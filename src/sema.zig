const std = @import("std");
const stdx = @import("stdx");
const t = stdx.testing;
const cy = @import("cyber.zig");
const ir = cy.ir;
const bt = cy.types.BuiltinTypes;
const sema = @This();
const sema_func = cy.sema_func;

/// TODO: Move use sites to sema_func.
const Argument = cy.sema_func.Argument;

const fmt = cy.fmt;
const v = fmt.v;
const ast = cy.ast;

const TypeId = cy.types.TypeId;
const Sym = cy.Sym;
const Value = cy.Value;
const TypeValue = cy.TypeValue;

const log = cy.log.scoped(.sema);

const sema_stmt = cy.sema_stmt;
const sema_local = cy.sema_local;
const sema_call = cy.sema_call;
const sema_expr = cy.sema_expr;
const sema_access = cy.sema_access;
const sema_resolve = cy.sema_resolve;
const sema_move = cy.sema_move;

pub const LocalId = u32;

pub const LocalVarType = enum(u8) {
    /// Local var or param.
    local, 

    /// Marked dead.
    dead,
};

const LocalVarS = struct {
    /// Id emitted in IR code. Starts from 0 after params in the current block.
    /// Aliases do not have an id.
    id: u8,

    isParam: bool,

    /// If declaration has an initializer.
    hasInit: bool,

    /// If var is hidden, user code can not reference it.
    hidden: bool,

    /// For persisted REPL locals.
    allow_redeclare: bool = false,

    /// For locals this points to a ir.DeclareLocal.
    /// This is NullId for params.
    declIrStart: *ir.Stmt,

    /// The initializer of a `x := expr` declaration. Error hints use it to tell where a value came from.
    init_node: ?*ast.Node = null,
};

const LifetimeKind = enum {
    block,

    /// Temporary, usually an rvalue that.
    temp,

    /// Continues to live beyond after function returns.
    inout,
};

pub const Lifetime = struct {
    kind: LifetimeKind,

    /// Relevant when `kind == .block`.
    block_depth: u8 = undefined,

    pub fn initTemp() Lifetime {
        return .{
            .kind = .temp,
        };
    }

    pub fn initBlock(depth: u8) Lifetime {
        return .{
            .kind = .block,
            .block_depth = depth,
        };
    }
};

pub const BorrowOwner = struct {
    owner: LocalId,
    ex: bool,
    /// The part of the value can point into `owner`, a local that holds borrows itself (`&w.x` of
    /// `w := W{q=&z}`), not only into the owner at its root (`sema_borrow.valuePlaceFree`).
    place: bool = false,
};

pub const BorrowLoan = struct {
    local: LocalId,
    owner: LocalId,
    ex: bool,
};

pub const borrow_field_unknown: u16 = 0xffff;
pub const borrow_field_whole: u16 = 0xfffe;

/// Represents a variable or alias in a block.
/// Local variables are given reserved registers on the stack frame.
/// Captured variables have box values at runtime.
/// TODO: This should be SemaVar since it includes all vars not just locals.
pub const Local = struct {
    type: LocalVarType,

    decl_t: *cy.Type,

    lifetime: Lifetime,

    /// If this is an owning local, track the borrows stored in other locals for the exclusivity check.
    /// Only borrows that live in a local count; a borrow passed as an argument ends with its statement.
    /// See `docs/decisions/project_borrow_model.md`.
    active_borrows: u8,
    active_ex_borrows: u8,

    /// Local register offset assigned to this var.
    /// Locals are relative to the stack frame's start position.
    local: u8 = undefined,

    /// Contains active fields in `proc.var_active_struct_fields`.
    has_inactive_struct_fields: bool = false,

    /// If this local holds a borrow, the owning local it borrows from (`cy.NullId` otherwise).
    /// Set by `bindBorrowLocal`, released by `popLocals2` and on reassignment.
    parent_local: LocalId,
    /// Whether the borrow held by this local is exclusive (`&&T`).
    ex_borrow: bool = false,
    /// The borrow container that the borrow of this local was read through (`p := &&h` of `h := Holder{r=&&f}`), or
    /// `cy.NullId`. The local can not outlive it (`checkViaOutlives`).
    borrow_via: LocalId = cy.NullId,
    /// Whether the value of this local can hold a borrow that points into a local that holds borrows itself
    /// (`h := H{b=&w.x}`, `h.b = &w.x`), or that this is unknown (`&&h` was taken). Only then a copy of a borrow
    /// that is read out of the local (`h.b`) has to stay inside the local (`sema_borrow.copyOutOf`).
    borrow_places: bool = false,
    /// The first local of the copies of one borrow (`r2 := r`), or `cy.NullId` for a borrow that is no copy.
    borrow_alias: LocalId = cy.NullId,
    /// The field of the owner that the borrow of this local points into, `borrow_field_whole` or
    /// `borrow_field_unknown`. An exclusive use of one field is no conflict with a borrow into another field.
    borrow_field: u16 = borrow_field_unknown,
    /// Whether the borrow of this local points to the place of the owner or of one of its fields (`&x`, `&x.a.b`),
    /// not into a buffer that the owner manages (`&x.xs[0]`). The place stays when its value is replaced.
    borrow_inline: bool = false,
    /// The name of a `scope |s|:` block. Only `s.start` on this name takes borrows (`semaScopeStart`).
    scope_block: bool = false,
    /// The borrow of this local ended after the last statement of its block that names it (`endBorrowsAfter`).
    /// The local is not used again.
    borrow_ended: bool = false,

    stack_idx: u32,

    inner: union {
        local: LocalVarS,
        unDefined: void,
    } = .{ .unDefined = {} },

    nameLen: u16,
    namePtr: [*]const u8,

    pub fn name(self: Local) []const u8 {
        return self.namePtr[0..self.nameLen];
    }

    pub inline fn isCapturable(self: Local) bool {
        return self.type == .local;
    }
};

const VarCacheEntryKind = enum {
    local,
    capture,
};

const VarCacheEntry = struct {
    type: VarCacheEntryKind,
    data: union {
        local: struct {
            varId: LocalId,
            blockId: BlockId,
        },
        // Index to Proc.captures.
        capture: u32,
    },
};

pub const VarShadow = extern struct {
    namePtr: [*]const u8,
    nameLen: u32,
    varId: LocalId,
    blockId: BlockId,
};

pub const NameVar = extern struct {
    namePtr: [*]const u8,
    nameLen: u32,
    varId: LocalId,
};

pub const VarAndType = struct {
    id: LocalId,
    vtype: TypeId,
};

pub const BlockId = u32;

pub const Block = struct {
    /// Start of local vars in this sub-block in `varStack`.
    varStart: u32,

    /// Start of shadowed vars from the previous sub-block in `varShadowStack`.
    varShadowStart: u32,

    /// Node that began the sub-block.
    node: *ast.Node,

    /// Whether execution can reach the end.
    /// If a return statement was generated, this would be set to false.
    endReachable: bool = true,

    /// Whether this is a loop block.
    loop: bool,

    pre_continue_block: u32 = cy.NullId,

    /// Whether there is a break stmt in the body of the loop.
    loop_has_break: bool,

    /// Whether a local of an outer block can be moved here (`canMoveAcross`).
    move_branch: MoveBranch = .none,

    /// The length of `Chunk.branch_moves` where the block began: the moves of outer locals after it are made in this
    /// block, or come from a statement of it that joined its branches.
    moves_start: u32 = 0,

    /// For a loop block: the block that wraps the loop statement (`pushLoopWrap`).
    loop_wrap: u32 = cy.NullId,

    /// For the wrap block of a loop: where the `break` statements that left the loop after they moved outer locals
    /// start in `Chunk.moved_breaks`, and those locals in `Chunk.break_moves`.
    moved_breaks_start: u32 = 0,
    break_moves_start: u32 = 0,

    pub fn init(node: *ast.Node, varStart: usize, varShadowStart: usize) Block {
        return .{
            .node = node,
            .varStart = @intCast(varStart),
            .varShadowStart = @intCast(varShadowStart),
            .loop = false,
            .loop_has_break = false,
        };
    }
};

pub const ProcId = u32;

/// A `break` that left a loop after the body moved outer locals (`semaMovedBreak`).
pub const MovedBreak = struct {
    /// An empty block before the `break`. `popLoopWrap` fills it with the destructors of the locals that the other
    /// such `break` statements of the loop moved and this one did not.
    slot: *ir.Stmt,
    /// The locals that it moved, a range of `Chunk.break_moves`.
    start: u32,
    end: u32,
};

pub const MoveBranch = enum(u8) {
    none,
    /// The body of a branch of an `if` statement, or its outer block while the `else` statements are checked.
    branch,
    /// The outer block of an `if` statement, between its branches and the block of the local.
    if_outer,
    /// The outer block of an `if` statement while its first condition is checked. The condition always runs, so a move
    /// in it is a move in the block of the statement (`moveBlock`).
    if_cond,
    /// The outer block of an `if` statement while the condition of an `else` branch is checked. The condition runs
    /// only when the branches before it did not: no outer local moves in it, also not from a branch of an `if`
    /// expression in it.
    else_cond,
    /// A block whose statements run in order: a `begin:` block, or a block of a loop statement. A move of an outer
    /// local in it is a move of the block around it. A loop checks where the move can go (`checkLoopMoves`).
    plain,
};

/// Lowering target of a `try` block. See `sema_try_stmt`.
pub const TryCtx = struct {
    /// Sema block of the `try` body. `!` breaks out of it on failure.
    body_block: BlockId,
    /// Hidden `error` local that carries the failure to the `else` block.
    err_local: LocalId,
    /// A `try` statement: a failing `!` notes the outer locals that the body moved on the way (`semaTryExit`).
    track_moves: bool = false,
};

pub const CaptureInfo = struct {
    parent_var_idx: u32,
    val_t: *cy.Type,
};

/// Container for main, fiber, function, and lambda blocks.
pub const Proc = struct {
    /// `varStack[varStart]` is the start of params.
    numParams: u8,

    /// The last cancel pad of this proc and the hash of the locals it destructs (`semaCancelPad`).
    cancel_pad: ?*ir.Stmt = null,
    cancel_pad_sig: u64 = 0,

    /// Captured vars. 
    captures: std.ArrayList(CaptureInfo),

    /// Maps a name to a var.
    /// This is updated as blocks declare their own locals and restored
    /// when blocks end.
    /// This can be deinited after ending the sema block.
    /// TODO: Move to chunk level.
    var_cache_entries: std.StringHashMapUnmanaged(VarCacheEntry),

    /// Maps a var to its active fields.
    /// Intentionally separated from any future var field states so it can be hashed against PartialStructLayout.
    var_active_struct_fields: std.AutoHashMapUnmanaged(LocalId, []bool),

    /// Start of `semaBlocks` stack.
    block_start: BlockId,

    /// Current sub block depth.
    block_depth: u32,

    /// Main block if `NullId`.
    func: ?*cy.Func,

    /// Whether this block belongs to a static function.
    isStaticFuncBlock: bool,

    /// Whether this is a method block.
    isMethodBlock: bool = false,

    /// All locals currently alive in this block.
    /// Every local above the current sub-block is included.
    varStart: u32,

    active_field_start: u32,

    global_init: bool,

    /// The global whose initializer is being analyzed. Its calls are recorded for `global_init.check`.
    global_init_var: ?*cy.sym.UserVar = null,

    /// Innermost enclosing `try` block of this proc. `!` inside it jumps to the `else` block
    /// instead of returning or panicking. A lambda starts a new proc, so it does not inherit it.
    try_ctx: ?TryCtx = null,

    ir: *ir.Stmt,

    node: *ast.Node,

    pub fn init(node: *ast.Node, func: ?*cy.Func, block_start: usize, isStaticFuncBlock: bool, varStart: u32, active_field_start: u32) Proc {
        return .{
            .var_cache_entries = .empty,
            .var_active_struct_fields = .empty,
            .numParams = 0,
            .block_depth = 0,
            .func = func,
            .block_start = @intCast(block_start),
            .isStaticFuncBlock = isStaticFuncBlock,
            .node = node,
            .captures = .empty,
            .varStart = varStart,
            .active_field_start = active_field_start,
            .global_init = false,
            .ir = undefined,
        };
    }

    pub fn deinit(self: *Proc, alloc: std.mem.Allocator) void {
        self.var_cache_entries.deinit(alloc);
        self.var_active_struct_fields.deinit(alloc);
        self.captures.deinit(alloc);
    }

    pub fn getReturnType(self: *const Proc, s: *Sema) *cy.Type {
        if (self.func) |func| {
            return func.sig.ret;
        } else {
            return s.object_t;
        }
    }
};

pub const ModFuncSigKey = cy.hash.KeyU128;
const ObjectMemberKey = cy.hash.KeyU64;

/// The statement being checked and its block, for `reuseSliceBuffer`.
pub const StmtCtx = struct {
    stmts: []const *ast.Node = &.{},
    idx: usize = 0,
    block: usize = 0,
};

// NOTE: This should only be inserted once since the main block will be wrapped in a main function.
pub fn sema_program_deinit(c: *cy.Chunk) !void {
    try sema_expr.semaNop(c, "program end.", c.ast.null_node);
    // Run static deinit for main func.
    const func = c.sym.getMod().getSym("@program_deinit").?.cast(.func).first;
    const expr = try sema_call.sema_call_ir(c, func, &.{}, c.ast.null_node);
    try sema_local.sema_discard(c, expr, c.ast.null_node);
}

const ExprResultType = enum(u8) {
    value,
    value_local,
    value_field,
    sym,
    varSym,
    const_,
    func,
    capturedLocal,
    ct_value,
    infer_error,
    pinned_borrow,
};

const ExprResultData = union {
    value: struct {
        // Values have a temp lifetime.
        // Borrow references point to a parent lifetime.
        parent_local: ?LocalId,

        // Depends on an auxiliary local (for local declarations only).
        has_aux_local: bool = false,
    },
    sym: *Sym,
    varSym: *Sym,
    const_: *Sym,
    func: *cy.sym.Func,
    value_local: LocalId,
    value_field: struct {
        parent_local: ?LocalId,
    },
    ct_value: TypeValue,
    infer_error: anyerror,
};

pub const ExprResult = struct {
    resType: ExprResultType,
    type: *cy.Type,
    data: ExprResultData,

    /// Whether the expression is addressable. (locals, field access)
    addressable: bool = false,

    owned: bool = false,

    // Suggests that a subsequent struct field access should be checked against the active list.
    check_struct_field_access: bool = false,

    ir: *cy.ir.Expr,

    pub fn initVoid(void_t: *cy.Type) ExprResult {
        return .{
            .resType = .ct_value,
            .type = void_t,
            .data = .{ .ct_value = TypeValue.init(void_t, cy.Value.Void) },
            .ir = undefined,
        };
    }

    pub fn initOwned(expr: *ir.Expr) ExprResult {
        return .{
            .resType = .value,
            .type = expr.type,
            .data = .{
                .value = .{
                    .parent_local = null,
                },
            },
            .owned = true,
            .ir = expr,
        };
    }

    pub fn init2(expr: *ir.Expr) ExprResult {
        return .{
            .resType = .value,
            .type = expr.type,
            .data = .{
                .value = .{
                    .parent_local = null,
                },
            },
            .ir = expr,
        };
    }

    pub fn init(expr: *ir.Expr, expr_t: *cy.Type) ExprResult {
        return .{
            .resType = .value,
            .type = expr_t,
            .data = .{
                .value = .{
                    .parent_local = null,
                },
            },
            .ir = expr,
        };
    }

    pub fn initInferError(err: anyerror) ExprResult {
        return .{
            .resType = .infer_error,
            .type = &cy.types.NullType,
            .data = .{ .infer_error = err },
            .ir = undefined,
        };
    }

    pub fn initCtValue(value: TypeValue) ExprResult {
        return .{
            .resType = .ct_value,
            .type = value.type,
            .data = .{ .ct_value = value },
            .ir = undefined,
        };
    }

    pub fn initCtValue2(type_: *cy.Type, value: Value) ExprResult {
        return .{
            .resType = .ct_value,
            .type = type_,
            .data = .{ .ct_value = TypeValue.init(type_, value) },
            .ir = undefined,
        };
    }

    pub fn initField(expr: *ir.Expr, parent_local: ?LocalId) ExprResult {
        return .{
            .resType = .value_field,
            .type = expr.type,
            .data = .{
                .value_field = .{
                    .parent_local = parent_local,
                },
            },
            .ir = expr,
        };
    }

    pub fn initLocal(expr: *ir.Expr, local: LocalId) ExprResult {
        return .{
            .resType = .value_local,
            .type = expr.type,
            .data = .{
                .value_local = local,
            },
            .ir = expr,
        };
    }

    pub fn initCustom(expr: *ir.Expr, resType: ExprResultType, expr_t: *cy.Type, data: ExprResultData) ExprResult {
        return .{
            .resType = resType,
            .type = expr_t,
            .data = data,
            .ir = expr,
        };
    }

    pub fn recParentLocal(self: *const ExprResult) ?LocalId {
        switch (self.resType) {
            .value_local => {
                return self.data.value_local;
            },
            .value_field => {
                return self.data.value_field.parent_local;
            },
            .value => {
                return self.data.value.parent_local;
            },
            else => {
                return null;
            },
        }
    }

    pub fn recParentLocalOrError(self: *const ExprResult, c: *cy.Chunk, node: *ast.Node) !LocalId {
        return self.recParentLocal() orelse {
            return c.reportErrorFmt("Expected receiver parent local. `{}`", &.{v(self.resType)}, node);
        };
    }
};

pub const Cstr = struct {
    /// Whether to fail if incompatible with type cstr.
    reqTypeCstr: bool = false,

    /// Some expressions may want to have a target type but not try to fit it.
    /// In such cases, `target_t` serves as simply a type hint.
    /// e.g. When processing the first operand of a binary expression.
    fit_target: bool = false,

    use_as_borrow: bool = false,

    /// Suggests that the expression will be assigned to a local.
    assign_to_local: bool = false,

    /// This is set when targeting overloaded function parameters so that
    /// inferring literals don't return a CompileError.
    return_infer_error: bool = false,

    allow_ct_sym: bool = false,

    target_t: ?*cy.Type = null,

    pub fn initRequire(type_: *cy.Type) Cstr {
        return .{
            .target_t = type_,
            .reqTypeCstr = true,
            .fit_target = true,
            .return_infer_error = false,
        };
    }

    pub fn hasTargetType(self: Cstr) bool {
        return self.target_t != null;
    }
};

/// The depth of everything that sema stacks up in a chunk while it checks one body. With error recovery
/// (`Compiler.recover`) a body that fails is abandoned where the error was reported: `restore` drops what
/// it left behind and the compiler goes on with the next body.
/// Nothing is generated from a compile that reported an error, so the IR of the abandoned body is only dropped
/// from the list of blocks. Its memory belongs to the arena of the chunk.
pub const StackMark = struct {
    procs: usize,
    blocks: usize,
    vars: usize,
    var_shadows: usize,
    active_fields: usize,
    types: usize,
    values: usize,
    exprs: usize,
    func_params: usize,
    func_template_params: usize,
    list_data: usize,
    block_jumps: usize,
    seq_entries: usize,
    scope_start_borrows: usize,
    scope_blocks: usize,
    scope_borrows: usize,
    resolve_contexts: usize,
    ir_stmt_blocks: usize,
    ir_func_blocks: usize,
    ir_seq_pending: usize,
    cur_cont_expr: ?*ast.LambdaContExpr,
    scope_start_call: ?*ast.Node,
    scope_start_lit: ?*ast.Node,
    resolving_ct_stmts: bool,

    pub fn take(c: *cy.Chunk) StackMark {
        return .{
            .procs = c.semaProcs.items.len,
            .blocks = c.semaBlocks.items.len,
            .vars = c.varStack.items.len,
            .var_shadows = c.varShadowStack.items.len,
            .active_fields = c.active_field_stack.items.len,
            .types = c.typeStack.items.len,
            .values = c.valueStack.items.len,
            .exprs = c.expr_stack.items.len,
            .func_params = c.func_param_stack.items.len,
            .func_template_params = c.func_template_param_stack.items.len,
            .list_data = c.listDataStack.items.len,
            .block_jumps = c.blockJumpStack.items.len,
            .seq_entries = c.seq_pending.items.len,
            .scope_start_borrows = c.scope_start_borrows.items.len,
            .scope_blocks = c.scope_blocks.items.len,
            .scope_borrows = c.scope_borrows.items.len,
            .resolve_contexts = c.resolve_stack.items.len,
            .ir_stmt_blocks = c.ir.stmtBlockStack.items.len,
            .ir_func_blocks = c.ir.func_blocks.items.len,
            .ir_seq_pending = c.ir.seq_pending,
            .cur_cont_expr = c.cur_cont_expr,
            .scope_start_call = c.scope_start_call,
            .scope_start_lit = c.scope_start_lit,
            .resolving_ct_stmts = c.resolving_ct_stmts,
        };
    }

    /// A stack that is not deeper than the mark is left alone. Nothing here can fail.
    pub fn restore(self: StackMark, c: *cy.Chunk) void {
        while (c.resolve_stack.items.len > self.resolve_contexts) {
            sema_resolve.popResolveContext(c);
        }
        while (c.semaProcs.items.len > self.procs) {
            c.semaProcs.items[c.semaProcs.items.len - 1].deinit(c.alloc);
            c.semaProcs.items.len -= 1;
        }
        if (c.semaProcs.items.len > 0) {
            c.cur_sema_proc = &c.semaProcs.items[c.semaProcs.items.len - 1];
        }
        truncate(&c.semaBlocks, self.blocks);
        truncate(&c.varStack, self.vars);
        truncate(&c.varShadowStack, self.var_shadows);
        truncate(&c.active_field_stack, self.active_fields);
        truncate(&c.typeStack, self.types);
        truncate(&c.valueStack, self.values);
        truncate(&c.expr_stack, self.exprs);
        truncate(&c.func_param_stack, self.func_params);
        truncate(&c.func_template_param_stack, self.func_template_params);
        truncate(&c.listDataStack, self.list_data);
        truncate(&c.blockJumpStack, self.block_jumps);
        truncate(&c.seq_pending, self.seq_entries);
        truncate(&c.scope_start_borrows, self.scope_start_borrows);
        truncate(&c.scope_blocks, self.scope_blocks);
        truncate(&c.scope_borrows, self.scope_borrows);
        truncate(&c.ir.stmtBlockStack, self.ir_stmt_blocks);
        truncate(&c.ir.func_blocks, self.ir_func_blocks);
        c.ir.seq_pending = @min(c.ir.seq_pending, self.ir_seq_pending);
        c.seq_flushing = false;
        c.cur_cont_expr = self.cur_cont_expr;
        c.scope_start_call = self.scope_start_call;
        c.scope_start_lit = self.scope_start_lit;
        c.resolving_ct_stmts = self.resolving_ct_stmts;
        // A cancel pad is built inside one body and never across two.
        c.cancel_pad_building = false;
        c.cancel_pad_var_end = null;
        c.cancel_replay = false;
        c.cancel_replay_last = false;
    }

    pub fn truncate(list: anytype, len: usize) void {
        if (list.items.len > len) list.items.len = len;
    }
};

pub fn sema_program(c: *cy.Chunk, opt_main_func: ?*cy.Func) !*ir.Stmt {
    try sema_resolve.pushChunkResolveContext(c, null);
    defer sema_resolve.popResolveContext(c);

    const program_block = try c.ir.newStmt(.mainBlock, @ptrCast(c.ast.root), undefined);
    try c.ir.func_blocks.append(c.alloc, program_block);

    const id = try sema_local.pushProc(c, null);
    c.mainSemaProcId = id;

    // Call `@program_init`.
    const func = c.sym.getMod().getSym("@program_init").?.cast(.func).first;
    const call = try sema_call.sema_call_ir(c, func, &.{}, c.ast.null_node);
    try sema_local.sema_discard(c, call, c.ast.null_node);

    // For REPL, restore variables from previous evaluation.
    if (c.vm.config.persist_main) {
        // `VM.eval` copied each saved local into a VM-owned buffer after the previous run.
        // The new local takes the value over bitwise (a move): the buffer is not destructed, only freed,
        // when the restored local is tracked again. The saves stay intact if this compile fails.
        for (c.vm.env_local_saves.items) |save| {
            std.debug.assert(save.owned);
            const ptr_t = try getPtrType(c, save.val_t);
            const addr = try c.semaConst(@intFromPtr(save.value.ptr), ptr_t, c.ast.null_node);
            const init = try sema_expr.semaDeref(c, addr, c.ast.null_node);
            const name_dup = try c.ir.alloc.dupe(u8, save.name);
            const local_res = try sema_local.declareLocalInit(c, name_dup, save.val_t, init, c.ast.null_node);
            const local = &c.varStack.items[local_res.id];
            local.inner.local.allow_redeclare = true;
            try sema_local.semaTrackMainLocal(c, local, c.ast.null_node);
        }
    }

    if (opt_main_func) |main_func| {
        for (c.ast.root.?.stmts.slice()) |stmt| {
            switch (stmt.type()) {
                .trait_decl,
                .struct_decl,
                .cstruct_decl,
                .cunion_decl,
                .passStmt,
                .const_decl,
                .global_decl,
                .custom_type_decl,
                .type_alias_decl,
                .template,
                .enumDecl,
                .use_alias,
                .import_stmt,
                .funcDecl,
                .ct_stmt => {},
                else => {
                    return c.reportError("Body statement is not allowed when main function is declared.", stmt);
                },
            }
        }

        // Invoke main function.
        const call_main = try sema_call.sema_call_ir(c, main_func, &.{}, c.ast.null_node);
        const main_res = try sema_local.declareHiddenLocal(c, "_main_res", call_main.type, call_main, c.ast.null_node);

        // An error that `main` returns is not handled by anything. It panics, like `expr!` at the top level.
        if (call_main.type.kind() == .result) {
            const node: *ast.Node = @ptrCast(main_func.decl.?);
            const res = try sema_expr.semaLocal(c, main_res.id, node);
            const cond = try c.semaIsError(res, node);
            _ = try sema_local.pushBlock(c, node);
            {
                const err = try sema_access.semaUnwrapResultErrorNoCheck(c, res, node);
                const arg = Argument.initPreResolved(node, err);
                const panic_call = try c.semaCallFunc2(c.sema.panic_unwrap_error_fn, &.{arg}, &.{}, node);
                _ = try sema_local.declareHiddenLocal(c, "_res", c.sema.void_t, panic_call, node);
            }
            const block = try sema_local.popBlock2(c, false);
            _ = try c.ir.pushStmt(.if_block, node, .{
                .cond_expr = cond.ir,
                .body_head = block.first,
            });
        } else if (call_main.type.id() == bt.Error) {
            // `fn main() -> error` has no value case. What it returns is an error that nothing handles.
            const node: *ast.Node = @ptrCast(main_func.decl.?);
            const err = try sema_expr.semaLocal(c, main_res.id, node);
            const arg = Argument.initPreResolved(node, err);
            const panic_call = try c.semaCallFunc2(c.sema.panic_unwrap_error_fn, &.{arg}, &.{}, node);
            _ = try sema_local.declareHiddenLocal(c, "_res", c.sema.void_t, panic_call, node);
        }

        // Skip deinit of main result.
        c.varStack.items[main_res.id].type = .dead;

        try sema_program_deinit(c);
    } else {
        const stmts = c.ast.root.?.stmts.slice();
        if (c.vm.config.persist_main and stmts.len > 0 and stmts[stmts.len - 1].type() == .exprStmt) {
            // REPL: the last expression's value is the eval result.
            try sema_stmt.semaStmts(c, stmts[0 .. stmts.len - 1]);
            try sema_local.semaMainResultStmt(c, stmts[stmts.len - 1]);
        } else {
            try sema_stmt.semaStmts(c, stmts);
        }
        if (c.vm.config.persist_main and c.block().endReachable) try sema_move.semaUntrackMovedMainLocals(c);

        var destruct_locals = true;
        if (c.block().endReachable) {
            // Main locals are destructed before `@program_deinit` releases the globals, in the same order
            // as `return` in main (`semaReturn`). A local's `@deinit` may still read the globals.
            if (sema_local.shouldGenMainScopeReleaseOps(c.compiler)) {
                try sema_local.semaDestructBlock(c);
                destruct_locals = false;
            }
            try sema_program_deinit(c);
        }
        const stmtBlock = try sema_local.popProc2(c, destruct_locals);
        program_block.cast(.mainBlock).* = .{
            .bodyHead = stmtBlock.first,
        };
        return program_block;
    }

    const stmtBlock = try sema_local.popProc(c);

    log.tracev("pop main block", .{});

    program_block.cast(.mainBlock).* = .{
        .bodyHead = stmtBlock.first,
    };
    return program_block;
}

pub const FuncSigId = u32;

pub const FuncParam = packed struct {
    type_ptr: u63,
    sink: bool,

    pub fn init(type_: *cy.Type) FuncParam {
        return .{ .type_ptr = @intCast(@intFromPtr(type_)), .sink = false };
    }

    pub fn init2(type_: *cy.Type, sink: bool) FuncParam {
        return .{ .type_ptr = @intCast(@intFromPtr(type_)), .sink = sink };
    }

    pub fn get_type(self: *const FuncParam) *cy.Type {
        const addr: usize = @intCast(self.type_ptr);
        return @ptrFromInt(addr);
    }
};

/// Turning this into to packed struct fails web-lib ReleaseFast strip=true,
/// however, it seems an inner packed struct `info` works.
pub const FuncSig = struct {
    /// Last elem is the return type sym.
    params_ptr: [*]const FuncParam,
    ret: *cy.Type,
    id: u32,
    params_len: u16,
    extern_: bool,
    scope_param_idx: u8,

    /// If a param or the return type is not the any type.
    // isTyped: bool,

    /// If a param is not the any type.
    // isParamsTyped: bool,

    pub inline fn params(self: FuncSig) []const FuncParam {
        return self.params_ptr[0..self.params_len];
    }

    pub inline fn numParams(self: FuncSig) u8 {
        return @intCast(self.params_len);
    }

    pub inline fn getRetType(self: FuncSig) *cy.Type {
        return self.ret;
    }

    pub fn deinit(self: *FuncSig, alloc: std.mem.Allocator) void {
        alloc.free(self.params());
    }
};

const FuncSigKey = struct {
    params_ptr: [*]const FuncParam,
    params_len: u32,
    ret: *cy.Type,
    extern_: bool,
    scope_param_idx: u8,
};

const BuiltinSymType = enum(u8) {
    bool_t,
    int_t,
    float_t,
};

const ExternVariantKey = struct {
    func: *cy.Func,
    sig: *cy.FuncSig,
};

pub const PartialStructLayout = struct {
    fields: []bool,

    pub fn deinit(self: *PartialStructLayout, alloc: std.mem.Allocator) void {
        alloc.free(self.fields);
    }
};

pub const Sema = struct {
    alloc: std.mem.Allocator,
    compiler: *cy.Compiler,

    /// This is used to perform a Type lookup by ID and to destroy the types.
    types: std.ArrayList(*cy.Type),

    /// Distinct partial layouts.
    partial_struct_layouts: std.HashMapUnmanaged([]bool, *PartialStructLayout, PartialStructLayoutContext, 80),

    /// Resolved signatures for functions.
    func_sigs: std.ArrayList(*FuncSig),
    func_sig_map: std.HashMapUnmanaged(FuncSigKey, FuncSigId, FuncSigKeyContext, 80),

    symbols: std.ArrayList([]const u8),
    symbols_map: std.StringHashMapUnmanaged(u64),

    object_t: *cy.Type = &cy.types.NullType,
    table_t: *cy.Type = &cy.types.NullType,
    bool_t: *cy.Type = &cy.types.NullType,
    eval_int_t: *cy.Type = &cy.types.NullType,
    eval_str_t: *cy.Type = &cy.types.NullType,
    i8_t: *cy.Type = &cy.types.NullType,
    i16_t: *cy.Type = &cy.types.NullType,
    i32_t: *cy.Type = &cy.types.NullType,
    i64_t: *cy.Type = &cy.types.NullType,
    r8_t: *cy.Type = &cy.types.NullType,
    r16_t: *cy.Type = &cy.types.NullType,
    r32_t: *cy.Type = &cy.types.NullType,
    r64_t: *cy.Type = &cy.types.NullType,
    rsize_t: *cy.Type = &cy.types.NullType,
    f64_t: *cy.Type = &cy.types.NullType,
    f32_t: *cy.Type = &cy.types.NullType,
    str_buffer_t: *cy.Type = &cy.types.NullType,
    str_t: *cy.Type = &cy.types.NullType,
    mut_str_t: *cy.Type = &cy.types.NullType,
    void_t: *cy.Type = &cy.types.NullType,
    never_t: *cy.Type = &cy.types.NullType,
    type_t: *cy.Type = &cy.types.NullType,
    partial_struct_layout_t: *cy.Type = &cy.types.NullType,
    code_t: *cy.Type = &cy.types.NullType,
    error_t: *cy.Type = &cy.types.NullType,
    symbol_t: *cy.Type = &cy.types.NullType,
    funcsig_t: *cy.Type = &cy.types.NullType,
    range_t: *cy.Type = &cy.types.NullType,
    any_t: *cy.Type = &cy.types.NullType,
    dependent_t: *cy.Type = &cy.types.NullType,
    infer_t: *cy.Type = &cy.types.NullType,

    // Consider removing the following after inlining stack values.
    option_int_t: *cy.Type = &cy.types.NullType,
    ptr_span_byte_t: *cy.Type = &cy.types.NullType,

    ptr_int_t: *cy.Type = &cy.types.NullType,
    ptr_void_t: *cy.Type = &cy.types.NullType,
    raw_buffer_byte_t: *cy.Type = &cy.types.NullType,
    generator_tmpl: *cy.sym.Template,
    int_tmpl: *cy.sym.Template,
    float_tmpl: *cy.sym.Template,
    fn_tuple_tmpl: *cy.sym.Template,
    future_tmpl: *cy.sym.Template,
    slice_tmpl: *cy.sym.Template,
    span_tmpl: *cy.sym.Template,
    as_span_tmpl: *cy.sym.Template,
    array_tmpl: *cy.sym.Template,
    map_tmpl: *cy.sym.Template,
    hash_map_tmpl: *cy.sym.Template,
    ptr_span_tmpl: *cy.sym.Template,
    va_list_tmpl: *cy.sym.Template,
    option_tmpl: *cy.sym.Template,
    ptr_tmpl: *cy.sym.Template,
    ref_tmpl: *cy.sym.Template,
    borrow_tmpl: *cy.sym.Template,
    ex_borrow_tmpl: *cy.sym.Template,
    table_type: *cy.sym.TypeSym,
    generic_vector_tmpl: *cy.sym.Template,
    vector_tmpl: *cy.sym.Template,
    partial_vector_tmpl: *cy.sym.Template,
    func_ptr_tmpl: *cy.sym.Template,
    func_tmpl: *cy.sym.Template,
    opaque_func_tmpl: *cy.sym.Template,
    func_sym_tmpl: *cy.sym.Template,
    raw_buffer_tmpl: *cy.sym.Template,
    buffer_tmpl: *cy.sym.Template,
    eval_buffer_tmpl: *cy.sym.Template,
    ref_child_tmpl: *cy.sym.Template,
    result_tmpl: *cy.sym.Template,
    copy_fn: *cy.Func = undefined,
    partial_dtor_fn: *cy.Func = undefined,
    dtor_fn: *cy.Func = undefined,
    eq_fn: *cy.Func = undefined,
    deinit_obj_tmpl: *cy.sym.FuncTemplate = undefined,
    destruct_box_fn: ?*cy.Func = null,
    panic_fn: *cy.Func = undefined,
    panic_unwrap_error_fn: *cy.Func = undefined,
    track_main_local_fn: *cy.Func = undefined,
    untrack_main_local_fn: *cy.Func = undefined,
    main_result_fn: *cy.Func = undefined,
    scope_new_fn: *cy.Func = undefined,
    scope_abort_fn: *cy.Func = undefined,
    scope_join_fn: *cy.Func = undefined,
    /// `Scope.start`.
    scope_start_sym: *cy.sym.FuncSym = undefined,
    /// `spawn`, which `deny_spawn` rejects.
    spawn_sym: *cy.sym.FuncSym = undefined,
    /// `print` and the functions like it, which do not take a `!T` (`checkPrintCall`).
    print_syms: [6]*cy.sym.FuncSym = undefined,
    to_print_string_fn: *cy.Func = undefined,
    access_fn: *cy.Func = undefined,
    builtin_sig: *FuncSig = undefined,

    vm_c_variadic_funcs: std.AutoHashMapUnmanaged(ExternVariantKey, *cy.Func),

    pub fn init(alloc: std.mem.Allocator, compiler: *cy.Compiler) !Sema {
        var new = Sema{
            .alloc = alloc,
            .compiler = compiler,
            .generator_tmpl = undefined,
            .future_tmpl = undefined,
            .ptr_span_tmpl = undefined,
            .va_list_tmpl = undefined,
            .option_tmpl = undefined,
            .int_tmpl = undefined,
            .float_tmpl = undefined,
            .fn_tuple_tmpl = undefined,
            .ptr_tmpl = undefined,
            .ref_tmpl = undefined,
            .borrow_tmpl = undefined,
            .ex_borrow_tmpl = undefined,
            .slice_tmpl = undefined,
            .span_tmpl = undefined,
            .as_span_tmpl = undefined,
            .array_tmpl = undefined,
            .map_tmpl = undefined,
            .hash_map_tmpl = undefined,
            .table_type = undefined,
            .vector_tmpl = undefined,
            .generic_vector_tmpl = undefined,
            .partial_vector_tmpl = undefined,
            .func_ptr_tmpl = undefined,
            .func_tmpl = undefined,
            .opaque_func_tmpl = undefined,
            .func_sym_tmpl = undefined,
            .raw_buffer_tmpl = undefined,
            .buffer_tmpl = undefined,
            .eval_buffer_tmpl = undefined,
            .result_tmpl = undefined,
            .ref_child_tmpl = undefined,
            .func_sigs = .empty,
            .func_sig_map = .empty,
            .types = .empty,
            .partial_struct_layouts = .empty,
            .symbols = .empty,
            .symbols_map = .empty,
            .vm_c_variadic_funcs = .empty,
        };

        // Reserve the null type.
        const id = try new.reserveType();
        std.debug.assert(id == 0);
        std.debug.assert(new.types.items[id].kind() == .null);

        return new;
    }

    pub fn deinit(self: *Sema, alloc: std.mem.Allocator, comptime reset: bool) void {
        for (self.func_sigs.items) |it| {
            it.deinit(alloc);
            alloc.destroy(it);
        }

        for (self.types.items[1..]) |type_| {
            type_.destroy(alloc);
        }

        var iter = self.partial_struct_layouts.iterator();
        while (iter.next()) |e| {
            e.value_ptr.*.deinit(alloc);
            alloc.destroy(e.value_ptr.*);
        }

        for (self.symbols.items) |name| {
            self.alloc.free(name);
        }
        if (reset) {
            self.types.items.len = 1;
            self.partial_struct_layouts.clearRetainingCapacity();
            self.func_sigs.clearRetainingCapacity();
            self.func_sig_map.clearRetainingCapacity();
            self.symbols.clearRetainingCapacity();
            self.symbols_map.clearRetainingCapacity();
            self.vm_c_variadic_funcs.clearRetainingCapacity();
        } else {
            self.types.deinit(alloc);
            self.partial_struct_layouts.deinit(alloc);
            self.func_sigs.deinit(alloc);
            self.func_sig_map.deinit(alloc);
            self.symbols.deinit(alloc);
            self.symbols_map.deinit(alloc);
            self.vm_c_variadic_funcs.deinit(alloc);
        }
    }

    pub fn initSymbol(self: *Sema, name: []const u8) !Value {
        const id = try self.ensureSymbol(name);
        return Value.initInt(@intCast(id));
    }

    pub fn ensureSymbol(self: *Sema, name: []const u8) !u64 {
        const res = try self.symbols_map.getOrPut(self.alloc, name);
        if (!res.found_existing) {
            const id: u64 = @intCast(self.symbols.items.len);
            const dupe = try self.alloc.dupe(u8, name);
            try self.symbols.append(self.alloc, dupe);
            res.value_ptr.* = id;
            res.key_ptr.* = dupe;
            return id;
        } else {
            return res.value_ptr.*;
        }
    }

    pub fn ensureFuncSig(s: *Sema, params: []const FuncParam, ret: *cy.Type) !*FuncSig {
        return s.ensureFuncSig2(params, ret, false, null);
    }

    pub fn ensureFuncSig2(s: *Sema, params: []const FuncParam, ret: *cy.Type, extern_: bool, scope_param_idx: ?u8) !*FuncSig {
        const res = try s.func_sig_map.getOrPut(s.alloc, .{
            .params_ptr = params.ptr,
            .params_len = @intCast(params.len),
            .ret = ret,
            .extern_ = extern_,
            .scope_param_idx = scope_param_idx orelse cy.NullU8,
        });
        if (res.found_existing) {
            return s.func_sigs.items[res.value_ptr.*];
        } else {
            // The new entry's key still points at the caller's `params`. It leaves the map unless the sig is created.
            errdefer s.func_sig_map.removeByPtr(res.key_ptr);
            try s.func_sigs.ensureUnusedCapacity(s.alloc, 1);
            const id: u32 = @intCast(s.func_sigs.items.len);
            const new = try s.alloc.dupe(FuncParam, params);
            errdefer s.alloc.free(new);
            const sig = try s.alloc.create(FuncSig);
            sig.* = .{
                .params_ptr = new.ptr,
                .params_len = @intCast(new.len),
                .id = id,
                .ret = ret,
                .extern_ = extern_,
                .scope_param_idx = scope_param_idx orelse cy.NullU8,
            };
            s.func_sigs.appendAssumeCapacity(sig);
            res.value_ptr.* = id;
            res.key_ptr.* = .{
                .params_ptr = new.ptr,
                .params_len = @intCast(new.len),
                .ret = ret,
                .extern_ = extern_,
                .scope_param_idx = scope_param_idx orelse cy.NullU8,
            };
            return sig;
        }
    }

    pub fn formatFuncSig(s: *Sema, sig: *FuncSig, buf: []u8, from: ?*cy.Chunk) ![]const u8 {
        var w = std.Io.Writer.fixed(buf);
        try s.writeFuncSigStr(&w, sig, from);
        return w.buffered();
    }

    /// Format: (Type, ...) RetType
    pub fn getFuncSigTempStr(s: *Sema, buf: *std.ArrayList(u8), funcSigId: FuncSigId) ![]const u8 {
        buf.clearRetainingCapacity();
        var w: std.Io.Writer.Allocating = .fromArrayList(s.alloc, buf);
        const res = s.writeFuncSigStr(&w.writer, s.getFuncSig(funcSigId), null);
        buf.* = w.toArrayList();
        try res;
        return buf.items;
    }

    pub fn allocFuncSigStr(s: *Sema, sig: *FuncSig, show_ret: bool, from: ?*cy.Chunk) ![]const u8 {
        var buf = std.Io.Writer.Allocating.init(s.alloc);
        defer buf.deinit();
        const w = &buf.writer;

        try w.writeAll("(");
        try writeFuncParams(s, w, sig.params(), sig.scope_param_idx, from);
        try w.writeAll(")");
        if (show_ret) {
            try w.writeAll(" -> ");
            if (sig.scope_param_idx != cy.NullU8) {
                try w.writeAll("scope ");
            }
            try s.writeTypeName(w, sig.ret, from);
        }
        return buf.toOwnedSlice();
    }

    pub fn writeFuncSigStr(s: *Sema, w: *std.Io.Writer, sig: *FuncSig, from: ?*cy.Chunk) !void {
        try w.writeAll("(");
        try writeFuncParams(s, w, sig.params(), sig.scope_param_idx, from);
        try w.writeAll(") -> ");
        if (sig.scope_param_idx != cy.NullU8) {
            try w.writeAll(") -> scope ");
        }
        try s.writeTypeName(w, sig.ret, from);
    }

    pub fn writeFuncSigTypesStr(s: *Sema, w: anytype, params: []const FuncParam, ret: *cy.Type, from: ?*cy.Chunk) !void {
        try w.writeAll("(");
        try writeFuncParams(s, w, params, cy.NullU8, from);
        try w.writeAll(") -> ");
        try s.writeTypeName(w, ret, from);
    }

    pub fn writeFuncParams(s: *Sema, w: *std.Io.Writer, params: []const FuncParam, scope_param_idx: u8, from: ?*cy.Chunk) !void {
        if (params.len > 0) {
            if (scope_param_idx == 0) {
                try w.writeAll("scope ");
            } else if (params[0].sink) {
                try w.writeAll("sink ");
            }

            try s.writeTypeName(w, params[0].get_type(), from);

            for (params[1..], 1..) |param, i| {
                try w.writeAll(", ");
                if (scope_param_idx == i) {
                    try w.writeAll("scope ");
                } else if (param.sink) {
                    try w.writeAll("sink ");
                }
                try s.writeTypeName(w, param.get_type(), from);
            }
        }
    }

    pub inline fn getFuncSig(self: *Sema, id: FuncSigId) *FuncSig {
        return self.func_sigs.items[id];
    }

    pub const getType = cy.types.getType;
    pub const allocTypeName = cy.types.allocTypeName;
    pub const allocSymName = cy.types.allocSymName;
    pub const reserveType = cy.types.reserveType;
    pub const getRtCompareType = cy.types.getRtCompareType;
    pub const createTypeWithId = cy.types.createTypeWithId;
    pub const createType = cy.types.createType;
    pub const writeTypeName = cy.types.writeTypeName;

    pub const newFuncName = cy.sym.newFuncName;
};

pub const PartialStructLayoutContext = struct {
    pub fn hash(_: @This(), key: []bool) u64 {
        var c = std.hash.Wyhash.init(0);
        c.update(std.mem.sliceAsBytes(key));
        return c.final();
    }
    pub fn eql(_: @This(), a: []bool, b: []bool) bool {
        return std.mem.eql(bool, a, b);
    }
};

pub const FuncSigKeyContext = struct {
    pub fn hash(_: @This(), key: FuncSigKey) u64 {
        var c = std.hash.Wyhash.init(0);
        const bytes: [*]const u8 = @ptrCast(key.params_ptr);
        c.update(bytes[0..key.params_len*4]);
        c.update(std.mem.asBytes(&key.ret));
        c.update(std.mem.asBytes(&key.extern_));
        c.update(std.mem.asBytes(&key.scope_param_idx));
        return c.final();
    }
    pub fn eql(_: @This(), a: FuncSigKey, b: FuncSigKey) bool {
        if (!std.mem.eql(*cy.Type, @ptrCast(a.params_ptr[0..a.params_len]), @ptrCast(b.params_ptr[0..b.params_len]))) {
            return false;
        }
        if (a.ret != b.ret) {
            return false;
        }
        return a.extern_ == b.extern_ and a.scope_param_idx == b.scope_param_idx;
    }
};

test "sema internals." {
    // `Local` holds a bare union, which carries a hidden tag only with runtime safety.
    // The borrow tracking fields (`active_ex_borrows`, `ex_borrow`) added a word in 2026-11 (F-25).
    // `LocalVarS.init_node` (where a value came from, for error hints) added a pointer in 2026-11.
    // `borrow_via`, `borrow_alias`, `borrow_field` and `borrow_inline` (the use of an exclusive borrow, F-167) added
    // two `LocalId`, a `u16` and a `bool` in 2026-11.
    if (cy.is32Bit) {
        try t.eq(if (std.debug.runtime_safety) 60 else 56, @sizeOf(Local));
        try t.eq(16, @sizeOf(FuncSig));
    } else {
        try t.eq(if (std.debug.runtime_safety) 80 else 72, @sizeOf(Local));
        try t.eq(24, @sizeOf(FuncSig));
    }
}

/// TODO: Cache this by `elem_t`.
pub fn getPtrType(c: *cy.Chunk, child_t: *cy.Type) !*cy.Type {
    const arg = cy.Value.initType(child_t);
    const sym = try cy.template.expand_template(c, c.sema.ptr_tmpl, &.{c.sema.type_t}, &.{ arg });
    return sym.getStaticType().?;
}

pub fn get_ptr_span_type(c: *cy.Chunk, elem_t: *cy.Type) !*cy.Type {
    const arg = cy.Value.initType(elem_t);
    const sym = try cy.template.expand_template(c, c.sema.ptr_span_tmpl, &.{c.sema.type_t}, &.{ arg });
    return sym.getStaticType().?;
}

pub fn getRefType(c: *cy.Chunk, child_t: *cy.Type) !*cy.Type {
    const arg = cy.Value.initType(child_t);
    const sym = try cy.template.expand_template(c, c.sema.ref_tmpl, &.{c.sema.type_t}, &.{ arg });
    return sym.getStaticType().?;
}

pub fn getResultType(c: *cy.Chunk, child_t: *cy.Type) !*cy.Type {
    const arg = cy.Value.initType(child_t);
    const sym = try cy.template.expand_template(c, c.sema.result_tmpl, &.{c.sema.type_t}, &.{ arg });
    return sym.getStaticType().?;
}

pub fn getOptionType(c: *cy.Chunk, child_t: *cy.Type) !*cy.Type {
    const arg = cy.Value.initType(child_t);
    const sym = try cy.template.expand_template(c, c.sema.option_tmpl, &.{c.sema.type_t}, &.{ arg });
    return sym.getStaticType().?;
}

pub fn get_ex_borrow_type(c: *cy.Chunk, child_t: *cy.Type) !*cy.Type {
    const arg = cy.Value.initType(child_t);
    const sym = try cy.template.expand_template(c, c.sema.ex_borrow_tmpl, &.{c.sema.type_t}, &.{ arg });
    return sym.getStaticType().?;
}

pub fn getBorrowType(c: *cy.Chunk, child_t: *cy.Type) !*cy.Type {
    const arg = cy.Value.initType(child_t);
    const sym = try cy.template.expand_template(c, c.sema.borrow_tmpl, &.{c.sema.type_t}, &.{ arg });
    return sym.getStaticType().?;
}

pub fn getFuncPtrType(c: *cy.Chunk, sig: *FuncSig) !*cy.Type {
    const arg = cy.Value.initFuncSig(sig);
    const sym = try cy.template.expand_template(c, c.sema.func_ptr_tmpl, &.{c.sema.funcsig_t}, &.{ arg });
    return sym.getStaticType().?;
}

pub fn getOpaqueFuncType(c: *cy.Chunk, funcptr_t: *cy.Type) !*cy.Type {
    const arg = cy.Value.initType(funcptr_t);
    const sym = try cy.template.expand_template(c, c.sema.opaque_func_tmpl, &.{c.sema.type_t}, &.{ arg });
    return sym.getStaticType().?;
}

pub fn getFuncType(c: *cy.Chunk, funcptr_t: *cy.Type) !*cy.Type {
    const arg = cy.Value.initType(funcptr_t);
    const sym = try cy.template.expand_template(c, c.sema.func_tmpl, &.{c.sema.type_t}, &.{ arg });
    return sym.getStaticType().?;
}

pub fn getFuncSymType(c: *cy.Chunk, sig: *FuncSig) !*cy.Type {
    const arg = cy.Value.initFuncSig(sig);
    const sym = try cy.template.expand_template(c, c.sema.func_sym_tmpl, &.{c.sema.funcsig_t}, &.{ arg });
    return sym.getStaticType().?;
}

pub fn getGeneratorType(c: *cy.Chunk, arg_t: *cy.Type) !*cy.Type {
    const arg = cy.Value.initType(arg_t);
    const sym = try cy.template.expand_template(c, c.sema.generator_tmpl, &.{c.sema.type_t}, &.{ arg });
    return sym.getStaticType().?;
}

pub fn get_span_type(c: *cy.Chunk, elem_t: *cy.Type) !*cy.Type {
    const elem = cy.Value.initType(elem_t);
    const sym = try cy.template.expand_template(c, c.sema.span_tmpl, &.{c.sema.type_t}, &.{ elem });
    return sym.getStaticType().?;
}

pub fn get_slice_type(c: *cy.Chunk, elem_t: *cy.Type) !*cy.Type {
    const elem = cy.Value.initType(elem_t);
    const sym = try cy.template.expand_template(c, c.sema.slice_tmpl, &.{c.sema.type_t}, &.{ elem });
    return sym.getStaticType().?;
}

pub fn getArrayType(c: *cy.Chunk, elem_t: *cy.Type) !*cy.Type {
    const elem = cy.Value.initType(elem_t);
    const sym = try cy.template.expand_template(c, c.sema.array_tmpl, &.{c.sema.type_t}, &.{ elem });
    return sym.getStaticType().?;
}

pub fn getMapType(c: *cy.Chunk, key_t: *cy.Type, val_t: *cy.Type) !*cy.Type {
    const key = cy.Value.initType(key_t);
    const val = cy.Value.initType(val_t);
    const sym = try cy.template.expand_template(c, c.sema.map_tmpl, &.{c.sema.type_t, c.sema.type_t}, &.{ key, val });
    return sym.getStaticType().?;
}

pub fn getVectorType(c: *cy.Chunk, elem_t: *cy.Type, n: i64) !*cy.Type {
    const n_arg = cy.Value.initInt(n);
    const elem_arg = cy.Value.initType(elem_t);
    const sym = try cy.template.expand_template(c, c.sema.vector_tmpl, &.{c.sema.type_t, c.sema.i64_t}, &.{ elem_arg, n_arg });
    return sym.getStaticType().?;
}

pub fn getEqFunc(c: *cy.Chunk, type_: *cy.Type, node: ?*ast.Node) !*cy.Func {
    const param = cy.Value.initType(type_);
    const func = try cy.template.expandFuncTemplate(c, c.sema.eq_fn.data.generic, &.{c.sema.type_t}, &.{param}, node);
    return func;
}

pub fn getCopyFunc(c: *cy.Chunk, type_: *cy.Type, node: *ast.Node) !*cy.Func {
    return type_.copy_ctor orelse {
        const param = cy.Value.initType(type_);
        const func = try cy.template.expandFuncTemplate(c, c.sema.copy_fn.data.generic, &.{c.sema.type_t}, &.{param}, node);
        type_.copy_ctor = func;
        return func;
    };
}

pub fn get_partial_dtor(c: *cy.Chunk, type_: *cy.Type, layout: *PartialStructLayout, node: *ast.Node) !*cy.Func {
    const arg0 = cy.Value.initType(type_);
    const arg1 = cy.Value.initPtr(layout);
    const func = try cy.template.expandFuncTemplate(c, c.sema.partial_dtor_fn.data.generic, &.{c.sema.type_t, c.sema.partial_struct_layout_t}, &.{arg0, arg1}, node);
    return func;
}

pub fn getDtorFunc(c: *cy.Chunk, type_: *cy.Type, node: *ast.Node) !*cy.Func {
    return type_.dtor orelse {
        const param = cy.Value.initType(type_);
        const func = try cy.template.expandFuncTemplate(c, c.sema.dtor_fn.data.generic, &.{c.sema.type_t}, &.{param}, node);
        type_.dtor = func;
        return func;
    };
}

pub fn getDeinitObjFunc(c: *cy.Chunk, type_: *cy.Type, node: *ast.Node) !*cy.Func {
    return type_.deinit_obj orelse {
        const param = cy.Value.initType(type_);
        const func = try cy.template.expandFuncTemplate(c, c.sema.deinit_obj_tmpl, &.{c.sema.type_t}, &.{param}, node);
        type_.deinit_obj = func;
        return func;
    };
}

pub fn getToPrintStringFunc(c: *cy.Chunk, type_: *cy.Type, node: *ast.Node) !*cy.Func {
    const param = cy.Value.initType(type_);
    const func = try cy.template.expandFuncTemplate(c, c.sema.to_print_string_fn.data.generic, &.{c.sema.type_t}, &.{param}, node);
    return func;
}
