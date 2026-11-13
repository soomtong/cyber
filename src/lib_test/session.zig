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
