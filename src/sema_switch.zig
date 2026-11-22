const std = @import("std");
const cy = @import("cyber.zig");
const ir = cy.ir;
const sema_func = cy.sema_func;
const ct_inline = cy.ct_inline;
const Argument = cy.sema_func.Argument;
const cte = cy.cte;
const fmt = cy.fmt;
const v = fmt.v;
const ast = cy.ast;
const Value = cy.Value;
const TypeValue = cy.TypeValue;
const sema = cy.sema;
const sema_stmt = cy.sema_stmt;
const sema_local = cy.sema_local;
const sema_call = cy.sema_call;
const sema_expr = cy.sema_expr;
const sema_resolve = cy.sema_resolve;
const sema_move = cy.sema_move;
const sema_borrow = cy.sema_borrow;

pub const SwitchInfo = struct {
    node: *ast.Node,
    control_t: *cy.Type,
    control_n: *ast.Node,
    control_is_choice: bool,

    // Target type can be given or inferred from the first case.
    opts: sema.Cstr,

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

    /// The local that holds the value of the control, which a borrow capture (`|&v|`) borrows from. The hidden
    /// `control` local that points to it is not bound to an owner.
    control_parent: ?sema.LocalId = null,

    /// The local that the value of the control borrows from, before a temp holds it. A copy capture (`|p|`) of a
    /// borrow payload borrows from it.
    control_owner: ?sema.LocalId = null,

    /// For a `switch` expression: the owner of a borrow result, joined over the cases (`sema_borrow.joinBranchOwner`).
    borrow_owner: ?sema.LocalId = null,

    /// For a `switch` statement: the moves of outer locals by its cases.
    moves: ?*CaseMoves = null,

    pub fn init(c: *cy.Chunk, control_n: *ast.Node, control: sema.ExprResult, is_expr: bool, opts: sema.Cstr, node: *ast.Node) !SwitchInfo {
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

    pub fn deinit(self: *SwitchInfo, alloc: std.mem.Allocator) void {
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

pub fn semaSwitchStmt(c: *cy.Chunk, block: *ast.SwitchBlock) !void {
    const var_start = c.varStack.items.len;
    // Determine the control type first.
    var control_expr = try c.semaExpr(block.expr, .{});
    const control_owner = control_expr.recParentLocal();
    control_expr = try sema_move.semaEnsureAddressable(c, control_expr, block.expr);
    const control_borrow_t = try sema.getBorrowType(c, control_expr.type);
    control_expr = try sema_expr.semaAddressOf(c, control_expr, control_borrow_t, block.expr);
    const control_local = try sema_local.declareHiddenLocal(c, "control", control_expr.type, control_expr, block.expr);
    var control = try sema_expr.semaLocal(c, control_local.id, block.expr);
    control = try sema_expr.semaDeref(c, control, block.expr);

    var info = try SwitchInfo.init(c, block.expr, control, false, .{}, @ptrCast(block));
    defer info.deinit(c.alloc);
    info.control_parent = control_expr.recParentLocal();
    info.control_owner = control_owner orelse info.control_parent;

    info.cond_local = (try sema_local.declareHiddenLocal(c, "_cond", c.sema.bool_t, null, @ptrCast(block))).id;

    if (block.cases.ptr[0].type() == .case_stmt) {
        if (block.cases.ptr[0].cast(.case_stmt).body_kind == .expr) {
            // Reserve local for result.
            const res_local = try sema_local.declareHiddenLocal(c, "_temp", c.sema.void_t, null, @ptrCast(block));
            info.res_local = res_local.id;
        }
    }

    var case_moves = CaseMoves{};
    defer case_moves.deinit(c.alloc);
    info.moves = &case_moves;
    try semaSwitchBody(c, &info, block, control);
    if (case_moves.kept.items.len > 0) {
        // Every way through the statement is a case: there is no implicit `else`.
        try sema_stmt.joinBranchMoves(c, @ptrCast(block), 0, case_moves.branches.items, case_moves.kept.items, true);
        // A local of a block further out is a move of the enclosing branch.
        for (case_moves.kept.items) |id| {
            if (id < c.block().varStart) try c.branch_moves.append(c.alloc, id);
        }
    }
    try sema_local.popLocals(c, var_start, @ptrCast(block));
}

/// The cases of a `switch` statement as branches that move outer locals (`joinBranchMoves`).
const CaseMoves = struct {
    branches: std.ArrayListUnmanaged(sema_stmt.IfBranch) = .empty,
    kept: std.ArrayListUnmanaged(sema.LocalId) = .empty,

    pub fn deinit(self: *CaseMoves, alloc: std.mem.Allocator) void {
        self.branches.deinit(alloc);
        self.kept.deinit(alloc);
    }
};

/// Begins the body block of a case. In a `switch` statement it can move outer locals.
fn pushCaseBlock(c: *cy.Chunk, info: *SwitchInfo, case: *ast.CaseStmt) !void {
    _ = try sema_local.pushBlock(c, @ptrCast(case));
    if (info.moves != null) c.block().move_branch = .branch;
}

/// Ends the body block of a case and makes its `switch_case`.
fn popCaseBlock(c: *cy.Chunk, info: *SwitchInfo, case: *ast.CaseStmt, conds: []*ir.Expr, fallthrough: bool) !*ir.Expr {
    const end_reachable = c.block().endReachable;
    const moves_start = c.block().moves_start;
    const var_start = c.block().varStart;
    const stmtBlock = try sema_local.popBlock(c);
    const case_ir = try c.ir.newExpr(.switch_case, c.sema.void_t, @ptrCast(case), .{
        .numConds = @intCast(conds.len),
        .body_head = stmtBlock.first,
        .conds = conds.ptr,
        .fallthrough = fallthrough,
    });
    if (info.moves) |moves| {
        if (!fallthrough) {
            try sema_stmt.endIfBranch(c, &moves.branches, &moves.kept, &case_ir.cast(.switch_case).body_head, end_reachable,
                moves_start, var_start, var_start);
        }
    }
    return case_ir;
}

pub fn semaSwitchExpr(c: *cy.Chunk, block: *ast.SwitchBlock, cstr: sema.Cstr) !sema.ExprResult {
    // Determine the control type first.
    var control_expr = try c.semaExpr(block.expr, .{});
    const control_owner = control_expr.recParentLocal();
    control_expr = try sema_move.semaEnsureAddressable(c, control_expr, block.expr);
    const control_borrow_t = try sema.getBorrowType(c, control_expr.type);
    control_expr = try sema_expr.semaAddressOf(c, control_expr, control_borrow_t, block.expr);
    const control_local = try sema_local.declareHiddenLocal(c, "control", control_expr.type, control_expr, block.expr);
    var control = try sema_expr.semaLocal(c, control_local.id, block.expr);
    control = try sema_expr.semaDeref(c, control, block.expr);

    var info = try SwitchInfo.init(c, block.expr, control, true, cstr, @ptrCast(block));
    defer info.deinit(c.alloc);
    info.control_parent = control_expr.recParentLocal();
    info.control_owner = control_owner orelse info.control_parent;

    info.cond_local = (try sema_local.declareHiddenLocal(c, "_cond", c.sema.bool_t, null, @ptrCast(block))).id;

    // Reserve local for result.
    const res_local = try sema_local.declareHiddenLocal(c, "_temp", cstr.target_t orelse c.sema.void_t, null, @ptrCast(block));
    info.res_local = res_local.id;

    // The cases move outer locals like the ones of a `switch` statement.
    var case_moves = CaseMoves{};
    defer case_moves.deinit(c.alloc);
    info.moves = &case_moves;
    try semaSwitchBody(c, &info, block, control);
    if (case_moves.kept.items.len > 0) {
        try sema_stmt.joinBranchMoves(c, @ptrCast(block), 0, case_moves.branches.items, case_moves.kept.items, true);
        // The block around the expression can be one that passes its moves on (the condition of an `if` statement).
        const parent_start = c.semaBlocks.items[sema_move.moveBlockFrom(c, c.semaBlocks.items.len - 1)].varStart;
        for (case_moves.kept.items) |id| {
            if (id < parent_start) try c.branch_moves.append(c.alloc, id);
        }
    }

    if (info.opts.target_t == null) {
        return c.reportError("Expected to infer target type.", block.expr);
    }

    const res = (try sema_expr.semaLocal(c, res_local.id, info.node)).ir;
    c.varStack.items[res_local.id].type = .dead;
    var switch_res = sema.ExprResult.initOwned(res);
    switch_res.data.value.parent_local = info.borrow_owner;
    return switch_res;
}

/// Saves reference to the control local for unwrapping.
/// Returns the tag as the new control.
fn semaSwitchChoicePrologue(c: *cy.Chunk, info: *SwitchInfo, control: sema.ExprResult, node: *ast.Node) !void {
    // Get choice tag for switch expr.
    const expr = try c.ir.newExpr(.field, c.sema.i64_t, node, .{
        .idx = 0,
        .rec = control.ir,
    });
    const tag_expr = sema.ExprResult.init2(expr);

    const choice_tag = try sema_local.declareHiddenLocal(c, "_choice_tag", c.sema.i64_t, tag_expr, node);
    info.choice_tag_local = @intCast(choice_tag.id);
}

fn semaSwitchBody(c: *cy.Chunk, info: *SwitchInfo, block: *ast.SwitchBlock, control: sema.ExprResult) !void {
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
                var func_sym = try sema_call.requireFuncSym(c, iterator_sym, iter_n);
                var iter = try cte.callFuncSymRec(c, func_sym, iter_n, sema.ExprResult.initCtValue(iterable), &.{}, child);
                defer c.heap.destructValue(iter);

                // while iter.next()
                const next_sym = try c.accessResolvedSymOrFail(iterable.type, "next", iter_n);
                func_sym = try sema_call.requireFuncSym(c, next_sym, iter_n);
                const borrow_t = try sema.getBorrowType(c, iter.type);
                var iter_borrow: TypeValue = undefined;
                if (iter.type.is_cte_boxed()) {
                    iter_borrow = TypeValue.init(borrow_t, iter.value);
                } else {
                    iter_borrow = TypeValue.init(borrow_t, Value.initPtr(@ptrCast(&iter.value)));
                }
                const args = [_]sema_func.Argument{
                    sema_func.Argument.initReceiver(iter_n, sema.ExprResult.initCtValue(iterable)),
                    sema_func.Argument.initPreResolved(iter_n, sema.ExprResult.initCtValue(iter_borrow)),
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
                        const cx = sema_resolve.getResolveContext(c);
                        try cx.initCtVar2(c.alloc, each.as_name(), value_t, value);
                    }
                    defer {
                        if (for_stmt.each) |each| {
                            const cx = sema_resolve.getResolveContext(c);
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

    try pushCaseBlock(c, info, case);
    if (case.body_kind == .expr) {
        const body = case.body_data.expr;
        var expr = try c.semaExpr(body, info.opts);
        info.borrow_owner = try sema_borrow.joinCaseOwner(c, info.borrow_owner, expr, c.block().varStart, body);
        expr = try sema_move.semaOwn(c, expr, body);

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

        try sema_stmt.semaStmts(c, case.body_data.block.slice());
    }

    if (info.exhaust_enum) {
        @memset(info.enum_coverage, true);
        info.enum_num_covered = @intCast(info.enum_coverage.len);
    }

    if (!info.end_reachable and c.block().endReachable) {
        info.end_reachable = true;
    }
    return popCaseBlock(c, info, case, &.{}, false);
}

fn semaSwitchCase(c: *cy.Chunk, info: *SwitchInfo, case: *ast.CaseStmt, control: sema.ExprResult) !*ir.Expr {
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

    try pushCaseBlock(c, info, case);

    if (hasCapture) {
        const capture_t = case_capture_type orelse {
            return c.reportError("Only a case of a choice can capture a payload.", case.data.case.capture.?);
        };

        // Copy payload to captured var.
        const fieldLoc = try c.ir.newExpr(.field, capture_t, case.data.case.capture.?, .{
            .idx = 1,
            .rec = control.ir,
        });
        // The payload lives in the control, so a capture borrows from the owner of the control.
        var capture = sema.ExprResult.initField(fieldLoc, info.control_parent);
        capture.addressable = true;

        switch (case.data.case.capture.?.type()) {
            .ident => {
                const name = case.data.case.capture.?.cast(.ident).name.slice();
                capture = try sema_expr.sema_copy(c, capture, case.data.case.capture.?);
                // A copy of a borrow payload points to what the control borrows, not into the control.
                switch (capture.resType) {
                    .value_field => capture.data.value_field.parent_local = info.control_owner,
                    .value => capture.data.value.parent_local = info.control_owner,
                    else => {},
                }
                const capture_v = try sema_local.declareLocalInit(c, name, capture_t, capture, case.data.case.capture.?);
                try sema_borrow.bindCaptureLocal(c, capture_v.id, capture);
            },
            .borrow => {
                const borrow = case.data.case.capture.?.cast(.borrow);
                if (borrow.child.type() != .ident) {
                    return c.reportError("Unsupported capture.", borrow.child);
                }
                const name = borrow.child.cast(.ident).name.slice();
                const borrow_t = try sema.getBorrowType(c, capture_t);
                capture = try sema_expr.semaAddressOf(c, capture, borrow_t, case.data.case.capture.?);
                const capture_v = try sema_local.declareLocalInit(c, name, borrow_t, capture, case.data.case.capture.?);
                try sema_borrow.bindCaptureLocal(c, capture_v.id, capture);
            },
            else => {
                return c.reportError("Unsupported capture.", case.data.case.capture.?);
            },
        }
    }

    if (case.body_kind == .expr) {
        const body = case.body_data.expr;

        var body_expr: sema.ExprResult = undefined;
        if (info.opts.target_t == null) {
            // Infer target type.
            body_expr = try c.semaExpr(body, info.opts);
            info.setTargetType(c, body_expr.type);
        } else {
            body_expr = try c.semaExprCstr(body, info.opts.target_t.?);
        }
        info.borrow_owner = try sema_borrow.joinCaseOwner(c, info.borrow_owner, body_expr, c.block().varStart, body);
        body_expr = try sema_move.semaOwn(c, body_expr, body);

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

        try sema_stmt.semaStmts(c, case.body_data.block.slice());
    } else {
        @panic("unexpected");
    }

    const fallthrough = case.body_kind == .fallthrough;
    if (!fallthrough) {
        if (!info.end_reachable and c.block().endReachable) {
            info.end_reachable = true;
        }
    }
    return popCaseBlock(c, info, case, conds, fallthrough);
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

    const tag_local = try sema_expr.semaLocal(c, info.choice_tag_local, right_n);

    out_payload_t.* = case.payload_t;
    const right = try c.semaConst(case.val, c.sema.i64_t, right_n);
    const res = try sema_expr.semaCompare(c, info.control_n, tag_local, right_n, right, right_n);
    return c.ir.newExpr(.case_cond, c.sema.void_t, right_n, .{
        .body_head = null,
        .expr = res.ir,
    });
}

fn semaCaseCondEnd(c: *cy.Chunk, var_start: usize, cond_local: u32, control_n: *ast.Node, control: sema.ExprResult, right_n: *ast.Node, right: sema.ExprResult) !*ir.Expr {
    var cond_res = try sema_expr.semaCompare(c, control_n, control, right_n, right, right_n);
    if (c.varStack.items.len > var_start) {
        _ = try c.ir.pushStmt(.set_local, right_n, .{
            .id = c.varStack.items[cond_local].inner.local.id,
            .right = cond_res.ir,
        });
        try sema_local.popLocals(c, var_start, right_n);
        cond_res = try sema_expr.semaLocal(c, cond_local, right_n);
    }
    const cond_block = c.ir.popStmtBlock();
    return c.ir.newExpr(.case_cond, c.sema.void_t, right_n, .{
        .body_head = cond_block.first,
        .expr = cond_res.ir,
    });
}

fn semaCaseCond(c: *cy.Chunk, info: *SwitchInfo, conds_buf: *std.ArrayList(*ir.Expr), expr_n: *ast.Node, expr: sema.ExprResult, cond: *ast.Node) !void {
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
            const greater = try sema_expr.sema_bin_expr3(c, expr, expr_n, min, range.start.?, .greater_equal, cond);

            const max = try ct_inline.value(c, end, info.control_t, range.end.?);
            const less = try sema_expr.sema_bin_expr3(c, expr, expr_n, max, range.end.?, .less_equal, cond);

            const cond_res = try sema_expr.semaLogicAnd2(c, range.start.?, greater, range.end.?, less, cond);
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
