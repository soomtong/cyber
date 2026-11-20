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
    // Not `ignoreErrors`: a rename is refused for a source that does not tokenize.
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

/// Whether `decl`, the text of a declaration, is the type alias `type name = target` (also with template
/// parameters). False if the text does not tokenize.
pub fn isTypeAlias(alloc: std.mem.Allocator, decl: []const u8, name: []const u8) !bool {
    var tokenizer = cy.Tokenizer.init(alloc, decl);
    defer tokenizer.deinit();
    tokenizer.tokenize() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    if (tokenizer.has_error) return false;
    const tokens = tokenizer.tokens.items;
    // Attributes can come before `type`.
    var i: usize = 0;
    while (i < tokens.len and tokens[i].tag() != .type_k) i += 1;
    i += 1;
    if (i >= tokens.len or tokens[i].tag() != .ident) return false;
    if (tokens[i].data.end > decl.len or !std.mem.eql(u8, decl[tokens[i].pos()..tokens[i].data.end], name)) return false;
    i += 1;
    if (i < tokens.len and tokens[i].tag() == .left_bracket) {
        var depth: usize = 0;
        while (i < tokens.len) : (i += 1) {
            if (tokens[i].tag() == .left_bracket) depth += 1;
            if (tokens[i].tag() == .right_bracket) {
                depth -= 1;
                if (depth == 0) break;
            }
        }
        i += 1;
    }
    return i < tokens.len and tokens[i].tag() == .equal;
}

test isTypeAlias {
    const alloc = std.testing.allocator;
    try std.testing.expect(try isTypeAlias(alloc, "type Alias = lib.Foo", "Alias"));
    try std.testing.expect(try isTypeAlias(alloc, "type Pair[T Any] = Tuple[T, T]", "Pair"));
    try std.testing.expect(try isTypeAlias(alloc, "type Op = fn(int) -> int", "Op"));
    try std.testing.expect(!try isTypeAlias(alloc, "type Foo:\n    n int\n", "Foo"));
    try std.testing.expect(!try isTypeAlias(alloc, "type Color enum:\n    case red\n", "Color"));
    try std.testing.expect(!try isTypeAlias(alloc, "fn twice(n int) -> int:\n    return n * 2\n", "twice"));
    // Another name than the one of the declaration.
    try std.testing.expect(!try isTypeAlias(alloc, "type Alias = lib.Foo", "Foo"));
}

/// An edit that replaces `text[start..end]` of the old text with `new_text`, a slice of the new text.
pub const LineEdit = struct {
    start: usize,
    end: usize,
    new_text: []const u8,
};

/// The edits that turn the lines `first`..`last` (0-based, inclusive) of `old` into the formatted `new`, one edit
/// per line that differs. The formatter never joins or splits a line (`format.zig`): it changes what is in a line
/// and drops blank lines (a run of them becomes one, those at the start and the end go). So the lines of `new`
/// are those of `old` in order, less some blank ones. A line break is not part of a line and `\r` before it is
/// left as it is. A dropped line is deleted with its line break. What follows the last line break of `new` is
/// not a line when it is empty, so every blank line at the end of `old` is dropped, and a last line of `old`
/// without a line break gets the one of `new`: the edits of every line give `new`, like a format of the whole
/// document. Null if `new` is not such a copy of `old`.
pub fn lineEdits(alloc: std.mem.Allocator, old: []const u8, new: []const u8, first: usize, last: usize) !?[]LineEdit {
    var old_lines = std.mem.splitScalar(u8, old, '\n');
    var new_lines: NewLines = .{ .iter = std.mem.splitScalar(u8, new, '\n') };
    var out: std.ArrayList(LineEdit) = .empty;
    // Also when the lines do not match.
    defer out.deinit(alloc);
    var new_line = new_lines.next();
    var line: usize = 0;
    while (old_lines.next()) |old_line| : (line += 1) {
        const line_start = if (old_lines.index) |next| next - old_line.len - 1 else old.len - old_line.len;
        const line_end = old_lines.index orelse old.len;
        const in_range = line >= first and line <= last;
        const old_text = std.mem.trimEnd(u8, old_line, "\r");
        const old_blank = std.mem.trim(u8, old_text, " \t").len == 0;
        const dropped = old_blank and (new_line == null or std.mem.trim(u8, new_line.?, " \t\r").len != 0);
        if (dropped) {
            // The empty end of the text after its last line break has nothing to delete.
            if (in_range and line_end > line_start) try out.append(alloc, .{ .start = line_start, .end = line_end, .new_text = "" });
            continue;
        }
        const new_raw = new_line orelse return null;
        const new_text = std.mem.trimEnd(u8, new_raw, "\r");
        // The last line of `old` has no line break and its line in `new` has one.
        const adds_break = old_lines.index == null and new_lines.has_break;
        new_line = new_lines.next();
        if (!in_range) continue;
        if (adds_break) {
            const at = @intFromPtr(new_raw.ptr) - @intFromPtr(new.ptr);
            try out.append(alloc, .{ .start = line_start, .end = line_end, .new_text = new[at .. at + new_raw.len + 1] });
        } else if (!std.mem.eql(u8, old_text, new_text)) {
            try out.append(alloc, .{ .start = line_start, .end = line_start + old_text.len, .new_text = new_text });
        }
    }
    if (new_line != null) return null;
    return try out.toOwnedSlice(alloc);
}

/// The lines of the formatted text. The empty text after its last line break is not a line.
const NewLines = struct {
    iter: std.mem.SplitIterator(u8, .scalar),
    /// Whether a line break follows the line that `next` returned last.
    has_break: bool = false,

    fn next(self: *NewLines) ?[]const u8 {
        const line = self.iter.next() orelse return null;
        self.has_break = self.iter.index != null;
        if (!self.has_break and line.len == 0) return null;
        return line;
    }
};

test lineEdits {
    const alloc = std.testing.allocator;
    const old = "fn add(a int,b int)->int:\r\n  return a+b\n\nprint(add(1,2))";
    const new = "fn add(a int, b int) -> int:\r\n    return a + b\n\nprint(add(1, 2))\n";

    const all = (try lineEdits(alloc, old, new, 0, 100)).?;
    defer alloc.free(all);
    try std.testing.expectEqual(@as(usize, 3), all.len);
    // The `\r` of the first line stays.
    try std.testing.expectEqualStrings("fn add(a int,b int)->int:", old[all[0].start..all[0].end]);
    try std.testing.expectEqualStrings("fn add(a int, b int) -> int:", all[0].new_text);
    try std.testing.expectEqualStrings("  return a+b", old[all[1].start..all[1].end]);
    try std.testing.expectEqualStrings("    return a + b", all[1].new_text);
    try std.testing.expectEqualStrings("print(add(1,2))", old[all[2].start..all[2].end]);

    // Only the lines of the range.
    const some = (try lineEdits(alloc, old, new, 1, 2)).?;
    defer alloc.free(some);
    try std.testing.expectEqual(@as(usize, 1), some.len);
    try std.testing.expectEqualStrings("    return a + b", some[0].new_text);

    // Blank lines that the formatter dropped: a run of them becomes one, those at the start go.
    const blank = "\n\nx=1\n\n  \n\ny=2\n";
    const dropped = (try lineEdits(alloc, blank, "x = 1\n\ny = 2\n", 0, 100)).?;
    defer alloc.free(dropped);
    try std.testing.expectEqual(@as(usize, 6), dropped.len);
    try std.testing.expectEqualStrings("\n", blank[dropped[0].start..dropped[0].end]);
    try std.testing.expectEqual(@as(usize, 1), dropped[1].start);
    try std.testing.expectEqualStrings("x = 1", dropped[2].new_text);
    // The first blank line after `x=1` stays, the next two go.
    try std.testing.expectEqualStrings("  \n", blank[dropped[3].start..dropped[3].end]);
    try std.testing.expectEqualStrings("\n", blank[dropped[4].start..dropped[4].end]);
    try std.testing.expectEqual(blank.len - "\ny=2\n".len, dropped[4].start);
    try std.testing.expectEqualStrings("y = 2", dropped[5].new_text);

    // The edits of every line give the output: the blank lines at the end go, and a last line without a line
    // break gets one.
    const cases = [_][2][]const u8{
        .{ "x=1\n\n\n", "x = 1\n" },
        .{ "x=1\n\n  ", "x = 1\n" },
        .{ "x=1\n", "x = 1\n" },
        .{ "x=1", "x = 1\n" },
        .{ "x = 1", "x = 1\n" },
        .{ "x=1\r\n\r\n", "x = 1\r\n" },
        .{ "\n\n", "" },
        .{ "  ", "" },
        .{ "", "" },
        .{ blank, "x = 1\n\ny = 2\n" },
        .{ old, new },
    };
    for (cases) |case| {
        const edits = (try lineEdits(alloc, case[0], case[1], 0, 100)).?;
        defer alloc.free(edits);
        var applied: std.ArrayList(u8) = .empty;
        defer applied.deinit(alloc);
        var at: usize = 0;
        for (edits) |edit| {
            try std.testing.expect(edit.start >= at and edit.end >= edit.start);
            // An edit changes something.
            try std.testing.expect(!std.mem.eql(u8, case[0][edit.start..edit.end], edit.new_text));
            try applied.appendSlice(alloc, case[0][at..edit.start]);
            try applied.appendSlice(alloc, edit.new_text);
            at = edit.end;
        }
        try applied.appendSlice(alloc, case[0][at..]);
        try std.testing.expectEqualStrings(case[1], applied.items);
    }
    // A range that leaves out the last line leaves the end as it is.
    const head = (try lineEdits(alloc, "x=1\ny=2", "x = 1\ny = 2\n", 0, 0)).?;
    defer alloc.free(head);
    try std.testing.expectEqual(@as(usize, 1), head.len);
    try std.testing.expectEqualStrings("x = 1", head[0].new_text);

    // Lines that do not match.
    try std.testing.expect((try lineEdits(alloc, "a\nb\nc", "a\nb", 0, 1)) == null);
    try std.testing.expect((try lineEdits(alloc, "a\nb", "a\nb\nc", 0, 1)) == null);
}
