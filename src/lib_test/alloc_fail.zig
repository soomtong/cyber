const std = @import("std");
const builtin = @import("builtin");
const stdx = @import("stdx");
const C = @import("../capi.zig");
const zt = stdx.testing;

/// Fails the `fail_at`-th allocation while `armed`, and with `sticky` every allocation after it.
/// A resize or a remap that grows a block counts as an allocation.
const FailingAlloc = struct {
    child: std.mem.Allocator,
    n: usize = 0,
    fail_at: usize = 0,
    sticky: bool = false,
    armed: bool = false,
    fired: bool = false,

    fn allocator(self: *FailingAlloc) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn hit(self: *FailingAlloc) bool {
        if (!self.armed) return false;
        self.n += 1;
        if (self.n == self.fail_at or (self.sticky and self.n > self.fail_at)) {
            self.fired = true;
            return true;
        }
        return false;
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *FailingAlloc = @ptrCast(@alignCast(ctx));
        if (self.hit()) return null;
        return self.child.rawAlloc(len, alignment, ra);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *FailingAlloc = @ptrCast(@alignCast(ctx));
        if (new_len > memory.len and self.hit()) return false;
        return self.child.rawResize(memory, alignment, new_len, ra);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *FailingAlloc = @ptrCast(@alignCast(ctx));
        if (new_len > memory.len and self.hit()) return null;
        return self.child.rawRemap(memory, alignment, new_len, ra);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *FailingAlloc = @ptrCast(@alignCast(ctx));
        self.child.rawFree(memory, alignment, ra);
    }

    const vtable: std.mem.Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };
};

/// Evals `failing_alloc_src` on a new VM whose allocator fails at `fail_at`, in a REPL session after a first
/// eval if `session`. Returns the number of allocations the eval asked for.
fn evalWithFailingAlloc(session: bool, fail_at: usize, sticky: bool) !usize {
    var fa = FailingAlloc{ .child = zt.alloc, .fail_at = fail_at, .sticky = sticky };
    const vm = C.vm_initx(fa.allocator());
    defer C.vm_deinit(vm);

    var config = C.defaultEvalConfig();
    config.persist_main = session;
    var res: C.EvalResult = undefined;
    if (session) {
        try zt.eq(C.Success, C.vm_evalx(vm, "main", "kept := 1", config, &res));
    }

    fa.armed = true;
    const code = C.vm_evalx(vm, "main", failing_alloc_src, config, &res);
    // The host asks for the report while its allocator still fails.
    const report = C.vm_error_summary(vm);
    fa.armed = false;
    C.vm_freeb(vm, report);

    if (!fa.fired) {
        try zt.eq(C.Success, code);
    } else if (code != C.Success) {
        // A failure that is not absorbed (a buffer that could not grow in place is allocated anew) is an error
        // of the eval: in the compiler, in the script, or in the bookkeeping after the run.
        try zt.expect(code == C.ErrorCompile or code == C.ErrorPanic or code == C.ErrorUnknown);
    }

    if (session and code == C.ErrorCompile) {
        // The compiler was left at an arbitrary point, so the next eval starts from a reset VM.
        try zt.eq(C.ErrorCompile, C.vm_evalx(vm, "main", "kept", config, &res));
    }
    try zt.eq(C.Success, C.vm_evalx(vm, "main",
        \\after := Array[int]{}
        \\after << 1
        \\after << 2
        \\if after.len() != 2: panic('after')
    , config, &res));
    return fa.n;
}

const failing_alloc_src =
    \\use test
    \\use meta
    \\type Node:
    \\  val  int
    \\  next ?^Node
    \\type Shape enum:
    \\  case circle float
    \\  case rect   int
    \\type Pair[T Any]:
    \\  a T
    \\  b T
    \\fn sum[T Any](p Pair[T]) -> T:
    \\  return p.a + p.b
    \\fn area(s Shape) -> float:
    \\  switch s:
    \\    case .circle |r|: return r * r * 3.0
    \\    case .rect |w|: return float(w)
    \\generator fn gen(n int) -> int:
    \\  for 0..n |i|:
    \\    yield i
    \\names := Array[str]{}
    \\m := Map[str, int]{}
    \\var head ?^Node = none
    \\for 0..40 |i|:
    \\  names << 'k%{i}'
    \\  m['k%{i}'] = i
    \\  head = ^Node{val=i, next=head}
    \\test.eq(40, names.len())
    \\test.eq(40, m.size())
    \\test.eq(3, sum[int](Pair[int]{a=1, b=2}))
    \\test.eq(12.0, area(Shape.circle(2.0)))
    \\total := 0
    \\for gen(10) |v|:
    \\  total += v
    \\test.eq(45, total)
;

test "An allocation that fails during an eval is an error, and the VM can be used again." {
    // F-41. A host allocator that returns null in the compiler used to abort, crash or leak.
    // `zt.alloc` checks that every failed eval gives back what it took.
    C.setSilent(true);
    defer C.setSilent(false);

    for ([_]bool{ false, true }) |session| {
        const total = try evalWithFailingAlloc(session, 0, false);
        try zt.expect(total > 100);

        // Failures spread over the eval: loading the builtin modules, sema, code generation and the run.
        const samples = 4;
        for (1..samples + 1) |i| {
            _ = try evalWithFailingAlloc(session, total * i / (samples + 1), false);
        }
        // An allocator that stays empty, as a host arena that ran out would.
        _ = try evalWithFailingAlloc(session, total / 3, true);
        _ = try evalWithFailingAlloc(session, total - 20, true);
    }
}

test "A type declaration that fails part way frees what it reserved." {
    // Found by the allocation fuzz of F-41, but these fail with an ordinary compile error.
    C.setSilent(true);
    defer C.setSilent(false);

    const srcs = [_][]const u8{
        // The second method fails after the first one was reserved.
        \\type Shape trait:
        \\    fn area() -> float
        \\    fn name() -> Missing
        ,
        // The second case fails after the list of cases was allocated.
        \\type Color enum:
        \\    case red
        \\    case red
        ,
        \\type Shape enum:
        \\    case circle float
        \\    case rect   Missing
        ,
    };
    for (srcs) |src| {
        // `zt.alloc` reports what the VM did not free.
        const vm = C.vm_initx(zt.alloc);
        defer C.vm_deinit(vm);
        var res: C.EvalResult = undefined;
        try zt.eq(C.ErrorCompile, C.vm_eval(vm, src, &res));
        try zt.eq(C.Success, C.vm_eval(vm, "a := 1", &res));
    }
}

test "A VM that can not be created returns null and leaves nothing allocated." {
    // `zt.alloc` reports what a failed `cl_vm_initx` did not give back. Every allocation of the init fails
    // once, and with `sticky` every allocation after it too, as a host arena that ran out would.
    for ([_]bool{ false, true }) |sticky| {
        const n = try initWithFailingAlloc(sticky);
        try zt.expect(n > 10);
    }
}

fn initWithFailingAlloc(sticky: bool) !usize {
    var n: usize = 1;
    while (true) : (n += 1) {
        var fa = FailingAlloc{ .child = zt.alloc, .fail_at = n, .sticky = sticky, .armed = true };
        const vm = C.c.cl_vm_initx(C.toAllocator(fa.allocator())) orelse {
            try zt.expect(fa.fired);
            continue;
        };
        fa.armed = false;
        defer C.vm_deinit(vm);
        // A failure can be absorbed (a block that could not grow in place is allocated anew). The VM works.
        var res: C.EvalResult = undefined;
        try zt.eq(C.Success, C.vm_eval(vm, "a := 1", &res));
        // Past the last allocation of the init.
        if (!fa.fired) return n;
    }
}

/// The allocator of the VM in the host functions below, which fail the next allocation they ask for.
var host_fa: ?*FailingAlloc = null;

fn failNextAlloc() void {
    const fa = host_fa.?;
    fa.n = 0;
    fa.fail_at = 1;
    fa.sticky = false;
    fa.fired = false;
    fa.armed = true;
}

// Longer than the small inline form, so the heap is asked for a buffer.
const long_host_str = "a string that the host function builds on the heap, long enough for its own buffer.";

const HostOom = struct {
    fn make_str(t: *C.Thread) callconv(.c) C.Ret {
        const ret: *C.str = C.thread_ret(t, C.str);
        failNextAlloc();
        ret.* = C.str_init(t, long_host_str);
        host_fa.?.armed = false;
        // The host returns as usual. The VM sees the failure.
        return C.RetOk;
    }
    fn make_slice(t: *C.Thread) callconv(.c) C.Ret {
        const ret: *C.Slice = C.thread_ret(t, C.Slice);
        failNextAlloc();
        ret.* = C.slice_init(t, 64, 8);
        host_fa.?.armed = false;
        return C.RetOk;
    }
    fn make_own_panic(t: *C.Thread) callconv(.c) C.Ret {
        const ret: *C.str = C.thread_ret(t, C.str);
        failNextAlloc();
        ret.* = C.str_init(t, long_host_str);
        host_fa.?.armed = false;
        // A host that checks gives its own panic, which is kept.
        return C.thread_ret_panic(t, "The host is out of memory.");
    }
    fn loader(vm_: *C.VM, mod: *C.Sym, uri: C.Bytes, res: [*c]C.LoaderResult) callconv(.c) bool {
        if (std.mem.eql(u8, C.from_bytes(uri), "mod")) {
            C.mod_add_func(mod, "make_str", C.BIND_FUNC(&make_str));
            C.mod_add_func(mod, "make_slice", C.BIND_FUNC(&make_slice));
            C.mod_add_func(mod, "make_own_panic", C.BIND_FUNC(&make_own_panic));
            res[0].src = C.to_bytes(
                \\#[bind] fn make_str() -> str
                \\#[bind] fn make_slice() -> []int
                \\#[bind] fn make_own_panic() -> str
            );
            return true;
        }
        return C.default_loader(vm_, mod, uri, res);
    }
};

test "A value that a host function can not create ends the call with an OutOfMemory panic." {
    // `cl_str_init` and the other value-creating functions used to abort the process.
    C.setSilent(true);
    defer C.setSilent(false);
    var fa = FailingAlloc{ .child = zt.alloc };
    host_fa = &fa;
    defer host_fa = null;
    const vm = C.vm_initx(fa.allocator());
    defer C.vm_deinit(vm);
    C.vm_set_loader(vm, @ptrCast(&HostOom.loader));

    const cases = [_]struct { src: []const u8, summary: []const u8 }{
        .{ .src = "use mod\ns := mod.make_str()\nprint(s)", .summary = "panic: OutOfMemory\n" },
        .{ .src = "use mod\nxs := mod.make_slice()\nprint(xs.len())", .summary = "panic: OutOfMemory\n" },
        // Called from a function value: the call goes through `Thread.callFunc`.
        .{ .src = "use mod\nf := mod.make_str\ns := f()\nprint(s)", .summary = "panic: OutOfMemory\n" },
        .{ .src = "use mod\ns := mod.make_own_panic()", .summary = "panic: The host is out of memory.\n" },
    };
    for (cases) |case| {
        var res: C.EvalResult = undefined;
        try zt.eq(C.ErrorPanic, C.vm_eval(vm, case.src, &res));
        try zt.expect(fa.fired);
        const report = C.vm_error_summary(vm);
        defer C.vm_freeb(vm, report);
        try zt.expect(std.mem.startsWith(u8, report, case.summary));
        // The flag does not carry over to the next eval.
        try zt.eq(C.Success, C.vm_eval(vm, "a := 'still alive' + ' here'", &res));
    }
}

test "A reset that runs out of memory leaves a pending reset, and the next eval starts over." {
    // Every allocation of `cl_vm_reset` fails once, and with `sticky` every allocation after it too.
    for ([_]bool{ false, true }) |sticky| {
        var pending_seen = false;
        var n: usize = 1;
        while (true) : (n += 1) {
            var fa = FailingAlloc{ .child = zt.alloc };
            const vm = C.vm_initx(fa.allocator());
            defer C.vm_deinit(vm);
            var config = C.defaultEvalConfig();
            config.persist_main = true;
            var res: C.EvalResult = undefined;
            try zt.eq(C.Success, C.vm_evalx(vm, "main", "kept := 1", config, &res));

            fa = .{ .child = zt.alloc, .fail_at = n, .sticky = sticky, .armed = true };
            C.vm_reset(vm);
            fa.armed = false;
            // A failure can be absorbed (a block that could not grow in place is allocated anew).
            if (C.vm_reset_pending(vm)) pending_seen = true;
            try zt.eq(C.Success, C.vm_evalx(vm, "main", "a := 2", config, &res));
            try zt.expect(!C.vm_reset_pending(vm));
            // The session of before the reset is gone either way.
            try zt.eq(C.ErrorCompile, C.vm_evalx(vm, "main", "b := kept", config, &res));
            if (!fa.fired) break;
        }
        try zt.expect(pending_seen);
    }
}

test "An API error without memory for its message is still reported." {
    var fa = FailingAlloc{ .child = zt.alloc };
    const vm = C.vm_initx(fa.allocator());
    defer C.vm_deinit(vm);
    C.reportApiError(vm, C.to_bytes("the first message"));
    fa = .{ .child = zt.alloc, .fail_at = 1, .armed = true };
    C.reportApiError(vm, C.to_bytes("the second message"));
    fa.armed = false;
    try zt.expect(fa.fired);
}
