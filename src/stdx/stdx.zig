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
///
/// Built on first use from `init_single_threaded`, but with a real allocator and the
/// process environment. `std.Io.Threaded.global_single_threaded` has a failing allocator
/// and an empty environment, so child processes could not be spawned through it and
/// would inherit no environment variables.
pub fn io() std.Io {
    if (threaded_state.load(.acquire) != threaded_ready) initThreadedOnce();
    return threaded.io();
}

var threaded: std.Io.Threaded = .init_single_threaded;

const threaded_uninit: u8 = 0;
const threaded_initing: u8 = 1;
const threaded_ready: u8 = 2;
var threaded_state: std.atomic.Value(u8) = .init(threaded_uninit);

fn initThreadedOnce() void {
    @branchHint(.cold);
    if (threaded_state.cmpxchgStrong(threaded_uninit, threaded_initing, .acquire, .acquire) == null) {
        // `Threaded` uses its allocator for `processSpawn` scratch memory and the memoized environment scan.
        threaded.allocator = if (builtin.link_libc) std.heap.c_allocator else std.heap.page_allocator;
        const block = processEnvironBlock();
        threaded.environ = .{ .process_environ = .{ .block = block } };
        threaded.environ_initialized = block.isEmpty();
        threaded_state.store(threaded_ready, .release);
        return;
    }
    while (threaded_state.load(.acquire) != threaded_ready) std.atomic.spinLoopHint();
}

const has_libc_environ = builtin.link_libc and switch (builtin.os.tag) {
    .windows, .freestanding, .other => false,
    else => true,
};

/// The environment the process was started with, as `std.start` would hand to `main`.
/// Read through libc since Cyber also runs embedded, where `main` is not Zig's.
fn processEnvironBlock() std.process.Environ.Block {
    if (builtin.os.tag == .windows) return .global;
    if (has_libc_environ) {
        const c_environ = std.c.environ;
        var n: usize = 0;
        while (c_environ[n] != null) : (n += 1) {}
        return .{ .slice = c_environ[0..n :null] };
    } else {
        return .empty;
    }
}

/// Appends to an unmanaged byte `ArrayList` of any alignment.
/// Keeps the call surface of `ArrayList.writer()`, which Zig 0.16 removed.
pub fn ListWriter(comptime List: type) type {
    return struct {
        list: *List,
        alloc: std.mem.Allocator,

        pub const Error = std.mem.Allocator.Error;

        pub fn print(self: @This(), comptime fmt: []const u8, args: anytype) Error!void {
            return self.list.print(self.alloc, fmt, args);
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
/// On Windows the value comes from the process environment block as WTF-8, like
/// `std.process.getEnvVarOwned` before Zig 0.16, since the CRT `getenv` would return the ANSI code page.
pub fn getEnvVarOwned(alloc: std.mem.Allocator, key: []const u8) error{ OutOfMemory, EnvironmentVariableNotFound, InvalidWtf8 }![]u8 {
    if (builtin.os.tag == .windows) {
        const key_w = try std.unicode.wtf8ToWtf16LeAllocZ(alloc, key);
        defer alloc.free(key_w);
        const environ: std.process.Environ = .{ .block = .global };
        const val_w = environ.getWindows(key_w) orelse return error.EnvironmentVariableNotFound;
        return std.unicode.wtf16LeToWtf8Alloc(alloc, val_w);
    }
    if (!builtin.link_libc) return error.EnvironmentVariableNotFound;
    var buf: [256]u8 = undefined;
    const key_z = std.mem.printSentinel(&buf, "{s}", .{key}, 0) catch return error.EnvironmentVariableNotFound;
    const val = std.c.getenv(key_z.ptr) orelse return error.EnvironmentVariableNotFound;
    return alloc.dupe(u8, std.mem.span(val));
}

/// Reinterprets the bytes of `v` as `T`, as `@bitCast` did for extern structs and unions before Zig 0.17.
pub fn reinterpret(comptime T: type, v: anytype) T {
    comptime std.debug.assert(@sizeOf(T) == @sizeOf(@TypeOf(v)));
    return @as(*align(1) const T, @ptrCast(&v)).*;
}
