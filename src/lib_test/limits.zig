const std = @import("std");
const stdx = @import("stdx");
const cy = @import("../cyber.zig");
const C = @import("../capi.zig");
const zt = stdx.testing;
const is_wasm = @import("util.zig").is_wasm;

test "cl_vm_set_stack_limit turns runaway recursion into a panic." {
    // F-40. Leak-checking allocator: the panic sweep frees the values left in the abandoned frames.
    const vm = C.vm_initx(zt.alloc);
    defer C.vm_deinit(vm);
    C.setSilent(true);
    defer C.setSilent(false);

    C.vm_set_stack_limit(vm, 1024 * 1024);
    var res: C.EvalResult = undefined;
    try zt.eq(C.ErrorPanic, C.vm_eval(vm,
        \\fn f(n int) -> int:
        \\  return f(n + 1) + 1
        \\_ = f(0)
    , &res));
    {
        const report = C.vm_error_summary(vm);
        defer C.vm_freeb(vm, report);
        try zt.eq(true, std.mem.startsWith(u8, report, "panic: Stack overflow. The stack limit is 1048576 bytes."));
        // The trace keeps both ends and elides the middle.
        try zt.expect(std.mem.indexOf(u8, report, "frames omitted") != null);
        try zt.expect(std.mem.indexOf(u8, report, " main:") != null);
    }

    // Managed arguments in the abandoned frames.
    try zt.eq(C.ErrorPanic, C.vm_eval(vm,
        \\fn g(s str, n int) -> int:
        \\  return g(s, n + 1) + 1
        \\_ = g('abc' + 'def', 0)
    , &res));

    // Recursion that fits the limit, and the VM is still usable.
    try zt.eq(C.Success, C.vm_eval(vm,
        \\fn depth(n int) -> int:
        \\  if n == 0:
        \\    return 0
        \\  return depth(n - 1) + 1
        \\use test
        \\test.eq(1000, depth(1000))
    , &res));

    // 200000 levels need more than 1 MiB. Removing the limit lets the stack grow again.
    try zt.eq(C.ErrorPanic, C.vm_eval(vm,
        \\fn depth(n int) -> int:
        \\  if n == 0:
        \\    return 0
        \\  return depth(n - 1) + 1
        \\_ = depth(200000)
    , &res));
    C.vm_set_stack_limit(vm, 0);
    try zt.eq(C.Success, C.vm_eval(vm,
        \\fn depth(n int) -> int:
        \\  if n == 0:
        \\    return 0
        \\  return depth(n - 1) + 1
        \\use test
        \\test.eq(200000, depth(200000))
    , &res));
}

/// Host allocator of the memory limit tests: records the most bytes the VM held at once.
const PeakAlloc = struct {
    child: std.mem.Allocator,
    held: std.atomic.Value(usize) = .init(0),
    peak: std.atomic.Value(usize) = .init(0),

    fn allocator(self: *PeakAlloc) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn grew(self: *PeakAlloc, old_len: usize, new_len: usize) void {
        if (new_len >= old_len) {
            const now = self.held.fetchAdd(new_len - old_len, .monotonic) + (new_len - old_len);
            _ = self.peak.fetchMax(now, .monotonic);
        } else {
            _ = self.held.fetchSub(old_len - new_len, .monotonic);
        }
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *PeakAlloc = @ptrCast(@alignCast(ctx));
        const ptr = self.child.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.grew(0, len);
        return ptr;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *PeakAlloc = @ptrCast(@alignCast(ctx));
        if (!self.child.rawResize(memory, alignment, new_len, ret_addr)) return false;
        self.grew(memory.len, new_len);
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *PeakAlloc = @ptrCast(@alignCast(ctx));
        const ptr = self.child.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        self.grew(memory.len, new_len);
        return ptr;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *PeakAlloc = @ptrCast(@alignCast(ctx));
        self.child.rawFree(memory, alignment, ret_addr);
        self.grew(memory.len, 0);
    }
};

test "cl_vm_set_memory_limit turns runaway allocation into a panic." {
    // F-41. Leak-checking allocator below the VM: the panic frees what the script allocated.
    var host = PeakAlloc{ .child = zt.alloc };
    const vm = C.vm_initx(host.allocator());
    defer C.vm_deinit(vm);
    C.setSilent(true);
    defer C.setSilent(false);

    var res: C.EvalResult = undefined;
    // The first eval loads `core`. The limit is set on top of what the VM holds after it.
    try zt.eq(C.Success, C.vm_eval(vm, "a := 1", &res));
    // The count is the host allocator's, less the `VM` object and the counter itself.
    try zt.expect(C.vm_memory_used(vm) > 1024 * 1024);
    try zt.expect(C.vm_memory_used(vm) < host.held.load(.monotonic));
    try zt.expect(host.held.load(.monotonic) - C.vm_memory_used(vm) < 64 * 1024);

    const room = 4 * 1024 * 1024;
    const srcs = [_][]const u8{
        // Array buffer.
        \\a := Array[int]{}
        \\for 0..100000000 |i|:
        \\  a << i
        ,
        // Map buffers.
        \\m := Map[int, int]{}
        \\for 0..100000000 |i|:
        \\  m[i] = i
        ,
        // One string that doubles, and many strings that stay.
        \\s := 'abcdefgh'
        \\for 0..100 |i|:
        \\  s += s
        ,
        \\a := Array[str]{}
        \\for 0..100000000 |i|:
        \\  a << str(i)
        ,
        // Pool objects: the heap pages.
        \\type Node:
        \\  value int
        \\  next ?^Node
        \\head := ?^Node(none)
        \\for 0..100000000 |i|:
        \\  head = ^Node{value=i, next=head}
        ,
        // Objects larger than a pool slot.
        \\type Big:
        \\  a int
        \\  b int
        \\  c int
        \\  d int
        \\  e int
        \\  next ?^Big
        \\head := ?^Big(none)
        \\for 0..100000000 |i|:
        \\  head = ^Big{a=i, b=i, c=i, d=i, e=i, next=head}
        ,
        // The stack.
        \\fn f(n int) -> int:
        \\  return f(n + 1) + 1
        \\_ = f(0)
        ,
    };
    for (srcs) |src| {
        const before = C.vm_memory_used(vm);
        const limit = before + room;
        C.vm_set_memory_limit(vm, @intCast(limit));
        host.peak.store(0, .monotonic);
        try zt.eq(C.ErrorPanic, C.vm_eval(vm, src, &res));
        {
            const report = C.vm_error_summary(vm);
            defer C.vm_freeb(vm, report);
            try zt.eq(true, std.mem.startsWith(u8, report, "panic: OutOfMemory\n"));
        }
        if (!cy.Trace) {
            // The host never held much more than the limit. The slack is what a panic records (the frames of the
            // runaway recursion) and what the compiler allocated for this eval.
            try zt.expect(host.peak.load(.monotonic) < limit + room / 2);
            // The script got most of its room before it was stopped.
            try zt.expect(host.peak.load(.monotonic) > before + room / 4);
            // The panic gave back the heap pages and the stack.
            try zt.expect(C.vm_memory_used(vm) < before + 256 * 1024);
        }
        // A Trace build keeps a record of every object that was allocated, and the records count as well.
        if (cy.Trace) C.vm_set_memory_limit(vm, @intCast(C.vm_memory_used(vm) + room));
        // The VM is usable with the limit still in place.
        try zt.eq(C.Success, C.vm_eval(vm,
            \\use test
            \\a := Array[str]{}
            \\for 0..1000 |i|:
            \\  a << str(i)
            \\test.eq(1000, a.len())
        , &res));
    }

    // A limit below what the VM already holds: the script can not allocate, and the compiler is not refused.
    C.vm_set_memory_limit(vm, 1);
    try zt.eq(C.ErrorPanic, C.vm_eval(vm,
        \\a := Array[int]{}
        \\for 0..100000 |i|:
        \\  a << i
    , &res));
    {
        const report = C.vm_error_summary(vm);
        defer C.vm_freeb(vm, report);
        try zt.eq(true, std.mem.startsWith(u8, report, "panic: OutOfMemory\n"));
    }
    try zt.eq(C.Success, C.vm_eval(vm,
        \\use test
        \\fn add(a int, b int) -> int:
        \\  return a + b
        \\test.eq(3, add(1, 2))
    , &res));

    // Zero or less removes the limit.
    for ([_]i64{ 0, -1 }) |no_limit| {
        C.vm_set_memory_limit(vm, 1);
        C.vm_set_memory_limit(vm, no_limit);
        try zt.eq(C.Success, C.vm_eval(vm,
            \\use test
            \\a := Array[int]{}
            \\for 0..1000000 |i|:
            \\  a << i
            \\test.eq(1000000, a.len())
        , &res));
    }
}

test "cl_vm_set_memory_limit covers spawned threads." {
    if (is_wasm) return;
    const vm = C.vm_initx(zt.alloc);
    defer C.vm_deinit(vm);
    C.setSilent(true);
    defer C.setSilent(false);

    var res: C.EvalResult = undefined;
    try zt.eq(C.Success, C.vm_eval(vm, "a := 1", &res));
    const src =
        \\fn grow(n int) -> int:
        \\  a := Array[int]{}
        \\  for 0..n |i|:
        \\    a << i
        \\  return a.len()
        \\use test
        \\test.eq(1000, spawn(grow, {1000}).await())
        \\_ = spawn(grow, {100000000}).await()
    ;
    C.vm_set_memory_limit(vm, @intCast(C.vm_memory_used(vm) + 4 * 1024 * 1024));
    try zt.eq(C.ErrorPanic, C.vm_eval(vm, src, &res));
    {
        const report = C.vm_error_summary(vm);
        defer C.vm_freeb(vm, report);
        try zt.eq(true, std.mem.startsWith(u8, report, "panic: Spawned thread panicked: OutOfMemory\n"));
    }
    try zt.eq(C.Success, C.vm_eval(vm,
        \\use test
        \\fn grow(n int) -> int:
        \\  a := Array[int]{}
        \\  for 0..n |i|:
        \\    a << i
        \\  return a.len()
        \\test.eq(1000, spawn(grow, {1000}).await())
    , &res));
}

/// The memory functions of a C host, on top of an allocator that checks the size and alignment of every free.
const CMem = struct {
    child: std.mem.Allocator,
    held: std.atomic.Value(usize) = .init(0),
    blocks: std.atomic.Value(usize) = .init(0),
    allocs: std.atomic.Value(usize) = .init(0),
    max_align: std.atomic.Value(usize) = .init(0),

    fn funcs(self: *CMem) C.MemFuncs {
        return .{ .ctx = self, .alloc = alloc, .free = free };
    }

    fn alloc(ctx: ?*anyopaque, size: usize, alignment: usize) callconv(.c) ?*anyopaque {
        const self: *CMem = @ptrCast(@alignCast(ctx));
        if (size == 0 or !std.math.isPowerOfTwo(alignment)) return null;
        const ptr = self.child.rawAlloc(size, .fromByteUnits(alignment), @returnAddress()) orelse return null;
        _ = self.held.fetchAdd(size, .monotonic);
        _ = self.blocks.fetchAdd(1, .monotonic);
        _ = self.allocs.fetchAdd(1, .monotonic);
        _ = self.max_align.fetchMax(alignment, .monotonic);
        return ptr;
    }

    fn free(ctx: ?*anyopaque, ptr: ?*anyopaque, size: usize, alignment: usize) callconv(.c) void {
        const self: *CMem = @ptrCast(@alignCast(ctx));
        const bytes: [*]u8 = @ptrCast(ptr.?);
        self.child.rawFree(bytes[0..size], .fromByteUnits(alignment), @returnAddress());
        _ = self.held.fetchSub(size, .monotonic);
        _ = self.blocks.fetchSub(1, .monotonic);
    }
};

test "cl_vm_init_mem runs a VM on the C memory functions of a host." {
    // F-41. A C host can not fill in a `CLAllocator`, which is a Zig vtable.
    var host = CMem{ .child = zt.alloc };
    {
        const vm = C.vm_init_mem(host.funcs());
        defer C.vm_deinit(vm);
        C.setSilent(true);
        defer C.setSilent(false);

        var res: C.EvalResult = undefined;
        // Buffers that grow are reallocated: without in-place growth that is a new block, a copy and a free.
        try zt.eq(C.Success, C.vm_eval(vm,
            \\use test
            \\a := Array[str]{}
            \\m := Map[int, int]{}
            \\s := ''
            \\for 0..20000 |i|:
            \\  a << str(i)
            \\  m[i] = i
            \\  s += 'x'
            \\test.eq(20000, a.len())
            \\test.eq(20000, m.size())
            \\test.eq(20000, s.len())
        , &res));
        try zt.expect(host.allocs.load(.monotonic) > 1000);

        // The host holds what the VM counts, and the `VM` object, the counter and the functions on top.
        const used = C.vm_memory_used(vm);
        try zt.expect(used > 1024 * 1024);
        try zt.expect(used < host.held.load(.monotonic));
        try zt.expect(host.held.load(.monotonic) - used < 64 * 1024);

        // The memory limit works the same on top of the host's functions.
        C.vm_set_memory_limit(vm, @intCast(used + 4 * 1024 * 1024));
        try zt.eq(C.ErrorPanic, C.vm_eval(vm,
            \\a := Array[int]{}
            \\for 0..100000000 |i|:
            \\  a << i
        , &res));
        {
            const report = C.vm_error_summary(vm);
            defer C.vm_freeb(vm, report);
            try zt.eq(true, std.mem.startsWith(u8, report, "panic: OutOfMemory\n"));
        }
        try zt.eq(C.Success, C.vm_eval(vm, "print('still alive')", &res));

        // Memory a host function takes from the VM comes from the same functions.
        const before = host.held.load(.monotonic);
        const buf = C.vm_allocb(vm, 4096);
        try zt.eq(before + 4096, host.held.load(.monotonic));
        C.vm_freeb(vm, buf);
        try zt.eq(before, host.held.load(.monotonic));
    }
    // `cl_vm_deinit` returned everything, the `VM` object and the functions included.
    try zt.eq(@as(usize, 0), host.blocks.load(.monotonic));
    try zt.eq(@as(usize, 0), host.held.load(.monotonic));
}

test "cl_vm_set_fuel stops runaway loops and recursion." {
    // Leak-checking allocator: stopping unwinds like a panic and frees the heap.
    const vm = C.vm_initx(zt.alloc);
    defer C.vm_deinit(vm);
    C.setSilent(true);
    defer C.setSilent(false);

    C.vm_set_fuel(vm, 10000);
    var res: C.EvalResult = undefined;
    try zt.eq(C.ErrorInterrupt, C.vm_eval(vm,
        \\s := 'abcdefghijklmnopqrstuvwxyz' + '0123456789'
        \\i := 0
        \\while true:
        \\  i += 1
    , &res));
    {
        const report = C.vm_error_summary(vm);
        defer C.vm_freeb(vm, report);
        try zt.eq(true, std.mem.startsWith(u8, report, "panic: Out of fuel."));
    }
    try zt.eq(C.ErrorInterrupt, C.vm_eval(vm,
        \\fn f(n int) -> int:
        \\  return f(n + 1)
        \\_ = f(0)
    , &res));

    // Enough fuel for a bounded loop, and the VM is still usable.
    try zt.eq(C.Success, C.vm_eval(vm,
        \\sum := 0
        \\for 0..100 |i|:
        \\  sum += i
        \\use test
        \\test.eq(4950, sum)
    , &res));

    // No limit.
    C.vm_set_fuel(vm, 0);
    try zt.eq(C.Success, C.vm_eval(vm,
        \\sum := 0
        \\for 0..100000 |i|:
        \\  sum += 1
    , &res));
}

test "cl_vm_interrupt stops a running eval." {
    const vm = C.vm_initx(zt.alloc);
    defer C.vm_deinit(vm);
    C.setSilent(true);
    defer C.setSilent(false);

    const S = struct {
        var started = std.atomic.Value(bool).init(false);
        var calls: usize = 0;

        // Interrupts from inside the eval on the 100th call.
        fn mod_tick(t_: *C.Thread) callconv(.c) C.Ret {
            _ = C.thread_ret(t_, void);
            calls += 1;
            if (calls == 100) {
                C.vm_interrupt(C.thread_vm(t_));
            }
            return C.RetOk;
        }
        // Lets the other thread know the loop is running.
        fn mod_started(t_: *C.Thread) callconv(.c) C.Ret {
            _ = C.thread_ret(t_, void);
            started.store(true, .release);
            return C.RetOk;
        }
        fn loader(vm_: *C.VM, mod: *C.Sym, uri: C.Bytes, res: [*c]C.LoaderResult) callconv(.c) bool {
            const name = C.from_bytes(uri);
            if (std.mem.eql(u8, name, "mod")) {
                C.mod_add_func(mod, "tick", C.BIND_FUNC(&mod_tick));
                C.mod_add_func(mod, "started", C.BIND_FUNC(&mod_started));
                res[0].src = C.to_bytes(
                    \\#[bind] fn tick()
                    \\#[bind] fn started()
                );
                return true;
            } else {
                return C.default_loader(vm_, mod, uri, res);
            }
        }
        fn interrupter(vm_: *C.VM) void {
            while (!started.load(.acquire)) {
                std.atomic.spinLoopHint();
            }
            C.vm_interrupt(vm_);
        }
    };
    C.vm_set_loader(vm, @ptrCast(&S.loader));

    var res: C.EvalResult = undefined;
    try zt.eq(C.ErrorInterrupt, C.vm_eval(vm,
        \\use mod
        \\while true:
        \\  mod.tick()
    , &res));
    try zt.eq(100, S.calls);
    {
        const report = C.vm_error_summary(vm);
        defer C.vm_freeb(vm, report);
        try zt.eq(true, std.mem.startsWith(u8, report, "panic: Interrupted."));
    }

    // The next eval starts with the request cleared.
    try zt.eq(C.Success, C.vm_eval(vm, "use mod\nmod.tick()", &res));

    // From another thread.
    if (cy.isWasm) return;
    const thread = try std.Thread.spawn(.{}, S.interrupter, .{vm});
    try zt.eq(C.ErrorInterrupt, C.vm_eval(vm,
        \\use mod
        \\mod.started()
        \\while true:
        \\  pass
    , &res));
    thread.join();
}

test "Spawned threads stop with the eval and do not abort the host." {
    if (is_wasm) return;
    const vm = C.vm_init();
    defer C.vm_deinit(vm);
    C.setSilent(true);
    defer C.setSilent(false);

    const S = struct {
        var started = std.atomic.Value(bool).init(false);
        fn mod_started(t_: *C.Thread) callconv(.c) C.Ret {
            _ = C.thread_ret(t_, void);
            started.store(true, .release);
            return C.RetOk;
        }
        fn loader(vm_: *C.VM, mod: *C.Sym, uri: C.Bytes, res: [*c]C.LoaderResult) callconv(.c) bool {
            const name = C.from_bytes(uri);
            if (std.mem.eql(u8, name, "mod")) {
                C.mod_add_func(mod, "started", C.BIND_FUNC(&mod_started));
                res[0].src = C.to_bytes("#[bind] fn started()");
                return true;
            } else {
                return C.default_loader(vm_, mod, uri, res);
            }
        }
        fn interrupter(vm_: *C.VM) void {
            while (!started.load(.acquire)) {
                std.atomic.spinLoopHint();
            }
            C.vm_interrupt(vm_);
        }
    };
    C.vm_set_loader(vm, @ptrCast(&S.loader));
    var res: C.EvalResult = undefined;

    // The spawned functions take an argument: `spawn(f, {})` with no arguments crashes at compile time in
    // ReleaseSafe when it is not the process's first VM (also before this change).
    // A spawned thread inherits the fuel limit.
    C.vm_set_fuel(vm, 10000);
    try zt.eq(C.ErrorInterrupt, C.vm_eval(vm,
        \\fn spin(start int) -> int:
        \\  i := start
        \\  while true:
        \\    i += 1
        \\  return i
        \\_ = spawn(spin, {0}).await()
    , &res));
    C.vm_set_fuel(vm, 0);

    // A host interrupt reaches the main thread waiting in `await` and the spawned thread.
    const thread = try std.Thread.spawn(.{}, S.interrupter, .{vm});
    try zt.eq(C.ErrorInterrupt, C.vm_eval(vm,
        \\use mod
        \\fn spin(start int) -> int:
        \\  mod.started()
        \\  i := start
        \\  while true:
        \\    i += 1
        \\  return i
        \\_ = spawn(spin, {0}).await()
    , &res));
    thread.join();

    // A panic in a spawned thread fails the eval instead of aborting the process, with the thread's message.
    try zt.eq(C.ErrorPanic, C.vm_eval(vm,
        \\fn boom(n int) -> int:
        \\  panic('boom')
        \\  return n
        \\_ = spawn(boom, {1}).await()
    , &res));
    {
        const report = C.vm_error_summary(vm);
        defer C.vm_freeb(vm, report);
        try zt.eq(true, std.mem.startsWith(u8, report, "panic: Spawned thread panicked: boom\n"));
    }

    // `await` inside a spawned thread blocks that thread. A panic below it reaches the main thread through
    // each awaiting thread. (Before, the nested `await` was a Zig `@panic("TODO")` that aborted the host.)
    try zt.eq(C.ErrorPanic, C.vm_eval(vm,
        \\fn boom(n int) -> int:
        \\  panic('boom')
        \\  return n
        \\fn mid(n int) -> int:
        \\  return spawn(boom, {n}).await() + 1
        \\_ = spawn(mid, {1}).await()
    , &res));
    {
        const report = C.vm_error_summary(vm);
        defer C.vm_freeb(vm, report);
        try zt.eq(true, std.mem.startsWith(u8, report, "panic: Spawned thread panicked: Spawned thread panicked: boom\n"));
    }

    // The fuel limit stops a thread below a nested `await` and the eval reports the interrupt.
    C.vm_set_fuel(vm, 10000);
    try zt.eq(C.ErrorInterrupt, C.vm_eval(vm,
        \\fn spin(start int) -> int:
        \\  i := start
        \\  while true:
        \\    i += 1
        \\  return i
        \\fn mid(n int) -> int:
        \\  return spawn(spin, {n}).await() + 1
        \\_ = spawn(mid, {0}).await()
    , &res));
    C.vm_set_fuel(vm, 0);

    // Still usable, including nested `await`.
    try zt.eq(C.Success, C.vm_eval(vm,
        \\fn add(a int, b int) -> int:
        \\  return a + b
        \\fn mid(a int) -> int:
        \\  return spawn(add, {a, 3}).await() * 10
        \\use test
        \\test.eq(5, spawn(add, {2, 3}).await())
        \\test.eq(50, spawn(mid, {2}).await())
    , &res));
}

test "Spawn without args works in every VM." {
    // `FnTuple[Sig]` loops zero times for a function without params. The compile-time body
    // used to read an unset loop result, which crashed later VMs in ReleaseSafe.
    if (is_wasm) return;
    for (0..2) |_| {
        const vm = C.vm_init();
        defer C.vm_deinit(vm);
        var res: C.EvalResult = undefined;
        try zt.eq(C.Success, C.vm_eval(vm,
            \\fn zero() -> int:
            \\  return 7
            \\use test
            \\test.eq(7, spawn(zero, {}).await())
        , &res));
    }
}
