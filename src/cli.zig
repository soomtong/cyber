const std = @import("std");
const stdx = @import("stdx");
const zt = stdx.testing;
const builtin = @import("builtin");
const build_config = @import("build_config");
const os_mod = @import("std/os.zig");
const test_mod = @import("std/test.zig");
const cache = @import("cache.zig");
const C = @import("capi.zig");
const log = std.log.scoped(.cli);
const http = @import("http.zig");
const NullId = std.math.maxInt(u32);
const vmc = @import("vmc");
const malloc = build_config.malloc;
const is_wasm = builtin.target.cpu.arch.isWasm();
const is_wasm_freestanding = is_wasm and builtin.target.os.tag == .freestanding;
const mi = @import("mimalloc");

pub const Src = @embedFile("std/cli.cy");

const funcs = [_]struct { []const u8, C.BindFunc }{
    .{ "replReadLine", zErrFunc(replReadLine) },
};

pub fn bind(_: ?*C.VM, mod: ?*C.Sym) callconv(.c) C.Bytes {
    for (funcs) |e| {
        C.mod_add_func(mod.?, e.@"0", e.@"1");
    }
    return C.to_bytes("");
}

const Config = struct {
    /// Whether url imports and cached assets should be reloaded.
    reload: bool = false,
};

/// A standard module of the CLI. The source is embedded in the executable, so the CLI does not read `src/` from disk.
const StdMod = struct {
    /// Source of a module whose bind function does not return it.
    src: []const u8 = "",
    bind_fn: C.ModuleBindFn = null,
};

const StdEntry = struct { []const u8, StdMod };

/// Modules that any chunk can import by name (`use os`). The name is also the chunk uri, the same as in the library's
/// default loader (`compiler.default_loader`).
const named_std_mods = [_]StdEntry{
    .{ "core", .{ .bind_fn = C.mod_bind_core } },
    .{ "meta", .{ .bind_fn = C.mod_bind_meta } },
    .{ "math", .{ .bind_fn = C.mod_bind_math } },
    .{ "cy", .{ .bind_fn = C.mod_bind_cy } },
    .{ "c", .{ .bind_fn = C.mod_bind_c } },
    .{ "io", .{ .bind_fn = C.mod_bind_io } },
    .{ "test", .{ .bind_fn = C.mod_bind_test } },
    .{ "libc", .{ .src = @embedFile("std/libc.cy") } },
    .{ "os", .{ .src = os_mod.Src, .bind_fn = &os_mod.bind } },
    .{ "cli", .{ .src = Src, .bind_fn = &bind } },
};

/// Platform modules. Only a standard module can import them, by a path relative to its own uri
/// (`use macos 'os.macos.cy'`). They are imported behind `#[cond=meta.system() == ...]`, so each target embeds its own.
const platform_std_mods: []const StdEntry = switch (builtin.target.os.tag) {
    .macos => &.{
        .{ "os.macos.cy", .{ .src = @embedFile("std/os.macos.cy") } },
        .{ "libc.macos.cy", .{ .src = @embedFile("std/libc.macos.cy") } },
    },
    .linux => &.{
        .{ "os.linux.cy", .{ .src = @embedFile("std/os.linux.cy") } },
        .{ "libc.linux.cy", .{ .src = @embedFile("std/libc.linux.cy") } },
    },
    .windows => &.{
        .{ "os.windows.cy", .{ .src = @embedFile("std/os.windows.cy") } },
        .{ "windows/windows.cy", .{ .src = @embedFile("std/windows/windows.cy") } },
        .{ "windows/kernel32.cy", .{ .src = @embedFile("std/windows/kernel32.cy") } },
    },
    else => &.{},
};

const std_mods = std.StaticStringMap(StdMod).initComptime(named_std_mods ++ platform_std_mods);

pub const App = struct {
    alloc: std.mem.Allocator,
    config: Config,

    /// Interface used for imports and fetch.
    httpClient: http.HttpClient,
    stdHttpClient: if (!is_wasm) *http.StdHttpClient else void,

    /// Import name to chunk uri, for names that resolve without looking at the file system.
    mod_uris: std.StringHashMapUnmanaged([]const u8) = .empty,

    pub fn deinit(self: *App) void {
        self.mod_uris.deinit(self.alloc);
    }
};

pub fn init_cli(vm: *C.VM, alloc: std.mem.Allocator) !void {
    const app = try alloc.create(App);
    app.* = .{
        .config = .{},
        .alloc = alloc,
        .httpClient = undefined,
        .stdHttpClient = undefined,
    };

    for (named_std_mods) |mod| {
        try app.mod_uris.putNoClobber(alloc, mod[0], mod[0]);
    }

    if (!is_wasm) {
        app.stdHttpClient = try alloc.create(http.StdHttpClient);
        app.stdHttpClient.* = http.StdHttpClient.init(alloc);
        app.httpClient = app.stdHttpClient.iface();
    }
    C.vm_set_user_data(vm, app);

    C.vm_set_resolver(vm, resolver);
    C.vm_set_dl_resolver(vm, dl_resolver);
    C.vm_set_loader(vm, loader);
    C.vm_set_printer(vm, print);
    C.vm_set_eprinter(vm, err_);
    C.vm_set_logger(vm, logFn);
    C.set_logger(global_logger);
}

pub fn deinit_cli(vm: *C.VM) void {
    const app: *App = @ptrCast(@alignCast(C.vm_user_data(vm)));
    app.deinit();
    const alloc = app.alloc;

    if (!is_wasm) {
        app.httpClient.deinit();
        alloc.destroy(app.stdHttpClient);
    }

    alloc.destroy(app);
}

pub fn set_new_mock_http(vm: *C.VM) !*anyopaque {
    const app: *App = @ptrCast(@alignCast(C.vm_user_data(vm)));
    const client = try app.alloc.create(http.MockHttpClient);
    client.* = http.MockHttpClient.init(app.alloc);
    app.httpClient = client.iface();
    return client;
}

// Thread-safe.
fn logFn(_: ?*C.VM, str: C.Bytes) callconv(.c) void {
    std.debug.print("{s}\n", .{C.from_bytes(str)});
}

fn global_logger(str: C.Bytes) callconv(.c) void {
    std.debug.print("{s}\n", .{C.from_bytes(str)});
}

// Not thread-safe.
fn err_(_: ?*C.Thread, str: C.Bytes) callconv(.c) void {
    if (C.silent()) {
        return;
    }
    std.Io.File.stderr().writeStreamingAll(stdx.io(), C.from_bytes(str)) catch @panic("error");
}

// Not thread-safe.
fn print(_: ?*C.Thread, str: C.Bytes) callconv(.c) void {
    // Temporarily redirect to error for tests to avoid hanging the Zig runner.
    if (builtin.is_test) {
        const slice = C.from_bytes(str);
        std.Io.File.stderr().writeStreamingAll(stdx.io(), slice) catch @panic("error");
        return;
    }

    const slice = C.from_bytes(str);
    std.Io.File.stdout().writeStreamingAll(stdx.io(), slice) catch @panic("error");
}

pub fn loader(vm_: ?*C.VM, mod_: ?*C.Sym, spec_: C.Bytes, res: [*c]C.LoaderResult) callconv(.c) bool {
    const vm = vm_.?;
    const spec = C.from_bytes(spec_);

    const app: *App = @ptrCast(@alignCast(C.vm_user_data(vm)));
    if (std_mods.get(spec)) |mod| {
        var src = mod.src;
        if (mod.bind_fn) |bind_fn| {
            const bound_src = C.from_bytes(bind_fn(vm_, mod_));
            if (src.len == 0) {
                src = bound_src;
            }
        }
        res[0] = .{
            .src = C.to_bytes(src),
            .manage_src = false,
        };
        return true;
    }

    if (is_wasm_freestanding) {
        return false;
    }

    // Load from file or http.
    var src: []const u8 = undefined;
    if (std.mem.startsWith(u8, spec, "http://") or std.mem.startsWith(u8, spec, "https://")) {
        src = loadUrl(vm, app.alloc, spec) catch |e| {
            if (e == error.HandledError) {
                return false;
            } else {
                const msg = app.alloc.print("Can not load `{s}`. {}", .{ spec, e }) catch return false;
                defer app.alloc.free(msg);
                C.reportApiError(@ptrCast(vm), C.to_bytes(msg));
                return false;
            }
        };
    } else {
        src = std.Io.Dir.cwd().readFileAlloc(stdx.io(), spec, app.alloc, .limited(1e9)) catch |e| {
            const msg = app.alloc.print("Can not load `{s}`. {}", .{ spec, e }) catch return false;
            defer app.alloc.free(msg);
            C.reportApiError(@ptrCast(vm), C.to_bytes(msg));
            return false;
        };
    }

    res[0] = .{
        .src = C.to_bytes(src),
        .manage_src = true,
    };
    return true;
}

fn dl_resolver(vm: ?*C.VM, uri: C.Bytes, out: [*c]C.Bytes) callconv(.c) bool {
    if (std.mem.startsWith(u8, C.from_bytes(uri), "https://")) {
        const final_path = os_mod.allocCacheUrl(vm.?, C.from_bytes(uri)) catch @panic("error");
        out[0] = C.to_bytes(final_path);
        return true;
    }
    const final_uri = C.vm_allocb(vm.?, uri.len);
    @memcpy(final_uri, C.from_bytes(uri));
    out[0] = C.to_bytes(final_uri);
    return true;
}

fn resolver(vm_: ?*C.VM, params: C.ResolverParams, res_uri_len: ?*usize) callconv(.c) bool {
    const vm: *C.VM = @ptrCast(vm_);
    const uri = C.from_bytes(params.uri);

    const app: *App = @ptrCast(@alignCast(C.vm_user_data(vm)));

    var cur_uri: []const u8 = "";
    if (app.mod_uris.get(uri)) |abs_path| {
        const out = params.buf[0..params.bufLen];
        const res = std.mem.print(out, "{s}", .{abs_path}) catch @panic("error");
        res_uri_len.?.* = res.len;
        return true;
    } else {
        if (params.chunkId != NullId) {
            cur_uri = C.from_bytes(params.curUri);
        }
    }

    if (std_mods.has(cur_uri)) {
        // A standard module imports a platform module. Both are embedded, so the path is joined to the importer's
        // uri without looking at the file system.
        const out = params.buf[0..params.bufLen];
        const res = if (std.mem.lastIndexOfScalar(u8, cur_uri, '/')) |idx|
            std.mem.print(out, "{s}/{s}", .{ cur_uri[0..idx], uri }) catch @panic("error")
        else
            std.mem.print(out, "{s}", .{uri}) catch @panic("error");
        if (!std_mods.has(res)) {
            const msg = app.alloc.print("Standard module `{s}` does not have the module `{s}`.", .{ cur_uri, uri }) catch return false;
            defer app.alloc.free(msg);
            C.reportApiError(@ptrCast(vm), C.to_bytes(msg));
            return false;
        }
        res_uri_len.?.* = res.len;
        return true;
    }

    const r_uri = zResolve(vm, app.alloc, params.chunkId, params.buf[0..params.bufLen], cur_uri, uri) catch |e| {
        if (e == error.HandledError) {
            return false;
        } else {
            const msg = app.alloc.print("Resolve module `{s}`, error: `{}`", .{ uri, e }) catch return false;
            defer app.alloc.free(msg);
            C.reportApiError(@ptrCast(vm), C.to_bytes(msg));
            return false;
        }
    };

    res_uri_len.?.* = r_uri.len;
    return true;
}

fn zResolve(vm: *C.VM, alloc: std.mem.Allocator, chunkId: u32, buf: []u8, cur_uri: []const u8, spec: []const u8) ![]const u8 {
    _ = chunkId;
    if (std.mem.startsWith(u8, spec, "http://") or std.mem.startsWith(u8, spec, "https://")) {
        const uri = try std.Uri.parse(spec);
        if (std.mem.endsWith(u8, uri.host.?.percent_encoded, "github.com")) {
            if (std.mem.count(u8, uri.path.percent_encoded, "/") == 2 and uri.path.percent_encoded[uri.path.percent_encoded.len - 1] != '/') {
                var w: std.Io.Writer = .fixed(buf);

                try w.writeAll(uri.scheme);
                try w.writeAll("://raw.githubusercontent.com");
                try w.writeAll(uri.path.percent_encoded);
                try w.writeAll("/master/mod.cy");
                std.debug.print("{s}\n", .{w.buffered()});
                return w.buffered();
            }
        }
        // The caller reads the result from `buf` and only takes its length from here.
        if (spec.len > buf.len) return error.NameTooLong;
        @memcpy(buf[0..spec.len], spec);
        return buf[0..spec.len];
    }

    var pathBuf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&pathBuf);
    if (cur_uri.len > 0) b: {
        // Create path from the current script.
        // There should always be a parent directory since `curUri` should be absolute when dealing with file modules.
        const dir = std.Io.Dir.path.dirname(cur_uri) orelse {
            // Likely from an in-memory chunk uri such as `main` or `input` (repl).
            try w.writeAll(spec);
            break :b;
        };
        try w.print("{s}/{s}", .{ dir, spec });
    } else {
        try w.writeAll(spec);
    }
    const path = w.buffered();

    // Get canonical path.
    const absPath = realpath(std.Io.Dir.cwd(), path, buf) catch |e| {
        if (e == error.FileNotFound) {
            const msg = try alloc.print("Import path does not exist: `{s}`", .{path});
            if (builtin.target.os.tag == .windows) {
                _ = std.mem.replaceScalar(u8, msg, '/', '\\');
            }
            defer alloc.free(msg);
            C.reportApiError(@ptrCast(vm), C.to_bytes(msg));
            return error.HandledError;
        } else {
            return e;
        }
    };
    return absPath;
}

fn realpath(cwd: std.Io.Dir, path: []const u8, out: []u8) ![]u8 {
    if (is_wasm and builtin.target.os.tag == .wasi) {
        return wasi_realpath(cwd, path, out);
    } else {
        const len = try cwd.realPathFile(stdx.io(), path, out);
        return out[0..len];
    }
}

// TODO: Emulate realpath.
fn wasi_realpath(cwd: std.Io.Dir, path: []const u8, out: []u8) ![]u8 {
    var w = std.Io.Writer.fixed(out);
    if (path.len == 0 or path[0] != '/') {
        var prestat: std.os.wasi.prestat_t = undefined;

        if (std.os.wasi.fd_prestat_get(cwd.handle, &prestat) != .SUCCESS) {
            return error.MissingCwd;
        }

        var buf: [1024]u8 = undefined;
        const len = prestat.u.dir.pr_name_len;
        if (len > buf.len) return error.NameTooLong;

        if (std.os.wasi.fd_prestat_dir_name(cwd.handle, @ptrCast(&buf[0]), len) != .SUCCESS) {
            return error.MissingCwd;
        }
        try w.writeAll(buf[0..len]);
    }
    try w.writeAll(path);
    return w.buffered();
}

fn loadUrl(vm: *C.VM, alloc: std.mem.Allocator, url: []const u8) ![]const u8 {
    const specGroup = try cache.getSpecHashGroup(alloc, url);
    defer specGroup.deinit(alloc);

    const a: *App = @ptrCast(@alignCast(C.vm_user_data(vm)));

    if (a.config.reload) {
        // Remove cache entry.
        try specGroup.markEntryBySpecForRemoval(url);
    } else {
        // First check local cache.
        if (try specGroup.findEntryBySpec(url)) |entry| {
            var found = true;
            const src = cache.allocSpecFileContents(alloc, entry) catch |e| b: {
                if (e == error.FileNotFound) {
                    // Fallthrough.
                    found = false;
                    break :b "";
                } else {
                    return e;
                }
            };
            if (found) {
                if (C.verbose()) {
                    const cachePath = try cache.allocSpecFilePath(alloc, entry);
                    defer alloc.free(cachePath);
                    std.debug.print("Using cached `{s}` at `{s}`.\n", .{ url, cachePath });
                }
                return src;
            }
        }
    }

    const client = a.httpClient;

    if (C.verbose()) {
        std.debug.print("Fetching `{s}`.\n", .{url});
    }

    const uri = try std.Uri.parse(url);
    const res = client.fetch(alloc, .GET, uri, .{}) catch |e| {
        if (e == error.UnknownHostName) {
            const msg = try alloc.print("Can not connect to `{s}`.", .{uri.host.?.percent_encoded});
            defer alloc.free(msg);
            C.reportApiError(@ptrCast(vm), C.to_bytes(msg));
            return error.HandledError;
        } else {
            return e;
        }
    };
    errdefer alloc.free(res.body);

    if (res.status != .ok) {
        // Stop immediately.
        const e = try alloc.print("Can not load `{s}`. Response code: {}", .{ url, res.status });
        defer alloc.free(e);
        C.reportApiError(@ptrCast(vm), C.to_bytes(e));
        return error.HandledError;
    }

    // Cache to local.
    const entry = try cache.saveNewSpecFile(alloc, specGroup, url, res.body);
    entry.deinit(alloc);

    return res.body;
}

pub const use_ln = builtin.target.os.tag != .windows and builtin.target.os.tag != .wasi;
const ln = @import("linenoise");

pub fn replReadLine(t: *C.Thread) anyerror!C.Ret {
    const ret = C.thread_ret(t, C.str);

    const alloc = C.thread_allocator(t);

    var prefix = C.thread_param(t, C.str);
    defer C.str_deinit(t, &prefix);
    const prefix_dup = try alloc.dupeSentinel(u8, C.str_bytes(prefix), 0);
    defer alloc.free(prefix_dup);
    if (use_ln) {
        const line = LnReadLine.read(undefined, prefix_dup) catch |err| {
            if (err == error.EndOfStream) return repl_end_of_input(t, ret);
            return err;
        };
        defer LnReadLine.free(undefined, line);
        ret.* = C.str_init(t, line);
    } else {
        var read_line = FallbackReadLine{
            .alloc = alloc,
        };
        const line = FallbackReadLine.read(&read_line, prefix_dup) catch |err| {
            if (err == error.EndOfStream) return repl_end_of_input(t, ret);
            return err;
        };
        defer FallbackReadLine.free(&read_line, line);
        ret.* = C.str_init(t, line);
    }
    return C.RetOk;
}

/// End of input (Ctrl-D, or a piped stdin that ran out) ends the REPL like `.exit`.
fn repl_end_of_input(t: *C.Thread, ret: *C.str) C.Ret {
    ret.* = C.str_init(t, ".exit");
    return C.RetOk;
}

pub const LnReadLine = struct {
    pub fn read(ptr: *anyopaque, prefix: [:0]const u8) anyerror![]const u8 {
        _ = ptr;
        const linez = ln.linenoise(prefix);
        if (linez == null) {
            return error.EndOfStream;
        }
        _ = ln.linenoiseHistoryAdd(linez);
        return std.mem.sliceTo(linez, 0);
    }

    pub fn free(ptr: *anyopaque, line: []const u8) void {
        _ = ptr;
        ln.linenoiseFree(@constCast(line.ptr));
    }
};

pub const FallbackReadLine = struct {
    alloc: std.mem.Allocator,

    pub fn read(ptr: *anyopaque, prefix: [:0]const u8) anyerror![]const u8 {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        try std.Io.File.stdout().writeStreamingAll(stdx.io(), prefix);
        // Read one line, one byte at a time, so no input past the newline is consumed.
        var line: std.ArrayList(u8) = .empty;
        errdefer line.deinit(self.alloc);
        const stdin = std.Io.File.stdin();
        while (true) {
            var byte: [1]u8 = undefined;
            const n = stdin.readStreaming(stdx.io(), &.{&byte}) catch |err| {
                if (err == error.EndOfStream) {
                    if (line.items.len == 0) return error.EndOfStream;
                    break;
                }
                return err;
            };
            if (n == 0) continue;
            if (byte[0] == '\n') break;
            try line.append(self.alloc, byte[0]);
        }
        if (line.items.len > 0 and line.items[line.items.len - 1] == '\r') {
            line.items.len -= 1;
        }
        return line.toOwnedSlice(self.alloc);
    }

    pub fn free(ptr: *anyopaque, line: []const u8) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.alloc.free(line);
    }
};

test "Stack traces." {
    if (!is_wasm) {
        const vm = C.vm_initx(zt.alloc);
        defer C.vm_deinit(vm);

        try init_cli(vm, zt.alloc);
        defer deinit_cli(vm);

        // panic from global init in another module.
        var res: C.EvalResult = undefined;
        const config = C.defaultEvalConfig();
        const code = C.vm_evalx(vm, "./src/test/main.cy",
            \\use a 'modules/test_mods/init_panic_error.cy'
            \\use t 'test'
            \\t.eq(a.foo, 123)
        , config, &res);

        try zt.eq(C.ErrorPanic, code);
        const thread = C.vm_main_thread(vm);
        {
            const report = C.thread_panic_summary(thread);
            defer C.vm_freeb(vm, report);

            const root = build_config.mod_root.?;
            const sep = if (builtin.target.os.tag == .windows) "\\" else "/";
            const exp = try zt.alloc.print(
                \\panic: boom
                \\
                \\{s}{s}src{s}test{s}modules{s}test_mods{s}init_panic_error.cy:1:18 @init:
                \\global foo int = panic('boom')
                \\                 ^
                \\{s}{s}src{s}test{s}main.cy: @program_init
                \\{s}{s}src{s}test{s}main.cy: main
                \\
            , .{ root, sep, sep, sep, sep, sep, root, sep, sep, sep, root, sep, sep, sep });
            defer zt.alloc.free(exp);
            try zt.eqStr(exp, report);
        }

        const trace = C.thread_panic_trace(thread);
        try zt.eq(trace.frames_len, 3);
        try eqStackFrame(trace.frames[0], .{
            .name = C.to_bytes("@init"),
            .chunk = 3,
            .line = 0,
            .col = 17,
            .line_pos = 0,
        });
        try eqStackFrame(trace.frames[1], .{
            .name = C.to_bytes("@program_init"),
            .chunk = 0,
            .line = 0,
            .col = 0,
            .line_pos = NullId,
        });
        try eqStackFrame(trace.frames[2], .{
            .name = C.to_bytes("main"),
            .chunk = 0,
            .line = 0,
            .col = 0,
            .line_pos = NullId,
        });
    }
}

fn eqStackFrame(act: C.StackFrame, exp: C.StackFrame) !void {
    try zt.eqStr(C.from_bytes(act.name), C.from_bytes(exp.name));
    try zt.eq(exp.chunk, act.chunk);
    try zt.eq(exp.line, act.line);
    try zt.eq(exp.col, act.col);
    try zt.eq(exp.line_pos, act.line_pos);
}

// test "Import http spec." {
//     if (is_wasm) {
//         return;
//     }

//     var run = try VMrunner.init();
//     defer run.deinit();

//     const vm = run.internal();

//     const basePath = try std.fs.realpathAlloc(t.alloc, ".");
//     defer t.alloc.free(basePath);

//     // Import error.UnknownHostName.
//     var client: *http.MockHttpClient = @ptrCast(@alignCast(c.setNewMockHttp(@ptrCast(vm))));
//     client.retReqError = .UnknownHostName;
//     try run.eval(Config.initFileModules("./test/modules/import.cy").withSilent().withReload(),
//         \\use a 'https://doesnotexist123.com/'
//         \\b = a
//     , struct { fn func(run_: *VMrunner, res: EvalResult) !void {
//         try run_.expectErrorReport(res, c.ErrorCompile,
//             \\CompileError: Can not connect to `doesnotexist123.com`.
//             \\
//             \\@AbsPath(test/modules/import.cy):1:7:
//             \\use a 'https://doesnotexist123.com/'
//             \\      ^
//             \\
//         );
//     }}.func);
//     vm.alloc.destroy(client);

//     // Import NotFound response code.
//     client = @ptrCast(@alignCast(c.setNewMockHttp(@ptrCast(vm))));
//     client.retStatusCode = std.http.Status.not_found;
//     try run.eval(Config.initFileModules("./test/modules/import.cy").withSilent().withReload(),
//         \\use a 'https://exists.com/missing'
//         \\b = a
//     , struct { fn func(run_: *VMrunner, res: EvalResult) !void {
//         try run_.expectErrorReport(res, c.ErrorCompile,
//             \\CompileError: Can not load `https://exists.com/missing`. Response code: not_found
//             \\
//             \\@AbsPath(test/modules/import.cy):1:7:
//             \\use a 'https://exists.com/missing'
//             \\      ^
//             \\
//         );

//     }}.func);
//     vm.alloc.destroy(client);

//     // Successful import.
//     client = @ptrCast(@alignCast(c.setNewMockHttp(@ptrCast(vm))));
//     client.retBody =
//         \\var .foo = 123
//         ;
//     _ = try run.evalPass(Config.initFileModules("./test/modules/import.cy").withReload(),
//         \\use a 'https://exists.com/a.cy'
//         \\use t 'test'
//         \\t.eq(a.foo, 123)
//     );
//     vm.alloc.destroy(client);
// }

pub fn tracev(comptime format: []const u8, args: anytype) void {
    if (build_config.trace and C.verbose()) {
        std.debug.print(format, args);
    }
}

pub fn zErrFunc(comptime f: fn (t: *C.Thread) anyerror!C.Ret) C.BindFunc {
    const S = struct {
        pub fn genFunc(t: *C.Thread) callconv(.c) C.Ret {
            return @call(.always_inline, f, .{t}) catch |err| {
                return @call(.never_inline, prepPanicZError, .{ t, err, @errorReturnTrace() });
            };
        }
    };
    return .{
        .kind = C.BindFuncVm,
        .ptr = @ptrCast(@constCast(&S.genFunc)),
    };
}

pub const isFreestanding = builtin.target.os.tag == .freestanding;

pub fn prepPanicZError(t: *C.Thread, err: anyerror, optTrace: ?*std.lang.StackTrace) C.Ret {
    if (!isFreestanding and C.verbose()) {
        std.debug.print("{}", .{err});
        if (optTrace) |trace_| {
            std.debug.dumpErrorReturnTrace(trace_);
        }
    }
    return C.thread_ret_panic(t, @errorName(err));
}

// Backed by the page allocator so freed memory is never reused: SafeAllocator
// relies on that to catch writes after free. The default CLI build uses this
// only in Debug (`-Dmalloc=zig` selects it in other modes).
var gpa: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{
    .stack_trace_frames = if (builtin.mode == .debug) 12 else 0,
});
var miAlloc: mi.Allocator = undefined;
var trace_allocator: TraceAllocator = undefined;
var initedAllocator = false;

fn initAllocator() void {
    defer initedAllocator = true;
    switch (malloc) {
        .zig, .malloc => return,
        .mimalloc => {
            miAlloc.init();
        },
    }
}

pub fn getAllocator() std.mem.Allocator {
    if (!initedAllocator) {
        initAllocator();
    }
    switch (malloc) {
        .mimalloc => {
            return miAlloc.allocator();
        },
        .malloc => {
            return std.heap.c_allocator;
        },
        .zig => {
            if (builtin.is_test) {
                if (build_config.trace) {
                    trace_allocator.alloc_ = zt.alloc;
                    return trace_allocator.allocator();
                } else {
                    return zt.alloc;
                }
            }
            if (is_wasm) {
                return std.heap.wasm_allocator;
            } else {
                return gpa.allocator();
            }
        },
    }
}

pub fn deinitAllocator() void {
    switch (malloc) {
        .mimalloc => {
            miAlloc.deinit();
            initedAllocator = false;
        },
        .malloc => {
            return;
        },
        .zig => {
            if (is_wasm) {
                return;
            } else {
                _ = gpa.deinit();
                initedAllocator = false;
            }
        },
    }
}

// Uses a backing allocator and zeros the freed memory to surface UB more consistently.
pub const TraceAllocator = struct {
    alloc_: std.mem.Allocator,

    const vtable = std.mem.Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .free = free,
        .remap = remap,
    };

    pub fn allocator(self: *TraceAllocator) std.mem.Allocator {
        return std.mem.Allocator{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    fn alloc(ptr: *anyopaque, len: usize, log2_align: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *TraceAllocator = @ptrCast(@alignCast(ptr));
        return self.alloc_.rawAlloc(len, log2_align, ret_addr);
    }

    fn resize(ptr: *anyopaque, buf: []u8, log2_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *TraceAllocator = @ptrCast(@alignCast(ptr));
        return self.alloc_.rawResize(buf, log2_align, new_len, ret_addr);
    }

    fn remap(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *TraceAllocator = @ptrCast(@alignCast(ptr));
        return self.alloc_.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(ptr: *anyopaque, buf: []u8, log2_align: std.mem.Alignment, ret_addr: usize) void {
        const self: *TraceAllocator = @ptrCast(@alignCast(ptr));
        @memset(buf, 0);
        return self.alloc_.rawFree(buf, log2_align, ret_addr);
    }
};
