// Debugging aids for the lib tests. Nothing calls them; call `debug(vm)` from a test to see the logs.
const std = @import("std");
const C = @import("../capi.zig");

pub fn test_logger(_: ?*C.VM, str: C.Bytes) callconv(.c) void {
    std.debug.print("{s}\n", .{C.from_bytes(str)});
}

pub fn test_global_logger(str: C.Bytes) callconv(.c) void {
    std.debug.print("{s}\n", .{C.from_bytes(str)});
}

pub fn debug(vm: ?*C.VM) void {
    C.setVerbose(true);
    C.vm_set_logger(vm, &test_logger);
    C.set_logger(&test_global_logger);
}
