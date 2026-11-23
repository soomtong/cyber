const std = @import("std");
const cy = @import("cyber.zig");
const ir = cy.ir;
const bt = cy.types.BuiltinTypes;
const sema_func = cy.sema_func;
const ct_inline = cy.ct_inline;
const Argument = cy.sema_func.Argument;
const fmt = cy.fmt;
const v = fmt.v;
const ast = cy.ast;
const log = cy.log.scoped(.sema);
const sema = cy.sema;
const sema_local = cy.sema_local;
const sema_borrow = cy.sema_borrow;
const sema_call = cy.sema_call;
const sema_expr = cy.sema_expr;
const sema_assign = cy.sema_assign;
const sema_access = cy.sema_access;
const sema_switch = cy.sema_switch;
const sema_move = cy.sema_move;
const sema_init = cy.sema_init;
const sema_lit = cy.sema_lit;

pub fn semaStmts(c: *cy.Chunk, stmts: []const *ast.Node) anyerror!void {
    const saved_ctx = c.stmt_ctx;
    defer c.stmt_ctx = saved_ctx;
    const comp = c.compiler;
    if (comp.recover and comp.recover_chunk == c) {
        // The first statements checked in a pass are those of the body.
        if (comp.recover_stmt_depth == null) comp.recover_stmt_depth = c.resolve_stack.items.len;
        if (comp.recover_skip.count() > 0) {
            var ends: BorrowEnds = .empty;
            defer ends.deinit(c.alloc);
            for (stmts, 0..) |stmt, i| {
                const var_start = c.varStack.items.len;
                c.stmt_ctx = .{ .stmts = stmts, .idx = i, .block = c.semaBlocks.items.len - 1 };
                try semaStmt(c, stmt);
                // A skipped declaration ends the block: the rest would report its names as undeclared.
                if (comp.recover_skip.contains(stmt) and declaresLocal(stmt)) return;
                try endBorrowsAfter(c, &ends, stmts, i, var_start);
            }
            return;
        }
    }
    var ends: BorrowEnds = .empty;
    defer ends.deinit(c.alloc);
    for (stmts, 0..) |stmt, i| {
        const var_start = c.varStack.items.len;
        c.stmt_ctx = .{ .stmts = stmts, .idx = i, .block = c.semaBlocks.items.len - 1 };
        try semaStmt(c, stmt);
        try endBorrowsAfter(c, &ends, stmts, i, var_start);
    }
}

const BorrowEnd = struct {
    local: sema.LocalId,
    /// The index of the last statement of the block that names the local.
    last: usize,
};

const BorrowEnds = std.ArrayListUnmanaged(BorrowEnd);

/// Non-lexical borrow lifetimes. A local of the block that can hold a borrow stops counting as a borrow of its owner
/// after the last statement of the block that names it, not at the end of the block. Only a local without a destructor
/// ends early: a destructor runs at the end of the block and could read the borrow. A statement names the local when
/// its source text has the name as a word, so a mention in a nested block, a lambda or a string interpolation counts.
/// See `docs/decisions/project_borrow_model.md` "비어휘적 수명".
fn endBorrowsAfter(c: *cy.Chunk, ends: *BorrowEnds, stmts: []const *ast.Node, i: usize, var_start: usize) !void {
    // A local of the REPL's top level is read by later inputs.
    if (c.vm.config.persist_main and c.proc().func == null and c.semaBlocks.items.len == 1) return;
    // The locals that the statement declared in this block.
    var id = var_start;
    while (id < c.varStack.items.len) : (id += 1) {
        const local = c.varStack.items[id];
        if (local.type != .local or local.inner.local.hidden) continue;
        if (!local.decl_t.info.borrow_only or local.decl_t.isManaged()) continue;
        const last = lastNamingStmt(c, stmts, i, local.name()) orelse continue;
        try ends.append(c.alloc, .{ .local = @intCast(id), .last = last });
    }
    // A local that another live local points into (`hr := &h`) keeps its borrows while that local lives: a borrow
    // that is read through it (`hr.b`) needs them. It ends after a later statement.
    var progress = true;
    while (progress) {
        progress = false;
        var j: usize = 0;
        while (j < ends.items.len) {
            const end = ends.items[j];
            if (end.last != i or sema_borrow.isPointedInto(c, end.local)) {
                j += 1;
                continue;
            }
            const local = &c.varStack.items[end.local];
            sema_borrow.unbindBorrowLocal(c, local);
            local.borrow_ended = true;
            _ = ends.swapRemove(j);
            progress = true;
        }
    }
    var j: usize = 0;
    while (j < ends.items.len) {
        if (ends.items[j].last != i) {
            j += 1;
            continue;
        }
        if (i + 1 < stmts.len) {
            ends.items[j].last = i + 1;
            j += 1;
        } else {
            // The end of the block ends it.
            _ = ends.swapRemove(j);
        }
    }
}

/// The index of the last statement from `i` on whose source text names `name`, or null when it can not be told.
pub fn lastNamingStmt(c: *cy.Chunk, stmts: []const *ast.Node, i: usize, name: []const u8) ?usize {
    const src_id = stmts[i].src();
    var last = i;
    var k = i + 1;
    while (k < stmts.len) : (k += 1) {
        if (stmts[k].src() != src_id) return null;
        const text = stmtText(c, stmts, k) orelse return null;
        if (namesWord(text, name)) last = k;
    }
    return last;
}

/// Whether `text` has `name` as a word. A word after one `.` is a member (`h.r`), not a local. One after `..` is.
fn namesWord(text: []const u8, name: []const u8) bool {
    return countNames(text, name) > 0;
}

/// How many times `text` has `name` as a word (`namesWord`).
pub fn countNames(text: []const u8, name: []const u8) usize {
    var n: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, text, pos, name)) |idx| {
        pos = idx + 1;
        const after = idx + name.len;
        if (after < text.len and sema_move.isIdentChar(text[after])) continue;
        if (idx > 0) {
            const prev = text[idx - 1];
            if (sema_move.isIdentChar(prev)) continue;
            if (prev == '.' and !(idx > 1 and text[idx - 2] == '.')) continue;
        }
        n += 1;
    }
    return n;
}

/// The source text of the statement `stmts[i]`, up to the next statement or the end of its last line.
pub fn stmtText(c: *cy.Chunk, stmts: []const *ast.Node, i: usize) ?[]const u8 {
    const stmt = stmts[i];
    const src = c.compiler.chunks.items[stmt.src()].src;
    const start = stmt.pos();
    var end: usize = undefined;
    if (i + 1 < stmts.len) {
        if (stmts[i + 1].src() != stmt.src()) return null;
        end = stmts[i + 1].pos();
    } else {
        end = stmt.end();
        if (end == cy.NullId) return null;
        while (end < src.len and src[end] != '\n') end += 1;
    }
    if (start == cy.NullId or start > end or end > src.len) return null;
    return src[start..end];
}

/// Whether a statement declares a name for the statements after it in its block.
fn declaresLocal(stmt: *ast.Node) bool {
    return switch (stmt.type()) {
        .var_decl => true,
        .ct_stmt => stmt.cast(.ct_stmt).child.type() == .var_decl,
        else => false,
    };
}

/// With error recovery, a statement that failed in an earlier pass of the body is skipped (`BodyRecover`).
/// The block is then taken as not reaching its end: a `return` that is skipped does not leave the function
/// without one.
/// When the statement fails, the innermost statement of the body that failed is recorded for the next pass.
pub fn semaStmt(c: *cy.Chunk, node: *ast.Node) !void {
    const comp = c.compiler;
    if (!comp.recover or comp.recover_chunk == null) return semaStmt2(c, node);
    if (comp.recover_skip.contains(node)) {
        if (c.semaBlocks.items.len > 0) c.block().endReachable = false;
        return;
    }
    const lens = comp.refLens();
    semaStmt2(c, node) catch |err| {
        if (comp.recover_failed_stmt == null and comp.recover_chunk == c and node.src() == c.id and
            comp.recover_stmt_depth == c.resolve_stack.items.len)
        {
            comp.recover_failed_stmt = node;
            comp.recover_failed_lens = lens;
        }
        return err;
    };
    // A failure inside that was handled is not one of the body's.
    comp.recover_failed_stmt = null;
}

fn semaExprStmt(c: *cy.Chunk, node: *ast.Node) !void {
    const var_start = c.varStack.items.len;
    const expr = try c.semaExpr(node, .{});
    try semaExprStmtEnd(c, expr, var_start, node);
}

/// The statement part of an expression statement, after the expression itself was analyzed.
pub fn semaExprStmtEnd(c: *cy.Chunk, expr: sema.ExprResult, var_start: usize, node: *ast.Node) !void {
    if (expr.resType == .ct_value and expr.data.ct_value.type.id() == bt.Void) {
        // A call that took a global ran already and left hidden locals (`restoreGlobal`).
        try sema_local.popLocals(c, var_start, node);
        return;
    }

    if (expr.type.id() != bt.Void and expr.type.id() != bt.Never) {
        const name = try c.sema.allocTypeName(expr.type);
        defer c.alloc.free(name);

        try sema_call.checkDroppedSliceResult(c, expr.type, node);
        if (expr.type.kind() == .result) {
            return c.reportErrorFmt("Expected to handle the error case for `{}`. Add `!` after the call to unwrap it, or handle the error with `!else` or `try`.", &.{v(name)}, node);
        } else {
            // The fix with the statement's own text, when it is short (`xs.pop()`).
            if (node.src() == c.id) {
                const text = c.ast.nodeString(node);
                if (text.len <= 60 and std.mem.indexOfScalar(u8, text, '\n') == null) {
                    return c.reportErrorFmt("Expected assignment to a variable or placeholder for `{}`. Write `_ = {}` to drop the value.", &.{v(name), v(text)}, node);
                }
            }
            return c.reportErrorFmt("Expected assignment to a variable or placeholder for `{}`. Write `_ = ...` to drop the value.", &.{v(name)}, node);
        }
    }

    _ = try c.ir.pushStmt(.discard, node, .{ .expr = expr.ir });
    if (expr.type.id() == bt.Never) {
        c.block().endReachable = false;
        // A `never` call does not return, so destructing its temporaries would be dead code.
        try sema_local.popLocals2(c, var_start, false, node);
        return;
    }
    try sema_local.popLocals(c, var_start, node);
}

fn semaStmt2(c: *cy.Chunk, node: *ast.Node) !void {
    // The borrow owners that the statement notes end with it (`noteBorrowOwner`).
    const saved_pending_start = c.borrow_pending_start;
    c.borrow_pending_start = @intCast(c.borrow_pending.items.len);
    defer {
        c.borrow_pending.items.len = c.borrow_pending_start;
        c.borrow_pending_start = saved_pending_start;
    }
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
            try semaScopeExitJoin(c, c.loopBlock(c.proc().block_start), node);
            try semaBreak(c, node);
            try sema_local.popLocals2(c, var_start, false, node);
        },
        .continueStmt => {
            const var_start = c.varStack.items.len;
            try semaScopeExitJoin(c, c.loopBlock(c.proc().block_start), node);
            try semaContinue(c, node);
            try sema_local.popLocals2(c, var_start, false, node);
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
            try sema_local.localDecl(c, node.cast(.var_decl), );
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
            if (try sema_call.semaOpAssignMethod(c, node)) return;
            try sema_assign.semaAssignStmt(c, node, stmt.left, node, .{ .rhsOpAssignBinExpr = true });
            return;
        },
        .assign_stmt => {
            const stmt = node.cast(.assign_stmt);
            try sema_assign.semaAssignStmt(c, node, stmt.left, stmt.right, .{});
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

            const wrap = try pushLoopWrap(c, node);
            const hidden = try sema_local.pushBlock(c, node);
            c.block().move_branch = .plain;
            {
                const iterable_n: *ast.Node = @ptrCast(stmt.iterable);
                var iterable_init = try c.semaExpr(stmt.iterable, .{});
                if (iterable_init.type.kind() == .borrow or iterable_init.type.kind() == .ex_borrow) {
                    // A borrowed iterable (`a &[]int`) is iterated in place, like `for a.* |x|:`. Borrowing the
                    // borrow asked for `iterator(&&[]int)`.
                    iterable_init = try sema_expr.semaDeref(c, iterable_init, iterable_n);
                }
                var iterable_expr = iterable_init;
                if (iterable_init.type.isRefPointer()) {
                    // The hidden local releases the ref at the end of the loop, so an existing local must be retained.
                    iterable_expr = try sema_move.semaOwn(c, iterable_expr, iterable_n);
                } else {
                    if (iterable_expr.type.info.borrow_only and iterable_expr.resType == .value and
                        iterable_expr.data.value.parent_local != null)
                    {
                        // A borrow container that a call gives (`for xs[..] |p|:`) is held by a local that borrows
                        // what it borrows, so an element borrows from that owner, not from a temporary value.
                        const owned = try sema_move.semaOwn(c, iterable_expr, iterable_n);
                        const span_v = try sema_local.declareHiddenLocal(c, "_span", owned.type, owned, iterable_n);
                        try sema_borrow.bindBorrowLocal(c, span_v.id, iterable_expr);
                        iterable_expr = try sema_expr.semaLocal(c, span_v.id, iterable_n);
                    }
                    iterable_expr = try sema_borrow.semaBorrow(c, iterable_expr, node);
                }
                const iterable_v = try sema_local.declareHiddenLocal(c, "_iterable", iterable_expr.type, iterable_expr, iterable_n);
                // The loop borrows the iterable until it ends.
                try sema_borrow.bindBorrowLocal(c, iterable_v.id, iterable_expr);
                // The iterator can keep a pointer into the value, so the value can not be replaced in the loop.
                c.varStack.items[iterable_v.id].borrow_inline = false;
                const iterable = try sema_expr.semaLocal(c, iterable_v.id, node);

                const iterator_sym = try c.accessResolvedSymOrFail(iterable_init.type, "iterator", iterable_n);
                var func_sym = try sema_call.requireFuncSym(c, iterator_sym, iterable_n);
                const iterator_init = try c.semaCallFuncSymRec(func_sym, iterable_n, iterable, &.{}, false, iterable_n);
                const iterator_v = try sema_local.declareHiddenLocal(c, "iterator", iterator_init.type, iterator_init, iterable_n);
                const iterator = try sema_expr.semaLocal(c, iterator_v.id, node);
                const iterator_borrow = try sema_borrow.semaBorrow(c, iterator, node);

                if (stmt.count) |count| {
                    if (count.type() != .ident) {
                        return c.reportError("Expected a variable name for the index.", count);
                    }
                }
                const counter_init = try c.semaConst(0, c.sema.i64_t, node);
                const counterv = try sema_local.declareHiddenLocal(c, "_counter", c.sema.i64_t, counter_init, node);

                const ClosureData = struct {
                    stmt: *ast.ForIterStmt,
                    counterv: sema_local.LocalResult,
                    outer: usize,
                };

                // Loop block.
                const outer = try sema_local.pushBlock(c, node);
                beginLoopBlock(c, wrap);
                {
                    // if iterator.next() -> i, each
                    const S = struct {
                        fn body(c_: *cy.Chunk, opt_id: u32, opt_local: sema.ExprResult, data_: *anyopaque) !void {
                            _ = opt_id;
                            _ = opt_local;
                            c_.block().move_branch = .plain;
                            const data: *ClosureData = @ptrCast(@alignCast(data_));
                            var counter_: sema.ExprResult = undefined;
                            if (data.stmt.count) |count| {
                                counter_ = try sema_expr.semaLocal(c_, data.counterv.id, @ptrCast(data.stmt));

                                // _count = _counter
                                const count_name = count.cast(.ident).name.slice();
                                _ = try sema_local.declareLocalInit(c_, count_name, c_.sema.i64_t, counter_, @ptrCast(data.stmt));
                            }

                            const block_idx = try sema_local.pushBlock(c_, @ptrCast(data.stmt));
                            c_.block().move_branch = .plain;
                            c_.semaBlocks.items[data.outer].pre_continue_block = @intCast(block_idx);
                            {
                                try semaStmts(c_, data.stmt.stmts);
                            }
                            if (!c_.block().endReachable) {
                                // The moves of the body are not on the way to the next iteration.
                                restoreMoves(c_, c_.block().moves_start);
                            }
                            // A move of the capture or of the index is a move in their block, which ends with the
                            // iteration.
                            endPlainBlockMoves(c_, block_idx);
                            // The capture and the index end with the body: a `continue` that jumps to the end of
                            // this block destructs them like this end does (`semaContinue`). A path that moved one
                            // and a path that did not then meet with nothing left to destruct.
                            if (c_.block().endReachable) {
                                try sema_local.semaDestructBlock2(c_, &c_.semaBlocks.items[block_idx - 1]);
                            }
                            const block = try sema_local.popBlock2(c_, false);
                            _ = try c_.ir.pushStmt(.block, @ptrCast(data.stmt), .{ .bodyHead = block.first });
                            for (c_.varStack.items[c_.block().varStart..]) |*local| {
                                local.type = .dead;
                            }

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
                    func_sym = try sema_call.requireFuncSym(c, next_sym, iterable_n);
                    const args = [2]sema_func.Argument{
                        sema_func.Argument.initReceiver(iterable_n, iterable),
                        sema_func.Argument.initPreResolved(iterable_n, iterator_borrow),
                    };
                    const next = try c.semaCallFuncSymRec2(func_sym, &args, iterable_n);
                    if (each_n != null and stmt.each.?.type() != .borrow and next.type.kind() == .option) {
                        // `for a |r|` copies each element (`next` of `Array` does). The capture of an `if` or
                        // `while` unwrap would take a `NoCopy` payload, and the error would come from `next`.
                        const elem_t = next.type.cast(.option).child_t;
                        if (elem_t.info.no_copy) return sema_expr.reportNoCopy(c, elem_t, each_n.?);
                    }

                    var closure_data = ClosureData{
                        .stmt = stmt,
                        .counterv = counterv,
                        .outer = outer,
                    };
                    // `next` of a vector or a span copies an element: the capture points where the element points.
                    const copies = std.mem.eql(u8, next_name, "next") and
                        (iterable_init.type.isInstanceOf(c.sema.vector_tmpl) or iterable_init.type.isInstanceOf(c.sema.span_tmpl));
                    const elem_of: ?sema.LocalId = if (copies) iterable_v.id else null;
                    _ = try semaIfUnwrapBlock2(c, next, node, each_n, elem_of, S.body, &closure_data, outer, true, @ptrCast(stmt));
                }
                restoreMoves(c, c.block().moves_start);
                const block = try sema_local.popBlock(c);
                _ = try c.ir.pushStmt(.loop_block, node, .{
                    .body_head = block.first,
                });
            }
            endPlainBlockMoves(c, hidden);
            const block = try sema_local.popBlock(c);
            _ = try c.ir.pushStmt(.block, @ptrCast(stmt), .{ .bodyHead = block.first });
            try popLoopWrap(c, wrap, node);
        },
        .for_range_stmt => {
            const stmt = node.cast(.for_range_stmt);

            const wrap = try pushLoopWrap(c, node);
            const var_start = c.varStack.items.len;

            const range_start = try c.semaExprTarget(stmt.start, c.sema.i64_t);
            if (range_start.type.kind() != .int) {
                return c.reportError("Expected integer type.", stmt.start);
            }
            const range_end = try c.semaExprCstr(stmt.end, range_start.type);

            const loop_idx = try sema_local.pushBlock(c, node);
            beginLoopBlock(c, wrap);

            var eachLocal: ?u8 = null;
            if (stmt.each) |each| {
                if (each.type() == .ident) {
                    const varId = try sema_local.declareLocal(c, each, range_start.type, false);
                    eachLocal = c.varStack.items[varId].inner.local.id;
                } else {
                    return c.reportErrorFmt("Unsupported each clause: {}", &.{v(each.type())}, each);
                }
            }

            const declHead = c.ir.getAndClearStmtBlock();

            try semaStmts(c, stmt.stmts);
            try checkLoopMoves(c, loop_idx, node);
            restoreMoves(c, c.block().moves_start);
            const stmtBlock = try sema_local.popBlock(c);

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
            try sema_local.popLocals(c, var_start, @ptrCast(stmt));
            try popLoopWrap(c, wrap, node);
        },
        .whileInfStmt => {
            const stmt = node.cast(.whileInfStmt);
            const wrap = try pushLoopWrap(c, node);
            _ = try sema_local.pushBlock(c, node);
            beginLoopBlock(c, wrap);
            {
                try semaStmts(c, stmt.stmts);
                try semaContinue(c, node);
            }
            const loop_has_break = c.block().loop_has_break;
            restoreMoves(c, c.block().moves_start);
            const stmtBlock = try sema_local.popBlock2(c, false);
            if (!loop_has_break) {
                c.block().endReachable = false;
            }
            _ = try c.ir.pushStmt(.loop_block, node, .{
                .body_head = stmtBlock.first,
            });
            try popLoopWrap(c, wrap, node);
        },
        .whileCondStmt => {
            const stmt = node.cast(.whileCondStmt);

            const wrap = try pushLoopWrap(c, node);
            _ = try sema_local.pushBlock(c, node);
            beginLoopBlock(c, wrap);
            {
                const cond = try c.semaExprCstr(stmt.cond, c.sema.bool_t);
                try checkLoopCondMoves(c, c.semaBlocks.items.len - 1, stmt.cond);
                _ = try sema_local.pushBlock(c, node);
                c.block().move_branch = .plain;
                {
                    try semaStmts(c, stmt.stmts);
                    try semaContinue(c, node);
                }
                const block = try sema_local.popBlock2(c, false);
                _ = try c.ir.pushStmt(.if_block, node, .{
                    .cond_expr = cond.ir,
                    .body_head = block.first,
                });
            }
            restoreMoves(c, c.block().moves_start);
            const block = try sema_local.popBlock(c);
            _ = try c.ir.pushStmt(.loop_block, node, .{
                .body_head = block.first,
            });
            try popLoopWrap(c, wrap, node);
        },
        .while_unwrap_stmt => {
            const stmt = node.cast(.while_unwrap_stmt);

            const wrap = try pushLoopWrap(c, node);
            const outer = try sema_local.pushBlock(c, node);
            beginLoopBlock(c, wrap);
            {
                const S = struct {
                    fn body(c_: *cy.Chunk, opt_id: u32, opt_local: sema.ExprResult, data: *anyopaque) !void {
                        _ = opt_id;
                        _ = opt_local;
                        c_.block().move_branch = .plain;
                        const stmt_: *ast.WhileUnwrapStmt = @ptrCast(@alignCast(data));
                        // The option expression is checked and owned by now.
                        try checkLoopCondMoves(c_, c_.semaBlocks.items.len - 2, stmt_.opt);
                        try semaStmts(c_, stmt_.stmts);
                        try semaContinue(c_, @ptrCast(stmt_));
                    }
                }; 
                const opt = try c.sema_expr_cstr_template(stmt.opt, c.sema.option_tmpl);
                _ = try semaIfUnwrapBlock2(c, opt, stmt.opt, stmt.capture, null, S.body, stmt, outer, true, @ptrCast(stmt));
            }
            restoreMoves(c, c.block().moves_start);
            const stmtBlock = try sema_local.popBlock(c);
            _ = try c.ir.pushStmt(.loop_block, node, .{
                .body_head = stmtBlock.first,
            });
            try popLoopWrap(c, wrap, node);
        },
        .switch_stmt => {
            try sema_switch.semaSwitchStmt(c, node.cast(.switch_stmt));
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
        .scope_stmt => {
            try sema_scope_stmt(c, node.cast(.scope_stmt));
        },
        .suspend_stmt => {
            // Gives control back to the `resume` call of the running fiber. The frames stay on the fiber's
            // stack, so nothing is copied or destructed here.
            const stmt = try c.ir.pushStmt(.suspend_, node, .{});
            try sema_call.semaCancelPad(c, @intFromPtr(stmt), node);
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
            const opt_t = try sema.getOptionType(c, val_t);
            if (yield.child) |child| {
                const var_start = c.varStack.items.len;
                var expr = try c.semaExprCstr(child, val_t);
                // The yielded value is handed to the consumer, which destructs it. A local stays alive in the
                // generator, so it is copied like a returned value.
                expr = try sema_move.semaOwn(c, expr, child);
                if (opt_t.cast(.option).zero_union) {
                    expr = try sema_expr.semaBitcast(c, expr, opt_t, child);
                } else {
                    const tag = try c.semaConst(1, c.sema.i64_t, child);
                    expr = try sema_init.semaInit2(c, opt_t, tag, expr, child);
                }
                _ = try c.ir.pushStmt(.set_ret, node, .{
                    .right = expr.ir,
                });
                // Emit deinit block.
                try c.ir.pushStmtBlock(c.alloc);
                {
                    const b = c.procBlock();
                    try sema_local.semaDestructBlock2(c, b);
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
                try sema_local.popLocals2(c, var_start, true, node);
            } else {
                return c.reportErrorFmt("TODO", &.{}, node);
            }
        },
        .returnStmt => {
            const proc = c.proc();
            if (proc.func == null) {
                return c.reportErrorFmt("Return statement is not allowed in the main block.", &.{}, node);
            }
            try checkReturnTypeKnown(c, "`return`", "(`fn(x T) -> U => expr`)", node);
            try semaScopeExitJoin(c, null, node);
            _ = try semaReturn(c, node);
        },
        .returnExprStmt => {
            const child = node.cast(.returnExprStmt).child;
            const proc = c.proc();
            if (proc.func == null) {
                return c.reportErrorFmt("Return statement is not allowed in the main block.", &.{}, node);
            }
            try checkReturnTypeKnown(c, "`return`", "(`fn(x T) -> U => expr`)", node);
            const retType = proc.getReturnType(c.sema);
            // The fibers are done before the result is evaluated.
            try semaScopeExitJoin(c, null, node);
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

pub fn check_locals(c: *cy.Chunk, exp_var_start: usize, node: *ast.Node) !void {
    if (exp_var_start != c.varStack.items.len) {
        return c.reportErrorFmt("Expected var_start {}, found {}.", &.{v(exp_var_start), v(c.varStack.items.len)}, node);
    }
}

pub fn semaBreakTo(c: *cy.Chunk, block_idx: usize, node: *ast.Node) !void {
    const start = c.proc().block_start;
    try sema_assign.checkAssignMoveJump(c, block_idx, node);
    const b = &c.semaBlocks.items[block_idx];
    try sema_local.semaDestructBlock2(c, b);
    _ = try c.ir.pushStmt(.break_, node, .{ .block_offset = @intCast(block_idx - start) });
    c.block().endReachable = false;
}

/// Begins the block that wraps a loop statement. A `break` that leaves the loop after it moved outer locals jumps
/// to the end of this block, past the destructors that `popLoopWrap` puts after the loop for the other ways out.
fn pushLoopWrap(c: *cy.Chunk, node: *ast.Node) !usize {
    const idx = try sema_local.pushBlock(c, node);
    c.block().move_branch = .plain;
    c.block().break_moves_start = @intCast(c.break_moves.items.len);
    c.block().moved_breaks_start = @intCast(c.moved_breaks.items.len);
    return idx;
}

/// Marks the current block as the loop block of the wrap block `wrap`.
fn beginLoopBlock(c: *cy.Chunk, wrap: usize) void {
    c.block().loop = true;
    c.block().move_branch = .plain;
    c.block().loop_wrap = @intCast(wrap);
}

/// Ends the wrap block of a loop (the current block), after the loop statement. The outer locals that a `break` moved
/// are destructed here for the other ways out of the loop (its end, a `break` that moved nothing), and before each
/// `break` that moved other locals, so they are dead after the loop on every path.
/// See `docs/decisions/project_last_use.md`.
fn popLoopWrap(c: *cy.Chunk, wrap: usize, node: *ast.Node) !void {
    const b = c.semaBlocks.items[wrap];
    const fall = b.endReachable;
    const all = try c.alloc.dupe(sema.LocalId, c.break_moves.items[b.break_moves_start..]);
    defer c.alloc.free(all);
    c.break_moves.items.len = b.break_moves_start;
    const breaks = try c.alloc.dupe(sema.MovedBreak, c.moved_breaks.items[b.moved_breaks_start..]);
    defer c.alloc.free(breaks);
    c.moved_breaks.items.len = b.moved_breaks_start;
    var moved_list: std.ArrayListUnmanaged(sema.LocalId) = .empty;
    defer moved_list.deinit(c.alloc);
    for (all) |id| {
        if (std.mem.indexOfScalar(sema.LocalId, moved_list.items, id) == null) try moved_list.append(c.alloc, id);
    }
    const moved = moved_list.items;
    // The youngest first.
    std.mem.sort(sema.LocalId, moved, {}, std.sort.desc(sema.LocalId));
    for (breaks) |br| {
        const own = all[br.start - b.break_moves_start..br.end - b.break_moves_start];
        if (own.len == moved.len) continue;
        // The `break` destructed the locals of the wrap block before the slot.
        try c.ir.pushStmtBlock(c.alloc);
        {
            errdefer _ = c.ir.popStmtBlock();
            try destructBranchEnd(c, moved, own, b.varStart, node);
        }
        br.slot.cast(.block).bodyHead = c.ir.popStmtBlock().first;
    }
    for (moved) |id| {
        if (fall) try sema_local.semaDestructLocal(c, &c.varStack.items[id], node);
        c.varStack.items[id].type = .dead;
    }
    endPlainBlockMoves(c, wrap);
    const block = try sema_local.popBlock(c);
    _ = try c.ir.pushStmt(.block, node, .{ .bodyHead = block.first });
    if (!fall and breaks.len == 0) {
        c.block().endReachable = false;
    }
    // A local of a block further out is a move of the enclosing branch or loop.
    for (moved) |id| {
        if (id < c.block().varStart) try c.branch_moves.append(c.alloc, id);
    }
}

/// Ends a block whose moves of outer locals are moves of the block around it (`MoveBranch.plain`): a local of that
/// block is moved like by a statement of it.
fn endPlainBlockMoves(c: *cy.Chunk, idx: usize) void {
    const parent_start = c.semaBlocks.items[idx - 1].varStart;
    var i: usize = c.semaBlocks.items[idx].moves_start;
    while (i < c.branch_moves.items.len) {
        if (c.branch_moves.items[i] >= parent_start) {
            _ = c.branch_moves.orderedRemove(i);
        } else i += 1;
    }
}

/// The moves of outer locals since `start` were made on paths that do not reach this point (they left with `return`
/// or a `break`): the locals are alive here.
fn restoreMoves(c: *cy.Chunk, start: usize) void {
    for (c.branch_moves.items[start..]) |id| {
        c.varStack.items[id].type = .local;
    }
    c.branch_moves.items.len = start;
}

/// The body of the loop block `idx` goes on to the next iteration here. A local that is declared outside the loop
/// and was moved on the way would be read again.
fn checkLoopMoves(c: *cy.Chunk, idx: usize, node: *ast.Node) !void {
    const b = c.semaBlocks.items[idx];
    if (b.loop_wrap == cy.NullId or !c.block().endReachable) return;
    const wrap_start = c.semaBlocks.items[b.loop_wrap].varStart;
    for (c.branch_moves.items[b.moves_start..]) |id| {
        if (id >= wrap_start) continue;
        const name = c.varStack.items[id].name();
        return c.reportErrorFmt("Cannot move `{}` here: it is declared outside the loop, and the next iteration reads it. A loop body can move it where it then leaves the loop with `break` or `return`, or gives it a value again. Borrow it with `&{}`.", &.{v(name), v(name)}, c.moved_sites.get(id) orelse node);
    }
}

/// The condition of a `while` loop (or the option of `while opt |v|`) was checked in the loop block `idx`. It runs
/// before every iteration, also the one that ends the loop: a local that is declared outside the loop can not move in
/// it. A move that stayed in `Chunk.branch_moves` would count as a move of a body that then leaves the loop.
fn checkLoopCondMoves(c: *cy.Chunk, idx: usize, node: *ast.Node) !void {
    const b = c.semaBlocks.items[idx];
    const wrap_start = c.semaBlocks.items[b.loop_wrap].varStart;
    for (c.branch_moves.items[b.moves_start..]) |id| {
        if (id >= wrap_start) continue;
        const name = c.varStack.items[id].name();
        return c.reportErrorFmt("Cannot move `{}` in the condition of a `while` loop: it is declared outside the loop, and the condition is evaluated before every iteration. Borrow it with `&{}`, or write `while:` and move it in the body where the body then leaves the loop with `break` or `return`.", &.{v(name), v(name)}, c.moved_sites.get(id) orelse node);
    }
}

/// A `break` of the loop block `idx` after the body moved outer locals: it jumps to the end of the wrap block of the
/// loop. Returns false when nothing was moved. The locals are dead after the loop: `popLoopWrap` destructs them on
/// the other ways out, and the ones that another such `break` moved in the slot before this one.
fn semaMovedBreak(c: *cy.Chunk, idx: usize, node: *ast.Node) !bool {
    const wrap = c.semaBlocks.items[idx].loop_wrap;
    if (wrap == cy.NullId or !c.block().endReachable) return false;
    const wb = &c.semaBlocks.items[wrap];
    var pending: std.ArrayListUnmanaged(sema.LocalId) = .empty;
    defer pending.deinit(c.alloc);
    for (c.branch_moves.items[c.semaBlocks.items[idx].moves_start..]) |id| {
        if (id >= wb.varStart) continue;
        if (std.mem.indexOfScalar(sema.LocalId, pending.items, id) == null) try pending.append(c.alloc, id);
    }
    if (pending.items.len == 0) return false;
    const start = c.proc().block_start;
    try sema_assign.checkAssignMoveJump(c, wrap, node);
    try sema_local.semaDestructBlock2(c, wb);
    const slot = try c.ir.pushStmt(.block, node, .{ .bodyHead = null });
    const moves_start = c.break_moves.items.len;
    try c.break_moves.appendSlice(c.alloc, pending.items);
    try c.moved_breaks.append(c.alloc, .{ .slot = slot, .start = @intCast(moves_start),
        .end = @intCast(c.break_moves.items.len) });
    _ = try c.ir.pushStmt(.break_, node, .{ .block_offset = @intCast(wrap - start) });
    c.block().endReachable = false;
    return true;
}

fn semaBreak(c: *cy.Chunk, node: *ast.Node) !void {
    const start = c.proc().block_start;
    const idx = c.loopBlock(start) orelse {
        return c.reportError("Expected parent loop block.", node);
    };
    try sema_assign.checkAssignMoveJump(c, idx, node);
    if (try semaMovedBreak(c, idx, node)) return;
    const b = &c.semaBlocks.items[idx];
    b.loop_has_break = true;
    try sema_local.semaDestructBlock2(c, b);
    _ = try c.ir.pushStmt(.break_, node, .{ .block_offset = @intCast(idx - start) });
    c.block().endReachable = false;
}

fn semaContinueTo(c: *cy.Chunk, block_idx: usize, node: *ast.Node) !void {
    const start = c.proc().block_start;
    try sema_assign.checkAssignMoveJump(c, block_idx, node);
    try checkLoopMoves(c, block_idx, node);
    const b = &c.semaBlocks.items[block_idx];
    try sema_local.semaDestructBlock2(c, b);
    _ = try c.ir.pushStmt(.continue_, node, .{ .block_offset = @intCast(block_idx - start) });
    c.block().endReachable = false;
}

fn semaContinue(c: *cy.Chunk, node: *ast.Node) !void {
    const start = c.proc().block_start;
    const idx = c.loopBlock(start) orelse {
        return c.reportError("Expected parent loop block.", node);
    };
    try sema_assign.checkAssignMoveJump(c, idx, node);
    try checkLoopMoves(c, idx, node);
    const b = &c.semaBlocks.items[idx];
    if (b.pre_continue_block != cy.NullId) {
        // With the locals of the block around the body (the capture and the index of `for xs |i, x|`): they are dead
        // after the body, whichever path moved them.
        const pre_cont_block = &c.semaBlocks.items[b.pre_continue_block - 1];
        try sema_local.semaDestructBlock2(c, pre_cont_block);
        _ = try c.ir.pushStmt(.break_, node, .{ .block_offset = @intCast(b.pre_continue_block - start) });
    } else {
        try sema_local.semaDestructBlock2(c, b);
        _ = try c.ir.pushStmt(.continue_, node, .{ .block_offset = @intCast(idx - start) });
    }
    c.block().endReachable = false;
}

/// An `!else` or `?else` block reaches its end. Says how it can end here: `return` only in a function, `break` and
/// `continue` only in a loop. The main block can not `return`, so it gets the other forms.
pub fn reportElseBlockEnd(c: *cy.Chunk, kind: enum { result, option }, node: *ast.Node) anyerror {
    const op: []const u8 = if (kind == .result) "!else" else "?else";
    const in_func = c.proc().func != null;
    const in_loop = c.loopBlock(c.proc().block_start) != null;
    const ends: []const u8 = if (in_func and in_loop)
        "`return`, `panic(...)`, `break` or `continue`"
    else if (in_func)
        "`return` or `panic(...)`"
    else if (in_loop)
        "`panic(...)`, `break` or `continue`"
    else
        "`panic(...)`";
    const other: []const u8 = if (in_func)
        ""
    else if (kind == .result)
        " To go on after the error at the top level, give a default value (`f() !else default`) or handle the error in a `try:` block with an `else:` block."
    else
        " To go on at the top level, give a default value (`x ?else default`) or unwrap it with `if x |v|:`.";
    return c.reportErrorFmt("An `{}` block must not reach its end. End it with {}.{}", &.{v(op), v(ends), v(other)}, node);
}

/// Assumes `expr` is owned or has unmanaged type.
pub fn semaReturnExpr(c: *cy.Chunk, expr: sema.ExprResult, node: *ast.Node) !void {
    _ = try c.ir.pushStmt(.set_ret, node, .{
        .right = expr.ir,
    });

    // TODO: Optimize to a single `ret_expr` if there were no destructors emitted.
    const b = c.procBlock();
    try sema_local.semaDestructBlock2(c, b);

    if (c.proc().func == null) {
        try sema.sema_program_deinit(c);
    }

    _ = try c.ir.pushStmt(.ret, node, .{
        .return_value = true,
    });
    c.block().endReachable = false;
}

pub fn semaReturn(c: *cy.Chunk, node: *ast.Node) !void {
    const proc = c.proc();
    const b = c.procBlock();
    const var_start = c.varStack.items.len;

    const ret_t = proc.getReturnType(c.sema);
    if (ret_t.id() == bt.Void) {
        try sema_local.semaDestructBlock2(c, b);

        if (c.proc().func == null) {
            try sema.sema_program_deinit(c);
        }

        _ = try c.ir.pushStmt(.ret, node, .{ .return_value = false });
    }
    if (ret_t.kind() == .result and ret_t.cast(.result).child_t.id() == bt.Void) {
        const voidv = try c.semaVoid(node);
        const expr = try sema_init.semaInitChoice(c, ret_t, 1, 1, voidv, node);
        try semaReturnExpr(c, expr, node);
    }
    try sema_local.popLocals2(c, var_start, false, node);
    c.block().endReachable = false;
}

pub fn semaReturnExprStmt(c: *cy.Chunk, child: *ast.Node, ret_opt: ?*cy.Type, node: *ast.Node) !*cy.Type {
    const proc = c.proc();
    if (proc.func != null and proc.func.?.info.generator) {
        const gen_t = c.proc().getReturnType(c.sema).cast(.pointer).child_t;
        const funcptr_t = gen_t.sym().instance.?.params[0].asPtr(*cy.Type);
        const val_t = funcptr_t.cast(.func_ptr).sig.ret;
        const opt_t = try sema.getOptionType(c, val_t);

        const var_start = c.varStack.items.len;
        var expr = try c.semaExprCstr(child, val_t);
        // Same as `yield`: the generator's locals are destructed below, so the result is a copy.
        expr = try sema_move.semaOwn(c, expr, child);
        if (opt_t.cast(.option).zero_union) {
            expr = try sema_expr.semaBitcast(c, expr, opt_t, child);
        } else {
            const tag = try c.semaConst(1, c.sema.i64_t, child);
            expr = try sema_init.semaInit2(c, opt_t, tag, expr, child);
        }
        _ = try c.ir.pushStmt(.set_ret, node, .{
            .right = expr.ir,
        });
        const b = c.procBlock();
        try sema_local.semaDestructBlock2(c, b);
        _ = try c.ir.pushStmt(.yield, node, .{
            .deinit_head = null,
            .ret_opt_t = opt_t,
            .end = true,
        });
        try sema_local.popLocals2(c, var_start, false, node);
        c.block().endReachable = false;
        return opt_t;
    }

    const var_start = c.varStack.items.len;
    // The borrow owners that the expression notes are checked against the `scope` parameter (`checkReturnOwners`).
    // A lambda body is checked inside the statement that has the lambda, which notes its own owners.
    const saved_pending_start = c.borrow_pending_start;
    c.borrow_pending_start = @intCast(c.borrow_pending.items.len);
    defer {
        c.borrow_pending.items.len = c.borrow_pending_start;
        c.borrow_pending_start = saved_pending_start;
    }

    var expr: sema.ExprResult = undefined;
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
    try sema_borrow.checkReturnOwners(c, expr, c.borrow_pending_start, node);

    if (moved_local) |local_id| {
        c.varStack.items[local_id].type = .dead;
        defer c.varStack.items[local_id].type = .local;
        try semaReturnExpr(c, expr, node);
    } else {
        expr = try sema_move.semaOwn(c, expr, child);
        try semaReturnExpr(c, expr, node);
    }
    try sema_local.popLocals2(c, var_start, false, node);
    return expr.type;
}

/// The tail of `semaExpr` with `reqTypeCstr` and `fit_target` set.
fn fitReturnType(c: *cy.Chunk, expr: sema.ExprResult, ret_t: *cy.Type, node: *ast.Node) !sema.ExprResult {
    if (expr.type == ret_t) {
        return expr;
    }
    if (try sema_lit.semaFitTarget(c, expr, ret_t, node)) |new| {
        return new;
    }
    if (expr.type.id() == bt.Never) {
        return expr;
    }
    return sema_lit.reportExpectedType(c, ret_t, expr.type, node);
}

fn implicitReturnMoveLocal(c: *cy.Chunk, expr: sema.ExprResult) ?sema.LocalId {
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
    return semaIfBlock2(c, cond_n, stmts, outer, is_last, end_reachable, null, null, node);
}

/// `cond_moves_end` receives the length of `Chunk.branch_moves` after the condition.
fn semaIfBlock2(c: *cy.Chunk, cond_n: *ast.Node, stmts: []const *ast.Node, outer: usize,
    is_last: bool, end_reachable: *bool, if_stmt: ?**ir.Stmt, cond_moves_end: ?*usize, node: *ast.Node) !void {

    const cond = try c.semaExprCstr(cond_n, c.sema.bool_t);
    if (c.semaBlocks.items[outer].move_branch == .if_cond or c.semaBlocks.items[outer].move_branch == .else_cond) {
        c.semaBlocks.items[outer].move_branch = .if_outer;
    }
    if (cond_moves_end) |out| out.* = c.branch_moves.items.len;
    const body_idx = try sema_local.pushBlock(c, node);
    c.semaBlocks.items[body_idx].move_branch = .branch;
    {
        try semaStmts(c, stmts);
        // NOTE: Set end_reachable before break.
        end_reachable.* = c.block().endReachable;
        if (!is_last) {
            try semaBreakTo(c, outer, node);
        }
    }
    const block = try sema_local.popBlock2(c, end_reachable.*);
    const stmt = try c.ir.pushStmt(.if_block, node, .{
        .cond_expr = cond.ir,
        .body_head = block.first,
    });
    if (if_stmt) |out| out.* = stmt;
}

/// For `unwrap_or`, `unwrap_or_block`.
fn semaIfUnwrapBlock2(c: *cy.Chunk, opt: sema.ExprResult, opt_n: *ast.Node, opt_unwrap: ?*ast.Node,
    elem_of: ?sema.LocalId, body: *const fn (*cy.Chunk, u32, sema.ExprResult, *anyopaque) anyerror!void,
    body_data: *anyopaque, outer: usize, is_last: bool, node: *ast.Node) !void {

    const opt_owner = opt.recParentLocal();
    const owned_opt = try sema_move.semaOwn(c, opt, opt_n);
    // _opt = <opt>
    const opt_v = try sema_local.declareHiddenLocal(c, "_opt", opt.type, owned_opt, opt_n);
    const get_opt = try sema_expr.semaLocal(c, opt_v.id, opt_n);

    // if !isNone(_opt)
    var cond = try c.semaIsNone(get_opt, opt_n);
    const irIdx = try c.ir.newExpr(.unary_op, c.sema.bool_t, opt_n, .{
        .childT = c.sema.bool_t, .op = .lnot, .expr = cond.ir,
    });
    cond.ir = irIdx;

    _ = try sema_local.pushBlock(c, @ptrCast(node));
    {
        if (opt_unwrap) |unwrap| {
            try semaCaptureUnwrap(c, opt, opt_v.id, opt_owner orelse opt_v.id, elem_of, get_opt, unwrap);
        }

        try body(c, opt_v.id, get_opt, body_data);
        if (!is_last) {
            try semaBreakTo(c, outer, @ptrCast(node));
        }
    }
    const end_reachable = c.block().endReachable;
    const block = try sema_local.popBlock2(c, end_reachable);
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

/// `opt_id` is the hidden local that owns the option. A `NoCopy` payload moves out of it to the capture: the option
/// is then dead in the branch (it has nothing left to destruct). `opt_owner` is the local that the option was read
/// from, or `opt_id` for a new value: a borrow payload points to what it borrows, so the capture borrows from it
/// until the branch ends. `elem_of` is the local that a `for` loop reads the elements of a vector or a span through
/// (`sema_borrow.bindCaptureCopy`).
fn semaCaptureUnwrap(c: *cy.Chunk, opt: sema.ExprResult, opt_id: sema.LocalId, opt_owner: sema.LocalId,
    elem_of: ?sema.LocalId, get_opt: sema.ExprResult, capture: *ast.Node) !void {
    const opt_t = opt.type;
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
    var unwrap_init = try sema_access.semaUnwrapOptionNoCheck(c, get_opt, capture);
    if (unwrap_t.info.no_copy and capture.type() == .ident) {
        unwrap_init.owned = true;
        c.varStack.items[opt_id].type = .dead;
    } else {
        unwrap_init = try sema_expr.sema_copy(c, unwrap_init, capture);
    }
    switch (unwrap_init.resType) {
        .value_field => unwrap_init.data.value_field.parent_local = opt_owner,
        .value => unwrap_init.data.value.parent_local = opt_owner,
        else => {},
    }
    const unwrap_v = try sema_local.declareLocalInit(c, unwrap_name, unwrap_t, unwrap_init, capture);
    try sema_borrow.bindCaptureLocal(c, unwrap_v.id, unwrap_init);
    sema_borrow.bindCaptureCopy(c, unwrap_v.id, opt, elem_of);
    const unwrap_local = try sema_expr.semaLocal(c, unwrap_v.id, capture);

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
            const dvar_init = try sema_access.semaIndexExpr2(c, unwrap_local, capture, index, capture, capture);
            _ = try sema_local.declareLocalInit(c, name, dvar_init.type, dvar_init, capture);
        }
    }
}

/// Extracted `opt_n` and `stmts` to be compatible with IfUnwrapStmt/ElseIfUnwrapBlock.
/// `cond_moves_end` receives the length of `Chunk.branch_moves` after the option expression.
fn semaIfUnwrapBlock(c: *cy.Chunk, opt_n: *ast.Node, opt_unwrap: ?*ast.Node,
    stmts: []const *ast.Node, outer: usize, is_last: bool, end_reachable: *bool, if_stmt: **ir.Stmt,
    cond_moves_end: *usize, node: *ast.Node) !void {

    const opt = try c.sema_expr_cstr_template(opt_n, c.sema.option_tmpl);
    const opt_owner = opt.recParentLocal();

    // _opt = <opt>
    const owned_opt = try sema_move.semaOwn(c, opt, opt_n);
    c.semaBlocks.items[outer].move_branch = .if_outer;
    cond_moves_end.* = c.branch_moves.items.len;
    const opt_v = try sema_local.declareHiddenLocal(c, "_opt", opt.type, owned_opt, opt_n);
    const get_opt = try sema_expr.semaLocal(c, opt_v.id, opt_n);

    // if !isNone(_opt)
    var cond = try c.semaIsNone(get_opt, opt_n);
    const irIdx = try c.ir.newExpr(.unary_op, c.sema.bool_t, opt_n, .{
        .childT = c.sema.bool_t, .op = .lnot, .expr = cond.ir,
    });
    cond.ir = irIdx;

    _ = try sema_local.pushBlock(c, @ptrCast(node));
    c.block().move_branch = .branch;
    {
        if (opt_unwrap) |unwrap| {
            try semaCaptureUnwrap(c, opt, opt_v.id, opt_owner orelse opt_v.id, null, get_opt, unwrap);
        }

        try semaStmts(c, stmts);
        // NOTE: Set end_reachable before break.
        end_reachable.* = c.block().endReachable;
        if (!is_last) {
            try semaBreakTo(c, outer, @ptrCast(node));
        }
    }
    const block = try sema_local.popBlock2(c, end_reachable.*);
    if_stmt.* = try c.ir.pushStmt(.if_block, node, .{
        .cond_expr = cond.ir,
        .body_head = block.first,
    });
    if (!is_last and c.varStack.items[opt_v.id].type != .local) {
        // The capture took the payload. The option is `none` in the branches that follow.
        c.varStack.items[opt_v.id].type = .local;
    }
}

/// The branches move outer locals like the ones of an `if` statement (`semaIfStmt`). The option expression always
/// runs, like the first condition.
fn semaIfUnwrapStmt(c: *cy.Chunk, stmt: *ast.IfUnwrapStmt) !void {
    var blocks_end_reachable = false;
    var has_else = false;
    const outer = try sema_local.pushBlock(c, @ptrCast(stmt));
    c.semaBlocks.items[outer].move_branch = .if_cond;
    const outer_start = c.semaBlocks.items[outer].varStart;
    var moves_start: usize = c.branch_moves.items.len;
    var branches: std.ArrayListUnmanaged(IfBranch) = .empty;
    defer branches.deinit(c.alloc);
    var kept: std.ArrayListUnmanaged(sema.LocalId) = .empty;
    defer kept.deinit(c.alloc);
    {
        var end_reachable: bool = undefined;
        var if_stmt: *ir.Stmt = undefined;
        const first_is_last = stmt.else_blocks.len == 0;
        try semaIfUnwrapBlock(c, stmt.opt, stmt.unwrap, stmt.stmts, outer, first_is_last, &end_reachable, &if_stmt,
            &moves_start, @ptrCast(stmt));
        try endIfBranch(c, &branches, &kept, &if_stmt.cast(.if_block).body_head, end_reachable, moves_start, outer_start,
            branchVarEnd(c, outer_start, first_is_last));
        if (!blocks_end_reachable and end_reachable) {
            blocks_end_reachable = true;
        }

        for (stmt.else_blocks, 0..) |node, i| {
            switch (node.type()) {
                .elseif_block => {
                    const else_ = node.cast(.elseif_block);
                    const start = c.branch_moves.items.len;
                    const is_last = i + 1 == stmt.else_blocks.len;
                    c.semaBlocks.items[outer].move_branch = .else_cond;
                    try semaIfBlock2(c, else_.cond, else_.stmts, outer, is_last, &end_reachable, &if_stmt, null, node);
                    try endIfBranch(c, &branches, &kept, &if_stmt.cast(.if_block).body_head, end_reachable, start,
                        outer_start, branchVarEnd(c, outer_start, is_last));
                    if (!blocks_end_reachable and end_reachable) {
                        blocks_end_reachable = true;
                    }
                },
                .else_block => {
                    has_else = true;
                    const else_ = node.cast(.else_block);
                    const start = c.branch_moves.items.len;
                    c.semaBlocks.items[outer].move_branch = .branch;
                    c.semaBlocks.items[outer].moves_start = @intCast(start);
                    try semaStmts(c, else_.stmts);
                    c.semaBlocks.items[outer].move_branch = .if_outer;
                    try endIfBranch(c, &branches, &kept, null, c.block().endReachable, start, outer_start,
                        c.varStack.items.len);
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
    if (kept.items.len > 0) {
        try joinBranchMoves(c, @ptrCast(stmt), outer, branches.items, kept.items, has_else);
    }
    // A local of a block further out is a move of the enclosing branch.
    c.branch_moves.items.len = moves_start;
    const parent_start = c.semaBlocks.items[outer - 1].varStart;
    for (kept.items) |id| {
        if (id < parent_start) try c.branch_moves.append(c.alloc, id);
    }
    const block = try sema_local.popBlock(c);
    _ = try c.ir.pushStmt(.block, @ptrCast(stmt), .{ .bodyHead = block.first });
    if (!blocks_end_reachable and has_else) {
        c.block().endReachable = false;
    }
}

/// A lambda whose return type is inferred from its body (`fn(x str) => expr`, or `|x| expr` for a function type that
/// infers its result, `fn(T) -> %U`) has no signature while the body is analyzed. Nothing in the body can leave the
/// lambda before the type of the body is known, so `what` is reported instead of reading the missing signature.
fn checkReturnTypeKnown(c: *cy.Chunk, what: []const u8, how: []const u8, node: *ast.Node) !void {
    const func = c.proc().func orelse return;
    if (func.isResolved()) return;
    return c.reportErrorFmt("{} can not leave a lambda whose return type is inferred from its body: the return type is not known yet. Declare the return type of the lambda {}.", &.{
        v(what), v(how),
    }, node);
}

/// What a failing `!` does with its error: it goes to the `else` block of the enclosing `try`, or the function
/// returns it, or the main block panics.
pub fn semaPropagateError(c: *cy.Chunk, err: sema.ExprResult, node: *ast.Node) !void {
    const proc = c.proc();
    if (proc.try_ctx) |try_ctx| {
        // Inside a `try` block: hand the error to the `else` block instead of leaving the proc.
        const err_local = &c.varStack.items[try_ctx.err_local];
        _ = try c.ir.pushStmt(.set_local, node, .{
            .id = @intCast(err_local.inner.local.id),
            .right = err.ir,
        });
        if (try_ctx.track_moves) {
            try semaTryExit(c, try_ctx.body_block, node);
        } else {
            try semaBreakTo(c, try_ctx.body_block, node);
        }
    } else if (proc.func != null) {
        try checkReturnTypeKnown(c, "`!`", "(`fn(x T) -> !U => expr`), or handle the error here with `!else` or `try`", node);
        const ret_t = proc.getReturnType(c.sema);
        if (ret_t.id() == bt.Error) {
            try semaReturnExpr(c, err, node);
        } else if (ret_t.kind() == .result) {
            const ret = try sema_init.semaInitChoice(c, ret_t, 0, 0, err, node);
            try semaReturnExpr(c, ret, node);
        } else {
            const ret_name = try c.sema.allocTypeName(ret_t);
            defer c.alloc.free(ret_name);
            const func = proc.func.?;
            if (func.type == .userLambda) {
                return c.reportErrorFmt("Expected a `!T` or `error` return type for `!`. The lambda returns `{}`, so `!` can not pass the error on. Declare it `-> !{}`, or handle the error here with `!else` or `try`.", &.{
                    v(ret_name), v(ret_name),
                }, node);
            }
            return c.reportErrorFmt("Expected a `!T` or `error` return type for `!`. The function `{}` returns `{}`, so `!` can not pass the error on. Declare it `-> !{}`, or handle the error here with `!else` or `try`.", &.{
                v(func.name()), v(ret_name), v(ret_name),
            }, node);
        }
    } else {
        // Panic.
        const arg = Argument.initPreResolved(node, err);
        const call = try c.semaCallFunc2(c.sema.panic_unwrap_error_fn, &.{arg}, &.{}, node);
        _ = try sema_local.declareHiddenLocal(c, "_res", c.sema.void_t, call, node);
    }
}

/// `scope |s|:` with a body. `s` is a `Scope` that lives for the body. The fibers that the body starts are
/// done when the statement is:
///
///     outer:
///         s := Scope.new()
///         mid:
///             _try_err
///             body:
///                 <body>            -- a failing `!` sets `_try_err` and breaks out of `body`
///                 break mid
///             s.abort()             -- the body failed: the fibers are cancelled
///             <the error goes on like at a `!`>
///         s.join()!                 -- the body reached its end: wait for the fibers
///
/// A `return`, `break` or `continue` that leaves the body destructs `s`, which joins the fibers first.
fn sema_scope_stmt(c: *cy.Chunk, stmt: *ast.ScopeStmt) !void {
    const node: *ast.Node = @ptrCast(stmt);
    if (stmt.name.type() != .ident) {
        return c.reportError("Expected a name for the scope.", stmt.name);
    }
    {
        // An error of the body or of a fiber leaves the block like a failing `!`. Say so here instead of at
        // the `!` that the block is lowered to.
        const proc = c.proc();
        if (proc.try_ctx == null) {
            if (proc.func != null) {
                try checkReturnTypeKnown(c, "A `scope` block", "(`fn(x T) -> !U => expr`), or put the block in a `try` block", node);
                const ret_t = proc.getReturnType(c.sema);
                if (ret_t.id() != bt.Error and ret_t.kind() != .result) {
                    return c.reportError("A `scope` block needs a function that returns `!T` or `error`, or an enclosing `try` block. An error of its fibers leaves the block like a failing `!`.", node);
                }
            }
        }
    }
    const scope_t = c.sema.scope_new_fn.sig.ret;
    const borrow_t = try sema.get_ex_borrow_type(c, scope_t);

    var body_end_reachable = false;
    // The outer locals that the body moved where it reaches its end: they are dead after the statement.
    var end_moves: std.ArrayListUnmanaged(sema.LocalId) = .empty;
    defer end_moves.deinit(c.alloc);
    const scope_idx = try sema_local.pushBlock(c, node);
    c.block().move_branch = .plain;
    const outer_start = c.block().varStart;
    {
        const new_call = try c.semaCallFunc2(c.sema.scope_new_fn, &.{}, &.{}, node);
        const scope_local = try sema_local.declareLocalInit(c, stmt.name.cast(.ident).name.slice(), scope_t, new_call, stmt.name);
        c.varStack.items[scope_local.id].scope_block = true;
        // The fibers are done when this block is left, on every path: the `Scope` is destructed here.
        const borrows_start = c.scope_borrows.items.len;
        defer endScopeBorrows(c, borrows_start);

        const mid = try sema_local.pushBlock(c, node);
        c.block().move_branch = .plain;
        // The locals that the body moved before some failing `!`: dead where the body failed.
        var fail_moves: std.ArrayListUnmanaged(sema.LocalId) = .empty;
        defer fail_moves.deinit(c.alloc);
        {
            const err_local = try sema_local.declareHiddenLocal(c, "_try_err", c.sema.error_t, null, node);
            c.varStack.items[err_local.id].type = .dead;

            const proc = c.proc();
            const body_block = try sema_local.pushBlock(c, node);
            c.block().move_branch = .plain;
            const body_start = c.block().varStart;
            const exits_start = c.try_exits.items.len;
            const exit_moves_start = c.try_moves.items.len;
            const prev_ctx = proc.try_ctx;
            proc.try_ctx = .{ .body_block = @intCast(body_block), .err_local = err_local.id, .track_moves = true };
            {
                try c.scope_blocks.append(c.alloc, .{
                    .local = scope_local.id,
                    .body_block = body_block,
                    .proc_depth = c.semaProcs.items.len,
                });
                defer c.scope_blocks.items.len -= 1;
                try semaStmts(c, stmt.stmts);
                body_end_reachable = c.block().endReachable;
                const moves_start = c.block().moves_start;
                if (body_end_reachable) {
                    try appendOuterMoves(c, &end_moves, moves_start, outer_start);
                    try semaBreakTo(c, mid, node);
                }
                restoreMoves(c, moves_start);
            }
            c.proc().try_ctx = prev_ctx;
            const exits = try c.alloc.dupe(sema.MovedBreak, c.try_exits.items[exits_start..]);
            defer c.alloc.free(exits);
            c.try_exits.items.len = exits_start;
            const exit_moves = try c.alloc.dupe(sema.LocalId, c.try_moves.items[exit_moves_start..]);
            defer c.alloc.free(exit_moves);
            c.try_moves.items.len = exit_moves_start;
            for (exit_moves) |id| {
                if (std.mem.indexOfScalar(sema.LocalId, fail_moves.items, id) == null) try fail_moves.append(c.alloc, id);
            }
            std.mem.sort(sema.LocalId, fail_moves.items, {}, std.sort.desc(sema.LocalId));
            const body = try sema_local.popBlock2(c, false);
            _ = try c.ir.pushStmt(.block, node, .{ .bodyHead = body.first });

            // Each failing `!` destructs the ones that it did not move itself, in the slot before its `break`.
            for (exits) |ex| {
                const own = exit_moves[ex.start - exit_moves_start..ex.end - exit_moves_start];
                if (own.len == fail_moves.items.len) continue;
                try c.ir.pushStmtBlock(c.alloc);
                {
                    errdefer _ = c.ir.popStmtBlock();
                    try destructBranchEnd(c, fail_moves.items, own, body_start, node);
                }
                ex.slot.cast(.block).bodyHead = c.ir.popStmtBlock().first;
            }

            // The body failed. The moves are moves on the way of the error for the statements around (an enclosing
            // `try`), and the locals are dead for a `return` of the error.
            const fail_moves_start = c.branch_moves.items.len;
            try c.branch_moves.appendSlice(c.alloc, fail_moves.items);
            for (fail_moves.items) |id| {
                c.varStack.items[id].type = .dead;
            }
            defer {
                for (fail_moves.items) |id| {
                    c.varStack.items[id].type = .local;
                }
                c.branch_moves.items.len = fail_moves_start;
            }
            const scope_v = try sema_expr.semaLocal(c, scope_local.id, node);
            const scope_addr = try sema_expr.semaAddressOf(c, scope_v, borrow_t, node);
            const abort_call = try c.semaCallFunc2(c.sema.scope_abort_fn, &.{Argument.initPreResolved(node, scope_addr)}, &.{}, node);
            _ = try sema_local.declareHiddenLocal(c, "_res", c.sema.void_t, abort_call, node);
            c.varStack.items[err_local.id].type = .local;
            const err = try sema_expr.semaLocal(c, err_local.id, node);
            c.varStack.items[err_local.id].type = .dead;
            try semaPropagateError(c, err, node);
        }
        const mid_block = try sema_local.popBlock2(c, false);
        _ = try c.ir.pushStmt(.block, node, .{ .bodyHead = mid_block.first });
        c.block().endReachable = body_end_reachable;
        // Only the end of the body comes here.
        for (end_moves.items) |id| {
            c.varStack.items[id].type = .dead;
        }
        try c.branch_moves.appendSlice(c.alloc, end_moves.items);

        if (body_end_reachable) {
            // `s.join()!`
            try semaScopeJoinCheck(c, scope_local.id, node);
        }
    }
    endPlainBlockMoves(c, scope_idx);
    const block = try sema_local.popBlock(c);
    _ = try c.ir.pushStmt(.block, node, .{ .bodyHead = block.first });
    if (!body_end_reachable) {
        c.block().endReachable = false;
    }
}

pub const OpenScopeBlock = struct {
    local: sema.LocalId,
    /// Index of the body's block in `semaBlocks`.
    body_block: usize,
    proc_depth: usize,
};

/// `s.join()!` for the `Scope` in the local `scope_local`: the fibers run to their end, and an error of a fiber
/// goes on like at a failing `!`.
fn semaScopeJoinCheck(c: *cy.Chunk, scope_local: sema.LocalId, node: *ast.Node) !void {
    const scope_t = c.sema.scope_new_fn.sig.ret;
    const borrow_t = try sema.get_ex_borrow_type(c, scope_t);
    const scope_v = try sema_expr.semaLocal(c, scope_local, node);
    const scope_addr = try sema_expr.semaAddressOf(c, scope_v, borrow_t, node);
    var join_res = try c.semaCallFunc2(c.sema.scope_join_fn, &.{Argument.initPreResolved(node, scope_addr)}, &.{}, node);
    join_res = try sema_move.semaEnsureAddressable(c, join_res, node);
    const res_borrow_t = try sema.getBorrowType(c, join_res.type);
    const res_addr = try sema_expr.semaAddressOf(c, join_res, res_borrow_t, node);
    const res_local = try sema_local.declareHiddenLocal(c, "_res_addr", res_borrow_t, res_addr, node);
    const res = try sema_expr.semaLocal(c, res_local.id, node);
    const cond = try c.semaIsError(res, node);
    _ = try sema_local.pushBlock(c, node);
    {
        const err = try sema_access.semaUnwrapResultErrorNoCheck(c, res, node);
        try semaPropagateError(c, err, node);
    }
    const err_block = try sema_local.popBlock2(c, false);
    _ = try c.ir.pushStmt(.if_block, node, .{
        .cond_expr = cond.ir,
        .body_head = err_block.first,
    });
}

/// Before a `return` (`loop_block` is null), or a `break` · `continue` of the loop at `loop_block`: the `scope`
/// blocks that the statement leaves are joined first, innermost first, and an error of a fiber goes on like at
/// a failing `!` instead of the statement. Without this the join would be left to `Scope.@deinit`, where an
/// error can only panic.
fn semaScopeExitJoin(c: *cy.Chunk, loop_block: ?usize, node: *ast.Node) !void {
    const proc_depth = c.semaProcs.items.len;
    var i = c.scope_blocks.items.len;
    while (i > 0) {
        i -= 1;
        const open = c.scope_blocks.items[i];
        if (open.proc_depth != proc_depth) break;
        if (loop_block) |idx| {
            // The loop is inside the block: the statement does not leave it.
            if (open.body_block < idx) break;
        }
        if (c.compiler.record_refs and i == c.scope_blocks.items.len - 1) cy.refs.recordScopeExit(c, node);
        _ = try sema_local.pushBlock(c, node);
        try semaScopeJoinCheck(c, open.local, node);
        const block = try sema_local.popBlock(c);
        _ = try c.ir.pushStmt(.block, node, .{ .bodyHead = block.first });
    }
}

/// A borrow that an argument of `s.start` passes to a fiber of a `scope` block.
pub const ScopeBorrow = struct {
    /// The local that owns the borrowed value. Null when no local does (a global).
    owner: ?sema.LocalId,
    ex: bool,
    node: *ast.Node,
};

fn endScopeBorrows(c: *cy.Chunk, start: usize) void {
    for (c.scope_borrows.items[start..]) |borrow| {
        const owner = &c.varStack.items[borrow.owner.?];
        if (borrow.ex) {
            owner.active_ex_borrows -= 1;
        } else {
            owner.active_borrows -= 1;
        }
    }
    c.scope_borrows.items.len = start;
}

/// `s.start(func, {args})`. A fiber of a `Scope` runs after the call, so its arguments can not borrow in
/// general (`checkScopeStartCall`). The fibers of a `scope |s|:` block are done when the block is left, so
/// there `s.start` takes borrows of values that are declared before the block. A value that is declared in
/// the block is destructed before the fibers are joined.
/// The borrow lasts until the end of the block: the owner counts it like a borrow that a local holds.
pub fn semaScopeStart(c: *cy.Chunk, rec: *ast.Node, rec_res: sema.ExprResult, call: *ast.CallExpr, node: *ast.Node) !sema.ExprResult {
    var scope_local: ?sema.LocalId = null;
    if (rec.type() == .ident and rec_res.resType == .value_local) {
        if (c.varStack.items[rec_res.data.value_local].scope_block) {
            scope_local = rec_res.data.value_local;
        }
    }
    const args = call.args.slice();
    const lit: ?*ast.Node = if (args.len == 2 and args[1].type() == .init_lit) args[1] else null;
    if (scope_local == null or lit == null) {
        return c.semaCallFuncSymRec(c.sema.scope_start_sym, rec, rec_res, args, false, node);
    }

    const prev_call = c.scope_start_call;
    const prev_lit = c.scope_start_lit;
    const start = c.scope_start_borrows.items.len;
    c.scope_start_call = node;
    c.scope_start_lit = lit;
    defer {
        c.scope_start_call = prev_call;
        c.scope_start_lit = prev_lit;
        c.scope_start_borrows.items.len = start;
    }
    const res = try c.semaCallFuncSymRec(c.sema.scope_start_sym, rec, rec_res, args, false, node);

    for (c.scope_start_borrows.items[start..]) |borrow| {
        const owner_id = borrow.owner orelse continue;
        const owner = &c.varStack.items[owner_id];
        if (owner.lifetime.kind == .temp) {
            return c.reportError("A fiber can not borrow from a temporary value.", borrow.node);
        }
        if (owner_id > scope_local.?) {
            return c.reportErrorFmt("A fiber of the `scope` block can not borrow `{}`: it is declared inside the block and is gone before the fibers are done. Declare it before the block.", &.{v(owner.name())}, borrow.node);
        }
        // The earlier arguments and the earlier `start` calls of the open blocks count.
        if (borrow.ex) {
            try sema_borrow.checkExclusiveBorrow(c, owner_id, borrow.node);
            owner.active_ex_borrows += 1;
        } else {
            try sema_borrow.checkSharedBorrow(c, owner_id, borrow.node);
            owner.active_borrows += 1;
        }
        try c.scope_borrows.append(c.alloc, borrow);
    }
    return res;
}

fn sema_begin_stmt(c: *cy.Chunk, node: *ast.BeginStmt) !void {
    const idx = try sema_local.pushBlock(c, @ptrCast(node));
    c.block().move_branch = .plain;
    {
        try semaStmts(c, node.stmts);
    }
    const end_reachable = c.block().endReachable;
    endPlainBlockMoves(c, idx);
    const block = try sema_local.popBlock(c);
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
///
/// The body and the handler move outer locals (see `docs/decisions/project_last_use.md` "try 블록"). Without a
/// runtime flag, each way through the statement leaves such a local in one state:
/// - the locals that the body moved before some failing `!` are dead in the handler: each failing `!` destructs the
///   ones that it did not move itself, in a slot before its `break` (`semaTryExit`).
/// - the locals that either way to the end of the statement moved are dead after it: the other way destructs them.
fn sema_try_stmt(c: *cy.Chunk, stmt: *ast.TryStmt) !void {
    const node: *ast.Node = @ptrCast(stmt);
    const proc = c.proc();

    var body_end_reachable = false;
    var handler_end_reachable = false;
    // The locals that are dead after the statement.
    var dead: std.ArrayListUnmanaged(sema.LocalId) = .empty;
    defer dead.deinit(c.alloc);
    const outer = try sema_local.pushBlock(c, node);
    c.block().move_branch = .plain;
    const outer_start = c.block().varStart;
    {
        // Declared in `outer`, below the body block, so a failing `!` keeps it while the body's locals
        // are destructed. `error` has no destructor; it is marked dead so the else block does not
        // release an uninitialized local.
        const err_local = try sema_local.declareHiddenLocal(c, "_try_err", c.sema.error_t, null, node);
        c.varStack.items[err_local.id].type = .dead;

        const body_block = try sema_local.pushBlock(c, node);
        c.block().move_branch = .plain;
        const body_start = c.block().varStart;
        const exits_start = c.try_exits.items.len;
        const exit_moves_start = c.try_moves.items.len;
        const prev_ctx = proc.try_ctx;
        proc.try_ctx = .{ .body_block = @intCast(body_block), .err_local = err_local.id, .track_moves = true };
        // The outer locals that the body moved where it reaches its end, and the slot before its `break`.
        var end_moves: std.ArrayListUnmanaged(sema.LocalId) = .empty;
        defer end_moves.deinit(c.alloc);
        var end_slot: ?*ir.Stmt = null;
        {
            try semaStmts(c, stmt.stmts);
            body_end_reachable = c.block().endReachable;
            const moves_start = c.block().moves_start;
            if (body_end_reachable) {
                try appendOuterMoves(c, &end_moves, moves_start, outer_start);
                try sema_assign.checkAssignMoveJump(c, outer, node);
                try sema_local.semaDestructBlock2(c, &c.semaBlocks.items[outer]);
                end_slot = try c.ir.pushStmt(.block, node, .{ .bodyHead = null });
                _ = try c.ir.pushStmt(.break_, node, .{ .block_offset = @intCast(outer - proc.block_start) });
                c.block().endReachable = false;
            }
            restoreMoves(c, moves_start);
        }
        proc.try_ctx = prev_ctx;
        const exits = try c.alloc.dupe(sema.MovedBreak, c.try_exits.items[exits_start..]);
        defer c.alloc.free(exits);
        c.try_exits.items.len = exits_start;
        const exit_moves = try c.alloc.dupe(sema.LocalId, c.try_moves.items[exit_moves_start..]);
        defer c.alloc.free(exit_moves);
        c.try_moves.items.len = exit_moves_start;
        // The locals that are dead in the handler.
        var fail_moves: std.ArrayListUnmanaged(sema.LocalId) = .empty;
        defer fail_moves.deinit(c.alloc);
        for (exit_moves) |id| {
            if (std.mem.indexOfScalar(sema.LocalId, fail_moves.items, id) == null) try fail_moves.append(c.alloc, id);
        }
        std.mem.sort(sema.LocalId, fail_moves.items, {}, std.sort.desc(sema.LocalId));
        const body = try sema_local.popBlock2(c, false);
        _ = try c.ir.pushStmt(.block, node, .{ .bodyHead = body.first });

        // They are moves on the way of the handler for the statements around: a `break` or `continue` of a loop,
        // a failing `!` of an enclosing `try`.
        const fail_moves_start = c.branch_moves.items.len;
        try c.branch_moves.appendSlice(c.alloc, fail_moves.items);
        for (fail_moves.items) |id| {
            c.varStack.items[id].type = .dead;
        }
        const catch_stmt = stmt.catchStmt;
        const catch_node: *ast.Node = @ptrCast(catch_stmt);
        _ = try sema_local.pushBlock(c, catch_node);
        c.block().move_branch = .plain;
        {
            if (catch_stmt.errorVar) |capture| {
                if (capture.type() != .ident) {
                    return c.reportErrorFmt("Unsupported error variable: {}", &.{v(capture.type())}, capture);
                }
                c.varStack.items[err_local.id].type = .local;
                const err = try sema_expr.semaLocal(c, err_local.id, capture);
                c.varStack.items[err_local.id].type = .dead;
                _ = try sema_local.declareLocalInit(c, capture.cast(.ident).name.slice(), c.sema.error_t, err, capture);
            }
            try semaStmts(c, catch_stmt.stmts);
            handler_end_reachable = c.block().endReachable;
            const moves_start = c.block().moves_start;
            if (handler_end_reachable) {
                try dead.appendSlice(c.alloc, fail_moves.items);
                try appendOuterMoves(c, &dead, moves_start, outer_start);
                if (body_end_reachable) {
                    // The locals that only the body moved, on its way to the end.
                    std.mem.sort(sema.LocalId, end_moves.items, {}, std.sort.desc(sema.LocalId));
                    for (end_moves.items) |id| {
                        if (std.mem.indexOfScalar(sema.LocalId, dead.items, id) != null) continue;
                        try sema_local.semaDestructLocal(c, &c.varStack.items[id], catch_node);
                        c.varStack.items[id].type = .dead;
                        try dead.append(c.alloc, id);
                    }
                }
            } else if (body_end_reachable) {
                try dead.appendSlice(c.alloc, end_moves.items);
            }
            restoreMoves(c, moves_start);
        }
        c.branch_moves.items.len = fail_moves_start;
        const handler = try sema_local.popBlock(c);
        _ = try c.ir.pushStmt(.block, catch_node, .{ .bodyHead = handler.first });
        // The else block falls through to the end of `outer`, where the body's `break outer` lands.
        c.block().endReachable = body_end_reachable or handler_end_reachable;

        // The slots. The locals are alive where the statements of a slot run, apart from the ones that its exit
        // moved (`destructBranchEnd`).
        for (fail_moves.items) |id| {
            c.varStack.items[id].type = .local;
        }
        for (dead.items) |id| {
            c.varStack.items[id].type = .local;
        }
        for (exits) |ex| {
            const own = exit_moves[ex.start - exit_moves_start..ex.end - exit_moves_start];
            if (own.len == fail_moves.items.len) continue;
            try c.ir.pushStmtBlock(c.alloc);
            {
                errdefer _ = c.ir.popStmtBlock();
                try destructBranchEnd(c, fail_moves.items, own, body_start, node);
            }
            ex.slot.cast(.block).bodyHead = c.ir.popStmtBlock().first;
        }
        if (end_slot) |slot| {
            if (handler_end_reachable and end_moves.items.len < dead.items.len) {
                std.mem.sort(sema.LocalId, dead.items, {}, std.sort.desc(sema.LocalId));
                try c.ir.pushStmtBlock(c.alloc);
                {
                    errdefer _ = c.ir.popStmtBlock();
                    try destructBranchEnd(c, dead.items, end_moves.items, outer_start, node);
                }
                slot.cast(.block).bodyHead = c.ir.popStmtBlock().first;
            }
        }
        for (dead.items) |id| {
            c.varStack.items[id].type = .dead;
        }
    }
    const block = try sema_local.popBlock(c);
    _ = try c.ir.pushStmt(.block, node, .{ .bodyHead = block.first });
    if (!body_end_reachable and !handler_end_reachable) {
        c.block().endReachable = false;
    }
    // A local of a block further out is a move of the enclosing branch or loop.
    for (dead.items) |id| {
        if (id < c.block().varStart) try c.branch_moves.append(c.alloc, id);
    }
}

/// Adds the locals below `outer_start` that were moved since `moves_start` of `Chunk.branch_moves` to `list`, each
/// once.
fn appendOuterMoves(c: *cy.Chunk, list: *std.ArrayListUnmanaged(sema.LocalId), moves_start: usize, outer_start: usize) !void {
    for (c.branch_moves.items[moves_start..]) |id| {
        if (id >= outer_start) continue;
        if (std.mem.indexOfScalar(sema.LocalId, list.items, id) == null) try list.append(c.alloc, id);
    }
}

/// A failing `!` in the body block `body_block` of a `try` statement: it leaves the body for the handler. The outer
/// locals that the body moved on the way are noted (`Chunk.try_exits`), and `sema_try_stmt` fills the slot before
/// the `break` with the destructors of the ones that only the other failing `!` of the body moved.
fn semaTryExit(c: *cy.Chunk, body_block: usize, node: *ast.Node) !void {
    try sema_assign.checkAssignMoveJump(c, body_block, node);
    const b = &c.semaBlocks.items[body_block];
    try sema_local.semaDestructBlock2(c, b);
    const slot = try c.ir.pushStmt(.block, node, .{ .bodyHead = null });
    const start = c.try_moves.items.len;
    const outer_start = c.semaBlocks.items[body_block - 1].varStart;
    for (c.branch_moves.items[b.moves_start..]) |id| {
        if (id >= outer_start) continue;
        if (std.mem.indexOfScalar(sema.LocalId, c.try_moves.items[start..], id) == null) try c.try_moves.append(c.alloc, id);
    }
    try c.try_exits.append(c.alloc, .{ .slot = slot, .start = @intCast(start), .end = @intCast(c.try_moves.items.len) });
    _ = try c.ir.pushStmt(.break_, node, .{ .block_offset = @intCast(body_block - c.proc().block_start) });
    c.block().endReachable = false;
}

/// A branch of an `if`, `if` unwrap or `switch` statement, for the moves of outer locals (`joinBranchMoves`).
pub const IfBranch = struct {
    /// The head of the body of the branch (of an `if_block` or a `switch_case`), or null for the `else` statements
    /// of an `if` statement, which run in its outer block.
    body: ?*?*ir.Stmt,
    end_reachable: bool,
    /// The range of `Chunk.branch_moves` that the branch moved.
    moves_start: u32,
    moves_end: u32,
    /// The end of the locals that are alive where the branch ends (`destructBranchEnd`).
    var_end: u32,
};

fn semaIfStmt(c: *cy.Chunk, node: *ast.IfStmt) !void {
    var blocks_end_reachable = false;
    var has_else = false;
    const outer = try sema_local.pushBlock(c, @ptrCast(node));
    // The first condition always runs: it can move a local like a statement of the block of the `if` statement.
    c.semaBlocks.items[outer].move_branch = .if_cond;
    const outer_start = c.semaBlocks.items[outer].varStart;
    // Set to the end of the moves of the first condition: they are moves of the enclosing branch, not of a branch of
    // this statement.
    var moves_start: usize = c.branch_moves.items.len;
    var branches: std.ArrayListUnmanaged(IfBranch) = .empty;
    defer branches.deinit(c.alloc);
    // The moves of the branches are kept after `moves_start` while the next branch is checked, without the moved state.
    var kept: std.ArrayListUnmanaged(sema.LocalId) = .empty;
    defer kept.deinit(c.alloc);
    {
        var end_reachable: bool = undefined;
        var if_stmt: *ir.Stmt = undefined;
        const first_is_last = node.else_blocks.len == 0;
        try semaIfBlock2(c, node.cond, node.stmts, outer, first_is_last, &end_reachable, &if_stmt, &moves_start, @ptrCast(node));
        try endIfBranch(c, &branches, &kept, &if_stmt.cast(.if_block).body_head, end_reachable, moves_start, outer_start,
            branchVarEnd(c, outer_start, first_is_last));
        if (!blocks_end_reachable and end_reachable) {
            blocks_end_reachable = true;
        }

        for (node.else_blocks, 0..) |else_block, i| {
            switch (else_block.type()) {
                .elseif_block => {
                    const elseif = else_block.cast(.elseif_block);
                    const start = c.branch_moves.items.len;
                    const is_last = i + 1 == node.else_blocks.len;
                    c.semaBlocks.items[outer].move_branch = .else_cond;
                    try semaIfBlock2(c, elseif.cond, elseif.stmts, outer, is_last, &end_reachable, &if_stmt, null, else_block);
                    try endIfBranch(c, &branches, &kept, &if_stmt.cast(.if_block).body_head, end_reachable, start,
                        outer_start, branchVarEnd(c, outer_start, is_last));
                    if (!blocks_end_reachable and end_reachable) {
                        blocks_end_reachable = true;
                    }
                },
                .else_block => {
                    has_else = true;
                    const else_ = else_block.cast(.else_block);
                    const start = c.branch_moves.items.len;
                    c.semaBlocks.items[outer].move_branch = .branch;
                    c.semaBlocks.items[outer].moves_start = @intCast(start);
                    try semaStmts(c, else_.stmts);
                    c.semaBlocks.items[outer].move_branch = .if_outer;
                    try endIfBranch(c, &branches, &kept, null, c.block().endReachable, start, outer_start,
                        c.varStack.items.len);
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
    if (kept.items.len > 0) {
        try joinBranchMoves(c, @ptrCast(node), outer, branches.items, kept.items, has_else);
    }
    // A local of a block further out is a move of the enclosing branch.
    c.branch_moves.items.len = moves_start;
    const parent_start = c.semaBlocks.items[outer - 1].varStart;
    for (kept.items) |id| {
        if (id < parent_start) try c.branch_moves.append(c.alloc, id);
    }
    const block = try sema_local.popBlock(c);
    _ = try c.ir.pushStmt(.block, @ptrCast(node), .{ .bodyHead = block.first });

    if (!blocks_end_reachable and has_else) {
        c.block().endReachable = false;
    }
}

/// The end of the locals that are alive where a branch of an `if` statement ends.
/// A branch other than the last one ends with a `break` out of the statement, after the destructors of the locals
/// of the outer block. The last one runs to the end of the outer block, whose locals are still alive.
fn branchVarEnd(c: *cy.Chunk, outer_start: u32, is_last: bool) usize {
    return if (is_last) c.varStack.items.len else outer_start;
}

/// Ends a branch of an `if` statement: the outer locals that it moved are alive again for the next branch.
pub fn endIfBranch(c: *cy.Chunk, branches: *std.ArrayListUnmanaged(IfBranch), kept: *std.ArrayListUnmanaged(sema.LocalId),
    body: ?*?*ir.Stmt, end_reachable: bool, start: usize, outer_start: u32, var_end: usize) !void {
    var branch = IfBranch{ .body = body, .end_reachable = end_reachable, .moves_start = @intCast(kept.items.len), .moves_end = 0,
        .var_end = @intCast(var_end) };
    for (c.branch_moves.items[start..]) |id| {
        if (id >= outer_start) continue;
        c.varStack.items[id].type = .local;
        if (end_reachable) try kept.append(c.alloc, id);
    }
    c.branch_moves.items.len = start;
    branch.moves_end = @intCast(kept.items.len);
    try branches.append(c.alloc, branch);
}

/// After the branches of an `if` statement: an outer local that a branch moved is destructed at the end of the other
/// branches that reach the end, and of the implicit `else`. It is dead after the statement. Each path to the join then
/// leaves it in one state, without a runtime flag. See `docs/decisions/project_last_use.md` "E".
pub fn joinBranchMoves(c: *cy.Chunk, node: *ast.Node, outer: usize, branches: []const IfBranch, moved: []const sema.LocalId,
    has_else: bool) !void {
    // Each local once, in the order of the moves.
    var ids: std.ArrayListUnmanaged(sema.LocalId) = .empty;
    defer ids.deinit(c.alloc);
    for (moved) |id| {
        if (std.mem.indexOfScalar(sema.LocalId, ids.items, id) == null) try ids.append(c.alloc, id);
    }
    for (branches) |branch| {
        if (!branch.end_reachable) continue;
        const own = moved[branch.moves_start..branch.moves_end];
        if (branch.body) |body| {
            try c.ir.pushStmtBlock(c.alloc);
            {
                errdefer _ = c.ir.popStmtBlock();
                try destructBranchEnd(c, ids.items, own, branch.var_end, node);
            }
            const chain = c.ir.popStmtBlock();
            spliceBranchEnd(body, chain);
        } else {
            // The `else` statements run in the outer block, which is the current one.
            try destructBranchEnd(c, ids.items, own, branch.var_end, node);
        }
    }
    if (!has_else) {
        // The last branch falls through to the implicit `else`: it breaks out first, like the other branches.
        const last = branches[branches.len - 1];
        if (last.end_reachable) {
            for (ids.items) |id| {
                c.varStack.items[id].type = .dead;
            }
            try c.ir.pushStmtBlock(c.alloc);
            {
                errdefer _ = c.ir.popStmtBlock();
                try sema_local.semaDestructBlock2(c, &c.semaBlocks.items[outer]);
                const start = c.proc().block_start;
                _ = try c.ir.pushStmt(.break_, node, .{ .block_offset = @intCast(outer - start) });
            }
            spliceBranchEnd(last.body.?, c.ir.popStmtBlock());
        }
        try destructBranchEnd(c, ids.items, &.{}, c.varStack.items.len, node);
    }
    for (ids.items) |id| {
        c.varStack.items[id].type = .dead;
    }
}

/// Destructs the locals `ids` that a branch of an `if` statement did not move (`own` are the ones that it moved), for
/// the end of that branch. The statements are made after all the branches, so the locals get the state that they
/// have at the end of the branch for the cancel pads of the destructors (`semaCancelPad`): the locals from `var_end`
/// up are not alive there (the locals of a later branch, or the ones that the `break` of the branch destructed), and
/// neither are the locals that the branch moved or the ones that are destructed already. `ids` are alive on return.
fn destructBranchEnd(c: *cy.Chunk, ids: []const sema.LocalId, own: []const sema.LocalId, var_end: usize, node: *ast.Node) !void {
    const saved_end = c.cancel_pad_var_end;
    const saved_proc = c.cancel_pad_var_proc;
    defer {
        c.cancel_pad_var_end = saved_end;
        c.cancel_pad_var_proc = saved_proc;
    }
    if (var_end < c.varStack.items.len) {
        c.cancel_pad_var_end = var_end;
        c.cancel_pad_var_proc = c.semaProcs.items.len;
    }
    for (ids) |id| {
        const is_own = std.mem.indexOfScalar(sema.LocalId, own, id) != null;
        c.varStack.items[id].type = if (is_own) .dead else .local;
    }
    defer {
        for (ids) |id| {
            c.varStack.items[id].type = .local;
        }
    }
    for (ids) |id| {
        if (c.varStack.items[id].type != .local) continue;
        try sema_local.semaDestructLocal(c, &c.varStack.items[id], node);
        c.varStack.items[id].type = .dead;
    }
}

/// Puts `chain` at the end of the body of a branch (`body_head` is its head), before the `break` out of the `if`
/// statement that a branch other than the last one ends with.
fn spliceBranchEnd(body_head: *?*ir.Stmt, chain: ir.StmtBlock) void {
    const first = chain.first orelse return;
    var prev: ?*ir.Stmt = null;
    var cur = body_head.*;
    while (cur) |s| {
        if (s.next == null) break;
        prev = s;
        cur = s.next;
    }
    if (cur) |last| {
        if (last.code == .break_) {
            chain.last.?.next = last;
            if (prev) |p| p.next = first else body_head.* = first;
            return;
        }
        last.next = first;
    } else {
        body_head.* = first;
    }
}

fn semaElseStmt(c: *cy.Chunk, node: *ast.Node, outer: usize, is_last_else: bool, end_reachable: *bool) !void {
    if (node.type() == .elseif_block) {
        const block = node.cast(.elseif_block);

        const cond = try c.semaExprCstr(block.cond, c.sema.bool_t);
        _ = try sema_local.pushBlock(c, node);
        {
            try semaStmts(c, block.stmts);
            if (!is_last_else) {
                try semaBreakTo(c, outer, node);
            }
            end_reachable.* = c.block().endReachable;
        }
        const stmts = try sema_local.popBlock2(c, is_last_else);
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

/// The payload of `res` for `!else` once the error branch has left. A result that was a new value (a call)
/// gives up its payload like `!` does, so a `NoCopy` payload can be unwrapped. A place is copied.
pub fn semaMoveOrCopyResultPayload(c: *cy.Chunk, res: sema.ExprResult, owned: bool, node: *ast.Node) !sema.ExprResult {
    var payload = try sema_access.semaUnwrapResultNoCheck(c, res, node);
    if (owned) {
        if (res.recParentLocal()) |owner| {
            c.varStack.items[owner].type = .dead;
            payload.owned = true;
            return payload;
        }
    }
    return sema_expr.sema_copy(c, payload, node);
}

/// The option of `?else` before the block of the expression begins. A new value (a call) goes to `_opt` as it is,
/// and a `NoCopy` option that is read from a variable moves here, in the block of the statement (`o ?else x`): the
/// option always runs. Both let a `NoCopy` payload be unwrapped.
pub fn semaElseOptionOwner(c: *cy.Chunk, opt: sema.ExprResult, node: *ast.Node) !sema.ExprResult {
    if (opt.owned) return opt;
    if (opt.type.info.no_copy) return sema_move.semaOwn(c, opt, node);
    return sema_move.semaEnsureAddressable(c, opt, node);
}

pub fn semaUnwrapOrStmt(c: *cy.Chunk, opt: sema.ExprResult, res_ir_id: u32, outer: usize, node: *ast.Node) !void {
    const Data = struct {
        node: *ast.Node,
        res_ir_id: u32,
    };
    const S = struct {
        fn body(c_: *cy.Chunk, opt_id: u32, opt_local: sema.ExprResult, data_: *anyopaque) !void {
            const data: *Data = @ptrCast(@alignCast(data_));
            const unwrap_res = try sema_access.semaUnwrapOptionNoCheck(c_, opt_local, data.node);
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
    try semaIfUnwrapBlock2(c, opt, node, null, null, S.body, @ptrCast(&data), outer, false, node);
}
