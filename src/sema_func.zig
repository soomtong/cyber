const std = @import("std");
const cy = @import("cyber.zig");
const C = @import("capi.zig");
const bt = cy.types.BuiltinTypes;
const ast = cy.ast;
const sema = cy.sema;
const sema_borrow = cy.sema_borrow;
const sema_call = cy.sema_call;
const sema_expr = cy.sema_expr;
const sema_hint = cy.sema_hint;
const sema_lit = cy.sema_lit;
const sema_local = cy.sema_local;
const sema_move = cy.sema_move;
const sema_resolve = cy.sema_resolve;
const sema_type = cy.sema_type;
const cte = cy.cte;
const log = cy.log.scoped(.sema_func);
const fmt = cy.fmt;
const v = fmt.v;
const ir = cy.ir;
const Value = cy.Value;

const FuncResultKind = enum(u8) {
    rt,
    rt_sema,
    ct,

    // NOTE: See if most functions can return the final ExprResult to avoid bubbling up args. Try to remove `rt`, `rt_sema`.
    expr_res,
};

pub const FuncSymResult = struct {
    func: *cy.Func,
    kind: FuncResultKind,
    data: FuncResultUnion,
};

const FuncResultUnion = union {
    rt: struct {
        args: [*]*ir.Expr,
        nargs: u32,
        ret_parent_scope_local: ?u32,
    },
    expr_res: sema.ExprResult,
    ct: sema.ExprResult,
};

const FuncSigCtResult = struct {
    arg_start: usize,
    argt_start: usize,
};

pub const FuncResult = struct {
    func: *cy.Func,
    kind: FuncResultKind,
    data: FuncResultUnion,
};

const ArgType = enum {
    standard,
    receiver,
    pre_resolved,
    skip,
};

const ResolvedArgType = enum {
    null,
    rt,
    template,
    ct,
    incompat,
};

pub const Argument = struct {
    type: ArgType,

    /// This is wasteful since only pre_resolved uses `data`.
    /// The resolved arg result is stored together to avoid building two lists.
    data: union {
        pre_resolved: sema.ExprResult,
        receiver: sema.ExprResult,
    },
    resolve_t: ResolvedArgType,
    res: union {
        rt: sema.ExprResult,
        ct: cy.TypeValue,
        template: cy.TypeValue,
        incompat: void,
    },
    node: *ast.Node,

    pub fn init(node: *ast.Node) Argument {
        return .{ .type = .standard, .data = undefined, .resolve_t = .null, .res = undefined, .node = node };
    }

    pub fn initPreResolved(node: *ast.Node, res: sema.ExprResult) Argument {
        return .{
            .type = .pre_resolved,
            .data = .{ .pre_resolved = res },
            .resolve_t = .null,
            .res = undefined,
            .node = node,
        };
    }

    pub fn initReceiver(node: *ast.Node, res: sema.ExprResult) Argument {
        return .{
            .type = .receiver,
            .data = .{ .receiver = res },
            .resolve_t = .null,
            .res = undefined,
            .node = node,
        };
    }
};

const MatchGenericFuncCtResult = struct {
    func: *cy.Func,
    res: sema.ExprResult,
};

/// With `overloaded`, an argument that the template can not take returns null with `match_err.rematch` (see
/// `matchTemplateArgCt`), so the call tries the next overload.
pub fn matchGenericFuncCt(c: *cy.Chunk, template: *cy.sym.FuncTemplate,
    pre_args: []const Argument, end_args: []const *ast.Node, cstr: cte.CallCstr, overloaded: bool,
    match_err: *FuncMatchError, node: *ast.Node) !?MatchGenericFuncCtResult {
    _ = cstr;

    try sema_resolve.ensureResolvedFuncTemplate(c, template);

    const nargs = pre_args.len + end_args.len;
    
    if (template.func_params.len != nargs) {
        match_err.* = FuncMatchError.init(undefined, 0, undefined);
        return null;
    }

    // Prepare template context.
    try sema_resolve.pushSymResolveContext(c, @ptrCast(template), node);
    var template_ctx = sema_resolve.saveResolveContext(c);
    template_ctx.has_ct_params = true;
    defer template_ctx.deinit(c);

    const arg_start = c.valueStack.items.len;
    const argt_start = c.typeStack.items.len;

    // First reserve the ct args since the upper bound is known.
    try c.valueStack.resize(c.alloc, arg_start + nargs);
    try c.typeStack.resize(c.alloc, argt_start + nargs);

    var arg_idx: u32 = 0;
    // The callee owns the arguments once it is called, like in `matchFuncCt`: it binds them as compile-time
    // params and destructs them when its block ends. Destructing them here as well freed a string argument
    // twice (`fn f(x %T)` evaluated with `'abc'`, F-112).
    var called = false;
    defer {
        if (!called) {
            for (0..arg_idx) |i| {
                const arg = c.valueStack.items[arg_start + i];
                const arg_t = c.typeStack.items[argt_start + i];

                // Only reference args are owned by the callsite.
                if (arg_t.isObjectLike()) {
                    c.heap.destructValue2(arg_t, arg);
                }
            }
        }
        c.valueStack.items.len = arg_start;
        c.typeStack.items.len = argt_start;
    }

    const params = template.sig.params();
    for (0..nargs) |i| {
        var arg: Argument = undefined;
        if (i < pre_args.len) {
            arg = pre_args[i];
        } else {
            arg = Argument.init(end_args[i - pre_args.len]);
        }
        const final_arg = try matchTemplateArgCt(c, params[i], arg, template, &template_ctx, i, overloaded);
        if (final_arg.resolve_t == .ct) {
            c.valueStack.items[arg_start + arg_idx] = final_arg.res.ct.value;
            c.typeStack.items[argt_start + arg_idx] = final_arg.res.ct.type;
            arg_idx += 1;
        } else if (final_arg.resolve_t == .template) {
            const name = template.func_params[i].name_type.as_name();
            try template_ctx.initCtParam(c.alloc, name, final_arg.res.template);
        } else if (final_arg.resolve_t == .incompat) {
            // Only for an overload.
            match_err.* = FuncMatchError.init(params[i], i + 1, c.sema.void_t);
            match_err.rematch = true;
            return null;
        }
    }

    const gen_func = try genFunc(c, template, &template_ctx, node);

    const ct_args = c.valueStack.items[arg_start..arg_start+arg_idx];
    // Only a function with a body binds the arguments. A function that the host evaluates reads them and
    // leaves them to the callsite.
    called = gen_func.type == .userFunc and gen_func.data.userFunc.eval == null;
    const res = try cte.evalCall(c, gen_func, ct_args, node);
    return .{
        .func = gen_func,
        .res = res,
    };
}

const MatchGenericFuncRt = struct {
    func: *cy.Func,
    nargs: usize,
    ret_parent_scope_local: ?u32,
};

pub fn matchGenericFuncRt(c: *cy.Chunk, func: *cy.Func,
    pre_args: []const Argument, end_args: []const *ast.Node, args: []*ir.Expr,
    overloaded: bool, match_err: *FuncMatchError, node: *ast.Node) !?MatchGenericFuncRt {

    const template = func.data.generic;

    try sema_resolve.ensureResolvedFuncTemplate(c, template);

    const nargs = pre_args.len + end_args.len;
    
    if (template.func_params.len != nargs) {
        match_err.* = FuncMatchError.init(undefined, 0, undefined);
        return null;
    }

    // Prepare template context.
    try sema_resolve.pushFuncResolveContext(c, func, node);
    var template_ctx = sema_resolve.saveResolveContext(c);
    template_ctx.has_ct_params = true;
    defer template_ctx.deinit(c);

    var arg_idx: u32 = 0;
    var borrows: ArgBorrows = .{};

    // An argument is evaluated before a statement that a later argument adds (`sema_move.seqFlush`).
    const seq_start = c.seq_pending.items.len;
    defer sema_move.seqPop(c, seq_start);

    const params = template.sig.params();
    for (0..nargs) |i| {
        var arg: Argument = undefined;
        if (i < pre_args.len) {
            arg = pre_args[i];
        } else {
            arg = Argument.init(end_args[i - pre_args.len]);
        }
        const pending_start: u32 = @intCast(c.borrow_pending.items.len);
        const final_arg = try matchTemplateArg(c, params[i], arg, template, &template_ctx, i, overloaded, false);
        if (final_arg.resolve_t == .incompat) {
            // Only for an overload: the argument does not have the type of the parameter, or the infer
            // parameters can not be bound from it. The call tries the next overload (`matchFuncSym`).
            match_err.* = FuncMatchError.init(params[i], i + 1, c.sema.void_t);
            match_err.rematch = true;
            return null;
        }
        if (final_arg.resolve_t == .rt) {
            args[arg_idx] = final_arg.res.rt.ir;
            const arg_res = final_arg.res.rt;
            // The argument matched its parameter, so an exclusive borrow argument is for a `&&T` parameter.
            try borrows.add(c, arg_idx, arg_res, arg_res.type.kind() == .ex_borrow, pending_start, arg.node);
            if (arg_res.resType == .value and !arg_res.addressable) {
                try sema_move.seqPush(c, &args[arg_idx], arg_res.owned, arg.node);
            } else {
                try sema_move.seqPushTakeArg(c, &args[arg_idx], arg.node);
            }
            arg_idx += 1;
        } else if (final_arg.resolve_t == .template) {
            const name = template.func_params[i].name_type.as_name();
            try template_ctx.initCtParam(c.alloc, name, final_arg.res.template);
        }
    }

    try borrows.check(c, arg_idx);

    if (tookReceiver(c, pre_args) and arg_idx > 0) {
        try sema_move.finishGlobalTake(c, args[1..arg_idx], borrows.nodes[1..arg_idx]);
    }

    const func_instance = try genFunc(c, template, &template_ctx, node);
    const scope_idx = func_instance.sig.scope_param_idx;
    if (scope_idx != cy.NullU8 and scope_idx < arg_idx) try borrows.lendScopeArg(c, scope_idx, arg_idx);

    return .{
        .func = func_instance,
        .nargs = arg_idx,
        .ret_parent_scope_local = null,
    };
}

// pub fn matchGenericFunc(c: *cy.Chunk, template: *cy.sym.FuncTemplate,
//     pre_args: []const Argument, end_args: []const *ast.Node, req_value: bool, node: *ast.Node) !sema.ExprResult {

//     const ct_call = req_value or template.ct;
//     var match_err: FuncMatchError = undefined;
//     if (ct_call) {
//         const call_cstr = cte.CallCstr{
//             .req_value = req_value,
//         };
//         const res = (try matchGenericFuncCt(c, template, pre_args, end_args, call_cstr, &match_err, node)) orelse {
//             return reportCallFuncMismatch(c, pre_args, end_args, template.head.name(), template.sig, match_err, node);
//         };
//         return res.res;
//     } else {
//         const args = try c.ir.allocArray(*ir.Expr, pre_args.len + end_args.len);
//         const res = (try matchGenericFuncRt(c, template, pre_args, end_args, args, false, &match_err, node)) orelse {
//             return reportCallFuncMismatch(c, pre_args, end_args, template.head.name(), template.sig, match_err, node);
//         };
//         const call_ir = try c.ir.newExpr(.call, res.func.sig.ret, node, .{
//             .func = res.func,
//             .numArgs = @intCast(res.nargs),
//             .args = args.ptr,
//         });
//         return sema.ExprResult.initOwned(call_ir);
//     }
// }

fn genFunc(c: *cy.Chunk, template: *cy.sym.FuncTemplate, template_ctx: *sema_resolve.ResolveContext, node: *ast.Node) !*cy.Func {
    // Build template args from context.
    const arg_start = c.valueStack.items.len;
    const argt_start = c.typeStack.items.len;
    defer {
        // for (c.valueStack.items[arg_start..], 0..) |value, i| {
        //     const val_t = c.typeStack.items[argt_start + i];
        //     c.heap.destructValue2(val_t, value);
        // }
        c.valueStack.items.len = arg_start;
        c.typeStack.items.len = argt_start;
    }
    for (template.params) |tparam| {
        const param = template_ctx.ct_params.get(tparam.name).?;
        const param_t = param.getType();
        try c.typeStack.append(c.alloc, param_t);
        try c.valueStack.append(c.alloc, param.value);
    }

    // Generate function.
    const args = c.valueStack.items[arg_start..];
    const arg_types = c.typeStack.items[argt_start..];
    return cy.template.expandResolvedFuncTemplate(c, template, arg_types, args, true, node);
}

fn getVmCVariantFunc(c: *cy.Chunk, extern_func: *cy.Func, args: []*ir.Expr, node: *ast.Node) !*cy.Func {
    // Specialize on variadic signature.
    const param_start = c.func_param_stack.items.len;
    defer c.func_param_stack.items.len = param_start;

    const params = extern_func.sig.params();
    for (params[0..params.len-1]) |param| {
        try c.func_param_stack.append(c.alloc, param);
    }
    for (args[params.len-1..]) |varg| {
        try c.func_param_stack.append(c.alloc, sema.FuncParam.init(varg.type));
    }
    try sema_local.checkArgLimit(c, args.len, node);
    const sig = try c.sema.ensureFuncSig(c.func_param_stack.items[param_start..], extern_func.sig.ret);

    const res = try c.sema.vm_c_variadic_funcs.getOrPut(c.alloc, .{ .func = extern_func, .sig = sig });
    if (!res.found_existing) {
        const config = cy.sym.FuncConfig{
            .is_method = false,
            .extern_ = true,
        };
        const func = try c.createFunc(.vm_extern_variant, extern_func.parent, config, extern_func.decl);
        func.data = .{
            .vm_extern_variant = .{ .extern_func = extern_func },
        };
        c.resolveFuncInfo(func, sig);

        try c.funcs.append(c.alloc, func);

        try sema_resolve.resolveFuncVariant(c, func, false, node);
        res.value_ptr.* = func;

        if (!c.has_extern_func) {
            c.has_extern_func = true;
        }
    }
    return res.value_ptr.*;
}

pub fn matchFuncRt(c: *cy.Chunk, func: *cy.Func, pre_args: []const Argument,
    end_args: []const *ast.Node, node: *ast.Node) !FuncResult {

    var match_err: FuncMatchError = undefined;

    switch (func.type) {
        .reserved => {
            const name = try c.sema.newFuncName(c.alloc, func, .{});
            defer c.alloc.free(name);
            return c.reportErrorFmt("Cannot invoke the reserved function `{}`.", &.{v(name)}, node);
        },
        .generic => {
            const args = try c.ir.allocArray(*ir.Expr, pre_args.len + end_args.len);
            const res = (try matchGenericFuncRt(c, func, pre_args, end_args, args, false, &match_err, node)) orelse {
                return reportCallFuncMismatch2(c, pre_args, end_args, func, match_err, node);
            };
            const nargs = res.nargs;
            return .{
                .func = res.func,
                .kind = .rt,
                .data = .{ .rt = .{
                    .args = args.ptr,
                    .nargs = @intCast(nargs),
                    .ret_parent_scope_local = null,
                }},
            };
        },
        .host_builtin => {
            std.debug.assert(pre_args.len == 0);
            if (end_args.len != func.sig.params_len) {
                const name = try c.sema.newFuncName(c.alloc, func, .{});
                defer c.alloc.free(name);
                return c.reportErrorFmt("Expected {} arguments for `{}`, found {}.", &.{v(func.sig.params_len), v(func.name()), v(end_args.len)}, node);
            }
            const ctx = cy.BuiltinContext{
                .func = func, 
                .args = end_args.ptr,
                .node = node,
            };
            var res: sema.ExprResult = undefined;
            if (!func.data.host_builtin.ptr(c, &ctx, &res)) {
                return error.CompileError;
            }
            return .{
                .func = func,
                .kind = .expr_res,
                .data = .{ .expr_res = res },
            };
        },
        else => {
            const args = try c.ir.allocArray(*ir.Expr, pre_args.len + end_args.len);
            const nargs = args.len;
            const res = (try matchFuncSig(c, func.sig, pre_args, end_args, args, false, false, &match_err)) orelse {
                return reportCallFuncMismatch2(c, pre_args, end_args, func, match_err, node);
            };
            var final_func = func;
            if (func.type == .extern_ and func.data.extern_.vm_variadic) {
                final_func = try getVmCVariantFunc(c, func, args, node);
            }
            return .{
                .func = final_func,
                .kind = .rt,
                .data = .{ .rt = .{
                    .args = args.ptr,
                    .nargs = @intCast(nargs),
                    .ret_parent_scope_local = res.ret_parent_scope_local,
                }},
            };
        },
    }
}

pub fn matchFunc(c: *cy.Chunk, func: *cy.sym.Func, pre_args: []const Argument, end_args: []const *ast.Node, req_value: bool, node: *ast.Node) !FuncResult {
    // Assumes resolved func for `const_eval_only` and signature.
    const ct_call = req_value or func.info.const_eval_only;
    if (ct_call) {
        const call_cstr = cte.CallCstr{
            .req_value = req_value,
        };
        return matchFuncCt(c, func, pre_args, end_args, call_cstr, node);
    } else {
        return matchFuncRt(c, func, pre_args, end_args, node);
    }
}

pub const FuncMatchError = struct {
    // 0 indicates wrong number of arguments.
    // 1 indicates the first argument is incompatible.
    arg: usize,
    arg_t: *cy.Type,
    param: sema.FuncParam,

    /// The argument was not reported and has no type to name (`arg_t` is not its type): an inferred lambda
    /// whose body does not have the result type of the parameter (`error.LambdaResult`), a literal that needs
    /// a target type and can not be made for the parameter (`none`, `.red`, `{1, 2}`), or any mismatch of an
    /// overload that infers template parameters. Matching the overload alone reports the error
    /// (`matchFuncSym`).
    rematch: bool = false,

    fn init(param: sema.FuncParam, arg: usize, arg_t: *cy.Type) FuncMatchError {
        return .{
            .arg = arg,
            .arg_t = arg_t,
            .param = param,
        };
    }
};

pub fn matchFuncSigCt(c: *cy.Chunk, sig: *cy.FuncSig, pre_args: []const Argument,
    args: []const *ast.Node, cstr: cte.CallCstr, match_err: *FuncMatchError, node: *ast.Node) !?FuncSigCtResult {

    _ = node;

    const params = sig.params();
    if (params.len != pre_args.len + args.len) {
        match_err.* = FuncMatchError.init(undefined, 0, undefined);
        return null;
    }

    const arg_start = c.valueStack.items.len;
    const argt_start = c.typeStack.items.len;

    var arg_idx: usize = 0;
    var matched = false;

    // First reserve the ct args since the exact amount is known.
    try c.valueStack.resize(c.alloc, arg_start + params.len);
    try c.typeStack.resize(c.alloc, argt_start + params.len);
    defer {
        if (!matched) {
            for (0..arg_idx) |i| {
                const arg = c.valueStack.items[arg_start + i];
                const arg_t = c.typeStack.items[argt_start + i];

                c.heap.destructValue2(arg_t, arg);
            }
            c.valueStack.items.len = arg_start;
            c.typeStack.items.len = argt_start;
        }
    }

    while (arg_idx < pre_args.len) : (arg_idx += 1) {
        var matched_arg: bool = undefined;
        const value = try matchPreArgCt(c, pre_args[arg_idx], params[arg_idx], cstr.req_value, &matched_arg);

        if (!matched_arg) {
            match_err.* = FuncMatchError.init(params[arg_idx], arg_idx + 1, value.type);
            return null;
        }
        c.valueStack.items[arg_start + arg_idx] = value.value;
        c.typeStack.items[argt_start + arg_idx] = value.type;
    }

    while (arg_idx < params.len) : (arg_idx += 1) {
        var matched_arg: bool = undefined;
        const value = try matchArgCt(c, args[arg_idx - pre_args.len], params[arg_idx], cstr.req_value, &matched_arg);

        if (!matched_arg) {
            match_err.* = FuncMatchError.init(params[arg_idx], arg_idx + 1, value.type);
            return null;
        }
        c.valueStack.items[arg_start + arg_idx] = value.value;
        c.typeStack.items[argt_start + arg_idx] = value.type;
    }

    matched = true;
    return .{
        .arg_start = arg_start,
        .argt_start = argt_start,
    };
}

const MatchFuncSigResult = struct {
    ret_parent_scope_local: ?u32,
};

/// `exact` disables implicit conversions so an argument only matches a parameter of the same type.
/// It is the first pass of overload resolution (F-21).
pub fn matchFuncSig(c: *cy.Chunk, sig: *cy.FuncSig, pre_args: []const Argument, end_args: []const *ast.Node,
    args: []*ir.Expr, overloaded: bool, exact: bool, match_err: *FuncMatchError) !?MatchFuncSigResult {

    const params = sig.params();
    const nargs = pre_args.len + end_args.len;
    if (params.len != nargs) {
        // Continue if at least has variadic minimum.
        if (params.len == 0 or !(params[params.len-1].get_type().kind() == .c_variadic and nargs >= params.len - 1)) {
            match_err.* = FuncMatchError.init(undefined, 0, undefined);
            return null;
        }
    }

    const capture_param_scope = sig.scope_param_idx != cy.NullU8;
    var ret_parent_scope_local: ?u32 = null;

    var borrows: ArgBorrows = .{};
    const call_pending_start = c.borrow_pending.items.len;
    var scope_arg_idx: ?u32 = null;

    var arg_idx: u32 = 0;

    // An argument is evaluated before a statement that a later argument adds (`sema_move.seqFlush`).
    const seq_start = c.seq_pending.items.len;
    defer sema_move.seqPop(c, seq_start);

    for (0..nargs) |i| {
        var arg: Argument = undefined;
        if (i < pre_args.len) {
            arg = pre_args[i];
            if (arg.type == .skip) {
                arg_idx += 1;
                continue;
            }
        } else {
            arg = Argument.init(end_args[i - pre_args.len]);
        }

        var param: sema.FuncParam = undefined;
        if (i >= params.len) {
            // C variadic arg.
            param = params[params.len-1];
        } else {
            param = params[i];
        }

        var match: bool = undefined;
        const pending_start: u32 = @intCast(c.borrow_pending.items.len);
        const arg_res = try matchArg(c, arg, param, overloaded, exact, &match);
        if (!match) {
            match_err.* = FuncMatchError.init(param, arg_idx + 1, arg_res.type);
            match_err.rematch = arg_res.resType == .infer_error;
            return null;
        }
        if (capture_param_scope and sig.scope_param_idx == i) {
            ret_parent_scope_local = arg_res.recParentLocal();
            scope_arg_idx = arg_idx;
        }
        try borrows.add(c, arg_idx, arg_res, param.get_type().kind() == .ex_borrow, pending_start, arg.node);
        args[arg_idx] = arg_res.ir;
        if (arg_res.resType == .value and !arg_res.addressable) {
            try sema_move.seqPush(c, &args[arg_idx], arg_res.owned, arg.node);
        } else {
            try sema_move.seqPushTakeArg(c, &args[arg_idx], arg.node);
        }
        arg_idx += 1;
    }

    try borrows.check(c, arg_idx);
    if (scope_arg_idx) |idx| try borrows.lendScopeArg(c, idx, arg_idx);

    if (tookReceiver(c, pre_args) and arg_idx > 0) {
        try sema_move.finishGlobalTake(c, args[1..arg_idx], borrows.nodes[1..arg_idx]);
    }

    // The result borrows only from the `scope` argument, so the owners that the other arguments note end with the
    // call.
    if (c.borrow_pending.items.len > call_pending_start) {
        var keep: []const sema.BorrowOwner = &.{};
        if (scope_arg_idx) |idx| keep = c.borrow_pending.items[borrows.pending_start[idx]..borrows.pending_end[idx]];
        std.mem.copyForwards(sema.BorrowOwner, c.borrow_pending.items[call_pending_start..], keep);
        c.borrow_pending.items.len = call_pending_start + keep.len;
    }

    return .{
        .ret_parent_scope_local = ret_parent_scope_local,
    };
}

/// The borrows that the arguments of one call hold. All arguments are alive inside the call, so an exclusive borrow
/// can not share its owner with another argument. `matchFuncSig` and `matchGenericFuncRt` both check it.
const ArgBorrows = struct {
    // Owners borrowed by each argument, to reject an exclusive borrow next to another borrow of the same local.
    owners: [256]?sema.LocalId = @splat(null),
    ex: [256]bool = @splat(false),
    // The local that an exclusive borrow argument for a `&&T` parameter is read through.
    ex_via: [256]?sema.LocalId = @splat(null),
    ex_field: [256]u16 = undefined,
    nodes: [256]*ast.Node = undefined,
    results: [256]sema.ExprResult = undefined,
    // The other owners that each argument notes (`if c: &y else &a[0]`) in `Chunk.borrow_pending`.
    pending_start: [256]u32 = @splat(0),
    pending_end: [256]u32 = @splat(0),

    /// Records argument `idx`. `param_ex` is whether its parameter is `&&T`. The argument noted its other owners in
    /// `borrow_pending` from `pending_start`.
    fn add(self: *ArgBorrows, c: *cy.Chunk, idx: u32, arg_res: sema.ExprResult, param_ex: bool, pending_start: u32,
        node: *ast.Node) !void {
        self.pending_start[idx] = pending_start;
        self.pending_end[idx] = @intCast(c.borrow_pending.items.len);
        self.owners[idx] = sema_borrow.borrowOwner(c, arg_res);
        if (!arg_res.type.isManaged() and !arg_res.type.info.borrow_only and !arg_res.type.isPointer()) {
            // A plain value (`self.pos`) is copied into the call. It borrows nothing.
            self.owners[idx] = null;
        }
        self.ex[idx] = arg_res.type.kind() == .ex_borrow;
        if (self.ex[idx] and param_ex and sema_borrow.readThroughShared(arg_res.ir)) {
            return c.reportError("Cannot use an exclusive borrow that is read through a shared borrow.", node);
        }
        // A value that contains an exclusive borrow (`Holder{r=&&f}`) gives the callee the same access.
        if ((self.ex[idx] and param_ex) or
            (arg_res.type.kind() != .ex_borrow and arg_res.type.info.ex_borrow))
        {
            self.ex_via[idx] = arg_res.recParentLocal();
            self.ex_field[idx] = sema_borrow.borrowField(c, arg_res);
        }
        self.nodes[idx] = node;
        self.results[idx] = arg_res;
    }

    /// A function can store a borrow that its `scope` parameter gives behind another borrow parameter
    /// (`fn (&&Outer) set(scope p &int): self.v = View{a=p}`, `sema_borrow.checkFieldOwner`). So the value behind
    /// each other borrow argument of a borrow container type borrows what the `scope` argument borrows, like a field
    /// assignment: it can not outlive it, and it keeps it borrowed.
    fn lendScopeArg(self: *const ArgBorrows, c: *cy.Chunk, scope_idx: u32, nargs: u32) !void {
        const scope_arg = self.results[scope_idx];
        if (!scope_arg.type.info.borrow_only) return;
        for (0..nargs) |i| {
            if (i == scope_idx) continue;
            const arg = self.results[i];
            switch (arg.type.kind()) {
                .borrow, .ex_borrow => {},
                else => continue,
            }
            const child = arg.type.getRefLikeChild() orelse continue;
            if (!child.info.borrow_only) continue;
            try sema_borrow.checkFieldBorrowOutlives(c, arg, scope_arg, self.nodes[scope_idx]);
            try sema_borrow.addFieldBorrowLoan(c, arg, scope_arg);
        }
    }

    /// Checks the first `nargs` arguments.
    fn check(self: *const ArgBorrows, c: *cy.Chunk, nargs: u32) !void {
        for (0..nargs) |i| {
            if (!self.ex[i]) {
                if (self.ex_via[i]) |via| {
                    try sema_borrow.checkExclusiveBorrowOfField(c, via, self.ex_field[i], false, self.nodes[i]);
                }
                continue;
            }
            // The callee can change the value, so no other local can hold a borrow of it. An exclusive borrow that is
            // already in a local or a field (`r.grow()` of `r := &&f`, `h.r.grow()`) is checked here, where it is used.
            if (self.ex_via[i]) |via| {
                try sema_borrow.checkExclusiveBorrowOfField(c, via, self.ex_field[i], false, self.nodes[i]);
            }
            // Each argument borrows its owner and the other owners that it notes (`if c: &y else &a[0]`).
            const owner = self.owners[i] orelse continue;
            var k: u32 = self.pending_start[i];
            var cur: ?sema.LocalId = owner;
            while (cur) |o| : ({
                cur = nextArgOwner(c, self.pending_end[i], &k);
            }) {
                for (0..nargs) |j| {
                    if (j == i) continue;
                    if (argBorrowsOwner(c, self.owners[j], self.pending_start[j], self.pending_end[j], o)) {
                        const name = c.varStack.items[o].name();
                        return c.reportErrorFmt("Cannot pass an exclusive borrow of `{}` with another argument that borrows `{}`.", &.{v(name), v(name)}, self.nodes[i]);
                    }
                }
            }
        }
    }
};

/// The next other owner that an argument notes in `Chunk.borrow_pending`, from `k` up to `end`.
fn nextArgOwner(c: *cy.Chunk, end: u32, k: *u32) ?sema.LocalId {
    while (k.* < end) {
        const p = c.borrow_pending.items[k.*];
        k.* += 1;
        if (p.owner < c.varStack.items.len) return sema_borrow.borrowOwnerOf(c, p.owner);
    }
    return null;
}

/// Whether an argument with the owner `first` and the other owners in `borrow_pending[start..end]` borrows `owner`.
fn argBorrowsOwner(c: *cy.Chunk, first: ?sema.LocalId, start: u32, end: u32, owner: sema.LocalId) bool {
    var cur = first orelse return false;
    var k = start;
    while (true) {
        if (cur == owner) return true;
        cur = nextArgOwner(c, end, &k) orelse return false;
    }
}

/// Whether the receiver of this call is the one that `sema_move.takeGlobal` took a place for.
fn tookReceiver(c: *cy.Chunk, pre_args: []const Argument) bool {
    if (c.global_take == null) return false;
    if (pre_args.len == 0 or pre_args[0].type != .receiver) return false;
    return pre_args[0].node == c.global_take_rec;
}

pub fn matchFuncSym2(c: *cy.Chunk, func_sym: *cy.sym.FuncSym, pre_args: []const Argument, end_args: []const *ast.Node,
    req_value: bool, node: *ast.Node) anyerror!sema.ExprResult {

    try sema_local.referenceSym(c, @ptrCast(func_sym), node);

    const res = try matchFuncSym(c, func_sym, pre_args, end_args, req_value, node);
    if (res.kind == .ct) {
        return res.data.ct;
    }

    switch (res.func.type) {
        .host_builtin => {
            return res.data.expr_res;
        },
        else => {
            try sema_call.checkCallee(c, res.func, node);
            if (func_sym == c.sema.scope_start_sym) {
                try sema_hint.checkScopeStartCall(c, res.func, node);
            }
            try sema_hint.checkPrintCall(c, func_sym, res.func, node);
            if (c.compiler.config.deny_spawn and func_sym == c.sema.spawn_sym and !c.is_builtin) {
                return c.reportErrorFmt("`spawn` is not allowed. The host disabled threads for this script (`deny_spawn`). Use `fiber` or a `scope` block for concurrent work.", &.{}, node);
            }
            sema_call.recordCallRef(c, node, res.func);
            sema_call.markHotCall(c, res.func);
            try cy.global_init.recordCall(c, res.func);
            try sema_call.semaCancelHoist(c);
            const expr = try c.ir.newExpr(.call, res.func.sig.ret, node, .{ 
                .func = res.func,
                .numArgs = @as(u8, @intCast(res.data.rt.nargs)),
                .args = res.data.rt.args,
            });
            try sema_call.semaCancelPad(c, @intFromPtr(expr), node);
            var expr_res = sema.ExprResult.initOwned(expr);
            expr_res.data.value.parent_local = res.data.rt.ret_parent_scope_local;
            return expr_res;
        }
    }
}

pub fn matchFuncSym(c: *cy.Chunk, func_sym: *cy.sym.FuncSym, pre_args: []const Argument, end_args: []const *ast.Node,
    req_value: bool, node: *ast.Node) anyerror!FuncSymResult {

    if (func_sym.numFuncs == 1) {
        const res = try matchFunc(c, func_sym.first, pre_args, end_args, req_value, node);
        return .{
            .func = res.func,
            .kind = res.kind,
            .data = res.data,
        };
    }

    const nargs = pre_args.len + end_args.len;
    var loc: []*ir.Expr = undefined;
    if (!req_value) {
        loc = try c.ir.allocArray(*ir.Expr, nargs);
    }

    var best_func = func_sym.first;
    // `node` if 0 otherwise (best_err_arg-1) indexes into `pre_args` and `end_args`.
    // if == nargs, there is not enough arguments.
    var best_match_err = FuncMatchError.init(undefined, 0, undefined);

    if (!req_value and c.compiler.record_refs and cy.refs.inMainSource(c, node)) {
        try probeAmbiguousCall(c, func_sym, pre_args, end_args, nargs, node);
    }

    // First pass: a candidate whose parameter types match the arguments without implicit conversions wins,
    // regardless of declaration order. Otherwise fall back to the first candidate that matches with conversions (F-21).
    if (!req_value and func_sym.numFuncs > 1) {
        var next_exact: ?*cy.Func = func_sym.first;
        while (next_exact) |func| {
            next_exact = func.next;
            if (func.info.const_eval_only) {
                continue;
            }
            var match_err: FuncMatchError = undefined;
            if (try matchRtOverload(c, func, pre_args, end_args, loc, true, &match_err, node)) |res| {
                return res;
            }
        }
    }


    var next: ?*cy.Func = func_sym.first;
    while (next) |func| {
        var match_err: FuncMatchError = undefined;

        const ct_call = req_value or func.info.const_eval_only;
        if (ct_call) {
            if (try matchOverloadedFuncCt(c, func, pre_args, end_args, req_value, &match_err, node)) |res| {
                return .{
                    .func = func,
                    .kind = res.kind,
                    .data = res.data,
                };
            }
            if (match_err.arg > best_match_err.arg) {
                best_func = func;
                best_match_err = match_err;
            }
            next = func.next;
        } else {
            if (try matchRtOverload(c, func, pre_args, end_args, loc, false, &match_err, node)) |res| {
                return res;
            }
            if (match_err.arg > best_match_err.arg) {
                best_func = func;
                best_match_err = match_err;
            }
            next = func.next;
        }
    }

    if (best_match_err.rematch) {
        // The overload that came closest fails at an argument that was not reported: the body of an inferred
        // lambda, a literal that needs a target type, or an argument of an overload that infers template
        // parameters. Matching it alone reports the error, like a function without overloads does.
        var match_err: FuncMatchError = undefined;
        if (best_func.type == .generic and (req_value or best_func.info.const_eval_only)) {
            const cstr = cte.CallCstr{ .req_value = req_value };
            _ = try matchGenericFuncCt(c, best_func.data.generic, pre_args, end_args, cstr, false, &match_err, node);
        } else if (best_func.type == .generic) {
            _ = try matchGenericFuncRt(c, best_func, pre_args, end_args, loc, false, &match_err, node);
        } else {
            _ = try matchFuncSig(c, best_func.sig, pre_args, end_args, loc, false, false, &match_err);
        }
    }
    return reportCallFuncMismatch2(c, pre_args, end_args, best_func, best_match_err, node);
}

/// An argument whose analysis has no effect beyond the call: it can be matched against every overload and undone.
fn isProbeSafeArg(node: *ast.Node) bool {
    return switch (node.type()) {
        .ident, .noneLit, .decLit, .binLit, .octLit, .hexLit, .floatLit, .trueLit, .falseLit, .raw_string_lit,
        .string_lit => true,
        .accessExpr => isProbeSafeArg(node.cast(.accessExpr).left),
        else => false,
    };
}

/// For an editor (`refs.hints`): when more than one runtime overload matches a call through implicit conversions,
/// the call picks the one declared first. Every candidate is matched and undone here, and a call whose pick is not
/// more specific than another match is recorded. Only calls whose arguments are names and literals are checked,
/// since an argument such as a lambda or a block would be analyzed once per candidate.
fn probeAmbiguousCall(c: *cy.Chunk, func_sym: *cy.sym.FuncSym, pre_args: []const Argument, end_args: []const *ast.Node,
    nargs: usize, node: *ast.Node) !void {
    for (pre_args) |arg| {
        if (arg.type == .standard and !isProbeSafeArg(arg.node)) return;
    }
    for (end_args) |arg| {
        if (!isProbeSafeArg(arg)) return;
    }
    const loc = try c.ir.allocArray(*ir.Expr, nargs);
    var matched: [8]*cy.Func = undefined;
    var num_matched: usize = 0;
    // The first pass of `matchFuncSym` picks an exact match. Only when there is none, the second pass picks the
    // first candidate that matches through implicit conversions.
    for ([_]bool{ true, false }) |exact| {
        var next: ?*cy.Func = func_sym.first;
        while (next) |func| : (next = func.next) {
            if (func.info.const_eval_only or func.type == .generic) continue;
            if (num_matched == matched.len) break;
            const report_start = c.compiler.reports.items.len;
            var match_err: FuncMatchError = undefined;
            const res = tryRtOverload(c, func, pre_args, end_args, loc, exact, true, &match_err, node) catch |err| {
                if (err != error.CompileError) return err;
                for (c.compiler.reports.items[report_start..]) |*report| {
                    report.deinit(c.alloc);
                }
                c.compiler.reports.items.len = report_start;
                continue;
            };
            if (res != null) {
                matched[num_matched] = func;
                num_matched += 1;
            }
        }
        if (num_matched > 0) break;
    }
    if (num_matched < 2) return;
    for (matched[1..num_matched]) |other| {
        if (!moreSpecificSig(matched[0].sig, other.sig) and !interchangeableSigs(matched[0].sig, other.sig)) {
            cy.refs.recordAmbiguousCall(c, node, matched[0], other);
            return;
        }
    }
}

/// Whether each parameter of `a` is the same as that of `b` or narrower: `T` is narrower than `?T` and `!T`.
fn moreSpecificSig(a: *cy.FuncSig, b: *cy.FuncSig) bool {
    const a_params = a.params();
    const b_params = b.params();
    if (a_params.len != b_params.len) return false;
    for (a_params, b_params) |ap, bp| {
        const at = ap.get_type();
        const bt_ = bp.get_type();
        if (at.id() == bt_.id()) continue;
        switch (bt_.kind()) {
            .option => if (bt_.cast(.option).child_t.id() == at.id()) continue,
            .result => if (bt_.cast(.result).child_t.id() == at.id()) continue,
            else => {},
        }
        return false;
    }
    return true;
}

/// Whether the parameters of `a` and `b` only differ in pairs that give the same answer by design: two number
/// types (`float(x)` with an `i32` takes `float` before `int`, and the value is the same), or `str` and `byte` (a
/// one-character literal fits both, as in `s.index('\n')`).
fn interchangeableSigs(a: *cy.FuncSig, b: *cy.FuncSig) bool {
    const a_params = a.params();
    const b_params = b.params();
    if (a_params.len != b_params.len) return false;
    for (a_params, b_params) |ap, bp| {
        const at = ap.get_type();
        const bt_ = bp.get_type();
        if (at.id() == bt_.id()) continue;
        if (isNumberOrRaw(at) and isNumberOrRaw(bt_)) continue;
        if ((at.id() == bt.Str and bt_.id() == bt.R8) or (at.id() == bt.R8 and bt_.id() == bt.Str)) continue;
        return false;
    }
    return true;
}

/// Tries one runtime overload candidate. On a mismatch the locals and statements generated while matching are discarded.
fn matchRtOverload(c: *cy.Chunk, func: *cy.Func, pre_args: []const Argument, end_args: []const *ast.Node,
    loc: []*ir.Expr, exact: bool, match_err: *FuncMatchError, node: *ast.Node) !?FuncSymResult {
    return tryRtOverload(c, func, pre_args, end_args, loc, exact, false, match_err, node);
}

/// With `probe`, what the candidate generated is discarded whether it matches or not, and also on an error. The
/// result then only tells whether it matched.
fn tryRtOverload(c: *cy.Chunk, func: *cy.Func, pre_args: []const Argument, end_args: []const *ast.Node,
    loc: []*ir.Expr, exact: bool, probe: bool, match_err: *FuncMatchError, node: *ast.Node) !?FuncSymResult {

    // Save last statement to clear any that were added on a mismatch.
    const start_stmt = c.ir.curBlock().last;
    const var_start = c.varStack.items.len;
    const saved_take = c.global_take;
    const undo_mark = try sema_move.beginUndo(c);
    defer sema_move.endUndo(c, undo_mark);
    const Undo = struct {
        fn run(c_: *cy.Chunk, mark: anytype, var_start_: usize, saved_take_: anytype, start_stmt_: anytype) void {
            // A local that an argument moved is alive again for the next candidate.
            sema_move.undoMoves(c_, mark, var_start_);
            // Discard any locals created during matching.
            if (var_start_ < c_.varStack.items.len) {
                sema_borrow.truncateBorrowLoans(c_, var_start_);
                c_.varStack.items.len = var_start_;
            }
            // The hidden locals of a take (`sema_move.takeGlobal`) went with them. The next candidate takes again.
            c_.global_take = saved_take_;
            if (start_stmt_ != null) {
                // TODO: Also remove the statements and expressions generated.
                start_stmt_.?.next = null;
                c_.ir.curBlock().last = start_stmt_.?;
            } else {
                c_.ir.curBlock().last = null;
            }
        }
    };
    errdefer if (probe) Undo.run(c, undo_mark, var_start, saved_take, start_stmt);

    if (try matchOverloadedFunc(c, func, pre_args, end_args, loc, exact, match_err, node)) |res| {
        if (probe) Undo.run(c, undo_mark, var_start, saved_take, start_stmt);
        return .{
            .func = res.func,
            .kind = .rt,
            .data = .{ .rt = .{
                .args = loc.ptr,
                .nargs = @intCast(res.nargs),
                .ret_parent_scope_local = res.ret_parent_scope_local,
            }},
        };
    }

    Undo.run(c, undo_mark, var_start, saved_take, start_stmt);
    return null;
}

pub fn matchFuncCt(c: *cy.Chunk, func: *cy.Func, pre_args: []const Argument, end_args: []const *ast.Node, cstr: cte.CallCstr, node: *ast.Node) !FuncResult {
    try sema_resolve.ensure_resolved_func(c, func, true, node);
    switch (func.type) {
        .generic => {
            var match_err: FuncMatchError = undefined;
            const res = (try matchGenericFuncCt(c, func.data.generic, pre_args, end_args, cstr, false, &match_err, node)) orelse {
                return reportCallFuncMismatch2(c, pre_args, end_args, func, match_err, node);
            };
            return .{
                .func = res.func,
                .kind = .ct,
                .data = .{ .ct = res.res },
            };
        },
        .reserved => {
            const name = try c.sema.newFuncName(c.alloc, func, .{});
            defer c.alloc.free(name);
            return c.reportErrorFmt("Cannot invoke the reserved function `{}`.", &.{v(name)}, node);
        },
        .host_builtin => {
            const ptr = func.data.host_builtin.eval orelse {
                const name = try c.sema.newFuncName(c.alloc, func, .{});
                defer c.alloc.free(name);
                return c.reportErrorFmt("Unsupported const eval of `{}`.", &.{v(func.name())}, node);
            };
            std.debug.assert(pre_args.len == 0);
            if (end_args.len != func.sig.params_len) {
                const name = try c.sema.newFuncName(c.alloc, func, .{});
                defer c.alloc.free(name);
                return c.reportErrorFmt("Expected {} arguments for `{}`, found {}.", &.{v(func.sig.params_len), v(func.name()), v(end_args.len)}, node);
            }
            const ctx = cy.BuiltinContext{
                .func = func, 
                .args = end_args.ptr,
                .node = node,
            };
            const res = ptr(c, &ctx);
            if (res.type.id() == bt.Null) {
                return error.CompileError;
            }
            try sema_type.ensure_eval_eligible_type(c, res.type, node);
            return .{
                .func = func,
                .kind = .ct,
                .data = .{ .ct = sema.ExprResult.initCtValue(res) },
            };
        },
        else => {
            var match_err: FuncMatchError = undefined;
            const res = (try matchFuncSigCt(c, func.sig, pre_args, end_args, cstr, &match_err, node)) orelse {
                return reportCallFuncMismatch2(c, pre_args, end_args, func, match_err, node);
            };
            const ct_args = c.valueStack.items[res.arg_start..];
            defer {
                // No destruction after const eval call.
                // Unlike runtime, compile-time callsite doesn't try to manage an eval_ref (all arguments are copied to the callee).
                c.valueStack.items.len = res.arg_start;
                c.typeStack.items.len = res.argt_start;
            }
            const ct_res = try cte.evalCall(c, func, ct_args, node);
            if (cstr.req_value and ct_res.resType != .ct_value) {
                return c.reportErrorFmt("Expected compile-time value.", &.{}, node);
            }
            return .{
                .func = func,
                .kind = .ct,
                .data = .{ .ct = ct_res },
            };
        }
    }
}

fn matchOverloadedFuncCt(c: *cy.Chunk, func: *cy.Func, pre_args: []const Argument, end_args: []const *ast.Node, req_value: bool, match_err: *FuncMatchError, node: *ast.Node) !?FuncResult {
    try sema_resolve.ensure_resolved_func(c, func, true, node);
    const call_cstr = cte.CallCstr{
        .req_value = req_value,
    };

    if (func.type == .generic) {
        const res = try matchGenericFuncCt(c, func.data.generic, pre_args, end_args, call_cstr, true, match_err, node) orelse {
            return null;
        };
        return .{
            .func = res.func,
            .kind = .ct,
            .data = .{ .ct = res.res },
        };
    } else {
        const res = (try matchFuncSigCt(c, func.sig, pre_args, end_args, call_cstr, match_err, node)) orelse {
            return null;
        };
        defer {
            const args = c.valueStack.items[res.arg_start..];
            for (args, 0..) |arg, i| {
                const arg_t = c.typeStack.items[res.argt_start + i];
                // Only reference args are owned by the callsite.
                if (arg_t.isObjectLike()) {
                    c.heap.destructValue2(arg_t, arg);
                }
            }
            c.valueStack.items.len = res.arg_start;
            c.typeStack.items.len = res.argt_start;
        }

        const ct_res = try cte.evalCall(c, func, c.valueStack.items[res.arg_start..], node);
        if (req_value and ct_res.resType != .ct_value) {
            return c.reportErrorFmt("Expected compile-time value.", &.{}, node);
        }
        return .{
            .func = func,
            .kind = .ct,
            .data = .{ .ct = ct_res },
        };
    }
}

const MatchOverloadedFuncResult = struct {
    func: *cy.Func,
    nargs: usize,
    ret_parent_scope_local: ?u32,
};

fn matchOverloadedFunc(c: *cy.Chunk, func: *cy.Func, pre_args: []const Argument,
    end_args: []const *ast.Node, args: []*ir.Expr, exact: bool, match_err: *FuncMatchError, node: *ast.Node) !?MatchOverloadedFuncResult {

    if (func.type == .generic) {
        if (exact) {
            // Generic candidates are only considered in the second pass.
            match_err.* = FuncMatchError.init(undefined, 0, undefined);
            return null;
        }
        const res = (try matchGenericFuncRt(c, func, pre_args, end_args, args, true, match_err, node)) orelse {
            return null;
        };
        return .{
            .func = res.func,
            .nargs = res.nargs,
            .ret_parent_scope_local = null,
        };
    } else {
        const res = (try matchFuncSig(c, func.sig, pre_args, end_args, args, true, exact, match_err)) orelse {
            return null;
        };
        return .{
            .func = func,
            .nargs = args.len,
            .ret_parent_scope_local = res.ret_parent_scope_local,
        };
    }
}

pub fn ownOrManageArg(c: *cy.Chunk, arg: sema.ExprResult, node: *ast.Node) !sema.ExprResult {
    if (arg.resType == .infer_error) {
        return arg;
    }
    // Object types are managed from the caller side.
    // Other types are copied and managed from the callee side.
    if (arg.type.isObjectLike()) {
        if (arg.resType == .value_local) {
            return arg;
        } else {
            const res = try sema_move.semaOwn(c, arg, node);
            return sema_move.semaManage(c, res, node);
        }
    } else {
        return sema_move.semaOwn(c, arg, node);
    }
}

fn resolveRtArg(c: *cy.Chunk, arg: Argument, node: *ast.Node, opt_target: ?sema.FuncParam, overloaded: bool, fit_target: bool) !sema.ExprResult {
    if (arg.resolve_t == .rt) {
        return arg.res.rt;
    }
    switch (arg.type) {
        .standard => {
            if (opt_target) |target| {
                const target_t = target.get_type();
                var res = try c.semaExpr(node, .{
                    .target_t = target_t,
                    .reqTypeCstr = false,
                    .fit_target = fit_target,
                    .return_infer_error = overloaded,
                });
                if (res.resType == .infer_error) {
                    return res;
                }

                if (target.sink) {
                    if (res.resType == .value_local) {
                        // move owner.
                        try sema_move.noteMove(c, res.data.value_local);
                        c.varStack.items[res.data.value_local].type = .dead;
                    }
                    res.owned = true;
                    return res;
                }
                return res;
            } else {
                const res = try c.semaExpr(node, .{
                    .return_infer_error = overloaded,
                });
                return res;
            }
        },
        .pre_resolved => {
            return arg.data.pre_resolved;
        },
        .receiver => {
            if (opt_target) |target| {
                if (target.sink) {
                    if (arg.data.receiver.type.id() == target.get_type().id()) {
                        if (arg.data.receiver.resType == .value_local) {
                            // move owner.
                            try sema_move.noteMove(c, arg.data.receiver.data.value_local);
                            c.varStack.items[arg.data.receiver.data.value_local].type = .dead;
                        }
                        var res = arg.data.receiver;
                        res.owned = true;
                        return res;
                    }
                }
                const target_t = target.get_type();
                if (target_t.kind() == .pointer) {
                    if (target_t.cast(.pointer).ref) {
                        const child_t = target_t.cast(.pointer).child_t;
                        if (arg.data.receiver.type != target_t) {
                            // Not the exact pointer type but matches a distinct pointer type.
                            const rec_t = arg.data.receiver.type;
                            if (rec_t.kind() == .pointer) {
                                const rec_pt = rec_t.cast(.pointer);
                                if (rec_pt.ref and rec_pt.child_t == child_t) {
                                    return sema.ExprResult.init(arg.data.receiver.ir, target_t);
                                }
                            }
                        }
                    } else {
                        const child_t = target_t.cast(.pointer).child_t;
                        if (arg.data.receiver.type != target_t) {
                            const rec_t = arg.data.receiver.type;
                            if (rec_t.kind() == .pointer) {
                                const rec_pt = rec_t.cast(.pointer);
                                if (!rec_pt.ref and rec_pt.child_t == child_t) {
                                    return sema.ExprResult.init(arg.data.receiver.ir, target_t);
                                }
                            }
                        }
                    }
                } else if (target_t.kind() == .borrow) {
                    const target_child_t = target_t.cast(.borrow).child_t;
                    if (arg.data.receiver.type == target_child_t) {
                        // Implicit T -> &T
                        const rec = try sema_move.semaManage(c, arg.data.receiver, node);
                        const addressable = try sema_move.semaEnsureAddressable(c, rec, node);
                        if (addressable.recParentLocal()) |parent_local| {
                            try sema_borrow.checkSharedBorrowOf(c, parent_local, node);
                        }
                        return sema_expr.semaAddressOf(c, addressable, target_t, node);
                    }
                    if (arg.data.receiver.type != target_t) {
                        // Not the exact pointer type but matches a distinct pointer type.
                        const rec_t = arg.data.receiver.type;
                        // Implicit ^T -> &T
                        // Implicit *T -> &T
                        if (rec_t.kind() == .pointer) {
                            const rec_pt = rec_t.cast(.pointer);
                            if (rec_pt.child_t == target_child_t) {
                                var new_rec = try sema_move.semaManage(c, arg.data.receiver, node);
                                new_rec.type = target_t;
                                return new_rec;
                            }
                        }
                        // NOTE: This implicit conversion is only possible if the function doesn't have a `&|T` parameter.
                        //       Multiple `&T` are allowed because they are guaranteed to not outlive the receiver `&|T`.
                        // TODO: Check that no other parameter accepts `&|T`.
                        // &>T -> &T
                        if (rec_t.kind() == .ex_borrow) {
                            const borrow = rec_t.cast(.ex_borrow);
                            if (borrow.child_t == target_child_t) {
                                // Keeps the local it borrows from, so a `scope` result is bound to the owner.
                                var new_rec = arg.data.receiver;
                                new_rec.type = target_t;
                                return new_rec;
                            }
                        }
                    }
                } else if (target_t.kind() == .ex_borrow) {
                    const target_child_t = target_t.cast(.ex_borrow).child_t;
                    if (arg.data.receiver.type == target_child_t) {
                        // T -> &>T
                        const rec = try sema_move.semaManage(c, arg.data.receiver, node);
                        return sema_borrow.sema_ex_borrow2(c, rec, target_t, node);
                    }
                    if (arg.data.receiver.type.kind() == .pointer) {
                        const pointer = arg.data.receiver.type.cast(.pointer);

                        if (pointer.child_t == target_child_t) {
                            if (!pointer.ref) {
                                // *T -> &>T
                                var new_rec = try sema_move.semaManage(c, arg.data.receiver, node);
                                new_rec.type = target_t;
                                return new_rec;
                            }
                        }
                    }
                } else if (target_t.kind() == .generic_trait) {
                    if (arg.data.receiver.type.kind() == .ref_trait) {
                        if (arg.data.receiver.type.cast(.ref_trait).generic.base.id() == target_t.id()) {
                            return sema.ExprResult.init(arg.data.receiver.ir, target_t);
                        }
                    } else if (arg.data.receiver.type.kind() == .borrow_trait) {
                        if (arg.data.receiver.type.cast(.borrow_trait).generic.base.id() == target_t.id()) {
                            return sema.ExprResult.init(arg.data.receiver.ir, target_t);
                        }
                    }
                }

                return arg.data.receiver;
            } else {
                return arg.data.receiver;
            }
        },
        .skip => {
            return error.Unexpected;
        },
    }
}

fn getFuncTemplateParamType(c: *cy.Chunk, template: *cy.sym.FuncTemplate, ctx: *sema_resolve.ResolveContext, idx: usize, resolve_new_type: bool) !*cy.Type {
    if (idx == 0 and std.mem.eql(u8, template.func_params[idx].name_type.as_name(), "self")) {
        return template.head.parent.?.getStaticType().?;
    } else {
        const spec_idx = sema_resolve.indexOfTypedParam(template.func_params, idx).?;
        try sema_resolve.pushSavedResolveContext(c, ctx.*);
        defer ctx.* = sema_resolve.saveResolveContext(c);

        return try cte.eval_type2(c, resolve_new_type, template.func_params[spec_idx].type.?);
    }
}

/// The type of a parameter from the template parameters that the arguments before it bound (`b []T`,
/// `f fn(T) -> %U`). Returns `null` when the type declares an infer parameter that is not bound yet:
/// the argument is resolved first and the parameter is inferred from its type.
fn evalParamType(c: *cy.Chunk, template: *cy.sym.FuncTemplate, ctx: *sema_resolve.ResolveContext, idx: usize, resolve_new_type: bool) !?*cy.Type {
    const prev = ctx.infer_param;
    ctx.infer_param = .bound;
    defer ctx.infer_param = prev;
    return getFuncTemplateParamType(c, template, ctx, idx, resolve_new_type) catch |err| {
        if (err == error.FoundInferParam) {
            return null;
        }
        return err;
    };
}

/// The type of a parameter before its argument is analysed, to tell which parts of it are known.
/// An infer parameter that is not bound yet is the placeholder type `Sema.infer_t` for the evaluation, and
/// so is every later use of its name (`Pair[%U, U]`). A type that can not be expanded with the placeholder
/// (`Map[%K, int]`, `[%N]T`) is the placeholder too, see `template.resolveTemplateArgs`.
/// The type is only looked at. It is not resolved.
fn evalParamTypeHint(c: *cy.Chunk, template: *cy.sym.FuncTemplate, ctx: *sema_resolve.ResolveContext, idx: usize) !?*cy.Type {
    const spec = paramTypeSpec(template, idx);
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (names.items) |name| {
            ctx.unsetCtParam(c.heap, name);
        }
        names.deinit(c.alloc);
    }
    while (firstInferParam(spec, ctx)) |infer_n| {
        const name = infer_n.cast(.infer_param).name.as_name();
        try names.ensureUnusedCapacity(c.alloc, 1);
        try ctx.initCtParam2(c.alloc, name, c.sema.type_t, Value.initPtr(c.sema.infer_t));
        names.appendAssumeCapacity(name);
    }
    return evalParamType(c, template, ctx, idx, false);
}

/// The type specifier of the parameter at `idx`.
fn paramTypeSpec(template: *cy.sym.FuncTemplate, idx: usize) *ast.Node {
    const spec_idx = sema_resolve.indexOfTypedParam(template.func_params, idx).?;
    return template.func_params[spec_idx].type.?;
}

/// Reports the first infer parameter of the parameter at `idx` that its argument did not bind.
fn reportCanNotInfer(c: *cy.Chunk, template: *cy.sym.FuncTemplate, ctx: *sema_resolve.ResolveContext, idx: usize, arg_n: *ast.Node) anyerror {
    const param_name = template.func_params[idx].name_type.as_name();
    if (firstInferParam(paramTypeSpec(template, idx), ctx)) |infer_n| {
        const name = infer_n.cast(.infer_param).name.as_name();
        return c.reportErrorFmt("Can not infer the template parameter `{}` from the argument for `{}`. Declare it as its own parameter (`%{} type`) and pass the type in the call.", &.{v(name), v(param_name), v(name)}, arg_n);
    }
    return c.reportErrorFmt("Can not infer a template parameter from the argument for `{}`. Declare it as its own parameter (`%T type`) and pass the type in the call.", &.{v(param_name)}, arg_n);
}

/// The signature of a function type: `fn(T) -> U`, `Func[fn(T) -> U]`, `&OpaqueFunc[fn(T) -> U]`.
pub fn funcSigOfType(type_: *cy.Type) ?*cy.FuncSig {
    switch (type_.kind()) {
        .func_ptr => return type_.cast(.func_ptr).sig,
        .func => return type_.cast(.func).sig,
        .borrow => {
            const child_t = type_.cast(.borrow).child_t;
            if (child_t.kind() == .func) {
                return child_t.cast(.func).sig;
            }
            return null;
        },
        else => return null,
    }
}

/// An inferred lambda (`|x| expr`) as the argument of a parameter that still has infer parameters to bind:
/// `f fn(T) -> %U`. The parameters of the lambda are typed from the function type, which must be known from
/// the arguments before it. The result type is the type of the body, and the parameter is then inferred
/// from the function type of the lambda like from any other function.
/// Returns `null` when the argument is not such a lambda.
/// With `soft`, a lambda that the parameter can not take is `error.InferMismatch` instead of a report.
fn resolveInferLambdaArg(c: *cy.Chunk, arg: Argument, template: *cy.sym.FuncTemplate, ctx: *sema_resolve.ResolveContext, idx: usize, soft: bool) !?sema.ExprResult {
    if (arg.type != .standard) {
        return null;
    }
    var block_lambda = false;
    var lambda_n = arg.node;
    if (lambda_n.type() == .lambda_cont_expr) {
        lambda_n = lambda_n.cast(.lambda_cont_expr).child;
    }
    switch (lambda_n.type()) {
        .lambda_expr => {
            if (lambda_n.cast(.lambda_expr).sig_t != .infer) return null;
        },
        .lambda_multi => {
            if (lambda_n.cast(.lambda_multi).sig_t != .infer) return null;
            block_lambda = true;
        },
        .lambda_cont => {
            if (lambda_n.cast(.lambda_cont).sig_t != .infer) return null;
            block_lambda = true;
        },
        else => return null,
    }

    const param_name = template.func_params[idx].name_type.as_name();
    const infer_n = firstInferParam(paramTypeSpec(template, idx), ctx) orelse return null;
    const name = infer_n.cast(.infer_param).name.as_name();

    const hint_t = (try evalParamTypeHint(c, template, ctx, idx)) orelse return null;
    const sig = funcSigOfType(hint_t) orelse return null;
    if (soft and (block_lambda or lambda_n.cast(.lambda_expr).params.len != sig.params().len)) {
        return error.InferMismatch;
    }
    if (block_lambda) {
        return c.reportErrorFmt("Can not infer the template parameter `{}` from the lambda for `{}`. The result type of a lambda with a block is not inferred. Use an expression lambda (`|x| expr`), declare the types of the lambda (`fn(x T) -> {}:`), or declare `%{} type` as its own parameter and pass the type in the call.", &.{v(name), v(param_name), v(name), v(name)}, arg.node);
    }
    const lambda = lambda_n.cast(.lambda_expr);
    if (lambda.params.len != sig.params().len) {
        return c.reportErrorFmt("Expected a lambda with `{}` parameter(s) for `{}`. Found `{}`.", &.{v(sig.params().len), v(param_name), v(lambda.params.len)}, arg.node);
    }
    for (sig.params(), 0..) |param, i| {
        if (cy.template.usesInferPlaceholder(param.get_type())) {
            const lambda_param = lambda.params[i].name_type.as_name();
            return c.reportErrorFmt("Can not infer the template parameter `{}` from the lambda for `{}`. The type of the lambda parameter `{}` must be known from the arguments before the lambda. Declare the types of the lambda (`fn(x T) -> U: ...`), or declare `%{} type` as its own parameter and pass the type in the call.", &.{v(name), v(param_name), v(lambda_param), v(name)}, arg.node);
        }
    }
    return try sema_expr.semaLambdaInferRet(c, lambda_n, sig.params());
}

/// The first infer parameter (`%T`) in a type specifier that is not bound in `ctx`.
/// Visits the same nodes as `sema_type.findInferParams`.
fn firstInferParam(node: *ast.Node, ctx: ?*sema_resolve.ResolveContext) ?*ast.Node {
    switch (node.type()) {
        .infer_param => {
            if (ctx) |ctx_| {
                if (ctx_.hasCtParam(node.cast(.infer_param).name.as_name())) return null;
            }
            return node;
        },
        .index_expr => {
            for (node.cast(.index_expr).args.slice()) |arg| {
                if (firstInferParam(arg, ctx)) |res| return res;
            }
            return null;
        },
        .ref => return firstInferParam(node.cast(.ref).child, ctx),
        .borrow => return firstInferParam(node.cast(.borrow).child, ctx),
        .option_type => return firstInferParam(node.cast(.option_type).child, ctx),
        .unary_expr => {
            const unary = node.cast(.unary_expr);
            if (unary.op != .lnot) return null;
            return firstInferParam(unary.child, ctx);
        },
        .span_type => return firstInferParam(node.cast(.span_type).child, ctx),
        .slice_type => return firstInferParam(node.cast(.slice_type).child, ctx),
        .vector_type => {
            const vector_t = node.cast(.vector_type);
            return firstInferParam(vector_t.child, ctx) orelse firstInferParam(vector_t.n, ctx);
        },
        .partial_vector_type => {
            const vector_t = node.cast(.partial_vector_type);
            return firstInferParam(vector_t.child, ctx) orelse firstInferParam(vector_t.n, ctx);
        },
        .binExpr => {
            const bin = node.cast(.binExpr);
            return firstInferParam(bin.left, ctx) orelse firstInferParam(bin.right, ctx);
        },
        .fn_type => {
            const func_type = node.cast(.fn_type);
            for (func_type.params.slice()) |param| {
                if (firstInferParam(param.type orelse param.name_type, ctx)) |res| return res;
            }
            if (func_type.ret) |ret| {
                return firstInferParam(ret, ctx);
            }
            return null;
        },
        else => return null,
    }
}

/// With `overloaded`, an argument that does not have the type of its parameter, or whose type does not have the form
/// that the infer parameters are bound from, is returned as `.incompat` instead of reported.
fn matchTemplateArgCt(c: *cy.Chunk, param: sema.FuncParam, arg: Argument, template: *cy.sym.FuncTemplate,
    template_ctx: *sema_resolve.ResolveContext, param_idx: usize, overloaded: bool) !Argument {

    const param_t = param.get_type();
    const ast_param = template.func_params[param_idx];

    if (ast_param.template_param) {
        // (%T type)
        var tparam_t: *cy.Type = undefined;
        {
            try sema_resolve.pushSavedResolveContext(c, template_ctx.*);
            defer template_ctx.* = sema_resolve.saveResolveContext(c);
            const type_idx = sema_resolve.indexOfTypedParam(template.func_params, param_idx).?;
            tparam_t = try cte.eval_type2(c, false, template.func_params[type_idx].type.?);
        }

        const ct_value = (try evalCtArg(c, arg.node, tparam_t, overloaded)) orelse return incompatArg(arg);
        var new_arg = arg;
        new_arg.resolve_t = .template;
        new_arg.res = .{ .template = ct_value };
        return new_arg;
    }
    var infer = param_t.id() == bt.Infer;
    var dep_target_t: ?*cy.Type = null;
    if (param_t.id() == bt.Dependent) {
        dep_target_t = try evalParamType(c, template, template_ctx, param_idx, true);
        // The type declares an infer parameter that is not bound yet (`p Pair[T, %U]`).
        infer = dep_target_t == null;
    }
    if (!infer) {
        const target_t: *cy.Type = dep_target_t orelse param_t;
        var ct_value: cy.TypeValue = undefined;

        switch (arg.type) {
            .receiver => {
                if (arg.data.receiver.type.id() != target_t.id()) {
                    if (target_t.kind() == .borrow) {
                        const borrow_target_t = target_t.cast(.borrow);
                        if (arg.data.receiver.type.id() == borrow_target_t.child_t.id()) {
                            // T -> &T.
                            if (arg.data.receiver.type.is_cte_boxed()) {
                                const ref = arg.data.receiver.data.ct_value.value;
                                ct_value = cy.TypeValue.init(target_t, ref);
                                var new_arg = arg;
                                new_arg.resolve_t = .ct;
                                new_arg.res = .{ .ct = ct_value };
                                return new_arg;
                            } else {
                                return c.reportError("TODO", arg.node);
                            }
                        }
                    }
                    return c.reportError("TODO", arg.node);
                } else {
                    ct_value = arg.data.receiver.data.ct_value;
                    var new_arg = arg;
                    new_arg.resolve_t = .ct;
                    new_arg.res = .{ .ct = ct_value };
                    return new_arg;
                }
            },
            else => {
                if (target_t == c.sema.code_t) {
                    const val = cy.Value.initPtr(arg.node);
                    ct_value = cy.TypeValue.init(c.sema.code_t, val);
                } else {
                    ct_value = (try evalCtArg(c, arg.node, target_t, overloaded)) orelse return incompatArg(arg);
                }
                var new_arg = arg;
                new_arg.resolve_t = .ct;
                new_arg.res = .{ .ct = ct_value };
                return new_arg;
            }
        }
    }

    const ct_value = try cte.eval(c, arg.node);
    var keep = false;
    defer if (!keep) c.heap.destructValue(ct_value);
    const targ = cy.TypeValue.init(c.sema.type_t, Value.initPtr(ct_value.type));
    inferCtArgs(c, targ, template, template_ctx, paramTypeSpec(template, param_idx), null, overloaded, arg.node) catch |err| {
        if (err == error.InferMismatch) {
            return incompatArg(arg);
        }
        return err;
    };
    // The parts of the parameter type that are not inferred are checked against the argument here.
    const target_t = (try evalParamType(c, template, template_ctx, param_idx, true)) orelse {
        return reportCanNotInfer(c, template, template_ctx, param_idx, arg.node);
    };
    if (ct_value.type.id() != target_t.id()) {
        if (overloaded) {
            return incompatArg(arg);
        }
        return sema_expr.reportIncompatType(c, target_t, ct_value.type, arg.node);
    }
    keep = true;

    var new_arg = arg;
    new_arg.resolve_t = .ct;
    new_arg.res = .{ .ct = ct_value };
    return new_arg;
}

/// With `overloaded`, an argument that the parameter can not take is not reported: it is returned as `.incompat`.
/// That is an argument that does not have the type of the parameter, an inferred lambda whose body does not
/// have the result type of the parameter, a literal that can not be made for the parameter, and an argument
/// whose type does not have the form that the infer parameters are bound from (`inferCtArgs`).
/// An error inside the argument is reported, and so is an error of the declaration.
fn matchTemplateArg(c: *cy.Chunk, param: sema.FuncParam, arg: Argument, template: *cy.sym.FuncTemplate,
    template_ctx: *sema_resolve.ResolveContext, param_idx: usize, overloaded: bool, comptime sema_func: bool) !Argument {

    const param_t = param.get_type();
    const ast_param = template.func_params[param_idx];

    if (ast_param.template_param) {
        var tparam_t: *cy.Type = undefined;
        {
            try sema_resolve.pushSavedResolveContext(c, template_ctx.*);
            defer template_ctx.* = sema_resolve.saveResolveContext(c);
            const type_idx = sema_resolve.indexOfTypedParam(template.func_params, param_idx).?;
            tparam_t = try cte.eval_type2(c, false, template.func_params[type_idx].type.?);
        }

        var ct_value: cy.TypeValue = undefined;
        if (arg.type == .pre_resolved and arg.data.pre_resolved.resType == .ct_value) {
            ct_value = arg.data.pre_resolved.data.ct_value;
            if (ct_value.type.id() != tparam_t.id()) {
                return sema_expr.reportIncompatType(c, tparam_t, ct_value.type, arg.node);
            }
            ct_value = try c.heap.copy_value(ct_value);
        } else {
            ct_value = try cte.evalCheck(c, arg.node, tparam_t);
        }
        var new_arg = arg;
        new_arg.resolve_t = .template;
        new_arg.res = .{ .template = ct_value };
        return new_arg;
    }

    var target: ?sema.FuncParam = null;

    var infer = param_t.id() == bt.Infer;
    if (param_t.id() == bt.Dependent) {
        if (try evalParamType(c, template, template_ctx, param_idx, true)) |target_t| {
            target = sema.FuncParam.init(target_t);
        } else {
            // The type declares an infer parameter that is not bound yet (`f fn(T) -> %U`).
            infer = true;
        }
    } else if (!infer) {
        target = param;
    }
    var res: sema.ExprResult = undefined;
    // A lambda that is checked here and then does not have the form of the parameter is dropped.
    const lambda_mark = sema_local.LambdaMark.take(c);
    if (infer) {
        const opt_res = resolveInferLambdaArg(c, arg, template, template_ctx, param_idx, overloaded) catch |err| {
            if (err == error.InferMismatch) {
                return incompatArg(arg);
            }
            return err;
        };
        res = opt_res orelse try resolveRtArg(c, arg, arg.node, null, overloaded, true);
    } else {
        res = try resolveRtArg(c, arg, arg.node, target, overloaded, true);
    }
    if (res.resType == .infer_error) {
        // Only with `overloaded`.
        return incompatArg(arg);
    }

    if (infer) {
        // Infer template params.
        const targ = cy.TypeValue.init(c.sema.type_t, Value.initPtr(res.type));
        inferCtArgs(c, targ, template, template_ctx, paramTypeSpec(template, param_idx), null, overloaded, arg.node) catch |err| {
            if (err == error.InferMismatch) {
                try sema_local.dropLambdas(c, lambda_mark);
                return incompatArg(arg);
            }
            return err;
        };
        try sema_type.ensure_resolved_type(c, res.type, arg.node);

        // The parts of the parameter type that are not inferred (`T` in `f fn(T) -> %U`) are checked against
        // the argument below, with the type that the parameter has now.
        const target_t = (try evalParamType(c, template, template_ctx, param_idx, true)) orelse {
            return reportCanNotInfer(c, template, template_ctx, param_idx, arg.node);
        };
        if (res.type.id() != target_t.id()) {
            // A function for a `Func[fn(T) -> %U]` parameter.
            if (try sema_lit.semaFitTarget(c, res, target_t, arg.node)) |new| {
                res = new;
            }
        }
        target = sema.FuncParam.init(target_t);
    }
    if (!sema_func) {
        res = try ownOrManageArg(c, res, arg.node);
    }

    if (param_t.is_generic()) {
        var buf: [2]u8 = undefined;
        const anonymous_name = try std.mem.print(&buf, "{}", .{param_idx});
        const idx = template.indexOfParam(anonymous_name).?;
        try template_ctx.initCtParam2(c.alloc, template.params[idx].name, c.sema.type_t, Value.initPtr(res.type));
        if (!try sema_type.implements(c, res.type, param.get_type().cast(.generic_trait), arg.node)) {
            if (overloaded) {
                return incompatArg(arg);
            }
            return sema_expr.reportIncompatType(c, param.get_type(), res.type, arg.node);
        }
    } else {
        const ct_compat = cy.types.isTypeCompat(c.compiler, res.type, target.?.get_type());
        if (!ct_compat) {
            if (overloaded) {
                return incompatArg(arg);
            }
            if (arg.type == .receiver) {
                var hint_buf: [256]u8 = undefined;
                const hint = refReceiverHint(c, target.?.get_type(), res.type, arg.node, template.head.name(), &hint_buf);
                if (hint.len > 0) {
                    const exp_name = try c.sema.allocTypeName(target.?.get_type());
                    defer c.alloc.free(exp_name);
                    const act_name = try c.sema.allocTypeName(res.type);
                    defer c.alloc.free(act_name);
                    return c.reportErrorFmt("Expected type `{}`. Found `{}`.{}", &.{v(exp_name), v(act_name), v(hint)}, arg.node);
                }
            }
            const closure_hint = closureArgHint(target.?.get_type(), res.type);
            if (closure_hint.len > 0) {
                const exp_name = try c.sema.allocTypeName(target.?.get_type());
                defer c.alloc.free(exp_name);
                const act_name = try c.sema.allocTypeName(res.type);
                defer c.alloc.free(act_name);
                return c.reportErrorFmt("Expected type `{}`. Found `{}`.{}", &.{v(exp_name), v(act_name), v(closure_hint)}, arg.node);
            }
            return sema_expr.reportIncompatType(c, target.?.get_type(), res.type, arg.node);
        }
    }

    var resolved_arg = arg;
    resolved_arg.res = .{ .rt = res };
    resolved_arg.resolve_t = .rt;
    return resolved_arg;
}

/// The argument that an overload does not take (`matchTemplateArg`).
/// Evaluates a compile-time argument for a parameter of type `target_t`. With `overloaded`, an argument of another
/// type is null instead of a type error.
fn evalCtArg(c: *cy.Chunk, node: *ast.Node, target_t: *cy.Type, overloaded: bool) !?cy.TypeValue {
    if (!overloaded) {
        return try cte.evalCheck(c, node, target_t);
    }
    var cstr = cte.ExprCstr.init_check(target_t);
    cstr.check = false;
    const val = try cte.exprToValue(c, try cte.evalExpr(c, node, cstr), node);
    if (val.type.id() != target_t.id()) {
        c.heap.destructValue(val);
        return null;
    }
    return val;
}

fn incompatArg(arg: Argument) Argument {
    var incompat_arg = arg;
    incompat_arg.resolve_t = .incompat;
    incompat_arg.res = .{ .incompat = {} };
    return incompat_arg;
}

/// The hint for a closure that is passed to a function pointer parameter, or an empty string.
fn closureArgHint(param_t: *cy.Type, arg_t: *cy.Type) []const u8 {
    if (param_t.kind() != .func_ptr or arg_t.kind() != .func) return "";
    return " A closure is passed to a `Func[fn(...)]` or a `&OpaqueFunc[fn(...)]` parameter.";
}

// Owns a copy of the argument, unless its obtaining a borrow to a receiver.
fn matchPreArgCt(c: *cy.Chunk, arg: Argument, param: sema.FuncParam, req_value: bool, out_match: *bool) !cy.TypeValue {
    const param_t = param.get_type();
    var ct_value: cy.TypeValue = undefined;
    if (arg.type == .receiver) {
        if (arg.data.receiver.resType != .ct_value) {
            return c.reportErrorFmt("Expected eval value.", &.{}, arg.node);
        }
        const rec = arg.data.receiver.data.ct_value;

        // T -> T
        if (rec.type.id() == param_t.id()) {
            out_match.* = true;
            return c.heap.copy_value(rec);
        }

        if (param_t.kind() == .borrow) {
            const param_borrow_t = param_t.cast(.borrow);

            if (param_borrow_t.child_t.id() == rec.type.id()) {
                // T -> &T
                out_match.* = true;
                if (param_borrow_t.child_t.is_cte_boxed()) {
                    return cy.TypeValue.init(param_t, rec.value);
                } else {
                    // Find some way to have a stable primitive argument.
                    return c.reportError("TODO", arg.node);
                }
            }

            // ^T -> &T
            // *T -> &T
            if (rec.type.kind() == .pointer) {
                const ptr_t = rec.type.cast(.pointer);
                if (param_borrow_t.child_t.id() == ptr_t.child_t.id()) {
                    out_match.* = true;
                    return cy.TypeValue.init(param_t, rec.value);
                }
            }
        }
        out_match.* = false;
    } else if (arg.type == .pre_resolved) {
        if (arg.data.pre_resolved.resType != .ct_value) {
            return c.reportErrorFmt("Expected eval value.", &.{}, arg.node);
        }
        if (arg.data.pre_resolved.type.id() != param_t.id()) {
            out_match.* = false;
            return arg.data.pre_resolved.data.ct_value;
        }
        ct_value = try c.heap.copy_value(arg.data.pre_resolved.data.ct_value);
    } else if (arg.type == .standard) {
        if (req_value) {
            const res = try cte.evalTarget(c, arg.node, param_t);
            if (param_t.id() != res.type.id()) {
                // The value is not passed on, so it is released here.
                c.heap.destructValue(res);
                out_match.* = false;
                return cy.TypeValue.init(param_t, undefined);
            }
            ct_value = res;
        } else {
            const res = try c.semaExprTarget(arg.node, param_t);
            if (res.type.id() != param_t.id()) {
                out_match.* = false;
                return cy.TypeValue.init(param_t, undefined);
            }
            const val = cy.Value.initPtr(res.ir);
            ct_value = cy.TypeValue.init(param_t, val);
        }
    } else {
        return c.reportErrorFmt("TODO: {}", &.{v(arg.type)}, arg.node);
        // ct_value = cy.TypeValue.init(c.sema.void_t, cy.Value.Void);
        // out_match.* = false;
        // return ct_value;
    }
    out_match.* = true;
    return ct_value;
}

fn matchArgCt(c: *cy.Chunk, arg: *ast.Node, param: sema.FuncParam, req_value: bool, out_match: *bool) !cy.TypeValue {
    const param_t = param.get_type();
    _ = req_value;
    var ct_value: cy.TypeValue = undefined;
    if (param_t == c.sema.code_t) {
        const val = cy.Value.initPtr(arg);
        ct_value = cy.TypeValue.init(c.sema.code_t, val);
    } else {
        ct_value = try cte.evalTarget(c, arg, param_t);
        if (ct_value.type != param_t) {
            // Only the type is kept for the error message. The value is released here.
            const arg_t = ct_value.type;
            c.heap.destructValue(ct_value);
            out_match.* = false;
            return cy.TypeValue.init(arg_t, undefined);
        }
    }
    out_match.* = true;
    return ct_value;
}

fn matchArg(c: *cy.Chunk, arg: Argument, param: sema.FuncParam, overloaded: bool, exact: bool, out_match: *bool) !sema.ExprResult {
    if (exact and arg.type == .standard and !int_literal_fits_exact(arg.node, param.get_type())) {
        // An integer literal is an exact match only for integer parameters. It still fits `float` in the second pass.
        out_match.* = false;
        return sema.ExprResult.initVoid(c.sema.i64_t);
    }
    var res = try resolveRtArg(c, arg, arg.node, param, overloaded, !exact);
    if (res.resType == .infer_error) {
        // Only set for an overload: the argument can not take the type of the parameter.
        out_match.* = false;
        return res;
    }
    res = try ownOrManageArg(c, res, arg.node);

    const ct_compat = cy.types.isTypeCompat(c.compiler, res.type, param.get_type());
    if (!ct_compat) {
        // Check to fit
        out_match.* = false;
        return res;
    }

    out_match.* = true;
    return res;
}

fn int_literal_fits_exact(node: *ast.Node, param_t: *cy.Type) bool {
    switch (node.type()) {
        .decLit, .binLit, .octLit, .hexLit => {
            return param_t.kind() == .int or param_t.kind() == .raw;
        },
        else => return true,
    }
}

pub fn reportCallFuncMismatch2(c: *cy.Chunk, pre_args: []const Argument, end_args: []const *ast.Node, func_: *cy.Func, match_err: FuncMatchError, node: *ast.Node) anyerror {
    var func = func_;
    if (c.reuse_call) |reuse| {
        if (reuse.node == node) {
            // The script wrote the new-list method.
            func = reuse.writtenFunc(func) orelse func;
        }
    }
    return reportCallFuncMismatch3(c, pre_args, end_args, func.name(), func.sig, func, match_err, node);
}

/// A method that changes its receiver in place (`&>T`) called on a `^T`: name the `.*` form.
/// `^T` does not turn into `&>T` on its own, since other references may share the value.
fn refReceiverHint(c: *cy.Chunk, param_t: *cy.Type, arg_t: *cy.Type, rec_n: *ast.Node, func_name: []const u8, buf: []u8) []const u8 {
    if (param_t.kind() != .ex_borrow or arg_t.kind() != .pointer) return "";
    const pointer = arg_t.cast(.pointer);
    if (!pointer.ref or pointer.child_t != param_t.cast(.ex_borrow).child_t) return "";
    const rec_src = c.nodeString(rec_n);
    if (!isShortSrc(rec_src)) return "";
    return std.fmt.bufPrint(buf, " To change the value that `{s}` points to, write `{s}.*.{s}(...)`.", .{rec_src, rec_src, func_name}) catch "";
}

pub fn reportCallFuncMismatch(c: *cy.Chunk, pre_args: []const Argument, end_args: []const *ast.Node, func_name: []const u8, sig: *cy.FuncSig, match_err: FuncMatchError, node: *ast.Node) anyerror {
    return reportCallFuncMismatch3(c, pre_args, end_args, func_name, sig, null, match_err, node);
}

fn reportCallFuncMismatch3(c: *cy.Chunk, pre_args: []const Argument, end_args: []const *ast.Node, func_name: []const u8, sig: *cy.FuncSig, func: ?*cy.Func, match_err: FuncMatchError, node: *ast.Node) anyerror {
    const sig_str = try c.sema.allocFuncSigStr(sig, true, c);
    defer c.alloc.free(sig_str);

    const num_call_args = pre_args.len + end_args.len;
    // if (err_arg == num_call_args) {
    //     std.debug.assert(err_arg > 0);
    //     const arg_idx = err_arg - 1;
    //     const err_node = if (arg_idx < pre_args.len) pre_args[arg_idx].node else end_args[arg_idx];
    //     return c.reportErrorFmt("Missing subsequent argument to match the function `fn {}{}`", &.{v(name), v(sig_str)}, err_node);
    // }

    if (match_err.arg == 0) {
        return c.reportErrorFmt("Expected `{}` arguments, found `{}`, when calling the function `fn {}{}`.", &.{v(sig.params_len), v(num_call_args), v(func_name), v(sig_str)}, node);
    }

    const arg_idx = match_err.arg - 1;
    const err_node = if (arg_idx < pre_args.len) pre_args[arg_idx].node else end_args[arg_idx-pre_args.len];

    const paramt_name = try c.sema.allocTypeName(match_err.param.get_type());
    defer c.alloc.free(paramt_name);
    const argt_name = try c.sema.allocTypeName(match_err.arg_t);
    defer c.alloc.free(argt_name);
    if (arg_idx > 0) {
        // `a[i]` and `a[i..j]` call `@index` and `@slice`. Name what the script wrote, not the hook.
        const what: ?[]const u8 = if (std.mem.eql(u8, func_name, "@slice"))
            "A slice bound"
        else if (arg_idx == 1 and (std.mem.eql(u8, func_name, "@index") or std.mem.eql(u8, func_name, "@set_index") or std.mem.eql(u8, func_name, "@index_addr")))
            "An index"
        else
            null;
        if (what == null and arg_idx == 2 and std.mem.eql(u8, func_name, "@set_index")) {
            // `a[i] = v`: name the container and its element type.
            var rec_t = sig.params()[0].get_type();
            switch (rec_t.kind()) {
                .pointer => rec_t = rec_t.cast(.pointer).child_t,
                .borrow => rec_t = rec_t.cast(.borrow).child_t,
                .ex_borrow => rec_t = rec_t.cast(.ex_borrow).child_t,
                else => {},
            }
            const rec_name = try c.sema.allocTypeName(rec_t);
            defer c.alloc.free(rec_name);
            const hint: []const u8 = switch (match_err.arg_t.kind()) {
                .option => " Unwrap it first: `if x |v|:` or `x.?`.",
                .result => " Unwrap it with `!` first, or handle the error with `!else` or `try`.",
                else => "",
            };
            return c.reportErrorFmt("An element of `{}` must be `{}`, got `{}`.{}", &.{v(rec_name), v(paramt_name), v(argt_name), v(hint)}, err_node);
        }
        if (what) |what_| {
            const hint: []const u8 = switch (match_err.arg_t.kind()) {
                .option => " Unwrap it first: `if s.index(x) |i|:` or `x.?`.",
                .result => " Unwrap it with `!` first, or handle the error with `!else` or `try`.",
                else => "",
            };
            return c.reportErrorFmt("{} must be `{}`, got `{}`.{}", &.{v(what_), v(paramt_name), v(argt_name), v(hint)}, err_node);
        }
    }
    if (arg_idx == 1 and pre_args.len > 0 and sig.params_len == 2) {
        if (binaryOpVerb(func_name)) |verb| {
            // `a > b` calls `fn >(T, T)`. Name the operator, not the function.
            const left_n = pre_args[0].node;
            var left_t = sig.params()[0].get_type();
            switch (left_t.kind()) {
                .borrow => left_t = left_t.cast(.borrow).child_t,
                .ex_borrow => left_t = left_t.cast(.ex_borrow).child_t,
                else => {},
            }
            const left_name = try c.sema.allocTypeName(left_t);
            defer c.alloc.free(left_name);
            var hint: []const u8 = " Convert one side so that both have the same type.";
            const left_src = c.nodeString(left_n);
            const right_src = c.nodeString(err_node);
            if (left_t.id() == bt.Str and isNumberType(match_err.arg_t) and isShortSrc(left_src) and isShortSrc(right_src)) {
                if (std.mem.eql(u8, func_name, "+")) {
                    hint = std.fmt.bufPrint(&op_hint_buf, " To join them, write `'%{{{s}}}%{{{s}}}'`.", .{left_src, right_src}) catch hint;
                } else {
                    hint = std.fmt.bufPrint(&op_hint_buf, " Convert one side: `{s}({s})` or `'%{{{s}}}'`.", .{argt_name, left_src, right_src}) catch hint;
                }
            }
            if (verb == .compare) {
                return c.reportErrorFmt("Can not compare `{}` with `{}`.{}", &.{v(left_name), v(argt_name), v(hint)}, err_node);
            }
            return c.reportErrorFmt("Can not apply `{}` to `{}` and `{}`.{}", &.{v(func_name), v(left_name), v(argt_name), v(hint)}, err_node);
        }
    }
    // A text and bytes pair (`os.write_file` and `os.write_file_bytes`): name the other function.
    // A value from the other function of the pair (`os.read_file(p)!` for `[]byte`) is named first.
    var hint = try sema_hint.resultTypeHint(c, match_err.param.get_type(), match_err.arg_t, err_node);
    var rec_hint_buf: [256]u8 = undefined;
    if (hint.len == 0 and arg_idx == 0 and pre_args.len > 0 and pre_args[0].type == .receiver) {
        hint = refReceiverHint(c, match_err.param.get_type(), match_err.arg_t, err_node, func_name, &rec_hint_buf);
    }
    if (hint.len == 0) {
        if (func) |f| hint = try sema_hint.callArgHint(c, f, match_err.arg_t);
    }
    if (hint.len == 0) {
        hint = closureArgHint(match_err.param.get_type(), match_err.arg_t);
    }
    return c.reportErrorFmt("Expected argument `{}`, found `{}`, when calling `fn {}{}`.{}", &.{v(paramt_name), v(argt_name), v(func_name), v(sig_str), v(hint)}, err_node);
}

var op_hint_buf: [256]u8 = undefined;

const OpVerb = enum { compare, apply };

/// The verb for a binary operator function, or null for any other function.
fn binaryOpVerb(name: []const u8) ?OpVerb {
    const compare = [_][]const u8{ "<", "<=", ">", ">=" };
    for (compare) |op| {
        if (std.mem.eql(u8, name, op)) return .compare;
    }
    const apply = [_][]const u8{ "+", "-", "*", "/", "%", "**", "&&", "||", "~", "<<", ">>" };
    for (apply) |op| {
        if (std.mem.eql(u8, name, op)) return .apply;
    }
    return null;
}

fn isNumberType(t: *cy.Type) bool {
    return t.kind() == .int or t.kind() == .float;
}

/// A number type or a raw integer that is not a name (`symbol` and `error` are distinct raw types).
fn isNumberOrRaw(t: *cy.Type) bool {
    return isNumberType(t) or (t.kind() == .raw and !t.cast(.raw).distinct);
}

fn isShortSrc(src: []const u8) bool {
    return src.len > 0 and src.len <= 30 and std.mem.indexOfScalar(u8, src, '\n') == null;
}

fn expectTypeFromTemplate(c: *cy.Chunk, type_: *cy.Type, exp: *cy.sym.Template, soft: bool, node: *ast.Node) !*cy.Instance {
    const variant = type_.sym().instance orelse {
        if (soft) return error.InferMismatch;
        const name = try c.sema.allocTypeName(type_);
        defer c.alloc.free(name);
        return c.reportErrorFmt("Expected `{}` to be an expanded type.", &.{v(name)}, node);
    };

    if (variant.type != .sym or variant.data.sym.template != exp) {
        if (soft) return error.InferMismatch;
        return c.reportErrorFmt("Expected template `{}`. Found `{}`.", &.{v(exp.head.name()), v(variant.data.sym.template.head.name())}, node);
    }
    return variant;
}

/// The arguments of a type alias template while its target is matched: `T` and `%U` of `f MapFn[T, %U]`
/// for the target `fn(A) -> B` of `type MapFn[A Any, B Any] = fn(A) -> B`.
const AliasArgs = struct {
    template: *cy.sym.Template,
    args: []const *ast.Node,
    /// The alias arguments that `args` are written in. `null` for the signature of the function template.
    parent: ?*const AliasArgs,

    fn find(self: *const AliasArgs, name: []const u8) ?*ast.Node {
        for (self.template.decl.params, 0..) |param, i| {
            if (std.mem.eql(u8, param.name_type.as_name(), name)) {
                return self.args[i];
            }
        }
        return null;
    }
};

/// The symbol that a node of a parameter type names, looked up where the node is written.
fn evalInferSym(c: *cy.Chunk, template_ctx: *sema_resolve.ResolveContext, alias: ?*const AliasArgs, node: *ast.Node) !*cy.Sym {
    if (alias) |alias_| {
        try sema_resolve.pushSymResolveContext(c, @ptrCast(alias_.template), node);
        defer sema_resolve.popResolveContext(c);
        return cte.evalSym(c, node);
    }
    try sema_resolve.pushSavedResolveContext(c, template_ctx.*);
    defer template_ctx.* = sema_resolve.saveResolveContext(c);
    return cte.evalSym(c, node);
}

fn expectTypeArg(c: *cy.Chunk, arg: cy.TypeValue, soft: bool, node: *ast.Node) !*cy.Type {
    if (arg.type.id() != bt.Type) {
        if (soft) return error.InferMismatch;
        return c.reportErrorFmt("Expected type.", &.{}, node);
    }
    return arg.value.asPtr(*cy.Type);
}

/// Binds the infer parameters (`%T`) of the type specifier `template_n` from the type of an argument.
/// The specifier and the type are walked together: `[]%T` binds `T` from the element type of a slice,
/// `fn(T) -> %U` binds `U` from the return type of a function.
/// The parts of the specifier that declare no infer parameter are not checked here. The caller evaluates
/// the specifier once its parameters are bound and checks the argument against that type.
/// `alias` is set while `template_n` is a node of the target of a type alias template.
/// With `soft`, an argument type that does not have the form of the specifier (`float` for `?%T`, a closure
/// for `fn(T) -> %U`) is `error.InferMismatch` instead of a report: an overload that the call does not match.
fn inferCtArgs(c: *cy.Chunk, arg: cy.TypeValue, template: *cy.sym.FuncTemplate, template_ctx: *sema_resolve.ResolveContext, template_n: *ast.Node, alias: ?*const AliasArgs, soft: bool, node: *ast.Node) !void {
    switch (template_n.type()) {
        .infer_param => {
            const name = template_n.cast(.infer_param).name.as_name();
            if (template_ctx.hasCtParam(name)) {
                // Bound by an earlier use: `f Bin[%T]` for `type Bin[A Any] = fn(A, A) -> A`.
                return;
            }
            const new = try c.heap.copyValue2(arg.type, arg.value);
            try template_ctx.initCtParam(c.alloc, name, cy.TypeValue.init(arg.type, new));
        },
        .ident => {
            if (alias) |alias_| {
                if (alias_.find(template_n.as_name())) |alias_arg| {
                    // A parameter of the alias. Continue with the argument that it stands for.
                    try inferCtArgs(c, arg, template, template_ctx, alias_arg, alias_.parent, soft, node);
                }
            }
        },
        .span_type => {
            const span_type = template_n.cast(.span_type);
            const arg_t = try expectTypeArg(c, arg, soft, node);
            const variant = try expectTypeFromTemplate(c, arg_t, c.sema.span_tmpl, soft, node);
            try inferCtArgs(c, variant.getParamAt(0), template, template_ctx, span_type.child, alias, soft, node);
        },
        .slice_type => {
            const slice_type = template_n.cast(.slice_type);
            const arg_t = try expectTypeArg(c, arg, soft, node);
            const variant = try expectTypeFromTemplate(c, arg_t, c.sema.slice_tmpl, soft, node);
            try inferCtArgs(c, variant.getParamAt(0), template, template_ctx, slice_type.child, alias, soft, node);
        },
        .vector_type => {
            const vector_t = template_n.cast(.vector_type);
            const arg_t = try expectTypeArg(c, arg, soft, node);
            const variant = try expectTypeFromTemplate(c, arg_t, c.sema.vector_tmpl, soft, node);
            try inferCtArgs(c, variant.getParamAt(0), template, template_ctx, vector_t.child, alias, soft, node);
            try inferCtArgs(c, variant.getParamAt(1), template, template_ctx, vector_t.n, alias, soft, node);
        },
        .partial_vector_type => {
            const vector_t = template_n.cast(.partial_vector_type);
            const arg_t = try expectTypeArg(c, arg, soft, node);
            const variant = try expectTypeFromTemplate(c, arg_t, c.sema.partial_vector_tmpl, soft, node);
            try inferCtArgs(c, variant.getParamAt(0), template, template_ctx, vector_t.child, alias, soft, node);
            try inferCtArgs(c, variant.getParamAt(1), template, template_ctx, vector_t.n, alias, soft, node);
        },
        .ref => {
            const ref = template_n.cast(.ref);
            const arg_t = try expectTypeArg(c, arg, soft, node);
            const variant = try expectTypeFromTemplate(c, arg_t, c.sema.ref_tmpl, soft, node);
            try inferCtArgs(c, variant.getParamAt(0), template, template_ctx, ref.child, alias, soft, node);
        },
        .option_type => {
            const option_type = template_n.cast(.option_type);
            const arg_t = try expectTypeArg(c, arg, soft, node);
            const variant = try expectTypeFromTemplate(c, arg_t, c.sema.option_tmpl, soft, node);
            try inferCtArgs(c, variant.getParamAt(0), template, template_ctx, option_type.child, alias, soft, node);
        },
        .unary_expr => {
            // `!%T`. The result type is parsed as a unary expression. Any other unary expression is a
            // value (`not flag`) that declares no infer parameter.
            const unary = template_n.cast(.unary_expr);
            if (unary.op != .lnot or arg.type.id() != bt.Type) {
                return;
            }
            const arg_t = arg.value.asPtr(*cy.Type);
            const variant = try expectTypeFromTemplate(c, arg_t, c.sema.result_tmpl, soft, node);
            try inferCtArgs(c, variant.getParamAt(0), template, template_ctx, unary.child, alias, soft, node);
        },
        .borrow => {
            const borrow = template_n.cast(.borrow);
            const arg_t = try expectTypeArg(c, arg, soft, node);
            if (arg_t.kind() == .func_ptr or arg_t.kind() == .func) {
                // A function or a closure for a `&OpaqueFunc[fn(T) -> %U]` parameter. It is borrowed once
                // the parameter type is known.
                return inferCtArgs(c, arg, template, template_ctx, borrow.child, alias, soft, node);
            }
            const variant = try expectTypeFromTemplate(c, arg_t, c.sema.borrow_tmpl, soft, node);
            try inferCtArgs(c, variant.getParamAt(0), template, template_ctx, borrow.child, alias, soft, node);
        },
        .fn_type => {
            // `fn(T) -> %U`. Each parameter type and the return type are matched with those of the function.
            const func_type = template_n.cast(.fn_type);
            const arg_t = try expectTypeArg(c, arg, soft, node);
            if (arg_t.kind() != .func_ptr) {
                if (soft) return error.InferMismatch;
                const name = try c.sema.allocTypeName(arg_t);
                defer c.alloc.free(name);
                if (arg_t.kind() == .func) {
                    return c.reportErrorFmt("Expected a function for `{}`. Found the closure `{}`. A closure is passed to a `Func[fn(...)]` or a `&OpaqueFunc[fn(...)]` parameter.", &.{v(c.nodeString(template_n)), v(name)}, node);
                }
                return c.reportErrorFmt("Expected a function for `{}`. Found `{}`.", &.{v(c.nodeString(template_n)), v(name)}, node);
            }
            const sig = arg_t.cast(.func_ptr).sig;
            const params = sig.params();
            if (params.len != func_type.params.len) {
                if (soft) return error.InferMismatch;
                const name = try c.sema.allocTypeName(arg_t);
                defer c.alloc.free(name);
                return c.reportErrorFmt("Expected a function with `{}` parameter(s) for `{}`. Found `{}`.", &.{v(func_type.params.len), v(c.nodeString(template_n)), v(name)}, node);
            }
            for (func_type.params.slice(), 0..) |param, i| {
                const param_arg = cy.TypeValue.init(c.sema.type_t, Value.initPtr(params[i].get_type()));
                try inferCtArgs(c, param_arg, template, template_ctx, param.type orelse param.name_type, alias, soft, node);
            }
            if (func_type.ret) |ret| {
                const ret_arg = cy.TypeValue.init(c.sema.type_t, Value.initPtr(sig.ret));
                try inferCtArgs(c, ret_arg, template, template_ctx, ret, alias, soft, node);
            }
        },
        .index_expr => {
            // Infer nested. (e.g. `A[%T]`)
            const index_expr = template_n.cast(.index_expr);
            const template_t = try evalInferSym(c, template_ctx, alias, index_expr.left);
            if (template_t.type != .template) {
                return c.reportErrorFmt("Expected template. Found `{}`.", &.{v(template_t.type)}, index_expr.left);
            }
            const exp_template = template_t.cast(.template);

            if (exp_template.kind == .type_alias and exp_template.decl.child_decl.type() == .type_alias_decl) {
                // `MapFn[T, %U]`. An alias has no type of its own: match the target with the alias arguments.
                if (exp_template.decl.params.len != index_expr.args.len) {
                    return c.reportErrorFmt("Expected `{}` args. Found `{}`.", &.{v(exp_template.decl.params.len), v(index_expr.args.len)}, template_n);
                }
                const alias_args = AliasArgs{
                    .template = exp_template,
                    .args = index_expr.args.slice(),
                    .parent = alias,
                };
                const target_n = exp_template.decl.child_decl.cast(.type_alias_decl).target;
                return inferCtArgs(c, arg, template, template_ctx, target_n, &alias_args, soft, node);
            }

            if (arg.type.id() == bt.Type) {
                const arg_t = arg.value.asPtr(*cy.Type);

                if (arg_t.kind() == .func_ptr and index_expr.args.len == 1) {
                    if (exp_template == c.sema.func_tmpl or exp_template == c.sema.opaque_func_tmpl) {
                        // A function for a `Func[fn(T) -> %U]` parameter. It is wrapped once the parameter
                        // type is known.
                        return inferCtArgs(c, arg, template, template_ctx, index_expr.args.ptr[0], alias, soft, node);
                    }
                }

                const variant = arg_t.sym().instance orelse {
                    if (soft) return error.InferMismatch;
                    const name = try c.sema.allocTypeName(arg_t);
                    defer c.alloc.free(name);
                    return c.reportErrorFmt("Expected `{}` to be an expanded type.", &.{v(name)}, node);
                };

                if (variant.type != .sym) {
                    if (soft) return error.InferMismatch;
                    const name = try c.sema.allocTypeName(arg_t);
                    defer c.alloc.free(name);
                    return c.reportErrorFmt("Expected template `{}`. Found `{}`.", &.{v(template_t.name()), v(name)}, node);
                }
                if (variant.data.sym.template != exp_template) {
                    const is_func = exp_template == c.sema.func_tmpl or exp_template == c.sema.opaque_func_tmpl;
                    if (is_func and arg_t.kind() == .func and index_expr.args.len == 1) {
                        // A `Func` closure for an `OpaqueFunc` parameter. Both hold the same function type.
                        return inferCtArgs(c, variant.getParamAt(0), template, template_ctx, index_expr.args.ptr[0], alias, soft, node);
                    }
                    if (soft) return error.InferMismatch;
                    return c.reportErrorFmt("Expected template `{}`. Found `{}`.", &.{v(template_t.name()), v(variant.data.sym.template.head.name())}, node);
                }
                if (variant.params.len != index_expr.args.len) {
                    return c.reportErrorFmt("Expected `{}` args. Found `{}`.", &.{v(variant.params.len), v(index_expr.args.len)}, template_n);
                }
                for (0..variant.params.len) |i| {
                    try inferCtArgs(c, variant.getParamAt(i), template, template_ctx, index_expr.args.ptr[i], alias, soft, node);
                }
            } else {
               return c.reportErrorFmt("TODO: {}.", &.{v(arg.type.name())}, node);
            }
        },
        else => {
            // A type form that is not walked. It is fine when it declares no infer parameter (`int`, `?T`):
            // the caller checks it with the whole parameter type.
        }
    }
}

