//! `std.DynLib`, plus the Windows support that Zig 0.16 removed from it.

const std = @import("std");
const builtin = @import("builtin");
const win32 = @import("win32.zig");

pub const DynLib = if (builtin.os.tag == .windows) WindowsDynLib else std.DynLib;

pub const WindowsDynLib = struct {
    handle: std.os.windows.HMODULE,

    pub fn open(path: []const u8) !WindowsDynLib {
        var buf: [std.os.windows.PATH_MAX_WIDE:0]u16 = undefined;
        const len = try std.unicode.wtf8ToWtf16Le(&buf, path);
        buf[len] = 0;
        const handle = win32.LoadLibraryW(buf[0..len :0]) orelse return error.FileNotFound;
        return .{ .handle = handle };
    }

    /// The module of the running executable, like `dlopen(NULL)`.
    pub fn openSelf() !WindowsDynLib {
        const handle = win32.GetModuleHandleW(null) orelse return error.FileNotFound;
        return .{ .handle = handle };
    }

    pub fn close(self: *WindowsDynLib) void {
        _ = win32.FreeLibrary(self.handle);
        self.* = undefined;
    }

    pub fn lookup(self: *WindowsDynLib, comptime T: type, name: [:0]const u8) ?T {
        const addr = win32.GetProcAddress(self.handle, name.ptr) orelse return null;
        return @ptrCast(@alignCast(addr));
    }
};
