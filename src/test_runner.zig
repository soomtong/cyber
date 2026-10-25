const std = @import("std");
const builtin = @import("builtin");

/// Template for a custom test runner.
pub fn main(init: std.process.Init.Minimal) !void {
    // Zig 0.17 leaves the testing allocator and Io to the test runner.
    std.testing.allocator_instance = .init(std.heap.page_allocator, .{});
    std.testing.io_instance = .init(std.testing.allocator, .{});

    test_init(&init.args);

    var passed: usize = 0;
    for (builtin.test_functions) |t| {
        t.func() catch |err| {
            std.debug.print("{s} fail: {}\n", .{t.name, err});
            if (@errorReturnTrace()) |trace| {
                std.debug.dumpErrorReturnTrace(trace);
            }
            continue;
        };
        passed += 1;
        std.debug.print("{s} passed\n", .{t.name});
    }

    if (passed < builtin.test_functions.len) {
        std.debug.print("Failed. {}/{} tests passed\n", .{passed, builtin.test_functions.len});
        return error.Failed;
    } else {
        std.debug.print("Ok. {} tests passed\n", .{passed});
    }

    // Deinit test allocator to surface leaks.
    std.testing.io_instance.deinit();
    _ = std.testing.allocator_instance.deinit();
}

/// `args` points to a `std.process.Args`.
extern fn test_init(args: *const anyopaque) void;

extern fn zpanic(msg: [*]const u8, msg_len: usize, first_trace_addr: usize) noreturn;

pub fn panic(msg: []const u8, trace: ?*std.lang.StackTrace, ret_addr: ?usize) noreturn {
    _ = trace;
    _ = ret_addr;
    zpanic(msg.ptr, msg.len, @returnAddress());
}