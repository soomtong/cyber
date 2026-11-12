const std = @import("std");
const stdx = @import("stdx");
const cy = @import("../cyber.zig");
const C = @import("../capi.zig");
const zt = stdx.testing;

/// A host module whose functions return pending futures. The test completes them between `CL_AWAIT` and the resume.
const Host = struct {
    /// Futures in the order the script asked for them. Borrowed: only compared and completed while pending.
    var asked: [16]?*C.Future = @splat(null);
    var args: [16]i64 = @splat(0);
    var num_asked: usize = 0;

    fn reset() void {
        asked = @splat(null);
        args = @splat(0);
        num_asked = 0;
    }

    fn pending(t: *C.Thread, spec: []const u8, arg: i64) C.Ret {
        // A value slot is 8 bytes on every target. A pointer is not.
        const ret = C.thread_ret(t, u64);
        const future_t = C.vm_find_type(C.thread_vm(t), spec) orelse {
            return C.thread_ret_panic(t, "No future type.");
        };
        const f = C.future_new(t, future_t) orelse {
            return C.thread_ret_panic(t, "No future.");
        };
        asked[num_asked] = f;
        args[num_asked] = arg;
        num_asked += 1;
        ret.* = @intFromPtr(f);
        return C.RetOk;
    }

    fn ask(t: *C.Thread) callconv(.c) C.Ret {
        return pendingInt(t, "Future[int]");
    }
    fn ask_res(t: *C.Thread) callconv(.c) C.Ret {
        return pendingInt(t, "Future[!int]");
    }
    fn pendingInt(t: *C.Thread, spec: []const u8) C.Ret {
        // The return slot is reserved before the params are read.
        // A value slot is 8 bytes on every target. A pointer is not.
        const ret = C.thread_ret(t, u64);
        const n = C.thread_int(t);
        const future_t = C.vm_find_type(C.thread_vm(t), spec) orelse {
            return C.thread_ret_panic(t, "No future type.");
        };
        const f = C.future_new(t, future_t) orelse {
            return C.thread_ret_panic(t, "No future.");
        };
        asked[num_asked] = f;
        args[num_asked] = n;
        num_asked += 1;
        ret.* = @intFromPtr(f);
        return C.RetOk;
    }
    fn ask_str(t: *C.Thread) callconv(.c) C.Ret {
        return pending(t, "Future[str]", 0);
    }
    fn ask_void(t: *C.Thread) callconv(.c) C.Ret {
        return pending(t, "Future[!void]", 0);
    }
    /// Returns a future that is already completed with `n * 2`.
    fn ask_done(t: *C.Thread) callconv(.c) C.Ret {
        // A value slot is 8 bytes on every target. A pointer is not.
        const ret = C.thread_ret(t, u64);
        const n = C.thread_int(t);
        const vm = C.thread_vm(t);
        const f = C.future_new(t, C.vm_find_type(vm, "Future[int]").?).?;
        const v: i64 = n * 2;
        if (!C.future_complete(vm, f, &v)) return C.thread_ret_panic(t, "Not completed.");
        ret.* = @intFromPtr(f);
        return C.RetOk;
    }

    fn loader(vm: *C.VM, mod: *C.Sym, uri: C.Bytes, res: [*c]C.LoaderResult) callconv(.c) bool {
        const name = C.from_bytes(uri);
        if (std.mem.eql(u8, name, "host")) {
            C.mod_add_func(mod, "ask", C.BIND_FUNC(&ask));
            C.mod_add_func(mod, "ask_res", C.BIND_FUNC(&ask_res));
            C.mod_add_func(mod, "ask_str", C.BIND_FUNC(&ask_str));
            C.mod_add_func(mod, "ask_void", C.BIND_FUNC(&ask_void));
            C.mod_add_func(mod, "ask_done", C.BIND_FUNC(&ask_done));
            res[0].src = C.to_bytes(
                \\#[bind] fn ask(n int) -> Future[int]
                \\#[bind] fn ask_res(n int) -> Future[!int]
                \\#[bind] fn ask_str() -> Future[str]
                \\#[bind] fn ask_void() -> Future[!void]
                \\#[bind] fn ask_done(n int) -> Future[int]
            );
            return true;
        } else {
            return C.default_loader(vm, mod, uri, res);
        }
    }

    fn init() *C.VM {
        reset();
        const vm = C.vm_initx(zt.alloc);
        C.vm_set_loader(vm, @ptrCast(&loader));
        return vm;
    }
};

fn completeInt(vm: *C.VM, f: ?*C.Future, n: i64) bool {
    return C.future_complete(vm, f, &n);
}

test "An await of a host future suspends the eval, and cl_vm_resume continues it." {
    const vm = Host.init();
    defer C.vm_deinit(vm);

    var res: C.EvalResult = undefined;
    try zt.eq(C.Await, C.vm_eval(vm,
        \\use host
        \\use test
        \\a := host.ask(1).await()
        \\test.eq(a, 10)
        \\b := host.ask(2).await()
        \\c := host.ask(3).await()
        \\test.eq(b + c, 50)
    , &res));
    try zt.eq(1, Host.num_asked);
    try zt.eq(Host.asked[0], C.vm_pending_future(vm));
    try zt.eq(1, Host.args[0]);

    // A resume without a completion waits again.
    try zt.eq(C.Await, C.vm_resume(vm, &res));
    try zt.eq(Host.asked[0], C.vm_pending_future(vm));

    try zt.eq(true, completeInt(vm, Host.asked[0], 10));
    // A future is completed once.
    try zt.eq(false, completeInt(vm, Host.asked[0], 11));
    try zt.eq(C.Await, C.vm_resume(vm, &res));
    try zt.eq(2, Host.num_asked);
    try zt.eq(true, completeInt(vm, Host.asked[1], 20));
    try zt.eq(C.Await, C.vm_resume(vm, &res));
    try zt.eq(3, Host.num_asked);
    try zt.eq(true, completeInt(vm, Host.asked[2], 30));
    try zt.eq(C.Success, C.vm_resume(vm, &res));
    try zt.eq(null, C.vm_pending_future(vm));

    // Nothing is suspended now.
    try zt.eq(C.ErrorUnknown, C.vm_resume(vm, &res));
}

/// Runs `src`, completing every awaited `ask` future with its argument times 10, until the eval ends.
fn runCompleting(vm: *C.VM, config: C.EvalConfig, src: []const u8, res: *C.EvalResult) C.ResultCode {
    var code = C.vm_evalx(vm, "main", src, config, res);
    while (code == C.Await) {
        const f = C.vm_pending_future(vm);
        var found = false;
        for (Host.asked[0..Host.num_asked], 0..) |asked, i| {
            if (asked == f) {
                found = completeInt(vm, f, Host.args[i] * 10);
                break;
            }
        }
        if (!found) return C.ErrorUnknown;
        code = C.vm_resume(vm, res);
    }
    return code;
}

test "An await suspends at any call depth, in a generator body and in a fiber." {
    const vm = Host.init();
    defer C.vm_deinit(vm);

    var res: C.EvalResult = undefined;
    // A wrapper keeps the script API synchronous. The await is two calls deep.
    try zt.eq(C.Success, runCompleting(vm, C.defaultEvalConfig(),
        \\use host
        \\use test
        \\fn ask(n int) -> int:
        \\    return host.ask(n).await()
        \\fn sum(n int) -> int:
        \\    total := 0
        \\    for 1..n + 1 |i|:
        \\        total += ask(i)
        \\    return total
        \\test.eq(sum(4), 100)
    , &res));
    try zt.eq(4, Host.num_asked);

    // The body of a generator that the root context consumes.
    Host.reset();
    try zt.eq(C.Success, runCompleting(vm, C.defaultEvalConfig(),
        \\use host
        \\use test
        \\generator fn answers(n int) -> int:
        \\    for 1..n + 1 |i|:
        \\        yield host.ask(i).await()
        \\total := 0
        \\for answers(3) |v|:
        \\    total += v
        \\test.eq(total, 60)
    , &res));
    try zt.eq(3, Host.num_asked);

    // Inside a fiber the eval leaves the VM as well. The resume continues in the fiber.
    Host.reset();
    try zt.eq(C.Success, runCompleting(vm, C.defaultEvalConfig(),
        \\use host
        \\use test
        \\fn work(log ^ArrayStore[int], n int):
        \\    log << host.ask(n).await()
        \\    suspend
        \\    log << host.ask(n + 1).await()
        \\log := ^ArrayStore[int]{}
        \\f := fiber work(log, 1)
        \\test.eq(f.resume(), .suspended)
        \\test.eq(log.len(), 1)
        \\test.eq(f.resume(), .done)
        \\test.eq(log[0] + log[1], 30)
    , &res));
    try zt.eq(2, Host.num_asked);
}

test "A host future completes with a value or an error." {
    const vm = Host.init();
    defer C.vm_deinit(vm);
    const t = C.vm_main_thread(vm);

    var res: C.EvalResult = undefined;
    try zt.eq(C.Await, C.vm_eval(vm,
        \\use host
        \\use test
        \\fn get(n int) -> !int:
        \\    return host.ask_res(n).await()
        \\test.eq(get(1)!, 7)
        \\fn get_or(n int, default int) -> int:
        \\    return get(n) !else |err|:
        \\        test.eq(err, error.Denied)
        \\        return default
        \\test.eq(get_or(2, -1), -1)
        \\host.ask_void().await()!
        \\res := host.ask_void().await()
        \\test.eq(res.unwrap_error(), error.Denied)
        \\s := host.ask_str().await()
        \\test.eq(s, 'from the host')
    , &res));
    // `Future[!int]` takes the `int`.
    try zt.eq(true, completeInt(vm, C.vm_pending_future(vm), 7));
    try zt.eq(C.Await, C.vm_resume(vm, &res));
    try zt.eq(true, C.future_complete_error(vm, C.vm_pending_future(vm), C.symbol(vm, "Denied")));
    try zt.eq(C.Await, C.vm_resume(vm, &res));
    // `Future[!void]`: no value to read.
    try zt.eq(true, C.future_complete(vm, C.vm_pending_future(vm), null));
    try zt.eq(C.Await, C.vm_resume(vm, &res));
    try zt.eq(true, C.future_complete_error(vm, C.vm_pending_future(vm), C.symbol(vm, "Denied")));
    try zt.eq(C.Await, C.vm_resume(vm, &res));
    // A `str` is owned by the future after the completion.
    const f = C.vm_pending_future(vm);
    // Only a `Future[!U]` takes an error.
    try zt.eq(false, C.future_complete_error(vm, f, C.symbol(vm, "Denied")));
    const s = C.str_init(t, "from the host");
    try zt.eq(true, C.future_complete(vm, f, &s));
    try zt.eq(C.Success, C.vm_resume(vm, &res));
}

test "A completed future does not suspend the eval." {
    const vm = Host.init();
    defer C.vm_deinit(vm);

    var res: C.EvalResult = undefined;
    try zt.eq(C.Success, C.vm_eval(vm,
        \\use host
        \\use test
        \\test.eq(host.ask_done(21).await(), 42)
        \\test.eq(Future.complete(5).await(), 5)
        \\-- A future that the script completes itself.
        \\r := FutureResolver.new(int)
        \\r.complete(9)
        \\test.eq(r.future().await(), 9)
    , &res));
    try zt.eq(null, C.vm_pending_future(vm));
}

test "Futures that are not awaited or stay pending are freed." {
    const vm = Host.init();
    defer C.vm_deinit(vm);
    const t = C.vm_main_thread(vm);

    var res: C.EvalResult = undefined;
    try zt.eq(C.Success, C.vm_eval(vm,
        \\use host
        \\_ = host.ask(1)
        \\kept := host.ask_str()
        \\_ = host.ask_done(3)
        \\fn drop():
        \\    f := host.ask_res(4)
        \\drop()
    , &res));
    try zt.eq(3, Host.num_asked);

    // The host can hold a reference past the script. It completes the future and releases it.
    Host.reset();
    try zt.eq(C.Await, C.vm_eval(vm,
        \\use host
        \\use test
        \\fn first() -> str:
        \\    return host.ask_str().await()
        \\test.eq(first(), 'kept')
    , &res));
    const f = C.vm_pending_future(vm).?;
    const f_value: u64 = @intFromPtr(f);
    C.thread_retain(t, f_value);
    const s = C.str_init(t, "kept");
    try zt.eq(true, C.future_complete(vm, f, &s));
    try zt.eq(C.Success, C.vm_resume(vm, &res));
    C.thread_release(t, f_value);
}

test "A suspended eval carries its main locals to the next eval." {
    const vm = Host.init();
    defer C.vm_deinit(vm);

    var config = C.defaultEvalConfig();
    config.persist_main = true;
    var res: C.EvalResult = undefined;
    try zt.eq(C.Success, C.vm_evalx(vm, "repl", "use host\nbefore := 1", config, &res));
    try zt.eq(C.Success, runCompleting(vm, config,
        \\a := host.ask(2).await()
        \\name := 'abc' + 'def'
        \\b := host.ask(3).await()
    , &res));
    try zt.eq(C.Success, C.vm_evalx(vm, "repl",
        \\use test
        \\test.eq(before + a + b, 51)
        \\test.eq(name, 'abcdef')
    , config, &res));

    // The last expression of a resumed eval is the result.
    try zt.eq(C.Await, C.vm_evalx(vm, "repl", "host.ask(4).await() + a", config, &res));
    try zt.eq(true, completeInt(vm, C.vm_pending_future(vm), 40));
    try zt.eq(C.Success, C.vm_resume(vm, &res));
    try zt.eq(60, @as(*i64, @ptrCast(@alignCast(res.res))).*);
}

test "cl_vm_abandon drops a suspended eval, and the VM takes the next eval." {
    const vm = Host.init();
    defer C.vm_deinit(vm);
    C.setSilent(true);
    defer C.setSilent(false);

    var config = C.defaultEvalConfig();
    config.persist_main = true;
    var res: C.EvalResult = undefined;
    try zt.eq(C.Success, C.vm_evalx(vm, "repl",
        \\use host
        \\fn ask(n int) -> int:
        \\    return host.ask(n).await()
        \\kept := 'abc' + 'def'
    , config, &res));
    try zt.eq(C.Await, C.vm_evalx(vm, "repl",
        \\list := ^ArrayStore[str]{}
        \\list << ('x' + 'y')
        \\n := ask(1)
    , config, &res));

    // The suspended eval refuses another program.
    try zt.eq(C.ErrorSuspended, C.vm_evalx(vm, "repl", "_ = 1", config, &res));
    try zt.eq(C.ErrorSuspended, C.vm_validate(vm, "_ = 1"));
    try zt.eq(C.ErrorSuspended, C.vm_compile(vm, "main", "_ = 1", C.defaultCompileConfig()));
    try zt.eq(Host.asked[0], C.vm_pending_future(vm));

    C.vm_abandon(vm);
    try zt.eq(null, C.vm_pending_future(vm));
    {
        const report = C.vm_error_summary(vm);
        defer C.vm_freeb(vm, report);
        try zt.eq(true, std.mem.startsWith(u8, report, "panic: Abandoned while awaiting a future."));
        try zt.expect(std.mem.indexOf(u8, report, " ask:") != null);
    }
    // Nothing to abandon or to resume.
    C.vm_abandon(vm);
    try zt.eq(C.ErrorUnknown, C.vm_resume(vm, &res));

    // Like an interrupt: the main locals are gone, the declarations stay.
    try zt.eq(C.ErrorCompile, C.vm_evalx(vm, "repl", "_ = kept", config, &res));
    try zt.eq(C.Await, C.vm_evalx(vm, "repl", "m := ask(2)", config, &res));
    try zt.eq(true, completeInt(vm, C.vm_pending_future(vm), 5));
    try zt.eq(C.Success, C.vm_resume(vm, &res));
    try zt.eq(C.Success, C.vm_evalx(vm, "repl", "use test\ntest.eq(m, 5)", config, &res));

    // Abandoned inside a fiber: the fiber and its stack are freed with the eval.
    try zt.eq(C.Await, C.vm_evalx(vm, "repl",
        \\fn work(tag str):
        \\    local := tag + '!'
        \\    _ = ask(7)
        \\f := fiber work('a' + 'b')
        \\_ = f.resume()
    , config, &res));
    C.vm_abandon(vm);
    try zt.eq(C.ErrorCompile, C.vm_evalx(vm, "repl", "_ = m", config, &res));
    try zt.eq(C.Success, C.vm_evalx(vm, "repl", "g := fiber work('c')", config, &res));

    // `cl_vm_reset` and `cl_vm_deinit` abandon a suspended eval.
    try zt.eq(C.Await, C.vm_evalx(vm, "repl", "big := 'a' + 'b'\nk := ask(3)", config, &res));
    C.vm_reset(vm);
    try zt.eq(null, C.vm_pending_future(vm));
    try zt.eq(C.Await, C.vm_evalx(vm, "repl", "use host\ns := 'a' + 'b'\nk := host.ask(3).await()", config, &res));
}

test "The limits of an eval carry over a suspension." {
    const vm = Host.init();
    defer C.vm_deinit(vm);
    C.setSilent(true);
    defer C.setSilent(false);

    var res: C.EvalResult = undefined;
    const loop_after =
        \\use host
        \\n := host.ask(1).await()
        \\while true:
        \\    n += 1
    ;

    // The fuel is not refilled by the resume.
    C.vm_set_fuel(vm, 1000);
    try zt.eq(C.Await, C.vm_eval(vm, loop_after, &res));
    try zt.eq(true, completeInt(vm, C.vm_pending_future(vm), 1));
    try zt.eq(C.ErrorInterrupt, C.vm_resume(vm, &res));
    {
        const report = C.vm_error_summary(vm);
        defer C.vm_freeb(vm, report);
        try zt.eq(true, std.mem.startsWith(u8, report, "panic: Out of fuel."));
    }
    C.vm_set_fuel(vm, 0);

    // An interrupt that arrives while the eval is suspended stops it after the resume.
    try zt.eq(C.Await, C.vm_eval(vm, loop_after, &res));
    C.vm_interrupt(vm);
    try zt.eq(true, completeInt(vm, C.vm_pending_future(vm), 1));
    try zt.eq(C.ErrorInterrupt, C.vm_resume(vm, &res));
    {
        const report = C.vm_error_summary(vm);
        defer C.vm_freeb(vm, report);
        try zt.eq(true, std.mem.startsWith(u8, report, "panic: Interrupted."));
    }

    // The memory limit.
    try zt.eq(C.Await, C.vm_eval(vm,
        \\use host
        \\n := host.ask(1).await()
        \\list := ^ArrayStore[int]{}
        \\while true:
        \\    list << n
    , &res));
    C.vm_set_memory_limit(vm, @intCast(C.vm_memory_used(vm) + 4 * 1024 * 1024));
    try zt.eq(true, completeInt(vm, C.vm_pending_future(vm), 1));
    try zt.eq(C.ErrorPanic, C.vm_resume(vm, &res));
    {
        const report = C.vm_error_summary(vm);
        defer C.vm_freeb(vm, report);
        try zt.eq(true, std.mem.startsWith(u8, report, "panic: OutOfMemory"));
    }
    C.vm_set_memory_limit(vm, 0);

    // A panic after the resume, and the VM is used again.
    try zt.eq(C.Await, C.vm_eval(vm,
        \\use host
        \\n := host.ask(1).await()
        \\panic('after %{n}')
    , &res));
    try zt.eq(true, completeInt(vm, C.vm_pending_future(vm), 3));
    try zt.eq(C.ErrorPanic, C.vm_resume(vm, &res));
    try zt.eq(C.Success, C.vm_eval(vm, "_ = 1 + 2", &res));
}

test "A future that only the script could complete suspends too, and a spawned thread can not wait." {
    const vm = Host.init();
    defer C.vm_deinit(vm);
    C.setSilent(true);
    defer C.setSilent(false);

    var res: C.EvalResult = undefined;
    // The host does not know this future. It abandons the eval.
    try zt.eq(C.Await, C.vm_eval(vm,
        \\r := FutureResolver.new(int)
        \\_ = r.future().await()
    , &res));
    try zt.expect(C.vm_pending_future(vm) != null);
    try zt.eq(0, Host.num_asked);
    C.vm_abandon(vm);

    if (cy.isWasm) return;
    try zt.eq(C.ErrorPanic, C.vm_eval(vm,
        \\use host
        \\fn wait() -> int:
        \\    return host.ask(1).await()
        \\_ = spawn(wait, {}).await()
    , &res));
    {
        const report = C.vm_error_summary(vm);
        defer C.vm_freeb(vm, report);
        try zt.expect(std.mem.indexOf(u8, report, "Cannot wait in a spawned thread") != null);
    }
    try zt.eq(C.Success, C.vm_eval(vm, "_ = 1 + 2", &res));
}
