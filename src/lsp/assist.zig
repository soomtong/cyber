//! Code assists that are worked out from the text: quick fixes for diagnostics, the doc comment of a
//! declaration, whether a type hint would only repeat the source, and the identifiers of a name. Pure functions
//! with unit tests.

const std = @import("std");
const cy = @import("../cyber.zig");

/// An edit of the document that fixes a diagnostic. Offsets are bytes. `title` and `new_text` are allocated.
pub const Fix = struct {
    title: []const u8,
    start: usize,
    end: usize,
    new_text: []const u8,
};

/// The codes of the diagnostics that the server makes from compiler hints.
pub const code_unused_local = "unused-local";
pub const code_unused_use = "unused-use";
pub const code_scope_exit = "scope-exit";

/// The fix for a diagnostic of the server with code `code` over `text[start..end]`. Null for another code.
/// The fix of a compile error is not made here: the compiler sends the edit with the error (`CLReport.fix_text`).
pub fn quickFix(alloc: std.mem.Allocator, text: []const u8, start: usize, end: usize, code: []const u8) !?Fix {
    if (start > end or end > text.len) return null;
    const range_text = text[start..end];

    if (std.mem.eql(u8, code, code_unused_local)) {
        if (!isIdentifier(range_text)) return null;
        return .{
            .title = try std.fmt.allocPrint(alloc, "Prefix `{s}` with `_`", .{range_text}),
            .start = start,
            .end = start,
            .new_text = try alloc.dupe(u8, "_"),
        };
    }
    if (std.mem.eql(u8, code, code_unused_use)) {
        // The whole line of the `use`, with its line break.
        const line_start = if (std.mem.findScalarLast(u8, text[0..start], '\n')) |i| i + 1 else 0;
        const line_end = if (std.mem.findScalarPos(u8, text, end, '\n')) |i| i + 1 else text.len;
        if (std.mem.trim(u8, text[line_start..start], " \t").len != 0) return null;
        return .{
            .title = try std.fmt.allocPrint(alloc, "Remove `{s}`", .{std.mem.trimEnd(u8, range_text, " \t\r\n")}),
            .start = line_start,
            .end = line_end,
            .new_text = try alloc.dupe(u8, ""),
        };
    }
    return null;
}

/// The tokenizer takes ASCII letters, digits and `_` in a name.
pub fn isIdentifier(text: []const u8) bool {
    if (text.len == 0 or std.ascii.isDigit(text[0])) return false;
    for (text) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_') return false;
    }
    return true;
}

/// Whether `text` is a keyword of the language (`return`, `fn`, `type`), which can not name anything.
pub fn isKeyword(text: []const u8) bool {
    return cy.tokenizer.isKeyword(text);
}

/// The doc comment (`--|` lines) right above the line of `pos`, without the markers. Empty if there is none.
pub fn docComment(alloc: std.mem.Allocator, src: []const u8, pos: usize) ![]const u8 {
    if (pos > src.len) return "";
    var line_start = if (std.mem.findScalarLast(u8, src[0..pos], '\n')) |i| i + 1 else 0;
    // Attributes on lines of their own sit between the comment and the declaration.
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(alloc);
    while (line_start > 0) {
        const prev_end = line_start - 1;
        const prev_start = if (std.mem.findScalarLast(u8, src[0..prev_end], '\n')) |i| i + 1 else 0;
        const line = std.mem.trim(u8, src[prev_start..prev_end], " \t\r");
        if (std.mem.startsWith(u8, line, "--|")) {
            var body = line[3..];
            if (body.len > 0 and body[0] == ' ') body = body[1..];
            try lines.append(alloc, body);
        } else if (std.mem.startsWith(u8, line, "#[") and lines.items.len == 0) {
            // An attribute above the declaration.
        } else {
            break;
        }
        line_start = prev_start;
    }
    if (lines.items.len == 0) return "";
    std.mem.reverse([]const u8, lines.items);
    return std.mem.join(alloc, "\n", lines.items);
}

/// Whether the type of `x := init` is already written at the start of `init`: `Vec2{...}`, `Foo(...)`,
/// `[]int{...}`, `Map[str, int]{}`, `'text'` for `str`, or a number for `int` and `float`. The hint then repeats it.
pub fn typeIsWritten(init: []const u8, type_name: []const u8) bool {
    const s = std.mem.trimStart(u8, init, " \t");
    // A lambda shows its signature already.
    if (std.mem.startsWith(u8, s, "fn(") or std.mem.startsWith(u8, s, "fn ")) return true;
    if (std.mem.startsWith(u8, s, type_name)) {
        const rest = s[type_name.len..];
        if (rest.len > 0 and (rest[0] == '{' or rest[0] == '(')) return true;
        // `Vec2.zero()`, `str.from_utf8(b)!` name the type too.
        if (rest.len > 0 and rest[0] == '.') return true;
    }
    if (s.len == 0) return false;
    if (std.mem.eql(u8, type_name, "str") and (s[0] == '\'' or s[0] == '"' or s[0] == '`')) return true;
    if (std.mem.eql(u8, type_name, "bool") and (std.mem.startsWith(u8, s, "true") or std.mem.startsWith(u8, s, "false"))) {
        const kw: usize = if (s[0] == 't') 4 else 5;
        return s.len == kw or !(std.ascii.isAlphanumeric(s[kw]) or s[kw] == '_');
    }
    if (std.ascii.isDigit(s[0]) or (s[0] == '-' and s.len > 1 and std.ascii.isDigit(s[1]))) {
        // A number literal alone: `1`, `-2`, `0.5`, `1e3`.
        var i: usize = if (s[0] == '-') 1 else 0;
        var is_float = false;
        while (i < s.len and (std.ascii.isAlphanumeric(s[i]) or s[i] == '.' or s[i] == '_')) : (i += 1) {
            if (s[i] == '.' or s[i] == 'e') is_float = true;
        }
        const tail = std.mem.trim(u8, s[i..], " \t\r");
        if (tail.len != 0 and !std.mem.startsWith(u8, tail, "--")) return false;
        if (std.mem.startsWith(u8, s, "0x") or std.mem.startsWith(u8, s, "0b") or std.mem.startsWith(u8, s, "0o")) is_float = false;
        if (std.mem.eql(u8, type_name, "int")) return !is_float;
        if (std.mem.eql(u8, type_name, "float")) return is_float;
    }
    return false;
}

const t = std.testing;

test "Quick fixes for the hints of the server." {
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var text: []const u8 = "use os\nuse math\nprint(1)\n";
    const start = std.mem.indexOf(u8, text, "use math").?;
    var fix = (try quickFix(arena, text, start, start + 8, code_unused_use)).?;
    try t.expectEqualStrings("use math\n", text[fix.start..fix.end]);
    try t.expectEqualStrings("", fix.new_text);

    text = "x := 1\n";
    fix = (try quickFix(arena, text, 0, 1, code_unused_local)).?;
    try t.expectEqual(@as(usize, 0), fix.end);
    try t.expectEqualStrings("_", fix.new_text);

    // A compile error has no code. Its fix comes from the compiler.
    try t.expect((try quickFix(arena, text, 0, 1, "")) == null);
}

test "The doc comment above a declaration." {
    const src = "--| Adds two numbers.\n--| Returns the sum.\n#[bind]\nfn add(a int, b int) -> int\n\nfn other():\n  pass\n";
    const doc = try docComment(t.allocator, src, std.mem.indexOf(u8, src, "fn add").?);
    defer t.allocator.free(doc);
    try t.expectEqualStrings("Adds two numbers.\nReturns the sum.", doc);
    try t.expectEqualStrings("", try docComment(t.allocator, src, std.mem.indexOf(u8, src, "fn other").?));
}

test "A type hint is left out when the initializer already names the type." {
    try t.expect(typeIsWritten(" Vec2{x = 1}", "Vec2"));
    try t.expect(typeIsWritten("Vec2.zero()", "Vec2"));
    try t.expect(typeIsWritten("'abc'", "str"));
    try t.expect(typeIsWritten("10", "int"));
    try t.expect(typeIsWritten("1.5", "float"));
    try t.expect(typeIsWritten("true", "bool"));
    try t.expect(!typeIsWritten("1 + 2", "int"));
    try t.expect(!typeIsWritten("trueish()", "bool"));
    try t.expect(!typeIsWritten("make()", "Vec2"));
    try t.expect(typeIsWritten("fn() -> int:", "OpaqueFunc[fn() -> int]"));
}

/// The offsets of the identifiers `name` in `text`, from the tokenizer: not the words in comments and strings,
/// but the names in the expressions of an interpolated string. Null if the text does not tokenize.
pub fn identsNamed(alloc: std.mem.Allocator, text: []const u8, name: []const u8) !?[]u32 {
    var tokenizer = cy.Tokenizer.init(alloc, text);
    defer tokenizer.deinit();
    // Not `ignoreErrors`: with it an unterminated string makes tokens without end.
    tokenizer.tokenize() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    if (tokenizer.has_error) return null;
    var out: std.ArrayList(u32) = .empty;
    errdefer out.deinit(alloc);
    for (tokenizer.tokens.items) |token| {
        if (token.tag() != .ident) continue;
        const pos = token.pos();
        if (token.data.end > text.len or !std.mem.eql(u8, text[pos..token.data.end], name)) continue;
        try out.append(alloc, pos);
    }
    return try out.toOwnedSlice(alloc);
}

test identsNamed {
    const alloc = std.testing.allocator;
    const text =
        \\-- twice in a comment
        \\fn twice(n int) -> int:
        \\    return n * 2
        \\print('twice %{twice(2)}')
        \\print(twice2)
        \\
    ;
    const found = (try identsNamed(alloc, text, "twice")).?;
    defer alloc.free(found);
    try std.testing.expectEqual(@as(usize, 2), found.len);
    try std.testing.expectEqual(std.mem.find(u8, text, "twice(n").?, found[0]);
    try std.testing.expectEqual(std.mem.find(u8, text, "twice(2)").?, found[1]);

    // A source that does not tokenize.
    try std.testing.expect((try identsNamed(alloc, "print('twice)\n", "twice")) == null);
}
