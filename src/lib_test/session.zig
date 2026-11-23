const std = @import("std");
const stdx = @import("stdx");
const C = @import("../capi.zig");
const zt = stdx.testing;

test "Return from main." {
    const vm = C.vm_init();
    defer C.vm_deinit(vm);

    var res: C.EvalResult = undefined;
    _ = C.vm_eval(vm,
        \\fn main() -> int:
        \\  return 123
    , &res);
    try zt.eq(123, @as(*i64, @ptrCast(res.res)).*);
}

test "The VM owns what main returns and releases it." {
    // Leak-checking allocator. The main block does not release the result of `main`, so a heap value used to
    // stay allocated after the VM was gone. It is released by the next eval, by `cl_vm_release_result` and
    // by the deinit.
    const vm = C.vm_initx(zt.alloc);
    defer C.vm_deinit(vm);

    var res: C.EvalResult = undefined;
    try zt.eq(C.Success, C.vm_eval(vm,
        \\fn main() -> str:
        \\  return 'abc' + '-padding-padding-padding-padding-padding'
    , &res));
    try zt.eqStr("abc-padding-padding-padding-padding-padding", C.str_bytes(@as(*C.str, @ptrCast(res.res)).*));

    // Released by the next eval. A result with a value inside, then an error.
    try zt.eq(C.Success, C.vm_eval(vm,
        \\type Pair:
        \\  name str
        \\  count ^int
        \\fn main() -> !?Pair:
        \\  return Pair{name = 'pair' + '-padding-padding-padding-padding-padding', count = ^3}
    , &res));
    C.vm_release_result(vm);
    // Nothing left to release.
    C.vm_release_result(vm);

    try zt.eq(C.Success, C.vm_eval(vm,
        \\type Step = fn() -> int
        \\fn main() -> Func[Step]:
        \\  n := ^5
        \\  return fn() -> int:
        \\    return n.*
    , &res));
}

test "Evals after a failed first compile." {
    // F-04. The first compile used to leave the core chunk loaded while `Compiler.cont` stayed false, so the next
    // compile loaded core again: SIGSEGV after a syntax error, `@program_init has already been declared` after a
    // sema error. Each failure kind is followed by a successful eval on the same VM.
    const vm = C.vm_initx(zt.alloc);
    defer C.vm_deinit(vm);
    C.setSilent(true);
    defer C.setSilent(false);

    var res: C.EvalResult = undefined;
    // Syntax error, twice.
    try zt.eq(C.ErrorCompile, C.vm_eval(vm, "x := ", &res));
    try zt.eq(C.ErrorCompile, C.vm_eval(vm, "x := ", &res));
    try zt.eq(C.Success, C.vm_eval(vm,
        \\use test
        \\test.eq(3, 1 + 2)
    , &res));

    // Sema error on a fresh VM.
    const vm2 = C.vm_initx(zt.alloc);
    defer C.vm_deinit(vm2);
    try zt.eq(C.ErrorCompile, C.vm_eval(vm2, "print(nope)", &res));
    {
        const summary = C.vm_compile_error_summary(vm2);
        defer C.vm_freeb(vm2, summary);
        try zt.expect(std.mem.indexOf(u8, summary, "nope") != null);
    }
    try zt.eq(C.Success, C.vm_eval(vm2,
        \\use test
        \\test.eq(3, 1 + 2)
    , &res));

    // Different uris, then a declaration from the failed eval does not block the next one.
    const vm3 = C.vm_initx(zt.alloc);
    defer C.vm_deinit(vm3);
    try zt.eq(C.ErrorCompile, C.vm_evalx(vm3, "first", "fn f() -> int:\n  return nope", C.defaultEvalConfig(), &res));
    try zt.eq(C.Success, C.vm_evalx(vm3, "second",
        \\fn f() -> int:
        \\  return 7
        \\use test
        \\test.eq(7, f())
    , C.defaultEvalConfig(), &res));

    // `cl_vm_validate` of bad source, then an eval. The compile error summary stays readable.
    const vm4 = C.vm_initx(zt.alloc);
    defer C.vm_deinit(vm4);
    try zt.eq(C.ErrorCompile, C.vm_validate(vm4, "_ = 1 +"));
    try zt.eq(C.Success, C.vm_eval(vm4, "_ = 1 + 2", &res));
    try zt.eq(C.ErrorCompile, C.vm_eval(vm4, "_ = 1 +", &res));
    {
        const summary = C.vm_compile_error_summary(vm4);
        defer C.vm_freeb(vm4, summary);
        try zt.expect(summary.len > 0);
    }
    try zt.eq(C.Success, C.vm_eval(vm4, "_ = 1 + 2", &res));

    // REPL shape: `persist_main`, a failed first input, then a local that persists.
    const vm5 = C.vm_initx(zt.alloc);
    defer C.vm_deinit(vm5);
    var config = C.defaultEvalConfig();
    config.persist_main = true;
    try zt.eq(C.ErrorCompile, C.vm_evalx(vm5, "repl", "x := ", config, &res));
    try zt.eq(C.Success, C.vm_evalx(vm5, "repl", "x := 5", config, &res));
    try zt.eq(C.Success, C.vm_evalx(vm5, "repl", "use test\ntest.eq(5, x)", config, &res));

    // A failed eval after a successful one: its declarations are not carried over (the function has no bytecode),
    // while the earlier eval's locals and functions still are.
    try zt.eq(C.Success, C.vm_evalx(vm5, "repl", "fn ok() -> int:\n  return 1", config, &res));
    try zt.eq(C.ErrorCompile, C.vm_evalx(vm5, "repl", "fn broken() -> int:\n  return nope\ntype P:\n  a int", config, &res));
    try zt.eq(C.Success, C.vm_evalx(vm5, "repl", "use test\ntest.eq(6, x + ok())", config, &res));
    try zt.eq(C.ErrorCompile, C.vm_evalx(vm5, "repl", "_ = broken()", config, &res));
    try zt.eq(C.ErrorCompile, C.vm_evalx(vm5, "repl", "_ = P{a=1}", config, &res));
    try zt.eq(C.Success, C.vm_evalx(vm5, "repl", "use test\ntest.eq(6, x + ok())", config, &res));
}

test "Private symbols of an earlier eval stay visible to the next eval of the same session." {
    // F-30. `-` symbols are visible to the chunk that declares them. The main chunks of a `persist_main` session
    // share one `srcUri`, so a method or field declared private in one eval is still reachable from the next one.
    C.setSilent(true);
    defer C.setSilent(false);

    var res: C.EvalResult = undefined;
    const vm = C.vm_initx(zt.alloc);
    defer C.vm_deinit(vm);
    var config = C.defaultEvalConfig();
    config.persist_main = true;
    try zt.eq(C.Success, C.vm_evalx(vm, "repl", "type Foo:\n  -b int = 1\n-fn (&Foo) m() -> int:\n  return self.b\n-fn s() -> int:\n  return 4", config, &res));
    try zt.eq(C.Success, C.vm_evalx(vm, "repl", "use test\nf := Foo{}\ntest.eq(f.m() + f.b + s(), 6)", config, &res));
}

test "A global initializer can call a function that reads a global of an earlier eval." {
    // F-88. The globals of an earlier eval are initialized, so the check of global initializers does not count them.
    // An initializer that reaches a global of its own eval too early is a compile error, and the session goes on.
    C.setSilent(true);
    defer C.setSilent(false);

    var res: C.EvalResult = undefined;
    const vm = C.vm_initx(zt.alloc);
    defer C.vm_deinit(vm);
    var config = C.defaultEvalConfig();
    config.persist_main = true;
    try zt.eq(C.Success, C.vm_evalx(vm, "repl", "global base int = 7\nfn get() -> int:\n  return base", config, &res));
    try zt.eq(C.Success, C.vm_evalx(vm, "repl", "use test\nglobal next int = get() + 1\ntest.eq(8, next)", config, &res));
    try zt.eq(C.ErrorCompile, C.vm_evalx(vm, "repl", "global a int = peek()\nglobal b int = 1\nfn peek() -> int:\n  return b", config, &res));
    const summary = C.vm_compile_error_summary(vm);
    defer C.vm_freeb(vm, summary);
    try zt.expect(std.mem.indexOf(u8, summary, "The initializer of `a` can reach `peek`") != null);
    try zt.eq(C.Success, C.vm_evalx(vm, "repl", "use test\ntest.eq(8, next)\ntest.eq(7, get())", config, &res));
}

test "cl_vm_validate checks against the session without resetting it." {
    // F-05. `cl_vm_validate` used to call `resetVM`: the persisted locals and declarations of a REPL session were
    // gone, and a validate that failed left the half-built first compile for the next eval (F-04's crash).
    // Now it compiles against the current session like an eval that is never run, and keeps none of its own
    // declarations.
    const S = struct {
        fn loader(vm_: *C.VM, mod: *C.Sym, uri: C.Bytes, res: [*c]C.LoaderResult) callconv(.c) bool {
            if (std.mem.eql(u8, C.from_bytes(uri), "gmod")) {
                res[0].src = C.to_bytes(
                    \\global counter int = 10
                    \\fn get() -> int:
                    \\  return counter
                    \\fn bump():
                    \\  counter += 1
                );
                return true;
            }
            return C.default_loader(vm_, mod, uri, res);
        }
    };
    C.setSilent(true);
    defer C.setSilent(false);

    var res: C.EvalResult = undefined;
    var config = C.defaultEvalConfig();
    config.persist_main = true;

    // A REPL session: a persisted local survives a good and a bad validate, and the compile error summary of the
    // bad one is readable.
    const vm = C.vm_initx(zt.alloc);
    defer C.vm_deinit(vm);
    try zt.eq(C.Success, C.vm_evalx(vm, "repl", "x := 5\nx", config, &res));
    try zt.eq(5, @as(*i64, @ptrCast(@alignCast(res.res))).*);
    try zt.eq(C.Success, C.vm_validate(vm, "_ = x + 1"));
    // The eval result the host still holds is untouched.
    try zt.eq(5, @as(*i64, @ptrCast(@alignCast(res.res))).*);
    try zt.eq(C.ErrorCompile, C.vm_validate(vm, "_ = x +"));
    {
        const summary = C.vm_compile_error_summary(vm);
        defer C.vm_freeb(vm, summary);
        try zt.expect(summary.len > 0);
    }
    try zt.eq(C.ErrorCompile, C.vm_validate(vm, "_ = nope"));
    {
        const summary = C.vm_compile_error_summary(vm);
        defer C.vm_freeb(vm, summary);
        try zt.expect(std.mem.indexOf(u8, summary, "nope") != null);
    }
    try zt.eq(C.Success, C.vm_evalx(vm, "repl", "use test\ntest.eq(5, x)", config, &res));

    // Declarations of a validated source are not kept: the next eval neither sees them nor fails on them.
    try zt.eq(C.Success, C.vm_validate(vm, "fn v() -> int:\n  return 1\ntype Q:\n  a int\ny := 7\n_ = v() + Q{a=1}.a + y"));
    try zt.eq(C.ErrorCompile, C.vm_evalx(vm, "repl", "_ = v()", config, &res));
    try zt.eq(C.ErrorCompile, C.vm_evalx(vm, "repl", "_ = Q{a=1}", config, &res));
    try zt.eq(C.ErrorCompile, C.vm_evalx(vm, "repl", "_ = y", config, &res));
    try zt.eq(C.Success, C.vm_evalx(vm, "repl", "fn v() -> int:\n  return 2\ntype Q:\n  a int\ny := 8", config, &res));
    try zt.eq(C.Success, C.vm_evalx(vm, "repl", "use test\ntest.eq(15, x + v() + Q{a=0}.a + y)", config, &res));

    // Declarations from earlier evals are still visible to a validate.
    try zt.eq(C.Success, C.vm_validate(vm, "_ = v() + Q{a=x}.a + y"));
    try zt.eq(C.ErrorCompile, C.vm_validate(vm, "_ = v(1)"));

    // A validate on a fresh VM, then evals.
    const vm2 = C.vm_initx(zt.alloc);
    defer C.vm_deinit(vm2);
    try zt.eq(C.Success, C.vm_validate(vm2, "fn f() -> int:\n  return 1\n_ = f()"));
    try zt.eq(C.ErrorCompile, C.vm_evalx(vm2, "repl", "_ = f()", config, &res));
    try zt.eq(C.Success, C.vm_evalx(vm2, "repl", "x := 5", config, &res));
    try zt.eq(C.Success, C.vm_evalx(vm2, "repl", "use test\ntest.eq(5, x)", config, &res));

    // A module first loaded by a validate is initialized by the next eval that runs: its extern functions are
    // bound (`math`) and its globals are initialized (`gmod`).
    const vm3 = C.vm_initx(zt.alloc);
    defer C.vm_deinit(vm3);
    C.vm_set_loader(vm3, @ptrCast(&S.loader));
    try zt.eq(C.Success, C.vm_validate(vm3, "use math\nuse gmod\n_ = math.sqrt(16.0) + float(gmod.get())"));
    try zt.eq(C.Success, C.vm_evalx(vm3, "repl",
        \\use math
        \\use gmod
        \\use test
        \\test.eq(4.0, math.sqrt(16.0))
        \\test.eq(10, gmod.get())
        \\gmod.bump()
        \\test.eq(11, gmod.get())
    , config, &res));
    // The module is not initialized twice.
    try zt.eq(C.Success, C.vm_evalx(vm3, "repl", "use gmod\nuse test\ntest.eq(11, gmod.get())", config, &res));

    // Without `persist_main` the same holds for a plain eval sequence.
    const vm4 = C.vm_initx(zt.alloc);
    defer C.vm_deinit(vm4);
    try zt.eq(C.Success, C.vm_eval(vm4, "use test\ntest.eq(1, 1)", &res));
    try zt.eq(C.Success, C.vm_validate(vm4, "use math\n_ = math.floor(1.5)"));
    try zt.eq(C.ErrorCompile, C.vm_validate(vm4, "use math\n_ = math.floor('a')"));
    try zt.eq(C.Success, C.vm_eval(vm4, "use math\nuse test\ntest.eq(1.0, math.floor(1.5))", &res));
}

test "Eval without main after an eval with main." {
    const vm = C.vm_init();
    defer C.vm_deinit(vm);

    var res: C.EvalResult = undefined;
    try zt.eq(C.Success, C.vm_eval(vm,
        \\fn main() -> int:
        \\  return 123
    , &res));
    try zt.eq(C.Success, C.vm_eval(vm,
        \\a := 1
    , &res));
}

test "persist_main keeps top level funcs across evals." {
    const vm = C.vm_init();
    defer C.vm_deinit(vm);

    var config = C.defaultEvalConfig();
    config.persist_main = true;
    var res: C.EvalResult = undefined;
    try zt.eq(C.Success, C.vm_evalx(vm, "repl",
        \\fn foo() -> int:
        \\  return 123
    , config, &res));
    try zt.eq(C.Success, C.vm_evalx(vm, "repl",
        \\fn main() -> int:
        \\  return foo()
    , config, &res));
    try zt.eq(123, @as(*i64, @ptrCast(res.res)).*);
}

test "A lambda that an overload did not take leaves nothing behind in a session." {
    // The lambda is checked for each overload. The ones that are dropped are not generated, also in the
    // evals that follow, and they are freed with the session (leak-checking allocator).
    C.setSilent(true);
    defer C.setSilent(false);

    const vm = C.vm_initx(zt.alloc);
    defer C.vm_deinit(vm);

    var config = C.defaultEvalConfig();
    config.persist_main = true;
    var res: C.EvalResult = undefined;
    try zt.eq(C.Success, C.vm_evalx(vm, "repl",
        \\fn pick(x int, f fn(int) -> str) -> str:
        \\  return 'str %{f(x)}'
        \\fn pick(x int, f fn(int) -> int) -> str:
        \\  return 'int %{f(x)}'
        \\fn ap(x int, f fn(int) -> int) -> int:
        \\  return f(x)
        \\use test
        \\test.eq('int 12', pick(1, |x| if (x > 0) ap(x, |y| y + 11) else 0))
    , config, &res));
    try zt.eq(C.Success, C.vm_evalx(vm, "repl",
        \\use test
        \\r := pick(1, |x|):
        \\  if x > 5:
        \\    return 3
        \\  return ap(x, |y| y + 1)
        \\test.eq('int 2', r)
    , config, &res));
    // No overload takes the lambda: the eval fails and the session goes on.
    try zt.eq(C.ErrorCompile, C.vm_evalx(vm, "repl", "_ = pick(1, |x| if (x > 0) 1.5 else ap(x, |y| y))", config, &res));
    try zt.eq(C.Success, C.vm_evalx(vm, "repl", "use test\ntest.eq('int 3', pick(2, |x| ap(x, |y| y + 1)))\ntest.eq('int 2', r)", config, &res));
}

test "An argument that an overload with template parameters did not take leaves nothing behind in a session." {
    // The lambda is checked to its end for the overload that infers, and dropped when its type does not have
    // the form of the parameter. A literal that an overload can not take is not made.
    C.setSilent(true);
    defer C.setSilent(false);

    const vm = C.vm_initx(zt.alloc);
    defer C.vm_deinit(vm);

    var config = C.defaultEvalConfig();
    config.persist_main = true;
    var res: C.EvalResult = undefined;
    try zt.eq(C.Success, C.vm_evalx(vm, "repl",
        \\fn opt(x %T, f fn(T) -> ?%U) -> str:
        \\  return 'option'
        \\fn opt(x float, f fn(float) -> float) -> str:
        \\  return 'float %{f(x)}'
        \\fn ap(x float, f fn(float) -> float) -> float:
        \\  return f(x)
        \\fn tag(x %T, y str) -> str:
        \\  return 'str'
        \\fn tag(x int, y ?[]int) -> str:
        \\  return 'option'
        \\use test
        \\test.eq('float 3.0', opt(1, |x| ap(x, |y| y + 2)))
        \\test.eq('option', tag(1, none))
        \\test.eq('option', tag(1, {1, 2}))
    , config, &res));
    try zt.eq(C.Success, C.vm_evalx(vm, "repl",
        \\use test
        \\k := ^1.5
        \\test.eq('float 2.0', opt(1, fn(x float) -> float => ap(x, |y| y * 2)))
    , config, &res));
    // No overload takes the arguments: the eval fails and the session goes on.
    try zt.eq(C.ErrorCompile, C.vm_evalx(vm, "repl", "_ = opt('a', |x| ap(1, |y| y))", config, &res));
    try zt.eq(C.ErrorCompile, C.vm_evalx(vm, "repl", "_ = tag(1, true)", config, &res));
    try zt.eq(C.Success, C.vm_evalx(vm, "repl", "use test\ntest.eq('float 4.0', opt(2, |x| ap(x, |y| y + 2)))", config, &res));
}

test "persist_main returns the last top level expression as the eval result." {
    // Leak-checking allocator: the VM owns a copy of each result until the next eval or deinit.
    const vm = C.vm_initx(zt.alloc);
    defer C.vm_deinit(vm);

    var config = C.defaultEvalConfig();
    config.persist_main = true;
    var res: C.EvalResult = undefined;
    try zt.eq(C.Success, C.vm_evalx(vm, "repl", "1 + 2", config, &res));
    try zt.eq(@as(C.TypeId, @intCast(C.TypeI64)), res.res_t);
    try zt.eq(3, @as(*i64, @ptrCast(res.res)).*);

    // A local as the result stays usable afterwards.
    try zt.eq(C.Success, C.vm_evalx(vm, "repl", "s := 'abc' + 'd'\ns", config, &res));
    try zt.eq(@as(C.TypeId, @intCast(C.TypeStr)), res.res_t);
    try zt.eqStr("abcd", C.str_bytes(@as(*C.str, @ptrCast(res.res)).*));
    try zt.eq(C.Success, C.vm_evalx(vm, "repl", "s + '!'", config, &res));
    try zt.eqStr("abcd!", C.str_bytes(@as(*C.str, @ptrCast(res.res)).*));

    // A statement without a value gives no result.
    try zt.eq(C.Success, C.vm_evalx(vm, "repl", "_ = s.len()", config, &res));
    try zt.eq(@as(C.TypeId, @intCast(C.TypeVoid)), res.res_t);
    try zt.eq(C.Success, C.vm_evalx(vm, "repl", "x := 1", config, &res));
    try zt.eq(@as(C.TypeId, @intCast(C.TypeVoid)), res.res_t);

    // The previous result is released by the next eval and the local is intact.
    try zt.eq(C.Success, C.vm_evalx(vm, "repl", "use test\ntest.eq('abcd', s)\ns.len() + x", config, &res));
    try zt.eq(5, @as(*i64, @ptrCast(res.res)).*);

    // A local that can not be copied is shown as it is and keeps its value.
    try zt.eq(C.Success, C.vm_evalx(vm, "repl", "m := Map[str, int]{}\nm['a'] = 1\nm", config, &res));
    try zt.eq(true, res.res_t != @as(C.TypeId, @intCast(C.TypeVoid)));
    try zt.eq(C.Success, C.vm_evalx(vm, "repl", "m['a'] + 1", config, &res));
    try zt.eq(2, @as(*i64, @ptrCast(res.res)).*);
}

test "persist_main keeps main locals across evals." {
    // Leak-checking allocator: restored values are moved, not copied, and a panic drops the saves.
    const vm = C.vm_initx(zt.alloc);
    defer C.vm_deinit(vm);

    var config = C.defaultEvalConfig();
    config.persist_main = true;
    var res: C.EvalResult = undefined;
    try zt.eq(C.Success, C.vm_evalx(vm, "repl",
        \\type P:
        \\  n int
        \\  name str
        \\fn depth(n int) -> int:
        \\  return if (n == 0) 0 else 1 + depth(n - 1)
        \\x := 5
        \\s := 'abcdefghijklmnopqrstuvwxyz' + '0123456789'
        \\p := P{n=1, name=s + '!'}
        \\-- Grows the stack after the locals were declared.
        \\_ = depth(20000)
    , config, &res));
    try zt.eq(C.Success, C.vm_evalx(vm, "repl",
        \\use test
        \\test.eq(5, x)
        \\test.eq(36, s.len())
        \\test.eq(37, p.name.len())
        \\x = x + 1
        \\p.n += 1
    , config, &res));
    try zt.eq(C.Success, C.vm_evalx(vm, "repl",
        \\use test
        \\test.eq(6, x)
        \\test.eq(2, p.n)
        \\-- Redeclaring releases the previous value.
        \\s := 10
        \\test.eq(10, s)
    , config, &res));
    // The expected errors would print error traces.
    C.setSilent(true);
    defer C.setSilent(false);
    // A compile error keeps the saves.
    try zt.eq(C.ErrorCompile, C.vm_evalx(vm, "repl", "undefined_thing", config, &res));
    try zt.eq(C.Success, C.vm_evalx(vm, "repl",
        \\use test
        \\test.eq(6, x)
    , config, &res));
    // A top level borrow would point at the old stack slot after the next eval grows the stack, and a
    // `[&]T{...}` literal borrows a hidden vector that is not carried over. Borrows inside a block are fine.
    try zt.eq(C.ErrorCompile, C.vm_evalx(vm, "repl", "sp := [&]int{1, 2}", config, &res));
    try zt.eq(C.ErrorCompile, C.vm_evalx(vm, "repl", "r := &x", config, &res));
    try zt.eq(C.ErrorCompile, C.vm_evalx(vm, "repl",
        \\v := [2]int{1, 2}
        \\sp := v[0..2]
    , config, &res));
    try zt.eq(C.Success, C.vm_evalx(vm, "repl",
        \\if true:
        \\  r := &x
        \\  sp := [&]int{1, 2}
        \\  test.eq(6, r.*)
        \\  test.eq(2, sp[1])
    , config, &res));
    // A panic frees the heap, so the saves are dropped.
    try zt.eq(C.ErrorPanic, C.vm_evalx(vm, "repl", "panic('boom')", config, &res));
    try zt.eq(C.ErrorCompile, C.vm_evalx(vm, "repl", "print(x)", config, &res));
}

test "persist_main: a top level local moves with `move` only, and a moved one is gone for the next eval." {
    // The next eval restores every tracked main local and does not know what the earlier evals moved. An implicit
    // move (`eat(a)`) left `a` readable after its buffer was freed. Leak-checking allocator.
    const vm = C.vm_initx(zt.alloc);
    defer C.vm_deinit(vm);
    C.setSilent(true);
    defer C.setSilent(false);

    var config = C.defaultEvalConfig();
    config.persist_main = true;
    var res: C.EvalResult = undefined;
    try zt.eq(C.Success, C.vm_evalx(vm, "repl",
        \\use test
        \\type Box:
        \\    xs Array[str]
        \\    n int
        \\fn eat(x Array[str]) -> int:
        \\    return x.len()
        \\fn long(n int) -> str:
        \\    return 'abcdefghijklmnopqrstuvwxyz' + str(n)
        \\a := Array[str]{long(1), long(2)}
        \\bx := Box{xs=Array[str]{long(3)}, n=1}
    , config, &res));

    // No implicit move of a top level local: as an argument, as an initializer, from a branch, of a member.
    const implicit = [_][]const u8{
        "test.eq(2, eat(a))",
        "b := a",
        "if a.len() == 2:\n    test.eq(2, eat(a))",
    };
    for (implicit) |src| {
        try zt.eq(C.ErrorCompile, C.vm_evalx(vm, "repl", src, config, &res));
        const summary = C.vm_compile_error_summary(vm);
        defer C.vm_freeb(vm, summary);
        try zt.expect(std.mem.indexOf(u8, summary, "The top level variable `a` of the REPL does not move without `move`: later inputs read it. Write `move a`") != null);
    }
    try zt.eq(C.ErrorCompile, C.vm_evalx(vm, "repl", "test.eq(1, eat(bx.xs))", config, &res));
    {
        const summary = C.vm_compile_error_summary(vm);
        defer C.vm_freeb(vm, summary);
        try zt.expect(std.mem.indexOf(u8, summary, "A member of the top level variable `bx` of the REPL does not move") != null);
    }
    try zt.eq(C.ErrorCompile, C.vm_evalx(vm, "repl", "c := move bx.xs", config, &res));
    {
        const summary = C.vm_compile_error_summary(vm);
        defer C.vm_freeb(vm, summary);
        try zt.expect(std.mem.indexOf(u8, summary, "Cannot move a member of the top level variable `bx` of the REPL") != null);
    }
    // The failed inputs moved nothing.
    try zt.eq(C.Success, C.vm_evalx(vm, "repl", "test.eq(2, a.len())\ntest.eq(27, a[0].len())\ntest.eq(1, bx.xs.len())", config, &res));

    // A local of a function or of a nested block ends with the input and moves as in a script.
    try zt.eq(C.Success, C.vm_evalx(vm, "repl",
        \\fn f() -> int:
        \\    q := Array[str]{long(4)}
        \\    return eat(q)
        \\test.eq(1, f())
        \\if a.len() == 2:
        \\    q := Array[str]{long(5), long(6)}
        \\    test.eq(2, eat(q))
    , config, &res));

    // `move` gives the value away. The local is not restored: the later evals do not know the name.
    try zt.eq(C.Success, C.vm_evalx(vm, "repl", "b := move a\ntest.eq(2, b.len())", config, &res));
    try zt.eq(C.ErrorCompile, C.vm_evalx(vm, "repl", "test.eq(2, a.len())", config, &res));
    {
        const summary = C.vm_compile_error_summary(vm);
        defer C.vm_freeb(vm, summary);
        try zt.expect(std.mem.indexOf(u8, summary, "Undeclared variable `a`.") != null);
    }
    try zt.eq(C.Success, C.vm_evalx(vm, "repl", "test.eq(27, b[0].len())\ntest.eq(1, bx.n)", config, &res));
    // A restored local that a branch moves is gone as well. The other branch destructs it.
    try zt.eq(C.Success, C.vm_evalx(vm, "repl", "if bx.n == 1:\n    test.eq(2, eat(move b))", config, &res));
    try zt.eq(C.ErrorCompile, C.vm_evalx(vm, "repl", "test.eq(2, b.len())", config, &res));
    try zt.eq(C.Success, C.vm_evalx(vm, "repl", "d := Array[str]{long(7)}\nif bx.n == 2:\n    test.eq(1, eat(move d))", config, &res));
    try zt.eq(C.ErrorCompile, C.vm_evalx(vm, "repl", "test.eq(1, d.len())", config, &res));
    // An assignment does not give a moved top level local a value again. A local of a function or a block gets one.
    try zt.eq(C.Success, C.vm_evalx(vm, "repl", "fn same(x Array[str]) -> Array[str]:\n    return x\ng := Array[str]{long(9)}", config, &res));
    try zt.eq(C.ErrorCompile, C.vm_evalx(vm, "repl", "h := move g\ng = Array[str]{long(10)}", config, &res));
    {
        const summary = C.vm_compile_error_summary(vm);
        defer C.vm_freeb(vm, summary);
        try zt.expect(std.mem.indexOf(u8, summary, "Cannot assign to the top level variable `g` of the REPL after it was moved. Declare it again with `g := ...`.") != null);
    }
    try zt.eq(C.ErrorCompile, C.vm_evalx(vm, "repl", "g = same(move g)", config, &res));
    try zt.eq(C.Success, C.vm_evalx(vm, "repl",
        \\test.eq(1, g.len())
        \\if bx.n == 1:
        \\    q := Array[str]{long(11)}
        \\    q = same(q)
        \\    for 0..2:
        \\        q = same(q)
        \\    test.eq(28, q[0].len())
        \\t := same(move g)
        \\g := move t
    , config, &res));
    try zt.eq(C.Success, C.vm_evalx(vm, "repl", "test.eq(1, g.len())", config, &res));
    // The name can be declared again, and the other locals are kept.
    try zt.eq(C.Success, C.vm_evalx(vm, "repl", "a := Array[str]{long(8)}\ne := move a\na := 3", config, &res));
    try zt.eq(C.Success, C.vm_evalx(vm, "repl", "test.eq(3, a)\ntest.eq(1, e.len())\ntest.eq(1, bx.xs.len())", config, &res));
}

test "Multiple evals with same VM." {
    const vm = C.vm_init();
    defer C.vm_deinit(vm);

    const src =
        \\use test
        \\a := 1
        \\test.eq(a, 1)
        ;

    var eval_res: C.EvalResult = undefined;
    var res = C.vm_eval(vm, src, &eval_res);
    try zt.eq(C.Success, res);

    res = C.vm_eval(vm, src, &eval_res);
    try zt.eq(C.Success, res);

    res = C.vm_eval(vm, src, &eval_res);
    try zt.eq(C.Success, res);
}

test "A compile that fails leaves no state that the next compile trips on." {
    // tars-agent M0: a closure that captures a local fails to compile, and the next compile of the same VM
    // crashed. A host module whose source fails to compile crashed the third eval that used it.
    const S = struct {
        fn loader(vm_: *C.VM, mod: *C.Sym, uri: C.Bytes, res: [*c]C.LoaderResult) callconv(.c) bool {
            if (std.mem.eql(u8, C.from_bytes(uri), "badmod")) {
                res[0].src = C.to_bytes(
                    \\fn read(path str) -> !str:
                    \\    return undefined_thing
                );
                return true;
            }
            return C.default_loader(vm_, mod, uri, res);
        }
    };
    C.setSilent(true);
    defer C.setSilent(false);

    var res: C.EvalResult = undefined;
    const bad = [_][]const u8{
        // A closure that captures a local. The instance of `sort` is made, its body is not checked.
        \\names := []str{'a', 'b'}
        \\counts := Map[str, int]{}
        \\names.sort(|a, b| counts[a] > counts[b])
        ,
        // New template instances, then an error in the main block.
        \\m := Map[int, str]{}
        \\m[1] = 'a'
        \\l := []float{1.0}
        \\l.sort(|a, b| a < b)
        \\_ = nope
        ,
        // An error in a function body after the main block expanded templates.
        \\type P:
        \\    a int
        \\fn f() -> int:
        \\    return nope
        \\ps := []P{P{a=1}}
        \\o := ?[]str(none)
        \\_ = f()
        ,
        // A syntax error.
        \\x := (
        ,
        // A module with extern functions, loaded first by the failed compile.
        \\use math
        \\_ = math.sqrt(4.0) + nope
    };
    const good = [_][]const u8{
        \\counts := Map[str, int]{}
        \\counts['a'] = 1
        \\print(counts['a'])
        ,
        \\use test
        \\names := []str{'b', 'a'}
        \\names.sort(|a, b| a.less(b))
        \\test.eq(names[0], 'a')
        ,
        \\use test
        \\m := Map[int, str]{}
        \\m[1] = 'a'
        \\l := []float{2.0, 1.0}
        \\l.sort(|a, b| a < b)
        \\test.eq(l[0], 1.0)
        \\test.eq(m[1], 'a')
        ,
        \\use test
        \\o := ?[]str(none)
        \\test.eq(o == none, true)
        \\type P:
        \\    a int
        \\ps := []P{P{a=1}}
        \\test.eq(ps[0].a, 1)
        ,
        \\use test
        \\use math
        \\test.eq(math.sqrt(4.0), 2.0)
    };

    for ([_]bool{ true, false }) |persist| {
        var config = C.defaultEvalConfig();
        config.persist_main = persist;
        // One session for each failure, after a first eval that succeeds: a failed first compile resets the VM.
        for (bad) |b| {
            const vm = C.vm_initx(zt.alloc);
            defer C.vm_deinit(vm);
            try zt.eq(C.Success, C.vm_evalx(vm, "main", "_ = 1", config, &res));
            for (good) |g| {
                try zt.eq(C.ErrorCompile, C.vm_validate(vm, b));
                try zt.eq(C.Success, C.vm_validate(vm, g));
                try zt.eq(C.Success, C.vm_evalx(vm, "main", g, config, &res));
                try zt.eq(C.ErrorCompile, C.vm_evalx(vm, "main", b, config, &res));
                try zt.eq(C.Success, C.vm_evalx(vm, "main", g, config, &res));
            }
            // Failures in a row.
            for (bad) |b2| {
                try zt.eq(C.ErrorCompile, C.vm_evalx(vm, "main", b2, config, &res));
            }
            for (good) |g| {
                try zt.eq(C.Success, C.vm_evalx(vm, "main", g, config, &res));
            }
        }
        // A host module that fails to compile.
        const vm = C.vm_initx(zt.alloc);
        defer C.vm_deinit(vm);
        C.vm_set_loader(vm, @ptrCast(&S.loader));
        for (0..4) |_| {
            try zt.eq(C.ErrorCompile, C.vm_evalx(vm, "main", "use badmod\nprint(badmod.read('x')!)", config, &res));
            try zt.eq(C.Success, C.vm_evalx(vm, "main", "_ = 1 + 2", config, &res));
        }
    }
}


test "A template instance that a failed compile left behind and that does not compile fails no later compile." {
    // `Map[[]int, int]` has no hash for its key. After an error ahead of it, its body was never checked, and
    // the next compile, which does not use it, must not report its error.
    C.setSilent(true);
    defer C.setSilent(false);
    var res: C.EvalResult = undefined;
    var config = C.defaultEvalConfig();
    config.persist_main = true;
    const Step = struct { src: []const u8, code: C.ResultCode };
    const seqs = [_][]const Step{
        &.{
            .{ .src = "_ = 1", .code = C.Success },
            .{ .src = "m := Map[[]int, int]{}", .code = C.ErrorCompile },
            .{ .src = "_ = 2", .code = C.Success },
            .{ .src = "m := Map[[]int, int]{}", .code = C.ErrorCompile },
            .{ .src = "_ = 3", .code = C.Success },
        },
        &.{
            .{ .src = "_ = 1", .code = C.Success },
            .{ .src = "m := Map[[]int, int]{}\n_ = nope", .code = C.ErrorCompile },
            .{ .src = "_ = 2", .code = C.Success },
        },
        &.{
            .{ .src = "_ = 1", .code = C.Success },
            .{ .src = "m := Map[[]int, int]{}\n_ = nope", .code = C.ErrorCompile },
            .{ .src = "m := Map[[]int, int]{}", .code = C.ErrorCompile },
            .{ .src = "_ = 3", .code = C.Success },
        },
    };
    for (seqs) |seq| {
        const vm = C.vm_initx(zt.alloc);
        defer C.vm_deinit(vm);
        for (seq) |step| {
            try zt.eq(step.code, C.vm_evalx(vm, "main", step.src, config, &res));
        }
    }
}

test "A carried template instance that does not compile is dropped without compiling the source again." {
    // The compile that dropped such an instance used to start over, so the module loader was called again for a
    // module that the first attempt had loaded. The instances are now checked before the source is resolved.
    const S = struct {
        var loads: u32 = 0;
        fn loader(vm_: *C.VM, mod: *C.Sym, uri: C.Bytes, res: [*c]C.LoaderResult) callconv(.c) bool {
            if (std.mem.eql(u8, C.from_bytes(uri), "mymod")) {
                loads += 1;
                res[0].src = C.to_bytes(
                    \\fn two() -> int:
                    \\    return 2
                );
                return true;
            }
            return C.default_loader(vm_, mod, uri, res);
        }
    };
    C.setSilent(true);
    defer C.setSilent(false);
    var res: C.EvalResult = undefined;
    for ([_]bool{ true, false }) |persist| {
        var config = C.defaultEvalConfig();
        config.persist_main = persist;
        const vm = C.vm_initx(zt.alloc);
        defer C.vm_deinit(vm);
        C.vm_set_loader(vm, @ptrCast(&S.loader));
        try zt.eq(C.Success, C.vm_evalx(vm, "main", "_ = 1", config, &res));
        // Two instances whose bodies do not compile, behind an error: two passes drop them.
        try zt.eq(C.ErrorCompile, C.vm_evalx(vm, "main",
            \\m := Map[[]int, int]{}
            \\n := Map[[]float, str]{}
            \\_ = nope
        , config, &res));
        S.loads = 0;
        try zt.eq(C.Success, C.vm_evalx(vm, "main",
            \\use test
            \\use mymod
            \\counts := Map[str, int]{a=1}
            \\test.eq(mymod.two() + counts['a'], 3)
        , config, &res));
        try zt.eq(1, S.loads);
        try zt.eq(C.ErrorCompile, C.vm_evalx(vm, "main", "m := Map[[]int, int]{}", config, &res));
        try zt.eq(C.Success, C.vm_evalx(vm, "main", "_ = 2", config, &res));
    }
}

test "An invalid escape sequence is a compile error that keeps the session." {
    // F-131. The escape error used to leave the compiler as a bare Zig error, which was taken for an allocation
    // failure: the next eval reset the VM and lost every local, function and `use` of the session.
    const vm = C.vm_initx(zt.alloc);
    defer C.vm_deinit(vm);
    C.setSilent(true);
    defer C.setSilent(false);

    var config = C.defaultEvalConfig();
    config.persist_main = true;
    var res: C.EvalResult = undefined;
    try zt.eq(false, C.vm_reset_pending(vm));
    try zt.eq(C.Success, C.vm_evalx(vm, "main",
        \\use test
        \\keep := 7
        \\fn helper() -> int:
        \\    return 11
    , config, &res));

    const bad = [_][]const u8{ "s := \"a\\|b\"", "s := 'a\\xZZb'", "s := 'a\\xb'", "var b byte = '\\q'" };
    for (bad) |src| {
        try zt.eq(C.ErrorCompile, C.vm_evalx(vm, "main", src, config, &res));
        const summary = C.vm_compile_error_summary(vm);
        defer C.vm_freeb(vm, summary);
        try zt.expect(std.mem.indexOf(u8, summary, "CompileError: Invalid escape sequence `\\") != null);
        try zt.expect(std.mem.indexOf(u8, summary, "main:1:") != null);
        try zt.eq(false, C.vm_reset_pending(vm));
        try zt.eq(C.ErrorCompile, C.vm_validate(vm, src));
        try zt.eq(false, C.vm_reset_pending(vm));
    }
    try zt.eq(C.Success, C.vm_evalx(vm, "main",
        \\test.eq(keep, 7)
        \\test.eq(helper(), 11)
        \\test.eq('a\0b'[1], 0)
    , config, &res));
}

test "cl_vm_reset_pending tells that the next eval starts from a reset VM." {
    const vm = C.vm_initx(zt.alloc);
    defer C.vm_deinit(vm);
    C.setSilent(true);
    defer C.setSilent(false);

    var config = C.defaultEvalConfig();
    config.persist_main = true;
    var res: C.EvalResult = undefined;
    // A failed first compile: nothing of it is kept.
    try zt.eq(C.ErrorCompile, C.vm_evalx(vm, "main", "print(nope)", config, &res));
    try zt.eq(true, C.vm_reset_pending(vm));
    try zt.eq(C.Success, C.vm_evalx(vm, "main", "a := 1", config, &res));
    try zt.eq(false, C.vm_reset_pending(vm));
    // A later compile error or panic keeps the session.
    try zt.eq(C.ErrorCompile, C.vm_evalx(vm, "main", "print(nope)", config, &res));
    try zt.eq(false, C.vm_reset_pending(vm));
    try zt.eq(C.Success, C.vm_evalx(vm, "main", "if a != 1: panic('a')", config, &res));
    // A panic drops the main locals of the session but not its declarations, and it is not a reset.
    try zt.eq(C.Success, C.vm_evalx(vm, "main", "fn two() -> int:\n    return 2", config, &res));
    try zt.eq(C.ErrorPanic, C.vm_evalx(vm, "main", "panic('x')", config, &res));
    try zt.eq(false, C.vm_reset_pending(vm));
    try zt.eq(C.Success, C.vm_evalx(vm, "main", "if two() != 2: panic('two')", config, &res));
    C.vm_reset(vm);
    try zt.eq(false, C.vm_reset_pending(vm));
}

test "persist_main: the capture error suggests the borrow for a function only." {
    // A top level `b := &x` can not be kept across evals, so the hint must not lead there.
    const vm = C.vm_initx(zt.alloc);
    defer C.vm_deinit(vm);
    C.setSilent(true);
    defer C.setSilent(false);

    var config = C.defaultEvalConfig();
    config.persist_main = true;
    var res: C.EvalResult = undefined;
    try zt.eq(C.Success, C.vm_evalx(vm, "main", "names := []str{'a', 'b'}\ncounts := Map[str, int]{a=1, b=2}", config, &res));
    try zt.eq(C.ErrorCompile, C.vm_evalx(vm, "main", "names.sort(|a, b| counts[a] > counts[b])", config, &res));
    {
        const summary = C.vm_compile_error_summary(vm);
        defer C.vm_freeb(vm, summary);
        try zt.expect(std.mem.indexOf(u8, summary, "Declare it with `^T`. Inside a function, you can also borrow it before the lambda (`b := &counts`)") != null);
    }
    // Inside a function the borrow works, and the hint says so.
    try zt.eq(C.ErrorCompile, C.vm_evalx(vm, "main",
        \\fn f():
        \\    m := Map[str, int]{a=1, b=2}
        \\    xs := []str{'a', 'b'}
        \\    xs.sort(|a, b| m[a] > m[b])
    , config, &res));
    {
        const summary = C.vm_compile_error_summary(vm);
        defer C.vm_freeb(vm, summary);
        try zt.expect(std.mem.indexOf(u8, summary, "Declare it with `^T`, or borrow it before the lambda (`b := &m`)") != null);
    }
    try zt.eq(C.Success, C.vm_evalx(vm, "main",
        \\rc := ^Map[str, int]{a=1, b=2}
        \\names.sort(|a, b| rc[a] > rc[b])
        \\if names[0] != 'b': panic('sort')
    , config, &res));
}

test "persist_main: an in-place Slice resize on the last line has no result, and a new-list method shows the list." {
    // Before 0.4.15 the resize methods returned the new list, and `out.remove(1)` on the last line was an error.
    const vm = C.vm_initx(zt.alloc);
    defer C.vm_deinit(vm);
    C.setSilent(true);
    defer C.setSilent(false);

    var config = C.defaultEvalConfig();
    config.persist_main = true;
    var res: C.EvalResult = undefined;
    try zt.eq(C.Success, C.vm_evalx(vm, "main", "out := []int{1, 2, 3}\nout.remove(1)", config, &res));
    try zt.eq(true, res.res_t == @as(C.TypeId, @intCast(C.TypeVoid)));
    try zt.eq(C.Success, C.vm_evalx(vm, "main", "out.len()", config, &res));
    try zt.eq(2, @as(*i64, @ptrCast(res.res)).*);
    try zt.eq(C.Success, C.vm_evalx(vm, "main", "out.append(4)", config, &res));
    try zt.eq(true, res.res_t == @as(C.TypeId, @intCast(C.TypeVoid)));
    try zt.eq(C.Success, C.vm_evalx(vm, "main", "out.removed(0)", config, &res));
    try zt.eq(false, res.res_t == @as(C.TypeId, @intCast(C.TypeVoid)));
    try zt.eq(C.Success, C.vm_evalx(vm, "main", "out.len()", config, &res));
    try zt.eq(3, @as(*i64, @ptrCast(res.res)).*);
    try zt.eq(C.ErrorCompile, C.vm_evalx(vm, "main", "out = out.remove(1)", config, &res));
    {
        const summary = C.vm_compile_error_summary(vm);
        defer C.vm_freeb(vm, summary);
        try zt.expect(std.mem.indexOf(u8, summary, "`remove` changes `out` in place and returns nothing.") != null);
    }
}

test "A host resolver gates the `use` of the script, and the compiler's own builtin lookups skip it." {
    // The resolver gets the importing module (`curUri`) with each `use`. An allow list for the script holds even
    // for `meta`, which `core` loaded first, while `math` still imports `c` and `meta` itself. With `math`, the
    // compiler looks up `c` for `@initBindLib`; that lookup must not reach the resolver as `main` importing `c`.
    const S = struct {
        fn resolver(vm_: ?*C.VM, params: C.ResolverParams, res_uri_len: [*c]usize) callconv(.c) bool {
            const cur = C.from_bytes(params.curUri);
            const uri = C.from_bytes(params.uri);
            if (std.mem.eql(u8, cur, "main")) {
                const allowed = std.mem.eql(u8, uri, "core") or std.mem.eql(u8, uri, "math");
                if (!allowed) return false;
            }
            return C.default_resolver(vm_, params, res_uri_len);
        }
    };
    const vm = C.vm_initx(zt.alloc);
    defer C.vm_deinit(vm);
    C.vm_set_resolver(vm, S.resolver);
    C.setSilent(true);
    defer C.setSilent(false);

    var config = C.defaultEvalConfig();
    config.persist_main = true;
    var res: C.EvalResult = undefined;
    try zt.eq(C.Success, C.vm_evalx(vm, "main", "use math\nx := math.sqrt(16.0)", config, &res));
    for ([_][]const u8{ "c", "meta", "cy", "io" }) |name| {
        var buf: [64]u8 = undefined;
        const src = try std.fmt.bufPrint(&buf, "use {s}\n_ = 1", .{name});
        try zt.eq(C.ErrorCompile, C.vm_evalx(vm, "main", src, config, &res));
        const summary = C.vm_compile_error_summary(vm);
        defer C.vm_freeb(vm, summary);
        const exp = try std.fmt.bufPrint(&buf, "Failed to resolve module `{s}`.", .{name});
        try zt.expect(std.mem.indexOf(u8, summary, exp) != null);
    }
    // The session goes on after a refused `use`.
    try zt.eq(C.Success, C.vm_evalx(vm, "main", "x", config, &res));
    try zt.eq(4.0, @as(*f64, @ptrCast(@alignCast(res.res))).*);
}

test "An `#[extern]` function without the `c` module is a compile error, not a crash." {
    // The program init looked up `c` for `@initBindLib` and unwrapped a null when the script had no `use c`.
    const vm = C.vm_initx(zt.alloc);
    defer C.vm_deinit(vm);
    C.setSilent(true);
    defer C.setSilent(false);

    var config = C.defaultEvalConfig();
    config.persist_main = true;
    var res: C.EvalResult = undefined;
    for ([_][]const u8{
        "#[extern='abs']\nfn c_abs(a int) -> int\nprint(c_abs(-3))",
        "#[extern='getpid']\nfn pid() -> int\nprint(pid())",
    }) |src| {
        try zt.eq(C.ErrorCompile, C.vm_validate(vm, src));
        try zt.eq(C.ErrorCompile, C.vm_evalx(vm, "main", src, config, &res));
        const summary = C.vm_compile_error_summary(vm);
        defer C.vm_freeb(vm, summary);
        try zt.expect(std.mem.indexOf(u8, summary, "An `#[extern]` function needs the `c` module. Add `use c`.") != null);
    }
    // The session goes on.
    try zt.eq(C.Success, C.vm_evalx(vm, "main", "x := 1", config, &res));
}

test "A body of a template instance that failed does not break the next compile." {
    // tars-agent, cyber 0.4.17: `[]Array[int]` failed in a body of `PtrSpan[Array[int]]` (a slice copies its
    // elements). `Slice[Array[int]]` itself did not fail and its unchecked bodies were carried to the next
    // compile, which generated a call into the body that was never checked: SIGSEGV in `cl_vm_validate`.
    // `[]Array[int]` is now refused as a type, so the same is shown with templates of the session.
    C.setSilent(true);
    defer C.setSilent(false);
    var res: C.EvalResult = undefined;
    var config = C.defaultEvalConfig();
    config.persist_main = true;
    const decls =
        \\use test
        \\type Box[T Any]:
        \\    v T
        \\fn (&Box[]) dup() -> T:
        \\    return self.v
        \\fn (&Box[]) size() -> int:
        \\    return 1
        \\type Wrap[T Any]:
        \\    b Box[T]
        \\fn (&Wrap[]) get() -> T:
        \\    return self.b.dup()
        \\fn (&Wrap[]) get2() -> T:
        \\    return self.get()
    ;
    const bad = [_][]const u8{
        "w := Wrap[Array[int]]{b=Box[Array[int]]{v=Array[int]{1}}}\n_ = w.get2()",
        "fn f():\n  w := Wrap[Array[int]]{b=Box[Array[int]]{v=Array[int]{1}}}\n  _ = w.get2()\nf()",
    };
    for (bad) |src| {
        for ([_]bool{ true, false }) |validate| {
            errdefer std.debug.print("source: {s}\nvalidate: {}\n", .{ src, validate });
            const vm = C.vm_initx(zt.alloc);
            defer C.vm_deinit(vm);
            errdefer {
                const summary = C.vm_compile_error_summary(vm);
                defer C.vm_freeb(vm, summary);
                std.debug.print("summary: {s}\n", .{summary});
            }
            try zt.eq(C.Success, C.vm_evalx(vm, "repl", decls, config, &res));
            // Three times: the later ones call the body that failed and get its error again.
            for (0..3) |_| {
                if (validate) {
                    try zt.eq(C.ErrorCompile, C.vm_validate(vm, src));
                } else {
                    try zt.eq(C.ErrorCompile, C.vm_evalx(vm, "repl", src, config, &res));
                }
                const summary = C.vm_compile_error_summary(vm);
                defer C.vm_freeb(vm, summary);
                try zt.expect(std.mem.indexOf(u8, summary, "Cannot copy `Array[int]`") != null);
                try zt.expect(std.mem.indexOf(u8, summary, "return self.v") != null);
                // A source that does not call the body is not blamed for it.
                try zt.eq(C.Success, C.vm_validate(vm, "print(1)"));
                try zt.eq(C.Success, C.vm_evalx(vm, "repl", "test.eq(1, 1)", config, &res));
            }
            // Only that body failed. The instances are still good.
            try zt.eq(C.Success, C.vm_evalx(vm, "repl", "bx := Box[Array[int]]{v=Array[int]{1}}\ntest.eq(1, bx.size())", config, &res));
            try zt.eq(C.ErrorCompile, C.vm_evalx(vm, "repl", "_ = bx.dup()", config, &res));
            try zt.eq(C.Success, C.vm_evalx(vm, "repl", "test.eq(1, bx.size())\nbi := Box[int]{v=3}\ntest.eq(3, bi.dup())", config, &res));
        }
    }
}

test "A function value of a body that failed does not break the next compile." {
    // `f := bad[bool]` failed in the body of `bad[bool]`. A second `g := bad[bool]` made a function value of
    // the body without IR, and the host panicked in the relocation of `bc_gen` (`genSymMap.get(...).?`).
    C.setSilent(true);
    defer C.setSilent(false);
    var res: C.EvalResult = undefined;
    var config = C.defaultEvalConfig();
    config.persist_main = true;
    const decls =
        \\use test
        \\fn bad[T Any](x T) -> int:
        \\    return x + 1
        \\fn mk[T Any](x T) -> int:
        \\    return x + 1
    ;
    // A function value or a call first, then the other way.
    const first = [_][]const u8{
        "f := bad[bool]",
        "fn h():\n  f := bad[bool]\n  _ = f(true)\nh()",
        "_ = bad[bool](true)",
        "fn h():\n  _ = bad[bool](true)\nh()",
    };
    for (first) |src| {
        for ([_]bool{ true, false }) |validate| {
            errdefer std.debug.print("source: {s}\nvalidate: {}\n", .{ src, validate });
            const vm = C.vm_initx(zt.alloc);
            defer C.vm_deinit(vm);
            errdefer {
                const summary = C.vm_compile_error_summary(vm);
                defer C.vm_freeb(vm, summary);
                std.debug.print("summary: {s}\n", .{summary});
            }
            try zt.eq(C.Success, C.vm_evalx(vm, "repl", decls, config, &res));
            const nexts = [_][]const u8{ src, "g := bad[bool]", "_ = bad[bool](false)", "fn h2():\n  g := bad[bool]\nh2()", src };
            for (nexts) |next| {
                errdefer std.debug.print("next: {s}\n", .{next});
                if (validate) {
                    try zt.eq(C.ErrorCompile, C.vm_validate(vm, next));
                } else {
                    try zt.eq(C.ErrorCompile, C.vm_evalx(vm, "repl", next, config, &res));
                }
                const summary = C.vm_compile_error_summary(vm);
                defer C.vm_freeb(vm, summary);
                try zt.expect(std.mem.indexOf(u8, summary, "return x + 1") != null);
                try zt.eq(C.Success, C.vm_validate(vm, "print(1)"));
            }
            // Other instances are good.
            try zt.eq(C.Success, C.vm_evalx(vm, "repl", "fi := bad[int]\ntest.eq(3, fi(2))\ntest.eq(4, mk[int](3))", config, &res));
        }
    }
    // A method of a type instance whose body failed, while the instance is good (`sema_func_sym`).
    const box_decls =
        \\use test
        \\type Box[T Any]:
        \\    v T
        \\fn (&Box[]) dup() -> T:
        \\    return self.v
        \\fn (&Box[]) size() -> int:
        \\    return 1
    ;
    const box_first = [_][]const u8{
        "bx := Box[Array[int]]{v=Array[int]{1}}\n_ = bx.dup()",
        "f := Box[Array[int]].dup",
    };
    for (box_first) |src| {
        for ([_]bool{ true, false }) |validate| {
            errdefer std.debug.print("source: {s}\nvalidate: {}\n", .{ src, validate });
            const vm = C.vm_initx(zt.alloc);
            defer C.vm_deinit(vm);
            errdefer {
                const summary = C.vm_compile_error_summary(vm);
                defer C.vm_freeb(vm, summary);
                std.debug.print("summary: {s}\n", .{summary});
            }
            try zt.eq(C.Success, C.vm_evalx(vm, "repl", box_decls, config, &res));
            const nexts = [_][]const u8{ src, "g := Box[Array[int]].dup", "fn h():\n  g := Box[Array[int]].dup\nh()", src };
            for (nexts) |next| {
                errdefer std.debug.print("next: {s}\n", .{next});
                if (validate) {
                    try zt.eq(C.ErrorCompile, C.vm_validate(vm, next));
                } else {
                    try zt.eq(C.ErrorCompile, C.vm_evalx(vm, "repl", next, config, &res));
                }
                const summary = C.vm_compile_error_summary(vm);
                defer C.vm_freeb(vm, summary);
                try zt.expect(std.mem.indexOf(u8, summary, "return self.v") != null);
                try zt.eq(C.Success, C.vm_validate(vm, "print(1)"));
            }
            try zt.eq(C.Success, C.vm_evalx(vm, "repl", "sz := Box[Array[int]].size\nbi := Box[int]{v=3}\ntest.eq(3, bi.dup())", config, &res));
        }
    }
}

test "A slice of a NoCopy element type is refused and does not break the next compile." {
    C.setSilent(true);
    defer C.setSilent(false);
    var res: C.EvalResult = undefined;
    var config = C.defaultEvalConfig();
    config.persist_main = true;
    const bad = [_][]const u8{
        "xs := []Array[int]{}",
        "xs := []Array[int]{Array[int]{7}}",
        "a := Array[int]{7}\nxs := []Array[int]{move a}",
        "fn f():\n  a := []Array[int]{Array[int]{7}}\n  x := a[0]\n  _ = x.len()\nf()",
        "type W:\n  xs []Array[int]",
    };
    for (bad) |src| {
        for ([_]bool{ true, false }) |validate| {
            errdefer std.debug.print("source: {s}\nvalidate: {}\n", .{ src, validate });
            const vm = C.vm_initx(zt.alloc);
            defer C.vm_deinit(vm);
            errdefer {
                const summary = C.vm_compile_error_summary(vm);
                defer C.vm_freeb(vm, summary);
                std.debug.print("summary: {s}\n", .{summary});
            }
            try zt.eq(C.Success, C.vm_evalx(vm, "repl", "use test\nx := 5", config, &res));
            for (0..2) |_| {
                if (validate) {
                    try zt.eq(C.ErrorCompile, C.vm_validate(vm, src));
                } else {
                    try zt.eq(C.ErrorCompile, C.vm_evalx(vm, "repl", src, config, &res));
                }
                const summary = C.vm_compile_error_summary(vm);
                defer C.vm_freeb(vm, summary);
                try zt.expect(std.mem.indexOf(u8, summary, "A slice `[]Array[int]` copies its elements") != null);
                try zt.eq(C.Success, C.vm_validate(vm, "print(1)"));
            }
            try zt.eq(C.Success, C.vm_evalx(vm, "repl", "test.eq(5, x)\nys := []int{1, 2}\ntest.eq(2, ys.len())", config, &res));
            try zt.eq(C.Success, C.vm_evalx(vm, "repl", "zs := Array[Array[int]]{}\nzs.append(Array[int]{7})\ntest.eq(1, zs.len())", config, &res));
        }
    }
}
