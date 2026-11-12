//! The base protocol: messages framed by a `Content-Length` header, read from stdin and written to stdout.

const std = @import("std");
const builtin = @import("builtin");
const stdx = @import("stdx");

pub const max_message_size = 1 << 26;

pub const Frame = struct {
    body_start: usize,
    body_end: usize,
};

pub const FrameError = error{
    /// The header has no usable `Content-Length`. The stream can not be read any further.
    BadHeader,
    MessageTooLarge,
};

/// Finds the first message in `buf`. Returns null if it is not complete yet.
pub fn parseFrame(buf: []const u8) FrameError!?Frame {
    const header_end = std.mem.find(u8, buf, "\r\n\r\n") orelse {
        if (buf.len > 4096) return error.BadHeader;
        return null;
    };
    var len: ?usize = null;
    var lines = std.mem.splitSequence(u8, buf[0..header_end], "\r\n");
    while (lines.next()) |line| {
        const colon = std.mem.findScalar(u8, line, ':') orelse return error.BadHeader;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        if (std.ascii.eqlIgnoreCase(name, "Content-Length")) {
            const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
            len = std.fmt.parseInt(usize, value, 10) catch return error.BadHeader;
        }
    }
    const body_len = len orelse return error.BadHeader;
    if (body_len > max_message_size) return error.MessageTooLarge;
    const body_start = header_end + 4;
    if (buf.len < body_start + body_len) return null;
    return .{ .body_start = body_start, .body_end = body_start + body_len };
}

pub const Event = union(enum) {
    /// Valid until the next call to `next`.
    message: []const u8,
    /// Nothing arrived within the timeout.
    idle,
    /// The client closed the stream.
    eof,
};

pub const Reader = struct {
    alloc: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,
    /// Bytes at the start of `buf` that belong to the message returned last.
    consumed: usize = 0,

    pub fn init(alloc: std.mem.Allocator) Reader {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Reader) void {
        self.buf.deinit(self.alloc);
    }

    /// Waits for the next message. With `timeout_ms` it returns `.idle` if the client sends nothing for that long,
    /// which is when the server does the work it put off. Without a way to wait with a timeout (Windows)
    /// `.idle` is returned at once when no complete message is buffered.
    pub fn next(self: *Reader, timeout_ms: ?u32) !Event {
        if (self.consumed > 0) {
            const rest = self.buf.items.len - self.consumed;
            std.mem.copyForwards(u8, self.buf.items[0..rest], self.buf.items[self.consumed..]);
            self.buf.shrinkRetainingCapacity(rest);
            self.consumed = 0;
        }
        const io = stdx.io();
        const stdin = std.Io.File.stdin();
        while (true) {
            if (try parseFrame(self.buf.items)) |frame| {
                self.consumed = frame.body_end;
                return .{ .message = self.buf.items[frame.body_start..frame.body_end] };
            }
            if (timeout_ms) |ms| {
                if (!waitReadable(stdin, ms)) return .idle;
            }
            var chunk: [16 * 1024]u8 = undefined;
            const n = stdin.readStreaming(io, &.{&chunk}) catch |err| switch (err) {
                error.EndOfStream => return .eof,
                else => return err,
            };
            if (n == 0) return .eof;
            try self.buf.appendSlice(self.alloc, chunk[0..n]);
        }
    }
};

fn waitReadable(file: std.Io.File, timeout_ms: u32) bool {
    switch (builtin.os.tag) {
        .windows, .wasi, .freestanding => return false,
        else => {
            var fds = [_]std.posix.pollfd{.{
                .fd = file.handle,
                .events = std.posix.POLL.IN,
                .revents = 0,
            }};
            // If the wait itself fails the read decides.
            const n = std.posix.poll(&fds, @intCast(timeout_ms)) catch return true;
            return n > 0;
        },
    }
}

pub fn writeMessage(body: []const u8) !void {
    const io = stdx.io();
    const stdout = std.Io.File.stdout();
    var header_buf: [64]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf, "Content-Length: {}\r\n\r\n", .{body.len}) catch unreachable;
    try stdout.writeStreamingAll(io, header);
    try stdout.writeStreamingAll(io, body);
}

test "A frame is complete when its body has arrived." {
    const t = std.testing;
    try t.expectEqual(@as(?Frame, null), try parseFrame(""));
    try t.expectEqual(@as(?Frame, null), try parseFrame("Content-Length: 2\r\n"));
    try t.expectEqual(@as(?Frame, null), try parseFrame("Content-Length: 2\r\n\r\n{"));

    const two = "Content-Length: 2\r\n\r\n{}Content-Length: 4\r\n\r\nnull";
    const first = (try parseFrame(two)).?;
    try t.expectEqualStrings("{}", two[first.body_start..first.body_end]);
    const second = (try parseFrame(two[first.body_end..])).?;
    try t.expectEqualStrings("null", two[first.body_end..][second.body_start..second.body_end]);

    // Other headers are skipped and the name has no case.
    const typed = "Content-Type: application/vscode-jsonrpc; charset=utf-8\r\ncontent-length:  2 \r\n\r\n[]";
    const frame = (try parseFrame(typed)).?;
    try t.expectEqualStrings("[]", typed[frame.body_start..frame.body_end]);

    try t.expectError(error.BadHeader, parseFrame("Content-Type: x\r\n\r\n{}"));
    try t.expectError(error.BadHeader, parseFrame("Content-Length: two\r\n\r\n{}"));
    try t.expectError(error.BadHeader, parseFrame("no header\r\n\r\n{}"));
    try t.expectError(error.MessageTooLarge, parseFrame("Content-Length: 99999999999\r\n\r\n"));
}
