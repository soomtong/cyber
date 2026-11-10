const std = @import("std");
const stdx = @import("stdx");
const cy = @import("../cyber.zig");
const C = @import("../capi.zig");
const zt = stdx.testing;
const is_wasm = @import("util.zig").is_wasm;

test "JIT backend is rejected with a clear compile error." {
    const vm = C.vm_init();
    defer C.vm_deinit(vm);

    C.setSilent(true);
    defer C.setSilent(false);

    var config = C.defaultEvalConfig();
    config.backend = C.BackendJIT;
    var res: C.EvalResult = undefined;
    try zt.eq(C.ErrorCompile, C.vm_evalx(vm, "t", "_ = 1 + 2", config, &res));
    const summary = C.vm_compile_error_summary(vm);
    defer C.vm_freeb(vm, summary);
    try zt.expect(std.mem.indexOf(u8, summary, "The JIT backend is not supported.") != null);
}

/// Builds a source with `n` repetitions of `item` (`{}` is the index) between `head` and `tail`, joined by `sep`.
fn repeat_src(w: *std.Io.Writer, head: []const u8, item: []const u8, sep: []const u8, n: usize, tail: []const u8) !void {
    try w.writeAll(head);
    for (0..n) |i| {
        if (i > 0) try w.writeAll(sep);
        var rest = item;
        while (std.mem.indexOf(u8, rest, "{}")) |idx| {
            try w.writeAll(rest[0..idx]);
            try w.print("{}", .{i});
            rest = rest[idx + 2 ..];
        }
        try w.writeAll(rest);
    }
    try w.writeAll(tail);
}

fn expect_limit_error(vm: *C.VM, src: []const u8, msg: []const u8) !void {
    var res: C.EvalResult = undefined;
    try zt.eq(C.ErrorCompile, C.vm_eval(vm, src, &res));
    const summary = C.vm_compile_error_summary(vm);
    defer C.vm_freeb(vm, summary);
    if (std.mem.indexOf(u8, summary, msg) == null) {
        std.debug.print("expected `{s}`, got:\n{s}\n", .{ msg, summary });
        return error.TestUnexpectedResult;
    }
}

test "Compiler limits are compile errors, not panics." {
    // F-08. IR local ids, `FuncSig.numParams`, call `nargs` and field `idx` are `u8`. Exceeding them used to
    // trip an `@intCast` or `+=` panic in sema and abort the host.
    if (is_wasm) return;
    C.setSilent(true);
    defer C.setSilent(false);

    var lw = std.Io.Writer.Allocating.init(zt.alloc);
    defer lw.deinit();
    const w = &lw.writer;

    const locals_msg = "Too many local variables. A function can have at most 256 locals, including hidden temporaries.";
    const params_msg = "Too many parameters. A function can have at most 255 parameters.";
    const fields_msg = "Too many fields. A struct can have at most 255 fields.";

    // 257 locals in a function, 300 in main.
    {
        const vm = C.vm_init();
        defer C.vm_deinit(vm);
        lw.clearRetainingCapacity();
        try repeat_src(w, "fn f() -> int:\n", "    v{} := {}\n", "", 257, "    return v256\nprint(f())\n");
        try expect_limit_error(vm, lw.written(), locals_msg);
    }
    {
        const vm = C.vm_init();
        defer C.vm_deinit(vm);
        lw.clearRetainingCapacity();
        try repeat_src(w, "", "v{} := {}\n", "", 300, "print(v299)\n");
        try expect_limit_error(vm, lw.written(), locals_msg);
    }
    // 256 params of a function, a lambda and a function type.
    {
        const vm = C.vm_init();
        defer C.vm_deinit(vm);
        lw.clearRetainingCapacity();
        try repeat_src(w, "fn f(", "a{} int", ", ", 256, ") -> int:\n    return a0\nprint(1)\n");
        try expect_limit_error(vm, lw.written(), params_msg);
    }
    {
        const vm = C.vm_init();
        defer C.vm_deinit(vm);
        lw.clearRetainingCapacity();
        try repeat_src(w, "f := fn(", "a{} int", ", ", 256, ") -> int:\n    return a0\nprint(1)\n");
        try expect_limit_error(vm, lw.written(), params_msg);
    }
    {
        const vm = C.vm_init();
        defer C.vm_deinit(vm);
        lw.clearRetainingCapacity();
        try repeat_src(w, "type F = fn(", "int", ", ", 256, ") -> int\nprint(1)\n");
        try expect_limit_error(vm, lw.written(), params_msg);
    }
    // 256 fields of a struct.
    {
        const vm = C.vm_init();
        defer C.vm_deinit(vm);
        lw.clearRetainingCapacity();
        try repeat_src(w, "type S:\n", "    f{} int\n", "", 256, "s := S{}\nprint(1)\n");
        try expect_limit_error(vm, lw.written(), fields_msg);
    }
    // The limits themselves compile and run: 255 params + 1 local = 256 IR locals, 255 fields.
    {
        const vm = C.vm_init();
        defer C.vm_deinit(vm);
        lw.clearRetainingCapacity();
        try repeat_src(w, "fn f(", "a{} int", ", ", 255, ") -> int:\n    x := a254\n    return x\n");
        try repeat_src(w, "use test\ntest.eq(254, f(", "{}", ", ", 255, "))\n");
        var res: C.EvalResult = undefined;
        try zt.eq(C.Success, C.vm_eval(vm, lw.written(), &res));
    }
    {
        const vm = C.vm_init();
        defer C.vm_deinit(vm);
        lw.clearRetainingCapacity();
        try repeat_src(w, "type S:\n", "    f{} int\n", "", 255, "");
        try repeat_src(w, "s := S{", "f{}={}", ", ", 255, "}\nuse test\ntest.eq(254, s.f254)\n");
        var res: C.EvalResult = undefined;
        try zt.eq(C.Success, C.vm_eval(vm, lw.written(), &res));
    }
}

test "Jumps past the one-slot offset are compile errors, not panics or runtime crashes." {
    // F-09. `jump` · `release` offsets are i16, `jump_f` · `jump_t` offsets u16. A long body used to trip `@intCast` in
    // bc_gen (host abort), and a forward `jump` of 32768..65535 slots was read back as negative by the VM (SIGSEGV).
    if (is_wasm) return;
    C.setSilent(true);
    defer C.setSilent(false);

    var lw = std.Io.Writer.Allocating.init(zt.alloc);
    defer lw.deinit();
    const w = &lw.writer;

    const jump_msg = "Function body too large. A jump can span at most 32767 bytecode slots.";
    const cond_jump_msg = "Function body too large. A jump can span at most 65535 bytecode slots.";

    // Loop body: the backward `jump` of `continue` at the end of the body.
    {
        const vm = C.vm_init();
        defer C.vm_deinit(vm);
        lw.clearRetainingCapacity();
        try repeat_src(w, "s := 0\ni := 0\nwhile i < 2:\n    i += 1\n", "    s += 1\n", "", 9000, "print(s)\n");
        try expect_limit_error(vm, lw.written(), jump_msg);
    }
    // `if` without `else`: the forward `jump_f` over the body (u16).
    {
        const vm = C.vm_init();
        defer C.vm_deinit(vm);
        lw.clearRetainingCapacity();
        try repeat_src(w, "s := 0\nif s == 0:\n", "    s += 1\n", "", 17000, "print(s)\n");
        try expect_limit_error(vm, lw.written(), cond_jump_msg);
    }
    // Long `else` body: the forward `jump` at the end of the `if` body (i16). This one used to compile and crash at runtime.
    {
        const vm = C.vm_init();
        defer C.vm_deinit(vm);
        lw.clearRetainingCapacity();
        try repeat_src(w, "s := 1\nif s == 1:\n    s = -1\nelse:\n", "    s += 1\n", "", 9000, "print(s)\n");
        try expect_limit_error(vm, lw.written(), jump_msg);
    }
    // Inside the limits the bodies compile and run: a loop body of 7000 `add_i16` (4 slots each) and an `if` body of
    // 15000 (60000 slots fit the u16 conditional jump).
    {
        const vm = C.vm_init();
        defer C.vm_deinit(vm);
        lw.clearRetainingCapacity();
        try repeat_src(w, "use test\ns := 0\ni := 0\nwhile i < 2:\n    i += 1\n", "    s += 1\n", "", 7000, "test.eq(s, 14000)\n");
        var res: C.EvalResult = undefined;
        try zt.eq(C.Success, C.vm_eval(vm, lw.written(), &res));
    }
    {
        const vm = C.vm_init();
        defer C.vm_deinit(vm);
        lw.clearRetainingCapacity();
        try repeat_src(w, "use test\ns := 0\nif s == 0:\n", "    s += 1\n", "", 15000, "test.eq(s, 15000)\n");
        var res: C.EvalResult = undefined;
        try zt.eq(C.Success, C.vm_eval(vm, lw.written(), &res));
    }
}

test "String literals past 65535 bytes are compile errors, not truncated." {
    // F-24. `const_str` keeps the length in the upper 16 bits of its u64 operand, so a 70000-byte literal used to run
    // with `len()` 4464 and a 65536-byte one with `len()` 0.
    if (is_wasm) return;
    C.setSilent(true);
    defer C.setSilent(false);

    var lw = std.Io.Writer.Allocating.init(zt.alloc);
    defer lw.deinit();
    const w = &lw.writer;
    const msg = "String literal too long. A string literal can have at most 65535 bytes.";

    {
        const vm = C.vm_init();
        defer C.vm_deinit(vm);
        lw.clearRetainingCapacity();
        try repeat_src(w, "s := '", "a", "", 65536, "'\nprint(s.len())\n");
        try expect_limit_error(vm, lw.written(), msg);
    }
    // The pieces of an interpolated string are literals too.
    {
        const vm = C.vm_init();
        defer C.vm_deinit(vm);
        lw.clearRetainingCapacity();
        try repeat_src(w, "x := 1\ns := '", "a", "", 70000, "%{x}'\nprint(s.len())\n");
        try expect_limit_error(vm, lw.written(), msg);
    }
    // 65535 bytes is the limit and runs.
    {
        const vm = C.vm_init();
        defer C.vm_deinit(vm);
        lw.clearRetainingCapacity();
        try repeat_src(w, "use test\ns := '", "a", "", 65535, "'\ntest.eq(s.len(), 65535)\n");
        var res: C.EvalResult = undefined;
        try zt.eq(C.Success, C.vm_eval(vm, lw.written(), &res));
    }
}

fn expect_deny_raw_ptr_error(vm: *C.VM, src: []const u8, type_name: []const u8) !void {
    var config = C.defaultEvalConfig();
    config.deny_raw_ptrs = true;
    var res: C.EvalResult = undefined;
    try zt.eq(C.ErrorCompile, C.vm_evalx(vm, "t", src, config, &res));
    const summary = C.vm_compile_error_summary(vm);
    defer C.vm_freeb(vm, summary);
    var buf: [128]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, "Raw pointer type `{s}` is not allowed.", .{type_name});
    if (std.mem.indexOf(u8, summary, msg) == null) {
        std.debug.print("expected `{s}`, got:\n{s}\n", .{ msg, summary });
        return error.TestUnexpectedResult;
    }
}

test "deny_raw_ptrs rejects raw pointers in script chunks." {
    // F-06. Without the option a script dereferences any address (`as[Ptr[int]] 8` → SIGSEGV in the host).
    if (is_wasm) return;
    C.setSilent(true);
    defer C.setSilent(false);

    const cast_src = "p := as[Ptr[int]] 8\nprint(p.*)\n";
    {
        const vm = C.vm_init();
        defer C.vm_deinit(vm);
        try expect_deny_raw_ptr_error(vm, cast_src, "Ptr[int]");
        try expect_deny_raw_ptr_error(vm, "p := Ptr[int](8)\nprint(p.*)\n", "Ptr[int]");
        try expect_deny_raw_ptr_error(vm, "x := 1\nr := &x\np := as[Ptr[int]] r\nprint(p[100000000])\n", "Ptr[int]");
        try expect_deny_raw_ptr_error(vm, "p := alloc(int)\np.* = 1\n", "Ptr[int]");
        try expect_deny_raw_ptr_error(vm, "ps := PtrSpan[int]{length=4}\nprint(ps[1])\n", "PtrSpan[int]");
        try expect_deny_raw_ptr_error(vm, "fn f(p Ptr[int]) -> int:\n    return p.*\nprint(f(as[Ptr[int]] 8))\n", "Ptr[int]");
        // `?Ptr[T]` (what `StaticMap.get` returns) is checked through the option.
        try expect_deny_raw_ptr_error(vm, "fn g() -> ?Ptr[int]:\n    return none\nprint(g())\n", "Ptr[int]");
    }
    // Safe code still runs: spans, slices, maps, strings and borrows are implemented with raw pointers inside core.
    {
        const vm = C.vm_init();
        defer C.vm_deinit(vm);
        var config = C.defaultEvalConfig();
        config.deny_raw_ptrs = true;
        var res: C.EvalResult = undefined;
        const src =
            \\use test
            \\xs := []int{1, 2, 3}
            \\xs += 4
            \\sp := [&]int{4, 5, 6}
            \\m := Map[str, int]{}
            \\m['a'] = 1
            \\x := 42
            \\r := &x
            \\test.eq(xs[3] + sp[2] + m['a'] + r.*, 4 + 6 + 1 + 42)
            \\s := 'ab%{x}'
            \\test.eq(s.len(), 4)
            \\
        ;
        try zt.eq(C.Success, C.vm_evalx(vm, "t", src, config, &res));
    }
    // REPL: a rejected eval does not break the next one.
    {
        const vm = C.vm_init();
        defer C.vm_deinit(vm);
        var config = C.defaultEvalConfig();
        config.deny_raw_ptrs = true;
        config.persist_main = true;
        var res: C.EvalResult = undefined;
        try zt.eq(C.Success, C.vm_evalx(vm, "t", "a := 1\n", config, &res));
        try zt.eq(C.ErrorCompile, C.vm_evalx(vm, "t", cast_src, config, &res));
        try zt.eq(C.Success, C.vm_evalx(vm, "t", "use test\ntest.eq(a, 1)\n", config, &res));
    }
    // The default keeps raw pointers (the CLI and existing hosts). Compile only: running it would crash.
    {
        const vm = C.vm_init();
        defer C.vm_deinit(vm);
        try zt.eq(C.Success, C.vm_compile(vm, "t", cast_src, C.defaultCompileConfig()));
    }
}

/// Counts `funcs_debug` entries named `name` in the main chunk. A function body has one entry and each inline site of it
/// adds one, so the result minus one is the number of inline sites.
fn count_debug_frames(vm: ?*C.VM, name: []const u8) u32 {
    const zvm: *cy.VM = @ptrCast(@alignCast(vm.?));
    var n: u32 = 0;
    for (zvm.compiler.main_chunk.funcs_debug.items) |f| {
        if (std.mem.eql(u8, f.name, name)) n += 1;
    }
    return n;
}

test "Bytecode inlining of functions with loops." {
    const vm = C.vm_init();
    defer C.vm_deinit(vm);

    try zt.eq(C.Success, C.vm_compile(vm, "main",
        \\fn find_first(xs []int, target int) -> int:
        \\  for 0..xs.len() |i|:
        \\    if xs[i] == target:
        \\      return i
        \\  return -1
        \\
        \\fn unwrap_sum(o ?int) -> int:
        \\  cur := o
        \\  total := 0
        \\  while cur |v|:
        \\    total += v
        \\    cur = none
        \\  return total
        \\
        \\fn rec(n int) -> int:
        \\  if n <= 0:
        \\    return 0
        \\  t := 0
        \\  for 0..n |i|:
        \\    t += i
        \\  return t + rec(n - 1)
        \\
        \\xs := []int{4, 8, 15}
        \\for 0..2 |i|:
        \\  _ = find_first(xs, 15)
        \\  _ = find_first(xs, i)
        \\  _ = unwrap_sum(i)
        \\  _ = rec(i)
    , C.defaultCompileConfig()));

    // `for` and `while` bodies are inlined at each call. The bodies are bigger than `inline_small_nodes`,
    // so the sites are in a loop (hot). See "Inline site rules." for sites outside a loop.
    try zt.eq(3, count_debug_frames(vm, "find_first"));
    try zt.eq(2, count_debug_frames(vm, "unwrap_sum"));
    // A recursive function is inlined once into `main` and unrolled one level into its own body
    // (the self call site counts as hot). The unrolled copy's self call stays a call.
    try zt.eq(3, count_debug_frames(vm, "rec"));
}

test "Inline site rules." {
    const vm = C.vm_init();
    defer C.vm_deinit(vm);

    try zt.eq(C.Success, C.vm_compile(vm, "main",
        \\fn small(a int, b int) -> int:
        \\  return a * b + 1
        \\
        \\fn big(xs []int, target int) -> int:
        \\  for 0..xs.len() |i|:
        \\    if xs[i] == target:
        \\      return i
        \\  return -1
        \\
        \\fn die(code int) -> never:
        \\  _ = code
        \\  panic('dead')
        \\
        \\xs := []int{4, 8, 15}
        \\a := small(2, 3)
        \\b := big(xs, 8)
        \\if a == 0:
        \\  c := small(a, b)
        \\  die(c)
        \\if b == 99:
        \\  die(b)
        \\  b = 1
        \\for 0..2 |i|:
        \\  b += big(xs, i)
    , C.defaultCompileConfig()));

    // A small body is inlined at any site, but not in a block that ends with a `never` call (an error path).
    try zt.eq(2, count_debug_frames(vm, "small"));
    // A body over `inline_small_nodes` is inlined only at a site inside a loop.
    try zt.eq(2, count_debug_frames(vm, "big"));
    // A function that does not return is never inlined. Its body is small and the second `die` site is followed
    // by a statement, so neither the size nor the error path rule applies there and only the `never` rule keeps it a call.
    try zt.eq(1, count_debug_frames(vm, "die"));
}

test "Hot callee sites." {
    const vm = C.vm_init();
    defer C.vm_deinit(vm);

    try zt.eq(C.Success, C.vm_compile(vm, "main",
        \\fn big(xs []int, target int) -> int:
        \\  for 0..xs.len() |i|:
        \\    if xs[i] == target:
        \\      return i
        \\  return -1
        \\
        \\fn wrap_hot(xs []int, t int) -> int:
        \\  return big(xs, t) + 1
        \\
        \\fn wrap_cold(xs []int, t int) -> int:
        \\  return big(xs, t) + 2
        \\
        \\xs := []int{4, 8, 15}
        \\a := wrap_cold(xs, 8)
        \\for 0..2 |i|:
        \\  a += wrap_hot(xs, i)
    , C.defaultCompileConfig()));

    // `wrap_hot` is called from a loop, so the `big` site in its body is hot: body + site in `wrap_hot` + site in
    // the copy of `wrap_hot` inside the main loop. `wrap_cold` is called once outside loops, so `big` stays a call
    // there in both its body and its copy in main.
    try zt.eq(3, count_debug_frames(vm, "big"));
    try zt.eq(2, count_debug_frames(vm, "wrap_hot"));
    try zt.eq(2, count_debug_frames(vm, "wrap_cold"));
}

/// Counts the instructions after the last `ret` of `name`'s body in the main chunk (from its `markers` entry to the
/// next function header). Only the Trace build's `trap` end marker may follow a body's last return.
fn count_insts_after_last_ret(vm: ?*C.VM, name: []const u8) !u32 {
    const zvm: *cy.VM = @ptrCast(@alignCast(vm.?));
    const chunk = zvm.compiler.main_chunk;
    var start: ?u32 = null;
    var iter = chunk.buf.markers.iterator();
    while (iter.next()) |e| {
        if (std.mem.eql(u8, e.value_ptr.*.name(), name)) start = e.key_ptr.*;
    }
    const ops = chunk.buf.ops.items;
    var pc: usize = start orelse return error.FuncNotFound;
    var after: u32 = 0;
    while (pc < ops.len) {
        const code = ops[pc].opcode();
        // The next function starts with a `nop32` header.
        if (code == .nop32) break;
        switch (code) {
            .ret, .ret_0, .ret_n => after = 0,
            .trap => {},
            else => after += 1,
        }
        pc += cy.bytecode.getInstLenAt(ops.ptr + pc);
    }
    return after;
}

test "A function body ends at its last return." {
    const vm = C.vm_init();
    defer C.vm_deinit(vm);

    // Both params are managed values that a block end would destruct. `return` destructs them itself,
    // so sema must not emit the block end destructors after it.
    try zt.eq(C.Success, C.vm_compile(vm, "main",
        \\fn find_first(xs []int, target int) -> int:
        \\  for 0..xs.len() |i|:
        \\    if xs[i] == target:
        \\      return i
        \\  return -1
        \\
        \\fn pick(s str, n int) -> int:
        \\  if n > 0:
        \\    return s.len()
        \\  else:
        \\    return -1
        \\
        \\xs := []int{4, 8, 15}
        \\_ = find_first(xs, 15)
        \\_ = pick('abc', 1)
    , C.defaultCompileConfig()));

    try zt.eq(0, count_insts_after_last_ret(vm, "find_first"));
    try zt.eq(0, count_insts_after_last_ret(vm, "pick"));
}

test "setOpArgU48 writes only its 6-byte operand." {
    // A `*u48` store is 8 bytes. At the end of the ops buffer it overwrote the allocator's metadata.
    var buf: cy.ByteCodeBuffer = undefined;
    buf.ops = .empty;
    defer buf.ops.deinit(zt.alloc);
    try buf.ops.ensureTotalCapacityPrecise(zt.alloc, 8);
    buf.ops.items.len = 8;
    @memset(buf.ops.items, .{ .val = 0xabcd });
    buf.ops.items.len = 4;

    buf.setOpArgU48(1, 0x112233445566);
    try zt.eq(0xabcd, buf.ops.items[0].val);
    try zt.eq(0x5566, buf.ops.items[1].val);
    try zt.eq(0x3344, buf.ops.items[2].val);
    try zt.eq(0x1122, buf.ops.items[3].val);
    try zt.eq(0xabcd, buf.ops.items.ptr[4].val);
}

test "Compile error summaries have no escape codes unless the host asks." {
    // The marker line used to be wrapped in `\x1b[31m` .. `\x1b[0m` for every host (F-52).
    const vm = C.vm_init();
    defer C.vm_deinit(vm);

    const src = "a := 1\nprint(nope)";
    var res: C.EvalResult = undefined;
    try zt.eq(C.ErrorCompile, C.vm_eval(vm, src, &res));
    {
        const summary = C.vm_compile_error_summary(vm);
        defer C.vm_freeb(vm, summary);
        try zt.eqStr(
            \\CompileError: Undeclared variable `nope`.
            \\
            \\eval:2:7:
            \\print(nope)
            \\      ^~~~
            \\
        , summary);
    }

    C.vm_set_error_color(vm, true);
    {
        const summary = C.vm_compile_error_summary(vm);
        defer C.vm_freeb(vm, summary);
        try zt.expect(std.mem.endsWith(u8, summary, "print(nope)\n      \x1b[31m^~~~\x1b[0m\n"));
    }

    // The setting is the host's, like the printer: a reset keeps it.
    C.vm_reset(vm);
    try zt.eq(C.ErrorCompile, C.vm_eval(vm, src, &res));
    {
        const summary = C.vm_error_summary(vm);
        defer C.vm_freeb(vm, summary);
        try zt.expect(std.mem.endsWith(u8, summary, "print(nope)\n      \x1b[31m^~~~\x1b[0m\n"));
    }

    // A VM that a script creates reports to the same place, so it takes the setting of its parent.
    const S = struct {
        var escapes: usize = 0;
        var markers: usize = 0;
        fn printer(_: ?*C.Thread, str: C.Bytes) callconv(.c) void {
            const bytes = C.from_bytes(str);
            escapes += std.mem.count(u8, bytes, "\x1b[31m");
            markers += std.mem.count(u8, bytes, "^~~~");
        }
    };
    C.vm_set_printer(vm, &S.printer);
    const child_src =
        \\use cy
        \\vm := cy.VM()
        \\_ = vm.eval('print(nope)')
        \\print(vm.compile_error_summary())
    ;
    C.vm_reset(vm);
    try zt.eq(C.Success, C.vm_eval(vm, child_src, &res));
    try zt.eq(@as(usize, 1), S.markers);
    try zt.eq(@as(usize, 1), S.escapes);

    C.vm_set_error_color(vm, false);
    C.vm_reset(vm);
    try zt.eq(C.Success, C.vm_eval(vm, child_src, &res));
    try zt.eq(@as(usize, 2), S.markers);
    try zt.eq(@as(usize, 1), S.escapes);
}

test "cl_vm_compile_error returns the location of a compile error." {
    // A host had to parse `uri:line:col` out of the summary text (F-52).
    const vm = C.vm_init();
    defer C.vm_deinit(vm);

    var res: C.EvalResult = undefined;
    var err: C.CompileError = undefined;

    // Nothing was compiled yet.
    try zt.expect(!C.vm_compile_error(vm, &err));
    try zt.eq(@as(usize, 0), err.msg.len);

    // A compile error reports the range of a node. `line` and `col` start at 0.
    try zt.eq(C.ErrorCompile, C.vm_eval(vm, "a := 1\nprint(nope)", &res));
    try zt.expect(C.vm_compile_error(vm, &err));
    try zt.eq(C.ReportCompileError, err.kind);
    try zt.eqStr("Undeclared variable `nope`.", C.from_bytes(err.msg));
    try zt.eqStr("eval", C.from_bytes(err.uri));
    try zt.expect(err.has_loc);
    try zt.eq(@as(u32, 1), err.line);
    try zt.eq(@as(u32, 6), err.col);
    try zt.eq(@as(u32, 4), err.len);

    // `col` counts bytes: the summary prints column 17 here, and `한글` is 6 bytes.
    C.vm_reset(vm);
    try zt.eq(C.ErrorCompile, C.vm_eval(vm, "x := '한글' + nope", &res));
    try zt.expect(C.vm_compile_error(vm, &err));
    try zt.eq(@as(u32, 0), err.line);
    try zt.eq(@as(u32, 16), err.col);
    try zt.eq(@as(u32, 4), err.len);

    // A node that continues on later lines is cut at the end of its first line, like the marker in the summary.
    C.vm_reset(vm);
    try zt.eq(C.ErrorCompile, C.vm_eval(vm, "fn a():\n  pass\nfn a():\n  pass", &res));
    try zt.expect(C.vm_compile_error(vm, &err));
    try zt.eq(@as(u32, 2), err.line);
    try zt.eq(@as(u32, 0), err.col);
    try zt.eq(@as(u32, 7), err.len);

    // A parse error and a token error report a position.
    C.vm_reset(vm);
    try zt.eq(C.ErrorCompile, C.vm_eval(vm, "a := 1\nb := a +\n", &res));
    try zt.expect(C.vm_compile_error(vm, &err));
    try zt.eq(C.ReportParseError, err.kind);
    try zt.eqStr("Expected right operand.", C.from_bytes(err.msg));
    try zt.expect(err.has_loc);
    try zt.eq(@as(u32, 2), err.line);
    try zt.eq(@as(u32, 0), err.col);
    try zt.eq(@as(u32, 1), err.len);

    C.vm_reset(vm);
    try zt.eq(C.ErrorCompile, C.vm_eval(vm, "a := 'abc", &res));
    try zt.expect(C.vm_compile_error(vm, &err));
    try zt.eq(C.ReportTokenError, err.kind);
    try zt.expect(err.has_loc);
    try zt.eq(@as(u32, 0), err.line);
    try zt.eq(@as(u32, 6), err.col);
    try zt.eq(@as(u32, 1), err.len);

    // `cl_vm_validate` records its error the same way.
    C.vm_reset(vm);
    try zt.eq(C.ErrorCompile, C.vm_validate(vm, "print(nope)"));
    try zt.expect(C.vm_compile_error(vm, &err));
    try zt.eq(C.ReportCompileError, err.kind);
    try zt.eq(@as(u32, 6), err.col);

    // An error that does not belong to a source has no location.
    C.vm_reset(vm);
    var config = C.defaultEvalConfig();
    config.backend = C.BackendJIT;
    try zt.eq(C.ErrorCompile, C.vm_evalx(vm, "main", "a := 1", config, &res));
    try zt.expect(C.vm_compile_error(vm, &err));
    try zt.eq(C.ReportCompileError, err.kind);
    try zt.expect(std.mem.startsWith(u8, C.from_bytes(err.msg), "The JIT backend is not supported."));
    try zt.eq(@as(usize, 0), err.uri.len);
    try zt.expect(!err.has_loc);
    {
        const summary = C.vm_compile_error_summary(vm);
        defer C.vm_freeb(vm, summary);
        try zt.expect(std.mem.startsWith(u8, summary, "CompileError: The JIT backend is not supported."));
    }

    // The error is that of the last compile: a panic or a success does not leave the earlier one behind.
    C.vm_reset(vm);
    try zt.eq(C.ErrorCompile, C.vm_eval(vm, "print(nope)", &res));
    try zt.eq(C.ErrorPanic, C.vm_eval(vm, "panic('boom')", &res));
    try zt.expect(!C.vm_compile_error(vm, &err));
    try zt.eq(@as(usize, 0), err.msg.len);
    try zt.expect(!err.has_loc);
    try zt.eq(C.Success, C.vm_eval(vm, "a := 1", &res));
    try zt.expect(!C.vm_compile_error(vm, &err));
}

test "Error summaries are empty when there is no error." {
    // `cl_vm_compile_error_summary` and `cl_thread_panic_summary` used to end the host process when asked
    // without an error, and a script could ask through `cy.VM` (F-52).
    const vm = C.vm_init();
    defer C.vm_deinit(vm);

    const S = struct {
        fn expectEmpty(vm_: *C.VM) !void {
            // The null string can be passed to `cl_vm_freeb` like any other result.
            const compile_summary = C.vm_compile_error_summary(vm_);
            defer C.vm_freeb(vm_, compile_summary);
            try zt.eq(@as(usize, 0), compile_summary.len);

            const panic_summary = C.thread_panic_summary(C.vm_main_thread(vm_));
            defer C.vm_freeb(vm_, panic_summary);
            try zt.eq(@as(usize, 0), panic_summary.len);

            const summary = C.vm_error_summary(vm_);
            defer C.vm_freeb(vm_, summary);
            try zt.eq(@as(usize, 0), summary.len);
        }
    };

    // Before the first eval.
    try S.expectEmpty(vm);

    // After a success.
    var res: C.EvalResult = undefined;
    try zt.eq(C.Success, C.vm_eval(vm, "a := 1", &res));
    try S.expectEmpty(vm);

    // A success after a compile error and after a panic.
    try zt.eq(C.ErrorCompile, C.vm_eval(vm, "print(nope)", &res));
    try zt.eq(C.Success, C.vm_eval(vm, "b := 1", &res));
    try S.expectEmpty(vm);
    try zt.eq(C.ErrorPanic, C.vm_eval(vm, "panic('boom')", &res));
    try zt.eq(C.Success, C.vm_eval(vm, "c := 1", &res));
    try S.expectEmpty(vm);

    // From a script, on a VM that has not failed.
    try zt.eq(C.Success, C.vm_eval(vm,
        \\use cy
        \\vm := cy.VM()
        \\if vm.compile_error_summary().len() != 0: panic('compile summary')
        \\if vm.panic_summary().len() != 0: panic('panic summary')
        \\_ = vm.eval('a := 1')
        \\if vm.compile_error_summary().len() != 0: panic('compile summary after eval')
        \\if vm.panic_summary().len() != 0: panic('panic summary after eval')
    , &res));
}
