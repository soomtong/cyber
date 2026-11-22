const std = @import("std");
const cy = @import("cyber.zig");
const ir = cy.ir;
const sema_func = cy.sema_func;
const Argument = cy.sema_func.Argument;
const cte = cy.cte;
const fmt = cy.fmt;
const v = fmt.v;
const module = cy.module;
const ast = cy.ast;
const log = cy.log.scoped(.sema);
const sema = cy.sema;
const sema_stmt = cy.sema_stmt;
const sema_local = cy.sema_local;
const sema_borrow = cy.sema_borrow;
const sema_call = cy.sema_call;
const sema_expr = cy.sema_expr;
const sema_access = cy.sema_access;
const sema_move = cy.sema_move;

fn semaAssignToIndexStmt(c: *cy.Chunk, left: *ast.IndexExpr, right: *ast.Node, node: *ast.Node) !void {
    var rec = try c.semaExpr(left.left, .{});
    // rec = try semaManage(c, rec, left.left);

    // `T`, `&T`, `^T` will look for `T.@set_index`
    // `Ptr[T]` will skip @set_index.
    if (!rec.type.isPointer()) {
        // First look for `@set_index`.
        if (try c.accessResolvedSym(rec.type, "@set_index", node)) |set_index_sym| {
            const func_sym = try sema_call.requireFuncSym(c, set_index_sym, @ptrCast(left));
            const args = [_]sema_func.Argument{
                sema_func.Argument.initReceiver(left.left, rec),
                sema_func.Argument.init(left.args.ptr[0]),
                sema_func.Argument.init(right),
            };
            const res = try c.semaCallFuncSymRec2(func_sym, &args, node);
            if (res.ir.code == .call) {
                // `@set_index` destructs the old element when it is managed.
                const params = res.ir.cast(.call).func.sig.params();
                if (params.len == 3 and params[2].get_type().isManaged()) {
                    try sema_borrow.checkWriteAccess(c, rec, node);
                }
            }
            _ = try sema_local.declareHiddenLocal(c, "_res", res.type, res, node);
            return;
        }
    }

    var ptr: sema.ExprResult = undefined;
    if (rec.type.isPointer()) {
        const idx = try c.semaExprCstr(left.args.ptr[0], c.sema.i64_t);
        ptr = try sema_access.sema_ptr_index(c, rec, idx, node);
    } else if (try c.accessResolvedSym(rec.type, "@index_addr", node)) |index_addr_sym| {
        // Default to `@index_addr` and `set_deref`.
        const index_addr_fsym = try sema_call.requireFuncSym(c, index_addr_sym, @ptrCast(left));
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
    try sema_borrow.checkFieldBorrowOutlives(c, rec, val, right);
    try sema_borrow.addFieldBorrowLoan(c, rec, val);
    val = try sema_move.semaOwn(c, val, right);

    if (target_t.isManaged()) {
        try sema_borrow.checkWriteAccess(c, rec, node);
        const res = try sema_local.declareHiddenLocal(c, "_res", target_t, val, right);
        const res_local = try sema_expr.semaLocal(c, res.id, right);

        const deref_loc = try c.ir.newExpr(.deref, target_t, node, .{
            .expr = ptr.ir,
        });
        const deref = sema.ExprResult.init(deref_loc, target_t);
        const temp = try sema_local.declareHiddenLocal(c, "_temp", target_t, deref, @ptrCast(left));
        try sema_local.semaDestructLocal(c, &c.varStack.items[temp.id], @ptrCast(left));
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

fn semaAssignToAccessStmt(c: *cy.Chunk, var_start: usize, rec_n: *ast.Node, rec: sema.ExprResult, access_right_n: *ast.Node, access_right_name: []const u8, right: *ast.Node, opts: AssignOptions, node: *ast.Node) !void {
    if (rec.resType == .sym) {
        const right_sym = try c.getResolvedSymOrFail(rec.data.sym, access_right_name, right);
        try c.checkResolvedSymIsDistinct(right_sym, right);
        try sema_local.referenceSym(c, right_sym, right);

        const sym = try sema_expr.symbol(c, right_sym, false, right);
        if (sym.resType == .varSym) {
            const cstr = sema.Cstr.initRequire((try c.getSymValueType(sym.data.varSym)).?);
            var right_res = try c.semaExprOrOpAssignBinExpr(right, cstr, opts.rhsOpAssignBinExpr);
            right_res = try sema_move.semaOwn(c, right_res, right);

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
            const func_sym = try sema_call.requireFuncSym(c, sym, node);

            // const child_cstr = Cstr.init(func_sym.first.sig.params_ptr[2].get_type());
            const right_res = try c.semaExprOrOpAssignBinExpr(right, .{}, opts.rhsOpAssignBinExpr);

            const field_name = try c.heap.init_eval_str(access_right_name);
            defer c.heap.release(field_name);

            const args = [3]sema_func.Argument{
                sema_func.Argument.initReceiver(rec_n, rec),
                sema_func.Argument.initPreResolved(access_right_n, sema.ExprResult.initCtValue2(c.sema.eval_str_t, field_name)),
                sema_func.Argument.initPreResolved(right, right_res),
            };
            const call = try c.semaCallFuncSymRec2(func_sym, &args, node);
            _ = try sema_local.declareHiddenLocal(c, "_res", call.type, call, node);
            try sema_local.popLocals(c, var_start, node);
            return;
        }

        const type_name = try c.sema.allocTypeName(type_sym.type);
        defer c.alloc.free(type_name);
        return c.reportErrorFmt("Field `{}` does not exist in `{}`.", &.{v(access_right_name), v(type_name)}, access_right_n);
    };

    try cy.module.check_sym_visible(c, sym, access_right_n);
    if (sym.type != .field) {
        return sema_access.reportNotField(c, type_sym.type.name(), access_right_name, sym, access_right_n);
    }
    const field_s = sym.cast(.field);

    // Assigning to a member that was moved out revives it (F-79). `rec` carries the access path
    // when its root local has inactive members. Resolve the member's states before the rhs is
    // evaluated since the rhs can overwrite `c.temp_access_path`.
    var revive: ?ReviveMember = null;
    if (rec.check_struct_field_access and rec.type.kind() == .struct_t) {
        const var_id = c.temp_access_path.var_id;
        sema_access.step_member_access_path(c, rec.type, field_s.idx, field_s.type);
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

    const cstr = sema.Cstr.initRequire(field_s.type);
    var right_res = try c.semaExprOrOpAssignBinExpr(right, cstr, opts.rhsOpAssignBinExpr);
    try sema_borrow.checkFieldBorrowOutlives(c, rec, right_res, right);
    try sema_borrow.addFieldBorrowLoan(c, rec, right_res);
    if (field_s.type.isManaged()) {
        try sema_borrow.checkFieldWriteAccess(c, rec, @intCast(field_s.idx), node);
    }
    right_res = try sema_move.semaOwn(c, right_res, right);

    if (revive) |rv| {
        if (field_s.type.isManaged()) {
            // Store new value.
            const res = try sema_local.declareHiddenLocal(c, "_res", field_s.type, right_res, right);
            const res_local = try sema_expr.semaLocal(c, res.id, right);

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
        const res = try sema_local.declareHiddenLocal(c, "_res", field_s.type, right_res, right);
        const res_local = try sema_expr.semaLocal(c, res.id, right);

        // Move existing to temp local.
        const field = sema.ExprResult.init(loc, field_s.type);
        const temp = try sema_local.declareHiddenLocal(c, "_temp", field_s.type, field, access_right_n);

        // Destruct existing.
        try sema_local.semaDestructLocal(c, &c.varStack.items[temp.id], access_right_n);
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
    var_id: sema.LocalId,
    /// Offset of the member's states in the owner's state vector.
    offset: usize,
    len: usize,
    /// Some states of the member are still alive. The old value needs a partial destruct.
    partial: bool,
};

/// Partially destruct the struct member `field_loc`: only its members that `states` marks alive.
fn sema_call_partial_destruct_member(c: *cy.Chunk, field_loc: *ir.Expr, field_t: *cy.Type, states: []bool, node: *ast.Node) !void {
    const ptr_t = try sema.getPtrType(c, field_t);
    const field = sema.ExprResult.init(field_loc, field_t);
    const addr = try sema_expr.semaAddressOf(c, field, ptr_t, node);
    const layout = try sema_access.ensure_partial_struct_layout(c, states);
    const dtor = try sema.get_partial_dtor(c, field_t, layout, node);
    const arg = Argument.initPreResolved(node, addr);
    const call = try c.semaCallFunc2(dtor, &.{arg}, &.{}, node);
    _ = try c.ir.pushStmt(.discard, node, .{ .expr = call.ir });
}

fn semaAssignToGlobal(c: *cy.Chunk, left: sema.ExprResult, left_n: *ast.Node, right: sema.ExprResult, right_n: *ast.Node, node: *ast.Node) !void {
    // Destruct first.
    const var_t = (try c.getSymValueType(left.data.varSym)).?;
    if (var_t.isManaged()) {
        const res = try sema_local.declareHiddenLocal(c, "_res", var_t, right, right_n);
        const res_local = try sema_expr.semaLocal(c, res.id, right_n);

        const temp = try sema_local.declareHiddenLocal(c, "_temp", var_t, left, left_n);
        try sema_local.semaDestructLocal(c, &c.varStack.items[temp.id], left_n);
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

/// A node of the left side of `x op= y` whose value is held in the hidden local `id` for the statement.
pub const PlaceSubst = struct {
    node: *ast.Node,
    id: sema.LocalId,
};

/// Sema of a node that `stabilizeOpAssignLeft` evaluated reads its local.
pub fn semaPlaceSubst(c: *cy.Chunk, node: *ast.Node) !?sema.ExprResult {
    var i = c.place_subst.items.len;
    while (i > 0) {
        i -= 1;
        const e = c.place_subst.items[i];
        if (e.node == node) return try sema_expr.semaLocal(c, e.id, node);
    }
    return null;
}

/// `x op= y` is `x = x op y`, and the left side is analyzed twice: once to read and once to write. A receiver or an
/// index that can have a side effect (`f()[g()] += 1`, `get(p).a += 1`, `ptr().* += 1`) is evaluated once, before the
/// right side, into a hidden local, and both analyses read the local. A variable, a field path, a constant and an
/// operator expression of those are analyzed twice as before, so `x += 1` and `a[i] += 1` keep their IR.
fn stabilizeOpAssignLeft(c: *cy.Chunk, node: *ast.Node, top: bool) !void {
    switch (node.type()) {
        .ident, .at_lit => {},
        .group => try stabilizeOpAssignLeft(c, node.cast(.group).child, top),
        .accessExpr => try stabilizeOpAssignLeft(c, node.cast(.accessExpr).left, false),
        .deref => try stabilizeOpAssignLeft(c, node.cast(.deref).left, false),
        .index_expr => {
            const index = node.cast(.index_expr);
            try stabilizeOpAssignLeft(c, index.left, false);
            if (index.args.len == 1) {
                const arg = index.args.ptr[0];
                if (arg.type() != .range and !isPureOperand(arg)) {
                    try holdOperand(c, arg);
                }
            }
        },
        .callExpr => {
            const call = node.cast(.callExpr);
            if (top) {
                // `meta.access(rec, name) op= y`.
                if (call.args.len == 2) try stabilizeOpAssignLeft(c, call.args.ptr[0], false);
                return;
            }
            try holdOperand(c, node);
        },
        else => {
            if (!isPureOperand(node)) try holdOperand(c, node);
        },
    }
}

/// An operand that can be evaluated twice: it has no side effect and evaluates to the same value.
fn isPureOperand(node: *ast.Node) bool {
    return switch (node.type()) {
        .ident, .at_lit, .binLit, .decLit, .hexLit, .octLit, .floatLit, .trueLit, .falseLit, .noneLit, .void_lit,
        .string_lit, .raw_string_lit, .sq_string_lit, .string_multi_lit, .raw_string_multi_lit, .sq_string_multi_lit,
        .dot_lit, .error_lit => true,
        .group => isPureOperand(node.cast(.group).child),
        .accessExpr => isPureOperand(node.cast(.accessExpr).left),
        .unary_expr => isPureOperand(node.cast(.unary_expr).child),
        .binExpr => isPureOperand(node.cast(.binExpr).left) and isPureOperand(node.cast(.binExpr).right),
        else => false,
    };
}

/// Evaluates `node` into a hidden local that lives until the statement ends.
fn holdOperand(c: *cy.Chunk, node: *ast.Node) !void {
    const res = try c.semaExprSkipSym(node, .{});
    if (res.resType != .value) return;
    // A place is read again like a variable.
    if (res.addressable) return;
    if (res.type.kind() == .void or res.type.kind() == .never) return;
    // A managed value that is not owned has no local to own it.
    if (res.type.isManaged() and !res.owned) return;
    const temp = try sema_local.declareHiddenLocal(c, "_place", res.type, res, node);
    c.varStack.items[temp.id].lifetime = .initTemp();
    try c.place_subst.append(c.alloc, .{ .node = node, .id = temp.id });
}

const AssignOptions = struct {
    rhsOpAssignBinExpr: bool = false,
};

/// Pass rightId explicitly to perform custom sema on op assign rhs.
pub fn semaAssignStmt(c: *cy.Chunk, node: *ast.Node, left_n: *ast.Node, right: *ast.Node, opts: AssignOptions) !void {
    var var_start = c.varStack.items.len;
    const subst_start = c.place_subst.items.len;
    defer c.place_subst.items.len = subst_start;
    if (opts.rhsOpAssignBinExpr) {
        try stabilizeOpAssignLeft(c, left_n, true);
    }
    switch (left_n.type()) {
        .index_expr => {
            const left = left_n.cast(.index_expr);
            if (left.args.len != 1) {
                return c.reportErrorFmt("Unsupported array expr.", &.{}, left_n);
            }
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
            try sema_local.popLocals(c, var_start, node);
            if (cy.Trace) {
                try sema_stmt.check_locals(c, var_start, node);
            }
            return;
        },
        .accessExpr => {
            const left = left_n.cast(.accessExpr);

            if (!opts.rhsOpAssignBinExpr and try sema_call.reuseMemberSliceBuffer(c, left_n, right, node)) {
                try sema_local.popLocals(c, var_start, node);
                return;
            }
            var rec = try c.semaExprSkipSym(left.left, .{});
            if (!rec.addressable) {
                rec = try sema_move.semaManage(c, rec, left.left);
            }
            const name = left.right.as_name();
            try semaAssignToAccessStmt(c, var_start, left.left, rec, left.right, name, right, opts, node);
            try sema_local.popLocals(c, var_start, node);
            if (cy.Trace) {
                try sema_stmt.check_locals(c, var_start, node);
            }
            return;
        }, 
        .callExpr => {
            const call = left_n.cast(.callExpr);
            const sym = try cte.evalSym(c, call.callee);
            const access_fn = try sema_call.requireFuncSym(c, sym, call.callee);
            if (access_fn.first == c.sema.access_fn) {
                if (call.args.len != 2) {
                    return c.reportError("Expected 2 arguments.", left_n);
                }

                var rec = try c.semaExprSkipSym(call.args.ptr[0], .{});
                if (!rec.addressable) {
                    rec = try sema_move.semaManage(c, rec, call.args.ptr[0]);
                }
                const name = try cte.evalCheck(c, call.args.ptr[1], c.sema.str_t);
                defer c.heap.destructValue(name);

                try semaAssignToAccessStmt(c, var_start, call.args.ptr[0], rec, call.args.ptr[1], name.value.asString(), right, opts, node);
                try sema_local.popLocals(c, var_start, node);
                if (cy.Trace) {
                    try sema_stmt.check_locals(c, var_start, node);
                }
                return;
            }
        },
        .deref => {
            const ptr_n = left_n.cast(.deref).left;
            var ptr = try c.semaExpr(ptr_n, .{});
            ptr = try sema_move.semaManage(c, ptr, ptr_n);

            var child_t: *cy.Type = undefined;
            if (ptr.type.kind() == .pointer) {
                child_t = ptr.type.cast(.pointer).child_t;
            } else if (ptr.type.kind() == .borrow) {
                child_t = ptr.type.cast(.borrow).child_t;
            } else if (ptr.type.kind() == .ex_borrow) {
                child_t = ptr.type.cast(.ex_borrow).child_t;
            } else {
                return c.reportError("Expected pointer type.", ptr_n);
            }
            const expr = sema.Cstr.initRequire(child_t);
            // A local on the right is borrowed: own a copy, or the local and the target release one value twice.
            const right_res = try sema_move.semaOwn(c, try c.semaExprOrOpAssignBinExpr(right, expr, opts.rhsOpAssignBinExpr), right);

            if (child_t.isManaged()) {
                try sema_borrow.checkWriteAccess(c, ptr, node);
                const res = try sema_local.declareHiddenLocal(c, "_res", child_t, right_res, right);
                const res_local = try sema_expr.semaLocal(c, res.id, right);

                const deref_loc = try c.ir.newExpr(.deref, child_t, node, .{
                    .expr = ptr.ir,
                });
                const deref = sema.ExprResult.init(deref_loc, child_t);
                const temp = try sema_local.declareHiddenLocal(c, "_temp", child_t, deref, left_n);
                try sema_local.semaDestructLocal(c, &c.varStack.items[temp.id], left_n);
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
            try sema_local.popLocals(c, var_start, node);
            if (cy.Trace) {
                try sema_stmt.check_locals(c, var_start, node);
            }
            return;
        },
        .ident => {
            var right_res: sema.ExprResult = undefined;
            if (!opts.rhsOpAssignBinExpr) {
                c.assign_left = left_n;
            }
            const leftRes = c.semaExprSkipSym(left_n, .{}) catch |err| {
                c.assign_left = null;
                return err;
            };
            c.assign_left = null;
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

                if (svar.type == .dead and id < c.block().varStart and !movedInBlock(c, id)) {
                    // A loop body or a branch would leave the local alive on one path and moved on another.
                    return reportAssignMovedOuter(c, id, left_n);
                }

                var right_cstr = sema.Cstr.initRequire(svar.decl_t);
                right_cstr.assign_to_local = true;
                // The right side can move the local (`r = eat(r)`): the assignment gives it a value again.
                const revive = AssignRevive{ .id = id, .block = @intCast(c.semaBlocks.items.len - 1), .prev = c.assign_revive };
                const saved_revive = c.assign_revive;
                if (!opts.rhsOpAssignBinExpr and !svar.inner.local.hidden and !sema_move.isPersistedMainLocal(c, id)) {
                    c.assign_revive = &revive;
                }
                var borrow_init: sema.ExprResult = undefined;
                {
                    defer c.assign_revive = saved_revive;
                    right_res = try semaAssignRight(c, left_n, right, right_cstr, opts.rhsOpAssignBinExpr);
                    if (right_res.resType == .value and right_res.data.value.has_aux_local) {
                        var_start += 1;
                    }
                    try sema_borrow.checkBorrowOutlives(c, id, right_res, right);
                    // `svar` can be stale here: the right side can add locals.
                    if (c.varStack.items[id].decl_t.isManaged() and c.varStack.items[id].type != .dead) {
                        // The old value is destructed.
                        try sema_borrow.checkExclusiveBorrowOfField(c, id, sema.borrow_field_whole, true, node);
                    }
                    borrow_init = right_res;
                    right_res = try sema_move.semaOwn(c, right_res, right);
                }
                // A local that was moved, before the statement or by its right side, has no value to destruct.
                const moved = c.varStack.items[id].type == .dead;
                if (moved and sema_move.isPersistedMainLocal(c, id)) {
                    // A failure of the right side at runtime would leave the moved local to the next input.
                    const name = c.varStack.items[id].name();
                    return c.reportErrorFmt("Cannot assign to the top level variable `{}` of the REPL after it was moved. Declare it again with `{} := ...`.", &.{v(name), v(name)}, left_n);
                }

                if (right_res.type.isManaged()) {
                    const tempv = try sema_local.declareHiddenLocal(c, "_temp", right_res.type, right_res, right);
                    right_res = try sema_expr.semaLocal(c, tempv.id, node);
                    if (!moved) {
                        try sema_local.semaDestructLocal(c, &c.varStack.items[leftRes.data.value_local], left_n);
                    }
                    c.varStack.items[tempv.id].type = .dead;
                }
                if (moved) try reviveLocal(c, id);

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
                sema_borrow.unbindBorrowLocal(c, local);
                try sema_borrow.checkBindBorrow(c, leftRes.data.value_local, borrow_init, right);
                try sema_borrow.bindBorrowLocal(c, leftRes.data.value_local, borrow_init);

                _ = try c.ir.pushStmt(.set_local, node, .{
                    .id = local.inner.local.id,
                    .right = right_res.ir,
                });
                try sema_local.popLocals(c, var_start, node);
                if (cy.Trace) {
                    try sema_stmt.check_locals(c, var_start, node);
                }
                return;
            } else if (leftRes.resType == .value_field) {
                const expr = sema.Cstr.initRequire(leftT);
                right_res = try c.semaExprOrOpAssignBinExpr(right, expr, opts.rhsOpAssignBinExpr);
                try sema_borrow.checkFieldBorrowOutlives(c, leftRes, right_res, right);
                try sema_borrow.addFieldBorrowLoan(c, leftRes, right_res);
                if (leftT.isManaged()) {
                    try sema_borrow.checkWriteAccess(c, leftRes, node);
                }
                right_res = try sema_move.semaOwn(c, right_res, right);
                _ = try c.ir.pushStmt(.set_field, left_n, .{
                    .field = leftRes.ir,
                    .right = right_res.ir,
                });
                try sema_local.popLocals(c, var_start, node);
                if (cy.Trace) {
                    try sema_stmt.check_locals(c, var_start, node);
                }
                return;
            } else {
                const right_cstr = sema.Cstr.initRequire(leftT);
                right_res = try semaAssignRight(c, left_n, right, right_cstr, opts.rhsOpAssignBinExpr);
                right_res = try sema_move.semaOwn(c, right_res, right);
            }

            switch (leftRes.resType) {
                .const_ => {
                    return c.reportErrorFmt("Cannot assign to a constant.", &.{}, node);
                },
                .varSym         => {
                    try semaAssignToGlobal(c, leftRes, left_n, right_res, right, node);
                    try sema_local.popLocals(c, var_start, node);
                    if (cy.Trace) {
                        try sema_stmt.check_locals(c, var_start, node);
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
                    try sema_local.popLocals(c, var_start, node);
                    if (cy.Trace) {
                        try sema_stmt.check_locals(c, var_start, node);
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

/// The right side of `left_n = right`. While it is analyzed, the chunk knows the variable that is assigned
/// (`Chunk.assign_target`).
/// An assignment `x = right` to the local `id`, while its right side is checked. The right side can move the local
/// where it always runs (`r = eat(r)`, `xs = xs.appended(v)`): the local is alive again when the statement ends, so
/// the move is allowed from a loop body or any other block too. See `docs/decisions/project_last_use.md`.
pub const AssignRevive = struct {
    id: sema.LocalId,
    /// The block of the statement. A move from a deeper block is a part that is evaluated conditionally, or a lambda.
    block: u32,
    prev: ?*const AssignRevive,
};

/// Whether a move of the whole local `id` at this point is undone by the assignment to it that is being checked.
pub fn movesIntoAssign(c: *cy.Chunk, id: sema.LocalId) bool {
    const rev = c.assign_revive orelse return false;
    return rev.id == id and rev.block == c.semaBlocks.items.len - 1;
}

/// Whether the outer local `id` was moved in the current block (or by a statement of it that joined its branches):
/// every path to this point moved it, so an assignment here gives it a value on every path, and the block then ends
/// like one that did not move it.
fn movedInBlock(c: *cy.Chunk, id: sema.LocalId) bool {
    const b = c.block();
    if (b.move_branch != .branch and b.move_branch != .plain) return false;
    return std.mem.indexOfScalar(sema.LocalId, c.branch_moves.items[b.moves_start..], id) != null;
}

/// The assignment gives the moved local `id` a value: it is alive again.
fn reviveLocal(c: *cy.Chunk, id: sema.LocalId) !void {
    // The move is no longer one that the block leaves to its `if` statement or loop.
    var i: usize = c.block().moves_start;
    while (i < c.branch_moves.items.len) {
        if (c.branch_moves.items[i] == id) {
            _ = c.branch_moves.orderedRemove(i);
        } else i += 1;
    }
    if (c.move_undo_depth > 0) {
        try c.move_undo.append(c.alloc, .{ .id = id, .revive = true, .site = c.moved_sites.get(id), .has_site = true });
    }
    c.varStack.items[id].type = .local;
    _ = c.moved_sites.remove(id);
}

fn reportAssignMovedOuter(c: *cy.Chunk, id: sema.LocalId, node: *ast.Node) anyerror {
    const local = c.varStack.items[id];
    const site = c.moved_sites.get(id).?;
    const ast_ = c.compiler.chunks.items[site.src()].ast;
    var line: u32 = undefined;
    var col: u32 = undefined;
    var line_start: u32 = undefined;
    ast_.computeLinePos(site.pos(), &line, &col, &line_start);
    return c.reportErrorFmt("Cannot assign to `{}` here: it was moved at {}:{} and it is declared in an outer block. Assign to it in the block that declares it, or declare a new variable.", &.{v(local.name()), v(line + 1), v(col + 1)}, node);
}

/// A jump out of the block `block_idx` (`break`, `continue`, a failing `!` in a `try` block). The right side of an
/// assignment that moved its local can not jump to where the local is still declared: the local would be read as
/// alive there.
pub fn checkAssignMoveJump(c: *cy.Chunk, block_idx: usize, node: *ast.Node) !void {
    var cur = c.assign_revive;
    while (cur) |rev| : (cur = rev.prev) {
        if (block_idx > rev.block) continue;
        const local = c.varStack.items[rev.id];
        if (local.type != .dead or rev.id >= c.semaBlocks.items[block_idx].varStart) continue;
        return c.reportErrorFmt("Cannot leave the assignment to `{}` here: its right side moved `{}`, which is declared outside the block that ends here. Move it to a new variable in a statement before this one.", &.{v(local.name()), v(local.name())}, node);
    }
}

fn semaAssignRight(c: *cy.Chunk, left_n: *ast.Node, right: *ast.Node, cstr: sema.Cstr, op_assign_bin_expr: bool) !sema.ExprResult {
    c.assign_target = left_n;
    c.assign_right = right;
    defer {
        c.assign_target = null;
        c.assign_right = null;
    }
    return c.semaExprOrOpAssignBinExpr(right, cstr, op_assign_bin_expr);
}
