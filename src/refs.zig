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
        // The fields are symbols of the type, found through its declaration.
        const decl = declOf(sym) orelse continue;
        const fields = switch (decl.type()) {
            .struct_decl => decl.cast(.struct_decl).fields.slice(),
            .cstruct_decl => decl.cast(.cstruct_decl).fields.slice(),
            else => continue,
        };
        const mod = sym.getMod() orelse continue;
        for (fields) |field| {
            const range = nameRange(main, field.name, pos) orelse continue;
            const field_sym = mod.getSym(main.src[range[0]..range[1]]) orelse continue;
            if (field_sym.type != .field) continue;
            return .{ .pos = range[0], .end = range[1], .kind = .sym, .data = .{ .sym = field_sym } };
        }
    }
    return null;
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
    var target: ?*cy.Sym = null;
    var other: ?*cy.Sym = null;
    for (compiler.refs.items) |ref| {
        if (ref.kind != .sym) continue;
        const sym = ref.data.sym;
        // Most names refer to a few symbols: the last answers are remembered.
        if (sym != target) {
            if (sym == other) continue;
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
        const mod = sym.getMod() orelse continue;
        for (fields) |field| {
            if (field.name.pos() != def_pos) continue;
            const name = main.src[field.name.pos()..@min(field.name.end(), main.src.len)];
            const field_sym = mod.getSym(name) orelse continue;
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
