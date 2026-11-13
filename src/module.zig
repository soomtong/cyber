const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const stdx = @import("stdx");
const t = stdx.testing;
const cy = @import("cyber.zig");
const C = @import("capi.zig");
const sema = cy.sema;
const sema_type = cy.sema_type;
const types = cy.types;
const bt = types.BuiltinTypes;
const ir = cy.ir;
const fmt = cy.fmt;
const v = fmt.v;
const vmc = cy.vmc;
const log = cy.log.scoped(.module);
const ast = cy.ast;

pub const ModFuncKey = cy.hash.KeyU128;

/// A module contains symbols declared in Cyber source code and through the embedded API.
/// Overloaded functions are linked together so that type signatures can be checked sequentially.
pub const Module = struct {
    /// Name to sym.
    symMap: std.StringHashMapUnmanaged(*cy.Sym),

    /// Sym+funcSig to func sym. This is used to check whether an overloaded function is unique.
    /// This should only be populated for a function sym once it's overloaded.
    overloadedFuncMap: std.HashMapUnmanaged(ModFuncKey, *cy.Func, cy.hash.KeyU128Context, 80),

    /// Sym+params-only funcSig to func sym. Overloads must differ in their parameters, not only in the return type (F-21).
    overloadedParamsMap: std.HashMapUnmanaged(ModFuncKey, *cy.Func, cy.hash.KeyU128Context, 80),

    pub fn init() Module {
        return .{
            .symMap = .empty,
            .overloadedFuncMap = .empty,
            .overloadedParamsMap = .empty,
        };
    }

    pub fn deinit(self: *Module, alloc: std.mem.Allocator) void {
        self.symMap.deinit(alloc);
        self.overloadedFuncMap.deinit(alloc);
        self.overloadedParamsMap.deinit(alloc);
    }

    pub fn getFirstFunc(m: *const Module, name: []const u8) ?*cy.Func {
        const sym = m.symMap.get(name) orelse return null;
        return sym.cast(.func).first;
    }

    pub fn getSym(m: *Module, name: []const u8) ?*cy.Sym {
        return m.symMap.get(name);
    }

    fn isFuncUnique(m: *Module, func: *cy.sym.FuncSym, sig: *cy.FuncSig) bool {
        if (func.firstFuncSig == sig) {
            return false;
        }
        if (func.numFuncs == 1) {
            return true;
        }
        
        const key = ModFuncKey.initModFuncKey(func, sig);
        return !m.overloadedFuncMap.contains(key);
    }

    pub fn addSym(m: *Module, alloc: std.mem.Allocator, name: []const u8, sym: *cy.Sym) !void {
        try m.symMap.putNoClobber(alloc, name, sym);
    }

    pub fn updateParentRefs(m: *Module, parent: *cy.Sym) void {
        var iter = m.symMap.valueIterator();
        while (iter.next()) |val_ptr| {
            val_ptr.*.parent = parent;
        }
    }
};

pub fn reportDupSym(c: *cy.Chunk, sym: *cy.Sym, name: []const u8, decl: ?*ast.Node) !void {
    const id = try c.addReportFmt("`{}` has already been declared as a `{}`", &.{v(name), v(sym.type)}, decl);
    var last = &c.compiler.reports.items[id];
    // A field or a case does not keep its declaration. The report then has no "First declared at".
    if (sym.declNodeOrNull()) |first_decl| {
        last = try c.appendContextTrace(last, "First declared at:", first_decl);
    }
    try c.appendErrorTrace(last);
    return error.CompileError;
}

/// A `persist_main` eval carries the previous main's symbols over as use aliases without a declaration.
/// A new declaration of the same name replaces them, like redefining in a REPL.
fn isCarriedOverSym(sym: *cy.Sym) bool {
    return sym.type == .use_alias and sym.cast(.use_alias).decl == null;
}

pub fn addUniqueSym(c: *cy.Chunk, mod: *Module, name: []const u8, sym: *cy.Sym, decl: ?*ast.Node) !void {
    const res = try mod.symMap.getOrPut(c.alloc, name);
    if (res.found_existing) {
        const existing = res.value_ptr.*;
        if (!isCarriedOverSym(existing)) {
            try reportDupSym(c, existing, name, decl);
        }
    }
    res.value_ptr.* = sym;
}

fn prepareFuncSym(c: *cy.Chunk, parent: *cy.Sym, mod: *Module, name: []const u8, decl: ?*ast.FuncDecl) !*cy.sym.FuncSym {
    const hidden = if (decl) |d| d.hidden else false;
    if (mod.symMap.get(name)) |sym| {
        if (isCarriedOverSym(sym)) {
            _ = mod.symMap.remove(name);
        } else if (sym.type == .func) {
            // Overloads share one func sym, so they share one visibility (F-30).
            if (sym.getMetadata().private != hidden) {
                return c.reportErrorFmt("Overloads of `{}` must have the same visibility.", &.{v(name)}, @ptrCast(decl));
            }
            return sym.cast(.func);
        } else {
            try reportDupSym(c, sym, name, @ptrCast(decl));
        }
    }
    // Create func sym.
    const sym = try c.createFuncSym(parent, name);
    sym.head.getMetadata().private = hidden;
    try mod.addSym(c.alloc, name, @ptrCast(sym));
    return sym;
}

pub fn reserveUseAlias(c: *cy.Chunk, parent: *cy.Sym, name: []const u8, decl: ?*ast.Node) !*cy.sym.UseAlias {
    const sym = try c.createUseAlias(parent, name, decl);
    const mod = parent.getMod().?;
    _ = try addUniqueSym(c, mod, name, @ptrCast(sym), @ptrCast(decl));
    return sym;
} 

pub fn reserve_type_const(c: *cy.Chunk, parent: *cy.Sym, name: []const u8, decl: *ast.TypeConstDecl) !*cy.sym.TypeConst {
    const sym = try c.createTypeConst(parent, name, decl.hidden, decl);
    const mod = parent.getMod().?;
    _ = try addUniqueSym(c, mod, name, @ptrCast(sym), @ptrCast(decl));
    return sym;
} 

pub fn reserveTypeAlias(c: *cy.Chunk, parent: *cy.Sym, name: []const u8, decl: *ast.TypeAliasDecl) !*cy.sym.TypeAlias {
    const sym = try c.createTypeAlias(parent, name, decl.hidden, decl);
    const mod = parent.getMod().?;
    _ = try addUniqueSym(c, mod, name, @ptrCast(sym), @ptrCast(decl));
    return sym;
} 

pub fn reserveFuncTemplateSym(c: *cy.Chunk, parent: *cy.Sym, name: []const u8, callable: bool, decl: *ast.TemplateDecl) !*cy.sym.FuncTemplate {
    const sym = try c.createFuncTemplate(parent, name, callable, decl);
    sym.head.getMetadata().private = ast.isHiddenDecl(decl.child_decl);
    const mod = parent.getMod().?;
    try addUniqueSym(c, mod, name, @ptrCast(sym), @ptrCast(decl));
    return sym;
}

pub fn reserveTemplate(c: *cy.Chunk, parent: *cy.Sym, name: []const u8,
    kind: cy.sym.TemplateType, decl: *ast.TemplateDecl) !*cy.sym.Template {

    const sym = try c.createTemplate(parent, name, kind, decl);
    sym.head.getMetadata().private = ast.isHiddenDecl(decl.child_decl);
    const mod = parent.getMod().?;
    try addUniqueSym(c, mod, name, @ptrCast(sym), @ptrCast(decl));
    return sym;
}

pub fn declareEnumCase(c: *cy.Chunk, parent: *cy.Sym, name: []const u8, type_: *cy.Type,
    val: u32, decl: *ast.EnumMember) !*cy.sym.EnumCase {
    const sym = try c.createEnumCase(parent, name, type_, val);
    const mod = parent.getMod().?;
    try addUniqueSym(c, mod, name, @ptrCast(sym), @ptrCast(decl));
    return sym;
}

pub fn declareChoiceCase(c: *cy.Chunk, parent: *cy.Sym, name: []const u8, type_: *cy.Type,
    val: u32, idx: u32, payload_t: *cy.Type, decl: *ast.Node) !*cy.sym.ChoiceCase {
    const sym = try c.createChoiceCase(parent, name, type_, val, idx, payload_t);
    const mod = parent.getMod().?;
    try addUniqueSym(c, mod, name, @ptrCast(sym), @ptrCast(decl));
    return sym;
}

pub fn declareUnionCase(c: *cy.Chunk, parent: *cy.Sym, name: []const u8, type_: *cy.Type,
    idx: u32, payload_t: *cy.Type, decl: *ast.Node) !*cy.sym.UnionCase {
    const sym = try c.createUnionCase(parent, name, type_, idx, payload_t);
    const mod = parent.getMod().?;
    try addUniqueSym(c, mod, name, @ptrCast(sym), @ptrCast(decl));
    return sym;
}

pub fn reserveExternVar(c: *cy.Chunk, parent: *cy.Sym, name: []const u8, decl: ?*ast.GlobalDecl) !*cy.sym.ExternVar {
    const sym = try c.createExternVar(parent, name, decl);
    sym.head.getMetadata().private = if (decl) |d| d.hidden else false;
    const mod = parent.getMod().?;
    try addUniqueSym(c, mod, name, @ptrCast(sym), @ptrCast(decl));
    return sym;
}

pub fn reserveHostVar(c: *cy.Chunk, parent: *cy.Sym, name: []const u8, decl: ?*ast.GlobalDecl) !*cy.sym.HostVar {
    const sym = try c.createHostVar(parent, name, decl);
    sym.head.getMetadata().private = if (decl) |d| d.hidden else false;
    const mod = parent.getMod().?;
    try addUniqueSym(c, mod, name, @ptrCast(sym), @ptrCast(decl));
    return sym;
}

pub fn resolveHostVar(c: *cy.Chunk, sym: *cy.sym.HostVar, var_t: *cy.Type, val: *anyopaque) !void {
    _ = c;
    sym.type = var_t;
    sym.val = val;
} 

pub fn reserveConst(c: *cy.Chunk, parent: *cy.Sym, name: []const u8, decl: ?*ast.ConstDecl) !*cy.sym.Const {
    const sym = try c.createConst(parent, name, decl);
    sym.head.getMetadata().private = if (decl) |d| d.hidden else false;
    const mod = parent.getMod().?;
    _ = try addUniqueSym(c, mod, name, @ptrCast(sym), @ptrCast(decl));
    return sym;
}

pub fn reserveUserVar(c: *cy.Chunk, parent: *cy.Sym, name: []const u8, decl: ?*ast.GlobalDecl) !*cy.sym.UserVar {
    const sym = try c.createUserVar(parent, name, decl);
    sym.head.getMetadata().private = if (decl) |d| d.hidden else false;
    const mod = parent.getMod().?;
    _ = try addUniqueSym(c, mod, name, @ptrCast(sym), @ptrCast(decl));
    return sym;
}

pub fn resolveUserVarType(c: *cy.Chunk, sym: *cy.sym.UserVar, type_: *cy.Type) void {
    _ = c;
    sym.type = type_;
}

pub fn declareField(c: *cy.Chunk, parent: *cy.Sym, name: []const u8, idx: usize, type_: *cy.Type, decl: ?*ast.Node) !*cy.sym.Field {
    const sym = try c.createField(parent, name, idx, type_);
    if (decl) |d| {
        if (d.type() == .struct_field) {
            sym.head.getMetadata().private = d.cast(.struct_field).hidden;
        }
    }
    const mod = parent.getMod().?;
    _ = try addUniqueSym(c, mod, name, @ptrCast(sym), decl);
    return sym;
}

pub fn reserveTypeSym(c: *cy.Chunk, parent: *cy.Sym, name: []const u8, type_: *cy.Type, decl: ?*ast.Node) !*cy.sym.TypeSym {
    const sym = try c.createTypeSym(parent, name, type_, decl);
    sym.head.getMetadata().private = if (decl) |d| ast.isHiddenDecl(d) else false;
    const mod = parent.getMod().?;
    _ = try addUniqueSym(c, mod, name, @ptrCast(sym), @ptrCast(decl));
    return sym;
}

pub fn addUserLambda(c: *cy.Chunk, parent: *cy.Sym, decl: *ast.Node) !*cy.Func {
    const config = cy.sym.FuncConfig{
        .is_method = false,
        .extern_ = false,
    };
    const func = try c.createFunc(.userLambda, parent, config, decl);
    try c.appendFunc(func);
    return func;
}

pub fn resolveUserLambda(c: *cy.Chunk, func: *cy.Func, sig: *cy.FuncSig) !void {
    _ = c;
    func.sig = sig;
    func.info.resolved = true;
}

pub fn reserveVariantMember(
    c: *cy.Chunk, parent: *cy.Sym, name: []const u8, decl: *ast.Node,
) !*cy.sym.VariantMember {
    const sym = try c.createVariantMember(parent, name, @ptrCast(decl));
    sym.head.getMetadata().private = ast.isHiddenDecl(decl);
    const mod = parent.getMod().?;
    _ = try addUniqueSym(c, mod, name, @ptrCast(sym), @ptrCast(decl));
    return sym;
}

pub fn reserveVariantFunc(
    c: *cy.Chunk, parent: *cy.Sym, name: []const u8, decl: *ast.FuncDecl,
) !*cy.sym.VariantFunc {
    // const sym = try c.createVariantMember(parent, name, @ptrCast(decl));
    const mod = parent.getMod().?;
    if (mod.symMap.get(name)) |sym| {
        if (sym.type == .variant_func) {
            const sym_ = sym.cast(.variant_func);
            if (sym.getMetadata().private != decl.hidden) {
                return c.reportErrorFmt("Overloads of `{}` must have the same visibility.", &.{v(name)}, @ptrCast(decl));
            }
            try sym_.rest().append(c.alloc, .{
                .decl = decl,
                .with_cstrs = .{ .ptr = undefined, .len = 0 },
                .resolved = false,
            });
            return sym_;
        } else {
            try reportDupSym(c, sym, name, @ptrCast(decl));
            unreachable;
        }
    } else {
        const sym = try c.createVariantFunc(parent, name, decl);
        sym.head.getMetadata().private = decl.hidden;
        try mod.addSym(c.alloc, name, @ptrCast(sym));
        return sym;
    }
}

pub fn resolveHostFunc(c: *cy.Chunk, func: *cy.Func, sig: *sema.FuncSig, func_ptr: cy.ZHostFn, eval_ptr: ?cy.ZConstEvalFn) !void {
    func.type = .hostFunc;
    try resolveFunc(c, func, sig);
    func.data = .{ .hostFunc = .{
        .ptr = func_ptr,
        .eval = eval_ptr,
    }};
}

pub fn resolveHostBuiltinFunc(c: *cy.Chunk, func: *cy.Func, sig: *sema.FuncSig, func_ptr: cy.ZBuiltinFn, eval_ptr: ?cy.ZBuiltinEvalFn) !void {
    func.type = .host_builtin;
    try resolveFunc(c, func, sig);
    func.data = .{ .host_builtin = .{
        .ptr = func_ptr,
        .eval = eval_ptr,
    }};
}

pub fn resolveHostConstEvalFunc(c: *cy.Chunk, func: *cy.Func, sig: *cy.FuncSig, func_ptr: cy.ZConstEvalFn) !void {
    func.type = .host_const_eval;
    func.info.const_eval_only = true;
    try resolveFunc(c, func, sig);
    func.data = .{ .host_const_eval = .{ .ptr = func_ptr }};
}

pub fn reserveTraitFunc(
    c: *cy.Chunk, parent: *cy.Sym, name: []const u8, node: *ast.FuncDecl, vtable_idx: usize,
) !*cy.Func {
    const mod = parent.getMod().?;
    const sym = try prepareFuncSym(c, parent, mod, name, node);
    const config = cy.sym.FuncConfig{
        .is_method = true,
        .extern_ = false,
    };
    const func = try c.createFunc(.trait, @ptrCast(sym), config, @ptrCast(node));
    func.data = .{
        .trait = .{
            .vtable_idx = @intCast(vtable_idx),
        },
    };
    sym.addFunc(func);
    return func;
}

pub fn reserveFunc(
    c: *cy.Chunk, parent: *cy.Sym, name: []const u8, decl: *ast.FuncDecl,
) !?*cy.Func {
    const mod = parent.getMod().?;

    var extern_ = false;
    for (decl.attrs.slice()) |attr| {
        if (attr.type == .extern_) {
            extern_ = true;
        } else if (attr.type == .cond) {
            // The condition of a template member can name the template parameters of the instance.
            const in_instance = parent.instance() != null;
            if (in_instance) {
                try sema.pushSymResolveContext(c, parent, attr.value.?);
            }
            defer if (in_instance) sema.popResolveContext(c);
            const res = try cy.cte.evalCheck(c, attr.value.?, c.sema.bool_t);
            if (!res.value.asBool()) {
                // Skip.
                return null;
            }
        }
    }

    // After the `#[cond]` check. A skipped declaration must not leave a function symbol without a function.
    const sym = try prepareFuncSym(c, parent, mod, name, decl);

    const config = cy.sym.FuncConfig{
        .is_method = decl.sig_t == .method,
        .extern_ = extern_,
    };
    if (config.is_method) {
        if (parent.type == .template) {
            return c.reportErrorFmt("A method must be bound to a template's instance `{}[]`.", &.{v(parent.name())}, @ptrCast(decl));
        }
    }
    const func = try c.createFunc(.unresolved, @ptrCast(sym), config, @ptrCast(decl));
    func.data = .{ .unresolved = {} };
    try c.funcs.append(c.alloc, func);
    sym.addFunc(func);
    return func;
}

pub fn reserveUserFunc(
    c: *cy.Chunk, parent: *cy.Sym, name: []const u8, config: cy.sym.FuncConfig, node: *ast.FuncDecl,
) !*cy.Func {
    const mod = parent.getMod().?;
    const sym = try prepareFuncSym(c, parent, mod, name, node);
    const func = try c.createFunc(.userFunc, @ptrCast(sym), config, @ptrCast(node));
    func.data = .{.userFunc = .{.loc = undefined}};
    try c.funcs.append(c.alloc, func);
    sym.addFunc(func);
    return func;
}

pub fn appendFunc(c: *cy.Chunk, func: *cy.Func) !void {
    try c.funcs.append(c.alloc, func);
}

pub fn resolveUserFunc(c: *cy.Chunk, func: *cy.Func, sig: *cy.FuncSig) !void {
    if (!func.info.const_eval_only) {
        for (sig.params()) |param| {
            if (param.get_type().info.ct) {
                func.info.const_eval_only = true;
                break;
            }
        }
    }
    try resolveFunc(c, func, sig);
}

pub fn resolveFunc(c: *cy.Chunk, func: *cy.Func, sig: *cy.FuncSig) !void {
    if (func.instance == null) {
        const sym = func.parent.cast(.func);
        const mod = sym.head.parent.?.getMod().?;
        if (!mod.isFuncUnique(sym, sig)) {
            return c.reportErrorFmt("`{}` has already been declared with the same function signature.", &.{v(func.name())}, @ptrCast(func.decl));
        }
        if (sym.first == func) {
            sym.firstFuncSig = sig;
        }
        if (sym.numFuncs > 1) {
            const key = ModFuncKey.initModFuncKey(sym, sig);
            try mod.overloadedFuncMap.putNoClobber(c.alloc, key, func);

            // Overloads that differ only in the return type can not be told apart at a call site.
            const params_sig = try c.sema.ensureFuncSig2(sig.params(), c.sema.void_t, sig.extern_, if (sig.scope_param_idx == cy.NullU8) null else sig.scope_param_idx);
            const params_key = ModFuncKey.initModFuncKey(sym, params_sig);
            const params_res = try mod.overloadedParamsMap.getOrPut(c.alloc, params_key);
            if (params_res.found_existing) {
                return c.reportErrorFmt("`{}` has already been declared with the same parameters. Overloads must differ in their parameter types, not only in the return type.", &.{v(func.name())}, @ptrCast(func.decl));
            }
            params_res.value_ptr.* = func;
        }
    }
    resolveFuncInfo(c, func, sig);
}

pub fn resolveFuncInfo(c: *cy.Chunk, func: *cy.Func, sig: *cy.FuncSig) void {
    _ = c;
    func.sig = sig;
    func.info.resolved = true;
}

pub fn get_pub_resolved_chunk_sym(c: *cy.Chunk, chunk: *cy.sym.Chunk, name: []const u8, node: *ast.Node) anyerror!?*cy.Sym {
    const mod = chunk.getMod();
    const sym = mod.getSym(name) orelse return null;
    if (!is_sym_visible(c, sym, node)) {
        // A `-` symbol of a fallback module (core) is not reachable from a script by its bare name (F-30).
        return null;
    }
    switch (sym.type) {
        .module_alias => {
            {
                // TODO: check visibility.
                return null;
            }
            return sym.cast(.module_alias).sym;
        },
        .use_alias => {
            const alias = sym.cast(.use_alias);
            {
                // TODO: check visibility.
                return null;
            }
            if (!alias.resolved) {
                try sema.resolveUseAlias(c, alias);
            }
            return alias.sym;
        },
        .type_alias => {
            const alias = sym.cast(.type_alias);
            if (!alias.resolved) {
                try sema_type.resolve_type_alias(c, alias);
            }
            return &alias.sym.head;
        },
        else => {
            return sym;
        }
    }
}

/// The chunk that an access is written in. `c` can be a different chunk: a core template body expanded for a
/// user type is resolved under the user chunk, and a field default is evaluated under the chunk that writes the
/// initializer. Generated nodes without a source fall back to `c`.
pub fn access_chunk(c: *cy.Chunk, node: *ast.Node) *cy.Chunk {
    const src = node.src();
    if (src == cy.NullId) {
        return c;
    }
    return c.compiler.chunks.items[src];
}

/// A `-` symbol is visible to the chunk that declares it. Chunks with the same `srcUri` are one module: a
/// `persist_main` session creates a new main chunk for every eval under the same uri (F-30).
pub fn is_sym_visible(c: *cy.Chunk, sym: *cy.Sym, node: *ast.Node) bool {
    if (!sym.getMetadata().private) {
        return true;
    }
    // A `use` alias is always private so that `use *` does not re-export it, but the qualified path through it
    // (`libc.macos.Stat`) stays open as before.
    if (sym.type == .use_alias or sym.type == .module_alias) {
        return true;
    }
    const owner = sym.getRootChunk();
    const from = access_chunk(c, node);
    return owner == from or std.mem.eql(u8, owner.srcUri, from.srcUri);
}

/// Reports an access to a `-` symbol from another module. Aliases are checked as themselves, not as their target,
/// so `use *` aliases and `persist_main` aliases of private symbols pass (they belong to the importing chunk).
pub fn check_sym_visible(c: *cy.Chunk, sym: *cy.Sym, node: *ast.Node) !void {
    if (is_sym_visible(c, sym, node)) {
        return;
    }
    const kind: []const u8 = if (sym.type == .field) "field" else "symbol";
    const parent_name = try cy.sym.formatSymName(c.sema, &cy.tempBuf, sym.parent.?, .{ .from = c });
    return c.reportErrorFmt("Can not access the private {} `{}` in `{}`. A symbol declared with `-` is only visible to the module that declares it.", &.{v(kind), v(sym.name()), v(parent_name)}, node);
}

/// Note that resolved refers to a resolved symbol path and not the underlying symbol content.
pub fn getResolvedSym(c: *cy.Chunk, modSym: *cy.Sym, name: []const u8, node: *ast.Node) anyerror!?*cy.Sym {
    const res = try getResolvedSym2(c, modSym, name, node);
    if (c.compiler.record_refs) {
        if (res) |sym| cy.refs.recordSym(c, node, name, sym);
    }
    return res;
}

fn getResolvedSym2(c: *cy.Chunk, modSym: *cy.Sym, name: []const u8, node: *ast.Node) anyerror!?*cy.Sym {
    const mod = modSym.getMod() orelse {
        return null;
    };
    if (mod.getSym(name)) |sym| {
        try check_sym_visible(c, sym, node);
        switch (sym.type) {
            .module_alias => {
                return sym.cast(.module_alias).sym;
            },
            .use_alias => {
                const alias = sym.cast(.use_alias);
                if (!alias.resolved) {
                    try sema.resolveUseAlias(c, alias);
                }
                return alias.sym;
            },
            .type_alias => {
                const alias = sym.cast(.type_alias);
                if (!alias.resolved) {
                    try sema_type.resolve_type_alias(c, alias);
                }
                return &alias.sym.head;
            },
            else => {
                return sym;
            }
        }
    }

    // Lazily load instance sym.
    if (modSym.instance()) |variant| {
        if (variant.getSymTemplate().getMod().getSym(name)) |sym| {
            if (sym.type == .variant_func) {
                const func_sym = sym.cast(.variant_func);

                // The functions are reserved in the module of the instance before their signatures are resolved.
                // If one fails, the name is taken out again: the next lookup would otherwise find a function
                // without a signature (a crash in a session that compiles again, and with error recovery in the
                // next body that calls it). It then fails here once more, with its report.
                var resolved = false;
                defer if (!resolved) {
                    _ = mod.symMap.remove(name);
                };
                try sema.ensure_resolved_instance_func_decl(c, &func_sym.decl);
                if (func_sym.decl.with_cstrs.len > 0) {
                    try sema.check_instance_func_cstr(c, variant, &func_sym.decl, node);
                }
                // An overload that is skipped by `#[cond]` does not hide the overloads that follow it.
                if (try c.reserveFunc(modSym, sym.name(), func_sym.decl.decl)) |func| {
                    try sema.ensure_resolved_func(c, func, true, node);
                }

                for (func_sym.rest().items) |*decl| {
                    try sema.ensure_resolved_instance_func_decl(c, decl);
                    if (decl.with_cstrs.len > 0) {
                        try sema.check_instance_func_cstr(c, variant, decl, node);
                    }
                    const func = (try c.reserveFunc(modSym, sym.name(), decl.decl)) orelse continue;
                    try sema.ensure_resolved_func(c, func, true, node);
                }
                resolved = true;
                const res = mod.getSym(name) orelse return null;
                try check_sym_visible(c, res, node);
                return res;
            } else if (sym.type == .variant_member) {
                const member = sym.cast(.variant_member);
                try check_sym_visible(c, sym, node);
                if (member.decl.type() == .const_decl) {
                    return sema.reserveConst(c, modSym, sym.name(), member.decl.cast(.const_decl));
                } else if (member.decl.type() == .template) {
                    const template = member.decl.cast(.template);
                    if (template.child_decl.type() == .funcDecl) {
                        return @ptrCast(try sema.reserveFuncTemplateSym(c, modSym, sym.name(), template));
                    } else {
                        @panic("TODO");
                    }
                } else {
                    @panic("TODO");
                }
            }
        }
    }

    return null;
}

pub fn getResolvedSymOrFail(c: *cy.Chunk, modSym: *cy.Sym, name: []const u8, node: *ast.Node) !*cy.Sym {
    return (try c.getResolvedSym(modSym, name, node)) orelse {
        if (modSym.getMod() == null) {
            const mod_name = try cy.sym.formatSymName(c.sema, &cy.tempBuf, modSym, .{ .from = c });
            return c.reportErrorFmt("Can not access `{}` from parent `{}`. Parent is not a module.", &.{v(name), v(mod_name)}, node);
        } else {
            const mod_name = try cy.sym.formatSymName(c.sema, &cy.tempBuf, modSym.resolved(), .{ .from = c });
            return c.reportErrorFmt("Can not find the symbol `{}` in `{}`.", &.{v(name), v(mod_name)}, node);
        }
    };
}

/// Assumes resolved symbol.
pub fn checkResolvedSymIsDistinct(c: *cy.Chunk, sym: *cy.Sym, node: *ast.Node) !void {
    if (sym.isDistinctAssumeResolved()) {
        return;
    }
    // More than one func for sym.
    return c.reportErrorFmt("Symbol `{}` is ambiguous. There are multiple functions with the same name.", &.{v(sym.name())}, node);
}

pub fn accessResolvedSym(c: *cy.Chunk, rec_t: *cy.Type, name: []const u8, node: *ast.Node) !?*cy.Sym {
    if (try c.getResolvedSym(@ptrCast(rec_t.sym()), name, node)) |sym| {
        return sym;
    }
    if (try getRefLikeChildSym(c, rec_t, name, node)) |sym| {
        return sym;
    }
    return null;
}

pub fn accessResolvedSymOrFail(c: *cy.Chunk, rec_t: *cy.Type, name: []const u8, node: *ast.Node) !*cy.Sym {
    return (try c.accessResolvedSym(rec_t, name, node)) orelse {
        const type_name = try c.sema.allocTypeName(rec_t);
        defer c.alloc.free(type_name);
        return c.reportErrorFmt("Can not find the symbol `{}` for `{}`.", &.{v(name), v(type_name)}, node);
    };
}

pub fn getRefLikeChildSym(c: *cy.Chunk, type_: *cy.Type, name_: []const u8, node: *ast.Node) !?*cy.Sym {
    if (type_.kind() == .pointer) {
        const ptr_t = type_.cast(.pointer);
        if (ptr_t.child_t.kind() != .pointer) {
            const child_sym = ptr_t.child_t.sym();
            if (try c.getResolvedSym(@ptrCast(child_sym), name_, node)) |sym| {
                return sym;
            }
        }
    } else if (type_.kind() == .borrow) {
        const child_t = type_.cast(.borrow).child_t;
        if (try c.getResolvedSym(@ptrCast(child_t.sym()), name_, node)) |sym| {
            return sym;
        }
    } else if (type_.kind() == .ex_borrow) {
        const child_t = type_.cast(.ex_borrow).child_t;
        if (try c.getResolvedSym(@ptrCast(child_t.sym()), name_, node)) |sym| {
            return sym;
        }
    } else if (type_.kind() == .borrow_trait) {
        const trait = type_.cast(.borrow_trait).generic;
        if (try c.getResolvedSym(@ptrCast(trait.base.sym()), name_, node)) |sym| {
            return sym;
        }
    } else if (type_.kind() == .ref_trait) {
        const trait = type_.cast(.ref_trait).generic;
        if (try c.getResolvedSym(@ptrCast(trait.base.sym()), name_, node)) |sym| {
            return sym;
        }
    }
    return null;
}

test "module internals" {
    try t.eq(@offsetOf(Module, "symMap"), @offsetOf(vmc.Module, "symMap"));
    try t.eq(@offsetOf(Module, "overloadedFuncMap"), @offsetOf(vmc.Module, "overloadedFuncMap"));
}
