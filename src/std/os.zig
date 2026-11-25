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

    var env_map: ?std.process.Environ.Map = if (inherits_current_env) null else try currentEnvMap(alloc);
    defer if (env_map) |*map| map.deinit();

    const res = try std.process.run(alloc, stdx.io(), .{
        .argv = buf.items,
        .environ_map = if (env_map) |*map| map else null,
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

/// Whether a child that is given no environment gets the environment of this process as it is now.
/// On Windows it does. Where libc holds the environment it does not: the `Io` instance remembers the block that
/// it read when it was built, and `setenv` moves `environ` to a new array, so the variables that `os.set_env`
/// has set since are missing. There a child is given `currentEnvMap`.
const inherits_current_env = builtin.os.tag == .windows;

/// The environment of this process as it is now.
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
    /// The time limit of the command passed and its stages were stopped.
    timed_out = 10,
    /// The host asked the VM to stop and the stages were stopped. The caller loops so that its checkpoint stops the VM.
    interrupted = 11,
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

/// Where a stream of a stage goes to or comes from when it is not a pipe of the pipeline.
/// Mirrored by `CmdIo` in `os.cy`.
const CmdIo = enum(i64) {
    /// What the mode says: inherited, captured or empty.
    default = 0,
    /// stdin: the input text. Not used for an output.
    text = 1,
    /// A file: read for stdin, created or emptied for an output.
    file = 2,
    /// An output file that is created or added to.
    append = 3,
};

const CmdStage = struct {
    argv: []const []const u8,
    cwd: []const u8,
    /// Name and value pairs.
    env: []const C.str,
    err_io: CmdIo,
    err_path: []const u8,
};

/// What a command does with its first stdin and last stdout, and how long it may run.
const CmdOptions = struct {
    in_io: CmdIo,
    /// The text for `.text`, the path for `.file`.
    in: []const u8,
    out_io: CmdIo,
    out_path: []const u8,
    /// 0 for no time limit.
    timeout_ms: i64,
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
        error.CmdTimedOut => .timed_out,
        error.CmdInterrupted => .interrupted,
        error.IsDir => .is_a_directory,
        error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded => .too_many_open_files,
        error.OutOfMemory, error.SystemResources => .out_of_memory,
        else => .unknown,
    };
}

/// Runs the pipeline of an `os.Cmd`. The command is described by flat spans so that nothing is copied:
/// `args` holds the arguments of all stages, `counts` three numbers per stage (arguments, environment pairs, the
/// `CmdIo` of its stderr), `dirs` one working directory per stage (empty to inherit), `envs` the name and value
/// pairs of all stages, `errs` one stderr path per stage (empty when it is not a file), `texts` the stdin text or
/// path and the stdout path, and `opts` the `CmdIo` of stdin, the `CmdIo` of stdout and the time limit in ms.
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
    const errs_span = C.thread_param(t, StrSpan);
    const texts_span = C.thread_param(t, StrSpan);
    const opts_span = C.thread_param(t, IntSpan);
    const mode: CmdMode = @enumFromInt(C.thread_int(t));

    const args = args_span.ptr[0..@intCast(args_span.len)];
    const counts = counts_span.ptr[0..@intCast(counts_span.len)];
    const dirs = dirs_span.ptr[0..@intCast(dirs_span.len)];
    const envs = envs_span.ptr[0..@intCast(envs_span.len)];
    const errs = errs_span.ptr[0..@intCast(errs_span.len)];
    const texts = texts_span.ptr[0..@intCast(texts_span.len)];
    const opts = opts_span.ptr[0..@intCast(opts_span.len)];

    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out: CmdOutput = .{};
    defer alloc.free(out.out);
    defer alloc.free(out.err);

    const nstages = dirs.len;
    var fail: CmdFail = .none;
    if (nstages == 0 or nstages > cmd_max_stages or counts.len != nstages * 3 or errs.len != nstages or
        texts.len != 2 or opts.len != 3)
    {
        fail = .invalid_argument;
    } else {
        const options: CmdOptions = .{
            .in_io = cmdIo(opts[0]) orelse .text,
            .in = C.str_bytes(texts[0]),
            .out_io = cmdIo(opts[1]) orelse .text,
            .out_path = C.str_bytes(texts[1]),
            .timeout_ms = opts[2],
        };
        if (options.in_io == .append or options.out_io == .text or options.timeout_ms < 0) fail = .invalid_argument;
        if (options.in_io == .file and !cmdValidPath(options.in)) fail = .invalid_argument;
        if (options.out_io != .default and !cmdValidPath(options.out_path)) fail = .invalid_argument;

        const stages = try arena.alloc(CmdStage, nstages);
        var arg_i: usize = 0;
        var env_i: usize = 0;
        for (stages, 0..) |*stage, i| {
            const nargs: usize = @intCast(counts[i * 3]);
            const nenv: usize = @intCast(counts[i * 3 + 1]);
            const err_io = cmdIo(counts[i * 3 + 2]) orelse .text;
            const argv = try arena.alloc([]const u8, nargs);
            for (argv, args[arg_i..][0..nargs]) |*dst, arg| dst.* = C.str_bytes(arg);
            // A program name is required, and a NUL would cut an argument short.
            if (nargs == 0 or argv[0].len == 0) fail = .invalid_argument;
            for (argv) |arg| {
                if (std.mem.indexOfScalar(u8, arg, 0) != null) fail = .invalid_argument;
            }
            const err_path = C.str_bytes(errs[i]);
            if (err_io == .text or (err_io != .default and !cmdValidPath(err_path))) fail = .invalid_argument;
            stage.* = .{
                .argv = argv,
                .cwd = C.str_bytes(dirs[i]),
                .env = envs[env_i..][0 .. nenv * 2],
                .err_io = err_io,
                .err_path = err_path,
            };
            arg_i += nargs;
            env_i += nenv * 2;
        }
        if (fail == .none) {
            cmdRunPipeline(alloc, arena, stages, options, mode, t, &out) catch |err| {
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

fn cmdIo(n: i64) ?CmdIo {
    if (n < 0 or n > @intFromEnum(CmdIo.append)) return null;
    return @enumFromInt(n);
}

/// A path names a file: it is not empty and a NUL does not cut it short.
fn cmdValidPath(path: []const u8) bool {
    return path.len > 0 and std.mem.indexOfScalar(u8, path, 0) == null;
}

/// Writes the input text to the stdin of the first stage and closes it, on a thread of its own: the stage may
/// not read its input before its output is read, and a pipe holds only so much.
fn cmdFeedInput(file: std.Io.File, bytes: []const u8) void {
    const io = stdx.io();
    // A stage that exits without reading its input makes the write fail with `SIGPIPE`, which would end this
    // process. The write must return an error instead, without a change that another thread or a stage sees:
    // a signal mask is inherited by the programs that a thread starts.
    if (comptime builtin.os.tag.isDarwin()) {
        // Per descriptor. `sigprocmask` is not used here: on Darwin it sets the mask of every thread of the
        // process, and the stages that the other threads start afterwards would have `SIGPIPE` blocked.
        _ = std.c.fcntl(file.handle, std.c.F.SETNOSIGPIPE, @as(c_int, 1));
    } else if (builtin.os.tag != .windows) {
        // Blocked on this thread only, the signal goes away with the thread.
        var set = std.posix.sigemptyset();
        std.posix.sigaddset(&set, .PIPE);
        if (builtin.link_libc) {
            var old: std.posix.sigset_t = undefined;
            _ = std.c.pthread_sigmask(std.posix.SIG.BLOCK, &set, &old);
        } else {
            // Without libc this is the system call, which sets the mask of the calling thread.
            std.posix.sigprocmask(std.posix.SIG.BLOCK, &set, null);
        }
    }
    file.writeStreamingAll(io, bytes) catch {};
    file.close(io);
}

fn cmdDoNothingSignalHandler(_: std.posix.SIG) callconv(.c) void {}

/// A program keeps an ignored `SIGPIPE` when it is started, and a handler is set back to the default action.
/// When this process ignores the signal, a stage in front of one that closes its input (`yes` before `head`)
/// is not stopped by the signal: its write fails and it ends with an error status, so the pipeline would fail.
/// A handler that does nothing is the same to this process (a write to a closed pipe returns an error) and
/// gives the stages the default action. `std.Io.Threaded.init` does the same for the processes it starts.
/// The default action and a handler of the host are left alone.
fn cmdLetStagesGetSigpipe() void {
    if (builtin.os.tag == .windows) return;
    var old: std.posix.Sigaction = undefined;
    std.posix.sigaction(.PIPE, null, &old);
    if (old.handler.handler != std.posix.SIG.IGN) return;
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = cmdDoNothingSignalHandler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.PIPE, &act, null);
}

/// How often the watch of a running command looks at the interrupt request of the VM, in milliseconds.
const cmd_watch_ms = 20;
/// How long the reading of the output waits before it looks whether the watch stopped the stages, in ms.
/// A program that a stage started may keep the pipe open after the stage is stopped.
const cmd_read_poll_ms = 50;

/// Watches the stages of a running command from a thread of its own, and stops them when the time limit passes
/// or the host asks the VM to stop. The thread that runs the command is blocked meanwhile, in a read or a wait.
/// A stage is stopped only before the running thread has seen it end: once it has, the running thread may reap
/// it, and its id may then name another process.
const CmdWatch = struct {
    /// The thread of the VM that runs the command, for its interrupt request.
    thread: *C.Thread,
    deadline: ?std.Io.Clock.Timestamp,
    children: []std.process.Child,
    mutex: std.Io.Mutex = .init,
    /// Set by the running thread when the stages have ended, or on an error. The watch ends.
    done: std.Io.Event = .unset,
    /// The stages that the running thread has seen end. Guarded by `mutex`.
    ended: [cmd_max_stages]bool = @splat(false),
    /// `CmdFail.none` while the stages run, `.timed_out` or `.interrupted` once the watch has stopped them.
    stopped: std.atomic.Value(CmdFail) = .init(.none),

    fn run(w: *CmdWatch) void {
        const io = stdx.io();
        while (true) {
            var until = std.Io.Clock.Timestamp.fromNow(io, .{ .raw = .fromMilliseconds(cmd_watch_ms), .clock = .awake });
            if (w.deadline) |deadline| {
                if (deadline.compare(.lt, until)) until = deadline;
            }
            if (w.done.waitTimeout(io, .{ .deadline = until })) |_| {
                return;
            } else |err| switch (err) {
                error.Timeout => {},
                error.Canceled => return,
            }
            var why: CmdFail = .none;
            if (C.thread_interrupted(w.thread)) {
                why = .interrupted;
            } else if (w.deadline) |deadline| {
                if (std.Io.Clock.Timestamp.now(io, .awake).compare(.gte, deadline)) why = .timed_out;
            }
            if (why != .none) {
                w.mutex.lockUncancelable(io);
                defer w.mutex.unlock(io);
                w.stopped.store(why, .release);
                for (w.children, 0..) |*child, i| {
                    if (!w.ended[i]) cmdTerminate(child);
                }
                return;
            }
        }
    }

    /// Records that the running thread saw stage `i` end, so that the watch leaves it alone.
    fn markEnded(w: *CmdWatch, io: std.Io, i: usize) void {
        w.mutex.lockUncancelable(io);
        defer w.mutex.unlock(io);
        w.ended[i] = true;
    }

    /// The error that the running thread returns when the watch stopped the stages.
    fn check(w: *CmdWatch) !void {
        switch (w.stopped.load(.acquire)) {
            .timed_out => return error.CmdTimedOut,
            .interrupted => return error.CmdInterrupted,
            else => {},
        }
    }
};

/// Ends a stage at once. It is reaped later by `wait` or `kill` of the running thread.
fn cmdTerminate(child: *const std.process.Child) void {
    const id = child.id orelse return;
    if (builtin.os.tag == .windows) {
        _ = std.os.windows.ntdll.NtTerminateProcess(id, @fromBackingInt(1));
    } else {
        std.posix.kill(id, .KILL) catch {};
    }
}

/// Darwin's `waitid`, which `std.c` does not declare.
extern "c" fn waitid(idtype: c_uint, id: c_uint, info: *std.c.siginfo_t, options: c_int) c_int;

/// Blocks until a stage ends, without reaping it: its id stays that of the stage until `wait`.
/// Where this can not be done the watch can not stop the stage while it is waited for.
fn cmdAwaitEnd(child: *const std.process.Child) void {
    const id = child.id orelse return;
    switch (builtin.os.tag) {
        .windows => _ = std.os.windows.ntdll.NtWaitForSingleObject(id, .FALSE, null),
        .linux => {
            const linux = std.os.linux;
            var info: linux.siginfo_t = undefined;
            while (linux.errno(linux.waitid(.PID, id, &info, linux.W.EXITED | linux.W.NOWAIT, null)) == .INTR) {}
        },
        else => if (comptime builtin.os.tag.isDarwin()) {
            // <sys/wait.h>: P_PID, WEXITED, WNOWAIT.
            const P_PID = 1;
            const WEXITED = 0x04;
            const WNOWAIT = 0x20;
            var info: std.c.siginfo_t = undefined;
            while (waitid(P_PID, @intCast(id), &info, WEXITED | WNOWAIT) == -1 and std.posix.errno(-1) == .INTR) {}
        },
    }
}

/// The files of the redirections of a command. A file is opened once for all the stages that name it the same way,
/// so that two stages that write to the same file do not write over each other.
const CmdFiles = struct {
    list: [cmd_max_stages + 2]Entry = undefined,
    len: usize = 0,

    const Entry = struct { path: []const u8, io: CmdIo, file: std.Io.File };

    fn deinit(self: *CmdFiles, io: std.Io) void {
        for (self.list[0..self.len]) |entry| entry.file.close(io);
    }

    fn open(self: *CmdFiles, io: std.Io, path: []const u8, kind: CmdIo) !std.Io.File {
        for (self.list[0..self.len]) |entry| {
            if (entry.io == kind and std.mem.eql(u8, entry.path, path)) return entry.file;
        }
        const file = try cmdOpenOutput(io, path, kind);
        self.list[self.len] = .{ .path = path, .io = kind, .file = file };
        self.len += 1;
        return file;
    }

    fn openInput(self: *CmdFiles, io: std.Io, path: []const u8) !std.Io.File {
        const file = try std.Io.Dir.cwd().openFile(io, path, .{});
        // `.default` is never an output kind, so the entry is not shared with one.
        self.list[self.len] = .{ .path = path, .io = .default, .file = file };
        self.len += 1;
        return file;
    }
};

const FILE_END = 2;
extern "kernel32" fn SetFilePointerEx(file: std.os.windows.HANDLE, distance: i64, new_pos: ?*i64, method: u32) callconv(.winapi) std.os.windows.BOOL;

/// Opens an output file: emptied for `.file`, added to for `.append`. Created when it does not exist.
fn cmdOpenOutput(io: std.Io, path: []const u8, kind: CmdIo) !std.Io.File {
    if (kind != .append) return std.Io.Dir.cwd().createFile(io, path, .{});
    if (builtin.os.tag == .windows) {
        const file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = false });
        errdefer file.close(io);
        if (SetFilePointerEx(file.handle, 0, null, FILE_END) == .FALSE) return error.Unexpected;
        return file;
    }
    // Every write goes to the end, also when another process adds to the file meanwhile.
    const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .APPEND = true,
        .CLOEXEC = true,
    }, 0o666);
    return .{ .handle = fd, .flags = .{ .nonblocking = false } };
}

fn cmdRunPipeline(alloc: std.mem.Allocator, arena: std.mem.Allocator, stages: []const CmdStage, opts: CmdOptions, mode: CmdMode, t: *C.Thread, out: *CmdOutput) !void {
    const io = stdx.io();
    const n = stages.len;
    if (n > 1) cmdLetStagesGetSigpipe();

    var base_env: ?std.process.Environ.Map = if (inherits_current_env) null else try currentEnvMap(arena);

    // Opened before any stage starts, so that a file that can not be opened starts nothing. Each stage that is
    // given one has its own copy, and these are closed once all have started.
    var files: CmdFiles = .{};
    defer files.deinit(io);
    const in_file: ?std.Io.File = if (opts.in_io == .file) try files.openInput(io, opts.in) else null;
    const out_file: ?std.Io.File = if (opts.out_io != .default) try files.open(io, opts.out_path, opts.out_io) else null;
    var err_files: [cmd_max_stages]?std.Io.File = @splat(null);
    for (stages, 0..) |stage, i| {
        if (stage.err_io != .default) err_files[i] = try files.open(io, stage.err_path, stage.err_io);
    }

    // Declared before the stages so that it is joined after they are stopped: on an error the thread may be
    // writing to a stage that nobody reads from any more, and only the end of that stage lets the write return.
    var feeder: ?std.Thread = null;
    defer if (feeder) |thread| thread.join();

    var children: [cmd_max_stages]std.process.Child = undefined;
    var nspawned: usize = 0;
    // On an error, the stages that started are stopped. After `wait` this does nothing.
    defer for (children[0..nspawned]) |*child| child.kill(io);

    for (stages, 0..) |stage, i| {
        // The variables of the stage go on top of the environment of this process.
        var env_map = base_env;
        if (stage.env.len > 0) {
            if (base_env == null) base_env = try currentEnvMap(arena);
            env_map = try base_env.?.clone(arena);
            var j: usize = 0;
            while (j < stage.env.len) : (j += 2) {
                const name = C.str_bytes(stage.env[j]);
                if (!std.process.Environ.Map.validateKeyForPut(name)) return error.InvalidName;
                try env_map.?.put(name, C.str_bytes(stage.env[j + 1]));
            }
        }

        const child_in: std.process.SpawnOptions.StdIo = if (i > 0)
            .{ .file = children[i - 1].stdout.? }
        else switch (opts.in_io) {
            .text => .pipe,
            .file => .{ .file = in_file.? },
            else => if (mode == .run) .inherit else .ignore,
        };
        const child_out: std.process.SpawnOptions.StdIo = if (i + 1 < n)
            .pipe
        else if (out_file) |file|
            .{ .file = file }
        else if (mode != .run)
            .pipe
        else
            .inherit;
        const child_err: std.process.SpawnOptions.StdIo = if (err_files[i]) |file|
            .{ .file = file }
        else if (mode == .status)
            .pipe
        else
            .inherit;

        children[i] = try std.process.spawn(io, .{
            .argv = stage.argv,
            .cwd = if (stage.cwd.len > 0) .{ .path = stage.cwd } else .inherit,
            .environ_map = if (env_map) |*map| map else null,
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

    if (opts.in_io == .text) {
        const file = children[0].stdin.?;
        children[0].stdin = null;
        feeder = std.Thread.spawn(.{}, cmdFeedInput, .{ file, opts.in }) catch |err| {
            file.close(io);
            return err;
        };
    }

    var watch: CmdWatch = .{
        .thread = t,
        .deadline = if (opts.timeout_ms > 0)
            .fromNow(io, .{ .raw = .fromMilliseconds(opts.timeout_ms), .clock = .awake })
        else
            null,
        .children = children[0..n],
    };
    // Declared after the stages so that it ends before an error stops them.
    var watcher: ?std.Thread = try std.Thread.spawn(.{}, CmdWatch.run, .{&watch});
    defer if (watcher) |thread| {
        watch.done.set(io);
        thread.join();
    };

    // Stream 0 is the stdout of the last stage when it is captured, the others are the captured stderr of the
    // stages in order.
    const capture_out = mode != .run and out_file == null;
    var streams_in: [cmd_max_stages + 1]std.Io.File = undefined;
    var nfiles: usize = 0;
    if (capture_out) {
        streams_in[0] = children[n - 1].stdout.?;
        nfiles = 1;
    }
    const first_err = nfiles;
    if (mode == .status) {
        for (children[0..n]) |child| {
            if (child.stderr) |file| {
                streams_in[nfiles] = file;
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
        multi_reader.init(alloc, io, streams, streams_in[0..nfiles]);
        defer multi_reader.deinit();

        while (true) {
            multi_reader.fill(64, .{ .duration = .{ .raw = .fromMilliseconds(cmd_read_poll_ms), .clock = .awake } }) catch |err| switch (err) {
                error.EndOfStream => break,
                error.Timeout => {
                    try watch.check();
                    continue;
                },
                else => |e| return e,
            };
            if (capture_out and multi_reader.reader(0).buffered().len > cmd_output_limit) return error.StreamTooLong;
            var err_len: usize = 0;
            for (first_err..nfiles) |i| err_len += multi_reader.reader(i).buffered().len;
            if (err_len > cmd_output_limit) return error.StreamTooLong;
        }
        try multi_reader.checkAnyError();
        try watch.check();

        if (capture_out) out.out = try multi_reader.toOwnedSlice(0);
        var err_buf: std.ArrayList(u8) = .empty;
        errdefer err_buf.deinit(alloc);
        for (first_err..nfiles) |i| {
            try err_buf.appendSlice(alloc, multi_reader.reader(i).buffered());
        }
        out.err = try err_buf.toOwnedSlice(alloc);
    }

    for (children[0..n], 0..) |*child, i| {
        cmdAwaitEnd(child);
        watch.markEnded(io, i);
    }
    watch.done.set(io);
    watcher.?.join();
    watcher = null;
    try watch.check();

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