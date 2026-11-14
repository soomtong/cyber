const std = @import("std");
const stdx = @import("stdx");
const t = stdx.testing;
const builtin = @import("builtin");
const cy = @import("cyber.zig");
const C = @import("capi.zig");
const fmt = cy.fmt;
const v = fmt.v;
const sema = cy.sema;
const types = cy.types;
const log = cy.log.scoped(.chunk);
const bc = @import("bc_gen.zig");
const ast = cy.ast;
const bt = cy.types.BuiltinTypes;

pub const ChunkId = u32;
pub const SymId = u32;
pub const FuncId = u32;

const VarAccessPath = struct {
    // Maybe redundant with recParentLocal()
    var_id: sema.LocalId = undefined,

    struct_field_offset: usize = 0,
    /// Number of field states the accessed member occupies. See `sema_type.fieldStateLen`.
    state_len: usize = 1,
};

/// A compilation unit.
/// It contains data to compile from source into a module with exported symbols.
pub const Chunk = struct {
    id: ChunkId,
    alloc: std.mem.Allocator,
    compiler: *cy.Compiler,
    sema: *cy.Sema,
    vm: *cy.VM,

    /// Heap for compile-time values.
    heap: *cy.Heap,

    /// Source code.
    src: []const u8,
    manage_src: bool,

    /// A builtin module (`core`, `meta`, `cy`, `c`, `math`, `io`, `test`). Set by the module's bind function.
    /// Only these declare `@` functions other than the hooks and use the attributes reserved for the compiler.
    is_builtin: bool = false,

    /// A callee that the compiler put into this chunk's AST (`fiber f()` is a call of `@new_fiber`). It names an
    /// intrinsic that the script could not call itself.
    internal_callee: ?*ast.Node = null,

    /// Whether `src` needs to be loaded from `srcUri`.
    pending_load_src: bool,
    loaded: bool,

    importer: ?*ast.Node,

    /// The chunks that this chunk imports with `use`. Their globals are initialized first (`global_init.zig`).
    imports: std.ArrayListUnmanaged(*cy.Chunk),

    /// Read-only view of the AST.
    ast: cy.ast.AstView,

    /// Owned, absolute path to source.
    srcUri: []const u8,

    parser: cy.Parser,

    /// Used for temp string building.
    tempBufU8: std.ArrayList(u8),
    u16_stack: std.ArrayList(u16),

    /// Since nodes are currently processed recursively,
    /// set the current node so that error reporting has a better
    /// location context for helper methods that simply return no context errors.
    curNode: ?*ast.Node,

    /// The left side of a plain `x = y` that sema is resolving. An undeclared name there gets a `:=` hint.
    assign_left: ?*ast.Node = null,

    /// The current expr that has a continuation body, otherwise null.
    cur_cont_expr: ?*ast.LambdaContExpr,

    ///
    /// Sema pass.
    ///
    semaProcs: std.ArrayList(sema.Proc),
    semaBlocks: std.ArrayList(sema.Block),

    /// Generic stacks.
    listDataStack: std.ArrayList(ListData),

    /// Stack for building func signatures. (e.g. for nested func calls)
    typeStack: std.ArrayList(*types.Type),

    valueStack: std.ArrayList(cy.Value),
    func_template_param_stack: std.ArrayList(cy.sym.FuncTemplateParam),

    expr_stack: std.ArrayList(sema.ExprResult),

    func_param_stack: std.ArrayList(sema.FuncParam),

    active_field_stack: std.ArrayList(bool),

    ir: cy.ir.Buffer,

    /// VM locals. From a block's `localStart` offset, this is indexed by the virtual reg 
    /// which includes function prelude regs and params for simplicity.

    /// Local vars.
    varStack: std.ArrayList(sema.Local),
    varShadowStack: std.ArrayList(cy.sema.VarShadow),

    /// Operands of the expression being analyzed that are done but not consumed yet, in evaluation order.
    /// See `sema.seqFlush`.
    seq_pending: std.ArrayList(cy.sema.SeqEntry) = .empty,
    seq_flushing: bool = false,
    /// The IR of `move x`: a read of `x`, which is dead from then on. `sema.seqPush` keeps it pending so that a
    /// cancel before the consumer takes it still destructs the value.
    moved_locals: std.AutoHashMapUnmanaged(*cy.ir.Expr, void) = .empty,

    /// The `s.start(func, {args})` call of a `scope` block that is being analyzed, and its argument literal.
    /// `semaTupleInit` records the borrows of that literal in `scope_start_borrows`. See `sema.semaScopeStart`.
    scope_start_call: ?*cy.ast.Node = null,
    scope_start_lit: ?*cy.ast.Node = null,
    scope_start_borrows: std.ArrayList(cy.sema.ScopeBorrow) = .empty,
    /// The `scope` blocks whose body is being analyzed, outermost first. `return`, `break` and `continue`
    /// join the blocks they leave (`sema.semaScopeExitJoin`).
    scope_blocks: std.ArrayList(cy.sema.OpenScopeBlock) = .empty,
    /// The borrows that the fibers of the open `scope` blocks hold. They end with their block.
    scope_borrows: std.ArrayList(cy.sema.ScopeBorrow) = .empty,

    /// Cancel pads by the address of the IR node they belong to: a call expr, a `suspend_` stmt or an
    /// `await_` stmt. A pad is a statement list that destructs the locals that are alive at the node and
    /// returns. A fiber that is cancelled while one of its frames is at the node continues there.
    /// See `sema.semaCancelPad` and `bc_gen.push_cancel_site`.
    cancel_pads: std.AutoHashMapUnmanaged(usize, *cy.ir.Stmt) = .empty,
    /// A pad is being analyzed. Its own calls (destructors) get no pad.
    cancel_pad_building: bool = false,
    /// While the locals of a block are destructed from the youngest down (`sema.semaDestructBlock2`): the index
    /// of the local that is destructed now, and the proc depth it belongs to. The locals from here up are
    /// destructed or being destructed, so the pad of the destructor call only destructs the older ones.
    cancel_pad_var_end: ?usize = null,
    cancel_pad_var_proc: usize = 0,
    /// bc_gen: the sites of the function that is generated, and the state while their pads are generated.
    cancel_sites: std.ArrayList(bc.CancelSite) = .empty,
    cancel_replay: bool = false,
    cancel_replay_last: bool = false,

    /// Main sema block id.
    mainSemaProcId: sema.ProcId,

    /// Builtins is always a fallback module for symbol lookups.
    fallback_modules: std.ArrayList(*cy.Sym),

    /// Syms owned by this chunk. Does not include field syms.
    syms: std.ArrayList(*cy.Sym),

    /// Functions owned by this chunk.
    /// Includes lambdas which are not linked from a named sym.
    funcs: std.ArrayList(*cy.Func),

    host_funcs: std.StringHashMapUnmanaged(C.BindFunc),
    fallback_bind_func: ?C.BindFunc = null,
    host_types: std.StringHashMapUnmanaged(C.BindType),
    host_globals: std.StringHashMapUnmanaged(C.BindGlobal),

    /// Run before chunk is destroyed.
    on_destroy: C.ModuleOnDestroyFn = null,

    /// Run after declarations have been loaded.
    on_load: C.ModuleOnLoadFn = null,

    /// Reference the current resolve context.
    resolve_stack: std.ArrayList(sema.ResolveContext),

    has_pending_ct_stmts: bool,
    resolving_ct_stmts: bool,

    ///
    /// Codegen pass
    ///
    proc_stack: std.ArrayList(bc.Proc), // TODO: This isn't needed anymore. `cur_proc` should be enough.
    funcs_debug: std.ArrayList(FuncDebugInfo),
    blocks: std.ArrayList(bc.Block),
    blockJumpStack: std.ArrayList(BlockJump),

    /// Maps ir local to bc reg.
    bc_local_map: std.ArrayList(bc.LocalSlot),

    /// Set while generating an inlined callee body. See `bc_gen.gen_inline_call`.
    inline_ctx: ?*bc.InlineCtx = null,
    /// Nesting of statement lists that end with a `never` call (error paths). Calls in them are not inlined.
    cold_depth: u32 = 0,

    /// Offset added to IR local ids. Non-zero only while inlining.
    inline_local_base: usize = 0,

    relocations: std.ArrayList(bc.Relocation),
    rt_relocations: std.ArrayList(bc.Relocation),

    cur_proc: *bc.Proc,

    // TODO: inline the active `Proc`.
    cur_sema_proc: *sema.Proc,

    temp_access_path: VarAccessPath,

    buf: cy.ByteCodeBuffer,

    /// This chunk's sym.
    sym: *cy.sym.Chunk,

    has_bind_lib: bool,
    bind_lib: ?[]const u8,
    has_extern_func: bool,

    has_static_init: bool,

    /// Bytecode was generated for this chunk (`bcgen.genAll` finished with it in `newChunks`).
    rt_ready: bool,
    /// A program that ran called this chunk's `@init` and bound its extern functions. A chunk compiled by
    /// `VM.validate` (never run) stays false and the next executed program initializes it (F-05).
    rt_inited: bool,

    /// A module that a failed compile loaded first. It left the module cache, so the next `use` loads the
    /// module again (`Compiler.carryFailedCompile`).
    evicted: bool = false,

    encoder: cy.ast.Encoder,

    indent: u32,

    /// Fallback for name resolving. Used by libcyber's `clFindType`.
    resolve_name_fn: ?*const fn(c: *Chunk, name: []const u8) ?sema.NameResult = null,

    reserved_syms: bool = false,

    /// LLVM
    
    user_data: ?*anyopaque,

    trace_eval_expr_depth: usize = 0,

    pub fn init(self: *Chunk, c: *cy.Compiler, id: ChunkId, srcUri: []const u8, src: ?[]const u8) !void {
        self.* = .{
            .id = id,
            .alloc = c.alloc,
            .compiler = c,
            .heap = &c.heap,
            .sema = &c.sema,
            .cur_sema_proc = undefined,
            .vm = c.vm,
            .src = src orelse "",
            .manage_src = true,
            .ast = undefined,
            .srcUri = srcUri,
            .sym = undefined,
            .parser = undefined,
            .semaProcs = .empty,
            .semaBlocks = .empty,
            .proc_stack = .empty,
            .funcs_debug = .empty,
            .blocks = .empty,
            .blockJumpStack = .empty,
            .varShadowStack = .empty,
            .varStack = .empty,
            .typeStack = .empty,
            .valueStack = .empty,
            .expr_stack = .empty,
            .func_param_stack = .empty,
            .active_field_stack = .empty,
            .temp_access_path = .{},
            .func_template_param_stack = .empty,
            .ir = undefined,
            .listDataStack = .empty,
            .cur_proc = undefined,
            .buf = cy.ByteCodeBuffer.init(c.alloc, c.vm),
            .curNode = null,
            .cur_cont_expr = null,
            .tempBufU8 = .empty,
            .u16_stack = .empty,
            .mainSemaProcId = cy.NullId,
            .fallback_modules = .empty,
            .has_static_init = false,
            .rt_ready = false,
            .rt_inited = false,
            .encoder = undefined,
            .indent = 0,
            .syms = .empty,
            .funcs = .empty,
            .host_funcs = .empty,
            .host_types = .empty,
            .host_globals = .empty,
            .resolve_stack = .empty,
            .user_data = null,
            .has_bind_lib = false,
            .bind_lib = null,
            .has_pending_ct_stmts = false,
            .resolving_ct_stmts = false,
            .pending_load_src = src == null,
            .loaded = false,
            .importer = null,
            .imports = .empty,
            .has_extern_func = false,
            .bc_local_map = .empty,
            .relocations = .empty,
            .rt_relocations = .empty,
        };
        self.encoder.c = c;
        self.ir.init(c.alloc);
        try self.parser.init(c.alloc);
    }

    // Compile-time values are destructed first since they depend on type syms.
    pub fn deinitCtValues(self: *Chunk) void {
        for (self.syms.items) |sym| {
            cy.sym.deinit_sym_ct_values(self.heap, sym);
        }
        for (self.funcs.items) |func| {
            cy.sym.deinit_func_ct_values(self.heap, func);
        }
    }

    pub fn deinit(self: *Chunk) void {
        self.tempBufU8.deinit(self.alloc);
        self.u16_stack.deinit(self.alloc);

        self.semaBlocks.deinit(self.alloc);

        for (self.semaProcs.items) |*sproc| {
            sproc.deinit(self.alloc);
        }
        self.semaProcs.deinit(self.alloc);

        self.proc_stack.deinit(self.alloc);
        self.funcs_debug.deinit(self.alloc);
        self.blocks.deinit(self.alloc); 

        self.blockJumpStack.deinit(self.alloc);
        self.varShadowStack.deinit(self.alloc);
        self.seq_pending.deinit(self.alloc);
        self.moved_locals.deinit(self.alloc);
        self.scope_start_borrows.deinit(self.alloc);
        self.scope_borrows.deinit(self.alloc);
        self.scope_blocks.deinit(self.alloc);
        self.cancel_pads.deinit(self.alloc);
        for (self.cancel_sites.items) |site| self.alloc.free(site.local_map);
        self.cancel_sites.deinit(self.alloc);
        self.varStack.deinit(self.alloc);

        self.typeStack.deinit(self.alloc);
        self.valueStack.deinit(self.alloc);
        self.expr_stack.deinit(self.alloc);
        self.func_param_stack.deinit(self.alloc);
        self.active_field_stack.deinit(self.alloc);
        self.func_template_param_stack.deinit(self.alloc);
        self.ir.deinit(self.alloc);
        self.listDataStack.deinit(self.alloc);
        self.resolve_stack.deinit(self.alloc);

        self.fallback_modules.deinit(self.alloc);
        self.imports.deinit(self.alloc);

        for (self.funcs.items) |func| {
            func.destroy(self.alloc);
        }
        self.funcs.deinit(self.alloc);

        self.host_funcs.deinit(self.alloc);
        self.host_types.deinit(self.alloc);
        self.host_globals.deinit(self.alloc);

        // Deinit chunk syms. Any retained values must already be freed in case they need to reference syms.
        for (self.syms.items) |sym| {
            sym.destroy(self.heap, self.alloc);
        }
        self.syms.deinit(self.alloc);

        self.buf.deinit();

        if (self.bind_lib) |dl_bind| {
            self.alloc.free(dl_bind);
            self.bind_lib = null;
        }

        self.bc_local_map.deinit(self.alloc);
        self.relocations.deinit(self.alloc);
        self.rt_relocations.deinit(self.alloc);

        self.alloc.free(self.srcUri);
        self.parser.deinit();
    }

    pub fn updateAstView(self: *cy.Chunk, view: cy.ast.AstView) void {
        self.ast = view;
    }

    pub fn genBlock(self: *cy.Chunk) *bc.Block {
        return &self.blocks.items[self.blocks.items.len-1];
    }

    pub fn loopBlock(self: *cy.Chunk, start: usize) ?usize {
        var i: usize = self.semaBlocks.items.len;
        while (i > start) {
            i -= 1;
            if (self.semaBlocks.items[i].loop) {
                return i;
            }
        }
        return null;
    }

    pub fn block(self: *cy.Chunk) *sema.Block {
        return &self.semaBlocks.items[self.semaBlocks.items.len-1];
    }

    pub fn proc(self: *cy.Chunk) *sema.Proc {
        return &self.semaProcs.items[self.semaProcs.items.len-1];
    }

    pub fn procBlock(self: *cy.Chunk) *sema.Block {
        return &self.semaBlocks.items[self.proc().block_start];
    }

    pub fn getProcParams(c: *const cy.Chunk, p: *sema.Proc) []const sema.Local {
        return c.varStack.items[p.varStart..p.varStart+p.numParams];
    }

    /// Includes aliases.
    pub fn getProcVars(c: *const cy.Chunk, p: *sema.Proc) []const sema.Local {
        return c.varStack.items[p.varStart+p.numParams..];
    }

    pub inline fn semaBlockDepth(self: *Chunk) u32 {
        return @intCast(self.semaProcs.items.len);
    }

    pub fn get_chunk_by_uri(self: *Chunk, uri: []const u8) !?*cy.Chunk {
        var buf: [1024]u8 = undefined;
        const ruri = try cy.compiler.resolveModuleUriFrom(self, &buf, uri, null);
        return self.compiler.chunk_map.get(ruri);
    }

    /// A jump operand is one `Inst` slot. `jump` · `release` · `release_opt` read it as i16, `jump_f` · `jump_t` as u16.
    /// A body long enough to push a jump past that is reported as a compile error instead of tripping `@intCast`
    /// (or, for a forward `jump` between 32768 and 65535, jumping backward at runtime). F-09.
    pub const max_jump: u32 = std.math.maxInt(i16);
    pub const max_cond_jump: u32 = std.math.maxInt(u16);

    fn checkJump(self: *Chunk, dist: usize, max: u32, node: ?*ast.Node) !u16 {
        if (dist > max) {
            return self.reportErrorFmt("Function body too large. A jump can span at most {} bytecode slots. Move part of the body into another function.", &.{v(max)}, node);
        }
        return @intCast(dist);
    }

    fn backJump(self: *Chunk, dist: usize, node: ?*ast.Node) !u16 {
        const d = try self.checkJump(dist, max_jump, node);
        return @bitCast(-@as(i16, @intCast(d)));
    }

    pub fn pushEmptyJumpNotCond(self: *Chunk, reg: bc.Reg, node: *ast.Node) !u32 {
        const start: u32 = @intCast(self.buf.ops.items.len);
        try self.pushCode(.jump_f, &.{reg, 0}, node);
        return start;
    }

    /// `jump_t` with the same operand layout as `jump_f`, so `patchJumpNotCondToCurPc` patches both.
    pub fn pushEmptyJumpCond(self: *Chunk, reg: bc.Reg, node: *ast.Node) !u32 {
        const start: u32 = @intCast(self.buf.ops.items.len);
        try self.pushCode(.jump_t, &.{reg, 0}, node);
        return start;
    }

    // A backward `jump` is a checkpoint that can stop the eval (`cl_vm_interrupt`, fuel), so jumps carry a
    // debug sym like other failable insts. `pushEmptyJump` can be patched backward by `continue`.
    pub fn pushJumpBackTo(self: *Chunk, toPc: usize, node: *ast.Node) !void {
        const pc = self.buf.ops.items.len;
        try self.pushFCode(.jump, &.{try self.backJump(pc - toPc, node)}, node);
    }

    pub fn pushEmptyJump(self: *Chunk, node: *ast.Node) !u32 {
        const start: u32 = @intCast(self.buf.ops.items.len);
        try self.pushFCode(.jump, &.{0}, node);
        return start;
    }

    pub fn patchJumpToCurPc(self: *Chunk, jumpPc: u32, node: ?*ast.Node) !void {
        self.buf.ops.items[jumpPc + 1].val = try self.checkJump(self.buf.ops.items.len - jumpPc, max_jump, node);
    }

    pub fn patchJumpCondToCurPc(self: *Chunk, jumpPc: u32, node: ?*ast.Node) !void {
        self.buf.ops.items[jumpPc + 2].val = try self.checkJump(self.buf.ops.items.len - jumpPc, max_cond_jump, node);
    }

    pub fn patchJumpNotCondToCurPc(self: *Chunk, jumpPc: u32, node: ?*ast.Node) !void {
        self.buf.ops.items[jumpPc + 2].val = try self.checkJump(self.buf.ops.items.len - jumpPc, max_cond_jump, node);
    }

    pub fn patchBreaks(self: *Chunk, jumpStackStart: usize, block_offset: usize, breakPc: usize, node: ?*ast.Node) !usize {
        var jump_stack_end = jumpStackStart;
        for (self.blockJumpStack.items[jumpStackStart..]) |jump| {
            switch (jump.jumpT) {
                .brk => {
                    if (jump.block_offset == block_offset) {
                        if (breakPc > jump.pc) {
                            self.buf.ops.items[jump.pc + 1].val = try self.checkJump(breakPc - jump.pc, max_jump, node);
                        } else {
                            self.buf.ops.items[jump.pc + 1].val = try self.backJump(jump.pc - breakPc, node);
                        }
                    } else {
                        self.blockJumpStack.items[jump_stack_end] = jump;
                        jump_stack_end += 1;
                    }
                },
                else => {
                    self.blockJumpStack.items[jump_stack_end] = jump;
                    jump_stack_end += 1;
                },
            }
        }
        return jump_stack_end;
    }

    pub fn patchForBlockJumps(self: *Chunk, jumpStackStart: usize, block_offset: usize, breakPc: usize, contPc: usize, node: ?*ast.Node) !usize {
        var jump_stack_end = jumpStackStart;
        for (self.blockJumpStack.items[jumpStackStart..]) |jump| {
            switch (jump.jumpT) {
                .brk => {
                    if (jump.block_offset == block_offset) {
                        if (breakPc > jump.pc) {
                            self.buf.ops.items[jump.pc + 1].val = try self.checkJump(breakPc - jump.pc, max_jump, node);
                        } else {
                            self.buf.ops.items[jump.pc + 1].val = try self.backJump(jump.pc - breakPc, node);
                        }
                    } else {
                        self.blockJumpStack.items[jump_stack_end] = jump;
                        jump_stack_end += 1;
                    }
                },
                .cont => {
                    if (jump.block_offset == block_offset) {
                        if (contPc > jump.pc) {
                            self.buf.ops.items[jump.pc + 1].val = try self.checkJump(contPc - jump.pc, max_jump, node);
                        } else {
                            self.buf.ops.items[jump.pc + 1].val = try self.backJump(jump.pc - contPc, node);
                        }
                    } else {
                        self.blockJumpStack.items[jump_stack_end] = jump;
                        jump_stack_end += 1;
                    }
                },
            }
        }
        return jump_stack_end;
    }

    pub fn getMaxUsedRegisters(self: *Chunk) bc.Reg {
        return self.cur_proc.max_regs;
    }

    pub fn unescapeString(self: *Chunk, literal: []const u8) ![]const u8 {
        try self.tempBufU8.resize(self.alloc, literal.len);
        return cy.sema.unescapeString(self.tempBufU8.items, literal, false);
    }

    pub fn appendContextTrace(self: *Chunk, report: *cy.compiler.Report, msg: []const u8, ctx_n: *ast.Node) !*cy.compiler.Report {
        const trace = try self.alloc.create(cy.compiler.Report);
        trace.* = .{
            .type = .context,
            .msg = try self.alloc.dupe(u8, msg),
            .chunk = ctx_n.src(),
            .loc = @intFromPtr(ctx_n),
        };
        report.next = trace;
        return trace;
    }

    pub fn appendErrorTrace(self: *Chunk, report: *cy.compiler.Report) !void {
        var last = report;
        if (self.resolve_stack.items.len > 0) {
            var i: usize = self.resolve_stack.items.len;
            while (i > 0) {
                i -= 1;
                const ctx = self.resolve_stack.items[i];
                const caller = ctx.caller orelse continue;
                const trace = try self.alloc.create(cy.compiler.Report);
                trace.* = .{
                    .type = .compile_err,
                    .msg = "",
                    .chunk = caller.src(),
                    .loc = @intFromPtr(caller),
                };
                last.next = trace;
                last = trace;
            }
        }
    }

    pub fn reportError(self: *Chunk, msg: []const u8, opt_node: ?*ast.Node) error{OutOfMemory, CompileError} {
        const id = try self.addReport(msg, opt_node);
        try self.appendErrorTrace(&self.compiler.reports.items[id]);
        return error.CompileError;
    }

    pub fn addReport(self: *Chunk, msg: []const u8, opt_node: ?*ast.Node) !usize {
        var chunk_id: u32 = undefined;
        if (opt_node) |node| {
            chunk_id = node.src();
        } else {
            // Reports from module loading arrive before any resolve context exists.
            if (self.resolve_stack.items.len > 0) {
                const ctx = sema.getResolveContext(self);
                chunk_id = ctx.chunk.id;
            } else {
                chunk_id = self.id;
            }
        }
        return self.compiler.addReport(.compile_err, msg, chunk_id, @intFromPtr(opt_node));
    }

    pub fn reportErrorFmt(self: *Chunk, format: []const u8, args: []const fmt.FmtValue, opt_node: ?*ast.Node) error{CompileError, OutOfMemory, FormatError, WriteFailed} {
        const id = try self.addReportFmt(format, args, opt_node);
        try self.appendErrorTrace(&self.compiler.reports.items[id]);
        return error.CompileError;
    }

    pub fn addReportFmt(self: *Chunk, format: []const u8, args: []const fmt.FmtValue, opt_node: ?*ast.Node) !usize {
        var chunk_id: u32 = undefined;
        if (opt_node) |node| {
            chunk_id = node.src();
        } else {
            if (self.resolve_stack.items.len > 0) {
                const ctx = sema.getResolveContext(self);
                chunk_id = ctx.chunk.id;
            } else {
                chunk_id = self.id;
            }
        }
        return self.compiler.addReportFmt(.compile_err, format, args, chunk_id, @intFromPtr(opt_node));
    }

    /// An optional debug sym is only included in Trace builds.
    pub fn pushOptionalDebugSym(c: *Chunk, node: *ast.Node) !void {
        if (cy.Trace or c.compiler.vm.config.gen_all_debug_syms) {
            try c.pushFailableDebugSym(node);
        }
    }

    pub fn pushFailableDebugSym(self: *Chunk, node: *ast.Node) !void {
        var loc = node.pos();
        var frame = self.cur_proc.id;
        if (self.inline_ctx) |ctx| {
            // The trace expands an inline site into a callee and a caller frame.
            frame = ctx.frame_id;
            if (node.src() != ctx.src_chunk) {
                // Generated code without a callee source pos. Shown like a hidden function.
                loc = cy.NullId;
            }
        }
        try self.buf.pushFailableDebugSym(
            self.buf.ops.items.len, self.cur_proc.chunk_id, loc, frame,
        );
    }

    pub fn fmtExtraDesc(self: *Chunk, comptime format: []const u8, vals: anytype) !u32 {
        // Behind a comptime flag since it's doing allocation.
        if (cy.Trace) {
            const idx = self.buf.instDescExtras.items.len;
            const text = try self.alloc.print(format, vals);
            try self.buf.instDescExtras.append(self.alloc, .{
                .text = text,
            });
            return @intCast(idx);
        } else {
            return cy.NullId;
        }
    }

    pub fn pushFCode(c: *Chunk, code: cy.OpCode, args: []const u16, node: *ast.Node) !void {
        return c.pushFCode2(code, false, args, node);
    }

    /// An instruction that can fail (can throw or panic).
    pub fn pushFCode2(c: *Chunk, code: cy.OpCode, tmp_dst: bool, args: []const u16, node: *ast.Node) !void {
        log.tracev("pushFCode: {s} {}", .{@tagName(code), c.buf.ops.items.len});
        try c.pushFailableDebugSym(node);
        try c.buf.pushOpSlice2(code, tmp_dst, args);
        if (cy.Trace) {
            const exp = cy.bytecode.getInstLenAt(c.buf.ops.items.ptr + c.buf.ops.items.len - 1 - args.len) - 1;
            if (args.len != exp) {
                std.debug.panic("Expected {} operands for {}, found {}.", .{exp, code, args.len});
            }
        }
    }

    pub fn pushCode(c: *Chunk, code: cy.OpCode, args: []const u16, node: *ast.Node) !void {
        return c.pushCode2(code, false, args, node);
    }

    pub fn pushCode2(c: *Chunk, code: cy.OpCode, tmp_dst: bool, args: []const u16, node: *ast.Node) !void {
        log.tracev("pushCode: {s} {}", .{@tagName(code), c.buf.ops.items.len});
        try c.pushOptionalDebugSym(node);
        try c.buf.pushOpSlice2(code, tmp_dst, args);
        if (cy.Trace) {
            const exp = cy.bytecode.getInstLenAt(c.buf.ops.items.ptr + c.buf.ops.items.len - 1 - args.len) - 1;
            if (args.len != exp) {
                std.debug.panic("Expected {} operands for {}, found {}.", .{exp, code, args.len});
            }
        }
    }

    pub fn pushCodeExt(c: *Chunk, code: cy.OpCode, args: []const u16, operands: usize, node: *ast.Node) !void {
        return c.pushCodeExt2(code, false, args, operands, node);
    }

    /// `pushCodeExt` for an instruction that can fail.
    pub fn pushFCodeExt(c: *Chunk, code: cy.OpCode, args: []const u16, operands: usize, node: *ast.Node) !void {
        return c.pushCodeExt2(code, true, args, operands, node);
    }

    fn pushCodeExt2(c: *Chunk, code: cy.OpCode, failable: bool, args: []const u16, operands: usize, node: *ast.Node) !void {
        log.tracev("pushCode: {s} {}", .{@tagName(code), c.buf.ops.items.len});
        if (failable) {
            try c.pushFailableDebugSym(node);
        } else {
            try c.pushOptionalDebugSym(node);
        }
        try c.buf.pushOpSlice(code, args);
        _ = try c.buf.reserveData(operands);
        if (cy.Trace) {
            const exp = cy.bytecode.getInstLenAt(c.buf.ops.items.ptr + c.buf.ops.items.len - 1 - args.len - operands) - 1;
            if (args.len + operands != exp) {
                std.debug.panic("Expected {} operands for {}, found {}.", .{exp, code, args.len + operands});
            }
        }
    }

    pub fn pushCodeBytes(c: *Chunk, bytes: []const u8) !void {
        try c.buf.pushOperands(bytes);
    }

    pub fn findResolvedType(c: *cy.Chunk, spec: []const u8, node: *ast.Node) !?*cy.Type {
        const type_ = (try c.vm.findType(spec)) orelse {
            return null;
        };
        try cy.sema_type.ensure_resolved_type(c, type_, node);
        return type_;
    }

    pub const createTypeSym = cy.sym.createTypeSym;
    pub const createTypeAlias = cy.sym.createTypeAlias;
    pub const createTypeConst = cy.sym.createTypeConst;
    pub const createFuncSym = cy.sym.createFuncSym;
    pub const createFunc = cy.sym.createFunc;
    pub const createConst = cy.sym.createConst;
    pub const createField = cy.sym.createField;
    pub const createHostVar = cy.sym.createHostVar;
    pub const createUserVar = cy.sym.createUserVar;
    pub const createEnumCase = cy.sym.createEnumCase;
    pub const createChoiceCase = cy.sym.createChoiceCase;
    pub const createUnionCase = cy.sym.createUnionCase;
    pub const createFuncTemplate = cy.sym.createFuncTemplate;
    pub const createChunkSym = cy.sym.createChunkSym;
    pub const createUseAlias = cy.sym.createUseAlias;
    pub const createTemplate = cy.sym.createTemplate;
    pub const createVariantMember = cy.sym.createVariantMember;
    pub const createVariantFunc = cy.sym.createVariantFunc;
    pub const createExternVar = cy.sym.createExternVar;
    pub const getSymValueType = cy.sym.getSymValueType;

    pub const declareEnumCase = cy.module.declareEnumCase;
    pub const declareChoiceCase = cy.module.declareChoiceCase;
    pub const declareUnionCase = cy.module.declareUnionCase;
    pub const declareField = cy.module.declareField;
    pub const accessResolvedSym = cy.module.accessResolvedSym;
    pub const accessResolvedSymOrFail = cy.module.accessResolvedSymOrFail;
    pub const appendFunc = cy.module.appendFunc;
    pub const addUserLambda = cy.module.addUserLambda;
    pub const reserveTypeSym = cy.module.reserveTypeSym;
    pub const reserveTypeAlias = cy.module.reserveTypeAlias;
    pub const reserve_type_const = cy.module.reserve_type_const;
    pub const reserveFunc = cy.module.reserveFunc;
    pub const reserveUserFunc = cy.module.reserveUserFunc;
    pub const reserveTemplate = cy.module.reserveTemplate;
    pub const reserveTraitFunc = cy.module.reserveTraitFunc;
    pub const reserveConst = cy.module.reserveConst;
    pub const reserveFuncTemplateSym = cy.module.reserveFuncTemplateSym;
    pub const reserveUseAlias = cy.module.reserveUseAlias;
    pub const reserveVariantMember = cy.module.reserveVariantMember;
    pub const reserveVariantFunc = cy.module.reserveVariantFunc;
    pub const reserveUserVar = cy.module.reserveUserVar;
    pub const reserveHostVar = cy.module.reserveHostVar;
    pub const reserveExternVar = cy.module.reserveExternVar;
    pub const resolveFunc = cy.module.resolveFunc;
    pub const resolveHostFunc = cy.module.resolveHostFunc;
    pub const resolveUserFunc = cy.module.resolveUserFunc;
    pub const resolveUserLambda = cy.module.resolveUserLambda;
    pub const resolveFuncInfo = cy.module.resolveFuncInfo;
    pub const resolveHostConstEvalFunc = cy.module.resolveHostConstEvalFunc;
    pub const resolveHostBuiltinFunc = cy.module.resolveHostBuiltinFunc;
    pub const resolveHostVar = cy.module.resolveHostVar;
    pub const resolveUserVarType = cy.module.resolveUserVarType;
    pub const checkResolvedSymIsDistinct = cy.module.checkResolvedSymIsDistinct;
    pub const getResolvedSym = cy.module.getResolvedSym;
    pub const getResolvedSymOrFail = cy.module.getResolvedSymOrFail;

    pub const semaInitExpr = sema.semaInitExpr;
    pub const semaObjectInit2 = sema.semaObjectInit2;
    pub const semaInitStruct = sema.semaInitStruct;
    pub const semaInitFixedArray = sema.semaInitVector;
    pub const semaTupleInit = sema.semaTupleInit;
    pub const semaPtrOrType = sema.semaPtrOrType;
    pub const semaRefOrType = sema.semaRefOrType;
    pub const semaBorrowOrType = sema.semaBorrowOrType;
    pub const semaBinExpr = sema.semaBinExpr;
    pub const semaUnExpr = sema.semaUnExpr;
    pub const semaIsError = sema.semaIsError;
    pub const semaIsNone = sema.semaIsNone;
    pub const semaIsZero = sema.semaIsZero;
    pub const semaConst = sema.semaConst;
    pub const semaConst8 = sema.semaConst8;
    pub const semaConst16 = sema.semaConst16;
    pub const semaConst32 = sema.semaConst32;
    pub const semaNone = sema.semaNone;
    pub const semaFalse = sema.semaFalse;
    pub const semaString = sema.semaString;
    pub const semaStringTarget = sema.semaStringTarget;
    pub const semaRawString = sema.semaRawString;
    pub const semaRawStringAs = sema.semaRawStringAs;
    pub const semaStringAs = sema.semaStringAs;
    pub const semaTrue = sema.semaTrue;
    pub const semaVoid = sema.semaVoid;
    pub const semaExprOrOpAssignBinExpr = sema.semaExprOrOpAssignBinExpr;
    pub const semaExprSkipSym = sema.semaExprSkipSym;
    pub const semaExpr = sema.semaExpr;
    pub const semaExprHint = sema.semaExprHint;
    pub const semaExprCstr = sema.semaExprCstr;
    pub const semaExprNoCheck = sema.semaExprNoCheck;
    pub const semaExprTarget = sema.semaExprTarget;
    pub const semaCallExpr = sema.semaCallExpr;
    pub const semaCallValue = sema.semaCallValue;
    pub const semaCallUnion = sema.semaCallUnion;
    pub const semaCallPtr = sema.semaCallPtr;
    pub const semaCallFunc = sema.semaCallFunc;
    pub const semaCallFunc2 = sema.semaCallFunc2;
    pub const semaCallFuncResult = sema.semaCallFuncResult;
    pub const semaCallFuncSym = sema.semaCallFuncSym;
    pub const semaCallFuncSym1 = sema.semaCallFuncSym1;
    pub const semaCallFuncSym2 = sema.semaCallFuncSym2;
    pub const semaCallFuncSymRec = sema.semaCallFuncSymRec;
    pub const semaCallFuncSymRec2 = sema.semaCallFuncSymRec2;
    // pub const semaCallGenericFunc = sema.semaCallGenericFunc;
    // pub const semaCallGenericFuncRec = sema.semaCallGenericFuncRec;

    pub const sema_expr_cstr_template = sema.sema_expr_cstr_template;
};

const FuncDebugInfo = struct {
    func: ?*cy.Func,

    name: []const u8,
    src_chunk: u32,
};

test "chunk internals." {
}

const BlockJumpType = enum {
    /// Breaks out of a for loop, while loop, or switch stmt.
    brk,
    /// Continues a for loop or while loop.
    cont,
};

const BlockJump = struct {
    jumpT: BlockJumpType,
    pc: u32,
    block_offset: u32,
};

const ReservedTempLocal = struct {
    local: LocalId,
};

const LocalId = u8;

pub const TypeDepNode = struct {
    visited: bool,
    hasCircularDep: bool,
    hasUnsupported: bool,
};

pub const ListData = union {
    pc: u32,
    node: ?*ast.Node,
    constIdx: u16,
    jumpToEndPc: u32,
};