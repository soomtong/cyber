const std = @import("std");
const builtin = @import("builtin");
const stdx = @import("stdx.zig");

const time_wasm = @import("time_wasm.zig");
const IsWasm = builtin.target.cpu.arch.isWasm() and builtin.os.tag != .wasi;

pub const Timer = if (IsWasm) time_wasm.Timer else NativeTimer;

/// Same surface as the `std.time.Timer` that Zig 0.16 removed.
const NativeTimer = struct {
    start_ts: std.Io.Timestamp,

    pub fn start() !NativeTimer {
        return .{ .start_ts = .now(stdx.io(), .awake) };
    }

    pub fn read(self: NativeTimer) u64 {
        return @intCast(self.start_ts.untilNow(stdx.io(), .awake).toNanoseconds());
    }
};

pub const Duration = struct {
    const Self = @This();

    ns: u64,

    pub fn initSecsF(secs: f32) Self {
        return .{
            .ns = @intFromFloat(secs * 1e9),
        };
    }

    pub fn toMillis(self: Self) u32 {
        return @intCast(self.ns / 1000000);
    }
};

pub fn getMilliTimestamp() i64 {
    if (IsWasm) {
        return time_wasm.getMilliTimestamp();
    } else {
        return std.time.milliTimestamp();
    }
}
