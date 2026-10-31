const std = @import("std");
const Build = std.Build;
const builtin = @import("builtin");
const config_ = @import("src/config.zig");
const mimalloc_lib = @import("lib/mimalloc/lib.zig");
const tcc_lib = @import("lib/tcc/lib.zig");
const Translator = @import("translate_c").Translator;

// FIND: v0.4.2
const Version = "0.4.2";

var optMalloc: ?Allocator = undefined;
var selinux: bool = undefined;
var vmEngine: config_.Engine = undefined;
var testFilter: ?[]const u8 = undefined;
var test_backend: config_.TestBackend = undefined;
var trace: bool = undefined;
var log_mem: bool = undefined;
var no_cache: bool = undefined;
var optFFI: ?bool = undefined;
var optStatic: ?bool = undefined;
var optJIT: ?bool = undefined;
var strip: bool = undefined;
var threads: bool = undefined;

var rtarget: std.Build.ResolvedTarget = undefined;
var target: std.Target = undefined;
var optimize: std.lang.Optimize = undefined;
var dev: bool = undefined;
var isystem: []const []const u8 = undefined;

pub const Allocator = enum {
    zig,
    malloc,
    mimalloc,
};

pub fn build(b: *std.Build) !void {
    rtarget = b.standardTargetOptions(.{});
    target = rtarget.result;
    optimize = b.standardOptimizeOption(.{});

    selinux = b.option(bool, "selinux", "Whether you are building on linux distro with selinux. e.g. Fedora.") orelse false;
    testFilter = b.option([]const u8, "test-filter", "Test filter.");
    test_backend = b.option(config_.TestBackend, "test-backend", "Test compiler backend.") orelse .vm;
    vmEngine = b.option(config_.Engine, "vm", "Build with `zig` or `c` VM.") orelse .c;
    optMalloc = b.option(Allocator, "malloc", "Override default allocator: `malloc`, `mimalloc`, `zig`");
    optFFI = b.option(bool, "ffi", "Override default FFI: true, false");
    optStatic = b.option(bool, "static", "Override default lib build type: true=static, false=dynamic");
    trace = b.option(bool, "trace", "Enable tracing features.") orelse (optimize == .debug);
    optJIT = b.option(bool, "jit", "Build with JIT.");
    log_mem = b.option(bool, "log-mem", "Log memory traces.") orelse false;
    no_cache = b.option(bool, "no-cache", "Disable caching when running tests.") orelse false;
    dev = b.option(bool, "dev", "Marks version as dev.") orelse true;
    isystem = b.option([]const []const u8, "isystem", "System includes.") orelse &.{};
    strip = b.option(bool, "strip", "Override strip.") orelse b: {
        if (optimize != .debug and !trace) {
            // Sometimes there are issues with strip for ReleaseFast + wasi.
            if (target.os.tag != .wasi) {
                break :b true;
            }
        }
        break :b false;
    };
    threads = b.option(bool, "threads", "Enable threads.") orelse b: {
        if (target.cpu.arch.isWasm() and (target.os.tag == .freestanding or target.os.tag == .wasi)) {
            break :b false;
        }
        break :b true;
    };

    var abs_root_path: []const u8 = undefined;
    if (target.os.tag == .wasi) {
        abs_root_path = "";
    } else {
        abs_root_path = try std.Io.Dir.cwd().realPathFileAlloc(b.graph.io, ".", b.allocator);
    }

    var opts = getDefaultOptions();
    opts.applyOverrides();

    const lib_mod = try create_lib_module(b, opts);
    const lib = try buildLib(b, lib_mod, opts);
    const lib_test = try add_lib_test(b, lib_mod);

    // TODO: Remove vmc dep from cli.
    const vmc = try create_vmc_mod(b, opts);

    var cli_config = CliConfig.default();
    if (optimize == .debug or target.os.tag == .wasi) {
        // Dev build looks at `@root`, release build uses the exe dir as root.
        cli_config = cli_config.with_mod_root(abs_root_path);
    }
    const cli_mod = try create_cli_module(b, vmc, lib, cli_config);

    const cli_test_config = CliConfig.default().with_mod_root(abs_root_path);
    const cli_test_mod = try create_cli_module(b, vmc, lib, cli_test_config);
    const cli_test = try add_cli_test(b, cli_test_mod);

    const trace_test = try addTraceTest(b, opts, cli_test_config);

    const behavior_test = try addBehaviorTest(b, lib, vmc, cli_test_config, opts.ffi);

    {
        const step = b.step("cli", "Build main cli.");

        const exe = b.addExecutable(.{
            .name = "cyber",
            .root_module = cli_mod,
        });
        exe.root_module.strip = strip;
        exe.root_module.addIncludePath(b.path("src"));

        // Allow dynamic libraries to be loaded by filename in the cwd.
        if (target.os.tag == .linux) {
            exe.root_module.addRPath(.{ .cwd_relative = ":$ORIGIN" });
            if (target.cpu.arch == .x86_64) {
                exe.root_module.addRPath(.{ .cwd_relative = "/usr/lib/x86_64-linux-gnu" });
            }
        } else if (target.os.tag == .macos) {
            exe.root_module.addRPath(.{ .cwd_relative = "@loader_path" });
        }

        // Allow exported symbols in exe to be visible to dlopen.
        exe.rdynamic = true;

        // step.dependOn(&b.addInstallFileWithDir(
        //     exe.getEmittedAsm(), .prefix, "cyber.s",
        // ).step);

        step.dependOn(&b.addInstallArtifact(exe, .{}).step);
        if (optimize != .debug) {
            // Release builds load the standard modules from `src/` next to the executable.
            // Platform modules are imported behind `#[cond=meta.system() == ...]`, so each
            // target only ships its own.
            const common_mods = [_][]const u8{
                "src/builtins/core.cy",
                "src/builtins/cy.cy",
                "src/builtins/meta.cy",
                "src/builtins/c.cy",
                "src/std/math.cy",
                "src/std/os.cy",
                "src/std/io.cy",
                "src/std/cli.cy",
                "src/std/test.cy",
                "src/std/libc.cy",
            };
            const target_mods: []const []const u8 = switch (target.os.tag) {
                .macos => &.{ "src/std/os.macos.cy", "src/std/libc.macos.cy" },
                .linux => &.{ "src/std/os.linux.cy", "src/std/libc.linux.cy" },
                .windows => &.{ "src/std/os.windows.cy", "src/std/windows/windows.cy", "src/std/windows/kernel32.cy" },
                else => &.{},
            };
            for (common_mods) |mod| {
                step.dependOn(&b.addInstallFile(b.path(mod), b.fmt("bin/{s}", .{mod})).step);
            }
            for (target_mods) |mod| {
                step.dependOn(&b.addInstallFile(b.path(mod), b.fmt("bin/{s}", .{mod})).step);
            }
        }
    }

    var standalone_lib_artifact: *std.Build.Step.InstallArtifact = undefined;
    {
        const step = b.step("lib", "Build as a library.");

        var standalone_opts = opts;
        // Default FFI to false for better compatibility (excludes libtcc which currently doesn't compile on MSVC).
        standalone_opts.ffi = false;
        standalone_opts.applyOverrides();

        const standalone_lib_mod = try create_lib_module(b, standalone_opts);
        const standalone_lib = try buildLib(b, standalone_lib_mod, opts);
        standalone_lib_artifact = b.addInstallArtifact(standalone_lib, .{});
        step.dependOn(&standalone_lib_artifact.step);
    }

    // {
    //     const main_step = b.step("web-lib", "Build wasm lib for web.");

    //     var opts = getDefaultOptions();
    //     opts.ffi = false;
    //     opts.malloc = if (target.cpu.arch.isWasm()) .zig else .malloc;
    //     opts.cli = false;
    //     opts.applyOverrides();

    //     const root = b.createModule(.{
    //         .root_source_file = b.path("src/web.zig"),
    //         .target = rtarget,
    //         .optimize = optimize,
    //     });
    //     const lib = b.addExecutable(.{
    //         .name = "cyber-web",
    //         .root_module = root,
    //     });
    //     lib.entry = .disabled;
    //     if (optimize != .debug) {
    //         // Disable to see better symbols when debugging wasm.
    //         lib.root_module.strip = true;
    //     }
    //     lib.addIncludePath(b.path("src"));

    //     if (target.cpu.arch.isWasm()) {
    //         // Export table so non-exported functions can still be invoked from:
    //         // `instance.exports.__indirect_function_table`
    //         lib.export_table = true;
    //     }
    //     lib.rdynamic = true;

    //     const build_options = try create_lib_config(b, opts);
    //     const stdx = b.createModule(.{
    //         .root_source_file = b.path("src/stdx/stdx.zig"),
    //     });

    //     try buildAndLinkDeps(lib.root_module, build_options, stdx, opts);
    //     main_step.dependOn(&b.addInstallArtifact(lib, .{}).step);
    // }

    {
        const main_step = b.step("build-test", "Build tests.");

        var install = b.addInstallArtifact(lib_test, .{});
        main_step.dependOn(&install.step);

        install = b.addInstallArtifact(cli_test, .{});
        main_step.dependOn(&install.step);

        install = b.addInstallArtifact(behavior_test, .{});
        main_step.dependOn(&install.step);

        install = b.addInstallArtifact(trace_test, .{});
        main_step.dependOn(&install.step);
    }

    const behavior_test_cmd = b.step("behavior-test", "Run behavior tests.");
    {
        var run = b.addRunArtifact(behavior_test);
        run.has_side_effects = no_cache;
        behavior_test_cmd.dependOn(&run.step);
    }

    const lib_test_cmd = b.step("lib-test", "Run lib tests.");
    {
        var run = b.addRunArtifact(lib_test);
        run.has_side_effects = no_cache;
        lib_test_cmd.dependOn(&run.step);
    }

    // Test the library as a standalone static library.
    const lib_standalone_test_cmd = b.step("lib-standalone-test", "Run lib tests.");
    {
        lib_standalone_test_cmd.dependOn(&standalone_lib_artifact.step);

        const lib_bin = standalone_lib_artifact.emitted_bin.?;
        var test1 = run_lib_standalone_test(b, "examples/libcyber/main.c", lib_bin);
        var test2 = run_lib_standalone_test(b, "examples/libcyber/bind_module.c", lib_bin);
        var test3 = run_lib_standalone_test(b, "examples/libcyber/host_tool.c", lib_bin);
        lib_standalone_test_cmd.dependOn(&test1.step);
        lib_standalone_test_cmd.dependOn(&test2.step);
        lib_standalone_test_cmd.dependOn(&test3.step);
    }

    const cli_test_cmd = b.step("cli-test", "Run cli tests.");
    {
        var run = b.addRunArtifact(cli_test);
        run.has_side_effects = no_cache;
        cli_test_cmd.dependOn(&run.step);
    }

    const trace_test_cmd = b.step("trace-test", "Run trace tests.");
    {
        const run = b.addRunArtifact(trace_test);
        run.has_side_effects = no_cache;
        trace_test_cmd.dependOn(&run.step);
    }

    {
        const main_step = b.step("test", "Run all tests.");
        main_step.dependOn(lib_test_cmd);
        main_step.dependOn(lib_standalone_test_cmd);
        main_step.dependOn(cli_test_cmd);
        main_step.dependOn(trace_test_cmd);
        main_step.dependOn(behavior_test_cmd);
    }

    b.step("version", "Get the short version.").dependOn(&addPrintStep(b, Version).step);
}

fn run_lib_standalone_test(b: *std.Build, path: []const u8, lib_bin: std.Build.LazyPath) *std.Build.Step.Run {
    const main_mod = b.createModule(.{
        .target = rtarget,
        .optimize = optimize,
    });
    main_mod.addIncludePath(b.path("src/include"));
    main_mod.addCSourceFile(.{
        .file = b.path(path),
    });
    const main = b.addExecutable(.{
        .name = "lib_standalone_test",
        .root_module = main_mod,
    });
    main.root_module.addObjectFile(lib_bin);
    main.root_module.link_libc = true;

    var run = b.addRunArtifact(main);
    run.has_side_effects = no_cache;
    return run;
}

fn link_cli_deps(b: *std.Build, cli: *std.Build.Module, vmc: *std.Build.Module, config: CliConfig) !void {
    cli.addIncludePath(b.path("src"));

    const build_config = try create_cli_config(b, config);
    cli.addImport("build_config", build_config);

    const linenoise = try createLinenoiseModule(b);
    cli.addImport("linenoise", linenoise);

    cli.addImport("vmc", vmc);
    cli.addImport("cyber_c", create_cyber_c_mod(b));

    const stdx = b.createModule(.{
        .root_source_file = b.path("src/stdx/stdx.zig"),
    });
    cli.addImport("stdx", stdx);

    if (config.malloc == .mimalloc) {
        const mimalloc = mimalloc_lib.createModule(b, rtarget, optimize);
        cli.addImport("mimalloc", mimalloc);
        try mimalloc_lib.buildAndLink(b, cli, .{
            .target = rtarget,
            .optimize = optimize,
        });
    }
}

/// Translates a C header with the translate-c package, which replaces `b.addTranslateC`
/// (deprecated in Zig 0.17). `Translator.mod` imports the helpers that the translated code uses.
/// `default_init` keeps the zero defaults on struct fields that `b.addTranslateC` gave.
pub fn translateC(b: *std.Build, header: std.Build.LazyPath, rtarget_: std.Build.ResolvedTarget, optimize_: std.lang.Optimize) Translator {
    return .init(b.dependency("translate_c", .{}), .{
        .c_source_file = header,
        .target = rtarget_,
        .optimize = optimize_,
        .default_init = true,
    });
}

/// Zig API to `cyber.h` for `capi.zig`. Replaces its `@cImport`, which Zig 0.17 removed.
/// Translated once per build graph; the module has no per-config inputs.
fn create_cyber_c_mod(b: *std.Build) *std.Build.Module {
    if (cyber_c_mod) |mod| return mod;
    cyber_c_mod = translateC(b, b.path("src/include/cyber.h"), rtarget, optimize).mod;
    return cyber_c_mod.?;
}
var cyber_c_mod: ?*std.Build.Module = null;

/// Translated once per `trace` flag; the other macro inputs are build-wide.
pub fn create_vmc_mod(b: *std.Build, opts: Options) !*std.Build.Module {
    if (vmc_mods[@intFromBool(opts.trace)]) |mod| return mod;
    const mod = try create_vmc_mod_uncached(b, opts);
    vmc_mods[@intFromBool(opts.trace)] = mod;
    return mod;
}
var vmc_mods: [2]?*std.Build.Module = .{ null, null };

fn create_vmc_mod_uncached(b: *std.Build, opts: Options) !*std.Build.Module {
    const vm_h = translateC(b, b.path("src/vm.h"), rtarget, optimize);
    const rt_safety = optimize == .debug or optimize == .safe;
    vm_h.defineCMacro("RT_SAFETY", if (rt_safety) "1" else "0");
    vm_h.defineCMacro("DEBUG", if (optimize == .debug) "1" else "0");
    vm_h.defineCMacro("TRACE", if (opts.trace) "1" else "0");
    vm_h.defineCMacro("IS_32BIT", if (is32Bit(opts.target)) "1" else "0");
    return vm_h.mod;
}

pub const Options = struct {
    selinux: bool,
    trace: bool,
    log_mem: bool,
    target: std.Target,
    optimize: std.lang.Optimize,
    static: bool,
    cyc: bool,
    ffi: bool,
    cli: bool,
    jit: bool,

    fn applyOverrides(self: *Options) void {
        if (optFFI) |ffi| {
            self.ffi = ffi;
        }
        if (optStatic) |static| {
            self.static = static;
        }
        if (optJIT) |jit| {
            self.jit = jit;
        }
    }
};

fn getDefaultOptions() Options {
    return .{
        .selinux = selinux,
        .trace = trace,
        .log_mem = log_mem,
        .target = target,
        .optimize = optimize,
        .cyc = true,
        .static = true,
        .ffi = !target.cpu.arch.isWasm(),
        .cli = !target.cpu.arch.isWasm(),
        .jit = false,
    };
}

const TestConfig = struct {
    test_backend: config_.TestBackend,
    ffi: bool,
};

fn create_test_config(b: *std.Build, config: TestConfig) !*std.Build.Module {
    const options = b.addOptions();
    options.addOption(config_.TestBackend, "test_backend", config.test_backend);
    options.addOption(bool, "ffi", config.ffi);
    return options.createModule();
}

const CliConfig = struct {
    mod_root: ?[]const u8,
    trace: bool,
    malloc: Allocator,

    fn default() CliConfig {
        var malloc_: Allocator = undefined;
        if (target.cpu.arch.isWasm()) {
            malloc_ = .zig;
        } else if (target.abi == .msvc) {
            // Zig 0.17 translate-c rejects the `__declspec` attributes in mimalloc.h for MSVC targets.
            malloc_ = .malloc;
        } else {
            if (optimize != .debug) {
                malloc_ = .mimalloc;
            } else {
                malloc_ = .zig;
            }
        }
        if (optMalloc) |malloc| {
            malloc_ = malloc;
        }
        return .{
            .mod_root = null,
            .trace = trace,
            .malloc = malloc_,
        };
    }

    fn with_mod_root(self: *const CliConfig, mod_root: ?[]const u8) CliConfig {
        var new = self.*;
        new.mod_root = mod_root;
        return new;
    }
};

fn create_cli_config(b: *std.Build, opts: CliConfig) !*std.Build.Module {
    const options = b.addOptions();
    options.addOption(?[]const u8, "mod_root", opts.mod_root);
    options.addOption(bool, "trace", opts.trace);
    options.addOption(Allocator, "malloc", opts.malloc);
    return options.createModule();
}

fn create_lib_config(b: *std.Build, opts: Options) !*std.Build.Module {
    const buildTag = b.graph.environ_map.get("BUILD") orelse "0";
    const commitTag = b.graph.environ_map.get("COMMIT") orelse "local";
    const options = b.addOptions();
    options.addOption(bool, "dev", dev);
    if (dev) {
        options.addOption([]const u8, "version", b.fmt("{s}-DEV", .{Version}));
        options.addOption([]const u8, "full_version", b.fmt("Cyber {s}-DEV build-{s}-{s}", .{ Version, buildTag, commitTag }));
    } else {
        options.addOption([]const u8, "version", Version);
        options.addOption([]const u8, "full_version", b.fmt("Cyber {s} build-{s}-{s}", .{ Version, buildTag, commitTag }));
    }
    options.addOption([]const u8, "build", buildTag);
    options.addOption([]const u8, "commit", commitTag);
    options.addOption(config_.Engine, "vmEngine", vmEngine);
    options.addOption(bool, "trace", opts.trace);
    options.addOption(bool, "log_mem", opts.log_mem);
    options.addOption(bool, "is32Bit", is32Bit(opts.target));
    options.addOption(bool, "cyc", opts.cyc);
    options.addOption(bool, "ffi", opts.ffi);
    options.addOption(bool, "cli", opts.cli);
    options.addOption(bool, "jit", opts.jit);
    options.addOption(bool, "threads", threads);
    return options.createModule();
}

fn add_cli_test(b: *std.Build, cli: *std.Build.Module) !*std.Build.Step.Compile {
    const step = b.addTest(.{
        .name = "cli_test",
        .root_module = cli,
        .filters = &.{testFilter orelse ""},
    });
    return step;
}

fn add_lib_test(b: *std.Build, lib: *std.Build.Module) !*std.Build.Step.Compile {
    const step = b.addTest(.{
        .name = "lib_test",
        .root_module = lib,
        .filters = &.{testFilter orelse ""},
    });
    return step;
}

fn addBehaviorTest(b: *std.Build, lib: *std.Build.Step.Compile, vmc: *std.Build.Module, config: CliConfig, ffi: bool) !*std.Build.Step.Compile {
    const root = b.createModule(.{
        .root_source_file = b.path("src/behavior_test.zig"),
        .target = rtarget,
        .optimize = optimize,
    });
    const step = b.addTest(.{
        .name = "behavior_test",
        .root_module = root,
        .filters = &.{testFilter orelse ""},
        .test_runner = .{
            .path = b.path("src/test_runner.zig"),
            .mode = .simple,
        },
    });

    // For linux FFI test.
    step.rdynamic = true;

    try link_cli_deps(b, root, vmc, config);
    step.root_module.linkLibrary(lib);

    const test_config = try create_test_config(b, .{
        .test_backend = test_backend,
        .ffi = ffi,
    });
    step.root_module.addImport("test_config", test_config);
    return step;
}

// Trace test builds its own lib because it requires the trace flag.
fn addTraceTest(b: *std.Build, lib_config_: Options, cli_config_: CliConfig) !*std.Build.Step.Compile {
    var lib_config = lib_config_;
    lib_config.trace = true;
    var cli_config = cli_config_;
    cli_config.trace = true;

    const root = b.createModule(.{
        .root_source_file = b.path("src/trace_test.zig"),
        .target = rtarget,
        .optimize = optimize,
    });

    const vmc = try create_vmc_mod(b, lib_config);
    try link_cli_deps(b, root, vmc, cli_config);

    const lib_mod = try create_lib_module(b, lib_config);
    const lib = try buildLib(b, lib_mod, lib_config);
    root.linkLibrary(lib);

    const step = b.addTest(.{
        .name = "trace_test",
        .root_module = root,
        .filters = &.{testFilter orelse ""},
        .test_runner = .{
            .path = b.path("src/test_runner.zig"),
            .mode = .simple,
        },
    });
    step.root_module.addIncludePath(b.path("src"));

    const test_config = try create_test_config(b, .{
        .test_backend = test_backend,
        .ffi = lib_config.ffi,
    });
    step.root_module.addImport("test_config", test_config);

    return step;
}

fn is32Bit(target_: std.Target) bool {
    switch (target_.cpu.arch) {
        .wasm32, .x86 => return true,
        else => return false,
    }
}

inline fn thisDir() []const u8 {
    return comptime std.Io.Dir.path.dirname(@src().file) orelse ".";
}

/// Prints `str` to stdout. Zig 0.17 has no custom build steps, so a small host program does the printing.
fn addPrintStep(b: *std.Build, str: []const u8) *std.Build.Step.Run {
    const src = b.addWriteFiles().add("print.zig", b.fmt(
        \\const std = @import("std");
        \\pub fn main(init: std.process.Init) !void {{
        \\    try std.Io.File.stdout().writeStreamingAll(init.io, "{f}");
        \\}}
    , .{std.zig.fmtString(str)}));
    const exe = b.addExecutable(.{
        .name = "print",
        .root_module = b.createModule(.{
            .root_source_file = src,
            .target = b.graph.host,
        }),
    });
    const run = b.addRunArtifact(exe);
    run.stdio = .inherit;
    return run;
}

pub fn buildCVM(b: *std.Build, opts: Options) !*std.Build.Step.Compile {
    const module = b.createModule(.{
        .target = rtarget,
        .optimize = optimize,
    });
    const lib = b.addObject(.{
        .name = "vm",
        .root_module = module,
    });
    lib.root_module.link_libc = true;
    lib.root_module.strip = strip;

    var cflags = try std.ArrayList([]const u8).initCapacity(b.allocator, 0);
    const rt_safety = optimize == .debug or optimize == .safe;
    if (rt_safety) {
        try cflags.append(b.allocator, "-DRT_SAFETY=1");
    } else {
        try cflags.append(b.allocator, "-DRT_SAFETY=0");
    }
    if (optimize == .debug) {
        try cflags.append(b.allocator, "-DDEBUG=1");
    } else {
        try cflags.append(b.allocator, "-DDEBUG=0");
    }
    try cflags.append(b.allocator, "-DCGOTO=1");
    if (opts.trace) {
        try cflags.append(b.allocator, "-DTRACE=1");
    } else {
        try cflags.append(b.allocator, "-DTRACE=0");
    }
    if (opts.log_mem) {
        try cflags.append(b.allocator, "-DLOG_MEM=1");
    } else {
        try cflags.append(b.allocator, "-DLOG_MEM=0");
    }
    if (is32Bit(opts.target)) {
        try cflags.append(b.allocator, "-DIS_32BIT=1");
    } else {
        try cflags.append(b.allocator, "-DIS_32BIT=0");
    }

    // Disable traps for arithmetic/bitshift overflows.
    // Note that changing this alone doesn't clear the build cache.
    lib.root_module.sanitize_c = .off;

    lib.root_module.addIncludePath(b.path("src"));
    lib.root_module.addCSourceFile(.{ .file = b.path("src/vm.c"), .flags = cflags.items });
    for (isystem) |path| {
        lib.root_module.addSystemIncludePath(.{ .cwd_relative = path });
    }
    return lib;
}

fn create_cli_module(b: *std.Build, vmc: *std.Build.Module, lib: *std.Build.Step.Compile, config: CliConfig) !*std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = rtarget,
        .optimize = optimize,
    });
    try link_cli_deps(b, mod, vmc, config);
    mod.linkLibrary(lib);
    return mod;
}

fn create_lib_module(b: *std.Build, opts: Options) !*std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = rtarget,
        .optimize = optimize,
    });

    mod.strip = strip;

    const build_config = try create_lib_config(b, opts);
    const stdx = b.createModule(.{
        .root_source_file = b.path("src/stdx/stdx.zig"),
    });

    mod.addIncludePath(b.path("src"));
    mod.addImport("build_config", build_config);
    mod.addImport("stdx", stdx);

    const vmc = try create_vmc_mod(b, opts);
    mod.addImport("vmc", vmc);
    mod.addImport("cyber_c", create_cyber_c_mod(b));

    mod.link_libc = true;

    if (vmEngine == .c) {
        const lib = try buildCVM(b, opts);
        if (opts.target.cpu.arch.isWasm()) {
            lib.root_module.stack_protector = false;
        }
        mod.addObject(lib);
    }

    if (opts.ffi) {
        const tcc = tcc_lib.createModule(b, rtarget, optimize);
        tcc_lib.addImport(mod, "tcc", tcc);
        try tcc_lib.buildAndLink(b, mod, .{
            .selinux = selinux,
            .target = rtarget,
            .optimize = optimize,
        });
    } else {
        mod.addAnonymousImport("tcc", .{
            .root_source_file = b.path("src/tcc_stub.zig"),
        });
        // Disable stack protector since the compiler isn't linking __stack_chk_guard/__stack_chk_fail.
        mod.stack_protector = false;
    }

    if (opts.jit) {
        // step.addIncludePath(.{ .path = "/opt/homebrew/Cellar/llvm/17.0.1/include" });
        // step.addLibraryPath(.{ .path = "/opt/homebrew/Cellar/llvm/17.0.1/lib" });
        // step.linkSystemLibrary("LLVM-17");
    }
    return mod;
}

fn buildLib(b: *std.Build, lib_mod: *std.Build.Module, opts: Options) !*std.Build.Step.Compile {
    const lib = b.addLibrary(.{
        .linkage = if (opts.static) .static else .dynamic,
        .name = "cyber",
        .root_module = lib_mod,
    });

    if (target.cpu.arch.isWasm()) {
        // Export table so non-exported functions can still be invoked from:
        // `instance.exports.__indirect_function_table`
        lib.export_table = true;
    }

    if (opts.cli) {
        if (target.os.tag == .windows) {
            lib.root_module.linkSystemLibrary("ole32", .{});
            lib.root_module.linkSystemLibrary("crypt32", .{});
            lib.root_module.linkSystemLibrary("ws2_32", .{});

            if (target.abi == .msvc) {
                lib.root_module.linkSystemLibrary("advapi32", .{});
                lib.root_module.linkSystemLibrary("shell32", .{});
            }
        }
    }

    // Allow exported symbols to be visible to dlopen.
    // Also needed to export symbols in wasm lib.
    lib.rdynamic = true;

    for (isystem) |path| {
        lib.root_module.addSystemIncludePath(.{ .cwd_relative = path });
    }

    return lib;
}

pub fn createLinenoiseModule(b: *std.Build) !*std.Build.Module {
    if (target.os.tag != .windows and target.os.tag != .wasi) {
        const mod = translateC(b, b.path("lib/linenoise/linenoise.h"), rtarget, optimize).mod;
        mod.addIncludePath(b.path("lib/linenoise"));
        try buildAndLinkLinenoise(b, mod);
        return mod;
    } else {
        const mod = b.createModule(.{
            .root_source_file = b.path("src/ln_stub.zig"),
            .target = rtarget,
            .optimize = optimize,
        });
        mod.addAnonymousImport("linenoise", .{
            .root_source_file = b.path("src/ln_stub.zig"),
        });
        return mod;
    }
}

pub fn buildAndLinkLinenoise(b: *std.Build, mod: *std.Build.Module) !void {
    const root = b.createModule(.{
        .target = rtarget,
        .optimize = optimize,
    });
    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "linenoise",
        .root_module = root,
    });
    lib.root_module.link_libc = true;
    // lib.disable_sanitize_c = true;

    const c_flags = try std.ArrayList([]const u8).initCapacity(b.allocator, 0);

    var sources = try std.ArrayList([]const u8).initCapacity(b.allocator, 0);
    sources.appendSlice(b.allocator, &.{
        "lib/linenoise/linenoise.c",
    }) catch @panic("error");
    for (sources.items) |src| {
        lib.root_module.addCSourceFile(.{
            .file = b.path(src),
            .flags = c_flags.items,
        });
    }
    mod.linkLibrary(lib);
}
