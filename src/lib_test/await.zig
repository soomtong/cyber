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
    /// The host keeps a reference to each future it creates (see the test on retained futures).
    var retain: bool = false;

    /// Gives back the references of an eval that ended normally, and forgets the futures.
    fn releaseAll(t: *C.Thread) void {
        for (asked[0..num_asked]) |f| {
            const value: u64 = @intFromPtr(f.?);
            C.thread_release(t, value);
        }
        reset();
    }

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
        const f = C.future_new(t, future_t, num_asked + 1) orelse {
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
        const f = C.future_new(t, future_t, num_asked + 1) orelse {
            return C.thread_ret_panic(t, "No future.");
        };
        asked[num_asked] = f;
        args[num_asked] = n;
        num_asked += 1;
        if (retain) C.thread_retain(t, @as(u64, @intFromPtr(f)));
        ret.* = @intFromPtr(f);
        return C.RetOk;
    }
    fn ask_str(t: *C.Thread) callconv(.c) C.Ret {
        return pending(t, "Future[str]", 0);
    }
    fn ask_void(t: *C.Thread) callconv(.c) C.Ret {
        return pending(t, "Future[!void]", 0);
    }
    fn ask_res_str(t: *C.Thread) callconv(.c) C.Ret {
        return pending(t, "Future[!str]", 0);
    }
    fn ask_res_ints(t: *C.Thread) callconv(.c) C.Ret {
        return pending(t, "Future[![]int]", 0);
    }
    /// Returns a future that is already completed with `n * 2`.
    fn ask_done(t: *C.Thread) callconv(.c) C.Ret {
        // A value slot is 8 bytes on every target. A pointer is not.
        const ret = C.thread_ret(t, u64);
        const n = C.thread_int(t);
        const vm = C.thread_vm(t);
        const f = C.future_new(t, C.vm_find_type(vm, "Future[int]").?, 1000).?;
        const v: i64 = n * 2;
        if (!C.future_complete(vm, f, &v)) return C.thread_ret_panic(t, "Not completed.");
        ret.* = @intFromPtr(f);
        return C.RetOk;
    }

    /// Asks the running eval to stop, from inside the eval.
    fn stop(t: *C.Thread) callconv(.c) C.Ret {
        _ = C.thread_ret(t, void);
        C.vm_interrupt(C.thread_vm(t));
        return C.RetOk;
    }

    fn loader(vm: *C.VM, mod: *C.Sym, uri: C.Bytes, res: [*c]C.LoaderResult) callconv(.c) bool {
        const name = C.from_bytes(uri);
        if (std.mem.eql(u8, name, "host")) {
            C.mod_add_func(mod, "ask", C.BIND_FUNC(&ask));
            C.mod_add_func(mod, "ask_res", C.BIND_FUNC(&ask_res));
            C.mod_add_func(mod, "ask_str", C.BIND_FUNC(&ask_str));
            C.mod_add_func(mod, "ask_void", C.BIND_FUNC(&ask_void));
            C.mod_add_func(mod, "ask_res_str", C.BIND_FUNC(&ask_res_str));
            C.mod_add_func(mod, "ask_res_ints", C.BIND_FUNC(&ask_res_ints));
            C.mod_add_func(mod, "ask_done", C.BIND_FUNC(&ask_done));
            C.mod_add_func(mod, "stop", C.BIND_FUNC(&stop));
            res[0].src = C.to_bytes(
                \\#[bind] fn ask(n int) -> Future[int]
                \\#[bind] fn ask_res(n int) -> Future[!int]
                \\#[bind] fn ask_str() -> Future[str]
                \\#[bind] fn ask_void() -> Future[!void]
                \\#[bind] fn ask_res_str() -> Future[!str]
                \\#[bind] fn ask_res_ints() -> Future[![]int]
                \\#[bind] fn ask_done(n int) -> Future[int]
                \\#[bind] fn stop()
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
        const f = C.vm_pending_future(vm).?;
        // The tag is the number of the request, starting at 1. No pointers are compared.
        const tag: usize = @intCast(C.future_tag(f));
        if (tag == 0 or tag > Host.num_asked) return C.ErrorUnknown;
        if (!completeInt(vm, f, Host.args[tag - 1] * 10)) return C.ErrorUnknown;
        code = C.vm_resume(vm, res);
    }
    return code;
}

test "An await suspends at any call depth and in a generator body. In a fiber it suspends the fiber." {
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

    // Inside a fiber the await gives control back to the resumer. The eval leaves the VM when the root
    // context waits for the fibers, and the resume continues in the root.
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
        \\test.eq(f.waiting(), true)
        \\test.eq(log.len(), 0)
        \\-- Not done yet: the fiber is not entered.
        \\test.eq(f.resume(), .suspended)
        \\test.eq(Fiber.wait_ready(), true)
        \\test.eq(f.waiting(), false)
        \\-- Runs to the plain `suspend`.
        \\test.eq(f.resume(), .suspended)
        \\test.eq(f.waiting(), false)
        \\test.eq(log.len(), 1)
        \\test.eq(Fiber.wait_ready(), false)
        \\test.eq(f.resume(), .suspended)
        \\test.eq(Fiber.wait_ready(), true)
        \\test.eq(f.resume(), .done)
        \\test.eq(log[0] + log[1], 30)
    , &res));
    try zt.eq(2, Host.num_asked);
}

test "Fibers that await host futures run interleaved, and the host sees all of their futures." {
    const vm = Host.init();
    defer C.vm_deinit(vm);

    var res: C.EvalResult = undefined;
    try zt.eq(C.Await, C.vm_eval(vm,
        \\use host
        \\use test
        \\fn work(name str, n int, log ^ArrayStore[str]):
        \\    a := host.ask(n).await()
        \\    log << '%{name}1=%{a}'
        \\    b := host.ask(n + 1).await()
        \\    log << '%{name}2=%{b}'
        \\fn pair(log ^ArrayStore[str]):
        \\    futs := []Future[int]{host.ask(100), host.ask(200)}
        \\    k := Future.wait_any(futs.span())
        \\    log << 'pair%{k}=%{futs[k].await()}'
        \\log := ^ArrayStore[str]{}
        \\x := fiber work('x', 1, log)
        \\y := fiber work('y', 5, log)
        \\z := fiber pair(log)
        \\while x.status() != .done or y.status() != .done or z.status() != .done:
        \\    _ = x.resume()
        \\    _ = y.resume()
        \\    _ = z.resume()
        \\    _ = Fiber.wait_ready()
        \\test.eq(log.len(), 5)
        \\test.eq(log[0], 'y1=50')
        \\test.eq(log[1], 'pair1=2000')
        \\test.eq(log[2], 'x1=10')
        \\test.eq(log[3], 'x2=20')
        \\test.eq(log[4], 'y2=60')
        \\test.eq(Fiber.wait_ready(), false)
    , &res));
    // x asked 1, y asked 5, z asked 100 and 200. All four are pending at once.
    try zt.eq(4, Host.num_asked);
    var pending: [8]?*C.Future = @splat(null);
    try zt.eq(4, C.vm_pending_futures(vm, &pending, pending.len));
    for (Host.asked[0..4]) |asked| {
        try zt.eq(true, std.mem.indexOfScalar(?*C.Future, pending[0..4], asked) != null);
    }
    // A resume without a completion waits again.
    try zt.eq(C.Await, C.vm_resume(vm, &res));
    try zt.eq(4, C.vm_pending_futures(vm, null, 0));

    // y's first answer comes first: y goes on to its second question while x still waits.
    try zt.eq(true, completeInt(vm, Host.asked[1], 50));
    try zt.eq(C.Await, C.vm_resume(vm, &res));
    try zt.eq(5, Host.num_asked);
    try zt.eq(4, C.vm_pending_futures(vm, null, 0));

    // The second future of the `wait_any` in z.
    try zt.eq(true, completeInt(vm, Host.asked[3], 2000));
    try zt.eq(C.Await, C.vm_resume(vm, &res));
    try zt.eq(2, C.vm_pending_futures(vm, null, 0));

    try zt.eq(true, completeInt(vm, Host.asked[0], 10));
    try zt.eq(C.Await, C.vm_resume(vm, &res));
    try zt.eq(6, Host.num_asked);
    try zt.eq(true, completeInt(vm, Host.asked[5], 20));
    try zt.eq(C.Await, C.vm_resume(vm, &res));
    try zt.eq(true, completeInt(vm, Host.asked[4], 60));
    try zt.eq(C.Success, C.vm_resume(vm, &res));
    try zt.eq(null, C.vm_pending_future(vm));
}

test "A scope cancels the fibers that wait for host futures when another fiber fails." {
    // Leak-checking allocator: the cancelled fibers release their frames, the futures they waited for and the
    // list of a `Future.wait_any`. The host never completes anything and the eval never leaves the VM.
    const vm = Host.init();
    defer C.vm_deinit(vm);

    var res: C.EvalResult = undefined;
    try zt.eq(C.Success, C.vm_eval(vm,
        \\use host
        \\use test
        \\fn ask(n int, log ^ArrayStore[str]) -> !void:
        \\    held := 'held' + '-padding-padding-padding-padding-%{n}'
        \\    v := host.ask(n).await()
        \\    log << '%{held} %{v}'
        \\fn ask_any(log ^ArrayStore[str]):
        \\    futs := []Future[int]{host.ask(10), host.ask(20)}
        \\    k := Future.wait_any(futs.span())
        \\    log << 'any %{k}'
        \\fn fail() -> !void:
        \\    suspend
        \\    return error.Stop
        \\fn run(log ^ArrayStore[str]) -> !void:
        \\    s := Scope.new()
        \\    s.start(ask, {1, log})
        \\    s.start(ask_any, {log})
        \\    s.start(fail, {})
        \\    s.start(ask, {2, log})
        \\    s.join()!
        \\log := ^ArrayStore[str]{}
        \\res := run(log)
        \\test.eq(res.unwrap_error(), error.Stop)
        \\test.eq(log.len(), 0)
        \\test.eq(Fiber.wait_ready(), false)
    , &res));
    // The last fiber was started before the failure and asked too.
    try zt.eq(4, Host.num_asked);
    try zt.eq(null, C.vm_pending_future(vm));
}

test "A scope block at the root waits for the host futures of nested groups, and an abandon frees them." {
    // Leak-checking allocator. The fibers borrow values of the functions that hold their blocks.
    const src =
        \\use host
        \\use test
        \\fn ask(n int, out &int) -> !void:
        \\    held := 'held' + '-padding-padding-padding-padding-%{n}'
        \\    v := host.ask(n).await()
        \\    out.* += v
        \\fn group(base int, out &int) -> !void:
        \\    sum := 0
        \\    scope |s|:
        \\        s.start(ask, {base, &sum})
        \\        s.start(ask, {base + 1, &sum})
        \\    out.* += sum
        \\fn run() -> !int:
        \\    total := 0
        \\    scope |s|:
        \\        s.start(group, {10, &total})
        \\        s.start(ask, {30, &total})
        \\        return total
        \\test.eq(run()!, 600)
    ;
    {
        const vm = Host.init();
        defer C.vm_deinit(vm);
        var res: C.EvalResult = undefined;
        try zt.eq(C.Await, C.vm_eval(vm, src, &res));
        // The group asked 10 and 11, then the second fiber of the root block asked 30.
        try zt.eq(3, Host.num_asked);
        try zt.eq(3, C.vm_pending_futures(vm, null, 0));
        try zt.eq(true, completeInt(vm, Host.asked[2], 300));
        try zt.eq(C.Await, C.vm_resume(vm, &res));
        try zt.eq(2, C.vm_pending_futures(vm, null, 0));
        try zt.eq(true, completeInt(vm, Host.asked[0], 100));
        try zt.eq(true, completeInt(vm, Host.asked[1], 200));
        try zt.eq(C.Success, C.vm_resume(vm, &res));
        try zt.eq(null, C.vm_pending_future(vm));
    }
    {
        const vm = Host.init();
        defer C.vm_deinit(vm);
        var res: C.EvalResult = undefined;
        try zt.eq(C.Await, C.vm_eval(vm, src, &res));
        try zt.eq(3, C.vm_pending_futures(vm, null, 0));
        C.vm_abandon(vm);
        try zt.eq(null, C.vm_pending_future(vm));
        try zt.eq(C.Success, C.vm_eval(vm, "_ = 1", &res));
    }
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

test "A host future of a result with a managed payload completes with a value or an error." {
    const vm = Host.init();
    defer C.vm_deinit(vm);
    const t = C.vm_main_thread(vm);

    var res: C.EvalResult = undefined;
    try zt.eq(C.Await, C.vm_eval(vm,
        \\use host
        \\use test
        \\s := host.ask_res_str().await()
        \\copy := s
        \\test.eq(copy!, 'from the host')
        \\test.eq(s!, 'from the host')
        \\e := host.ask_res_str().await()
        \\test.eq(e !else 'denied', 'denied')
        \\ints := host.ask_res_ints().await()
        \\ints2 := ints
        \\test.eq(ints2!.len(), 2)
        \\test.eq(ints![0], 1)
        \\test.eq(ints![1], 2)
        \\ie := host.ask_res_ints().await()
        \\test.eq(ie.unwrap_error(), error.Denied)
    , &res));
    const s = C.str_init(t, "from the host");
    try zt.eq(true, C.future_complete(vm, C.vm_pending_future(vm), &s));
    try zt.eq(C.Await, C.vm_resume(vm, &res));
    try zt.eq(true, C.future_complete_error(vm, C.vm_pending_future(vm), C.symbol(vm, "Denied")));
    try zt.eq(C.Await, C.vm_resume(vm, &res));
    const ints = C.slice_init(t, 2, 8);
    const elems: [*]i64 = @ptrCast(@alignCast(ints.ptr));
    elems[0] = 1;
    elems[1] = 2;
    try zt.eq(true, C.future_complete(vm, C.vm_pending_future(vm), &ints));
    try zt.eq(C.Await, C.vm_resume(vm, &res));
    try zt.eq(true, C.future_complete_error(vm, C.vm_pending_future(vm), C.symbol(vm, "Denied")));
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
        \\_ = Fiber.wait_ready()
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

    // An interrupt request that arrives while the eval is suspended is dropped by the resume, like one that
    // arrives before an eval starts. The time of the suspension is the host's.
    try zt.eq(C.Await, C.vm_eval(vm,
        \\use host
        \\use test
        \\n := host.ask(1).await()
        \\for 0..1000 |i|:
        \\    n += 1
        \\test.eq(n, 1001)
    , &res));
    C.vm_interrupt(vm);
    try zt.eq(true, completeInt(vm, C.vm_pending_future(vm), 1));
    try zt.eq(C.Success, C.vm_resume(vm, &res));

    // A request after the resume stops the eval.
    try zt.eq(C.Await, C.vm_eval(vm,
        \\use host
        \\n := host.ask(1).await()
        \\host.stop()
        \\while true:
        \\    n += 1
    , &res));
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

test "Future.wait_any suspends the eval until the host completes one of the futures." {
    const vm = Host.init();
    defer C.vm_deinit(vm);
    C.setSilent(true);
    defer C.setSilent(false);

    var res: C.EvalResult = undefined;
    // Three tools are started before any of them is awaited. The host answers in its own order.
    try zt.eq(C.Await, C.vm_eval(vm,
        \\use host
        \\use test
        \\fn first_done(futs []Future[int]) -> int:
        \\    return Future.wait_any(futs.span())
        \\futs := []Future[int]{host.ask(1), host.ask(2), host.ask(3)}
        \\order := ^ArrayStore[int]{}
        \\left := futs.len()
        \\done := []bool{false, false, false}
        \\while left > 0:
        \\    pending := []Future[int]{}
        \\    index := []int{}
        \\    for 0..futs.len() |i|:
        \\        if !done[i]:
        \\            pending = pending.append(futs[i])
        \\            index = index.append(i)
        \\    k := first_done(pending)
        \\    done[index[k]] = true
        \\    order << pending[k].await()
        \\    left -= 1
        \\test.eq(order[0], 20)
        \\test.eq(order[1], 10)
        \\test.eq(order[2], 30)
    , &res));
    try zt.eq(3, Host.num_asked);

    var pending: [4]?*C.Future = @splat(null);
    try zt.eq(3, C.vm_pending_futures(vm, &pending, pending.len));
    try zt.eq(Host.asked[0], pending[0]);
    try zt.eq(Host.asked[1], pending[1]);
    try zt.eq(Host.asked[2], pending[2]);
    // The count is returned without a buffer and with a short one.
    try zt.eq(3, C.vm_pending_futures(vm, null, 0));
    var one: [1]?*C.Future = .{null};
    try zt.eq(3, C.vm_pending_futures(vm, &one, 1));
    try zt.eq(Host.asked[0], one[0]);
    try zt.eq(Host.asked[0], C.vm_pending_future(vm));

    // A resume without a completion waits again for the same list.
    try zt.eq(C.Await, C.vm_resume(vm, &res));
    try zt.eq(3, C.vm_pending_futures(vm, null, 0));

    // The second tool finishes first.
    try zt.eq(true, completeInt(vm, Host.asked[1], 20));
    try zt.eq(C.Await, C.vm_resume(vm, &res));
    try zt.eq(2, C.vm_pending_futures(vm, &pending, pending.len));
    try zt.eq(Host.asked[0], pending[0]);
    try zt.eq(Host.asked[2], pending[1]);

    // Two completions before one resume: the script sees them in list order without another suspension.
    try zt.eq(true, completeInt(vm, Host.asked[2], 30));
    try zt.eq(true, completeInt(vm, Host.asked[0], 10));
    try zt.eq(C.Success, C.vm_resume(vm, &res));
    try zt.eq(0, C.vm_pending_futures(vm, null, 0));

    // A single await is a list of one.
    try zt.eq(C.Await, C.vm_eval(vm, "use host\n_ = host.ask(1).await()", &res));
    try zt.eq(1, C.vm_pending_futures(vm, &pending, pending.len));
    try zt.eq(C.vm_pending_future(vm), pending[0]);

    // Abandoned in a wait for several futures.
    C.vm_abandon(vm);
    try zt.eq(C.Await, C.vm_eval(vm,
        \\use host
        \\futs := []Future[int]{host.ask(1), host.ask(2)}
        \\_ = Future.wait_any(futs.span())
    , &res));
    C.vm_abandon(vm);
    try zt.eq(0, C.vm_pending_futures(vm, null, 0));

    // No futures is a panic, and a completed future does not suspend.
    try zt.eq(C.ErrorPanic, C.vm_eval(vm, "_ = Future.wait_any([]Future[int]{}.span())", &res));
    try zt.eq(C.Success, C.vm_eval(vm,
        \\use host
        \\use test
        \\futs := []Future[int]{host.ask(1), host.ask_done(4)}
        \\test.eq(Future.wait_any(futs.span()), 1)
        \\test.eq(futs[1].await(), 8)
    , &res));

    if (cy.isWasm) return;
    // With a future of a spawned thread in the list, the wait stays in the VM until that thread is done.
    try zt.eq(C.Success, C.vm_eval(vm,
        \\use host
        \\use test
        \\fn work(n int) -> int:
        \\    return n * 2
        \\futs := []Future[int]{host.ask(1), spawn(work, {21})}
        \\test.eq(Future.wait_any(futs.span()), 1)
        \\test.eq(futs[1].await(), 42)
    , &res));
}

test "A host that keeps the pointers of its futures retains them." {
    // A pending future that the script drops is freed, and the next future can get its address. A host that
    // looks a request up by the pointer would then find two requests for one pointer.
    const vm = Host.init();
    defer C.vm_deinit(vm);
    C.setSilent(true);
    defer C.setSilent(false);
    const t = C.vm_main_thread(vm);
    Host.retain = true;
    defer Host.retain = false;

    var res: C.EvalResult = undefined;
    try zt.eq(C.Await, C.vm_eval(vm,
        \\use host
        \\use test
        \\for 0..4 |i|:
        \\    _ = host.ask(i)
        \\test.eq(host.ask(9).await(), 90)
    , &res));
    try zt.eq(5, Host.num_asked);
    // The retained futures are alive, so every request has its own pointer.
    for (1..Host.num_asked) |i| {
        for (0..i) |j| {
            try zt.expect(Host.asked[i] != Host.asked[j]);
        }
    }
    try zt.eq(Host.asked[4], C.vm_pending_future(vm));
    // A future that the script dropped can still be completed. Nobody reads the value.
    try zt.eq(true, completeInt(vm, Host.asked[0], 1));
    try zt.eq(true, completeInt(vm, Host.asked[4], 90));
    try zt.eq(C.Success, C.vm_resume(vm, &res));
    // The eval ended normally: the host gives its references back.
    Host.releaseAll(t);

    // After a panic, an interrupt or `cl_vm_abandon` the heap of the eval is freed, with the futures in it.
    // The host forgets its pointers. It does not release them.
    try zt.eq(C.Await, C.vm_eval(vm,
        \\use host
        \\_ = host.ask(1)
        \\_ = host.ask(2).await()
    , &res));
    try zt.eq(2, Host.num_asked);
    C.vm_abandon(vm);
    Host.reset();
    try zt.eq(C.Await, C.vm_eval(vm,
        \\use host
        \\_ = host.ask(1)
        \\n := host.ask(2).await()
        \\panic('after %{n}')
    , &res));
    try zt.eq(true, completeInt(vm, C.vm_pending_future(vm), 2));
    try zt.eq(C.ErrorPanic, C.vm_resume(vm, &res));
    Host.reset();
    try zt.eq(C.Success, C.vm_eval(vm, "_ = 1 + 2", &res));
}

test "cl_future_tag identifies the request of a pending future." {
    const vm = Host.init();
    defer C.vm_deinit(vm);
    C.setSilent(true);
    defer C.setSilent(false);

    var res: C.EvalResult = undefined;
    // Futures that the script drops are freed and their addresses are used again. The tags stay apart.
    try zt.eq(C.Await, C.vm_eval(vm,
        \\use host
        \\use test
        \\for 0..4 |i|:
        \\    _ = host.ask(i)
        \\test.eq(host.ask(9).await(), 90)
        \\futs := []Future[int]{host.ask(5), host.ask(6)}
        \\test.eq(Future.wait_any(futs.span()), 1)
        \\test.eq(futs[1].await(), 60)
    , &res));
    try zt.eq(5, Host.num_asked);
    const f = C.vm_pending_future(vm).?;
    try zt.eq(5, C.future_tag(f));
    try zt.eq(9, Host.args[@as(usize, @intCast(C.future_tag(f))) - 1]);
    try zt.eq(true, completeInt(vm, f, 90));

    try zt.eq(C.Await, C.vm_resume(vm, &res));
    var pending: [2]?*C.Future = .{ null, null };
    try zt.eq(2, C.vm_pending_futures(vm, &pending, pending.len));
    try zt.eq(6, C.future_tag(pending[0]));
    try zt.eq(7, C.future_tag(pending[1]));
    try zt.eq(true, completeInt(vm, pending[1], 60));
    try zt.eq(C.Success, C.vm_resume(vm, &res));

    // A future of the script has the tag 0.
    try zt.eq(C.Await, C.vm_eval(vm,
        \\r := FutureResolver.new(int)
        \\_ = r.future().await()
    , &res));
    try zt.eq(0, C.future_tag(C.vm_pending_future(vm)));
    C.vm_abandon(vm);
}
