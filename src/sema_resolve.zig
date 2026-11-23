const std = @import("std");
const stdx = @import("stdx");
const cy = @import("cyber.zig");
const C = @import("capi.zig");
const ir = cy.ir;
const bt = cy.types.BuiltinTypes;
const sema_type = cy.sema_type;
const ct_inline = cy.ct_inline;
const cte = cy.cte;
const fmt = cy.fmt;
const v = fmt.v;
const module = cy.module;
const ast = cy.ast;
const Sym = cy.Sym;
const Value = cy.Value;
const TypeValue = cy.TypeValue;
const log = cy.log.scoped(.sema);
const sema = cy.sema;
const sema_local = cy.sema_local;
const sema_expr = cy.sema_expr;

pub fn reserveFuncTemplateSym(c: *cy.Chunk, parent: *cy.Sym, name: []const u8, decl: *ast.TemplateDecl) !*cy.sym.FuncTemplate {
    return c.reserveFuncTemplateSym(parent, name, decl.params.len == 0, decl);
}

pub fn reserveTemplate(c: *cy.Chunk, node: *ast.TemplateDecl) !*cy.sym.Template {
    var name_n: *ast.Node = undefined;
    var template_t: cy.sym.TemplateType = undefined;
    switch (node.child_decl.type()) {
        .struct_decl => {
            name_n = node.child_decl.cast(.struct_decl).name;
            template_t = .struct_t;
        },
        .enumDecl => {
            name_n = node.child_decl.cast(.enumDecl).name;
            template_t = .enum_t;
        },
        .custom_type_decl => {
            name_n = node.child_decl.cast(.custom_type_decl).name;
            template_t = .custom_t;
        },
        .type_alias_decl => {
            name_n = node.child_decl.cast(.type_alias_decl).name;
            template_t = .type_alias;
        },
        .type_const_decl => {
            name_n = node.child_decl.cast(.type_const_decl).name;
            template_t = .type_const;
        },
        .trait_decl => {
            name_n = node.child_decl.cast(.trait_decl).name;
            template_t = .trait_t;
        },
        else => {
            return c.reportErrorFmt("Unsupported type template.", &.{}, @ptrCast(node));
        }
    }
    return c.reserveTemplate(&c.sym.head, name_n.declName(), template_t, node);
}

pub fn resolveGenericFunc(c: *cy.Chunk, func: *cy.Func, sig: *cy.FuncSig, params: []cy.sym.FuncTemplateParam) !void {
    const decl = func.decl.?.cast(.funcDecl);
    const template = c.alloc.create(cy.sym.FuncTemplate) catch |err| {
        for (params) |param| {
            param.deinit(c.alloc);
        }
        c.alloc.free(params);
        return err;
    };
    template.* = .{
        .head = cy.Sym.init(.func_template, func.parent.parent.?, func.name()),
        .func_params = decl.params.slice(),
        .func_ret = decl.ret,
        .sig = sig,
        .with_cstrs = &.{},
        .params = params,
        .resolved = true,
        .callable = true,
        .decl = @ptrCast(decl),
        .instance_cache = .empty,
        .instances = .empty,
        .mod = undefined,
    };
    // The kind changes together with its payload. `Func.destroy` and `deinit_func_ct_values` read `data.generic`
    // from the kind alone.
    func.type = .generic;
    func.data = .{ .generic = template };
    try c.resolveFunc(func, sig);
}

pub fn resolveFuncTemplate(c: *cy.Chunk, template: *cy.sym.FuncTemplate) !void {
    try pushSymResolveContext(c, @ptrCast(template), @ptrCast(template.decl));
    defer popResolveContext(c);

    const decl = template.decl.cast(.template);
    template.params = try c.alloc.alloc(cy.sym.FuncTemplateParam, decl.params.len);
    var param_group_end: usize = cy.NullId;
    for (decl.params, 0..) |param, idx| {
        const name = param.name_type.as_name();
        var type_idx: u32 = undefined;
        if (param.type == null) {
            if (param_group_end == cy.NullId or idx > param_group_end) {
                param_group_end = indexOfTypedParam(decl.params, idx+1) orelse {
                    return c.reportError("Expected parameter type.", @ptrCast(param));
                };
            }
            type_idx = @intCast(param_group_end);
        } else {
            type_idx = @intCast(idx);
        }
        template.params[idx] = .{
            .anonymous = false,
            .name = name,
            .type_idx = type_idx,
        };
    }

    const func_decl = decl.child_decl.cast(.funcDecl);
    if (func_decl.with) |with| {
        template.with_cstrs = try resolve_with_cstrs(c, with);
    }

    template.resolved = true;
}

fn resolve_with_cstrs(c: *cy.Chunk, with: *ast.With) ![]cy.sym.WithCstr {
    const with_cstrs = try c.alloc.alloc(cy.sym.WithCstr, with.params.len);
    for (with.params.slice(), 0..) |param, i| {
        const param_name = param.name_type.as_name();
        const cstr_t = try cte.eval_type2(c, false, param.type.?);
        with_cstrs[i] = .{
            .name = param_name,
            .cstr_t = cstr_t,
        };
    }
    return with_cstrs;
}

pub fn ensure_resolved_instance_func_decl(c: *cy.Chunk, decl: *cy.sym.VariantFuncDecl) !void {
    if (decl.resolved) {
        return;
    }
    if (decl.decl.with) |with| {
        const cstrs = try resolve_with_cstrs(c, with);
        decl.with_cstrs = .{ .ptr = cstrs.ptr, .len = cstrs.len };
    }
    decl.resolved = true;
}

pub fn check_instance_func_cstr(c: *cy.Chunk, instance: *cy.Instance, decl: *cy.sym.VariantFuncDecl, node: *ast.Node) !void {
    for (decl.with_cstrs.slice()) |cstr| {
        const param = instance.getParam(cstr.name) orelse {
            return c.reportErrorFmt("Expected parameter type `{}`.", &.{v(cstr.name)}, node);
        };
        const impl_t = param.value.asPtr(*cy.Type);
        if (!try sema_type.implements(c, impl_t, cstr.cstr_t.cast(.generic_trait), node)) {
            const impl_name = try c.sema.allocTypeName(impl_t);
            defer c.alloc.free(impl_name);
            const trait_name = try c.sema.allocTypeName(cstr.cstr_t);
            defer c.alloc.free(trait_name);
            return c.reportErrorFmt("Expected `{}` to implement `{}`.", &.{v(impl_name), v(trait_name)}, node);
        }
    }
}

pub fn resolveTemplate(c: *cy.Chunk, sym: *cy.sym.Template) !void {
    try pushSymResolveContext(c, @ptrCast(sym), @ptrCast(sym.decl));
    defer popResolveContext(c);

    const tparams = try c.alloc.alloc(cy.sym.TemplateParam, sym.decl.params.len);
    errdefer c.alloc.free(tparams);
    for (sym.decl.params, 0..) |param, i| {
        const param_name = param.name_type.nameOrNull() orelse {
            return c.reportErrorFmt("Expected name, found {}.", &.{v(param.name_type.type())}, param.name_type);
        };
        tparams[i] = .{
            .name = param_name,
        };
    }
    sym.params = tparams;
}

pub fn reserveUseAlias(c: *cy.Chunk, node: *ast.UseAlias) !*cy.sym.UseAlias {
    const name = node.name.as_name();
    return c.reserveUseAlias(@ptrCast(c.sym), name, @ptrCast(node));
}

pub fn resolveUseAlias(c: *cy.Chunk, sym: *cy.sym.UseAlias) anyerror!void {
    if (sym.resolved) {
        return;
    }

    if (sym.resolve_with_sym) {
        if (sym.sym.type == .chunk) {
            // Already points to a sym but needs to ensure module is loaded.
            try pushSymResolveContext(c, @ptrCast(sym), @ptrCast(sym.decl));
            defer popResolveContext(c);
            const chunk_sym = sym.sym.cast(.chunk);
            try cy.compiler.loadChunk(chunk_sym.chunk);
        } else if (sym.sym.type == .type_alias) {
            // Alias points to a type alias.
            try pushSymResolveContext(c, @ptrCast(sym.sym), @ptrCast(sym.decl));
            defer popResolveContext(c);
            try sema_type.resolve_type_alias(c, sym.sym.cast(.type_alias));
            sym.sym = &sym.sym.cast(.type_alias).sym.head;
        } else if (sym.sym.type == .use_alias) {
            // Alias points to another alias.
            try pushSymResolveContext(c, @ptrCast(sym.sym), @ptrCast(sym.decl));
            defer popResolveContext(c);
            try resolveUseAlias(c, sym.sym.cast(.use_alias));
            sym.sym = sym.sym.cast(.use_alias).sym;
        }
        sym.resolved = true;
    } else {
        try pushSymResolveContext(c, @ptrCast(sym), @ptrCast(sym.decl));
        defer popResolveContext(c);

        const r_sym = try cte.evalSym(c, sym.decl.?.cast(.use_alias).target);
        sym.sym = r_sym;
        sym.resolved = true;
    }
}

pub fn declareUseImport(c: *cy.Chunk, node: *ast.ImportStmt) !void {
    for (node.attrs.slice()) |attr| {
        if (attr.type == .cond) {
            const res = try cte.evalCheck(c, attr.value.?, c.sema.bool_t);
            if (!res.value.asBool()) {
                // Skip import.
                return;
            }
        }
    }

    var specPath: []const u8 = undefined;
    if (node.spec) |spec| {
        if (spec.type() != .sq_string_lit) {
            // use alias.
            return c.reportErrorFmt("TODO", &.{}, spec);
        }
        specPath = spec.cast(.sq_string_lit).asString();
    } else {
        if (node.name.type() == .ident) {
            // Single ident import.
            specPath = node.name.cast(.ident).name.slice();
        } else {
            // `use os.read_file`: a symbol of a module is used through an alias.
            const path = c.nodeString(node.name);
            if (node.name.type() == .accessExpr) {
                const last = c.nodeString(node.name.cast(.accessExpr).right);
                return c.reportErrorFmt("Expected a module name. A symbol of a module is used through an alias: `use {} = {}`.", &.{v(last), v(path)}, @ptrCast(node));
            }
            return c.reportErrorFmt("Expected a module name, found `{}`.", &.{v(path)}, @ptrCast(node));
        }
    }

    var buf: [4096]u8 = undefined;
    const uri = try cy.compiler.resolveModuleUriFrom(c, &buf, specPath, node.spec);

    const import_c = try cy.compiler.ensureModule(c.compiler, uri);
    try c.imports.append(c.alloc, import_c);
    if (import_c.importer == null) {
        import_c.importer = @ptrCast(node);
    }

    if (node.name.type() == .all) {
        // Block on * import until it's symbols have been reserved.
        try cy.compiler.loadChunk(import_c);

        // Import all symbols into this module.
        for (import_c.syms.items) |sym| {
            if (sym.getMetadata().private) {
                continue;
            }
            const alias = try c.reserveUseAlias(@ptrCast(c.sym), sym.name(), @ptrCast(node));
            alias.sym = sym;
            alias.resolve_with_sym = true;
        }
    } else {
        const name = node.name.as_name();
        const alias = try c.reserveUseAlias(@ptrCast(c.sym), name, @ptrCast(node));
        alias.sym = @ptrCast(import_c.sym);
        alias.resolve_with_sym = true;
    }
}

// TODO: Rename to SemaContextKind
const ResolveContextType = enum(u8) {
    chunk,
    sym,
    func,
};

pub const InferParamMode = enum(u8) {
    /// Not a place that declares infer parameters. `%T` is reported as an error.
    none,
    /// A parameter type. `error.FoundInferParam` is returned to the caller, which must handle it.
    param,
    /// A return type. `%T` is reported as an error that points to the parameters.
    ret,
    /// A parameter type at a call. `%T` is the value that an argument bound. `error.FoundInferParam` is returned
    /// for a parameter that no argument bound yet.
    bound,
    /// Like `bound`, but a parameter that is not bound yet is the placeholder type `Sema.infer_t`.
    /// Tells which parts of a parameter type are known before its argument is analysed.
    placeholder,
};

pub const CtParam = struct {
    type_header: u64,
    value: Value,

    pub fn initParam(value: cy.TypeValue) CtParam {
        return .{ .type_header = @intFromPtr(value.type), .value = value.value };
    }

    pub fn initVar(value: cy.TypeValue) CtParam {
        return .{ .type_header = @as(u64, 1 << 63) | @intFromPtr(value.type), .value = value.value };
    }

    pub fn getType(self: *const CtParam) *cy.Type {
        const addr: usize = @intCast(self.type_header & ~(@as(u64, 1) << 63));
        return @ptrFromInt(addr);
    }

    pub fn isVar(self: *const CtParam) bool {
        return (self.type_header & (1 << 63)) > 0;
    }
};

// TODO: Rename to SemaContext
pub const ResolveContext = struct {
    type: ResolveContextType,
    has_ct_params: bool,

    /// Prefer the comptime type when encountering a runtime type. (e.g. For template param types)
    prefer_ct_type: bool = false,

    allow_rt_stmts: bool = true,

    /// Compile-time params in this context.
    /// TODO: Avoid hash map if 2 or fewer ct params.
    ct_params: std.StringHashMapUnmanaged(CtParam),

    ct_locals: std.ArrayList([]const u8),

    is_inline_eval: bool = false,

    /// What an infer parameter (`%T`) means for the type specifier that is being evaluated.
    infer_param: InferParamMode = .none,

    chunk: *cy.Chunk,
    caller: ?*ast.Node,

    data: union {
        sym: *cy.Sym,
        func: *cy.Func,
    },

    pub fn deinit(self: *ResolveContext, c: *cy.Chunk) void {
        var iter = self.ct_params.iterator();
        while (iter.next()) |e| {
            const param = e.value_ptr.*;
            c.heap.destructValue2(param.getType(), param.value);
        }
        self.ct_params.deinit(c.alloc);
        self.ct_locals.deinit(c.alloc);
    }

    pub fn pushCtBlock(self: *ResolveContext) usize {
        return self.ct_locals.items.len;
    }

    pub fn popCtBlock(self: *ResolveContext, c: *cy.Chunk, local_start: usize) void {
        for (self.ct_locals.items[local_start..]) |local| {
            if (self.ct_params.contains(local)) {
                self.unsetCtParam(c.heap, local);
            }
        }
        self.ct_locals.items.len = local_start;
    }

    pub fn hasCtParam(self: *ResolveContext, name: []const u8) bool {
        return self.ct_params.contains(name);
    }

    pub fn initCtParam(self: *ResolveContext, alloc: std.mem.Allocator, name: []const u8, val: cy.TypeValue) !void {
        const res = try self.ct_params.getOrPut(alloc, name);
        if (res.found_existing) {
            return error.DuplicateParam;
        }
        res.value_ptr.* = CtParam.initParam(val);
    }

    pub fn initCtParam2(self: *ResolveContext, alloc: std.mem.Allocator, name: []const u8, val_t: *cy.Type, val: cy.Value) !void {
        try self.initCtParam(alloc, name, cy.TypeValue.init(val_t, val));
    }

    pub fn initCtVar(self: *ResolveContext, alloc: std.mem.Allocator, name: []const u8, val: cy.TypeValue) !void {
        const res = try self.ct_params.getOrPut(alloc, name);
        if (res.found_existing) {
            return error.DuplicateParam;
        }
        res.value_ptr.* = CtParam.initVar(val);
    }

    pub fn initCtVar2(self: *ResolveContext, alloc: std.mem.Allocator, name: []const u8, val_t: *cy.Type, val: cy.Value) !void {
        try self.initCtVar(alloc, name, cy.TypeValue.init(val_t, val));
    }

    pub fn setCtParam(self: *ResolveContext, heap: *cy.Heap, name: []const u8, val_t: *cy.Type, val: cy.Value) !void {
        const res = try self.ct_params.getOrPut(heap.alloc, name);
        if (res.found_existing) {
            const param = res.value_ptr.*;
            heap.destructValue2(param.getType(), param.value);
        }
        res.value_ptr.* = CtParam.initParam(cy.TypeValue.init(val_t, val));
    }

    pub fn setCtVar(self: *ResolveContext, heap: *cy.Heap, name: []const u8, val_t: *cy.Type, val: cy.Value) !void {
        const res = try self.ct_params.getOrPut(heap.alloc, name);
        if (res.found_existing) {
            const param = res.value_ptr.*;
            heap.destructValue2(param.getType(), param.value);
        }
        res.value_ptr.* = CtParam.initVar(cy.TypeValue.init(val_t, val));
    }

    pub fn unsetCtParam(self: *ResolveContext, heap: *cy.Heap, name: []const u8) void {
        const pair = self.ct_params.fetchRemove(name).?;
        heap.destructValue2(pair.value.getType(), pair.value.value);
    }

    pub fn getSelfSym(self: *const ResolveContext) ?*cy.Sym {
        if (self.type == .func) {
            if (self.data.func.parent.type == .func) {
                if (self.data.func.parent.parent.?.type == .type) {
                    return self.data.func.parent.parent.?;
                }
            } else if (self.data.func.parent.type == .func_template) {
                if (self.data.func.parent.parent.?.type == .type) {
                    return self.data.func.parent.parent.?;
                } else if (self.data.func.parent.parent.?.type == .func) {
                    if (self.data.func.parent.parent.?.parent.?.type == .type) {
                        // generic func variant under a type.
                        return self.data.func.parent.parent.?.parent.?;
                    }
                }
            }
        } else if (self.type == .sym) {
            if (self.data.sym.type == .type) {
                return self.data.sym;
            }
            if (self.data.sym.parent.?.type == .type) {
                return self.data.sym.parent.?;
            }
        }
        return null;
    }
};

pub fn pushSymResolveContext(c: *cy.Chunk, sym: *cy.Sym, caller: ?*ast.Node) !void {
    const new = ResolveContext{
        .type = .sym,
        .has_ct_params = false,
        .ct_params = .empty,
        .ct_locals = .empty,
        .chunk = c.compiler.chunks.items[sym.declNode().src()],
        .caller = caller,
        .data = .{ .sym = sym },
    };
    try pushResolveContext2(c, new, caller);
}

pub fn pushFuncResolveContext(c: *cy.Chunk, func: *cy.Func, caller: ?*ast.Node) !void {
    const new = ResolveContext{
        .type = .func,
        .has_ct_params = false,
        .ct_params = .empty,
        .ct_locals = .empty,
        .chunk = c.compiler.chunks.items[func.src()],
        .caller = caller,
        .data = .{ .func = func },
    };
    try pushResolveContext2(c, new, caller);
}

pub fn pushChunkResolveContext(c: *cy.Chunk, caller: ?*ast.Node) !void {
    const new = ResolveContext{
        .type = .chunk,
        .has_ct_params = false,
        .ct_params = .empty,
        .ct_locals = .empty,
        .chunk = c,
        .caller = caller,
        .data = undefined,
    };
    try pushResolveContext2(c, new, caller);
}

pub fn pushResolveContext2(c: *cy.Chunk, ctx: ResolveContext, node: ?*ast.Node) !void {
    // Maximum limit to prevent recursive template expansions.
    // TODO: Another approach might involve determining if expanding template args contain a derived type from a type parameter.
    //       If it does and the template is already expanding, it would be a cycle.
    if (c.resolve_stack.items.len > 20) {
        return c.reportError("Maximum resolve depth reached.", node);
    }
    try c.resolve_stack.append(c.alloc, ctx);
}

pub fn pushSavedResolveContext(c: *cy.Chunk, ctx: ResolveContext) !void {
    try c.resolve_stack.append(c.alloc, ctx);
}

pub fn popResolveContext(c: *cy.Chunk) void {
    const last = &c.resolve_stack.items[c.resolve_stack.items.len-1];
    last.deinit(c);
    c.resolve_stack.items.len -= 1;
}

pub fn saveResolveContext(c: *cy.Chunk) ResolveContext {
    const last = c.resolve_stack.items[c.resolve_stack.items.len-1];
    c.resolve_stack.items.len -= 1;
    return last;
}

pub fn reserve_func_instance(c: *cy.Chunk, template: *cy.sym.FuncTemplate, instance: *cy.Instance) !*cy.Func {
    var decl: *ast.FuncDecl = undefined;
    if (template.decl.type() == .funcDecl) {
        decl = template.decl.cast(.funcDecl);
    } else {
        decl = @ptrCast(@alignCast(template.decl.cast(.template).child_decl));
    }

    var extern_ = false;
    for (decl.attrs.slice()) |attr| {
        if (attr.type == .extern_) {
            extern_ = true;
        }
    }
    const config = cy.sym.FuncConfig{
        .is_method = decl.sig_t == .method,
        .extern_ = extern_,
    };
    const func = try c.createFunc(.unresolved, &template.head, config, @ptrCast(decl));
    func.instance = instance;
    try c.funcs.append(c.alloc, func);
    return func;
}

pub fn resolveFuncVariant(c: *cy.Chunk, func: *cy.Func, resolve_new_types: bool, node: ?*ast.Node) !void {
    if (func.isResolved()) {
        return;
    }

    const decl = func.decl.?.cast(.funcDecl);
    if (ast.findAttr(decl.attrs.slice(), .bind) != null) {
        func.type = .hostFunc;
        func.data = .{ .hostFunc = .{
            .ptr = undefined,
        }};
        try resolveHostFuncVariant(c, func, resolve_new_types, node);
    } else {
        func.type = .userFunc;
        func.data = .{.userFunc = .{.loc = undefined}};
        try resolveUserFuncVariant(c, func, resolve_new_types, node);
    }
}

/// With recovery, whether the declaration `decl` failed to resolve earlier in this compile. Its error was
/// reported there, so the caller fails with `error.CompileError` and no report of its own. It is marked failed
/// too, and the declaration that asked for it does not report an error caused by the first.
pub fn declFailed(c: *cy.Chunk, decl: *const anyopaque) bool {
    const compiler = c.compiler;
    return compiler.recover and compiler.reports.items.len > 0 and compiler.failed_decls.contains(decl);
}

/// With recovery, marks the declaration `decl` that failed to resolve (`declFailed`). Its state is half set:
/// a struct still resolving, a const without a value.
pub fn markDeclFailed(c: *cy.Chunk, decl: *const anyopaque) void {
    if (!c.compiler.recover) return;
    // Without memory the compile ends anyway, with the error that the caller returns.
    c.compiler.failed_decls.put(c.alloc, decl, {}) catch {};
}

pub fn ensure_resolved_func(c: *cy.Chunk, func: *cy.Func, resolve_new_types: bool, node: ?*ast.Node) !void {
    if (func.isResolved()) {
        return;
    }
    if (declFailed(c, func)) return error.CompileError;
    errdefer markDeclFailed(c, func);

    switch (func.type) {
        .unresolved,
        .trait => {
            // continue.
        },
        .reserved,
        .generic,
        .userFunc,
        .hostFunc,
        .extern_,
        .vm_extern_variant,
        .host_builtin,
        .host_const_eval => {
            return error.Unexpected;
        },
        .userLambda => {
            return;
        },
    }

    try pushFuncResolveContext(c, func, node);
    defer popResolveContext(c);

    const decl = func.decl.?.cast(.funcDecl);
    var bind_attr: ?*ast.Attribute = null;
    var extern_attr: ?*ast.Attribute = null;
    const has_generator = decl.generator;
    const builtin_mod = sema_expr.isBuiltinModuleNode(c, @ptrCast(decl));
    if (!builtin_mod) {
        const func_name = func.name();
        if (func_name.len > 0 and func_name[0] == '@' and !sema_expr.hook_names.has(func_name)) {
            return c.reportErrorFmt("Unknown hook `{}`. A function name can start with `@` only when it is a hook that the compiler calls, such as `@init` or `@deinit`.", &.{v(func_name)}, decl.name);
        }
    }
    for (decl.attrs.slice()) |attr| {
        if (!builtin_mod) {
            switch (attr.type) {
                .unsafe, .consteval, .reserve => {
                    return c.reportErrorFmt("The `#[{}]` attribute is reserved for the builtin modules.", &.{v(@tagName(attr.type))}, @ptrCast(attr));
                },
                else => {},
            }
        }
        switch (attr.type) {
            .bind => {
                bind_attr = attr;
            },
            .extern_ => {
                extern_attr = attr;
            },
            .consteval => {
                func.info.const_eval_only = true;
            },
            .reserve => {
                func.type = .reserved;
                const sig = try ensure_opaque_func_sig(c, decl.params.len);
                try c.resolveFunc(func, sig);
                return;
            },
            else => {},
        }
    }

    if (bind_attr != null) {
        const bind_func = try resolveHostBindFunc(c, func, bind_attr.?);
        if (bind_func.kind == C.BindFuncVm) {
            if (c.compiler.config.backend != C.BackendVM and decl.stmts.len == 0) {
                return c.reportError("Expected function implementation.", @ptrCast(func.decl));
            }
        } else if (bind_func.kind == C.BindFuncBuiltin) {
            const sig = try ensure_opaque_func_sig(c, decl.params.len);
            try c.resolveHostBuiltinFunc(func, sig, @ptrCast(@alignCast(bind_func.ptr)), @ptrCast(@alignCast(bind_func.ptr2)));
            return;
        }
    }

    var generic: GenericFuncResult = undefined;
    var sig = try resolveFuncSig(c, func, resolve_new_types, &generic, false);
    if (generic.generic) {
        try resolveGenericFunc(c, func, sig, generic.params);
    } else {
        if (bind_attr != null) {
            try resolveHostFunc(c, func, sig);
            return;
        }

        if (extern_attr) |attr| {
            if (func.isMethod()) {
                return c.reportError("@extern function cannot be a method.", @ptrCast(func.decl));
            }
            // The program init calls `@initBindLib` of the `c` module for an extern function. Without `c` loaded
            // that lookup is null, so the script is a compile error here instead.
            if (c.compiler.chunk_map.get("c") == null) {
                return c.reportError("An `#[extern]` function needs the `c` module. Add `use c`.", @ptrCast(func.decl));
            }
            func.type = .extern_;
            var extern_name = func.name();
            c.has_extern_func = true;
            if (try attr.getString()) |name| {
                extern_name = name;
            }
            func.data = .{
                .extern_ = try c.alloc.create(cy.sym.ExternFunc),
            };
            func.data.extern_.* = .{
                .name_ptr = extern_name.ptr,
                .name_len = @intCast(extern_name.len),
                .vm_variadic = false,
                .has_impl = decl.stmts.len > 0,
                .ir = undefined,
            };
            try c.resolveUserFunc(func, sig);
            if (sig.params_len > 0 and sig.params_ptr[sig.params_len-1].get_type().kind() == .c_variadic) {
                if (c.compiler.config.backend == C.BackendVM) {
                    func.data.extern_.vm_variadic = true;
                }
            }
            return;
        }

        if (has_generator) {
            sig = try resolveGeneratorSig(c, func, sig);
        }

        if (func.type == .trait) {
            try c.resolveUserFunc(func, sig);
        } else {
            if (decl.stmts.len == 0) {
                return c.reportError("Expected function body.", @ptrCast(decl));
            }
            func.type = .userFunc;
            func.data = .{.userFunc = .{.loc = undefined}};
            try c.resolveUserFunc(func, sig);
        }
    }
}

fn resolveHostFunc2(c: *cy.Chunk, func: *cy.Func, bind_func: C.BindFunc, sig: *sema.FuncSig) !void {
    switch (bind_func.kind) {
        C.BindFuncVm => {
            try c.resolveHostFunc(func, sig, @ptrCast(@alignCast(bind_func.ptr)), @ptrCast(@alignCast(bind_func.ptr2)));
        },
        C.BindFuncConstEval => {
            try c.resolveHostConstEvalFunc(func, sig, @ptrCast(@alignCast(bind_func.ptr)));
        },
        C.BindFuncDecl => {
            func.type = .userFunc;
            func.data = .{.userFunc = .{.loc = undefined}};
            try c.resolveUserFunc(func, sig);
            if (bind_func.ptr2) |eval| {
                func.data.userFunc.eval = @ptrCast(@alignCast(eval));
            }
        },
        else => {
            return c.reportErrorFmt("Unsupported", &.{}, func.decl);
        },
    }
}

fn resolveHostFunc(c: *cy.Chunk, func: *cy.Func, sig: *sema.FuncSig) !void {
    const decl = func.decl.?.cast(.funcDecl);
    const attr = ast.findAttr(decl.attrs.slice(), .bind).?;
    const bind_func = try resolveHostBindFunc(c, func, attr);
    try resolveHostFunc2(c, func, bind_func, sig);
}

pub fn resolveHostFuncVariant(c: *cy.Chunk, func: *cy.Func, resolve_new_types: bool, node: ?*ast.Node) !void {
    try pushFuncResolveContext(c, func, node);
    defer popResolveContext(c);

    var generic: GenericFuncResult = undefined;
    const sig = try resolveFuncSig(c, func, resolve_new_types, &generic, true);
    try resolveHostFunc(c, func, sig);
}

pub fn resolveHostBindFunc(c: *cy.Chunk, func: *cy.Func, host_attr: *ast.Attribute) !C.BindFunc {
    const src_c = c.compiler.chunks.items[func.src()];

    const host_name = try host_attr.getString();
    var name_buf: [128]u8 = undefined;
    const bind_name = host_name orelse b: {
        var w = std.Io.Writer.fixed(&name_buf);
        try cy.sym.writeFuncName(c.sema, &w, func, .{ .from = src_c, .emit_template_args = false });
        break :b w.buffered();
    };
    log.tracev("Lookup embedded func for: {s}", .{bind_name});
    return src_c.host_funcs.get(bind_name) orelse {
        return src_c.fallback_bind_func orelse {
            return c.reportErrorFmt("Host func `{}` failed to load.", &.{v(bind_name)}, @ptrCast(func.decl));
        };
    };
}

/// Marks `func` as a generator and returns its signature with the return type `^Generator[fn(params) -> T]`.
/// Template instances resolve through `resolveUserFuncVariant`, so this is shared with `ensure_resolved_func`.
fn resolveGeneratorSig(c: *cy.Chunk, func: *cy.Func, sig: *cy.FuncSig) !*cy.FuncSig {
    const decl = func.decl.?.cast(.funcDecl);
    // The generator outlives the call that created it: its frame is snapshotted to the heap and resumed
    // later. A borrow parameter would keep a stack address past the caller's frame (use-after-return),
    // and the snapshot does not go through `semaLift` where `^borrow` is rejected.
    var rt_param_idx: usize = 0;
    for (decl.params.slice()) |param| {
        if (param.template_param) continue;
        const param_t = sig.params()[rt_param_idx].get_type();
        rt_param_idx += 1;
        if (param_t.info.borrow_only) {
            const name = try c.sema.allocTypeName(param_t);
            defer c.alloc.free(name);
            return c.reportErrorFmt("A `generator fn` can not take the borrow type `{}` as a parameter. The generator outlives the call, so pass an owned value or a `^T` pointer instead.", &.{v(name)}, @ptrCast(param));
        }
    }
    func.info.generator = true;
    // Modify func signature return type.
    const decl_sig = try c.sema.ensureFuncSig(sig.params(), sig.ret);
    const funcptr_t = try sema.getFuncPtrType(c, decl_sig);
    const gen_t = try sema.getGeneratorType(c, funcptr_t);
    const ret_t = try sema.getRefType(c, gen_t);
    return c.sema.ensureFuncSig(sig.params(), ret_t);
}

pub fn resolveUserFuncVariant(c: *cy.Chunk, func: *cy.Func, resolve_new_types: bool, node: ?*ast.Node) !void {
    try pushFuncResolveContext(c, func, node);
    defer popResolveContext(c);

    var generic: GenericFuncResult = undefined;
    var sig = try resolveFuncSig(c, func, resolve_new_types, &generic, true);
    std.debug.assert(!generic.generic);

    if (func.decl.?.cast(.funcDecl).generator) {
        sig = try resolveGeneratorSig(c, func, sig);
    }

    if (!func.info.const_eval_only) {
        for (sig.params()) |param| {
            if (param.get_type().info.ct) {
                return c.reportError("Expected `#fn` declaration when signature contains a type declared with `#type`.", func.decl);
            }
        }
    }

    c.resolveFuncInfo(func, sig);
}

pub fn reserveImplicitTraitMethod(c: *cy.Chunk, parent: *cy.Sym, decl: *ast.FuncDecl, vtable_idx: usize) !*cy.Func {
    // A method with a body is a default method. Each implementing type that does not define the method gets
    // its own copy (`sema_type.reserveDefaultMethods`).
    if (decl.stmts.len > 0 and decl.generator) {
        return c.reportErrorFmt("A default method of a trait can not be a generator.", &.{}, @ptrCast(decl));
    }
    const func = try c.reserveTraitFunc(parent, decl.name.declName(), decl, vtable_idx);
    return func;
}

pub fn reserveConst(c: *cy.Chunk, parent: *cy.Sym, name: []const u8, decl: *ast.ConstDecl) !*cy.Sym {
    if (decl.right == null) {
        // // No initializer.
        // if (ast.findAttr(decl.attrs, .host) != null) {
        //     return @ptrCast(try c.reserveHostVar(decl_path.parent, decl_path.name.base_name, decl));
        // }
        return c.reportErrorFmt("`{}` does not have an initializer.", &.{v(name)}, @ptrCast(decl));
    } else {
        return @ptrCast(try c.reserveConst(parent, name, decl));
    }
}

pub fn reserveGlobal(c: *cy.Chunk, decl: *ast.GlobalDecl) !?*Sym {
    const decl_path = try ensureDeclNamePath(c, @ptrCast(c.sym), decl.parent, decl.name);
    if (decl.right == null) {
        // No initializer.
        var has_bind = false;
        var has_extern = false;
        for (decl.attrs.slice()) |attr| {
            if (attr.type == .bind) {
                has_bind = true;
            } else if (attr.type == .extern_) {
                has_extern = true;
            } else if (attr.type == .cond) {
                const res = try cte.evalCheck(c, attr.value.?, c.sema.bool_t);
                if (!res.value.asBool()) {
                    return null;
                }
            }
        }
        if (has_bind) {
            return @ptrCast(try c.reserveHostVar(decl_path.parent, decl_path.name.name, decl));
        }
        if (has_extern) {
            return @ptrCast(try c.reserveExternVar(decl_path.parent, decl_path.name.name, decl));
        }
        return c.reportErrorFmt("`{}` does not have an initializer.", &.{v(decl_path.name.name)}, @ptrCast(decl));
    } else {
        return @ptrCast(try c.reserveUserVar(decl_path.parent, decl_path.name.name, decl));
    }
}

pub fn resolveConst(c: *cy.Chunk, sym: *cy.sym.Const) !void {
    if (sym.isResolved()) {
        return;
    }
    if (declFailed(c, sym)) return error.CompileError;
    errdefer markDeclFailed(c, sym);
    try pushSymResolveContext(c, @ptrCast(sym), null);
    defer popResolveContext(c);

    const node = sym.decl.?;

    sym.resolving_init = true;
    var type_: *cy.Type = undefined;
    var res: cy.TypeValue = undefined;
    if (node.type) |type_n| {
        type_ = try cte.eval_type2(c, true, type_n);
        // Only allow types that can be expanded at compile-time. `ct_expand.value`
        if (!type_.isConstEligible()) {
            const name = try c.sema.allocTypeName(type_);
            defer c.alloc.free(name);
            if (type_.id() == bt.Str) {
                return c.reportErrorFmt("Expected const eligible type, found `{}`. Consider using `EvalStr` which can coerce to a runtime `str`.", &.{v(name)}, type_n);
            }
            if (type_.kind() == .vector) {
                return c.reportErrorFmt("TODO: const `{}`. Alternatively, use the `global` declaration.", &.{v(name)}, if (node.type != null) @ptrCast(node.type.?) else node.right.?);
            }
            return c.reportErrorFmt("Expected const eligible type, found `{}`.", &.{v(name)}, if (node.type != null) @ptrCast(node.type.?) else node.right.?);
        }
        res = try cte.evalCheck(c, node.right.?, type_);
    } else {
        res = try cte.eval(c, node.right.?);
        type_ = res.type;
    }
    errdefer c.heap.destructValue(res);

    sym.type = type_;
    sym.value = res.value;

    // Compile-time exclusive types do not have cached IR.
    if (type_.id() == bt.EvalStr) {
        sym.ir = null;
    } else {
        sym.ir = (try ct_inline.value(c, res, null, node.right.?)).ir;
    }
    sym.resolved = true;
    sym.resolving_init = false;
}

/// Resolves the variable's type and initializer.
/// If type spec is not provided, the initializer is resolved to obtain the type.
pub fn resolveUserVar(c: *cy.Chunk, sym: *cy.sym.UserVar) !void {
    if (sym.isResolved()) {
        return;
    }
    if (declFailed(c, sym)) return error.CompileError;
    errdefer markDeclFailed(c, sym);

    try pushSymResolveContext(c, @ptrCast(sym), null);
    defer popResolveContext(c);

    const decl_n = sym.decl.?;
    const var_t = try cte.eval_type2(c, true, decl_n.typeSpec);
    if (var_t.info.borrow_only) {
        // A global outlives every local that a borrow in it could point to.
        const type_name = try c.sema.allocTypeName(var_t);
        defer c.alloc.free(type_name);
        return c.reportErrorFmt("A global cannot hold the borrow type `{}`. Use an owned type such as `^T`.", &.{v(type_name)}, decl_n.typeSpec);
    }

    c.resolveUserVarType(sym, var_t);
    sym.resolving_init = false;
}

pub fn semaUserVarInit(c: *cy.Chunk, sym: *cy.sym.UserVar, ref_node: ?*ast.Node) !void {
    if (sym.emitted) {
        return;
    }

    if (sym.resolving_init) {
        return;
    }

    const node = sym.decl.?;

    // Ensure resolved type.
    const src_chunk = c.compiler.getSymChunk(&sym.head);

    _ = ref_node;
    try resolveUserVar(src_chunk, sym);
    
    try pushSymResolveContext(c, @ptrCast(sym), null);
    defer popResolveContext(c);

    c.cur_sema_proc.global_init = true;
    defer c.cur_sema_proc.global_init = false;
    c.cur_sema_proc.global_init_var = sym;
    defer c.cur_sema_proc.global_init_var = null;

    // Wrap in block to keep the same local state when loading each static variable.
    _ = try sema_local.pushBlock(c, @ptrCast(node));
    const res = try c.semaExprCstr(node.right.?, sym.type);

    try sema_expr.semaTraceNopFmt(c, "init {s}", .{sym.head.name()}, @ptrCast(node));
    _ = try c.ir.pushStmt(.set_global, @ptrCast(node), .{
        .sym = @ptrCast(sym),
        .expr = res.ir,
    });

    const block = try sema_local.popBlock(c);
    _ = try c.ir.pushStmt(.block, @ptrCast(node), .{ .bodyHead = block.first });
    sym.resolving_init = false;
    sym.emitted = true;
}

pub fn resolveExternVar(c: *cy.Chunk, sym: *cy.sym.ExternVar) !void {
    if (sym.resolved) {
        return;
    }
    try pushSymResolveContext(c, @ptrCast(sym), @ptrCast(sym.decl));
    defer popResolveContext(c);

    const decl = sym.decl.?;
    sym.type = try cte.eval_type2(c, true, decl.typeSpec);
    var extern_name = sym.head.name();
    const attr = cy.ast.findAttr(sym.decl.?.attrs.slice(), .extern_).?;
    if (try attr.getString()) |str| {
        extern_name = str;
    }
    sym.extern_name_ptr = extern_name.ptr;
    sym.extern_name_len = extern_name.len;
    sym.resolved = true;
}

pub fn writeBindName(w: anytype, sym: *cy.Sym) !void {
    if (sym.instance() != null) {
        const parent = sym.parent.?.parent.?;
        if (parent.type != .chunk) {
            try w.writeAll(parent.name());
        }
    } else {
        const parent = sym.parent.?;
        if (parent.type != .chunk) {
            try w.writeAll(parent.name());
        }
    }
    try w.writeAll(sym.name());
}

pub fn resolveHostVar(c: *cy.Chunk, sym: *cy.sym.HostVar) !void {
    if (sym.isResolved()) {
        return;
    }
    try pushSymResolveContext(c, @ptrCast(sym), @ptrCast(sym.decl));
    defer popResolveContext(c);

    const decl = sym.decl.?;

    c.tempBufU8.clearRetainingCapacity();
    const w = stdx.listWriter(&c.tempBufU8, c.alloc);
    try writeBindName(w, &sym.head);
    const bind_name = c.tempBufU8.items;

    const var_t = try cte.eval_type2(c, true, decl.typeSpec);

    // Value is consumed from loader.
    log.tracev("Invoke var loader for: {s}", .{bind_name});
    const binding = c.host_globals.get(bind_name) orelse {
        return c.reportErrorFmt("Host var `{}` failed to load.", &.{v(bind_name)}, @ptrCast(decl));
    };
    try c.resolveHostVar(sym, var_t, binding.ptr.?);
}

const NameResultType = enum {
    sym,
    ct_value,
    ct_var,
};

pub const NameResult = struct {
    type: NameResultType,
    data: union {
        sym: *Sym,
        ct_value: cy.TypeValue,
        ct_var: *CtParam,
    },

    pub fn initSym(sym: *Sym) NameResult {
        return .{ .type = .sym, .data = .{ .sym = sym, }};
    }

    pub fn initCtValue(ct_value: cy.TypeValue) NameResult {
        return .{ .type = .ct_value, .data = .{ .ct_value = ct_value, }};
    }

    pub fn initCtValue2(val_t: *cy.Type, val: cy.Value) NameResult {
        return .{ .type = .ct_value, .data = .{ .ct_value = cy.TypeValue.init(val_t, val), }};
    }

    pub fn initCtVar(ptr: *CtParam) NameResult {
        return .{ .type = .ct_var, .data = .{ .ct_var = ptr }};
    }
};

pub fn apiResolveName(c: *cy.Chunk, name: []const u8) ?NameResult {
    // Check top level chunks.
    const chunk = (c.get_chunk_by_uri(name) catch @panic("error")) orelse return null;
    return NameResult.initSym(@ptrCast(chunk.sym));
}

pub fn getResolvedName(c: *cy.Chunk, name: []const u8, node: *ast.Node) !?NameResult {
    const resolve_ctx_idx = c.resolve_stack.items.len-1;
    const ctx = c.resolve_stack.items[resolve_ctx_idx];
    const search_c = ctx.chunk;

    // Look in ct context.
    if (ctx.ct_params.size > 0) {
        if (ctx.ct_params.getPtr(name)) |param| {
            const param_t = param.getType();
            if (param_t.id() == bt.Type and param.value.asPtr(*cy.Type).id() == bt.Any) {
                return error.FoundDependentType;
            }

            if (param.isVar()) {
                return NameResult.initCtVar(param);
            } else {
                const new = try c.heap.copyValue2(param_t, param.value);
                return NameResult.initCtValue2(param_t, new);
            }
        }
    }

    if (ctx.type == .func) {
        if (ctx.data.func.instance) |variant| {
            if (variant.getParam(name)) |param| {
                const new_value = try c.heap.copyValue2(param.type, param.value);
                return NameResult.initCtValue2(param.type, new_value);
            }
        }

        // The body of a default method belongs to its trait. It sees the template parameters of the trait.
        if (ctx.data.func.default_trait) |trait_t| {
            if (trait_t.base.sym().instance) |variant| {
                if (variant.getParam(name)) |param| {
                    const new_value = try c.heap.copyValue2(param.type, param.value);
                    return NameResult.initCtValue2(param.type, new_value);
                }
            }
        }

        // Start at immediate parent since it could be a sym.CtValue.
        var opt_parent: ?*cy.Sym = ctx.data.func.parent;
        while (opt_parent) |parent| {
            if (parent.instance()) |variant| {
                if (variant.getParam(name)) |param| {
                    const new_value = try c.heap.copyValue2(param.type, param.value);
                    return NameResult.initCtValue2(param.type, new_value);
                }
            }
            opt_parent = parent.parent;
        }
    } else if (ctx.type == .sym) {
        if (ctx.data.sym.instance()) |variant| {
            if (variant.getParam(name)) |param| {
                const new_value = try c.heap.copyValue2(param.type, param.value);
                return NameResult.initCtValue2(param.type, new_value);
            }
        }
    }

    if (std.mem.eql(u8, "Self", name)) {
        if (ctx.getSelfSym()) |sym| {
            return NameResult.initSym(sym);
        }
    }

    // Look in the current chunk module.
    if (try c.getResolvedSym(@ptrCast(search_c.sym), name, node)) |sym| {
        return NameResult.initSym(sym);
    }

    // Look in fallback modules.
    var i = search_c.fallback_modules.items.len;
    while (i > 0) {
        i -= 1;
        const mod_sym = search_c.fallback_modules.items[i];
        if (try cy.module.get_pub_resolved_chunk_sym(c, mod_sym.cast(.chunk), name, node)) |sym| {
            return NameResult.initSym(sym);
        }
    }

    // Finally invoke optional fallback logic.
    // This is useful for implementing libcyber's `clFindType`.
    if (search_c.resolve_name_fn) |resolve_name_fn| {
        return resolve_name_fn(c, name);
    }

    return null;
}

pub fn semaChunkTopCtStmts(c: *cy.Chunk, node: ?*ast.Node) !void {
    if (!c.has_pending_ct_stmts) {
        return;
    }
    if (c.resolving_ct_stmts) {
        return;
    }
    c.resolving_ct_stmts = true;

    try pushChunkResolveContext(c, node);
    defer popResolveContext(c);
    getResolveContext(c).allow_rt_stmts = false;
    try cy.ct_inline.evalTopStmts(c, c.ast.root.?.stmts.slice());
    c.resolving_ct_stmts = false;
    c.has_pending_ct_stmts = false;
}

pub fn ensureResolvedFuncTemplate(c: *cy.Chunk, template: *cy.sym.FuncTemplate) !void {
    if (template.isResolved()) {
        return;
    }
    try resolveFuncTemplate(c, template);
}

pub fn ensureResolvedTemplate(c: *cy.Chunk, template: *cy.sym.Template) !void {
    if (template.isResolved()) {
        return;
    }
    try resolveTemplate(c, template);
}

pub fn getResolveContext(c: *cy.Chunk) *ResolveContext {
    return &c.resolve_stack.items[c.resolve_stack.items.len-1];
}

pub fn indexOfTypedParam(params: []const *ast.FuncParam, start: usize) ?usize {
    for (params[start..], start..) |param, i| {
        if (param.type != null) {
            return i;
        }
    }
    return null;
}

const GenericFuncResult = struct {
    generic: bool,
    params: []cy.sym.FuncTemplateParam,
};

fn ensure_opaque_func_sig(c: *cy.Chunk, nparams: usize) !*sema.FuncSig {
    const start = c.func_param_stack.items.len;
    defer c.func_param_stack.items.len = start;
    for (0..nparams) |_| {
        try c.func_param_stack.append(c.alloc, sema.FuncParam.init(c.sema.any_t));
    }
    return c.sema.ensureFuncSig2(c.func_param_stack.items[start..], c.sema.any_t, false, null);
}

/// During body sema, all new types should be resolved.
fn resolveFuncSig(c: *cy.Chunk, func: *cy.Func, resolve_new_types: bool, out_generic: *GenericFuncResult, comptime variant: bool) !*sema.FuncSig {
    const func_n = func.decl.?.cast(.funcDecl);

    // Get params, build func signature.
    const start = c.func_param_stack.items.len;
    defer c.func_param_stack.items.len = start;

    const template_start = c.func_template_param_stack.items.len;
    defer c.func_template_param_stack.items.len = template_start;
    // An anonymous param owns its name until `out_generic.params` takes the entries over on success.
    errdefer for (c.func_template_param_stack.items[template_start..]) |param| {
        param.deinit(c.alloc);
    };

    const sig_t = func_n.sig_t;
    if (sig_t == .infer) {
        return error.Unexpected;
    }

    var start_idx: usize = 0;

    var scope_param_idx: ?u8 = null;
    const params: []const *ast.FuncParam = func_n.params.slice();
    if (sig_t == .method) {
        // First parameter type of methods has the receiver type.
        const type_n = func_n.params.ptr[0].type.?;

        const rec_t = try cte.eval_type2(c, resolve_new_types, type_n);
        try c.func_param_stack.append(c.alloc, sema.FuncParam.init2(rec_t, func_n.params.ptr[0].sink_param));

        if (func_n.params.ptr[0].scope_param) {
            scope_param_idx = 0;
        }
        start_idx += 1;
    }
    // Separate check for trait methods.
    if (func.type == .trait) {
        // Add `self Self` generic param.
        const self_type = getResolveContext(c).getSelfSym().?.cast(.type).type;
        try c.func_param_stack.append(c.alloc, sema.FuncParam.init(self_type));
    }

    var param_group_t: ?*cy.Type = null;
    var param_group_end: usize = undefined;
    var has_ct_only_param = false;

    for (start_idx..params.len) |i| {
        const param = params[i];
        const paramName = param.name_type.as_name();
        if (std.mem.eql(u8, paramName, "self")) {
            return c.reportError("`self` is a reserved parameter for methods.", @ptrCast(param));
        }
        var type_: *cy.Type = undefined;
        if (param.type == null) {
            if (param_group_t == null or i > param_group_end) {
                // Attempt to find group type.
                param_group_end = indexOfTypedParam(params, i + 1) orelse {
                    return c.reportError("Expected parameter type.", @ptrCast(param));
                };
                param_group_t = try sema_type.resolveAnyParamType(c, i, resolve_new_types, params[param_group_end].type.?, variant);
            }
            type_ = param_group_t.?;
        } else {
            type_ = try sema_type.resolveAnyParamType(c, i, resolve_new_types, param.type.?, variant);
        }

        if (!has_ct_only_param and type_.info.ct and !param.template_param) {
            has_ct_only_param = true;
        }

        if (param.template_param) {
            if (!variant) {
                const ctx = getResolveContext(c);
                const value = TypeValue.init(c.sema.type_t, Value.initPtr(c.sema.any_t));
                try ctx.initCtParam(c.alloc, paramName, value);

                try c.func_template_param_stack.append(c.alloc, .{
                    .anonymous = false,
                    .name = paramName,
                    .type_idx = undefined,
                });
            } else {
                continue;
            }
        } else if (param.scope_param) {
            if (scope_param_idx != null) {
                return c.reportError("Expected only one parameter with the `scope` modifier.", param.name_type);
            }
            scope_param_idx = @intCast(c.func_param_stack.items.len - start);
        }
        try c.func_param_stack.append(c.alloc, sema.FuncParam.init2(type_, param.sink_param));
    }

    // Get return type.
    const ret_t = try sema_type.resolve_return_type_spec(c, func_n.ret, resolve_new_types);
    if (func.type != .trait and ret_t.info.borrow_only) {
        if (!func_n.scope_ret and ast.findAttr(func_n.attrs.slice(), .unsafe) == null) {
            if (ret_t.kind() == .borrow) {
                return c.reportError("Returning a borrow requires a `scope` modifier.", func_n.ret);
            } else {
                return c.reportError("Returning a borrow container requires a `scope` modifier.", func_n.ret);
            }
        }
        if (scope_param_idx == null and ast.findAttr(func_n.attrs.slice(), .unsafe) == null) {
            return c.reportError("Missing `scope` parameter.", func_n.ret);
        }
    }

    if (has_ct_only_param) {
        func.info.const_eval_only = true;
    }

    // Always write `generic`. Callers assert on it, and an undefined bool there lets optimized builds drop code.
    out_generic.generic = false;
    errdefer if (out_generic.generic) {
        c.alloc.free(out_generic.params);
        out_generic.generic = false;
    };
    if (!variant) {
        const generic_params = c.func_template_param_stack.items[template_start..];
        if (generic_params.len > 0) {
            const params_dupe = try c.alloc.dupe(cy.sym.FuncTemplateParam, generic_params);
            out_generic.* = .{
                .generic = true,
                .params = params_dupe,
            };
        }
    }
    const nparams = c.func_param_stack.items.len - start;
    try sema_local.checkParamLimit(c, nparams, if (params.len > sema_local.max_func_params) @ptrCast(params[sema_local.max_func_params]) else @ptrCast(func_n));
    return c.sema.ensureFuncSig2(c.func_param_stack.items[start..], ret_t, func.info.extern_, scope_param_idx);
}

pub fn pushLambdaFuncParams(c: *cy.Chunk, params: []const *ast.FuncParam) !void {
    var param_group_t: ?*cy.Type = null;
    var param_group_end: usize = undefined;
    for (params, 0..) |param, i| {
        const paramName = param.name_type.as_name();
        if (std.mem.eql(u8, paramName, "self")) {
            return c.reportError("`self` is a reserved parameter for methods.", @ptrCast(param));
        }
        var type_: *cy.Type = undefined;
        if (param.type == null) {
            if (param_group_t == null or i > param_group_end) {
                // Attempt to find group type.
                param_group_end = indexOfTypedParam(params, i + 1) orelse {
                    return c.reportError("Expected parameter type.", @ptrCast(param));
                };
                param_group_t = try cte.eval_type2(c, false, params[param_group_end].type.?);
            }
            type_ = param_group_t.?;
        } else {
            type_ = try cte.eval_type2(c, false, param.type.?);
        }
        try c.func_param_stack.append(c.alloc, .init(type_));
    }
    if (params.len > sema_local.max_func_params) {
        try sema_local.checkParamLimit(c, params.len, @ptrCast(params[sema_local.max_func_params]));
    }
}

pub fn inferLambdaFuncSig(c: *cy.Chunk, sig_t: ast.FuncSigType, opt_target_t: ?*cy.Type, node: *ast.Node) !?*sema.FuncSig {
    if (sig_t != .infer) {
        return null;
    }
    var target_t = opt_target_t orelse {
        return c.reportError("Can not infer function type. Consider using an explicit `fn` declaration.", node);
    };
    if (target_t.kind() == .func_ptr) {
        return target_t.cast(.func_ptr).sig;
    } else if (target_t.kind() == .func) {
        return target_t.cast(.func).sig;
    } else if (target_t == c.sema.object_t) {
        return null;
    } else if (target_t.kind() == .borrow) {
        const borrow_t = target_t.cast(.borrow);
        if (borrow_t.child_t.kind() == .func) {
            return borrow_t.child_t.cast(.func).sig;
        }
    }
    return c.reportError("Can not infer function type.", node);
}

pub const DeclNamePathResult = struct {
    name: cy.ast.NamePathBase,
    parent: *cy.Sym,

    /// Whether the symbol is declared as a template variant rather than in the template's namespace.
    variant: bool,
};

pub fn ensureDeclNamePath(c: *cy.Chunk, mod: *cy.Sym, parent_opt: ?*ast.Node, name_n: *ast.Node) !DeclNamePathResult {
    const name = name_n.getNamePathBase();
    var parent = parent_opt orelse {
        return .{
            .name = name,
            .parent = mod,
            .variant = false,
        };
    };

    if (parent.type() == .borrow) {
        parent = parent.cast(.borrow).child;
    } else if (parent.type() == .ex_borrow) {
        parent = parent.cast(.ex_borrow).child;
    } else if (parent.type() == .ref) {
        parent = parent.cast(.ref).child;
    }

    var parent_name: []const u8 = undefined;
    var variant = false;
    if (parent.type() == .ident) {
        parent_name = parent.as_name();
    } else if (parent.type() == .generic_expand) {
        variant = true;
        parent_name = parent.cast(.generic_expand).left.as_name();
    } else {
        return c.reportErrorFmt("TODO", &.{}, parent);
    }
    const sym = mod.getMod().?.getSym(parent_name) orelse {
        return c.reportErrorFmt("Undeclared symbol: `{}`", &.{v(parent_name)}, parent);
    };
    if (sym.type == .type_alias) {
        return c.reportError("Cannot declare from type alias.", name_n);
    }
    return .{
        .name = name,
        .parent = sym,
        .variant = variant,
    };
}
