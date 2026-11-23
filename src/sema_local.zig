const std = @import("std");
const cy = @import("cyber.zig");
const ir = cy.ir;
const bt = cy.types.BuiltinTypes;
const sema_func = cy.sema_func;
const Argument = cy.sema_func.Argument;
const cte = cy.cte;
const fmt = cy.fmt;
const v = fmt.v;
const ast = cy.ast;
const Sym = cy.Sym;
const TypeValue = cy.TypeValue;
const log = cy.log.scoped(.sema);
const sema = cy.sema;
const sema_stmt = cy.sema_stmt;
const sema_borrow = cy.sema_borrow;
const sema_type = cy.sema_type;
const sema_call = cy.sema_call;
const sema_expr = cy.sema_expr;
const sema_access = cy.sema_access;
const sema_resolve = cy.sema_resolve;
const sema_move = cy.sema_move;

pub fn popLocals(c: *cy.Chunk, var_start: usize, node: *ast.Node) !void {
    return popLocals2(c, var_start, true, node);
}

pub fn popLocals2(c: *cy.Chunk, var_start: usize, destruct: bool, node: *ast.Node) !void {
    if (c.varStack.items.len <= var_start) {
        return;
    }

    // try semaTraceNopFmt(c, "pop locals destruct: {s}", .{@tagName(node.type())}, node);
    const saved_end = c.cancel_pad_var_end;
    const saved_proc = c.cancel_pad_var_proc;
    defer {
        c.cancel_pad_var_end = saved_end;
        c.cancel_pad_var_proc = saved_proc;
    }
    var i: usize = c.varStack.items.len;
    while (i > var_start) {
        i -= 1;
        const local = &c.varStack.items[i];
        // Like `semaDestructBlock3`: a fiber cancelled inside this destructor does not destruct this local or the
        // younger ones again.
        c.cancel_pad_var_end = i;
        c.cancel_pad_var_proc = c.semaProcs.items.len;

        // Release the borrow this local held.
        sema_borrow.unbindBorrowLocal(c, local);

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

pub fn semaMethodBody(c: *cy.Chunk, func: *cy.Func) !void {
    if (func.info.emitted) {
        return;
    }
    try sema_resolve.pushFuncResolveContext(c, func, null);
    defer sema_resolve.popResolveContext(c);
    try semaMethodBody2(c, func);
}

pub fn semaMethodBody2(c: *cy.Chunk, func: *cy.Func) !void {
    // Object method.
    const blockId = try pushFuncProc(c, func);
    const parent_t = func.sig.params()[0].get_type();
    if (func.default_trait) |trait_t| {
        try pushDefaultMethodParamVars(c, parent_t, func, trait_t);
    } else {
        c.semaProcs.items[blockId].isMethodBlock = true;
        try pushMethodParamVars(c, parent_t, func);
    }
    if (func.info.generator) {
        try semaGeneratorPrologue(c, func);
    }
    try sema_stmt.semaStmts(c, func.decl.?.cast(.funcDecl).stmts.slice());
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
            var copy = try sema_expr.semaLocal(c, param.stack_idx, @ptrCast(node));
            copy = try sema_move.semaOwn(c, copy, @ptrCast(node));
            _ = try c.ir.pushStmt(.set_local, @ptrCast(node), .{
                .id = @intCast(param.inner.local.id),
                .right = copy.ir,
            });
        }
    }

    const gen_t = proc.func.?.sig.ret.cast(.pointer).child_t;
    const funcptr_t = gen_t.instanceOf(c.sema.generator_tmpl).?.params[0].asPtr(*cy.Type);
    const val_t = funcptr_t.cast(.func_ptr).sig.ret;
    const opt_t = try sema.getOptionType(c, val_t);

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
    try sema_resolve.pushFuncResolveContext(c, func, null);
    defer sema_resolve.popResolveContext(c);
    try semaFuncBody2(c, func);
}

pub fn semaFuncBody2(c: *cy.Chunk, func: *cy.Func) !void {
    const node = func.decl.?.cast(.funcDecl);
    _ = try pushFuncProc(c, func);
    try appendFuncParamVars(c, node.params.slice(), @ptrCast(func.sig.params()));
    if (func.info.generator) {
        try semaGeneratorPrologue(c, func);
    }
    try sema_stmt.semaStmts(c, node.stmts.slice());
    try procPrologue(c);
    try popFuncBlock(c);
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

pub const LocalResult = struct {
    id: u32, 
    ir_id: u32,
};

pub fn declareLocalInit(c: *cy.Chunk, name: []const u8, decl_t: *cy.Type, init: sema.ExprResult, node: *ast.Node) !LocalResult {
    const var_id = try declareLocalName(c, name, decl_t, false, true, node);
    const info = c.varStack.items[var_id].inner.local;
    info.declIrStart.cast(.declare_local).init = init.ir;
    return .{ .id = var_id, .ir_id = info.id };
}

pub fn declareHiddenLocal(c: *cy.Chunk, name: []const u8, decl_t: *cy.Type, init_opt: ?sema.ExprResult, node: *ast.Node) !LocalResult {
    const var_id = try declareLocalName(c, name, decl_t, true, init_opt != null, node);
    const info = c.varStack.items[var_id].inner.local;
    if (init_opt) |init| {
        info.declIrStart.cast(.declare_local).init = init.ir;
    }
    return .{ .id = var_id, .ir_id = info.id };
}

pub fn reserveLocalName(c: *cy.Chunk, name: []const u8, declType: *cy.Type, hidden: bool, hasInit: bool, node: *ast.Node) anyerror!sema.LocalId {
    // Pending operands get their locals first. Later than this, a flush would declare a local in the middle of
    // this declaration, and its statement would come before this one with a later IR id.
    if (c.ir.seq_pending > 0) try sema_move.seqFlush(c);
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

fn declareLocalName(c: *cy.Chunk, name: []const u8, decl_t: *cy.Type, hidden: bool, hasInit: bool, node: *ast.Node) !sema.LocalId {
    const id = try reserveLocalName(c, name, decl_t, hidden, hasInit, node);
    const local = &c.varStack.items[id];
    try sema_expr.semaTraceNopFmt(c, "declare: {s} {}", .{name, id}, node);
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

pub fn declareLocal(c: *cy.Chunk, ident: *ast.Node, declType: *cy.Type, hasInit: bool) !sema.LocalId {
    const name = ident.cast(.ident).name.slice();
    return declareLocalName(c, name, declType, false, hasInit, ident);
}

pub fn localDecl(c: *cy.Chunk, node: *ast.VarDecl) !void {
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
    try sema_expr.semaTraceNopFmt(c, "declare: {s} {}", .{name, var_idx}, @ptrCast(node));

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
    svar.inner.local.init_node = node.right;

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
    if (node.name.type() == .void_lit) {
        try sema_call.checkDroppedSliceResult(c, right.type, node.right);
    }
    try sema_call.checkSliceInPlaceResult(c, right.type, node.right, null, true);

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

    right = try sema_move.semaOwn(c, right, node.right);
    if (!has_target_type) {
        var_t = right.type;
        c.varStack.items[var_idx].decl_t = right.type;
        declare.cast(.declare_local).decl_t = var_t;
        if (c.compiler.record_refs) cy.refs.recordLocalType(c, &c.varStack.items[var_idx]);
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
    if (c.compiler.record_refs) cy.refs.recordDeclaredLocal(c, node.name, if (has_target_type) null else var_t);
    // A borrow assigned to `_` can not be used again, so it ends with its statement (`_ = r.add(1)`, then `r.add(2)`).
    // A borrow container can have a destructor that reads the borrow when the block ends, so it is kept.
    if (node.name.type() != .void_lit or !sema_borrow.isBorrowLocal(c, @intCast(var_idx))) {
        try sema_borrow.checkBindBorrow(c, @intCast(var_idx), right, node.right);
        try sema_borrow.bindBorrowLocal(c, @intCast(var_idx), right);
    }
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
        try sema_stmt.check_locals(c, var_start, @ptrCast(node));
    }
}

/// REPL (`persist_main`): the last top level expression statement becomes the eval result (`CLEvalResult`).
/// The value moves into a hidden local that `@mainResult` reports to the VM, which copies it after the run
/// (`Compiler.main_res`). Mirrors `localDecl` with an inferred type. An expression without a value keeps the usual
/// expression statement rules. See `docs/decisions/project_repl_result.md`.
pub fn semaMainResultStmt(c: *cy.Chunk, node: *ast.Node) !void {
    c.curNode = node;
    c.cur_cont_expr = null;
    const child = node.cast(.exprStmt).child;

    // Reserved before the expression so that its temporaries are popped without it.
    const name = "_main_res";
    const var_idx = try reserveLocalName(c, name, c.sema.void_t, true, true, node);
    try sema_expr.semaTraceNopFmt(c, "declare: {s} {}", .{name, var_idx}, node);
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
    // `xs.removed(1)` on the last line is the eval result, not a dropped one: it shows the new list.
    var right = try c.semaExpr(child, .{ .assign_to_local = true });
    const no_value = right.type.id() == bt.Void or right.type.id() == bt.Never or right.type.kind() == .result or
        (right.resType == .ct_value and right.data.ct_value.type.id() == bt.Void);
    if (no_value) {
        // The hidden local stays a void local without an init.
        return sema_stmt.semaExprStmtEnd(c, right, var_start, child);
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
    right = try sema_move.semaOwn(c, right, child);

    svar = &c.varStack.items[var_idx];
    svar.decl_t = right.type;
    declare.cast(.declare_local).decl_t = right.type;
    if (c.compiler.record_refs) cy.refs.recordLocalType(c, svar);
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
        try sema_stmt.check_locals(c, var_start, node);
    }
}

/// `@mainResult(type_id, addr, borrowed)`: tells the VM where the eval result lives.
fn semaMainResult(c: *cy.Chunk, val_t: *cy.Type, stack_idx: u32, borrowed: bool, node: *ast.Node) !void {
    const type_id = try c.semaConst(val_t.id(), c.sema.i64_t, node);
    const local_ref = try sema_expr.semaLocal(c, stack_idx, node);
    const addr = try sema_expr.semaAddressOf(c, local_ref, c.sema.ptr_void_t, node);
    const borrowed_v = try c.semaConst(@intFromBool(borrowed), c.sema.bool_t, node);
    const args = [_]sema_func.Argument{
        sema_func.Argument.initPreResolved(node, type_id),
        sema_func.Argument.initPreResolved(node, addr),
        sema_func.Argument.initPreResolved(node, borrowed_v),
    };
    const call = try c.semaCallFunc2(c.sema.main_result_fn, &args, &.{}, node);
    _ = try declareHiddenLocal(c, "@res", c.sema.void_t, call, node);
}

pub fn semaTrackMainLocal(c: *cy.Chunk, local: *sema.Local, node: *ast.Node) !void {
    const name = try c.semaRawString(local.name(), node);
    const type_id = try c.semaConst(local.decl_t.id(), c.sema.i64_t, node);
    const local_ref = try sema_expr.semaLocal(c, local.stack_idx, node);
    const addr = try sema_expr.semaAddressOf(c, local_ref, c.sema.ptr_void_t, node);
    const args = [_]sema_func.Argument{
        sema_func.Argument.initPreResolved(node, name),
        sema_func.Argument.initPreResolved(node, type_id),
        sema_func.Argument.initPreResolved(node, addr),
    };
    const call = try c.semaCallFunc2(c.sema.track_main_local_fn, &args, &.{}, node);
    _ = try declareHiddenLocal(c, "@res", c.sema.void_t, call, node);
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
    sema_borrow.truncateBorrowLoans(self, proc.varStart);
    self.varStack.items.len = proc.varStart;
    self.active_field_stack.items.len = proc.active_field_start;
    return stmtBlock;
}

pub fn pushLambdaProc(c: *cy.Chunk, func: *cy.Func) !sema.ProcId {
    return pushFuncProc(c, func);
}

pub fn pushFuncProc(c: *cy.Chunk, func: *cy.Func) !sema.ProcId {
    const stmt = try c.ir.newStmt(.funcBlock, @ptrCast(func.decl), undefined);
    try c.ir.func_blocks.append(c.alloc, stmt);
    const id = try pushProc(c, func);
    c.proc().ir = stmt;
    return id;
}

pub fn pushProc(self: *cy.Chunk, func: ?*cy.Func) !sema.ProcId {
    // The locals of pending operands belong to the proc that the operands are in. A lambda argument starts
    // another proc before its statement block is pushed.
    if (self.ir.seq_pending > 0) try sema_move.seqFlush(self);
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

    const new = sema.Proc.init(node, func, @intCast(self.semaBlocks.items.len), isStaticFuncBlock, @intCast(self.varStack.items.len), @intCast(self.active_field_stack.items.len));
    const idx = self.semaProcs.items.len;
    try self.semaProcs.append(self.alloc, new);
    self.cur_sema_proc = &self.semaProcs.items[idx];

    _ = try pushBlock(self, node);
    return @intCast(idx);
}

pub fn sema_discard(c: *cy.Chunk, expr: sema.ExprResult, node: *ast.Node) !void {
    _ = try c.ir.pushStmt(.discard, node, .{ .expr = expr.ir });
}

fn sema_call_partial_destruct_local(c: *cy.Chunk, local: *sema.Local, node: *ast.Node) !void {
    const ptr_t = try sema.getPtrType(c, local.decl_t);
    const local_v = try sema_expr.semaLocal(c, local.stack_idx, node);
    const addr = try sema_expr.semaAddressOf(c, local_v, ptr_t, node);
    const fields = c.proc().var_active_struct_fields.get(local.stack_idx).?;
    const layout = try sema_access.ensure_partial_struct_layout(c, fields);
    const dtor = try sema.get_partial_dtor(c, local.decl_t, layout, node);
    const arg = Argument.initPreResolved(node, addr);
    const call = try c.semaCallFunc2(dtor, &.{arg}, &.{}, node);
    _ = try c.ir.pushStmt(.discard, node, .{ .expr = call.ir });
}

fn semaDestructLocalCall(c: *cy.Chunk, local: *sema.Local, node: *ast.Node) !void {
    const ptr_t = try sema.getPtrType(c, local.decl_t);
    const local_v = try sema_expr.semaLocal(c, local.stack_idx, node);
    const addr = try sema_expr.semaAddressOf(c, local_v, ptr_t, node);
    const dtor = try sema.getDtorFunc(c, local.decl_t, node);
    const arg = Argument.initPreResolved(node, addr);
    const call = try c.semaCallFunc2(dtor, &.{arg}, &.{}, node);
    _ = try c.ir.pushStmt(.discard, node, .{ .expr = call.ir });
}

fn semaReleaseLocal(c: *cy.Chunk, local: *sema.Local, optional: bool, type_: *cy.Type, node: *ast.Node) !void {
    const deinit_obj = try sema.getDeinitObjFunc(c, type_, node);

    try sema_expr.semaTraceNopFmt(c, "release: {s}", .{local.name()}, node);
    const stmt = try c.ir.pushStmt(.release, node, .{
        .reg = local.inner.local.id,
        .optional = optional,
        .deinit_obj = deinit_obj,
    });
    // The last release calls the object's destructor in this frame. A fiber can be cancelled inside its `@deinit`.
    // A destructor that runs no script code cannot suspend, so the release needs no site.
    if (sema_call.destructMayRunScript(c, type_, 0)) {
        try sema_call.semaCancelPad(c, @intFromPtr(stmt), node);
    }
}

/// `local` can be invalidated after this function returns.
pub fn semaDestructLocal(c: *cy.Chunk, local: *sema.Local, node: *ast.Node) !void {
    if (local.type != .local) {
        return;
    }
    const proc = c.proc();
    // A fiber cancelled inside this destructor must not destruct the local again.
    const saved_skip = c.cancel_pad_skip;
    const saved_skip_proc = c.cancel_pad_skip_proc;
    defer {
        c.cancel_pad_skip = saved_skip;
        c.cancel_pad_skip_proc = saved_skip_proc;
    }
    const items = c.varStack.items;
    if (@intFromPtr(local) >= @intFromPtr(items.ptr) and @intFromPtr(local) < @intFromPtr(items.ptr + items.len)) {
        c.cancel_pad_skip = local - items.ptr;
        c.cancel_pad_skip_proc = c.semaProcs.items.len;
    }

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

    try sema_expr.semaTraceNopFmt(c, "deinit: {s} {}", .{local.name(), local.stack_idx}, proc.node);

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

pub fn semaDestructBlock2(c: *cy.Chunk, b: *sema.Block) !void {
    return semaDestructBlock3(c, b, c.varStack.items.len);
}

/// Destructs the locals of `b` below `var_end`, from the youngest down.
pub fn semaDestructBlock3(c: *cy.Chunk, b: *sema.Block, var_end: usize) !void {
    const saved_end = c.cancel_pad_var_end;
    const saved_proc = c.cancel_pad_var_proc;
    defer {
        c.cancel_pad_var_end = saved_end;
        c.cancel_pad_var_proc = saved_proc;
    }
    const skip: ?usize = if (c.cancel_pad_skip_proc == c.semaProcs.items.len) c.cancel_pad_skip else null;
    var i: usize = var_end;
    while (i > b.varStart) {
        i -= 1;
        if (skip == i) continue;
        // A fiber that is cancelled inside this destructor must not destruct the local again (F-106).
        c.cancel_pad_var_end = i;
        c.cancel_pad_var_proc = c.semaProcs.items.len;
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
            sema_borrow.unbindBorrowLocal(c, decl);
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
    const new = sema.Block.init(
        node,
        c.varStack.items.len,
        c.varShadowStack.items.len,
    );

    var new_ = new;
    new_.moves_start = @intCast(c.branch_moves.items.len);
    const idx = c.semaBlocks.items.len;
    try c.semaBlocks.append(c.alloc, new_);
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

/// The parameters of a method that a type got from a default method of `trait_t`. The declaration is the
/// trait's, so it has no receiver parameter. The receiver `&T` is a hidden parameter, and `self` is a local that
/// views it as `&Dyn[Trait]`: the body can call the methods of the trait and nothing else of the type.
fn pushDefaultMethodParamVars(c: *cy.Chunk, rec_t: *cy.Type, func: *const cy.Func, trait_t: *cy.types.GenericTrait) !void {
    const curNode = c.curNode;
    defer c.curNode = curNode;

    const node: *ast.Node = func.decl.?;
    const params = func.sig.params();
    const param_decls = node.cast(.funcDecl).params.slice();

    const proc = c.proc();
    try checkLocalLimit(c, 0, node);
    const rec_id = try pushLocalVar(c, .local, "$self", rec_t, true);
    c.varStack.items[rec_id].inner = .{
        .local = .{
            .id = 0,
            .isParam = true,
            .hasInit = false,
            .declIrStart = undefined,
            .hidden = true,
        },
    };
    proc.numParams += 1;

    var rt_param_idx: usize = 1;
    for (param_decls) |param_decl| {
        try declareParam(c, param_decl, false, rt_param_idx, params[rt_param_idx].get_type());
        rt_param_idx += 1;
    }

    const dyn_sym = c.compiler.builtins_chunk.sym.getMod().getSym("Dyn").?;
    const dyn_t = (try cy.template.expand_template(c, dyn_sym.cast(.template), &.{c.sema.type_t}, &.{cy.Value.initType(&trait_t.base)})).getStaticType().?;
    const self_t = try sema.getBorrowType(c, dyn_t);
    try sema_type.checkDynReceivers(c, rec_t.cast(.borrow).child_t, trait_t, node);
    const rec = try sema_expr.semaLocal(c, rec_id, node);
    const loc = try c.ir.newExpr(.trait, self_t, node, .{
        .ref = rec.ir,
        .impl_t = rec_t.cast(.borrow).child_t,
        .trait_t = self_t,
        .generic_t = trait_t,
    });
    _ = try declareLocalInit(c, "self", self_t, sema.ExprResult.init(loc, self_t), node);
}

pub fn appendFuncParamVars(c: *cy.Chunk, ast_params: []const *ast.FuncParam, params: []const sema.FuncParam) !void {
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

fn pushLocalVar(c: *cy.Chunk, _type: sema.LocalVarType, name: []const u8, declType: *cy.Type, hidden: bool) !sema.LocalId {
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
    if (c.compiler.record_refs and !hidden) {
        cy.refs.recordLocalDecl(c, name, declType);
    }
    if (c.moved_sites.count() > 0) _ = c.moved_sites.remove(id);
    try c.varStack.append(c.alloc, .{
        .decl_t = declType,
        .lifetime = sema.Lifetime.initBlock(@intCast(proc.block_depth)),
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

fn getVarPtr(self: *cy.Chunk, name: []const u8) ?*sema.Local {
    if (self.proc().var_cache_entries.get(name)) |varId| {
        return &self.vars.items[varId];
    } else return null;
}

fn pushCapturedVar(c: *cy.Chunk, name: []const u8, parentVarId: sema.LocalId) !u32 {
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

pub fn lookupSelfExpr(c: *cy.Chunk, node: *ast.Node) !sema.ExprResult {
    const self = (try lookupSelf(c, node)) orelse {
        return c.reportErrorFmt("Can only infer `self` from a method body.", &.{}, node);
    };
    if (self.capture) {
        const capture = try sema_expr.semaCaptured(c, self.id, node);
        return sema_move.semaOwn(c, capture, node);
    } else {
        return sema_expr.semaLocal(c, self.id, node);
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
            return self.reportErrorFmt(captureHintFmt(self), &.{v("self")}, node);
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
    ct_var: *sema_resolve.CtParam,

    capture: u32,

    /// Local, parent local alias, or parent object member alias.
    local: sema.LocalId,
};

/// Static var lookup is skipped for callExpr since there is a chance it can fail on a
/// symbol with overloaded signatures.
pub fn lookupIdent(self: *cy.Chunk, name: []const u8, node: *ast.Node) !LookupIdentResult {
    const res = try lookupIdent2(self, name, node);
    if (self.compiler.record_refs) {
        switch (res) {
            .local => |id| {
                const local = &self.varStack.items[id];
                cy.refs.recordLocalUse(self, node, local.decl_t, local.namePtr[0..local.nameLen]);
            },
            .capture => |idx| {
                // A use in a lambda is a use of the local that it captures.
                const parent_id = self.proc().captures.items[idx].parent_var_idx;
                const local = &self.varStack.items[parent_id];
                cy.refs.recordLocalUse(self, node, local.decl_t, local.namePtr[0..local.nameLen]);
            },
            .static => |sym| cy.refs.recordSym(self, node, name, sym),
            else => {},
        }
    }
    return res;
}

/// `endBorrowsAfter` found no statement after this one that names the local. Reaching it is a compiler bug.
fn reportBorrowEnded(c: *cy.Chunk, name: []const u8, node: *ast.Node) anyerror {
    return c.reportErrorFmt("Internal error: the borrow of `{}` was ended before this use.", &.{v(name)}, node);
}

fn lookupIdent2(self: *cy.Chunk, name: []const u8, node: *ast.Node) !LookupIdentResult {
    if (self.semaProcs.items.len == 0) {
        return (try lookupStaticIdent2(self, name, node)) orelse {
            return self.reportErrorFmt("Could not find the symbol `{}`.", &.{v(name)}, node);
        };
    }

    const proc = self.proc();
    // A struct field's default value sees the names of the struct's module, not the locals of the code that
    // writes the literal. A lambda in the default value still sees its own locals.
    const hidden_depth = if (self.hide_locals_below) |below| self.semaProcs.items.len -| below else std.math.maxInt(usize);
    if (hidden_depth == 0) {
        return lookupStaticIdentOrFail(self, name, node);
    }
    if (proc.var_cache_entries.get(name)) |varInfo| {
        switch (varInfo.type) {
            .local => {
                const data = varInfo.data.local;
                if (self.varStack.items[data.varId].borrow_ended) return reportBorrowEnded(self, name, node);
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

    if (if (hidden_depth > 1) try lookupParentLocal(self, name, node) else null) |res| {
        if (proc.isStaticFuncBlock) {
            // Can not capture local before static function block.
            const funcName = proc.func.?.name();
            return self.reportErrorFmt("Can not capture the local variable `{}` from static function `{}`.\nOnly lambdas (anonymous functions) can capture local variables.", &.{v(name), v(funcName)}, self.curNode);
        }

        // TODO: Capture non-reference stack variables too.
        const decl_t = self.varStack.items[res.varId].decl_t;
        if (!decl_t.isObjectLike() and decl_t.kind() != .borrow) {
            return self.reportErrorFmt(captureHintFmt(self), &.{v(name)}, node);
        }

        // Create a local captured variable.
        const id = try pushCapturedVar(self, name, res.varId);
        return LookupIdentResult{
            .capture = id,
        };
    }

    if (try lookupStaticIdent2(self, name, node)) |res| {
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
    if (self.assign_left == node) {
        return self.reportErrorFmt("Undeclared variable `{}`. To declare a new variable, write `{} := ...`.", &.{v(name), v(name)}, node);
    }
    return self.reportErrorFmt("Undeclared variable `{}`.", &.{v(name)}, node);
}

pub fn lookupStaticIdent(c: *cy.Chunk, name: []const u8, node: *ast.Node) !?LookupIdentResult {
    const res = try lookupStaticIdent2(c, name, node);
    if (c.compiler.record_refs) {
        if (res) |found| {
            if (found == .static) cy.refs.recordSym(c, node, name, found.static);
        }
    }
    return res;
}

fn lookupStaticIdentOrFail(c: *cy.Chunk, name: []const u8, node: *ast.Node) !LookupIdentResult {
    return (try lookupStaticIdent2(c, name, node)) orelse {
        return c.reportErrorFmt("Undeclared variable `{}`.", &.{v(name)}, node);
    };
}

fn lookupStaticIdent2(c: *cy.Chunk, name: []const u8, node: *ast.Node) !?LookupIdentResult {
    const res = (try sema_resolve.getResolvedName(c, name, node)) orelse {
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
    varId: sema.LocalId,
    blockIdx: u32,
};

/// The message for a lambda that captures a local that is not a reference. With `persist_main` a top level
/// borrow can not be kept across evals, so the borrow is only suggested for a function there.
fn captureHintFmt(c: *cy.Chunk) []const u8 {
    if (c.vm.config.persist_main and c.semaProcs.items.len >= 2 and c.semaProcs.items[c.semaProcs.items.len - 2].func == null) {
        return "Can only capture variables declared with the reference types `^T` or `&T`. Declare it with `^T`. Inside a function, you can also borrow it before the lambda (`b := &{}`) and use `b` in the lambda.";
    }
    return "Can only capture variables declared with the reference types `^T` or `&T`. Declare it with `^T`, or borrow it before the lambda (`b := &{}`) and use `b` in the lambda.";
}

fn lookupParentLocal(c: *cy.Chunk, name: []const u8, node: *ast.Node) !?LookupParentLocalResult {
    // Only check one block above.
    if (c.semaBlockDepth() > 1) {
        const prev = c.semaProcs.items[c.semaProcs.items.len - 2];
        if (prev.var_cache_entries.get(name)) |varInfo| {
            switch (varInfo.type) {
                .local => {
                    const data = varInfo.data.local;
                    const svar = c.varStack.items[data.varId];
                    if (svar.borrow_ended) return reportBorrowEnded(c, name, node);
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

const VarResult = struct {
    id: sema.LocalId,
    fromParentBlock: bool,
};

/// A pinned closure keeps its captured values without a reference (`Heap.allocClosure`), so the result borrows from
/// the captured local that goes out of scope first (`shorterOwner`).
pub fn popLambdaProc(c: *cy.Chunk) !sema.ExprResult {
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
    var owner: ?sema.LocalId = null;
    if (captures.len > 0) {
        captures_data = try c.ir.allocArray(u8, captures.len);
        for (captures, 0..) |info, i| {
            const pId = info.parent_var_idx;
            const pvar = c.varStack.items[pId];
            captures_data[i] = pvar.inner.local.id;
            if (!info.val_t.isRefPointer()) {
                captures_scope_locals = true;
            }
            try sema_borrow.noteBorrowLocal(c, pId);
            owner = sema_borrow.shorterOwner(c, owner, sema_borrow.borrowOwnerOf(c, pId));
        }
        c.alloc.free(captures);
        const funcptr_t = try sema.getFuncPtrType(c, proc.func.?.sig);
        if (captures_scope_locals) {
            type_ = try sema.getOpaqueFuncType(c, funcptr_t);
        } else {
            type_ = try sema.getFuncType(c, funcptr_t);
        }
    } else {
        type_ = try sema.getFuncPtrType(c, proc.func.?.sig);
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
    const expr = try c.ir.newExpr(.lambda, type_, proc.node, .{
        .func = proc.func.?,
        .numCaptures = @as(u8, @intCast(captures.len)),
        .captures = captures_data.ptr,
        .pinned_closure = captures_scope_locals,
    });
    var res = sema.ExprResult.initOwned(expr);
    if (captures_scope_locals) {
        res.data.value.parent_local = owner;
    }
    return res;
}

/// What a lambda adds to the chunk while it is checked, taken before `Chunk.addUserLambda` for `dropLambdaProc`.
pub const LambdaMark = struct {
    funcs: usize,
    func_blocks: usize,
    ref_lens: [4]usize,

    pub fn take(c: *cy.Chunk) LambdaMark {
        return .{
            .funcs = c.funcs.items.len,
            .func_blocks = c.ir.func_blocks.items.len,
            .ref_lens = c.compiler.refLens(),
        };
    }
};

/// Drops the lambda that was being checked instead of `popLambdaProc`: no code is generated for it or for a
/// lambda inside it. The `Func` of each of them leaves `Chunk.funcs` for `Chunk.dropped_funcs`, so that code
/// generation, the global initializer check and the symbol info do not see a function without a body.
/// A function that a template expanded to for the body stays: it is an instance of its template.
/// The symbol info that the body recorded (`refs.zig`) is dropped too: the body is checked again for the
/// next overload, or once more to report its error.
pub fn dropLambdaProc(c: *cy.Chunk, mark: LambdaMark) !void {
    _ = try popProc(c);
    c.ir.func_blocks.items.len = mark.func_blocks;

    try c.dropped_funcs.ensureUnusedCapacity(c.alloc, c.funcs.items.len - mark.funcs);
    var kept = mark.funcs;
    for (c.funcs.items[mark.funcs..]) |func| {
        if (func.type == .userLambda) {
            c.dropped_funcs.appendAssumeCapacity(func);
        } else {
            c.funcs.items[kept] = func;
            kept += 1;
        }
    }
    c.funcs.items.len = kept;

    c.compiler.truncateRefs(mark.ref_lens);
}

/// Whether the block of the current function reaches its end without a `return` that its return type needs
/// (`procPrologue` reports 'Missing return statement.').
pub fn missingReturn(c: *cy.Chunk) bool {
    const proc = c.proc();
    if (!c.block().endReachable) return false;
    if (proc.func != null and proc.func.?.info.generator) return false;
    const ret_t = proc.getReturnType(c.sema);
    return !(ret_t.id() == bt.Void or (ret_t.kind() == .result and ret_t.cast(.result).child_t.id() == bt.Void));
}

pub fn procPrologue(c: *cy.Chunk) !void {
    const proc = c.proc();

    if (c.block().endReachable) {
        if (proc.func != null and proc.func.?.info.generator) {
            try sema_stmt.semaGeneratorEnd(c, proc.node);
        } else {
            const ret_t = proc.getReturnType(c.sema);
            if (ret_t.id() == bt.Void or (ret_t.kind() == .result and ret_t.cast(.result).child_t.id() == bt.Void)) {
                _ = try sema_stmt.semaReturn(c, proc.node);
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
    func.info.body_failed = false;

    if (func.type == .userFunc) {
        func.data.userFunc.loc = proc.ir;
    } else if (func.type == .extern_) {
        func.data.extern_.ir = proc.ir.cast(.funcBlock);
    } else {
        @panic("unexpected");
    }
}
