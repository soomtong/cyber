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
    \\#[generator]
    \\fn gen(n int) -> int:
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
