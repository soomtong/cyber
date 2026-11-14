const std = @import("std");
const builtin = @import("builtin");
const build_config = @import("build_config");
const stdx = @import("stdx");
const cy = @import("../cyber.zig");
const C = @import("../capi.zig");
const meta_mod = @import("../builtins/meta.zig");
const zt = stdx.testing;
const bt = cy.types.BuiltinTypes;

test "cl_vm_validate()" {
    const vm = C.vm_init();
    defer C.vm_deinit(vm);

    C.setSilent(true);
    defer C.setSilent(false);

    var res = C.vm_validate(vm, "_ = 1 + 2");
    try zt.eq(res, C.Success);

    res = C.vm_validate(vm, "_ = 1 +");
    try zt.eq(res, C.ErrorCompile);
}

test "cl_find_type()" {
    const vm = C.vm_init();
    defer C.vm_deinit(vm);

    // Before types are loaded.
    try zt.eq(C.vm_find_type(vm, "int"), null);

    // Load builtin type.
    _ = C.vm_compile(vm, "main", "", C.defaultCompileConfig());
    const act: *cy.Type = @ptrCast(@alignCast(C.vm_find_type(vm, "int")));
    try zt.eq(act.id(), C.TypeI64);

    // Load type declared from main.
    _ = C.vm_compile(vm, "main",
        \\type Foo:
        \\    a int
    , C.defaultCompileConfig());
    try zt.expect(C.vm_find_type(vm, "Foo") != null);
}

test "cl_symbol()" {
    const vm = C.vm_init();
    defer C.vm_deinit(vm);

    const val = C.symbol(vm, "foo");
    try zt.eq(val + 1, C.symbol(vm, "foo2"));
    try zt.eq(val, C.symbol(vm, "foo"));
}

test "Constants." {
    try zt.eq(C.TypeVoid, bt.Void);
    try zt.eq(C.TypeBool, bt.Bool);
    try zt.eq(C.TypeError, bt.Error);
    try zt.eq(C.TypeSymbol, bt.Symbol);
    try zt.eq(C.TypeI64, bt.I64);
    try zt.eq(C.TypeF64, bt.F64);
    try zt.eq(C.TypeStr, bt.Str);
    try zt.eq(C.TypeType, bt.Type);
    try zt.eq(C.TypeFuncSig, bt.FuncSig);
    try zt.eq(C.TypeCode, bt.Code);
}

test "cl_full_version()" {
    const str = C.full_version();
    try zt.eqStr(str, build_config.full_version);
}

test "cl_version()" {
    const str = C.version();
    try zt.eqStr(str, build_config.version);
}

test "cl_build()" {
    const str = C.build();
    try zt.eqStr(str, build_config.build);
}

test "cl_commit()" {
    const str = C.commit();
    try zt.eqStr(str, build_config.commit);
}

test "value_desc renders values from the type layout." {
    // Leak-checking allocator: each result (including choice payloads) is released before the next eval.
    const vm = C.vm_initx(zt.alloc);
    defer C.vm_deinit(vm);

    var config = C.defaultEvalConfig();
    config.persist_main = true;
    const S = struct {
        fn expect(vm_: *C.VM, config_: C.EvalConfig, src: []const u8, exp: []const u8) !void {
            var res: C.EvalResult = undefined;
            try zt.eq(C.Success, C.vm_evalx(vm_, "repl", src, config_, &res));
            const desc = C.value_desc(vm_, res.res_t, res.res);
            defer C.vm_freeb(vm_, desc);
            try zt.eqStr(exp, desc);
        }
    };
    try S.expect(vm, config, "?int(none)", "`?int` none");
    try S.expect(vm, config, "?int(3)", "`?int` 3");
    try S.expect(vm, config, "?str('abc')", "`?str` 'abc'");
    try S.expect(vm, config,
        \\type P:
        \\  a int
        \\  b str
        \\P{a=1, b='x'}
    , "`P` {a=1, b='x'}");
    try S.expect(vm, config, "^P{a=3, b='z'}", "`^P` ^{a=3, b='z'}");
    try S.expect(vm, config, "[]int{1, 2, 3}", "`[]int` {1, 2, 3}");
    try S.expect(vm, config, "[]str{'a', 'b'}", "`[]str` {'a', 'b'}");
    try S.expect(vm, config, "[3]int{4, 5, 6}", "`[3]int` {4, 5, 6}");
    try S.expect(vm, config, "[&]int{7, 8}", "`[&]int` {7, 8}");
    try S.expect(vm, config,
        \\x := P{a=2, b='y'}
        \\&x
    , "`&P` &{a=2, b='y'}");
    try S.expect(vm, config, "[]int{1,2,3,4,5,6,7,8,9,10,11,12}", "`[]int` {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, ...2 more}");
    try S.expect(vm, config,
        \\m := Map[str, int]{}
        \\m['a'] = 1
        \\m
    , "`Map[str, int]` {'a': 1}");
    try S.expect(vm, config, "Map[int, str]{}", "`Map[int, str]` {}");
    try S.expect(vm, config,
        \\type Color enum:
        \\  case red
        \\  case blue
        \\Color.blue
    , "`Color` .blue");
    try S.expect(vm, config,
        \\type Shape enum:
        \\  case dot
        \\  case circle int
        \\  case label str
        \\Shape.circle(5)
    , "`Shape` .circle(5)");
    try S.expect(vm, config, "Shape.dot", "`Shape` .dot");
    try S.expect(vm, config, "Shape.label('hi')", "`Shape` .label('hi')");
    try S.expect(vm, config, "[]Shape{Shape.dot, Shape.circle(2)}", "`[]Shape` {.dot, .circle(2)}");
    try S.expect(vm, config,
        \\type Q:
        \\  inner P
        \\  opt ?int
        \\Q{inner=P{a=1, b='q'}, opt=none}
    , "`Q` {inner={a=1, b='q'}, opt=none}");
    // Nesting stops at the depth limit, so a cyclic reference stays short.
    try S.expect(vm, config,
        \\type Node:
        \\  next ?^Node
        \\  v int
        \\n := ^Node{next=none, v=1}
        \\n.next = n
        \\n
    , "`^Node` ^{next=^{next=..., v=...}, v=1}");
    try S.expect(vm, config, "1.5", "`float` 1.5");
    try S.expect(vm, config, "true", "`bool` true");
    try S.expect(vm, config, "error.Oops", "`error` error.Oops");
}

test "cl_slice_init." {
    const vm = C.vm_init();
    defer C.vm_deinit(vm);

    const S = struct {
        fn mod_test(t_: *C.Thread) callconv(.c) C.Ret {
            const ret: *C.Slice = C.thread_ret(t_, C.Slice);
            ret.* = C.slice_init(t_, 2, 8);
            var elems: [*]i64 = @ptrCast(@alignCast(ret.ptr));
            elems[0] = 123;
            elems[1] = 234;
            return C.RetOk;
        }
        fn loader(vm_: *C.VM, mod: *C.Sym, uri: C.Bytes, res: [*c]C.LoaderResult) callconv(.c) bool {
            const name = C.from_bytes(uri);
            if (std.mem.eql(u8, name, "mod")) {
                C.mod_add_func(mod, "test", C.BIND_FUNC(&mod_test));
                res[0].src = C.to_bytes("#[bind] fn test() -> []int");
                return true;
            } else {
                return C.default_loader(vm_, mod, uri, res);
            }
        }
    };
    C.vm_set_loader(vm, @ptrCast(&S.loader));

    var res: C.EvalResult = undefined;
    const code = C.vm_eval(vm, 
        \\use mod
        \\use test
        \\slice := mod.test()
        \\test.eq(2, slice.len())
        \\test.eq(123, slice[0])
        \\test.eq(234, slice[1])
    , &res);
    try zt.eq(C.Success, code);
}

test "Bind functions." {
    const vm = C.vm_init();
    defer C.vm_deinit(vm);

    const S = struct {
        fn mod_test(t_: *C.Thread) callconv(.c) C.Ret {
            const ret: *i64 = C.thread_ret(t_, i64);
            const a = C.thread_int(t_);
            ret.* = a + 1;
            return C.RetOk;
        }
        fn loader(vm_: *C.VM, mod: *C.Sym, uri: C.Bytes, res: [*c]C.LoaderResult) callconv(.c) bool {
            const name = C.from_bytes(uri);
            if (std.mem.eql(u8, name, "mod")) {
                C.mod_add_func(mod, "test", C.BIND_FUNC(&mod_test));
                res[0].src = C.to_bytes("#[bind] fn test(a int) -> int");
                return true;
            } else {
                return C.default_loader(vm_, mod, uri, res);
            }
        }
    };
    C.vm_set_loader(vm, @ptrCast(&S.loader));

    var res: C.EvalResult = undefined;
    _ = C.vm_eval(vm, 
        \\use mod
        \\use test
        \\test.eq(123, mod.test(122))
    , &res);
}

test "A host function can read its parameters before it takes the return slot." {
    // `cl_thread_str` before `cl_thread_ret` used to read from a null pointer.
    const vm = C.vm_init();
    defer C.vm_deinit(vm);

    const S = struct {
        fn mod_test(t_: *C.Thread) callconv(.c) C.Ret {
            const a = C.thread_int(t_);
            var s = C.thread_str(t_);
            const b = C.thread_int(t_);
            const len: i64 = @intCast(C.str_bytes(s).len);
            C.str_deinit(t_, &s);
            const ret: *i64 = C.thread_ret(t_, i64);
            ret.* = a * 100 + len * 10 + b;
            return C.RetOk;
        }
        fn loader(vm_: *C.VM, mod: *C.Sym, uri: C.Bytes, res: [*c]C.LoaderResult) callconv(.c) bool {
            const name = C.from_bytes(uri);
            if (std.mem.eql(u8, name, "mod")) {
                C.mod_add_func(mod, "test", C.BIND_FUNC(&mod_test));
                res[0].src = C.to_bytes("#[bind] fn test(a int, s str, b int) -> int");
                return true;
            } else {
                return C.default_loader(vm_, mod, uri, res);
            }
        }
    };
    C.vm_set_loader(vm, @ptrCast(&S.loader));

    var res: C.EvalResult = undefined;
    try zt.eq(C.Success, C.vm_eval(vm,
        \\use mod
        \\use test
        \\test.eq(mod.test(1, 'abc', 2), 132)
        \\fn call(n int) -> int:
        \\    return mod.test(n, 'ab', n)
        \\test.eq(call(3), 323)
    , &res));
}

test "A host function called through a function value reads its parameters first." {
    // Only the direct call set `fp_end` before a host call. A function pointer, a function union, a call from a
    // builtin method (`sort`) and a trait call left the `fp_end` of an earlier call, so reading a parameter before
    // `cl_thread_ret` read another value without an error.
    const vm = C.vm_init();
    defer C.vm_deinit(vm);

    const S = struct {
        fn first(t_: *C.Thread) callconv(.c) C.Ret {
            var s = C.thread_str(t_);
            const len: i64 = @intCast(C.str_bytes(s).len);
            C.str_deinit(t_, &s);
            C.thread_ret(t_, i64).* = len;
            return C.RetOk;
        }
        fn less(t_: *C.Thread) callconv(.c) C.Ret {
            var a = C.thread_str(t_);
            defer C.str_deinit(t_, &a);
            var b = C.thread_str(t_);
            defer C.str_deinit(t_, &b);
            const res = std.mem.order(u8, C.str_bytes(a), C.str_bytes(b)) == .lt;
            C.thread_ret(t_, bool).* = res;
            return C.RetOk;
        }
        fn measure(t_: *C.Thread) callconv(.c) C.Ret {
            const box = C.thread_param(t_, *const i64);
            const k = C.thread_int(t_);
            C.thread_ret(t_, i64).* = box.* * 10 + k;
            return C.RetOk;
        }
        fn loader(vm_: *C.VM, mod: *C.Sym, uri: C.Bytes, res: [*c]C.LoaderResult) callconv(.c) bool {
            const name = C.from_bytes(uri);
            if (std.mem.eql(u8, name, "mod")) {
                C.mod_add_func(mod, "first", C.BIND_FUNC(&first));
                C.mod_add_func(mod, "less", C.BIND_FUNC(&less));
                C.mod_add_func(mod, "Box.measure", C.BIND_FUNC(&measure));
                res[0].src = C.to_bytes(
                    \\#[bind] fn first(s str) -> int
                    \\#[bind] fn less(a str, b str) -> bool
                    \\type Measure trait:
                    \\    fn measure(k int) -> int
                    \\type Box:
                    \\    with Measure
                    \\    n int
                    \\#[bind] fn (&Box) measure(k int) -> int
                );
                return true;
            } else {
                return C.default_loader(vm_, mod, uri, res);
            }
        }
    };
    C.vm_set_loader(vm, @ptrCast(&S.loader));

    var res: C.EvalResult = undefined;
    try zt.eq(C.Success, C.vm_eval(vm,
        \\use mod
        \\use test
        \\type F = fn(str) -> int
        \\test.eq(mod.first('hello'), 5)
        \\var f F = mod.first
        \\test.eq(f('hello'), 5)
        \\var g Func[F] = mod.first
        \\test.eq(g('hello'), 5)
        \\xs := {'b', 'c', 'a'}
        \\xs.sort(mod.less)
        \\test.eq_slice({'a', 'b', 'c'}, xs)
        \\var m ^Dyn[mod.Measure] = ^mod.Box{n=4}
        \\test.eq(m.measure(2), 42)
    , &res));
}

test "Host functions release their owned str params." {
    // Leak-checking allocator: a host function that skips `str_deinit` leaks the heap string.
    // The strings are longer than 32 bytes so they are big objects allocated outside the heap pages.
    const vm = C.vm_initx(zt.alloc);
    defer C.vm_deinit(vm);

    const S = struct {
        fn mod_len(t_: *C.Thread) callconv(.c) C.Ret {
            const ret: *i64 = C.thread_ret(t_, i64);
            var s = C.thread_str(t_);
            defer C.str_deinit(t_, &s);
            ret.* = @intCast(C.str_bytes(s).len);
            return C.RetOk;
        }
        fn loader(vm_: *C.VM, mod: *C.Sym, uri: C.Bytes, res: [*c]C.LoaderResult) callconv(.c) bool {
            const name = C.from_bytes(uri);
            if (std.mem.eql(u8, name, "mod")) {
                C.mod_add_func(mod, "len", C.BIND_FUNC(&mod_len));
                res[0].src = C.to_bytes("#[bind] fn len(s str) -> int");
                return true;
            } else {
                return C.default_loader(vm_, mod, uri, res);
            }
        }
    };
    C.vm_set_loader(vm, @ptrCast(&S.loader));

    var res: C.EvalResult = undefined;
    try zt.eq(C.Success, C.vm_eval(vm,
        \\use mod
        \\use test
        \\s := 'abcdefghijklmnopqrstuvwxyz' + '0123456789'
        \\test.eq(36, mod.len(s))
        \\test.eq(36, mod.len('abcdefghijklmnopqrstuvwxyz' + '9876543210'))
    , &res));
}

test "Host functions release their owned slice params." {
    // Leak-checking allocator: a host function that skips `slice_deinit` leaks the buffer
    // and, for `[]str`, the heap strings in it.
    const vm = C.vm_initx(zt.alloc);
    defer C.vm_deinit(vm);

    const S = struct {
        fn mod_sum(t_: *C.Thread) callconv(.c) C.Ret {
            const ret: *i64 = C.thread_ret(t_, i64);
            var s = C.thread_slice(t_);
            defer C.slice_deinit(t_, null, &s);
            const elems: [*]i64 = @ptrCast(@alignCast(s.ptr));
            var sum: i64 = 0;
            for (elems[0..@intCast(s.len)]) |e| sum += e;
            ret.* = sum;
            return C.RetOk;
        }
        fn mod_total_len(t_: *C.Thread) callconv(.c) C.Ret {
            const ret: *i64 = C.thread_ret(t_, i64);
            var s = C.thread_slice(t_);
            const str_t = C.vm_find_type(C.thread_vm(t_), "str");
            defer C.slice_deinit(t_, str_t, &s);
            const elems: [*]C.str = @ptrCast(@alignCast(s.ptr));
            var total: i64 = 0;
            for (elems[0..@intCast(s.len)]) |e| total += @intCast(C.str_bytes(e).len);
            ret.* = total;
            return C.RetOk;
        }
        fn loader(vm_: *C.VM, mod: *C.Sym, uri: C.Bytes, res: [*c]C.LoaderResult) callconv(.c) bool {
            const name = C.from_bytes(uri);
            if (std.mem.eql(u8, name, "mod")) {
                C.mod_add_func(mod, "sum", C.BIND_FUNC(&mod_sum));
                C.mod_add_func(mod, "total_len", C.BIND_FUNC(&mod_total_len));
                res[0].src = C.to_bytes(
                    \\#[bind] fn sum(s []int) -> int
                    \\#[bind] fn total_len(s []str) -> int
                );
                return true;
            } else {
                return C.default_loader(vm_, mod, uri, res);
            }
        }
    };
    C.vm_set_loader(vm, @ptrCast(&S.loader));

    var res: C.EvalResult = undefined;
    try zt.eq(C.Success, C.vm_eval(vm,
        \\use mod
        \\use test
        \\nums := []int{1, 2, 3}
        \\test.eq(6, mod.sum(nums))
        \\test.eq(6, nums.len() + 3)
        \\test.eq(10, mod.sum([]int{4, 6}))
        \\a := 'abcdefghijklmnopqrstuvwxyz' + '0123456789'
        \\strs := []str{a, a + '!'}
        \\test.eq(73, mod.total_len(strs))
        \\test.eq(73, mod.total_len([]str{a, a + '?'}))
        \\test.eq(36, strs[0].len())
    , &res));
}

test "Bind global persists across multiple evals." {
    const vm = C.vm_init();
    defer C.vm_deinit(vm);

    var global: i64 = 0;
    C.vm_set_user_data(vm, &global);
    C.vm_set_loader(vm, struct {
        fn loader(vm_: ?*C.VM, mod: ?*C.Sym, spec: C.Bytes, res: [*c]C.LoaderResult) callconv(.c) bool {
            if (std.mem.eql(u8, C.from_bytes(spec), "mod")) {
                const ptr = C.vm_user_data(vm_);
                C.mod_add_global(mod.?, "g", C.BIND_GLOBAL(ptr));
                res[0].src = C.to_bytes("#[bind] global g int");
                return true;
            } else {
                return C.default_loader(vm_, mod, spec, res);
            }
        }
    }.loader);

    try zt.eq(0, global);
    var eval_res: C.EvalResult = undefined;
    _ = C.vm_eval(vm, 
        \\use m 'mod'
        \\m.g = 1
    , &eval_res);
    try zt.eq(1, global);
    _ = C.vm_eval(vm, 
        \\use m 'mod'
        \\m.g = m.g + 1
    , &eval_res);
    try zt.eq(2, global);
}

const Endian = enum {
    little,
    big,
};

test "meta constants" {
    const vm = C.vm_init();
    defer C.vm_deinit(vm);

    var eval_res: C.EvalResult = undefined;
    var res = C.vm_eval(vm, 
        \\use meta
        \\fn main() -> SystemKind:
        \\  return meta.system()
    , &eval_res);
    try zt.eq(C.Success, res);
    const exp_system = @field(meta_mod.SystemKind, @tagName(builtin.target.os.tag));
    try zt.eq(@backingInt(exp_system), @as(*i64, @ptrCast(eval_res.res)).*);

    res = C.vm_eval(vm, 
        \\use meta
        \\fn main() -> str:
        \\  return meta.cpu()
    , &eval_res);
    try zt.eq(C.Success, res);
    const exp_cpu = @tagName(builtin.target.cpu.arch);
    try zt.eqStr(exp_cpu, C.str_bytes(@as(*C.str, @ptrCast(eval_res.res)).*));

    res = C.vm_eval(vm, 
        \\use meta
        \\fn main() -> Endian:
        \\  return meta.endian()
    , &eval_res);
    try zt.eq(C.Success, res);
    const exp_endian = @field(Endian, @tagName(builtin.target.cpu.arch.endian()));
    try zt.eq(@backingInt(exp_endian), @as(*i64, @ptrCast(eval_res.res)).*);
}

fn refAllDeclsRecursive(comptime T: type) void {
    if (!builtin.is_test) return;
    @setEvalBranchQuota(1_000_000);
    inline for (comptime std.meta.declarations(T)) |decl_name| {
        // Translated C headers hold expressions that do not translate, so they are not walked.
        if (comptime std.mem.eql(u8, decl_name, "vmc") or std.mem.eql(u8, decl_name, "c")) continue;
        const D = @field(T, decl_name);
        if (@TypeOf(D) == type) {
            switch (@typeInfo(D)) {
                // Walk a container declared here. An alias to a type declared elsewhere (`pub const W = std.Io.Writer`)
                // has a different type name, and walking std internals is not the point of this test.
                .@"struct", .@"enum", .@"union", .@"opaque" => if (comptime declaresType(decl_name, @typeName(D))) refAllDeclsRecursive(D),
                else => {},
            }
        }
        _ = &@field(T, decl_name);
    }
}

fn declaresType(decl_name: []const u8, type_name: []const u8) bool {
    @setEvalBranchQuota(1_000_000);
    if (std.mem.eql(u8, decl_name, type_name)) return true;
    return std.mem.endsWith(u8, type_name, decl_name) and type_name[type_name.len - decl_name.len - 1] == '.';
}

test "print and eprint callbacks receive the running thread." {
    // The header declares `CLPrintFn(CLThread* t, CLBytes str)`. The builtins used to pass the VM pointer
    // instead, so `cl_thread_vm(t)` in a host callback read garbage (F-50).
    const vm = C.vm_init();
    defer C.vm_deinit(vm);

    const S = struct {
        var expected: ?*C.Thread = null;
        var expected_vm: ?*C.VM = null;
        var print_calls: u32 = 0;
        var eprint_calls: u32 = 0;
        var print_ok = true;
        var eprint_ok = true;

        fn check(t_: ?*C.Thread) bool {
            if (t_ != expected) return false;
            return C.thread_vm(t_.?) == expected_vm.?;
        }
        fn printer(t_: ?*C.Thread, _: C.Bytes) callconv(.c) void {
            print_calls += 1;
            print_ok = print_ok and check(t_);
        }
        fn eprinter(t_: ?*C.Thread, _: C.Bytes) callconv(.c) void {
            eprint_calls += 1;
            eprint_ok = eprint_ok and check(t_);
        }
    };
    S.expected = C.vm_main_thread(vm);
    S.expected_vm = vm;
    C.vm_set_printer(vm, &S.printer);
    C.vm_set_eprinter(vm, &S.eprinter);

    var res: C.EvalResult = undefined;
    try zt.eq(C.Success, C.vm_eval(vm,
        \\print('a')
        \\prints('b')
        \\eprint('c')
        \\eprints('d')
    , &res));
    // `print` and `eprint` invoke the callback twice (value and new line).
    try zt.eq(@as(u32, 3), S.print_calls);
    try zt.eq(@as(u32, 3), S.eprint_calls);
    try zt.expect(S.print_ok);
    try zt.expect(S.eprint_ok);
}

test "Every function declared in cyber.h is exported." {
    // The header is the C contract. Zig does not analyze an unreferenced extern, so a declaration without
    // an export passes this build and only fails when a C host links it (F-51). Reference each one here.
    @setEvalBranchQuota(100_000);
    inline for (comptime std.meta.declarations(C.c)) |decl_name| {
        if (comptime std.mem.startsWith(u8, decl_name, "cl")) {
            if (@typeInfo(@TypeOf(@field(C.c, decl_name))) == .@"fn") {
                std.mem.doNotOptimizeAway(&@field(C.c, decl_name));
            }
        }
    }
}

// Zig only analyzes code that something references, so a function nothing calls can keep using removed APIs
// without failing the build. This references every `pub` declaration reachable from `cy` so that such code fails here.
test "All declarations compile." {
    refAllDeclsRecursive(cy);
}
