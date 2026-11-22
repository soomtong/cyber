const std = @import("std");
const cy = @import("cyber.zig");
const ir = cy.ir;
const fmt = cy.fmt;
const v = fmt.v;
const ast = cy.ast;
const Sym = cy.Sym;
const sema = cy.sema;
const sema_access = cy.sema_access;
const sema_move = cy.sema_move;

/// The local that owns the value an expression borrows from. Borrow locals are followed to their owner,
/// so `r := &a; x := r` and `&r.field` all resolve to `a`.
pub fn borrowOwner(c: *cy.Chunk, expr: sema.ExprResult) ?sema.LocalId {
    const parent = expr.recParentLocal() orelse return null;
    return borrowOwnerOf(c, parent);
}

pub fn borrowOwnerOf(c: *cy.Chunk, local: sema.LocalId) sema.LocalId {
    var owner = local;
    while (c.varStack.items[owner].parent_local != cy.NullId) {
        owner = c.varStack.items[owner].parent_local;
    }
    return owner;
}

/// The template instance whose declaration or body is being checked, if any: the innermost resolve context that
/// belongs to one, else the innermost proc. A lambda in a body belongs to no instance, so the procs are walked outward.
pub fn bodyInstance(c: *cy.Chunk) ?*cy.Instance {
    var j = c.resolve_stack.items.len;
    while (j > 0) {
        j -= 1;
        const ctx = c.resolve_stack.items[j];
        switch (ctx.type) {
            .chunk => {},
            .func => if (cy.compiler.ownerInstance(ctx.data.func)) |inst| return inst,
            .sym => {
                var cur: ?*cy.Sym = ctx.data.sym;
                while (cur) |sym| : (cur = sym.parent) {
                    if (sym.instance()) |inst| return inst;
                }
            },
        }
    }
    var i = c.semaProcs.items.len;
    while (i > 0) {
        i -= 1;
        const func = c.semaProcs.items[i].func orelse continue;
        if (cy.compiler.ownerInstance(func)) |inst| return inst;
    }
    return null;
}

/// Of two borrow owners, the one that goes out of scope first. A value that borrows from both (a borrow container
/// literal, a pinned closure) lives only as long as that one. Of two locals of one block, the one declared later goes
/// first (a body local before a parameter).
pub fn shorterOwner(c: *cy.Chunk, cur: ?sema.LocalId, next: ?sema.LocalId) ?sema.LocalId {
    const b = next orelse return cur;
    const a = cur orelse return b;
    const la = c.varStack.items[a].lifetime;
    const lb = c.varStack.items[b].lifetime;
    if (la.kind == .temp) return a;
    if (lb.kind == .temp) return b;
    if (lb.kind == .block and (la.kind != .block or lb.block_depth > la.block_depth)) return b;
    if (lb.kind == .block and la.kind == .block and lb.block_depth == la.block_depth and b > a) return b;
    return a;
}

/// A `scope` function returns a borrow (or a value that holds one: `?&T`, `!&T`, a borrow container) only from its
/// `scope` parameter. Every owner of the value counts: the owner of the result, the other owners that the branches of
/// the expression note from `pending_start` on (`if c: &p[0] else &y`), and the loans of a returned local.
pub fn checkReturnOwners(c: *cy.Chunk, expr: sema.ExprResult, pending_start: usize, node: *ast.Node) !void {
    if (!expr.type.info.borrow_only) return;
    const proc = c.proc();
    // The main block has no function, and a lambda whose return type is being inferred from this expression
    // (`fn() => borrow`) has no signature yet. Neither has a `scope` parameter to check against.
    const func = proc.func orelse return;
    if (!func.isResolved()) return;
    const idx = func.sig.scope_param_idx;
    if (idx == cy.NullU8) return;
    const param: sema.LocalId = @intCast(proc.varStart + idx);

    if (borrowOwner(c, expr)) |owner| {
        if (owner != param) return reportReturnOwner(c, param, node);
    } else if (isBorrowType(expr.type)) {
        return c.reportError("Expected parent lifetime local.", node);
    }
    if (expr.resType == .value_local) {
        for (c.borrow_loans.items) |loan| {
            if (loan.local != expr.data.value_local) continue;
            if (borrowOwnerOf(c, loan.owner) != param) return reportReturnOwner(c, param, node);
        }
    }
    for (c.borrow_pending.items[pending_start..]) |p| {
        if (p.owner >= c.varStack.items.len) continue;
        if (borrowOwnerOf(c, p.owner) != param) return reportReturnOwner(c, param, node);
    }
}

fn reportReturnOwner(c: *cy.Chunk, param: sema.LocalId, node: *ast.Node) anyerror {
    const param_name = c.varStack.items[param].name();
    return c.reportErrorFmt("Expected to return a borrow from the same scope as `{}`.", &.{v(param_name)}, node);
}

/// Notes the owner of a borrow that becomes a part of a value (a field of a literal, a branch of an `if` expression, a
/// capture), for the local that the value is bound to in this statement.
pub fn noteBorrowOwner(c: *cy.Chunk, owner: ?sema.LocalId, ex: bool) !void {
    const o = owner orelse return;
    try c.borrow_pending.append(c.alloc, .{ .owner = o, .ex = ex });
}

/// The owner of a value that one of several branches gives (an `if` or `switch` expression, the two sides of `?else`
/// and `!else`), joined with the owner `cur` of the branches before it. The result lives as long as the owner that goes
/// out of scope first, and the other owners are loans of the local that the result is bound to.
pub fn joinBranchOwner(c: *cy.Chunk, cur: ?sema.LocalId, res: sema.ExprResult) !?sema.LocalId {
    if (!res.type.info.borrow_only) return cur;
    const owner = borrowOwner(c, res);
    try noteBorrowOwner(c, owner, res.type.info.ex_borrow);
    return shorterOwner(c, cur, owner);
}

/// `joinBranchOwner` for the body of a `switch` case. A borrow of a local of the case (`case .one |v| => &v`) ends
/// with the case, so the result can not hold it.
pub fn joinCaseOwner(c: *cy.Chunk, cur: ?sema.LocalId, res: sema.ExprResult, case_var_start: usize, node: *ast.Node) !?sema.LocalId {
    if (res.type.info.borrow_only) {
        if (borrowOwner(c, res)) |owner| {
            if (owner >= case_var_start) {
                const name = c.varStack.items[owner].name();
                return c.reportErrorFmt("The result of `switch` can not outlive `{}`.", &.{v(name)}, node);
            }
        }
    }
    return joinBranchOwner(c, cur, res);
}

/// Records that the capture `var_idx` of a `switch` case holds the borrow `init` (the payload of the control or a
/// borrow of it) until the case ends. The borrow owners that the branches of the `switch` note before it are kept.
pub fn bindCaptureLocal(c: *cy.Chunk, var_idx: sema.LocalId, init: sema.ExprResult) !void {
    const saved_start = c.borrow_pending_start;
    c.borrow_pending_start = @intCast(c.borrow_pending.items.len);
    defer c.borrow_pending_start = saved_start;
    try bindBorrowLocal(c, var_idx, init);
}

fn addBorrowLoan(c: *cy.Chunk, local: sema.LocalId, owner: sema.LocalId, ex: bool) !void {
    if (owner == local or c.varStack.items[local].parent_local == owner) return;
    for (c.borrow_loans.items) |loan| {
        if (loan.local == local and loan.owner == owner and (loan.ex or !ex)) return;
    }
    try c.borrow_loans.append(c.alloc, .{ .local = local, .owner = owner, .ex = ex });
    if (ex) {
        c.varStack.items[owner].active_ex_borrows += 1;
    } else {
        c.varStack.items[owner].active_borrows += 1;
    }
}

/// Forgets the loans of the locals from `var_start` on, which are removed without `unbindBorrowLocal` (the end of a
/// function, a failed match). Their owners are removed with them or were not counted for good.
pub fn truncateBorrowLoans(c: *cy.Chunk, var_start: usize) void {
    var i: usize = 0;
    while (i < c.borrow_loans.items.len) {
        const loan = c.borrow_loans.items[i];
        if (loan.local < var_start) {
            i += 1;
            continue;
        }
        if (loan.owner < var_start) {
            const owner = &c.varStack.items[loan.owner];
            if (loan.ex) owner.active_ex_borrows -= 1 else owner.active_borrows -= 1;
        }
        _ = c.borrow_loans.swapRemove(i);
    }
}

fn dropBorrowLoans(c: *cy.Chunk, local: sema.LocalId) void {
    var i: usize = 0;
    while (i < c.borrow_loans.items.len) {
        const loan = c.borrow_loans.items[i];
        if (loan.local != local) {
            i += 1;
            continue;
        }
        const owner = &c.varStack.items[loan.owner];
        if (loan.ex) owner.active_ex_borrows -= 1 else owner.active_borrows -= 1;
        _ = c.borrow_loans.swapRemove(i);
    }
}

/// A borrow that is stored in a field or an element of a local (`h.r = &&f`) is a loan of the value that has the
/// field, until that value goes out of scope.
pub fn addFieldBorrowLoan(c: *cy.Chunk, left: sema.ExprResult, right: sema.ExprResult) !void {
    if (!right.type.info.borrow_only) return;
    const owner = borrowOwner(c, right) orelse return;
    var target = left.recParentLocal() orelse return;
    const root = c.varStack.items[target];
    if (root.parent_local != cy.NullId and isBorrowLocal(c, target)) {
        // Through a local that is a borrow, the value is in the container it was read through or in the owner.
        target = if (root.borrow_via != cy.NullId) root.borrow_via else root.parent_local;
    }
    try addBorrowLoan(c, target, owner, right.type.info.ex_borrow);
    // The other owners of a borrow that one of several branches gives (`h.r = if c: &y else &a[0]`), or of a borrow
    // container.
    for (c.borrow_pending.items[c.borrow_pending_start..]) |p| {
        if (p.owner >= c.varStack.items.len) continue;
        const other = borrowOwnerOf(c, p.owner);
        if (other == owner) continue;
        try addBorrowLoan(c, target, other, p.ex);
    }
}

/// A copy of a borrow container that is read from the local `from` (`r = h`, the element that `for xs |p|` copies)
/// keeps the other owners that `from` lends from (`BorrowLoan`), and those of the containers it was read through.
fn copyBorrowLoans(c: *cy.Chunk, var_idx: sema.LocalId, owner: sema.LocalId, from: sema.LocalId) !void {
    var cur = from;
    var depth: usize = 0;
    while (cur != cy.NullId and cur != owner and cur != var_idx and depth < 16) : (depth += 1) {
        const len = c.borrow_loans.items.len;
        var i: usize = 0;
        while (i < len) : (i += 1) {
            const loan = c.borrow_loans.items[i];
            if (loan.local != cur) continue;
            const other = borrowOwnerOf(c, loan.owner);
            if (other == owner or other == var_idx) continue;
            try addBorrowLoan(c, var_idx, other, loan.ex);
        }
        cur = c.varStack.items[cur].borrow_via;
    }
}

/// Records that the local `var_idx` holds the borrow `init` until it goes out of scope.
pub fn bindBorrowLocal(c: *cy.Chunk, var_idx: sema.LocalId, init: sema.ExprResult) !void {
    const decl_t = c.varStack.items[var_idx].decl_t;
    if (!decl_t.info.borrow_only) return;
    const owner = borrowOwner(c, init) orelse return;
    if (owner == var_idx) return;
    defer c.borrow_pending.items.len = c.borrow_pending_start;
    // The other owners of a borrow container, or of a borrow that one of several branches gives
    // (`if c: &x else &a[0]`).
    var i: usize = c.borrow_pending_start;
    while (i < c.borrow_pending.items.len) : (i += 1) {
        const p = c.borrow_pending.items[i];
        if (p.owner >= c.varStack.items.len) continue;
        const other = borrowOwnerOf(c, p.owner);
        if (other == owner or other == var_idx) continue;
        try addBorrowLoan(c, var_idx, other, p.ex);
    }
    try copyBorrowLoans(c, var_idx, owner, init.recParentLocal().?);
    // A value that contains an exclusive borrow (`Holder{r=&&f}`, `?&&Foo`) keeps exclusive access like the borrow.
    const ex = decl_t.info.ex_borrow;
    const local = &c.varStack.items[var_idx];
    local.parent_local = owner;
    local.ex_borrow = ex;
    const via = init.recParentLocal().?;
    var inline_: bool = undefined;
    local.borrow_field = borrowField2(c, init, &inline_);
    local.borrow_inline = inline_;
    if (init.resType == .value_local) {
        // A copy points to the same value as the local it copies.
        local.borrow_alias = borrowAlias(c, via);
        local.borrow_via = c.varStack.items[via].borrow_via;
    } else if (via != owner) {
        local.borrow_via = if (isBorrowLocal(c, via)) c.varStack.items[via].borrow_via else via;
    }
    if (ex) {
        c.varStack.items[owner].active_ex_borrows += 1;
    } else {
        c.varStack.items[owner].active_borrows += 1;
    }
}

pub fn unbindBorrowLocal(c: *cy.Chunk, local: *sema.Local) void {
    if (c.borrow_loans.items.len > 0) {
        dropBorrowLoans(c, @intCast((@intFromPtr(local) - @intFromPtr(c.varStack.items.ptr)) / @sizeOf(sema.Local)));
    }
    if (local.parent_local == cy.NullId) return;
    const owner = &c.varStack.items[local.parent_local];
    if (local.ex_borrow) {
        owner.active_ex_borrows -= 1;
    } else {
        owner.active_borrows -= 1;
    }
    local.parent_local = cy.NullId;
    local.ex_borrow = false;
    local.borrow_via = cy.NullId;
    local.borrow_alias = cy.NullId;
    local.borrow_field = sema.borrow_field_unknown;
    local.borrow_inline = false;
}

/// The field of the owner that `expr` reads or points into: a field index, `borrow_field_whole` when it is the whole
/// value of the owner, or `borrow_field_unknown`.
pub fn borrowField(c: *cy.Chunk, expr: sema.ExprResult) u16 {
    var inline_: bool = undefined;
    return borrowField2(c, expr, &inline_);
}

/// `inline_` is set to whether `expr` is the place of the owner or of a field in it (`Local.borrow_inline`).
fn borrowField2(c: *cy.Chunk, expr: sema.ExprResult, inline_: *bool) u16 {
    inline_.* = false;
    const via = expr.recParentLocal() orelse return sema.borrow_field_unknown;
    const via_local = c.varStack.items[via];
    var base: u16 = sema.borrow_field_whole;
    var base_inline = true;
    if (via_local.parent_local != cy.NullId) {
        // Through a local that is a borrow, the path starts where that borrow points. A borrow container can hold
        // more than one borrow.
        if (!isBorrowLocal(c, via)) return sema.borrow_field_unknown;
        base = via_local.borrow_field;
        base_inline = via_local.borrow_inline;
    }

    // The field that is read from the local first. A `scope` result points into what its `scope` argument points to.
    var field: u16 = sema.borrow_field_whole;
    var path_inline = true;
    var cur = expr.ir;
    while (true) {
        switch (cur.code) {
            .address_of => cur = cur.cast(.address_of).expr,
            .deref => {
                cur = cur.cast(.deref).expr;
                // Two fields can hold a reference to one object, so a path through a reference names no field.
                if (!isBorrowType(cur.type)) return sema.borrow_field_unknown;
            },
            .field => {
                field = cur.cast(.field).idx;
                cur = cur.cast(.field).rec;
                if (cur.type.kind() == .pointer) return sema.borrow_field_unknown;
            },
            .call => {
                const call = cur.cast(.call);
                const idx = call.func.sig.scope_param_idx;
                if (idx == cy.NullU8 or idx >= call.numArgs) return sema.borrow_field_unknown;
                field = sema.borrow_field_whole;
                path_inline = false;
                cur = call.args[idx];
            },
            .local => {
                inline_.* = base_inline and path_inline;
                return if (base != sema.borrow_field_whole) base else field;
            },
            else => return sema.borrow_field_unknown,
        }
    }
}

/// Whether `expr` is read through a shared borrow (`b.*` of `b := &r`, `self.r` of `self &Holder`). A shared borrow
/// gives no exclusive access to what is behind it, also when that is an exclusive borrow.
pub fn readThroughShared(expr: *ir.Expr) bool {
    var cur = expr;
    while (true) {
        switch (cur.code) {
            .deref => cur = cur.cast(.deref).expr,
            .field => cur = cur.cast(.field).rec,
            else => return false,
        }
        if (cur.type.kind() == .borrow) return true;
    }
}

/// Whether the place `expr` is reached through a shared borrow: `self.xs` of `self &Foo`, `f.*` of `f &[]int`,
/// `self.items[i].name` (the borrow that `@index_addr` returns comes from its receiver). What is behind a pointer
/// (`self.node.xs` of `node ^Node`) is reached through the pointer, which is not a borrow.
pub fn placeThroughShared(expr: *ir.Expr) bool {
    var cur = expr;
    while (true) {
        switch (cur.code) {
            .address_of => {
                cur = cur.cast(.address_of).expr;
                continue;
            },
            .call => {
                // A borrow that a function returns points into what its first argument borrows.
                const call = cur.cast(.call);
                if (call.numArgs == 0 or !isBorrowType(cur.type)) return false;
                cur = call.args[0];
                continue;
            },
            else => {},
        }
        switch (cur.type.kind()) {
            .borrow => return true,
            .pointer => return false,
            else => {},
        }
        switch (cur.code) {
            .deref => cur = cur.cast(.deref).expr,
            .field => cur = cur.cast(.field).rec,
            else => return false,
        }
    }
}

/// A shared borrow gives no access that frees or moves what is behind it: another shared borrow of the same owner
/// can point into it (`s := &f.xs[0]` next to the `&f` that a method received).
fn checkNoWriteThroughShared(c: *cy.Chunk, place: *ir.Expr, comptime what: []const u8, node: *ast.Node) !void {
    if (!placeThroughShared(place)) return;
    // A destructor has the only access to the value that it ends.
    if (c.proc().func) |func| {
        if (std.mem.eql(u8, func.name(), "@deinit")) return;
    }
    return c.reportError("Cannot " ++ what ++ " through a shared borrow. Declare the borrow as `&&T`.", node);
}

fn isBorrowType(type_: *cy.Type) bool {
    return switch (type_.kind()) {
        .borrow, .ex_borrow => true,
        else => false,
    };
}

fn borrowFieldsDisjoint(a: u16, b: u16) bool {
    return a < sema.borrow_field_whole and b < sema.borrow_field_whole and a != b;
}

/// Whether the local is a borrow itself (`r := &&f`), not a value that contains borrows.
pub fn isBorrowLocal(c: *cy.Chunk, local: sema.LocalId) bool {
    return switch (c.varStack.items[local].decl_t.kind()) {
        .borrow, .ex_borrow => true,
        else => false,
    };
}

fn borrowAlias(c: *cy.Chunk, local: sema.LocalId) sema.LocalId {
    const alias = c.varStack.items[local].borrow_alias;
    return if (alias != cy.NullId) alias else local;
}

/// A local can not start to hold a borrow that conflicts with the one that another local holds. A borrow taken through
/// a local that is a borrow (`&r.xs[0]` of `r := &&f`, `r.first()`) passes `otherBorrows` as a reborrow, which is sound
/// only while it lasts no longer than its statement. Kept in a local it would live next to `r`, and `r` could free what
/// it points to. Call before `bindBorrowLocal`, when the local holds no borrow.
pub fn checkBindBorrow(c: *cy.Chunk, var_idx: sema.LocalId, init: sema.ExprResult, node: *ast.Node) !void {
    const decl_t = c.varStack.items[var_idx].decl_t;
    if (!decl_t.info.borrow_only) return;
    // A copy of a borrow local (`r2 := r`) is no new borrow.
    if (init.resType == .value_local) return;
    const via = init.recParentLocal() orelse return;
    const owner = borrowOwnerOf(c, via);
    if (via == owner or owner == var_idx) return;
    switch (c.varStack.items[via].decl_t.kind()) {
        .borrow, .ex_borrow => {},
        // A borrow of a borrow container (`&h` of `h := Holder{r=&&f}`) borrows the container.
        else => return,
    }
    if (decl_t.kind() == .ex_borrow) {
        try checkExclusiveBorrow(c, owner, node);
    } else {
        try checkSharedBorrow(c, owner, node);
    }
}

/// The borrow counts of the owner of `local`, without the binding of `local` itself. A borrow taken through a local that
/// holds a borrow (`r := &&f`, a borrow container such as `h := Holder{r=&&f}`) reborrows from it, so its own binding is
/// no conflict. The reborrow can not be kept in a local (`checkBindBorrow`).
fn otherBorrows(c: *cy.Chunk, local: sema.LocalId) struct { owner: sema.LocalId, shared: u8, ex: u8 } {
    const owner = borrowOwnerOf(c, local);
    var shared = c.varStack.items[owner].active_borrows;
    var ex = c.varStack.items[owner].active_ex_borrows;
    const l = c.varStack.items[local];
    if (local != owner and l.parent_local == owner) {
        if (l.ex_borrow) ex -= 1 else shared -= 1;
    }
    return .{ .owner = owner, .shared = shared, .ex = ex };
}

/// `checkSharedBorrow` for a borrow of `local` (`&local`, `&local.field`).
pub fn checkSharedBorrowOf(c: *cy.Chunk, local: sema.LocalId, node: *ast.Node) !void {
    const b = otherBorrows(c, local);
    if (b.ex > 0) {
        const name = c.varStack.items[b.owner].name();
        return c.reportErrorFmt("Cannot borrow `{}`. There is an active exclusive borrow to it.", &.{v(name)}, node);
    }
}

/// `checkExclusiveBorrow` for a borrow of `local` (`&&local`, `&&local.field`), and for a use of the exclusive borrow
/// that `local` holds (`local.grow()`, `local.r.grow()`).
pub fn checkExclusiveBorrowOf(c: *cy.Chunk, local: sema.LocalId, node: *ast.Node) !void {
    return checkExclusiveBorrowOfField(c, local, sema.borrow_field_whole, false, node);
}

/// `checkExclusiveBorrowOf` for the field `field` of the owner (`borrowField`). `write` is an assignment: it replaces
/// a value in its place, so a borrow of a place (`Local.borrow_inline`) stays valid and is no conflict.
pub fn checkExclusiveBorrowOfField(c: *cy.Chunk, local: sema.LocalId, field: u16, write: bool, node: *ast.Node) !void {
    // The other locals that `local` borrows from (`BorrowLoan`): no other local can borrow from them either.
    for (c.borrow_loans.items) |loan| {
        if (loan.local != local) continue;
        const owner = c.varStack.items[loan.owner];
        if (@as(usize, owner.active_borrows) + owner.active_ex_borrows > 1) {
            return c.reportErrorFmt("Expected exclusive access. There is another active borrow to `{}`.", &.{v(owner.name())}, node);
        }
    }
    const b = otherBorrows(c, local);
    if (b.shared == 0 and b.ex == 0) return;

    // Some other local borrows from the owner. It is no conflict when it points to the same value as `local` (a copy of
    // the borrow), when `local` was read through it (a borrow container), or when it points into another field.
    var left: usize = @as(usize, b.shared) + b.ex;
    const alias = borrowAlias(c, local);
    for (c.varStack.items, 0..) |other, i| {
        if (i == local or other.parent_local != b.owner) continue;
        const copy = other.decl_t == c.varStack.items[local].decl_t and borrowAlias(c, @intCast(i)) == alias;
        if (!copy and !isBorrowVia(c, local, @intCast(i)) and !borrowFieldsDisjoint(field, other.borrow_field) and
            !(write and other.borrow_inline)) continue;
        left -= 1;
        if (left == 0) return;
    }
    for (c.borrow_loans.items) |loan| {
        // A loan of a container that `local` was read through.
        if (loan.owner != b.owner or !isBorrowVia(c, local, loan.local)) continue;
        left -= 1;
        if (left == 0) return;
    }
    const name = c.varStack.items[b.owner].name();
    return c.reportErrorFmt("Expected exclusive access. There is another active borrow to `{}`.", &.{v(name)}, node);
}

/// Whether the borrow of `local` was read through the borrow container `via`.
fn isBorrowVia(c: *cy.Chunk, local: sema.LocalId, via: sema.LocalId) bool {
    var cur = c.varStack.items[local].borrow_via;
    while (cur != cy.NullId) : (cur = c.varStack.items[cur].borrow_via) {
        if (cur == via) return true;
    }
    return false;
}

/// A shared borrow (`&a`, `&self`) is not allowed while a local holds an exclusive borrow of the owner.
pub fn checkSharedBorrow(c: *cy.Chunk, owner: sema.LocalId, node: *ast.Node) !void {
    if (c.varStack.items[owner].active_ex_borrows > 0) {
        const name = c.varStack.items[owner].name();
        return c.reportErrorFmt("Cannot borrow `{}`. There is an active exclusive borrow to it.", &.{v(name)}, node);
    }
}

/// An exclusive borrow (`&&a`, `&&self`) is not allowed while a local holds any borrow of the owner.
pub fn checkExclusiveBorrow(c: *cy.Chunk, owner: sema.LocalId, node: *ast.Node) !void {
    const local = c.varStack.items[owner];
    if (local.active_borrows > 0 or local.active_ex_borrows > 0) {
        return c.reportErrorFmt("Expected exclusive access. There is another active borrow to `{}`.", &.{v(local.name())}, node);
    }
}

/// An assignment that destructs the old value of a field or an element of `left` frees what a borrow in another local
/// can point to (`s := &g.xs[0]` then `g.xs = {7}`), so it needs the same access as an exclusive borrow. A value that
/// is not managed is written in place, and a borrow of it reads the new value (`c := &x`, `x = 7`, `c.*`).
pub fn checkWriteAccess(c: *cy.Chunk, left: sema.ExprResult, node: *ast.Node) !void {
    return checkFieldWriteAccess(c, left, null, node);
}

/// `checkWriteAccess` for an assignment to the field `field_idx` of `left`.
pub fn checkFieldWriteAccess(c: *cy.Chunk, left: sema.ExprResult, field_idx: ?u16, node: *ast.Node) !void {
    try checkNoWriteThroughShared(c, left.ir, "replace a managed value", node);
    const local = left.recParentLocal() orelse return;
    var field = borrowField(c, left);
    if (field == sema.borrow_field_whole) {
        if (field_idx) |idx| field = idx;
    }
    return checkExclusiveBorrowOfField(c, local, field, true, node);
}

/// A borrow assigned to a local can not come from a value that dies before the local does.
pub fn checkBorrowOutlives(c: *cy.Chunk, var_idx: sema.LocalId, right: sema.ExprResult, node: *ast.Node) !void {
    if (!c.varStack.items[var_idx].decl_t.info.borrow_only) return;
    const owner = borrowOwner(c, right) orelse return;
    try checkOwnerOutlives(c, var_idx, owner, node);
    return checkViaOutlives(c, var_idx, right, node);
}

/// A borrow that is read through a borrow container (`&&h`, `&h.r.xs[0]` of `h := Holder{r=&&f}`) can point to the
/// container, so it can not outlive the container either. A copy of the container (`h2 = h`) does not point to it.
fn checkViaOutlives(c: *cy.Chunk, var_idx: sema.LocalId, right: sema.ExprResult, node: *ast.Node) !void {
    if (right.resType == .value_local) return;
    const via = right.recParentLocal() orelse return;
    if (c.varStack.items[via].parent_local == cy.NullId or isBorrowLocal(c, via)) return;
    return checkOwnerOutlives(c, var_idx, via, node);
}

/// `checkBorrowOutlives` for a borrow assigned to a field or an element (`o.v = View{a=&z}`, `vs[0] = View{a=&z}`,
/// `h.cb = fn() -> int => b.*`). `left` is the left side or the value that has the field or the element. The value
/// lives where the local at the root of the left side keeps it: in the local, or behind the borrow that the local holds.
pub fn checkFieldBorrowOutlives(c: *cy.Chunk, left: sema.ExprResult, right: sema.ExprResult, node: *ast.Node) !void {
    if (!right.type.info.borrow_only) return;
    const owner = borrowOwner(c, right) orelse return;
    var root = left.recParentLocal() orelse return;
    // Through a local that is a borrow (`r := &&o`), the value is in the local it borrows. A borrow container
    // (`o := Outer{v=View{a=&x}}`) keeps the value itself.
    while (c.varStack.items[root].parent_local != cy.NullId) {
        switch (c.varStack.items[root].decl_t.kind()) {
            .borrow, .ex_borrow => root = c.varStack.items[root].parent_local,
            else => break,
        }
    }
    const root_local = c.varStack.items[root];
    const owner_local = c.varStack.items[owner];
    const owner_is_param = owner_local.type == .local and owner_local.inner.local.isParam;
    if (owner != root and root_local.type == .local and root_local.inner.local.isParam and !owner_is_param) {
        switch (root_local.decl_t.kind()) {
            .borrow, .ex_borrow, .pointer => {
                // The value behind a parameter is still there after the call.
                if (owner_local.lifetime.kind == .temp) {
                    return c.reportError("The result can not borrow from a temporary value.", node);
                }
                return c.reportErrorFmt("The value behind `{}` can not outlive `{}`.", &.{v(root_local.name()), v(owner_local.name())}, node);
            },
            else => {},
        }
    }
    try checkOwnerOutlives(c, root, owner, node);
    return checkViaOutlives(c, root, right, node);
}

fn checkOwnerOutlives(c: *cy.Chunk, var_idx: sema.LocalId, owner: sema.LocalId, node: *ast.Node) !void {
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

pub fn sema_ex_borrow2(c: *cy.Chunk, child: sema.ExprResult, ex_borrow_t: *cy.Type, node: *ast.Node) !sema.ExprResult {
    try sema_access.checkPartialMoveWhole(c, child, "borrow", node);
    const eff_child = try sema_move.semaEnsureAddressable(c, child, node);

    const parent_local = eff_child.recParentLocal() orelse {
        if (c.global_take_rec == node and c.global_take == null and eff_child.addressable) {
            if (try sema_move.takeGlobal(c, eff_child, node)) |local_res| {
                return sema_ex_borrow2(c, local_res, ex_borrow_t, node);
            }
        }
        if (eff_child.resType == .varSym) {
            return c.reportError("Cannot acquire exclusive borrow. Consider wrapping type in `Ex`.", node);
        } else {
            return c.reportError("Expected parent local.", node);
        }
    };

    try checkNoWriteThroughShared(c, eff_child.ir, "borrow exclusively", node);
    try checkExclusiveBorrowOfField(c, parent_local, borrowField(c, eff_child), false, node);

    const addr_of = try c.ir.newExpr(.address_of, ex_borrow_t, node, .{
        .expr = eff_child.ir,
    });
    var res = sema.ExprResult.init2(addr_of);
    res.data.value.parent_local = parent_local;
    return res;
}

pub fn sema_ex_borrow(c: *cy.Chunk, child: sema.ExprResult, node: *ast.Node) !sema.ExprResult {
    const borrow_ex_t = try sema.get_ex_borrow_type(c, child.type);
    return sema_ex_borrow2(c, child, borrow_ex_t, node);
}

pub fn semaBorrow(c: *cy.Chunk, child: sema.ExprResult, node: *ast.Node) !sema.ExprResult {
    try sema_access.checkPartialMoveWhole(c, child, "borrow", node);
    // Assign expression to a temp to extend the lifetime.
    const eff_child = try sema_move.semaEnsureAddressable(c, child, node);
    const borrow_t = try sema.getBorrowType(c, eff_child.type);
    const addr_of = try c.ir.newExpr(.address_of, borrow_t, node, .{
        .expr = eff_child.ir,
    });
    var res = sema.ExprResult.init2(addr_of);
    if (eff_child.recParentLocal()) |parent_local| {
        // Counted only when stored in a local (`bindBorrowLocal`). A temporary borrow ends with its statement.
        try checkSharedBorrowOf(c, parent_local, node);
        res.data.value.parent_local = parent_local;
    } else {
        res.data.value.parent_local = null;
    }
    return res;
}
