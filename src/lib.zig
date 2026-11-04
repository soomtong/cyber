const std = @import("std");
const build_config = @import("build_config");
const builtin = @import("builtin");
const stdx = @import("stdx");
const fatal = cy.fatal;
const mi = @import("mimalloc");
const cy = @import("cyber.zig");
const meta_mod = @import("builtins/meta.zig");
const Value = cy.Value;
const zt = stdx.testing;
const log = cy.log.scoped(.lib);
const bt = cy.types.BuiltinTypes;
const C = @import("capi.zig");
const is_wasm = builtin.target.cpu.arch.isWasm();
const vmc = cy.vmc;

export var clVerbose = false;
export var clSilent = false;

export var cl_logger: C.GlobalLogFn = default_logger;
export var CL_TRACE: bool = build_config.trace;

fn default_logger(s: C.Bytes) callconv(.c) void {
    _ = s;
}

export fn cl_vm_init() *cy.VM {
    const alloc = std.heap.c_allocator;
    const vm = alloc.create(cy.VM) catch fatal();
    vm.init(alloc) catch fatal();
    return @ptrCast(vm);
}

export fn cl_vm_initx(allocator: C.Allocator) *cy.VM {
    const alloc = C.fromAllocator(allocator);
    const vm = alloc.create(cy.VM) catch fatal();
    vm.init(alloc) catch fatal();
    return @ptrCast(vm);
}

export fn cl_vm_deinit(vm: *cy.VM) void {
    vm.deinit(false);
    vm.alloc.destroy(vm); 
}

export fn cl_thread_vm(t: *cy.Thread) *cy.VM {
    return t.c.vm;
}

export fn cl_thread_allocator(t: *cy.Thread) C.Allocator {
    return C.toAllocator(t.alloc);
}

export fn cl_thread_dump_stats(t: *cy.Thread) void {
    return t.dump_stats() catch @panic("error");
}

export fn cl_vm_allocator(vm: *cy.VM) C.Allocator {
    return C.toAllocator(vm.alloc);
}

export fn cl_thread_rc(t: *cy.Thread) usize {
    return t.getGlobalRC();
}

export fn cl_thread_count_objects(t: *cy.Thread) usize {
    return t.heap.count_objects();
}

export fn cl_thread_dump_live_objects(t: *cy.Thread) void {
    if (cy.Trace) {
        var lw = std.Io.Writer.Allocating.init(t.alloc);
        defer lw.deinit();
        const w = &lw.writer;
        w.print("begin dump live objects\n", .{}) catch @panic("error");
        var iter = t.heap.objectTraceMap.iterator();
        while (iter.next()) |it| {
            const trace = it.value_ptr.*;
            if (trace.free_ctx == null) {
                cy.debug.write_object_alloc_trace(t, w, it.key_ptr.*, trace) catch fatal();
            }
        }
        w.print("end dump live objects\n", .{}) catch @panic("error");
        t.c.vm.log(lw.written());
    }
}

/// This is useful when calling into wasm to allocate some memory.
export fn clAlloc(vm: *cy.VM, size: usize) [*]const u8 {
    const slice = vm.alloc.alignedAlloc(u8, .@"8", size) catch fatal();
    return slice.ptr;
}

export fn cl_thread_ret(t: *cy.Thread, size: usize) *anyopaque {
    return t.ret_sized(size);
}

export fn cl_thread_ret_panic(t: *cy.Thread, msg: C.Bytes) C.Ret {
    return t.ret_panic(C.from_bytes(msg));
}

export fn cl_thread_param(t: *cy.Thread, size: usize) *anyopaque {
    return t.param_sized(size).ptr;
}

export fn cl_thread_float(t: *cy.Thread) f64 {
    return t.param(f64);
}

export fn cl_thread_f32(t: *cy.Thread) f32 {
    return t.param(f32);
}

export fn cl_thread_int(t: *cy.Thread) i64 {
    return t.param(i64);
}

export fn cl_thread_i32(t: *cy.Thread) i32 {
    return t.param(i32);
}

export fn cl_thread_i16(t: *cy.Thread) i16 {
    return t.param(i16);
}

export fn cl_thread_i8(t: *cy.Thread) i8 {
    return t.param(i8);
}

export fn cl_thread_r64(t: *cy.Thread) u64 {
    return t.param(u64);
}

export fn cl_thread_r32(t: *cy.Thread) u32 {
    return t.param(u32);
}

export fn cl_thread_r16(t: *cy.Thread) u16 {
    return t.param(u16);
}

export fn cl_thread_byte(t: *cy.Thread) u8 {
    return t.param(u8);
}

export fn cl_thread_slice(t: *cy.Thread) cy.heap.Slice {
    return t.param(cy.heap.Slice);
}

export fn cl_thread_str(t: *cy.Thread) cy.heap.Str {
    return t.param(cy.heap.Str);
}

export fn cl_thread_ptr(t: *cy.Thread) *anyopaque {
    return t.param(*anyopaque);
}

export fn cl_slice_init(t: *cy.Thread, num_elems: usize, elem_size: usize) cy.heap.Slice {
    return t.heap.init_slice_undef(t.c.vm.sema.raw_buffer_byte_t.id(), num_elems, elem_size) catch fatal();
}

/// Releases a slice that a host function owns, e.g. a `[]T` param from `cl_thread_slice`.
/// `elem_t` is the element type. It may be null when the elements are not managed.
/// Like `Slice.@deinit`, the initialized elements are destructed only when this slice holds the last reference
/// to the buffer.
export fn cl_slice_deinit(t: *cy.Thread, elem_t: ?*cy.Type, s: *cy.heap.Slice) void {
    const buf: *cy.HeapObject = @ptrCast(s.buf orelse return);
    if (elem_t) |et| {
        if (et.isManaged() and buf.rc() == 1) {
            const data: [*]u8 = @ptrCast(buf.raw_buffer.elemsPtr());
            const count = @as(*u64, @ptrCast(@alignCast(data))).*;
            const elems = data + cy.heap.SliceBufferElemsOffset;
            const size = et.size();
            for (0..@intCast(count)) |i| {
                t.heap.destructValueAt(et, elems + i * size);
            }
        }
    }
    t.heap.releaseObject(buf);
}

export fn cl_vm_alloc(vm: *cy.VM, size: usize) *anyopaque {
    const slice = vm.alloc.alignedAlloc(u8, .@"8", size) catch fatal();
    return slice.ptr;
}

export fn cl_vm_free(vm: *cy.VM, ptr: *anyopaque, size: usize) void {
    vm.alloc.free(@as([*]align(8) u8, @ptrCast(@alignCast(ptr)))[0..size]);
}

export fn cl_vm_allocb(vm: *cy.VM, size: usize) C.Bytes {
    const slice = vm.alloc.alloc(u8, size) catch fatal();
    return C.to_bytes(slice);
}

export fn cl_vm_freeb(vm: *cy.VM, bytes: C.Bytes) void {
    vm.alloc.free(C.from_bytes(bytes));
}

export fn cl_vm_freez(vm: *cy.VM, str: [*:0]const u8) void {
    vm.alloc.free(std.mem.sliceTo(str, 0));
}

export fn clGetAllocator(vm: *cy.VM) C.Allocator {
    return C.toAllocator(vm.alloc);
}

export fn clDefaultEvalConfig() C.EvalConfig {
    return .{
        .single_run = false,
        .backend = C.BackendVM,
        .gen_all_debug_syms = false,
        .spawn_exe = false, 
        .persist_main = false,
    };
}

export fn cl_vm_reset(vm: *cy.VM) void {
    vm.resetVM() catch cy.fatal();
}

export fn cl_vm_eval(vm: *cy.VM, src: C.Bytes, res: *C.EvalResult) C.ResultCode {
    const uri: []const u8 = "eval";
    return cl_vm_evalx(vm, C.to_bytes(uri), src, C.defaultEvalConfig(), res);
}

export fn cl_vm_evalx(vm: *cy.VM, uri: C.Bytes, src: C.Bytes, config: C.EvalConfig, out: *C.EvalResult) C.ResultCode {
    var res = C.Success;
    out.* = vm.eval(C.from_bytes(uri), C.from_bytes(src), config) catch |err| b: {
        switch (err) {
            error.CompileError => {
                res = C.ErrorCompile;
            },
            error.Panic => {
                res = C.ErrorPanic;
            },
            error.Interrupted => {
                res = C.ErrorInterrupt;
            },
            error.Await => {
                res = C.Await;
            },
            else => {
                log.tracev("{}", .{err});
                res = C.ErrorUnknown;
            },
        }
        break :b undefined;
    };
    vm.last_res = res;
    return res;
}

export fn cl_vm_interrupt(vm: *cy.VM) void {
    @atomicStore(u8, vm.main_thread.c.interrupt, 1, .release);
}

export fn cl_vm_set_fuel(vm: *cy.VM, fuel: i64) void {
    vm.main_thread.c.fuel_limit = fuel;
}

export fn cl_vm_eval_path(vm: *cy.VM, uri: C.Bytes, config: C.EvalConfig, out: *C.EvalResult) C.ResultCode {
    var res = C.Success;
    out.* = vm.eval(C.from_bytes(uri), null, config) catch |err| b: {
        switch (err) {
            error.CompileError => {
                res = C.ErrorCompile;
            },
            error.Panic => {
                res = C.ErrorPanic;
            },
            error.Interrupted => {
                res = C.ErrorInterrupt;
            },
            error.Await => {
                res = C.Await;
            },
            else => {
                log.tracev("{}", .{err});
                res = C.ErrorUnknown;
            },
        }
        break :b undefined;
    };
    vm.last_res = res;
    return res;
}

// export fn cl_run_ready_tasks(t: *cy.Thread) C.ResultCode {
//     var res = C.Success;
//     runReadyTasks(t) catch |err| {
//         switch (err) {
//             error.CompileError => {
//                 res = C.ErrorCompile;
//             },
//             error.Panic => {
//                 res = C.ErrorPanic;
//             },
//             error.Await => {
//                 res = C.Await;
//             },
//             else => {
//                 log.tracev("{}", .{err});
//                 res = C.ErrorUnknown;
//             },
//         }
//     };
//     t.last_res = res;
//     return res;
// }

// fn runReadyTasks(t: *cy.Thread) anyerror!void {
//     log.tracev("run ready tasks", .{});

//     while (t.ready_tasks.readItem()) |task| {
//         switch (task.type) {
//             .cont => {
//                 const cont = task.data.cont;
//                 t.c.stack = @ptrCast(cont.stack.ptr);
//                 t.c.stack_len = cont.stack.len;
//                 t.c.stackEndPtr = t.c.stack + t.c.stack_len;
//                 t.c.framePtr = t.c.stack + cont.fp;
//                 t.c.pc = cont.pc;
//                 @call(.never_inline, cy.Thread.evalLoopGrowStack, .{t.main_thread, true}) catch |err| {
//                     if (err == error.Await) {
//                         continue;
//                     } else {
//                         return err;
//                     }
//                 };

//                 // Reached end. Free task's stack.
//                 t.alloc.free(t.c.stack[0..t.c.stack_len]);
//                 t.c.stack_len = 0;
//             },
//             .callback => {
//                 // Create fiber.
//                 const initial_stack_size: u32 = 16;
//                 const stack = try t.heap.alloc.alloc(Value, initial_stack_size);
//                 t.c.stack = @ptrCast(stack.ptr);
//                 t.c.stack_len = stack.len;
//                 t.c.stackEndPtr = @ptrCast(t.c.stack + t.c.stack_len);

//                 // Indicate there is no previous fp.
//                 t.c.framePtr = t.c.stackEndPtr;
//                 _ = cy.vm.callUnion(t, task.data.callback, &.{}) catch |err| {
//                     if (err == error.Await) {
//                         return error.TODO;
//                     } else if (err == error.Panic) {
//                         try cy.vm.handleExecResult(t, vmc.RES_CODE_PANIC);
//                     } else {
//                         return err;
//                     }
//                 };

//                 // Release callback.
//                 t.heap.release(task.data.callback);

//                 // Reached end. Free task's stack.
//                 t.alloc.free(t.c.stack[0..t.c.stack_len]);
//             },
//             .dead => {},
//         }
//     }
// }

export fn clDefaultCompileConfig() C.CompileConfig {
    return .{
        .single_run = false,
        .gen_all_debug_syms = false,
        .backend = C.BackendVM,
        .skip_codegen = false,
        .emit_source_map = false,
        .persist_main = false,
    };
}

export fn cl_vm_compile_path(vm: *cy.VM, uri: C.Bytes, config: C.CompileConfig) C.ResultCode {
    var res = C.Success;
    _ = vm.compile(C.from_bytes(uri), null, config) catch |err| {
        switch (err) {
            error.CompileError => {
                res = C.ErrorCompile;
            },
            else => {
                res = C.ErrorUnknown;
            },
        }
    };
    vm.last_res = res;
    return res;
}    

export fn cl_vm_compile(vm: *cy.VM, uri: C.Bytes, src: C.Bytes, config: C.CompileConfig) C.ResultCode {
    var res = C.Success;
    _ = vm.compile(C.from_bytes(uri), C.from_bytes(src), config) catch |err| {
        switch (err) {
            error.CompileError => {
                res = C.ErrorCompile;
            },
            else => {
                res = C.ErrorUnknown;
            },
        }
    };
    vm.last_res = res;
    return res;
}

export fn cl_vm_validate(vm: *cy.VM, src: C.Bytes) C.ResultCode {
    var res = C.Success;
    _ = vm.validate("main", C.from_bytes(src), .{}) catch |err| {
        switch (err) {
            error.CompileError => {
                res = C.ErrorCompile;
            },
            else => {
                res = C.ErrorUnknown;
            },
        }
    };
    vm.last_res = res;
    return res;
}

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

export fn clResultName(code: C.ResultCode) C.Bytes {
    switch (code) {
        C.Success => return C.to_bytes("Success"),
        C.ErrorCompile => return C.to_bytes("CompileError"),
        C.ErrorPanic => return C.to_bytes("PanicError"),
        C.ErrorInterrupt => return C.to_bytes("InterruptError"),
        C.ErrorUnknown => return C.to_bytes("UnknownError"),
        else => fatal(),
    }
}

var tempBuf: [1024]u8 align(8) = undefined;

export fn cl_vm_error_summary(vm: *cy.VM) C.Bytes {
    if (vm.last_res == C.ErrorCompile) {
        return cl_vm_compile_error_summary(vm);
    } else if (vm.last_res == C.ErrorPanic or vm.last_res == C.ErrorInterrupt) {
        return cl_thread_panic_summary(vm.main_thread);
    } else {
        return C.NullStr;
    }
}

export fn cl_vm_compile_error_summary(vm: *cy.VM) C.Bytes {
    if (vm.compiler.reports.items.len == 0) {
        cy.panic("No report.");
    }
    const str = cy.debug.allocReportSummary(vm.compiler, vm.compiler.reports.items[0]) catch fatal();
    return C.to_bytes(str);
}

export fn cl_thread_panic_summary(t: *cy.Thread) C.Bytes {
    const summary = cy.debug.allocLastUserPanicError(t) catch fatal();
    return C.to_bytes(summary);
}

export fn cl_thread_panic_trace(t: *cy.Thread) C.StackTrace {
    return .{
        .frames = @ptrCast(t.stack_trace.frames.ptr),
        .frames_len = t.stack_trace.frames.len,
    };
}

export fn clReportApiError(vm: *const cy.VM, msg: C.Bytes) void {
    vm.setApiError(C.from_bytes(msg)) catch fatal();
}

export fn cl_vm_resolver(vm: *cy.VM) C.ResolverFn {
    return vm.compiler.resolver;
}

export fn cl_vm_set_resolver(vm: *cy.VM, resolver: C.ResolverFn) void {
    vm.compiler.resolver = resolver;
}

export fn cl_vm_resolve(vm: *cy.VM, uri: C.Bytes) C.Bytes {
    var buf: [4096]u8 = undefined;
    const r_uri_temp = cy.compiler.resolveModuleUri(vm.compiler, &buf, C.from_bytes(uri)) catch fatal();
    const r_uri = vm.alloc.dupe(u8, r_uri_temp) catch fatal();
    return C.to_bytes(r_uri);
}

export fn cl_vm_set_dl_resolver(vm: *cy.VM, dl_resolver: C.DlResolverFn) void {
    vm.compiler.dl_resolver = dl_resolver;
}

export fn cl_vm_get_loader(vm: *cy.VM) C.ModuleLoaderFn {
    return vm.compiler.loader;
}

export fn cl_vm_set_loader(vm: *cy.VM, loader: C.ModuleLoaderFn) void {
    vm.compiler.loader = loader;
}

export fn cl_vm_printer(vm: *cy.VM) C.PrintFn {
    return vm.print;
}

export fn cl_vm_set_printer(vm: *cy.VM, print: C.PrintFn) void {
    vm.print = print;
}

export fn cl_vm_eprinter(vm: *cy.VM) C.PrintErrorFn {
    return vm.print_err;
}

export fn cl_vm_set_eprinter(vm: *cy.VM, print: C.PrintErrorFn) void {
    vm.print_err = print;
}

export fn cl_vm_logger(vm: *cy.VM) C.LogFn {
    return vm.log_fn;
}

export fn cl_vm_set_logger(vm: *cy.VM, logger: C.LogFn) void {
    vm.log_fn = logger;
}

export fn cl_vm_dump_bytecode(vm: *cy.VM) void {
    cy.debug.dumpBytecode(vm, .{}) catch @panic("error");
}

export fn cl_thread_check_memory(t: *cy.Thread) C.MemoryCheck {
    return t.check_memory() catch cy.fatal();
}

export fn cl_find_type(vm: *cy.VM, spec: C.Bytes) ?*cy.Type {
    return vm.findType(C.from_bytes(spec)) catch @panic("error");
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

export fn clExpandTypeTemplate(vm: *cy.VM, ctemplate: ?*C.Sym, types_ptr: [*]const *cy.Type, args_ptr: [*]const cy.Value, nargs: usize) ?*cy.Type {
    const template = cy.Sym.fromC(ctemplate).cast(.template);
    const args = args_ptr[0..nargs];
    const param_types = types_ptr[0..nargs];
    return vm.expandTypeTemplate(template, param_types, args) catch @panic("error");
}

export fn cl_mod_add_type(mod: *C.Sym, name: C.Bytes, binding: C.BindType) void {
    const c: *cy.sym.Chunk = @ptrCast(@alignCast(mod));
    c.chunk.host_types.put(c.chunk.alloc, C.from_bytes(name), binding) catch @panic("error");
}

export fn cl_mod_add_func(mod: *C.Sym, name: C.Bytes, binding: C.BindFunc) void {
    const c: *cy.sym.Chunk = @ptrCast(@alignCast(mod));
    c.chunk.host_funcs.put(c.chunk.alloc, C.from_bytes(name), binding) catch @panic("error");
}

export fn cl_mod_set_fallback_func(mod: *C.Sym, binding: C.BindFunc) void {
    const c: *cy.sym.Chunk = @ptrCast(@alignCast(mod));
    c.chunk.fallback_bind_func = binding;
}

export fn cl_mod_add_global(mod: *C.Sym, name: C.Bytes, binding: C.BindGlobal) void {
    const c: *cy.sym.Chunk = @ptrCast(@alignCast(mod));
    c.chunk.host_globals.put(c.chunk.alloc, C.from_bytes(name), binding) catch @panic("error");
}

export fn cl_mod_on_destroy(mod: *C.Sym, on_destroy: C.ModuleOnDestroyFn) void {
    const c: *cy.sym.Chunk = @ptrCast(@alignCast(mod));
    c.chunk.on_destroy = on_destroy;
}

export fn cl_mod_on_load(mod: *C.Sym, on_load: C.ModuleOnLoadFn) void {
    const c: *cy.sym.Chunk = @ptrCast(@alignCast(mod));
    c.chunk.on_load = on_load;
}

export fn cl_thread_release(t: *cy.Thread, val: Value) void {
    t.heap.release(val);
}

export fn cl_thread_retain(t: *cy.Thread, val: Value) void {
    t.heap.retain(val);
}

export fn cl_vm_user_data(vm: *cy.VM) ?*anyopaque {
    return vm.userData;
}

export fn cl_vm_set_user_data(vm: *cy.VM, userData: ?*anyopaque) void {
    vm.userData = userData;
}

export fn cl_str_init(t: *cy.Thread, cstr: C.Bytes) C.str {
    return stdx.reinterpret(C.str, t.heap.init_str(C.from_bytes(cstr)) catch fatal());
}

export fn cl_astr_init(t: *cy.Thread, cstr: C.Bytes) C.str {
    return stdx.reinterpret(C.str, t.heap.init_astr(C.from_bytes(cstr)) catch fatal());
}

export fn cl_ustr_init(t: *cy.Thread, cstr: C.Bytes) C.str {
    return stdx.reinterpret(C.str, t.heap.init_ustr(C.from_bytes(cstr)) catch fatal());
}

export fn cl_str_deinit(t: *cy.Thread, s: *cy.heap.Str) void {
    t.heap.destructStr(s);
}

export fn cl_str_bytes(s: cy.heap.Str) C.Bytes {
    return C.to_bytes(s.slice());
}

export fn cl_array_empty(t: *cy.Thread, array_t: *cy.Type) Value {
    return t.heap.newEmptyArray(array_t.id()) catch fatal();
}

export fn cl_map_empty(t: *cy.Thread, map_t: *cy.Type) Value {
    return t.heap.allocMapZero(map_t.id()) catch fatal();
}

export fn cl_new_func_union(t: *cy.Thread, union_t: *cy.Type, func: C.HostFn) Value {
    return t.heap.allocHostFuncUnion(union_t.id(), @ptrCast(func)) catch fatal();
}

export fn cl_vm_ensure_func_sig(vm: *cy.VM, params: [*]const *cy.Type, nparams: usize, ret_t: *cy.Type) *cy.FuncSig {
    return vm.sema.ensureFuncSig(@ptrCast(@alignCast(params[0..nparams])), ret_t) catch fatal();
}

// test "clNewFunc()" {
//     const vm = C.create();
//     defer vm.destroy();

//     const val = vm.newFunc(&.{}, bt.Dyn, @ptrFromInt(8));
//     try t.eq(C.getType(val), bt.Func);
// }

export fn cl_mod_set_data(mod_: *C.Sym, data: ?*anyopaque) void {
    const sym: *cy.sym.Chunk = @ptrCast(@alignCast(mod_));
    const chunk = sym.chunk;
    chunk.user_data = data;
}

export fn cl_mod_get_data(mod_: *C.Sym) ?*anyopaque {
    const sym: *cy.sym.Chunk = @ptrCast(@alignCast(mod_));
    const chunk = sym.chunk;
    return chunk.user_data;
}

export fn cl_lift(t: *cy.Thread, type_: *cy.Type, value: *anyopaque) Value {
    const res = t.heap.new_object_undef(type_.id(), type_.size()) catch @panic("error");
    const dst: [*]u8 = @ptrCast(res);
    const src: [*]u8 = @ptrCast(value);
    @memcpy(dst[0..type_.size()], src[0..type_.size()]);
    return Value.initPtr(res);
}

export fn cl_error(vm: *cy.VM, name: C.Bytes) u64 {
    return vm.sema.ensureSymbol(C.from_bytes(name)) catch @panic("error");
}

export fn cl_symbol(vm: *cy.VM, name: C.Bytes) u64 {
    return vm.sema.ensureSymbol(C.from_bytes(name)) catch @panic("error");
}

test "cl_symbol()" {
    const vm = C.vm_init();
    defer C.vm_deinit(vm);

    const val = C.symbol(vm, "foo");
    try zt.eq(val + 1, C.symbol(vm, "foo2"));
    try zt.eq(val, C.symbol(vm, "foo"));
}

export fn cl_object_string(t: *cy.Thread, val: Value) C.Bytes {
    const str = t.heap.get_or_buf_print_object(&cy.tempBuf, val) catch cy.fatal();
    return C.to_bytes(str);
}

test "Constants." {
    try zt.eq(C.TypeVoid, bt.Void);
    try zt.eq(C.TypeBool, bt.Bool);
    try zt.eq(C.TypeError, bt.Error);
    try zt.eq(C.TypeSymbol, bt.Symbol);
    try zt.eq(C.TypeI64, bt.I64);
    try zt.eq(C.TypeF64, bt.F64);
    try zt.eq(C.TypeStr, bt.Str);
    // try zt.eq(C.TypeFiber, bt.Fiber);
    try zt.eq(C.TypeType, bt.Type);
    try zt.eq(C.TypeFuncSig, bt.FuncSig);
    try zt.eq(C.TypeCode, bt.Code);
}

export fn cl_type_id(type_: *cy.Type) cy.TypeId {
    return type_.id();
}

export fn cl_type_from_id(vm: *cy.VM, type_id: cy.TypeId) *C.Type {
    return @ptrCast(vm.sema.getType(type_id));
}

// test "clGetTypeId()" {
//     try t.eq(C.getType(C.float(123)), bt.Float);
// }

export fn cl_vm_main_thread(vm: *cy.VM) *cy.Thread {
    return vm.main_thread;
}

export fn cl_thread_trace_info(t: *cy.Thread) C.TraceInfo {
    return .{
        .num_retains = t.heap.c.numRetains,
        .num_releases = t.heap.c.numReleases,
    };
}

export fn cl_thread_signal_host_segfault(t: *cy.Thread) void {
    cy.debug.thread_signal_host_segfault(t) catch @panic("error");
}

export fn cl_thread_signal_host_panic(t: *cy.Thread) void {
    cy.debug.thread_signal_host_panic(t) catch @panic("error");
}

export fn cl_value_desc(vm: *cy.VM, val_t: cy.TypeId, val: *Value) C.Bytes {
    const res = cy.debug.alloc_value_desc(vm, val_t, val) catch @panic("error");
    return C.to_bytes(res);
}

export fn cl_full_version() C.Bytes {
    return C.to_bytes(build_config.full_version);
}

test "cl_full_version()" {
    const str = C.full_version();
    try zt.eqStr(str, build_config.full_version);
}

export fn cl_version() C.Bytes {
    return C.to_bytes(build_config.version);
}

test "cl_version()" {
    const str = C.version();
    try zt.eqStr(str, build_config.version);
}

export fn cl_build() C.Bytes {
    return C.to_bytes(build_config.build);
}

test "cl_build()" {
    const str = C.build();
    try zt.eqStr(str, build_config.build);
}

export fn cl_commit() C.Bytes {
    return C.to_bytes(build_config.commit);
}

test "cl_commit()" {
    const str = C.commit();
    try zt.eqStr(str, build_config.commit);
}

comptime {
    @export(&cy.compiler.default_resolver, .{ .name = "cl_default_resolver", .linkage = .strong });
    @export(&cy.compiler.default_loader, .{ .name = "cl_default_loader", .linkage = .strong });
}

fn test_logger(_: ?*C.VM, str: C.Bytes) callconv(.c) void {
    std.debug.print("{s}\n", .{C.from_bytes(str)});
}

fn test_global_logger(str: C.Bytes) callconv(.c) void {
    std.debug.print("{s}\n", .{C.from_bytes(str)});
}

fn debug(vm: ?*C.VM) void {
    C.setVerbose(true);
    C.vm_set_logger(vm, &test_logger);
    C.set_logger(&test_global_logger);
}

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

    // A panic in a spawned thread fails the eval instead of aborting the process.
    try zt.eq(C.ErrorPanic, C.vm_eval(vm,
        \\fn boom(n int) -> int:
        \\  panic('boom')
        \\  return n
        \\_ = spawn(boom, {1}).await()
    , &res));
    {
        const report = C.vm_error_summary(vm);
        defer C.vm_freeb(vm, report);
        try zt.eq(true, std.mem.startsWith(u8, report, "panic: Spawned thread did not finish."));
    }

    // Still usable.
    try zt.eq(C.Success, C.vm_eval(vm,
        \\fn add(a int, b int) -> int:
        \\  return a + b
        \\use test
        \\test.eq(5, spawn(add, {2, 3}).await())
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

// pub fn panic(msg: []const u8, trace: ?*std.lang.StackTrace, ret_addr: ?usize) noreturn {
//     _ = trace;
//     _ = ret_addr;
//     // if (is_wasm) {
//     //     std.debug.print("{s}", .{msg});
//     //     @trap();
//     // } else {
//         // std.debug.defaultPanic(msg, @returnAddress());
//     // }
// }

export fn cl_strlen(s: [*:0]const u8) usize {
    return std.mem.len(s);
}
fn refAllDeclsRecursive(comptime T: type) void {
    if (!builtin.is_test) return;
    @setEvalBranchQuota(1_000_000);
    inline for (comptime std.meta.declarations(T)) |decl_name| {
        // Translated C headers hold expressions that do not translate, so they are not walked. The copy-and-patch
        // JIT (`jitgen`) is unsupported dead code that no longer compiles (`docs/decisions/project_direction.md`).
        if (comptime std.mem.eql(u8, decl_name, "vmc") or std.mem.eql(u8, decl_name, "c") or std.mem.eql(u8, decl_name, "jitgen")) continue;
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

// Zig only analyzes code that something references, so a function nothing calls can keep using removed APIs
// without failing the build. This references every `pub` declaration reachable from `cy` so that such code fails here.
test "All declarations compile." {
    refAllDeclsRecursive(cy);
}
