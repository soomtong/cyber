const std = @import("std");
const stdx = @import("stdx");
const cy = @import("cyber.zig");
const ir = cy.ir;
const bt = cy.types.BuiltinTypes;
const sema_func = cy.sema_func;
const sema_type = cy.sema_type;
const ct_inline = cy.ct_inline;
const Argument = cy.sema_func.Argument;
const cte = cy.cte;
const fmt = cy.fmt;
const v = fmt.v;
const ast = cy.ast;
const TypeId = cy.types.TypeId;
const Sym = cy.Sym;
const TypeValue = cy.TypeValue;
const log = cy.log.scoped(.sema);
const sema = cy.sema;
const sema_stmt = cy.sema_stmt;
const sema_local = cy.sema_local;
const sema_borrow = cy.sema_borrow;
const sema_call = cy.sema_call;
const sema_hint = cy.sema_hint;
const sema_access = cy.sema_access;
const sema_resolve = cy.sema_resolve;
const sema_switch = cy.sema_switch;
const sema_move = cy.sema_move;
const sema_init = cy.sema_init;
const sema_lit = cy.sema_lit;

/// An operand of `and` or `or` is a `bool`. An option gets a note: `if ok and s.index(x) |i|:` unwraps the whole
/// condition, so the `|i|` does not reach the operand.
fn semaLogicOperand(c: *cy.Chunk, node: *ast.Node) !sema.ExprResult {
    const res = try c.semaExprTarget(node, c.sema.bool_t);
    if (res.type.id() == bt.Bool or res.type.id() == bt.Never) return res;
    if (res.type.kind() == .option) {
        const type_name = try c.sema.allocTypeName(res.type);
        defer c.alloc.free(type_name);
        return c.reportErrorFmt("Expected type `bool`, got `{}`. An operand of `and` and `or` is not unwrapped: `|v|` applies to the whole condition of the `if`. Unwrap the option in an `if` of its own inside this one: `if x |v|:`, or compare it with `none`.", &.{v(type_name)}, node);
    }
    return sema_lit.reportExpectedType(c, c.sema.bool_t, res.type, node);
}

fn semaLogicOr(c: *cy.Chunk, left: *ast.Node, right: *ast.Node, node: *ast.Node) !sema.ExprResult {
    const res_local = try sema_local.declareHiddenLocal(c, "_temp", c.sema.bool_t, null, node);

    const outer = try sema_local.pushBlock(c, node);
    {
        // The left operand always runs: a move in it is a move in the block around the expression (`moveBlock`).
        c.block().move_branch = .if_cond;
        const cond = try semaLogicOperand(c, left);
        c.semaBlocks.items[outer].move_branch = .none;

        _ = try sema_local.pushBlock(c, left);
        {
            const true_value = try sema_lit.semaTrue(c, left);
            _ = try c.ir.pushStmt(.set_local, left, .{
                .id = @intCast(res_local.ir_id),
                .right = true_value.ir,
            });
            try sema_stmt.semaBreakTo(c, outer, left);
        }
        const block = try sema_local.popBlock2(c, false);
        _ = try c.ir.pushStmt(.if_block, left, .{
            .cond_expr = cond.ir,
            .body_head = block.first,
        });

        const right_value = try semaLogicOperand(c, right);
        _ = try c.ir.pushStmt(.set_local, right, .{
            .id = @intCast(res_local.ir_id),
            .right = right_value.ir,
        });
    }
    const block = try sema_local.popBlock(c);
    _ = try c.ir.pushStmt(.block, @ptrCast(node), .{ .bodyHead = block.first });

    const res = (try semaLocal(c, res_local.id, node)).ir;
    c.varStack.items[res_local.id].type = .dead;
    return sema.ExprResult.init2(res);
}

fn semaLogicAnd(c: *cy.Chunk, left: *ast.Node, right: *ast.Node, node: *ast.Node) !sema.ExprResult {
    const res_local = try sema_local.declareHiddenLocal(c, "_temp", c.sema.bool_t, null, node);

    const outer = try sema_local.pushBlock(c, node);
    {
        // The left operand always runs: a move in it is a move in the block around the expression (`moveBlock`).
        c.block().move_branch = .if_cond;
        var cond = try semaLogicOperand(c, left);
        c.semaBlocks.items[outer].move_branch = .none;
        const expr = try c.ir.newExpr(.unary_op, c.sema.bool_t, left, .{
            .childT = c.sema.bool_t, .op = .lnot, .expr = cond.ir,
        });
        cond = sema.ExprResult.init2(expr);

        _ = try sema_local.pushBlock(c, left);
        {
            const false_value = try sema_lit.semaFalse(c, left);
            _ = try c.ir.pushStmt(.set_local, left, .{
                .id = @intCast(res_local.ir_id),
                .right = false_value.ir,
            });
            try sema_stmt.semaBreakTo(c, outer, left);
        }
        const block = try sema_local.popBlock2(c, false);
        _ = try c.ir.pushStmt(.if_block, left, .{
            .cond_expr = cond.ir,
            .body_head = block.first,
        });

        const right_value = try semaLogicOperand(c, right);
        _ = try c.ir.pushStmt(.set_local, right, .{
            .id = @intCast(res_local.ir_id),
            .right = right_value.ir,
        });
    }
    const block = try sema_local.popBlock(c);
    _ = try c.ir.pushStmt(.block, @ptrCast(node), .{ .bodyHead = block.first });

    const res = (try semaLocal(c, res_local.id, node)).ir;
    c.varStack.items[res_local.id].type = .dead;
    return sema.ExprResult.init2(res);
}

pub fn semaLogicAnd2(c: *cy.Chunk, left: *ast.Node, left_value: sema.ExprResult, right: *ast.Node, right_value: sema.ExprResult, node: *ast.Node) !sema.ExprResult {
    const res_local = try sema_local.declareHiddenLocal(c, "_temp", c.sema.bool_t, null, node);

    const outer = try sema_local.pushBlock(c, node);
    {
        var cond = left_value;
        const expr = try c.ir.newExpr(.unary_op, c.sema.bool_t, left, .{
            .childT = c.sema.bool_t, .op = .lnot, .expr = left_value.ir,
        });
        cond = sema.ExprResult.init2(expr);

        _ = try sema_local.pushBlock(c, left);
        {
            const false_value = try sema_lit.semaFalse(c, left);
            _ = try c.ir.pushStmt(.set_local, left, .{
                .id = @intCast(res_local.ir_id),
                .right = false_value.ir,
            });
            try sema_stmt.semaBreakTo(c, outer, left);
        }
        const block = try sema_local.popBlock2(c, false);
        _ = try c.ir.pushStmt(.if_block, left, .{
            .cond_expr = cond.ir,
            .body_head = block.first,
        });

        _ = try c.ir.pushStmt(.set_local, right, .{
            .id = @intCast(res_local.ir_id),
            .right = right_value.ir,
        });
    }
    const block = try sema_local.popBlock(c);
    _ = try c.ir.pushStmt(.block, @ptrCast(node), .{ .bodyHead = block.first });

    const res = (try semaLocal(c, res_local.id, node)).ir;
    c.varStack.items[res_local.id].type = .dead;
    return sema.ExprResult.init2(res);
}

pub fn symbol(c: *cy.Chunk, sym: *Sym, prefer_ct_sym: bool, node: *ast.Node) !sema.ExprResult {
    return symbol2(c, sym, prefer_ct_sym, null, node);
}

pub fn symbol2(c: *cy.Chunk, sym: *Sym, prefer_ct_sym: bool, opt_target: ?*cy.Type, node: *ast.Node) !sema.ExprResult {
    try sema_local.referenceSym(c, sym, node);
    switch (sym.type) {
        .const_ => {
            const const_ = sym.cast(.const_);
            const src_chunk = c.compiler.chunks.items[const_.head.declNode().src()];
            try sema_resolve.resolveConst(src_chunk, const_);

            // Use cached IR when target type matches or inferring from value.
            if (const_.ir) |expr| {
                if (opt_target) |target_t| {
                    if (target_t.id() == const_.type.id()) {
                        var const_res = sema.ExprResult.initCustom(expr, .const_, const_.type, .{ .const_ = sym });
                        const_res.owned = true;
                        return const_res;
                    }
                } else {
                    var const_res = sema.ExprResult.initCustom(expr, .const_, const_.type, .{ .const_ = sym });
                    const_res.owned = true;
                    return const_res;
                }
            }
            const res = try ct_inline.value(c, cy.TypeValue.init(const_.type, const_.value), opt_target, node);
            var const_res = sema.ExprResult.initCustom(res.ir, .const_, res.type, .{ .const_ = sym });
            const_res.owned = true;
            return const_res;
        },
        .userVar => {
            // In a global initializer this is allowed for a global that is initialized earlier.
            // `global_init.check` reports the others.
            const user_var = sym.cast(.userVar);
            try cy.global_init.recordGlobal(c, user_var);
            const src_chunk = c.compiler.chunks.items[user_var.head.declNode().src()];
            try sema_resolve.resolveUserVar(src_chunk, user_var, );
            const loc = try c.ir.newExpr(.global, user_var.type, node, .{ .sym = sym });
            var res = sema.ExprResult.initCustom(loc, .varSym, user_var.type, .{ .varSym = sym });
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
            var res = sema.ExprResult.initCustom(expr, .varSym, extern_var.type, .{ .varSym = sym });
            res.addressable = true;
            return res;
        },
        .hostVar => {
            // The host binds its globals when the module loads, before any initializer runs.
            const host_var = sym.cast(.hostVar);
            const loc = try c.ir.newExpr(.global, host_var.type, node, .{ .sym = sym });
            var res = sema.ExprResult.initCustom(loc, .varSym, host_var.type, .{ .varSym = sym });
            res.addressable = true;
            return res;
        },
        .func => {
            // `symbol` being invoked suggests the func sym is not ambiguous.
            const func = sym.cast(.func);
            if (func.numFuncs != 1) {
                if (prefer_ct_sym) {
                    return sema.ExprResult.initCustom(undefined, .sym, c.sema.void_t, .{ .sym = sym });
                }
                return c.reportError("AmbiguousSymbol", node);
            }
            return sema_call.sema_func_sym(c, func.first, prefer_ct_sym, opt_target, node);
        },
        .type => {
            if (prefer_ct_sym) {
                const sym_t = sym.getStaticType().?;
                return sema.ExprResult.initCustom(undefined, .sym, sym_t, .{ .sym = sym });
            }
            return c.reportError("Compile-time symbol cannot be used here. Consider expanding with `#{expr}` or using it in a compile-time context.", node);
        },
        .union_case => {
            const case = sym.cast(.union_case);
            if (case.payload_t.id() != bt.Void) {
                if (prefer_ct_sym) {
                    return sema.ExprResult.initCustom(undefined, .sym, c.sema.void_t, .{ .sym = sym });
                }
                return c.reportError("Must initialize cunion case with payload.", node);
            }
            return sema_init.semaInitCunionNoPayload(c, case.type, case.idx, node);
        },
        .choice_case => {
            const case = sym.cast(.choice_case);
            if (case.payload_t.id() != bt.Void) {
                if (prefer_ct_sym) {
                    return sema.ExprResult.initCustom(undefined, .sym, c.sema.void_t, .{ .sym = sym });
                }
                return c.reportError("Must initialize choice case with payload.", node);
            }
            return sema_init.semaInitChoiceNoPayload(c, case, node);
        },
        .enum_case => {
            const case = sym.cast(.enum_case);
            return c.semaConst(case.val, case.type, node);
        },
        .chunk,
        .func_template,
        .template => {
            if (prefer_ct_sym) {
                return sema.ExprResult.initCustom(undefined, .sym, c.sema.void_t, .{ .sym = sym });
            }
        },
        .use_alias => {
            const alias = sym.cast(.use_alias);
            if (!alias.resolved) {
                try sema_resolve.resolveUseAlias(c, alias);
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

pub fn semaLocal(c: *cy.Chunk, id: sema.LocalId, node: *ast.Node) !sema.ExprResult {
    const local = &c.varStack.items[id];
    switch (local.type) {
        .local => {
            const expr = try c.ir.newExpr(.local, local.decl_t, node, .{ .id = local.inner.local.id });
            var res = sema.ExprResult.initLocal(expr, local.stack_idx);
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
            if (c.assign_left == node and c.moved_sites.contains(id) and !local.inner.local.hidden) {
                // The left side of `x = y`: the assignment gives a moved local a value again (`semaAssignStmt`).
                const expr = try c.ir.newExpr(.local, local.decl_t, node, .{ .id = local.inner.local.id });
                var res = sema.ExprResult.initLocal(expr, local.stack_idx);
                res.addressable = true;
                return res;
            }
            if (c.moved_sites.get(id)) |site| {
                const ast_ = c.compiler.chunks.items[site.src()].ast;
                var line: u32 = undefined;
                var col: u32 = undefined;
                var line_start: u32 = undefined;
                ast_.computeLinePos(site.pos(), &line, &col, &line_start);
                return c.reportErrorFmt("`{}` was moved at {}:{}. Borrow it with `&{}` or clone it to use it here.", &.{v(local.name()), v(line + 1), v(col + 1), v(local.name())}, node);
            }
            return c.reportErrorFmt("`{}` is no longer alive in this scope.", &.{v(local.name())}, node);
        },
    }
}

pub fn semaCaptured(c: *cy.Chunk, idx: usize, node: *ast.Node) !sema.ExprResult {
    const info = &c.proc().captures.items[idx];
    const loc = try c.ir.newExpr(.captured, info.val_t, node, .{ .idx = @intCast(idx) });
    var res = sema.ExprResult.initCustom(loc, .capturedLocal, info.val_t, undefined);
    res.addressable = true;
    return res;
}

fn semaIdent(c: *cy.Chunk, cstr: sema.Cstr, prefer_ct_sym: bool, node: *ast.Node) !sema.ExprResult {
    const name = node.cast(.ident).name.slice();
    return semaIdent2(c, cstr, prefer_ct_sym, name, node);
}

fn semaIdent2(c: *cy.Chunk, cstr: sema.Cstr, prefer_ct_sym: bool, name: []const u8, node: *ast.Node) !sema.ExprResult {
    const res = try sema_local.lookupIdent(c, name, node);
    switch (res) {
        .local => |id| {
            return semaLocal(c, id, node);
        },
        .capture => |idx| {
            return semaCaptured(c, idx, node);
        },
        .static => |sym| {
            return symbol2(c, sym, prefer_ct_sym, cstr.target_t, node);
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

pub fn semaArray(c: *cy.Chunk, array_t: *cy.Type, args: []*ir.Expr, node: *ast.Node) !sema.ExprResult {
    const init_elems = (try c.getResolvedSym(@ptrCast(array_t.sym()), "@init_sequence", node)).?;
    return sema_init.sema_init_seq2(c, init_elems, args, node);
}

pub fn semaStringTemplate(c: *cy.Chunk, template: *ast.StringTemplate) !sema.ExprResult {
    const nexprs = template.parts.len / 2;

    const str_span_t = try sema.get_span_type(c, c.sema.str_t);
    const str_borrow_t = try sema.getBorrowType(c, c.sema.str_t);

    // strs as [&]str
    const nstrs = nexprs+1;
    const strs_loc = try c.ir.allocArray(*ir.Expr, nstrs);
    for (0..nexprs+1) |i| {
        const str_n = template.parts[i*2];
        const str = str_n.cast(.stringt_part).value.slice();
        const str_res = try c.semaString(str, str_n);
        strs_loc[i] = str_res.ir;
    }
    const str_vec_t = try sema.getVectorType(c, c.sema.str_t, @intCast(nstrs));
    const strs_init = try semaVector(c, str_vec_t, strs_loc, @ptrCast(template));
    const strs_local = try sema_local.declareHiddenLocal(c, "_strs_vec", str_vec_t, strs_init, @ptrCast(template));
    const strs = try semaLocal(c, strs_local.id, @ptrCast(template));
    const str_base = try semaAddressOf(c, strs, str_borrow_t, @ptrCast(template));
    const str_span = try sema_init.sema_span(c, str_span_t, str_base, @intCast(nstrs), @ptrCast(template));

    // exprs as [&]str
    const exprs_loc = try c.ir.allocArray(*ir.Expr, nexprs);
    const seq_tmpl_start = c.seq_pending.items.len;
    errdefer sema_move.seqPop(c, seq_tmpl_start);
    for (0..nexprs) |i| {
        const expr = template.parts[1 + i*2].cast(.stringt_expr);
        const res = try c.semaExpr(expr.child, .{});
        if (res.type.kind() == .result and !sema_hint.inGenericCode(c)) {
            const type_name = try c.sema.allocTypeName(res.type);
            defer c.alloc.free(type_name);
            return c.reportErrorFmt("Can not print `{}`. Unwrap it with `!` first, or handle the error with `!else` or `try`.", &.{v(type_name)}, expr.child);
        }

        const to_print_string_func = try sema.getToPrintStringFunc(c, res.type, expr.child);
        const expr_arg = Argument.initPreResolved(expr.child, res);
        const expr_str = try c.semaCallFunc2(to_print_string_func, &.{expr_arg}, &.{}, expr.child);
        exprs_loc[i] = expr_str.ir;
        try sema_move.seqPush(c, &exprs_loc[i], expr_str.owned, expr.child);
    }
    sema_move.seqPop(c, seq_tmpl_start);
    const expr_vec_t = try sema.getVectorType(c, c.sema.str_t, @intCast(nexprs));
    const exprs_init = try semaVector(c, expr_vec_t, exprs_loc, @ptrCast(template));
    const exprs_local = try sema_local.declareHiddenLocal(c, "_exprs_vec", expr_vec_t, exprs_init, @ptrCast(template));
    const exprs = try semaLocal(c, exprs_local.id, @ptrCast(template));
    const expr_base = try semaAddressOf(c, exprs, str_borrow_t, @ptrCast(template));
    const expr_span = try sema_init.sema_span(c, str_span_t, expr_base, @intCast(nexprs), @ptrCast(template));

    const sym = c.sema.str_t.sym().getMod().getSym("interpolate").?;
    const func_sym = try sema_call.requireFuncSym(c, sym, @ptrCast(template));
    return c.semaCallFuncSym2(func_sym, @ptrCast(template), str_span, @ptrCast(template), expr_span, @ptrCast(template));
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
            if (ctype == bt.Void) try sema_call.checkSliceInPlaceAssign(c, node);
            const cstrName = try c.sema.allocTypeName(reportCstrTypeId);
            defer c.alloc.free(cstrName);
            const typeName = try c.sema.allocTypeName(ctype);
            defer c.alloc.free(typeName);
            return c.reportErrorFmt("Expected type `{}`, got `{}`.", &.{v(cstrName), v(typeName)}, node);
        }
    }
}

fn pushExprRes(c: *cy.Chunk, res: sema.ExprResult) !void {
    try c.exprResStack.append(c.alloc, res);
}

pub fn semaMadd(c: *cy.Chunk, base: sema.ExprResult, scale: i64, mul: sema.ExprResult, node: *ast.Node) !sema.ExprResult {
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

pub fn semaAddressOf(c: *cy.Chunk, child: sema.ExprResult, ptr_t: *cy.Type, node: *ast.Node) !sema.ExprResult {
    const expr = try c.ir.newExpr(.address_of, ptr_t, node, .{
        .expr = child.ir,
    });
    var res = sema.ExprResult.init2(expr);
    res.data.value.parent_local = child.recParentLocal();
    return res;
}

pub fn sema_bitcast_nocheck(c: *cy.Chunk, expr: sema.ExprResult, target_t: *cy.Type, node: *ast.Node) !sema.ExprResult {
    const res = try c.ir.newExpr(.bitcast, target_t, node, .{
        .expr = expr.ir,
    });
    return sema.ExprResult.init2(res);
}

pub fn semaBitcast(c: *cy.Chunk, expr: sema.ExprResult, target_t: *cy.Type, node: *ast.Node) !sema.ExprResult {
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

pub fn semaDeref(c: *cy.Chunk, ptr: sema.ExprResult, node: *ast.Node) !sema.ExprResult {
    const child_t = ptr.type.getRefLikeChild().?;
    const deref = try c.ir.newExpr(.deref, child_t, node, .{
        .expr = ptr.ir,
    });
    const parent_local = ptr.recParentLocal();
    var res = sema.ExprResult.init2(deref);
    res.data.value.parent_local = parent_local;
    // A dereference is always addressable: its address is the pointer value itself.
    // Taking `ptr.addressable` made `*(as[Ptr[T]] p)[i]` copy the element into a hidden
    // temp (no retain), return the temp's address and then destruct the temp.
    res.addressable = true;
    return res;
}

pub fn reportNoCopy(c: *cy.Chunk, type_: *cy.Type, node: *ast.Node) anyerror {
    const name = try c.sema.allocTypeName(type_);
    defer c.alloc.free(name);

    const no_copy = c.sema.types.items[bt.NoCopy].cast(.generic_trait);
    if (try sema_type.implements(c, type_, no_copy, node)) {
        return c.reportErrorFmt("Cannot copy `{}`, type implements `NoCopy`.", &.{v(name)}, node);
    } else {
        return c.reportErrorFmt("Cannot copy `{}`, type member implements `NoCopy`.", &.{v(name)}, node);
    }
}

pub fn sema_copy(c: *cy.Chunk, expr: sema.ExprResult, node: *ast.Node) anyerror!sema.ExprResult {
    try sema_access.checkPartialMoveWhole(c, expr, "copy", node);
    if (expr.type.info.no_copy) {
        return reportNoCopy(c, expr.type, node);
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
                        return sema.ExprResult.initOwned(loc);
                    }
                },
                .func => {
                    if (!expr.type.info.copy_user) {
                        const loc = try c.ir.newExpr(.retain, expr.type, node, .{
                            .expr = expr.ir,
                        });
                        return sema.ExprResult.initOwned(loc);
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
    const ptr_t = try sema.getPtrType(c, expr.type);
    const ptr_loc = try c.ir.newExpr(.address_of, ptr_t, node, .{
        .expr = addr_expr.ir,
    });
    const ptr = sema.ExprResult.init(ptr_loc, ptr_t);
    const copy_fn = try sema.getCopyFunc(c, expr.type, node);
    const arg = Argument.initPreResolved(node, ptr);
    return c.semaCallFunc2(copy_fn, &.{arg}, &.{}, node);
}

/// Skips emitting IR for a sym.
pub fn semaExprSkipSym(c: *cy.Chunk, node: *ast.Node, cstr: sema.Cstr) !sema.ExprResult {
    switch (node.type()) {
        .group => {
            const child_n = node.cast(.group).child;
            return semaExprSkipSym(c, child_n, cstr);
        },
        .at_lit => {
            const name = node.cast(.at_lit).value.slice();
            if (c.semaProcs.items.len > 0) {
                const res = (try sema_resolve.getResolvedName(c, name, node)) orelse {
                    return sema_lit.reportOldSymbolLit(c, name, node);
                };
                try checkIntrinsicUse(c, node);
                switch (res.type) {
                    .sym => {
                        return symbol2(c, res.data.sym, true, cstr.target_t, node);
                    },
                    .ct_value => {
                        return c.reportErrorFmt("TODO ct_value", &.{}, node);
                    },
                    .ct_var => {
                        return c.reportErrorFmt("TODO ct_var", &.{}, node);
                    },
                }
            }
            return sema_lit.reportOldSymbolLit(c, name, node);
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
                        return symbol(c, final_sym, true, node);
                    },
                    .func_template => {
                        const template = left.data.sym.cast(.func_template);
                        const func_res = try cy.template.expandTemplateFuncForArgs(c, template, index_expr.args.slice(), node);
                        return sema.ExprResult.initCustom(undefined, .func, c.sema.void_t, .{ .func = func_res });
                    },
                    .func => {
                        const func_sym = left.data.sym.cast(.func);
                        std.debug.assert(func_sym.numFuncs > 1);
                        const idx = try cte.evalCheck(c, index_expr.args.ptr[0], c.sema.i64_t);
                        const func = func_sym.get_func(@intCast(idx.value.asInt())) orelse {
                            return c.reportError("Index out of bounds.", index_expr.args.ptr[0]);
                        };
                        return sema_call.sema_func_sym(c, func, true, null, node);
                    },
                    else => {
                        left = try symbol(c, left.data.sym, false, node);
                    },
                }
            } else if (left.resType == .func) {
                return c.reportError("Expected overloaded function.", node);
            }
            return sema_access.semaIndexExpr(c, index_expr.left, left, cstr, node);
        },
        .accessExpr => {
            const access = node.cast(.accessExpr);
            if (access.left.type() == .ident or access.left.type() == .accessExpr) {
                if (access.right.type() != .ident) return error.Unexpected;

                // TODO: Check if ident is sym to reduce work.
                return sema_access.semaAccessExpr(c, access, true, cstr.target_t);
            } else {
                return c.semaExpr(node, .{});
            }
        },
        .generic_vector_type => {
            const vector_t = node.cast(.generic_vector_type);
            const sym = try cy.template.expand_template_ast(c, c.sema.generic_vector_tmpl, &.{ vector_t.elem_t }, node);
            return sema.ExprResult.initCustom(undefined, .sym, sym.getStaticType().?, .{ .sym = sym });
        },
        .partial_vector_type => {
            const vector_t = node.cast(.partial_vector_type);
            const sym = try cy.template.expand_template_ast(c, c.sema.partial_vector_tmpl, &.{ vector_t.child, vector_t.n }, node);
            return sema.ExprResult.initCustom(undefined, .sym, sym.getStaticType().?, .{ .sym = sym });
        },
        .vector_type => {
            const vector_t = node.cast(.vector_type);
            const sym = try cy.template.expand_template_ast(c, c.sema.vector_tmpl, &.{ vector_t.child, vector_t.n }, node);
            return sema.ExprResult.initCustom(undefined, .sym, sym.getStaticType().?, .{ .sym = sym });
        },
        .span_type => {
            const span_type = node.cast(.span_type);
            const sym = try cy.template.expand_template_ast(c, c.sema.span_tmpl, &.{ span_type.child }, node);
            return sema.ExprResult.initCustom(undefined, .sym, sym.getStaticType().?, .{ .sym = sym });
        },
        .slice_type => {
            const slice_type = node.cast(.slice_type);
            const sym = try cy.template.expand_template_ast(c, c.sema.slice_tmpl, &.{ slice_type.child }, node);
            return sema.ExprResult.initCustom(undefined, .sym, sym.getStaticType().?, .{ .sym = sym });
        },
        .option_type => {
            const option_type = node.cast(.option_type);
            const sym = try cy.template.expand_template_ast(c, c.sema.option_tmpl, &.{ option_type.child }, node);
            return sema.ExprResult.initCustom(undefined, .sym, sym.getStaticType().?, .{ .sym = sym });
        },
        else => {
            // Not a symbol path.
            return c.semaExpr(node, cstr);
        },
    }
}

pub fn semaExprHint(c: *cy.Chunk, node: *ast.Node, target_t: ?*cy.Type) !sema.ExprResult {
    return try semaExpr(c, node, .{
        .target_t = target_t,
        .fit_target = false,
        .reqTypeCstr = false,
    });
}

pub fn semaExprTarget(c: *cy.Chunk, node: *ast.Node, target_t: ?*cy.Type) !sema.ExprResult {
    return try semaExpr(c, node, .{
        .target_t = target_t,
        .reqTypeCstr = false,
        .fit_target = true,
    });
}

pub fn semaExprCstr(c: *cy.Chunk, node: *ast.Node, target_t: *cy.Type) !sema.ExprResult {
    return try semaExpr(c, node, .{
        .target_t = target_t,
        .reqTypeCstr = true,
        .fit_target = true,
    });
}

pub fn semaExpr(c: *cy.Chunk, node: *ast.Node, cstr: sema.Cstr) !sema.ExprResult {
    // Set current node for unexpected errors.
    c.curNode = node;
    const res = try c.semaExprNoCheck(node, cstr);
    if (cy.Trace) {
        log.tracev("expr.{s}: end {s}", .{@tagName(node.type()), res.type.name()});
    }
    if (c.compiler.record_refs) {
        cy.refs.recordExpr(c, node, res.type);
    }
    if (c.compiler.config.deny_raw_ptrs) {
        try check_raw_ptr(c, res.type, node);
    }

    return checkExprCstr(c, res, cstr, node);
}

fn checkExprCstr(c: *cy.Chunk, res: sema.ExprResult, cstr: sema.Cstr, node: *ast.Node) !sema.ExprResult {
    if (cstr.target_t) |target_t| {
        if (target_t == res.type) {
            return res;
        }

        if (cstr.fit_target) {
            if (try sema_lit.semaFitTarget(c, res, target_t, node)) |new| {
                return new;
            }
        }

        if (res.type.id() == bt.Never) {
            return res;
        }

        if (cstr.reqTypeCstr) {
            return sema_lit.reportExpectedType(c, target_t, res.type, node);
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
    if (ptr_t.kind() == .null) {
        // An argument probed against overloads (`s.trim({' ', '\t'})`) has no type yet.
        return;
    }
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

pub fn semaExprNoCheck(c: *cy.Chunk, node: *ast.Node, cstr: sema.Cstr) anyerror!sema.ExprResult {
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
                if ((try sema_resolve.getResolvedName(c, at_name, node)) != null) {
                    try checkIntrinsicUse(c, node);
                }
            }
            return sema_lit.reportOldSymbolLit(c, at_name, node);
        },
        .void_lit => {
            return c.semaVoid(node);
        },
        .undef_lit => {
            if (cstr.target_t) |target_t| {
                const loc = try c.ir.newExpr(.undef, target_t, node, .{});
                return sema.ExprResult.initOwned(loc);
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
                    const val = try sema_lit.semaParseFloat(c, f32, literal, node);
                    return c.semaConst32(@bitCast(val), c.sema.f32_t, node);
                }
            }
            const val = try sema_lit.semaParseFloat(c, f64, literal, node);
            return c.semaConst(@bitCast(val), c.sema.f64_t, node);
        },
        .dec_u => {
            // `123u`: an unsigned decimal, stored as its 64-bit pattern.
            const literal = node.cast(.dec_u).asDecU();
            const val = try sema_lit.semaParseInt(c, u64, literal, 10, node);
            return c.semaConst(val, c.sema.i64_t, node);
        },
        .decLit => {
            const literal = node.cast(.decLit).value.slice();
            if (cstr.target_t) |target_t| {
                if (try sema_lit.semaInferSignedLit(c, literal, target_t, 10, node)) |res| {
                    return res;
                }
            }
            // A plain decimal is an `int`, so it must fit in i64. Larger bit patterns need `u`, hex or `r64`.
            const val = try sema_lit.semaParseInt(c, i64, literal, 10, node);
            return c.semaConst(@bitCast(val), c.sema.i64_t, node);
        },
        .binLit => {
            const literal = node.cast(.binLit).asBin();
            if (cstr.target_t) |target_t| {
                if (try sema_lit.semaInferUnsignedLit(c, literal, target_t, 2, node)) |res| {
                    return res;
                }
            }
            const val = try sema_lit.semaParseInt(c, u64, literal, 2, node);
            return c.semaConst(val, c.sema.i64_t, node);
        },
        .octLit => {
            const literal = node.cast(.octLit).asOct();
            if (cstr.target_t) |target_t| {
                if (try sema_lit.semaInferUnsignedLit(c, literal, target_t, 8, node)) |res| {
                    return res;
                }
            }
            const val = try sema_lit.semaParseInt(c, u64, literal, 8, node);
            return c.semaConst(val, c.sema.i64_t, node);
        },
        .hexLit => {
            const literal = node.cast(.hexLit).asHex();
            if (cstr.target_t) |target_t| {
                if (try sema_lit.semaInferUnsignedLit(c, literal, target_t, 16, node)) |res| {
                    return res;
                }
            }
            const val = try sema_lit.semaParseInt(c, u64, literal, 16, node);
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
                    const cp = try sema_lit.semaStringLitCodepoint(c, special_string.asString(), node);
                    if (cp > 0xFF) {
                        return c.reportError("Expected an ASCII codepoint.", node);
                    }
                    return c.semaConst8(@intCast(cp), c.sema.i8_t, node);
                },
                .unicode_cp => {
                    const cp = try sema_lit.semaStringLitCodepoint(c, special_string.asString(), node);
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
            const res_local = try sema_local.declareHiddenLocal(c, "_temp", cstr.target_t orelse c.sema.void_t, null, node);
            // A borrow result lives as long as the owner of either branch that goes out of scope first.
            var if_owner: ?sema.LocalId = null;

            // The branches move outer locals like the ones of an `if` statement (`semaIfStmt`), and the condition
            // always runs.
            var branches: std.ArrayListUnmanaged(sema_stmt.IfBranch) = .empty;
            defer branches.deinit(c.alloc);
            var kept: std.ArrayListUnmanaged(sema.LocalId) = .empty;
            defer kept.deinit(c.alloc);
            const outer = try sema_local.pushBlock(c, node);
            c.semaBlocks.items[outer].move_branch = .if_cond;
            const outer_start = c.semaBlocks.items[outer].varStart;
            {
                const cond = try c.semaExprCstr(if_expr.cond, c.sema.bool_t);
                c.semaBlocks.items[outer].move_branch = .if_outer;
                const moves_start = c.branch_moves.items.len;

                var target_t: *cy.Type = undefined;
                _ = try sema_local.pushBlock(c, node);
                c.block().move_branch = .branch;
                var body_end_reachable = true;
                {
                    var body: sema.ExprResult = undefined;
                    if (cstr.target_t) |cstr_target_t| {
                        body = try c.semaExprCstr(if_expr.body, cstr_target_t);
                        target_t = cstr_target_t;
                    } else {
                        body = try c.semaExpr(if_expr.body, .{});
                        target_t = body.type;
                        c.varStack.items[res_local.id].inner.local.declIrStart.cast(.declare_local).decl_t = target_t;
                        c.varStack.items[res_local.id].decl_t = target_t;
                    }
                    if_owner = try sema_borrow.joinBranchOwner(c, if_owner, body);
                    body = try sema_move.semaOwn(c, body, if_expr.body);
                    _ = try c.ir.pushStmt(.set_local, if_expr.body, .{
                        .id = @intCast(res_local.ir_id),
                        .right = body.ir,
                    });
                    body_end_reachable = c.block().endReachable;
                    try sema_stmt.semaBreakTo(c, outer, if_expr.body);
                }
                const if_stmts = try sema_local.popBlock2(c, false);
                const if_stmt = try c.ir.pushStmt(.if_block, node, .{
                    .cond_expr = cond.ir,
                    .body_head = if_stmts.first,
                });
                try sema_stmt.endIfBranch(c, &branches, &kept, &if_stmt.cast(.if_block).body_head, body_end_reachable, moves_start,
                    outer_start, outer_start);

                // Else.
                const else_moves_start = c.branch_moves.items.len;
                c.semaBlocks.items[outer].move_branch = .branch;
                c.semaBlocks.items[outer].moves_start = @intCast(else_moves_start);
                var else_body = try c.semaExprCstr(if_expr.else_expr, target_t);
                if_owner = try sema_borrow.joinBranchOwner(c, if_owner, else_body);
                else_body = try sema_move.semaOwn(c, else_body, if_expr.else_expr);
                _ = try c.ir.pushStmt(.set_local, if_expr.else_expr, .{
                    .id = @intCast(res_local.ir_id),
                    .right = else_body.ir,
                });
                c.semaBlocks.items[outer].move_branch = .if_outer;
                try sema_stmt.endIfBranch(c, &branches, &kept, null, c.block().endReachable, else_moves_start, outer_start,
                    c.varStack.items.len);
                if (kept.items.len > 0) {
                    try sema_stmt.joinBranchMoves(c, node, outer, branches.items, kept.items, true);
                }
                // A local of a block further out is a move of the enclosing branch. The block around the expression
                // can be one that passes its moves on (the condition of an `if` statement, the left of an `and`).
                c.branch_moves.items.len = moves_start;
                const parent_start = c.semaBlocks.items[sema_move.moveBlockFrom(c, outer - 1)].varStart;
                for (kept.items) |id| {
                    if (id < parent_start) try c.branch_moves.append(c.alloc, id);
                }
            }
            const stmts = try sema_local.popBlock(c);
            _ = try c.ir.pushStmt(.block, node, .{
                .bodyHead = stmts.first,
            });

            const res = (try semaLocal(c, res_local.id, node)).ir;
            c.varStack.items[res_local.id].type = .dead;
            var if_res = sema.ExprResult.initOwned(res);
            if_res.data.value.parent_local = if_owner;
            return if_res;
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
                            const init_sym = try sema_call.requireFuncSym(c, sym, node);
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
                            const init_sym = try sema_call.requireFuncSym(c, sym, node);
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
                                    return sema_lit.semaZext(c, target_t, @intCast(child.type.size() * 8), child, node);
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
                        const init_sym = try sema_call.requireFuncSym(c, sym, node);
                        return c.semaCallFuncSym1(init_sym, as_expr.expr, child, node);
                    }

                    if (child.type.kind() == .float) {
                        // f32/f64 -> Int[]
                        const sym = try c.getResolvedSymOrFail(&target_t.sym().head, "@init", node);
                        const init_sym = try sema_call.requireFuncSym(c, sym, node);
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
                                return sema_lit.semaZext(c, target_t, @intCast(child.type.size() * 8), child, node);
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
                            return sema_lit.semaZext(c, target_t, int_t.bits, child, node);
                        }
                        const sym = try c.getResolvedSymOrFail(&target_t.sym().head, "@init", node);
                        const init_sym = try sema_call.requireFuncSym(c, sym, node);
                        return c.semaCallFuncSym1(init_sym, as_expr.expr, child, node);
                    }
                }

                // Cast to float.
                if (target_t.kind() == .float) {
                    if (child.type.kind() == .int) {
                        // Int[]/UInt[] -> f64
                        const sym = try c.getResolvedSymOrFail(&target_t.sym().head, "@init", node);
                        const init_sym = try sema_call.requireFuncSym(c, sym, node);
                        return c.semaCallFuncSym1(init_sym, as_expr.expr, child, node);
                    }

                    if (child.type.kind() == .float) {
                        // f64/f32 -> f64
                        const sym = try c.getResolvedSymOrFail(&target_t.sym().head, "@init", node);
                        const init_sym = try sema_call.requireFuncSym(c, sym, node);
                        return c.semaCallFuncSym1(init_sym, as_expr.expr, child, node);
                    }
                }

                if (target_t.kind() == .struct_t) {
                    if (target_t.isInstanceOf(c.sema.ptr_span_tmpl)) {
                        if (child.type.kind() == .struct_t) {
                            if (child.type.isInstanceOf(c.sema.span_tmpl)) {
                                if (target_t.sym().instance.?.params[0].asPtr(*cy.Type).id() == child.type.sym().instance.?.params[0].asPtr(*cy.Type).id()) {
                                    // [&]T -> PtrSlice[T]
                                    const eff_child = try sema_move.semaOwn(c, child, node);
                                    return semaBitcast(c, eff_child, target_t, node);
                                }
                            }
                        }
                    } else if (target_t.isInstanceOf(c.sema.span_tmpl)) {
                        if (child.type.kind() == .struct_t) {
                            if (child.type.isInstanceOf(c.sema.ptr_span_tmpl)) {
                                if (target_t.sym().instance.?.params[0].asPtr(*cy.Type).id() == child.type.sym().instance.?.params[0].asPtr(*cy.Type).id()) {
                                    // PtrSlice[T] -> [&]T
                                    const eff_child = try sema_move.semaOwn(c, child, node);
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
                return sema.ExprResult.init(loc, target_t);
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
            const type_ = try sema.getFuncPtrType(c, sig);
            _ = type_;
            return c.reportError("Compile-time type cannot be used here. Consider using the `MetaType` initializer.", node);
        },
        .accessExpr => {
            return sema_access.semaAccessExpr(c, node.cast(.accessExpr), false, cstr.target_t);
        },
        .unwrap_choice => {
            const unwrap = node.cast(.unwrap_choice);
            var choice = try c.semaExpr(unwrap.left, .{});
            if (choice.type.kind() == .choice) {
                choice = try sema_move.semaEnsureAddressable(c, choice, unwrap.left);

                const choice_t = choice.type.cast(.choice);
                const name = unwrap.right.as_name();
                const case = choice_t.getCase(name) orelse {
                    return c.reportErrorFmt("Choice case `{}` does not exist.", &.{v(name)}, unwrap.right);
                };

                const choice_ptr_t = try sema.getPtrType(c, choice.type);
                const addr = try semaAddressOf(c, choice, choice_ptr_t, node);
                const ptr_t = try sema.getPtrType(c, case.payload_t);
                const loc = try c.ir.newExpr(.unwrap_addr, ptr_t, node, .{
                    .choice = addr.ir,
                    .tag = @intCast(case.val),
                });
                var ptr = sema.ExprResult.init(loc, ptr_t);
                ptr.addressable = choice.addressable;
                ptr.data.value.parent_local = choice.recParentLocal();
                return semaDeref(c, ptr, node);
            }
            if (choice.type.kind() == .pointer) {
                const pointer = choice.type.cast(.pointer);
                if (pointer.child_t.kind() == .choice) {
                    choice = try sema_move.semaManage(c, choice, unwrap.left);
                    const choice_t = pointer.child_t.cast(.choice);
                    const name = unwrap.right.as_name();
                    const case = choice_t.getCase(name) orelse {
                        return c.reportErrorFmt("Choice case `{}` does not exist.", &.{v(name)}, unwrap.right);
                    };
                    const ptr_t = try sema.getPtrType(c, case.payload_t);

                    const loc = try c.ir.newExpr(.unwrap_addr, ptr_t, node, .{
                        .choice = choice.ir,
                        .tag = @intCast(case.val),
                    });
                    var ptr = sema.ExprResult.init2(loc);
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
            opt = try sema_move.semaEnsureAddressable(c, opt, unwrap.opt);
            const payload_t = opt.type.cast(.option).child_t;

            if (opt.type.cast(.option).zero_union) {
                const expr = try c.ir.newExpr(.unwrap_nz, payload_t, node, .{
                    .option = opt.ir,
                });
                var res = sema.ExprResult.init2(expr);
                res.addressable = opt.addressable;
                return res;
            } else {
                const opt_ptr_t = try sema.getPtrType(c, opt.type);
                const addr = try semaAddressOf(c, opt, opt_ptr_t, node);

                const ptr_t = try sema.getPtrType(c, payload_t);
                const loc = try c.ir.newExpr(.unwrap_addr, ptr_t, node, .{
                    .choice = addr.ir,
                    .tag = 1,
                });
                var ptr = sema.ExprResult.init2(loc);
                ptr.addressable = opt.addressable;
                ptr.data.value.parent_local = opt.recParentLocal();

                var res = try semaDeref(c, ptr, node);
                if (owned) {
                    // Consume from option container.
                    const owner = res.data.value.parent_local.?;
                    c.varStack.items[owner].type = .dead;
                    res.owned = true;
                    // The payload is a new value, not a place: a borrow (`==`, `for`) must give it a temp to release.
                    res.addressable = false;
                }
                return res;
            }
        },
        .unwrap_res => {
            const unwrap_res = node.cast(.unwrap_res);
            var res_expr = try c.sema_expr_cstr_template(unwrap_res.res, c.sema.result_tmpl);
            const owned = res_expr.owned;
            // A borrow payload of a new result (`f(&a)!`) borrows from the owner of the result, not from the temp that
            // holds it for the statement.
            const borrow_owner = if (res_expr.type.info.borrow_only) sema_borrow.borrowOwner(c, res_expr) else null;
            res_expr = try sema_move.semaEnsureAddressable(c, res_expr, unwrap_res.res);

            const borrow_t = try sema.getBorrowType(c, res_expr.type);
            const res_addr = try semaAddressOf(c, res_expr, borrow_t, unwrap_res.res);
            const res_local = try sema_local.declareHiddenLocal(c, "_res_addr", borrow_t, res_addr, node);
            const res = try semaLocal(c, res_local.id, node);
            const cond = try c.semaIsError(res, node);

            // Push error branch.
            _ = try sema_local.pushBlock(c, node);
            {
                const err = try sema_access.semaUnwrapResultErrorNoCheck(c, res, node);
                try sema_stmt.semaPropagateError(c, err, node);
            }
            const block = try sema_local.popBlock2(c, false);
            _ = try c.ir.pushStmt(.if_block, node, .{
                .cond_expr = cond.ir,
                .body_head = block.first,
            });

            var unwrap = try sema_access.semaUnwrapResultNoCheck(c, res, node);
            unwrap.data.value_field.parent_local = res_expr.recParentLocal();
            if (owned) {
                // Move from Result container if initially owned.
                const owner = unwrap.data.value_field.parent_local.?;
                c.varStack.items[owner].type = .dead;
                unwrap.owned = true;
                // The payload is a new value, not a place: a borrow (`==`, `for`) must give it a temp to release.
                unwrap.addressable = false;
                if (res_expr.type.info.borrow_only) {
                    var payload = sema.ExprResult.initOwned(unwrap.ir);
                    payload.data.value.parent_local = borrow_owner;
                    return payload;
                }
            }
            return unwrap;
        },
        .unwrap_res_or => {
            const unwrap = node.cast(.unwrap_res_or);

            var res = try c.sema_expr_cstr_template(unwrap.res, c.sema.result_tmpl);
            const owned = res.owned;
            // A borrow payload lives as long as the owner of the result or of the default, whichever goes first.
            var owner = try sema_borrow.joinBranchOwner(c, null, res);
            res = try sema_move.semaEnsureAddressable(c, res, unwrap.res);

            const payload_t = res.type.cast(.result).child_t;
            const dst_local = try sema_local.declareHiddenLocal(c, "_temp", payload_t, null, node);
            const cond = try c.semaIsError(res, node);

            const outer = try sema_local.pushBlock(c, node);
            {
                // Push error branch.
                _ = try sema_local.pushBlock(c, node);
                {
                    try checkElseDefaultPrec(c, "!else", unwrap.default, payload_t);
                    const else_body = try c.semaExprCstr(unwrap.default, payload_t);
                    owner = try sema_borrow.joinBranchOwner(c, owner, else_body);
                    _ = try c.ir.pushStmt(.set_local, unwrap.default, .{
                        .id = @intCast(dst_local.ir_id),
                        .right = else_body.ir,
                    });
                    try sema_stmt.semaBreakTo(c, outer, unwrap.default);
                }
                const stmts = try sema_local.popBlock2(c, false);
                _ = try c.ir.pushStmt(.if_block, node, .{
                    .cond_expr = cond.ir,
                    .body_head = stmts.first,
                });

                // Else result branch.
                const unwrap_res = try sema_stmt.semaMoveOrCopyResultPayload(c, res, owned, node);
                _ = try c.ir.pushStmt(.set_local, unwrap.res, .{
                    .id = @intCast(dst_local.ir_id),
                    .right = unwrap_res.ir,
                });
            }
            const stmts = try sema_local.popBlock(c);
            _ = try c.ir.pushStmt(.block, node, .{
                .bodyHead = stmts.first,
            });

            const ret = (try semaLocal(c, dst_local.id, node)).ir;
            c.varStack.items[dst_local.id].type = .dead;
            var unwrap_ret = sema.ExprResult.initOwned(ret);
            unwrap_ret.data.value.parent_local = owner;
            return unwrap_ret;
        },
        .unwrap_res_or_block => {
            const unwrap = node.cast(.unwrap_res_or_block);

            var res = try c.sema_expr_cstr_template(unwrap.res, c.sema.result_tmpl);
            const owned = res.owned;
            const owner = try sema_borrow.joinBranchOwner(c, null, res);
            res = try sema_move.semaEnsureAddressable(c, res, unwrap.res);

            const payload_t = res.type.cast(.result).child_t;
            const dst_local = try sema_local.declareHiddenLocal(c, "_temp", payload_t, null, node);

            // NOTE: Prevent else block from releasing a uninited local.
            c.varStack.items[dst_local.id].type = .dead;
            const cond = try c.semaIsError(res, node);

            // Push error branch.
            _ = try sema_local.pushBlock(c, node);
            {
                if (unwrap.capture) |capture| {
                    var err_name: []const u8 = undefined;
                    if (capture.type() == .ident) {
                        err_name = capture.cast(.ident).name.slice();
                    } else {
                        return c.reportErrorFmt("Unsupported error variable: {}", &.{v(capture.type())}, capture);
                    }

                    var capture_init = try sema_access.semaUnwrapResultErrorNoCheck(c, res, capture);
                    capture_init = try sema_copy(c, capture_init, capture);
                    _ = try sema_local.declareLocalInit(c, err_name, c.sema.error_t, capture_init, capture);
                }
                try sema_stmt.semaStmts(c, unwrap.else_stmts);
                if (c.block().endReachable) {
                    return sema_stmt.reportElseBlockEnd(c, .result, node);
                }
            }
            const stmts = try sema_local.popBlock2(c, false);
            _ = try c.ir.pushStmt(.if_block, node, .{
                .cond_expr = cond.ir,
                .body_head = stmts.first,
            });

            // Push result branch.
            const unwrap_res = try sema_stmt.semaMoveOrCopyResultPayload(c, res, owned, node);
            _ = try c.ir.pushStmt(.set_local, unwrap.res, .{
                .id = @intCast(dst_local.ir_id),
                .right = unwrap_res.ir,
            });

            c.varStack.items[dst_local.id].type = .local;
            const ret = (try semaLocal(c, dst_local.id, node)).ir;
            c.varStack.items[dst_local.id].type = .dead;
            var unwrap_ret = sema.ExprResult.initOwned(ret);
            unwrap_ret.data.value.parent_local = owner;
            return unwrap_ret;
        },
        .unwrap_or => {
            const unwrap = node.cast(.unwrap_or);

            var opt = try semaElseOption(c, unwrap.opt, unwrap.default);
            // A borrow payload lives as long as the owner of the option or of the default, whichever goes first.
            var owner = try sema_borrow.joinBranchOwner(c, null, opt);
            opt = try sema_stmt.semaElseOptionOwner(c, opt, unwrap.opt);

            const payload_t = opt.type.cast(.option).child_t;
            const res_local = try sema_local.declareHiddenLocal(c, "_temp", payload_t, null, node);

            // NOTE: Prevent else block from releasing a uninited local.
            c.varStack.items[res_local.id].type = .dead;

            const outer = try sema_local.pushBlock(c, node);
            {
                try sema_stmt.semaUnwrapOrStmt(c, opt, res_local.ir_id, outer, unwrap.opt);

                // Else.
                try checkElseDefaultPrec(c, "?else", unwrap.default, payload_t);
                var else_body = try c.semaExprCstr(unwrap.default, payload_t);
                owner = try sema_borrow.joinBranchOwner(c, owner, else_body);
                else_body = try sema_move.semaOwn(c, else_body, unwrap.default);
                _ = try c.ir.pushStmt(.set_local, unwrap.default, .{
                    .id = @intCast(res_local.ir_id),
                    .right = else_body.ir,
                });
            }
            const block = try sema_local.popBlock(c);
            _ = try c.ir.pushStmt(.block, node, .{
                .bodyHead = block.first,
            });

            c.varStack.items[res_local.id].type = .local;
            const expr = (try semaLocal(c, res_local.id, node)).ir;
            // Move to return.
            c.varStack.items[res_local.id].type = .dead;
            var unwrap_ret = sema.ExprResult.initOwned(expr);
            unwrap_ret.data.value.parent_local = owner;
            return unwrap_ret;
        },
        .unwrap_or_block => {
            const unwrap = node.cast(.unwrap_or_block);

            var opt = try semaElseOption(c, unwrap.opt, null);
            const owner = try sema_borrow.joinBranchOwner(c, null, opt);
            opt = try sema_stmt.semaElseOptionOwner(c, opt, unwrap.opt);

            const payload_t = opt.type.cast(.option).child_t;
            const res_local = try sema_local.declareHiddenLocal(c, "_unwrap_res", payload_t, null, node);

            // NOTE: Prevent else block from releasing a uninited local.
            c.varStack.items[res_local.id].type = .dead;

            const outer = try sema_local.pushBlock(c, node);
            {
                try sema_stmt.semaUnwrapOrStmt(c, opt, res_local.ir_id, outer, unwrap.opt);

                // Else.
                try sema_stmt.semaStmts(c, unwrap.else_stmts);
                if (c.block().endReachable) {
                    return sema_stmt.reportElseBlockEnd(c, .option, node);
                }
            }
            const block = try sema_local.popBlock(c);
            _ = try c.ir.pushStmt(.block, node, .{
                .bodyHead = block.first,
            });

            c.varStack.items[res_local.id].type = .local;
            const res = (try semaLocal(c, res_local.id, node)).ir;
            c.varStack.items[res_local.id].type = .dead;
            var unwrap_ret = sema.ExprResult.initOwned(res);
            unwrap_ret.data.value.parent_local = owner;
            return unwrap_ret;
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

            if (!range.inc) {
                return c.reportError("A decreasing range is only allowed in a `for` loop.", node);
            }

            var b: sema_init.InitBuilder = .{ .c = c };
            try b.begin(c.sema.range_t, 2, node);

            const start_res = try c.semaExprCstr(start, c.sema.i64_t);
            try b.pushArg(start_res, start);

            // `Range` is `[start, end)`, so `a..=b` holds `b + 1`.
            const end_res = if (range.end_inclusive)
                try sema_access.semaRangeEndPlusOne(c, end)
            else
                try c.semaExprCstr(end, c.sema.i64_t);
            try b.pushArg(end_res, end);

            const loc = b.end();
            return sema.ExprResult.init(loc, c.sema.range_t);
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
            left = try sema_move.semaManage(c, left, deref.left);

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
                    const payload = try sema_init.semaInitLitTarget(c, init_lit, option.child_t, cstr.return_infer_error, cstr.assign_to_local);
                    const tag = try c.semaConst(1, c.sema.i64_t, node);
                    return sema_init.semaInit2(c, target_t, tag, payload, node);
                } else {
                    return sema_init.semaInitLitTarget(c, init_lit, target_t, cstr.return_infer_error, cstr.assign_to_local);
                }
            }

            const init_lit = node.cast(.init_lit);
            if (!init_lit.array_like) {
                return c.reportError("Expected a target type for a key value initializer, such as `Map[str, int]{a=1}`.", node);
            }
            if (init_lit.args.len == 0) {
                return c.reportError("Expected a target type or at least one element.", node);
            }
            return sema_init.semaInferSliceLit(c, init_lit);
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

            if (try sema_resolve.inferLambdaFuncSig(c, lambda.sig_t, cstr.target_t, node)) |sig| {
                const func = try c.addUserLambda(@ptrCast(c.sym), @ptrCast(lambda));
                _ = try sema_local.pushLambdaProc(c, func);

                // Generate function body.
                try c.resolveUserLambda(func, sig);
                try sema_local.appendFuncParamVars(c, lambda.params, sig.params());

                _ = try sema_stmt.semaReturnExprStmt(c, lambda.expr, func.sig.ret, lambda.expr);

                return sema_local.popLambdaProc(c);
            } else {
                const start = c.func_param_stack.items.len;
                defer c.func_param_stack.items.len = start;
                try sema_resolve.pushLambdaFuncParams(c, lambda.params);

                const func = try c.addUserLambda(@ptrCast(c.sym), @ptrCast(lambda));
                _ = try sema_local.pushLambdaProc(c, func);

                // Generate function body.
                const params = c.func_param_stack.items[start..];
                try sema_local.appendFuncParamVars(c, lambda.params, params);

                var func_ret_t: *cy.Type = undefined;
                if (lambda.ret == null) {
                    // Infer return type.
                    func_ret_t = try sema_stmt.semaReturnExprStmt(c, lambda.expr, null, lambda.expr);
                } else {
                    func_ret_t = try sema_type.resolveReturnType(c, lambda.ret);
                    _ = try sema_stmt.semaReturnExprStmt(c, lambda.expr, func_ret_t, lambda.expr);
                }

                const sig = try c.sema.ensureFuncSig(@ptrCast(params), func_ret_t);
                try c.resolveUserLambda(func, sig);

                return sema_local.popLambdaProc(c);
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
                    return symbol(c, final_sym, false, node);
                } else if (left.data.sym.type == .func_template) {
                    const template = left.data.sym.cast(.func_template);
                    const func_res = try cy.template.expandTemplateFuncForArgs(c, template, index_expr.args.slice(), node);
                    const typeId = try cy.sema.getFuncPtrType(c, func_res.sig);
                    try sema_call.checkCallee(c, func_res, node);
                    func_res.info.escaped = true;
                    const loc = try c.ir.newExpr(.func_ptr, typeId, node, .{ .func = func_res });
                    return sema.ExprResult.initCustom(loc, .func, typeId, .{ .func = func_res });
                } else {
                    left = try symbol(c, left.data.sym, false, node);
                }
            }
            return sema_access.semaIndexExpr(c, index_expr.left, left, cstr, node);
        },
        .switchExpr => { 
            return sema_switch.semaSwitchExpr(c, node.cast(.switchExpr), .{
                .target_t = cstr.target_t,
                .reqTypeCstr = cstr.reqTypeCstr,
            });
        },
        .fiber_expr => {
            return sema_call.semaFiberExpr(c, node);
        },
        .spawn_expr => {
            return sema_call.semaSpawnExpr(c, node);
        },
        .move_expr => {
            const child = node.cast(.move_expr).expr;
            const res = try semaExpr(c, child, .{});
            const moved = try sema_move.semaMove(c, res, child);
            const owner = c.temp_access_path.var_id;
            if (c.varStack.items[owner].type == .local and sema_move.isPersistedMainLocal(c, owner)) {
                // The moved state of a member is not carried over to the next input, which reads the whole local.
                const name = c.varStack.items[owner].name();
                return c.reportErrorFmt("Cannot move a member of the top level variable `{}` of the REPL: later inputs read `{}`. Move the whole variable with `move {}`, or do it inside a function.", &.{v(name), v(name), v(name)}, child);
            }
            return moved;
        },
        else => {
            return c.reportErrorFmt("Unsupported node: {}", &.{v(node.type())}, node);
        },
    }
}

/// Expr or construct binExpr from opAssignStmt.
pub fn semaExprOrOpAssignBinExpr(c: *cy.Chunk, node: *ast.Node, cstr: sema.Cstr, opAssignBinExpr: bool) !sema.ExprResult {
    if (!opAssignBinExpr) {
        return try c.semaExpr(node, cstr);
    } else {
        const stmt = node.cast(.op_assign_stmt);
        const res = try c.semaBinExpr(cstr, stmt.left, stmt.op, stmt.right, node);
        // `x op= y` is `x = x op y`. Check the result like a plain assignment does. Without this, `^[]T += v`
        // stored the `[]T` that `+` returns into the `^[]T` local and corrupted memory.
        if (cstr.target_t) |target_t| {
            if (target_t != res.type and cstr.reqTypeCstr) {
                if (target_t.getRefLikeChild() == res.type) {
                    const name = try c.sema.allocTypeName(target_t);
                    defer c.alloc.free(name);
                    const op = try c.sema.allocTypeName(res.type);
                    defer c.alloc.free(op);
                    return c.reportErrorFmt("Expected type `{}`, got `{}`. To change the value that `{}` points to, write `{}.* {}= ...`.", &.{
                        v(name), v(op), v(c.nodeString(stmt.left)), v(c.nodeString(stmt.left)), v(stmt.op.name()),
                    }, node);
                }
            }
        }
        return checkExprCstr(c, res, cstr, node);
    }
}

pub fn semaIsError(c: *cy.Chunk, rec: sema.ExprResult, node: *ast.Node) !sema.ExprResult {
    const loc = try c.ir.newExpr(.field, c.sema.i64_t, node, .{
        .idx = 0,
        .rec = rec.ir,
    });
    const field = sema.ExprResult.init2(loc);
    return semaIsZero(c, field, node);
}

pub fn semaIsNone(c: *cy.Chunk, rec: sema.ExprResult, node: *ast.Node) !sema.ExprResult {
    if (rec.type.kind() == .option) {
        if (rec.type.cast(.option).zero_union) {
            return semaIsZero(c, rec, node);
        } else {
            const loc = try c.ir.newExpr(.field, c.sema.i64_t, node, .{
                .idx = 0,
                .rec = rec.ir,
            });
            const field = sema.ExprResult.init(loc, c.sema.i64_t);
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
                const rec_deref = sema.ExprResult.init(loc, child);
                return semaIsZero(c, rec_deref, node);
            } else {
                const loc = try c.ir.newExpr(.field, c.sema.i64_t, node, .{
                    .idx = 0,
                    .rec = rec.ir,
                });
                const field = sema.ExprResult.init(loc, c.sema.i64_t);
                return semaIsZero(c, field, node);
            }
        }
    }
    return c.reportError("Expected `Option` type.", node);
}

pub fn semaIsZero(c: *cy.Chunk, child: sema.ExprResult, node: *ast.Node) !sema.ExprResult {
    const irIdx = try c.ir.newExpr(.is_zero, c.sema.bool_t, node, .{ .child = child.ir });
    return sema.ExprResult.init(irIdx, c.sema.bool_t);
}

pub fn semaNone(c: *cy.Chunk, prefer_t: *cy.Type, node: *ast.Node) !sema.ExprResult {
    if (prefer_t.kind() == .option) {
        const option_t = prefer_t.cast(.option);
        if (option_t.zero_union) {
            var res = try c.semaConst(0, prefer_t, node);
            res.owned = true;
            return res;
        } else {
            // Generate IR to wrap value into optional.
            var b: sema_init.InitBuilder = .{ .c = c };
            try b.begin(prefer_t, 2, node);
            const tag = try c.semaConst(0, c.sema.i64_t, node);
            try b.pushArg(tag, node);
            const payload = try c.semaVoid(node);
            try b.pushArg2(payload, c.sema.void_t, node);
            const loc = b.end();

            return sema.ExprResult.initOwned(loc);
        }
    } else if (prefer_t.kind() == .result) {
        const result_t = prefer_t.cast(.result);
        if (result_t.child_t.kind() == .option) {
            const option = try semaNone(c, result_t.child_t, node);
            return sema_init.semaInitChoice(c, prefer_t, 1, 1, option, node);
        }
    } else if (prefer_t.kind() == .pointer) {
        const pointer = prefer_t.cast(.pointer);
        if (!pointer.ref) {
            return sema_lit.semaConst(c, 0, prefer_t, node);
        }
    } else if (prefer_t.kind() == .func_ptr) {
        const func_ptr = prefer_t.cast(.func_ptr);
        if (func_ptr.sig.extern_) {
            // @extern fn()
            return sema_lit.semaConst(c, 0, prefer_t, node);
        }
    }
    return c.reportErrorFmt("Expected `?T` to infer `none` value, found `{}`.", &.{v(prefer_t.name())}, node);
}

pub fn semaRefOrType(c: *cy.Chunk, node: *ast.Node, cstr: sema.Cstr) !sema.ExprResult {
    const ref = node.cast(.ref);
    var child_cstr = sema.Cstr{};
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
    return sema_move.semaLift(c, child, node);
}

pub fn sema_ex_borrow_or_type(c: *cy.Chunk, node: *ast.Node, cstr: sema.Cstr) !sema.ExprResult {
    const borrow = node.cast(.ex_borrow);
    var child_cstr = sema.Cstr{};
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
        const borrow_t = try sema.getBorrowType(c, child.data.sym.getStaticType().?);
        return sema.ExprResult.initCustom(undefined, .sym, c.sema.type_t, .{ .sym = &borrow_t.sym().head });
    }

    if (cstr.assign_to_local and !child.addressable) {
        // try semaInitLocal(c, extended_temp, child, borrow.child);
        // child = try semaLocal(c, extended_temp, node);
        // var res = try sema_ex_borrow(c, child, node);
        // res.data.value.has_aux_local = true;
        // return res;
        return c.reportError("Cannot exclusively borrow a temporary value.", borrow.child);
    } else {
        return sema_borrow.sema_ex_borrow(c, child, node);
    }
}

pub fn semaBorrowOrType(c: *cy.Chunk, node: *ast.Node, cstr: sema.Cstr) !sema.ExprResult {
    const borrow = node.cast(.borrow);
    var child_cstr = sema.Cstr{};
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
        const borrow_t = try sema.getBorrowType(c, child.data.sym.getStaticType().?);
        return sema.ExprResult.initCustom(undefined, .sym, c.sema.type_t, .{ .sym = &borrow_t.sym().head });
    }

    if (cstr.assign_to_local and !child.addressable) {
        // try semaInitLocal(c, extended_temp, child, borrow.child);
        // child = try semaLocal(c, extended_temp, node);
        // var res = try semaBorrow(c, child, node);
        // res.data.value.has_aux_local = true;
        // return res;
        return c.reportError("Cannot borrow a temporary value.", borrow.child);
    } else {
        return sema_borrow.semaBorrow(c, child, node);
    }
}

pub fn semaInitLocal(c: *cy.Chunk, id: sema.LocalId, init: sema.ExprResult, node: *ast.Node) !void {
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
    if (c.compiler.record_refs) cy.refs.recordLocalType(c, local);
}

pub fn semaPtrOrType(c: *cy.Chunk, node: *ast.Node, cstr: sema.Cstr) !sema.ExprResult {
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
    child = try sema_move.semaEnsureAddressable(c, child, node);

    const ptr_t = try sema.getPtrType(c, child.type);
    const loc = try c.ir.newExpr(.address_of, ptr_t, node, .{
        .expr = child.ir,
    });
    return sema.ExprResult.init2(loc);
}

pub fn semaUnExpr(c: *cy.Chunk, unary: *ast.Unary, expr: sema.Cstr) !sema.ExprResult {
    const node = @as(*ast.Node, @ptrCast(unary));
    switch (unary.op) {
        .minus => {
            var child: sema.ExprResult = undefined;
            // `return -x` in a function that returns `?T` or `!T` negates a `T` and wraps it after.
            var neg_target_t = expr.target_t;
            if (neg_target_t) |target_t| {
                switch (target_t.kind()) {
                    .option => neg_target_t = target_t.cast(.option).child_t,
                    .result => neg_target_t = target_t.cast(.result).child_t,
                    else => {},
                }
            }
            if (unary.child.type() == .decLit) {
                const literal = unary.child.cast(.decLit).value.slice();
                if (neg_target_t) |target_t| {
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
                var val: i64 = @bitCast(try sema_lit.semaParseInt(c, u64, literal, 10, @ptrCast(unary.child)));
                if (val != std.math.minInt(i64)) {
                    if (val < 0) {
                        return c.reportError("Integer literal does not fit the target type.", @ptrCast(unary.child));
                    } else {
                        val = -val;
                    }
                }
                return c.semaConst(@bitCast(val), c.sema.i64_t, node);
            } else {
                child = try c.semaExprTarget(unary.child, neg_target_t);
            }

            switch (child.type.id()) {
                bt.F32,
                bt.F64 => {
                    const op = try c.ir.newExpr(.fneg, child.type, node, .{
                        .expr = child.ir,
                    });
                    return sema.ExprResult.init2(op);
                },
                bt.I8,
                bt.I16,
                bt.I32,
                bt.I64 => {
                    const op = try c.ir.newExpr(.neg, child.type, node, .{
                        .expr = child.ir,
                    });
                    return sema.ExprResult.init2(op);
                },
                else => {},
            }

            // Look for sym under child type's module.
            const childTypeSym = child.type.sym();
            const sym = try c.getResolvedSymOrFail(@ptrCast(childTypeSym), unary.op.name(), node);
            const func_sym = try sema_call.requireFuncSym(c, sym, node);
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
                    return sema.ExprResult.init2(op);
                },
                else => {},
            }

            // Look for sym under child type's module.
            const childTypeSym = child.type.sym();
            const sym = (try c.getResolvedSym(@ptrCast(childTypeSym), unary.op.name(), node)) orelse {
                const type_name = try c.sema.allocTypeName(child.type);
                defer c.alloc.free(type_name);
                const hint: []const u8 = switch (child.type.kind()) {
                    .option => " For an option, compare with `none` (`x == none`), unwrap it with `if x |v|:`, or give a default with `?else`.",
                    .result => " Unwrap the result with `!` first, or handle the error with `!else` or `try`.",
                    else => "",
                };
                return c.reportErrorFmt("`not` takes a `bool`. Found `{}`.{}", &.{v(type_name), v(hint)}, node);
            };
            const func_sym = try sema_call.requireFuncSym(c, sym, node);
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
                    return fold_const_int(c, sema.ExprResult.init(op, child.type));
                },
                else => {},
            }

            // Look for sym under child type's module.
            const childTypeSym = child.type.sym();
            const sym = try c.getResolvedSymOrFail(@ptrCast(childTypeSym), unary.op.name(), node);
            const func_sym = try sema_call.requireFuncSym(c, sym, node);
            return c.semaCallFuncSym1(func_sym, unary.child, child, node);
        },
        else => return c.reportErrorFmt("Unsupported unary op: {}", &.{v(unary.op)}, node),
    }
}

pub fn sema_bin_expr3(c: *cy.Chunk, left: sema.ExprResult, left_n: *ast.Node, right: sema.ExprResult, right_n: *ast.Node, op: cy.BinaryExprOp, node: *ast.Node) !sema.ExprResult {
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
            const func_sym = try sema_call.requireFuncSym(c, sym, node);
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
fn fold_const_int(c: *cy.Chunk, res: sema.ExprResult) !sema.ExprResult {
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

fn sema_bin_expr2(c: *cy.Chunk, left: sema.ExprResult, left_n: *ast.Node, right: sema.ExprResult, right_n: *ast.Node, op: cy.BinaryExprOp, node: *ast.Node) !sema.ExprResult {
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
                    return sema.ExprResult.init2(expr);
                },
                .minus => {
                    const expr = try c.ir.newExpr(.fsub, left.type, node, .{
                        .left = left.ir,
                        .right = right.ir,
                    });
                    return sema.ExprResult.init2(expr);
                },
                .star => {
                    const expr = try c.ir.newExpr(.fmul, left.type, node, .{
                        .left = left.ir,
                        .right = right.ir,
                    });
                    return sema.ExprResult.init2(expr);
                },
                .slash => {
                    const expr = try c.ir.newExpr(.fdiv, left.type, node, .{
                        .left = left.ir,
                        .right = right.ir,
                    });
                    return sema.ExprResult.init2(expr);
                },
                .percent => {
                    const expr = try c.ir.newExpr(.fmod, left.type, node, .{
                        .left = left.ir,
                        .right = right.ir,
                    });
                    return sema.ExprResult.init2(expr);
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
    const func_sym = try sema_call.requireFuncSym(c, sym, node);
    const args = [_]sema_func.Argument{
        sema_func.Argument.initReceiver(left_n, left),
        sema_func.Argument.initPreResolved(right_n, right),
    };
    return c.semaCallFuncSymRec2(func_sym, &args, node);
}

/// `n + 1` where `n` is a `^int` or `&float`: the operator is on the value it points to. Without this the lookup
/// found the reserved `int.+` and reported ``Cannot invoke the reserved function `int.+`.``.
fn checkRefOperand(c: *cy.Chunk, left_t: *cy.Type, op: cy.BinaryExprOp, left_n: *ast.Node, node: *ast.Node) !void {
    // Raw `Ptr[T]` keeps pointer arithmetic.
    if (left_t.kind() == .pointer and !left_t.isRefPointer()) return;
    const child_t = left_t.getRefLikeChild() orelse return;
    switch (child_t.kind()) {
        .int, .raw, .float => {},
        else => return,
    }
    const name = try c.sema.allocTypeName(left_t);
    defer c.alloc.free(name);
    const left_s = c.nodeString(left_n);
    if (node.type() == .op_assign_stmt) {
        return c.reportErrorFmt("Can not use `{}` on `{}`. To change the value that `{}` points to, write `{}.* {}= ...`.", &.{
            v(op.name()), v(name), v(left_s), v(left_s), v(op.name()),
        }, node);
    }
    return c.reportErrorFmt("Can not use `{}` on `{}`. Dereference it first: `{}.* {} ...`.", &.{
        v(op.name()), v(name), v(left_s), v(op.name()),
    }, node);
}

pub fn semaBinExpr(c: *cy.Chunk, expr: sema.Cstr, left_n: *ast.Node, op: cy.BinaryExprOp, right_n: *ast.Node, node: *ast.Node) !sema.ExprResult {
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
            try checkRefOperand(c, left.type, op, left_n, node);
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
            const func_sym = try sema_call.requireFuncSym(c, sym, node);
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
            try checkRefOperand(c, left.type, op, left_n, node);
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
                        left = (try sema_lit.semaFitTarget(c, left, right.type, left_n)) orelse {
                            return c.reportError("Could not widen left integer type.", left_n);
                        };
                    } else {
                        right = (try sema_lit.semaFitTarget(c, right, left.type, right_n)) orelse {
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
            const func_sym = try sema_call.requireFuncSym(c, sym, node);
            return c.semaCallFuncSymRec(func_sym, left_n, left, &.{ right_n }, false, node);
        },
        .bang_equal => {
            var left = try c.semaExpr(left_n, .{});
            try checkNoneCompare(c, left.type, left_n, right_n);
            const right = try semaRightOperand(c, &left, left_n, right_n, .{ .target_t = left.type, .reqTypeCstr = true, .fit_target = true });
            const res = try semaCompare(c, left_n, left, right_n, right, node);
            const not = try c.ir.newExpr(.unary_op, c.sema.bool_t, node, .{
                .childT = c.sema.bool_t, .op = .lnot, .expr = res.ir,
            });
            return sema.ExprResult.init2(not);
        },
        .equal_equal => {
            var left = try c.semaExpr(left_n, .{});
            try checkNoneCompare(c, left.type, left_n, right_n);
            const right = try semaRightOperand(c, &left, left_n, right_n, .{ .target_t = left.type, .reqTypeCstr = true, .fit_target = true });
            return semaCompare(c, left_n, left, right_n, right, node);
        },
        else => return c.reportErrorFmt("Unsupported binary op: {}", &.{v(op)}, node),
    }
}

/// `x == none` where `x` can not hold `none`. `semaNone` would only say that it expected `?T`.
fn checkNoneCompare(c: *cy.Chunk, left_t: *cy.Type, left_n: *ast.Node, right_n: *ast.Node) !void {
    if (right_n.type() != .noneLit) return;
    if (noneFits(left_t)) return;
    if (left_t.id() == bt.Never) return;
    const type_name = try c.sema.allocTypeName(left_t);
    defer c.alloc.free(type_name);
    const left_src = c.nodeString(left_n);
    const short = left_src.len <= 40 and std.mem.indexOfScalar(u8, left_src, '\n') == null;
    var example: []const u8 = "";
    if (left_t.id() == bt.Str and short) {
        example = std.fmt.bufPrint(&sema_hint.suggest_buf, ", for example `{s}.len() == 0`", .{left_src}) catch "";
    }
    if (short) {
        return c.reportErrorFmt("`{}` is `{}`, which is never `none`. Compare with a value of the same type{}.", &.{v(left_src), v(type_name), v(example)}, right_n);
    }
    return c.reportErrorFmt("This value is `{}`, which is never `none`. Compare with a value of the same type{}.", &.{v(type_name), v(example)}, right_n);
}

/// Whether `semaNone` can make a `none` value of type `t`.
fn noneFits(type_: *cy.Type) bool {
    return switch (type_.kind()) {
        .option => true,
        .result => type_.cast(.result).child_t.kind() == .option,
        .pointer => !type_.cast(.pointer).ref,
        .func_ptr => type_.cast(.func_ptr).sig.extern_,
        else => false,
    };
}

/// Analyzes the right operand of a binary expression. `left` is evaluated before a statement that the right
/// operand adds (`seqFlush`).
fn semaRightOperand(c: *cy.Chunk, left: *sema.ExprResult, left_n: *ast.Node, right_n: *ast.Node, cstr: sema.Cstr) !sema.ExprResult {
    const seq_start = c.seq_pending.items.len;
    defer sema_move.seqPop(c, seq_start);
    try sema_move.seqPushRes(c, left, left_n);
    return c.semaExpr(right_n, cstr);
}

/// Assumes first arg contains the the args count.
pub fn semaPartialVector(c: *cy.Chunk, arr_t: *cy.Type, args: []*ir.Expr, node: *ast.Node) !sema.ExprResult {
    if (args.len > 255) {
        return c.reportError("Max limit reached.", node);
    }
    const loc = try c.ir.newExpr(.init, arr_t, node, .{
        .nargs = @intCast(args.len), .args = args.ptr,
    });
    return sema.ExprResult.initOwned(loc);
}

pub fn semaVector(c: *cy.Chunk, arr_t: *cy.Type, args: []*ir.Expr, node: *ast.Node) !sema.ExprResult {
    if (args.len > 255) {
        return c.reportError("Max limit reached.", node);
    }
    const loc = try c.ir.newExpr(.init, arr_t, node, .{
        .nargs = @intCast(args.len), .args = args.ptr,
    });
    return sema.ExprResult.initOwned(loc);
}

pub fn semaCompare(c: *cy.Chunk, left_n: *ast.Node, left: sema.ExprResult, right_n: *ast.Node, right: sema.ExprResult, node: *ast.Node) !sema.ExprResult {
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
        const left_borrow = try sema_borrow.semaBorrow(c, left, left_n);
        const right_borrow = try sema_borrow.semaBorrow(c, right, right_n);
        const args = [_]sema_func.Argument{
            sema_func.Argument.initPreResolved(left_n, left_borrow),
            sema_func.Argument.initPreResolved(right_n, right_borrow),
        };
        const eq_func = try sema.getEqFunc(c, left.type, node);
        return c.semaCallFunc2(eq_func, &args, &.{}, node);
    } else {
        const new_left = try sema_move.semaManage(c, left, left_n);
        const new_right = try sema_move.semaManage(c, right, right_n);
        const loc = try c.ir.newExpr(.binary_op, c.sema.bool_t, node, .{
            .leftT = left.type,
            .rightT = right.type,
            .op = .equal_equal,
            .left = new_left.ir,
            .right = new_right.ir,
        });
        return sema.ExprResult.init2(loc);
    }
}

/// Use of body stmts is extracted so that `lamda_multi` and `lambda_cont` have the same behavior.
fn semaLambdaMulti(c: *cy.Chunk, lambda: *ast.LambdaMulti, stmts: []const *ast.Node, expr: sema.Cstr) !sema.ExprResult {
    const node: *ast.Node = @ptrCast(lambda);

    // try pushResolveContext(c, node);
    // defer popResolveContext(c);

    if (try sema_resolve.inferLambdaFuncSig(c, lambda.sig_t, expr.target_t, node)) |sig| {
        const func = try c.addUserLambda(@ptrCast(c.sym), @ptrCast(lambda));
        _ = try sema_local.pushLambdaProc(c, func);

        try c.resolveUserLambda(func, sig);
        try sema_local.appendFuncParamVars(c, lambda.params, @ptrCast(sig.params()));

        // Generate function body.
        try sema_stmt.semaStmts(c, stmts);

        return sema_local.popLambdaProc(c);
    } else {
        const start = c.func_param_stack.items.len;
        defer c.func_param_stack.items.len = start;
        try sema_resolve.pushLambdaFuncParams(c, lambda.params);

        const func = try c.addUserLambda(@ptrCast(c.sym), @ptrCast(lambda));
        _ = try sema_local.pushLambdaProc(c, func);

        const func_ret_t = try sema_type.resolveReturnType(c, lambda.ret);
        const params = c.func_param_stack.items[start..];
        const sig = try c.sema.ensureFuncSig(@ptrCast(params), func_ret_t);
        try c.resolveUserLambda(func, sig);

        try sema_local.appendFuncParamVars(c, lambda.params, params);

        // Generate function body.
        try sema_stmt.semaStmts(c, stmts);

        return sema_local.popLambdaProc(c);
    }
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
pub const hook_names = std.StaticStringMap(void).initComptime(.{
    .{"@init"}, .{"@init_sequence"}, .{"@init_record"},
    .{"@deinit"}, .{"@copy"}, .{"@clone"},
    .{"@index"}, .{"@set_index"}, .{"@index_addr"}, .{"@slice"},
    .{"@get"}, .{"@set"},
    .{"@send"},
});

pub fn sema_at_symbol(c: *cy.Chunk, name: []const u8, node: *ast.Node) !sema.ExprResult {
    const id = try c.sema.ensureSymbol(name);
    return c.semaConst(@intCast(id), c.sema.symbol_t, node);
}

/// `opt ?else '' == 'x'` parses as `opt ?else ('' == 'x')`. When the default is a comparison and the payload
/// is not a `bool`, say so instead of only ``Expected type `str`, got `bool`.``.
fn checkElseDefaultPrec(c: *cy.Chunk, op: []const u8, default_n: *ast.Node, payload_t: *cy.Type) !void {
    if (default_n.type() != .binExpr or payload_t.id() == bt.Bool) return;
    const bin = default_n.cast(.binExpr);
    switch (bin.op) {
        .equal_equal, .bang_equal, .less, .less_equal, .greater, .greater_equal, .and_op, .or_op => {},
        else => return,
    }
    const name = try c.sema.allocTypeName(payload_t);
    defer c.alloc.free(name);
    const op_name = switch (bin.op) {
        .equal_equal => "==",
        .bang_equal => "!=",
        .and_op => "and",
        .or_op => "or",
        else => bin.op.name(),
    };
    return c.reportErrorFmt("Expected type `{}`, got `bool`. `{}` binds weaker than `{}`, so this is the default value. Put the unwrap in parentheses: `(x {} default) {} y`.", &.{
        v(name), v(op), v(op_name), v(op), v(op_name),
    }, default_n);
}

pub fn sema_expr_cstr_template(c: *cy.Chunk, node: *ast.Node, template: *cy.sym.Template) !sema.ExprResult {
    return semaExprTemplate(c, node, template, null);
}

/// The left side of `?else`. `default_n` is the default value, or null for an `?else` block.
fn semaElseOption(c: *cy.Chunk, node: *ast.Node, default_n: ?*ast.Node) !sema.ExprResult {
    return semaExprTemplate(c, node, c.sema.option_tmpl, .{ .default_n = default_n });
}

const ElseCtx = struct {
    default_n: ?*ast.Node,
};

fn semaExprTemplate(c: *cy.Chunk, node: *ast.Node, template: *cy.sym.Template, else_ctx: ?ElseCtx) !sema.ExprResult {
    const res = try c.semaExpr(node, .{});
    if (!res.type.isInstanceOf(template)) {
        const type_name = try c.sema.allocTypeName(res.type);
        defer c.alloc.free(type_name);
        // Say which operator fits the value. Models write `!` on a `str` or a `?int`.
        var hint: []const u8 = "";
        if (template == c.sema.result_tmpl) {
            if (res.type.kind() == .option) {
                hint = std.fmt.bufPrint(&sema_hint.suggest_buf, " `!`, `!else` and `try` handle a `!T`. For `{s}`, use `.?` or `?else`.", .{type_name}) catch "";
            } else if (res.type.id() != bt.Never) {
                hint = std.fmt.bufPrint(&sema_hint.suggest_buf, " `!`, `!else` and `try` handle a `!T`. `{s}` has no error case, so use the value as it is.", .{type_name}) catch "";
            }
        } else if (template == c.sema.option_tmpl and res.type.kind() == .result) {
            hint = std.fmt.bufPrint(&sema_hint.suggest_buf, " `.?` and `?else` handle a `?T`. For `{s}`, use `!` or `!else`.", .{type_name}) catch "";
        } else if (else_ctx != null and res.type.id() != bt.Never) {
            // `s.ends_with('a') ?else false`: the value can not be `none`, so the default is never used.
            const default_src: []const u8 = if (else_ctx.?.default_n) |n| c.nodeString(n) else "";
            if (default_src.len > 0 and default_src.len <= 40 and std.mem.indexOfScalar(u8, default_src, '\n') == null) {
                hint = std.fmt.bufPrint(&sema_hint.suggest_buf, " This value is `{s}`, not an option. Remove `?else {s}`.", .{type_name, default_src}) catch "";
            } else if (else_ctx.?.default_n != null) {
                hint = std.fmt.bufPrint(&sema_hint.suggest_buf, " This value is `{s}`, not an option. Remove the `?else` default.", .{type_name}) catch "";
            } else {
                hint = std.fmt.bufPrint(&sema_hint.suggest_buf, " This value is `{s}`, not an option. Remove the `?else` block.", .{type_name}) catch "";
            }
        }
        return c.reportErrorFmt("Expected type instance of `{}`, found `{}`.{}", &.{v(template.head.name()), v(type_name), v(hint)}, node);
    }
    return res;
}
