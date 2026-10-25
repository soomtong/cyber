const std = @import("std");
const builtin = @import("builtin");
const C = @import("capi.zig");
const vmc = @import("vmc");
const is_wasm = builtin.target.cpu.arch.isWasm();

/// NOTE: Dupe Zig segfault handler to wrap a custom user handler.
var windows_segfault_handle: ?std.os.windows.HANDLE = null;

/// Signal number type of a `SigactionFn`.
pub const Sig = if (builtin.target.os.tag == .windows) i32 else std.posix.SIG;

/// Attaches a global SIGSEGV handler which calls `@panic("segmentation fault");`
const SigactionFn = if (builtin.target.os.tag == .windows) *const fn (Sig, *const void, ?*anyopaque) callconv(.c) void else std.posix.Sigaction.sigaction_fn;

pub fn attachSegfaultHandler(handler: SigactionFn) void {
    if (is_wasm) {
        @panic("unsupported");
    }

    if (!std.debug.have_segfault_handling_support) {
        @compileError("segfault handler not supported for this target");
    }
    if (builtin.target.os.tag == .windows) {
        windows_segfault_handle = std.os.windows.ntdll.RtlAddVectoredExceptionHandler(0, handleSegfaultWindows);
        return;
    }
    const act = std.posix.Sigaction{
        .handler = .{ .sigaction = handler },
        .mask = std.posix.sigemptyset(),
        .flags = (std.posix.SA.SIGINFO | std.posix.SA.RESTART | std.posix.SA.RESETHAND),
    };
    std.debug.updateSegfaultHandler(&act);
}

fn resetSegfaultHandler() void {
    if (builtin.target.os.tag == .windows) {
        if (windows_segfault_handle) |handle| {
            std.debug.assert(std.os.windows.ntdll.RtlRemoveVectoredExceptionHandler(handle) != 0);
            windows_segfault_handle = null;
        }
        return;
    }
    const act = std.posix.Sigaction{
        .handler = .{ .handler = std.posix.SIG.DFL },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.debug.updateSegfaultHandler(&act);
}

/// Non-zero whenever the program triggered a panic.
/// The counter is incremented/decremented atomically.
var panicking = std.atomic.Value(u8).init(0);

/// Counts how many times the panic handler is invoked by this thread.
/// This is used to catch and handle panics triggered by the panic handler.
pub threadlocal var panic_stage: usize = 0;

/// Modified from `std.debug.defaultPanic` to wrap a custom `handler`.
/// Dumps a stack trace to standard error, then aborts.
pub fn defaultPanic(
    msg: []const u8,
    first_trace_addr: ?usize,
    handler: *const fn () anyerror!void,
) noreturn {
    @branchHint(.cold);

    // For backends that cannot handle the language features depended on by the
    // default panic handler, we have a simpler panic handler:
    switch (builtin.zig_backend) {
        .stage2_aarch64,
        .stage2_arm,
        .stage2_powerpc,
        .stage2_riscv64,
        .stage2_spirv,
        .stage2_wasm,
        .stage2_x86,
        => @trap(),
        .stage2_x86_64 => switch (builtin.target.ofmt) {
            .elf, .macho => {},
            else => @trap(),
        },
        else => {},
    }

    switch (builtin.target.os.tag) {
        .freestanding, .other => {
            @trap();
        },
        .uefi => {
            const uefi = std.os.uefi;

            var utf16_buffer: [1000]u16 = undefined;
            const len_minus_3 = std.unicode.utf8ToUtf16Le(&utf16_buffer, msg) catch 0;
            utf16_buffer[len_minus_3..][0..3].* = .{ '\r', '\n', 0 };
            const len = len_minus_3 + 3;
            const exit_msg = utf16_buffer[0 .. len - 1 :0];

            // Output to both std_err and con_out, as std_err is easier
            // to read in stuff like QEMU at times, but, unlike con_out,
            // isn't visible on actual hardware if directly booted into
            inline for ([_]?*uefi.protocol.SimpleTextOutput{ uefi.system_table.std_err, uefi.system_table.con_out }) |o| {
                if (o) |out| {
                    out.setAttribute(.{ .foreground = .red }) catch {};
                    _ = out.outputString(exit_msg) catch {};
                    out.setAttribute(.{ .foreground = .white }) catch {};
                }
            }

            if (uefi.system_table.boot_services) |bs| {
                // ExitData buffer must be allocated using boot_services.allocatePool (spec: page 220)
                const exit_data = uefi.raw_pool_allocator.dupeSentinel(u16, exit_msg, 0) catch @trap();
                bs.exit(uefi.handle, .aborted, exit_data) catch {};
            }
            @trap();
        },
        .cuda, .amdhsa => std.process.abort(),
        .plan9 => {
            var status: [std.os.plan9.ERRMAX]u8 = undefined;
            const len = @min(msg.len, status.len - 1);
            @memcpy(status[0..len], msg[0..len]);
            status[len] = 0;
            std.os.plan9.exits(status[0..len :0]);
        },
        else => {},
    }

    if (std.options.enable_segfault_handler) {
        // If a segfault happens while panicking, we want it to actually segfault, not trigger
        // the handler.
        resetSegfaultHandler();
    }

    // Note there is similar logic in handleSegfault.
    switch (panic_stage) {
        0 => {
            panic_stage = 1;

            _ = panicking.fetchAdd(1, .seq_cst);

            trace: {
                const stderr = std.debug.lockStderr(&.{}).terminal();
                defer std.debug.unlockStderr();
                const writer = stderr.writer;

                if (builtin.single_threaded) {
                    writer.print("panic: ", .{}) catch break :trace;
                } else {
                    const current_thread_id = std.Thread.getCurrentId();
                    writer.print("thread {d} panic: ", .{current_thread_id}) catch break :trace;
                }
                writer.print("{s}\n", .{msg}) catch break :trace;

                if (@errorReturnTrace()) |t| if (t.index > 0) {
                    writer.writeAll("error return context:\n") catch break :trace;
                    std.debug.writeErrorReturnTrace(t, stderr) catch break :trace;
                    writer.writeAll("\nstack trace:\n") catch break :trace;
                };
                std.debug.writeCurrentStackTrace(.{
                    .first_address = first_trace_addr orelse @returnAddress(),
                    .allow_unsafe_unwind = true,
                }, stderr) catch break :trace;
            }

            handler() catch |err| {
                std.debug.print("error during panic: {}", .{err});
                std.process.abort();
            };

            waitForOtherThreadToFinishPanicking();
        },
        1 => {
            panic_stage = 2;

            // A panic happened while trying to print a previous panic message.
            // We're still holding the mutex but that's fine as we're going to
            // call abort().
            const stderr = std.debug.lockStderr(&.{}).terminal();
            stderr.writer.writeAll("aborting due to recursive panic\n") catch {};
        },
        else => {}, // Panicked while printing the recursive panic message.
    }

    std.process.abort();
}

pub fn vm_segv_handler(_: *C.VM) !void {
    const t: *C.Thread = @ptrCast(vmc.cur_thread orelse {
        std.debug.print("segfault without thread context\n", .{});
        return;
    });
    C.thread_signal_host_segfault(t);
}

pub fn vm_panic_handler(_: *C.VM) !void {
    const t: *C.Thread = @ptrCast(vmc.cur_thread orelse {
        std.debug.print("panic without thread context\n", .{});
        return;
    });
    C.thread_signal_host_panic(t);
}

/// Modified from `std.debug.handleSegfaultPosix` to wrap a custom `handler`.
pub fn handleSegfaultPosix(sig: Sig, info: *const std.posix.siginfo_t, ctx_ptr: ?*anyopaque, handler: *const fn() callconv(.c) void) noreturn {
    // Reset to the default handler so that if a segfault happens in this handler it will crash
    // the process. Also when this handler returns, the original instruction will be repeated
    // and the resulting segfault will crash the process rather than continually dump stack traces.
    resetSegfaultHandler();

    const addr: ?usize, const name: []const u8 = info: {
        if (native_os == .linux and native_arch == .x86_64) {
            // x86_64 doesn't have a full 64-bit virtual address space.
            // Addresses outside of that address space are non-canonical
            // and the CPU won't provide the faulting address to us.
            // This happens when accessing memory addresses such as 0xaaaaaaaaaaaaaaaa
            // but can also happen when no addressable memory is involved;
            // for example when reading/writing model-specific registers
            // by executing `rdmsr` or `wrmsr` in user-space (unprivileged mode).
            const SI_KERNEL = 0x80;
            if (sig == .SEGV and info.code == SI_KERNEL) {
                break :info .{ null, "General protection exception" };
            }
        }
        const addr: usize = switch (native_os) {
            .linux => @intFromPtr(info.fields.sigfault.addr),
            .freebsd, .macos => @intFromPtr(info.addr),
            .netbsd => @intFromPtr(info.info.reason.fault.addr),
            .openbsd => @intFromPtr(info.data.fault.addr),
            .illumos => @intFromPtr(info.reason.fault.addr),
            else => unreachable,
        };
        const name = switch (sig) {
            .SEGV => "Segmentation fault",
            .ILL => "Illegal instruction",
            .BUS => "Bus error",
            .FPE => "Arithmetic exception",
            else => unreachable,
        };
        break :info .{ addr, name };
    };
    const opt_cpu_context: ?std.debug.cpu_context.Native = std.debug.cpu_context.fromPosixSignalContext(ctx_ptr);
    handleSegfault(addr, name, if (opt_cpu_context) |*ctx| ctx else null, handler);
}

fn handleSegfaultWindows(info: *std.os.windows.EXCEPTION_POINTERS) callconv(.winapi) c_long {
    // For backends that cannot handle the language features used by this segfault handler, we have a simpler one,
    switch (builtin.zig_backend) {
        .stage2_x86_64 => if (builtin.target.ofmt == .coff) @trap(),
        else => {},
    }

    const name: []const u8, const addr: ?usize = switch (info.ExceptionRecord.ExceptionCode) {
        std.os.windows.EXCEPTION_DATATYPE_MISALIGNMENT => .{ "Unaligned Memory Access", null },
        std.os.windows.EXCEPTION_ACCESS_VIOLATION => .{ "Segmentation fault", info.ExceptionRecord.ExceptionInformation[1] },
        std.os.windows.EXCEPTION_ILLEGAL_INSTRUCTION => .{ "Illegal instruction", info.ContextRecord.getRegs().ip },
        std.os.windows.EXCEPTION_STACK_OVERFLOW => .{ "Stack Overflow", null },
        else => return std.os.windows.EXCEPTION_CONTINUE_SEARCH,
    };
    handleSegfault(addr, name, &std.debug.cpu_context.fromWindowsContext(info.ContextRecord), null);
}

const native_arch = builtin.target.cpu.arch;
const native_os = builtin.target.os.tag;

/// Modified from `std.debug.defaultHandleSegfault` to wrap a custom `handler`.
fn handleSegfault(addr: ?usize, name: []const u8, opt_ctx: ?std.debug.CpuContextPtr, handler: ?*const fn() callconv(.c) void) noreturn {
    // Note there is similar logic in defaultPanic.
    switch (panic_stage) {
        0 => {
            panic_stage = 1;
            _ = panicking.fetchAdd(1, .seq_cst);

            trace: {
                const stderr = std.debug.lockStderr(&.{}).terminal();
                defer std.debug.unlockStderr();

                if (addr) |a| {
                    stderr.writer.print("{s} at address 0x{x}\n", .{ name, a }) catch break :trace;
                } else {
                    stderr.writer.print("{s} (no address available)\n", .{name}) catch break :trace;
                }
                if (opt_ctx) |context| {
                    std.debug.writeCurrentStackTrace(.{
                        .context = context,
                        .allow_unsafe_unwind = true,
                    }, stderr) catch break :trace;
                }
            }

            if (handler) |handler_| handler_();

            waitForOtherThreadToFinishPanicking();
        },
        1 => {
            panic_stage = 2;
            // A segfault happened while trying to print a previous panic message.
            // We're still holding the mutex but that's fine as we're going to
            // call abort().
            const stderr = std.debug.lockStderr(&.{}).terminal();
            stderr.writer.writeAll("aborting due to recursive panic\n") catch {};
        },
        else => {}, // Panicked while printing the recursive panic message.
    }

    // We cannot allow the signal handler to return because when it runs the original instruction
    // again, the memory may be mapped and undefined behavior would occur rather than repeating
    // the segfault. So we simply abort here.
    std.process.abort();
}

/// Must be called only after adding 1 to `panicking`. There are three callsites.
fn waitForOtherThreadToFinishPanicking() void {
    if (panicking.fetchSub(1, .seq_cst) != 1) {
        // Another thread is panicking, wait for the last one to finish
        // and call abort()
        if (builtin.single_threaded) unreachable;

        // Sleep forever without hammering the CPU
        var futex: u32 = 0;
        while (true) std.Options.debug_io.futexWaitUncancelable(u32, &futex, 0);
        unreachable;
    }
}

// Protected by `std.debug.lockStderr`.
pub var print_buf: [1024]u8 = undefined;
