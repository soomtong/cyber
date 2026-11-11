
// ---- PROBE: allocation-failure fuzz. See src/tools/alloc_fuzz/README.md. ----
// Not part of the build. `fuzz.sh build` appends this file to the end of `src/lib.zig`,
// builds the lib tests with `-Dtest-filter=PROBE` and restores `src/lib.zig`.
// It uses names that `src/lib.zig` already has (`std`, `zt`, `C`).
//
// One process runs one eval where only allocation number `PROBE_N` fails.
//   PROBE_N       1-based index of the allocation that fails. 0 or unset skips the test.
//   PROBE_STICKY  1: every allocation from `PROBE_N` on fails.
//   PROBE_SCN     0: first eval of a new VM. 1: second eval of a `persist_main` session.
//   PROBE_WHERE   1: print the stack of the failing allocation.
// The test allocator below the probe reports leaks, so a leak makes the process fail.
const ProbeAlloc = struct {
    child: std.mem.Allocator,
    n: usize = 0,
    fail_at: usize = 0,
    sticky: bool = false,
    armed: bool = false,
    fired: bool = false,

    fn allocator(self: *ProbeAlloc) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }
    fn hit(self: *ProbeAlloc) bool {
        if (!self.armed) return false;
        self.n += 1;
        if (self.n == self.fail_at or (self.sticky and self.n > self.fail_at)) {
            if (!self.fired and probeEnv("PROBE_WHERE", 0) != 0) std.debug.dumpCurrentStackTrace(.{});
            self.fired = true;
            return true;
        }
        return false;
    }
    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *ProbeAlloc = @ptrCast(@alignCast(ctx));
        if (self.hit()) return null;
        return self.child.rawAlloc(len, alignment, ra);
    }
    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *ProbeAlloc = @ptrCast(@alignCast(ctx));
        if (new_len > memory.len and self.hit()) return false;
        return self.child.rawResize(memory, alignment, new_len, ra);
    }
    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *ProbeAlloc = @ptrCast(@alignCast(ctx));
        if (new_len > memory.len and self.hit()) return null;
        return self.child.rawRemap(memory, alignment, new_len, ra);
    }
    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *ProbeAlloc = @ptrCast(@alignCast(ctx));
        self.child.rawFree(memory, alignment, ra);
    }
    const vtable: std.mem.Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };
};

fn probeEnv(name: [*:0]const u8, def: usize) usize {
    const p = std.c.getenv(name) orelse return def;
    return std.fmt.parseInt(usize, std.mem.span(p), 10) catch def;
}

const probe_src =
    \\use test
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
    \\fn fails(i int) -> !int:
    \\  if i > 500: return error.TooBig
    \\  return i
    \\a := Array[int]{}
    \\m := Map[str, int]{}
    \\s := ''
    \\var head ?^Node = none
    \\for 0..600 |i|:
    \\  a << i
    \\  m['k%{i}'] = i
    \\  s += 'x'
    \\  head = ^Node{val=i, next=head}
    \\test.eq(600, a.len())
    \\test.eq(600, m.size())
    \\test.eq(600, s.len())
    \\test.eq(3, sum[int](Pair[int]{a=1, b=2}))
    \\test.eq(12.0, area(Shape.circle(2.0)))
    \\cnt := ^Node{val=600, next=none}
    \\add := fn(x int) -> int:
    \\  return x + cnt.val
    \\test.eq(601, add(1))
    \\total := 0
    \\for gen(10) |v|:
    \\  total += v
    \\test.eq(45, total)
    \\r := fails(1000) !else -1
    \\test.eq(-1, r)
;

const probe_src2 =
    \\type P2:
    \\  x int
    \\fn twice(x int) -> int:
    \\  return x * 2
    \\b := Array[str]{}
    \\for 0..50 |i|:
    \\  b << str(twice(i))
    \\q := P2{x=b.len()}
    \\q.x + a.len()
;

test "PROBE" {
    const n = probeEnv("PROBE_N", 0);
    if (n == 0) return;
    const sticky = probeEnv("PROBE_STICKY", 0) != 0;
    const scn = probeEnv("PROBE_SCN", 0);
    var probe = ProbeAlloc{ .child = zt.alloc, .fail_at = n, .sticky = sticky };
    C.setSilent(true);
    var res: C.EvalResult = undefined;
    var r1: C.ResultCode = 99;
    var r2: C.ResultCode = 99;
    var r3: C.ResultCode = 99;
    {
        const vm = C.vm_initx(probe.allocator());
        defer C.vm_deinit(vm);
        var config = C.defaultEvalConfig();
        if (scn == 1) config.persist_main = true;
        if (scn == 0) {
            probe.armed = true;
            r1 = C.vm_evalx(vm, "main", probe_src, config, &res);
            probe.armed = false;
        } else {
            r1 = C.vm_evalx(vm, "main", probe_src, config, &res);
            probe.armed = true;
            r2 = C.vm_evalx(vm, "main", probe_src2, config, &res);
            probe.armed = false;
        }
        if (probe.fired and (r1 != C.Success or (scn == 1 and r2 != C.Success))) {
            const report = C.vm_error_summary(vm);
            defer C.vm_freeb(vm, report);
            const nl = std.mem.indexOfScalar(u8, report, '\n') orelse report.len;
            std.debug.print("PROBE_MSG {s}\n", .{report[0..nl]});
        }
        std.debug.print("PROBE_R r1={} r2={} n={}\n", .{ r1, r2, probe.n });
        // The VM must stay usable.
        r3 = C.vm_evalx(vm, "main", "x9 := 1 + 2", config, &res);
    }
    std.debug.print("PROBE n={} total={} fired={} r1={} r2={} r3={}\n", .{ n, probe.n, probe.fired, r1, r2, r3 });
}
