const std = @import("std");
const stdx = @import("stdx");
const C = @import("../capi.zig");
const zt = stdx.testing;

test "single_run frees the main block's raw buffers at deinit." {
    const vm = C.vm_init();
    defer C.vm_deinit(vm);

    var config = C.defaultEvalConfig();
    config.single_run = true;
    var res: C.EvalResult = undefined;
    try zt.eq(C.Success, C.vm_evalx(vm, "t",
        \\arr := Array[int]{}
        \\for 0..10 |i|:
        \\  arr.append(i)
    , config, &res));
}

test "single_run frees big heap objects at deinit." {
    // Leak-checking allocator: the main block's big objects (`Generator` is 48 bytes) must not survive deinit.
    const vm = C.vm_initx(zt.alloc);
    defer C.vm_deinit(vm);

    var config = C.defaultEvalConfig();
    config.single_run = true;
    var res: C.EvalResult = undefined;
    try zt.eq(C.Success, C.vm_evalx(vm, "t",
        \\#[generator]
        \\fn inc() -> int:
        \\  yield 0
        \\
        \\type IncFn = fn() -> int
        \\
        \\gens := Array[^Generator[IncFn]]{}
        \\for 0..10:
        \\  g := inc()
        \\  _ = g.next()
        \\  gens.append(g)
    , config, &res));
}

test "Generator frames keep locals across yields and free them." {
    // Leak-checking allocator: managed locals live in the generator's saved frame between resumes,
    // a yielded local is handed out as a copy, and dropping a paused generator destructs its saved locals.
    const vm = C.vm_initx(zt.alloc);
    defer C.vm_deinit(vm);

    var res: C.EvalResult = undefined;
    try zt.eq(C.Success, C.vm_evalx(vm, "t",
        \\use test
        \\
        \\fn deep(n int) -> int:
        \\  if n == 0:
        \\    return 0
        \\  return 1 + deep(n - 1)
        \\
        \\#[generator]
        \\fn words(n int) -> str:
        \\  s := 'w-padding-padding-padding-padding'
        \\  for 0..n |i|:
        \\    s = s + '-%{i}'
        \\    yield s
        \\  return s + '-end'
        \\
        \\g := words(2)
        \\test.eq('w-padding-padding-padding-padding-0', g.next().?)
        \\_ = deep(50)
        \\test.eq('w-padding-padding-padding-padding-0-1', g.next().?)
        \\test.eq('w-padding-padding-padding-padding-0-1-end', g.next().?)
        \\
        \\fn drop_paused():
        \\  d := words(5)
        \\  _ = d.next()
        \\  _ = deep(50)
        \\  _ = d.next()
        \\drop_paused()
        \\
        \\type WordsFn = fn(int) -> str
        \\fn resume_deep(gen ^Generator[WordsFn], n int) -> str:
        \\  if n == 0:
        \\    return gen.next().?
        \\  return resume_deep(gen, n - 1)
        \\r := words(2)
        \\test.eq('w-padding-padding-padding-padding-0', resume_deep(r, 3000))
        \\test.eq('w-padding-padding-padding-padding-0-1', resume_deep(r, 6000))
    , C.defaultEvalConfig(), &res));
}

fn expectInOrder(report: []const u8, parts: []const []const u8) !void {
    var start: usize = 0;
    for (parts) |part| {
        const idx = std.mem.findPos(u8, report, start, part) orelse {
            std.debug.print("missing `{s}` after {} in:\n{s}\n", .{part, start, report});
            return error.TestUnexpectedResult;
        };
        start = idx + part.len;
    }
}

test "Panics inside generators unwind through the generator frame." {
    // A running generator frame keeps the `Generator` where other frames keep the caller's fp, after a
    // ret slot as wide as `?T`. `?int` and `?str` are wider than one register.
    const vm = C.vm_initx(zt.alloc);
    defer C.vm_deinit(vm);
    C.setSilent(true);
    defer C.setSilent(false);

    var res: C.EvalResult = undefined;
    try zt.eq(C.ErrorPanic, C.vm_eval(vm,
        \\#[generator]
        \\fn walker() -> int:
        \\  panic('boom in generator')
        \\  yield 1
        \\
        \\fn drive():
        \\  g := walker()
        \\  print(g.next())
        \\
        \\drive()
    , &res));
    {
        const report = C.vm_error_summary(vm);
        defer C.vm_freeb(vm, report);
        try expectInOrder(report, &.{"panic: boom in generator", " walker:", " Generator.next:", " drive:", " main:"});
    }

    try zt.eq(C.ErrorPanic, C.vm_eval(vm,
        \\fn fail(n int) -> int:
        \\  if n == 3:
        \\    panic('boom at %{n}')
        \\  return n
        \\
        \\#[generator]
        \\fn walker() -> str:
        \\  for 0..5 |i|:
        \\    yield 'v%{fail(i)}'
        \\
        \\fn drive():
        \\  g := walker()
        \\  while g.next() |v|:
        \\    _ = v
        \\
        \\drive()
    , &res));
    {
        const report = C.vm_error_summary(vm);
        defer C.vm_freeb(vm, report);
        try expectInOrder(report, &.{"panic: boom at 3", " fail:", " walker:", " Generator.next:", " drive:", " main:"});
    }

    // Stopping inside a generator body unwinds the same way.
    C.vm_set_fuel(vm, 10000);
    try zt.eq(C.ErrorInterrupt, C.vm_eval(vm,
        \\#[generator]
        \\fn forever() -> int:
        \\  i := 0
        \\  while true:
        \\    i += 1
        \\  yield i
        \\
        \\g := forever()
        \\_ = g.next()
    , &res));
    {
        const report = C.vm_error_summary(vm);
        defer C.vm_freeb(vm, report);
        try expectInOrder(report, &.{"panic: Out of fuel.", " forever:", " Generator.next:", " main:"});
    }
    C.vm_set_fuel(vm, 0);

    // The VM is still usable.
    try zt.eq(C.Success, C.vm_eval(vm, "x := 1", &res));
}

test "stack_trace() lists the frames from the caller to main." {
    const vm = C.vm_initx(zt.alloc);
    defer C.vm_deinit(vm);

    var res: C.EvalResult = undefined;
    try zt.eq(C.Success, C.vm_evalx(vm, "t",
        \\use meta
        \\use test
        \\
        \\fn pos(s str, part str) -> int:
        \\  return s.index(part) ?else -1
        \\
        \\fn expect_in_order(s str, a str, b str, c str):
        \\  test.eq(true, pos(s, a) >= 0)
        \\  test.eq(true, pos(s, a) < pos(s, b))
        \\  test.eq(true, pos(s, b) < pos(s, c))
        \\
        \\fn show() -> str:
        \\  return meta.stack_trace()
        \\
        \\fn mid() -> str:
        \\  return show()
        \\
        \\-- The host frame of `stack_trace` is dropped, and the outer frames stay.
        \\t1 := mid()
        \\test.eq(-1, pos(t1, '<host>'))
        \\expect_in_order(t1, ' show:', ' mid:', ' main:')
        \\
        \\-- Through a running generator frame (`?int` ret slot).
        \\#[generator]
        \\fn walker() -> int:
        \\  t := show()
        \\  expect_in_order(t, ' show:', ' walker:', ' Generator.next:')
        \\  test.eq(true, pos(t, ' Generator.next:') < pos(t, ' main:'))
        \\  yield 1
        \\
        \\g := walker()
        \\test.eq(1, g.next().?)
    , C.defaultEvalConfig(), &res));
}

test "Stack trace unwinding." {
    const vm = C.vm_init();
    defer C.vm_deinit(vm);

    var res: C.EvalResult = undefined;
    var code = C.vm_eval(vm,
        \\use test
        \\a := 123
        \\b := a / 0
    , &res);

    try zt.eq(C.ErrorPanic, code);
    var thread = C.vm_main_thread(vm);
    {
        const report = C.thread_panic_summary(thread);
        defer C.vm_freeb(vm, report);
        try zt.eqStr(
            \\panic: Division by zero.
            \\
            \\eval:3:6 main:
            \\b := a / 0
            \\     ^
            \\
        , report);
    }

    var trace = C.thread_panic_trace(thread);
    try zt.eq(trace.frames_len, 1);
    try eqStackFrame(trace.frames[0], .{
        .name = C.to_bytes("main"),
        .chunk = 0,
        .line = 2,
        .col = 5,
        .line_pos = 18,
    });

    C.vm_reset(vm);

    // Function stack trace.
    code = C.vm_eval(vm, 
        \\use test
        \\fn foo() -> int:
        \\  a := 123
        \\  return a / 0
        \\b := foo()
    , &res);

    try zt.eq(C.ErrorPanic, code);
    thread = C.vm_main_thread(vm);
    {
        const report = C.thread_panic_summary(thread);
        defer C.vm_freeb(vm, report);
        try zt.eqStr(
            \\panic: Division by zero.
            \\
            \\eval:4:10 foo:
            \\  return a / 0
            \\         ^
            \\eval:5:6 main:
            \\b := foo()
            \\     ^
            \\
        , report);
    }
    trace = C.thread_panic_trace(thread);
    try zt.eq(trace.frames_len, 2);
    try eqStackFrame(trace.frames[0], .{
        .name = C.to_bytes("foo"),
        .chunk = 0,
        .line = 3,
        .col = 9,
        .line_pos = 37,
    });
    try eqStackFrame(trace.frames[1], .{
        .name = C.to_bytes("main"),
        .chunk = 0,
        .line = 4,
        .col = 5,
        .line_pos = 52,
    });
}

fn eqStackFrame(act: C.StackFrame, exp: C.StackFrame) !void {
    try zt.eqStr(C.from_bytes(act.name), C.from_bytes(exp.name));
    try zt.eq(exp.chunk, act.chunk);
    try zt.eq(exp.line, act.line);
    try zt.eq(exp.col, act.col);
    try zt.eq(exp.line_pos, act.line_pos);
}
