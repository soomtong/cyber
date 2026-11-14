const std = @import("std");
const build_config = @import("build_config");
const stdx = @import("stdx");
const fatal = cy.fatal;
const cy = @import("cyber.zig");
const Value = cy.Value;
// Unused here. src/tools/alloc_fuzz/probe.zig is appended to this file and uses this name.
const zt = stdx.testing;
const log = cy.log.scoped(.lib);
const C = @import("capi.zig");
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

/// The allocator of a VM created with `cl_vm_init_mem`: the two C functions of the host as a `std.mem.Allocator`.
/// There is no in-place growth, so `resize` and `remap` decline and the caller allocates, copies and frees.
const HostMem = struct {
    funcs: C.MemFuncs,

    fn allocator(self: *HostMem) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// The `HostMem` behind `a`, when `a` came from `cl_vm_init_mem`.
    fn of(a: std.mem.Allocator) ?*HostMem {
        if (a.vtable != &vtable) return null;
        return @ptrCast(@alignCast(a.ptr));
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
        const self: *HostMem = @ptrCast(@alignCast(ctx));
        return @ptrCast(self.funcs.alloc.?(self.funcs.ctx, len, alignment.toByteUnits()));
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, _: usize) void {
        const self: *HostMem = @ptrCast(@alignCast(ctx));
        self.funcs.free.?(self.funcs.ctx, memory.ptr, memory.len, alignment.toByteUnits());
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = std.mem.Allocator.noResize,
        .remap = std.mem.Allocator.noRemap,
        .free = free,
    };
};

export fn cl_vm_init_mem(funcs: C.MemFuncs) *cy.VM {
    // The `HostMem` lives in the host's memory too, so that the host sees nothing left after `cl_vm_deinit`.
    const mem_ptr = funcs.alloc.?(funcs.ctx, @sizeOf(HostMem), @alignOf(HostMem)) orelse fatal();
    const mem: *HostMem = @ptrCast(@alignCast(mem_ptr));
    mem.* = .{ .funcs = funcs };
    const alloc = mem.allocator();
    const vm = alloc.create(cy.VM) catch fatal();
    vm.init(alloc) catch fatal();
    return @ptrCast(vm);
}

export fn cl_vm_deinit(vm: *cy.VM) void {
    vm.deinit(false);
    // `deinit` put back the allocator the VM was created with.
    const alloc = vm.alloc;
    alloc.destroy(vm);
    if (HostMem.of(alloc)) |mem| {
        const funcs = mem.funcs;
        funcs.free.?(funcs.ctx, mem, @sizeOf(HostMem), @alignOf(HostMem));
    }
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

export fn cl_vm_release_result(vm: *cy.VM) void {
    vm.dropMainResult(true);
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

export fn clDefaultEvalConfig() C.EvalConfig {
    return .{
        .single_run = false,
        .backend = C.BackendVM,
        .gen_all_debug_syms = false,
        .spawn_exe = false,
        .persist_main = false,
        .deny_raw_ptrs = false,
        .deny_spawn = false,
    };
}

export fn cl_vm_reset(vm: *cy.VM) void {
    vm.resetVM() catch cy.fatal();
}

export fn cl_vm_reset_pending(vm: *cy.VM) bool {
    return vm.compiler.first_compile_failed or vm.compiler.alloc_failed;
}

/// Maps an error of an eval to its result code. `anytype` keeps the switch on the error set of the caller (`anyerror` today).
fn evalResultCode(err: anytype) C.ResultCode {
    return switch (err) {
        error.CompileError => C.ErrorCompile,
        error.Panic => C.ErrorPanic,
        error.Interrupted => C.ErrorInterrupt,
        error.Await => C.Await,
        error.Suspended => C.ErrorSuspended,
        else => b: {
            log.tracev("{}", .{err});
            break :b C.ErrorUnknown;
        },
    };
}

/// Maps an error of a compile or a validate to its result code. `err` is `anytype` for the same reason.
fn compileResultCode(err: anytype) C.ResultCode {
    return switch (err) {
        error.CompileError => C.ErrorCompile,
        error.Suspended => C.ErrorSuspended,
        else => C.ErrorUnknown,
    };
}

export fn cl_vm_eval(vm: *cy.VM, src: C.Bytes, res: *C.EvalResult) C.ResultCode {
    const uri: []const u8 = "eval";
    return cl_vm_evalx(vm, C.to_bytes(uri), src, C.defaultEvalConfig(), res);
}

export fn cl_vm_evalx(vm: *cy.VM, uri: C.Bytes, src: C.Bytes, config: C.EvalConfig, out: *C.EvalResult) C.ResultCode {
    var res = C.Success;
    out.* = vm.eval(C.from_bytes(uri), C.from_bytes(src), config) catch |err| b: {
        res = evalResultCode(err);
        break :b undefined;
    };
    vm.last_res = res;
    return res;
}

export fn cl_vm_resume(vm: *cy.VM, out: *C.EvalResult) C.ResultCode {
    var res = C.Success;
    out.* = vm.resumeEval() catch |err| b: {
        res = evalResultCode(err);
        break :b undefined;
    };
    vm.last_res = res;
    return res;
}

export fn cl_vm_abandon(vm: *cy.VM) void {
    if (!vm.isSuspended()) return;
    vm.abandonEval();
    vm.last_res = C.ErrorInterrupt;
}

export fn cl_vm_pending_future(vm: *cy.VM) ?*cy.heap.FutureValue {
    return vm.compiler.await_future;
}

export fn cl_vm_pending_futures(vm: *cy.VM, out: ?[*]?*cy.heap.FutureValue, cap: usize) usize {
    const compiler = vm.compiler;
    const single = compiler.await_future orelse return 0;
    const list: []const *cy.heap.FutureValue = if (compiler.await_any.len > 0) compiler.await_any else &.{single};
    if (out) |out_| {
        for (list[0..@min(cap, list.len)], 0..) |future, i| {
            out_[i] = future;
        }
    }
    return list.len;
}

export fn cl_future_tag(future: *cy.heap.FutureValue) u64 {
    return future.tag;
}

export fn cl_future_new(t: *cy.Thread, future_t: *cy.Type, tag: u64) ?*cy.heap.FutureValue {
    if (!future_t.isInstanceOf(t.c.vm.sema.future_tmpl)) return null;
    // `Future[T]` is a struct with the single field `inner ^FutureValue[T]`.
    const value_t = future_t.cast(.struct_t).fields()[0].type.cast(.pointer).child_t;
    const size = value_t.size();
    const obj = t.heap.new_object_undef(value_t.id(), size) catch return null;
    // Zeroed: not completed, no shared state, and `data` is `none`.
    @memset(@as([*]u8, @ptrCast(obj))[0..size], 0);
    const future: *cy.heap.FutureValue = @ptrCast(@alignCast(obj));
    future.cont_head = cy.NullId;
    future.cont_tail = cy.NullId;
    future.tag = tag;
    return future;
}

/// Where the `T` of a pending host future is written, or null if the future can not be completed by the host.
const FutureSlot = struct {
    type: *cy.Type,
    ptr: [*]u8,
    /// The tag of `data ?T`, or null when `none` is the zero value of `T`.
    some_tag: ?*u64,
};

fn futureSlot(vm: *cy.VM, future: *cy.heap.FutureValue) ?FutureSlot {
    if (future.completed or future.shared_state != null) return null;
    const obj: *cy.HeapObject = @ptrCast(@alignCast(future));
    const value_t = vm.sema.getType(obj.getTypeId());
    if (value_t.kind() != .struct_t) return null;
    // `FutureValue[T]`: cont_head, cont_tail, shared_state, completed, tag, data ?T.
    const fields = value_t.cast(.struct_t).fields();
    if (fields.len != 6 or fields[5].type.kind() != .option) return null;
    const option_t = fields[5].type.cast(.option);
    const data: [*]u8 = @ptrCast(&future.data);
    if (option_t.zero_union) {
        return .{ .type = option_t.child_t, .ptr = data, .some_tag = null };
    }
    return .{ .type = option_t.child_t, .ptr = data + 8, .some_tag = @ptrCast(@alignCast(data)) };
}

export fn cl_future_complete(vm: *cy.VM, future: *cy.heap.FutureValue, value: ?*const anyopaque) bool {
    const slot = futureSlot(vm, future) orelse return false;
    var dst = slot.ptr;
    var val_t = slot.type;
    if (val_t.kind() == .result) {
        // `Future[!U]` takes the `U`. The result's tag 1 is the value case.
        @as(*u64, @ptrCast(@alignCast(dst))).* = 1;
        dst += 8;
        val_t = val_t.cast(.result).child_t;
    }
    const size = val_t.size();
    if (size > 0) {
        const src: [*]const u8 = @ptrCast(value orelse return false);
        @memcpy(dst[0..size], src[0..size]);
    }
    if (slot.some_tag) |tag| tag.* = 1;
    future.completed = true;
    return true;
}

export fn cl_future_complete_error(vm: *cy.VM, future: *cy.heap.FutureValue, err: i64) bool {
    const slot = futureSlot(vm, future) orelse return false;
    if (slot.type.kind() != .result) return false;
    // The result's tag 0 is the error case.
    @as(*u64, @ptrCast(@alignCast(slot.ptr))).* = 0;
    @as(*i64, @ptrCast(@alignCast(slot.ptr + 8))).* = err;
    if (slot.some_tag) |tag| tag.* = 1;
    future.completed = true;
    return true;
}

export fn cl_vm_interrupt(vm: *cy.VM) void {
    @atomicStore(u8, vm.main_thread.c.interrupt, 1, .release);
    // A thread that waits for a spawned thread sleeps until something happens. Can be called from a signal handler.
    vm.worker_pool.notifyProgressFromSignal();
}

export fn cl_vm_set_fuel(vm: *cy.VM, fuel: i64) void {
    vm.main_thread.c.fuel_limit = fuel;
}

export fn cl_vm_set_memory_limit(vm: *cy.VM, bytes: i64) void {
    vm.memAccount().limit.store(if (bytes <= 0) 0 else @intCast(@min(bytes, std.math.maxInt(usize))), .monotonic);
}

export fn cl_vm_memory_used(vm: *cy.VM) usize {
    return vm.memAccount().used.load(.monotonic);
}

export fn cl_vm_set_stack_limit(vm: *cy.VM, bytes: i64) void {
    if (bytes <= 0) {
        vm.main_thread.c.stack_limit = std.math.maxInt(usize);
    } else {
        vm.main_thread.c.stack_limit = @intCast(@divTrunc(bytes, @sizeOf(cy.Value)));
    }
}

export fn cl_vm_eval_path(vm: *cy.VM, uri: C.Bytes, config: C.EvalConfig, out: *C.EvalResult) C.ResultCode {
    var res = C.Success;
    out.* = vm.eval(C.from_bytes(uri), null, config) catch |err| b: {
        res = evalResultCode(err);
        break :b undefined;
    };
    vm.last_res = res;
    return res;
}

export fn clDefaultCompileConfig() C.CompileConfig {
    return .{
        .single_run = false,
        .gen_all_debug_syms = false,
        .backend = C.BackendVM,
        .skip_codegen = false,
        .emit_source_map = false,
        .persist_main = false,
        .deny_raw_ptrs = false,
        .deny_spawn = false,
    };
}

export fn cl_vm_compile_path(vm: *cy.VM, uri: C.Bytes, config: C.CompileConfig) C.ResultCode {
    var res = C.Success;
    _ = vm.compile(C.from_bytes(uri), null, config) catch |err| {
        res = compileResultCode(err);
    };
    vm.last_res = res;
    return res;
}

export fn cl_vm_compile(vm: *cy.VM, uri: C.Bytes, src: C.Bytes, config: C.CompileConfig) C.ResultCode {
    var res = C.Success;
    _ = vm.compile(C.from_bytes(uri), C.from_bytes(src), config) catch |err| {
        res = compileResultCode(err);
    };
    vm.last_res = res;
    return res;
}

export fn cl_vm_validate(vm: *cy.VM, src: C.Bytes) C.ResultCode {
    var res = C.Success;
    _ = vm.validate("main", C.from_bytes(src), .{}) catch |err| {
        res = compileResultCode(err);
    };
    vm.last_res = res;
    return res;
}

export fn clResultName(code: C.ResultCode) C.Bytes {
    switch (code) {
        C.Success => return C.to_bytes("Success"),
        C.ErrorCompile => return C.to_bytes("CompileError"),
        C.ErrorPanic => return C.to_bytes("PanicError"),
        C.ErrorInterrupt => return C.to_bytes("InterruptError"),
        C.ErrorUnknown => return C.to_bytes("UnknownError"),
        C.Await => return C.to_bytes("Await"),
        C.ErrorSuspended => return C.to_bytes("SuspendedError"),
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
        // Asking without an error is not a reason to end the host process.
        return C.NullStr;
    }
    // Out of memory for the text: the null string, like no error. `cl_vm_compile_error` still has the message.
    const str = cy.debug.allocReportSummary(vm.compiler, vm.compiler.reports.items[0]) catch return C.NullStr;
    return C.to_bytes(str);
}

export fn cl_vm_format(vm: *cy.VM, src: C.Bytes, out: *C.Bytes) C.FormatResult {
    var diag: cy.format.Diagnostic = .{};
    defer diag.deinit(vm.alloc);
    const text = cy.format.format(vm.alloc, C.from_bytes(src), &diag) catch |err| {
        out.* = C.NullStr;
        switch (err) {
            error.OutOfMemory => return C.FormatNoMemory,
            error.ParseError => {
                const msg = std.fmt.allocPrint(vm.alloc, "{}:{}: {s}", .{ diag.line + 1, diag.col + 1, diag.msg }) catch return C.FormatSyntaxError;
                out.* = C.to_bytes(msg);
                return C.FormatSyntaxError;
            },
            error.VerifyError => {
                // Not every verification failure has a position in the source.
                const msg = (if (diag.pos > 0)
                    std.fmt.allocPrint(vm.alloc, "{}:{}: {s}", .{ diag.line + 1, diag.col + 1, diag.msg })
                else
                    vm.alloc.dupe(u8, diag.msg)) catch return C.FormatInternalError;
                out.* = C.to_bytes(msg);
                return C.FormatInternalError;
            },
        }
    };
    out.* = C.to_bytes(text);
    return C.FormatOk;
}

export fn cl_vm_set_error_color(vm: *cy.VM, enabled: bool) void {
    vm.compiler.report_color = enabled;
}

export fn cl_vm_set_symbol_info(vm: *cy.VM, enabled: bool) void {
    vm.compiler.record_refs = enabled;
}

export fn cl_vm_symbol_at(vm: *cy.VM, pos: u32, out: *C.SymbolInfo) bool {
    out.* = std.mem.zeroes(C.SymbolInfo);
    const info = (cy.refs.find(vm.compiler, pos) catch return false) orelse return false;
    out.* = .{
        .kind = switch (info.kind) {
            .expr => C.SymbolExpr,
            .local => C.SymbolLocal,
            .sym => C.SymbolDecl,
        },
        .pos = info.pos,
        .end_pos = info.end,
        .detail = C.to_bytes(info.detail),
        .has_def = info.def_uri.len > 0,
        .def_uri = C.to_bytes(info.def_uri),
        .def_pos = info.def_pos,
        .def_end_pos = info.def_end,
    };
    return true;
}

export fn cl_vm_symbol_refs(vm: *cy.VM, pos: u32, out: *[*c]const C.Range) usize {
    out.* = null;
    const ranges = cy.refs.findAll(vm.compiler, pos) catch return 0;
    if (ranges.len == 0) return 0;
    out.* = @ptrCast(ranges.ptr);
    return ranges.len;
}

export fn cl_vm_symbol_refs_to(vm: *cy.VM, def_uri: C.Bytes, def_pos: u32, out: *[*c]const C.Range) usize {
    out.* = null;
    const ranges = cy.refs.findAllTo(vm.compiler, C.from_bytes(def_uri), def_pos) catch return 0;
    if (ranges.len == 0) return 0;
    out.* = @ptrCast(ranges.ptr);
    return ranges.len;
}

export fn cl_vm_symbol_tokens(vm: *cy.VM, out: *[*c]const C.Token) usize {
    out.* = null;
    const tokens = cy.refs.tokens(vm.compiler) catch return 0;
    if (tokens.len == 0) return 0;
    out.* = @ptrCast(tokens.ptr);
    return tokens.len;
}

fn toItems(vm: *cy.VM, items: []const cy.refs.Item, out: *[*c]const C.Item) usize {
    out.* = null;
    if (items.len == 0) return 0;
    // The arena of the items owns the array too. It is used in place: a copy would lose the allocation.
    const arena = if (vm.compiler.ref_arena) |*a| a.allocator() else return 0;
    const res = arena.alloc(C.Item, items.len) catch return 0;
    for (items, 0..) |item, i| {
        res[i] = .{
            .name = C.to_bytes(item.name),
            .detail = C.to_bytes(item.detail),
            .kind = switch (item.kind) {
                .local => C.ItemLocal,
                .function => C.ItemFunction,
                .type => C.ItemType,
                .field => C.ItemField,
                .case => C.ItemCase,
                .constant => C.ItemConstant,
                .global => C.ItemGlobal,
                .module => C.ItemModule,
                .other => C.ItemOther,
                .method => C.ItemMethod,
            },
        };
    }
    out.* = res.ptr;
    return res.len;
}

export fn cl_vm_members_at(vm: *cy.VM, pos: u32, out: *[*c]const C.Item) usize {
    out.* = null;
    const items = cy.refs.members(vm.compiler, pos) catch return 0;
    return toItems(vm, items, out);
}

export fn cl_vm_names_at(vm: *cy.VM, pos: u32, out: *[*c]const C.Item) usize {
    out.* = null;
    const items = cy.refs.scope(vm.compiler, pos) catch return 0;
    return toItems(vm, items, out);
}

export fn cl_vm_set_error_recovery(vm: *cy.VM, enabled: bool) void {
    vm.compiler.recover = enabled;
}

export fn cl_vm_compile_error(vm: *cy.VM, out: *C.CompileError) bool {
    out.* = std.mem.zeroes(C.CompileError);
    // `last_res` rather than the report list alone: the list is only cleared when the next compile starts.
    if (vm.last_res != C.ErrorCompile or vm.compiler.reports.items.len == 0) {
        return false;
    }
    const report = vm.compiler.reports.items[0];
    const loc = cy.debug.reportLoc(vm.compiler, report);
    out.* = .{
        .kind = switch (report.type) {
            .token_err => C.ReportTokenError,
            .parse_err => C.ReportParseError,
            .compile_err, .context => C.ReportCompileError,
        },
        .msg = C.to_bytes(report.msg),
        .uri = C.to_bytes(loc.uri),
        .has_loc = loc.has_pos,
        .line = loc.line,
        .col = loc.col,
        .len = loc.len,
    };
    return true;
}

fn toReport(vm: *cy.VM, report: cy.Report, kind: C.ReportKind) C.Report {
    const loc = cy.debug.reportLoc(vm.compiler, report);
    return .{
        .kind = kind,
        .msg = C.to_bytes(report.msg),
        .uri = C.to_bytes(loc.uri),
        .has_loc = loc.has_pos,
        .line = loc.line,
        .col = loc.col,
        .end_line = loc.end_line,
        .end_col = loc.end_col,
        .pos = loc.pos,
        .end_pos = loc.end_pos,
    };
}

export fn cl_vm_compile_report_count(vm: *cy.VM) usize {
    // `last_res` rather than the report list alone: the list is only cleared when the next compile starts.
    if (vm.last_res != C.ErrorCompile) {
        return 0;
    }
    return vm.compiler.reports.items.len;
}

export fn cl_vm_compile_report(vm: *cy.VM, idx: usize, out: *C.Report) bool {
    out.* = std.mem.zeroes(C.Report);
    if (idx >= cl_vm_compile_report_count(vm)) {
        return false;
    }
    const report = vm.compiler.reports.items[idx];
    out.* = toReport(vm, report, switch (report.type) {
        .token_err => C.ReportTokenError,
        .parse_err => C.ReportParseError,
        .compile_err, .context => C.ReportCompileError,
    });
    return true;
}

export fn cl_vm_compile_report_note(vm: *cy.VM, idx: usize, note_idx: usize, out: *C.Report) bool {
    out.* = std.mem.zeroes(C.Report);
    if (idx >= cl_vm_compile_report_count(vm)) {
        return false;
    }
    var note: ?*cy.Report = vm.compiler.reports.items[idx].next;
    var i: usize = 0;
    while (note) |n| : (i += 1) {
        if (i == note_idx) {
            out.* = toReport(vm, n.*, C.ReportNote);
            return true;
        }
        note = n.next;
    }
    return false;
}

export fn cl_thread_panic_summary(t: *cy.Thread) C.Bytes {
    if (t.c.panic_type == vmc.PANIC_NONE) {
        return C.NullStr;
    }
    const summary = cy.debug.allocLastUserPanicError(t) catch return C.NullStr;
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
    return vm.findType(C.from_bytes(spec)) catch null;
}

export fn clExpandTypeTemplate(vm: *cy.VM, ctemplate: ?*C.Sym, types_ptr: [*]const *cy.Type, args_ptr: [*]const cy.Value, nargs: usize) ?*cy.Type {
    const template = cy.Sym.fromC(ctemplate).cast(.template);
    const args = args_ptr[0..nargs];
    const param_types = types_ptr[0..nargs];
    return vm.expandTypeTemplate(template, param_types, args) catch |err| {
        // During a compile (a module loader or a type creator calling in), the compile fails with this.
        vm.compiler.host_error = err;
        return null;
    };
}

export fn cl_mod_add_type(mod: *C.Sym, name: C.Bytes, binding: C.BindType) void {
    const c: *cy.sym.Chunk = @ptrCast(@alignCast(mod));
    c.chunk.host_types.put(c.chunk.alloc, C.from_bytes(name), binding) catch |err| {
        // No way to return it from here. The compile that is loading this module fails with it.
        c.chunk.compiler.host_error = err;
    };
}

export fn cl_mod_add_func(mod: *C.Sym, name: C.Bytes, binding: C.BindFunc) void {
    const c: *cy.sym.Chunk = @ptrCast(@alignCast(mod));
    c.chunk.host_funcs.put(c.chunk.alloc, C.from_bytes(name), binding) catch |err| {
        // No way to return it from here. The compile that is loading this module fails with it.
        c.chunk.compiler.host_error = err;
    };
}

export fn cl_mod_set_fallback_func(mod: *C.Sym, binding: C.BindFunc) void {
    const c: *cy.sym.Chunk = @ptrCast(@alignCast(mod));
    c.chunk.fallback_bind_func = binding;
}

export fn cl_mod_add_global(mod: *C.Sym, name: C.Bytes, binding: C.BindGlobal) void {
    const c: *cy.sym.Chunk = @ptrCast(@alignCast(mod));
    c.chunk.host_globals.put(c.chunk.alloc, C.from_bytes(name), binding) catch |err| {
        // No way to return it from here. The compile that is loading this module fails with it.
        c.chunk.compiler.host_error = err;
    };
}

export fn cl_mod_on_destroy(mod: *C.Sym, on_destroy: C.ModuleOnDestroyFn) void {
    const c: *cy.sym.Chunk = @ptrCast(@alignCast(mod));
    c.chunk.on_destroy = on_destroy;
}

export fn cl_mod_on_load(mod: *C.Sym, on_load: C.ModuleOnLoadFn) void {
    const c: *cy.sym.Chunk = @ptrCast(@alignCast(mod));
    c.chunk.on_load = on_load;
}

// `CLValue` is a `uint64_t` in the header. An `extern union` passed by value has another ABI on wasm32, so the
// exports take and return the 64-bit pattern.
export fn cl_thread_release(t: *cy.Thread, val: u64) void {
    t.heap.release(.{ .val = val });
}

export fn cl_thread_retain(t: *cy.Thread, val: u64) void {
    t.heap.retain(.{ .val = val });
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

export fn cl_array_empty(t: *cy.Thread, array_t: *cy.Type) u64 {
    return (t.heap.newEmptyArray(array_t.id()) catch fatal()).val;
}

export fn cl_map_empty(t: *cy.Thread, map_t: *cy.Type) u64 {
    return (t.heap.allocMapZero(map_t.id()) catch fatal()).val;
}

export fn cl_new_func_union(t: *cy.Thread, union_t: *cy.Type, func: C.HostFn) u64 {
    return (t.heap.allocHostFuncUnion(union_t.id(), @ptrCast(func)) catch fatal()).val;
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

export fn cl_lift(t: *cy.Thread, type_: *cy.Type, value: *anyopaque) u64 {
    const res = t.heap.new_object_undef(type_.id(), type_.size()) catch @panic("error");
    const dst: [*]u8 = @ptrCast(res);
    const src: [*]u8 = @ptrCast(value);
    @memcpy(dst[0..type_.size()], src[0..type_.size()]);
    return Value.initPtr(res).val;
}

export fn cl_error(vm: *cy.VM, name: C.Bytes) u64 {
    return vm.sema.ensureSymbol(C.from_bytes(name)) catch @panic("error");
}

export fn cl_symbol(vm: *cy.VM, name: C.Bytes) u64 {
    return vm.sema.ensureSymbol(C.from_bytes(name)) catch @panic("error");
}

export fn cl_object_string(t: *cy.Thread, val: u64) C.Bytes {
    const str = t.heap.get_or_buf_print_object(&cy.tempBuf, .{ .val = val }) catch cy.fatal();
    return C.to_bytes(str);
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

export fn cl_version() C.Bytes {
    return C.to_bytes(build_config.version);
}

export fn cl_build() C.Bytes {
    return C.to_bytes(build_config.build);
}

export fn cl_commit() C.Bytes {
    return C.to_bytes(build_config.commit);
}

comptime {
    @export(&cy.compiler.default_resolver, .{ .name = "cl_default_resolver", .linkage = .strong });
    @export(&cy.compiler.default_loader, .{ .name = "cl_default_loader", .linkage = .strong });
}

export fn cl_strlen(s: [*:0]const u8) usize {
    return std.mem.len(s);
}

test {
    _ = @import("lib_test/api.zig");
    _ = @import("lib_test/session.zig");
    _ = @import("lib_test/limits.zig");
    _ = @import("lib_test/compile.zig");
    _ = @import("lib_test/runtime.zig");
    _ = @import("lib_test/alloc_fail.zig");
    _ = @import("lib_test/format.zig");
    _ = @import("lib_test/await.zig");
}
