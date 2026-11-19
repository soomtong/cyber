//! What the names in the main source of a compile refer to, for editor tooling (hover, go to definition).
//! Sema records a reference where it resolves a name, when the host asked for it (`cl_vm_set_symbol_info`).
//! Only the main chunk is recorded: a host that wants the references of a module compiles it as the main source.

const std = @import("std");
const cy = @import("cyber.zig");
const ast = cy.ast;

pub const Kind = enum(u8) {
    /// An expression and its type. `data` is unused.
    expr,
    /// A name that resolved to a symbol.
    sym,
    /// A local, at its declaration or at a use.
    local,
};

pub const Ref = struct {
    /// Byte offsets in the main source. `end` is exclusive.
    pos: u32,
    end: u32,
    kind: Kind,
    type: ?*cy.Type = null,
    data: union {
        none: void,
        sym: *cy.Sym,
        /// Offset of the name in the declaration, in the main source. `cy.NullId` if it is not in the source.
        local_decl: u32,
    } = .{ .none = {} },
};

/// The range of `node` in the main source, if sema is recording and the node is from there.
fn rangeOf(c: *cy.Chunk, node: *ast.Node) ?[2]u32 {
    const compiler = c.compiler;
    if (!compiler.record_refs or c != compiler.main_chunk) return null;
    if (node.type() == .null) return null;
    // Compile-time evaluation in the main chunk also goes over nodes of other sources (the declarations of a
    // template in `core`). Their positions are in another source.
    if (node.src() != c.id) return null;
    const pos = node.pos();
    if (pos == cy.NullId) return null;
    const end = node.end();
    if (end == cy.NullId or end <= pos or end > c.src.len) return null;
    return .{ pos, end };
}

fn append(c: *cy.Chunk, ref: Ref) void {
    // The references are a convenience. Without memory for one the compile goes on without it.
    c.compiler.refs.append(c.compiler.alloc, ref) catch {};
}

/// The type of an expression.
pub fn recordExpr(c: *cy.Chunk, node: *ast.Node, type_: *cy.Type) void {
    const range = rangeOf(c, node) orelse return;
    append(c, .{ .pos = range[0], .end = range[1], .kind = .expr, .type = type_ });
}

/// `node` is the name `name` and resolved to `sym`. A lookup on behalf of a larger node (the `@init_sequence`
/// of a literal) is not a reference of that node.
pub fn recordSym(c: *cy.Chunk, node: *ast.Node, name: []const u8, sym: *cy.Sym) void {
    const range = rangeOf(c, node) orelse return;
    if (!std.mem.eql(u8, c.src[range[0]..range[1]], name)) return;
    append(c, .{ .pos = range[0], .end = range[1], .kind = .sym, .data = .{ .sym = sym } });
}

/// A use of a local. `name` is the name the local was declared with.
pub fn recordLocalUse(c: *cy.Chunk, node: *ast.Node, type_: *cy.Type, decl_name: []const u8) void {
    const range = rangeOf(c, node) orelse return;
    if (!std.mem.eql(u8, c.src[range[0]..range[1]], decl_name)) return;
    append(c, .{ .pos = range[0], .end = range[1], .kind = .local, .type = type_, .data = .{ .local_decl = declPos(c, decl_name) } });
}

/// The declaration of a local. The name of a declared local is a slice of the source, a hidden local has a
/// name of its own and is skipped.
pub fn recordLocalDecl(c: *cy.Chunk, name: []const u8, type_: *cy.Type) void {
    const compiler = c.compiler;
    if (!compiler.record_refs or c != compiler.main_chunk) return;
    const pos = declPos(c, name);
    if (pos == cy.NullId) return;
    append(c, .{ .pos = pos, .end = pos + @as(u32, @intCast(name.len)), .kind = .local, .type = type_, .data = .{ .local_decl = pos } });
}

/// The type of a local that was declared without one is known after its initializer. Recorded again at the
/// declaration: the last reference recorded for a range is the one that is found.
pub fn recordLocalType(c: *cy.Chunk, local: *const cy.sema.Local) void {
    recordLocalDecl(c, local.namePtr[0..local.nameLen], local.decl_t);
}

fn declPos(c: *cy.Chunk, name: []const u8) u32 {
    const start = @intFromPtr(c.src.ptr);
    const ptr = @intFromPtr(name.ptr);
    if (name.len == 0 or ptr < start or ptr + name.len > start + c.src.len) return cy.NullId;
    return @intCast(ptr - start);
}

pub const Info = struct {
    kind: Kind = .expr,

    /// The range of the name or expression at the position.
    pos: u32 = 0,
    end: u32 = 0,

    /// One line that describes it: the header of the declaration, `name Type` for a local or a field,
    /// the type for another expression. Valid until the next `find` or compile.
    detail: []const u8 = "",

    /// Where it is declared. `def_uri` is empty if it has no declaration in a source (a builtin type).
    def_uri: []const u8 = "",
    def_pos: u32 = 0,
    def_end: u32 = 0,
};

const Picked = struct {
    ref: Ref,
    /// The type of the expression with the same range, if one was recorded.
    type: ?*cy.Type,
};

/// The reference at byte offset `pos`.
fn pick(compiler: *cy.Compiler, pos: u32) ?Picked {
    // The smallest range that holds the position is the name itself. For the same range a symbol or a local
    // says more than the type of the expression, and the last one recorded is the most resolved.
    var best: ?Ref = null;
    var best_t: ?*cy.Type = null;
    for (compiler.refs.items) |ref| {
        // The end is included so that the position right after a name still finds it.
        if (pos < ref.pos or pos > ref.end) continue;
        if (best) |b| {
            const len = ref.end - ref.pos;
            const best_len = b.end - b.pos;
            if (len > best_len) continue;
            if (len == best_len) {
                if (ref.kind == .expr) {
                    if (ref.pos == b.pos) best_t = ref.type;
                    continue;
                }
            } else {
                best_t = null;
            }
        }
        if (ref.kind == .expr) best_t = ref.type;
        best = ref;
    }
    // The name in a declaration is not a use and has no reference of its own, but it is where "find the
    // uses" is asked most. A name is never inside an expression that is not also a name, so it wins over one.
    if (best == null or best.?.kind == .expr) {
        if (declAt(compiler, pos)) |decl_ref| {
            return .{ .ref = decl_ref, .type = null };
        }
    }
    return .{ .ref = best orelse return null, .type = best_t };
}

/// The declaration of the main source whose name is at `pos`, as a reference to the symbol it declares.
fn declAt(compiler: *cy.Compiler, pos: u32) ?Ref {
    const main = compiler.main_chunk;
    for (main.funcs.items) |func| {
        const decl = func.decl orelse continue;
        if (decl.type() != .funcDecl) continue;
        // An instance of a template shares the declaration of the template, which is found as a symbol below.
        if (func.parent.type != .func) continue;
        if (nameRange(main, decl.cast(.funcDecl).name, pos)) |range| {
            return .{ .pos = range[0], .end = range[1], .kind = .sym, .data = .{ .sym = func.parent } };
        }
    }
    for (main.syms.items) |sym| {
        if (declNameNode(sym)) |name_n| {
            if (nameRange(main, name_n, pos)) |range| {
                return .{ .pos = range[0], .end = range[1], .kind = .sym, .data = .{ .sym = sym } };
            }
        }
        // The fields and the cases are symbols of the type, found through its declaration.
        const decl = declOf(sym) orelse continue;
        const mod = sym.getMod() orelse continue;
        switch (decl.type()) {
            .struct_decl, .cstruct_decl => {
                const fields = if (decl.type() == .struct_decl) decl.cast(.struct_decl).fields.slice() else decl.cast(.cstruct_decl).fields.slice();
                for (fields) |field| {
                    if (memberAt(main, mod, field.name, pos, &.{.field})) |ref| return ref;
                }
            },
            .enumDecl => {
                for (decl.cast(.enumDecl).members.slice()) |member| {
                    if (memberAt(main, mod, member.name, pos, &.{ .enum_case, .choice_case })) |ref| return ref;
                }
            },
            .cunion_decl => {
                for (decl.cast(.cunion_decl).cases.slice()) |case| {
                    if (memberAt(main, mod, case.name, pos, &.{.union_case})) |ref| return ref;
                }
            },
            else => {},
        }
    }
    return null;
}

/// The symbol of the type module `mod` that the member name `name_n` declares, if `pos` is at the name.
fn memberAt(main: *cy.Chunk, mod: *cy.Module, name_n: *ast.Node, pos: u32, sym_types: []const cy.sym.SymType) ?Ref {
    const range = nameRange(main, name_n, pos) orelse return null;
    const member = mod.getSym(main.src[range[0]..range[1]]) orelse return null;
    if (std.mem.findScalar(cy.sym.SymType, sym_types, member.type) == null) return null;
    return .{ .pos = range[0], .end = range[1], .kind = .sym, .data = .{ .sym = member } };
}

/// The range of a name node of the main source if `pos` is in it or right after it.
fn nameRange(main: *cy.Chunk, name_n: *ast.Node, pos: u32) ?[2]u32 {
    if (name_n.type() == .null) return null;
    const start = name_n.pos();
    if (start == cy.NullId or pos < start) return null;
    const end = name_n.end();
    if (end == cy.NullId or pos > end or end <= start or end > main.src.len) return null;
    if (name_n.src() != main.id) return null;
    return .{ start, end };
}

pub const Range = extern struct {
    pos: u32,
    end: u32,
};

/// Every place in the main source that names what is named at `pos`: the uses and, if it is declared in the
/// main source, the name in the declaration. Sorted, without duplicates. Empty if `pos` is not at a local or a
/// symbol. The result is valid until the next call or compile.
pub fn findAll(compiler: *cy.Compiler, pos: u32) ![]const Range {
    const out = &compiler.ref_ranges;
    out.clearRetainingCapacity();
    if (compiler.refs_main == null) return out.items;
    const picked = pick(compiler, pos) orelse return out.items;
    const target = picked.ref;
    switch (target.kind) {
        .expr => return out.items,
        .local => {
            // A local is the same local where the declaration is the same. One that is not declared in the
            // source (`self`) is told apart by its name and type instead.
            const name = compiler.main_chunk.src[target.pos..target.end];
            for (compiler.refs.items) |ref| {
                if (ref.kind != .local or ref.data.local_decl != target.data.local_decl) continue;
                if (target.data.local_decl == cy.NullId) {
                    if (ref.type != target.type) continue;
                    if (!std.mem.eql(u8, compiler.main_chunk.src[ref.pos..ref.end], name)) continue;
                }
                try out.append(compiler.alloc, .{ .pos = ref.pos, .end = ref.end });
            }
        },
        .sym => {
            const sym = target.data.sym;
            for (compiler.refs.items) |ref| {
                if (ref.kind != .sym or ref.data.sym != sym) continue;
                try out.append(compiler.alloc, .{ .pos = ref.pos, .end = ref.end });
            }
            if (declNameNode(sym)) |name_n| {
                if (name_n.src() == compiler.main_chunk.id) {
                    const start = name_n.pos();
                    const end = name_n.end();
                    if (start != cy.NullId and end != cy.NullId and start < end and end <= compiler.main_chunk.src.len) {
                        try out.append(compiler.alloc, .{ .pos = start, .end = end });
                    }
                }
            }
        },
    }
    sortRanges(out);
    return out.items;
}

/// Where `sym` is declared, the way `Info.def_uri` and `Info.def_pos` give it.
fn defOf(compiler: *cy.Compiler, sym: *cy.Sym) ?struct { uri: []const u8, pos: u32 } {
    const decl = (if (sym.type == .field) fieldNameNode(sym) else declOf(sym)) orelse return null;
    const chunk_id = decl.src();
    if (chunk_id >= compiler.chunks.items.len) return null;
    const pos = decl.pos();
    if (pos == cy.NullId) return null;
    return .{ .uri = compiler.chunks.items[chunk_id].srcUri, .pos = pos };
}

/// Every place in the main source that names the symbol declared at byte offset `def_pos` of the source
/// `def_uri`, the way `find` reports a declaration. For a host that looks for the uses of a symbol in the
/// other sources of a project: it compiles each one as the main source and asks here.
/// The name in the declaration is included when the main source is the one that declares it.
/// Sorted, without duplicates. The result is valid until the next call, `findAll` or compile.
pub fn findAllTo(compiler: *cy.Compiler, def_uri: []const u8, def_pos: u32) ![]const Range {
    const out = &compiler.ref_ranges;
    out.clearRetainingCapacity();
    if (compiler.refs_main == null) return out.items;
    var target: ?*cy.Sym = null;
    var other: ?*cy.Sym = null;
    for (compiler.refs.items) |ref| {
        if (ref.kind != .sym) continue;
        const sym = ref.data.sym;
        // Most names refer to a few symbols: the last answers are remembered.
        if (sym != target) {
            if (sym == other) continue;
            // A module is named by an alias of each source that uses it, so it has no uses in other sources. Its
            // place is the start of its source, which is also the place of a declaration on the first line.
            if (sym.type == .chunk or sym.type == .module_alias) {
                other = sym;
                continue;
            }
            const def = defOf(compiler, sym);
            if (def == null or def.?.pos != def_pos or !std.mem.eql(u8, def.?.uri, def_uri)) {
                other = sym;
                continue;
            }
            target = sym;
        }
        try out.append(compiler.alloc, .{ .pos = ref.pos, .end = ref.end });
    }
    // The source that declares the symbol may not use it. The declaration is then found by its place.
    if (target == null and std.mem.eql(u8, compiler.main_chunk.srcUri, def_uri)) {
        target = declaredAt(compiler, def_pos);
    }
    if (target) |sym| {
        if (declNameNode(sym)) |name_n| {
            if (name_n.src() == compiler.main_chunk.id) {
                const start = name_n.pos();
                const end = name_n.end();
                if (start != cy.NullId and end != cy.NullId and start < end and end <= compiler.main_chunk.src.len) {
                    try out.append(compiler.alloc, .{ .pos = start, .end = end });
                }
            }
        }
    }
    sortRanges(out);
    return out.items;
}

/// The symbol of the main source whose declaration is at `def_pos`, as `defOf` gives the place.
fn declaredAt(compiler: *cy.Compiler, def_pos: u32) ?*cy.Sym {
    const main = compiler.main_chunk;
    for (main.funcs.items) |func| {
        if (func.parent.type != .func) continue;
        const def = defOf(compiler, func.parent) orelse continue;
        if (def.pos == def_pos and std.mem.eql(u8, def.uri, main.srcUri)) return func.parent;
    }
    for (main.syms.items) |sym| {
        if (defOf(compiler, sym)) |def| {
            if (def.pos == def_pos and std.mem.eql(u8, def.uri, main.srcUri)) return sym;
        }
        const decl = declOf(sym) orelse continue;
        const fields = switch (decl.type()) {
            .struct_decl => decl.cast(.struct_decl).fields.slice(),
            .cstruct_decl => decl.cast(.cstruct_decl).fields.slice(),
            else => continue,
        };
        // An instance of a template that another module declares is a sym of this chunk too. Its fields
        // are at offsets of that module's source.
        if (decl.src() != main.id) continue;
        const mod = sym.getMod() orelse continue;
        for (fields) |field| {
            const start = field.name.pos();
            if (start != def_pos) continue;
            const end = field.name.end();
            if (end == cy.NullId or end <= start or end > main.src.len) continue;
            const field_sym = mod.getSym(main.src[start..end]) orelse continue;
            if (field_sym.type == .field) return field_sym;
        }
    }
    return null;
}

fn sortRanges(out: *std.ArrayList(Range)) void {
    std.mem.sort(Range, out.items, {}, struct {
        fn lessThan(_: void, x: Range, y: Range) bool {
            return x.pos < y.pos or (x.pos == y.pos and x.end < y.end);
        }
    }.lessThan);
    // A name inside a template is recorded once per instance.
    var len: usize = 0;
    for (out.items) |range| {
        if (len > 0 and out.items[len - 1].pos == range.pos and out.items[len - 1].end == range.end) continue;
        out.items[len] = range;
        len += 1;
    }
    out.items.len = len;
}

pub const Token = extern struct {
    pos: u32,
    end: u32,
    kind: u32,
};

/// The names of the main source that were resolved, with what each one is, for highlighting by meaning.
/// Sorted by position, one entry per name. Keywords, literals and names that did not resolve are not listed.
/// The result is valid until the next call or compile.
pub fn tokens(compiler: *cy.Compiler) ![]const Token {
    const out = &compiler.ref_tokens;
    out.clearRetainingCapacity();
    if (compiler.refs_main == null) return out.items;
    for (compiler.refs.items) |ref| {
        const kind: ItemKind = switch (ref.kind) {
            .expr => continue,
            .local => .local,
            .sym => itemKind(ref.data.sym),
        };
        try out.append(compiler.alloc, .{ .pos = ref.pos, .end = ref.end, .kind = @intFromEnum(kind) });
    }
    // A stable sort keeps the order of recording for the same name: the last one is the most resolved.
    std.mem.sort(Token, out.items, {}, struct {
        fn lessThan(_: void, x: Token, y: Token) bool {
            return x.pos < y.pos;
        }
    }.lessThan);
    var len: usize = 0;
    for (out.items) |token| {
        if (len > 0 and out.items[len - 1].pos == token.pos) {
            out.items[len - 1] = token;
            continue;
        }
        // A name does not overlap the one before it.
        if (len > 0 and token.pos < out.items[len - 1].end) continue;
        out.items[len] = token;
        len += 1;
    }
    out.items.len = len;
    return out.items;
}

/// The node of the name in the declaration of `sym`.
fn declNameNode(sym: *cy.Sym) ?*ast.Node {
    if (sym.type == .field) return fieldNameNode(sym);
    var decl = declOf(sym) orelse return null;
    if (decl.type() == .template) decl = decl.cast(.template).child_decl;
    return switch (decl.type()) {
        .funcDecl => decl.cast(.funcDecl).name,
        .struct_decl => decl.cast(.struct_decl).name,
        .cstruct_decl => decl.cast(.cstruct_decl).name,
        .cunion_decl => decl.cast(.cunion_decl).name,
        .enumDecl => decl.cast(.enumDecl).name,
        .trait_decl => decl.cast(.trait_decl).name,
        .type_alias_decl => decl.cast(.type_alias_decl).name,
        .type_const_decl => decl.cast(.type_const_decl).name,
        .custom_type_decl => decl.cast(.custom_type_decl).name,
        .const_decl => decl.cast(.const_decl).name,
        .global_decl => decl.cast(.global_decl).name,
        else => null,
    };
}

/// Describes what is at byte offset `pos` of the main source of the last compile. Null if nothing was recorded there.
pub fn find(compiler: *cy.Compiler, pos: u32) !?Info {
    // Nothing was recorded: no compile yet, a reset, a compile that failed before its main source, or one
    // that did not record. `main_chunk` is not to be touched then.
    if (compiler.refs_main == null) return null;
    const picked = pick(compiler, pos) orelse return null;
    const best_t = picked.type;
    const ref = picked.ref;
    const main = compiler.main_chunk;

    var buf = std.Io.Writer.Allocating.init(compiler.alloc);
    defer buf.deinit();
    const w = &buf.writer;
    var info: Info = .{ .pos = ref.pos, .end = ref.end, .kind = ref.kind };
    const name = main.src[ref.pos..ref.end];

    switch (ref.kind) {
        .expr => {
            try writeTypeName(compiler, w, ref.type.?);
        },
        .local => {
            try w.writeAll(name);
            try w.writeAll(" ");
            try writeTypeName(compiler, w, ref.type.?);
            if (ref.data.local_decl != cy.NullId) {
                info.def_uri = main.srcUri;
                info.def_pos = ref.data.local_decl;
                info.def_end = info.def_pos + @as(u32, @intCast(name.len));
            }
        },
        .sym => {
            const sym = ref.data.sym;
            try writeSymDetail(compiler, w, sym, best_t);
            if (sym.type == .field) {
                if (fieldNameNode(sym)) |name_n| {
                    setDef(compiler, &info, name_n);
                }
            } else if (declOf(sym)) |decl| {
                setDef(compiler, &info, decl);
            }
        },
    }

    compiler.alloc.free(compiler.ref_detail);
    compiler.ref_detail = "";
    compiler.ref_detail = try buf.toOwnedSlice();
    info.detail = compiler.ref_detail;
    return info;
}

/// One line for a symbol: `name Type` for a field, the header of its declaration, or its kind and name.
fn writeSymDetail(compiler: *cy.Compiler, w: *std.Io.Writer, sym: *cy.Sym, expr_t: ?*cy.Type) !void {
    if (sym.type == .field) {
        try w.writeAll(sym.name());
        try w.writeAll(" ");
        try writeTypeName(compiler, w, sym.cast(.field).type);
    } else if (declOf(sym)) |decl| {
        const chunk = compiler.chunks.items[decl.src()];
        if (sym.type == .chunk) {
            try w.print("module {s}", .{chunk.srcUri});
        } else {
            try w.writeAll(headerLine(chunk.src, decl));
            if (sym.type == .func and sym.cast(.func).numFuncs > 1) {
                try w.print(" (+{} overloads)", .{sym.cast(.func).numFuncs - 1});
            }
        }
    } else if (sym.type == .enum_case or sym.type == .choice_case or sym.type == .union_case) {
        if (sym.parent) |parent| {
            try w.print("case {s}.{s}", .{ parent.name(), sym.name() });
        } else {
            try w.print("case {s}", .{sym.name()});
        }
    } else {
        try w.print("{s} {s}", .{ symKindName(sym.type), sym.name() });
        if (expr_t) |type_| {
            try w.writeAll(" ");
            try writeTypeName(compiler, w, type_);
        }
    }
}

pub const ItemKind = enum(u8) {
    local,
    function,
    type,
    field,
    case,
    constant,
    global,
    module,
    other,
    /// A function with a receiver.
    method,
};

/// A name that can be written at a position, for completion.
pub const Item = struct {
    name: []const u8,
    /// Like `Info.detail`.
    detail: []const u8,
    kind: ItemKind,
};

fn itemKind(sym: *cy.Sym) ItemKind {
    return switch (sym.type) {
        .func => if (sym.cast(.func).numFuncs > 0 and sym.cast(.func).first.isMethod()) .method else .function,
        .func_template, .variant_func => .function,
        .type, .type_alias, .type_const, .template => .type,
        .field => .field,
        .enum_case, .choice_case, .union_case => .case,
        .const_ => .constant,
        .userVar, .hostVar, .extern_var => .global,
        .chunk, .module_alias => .module,
        .use_alias => if (sym.cast(.use_alias).resolved) itemKind(sym.cast(.use_alias).sym) else .other,
        else => .other,
    };
}

const Items = struct {
    compiler: *cy.Compiler,
    arena: std.mem.Allocator,
    list: std.ArrayList(Item) = .empty,
    seen: std.StringHashMapUnmanaged(void) = .empty,

    /// The lists of the last call are dropped. They are owned by the compiler.
    fn init(compiler: *cy.Compiler) Items {
        if (compiler.ref_arena) |*arena| arena.deinit();
        compiler.ref_arena = std.heap.ArenaAllocator.init(compiler.alloc);
        return .{ .compiler = compiler, .arena = compiler.ref_arena.?.allocator() };
    }

    /// A name that was added before hides this one, like an inner declaration hides an outer one.
    fn add(self: *Items, name: []const u8, detail: []const u8, kind: ItemKind) !void {
        const res = try self.seen.getOrPut(self.arena, name);
        if (res.found_existing) return;
        try self.list.append(self.arena, .{ .name = name, .detail = detail, .kind = kind });
    }

    /// The symbols of a module that a script can name from the main source.
    fn addModule(self: *Items, mod: *cy.Module) !void {
        var iter = mod.symMap.iterator();
        while (iter.next()) |entry| {
            const name = entry.key_ptr.*;
            var sym = entry.value_ptr.*;
            // Hooks and operators (`@init`, `$get`) are not called by their names.
            if (name.len == 0 or !(std.ascii.isAlphabetic(name[0]) or name[0] == '_')) continue;
            if (sym.getMetadata().private and sym.type != .use_alias and sym.type != .module_alias) {
                if (sym.getRootChunk() != self.compiler.main_chunk) continue;
            }
            if (sym.type == .use_alias) {
                const alias = sym.cast(.use_alias);
                if (!alias.resolved) continue;
                sym = alias.sym;
            } else if (sym.type == .module_alias) {
                sym = sym.cast(.module_alias).sym;
            }
            var buf = std.Io.Writer.Allocating.init(self.arena);
            try writeSymDetail(self.compiler, &buf.writer, sym, null);
            try self.add(try self.arena.dupe(u8, name), buf.written(), itemKind(sym));
        }
    }

    fn finish(self: *Items) []const Item {
        std.mem.sort(Item, self.list.items, {}, struct {
            fn lessThan(_: void, x: Item, y: Item) bool {
                return std.mem.order(u8, x.name, y.name) == .lt;
            }
        }.lessThan);
        return self.list.items;
    }
};

/// The members of the expression that ends at byte offset `pos` of the main source: the fields and methods
/// of its type, or the symbols of the module or type that it names. Empty if no expression ends there.
/// The result is valid until the next `members`, `scope` or compile.
pub fn members(compiler: *cy.Compiler, pos: u32) ![]const Item {
    if (compiler.refs_main == null) return &.{};
    var items = Items.init(compiler);

    // The smallest expression that ends at the position is the receiver: `x + v.` asks for the members of `v`.
    var best: ?Ref = null;
    var best_t: ?*cy.Type = null;
    for (compiler.refs.items) |ref| {
        if (ref.end != pos) continue;
        if (best) |b| {
            if (ref.pos < b.pos) continue;
            if (ref.pos == b.pos and ref.kind == .expr) {
                best_t = ref.type;
                continue;
            }
            if (ref.pos > b.pos) best_t = null;
        }
        if (ref.kind == .expr) best_t = ref.type;
        best = ref;
    }
    const ref = best orelse return items.finish();

    var type_: ?*cy.Type = switch (ref.kind) {
        .expr, .local => ref.type,
        .sym => best_t,
    };
    if (ref.kind == .sym) {
        const sym = ref.data.sym;
        switch (sym.type) {
            // A module or a type is asked for what it declares: `math.`, `Color.`.
            .chunk, .type, .template, .type_const => {
                if (sym.getMod()) |mod| try items.addModule(mod);
                return items.finish();
            },
            .field => type_ = sym.cast(.field).type,
            else => {},
        }
    }
    const value_t = type_ orelse return items.finish();
    const base_t = value_t.getBaseType();
    if (base_t.sym().head.getMod()) |mod| try items.addModule(mod);
    return items.finish();
}

/// The names that can be used at byte offset `pos` of the main source: the locals and parameters declared
/// before it in the function it is in, then what the main source declares and uses, then the builtins.
/// The result is valid until the next `members`, `scope` or compile.
pub fn scope(compiler: *cy.Compiler, pos: u32) ![]const Item {
    if (compiler.refs_main == null) return &.{};
    var items = Items.init(compiler);
    const main = compiler.main_chunk;

    // The outermost function around the position. A lambda in it sees its locals too.
    var body_start: u32 = 0;
    var body_end: u32 = @intCast(main.src.len);
    var in_func = false;
    for (main.funcs.items) |func| {
        const decl = func.decl orelse continue;
        if (decl.type() != .funcDecl) continue;
        const start = decl.pos();
        if (start == cy.NullId or decl.src() != main.id) continue;
        const end = decl.end();
        if (end == cy.NullId or pos < start or pos > end) continue;
        if (!in_func or start < body_start) {
            body_start = start;
            body_end = end;
            in_func = true;
        }
    }

    // Blocks are not told apart: a local of a block that has ended is still offered.
    // The latest declaration of a name before the position is the one in scope.
    var i = compiler.refs.items.len;
    while (i > 0) {
        i -= 1;
        const ref = compiler.refs.items[i];
        if (ref.kind != .local or ref.data.local_decl == cy.NullId) continue;
        const decl_pos = ref.data.local_decl;
        if (decl_pos != ref.pos or decl_pos >= pos) continue;
        if (decl_pos < body_start or decl_pos > body_end) continue;
        if (!in_func and insideFunc(main, decl_pos)) continue;
        const name = main.src[ref.pos..ref.end];
        var buf = std.Io.Writer.Allocating.init(items.arena);
        try buf.writer.writeAll(name);
        try buf.writer.writeAll(" ");
        try writeTypeName(compiler, &buf.writer, ref.type.?);
        try items.add(name, buf.written(), .local);
    }

    if (main.sym.head.getMod()) |mod| try items.addModule(mod);
    var m = main.fallback_modules.items.len;
    while (m > 0) {
        m -= 1;
        if (main.fallback_modules.items[m].getMod()) |mod| try items.addModule(mod);
    }
    return items.finish();
}

fn insideFunc(main: *cy.Chunk, pos: u32) bool {
    for (main.funcs.items) |func| {
        const decl = func.decl orelse continue;
        if (decl.type() != .funcDecl) continue;
        const start = decl.pos();
        if (start == cy.NullId or decl.src() != main.id) continue;
        const end = decl.end();
        if (end != cy.NullId and pos >= start and pos <= end) return true;
    }
    return false;
}

fn writeTypeName(compiler: *cy.Compiler, w: *std.Io.Writer, type_: *cy.Type) !void {
    const name = try compiler.sema.allocTypeName(type_);
    defer compiler.alloc.free(name);
    try w.writeAll(name);
}

fn declOf(sym: *cy.Sym) ?*ast.Node {
    // A function symbol is reserved before its first function. After a compile that failed in between it has none.
    if (sym.type == .func and sym.cast(.func).numFuncs == 0) return null;
    const decl = sym.declNodeOrNull() orelse return null;
    if (decl.type() == .null or decl.pos() == cy.NullId) return null;
    return decl;
}

fn setDef(compiler: *cy.Compiler, info: *Info, decl: *ast.Node) void {
    const chunk_id = decl.src();
    if (chunk_id >= compiler.chunks.items.len) return;
    const chunk = compiler.chunks.items[chunk_id];
    const pos = decl.pos();
    const end = decl.end();
    if (pos == cy.NullId or end == cy.NullId or pos > chunk.src.len) return;
    info.def_uri = chunk.srcUri;
    info.def_pos = pos;
    info.def_end = @min(@max(end, pos), @as(u32, @intCast(chunk.src.len)));
}

/// A field does not keep its declaration. It is found through the declaration of its type.
fn fieldNameNode(sym: *cy.Sym) ?*ast.Node {
    const parent = sym.parent orelse return null;
    const decl = parent.declNodeOrNull() orelse return null;
    const fields = switch (decl.type()) {
        .struct_decl => decl.cast(.struct_decl).fields.slice(),
        .cstruct_decl => decl.cast(.cstruct_decl).fields.slice(),
        else => return null,
    };
    const idx = sym.cast(.field).idx;
    if (idx >= fields.len) return null;
    return fields[idx].name;
}

/// The first line of a declaration without the `:` that opens its body.
fn headerLine(src: []const u8, decl: *ast.Node) []const u8 {
    var pos: usize = @min(decl.pos(), src.len);
    // Attributes come before the declaration, on its line or on lines of their own.
    while (std.mem.startsWith(u8, src[pos..], "#[")) {
        const close = std.mem.findScalarPos(u8, src, pos, ']') orelse break;
        pos = close + 1;
        while (pos < src.len and std.ascii.isWhitespace(src[pos])) pos += 1;
    }
    const line_end = std.mem.findScalarPos(u8, src, pos, '\n') orelse src.len;
    var line = std.mem.trimEnd(u8, src[pos..line_end], " \t\r");
    if (std.mem.endsWith(u8, line, ":")) line = line[0 .. line.len - 1];
    return line;
}

fn symKindName(sym_t: cy.sym.SymType) []const u8 {
    return switch (sym_t) {
        .userVar, .hostVar, .extern_var => "global",
        .const_ => "const",
        .func, .func_template, .variant_func => "fn",
        .type, .type_alias, .type_const, .template => "type",
        .chunk, .module_alias => "module",
        .enum_case, .choice_case, .union_case => "case",
        else => "symbol",
    };
}

// -----------------------------------
// [ Hints ]
// -----------------------------------

/// A local of the main source that was declared with `x := ...` or `var x T = ...`.
pub const LocalDecl = struct {
    /// The range of the name.
    pos: u32,
    end: u32,
    /// The type of a local that was declared without one. Null when the declaration names it.
    inferred: ?*cy.Type,
};

/// A call of the main source and the function that it calls, out of the overloads.
pub const Call = struct {
    node: *ast.Node,
    func: *cy.Func,
};

/// A call `f(a, b)` or `x.f(a, b)` of the main source. Calls that sema makes for other nodes (operators,
/// literals) are not `callExpr` nodes and are skipped. A call that sema makes as a `callExpr` names an `@` builtin
/// (`fiber f(a)` is `@new_fiber(f, {a})`): its parameters are not what the source passes.
pub fn recordCall(c: *cy.Chunk, node: *ast.Node, func: *cy.Func) void {
    if (node.type() != .callExpr) return;
    if (node.cast(.callExpr).callee.type() == .at_lit) return;
    _ = rangeOf(c, node) orelse return;
    c.compiler.ref_calls.append(c.compiler.alloc, .{ .node = node, .func = func }) catch {};
}

pub const HintKind = enum(u32) {
    /// `x := expr`: the type that was inferred for `x`. The range is the name, `detail` is the type.
    local_type = 0,
    /// A `return`, `break` or `continue` that waits for the fibers of a `scope` block before it leaves the block.
    /// The range is the statement, `detail` is the keyword.
    scope_exit = 1,
    /// A local that is declared and never used. The range is the name, `detail` is the name.
    unused_local = 2,
    /// A `use` whose module is never named. The range is the statement, `detail` is the name of the module.
    unused_use = 3,
    /// An argument of a call to a function with two or more parameters: the name of its parameter. The range is the
    /// argument, `detail` is the name. Not listed when the argument is a name that ends in the parameter's name.
    param_name = 4,
};

pub const Hint = extern struct {
    pos: u32,
    end: u32,
    kind: u32,
    detail_ptr: [*]const u8,
    detail_len: usize,
};

/// `x := expr` or `var x T = expr` in the main source. `inferred` is the type of a local without a declared type.
pub fn recordDeclaredLocal(c: *cy.Chunk, name_n: *ast.Node, inferred: ?*cy.Type) void {
    const compiler = c.compiler;
    if (!compiler.record_refs or c != compiler.main_chunk) return;
    if (name_n.type() != .ident) return;
    // The position comes from the name, a slice of the source, like `recordLocalDecl`. A declaration in a template
    // of another source can be checked in the main chunk (compile-time evaluation), and its name is not in the
    // main source.
    const name = name_n.cast(.ident).name.slice();
    const pos = declPos(c, name);
    if (pos == cy.NullId) return;
    compiler.ref_locals.append(compiler.alloc, .{ .pos = pos, .end = pos + @as(u32, @intCast(name.len)), .inferred = inferred }) catch {};
}

/// A statement that waits for the fibers of a `scope` block before it leaves it.
pub fn recordScopeExit(c: *cy.Chunk, node: *ast.Node) void {
    const range = rangeOf(c, node) orelse return;
    c.compiler.ref_scope_exits.append(c.compiler.alloc, range) catch {};
}

/// Notes on the main source of the last compile for an editor: inferred types, statements that wait for fibers,
/// and, when `complete` (the compile reached every body without an error), the locals and `use`s that are never
/// used. Sorted by position. Valid until the next compile. The hints are made once per compile.
pub fn hints(compiler: *cy.Compiler, complete: bool) ![]const Hint {
    const out = &compiler.ref_hints;
    const text = &compiler.ref_hint_text;
    if (compiler.ref_hints_done == complete) return out.items;
    compiler.ref_hints_done = null;
    out.clearRetainingCapacity();
    text.clearRetainingCapacity();
    const main = compiler.refs_main orelse return out.items;
    const alloc = compiler.alloc;

    // The detail is an offset into `text` until the end, since `text` can move while it grows.
    const Pending = struct { pos: u32, end: u32, kind: HintKind, start: usize, len: usize };
    var pending: std.ArrayList(Pending) = .empty;
    defer pending.deinit(alloc);

    for (compiler.ref_locals.items) |local| {
        const type_ = local.inferred orelse continue;
        const name = try compiler.sema.allocTypeName(type_);
        defer alloc.free(name);
        const start = text.items.len;
        try text.appendSlice(alloc, name);
        try pending.append(alloc, .{ .pos = local.pos, .end = local.end, .kind = .local_type, .start = start, .len = name.len });
    }
    for (compiler.ref_scope_exits.items) |range| {
        const src = main.src[range[0]..range[1]];
        var kw_len: usize = 0;
        while (kw_len < src.len and std.ascii.isAlphabetic(src[kw_len])) kw_len += 1;
        const kw = src[0..kw_len];
        if (!std.mem.eql(u8, kw, "return") and !std.mem.eql(u8, kw, "break") and !std.mem.eql(u8, kw, "continue")) continue;
        try pending.append(alloc, .{ .pos = range[0], .end = range[1], .kind = .scope_exit, .start = @intFromPtr(src.ptr) - @intFromPtr(main.src.ptr), .len = kw_len });
    }
    try paramNames(compiler, main, text, &pending);
    if (complete) {
        var index = try RefIndex.init(compiler);
        defer index.deinit(alloc);
        try unusedLocals(compiler, main, &index, &pending);
        try unusedUses(compiler, main, &index, &pending);
    }

    std.mem.sort(Pending, pending.items, {}, struct {
        fn lessThan(_: void, x: Pending, y: Pending) bool {
            return x.pos < y.pos or (x.pos == y.pos and @intFromEnum(x.kind) < @intFromEnum(y.kind));
        }
    }.lessThan);
    for (pending.items, 0..) |p, i| {
        // A local in a template body is recorded once per instance: the last one is kept.
        if (i + 1 < pending.items.len) {
            const next = pending.items[i + 1];
            if (next.pos == p.pos and next.end == p.end and next.kind == p.kind) continue;
        }
        const detail = if (p.kind == .scope_exit or p.kind == .unused_local or p.kind == .unused_use)
            main.src[p.start..][0..p.len]
        else
            text.items[p.start..][0..p.len];
        try out.append(alloc, .{ .pos = p.pos, .end = p.end, .kind = @intFromEnum(p.kind), .detail_ptr = detail.ptr, .detail_len = detail.len });
    }
    compiler.ref_hints_done = complete;
    return out.items;
}

/// The names of the parameters at the arguments of the calls in the main source.
fn paramNames(compiler: *cy.Compiler, main: *cy.Chunk, text: *std.ArrayList(u8), pending: anytype) !void {
    const alloc = compiler.alloc;
    // A call in a template body or a loop is recorded more than once. In a template body each instance can call
    // another overload, with other names: such a call has no hints. The instances of one template share a declaration.
    var decls: std.AutoArrayHashMapUnmanaged(*ast.Node, ?*ast.Node) = .empty;
    defer decls.deinit(alloc);
    for (compiler.ref_calls.items) |call_rec| {
        const entry = try decls.getOrPut(alloc, call_rec.node);
        if (!entry.found_existing) {
            entry.value_ptr.* = call_rec.func.decl;
        } else if (entry.value_ptr.* != call_rec.func.decl) {
            entry.value_ptr.* = null;
        }
    }
    outer: for (decls.keys(), decls.values()) |call_node, opt_decl| {
        const decl_n = opt_decl orelse continue;
        if (decl_n.type() != .funcDecl) continue;
        const decl = decl_n.cast(.funcDecl);

        // The parameters that the arguments are written for: not the receiver, not the template parameters.
        // A parameter without a name or more parameters than the buffer: the arguments can not be matched.
        var names_buf: [32][]const u8 = undefined;
        var nparams: usize = 0;
        for (decl.params.slice()) |param| {
            if (param.template_param) continue;
            const name = param.name_type.nameOrNull() orelse continue :outer;
            if (std.mem.eql(u8, name, "self")) continue;
            if (nparams == names_buf.len) continue :outer;
            names_buf[nparams] = name;
            nparams += 1;
        }
        const names = names_buf[0..nparams];
        if (names.len < 2) continue;

        const args = call_node.cast(.callExpr).args.slice();
        // `Vec2.scale(v, 2.0)` passes the receiver as the first argument.
        const skip: usize = if (args.len == names.len) 0 else if (args.len == names.len + 1) 1 else continue;
        for (args[skip..], names) |arg, name| {
            if (name.len == 0 or name[0] == '_') continue;
            if (arg.src() != main.id) continue;
            const pos = arg.pos();
            const end = arg.end();
            if (pos == cy.NullId or end == cy.NullId or end <= pos or end > main.src.len) continue;
            if (argNamesParam(main.src[pos..end], name)) continue;
            const start = text.items.len;
            try text.appendSlice(alloc, name);
            try pending.append(alloc, .{ .pos = pos, .end = end, .kind = .param_name, .start = start, .len = name.len });
        }
    }
}

/// Whether an argument already says the name of its parameter: `width`, `self.width`, `&width`, `old_width`.
fn argNamesParam(arg: []const u8, param: []const u8) bool {
    var s = std.mem.trim(u8, arg, " \t");
    while (s.len > 0 and (s[0] == '&' or s[0] == '^')) s = s[1..];
    var end = s.len;
    while (end > 0 and (std.ascii.isAlphanumeric(s[end - 1]) or s[end - 1] == '_')) end -= 1;
    // Only a name or a path of names, not a call or an expression that ends in a name.
    for (s[0..end]) |ch| {
        if (!(std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '.' or ch == '&')) return false;
    }
    const last = s[end..];
    if (last.len < param.len) return false;
    if (!std.mem.endsWith(u8, last, param)) return false;
    return last.len == param.len or last[last.len - param.len - 1] == '_';
}

test argNamesParam {
    try std.testing.expect(argNamesParam("width", "width"));
    try std.testing.expect(argNamesParam("self.width", "width"));
    try std.testing.expect(argNamesParam("&width", "width"));
    try std.testing.expect(argNamesParam("old_width", "width"));
    try std.testing.expect(!argNamesParam("bandwidth", "width"));
    try std.testing.expect(!argNamesParam("f(width)", "width"));
    try std.testing.expect(!argNamesParam("1", "width"));
    try std.testing.expect(!argNamesParam("a + width", "width"));
}

/// The positions that `unusedLocals` and `unusedUses` ask about, from one pass over the references.
const RefIndex = struct {
    /// The declarations of the locals that are used somewhere else than at the declaration.
    used_decls: std.AutoHashMapUnmanaged(u32, void) = .empty,
    /// The positions that sema resolved to a local or a symbol.
    resolved: std.AutoHashMapUnmanaged(u32, void) = .empty,

    fn init(compiler: *cy.Compiler) !RefIndex {
        var index: RefIndex = .{};
        errdefer index.deinit(compiler.alloc);
        for (compiler.refs.items) |ref| {
            if (ref.kind != .expr) try index.resolved.put(compiler.alloc, ref.pos, {});
            if (ref.kind == .local and ref.pos != ref.data.local_decl) {
                try index.used_decls.put(compiler.alloc, ref.data.local_decl, {});
            }
        }
        return index;
    }

    fn deinit(self: *RefIndex, alloc: std.mem.Allocator) void {
        self.used_decls.deinit(alloc);
        self.resolved.deinit(alloc);
    }
};

fn unusedLocals(compiler: *cy.Compiler, main: *cy.Chunk, index: *const RefIndex, pending: anytype) !void {
    // A declaration is recorded once per instance of a template body.
    var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer seen.deinit(compiler.alloc);
    for (compiler.ref_locals.items) |local| {
        if ((try seen.fetchPut(compiler.alloc, local.pos, {})) != null) continue;
        const name = main.src[local.pos..local.end];
        // `_x` says that it is not used on purpose.
        if (name.len == 0 or name[0] == '_') continue;
        if (index.used_decls.contains(local.pos)) continue;
        if (mentionedUnresolved(main, index, name, local.end)) continue;
        try pending.append(compiler.alloc, .{ .pos = local.pos, .end = local.end, .kind = .unused_local, .start = local.pos, .len = name.len });
    }
}

fn unusedUses(compiler: *cy.Compiler, main: *cy.Chunk, index: *const RefIndex, pending: anytype) !void {
    const root = main.ast.root orelse return;
    for (root.stmts.slice()) |stmt| {
        if (stmt.type() != .import_stmt) continue;
        const import = stmt.cast(.import_stmt);
        // `use * 'x'` brings in names of its own. A `use` with a condition may be skipped on purpose.
        if (import.name.type() != .ident or import.attrs.len > 0) continue;
        const name_range = rangeOf(main, import.name) orelse continue;
        const name = main.src[name_range[0]..name_range[1]];
        if (name.len == 0 or name[0] == '_') continue;
        var used = false;
        for (compiler.refs.items) |ref| {
            if (ref.kind != .sym or ref.pos == name_range[0]) continue;
            if (std.mem.eql(u8, main.src[ref.pos..ref.end], name)) {
                used = true;
                break;
            }
        }
        if (used or mentionedUnresolved(main, index, name, name_range[1])) continue;
        const stmt_range = rangeOf(main, stmt) orelse continue;
        try pending.append(compiler.alloc, .{ .pos = stmt_range[0], .end = stmt_range[1], .kind = .unused_use, .start = name_range[0], .len = name.len });
    }
}

/// Whether `name` is written as a word after `from` at a place that sema did not resolve: a branch of `#if`
/// that was not taken, a template body that was not expanded, or a string. A use could hide there, so the
/// name is not called unused. Words in `--` comments do not count.
fn mentionedUnresolved(main: *cy.Chunk, index: *const RefIndex, name: []const u8, from: u32) bool {
    const src = main.src;
    var i: usize = from;
    while (std.mem.indexOfPos(u8, src, i, name)) |at| {
        i = at + name.len;
        if (at > 0 and isWordByte(src[at - 1])) continue;
        if (i < src.len and isWordByte(src[i])) continue;
        const line_start = if (std.mem.findScalarLast(u8, src[0..at], '\n')) |nl| nl + 1 else 0;
        if (std.mem.indexOf(u8, src[line_start..at], "--") != null) continue;
        if (!index.resolved.contains(@intCast(at))) return true;
    }
    return false;
}

fn isWordByte(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}
