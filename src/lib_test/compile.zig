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
            \\test.eq('xay'.trim({'x', 'y'}), 'a')
            \\test.eq(' a\n'.trim(), 'a')
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

test "Compile reports give the range and the notes of a compile error." {
    // `cl_vm_compile_error` gives the start, the length on the first line and the head of the chain only.
    // A language server needs the whole range and the related places (docs/specs/2026-11-12-lsp-design.md, P0).
    const vm = C.vm_init();
    defer C.vm_deinit(vm);

    var res: C.EvalResult = undefined;
    var rep: C.Report = undefined;

    // Nothing was compiled yet.
    try zt.eq(@as(usize, 0), C.vm_compile_report_count(vm));
    try zt.expect(!C.vm_compile_report(vm, 0, &rep));
    try zt.expect(!C.vm_compile_report_note(vm, 0, 0, &rep));
    try zt.eq(@as(usize, 0), rep.msg.len);

    // The range of a node, as lines and columns and as byte offsets. The end is exclusive.
    try zt.eq(C.ErrorCompile, C.vm_eval(vm, "a := 1\nprint(nope)", &res));
    try zt.eq(@as(usize, 1), C.vm_compile_report_count(vm));
    try zt.expect(C.vm_compile_report(vm, 0, &rep));
    try zt.eq(C.ReportCompileError, rep.kind);
    try zt.eqStr("Undeclared variable `nope`.", C.from_bytes(rep.msg));
    try zt.eqStr("eval", C.from_bytes(rep.uri));
    try zt.expect(rep.has_loc);
    try zt.eq(@as(u32, 1), rep.line);
    try zt.eq(@as(u32, 6), rep.col);
    try zt.eq(@as(u32, 1), rep.end_line);
    try zt.eq(@as(u32, 10), rep.end_col);
    try zt.eq(@as(u32, 13), rep.pos);
    try zt.eq(@as(u32, 17), rep.end_pos);
    // There is no other report and this one has no notes.
    try zt.expect(!C.vm_compile_report(vm, 1, &rep));
    try zt.expect(!rep.has_loc);
    try zt.expect(!C.vm_compile_report_note(vm, 0, 0, &rep));
    try zt.expect(!C.vm_compile_report_note(vm, 1, 0, &rep));

    // Columns count bytes: `한글` is 6 bytes.
    C.vm_reset(vm);
    try zt.eq(C.ErrorCompile, C.vm_eval(vm, "x := '한글' + nope", &res));
    try zt.expect(C.vm_compile_report(vm, 0, &rep));
    try zt.eq(@as(u32, 16), rep.col);
    try zt.eq(@as(u32, 20), rep.end_col);
    try zt.eq(@as(u32, 16), rep.pos);
    try zt.eq(@as(u32, 20), rep.end_pos);

    // A node that continues on later lines ends on its last line. `CLCompileError.len` stops at the first.
    // A context note carries its message and the place it points to.
    C.vm_reset(vm);
    const dup_src = "type A:\n  a int\n\ntype A:\n  b int\n";
    try zt.eq(C.ErrorCompile, C.vm_eval(vm, dup_src, &res));
    try zt.expect(C.vm_compile_report(vm, 0, &rep));
    try zt.eqStr("`A` has already been declared as a `type`", C.from_bytes(rep.msg));
    try zt.eq(@as(u32, 3), rep.line);
    try zt.eq(@as(u32, 0), rep.col);
    try zt.eq(@as(u32, 4), rep.end_line);
    try zt.eq(@as(u32, 7), rep.end_col);
    try zt.eqStr("type A:\n  b int", dup_src[rep.pos..rep.end_pos]);
    try zt.expect(C.vm_compile_report_note(vm, 0, 0, &rep));
    try zt.eq(C.ReportNote, rep.kind);
    try zt.eqStr("First declared at:", C.from_bytes(rep.msg));
    try zt.eqStr("eval", C.from_bytes(rep.uri));
    try zt.expect(rep.has_loc);
    try zt.eq(@as(u32, 0), rep.line);
    try zt.eq(@as(u32, 0), rep.col);
    try zt.eq(@as(u32, 1), rep.end_line);
    try zt.eqStr("type A:\n  a int", dup_src[rep.pos..rep.end_pos]);
    try zt.expect(!C.vm_compile_report_note(vm, 0, 1, &rep));
    try zt.eq(@as(usize, 0), rep.msg.len);

    // An error inside a template has the call that expanded it as a note without a message.
    C.vm_reset(vm);
    const tmpl_src = "type Foo[T Any]:\n  a T.nope\n\nfn main():\n  f := Foo[int]{a = 1}\n";
    try zt.eq(C.ErrorCompile, C.vm_eval(vm, tmpl_src, &res));
    try zt.expect(C.vm_compile_report(vm, 0, &rep));
    try zt.eqStr("Can not find the symbol `nope` in `int`.", C.from_bytes(rep.msg));
    try zt.eq(@as(u32, 1), rep.line);
    try zt.eqStr("nope", tmpl_src[rep.pos..rep.end_pos]);
    try zt.expect(C.vm_compile_report_note(vm, 0, 0, &rep));
    try zt.eq(C.ReportNote, rep.kind);
    try zt.eq(@as(usize, 0), rep.msg.len);
    try zt.eq(@as(u32, 4), rep.line);
    try zt.eq(@as(u32, 7), rep.col);
    try zt.eqStr("Foo[int]", tmpl_src[rep.pos..rep.end_pos]);
    try zt.expect(!C.vm_compile_report_note(vm, 0, 1, &rep));

    // A parse error and a token error report a position. The range is the code point there.
    C.vm_reset(vm);
    try zt.eq(C.ErrorCompile, C.vm_eval(vm, "a := 'abc", &res));
    try zt.expect(C.vm_compile_report(vm, 0, &rep));
    try zt.eq(C.ReportTokenError, rep.kind);
    try zt.eq(@as(u32, 0), rep.line);
    try zt.eq(@as(u32, 6), rep.col);
    try zt.eq(@as(u32, 0), rep.end_line);
    try zt.eq(@as(u32, 7), rep.end_col);
    try zt.eq(@as(u32, 6), rep.pos);
    try zt.eq(@as(u32, 7), rep.end_pos);

    // At the end of the source the range is empty.
    C.vm_reset(vm);
    try zt.eq(C.ErrorCompile, C.vm_eval(vm, "a := 1\nb := a +\n", &res));
    try zt.expect(C.vm_compile_report(vm, 0, &rep));
    try zt.eq(C.ReportParseError, rep.kind);
    try zt.expect(rep.has_loc);
    try zt.eq(@as(u32, 2), rep.line);
    try zt.eq(@as(u32, 0), rep.col);
    try zt.eq(@as(u32, 2), rep.end_line);
    try zt.eq(@as(u32, 0), rep.end_col);
    try zt.eq(@as(u32, 16), rep.pos);
    try zt.eq(@as(u32, 16), rep.end_pos);

    // `cl_vm_validate` records its error the same way.
    C.vm_reset(vm);
    try zt.eq(C.ErrorCompile, C.vm_validate(vm, "print(nope)"));
    try zt.eq(@as(usize, 1), C.vm_compile_report_count(vm));
    try zt.expect(C.vm_compile_report(vm, 0, &rep));
    try zt.eq(@as(u32, 6), rep.pos);
    try zt.eq(@as(u32, 10), rep.end_pos);

    // An error that does not belong to a source has no location.
    C.vm_reset(vm);
    var config = C.defaultEvalConfig();
    config.backend = C.BackendJIT;
    try zt.eq(C.ErrorCompile, C.vm_evalx(vm, "main", "a := 1", config, &res));
    try zt.expect(C.vm_compile_report(vm, 0, &rep));
    try zt.eq(@as(usize, 0), rep.uri.len);
    try zt.expect(!rep.has_loc);

    // The reports are those of the last compile.
    C.vm_reset(vm);
    try zt.eq(C.ErrorCompile, C.vm_eval(vm, "print(nope)", &res));
    try zt.eq(C.ErrorPanic, C.vm_eval(vm, "panic('boom')", &res));
    try zt.eq(@as(usize, 0), C.vm_compile_report_count(vm));
    try zt.expect(!C.vm_compile_report(vm, 0, &rep));
    try zt.eq(C.Success, C.vm_eval(vm, "a := 1", &res));
    try zt.eq(@as(usize, 0), C.vm_compile_report_count(vm));
}

test "A compile-time call with a string argument does not end the host." {
    // `#print('x')` ended the process with `panic: Unsupported: .eval_ref`, and a generic function evaluated
    // with a string freed the string twice (F-112). A host that only compiles, like the language server, died too.
    const vm = C.vm_init();
    defer C.vm_deinit(vm);

    var res: C.EvalResult = undefined;
    var err: C.CompileError = undefined;

    try zt.eq(C.ErrorCompile, C.vm_eval(vm, "#print('hello')\nprint(1)", &res));
    try zt.expect(C.vm_compile_error(vm, &err));
    try zt.eqStr("`type.info` does not support the type `EvalStr`.", C.from_bytes(err.msg));

    C.vm_reset(vm);
    try zt.eq(C.ErrorCompile, C.vm_validate(vm, "#print('hello')"));

    // The callee owns the argument, also when it passes it on and when it fails.
    C.vm_reset(vm);
    try zt.eq(C.Success, C.vm_eval(vm,
        \\fn g(x %T) -> int:
        \\    return 2
        \\fn f(x %T) -> int:
        \\    return g(x)
        \\#a := f('abc')
    , &res));

    C.vm_reset(vm);
    try zt.eq(C.ErrorCompile, C.vm_eval(vm,
        \\fn f(x %T) -> int:
        \\    return nope
        \\#a := f('abc')
    , &res));
    try zt.expect(C.vm_compile_error(vm, &err));
    try zt.eqStr("Could not find the symbol `nope`.", C.from_bytes(err.msg));
}

test "With error recovery every body reports its first error." {
    // docs/specs/2026-11-12-lsp-design.md, P2.
    const vm = C.vm_init();
    defer C.vm_deinit(vm);

    var res: C.EvalResult = undefined;
    var rep: C.Report = undefined;
    var err: C.CompileError = undefined;

    const src =
        \\fn a() -> int:
        \\    return nope1
        \\
        \\fn b() -> int:
        \\    x := 1
        \\    if x == 1:
        \\        return nope2
        \\    return nope2b
        \\
        \\type T:
        \\    v int
        \\
        \\fn (&T) m() -> int:
        \\    f := fn(y int) -> int:
        \\        return y + self.zz
        \\    return f(1)
        \\
        \\fn ok() -> int:
        \\    return 1
        \\
        \\print(a() + nope3)
        \\print(nope4)
    ;

    // Off by default: the compile ends at the first error, which is in the main block.
    try zt.eq(C.ErrorCompile, C.vm_eval(vm, src, &res));
    try zt.eq(@as(usize, 1), C.vm_compile_report_count(vm));
    try zt.expect(C.vm_compile_report(vm, 0, &rep));
    try zt.eqStr("Undeclared variable `nope3`.", C.from_bytes(rep.msg));

    // On: the main block and each function report their first error. A body is given up at that error,
    // so `nope4` and `nope2b` are not reported. The setting is kept across a reset.
    C.vm_set_error_recovery(vm, true);
    C.vm_reset(vm);
    try zt.eq(C.ErrorCompile, C.vm_eval(vm, src, &res));
    try zt.eq(@as(usize, 4), C.vm_compile_report_count(vm));
    const expected = [_]struct { line: u32, msg: []const u8 }{
        .{ .line = 20, .msg = "Undeclared variable `nope3`." },
        .{ .line = 1, .msg = "Undeclared variable `nope1`." },
        .{ .line = 6, .msg = "Undeclared variable `nope2`." },
        .{ .line = 14, .msg = "Field `zz` does not exist in `T`." },
    };
    for (expected, 0..) |exp, i| {
        try zt.expect(C.vm_compile_report(vm, i, &rep));
        try zt.eq(C.ReportCompileError, rep.kind);
        try zt.eq(exp.line, rep.line);
        try zt.eqStr(exp.msg, C.from_bytes(rep.msg));
    }
    try zt.expect(!C.vm_compile_report(vm, 4, &rep));
    // The summary and `cl_vm_compile_error` describe the first one.
    try zt.expect(C.vm_compile_error(vm, &err));
    try zt.eqStr("Undeclared variable `nope3`.", C.from_bytes(err.msg));

    // Nothing ran, and the next compile starts clean.
    try zt.eq(C.Success, C.vm_eval(vm, "fn main() -> int:\n    return 7", &res));
    try zt.eq(@as(i64, 7), @as(*i64, @ptrCast(@alignCast(res.res))).*);
    try zt.eq(@as(usize, 0), C.vm_compile_report_count(vm));

    // `cl_vm_validate` recovers the same way.
    C.vm_reset(vm);
    try zt.eq(C.ErrorCompile, C.vm_validate(vm, "fn a() -> int:\n    return nope1\nfn b() -> int:\n    return nope2"));
    try zt.eq(@as(usize, 2), C.vm_compile_report_count(vm));

    // A syntax error and an error in a declaration still end the compile.
    C.vm_reset(vm);
    try zt.eq(C.ErrorCompile, C.vm_eval(vm, "fn a() -> int:\n    return nope1\nfn b( -> int:\n    return nope2", &res));
    try zt.eq(@as(usize, 1), C.vm_compile_report_count(vm));
    try zt.expect(C.vm_compile_report(vm, 0, &rep));
    try zt.eq(C.ReportParseError, rep.kind);

    C.vm_reset(vm);
    try zt.eq(C.ErrorCompile, C.vm_eval(vm, "fn a(x Nope) -> int:\n    return 1\nfn b() -> int:\n    return nope2", &res));
    try zt.eq(@as(usize, 1), C.vm_compile_report_count(vm));
}

test "With error recovery a template that failed to expand is reported once." {
    const vm = C.vm_init();
    defer C.vm_deinit(vm);
    C.vm_set_error_recovery(vm, true);

    var res: C.EvalResult = undefined;
    var rep: C.Report = undefined;

    // `Foo[int]` fails in `a`. `b` asks for the same instance: it is given up without a second report, and
    // without using the instance that was left half resolved. `c` expands another instance, which has its own error.
    try zt.eq(C.ErrorCompile, C.vm_eval(vm,
        \\type Foo[T Any]:
        \\    a T.nope
        \\
        \\fn a():
        \\    f := Foo[int]{a = 1}
        \\
        \\fn b():
        \\    g := Foo[int]{a = 2}
        \\
        \\fn c():
        \\    h := Foo[str]{a = 2}
    , &res));
    try zt.eq(@as(usize, 2), C.vm_compile_report_count(vm));
    try zt.expect(C.vm_compile_report(vm, 0, &rep));
    try zt.eqStr("Can not find the symbol `nope` in `int`.", C.from_bytes(rep.msg));
    try zt.expect(C.vm_compile_report_note(vm, 0, 0, &rep));
    try zt.eq(@as(u32, 4), rep.line);
    try zt.expect(C.vm_compile_report(vm, 1, &rep));
    try zt.eqStr("Can not find the symbol `nope` in `str`.", C.from_bytes(rep.msg));
    try zt.expect(C.vm_compile_report_note(vm, 1, 0, &rep));
    try zt.eq(@as(u32, 10), rep.line);

    // The body of a function template is a body of its own, per instance.
    C.vm_reset(vm);
    try zt.eq(C.ErrorCompile, C.vm_eval(vm,
        \\fn id[T Any](x T) -> T:
        \\    return x.nope
        \\
        \\fn a() -> int:
        \\    return id[int](1)
        \\
        \\fn b() -> float:
        \\    return id[float](1.0) + nope2
    , &res));
    try zt.eq(@as(usize, 3), C.vm_compile_report_count(vm));
    try zt.expect(C.vm_compile_report(vm, 0, &rep));
    try zt.eqStr("Undeclared variable `nope2`.", C.from_bytes(rep.msg));
    try zt.expect(C.vm_compile_report(vm, 1, &rep));
    try zt.eqStr("Field `nope` does not exist in `int`.", C.from_bytes(rep.msg));
    try zt.expect(C.vm_compile_report(vm, 2, &rep));
    try zt.eqStr("Field `nope` does not exist in `float`.", C.from_bytes(rep.msg));

    // An instance whose signature does not resolve has no body to check (this aborted the compiler).
    C.vm_reset(vm);
    try zt.eq(C.ErrorCompile, C.vm_eval(vm,
        \\type Shape trait:
        \\    fn area() -> float
        \\fn hash[K Any](key K) -> int:
        \\    return 1
        \\x := hash[Shape]
    , &res));
    try zt.eq(@as(usize, 1), C.vm_compile_report_count(vm));
    try zt.expect(C.vm_compile_report(vm, 0, &rep));
    try zt.eqStr("Expected a value type for the parameter. `Shape` is a trait.", C.from_bytes(rep.msg));
}

test "cl_vm_symbol_at describes the names of the main source." {
    // docs/specs/2026-11-12-lsp-design.md, P3.
    const vm = C.vm_init();
    defer C.vm_deinit(vm);

    const src =
        \\use math
        \\
        \\type Vec2:
        \\    x float
        \\    y float
        \\
        \\fn (&Vec2) len() -> float:
        \\    return math.sqrt(self.x * self.x + self.y * self.y)
        \\
        \\type Color enum:
        \\    case red
        \\    case green
        \\
        \\const limit = 10
        \\
        \\fn add(a int, b int) -> int:
        \\    total := a + b
        \\    return total + limit
        \\
        \\v := Vec2{x = 1.0, y = 2.0}
        \\n := add(1, 2)
        \\c := Color.green
        \\print(v.len() + float(n))
        \\s := 'abc'
        \\print(s.len())
    ;
    const S = struct {
        /// Asks at the `nth` occurrence of `needle` and checks the range, the description and the declaration.
        fn expect(vm_: *C.VM, src_: []const u8, needle: []const u8, nth: usize, detail: []const u8, def: ?[]const u8) !void {
            var pos: usize = 0;
            var n: usize = 0;
            while (true) : (n += 1) {
                pos = std.mem.findPos(u8, src_, pos, needle).?;
                if (n == nth) break;
                pos += 1;
            }
            var info: C.SymbolInfo = undefined;
            try zt.expect(C.vm_symbol_at(vm_, @intCast(pos), &info));
            // `needle` starts with the name and can go on to tell one occurrence from another.
            try zt.eq(@as(u32, @intCast(pos)), info.pos);
            try zt.expect(std.mem.startsWith(u8, needle, src_[info.pos..info.end_pos]));
            try zt.eqStr(detail, C.from_bytes(info.detail));
            if (def) |text| {
                try zt.expect(info.has_def);
                try zt.eqStr("main", C.from_bytes(info.def_uri));
                try zt.eqStr(text, src_[info.def_pos..info.def_end_pos]);
            }
            // The position right after the name finds it too.
            var after: C.SymbolInfo = undefined;
            try zt.expect(C.vm_symbol_at(vm_, info.end_pos, &after));
            try zt.eq(info.pos, after.pos);
        }
    };

    var config = C.defaultCompileConfig();
    config.skip_codegen = true;
    var info: C.SymbolInfo = undefined;

    // Off by default: nothing is recorded.
    try zt.eq(C.Success, C.vm_compile(vm, "main", src, config));
    try zt.expect(!C.vm_symbol_at(vm, 5, &info));
    try zt.eq(@as(usize, 0), info.detail.len);

    C.vm_set_symbol_info(vm, true);
    try zt.eq(C.Success, C.vm_compile(vm, "main", src, config));

    // A local, at its declaration and at a use. Its type is the one that was inferred.
    try S.expect(vm, src, "total", 0, "total int", "total");
    try S.expect(vm, src, "total", 1, "total int", "total");
    try S.expect(vm, src, "v", 0, "v Vec2", "v");
    // A parameter.
    try S.expect(vm, src, "a + b", 0, "a int", "a");
    try S.expect(vm, src, "self", 0, "self &Vec2", null);
    // A field is declared by its name in the type.
    try S.expect(vm, src, "x *", 0, "x float", "x");
    // Functions, methods, types, constants: the first line of the declaration.
    try S.expect(vm, src, "add(1", 0, "fn add(a int, b int) -> int", "fn add(a int, b int) -> int:\n    total := a + b\n    return total + limit");
    try S.expect(vm, src, "len()", 1, "fn (&Vec2) len() -> float", null);
    try S.expect(vm, src, "Vec2{", 0, "type Vec2", "type Vec2:\n    x float\n    y float");
    try S.expect(vm, src, "limit", 1, "const limit = 10", "const limit = 10");
    try S.expect(vm, src, "Color.", 0, "type Color enum", null);
    try S.expect(vm, src, "green", 1, "case Color.green", null);

    // A name from a module is declared in that module. Attributes are not part of the description.
    var pos: u32 = @intCast(std.mem.find(u8, src, "sqrt").?);
    try zt.expect(C.vm_symbol_at(vm, pos, &info));
    try zt.eqStr("fn sqrt(a float) -> float", C.from_bytes(info.detail));
    try zt.expect(info.has_def);
    try zt.eqStr("math", C.from_bytes(info.def_uri));
    pos = @intCast(std.mem.find(u8, src, "math.").?);
    try zt.expect(C.vm_symbol_at(vm, pos, &info));
    try zt.eqStr("module math", C.from_bytes(info.detail));
    pos = @intCast(std.mem.find(u8, src, "s.len()").? + 2);
    try zt.expect(C.vm_symbol_at(vm, pos, &info));
    try zt.eqStr("fn (&str) len() -> int", C.from_bytes(info.detail));
    try zt.eqStr("core", C.from_bytes(info.def_uri));

    // Any other expression has its type. The smallest expression at the position is taken.
    pos = @intCast(std.mem.find(u8, src, "1.0").?);
    try zt.expect(C.vm_symbol_at(vm, pos, &info));
    try zt.eqStr("1.0", src[info.pos..info.end_pos]);
    try zt.eqStr("float", C.from_bytes(info.detail));
    try zt.expect(!info.has_def);
    pos = @intCast(std.mem.find(u8, src, "+ limit").?);
    try zt.expect(C.vm_symbol_at(vm, pos, &info));
    try zt.eqStr("total + limit", src[info.pos..info.end_pos]);
    try zt.eqStr("int", C.from_bytes(info.detail));

    // Nothing at a keyword or past the end.
    try zt.expect(!C.vm_symbol_at(vm, 0, &info));
    try zt.expect(!C.vm_symbol_at(vm, @intCast(src.len + 10), &info));

    // A compile that fails keeps what was resolved before the error.
    const bad = "fn add(a int, b int) -> int:\n    return a + b\nn := add(1, 2)\nprint(n + nope)";
    try zt.eq(C.ErrorCompile, C.vm_compile(vm, "main", bad, config));
    pos = @intCast(std.mem.find(u8, bad, "add(1").?);
    try zt.expect(C.vm_symbol_at(vm, pos, &info));
    try zt.eqStr("fn add(a int, b int) -> int", C.from_bytes(info.detail));
    pos = @intCast(std.mem.find(u8, bad, "nope").?);
    try zt.expect(!C.vm_symbol_at(vm, pos, &info));

    // The references are those of the last compile.
    try zt.eq(C.Success, C.vm_compile(vm, "main", "a := 1", config));
    try zt.expect(C.vm_symbol_at(vm, 0, &info));
    try zt.eqStr("a int", C.from_bytes(info.detail));
    try zt.expect(!C.vm_symbol_at(vm, 40, &info));
}

test "cl_vm_symbol_refs finds the places that name the same thing." {
    const vm = C.vm_init();
    defer C.vm_deinit(vm);
    C.vm_set_symbol_info(vm, true);

    const src =
        \\type Vec2:
        \\    x float
        \\    y float
        \\
        \\fn (&Vec2) sum() -> float:
        \\    return self.x + self.y + self.x
        \\
        \\fn add(a int, b int) -> int:
        \\    total := a + b
        \\    if total > 0:
        \\        total := a
        \\        return total
        \\    return total + a
        \\
        \\fn id[T Any](x T) -> T:
        \\    return x
        \\
        \\v := Vec2{x = 1.0, y = 2.0}
        \\print(v.sum() + float(add(1, 2)))
        \\print(add(id[int](3), 4))
        \\print(id[float](1.5))
    ;
    const S = struct {
        /// The texts of the lines that the ranges for the `nth` occurrence of `needle` start on are not useful
        /// to compare, so the ranges are compared as offsets of the occurrences of `needle` listed in `expected`.
        fn expect(vm_: *C.VM, src_: []const u8, needle: []const u8, nth: usize, expected: []const usize) !void {
            var offsets: [16]u32 = undefined;
            var n: usize = 0;
            var pos: usize = 0;
            while (std.mem.findPos(u8, src_, pos, needle)) |found| : (n += 1) {
                offsets[n] = @intCast(found);
                pos = found + 1;
            }
            var ptr: [*c]const C.Range = null;
            const len = C.vm_symbol_refs(vm_, offsets[nth], &ptr);
            try zt.eq(expected.len, len);
            for (expected, 0..) |occurrence, i| {
                try zt.eq(offsets[occurrence], ptr[i].pos);
            }
        }
    };

    var config = C.defaultCompileConfig();
    config.skip_codegen = true;
    try zt.eq(C.Success, C.vm_compile(vm, "main", src, config));

    var info: C.SymbolInfo = undefined;
    var ptr: [*c]const C.Range = null;

    // A local: its declaration and its uses. The inner `total` is another local, asked from any of its places.
    try S.expect(vm, src, "total", 0, &.{ 0, 1, 4 });
    try S.expect(vm, src, "total", 4, &.{ 0, 1, 4 });
    try S.expect(vm, src, "total", 2, &.{ 2, 3 });
    try S.expect(vm, src, "total", 3, &.{ 2, 3 });
    try zt.expect(C.vm_symbol_at(vm, @intCast(std.mem.find(u8, src, "total").?), &info));
    try zt.eq(C.SymbolLocal, info.kind);

    // A function: the name in its declaration and the calls. Asked at a call or at the declaration.
    try S.expect(vm, src, "add(", 1, &.{ 0, 1, 2 });
    try zt.expect(C.vm_symbol_at(vm, @intCast(std.mem.find(u8, src, "add(1").?), &info));
    try zt.eq(C.SymbolDecl, info.kind);

    // A field and a method.
    // `self` is not declared in the source. Its uses in the method are still found.
    try S.expect(vm, src, "self.", 0, &.{ 0, 1, 2 });
    const field_use: u32 = @intCast(std.mem.find(u8, src, "self.x").? + 5);
    var len = C.vm_symbol_refs(vm, field_use, &ptr);
    // The declaration, two uses in the method, and the name in the initializer `Vec2{x = 1.0, ...}`.
    try zt.eq(@as(usize, 4), len);
    try zt.eqStr("x float", src[ptr[0].pos .. ptr[0].pos + 7]);
    try zt.eqStr("x + self.y", src[ptr[1].pos .. ptr[1].pos + 10]);
    try zt.eq(@as(u32, 1), ptr[0].end_pos - ptr[0].pos);
    try S.expect(vm, src, "sum()", 1, &.{ 0, 1 });

    // A type.
    try S.expect(vm, src, "Vec2", 2, &.{ 0, 1, 2 });

    // A name inside a template is checked once per instance and listed once.
    const x_use: u32 = @intCast(std.mem.find(u8, src, "return x").? + 7);
    len = C.vm_symbol_refs(vm, x_use, &ptr);
    try zt.eq(@as(usize, 2), len);
    try zt.eqStr("x T)", src[ptr[0].pos .. ptr[0].pos + 4]);
    try zt.eq(x_use, ptr[1].pos);
    try S.expect(vm, src, "id[", 1, &.{ 0, 1, 2 });

    // An expression that is not a name, and a place without anything.
    len = C.vm_symbol_refs(vm, @intCast(std.mem.find(u8, src, "1.0").?), &ptr);
    try zt.eq(@as(usize, 0), len);
    try zt.expect(ptr == null);
    try zt.eq(@as(usize, 0), C.vm_symbol_refs(vm, 0, &ptr));
    try zt.expect(C.vm_symbol_at(vm, @intCast(std.mem.find(u8, src, "1.0").?), &info));
    try zt.eq(C.SymbolExpr, info.kind);
}

test "cl_vm_members_at and cl_vm_names_at list what can be written at a place." {
    const vm = C.vm_init();
    defer C.vm_deinit(vm);
    C.vm_set_symbol_info(vm, true);

    const src =
        \\use math
        \\
        \\type Vec2:
        \\    x float
        \\    y float
        \\    -secret int
        \\
        \\fn (&Vec2) sum() -> float:
        \\    return self.x + self.y
        \\
        \\fn Vec2 :: zero() -> Vec2:
        \\    return Vec2{x = 0.0, y = 0.0, secret = 0}
        \\
        \\type Color enum:
        \\    case red
        \\    case green
        \\
        \\const limit = 10
        \\
        \\fn add(first int, second int) -> int:
        \\    total := first + second
        \\    if total > limit:
        \\        inner := 1
        \\        return inner
        \\    return total
        \\
        \\v := Vec2.zero()
        \\s := 'abc'
        \\print(v.x)
        \\print(math.pi)
        \\print(s)
        \\c := Color.red
    ;
    const S = struct {
        fn find(items: [*c]const C.Item, len: usize, name: []const u8) ?C.Item {
            for (items[0..len]) |item| {
                if (std.mem.eql(u8, C.from_bytes(item.name), name)) return item;
            }
            return null;
        }
        /// The offset right after the `nth` occurrence of `needle`.
        fn after(src_: []const u8, needle: []const u8, nth: usize) u32 {
            var pos: usize = 0;
            var n: usize = 0;
            while (true) : (n += 1) {
                pos = std.mem.findPos(u8, src_, pos, needle).?;
                if (n == nth) return @intCast(pos + needle.len);
                pos += 1;
            }
        }
    };

    var config = C.defaultCompileConfig();
    config.skip_codegen = true;
    try zt.eq(C.Success, C.vm_compile(vm, "main", src, config));
    var items: [*c]const C.Item = null;

    // The members of a value: its fields and methods, also the private ones of a type of the main source.
    var len = C.vm_members_at(vm, S.after(src, "print(v", 0), &items);
    try zt.eqStr("x float", C.from_bytes(S.find(items, len, "x").?.detail));
    try zt.eq(C.ItemField, S.find(items, len, "x").?.kind);
    try zt.eqStr("fn (&Vec2) sum() -> float", C.from_bytes(S.find(items, len, "sum").?.detail));
    try zt.eq(C.ItemMethod, S.find(items, len, "sum").?.kind);
    try zt.expect(S.find(items, len, "secret") != null);
    try zt.expect(S.find(items, len, "y") != null);
    // Sorted by name.
    for (1..len) |i| {
        try zt.expect(std.mem.order(u8, C.from_bytes(items[i - 1].name), C.from_bytes(items[i].name)) == .lt);
    }

    // Through a borrow: `self` is `&Vec2`.
    len = C.vm_members_at(vm, S.after(src, "self", 0), &items);
    try zt.expect(S.find(items, len, "x") != null);
    try zt.expect(S.find(items, len, "sum") != null);

    // A builtin type has methods and no hooks or operators in the list.
    len = C.vm_members_at(vm, S.after(src, "print(s", 0), &items);
    try zt.eqStr("fn (&str) len() -> int", C.from_bytes(S.find(items, len, "len").?.detail));
    for (items[0..len]) |item| {
        const name = C.from_bytes(item.name);
        try zt.expect(std.ascii.isAlphabetic(name[0]) or name[0] == '_');
    }

    // A module and a type are asked for what they declare.
    len = C.vm_members_at(vm, S.after(src, "print(math", 0), &items);
    try zt.eqStr("fn sqrt(a float) -> float", C.from_bytes(S.find(items, len, "sqrt").?.detail));
    try zt.expect(S.find(items, len, "pi") != null);
    len = C.vm_members_at(vm, S.after(src, ":= Color", 0), &items);
    try zt.eq(C.ItemCase, S.find(items, len, "red").?.kind);
    try zt.eqStr("case Color.green", C.from_bytes(S.find(items, len, "green").?.detail));
    len = C.vm_members_at(vm, S.after(src, ":= Vec2", 0), &items);
    try zt.eqStr("fn Vec2 :: zero() -> Vec2", C.from_bytes(S.find(items, len, "zero").?.detail));
    // A function of a type without a receiver is a function, one with a receiver is a method.
    try zt.eq(C.ItemFunction, S.find(items, len, "zero").?.kind);
    try zt.eq(C.ItemMethod, S.find(items, len, "sum").?.kind);

    // Nothing ends at a keyword.
    try zt.eq(@as(usize, 0), C.vm_members_at(vm, 3, &items));
    try zt.expect(items == null);

    // The names in a function: its parameters and the locals declared before the position, the declarations
    // of the source, the module it uses and the builtins. Not the locals of the main block or of later lines.
    len = C.vm_names_at(vm, S.after(src, "return inner", 0), &items);
    try zt.eqStr("first int", C.from_bytes(S.find(items, len, "first").?.detail));
    try zt.eq(C.ItemLocal, S.find(items, len, "first").?.kind);
    try zt.eqStr("total int", C.from_bytes(S.find(items, len, "total").?.detail));
    try zt.expect(S.find(items, len, "inner") != null);
    try zt.eqStr("fn add(first int, second int) -> int", C.from_bytes(S.find(items, len, "add").?.detail));
    try zt.eq(C.ItemType, S.find(items, len, "Vec2").?.kind);
    try zt.eq(C.ItemConstant, S.find(items, len, "limit").?.kind);
    try zt.eq(C.ItemModule, S.find(items, len, "math").?.kind);
    try zt.eqStr("fn print(x %T)", C.from_bytes(S.find(items, len, "print").?.detail));
    try zt.expect(S.find(items, len, "int") != null);
    try zt.expect(S.find(items, len, "v") == null);
    try zt.expect(S.find(items, len, "s") == null);
    len = C.vm_names_at(vm, S.after(src, "total := first", 0), &items);
    try zt.expect(S.find(items, len, "first") != null);
    try zt.expect(S.find(items, len, "inner") == null);

    // In the main block: its locals declared so far, not those of a function.
    len = C.vm_names_at(vm, S.after(src, "print(s", 0), &items);
    try zt.eqStr("v Vec2", C.from_bytes(S.find(items, len, "v").?.detail));
    try zt.eqStr("s str", C.from_bytes(S.find(items, len, "s").?.detail));
    try zt.expect(S.find(items, len, "c") == null);
    try zt.expect(S.find(items, len, "total") == null);
    try zt.expect(S.find(items, len, "add") != null);
}

test "Compiling again and again with one VM does not grow its memory." {
    // Every compile left about 14 compile-time objects that nothing owned. A reset kept the pages of that heap,
    // so a host that checks sources with one VM (the language server) grew without bound (F-114).
    var da: std.heap.DebugAllocator(.{ .enable_memory_limit = true, .stack_trace_frames = 0 }) = .init;
    defer _ = da.deinit();
    const vm = C.vm_initx(da.allocator());
    defer C.vm_deinit(vm);
    const cvm: *cy.VM = @ptrCast(@alignCast(vm));

    var config = C.defaultCompileConfig();
    config.skip_codegen = true;
    // The template has a string parameter: its instance owns a compile-time object, which the syms release.
    const src = "type Foo[T Any]:\n    a T\ntype Tag[const S EvalStr]:\n    v int\nfn a() -> int:\n    f := Foo[int]{a = 1}\n    t := Tag['x']{v = 2}\n    return f.a + t.v\nprint(a())\n";
    const bad = "fn a() -> int:\n    return nope\nprint(a() + 'x')\n";

    try zt.eq(C.Success, C.vm_compile(vm, "main", src, config));
    C.vm_reset(vm);
    const base = da.total_requested_bytes;
    try zt.eq(@as(usize, 0), cvm.compiler.heap.count_objects());

    var i: usize = 0;
    while (i < 40) : (i += 1) {
        // Sources that compile and sources that do not, also with the options of the language server.
        C.vm_set_error_recovery(vm, i % 4 >= 2);
        C.vm_set_symbol_info(vm, i % 4 >= 2);
        if (i % 2 == 0) {
            try zt.eq(C.Success, C.vm_compile(vm, "main", src, config));
        } else {
            try zt.eq(C.ErrorCompile, C.vm_compile(vm, "main", bad, config));
        }
    }
    C.vm_reset(vm);
    try zt.eq(@as(usize, 0), cvm.compiler.heap.count_objects());
    try zt.eq(@as(usize, 1), cvm.compiler.heap.heapPages.items.len);
    // Buffers that keep their capacity across a reset may have grown once. They do not grow with every compile.
    const after_40 = da.total_requested_bytes;
    i = 0;
    while (i < 40) : (i += 1) {
        _ = C.vm_compile(vm, "main", if (i % 2 == 0) src else bad, config);
    }
    C.vm_reset(vm);
    try zt.eq(after_40, da.total_requested_bytes);
    try zt.expect(after_40 < base + 64 * 1024);

    // An eval after all of that still runs.
    C.vm_set_error_recovery(vm, false);
    C.vm_set_symbol_info(vm, false);
    var res: C.EvalResult = undefined;
    try zt.eq(C.Success, C.vm_eval(vm, "fn main() -> int:\n    return 7", &res));
    try zt.eq(@as(i64, 7), @as(*i64, @ptrCast(@alignCast(res.res))).*);
}

test "cl_vm_symbol_refs_to and cl_vm_symbol_tokens." {
    const vm = C.vm_init();
    defer C.vm_deinit(vm);
    C.vm_set_symbol_info(vm, true);
    var config = C.defaultCompileConfig();
    config.skip_codegen = true;

    const src =
        \\type Vec2:
        \\    x float
        \\
        \\fn (&Vec2) get() -> float:
        \\    return self.x
        \\
        \\fn add(a int, b int) -> int:
        \\    return a + b
        \\
        \\const limit = 10
        \\v := Vec2{x = 1.0}
        \\print(v.get() + float(add(limit, 2)))
        \\print(add(1, 2))
    ;
    try zt.eq(C.Success, C.vm_compile(vm, "main", src, config));
    var info: C.SymbolInfo = undefined;
    var ranges: [*c]const C.Range = null;

    // The name in a declaration can be asked like a use of it.
    const decl_name: u32 = @intCast(std.mem.find(u8, src, "add(a int").?);
    try zt.expect(C.vm_symbol_at(vm, decl_name, &info));
    try zt.eq(C.SymbolDecl, info.kind);
    try zt.eqStr("add", src[info.pos..info.end_pos]);
    try zt.eqStr("fn add(a int, b int) -> int", C.from_bytes(info.detail));
    try zt.eq(@as(usize, 3), C.vm_symbol_refs(vm, decl_name, &ranges));
    try zt.eq(decl_name, ranges[0].pos);
    // A field and a type too.
    try zt.expect(C.vm_symbol_at(vm, @intCast(std.mem.find(u8, src, "x float").?), &info));
    try zt.eqStr("x float", C.from_bytes(info.detail));
    try zt.eq(@as(usize, 3), C.vm_symbol_refs(vm, info.pos, &ranges));
    try zt.expect(C.vm_symbol_at(vm, 6, &info));
    try zt.eqStr("type Vec2", C.from_bytes(info.detail));

    // The places that name the declaration at a location: the same answer as asking at one of them.
    try zt.expect(C.vm_symbol_at(vm, @intCast(std.mem.find(u8, src, "add(1").?), &info));
    const def_pos = info.def_pos;
    try zt.eq(@as(usize, 3), C.vm_symbol_refs_to(vm, C.to_bytes("main"), def_pos, &ranges));
    try zt.eq(decl_name, ranges[0].pos);
    try zt.eq(@as(u32, 3), ranges[0].end_pos - ranges[0].pos);
    // Another source, or another place, declares something else.
    try zt.eq(@as(usize, 0), C.vm_symbol_refs_to(vm, C.to_bytes("other"), def_pos, &ranges));
    try zt.expect(ranges == null);
    try zt.eq(@as(usize, 0), C.vm_symbol_refs_to(vm, C.to_bytes("main"), def_pos + 1, &ranges));

    // The resolved names with what they are, sorted, one per name.
    var tokens: [*c]const C.Token = null;
    const len = C.vm_symbol_tokens(vm, &tokens);
    try zt.expect(len > 10);
    const S = struct {
        fn kindOf(src_: []const u8, tokens_: [*c]const C.Token, len_: usize, needle: []const u8) ?u32 {
            const pos = std.mem.find(u8, src_, needle).?;
            for (tokens_[0..len_]) |token| {
                if (token.pos == pos) return token.kind;
            }
            return null;
        }
    };
    try zt.eq(@as(?u32, C.ItemLocal), S.kindOf(src, tokens, len, "self.x"));
    try zt.eq(@as(?u32, C.ItemField), S.kindOf(src, tokens, len, "x\n\nfn add"));
    try zt.eq(@as(?u32, C.ItemLocal), S.kindOf(src, tokens, len, "v := "));
    try zt.eq(@as(?u32, C.ItemType), S.kindOf(src, tokens, len, "Vec2{"));
    try zt.eq(@as(?u32, C.ItemMethod), S.kindOf(src, tokens, len, "get() +"));
    try zt.eq(@as(?u32, C.ItemFunction), S.kindOf(src, tokens, len, "add(limit"));
    try zt.eq(@as(?u32, C.ItemConstant), S.kindOf(src, tokens, len, "limit, 2"));
    try zt.eq(@as(?u32, null), S.kindOf(src, tokens, len, "1.0"));
    try zt.eq(@as(?u32, null), S.kindOf(src, tokens, len, "return a"));
    for (1..len) |i| {
        try zt.expect(tokens[i].pos >= tokens[i - 1].end_pos);
    }
}

test "The symbol queries find nothing when there is no recorded compile." {
    // They read the main chunk, which is undefined before the first compile and freed by a reset: a host that
    // asked then crashed (final review, 2026-11-13).
    const vm = C.vm_init();
    defer C.vm_deinit(vm);
    var config = C.defaultCompileConfig();
    config.skip_codegen = true;

    const S = struct {
        fn expectNothing(vm_: *C.VM) !void {
            var info: C.SymbolInfo = undefined;
            var ranges: [*c]const C.Range = null;
            var items: [*c]const C.Item = null;
            var tokens: [*c]const C.Token = null;
            for ([_]u32{ 0, 3, 100000 }) |pos| {
                try zt.expect(!C.vm_symbol_at(vm_, pos, &info));
                try zt.eq(@as(usize, 0), info.detail.len);
                try zt.eq(@as(usize, 0), C.vm_symbol_refs(vm_, pos, &ranges));
                try zt.expect(ranges == null);
                try zt.eq(@as(usize, 0), C.vm_symbol_refs_to(vm_, C.to_bytes("main"), pos, &ranges));
                try zt.eq(@as(usize, 0), C.vm_members_at(vm_, pos, &items));
                try zt.eq(@as(usize, 0), C.vm_names_at(vm_, pos, &items));
                try zt.expect(items == null);
            }
            try zt.eq(@as(usize, 0), C.vm_symbol_tokens(vm_, &tokens));
        }
    };
    const src = "fn add(a int, b int) -> int:\n    return a + b\nn := add(1, 2)\n";

    // Before any compile, with the recording off and on.
    try S.expectNothing(vm);
    C.vm_set_symbol_info(vm, true);
    try S.expectNothing(vm);

    // After a reset.
    try zt.eq(C.Success, C.vm_compile(vm, "main", src, config));
    var info: C.SymbolInfo = undefined;
    try zt.expect(C.vm_symbol_at(vm, 3, &info));
    C.vm_reset(vm);
    try S.expectNothing(vm);

    // After a compile that failed before it had a main source: the chunk of the compile before it is gone.
    try zt.eq(C.Success, C.vm_compile(vm, "main", src, config));
    var jit = C.defaultCompileConfig();
    jit.backend = C.BackendJIT;
    try zt.eq(C.ErrorCompile, C.vm_compile(vm, "main", src, jit));
    try S.expectNothing(vm);

    // A compile that did not record answers nothing, not a part: the names in declarations are known to the
    // compiler either way, the locals are not.
    C.vm_set_symbol_info(vm, false);
    try zt.eq(C.Success, C.vm_compile(vm, "main", src, config));
    try S.expectNothing(vm);
    C.vm_set_symbol_info(vm, true);
    try zt.eq(C.Success, C.vm_compile(vm, "main", src, config));
    try zt.expect(C.vm_symbol_at(vm, 3, &info));
}

test "A method of a template instance whose signature fails is not found half built later." {
    // The function was reserved in the module of the instance before its signature was resolved. The next body
    // that called it (with error recovery), or the next eval of a session, read a function without a signature.
    const src =
        \\type W[T Any]:
        \\    v T
        \\fn (&W[]) bad() -> T.nope:
        \\    return self.v
        \\fn W[] :: make(v T) -> T.nope:
        \\    return v
        \\fn a() -> int:
        \\    w := W[int]{v = 1}
        \\    return w.bad()
        \\fn b() -> int:
        \\    w := W[int]{v = 1}
        \\    return w.bad()
        \\fn c() -> int:
        \\    return W[int].make(1)
        \\fn d() -> int:
        \\    return W[int].make(2)
    ;
    {
        const vm = C.vm_init();
        defer C.vm_deinit(vm);
        C.vm_set_error_recovery(vm, true);
        var res: C.EvalResult = undefined;
        var rep: C.Report = undefined;
        try zt.eq(C.ErrorCompile, C.vm_eval(vm, src, &res));
        // Every body that calls one of them reports that its signature does not resolve.
        try zt.eq(@as(usize, 4), C.vm_compile_report_count(vm));
        for (0..4) |i| {
            try zt.expect(C.vm_compile_report(vm, i, &rep));
            try zt.eqStr("Can not find the symbol `nope` in `int`.", C.from_bytes(rep.msg));
        }
    }
    {
        // A session without recovery: each eval that calls the method fails the same way.
        const vm = C.vm_init();
        defer C.vm_deinit(vm);
        var config = C.defaultEvalConfig();
        config.persist_main = true;
        var res: C.EvalResult = undefined;
        try zt.eq(C.Success, C.vm_evalx(vm, "main", "type W[T Any]:\n    v T\nfn (&W[]) bad() -> T.nope:\n    return self.v\nw := W[int]{v = 1}", config, &res));
        for (0..3) |_| {
            try zt.eq(C.ErrorCompile, C.vm_evalx(vm, "main", "x := w.bad()", config, &res));
            var err: C.CompileError = undefined;
            try zt.expect(C.vm_compile_error(vm, &err));
            try zt.eqStr("Can not find the symbol `nope` in `int`.", C.from_bytes(err.msg));
        }
        try zt.eq(C.Success, C.vm_evalx(vm, "main", "y := w.v", config, &res));
    }
}

test "Source that stops in the middle is a compile error, not a crash." {
    const vm = C.vm_init();
    defer C.vm_deinit(vm);
    var err: C.CompileError = undefined;

    // The parser read one byte past the end for a parameter name at the end of the source, and unwrapped a
    // missing expression after `return`.
    try zt.eq(C.ErrorCompile, C.vm_validate(vm, "fn f(a"));
    try zt.expect(C.vm_compile_error(vm, &err));
    try zt.eq(C.ReportParseError, err.kind);
    C.vm_reset(vm);
    try zt.eq(C.ErrorCompile, C.vm_validate(vm, "x := 1\nfn add(a int, b"));
    C.vm_reset(vm);
    try zt.eq(C.ErrorCompile, C.vm_validate(vm, "fn f():\n    return ,a\n"));
    try zt.expect(C.vm_compile_error(vm, &err));
    try zt.eqStr("Expected an expression after `return`.", C.from_bytes(err.msg));

    // The end of a `const` declaration without a type or a value was read from a type that is not there,
    // when the error for it was located.
    C.vm_reset(vm);
    try zt.eq(C.ErrorCompile, C.vm_validate(vm, "const a"));
    var rep: C.Report = undefined;
    try zt.expect(C.vm_compile_report(vm, 0, &rep));
    try zt.eq(@as(u32, 7), rep.end_pos);
    C.vm_reset(vm);
    try zt.eq(C.ErrorCompile, C.vm_validate(vm, "x := 1\nconst b = "));
    // A `cstruct` without fields (the end of its last field was read), and a function type whose attribute
    // list stops after `#[`.
    C.vm_reset(vm);
    _ = C.vm_validate(vm, "type Foo cstruct");
    {
        var out: C.Bytes = C.NullStr;
        _ = C.c.cl_vm_format(vm, C.to_bytes("type Foo cstruct"), &out);
        if (out.ptr != null) C.vm_freeb(vm, C.from_bytes(out));
    }
    C.vm_reset(vm);
    try zt.eq(C.ErrorCompile, C.vm_validate(vm, "type Callback = #["));

    // A constant that names a function (`const z = h` on the way to `const z = h()`): the signature of the
    // function was read before it was resolved.
    C.vm_reset(vm);
    try zt.eq(C.ErrorCompile, C.vm_validate(vm, "fn h() -> int:\n    return 4\nconst z = h\n"));
    try zt.expect(C.vm_compile_error(vm, &err));
    try zt.expect(std.mem.startsWith(u8, C.from_bytes(err.msg), "Unsupported expansion of compile-time value"));

    // A lambda that returns a borrow has no signature while its return type is inferred. The check of the
    // returned borrow read it.
    C.vm_reset(vm);
    try zt.eq(C.Success, C.vm_validate(vm, "local_a := 123\nborrow_a := &local_a\nstack_fn := fn() => borrow_a\n"));
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
