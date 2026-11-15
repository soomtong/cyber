//! The clocks of the `time` module and the reads of the system time zone database.
//! The calendar, the parser, the formatter and the TZif reader are in `time.cy`.
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
    .{ "tz_read_", zErrFunc(tzRead) },
    .{ "tz_local_", zErrFunc(tzLocal) },
    .{ "tz_local_data_", zErrFunc(tzLocalData) },
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

/// Whether the target has a zoneinfo directory to read. Windows keeps its zones in the registry in another form,
/// and wasm has no file system of its own or (WASI) no zoneinfo in it.
const has_zoneinfo = switch (builtin.target.os.tag) {
    .windows, .wasi, .freestanding => false,
    else => !builtin.target.cpu.arch.isWasm(),
};

/// Where the compiled zones are, after `$TZDIR`. The same list as Go and zeit.
const zoneinfo_dirs = [_][]const u8{
    "/usr/share/zoneinfo",
    "/usr/share/lib/zoneinfo",
    "/usr/lib/locale/TZ",
    "/etc/zoneinfo",
};

/// A TZif file of the zones that exist is a few kilobytes.
const max_tzif_len = 1 << 20;

/// Whether `name` can be joined to a zoneinfo directory: `Area/Location` of letters, digits and `+ - _`.
/// No `.`, no empty part and no leading `/`, so that it stays inside the directory.
fn validZoneName(name: []const u8) bool {
    if (name.len == 0 or name.len > 255) return false;
    var prev: u8 = '/';
    for (name) |ch| {
        switch (ch) {
            'A'...'Z', 'a'...'z', '0'...'9', '+', '-', '_' => {},
            '/' => if (prev == '/') return false,
            else => return false,
        }
        prev = ch;
    }
    return prev != '/';
}

fn isTzif(data: []const u8) bool {
    return data.len >= 44 and std.mem.eql(u8, data[0..4], "TZif");
}

fn readTzifFile(alloc: std.mem.Allocator, path: []const u8) ?[]u8 {
    const data = std.Io.Dir.cwd().readFileAlloc(stdx.io(), path, alloc, .limited(max_tzif_len)) catch return null;
    if (!isTzif(data)) {
        alloc.free(data);
        return null;
    }
    return data;
}

fn readZone(alloc: std.mem.Allocator, name: []const u8) ?[]u8 {
    if (!has_zoneinfo or !validZoneName(name)) return null;
    var buf: [1024]u8 = undefined;
    if (stdx.getEnvVarOwned(alloc, "TZDIR")) |dir| {
        defer alloc.free(dir);
        if (dir.len > 0 and std.Io.Dir.path.isAbsolute(dir)) {
            // Like jiff and zeit, `TZDIR` replaces the list when it has the zone.
            if (std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, name })) |path| {
                if (readTzifFile(alloc, path)) |data| return data;
            } else |_| {}
        }
    } else |_| {}
    for (zoneinfo_dirs) |dir| {
        const path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, name }) catch continue;
        if (readTzifFile(alloc, path)) |data| return data;
    }
    return null;
}

/// `fn tz_read_(name str) -> str`: the TZif file of a zone, or `''` when the system has none by that name.
fn tzRead(t: *cy.Thread) anyerror!C.Ret {
    const ret = t.ret(cy.heap.Str);
    const name_str = t.param(cy.heap.Str);
    defer t.heap.destructStr(&name_str);
    const alloc = t.alloc;
    const data = readZone(alloc, name_str.slice()) orelse {
        ret.* = try t.heap.init_empty_str();
        return C.RetOk;
    };
    defer alloc.free(data);
    ret.* = try t.heap.init_str(data);
    return C.RetOk;
}

const local_path = "/etc/localtime";

/// The zone name in the target of a link into a zoneinfo directory: `.../zoneinfo/Asia/Seoul` gives `Asia/Seoul`.
fn nameOfLink(target: []const u8) []const u8 {
    const key = "zoneinfo/";
    const at = std.mem.lastIndexOf(u8, target, key) orelse return "";
    const name = target[at + key.len ..];
    return if (validZoneName(name)) name else "";
}

/// `fn tz_local_() -> str`: how the system says what the local zone is.
/// `''`: it does not say. `U`: UTC (`TZ` is set and empty). `T<value>`: the value of `TZ`, a zone name or a
/// POSIX rule. `L<name>`: a TZif file, read with `tz_local_data_`: `TZ` is an absolute path, or `/etc/localtime`.
/// `<name>` is the zone that the link points at, or empty.
fn tzLocal(t: *cy.Thread) anyerror!C.Ret {
    const ret = t.ret(cy.heap.Str);
    const alloc = t.alloc;
    if (!has_zoneinfo) {
        ret.* = try t.heap.init_empty_str();
        return C.RetOk;
    }
    var buf: [1100]u8 = undefined;
    if (stdx.getEnvVarOwned(alloc, "TZ")) |raw| {
        defer alloc.free(raw);
        // A leading `:` marks an implementation defined value: here, as in glibc, a file or a zone name.
        const value = if (raw.len > 0 and raw[0] == ':') raw[1..] else raw;
        if (value.len == 0) {
            ret.* = try t.heap.init_astr("U");
        } else if (std.Io.Dir.path.isAbsolute(value)) {
            const spec = std.fmt.bufPrint(&buf, "L{s}", .{nameOfLink(value)}) catch "L";
            ret.* = try t.heap.init_str(spec);
        } else {
            const spec = std.fmt.bufPrint(&buf, "T{s}", .{value[0..@min(value.len, 1024)]}) catch "T";
            ret.* = try t.heap.init_str(spec);
        }
        return C.RetOk;
    } else |_| {}
    var link: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const name = if (std.Io.Dir.readLinkAbsolute(stdx.io(), local_path, &link)) |len| nameOfLink(link[0..len]) else |_| "";
    const spec = std.fmt.bufPrint(&buf, "L{s}", .{name}) catch "L";
    ret.* = try t.heap.init_str(spec);
    return C.RetOk;
}

/// `fn tz_local_data_() -> str`: the TZif file that `tz_local_` answered `L` for, or `''` when it can not be read.
fn tzLocalData(t: *cy.Thread) anyerror!C.Ret {
    const ret = t.ret(cy.heap.Str);
    const alloc = t.alloc;
    var data: ?[]u8 = null;
    if (has_zoneinfo) {
        if (stdx.getEnvVarOwned(alloc, "TZ")) |raw| {
            defer alloc.free(raw);
            const value = if (raw.len > 0 and raw[0] == ':') raw[1..] else raw;
            if (value.len > 0 and std.Io.Dir.path.isAbsolute(value)) data = readTzifFile(alloc, value);
        } else |_| {
            data = readTzifFile(alloc, local_path);
        }
    }
    const bytes = data orelse {
        ret.* = try t.heap.init_empty_str();
        return C.RetOk;
    };
    defer alloc.free(bytes);
    ret.* = try t.heap.init_str(bytes);
    return C.RetOk;
}

test "time zone names" {
    const zt = std.testing;
    try zt.expect(validZoneName("Asia/Seoul"));
    try zt.expect(validZoneName("America/Argentina/Buenos_Aires"));
    try zt.expect(validZoneName("Etc/GMT+5"));
    try zt.expect(validZoneName("UTC"));
    try zt.expect(!validZoneName(""));
    try zt.expect(!validZoneName("/etc/passwd"));
    try zt.expect(!validZoneName("../../etc/passwd"));
    try zt.expect(!validZoneName("Asia/../../etc/passwd"));
    try zt.expect(!validZoneName("Asia//Seoul"));
    try zt.expect(!validZoneName("Asia/Seoul/"));
    try zt.expect(!validZoneName("posixrules.tab"));
    try zt.expect(!validZoneName("Asia\\Seoul"));
    try zt.expectEqualStrings("Asia/Seoul", nameOfLink("/var/db/timezone/zoneinfo/Asia/Seoul"));
    try zt.expectEqualStrings("", nameOfLink("/etc/somewhere"));
}
