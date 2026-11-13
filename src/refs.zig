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
    return .{ .ref = best orelse return null, .type = best_t };
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
            if (sym.type == .field) {
                const field = sym.cast(.field);
                try w.writeAll(name);
                try w.writeAll(" ");
                try writeTypeName(compiler, w, field.type);
                if (fieldNameNode(sym)) |name_n| {
                    setDef(compiler, &info, name_n);
                }
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
                setDef(compiler, &info, decl);
            } else if (sym.type == .enum_case or sym.type == .choice_case or sym.type == .union_case) {
                if (sym.parent) |parent| {
                    try w.print("case {s}.{s}", .{ parent.name(), sym.name() });
                } else {
                    try w.print("case {s}", .{sym.name()});
                }
            } else {
                try w.print("{s} {s}", .{ symKindName(sym.type), sym.name() });
                if (best_t) |type_| {
                    try w.writeAll(" ");
                    try writeTypeName(compiler, w, type_);
                }
            }
        },
    }

    compiler.alloc.free(compiler.ref_detail);
    compiler.ref_detail = "";
    compiler.ref_detail = try buf.toOwnedSlice();
    info.detail = compiler.ref_detail;
    return info;
}

fn writeTypeName(compiler: *cy.Compiler, w: *std.Io.Writer, type_: *cy.Type) !void {
    const name = try compiler.sema.allocTypeName(type_);
    defer compiler.alloc.free(name);
    try w.writeAll(name);
}

fn declOf(sym: *cy.Sym) ?*ast.Node {
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
