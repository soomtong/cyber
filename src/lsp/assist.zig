//! Code assists that are worked out from the text: quick fixes for diagnostics, the doc comment of a
//! declaration, and whether a type hint would only repeat the source. Pure functions with unit tests.

const std = @import("std");

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

/// The fix for a diagnostic with message `msg` and code `code` (empty for a compile error) over `text[start..end]`.
/// Null when the message names no fix that can be made from the text.
pub fn quickFix(alloc: std.mem.Allocator, text: []const u8, start: usize, end: usize, msg: []const u8, code: []const u8) !?Fix {
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
    if (code.len > 0) return null;

    // 'Did you mean `trim_left`?', 'Did you mean the method `len()`?'
    if (quoteAfter(msg, "Did you mean the method `") orelse quoteAfter(msg, "Did you mean `")) |name| {
        if (!isIdentifier(range_text)) return null;
        var new_text = name;
        // `v.len` -> `v.len()`, but not when the call is already written.
        if (std.mem.endsWith(u8, name, "()") and end < text.len and text[end] == '(') new_text = name[0 .. name.len - 2];
        if (!isIdentifier(new_text) and !(std.mem.endsWith(u8, new_text, "()") and isIdentifier(new_text[0 .. new_text.len - 2]))) return null;
        return .{
            .title = try std.fmt.allocPrint(alloc, "Change to `{s}`", .{new_text}),
            .start = start,
            .end = end,
            .new_text = try alloc.dupe(u8, new_text),
        };
    }

    // 'Can not find the symbol `read_file_str` in `os`. Use `os.read_file`. ...': the same module, another name.
    if (quoteAfter(msg, ". Use `")) |path| {
        if (!isIdentifier(range_text)) return null;
        const dot = std.mem.findScalarLast(u8, path, '.') orelse return null;
        const mod = path[0..dot];
        const member = path[dot + 1 ..];
        if (!isIdentifier(member)) return null;
        // Only when the name is written after the same module: `os.read_file_str` -> `os.read_file`.
        if (start < mod.len + 1 or !std.mem.eql(u8, text[start - mod.len - 1 .. start], path[0 .. dot + 1])) return null;
        return .{
            .title = try std.fmt.allocPrint(alloc, "Change to `{s}`", .{path}),
            .start = start,
            .end = end,
            .new_text = try alloc.dupe(u8, member),
        };
    }

    // '`append` changes `out` in place and returns nothing. Write `out.append(3)` as a statement.'
    if (std.mem.indexOf(u8, msg, "` as a statement.") != null) {
        const code_text = quoteAfter(msg, "Write `") orelse return null;
        // The line must be `<name> = <the call>` and nothing else.
        const line_start = if (std.mem.findScalarLast(u8, text[0..start], '\n')) |i| i + 1 else 0;
        const line_end = std.mem.findScalarPos(u8, text, end, '\n') orelse text.len;
        if (std.mem.trim(u8, text[end..line_end], " \t\r").len != 0) return null;
        const head = std.mem.trimStart(u8, text[line_start..start], " \t");
        const head_at = start - head.len;
        if (!std.mem.endsWith(u8, head, " = ") or !isIdentifier(head[0 .. head.len - 3])) return null;
        return .{
            .title = try std.fmt.allocPrint(alloc, "Change to `{s}`", .{code_text}),
            .start = head_at,
            .end = end,
            .new_text = try alloc.dupe(u8, code_text),
        };
    }
    return null;
}

/// The text between `prefix` and the next backtick.
fn quoteAfter(msg: []const u8, prefix: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, msg, prefix) orelse return null;
    const rest = msg[at + prefix.len ..];
    const close = std.mem.findScalar(u8, rest, '`') orelse return null;
    if (close == 0) return null;
    return rest[0..close];
}

/// The tokenizer takes ASCII letters, digits and `_` in a name.
pub fn isIdentifier(text: []const u8) bool {
    if (text.len == 0 or std.ascii.isDigit(text[0])) return false;
    for (text) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_') return false;
    }
    return true;
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

test "Quick fixes from the messages of the compiler and the hints of the server." {
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var text: []const u8 = "ok := os.fileExists('a')\n";
    var start = std.mem.indexOf(u8, text, "fileExists").?;
    var fix = (try quickFix(arena, text, start, start + 10, "Can not find the symbol `fileExists` in `os`. Did you mean `file_exists`?", "")).?;
    try t.expectEqualStrings("file_exists", fix.new_text);
    try t.expectEqual(start, fix.start);
    try t.expectEqualStrings("Change to `file_exists`", fix.title);

    text = "n := v.len\n";
    start = std.mem.indexOf(u8, text, "len").?;
    fix = (try quickFix(arena, text, start, start + 3, "Can not find the field `len` in `Vec2`. Did you mean the method `len()`?", "")).?;
    try t.expectEqualStrings("len()", fix.new_text);
    text = "n := v.len(1)\n";
    fix = (try quickFix(arena, text, start, start + 3, "Did you mean the method `len()`?", "")).?;
    try t.expectEqualStrings("len", fix.new_text);

    text = "s := os.read_file_str('a')!\n";
    start = std.mem.indexOf(u8, text, "read_file_str").?;
    fix = (try quickFix(arena, text, start, start + 13, "Can not find the symbol `read_file_str` in `os`. Use `os.read_file`. It returns `str`.", "")).?;
    try t.expectEqualStrings("read_file", fix.new_text);
    // Another module: the fix would have to change the module and the `use` too.
    text = "d := os.dirname(p)\n";
    start = std.mem.indexOf(u8, text, "dirname").?;
    try t.expect((try quickFix(arena, text, start, start + 7, "Can not find the symbol `dirname` in `os`. Use `path.dir` from `use path`.", "")) == null);

    text = "fn f():\n    out = out.append(3)\n";
    start = std.mem.indexOf(u8, text, "out.append").?;
    fix = (try quickFix(arena, text, start, start + 13, "`append` changes `out` in place and returns nothing. Write `out.append(3)` as a statement.", "")).?;
    try t.expectEqualStrings("out.append(3)", fix.new_text);
    try t.expectEqualStrings("out = out.append(3)", text[fix.start..fix.end]);

    text = "use os\nuse math\nprint(1)\n";
    start = std.mem.indexOf(u8, text, "use math").?;
    fix = (try quickFix(arena, text, start, start + 8, "The module `math` is never used.", code_unused_use)).?;
    try t.expectEqualStrings("use math\n", text[fix.start..fix.end]);
    try t.expectEqualStrings("", fix.new_text);

    text = "x := 1\n";
    fix = (try quickFix(arena, text, 0, 1, "`x` is never used.", code_unused_local)).?;
    try t.expectEqual(@as(usize, 0), fix.end);
    try t.expectEqualStrings("_", fix.new_text);

    try t.expect((try quickFix(arena, text, 0, 1, "Undeclared variable `x`.", "")) == null);
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
