//! Positions of the Language Server Protocol and byte offsets of the compiler.
//! The compiler reports byte offsets. A client counts the characters of a line in UTF-16 code units
//! unless it agreed to `utf-8` in `initialize`.

const std = @import("std");

pub const Encoding = enum {
    utf8,
    utf16,

    pub fn name(self: Encoding) []const u8 {
        return switch (self) {
            .utf8 => "utf-8",
            .utf16 => "utf-16",
        };
    }
};

pub const Position = struct {
    line: u32,
    character: u32,
};

/// Lines end at `\n`, like the compiler counts them. The `\r` of a `\r\n` is the last character of its line.
pub fn fromOffset(src: []const u8, offset: usize, enc: Encoding) Position {
    const end = @min(offset, src.len);
    var line: u32 = 0;
    var line_start: usize = 0;
    for (src[0..end], 0..) |ch, i| {
        if (ch == '\n') {
            line += 1;
            line_start = i + 1;
        }
    }
    return .{ .line = line, .character = units(src[line_start..end], enc) };
}

/// A position past the end of its line is the end of the line, and a line past the end is the end of the source.
pub fn toOffset(src: []const u8, pos: Position, enc: Encoding) usize {
    var line_start: usize = 0;
    var line: u32 = 0;
    while (line < pos.line) : (line += 1) {
        const nl = std.mem.findScalarPos(u8, src, line_start, '\n') orelse return src.len;
        line_start = nl + 1;
    }
    const line_end = std.mem.findScalarPos(u8, src, line_start, '\n') orelse src.len;
    const text = src[line_start..line_end];
    switch (enc) {
        .utf8 => return line_start + @min(pos.character, text.len),
        .utf16 => {
            var i: usize = 0;
            var n: u32 = 0;
            while (i < text.len and n < pos.character) {
                const len = seqLen(text[i..]);
                n += if (len == 4) 2 else 1;
                i += len;
            }
            return line_start + i;
        },
    }
}

/// The length of `text` in the units of `enc`.
pub fn units(text: []const u8, enc: Encoding) u32 {
    switch (enc) {
        .utf8 => return @intCast(text.len),
        .utf16 => {
            var i: usize = 0;
            var n: u32 = 0;
            while (i < text.len) {
                const len = seqLen(text[i..]);
                // A code point outside the basic plane is a surrogate pair.
                n += if (len == 4) 2 else 1;
                i += len;
            }
            return n;
        },
    }
}

/// Bytes of the code point at the start of `text`. An invalid byte counts as one character.
fn seqLen(text: []const u8) usize {
    const len = std.unicode.utf8ByteSequenceLength(text[0]) catch return 1;
    if (len > text.len) return 1;
    return len;
}

test "Positions count UTF-16 code units or bytes." {
    const src = "a := 1\nx := '한글😀' + b\r\nlast";
    const b = std.mem.find(u8, src, "b").?;
    try std.testing.expectEqual(Position{ .line = 0, .character = 3 }, fromOffset(src, 3, .utf16));
    // `한글` is 6 bytes and 2 units, the emoji is 4 bytes and 2 units.
    try std.testing.expectEqual(Position{ .line = 1, .character = 14 }, fromOffset(src, b, .utf16));
    try std.testing.expectEqual(Position{ .line = 1, .character = 20 }, fromOffset(src, b, .utf8));
    try std.testing.expectEqual(Position{ .line = 2, .character = 4 }, fromOffset(src, src.len + 10, .utf16));

    try std.testing.expectEqual(b, toOffset(src, .{ .line = 1, .character = 14 }, .utf16));
    try std.testing.expectEqual(b, toOffset(src, .{ .line = 1, .character = 20 }, .utf8));
    // Past the end of the line and past the last line.
    try std.testing.expectEqual(@as(usize, 6), toOffset(src, .{ .line = 0, .character = 99 }, .utf16));
    try std.testing.expectEqual(src.len, toOffset(src, .{ .line = 9, .character = 0 }, .utf16));
}
