//! Completion and signature help ask about source that is being typed, which usually does not parse:
//! `x := v.` or `add(1, `. The compiler stops at a syntax error, so the server compiles a copy that is patched
//! around the cursor until it parses, and asks the compiler about that copy.
//!
//! The patches are tried in order, from the one that changes the least:
//!
//!   0. Only the word at the cursor is touched. `v.le|n` becomes `v`, an empty place gets a placeholder name.
//!   1. The rest of the line after the cursor is dropped and the brackets opened on the line are closed.
//!   2. The line is replaced by the receiver (or the placeholder) alone.
//!
//! This is text surgery, not parsing. A cursor inside a string or a comment is not recognized, and a line that
//! opens a block can not be replaced. See docs/specs/2026-11-12-lsp-design.md.

const std = @import("std");

/// A name that no script declares. It parses as an expression where a name is expected.
pub const placeholder = "cy_lsp_placeholder_";

pub const num_attempts = 3;

pub const Kind = enum {
    /// After `expr.`: the members of `expr`.
    member,
    /// Anywhere else: the names in scope.
    scope,
};

pub const Patch = struct {
    kind: Kind,
    /// The source to compile. Owned by the caller.
    text: []u8,
    /// Where to ask in `text`: the end of the receiver for `member`, the place of the name for `scope`.
    pos: usize,
};

fn isIdent(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

fn wordStart(text: []const u8, offset: usize) usize {
    var i = offset;
    while (i > 0 and isIdent(text[i - 1])) i -= 1;
    return i;
}

fn wordEnd(text: []const u8, offset: usize) usize {
    var i = offset;
    while (i < text.len and isIdent(text[i])) i += 1;
    return i;
}

fn lineStart(text: []const u8, offset: usize) usize {
    return if (std.mem.findScalarLast(u8, text[0..offset], '\n')) |nl| nl + 1 else 0;
}

fn lineEnd(text: []const u8, offset: usize) usize {
    return std.mem.findScalarPos(u8, text, offset, '\n') orelse text.len;
}

/// The closing brackets for the ones that `text` opens and does not close, innermost first.
fn appendClosers(alloc: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    var stack: std.ArrayList(u8) = .empty;
    defer stack.deinit(alloc);
    for (text) |ch| {
        switch (ch) {
            '(' => try stack.append(alloc, ')'),
            '[' => try stack.append(alloc, ']'),
            '{' => try stack.append(alloc, '}'),
            ')', ']', '}' => {
                if (stack.items.len > 0 and stack.items[stack.items.len - 1] == ch) _ = stack.pop();
            },
            else => {},
        }
    }
    while (stack.pop()) |ch| try out.append(alloc, ch);
}

/// The start of the receiver that ends at `end`: names, `.`, and call or index brackets with what is in them.
/// `self.items[i + 1].name` is one receiver, `a + b.c` gives `b.c`.
fn receiverStart(text: []const u8, end: usize) usize {
    var i = end;
    while (i > 0) {
        const ch = text[i - 1];
        if (isIdent(ch) or ch == '.') {
            i -= 1;
        } else if (ch == ')' or ch == ']') {
            // Back to the bracket that opens this one.
            var depth: usize = 0;
            var j = i;
            while (j > 0) {
                j -= 1;
                switch (text[j]) {
                    ')', ']' => depth += 1,
                    '(', '[' => {
                        depth -= 1;
                        if (depth == 0) break;
                    },
                    '\n' => return i,
                    else => {},
                }
            } else return i;
            if (depth != 0) return i;
            i = j;
        } else break;
    }
    return i;
}

/// The source patched for a completion at `offset`. Null if `attempt` has nothing to try here.
pub fn patchCompletion(alloc: std.mem.Allocator, text: []const u8, offset_: usize, attempt: usize) !?Patch {
    const offset = @min(offset_, text.len);
    const start = wordStart(text, offset);
    const end = wordEnd(text, offset);
    const kind: Kind = if (start > 0 and text[start - 1] == '.') .member else .scope;
    // A number is not a name: `1.` and `12|` complete nothing.
    if (kind == .scope and start < offset and std.ascii.isDigit(text[start])) return null;
    if (kind == .member) {
        const rec_start = wordStart(text, start - 1);
        if (rec_start < start - 1 and std.ascii.isDigit(text[rec_start])) return null;
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var pos: usize = undefined;
    switch (attempt) {
        0 => switch (kind) {
            .member => {
                // Without the `.` and the member, the receiver is an expression of its own.
                try out.appendSlice(alloc, text[0 .. start - 1]);
                pos = out.items.len;
                try out.appendSlice(alloc, text[end..]);
            },
            .scope => {
                try out.appendSlice(alloc, text[0..start]);
                pos = out.items.len;
                if (start == end) {
                    try out.appendSlice(alloc, placeholder);
                } else {
                    try out.appendSlice(alloc, text[start..end]);
                }
                try out.appendSlice(alloc, text[end..]);
            },
        },
        1 => {
            const line_start = lineStart(text, offset);
            const head_end = if (kind == .member) start - 1 else start;
            try out.appendSlice(alloc, text[0..head_end]);
            pos = out.items.len;
            if (kind == .scope) {
                try out.appendSlice(alloc, if (start == offset) placeholder else text[start..offset]);
            }
            try appendClosers(alloc, &out, text[line_start..head_end]);
            try out.appendSlice(alloc, text[lineEnd(text, offset)..]);
        },
        2 => {
            const line_start = lineStart(text, offset);
            var indent = line_start;
            while (indent < text.len and (text[indent] == ' ' or text[indent] == '\t')) indent += 1;
            try out.appendSlice(alloc, text[0..@min(indent, start)]);
            switch (kind) {
                .member => {
                    const rec_start = @max(receiverStart(text, start - 1), line_start);
                    if (rec_start >= start - 1) {
                        out.deinit(alloc);
                        return null;
                    }
                    try out.appendSlice(alloc, text[rec_start .. start - 1]);
                    pos = out.items.len;
                },
                .scope => {
                    pos = out.items.len;
                    try out.appendSlice(alloc, if (start == offset) placeholder else text[start..offset]);
                },
            }
            try out.appendSlice(alloc, text[lineEnd(text, offset)..]);
        },
        else => return null,
    }
    return .{ .kind = kind, .text = try out.toOwnedSlice(alloc), .pos = pos };
}

pub const Call = struct {
    /// The end of the name that is called: the offset of its `(`.
    callee_end: usize,
    /// The argument that the cursor is in, counted from 0.
    arg: u32,
};

/// The call whose arguments the cursor at `offset` is in. Null if it is not inside the brackets of a call.
pub fn enclosingCall(text: []const u8, offset_: usize) ?Call {
    const offset = @min(offset_, text.len);
    var depth: usize = 0;
    var commas: u32 = 0;
    var i = offset;
    // A call is not looked for further back than this.
    const limit = offset -| 4000;
    while (i > limit) {
        i -= 1;
        switch (text[i]) {
            ')', ']', '}' => depth += 1,
            '[', '{' => {
                // The cursor is inside a literal or an index, not directly in a call.
                if (depth == 0) return null;
                depth -= 1;
            },
            '(' => {
                if (depth == 0) {
                    if (i == 0 or !isIdent(text[i - 1])) return null;
                    return .{ .callee_end = i, .arg = commas };
                }
                depth -= 1;
            },
            ',' => {
                if (depth == 0) commas += 1;
            },
            else => {},
        }
    }
    return null;
}

/// The source patched so that the call around `offset` parses. Attempt 0 is the source as it is.
/// The caller owns the result. The offsets before `offset` stay the same in every attempt.
pub fn patchCall(alloc: std.mem.Allocator, text: []const u8, offset_: usize, call: Call, attempt: usize) !?[]u8 {
    const offset = @min(offset_, text.len);
    switch (attempt) {
        0 => return try alloc.dupe(u8, text),
        1 => {
            // The arguments typed so far, a placeholder for the one that is missing, and the closing brackets.
            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(alloc);
            try out.appendSlice(alloc, text[0..offset]);
            const typed = std.mem.trimEnd(u8, text[call.callee_end..offset], " \t\r\n");
            if (std.mem.endsWith(u8, typed, ",")) {
                try out.appendSlice(alloc, " " ++ placeholder);
            }
            // The call can be an argument of another one: everything opened on its line is closed.
            try appendClosers(alloc, &out, text[lineStart(text, call.callee_end)..offset]);
            try out.appendSlice(alloc, text[lineEnd(text, offset)..]);
            return try out.toOwnedSlice(alloc);
        },
        else => return null,
    }
}

pub const Param = struct {
    start: usize,
    end: usize,
};

/// The parameters in the header of a function, as ranges of `label`: `fn add(a int, b int) -> int` has
/// `a int` and `b int`. The receiver of a method (`fn (&Vec2) len()`) is not a parameter of the call.
pub fn signatureParams(alloc: std.mem.Allocator, label: []const u8) ![]Param {
    var out: std.ArrayList(Param) = .empty;
    errdefer out.deinit(alloc);

    var i: usize = 0;
    if (std.mem.startsWith(u8, label, "fn (")) {
        i = (matching(label, 3) orelse return out.toOwnedSlice(alloc)) + 1;
    }
    const open = std.mem.findScalarPos(u8, label, i, '(') orelse return out.toOwnedSlice(alloc);
    const close = matching(label, open) orelse return out.toOwnedSlice(alloc);

    var depth: usize = 0;
    var start = open + 1;
    i = open + 1;
    while (i <= close) : (i += 1) {
        const ch = label[i];
        if (i == close or (ch == ',' and depth == 0)) {
            var s = start;
            var e = i;
            while (s < e and label[s] == ' ') s += 1;
            while (e > s and label[e - 1] == ' ') e -= 1;
            if (e > s) try out.append(alloc, .{ .start = s, .end = e });
            start = i + 1;
        } else switch (ch) {
            '(', '[', '{' => depth += 1,
            ')', ']', '}' => depth -|= 1,
            else => {},
        }
    }
    return out.toOwnedSlice(alloc);
}

/// The bracket that closes the one at `open`.
fn matching(text: []const u8, open: usize) ?usize {
    var depth: usize = 0;
    var i = open;
    while (i < text.len) : (i += 1) {
        switch (text[i]) {
            '(', '[', '{' => depth += 1,
            ')', ']', '}' => {
                depth -= 1;
                if (depth == 0) return i;
            },
            else => {},
        }
    }
    return null;
}

fn expectPatch(text: []const u8, attempt: usize, kind: Kind, expected: []const u8) !void {
    const t = std.testing;
    // `|` marks the cursor in `text` and the place to ask in `expected`.
    const offset = std.mem.findScalar(u8, text, '|').?;
    const src = try std.mem.concat(t.allocator, u8, &.{ text[0..offset], text[offset + 1 ..] });
    defer t.allocator.free(src);
    const patch = (try patchCompletion(t.allocator, src, offset, attempt)).?;
    defer t.allocator.free(patch.text);
    const marked = try std.mem.concat(t.allocator, u8, &.{ patch.text[0..patch.pos], "|", patch.text[patch.pos..] });
    defer t.allocator.free(marked);
    try t.expectEqual(kind, patch.kind);
    try t.expectEqualStrings(expected, marked);
}

test "A completion is asked on source that is patched around the cursor." {
    const t = std.testing;
    const p = placeholder;

    // The word at the cursor: the member is taken out, an empty place gets a name.
    try expectPatch("x := v.|\ny := 1", 0, .member, "x := v|\ny := 1");
    try expectPatch("print(v.le|n())", 0, .member, "print(v|())");
    try expectPatch("x := |\n", 0, .scope, "x := |" ++ p ++ "\n");
    try expectPatch("x := pri|nt", 0, .scope, "x := |print");
    try expectPatch("|", 0, .scope, "|" ++ p);

    // The rest of the line is dropped and the brackets are closed.
    try expectPatch("print(add(v.|, 2 +\ny := 1", 1, .member, "print(add(v|))\ny := 1");
    try expectPatch("a := [1, f(|\n", 1, .scope, "a := [1, f(|" ++ p ++ ")]\n");
    try expectPatch("a := to|tal +\n", 1, .scope, "a := |to\n");

    // The line is replaced by the receiver or the name.
    try expectPatch("    if self.items[i + 1].na|\n    pass", 2, .member, "    self.items[i + 1]|\n    pass");
    try expectPatch("  return a + b.c.| )", 2, .member, "  b.c|");
    try expectPatch("    while to|\n", 2, .scope, "    |to\n");
    try expectPatch("    if |\n", 2, .scope, "    |" ++ p ++ "\n");

    // Nothing to complete after a number, and no receiver to keep.
    try t.expectEqual(@as(?Patch, null), try patchCompletion(t.allocator, "x := 12", 7, 0));
    try t.expectEqual(@as(?Patch, null), try patchCompletion(t.allocator, "x := 1.", 7, 0));
    try t.expectEqual(@as(?Patch, null), try patchCompletion(t.allocator, "x := (.", 7, 2));
    try t.expectEqual(@as(?Patch, null), try patchCompletion(t.allocator, "x := v.", 7, 3));
    // A name that ends in a digit is still a name.
    const patch = (try patchCompletion(t.allocator, "x := v2.", 8, 0)).?;
    defer t.allocator.free(patch.text);
    try t.expectEqualStrings("x := v2", patch.text);
}

test "The call around the cursor and the parameters of a signature." {
    const t = std.testing;

    const src = "x := add(1, mul(2, 3), [4, 5], ";
    var call = enclosingCall(src, src.len).?;
    try t.expectEqualStrings("add", src[call.callee_end - 3 .. call.callee_end]);
    try t.expectEqual(@as(u32, 3), call.arg);
    // Inside the inner call.
    call = enclosingCall(src, std.mem.find(u8, src, "3").?).?;
    try t.expectEqualStrings("mul", src[call.callee_end - 3 .. call.callee_end]);
    try t.expectEqual(@as(u32, 1), call.arg);
    call = enclosingCall("v.len(", 6).?;
    try t.expectEqual(@as(usize, 5), call.callee_end);
    try t.expectEqual(@as(u32, 0), call.arg);
    // Not in a call: outside of brackets, in a group, in a literal.
    try t.expectEqual(@as(?Call, null), enclosingCall("x := 1 + ", 9));
    try t.expectEqual(@as(?Call, null), enclosingCall("x := (1 + ", 10));
    try t.expectEqual(@as(?Call, null), enclosingCall("f([1, ", 6));

    call = enclosingCall(src, src.len).?;
    const patched = (try patchCall(t.allocator, src ++ "\ny := 1", src.len, call, 1)).?;
    defer t.allocator.free(patched);
    try t.expectEqualStrings("x := add(1, mul(2, 3), [4, 5],  " ++ placeholder ++ ")\ny := 1", patched);
    const open = (try patchCall(t.allocator, "add(", 4, .{ .callee_end = 3, .arg = 0 }, 1)).?;
    defer t.allocator.free(open);
    try t.expectEqualStrings("add()", open);
    const nested = (try patchCall(t.allocator, "n := add(1, mul(", 16, .{ .callee_end = 15, .arg = 0 }, 1)).?;
    defer t.allocator.free(nested);
    try t.expectEqualStrings("n := add(1, mul())", nested);

    const label = "fn add(a int, b Map[str, int], f fn(int, int) -> int) -> int";
    const params = try signatureParams(t.allocator, label);
    defer t.allocator.free(params);
    try t.expectEqual(@as(usize, 3), params.len);
    try t.expectEqualStrings("a int", label[params[0].start..params[0].end]);
    try t.expectEqualStrings("b Map[str, int]", label[params[1].start..params[1].end]);
    try t.expectEqualStrings("f fn(int, int) -> int", label[params[2].start..params[2].end]);

    // The receiver of a method is not an argument of the call.
    const method = "fn (&Vec2) scale(by float) -> Vec2";
    const method_params = try signatureParams(t.allocator, method);
    defer t.allocator.free(method_params);
    try t.expectEqual(@as(usize, 1), method_params.len);
    try t.expectEqualStrings("by float", method[method_params[0].start..method_params[0].end]);

    const none = try signatureParams(t.allocator, "fn now() -> int");
    defer t.allocator.free(none);
    try t.expectEqual(@as(usize, 0), none.len);
}
