const std = @import("std");
const cy = @import("cyber.zig");
const ir = cy.ir;
const bt = cy.types.BuiltinTypes;
const fmt = cy.fmt;
const v = fmt.v;
const ast = cy.ast;
const Sym = cy.Sym;
const sema = cy.sema;
const sema_local = cy.sema_local;
const sema_borrow = cy.sema_borrow;
const sema_call = cy.sema_call;
const sema_expr = cy.sema_expr;
const sema_access = cy.sema_access;
const sema_move = cy.sema_move;
const sema_lit = cy.sema_lit;
const sema_resolve = cy.sema_resolve;

pub fn semaTupleInit(c: *cy.Chunk, type_: *cy.Type, fields: []const cy.types.Field, lit: *ast.InitLit) !sema.ExprResult {
    if (lit.args.len != fields.len) {
        return c.reportErrorFmt("Expected {} args, found {}.", &.{v(fields.len), v(lit.args.len)}, @ptrCast(lit));
    }

    const args = try c.ir.allocArray(*ir.Expr, fields.len);
    var owner: ?sema.LocalId = null;
    {
        // An element is evaluated before a statement that a later element adds (`seqFlush`).
        const seq_start = c.seq_pending.items.len;
        defer sema_move.seqPop(c, seq_start);
        const record_borrows = c.scope_start_lit == @as(*ast.Node, @ptrCast(lit));
        for (fields, 0..) |field, i| {
            var arg = try c.semaExprCstr(lit.args.ptr[i], field.type);
            if (field.type.info.borrow_only) {
                try sema_borrow.noteBorrowOwner(c, sema_borrow.borrowOwner(c, arg), arg.type.info.ex_borrow);
                owner = sema_borrow.shorterOwner(c, owner, sema_borrow.borrowOwner(c, arg));
            }
            if (record_borrows and field.type.info.borrow_only) {
                try c.scope_start_borrows.append(c.alloc, .{
                    .owner = sema_borrow.borrowOwner(c, arg),
                    .ex = field.type.kind() == .ex_borrow,
                    .node = lit.args.ptr[i],
                });
            }
            arg = try sema_move.semaOwn(c, arg, lit.args.ptr[i]);
            args[i] = arg.ir;
            try sema_move.seqPush(c, &args[i], true, lit.args.ptr[i]);
        }
    }

    const init = try c.ir.newExpr(.init, type_, @ptrCast(lit), .{
        .nargs = @as(u32, @intCast(fields.len)), .args = args.ptr,
    });
    var res = sema.ExprResult.initOwned(init);
    res.data.value.parent_local = owner;
    return res;
}

pub fn semaInitPartialVector(c: *cy.Chunk, vector_t: *cy.types.PartialVector, init_n: *ast.InitLit) !sema.ExprResult {
    const nargs = init_n.args.len;
    if (nargs > vector_t.n) {
        return c.reportErrorFmt("Expected at most `{}` elements, found `{}`.", &.{v(vector_t.n), v(nargs)}, @ptrCast(init_n));
    }
    const args = try c.ir.allocArray(*ir.Expr, nargs + 1);
    args[0] = (try sema_lit.semaConst(c, nargs, c.sema.i64_t, @ptrCast(init_n))).ir;
    {
        const seq_start = c.seq_pending.items.len;
        defer sema_move.seqPop(c, seq_start);
        for (init_n.args.slice(), 0..) |arg_n, i| {
            var arg = try c.semaExprTarget(arg_n, vector_t.elem_t);
            arg = try sema_move.semaOwn(c, arg, arg_n);
            args[i+1] = arg.ir;
            try sema_move.seqPush(c, &args[i+1], true, arg_n);
        }
    }
    return sema_expr.semaPartialVector(c, &vector_t.base, args, @ptrCast(init_n));
}

pub fn semaInitVector(c: *cy.Chunk, vector_t: *cy.types.Vector, init_n: *ast.InitLit) !sema.ExprResult {
    const nargs = init_n.args.len;
    const args = try c.ir.allocArray(*ir.Expr, nargs);
    {
        const seq_start = c.seq_pending.items.len;
        defer sema_move.seqPop(c, seq_start);
        for (init_n.args.slice(), 0..) |arg_n, i| {
            var arg = try c.semaExprTarget(arg_n, vector_t.elem_t);
            arg = try sema_move.semaOwn(c, arg, arg_n);
            args[i] = arg.ir;
            try sema_move.seqPush(c, &args[i], true, arg_n);
        }
    }

    const loc = try c.ir.newExpr(.init, @ptrCast(vector_t), @ptrCast(init_n), .{
        .nargs = @intCast(nargs), .args = args.ptr,
    });
    return sema.ExprResult.initOwned(loc);
}

pub fn semaInitGenericArray(c: *cy.Chunk, generic_t: *cy.types.GenericVector, init_n: *ast.InitLit) !sema.ExprResult {
    const array_t = try sema.getVectorType(c, generic_t.elem_t, @intCast(init_n.args.len));
    return semaInitVector(c, array_t.cast(.vector), init_n);
}

/// Emits the default initializer. Ignores `@init_record`.
pub fn semaInitStruct(c: *cy.Chunk, struct_t: *cy.types.Struct, initializer: *ast.InitLit) !sema.ExprResult {
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
        const info = try sema_access.checkSymInitField(c, @ptrCast(sym), fieldName, pair.key);
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
    errdefer sema_move.seqPop(c, seq_start);
    // The local that the borrow fields keep alive the shortest.
    var owner: ?sema.LocalId = null;
    for (0..fieldNodes.len) |i| {
        const item = c.listDataStack.items[fieldsDataStart+i];
        const fieldT = struct_t.fields_ptr[i].type;
        if (item.node == null) {
            if (struct_t.fields_ptr[i].init_n != null) {
                ir_args[i] = (try semaFieldDefault(c, struct_t, i)).ir;
            } else {
                if (!struct_t.cstruct) {
                    return c.reportErrorFmt("Initialization requires the field `{}`.", &.{v(struct_t.fields_ptr[i].sym.head.name())}, node);
                }
                ir_args[i] = (try sema_lit.semaCZero(c, fieldT, node)).ir;
            }
        } else {
            var arg = try c.semaExprCstr(item.node.?, fieldT);
            if (fieldT.info.borrow_only) {
                try sema_borrow.noteBorrowOwner(c, sema_borrow.borrowOwner(c, arg), arg.type.info.ex_borrow);
                owner = sema_borrow.shorterOwner(c, owner, sema_borrow.borrowOwner(c, arg));
            }
            arg = try sema_move.semaOwn(c, arg, item.node.?);
            ir_args[i] = arg.ir;
            try sema_move.seqPush(c, &ir_args[i], true, item.node.?);
        }
    }
    sema_move.seqPop(c, seq_start);

    const loc = try c.ir.newExpr(.init, @ptrCast(struct_t), node, .{
        .nargs = @as(u32, @intCast(struct_t.fields_len)),
        .args = ir_args.ptr,
    });
    var res = sema.ExprResult.initOwned(loc);
    res.data.value.parent_local = owner;
    return res;
}

/// Checks the default value of the field `idx` where a struct literal leaves it out. The names in it are looked up
/// in the struct's declaration (its module and template parameters), not among the locals of the literal's code.
/// The value is owned, as an explicit field value is: a default that reads a place (`s str = G`) is copied, and a
/// `NoCopy` one is an error, so each literal gets its own value.
pub fn semaFieldDefault(c: *cy.Chunk, struct_t: *cy.types.Struct, idx: usize) !sema.ExprResult {
    const field = struct_t.fields_ptr[idx];
    try sema_resolve.pushSymResolveContext(c, @ptrCast(struct_t.base.sym()), field.init_n);
    defer sema_resolve.popResolveContext(c);
    const prev_hide = c.hide_locals_below;
    c.hide_locals_below = c.semaProcs.items.len;
    defer c.hide_locals_below = prev_hide;
    const res = try sema_expr.semaExprCstr(c, field.init_n.?, field.type);
    return sema_move.semaOwn(c, res, field.init_n.?);
}

/// `initializerId` is a record literal node.
/// If `ref_t` is provided, it becomes a ref initializer.
pub fn semaObjectInit2(c: *cy.Chunk, struct_t: *cy.types.Struct, initializer: *ast.InitLit) !sema.ExprResult {
    const sym = struct_t.base.sym();
    if (try c.getResolvedSym(@ptrCast(sym), "@init_record", @ptrCast(initializer))) |init_pairs| {
        return semaInitRecord(c, init_pairs, initializer);
    }
    return semaInitStruct(c, struct_t, initializer);
}

pub fn semaInitExpr(c: *cy.Chunk, node: *ast.InitExpr, cstr: sema.Cstr) !sema.ExprResult {
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
            const str = c.nodeString(node.left);
            return c.reportErrorFmt("Can not initialize enum case `{}`.", &.{v(str)}, node.left);
        },
        .union_case => {
            const str = c.nodeString(node.left);
            return c.reportErrorFmt("Can not initialize cunion case `{}`.", &.{v(str)}, node.left);
        },
        .choice_case => {
            const str = c.nodeString(node.left);
            return c.reportErrorFmt("Can not initialize choice case `{}`.", &.{v(str)}, node.left);
        },
        .template => {
            const str = c.nodeString(node.left);
            return c.reportErrorFmt("Expected a type, found type template. Expand `{}` to a type.", &.{v(str)}, node.left);
        },
        else => {
            const str = c.nodeString(node.left);
            return c.reportErrorFmt("Can not initialize `{}`.", &.{v(str)}, node.left);
        }
    }
}

pub fn semaInitLitTarget(c: *cy.Chunk, init_lit: *ast.InitLit, target_t: *cy.Type, return_infer_error: bool, assign_to_local: bool) !sema.ExprResult {
    const node: *ast.Node = @ptrCast(init_lit);
    if (target_t.sym().instance) |instance| {
        if (assign_to_local) {
            if (instance.getSymTemplate() == c.sema.span_tmpl) {
                // Overrides `Span[T].init_sequence` and extends the lifetime of the vector.
                const elem_t = instance.params[0].asPtr(*cy.Type);

                const vec_t = try sema.getVectorType(c, elem_t, @intCast(init_lit.args.len));
                const vec_var = try sema_local.reserveLocalName(c, "_vec", vec_t, true, true, node);
                c.varStack.items[vec_var].type = .dead;

                const args = try c.ir.allocArray(*ir.Expr, init_lit.args.len);
                // The elements are not registered as pending operands (`seqFlush`): `_vec` is reserved above and
                // declared below, and a local that is declared in between would break the order of the IR locals.
                for (init_lit.args.slice(), 0..) |arg, i| {
                    const res = try c.semaExprTarget(arg, elem_t);
                    args[i] = res.ir;
                }

                const vec_init = try sema_expr.semaVector(c, vec_t, args, node);
                try sema_expr.semaInitLocal(c, vec_var, vec_init, node);

                const vec = try sema_expr.semaLocal(c, vec_var, node);
                const borrow_t = try sema.getBorrowType(c, elem_t);
                const addr_of = try c.ir.newExpr(.address_of, borrow_t, node, .{
                    .expr = vec.ir,
                });
                const borrow = sema.ExprResult.init2(addr_of);

                var res = try sema_span(c, target_t, borrow, @intCast(args.len), node);
                res.data.value.has_aux_local = true;
                return res;
            }
        }
        if (instance.getSymTemplate() == c.sema.as_span_tmpl) {
            // Default to Slice[T].
            const elem_t = instance.params[0].asPtr(*cy.Type);
            const slice_t = try sema.get_slice_type(c, elem_t);
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
            return sema_lit.semaCZero(c, target_t, @ptrCast(init_lit));
        },
        .result => {
            const result_t = target_t.cast(.result);
            return semaInitLitTarget(c, init_lit, result_t.child_t, return_infer_error, false);
        },
        .vector => {
            var vec_t = target_t.cast(.vector);
            if (vec_t.n != init_lit.args.len) {
                vec_t = (try sema.getVectorType(c, vec_t.elem_t, @intCast(init_lit.args.len))).cast(.vector);
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
        return sema.ExprResult.initInferError(error.InitLit);
    } else {
        const type_name = try c.sema.allocTypeName(target_t);
        defer c.alloc.free(type_name);
        return c.reportErrorFmt("Can not infer initializer type `{}`.", &.{v(type_name)}, @ptrCast(init_lit));
    }
}

fn sema_object(c: *cy.Chunk, impl: sema.ExprResult, node: *ast.Node) !sema.ExprResult {
    var b: InitBuilder = .{ .c = c };
    try b.begin(c.sema.object_t, 1, node);
    const impl_ptr = try sema_expr.semaBitcast(c, impl, c.sema.ptr_void_t, node);
    try b.pushArg(impl_ptr, node);
    const loc = b.end();
    return sema.ExprResult.initOwned(loc);
}

fn semaInitPair(c: *cy.Chunk, pair_t: *cy.Type, key: sema.ExprResult, val: sema.ExprResult, node: *ast.Node) !sema.ExprResult {
    var b: InitBuilder = .{ .c = c };
    try b.begin(pair_t, 2, node);
    try b.pushArg(key, node);
    try b.pushArg(val, node);
    const loc = b.end();
    return sema.ExprResult.initOwned(loc);
}

pub fn sema_span(c: *cy.Chunk, span_t: *cy.Type, borrow: sema.ExprResult, len: i64, node: *ast.Node) !sema.ExprResult {
    const len_expr = try c.semaConst(@bitCast(len), c.sema.i64_t, node);
    var b: InitBuilder = .{ .c = c };
    try b.begin(span_t, 2, node);
    try b.pushArg(borrow, node);
    try b.pushArg(len_expr, node);
    const loc = b.end();
    return sema.ExprResult.initOwned(loc);
}

pub fn sema_init_seq2(c: *cy.Chunk, init_seq: *cy.Sym, args: []*ir.Expr, node: *ast.Node) !sema.ExprResult {
    const func_sym = try sema_call.requireFuncSym(c, init_seq, node);
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
    const borrow_t = try sema.getBorrowType(c, elem_t);
    if (args.len == 0) {
        const ptr = try c.semaConst(0, borrow_t, node);
        const init_span = try sema_span(c, init_span_t, ptr, 0, node);
        return c.semaCallFuncSym1(func_sym, node, init_span, node);
    } else {
        return sema_call_init_span(c, func_sym, init_span_t, borrow_t, elem_t, args, node);
    }
}

/// `{a, b}` without a target type is a `[]T` where `T` is the type of the first element.
pub fn semaInferSliceLit(c: *cy.Chunk, lit: *ast.InitLit) !sema.ExprResult {
    const node: *ast.Node = @ptrCast(lit);
    const nargs = lit.args.len;
    const args = try c.ir.allocArray(*ir.Expr, nargs);

    // An element is evaluated before a statement that a later element adds (`seqFlush`).
    const seq_start = c.seq_pending.items.len;
    errdefer sema_move.seqPop(c, seq_start);

    const first = lit.args.ptr[0];
    var res = try c.semaExpr(first, .{});
    res = try sema_move.semaOwn(c, res, first);
    const elem_t = res.type;
    args[0] = res.ir;
    try sema_move.seqPush(c, &args[0], true, first);
    for (lit.args.slice()[1..], 1..) |arg, i| {
        // The list has the type of its first element. A literal of another kind is not converted to it:
        // `{1, 'a'}` is not `{1, 97}` and `{1.5, 2}` is not `{1.5, 2.0}`. The same note is given in either order
        // when the first element is a `str`, an integer, a float or a `bool`: `{'a', 1}`.
        const elem_is_str = elem_t.id() == bt.Str;
        const elem_kind = elem_t.kind();
        const lit_name: ?[]const u8 = switch (arg.type()) {
            .string_lit, .string_multi_lit, .sq_string_lit, .sq_string_multi_lit, .raw_string_lit => if (!elem_is_str) "str" else null,
            .decLit, .hexLit, .binLit, .octLit => if (elem_is_str or elem_kind == .float or elem_kind == .bool) "int" else null,
            .floatLit => if (elem_is_str or elem_kind == .int or elem_kind == .bool) "float" else null,
            .trueLit, .falseLit => if (elem_is_str or elem_kind == .int or elem_kind == .float) "bool" else null,
            else => null,
        };
        if (lit_name) |name| {
            const elem_name = try c.sema.allocTypeName(elem_t);
            defer c.alloc.free(elem_name);
            return c.reportErrorFmt("Expected type `{}`, got `{}`. A list literal without a type takes the type of its first element and does not convert the others. Write the element type: `[]T{...}`.", &.{v(elem_name), v(name)}, arg);
        }
        res = try c.semaExprCstr(arg, elem_t);
        res = try sema_move.semaOwn(c, res, arg);
        args[i] = res.ir;
        try sema_move.seqPush(c, &args[i], true, arg);
    }
    sema_move.seqPop(c, seq_start);

    const slice_t = try sema.get_slice_type(c, elem_t);
    const init_seq = (try c.getResolvedSym(@ptrCast(slice_t.sym()), "@init_sequence", node)).?;
    const func_sym = try sema_call.requireFuncSym(c, init_seq, node);
    const span_t = func_sym.first.sig.params_ptr[0].get_type();
    const borrow_t = try sema.getBorrowType(c, elem_t);
    return sema_call_init_span(c, func_sym, span_t, borrow_t, elem_t, args, node);
}

fn semaInitSequence(c: *cy.Chunk, init_seq: *cy.Sym, lit: *ast.InitLit) !sema.ExprResult {
    const node: *ast.Node = @ptrCast(lit);
    const func_sym = try sema_call.requireFuncSym(c, init_seq, node);

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
    const borrow_t = try sema.getBorrowType(c, elem_t);
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
            defer sema_move.seqPop(c, seq_start);
            for (lit.args.slice(), 0..) |arg, i| {
                var res = try c.semaExprCstr(arg, elem_t);
                res = try sema_move.semaOwn(c, res, arg);
                args[i] = res.ir;
                try sema_move.seqPush(c, &args[i], true, arg);
            }
        }
        return sema_call_init_span(c, func_sym, span_t, borrow_t, elem_t, args, node);
    }
}

/// init_record or init_sequence.
fn sema_call_init_span(c: *cy.Chunk, init: *cy.sym.FuncSym, span_t: *cy.Type, borrow_t: *cy.Type, elem_t: *cy.Type, args: []*ir.Expr, node: *ast.Node) !sema.ExprResult {
    const vec_t = try sema.getVectorType(c, elem_t, @intCast(args.len));
    const loc = try c.ir.newExpr(.init, vec_t, node, .{
        .nargs = @intCast(args.len), .args = args.ptr,
    });
    const array_var = try sema_local.declareHiddenLocal(c, "_vec", vec_t, sema.ExprResult.init(loc, vec_t), node);
    const array = try sema_expr.semaLocal(c, array_var.id, node);
    const addr_of = try c.ir.newExpr(.address_of, borrow_t, node, .{
        .expr = array.ir,
    });
    const borrow = sema.ExprResult.init2(addr_of);
    const init_span = try sema_span(c, span_t, borrow, @intCast(args.len), node);
    const res = try c.semaCallFuncSym1(init, node, init_span, node);
    if (!elem_t.is_copyable()) {
        // Elements that can not be copied are moved. The initializer takes the bytes of the elements
        // (`@memcpy`), so the temporary vector is dead after the call and its elements are not destructed.
        c.varStack.items[array_var.id].type = .dead;
    }
    return res;
}

fn semaInitRecord(c: *cy.Chunk, init_pairs: *cy.Sym, init_n: *ast.InitLit) !sema.ExprResult {
    const node: *ast.Node = @ptrCast(init_n);
    const func_sym = try sema_call.requireFuncSym(c, init_pairs, node);

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
    const borrow_t = try sema.getBorrowType(c, pair_t);
    if (init_n.args.len == 0) {
        const ptr = try c.semaConst(0, borrow_t, node);
        const init_span = try sema_span(c, span_t, ptr, 0, node);
        return c.semaCallFuncSym1(func_sym, node, init_span, node);
    } else {
        const pairs = try c.ir.allocArray(*ir.Expr, init_n.args.len);
        const seq_start = c.seq_pending.items.len;
        errdefer sema_move.seqPop(c, seq_start);
        for (init_n.args.slice(), 0..) |arg, i| {
            if (arg.type() != .keyValue) {
                return c.reportError("Expected key value pair.", arg);
            }
            const kv = arg.cast(.keyValue);

            var key: sema.ExprResult = undefined;
            if (kv.key.type() == .ident) {
                key = try c.semaString(kv.key.cast(.ident).name.slice(), kv.key);
            } else {
                key = try c.semaExprCstr(kv.key, key_t);
                key = try sema_move.semaOwn(c, key, kv.key);
            }
            var val = try c.semaExprCstr(kv.value, val_t);
            val = try sema_move.semaOwn(c, val, kv.value);
            const pair = try semaInitPair(c, pair_t, key, val, arg);
            pairs[i] = pair.ir;
            try sema_move.seqPush(c, &pairs[i], true, arg);
        }
        sema_move.seqPop(c, seq_start);
        return sema_call_init_span(c, func_sym, span_t, borrow_t, pair_t, pairs, node);
    }
}

pub fn semaInit2(c: *cy.Chunk, init_t: *cy.Type, arg0: sema.ExprResult, arg1: sema.ExprResult, node: *ast.Node) !sema.ExprResult {
    var b: InitBuilder = .{ .c = c };
    try b.begin(init_t, 2, node);
    try b.pushArg2(arg0, arg0.type, node);
    try b.pushArg2(arg1, arg1.type, node);
    const irIdx = b.end();
    return sema.ExprResult.initOwned(irIdx);
}

pub fn semaWrapSome(c: *cy.Chunk, option_t: *cy.types.Option, res: sema.ExprResult, node: *ast.Node) !sema.ExprResult {
    // `?&T` and an option of a borrow container borrow from what the payload borrows from.
    const owner: ?sema.LocalId = if (option_t.base.info.borrow_only) sema_borrow.borrowOwner(c, res) else null;
    const owned = try sema_move.semaOwn(c, res, node);
    var some: sema.ExprResult = undefined;
    if (option_t.zero_union) {
        some = try sema_expr.semaBitcast(c, owned, &option_t.base, node);
        some.owned = true;
    } else {
        const tag = try c.semaConst(1, c.sema.i64_t, node);
        some = try semaInit2(c, &option_t.base, tag, owned, node);
    }
    if (owner != null and some.resType == .value) {
        some.data.value.parent_local = owner;
    }
    return some;
}

pub fn semaInitCunionCase(c: *cy.Chunk, union_t: *cy.Type, case: u32, payload: sema.ExprResult, node: *ast.Node) !sema.ExprResult {
    var b: InitBuilder = .{ .c = c };
    try b.begin(union_t, 1, node);
    const case_arg = try c.ir.newExpr(.init_case, union_t, node, .{
        .child = payload.ir,
        .case = case,
    });
    const final_payload = sema.ExprResult.init2(case_arg);
    try b.pushArg2(final_payload, union_t, node);
    const irIdx = b.end();
    return sema.ExprResult.initOwned(irIdx);
}

pub fn semaInitCunionNoPayload(c: *cy.Chunk, union_t: *cy.Type, case: u32, node: *ast.Node) !sema.ExprResult {
    // No payload type.
    var b: InitBuilder = .{ .c = c };
    try b.begin(union_t, 1, node);
    const payload = try c.semaVoid(node);
    const case_arg = try c.ir.newExpr(.init_case, union_t, node, .{
        .child = payload.ir,
        .case = case,
    });
    const final_payload = sema.ExprResult.init2(case_arg);
    try b.pushArg2(final_payload, union_t, node);
    const irIdx = b.end();
    return sema.ExprResult.initOwned(irIdx);
}

pub fn semaInitChoice(c: *cy.Chunk, union_t: *cy.Type, case: u32, val: u32, payload: sema.ExprResult, node: *ast.Node) !sema.ExprResult {
    var b: InitBuilder = .{ .c = c };
    try b.begin(union_t, 2, node);
    const tag = try c.semaConst(val, c.sema.i64_t, node);
    try b.pushArg(tag, node);
    const case_arg = try c.ir.newExpr(.init_case, union_t, node, .{
        .child = payload.ir,
        .case = case,
    });
    const final_payload = sema.ExprResult.init2(case_arg);
    try b.pushArg2(final_payload, union_t, node);
    const irIdx = b.end();
    return sema.ExprResult.initOwned(irIdx);
}

pub fn semaInitChoiceNoPayload(c: *cy.Chunk, case: *cy.sym.ChoiceCase, node: *ast.Node) !sema.ExprResult {
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
    const final_payload = sema.ExprResult.init2(case_arg);
    try b.pushArg2(final_payload, case.type, node);
    const irIdx = b.end();
    return sema.ExprResult.initOwned(irIdx);
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
            .nargs = @as(u32, @intCast(numFields)), .args = b.irArgs.ptr,
        });
        b.argIdx = 0;
        b.fields = type_.fields().?;
    }

    pub fn pushArg(b: *InitBuilder, expr: sema.ExprResult, node: *ast.Node) !void {
        try b.pushArg2(expr, b.fields[b.argIdx].type, node);
    }

    pub fn pushArg2(b: *InitBuilder, expr: sema.ExprResult, exp_t: *cy.Type, node: *cy.ast.Node) !void {
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
