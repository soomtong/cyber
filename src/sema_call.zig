const std = @import("std");
const cy = @import("cyber.zig");
const ir = cy.ir;
const rt = cy.rt;
const bt = cy.types.BuiltinTypes;
const sema_func = cy.sema_func;
const Argument = cy.sema_func.Argument;
const fmt = cy.fmt;
const v = fmt.v;
const ast = cy.ast;
const Sym = cy.Sym;
const sema = cy.sema;
const sema_stmt = cy.sema_stmt;
const sema_local = cy.sema_local;
const sema_expr = cy.sema_expr;
const sema_hint = cy.sema_hint;
const sema_assign = cy.sema_assign;
const sema_access = cy.sema_access;
const sema_move = cy.sema_move;
const sema_init = cy.sema_init;

/// A method call `recv.method(args)`: the receiver node and the method name.
const MethodCall = struct {
    recv: *ast.Node,
    method: []const u8,
};

fn methodCallOf(node: *ast.Node) ?MethodCall {
    if (node.type() != .callExpr) return null;
    const call = node.cast(.callExpr);
    if (call.callee.type() != .accessExpr) return null;
    const access = call.callee.cast(.accessExpr);
    if (access.right.type() != .ident) return null;
    return .{ .recv = access.left, .method = access.right.cast(.ident).name.slice() };
}

/// The `Slice` methods that return a new list, paired with the method that changes the receiver in place.
const slice_new_value_methods = [_][2][]const u8{
    .{ "appended", "append" }, .{ "inserted", "insert" }, .{ "removed", "remove" },
};

/// The `Slice` methods that change the receiver in place and return nothing (before 0.4.15 they returned the new list).
const slice_in_place_methods = [_][]const u8{ "append", "insert", "remove", "clear", "size_down", "size_up" };

/// `src` with the method name `from` after the receiver replaced by `to`: `xs.appended(2)` -> `xs.append(2)`.
fn renameMethodSrc(buf: []u8, src: []const u8, recv: []const u8, from: []const u8, to: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, src, recv)) return null;
    const rest = src[recv.len..];
    if (!std.mem.startsWith(u8, rest, ".") or !std.mem.startsWith(u8, rest[1..], from)) return null;
    return std.fmt.bufPrint(buf, "{s}.{s}{s}", .{recv, to, rest[1 + from.len..]}) catch null;
}

var rename_buf: [160]u8 = undefined;

/// `_ = xs.appended(v)` or a bare `xs.appended(v)`. The methods that return a new list leave the receiver as it
/// was, so a dropped result is a lost update: the in-place method was meant.
pub fn checkDroppedSliceResult(c: *cy.Chunk, expr_t: *cy.Type, node: *ast.Node) !void {
    const mc = methodCallOf(node) orelse return;
    const instance = expr_t.sym().instance orelse return;
    if (instance.getSymTemplate() != c.sema.slice_tmpl) return;
    for (slice_new_value_methods) |pair| {
        if (!std.mem.eql(u8, mc.method, pair[0])) continue;
        const recv = c.nodeString(mc.recv);
        if (renameMethodSrc(&rename_buf, c.nodeString(node), recv, pair[0], pair[1])) |fixed| {
            if (recv.len <= 40) {
                return c.reportErrorFmt("`{}` returns a new list and leaves `{}` as it was. To change `{}` in place, write `{}`.", &.{v(pair[0]), v(recv), v(recv), v(fixed)}, node);
            }
        }
        return c.reportErrorFmt("`{}` returns a new list and leaves the receiver as it was. To change it in place, call `{}`.", &.{v(pair[0]), v(pair[1])}, node);
    }
}

/// A `void` call where a value was expected: `checkSliceInPlaceResult` for an assignment, which names the
/// assigned variable when it is the receiver (`xs = xs.append(v)`).
pub fn checkSliceInPlaceAssign(c: *cy.Chunk, node: *ast.Node) !void {
    try checkSliceInPlaceResult(c, c.sema.void_t, node, if (c.assign_right == node) c.assign_target else null, false);
}

/// Whether `node` is a call of a method of a `Slice` that returned nothing. The call is the last one that sema
/// analyzed (`Chunk.slice_void_call`), so this is asked right after the call.
fn isSliceVoidCall(c: *cy.Chunk, node: *ast.Node) bool {
    return c.slice_void_call == node;
}

/// Whether the methods of `sym` are methods of a `Slice`.
fn isSliceMethodSym(c: *cy.Chunk, sym: *cy.sym.FuncSym) bool {
    const type_sym = sym.head.parent orelse return false;
    const type_ = type_sym.getStaticType() orelse return false;
    const instance = type_.sym().instance orelse return false;
    return instance.type == .sym and instance.getSymTemplate() == c.sema.slice_tmpl;
}

/// `xs = xs.append(v)` or `ys := xs.append(v)`, the form from before 0.4.15: `append` and the other resize methods of
/// `Slice` now change the receiver in place and return nothing. `res_t` is the type of the call. `left` is the
/// assigned variable, or null for a declaration or another place. `must_be_slice` is for a place where a `void`
/// value is not an error by itself (a declaration): only a call of a `Slice` method is reported there.
pub fn checkSliceInPlaceResult(c: *cy.Chunk, res_t: *cy.Type, node: *ast.Node, left: ?*ast.Node, must_be_slice: bool) !void {
    if (res_t.id() != bt.Void) return;
    const mc = methodCallOf(node) orelse return;
    var found = false;
    for (slice_in_place_methods) |m| {
        if (std.mem.eql(u8, mc.method, m)) found = true;
    }
    if (!found) return;
    // The receiver is a `Slice`, so the message can name the method that returns a new list.
    const slice_recv = isSliceVoidCall(c, node);
    if (must_be_slice and !slice_recv) return;
    const recv = c.nodeString(mc.recv);
    const call_src = c.nodeString(node);
    if (recv.len > 40 or call_src.len > 80) {
        return c.reportErrorFmt("`{}` changes the receiver in place and returns nothing. Call it as a statement.", &.{v(mc.method)}, node);
    }
    if (left) |left_n| {
        if (std.mem.eql(u8, c.nodeString(left_n), recv)) {
            // The fix replaces the assignment `xs = xs.append(v)` with the call.
            return c.reportErrorFix("`{}` changes `{}` in place and returns nothing. Write `{}` as a statement.", &.{v(mc.method), v(recv), v(call_src)}, node, .{
                .pos = left_n.pos(),
                .end_pos = node.end(),
                .text = call_src,
            });
        }
    }
    if (slice_recv) for (slice_new_value_methods) |pair| {
        if (!std.mem.eql(u8, mc.method, pair[1])) continue;
        if (renameMethodSrc(&rename_buf, call_src, recv, pair[1], pair[0])) |new_src| {
            return c.reportErrorFmt("`{}` changes `{}` in place and returns nothing. Write `{}` as a statement, or `{}` for a new list that leaves `{}` as it was.", &.{
                v(mc.method), v(recv), v(call_src), v(new_src), v(recv),
            }, node);
        }
    };
    return c.reportErrorFmt("`{}` changes `{}` in place and returns nothing. Write `{}` as a statement.", &.{v(mc.method), v(recv), v(call_src)}, node);
}

/// A variable or a field path (`xs`, `self.out`): sema of it has no side effects, so `semaOpAssignMethod`
/// can look at its type and still fall back to `x = x op y`.
fn isPlainPlace(node: *ast.Node) bool {
    return switch (node.type()) {
        .ident => true,
        .accessExpr => isPlainPlace(node.cast(.accessExpr).left),
        else => false,
    };
}

/// `x op= y` calls the `op=` method of the type of `x` when the type declares one, so that the type can
/// change `x` in place (`Slice` appends in place for `+=`). Otherwise `x op= y` is `x = x op y` and this
/// returns false.
pub fn semaOpAssignMethod(c: *cy.Chunk, node: *ast.Node) !bool {
    const stmt = node.cast(.op_assign_stmt);
    if (!isPlainPlace(stmt.left)) return false;
    var name_buf: [8]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "{s}=", .{stmt.op.name()}) catch return false;
    const var_start = c.varStack.items.len;
    const left = try c.semaExprSkipSym(stmt.left, .{});
    if (left.resType == .sym) return false;
    switch (left.type.kind()) {
        // A reference keeps the guided error of `x = x op y` (`checkRefOperand`).
        .int, .raw, .float, .pointer => return false,
        else => {},
    }
    const sym = (try c.accessResolvedSym(left.type, name, node)) orelse return false;
    const func_sym = try requireFuncSym(c, sym, node);
    const res = try c.semaCallFuncSymRec(func_sym, stmt.left, left, &.{ stmt.right }, false, node);
    const is_void = res.resType == .ct_value and res.data.ct_value.type.id() == bt.Void;
    if (!is_void and res.type.id() != bt.Void and res.type.id() != bt.Never) {
        // The statement has no place for a value, and `_ = x op= y` is not a statement.
        const ret_name = try c.sema.allocTypeName(res.type);
        defer c.alloc.free(ret_name);
        const rec_name = try c.sema.allocTypeName(left.type);
        defer c.alloc.free(rec_name);
        return c.reportErrorFmt("The `{}` method of `{}` returns `{}`, and an `x {} y` statement can not use or drop the value. Declare the method without a return type.", &.{v(name), v(rec_name), v(ret_name), v(name)}, node);
    }
    try sema_stmt.semaExprStmtEnd(c, res, var_start, node);
    return true;
}

pub fn requireFuncSym(c: *cy.Chunk, sym: *Sym, node: *ast.Node) !*cy.sym.FuncSym {
    if (sym.type != .func) {
        return c.reportErrorFmt("Expected `{}` to be a function symbol.", &.{v(sym.name())}, node);
    }
    return sym.cast(.func);
}

// Invoke a type's sym as the callee.
fn callTypeInit(c: *cy.Chunk, sym: *Sym, sym_n: *ast.Node, args: []const *ast.Node, req_value: bool, node: *ast.Node) !sema.ExprResult {
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

pub fn callSym(c: *cy.Chunk, sym: *Sym, sym_node: *ast.Node, args: []*ast.Node, req_value: bool, node: *ast.Node) !sema.ExprResult {
    try sema_local.referenceSym(c, sym, sym_node);
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
            payload = try sema_move.semaOwn(c, payload, args[0]);
            return sema_init.semaInitCunionCase(c, case.type, case.idx, payload, node);
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
            payload = try sema_move.semaOwn(c, payload, args[0]);
            return sema_init.semaInitChoice(c, case.type, case.idx, case.val, payload, node);
        },
        .userVar,
        .hostVar => {
            var callee = try sema_expr.symbol(c, sym, true, sym_node);
            callee = try sema_move.semaOwn(c, callee, sym_node);
            return c.semaCallValue(callee, sym_node, args, node);
        },
        else => {},
    }
    // try pushCallArgs(c, node.data.callExpr.argHead, numArgs, true);
    return c.reportErrorFmt("Unsupported call from symbol: `{}`", &.{v(sym.type)}, sym_node);
}

pub fn sema_func_sym(c: *cy.Chunk, func: *cy.Func, prefer_ct_sym: bool, opt_target: ?*cy.Type, node: *ast.Node) !sema.ExprResult {
    const ptr_t = try cy.sema.getFuncPtrType(c, func.sig);
    if (prefer_ct_sym) {
        return sema.ExprResult.initCustom(undefined, .func, ptr_t, .{ .func = func });
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
    var res = sema.ExprResult.initCustom(loc, .func, ptr_t, .{ .func = func });
    if (opt_target) |target_t| {
        if (target_t.kind() == .func and func.sig == target_t.cast(.func).sig) {
            loc = try c.ir.newExpr(.func, target_t, node, .{
                .expr = res.ir,
            });
            res = sema.ExprResult.initOwned(loc);
        }
    }
    return res;
}

/// First arg contains the receiver.
pub fn semaCallFuncSymRec2(c: *cy.Chunk, sym: *cy.sym.FuncSym, args: []const Argument, node: *ast.Node) !sema.ExprResult {
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
        return sema.ExprResult.initOwned(loc);
    } else {
        return sema_func.matchFuncSym2(c, sym, args, &.{}, false, node);
    }
}

pub fn semaCallFuncSymRec(c: *cy.Chunk, sym: *cy.sym.FuncSym, rec: *ast.Node, rec_res: sema.ExprResult,
    args: []const *ast.Node, req_value: bool, node: *ast.Node) !sema.ExprResult {
    const saved_rec = c.global_take_rec;
    const saved_args = c.global_take_args;
    const saved_take = c.global_take;
    c.global_take_rec = rec;
    c.global_take_args = args;
    c.global_take = null;
    defer {
        c.global_take_rec = saved_rec;
        c.global_take_args = saved_args;
        c.global_take = saved_take;
    }
    if (try reuseSliceBuffer(c, sym, rec, rec_res, args, node)) |res| return res;
    const res = try semaCallFuncSymRecInner(c, sym, rec, rec_res, args, req_value, node);
    if (res.type.id() == bt.Void and isSliceMethodSym(c, sym)) {
        c.slice_void_call = node;
    }
    if (c.global_take) |take| {
        return sema_move.restoreGlobal(c, take, res, node);
    }
    return res;
}

/// A new-list method of `Slice` (`appended`, `inserted`, `removed`, `+`) on the last use of a local reuses its buffer:
/// `xs.appended(v)` becomes `_reuse := move xs` and `_reuse.append(v)`, which copies only when another value shares the
/// buffer. The result is the same, without the copy. The last use is the only name of the local in its statement, and
/// no later statement of the block names it. See `docs/decisions/project_last_use.md` "B".
fn reuseSliceBuffer(c: *cy.Chunk, sym: *cy.sym.FuncSym, rec: *ast.Node, rec_res: sema.ExprResult, args: []const *ast.Node,
    node: *ast.Node) anyerror!?sema.ExprResult {
    const name = sym.head.name();
    const in_place: []const u8 = if (std.mem.eql(u8, name, "appended"))
        "append"
    else if (std.mem.eql(u8, name, "inserted"))
        "insert"
    else if (std.mem.eql(u8, name, "removed"))
        "remove"
    else if (std.mem.eql(u8, name, "+"))
        "+="
    else
        return null;
    if (!isSliceMethodSym(c, sym)) return null;
    if (rec.type() != .ident or rec_res.resType != .value_local or rec_res.ir.code != .local) return null;
    const id = rec_res.data.value_local;
    const local = c.varStack.items[id];
    if (local.type != .local or local.inner.local.hidden) return null;
    // A `Slice` value, not a reference or a borrow of one.
    if (local.decl_t != rec_res.type or local.decl_t.isObjectLike() or local.decl_t.info.borrow_only) return null;
    if (local.active_borrows > 0 or local.active_ex_borrows > 0 or local.has_inactive_struct_fields) return null;
    if (c.vm.config.persist_main and c.proc().func == null and c.semaBlocks.items.len == 1) return null;
    // The local is of this block, and this statement of the block is its last use.
    // Or the statement assigns the result to the local (`xs = xs.appended(v)`), from any block: the left side and
    // the receiver are its only names of the local.
    const ctx = c.stmt_ctx;
    if (ctx.stmts.len == 0 or ctx.block != c.semaBlocks.items.len - 1) return null;
    const text = sema_stmt.stmtText(c, ctx.stmts, ctx.idx) orelse return null;
    if (sema_assign.movesIntoAssign(c, id) and assignsToName(ctx.stmts[ctx.idx], local.name())) {
        if (sema_stmt.countNames(text, local.name()) != 2) return null;
        // The move of the local comes before the arguments, and the assignment gives it a value after them. A jump
        // from in between would arrive where the local is declared with the local moved (`checkAssignMoveJump`).
        // The user wrote no move, so the statement copies instead.
        if (canLeaveAssign(c, text, id)) return null;
    } else {
        if (id < c.block().varStart) return null;
        if (sema_stmt.countNames(text, local.name()) != 1) return null;
        if ((sema_stmt.lastNamingStmt(c, ctx.stmts, ctx.idx, local.name()) orelse return null) != ctx.idx) return null;
    }

    const in_sym = (try c.accessResolvedSym(rec_res.type, in_place, node)) orelse return null;
    if (in_sym.type != .func) return null;
    const own_sym = (try c.accessResolvedSym(rec_res.type, "own_buffer", node)) orelse return null;
    if (own_sym.type != .func) return null;
    const moved = try sema_move.semaMove(c, rec_res, rec);
    const tmp = try sema_local.declareHiddenLocal(c, "_reuse", rec_res.type, moved, rec);
    const tmp_res = try sema_expr.semaLocal(c, tmp.id, rec);
    const saved_void = c.slice_void_call;
    const saved_reuse = c.reuse_call;
    c.reuse_call = .{ .node = node, .written = sym, .in_place = in_sym.cast(.func) };
    const call = c.semaCallFuncSymRec(in_sym.cast(.func), rec, tmp_res, args, false, node) catch |err| {
        c.reuse_call = saved_reuse;
        return err;
    };
    c.reuse_call = saved_reuse;
    _ = try c.ir.pushStmt(.discard, node, .{ .expr = call.ir });
    // An in-place method that does not grow the buffer can leave it shared (`remove` of the last element, `append`
    // of an empty span). The result of a new-list method shares its buffer with no other value.
    c.reuse_call = .{ .node = node, .written = sym, .in_place = in_sym.cast(.func), .record = false };
    const own_call = c.semaCallFuncSymRec(own_sym.cast(.func), rec, try sema_expr.semaLocal(c, tmp.id, rec), &.{}, false, node) catch |err| {
        c.reuse_call = saved_reuse;
        return err;
    };
    c.reuse_call = saved_reuse;
    c.slice_void_call = saved_void;
    _ = try c.ir.pushStmt(.discard, node, .{ .expr = own_call.ir });
    return try sema_move.semaMove(c, try sema_expr.semaLocal(c, tmp.id, rec), rec);
}

/// `s.xs = s.xs.appended(v)` (also `inserted`, `removed`, `+`): the member is the receiver and the target, so the
/// statement is the in-place call `s.xs.append(v)`, which copies only when another value shares the buffer. The path
/// is one of struct values from a local, or from an exclusive borrow (`self.xs` of a `&&T` method), that is not
/// borrowed and that the arguments do not name: nothing else can read the member in between. Returns false to leave
/// the statement to the assignment. See `docs/decisions/project_last_use.md`.
pub fn reuseMemberSliceBuffer(c: *cy.Chunk, left_n: *ast.Node, right: *ast.Node, node: *ast.Node) !bool {
    if (!isPlainPlace(left_n)) return false;
    var written: []const u8 = undefined;
    var in_place: []const u8 = undefined;
    var recv: *ast.Node = undefined;
    var args: []const *ast.Node = undefined;
    if (methodCallOf(right)) |mc| {
        for (slice_new_value_methods) |pair| {
            if (!std.mem.eql(u8, mc.method, pair[0])) continue;
            written = pair[0];
            in_place = pair[1];
            break;
        } else return false;
        recv = mc.recv;
        args = right.cast(.callExpr).args.slice();
    } else if (right.type() == .binExpr and right.cast(.binExpr).op == .plus) {
        written = "+";
        in_place = "+=";
        recv = right.cast(.binExpr).left;
        args = @as([*]const *ast.Node, @ptrCast(&right.cast(.binExpr).right))[0..1];
    } else return false;
    if (!isPlainPlace(recv) or left_n.src() != c.id or right.src() != c.id) return false;
    if (!std.mem.eql(u8, c.nodeString(left_n), c.nodeString(recv))) return false;
    var root = left_n;
    while (root.type() == .accessExpr) root = root.cast(.accessExpr).left;
    const root_name = root.cast(.ident).name.slice();
    // The receiver is the only name of the root on the right side.
    if (sema_stmt.countNames(c.nodeString(right), root_name) != 1) return false;

    const place = try c.semaExprSkipSym(left_n, .{});
    if (place.resType != .value_field) return false;
    const instance = place.type.sym().instance orelse return false;
    if (instance.type != .sym or instance.getSymTemplate() != c.sema.slice_tmpl) return false;
    var cur = place.ir;
    while (cur.code == .field) {
        const rec = cur.cast(.field).rec;
        if (rec.type.kind() != .struct_t) {
            if (rec.type.kind() != .ex_borrow or rec.code != .local) return false;
        }
        cur = rec;
    }
    if (cur.code != .local) return false;
    const id = place.recParentLocal() orelse return false;
    const local = c.varStack.items[id];
    if (local.type != .local or local.inner.local.hidden or local.inner.local.id != cur.cast(.local).id) return false;
    if (local.active_borrows > 0 or local.active_ex_borrows > 0 or local.has_inactive_struct_fields) return false;

    const written_sym = (try c.accessResolvedSym(place.type, written, node)) orelse return false;
    if (written_sym.type != .func) return false;
    const in_sym = (try c.accessResolvedSym(place.type, in_place, node)) orelse return false;
    if (in_sym.type != .func) return false;
    const own_sym = (try c.accessResolvedSym(place.type, "own_buffer", node)) orelse return false;
    if (own_sym.type != .func) return false;

    const saved_void = c.slice_void_call;
    const saved_reuse = c.reuse_call;
    c.reuse_call = .{ .node = right, .written = written_sym.cast(.func), .in_place = in_sym.cast(.func) };
    const call = c.semaCallFuncSymRec(in_sym.cast(.func), recv, place, args, false, right) catch |err| {
        c.reuse_call = saved_reuse;
        return err;
    };
    c.reuse_call = saved_reuse;
    _ = try c.ir.pushStmt(.discard, node, .{ .expr = call.ir });
    // See `reuseSliceBuffer`: the result of a new-list method shares its buffer with no other value.
    const own_place = try c.semaExprSkipSym(left_n, .{});
    c.reuse_call = .{ .node = right, .written = written_sym.cast(.func), .in_place = in_sym.cast(.func), .record = false };
    const own_call = c.semaCallFuncSymRec(own_sym.cast(.func), recv, own_place, &.{}, false, right) catch |err| {
        c.reuse_call = saved_reuse;
        return err;
    };
    c.reuse_call = saved_reuse;
    c.slice_void_call = saved_void;
    _ = try c.ir.pushStmt(.discard, node, .{ .expr = own_call.ir });
    return true;
}

/// Whether the statement with the source `text`, an assignment to the local `id`, can jump from its right side to
/// where the local is still declared: a `break` or `continue` (in an `?else:` block), or a failing `!` that goes
/// to the handler of a `try` statement or leaves a `scope` block around the declaration. A `return` and a `!` that
/// returns from the function are not such jumps. Like the other checks of the last use, this reads the text: a
/// word in a string or a comment counts too, which only costs the reuse.
fn canLeaveAssign(c: *cy.Chunk, text: []const u8, id: sema.LocalId) bool {
    if (sema_stmt.countNames(text, "break") > 0 or sema_stmt.countNames(text, "continue") > 0) return true;
    const try_ctx = c.proc().try_ctx orelse return false;
    // A local of the body leaves with the body.
    if (id >= c.semaBlocks.items[try_ctx.body_block].varStart) return false;
    var pos: usize = 0;
    while (std.mem.indexOfScalarPos(u8, text, pos, '!')) |idx| {
        pos = idx + 1;
        const rest = text[pos..];
        // `!=`, and `!else` with a default value, which does not propagate.
        if (rest.len > 0 and rest[0] == '=') continue;
        if (std.mem.startsWith(u8, rest, "else") and (rest.len == 4 or !sema_move.isIdentChar(rest[4]))) continue;
        return true;
    }
    return false;
}

/// Whether `stmt` is `name = ...`.
fn assignsToName(stmt: *ast.Node, name: []const u8) bool {
    if (stmt.type() != .assign_stmt) return false;
    const left = stmt.cast(.assign_stmt).left;
    return left.type() == .ident and std.mem.eql(u8, left.cast(.ident).name.slice(), name);
}

fn semaCallFuncSymRecInner(c: *cy.Chunk, sym: *cy.sym.FuncSym, rec: *ast.Node, rec_res: sema.ExprResult,
    args: []const *ast.Node, req_value: bool, node: *ast.Node) !sema.ExprResult {
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
        return sema.ExprResult.initOwned(loc);
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

/// A call to a function whose body did not compile in an earlier compile of the session (`FuncInfo.body_failed`).
/// A body that the failed compile left unchecked (`Compiler.carry_funcs`) finds such a function through a type it
/// already has, and so can this source. The function has no IR, so code can not be generated for the call
/// (SIGSEGV in `bc_gen.check_inline` before 2026-11-22).
/// - From this source: the body is checked again with this compile (`Compiler.recheck_funcs`), which reports its
///   error where it is. With error recovery the body is not checked again and the call is the error.
/// - From a carried body: the error is not this source's. The carried body fails and is dropped in turn.
pub fn checkCallee(c: *cy.Chunk, func: *cy.Func, node: *ast.Node) !void {
    if (func.info.body_failed) {
        const compiler = c.compiler;
        if (compiler.checking_carried or compiler.recover) return cy.template.failedInstance(c, node);
        // The mark stays until the body compiles (`sema_local`): this compile can fail before it gets there.
        if (std.mem.indexOfScalar(*cy.Func, compiler.recheck_funcs.items, func) == null) {
            func.info.emitted = false;
            func.info.bc_inline = 0;
            try compiler.recheck_funcs.append(compiler.alloc, func);
        }
        return;
    }
    const inst = cy.compiler.ownerInstance(func) orelse return;
    if (inst.failed) return cy.template.failedInstance(c, node);
}

pub fn sema_call_ir(c: *cy.Chunk, func: *cy.Func, args: []const *ir.Expr, node: *ast.Node) !sema.ExprResult {
    try checkCallee(c, func, node);
    recordCallRef(c, node, func);
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
/// The main block is never on a fiber's stack. A generator body can be: its frame runs on the stack of the
/// fiber that consumes it, and its pad ends the generator (`semaCancelPad`).
/// Where a frame goes when its fiber is cancelled at a site (`Chunk.cancel_pads`).
pub const CancelPad = union(enum) {
    /// The frame keeps running: the sites of a destruction routine (`isCancelKeepFunc`) are like this. A fiber
    /// cancelled inside a `@deinit` that `@destruct` called returns from the `@deinit` to the rest of
    /// `@destruct`, which destructs the fields.
    keep,
    /// The statements that destruct the locals that are alive at the site and return.
    pad: *ir.Stmt,
};

/// Whether `func` destructs a value: an instance of the destructor templates (`@destruct`, `@partial_destruct`,
/// `@deinitObject`), `@destructBox`, and a `@deinit` declared in a builtin module (`Generator.@deinit`, the
/// collections). Their code only destructs, so a cancel lets a frame of theirs finish (`CancelPad.keep`).
/// A `@deinit` of a script is not one: a cancel does not run more of it.
/// The templates are compared by identity (`Sema.dtor_fn` and the others), so a renamed one is still found.
/// The answer is cached in `func.info.cancel_keep`.
pub fn isCancelKeepFunc(compiler: *cy.Compiler, func: *cy.Func) bool {
    switch (func.info.cancel_keep) {
        1 => return true,
        2 => return false,
        else => {},
    }
    const keep = computeCancelKeep(compiler, func);
    func.info.cancel_keep = if (keep) 1 else 2;
    return keep;
}

fn computeCancelKeep(compiler: *cy.Compiler, func: *cy.Func) bool {
    if (func.type == .userLambda) return false;
    const decl = func.decl orelse return false;
    const src = decl.src();
    if (src >= compiler.chunks.items.len or !compiler.chunks.items[src].is_builtin) return false;
    const s = &compiler.sema;
    if (func.instance) |inst| {
        if (inst.type == .func) {
            const tmpl = inst.data.func.template;
            if (tmpl == s.dtor_fn.data.generic or tmpl == s.partial_dtor_fn.data.generic or tmpl == s.deinit_obj_tmpl) {
                return true;
            }
        }
    }
    if (s.destruct_box_fn == func) return true;
    // The destructor hook of a builtin type. The name is the language's, like `meta.has_decl(T, '@deinit')`.
    return std.mem.eql(u8, func.name(), "@deinit");
}

/// Whether destructing a `type_` can run a `@deinit` of a script: code that can suspend a fiber.
/// Errs on true for what it does not see through (function values, trait objects).
pub fn destructMayRunScript(c: *cy.Chunk, type_: *cy.Type, depth: u32) bool {
    if (depth > 8) return true;
    if (!type_.isManaged()) return false;
    if (type_.id() == bt.Str) return false;
    switch (type_.kind()) {
        .pointer => {
            const ptr_t = type_.cast(.pointer);
            return ptr_t.ref and destructMayRunScript(c, ptr_t.child_t, depth + 1);
        },
        .borrow, .ex_borrow => return false,
        .option => return destructMayRunScript(c, type_.cast(.option).child_t, depth + 1),
        .result => return destructMayRunScript(c, type_.cast(.result).child_t, depth + 1),
        .choice => {
            for (type_.cast(.choice).cases()) |case| {
                if (destructMayRunScript(c, case.payload_t, depth + 1)) return true;
            }
            return false;
        },
        .vector => return destructMayRunScript(c, type_.cast(.vector).elem_t, depth + 1),
        .partial_vector => return destructMayRunScript(c, type_.cast(.partial_vector).elem_t, depth + 1),
        .struct_t => {
            // Dropping a generator runs the deinit block of its body (`Generator.end`), which is script code.
            if (type_.isInstanceOf(c.sema.generator_tmpl)) return true;
            if (type_.sym().getMod().getSym("@deinit")) |deinit_sym| {
                if (deinit_sym.type == .func) {
                    if (deinit_sym.cast(.func).first.decl) |decl| {
                        if (!c.compiler.chunks.items[decl.src()].is_builtin) return true;
                    }
                } else return true;
            }
            for (type_.cast(.struct_t).fields()) |field| {
                if (destructMayRunScript(c, field.type, depth + 1)) return true;
            }
            // A collection of the builtin modules destructs its elements, which its fields do not show.
            if (type_.sym().instance) |inst| {
                for (inst.param_types, inst.params) |param_t, param| {
                    if (param_t != c.sema.type_t) continue;
                    if (destructMayRunScript(c, param.asPtr(*cy.Type), depth + 1)) return true;
                }
            }
            return false;
        },
        else => return true,
    }
}

/// The type that a destruction routine destructs (`isCancelKeepFunc`), or null when it is not known.
pub fn cancelKeepSubject(c: *cy.Chunk, func: *cy.Func) ?*cy.Type {
    if (func.instance) |inst| {
        if (inst.param_types.len > 0 and inst.param_types[0] == c.sema.type_t) {
            return inst.params[0].asPtr(*cy.Type);
        }
    }
    if (func.isMethod() and func.sig.params_len > 0) {
        const rec_t = func.sig.params()[0].get_type();
        return switch (rec_t.kind()) {
            .borrow => rec_t.cast(.borrow).child_t,
            .ex_borrow => rec_t.cast(.ex_borrow).child_t,
            .pointer => rec_t.cast(.pointer).child_t,
            else => rec_t,
        };
    }
    return null;
}

fn cancelPadApplies(c: *cy.Chunk) bool {
    if (c.cancel_pad_building) return false;
    return c.proc().func != null;
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
            return sema_move.seqFlush(c);
        }
    }
}

/// Attaches a cancel pad to the IR node at `key` (a call expr, a `suspend_` or an `await_` stmt): the
/// statements that a `return` at this point would run to destruct the proc's locals, and a return without a
/// value. bc_gen emits the pad after the function body and records the site in `ByteCodeBuffer.cancel_table`.
/// `Fiber.cancel` sends every frame of a suspended fiber to the pad of the site it is at, so the frames
/// release what they own from the top down and the fiber ends. Nothing runs on the normal path.
/// Consecutive sites with the same live locals share a pad.
pub fn semaCancelPad(c: *cy.Chunk, key: usize, node: *ast.Node) anyerror!void {
    if (!cancelPadApplies(c)) return;
    const proc = c.proc();
    if (isCancelKeepFunc(c.compiler, proc.func.?)) {
        try c.cancel_pads.put(c.alloc, key, .keep);
        return;
    }

    var hasher = std.hash.Wyhash.init(0);
    const b = c.procBlock();
    // The call of a destructor at the end of a block: the locals from the destructed one up are not alive.
    var var_end = c.varStack.items.len;
    if (c.cancel_pad_var_end) |end| {
        if (c.cancel_pad_var_proc == c.semaProcs.items.len and end >= b.varStart and end < var_end) {
            var_end = end;
        }
    }
    const skip: ?usize = if (c.cancel_pad_skip_proc == c.semaProcs.items.len) c.cancel_pad_skip else null;
    for (c.varStack.items[b.varStart..var_end], b.varStart..) |*local, i| {
        if (local.type != .local or skip == i) continue;
        std.hash.autoHash(&hasher, i);
        std.hash.autoHash(&hasher, @intFromPtr(local.decl_t));
        std.hash.autoHash(&hasher, local.inner.local.id);
    }
    // Zero is "no pad yet".
    const sig = hasher.final() | 1;
    if (proc.cancel_pad) |pad| {
        if (proc.cancel_pad_sig == sig) {
            try c.cancel_pads.put(c.alloc, key, .{ .pad = pad });
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
        try sema_local.semaDestructBlock3(c, b, var_end);
        if (proc.func.?.info.generator) {
            // The frame of a generator body leaves like the deinit block of a `yield`: `RET_Y` marks the
            // generator as done and returns to the consumer, whose own pad drops the generator.
            const gen_t = proc.getReturnType(c.sema).cast(.pointer).child_t;
            const funcptr_t = gen_t.sym().instance.?.params[0].asPtr(*cy.Type);
            const opt_t = try sema.getOptionType(c, funcptr_t.cast(.func_ptr).sig.ret);
            _ = try c.ir.pushStmt(.yield, node, .{
                .deinit_head = null,
                .ret_opt_t = opt_t,
                .end = true,
            });
        } else {
            _ = try c.ir.pushStmt(.ret, node, .{ .return_value = false });
        }
    }
    const block = c.ir.popStmtBlock();
    // `proc` can be stale: analyzing a destructor can add procs.
    const cur = c.proc();
    cur.cancel_pad = block.first;
    cur.cancel_pad_sig = sig;
    try c.cancel_pads.put(c.alloc, key, .{ .pad = block.first.? });
}

pub fn semaCallFuncResult(c: *cy.Chunk, res: sema_func.FuncResult, node: *ast.Node) !sema.ExprResult {
    // try referenceSym(c, @ptrCast(matcher.sym), node);
    return sema_call_ir(c, res.func, res.data.rt.args[0..res.data.rt.nargs], node);
}

pub fn semaCallValue(c: *cy.Chunk, callee: sema.ExprResult, callee_n: *ast.Node, args: []*ast.Node, node: *ast.Node) !sema.ExprResult {
    if (callee.type.kind() == .func_ptr) {
        return c.semaCallPtr(callee, callee.type.cast(.func_ptr).sig, args, node);
    } else if (callee.type.kind() == .func) {
        return c.semaCallUnion(callee, callee_n, callee.type.cast(.func).sig, args, node);
    } else {
        return c.reportErrorFmt("Expected callee, found {}.", &.{v(callee.type.kind())}, node);
    }
}

pub fn semaCallPtr(c: *cy.Chunk, func: sema.ExprResult, sig: *sema.FuncSig, args: []*ast.Node, node: *ast.Node) !sema.ExprResult {
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
    return sema.ExprResult.initOwned(loc);
}

pub fn semaCallUnion(c: *cy.Chunk, func: sema.ExprResult, func_n: *ast.Node, sig: *sema.FuncSig, args: []*ast.Node, node: *ast.Node) !sema.ExprResult {
    const managed = try sema_move.semaManage(c, func, func_n);

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
    return sema.ExprResult.initOwned(loc);
}

pub fn semaCallFunc(c: *cy.Chunk, func: *cy.Func, args: []*ast.Node, node: *ast.Node) !sema.ExprResult {
    const res = try sema_func.matchFunc(c, func, &.{}, args, false, node);
    return c.semaCallFuncResult(.{ .func = res.func, .kind = res.kind, .data = res.data }, node);
}

pub fn semaCallFunc2(c: *cy.Chunk, func: *cy.Func, pre_args: []const Argument, args: []*ast.Node, node: *ast.Node) !sema.ExprResult {
    const res = try sema_func.matchFunc(c, func, pre_args, args, false, node);
    return c.semaCallFuncResult(.{ .func = res.func, .kind = res.kind, .data = res.data }, node);
}

pub fn semaCallFuncSym1(c: *cy.Chunk, sym: *cy.sym.FuncSym, arg1_n: *ast.Node, arg1: sema.ExprResult, node: *ast.Node) !sema.ExprResult {
    const arg = Argument.initPreResolved(arg1_n, arg1);
    return sema_func.matchFuncSym2(c, sym, &.{arg}, &.{}, false, node);
}

pub fn semaCallFuncSym2(c: *cy.Chunk, sym: *cy.sym.FuncSym, arg1_n: *ast.Node, arg1_res: sema.ExprResult,
    arg2_n: *ast.Node, arg2_res: sema.ExprResult, node: *ast.Node) !sema.ExprResult {
    const arg1 = Argument.initPreResolved(arg1_n, arg1_res);
    const arg2 = Argument.initPreResolved(arg2_n, arg2_res);
    return sema_func.matchFuncSym2(c, sym, &.{arg1, arg2}, &.{}, false, node);
}

/// Match first overloaded function.
pub fn semaCallFuncSym(c: *cy.Chunk, sym: *cy.sym.FuncSym, args: []const *ast.Node, req_value: bool, node: *ast.Node) !sema.ExprResult {
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

/// A new-list method call of `Slice` that is checked as its in-place method (`reuseSliceBuffer`).
pub const ReuseCall = struct {
    node: *ast.Node,
    written: *cy.sym.FuncSym,
    in_place: *cy.sym.FuncSym,
    /// False for the `own_buffer` call after the in-place one: the script wrote no such call (`recordCallRef`).
    record: bool = true,

    /// The overload of the method that the script wrote for the overload `func` of the in-place method. The
    /// overloads of the new-list method are declared in the order of the in-place ones.
    pub fn writtenFunc(self: ReuseCall, func: *cy.Func) ?*cy.Func {
        var in_place: ?*cy.Func = self.in_place.first;
        var written: ?*cy.Func = self.written.first;
        while (in_place != null and written != null) {
            if (in_place.? == func) return written.?;
            in_place = in_place.?.next;
            written = written.?.next;
        }
        return null;
    }
};

/// Records the call `node` to `func` for the language server (`refs.recordCall`). The calls that the reuse of a
/// slice buffer makes have the node of the call that the script wrote: the in-place method is recorded as the
/// written one, and `own_buffer` is not recorded. Two functions for one node would leave it without the names of
/// its parameters (`refs.paramNames`).
pub fn recordCallRef(c: *cy.Chunk, node: *ast.Node, func: *cy.Func) void {
    if (!c.compiler.record_refs) return;
    var rec_func = func;
    if (c.reuse_call) |reuse| {
        if (reuse.node == node) {
            if (!reuse.record) return;
            rec_func = reuse.writtenFunc(func) orelse func;
        }
    }
    cy.refs.recordCall(c, node, rec_func);
}

const EmbeddedResult = struct {
    field_idx: usize,
    embedded_t: *cy.Type,
    sym: *cy.Sym,
};

pub fn get_embedded_sym(c: *cy.Chunk, rec_t: *cy.types.Struct, name: []const u8, node: *ast.Node) !?EmbeddedResult {
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
pub fn semaFiberExpr(c: *cy.Chunk, node: *ast.Node) !sema.ExprResult {
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
        return sema_expr.semaExpr(c, @ptrCast(new_call), .{});
    }
    const call = child.cast(.callExpr);
    try checkEntryMethodCall(c, call, "fiber", "fiber", node);

    // Report the role and lifetime rules at the `fiber` expression instead of inside `@new_fiber`.
    // A path (`T.method`, `mod.func`) is checked too: a `&T` receiver is a borrow like any parameter.
    if (try entrySig(c, call)) |sig| {
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

    return semaEntryCall(c, "@new_fiber", call, node);
}

/// The signature of the entry function of `fiber f(..)` or `spawn f(..)` when the callee is a name or a path.
fn entrySig(c: *cy.Chunk, call: *ast.CallExpr) !?*cy.FuncSig {
    if (call.callee.type() != .ident and call.callee.type() != .accessExpr) return null;
    const callee_res = try c.semaExpr(call.callee, .{});
    return switch (callee_res.type.kind()) {
        .func_ptr => callee_res.type.cast(.func_ptr).sig,
        .func_sym => callee_res.type.cast(.func_sym).sig,
        else => null,
    };
}

/// `fiber obj.work()` and `spawn obj.work()` have no place for the receiver. Name the method through its type instead.
fn checkEntryMethodCall(c: *cy.Chunk, call: *ast.CallExpr, keyword: []const u8, entry: []const u8, node: *ast.Node) !void {
    if (call.callee.type() != .accessExpr) return;
    const access = call.callee.cast(.accessExpr);
    if (access.left.type() != .ident) return;
    const left = try c.semaExprSkipSym(access.left, .{});
    if (left.resType == .sym) return;
    if (try c.accessResolvedSym(left.type, access.right.as_name(), access.right)) |sym| {
        if (sym.type == .func) {
            return c.reportErrorFmt("A {} entry cannot be a method call on a value. Pass the receiver as the first argument: `{} T.{}(obj)`.", &.{ v(entry), v(keyword), v(sym.name()) }, node);
        }
    }
}

/// `spawn f(a, b)` is the call `@spawn(f, {a, b})` of the core module: the arguments are evaluated and sent now,
/// and `f` is called on the new thread.
pub fn semaSpawnExpr(c: *cy.Chunk, node: *ast.Node) !sema.ExprResult {
    const call = node.cast(.spawn_expr).child.cast(.callExpr);
    try checkEntryMethodCall(c, call, "spawn", "thread", node);
    if (try entrySig(c, call)) |sig| {
        for (sig.params()) |param| {
            const param_t = param.get_type();
            if (param_t.info.borrow_only) {
                // The arguments are sent to the thread's heap. A borrow would point into the spawning thread.
                const type_name = try c.sema.allocTypeName(param_t);
                defer c.alloc.free(type_name);
                return c.reportErrorFmt("Cannot borrow a value across threads. The parameter type is `{}`. Take the value instead.", &.{v(type_name)}, node);
            }
        }
    }
    return semaEntryCall(c, "@spawn", call, node);
}

/// Sema of `name(call.callee, {call.args})`, a builtin that takes the entry function and its arguments as a tuple.
fn semaEntryCall(c: *cy.Chunk, name: []const u8, call: *ast.CallExpr, node: *ast.Node) !sema.ExprResult {
    const tree = &c.parser.ast;
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
    return sema_expr.semaExpr(c, @ptrCast(new_call), .{});
}

pub fn semaCallExpr(c: *cy.Chunk, node: *ast.Node, opt_target: ?*cy.Type) !sema.ExprResult {
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
                            leftRes = try sema_access.semaField(c, leftRes, callee.right, embedded_res.field_idx, embedded_res.embedded_t, callee.right);
                            break :b embedded_res.sym;
                        }
                    }
                    const type_name = try c.sema.allocTypeName(leftRes.type);
                    defer c.alloc.free(type_name);
                    const hint = try sema_hint.suggestMember(c, leftRes.type, right_name, callee.right);
                    return c.reportErrorFix("Can not find the symbol `{}` in `{}`.{}", &.{v(right_name), v(type_name), v(hint)}, callee.right, sema_hint.suggestedFix(c, right_name, callee.right));
                };

                if (rightSym.type == .func) {
                    // Call method.
                    const func_sym = rightSym.cast(.func);
                    const recv = try sema_expr.symbol(c, leftSym, true, callee.left);
                    return c.semaCallFuncSymRec(func_sym, callee.left, recv, call.args.slice(), false, node);
                } else if (rightSym.type == .field) {
                    // Call field value.
                    const field = rightSym.cast(.field);
                    const recv = try sema_expr.symbol(c, leftSym, true, callee.left);
                    const callee_v = try sema_access.semaField(c, recv, callee.left, field.idx, field.type, callee.right);
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
                        leftRes = try sema_access.semaField(c, leftRes, callee.right, embedded_res.field_idx, embedded_res.embedded_t, callee.right);
                        break :b embedded_res.sym;
                    }
                }
                const type_name = try c.sema.allocTypeName(leftRes.type);
                defer c.alloc.free(type_name);
                const hint = try sema_hint.suggestMember(c, leftRes.type, right_name, callee.right);
                return c.reportErrorFix("Can not find the symbol `{}` in `{}`.{}", &.{v(right_name), v(type_name), v(hint)}, callee.right, sema_hint.suggestedFix(c, right_name, callee.right));
            };

            if (rightSym.type == .func) {
                if (rightSym.cast(.func) == c.sema.scope_start_sym) {
                    return sema_stmt.semaScopeStart(c, callee.left, leftRes, call, node);
                }
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
        const varRes = try sema_local.lookupIdent(c, name, call.callee);
        if (call.callee.type() == .at_lit and varRes == .static) {
            try sema_expr.checkIntrinsicUse(c, call.callee);
        }
        switch (varRes) {
            .local => {
                const calleeRes = try c.semaExpr(call.callee, .{});
                return c.semaCallValue(calleeRes, call.callee, call.args.slice(), node);
            },
            .capture => |idx| {
                var callee = try sema_expr.semaCaptured(c, idx, node);
                callee = try sema_move.semaOwn(c, callee, node);
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
