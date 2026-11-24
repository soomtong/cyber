const std = @import("std");
const dynlib = @import("../dynlib.zig");
const stdx = @import("stdx");
const builtin = @import("builtin");
const C = @import("../capi.zig");
const fmt = @import("../fmt.zig");
const bindings = @import("../builtins/bindings.zig");
const cli = @import("../cli.zig");
const zErrFunc = cli.zErrFunc;
const Symbol = bindings.Symbol;
// const ffi = @import("os_ffi.zig");
const http = @import("../http.zig");
const cache = @import("../cache.zig");
const is_wasm = builtin.target.cpu.arch.isWasm();

const log = std.log.scoped(.os);

pub const Src = @embedFile("os.cy");

/// Adjusted by the CLI main when args are used to interpret a script file.
pub var argv_start: usize = 0;

/// Set by the CLI `main`. Zig 0.16 hands the process arguments only to `main`, so an embedder sees none.
pub var process_args: ?std.process.Args = null;

const funcs = [_]struct{[]const u8, C.BindFunc}{
    // Top level
    .{"cache_url",       zErrFunc(cacheUrl)},
    .{"fetch_url",       zErrFunc(fetchUrl)},
    
    .{"stderr",         zErrFunc(stderr)},
    .{"stdin",          zErrFunc(stdin)},
    .{"stdout",         zErrFunc(stdout)},
    .{"_exec",          zErrFunc(exec)},
    .{"_cmd_run",       zErrFunc(cmdRun)},
    .{"_args",          zErrFunc(_args)},
};

const types = [_]struct{[]const u8, C.BindType}{
    // .{"FFI",          CS.TYPE_HOBJ(null, ffi.FFI_deinit)},
};

pub fn bind(_: ?*C.VM, mod: ?*C.Sym) callconv(.c) C.Bytes {
    for (funcs) |e| {
        C.mod_add_func(mod.?, e.@"0", e.@"1");
    }

    for (types) |e| {
        C.mod_add_type(mod.?, e.@"0", e.@"1");
    }

    C.mod_add_global(mod.?, "vecBitSize", C.BIND_GLOBAL(&simd_bit_size));
    return C.to_bytes("");
}

var simd_bit_size: i64 = if (std.simd.suggestVectorLength(u8)) |VecSize|
    VecSize * 8 else 0;

const File = extern struct {
    fd: std.c.fd_t,
    closed: bool = false,
};

fn stderr(t: *C.Thread) !C.Ret {
    // if (!cy.hasStdFiles) return t.ret_panic("Unsupported.");

    const ret = C.thread_ret(t, File);
    const handle = std.Io.File.stderr().handle;
    ret.* = .{ .fd = handle };
    return C.RetOk;
}

fn stdin(t: *C.Thread) !C.Ret {
    // if (!cy.hasStdFiles) return t.ret_panic("Unsupported.");

    const ret = C.thread_ret(t, File);
    const handle = std.Io.File.stdin().handle;
    ret.* = .{ .fd = handle };
    return C.RetOk;
}

fn stdout(t: *C.Thread) !C.Ret {
    // if (!cy.hasStdFiles) return t.ret_panic("Unsupported.");

    const ret = C.thread_ret(t, File);
    const handle = std.Io.File.stdout().handle;
    ret.* = .{ .fd = handle };
    return C.RetOk;
}

fn _args(t: *C.Thread) !C.Ret {
    // if (is_wasm) return t.ret_panic("Unsupported.");

    const ret = C.thread_ret(t, C.Slice);
    const byte_buffer_t: C.TypeId = @intCast(C.thread_int(t));
    _ = byte_buffer_t;

    const alloc = C.thread_allocator(t);

    var args: std.ArrayList(C.str) = .empty;
    defer {
        for (args.items) |*arg| {
            C.str_deinit(t, arg);
        }
        args.deinit(alloc);
    }

    if (process_args) |process_args_| {
        var iter = try process_args_.iterateAllocator(alloc);
        defer iter.deinit();
        while (iter.next()) |arg| {
            const str = C.str_init(t, arg);
            try args.append(alloc, str);
        }
    }

    const final_args = args.items[argv_start..];

    const slice = C.slice_init(t, final_args.len, @sizeOf(C.str));
    @memcpy(C.slice_items(slice, C.str), final_args);
    try args.resize(alloc, argv_start);
    ret.* = slice;
    return C.RetOk;
}

fn cacheUrl(t: *C.Thread) anyerror!C.Ret {
    // if (is_wasm) return t.ret_panic("Unsupported.");

    const vm = C.thread_vm(t);
    const alloc = C.thread_allocator(t);

    const ret = C.thread_ret(t, C.str);
    var url_s = C.thread_str(t);
    defer C.str_deinit(t, &url_s);
    const url = C.str_bytes(url_s);
    const path = try allocCacheUrl(vm, url);
    defer alloc.free(path);
    ret.* = C.str_init(t, path);
    return C.RetOk;
}

pub fn allocCacheUrl(vm: *C.VM, url: []const u8) ![]const u8 {
    const alloc = C.vm_allocator(vm);

    const specGroup = try cache.getSpecHashGroup(alloc, url);
    defer specGroup.deinit(alloc);

    const a: *cli.App = @ptrCast(@alignCast(C.vm_user_data(vm)));
    if (a.config.reload) {
        try specGroup.markEntryBySpecForRemoval(url);
    } else {
        // First check local cache.
        if (try specGroup.findEntryBySpec(url)) |entry| {
            return cache.allocSpecFilePath(alloc, entry);
        }
    }

    const resp = try http.get(alloc, a.httpClient, url);
    defer alloc.free(resp.body);
    if (resp.status != .ok) {
        cli.tracev("cache_url response status: {}", .{resp.status});
        return error.UnknownError;
    } else {
        const entry = try cache.saveNewSpecFile(alloc, specGroup, url, resp.body);
        defer entry.deinit(alloc);
        return cache.allocSpecFilePath(alloc, entry);
    }
}

const ExecResult = extern struct {
    out: C.str,
    err: C.str,
    code: i64,
};

pub fn exec(t: *C.Thread) anyerror!C.Ret {
    if (is_wasm) return C.thread_ret_panic(t, "Unsupported.");

    const alloc = C.thread_allocator(t);

    const ret = C.thread_ret(t, ExecResult);
    // `[&]str` span: borrowed, so nothing is released here. A `[]str` param would be owned by
    // this host function and leak unless it ran the slice destructor.
    const ArgsSpan = extern struct { ptr: [*]const C.str, len: u64 };
    const args_span = C.thread_param(t, ArgsSpan);
    const args = args_span.ptr[0..@intCast(args_span.len)];
    var buf: std.ArrayList([]const u8) = .empty;
    defer {
        buf.deinit(alloc);
    }
    for (args) |arg| {
        try buf.append(alloc, C.str_bytes(arg));
    }

    var env_map = try currentEnvMap(alloc);
    defer env_map.deinit();

    const res = try std.process.run(alloc, stdx.io(), .{
        .argv = buf.items,
        .environ_map = &env_map,
        .stdout_limit = .limited(1024 * 1024 * 10),
        .stderr_limit = .limited(1024 * 1024 * 10),
    });

    defer alloc.free(res.stdout);
    var out = C.str_init(t, res.stdout);
    errdefer t.heap.destructStr(&out);
    defer alloc.free(res.stderr);
    var err = C.str_init(t, res.stderr);
    errdefer t.heap.destructStr(&err);
    var code: i64 = -1;
    if (res.term == .exited) {
        code = @intCast(res.term.exited);
    }

    ret.* = .{
        .out = out,
        .err = err,
        .code = code,
    };
    return C.RetOk;
}

/// The environment of this process as it is now. A child that inherits the environment gets the one that the
/// `Io` instance read when it was built, without the variables that `os.set_env` has set since.
fn currentEnvMap(alloc: std.mem.Allocator) !std.process.Environ.Map {
    const environ: std.process.Environ = .{ .block = stdx.processEnvironBlock() };
    return environ.createMap(alloc);
}

/// A pipeline of `os.Cmd` has at most this many stages.
const cmd_max_stages = 16;
/// The captured stdout, and the captured stderr of all stages together, stop at this many bytes each.
const cmd_output_limit = 1024 * 1024 * 10;

/// What `_cmd_run` returns. `fail` is a `CmdFail`: the pipeline did not start or its output could not be read.
/// `code` is 0 when every stage succeeded and otherwise the status of the last stage that failed.
const CmdRaw = extern struct {
    out: C.str,
    err: C.str,
    code: i64,
    fail: i64,
};

/// Mirrored by `cmd_error` in `os.cy`.
const CmdFail = enum(i64) {
    none = 0,
    not_found = 1,
    permission_denied = 2,
    invalid_argument = 3,
    too_big = 4,
    not_a_directory = 5,
    is_a_directory = 6,
    too_many_open_files = 7,
    out_of_memory = 8,
    unknown = 9,
};

/// Mirrored by `Cmd.run`, `Cmd.read` and `Cmd.run_status` in `os.cy`.
const CmdMode = enum(i64) {
    /// stdout and stderr go to those of this process. stdin too, unless there is input text.
    run = 0,
    /// The stdout of the last stage is captured. stderr goes to that of this process.
    read = 1,
    /// The stdout of the last stage and the stderr of every stage are captured.
    status = 2,
};

const CmdStage = struct {
    argv: []const []const u8,
    cwd: []const u8,
    /// Name and value pairs.
    env: []const C.str,
};

const CmdOutput = struct {
    out: []u8 = &.{},
    err: []u8 = &.{},
    code: i64 = 0,
};

fn cmdFail(err: anyerror) CmdFail {
    return switch (err) {
        error.FileNotFound => .not_found,
        error.AccessDenied, error.PermissionDenied => .permission_denied,
        error.InvalidExe, error.InvalidName, error.InvalidWtf8, error.InvalidBatchScriptArg, error.BadPathName, error.NameTooLong => .invalid_argument,
        error.StreamTooLong => .too_big,
        error.NotDir => .not_a_directory,
        error.IsDir => .is_a_directory,
        error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded => .too_many_open_files,
        error.OutOfMemory, error.SystemResources => .out_of_memory,
        else => .unknown,
    };
}

/// Runs the pipeline of an `os.Cmd`. The command is described by flat spans so that nothing is copied:
/// `args` holds the arguments of all stages, `counts` two numbers per stage (arguments, environment pairs),
/// `dirs` one working directory per stage (empty to inherit), `envs` the name and value pairs of all stages,
/// and `input` zero or one text for the stdin of the first stage.
pub fn cmdRun(t: *C.Thread) anyerror!C.Ret {
    if (is_wasm) return C.thread_ret_panic(t, "Unsupported.");

    const alloc = C.thread_allocator(t);
    const ret = C.thread_ret(t, CmdRaw);

    const StrSpan = extern struct { ptr: [*]const C.str, len: u64 };
    const IntSpan = extern struct { ptr: [*]const i64, len: u64 };
    const args_span = C.thread_param(t, StrSpan);
    const counts_span = C.thread_param(t, IntSpan);
    const dirs_span = C.thread_param(t, StrSpan);
    const envs_span = C.thread_param(t, StrSpan);
    const input_span = C.thread_param(t, StrSpan);
    const mode: CmdMode = @enumFromInt(C.thread_int(t));

    const args = args_span.ptr[0..@intCast(args_span.len)];
    const counts = counts_span.ptr[0..@intCast(counts_span.len)];
    const dirs = dirs_span.ptr[0..@intCast(dirs_span.len)];
    const envs = envs_span.ptr[0..@intCast(envs_span.len)];
    const input: ?[]const u8 = if (input_span.len > 0) C.str_bytes(input_span.ptr[0]) else null;

    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out: CmdOutput = .{};
    defer alloc.free(out.out);
    defer alloc.free(out.err);

    const nstages = dirs.len;
    var fail: CmdFail = .none;
    if (nstages == 0 or nstages > cmd_max_stages or counts.len != nstages * 2) {
        fail = .invalid_argument;
    } else {
        const stages = try arena.alloc(CmdStage, nstages);
        var arg_i: usize = 0;
        var env_i: usize = 0;
        for (stages, 0..) |*stage, i| {
            const nargs: usize = @intCast(counts[i * 2]);
            const nenv: usize = @intCast(counts[i * 2 + 1]);
            const argv = try arena.alloc([]const u8, nargs);
            for (argv, args[arg_i..][0..nargs]) |*dst, arg| dst.* = C.str_bytes(arg);
            // A program name is required, and a NUL would cut an argument short.
            if (nargs == 0 or argv[0].len == 0) fail = .invalid_argument;
            for (argv) |arg| {
                if (std.mem.indexOfScalar(u8, arg, 0) != null) fail = .invalid_argument;
            }
            stage.* = .{
                .argv = argv,
                .cwd = C.str_bytes(dirs[i]),
                .env = envs[env_i..][0 .. nenv * 2],
            };
            arg_i += nargs;
            env_i += nenv * 2;
        }
        if (fail == .none) {
            cmdRunPipeline(alloc, arena, stages, input, mode, &out) catch |err| {
                if (err == error.OutOfMemory) return err;
                fail = cmdFail(err);
            };
        }
    }

    var out_s = C.str_init(t, out.out);
    errdefer t.heap.destructStr(&out_s);
    const err_s = C.str_init(t, out.err);
    ret.* = .{
        .out = out_s,
        .err = err_s,
        .code = out.code,
        .fail = @intFromEnum(fail),
    };
    return C.RetOk;
}

/// Writes the input text to the stdin of the first stage and closes it, on a thread of its own: the stage may
/// not read its input before its output is read, and a pipe holds only so much.
fn cmdFeedInput(file: std.Io.File, bytes: []const u8) void {
    const io = stdx.io();
    if (builtin.os.tag != .windows) {
        // A stage that exits without reading its input makes the write fail with a signal. Blocked on this
        // thread, the write returns an error instead and the signal goes away with the thread.
        var set = std.posix.sigemptyset();
        std.posix.sigaddset(&set, .PIPE);
        std.posix.sigprocmask(std.posix.SIG.BLOCK, &set, null);
    }
    file.writeStreamingAll(io, bytes) catch {};
    file.close(io);
}

fn cmdRunPipeline(alloc: std.mem.Allocator, arena: std.mem.Allocator, stages: []const CmdStage, input: ?[]const u8, mode: CmdMode, out: *CmdOutput) !void {
    const io = stdx.io();
    const n = stages.len;

    const base_env = try currentEnvMap(arena);

    var children: [cmd_max_stages]std.process.Child = undefined;
    var nspawned: usize = 0;
    // On an error, the stages that started are stopped. After `wait` this does nothing.
    defer for (children[0..nspawned]) |*child| child.kill(io);

    for (stages, 0..) |stage, i| {
        // The variables of the stage go on top of the environment of this process.
        var env_map = base_env;
        if (stage.env.len > 0) {
            env_map = try base_env.clone(arena);
            var j: usize = 0;
            while (j < stage.env.len) : (j += 2) {
                const name = C.str_bytes(stage.env[j]);
                if (!std.process.Environ.Map.validateKeyForPut(name)) return error.InvalidName;
                try env_map.put(name, C.str_bytes(stage.env[j + 1]));
            }
        }

        const child_in: std.process.SpawnOptions.StdIo = if (i > 0)
            .{ .file = children[i - 1].stdout.? }
        else if (input != null)
            .pipe
        else if (mode == .run)
            .inherit
        else
            .ignore;
        const child_out: std.process.SpawnOptions.StdIo = if (i + 1 < n or mode != .run) .pipe else .inherit;
        const child_err: std.process.SpawnOptions.StdIo = if (mode == .status) .pipe else .inherit;

        children[i] = try std.process.spawn(io, .{
            .argv = stage.argv,
            .cwd = if (stage.cwd.len > 0) .{ .path = stage.cwd } else .inherit,
            .environ_map = &env_map,
            .stdin = child_in,
            .stdout = child_out,
            .stderr = child_err,
            .create_no_window = true,
        });
        nspawned += 1;

        if (i > 0) {
            // The next stage holds the read end now. Kept open here, the stage before would never see it close.
            children[i - 1].stdout.?.close(io);
            children[i - 1].stdout = null;
        }
    }

    var feeder: ?std.Thread = null;
    if (input) |bytes| {
        const file = children[0].stdin.?;
        children[0].stdin = null;
        feeder = std.Thread.spawn(.{}, cmdFeedInput, .{ file, bytes }) catch |err| {
            file.close(io);
            return err;
        };
    }
    defer if (feeder) |thread| thread.join();

    // Stream 0 is the stdout of the last stage, the others are the stderr of the stages in order.
    var files: [cmd_max_stages + 1]std.Io.File = undefined;
    var nfiles: usize = 0;
    if (mode != .run) {
        files[0] = children[n - 1].stdout.?;
        nfiles = 1;
        if (mode == .status) {
            for (children[0..n]) |child| {
                files[nfiles] = child.stderr.?;
                nfiles += 1;
            }
        }
    }

    if (nfiles > 0) {
        var buffer: std.Io.File.MultiReader.Buffer(cmd_max_stages + 1) = undefined;
        // `Streams` reads the number of streams from `len` and lays its two arrays out after it.
        const streams = buffer.toStreams();
        streams.len = @intCast(nfiles);
        var multi_reader: std.Io.File.MultiReader = undefined;
        multi_reader.init(alloc, io, streams, files[0..nfiles]);
        defer multi_reader.deinit();

        while (multi_reader.fill(64, .none)) |_| {
            if (multi_reader.reader(0).buffered().len > cmd_output_limit) return error.StreamTooLong;
            var err_len: usize = 0;
            for (1..nfiles) |i| err_len += multi_reader.reader(i).buffered().len;
            if (err_len > cmd_output_limit) return error.StreamTooLong;
        } else |err| switch (err) {
            error.EndOfStream => {},
            else => |e| return e,
        }
        try multi_reader.checkAnyError();

        out.out = try multi_reader.toOwnedSlice(0);
        var err_buf: std.ArrayList(u8) = .empty;
        errdefer err_buf.deinit(alloc);
        for (1..nfiles) |i| {
            try err_buf.appendSlice(alloc, multi_reader.reader(i).buffered());
        }
        out.err = try err_buf.toOwnedSlice(alloc);
    }

    // The code of the pipeline is that of the last stage that failed. A stage before the last one that was
    // stopped because the next stage closed its input did what it was asked.
    var code: i64 = 0;
    for (children[0..n], 0..) |*child, i| {
        const term = try child.wait(io);
        const stage_code: i64 = switch (term) {
            .exited => |status| status,
            .signal => |sig| b: {
                if (builtin.os.tag != .windows) {
                    if (i + 1 < n and sig == .PIPE) break :b 0;
                    break :b 128 + @as(i64, @intCast(@intFromEnum(sig)));
                }
                break :b -1;
            },
            else => -1,
        };
        if (stage_code != 0) code = stage_code;
    }
    out.code = code;
}

pub fn fetchUrl(t: *C.Thread) anyerror!C.Ret {
    // if (is_wasm) return t.ret_panic("Unsupported.");

    const ret = C.thread_ret(t, C.str);
    var url_s = C.thread_param(t, C.str);
    defer C.str_deinit(t, &url_s);
    const url = C.str_bytes(url_s);

    const vm = C.thread_vm(t);
    const alloc = C.thread_allocator(t);

    const a: *cli.App = @ptrCast(@alignCast(C.vm_user_data(vm)));
    const resp = try http.get(alloc, a.httpClient, url);
    defer alloc.free(resp.body);
    ret.* = C.str_init(t, resp.body);

    return C.RetOk;
}

/// `std.DynLib` wraps libc's `dlopen` handle only when it links a dynamic libc. A static musl build
/// gets `ElfDynLib`, which has no handle, so `RTLD_DEEPBIND` applies only to the libc case.
const dynlib_has_dl_handle = @hasField(@FieldType(std.DynLib, "inner"), "handle");

pub fn dlopen(path: []const u8) !dynlib.DynLib {
    if (builtin.target.os.tag == .linux and builtin.link_libc and dynlib_has_dl_handle) {
        const path_c = try std.posix.toPosixPath(path);
        // Place the lookup scope of the symbols in this library ahead of the global scope.
        const RTLD_DEEPBIND = 0x00008;
        var mode: u32 = @bitCast(std.c.RTLD{
            .LAZY = true,
        });
        mode |= RTLD_DEEPBIND;
        return dynlib.DynLib{
            .inner = .{
                .handle = std.c.dlopen(&path_c, @bitCast(mode)) orelse {
                    return error.FileNotFound;
                },
            },
        };
    } else {
        return dynlib.DynLib.open(path);
    }
}