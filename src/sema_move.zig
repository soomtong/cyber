const std = @import("std");
const cy = @import("cyber.zig");
const ir = cy.ir;
const bt = cy.types.BuiltinTypes;
const sema_func = cy.sema_func;
const Argument = cy.sema_func.Argument;
const fmt = cy.fmt;
const v = fmt.v;
const ast = cy.ast;
const sema = cy.sema;
const sema_local = cy.sema_local;
const sema_expr = cy.sema_expr;
const sema_assign = cy.sema_assign;
const sema_access = cy.sema_access;
const sema_init = cy.sema_init;

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
    // A moved local is read like a local, but the local is dead: until the consumer takes the value, nothing
    // destructs it. Pending, a cancel pad of a later operand's call destructs it (`semaCancelHoist`).
    const moved = owned and expr.code == .local and expr.cast(.local).moved;
    if (!moved and seqOrderFree(expr)) return;
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
pub fn seqPushRes(c: *cy.Chunk, res: *sema.ExprResult, node: *ast.Node) !void {
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

        const temp = try sema_local.declareHiddenLocal(c, "_seq", e.orig.type, sema.ExprResult.init2(e.orig), e.node);
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

pub fn semaEnsureAddressable(c: *cy.Chunk, expr: sema.ExprResult, node: *ast.Node) !sema.ExprResult {
    if (!expr.addressable) {
        const tempv = try sema_local.declareHiddenLocal(c, "_temp", expr.type, expr, node);
        c.varStack.items[tempv.id].lifetime = sema.Lifetime.initTemp();
        return sema_expr.semaLocal(c, tempv.id, node);
    }
    return expr;
}

pub fn semaManage(c: *cy.Chunk, expr: sema.ExprResult, node: *ast.Node) !sema.ExprResult {
    if (!expr.type.isManaged()) {
        return expr;
    }
    if (!expr.owned) {
        return expr;
    }

    const tempv = try sema_local.declareHiddenLocal(c, "_temp", expr.type, expr, node);
    c.varStack.items[tempv.id].lifetime = .initTemp();
    return sema_expr.semaLocal(c, tempv.id, node);
}

pub fn semaOwn(c: *cy.Chunk, expr: sema.ExprResult, node: *ast.Node) !sema.ExprResult {
    if (expr.owned) {
        return expr;
    }
    if (expr.type.info.no_copy and canMoveImplicitly(c, expr)) {
        if (isPersistedMainLocal(c, expr.recParentLocal().?)) return reportCopyPersistedLocal(c, expr, node);
        return semaMove(c, expr, node);
    }
    if (expr.type.info.no_copy and expr.ir.code == .local) {
        if (expr.recParentLocal()) |id| {
            if (id < c.block().varStart and c.varStack.items[id].type == .local) return reportMoveAcross(c, id, node);
        }
    }
    return sema_expr.sema_copy(c, expr, node);
}

/// A `NoCopy` value that would be copied moves instead when it is read from a local or a member path of one
/// (`total(xs)`, `Box{v=s.xs}`). A later use of the local is an error that names this place. A value that `move` could
/// not take is left to the copy error. See `docs/decisions/project_last_use.md`.
fn canMoveImplicitly(c: *cy.Chunk, expr: sema.ExprResult) bool {
    var cur = expr.ir;
    while (cur.code == .field) {
        const rec = cur.cast(.field).rec;
        if (rec.type.kind() != .struct_t) return false;
        if (rec.type.cast(.struct_t).base.sym().has_decl("@deinit")) return false;
        cur = rec;
    }
    if (cur.code != .local) return false;
    const id = expr.recParentLocal() orelse return false;
    const local = c.varStack.items[id];
    if (local.type != .local or local.inner.local.hidden) return false;
    if (local.inner.local.id != cur.cast(.local).id) return false;
    if (local.inner.local.isParam and local.decl_t.isObjectLike()) return false;
    if (local.decl_t.info.borrow_only) return false;
    if (id < c.block().varStart and (cur != expr.ir or !(canMoveAcross(c, id) or sema_assign.movesIntoAssign(c, id)))) return false;
    if (cur == expr.ir and local.has_inactive_struct_fields) return false;
    return true;
}

/// Whether the local `id` is declared in the top level block of the REPL's main (`persist_main`). The next input reads
/// it again from a new main chunk, which does not know what the earlier inputs moved. A local of a nested block or of
/// a function ends with the input.
pub fn isPersistedMainLocal(c: *cy.Chunk, id: sema.LocalId) bool {
    if (!c.vm.config.persist_main) return false;
    const proc = c.proc();
    if (proc.func != null or id < proc.varStart) return false;
    const nested = proc.block_start + 1;
    return nested >= c.semaBlocks.items.len or id < c.semaBlocks.items[nested].varStart;
}

/// A `NoCopy` value read from a top level local of the REPL does not move without `move`: the local would be gone for
/// the later inputs without a word in the source. `move x` says so, and `semaUntrackMovedMainLocals` then forgets `x`.
fn reportCopyPersistedLocal(c: *cy.Chunk, expr: sema.ExprResult, node: *ast.Node) anyerror {
    const type_name = try c.sema.allocTypeName(expr.type);
    defer c.alloc.free(type_name);
    const name = c.varStack.items[expr.recParentLocal().?].name();
    if (expr.ir.code != .local) {
        return c.reportErrorFmt("Cannot copy `{}`, a `NoCopy` type. A member of the top level variable `{}` of the REPL does not move: later inputs read `{}`. Borrow it, or move the whole variable with `move {}`.", &.{v(type_name), v(name), v(name), v(name)}, node);
    }
    return c.reportErrorFmt("Cannot copy `{}`, a `NoCopy` type. The top level variable `{}` of the REPL does not move without `move`: later inputs read it. Write `move {}` to give it away (later inputs can not use `{}` then), or borrow it.", &.{v(type_name), v(name), v(name), v(name)}, node);
}

/// REPL (`persist_main`), at the end of the main block: a top level local that was moved (`ys := move xs`, also from a
/// branch of an `if` statement) is not carried over to the next input. Its value has another owner, so the next input
/// would read a value that is freed or owned twice.
pub fn semaUntrackMovedMainLocals(c: *cy.Chunk) !void {
    const proc = c.proc();
    var id: usize = proc.varStart;
    while (id < c.varStack.items.len) : (id += 1) {
        const local = c.varStack.items[id];
        if (local.type != .dead or local.inner.local.hidden or local.inner.local.isParam) continue;
        // A local that was declared again under the name (a restored one can be) keeps the name.
        const entry = proc.var_cache_entries.get(local.name()) orelse continue;
        if (entry.type != .local or entry.data.local.varId != id) continue;
        const name = try c.semaRawString(local.name(), c.ast.null_node);
        const arg = sema_func.Argument.initPreResolved(c.ast.null_node, name);
        const call = try c.semaCallFunc2(c.sema.untrack_main_local_fn, &.{arg}, &.{}, c.ast.null_node);
        try sema_local.sema_discard(c, call, c.ast.null_node);
    }
}

/// The local `id` of an outer block can not be moved at `node`. The message names the cause: an expression that is
/// checked in a block of its own and evaluates a part conditionally (`and`, `or`, `?else`,
/// `!else`), the condition of an `else` branch, or a block like a loop body.
fn reportMoveAcross(c: *cy.Chunk, id: sema.LocalId, node: *ast.Node) anyerror {
    const name = c.varStack.items[id].name();
    if (c.varStack.items[id].scope_block) {
        return c.reportErrorFmt("Cannot move `{}`: it is the scope of a `scope` block, which joins its fibers at the end of the block. Borrow it with `&&{}`.", &.{v(name), v(name)}, node);
    }
    // The block that does not take the move: the current one, or one between it and the block of the local.
    var b = &c.semaBlocks.items[moveBlock(c)];
    if (b.move_branch == .branch or b.move_branch == .plain) {
        var i = moveBlock(c);
        while (i > c.proc().block_start) {
            i -= 1;
            if (id >= c.semaBlocks.items[i].varStart) break;
            if (c.semaBlocks.items[i].move_branch == .none) {
                b = &c.semaBlocks.items[i];
                break;
            }
        }
    }
    const expr_name: ?[]const u8 = switch (b.node.type()) {
        .binExpr => switch (b.node.cast(.binExpr).op) {
            .and_op => "an `and` expression",
            .or_op => "an `or` expression",
            else => null,
        },
        .unwrap_or, .unwrap_or_block => "a `?else` expression",
        .unwrap_res_or, .unwrap_res_or_block => "a `!else` expression",
        else => null,
    };
    if (expr_name) |expr| {
        return c.reportErrorFmt("Cannot move `{}` inside {}: a part of the expression is evaluated conditionally. Borrow it with `&{}`, or move it to a variable in a statement before this one.", &.{v(name), v(expr), v(name)}, node);
    }
    if (b.move_branch == .if_outer) {
        return c.reportErrorFmt("Cannot move `{}` in the condition of an `else` branch: the condition is evaluated conditionally. Move it inside the branch, or borrow it with `&{}`.", &.{v(name), v(name)}, node);
    }
    return c.reportErrorFmt("Cannot move `{}` here: it is declared outside this block. A branch of an `if` or `switch`, a `begin:` block, a `try` statement, a `scope` block and a loop body can move an outer variable, this block can not. Borrow it with `&{}`.", &.{v(name), v(name)}, node);
}

/// Whether the local `id` of an outer block can be moved from the current block: every block up to the one of the
/// local is a branch of an `if`, `if` unwrap or `switch` statement, a `begin:` block or a block of a loop. A loop
/// takes the move only where the body then leaves the loop (`checkLoopMoves`, `semaBreak`).
fn canMoveAcross(c: *cy.Chunk, id: sema.LocalId) bool {
    // The `Scope` of a `scope` block stays where it is: the block joins its fibers at the end.
    if (c.varStack.items[id].scope_block) return false;
    var i = moveBlock(c);
    if (id >= c.semaBlocks.items[i].varStart) return true;
    const kind = c.semaBlocks.items[i].move_branch;
    if (kind != .branch and kind != .plain) return false;
    while (i > c.proc().block_start) {
        i -= 1;
        const b = c.semaBlocks.items[i];
        if (id >= b.varStart) return true;
        if (b.move_branch == .none) return false;
    }
    return false;
}

/// The block that a move at this point is a move in: the current one, or the block of the `if` statement while its
/// first condition is checked.
fn moveBlock(c: *cy.Chunk) usize {
    var i = c.semaBlocks.items.len - 1;
    // The left operand of an `and` in the condition is two such blocks deep.
    while (c.semaBlocks.items[i].move_branch == .if_cond) i -= 1;
    return i;
}

pub fn semaLift(c: *cy.Chunk, expr: sema.ExprResult, node: *ast.Node) !sema.ExprResult {
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
    const ref_t = try sema.getRefType(c, expr.type);
    const loc = try c.ir.newExpr(.lift, ref_t, node, .{
        .child = own_expr.ir,
    });
    return sema.ExprResult.initOwned(loc);
}

fn semaLiftToObject(c: *cy.Chunk, expr: sema.ExprResult, node: *ast.Node) !sema.ExprResult {
    const lift = try semaLift(c, expr, node);
    const loc = try c.ir.newExpr(.bitcast, c.sema.object_t, node, .{
        .expr = lift.ir,
    });

    // Ensure `deinitObject` for child type.
    if (lift.type.kind() == .pointer) {
        _ = try sema.getDeinitObjFunc(c, lift.type.getRefLikeChild().?);
    } else {
        _ = try sema.getDeinitObjFunc(c, lift.type);
    }
    return sema.ExprResult.init(loc, c.sema.object_t);
}

/// `move child` of the value `res` read from a local or a member of one.
pub fn semaMove(c: *cy.Chunk, res_: sema.ExprResult, child: *ast.Node) !sema.ExprResult {
    var res = res_;
    const field_access = try sema_access.build_move_access_path(c, res, child);

    // Can only move if owner was declared in the same block, or the whole value from a branch of an `if`
    // statement in that block (`semaIfStmt` destructs it at the end of the other branches).
    // The first condition of an `if` statement moves like a statement of the block of the `if` statement (`moveBlock`).
    const outer_local = c.temp_access_path.var_id < c.block().varStart;
    if (outer_local and field_access) {
        return c.reportError("Can only move a member of a variable declared in the same block.", child);
    }
    // An assignment to the local that is being checked gives it a value again: no branch or loop sees the move.
    const into_assign = !field_access and sema_assign.movesIntoAssign(c, c.temp_access_path.var_id);
    const cross = !into_assign and c.temp_access_path.var_id < c.semaBlocks.items[moveBlock(c)].varStart;
    if (outer_local and !into_assign and !canMoveAcross(c, c.temp_access_path.var_id)) {
        return reportMoveAcross(c, c.temp_access_path.var_id, child);
    }

    const local = &c.varStack.items[c.temp_access_path.var_id];
    if (local.inner.local.isParam and local.decl_t.isObjectLike()) {
        return c.reportError("Cannot move a reference parameter.", child);
    }
    if (res.type.isManaged() and (local.active_borrows > 0 or local.active_ex_borrows > 0)) {
        // The new owner can free what the borrow points to.
        return c.reportErrorFmt("Cannot move `{}`. There is an active borrow to it.", &.{v(local.name())}, child);
    }

    if (!field_access) {
        // move owner.
        if (local.has_inactive_struct_fields) {
            return c.reportError("Cannot move a partially moved value.", child);
        }
        if (c.move_undo_depth > 0) {
            try c.move_undo.append(c.alloc, .{
                .id = c.temp_access_path.var_id,
                .site = c.moved_sites.get(c.temp_access_path.var_id),
                .has_site = true,
                .branch = cross,
            });
        }
        local.type = .dead;
        try c.moved_sites.put(c.alloc, c.temp_access_path.var_id, child);
        if (cross) try c.branch_moves.append(c.alloc, c.temp_access_path.var_id);
        if (res.ir.code == .local) {
            res.ir.cast(.local).moved = true;
        }
        // A value like a call result, not a read of a local: the local is dead.
        return sema.ExprResult.initOwned(res.ir);
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
    if (c.move_undo_depth > 0) {
        try c.move_undo.append(c.alloc, .{
            .id = c.temp_access_path.var_id,
            .member = true,
            .new_state = !state_res.found_existing,
            .offset = @intCast(start),
            .len = @intCast(c.temp_access_path.state_len),
        });
    }
    @memset(state_res.value_ptr.*[start..start + c.temp_access_path.state_len], false);

    res.owned = true;
    return res;
}

/// A move made while an overload candidate is matched (`Chunk.move_undo`).
pub const MoveUndo = struct {
    id: sema.LocalId,
    /// The site that `Chunk.moved_sites` had for the local before the move, when `has_site`.
    site: ?*ast.Node = null,
    has_site: bool = false,
    /// The move was added to `Chunk.branch_moves`.
    branch: bool = false,
    /// Not a move: an assignment gave the moved local a value (`reviveLocal`), and took this many entries of it out of
    /// `Chunk.branch_moves`.
    revive: bool = false,
    branch_taken: u32 = 0,
    /// The move of a member: the range of the member state, and whether the move created the state of the local.
    member: bool = false,
    new_state: bool = false,
    offset: u32 = 0,
    len: u32 = 0,
};

/// Records that the local `id` is about to be made dead by a move that `semaMove` does not make.
pub fn noteMove(c: *cy.Chunk, id: sema.LocalId) !void {
    if (c.move_undo_depth == 0) return;
    if (c.varStack.items[id].type != .local) return;
    try c.move_undo.append(c.alloc, .{ .id = id });
}

/// Takes back the moves recorded since `start`: an overload candidate did not match, and the next one checks the
/// arguments again. The locals from `var_start` on are discarded by the caller.
pub fn undoMoves(c: *cy.Chunk, start: usize, var_start: usize) void {
    var i = c.move_undo.items.len;
    while (i > start) {
        i -= 1;
        const undo = c.move_undo.items[i];
        if (undo.branch) _ = c.branch_moves.pop();
        for (0..undo.branch_taken) |_| c.branch_moves.append(c.alloc, undo.id) catch @panic("OOM");
        if (undo.id >= var_start) continue;
        const local = &c.varStack.items[undo.id];
        if (undo.member) {
            if (c.proc().var_active_struct_fields.get(undo.id)) |fields| {
                @memset(fields[undo.offset..undo.offset + undo.len], true);
            }
            if (undo.new_state) {
                _ = c.proc().var_active_struct_fields.remove(undo.id);
                local.has_inactive_struct_fields = false;
            }
            continue;
        }
        local.type = if (undo.revive) .dead else .local;
        if (undo.has_site) {
            if (undo.site) |site| {
                c.moved_sites.putAssumeCapacity(undo.id, site);
            } else {
                _ = c.moved_sites.remove(undo.id);
            }
        }
    }
    c.move_undo.items.len = start;
}

/// A place (a global, a field of one, the target of a pointer) that a method call takes out for an exclusive borrow
/// of its receiver (`takeGlobal`). `ptr` is a hidden local with the address of the place. `local` is the hidden local
/// that the receiver borrows.
pub const GlobalTake = struct {
    ptr: sema.LocalId,
    local: sema.LocalId,
    type: *cy.Type,
    /// The receiver node, for the error of an argument that reads the place.
    rec: *ast.Node,
    /// Whether the value of the place moved into `local` (`finishGlobalTake`).
    done: bool = false,
};

pub fn isIdentChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

/// The path of a receiver: `s.xs` of `s.xs`, `g` of `(g)`, `p` of `p.*`, `xs` of `xs[0].ys`.
fn placePath(src: []const u8) []const u8 {
    var start: usize = 0;
    while (start < src.len and (src[start] == '(' or src[start] == ' ')) start += 1;
    var end = start;
    while (end < src.len) {
        if (isIdentChar(src[end])) {
            end += 1;
        } else if (src[end] == '.' and end + 1 < src.len and isIdentChar(src[end + 1])) {
            end += 1;
        } else break;
    }
    return src[start..end];
}

/// Whether the code `src` reads the place `path` (`g`, `s.xs`), a part of it (`s.xs.len`), or a value that holds it
/// (`s`). A different field (`s.n`) does not read it. A method call on a parent (`s.sum()`) can read it.
/// The text of a string literal is skipped; an interpolation `%{...}` inside a string is code and is searched.
fn mentionsPlace(src: []const u8, path: []const u8) bool {
    if (path.len == 0) return false;
    var quote: u8 = 0;
    var interp_depth: u32 = 0;
    var i: usize = 0;
    while (i < src.len) : (i += 1) {
        const ch = src[i];
        if (quote != 0 and interp_depth == 0) {
            if (ch == '\\') {
                i += 1;
            } else if (ch == '%' and i + 1 < src.len and src[i + 1] == '{') {
                interp_depth = 1;
                i += 1;
            } else if (ch == quote) {
                quote = 0;
            }
            continue;
        }
        if (interp_depth > 0) {
            if (ch == '{') interp_depth += 1;
            if (ch == '}') {
                interp_depth -= 1;
                continue;
            }
        } else if (ch == '\'' or ch == '"') {
            quote = ch;
            continue;
        }
        if (!isIdentChar(ch)) continue;
        // The start of a name chain (`a.b.c`). A chain after `.` is a field of another value.
        const chain_start = i;
        var end = i;
        while (end < src.len) {
            if (isIdentChar(src[end])) {
                end += 1;
            } else if (src[end] == '.' and end + 1 < src.len and isIdentChar(src[end + 1])) {
                end += 1;
            } else break;
        }
        i = end - 1;
        if (chain_start > 0 and src[chain_start - 1] == '.') continue;
        var chain = src[chain_start..end];
        if (end < src.len and src[end] == '(') {
            // The last name is a method. It can read every part of its receiver.
            const dot = std.mem.lastIndexOfScalar(u8, chain, '.') orelse continue;
            chain = chain[0..dot];
        }
        var chain_it = std.mem.splitScalar(u8, chain, '.');
        var path_it = std.mem.splitScalar(u8, path, '.');
        while (true) {
            const chain_part = chain_it.next() orelse return true;
            const path_part = path_it.next() orelse return true;
            if (!std.mem.eql(u8, chain_part, path_part)) break;
        }
    }
    return false;
}

test "mentionsPlace" {
    try std.testing.expect(mentionsPlace("g.span()", "g"));
    try std.testing.expect(mentionsPlace("g", "g"));
    try std.testing.expect(!mentionsPlace("'a'.concat('1')", "a"));
    try std.testing.expect(mentionsPlace("'n %{a.len()}'", "a"));
    try std.testing.expect(!mentionsPlace("x.a + ab", "a"));
    try std.testing.expect(!mentionsPlace("'it\\'s a'", "a"));
    try std.testing.expect(!mentionsPlace("st.n", "st.xs"));
    try std.testing.expect(mentionsPlace("st", "st.xs"));
    try std.testing.expect(mentionsPlace("st.xs[1..]", "st.xs"));
    try std.testing.expect(mentionsPlace("st.view()", "st.xs"));
    try std.testing.expect(!mentionsPlace("st.other.span()", "st.xs"));
    try std.testing.expect(!mentionsPlace("view()", "view"));
}

test "placePath" {
    try std.testing.expectEqualStrings("g", placePath("(g)"));
    try std.testing.expectEqualStrings("s.xs", placePath("s.xs"));
    try std.testing.expectEqualStrings("p", placePath("p.*"));
    try std.testing.expectEqualStrings("xs", placePath("xs[0].ys"));
}

/// Take-and-restore: a global can not be borrowed exclusively, because a function could reach it through the global
/// while it holds the borrow. For the receiver of a method call (`g.append(v)`, `g += v`, `s.xs.append(v)`), the
/// value of the place moves into a hidden local for the call, the place holds an empty value meanwhile, and
/// `restoreGlobal` moves the value back right after the call. Only for a type that has an empty value
/// (`@init_sequence`: `Slice`, `Array`). Returns the hidden local, or null for another type.
///
/// The value moves after the arguments are evaluated (`finishGlobalTake`), so an argument reads the place as it
/// was, and an argument that leaves the call (`f()!`) leaves the place as it was. Until then the hidden local holds
/// the empty value.
pub fn takeGlobal(c: *cy.Chunk, place: sema.ExprResult, node: *ast.Node) !?sema.ExprResult {
    const var_t = place.type;
    const init_seq = (try c.accessResolvedSym(var_t, "@init_sequence", node)) orelse return null;
    if (init_seq.type != .func) return null;
    // The address is taken once, so the place is evaluated once.
    const ptr_t = try sema.getPtrType(c, var_t);
    const addr = try sema_expr.semaAddressOf(c, place, ptr_t, node);
    const ptr = try sema_local.declareHiddenLocal(c, "_place", ptr_t, addr, node);
    const empty = try sema_init.sema_init_seq2(c, init_seq, &.{}, node);
    const taken = try sema_local.declareHiddenLocal(c, "_global", var_t, empty, node);
    c.global_take = .{ .ptr = ptr.id, .local = taken.id, .type = var_t, .rec = node };
    return try sema_expr.semaLocal(c, taken.id, node);
}

/// An argument that is a local, a part of one, a constant, or a borrow of a local does not read a global.
fn argReadsNoGlobal(expr: *ir.Expr) bool {
    return switch (expr.code) {
        .local, .captured, .const8, .const16, .const32, .const64, .truev, .falsev, .voidv, .undef,
        .func, .func_ptr, .string, .init_zero => true,
        .address_of => argReadsNoGlobal(expr.cast(.address_of).expr),
        .field => argReadsNoGlobal(expr.cast(.field).rec),
        .retain => argReadsNoGlobal(expr.cast(.retain).expr),
        .unwrap_nz => argReadsNoGlobal(expr.cast(.unwrap_nz).option),
        .unwrap_addr => addrOfLocal(expr.cast(.unwrap_addr).choice),
        .deref => addrOfLocal(expr.cast(.deref).expr),
        .bitcast => argReadsNoGlobal(expr.cast(.bitcast).expr),
        .cast => argReadsNoGlobal(expr.cast(.cast).expr),
        else => false,
    };
}

/// Whether `expr` is the address of a local or of a part of one. A pointer or a borrow that a local holds can
/// point to a global.
fn addrOfLocal(expr: *ir.Expr) bool {
    return switch (expr.code) {
        .local => switch (expr.type.kind()) {
            .pointer, .borrow, .ex_borrow => false,
            else => !expr.type.info.borrow_only,
        },
        .address_of => argReadsNoGlobal(expr.cast(.address_of).expr),
        .unwrap_addr => addrOfLocal(expr.cast(.unwrap_addr).choice),
        .bitcast => addrOfLocal(expr.cast(.bitcast).expr),
        else => false,
    };
}

/// A place argument (`g[0]`) is read where the call takes it, inside the call. While a call holds a taken place
/// (`takeGlobal`), the place is empty there, so a place that is not part of a local is registered as a pending operand:
/// `finishGlobalTake` then reads it into a local before the value moves (`g.append(g[0])`). Only for a value that
/// needs no copy and no destructor. A borrow can not be held in a local (`seqPush`).
pub fn seqPushTakeArg(c: *cy.Chunk, slot: **ir.Expr, node: *ast.Node) !void {
    const take = c.global_take orelse return;
    if (take.done) return;
    if (argReadsNoGlobal(slot.*)) return;
    if (slot.*.type.isManaged()) return;
    try seqPush(c, slot, false, node);
}

/// Called when the arguments of the call that took a place (`takeGlobal`) are matched, while they are still pending
/// operands: the statements here evaluate them into locals first (`seqFlush`). Then the value of the place and the
/// empty value of the hidden local change places.
/// `args` and `nodes` are the arguments after the receiver. An argument that can not be held in a local (a borrow,
/// a place of a managed value) is evaluated inside the call, where the place is empty: it is an error for it to read
/// the place.
pub fn finishGlobalTake(c: *cy.Chunk, args: []const *ir.Expr, nodes: []const *ast.Node) !void {
    var take = c.global_take orelse return;
    if (take.done) return;
    const node = take.rec;
    // Like `_temp` in `semaAssignToGlobal`: a local gets the value without a copy, and the place gets a new value
    // without a release.
    const read = try c.ir.newExpr(.deref, take.type, node, .{ .expr = (try sema_expr.semaLocal(c, take.ptr, node)).ir });
    const swap = try sema_local.declareHiddenLocal(c, "_swap", take.type, sema.ExprResult.init(read, take.type), node);
    _ = try c.ir.pushStmt(.set_deref, node, .{
        .ptr = (try sema_expr.semaLocal(c, take.ptr, node)).ir,
        .right = (try sema_expr.semaLocal(c, take.local, node)).ir,
    });
    _ = try c.ir.pushStmt(.set_local, node, .{
        .id = c.varStack.items[take.local].inner.local.id,
        .right = (try sema_expr.semaLocal(c, swap.id, node)).ir,
    });
    c.varStack.items[swap.id].type = .dead;
    take.done = true;
    c.global_take = take;

    const path = placePath(c.nodeString(node));
    for (args, nodes) |arg, arg_n| {
        if (argReadsNoGlobal(arg)) continue;
        if (mentionsPlace(c.nodeString(arg_n), path)) {
            return c.reportErrorFmt("The method takes `{}` out while it runs, so this argument can not read `{}`. Read it into a local first.", &.{v(c.nodeString(node)), v(path)}, arg_n);
        }
    }
}

/// Runs the call `res` that took a place (`takeGlobal`) and moves the value back. The result of the call is kept in a
/// hidden local, so the place holds its value again when the result is used.
pub fn restoreGlobal(c: *cy.Chunk, take: GlobalTake, res: sema.ExprResult, node: *ast.Node) !sema.ExprResult {
    if (!take.done) {
        // The hidden local would hold the empty value, and the call would change that.
        return c.reportError("Unsupported: this call can not change a global in place. Change a local and assign it to the global.", node);
    }
    var out: sema.ExprResult = undefined;
    if (res.resType == .ct_value) {
        out = res;
    } else if (res.type.id() == bt.Void or res.type.id() == bt.Never) {
        _ = try c.ir.pushStmt(.discard, node, .{ .expr = res.ir });
        out = sema.ExprResult.initVoid(c.sema.void_t);
    } else {
        const tmp = try sema_local.declareHiddenLocal(c, "_res", res.type, res, node);
        c.varStack.items[tmp.id].lifetime = .initTemp();
        out = try sema_expr.semaLocal(c, tmp.id, node);
    }
    // Destruct the empty value, then move the taken value back.
    const read = try c.ir.newExpr(.deref, take.type, node, .{ .expr = (try sema_expr.semaLocal(c, take.ptr, node)).ir });
    const cur = try sema_local.declareHiddenLocal(c, "_temp", take.type, sema.ExprResult.init(read, take.type), node);
    try sema_local.semaDestructLocal(c, &c.varStack.items[cur.id], node);
    c.varStack.items[cur.id].type = .dead;
    const taken = try sema_expr.semaLocal(c, take.local, node);
    _ = try c.ir.pushStmt(.set_deref, node, .{ .ptr = (try sema_expr.semaLocal(c, take.ptr, node)).ir, .right = taken.ir });
    c.varStack.items[take.local].type = .dead;
    return out;
}
