// Copied only what is used from the cosmic project.
// TODO: Remove this package.

const std = @import("std");
const builtin = @import("builtin");

pub const testing = @import("testing.zig");

pub const time = @import("time.zig");
pub const heap = @import("heap.zig");

pub const stack = @import("ds/stack.zig");
pub const Stack = stack.Stack;

pub const debug = @import("debug.zig");

/// Process-wide `Io` for code reached through the C API, where no `Io` is passed down.
/// Blocking and without task-level concurrency, like the std I/O before Zig 0.16.
pub fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

/// Appends to an unmanaged byte `ArrayList` of any alignment.
/// Keeps the call surface of `ArrayList.writer()`, which Zig 0.16 removed.
pub fn ListWriter(comptime List: type) type {
    return struct {
        list: *List,
        alloc: std.mem.Allocator,

        pub const Error = std.mem.Allocator.Error;

        pub fn print(self: @This(), comptime fmt: []const u8, args: anytype) Error!void {
            const len = std.fmt.count(fmt, args);
            try self.list.ensureUnusedCapacity(self.alloc, len);
            _ = std.fmt.bufPrint(self.list.unusedCapacitySlice(), fmt, args) catch unreachable;
            self.list.items.len += len;
        }

        pub fn writeAll(self: @This(), bytes: []const u8) Error!void {
            try self.list.appendSlice(self.alloc, bytes);
        }

        pub fn write(self: @This(), bytes: []const u8) Error!usize {
            try self.list.appendSlice(self.alloc, bytes);
            return bytes.len;
        }

        pub fn writeByte(self: @This(), byte: u8) Error!void {
            try self.list.append(self.alloc, byte);
        }

        pub fn writeByteNTimes(self: @This(), byte: u8, n: usize) Error!void {
            try self.list.appendNTimes(self.alloc, byte, n);
        }
    };
}

pub fn listWriter(list: anytype, alloc: std.mem.Allocator) ListWriter(@TypeOf(list.*)) {
    return .{ .list = list, .alloc = alloc };
}

/// Reads the environment through libc, which Cyber links on every target that has one.
/// Zig 0.16 hands the environment only to `main`, but Cyber also runs embedded through the C API.
pub fn getEnvVarOwned(alloc: std.mem.Allocator, key: []const u8) error{ OutOfMemory, EnvironmentVariableNotFound, InvalidWtf8 }![]u8 {
    if (!builtin.link_libc) return error.EnvironmentVariableNotFound;
    var buf: [256]u8 = undefined;
    const key_z = std.fmt.bufPrintSentinel(&buf, "{s}", .{key}, 0) catch return error.EnvironmentVariableNotFound;
    const val = std.c.getenv(key_z.ptr) orelse return error.EnvironmentVariableNotFound;
    return alloc.dupe(u8, std.mem.span(val));
}
