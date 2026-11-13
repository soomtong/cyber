//! Document outline and folding. The outline comes from the parser alone, like `cyber fmt`: nothing is compiled.
//! Folding comes from the indentation, so it also works while the source does not parse.

const std = @import("std");
const cy = @import("../cyber.zig");
const ast = cy.ast;
const Node = ast.Node;

/// `SymbolKind` of the protocol.
pub const Kind = enum(u8) {
    class = 5,
    method = 6,
    field = 8,
    @"enum" = 10,
    interface = 11,
    function = 12,
    variable = 13,
    constant = 14,
    enum_member = 22,
    @"struct" = 23,
};

pub const Symbol = struct {
    name: []const u8,
    /// Shown next to the name. Empty if there is nothing to add.
    detail: []const u8 = "",
    kind: Kind,
    /// Byte offsets of the whole declaration. `end` is exclusive.
    pos: u32,
    end: u32,
    /// Byte offsets of the name. Inside `pos`..`end`.
    name_pos: u32,
    name_end: u32,
    children: []const Symbol = &.{},
};

const Collector = struct {
    arena: std.mem.Allocator,
    src: []const u8,

    fn text(self: *Collector, node: *Node) []const u8 {
        const start = @min(node.pos(), self.src.len);
        const end = @min(@max(node.end(), start), self.src.len);
        return self.src[start..end];
    }

    /// The range of the name is kept inside the range of the declaration, which the protocol requires.
    fn symbol(self: *Collector, decl: *Node, name: *Node, kind: Kind) Symbol {
        const len: u32 = @intCast(self.src.len);
        const name_pos = @min(name.pos(), len);
        const name_end = @min(@max(name.end(), name_pos), len);
        return .{
            .name = self.src[name_pos..name_end],
            .kind = kind,
            .pos = @min(decl.pos(), name_pos),
            .end = @min(@max(decl.end(), name_end), len),
            .name_pos = name_pos,
            .name_end = name_end,
        };
    }

    fn member(self: *Collector, name: *Node, last: ?*Node, kind: Kind) Symbol {
        var sym = self.symbol(name, name, kind);
        if (last) |node| {
            sym.end = @min(@max(node.end(), sym.end), @as(u32, @intCast(self.src.len)));
        }
        return sym;
    }

    fn func(self: *Collector, node: *Node) !Symbol {
        const decl = node.cast(.funcDecl);
        var sym = self.symbol(node, decl.name, .function);
        // `fn (&Foo) bar()` and `fn Foo :: bar()` are listed as `Foo.bar`.
        // The receiver of a method is its first parameter, the owner of a static function is `parent`.
        var owner_n: ?*Node = decl.parent;
        if (decl.sig_t == .method and decl.params.len > 0) {
            const self_param = decl.params.ptr[0];
            owner_n = self_param.type orelse self_param.name_type;
        }
        if (owner_n) |owner_node| {
            sym.kind = .method;
            const owner = std.mem.trimStart(u8, self.text(owner_node), "&");
            sym.name = try std.fmt.allocPrint(self.arena, "{s}.{s}", .{ owner, sym.name });
        }
        return sym;
    }

    fn add(self: *Collector, out: *std.ArrayList(Symbol), node: *Node) error{OutOfMemory}!void {
        switch (node.type()) {
            .funcDecl => try out.append(self.arena, try self.func(node)),
            .struct_decl, .cstruct_decl => {
                const decl = if (node.type() == .struct_decl) node.cast(.struct_decl) else node.cast(.cstruct_decl);
                var sym = self.symbol(node, decl.name, .@"struct");
                var children: std.ArrayList(Symbol) = .empty;
                for (decl.fields.slice()) |field| {
                    try children.append(self.arena, self.member(field.name, field.typeSpec, .field));
                }
                sym.children = children.items;
                try out.append(self.arena, sym);
            },
            .cunion_decl => {
                const decl = node.cast(.cunion_decl);
                var sym = self.symbol(node, decl.name, .@"struct");
                var children: std.ArrayList(Symbol) = .empty;
                for (decl.cases.slice()) |case| {
                    try children.append(self.arena, self.member(case.name, case.payload_t, .field));
                }
                sym.children = children.items;
                try out.append(self.arena, sym);
            },
            .enumDecl => {
                const decl = node.cast(.enumDecl);
                var sym = self.symbol(node, decl.name, .@"enum");
                var children: std.ArrayList(Symbol) = .empty;
                for (decl.members.slice()) |m| {
                    try children.append(self.arena, self.member(m.name, m.typeSpec, .enum_member));
                }
                sym.children = children.items;
                try out.append(self.arena, sym);
            },
            .trait_decl => {
                const decl = node.cast(.trait_decl);
                var sym = self.symbol(node, decl.name, .interface);
                var children: std.ArrayList(Symbol) = .empty;
                for (decl.funcs.slice()) |f| {
                    const f_node: *Node = @ptrCast(f);
                    try children.append(self.arena, self.symbol(f_node, f.name, .method));
                }
                sym.children = children.items;
                try out.append(self.arena, sym);
            },
            .type_alias_decl => try out.append(self.arena, self.symbol(node, node.cast(.type_alias_decl).name, .class)),
            .type_const_decl => try out.append(self.arena, self.symbol(node, node.cast(.type_const_decl).name, .class)),
            .custom_type_decl => try out.append(self.arena, self.symbol(node, node.cast(.custom_type_decl).name, .class)),
            .const_decl => try out.append(self.arena, self.symbol(node, node.cast(.const_decl).name, .constant)),
            .global_decl => try out.append(self.arena, self.symbol(node, node.cast(.global_decl).name, .variable)),
            .var_decl => {
                // A local of the main block. Only a plain name is listed.
                const decl = node.cast(.var_decl);
                if (decl.name.type() == .ident) {
                    try out.append(self.arena, self.symbol(node, decl.name, .variable));
                }
            },
            .template => try self.add(out, node.cast(.template).child_decl),
            else => {},
        }
    }
};

/// The declarations at the top level of `src`, in source order. Null if `src` does not parse.
/// The result is allocated in `arena` and its names point into `src` or `arena`.
pub fn documentSymbols(arena: std.mem.Allocator, src: []const u8) error{OutOfMemory}!?[]const Symbol {
    var parser: cy.Parser = undefined;
    try parser.init(arena);
    defer parser.deinit();
    parser.reportFn = parserReport;
    parser.tokenizerReportFn = tokenizerReport;
    parser.ctx = &parser;

    const res = parser.parse(src, 0, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    if (res.has_error) return null;
    const root = res.root orelse return null;

    var c: Collector = .{ .arena = arena, .src = src };
    var out: std.ArrayList(Symbol) = .empty;
    for (root.stmts.slice()) |stmt| {
        try c.add(&out, stmt);
    }
    return out.items;
}

fn parserReport(_: *cy.Parser, _: []const u8, _: []const cy.fmt.FmtValue, _: u32) anyerror {
    return error.ParseError;
}

fn tokenizerReport(_: *anyopaque, _: []const u8, _: []const cy.fmt.FmtValue, _: u32) anyerror!void {
    return error.TokenError;
}

pub const Fold = struct {
    /// Lines start at 0. The fold hides the lines after `start_line` up to and including `end_line`.
    start_line: u32,
    end_line: u32,
};

/// A line followed by more indented lines folds up to the last of them. Blank lines at the end of a block
/// are left outside.
pub fn foldingRanges(alloc: std.mem.Allocator, src: []const u8) error{OutOfMemory}![]Fold {
    const Open = struct { line: u32, indent: u32 };
    var out: std.ArrayList(Fold) = .empty;
    errdefer out.deinit(alloc);
    var stack: std.ArrayList(Open) = .empty;
    defer stack.deinit(alloc);

    var last_content: u32 = 0;
    var line_no: u32 = 0;
    var lines = std.mem.splitScalar(u8, src, '\n');
    while (lines.next()) |line| : (line_no += 1) {
        var indent: u32 = 0;
        while (indent < line.len and (line[indent] == ' ' or line[indent] == '\t')) indent += 1;
        if (indent == line.len or line[indent] == '\r') continue;

        while (stack.items.len > 0 and stack.items[stack.items.len - 1].indent >= indent) {
            const open = stack.pop().?;
            if (last_content > open.line) {
                try out.append(alloc, .{ .start_line = open.line, .end_line = last_content });
            }
        }
        try stack.append(alloc, .{ .line = line_no, .indent = indent });
        last_content = line_no;
    }
    while (stack.pop()) |open| {
        if (last_content > open.line) {
            try out.append(alloc, .{ .start_line = open.line, .end_line = last_content });
        }
    }
    std.mem.sort(Fold, out.items, {}, struct {
        fn lessThan(_: void, a: Fold, b: Fold) bool {
            return a.start_line < b.start_line;
        }
    }.lessThan);
    return out.toOwnedSlice(alloc);
}

test "The outline lists the declarations of a source." {
    const t = std.testing;
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\use math
        \\
        \\type Vec2:
        \\    x float
        \\    y float
        \\
        \\fn (&Vec2) len() -> float:
        \\    return math.sqrt(self.x * self.x + self.y * self.y)
        \\
        \\type Color enum:
        \\    case red
        \\    case green
        \\
        \\const limit = 10
        \\
        \\fn add(a int, b int) -> int:
        \\    return a + b
        \\
        \\total := add(1, 2)
        \\
    ;
    const syms = (try documentSymbols(arena, src)).?;
    try t.expectEqual(@as(usize, 6), syms.len);

    try t.expectEqualStrings("Vec2", syms[0].name);
    try t.expectEqual(Kind.@"struct", syms[0].kind);
    try t.expectEqualStrings("type Vec2:\n    x float\n    y float", src[syms[0].pos..syms[0].end]);
    try t.expectEqualStrings("Vec2", src[syms[0].name_pos..syms[0].name_end]);
    try t.expectEqual(@as(usize, 2), syms[0].children.len);
    try t.expectEqualStrings("x", syms[0].children[0].name);
    try t.expectEqualStrings("y float", src[syms[0].children[1].pos..syms[0].children[1].end]);

    try t.expectEqualStrings("Vec2.len", syms[1].name);
    try t.expectEqual(Kind.method, syms[1].kind);
    try t.expectEqualStrings("len", src[syms[1].name_pos..syms[1].name_end]);
    try t.expect(std.mem.endsWith(u8, src[syms[1].pos..syms[1].end], "self.y * self.y)"));

    try t.expectEqualStrings("Color", syms[2].name);
    try t.expectEqual(Kind.@"enum", syms[2].kind);
    try t.expectEqual(@as(usize, 2), syms[2].children.len);
    try t.expectEqualStrings("green", syms[2].children[1].name);

    try t.expectEqualStrings("limit", syms[3].name);
    try t.expectEqual(Kind.constant, syms[3].kind);

    try t.expectEqualStrings("add", syms[4].name);
    try t.expectEqual(Kind.function, syms[4].kind);

    try t.expectEqualStrings("total", syms[5].name);
    try t.expectEqual(Kind.variable, syms[5].kind);

    // A source that does not parse has no outline.
    try t.expectEqual(@as(?[]const Symbol, null), try documentSymbols(arena, "fn add(a int:\n"));
}

test "Folding follows the indentation." {
    const t = std.testing;
    const src =
        \\fn a():
        \\    if true:
        \\        pass
        \\
        \\    pass
        \\
        \\x := 1
        \\scope |s|:
        \\    s.start(a, {})
        \\
    ;
    const folds = try foldingRanges(t.allocator, src);
    defer t.allocator.free(folds);
    try t.expectEqual(@as(usize, 3), folds.len);
    try t.expectEqual(Fold{ .start_line = 0, .end_line = 4 }, folds[0]);
    try t.expectEqual(Fold{ .start_line = 1, .end_line = 2 }, folds[1]);
    try t.expectEqual(Fold{ .start_line = 7, .end_line = 8 }, folds[2]);
}
