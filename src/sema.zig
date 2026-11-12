const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const stdx = @import("stdx");
const t = stdx.testing;
const cy = @import("cyber.zig");
const C = @import("capi.zig");
const ir = cy.ir;
const vmc = @import("vmc");
const rt = cy.rt;
const bt = cy.types.BuiltinTypes;
const Nullable = cy.Nullable;
const sema = @This();
const sema_func = cy.sema_func;
const sema_type = cy.sema_type;
const ct_inline = cy.ct_inline;

/// TODO: Move use sites to sema_func.
const Argument = cy.sema_func.Argument;

const cte = cy.cte;
const fmt = cy.fmt;
const v = fmt.v;
const module = cy.module;
const ast = cy.ast;

const ChunkId = cy.chunk.ChunkId;
const TypeId = cy.types.TypeId;
const Sym = cy.Sym;
const Value = cy.Value;
const TypeValue = cy.TypeValue;

const vm_ = @import("vm.zig");

const log = cy.log.scoped(.sema);

pub const LocalId = u32;

const LocalVarType = enum(u8) {
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
};

const LifetimeKind = enum {
    block,

    /// Temporary, usually an rvalue that.
    temp,

    /// Continues to live beyond after function returns.
    inout,
};

const Lifetime = struct {
    kind: LifetimeKind,

    /// Relevant when `kind == .block`.
    block_depth: u8 = undefined,

    fn initTemp() Lifetime {
        return .{
            .kind = .temp,
        };
    }

    fn initBlock(depth: u8) Lifetime {
        return .{
            .kind = .block,
            .block_depth = depth,
        };
    }
};

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

/// Lowering target of a `try` block. See `sema_try_stmt`.
pub const TryCtx = struct {
    /// Sema block of the `try` body. `!` breaks out of it on failure.
    body_block: BlockId,
    /// Hidden `error` local that carries the failure to the `else` block.
    err_local: LocalId,
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

    fn getReturnType(self: *const Proc, s: *Sema) *cy.Type {
        if (self.func) |func| {
            return func.sig.ret;
        } else {
            return s.object_t;
        }
    }
};

pub const ModFuncSigKey = cy.hash.KeyU128;
const ObjectMemberKey = cy.hash.KeyU64;

pub fn semaStmts(c: *cy.Chunk, stmts: []const *ast.Node) anyerror!void {
    for (stmts) |stmt| {
        try semaStmt(c, stmt);
    }
}

fn popLocals(c: *cy.Chunk, var_start: usize, node: *ast.Node) !void {
    return popLocals2(c, var_start, true, node);
}

/// The local that owns the value an expression borrows from. Borrow locals are followed to their owner,
/// so `r := &a; x := r` and `&r.field` all resolve to `a`.
pub fn borrowOwner(c: *cy.Chunk, expr: ExprResult) ?LocalId {
    const parent = expr.recParentLocal() orelse return null;
    return borrowOwnerOf(c, parent);
}

pub fn borrowOwnerOf(c: *cy.Chunk, local: LocalId) LocalId {
    var owner = local;
    while (c.varStack.items[owner].parent_local != cy.NullId) {
        owner = c.varStack.items[owner].parent_local;
    }
    return owner;
}

/// Records that the local `var_idx` holds the borrow `init` until it goes out of scope.
fn bindBorrowLocal(c: *cy.Chunk, var_idx: LocalId, init: ExprResult) void {
    const decl_t = c.varStack.items[var_idx].decl_t;
    if (!decl_t.info.borrow_only) return;
    const owner = borrowOwner(c, init) orelse return;
    if (owner == var_idx) return;
    const ex = decl_t.kind() == .ex_borrow;
    const local = &c.varStack.items[var_idx];
    local.parent_local = owner;
    local.ex_borrow = ex;
    if (ex) {
        c.varStack.items[owner].active_ex_borrows += 1;
    } else {
        c.varStack.items[owner].active_borrows += 1;
    }
}

fn unbindBorrowLocal(c: *cy.Chunk, local: *Local) void {
    if (local.parent_local == cy.NullId) return;
    const owner = &c.varStack.items[local.parent_local];
    if (local.ex_borrow) {
        owner.active_ex_borrows -= 1;
    } else {
        owner.active_borrows -= 1;
    }
    local.parent_local = cy.NullId;
    local.ex_borrow = false;
}

/// A shared borrow (`&a`, `&self`) is not allowed while a local holds an exclusive borrow of the owner.
pub fn checkSharedBorrow(c: *cy.Chunk, owner: LocalId, node: *ast.Node) !void {
    if (c.varStack.items[owner].active_ex_borrows > 0) {
        const name = c.varStack.items[owner].name();
        return c.reportErrorFmt("Cannot borrow `{}`. There is an active exclusive borrow to it.", &.{v(name)}, node);
    }
}

/// An exclusive borrow (`&&a`, `&&self`) is not allowed while a local holds any borrow of the owner.
pub fn checkExclusiveBorrow(c: *cy.Chunk, owner: LocalId, node: *ast.Node) !void {
    const local = c.varStack.items[owner];
    if (local.active_borrows > 0 or local.active_ex_borrows > 0) {
        return c.reportErrorFmt("Expected exclusive access. There is another active borrow to `{}`.", &.{v(local.name())}, node);
    }
}

/// A borrow assigned to a local can not come from a value that dies before the local does.
fn checkBorrowOutlives(c: *cy.Chunk, var_idx: LocalId, right: ExprResult, node: *ast.Node) !void {
    if (!c.varStack.items[var_idx].decl_t.info.borrow_only) return;
    const owner = borrowOwner(c, right) orelse return;
    if (owner == var_idx) return;
    const owner_local = c.varStack.items[owner];
    const local = c.varStack.items[var_idx];
    if (owner_local.lifetime.kind == .temp) {
        return c.reportError("The result can not borrow from a temporary value.", node);
    }
    if (owner_local.lifetime.kind == .block and local.lifetime.kind == .block and
        owner_local.lifetime.block_depth > local.lifetime.block_depth) {
        return c.reportErrorFmt("`{}` can not outlive `{}`.", &.{v(local.name()), v(owner_local.name())}, node);
    }
}

fn popLocals2(c: *cy.Chunk, var_start: usize, destruct: bool, node: *ast.Node) !void {
    if (c.varStack.items.len <= var_start) {
        return;
    }

    // try semaTraceNopFmt(c, "pop locals destruct: {s}", .{@tagName(node.type())}, node);
    var i: usize = c.varStack.items.len;
    while (i > var_start) {
        i -= 1;
        const local = &c.varStack.items[i];

        // Release the borrow this local held.
        unbindBorrowLocal(c, local);

        if (destruct) {
            if (local.type == .local) {
                try semaDestructLocal(c, local, node);
                continue;
            }
            if (local.type == .dead) {
                continue;
            }
            std.debug.panic("Unexpected {}", .{local.type});
        }
    }

    _ = try c.ir.pushStmt(.pop_locals, node, .{ .local_end = var_start - c.cur_sema_proc.varStart });
    c.varStack.items.len = var_start;
}

fn semaExprStmt(c: *cy.Chunk, node: *ast.Node) !void {
    const var_start = c.varStack.items.len;
    const expr = try c.semaExpr(node, .{});
    try semaExprStmtEnd(c, expr, var_start, node);
}

/// The statement part of an expression statement, after the expression itself was analyzed.
fn semaExprStmtEnd(c: *cy.Chunk, expr: ExprResult, var_start: usize, node: *ast.Node) !void {
    if (expr.resType == .ct_value and expr.data.ct_value.type.id() == bt.Void) {
        return;
    }

    if (expr.type.id() != bt.Void and expr.type.id() != bt.Never) {
        const name = try c.sema.allocTypeName(expr.type);
        defer c.alloc.free(name);

        if (expr.type.kind() == .result) {
            return c.reportErrorFmt("Expected to handle the error case for `{}`.", &.{v(name)}, node);
        } else {
            return c.reportErrorFmt("Expected assignment to a variable or placeholder for `{}`.", &.{v(name)}, node);
        }
    }

    _ = try c.ir.pushStmt(.discard, node, .{ .expr = expr.ir });
    if (expr.type.id() == bt.Never) {
        c.block().endReachable = false;
        // A `never` call does not return, so destructing its temporaries would be dead code.
        try popLocals2(c, var_start, false, node);
        return;
    }
    try popLocals(c, var_start, node);
}

pub fn semaStmt(c: *cy.Chunk, node: *ast.Node) !void {
    c.curNode = node;

    // Expected start in `varStack` for each statement.
    var exp_var_start: usize = undefined;
    if (cy.Trace) {
        exp_var_start = c.varStack.items.len;
        const node_str = c.encoder.formatTrunc(node);
        log.tracev("stmt.{s}: \"{s}\"", .{@tagName(node.type()), node_str});
    }
    c.cur_cont_expr = null;

    // NOTE: For now, we allow statements after unreachable for convenience.
    // if (c.semaBlocks.items.len > 0 and !c.block().endReachable) {
    //     return c.reportError("Unreachable statement.", node);
    // }

    switch (node.type()) {
        .exprStmt => {
            const stmt = node.cast(.exprStmt);
            try semaExprStmt(c, stmt.child);
        },
        .breakStmt => {
            const var_start = c.varStack.items.len;
            try semaBreak(c, node);
            try popLocals2(c, var_start, false, node);
        },
        .continueStmt => {
            const var_start = c.varStack.items.len;
            try semaContinue(c, node);
            try popLocals2(c, var_start, false, node);
        },
        .ct_stmt => {
            // Only allow ad hoc evaluation in a function context.
            // Top level ct stmts are evaluated separately.
            if (c.proc().func != null) {
                const ct_stmt = node.cast(.ct_stmt);
                _ = try ct_inline.evalStmt(c, ct_stmt);
            }
        },
        .var_decl => {
            try localDecl(c, node.cast(.var_decl), );
            return;
        },
        .op_assign_stmt => {
            const stmt = node.cast(.op_assign_stmt);
            switch (stmt.op) {
                .bitwiseOr,
                .bitwiseAnd,
                .bitwiseLeftShift,
                .bitwiseRightShift,
                .bitwiseXor,
                .star,
                .slash,
                .percent,
                .pow,
                .plus,
                .minus => {},
                else => {
                    return c.reportErrorFmt("Unsupported op assign statement for {}.", &.{v(stmt.op)}, node);
                }
            }
            try semaAssignStmt(c, node, stmt.left, node, .{ .rhsOpAssignBinExpr = true });
            return;
        },
        .assign_stmt => {
            const stmt = node.cast(.assign_stmt);
            try semaAssignStmt(c, node, stmt.left, stmt.right, .{});
            return;
        },
        .trait_decl,
        .struct_decl,
        .cstruct_decl,
        .cunion_decl,
        .passStmt,
        .const_decl,
        .global_decl,
        .custom_type_decl,
        .type_alias_decl,
        .type_const_decl,
        .use_alias,
        .import_stmt,
        .template,
        .enumDecl,
        .funcDecl => {
            // Nop.
        },
        .for_iter_stmt => {
            const stmt = node.cast(.for_iter_stmt);

            _ = try pushBlock(c, node);
            {
                const iterable_n: *ast.Node = @ptrCast(stmt.iterable);
                const iterable_init = try c.semaExpr(stmt.iterable, .{});
                var iterable_expr = iterable_init;
                if (iterable_init.type.isRefPointer()) {
                    // The hidden local releases the ref at the end of the loop, so an existing local must be retained.
                    iterable_expr = try semaOwn(c, iterable_expr, iterable_n);
                } else {
                    iterable_expr = try semaBorrow(c, iterable_expr, node);
                }
                const iterable_v = try declareHiddenLocal(c, "_iterable", iterable_expr.type, iterable_expr, iterable_n);
                // The loop borrows the iterable until it ends.
                bindBorrowLocal(c, iterable_v.id, iterable_expr);
                const iterable = try semaLocal(c, iterable_v.id, node);

                const iterator_sym = try c.accessResolvedSymOrFail(iterable_init.type, "iterator", iterable_n);
                var func_sym = try requireFuncSym(c, iterator_sym, iterable_n);
                const iterator_init = try c.semaCallFuncSymRec(func_sym, iterable_n, iterable, &.{}, false, iterable_n);
                const iterator_v = try declareHiddenLocal(c, "iterator", iterator_init.type, iterator_init, iterable_n);
                const iterator = try semaLocal(c, iterator_v.id, node);
                const iterator_borrow = try semaBorrow(c, iterator, node);

                if (stmt.count) |count| {
                    if (count.type() != .ident) {
                        return c.reportError("Expected a variable name for the index.", count);
                    }
                }
                const counter_init = try c.semaConst(0, c.sema.i64_t, node);
                const counterv = try declareHiddenLocal(c, "_counter", c.sema.i64_t, counter_init, node);

                const ClosureData = struct {
                    stmt: *ast.ForIterStmt,
                    counterv: LocalResult,
                    outer: usize,
                };

                // Loop block.
                const outer = try pushBlock(c, node);
                c.block().loop = true;
                {
                    // if iterator.next() -> i, each
                    const S = struct {
                        fn body(c_: *cy.Chunk, opt_id: u32, opt_local: ExprResult, data_: *anyopaque) !void {
                            _ = opt_id;
                            _ = opt_local;
                            const data: *ClosureData = @ptrCast(@alignCast(data_));
                            var counter_: ExprResult = undefined;
                            if (data.stmt.count) |count| {
                                counter_ = try semaLocal(c_, data.counterv.id, @ptrCast(data.stmt));

                                // _count = _counter
                                const count_name = count.cast(.ident).name.slice();
                                _ = try declareLocalInit(c_, count_name, c_.sema.i64_t, counter_, @ptrCast(data.stmt));
                            }

                            const block_idx = try pushBlock(c_, @ptrCast(data.stmt));
                            c_.semaBlocks.items[data.outer].pre_continue_block = @intCast(block_idx);
                            {
                                try semaStmts(c_, data.stmt.stmts);
                            }
                            const block = try popBlock(c_);
                            _ = try c_.ir.pushStmt(.block, @ptrCast(data.stmt), .{ .bodyHead = block.first });

                            // Continue epilogue.

                            if (data.stmt.count) |count| {
                                // _counter += 1
                                _ = count;
                                const one = try c_.semaConst(1, c_.sema.i64_t, @ptrCast(data.stmt));
                                const right = try c_.ir.newExpr(.add, c_.sema.i64_t, @ptrCast(data.stmt), .{
                                    .left = counter_.ir,
                                    .right = one.ir,
                                });

                                const info = c_.varStack.items[data.counterv.id].inner.local;
                                _ = try c_.ir.pushStmt(.set_local, @ptrCast(data.stmt), .{
                                    .id = info.id,
                                    .right = right,
                                });
                            }

                            try semaContinueTo(c_, data.outer, @ptrCast(data.stmt));
                        }
                    }; 

                    // `for a |&r|` iterates by borrow: `next_borrow` returns `?&T` and no element is copied.
                    var each_n = stmt.each;
                    var next_name: []const u8 = "next";
                    if (stmt.each) |each| {
                        if (each.type() == .borrow) {
                            const child = each.cast(.borrow).child;
                            if (child.type() != .ident) {
                                return c.reportError("Expected a variable name after `&`.", child);
                            }
                            each_n = child;
                            next_name = "next_borrow";
                            const iterable_sym = iterable_init.type.sym();
                            if ((try c.getResolvedSym(@ptrCast(iterable_sym), next_name, iterable_n)) == null) {
                                const type_name = try c.sema.allocTypeName(iterable_init.type);
                                defer c.alloc.free(type_name);
                                return c.reportErrorFmt("`{}` can not be iterated by borrow. It has no `next_borrow` method.", &.{v(type_name)}, each);
                            }
                        }
                    }
                    const next_sym = try c.accessResolvedSymOrFail(iterable_init.type, next_name, iterable_n);
                    func_sym = try requireFuncSym(c, next_sym, iterable_n);
                    const args = [2]sema_func.Argument{
                        sema_func.Argument.initReceiver(iterable_n, iterable),
                        sema_func.Argument.initPreResolved(iterable_n, iterator_borrow),
                    };
                    const next = try c.semaCallFuncSymRec2(func_sym, &args, iterable_n);

                    var closure_data = ClosureData{
                        .stmt = stmt,
                        .counterv = counterv,
                        .outer = outer,
                    };
                    _ = try semaIfUnwrapBlock2(c, next, node, each_n, S.body, &closure_data, outer, true, @ptrCast(stmt));
                }
                const block = try popBlock(c);
                _ = try c.ir.pushStmt(.loop_block, node, .{
                    .body_head = block.first,
                });
            }
            const block = try popBlock(c);
            _ = try c.ir.pushStmt(.block, @ptrCast(stmt), .{ .bodyHead = block.first });
        },
        .for_range_stmt => {
            const stmt = node.cast(.for_range_stmt);

            const var_start = c.varStack.items.len;

            const range_start = try c.semaExprTarget(stmt.start, c.sema.i64_t);
            if (range_start.type.kind() != .int) {
                return c.reportError("Expected integer type.", stmt.start);
            }
            const range_end = try c.semaExprCstr(stmt.end, range_start.type);

            _ = try pushBlock(c, node);
            c.block().loop = true;

            var eachLocal: ?u8 = null;
            if (stmt.each) |each| {
                if (each.type() == .ident) {
                    const varId = try declareLocal(c, each, range_start.type, false);
                    eachLocal = c.varStack.items[varId].inner.local.id;
                } else {
                    return c.reportErrorFmt("Unsupported each clause: {}", &.{v(each.type())}, each);
                }
            }

            const declHead = c.ir.getAndClearStmtBlock();

            try semaStmts(c, stmt.stmts);
            const stmtBlock = try popBlock(c);

            _ = try c.ir.pushStmt(.forRangeStmt, node, .{
                .has_each_local = eachLocal != null,
                .eachLocal = eachLocal orelse undefined,
                .start = range_start.ir,
                .end = range_end.ir,
                .bodyHead = stmtBlock.first,
                .increment = stmt.increment,
                .end_inclusive = stmt.end_inclusive,
                .declHead = declHead,
            });
            try popLocals(c, var_start, @ptrCast(stmt));
        },
        .whileInfStmt => {
            const stmt = node.cast(.whileInfStmt);
            _ = try pushBlock(c, node);
            c.block().loop = true;
            {
                try semaStmts(c, stmt.stmts);
                try semaContinue(c, node);
            }
            const loop_has_break = c.block().loop_has_break;
            const stmtBlock = try popBlock2(c, false);
            if (!loop_has_break) {
                c.block().endReachable = false;
            }
            _ = try c.ir.pushStmt(.loop_block, node, .{
                .body_head = stmtBlock.first,
            });
        },
        .whileCondStmt => {
            const stmt = node.cast(.whileCondStmt);

            _ = try pushBlock(c, node);
            c.block().loop = true;
            {
                const cond = try c.semaExprCstr(stmt.cond, c.sema.bool_t);
                _ = try pushBlock(c, node);
                {
                    try semaStmts(c, stmt.stmts);
                    try semaContinue(c, node);
                }
                const block = try popBlock2(c, false);
                _ = try c.ir.pushStmt(.if_block, node, .{
                    .cond_expr = cond.ir,
                    .body_head = block.first,
                });
            }
            const block = try popBlock(c);
            _ = try c.ir.pushStmt(.loop_block, node, .{
                .body_head = block.first,
            });
        },
        .while_unwrap_stmt => {
            const stmt = node.cast(.while_unwrap_stmt);

            const outer = try pushBlock(c, node);
            c.block().loop = true;
            {
                const S = struct {
                    fn body(c_: *cy.Chunk, opt_id: u32, opt_local: ExprResult, data: *anyopaque) !void {
                        _ = opt_id;
                        _ = opt_local;
                        const stmt_: *ast.WhileUnwrapStmt = @ptrCast(@alignCast(data));
                        try semaStmts(c_, stmt_.stmts);
                        try semaContinue(c_, @ptrCast(stmt_));
                    }
                }; 
                const opt = try c.sema_expr_cstr_template(stmt.opt, c.sema.option_tmpl);
                _ = try semaIfUnwrapBlock2(c, opt, stmt.opt, stmt.capture, S.body, stmt, outer, true, @ptrCast(stmt));
            }
            const stmtBlock = try popBlock(c);
            _ = try c.ir.pushStmt(.loop_block, node, .{
                .body_head = stmtBlock.first,
            });
        },
        .switch_stmt => {
            try semaSwitchStmt(c, node.cast(.switch_stmt));
        },
        .if_stmt => {
            try semaIfStmt(c, node.cast(.if_stmt));
        },
        .begin_stmt => {
            try sema_begin_stmt(c, node.cast(.begin_stmt));
        },
        .if_unwrap_stmt => {
            try semaIfUnwrapStmt(c, node.cast(.if_unwrap_stmt));
        },
        .tryStmt => {
            try sema_try_stmt(c, node.cast(.tryStmt));
        },
        .suspend_stmt => {
            // Gives control back to the `resume` call of the running fiber. The frames stay on the fiber's
            // stack, so nothing is copied or destructed here.
            const stmt = try c.ir.pushStmt(.suspend_, node, .{});
            try semaCancelPad(c, @intFromPtr(stmt), node);
        },
        .yield_stmt => {
            const yield = node.cast(.yield_stmt);
            const proc_func = c.proc().func;
            if (proc_func == null or !proc_func.?.info.generator) {
                // Without this, the return type below is cast as a generator pointer and the VM crashes at runtime.
                return c.reportError("`yield` is only allowed in a `generator fn`.", node);
            }
            const gen_t = c.proc().getReturnType(c.sema).cast(.pointer).child_t;
            const funcptr_t = gen_t.sym().instance.?.params[0].asPtr(*cy.Type);
            const val_t = funcptr_t.cast(.func_ptr).sig.ret;
            const opt_t = try getOptionType(c, val_t);
            if (yield.child) |child| {
                const var_start = c.varStack.items.len;
                var expr = try c.semaExprCstr(child, val_t);
                // The yielded value is handed to the consumer, which destructs it. A local stays alive in the
                // generator, so it is copied like a returned value.
                expr = try semaOwn(c, expr, child);
                if (opt_t.cast(.option).zero_union) {
                    expr = try semaBitcast(c, expr, opt_t, child);
                } else {
                    const tag = try c.semaConst(1, c.sema.i64_t, child);
                    expr = try semaInit2(c, opt_t, tag, expr, child);
                }
                _ = try c.ir.pushStmt(.set_ret, node, .{
                    .right = expr.ir,
                });
                // Emit deinit block.
                try c.ir.pushStmtBlock(c.alloc);
                {
                    const b = c.procBlock();
                    try semaDestructBlock2(c, b);
                    if (c.ir.stmtBlockStack.items[c.ir.stmtBlockStack.items.len-1].first != null) {
                        _ = try c.ir.pushStmt(.yield, node, .{
                            .deinit_head = null,
                            .ret_opt_t = opt_t,
                            .end = true,
                        });
                    }
                }
                const block = c.ir.popStmtBlock();
                _ = try c.ir.pushStmt(.yield, node, .{
                    .deinit_head = block.first,
                    .ret_opt_t = opt_t,
                    .end = false,
                });
                // Temporaries of the yield expression are alive while the generator is suspended here (the
                // deinit block above destructs them when the generator is dropped). After the resume they end.
                try popLocals2(c, var_start, true, node);
            } else {
                return c.reportErrorFmt("TODO", &.{}, node);
            }
        },
        .returnStmt => {
            const proc = c.proc();
            if (proc.func == null) {
                return c.reportErrorFmt("Return statement is not allowed in the main block.", &.{}, node);
            }
            _ = try semaReturn(c, node);
        },
        .returnExprStmt => {
            const child = node.cast(.returnExprStmt).child;
            const proc = c.proc();
            if (proc.func == null) {
                return c.reportErrorFmt("Return statement is not allowed in the main block.", &.{}, node);
            }
            const retType = proc.getReturnType(c.sema);
            _ = try semaReturnExprStmt(c, child, retType, node);
        },
        else => return c.reportErrorFmt("Unsupported statement: {}", &.{v(node.type())}, node),
    }

    if (cy.Trace) {
        if (node.type() != .ct_stmt) {
            try check_locals(c, exp_var_start, node);
        }
    }
}

fn check_locals(c: *cy.Chunk, exp_var_start: usize, node: *ast.Node) !void {
    if (exp_var_start != c.varStack.items.len) {
        return c.reportErrorFmt("Expected var_start {}, found {}.", &.{v(exp_var_start), v(c.varStack.items.len)}, node);
    }
}

fn semaBreakTo(c: *cy.Chunk, block_idx: usize, node: *ast.Node) !void {
    const start = c.proc().block_start;
    const b = &c.semaBlocks.items[block_idx];
    try semaDestructBlock2(c, b);
    _ = try c.ir.pushStmt(.break_, node, .{ .block_offset = @intCast(block_idx - start) });
    c.block().endReachable = false;
}

fn semaBreak(c: *cy.Chunk, node: *ast.Node) !void {
    const start = c.proc().block_start;
    const idx = c.loopBlock(start) orelse {
        return c.reportError("Expected parent loop block.", node);
    };
    const b = &c.semaBlocks.items[idx];
    b.loop_has_break = true;
    try semaDestructBlock2(c, b);
    _ = try c.ir.pushStmt(.break_, node, .{ .block_offset = @intCast(idx - start) });
    c.block().endReachable = false;
}

fn semaContinueTo(c: *cy.Chunk, block_idx: usize, node: *ast.Node) !void {
    const start = c.proc().block_start;
    const b = &c.semaBlocks.items[block_idx];
    try semaDestructBlock2(c, b);
    _ = try c.ir.pushStmt(.continue_, node, .{ .block_offset = @intCast(block_idx - start) });
    c.block().endReachable = false;
}

fn semaContinue(c: *cy.Chunk, node: *ast.Node) !void {
    const start = c.proc().block_start;
    const idx = c.loopBlock(start) orelse {
        return c.reportError("Expected parent loop block.", node);
    };
    const b = &c.semaBlocks.items[idx];
    if (b.pre_continue_block != cy.NullId) {
        const pre_cont_block = &c.semaBlocks.items[b.pre_continue_block];
        try semaDestructBlock2(c, pre_cont_block);
        _ = try c.ir.pushStmt(.break_, node, .{ .block_offset = @intCast(b.pre_continue_block - start) });
    } else {
        try semaDestructBlock2(c, b);
        _ = try c.ir.pushStmt(.continue_, node, .{ .block_offset = @intCast(idx - start) });
    }
    c.block().endReachable = false;
}

/// Assumes `expr` is owned or has unmanaged type.
pub fn semaReturnExpr(c: *cy.Chunk, expr: ExprResult, node: *ast.Node) !void {
    if (expr.type.kind() == .borrow) {
        const proc = c.proc();
        const scope_param_idx = proc.func.?.sig.scope_param_idx;
        if (scope_param_idx != cy.NullU8) {
            if (expr.resType == .value) {
                const parent_local = expr.data.value.parent_local orelse {
                    return c.reportError("Expected parent lifetime local.", node);
                };
                if (parent_local != proc.varStart + scope_param_idx) {
                    const param_name = c.varStack.items[proc.varStart + scope_param_idx].name();
                    return c.reportErrorFmt("Expected to return a borrow from the same scope as `{}`.", &.{v(param_name)}, node);
                }
            } else if (expr.resType == .value_local) {
                if (expr.data.value_local != proc.varStart + scope_param_idx) {
                    const param_name = c.varStack.items[proc.varStart + scope_param_idx].name();
                    return c.reportErrorFmt("Expected to return a borrow from the same scope as `{}`.", &.{v(param_name)}, node);
                }
            } else {
                return c.reportErrorFmt("Unsupported resType `{}`", &.{v(expr.resType)}, node);
            }
        }
    }

    _ = try c.ir.pushStmt(.set_ret, node, .{
        .right = expr.ir,
    });

    // TODO: Optimize to a single `ret_expr` if there were no destructors emitted.
    const b = c.procBlock();
    try semaDestructBlock2(c, b);

    if (c.proc().func == null) {
        try sema_program_deinit(c);
    }

    _ = try c.ir.pushStmt(.ret, node, .{
        .return_value = true,
    });
    c.block().endReachable = false;
}

// NOTE: This should only be inserted once since the main block will be wrapped in a main function.
fn sema_program_deinit(c: *cy.Chunk) !void {
    try semaNop(c, "program end.", c.ast.null_node);
    // Run static deinit for main func.
    const func = c.sym.getMod().getSym("@program_deinit").?.cast(.func).first;
    const expr = try sema.sema_call_ir(c, func, &.{}, c.ast.null_node);
    try sema_discard(c, expr, c.ast.null_node);
}

fn semaReturn(c: *cy.Chunk, node: *ast.Node) !void {
    const proc = c.proc();
    const b = c.procBlock();
    const var_start = c.varStack.items.len;

    const ret_t = proc.getReturnType(c.sema);
    if (ret_t.id() == bt.Void) {
        try semaDestructBlock2(c, b);

        if (c.proc().func == null) {
            try sema_program_deinit(c);
        }

        _ = try c.ir.pushStmt(.ret, node, .{ .return_value = false });
    }
    if (ret_t.kind() == .result and ret_t.cast(.result).child_t.id() == bt.Void) {
        const voidv = try c.semaVoid(node);
        const expr = try semaInitChoice(c, ret_t, 1, 1, voidv, node);
        try semaReturnExpr(c, expr, node);
    }
    try popLocals2(c, var_start, false, node);
    c.block().endReachable = false;
}

fn semaReturnExprStmt(c: *cy.Chunk, child: *ast.Node, ret_opt: ?*cy.Type, node: *ast.Node) !*cy.Type {
    const proc = c.proc();
    if (proc.func != null and proc.func.?.info.generator) {
        const gen_t = c.proc().getReturnType(c.sema).cast(.pointer).child_t;
        const funcptr_t = gen_t.sym().instance.?.params[0].asPtr(*cy.Type);
        const val_t = funcptr_t.cast(.func_ptr).sig.ret;
        const opt_t = try getOptionType(c, val_t);

        const var_start = c.varStack.items.len;
        var expr = try c.semaExprCstr(child, val_t);
        // Same as `yield`: the generator's locals are destructed below, so the result is a copy.
        expr = try semaOwn(c, expr, child);
        if (opt_t.cast(.option).zero_union) {
            expr = try semaBitcast(c, expr, opt_t, child);
        } else {
            const tag = try c.semaConst(1, c.sema.i64_t, child);
            expr = try semaInit2(c, opt_t, tag, expr, child);
        }
        _ = try c.ir.pushStmt(.set_ret, node, .{
            .right = expr.ir,
        });
        const b = c.procBlock();
        try semaDestructBlock2(c, b);
        _ = try c.ir.pushStmt(.yield, node, .{
            .deinit_head = null,
            .ret_opt_t = opt_t,
            .end = true,
        });
        try popLocals2(c, var_start, false, node);
        c.block().endReachable = false;
        return opt_t;
    }

    const var_start = c.varStack.items.len;

    var expr: ExprResult = undefined;
    // For a plain name, fit the return type after the move check so that wrapping a local
    // (`T` -> `?T`, `!T`) moves it too. Other expressions keep the usual constraint since
    // `fit_target` also steers how their children are checked.
    const defer_fit = ret_opt != null and child.type() == .ident;
    if (ret_opt) |ret_t| {
        if (defer_fit) {
            expr = try c.semaExpr(child, .{
                .target_t = ret_t,
                .reqTypeCstr = false,
                .fit_target = false,
            });
        } else {
            expr = try c.semaExprCstr(child, ret_t);
        }
    } else {
        expr = try c.semaExpr(child, .{});
    }

    // Returning a local moves it instead of copying it. A type without `@copy` is copied bitwise,
    // so a copy would run the local's destructor here and the caller's on the same state.
    // The local is only marked dead while the return's destructors are generated. Code after a return
    // is unreachable, so other paths that still use the local are unaffected.
    const moved_local = implicitReturnMoveLocal(c, expr);
    if (moved_local != null) {
        expr.owned = true;
    }
    if (defer_fit) {
        expr = try fitReturnType(c, expr, ret_opt.?, child);
    }

    if (moved_local) |local_id| {
        c.varStack.items[local_id].type = .dead;
        defer c.varStack.items[local_id].type = .local;
        try semaReturnExpr(c, expr, node);
    } else {
        expr = try semaOwn(c, expr, child);
        try semaReturnExpr(c, expr, node);
    }
    try popLocals2(c, var_start, false, node);
    return expr.type;
}

/// The tail of `semaExpr` with `reqTypeCstr` and `fit_target` set.
fn fitReturnType(c: *cy.Chunk, expr: ExprResult, ret_t: *cy.Type, node: *ast.Node) !ExprResult {
    if (expr.type == ret_t) {
        return expr;
    }
    if (try semaFitTarget(c, expr, ret_t, node)) |new| {
        return new;
    }
    if (expr.type.id() == bt.Never) {
        return expr;
    }
    return reportExpectedType(c, ret_t, expr.type, node);
}

fn implicitReturnMoveLocal(c: *cy.Chunk, expr: ExprResult) ?LocalId {
    if (expr.owned or expr.resType != .value_local) {
        return null;
    }
    const proc = c.proc();
    if (proc.func == null) {
        return null;
    }
    const local_id = expr.data.value_local;
    const local = &c.varStack.items[local_id];
    if (local.type != .local or local.has_inactive_struct_fields) {
        return null;
    }
    // A local declared outside this function (a captured or static var) is not owned by this frame.
    if (local_id < proc.varStart) {
        return null;
    }
    if (!local.decl_t.isManaged()) {
        return null;
    }
    // Reference params are not owned by regular functions.
    if (local.inner.local.isParam and local.decl_t.isObjectLike()) {
        return null;
    }
    return local_id;
}

/// Extracted `cond_n` and `stmts` to be compatible with IfStmt/ElseIfBlock.
fn semaIfBlock(c: *cy.Chunk, cond_n: *ast.Node, stmts: []const *ast.Node, outer: usize,
    is_last: bool, end_reachable: *bool, node: *ast.Node) !void {

    const cond = try c.semaExprCstr(cond_n, c.sema.bool_t);
    _ = try pushBlock(c, node);
    {
        try semaStmts(c, stmts);
        // NOTE: Set end_reachable before break.
        end_reachable.* = c.block().endReachable;
        if (!is_last) {
            try semaBreakTo(c, outer, node);
        }
    }
    const block = try popBlock2(c, end_reachable.*);
    _ = try c.ir.pushStmt(.if_block, node, .{
        .cond_expr = cond.ir,
        .body_head = block.first,
    });
}

/// For `unwrap_or`, `unwrap_or_block`.
fn semaIfUnwrapBlock2(c: *cy.Chunk, opt: ExprResult, opt_n: *ast.Node, opt_unwrap: ?*ast.Node,
    body: *const fn (*cy.Chunk, u32, ExprResult, *anyopaque) anyerror!void,
    body_data: *anyopaque, outer: usize, is_last: bool, node: *ast.Node) !void {

    const owned_opt = try semaOwn(c, opt, opt_n);
    // _opt = <opt>
    const opt_v = try declareHiddenLocal(c, "_opt", opt.type, owned_opt, opt_n);
    const get_opt = try semaLocal(c, opt_v.id, opt_n);

    // if !isNone(_opt)
    var cond = try c.semaIsNone(get_opt, opt_n);
    const irIdx = try c.ir.newExpr(.unary_op, c.sema.bool_t, opt_n, .{
        .childT = c.sema.bool_t, .op = .lnot, .expr = cond.ir,
    });
    cond.ir = irIdx;

    _ = try pushBlock(c, @ptrCast(node));
    {
        if (opt_unwrap) |unwrap| {
            try semaCaptureUnwrap(c, opt.type, get_opt, unwrap);  
        }

        try body(c, opt_v.id, get_opt, body_data);
        if (!is_last) {
            try semaBreakTo(c, outer, @ptrCast(node));
        }
    }
    const end_reachable = c.block().endReachable;
    const block = try popBlock2(c, end_reachable);
    _ = try c.ir.pushStmt(.if_block, node, .{
        .cond_expr = cond.ir,
        .body_head = block.first,
    });

    if (!is_last) {
        if (c.varStack.items[opt_v.id].type != .local) {
            // If opt_v was consumed in the `body`, restore for the next block.
            c.varStack.items[opt_v.id].type = .local;
        }
    }
}

fn semaCaptureUnwrap(c: *cy.Chunk, opt_t: *cy.Type, get_opt: ExprResult, capture: *ast.Node) !void {
    // _unwrap = _opt.?
    const unwrap_t = opt_t.cast(.option).child_t;
    var unwrap_name: []const u8 = undefined;
    if (capture.type() == .ident) {
        unwrap_name = capture.cast(.ident).name.slice();
    } else if (capture.type() == .seqDestructure) {
        unwrap_name = "_unwrap";
    } else {
        return c.reportErrorFmt("Unsupported unwrap declaration: {}", &.{v(capture.type())}, capture);
    }
    var unwrap_init = try semaUnwrapOptionNoCheck(c, get_opt, capture);
    unwrap_init = try sema_copy(c, unwrap_init, capture);
    const unwrap_v = try declareLocalInit(c, unwrap_name, unwrap_t, unwrap_init, capture);
    const unwrap_local = try semaLocal(c, unwrap_v.id, capture);

    if (capture.type() == .seqDestructure) {
        const decls = capture.cast(.seqDestructure).args;
        for (decls, 0..) |decl, i| {
            {
                return c.reportErrorFmt("TODO", &.{}, capture);
            }
            const name = decl.cast(.ident).name;
            var index = try c.semaConst(@intCast(i), c.sema.i64_t, capture);
            index.ir = try c.ir.newExpr(.box, c.sema.object_t, capture, .{
                .expr = index.ir,
            });
            index.type = c.sema.object_t;
            const dvar_init = try semaIndexExpr2(c, unwrap_local, capture, index, capture, capture);
            _ = try declareLocalInit(c, name, dvar_init.type, dvar_init, capture);
        }
    }
}

fn semaLogicOr(c: *cy.Chunk, left: *ast.Node, right: *ast.Node, node: *ast.Node) !ExprResult {
    const res_local = try declareHiddenLocal(c, "_temp", c.sema.bool_t, null, node);

    const outer = try pushBlock(c, node);
    {
        const cond = try c.semaExprCstr(left, c.sema.bool_t);

        _ = try pushBlock(c, left);
        {
            const true_value = try semaTrue(c, left);
            _ = try c.ir.pushStmt(.set_local, left, .{
                .id = @intCast(res_local.ir_id),
                .right = true_value.ir,
            });
            try semaBreakTo(c, outer, left);
        }
        const block = try popBlock2(c, false);
        _ = try c.ir.pushStmt(.if_block, left, .{
            .cond_expr = cond.ir,
            .body_head = block.first,
        });

        const right_value = try c.semaExprCstr(right, c.sema.bool_t);
        _ = try c.ir.pushStmt(.set_local, right, .{
            .id = @intCast(res_local.ir_id),
            .right = right_value.ir,
        });
    }
    const block = try popBlock(c);
    _ = try c.ir.pushStmt(.block, @ptrCast(node), .{ .bodyHead = block.first });

    const res = (try semaLocal(c, res_local.id, node)).ir;
    c.varStack.items[res_local.id].type = .dead;
    return ExprResult.init2(res);
}

fn semaLogicAnd(c: *cy.Chunk, left: *ast.Node, right: *ast.Node, node: *ast.Node) !ExprResult {
    const res_local = try declareHiddenLocal(c, "_temp", c.sema.bool_t, null, node);

    const outer = try pushBlock(c, node);
    {
        var cond = try c.semaExprCstr(left, c.sema.bool_t);
        const expr = try c.ir.newExpr(.unary_op, c.sema.bool_t, left, .{
            .childT = c.sema.bool_t, .op = .lnot, .expr = cond.ir,
        });
        cond = ExprResult.init2(expr);

        _ = try pushBlock(c, left);
        {
            const false_value = try semaFalse(c, left);
            _ = try c.ir.pushStmt(.set_local, left, .{
                .id = @intCast(res_local.ir_id),
                .right = false_value.ir,
            });
            try semaBreakTo(c, outer, left);
        }
        const block = try popBlock2(c, false);
        _ = try c.ir.pushStmt(.if_block, left, .{
            .cond_expr = cond.ir,
            .body_head = block.first,
        });

        const right_value = try c.semaExprCstr(right, c.sema.bool_t);
        _ = try c.ir.pushStmt(.set_local, right, .{
            .id = @intCast(res_local.ir_id),
            .right = right_value.ir,
        });
    }
    const block = try popBlock(c);
    _ = try c.ir.pushStmt(.block, @ptrCast(node), .{ .bodyHead = block.first });

    const res = (try semaLocal(c, res_local.id, node)).ir;
    c.varStack.items[res_local.id].type = .dead;
    return ExprResult.init2(res);
}

fn semaLogicAnd2(c: *cy.Chunk, left: *ast.Node, left_value: ExprResult, right: *ast.Node, right_value: ExprResult, node: *ast.Node) !ExprResult {
    const res_local = try declareHiddenLocal(c, "_temp", c.sema.bool_t, null, node);

    const outer = try pushBlock(c, node);
    {
        var cond = left_value;
        const expr = try c.ir.newExpr(.unary_op, c.sema.bool_t, left, .{
            .childT = c.sema.bool_t, .op = .lnot, .expr = left_value.ir,
        });
        cond = ExprResult.init2(expr);

        _ = try pushBlock(c, left);
        {
            const false_value = try semaFalse(c, left);
            _ = try c.ir.pushStmt(.set_local, left, .{
                .id = @intCast(res_local.ir_id),
                .right = false_value.ir,
            });
            try semaBreakTo(c, outer, left);
        }
        const block = try popBlock2(c, false);
        _ = try c.ir.pushStmt(.if_block, left, .{
            .cond_expr = cond.ir,
            .body_head = block.first,
        });

        _ = try c.ir.pushStmt(.set_local, right, .{
            .id = @intCast(res_local.ir_id),
            .right = right_value.ir,
        });
    }
    const block = try popBlock(c);
    _ = try c.ir.pushStmt(.block, @ptrCast(node), .{ .bodyHead = block.first });

    const res = (try semaLocal(c, res_local.id, node)).ir;
    c.varStack.items[res_local.id].type = .dead;
    return ExprResult.init2(res);
}

/// Extracted `opt_n` and `stmts` to be compatible with IfUnwrapStmt/ElseIfUnwrapBlock.
fn semaIfUnwrapBlock(c: *cy.Chunk, opt_n: *ast.Node, opt_unwrap: ?*ast.Node,
    stmts: []const *ast.Node, outer: usize, is_last: bool, end_reachable: *bool, node: *ast.Node) !void {

    const opt = try c.sema_expr_cstr_template(opt_n, c.sema.option_tmpl);

    // _opt = <opt>
    const owned_opt = try semaOwn(c, opt, opt_n);
    const opt_v = try declareHiddenLocal(c, "_opt", opt.type, owned_opt, opt_n);
    const get_opt = try semaLocal(c, opt_v.id, opt_n);

    // if !isNone(_opt)
    var cond = try c.semaIsNone(get_opt, opt_n);
    const irIdx = try c.ir.newExpr(.unary_op, c.sema.bool_t, opt_n, .{
        .childT = c.sema.bool_t, .op = .lnot, .expr = cond.ir,
    });
    cond.ir = irIdx;

    _ = try pushBlock(c, @ptrCast(node));
    {
        if (opt_unwrap) |unwrap| {
            try semaCaptureUnwrap(c, opt.type, get_opt, unwrap);  
        }

        try semaStmts(c, stmts);
        if (!is_last) {
            try semaBreakTo(c, outer, @ptrCast(node));
        }
        end_reachable.* = c.block().endReachable;
    }
    const block = try popBlock2(c, is_last);
    _ = try c.ir.pushStmt(.if_block, node, .{
        .cond_expr = cond.ir,
        .body_head = block.first,
    });
}

fn semaIfUnwrapStmt(c: *cy.Chunk, stmt: *ast.IfUnwrapStmt) !void {
    var blocks_end_reachable = false;
    var has_else = false;
    const outer = try pushBlock(c, @ptrCast(stmt));
    {
        var end_reachable: bool = undefined;
        try semaIfUnwrapBlock(c, stmt.opt, stmt.unwrap, stmt.stmts, outer, stmt.else_blocks.len == 0, &end_reachable, @ptrCast(stmt));
        if (!blocks_end_reachable and end_reachable) {
            blocks_end_reachable = true;
        }

        for (stmt.else_blocks, 0..) |node, i| {
            switch (node.type()) {
                .elseif_block => {
                    const else_ = node.cast(.elseif_block);
                    try semaIfBlock(c, else_.cond, else_.stmts, outer, i + 1 == stmt.else_blocks.len, &end_reachable, node);
                    if (!blocks_end_reachable and end_reachable) {
                        blocks_end_reachable = true;
                    }
                },
                .else_block => {
                    has_else = true;
                    const else_ = node.cast(.else_block);
                    try semaStmts(c, else_.stmts);
                    if (!blocks_end_reachable and c.block().endReachable) {
                        blocks_end_reachable = true;
                    }
                },
                else => {
                    return c.reportError("TODO", node);
                },
            }
        }
    }
    const block = try popBlock(c);
    _ = try c.ir.pushStmt(.block, @ptrCast(stmt), .{ .bodyHead = block.first });
    if (!blocks_end_reachable and has_else) {
        c.block().endReachable = false;
    }
}

fn sema_begin_stmt(c: *cy.Chunk, node: *ast.BeginStmt) !void {
    _ = try pushBlock(c, @ptrCast(node));
    {
        try semaStmts(c, node.stmts);
    }
    const end_reachable = c.block().endReachable;
    const block = try popBlock(c);
    _ = try c.ir.pushStmt(.block, @ptrCast(node), .{ .bodyHead = block.first });
    if (!end_reachable) {
        c.block().endReachable = false;
    }
}

/// `try: body else |err|: handler` is lowered without new IR:
///
///     block outer:
///         block body:
///             <body>          -- `!` on failure: _try_err = err; break body
///             break outer
///         err := _try_err
///         <handler>
///
/// Only `!` in the body is redirected (see `.unwrap_res`). `return`, `!else` and panics keep their
/// meaning. Both paths continue after the statement, so the handler may reach its end.
fn sema_try_stmt(c: *cy.Chunk, stmt: *ast.TryStmt) !void {
    const node: *ast.Node = @ptrCast(stmt);
    const proc = c.proc();

    var body_end_reachable = false;
    var handler_end_reachable = false;
    const outer = try pushBlock(c, node);
    {
        // Declared in `outer`, below the body block, so a failing `!` keeps it while the body's locals
        // are destructed. `error` has no destructor; it is marked dead so the else block does not
        // release an uninitialized local.
        const err_local = try declareHiddenLocal(c, "_try_err", c.sema.error_t, null, node);
        c.varStack.items[err_local.id].type = .dead;

        const body_block = try pushBlock(c, node);
        const prev_ctx = proc.try_ctx;
        proc.try_ctx = .{ .body_block = @intCast(body_block), .err_local = err_local.id };
        {
            try semaStmts(c, stmt.stmts);
            body_end_reachable = c.block().endReachable;
            if (body_end_reachable) {
                try semaBreakTo(c, outer, node);
            }
        }
        proc.try_ctx = prev_ctx;
        const body = try popBlock2(c, false);
        _ = try c.ir.pushStmt(.block, node, .{ .bodyHead = body.first });

        const catch_stmt = stmt.catchStmt;
        const catch_node: *ast.Node = @ptrCast(catch_stmt);
        _ = try pushBlock(c, catch_node);
        {
            if (catch_stmt.errorVar) |capture| {
                if (capture.type() != .ident) {
                    return c.reportErrorFmt("Unsupported error variable: {}", &.{v(capture.type())}, capture);
                }
                c.varStack.items[err_local.id].type = .local;
                const err = try semaLocal(c, err_local.id, capture);
                c.varStack.items[err_local.id].type = .dead;
                _ = try declareLocalInit(c, capture.cast(.ident).name.slice(), c.sema.error_t, err, capture);
            }
            try semaStmts(c, catch_stmt.stmts);
            handler_end_reachable = c.block().endReachable;
        }
        const handler = try popBlock(c);
        _ = try c.ir.pushStmt(.block, catch_node, .{ .bodyHead = handler.first });
        // The else block falls through to the end of `outer`, where the body's `break outer` lands.
        c.block().endReachable = body_end_reachable or handler_end_reachable;
    }
    const block = try popBlock(c);
    _ = try c.ir.pushStmt(.block, node, .{ .bodyHead = block.first });
    if (!body_end_reachable and !handler_end_reachable) {
        c.block().endReachable = false;
    }
}

fn semaIfStmt(c: *cy.Chunk, node: *ast.IfStmt) !void {
    var blocks_end_reachable = false;
    var has_else = false;
    const outer = try pushBlock(c, @ptrCast(node));
    {
        var end_reachable: bool = undefined;
        try semaIfBlock(c, node.cond, node.stmts, outer, node.else_blocks.len == 0, &end_reachable, @ptrCast(node));
        if (!blocks_end_reachable and end_reachable) {
            blocks_end_reachable = true;
        }

        for (node.else_blocks, 0..) |else_block, i| {
            switch (else_block.type()) {
                .elseif_block => {
                    const elseif = else_block.cast(.elseif_block);
                    try semaIfBlock(c, elseif.cond, elseif.stmts, outer, i + 1 == node.else_blocks.len, &end_reachable, else_block);
                    if (!blocks_end_reachable and end_reachable) {
                        blocks_end_reachable = true;
                    }
                },
                .else_block => {
                    has_else = true;
                    const else_ = else_block.cast(.else_block);
                    try semaStmts(c, else_.stmts);
                    if (!blocks_end_reachable and c.block().endReachable) {
                        blocks_end_reachable = true;
                    }
                },
                else => {
                    return c.reportError("TODO", else_block);
                }
            }
        }
    }
    const block = try popBlock(c);
    _ = try c.ir.pushStmt(.block, @ptrCast(node), .{ .bodyHead = block.first });

    if (!blocks_end_reachable and has_else) {
        c.block().endReachable = false;
    }
}

fn semaElseStmt(c: *cy.Chunk, node: *ast.Node, outer: usize, is_last_else: bool, end_reachable: *bool) !void {
    if (node.type() == .elseif_block) {
        const block = node.cast(.elseif_block);

        const cond = try c.semaExprCstr(block.cond, c.sema.bool_t);
        _ = try pushBlock(c, node);
        {
            try semaStmts(c, block.stmts);
            if (!is_last_else) {
                try semaBreakTo(c, outer, node);
            }
            end_reachable.* = c.block().endReachable;
        }
        const stmts = try popBlock2(c, is_last_else);
        _ = try c.ir.pushStmt(.if_block, node, .{
            .cond_expr = cond.ir,
            .body_head = stmts.first,
        });
    } else if (node.type() == .else_block) {
        const block = node.cast(.else_block);

        try semaStmts(c, block.stmts);
        end_reachable.* = c.block().endReachable;
    } else {
        return c.reportErrorFmt("TODO {}", &.{v(node.type())}, node);
    }
}

fn semaAssignToIndexStmt(c: *cy.Chunk, left: *ast.IndexExpr, right: *ast.Node, node: *ast.Node) !void {
    var rec = try c.semaExpr(left.left, .{});
    // rec = try semaManage(c, rec, left.left);

    // `T`, `&T`, `^T` will look for `T.@set_index`
    // `Ptr[T]` will skip @set_index.
    if (!rec.type.isPointer()) {
        // First look for `@set_index`.
        if (try c.accessResolvedSym(rec.type, "@set_index", node)) |set_index_sym| {
            const func_sym = try requireFuncSym(c, set_index_sym, @ptrCast(left));
            const args = [_]sema_func.Argument{
                sema_func.Argument.initReceiver(left.left, rec),
                sema_func.Argument.init(left.args.ptr[0]),
                sema_func.Argument.init(right),
            };
            const res = try c.semaCallFuncSymRec2(func_sym, &args, node); 
            _ = try declareHiddenLocal(c, "_res", res.type, res, node);
            return;
        }
    }

    var ptr: ExprResult = undefined;
    if (rec.type.isPointer()) {
        const idx = try c.semaExprCstr(left.args.ptr[0], c.sema.i64_t);
        ptr = try sema_ptr_index(c, rec, idx, node);
    } else if (try c.accessResolvedSym(rec.type, "@index_addr", node)) |index_addr_sym| {
        // Default to `@index_addr` and `set_deref`.
        const index_addr_fsym = try requireFuncSym(c, index_addr_sym, @ptrCast(left));
        const args = [_]sema_func.Argument{
            sema_func.Argument.initReceiver(left.left, rec),
            sema_func.Argument.init(left.args.ptr[0]),
        };
        ptr = try c.semaCallFuncSymRec2(index_addr_fsym, &args, node);
    } else {
        const name = try c.sema.allocTypeName(rec.type);
        defer c.alloc.free(name);
        return c.reportErrorFmt("Unsupported type `{}` for index assignment.", &.{v(name)}, @ptrCast(left));
    }

    const ptr_t = ptr.type;
    const target_t = ptr_t.getRefLikeChild().?;
    var val = try c.semaExprCstr(right, target_t);
    val = try semaOwn(c, val, right);

    if (target_t.isManaged()) {
        const res = try declareHiddenLocal(c, "_res", target_t, val, right);
        const res_local = try semaLocal(c, res.id, right);

        const deref_loc = try c.ir.newExpr(.deref, target_t, node, .{
            .expr = ptr.ir,
        });
        const deref = ExprResult.init(deref_loc, target_t);
        const temp = try declareHiddenLocal(c, "_temp", target_t, deref, @ptrCast(left));
        try semaDestructLocal(c, &c.varStack.items[temp.id], @ptrCast(left));
        c.varStack.items[temp.id].type = .dead;

        _ = try c.ir.pushStmt(.set_deref, node, .{
            .ptr = ptr.ir,
            .right = res_local.ir,
        });
        c.varStack.items[res.id].type = .dead;
    } else {
        _ = try c.ir.pushStmt(.set_deref, node, .{
            .ptr = ptr.ir,
            .right = val.ir,
        });
    }
}

fn semaAssignToAccessStmt(c: *cy.Chunk, var_start: usize, rec_n: *ast.Node, rec: ExprResult, access_right_n: *ast.Node, access_right_name: []const u8, right: *ast.Node, opts: AssignOptions, node: *ast.Node) !void {
    if (rec.resType == .sym) {
        const right_sym = try c.getResolvedSymOrFail(rec.data.sym, access_right_name, right);
        try c.checkResolvedSymIsDistinct(right_sym, right);
        try referenceSym(c, right_sym, right);

        const sym = try sema.symbol(c, right_sym, false, right);
        if (sym.resType == .varSym) {
            const cstr = Cstr.initRequire((try c.getSymValueType(sym.data.varSym)).?);
            var right_res = try c.semaExprOrOpAssignBinExpr(right, cstr, opts.rhsOpAssignBinExpr);
            right_res = try semaOwn(c, right_res, right);

            try semaAssignToGlobal(c, sym, rec_n, right_res, right, node);
            return;
        } else {
            return c.reportError("Unsupported.", rec_n);
        }
    }

    const type_sym = rec.type.sym();
    var type_ = rec.type.getBaseType();
    const mod = type_.sym().getMod();

    const sym = mod.getSym(access_right_name) orelse {
        if (try c.getResolvedSym(&type_.sym().head, "@set", access_right_n)) |sym| {
            const func_sym = try requireFuncSym(c, sym, node);

            // const child_cstr = Cstr.init(func_sym.first.sig.params_ptr[2].get_type());
            const right_res = try c.semaExprOrOpAssignBinExpr(right, .{}, opts.rhsOpAssignBinExpr);

            const field_name = try c.heap.init_eval_str(access_right_name);
            defer c.heap.release(field_name);

            const args = [3]sema_func.Argument{
                sema_func.Argument.initReceiver(rec_n, rec),
                sema_func.Argument.initPreResolved(access_right_n, ExprResult.initCtValue2(c.sema.eval_str_t, field_name)),
                sema_func.Argument.initPreResolved(right, right_res),
            };
            const call = try c.semaCallFuncSymRec2(func_sym, &args, node);
            _ = try declareHiddenLocal(c, "_res", call.type, call, node);
            try popLocals(c, var_start, node);
            return;
        }

        const type_name = try c.sema.allocTypeName(type_sym.type);
        defer c.alloc.free(type_name);
        return c.reportErrorFmt("Field `{}` does not exist in `{}`.", &.{v(access_right_name), v(type_name)}, access_right_n);
    };

    try cy.module.check_sym_visible(c, sym, access_right_n);
    if (sym.type != .field) {
        const type_name = type_sym.type.name();
        return c.reportErrorFmt("Type `{}` does not have a field named `{}`.", &.{v(type_name), v(access_right_name)}, access_right_n);
    }
    const field_s = sym.cast(.field);

    // Assigning to a member that was moved out revives it (F-79). `rec` carries the access path
    // when its root local has inactive members. Resolve the member's states before the rhs is
    // evaluated since the rhs can overwrite `c.temp_access_path`.
    var revive: ?ReviveMember = null;
    if (rec.check_struct_field_access and rec.type.kind() == .struct_t) {
        const var_id = c.temp_access_path.var_id;
        step_member_access_path(c, rec.type, field_s.idx, field_s.type);
        const offset = c.temp_access_path.struct_field_offset;
        const len = c.temp_access_path.state_len;
        const fields = c.proc().var_active_struct_fields.get(var_id).?;
        const states = fields[offset..offset + len];
        if (std.mem.findScalar(bool, states, false) != null) {
            // The owner must be declared in the same block so the state is known at the block end.
            // (Same rule as reassigning a partially moved variable: no runtime drop flags.)
            if (var_id < c.block().varStart) {
                return c.reportError("Can only assign to a moved member of a variable declared in the same block.", access_right_n);
            }
            revive = .{
                .var_id = var_id,
                .offset = offset,
                .len = len,
                .partial = std.mem.findScalar(bool, states, true) != null,
            };
        }
    }

    if (rec.type.kind() == .struct_t) {
        if (rec.resType == .value_field) {
            rec.ir.cast(.field).member_cont = true;
        }
    }
    const loc = try c.ir.newExpr(.field, field_s.type, access_right_n, .{
        .idx = @intCast(field_s.idx),
        .rec = rec.ir,
    });

    const cstr = Cstr.initRequire(field_s.type);
    var right_res = try c.semaExprOrOpAssignBinExpr(right, cstr, opts.rhsOpAssignBinExpr);
    right_res = try semaOwn(c, right_res, right);

    if (revive) |rv| {
        if (field_s.type.isManaged()) {
            // Store new value.
            const res = try declareHiddenLocal(c, "_res", field_s.type, right_res, right);
            const res_local = try semaLocal(c, res.id, right);

            if (rv.partial) {
                // Some members of the old value are still alive. Destruct those only.
                // (The moved out members belong to their new owners.)
                const fields = c.proc().var_active_struct_fields.get(rv.var_id).?;
                try sema_call_partial_destruct_member(c, loc, field_s.type, fields[rv.offset..rv.offset + rv.len], access_right_n);
            }

            // Move new value. The old value is not destructed: it was moved out.
            _ = try c.ir.pushStmt(.set_field, node, .{
                .field = loc,
                .right = res_local.ir,
            });
            c.varStack.items[res.id].type = .dead;
        } else {
            _ = try c.ir.pushStmt(.set_field, node, .{
                .field = loc,
                .right = right_res.ir,
            });
        }

        // The member is alive again.
        const fields = c.proc().var_active_struct_fields.get(rv.var_id).?;
        @memset(fields[rv.offset..rv.offset + rv.len], true);
        if (std.mem.findScalar(bool, fields, false) == null) {
            // Every member is alive. The variable is whole again.
            _ = c.proc().var_active_struct_fields.remove(rv.var_id);
            c.varStack.items[rv.var_id].has_inactive_struct_fields = false;
        }
        return;
    }

    if (field_s.type.isManaged()) {
        // Store new value.
        const res = try declareHiddenLocal(c, "_res", field_s.type, right_res, right);
        const res_local = try semaLocal(c, res.id, right);

        // Move existing to temp local.
        const field = ExprResult.init(loc, field_s.type);
        const temp = try declareHiddenLocal(c, "_temp", field_s.type, field, access_right_n);

        // Destruct existing.
        try semaDestructLocal(c, &c.varStack.items[temp.id], access_right_n);
        c.varStack.items[temp.id].type = .dead;

        // Move new value.
        _ = try c.ir.pushStmt(.set_field, node, .{
            .field = loc,
            .right = res_local.ir,
        });
        c.varStack.items[res.id].type = .dead;
    } else {
        _ = try c.ir.pushStmt(.set_field, node, .{
            .field = loc,
            .right = right_res.ir,
        });
    }
}

/// A member that is assigned to while some of its partial-move states are dead.
const ReviveMember = struct {
    var_id: LocalId,
    /// Offset of the member's states in the owner's state vector.
    offset: usize,
    len: usize,
    /// Some states of the member are still alive. The old value needs a partial destruct.
    partial: bool,
};

/// Partially destruct the struct member `field_loc`: only its members that `states` marks alive.
fn sema_call_partial_destruct_member(c: *cy.Chunk, field_loc: *ir.Expr, field_t: *cy.Type, states: []bool, node: *ast.Node) !void {
    const ptr_t = try getPtrType(c, field_t);
    const field = ExprResult.init(field_loc, field_t);
    const addr = try semaAddressOf(c, field, ptr_t, node);
    const layout = try ensure_partial_struct_layout(c, states);
    const dtor = try get_partial_dtor(c, field_t, layout, node);
    const arg = Argument.initPreResolved(node, addr);
    const call = try c.semaCallFunc2(dtor, &.{arg}, &.{}, node);
    _ = try c.ir.pushStmt(.discard, node, .{ .expr = call.ir });
}

fn semaAssignToGlobal(c: *cy.Chunk, left: ExprResult, left_n: *ast.Node, right: ExprResult, right_n: *ast.Node, node: *ast.Node) !void {
    // Destruct first.
    const var_t = (try c.getSymValueType(left.data.varSym)).?;
    if (var_t.isManaged()) {
        const res = try declareHiddenLocal(c, "_res", var_t, right, right_n);
        const res_local = try semaLocal(c, res.id, right_n);

        const temp = try declareHiddenLocal(c, "_temp", var_t, left, left_n);
        try semaDestructLocal(c, &c.varStack.items[temp.id], left_n);
        c.varStack.items[temp.id].type = .dead;

        _ = try c.ir.pushStmt(.set_global, node, .{
            .sym = left.data.varSym,
            .expr = res_local.ir,
        });
        c.varStack.items[res.id].type = .dead;
    } else {
        _ = try c.ir.pushStmt(.set_global, node, .{
            .sym = left.data.varSym,
            .expr = right.ir,
        });
    }
}

const AssignOptions = struct {
    rhsOpAssignBinExpr: bool = false,
};

/// Pass rightId explicitly to perform custom sema on op assign rhs.
fn semaAssignStmt(c: *cy.Chunk, node: *ast.Node, left_n: *ast.Node, right: *ast.Node, opts: AssignOptions) !void {
    var var_start = c.varStack.items.len;
    switch (left_n.type()) {
        .index_expr => {
            const left = left_n.cast(.index_expr);
            if (left.args.len != 1) {
                return c.reportErrorFmt("Unsupported array expr.", &.{}, left_n);
            }
            const rec = try c.semaExpr(left.left, .{});
            _ = rec;

            var final_right = right;
            if (opts.rhsOpAssignBinExpr) {
                // Push bin expr.
                const op_assign = right.cast(.op_assign_stmt);
                final_right = try c.parser.ast.newNodeErase(.binExpr, .{
                    .left = left_n,
                    .right = op_assign.right,
                    .op = op_assign.op,
                    .op_pos = op_assign.assign_pos,
                });
            }

            try semaAssignToIndexStmt(c, left, final_right, node);
            try popLocals(c, var_start, node);
            if (cy.Trace) {
                try check_locals(c, var_start, node);
            }
            return;
        },
        .accessExpr => {
            const left = left_n.cast(.accessExpr);

            var rec = try c.semaExprSkipSym(left.left, .{});
            if (!rec.addressable) {
                rec = try semaManage(c, rec, left.left);
            }
            const name = left.right.as_name();
            try semaAssignToAccessStmt(c, var_start, left.left, rec, left.right, name, right, opts, node);
            try popLocals(c, var_start, node);
            if (cy.Trace) {
                try check_locals(c, var_start, node);
            }
            return;
        }, 
        .callExpr => {
            const call = left_n.cast(.callExpr);
            const sym = try cte.evalSym(c, call.callee);
            const access_fn = try requireFuncSym(c, sym, call.callee);
            if (access_fn.first == c.sema.access_fn) {
                if (call.args.len != 2) {
                    return c.reportError("Expected 2 arguments.", left_n);
                }

                var rec = try c.semaExprSkipSym(call.args.ptr[0], .{});
                if (!rec.addressable) {
                    rec = try semaManage(c, rec, call.args.ptr[0]);
                }
                const name = try cte.evalCheck(c, call.args.ptr[1], c.sema.str_t);
                defer c.heap.destructValue(name);

                try semaAssignToAccessStmt(c, var_start, call.args.ptr[0], rec, call.args.ptr[1], name.value.asString(), right, opts, node);
                try popLocals(c, var_start, node);
                if (cy.Trace) {
                    try check_locals(c, var_start, node);
                }
                return;
            }
        },
        .deref => {
            const ptr_n = left_n.cast(.deref).left;
            var ptr = try c.semaExpr(ptr_n, .{});
            ptr = try semaManage(c, ptr, ptr_n);

            var child_t: *cy.Type = undefined;
            if (ptr.type.kind() == .pointer) {
                child_t = ptr.type.cast(.pointer).child_t;
            } else if (ptr.type.kind() == .borrow) {
                child_t = ptr.type.cast(.borrow).child_t;
            } else {
                return c.reportError("Expected pointer type.", ptr_n);
            }
            const expr = Cstr.initRequire(child_t);
            const right_res = try c.semaExprOrOpAssignBinExpr(right, expr, opts.rhsOpAssignBinExpr);

            if (child_t.isManaged()) {
                const res = try declareHiddenLocal(c, "_res", child_t, right_res, right);
                const res_local = try semaLocal(c, res.id, right);

                const deref_loc = try c.ir.newExpr(.deref, child_t, node, .{
                    .expr = ptr.ir,
                });
                const deref = ExprResult.init(deref_loc, child_t);
                const temp = try declareHiddenLocal(c, "_temp", child_t, deref, left_n);
                try semaDestructLocal(c, &c.varStack.items[temp.id], left_n);
                c.varStack.items[temp.id].type = .dead;

                _ = try c.ir.pushStmt(.set_deref, left_n, .{
                    .ptr = ptr.ir,
                    .right = res_local.ir,
                });
                c.varStack.items[res.id].type = .dead;
            } else {
                _ = try c.ir.pushStmt(.set_deref, left_n, .{
                    .ptr = ptr.ir,
                    .right = right_res.ir,
                });
            }
            try popLocals(c, var_start, node);
            if (cy.Trace) {
                try check_locals(c, var_start, node);
            }
            return;
        },
        .ident => {
            var right_res: ExprResult = undefined;
            const leftRes = try c.semaExprSkipSym(left_n, .{});
            const leftT = leftRes.type;
            if (leftRes.resType == .value_local) {
                const id = leftRes.data.value_local;
                const svar = &c.varStack.items[id];
                if (svar.inner.local.isParam and svar.decl_t.isObjectLike()) {
                    // TODO: Ref types are not managed until the param is mutated.
                    //       The existing ref should not be released. Instead register a param copy alias.
                    //       The function prelude would copy the param and manage it .
                    return c.reportError("TODO: Write to a reference parameter.", node);
                }

                var right_cstr = Cstr.initRequire(svar.decl_t);
                right_cstr.assign_to_local = true;
                right_res = try c.semaExprOrOpAssignBinExpr(right, right_cstr, opts.rhsOpAssignBinExpr);
                if (right_res.resType == .value and right_res.data.value.has_aux_local) {
                    var_start += 1;
                }
                try checkBorrowOutlives(c, id, right_res, right);
                const borrow_init = right_res;
                right_res = try semaOwn(c, right_res, right);

                if (right_res.type.isManaged()) {
                    const tempv = try declareHiddenLocal(c, "_temp", right_res.type, right_res, right);
                    right_res = try semaLocal(c, tempv.id, node);
                    try semaDestructLocal(c, &c.varStack.items[leftRes.data.value_local], left_n);
                    c.varStack.items[tempv.id].type = .dead;
                }

                const local = &c.varStack.items[leftRes.data.value_local];
                if (local.has_inactive_struct_fields) {
                    // Assigning to partially moved variable.
                    // Must be in the same scope level.
                    if (leftRes.data.value_local < c.block().varStart) {
                        return c.reportError("Can only assign to a partially moved variable declared in the same block.", left_n);
                    }

                    // Clear inactive struct fields.
                    _ = c.proc().var_active_struct_fields.remove(leftRes.data.value_local);
                    local.has_inactive_struct_fields = false;
                }

                // The local now holds a different borrow.
                unbindBorrowLocal(c, local);
                bindBorrowLocal(c, leftRes.data.value_local, borrow_init);

                _ = try c.ir.pushStmt(.set_local, node, .{
                    .id = local.inner.local.id,
                    .right = right_res.ir,
                });
                try popLocals(c, var_start, node);
                if (cy.Trace) {
                    try check_locals(c, var_start, node);
                }
                return;
            } else if (leftRes.resType == .value_field) {
                const expr = Cstr.initRequire(leftT);
                right_res = try c.semaExprOrOpAssignBinExpr(right, expr, opts.rhsOpAssignBinExpr);
                right_res = try semaOwn(c, right_res, right);
                _ = try c.ir.pushStmt(.set_field, left_n, .{
                    .field = leftRes.ir,
                    .right = right_res.ir,
                });
                try popLocals(c, var_start, node);
                if (cy.Trace) {
                    try check_locals(c, var_start, node);
                }
                return;
            } else {
                const right_cstr = Cstr.initRequire(leftT);
                right_res = try c.semaExprOrOpAssignBinExpr(right, right_cstr, opts.rhsOpAssignBinExpr);
                right_res = try semaOwn(c, right_res, right);
            }

            switch (leftRes.resType) {
                .const_ => {
                    return c.reportErrorFmt("Cannot assign to a constant.", &.{}, node);
                },
                .varSym         => {
                    try semaAssignToGlobal(c, leftRes, left_n, right_res, right, node);
                    try popLocals(c, var_start, node);
                    if (cy.Trace) {
                        try check_locals(c, var_start, node);
                    }
                    return;
                },
                .func => {
                    return c.reportErrorFmt("Cannot reassign to a static function.", &.{}, node);
                },
                .sym => {
                    if (leftRes.data.sym.type == .func) {
                        return c.reportErrorFmt("Cannot reassign to a static function.", &.{}, node);
                    }
                },
                .capturedLocal  => {
                    _ = try c.ir.pushStmt(.setCaptured, node, .{
                        .left_t = leftT,
                        .right_t = right_res.type,
                        .left = leftRes.ir,
                        .right = right_res.ir,
                    });
                    try popLocals(c, var_start, node);
                    if (cy.Trace) {
                        try check_locals(c, var_start, node);
                    }
                    return;
                },
                else => {
                    log.tracev("leftRes {s} {*}", .{@tagName(leftRes.resType), leftRes.type});
                    return c.reportErrorFmt("Assignment to the left `{}` is unsupported.", &.{v(left_n.type())}, node);
                }
            }
        },
        else => {},
    }
    return c.reportErrorFmt("Assignment to the left `{}` is unsupported.", &.{v(left_n.type())}, node);
}

fn semaIndexExpr2(c: *cy.Chunk, left: ExprResult, left_n: *ast.Node, arg0: ExprResult, arg0_n: *ast.Node, node: *ast.Node) !ExprResult {
    const leftT = left.type;

    const sym = try c.accessResolvedSymOrFail(leftT, "@index", node);
    const func_sym = try requireFuncSym(c, sym, node);

    const args = [2]sema_func.Argument{
        sema_func.Argument.initReceiver(left_n, left),
        sema_func.Argument.initPreResolved(arg0_n, arg0),
    };
    return c.semaCallFuncSymRec2(func_sym, &args, node);
}

fn semaSliceExpr(c: *cy.Chunk, left: *ast.Node, left_res: ExprResult, range: *ast.Range, node: *ast.Node) !ExprResult {
    //     // TODO: This auto conversion to `uint` should be defined by another `uint` compatible type that allows implicit conversion from `int`.
    //     //       @index doesn't need this special treatment since it accepts only one index arg.
    //     const start_res = try semaUintIndex(c, start);
    const sym = try c.accessResolvedSymOrFail(left_res.type, "@slice", node);
    const func_sym = try requireFuncSym(c, sym, node);
    if (range.start == null) {
        if (range.end) |end| {
            // `a[..end]` is `a[0..end]`.
            const zero = try c.semaConst(0, c.sema.i64_t, @ptrCast(range));
            const args = [_]sema_func.Argument{
                sema_func.Argument.initReceiver(left, left_res),
                sema_func.Argument.initPreResolved(@ptrCast(range), zero),
                sema_func.Argument.init(end),
            };
            return c.semaCallFuncSymRec2(func_sym, &args, node);
        }
        const args = [_]sema_func.Argument{
            sema_func.Argument.initReceiver(left, left_res),
        };
        return c.semaCallFuncSymRec2(func_sym, &args, node);
    }

    const start_arg = sema_func.Argument.init(range.start.?);
    if (range.end) |end| {
        const args = [_]sema_func.Argument{
            sema_func.Argument.initReceiver(left, left_res),
            // sema_func.Argument.initPreResolved(@ptrCast(range), start_res),
            // sema_func.Argument.initPreResolved(@ptrCast(range), end_res),
            start_arg,
            sema_func.Argument.init(end),
        };
        return c.semaCallFuncSymRec2(func_sym, &args, node);
    } else {
        const args = [_]sema_func.Argument{
            sema_func.Argument.initReceiver(left, left_res),
            // sema_func.Argument.initPreResolved(@ptrCast(range), start_res),
            start_arg,
        };
        return c.semaCallFuncSymRec2(func_sym, &args, node);
    }
}

fn sema_ptr_index(c: *cy.Chunk, ptr: ExprResult, idx: ExprResult, node: *ast.Node) !ExprResult {
    const child_t = ptr.type.cast(.pointer).child_t;

    const intptr = try sema_bitcast_nocheck(c, ptr, c.sema.i64_t, node);
    const elem_size = try c.semaConst(@intCast(child_t.size()), c.sema.i64_t, node);
    const offset = try c.ir.newExpr(.mul, idx.type, node, .{
        .left = idx.ir,
        .right = elem_size.ir,
    });
    const expr = try c.ir.newExpr(.add, idx.type, node, .{
        .left = intptr.ir,
        .right = offset,
    });
    var res = try sema_bitcast_nocheck(c, ExprResult.init2(expr), ptr.type, node);
    res.addressable = ptr.addressable;
    return res;
}

fn semaIndexExpr(c: *cy.Chunk, left: *ast.Node, left_res: ExprResult, cstr: Cstr, node: *ast.Node) !ExprResult {
    const index_expr = node.cast(.index_expr);
    if (index_expr.args.len != 1) {
        return c.reportErrorFmt("Unsupported array expr.", &.{}, node);
    }

    if (index_expr.args.ptr[0].type() == .range) {
        return semaSliceExpr(c, left, left_res, index_expr.args.ptr[0].cast(.range), node);
    }

    const leftT = left_res.type;
    if (leftT.isPointer()) {
        const idx = try c.semaExprCstr(index_expr.args.ptr[0], c.sema.i64_t);
        const res = try sema_ptr_index(c, left_res, idx, node);
        return semaDeref(c, res, node);
    }

    const args = [2]sema_func.Argument{
        sema_func.Argument.initReceiver(left, left_res),
        sema_func.Argument.init(index_expr.args.ptr[0]),
    };

    // Will first look for @index_addr.
    if (try c.accessResolvedSym(leftT, "@index_addr", node)) |sym| {
        const func_sym = try requireFuncSym(c, sym, node);
        var res = try c.semaCallFuncSymRec2(func_sym, &args, node);
        res.addressable = true;

        if (res.type.isPointer() or res.type.kind() == .borrow) {
            return semaDeref(c, res, node);
        } else if (res.type.isInstanceOf(c.sema.ref_child_tmpl)) {
            const ptr_t = res.type.cast(.struct_t).fields_ptr[1].type;
            if (cstr.target_t) |target_t| {
                if (target_t.id() == res.type.id()) {
                    // Target wants the RefChild.
                    return res;
                }
            }
            // `semaField` will manage the RefChild.
            res = try semaField(c, res, node, 1, ptr_t, node);
            return semaDeref(c, res, node);
        } else {
            return c.reportErrorFmt("Expected `Ptr`, `Borrow`, or `RefChild` return type for `@index_addr`.", &.{}, node);
        }
    } else {
        if (cstr.use_as_borrow) {
            return c.reportErrorFmt("Cannot borrow. Missing `@index_addr`.", &.{}, node);
        }
    }

    // Fallback to @index.
    const sym = try c.accessResolvedSymOrFail(leftT, "@index", node);
    const func_sym = try requireFuncSym(c, sym, node);
    return c.semaCallFuncSymRec2(func_sym, &args, node);
}

pub fn semaUnwrapResultNoCheck(c: *cy.Chunk, rec: ExprResult, node: *ast.Node) !ExprResult {
    const base_t = rec.type.getBaseType();
    if (base_t.kind() != .result) {
        return c.reportErrorFmt("Expected result type.", &.{}, node);
    }
    const payload_t = base_t.cast(.result).child_t;

    const final_rec = try semaManage(c, rec, node);
    var loc = try c.ir.newExpr(.field, payload_t, node, .{
        .idx = 1,
        .rec = final_rec.ir,
    });
    loc = try c.ir.newExpr(.case, payload_t, node, .{
        .child = loc,
        .union_t = rec.type,
        .case = 1,
    });
    var res = ExprResult.initField(loc, final_rec.recParentLocal());
    res.addressable = final_rec.addressable;
    return res;
}

pub fn semaUnwrapResultErrorNoCheck(c: *cy.Chunk, rec: ExprResult, node: *ast.Node) !ExprResult {
    const base_t = rec.type.getBaseType();
    if (base_t.kind() != .result) {
        return c.reportErrorFmt("Expected result type.", &.{}, node);
    }
    const final_rec = try semaManage(c, rec, node);
    var loc = try c.ir.newExpr(.field, c.sema.error_t, node, .{
        .idx = 1,
        .rec = final_rec.ir,
    });
    loc = try c.ir.newExpr(.case, c.sema.error_t, node, .{
        .child = loc,
        .union_t = rec.type,
        .case = 0,
    });
    var res = ExprResult.initField(loc, final_rec.recParentLocal());
    res.addressable = final_rec.addressable;
    return res;
}

fn semaUnwrapOptionNoCheck(c: *cy.Chunk, rec: ExprResult, node: *ast.Node) !ExprResult {
    if (rec.type.kind() != .option) {
        return c.reportErrorFmt("Expected option type.", &.{}, node);
    }

    const option_t = rec.type.cast(.option);
    if (option_t.zero_union) {
        return rec;
    } else {
        const final_rec = try semaManage(c, rec, node);
        const loc = try c.ir.newExpr(.field, option_t.child_t, node, .{
            .idx = 1,
            .rec = final_rec.ir,
        });
        const parent_local = try final_rec.recParentLocalOrError(c, node);
        var res = ExprResult.initField(loc, parent_local);
        res.addressable = true;
        return res;
    }
}

fn semaAccessChoicePayload(c: *cy.Chunk, rec: ExprResult, name: []const u8, node: *ast.Node) !ExprResult {
    const sym = rec.type.sym().getMod().getSym(name) orelse {
        return c.reportErrorFmt("Choice case `{}` does not exist in `{}`.", &.{v(name), v(rec.type.name())}, node);
    };
    if (sym.type != .choice_case) {
        return c.reportErrorFmt("Choice `{}` does not have a case named `{}`.", &.{v(rec.type.name()), v(name)}, node);
    }
    const final_rec = try semaManage(c, rec, node);
    const payload_t = sym.cast(.choice_case).payload_t;
    const loc = try c.ir.newExpr(.field, payload_t, node, .{
        .idx = 1,
        .rec = final_rec.ir,
    });
    var res = ExprResult.initCustom(loc, .field, payload_t, undefined);
    res.addressable = true;
    return res;
}

fn semaAccessFieldName(c: *cy.Chunk, rec_n: *ast.Node, rec: ExprResult, name: []const u8, field: *ast.Node) !ExprResult {
    var type_ = rec.type;

    if (type_.kind() == .c_union) {
        const mod = type_.sym().getMod();
        const sym = mod.getSym(name) orelse {
            const type_name = try c.sema.allocTypeName(type_);
            defer c.alloc.free(type_name);
            return c.reportErrorFmt("Case `{}` does not exist in `{}`.", &.{v(name), v(type_name)}, field);
        };

        if (sym.type != .union_case) {
            return c.reportErrorFmt("`{}` is not a union case.", &.{v(name)}, field);
        }
        const case = sym.cast(.union_case);

        var final_rec = rec;
        if (!rec.addressable) {
            final_rec = try semaManage(c, rec, rec_n);
        }
        var loc = try c.ir.newExpr(.field, case.payload_t, field, .{
            .idx = 0,
            .rec = final_rec.ir,
        });
        loc = try c.ir.newExpr(.case, case.payload_t, field, .{
            .child = loc,
            .union_t = rec.type,
            .case = case.idx,
        });

        const parent_local = final_rec.recParentLocal();
        var res = ExprResult.initField(loc, parent_local);
        res.addressable = true;
        return res;
    }

    type_ = type_.getBaseType();
    const mod = type_.sym().getMod();

    const sym = mod.getSym(name) orelse {
        if (type_.has_embeddings()) {
            if (try get_embedded_sym(c, type_.cast(.struct_t), name, @ptrCast(field))) |embedded_res| {
                if (embedded_res.sym.type == .field) {
                    const embedded_field = embedded_res.sym.cast(.field);
                    const final_rec = try semaField(c, rec, @ptrCast(field), embedded_res.field_idx, embedded_res.embedded_t, @ptrCast(field));
                    return semaField(c, final_rec, @ptrCast(field), embedded_field.idx, embedded_field.type, @ptrCast(field));
                }
            }
        }

        if (try c.getResolvedSym(&type_.sym().head, "@get", field)) |get_sym| {
            const func_sym = try requireFuncSym(c, get_sym, field);

            const field_name = try c.heap.init_eval_str(name);
            defer c.heap.release(field_name);

            const args = [_]sema_func.Argument{
                sema_func.Argument.initReceiver(rec_n, rec),
                sema_func.Argument.initPreResolved(field, ExprResult.initCtValue2(c.sema.eval_str_t, field_name)),
            };
            var call = try c.semaCallFuncSymRec2(func_sym, &args, field);
            const parent_local = rec.recParentLocal();
            call = ExprResult.initField(call.ir, parent_local);
            call.owned = true;
            return call;
        }

        var child_t: *cy.Type = undefined;
        if (type_.kind() == .pointer) {
            child_t = type_.cast(.pointer).child_t;
        } else if (type_.kind() == .borrow) {
            child_t = type_.cast(.borrow).child_t;
        } else if (type_.kind() == .ex_borrow) {
            child_t = type_.cast(.ex_borrow).child_t;
        } else {
            const type_name = try c.sema.allocTypeName(type_);
            defer c.alloc.free(type_name);
            return c.reportErrorFmt("Field `{}` does not exist in `{}`.", &.{v(name), v(type_name)}, field);
        }
        const child_ts = child_t.sym();
        const sym = child_ts.getMod().getSym(name) orelse {
            const type_name = try c.sema.allocTypeName(child_t);
            defer c.alloc.free(type_name);
            return c.reportErrorFmt("Field `{}` does not exist in `{}`.", &.{v(name), v(type_name)}, field);
        };
        try cy.module.check_sym_visible(c, sym, field);
        if (sym.type != .field) {
            const type_name = try c.sema.allocTypeName(child_t);
            defer c.alloc.free(type_name);
            return c.reportErrorFmt("Type `{}` does not have a field named `{}`.", &.{v(type_name), v(name)}, field);
        }
        const field_s = sym.cast(.field);
        // Access on typed pointer.
        const final_rec = try semaManage(c, rec, rec_n);
        const loc = try c.ir.newExpr(.field, field_s.type, field, .{
            .idx = @intCast(field_s.idx),
            .rec = final_rec.ir,
        });

        const parent_local = final_rec.recParentLocal();
        var res = ExprResult.initField(loc, parent_local);
        res.addressable = true;
        return res;
    };
    try cy.module.check_sym_visible(c, sym, field);
    if (sym.type != .field) {
        const type_name = type_.name();
        return c.reportErrorFmt("Type `{}` does not have a field named `{}`.", &.{v(type_name), v(name)}, field);
    }
    const field_sym = sym.cast(.field);
    return semaField(c, rec, rec_n, field_sym.idx, field_sym.type, field);
}

/// The accessed member is alive when any of its states is active.
/// A nested struct member stays accessible while only some of its own members were moved out.
fn check_struct_access_path(c: *cy.Chunk, node: *ast.Node) !void {
    const fields = c.proc().var_active_struct_fields.get(c.temp_access_path.var_id).?;
    const start = c.temp_access_path.struct_field_offset;
    const states = fields[start..start + c.temp_access_path.state_len];
    if (states.len == 0 or std.mem.findScalar(bool, states, true) != null) {
        return;
    } else {
        return c.reportError("Member is no longer alive.", node);
    }
}

/// A partially moved value can not be used as a whole (copied, borrowed, moved): the moved members are dead.
/// `expr` carries the access path from `semaLocal` / `semaField` when its root local has inactive members.
fn checkPartialMoveWhole(c: *cy.Chunk, expr: ExprResult, action: []const u8, node: *ast.Node) !void {
    if (!expr.check_struct_field_access) {
        return;
    }
    const fields = c.proc().var_active_struct_fields.get(c.temp_access_path.var_id).?;
    const start = c.temp_access_path.struct_field_offset;
    const states = fields[start..start + c.temp_access_path.state_len];
    if (std.mem.findScalar(bool, states, false) != null) {
        return c.reportErrorFmt("Cannot {} a partially moved value.", &.{v(action)}, node);
    }
}

pub fn ensure_partial_struct_layout(c: *cy.Chunk, fields: []bool) !*PartialStructLayout {
    const res = try c.sema.partial_struct_layouts.getOrPut(c.alloc, fields);
    if (!res.found_existing) {
        const dupe = try c.alloc.dupe(bool, fields);
        res.key_ptr.* = dupe;
        res.value_ptr.* = try c.alloc.create(PartialStructLayout);
        res.value_ptr.*.* = .{
            .fields = dupe,
        };
    }
    return res.value_ptr.*;
}

/// Backtrack from ExprResult to build temp access path.
fn build_move_access_path(c: *cy.Chunk, res: ExprResult, node: *ast.Node) !bool {
    const var_id = res.recParentLocal() orelse {
        return c.reportError("Can only move a local or local member.", node);
    };
    c.temp_access_path.var_id = var_id;
    c.temp_access_path.struct_field_offset = 0;
    c.temp_access_path.state_len = 1;
    var expr = res.ir;
    var field_access = false;
    var root = true;
    // The member being moved is the outermost field access, or the first one after a choice payload unwrap.
    var moved_member_known = false;
    while (true) {
        switch (expr.code) {
            .local => {
                if (expr.type.isObjectLike() and !root) {
                    return c.reportError("Cannot move a member from a shared reference.", node);
                }
                return field_access;
            },
            .field => {
                const field = expr.cast(.field);
                const member_t = expr.type;
                expr = field.rec;
                if (expr.type.isObjectLike()) {
                    return c.reportError("Cannot move a member from a shared reference.", node);
                }
                const rec_struct = expr.type.cast(.struct_t);
                if (rec_struct.base.sym().has_decl("@deinit")) {
                    return c.reportErrorFmt("Cannot move a member out of `{}`. The type has a custom `@deinit`.", &.{v(expr.type.name())}, node);
                }
                const state_offset = rec_struct.fields()[field.idx].state_offset;
                c.temp_access_path.struct_field_offset += state_offset;
                if (!moved_member_known) {
                    c.temp_access_path.state_len = sema_type.fieldStateLen(member_t);
                    moved_member_known = true;
                }
                field_access = true;
            },
            .deref => {
                expr = expr.cast(.deref).expr;
            },
            .unwrap_addr => {
                expr = expr.cast(.unwrap_addr).choice;
                c.temp_access_path.struct_field_offset = 0;
                moved_member_known = false;
            },
            .address_of => {
                expr = expr.cast(.address_of).expr;
            },
            else => {
                return c.reportError("Can only move a local or local member.", node);
            },
        }
        root = false;
    }
}

pub fn semaField(c: *cy.Chunk, rec: ExprResult, rec_n: *ast.Node, idx: usize, field_t: *cy.Type, node: *ast.Node) !ExprResult {
    var final_rec = rec;
    if (!rec.addressable) {
        final_rec = try semaManage(c, rec, rec_n);
    }
    const expr = try c.ir.newExpr(.field, field_t, node, .{
        .idx = @intCast(idx),
        .rec = final_rec.ir,
    });

    // const parent_local = try final_rec.recParentLocalOrError(c, node);
    const parent_local = final_rec.recParentLocal();
    var res = ExprResult.initField(expr, parent_local);

    // final_rec is ensured to be addressable.
    res.addressable = final_rec.addressable;
    if (rec.check_struct_field_access and rec.type.kind() == .struct_t) {
        step_member_access_path(c, rec.type, idx, field_t);
        try check_struct_access_path(c, node);
        res.check_struct_field_access = true;
    }
    return res;
}

/// Advance `c.temp_access_path` from a struct `rec_t` to its member `idx` of type `field_t`.
/// A struct with a custom `@deinit` occupies a single state (`sema_type.fieldStateLen`) and is moved as a whole,
/// so its members share that state and the path stays on it. Stepping into them with `fieldStateLen(field_t)`
/// would read the states of the following members (or past the end of the state vector) (F-80).
fn step_member_access_path(c: *cy.Chunk, rec_t: *cy.Type, idx: usize, field_t: *cy.Type) void {
    if (rec_t.sym().has_decl("@deinit")) {
        return;
    }
    c.temp_access_path.struct_field_offset += rec_t.cast(.struct_t).fields()[idx].state_offset;
    c.temp_access_path.state_len = sema_type.fieldStateLen(field_t);
}

pub fn checkSymInitField(c: *cy.Chunk, type_sym: *cy.Sym, name: []const u8, node: *ast.Node) !InitFieldResult {
    const sym = type_sym.getMod().?.getSym(name) orelse {
        // // TODO: This depends on @get being known, make sure @get is a nested declaration.
        // const type_e = c.sema.types.items[type_sym.getStaticType().?];
        // if (type_e.has_get) {
        //     return .{ .idx = undefined, .typeId = undefined, .use_get_method = true };
        // } else {
            const type_name = type_sym.name();
            return c.reportErrorFmt("Field `{}` does not exist in `{}`.", &.{v(name), v(type_name)}, node);
        // }
    };
    try cy.module.check_sym_visible(c, sym, node);
    if (sym.type != .field) {
        const type_name = type_sym.name();
        return c.reportErrorFmt("Type `{}` does not have a field named `{}`.", &.{v(type_name), v(name)}, node);
    }
    const field = sym.cast(.field);
    return .{
        .idx = @intCast(field.idx),
        .type = field.type,
    };
}

const SetFieldResult = struct {
    type: *cy.Type,
    idx: u8,
    use_set_method: bool,
};

const InitFieldResult = struct {
    type: *cy.Type,
    idx: u8,
};

pub fn reserveFuncTemplateSym(c: *cy.Chunk, parent: *cy.Sym, name: []const u8, decl: *ast.TemplateDecl) !*cy.sym.FuncTemplate {
    return c.reserveFuncTemplateSym(parent, name, decl.params.len == 0, decl);
}

pub fn reserveTemplate(c: *cy.Chunk, node: *ast.TemplateDecl) !*cy.sym.Template {
    var name_n: *ast.Node = undefined;
    var template_t: cy.sym.TemplateType = undefined;
    switch (node.child_decl.type()) {
        .struct_decl => {
            name_n = node.child_decl.cast(.struct_decl).name;
            template_t = .struct_t;
        },
        .enumDecl => {
            name_n = node.child_decl.cast(.enumDecl).name;
            template_t = .enum_t;
        },
        .custom_type_decl => {
            name_n = node.child_decl.cast(.custom_type_decl).name;
            template_t = .custom_t;
        },
        .type_alias_decl => {
            name_n = node.child_decl.cast(.type_alias_decl).name;
            template_t = .type_alias;
        },
        .type_const_decl => {
            name_n = node.child_decl.cast(.type_const_decl).name;
            template_t = .type_const;
        },
        .trait_decl => {
            name_n = node.child_decl.cast(.trait_decl).name;
            template_t = .trait_t;
        },
        else => {
            return c.reportErrorFmt("Unsupported type template.", &.{}, @ptrCast(node));
        }
    }
    return c.reserveTemplate(&c.sym.head, name_n.declName(), template_t, node);
}

pub fn resolveGenericFunc(c: *cy.Chunk, func: *cy.Func, sig: *cy.FuncSig, params: []cy.sym.FuncTemplateParam) !void {
    const decl = func.decl.?.cast(.funcDecl);
    const template = c.alloc.create(cy.sym.FuncTemplate) catch |err| {
        for (params) |param| {
            param.deinit(c.alloc);
        }
        c.alloc.free(params);
        return err;
    };
    template.* = .{
        .head = cy.Sym.init(.func_template, func.parent.parent.?, func.name()),
        .func_params = decl.params.slice(),
        .func_ret = decl.ret,
        .sig = sig,
        .with_cstrs = &.{},
        .params = params,
        .resolved = true,
        .callable = true,
        .decl = @ptrCast(decl),
        .instance_cache = .empty,
        .instances = .empty,
        .mod = undefined,
    };
    // The kind changes together with its payload. `Func.destroy` and `deinit_func_ct_values` read `data.generic`
    // from the kind alone.
    func.type = .generic;
    func.data = .{ .generic = template };
    try c.resolveFunc(func, sig);
}

pub fn resolveFuncTemplate(c: *cy.Chunk, template: *cy.sym.FuncTemplate) !void {
    try pushSymResolveContext(c, @ptrCast(template), @ptrCast(template.decl));
    defer popResolveContext(c);

    const decl = template.decl.cast(.template);
    template.params = try c.alloc.alloc(cy.sym.FuncTemplateParam, decl.params.len);
    var param_group_end: usize = cy.NullId;
    for (decl.params, 0..) |param, idx| {
        const name = param.name_type.as_name();
        var type_idx: u32 = undefined;
        if (param.type == null) {
            if (param_group_end == cy.NullId or idx > param_group_end) {
                param_group_end = indexOfTypedParam(decl.params, idx+1) orelse {
                    return c.reportError("Expected parameter type.", @ptrCast(param));
                };
            }
            type_idx = @intCast(param_group_end);
        } else {
            type_idx = @intCast(idx);
        }
        template.params[idx] = .{
            .anonymous = false,
            .name = name,
            .type_idx = type_idx,
        };
    }

    const func_decl = decl.child_decl.cast(.funcDecl);
    if (func_decl.with) |with| {
        template.with_cstrs = try resolve_with_cstrs(c, with);
    }

    template.resolved = true;
}

fn resolve_with_cstrs(c: *cy.Chunk, with: *ast.With) ![]cy.sym.WithCstr {
    const with_cstrs = try c.alloc.alloc(cy.sym.WithCstr, with.params.len);
    for (with.params.slice(), 0..) |param, i| {
        const param_name = param.name_type.as_name();
        const cstr_t = try cte.eval_type2(c, false, param.type.?);
        with_cstrs[i] = .{
            .name = param_name,
            .cstr_t = cstr_t,
        };
    }
    return with_cstrs;
}

pub fn ensure_resolved_instance_func_decl(c: *cy.Chunk, decl: *cy.sym.VariantFuncDecl) !void {
    if (decl.resolved) {
        return;
    }
    if (decl.decl.with) |with| {
        const cstrs = try resolve_with_cstrs(c, with);
        decl.with_cstrs = .{ .ptr = cstrs.ptr, .len = cstrs.len };
    }
    decl.resolved = true;
}

pub fn check_instance_func_cstr(c: *cy.Chunk, instance: *cy.Instance, decl: *cy.sym.VariantFuncDecl, node: *ast.Node) !void {
    for (decl.with_cstrs.slice()) |cstr| {
        const param = instance.getParam(cstr.name) orelse {
            return c.reportErrorFmt("Expected parameter type `{}`.", &.{v(cstr.name)}, node);
        };
        const impl_t = param.value.asPtr(*cy.Type);
        if (!try sema_type.implements(c, impl_t, cstr.cstr_t.cast(.generic_trait), node)) {
            const impl_name = try c.sema.allocTypeName(impl_t);
            defer c.alloc.free(impl_name);
            const trait_name = try c.sema.allocTypeName(cstr.cstr_t);
            defer c.alloc.free(trait_name);
            return c.reportErrorFmt("Expected `{}` to implement `{}`.", &.{v(impl_name), v(trait_name)}, node);
        }
    }
}

pub fn resolveTemplate(c: *cy.Chunk, sym: *cy.sym.Template) !void {
    try pushSymResolveContext(c, @ptrCast(sym), @ptrCast(sym.decl));
    defer popResolveContext(c);

    const tparams = try c.alloc.alloc(cy.sym.TemplateParam, sym.decl.params.len);
    errdefer c.alloc.free(tparams);
    for (sym.decl.params, 0..) |param, i| {
        const param_name = param.name_type.nameOrNull() orelse {
            return c.reportErrorFmt("Expected name, found {}.", &.{v(param.name_type.type())}, param.name_type);
        };
        tparams[i] = .{
            .name = param_name,
        };
    }
    sym.params = tparams;
}

pub fn reserveUseAlias(c: *cy.Chunk, node: *ast.UseAlias) !*cy.sym.UseAlias {
    const name = node.name.as_name();
    return c.reserveUseAlias(@ptrCast(c.sym), name, @ptrCast(node));
}

pub fn resolveUseAlias(c: *cy.Chunk, sym: *cy.sym.UseAlias) anyerror!void {
    if (sym.resolved) {
        return;
    }

    if (sym.resolve_with_sym) {
        if (sym.sym.type == .chunk) {
            // Already points to a sym but needs to ensure module is loaded.
            try sema.pushSymResolveContext(c, @ptrCast(sym), @ptrCast(sym.decl));
            defer sema.popResolveContext(c);
            const chunk_sym = sym.sym.cast(.chunk);
            try cy.compiler.loadChunk(chunk_sym.chunk);
        } else if (sym.sym.type == .type_alias) {
            // Alias points to a type alias.
            try sema.pushSymResolveContext(c, @ptrCast(sym.sym), @ptrCast(sym.decl));
            defer sema.popResolveContext(c);
            try sema_type.resolve_type_alias(c, sym.sym.cast(.type_alias));
            sym.sym = &sym.sym.cast(.type_alias).sym.head;
        } else if (sym.sym.type == .use_alias) {
            // Alias points to another alias.
            try sema.pushSymResolveContext(c, @ptrCast(sym.sym), @ptrCast(sym.decl));
            defer sema.popResolveContext(c);
            try resolveUseAlias(c, sym.sym.cast(.use_alias));
            sym.sym = sym.sym.cast(.use_alias).sym;
        }
        sym.resolved = true;
    } else {
        try sema.pushSymResolveContext(c, @ptrCast(sym), @ptrCast(sym.decl));
        defer sema.popResolveContext(c);

        const r_sym = try cte.evalSym(c, sym.decl.?.cast(.use_alias).target);
        sym.sym = r_sym;
        sym.resolved = true;
    }
}

pub fn declareUseImport(c: *cy.Chunk, node: *ast.ImportStmt) !void {
    for (node.attrs.slice()) |attr| {
        if (attr.type == .cond) {
            const res = try cte.evalCheck(c, attr.value.?, c.sema.bool_t);
            if (!res.value.asBool()) {
                // Skip import.
                return;
            }
        }
    }

    var specPath: []const u8 = undefined;
    if (node.spec) |spec| {
        if (spec.type() != .sq_string_lit) {
            // use alias.
            return c.reportErrorFmt("TODO", &.{}, spec);
        }
        specPath = spec.cast(.sq_string_lit).asString();
    } else {
        if (node.name.type() == .ident) {
            // Single ident import.
            specPath = node.name.cast(.ident).name.slice();
        } else {
            // use path.
            return c.reportErrorFmt("TODO", &.{}, @ptrCast(node));
        }
    }

    var buf: [4096]u8 = undefined;
    const uri = try cy.compiler.resolveModuleUriFrom(c, &buf, specPath, node.spec);

    const import_c = try cy.compiler.ensureModule(c.compiler, uri);
    try c.imports.append(c.alloc, import_c);
    if (import_c.importer == null) {
        import_c.importer = @ptrCast(node);
    }

    if (node.name.type() == .all) {
        // Block on * import until it's symbols have been reserved.
        try cy.compiler.loadChunk(import_c);

        // Import all symbols into this module.
        for (import_c.syms.items) |sym| {
            if (sym.getMetadata().private) {
                continue;
            }
            const alias = try c.reserveUseAlias(@ptrCast(c.sym), sym.name(), @ptrCast(node));
            alias.sym = sym;
            alias.resolve_with_sym = true;
        }
    } else {
        const name = node.name.as_name();
        const alias = try c.reserveUseAlias(@ptrCast(c.sym), name, @ptrCast(node));
        alias.sym = @ptrCast(import_c.sym);
        alias.resolve_with_sym = true;
    }
}

// TODO: Rename to SemaContextKind
const ResolveContextType = enum(u8) {
    chunk,
    sym,
    func,
};

pub const CtParam = struct {
    type_header: u64,
    value: Value,

    pub fn initParam(value: cy.TypeValue) CtParam {
        return .{ .type_header = @intFromPtr(value.type), .value = value.value };
    }

    pub fn initVar(value: cy.TypeValue) CtParam {
        return .{ .type_header = @as(u64, 1 << 63) | @intFromPtr(value.type), .value = value.value };
    }

    pub fn getType(self: *const CtParam) *cy.Type {
        const addr: usize = @intCast(self.type_header & ~(@as(u64, 1) << 63));
        return @ptrFromInt(addr);
    }

    pub fn isVar(self: *const CtParam) bool {
        return (self.type_header & (1 << 63)) > 0;
    }
};

// TODO: Rename to SemaContext
pub const ResolveContext = struct {
    type: ResolveContextType,
    has_ct_params: bool,

    /// Prefer the comptime type when encountering a runtime type. (e.g. For template param types)
    prefer_ct_type: bool = false,

    allow_rt_stmts: bool = true,

    /// Compile-time params in this context.
    /// TODO: Avoid hash map if 2 or fewer ct params.
    ct_params: std.StringHashMapUnmanaged(CtParam),

    ct_locals: std.ArrayList([]const u8),

    is_inline_eval: bool = false,

    chunk: *cy.Chunk,
    caller: ?*ast.Node,

    data: union {
        sym: *cy.Sym,
        func: *cy.Func,
    },

    pub fn deinit(self: *ResolveContext, c: *cy.Chunk) void {
        var iter = self.ct_params.iterator();
        while (iter.next()) |e| {
            const param = e.value_ptr.*;
            c.heap.destructValue2(param.getType(), param.value);
        }
        self.ct_params.deinit(c.alloc);
        self.ct_locals.deinit(c.alloc);
    }

    pub fn pushCtBlock(self: *ResolveContext) usize {
        return self.ct_locals.items.len;
    }

    pub fn popCtBlock(self: *ResolveContext, c: *cy.Chunk, local_start: usize) void {
        for (self.ct_locals.items[local_start..]) |local| {
            if (self.ct_params.contains(local)) {
                self.unsetCtParam(c.heap, local);
            }
        }
        self.ct_locals.items.len = local_start;
    }

    pub fn hasCtParam(self: *ResolveContext, name: []const u8) bool {
        return self.ct_params.contains(name);
    }

    pub fn initCtParam(self: *ResolveContext, alloc: std.mem.Allocator, name: []const u8, val: cy.TypeValue) !void {
        const res = try self.ct_params.getOrPut(alloc, name);
        if (res.found_existing) {
            return error.DuplicateParam;
        }
        res.value_ptr.* = CtParam.initParam(val);
    }

    pub fn initCtParam2(self: *ResolveContext, alloc: std.mem.Allocator, name: []const u8, val_t: *cy.Type, val: cy.Value) !void {
        try self.initCtParam(alloc, name, cy.TypeValue.init(val_t, val));
    }

    pub fn initCtVar(self: *ResolveContext, alloc: std.mem.Allocator, name: []const u8, val: cy.TypeValue) !void {
        const res = try self.ct_params.getOrPut(alloc, name);
        if (res.found_existing) {
            return error.DuplicateParam;
        }
        res.value_ptr.* = CtParam.initVar(val);
    }

    pub fn initCtVar2(self: *ResolveContext, alloc: std.mem.Allocator, name: []const u8, val_t: *cy.Type, val: cy.Value) !void {
        try self.initCtVar(alloc, name, cy.TypeValue.init(val_t, val));
    }

    pub fn setCtParam(self: *ResolveContext, heap: *cy.Heap, name: []const u8, val_t: *cy.Type, val: cy.Value) !void {
        const res = try self.ct_params.getOrPut(heap.alloc, name);
        if (res.found_existing) {
            const param = res.value_ptr.*;
            heap.destructValue2(param.getType(), param.value);
        }
        res.value_ptr.* = CtParam.initParam(cy.TypeValue.init(val_t, val));
    }

    pub fn setCtVar(self: *ResolveContext, heap: *cy.Heap, name: []const u8, val_t: *cy.Type, val: cy.Value) !void {
        const res = try self.ct_params.getOrPut(heap.alloc, name);
        if (res.found_existing) {
            const param = res.value_ptr.*;
            heap.destructValue2(param.getType(), param.value);
        }
        res.value_ptr.* = CtParam.initVar(cy.TypeValue.init(val_t, val));
    }

    pub fn unsetCtParam(self: *ResolveContext, heap: *cy.Heap, name: []const u8) void {
        const pair = self.ct_params.fetchRemove(name).?;
        heap.destructValue2(pair.value.getType(), pair.value.value);
    }

    pub fn getSelfSym(self: *const ResolveContext) ?*cy.Sym {
        if (self.type == .func) {
            if (self.data.func.parent.type == .func) {
                if (self.data.func.parent.parent.?.type == .type) {
                    return self.data.func.parent.parent.?;
                }
            } else if (self.data.func.parent.type == .func_template) {
                if (self.data.func.parent.parent.?.type == .type) {
                    return self.data.func.parent.parent.?;
                } else if (self.data.func.parent.parent.?.type == .func) {
                    if (self.data.func.parent.parent.?.parent.?.type == .type) {
                        // generic func variant under a type.
                        return self.data.func.parent.parent.?.parent.?;
                    }
                }
            }
        } else if (self.type == .sym) {
            if (self.data.sym.type == .type) {
                return self.data.sym;
            }
            if (self.data.sym.parent.?.type == .type) {
                return self.data.sym.parent.?;
            }
        }
        return null;
    }
};

pub fn pushSymResolveContext(c: *cy.Chunk, sym: *cy.Sym, caller: ?*ast.Node) !void {
    const new = ResolveContext{
        .type = .sym,
        .has_ct_params = false,
        .ct_params = .empty,
        .ct_locals = .empty,
        .chunk = c.compiler.chunks.items[sym.declNode().src()],
        .caller = caller,
        .data = .{ .sym = sym },
    };
    try pushResolveContext2(c, new, caller);
}

pub fn pushFuncResolveContext(c: *cy.Chunk, func: *cy.Func, caller: ?*ast.Node) !void {
    const new = ResolveContext{
        .type = .func,
        .has_ct_params = false,
        .ct_params = .empty,
        .ct_locals = .empty,
        .chunk = c.compiler.chunks.items[func.src()],
        .caller = caller,
        .data = .{ .func = func },
    };
    try pushResolveContext2(c, new, caller);
}

pub fn pushChunkResolveContext(c: *cy.Chunk, caller: ?*ast.Node) !void {
    const new = ResolveContext{
        .type = .chunk,
        .has_ct_params = false,
        .ct_params = .empty,
        .ct_locals = .empty,
        .chunk = c,
        .caller = caller,
        .data = undefined,
    };
    try pushResolveContext2(c, new, caller);
}

pub fn pushResolveContext2(c: *cy.Chunk, ctx: ResolveContext, node: ?*ast.Node) !void {
    // Maximum limit to prevent recursive template expansions.
    // TODO: Another approach might involve determining if expanding template args contain a derived type from a type parameter.
    //       If it does and the template is already expanding, it would be a cycle.
    if (c.resolve_stack.items.len > 20) {
        return c.reportError("Maximum resolve depth reached.", node);
    }
    try c.resolve_stack.append(c.alloc, ctx);
}

pub fn pushSavedResolveContext(c: *cy.Chunk, ctx: ResolveContext) !void {
    try c.resolve_stack.append(c.alloc, ctx);
}

pub fn popResolveContext(c: *cy.Chunk) void {
    const last = &c.resolve_stack.items[c.resolve_stack.items.len-1];
    last.deinit(c);
    c.resolve_stack.items.len -= 1;
}

pub fn saveResolveContext(c: *cy.Chunk) ResolveContext {
    const last = c.resolve_stack.items[c.resolve_stack.items.len-1];
    c.resolve_stack.items.len -= 1;
    return last;
}

pub fn reserve_func_instance(c: *cy.Chunk, template: *cy.sym.FuncTemplate, instance: *cy.Instance) !*cy.Func {
    var decl: *ast.FuncDecl = undefined;
    if (template.decl.type() == .funcDecl) {
        decl = template.decl.cast(.funcDecl);
    } else {
        decl = @ptrCast(@alignCast(template.decl.cast(.template).child_decl));
    }

    var extern_ = false;
    for (decl.attrs.slice()) |attr| {
        if (attr.type == .extern_) {
            extern_ = true;
        }
    }
    const config = cy.sym.FuncConfig{
        .is_method = decl.sig_t == .method,
        .extern_ = extern_,
    };
    const func = try c.createFunc(.unresolved, &template.head, config, @ptrCast(decl));
    func.instance = instance;
    try c.funcs.append(c.alloc, func);
    return func;
}

pub fn resolveFuncVariant(c: *cy.Chunk, func: *cy.Func, resolve_new_types: bool, node: ?*ast.Node) !void {
    if (func.isResolved()) {
        return;
    }

    const decl = func.decl.?.cast(.funcDecl);
    if (ast.findAttr(decl.attrs.slice(), .bind) != null) {
        func.type = .hostFunc;
        func.data = .{ .hostFunc = .{
            .ptr = undefined,
        }};
        try sema.resolveHostFuncVariant(c, func, resolve_new_types, node);
    } else {
        func.type = .userFunc;
        func.data = .{.userFunc = .{.loc = undefined}};
        try sema.resolveUserFuncVariant(c, func, resolve_new_types, node);
    }
}

pub fn ensure_resolved_func(c: *cy.Chunk, func: *cy.Func, resolve_new_types: bool, node: ?*ast.Node) !void {
    if (func.isResolved()) {
        return;
    }

    switch (func.type) {
        .unresolved,
        .trait => {
            // continue.
        },
        .reserved,
        .generic,
        .userFunc,
        .hostFunc,
        .extern_,
        .vm_extern_variant,
        .host_builtin,
        .host_const_eval => {
            return error.Unexpected;
        },
        .userLambda => {
            return;
        },
    }

    try pushFuncResolveContext(c, func, node);
    defer popResolveContext(c);

    const decl = func.decl.?.cast(.funcDecl);
    var bind_attr: ?*ast.Attribute = null;
    var extern_attr: ?*ast.Attribute = null;
    const has_generator = decl.generator;
    const builtin_mod = isBuiltinModuleNode(c, @ptrCast(decl));
    if (!builtin_mod) {
        const func_name = func.name();
        if (func_name.len > 0 and func_name[0] == '@' and !hook_names.has(func_name)) {
            return c.reportErrorFmt("Unknown hook `{}`. A function name can start with `@` only when it is a hook that the compiler calls, such as `@init` or `@deinit`.", &.{v(func_name)}, decl.name);
        }
    }
    for (decl.attrs.slice()) |attr| {
        if (!builtin_mod) {
            switch (attr.type) {
                .unsafe, .consteval, .reserve => {
                    return c.reportErrorFmt("The `#[{}]` attribute is reserved for the builtin modules.", &.{v(@tagName(attr.type))}, @ptrCast(attr));
                },
                else => {},
            }
        }
        switch (attr.type) {
            .bind => {
                bind_attr = attr;
            },
            .extern_ => {
                extern_attr = attr;
            },
            .consteval => {
                func.info.const_eval_only = true;
            },
            .reserve => {
                func.type = .reserved;
                const sig = try ensure_opaque_func_sig(c, decl.params.len);
                try c.resolveFunc(func, sig);
                return;
            },
            else => {},
        }
    }

    if (bind_attr != null) {
        const bind_func = try resolveHostBindFunc(c, func, bind_attr.?);
        if (bind_func.kind == C.BindFuncVm) {
            if (c.compiler.config.backend != C.BackendVM and decl.stmts.len == 0) {
                return c.reportError("Expected function implementation.", @ptrCast(func.decl));
            }
        } else if (bind_func.kind == C.BindFuncBuiltin) {
            const sig = try ensure_opaque_func_sig(c, decl.params.len);
            try c.resolveHostBuiltinFunc(func, sig, @ptrCast(@alignCast(bind_func.ptr)), @ptrCast(@alignCast(bind_func.ptr2)));
            return;
        }
    }

    var generic: GenericFuncResult = undefined;
    var sig = try resolveFuncSig(c, func, resolve_new_types, &generic, false);
    if (generic.generic) {
        try resolveGenericFunc(c, func, sig, generic.params);
    } else {
        if (bind_attr != null) {
            try resolveHostFunc(c, func, sig);
            return;
        }

        if (extern_attr) |attr| {
            if (func.isMethod()) {
                return c.reportError("@extern function cannot be a method.", @ptrCast(func.decl));
            }
            func.type = .extern_;
            var extern_name = func.name();
            c.has_extern_func = true;
            if (try attr.getString()) |name| {
                extern_name = name;
            }
            func.data = .{
                .extern_ = try c.alloc.create(cy.sym.ExternFunc),
            };
            func.data.extern_.* = .{
                .name_ptr = extern_name.ptr,
                .name_len = @intCast(extern_name.len),
                .vm_variadic = false,
                .has_impl = decl.stmts.len > 0,
                .ir = undefined,
            };
            try c.resolveUserFunc(func, sig);
            if (sig.params_len > 0 and sig.params_ptr[sig.params_len-1].get_type().kind() == .c_variadic) {
                if (c.compiler.config.backend == C.BackendVM) {
                    func.data.extern_.vm_variadic = true;
                }
            }
            return;
        }

        if (has_generator) {
            sig = try resolveGeneratorSig(c, func, sig);
        }

        if (func.type == .trait) {
            try c.resolveUserFunc(func, sig);
        } else {
            if (decl.stmts.len == 0) {
                return c.reportError("Expected function body.", @ptrCast(decl));
            }
            func.type = .userFunc;
            func.data = .{.userFunc = .{.loc = undefined}};
            try c.resolveUserFunc(func, sig);
        }
    }
}

fn resolveHostFunc2(c: *cy.Chunk, func: *cy.Func, bind_func: C.BindFunc, sig: *FuncSig) !void {
    switch (bind_func.kind) {
        C.BindFuncVm => {
            try c.resolveHostFunc(func, sig, @ptrCast(@alignCast(bind_func.ptr)), @ptrCast(@alignCast(bind_func.ptr2)));
        },
        C.BindFuncConstEval => {
            try c.resolveHostConstEvalFunc(func, sig, @ptrCast(@alignCast(bind_func.ptr)));
        },
        C.BindFuncDecl => {
            func.type = .userFunc;
            func.data = .{.userFunc = .{.loc = undefined}};
            try c.resolveUserFunc(func, sig);
            if (bind_func.ptr2) |eval| {
                func.data.userFunc.eval = @ptrCast(@alignCast(eval));
            }
        },
        else => {
            return c.reportErrorFmt("Unsupported", &.{}, func.decl);
        },
    }
}

fn resolveHostFunc(c: *cy.Chunk, func: *cy.Func, sig: *FuncSig) !void {
    const decl = func.decl.?.cast(.funcDecl);
    const attr = ast.findAttr(decl.attrs.slice(), .bind).?;
    const bind_func = try resolveHostBindFunc(c, func, attr);
    try resolveHostFunc2(c, func, bind_func, sig);
}

pub fn resolveHostFuncVariant(c: *cy.Chunk, func: *cy.Func, resolve_new_types: bool, node: ?*ast.Node) !void {
    try pushFuncResolveContext(c, func, node);
    defer popResolveContext(c);

    var generic: GenericFuncResult = undefined;
    const sig = try resolveFuncSig(c, func, resolve_new_types, &generic, true);
    try resolveHostFunc(c, func, sig);
}

pub fn resolveHostBindFunc(c: *cy.Chunk, func: *cy.Func, host_attr: *ast.Attribute) !C.BindFunc {
    const src_c = c.compiler.chunks.items[func.src()];

    const host_name = try host_attr.getString();
    var name_buf: [128]u8 = undefined;
    const bind_name = host_name orelse b: {
        var w = std.Io.Writer.fixed(&name_buf);
        try cy.sym.writeFuncName(c.sema, &w, func, .{ .from = src_c, .emit_template_args = false });
        break :b w.buffered();
    };
    log.tracev("Lookup embedded func for: {s}", .{bind_name});
    return src_c.host_funcs.get(bind_name) orelse {
        return src_c.fallback_bind_func orelse {
            return c.reportErrorFmt("Host func `{}` failed to load.", &.{v(bind_name)}, @ptrCast(func.decl));
        };
    };
}

/// Marks `func` as a generator and returns its signature with the return type `^Generator[fn(params) -> T]`.
/// Template instances resolve through `resolveUserFuncVariant`, so this is shared with `ensure_resolved_func`.
fn resolveGeneratorSig(c: *cy.Chunk, func: *cy.Func, sig: *cy.FuncSig) !*cy.FuncSig {
    const decl = func.decl.?.cast(.funcDecl);
    // The generator outlives the call that created it: its frame is snapshotted to the heap and resumed
    // later. A borrow parameter would keep a stack address past the caller's frame (use-after-return),
    // and the snapshot does not go through `semaLift` where `^borrow` is rejected.
    var rt_param_idx: usize = 0;
    for (decl.params.slice()) |param| {
        if (param.template_param) continue;
        const param_t = sig.params()[rt_param_idx].get_type();
        rt_param_idx += 1;
        if (param_t.info.borrow_only) {
            const name = try c.sema.allocTypeName(param_t);
            defer c.alloc.free(name);
            return c.reportErrorFmt("A `generator fn` can not take the borrow type `{}` as a parameter. The generator outlives the call, so pass an owned value or a `^T` pointer instead.", &.{v(name)}, @ptrCast(param));
        }
    }
    func.info.generator = true;
    // Modify func signature return type.
    const decl_sig = try c.sema.ensureFuncSig(sig.params(), sig.ret);
    const funcptr_t = try getFuncPtrType(c, decl_sig);
    const gen_t = try getGeneratorType(c, funcptr_t);
    const ret_t = try getRefType(c, gen_t);
    return c.sema.ensureFuncSig(sig.params(), ret_t);
}

pub fn resolveUserFuncVariant(c: *cy.Chunk, func: *cy.Func, resolve_new_types: bool, node: ?*ast.Node) !void {
    try pushFuncResolveContext(c, func, node);
    defer popResolveContext(c);

    var generic: GenericFuncResult = undefined;
    var sig = try resolveFuncSig(c, func, resolve_new_types, &generic, true);
    std.debug.assert(!generic.generic);

    if (func.decl.?.cast(.funcDecl).generator) {
        sig = try resolveGeneratorSig(c, func, sig);
    }

    if (!func.info.const_eval_only) {
        for (sig.params()) |param| {
            if (param.get_type().info.ct) {
                return c.reportError("Expected `#fn` declaration when signature contains a type declared with `#type`.", func.decl);
            }
        }
    }

    c.resolveFuncInfo(func, sig);
}

pub fn reserveImplicitTraitMethod(c: *cy.Chunk, parent: *cy.Sym, decl: *ast.FuncDecl, vtable_idx: usize) !*cy.Func {
    if (decl.stmts.len > 0) {
        return c.reportErrorFmt("Trait methods should not have a body.", &.{}, @ptrCast(decl));
    }
    const func = try c.reserveTraitFunc(parent, decl.name.declName(), decl, vtable_idx);
    return func;
}

pub fn semaMethodBody(c: *cy.Chunk, func: *cy.Func) !void {
    if (func.info.emitted) {
        return;
    }
    try pushFuncResolveContext(c, func, null);
    defer popResolveContext(c);
    try semaMethodBody2(c, func);
}

pub fn semaMethodBody2(c: *cy.Chunk, func: *cy.Func) !void {
    // Object method.
    const blockId = try pushFuncProc(c, func);
    c.semaProcs.items[blockId].isMethodBlock = true;

    const parent_t = func.sig.params()[0].get_type();
    try pushMethodParamVars(c, parent_t, func);
    if (func.info.generator) {
        try semaGeneratorPrologue(c, func);
    }
    try semaStmts(c, func.decl.?.cast(.funcDecl).stmts.slice());
    try procPrologue(c);
    try popFuncBlock(c);
}

/// Emitted after the parameters are declared. The call that creates the generator runs up to `ret_gen`, which
/// snapshots the frame and returns the generator. Methods need it as well as functions.
fn semaGeneratorPrologue(c: *cy.Chunk, func: *cy.Func) !void {
    const node = func.decl.?.cast(.funcDecl);
    const proc = c.proc();

    // Retain params with reference type, since the regular call convention will optimize it out.
    // Other params are already managed.
    for (c.varStack.items[proc.varStart..]) |param| {
        if (param.decl_t.isRefPointer()) {
            var copy = try semaLocal(c, param.stack_idx, @ptrCast(node));
            copy = try semaOwn(c, copy, @ptrCast(node));
            _ = try c.ir.pushStmt(.set_local, @ptrCast(node), .{
                .id = @intCast(param.inner.local.id),
                .right = copy.ir,
            });
        }
    }

    const gen_t = proc.func.?.sig.ret.cast(.pointer).child_t;
    const funcptr_t = gen_t.instanceOf(c.sema.generator_tmpl).?.params[0].asPtr(*cy.Type);
    const val_t = funcptr_t.cast(.func_ptr).sig.ret;
    const opt_t = try getOptionType(c, val_t);

    try c.ir.pushStmtBlock(c.alloc);
    {
        const b = c.procBlock();
        try semaDestructBlock2(c, b);
        if (c.ir.stmtBlockStack.items[c.ir.stmtBlockStack.items.len-1].first != null) {
            _ = try c.ir.pushStmt(.yield, @ptrCast(node), .{
                .deinit_head = null,
                .ret_opt_t = opt_t,
                .end = true,
            });
        }
    }
    const block = c.ir.popStmtBlock();

    // Returns the generator.
    _ = try c.ir.pushStmt(.ret_gen, @ptrCast(node), .{
        .gen_t = func.sig.ret,
        .next_t = opt_t,
        .deinit_head = block.first,
    });
}

pub fn semaFuncBody(c: *cy.Chunk, func: *cy.Func) !void {
    if (func.info.emitted) {
        return;
    }
    try pushFuncResolveContext(c, func, null);
    defer popResolveContext(c);
    try semaFuncBody2(c, func);
}

pub fn semaFuncBody2(c: *cy.Chunk, func: *cy.Func) !void {
    const node = func.decl.?.cast(.funcDecl);
    _ = try pushFuncProc(c, func);
    try appendFuncParamVars(c, node.params.slice(), @ptrCast(func.sig.params()));
    if (func.info.generator) {
        try semaGeneratorPrologue(c, func);
    }
    try semaStmts(c, node.stmts.slice());
    try procPrologue(c);
    try popFuncBlock(c);
}

pub fn reserveConst(c: *cy.Chunk, parent: *cy.Sym, name: []const u8, decl: *ast.ConstDecl) !*cy.Sym {
    if (decl.right == null) {
        // // No initializer.
        // if (ast.findAttr(decl.attrs, .host) != null) {
        //     return @ptrCast(try c.reserveHostVar(decl_path.parent, decl_path.name.base_name, decl));
        // }
        return c.reportErrorFmt("`{}` does not have an initializer.", &.{v(name)}, @ptrCast(decl));
    } else {
        return @ptrCast(try c.reserveConst(parent, name, decl));
    }
}

pub fn reserveGlobal(c: *cy.Chunk, decl: *ast.GlobalDecl) !?*Sym {
    const decl_path = try ensureDeclNamePath(c, @ptrCast(c.sym), decl.parent, decl.name);
    if (decl.right == null) {
        // No initializer.
        var has_bind = false;
        var has_extern = false;
        for (decl.attrs.slice()) |attr| {
            if (attr.type == .bind) {
                has_bind = true;
            } else if (attr.type == .extern_) {
                has_extern = true;
            } else if (attr.type == .cond) {
                const res = try cte.evalCheck(c, attr.value.?, c.sema.bool_t);
                if (!res.value.asBool()) {
                    return null;
                }
            }
        }
        if (has_bind) {
            return @ptrCast(try c.reserveHostVar(decl_path.parent, decl_path.name.name, decl));
        }
        if (has_extern) {
            return @ptrCast(try c.reserveExternVar(decl_path.parent, decl_path.name.name, decl));
        }
        return c.reportErrorFmt("`{}` does not have an initializer.", &.{v(decl_path.name.name)}, @ptrCast(decl));
    } else {
        return @ptrCast(try c.reserveUserVar(decl_path.parent, decl_path.name.name, decl));
    }
}

pub fn resolveConst(c: *cy.Chunk, sym: *cy.sym.Const) !void {
    if (sym.isResolved()) {
        return;
    }
    try pushSymResolveContext(c, @ptrCast(sym), null);
    defer popResolveContext(c);

    const node = sym.decl.?;

    sym.resolving_init = true;
    var type_: *cy.Type = undefined;
    var res: cy.TypeValue = undefined;
    if (node.type) |type_n| {
        type_ = try cte.eval_type2(c, true, type_n);
        // Only allow types that can be expanded at compile-time. `ct_expand.value`
        if (!type_.isConstEligible()) {
            const name = try c.sema.allocTypeName(type_);
            defer c.alloc.free(name);
            if (type_.id() == bt.Str) {
                return c.reportErrorFmt("Expected const eligible type, found `{}`. Consider using `EvalStr` which can coerce to a runtime `str`.", &.{v(name)}, type_n);
            }
            if (type_.kind() == .vector) {
                return c.reportErrorFmt("TODO: const `{}`. Alternatively, use the `global` declaration.", &.{v(name)}, if (node.type != null) @ptrCast(node.type.?) else node.right.?);
            }
            return c.reportErrorFmt("Expected const eligible type, found `{}`.", &.{v(name)}, if (node.type != null) @ptrCast(node.type.?) else node.right.?);
        }
        res = try cte.evalCheck(c, node.right.?, type_);
    } else {
        res = try cte.eval(c, node.right.?);
        type_ = res.type;
    }
    errdefer c.heap.destructValue(res);

    sym.type = type_;
    sym.value = res.value;

    // Compile-time exclusive types do not have cached IR.
    if (type_.id() == bt.EvalStr) {
        sym.ir = null;
    } else {
        sym.ir = (try ct_inline.value(c, res, null, node.right.?)).ir;
    }
    sym.resolved = true;
    sym.resolving_init = false;
}

/// Resolves the variable's type and initializer.
/// If type spec is not provided, the initializer is resolved to obtain the type.
pub fn resolveUserVar(c: *cy.Chunk, sym: *cy.sym.UserVar) !void {
    if (sym.isResolved()) {
        return;
    }

    try pushSymResolveContext(c, @ptrCast(sym), null);
    defer popResolveContext(c);

    const decl_n = sym.decl.?;
    const var_t = try cte.eval_type2(c, true, decl_n.typeSpec);

    c.resolveUserVarType(sym, var_t);
    sym.resolving_init = false;
}

pub fn semaUserVarInit(c: *cy.Chunk, sym: *cy.sym.UserVar, ref_node: ?*ast.Node) !void {
    if (sym.emitted) {
        return;
    }

    if (sym.resolving_init) {
        return;
    }

    const node = sym.decl.?;

    // Ensure resolved type.
    const src_chunk = c.compiler.getSymChunk(&sym.head);

    _ = ref_node;
    try resolveUserVar(src_chunk, sym);
    
    try pushSymResolveContext(c, @ptrCast(sym), null);
    defer popResolveContext(c);

    c.cur_sema_proc.global_init = true;
    defer c.cur_sema_proc.global_init = false;
    c.cur_sema_proc.global_init_var = sym;
    defer c.cur_sema_proc.global_init_var = null;

    // Wrap in block to keep the same local state when loading each static variable.
    _ = try sema.pushBlock(c, @ptrCast(node));
    const res = try c.semaExprCstr(node.right.?, sym.type);

    try sema.semaTraceNopFmt(c, "init {s}", .{sym.head.name()}, @ptrCast(node));
    _ = try c.ir.pushStmt(.set_global, @ptrCast(node), .{
        .sym = @ptrCast(sym),
        .expr = res.ir,
    });

    const block = try sema.popBlock(c);
    _ = try c.ir.pushStmt(.block, @ptrCast(node), .{ .bodyHead = block.first });
    sym.resolving_init = false;
    sym.emitted = true;
}

pub fn resolveExternVar(c: *cy.Chunk, sym: *cy.sym.ExternVar) !void {
    if (sym.resolved) {
        return;
    }
    try pushSymResolveContext(c, @ptrCast(sym), @ptrCast(sym.decl));
    defer popResolveContext(c);

    const decl = sym.decl.?;
    sym.type = try cte.eval_type2(c, true, decl.typeSpec);
    var extern_name = sym.head.name();
    const attr = cy.ast.findAttr(sym.decl.?.attrs.slice(), .extern_).?;
    if (try attr.getString()) |str| {
        extern_name = str;
    }
    sym.extern_name_ptr = extern_name.ptr;
    sym.extern_name_len = extern_name.len;
    sym.resolved = true;
}

pub fn writeBindName(w: anytype, sym: *cy.Sym) !void {
    if (sym.instance() != null) {
        const parent = sym.parent.?.parent.?;
        if (parent.type != .chunk) {
            try w.writeAll(parent.name());
        }
    } else {
        const parent = sym.parent.?;
        if (parent.type != .chunk) {
            try w.writeAll(parent.name());
        }
    }
    try w.writeAll(sym.name());
}

pub fn resolveHostVar(c: *cy.Chunk, sym: *cy.sym.HostVar) !void {
    if (sym.isResolved()) {
        return;
    }
    try pushSymResolveContext(c, @ptrCast(sym), @ptrCast(sym.decl));
    defer popResolveContext(c);

    const decl = sym.decl.?;

    c.tempBufU8.clearRetainingCapacity();
    const w = stdx.listWriter(&c.tempBufU8, c.alloc);
    try writeBindName(w, &sym.head);
    const bind_name = c.tempBufU8.items;

    const var_t = try cte.eval_type2(c, true, decl.typeSpec);

    // Value is consumed from loader.
    log.tracev("Invoke var loader for: {s}", .{bind_name});
    const binding = c.host_globals.get(bind_name) orelse {
        return c.reportErrorFmt("Host var `{}` failed to load.", &.{v(bind_name)}, @ptrCast(decl));
    };
    try c.resolveHostVar(sym, var_t, binding.ptr.?);
}

fn declareParam(c: *cy.Chunk, param: *ast.FuncParam, isSelf: bool, paramIdx: usize, declT: *cy.Type) !void {
    _ = paramIdx;
    var name: []const u8 = undefined;
    if (isSelf) {
        name = "self";
    } else {
        name = param.name_type.as_name();
    }

    const proc = c.proc();
    if (!isSelf) {
        if (proc.var_cache_entries.get(name)) |varInfo| {
            std.debug.assert(varInfo.type == .local);
            const data = varInfo.data.local;
            if (data.blockId == c.semaBlocks.items.len - 1) {
                return c.reportErrorFmt("Function param `{}` is already declared.", &.{v(name)}, @ptrCast(param));
            }
        }
    }
    const local_id = c.varStack.items.len - proc.varStart;
    try checkLocalLimit(c, local_id, @ptrCast(param));

    const id = try pushLocalVar(c, .local, name, declT, false);
    var svar = &c.varStack.items[id];
    svar.inner = .{
        .local = .{
            .id = @intCast(local_id),
            .isParam = true,
            .hasInit = false,
            .declIrStart = undefined,
            .hidden = false,
        },
    };
    proc.numParams += 1;
}

const LocalResult = struct {
    id: u32, 
    ir_id: u32,
};

fn declareLocalInit(c: *cy.Chunk, name: []const u8, decl_t: *cy.Type, init: ExprResult, node: *ast.Node) !LocalResult {
    const var_id = try declareLocalName(c, name, decl_t, false, true, node);
    const info = c.varStack.items[var_id].inner.local;
    info.declIrStart.cast(.declare_local).init = init.ir;
    return .{ .id = var_id, .ir_id = info.id };
}

pub fn declareHiddenLocal(c: *cy.Chunk, name: []const u8, decl_t: *cy.Type, init_opt: ?ExprResult, node: *ast.Node) !LocalResult {
    const var_id = try declareLocalName(c, name, decl_t, true, init_opt != null, node);
    const info = c.varStack.items[var_id].inner.local;
    if (init_opt) |init| {
        info.declIrStart.cast(.declare_local).init = init.ir;
    }
    return .{ .id = var_id, .ir_id = info.id };
}

fn reserveLocalName(c: *cy.Chunk, name: []const u8, declType: *cy.Type, hidden: bool, hasInit: bool, node: *ast.Node) anyerror!LocalId {
    // Pending operands get their locals first. Later than this, a flush would declare a local in the middle of
    // this declaration, and its statement would come before this one with a later IR id.
    if (c.ir.seq_pending > 0) try seqFlush(c);
    if (!hidden) {
        const proc = c.proc();
        if (proc.var_cache_entries.get(name)) |varInfo| {
            switch (varInfo.type) {
                .local => {
                    const data = varInfo.data.local;
                    if (data.blockId == c.semaBlocks.items.len - 1) {
                        const svar = &c.varStack.items[data.varId];
                        if (svar.type == .local) {
                            if (svar.inner.local.allow_redeclare) {
                                // Destruct before redeclaring.
                                try semaDestructLocal(c, svar, node);
                            } else {
                                return c.reportErrorFmt("Variable `{}` is already declared in the block.", &.{v(name)}, node);
                            }
                        }
                    } else {
                        // Create shadow entry for restoring the prev var.
                        try c.varShadowStack.append(c.alloc, .{
                            .namePtr = name.ptr,
                            .nameLen = @intCast(name.len),
                            .varId = data.varId,
                            .blockId = data.blockId,
                        });
                    }
                },
                .capture => {
                    return c.reportErrorFmt("Variable `{}` is a captured variable in the function.", &.{v(name)}, node);
                },
            }
        }
    }

    const proc = c.proc();
    const local_id = c.varStack.items.len - proc.varStart;
    try checkLocalLimit(c, local_id, node);
    const id = try pushLocalVar(c, .local, name, declType, hidden);
    var svar = &c.varStack.items[id];

    log.tracev("reserve ir local: {s} {}", .{name, local_id});

    svar.inner = .{ .local = .{
        .id = @intCast(local_id),
        .isParam = false,
        .hasInit = hasInit,
        .hidden = hidden,
        .declIrStart = undefined,
    }};
    return id;
}

/// IR local ids are `u8` (`LocalVarS.id`, `ir.DeclareLocal.id`, `ir.FuncParam.reg`), so a proc can hold
/// at most 256 params, locals and hidden temporaries. Report a compile error instead of overflowing the cast.
pub const max_proc_locals = std.math.maxInt(u8) + 1;

fn checkLocalLimit(c: *cy.Chunk, local_id: usize, node: *ast.Node) !void {
    if (local_id >= max_proc_locals) {
        return c.reportErrorFmt("Too many local variables. A function can have at most {} locals, including hidden temporaries.", &.{v(@as(u32, max_proc_locals))}, node);
    }
}

/// `FuncSig.numParams`, `Proc.numParams` and the call IR `nargs` are `u8`, so a signature holds at most 255 params
/// and a call passes at most 255 args (C variadic calls can exceed the param count).
pub const max_func_params = std.math.maxInt(u8);

pub fn checkParamLimit(c: *cy.Chunk, nparams: usize, node: *ast.Node) !void {
    if (nparams > max_func_params) {
        return c.reportErrorFmt("Too many parameters. A function can have at most {} parameters.", &.{v(@as(u32, max_func_params))}, node);
    }
}

pub fn checkArgLimit(c: *cy.Chunk, nargs: usize, node: *ast.Node) !void {
    if (nargs > max_func_params) {
        return c.reportErrorFmt("Too many arguments. A call can have at most {} arguments.", &.{v(@as(u32, max_func_params))}, node);
    }
}

/// The struct init IR `nargs` and the field IR `idx` are `u8`.
pub const max_struct_fields = std.math.maxInt(u8);

pub fn checkFieldLimit(c: *cy.Chunk, nfields: usize, node: *ast.Node) !void {
    if (nfields > max_struct_fields) {
        return c.reportErrorFmt("Too many fields. A struct can have at most {} fields.", &.{v(@as(u32, max_struct_fields))}, node);
    }
}

fn declareLocalName(c: *cy.Chunk, name: []const u8, decl_t: *cy.Type, hidden: bool, hasInit: bool, node: *ast.Node) !LocalId {
    const id = try reserveLocalName(c, name, decl_t, hidden, hasInit, node);
    const local = &c.varStack.items[id];
    try semaTraceNopFmt(c, "declare: {s} {}", .{name, id}, node);
    if (cy.Trace) {
        const type_name = try c.sema.allocTypeName(decl_t);
        defer c.alloc.free(type_name);
        log.tracev("push declare {s} {} {s}", .{name, local.inner.local.id, type_name});
    }
    const irIdx = try c.ir.pushStmt(.declare_local, node, .{
        .name_ptr = name.ptr,
        .name_len = @as(u16, @intCast(name.len)),
        .decl_t = decl_t,
        .id = local.inner.local.id,
        .init = null,
    });
    local.inner.local.declIrStart = irIdx;
    return id;
}

fn declareLocal(c: *cy.Chunk, ident: *ast.Node, declType: *cy.Type, hasInit: bool) !LocalId {
    const name = ident.cast(.ident).name.slice();
    return declareLocalName(c, name, declType, false, hasInit, ident);
}

fn localDecl(c: *cy.Chunk, node: *ast.VarDecl) !void {
    var var_t: *cy.Type = c.sema.void_t;
    var has_target_type = true;
    if (node.typeSpec == null) {
        has_target_type = false;
    } else {
        var_t = try cte.eval_type2(c, true, node.typeSpec.?);
    }

    var name: []const u8 = undefined;
    var var_idx: usize = undefined;
    if (node.name.type() == .void_lit) {
        // Hidden discard variable.
        name = "_";
        var_idx = try reserveLocalName(c, name, var_t, true, true, node.name);
    } else {
        name = node.name.cast(.ident).name.slice();
        var_idx = try reserveLocalName(c, name, var_t, false, true, node.name);
    }
    try semaTraceNopFmt(c, "declare: {s} {}", .{name, var_idx}, @ptrCast(node));

    var svar = &c.varStack.items[var_idx];
    svar.type = .dead;
    const declare = try c.ir.pushStmt(.declare_local, node.name, .{
        .name_ptr = name.ptr,
        .name_len = @as(u16, @intCast(name.len)),
        .decl_t = var_t,
        .id = svar.inner.local.id,
        .init = null,
    });
    svar.inner.local.declIrStart = declare;

    var var_start = c.varStack.items.len;
    var init_after_aux = false;

    // Infer rhs type and enforce constraint.
    // It shouldn't matter if an rvalue gets its lifetime extended `var x = &<rvalue>`
    // since that local and the one reserved will be destructed together.
    var right = try c.semaExpr(node.right, .{
        .target_t = if (has_target_type) var_t else null,
        .reqTypeCstr = has_target_type,
        .fit_target = has_target_type,
        .assign_to_local = true,
    });

    if (right.type.info.borrow_only and right.resType == .value) {
        if (right.data.value.parent_local) |parent_local| {
            if (c.varStack.items[parent_local].lifetime.kind == .temp) {
                return c.reportErrorFmt("Cannot assign to local `{}` with a value that has a shorter lifetime.", &.{v(name)}, node.right);
            }
        }
        if (right.data.value.has_aux_local) {
            // The aux local (`_vec` of a `[&]T{...}` literal) outlives this statement, but its `declare_local`
            // was pushed after `declare`, so the init has to follow it as a `set_local`.
            var_start += 1;
            init_after_aux = true;
        }
    }

    right = try semaOwn(c, right, node.right);
    if (!has_target_type) {
        var_t = right.type;
        c.varStack.items[var_idx].decl_t = right.type;
        declare.cast(.declare_local).decl_t = var_t;
    }
    if (var_t.info.borrow_only and c.vm.config.persist_main and c.proc().func == null and c.semaBlocks.items.len == 1) {
        // Top level locals are carried over to the next eval by moving their values into new stack slots.
        // A borrow would keep pointing at the old slot, which is freed once the stack grows, and a `[&]T{...}`
        // literal borrows a hidden vector that is not carried over at all.
        const type_name = try c.sema.allocTypeName(var_t);
        defer c.alloc.free(type_name);
        return c.reportErrorFmt("Cannot persist local `{}` of borrow type `{}` across evals. Declare it inside a block or use an owned type.", &.{v(name), v(type_name)}, node.right);
    }

    // Local now alive.
    svar = &c.varStack.items[var_idx];
    svar.type = .local;
    bindBorrowLocal(c, @intCast(var_idx), right);
    if (var_start == c.varStack.items.len and !init_after_aux) {
        declare.cast(.declare_local).init = right.ir;
    } else {
        _ = try c.ir.pushStmt(.set_local, @ptrCast(node), .{
            .id = @intCast(svar.inner.local.id),
            .right = right.ir,
        });
    }

    if (c.vm.config.persist_main) {
        if (c.proc().func == null and c.semaBlocks.items.len == 1) {
            // Main block.
            try semaTrackMainLocal(c, svar, @ptrCast(node));
        }
    }

    try popLocals(c, var_start, @ptrCast(node));

    if (cy.Trace) {
        try check_locals(c, var_start, @ptrCast(node));
    }
}

/// REPL (`persist_main`): the last top level expression statement becomes the eval result (`CLEvalResult`).
/// The value moves into a hidden local that `@mainResult` reports to the VM, which copies it after the run
/// (`Compiler.main_res`). Mirrors `localDecl` with an inferred type. An expression without a value keeps the usual
/// expression statement rules. See `docs/decisions/project_repl_result.md`.
fn semaMainResultStmt(c: *cy.Chunk, node: *ast.Node) !void {
    c.curNode = node;
    c.cur_cont_expr = null;
    const child = node.cast(.exprStmt).child;

    // Reserved before the expression so that its temporaries are popped without it.
    const name = "_main_res";
    const var_idx = try reserveLocalName(c, name, c.sema.void_t, true, true, node);
    try semaTraceNopFmt(c, "declare: {s} {}", .{name, var_idx}, node);
    var svar = &c.varStack.items[var_idx];
    svar.type = .dead;
    const declare = try c.ir.pushStmt(.declare_local, node, .{
        .name_ptr = name.ptr,
        .name_len = @as(u16, @intCast(name.len)),
        .decl_t = c.sema.void_t,
        .id = svar.inner.local.id,
        .init = null,
    });
    svar.inner.local.declIrStart = declare;

    var var_start = c.varStack.items.len;
    var init_after_aux = false;
    var right = try c.semaExpr(child, .{ .assign_to_local = true });
    const no_value = right.type.id() == bt.Void or right.type.id() == bt.Never or right.type.kind() == .result or
        (right.resType == .ct_value and right.data.ct_value.type.id() == bt.Void);
    if (no_value) {
        // The hidden local stays a void local without an init.
        return semaExprStmtEnd(c, right, var_start, child);
    }

    if (right.resType == .value_local) {
        // An existing local is shown without copying it (its type may not be copyable). The VM only frees
        // its snapshot: the persisted local keeps owning the value.
        const local = &c.varStack.items[right.data.value_local];
        try semaMainResult(c, local.decl_t, local.stack_idx, true, node);
        try popLocals(c, var_start, node);
        return;
    }

    if (right.type.info.borrow_only and right.resType == .value) {
        if (right.data.value.parent_local) |parent_local| {
            if (c.varStack.items[parent_local].lifetime.kind == .temp) {
                return c.reportError("The result can not borrow from a temporary value.", child);
            }
        }
        if (right.data.value.has_aux_local) {
            // See `localDecl`: the aux local's `declare_local` comes after `declare`.
            var_start += 1;
            init_after_aux = true;
        }
    }
    right = try semaOwn(c, right, child);

    svar = &c.varStack.items[var_idx];
    svar.decl_t = right.type;
    declare.cast(.declare_local).decl_t = right.type;
    svar.type = .local;
    if (var_start == c.varStack.items.len and !init_after_aux) {
        declare.cast(.declare_local).init = right.ir;
    } else {
        _ = try c.ir.pushStmt(.set_local, node, .{
            .id = @intCast(svar.inner.local.id),
            .right = right.ir,
        });
    }

    try semaMainResult(c, svar.decl_t, svar.stack_idx, false, node);

    try popLocals(c, var_start, node);
    if (cy.Trace) {
        try check_locals(c, var_start, node);
    }
}

/// `@mainResult(type_id, addr, borrowed)`: tells the VM where the eval result lives.
fn semaMainResult(c: *cy.Chunk, val_t: *cy.Type, stack_idx: u32, borrowed: bool, node: *ast.Node) !void {
    const type_id = try c.semaConst(val_t.id(), c.sema.i64_t, node);
    const local_ref = try semaLocal(c, stack_idx, node);
    const addr = try semaAddressOf(c, local_ref, c.sema.ptr_void_t, node);
    const borrowed_v = try c.semaConst(@intFromBool(borrowed), c.sema.bool_t, node);
    const args = [_]sema_func.Argument{
        sema_func.Argument.initPreResolved(node, type_id),
        sema_func.Argument.initPreResolved(node, addr),
        sema_func.Argument.initPreResolved(node, borrowed_v),
    };
    const call = try c.semaCallFunc2(c.sema.main_result_fn, &args, &.{}, node);
    _ = try declareHiddenLocal(c, "@res", c.sema.void_t, call, node);
}

fn semaTrackMainLocal(c: *cy.Chunk, local: *Local, node: *ast.Node) !void {
    const name = try c.semaRawString(local.name(), node);
    const type_id = try c.semaConst(local.decl_t.id(), c.sema.i64_t, node);
    const local_ref = try semaLocal(c, local.stack_idx, node);
    const addr = try semaAddressOf(c, local_ref, c.sema.ptr_void_t, node);
    const args = [_]sema_func.Argument{
        sema_func.Argument.initPreResolved(node, name),
        sema_func.Argument.initPreResolved(node, type_id),
        sema_func.Argument.initPreResolved(node, addr),
    };
    const call = try c.semaCallFunc2(c.sema.track_main_local_fn, &args, &.{}, node);
    _ = try declareHiddenLocal(c, "@res", c.sema.void_t, call, node);
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

    fn hasTargetType(self: Cstr) bool {
        return self.target_t != null;
    }
};

pub fn requireFuncSym(c: *cy.Chunk, sym: *Sym, node: *ast.Node) !*cy.sym.FuncSym {
    if (sym.type != .func) {
        return c.reportErrorFmt("Expected `{}` to be a function symbol.", &.{v(sym.name())}, node);
    }
    return sym.cast(.func);
}

// Invoke a type's sym as the callee.
fn callTypeInit(c: *cy.Chunk, sym: *Sym, sym_n: *ast.Node, args: []const *ast.Node, req_value: bool, node: *ast.Node) !ExprResult {
    const call_sym = try c.getResolvedSymOrFail(sym, "@init", sym_n);
    if (call_sym.type == .func) {
        return c.semaCallFuncSym(call_sym.cast(.func), args, req_value, node);
    } else if (call_sym.type == .func_template) {
        // const template = call_sym.cast(.func_template);
        // if (template.callable) {
        //     return c.semaCallGenericFunc(template, args, req_value, node);
        // }
    }
    return c.reportErrorFmt("Expected `{}` to be a function.", &.{v(sym.name())}, node);
}

pub fn callSym(c: *cy.Chunk, sym: *Sym, sym_node: *ast.Node, args: []*ast.Node, req_value: bool, node: *ast.Node) !ExprResult {
    try referenceSym(c, sym, sym_node);
    switch (sym.type) {
        .func => {
            const funcSym = sym.cast(.func);
            return c.semaCallFuncSym(funcSym, args, req_value, node);
        },
        .func_template => {
            // const template = sym.cast(.func_template);
            // if (template.callable) {
            //     return c.semaCallGenericFunc(template, args, req_value, node);
            // }
        },
        .variant_func => {
            return c.reportErrorFmt("`{}` was declared as a template instance function. Expand the template first.", &.{v(sym.name())}, sym_node);
        },
        .type,
        .template => {
            return callTypeInit(c, sym, sym_node, args, req_value, node);
        },
        .union_case => {
            const case = sym.cast(.union_case);
            if (case.payload_t == c.sema.void_t) {
                return c.reportErrorFmt("Can not initialize cunion member without a payload type.", &.{}, sym_node);
            }
            if (args.len != 1) {
                return c.reportErrorFmt("Expected only one payload argument for choice initializer. Found `{}`.", &.{v(args.len)}, sym_node);
            }
            var payload = try c.semaExprCstr(args[0], case.payload_t);
            payload = try semaOwn(c, payload, args[0]);
            return semaInitCunionCase(c, case.type, case.idx, payload, node);
        },
        .choice_case => {
            const case = sym.cast(.choice_case);
            if (case.payload_t == c.sema.void_t) {
                return c.reportErrorFmt("Can not initialize choice member without a payload type.", &.{}, sym_node);
            }
            if (args.len != 1) {
                return c.reportErrorFmt("Expected only one payload argument for choice initializer. Found `{}`.", &.{v(args.len)}, sym_node);
            }
            var payload = try c.semaExprCstr(args[0], case.payload_t);
            payload = try semaOwn(c, payload, args[0]);
            return semaInitChoice(c, case.type, case.idx, case.val, payload, node);
        },
        .userVar,
        .hostVar => {
            var callee = try sema.symbol(c, sym, true, sym_node);
            callee = try semaOwn(c, callee, sym_node);
            return c.semaCallValue(callee, sym_node, args, node);
        },
        else => {},
    }
    // try pushCallArgs(c, node.data.callExpr.argHead, numArgs, true);
    return c.reportErrorFmt("Unsupported call from symbol: `{}`", &.{v(sym.type)}, sym_node);
}

pub fn sema_func_sym(c: *cy.Chunk, func: *cy.Func, prefer_ct_sym: bool, opt_target: ?*cy.Type, node: *ast.Node) !ExprResult {
    const ptr_t = try cy.sema.getFuncPtrType(c, func.sig);
    if (prefer_ct_sym) {
        return ExprResult.initCustom(undefined, .func, ptr_t, .{ .func = func });
    }
    switch (func.type) {
        .generic, .host_const_eval, .host_builtin, .reserved, .trait, .vm_extern_variant => {
            // These have no runtime function to point to.
            return c.reportErrorFmt("The function `{}` can not be used as a value.", &.{v(func.name())}, node);
        },
        else => {},
    }
    func.info.escaped = true;
    var loc = try c.ir.newExpr(.func_ptr, ptr_t, node, .{ .func = func });
    var res = ExprResult.initCustom(loc, .func, ptr_t, .{ .func = func });
    if (opt_target) |target_t| {
        if (target_t.kind() == .func and func.sig == target_t.cast(.func).sig) {
            loc = try c.ir.newExpr(.func, target_t, node, .{
                .expr = res.ir,
            });
            res = ExprResult.initOwned(loc);
        }
    }
    return res;
}

pub fn symbol(c: *cy.Chunk, sym: *Sym, prefer_ct_sym: bool, node: *ast.Node) !ExprResult {
    return symbol2(c, sym, prefer_ct_sym, null, node);
}

pub fn symbol2(c: *cy.Chunk, sym: *Sym, prefer_ct_sym: bool, opt_target: ?*cy.Type, node: *ast.Node) !ExprResult {
    try referenceSym(c, sym, node);
    switch (sym.type) {
        .const_ => {
            const const_ = sym.cast(.const_);
            const src_chunk = c.compiler.chunks.items[const_.head.declNode().src()];
            try resolveConst(src_chunk, const_);

            // Use cached IR when target type matches or inferring from value.
            if (const_.ir) |expr| {
                if (opt_target) |target_t| {
                    if (target_t.id() == const_.type.id()) {
                        var const_res = ExprResult.initCustom(expr, .const_, const_.type, .{ .const_ = sym });
                        const_res.owned = true;
                        return const_res;
                    }
                } else {
                    var const_res = ExprResult.initCustom(expr, .const_, const_.type, .{ .const_ = sym });
                    const_res.owned = true;
                    return const_res;
                }
            }
            const res = try ct_inline.value(c, cy.TypeValue.init(const_.type, const_.value), opt_target, node);
            var const_res = ExprResult.initCustom(res.ir, .const_, res.type, .{ .const_ = sym });
            const_res.owned = true;
            return const_res;
        },
        .userVar => {
            // In a global initializer this is allowed for a global that is initialized earlier.
            // `global_init.check` reports the others.
            const user_var = sym.cast(.userVar);
            try cy.global_init.recordGlobal(c, user_var);
            const src_chunk = c.compiler.chunks.items[user_var.head.declNode().src()];
            try resolveUserVar(src_chunk, user_var, );
            const loc = try c.ir.newExpr(.global, user_var.type, node, .{ .sym = sym });
            var res = ExprResult.initCustom(loc, .varSym, user_var.type, .{ .varSym = sym });
            res.addressable = true;
            return res;
        },
        .extern_var => {
            if (c.cur_sema_proc.global_init) {
                // Extern globals are bound after the global initializers run (`@initBindLib`).
                return c.reportError("Cannot reference an extern global in a global initializer.", node);
            }
            const extern_var = sym.cast(.extern_var);
            const expr = try c.ir.newExpr(.global, extern_var.type, node, .{ .sym = sym });
            var res = ExprResult.initCustom(expr, .varSym, extern_var.type, .{ .varSym = sym });
            res.addressable = true;
            return res;
        },
        .hostVar => {
            // The host binds its globals when the module loads, before any initializer runs.
            const host_var = sym.cast(.hostVar);
            const loc = try c.ir.newExpr(.global, host_var.type, node, .{ .sym = sym });
            var res = ExprResult.initCustom(loc, .varSym, host_var.type, .{ .varSym = sym });
            res.addressable = true;
            return res;
        },
        .func => {
            // `symbol` being invoked suggests the func sym is not ambiguous.
            const func = sym.cast(.func);
            if (func.numFuncs != 1) {
                if (prefer_ct_sym) {
                    return ExprResult.initCustom(undefined, .sym, c.sema.void_t, .{ .sym = sym });
                }
                return c.reportError("AmbiguousSymbol", node);
            }
            return sema_func_sym(c, func.first, prefer_ct_sym, opt_target, node);
        },
        .type => {
            if (prefer_ct_sym) {
                const sym_t = sym.getStaticType().?;
                return ExprResult.initCustom(undefined, .sym, sym_t, .{ .sym = sym });
            }
            return c.reportError("Compile-time symbol cannot be used here. Consider expanding with `#{expr}` or using it in a compile-time context.", node);
        },
        .union_case => {
            const case = sym.cast(.union_case);
            if (case.payload_t.id() != bt.Void) {
                if (prefer_ct_sym) {
                    return ExprResult.initCustom(undefined, .sym, c.sema.void_t, .{ .sym = sym });
                }
                return c.reportError("Must initialize cunion case with payload.", node);
            }
            return semaInitCunionNoPayload(c, case.type, case.idx, node);
        },
        .choice_case => {
            const case = sym.cast(.choice_case);
            if (case.payload_t.id() != bt.Void) {
                if (prefer_ct_sym) {
                    return ExprResult.initCustom(undefined, .sym, c.sema.void_t, .{ .sym = sym });
                }
                return c.reportError("Must initialize choice case with payload.", node);
            }
            return semaInitChoiceNoPayload(c, case, node);
        },
        .enum_case => {
            const case = sym.cast(.enum_case);
            return c.semaConst(case.val, case.type, node);
        },
        .chunk,
        .func_template,
        .template => {
            if (prefer_ct_sym) {
                return ExprResult.initCustom(undefined, .sym, c.sema.void_t, .{ .sym = sym });
            }
        },
        .use_alias => {
            const alias = sym.cast(.use_alias);
            if (!alias.resolved) {
                try sema.resolveUseAlias(c, alias);
            }
            return symbol(c, alias.sym, prefer_ct_sym, node);
        },
        .type_alias => {
            const alias = sym.cast(.type_alias);
            if (!alias.resolved) {
                try sema_type.resolve_type_alias(c, alias);
            }
            return symbol(c, @ptrCast(alias.sym), prefer_ct_sym, node);
        },
        .field => {
            return c.reportErrorFmt("Cannot access field symbol.", &.{}, node);
        },
        else => {
            return c.reportErrorFmt("Unsupported: {}", &.{v(sym.type)}, node);
        }
    }

    return c.reportErrorFmt("Can't use symbol `{}` as a runtime value.", &.{v(sym.name())}, node);
}

pub fn semaLocal(c: *cy.Chunk, id: LocalId, node: *ast.Node) !ExprResult {
    const local = &c.varStack.items[id];
    switch (local.type) {
        .local => {
            const expr = try c.ir.newExpr(.local, local.decl_t, node, .{ .id = local.inner.local.id });
            var res = ExprResult.initLocal(expr, local.stack_idx);
            res.addressable = true;
            if (local.has_inactive_struct_fields) {
                c.temp_access_path.var_id = local.stack_idx;
                c.temp_access_path.struct_field_offset = 0;
                c.temp_access_path.state_len = local.decl_t.cast(.struct_t).field_state_len;
                res.check_struct_field_access = true;
            }
            return res;
        },
        .dead => {
            return c.reportErrorFmt("`{}` is no longer alive in this scope.", &.{v(local.name())}, node);
        },
    }
}

fn semaCaptured(c: *cy.Chunk, idx: usize, node: *ast.Node) !ExprResult {
    const info = &c.proc().captures.items[idx];
    const loc = try c.ir.newExpr(.captured, info.val_t, node, .{ .idx = @intCast(idx) });
    var res = ExprResult.initCustom(loc, .capturedLocal, info.val_t, undefined);
    res.addressable = true;
    return res;
}

fn semaIdent(c: *cy.Chunk, cstr: Cstr, prefer_ct_sym: bool, node: *ast.Node) !ExprResult {
    const name = node.cast(.ident).name.slice();
    return semaIdent2(c, cstr, prefer_ct_sym, name, node);
}

fn semaIdent2(c: *cy.Chunk, cstr: Cstr, prefer_ct_sym: bool, name: []const u8, node: *ast.Node) !ExprResult {
    const res = try lookupIdent(c, name, node);
    switch (res) {
        .local => |id| {
            return semaLocal(c, id, node);
        },
        .capture => |idx| {
            return semaCaptured(c, idx, node);
        },
        .static => |sym| {
            return sema.symbol2(c, sym, prefer_ct_sym, cstr.target_t, node);
        },
        .ct_var => {
            const var_t = res.ct_var.getType();
            const type_value = TypeValue.init(var_t, res.ct_var.value);
            return ct_inline.value(c, type_value, cstr.target_t, node);
        },
        .ct_value => |ct_value| {
            defer c.heap.destructValue(ct_value);
            return ct_inline.value(c, ct_value, cstr.target_t, node);
        },
    }
}

pub fn semaArray(c: *cy.Chunk, array_t: *cy.Type, args: []*ir.Expr, node: *ast.Node) !ExprResult {
    const init_elems = (try c.getResolvedSym(@ptrCast(array_t.sym()), "@init_sequence", node)).?;
    return sema_init_seq2(c, init_elems, args, node);
}

pub fn semaStringTemplate(c: *cy.Chunk, template: *ast.StringTemplate) !ExprResult {
    const nexprs = template.parts.len / 2;

    const str_span_t = try get_span_type(c, c.sema.str_t);
    const str_borrow_t = try getBorrowType(c, c.sema.str_t);

    // strs as [&]str
    const nstrs = nexprs+1;
    const strs_loc = try c.ir.allocArray(*ir.Expr, nstrs);
    for (0..nexprs+1) |i| {
        const str_n = template.parts[i*2];
        const str = str_n.cast(.stringt_part).value.slice();
        const str_res = try c.semaString(str, str_n);
        strs_loc[i] = str_res.ir;
    }
    const str_vec_t = try getVectorType(c, c.sema.str_t, @intCast(nstrs));
    const strs_init = try semaVector(c, str_vec_t, strs_loc, @ptrCast(template));
    const strs_local = try declareHiddenLocal(c, "_strs_vec", str_vec_t, strs_init, @ptrCast(template));
    const strs = try semaLocal(c, strs_local.id, @ptrCast(template));
    const str_base = try semaAddressOf(c, strs, str_borrow_t, @ptrCast(template));
    const str_span = try sema_span(c, str_span_t, str_base, @intCast(nstrs), @ptrCast(template));

    // exprs as [&]str
    const exprs_loc = try c.ir.allocArray(*ir.Expr, nexprs);
    const seq_tmpl_start = c.seq_pending.items.len;
    errdefer seqPop(c, seq_tmpl_start);
    for (0..nexprs) |i| {
        const expr = template.parts[1 + i*2].cast(.stringt_expr);
        const res = try c.semaExpr(expr.child, .{});

        const to_print_string_func = try getToPrintStringFunc(c, res.type, expr.child);
        const expr_arg = Argument.initPreResolved(expr.child, res);
        const expr_str = try c.semaCallFunc2(to_print_string_func, &.{expr_arg}, &.{}, expr.child);
        exprs_loc[i] = expr_str.ir;
        try seqPush(c, &exprs_loc[i], expr_str.owned, expr.child);
    }
    seqPop(c, seq_tmpl_start);
    const expr_vec_t = try getVectorType(c, c.sema.str_t, @intCast(nexprs));
    const exprs_init = try semaVector(c, expr_vec_t, exprs_loc, @ptrCast(template));
    const exprs_local = try declareHiddenLocal(c, "_exprs_vec", expr_vec_t, exprs_init, @ptrCast(template));
    const exprs = try semaLocal(c, exprs_local.id, @ptrCast(template));
    const expr_base = try semaAddressOf(c, exprs, str_borrow_t, @ptrCast(template));
    const expr_span = try sema_span(c, str_span_t, expr_base, @intCast(nexprs), @ptrCast(template));

    const sym = c.sema.str_t.sym().getMod().getSym("interpolate").?;
    const func_sym = try requireFuncSym(c, sym, @ptrCast(template));
    return c.semaCallFuncSym2(func_sym, @ptrCast(template), str_span, @ptrCast(template), expr_span, @ptrCast(template));
}

const NameResultType = enum {
    sym,
    ct_value,
    ct_var,
};

pub const NameResult = struct {
    type: NameResultType,
    data: union {
        sym: *Sym,
        ct_value: cy.TypeValue,
        ct_var: *CtParam,
    },

    fn initSym(sym: *Sym) NameResult {
        return .{ .type = .sym, .data = .{ .sym = sym, }};
    }

    fn initCtValue(ct_value: cy.TypeValue) NameResult {
        return .{ .type = .ct_value, .data = .{ .ct_value = ct_value, }};
    }

    fn initCtValue2(val_t: *cy.Type, val: cy.Value) NameResult {
        return .{ .type = .ct_value, .data = .{ .ct_value = cy.TypeValue.init(val_t, val), }};
    }

    fn initCtVar(ptr: *CtParam) NameResult {
        return .{ .type = .ct_var, .data = .{ .ct_var = ptr }};
    }
};

pub fn apiResolveName(c: *cy.Chunk, name: []const u8) ?NameResult {
    // Check top level chunks.
    const chunk = (c.get_chunk_by_uri(name) catch @panic("error")) orelse return null;
    return NameResult.initSym(@ptrCast(chunk.sym));
}

pub fn getResolvedName(c: *cy.Chunk, name: []const u8, node: *ast.Node) !?NameResult {
    const resolve_ctx_idx = c.resolve_stack.items.len-1;
    const ctx = c.resolve_stack.items[resolve_ctx_idx];
    const search_c = ctx.chunk;

    // Look in ct context.
    if (ctx.ct_params.size > 0) {
        if (ctx.ct_params.getPtr(name)) |param| {
            const param_t = param.getType();
            if (param_t.id() == bt.Type and param.value.asPtr(*cy.Type).id() == bt.Any) {
                return error.FoundDependentType;
            }

            if (param.isVar()) {
                return NameResult.initCtVar(param);
            } else {
                const new = try c.heap.copyValue2(param_t, param.value);
                return NameResult.initCtValue2(param_t, new);
            }
        }
    }

    if (ctx.type == .func) {
        if (ctx.data.func.instance) |variant| {
            if (variant.getParam(name)) |param| {
                const new_value = try c.heap.copyValue2(param.type, param.value);
                return NameResult.initCtValue2(param.type, new_value);
            }
        }

        // Start at immediate parent since it could be a sym.CtValue.
        var opt_parent: ?*cy.Sym = ctx.data.func.parent;
        while (opt_parent) |parent| {
            if (parent.instance()) |variant| {
                if (variant.getParam(name)) |param| {
                    const new_value = try c.heap.copyValue2(param.type, param.value);
                    return NameResult.initCtValue2(param.type, new_value);
                }
            }
            opt_parent = parent.parent;
        }
    } else if (ctx.type == .sym) {
        if (ctx.data.sym.instance()) |variant| {
            if (variant.getParam(name)) |param| {
                const new_value = try c.heap.copyValue2(param.type, param.value);
                return NameResult.initCtValue2(param.type, new_value);
            }
        }
    }

    if (std.mem.eql(u8, "Self", name)) {
        if (ctx.getSelfSym()) |sym| {
            return NameResult.initSym(sym);
        }
    }

    // Look in the current chunk module.
    if (try c.getResolvedSym(@ptrCast(search_c.sym), name, node)) |sym| {
        return NameResult.initSym(sym);
    }

    // Look in fallback modules.
    var i = search_c.fallback_modules.items.len;
    while (i > 0) {
        i -= 1;
        const mod_sym = search_c.fallback_modules.items[i];
        if (try cy.module.get_pub_resolved_chunk_sym(c, mod_sym.cast(.chunk), name, node)) |sym| {
            return NameResult.initSym(sym);
        }
    }

    // Finally invoke optional fallback logic.
    // This is useful for implementing libcyber's `clFindType`.
    if (search_c.resolve_name_fn) |resolve_name_fn| {
        return resolve_name_fn(c, name);
    }

    return null;
}

pub fn semaChunkTopCtStmts(c: *cy.Chunk, node: ?*ast.Node) !void {
    if (!c.has_pending_ct_stmts) {
        return;
    }
    if (c.resolving_ct_stmts) {
        return;
    }
    c.resolving_ct_stmts = true;

    try sema.pushChunkResolveContext(c, node);
    defer sema.popResolveContext(c);
    sema.getResolveContext(c).allow_rt_stmts = false;
    try cy.ct_inline.evalTopStmts(c, c.ast.root.?.stmts.slice());
    c.resolving_ct_stmts = false;
    c.has_pending_ct_stmts = false;
}

pub fn ensureResolvedFuncTemplate(c: *cy.Chunk, template: *cy.sym.FuncTemplate) !void {
    if (template.isResolved()) {
        return;
    }
    try sema.resolveFuncTemplate(c, template);
}

pub fn ensureResolvedTemplate(c: *cy.Chunk, template: *cy.sym.Template) !void {
    if (template.isResolved()) {
        return;
    }
    try sema.resolveTemplate(c, template);
}

pub fn getResolveContext(c: *cy.Chunk) *ResolveContext {
    return &c.resolve_stack.items[c.resolve_stack.items.len-1];
}

pub fn indexOfTypedParam(params: []const *ast.FuncParam, start: usize) ?usize {
    for (params[start..], start..) |param, i| {
        if (param.type != null) {
            return i;
        }
    }
    return null;
}

const GenericFuncResult = struct {
    generic: bool,
    params: []cy.sym.FuncTemplateParam,
};

fn ensure_opaque_func_sig(c: *cy.Chunk, nparams: usize) !*FuncSig {
    const start = c.func_param_stack.items.len;
    defer c.func_param_stack.items.len = start;
    for (0..nparams) |_| {
        try c.func_param_stack.append(c.alloc, FuncParam.init(c.sema.any_t));
    }
    return c.sema.ensureFuncSig2(c.func_param_stack.items[start..], c.sema.any_t, false, null);
}

/// During body sema, all new types should be resolved.
fn resolveFuncSig(c: *cy.Chunk, func: *cy.Func, resolve_new_types: bool, out_generic: *GenericFuncResult, comptime variant: bool) !*FuncSig {
    const func_n = func.decl.?.cast(.funcDecl);

    // Get params, build func signature.
    const start = c.func_param_stack.items.len;
    defer c.func_param_stack.items.len = start;

    const template_start = c.func_template_param_stack.items.len;
    defer c.func_template_param_stack.items.len = template_start;
    // An anonymous param owns its name until `out_generic.params` takes the entries over on success.
    errdefer for (c.func_template_param_stack.items[template_start..]) |param| {
        param.deinit(c.alloc);
    };

    const sig_t = func_n.sig_t;
    if (sig_t == .infer) {
        return error.Unexpected;
    }

    var start_idx: usize = 0;

    var scope_param_idx: ?u8 = null;
    const params: []const *ast.FuncParam = func_n.params.slice();
    if (sig_t == .method) {
        // First parameter type of methods has the receiver type.
        const type_n = func_n.params.ptr[0].type.?;

        const rec_t = try cte.eval_type2(c, resolve_new_types, type_n);
        try c.func_param_stack.append(c.alloc, FuncParam.init2(rec_t, func_n.params.ptr[0].sink_param));

        if (func_n.params.ptr[0].scope_param) {
            scope_param_idx = 0;
        }
        start_idx += 1;
    }
    // Separate check for trait methods.
    if (func.type == .trait) {
        // Add `self Self` generic param.
        const self_type = getResolveContext(c).getSelfSym().?.cast(.type).type;
        try c.func_param_stack.append(c.alloc, FuncParam.init(self_type));
    }

    var param_group_t: ?*cy.Type = null;
    var param_group_end: usize = undefined;
    var has_ct_only_param = false;

    for (start_idx..params.len) |i| {
        const param = params[i];
        const paramName = param.name_type.as_name();
        if (std.mem.eql(u8, paramName, "self")) {
            return c.reportError("`self` is a reserved parameter for methods.", @ptrCast(param));
        }
        var type_: *cy.Type = undefined;
        if (param.type == null) {
            if (param_group_t == null or i > param_group_end) {
                // Attempt to find group type.
                param_group_end = indexOfTypedParam(params, i + 1) orelse {
                    return c.reportError("Expected parameter type.", @ptrCast(param));
                };
                param_group_t = try sema_type.resolveAnyParamType(c, i, resolve_new_types, params[param_group_end].type.?, variant);
            }
            type_ = param_group_t.?;
        } else {
            type_ = try sema_type.resolveAnyParamType(c, i, resolve_new_types, param.type.?, variant);
        }

        if (!has_ct_only_param and type_.info.ct and !param.template_param) {
            has_ct_only_param = true;
        }

        if (param.template_param) {
            if (!variant) {
                const ctx = getResolveContext(c);
                const value = TypeValue.init(c.sema.type_t, Value.initPtr(c.sema.any_t));
                try ctx.initCtParam(c.alloc, paramName, value);

                try c.func_template_param_stack.append(c.alloc, .{
                    .anonymous = false,
                    .name = paramName,
                    .type_idx = undefined,
                });
            } else {
                continue;
            }
        } else if (param.scope_param) {
            if (scope_param_idx != null) {
                return c.reportError("Expected only one parameter with the `scope` modifier.", param.name_type);
            }
            scope_param_idx = @intCast(c.func_param_stack.items.len - start);
        }
        try c.func_param_stack.append(c.alloc, FuncParam.init2(type_, param.sink_param));
    }

    // Get return type.
    const ret_t = try sema_type.resolve_return_type_spec(c, func_n.ret, resolve_new_types);
    if (func.type != .trait and ret_t.info.borrow_only) {
        if (!func_n.scope_ret and ast.findAttr(func_n.attrs.slice(), .unsafe) == null) {
            if (ret_t.kind() == .borrow) {
                return c.reportError("Returning a borrow requires a `scope` modifier.", func_n.ret);
            } else {
                return c.reportError("Returning a borrow container requires a `scope` modifier.", func_n.ret);
            }
        }
        if (scope_param_idx == null and ast.findAttr(func_n.attrs.slice(), .unsafe) == null) {
            return c.reportError("Missing `scope` parameter.", func_n.ret);
        }
    }

    if (has_ct_only_param) {
        func.info.const_eval_only = true;
    }

    // Always write `generic`. Callers assert on it, and an undefined bool there lets optimized builds drop code.
    out_generic.generic = false;
    errdefer if (out_generic.generic) {
        c.alloc.free(out_generic.params);
        out_generic.generic = false;
    };
    if (!variant) {
        const generic_params = c.func_template_param_stack.items[template_start..];
        if (generic_params.len > 0) {
            const params_dupe = try c.alloc.dupe(cy.sym.FuncTemplateParam, generic_params);
            out_generic.* = .{
                .generic = true,
                .params = params_dupe,
            };
        }
    }
    const nparams = c.func_param_stack.items.len - start;
    try checkParamLimit(c, nparams, if (params.len > max_func_params) @ptrCast(params[max_func_params]) else @ptrCast(func_n));
    return c.sema.ensureFuncSig2(c.func_param_stack.items[start..], ret_t, func.info.extern_, scope_param_idx);
}

fn pushLambdaFuncParams(c: *cy.Chunk, params: []const *ast.FuncParam) !void {
    var param_group_t: ?*cy.Type = null;
    var param_group_end: usize = undefined;
    for (params, 0..) |param, i| {
        const paramName = param.name_type.as_name();
        if (std.mem.eql(u8, paramName, "self")) {
            return c.reportError("`self` is a reserved parameter for methods.", @ptrCast(param));
        }
        var type_: *cy.Type = undefined;
        if (param.type == null) {
            if (param_group_t == null or i > param_group_end) {
                // Attempt to find group type.
                param_group_end = indexOfTypedParam(params, i + 1) orelse {
                    return c.reportError("Expected parameter type.", @ptrCast(param));
                };
                param_group_t = try cte.eval_type2(c, false, params[param_group_end].type.?);
            }
            type_ = param_group_t.?;
        } else {
            type_ = try cte.eval_type2(c, false, param.type.?);
        }
        try c.func_param_stack.append(c.alloc, .init(type_));
    }
    if (params.len > max_func_params) {
        try checkParamLimit(c, params.len, @ptrCast(params[max_func_params]));
    }
}

fn inferLambdaFuncSig(c: *cy.Chunk, sig_t: ast.FuncSigType, opt_target_t: ?*cy.Type, node: *ast.Node) !?*FuncSig {
    if (sig_t != .infer) {
        return null;
    }
    var target_t = opt_target_t orelse {
        return c.reportError("Can not infer function type. Consider using an explicit `fn` declaration.", node);
    };
    if (target_t.kind() == .func_ptr) {
        return target_t.cast(.func_ptr).sig;
    } else if (target_t.kind() == .func) {
        return target_t.cast(.func).sig;
    } else if (target_t == c.sema.object_t) {
        return null;
    } else if (target_t.kind() == .borrow) {
        const borrow_t = target_t.cast(.borrow);
        if (borrow_t.child_t.kind() == .func) {
            return borrow_t.child_t.cast(.func).sig;
        }
    }
    return c.reportError("Can not infer function type.", node);
}

pub const DeclNamePathResult = struct {
    name: cy.ast.NamePathBase,
    parent: *cy.Sym,

    /// Whether the symbol is declared as a template variant rather than in the template's namespace.
    variant: bool,
};

pub fn ensureDeclNamePath(c: *cy.Chunk, mod: *cy.Sym, parent_opt: ?*ast.Node, name_n: *ast.Node) !DeclNamePathResult {
    const name = name_n.getNamePathBase();
    var parent = parent_opt orelse {
        return .{
            .name = name,
            .parent = mod,
            .variant = false,
        };
    };

    if (parent.type() == .borrow) {
        parent = parent.cast(.borrow).child;
    } else if (parent.type() == .ex_borrow) {
        parent = parent.cast(.ex_borrow).child;
    } else if (parent.type() == .ref) {
        parent = parent.cast(.ref).child;
    }

    var parent_name: []const u8 = undefined;
    var variant = false;
    if (parent.type() == .ident) {
        parent_name = parent.as_name();
    } else if (parent.type() == .generic_expand) {
        variant = true;
        parent_name = parent.cast(.generic_expand).left.as_name();
    } else {
        return c.reportErrorFmt("TODO", &.{}, parent);
    }
    const sym = mod.getMod().?.getSym(parent_name) orelse {
        return c.reportErrorFmt("Undeclared symbol: `{}`", &.{v(parent_name)}, parent);
    };
    if (sym.type == .type_alias) {
        return c.reportError("Cannot declare from type alias.", name_n);
    }
    return .{
        .name = name,
        .parent = sym,
        .variant = variant,
    };
}

pub fn popProc(self: *cy.Chunk) !cy.ir.StmtBlock {
    return popProc2(self, true);
}

pub fn popProc2(self: *cy.Chunk, destruct_locals: bool) !cy.ir.StmtBlock {
    const stmtBlock = try popBlock2(self, destruct_locals);
    const proc = self.proc();
    proc.deinit(self.alloc);
    self.semaProcs.items.len -= 1;
    if (self.semaProcs.items.len > 0) {
        self.cur_sema_proc = &self.semaProcs.items[self.semaProcs.items.len-1];
    }
    self.varStack.items.len = proc.varStart;
    self.active_field_stack.items.len = proc.active_field_start;
    return stmtBlock;
}

pub fn pushLambdaProc(c: *cy.Chunk, func: *cy.Func) !ProcId {
    return pushFuncProc(c, func);
}

pub fn pushFuncProc(c: *cy.Chunk, func: *cy.Func) !ProcId {
    const stmt = try c.ir.newStmt(.funcBlock, @ptrCast(func.decl), undefined);
    try c.ir.func_blocks.append(c.alloc, stmt);
    const id = try pushProc(c, func);
    c.proc().ir = stmt;
    return id;
}

pub fn sema_program(c: *cy.Chunk, opt_main_func: ?*cy.Func) !*ir.Stmt {
    try sema.pushChunkResolveContext(c, null);
    defer sema.popResolveContext(c);

    const program_block = try c.ir.newStmt(.mainBlock, @ptrCast(c.ast.root), undefined);
    try c.ir.func_blocks.append(c.alloc, program_block);

    const id = try pushProc(c, null);
    c.mainSemaProcId = id;

    // Call `@program_init`.
    const func = c.sym.getMod().getSym("@program_init").?.cast(.func).first;
    const call = try sema_call_ir(c, func, &.{}, c.ast.null_node);
    try sema_discard(c, call, c.ast.null_node);

    // For REPL, restore variables from previous evaluation.
    if (c.vm.config.persist_main) {
        // `VM.eval` copied each saved local into a VM-owned buffer after the previous run.
        // The new local takes the value over bitwise (a move): the buffer is not destructed, only freed,
        // when the restored local is tracked again. The saves stay intact if this compile fails.
        for (c.vm.env_local_saves.items) |save| {
            std.debug.assert(save.owned);
            const ptr_t = try getPtrType(c, save.val_t);
            const addr = try c.semaConst(@intFromPtr(save.value.ptr), ptr_t, c.ast.null_node);
            const init = try semaDeref(c, addr, c.ast.null_node);
            const name_dup = try c.ir.alloc.dupe(u8, save.name);
            const local_res = try declareLocalInit(c, name_dup, save.val_t, init, c.ast.null_node);
            const local = &c.varStack.items[local_res.id];
            local.inner.local.allow_redeclare = true;
            try semaTrackMainLocal(c, local, c.ast.null_node);
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
        const call_main = try sema_call_ir(c, main_func, &.{}, c.ast.null_node);
        const main_res = try declareHiddenLocal(c, "_main_res", call_main.type, call_main, c.ast.null_node);

        // An error that `main` returns is not handled by anything. It panics, like `expr!` at the top level.
        if (call_main.type.kind() == .result) {
            const node: *ast.Node = @ptrCast(main_func.decl.?);
            const res = try semaLocal(c, main_res.id, node);
            const cond = try c.semaIsError(res, node);
            _ = try pushBlock(c, node);
            {
                const err = try semaUnwrapResultErrorNoCheck(c, res, node);
                const arg = Argument.initPreResolved(node, err);
                const panic_call = try c.semaCallFunc2(c.sema.panic_unwrap_error_fn, &.{arg}, &.{}, node);
                _ = try declareHiddenLocal(c, "_res", c.sema.void_t, panic_call, node);
            }
            const block = try popBlock2(c, false);
            _ = try c.ir.pushStmt(.if_block, node, .{
                .cond_expr = cond.ir,
                .body_head = block.first,
            });
        } else if (call_main.type.id() == bt.Error) {
            // `fn main() -> error` has no value case. What it returns is an error that nothing handles.
            const node: *ast.Node = @ptrCast(main_func.decl.?);
            const err = try semaLocal(c, main_res.id, node);
            const arg = Argument.initPreResolved(node, err);
            const panic_call = try c.semaCallFunc2(c.sema.panic_unwrap_error_fn, &.{arg}, &.{}, node);
            _ = try declareHiddenLocal(c, "_res", c.sema.void_t, panic_call, node);
        }

        // Skip deinit of main result.
        c.varStack.items[main_res.id].type = .dead;

        try sema_program_deinit(c);
    } else {
        const stmts = c.ast.root.?.stmts.slice();
        if (c.vm.config.persist_main and stmts.len > 0 and stmts[stmts.len - 1].type() == .exprStmt) {
            // REPL: the last expression's value is the eval result.
            try semaStmts(c, stmts[0 .. stmts.len - 1]);
            try semaMainResultStmt(c, stmts[stmts.len - 1]);
        } else {
            try semaStmts(c, stmts);
        }

        var destruct_locals = true;
        if (c.block().endReachable) {
            // Main locals are destructed before `@program_deinit` releases the globals, in the same order
            // as `return` in main (`semaReturn`). A local's `@deinit` may still read the globals.
            if (shouldGenMainScopeReleaseOps(c.compiler)) {
                try semaDestructBlock(c);
                destruct_locals = false;
            }
            try sema_program_deinit(c);
        }
        const stmtBlock = try popProc2(c, destruct_locals);
        program_block.cast(.mainBlock).* = .{
            .bodyHead = stmtBlock.first,
        };
        return program_block;
    }

    const stmtBlock = try popProc(c);

    log.tracev("pop main block", .{});

    program_block.cast(.mainBlock).* = .{
        .bodyHead = stmtBlock.first,
    };
    return program_block;
}

pub fn pushProc(self: *cy.Chunk, func: ?*cy.Func) !ProcId {
    // The locals of pending operands belong to the proc that the operands are in. A lambda argument starts
    // another proc before its statement block is pushed.
    if (self.ir.seq_pending > 0) try seqFlush(self);
    if (cy.Trace) {
        if (func) |func_| {
            const path = try cy.sym.newFuncName(self.sema, self.alloc, func_, .{});
            defer self.alloc.free(path);
            log.tracev("push func: {s}", .{path});
        }
    }
    var isStaticFuncBlock = false;
    var node: *ast.Node = undefined;
    if (func != null) {
        isStaticFuncBlock = func.?.isStatic();
        node = @ptrCast(func.?.decl);
    } else {
        node = @ptrCast(self.ast.root);
    }

    const new = Proc.init(node, func, @intCast(self.semaBlocks.items.len), isStaticFuncBlock, @intCast(self.varStack.items.len), @intCast(self.active_field_stack.items.len));
    const idx = self.semaProcs.items.len;
    try self.semaProcs.append(self.alloc, new);
    self.cur_sema_proc = &self.semaProcs.items[idx];

    _ = try pushBlock(self, node);
    return @intCast(idx);
}

pub fn sema_discard(c: *cy.Chunk, expr: ExprResult, node: *ast.Node) !void {
    _ = try c.ir.pushStmt(.discard, node, .{ .expr = expr.ir });
}

fn sema_call_partial_destruct_local(c: *cy.Chunk, local: *Local, node: *ast.Node) !void {
    const ptr_t = try getPtrType(c, local.decl_t);
    const local_v = try semaLocal(c, local.stack_idx, node);
    const addr = try semaAddressOf(c, local_v, ptr_t, node);
    const fields = c.proc().var_active_struct_fields.get(local.stack_idx).?;
    const layout = try ensure_partial_struct_layout(c, fields);
    const dtor = try get_partial_dtor(c, local.decl_t, layout, node);
    const arg = Argument.initPreResolved(node, addr);
    const call = try c.semaCallFunc2(dtor, &.{arg}, &.{}, node);
    _ = try c.ir.pushStmt(.discard, node, .{ .expr = call.ir });
}

fn semaDestructLocalCall(c: *cy.Chunk, local: *Local, node: *ast.Node) !void {
    const ptr_t = try getPtrType(c, local.decl_t);
    const local_v = try semaLocal(c, local.stack_idx, node);
    const addr = try semaAddressOf(c, local_v, ptr_t, node);
    const dtor = try getDtorFunc(c, local.decl_t, node);
    const arg = Argument.initPreResolved(node, addr);
    const call = try c.semaCallFunc2(dtor, &.{arg}, &.{}, node);
    _ = try c.ir.pushStmt(.discard, node, .{ .expr = call.ir });
}

fn semaReleaseLocal(c: *cy.Chunk, local: *Local, optional: bool, type_: *cy.Type, node: *ast.Node) !void {
    const deinit_obj = try getDeinitObjFunc(c, type_, node);

    try semaTraceNopFmt(c, "release: {s}", .{local.name()}, node);
    _ = try c.ir.pushStmt(.release, node, .{
        .reg = local.inner.local.id,
        .optional = optional,
        .deinit_obj = deinit_obj,
    });
}

/// `local` can be invalidated after this function returns.
pub fn semaDestructLocal(c: *cy.Chunk, local: *Local, node: *ast.Node) !void {
    if (local.type != .local) {
        return;
    }
    const proc = c.proc();

    if (local.inner.local.isParam) {
        if (proc.func != null and !proc.func.?.info.generator) {
            // Reference types are not managed for regular func parameters (only generator func parameters).
            if (local.decl_t.isObjectLike()) {
                return;
            }
        }
        // Params are managed by generator functions.
    }

    if (!local.decl_t.isManaged()) {
        return;
    }

    try semaTraceNopFmt(c, "deinit: {s} {}", .{local.name(), local.stack_idx}, proc.node);

    switch (local.decl_t.id()) {
        bt.Str => {
            try semaDestructLocalCall(c, local, node);
        },
        else => {
            switch (local.decl_t.kind()) {
                .pointer => {
                    const pointer = local.decl_t.cast(.pointer);
                    if (pointer.ref) {
                        try semaReleaseLocal(c, local, false, pointer.child_t, node);
                    } else {
                        try semaDestructLocalCall(c, local, node);
                    }
                },
                .borrow_trait => {
                    try semaDestructLocalCall(c, local, node);
                },
                .ref_trait => {
                    try semaDestructLocalCall(c, local, node);
                },
                .func => {
                    try semaReleaseLocal(c, local, false, local.decl_t, node);
                },
                .option => {
                    const option = local.decl_t.cast(.option);
                    if (option.zero_union) {
                        if (option.child_t.isObjectLike()) {
                            if (option.child_t.isRefPointer()) {
                                try semaReleaseLocal(c, local, true, option.child_t.cast(.pointer).child_t, node);
                            } else {
                                try semaReleaseLocal(c, local, true, option.child_t, node);
                            }
                        }
                    } else {
                        try semaDestructLocalCall(c, local, node);
                    }
                },
                .choice => {
                    try semaDestructLocalCall(c, local, node);
                },
                .result => {
                    try semaDestructLocalCall(c, local, node);
                },
                .struct_t => {
                    if (local.has_inactive_struct_fields) {
                        try sema_call_partial_destruct_local(c, local, node);
                    } else {
                        try semaDestructLocalCall(c, local, node);
                    }
                },
                .c_union => {
                },
                .vector => {
                    try semaDestructLocalCall(c, local, node);
                },
                .partial_vector => {
                    try semaDestructLocalCall(c, local, node);
                },
                else => {
                    std.debug.panic("TODO: {s}", .{local.decl_t.name()});
                },
            }
        },
    }
}

pub fn semaDestructBlock(c: *cy.Chunk) !void {
    return semaDestructBlock2(c, c.block());
}

pub fn semaDestructBlock2(c: *cy.Chunk, b: *Block) !void {
    var i: usize = c.varStack.items.len;
    while (i > b.varStart) {
        i -= 1;
        try semaDestructLocal(c, &c.varStack.items[i], b.node);
    }
}

pub fn shouldGenMainScopeReleaseOps(c: *cy.Compiler) bool {
    return !c.vm.config.single_run and !c.vm.config.persist_main;
}

pub fn popBlock(c: *cy.Chunk) !cy.ir.StmtBlock {
    return popBlock2(c, true);
}

pub fn popBlock2(c: *cy.Chunk, destruct_locals: bool) !cy.ir.StmtBlock {
    const proc = c.proc();
    const b = c.block();

    // Execute destructors.
    var should_destruct = destruct_locals;
    if (should_destruct and proc.func == null and proc.block_depth == 1 and !shouldGenMainScopeReleaseOps(c.compiler)) {
        should_destruct = false;
    }
    // A block that ends with `return`, `break`, `continue` or a `never` call never reaches its end,
    // and those statements already destruct the locals they leave. Emitting destructors here would be dead code.
    if (!b.endReachable) {
        should_destruct = false;
    }
    if (should_destruct) {
        // try semaTraceNopFmt(c, "pop block destruct: {s}", .{@tagName(b.node.type())}, proc.node);
        try semaDestructBlock(c);
    }

    // Restore `nameToVar` to previous sub-block state.
    if (proc.block_depth > 1) {
        // Remove dead vars.
        const varDecls = c.varStack.items[b.varStart..];
        for (varDecls) |*decl| {
            // Borrows held by the block's locals end here.
            unbindBorrowLocal(c, decl);
            if (decl.type == .local and decl.inner.local.hidden) {
                continue;
            }
            const name = decl.namePtr[0..decl.nameLen];
            _ = proc.var_cache_entries.remove(name);
        }
        c.varStack.items.len = b.varStart;

        // Restore shadowed vars.
        const varShadows = c.varShadowStack.items[b.varShadowStart..];
        for (varShadows) |shadow| {
            const name = shadow.namePtr[0..shadow.nameLen];
            try proc.var_cache_entries.putNoClobber(c.alloc, name, .{
                .type = .local,
                .data = .{ .local = .{
                    .varId = shadow.varId,
                    .blockId = shadow.blockId,
                }},
            });
        }
        c.varShadowStack.items.len = b.varShadowStart;
    }

    proc.block_depth -= 1;
    c.semaBlocks.items.len -= 1;

    return c.ir.popStmtBlock();
}

pub fn pushBlock(c: *cy.Chunk, node: *ast.Node) !usize {
    try c.ir.pushStmtBlock(c.alloc);
    c.proc().block_depth += 1;
    // try semaTraceNopFmt(c, "push block: {s}", .{@tagName(node.type())}, @ptrCast(node));
    const new = Block.init(
        node,
        c.varStack.items.len,
        c.varShadowStack.items.len,
    );

    const idx = c.semaBlocks.items.len;
    try c.semaBlocks.append(c.alloc, new);
    return idx;
}

fn pushMethodParamVars(c: *cy.Chunk, self_t: *cy.Type, func: *const cy.Func) !void {
    const curNode = c.curNode;
    defer c.curNode = curNode;

    const params = func.sig.params();

    const param_decls = func.decl.?.cast(.funcDecl).params.slice();
    try declareParam(c, param_decls[0], true, 0, self_t);

    var rt_param_idx: usize = 1;
    for (param_decls[1..]) |param_decl| {
        if (param_decl.template_param) {
            continue;
        }
        try declareParam(c, param_decl, false, rt_param_idx, params[rt_param_idx].get_type());
        rt_param_idx += 1;
    }
}

fn appendFuncParamVars(c: *cy.Chunk, ast_params: []const *ast.FuncParam, params: []const FuncParam) !void {
    if (params.len > 0) {
        var rt_param_idx: usize = 0;
        for (ast_params) |param| {
            if (param.template_param) {
                continue;
            }
            try declareParam(c, param, false, rt_param_idx, params[rt_param_idx].get_type());
            rt_param_idx += 1;
        }
    }
}

fn pushLocalVar(c: *cy.Chunk, _type: LocalVarType, name: []const u8, declType: *cy.Type, hidden: bool) !LocalId {
    const proc = c.proc();
    const id: u32 = @intCast(c.varStack.items.len);

    if (!hidden) {
        _ = try proc.var_cache_entries.put(c.alloc, name, .{
            .type = .local,
            .data = .{ .local = .{
                .varId = id,
                .blockId = @intCast(c.semaBlocks.items.len-1),
            }},
        });
    }
    try c.varStack.append(c.alloc, .{
        .decl_t = declType,
        .lifetime = Lifetime.initBlock(@intCast(proc.block_depth)),
        .active_borrows = 0,
        .active_ex_borrows = 0,
        .parent_local = cy.NullId,
        .type = _type,
        .stack_idx = id,
        .namePtr = name.ptr,
        .nameLen = @intCast(name.len),
    });
    return id;
}

fn getVarPtr(self: *cy.Chunk, name: []const u8) ?*Local {
    if (self.proc().var_cache_entries.get(name)) |varId| {
        return &self.vars.items[varId];
    } else return null;
}

fn pushCapturedVar(c: *cy.Chunk, name: []const u8, parentVarId: LocalId) !u32 {
    const proc = c.proc();
    const parent_v = c.varStack.items[parentVarId];
    const capturedIdx: u8 = @intCast(proc.captures.items.len);
    try proc.captures.append(c.alloc, .{
        .parent_var_idx = parentVarId,
        .val_t = parent_v.decl_t,
    });
    try proc.var_cache_entries.put(c.alloc, name, .{
        .type = .capture,
        .data = .{ .capture = capturedIdx },
    });
    return capturedIdx;
}

/// TODO: Use to mark visited syms from at least one parent. Would not be a full tree shake but can still skip some syms.
pub fn referenceSym(c: *cy.Chunk, sym: *Sym, node: *ast.Node) !void {
    _ = c;
    _ = sym;
    _ = node;
}

pub fn lookupSelfExpr(c: *cy.Chunk, node: *ast.Node) !ExprResult {
    const self = (try lookupSelf(c, node)) orelse {
        return c.reportErrorFmt("Can only infer `self` from a method body.", &.{}, node);
    };
    if (self.capture) {
        const capture = try semaCaptured(c, self.id, node);
        return semaOwn(c, capture, node);
    } else {
        return semaLocal(c, self.id, node);
    }
}

const LookupSelfResult = struct {
    id: u32,
    capture: bool,
};

pub fn lookupSelf(self: *cy.Chunk, node: *ast.Node) !?LookupSelfResult {
    const proc = self.proc();
    if (proc.var_cache_entries.get("self")) |varInfo| {
        if (varInfo.type == .capture) {
            return .{
                .id = varInfo.data.capture,
                .capture = true,
            };
        } else {
            return .{
                .id = varInfo.data.local.varId,
                .capture = false,
            };
        }
    }

    if (try lookupParentLocal(self, "self", node)) |res| {
        if (proc.isStaticFuncBlock) {
            // Can not capture local before static function block.
            const funcName = proc.func.?.name();
            return self.reportErrorFmt("Can not capture the local variable `self` from static function `{}`.\nOnly lambdas (anonymous functions) can capture local variables.", &.{v(funcName)}, self.curNode);
        }

        // TODO: Capture non-reference stack variables too.
        const decl_t = self.varStack.items[res.varId].decl_t;
        if (!decl_t.isObjectLike() and decl_t.kind() != .borrow) {
            return self.reportErrorFmt("Can only capture variables declared with the reference types `^T` or `&T`.", &.{}, node);
        }

        // Create a local captured variable.
        const id = try pushCapturedVar(self, "self", res.varId);
        return LookupSelfResult{
            .id = id,
            .capture = true,
        };
    }
    return null;
}

const LookupIdentResult = union(enum) {
    static: *Sym,
    ct_value: cy.TypeValue,
    ct_var: *sema.CtParam,

    capture: u32,

    /// Local, parent local alias, or parent object member alias.
    local: LocalId,
};

/// Static var lookup is skipped for callExpr since there is a chance it can fail on a
/// symbol with overloaded signatures.
pub fn lookupIdent(self: *cy.Chunk, name: []const u8, node: *ast.Node) !LookupIdentResult {
    if (self.semaProcs.items.len == 0) {
        return (try lookupStaticIdent(self, name, node)) orelse {
            return self.reportErrorFmt("Could not find the symbol `{}`.", &.{v(name)}, node);
        };
    }

    const proc = self.proc();
    if (proc.var_cache_entries.get(name)) |varInfo| {
        switch (varInfo.type) {
            .local => {
                const data = varInfo.data.local;
                return LookupIdentResult{
                    .local = data.varId,
                };
            },
            .capture => {
                return LookupIdentResult{
                    .capture = varInfo.data.capture,
                };
            },
        }
    }

    if (try lookupParentLocal(self, name, node)) |res| {
        if (proc.isStaticFuncBlock) {
            // Can not capture local before static function block.
            const funcName = proc.func.?.name();
            return self.reportErrorFmt("Can not capture the local variable `{}` from static function `{}`.\nOnly lambdas (anonymous functions) can capture local variables.", &.{v(name), v(funcName)}, self.curNode);
        }

        // TODO: Capture non-reference stack variables too.
        const decl_t = self.varStack.items[res.varId].decl_t;
        if (!decl_t.isObjectLike() and decl_t.kind() != .borrow) {
            return self.reportErrorFmt("Can only capture variables declared with the reference types `^T` or `&T`.", &.{}, node);
        }

        // Create a local captured variable.
        const id = try pushCapturedVar(self, name, res.varId);
        return LookupIdentResult{
            .capture = id,
        };
    }

    if (try lookupStaticIdent(self, name, node)) |res| {
        return res;
    }

    if (self.cur_sema_proc.isMethodBlock) {
        const base_t = self.cur_sema_proc.func.?.sig.params()[0].get_type().getBaseType();
        if (base_t.sym().getMod().getSym(name)) |sym| {
            if (sym.type == .field) {
                return self.reportErrorFmt("Expected explicit `${}` or `self.{}`.", &.{v(name), v(name)}, node);
            }
        }
    }
    return self.reportErrorFmt("Undeclared variable `{}`.", &.{v(name)}, node);
}

pub fn lookupStaticIdent(c: *cy.Chunk, name: []const u8, node: *ast.Node) !?LookupIdentResult {
    const res = (try getResolvedName(c, name, node)) orelse {
        return null;
    };
    switch (res.type) {
        .sym => {
            return LookupIdentResult{ .static = res.data.sym };
        },
        .ct_value => {
            return LookupIdentResult{ .ct_value = res.data.ct_value };
        },
        .ct_var => {
            return LookupIdentResult{ .ct_var = res.data.ct_var };
        },
    }
}

const LookupParentLocalResult = struct {
    varId: LocalId,
    blockIdx: u32,
};

fn lookupParentLocal(c: *cy.Chunk, name: []const u8, node: *ast.Node) !?LookupParentLocalResult {
    // Only check one block above.
    if (c.semaBlockDepth() > 1) {
        const prev = c.semaProcs.items[c.semaProcs.items.len - 2];
        if (prev.var_cache_entries.get(name)) |varInfo| {
            switch (varInfo.type) {
                .local => {
                    const data = varInfo.data.local;
                    const svar = c.varStack.items[data.varId];
                    if (svar.isCapturable()) {
                        return .{
                            .varId = data.varId,
                            .blockIdx = @intCast(c.semaProcs.items.len - 2),
                        };
                    }
                    if (svar.type == .local and !svar.decl_t.isObjectLike()) {
                        const type_name = try c.sema.allocTypeName(svar.decl_t);
                        defer c.alloc.free(type_name);
                        return c.reportErrorFmt("Expected to capture a reference type, found `{}`.", &.{v(type_name)}, node);
                    }
                },
                .capture => {},
            }
        }
    }
    return null;
}

pub fn reportIncompatType(c: *cy.Chunk, exp_t: *cy.Type, act_t: *cy.Type, node: *ast.Node) anyerror {
    const exp_name = try c.sema.allocTypeName(exp_t);
    defer c.alloc.free(exp_name);
    const act_name = try c.sema.allocTypeName(act_t);
    defer c.alloc.free(act_name);
    return c.reportErrorFmt("Expected type `{}`. Found `{}`.", &.{v(exp_name), v(act_name)}, node);
}

fn checkTypeCstr(c: *cy.Chunk, ctype: cy.TypeId, cstr_t: TypeId, node: *ast.Node) !void {
    return checkTypeCstr2(c, ctype, cstr_t, cstr_t, node);
}

fn checkTypeCstr2(c: *cy.Chunk, ctype: cy.TypeId, cstr_t: TypeId, reportCstrTypeId: TypeId, node: *ast.Node) !void {
    // Dynamic is allowed.
    if (ctype != bt.Dyn) {
        if (!cy.types.isTypeCompat(c.compiler, ctype, cstr_t)) {
            const cstrName = try c.sema.allocTypeName(reportCstrTypeId);
            defer c.alloc.free(cstrName);
            const typeName = try c.sema.allocTypeName(ctype);
            defer c.alloc.free(typeName);
            return c.reportErrorFmt("Expected type `{}`, got `{}`.", &.{v(cstrName), v(typeName)}, node);
        }
    }
}

fn pushExprRes(c: *cy.Chunk, res: ExprResult) !void {
    try c.exprResStack.append(c.alloc, res);
}

pub const SwitchInfo = struct {
    node: *ast.Node,
    control_t: *cy.Type,
    control_n: *ast.Node,
    control_is_choice: bool,

    // Target type can be given or inferred from the first case.
    opts: Cstr,

    // For switch expression. When inferring the target type, the result is initially empty.
    res_local: u32,

    cond_local: u32,

    choice_tag_local: u8,

    // True when matching enum or choice.
    exhaust_enum: bool,
    enum_coverage: []bool = undefined,
    enum_num_covered: u32 = undefined,
    is_expr: bool,

    end_reachable: bool,

    fn init(c: *cy.Chunk, control_n: *ast.Node, control: ExprResult, is_expr: bool, opts: Cstr, node: *ast.Node) !SwitchInfo {
        var info = SwitchInfo{
            .node = node,
            .control_t = control.type,
            .control_n = control_n,
            .choice_tag_local = undefined,
            .control_is_choice = false,
            .exhaust_enum = false,
            .is_expr = is_expr,
            .res_local = cy.NullId,
            .cond_local = cy.NullId,
            .opts = opts,
            .end_reachable = false,
        };

        if (info.control_t.kind() == .choice) {
            try semaSwitchChoicePrologue(c, &info, control, control_n);
            info.control_is_choice = true;
            info.exhaust_enum = true;
            info.enum_coverage = try c.alloc.alloc(bool, info.control_t.cast(.choice).cases().len);
            @memset(info.enum_coverage, false);
            info.enum_num_covered = 0;
        }
        if (info.control_t.kind() == .enum_t) {
            info.exhaust_enum = true;
            info.enum_coverage = try c.alloc.alloc(bool, info.control_t.cast(.enum_t).cases().len);
            @memset(info.enum_coverage, false);
            info.enum_num_covered = 0;
        }
        return info;
    }

    fn deinit(self: *SwitchInfo, alloc: std.mem.Allocator) void {
        if (self.exhaust_enum) {
            alloc.free(self.enum_coverage);
        }
    }

    pub fn setTargetType(self: *SwitchInfo, c: *cy.Chunk, target_t: *cy.Type) void {
        self.opts.target_t = target_t;
        self.opts.reqTypeCstr = true;
        c.varStack.items[self.res_local].decl_t = target_t;
        c.varStack.items[self.res_local].inner.local.declIrStart.cast(.declare_local).decl_t = target_t;
    }
};

fn semaSwitchStmt(c: *cy.Chunk, block: *ast.SwitchBlock) !void {
    const var_start = c.varStack.items.len;
    // Determine the control type first.
    var control_expr = try c.semaExpr(block.expr, .{});
    control_expr = try semaEnsureAddressable(c, control_expr, block.expr);
    const control_borrow_t = try getBorrowType(c, control_expr.type);
    control_expr = try semaAddressOf(c, control_expr, control_borrow_t, block.expr);
    const control_local = try declareHiddenLocal(c, "control", control_expr.type, control_expr, block.expr);
    var control = try semaLocal(c, control_local.id, block.expr);
    control = try semaDeref(c, control, block.expr);

    var info = try SwitchInfo.init(c, block.expr, control, false, .{}, @ptrCast(block));
    defer info.deinit(c.alloc);

    info.cond_local = (try declareHiddenLocal(c, "_cond", c.sema.bool_t, null, @ptrCast(block))).id;

    if (block.cases.ptr[0].type() == .case_stmt) {
        if (block.cases.ptr[0].cast(.case_stmt).body_kind == .expr) {
            // Reserve local for result.
            const res_local = try declareHiddenLocal(c, "_temp", c.sema.void_t, null, @ptrCast(block));
            info.res_local = res_local.id;
        }
    }

    try semaSwitchBody(c, &info, block, control);
    try popLocals(c, var_start, @ptrCast(block));
}

fn semaSwitchExpr(c: *cy.Chunk, block: *ast.SwitchBlock, cstr: Cstr) !ExprResult {
    // Determine the control type first.
    var control_expr = try c.semaExpr(block.expr, .{});
    control_expr = try semaEnsureAddressable(c, control_expr, block.expr);
    const control_borrow_t = try getBorrowType(c, control_expr.type);
    control_expr = try semaAddressOf(c, control_expr, control_borrow_t, block.expr);
    const control_local = try declareHiddenLocal(c, "control", control_expr.type, control_expr, block.expr);
    var control = try semaLocal(c, control_local.id, block.expr);
    control = try semaDeref(c, control, block.expr);

    var info = try SwitchInfo.init(c, block.expr, control, true, cstr, @ptrCast(block));
    defer info.deinit(c.alloc);

    info.cond_local = (try declareHiddenLocal(c, "_cond", c.sema.bool_t, null, @ptrCast(block))).id;

    // Reserve local for result.
    const res_local = try declareHiddenLocal(c, "_temp", cstr.target_t orelse c.sema.void_t, null, @ptrCast(block));
    info.res_local = res_local.id;

    try semaSwitchBody(c, &info, block, control);

    if (info.opts.target_t == null) {
        return c.reportError("Expected to infer target type.", block.expr);
    }

    const res = (try semaLocal(c, res_local.id, info.node)).ir;
    c.varStack.items[res_local.id].type = .dead;
    // if (info.opts.target_t.?.id() == bt.Void) {
    //     @panic("boom");
    // }
    return ExprResult.initOwned(res);
}

/// Saves reference to the control local for unwrapping.
/// Returns the tag as the new control.
fn semaSwitchChoicePrologue(c: *cy.Chunk, info: *SwitchInfo, control: ExprResult, node: *ast.Node) !void {
    // Get choice tag for switch expr.
    const expr = try c.ir.newExpr(.field, c.sema.i64_t, node, .{
        .idx = 0,
        .rec = control.ir,
    });
    const tag_expr = ExprResult.init2(expr);

    const choice_tag = try declareHiddenLocal(c, "_choice_tag", c.sema.i64_t, tag_expr, node);
    info.choice_tag_local = @intCast(choice_tag.id);
}

fn semaSwitchBody(c: *cy.Chunk, info: *SwitchInfo, block: *ast.SwitchBlock, control: ExprResult) !void {
    // TODO: Cases should be appended without a builder.
    var cases_buf: std.ArrayList(*ir.Expr) = .empty;
    defer cases_buf.deinit(c.alloc);

    // TODO: Check for exhaustive by looking at all case conds.
    var has_else = false;
    for (block.cases.slice()) |case_n| {
        if (case_n.type() == .ct_stmt) {
            const child = case_n.cast(.ct_stmt).child;
            if (child.type() == .for_iter_stmt) {
                const for_stmt = child.cast(.for_iter_stmt);
                if (for_stmt.stmts.len != 1) {
                    return c.reportError("Expected 1 case statement.", child);
                }
                if (for_stmt.stmts.ptr[0].type() != .case_stmt) {
                    return c.reportError("Expected 1 case statement.", child);
                }
                const for_case = for_stmt.stmts.ptr[0].cast(.case_stmt);
                const iter_n = for_stmt.iterable;
                const iterable = try cte.eval(c, iter_n);
                defer c.heap.destructValue(iterable);

                // Obtain iterator.
                const iterator_sym = try c.accessResolvedSymOrFail(iterable.type, "iterator", iter_n);
                var func_sym = try requireFuncSym(c, iterator_sym, iter_n);
                var iter = try cte.callFuncSymRec(c, func_sym, iter_n, sema.ExprResult.initCtValue(iterable), &.{}, child);
                defer c.heap.destructValue(iter);

                // while iter.next()
                const next_sym = try c.accessResolvedSymOrFail(iterable.type, "next", iter_n);
                func_sym = try requireFuncSym(c, next_sym, iter_n);
                const borrow_t = try getBorrowType(c, iter.type);
                var iter_borrow: TypeValue = undefined;
                if (iter.type.is_cte_boxed()) {
                    iter_borrow = TypeValue.init(borrow_t, iter.value);
                } else {
                    iter_borrow = TypeValue.init(borrow_t, Value.initPtr(@ptrCast(&iter.value)));
                }
                const args = [_]sema_func.Argument{
                    sema_func.Argument.initReceiver(iter_n, ExprResult.initCtValue(iterable)),
                    sema_func.Argument.initPreResolved(iter_n, ExprResult.initCtValue(iter_borrow)),
                };
                while (true) {
                    const next = try cte.callFuncSym(c, func_sym, &args, &.{}, iter_n);
                    defer c.heap.destructValue(next);

                    const value = try c.heap.unwrap_option_or(next.type.cast(.option), next.value) orelse {
                        break;
                    };

                    const value_t = next.type.cast(.option).child_t;

                    // NOTE: Only one variable before case block so avoid pushing another ct block.
                    if (for_stmt.each) |each| {
                        const cx = sema.getResolveContext(c);
                        try cx.initCtVar2(c.alloc, each.as_name(), value_t, value);
                    }
                    defer {
                        if (for_stmt.each) |each| {
                            const cx = sema.getResolveContext(c);
                            cx.unsetCtParam(c.heap, each.as_name());
                        }
                    }
                    
                    const case_ir = try semaSwitchCase(c, info, for_case, control);
                    try cases_buf.append(c.alloc, case_ir);
                }
                continue;
            } else {
                return c.reportError("Unsupported", case_n);
            }
        }
        const case = case_n.cast(.case_stmt);
        switch (case.kind) {
            .case => {
                const case_ir = try semaSwitchCase(c, info, case, control);
                try cases_buf.append(c.alloc, case_ir);
            },
            .else_ => {
                const case_ir = try semaSwitchElseCase(c, info, case);
                try cases_buf.append(c.alloc, case_ir);
                has_else = true;
            },
        }
    }

    const cases_loc = try c.ir.allocArray(*ir.Expr, cases_buf.items.len);
    for (0..cases_buf.items.len) |i| {
        cases_loc[i] = cases_buf.items[i];
    }

    _ = try c.ir.pushStmt(.switch_stmt, @ptrCast(block), .{
        .numCases = @intCast(cases_buf.items.len),
        .cases = cases_loc.ptr,
    });
    if (!info.end_reachable) {
        c.block().endReachable = false;
    }

    if (info.exhaust_enum) {
        if (info.enum_num_covered < info.enum_coverage.len) {
            return c.reportErrorFmt("Unhandled cases in `switch`. `else` can be used to handle the remaining cases.", &.{}, @ptrCast(block));
        }
        return;
    }

    // All other types check for `else`.
    if (!has_else) {
        return c.reportErrorFmt("Expected `else` case since switch does not handle all cases.", &.{}, @ptrCast(block));
    }
}

fn semaSwitchElseCase(c: *cy.Chunk, info: *SwitchInfo, case: *ast.CaseStmt) !*ir.Expr {
    if (info.exhaust_enum) {
        if (info.enum_num_covered == info.enum_coverage.len) {
            return c.reportError("Unexpected `else` case. All cases are handled.", @ptrCast(case));
        }
    }

    _ = try pushBlock(c, @ptrCast(case));
    if (case.body_kind == .expr) {
        const body = case.body_data.expr;
        var expr = try c.semaExpr(body, info.opts);
        expr = try semaOwn(c, expr, body);

        // Infer target type.
        if (info.opts.target_t == null) {
            info.setTargetType(c, expr.type);
        }

        // Assign to res.
        _ = try c.ir.pushStmt(.set_local, body, .{
            .id = @intCast(info.res_local),
            .right = expr.ir,
        });
    } else {
        if (info.is_expr) {
            return c.reportErrorFmt("Assign switch statement requires a return case: `else => {expr}`", &.{}, @ptrCast(case));
        }

        try semaStmts(c, case.body_data.block.slice());
    }

    if (info.exhaust_enum) {
        @memset(info.enum_coverage, true);
        info.enum_num_covered = @intCast(info.enum_coverage.len);
    }

    if (!info.end_reachable and c.block().endReachable) {
        info.end_reachable = true;
    }
    const stmtBlock = try popBlock(c);
    return c.ir.newExpr(.switch_case, c.sema.void_t, @ptrCast(case), .{
        .numConds = 0,
        .body_head = stmtBlock.first,
        .conds = undefined,
        .fallthrough = false,
    });
}

fn semaSwitchCase(c: *cy.Chunk, info: *SwitchInfo, case: *ast.CaseStmt, control: ExprResult) !*ir.Expr {
    const hasCapture = case.data.case.capture != null;

    var conds_buf: std.ArrayList(*ir.Expr) = .empty;
    defer conds_buf.deinit(c.alloc);

    var case_capture_type: ?*cy.Type = null;
    var conds: []*ir.Expr = &.{};
    if (case.data.case.conds.len > 0) {
        for (case.data.case.conds.slice()) |cond| {
            if (info.control_is_choice) {
                var payload_t: *cy.Type = undefined;
                const case_cond = try semaChoiceCaseCond(c, info, cond, &payload_t);
                try conds_buf.append(c.alloc, case_cond);                
                if (case_capture_type == null) {
                    case_capture_type = payload_t;
                } else {
                    // TODO: Handle multiple cond capture types.
                    return c.reportErrorFmt("TODO", &.{}, cond);
                }
            } else {
                try semaCaseCond(c, info, &conds_buf, info.control_n, control, cond);
            }
        }

        conds = try c.ir.allocArray(*ir.Expr, conds_buf.items.len);
        @memcpy(conds, conds_buf.items);
    }

    _ = try pushBlock(c, @ptrCast(case));

    if (hasCapture) {
        const capture_t = case_capture_type orelse {
            return c.reportError("Only a case of a choice can capture a payload.", case.data.case.capture.?);
        };

        // Copy payload to captured var.
        const fieldLoc = try c.ir.newExpr(.field, capture_t, case.data.case.capture.?, .{
            .idx = 1,
            .rec = control.ir,
        });
        var capture = ExprResult.init2(fieldLoc);
        capture.addressable = true;

        switch (case.data.case.capture.?.type()) {
            .ident => {
                const name = case.data.case.capture.?.cast(.ident).name.slice();
                capture = try sema_copy(c, capture, case.data.case.capture.?);
                _ = try declareLocalInit(c, name, capture_t, capture, case.data.case.capture.?);
            },
            .borrow => {
                const borrow = case.data.case.capture.?.cast(.borrow);
                if (borrow.child.type() != .ident) {
                    return c.reportError("Unsupported capture.", borrow.child);
                }
                const name = borrow.child.cast(.ident).name.slice();
                const borrow_t = try getBorrowType(c, capture_t);
                capture = try semaAddressOf(c, capture, borrow_t, case.data.case.capture.?);
                _ = try declareLocalInit(c, name, borrow_t, capture, case.data.case.capture.?);
            },
            else => {
                return c.reportError("Unsupported capture.", case.data.case.capture.?);
            },
        }
    }

    if (case.body_kind == .expr) {
        const body = case.body_data.expr;

        var body_expr: ExprResult = undefined;
        if (info.opts.target_t == null) {
            // Infer target type.
            body_expr = try c.semaExpr(body, info.opts);
            info.setTargetType(c, body_expr.type);
        } else {
            body_expr = try c.semaExprCstr(body, info.opts.target_t.?);
        }
        body_expr = try semaOwn(c, body_expr, body);

        // Assign to res.
        _ = try c.ir.pushStmt(.set_local, body, .{
            .id = @intCast(info.res_local),
            .right = body_expr.ir,
        });
    } else if (case.body_kind == .fallthrough) {
        // nop.
    } else if (case.body_kind == .block) {
        if (info.is_expr) {
            return c.reportErrorFmt("Assign switch statement requires a return case: `case {cond} => {expr}`", &.{}, @ptrCast(case));
        }

        try semaStmts(c, case.body_data.block.slice());
    } else {
        @panic("unexpected");
    }

    const fallthrough = case.body_kind == .fallthrough;
    if (!fallthrough) {
        if (!info.end_reachable and c.block().endReachable) {
            info.end_reachable = true;
        }
    }
    const stmtBlock = try popBlock(c);
    return c.ir.newExpr(.switch_case, c.sema.void_t, @ptrCast(case), .{
        .numConds = @intCast(conds_buf.items.len),
        .body_head = stmtBlock.first,
        .conds = conds.ptr,
        .fallthrough = fallthrough,
    });
}

fn semaChoiceCaseCond(c: *cy.Chunk, info: *SwitchInfo, right_n: *ast.Node, out_payload_t: **cy.Type) !*ir.Expr {
    const choice_t = info.control_t.cast(.choice);
    if (right_n.type() != .dot_lit) {
        const targetTypeName = choice_t.base.name();
        return c.reportErrorFmt("Expected enum literal to match `{}`", &.{v(targetTypeName)}, right_n);
    }
    const name = right_n.cast(.dot_lit).as_dot_infer_name();
    const case = choice_t.getCase(name) orelse {
        const targetTypeName = choice_t.base.name();
        return c.reportErrorFmt("`{}` is not a member of `{}`", &.{v(name), v(targetTypeName)}, right_n);
    };
    if (info.enum_coverage[case.idx]) {
        return c.reportError("Duplicate case.", right_n);
    }
    info.enum_coverage[case.idx] = true;
    info.enum_num_covered += 1;

    const tag_local = try semaLocal(c, info.choice_tag_local, right_n);

    out_payload_t.* = case.payload_t;
    const right = try c.semaConst(case.val, c.sema.i64_t, right_n);
    const res = try semaCompare(c, info.control_n, tag_local, right_n, right, right_n);
    return c.ir.newExpr(.case_cond, c.sema.void_t, right_n, .{
        .body_head = null,
        .expr = res.ir,
    });
}

fn semaCaseCondEnd(c: *cy.Chunk, var_start: usize, cond_local: u32, control_n: *ast.Node, control: ExprResult, right_n: *ast.Node, right: ExprResult) !*ir.Expr {
    var cond_res = try semaCompare(c, control_n, control, right_n, right, right_n);
    if (c.varStack.items.len > var_start) {
        _ = try c.ir.pushStmt(.set_local, right_n, .{
            .id = c.varStack.items[cond_local].inner.local.id,
            .right = cond_res.ir,
        });
        try popLocals(c, var_start, right_n);
        cond_res = try semaLocal(c, cond_local, right_n);
    }
    const cond_block = c.ir.popStmtBlock();
    return c.ir.newExpr(.case_cond, c.sema.void_t, right_n, .{
        .body_head = cond_block.first,
        .expr = cond_res.ir,
    });
}

fn semaCaseCond(c: *cy.Chunk, info: *SwitchInfo, conds_buf: *std.ArrayList(*ir.Expr), expr_n: *ast.Node, expr: ExprResult, cond: *ast.Node) !void {
    if (false) {
    // if (info.control_t.id() == bt.MetaType) {
        // try c.ir.pushStmtBlock(c.alloc);
        // const var_start = c.varStack.items.len;
        // var right = try c.semaExprSkipSym(cond, .{});
        // if (right.resType == .sym) {
        //     if (right.data.sym.type == .type) {
        //         const static_t = right.data.sym.getStaticType().?;
        //         _ = static_t;
        //         // right = try semaMetaType(c, static_t, cond);
        //         {
        //             return error.TODO;
        //         }
        //     } else {
        //         return error.TODO;
        //     }
        // } else {
        //     return error.TODO;
        // }
        // const cond_expr = try semaCaseCondEnd(c, var_start, expr_n, expr, cond, right);
        // try conds_buf.append(c.alloc, cond_expr);
    } else {
        if (cond.type() == .range) {
            if (info.control_t.kind() != .int and info.control_t.kind() != .raw) {
                return c.reportError("Expected range to match `Int` or `Raw` type.", cond);
            }
            const range = cond.cast(.range);
            if (range.start == null or range.end == null) {
                return c.reportError("Expected a range with a start and an end.", cond);
            }
            const start = try cte.evalCheck(c, range.start.?, c.sema.eval_int_t);
            const end = try cte.evalCheck(c, range.end.?, c.sema.eval_int_t);

            const start_i = start.value.as_eval_int();
            const end_i = end.value.as_eval_int();
            if (start_i > end_i) {
                return c.reportErrorFmt("Expected range start `{}` <= range end `{}`.", &.{v(start_i), v(end_i)}, cond);
            }

            const min = try ct_inline.value(c, start, info.control_t, range.start.?);
            const greater = try sema_bin_expr3(c, expr, expr_n, min, range.start.?, .greater_equal, cond);

            const max = try ct_inline.value(c, end, info.control_t, range.end.?);
            const less = try sema_bin_expr3(c, expr, expr_n, max, range.end.?, .less_equal, cond);

            const cond_res = try semaLogicAnd2(c, range.start.?, greater, range.end.?, less, cond);
            const cond_expr = try c.ir.newExpr(.case_cond, c.sema.void_t, cond, .{
                .body_head = null,
                .expr = cond_res.ir,
            });
            try conds_buf.append(c.alloc, cond_expr);
        } else {
            try c.ir.pushStmtBlock(c.alloc);

            const var_start = c.varStack.items.len;
            const right = try cte.evalTarget(c, cond, info.control_t); 
            defer c.heap.destructValue(right);
            const right_ir = try ct_inline.value(c, right, info.control_t, cond);

            if (info.exhaust_enum) {
                if (info.enum_coverage[@intCast(right.value.asInt())]) {
                    return c.reportError("Duplicate case.", cond);
                }
                info.enum_coverage[@intCast(right.value.asInt())] = true;
                info.enum_num_covered += 1;
            }

            const eff_control = expr;
            const cond_res = try semaCaseCondEnd(c, var_start, info.cond_local, expr_n, eff_control, cond, right_ir);
            try conds_buf.append(c.alloc, cond_res);
        }
    }
}

pub fn semaMadd(c: *cy.Chunk, base: ExprResult, scale: i64, mul: ExprResult, node: *ast.Node) !ExprResult {
    const scale_res = try c.semaConst(@bitCast(scale), c.sema.i64_t, node);
    const mul_res = try c.ir.newExpr(.mul, c.sema.i64_t, node, .{
        .left = mul.ir,
        .right = scale_res.ir,
    });
    const loc = try c.ir.newExpr(.add, c.sema.i64_t, node, .{
        .left = base.ir,
        .right = mul_res,
    });
    return sema.ExprResult.init2(loc);
}

pub fn semaAddressOf(c: *cy.Chunk, child: ExprResult, ptr_t: *cy.Type, node: *ast.Node) !ExprResult {
    const expr = try c.ir.newExpr(.address_of, ptr_t, node, .{
        .expr = child.ir,
    });
    var res = ExprResult.init2(expr);
    res.data.value.parent_local = child.recParentLocal();
    return res;
}

pub fn sema_bitcast_nocheck(c: *cy.Chunk, expr: ExprResult, target_t: *cy.Type, node: *ast.Node) !ExprResult {
    const res = try c.ir.newExpr(.bitcast, target_t, node, .{
        .expr = expr.ir,
    });
    return ExprResult.init2(res);
}

pub fn semaBitcast(c: *cy.Chunk, expr: ExprResult, target_t: *cy.Type, node: *ast.Node) !ExprResult {
    for ([_]*cy.Type{ target_t, expr.type }) |type_| {
        if (!type_.has_size()) {
            const name = try c.sema.allocTypeName(type_);
            defer c.alloc.free(name);
            return c.reportErrorFmt("The type `{}` has no size.", &.{v(name)}, node);
        }
    }
    if (target_t.size() != expr.type.size()) {
        return c.reportErrorFmt("Expected source type size `{}` to match the target type size `{}`.", &.{v(expr.type.size()), v(target_t.size())}, node);
    }
    return sema_bitcast_nocheck(c, expr, target_t, node);
}

pub fn semaDeref(c: *cy.Chunk, ptr: ExprResult, node: *ast.Node) !ExprResult {
    const child_t = ptr.type.getRefLikeChild().?;
    const deref = try c.ir.newExpr(.deref, child_t, node, .{
        .expr = ptr.ir,
    });
    const parent_local = ptr.recParentLocal();
    var res = ExprResult.init2(deref);
    res.data.value.parent_local = parent_local;
    // A dereference is always addressable: its address is the pointer value itself.
    // Taking `ptr.addressable` made `*(as[Ptr[T]] p)[i]` copy the element into a hidden
    // temp (no retain), return the temp's address and then destruct the temp.
    res.addressable = true;
    return res;
}

pub fn sema_copy(c: *cy.Chunk, expr: ExprResult, node: *ast.Node) anyerror!ExprResult {
    try checkPartialMoveWhole(c, expr, "copy", node);
    if (expr.type.info.no_copy) {
        const name = try c.sema.allocTypeName(expr.type);
        defer c.alloc.free(name);

        const no_copy = c.sema.types.items[bt.NoCopy].cast(.generic_trait);
        if (try sema_type.implements(c, expr.type, no_copy, node)) {
            return c.reportErrorFmt("Cannot copy `{}`, type implements `NoCopy`.", &.{v(name)}, node);
        } else {
            return c.reportErrorFmt("Cannot copy `{}`, type member implements `NoCopy`.", &.{v(name)}, node);
        }
    }
    if (!expr.type.hasCopyCtor()) {
        return expr;
    }

    switch (expr.type.id()) {
        else => {
            switch (expr.type.kind()) {
                .pointer => {
                    const pointer = expr.type.cast(.pointer);
                    if (pointer.ref and !expr.type.info.copy_user) {
                        const loc = try c.ir.newExpr(.retain, expr.type, node, .{
                            .expr = expr.ir,
                        });
                        return ExprResult.initOwned(loc);
                    }
                },
                .func => {
                    if (!expr.type.info.copy_user) {
                        const loc = try c.ir.newExpr(.retain, expr.type, node, .{
                            .expr = expr.ir,
                        });
                        return ExprResult.initOwned(loc);
                    }
                },
                else => {},
            }
        },
    }
    // Invoke @copy.
    const addr_expr = expr;
    if (!expr.addressable) {
        return c.reportErrorFmt("Unexpected value with managed type is not addressable.", &.{}, node);
        // const tempv = try declareHiddenLocal(c, "_temp", expr.type, expr, node);
        // addr_expr = try semaLocal(c, tempv.id, node);
    }
    const ptr_t = try getPtrType(c, expr.type);
    const ptr_loc = try c.ir.newExpr(.address_of, ptr_t, node, .{
        .expr = addr_expr.ir,
    });
    const ptr = ExprResult.init(ptr_loc, ptr_t);
    const copy_fn = try getCopyFunc(c, expr.type, node);
    const arg = Argument.initPreResolved(node, ptr);
    return c.semaCallFunc2(copy_fn, &.{arg}, &.{}, node);
}

/// An operand whose IR is built but that the enclosing expression has not consumed yet.
///
/// Analysis can add statements in the middle of an expression: a temporary for a method receiver, an `await`,
/// the branch of an `!` unwrap, the block of an `and`. Such a statement runs before the statement that holds
/// the expression. Without care it would run before the operands that were analyzed earlier, so
/// `say(1) + mk(2).get()` would call `mk(2)` first. `seqFlush` evaluates the pending operands into locals right
/// before such a statement is added, which keeps the order left to right.
pub const SeqEntry = struct {
    /// Where the consumer reads the operand's IR from. Rewritten to a read of the local.
    slot: **ir.Expr,
    orig: *ir.Expr,
    /// The consumer takes ownership of the value.
    owned: bool,
    node: *ast.Node,
    /// `ir.stmtBlockStack` length at registration. The local is declared in that block only.
    depth: usize,
    /// `Chunk.semaProcs` length at registration.
    proc_depth: usize,
    var_id: u32 = cy.NullId,
    decl: ?*ir.Stmt = null,
};

/// An operand that nothing can affect and that has no effect itself does not have to be evaluated early.
fn seqOrderFree(expr: *ir.Expr) bool {
    return switch (expr.code) {
        .local, .captured, .const8, .const16, .const32, .const64, .truev, .falsev, .voidv, .undef,
        .func, .func_ptr, .string, .init_zero, .address_of => true,
        else => false,
    };
}

/// Registers the IR slot of an operand that is done. The caller pops with `seqPop` once the operands after it
/// are analyzed, on every path (`defer`).
pub fn seqPush(c: *cy.Chunk, slot: **ir.Expr, owned: bool, node: *ast.Node) !void {
    const expr = slot.*;
    if (seqOrderFree(expr)) return;
    const type_ = expr.type;
    // A borrow stays tied to its owner. It is not held in another local.
    if (type_.kind() == .borrow or type_.kind() == .ex_borrow or type_.info.borrow_only) return;
    if (type_.kind() == .void or type_.kind() == .never) return;
    try c.seq_pending.append(c.alloc, .{
        .slot = slot,
        .orig = expr,
        .owned = owned,
        .node = node,
        .depth = c.ir.stmtBlockStack.items.len,
        .proc_depth = c.semaProcs.items.len,
    });
    c.ir.seq_pending = c.seq_pending.items.len;
}

/// Registers an operand result. A place (a local, a field) is not registered: its consumer can take its address.
pub fn seqPushRes(c: *cy.Chunk, res: *ExprResult, node: *ast.Node) !void {
    if (res.resType != .value or res.addressable) return;
    try seqPush(c, &res.ir, res.owned, node);
}

/// An overload candidate that does not match discards the locals and statements of its attempt
/// (`sema_func.matchRtOverload`). A local that was declared for a pending operand goes with them.
fn seqValidate(c: *cy.Chunk, e: *SeqEntry) void {
    if (e.var_id == cy.NullId) return;
    if (e.var_id < c.varStack.items.len) {
        const local = &c.varStack.items[e.var_id];
        if (@as(?*ir.Stmt, @ptrCast(local.inner.local.declIrStart)) == e.decl) return;
    }
    e.slot.* = e.orig;
    e.var_id = cy.NullId;
    e.decl = null;
}

/// Called before a statement or a statement block is added while operands are pending (`ir.Buffer.seq_pending`).
pub fn seqFlush(c: *cy.Chunk) anyerror!void {
    if (c.seq_flushing) return;
    c.seq_flushing = true;
    defer c.seq_flushing = false;

    const depth = c.ir.stmtBlockStack.items.len;
    var i: usize = 0;
    while (i < c.seq_pending.items.len) : (i += 1) {
        seqValidate(c, &c.seq_pending.items[i]);
        var e = c.seq_pending.items[i];
        if (e.var_id != cy.NullId or e.depth != depth or e.proc_depth != c.semaProcs.items.len) continue;

        const temp = try declareHiddenLocal(c, "_seq", e.orig.type, ExprResult.init2(e.orig), e.node);
        const local = &c.varStack.items[temp.id];
        e.decl = @ptrCast(local.inner.local.declIrStart);
        if (!(e.owned and e.orig.type.isManaged())) {
            // Nothing to destruct. An owned value stays alive until `seqPop`, so that a return in between
            // (the error branch of a later `!`) destructs it.
            local.type = .dead;
        }
        e.slot.* = try c.ir.newExpr(.local, e.orig.type, e.node, .{ .id = local.inner.local.id });
        e.var_id = @intCast(temp.id);
        c.seq_pending.items[i] = e;
    }
}

/// Ends the registrations since `start`. The consumer now owns the values held for it.
pub fn seqPop(c: *cy.Chunk, start: usize) void {
    for (c.seq_pending.items[start..]) |*e| {
        seqValidate(c, e);
        if (e.var_id != cy.NullId) {
            c.varStack.items[e.var_id].type = .dead;
        }
    }
    c.seq_pending.items.len = start;
    c.ir.seq_pending = start;
}

pub fn semaEnsureAddressable(c: *cy.Chunk, expr: ExprResult, node: *ast.Node) !ExprResult {
    if (!expr.addressable) {
        const tempv = try declareHiddenLocal(c, "_temp", expr.type, expr, node);
        c.varStack.items[tempv.id].lifetime = Lifetime.initTemp();
        return semaLocal(c, tempv.id, node);
    }
    return expr;
}

pub fn semaManage(c: *cy.Chunk, expr: ExprResult, node: *ast.Node) !ExprResult {
    if (!expr.type.isManaged()) {
        return expr;
    }
    if (!expr.owned) {
        return expr;
    }

    const tempv = try declareHiddenLocal(c, "_temp", expr.type, expr, node);
    c.varStack.items[tempv.id].lifetime = .initTemp();
    return semaLocal(c, tempv.id, node);
}

pub fn semaOwn(c: *cy.Chunk, expr: ExprResult, node: *ast.Node) !ExprResult {
    if (expr.owned) {
        return expr;
    }
    return sema_copy(c, expr, node);
}

fn semaLift(c: *cy.Chunk, expr: ExprResult, node: *ast.Node) !ExprResult {
    if (expr.type.info.borrow_only) {
        const name = try c.sema.allocTypeName(expr.type);
        defer c.alloc.free(name);
        if (expr.type.kind() == .borrow) {
            return c.reportErrorFmt("Cannot lift the borrow type `{}`.", &.{v(name)}, node);
        } else {
            return c.reportErrorFmt("Cannot lift the borrow container type `{}`.", &.{v(name)}, node);
        }
    }

    const own_expr = try semaOwn(c, expr, node);
    const ref_t = try getRefType(c, expr.type);
    const loc = try c.ir.newExpr(.lift, ref_t, node, .{
        .child = own_expr.ir,
    });
    return ExprResult.initOwned(loc);
}

fn semaLiftToObject(c: *cy.Chunk, expr: ExprResult, node: *ast.Node) !ExprResult {
    const lift = try semaLift(c, expr, node);
    const loc = try c.ir.newExpr(.bitcast, c.sema.object_t, node, .{
        .expr = lift.ir,
    });

    // Ensure `deinitObject` for child type.
    if (lift.type.kind() == .pointer) {
        _ = try getDeinitObjFunc(c, lift.type.getRefLikeChild().?);
    } else {
        _ = try getDeinitObjFunc(c, lift.type);
    }
    return ExprResult.init(loc, c.sema.object_t);
}

pub fn semaTupleInit(c: *cy.Chunk, type_: *cy.Type, fields: []const cy.types.Field, lit: *ast.InitLit) !ExprResult {
    if (lit.args.len != fields.len) {
        return c.reportErrorFmt("Expected {} args, found {}.", &.{v(fields.len), v(lit.args.len)}, @ptrCast(lit));
    }

    const args = try c.ir.allocArray(*ir.Expr, fields.len);
    {
        // An element is evaluated before a statement that a later element adds (`seqFlush`).
        const seq_start = c.seq_pending.items.len;
        defer seqPop(c, seq_start);
        for (fields, 0..) |field, i| {
            var arg = try c.semaExprCstr(lit.args.ptr[i], field.type);
            arg = try semaOwn(c, arg, lit.args.ptr[i]);
            args[i] = arg.ir;
            try seqPush(c, &args[i], true, lit.args.ptr[i]);
        }
    }

    const init = try c.ir.newExpr(.init, type_, @ptrCast(lit), .{
        .nargs = @as(u8, @intCast(fields.len)), .args = args.ptr,
    });
    return ExprResult.initOwned(init);
}

pub fn semaInitPartialVector(c: *cy.Chunk, vector_t: *cy.types.PartialVector, init_n: *ast.InitLit) !ExprResult {
    const nargs = init_n.args.len;
    if (nargs > vector_t.n) {
        return c.reportErrorFmt("Expected at most `{}` elements, found `{}`.", &.{v(vector_t.n), v(nargs)}, @ptrCast(init_n));
    }
    const args = try c.ir.allocArray(*ir.Expr, nargs + 1);
    args[0] = (try semaConst(c, nargs, c.sema.i64_t, @ptrCast(init_n))).ir;
    {
        const seq_start = c.seq_pending.items.len;
        defer seqPop(c, seq_start);
        for (init_n.args.slice(), 0..) |arg_n, i| {
            var arg = try c.semaExprTarget(arg_n, vector_t.elem_t);
            arg = try semaOwn(c, arg, arg_n);
            args[i+1] = arg.ir;
            try seqPush(c, &args[i+1], true, arg_n);
        }
    }
    return semaPartialVector(c, &vector_t.base, args, @ptrCast(init_n));
}

pub fn semaInitVector(c: *cy.Chunk, vector_t: *cy.types.Vector, init_n: *ast.InitLit) !ExprResult {
    const nargs = init_n.args.len;
    const args = try c.ir.allocArray(*ir.Expr, nargs);
    {
        const seq_start = c.seq_pending.items.len;
        defer seqPop(c, seq_start);
        for (init_n.args.slice(), 0..) |arg_n, i| {
            var arg = try c.semaExprTarget(arg_n, vector_t.elem_t);
            arg = try semaOwn(c, arg, arg_n);
            args[i] = arg.ir;
            try seqPush(c, &args[i], true, arg_n);
        }
    }

    const loc = try c.ir.newExpr(.init, @ptrCast(vector_t), @ptrCast(init_n), .{
        .nargs = @intCast(nargs), .args = args.ptr,
    });
    return ExprResult.initOwned(loc);
}

pub fn semaInitGenericArray(c: *cy.Chunk, generic_t: *cy.types.GenericVector, init_n: *ast.InitLit) !ExprResult {
    const array_t = try getVectorType(c, generic_t.elem_t, @intCast(init_n.args.len));
    return semaInitVector(c, array_t.cast(.vector), init_n);
}

/// Emits the default initializer. Ignores `@init_record`.
pub fn semaInitStruct(c: *cy.Chunk, struct_t: *cy.types.Struct, initializer: *ast.InitLit) !ExprResult {
    const node: *ast.Node = @ptrCast(initializer);
    const sym = struct_t.base.sym();

    // Set up a temp buffer to map initializer entries to type fields.
    const fieldsDataStart = c.listDataStack.items.len;
    try c.listDataStack.resize(c.alloc, c.listDataStack.items.len + struct_t.fields_len);
    defer c.listDataStack.items.len = fieldsDataStart;

    const undecl_start = c.listDataStack.items.len;
    _ = undecl_start;

    // Initially set to NullId so missed mappings are known from a linear scan.
    const fieldNodes = c.listDataStack.items[fieldsDataStart..];
    @memset(fieldNodes, .{ .node = null });

    for (initializer.args.slice()) |arg| {
        if (arg.type() != .keyValue) {
            return c.reportError("Expected key value pair.", arg);
        }
        const pair = arg.cast(.keyValue);
        const fieldName = pair.key.nameOrNull() orelse {
            return c.reportError("Expected field name.", pair.key);
        };
        const info = try checkSymInitField(c, @ptrCast(sym), fieldName, pair.key);
        // if (info.use_get_method) {
        //     try c.listDataStack.append(c.alloc, .{ .node = entryId });
        //     entryId = entry.next();
        //     continue;
        // }

        fieldNodes[info.idx] = .{ .node = pair.value };
    }

    const ir_args = try c.ir.allocArray(*ir.Expr, struct_t.fields_len);

    // A field value is evaluated before a statement that the value of a later field adds (`seqFlush`).
    // The order is the order of the fields in the type.
    const seq_start = c.seq_pending.items.len;
    errdefer seqPop(c, seq_start);
    for (0..fieldNodes.len) |i| {
        const item = c.listDataStack.items[fieldsDataStart+i];
        const fieldT = struct_t.fields_ptr[i].type;
        if (item.node == null) {
            if (struct_t.fields_ptr[i].init_n) |init_n| {
                ir_args[i] = (try semaExprCstr(c, init_n, fieldT)).ir;
            } else {
                if (!struct_t.cstruct) {
                    return c.reportErrorFmt("Initialization requires the field `{}`.", &.{v(struct_t.fields_ptr[i].sym.head.name())}, node);
                }
                ir_args[i] = (try semaCZero(c, fieldT, node)).ir;
            }
        } else {
            var arg = try c.semaExprCstr(item.node.?, fieldT);
            arg = try semaOwn(c, arg, item.node.?);
            ir_args[i] = arg.ir;
            try seqPush(c, &ir_args[i], true, item.node.?);
        }
    }
    seqPop(c, seq_start);

    const loc = try c.ir.newExpr(.init, @ptrCast(struct_t), node, .{
        .nargs = @as(u8, @intCast(struct_t.fields_len)),
        .args = ir_args.ptr,
    });
    return ExprResult.initOwned(loc);
}

/// `initializerId` is a record literal node.
/// If `ref_t` is provided, it becomes a ref initializer.
pub fn semaObjectInit2(c: *cy.Chunk, struct_t: *cy.types.Struct, initializer: *ast.InitLit) !ExprResult {
    const sym = struct_t.base.sym();
    if (try c.getResolvedSym(@ptrCast(sym), "@init_record", @ptrCast(initializer))) |init_pairs| {
        return semaInitRecord(c, init_pairs, initializer);
    }
    return semaInitStruct(c, struct_t, initializer);
}

pub fn semaInitExpr(c: *cy.Chunk, node: *ast.InitExpr, cstr: Cstr) !ExprResult {
    const left = try c.semaExprSkipSym(node.left, .{});
    if (left.resType != .sym) {
        return c.reportError("Expected type for initializer.", node.left);
    }

    const sym = left.data.sym.resolved();
    switch (sym.type) {
        .type => {
            const type_sym = sym.cast(.type);
            const type_ = type_sym.type;
            return semaInitLitTarget(c, node.lit, type_, false, cstr.assign_to_local);
        },
        .enum_case => {
            const str = c.ast.nodeString(node.left);
            return c.reportErrorFmt("Can not initialize enum case `{}`.", &.{v(str)}, node.left);
        },
        .union_case => {
            const str = c.ast.nodeString(node.left);
            return c.reportErrorFmt("Can not initialize cunion case `{}`.", &.{v(str)}, node.left);
        },
        .choice_case => {
            const str = c.ast.nodeString(node.left);
            return c.reportErrorFmt("Can not initialize choice case `{}`.", &.{v(str)}, node.left);
        },
        .template => {
            const str = c.ast.nodeString(node.left);
            return c.reportErrorFmt("Expected a type, found type template. Expand `{}` to a type.", &.{v(str)}, node.left);
        },
        else => {
            const str = c.ast.nodeString(node.left);
            return c.reportErrorFmt("Can not initialize `{}`.", &.{v(str)}, node.left);
        }
    }
}

/// First arg contains the receiver.
pub fn semaCallFuncSymRec2(c: *cy.Chunk, sym: *cy.sym.FuncSym, args: []const Argument, node: *ast.Node) !ExprResult {
    if (sym.first.type == .trait) {
        // Trait function will always match first argument.
        const rec_arg = args[0];
        const res = try sema_func.matchFuncSym(c, sym, args, &.{}, false, node);
        try cy.global_init.recordIndirectCall(c);
        const loc = try c.ir.newExpr(.call_trait, res.func.sig.ret, node, .{
            .trait = rec_arg.data.receiver.ir,
            .vtable_idx = @intCast(res.func.data.trait.vtable_idx),
            .nargs = @intCast(res.data.rt.nargs),
            .args = res.data.rt.args,
        });
        try semaCancelPad(c, @intFromPtr(loc), node);
        return ExprResult.initOwned(loc);
    } else {
        return sema_func.matchFuncSym2(c, sym, args, &.{}, false, node);
    }
}

pub fn semaCallFuncSymRec(c: *cy.Chunk, sym: *cy.sym.FuncSym, rec: *ast.Node, rec_res: ExprResult,
    args: []const *ast.Node, req_value: bool, node: *ast.Node) !ExprResult {
    const rec_arg = Argument.initReceiver(rec, rec_res);
    if (sym.first.type == .trait) {
        // Trait function will always match first argument.
        const res = try sema_func.matchFuncSym(c, sym, &.{rec_arg}, args, false, node);
        try cy.global_init.recordIndirectCall(c);
        const loc = try c.ir.newExpr(.call_trait, res.func.sig.ret, node, .{
            .trait = rec_res.ir,
            .vtable_idx = @intCast(res.func.data.trait.vtable_idx),
            .nargs = @intCast(res.data.rt.nargs),
            .args = res.data.rt.args,
        });
        try semaCancelPad(c, @intFromPtr(loc), node);
        return ExprResult.initOwned(loc);
    } else {
        return sema_func.matchFuncSym2(c, sym, &.{rec_arg}, args, req_value, node);
    }
}

/// A call site inside a loop marks the callee hot. bc_gen then inlines at the sites in the callee's body
/// as if they were in a loop (`inline_cost_fits`).
pub fn markHotCall(c: *cy.Chunk, func: *cy.Func) void {
    if (c.semaProcs.items.len > 0 and c.loopBlock(c.proc().block_start) != null) {
        func.info.bc_hot = true;
    }
}

pub fn sema_call_ir(c: *cy.Chunk, func: *cy.Func, args: []const *ir.Expr, node: *ast.Node) !ExprResult {
    markHotCall(c, func);
    try cy.global_init.recordCall(c, func);
    try semaCancelHoist(c);
    const expr = try c.ir.newExpr(.call, func.sig.ret, node, .{ 
        .func = func, .numArgs = @intCast(args.len), .args = args.ptr,
    });
    try semaCancelPad(c, @intFromPtr(expr), node);
    return sema.ExprResult.initOwned(expr);
}

/// Whether the code that is analyzed can run in a frame of a fiber that is cancelled.
/// The main block is never on a fiber's stack. A generator body has its own drop path (the deinit block of
/// each `yield`), and a fiber with a generator frame on its stack is not cancelled.
fn cancelPadApplies(c: *cy.Chunk) bool {
    if (c.cancel_pad_building) return false;
    const func = c.proc().func orelse return false;
    return !func.info.generator;
}

/// Before a call is added to an expression: the operands of the expression that are done and own a managed
/// value are moved to locals (`seqFlush`), so that the pad of the call destructs them. Without this,
/// `'a' + f()` would leak the string when the fiber is cancelled inside `f`.
pub fn semaCancelHoist(c: *cy.Chunk) !void {
    if (c.ir.seq_pending == 0 or !cancelPadApplies(c)) return;
    const depth = c.ir.stmtBlockStack.items.len;
    for (c.seq_pending.items) |e| {
        if (e.var_id != cy.NullId or e.depth != depth or e.proc_depth != c.semaProcs.items.len) continue;
        if (e.owned and e.orig.type.isManaged()) {
            return seqFlush(c);
        }
    }
}

/// Attaches a cancel pad to the IR node at `key` (a call expr, a `suspend_` or an `await_` stmt): the
/// statements that a `return` at this point would run to destruct the proc's locals, and a return without a
/// value. bc_gen emits the pad after the function body and records the site in `ByteCodeBuffer.cancel_table`.
/// `Fiber.cancel` sends every frame of a suspended fiber to the pad of the site it is at, so the frames
/// release what they own from the top down and the fiber ends. Nothing runs on the normal path.
/// Consecutive sites with the same live locals share a pad.
pub fn semaCancelPad(c: *cy.Chunk, key: usize, node: *ast.Node) !void {
    if (!cancelPadApplies(c)) return;
    const proc = c.proc();

    var hasher = std.hash.Wyhash.init(0);
    const b = c.procBlock();
    for (c.varStack.items[b.varStart..], b.varStart..) |*local, i| {
        if (local.type != .local) continue;
        std.hash.autoHash(&hasher, i);
        std.hash.autoHash(&hasher, @intFromPtr(local.decl_t));
        std.hash.autoHash(&hasher, local.inner.local.id);
    }
    // Zero is "no pad yet".
    const sig = hasher.final() | 1;
    if (proc.cancel_pad) |pad| {
        if (proc.cancel_pad_sig == sig) {
            try c.cancel_pads.put(c.alloc, key, pad);
            return;
        }
    }

    c.cancel_pad_building = true;
    defer c.cancel_pad_building = false;
    // The pad is not part of the expression that is analyzed. Its statements must not flush the operands that
    // are still pending there (`ir.Buffer.pushStmt` would).
    const saved_flushing = c.seq_flushing;
    c.seq_flushing = true;
    defer c.seq_flushing = saved_flushing;
    try c.ir.pushStmtBlock(c.alloc);
    {
        errdefer _ = c.ir.popStmtBlock();
        try semaDestructBlock2(c, b);
        _ = try c.ir.pushStmt(.ret, node, .{ .return_value = false });
    }
    const block = c.ir.popStmtBlock();
    // `proc` can be stale: analyzing a destructor can add procs.
    const cur = c.proc();
    cur.cancel_pad = block.first;
    cur.cancel_pad_sig = sig;
    try c.cancel_pads.put(c.alloc, key, block.first.?);
}

pub fn semaCallFuncResult(c: *cy.Chunk, res: sema_func.FuncResult, node: *ast.Node) !ExprResult {
    // try referenceSym(c, @ptrCast(matcher.sym), node);
    return sema_call_ir(c, res.func, res.data.rt.args[0..res.data.rt.nargs], node);
}

pub fn semaCallValue(c: *cy.Chunk, callee: ExprResult, callee_n: *ast.Node, args: []*ast.Node, node: *ast.Node) !ExprResult {
    if (callee.type.kind() == .func_ptr) {
        return c.semaCallPtr(callee, callee.type.cast(.func_ptr).sig, args, node);
    } else if (callee.type.kind() == .func) {
        return c.semaCallUnion(callee, callee_n, callee.type.cast(.func).sig, args, node);
    } else {
        return c.reportErrorFmt("Expected callee, found {}.", &.{v(callee.type.kind())}, node);
    }
}

pub fn semaCallPtr(c: *cy.Chunk, func: ExprResult, sig: *FuncSig, args: []*ast.Node, node: *ast.Node) !ExprResult {
    const ir_args = try c.ir.allocArray(*ir.Expr, args.len);
    var match_err: sema_func.FuncMatchError = undefined;
    _ = (try sema_func.matchFuncSig(c, sig, &.{}, args, ir_args, false, false, &match_err)) orelse {
        return sema_func.reportCallFuncMismatch(c, &.{}, args, "", sig, match_err, node);
    };
    if (sig.extern_) {
        func.type.cast(.func_ptr).extern_is_called = true;
    }
    try cy.global_init.recordIndirectCall(c);
    try semaCancelHoist(c);
    const loc = try c.ir.newExpr(.call_ptr, sig.ret, node, .{
        .callee = func.ir,
        .nargs = @intCast(ir_args.len),
        .args = ir_args.ptr,
    });
    try semaCancelPad(c, @intFromPtr(loc), node);
    return ExprResult.initOwned(loc);
}

pub fn semaCallUnion(c: *cy.Chunk, func: ExprResult, func_n: *ast.Node, sig: *FuncSig, args: []*ast.Node, node: *ast.Node) !ExprResult {
    const managed = try semaManage(c, func, func_n);

    const ir_args = try c.ir.allocArray(*ir.Expr, args.len);
    var match_err: sema_func.FuncMatchError = undefined;
    _ = (try sema_func.matchFuncSig(c, sig, &.{}, args, ir_args, false, false, &match_err)) orelse {
        return sema_func.reportCallFuncMismatch(c, &.{}, args, "", sig, match_err, node);
    };
    try cy.global_init.recordIndirectCall(c);
    try semaCancelHoist(c);
    const loc = try c.ir.newExpr(.call_union, sig.ret, node, .{
        .callee = managed.ir,
        .nargs = @intCast(ir_args.len),
        .args = ir_args.ptr,
    });
    try semaCancelPad(c, @intFromPtr(loc), node);
    return ExprResult.initOwned(loc);
}

pub fn semaCallFunc(c: *cy.Chunk, func: *cy.Func, args: []*ast.Node, node: *ast.Node) !ExprResult {
    const res = try sema_func.matchFunc(c, func, &.{}, args, false, node);
    return c.semaCallFuncResult(.{ .func = res.func, .kind = res.kind, .data = res.data }, node);
}

pub fn semaCallFunc2(c: *cy.Chunk, func: *cy.Func, pre_args: []const Argument, args: []*ast.Node, node: *ast.Node) !ExprResult {
    const res = try sema_func.matchFunc(c, func, pre_args, args, false, node);
    return c.semaCallFuncResult(.{ .func = res.func, .kind = res.kind, .data = res.data }, node);
}

pub fn semaCallFuncSym1(c: *cy.Chunk, sym: *cy.sym.FuncSym, arg1_n: *ast.Node, arg1: ExprResult, node: *ast.Node) !ExprResult {
    const arg = Argument.initPreResolved(arg1_n, arg1);
    return sema_func.matchFuncSym2(c, sym, &.{arg}, &.{}, false, node);
}

pub fn semaCallFuncSym2(c: *cy.Chunk, sym: *cy.sym.FuncSym, arg1_n: *ast.Node, arg1_res: ExprResult,
    arg2_n: *ast.Node, arg2_res: ExprResult, node: *ast.Node) !ExprResult {
    const arg1 = Argument.initPreResolved(arg1_n, arg1_res);
    const arg2 = Argument.initPreResolved(arg2_n, arg2_res);
    return sema_func.matchFuncSym2(c, sym, &.{arg1, arg2}, &.{}, false, node);
}

/// Match first overloaded function.
pub fn semaCallFuncSym(c: *cy.Chunk, sym: *cy.sym.FuncSym, args: []const *ast.Node, req_value: bool, node: *ast.Node) !ExprResult {
    return sema_func.matchFuncSym2(c, sym, &.{}, args, req_value, node);
}

// pub fn semaCallGenericFuncRec(c: *cy.Chunk, template: *cy.sym.FuncTemplate, rec: *ast.Node, rec_res: ExprResult,
//     args: []const *ast.Node, node: *ast.Node) !ExprResult {

//     const rec_arg = Argument.initPreResolved(rec, rec_res);
//     return sema_func.matchGenericFunc(c, template, &.{rec_arg}, args, false, node);
// }

// pub fn semaCallGenericFunc(c: *cy.Chunk, func: *cy.sym.FuncTemplate, args: []const *ast.Node, req_value: bool, node: *ast.Node) !ExprResult {
//     return sema_func.matchGenericFunc(c, func, &.{}, args, req_value, node);
// }

/// Skips emitting IR for a sym.
pub fn semaExprSkipSym(c: *cy.Chunk, node: *ast.Node, cstr: Cstr) !ExprResult {
    switch (node.type()) {
        .group => {
            const child_n = node.cast(.group).child;
            return semaExprSkipSym(c, child_n, cstr);
        },
        .at_lit => {
            const name = node.cast(.at_lit).value.slice();
            if (c.semaProcs.items.len > 0) {
                const res = (try getResolvedName(c, name, node)) orelse {
                    return reportOldSymbolLit(c, name, node);
                };
                try checkIntrinsicUse(c, node);
                switch (res.type) {
                    .sym => {
                        return sema.symbol2(c, res.data.sym, true, cstr.target_t, node);
                    },
                    .ct_value => {
                        return c.reportErrorFmt("TODO ct_value", &.{}, node);
                    },
                    .ct_var => {
                        return c.reportErrorFmt("TODO ct_var", &.{}, node);
                    },
                }
            }
            return reportOldSymbolLit(c, name, node);
        },
        .ident => {
            return semaIdent(c, cstr, true, node);
        },
        .index_expr => {
            const index_expr = node.cast(.index_expr);
            var left = try semaExprSkipSym(c, index_expr.left, .{});
            if (left.resType == .sym) {
                switch (left.data.sym.type) {
                    .template => {
                        const template = left.data.sym.cast(.template);
                        const final_sym = try cy.template.expand_template_ast(c, template, index_expr.args.slice(), node);
                        return sema.symbol(c, final_sym, true, node);
                    },
                    .func_template => {
                        const template = left.data.sym.cast(.func_template);
                        const func_res = try cy.template.expandTemplateFuncForArgs(c, template, index_expr.args.slice(), node);
                        return ExprResult.initCustom(undefined, .func, c.sema.void_t, .{ .func = func_res });
                    },
                    .func => {
                        const func_sym = left.data.sym.cast(.func);
                        std.debug.assert(func_sym.numFuncs > 1);
                        const idx = try cte.evalCheck(c, index_expr.args.ptr[0], c.sema.i64_t);
                        const func = func_sym.get_func(@intCast(idx.value.asInt())) orelse {
                            return c.reportError("Index out of bounds.", index_expr.args.ptr[0]);
                        };
                        return sema_func_sym(c, func, true, null, node);
                    },
                    else => {
                        left = try sema.symbol(c, left.data.sym, false, node);
                    },
                }
            } else if (left.resType == .func) {
                return c.reportError("Expected overloaded function.", node);
            }
            return semaIndexExpr(c, index_expr.left, left, cstr, node);
        },
        .accessExpr => {
            const access = node.cast(.accessExpr);
            if (access.left.type() == .ident or access.left.type() == .accessExpr) {
                if (access.right.type() != .ident) return error.Unexpected;

                // TODO: Check if ident is sym to reduce work.
                return semaAccessExpr(c, access, true, cstr.target_t);
            } else {
                return c.semaExpr(node, .{});
            }
        },
        .generic_vector_type => {
            const vector_t = node.cast(.generic_vector_type);
            const sym = try cy.template.expand_template_ast(c, c.sema.generic_vector_tmpl, &.{ vector_t.elem_t }, node);
            return ExprResult.initCustom(undefined, .sym, sym.getStaticType().?, .{ .sym = sym });
        },
        .partial_vector_type => {
            const vector_t = node.cast(.partial_vector_type);
            const sym = try cy.template.expand_template_ast(c, c.sema.partial_vector_tmpl, &.{ vector_t.child, vector_t.n }, node);
            return ExprResult.initCustom(undefined, .sym, sym.getStaticType().?, .{ .sym = sym });
        },
        .vector_type => {
            const vector_t = node.cast(.vector_type);
            const sym = try cy.template.expand_template_ast(c, c.sema.vector_tmpl, &.{ vector_t.child, vector_t.n }, node);
            return ExprResult.initCustom(undefined, .sym, sym.getStaticType().?, .{ .sym = sym });
        },
        .span_type => {
            const span_type = node.cast(.span_type);
            const sym = try cy.template.expand_template_ast(c, c.sema.span_tmpl, &.{ span_type.child }, node);
            return ExprResult.initCustom(undefined, .sym, sym.getStaticType().?, .{ .sym = sym });
        },
        .slice_type => {
            const slice_type = node.cast(.slice_type);
            const sym = try cy.template.expand_template_ast(c, c.sema.slice_tmpl, &.{ slice_type.child }, node);
            return ExprResult.initCustom(undefined, .sym, sym.getStaticType().?, .{ .sym = sym });
        },
        .option_type => {
            const option_type = node.cast(.option_type);
            const sym = try cy.template.expand_template_ast(c, c.sema.option_tmpl, &.{ option_type.child }, node);
            return ExprResult.initCustom(undefined, .sym, sym.getStaticType().?, .{ .sym = sym });
        },
        else => {
            // Not a symbol path.
            return c.semaExpr(node, cstr);
        },
    }
}

pub fn semaExprHint(c: *cy.Chunk, node: *ast.Node, target_t: ?*cy.Type) !ExprResult {
    return try semaExpr(c, node, .{
        .target_t = target_t,
        .fit_target = false,
        .reqTypeCstr = false,
    });
}

pub fn semaExprTarget(c: *cy.Chunk, node: *ast.Node, target_t: ?*cy.Type) !ExprResult {
    return try semaExpr(c, node, .{
        .target_t = target_t,
        .reqTypeCstr = false,
        .fit_target = true,
    });
}

pub fn semaExprCstr(c: *cy.Chunk, node: *ast.Node, target_t: *cy.Type) !ExprResult {
    return try semaExpr(c, node, .{
        .target_t = target_t,
        .reqTypeCstr = true,
        .fit_target = true,
    });
}

pub fn semaExpr(c: *cy.Chunk, node: *ast.Node, cstr: Cstr) !ExprResult {
    // Set current node for unexpected errors.
    c.curNode = node;
    const res = try c.semaExprNoCheck(node, cstr);
    if (cy.Trace) {
        log.tracev("expr.{s}: end {s}", .{@tagName(node.type()), res.type.name()});
    }
    if (c.compiler.config.deny_raw_ptrs) {
        try check_raw_ptr(c, res.type, node);
    }

    if (cstr.target_t) |target_t| {
        if (target_t == res.type) {
            return res;
        }

        if (cstr.fit_target) {
            if (try semaFitTarget(c, res, target_t, node)) |new| {
                return new;
            }
        }

        if (res.type.id() == bt.Never) {
            return res;
        }

        if (cstr.reqTypeCstr) {
            return reportExpectedType(c, target_t, res.type, node);
        }
    }
    return res;
}

/// `deny_raw_ptrs` (F-06): a script chunk may not produce a value of a raw pointer type. Without `Ptr[T]` and
/// `PtrSpan[T]` values there is nothing to dereference at an arbitrary address (`as[Ptr[int]] 8`, `Ptr[int](8)`,
/// `as[Ptr[int]] &x` + `p[100000]`, `alloc(int)`, `PtrSpan[int]{length=4}`). Standard module chunks are exempt
/// because the core library is built on raw pointers. `^T` and `&T` can not be cast from an integer and stay allowed.
fn check_raw_ptr(c: *cy.Chunk, type_: *cy.Type, node: *ast.Node) !void {
    var ptr_t = type_;
    if (ptr_t.kind() == .option) {
        ptr_t = ptr_t.cast(.option).child_t;
    }
    if (!ptr_t.isPointer() and !ptr_t.isInstanceOf(c.sema.ptr_span_tmpl)) {
        return;
    }
    // The node's own chunk decides, not `c`: a struct field default such as `PtrSpan.ptr = none` is evaluated
    // under the script chunk that writes the initializer, and core nodes stay exempt.
    const node_chunk = c.compiler.chunks.items[node.src()];
    if (cy.compiler.is_std_module_uri(node_chunk.srcUri)) {
        return;
    }
    const name = try c.sema.allocTypeName(ptr_t);
    defer c.alloc.free(name);
    return c.reportErrorFmt("Raw pointer type `{}` is not allowed. The host disabled raw pointers for this script (`deny_raw_ptrs`).", &.{v(name)}, node);
}

pub fn semaExprNoCheck(c: *cy.Chunk, node: *ast.Node, cstr: Cstr) anyerror!ExprResult {
    if (cy.Trace) {
        const nodeStr = c.encoder.formatTrunc(node);
        log.tracev("expr.{s}: \"{s}\"", .{@tagName(node.type()), nodeStr});
    }

    c.curNode = node;

    if (node.type() == .lambda_cont_expr) {
        c.cur_cont_expr = node.cast(.lambda_cont_expr);
        const child = node.cast(.lambda_cont_expr).child;
        return c.semaExprNoCheck(child, cstr);
    }

    switch (node.type()) {
        .noneLit => {
            const target_t = cstr.target_t orelse {
                return c.reportErrorFmt("Could not determine optional type for `none`.", &.{}, node);
            };
            return c.semaNone(target_t, node);
        },
        .error_lit => {
            const name = node.cast(.error_lit).name.as_name();
            const id = try c.sema.ensureSymbol(name);
            return c.semaConst(@intCast(id), c.sema.error_t, node);
        },
        .dot_lit => {
            const name = node.cast(.dot_lit).as_dot_infer_name();
            if (cstr.target_t) |target_t| {
                if (target_t.kind() == .enum_t) {
                    const case = target_t.cast(.enum_t).getCase(name) orelse {
                        return c.reportErrorFmt("Could not infer `{}` enum case from `{}`.", &.{v(target_t.name()), v(name)}, node);
                    };
                    return c.semaConst(@intCast(case.val), target_t, node);
                }

                if (try c.getResolvedSym(&target_t.sym().head, name, node)) |sym| {
                    return symbol(c, sym, false, node);
                }
            }
            return c.reportErrorFmt("Can not infer symbol from `.{}`.", &.{v(name)}, node);
        },
        .at_lit => {
            const at_name = node.cast(.at_lit).value.slice();
            if (c.semaProcs.items.len > 0) {
                if ((try getResolvedName(c, at_name, node)) != null) {
                    try checkIntrinsicUse(c, node);
                }
            }
            return reportOldSymbolLit(c, at_name, node);
        },
        .void_lit => {
            return c.semaVoid(node);
        },
        .undef_lit => {
            if (cstr.target_t) |target_t| {
                const loc = try c.ir.newExpr(.undef, target_t, node, .{});
                return ExprResult.initOwned(loc);
            } else {
                return c.reportErrorFmt("Can not infer `undef` literal.", &.{}, node);
            }
        },
        .trueLit => {
            return c.semaTrue(node);
        },
        .falseLit => return c.semaFalse(node),
        .floatLit => {
            const literal = node.cast(.floatLit).value.slice();
            if (cstr.target_t) |target_t| {
                if (target_t.id() == bt.F32) {
                    const val = try semaParseFloat(c, f32, literal, node);
                    return c.semaConst32(@bitCast(val), c.sema.f32_t, node);
                }
            }
            const val = try semaParseFloat(c, f64, literal, node);
            return c.semaConst(@bitCast(val), c.sema.f64_t, node);
        },
        .dec_u => {
            // `123u`: an unsigned decimal, stored as its 64-bit pattern.
            const literal = node.cast(.dec_u).asDecU();
            const val = try semaParseInt(c, u64, literal, 10, node);
            return c.semaConst(val, c.sema.i64_t, node);
        },
        .decLit => {
            const literal = node.cast(.decLit).value.slice();
            if (cstr.target_t) |target_t| {
                if (try semaInferSignedLit(c, literal, target_t, 10, node)) |res| {
                    return res;
                }
            }
            // A plain decimal is an `int`, so it must fit in i64. Larger bit patterns need `u`, hex or `r64`.
            const val = try semaParseInt(c, i64, literal, 10, node);
            return c.semaConst(@bitCast(val), c.sema.i64_t, node);
        },
        .binLit => {
            const literal = node.cast(.binLit).asBin();
            if (cstr.target_t) |target_t| {
                if (try semaInferUnsignedLit(c, literal, target_t, 2, node)) |res| {
                    return res;
                }
            }
            const val = try semaParseInt(c, u64, literal, 2, node);
            return c.semaConst(val, c.sema.i64_t, node);
        },
        .octLit => {
            const literal = node.cast(.octLit).asOct();
            if (cstr.target_t) |target_t| {
                if (try semaInferUnsignedLit(c, literal, target_t, 8, node)) |res| {
                    return res;
                }
            }
            const val = try semaParseInt(c, u64, literal, 8, node);
            return c.semaConst(val, c.sema.i64_t, node);
        },
        .hexLit => {
            const literal = node.cast(.hexLit).asHex();
            if (cstr.target_t) |target_t| {
                if (try semaInferUnsignedLit(c, literal, target_t, 16, node)) |res| {
                    return res;
                }
            }
            const val = try semaParseInt(c, u64, literal, 16, node);
            return c.semaConst(val, c.sema.i64_t, node);
        },
        .ident => {
            return try semaIdent(c, cstr, false, node);
        },
        .string_lit => {
            return c.semaStringTarget(node.cast(.string_lit).asString(), cstr.target_t, node);
        },
        .string_multi_lit => return c.semaStringTarget(node.cast(.string_multi_lit).asStringMulti(), cstr.target_t, node),
        .sq_string_lit => {
            return c.semaStringTarget(node.cast(.sq_string_lit).asString(), cstr.target_t, node);
        },
        .sq_string_multi_lit => return c.semaStringTarget(node.cast(.sq_string_multi_lit).asStringMulti(), cstr.target_t, node),
        .raw_string_lit => {
            const lit = node.cast(.raw_string_lit).asRawString();
            if (cstr.target_t) |target_t| {
                if (target_t.isPointer()) {
                    const child_t = target_t.cast(.pointer).child_t;
                    if (child_t.id() == bt.R8 or child_t.id() == bt.I8) {
                        return c.semaRawStringAs(lit, target_t, node);
                    }
                }
            }
            return c.semaRawString(lit, node);
        },
        .raw_string_multi_lit => {
            const lit = node.cast(.raw_string_multi_lit).asRawStringMulti();
            if (cstr.target_t) |target_t| {
                if (target_t.isPointer()) {
                    const child_t = target_t.cast(.pointer).child_t;
                    if (child_t.id() == bt.R8 or child_t.id() == bt.I8) {
                        return c.semaRawStringAs(lit, target_t, node);
                    }
                }
            }
            return c.semaRawString(lit, node);
        },
        .special_string_lit => {
            const special_string = node.cast(.special_string_lit);
            switch (special_string.kind) {
                .ascii_cp => {
                    const cp = try semaStringLitCodepoint(c, special_string.asString(), node);
                    if (cp > 0xFF) {
                        return c.reportError("Expected an ASCII codepoint.", node);
                    }
                    return c.semaConst8(@intCast(cp), c.sema.i8_t, node);
                },
                .unicode_cp => {
                    const cp = try semaStringLitCodepoint(c, special_string.asString(), node);
                    return c.semaConst(cp, c.sema.i64_t, node);
                },
                else => {
                    return c.reportErrorFmt("TODO", &.{}, node);
                },
            }
        },
        .if_expr => {
            const if_expr = node.cast(.if_expr);

            // Turn into if statement that writes to a result local.
            const res_local = try declareHiddenLocal(c, "_temp", cstr.target_t orelse c.sema.void_t, null, node);

            const outer = try pushBlock(c, node);
            {
                const cond = try c.semaExprCstr(if_expr.cond, c.sema.bool_t);

                var target_t: *cy.Type = undefined;
                _ = try pushBlock(c, node);
                {
                    var body: ExprResult = undefined;
                    if (cstr.target_t) |cstr_target_t| {
                        body = try c.semaExprCstr(if_expr.body, cstr_target_t);
                        target_t = cstr_target_t;
                    } else {
                        body = try c.semaExpr(if_expr.body, .{});
                        target_t = body.type;
                        c.varStack.items[res_local.id].inner.local.declIrStart.cast(.declare_local).decl_t = target_t;
                        c.varStack.items[res_local.id].decl_t = target_t;
                    }
                    body = try semaOwn(c, body, if_expr.body);
                    _ = try c.ir.pushStmt(.set_local, if_expr.body, .{
                        .id = @intCast(res_local.ir_id),
                        .right = body.ir,
                    });
                    try semaBreakTo(c, outer, if_expr.body);
                }
                const if_stmts = try popBlock2(c, false);
                _ = try c.ir.pushStmt(.if_block, node, .{
                    .cond_expr = cond.ir,
                    .body_head = if_stmts.first,
                });

                // Else.
                var else_body = try c.semaExprCstr(if_expr.else_expr, target_t);
                else_body = try semaOwn(c, else_body, if_expr.else_expr);
                _ = try c.ir.pushStmt(.set_local, if_expr.else_expr, .{
                    .id = @intCast(res_local.ir_id),
                    .right = else_body.ir,
                });
            }
            const stmts = try popBlock(c);
            _ = try c.ir.pushStmt(.block, node, .{
                .bodyHead = stmts.first,
            });

            const res = (try semaLocal(c, res_local.id, node)).ir;
            c.varStack.items[res_local.id].type = .dead;
            return ExprResult.initOwned(res);
        },
        .as_expr => {
            const as_expr = node.cast(.as_expr);
            var target_t: *cy.Type = undefined;
            if (as_expr.target) |target| {
                target_t = try cte.eval_type2(c, true, target);
            } else {
                target_t = cstr.target_t orelse {
                    return c.reportError("Expected target type for auto cast.", node);
                };
                if (target_t.kind() == .option) {
                    target_t = target_t.cast(.option).child_t;
                } else if (target_t.kind() == .result) {
                    target_t = target_t.cast(.result).child_t;
                }
            }

            const child = try c.semaExprTarget(as_expr.expr, target_t);

            // NOTE: Allow casting to the same type since casting also has the purpose of inferring a literal's type.

            // Compile-time cast.
            if (cy.types.isTypeCompat(c.compiler, child.type, target_t)) {
                return child;
            } else {
                // Casting between distinct types.
                if (child.type.eqUnderlyingType(target_t)) {
                    const child_owned = child.owned;
                    var res = try semaBitcast(c, child, target_t, node);
                    res.owned = child_owned;
                    return res;
                }

                // Pointer cast.
                if (target_t.isPointer()) {
                    if (child.type.isPointer()) {
                        // From another pointer.
                        return semaBitcast(c, child, target_t, node);
                    }
                    if (child.type.isRefPointer()) {
                        // From ref.
                        return semaBitcast(c, child, target_t, node);
                    }
                    if (child.type.kind() == .borrow) {
                        // From borrow.
                        return semaBitcast(c, child, target_t, node);
                    }
                    if (child.type.kind() == .int) {
                        if (child.type.size() == target_t.size()) {
                            // From reinterpreted address.
                            // i64 -> Ptr[T], 64bit
                            // i32 -> Ptr[T], 32bit
                            return sema_bitcast_nocheck(c, child, target_t, node);
                        }
                        if (child.type.size() > target_t.size()) {
                            const sym = try c.getResolvedSymOrFail(&target_t.sym().head, "@init", node);
                            const init_sym = try requireFuncSym(c, sym, node);
                            return c.semaCallFuncSym1(init_sym, as_expr.expr, child, node);
                        }
                    }
                    if (child.type.kind() == .raw) {
                        if (child.type.size() == target_t.size()) {
                            // From reinterpreted address.
                            // r64 -> Ptr[T], 64bit
                            // r32 -> Ptr[T], 32bit
                            return sema_bitcast_nocheck(c, child, target_t, node);
                        }
                        if (child.type.size() > target_t.size()) {
                            const sym = try c.getResolvedSymOrFail(&target_t.sym().head, "@init", node);
                            const init_sym = try requireFuncSym(c, sym, node);
                            return c.semaCallFuncSym1(init_sym, as_expr.expr, child, node);
                        }
                    }

                    if (child.type.kind() == .option) {
                        const option = child.type.cast(.option);
                        if (option.zero_union and option.child_t.isPointer()) {
                            // ?Ptr[S] -> Ptr[T]
                            return semaBitcast(c, child, target_t, node);
                        }
                    }
                }

                if (target_t.kind() == .borrow) {
                    if (child.type.isPointer()) {
                        // Ptr[T] -> &S
                        return semaBitcast(c, child, target_t, node);
                    }
                }

                // Ref cast.
                if (target_t.isRefPointer()) {
                    if (child.type.isPointer()) {
                        var res = try semaBitcast(c, child, target_t, node);
                        // Mark owned to avoid incrementing the ref count on the receiving end.
                        res.owned = true;
                        return res;
                    }
                }

                if (target_t.kind() == .func_ptr) {
                    const target_func_ptr = target_t.cast(.func_ptr);
                    if (target_func_ptr.sig.extern_ and child.type.kind() == .func_ptr and child.type.cast(.func_ptr).sig.extern_) {
                        // @extern fn() -> @extern fn()
                        return semaBitcast(c, child, target_t, node);
                    }
                }

                // Cast to int.
                if (target_t.kind() == .int) {
                    const cast_int_t = target_t.cast(.int);
                    if (cast_int_t.bits == 64) {
                        // Ptr[T] -> i64
                        if (child.type.kind() == .pointer) {
                            if (!child.type.cast(.pointer).ref) {
                                if (target_t.size() > child.type.size()) {
                                    return sema.semaZext(c, target_t, @intCast(child.type.size() * 8), child, node);
                                }
                                return semaBitcast(c, child, target_t, node);
                            }
                        }
                        if (child.type.kind() == .func_ptr) {
                            return semaBitcast(c, child, target_t, node);
                        }
                        if (child.type.kind() == .enum_t) {
                            return semaBitcast(c, child, target_t, node);
                        }
                    }

                    if (child.type.kind() == .int) {
                        // Int[] -> Int[]
                        const sym = try c.getResolvedSymOrFail(&target_t.sym().head, "@init", node);
                        const init_sym = try requireFuncSym(c, sym, node);
                        return c.semaCallFuncSym1(init_sym, as_expr.expr, child, node);
                    }

                    if (child.type.kind() == .float) {
                        // f32/f64 -> Int[]
                        const sym = try c.getResolvedSymOrFail(&target_t.sym().head, "@init", node);
                        const init_sym = try requireFuncSym(c, sym, node);
                        return c.semaCallFuncSym1(init_sym, as_expr.expr, child, node);
                    }

                    // Cast to 8-bit int.
                    if (cast_int_t.bits == 8) {
                        if (child.type.id() == bt.Bool) {
                            return semaBitcast(c, child, target_t, node);
                        }
                    }

                    // // Narrow cast integer.
                    // if (child.type.kind() == .int) {
                    //     const child_int = child.type.cast(.int);
                    //     if (cast_int_t.bits < child_int.bits) {
                    //         const loc = try c.ir.newExpr(.trunc, target_t, node, .{
                    //             .expr = child.ir, .from_bits = @intCast(child_int.bits), .to_bits = @intCast(cast_int_t.bits),
                    //         });
                    //         return ExprResult.init(loc, target_t);
                    //     }
                    // }
                }

                // Cast to raw.
                if (target_t.kind() == .raw) {
                    const target_raw_t = target_t.cast(.raw);
                    if (target_raw_t.bits == 64) {
                        if (child.type.isPointer()) {
                            if (target_t.size() > child.type.size()) {
                                return sema.semaZext(c, target_t, @intCast(child.type.size() * 8), child, node);
                            }
                            return semaBitcast(c, child, target_t, node);
                        }
                        if (child.type.kind() == .func_ptr) {
                            return semaBitcast(c, child, target_t, node);
                        }
                        if (child.type.kind() == .enum_t) {
                            return semaBitcast(c, child, target_t, node);
                        }
                    }

                    if (child.type.kind() == .int) {
                        const int_t = child.type.cast(.int);
                        // Int[] -> Raw[]
                        if (target_raw_t.bits == int_t.bits) {
                            return semaBitcast(c, child, target_t, node);
                        }
                        if (target_raw_t.bits > int_t.bits) {
                            return semaZext(c, target_t, int_t.bits, child, node);
                        }
                        const sym = try c.getResolvedSymOrFail(&target_t.sym().head, "@init", node);
                        const init_sym = try requireFuncSym(c, sym, node);
                        return c.semaCallFuncSym1(init_sym, as_expr.expr, child, node);
                    }
                }

                // Cast to float.
                if (target_t.kind() == .float) {
                    if (child.type.kind() == .int) {
                        // Int[]/UInt[] -> f64
                        const sym = try c.getResolvedSymOrFail(&target_t.sym().head, "@init", node);
                        const init_sym = try requireFuncSym(c, sym, node);
                        return c.semaCallFuncSym1(init_sym, as_expr.expr, child, node);
                    }

                    if (child.type.kind() == .float) {
                        // f64/f32 -> f64
                        const sym = try c.getResolvedSymOrFail(&target_t.sym().head, "@init", node);
                        const init_sym = try requireFuncSym(c, sym, node);
                        return c.semaCallFuncSym1(init_sym, as_expr.expr, child, node);
                    }
                }

                if (target_t.kind() == .struct_t) {
                    if (target_t.isInstanceOf(c.sema.ptr_span_tmpl)) {
                        if (child.type.kind() == .struct_t) {
                            if (child.type.isInstanceOf(c.sema.span_tmpl)) {
                                if (target_t.sym().instance.?.params[0].asPtr(*cy.Type).id() == child.type.sym().instance.?.params[0].asPtr(*cy.Type).id()) {
                                    // [&]T -> PtrSlice[T]
                                    const eff_child = try semaOwn(c, child, node);
                                    return semaBitcast(c, eff_child, target_t, node);
                                }
                            }
                        }
                    } else if (target_t.isInstanceOf(c.sema.span_tmpl)) {
                        if (child.type.kind() == .struct_t) {
                            if (child.type.isInstanceOf(c.sema.ptr_span_tmpl)) {
                                if (target_t.sym().instance.?.params[0].asPtr(*cy.Type).id() == child.type.sym().instance.?.params[0].asPtr(*cy.Type).id()) {
                                    // PtrSlice[T] -> [&]T
                                    const eff_child = try semaOwn(c, child, node);
                                    return semaBitcast(c, eff_child, target_t, node);
                                }
                            }
                        }
                    }
                }
            }

            if (child.type.kind() == .struct_t) {
                return c.reportErrorFmt("Cannot cast a struct type.", &.{}, as_expr.expr);
            }

            // if (child.type.isObject()) {
                // if (target_t.isObjectLike()) {
                //     // Cast `Object` to ref type.
                //     const loc = try c.ir.newExpr(.cast, target_t, node, .{
                //         .type = target_t, .isRtCast = true, .expr = child.ir,
                //     });
                //     return ExprResult.init(loc, target_t);
                // } else {
                //     // Cast `Object` to ref of target type followed by a dereference to unbox.
                //     const final_child = try semaManage(c, child, node);
                //     const ptr_t = try getPtrType(c, target_t);
                //     const loc = try c.ir.newExpr(.cast, ptr_t, node, .{
                //         .type = ptr_t, .isRtCast = true, .expr = final_child.ir,
                //     });
                //     var res = ExprResult.init(loc, ptr_t);
                //     res = try semaDeref(c, res, node);
                //     return res;
                // }
            // } else {
                // Check if it's a down cast (deferred to runtime).
                if (!cy.types.isTypeCompat(c.compiler, target_t, child.type)) {
                    const actTypeName = try c.sema.allocTypeName(child.type);
                    defer c.alloc.free(actTypeName);
                    const expTypeName = try c.sema.allocTypeName(target_t);
                    defer c.alloc.free(expTypeName);
                    return c.reportErrorFmt("Cannot cast `{}` to `{}`.", &.{v(actTypeName), v(expTypeName)}, as_expr.expr);
                }
                const loc = try c.ir.newExpr(.cast, target_t, node, .{
                    .type = target_t, .isRtCast = true, .expr = child.ir,
                });
                return ExprResult.init(loc, target_t);
            // }
        },
        .callExpr => {
            const res = try c.semaCallExpr(node, cstr.target_t);
            if (res.resType == .ct_value) {
                const ct_value = res.data.ct_value;
                defer c.heap.destructValue(ct_value);
                return ct_inline.value(c, ct_value, cstr.target_t, node);
            }
            return res;
        },
        .partial_vector_type => {
            const vector_t = node.cast(.partial_vector_type);
            const sym = try cy.template.expand_template_ast(c, c.sema.partial_vector_tmpl, &.{ vector_t.child, vector_t.n }, node);
            const type_ = sym.getStaticType().?;
            _ = type_;
            return c.reportError("Compile-time type cannot be used here. Consider using the `MetaType` initializer.", node);
        },
        .vector_type => {
            const vector_t = node.cast(.vector_type);
            const sym = try cy.template.expand_template_ast(c, c.sema.vector_tmpl, &.{ vector_t.child, vector_t.n }, node);
            const type_ = sym.getStaticType().?;
            _ = type_;
            return c.reportError("Compile-time type cannot be used here. Consider using the `MetaType` initializer.", node);
        },
        .slice_type => { 
            const slice_type = node.cast(.slice_type);
            const sym = try cy.template.expand_template_ast(c, c.sema.slice_tmpl, &.{slice_type.child}, node);
            const type_ = sym.getStaticType().?;
            _ = type_;
            return c.reportError("Compile-time type cannot be used here. Consider using the `MetaType` initializer.", node);
        },
        .option_type => { 
            const sym = try cy.template.expand_template_ast(c, c.sema.option_tmpl, &.{node.cast(.option_type).child}, node);
            const type_ = sym.getStaticType().?;
            _ = type_;
            return c.reportError("Compile-time type cannot be used here. Consider using the `MetaType` initializer.", node);
        },
        .fn_type => {
            const func_type = node.cast(.fn_type);
            const sig = try sema_type.resolveFuncType(c, func_type);
            const type_ = try getFuncPtrType(c, sig);
            _ = type_;
            return c.reportError("Compile-time type cannot be used here. Consider using the `MetaType` initializer.", node);
        },
        .accessExpr => {
            return semaAccessExpr(c, node.cast(.accessExpr), false, cstr.target_t);
        },
        .unwrap_choice => {
            const unwrap = node.cast(.unwrap_choice);
            var choice = try c.semaExpr(unwrap.left, .{});
            if (choice.type.kind() == .choice) {
                choice = try semaEnsureAddressable(c, choice, unwrap.left);

                const choice_t = choice.type.cast(.choice);
                const name = unwrap.right.as_name();
                const case = choice_t.getCase(name) orelse {
                    return c.reportErrorFmt("Choice case `{}` does not exist.", &.{v(name)}, unwrap.right);
                };

                const choice_ptr_t = try getPtrType(c, choice.type);
                const addr = try semaAddressOf(c, choice, choice_ptr_t, node);
                const ptr_t = try getPtrType(c, case.payload_t);
                const loc = try c.ir.newExpr(.unwrap_addr, ptr_t, node, .{
                    .choice = addr.ir,
                    .tag = @intCast(case.val),
                });
                var ptr = ExprResult.init(loc, ptr_t);
                ptr.addressable = choice.addressable;
                ptr.data.value.parent_local = choice.recParentLocal();
                return semaDeref(c, ptr, node);
            }
            if (choice.type.kind() == .pointer) {
                const pointer = choice.type.cast(.pointer);
                if (pointer.child_t.kind() == .choice) {
                    choice = try semaManage(c, choice, unwrap.left);
                    const choice_t = pointer.child_t.cast(.choice);
                    const name = unwrap.right.as_name();
                    const case = choice_t.getCase(name) orelse {
                        return c.reportErrorFmt("Choice case `{}` does not exist.", &.{v(name)}, unwrap.right);
                    };
                    const ptr_t = try getPtrType(c, case.payload_t);

                    const loc = try c.ir.newExpr(.unwrap_addr, ptr_t, node, .{
                        .choice = choice.ir,
                        .tag = @intCast(case.val),
                    });
                    var ptr = ExprResult.init2(loc);
                    ptr.addressable = choice.addressable;
                    ptr.data.value.parent_local = choice.recParentLocal();
                    return semaDeref(c, ptr, node);
                }
            }
            return c.reportErrorFmt("Expected choice type. Found `{}`.", &.{v(choice.type.name())}, unwrap.left);
        },
        .unwrap => {
            const unwrap = node.cast(.unwrap);
            var opt = try c.sema_expr_cstr_template(unwrap.opt, c.sema.option_tmpl);
            const owned = opt.owned;
            opt = try semaEnsureAddressable(c, opt, unwrap.opt);
            const payload_t = opt.type.cast(.option).child_t;

            if (opt.type.cast(.option).zero_union) {
                const expr = try c.ir.newExpr(.unwrap_nz, payload_t, node, .{
                    .option = opt.ir,
                });
                var res = ExprResult.init2(expr);
                res.addressable = opt.addressable;
                return res;
            } else {
                const opt_ptr_t = try getPtrType(c, opt.type);
                const addr = try semaAddressOf(c, opt, opt_ptr_t, node);

                const ptr_t = try getPtrType(c, payload_t);
                const loc = try c.ir.newExpr(.unwrap_addr, ptr_t, node, .{
                    .choice = addr.ir,
                    .tag = 1,
                });
                var ptr = ExprResult.init2(loc);
                ptr.addressable = opt.addressable;
                ptr.data.value.parent_local = opt.recParentLocal();

                var res = try semaDeref(c, ptr, node);
                if (owned) {
                    // Consume from option container.
                    const owner = res.data.value.parent_local.?;
                    c.varStack.items[owner].type = .dead;
                    res.owned = true;
                }
                return res;
            }
        },
        .unwrap_res => {
            const unwrap_res = node.cast(.unwrap_res);
            var res_expr = try c.sema_expr_cstr_template(unwrap_res.res, c.sema.result_tmpl);
            const owned = res_expr.owned;
            res_expr = try semaEnsureAddressable(c, res_expr, unwrap_res.res);

            const borrow_t = try getBorrowType(c, res_expr.type);
            const res_addr = try semaAddressOf(c, res_expr, borrow_t, unwrap_res.res);
            const res_local = try declareHiddenLocal(c, "_res_addr", borrow_t, res_addr, node);
            const res = try semaLocal(c, res_local.id, node);
            const cond = try c.semaIsError(res, node);

            // Push error branch.
            _ = try pushBlock(c, node);
            {
                const proc = c.proc();
                if (proc.try_ctx) |try_ctx| {
                    // Inside a `try` block: hand the error to the `else` block instead of leaving the proc.
                    const err = try semaUnwrapResultErrorNoCheck(c, res, node);
                    const err_local = &c.varStack.items[try_ctx.err_local];
                    _ = try c.ir.pushStmt(.set_local, node, .{
                        .id = @intCast(err_local.inner.local.id),
                        .right = err.ir,
                    });
                    try semaBreakTo(c, try_ctx.body_block, node);
                } else if (proc.func != null) {
                    const ret_t = proc.getReturnType(c.sema);
                    if (ret_t.id() == bt.Error) {
                        const err = try semaUnwrapResultErrorNoCheck(c, res, node);
                        try semaReturnExpr(c, err, node);
                    } else if (ret_t.kind() == .result) {
                        const err = try semaUnwrapResultErrorNoCheck(c, res, node);
                        const ret = try semaInitChoice(c, ret_t, 0, 0, err, node);
                        try semaReturnExpr(c, ret, node);
                    } else {
                        return c.reportErrorFmt("Expected `Result` or `error` return type for enclosing function.", &.{}, node);
                    }
                } else {
                    // Panic.
                    const err = try semaUnwrapResultErrorNoCheck(c, res, node); 
                    const arg = Argument.initPreResolved(node, err);
                    const call = try c.semaCallFunc2(c.sema.panic_unwrap_error_fn, &.{arg}, &.{}, node);
                    _ = try declareHiddenLocal(c, "_res", c.sema.void_t, call, node);
                }
            }
            const block = try popBlock2(c, false);
            _ = try c.ir.pushStmt(.if_block, node, .{
                .cond_expr = cond.ir,
                .body_head = block.first,
            });

            var unwrap = try semaUnwrapResultNoCheck(c, res, node);
            unwrap.data.value_field.parent_local = res_expr.recParentLocal();
            if (owned) {
                // Move from Result container if initially owned.
                const owner = unwrap.data.value_field.parent_local.?;
                c.varStack.items[owner].type = .dead;
                unwrap.owned = true;
            }
            return unwrap;
        },
        .unwrap_res_or => {
            const unwrap = node.cast(.unwrap_res_or);

            var res = try c.sema_expr_cstr_template(unwrap.res, c.sema.result_tmpl);
            res = try semaEnsureAddressable(c, res, unwrap.res);

            const payload_t = res.type.cast(.result).child_t;
            const dst_local = try declareHiddenLocal(c, "_temp", payload_t, null, node);
            const cond = try c.semaIsError(res, node);

            const outer = try pushBlock(c, node);
            {
                // Push error branch.
                _ = try pushBlock(c, node);
                {
                    const else_body = try c.semaExprCstr(unwrap.default, payload_t);
                    _ = try c.ir.pushStmt(.set_local, unwrap.default, .{
                        .id = @intCast(dst_local.ir_id),
                        .right = else_body.ir,
                    });
                    try semaBreakTo(c, outer, unwrap.default);
                }
                const stmts = try popBlock2(c, false);
                _ = try c.ir.pushStmt(.if_block, node, .{
                    .cond_expr = cond.ir,
                    .body_head = stmts.first,
                });

                // Else result branch.
                var unwrap_res = try semaUnwrapResultNoCheck(c, res, node);
                unwrap_res = try sema_copy(c, unwrap_res, node);
                _ = try c.ir.pushStmt(.set_local, unwrap.res, .{
                    .id = @intCast(dst_local.ir_id),
                    .right = unwrap_res.ir,
                });
            }
            const stmts = try popBlock(c);
            _ = try c.ir.pushStmt(.block, node, .{
                .bodyHead = stmts.first,
            });

            const ret = (try semaLocal(c, dst_local.id, node)).ir;
            c.varStack.items[dst_local.id].type = .dead;
            return ExprResult.initOwned(ret);
        },
        .unwrap_res_or_block => {
            const unwrap = node.cast(.unwrap_res_or_block);

            var res = try c.sema_expr_cstr_template(unwrap.res, c.sema.result_tmpl);
            res = try semaEnsureAddressable(c, res, unwrap.res);

            const payload_t = res.type.cast(.result).child_t;
            const dst_local = try declareHiddenLocal(c, "_temp", payload_t, null, node);

            // NOTE: Prevent else block from releasing a uninited local.
            c.varStack.items[dst_local.id].type = .dead;
            const cond = try c.semaIsError(res, node);

            // Push error branch.
            _ = try pushBlock(c, node);
            {
                if (unwrap.capture) |capture| {
                    var err_name: []const u8 = undefined;
                    if (capture.type() == .ident) {
                        err_name = capture.cast(.ident).name.slice();
                    } else {
                        return c.reportErrorFmt("Unsupported error variable: {}", &.{v(capture.type())}, capture);
                    }

                    var capture_init = try semaUnwrapResultErrorNoCheck(c, res, capture);
                    capture_init = try sema_copy(c, capture_init, capture);
                    _ = try declareLocalInit(c, err_name, c.sema.error_t, capture_init, capture);
                }
                try semaStmts(c, unwrap.else_stmts);
                if (c.block().endReachable) {
                    return c.reportError("Expected unreachable block end.", node);
                }
            }
            const stmts = try popBlock2(c, false);
            _ = try c.ir.pushStmt(.if_block, node, .{
                .cond_expr = cond.ir,
                .body_head = stmts.first,
            });

            // Push result branch.
            var unwrap_res = try semaUnwrapResultNoCheck(c, res, node);
            unwrap_res = try sema_copy(c, unwrap_res, node);
            _ = try c.ir.pushStmt(.set_local, unwrap.res, .{
                .id = @intCast(dst_local.ir_id),
                .right = unwrap_res.ir,
            });

            c.varStack.items[dst_local.id].type = .local;
            const ret = (try semaLocal(c, dst_local.id, node)).ir;
            c.varStack.items[dst_local.id].type = .dead;
            return ExprResult.initOwned(ret);
        },
        .unwrap_or => {
            const unwrap = node.cast(.unwrap_or);

            var opt = try c.sema_expr_cstr_template(unwrap.opt, c.sema.option_tmpl);
            opt = try semaEnsureAddressable(c, opt, unwrap.opt);

            const payload_t = opt.type.cast(.option).child_t;
            const res_local = try declareHiddenLocal(c, "_temp", payload_t, null, node);

            // NOTE: Prevent else block from releasing a uninited local.
            c.varStack.items[res_local.id].type = .dead;

            const outer = try pushBlock(c, node);
            {
                try semaUnwrapOrStmt(c, opt, res_local.ir_id, outer, unwrap.opt);

                // Else.
                var else_body = try c.semaExprCstr(unwrap.default, payload_t);
                else_body = try semaOwn(c, else_body, unwrap.default);
                _ = try c.ir.pushStmt(.set_local, unwrap.default, .{
                    .id = @intCast(res_local.ir_id),
                    .right = else_body.ir,
                });
            }
            const block = try popBlock(c);
            _ = try c.ir.pushStmt(.block, node, .{
                .bodyHead = block.first,
            });

            c.varStack.items[res_local.id].type = .local;
            const expr = (try semaLocal(c, res_local.id, node)).ir;
            // Move to return.
            c.varStack.items[res_local.id].type = .dead;
            return ExprResult.initOwned(expr);
        },
        .unwrap_or_block => {
            const unwrap = node.cast(.unwrap_or_block);

            var opt = try c.sema_expr_cstr_template(unwrap.opt, c.sema.option_tmpl);
            opt = try semaEnsureAddressable(c, opt, unwrap.opt);

            const payload_t = opt.type.cast(.option).child_t;
            const res_local = try declareHiddenLocal(c, "_unwrap_res", payload_t, null, node);

            // NOTE: Prevent else block from releasing a uninited local.
            c.varStack.items[res_local.id].type = .dead;

            const outer = try pushBlock(c, node);
            {
                try semaUnwrapOrStmt(c, opt, res_local.ir_id, outer, unwrap.opt);

                // Else.
                try semaStmts(c, unwrap.else_stmts);
                if (c.block().endReachable) {
                    return c.reportError("Expected unreachable block end.", node);
                }
            }
            const block = try popBlock(c);
            _ = try c.ir.pushStmt(.block, node, .{
                .bodyHead = block.first,
            });

            c.varStack.items[res_local.id].type = .local;
            const res = (try semaLocal(c, res_local.id, node)).ir;
            c.varStack.items[res_local.id].type = .dead;
            return ExprResult.initOwned(res);
        },
        .expand_lit => {
            const expand_lit = node.cast(.expand_lit);
            const val = try cte.eval(c, expand_lit.child);
            defer c.heap.destructValue(val);
            return ct_inline.value(c, val, cstr.target_t, expand_lit.child);
        },
        .range => {
            const range = node.cast(.range);
            // `a..`, `..b` and `..` are only slice bounds.
            const end = range.end orelse {
                return c.reportError("Expected range end. A range without an end is only allowed as a slice index.", node);
            };
            const start = range.start orelse {
                return c.reportError("Expected range start. A range without a start is only allowed as a slice index.", node);
            };

            var b: InitBuilder = .{ .c = c };
            try b.begin(c.sema.range_t, 2, node);

            const start_res = try c.semaExprCstr(start, c.sema.i64_t);
            try b.pushArg(start_res, start);

            const end_res = try c.semaExprCstr(end, c.sema.i64_t);
            try b.pushArg(end_res, end);

            const loc = b.end();
            return ExprResult.init(loc, c.sema.range_t);
        },
        .binExpr => {
            const bin_expr = node.cast(.binExpr);
            return try c.semaBinExpr(cstr, bin_expr.left, bin_expr.op, bin_expr.right, node);
        },
        .unary_expr => {
            return try c.semaUnExpr(node.cast(.unary_expr), cstr);
        },
        .borrow => {
            return try c.semaBorrowOrType(node, cstr);
        },
        .ex_borrow => {
            return try sema_ex_borrow_or_type(c, node, cstr);
        },
        .ref => {
            return try c.semaRefOrType(node, cstr);
        },
        .ptr => {
            return try c.semaPtrOrType(node, cstr);
        },
        .deref => {
            const deref = node.cast(.deref);

            var left = try c.semaExpr(deref.left, .{});
            left = try semaManage(c, left, deref.left);

            var child_t: *cy.Type = undefined;
            if (left.type.kind() == .pointer) {
                child_t = left.type.cast(.pointer).child_t;
            } else if (left.type.kind() == .borrow) {
                child_t = left.type.cast(.borrow).child_t;
            } else {
                const name = try c.sema.allocTypeName(left.type);
                defer c.alloc.free(name);
                return c.reportErrorFmt("Expected reference type, found `{}`.", &.{v(name)}, node);
            }
            return semaDeref(c, left, node);
        },
        .init_lit => {
            if (cstr.target_t) |target_t| {
                const init_lit = node.cast(.init_lit);

                if (target_t.kind() == .option) {
                    const option = target_t.cast(.option);
                    const payload = try semaInitLitTarget(c, init_lit, option.child_t, cstr.return_infer_error, cstr.assign_to_local);
                    const tag = try c.semaConst(1, c.sema.i64_t, node);
                    return semaInit2(c, target_t, tag, payload, node);
                } else {
                    return semaInitLitTarget(c, init_lit, target_t, cstr.return_infer_error, cstr.assign_to_local);
                }
            }

            // TODO: Infer tuple type. Previously this initialized slices and maps.
            return c.reportErrorFmt("TODO: infer tuple type", &.{}, node);

            // const init_lit = node.cast(.init_lit);
            // if (init_lit.array_like) {
            //     if (init_lit.args.len == 0) {
            //         return c.reportError("Expected array type or at least one element.", node);
            //     }

            //     // Infer list type from the first element.
            //     const args = try c.ir.allocArray(*ir.Expr, init_lit.args.len);
            //     var arg_res = try c.semaExpr(init_lit.args.ptr[0], .{});
            //     arg_res = try semaOwn(c, arg_res, init_lit.args.ptr[0]);
            //     args[0] = arg_res.ir;

            //     // Constrain rest of elements to the type of the first element.
            //     const elem_t = arg_res.type;
            //     for (init_lit.args.slice()[1..], 1..) |arg, i| {
            //         arg_res = try c.semaExprCstr(arg, elem_t);
            //         arg_res = try semaOwn(c, arg_res, arg);
            //         args[i] = arg_res.ir;
            //     }

            //     const slice_t = try get_slice_type(c, elem_t);
            //     const init_seq = (try c.getResolvedSym(@ptrCast(slice_t.sym()), "@init_sequence", node)).?;

            //     return sema_init_seq2(c, init_seq, args, node);
            // } else {
            //     // Assume at least one key/value pair.
            //     // Infer map type from the first pair.
            //     const pairs = try c.ir.allocArray(*ir.Expr, init_lit.args.len);
            //     const first_pair = init_lit.args.ptr[0];
            //     if (first_pair.type() != .keyValue) {
            //         return c.reportError("Expected key value pair.", first_pair);
            //     }
            //     var kv = first_pair.cast(.keyValue);
            //     var key: ExprResult = undefined;
            //     if (kv.key.type() == .ident) {
            //         key = try c.semaString(kv.key.cast(.ident).name.slice(), kv.key);
            //     } else {
            //         key = try c.semaExpr(kv.key, .{});
            //     }
            //     var val = try c.semaExpr(kv.value, .{});
                
            //     const key_t = key.type;
            //     const val_t = val.type;
            //     const map_t = try getMapType(c, key_t, val_t);
            //     const init_record = (try c.getResolvedSym(@ptrCast(map_t.sym()), "@init_record", @ptrCast(init_lit))).?;
            //     const init_record_func = try requireFuncSym(c, init_record, node);
            //     const span_t = init_record_func.first.sig.params_ptr[0].get_type();
            //     if (!span_t.isInstanceOf(c.sema.span_tmpl)) {
            //         return c.reportError("Expected `[&]T` function parameter in `@init_record`.", node);
            //     }
            //     const pair_t = span_t.sym().instance.?.params[0].asPtr(*cy.Type);
            //     const pair_borrow_t = try getBorrowType(c, pair_t);

            //     var pair = try semaInitPair(c, pair_t, key, val, first_pair);
            //     pairs[0] = pair.ir;

            //     for (init_lit.args.slice()[1..], 1..) |arg, i| {
            //         kv = arg.cast(.keyValue);
            //         if (kv.key.type() == .ident) {
            //             key = try c.semaString(kv.key.cast(.ident).name.slice(), kv.key);
            //         } else {
            //             key = try c.semaExprCstr(kv.key, key_t);
            //             key = try semaOwn(c, key, kv.key);
            //         }
            //         val = try c.semaExprCstr(kv.value, val_t);
            //         val = try semaOwn(c, val, kv.value);
            //         pair = try semaInitPair(c, pair_t, key, val, arg);
            //         pairs[i] = pair.ir;
            //     }
            //     return sema_call_init_span(c, init_record_func, span_t, pair_borrow_t, pair_t, pairs, node);
            // }
        },
        .stringt => {
            const template = node.cast(.stringt);
            return semaStringTemplate(c, template);
        },
        .stringt_multi => {
            const template = node.cast(.stringt_multi);
            return semaStringTemplate(c, template);
        },
        .group => {
            const child = node.cast(.group).child;
            return c.semaExpr(child, cstr);
        },
        .lambda_expr => {
            const lambda = node.cast(.lambda_expr);

            if (try inferLambdaFuncSig(c, lambda.sig_t, cstr.target_t, node)) |sig| {
                const func = try c.addUserLambda(@ptrCast(c.sym), @ptrCast(lambda));
                _ = try pushLambdaProc(c, func);

                // Generate function body.
                try c.resolveUserLambda(func, sig);
                try appendFuncParamVars(c, lambda.params, sig.params());

                _ = try semaReturnExprStmt(c, lambda.expr, func.sig.ret, lambda.expr);

                const lambda_ir = try popLambdaProc(c);
                return ExprResult.initOwned(lambda_ir);
            } else {
                const start = c.func_param_stack.items.len;
                defer c.func_param_stack.items.len = start;
                try pushLambdaFuncParams(c, lambda.params);

                const func = try c.addUserLambda(@ptrCast(c.sym), @ptrCast(lambda));
                _ = try pushLambdaProc(c, func);

                // Generate function body.
                const params = c.func_param_stack.items[start..];
                try appendFuncParamVars(c, lambda.params, params);

                var func_ret_t: *cy.Type = undefined;
                if (lambda.ret == null) {
                    // Infer return type.
                    func_ret_t = try semaReturnExprStmt(c, lambda.expr, null, lambda.expr);
                } else {
                    func_ret_t = try sema_type.resolveReturnType(c, lambda.ret);
                    _ = try semaReturnExprStmt(c, lambda.expr, func_ret_t, lambda.expr);
                }

                const sig = try c.sema.ensureFuncSig(@ptrCast(params), func_ret_t);
                try c.resolveUserLambda(func, sig);

                const lambda_ir = try popLambdaProc(c);
                return ExprResult.initOwned(lambda_ir);
            }
        },
        .lambda_cont => {
            const lambda = node.cast(.lambda_cont);
            const cont_expr = c.cur_cont_expr orelse {
                return c.reportError("Expected lambda body.", node);
            };
            return semaLambdaMulti(c, lambda, cont_expr.stmts, cstr);
        },
        .lambda_multi => {
            const lambda = node.cast(.lambda_multi);
            return semaLambdaMulti(c, lambda, lambda.stmts, cstr);
        },
        .init_expr => {
            return c.semaInitExpr(node.cast(.init_expr), cstr);
        },
        .index_expr => {
            const index_expr = node.cast(.index_expr);
            var left = try c.semaExprSkipSym(index_expr.left, .{});
            if (left.resType == .sym) {
                if (left.data.sym.type == .template) {
                    const template = left.data.sym.cast(.template);
                    const final_sym = try cy.template.expand_template_ast(c, template, index_expr.args.slice(), node);
                    return sema.symbol(c, final_sym, false, node);
                } else if (left.data.sym.type == .func_template) {
                    const template = left.data.sym.cast(.func_template);
                    const func_res = try cy.template.expandTemplateFuncForArgs(c, template, index_expr.args.slice(), node);
                    const typeId = try cy.sema.getFuncPtrType(c, func_res.sig);
                    func_res.info.escaped = true;
                    const loc = try c.ir.newExpr(.func_ptr, typeId, node, .{ .func = func_res });
                    return ExprResult.initCustom(loc, .func, typeId, .{ .func = func_res });
                } else {
                    left = try sema.symbol(c, left.data.sym, false, node);
                }
            }
            return semaIndexExpr(c, index_expr.left, left, cstr, node);
        },
        .switchExpr => { 
            return semaSwitchExpr(c, node.cast(.switchExpr), .{
                .target_t = cstr.target_t,
                .reqTypeCstr = cstr.reqTypeCstr,
            });
        },
        .fiber_expr => {
            return semaFiberExpr(c, node);
        },
        .move_expr => {
            const child = node.cast(.move_expr).expr;
            var res = try semaExpr(c, child, .{});
            const field_access = try build_move_access_path(c, res, child);

            // Can only move if owner was declared in the same block.
            if (c.temp_access_path.var_id < c.block().varStart) {
                return c.reportError("Can only move variable declared in the same block.", child);
            }

            const local = &c.varStack.items[c.temp_access_path.var_id];
            if (local.inner.local.isParam and local.decl_t.isObjectLike()) {
                return c.reportError("Cannot move a reference parameter.", child);
            }

            if (!field_access) {
                // move owner.
                if (local.has_inactive_struct_fields) {
                    return c.reportError("Cannot move a partially moved value.", child);
                }
                res.owned = true;
                local.type = .dead;
                return res;
            }

            // move member.
            const state_res = try c.proc().var_active_struct_fields.getOrPut(c.alloc, c.temp_access_path.var_id);
            if (!state_res.found_existing) {
                const start = c.active_field_stack.items.len;
                const state_len = local.decl_t.cast(.struct_t).field_state_len;
                try c.active_field_stack.ensureUnusedCapacity(c.alloc, state_len);
                c.active_field_stack.items.len += state_len;
                const fields = c.active_field_stack.items[start..];
                @memset(fields, true);
                state_res.value_ptr.* = fields;
                local.has_inactive_struct_fields = true;
            }
            const start = c.temp_access_path.struct_field_offset;
            @memset(state_res.value_ptr.*[start..start + c.temp_access_path.state_len], false);

            res.owned = true;
            return res;
        },
        else => {
            return c.reportErrorFmt("Unsupported node: {}", &.{v(node.type())}, node);
        },
    }
}

const EmbeddedResult = struct {
    field_idx: usize,
    embedded_t: *cy.Type,
    sym: *cy.Sym,
};

fn get_embedded_sym(c: *cy.Chunk, rec_t: *cy.types.Struct, name: []const u8, node: *ast.Node) !?EmbeddedResult {
    const fields = rec_t.getEmbeddedFields();
    for (fields) |field| {
        if (try c.getResolvedSym(&field.embedded_type.sym().head, name, node)) |embedded_sym| {
            // TODO: Cache result into the receiver type's module as a `EmbeddedField`.
            return .{
                .field_idx = field.field_idx,
                .embedded_t = field.embedded_type,
                .sym = embedded_sym,
            };
        }
    }
    return null;
}

/// `fiber f(a, b)` is the call `@new_fiber(f, {a, b})` of the core module: the arguments are evaluated now
/// and `f` is called at the first `resume`.
fn semaFiberExpr(c: *cy.Chunk, node: *ast.Node) !ExprResult {
    const child = node.cast(.fiber_expr).child;
    if (child.type() == .lambda_multi) {
        // `fiber:` is `@new_fiber_block(fn(): body)`. The body is a closure, so it captures `^T` variables only.
        const tree = &c.parser.ast;
        const name = "@new_fiber_block";
        const callee = try tree.newNode(.at_lit, .{
            .src = node.src(),
            .pos = node.pos(),
            .value = .{ .ptr = name.ptr, .len = name.len },
        });
        c.internal_callee = @ptrCast(callee);
        const new_args = try tree.dupeNodes(&.{child});
        const new_call = try tree.newNode(.callExpr, .{
            .callee = @ptrCast(callee),
            .args = .{ .ptr = new_args.ptr, .len = new_args.len },
            .hasNamedArg = false,
            .end = child.end(),
        });
        c.updateAstView(tree.view());
        return semaExpr(c, @ptrCast(new_call), .{});
    }
    const call = child.cast(.callExpr);

    if (call.callee.type() == .accessExpr) {
        // `fiber obj.work()` has no place for the receiver. Name the method through its type instead.
        const access = call.callee.cast(.accessExpr);
        if (access.left.type() == .ident) {
            const left = try c.semaExprSkipSym(access.left, .{});
            if (left.resType != .sym) {
                if (try c.accessResolvedSym(left.type, access.right.as_name(), access.right)) |sym| {
                    if (sym.type == .func) {
                        return c.reportErrorFmt("A fiber entry cannot be a method call on a value. Pass the receiver as the first argument: `fiber T.{}(obj)`.", &.{v(sym.name())}, node);
                    }
                }
            }
        }
    }

    // Report the role and lifetime rules at the `fiber` expression instead of inside `@new_fiber`.
    // A path (`T.method`, `mod.func`) is checked too: a `&T` receiver is a borrow like any parameter.
    if (call.callee.type() == .ident or call.callee.type() == .accessExpr) {
        const callee_res = try c.semaExpr(call.callee, .{});
        const opt_sig: ?*cy.FuncSig = switch (callee_res.type.kind()) {
            .func_ptr => callee_res.type.cast(.func_ptr).sig,
            .func_sym => callee_res.type.cast(.func_sym).sig,
            else => null,
        };
        if (opt_sig) |sig| {
            if (sig.ret.kind() == .pointer and sig.ret.cast(.pointer).child_t.isInstanceOf(c.sema.generator_tmpl)) {
                return c.reportError("A generator cannot be a fiber entry.", node);
            }
            if (sig.ret.id() != bt.Void) {
                return c.reportError("A fiber entry function must return `void`.", node);
            }
            for (sig.params()) |param| {
                const param_t = param.get_type();
                if (param_t.info.borrow_only) {
                    // The fiber's stack moves when it grows, and the resumer's frame can be gone at the next resume.
                    const type_name = try c.sema.allocTypeName(param_t);
                    defer c.alloc.free(type_name);
                    return c.reportErrorFmt("Cannot borrow a stack value across fibers. The parameter type is `{}`. Use `^T`.", &.{v(type_name)}, node);
                }
            }
        }
    }

    const tree = &c.parser.ast;
    const name = "@new_fiber";
    const callee = try tree.newNode(.at_lit, .{
        .src = node.src(),
        .pos = node.pos(),
        .value = .{ .ptr = name.ptr, .len = name.len },
    });
    const args_lit = try tree.newNode(.init_lit, .{
        .args = call.args,
        .src = node.src(),
        .pos = call.callee.end(),
        .end = call.end,
        .array_like = true,
    });
    c.internal_callee = @ptrCast(callee);
    const new_args = try tree.dupeNodes(&.{ call.callee, @ptrCast(args_lit) });
    const new_call = try tree.newNode(.callExpr, .{
        .callee = @ptrCast(callee),
        .args = .{ .ptr = new_args.ptr, .len = new_args.len },
        .hasNamedArg = false,
        .end = call.end,
    });
    c.updateAstView(tree.view());
    return semaExpr(c, @ptrCast(new_call), .{});
}

pub fn semaCallExpr(c: *cy.Chunk, node: *ast.Node, opt_target: ?*cy.Type) !ExprResult {
    const call = node.cast(.callExpr);
    if (call.hasNamedArg) {
        return c.reportErrorFmt("Unsupported named args.", &.{}, node);
    }

    if (call.callee.type() == .accessExpr) {
        const callee = call.callee.cast(.accessExpr);
        var leftRes = try c.semaExprSkipSym(callee.left, .{});

        const right_name = callee.right.as_name();
        if (leftRes.resType == .sym) {
            const leftSym = leftRes.data.sym;

            if (leftSym.type == .func) {
                return c.reportErrorFmt("Can not access function symbol `{}`.", &.{v(leftSym.name())}, callee.right);
            }

            if (leftSym.isValue()) {
                // Look for sym under left type's module.
                const rightSym = (try c.accessResolvedSym(leftRes.type, right_name, callee.right)) orelse b: {
                    if (leftRes.type.has_embeddings()) {
                        if (try get_embedded_sym(c, leftRes.type.cast(.struct_t), right_name, callee.right)) |embedded_res| {
                            leftRes = try semaField(c, leftRes, callee.right, embedded_res.field_idx, embedded_res.embedded_t, callee.right);
                            break :b embedded_res.sym;
                        }
                    }
                    const type_name = try c.sema.allocTypeName(leftRes.type);
                    defer c.alloc.free(type_name);
                    return c.reportErrorFmt("Can not find the symbol `{}` in `{}`.", &.{v(right_name), v(type_name)}, callee.right);
                };

                if (rightSym.type == .func) {
                    // Call method.
                    const func_sym = rightSym.cast(.func);
                    const recv = try sema.symbol(c, leftSym, true, callee.left);
                    return c.semaCallFuncSymRec(func_sym, callee.left, recv, call.args.slice(), false, node);
                } else if (rightSym.type == .field) {
                    // Call field value.
                    const field = rightSym.cast(.field);
                    const recv = try sema.symbol(c, leftSym, true, callee.left);
                    const callee_v = try semaField(c, recv, callee.left, field.idx, field.type, callee.right);
                    return c.semaCallValue(callee_v, call.callee, call.args.slice(), callee.right);
                } else {
                    return c.reportErrorFmt("Can not call symbol `{}`.", &.{v(rightSym.type)}, callee.right);
                }
            } else {
                // Look for sym under left module.
                const rightSym = try c.getResolvedSymOrFail(leftSym, right_name, callee.right);

                return try callSym(c, rightSym, callee.right, call.args.slice(), false, node);
            }
        } else {
            // Look for sym under left type's module.
            const rightSym = (try c.accessResolvedSym(leftRes.type, right_name, callee.right)) orelse b: {
                if (leftRes.type.has_embeddings()) {
                    if (try get_embedded_sym(c, leftRes.type.cast(.struct_t), right_name, callee.right)) |embedded_res| {
                        leftRes = try semaField(c, leftRes, callee.right, embedded_res.field_idx, embedded_res.embedded_t, callee.right);
                        break :b embedded_res.sym;
                    }
                }
                const type_name = try c.sema.allocTypeName(leftRes.type);
                defer c.alloc.free(type_name);
                return c.reportErrorFmt("Can not find the symbol `{}` in `{}`.", &.{v(right_name), v(type_name)}, callee.right);
            };

            if (rightSym.type == .func) {
                return c.semaCallFuncSymRec(rightSym.cast(.func), callee.left, leftRes, call.args.slice(), false, node);
            } else if (rightSym.type == .func_template) {
                // const template = rightSym.cast(.func_template);
                // if (template.callable) {
                //     return c.semaCallGenericFuncRec(template, callee.left, leftRes, call.args, node);
                // } else {
                    return c.reportErrorFmt("Function template must be expanded first.", &.{v(right_name)}, callee.left);
                // }
            } else {
                const callee_v = try c.semaExpr(call.callee, .{});
                return c.semaCallValue(callee_v, call.callee, call.args.slice(), callee.right);
            }
        }
    } else if (call.callee.type() == .dot) {
        const target_t = opt_target orelse {
            return c.reportError("Cannot infer `@init` function.", node);
        };
        const sym = try c.getResolvedSymOrFail(&target_t.sym().head, "@init", node);
        const init_sym = try requireFuncSym(c, sym, node);
        return c.semaCallFuncSym(init_sym, call.args.slice(), false, node);
    } else if (call.callee.type() == .ident or call.callee.type() == .at_lit) {
        const name = call.callee.as_name();
        const varRes = try lookupIdent(c, name, call.callee);
        if (call.callee.type() == .at_lit and varRes == .static) {
            try checkIntrinsicUse(c, call.callee);
        }
        switch (varRes) {
            .local => {
                const calleeRes = try c.semaExpr(call.callee, .{});
                return c.semaCallValue(calleeRes, call.callee, call.args.slice(), node);
            },
            .capture => |idx| {
                var callee = try semaCaptured(c, idx, node);
                callee = try semaOwn(c, callee, node);
                return c.semaCallValue(callee, call.callee, call.args.slice(), node);
            },
            .static => |sym| {
                return callSym(c, sym, call.callee, call.args.slice(), false, node);
            },
            .ct_var => {
                return c.reportErrorFmt("TODO ct_var", &.{}, call.callee);
            },
            .ct_value => |ct_value| {
                defer c.heap.destructValue(ct_value);
                if (ct_value.type.id() == bt.Type) {
                    const type_ = ct_value.value.asPtr(*cy.Type);
                    const sym = type_.sym();
                    return callSym(c, @ptrCast(sym), call.callee, call.args.slice(), false, node);
                } else {
                    if (ct_value.type.kind() == .func_sym) {
                        const func = ct_value.value.asPtr(*cy.Func);
                        return c.semaCallFunc(func, call.args.slice(), node);
                    } else {
                        return c.reportErrorFmt("TODO ct_value", &.{}, call.callee);
                    }
                }
            },
        }
    } else {
        const calleeRes = try c.semaExprSkipSym(call.callee, .{});
        if (calleeRes.resType == .sym) {
            return callSym(c, calleeRes.data.sym, call.callee, call.args.slice(), false, node);
        } else if (calleeRes.resType == .func) {
            return c.semaCallFunc(calleeRes.data.func, call.args.slice(), @ptrCast(node));
        } else {
            return c.semaCallValue(calleeRes, call.callee, call.args.slice(), node);
        }
    }
}

/// Expr or construct binExpr from opAssignStmt.
pub fn semaExprOrOpAssignBinExpr(c: *cy.Chunk, node: *ast.Node, cstr: Cstr, opAssignBinExpr: bool) !ExprResult {
    if (!opAssignBinExpr) {
        return try c.semaExpr(node, cstr);
    } else {
        const stmt = node.cast(.op_assign_stmt);
        return try c.semaBinExpr(cstr, stmt.left, stmt.op, stmt.right, node);
    }
}

pub fn semaStringTarget(c: *cy.Chunk, lit: []const u8, opt_target: ?*cy.Type, node: *ast.Node) !ExprResult {
    if (opt_target) |target_t| {
        if (target_t.isPointer()) {
            const child_t = target_t.cast(.pointer).child_t;
            if (child_t.id() == bt.R8 or child_t.id() == bt.I8) {
                return c.semaStringAs(lit, target_t, node);
            }
        }

        var base_t = target_t;
        if (target_t.kind() == .option) {
            base_t = target_t.cast(.option).child_t;
        }

        var target_bits: ?u32 = null;
        if (base_t.id() == bt.Type) {
            // `type` is a host type with an integer layout. A code point is not a type.
        } else if (base_t.kind() == .int) {
            target_bits = base_t.cast(.int).bits;
        } else if (base_t.kind() == .raw) {
            target_bits = base_t.cast(.raw).bits;
        }
        if (target_bits) |bits| {
            if (try semaTryStringLitCodepoint(c, lit, bits, node)) |val| {
                switch (bits) {
                    8 => return semaConst8(c, val.byte, base_t, node),
                    16 => return semaConst16(c, val.u16, base_t, node),
                    32 => return semaConst32(c, val.u32, base_t, node),
                    64 => return semaConst(c, val.val, base_t, node),
                    else => @panic("unexpected"),
                }
            }
        }
    }        
    return semaStringAs(c, lit, c.sema.str_t, node);
}

pub fn semaString(c: *cy.Chunk, lit: []const u8, node: *ast.Node) !ExprResult {
    return semaStringAs(c, lit, c.sema.str_t, node);
}

pub fn semaStringAs(c: *cy.Chunk, lit: []const u8, type_: *cy.Type, node: *ast.Node) !ExprResult {
    const raw = try c.unescapeString(lit);
    if (raw.ptr != lit.ptr) {
        // Dupe and track in ast.strs.
        const dupe = try c.alloc.dupe(u8, raw);
        c.parser.ast.strs.append(c.alloc, dupe) catch |err| {
            c.alloc.free(dupe);
            return err;
        };
        return c.semaRawStringAs(dupe, type_, node);
    } else {
        return c.semaRawStringAs(raw, type_, node);
    }
}

pub fn semaRawString(c: *cy.Chunk, raw: []const u8, node: *ast.Node) !ExprResult {
    return semaRawStringAs(c, raw, c.sema.str_t, node);
}

pub fn semaRawStringAs(c: *cy.Chunk, raw: []const u8, type_: *cy.Type, node: *ast.Node) !ExprResult {
    const expr = try c.ir.newExpr(.string, type_, node, .{ .raw_ptr = raw.ptr, .raw_len = raw.len });
    return ExprResult.initOwned(expr);
}

pub fn semaConst16(c: *cy.Chunk, val: u16, type_: *cy.Type, node: *ast.Node) !ExprResult {
    const expr = try c.ir.newExpr(.const16, type_, node, .{ .val = val });
    return ExprResult.init2(expr);
}

pub fn semaConst32(c: *cy.Chunk, val: u32, type_: *cy.Type, node: *ast.Node) !ExprResult {
    const expr = try c.ir.newExpr(.const32, type_, node, .{ .val = val });
    return ExprResult.init2(expr);
}

pub fn semaConst(c: *cy.Chunk, val: u64, type_: *cy.Type, node: *ast.Node) !ExprResult {
    const expr = try c.ir.newExpr(.const64, type_, node, .{ .val = val });
    return ExprResult.init2(expr);
}

pub fn semaConst8(c: *cy.Chunk, val: u8, type_: *cy.Type, node: *ast.Node) !ExprResult {
    const expr = try c.ir.newExpr(.const8, type_, node, .{ .val = val });
    return ExprResult.init2(expr);
}

pub fn semaVoid(c: *cy.Chunk, node: *ast.Node) !ExprResult {
    const loc = try c.ir.newExpr(.voidv, c.sema.void_t, node, .{});
    return ExprResult.init(loc, c.sema.void_t);
}

pub fn semaTrue(c: *cy.Chunk, node: *ast.Node) !ExprResult {
    const loc = try c.ir.newExpr(.truev, c.sema.bool_t, node, .{});
    return ExprResult.init(loc, c.sema.bool_t);
}

pub fn semaFalse(c: *cy.Chunk, node: *ast.Node) !ExprResult {
    const irIdx = try c.ir.newExpr(.falsev, c.sema.bool_t, node, .{});
    return ExprResult.init(irIdx, c.sema.bool_t);
}

pub fn semaIsError(c: *cy.Chunk, rec: ExprResult, node: *ast.Node) !ExprResult {
    const loc = try c.ir.newExpr(.field, c.sema.i64_t, node, .{
        .idx = 0,
        .rec = rec.ir,
    });
    const field = ExprResult.init2(loc);
    return semaIsZero(c, field, node);
}

pub fn semaIsNone(c: *cy.Chunk, rec: ExprResult, node: *ast.Node) !ExprResult {
    if (rec.type.kind() == .option) {
        if (rec.type.cast(.option).zero_union) {
            return semaIsZero(c, rec, node);
        } else {
            const loc = try c.ir.newExpr(.field, c.sema.i64_t, node, .{
                .idx = 0,
                .rec = rec.ir,
            });
            const field = ExprResult.init(loc, c.sema.i64_t);
            return semaIsZero(c, field, node);
        }
    }
    if (rec.type.getRefLikeChild()) |child| {
        if (child.kind() == .option) {
            if (child.cast(.option).zero_union) {
                const ptr_cast = try c.ir.newExpr(.bitcast, c.sema.ptr_int_t, node, .{
                    .expr = rec.ir,
                });
                const loc = try c.ir.newExpr(.deref, c.sema.rsize_t, node, .{
                    .expr = ptr_cast,
                });
                const rec_deref = ExprResult.init(loc, child);
                return semaIsZero(c, rec_deref, node);
            } else {
                const loc = try c.ir.newExpr(.field, c.sema.i64_t, node, .{
                    .idx = 0,
                    .rec = rec.ir,
                });
                const field = ExprResult.init(loc, c.sema.i64_t);
                return semaIsZero(c, field, node);
            }
        }
    }
    return c.reportError("Expected `Option` type.", node);
}

pub fn semaIsZero(c: *cy.Chunk, child: ExprResult, node: *ast.Node) !ExprResult {
    const irIdx = try c.ir.newExpr(.is_zero, c.sema.bool_t, node, .{ .child = child.ir });
    return ExprResult.init(irIdx, c.sema.bool_t);
}

pub fn semaNone(c: *cy.Chunk, prefer_t: *cy.Type, node: *ast.Node) !ExprResult {
    if (prefer_t.kind() == .option) {
        const option_t = prefer_t.cast(.option);
        if (option_t.zero_union) {
            var res = try c.semaConst(0, prefer_t, node);
            res.owned = true;
            return res;
        } else {
            // Generate IR to wrap value into optional.
            var b: InitBuilder = .{ .c = c };
            try b.begin(prefer_t, 2, node);
            const tag = try c.semaConst(0, c.sema.i64_t, node);
            try b.pushArg(tag, node);
            const payload = try c.semaVoid(node);
            try b.pushArg2(payload, c.sema.void_t, node);
            const loc = b.end();

            return ExprResult.initOwned(loc);
        }
    } else if (prefer_t.kind() == .result) {
        const result_t = prefer_t.cast(.result);
        if (result_t.child_t.kind() == .option) {
            const option = try semaNone(c, result_t.child_t, node);
            return semaInitChoice(c, prefer_t, 1, 1, option, node);
        }
    } else if (prefer_t.kind() == .pointer) {
        const pointer = prefer_t.cast(.pointer);
        if (!pointer.ref) {
            return semaConst(c, 0, prefer_t, node);
        }
    } else if (prefer_t.kind() == .func_ptr) {
        const func_ptr = prefer_t.cast(.func_ptr);
        if (func_ptr.sig.extern_) {
            // @extern fn()
            return semaConst(c, 0, prefer_t, node);
        }
    }
    return c.reportErrorFmt("Expected `?T` to infer `none` value, found `{}`.", &.{v(prefer_t.name())}, node);
}

pub fn semaRefOrType(c: *cy.Chunk, node: *ast.Node, cstr: Cstr) !ExprResult {
    const ref = node.cast(.ref);
    var child_cstr = Cstr{};
    if (cstr.target_t) |target_t| {
        if (target_t.isRefPointer()) {
            child_cstr.target_t = target_t.cast(.pointer).child_t;
        }
    }
    const child = try c.semaExprSkipSym(ref.child, child_cstr);
    if (child.resType == .sym) {
        return c.reportError("Compile-time type cannot be used here. Consider expanding with `#{expr}` or using it in a compile-time context.", node);
    }
    if (child.resType == .func) {
        return c.reportError("A function symbol can not be lifted. Assign it to a variable first.", ref.child);
    }
    return semaLift(c, child, node);
}

pub fn sema_ex_borrow_or_type(c: *cy.Chunk, node: *ast.Node, cstr: Cstr) !ExprResult {
    const borrow = node.cast(.ex_borrow);
    var child_cstr = Cstr{};
    if (cstr.target_t) |target_t| {
        if (target_t.kind() == .ex_borrow) {
            child_cstr.target_t = target_t.cast(.ex_borrow).child_t;
        }
    }

    // var extended_temp: LocalId = undefined;
    // if (cstr.assign_to_local) {
    //     // Reserve local ahead of any temps in case the borrow extends the rvalue's lifetime.
    //     extended_temp = try reserveLocalName(c, "_temp", c.sema.void_t, true, true, borrow.child);
    //     c.varStack.items[extended_temp].type = .dead;
    // }

    child_cstr.use_as_borrow = true;
    child_cstr.fit_target = true;
    var child = try c.semaExprSkipSym(borrow.child, child_cstr);
    if (child.resType == .sym) {
        if (!cstr.allow_ct_sym) {
            return c.reportError("Expected value expression. Found a compile-time symbol.", borrow.child);
        } 
        const borrow_t = try getBorrowType(c, child.data.sym.getStaticType().?);
        return ExprResult.initCustom(undefined, .sym, c.sema.type_t, .{ .sym = &borrow_t.sym().head });
    }

    if (cstr.assign_to_local and !child.addressable) {
        // try semaInitLocal(c, extended_temp, child, borrow.child);
        // child = try semaLocal(c, extended_temp, node);
        // var res = try sema_ex_borrow(c, child, node);
        // res.data.value.has_aux_local = true;
        // return res;
        return c.reportError("Cannot exclusively borrow a temporary value.", borrow.child);
    } else {
        return sema_ex_borrow(c, child, node);
    }
}

pub fn semaBorrowOrType(c: *cy.Chunk, node: *ast.Node, cstr: Cstr) !ExprResult {
    const borrow = node.cast(.borrow);
    var child_cstr = Cstr{};
    if (cstr.target_t) |target_t| {
        if (target_t.kind() == .borrow) {
            child_cstr.target_t = target_t.cast(.borrow).child_t;
        }
    }

    // var extended_temp: LocalId = undefined;
    // if (cstr.assign_to_local) {
    //     // Reserve local ahead of any temps in case the borrow extends the rvalue's lifetime.
    //     extended_temp = try reserveLocalName(c, "_temp", c.sema.void_t, true, true, borrow.child);
    //     c.varStack.items[extended_temp].type = .dead;
    // }

    child_cstr.use_as_borrow = true;
    child_cstr.fit_target = true;
    var child = try c.semaExprSkipSym(borrow.child, child_cstr);
    if (child.resType == .sym) b: {
        if (child.data.sym.type == .func) {
            if (child.data.sym.cast(.func).numFuncs == 1) {
                // Borrow static function.
                child = try symbol2(c, child.data.sym, false, child_cstr.target_t, borrow.child);
                break :b;
            }
        }
        if (!cstr.allow_ct_sym) {
            return c.reportError("Expected value expression. Found a compile-time symbol.", borrow.child);
        } 
        const borrow_t = try getBorrowType(c, child.data.sym.getStaticType().?);
        return ExprResult.initCustom(undefined, .sym, c.sema.type_t, .{ .sym = &borrow_t.sym().head });
    }

    if (cstr.assign_to_local and !child.addressable) {
        // try semaInitLocal(c, extended_temp, child, borrow.child);
        // child = try semaLocal(c, extended_temp, node);
        // var res = try semaBorrow(c, child, node);
        // res.data.value.has_aux_local = true;
        // return res;
        return c.reportError("Cannot borrow a temporary value.", borrow.child);
    } else {
        return semaBorrow(c, child, node);
    }
}

fn semaInitLocal(c: *cy.Chunk, id: LocalId, init: ExprResult, node: *ast.Node) !void {
    const local = &c.varStack.items[id];
    const loc = try c.ir.pushStmt(.declare_local, node, .{
        .name_ptr = local.namePtr,
        .name_len = @as(u16, @intCast(local.nameLen)),
        .decl_t = init.type,
        .id = local.inner.local.id,
        .init = init.ir,
    });
    local.inner.local.declIrStart = loc;
    local.decl_t = init.type;
    local.type = .local;
}

pub fn semaPtrOrType(c: *cy.Chunk, node: *ast.Node, cstr: Cstr) !ExprResult {
    _ = cstr;
    const ptr = node.cast(.ptr);
    var child = try c.semaExprSkipSym(ptr.child, .{});
    if (child.resType == .sym) {
        return c.reportErrorFmt("Unsupported.", &.{}, ptr.child);
    }
    if (child.resType == .func) {
        return c.reportError("Can not take the address of a function symbol. Assign it to a variable first.", ptr.child);
    }
    // if (!child.addressable) {
    //     return c.reportErrorFmt("Cannot take the address of a temporary value.", &.{}, node.child);
    // }
    child = try semaEnsureAddressable(c, child, node);

    const ptr_t = try getPtrType(c, child.type);
    const loc = try c.ir.newExpr(.address_of, ptr_t, node, .{
        .expr = child.ir,
    });
    return ExprResult.init2(loc);
}

pub fn semaUnExpr(c: *cy.Chunk, unary: *ast.Unary, expr: Cstr) !ExprResult {
    const node = @as(*ast.Node, @ptrCast(unary));
    switch (unary.op) {
        .minus => {
            var child: ExprResult = undefined;
            if (unary.child.type() == .decLit) {
                const literal = unary.child.cast(.decLit).value.slice();
                if (expr.target_t) |target_t| {
                    if (target_t == c.sema.f64_t) {
                        const val = try std.fmt.parseFloat(f64, literal);
                        return c.semaConst(@bitCast(-val), c.sema.f64_t, node);
                    } else if (target_t == c.sema.f32_t) {
                        const val = try std.fmt.parseFloat(f32, literal);
                        return c.semaConst32(@bitCast(-val), c.sema.f32_t, node);
                    } else if (target_t == c.sema.i32_t) {
                        var val: u64 = try std.fmt.parseInt(u64, literal, 10);
                        const abs_min = 1 << 31;
                        if (val > abs_min) {
                            return c.reportError("Number literal is out of bounds.", @ptrCast(unary.child));
                        }
                        if (val > 0) {
                            val = (abs_min - val) | abs_min;
                        }
                        return c.semaConst32(@truncate(val), c.sema.i32_t, node);
                    } else if (target_t == c.sema.i16_t) {
                        var val: u64 = try std.fmt.parseInt(u64, literal, 10);
                        const abs_min = 1 << 15;
                        if (val > abs_min) {
                            return c.reportError("Number literal is out of bounds.", @ptrCast(unary.child));
                        }
                        if (val > 0) {
                            val = (abs_min - val) | abs_min;
                        }
                        return c.semaConst16(@truncate(val), c.sema.i16_t, node);
                    } else if (target_t == c.sema.i8_t) {
                        var val: u64 = try std.fmt.parseInt(u64, literal, 10);
                        const abs_min = 1 << 7;
                        if (val > abs_min) {
                            return c.reportError("Number literal is out of bounds.", @ptrCast(unary.child));
                        }
                        if (val > 0) {
                            val = (abs_min - val) | abs_min;
                        }
                        return c.semaConst8(@truncate(val), c.sema.i8_t, node);
                    }
                }
                var val: i64 = @bitCast(try semaParseInt(c, u64, literal, 10, @ptrCast(unary.child)));
                if (val != std.math.minInt(i64)) {
                    if (val < 0) {
                        return c.reportError("Integer literal does not fit the target type.", @ptrCast(unary.child));
                    } else {
                        val = -val;
                    }
                }
                return c.semaConst(@bitCast(val), c.sema.i64_t, node);
            } else {
                child = try c.semaExprTarget(unary.child, expr.target_t);
            }

            switch (child.type.id()) {
                bt.F32,
                bt.F64 => {
                    const op = try c.ir.newExpr(.fneg, child.type, node, .{
                        .expr = child.ir,
                    });
                    return ExprResult.init2(op);
                },
                bt.I8,
                bt.I16,
                bt.I32,
                bt.I64 => {
                    const op = try c.ir.newExpr(.neg, child.type, node, .{
                        .expr = child.ir,
                    });
                    return ExprResult.init2(op);
                },
                else => {},
            }

            // Look for sym under child type's module.
            const childTypeSym = child.type.sym();
            const sym = try c.getResolvedSymOrFail(@ptrCast(childTypeSym), unary.op.name(), node);
            const func_sym = try requireFuncSym(c, sym, node);
            return c.semaCallFuncSym1(func_sym, unary.child, child, node);
        },
        .lnot => {
            const child = try c.semaExprTarget(unary.child, expr.target_t);
            switch (child.type.id()) {
                bt.Bool => {
                    const op = try c.ir.newExpr(.unary_op, c.sema.bool_t, node, .{
                        .childT = child.type,
                        .op = .lnot,
                        .expr = child.ir,
                    });
                    return ExprResult.init2(op);
                },
                else => {},
            }

            // Look for sym under child type's module.
            const childTypeSym = child.type.sym();
            const sym = try c.getResolvedSymOrFail(@ptrCast(childTypeSym), unary.op.name(), node);
            const func_sym = try requireFuncSym(c, sym, node);
            return c.semaCallFuncSym1(func_sym, unary.child, child, node);
        },
        .bitwiseNot => {
            // Only an int or raw target reaches the operand. Another target (float) would convert
            // the operand to a type that has no `~`.
            var child_target: ?*cy.Type = null;
            if (expr.target_t) |target_t| {
                if (target_t.kind() == .int or target_t.kind() == .raw) {
                    child_target = target_t;
                }
            }
            const child = try c.semaExprTarget(unary.child, child_target);

            switch (child.type.id()) {
                bt.R8,
                bt.R16,
                bt.R32,
                bt.R64,
                bt.I8,
                bt.I16,
                bt.I32,
                bt.I64 => {
                    const op = try c.ir.newExpr(.not, child.type, node, .{
                        .expr = child.ir,
                    });
                    return fold_const_int(c, ExprResult.init(op, child.type));
                },
                else => {},
            }

            // Look for sym under child type's module.
            const childTypeSym = child.type.sym();
            const sym = try c.getResolvedSymOrFail(@ptrCast(childTypeSym), unary.op.name(), node);
            const func_sym = try requireFuncSym(c, sym, node);
            return c.semaCallFuncSym1(func_sym, unary.child, child, node);
        },
        else => return c.reportErrorFmt("Unsupported unary op: {}", &.{v(unary.op)}, node),
    }
}

fn sema_bin_expr3(c: *cy.Chunk, left: ExprResult, left_n: *ast.Node, right: ExprResult, right_n: *ast.Node, op: cy.BinaryExprOp, node: *ast.Node) !ExprResult {
    switch (left.type.id()) {
        bt.R8,
        bt.R16,
        bt.R32,
        bt.R64 => {
            const cond: ir.Condition = switch (op) {
                .greater => .ugt,
                .greater_equal => .uge,
                .less => .ult,
                .less_equal => .ule,
                else => {
                    @panic("unexpected");
                },
            };
            const expr = try c.ir.newExpr(.cmp, c.sema.bool_t, node, .{
                .left = left.ir,
                .right = right.ir,
                .cond = cond,
            });
            return cy.sema.ExprResult.init2(expr);
        },
        bt.F64,
        bt.F32,
        bt.I8,
        bt.I16,
        bt.I32,
        bt.I64 => {
            const cond: ir.Condition = switch (op) {
                .greater => .gt,
                .greater_equal => .ge,
                .less => .lt,
                .less_equal => .le,
                else => {
                    @panic("unexpected");
                },
            };
            const expr = try c.ir.newExpr(.cmp, c.sema.bool_t, node, .{
                .left = left.ir,
                .right = right.ir,
                .cond = cond,
            });
            return cy.sema.ExprResult.init2(expr);
        },
        else => {
            const leftTypeSym = left.type.sym();
            const sym = try c.getResolvedSymOrFail(@ptrCast(leftTypeSym), op.name(), node);
            const func_sym = try requireFuncSym(c, sym, node);
            const args = [_]sema_func.Argument{
                sema_func.Argument.initReceiver(left_n, left),
                sema_func.Argument.initPreResolved(right_n, right),
            };
            return c.semaCallFuncSymRec2(func_sym, &args, node);
        },
    }
}

/// Folds a 64-bit integer op whose operands are all `const64` into one `const64`.
/// Matches the VM: wrapping add/sub/mul, shift amount masked by 0xff (>= 64 is not folded).
fn fold_const_int(c: *cy.Chunk, res: ExprResult) !ExprResult {
    const expr = res.ir;
    switch (expr.type.id()) {
        bt.I64, bt.R64 => {},
        else => return res,
    }
    const val: u64 = switch (expr.code) {
        .not => b: {
            const child = expr.cast(.not).expr;
            if (child.code != .const64) return res;
            break :b ~child.cast(.const64).val;
        },
        .add, .sub, .mul, .imul, .and_op, .or_op, .xor, .lsl, .lsr => b: {
            const bin: *ir.BinOp2 = @ptrCast(@alignCast(expr));
            if (bin.left.code != .const64 or bin.right.code != .const64) return res;
            const l = bin.left.cast(.const64).val;
            const r = bin.right.cast(.const64).val;
            break :b switch (expr.code) {
                .add => l +% r,
                .sub => l -% r,
                .mul, .imul => l *% r,
                .and_op => l & r,
                .or_op => l | r,
                .xor => l ^ r,
                .lsl => if (r < 64) l << @intCast(r) else return res,
                .lsr => if (r < 64) l >> @intCast(r) else return res,
                else => unreachable,
            };
        },
        else => return res,
    };
    return c.semaConst(val, expr.type, expr.node);
}

fn sema_bin_expr2(c: *cy.Chunk, left: ExprResult, left_n: *ast.Node, right: ExprResult, right_n: *ast.Node, op: cy.BinaryExprOp, node: *ast.Node) !ExprResult {
    switch (left.type.id()) {
        bt.R8,
        bt.R16,
        bt.R32,
        bt.R64 => b: {
            switch (op) {
                .plus => {
                    const expr = try c.ir.newExpr(.add, left.type, node, .{
                        .left = left.ir,
                        .right = right.ir,
                    });
                    return cy.sema.ExprResult.init2(expr);
                },
                .minus => {
                    const expr = try c.ir.newExpr(.sub, left.type, node, .{
                        .left = left.ir,
                        .right = right.ir,
                    });
                    return cy.sema.ExprResult.init2(expr);
                },
                .star => {
                    const expr = try c.ir.newExpr(.mul, left.type, node, .{
                        .left = left.ir,
                        .right = right.ir,
                    });
                    return cy.sema.ExprResult.init2(expr);
                },
                .slash => {
                    const expr = try c.ir.newExpr(.div, left.type, node, .{
                        .left = left.ir,
                        .right = right.ir,
                    });
                    return cy.sema.ExprResult.init2(expr);
                },
                .percent => {
                    const expr = try c.ir.newExpr(.mod, left.type, node, .{
                        .left = left.ir,
                        .right = right.ir,
                    });
                    return cy.sema.ExprResult.init2(expr);
                },
                .bitwiseAnd => {
                    const expr = try c.ir.newExpr(.and_op, left.type, node, .{
                        .left = left.ir,
                        .right = right.ir,
                    });
                    return cy.sema.ExprResult.init2(expr);
                },
                .bitwiseOr => {
                    const expr = try c.ir.newExpr(.or_op, left.type, node, .{
                        .left = left.ir,
                        .right = right.ir,
                    });
                    return cy.sema.ExprResult.init2(expr);
                },
                .bitwiseXor => {
                    const expr = try c.ir.newExpr(.xor, left.type, node, .{
                        .left = left.ir,
                        .right = right.ir,
                    });
                    return cy.sema.ExprResult.init2(expr);
                },
                .bitwiseLeftShift => {
                    const expr = try c.ir.newExpr(.lsl, left.type, node, .{
                        .left = left.ir,
                        .right = right.ir,
                    });
                    return cy.sema.ExprResult.init2(expr);
                },
                .bitwiseRightShift => {
                    const expr = try c.ir.newExpr(.lsr, left.type, node, .{
                        .left = left.ir,
                        .right = right.ir,
                    });
                    return cy.sema.ExprResult.init2(expr);
                },
                else => {
                    break :b;
                },
            }
        },
        bt.I8,
        bt.I16,
        bt.I32,
        bt.I64 => b: {
            const ir_code: ir.ExprCode = switch (op) {
                .plus => {
                    const expr = try c.ir.newExpr(.add, left.type, node, .{
                        .left = left.ir,
                        .right = right.ir,
                    });
                    return cy.sema.ExprResult.init2(expr);
                },
                .minus => {
                    const expr = try c.ir.newExpr(.sub, left.type, node, .{
                        .left = left.ir,
                        .right = right.ir,
                    });
                    return cy.sema.ExprResult.init2(expr);
                },
                .star => {
                    const expr = try c.ir.newExpr(.imul, left.type, node, .{
                        .left = left.ir,
                        .right = right.ir,
                    });
                    return cy.sema.ExprResult.init2(expr);
                },
                .slash => {
                    const expr = try c.ir.newExpr(.idiv, left.type, node, .{
                        .left = left.ir,
                        .right = right.ir,
                    });
                    return cy.sema.ExprResult.init2(expr);
                },
                .percent => {
                    const expr = try c.ir.newExpr(.imod, left.type, node, .{
                        .left = left.ir,
                        .right = right.ir,
                    });
                    return cy.sema.ExprResult.init2(expr);
                },
                .bitwiseAnd => {
                    const expr = try c.ir.newExpr(.and_op, left.type, node, .{
                        .left = left.ir,
                        .right = right.ir,
                    });
                    return cy.sema.ExprResult.init2(expr);
                },
                .bitwiseOr => {
                    const expr = try c.ir.newExpr(.or_op, left.type, node, .{
                        .left = left.ir,
                        .right = right.ir,
                    });
                    return cy.sema.ExprResult.init2(expr);
                },
                .bitwiseXor => {
                    const expr = try c.ir.newExpr(.xor, left.type, node, .{
                        .left = left.ir,
                        .right = right.ir,
                    });
                    return cy.sema.ExprResult.init2(expr);
                },
                .bitwiseLeftShift => {
                    const expr = try c.ir.newExpr(.lsl, left.type, node, .{
                        .left = left.ir,
                        .right = right.ir,
                    });
                    return cy.sema.ExprResult.init2(expr);
                },
                .bitwiseRightShift => {
                    const expr = try c.ir.newExpr(.lsr, left.type, node, .{
                        .left = left.ir,
                        .right = right.ir,
                    });
                    return cy.sema.ExprResult.init2(expr);
                },
                else => {
                    break :b;
                },
            };
            const expr = try c.ir.newExpr(ir_code, left.type, node, .{
                .left = left.ir,
                .right = right.ir,
            });
            return cy.sema.ExprResult.init2(expr);
        },
        bt.F32,
        bt.F64 => b: {
            switch (op) {
                .plus => {
                    const expr = try c.ir.newExpr(.fadd, left.type, node, .{
                        .left = left.ir,
                        .right = right.ir,
                    });
                    return ExprResult.init2(expr);
                },
                .minus => {
                    const expr = try c.ir.newExpr(.fsub, left.type, node, .{
                        .left = left.ir,
                        .right = right.ir,
                    });
                    return ExprResult.init2(expr);
                },
                .star => {
                    const expr = try c.ir.newExpr(.fmul, left.type, node, .{
                        .left = left.ir,
                        .right = right.ir,
                    });
                    return ExprResult.init2(expr);
                },
                .slash => {
                    const expr = try c.ir.newExpr(.fdiv, left.type, node, .{
                        .left = left.ir,
                        .right = right.ir,
                    });
                    return ExprResult.init2(expr);
                },
                .percent => {
                    const expr = try c.ir.newExpr(.fmod, left.type, node, .{
                        .left = left.ir,
                        .right = right.ir,
                    });
                    return ExprResult.init2(expr);
                },
                else => {
                    break :b;
                },
            }
        },
        else => {},
    }
    const leftTypeSym = left.type.sym();
    const sym = try c.getResolvedSymOrFail(@ptrCast(leftTypeSym), op.name(), node);
    const func_sym = try requireFuncSym(c, sym, node);
    const args = [_]sema_func.Argument{
        sema_func.Argument.initReceiver(left_n, left),
        sema_func.Argument.initPreResolved(right_n, right),
    };
    return c.semaCallFuncSymRec2(func_sym, &args, node);
}

pub fn semaBinExpr(c: *cy.Chunk, expr: Cstr, left_n: *ast.Node, op: cy.BinaryExprOp, right_n: *ast.Node, node: *ast.Node) !ExprResult {
    switch (op) {
        .and_op => {
            return semaLogicAnd(c, left_n, right_n, node);
        },
        .or_op => {
            return semaLogicOr(c, left_n, right_n, node);
        },
        .greater,
        .greater_equal,
        .less,
        .less_equal => {
            var left = try c.semaExpr(left_n, .{});
            switch (left.type.kind()) {
                .int,
                .raw,
                .float => {
                    const right = try semaRightOperand(c, &left, left_n, right_n, .{ .target_t = left.type, .reqTypeCstr = true, .fit_target = true });
                    return sema_bin_expr3(c, left, left_n, right, right_n, op, node);
                },
                else => {},
            }
            const leftTypeSym = left.type.sym();
            const sym = try c.getResolvedSymOrFail(@ptrCast(leftTypeSym), op.name(), node);
            const func_sym = try requireFuncSym(c, sym, node);
            return c.semaCallFuncSymRec(func_sym, left_n, left, &.{ right_n }, false, node);
        },
        .bitwiseAnd,
        .bitwiseOr,
        .bitwiseXor,
        .bitwiseLeftShift,
        .bitwiseRightShift,
        .star,
        .slash,
        .percent,
        .pow,
        .plus,
        .minus => {
            switch (left_n.type()) {
                .binLit,
                .octLit,
                .hexLit,
                .decLit => {
                    // Infer type from right.
                    const right = try c.semaExprHint(right_n, expr.target_t);
                    const left = try c.semaExprCstr(left_n, right.type);
                    return fold_const_int(c, try sema_bin_expr2(c, left, left_n, right, right_n, op, node));
                },
                else => {},
            }
            var left = try c.semaExprHint(left_n, expr.target_t);
            if (left.type.kind() == .int or left.type.kind() == .raw) {
                var right = try semaRightOperand(c, &left, left_n, right_n, .{ .target_t = left.type, .reqTypeCstr = false, .fit_target = true });
                if (left.type.id() != right.type.id()) {
                    // Target biggest int width.
                    var left_bits: u32 = undefined;
                    if (left.type.kind() == .int) {
                        left_bits = left.type.cast(.int).bits;
                    } else {
                        left_bits = left.type.cast(.raw).bits;
                    }
                    var right_bits: u32 = undefined;
                    if (right.type.kind() == .int) {
                        right_bits = right.type.cast(.int).bits;
                    } else if (right.type.kind() == .raw) {
                        right_bits = right.type.cast(.raw).bits;
                    } else {
                        const exp_name = try c.sema.allocTypeName(left.type);
                        defer c.alloc.free(exp_name);
                        const act_name = try c.sema.allocTypeName(right.type);
                        defer c.alloc.free(act_name);
                        return c.reportErrorFmt("Expected `{}`, found `{}`.", &.{v(exp_name), v(act_name)}, right_n);
                    }
                    if (left_bits < right_bits) {
                        left = (try semaFitTarget(c, left, right.type, left_n)) orelse {
                            return c.reportError("Could not widen left integer type.", left_n);
                        };
                    } else {
                        right = (try semaFitTarget(c, right, left.type, right_n)) orelse {
                            return c.reportError("Could not widen right integer type.", right_n);
                        };
                    }
                }
                return fold_const_int(c, try sema_bin_expr2(c, left, left_n, right, right_n, op, node));
            } else if (left.type.kind() == .float) {
                const right = try semaRightOperand(c, &left, left_n, right_n, .{ .target_t = left.type, .reqTypeCstr = false, .fit_target = true });
                return fold_const_int(c, try sema_bin_expr2(c, left, left_n, right, right_n, op, node));
            }

            // Look for sym under left type's module.
            const sym = try c.accessResolvedSymOrFail(left.type, op.name(), node);
            const func_sym = try requireFuncSym(c, sym, node);
            return c.semaCallFuncSymRec(func_sym, left_n, left, &.{ right_n }, false, node);
        },
        .bang_equal => {
            var left = try c.semaExpr(left_n, .{});
            const right = try semaRightOperand(c, &left, left_n, right_n, .{ .target_t = left.type, .reqTypeCstr = true, .fit_target = true });
            const res = try semaCompare(c, left_n, left, right_n, right, node);
            const not = try c.ir.newExpr(.unary_op, c.sema.bool_t, node, .{
                .childT = c.sema.bool_t, .op = .lnot, .expr = res.ir,
            });
            return ExprResult.init2(not);
        },
        .equal_equal => {
            var left = try c.semaExpr(left_n, .{});
            const right = try semaRightOperand(c, &left, left_n, right_n, .{ .target_t = left.type, .reqTypeCstr = true, .fit_target = true });
            return semaCompare(c, left_n, left, right_n, right, node);
        },
        else => return c.reportErrorFmt("Unsupported binary op: {}", &.{v(op)}, node),
    }
}

/// Analyzes the right operand of a binary expression. `left` is evaluated before a statement that the right
/// operand adds (`seqFlush`).
fn semaRightOperand(c: *cy.Chunk, left: *ExprResult, left_n: *ast.Node, right_n: *ast.Node, cstr: Cstr) !ExprResult {
    const seq_start = c.seq_pending.items.len;
    defer seqPop(c, seq_start);
    try seqPushRes(c, left, left_n);
    return c.semaExpr(right_n, cstr);
}

/// Assumes first arg contains the the args count.
pub fn semaPartialVector(c: *cy.Chunk, arr_t: *cy.Type, args: []*ir.Expr, node: *ast.Node) !ExprResult {
    if (args.len > 255) {
        return c.reportError("Max limit reached.", node);
    }
    const loc = try c.ir.newExpr(.init, arr_t, node, .{
        .nargs = @intCast(args.len), .args = args.ptr,
    });
    return ExprResult.initOwned(loc);
}

pub fn semaVector(c: *cy.Chunk, arr_t: *cy.Type, args: []*ir.Expr, node: *ast.Node) !ExprResult {
    if (args.len > 255) {
        return c.reportError("Max limit reached.", node);
    }
    const loc = try c.ir.newExpr(.init, arr_t, node, .{
        .nargs = @intCast(args.len), .args = args.ptr,
    });
    return ExprResult.initOwned(loc);
}

fn semaInitLitTarget(c: *cy.Chunk, init_lit: *ast.InitLit, target_t: *cy.Type, return_infer_error: bool, assign_to_local: bool) !ExprResult {
    const node: *ast.Node = @ptrCast(init_lit);
    if (target_t.sym().instance) |instance| {
        if (assign_to_local) {
            if (instance.getSymTemplate() == c.sema.span_tmpl) {
                // Overrides `Span[T].init_sequence` and extends the lifetime of the vector.
                const elem_t = instance.params[0].asPtr(*cy.Type);

                const vec_t = try getVectorType(c, elem_t, @intCast(init_lit.args.len));
                const vec_var = try reserveLocalName(c, "_vec", vec_t, true, true, node);
                c.varStack.items[vec_var].type = .dead;

                const args = try c.ir.allocArray(*ir.Expr, init_lit.args.len);
                // The elements are not registered as pending operands (`seqFlush`): `_vec` is reserved above and
                // declared below, and a local that is declared in between would break the order of the IR locals.
                for (init_lit.args.slice(), 0..) |arg, i| {
                    const res = try c.semaExprTarget(arg, elem_t);
                    args[i] = res.ir;
                }

                const vec_init = try semaVector(c, vec_t, args, node);
                try semaInitLocal(c, vec_var, vec_init, node);

                const vec = try semaLocal(c, vec_var, node);
                const borrow_t = try getBorrowType(c, elem_t);
                const addr_of = try c.ir.newExpr(.address_of, borrow_t, node, .{
                    .expr = vec.ir,
                });
                const borrow = ExprResult.init2(addr_of);

                var res = try sema_span(c, target_t, borrow, @intCast(args.len), node);
                res.data.value.has_aux_local = true;
                return res;
            }
        }
        if (instance.getSymTemplate() == c.sema.as_span_tmpl) {
            // Default to Slice[T].
            const elem_t = instance.params[0].asPtr(*cy.Type);
            const slice_t = try get_slice_type(c, elem_t);
            const init_seq = (try c.getResolvedSym(@ptrCast(slice_t.sym()), "@init_sequence", node)).?;
            return semaInitSequence(c, init_seq, init_lit);
        }
    }

    if (init_lit.array_like) {
        if (try c.getResolvedSym(@ptrCast(target_t.sym()), "@init_sequence", node)) |init_seq| {
            return semaInitSequence(c, init_seq, init_lit);
        }
        if (init_lit.args.len == 0) {
            if (try c.getResolvedSym(@ptrCast(target_t.sym()), "@init_record", node)) |init_pairs| {
                return semaInitRecord(c, init_pairs, init_lit);
            }
        }
    } else {
        if (try c.getResolvedSym(@ptrCast(target_t.sym()), "@init_record", node)) |init_pairs| {
            return semaInitRecord(c, init_pairs, init_lit);
        }
    }

    switch (target_t.kind()) {
        .struct_t => b: {
            const struct_t = target_t.cast(.struct_t);
            if (init_lit.array_like) {
                if (struct_t.tuple) {
                    return c.semaTupleInit(target_t, struct_t.fields(), init_lit);
                } else if (init_lit.args.len > 0) {
                    if (!return_infer_error) {
                        return c.reportError("Expected record initializer.", @ptrCast(init_lit));
                    }
                    break :b;
                }
            }
            return c.semaObjectInit2(struct_t, init_lit);
        },
        .enum_t => {
            return c.reportErrorFmt("Only enum members can be used as initializers.", &.{}, @ptrCast(init_lit));
        },
        .c_union => {
            if (init_lit.args.len > 0) {
                return c.reportError("Only empty initializer is allowed for a `cunion` type.", @ptrCast(init_lit));
            }
            return semaCZero(c, target_t, @ptrCast(init_lit));
        },
        .result => {
            const result_t = target_t.cast(.result);
            return semaInitLitTarget(c, init_lit, result_t.child_t, return_infer_error, false);
        },
        .vector => {
            var vec_t = target_t.cast(.vector);
            if (vec_t.n != init_lit.args.len) {
                vec_t = (try getVectorType(c, vec_t.elem_t, @intCast(init_lit.args.len))).cast(.vector);
            }
            return semaInitVector(c, vec_t, init_lit);
        },
        .partial_vector => {
            return semaInitPartialVector(c, target_t.cast(.partial_vector), init_lit);
        },
        .generic_vector => {
            return semaInitGenericArray(c, target_t.cast(.generic_vector), init_lit);
        },
        else => {},
    }

    if (return_infer_error) {
        return ExprResult.initInferError(error.InitLit);
    } else {
        const type_name = try c.sema.allocTypeName(target_t);
        defer c.alloc.free(type_name);
        return c.reportErrorFmt("Can not infer initializer type `{}`.", &.{v(type_name)}, @ptrCast(init_lit));
    }
}

pub fn semaAccessExpr(c: *cy.Chunk, access: *ast.AccessExpr, prefer_ct_sym: bool, target_t: ?*cy.Type) !ExprResult {
    const right_name = access.right.as_name();
    return semaAccessExpr2(c, access.left, right_name, access.right, prefer_ct_sym, target_t);
}

pub fn semaAccessExpr2(c: *cy.Chunk, left_n: *ast.Node, right_name: []const u8, right_n: *ast.Node, prefer_ct_sym: bool, target_t: ?*cy.Type) !ExprResult {
    const rec = try c.semaExprSkipSym(left_n, .{});
    if (rec.resType == .sym) {
        const sym = rec.data.sym;
        if (sym.getStaticType() == c.sema.symbol_t) {
            // `symbol.name` is a symbol literal, like `error.Name`.
            return sema_at_symbol(c, right_name, right_n);
        }
        const rightSym = try c.getResolvedSymOrFail(sym, right_name, right_n);
        return sema.symbol2(c, rightSym, prefer_ct_sym, target_t, right_n);
    } else {
        return semaAccessFieldName(c, left_n, rec, right_name, right_n);
    }
}

pub fn semaCompare(c: *cy.Chunk, left_n: *ast.Node, left: ExprResult, right_n: *ast.Node, right: ExprResult, node: *ast.Node) !ExprResult {
    var simple_cmp = true;
    switch (left.type.id()) {
        bt.R8,
        bt.I8,
        bt.I16,
        bt.I32,
        bt.I64,
        bt.F64,
        bt.Bool => {},
        else => {
            switch (left.type.kind()) {
                .pointer,
                .enum_t,
                .int => {},
                .option,
                .choice,
                .result,
                .struct_t => {
                    simple_cmp = false;
                },
                else => {},
            }
        },
    }
    if (!simple_cmp) {
        const left_borrow = try semaBorrow(c, left, left_n);
        const right_borrow = try semaBorrow(c, right, right_n);
        const args = [_]sema_func.Argument{
            sema_func.Argument.initPreResolved(left_n, left_borrow),
            sema_func.Argument.initPreResolved(right_n, right_borrow),
        };
        const eq_func = try getEqFunc(c, left.type, node);
        return c.semaCallFunc2(eq_func, &args, &.{}, node);
    } else {
        const new_left = try semaManage(c, left, left_n);
        const new_right = try semaManage(c, right, right_n);
        const loc = try c.ir.newExpr(.binary_op, c.sema.bool_t, node, .{
            .leftT = left.type,
            .rightT = right.type,
            .op = .equal_equal,
            .left = new_left.ir,
            .right = new_right.ir,
        });
        return ExprResult.init2(loc);
    }
}

/// Use of body stmts is extracted so that `lamda_multi` and `lambda_cont` have the same behavior.
fn semaLambdaMulti(c: *cy.Chunk, lambda: *ast.LambdaMulti, stmts: []const *ast.Node, expr: Cstr) !ExprResult {
    const node: *ast.Node = @ptrCast(lambda);

    // try pushResolveContext(c, node);
    // defer popResolveContext(c);

    if (try inferLambdaFuncSig(c, lambda.sig_t, expr.target_t, node)) |sig| {
        const func = try c.addUserLambda(@ptrCast(c.sym), @ptrCast(lambda));
        _ = try pushLambdaProc(c, func);

        try c.resolveUserLambda(func, sig);
        try appendFuncParamVars(c, lambda.params, @ptrCast(sig.params()));

        // Generate function body.
        try semaStmts(c, stmts);

        const lambda_ir = try popLambdaProc(c);
        return ExprResult.initOwned(lambda_ir);
    } else {
        const start = c.func_param_stack.items.len;
        defer c.func_param_stack.items.len = start;
        try pushLambdaFuncParams(c, lambda.params);

        const func = try c.addUserLambda(@ptrCast(c.sym), @ptrCast(lambda));
        _ = try pushLambdaProc(c, func);

        const func_ret_t = try sema_type.resolveReturnType(c, lambda.ret);
        const params = c.func_param_stack.items[start..];
        const sig = try c.sema.ensureFuncSig(@ptrCast(params), func_ret_t);
        try c.resolveUserLambda(func, sig);

        try appendFuncParamVars(c, lambda.params, params);

        // Generate function body.
        try semaStmts(c, stmts);

        const lambda_ir = try popLambdaProc(c);
        return ExprResult.initOwned(lambda_ir);
    }
}

pub fn sema_ex_borrow2(c: *cy.Chunk, child: ExprResult, ex_borrow_t: *cy.Type, node: *ast.Node) !ExprResult {
    try checkPartialMoveWhole(c, child, "borrow", node);
    const eff_child = try sema.semaEnsureAddressable(c, child, node);

    const parent_local = eff_child.recParentLocal() orelse {
        if (eff_child.resType == .varSym) {
            return c.reportError("Cannot acquire exclusive borrow. Consider wrapping type in `Ex`.", node);
        } else {
            return c.reportError("Expected parent local.", node);
        }
    };

    try checkExclusiveBorrow(c, borrowOwnerOf(c, parent_local), node);

    const addr_of = try c.ir.newExpr(.address_of, ex_borrow_t, node, .{
        .expr = eff_child.ir,
    });
    var res = ExprResult.init2(addr_of);
    res.data.value.parent_local = parent_local;
    return res;
}

fn sema_ex_borrow(c: *cy.Chunk, child: ExprResult, node: *ast.Node) !ExprResult {
    const borrow_ex_t = try get_ex_borrow_type(c, child.type);
    return sema_ex_borrow2(c, child, borrow_ex_t, node);
}

fn semaBorrow(c: *cy.Chunk, child: ExprResult, node: *ast.Node) !ExprResult {
    try checkPartialMoveWhole(c, child, "borrow", node);
    // Assign expression to a temp to extend the lifetime.
    const eff_child = try semaEnsureAddressable(c, child, node);
    const borrow_t = try getBorrowType(c, eff_child.type);
    const addr_of = try c.ir.newExpr(.address_of, borrow_t, node, .{
        .expr = eff_child.ir,
    });
    var res = ExprResult.init2(addr_of);
    if (eff_child.recParentLocal()) |parent_local| {
        // Counted only when stored in a local (`bindBorrowLocal`). A temporary borrow ends with its statement.
        try checkSharedBorrow(c, borrowOwnerOf(c, parent_local), node);
        res.data.value.parent_local = parent_local;
    } else {
        res.data.value.parent_local = null;
    }
    return res;
}

fn sema_object(c: *cy.Chunk, impl: ExprResult, node: *ast.Node) !ExprResult {
    var b: InitBuilder = .{ .c = c };
    try b.begin(c.sema.object_t, 1, node);
    const impl_ptr = try semaBitcast(c, impl, c.sema.ptr_void_t, node);
    try b.pushArg(impl_ptr, node);
    const loc = b.end();
    return ExprResult.initOwned(loc);
}

fn semaInitPair(c: *cy.Chunk, pair_t: *cy.Type, key: ExprResult, val: ExprResult, node: *ast.Node) !ExprResult {
    var b: InitBuilder = .{ .c = c };
    try b.begin(pair_t, 2, node);
    try b.pushArg(key, node);
    try b.pushArg(val, node);
    const loc = b.end();
    return ExprResult.initOwned(loc);
}

fn sema_span(c: *cy.Chunk, span_t: *cy.Type, borrow: ExprResult, len: i64, node: *ast.Node) !ExprResult {
    const len_expr = try c.semaConst(@bitCast(len), c.sema.i64_t, node);
    var b: InitBuilder = .{ .c = c };
    try b.begin(span_t, 2, node);
    try b.pushArg(borrow, node);
    try b.pushArg(len_expr, node);
    const loc = b.end();
    return ExprResult.initOwned(loc);
}

fn sema_init_seq2(c: *cy.Chunk, init_seq: *cy.Sym, args: []*ir.Expr, node: *ast.Node) !ExprResult {
    const func_sym = try requireFuncSym(c, init_seq, node);
    const sig = func_sym.first.sig;
    if (sig.params_len != 1) {
        return c.reportError("Expected `@init_sequence` to have one parameter.", node);
    }
    const init_span_t = sig.params_ptr[0].get_type();
    const instance = init_span_t.sym().instance orelse {
        return c.reportError("Expected `[&]T` parameter.", node);
    };
    if (instance.getSymTemplate() != c.sema.span_tmpl) {
        return c.reportError("Expected `[&]T` parameter.", node);
    }
    const elem_t = instance.params[0].asPtr(*cy.Type);
    const borrow_t = try getBorrowType(c, elem_t);
    if (args.len == 0) {
        const ptr = try c.semaConst(0, c.sema.i64_t, node);
        const init_span = try sema_span(c, init_span_t, ptr, 0, node);
        return c.semaCallFuncSym1(func_sym, node, init_span, node);
    } else {
        return sema_call_init_span(c, func_sym, init_span_t, borrow_t, elem_t, args, node);
    }
}

fn semaInitSequence(c: *cy.Chunk, init_seq: *cy.Sym, lit: *ast.InitLit) !ExprResult {
    const node: *ast.Node = @ptrCast(lit);
    const func_sym = try requireFuncSym(c, init_seq, node);

    const sig = func_sym.first.sig;
    if (sig.params_len != 1) {
        return c.reportError("Expected `@init_sequence` to have one parameter.", node);
    }
    const span_t = sig.params_ptr[0].get_type();
    const instance = span_t.sym().instance orelse {
        return c.reportError("Expected `[&]T` parameter.", node);
    };
    if (instance.getSymTemplate() != c.sema.span_tmpl) {
        return c.reportError("Expected `[&]T` parameter.", node);
    }
    const elem_t = instance.params[0].asPtr(*cy.Type);
    const borrow_t = try getBorrowType(c, elem_t);
    if (lit.args.len == 0) {
        const ptr = try c.semaConst(0, borrow_t, node);
        const init_span = try sema_span(c, span_t, ptr, 0, node);
        return c.semaCallFuncSym1(func_sym, node, init_span, node);
    } else {
        const nargs = lit.args.len;
        const args = try c.ir.allocArray(*ir.Expr, nargs);
        {
            // An element is evaluated before a statement that a later element adds (`seqFlush`).
            const seq_start = c.seq_pending.items.len;
            defer seqPop(c, seq_start);
            for (lit.args.slice(), 0..) |arg, i| {
                var res = try c.semaExprCstr(arg, elem_t);
                res = try semaOwn(c, res, arg);
                args[i] = res.ir;
                try seqPush(c, &args[i], true, arg);
            }
        }
        return sema_call_init_span(c, func_sym, span_t, borrow_t, elem_t, args, node);
    }
}

/// init_record or init_sequence.
fn sema_call_init_span(c: *cy.Chunk, init: *cy.sym.FuncSym, span_t: *cy.Type, borrow_t: *cy.Type, elem_t: *cy.Type, args: []*ir.Expr, node: *ast.Node) !ExprResult {
    const vec_t = try getVectorType(c, elem_t, @intCast(args.len));
    const loc = try c.ir.newExpr(.init, vec_t, node, .{
        .nargs = @intCast(args.len), .args = args.ptr,
    });
    const array_var = try declareHiddenLocal(c, "_vec", vec_t, ExprResult.init(loc, vec_t), node);
    const array = try semaLocal(c, array_var.id, node);
    const addr_of = try c.ir.newExpr(.address_of, borrow_t, node, .{
        .expr = array.ir,
    });
    const borrow = ExprResult.init2(addr_of);
    const init_span = try sema_span(c, span_t, borrow, @intCast(args.len), node);
    const res = try c.semaCallFuncSym1(init, node, init_span, node);
    if (!elem_t.is_copyable()) {
        // Elements that can not be copied are moved. The initializer takes the bytes of the elements
        // (`@memcpy`), so the temporary vector is dead after the call and its elements are not destructed.
        c.varStack.items[array_var.id].type = .dead;
    }
    return res;
}

fn semaInitRecord(c: *cy.Chunk, init_pairs: *cy.Sym, init_n: *ast.InitLit) !ExprResult {
    const node: *ast.Node = @ptrCast(init_n);
    const func_sym = try requireFuncSym(c, init_pairs, node);

    // TODO: Check signature once per `sym`.
    const sig = func_sym.first.sig;
    if (sig.params_len != 1) {
        return c.reportError("Expected `@init_record` to have one parameter.", node);
    }
    const span_t = sig.params_ptr[0].get_type();
    const instance = sig.params_ptr[0].get_type().sym().instance orelse {
        return c.reportError("Expected `[&]Pair{_, _}` parameter.", node);
    };
    if (instance.getSymTemplate() != c.sema.span_tmpl) {
        return c.reportError("Expected `[&]Pair{_, _}` parameter.", node);
    }
    const pair_t = instance.params[0].asPtr(*cy.Type);
    const pair_instance = pair_t.sym().instance orelse {
        return c.reportError("Expected `[&]Pair{_, _}` parameter.", node);
    };
    const key_t = pair_instance.params[0].asPtr(*cy.Type);
    const val_t = pair_instance.params[1].asPtr(*cy.Type);
    const borrow_t = try getBorrowType(c, pair_t);
    if (init_n.args.len == 0) {
        const ptr = try c.semaConst(0, borrow_t, node);
        const init_span = try sema_span(c, span_t, ptr, 0, node);
        return c.semaCallFuncSym1(func_sym, node, init_span, node);
    } else {
        const pairs = try c.ir.allocArray(*ir.Expr, init_n.args.len);
        const seq_start = c.seq_pending.items.len;
        errdefer seqPop(c, seq_start);
        for (init_n.args.slice(), 0..) |arg, i| {
            if (arg.type() != .keyValue) {
                return c.reportError("Expected key value pair.", arg);
            }
            const kv = arg.cast(.keyValue);

            var key: ExprResult = undefined;
            if (kv.key.type() == .ident) {
                key = try c.semaString(kv.key.cast(.ident).name.slice(), kv.key);
            } else {
                key = try c.semaExprCstr(kv.key, key_t);
                key = try semaOwn(c, key, kv.key);
            }
            var val = try c.semaExprCstr(kv.value, val_t);
            val = try semaOwn(c, val, kv.value);
            const pair = try semaInitPair(c, pair_t, key, val, arg);
            pairs[i] = pair.ir;
            try seqPush(c, &pairs[i], true, arg);
        }
        seqPop(c, seq_start);
        return sema_call_init_span(c, func_sym, span_t, borrow_t, pair_t, pairs, node);
    }
}

pub fn semaInit2(c: *cy.Chunk, init_t: *cy.Type, arg0: ExprResult, arg1: ExprResult, node: *ast.Node) !ExprResult {
    var b: InitBuilder = .{ .c = c };
    try b.begin(init_t, 2, node);
    try b.pushArg2(arg0, arg0.type, node);
    try b.pushArg2(arg1, arg1.type, node);
    const irIdx = b.end();
    return ExprResult.initOwned(irIdx);
}

pub fn semaTraceNopFmt(c: *cy.Chunk, comptime format: []const u8, args: anytype, node: *ast.Node) !void {
    if (cy.Trace) {
        try semaNopFmt(c, format, args, node);
    }
}

pub fn semaNopFmt(c: *cy.Chunk, comptime format: []const u8, args: anytype, node: *ast.Node) !void {
    const start = c.ir.buf.items.len;
    try stdx.listWriter(&c.ir.buf, c.alloc).print(format, args);
    const len = c.ir.buf.items.len - start;
    _ = try c.ir.pushStmt(.nop_label, node, .{ .label_idx = start, .label_len = len });
}

pub fn semaNop(c: *cy.Chunk, label: []const u8, node: *ast.Node) !void {
    const start = c.ir.buf.items.len;
    try c.ir.buf.appendSlice(c.alloc, label);
    _ = try c.ir.pushStmt(.nop_label, node, .{ .label_idx = start, .label_len = label.len });
}

pub fn semaWrapSome(c: *cy.Chunk, option_t: *cy.types.Option, res: ExprResult, node: *ast.Node) !ExprResult {
    var owned = try semaOwn(c, res, node);
    if (option_t.zero_union) {
        owned = try semaBitcast(c, owned, &option_t.base, node);
        owned.owned = true;
        return owned;
    } else {
        const tag = try c.semaConst(1, c.sema.i64_t, node);
        return semaInit2(c, &option_t.base, tag, owned, node);
    }
}

pub fn semaInitCunionCase(c: *cy.Chunk, union_t: *cy.Type, case: u32, payload: ExprResult, node: *ast.Node) !ExprResult {
    var b: InitBuilder = .{ .c = c };
    try b.begin(union_t, 1, node);
    const case_arg = try c.ir.newExpr(.init_case, union_t, node, .{
        .child = payload.ir,
        .case = case,
    });
    const final_payload = ExprResult.init2(case_arg);
    try b.pushArg2(final_payload, union_t, node);
    const irIdx = b.end();
    return ExprResult.initOwned(irIdx);
}

fn semaInitCunionNoPayload(c: *cy.Chunk, union_t: *cy.Type, case: u32, node: *ast.Node) !ExprResult {
    // No payload type.
    var b: InitBuilder = .{ .c = c };
    try b.begin(union_t, 1, node);
    const payload = try c.semaVoid(node);
    const case_arg = try c.ir.newExpr(.init_case, union_t, node, .{
        .child = payload.ir,
        .case = case,
    });
    const final_payload = ExprResult.init2(case_arg);
    try b.pushArg2(final_payload, union_t, node);
    const irIdx = b.end();
    return ExprResult.initOwned(irIdx);
}

pub fn semaInitChoice(c: *cy.Chunk, union_t: *cy.Type, case: u32, val: u32, payload: ExprResult, node: *ast.Node) !ExprResult {
    var b: InitBuilder = .{ .c = c };
    try b.begin(union_t, 2, node);
    const tag = try c.semaConst(val, c.sema.i64_t, node);
    try b.pushArg(tag, node);
    const case_arg = try c.ir.newExpr(.init_case, union_t, node, .{
        .child = payload.ir,
        .case = case,
    });
    const final_payload = ExprResult.init2(case_arg);
    try b.pushArg2(final_payload, union_t, node);
    const irIdx = b.end();
    return ExprResult.initOwned(irIdx);
}

fn semaInitChoiceNoPayload(c: *cy.Chunk, case: *cy.sym.ChoiceCase, node: *ast.Node) !ExprResult {
    // No payload type.
    var b: InitBuilder = .{ .c = c };
    try b.begin(case.type, 2, node);
    const tag = try c.semaConst(case.val, c.sema.i64_t, node);
    try b.pushArg(tag, node);
    const payload = try c.semaVoid(node);
    const case_arg = try c.ir.newExpr(.init_case, case.type, node, .{
        .child = payload.ir,
        .case = case.idx,
    });
    const final_payload = ExprResult.init2(case_arg);
    try b.pushArg2(final_payload, case.type, node);
    const irIdx = b.end();
    return ExprResult.initOwned(irIdx);
}

const VarResult = struct {
    id: LocalId,
    fromParentBlock: bool,
};

fn popLambdaProc(c: *cy.Chunk) !*ir.Expr {
    const proc = c.proc();
    const params = c.getProcParams(proc);
    
    const captures = try proc.captures.toOwnedSlice(c.alloc);
    try procPrologue(c);
    const stmtBlock = try popProc(c);

    const ir_params = try c.ir.allocArray(ir.FuncParam, params.len);
    for (params, 0..) |param, i| {
        ir_params[i] = .{
            .reg = param.inner.local.id,
            .namePtr = param.namePtr,
            .nameLen = param.nameLen,
            .declType = param.decl_t,
        };
    }

    var captures_data: []u8 = &.{};
    var type_: *cy.Type = undefined;
    var captures_scope_locals = false;
    if (captures.len > 0) {
        captures_data = try c.ir.allocArray(u8, captures.len);
        for (captures, 0..) |info, i| {
            const pId = info.parent_var_idx;
            const pvar = c.varStack.items[pId];
            captures_data[i] = pvar.inner.local.id;
            if (!info.val_t.isRefPointer()) {
                captures_scope_locals = true;
            }
        }
        c.alloc.free(captures);
        const funcptr_t = try getFuncPtrType(c, proc.func.?.sig);
        if (captures_scope_locals) {
            type_ = try getOpaqueFuncType(c, funcptr_t);
        } else {
            type_ = try getFuncType(c, funcptr_t);
        }
    } else {
        type_ = try getFuncPtrType(c, proc.func.?.sig);
    }

    proc.ir.cast(.funcBlock).* = .{
        .func = proc.func.?,
        .bodyHead = stmtBlock.first,
        .parentType = null,
        .params = ir_params.ptr,
    };

    proc.func.?.info.emitted = true;
    proc.func.?.info.escaped = true;
    proc.func.?.data = .{ .userLambda = .{
        .func_block_ir = proc.ir,
        .is_closure = captures.len > 0,
    }};
    return c.ir.newExpr(.lambda, type_, proc.node, .{
        .func = proc.func.?,
        .numCaptures = @as(u8, @intCast(captures.len)),
        .captures = captures_data.ptr,
        .pinned_closure = captures_scope_locals,
    });
}

pub fn procPrologue(c: *cy.Chunk) !void {
    const proc = c.proc();

    if (c.block().endReachable) {
        if (proc.func != null and proc.func.?.info.generator) {
            const b = c.procBlock(); 
            try semaDestructBlock2(c, b);

            const gen_t = proc.func.?.sig.ret.cast(.pointer).child_t;
            const funcptr_t = gen_t.instanceOf(c.sema.generator_tmpl).?.params[0].asPtr(*cy.Type);
            const val_t = funcptr_t.cast(.func_ptr).sig.ret;
            const opt_t = try getOptionType(c, val_t);
            const none = try c.semaNone(opt_t, proc.node);
            _ = try c.ir.pushStmt(.set_ret, proc.node, .{
                .right = none.ir,
            });
            _ = try c.ir.pushStmt(.yield, proc.node, .{
                .deinit_head = null,
                .ret_opt_t = opt_t,
                .end = true,
            });
            c.block().endReachable = false;
        } else {
            const ret_t = proc.getReturnType(c.sema);
            if (ret_t.id() == bt.Void or (ret_t.kind() == .result and ret_t.cast(.result).child_t.id() == bt.Void)) {
                _ = try semaReturn(c, proc.node);
            } else {
                return c.reportError("Missing return statement.", proc.node);
            }
        }
    }
}

pub fn popFuncBlock(c: *cy.Chunk) !void {
    const proc = c.proc();

    // Insert a trap instruction to catch missing returns.
    // Could mean the function prologue wasn't emitted or bad reachable analysis.
    if (cy.Trace) {
        _ = try c.ir.pushStmt(.trap, proc.node, .{});
    }

    const params = c.getProcParams(proc);
    const stmtBlock = try popProc(c);

    const ir_params = try c.ir.allocArray(ir.FuncParam, params.len);
    for (params, 0..) |param, i| {
        ir_params[i] = .{
            .reg = param.inner.local.id,
            .namePtr = param.namePtr,
            .nameLen = param.nameLen,
            .declType = param.decl_t,
        };
    }

    const func = proc.func.?;
    const parentType: ?*cy.Type = if (func.isMethod()) params[0].decl_t else null;

    // Patch `pushFuncBlock` with maxLocals and param copies.
    proc.ir.cast(.funcBlock).* = .{
        .func = proc.func.?,
        .bodyHead = stmtBlock.first,
        .parentType = parentType,
        .params = ir_params.ptr,
    };

    func.info.emitted = true;

    if (func.type == .userFunc) {
        func.data.userFunc.loc = proc.ir;
    } else if (func.type == .extern_) {
        func.data.extern_.ir = proc.ir.cast(.funcBlock);
    } else {
        @panic("unexpected");
    }
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
    panic_fn: *cy.Func = undefined,
    panic_unwrap_error_fn: *cy.Func = undefined,
    track_main_local_fn: *cy.Func = undefined,
    main_result_fn: *cy.Func = undefined,
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

/// `buf` is assumed to be big enough.
pub fn unescapeString(buf: []u8, literal: []const u8, always_copy: bool) ![]const u8 {
    var i = std.mem.findScalar(u8, literal, '\\') orelse {
        if (always_copy) {
            @memcpy(buf[0..literal.len], literal);
            return buf[0..literal.len];
        } else {
            return literal;
        }
    };
    @memcpy(buf[0..i], literal[0..i]);
    var len = i;
    var res = try unescapeSeq(literal[i+1..]);
    buf[len] = res.char;
    len += 1;
    var rest = literal[i+1+res.advance..];

    while (true) {
        i = std.mem.findScalar(u8, rest, '\\') orelse break;
        @memcpy(buf[len..len+i], rest[0..i]);
        len += i;
        res = try unescapeSeq(rest[i+1..]);
        buf[len] = res.char;
        len += 1;
        rest = rest[i+1+res.advance..];
    }

    @memcpy(buf[len..len+rest.len], rest);
    return buf[0..len+rest.len];
}

const CharAdvance = struct {
    char: u8,
    advance: u8,

    fn init(char: u8, advance: u8) CharAdvance {
        return CharAdvance{ .char = char, .advance = advance };
    }
};

pub fn unescapeSeq(seq: []const u8) !CharAdvance {
    if (seq.len == 0) {
        return error.MissingEscapeSeq;
    }
    switch (seq[0]) {
        'a' => {
            return CharAdvance.init(0x07, 1);
        },
        'b' => {
            return CharAdvance.init(0x08, 1);
        },
        'e' => {
            return CharAdvance.init(0x1b, 1);
        },
        'n' => {
            return CharAdvance.init('\n', 1);
        },
        'r' => {
            return CharAdvance.init('\r', 1);
        },
        't' => {
            return CharAdvance.init('\t', 1);
        },
        '\\' => {
            return CharAdvance.init('\\', 1);
        },
        '"' => {
            return CharAdvance.init('"', 1);
        },
        '\'' => {
            return CharAdvance.init('\'', 1);
        },
        '0' => {
            return CharAdvance.init('"', 1);
        },
        '`' => {
            return CharAdvance.init('`', 1);
        },
        'x' => {
            if (seq.len < 3) {
                return error.InvalidEscapeSeq;
            }
            const ch = try std.fmt.parseInt(u8, seq[1..3], 16);
            return CharAdvance.init(ch, 3);
        },
        else => {
            return error.InvalidEscapeSeq;
        }
    }
}

test "sema internals." {
    // `Local` holds a bare union, which carries a hidden tag only with runtime safety.
    // The borrow tracking fields (`active_ex_borrows`, `ex_borrow`) added a word in 2026-11 (F-25).
    if (cy.is32Bit) {
        try t.eq(if (std.debug.runtime_safety) 44 else 40, @sizeOf(Local));
        try t.eq(16, @sizeOf(FuncSig));
    } else {
        try t.eq(if (std.debug.runtime_safety) 64 else 56, @sizeOf(Local));
        try t.eq(24, @sizeOf(FuncSig));
    }
}

pub const InitBuilder = struct {
    ir: *ir.Expr = undefined,
    irArgs: []*ir.Expr = undefined,

    /// Generic typeId so choice types can also be instantiated.
    type: *cy.Type = undefined,
    fields: []const cy.types.Field = undefined,

    c: *cy.Chunk,
    argIdx: u32 = undefined,

    pub fn begin(b: *InitBuilder, type_: *cy.Type, numFields: usize, node: *ast.Node) !void {
        b.type = type_;
        b.irArgs = try b.c.ir.allocArray(*ir.Expr, numFields);
        b.ir = try b.c.ir.newExpr(.init, type_, node, .{
            .nargs = @as(u8, @intCast(numFields)), .args = b.irArgs.ptr,
        });
        b.argIdx = 0;
        b.fields = type_.fields().?;
    }

    pub fn pushArg(b: *InitBuilder, expr: ExprResult, node: *ast.Node) !void {
        try b.pushArg2(expr, b.fields[b.argIdx].type, node);
    }

    pub fn pushArg2(b: *InitBuilder, expr: ExprResult, exp_t: *cy.Type, node: *cy.ast.Node) !void {
        std.debug.assert(b.argIdx < b.fields.len);
        if (expr.type != exp_t) {
            return b.c.reportErrorFmt("Expected type {}, found {}", &.{v(exp_t.name()), v(expr.type.name())}, node);
        }
        b.irArgs[b.argIdx] = expr.ir;
        b.argIdx += 1;
    }

    pub fn end(b: *InitBuilder) *ir.Expr {
        return b.ir;
    }
};

fn getUnOpName(op: cy.UnaryOp) []const u8 {
    return switch (op) {
        .minus => "-",
        .bitwiseNot => "~",
        else => @panic("unsupported"),
    };
}

fn getBinOpName(op: cy.BinaryExprOp) []const u8 {
    return switch (op) {
        .index => "@index",
        .less => "<",
        .greater => ">",
        .less_equal => "<=",
        .greater_equal => ">=",
        .minus => "-",
        .plus => "+",
        .star => "*",
        .slash => "/",
        .percent => "%",
        .caret => "^",
        .bitwiseAnd => "&&",
        .bitwiseOr => "||",
        .bitwiseXor => "~",
        .bitwiseLeftShift => "<<",
        .bitwiseRightShift => ">>",
        else => @panic("unsupported"),
    };
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

pub fn semaTryStringLitCodepoint(c: *cy.Chunk, lit: []const u8, bits: u32, node: *ast.Node) !?cy.Value {
    if (lit.len == 0) {
        return null;
    }
    if (lit[0] == '\\') {
        const res = unescapeSeq(lit[1..]) catch |err| {
            return c.reportErrorFmt("Unescape error: {}", &.{v(err)}, node);
        };
        if (lit.len > res.advance + 1) {
            return null;
        }

        return Value.initRaw(res.char);
    } else {
        const len = std.unicode.utf8ByteSequenceLength(lit[0]) catch {
            return null;
        };
        if (lit.len != len) {
            return null;
        }
        const val = stdx.utf8Decode(lit[0..0+len]) catch {
            return null;
        };
        if (val <= 0xFF) {
            const byte: u8 = @intCast(val);
            return Value.initRaw(byte);
        } else {
            if (bits >= 32) {
                return Value.initRaw(val);
            } else {
                return null;
            }
        }
    }
}

pub fn semaStringLitCodepoint(c: *cy.Chunk, lit: []const u8, node: *ast.Node) !u64 {
    if (lit.len == 0) {
        return c.reportErrorFmt("Invalid UTF-8 Rune.", &.{}, node);
    }
    var val: u64 = undefined;
    if (lit[0] == '\\') {
        const res = unescapeSeq(lit[1..]) catch |err| {
            return c.reportErrorFmt("Unescape error: {}", &.{v(err)}, node);
        };
        val = res.char;
        if (lit.len > res.advance + 1) {
            return c.reportErrorFmt("Invalid escape sequence.", &.{}, node);
        }
    } else {
        const len = std.unicode.utf8ByteSequenceLength(lit[0]) catch {
            return c.reportErrorFmt("Invalid UTF-8 Rune.", &.{}, node);
        };
        if (lit.len != len) {
            return c.reportErrorFmt("Invalid UTF-8 Rune.", &.{}, node);
        }
        val = stdx.utf8Decode(lit[0..0+len]) catch {
            return c.reportErrorFmt("Invalid UTF-8 Rune.", &.{}, node);
        };
    }
    return val;
}

pub fn semaUnwrapOrStmt(c: *cy.Chunk, opt: ExprResult, res_ir_id: u32, outer: usize, node: *ast.Node) !void {
    const Data = struct {
        node: *ast.Node,
        res_ir_id: u32,
    };
    const S = struct {
        fn body(c_: *cy.Chunk, opt_id: u32, opt_local: ExprResult, data_: *anyopaque) !void {
            const data: *Data = @ptrCast(@alignCast(data_));
            const unwrap_res = try semaUnwrapOptionNoCheck(c_, opt_local, data.node);
            _ = try c_.ir.pushStmt(.set_local, data.node, .{
                .id = @intCast(data.res_ir_id),
                .right = unwrap_res.ir,
            });
            // Invalidate option container. Wrapped inner was moved.
            c_.varStack.items[opt_id].type = .dead;
        }
    };
    var data = Data{
        .node = node,
        .res_ir_id = res_ir_id,
    };
    try semaIfUnwrapBlock2(c, opt, node, null, S.body, @ptrCast(&data), outer, false, node);
}

fn semaFitTarget(c: *cy.Chunk, expr: ExprResult, target_t: *cy.Type, node: *ast.Node) !?ExprResult {
    switch (target_t.kind()) {
        .struct_t => {
            // if (target_t.id() == bt.Object and expr.type.id() != bt.Object) {
            //     if (expr.type.isObjectLike()) {
            //         // Ensure `deinitObject` for child type.
            //         if (expr.type.kind() == .pointer) {
            //             _ = try getDeinitObjFunc(c, expr.type.getRefLikeChild().?, node);
            //         } else {
            //             _ = try getDeinitObjFunc(c, expr.type, node);
            //         }

            //         // Cast.
            //         var owned = try semaOwn(c, expr, node);
            //         owned = try sema_object(c, owned, node);
            //         owned.owned = true;
            //         return owned;
            //     }
            // }
        },
        .option => {
            // Check if type is compatible with Optional's some payload.
            const child_t = target_t.cast(.option).child_t;
            if (expr.type.id() == child_t.id()) {
                return try semaWrapSome(c, target_t.cast(.option), expr, node);
            }
        },
        .result => {
            if (expr.type.id() == bt.Error) {
                return try semaInitChoice(c, target_t, 0, 0, expr, node);
            }

            const child_t = target_t.cast(.result).child_t;
            if (expr.type.id() == child_t.id()) {
                const owned = try semaOwn(c, expr, node);
                return try semaInitChoice(c, target_t, 1, 1, owned, node);
            }

            // Does not match the child type. Attempt to fit child type.
            // T -> !S
            // T -> !?T
            if (try semaFitTarget(c, expr, child_t, node)) |new| {
                return try semaInitChoice(c, target_t, 1, 1, new, node);
            }
        },
        .ref_trait => {
            if (expr.type.isRefPointer()) {
                const child_t = expr.type.cast(.pointer).child_t;
                if (child_t.kind() == .struct_t) {
                    if (child_t.cast(.struct_t).implements(target_t.cast(.ref_trait).generic)) {
                        _ = try getDeinitObjFunc(c, child_t, node);
                        const loc = try c.ir.newExpr(.trait, target_t, node, .{
                            .ref = expr.ir,
                            .impl_t = child_t,
                            .trait_t = target_t,
                            .generic_t = target_t.cast(.ref_trait).generic,
                        });
                        return ExprResult.initOwned(loc);
                    }
                }
            }
        },
        .borrow => {
            // Implicit Ref to Borrow.
            const borrow = target_t.cast(.borrow);
            if (expr.type.isRefPointer()) {
                if (borrow.child_t.id() == expr.type.cast(.pointer).child_t.id()) {
                    return try semaBitcast(c, expr, target_t, node);
                }
            }
            if (borrow.child_t.kind() == .func) {
                if (expr.type.kind() == .func_ptr) {
                    const ir_expr = try c.ir.newExpr(.func, borrow.child_t, node, .{
                        .expr = expr.ir,
                    });
                    const new = ExprResult.initOwned(ir_expr);
                    return try semaBorrow(c, new, node);
                }
            }
        },
        .borrow_trait => {
            if (expr.type.kind() == .borrow) {
                const child_t = expr.type.cast(.borrow).child_t;
                if (child_t.kind() == .struct_t) {
                    if (child_t.cast(.struct_t).implements(target_t.cast(.borrow_trait).generic)) {
                        const loc = try c.ir.newExpr(.trait, target_t, node, .{
                            .ref = expr.ir,
                            .impl_t = child_t,
                            .trait_t = target_t,
                            .generic_t = target_t.cast(.borrow_trait).generic,
                        });
                        return ExprResult.init(loc, target_t);
                    }
                }
            }
        },
        .func_ptr => {
            if (expr.type.id() == c.sema.ptr_void_t.id()) {
                return try semaBitcast(c, expr, target_t, node);
            }
        },
        .func => {
            if (expr.type.kind() == .func_ptr and expr.type.cast(.func_ptr).sig == target_t.cast(.func).sig) {
                const loc = try c.ir.newExpr(.func, target_t, node, .{
                    .expr = expr.ir,
                });
                return ExprResult.initOwned(loc);
            }
        },
        .pointer => {
            const target_ptr = target_t.cast(.pointer);

            // Ptr[T] -> Ptr[void]
            if (target_t.id() == c.sema.ptr_void_t.id()) {
                if (expr.type.isPointer()) {
                    return try semaBitcast(c, expr, target_t, node);
                }
                if (expr.type.kind() == .func_ptr) {
                    return try semaBitcast(c, expr, target_t, node);
                }
            }

            // Ptr[void] -> Ptr[T] (mimics unsafe C)
            if (expr.type.id() == c.sema.ptr_void_t.id() and target_t.isPointer()) {
                return try semaBitcast(c, expr, target_t, node);
            }

            if (expr.type.isPointer()) {
                const expr_ptr = expr.type.cast(.pointer);
                // Ptr[Int[Bits]] -> Ptr[Raw[Bits]] (mimics unsafe C)
                if (expr_ptr.child_t.kind() == .int and target_ptr.child_t.kind() == .raw) {
                    if (expr_ptr.child_t.cast(.int).bits == target_ptr.child_t.cast(.raw).bits) {
                        return try semaBitcast(c, expr, target_t, node);
                    }
                }
                // Ptr[Raw[Bits]] -> Ptr[Int[Bits]] (mimics unsafe C)
                if (expr_ptr.child_t.kind() == .raw and target_ptr.child_t.kind() == .int) {
                    if (expr_ptr.child_t.cast(.raw).bits == target_ptr.child_t.cast(.int).bits) {
                        return try semaBitcast(c, expr, target_t, node);
                    }
                }
            }

            // &T -> Ptr[T]
            if (!target_ptr.ref and expr.type.kind() == .borrow) {
                const borrow_t = expr.type.cast(.borrow);
                if (target_ptr.child_t.id() == borrow_t.child_t.id()) {
                    return try semaBitcast(c, expr, target_t, node);
                }

                // &Int[Bits] -> Ptr[Raw[Bits]]
                if (target_ptr.child_t.kind() == .raw and borrow_t.child_t.kind() == .int) {
                    if (borrow_t.child_t.cast(.int).bits == target_ptr.child_t.cast(.raw).bits) {
                        return try semaBitcast(c, expr, target_t, node);
                    }
                }

                // &Raw[Bits] -> Ptr[Int[Bits]]
                if (target_ptr.child_t.kind() == .int and borrow_t.child_t.kind() == .raw) {
                    if (borrow_t.child_t.cast(.raw).bits == target_ptr.child_t.cast(.int).bits) {
                        return try semaBitcast(c, expr, target_t, node);
                    }
                }
            }

            if (expr.type.kind() == .borrow) {
                // &T -> Ptr[void]
                if (target_t.id() == c.sema.ptr_void_t.id()) {
                    return try semaBitcast(c, expr, target_t, node);
                }

                const borrow_t = expr.type.cast(.borrow);

                // &[N]T -> Ptr[T]
                if (borrow_t.child_t.kind() == .vector) {
                    if (borrow_t.child_t.cast(.vector).elem_t.id() == target_ptr.child_t.id()) {
                        return try semaBitcast(c, expr, target_t, node);
                    }
                }

                // &[..N]T -> Ptr[T]
                if (borrow_t.child_t.kind() == .partial_vector) {
                    if (borrow_t.child_t.cast(.partial_vector).elem_t.id() == target_ptr.child_t.id()) {
                        const ptr = try semaBitcast(c, expr, target_t, node);
                        const offset = try semaConst(c, 8, c.sema.i64_t, node);
                        const add = try c.ir.newExpr(.add, target_t, node, .{
                            .left = ptr.ir,
                            .right = offset.ir,
                        });
                        return cy.sema.ExprResult.init2(add);
                    }
                }
            }
        },
        .float => {
            if (target_t.id() == bt.F64) {
                if (expr.type.id() == bt.F32) {
                    // f32 -> f64
                    const sym = try c.getResolvedSymOrFail(&c.sema.f64_t.sym().head, "@init", node);
                    const init_sym = try requireFuncSym(c, sym, node);
                    return try c.semaCallFuncSym1(init_sym, node, expr, node);
                }
            }
            // Int[] -> Float[]
            if (expr.type.kind() == .int) {
                return try semaIntToFloat(c, target_t, expr, node);
            }

            // Raw[] -> Float[]
            if (expr.type.kind() == .raw) {
                return try semaIntToFloat(c, target_t, expr, node);
            }
        },
        .int => {
            if (expr.type.kind() == .int) {
                const int_t = expr.type.cast(.int);
                const target_int_t = target_t.cast(.int);
                if (int_t.bits < target_int_t.bits) {
                    // Widen.
                    return try semaSext(c, target_t, int_t.bits, expr, node);
                }
            }
            if (expr.type.kind() == .raw) {
                const raw_t = expr.type.cast(.raw);
                const target_int_t = target_t.cast(.int);
                if (raw_t.bits == target_int_t.bits) {
                    return try semaBitcast(c, expr, target_t, node);
                }
                if (raw_t.bits < target_int_t.bits) {
                    // Widen.
                    return try semaZext(c, target_t, raw_t.bits, expr, node);
                }
            }
        },
        .raw => {
            const target_raw_t = target_t.cast(.raw);
            if (target_raw_t.distinct) {
                return null;
            }
            if (expr.type.kind() == .raw) {
                const raw_t = expr.type.cast(.raw);
                if (raw_t.distinct) {
                    return null;
                }
                if (raw_t.bits < target_raw_t.bits) {
                    // Widen.
                    return try semaZext(c, target_t, raw_t.bits, expr, node);
                }
            }

            // Int[] -> Raw[]
            if (expr.type.kind() == .int) {
                const int_t = expr.type.cast(.int);

                if (int_t.bits == target_raw_t.bits) {
                    return try semaBitcast(c, expr, target_t, node);
                }
                if (int_t.bits < target_raw_t.bits) {
                    // Widen.
                    return try semaZext(c, target_t, int_t.bits, expr, node);
                }
            }
        },
        else => {},
    }
    return null;
}

pub fn semaCZero(c: *cy.Chunk, type_: *cy.Type, node: *ast.Node) !ExprResult {
    switch (type_.id()) {
        bt.R8,
        bt.I8  => return c.semaConst8(0, type_, node),
        bt.Bool  => return c.semaFalse(node),
        bt.R16,
        bt.I16   => return c.semaConst16(0, type_, node),
        bt.R32,
        bt.F32,
        bt.I32   => return c.semaConst32(0, type_, node),
        bt.R64,
        bt.I64,
        bt.F64 => return c.semaConst(0, type_, node),
        else => {
            switch (type_.kind()) {
                .struct_t => {
                    const struct_t = type_.cast(.struct_t);
                    if (!struct_t.cstruct) {
                        const name = try c.sema.allocTypeName(type_);
                        defer c.alloc.free(name);
                        return c.reportErrorFmt("Unsupported zero initializer for `{}`. Can only zero initialize a `cstruct` type.", &.{v(name)}, node);
                    }
                    const ir_args = try c.ir.allocArray(*ir.Expr, struct_t.fields_len);
                    for (struct_t.fields(), 0..) |field, i| {
                        const arg = try semaCZero(c, field.type, node);
                        ir_args[i] = arg.ir;
                    }
                    const loc = try c.ir.newExpr(.init, @ptrCast(struct_t), node, .{
                        .nargs = @as(u8, @intCast(struct_t.fields_len)),
                        .args = ir_args.ptr,
                    });
                    return ExprResult.initOwned(loc);
                },
                .c_union => {
                    const union_t = type_.cast(.c_union);
                    const expr = try c.ir.newExpr(.init_zero, type_, node, .{ .size = union_t.size });
                    return ExprResult.initOwned(expr);
                },
                .vector => {
                    const array_t = type_.cast(.vector);
                    if (!array_t.elem_t.isCZeroEligible()) {
                        const name = try c.sema.allocTypeName(array_t.elem_t);
                        defer c.alloc.free(name);
                        return c.reportErrorFmt("Unsupported zero initializer for `{}`. Can only zero initialize a `cstruct` type.", &.{v(name)}, node);
                    }
                    const expr = try c.ir.newExpr(.init_zero, type_, node, .{ .size = array_t.size });
                    return ExprResult.initOwned(expr);
                },
                .func_ptr => {
                    const func_ptr = type_.cast(.func_ptr);
                    if (func_ptr.sig.extern_) {
                        return c.semaConst(0, type_, node);
                    }
                },
                .pointer => {
                    const pointer = type_.cast(.pointer);
                    if (!pointer.ref) {
                        return c.semaConst(0, type_, node);
                    }
                },
                else => {},
            }
            const name = try c.sema.allocTypeName(type_);
            defer c.alloc.free(name);
            return c.reportErrorFmt("Unsupported zero initializer for `{}`.", &.{v(name)}, node);
        },
    }
}

fn reportExpectedType(c: *cy.Chunk, exp_t: *cy.Type, act_t: *cy.Type, node: *ast.Node) anyerror {
    const exp_name = try c.sema.allocTypeName(exp_t);
    defer c.alloc.free(exp_name);
    const act_name = try c.sema.allocTypeName(act_t);
    defer c.alloc.free(act_name);
    return c.reportErrorFmt("Expected type `{}`, got `{}`.", &.{v(exp_name), v(act_name)}, node);
}

fn semaInferSignedLit(c: *cy.Chunk, literal: []const u8, target_t: *cy.Type, base: u8, node: *ast.Node) !?ExprResult {
    switch (target_t.id()) {
        bt.F32 => {
            const val = try std.fmt.parseFloat(f32, literal);
            return try c.semaConst32(@bitCast(val), target_t, node);
        },
        bt.F64 => {
            const val = try std.fmt.parseFloat(f64, literal);
            return try c.semaConst(@bitCast(val), target_t, node);
        },
        bt.R8 => {
            const val = try semaParseInt(c, u8, literal, base, node);
            return try c.semaConst8(val, target_t, node);
        },
        bt.I8 => {
            const val = try semaParseInt(c, i8, literal, base, node);
            return try c.semaConst8(@bitCast(val), target_t, node);
        },
        bt.R16 => {
            const val = try semaParseInt(c, u16, literal, base, node);
            return try c.semaConst16(val, target_t, node);
        },
        bt.I16 => {
            const val = try semaParseInt(c, i16, literal, base, node);
            return try c.semaConst16(@bitCast(val), target_t, node);
        },
        bt.R32 => {
            const val = try semaParseInt(c, u32, literal, base, node);
            return try c.semaConst32(val, target_t, node);
        },
        bt.I32 => {
            const val = try semaParseInt(c, i32, literal, base, node);
            return try c.semaConst32(@bitCast(val), target_t, node);
        },
        bt.R64 => {
            const val = try semaParseInt(c, u64, literal, base, node);
            return try c.semaConst(val, target_t, node);
        },
        bt.I64 => {
            const val = try semaParseInt(c, i64, literal, base, node);
            return try c.semaConst(@bitCast(val), target_t, node);
        },
        else => {
            if (target_t.kind() == .option) {
                return semaInferSignedLit(c, literal, target_t.cast(.option).child_t, base, node);
            } else if (target_t.kind() == .result) {
                return semaInferSignedLit(c, literal, target_t.cast(.result).child_t, base, node);
            }
        },
    }
    return null;
}

fn semaInferUnsignedLit(c: *cy.Chunk, literal: []const u8, target_t: *cy.Type, base: u8, node: *ast.Node) !?ExprResult {
    switch (target_t.id()) {
        // The digits are in `base`. They are not a decimal float literal.
        bt.F32 => {
            const int = try semaParseInt(c, u64, literal, base, node);
            const val: f32 = @floatFromInt(int);
            return try c.semaConst32(@bitCast(val), target_t, node);
        },
        bt.F64 => {
            const int = try semaParseInt(c, u64, literal, base, node);
            const val: f64 = @floatFromInt(int);
            return try c.semaConst(@bitCast(val), target_t, node);
        },
        bt.R8,
        bt.I8 => {
            const val = try semaParseInt(c, u8, literal, base, node);
            return try c.semaConst8(val, target_t, node);
        },
        bt.R16,
        bt.I16 => {
            const val = try semaParseInt(c, u16, literal, base, node);
            return try c.semaConst16(val, target_t, node);
        },
        bt.R32,
        bt.I32 => {
            const val = try semaParseInt(c, u32, literal, base, node);
            return try c.semaConst32(val, target_t, node);
        },
        bt.R64 => {
            const val = try semaParseInt(c, u64, literal, base, node);
            return try c.semaConst(val, target_t, node);
        },
        else => {
            if (target_t.kind() == .option) {
                return semaInferUnsignedLit(c, literal, target_t.cast(.option).child_t, base, node);
            } else if (target_t.kind() == .result) {
                return semaInferUnsignedLit(c, literal, target_t.cast(.result).child_t, base, node);
            }
        },
    }
    return null;
}

pub fn semaParseFloat(c: *cy.Chunk, comptime T: type, literal: []const u8, node: *ast.Node) !T {
    return std.fmt.parseFloat(T, literal) catch |err| {
        switch (err) {
            // error.Overflow => {
            //     return c.reportError("Parsing decimal literal overflows integer type.", node);
            // },
            error.InvalidCharacter => {
                return c.reportError("Parsed invalid character.", node);
            },
        }
        return err;
    };
}

pub fn semaParseInt(c: *cy.Chunk, comptime T: type, literal: []const u8, base: u8, node: *ast.Node) !T {
    return std.fmt.parseInt(T, literal, base) catch |err| {
        switch (err) {
            error.Overflow => {
                return c.reportError("Integer literal does not fit the target type.", node);
            },
            error.InvalidCharacter => {
                return c.reportError("Parsed invalid character.", node);
            },
        }
        return err;
    };
}

pub fn semaSext(c: *cy.Chunk, target_t: *cy.Type, src_bits: u32, expr: ExprResult, node: *ast.Node) !ExprResult {
    const ext = try c.ir.newExpr(.sext, target_t, node, .{
        .expr = expr.ir,
        .src_bits = src_bits,
    });
    return ExprResult.init2(ext);
}

pub fn semaZext(c: *cy.Chunk, target_t: *cy.Type, src_bits: u32, expr: ExprResult, node: *ast.Node) !ExprResult {
    const ext = try c.ir.newExpr(.zext, target_t, node, .{
        .expr = expr.ir,
        .src_bits = src_bits,
    });
    return ExprResult.init2(ext);
}

pub fn semaIntToFloat(c: *cy.Chunk, target_t: *cy.Type, int: ExprResult, node: *ast.Node) !ExprResult {
    const expr = try c.ir.newExpr(.i2f, target_t, node, .{
        .expr = int.ir,
    });
    return sema.ExprResult.init2(expr);
}

/// `@name` that names no declaration. It used to be a symbol literal.
fn reportOldSymbolLit(c: *cy.Chunk, at_name: []const u8, node: *ast.Node) anyerror {
    return c.reportErrorFmt("Undeclared `{}`. A symbol literal is written `symbol.{}`.", &.{v(at_name), v(at_name[1..])}, node);
}

/// Whether the chunk that holds `node` is one of the builtin modules (`core`, `meta`, ...). Only they declare
/// `@` functions other than the hooks and use the attributes that are reserved for the compiler.
pub fn isBuiltinModuleNode(c: *cy.Chunk, node: *ast.Node) bool {
    const src_id = node.src();
    if (src_id == cy.NullId) return true;
    return c.compiler.chunks.items[src_id].is_builtin;
}

/// A script can not name an intrinsic: the `@` functions of the builtin modules are the runtime's internals
/// (reference counts, object layout, VM instructions). `node` is the `@name` node.
pub fn checkIntrinsicUse(c: *cy.Chunk, node: *ast.Node) !void {
    if (isBuiltinModuleNode(c, node)) return;
    if (c.internal_callee == node) return;
    const name = node.cast(.at_lit).value.slice();
    return c.reportErrorFmt("`{}` is internal to the builtin modules and can not be used in a script.", &.{v(name)}, node);
}

/// The `@` functions that a script can declare. The compiler calls them by name.
/// `@size` is not one of them: it gives the allocation size that `@freeObject` is called with.
const hook_names = std.StaticStringMap(void).initComptime(.{
    .{"@init"}, .{"@init_sequence"}, .{"@init_record"},
    .{"@deinit"}, .{"@copy"}, .{"@clone"},
    .{"@index"}, .{"@set_index"}, .{"@index_addr"}, .{"@slice"},
    .{"@get"}, .{"@set"},
    .{"@send"},
});

fn sema_at_symbol(c: *cy.Chunk, name: []const u8, node: *ast.Node) !ExprResult {
    const id = try c.sema.ensureSymbol(name);
    return c.semaConst(@intCast(id), c.sema.symbol_t, node);
}

pub fn sema_expr_cstr_template(c: *cy.Chunk, node: *ast.Node, template: *cy.sym.Template) !ExprResult {
    const res = try c.semaExpr(node, .{});
    if (!res.type.isInstanceOf(template)) {
        const type_name = try c.sema.allocTypeName(res.type);
        defer c.alloc.free(type_name);
        return c.reportErrorFmt("Expected type instance of `{}`, found `{}`.", &.{v(template.head.name()), v(type_name)}, node);
    }
    return res;
}