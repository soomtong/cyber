//! The clocks of the `time` module. The calendar, the parser and the formatter are in `time.cy`.
const std = @import("std");
const builtin = @import("builtin");
const stdx = @import("stdx");
const cy = @import("../cyber.zig");
const C = @import("../capi.zig");

const Src = @embedFile("time.cy");

/// wasm without WASI has no clock of its own: the host provides `hostMilliTimestamp` (see `stdx/time_wasm.zig`),
/// which serves both clocks at millisecond resolution.
const is_wasm_freestanding = builtin.target.cpu.arch.isWasm() and builtin.target.os.tag != .wasi;

comptime {
    @export(&bind, .{ .name = "cl_mod_bind_time", .linkage = .strong });
}

pub fn bind(_: *C.VM, mod: *C.Sym) callconv(.c) C.Bytes {
    cy.core.markBuiltinModule(mod);
    for (funcs) |e| {
        C.mod_add_func(mod, e.@"0", e.@"1");
    }
    return C.to_bytes(Src);
}

const zErrFunc = cy.core.zErrFunc;

const funcs = [_]struct { []const u8, C.BindFunc }{
    .{ "real_ns_", zErrFunc(realNs) },
    .{ "mono_ns_", zErrFunc(monoNs) },
};

fn clockNs(clock: std.Io.Clock) i64 {
    if (is_wasm_freestanding) {
        return stdx.time.getMilliTimestamp() * std.time.ns_per_ms;
    }
    const ns = std.Io.Timestamp.now(stdx.io(), clock).toNanoseconds();
    return std.math.cast(i64, ns) orelse if (ns < 0) std.math.minInt(i64) else std.math.maxInt(i64);
}

/// `fn real_ns_() -> int`: nanoseconds of the wall clock since 1970-01-01T00:00:00Z.
fn realNs(t: *cy.Thread) anyerror!C.Ret {
    const ret = t.ret(i64);
    ret.* = clockNs(.real);
    return C.RetOk;
}

/// `fn mono_ns_() -> int`: nanoseconds of a clock that never goes back. The origin is not specified.
fn monoNs(t: *cy.Thread) anyerror!C.Ret {
    const ret = t.ret(i64);
    ret.* = clockNs(.awake);
    return C.RetOk;
}
