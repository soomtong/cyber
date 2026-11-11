const std = @import("std");
const builtin = @import("builtin");
const cy = @import("cyber.zig");
const log = cy.log.scoped(.bc_gen);
const ir = cy.ir;
const sema = cy.sema;
const cc = @import("capi.zig");
const types = cy.types;
const bt = types.BuiltinTypes;
const v = cy.fmt.v;
const vmc = cy.vmc;
const ast = cy.ast;
const bc = @This();
const Root = @This();

pub const Reg = u16;
const TypeId = types.TypeId;

const Chunk = cy.chunk.Chunk;

const emit_nop = true;

pub const VtableKey = packed struct {
    type: cy.TypeId,
    trait: cy.TypeId,
};

const Intrinsic = enum {
    null,
    dtor_str,
    cmp_str,
    copy_str,
};

pub fn genAll(c: *cy.Compiler) !void {
    // Prepare types.
    for (c.newTypes(), c.type_start..) |stype, typeId| {
        _ = typeId;
    
        if (stype.kind() == .null) {
            // Skip placeholders.
            continue;
        }
        log.tracev("prep type: {s}", .{stype.name()});

        switch (stype.kind()) {
            .eval_ref,
            .eval_int,
            .c_variadic,
            .c_union,
            .never,
            .generic_vector,
            .generic,
            .generic_trait,
            .struct_t,
            .dyn_trait,
            .borrow_trait,
            .ref_trait,
            .void,
            .bool,
            .raw,
            .int,
            .float,
            .partial_vector,
            .vector,
            .option,
            .result,
            .func,
            .func_sym,
            .func_ptr,
            .choice,
            .pointer,
            .borrow,
            .ex_borrow,
            .enum_t => {},
            .null,
            .bare => {
                return error.Unexpected;
            },
        }
    }

    // Register intrinsics.
    c.sema.str_t.dtor.?.info.gen_intrinsic = @backingInt(Intrinsic.dtor_str);
    (try sema.getEqFunc(c.main_chunk, c.sema.str_t, null)).info.gen_intrinsic = @backingInt(Intrinsic.cmp_str);
    if (c.sema.str_t.copy_ctor) |copy_ctor| {
        if (!c.sema.str_t.info.copy_user) {
            copy_ctor.info.gen_intrinsic = @backingInt(Intrinsic.copy_str);
        }
    }

    for (c.newChunks()) |chunk| {
        log.tracev("prep chunk", .{});

        // Perform big allocation for instruction buffer for more consistent heap allocation.
        try chunk.buf.ops.ensureTotalCapacityPrecise(c.alloc, 4096 / 2);

        for (chunk.syms.items) |sym| {
            try prepareSym(c, sym);
        }
        for (chunk.funcs.items) |func| {
            try prepareFunc(c, func);
        }
    }

    for (c.newChunks()) |chunk| {
        for (chunk.syms.items) |sym| {
            switch (sym.type) {
                .type => {
                    const type_sym = sym.cast(.type);
                    if (type_sym.type.kind() == .struct_t) {
                        // rt funcs have been reserved. Create impl vtables.
                        const struct_t = type_sym.type.cast(.struct_t);
                        for (struct_t.impls()) |impl| {
                            // Reserved first, so that a vtable that was allocated is always handed to `vm.vtables`.
                            try c.vm.vtables.ensureUnusedCapacity(c.alloc, 1);
                            try c.gen_vtables.ensureUnusedCapacity(c.alloc, 1);
                            const vtable = try c.alloc.alloc(u64, impl.funcs.len);
                            const vtable_idx = c.vm.vtables.items.len;
                            c.vm.vtables.appendAssumeCapacity(vtable);
                            c.gen_vtables.putAssumeCapacity(VtableKey{ .type = struct_t.base.id(), .trait = impl.trait.base.id() }, @intCast(vtable_idx));
                        }
                    }
                },
                else => {},
            }
        }
    }

    for (c.newChunks()) |chunk| {
        log.tracev("Perform codegen for chunk{}: {s}", .{chunk.id, chunk.srcUri});

        try sema.pushChunkResolveContext(chunk, @ptrCast(chunk.ast.root));
        defer sema.popResolveContext(chunk);

        try genChunk(chunk);
        log.tracev("Done. performChunkCodegen {s}", .{chunk.srcUri});
    }

    // Perform static relocations.
    for (c.newChunks()) |chunk| {
        for (chunk.relocations.items) |rel| {
            const ptr: *align(2) [6]u8 = @ptrCast(&chunk.buf.ops.items[rel.pc]);
            switch (rel.kind) {
                .extern_func_ptr => {
                    return error.Unexpected;
                },
                .func => {
                    const addr: u48 = @intCast(@intFromPtr(c.genSymMap.get(rel.data.func).?.func.static_pc));
                    std.mem.writeInt(u48, ptr, addr, .little);
                },
                .global => {
                    const addr: u48 = @intCast(@intFromPtr(c.vm.globals.items[rel.data.global].value.ptr));
                    std.mem.writeInt(u48, ptr, addr, .little);
                },
            }
        }

        for (chunk.syms.items) |sym| {
            switch (sym.type) {
                .type => {
                    const type_sym = sym.cast(.type);
                    if (type_sym.type.kind() == .struct_t) {
                        const struct_t = type_sym.type.cast(.struct_t);
                        for (struct_t.impls()) |impl| {
                            const vtable_idx = c.gen_vtables.get(VtableKey{ .type = struct_t.base.id(), .trait = impl.trait.base.id() }).?;
                            const vtable = c.vm.vtables.items[vtable_idx];
                            for (impl.funcs, 0..) |func, i| {
                                var ptr: u64 = @intFromPtr(&chunk.buf.ops.items[c.genSymMap.get(func).?.func.pc]);
                                if (func.type == .hostFunc) {
                                    ptr |= 1 << 63;
                                }
                                vtable[i] = ptr;
                            }
                        }
                    }
                },
                else => {},
            }
        }
    }

    // Update runtime type info.
    if (cy.Trace) {
        c.vm.c.rw_lock.write_lock();
        defer c.vm.c.rw_lock.write_unlock();

        if (c.vm.types.items.len == 0) {
            // Reserve null type.
            try c.vm.types.ensureUnusedCapacity(c.alloc, 1);
            const name = try c.alloc.dupe(u8, "<null>");
            c.vm.types.appendAssumeCapacity(.{ .name_ptr = name.ptr, .name_len = name.len });
        }
        // Reserved first, so that a name that was allocated is always handed to `vm.types`.
        try c.vm.types.ensureUnusedCapacity(c.alloc, c.newTypes().len);
        for (c.newTypes()) |type_| {
            const name = try c.sema.allocTypeName(type_);
            c.vm.types.appendAssumeCapacity(.{ .name_ptr = name.ptr, .name_len = name.len });
        }

        c.vm.c.types_ptr = @ptrCast(c.vm.types.items.ptr);
        c.vm.c.types_len = c.vm.types.items.len;
    }

    for (c.newChunks()) |chunk| {
        chunk.rt_ready = true;
    }
}

fn prepareSym(c: *cy.Compiler, sym: *cy.Sym) !void {
    log.tracev("prep sym: {s}", .{sym.name()});
    switch (sym.type) {
        .hostVar, .extern_var, .userVar => {
            // Reserved first, so that a global that was created is always handed to `vm.globals`, its owner.
            try c.vm.globals.ensureUnusedCapacity(c.alloc, 1);
            try c.genSymMap.ensureUnusedCapacity(c.alloc, 1);
        },
        else => {},
    }
    switch (sym.type) {
        .hostVar => {
            const id = c.vm.globals.items.len;
            const global_sym = try c.alloc.create(cy.vm.GlobalSym);
            var val: []align(8) u8 = &.{};
            val.ptr = @ptrCast(@alignCast(sym.cast(.hostVar).val.?));
            global_sym.* = .init(val, sym);
            c.vm.globals.appendAssumeCapacity(global_sym);
            c.genSymMap.putAssumeCapacityNoClobber(sym, .{ .varSym = .{ .id = @intCast(id) }});
        },
        .extern_var => {
            const id = c.vm.globals.items.len;
            const global_sym = try c.alloc.create(cy.vm.GlobalSym);
            // value ptr is relocated at runtime.
            global_sym.* = .init(&.{}, sym);
            c.vm.globals.appendAssumeCapacity(global_sym);
            c.genSymMap.putAssumeCapacityNoClobber(sym, .{ .varSym = .{ .id = @intCast(id) }});
        },
        .userVar => {
            const id = c.vm.globals.items.len;
            const global_sym = try c.alloc.create(cy.vm.GlobalSym);
            errdefer c.alloc.destroy(global_sym);
            const global_t = sym.getValueType().?;
            const value = try c.alloc.alignedAlloc(u8, .@"8", global_t.size());
            global_sym.* = .init(value, sym);
            c.vm.globals.appendAssumeCapacity(global_sym);
            c.genSymMap.putAssumeCapacityNoClobber(sym, .{ .varSym = .{ .id = @intCast(id) }});
        },
        .func,
        .const_,
        .template,
        .func_template,
        .ct_value,
        .type,
        .type_const,
        .chunk,
        .field,
        .variant_func,
        .variant_member,
        .enum_case,
        .choice_case,
        .union_case,
        .type_alias,
        .use_alias,
        .module_alias => {},
        else => {
            log.tracev("{}", .{sym.type});
            return error.Unsupported;
        }
    }
}

pub fn prepareFunc(c: *cy.Compiler, func: *cy.Func) !void {
    switch (func.type) {
        .unresolved,
        .reserved,
        .vm_extern_variant,
        .host_builtin,
        .host_const_eval,
        .generic,
        .trait => return,
        .userLambda => {
            if (cy.Trace) {
                const symPath = try cy.sym.allocSymName(&c.sema, c.alloc, func.parent, .{});
                defer c.alloc.free(symPath);
                log.tracev("prep lambda in: {s}", .{symPath});
            }
            _ = try ensureFunc(c, func);
        },
        .hostFunc => {
            if (cy.Trace) {
                const symPath = try cy.sym.allocSymName(&c.sema, c.alloc, func.parent, .{});
                defer c.alloc.free(symPath);
                log.tracev("prep func: {s}", .{symPath});
            }
            const rtFunc = cy.vm.FuncSymbol.initHostFunc(@ptrCast(func.data.hostFunc.ptr));
            const id = try ensureFunc(c, func);
            try c.vm.host_funcs.put(c.alloc, @constCast(@ptrCast(func.data.hostFunc.ptr)), id);
            if (c.vm.funcSyms.items[id].type == .null) {
                completeFunc(c, id, func, rtFunc);
            }
        },
        .userFunc => {
            if (cy.Trace) {
                const symPath = try cy.sym.allocSymName(&c.sema, c.alloc, func.parent, .{});
                defer c.alloc.free(symPath);
                log.tracev("prep func: {s}", .{symPath});
            }
            _ = try ensureFunc(c, func);
            // Func is patched later once funcPc and stackSize is obtained.
        },
        .extern_ => {
            _ = try ensureExternFunc(c, func);
        },
    }
}

pub const ExternFunc = struct {
    id: u32,
    vm_id: u32,

    // For externs with user implementation.
    vm_pc: u32,
};

pub fn ensureExternFunc(c: *cy.Compiler, func: *cy.Func) !ExternFunc {
    const res = try c.genSymMap.getOrPut(c.alloc, func);
    if (!res.found_existing) {
        const id = try c.vm.addFunc(func, func.name(), func.sig, cy.vm.FuncSymbol.initNull());
        const vm_id = try c.vm.addFunc(func, func.name(), func.sig, cy.vm.FuncSymbol.initNull());
        res.value_ptr.* = .{ .extern_func = .{ .id = id, .vm_id = vm_id, .vm_pc = cy.NullId }};
    }
    return res.value_ptr.extern_func;
}

pub fn ensureFunc(c: *cy.Compiler, func: *cy.Func) !u32 {
    const res = try c.genSymMap.getOrPut(c.alloc, func);
    if (!res.found_existing) {
        const id = try c.vm.addFunc(func, func.name(), func.sig, cy.vm.FuncSymbol.initNull());
        res.value_ptr.* = .{ .func = .{ .static_pc = undefined, .id = id, .pc = 0, .end_pc = 0 }};
    }
    return res.value_ptr.func.id;
}

pub fn ensureExternFuncPtrDispatch(c: *cy.Compiler, func_ptr: *cy.types.FuncPtr) !u32 {
    const res = try c.genSymMap.getOrPut(c.alloc, func_ptr);
    if (!res.found_existing) {
        const id = try c.vm.addFunc(null, "extern_func_ptr", func_ptr.sig, cy.vm.FuncSymbol.initNull());
        res.value_ptr.* = .{ .func = .{ .static_pc = undefined, .id = id, .pc = 0, .end_pc = 0 }};
    }
    return res.value_ptr.func.id;
}

pub fn completeFunc(c: *cy.Compiler, id: u32, func: *cy.Func, sym: cy.vm.FuncSymbol) void {
    log.tracev("complete func gen: {s} {}", .{func.name(), id});
    if (c.vm.funcSyms.items[id].type != .null) {
        std.debug.panic("Func already completed: {s} {}", .{func.name(), id});
    }
    c.vm.funcSyms.items[id] = sym;
}

fn genChunk(c: *Chunk) !void {
    genChunkInner(c) catch |err| {
        if (err != error.CompileError) {
            // Wrap all other errors as a CompileError.
            return c.reportErrorFmt("error.{}", &.{v(err)}, c.curNode);
        } else return err;
    };
}

fn genStmts(c: *Chunk, head: ?*ir.Stmt) !void {
    const cold = stmts_end_in_never(head);
    if (cold) c.cold_depth += 1;
    defer if (cold) {
        c.cold_depth -= 1;
    };
    var stmt_opt = head;
    while (stmt_opt) |stmt| {
        try genStmt(c, stmt);
        stmt_opt = stmt.next;
    }
}

/// Whether a statement list ends with a call that does not return (`never`), like `panic`. Such a block is an
/// error path that runs at most once, so calls in it are not worth inlining. A loop in the list keeps it hot.
fn stmts_end_in_never(head: ?*ir.Stmt) bool {
    var cold = false;
    var stmt_opt = head;
    while (stmt_opt) |stmt| : (stmt_opt = stmt.next) {
        switch (stmt.code) {
            .discard => cold = stmt.cast(.discard).expr.type.id() == bt.Never,
            .pop_locals, .trap, .nop_label, .release => {},
            .loop_block, .forRangeStmt => return false,
            else => cold = false,
        }
    }
    return cold;
}

fn genStmt(c: *Chunk, stmt: *ir.Stmt) anyerror!void {
    const node = stmt.node;
    c.curNode = node;
    if (cy.Trace) {
        // An inlined callee node belongs to another chunk's source.
        const contextStr = if (c.inline_ctx == null) c.encoder.formatTrunc(node) else "<inlined>";
        if (cc.verbose()) {
            log.log("{f}| {s}: `{s}` reg_end={}", .{
                cy.fmt.Repeat{.s=" ", .count=c.indent * 4}, @tagName(stmt.code), contextStr,
                c.cur_proc.reg_end,
            });
        }
    }

    switch (stmt.code) {
        .await_             => try gen_await(c, stmt.cast(.await_), node),
        .block              => try gen_block(c, stmt.cast(.block), node),
        .break_             => try gen_break(c, stmt.cast(.break_), node),
        .breakpoint         => try gen_breakpoint(c, node),
        .suspend_           => try c.pushFCode(.suspend_op, &.{}, node),
        .continue_          => try gen_continue(c, stmt.cast(.continue_), node),
        .declare_local      => try gen_declare_local(c, stmt.cast(.declare_local), node),
        .discard            => try gen_discard(c, stmt.cast(.discard), node),
        .forRangeStmt       => try gen_for_range_stmt(c, stmt.cast(.forRangeStmt), node),
        .funcBlock          => return error.Unexpected,
        .if_block           => try gen_if_block(c, stmt.cast(.if_block), node),
        .loop_block         => try gen_loop_block(c, stmt.cast(.loop_block), node),
        .mainBlock          => return error.Unexpected,
        .nop_label          => try gen_nop_label(c, stmt.cast(.nop_label), node),
        .pop_locals         => try gen_pop_locals(c, stmt.cast(.pop_locals), node),
        .release            => try gen_release(c, stmt.cast(.release), node),
        .ret_expr           => try gen_ret_expr(c, stmt.cast(.ret_expr), node),
        .ret_gen            => try gen_ret_gen(c, stmt.cast(.ret_gen), node),
        .ret                => try gen_ret(c, stmt.cast(.ret), node),
        .setCaptured        => try gen_set_captured(c, stmt.cast(.setCaptured), node),
        .set_deref          => try gen_set_deref(c, stmt.cast(.set_deref), node),
        .set_field          => try gen_set_field(c, stmt.cast(.set_field), node),
        .set_global         => try gen_set_global(c, stmt.cast(.set_global), node),
        .set_local          => try gen_set_local(c, stmt.cast(.set_local), node),
        .set_ret            => try gen_set_ret(c, stmt.cast(.set_ret), node),
        .switch_stmt        => try gen_switch_stmt(c, stmt.cast(.switch_stmt), node),
        .trap               => try gen_trap(c, node),
        .verbose            => try verbose(c, stmt.cast(.verbose), node),
        .yield              => try gen_yield_stmt(c, stmt.cast(.yield), node),
        //         .dumpBytecode => {
        //             try cy.debug.dumpBytecode(c.compiler.vm, null);
        //         },
        else => {
            log.log("{}", .{stmt.code});
            return error.TODO;
        }
    }

    log.tracev("{f}| end {s} reg_end={}", .{
        cy.fmt.Repeat{.s=" ", .count=c.indent * 4}, @tagName(stmt.code),
        c.cur_proc.reg_end,
    });
}

fn genChunkInner(c: *Chunk) !void {
    c.listDataStack.clearRetainingCapacity();

    c.indent = 0;

    for (c.ir.func_blocks.items) |block| {
        if (block.code == .funcBlock) {
            try genFuncBlock(c, block.cast(.funcBlock), block.node);
        } else {
            try mainBlock(c, block.cast(.mainBlock), block.node);
        }
    }

    // Get stable func pcs after final buffer size.
    for (c.ir.func_blocks.items) |block| {
        if (block.code == .funcBlock) {
            const func = block.cast(.funcBlock).func;
            if (func.type == .extern_) {
                std.debug.assert(func.data.extern_.has_impl);
                const res = c.compiler.genSymMap.get(func).?;
                const id = res.extern_func.vm_id;
                const pc = res.extern_func.vm_pc;
                c.vm.funcSyms.items[id].data.func.pc = c.buf.ops.items.ptr + pc;
            } else {
                const res = c.compiler.genSymMap.getPtr(func).?;
                const id = res.func.id;
                res.func.static_pc = c.buf.ops.items.ptr + res.func.pc;
                c.vm.funcSyms.items[id].data.func.pc = c.buf.ops.items.ptr + res.func.pc;
            }
        }
    }

    // Insert debug table entry in order.
    const S = struct {
        fn compare(context: [*]cy.Inst, item: cy.DebugTableEntry) std.math.Order {
            return std.math.order(@intFromPtr(context), @intFromPtr(item.ptr));
        }
    };
    const idx = std.sort.lowerBound(cy.DebugTableEntry, c.compiler.debug_tables.items, c.buf.ops.items.ptr, S.compare);
    try c.compiler.debug_tables.insert(c.alloc, idx, .{
        .chunk = c,
        .ptr = c.buf.ops.items.ptr,
    });
}

fn genExpr(c: *Chunk, expr: *ir.Expr, cstr: Cstr) anyerror!GenValue {
    const node = expr.node;
    if (cy.Trace) {
        c.indent += 1;
        // An inlined callee node belongs to another chunk's source.
        const contextStr = if (c.inline_ctx == null) c.encoder.formatTrunc(node) else "<inlined>";
        if (cc.verbose()) {
            log.log("{f}( {s}: `{s}` {s} reg_end={}", .{
                cy.fmt.Repeat{.s=" ", .count=c.indent * 4}, @tagName(expr.code), contextStr, @tagName(cstr.type),
                c.cur_proc.reg_end,
            });
        }
    }

    const res = try switch (expr.code) {
        .add                => gen_add(c, expr.cast(.add), cstr, node),
        .address_of         => gen_addr_of(c, expr.cast(.address_of), cstr, node),
        .asr                => gen_asr(c, expr.cast(.asr), cstr, node),
        .and_op             => gen_and(c, expr.cast(.and_op), cstr, node),
        .binary_op          => genBinOp(c, expr.cast(.binary_op), cstr, node),
        .bitcast            => gen_bitcast(c, expr.cast(.bitcast), cstr, node),
        .call               => gen_call(c, expr.cast(.call), cstr, node),
        .call_ptr           => gen_call_ptr(c, expr.cast(.call_ptr), cstr, node),
        .call_union         => gen_call_union(c, expr.cast(.call_union), cstr, node),
        .call_trait         => gen_call_trait(c, expr.cast(.call_trait), cstr, node),
        .captured           => gen_captured(c, expr.cast(.captured), cstr, node),
        .case               => gen_case(c, expr.cast(.case), cstr, node),
        .cast               => gen_cast(c, expr.cast(.cast), cstr, node),
        .cmp                => genCompare(c, expr.cast(.cmp), cstr, node),
        .const8             => gen_const8(c, expr.cast(.const8), cstr, node),
        .const16            => gen_const16(c, expr.cast(.const16), cstr, node),
        .const32            => gen_const32(c, expr.cast(.const32), cstr, node),
        .const64            => gen_const64(c, expr.cast(.const64), cstr, node),
        .deref              => gen_deref(c, expr.cast(.deref), cstr, node),
        .div                => gen_width_binop(c, expr.cast(.div), .div, false, cstr, node),
        .f2i                => gen_f2i(c, expr.cast(.f2i), cstr, node),
        .fabs               => gen_fabs(c, expr.cast(.fabs), cstr, node),
        .fadd               => gen_fadd(c, expr.cast(.fadd), cstr, node),
        .falsev             => gen_false(c, cstr, node),
        .fdiv               => gen_fdiv(c, expr.cast(.fdiv), cstr, node),
        .field              => gen_field(c, expr.cast(.field), cstr, node),
        .fmod               => gen_fmod(c, expr.cast(.fmod), cstr, node),
        .fmul               => gen_fmul(c, expr.cast(.fmul), cstr, node),
        .fneg               => gen_fneg(c, expr.cast(.fneg), cstr, node),
        .fsub               => gen_fsub(c, expr.cast(.fsub), cstr, node),
        .func_ptr           => gen_funcptr(c, expr.cast(.func_ptr), cstr, node),
        .func               => genFuncUnion(c, expr.cast(.func), cstr, node),
        .gen_end            => gen_gen_end(c, expr.cast(.gen_end), cstr, node),
        .gen_next           => gen_gen_next(c, expr.cast(.gen_next), cstr, node),
        .fiber_resume       => gen_fiber_resume(c, expr.cast(.fiber_resume), cstr, node),
        .global             => gen_global(c, expr.cast(.global), cstr, node),
        .i2f                => gen_i2f(c, expr.cast(.i2f), cstr, node),
        .idiv               => gen_width_binop(c, expr.cast(.idiv), .idiv, true, cstr, node),
        .imod               => gen_width_binop(c, expr.cast(.imod), .imod, true, cstr, node),
        .imul               => genBinOp2(c, expr.cast(.imul), .imul, cstr, node),
        .init               => gen_init(c, expr.cast(.init), cstr, node),
        .init_case          => gen_init_case(c, expr.cast(.init_case), cstr, node),
        .init_zero          => gen_init_zero(c, expr.cast(.init_zero), cstr, node),
        .is_zero            => genIsZero(c, expr.cast(.is_zero), cstr, node),
        .lambda             => gen_lambda(c, expr.cast(.lambda), cstr, node),
        .lift               => gen_lift(c, expr.cast(.lift), cstr, node),
        .local              => gen_local(c, expr.cast(.local), cstr, node),
        .lsl                => genBinOp2(c, expr.cast(.lsl), .lsl, cstr, node),
        .lsr                => gen_width_binop(c, expr.cast(.lsr), .lsr, false, cstr, node),
        .mod                => gen_width_binop(c, expr.cast(.mod), .mod, false, cstr, node),
        .mul                => genBinOp2(c, expr.cast(.mul), .mul, cstr, node),
        .neg                => genUnOp2(c, expr.cast(.neg), .neg, cstr, node),
        .not                => genUnOp2(c, expr.cast(.not), .not, cstr, node),
        .or_op              => genBinOp2(c, expr.cast(.or_op), .or_, cstr, node),
        .retain             => gen_retain(c, expr.cast(.retain), cstr, node),
        .sext               => gen_sext(c, expr.cast(.sext), cstr, node),
        .string             => gen_string(c, expr.cast(.string), cstr, node),
        .sub                => genBinOp2(c, expr.cast(.sub), .sub, cstr, node),
        .trait              => gen_trait(c, expr.cast(.trait), cstr, node),
        .truev              => gen_true(c, cstr, node),
        .trunc              => gen_trunc(c, expr.cast(.trunc), cstr, node),
        .unary_op           => genUnOp(c, expr.cast(.unary_op), cstr, node),
        .undef              => gen_undef(c, expr.cast(.undef), cstr, node),
        .unwrap_addr        => genUnwrapAddr(c, expr.cast(.unwrap_addr), cstr, node),
        .unwrap_nz          => genUnwrapNZ(c, expr.cast(.unwrap_nz), cstr, node),
        .voidv              => gen_void(c, cstr, node),
        .xor                => genBinOp2(c, expr.cast(.xor), .xor, cstr, node),
        .zext               => gen_zext(c, expr.cast(.zext), cstr, node),
        else => {
            log.log("{}", .{expr.code});
            return error.TODO;
        }
    };
    if (cy.Trace) {
        if (cc.verbose()) {
            log.log("{f}) end {s} reg_end={}", .{
                cy.fmt.Repeat{.s=" ", .count=c.indent * 4}, @tagName(expr.code),
                c.cur_proc.reg_end,
            });
        }
        c.indent -= 1;
    }
    return res;
}

fn gen_release(c: *Chunk, stmt: *ir.Release, node: *ast.Node) !void {
    const reg = toLocalReg(c, @intCast(stmt.reg));
    try pushRelease(c, reg, stmt.optional, stmt.deinit_obj, node);
}

fn gen_trap(c: *Chunk, node: *ast.Node) !void {
    if (c.inline_ctx != null) {
        // Unreachable end marker of an inlined body. Returns already jump past it.
        return;
    }
    try c.pushFCode(.trap, &.{}, node);
}

fn gen_nop_label(c: *Chunk, stmt: *ir.NopLabel, node: *ast.Node) !void {
    if (!emit_nop or c.inline_ctx != null) {
        // An inlined callee's label lives in another chunk's IR buffer.
        return;
    }
    const label = c.ir.buf.items[stmt.label_idx..stmt.label_idx + stmt.label_len];
    log.tracev("nop: {s}", .{label});
    try genNopLabel2(c, label, node);
}

fn genNopLabel2(c: *Chunk, label: []const u8, node: *ast.Node) !void {
    const res = try c.buf.getOrPushConstString(label);
    const ptr_len = (@as(u64, @intFromPtr(res.slice.ptr)) & 0xffffffffffff) | (@as(u64, res.slice.len) << 48);
    const pc = c.buf.ops.items.len;
    try c.pushCode(.nops, &.{ 0, 0, 0, 0 }, node);
    c.buf.setOpArgU64(pc + 1, ptr_len);
}

fn mainBlock(c: *Chunk, stmt: *ir.MainBlock, node: *ast.Node) !void {
    log.tracev("main block:", .{});

    try pushProc(c, .main, c.id, null, "main", node);

    try reserveMainRegs(c);

    const main_pc = c.buf.ops.items.len;

    var child_opt = stmt.bodyHead;
    while (child_opt) |child| {
        try genStmt(c, child);
        child_opt = child.next;
    }

    try mainEnd(c, node);
    // Read before `popProc`. Afterwards `cur_proc` still points at the popped slot, which safe builds
    // overwrite with undefined bytes (a 0xAAAA = 43690-slot main stack).
    c.buf.mainStackSize = c.getMaxUsedRegisters();
    try popProc(c);

    c.buf.main_pc = @intCast(main_pc);
}

pub fn genFuncBlock(c: *Chunk, stmt: *ir.FuncBlock, node: *ast.Node) !void {
    const func = stmt.func;

    // Skip if marked as skip (usually for one-off compile-time functions)
    if (stmt.skip) {
        return;
    }

    // Reserve a nop32 inst to hold a function id to access debug info.
    const header_pc = c.buf.ops.items.len;
    try c.buf.pushOpSlice(.nop32, &.{0, 0});

    const pc = c.buf.ops.items.len;
    try c.buf.markers.put(c.alloc, @intCast(pc), func);

    var id: u32 = undefined;
    if (func.type == .extern_) {
        std.debug.assert(func.data.extern_.has_impl);
        const entry = try ensureExternFunc(c.compiler, func);
        id = entry.vm_id;
        c.compiler.genSymMap.getPtr(func).?.extern_func.vm_pc = @intCast(pc);
    } else {
        id = try ensureFunc(c.compiler, func);
        c.compiler.genSymMap.getPtr(func).?.func.pc = @intCast(pc);
    }
    c.buf.setOpArgU32(header_pc + 1, id);
    c.vm.log_tracev("gen {s} {}", .{stmt.func.name(), id});
    
    std.debug.assert(c.vm.funcSyms.items[id].type == .null);

    const params = stmt.params[0..func.sig.params_len];

    try pushFuncBlock(c, stmt, params, node);

    const chk_stk_pc = c.buf.ops.items.len;
    try c.buf.func_table.append(c.alloc, chk_stk_pc);
    try c.pushFCode(.chk_stk, &.{ 0, 0 }, node);

    try genStmts(c, stmt.bodyHead);

    c.buf.ops.items[chk_stk_pc + 1].val = c.cur_proc.ret_size;

    const stack_size = c.getMaxUsedRegisters();
    c.buf.ops.items[chk_stk_pc + 2].val = stack_size;

    // The generator's heap frame must cover every register the body uses, not just the params that were
    // reserved when `ret_gen` was emitted. Locals, loop state and temps live across `yield`.
    if (c.cur_proc.ret_gen_pc) |ret_gen_pc| {
        c.buf.ops.items[ret_gen_pc + 3].val = stack_size;
    }

    if (func.type != .extern_) {
        c.compiler.genSymMap.getPtr(func).?.func.end_pc = @intCast(c.buf.ops.items.len);
    }

    const rt_func = cy.vm.FuncSymbol.initFunc(undefined);
    completeFunc(c.compiler, id, func, rt_func);
    try popFuncBlockCommon(c, func);
}

fn gen_breakpoint(c: *Chunk, node: *ast.Node) !void {
    try c.pushFCode(.trap_debug, &.{}, node);
}

fn gen_await(c: *Chunk, stmt: *ir.Await, node: *ast.Node) !void {
    const childv = try genExpr(c, stmt.expr, Cstr.localOrTemp());
    try c.pushFCode(.await_op, &.{childv.reg}, node);
    try pop_temp_value(c, childv, node);
}

fn gen_yield_stmt(c: *Chunk, stmt: *ir.Yield, node: *ast.Node) !void {
    const pc = c.buf.ops.items.len;
    try c.pushCode(.ret_y, &.{@intCast(stmt.ret_opt_t.reg_size()), 0, @intFromBool(stmt.end)}, node);
    try genStmts(c, stmt.deinit_head);
    c.buf.ops.items[pc + 2].val = @intCast(c.buf.ops.items.len - pc);
}

fn gen_gen_next(c: *Chunk, expr: *ir.GenNext, cstr: Cstr, node: *ast.Node) !GenValue {
    // Assumes expr.base.type is the option next type.
    const inst = try beginCall(c, cstr, expr.base.type, false, node);
    const gen = try genExpr(c, expr.gen, Cstr.localOrTemp());
    const pc = c.buf.ops.items.len;
    try c.pushFCode(.gen_next, &.{inst.ret.reg, inst.base, gen.reg}, node);
    try push_site_ptr_layout(c, pc);
    try pop_temp_value(c, gen, node);
    return endCall(c, inst, expr.base.type, node);
}

/// `dst = resume(fiber)`. The fiber runs on its own stack, so this frame is not under a callee frame and
/// needs no pointer layout: its stack can not grow until the fiber gives control back.
fn gen_fiber_resume(c: *Chunk, expr: *ir.UnOp2, cstr: Cstr, node: *ast.Node) !GenValue {
    const dst = try bc.selectReg(c, expr.base.type, cstr, node);
    const fiber = try genExpr(c, expr.expr, Cstr.localOrTemp());
    try c.pushFCode(.fiber_resume, &.{dst.reg, fiber.reg}, node);
    try pop_temp_value(c, fiber, node);
    return dst;
}

fn gen_gen_end(c: *Chunk, expr: *ir.GenEnd, cstr: Cstr, node: *ast.Node) !GenValue {
    _ = cstr;
    const gen_t = expr.gen.type.cast(.pointer).child_t;
    const ret_t = gen_t.sym().instance.?.params[0].asPtr(*cy.Type).cast(.func_ptr).sig.ret;
    const next_t = try cy.sema.getOptionType(c, ret_t);

    const gen = try genExpr(c, expr.gen, Cstr.localOrTemp());
    const ret = c.cur_proc.reg_end;
    const pc = c.buf.ops.items.len;
    try c.pushFCode(.gen_end, &.{ret, @intCast(ret + next_t.reg_size()), gen.reg}, node);
    try push_site_ptr_layout(c, pc);
    try pop_temp_value(c, gen, node);
    return GenValue.discard();
}

fn gen_cast(c: *Chunk, expr: *ir.Cast, cstr: Cstr, node: *ast.Node) !GenValue {
    if (!expr.isRtCast) {
        return genExpr(c, expr.expr, cstr);
    }

    const dst = try bc.selectReg(c, expr.base.type, cstr, node);

    // TODO: If inst.dst is a temp, this should have a cstr of localOrExact.
    const childv = try genExpr(c, expr.expr, Cstr.localOrTemp());

    if (types.toRtConcreteType(expr.type)) |type_| {
        const shape_t = type_.pointeeOrSelf();
        try c.pushFCode(.cast, &.{ dst.reg, childv.reg, @intCast(shape_t.id()), @intFromBool(expr.type.isRefPointer()) }, node);
    } else {
        // Cast to abstract type.
        try c.pushFCode(.castAbstract, &.{ dst.reg, childv.reg, @intCast(expr.type.id()) }, node);
    }

    try pop_temp_value(c, childv, node);
    return dst;
} 

fn gen_addr_of(c: *Chunk, expr: *ir.AddressOf, cstr: Cstr, node: *ast.Node) !GenValue {
    return genAddressOf2(c, expr.expr, cstr, node);
}

fn gen_addr_global(c: *Chunk, global: *cy.Sym, cstr: Cstr, node: *ast.Node) !GenValue {
    const global_id = c.compiler.genSymMap.get(global).?.varSym.id;

    const dst = try selectReg(c, c.sema.ptr_void_t, cstr, node);
    if (cy.Trace) {
        var buf: [128]u8 = undefined;
        const label = try std.mem.print(&buf, "&global {s}", .{global.name()});
        try genNopLabel2(c, label, node);
    }
    const pc = c.buf.len();
    try c.pushCode(.const_64, &.{dst.reg, 0, 0, 0, 0}, node);
    if (global.type == .extern_var) {
        try c.rt_relocations.append(c.alloc, .{ .kind = .global, .pc = pc + 2, .data = .{ .global = global_id } });
    } else {
        try c.relocations.append(c.alloc, .{ .kind = .global, .pc = pc + 2, .data = .{ .global = global_id } });
    }
    return dst;
}

fn push_addr(c: *Chunk, dst: Reg, reg: Reg, node: *ast.Node) !void {
    try c.pushCode(.addr, &.{ dst, reg }, node);
}

fn genAddressOf2(c: *Chunk, expr: *ir.Expr, cstr: Cstr, node: *ast.Node) !GenValue {
    switch (expr.code) {
        .global => {
            const data = expr.cast(.global);
            return gen_addr_global(c, data.sym, cstr, node);
        },
        .local => {
            const data = expr.cast(.local);
            const reg = toLocalReg(c, data.id);

            const dst = try selectReg(c, c.sema.ptr_void_t, cstr, node);
            try push_addr(c, dst.reg, reg, node);
            return dst;
        },
        .case => {
            const data = expr.cast(.case);
            return genAddressOfField(c, data.child.cast(.field), cstr, node);
        },
        .field => {
            const data = expr.cast(.field);
            return genAddressOfField(c, data, cstr, node);
        },
        .deref => {
            const deref = expr.cast(.deref);
            return genExpr(c, deref.expr, cstr);
        },
        .call => {
            if (expr.type.isPointer()) {
                return gen_call(c, expr.cast(.call), cstr, node);
            }
            return c.reportError("TODO", node);
        },
        .bitcast => {
            return genAddressOf2(c, expr.cast(.bitcast).expr, cstr, node);
        },
        else => {
            return c.reportErrorFmt("TODO: {}", &.{v(expr.code)}, node);
        },
    }
}

fn genAddressOfField(c: *cy.Chunk, data: *ir.Field, cstr: Cstr, node: *ast.Node) !GenValue {
    const offset = data.rec.type.pointeeOrSelf().fields().?[data.idx].offset;
    const rec = fold_rec_offset(data.rec);

    const dst = try bc.selectReg(c, c.sema.ptr_void_t, cstr, node);

    // A register-aligned field of a local record starts at one of the local's registers.
    if (local_field_base(c, rec.rec, rec.off + offset)) |reg| {
        try push_addr(c, dst.reg, reg, node);
        return dst;
    }

    const rec_t = rec.rec.type;

    // A pointer or borrow (`&T`, `&&T`) record is already an address. A value record needs its address taken.
    var recv: GenValue = undefined;
    if (rec_t.isRefLike()) {
        recv = try genExpr(c, rec.rec, Cstr.localOrTemp());
    } else {
        recv = try genAddressOf2(c, rec.rec, Cstr.localOrTemp(), node);
    }

    try c.pushCode(.add_i16, &.{ dst.reg, recv.reg, @intCast(rec.off + offset)}, node);

    try pop_temp_value(c, recv, node);
    return dst;
}

fn gen_deref(c: *Chunk, expr: *ir.Deref, cstr: Cstr, node: *ast.Node) !GenValue {
    // `(&x).*` of a value local is `x`.
    if (expr.expr.code == .address_of) {
        const inner = expr.expr.cast(.address_of).expr;
        if (inner.code == .local and !inner.type.isRefLike() and inner.type == expr.base.type) {
            return gen_local(c, inner.cast(.local), cstr, node);
        }
    }
    // `p.*` of a pointer param bound to a caller local is that local.
    if (addr_of_local_value(c, expr.expr, expr.base.type)) |src| {
        if (cstr.type == .simple) {
            return GenValue.initLocal(src);
        }
        const dst = try bc.selectReg(c, expr.base.type, cstr, node);
        if (dst.type != .discard) {
            try push_mov(c, dst.reg, src, @intCast(expr.base.type.reg_size()), node);
        }
        return dst;
    }
    const dst = try bc.selectReg(c, expr.base.type, cstr, node);
    const srcv = try genExpr(c, expr.expr, Cstr.localOrTemp());
    try push_load(c, dst.reg, srcv.reg, 0, expr.base.type, node);
    try pop_temp_value(c, srcv, node);
    return dst;
}

fn gen_case(c: *Chunk, expr: *ir.Case, cstr: Cstr, node: *ast.Node) !GenValue {
    _ = node;
    return genExpr(c, expr.child, cstr);
}

const RecOffset = struct {
    rec: *ir.Expr,
    off: usize,
};

fn fold_rec_offset(init_rec: *ir.Expr) RecOffset {
    var rec = init_rec;
    var offset: usize = 0;

    // Check to fold with previous field access.
    while (true) {
        // Stop at a pointer or borrow (`&T`, `&&T`): the fields behind it live elsewhere.
        if (rec.type.isRefLike()) {
            break;
        }
        if (rec.code == .field) {
            const field = rec.cast(.field);
            rec = field.rec;
            offset += rec.type.pointeeOrSelf().fields().?[field.idx].offset;
        } else if (rec.code == .case) {
            rec = rec.cast(.case).child;
        } else if (rec.code == .deref) {
            rec = rec.cast(.deref).expr;
        } else {
            break;
        }
    }
    return .{ .rec = rec, .off = offset };
}

fn gen_field(c: *Chunk, expr: *ir.Field, cstr: Cstr, node: *ast.Node) !GenValue {
    const ret_t = expr.base.type;

    const offset = expr.rec.type.pointeeOrSelf().fields().?[expr.idx].offset;
    const rec = fold_rec_offset(expr.rec);

    // A field of a local record is already in the local's registers.
    if (local_field_reg(c, rec.rec, rec.off + offset, ret_t)) |src| {
        if (cstr.type == .simple) {
            return GenValue.initLocal(src);
        }
        const dst = try bc.selectReg(c, ret_t, cstr, node);
        if (dst.type != .discard) {
            try push_mov(c, dst.reg, src, @intCast(ret_t.reg_size()), node);
        }
        return dst;
    }

    const dst = try bc.selectReg(c, expr.base.type, cstr, node);

    const temp_start = c.cur_proc.reg_end;
    const recv = try genExpr(c, rec.rec, Cstr.localOrTemp());
    var src_ptr = recv.reg;
    if (!rec.rec.type.isRefLike()) {
        src_ptr = try reserve_reg(c, c.sema.ptr_void_t);
        try push_addr(c, src_ptr, recv.reg, node);
    }
    try push_load(c, dst.reg, src_ptr, @intCast(rec.off + offset), ret_t, node);
    try pop_regs(c, temp_start, node);
    return dst;
}

/// A value-typed local keeps its record in registers with the record's memory layout, so a field
/// that covers whole registers (8-byte aligned, a multiple of 8 bytes) is the register at
/// `base + offset / 8`. Reading or writing that register is the same as going through `addr`.
fn local_field_reg(c: *Chunk, rec: *ir.Expr, offset: usize, field_t: *cy.Type) ?Reg {
    const size = field_t.size();
    if (size == 0 or size % 8 != 0) return null;
    return local_field_base(c, rec, offset);
}

/// The register at byte `offset` of a record that lives in registers, when `offset` is register-aligned:
/// a value-typed local, or a pointer param bound to the address of a caller local (`LocalSlot.addr_of`).
fn local_field_base(c: *Chunk, rec: *ir.Expr, offset: usize) ?Reg {
    if (rec.code != .local or offset % 8 != 0) return null;
    const slot = local_slot(c, rec.cast(.local).id);
    if (slot.kind == .reg and rec.type.isRefLike()) return null;
    return slot.reg + @as(Reg, @intCast(offset / 8));
}

/// The caller local a pointer local is bound to, when the whole local can stand in for `*ptr` of `val_t`.
fn addr_of_local_value(c: *Chunk, ptr: *ir.Expr, val_t: *cy.Type) ?Reg {
    if (ptr.code != .local) return null;
    const slot = local_slot(c, ptr.cast(.local).id);
    if (slot.kind != .addr_of) return null;
    const size = val_t.size();
    if (size == 0 or size % 8 != 0) return null;
    return slot.reg;
}

fn gen_lift(c: *Chunk, expr: *ir.Lift, cstr: Cstr, node: *ast.Node) !GenValue {
    const dst = try bc.selectReg(c, expr.base.type, cstr, node);
    if (expr.child.code == .init) {
        const child_t = expr.child.type;
        try push_new(c, dst.reg, child_t, @intCast(child_t.size()), node);
        try gen_init_to(c, dst.reg, expr.child.cast(.init), 0, 0, node);
        return dst;
    } else {
        const src = try genExpr(c, expr.child, Cstr.localOrTemp());
        const child_t = expr.child.type;

        try push_new(c, dst.reg, child_t, @intCast(child_t.size()), node);
        try push_store(c, dst.reg, 0, src.reg, child_t, node);
        try pop_temp_value(c, src, node);
        return dst;
    }
}

fn gen_init_case(c: *Chunk, expr: *ir.InitCase, cstr: Cstr, node: *ast.Node) !GenValue {
    _ = node;
    return genExpr(c, expr.child, cstr);
}

/// Stores the fields through `dst_ptr`. `avoid_start..avoid_end` are the destination registers when the
/// destination is a local; a field value living there is copied out before any field is written.
fn gen_init_to(c: *Chunk, dst_ptr: Reg, expr: *ir.Init, avoid_start: u16, avoid_end: u16, node: *ast.Node) !void {
    const temp_start = c.cur_proc.reg_end;
    const arg_start = c.u16_stack.items.len;
    defer c.u16_stack.items.len = arg_start;
    const args = expr.args[0..expr.nargs];
    for (args) |arg_expr| {
        const arg = try gen_init_arg(c, arg_expr, avoid_start, avoid_end, node);
        try c.u16_stack.append(c.alloc, arg);
    }
    const regs = c.u16_stack.items[arg_start..];

    switch (expr.base.type.kind()) {
        .option => {
            const option_t = expr.base.type.cast(.option);
            const fields = &[_]cy.types.Field{
                option_t.fields()[0],
                .{ .sym = undefined, .type = args[1].type, .offset = 8 },
            };
            try push_struct_init_to(c, dst_ptr, fields, regs, node);
        },
        .choice => {
            const choice_t = expr.base.type.cast(.choice);
            std.debug.assert(args[1].code == .init_case);
            const fields = &[_]cy.types.Field{
                choice_t.fields()[0],
                .{ .sym = undefined, .type = args[1].cast(.init_case).child.type, .offset = 8 },
            };
            try push_struct_init_to(c, dst_ptr, fields, regs, node);
        },
        .c_union => {
            std.debug.assert(args[0].code == .init_case);
            const fields = &[_]cy.types.Field{
                .{ .sym = undefined, .type = args[0].cast(.init_case).child.type, .offset = 0 },
            };
            try push_struct_init_to(c, dst_ptr, fields, regs, node);
        },
        .result => {
            const res_t = expr.base.type.cast(.result);
            std.debug.assert(args[1].code == .init_case);
            const fields = &[_]cy.types.Field{
                res_t.fields()[0],
                .{ .sym = undefined, .type = args[1].cast(.init_case).child.type, .offset = 8 },
            };
            try push_struct_init_to(c, dst_ptr, fields, regs, node);
        },
        .struct_t => {
            const struct_t = expr.base.type.cast(.struct_t);
            try push_struct_init_to(c, dst_ptr, struct_t.fields(), regs, node);
        },
        .partial_vector => {
            const vector_t = expr.base.type.cast(.partial_vector);
            try push_store(c, dst_ptr, 0, regs[0], c.sema.i64_t, node);
            for (0..args.len-1) |i| {
                const offset = 8 + vector_t.elem_t.size() * i;
                try push_store(c, dst_ptr, @intCast(offset), regs[i+1], vector_t.elem_t, node);
            }
        },
        .vector => {
            const vector_t = expr.base.type.cast(.vector);
            for (0..args.len) |i| {
                const offset = vector_t.elem_t.size() * i;
                try push_store(c, dst_ptr, @intCast(offset), regs[i], vector_t.elem_t, node);
            }
        },
        else => {
            return c.reportErrorFmt("Unsupported: {}", &.{v(expr.base.type.kind())}, node);
        },
    }
    try pop_regs(c, temp_start, node);
}

fn gen_init(c: *Chunk, expr: *ir.Init, cstr: Cstr, node: *ast.Node) !GenValue {
    const dst = try selectReg(c, expr.base.type, cstr, node);

    const temp_start = c.cur_proc.reg_end;

    if (dst.type != .discard and try gen_init_regs(c, dst, cstr_is_fresh(cstr), expr, node)) {
        try pop_regs(c, temp_start, node);
        return dst;
    }

    // Reserve reg for dst addr.
    const dst_ptr = try reserve_reg(c, c.sema.ptr_void_t);
    try push_addr(c, dst_ptr, dst.reg, node);

    const dst_end: u16 = @as(u16, dst.reg) + @as(u16, @intCast(expr.base.type.reg_size()));
    try gen_init_to(c, dst_ptr, expr, dst.reg, dst_end, node);

    try pop_regs(c, temp_start, node);
    return dst;
}

/// Writes an `init` whose fields all cover whole registers straight into the destination registers
/// instead of through its address. Returns false when a field is packed or the type is not handled.
fn gen_init_regs(c: *Chunk, dst: GenValue, fresh: bool, expr: *ir.Init, node: *ast.Node) !bool {
    var field_buf: [2]cy.types.Field = undefined;
    const fields = init_fields(expr, &field_buf) orelse return false;
    const args = expr.args[0..expr.nargs];
    if (fields.len != args.len) return false;
    for (fields) |field| {
        const size = field.type.size();
        if (size == 0 or size % 8 != 0 or field.offset % 8 != 0) return false;
    }

    // A temp or a local being declared can not be named by the field expressions. Another local can
    // (`p = {x=p.y, y=p.x}`), so its fields are evaluated first unless every one is a constant or a
    // local outside the destination.
    const dst_end: u16 = @as(u16, dst.reg) + @as(u16, @intCast(expr.base.type.reg_size()));
    var direct = dst.type == .temp or fresh;
    if (!direct) {
        direct = true;
        for (args) |arg| {
            if (!init_arg_is_simple(c, arg, dst.reg, dst_end)) {
                direct = false;
                break;
            }
        }
    }
    if (direct) {
        for (fields, args) |field, arg| {
            const reg = dst.reg + @as(Reg, @intCast(field.offset / 8));
            _ = try genExpr(c, arg, Cstr.toTemp(reg));
        }
        return true;
    }

    const arg_start = c.u16_stack.items.len;
    defer c.u16_stack.items.len = arg_start;
    for (args) |arg| {
        const reg = try gen_init_arg(c, arg, dst.reg, dst_end, node);
        try c.u16_stack.append(c.alloc, reg);
    }
    const regs = c.u16_stack.items[arg_start..];
    for (fields, regs) |field, src| {
        const reg = dst.reg + @as(Reg, @intCast(field.offset / 8));
        try push_mov(c, reg, @intCast(src), @intCast(field.type.reg_size()), node);
    }
    return true;
}

/// The fields an `init` writes, in the order of its args. The payload of an option · choice · result
/// is a field at offset 8.
fn init_fields(expr: *ir.Init, buf: *[2]cy.types.Field) ?[]const cy.types.Field {
    const args = expr.args[0..expr.nargs];
    switch (expr.base.type.kind()) {
        .option => {
            const option_t = expr.base.type.cast(.option);
            buf.* = .{
                option_t.fields()[0],
                .{ .sym = undefined, .type = args[1].type, .offset = 8 },
            };
            return buf;
        },
        .choice => {
            const choice_t = expr.base.type.cast(.choice);
            std.debug.assert(args[1].code == .init_case);
            buf.* = .{
                choice_t.fields()[0],
                .{ .sym = undefined, .type = args[1].cast(.init_case).child.type, .offset = 8 },
            };
            return buf;
        },
        .result => {
            const res_t = expr.base.type.cast(.result);
            std.debug.assert(args[1].code == .init_case);
            buf.* = .{
                res_t.fields()[0],
                .{ .sym = undefined, .type = args[1].cast(.init_case).child.type, .offset = 8 },
            };
            return buf;
        },
        .c_union => {
            std.debug.assert(args[0].code == .init_case);
            buf[0] = .{ .sym = undefined, .type = args[0].cast(.init_case).child.type, .offset = 0 };
            return buf[0..1];
        },
        .struct_t => {
            return expr.base.type.cast(.struct_t).fields();
        },
        else => return null,
    }
}

/// A destination the expression being generated can not name: a temp, or a local being declared.
fn cstr_is_fresh(cstr: Cstr) bool {
    return cstr.type == .tempReg or (cstr.type == .localReg and cstr.data.slot.fresh);
}

/// A constant or a local outside `dst..dst_end`: evaluating it can not observe an earlier field write.
fn init_arg_is_simple(c: *Chunk, arg: *ir.Expr, dst: Reg, dst_end: u16) bool {
    switch (arg.code) {
        .const8, .const16, .const32, .const64, .truev, .falsev, .voidv => return true,
        .init_case => return init_arg_is_simple(c, arg.cast(.init_case).child, dst, dst_end),
        .local => {
            const slot = local_slot(c, arg.cast(.local).id);
            // A pointer param bound to a caller local materializes as `addr`, which reads no register.
            if (slot.kind == .addr_of) return true;
            const end: u16 = @as(u16, slot.reg) + @as(u16, @intCast(arg.type.reg_size()));
            return end <= dst or slot.reg >= dst_end;
        },
        else => return false,
    }
}

/// Evaluates an `init` field. A local inside the destination registers is copied first so that a
/// field written before it can not change it.
fn gen_init_arg(c: *Chunk, arg: *ir.Expr, avoid_start: u16, avoid_end: u16, node: *ast.Node) !Reg {
    const argv = try genExpr(c, arg, Cstr.localOrTemp());
    if (argv.type == .local) {
        const end: u16 = @as(u16, argv.reg) + @as(u16, @intCast(arg.type.reg_size()));
        if (argv.reg < avoid_end and end > avoid_start) {
            const temp = try reserve_reg(c, arg.type);
            try push_mov(c, temp, argv.reg, @intCast(arg.type.reg_size()), node);
            return temp;
        }
    }
    return argv.reg;
}

fn gen_init_zero(c: *Chunk, expr: *ir.InitZero, cstr: Cstr, node: *ast.Node) !GenValue {
    const dst = try bc.selectReg(c, expr.base.type, cstr, node);

    const dst_ptr = try reserve_reg(c, c.sema.ptr_void_t);
    try push_addr(c, dst_ptr, dst.reg, node);

    try c.pushCode(.memsetz, &.{ dst_ptr, 0, @intCast(expr.size) }, node);

    try pop_regs(c, dst_ptr, node);
    return dst;
}

fn gen_break(c: *Chunk, stmt: *ir.Break, node: *ast.Node) !void {
    const pc = try c.pushEmptyJump(node);
    const offset = stmt.block_offset + inline_block_base(c);
    try c.blockJumpStack.append(c.alloc, .{ .jumpT = .brk, .pc = pc, .block_offset = offset });
}

fn gen_continue(c: *Chunk, stmt: *ir.Continue, node: *ast.Node) !void {
    const pc = try c.pushEmptyJump(node);
    const offset = stmt.block_offset + inline_block_base(c);
    try c.blockJumpStack.append(c.alloc, .{ .jumpT = .cont, .pc = pc, .block_offset = offset });
}

/// IR block offsets count from the callee's function block. An inlined body starts deeper in the caller.
fn inline_block_base(c: *Chunk) u32 {
    return if (c.inline_ctx) |ctx| ctx.block_base else 0;
}

fn gen_set_deref(c: *Chunk, stmt: *ir.SetDeref, node: *ast.Node) !void {
    // `p.* = v` of a pointer param bound to a caller local assigns that local.
    if (addr_of_local_value(c, stmt.ptr, stmt.right.type)) |dst| {
        _ = try genExpr(c, stmt.right, Cstr.toLocal(dst));
        return;
    }
    const ptrv = try genExpr(c, stmt.ptr, Cstr.localOrTemp());
    const rightv = try genExpr(c, stmt.right, Cstr.localOrTemp());
    const right_t = stmt.right.type;

    try push_store(c, ptrv.reg, 0, rightv.reg, right_t, node);
    try pop_temp_value(c, rightv, node);
    try pop_temp_value(c, ptrv, node);
}

fn gen_set_field(c: *Chunk, stmt: *ir.SetField, node: *ast.Node) !void {
    const fieldData = stmt.field.cast(.field);

    // const rec_is_pointer = c.sema.isPointerType(type_id);

    const val_t = stmt.field.type;

    const offset = fieldData.rec.type.pointeeOrSelf().fields().?[fieldData.idx].offset;
    const rec = fold_rec_offset(fieldData.rec);

    // A field of a local record is one of the local's registers, assigned like a local.
    if (local_field_reg(c, rec.rec, rec.off + offset, val_t)) |dst| {
        _ = try genExpr(c, stmt.right, Cstr.toLocal(dst));
        return;
    }

    const temp_start = c.cur_proc.reg_end;
    var dst_ptr: GenValue = undefined;

    if (!rec.rec.type.isRefLike()) {
        dst_ptr = try genAddressOf2(c, rec.rec, Cstr.localOrTemp(), node);
    } else {
        dst_ptr = try genExpr(c, rec.rec, Cstr.localOrTemp());
    }

    const rightv = try genExpr(c, stmt.right, Cstr.localOrTemp());
    try push_store(c, dst_ptr.reg, @intCast(rec.off + offset), rightv.reg, val_t, node);
    try pop_regs(c, temp_start, node);
}

fn push_store(c: *cy.Chunk, dst_ptr: Reg, offset: u16, src: Reg, src_t: *cy.Type, node: *ast.Node) !void {
    const size = src_t.size();
    switch (size) {
        32 => {
            try c.pushCode(.store_4w, &.{ dst_ptr, offset, src }, node);
        },
        24 => {
            try c.pushCode(.store_3w, &.{ dst_ptr, offset, src }, node);
        },
        16 => {
            try c.pushCode(.store_2w, &.{ dst_ptr, offset, src }, node);
        },
        8 => {
            try c.pushCode(.store_64, &.{ dst_ptr, offset, src }, node);
        },
        4 => {
            try c.pushCode(.store_32, &.{ dst_ptr, offset, src }, node);
        },
        2 => {
            try c.pushCode(.store_16, &.{ dst_ptr, offset, src }, node);
        },
        1 => {
            try c.pushCode(.store_8, &.{ dst_ptr, offset, src }, node);
        },
        0 => {},
        else => {
            try c.pushCode(.store_n, &.{ dst_ptr, offset, src, @intCast(src_t.size()) }, node);
        },
    }
}

fn gen_bitcast(c: *Chunk, expr: *ir.Bitcast, cstr: Cstr, node: *ast.Node) !GenValue {
    _ = node;
    return genExpr(c, expr.expr, cstr);
}

fn genUnwrapAddr(c: *Chunk, expr: *ir.UnwrapAddr, cstr: Cstr, node: *ast.Node) !GenValue {
    const dst = try bc.selectReg(c, expr.base.type, cstr, node);
    const choice = try genExpr(c, expr.choice, Cstr.localOrTemp());

    try c.pushFCode(.unwrap_addr, &.{ dst.reg, choice.reg, expr.tag, 8 }, node);
    try pop_temp_value(c, choice, node);
    return dst;
}

fn genUnwrapNZ(c: *Chunk, expr: *ir.UnwrapNZ, cstr: Cstr, node: *ast.Node) !GenValue {
    const dst = try bc.selectReg(c, expr.base.type, cstr, node);
    const option = try genExpr(c, expr.option, Cstr.localOrTemp());
    try c.pushFCode(.unwrap_nz, &.{ dst.reg, option.reg}, node);
    try pop_temp_value(c, option, node);
    return dst;
}

fn gen_i2f(c: *Chunk, expr: *ir.UnOp2, cstr: Cstr, node: *ast.Node) !GenValue {
    const dst = try bc.selectReg(c, expr.base.type, cstr, node);
    const src = try genExpr(c, expr.expr, Cstr.localOrTemp());
    // The upper bits of a narrow int register are undefined. Extend from the int's width first.
    const src_t = expr.expr.type;
    switch (src_t.kind()) {
        .int => {
            const bits = src_t.cast(.int).bits;
            if (bits < 64) try push_sext(c, src.reg, src.reg, @intCast(bits), node);
        },
        .raw => {
            const bits = src_t.cast(.raw).bits;
            if (bits < 64) try push_zext(c, src.reg, src.reg, @intCast(bits), node);
        },
        else => {},
    }
    if (expr.base.type.id() == bt.F64) {
        try c.pushCode(.i2f, &.{ dst.reg, src.reg}, node);
    } else {
        try c.pushCode(.i2f32, &.{ dst.reg, src.reg}, node);
    }
    try pop_temp_value(c, src, node);
    return dst;
}

fn gen_trunc(c: *Chunk, expr: *ir.Trunc, cstr: Cstr, node: *ast.Node) !GenValue {
    _ = node;
    // Trunc just leaves the significant bits undefined.
    return genExpr(c, expr.expr, cstr);
}

fn gen_fabs(c: *Chunk, expr: *ir.UnOp2, cstr: Cstr, node: *ast.Node) !GenValue {
    const dst = try bc.selectReg(c, expr.base.type, cstr, node);
    const src = try genExpr(c, expr.expr, Cstr.localOrTemp());
    if (expr.base.type.id() == bt.F64) {
        try c.pushCode(.fabs, &.{dst.reg, src.reg}, node);
    } else {
        try c.pushCode(.f32abs, &.{ dst.reg, src.reg}, node);
    }
    try pop_temp_value(c, src, node);
    return dst;
}

fn gen_f2i(c: *Chunk, expr: *ir.UnOp2, cstr: Cstr, node: *ast.Node) !GenValue {
    const dst = try bc.selectReg(c, expr.base.type, cstr, node);
    const src = try genExpr(c, expr.expr, Cstr.localOrTemp());
    if (expr.expr.type.id() == bt.F64) {
        try c.pushCode(.f2i, &.{ dst.reg, src.reg}, node);
    } else {
        try c.pushCode(.f32_2i, &.{ dst.reg, src.reg}, node);
    }
    try pop_temp_value(c, src, node);
    return dst;
}

fn gen_sext(c: *Chunk, expr: *ir.Widen, cstr: Cstr, node: *ast.Node) !GenValue {
    const dst = try bc.selectReg(c, expr.base.type, cstr, node);
    const src = try genExpr(c, expr.expr, Cstr.localOrTemp());
    try push_sext(c, dst.reg, src.reg, @intCast(expr.src_bits), node);
    try pop_temp_value(c, src, node);
    return dst;
}

fn gen_zext(c: *Chunk, expr: *ir.Widen, cstr: Cstr, node: *ast.Node) !GenValue {
    const dst = try bc.selectReg(c, expr.base.type, cstr, node);
    const src = try genExpr(c, expr.expr, Cstr.localOrTemp());
    try push_zext(c, dst.reg, src.reg, @intCast(expr.src_bits), node);
    try pop_temp_value(c, src, node);
    return dst;
}

fn gen_void(c: *Chunk, cstr: Cstr, node: *ast.Node) !GenValue {
    if (cstr.type == .discard) {
        return GenValue.discard();
    }
    const dst = try bc.selectReg(c, c.sema.void_t, cstr, node);
    // Does not generate inst.
    return dst;
}

fn gen_undef(c: *Chunk, expr: *ir.SimpleExpr, cstr: Cstr, node: *ast.Node) !GenValue {
    const dst = try bc.selectReg(c, expr.base.type, cstr, node);
    // Nop.
    return dst;
}

fn gen_true(c: *Chunk, cstr: Cstr, node: *ast.Node) !GenValue {
    const dst = try bc.selectReg(c, c.sema.bool_t, cstr, node);
    try c.pushCode(.true, &.{dst.reg}, node);
    return dst;
}

fn gen_false(c: *Chunk, cstr: Cstr, node: *ast.Node) !GenValue {
    const dst = try bc.selectReg(c, c.sema.bool_t, cstr, node);
    try c.pushCode(.false, &.{dst.reg}, node);
    return dst;
}

fn gen_const8(c: *Chunk, expr: *ir.Const8, cstr: Cstr, node: *ast.Node) !GenValue {
    const dst = try bc.selectReg(c, expr.base.type, cstr, node);
    try c.pushCode(.const_16, &.{ dst.reg, expr.val }, node);
    return dst;
}

fn gen_const16(c: *Chunk, expr: *ir.Const16, cstr: Cstr, node: *ast.Node) !GenValue {
    const dst = try bc.selectReg(c, expr.base.type, cstr, node);
    try c.pushCode(.const_16, &.{ dst.reg, expr.val }, node);
    return dst;
}

fn gen_const32(c: *Chunk, expr: *ir.Const32, cstr: Cstr, node: *ast.Node) !GenValue {
    const dst = try bc.selectReg(c, expr.base.type, cstr, node);
    const pc = c.buf.ops.items.len;
    try c.pushCode(.const_32, &.{ dst.reg, 0, 0 }, node);
    c.buf.setOpArgU32(pc + 2, expr.val);
    return dst;
}

fn genIsZero(c: *Chunk, expr: *ir.IsZero, cstr: Cstr, node: *ast.Node) !GenValue {
    const dst = try bc.selectReg(c, expr.base.type, cstr, node);

    const childv = try genExpr(c, expr.child, Cstr.localOrTemp());

    try c.pushCode(.is_zero, &.{dst.reg, childv.reg}, node);
    try pop_temp_value(c, childv, node);
    return dst;
}

fn gen_retain(c: *Chunk, expr: *ir.Retain, cstr: Cstr, node: *ast.Node) !GenValue {
    const child = try genExpr(c, expr.expr, cstr);

    try c.pushCode(.retain, &.{ child.reg }, node);
    return child;
}

fn gen_string(c: *Chunk, expr: *ir.String, cstr: Cstr, node: *ast.Node) !GenValue {
    const dst = try bc.selectReg(c, expr.base.type, cstr, node);
    if (expr.base.type.id() == bt.Str) {
        try pushConstString(c, expr.raw(), dst.reg, node);
    } else if (expr.base.type.isPointer()) {
        try pushConstStrZPtr(c, expr.raw(), dst.reg, node);
    } else {
        return error.Unexpected;
    }
    return dst;
}

fn pushConstStrZPtr(c: *Chunk, str: []const u8, dst: Reg, node: *ast.Node) !void {
    const res = try c.buf.getOrPushConstString(str);
    try genConst64_(c, @intFromPtr(res.slice.ptr), dst, node);
}

/// `const_str` packs the pointer (48 bits) and the length (16 bits) into one u64 operand, so a literal is at most
/// 65535 bytes. A longer one used to have its length silently truncated (F-24).
pub const max_str_literal_len: usize = std.math.maxInt(u16);

fn pushConstString(c: *Chunk, str: []const u8, dst: Reg, node: *ast.Node) !void {
    if (str.len > max_str_literal_len) {
        return c.reportErrorFmt("String literal too long. A string literal can have at most {} bytes. Split it and join the parts at runtime.", &.{v(max_str_literal_len)}, node);
    }
    const res = try c.buf.getOrPushConstString(str);
    const ptr_len = (@as(u64, @intFromPtr(res.slice.ptr)) & 0xffffffffffff) | (@as(u64, res.slice.len) << 48);
    const pc = c.buf.ops.items.len;
    try c.pushCode(.const_str, &.{ dst, 0, 0, 0, 0, @intFromBool(res.ascii) }, node);
    c.buf.setOpArgU64(pc + 2, ptr_len);
}

fn genUnOp2(c: *Chunk, expr: *ir.UnOp2, op: cy.OpCode, cstr: Cstr, node: *ast.Node) !GenValue {
    const dst = try bc.selectReg(c, expr.base.type, cstr, node);
    const childv = try genExpr(c, expr.expr, Cstr.localOrTemp());
    try pushInlineUnExpr(c, op, dst.reg, childv.reg, node);
    try pop_temp_value(c, childv, node);
    return dst;
}

fn genUnOp(c: *Chunk, expr: *ir.UnOp, cstr: Cstr, node: *ast.Node) !GenValue {
    const dst = try bc.selectReg(c, expr.base.type, cstr, node);

    const childv = try genExpr(c, expr.expr, Cstr.localOrTemp());

    switch (expr.op) {
        .lnot => {
            try c.pushCode(.lnot, &.{dst.reg, childv.reg}, node);
        },
        .minus,
        .bitwiseNot => {
            if (expr.childT == c.sema.i64_t) {
                try pushInlineUnExpr(c, getIntUnaryOpCode(expr.op), dst.reg, childv.reg, node);
            } else if (expr.childT == c.sema.f64_t) {
                try pushInlineUnExpr(c, getFloatUnaryOpCode(expr.op), dst.reg, childv.reg, node);
            } else return error.Unexpected;
            // Builtin unary expr do not have retained child.
        },
        else => {
            return c.reportErrorFmt("Unsupported op: {}", &.{v(expr.op)}, node);
        }
    }

    try pop_temp_value(c, childv, node);
    return dst;
}

fn gen_call_trait(c: *Chunk, expr: *ir.CallTrait, cstr: Cstr, node: *ast.Node) !GenValue {
    const ret_t = expr.base.type;
    const inst = try beginCall(c, cstr, ret_t, true, node);

    // Trait struct is reserved over the callee and the first argument (the receiver).
    var temp = try reserve_reg(c, expr.trait.type);
    _ = try genExpr(c, expr.trait, Cstr.toTemp(temp));

    // Args. Skip impl receiver.
    const args = expr.args[1..expr.nargs];
    for (args) |arg| {
        temp = try reserve_reg(c, arg.type);
        _ = try genExpr(c, arg, Cstr.toTemp(temp));
    }

    const pc = c.buf.ops.items.len;
    try c.pushFCode(.call_trait, &.{inst.base, @intCast(expr.vtable_idx) }, node);
    try push_site_ptr_layout(c, pc);

    return endCall(c, inst, ret_t, node);
}

fn genCallIntrinsic(c: *Chunk, call: *ir.Call, cstr: Cstr, intrinsic: Intrinsic, node: *ast.Node) !GenValue {
    switch (intrinsic) {
        .null => {
            return error.Unexpected;
        },
        .dtor_str => {
            const borrow = try genExpr(c, call.args[0], Cstr.localOrTemp());
            try c.pushCode(.dtor_str, &.{borrow.reg}, node);
            try pop_temp_value(c, borrow, node);
            return GenValue.discard();
        },
        .cmp_str => {
            const dst = try bc.selectReg(c, call.base.type, cstr, node);
            const borrow_a = try genExpr(c, call.args[0], Cstr.localOrTemp());
            const borrow_b = try genExpr(c, call.args[1], Cstr.localOrTemp());
            try c.pushCode(.cmp_str, &.{dst.reg, borrow_a.reg, borrow_b.reg }, node);
            try pop_temp_value(c, borrow_b, node);
            try pop_temp_value(c, borrow_a, node);
            return dst;
        },
        .copy_str => {
            // `@copy[str](src Ptr[str])`: Load the 3 words and retain the buffer.
            if (cstr.type == .discard) {
                return GenValue.discard();
            }
            const dst = try bc.selectReg(c, call.base.type, cstr, node);
            const src_ptr = try genExpr(c, call.args[0], Cstr.localOrTemp());
            try c.pushCode(.copy_str, &.{dst.reg, src_ptr.reg}, node);
            try pop_temp_value(c, src_ptr, node);
            return dst;
        },
    }
}

fn genCallExternPtr(c: *Chunk, expr: *ir.CallPtr, func_ptr: *cy.types.FuncPtr, cstr: Cstr, node: *ast.Node) !GenValue {
    const ret_t = expr.base.type;
    const inst = try beginCall(c, cstr, ret_t, false, node);

    const args = expr.args[0..expr.nargs];

    // Push func pointer as the first arg.
    var temp = try reserve_reg(c, expr.callee.type);
    _ = try genExpr(c, expr.callee, Cstr.toTemp(temp));

    var exp_arg_reg = c.cur_proc.reg_end;
    for (args) |arg| {
        temp = try reserve_reg(c, arg.type);
        if (cy.Trace) {
            if (temp != exp_arg_reg) return error.Unexpected;
            exp_arg_reg += @intCast(arg.type.reg_size());
        }
        _ = try genExpr(c, arg, Cstr.toTemp(temp));
    }

    _ = try ensureExternFuncPtrDispatch(c.compiler, func_ptr);

    // Invoke extern function pointer dispatch.
    const start = c.buf.ops.items.len;
    try c.pushFCode(.call_host, &.{ inst.base, 0, 0, 0 }, node);
    try c.rt_relocations.append(c.alloc, .{.kind = .extern_func_ptr, .pc = start + 2, .data = .{.extern_func_ptr = func_ptr}});

    return endCall(c, inst, ret_t, node);
}

fn gen_call(c: *Chunk, expr: *ir.Call, cstr: Cstr, node: *ast.Node) !GenValue {
    log.tracev("call {s}", .{expr.func.name()});

    if (expr.func.info.gen_intrinsic > 0) {
        return genCallIntrinsic(c, expr, cstr, @fromBackingInt(@intCast(expr.func.info.gen_intrinsic)), node);
    }

    // Leave room in the u8 register window. Inlining extends the caller's frame. Error paths stay calls.
    if (c.cold_depth == 0 and c.cur_proc.reg_end < inline_max_reg_end and can_inline(expr.func)) {
        if (inline_cost_fits(c, expr.func)) |cost| {
            return gen_inline_call(c, expr, cost, cstr, node);
        }
    }

    const ret_t = expr.base.type;
    var callee_ret_t = ret_t;
    if (expr.func.info.generator) {
        const gen_t = ret_t.cast(.pointer).child_t;
        const val_t = gen_t.sym().instance.?.params[0].asPtr(*cy.Type).cast(.func_ptr).sig.ret;
        const next_t = try cy.sema.getOptionType(c, val_t);
        if (next_t.size() > ret_t.size()) {
            callee_ret_t = next_t;
        }
    }
    const inst = try beginCall(c, cstr, callee_ret_t, false, node);

    const args = expr.args[0..expr.numArgs];

    var exp_arg_reg = c.cur_proc.reg_end;
    for (args) |arg| {
        const temp = try reserve_reg(c, arg.type);
        if (cy.Trace) {
            if (temp != exp_arg_reg) return error.Unexpected;
            exp_arg_reg += @intCast(arg.type.reg_size());
        }
        _ = try genExpr(c, arg, Cstr.toTemp(temp));
    }

    if (expr.func.type == .extern_) {
        // const rt_id = (try ensureExternFunc(c.compiler, expr.func)).vm_id;
        try pushCall(c, inst.base, expr.func, node);
    } else {
        // const rt_id = try ensureFunc(c.compiler, expr.func);
        try pushCall(c, inst.base, expr.func, node);
    }

    return endCall(c, inst, ret_t, node);
}

/// State while generating an inlined callee body. See `docs/decisions/project_bc_inline.md`.
pub const InlineCtx = struct {
    /// Enclosing inline. Its body contains this call site.
    parent: ?*InlineCtx,
    func: *cy.Func,
    /// 1 for an inline in a proc body, 2 for an inline inside it, and so on.
    depth: u8,
    /// IR nodes inlined under the outermost inline, including nested ones. Only kept in the outermost ctx.
    total_cost: u32,
    /// Index into `ByteCodeBuffer.inline_sites`.
    site: u32,
    /// Caller's block depth at the call. Added to the callee's IR block offsets.
    block_base: u32,
    /// Call site node.
    node: *ast.Node,
    /// Callee's source chunk.
    src_chunk: u32,
    /// Callee's index into `Chunk.funcs_debug`.
    frame_id: u32,
    ret_reg: Reg,
    /// `ret_reg` is a register the body can not name: a fresh temp, the caller's temp destination,
    /// or a local being declared. A `return {…}` then writes its fields straight into it. Another
    /// local destination may be read by the body (`p = f(&p)`), so it keeps the local rules of
    /// `gen_init_regs`.
    ret_is_temp: bool,
    /// The callee's top level body. A trailing `ret_expr` there needs no jump.
    body_head: ?*ir.Stmt,
    /// `jump` insts that go to the end of the inlined body.
    end_jumps: std.ArrayList(u32),
};

const inline_max_nodes = 40;
/// Node limit for a function marked `#[inline]`.
const inline_max_nodes_attr = 120;
/// Nested inlines stop at this depth.
const inline_max_depth = 3;
/// Limit on IR nodes inlined under one outermost call site, so nesting does not multiply code size.
const inline_max_total = 160;
/// A body up to this many nodes is inlined at any site. Bigger bodies only at hot sites (in a loop) or with `#[inline]`.
const inline_small_nodes = 16;
const inline_max_params = 8;
/// Registers are u8 indexed by the VM (`chk_stk` frame size), keep a margin for the inlined body.
const inline_max_reg_end = 160;

/// Returns the cost of inlining `func` at the current site, or null when nesting limits are reached.
/// A self call (recursion) is unrolled one level: the site is hot, and the copy's own calls stay calls
/// because the inline context chain already holds the function.
fn inline_cost_fits(c: *Chunk, func: *cy.Func) ?u32 {
    const proc_func = c.funcs_debug.items[c.cur_proc.id].func;
    const self_call = proc_func == func;
    // `can_inline` cached the body's node count.
    const block = func.data.userFunc.loc.cast(.funcBlock);
    const cost = block.bc_inline_cost;
    const hot = c.cur_proc.loop_depth > 0 or (if (proc_func) |f| f.info.bc_hot else false);
    if (cost > inline_small_nodes and !hot and !block.bc_inline_attr and !self_call) return null;
    const ctx = c.inline_ctx orelse return cost;
    if (ctx.depth >= inline_max_depth) return null;
    var root = ctx;
    var cur: ?*InlineCtx = ctx;
    while (cur) |cx| {
        if (cx.func == func) return null;
        root = cx;
        cur = cx.parent;
    }
    if (root.total_cost + cost > inline_max_total) return null;
    return cost;
}

const InlineCount = struct {
    n: u32,
    limit: u32,
    /// Params assigned or address-taken in the body (`ir.FuncBlock.bc_param_pinned`).
    pinned: u32 = 0,

    fn pin_local(self: *InlineCount, id: u8) void {
        if (id < 32) self.pinned |= @as(u32, 1) << @intCast(id);
    }
};

/// `#[inline]` raises the node limit for a hot function that is too big for the default limit.
fn has_inline_attr(func: *cy.Func) bool {
    const decl = func.decl orelse return false;
    if (decl.type() != .funcDecl) return false;
    for (decl.cast(.funcDecl).attrs.slice()) |attr| {
        if (attr.type == .inline_) return true;
    }
    return false;
}

/// Whether `func` is a small function whose IR body only uses allowed statements and expressions.
/// Calls inside the body are generated as calls or nested inlines. Inline sites are expanded in stack traces.
fn can_inline(func: *cy.Func) bool {
    switch (func.info.bc_inline) {
        1 => return true,
        2 => return false,
        else => {},
    }
    if (check_inline(func)) |count| {
        func.info.bc_inline = 1;
        const block = func.data.userFunc.loc.cast(.funcBlock);
        block.bc_inline_cost = count.n;
        block.bc_inline_attr = has_inline_attr(func);
        block.bc_param_pinned = count.pinned;
        return true;
    }
    func.info.bc_inline = 2;
    return false;
}

/// Returns the body's IR node count (and pinned params) when `func` can be inlined.
fn check_inline(func: *cy.Func) ?InlineCount {
    if (func.type != .userFunc) return null;
    if (func.info.generator or func.info.extern_) return null;
    // A function that does not return runs at most once per call site, so the call is not worth removing.
    if (func.sig.ret.id() == bt.Never) return null;
    if (func.sig.params_len > inline_max_params) return null;
    const loc = func.data.userFunc.loc;
    if (loc.code != .funcBlock) return null;
    const block = loc.cast(.funcBlock);
    if (block.skip) return null;
    var count = InlineCount{
        .n = 0,
        .limit = if (has_inline_attr(func)) inline_max_nodes_attr else inline_max_nodes,
    };
    if (!check_inline_stmts(block.bodyHead, &count)) return null;
    return count;
}

fn check_inline_stmts(head: ?*ir.Stmt, count: *InlineCount) bool {
    var stmt_opt = head;
    while (stmt_opt) |stmt| {
        count.n += 1;
        if (count.n > count.limit) return false;
        switch (stmt.code) {
            .declare_local => {
                const data = stmt.cast(.declare_local);
                if (data.init) |init| {
                    if (!check_inline_expr(init, count)) return false;
                }
            },
            .set_local => {
                const data = stmt.cast(.set_local);
                count.pin_local(data.id);
                if (!check_inline_expr(data.right, count)) return false;
            },
            .set_ret => if (!check_inline_expr(stmt.cast(.set_ret).right, count)) return false,
            .set_global => if (!check_inline_expr(stmt.cast(.set_global).expr, count)) return false,
            .set_field => {
                const data = stmt.cast(.set_field);
                if (!check_inline_expr(data.field, count)) return false;
                if (!check_inline_expr(data.right, count)) return false;
            },
            .set_deref => {
                const data = stmt.cast(.set_deref);
                if (!check_inline_expr(data.ptr, count)) return false;
                if (!check_inline_expr(data.right, count)) return false;
            },
            .discard => if (!check_inline_expr(stmt.cast(.discard).expr, count)) return false,
            .ret_expr => if (!check_inline_expr(stmt.cast(.ret_expr).expr, count)) return false,
            .if_block => {
                const data = stmt.cast(.if_block);
                if (!check_inline_expr(data.cond_expr, count)) return false;
                if (!check_inline_stmts(data.body_head, count)) return false;
            },
            .block => if (!check_inline_stmts(stmt.cast(.block).bodyHead, count)) return false,
            // Loops use the caller's absolute block depth, and `break_` · `continue_` add `InlineCtx.block_base`.
            // A backward jump checkpoint inside the body is expanded through the inline site like any other pc.
            .loop_block => if (!check_inline_stmts(stmt.cast(.loop_block).body_head, count)) return false,
            .forRangeStmt => {
                const data = stmt.cast(.forRangeStmt);
                if (!check_inline_expr(data.start, count)) return false;
                if (!check_inline_expr(data.end, count)) return false;
                if (!check_inline_stmts(data.declHead, count)) return false;
                if (!check_inline_stmts(data.bodyHead, count)) return false;
            },
            .break_,
            .continue_,
            .ret,
            .trap,
            .nop_label,
            .pop_locals,
            .release => {},
            else => return false,
        }
        stmt_opt = stmt.next;
    }
    return true;
}

fn check_inline_expr(expr: *ir.Expr, count: *InlineCount) bool {
    count.n += 1;
    if (count.n > count.limit) return false;
    switch (expr.code) {
        .local,
        .const8,
        .const16,
        .const32,
        .const64,
        .truev,
        .falsev,
        .voidv,
        .undef,
        .string,
        .global,
        .init_zero => return true,
        .and_op, .or_op, .xor, .lsl, .asr, .lsr, .add, .sub, .imul, .mul, .div, .idiv, .mod, .imod,
        .fadd, .fsub, .fmod, .fmul, .fdiv => {
            // All of these are `BinOp2`. `cast` would check the exact code in Trace builds.
            const data: *ir.BinOp2 = @ptrCast(@alignCast(expr));
            return check_inline_expr(data.left, count) and check_inline_expr(data.right, count);
        },
        .cmp => {
            const data = expr.cast(.cmp);
            return check_inline_expr(data.left, count) and check_inline_expr(data.right, count);
        },
        .binary_op => {
            const data = expr.cast(.binary_op);
            return check_inline_expr(data.left, count) and check_inline_expr(data.right, count);
        },
        .unary_op => return check_inline_expr(expr.cast(.unary_op).expr, count),
        .neg, .not, .fneg, .fabs, .f2i, .i2f => {
            const data: *ir.UnOp2 = @ptrCast(@alignCast(expr));
            return check_inline_expr(data.expr, count);
        },
        .sext, .zext => {
            const data: *ir.Widen = @ptrCast(@alignCast(expr));
            return check_inline_expr(data.expr, count);
        },
        .is_zero => return check_inline_expr(expr.cast(.is_zero).child, count),
        .field => return check_inline_expr(expr.cast(.field).rec, count),
        .cast => {
            return check_inline_expr(expr.cast(.cast).expr, count);
        },
        .bitcast => return check_inline_expr(expr.cast(.bitcast).expr, count),
        .address_of => {
            const inner = expr.cast(.address_of).expr;
            if (inner.code == .local) count.pin_local(inner.cast(.local).id);
            return check_inline_expr(inner, count);
        },
        .deref => return check_inline_expr(expr.cast(.deref).expr, count),
        .trunc => return check_inline_expr(expr.cast(.trunc).expr, count),
        .retain => return check_inline_expr(expr.cast(.retain).expr, count),
        .init => {
            const data = expr.cast(.init);
            for (data.args[0..data.nargs]) |arg| {
                if (!check_inline_expr(arg, count)) return false;
            }
            return true;
        },
        .call => {
            // A call in an inlined body is generated as a call or a nested inline (`inline_cost_fits` decides).
            const data = expr.cast(.call);
            for (data.args[0..data.numArgs]) |arg| {
                if (!check_inline_expr(arg, count)) return false;
            }
            return true;
        },
        else => return false,
    }
}

fn inline_ret_jump(c: *Chunk, ctx: *InlineCtx, stmt: *ir.Stmt, node: *ast.Node) !void {
    // A return that ends the callee's top level body falls through to the end.
    // Only `trap` (an unreachable end marker, skipped when inlining) may follow it.
    var rest = stmt.next;
    while (rest) |r| {
        if (r.code != .trap) break;
        rest = r.next;
    }
    if (rest == null and is_top_level_stmt(ctx.body_head, stmt)) {
        return;
    }
    const pc = try c.pushEmptyJump(node);
    try ctx.end_jumps.append(c.alloc, pc);
}

fn is_top_level_stmt(head: ?*ir.Stmt, target: *ir.Stmt) bool {
    var stmt_opt = head;
    while (stmt_opt) |stmt| {
        if (stmt == target) return true;
        stmt_opt = stmt.next;
    }
    return false;
}

/// The caller local behind a pointer arg: `&local`, or a pointer param that is itself bound to one.
fn addr_of_local_arg(c: *Chunk, arg: *ir.Expr) ?Reg {
    switch (arg.code) {
        .address_of => {
            const inner = arg.cast(.address_of).expr;
            if (inner.code != .local) return null;
            const slot = local_slot(c, inner.cast(.local).id);
            if (slot.kind != .reg) return null;
            return slot.reg;
        },
        .local => {
            const slot = local_slot(c, arg.cast(.local).id);
            if (slot.kind != .addr_of) return null;
            return slot.reg;
        },
        else => return null,
    }
}

/// Generates the callee's IR body in the caller's proc instead of a `call`.
/// Args are evaluated into temps like a call, and the callee's param locals are bound to them.
fn gen_inline_call(c: *Chunk, expr: *ir.Call, cost: u32, cstr: Cstr, node: *ast.Node) !GenValue {
    const func = expr.func;
    const block = func.data.userFunc.loc.cast(.funcBlock);
    const ret_t = expr.base.type;
    const ret_size: u16 = @intCast(ret_t.reg_size());

    const temp_start = c.cur_proc.reg_end;
    // Return straight into the destination when it is a register. Args are copied to fresh temps
    // before the body runs, so `x = f(x)` still reads the old `x`.
    const direct_dst = ret_size > 0 and (cstr.type == .localReg or cstr.type == .tempReg);
    var ret_reg: Reg = 0;
    if (direct_dst) {
        ret_reg = cstr.data.slot.dst;
    } else if (ret_size > 0) {
        ret_reg = try reserve_reg(c, ret_t);
    }

    const saved_local_base = c.inline_local_base;
    const saved_local_len = c.bc_local_map.items.len;

    const args = expr.args[0..expr.numArgs];
    var arg_slots: [inline_max_params]LocalSlot = undefined;
    for (args, 0..) |arg, i| {
        // `&local` binds the param to the local itself when the body never assigns the param or takes
        // its address, so field and deref accesses in the body read the local's registers.
        const pinned = i >= 32 or (block.bc_param_pinned >> @intCast(i)) & 1 != 0;
        if (!pinned) {
            if (addr_of_local_arg(c, arg)) |reg| {
                arg_slots[i] = .{ .reg = reg, .kind = .addr_of };
                continue;
            }
        }
        const temp = try reserve_reg(c, arg.type);
        _ = try genExpr(c, arg, Cstr.toTemp(temp));
        arg_slots[i] = .{ .reg = temp, .kind = .reg };
    }

    // Bind callee param locals to the arg temps.
    c.inline_local_base = c.bc_local_map.items.len;
    for (arg_slots[0..args.len]) |slot| {
        try c.bc_local_map.append(c.alloc, slot);
    }

    const frame_id: u32 = @intCast(c.funcs_debug.items.len);
    try c.funcs_debug.append(c.alloc, .{ .func = func, .name = func.name(), .src_chunk = func.decl.?.src() });

    // The site is added before the body so sites stay ordered by `start`, a parent before its nested sites.
    const parent = c.inline_ctx;
    var call_loc = node.pos();
    var caller_frame = c.cur_proc.id;
    if (parent) |p| {
        caller_frame = p.frame_id;
        if (node.src() != p.src_chunk) call_loc = cy.NullId;
    }
    const site: u32 = @intCast(c.buf.inline_sites.items.len);
    const start_pc: u32 = @intCast(c.buf.ops.items.len);
    try c.buf.inline_sites.append(c.alloc, .{
        .start = start_pc,
        .end = start_pc,
        .call_loc = call_loc,
        .caller_frame = caller_frame,
        .parent = if (parent) |p| p.site else cy.NullId,
    });

    var ctx = InlineCtx{
        .parent = parent,
        .func = func,
        .depth = if (parent) |p| p.depth + 1 else 1,
        .total_cost = cost,
        .site = site,
        .block_base = c.cur_proc.block_depth,
        .node = node,
        .src_chunk = func.decl.?.src(),
        .frame_id = frame_id,
        .ret_reg = ret_reg,
        .ret_is_temp = cstr.type != .localReg or cstr.data.slot.fresh,
        .body_head = block.bodyHead,
        .end_jumps = .empty,
    };
    defer ctx.end_jumps.deinit(c.alloc);
    if (parent) |p| {
        var root = p;
        while (root.parent) |pp| root = pp;
        root.total_cost += cost;
    }
    c.inline_ctx = &ctx;
    const saved_cur_node = c.curNode;
    {
        defer {
            c.inline_ctx = parent;
            c.inline_local_base = saved_local_base;
            c.curNode = saved_cur_node;
        }
        try pushBlock(c, node);
        try genStmts(c, block.bodyHead);
        try popBlock(c);
    }
    for (ctx.end_jumps.items) |pc| {
        try c.patchJumpToCurPc(pc, node);
    }
    c.bc_local_map.items.len = saved_local_len;

    const end_pc: u32 = @intCast(c.buf.ops.items.len);
    if (end_pc > start_pc) {
        c.buf.inline_sites.items[site].end = end_pc;
    } else {
        // An empty body has no nested sites after it.
        std.debug.assert(site == c.buf.inline_sites.items.len - 1);
        c.buf.inline_sites.items.len = site;
    }

    if (ret_size == 0) {
        try pop_regs(c, temp_start, node);
        return if (cstr.type == .discard) GenValue.discard() else GenValue.initTemp(temp_start);
    }
    switch (cstr.type) {
        .localReg, .tempReg => {
            const dst = cstr.data.slot.dst;
            try pop_regs(c, temp_start, node);
            return if (cstr.type == .localReg) GenValue.initLocal(dst) else GenValue.initTemp(dst);
        },
        .discard => {
            try pop_regs(c, temp_start, node);
            return GenValue.discard();
        },
        else => {
            // The return temp stays reserved for the caller.
            try pop_regs(c, ret_reg + ret_size, node);
            return GenValue.initTemp(ret_reg);
        },
    }
}

fn gen_call_union(c: *Chunk, expr: *ir.CallUnion, cstr: Cstr, node: *ast.Node) !GenValue {
    const ret_t = expr.base.type;
    const inst = try beginCall(c, cstr, ret_t, true, node);

    // Callee.
    const arg_start = c.cur_proc.reg_end;
    var temp = try reserve_reg(c, expr.callee.type);
    _ = try genExpr(c, expr.callee, Cstr.toTemp(temp));

    // Args.
    var exp_arg_reg = arg_start + 1;
    const args = expr.args[0..expr.nargs];
    for (args) |arg| {
        temp = try reserve_reg(c, arg.type);
        if (cy.Trace) {
            if (temp != exp_arg_reg) return error.Unexpected;
            exp_arg_reg += @intCast(arg.type.reg_size());
        }
        _ = try genExpr(c, arg, Cstr.toTemp(temp));
    }

    const pc = c.buf.ops.items.len;
    try c.pushFCode(.call_union, &.{inst.base}, node);
    try push_site_ptr_layout(c, pc);

    try pop_regs(c, arg_start, node);
    return endCall(c, inst, ret_t, node);
}

fn gen_call_ptr(c: *Chunk, expr: *ir.CallPtr, cstr: Cstr, node: *ast.Node) !GenValue {
    const func_ptr = expr.callee.type.cast(.func_ptr);
    if (func_ptr.sig.extern_) {
        return genCallExternPtr(c, expr, func_ptr, cstr, node);
    }

    const ret_t = expr.base.type;
    const inst = try beginCall(c, cstr, ret_t, true, node);

    // Callee.
    var temp = try reserve_reg(c, expr.callee.type);
    _ = try genExpr(c, expr.callee, Cstr.toTemp(temp));

    // Args.
    const args = expr.args[0..expr.nargs];
    for (args) |arg| {
        temp = try reserve_reg(c, arg.type);
        _ = try genExpr(c, arg, Cstr.toTemp(temp));
    }

    const pc = c.buf.ops.items.len;
    try c.pushFCode(.call_ptr, &.{inst.base}, node);
    try push_site_ptr_layout(c, pc);

    return endCall(c, inst, ret_t, node);
}

fn pushCmp(c: *Chunk, val_t: *cy.Type, dst: Reg, left: Reg, right: Reg, node: *ast.Node) !void {
    switch (val_t.id()) {
        bt.Void => {
            try c.pushCode(.true, &.{dst}, node);
        },
        bt.Bool,
        bt.R8,
        bt.I8 => {
            try c.pushCode(.cmp_8, &.{dst, left, right}, node);
        },
        bt.F32 => {
            try c.pushCode(.feq32, &.{dst, left, right}, node);
        },
        bt.F64 => {
            try c.pushCode(.feq, &.{dst, left, right}, node);
        },
        bt.R32,
        bt.I32 => {
            try push_zext(c, left, left, 32, node);
            try push_zext(c, right, right, 32, node);
            try c.pushCode(.cmp, &.{dst, left, right}, node);
        },
        bt.R16,
        bt.I16 => {
            try push_zext(c, left, left, 16, node);
            try push_zext(c, right, right, 16, node);
            try c.pushCode(.cmp, &.{dst, left, right}, node);
        },
        bt.R64,
        bt.Symbol,
        bt.Error,
        bt.I64 => {
            try c.pushCode(.cmp, &.{dst, left, right}, node);
        },
        else => {
            switch (val_t.kind()) {
                .pointer,
                .func_ptr,
                .enum_t => {
                    try c.pushCode(.cmp, &.{dst, left, right}, node);
                },
                else => {
                    return c.reportErrorFmt("Unsupported comparison: {}", &.{v(val_t.name())}, node);
                }
            }
        }
    }
}

fn genCompare(c: *Chunk, expr: *ir.Compare, cstr: Cstr, node: *ast.Node) !GenValue {
    const dst = try bc.selectReg(c, expr.base.type, cstr, node);
    const left = try genExpr(c, expr.left, Cstr.localOrTemp());
    const right = try genExpr(c, expr.right, Cstr.localOrTemp());
    if (expr.left.type.kind() == .float) {
        if (expr.left.type.id() == bt.F64) {
            const code: cy.OpCode = switch (expr.cond) {
                .lt => .flt,
                .le => .fle,
                .gt => .fgt,
                .ge => .fge,
                else => return error.TODO,
            };
            try c.pushCode(code, &.{ dst.reg, left.reg, right.reg }, node);
        } else {
            const code: cy.OpCode = switch (expr.cond) {
                .lt => .flt32,
                .le => .fle32,
                .gt => .fgt32,
                .ge => .fge32,
                else => return error.TODO,
            };
            try c.pushCode(code, &.{ dst.reg, left.reg, right.reg }, node);
        }
    } else {
        var bits: u32 = undefined;
        if (expr.left.type.kind() == .raw) {
            bits = expr.left.type.cast(.raw).bits;
        } else {
            bits = expr.left.type.cast(.int).bits;
        }
        if (bits < 64) {
            const unsigned = expr.cond.isUnsigned();
            if (unsigned) {
                try push_zext(c, left.reg, left.reg, @intCast(bits), node);
                try push_zext(c, right.reg, right.reg, @intCast(bits), node);
            } else {
                try push_sext(c, left.reg, left.reg, @intCast(bits), node);
                try push_sext(c, right.reg, right.reg, @intCast(bits), node);
            }
        }
        const code: cy.OpCode = switch (expr.cond) {
            .ult => .ult,
            .lt => .lt,
            .ule => .ule,
            .le => .le,
            .ugt => .ugt,
            .gt => .gt,
            .uge => .uge,
            .ge => .ge,
            else => return error.TODO,
        };
        try c.pushCode2(code, dst.isTemp(), &.{ dst.reg, left.reg, right.reg }, node);
    }
    try pop_temp_value(c, right, node);
    try pop_temp_value(c, left, node);
    return dst;
}

fn gen_fneg(c: *Chunk, expr: *ir.UnOp2, cstr: Cstr, node: *ast.Node) !GenValue {
    const dst = try bc.selectReg(c, expr.base.type, cstr, node);
    const childv = try genExpr(c, expr.expr, Cstr.localOrTemp());
    if (expr.base.type.id() == bt.F64) {
        try pushInlineUnExpr(c, .fneg, dst.reg, childv.reg, node);
    } else {
        try pushInlineUnExpr(c, .fneg32, dst.reg, childv.reg, node);
    }
    try pop_temp_value(c, childv, node);
    return dst;
}

fn gen_fmod(c: *Chunk, expr: *ir.BinOp2, cstr: Cstr, node: *ast.Node) !GenValue {
    const dst = try bc.selectReg(c, expr.base.type, cstr, node);
    const leftv = try genExpr(c, expr.left, Cstr.localOrTemp());
    const rightv = try genExpr(c, expr.right, Cstr.localOrTemp());
    if (expr.base.type.id() == bt.F64) {
        try pushInlineBinExpr(c, .fmod, dst, leftv.reg, rightv.reg, node);
    } else {
        try pushInlineBinExpr(c, .fmod32, dst, leftv.reg, rightv.reg, node);
    }
    try pop_temp_value(c, rightv, node);
    try pop_temp_value(c, leftv, node);
    return dst;
}

fn gen_fdiv(c: *Chunk, expr: *ir.BinOp2, cstr: Cstr, node: *ast.Node) !GenValue {
    const dst = try bc.selectReg(c, expr.base.type, cstr, node);
    const leftv = try genExpr(c, expr.left, Cstr.localOrTemp());
    const rightv = try genExpr(c, expr.right, Cstr.localOrTemp());
    if (expr.base.type.id() == bt.F64) {
        try pushInlineBinExpr(c, .fdiv, dst, leftv.reg, rightv.reg, node);
    } else {
        try pushInlineBinExpr(c, .fdiv32, dst, leftv.reg, rightv.reg, node);
    }
    try pop_temp_value(c, rightv, node);
    try pop_temp_value(c, leftv, node);
    return dst;
}

fn gen_fmul(c: *Chunk, expr: *ir.BinOp2, cstr: Cstr, node: *ast.Node) !GenValue {
    const dst = try bc.selectReg(c, expr.base.type, cstr, node);
    const leftv = try genExpr(c, expr.left, Cstr.localOrTemp());
    const rightv = try genExpr(c, expr.right, Cstr.localOrTemp());
    if (expr.base.type.id() == bt.F64) {
        try pushInlineBinExpr(c, .fmul, dst, leftv.reg, rightv.reg, node);
    } else {
        try pushInlineBinExpr(c, .fmul32, dst, leftv.reg, rightv.reg, node);
    }
    try pop_temp_value(c, rightv, node);
    try pop_temp_value(c, leftv, node);
    return dst;
}

fn gen_fsub(c: *Chunk, expr: *ir.BinOp2, cstr: Cstr, node: *ast.Node) !GenValue {
    const dst = try bc.selectReg(c, expr.base.type, cstr, node);
    const leftv = try genExpr(c, expr.left, Cstr.localOrTemp());
    const rightv = try genExpr(c, expr.right, Cstr.localOrTemp());
    if (expr.base.type.id() == bt.F64) {
        try pushInlineBinExpr(c, .fsub, dst, leftv.reg, rightv.reg, node);
    } else {
        try pushInlineBinExpr(c, .fsub32, dst, leftv.reg, rightv.reg, node);
    }
    try pop_temp_value(c, rightv, node);
    try pop_temp_value(c, leftv, node);
    return dst;
}

fn gen_fadd(c: *Chunk, expr: *ir.BinOp2, cstr: Cstr, node: *ast.Node) !GenValue {
    const dst = try bc.selectReg(c, expr.base.type, cstr, node);
    const leftv = try genExpr(c, expr.left, Cstr.localOrTemp());
    const rightv = try genExpr(c, expr.right, Cstr.localOrTemp());
    if (expr.base.type.id() == bt.F64) {
        try pushInlineBinExpr(c, .fadd, dst, leftv.reg, rightv.reg, node);
    } else {
        try pushInlineBinExpr(c, .fadd32, dst, leftv.reg, rightv.reg, node);
    }
    try pop_temp_value(c, rightv, node);
    try pop_temp_value(c, leftv, node);
    return dst;
}

/// `a + i * k` with a small constant `k` (pointer indexing) becomes one `add_mul_i16`, `a + k` one `add_i16`.
fn gen_add(c: *Chunk, expr: *ir.BinOp2, cstr: Cstr, node: *ast.Node) !GenValue {
    if (expr.right.code == .mul or expr.right.code == .imul) {
        const mul: *ir.BinOp2 = @ptrCast(@alignCast(expr.right));
        if (mul.right.code == .const64) {
            const k = mul.right.cast(.const64).val;
            if (k > 0 and k <= std.math.maxInt(u16)) {
                const dst = try bc.selectReg(c, expr.base.type, cstr, node);
                const leftv = try genExpr(c, expr.left, Cstr.localOrTemp());
                const idxv = try genExpr(c, mul.left, Cstr.localOrTemp());
                try c.pushCode2(.add_mul_i16, dst.isTemp(), &.{ dst.reg, leftv.reg, idxv.reg, @intCast(k) }, node);
                try pop_temp_value(c, idxv, node);
                try pop_temp_value(c, leftv, node);
                return dst;
            }
        }
    } else if (expr.right.code == .const64) {
        const k: i64 = @bitCast(expr.right.cast(.const64).val);
        if (k >= std.math.minInt(i16) and k <= std.math.maxInt(i16)) {
            const dst = try bc.selectReg(c, expr.base.type, cstr, node);
            const leftv = try genExpr(c, expr.left, Cstr.localOrTemp());
            const imm: i16 = @intCast(k);
            try c.pushCode2(.add_i16, dst.isTemp(), &.{ dst.reg, leftv.reg, @bitCast(imm) }, node);
            try pop_temp_value(c, leftv, node);
            return dst;
        }
    }
    return genBinOp2(c, expr, .add, cstr, node);
}

/// `a && k` with a constant `k` becomes one `and_64` with the constant inline (`Array.cap` mask in loops).
fn gen_and(c: *Chunk, expr: *ir.BinOp2, cstr: Cstr, node: *ast.Node) !GenValue {
    if (expr.right.code == .const64) {
        const k = expr.right.cast(.const64).val;
        const dst = try bc.selectReg(c, expr.base.type, cstr, node);
        const leftv = try genExpr(c, expr.left, Cstr.localOrTemp());
        const pc = c.buf.len();
        try c.pushCode2(.and_64, dst.isTemp(), &.{ dst.reg, leftv.reg, 0, 0, 0, 0 }, node);
        c.buf.setOpArgU64(pc + 3, k);
        try pop_temp_value(c, leftv, node);
        return dst;
    }
    return genBinOp2(c, expr, .and_, cstr, node);
}

fn genBinOp2(c: *Chunk, expr: *ir.BinOp2, op: cy.OpCode, cstr: Cstr, node: *ast.Node) !GenValue {
    const dst = try bc.selectReg(c, expr.base.type, cstr, node);
    const leftv = try genExpr(c, expr.left, Cstr.localOrTemp());
    const rightv = try genExpr(c, expr.right, Cstr.localOrTemp());
    try pushInlineBinExpr(c, op, dst, leftv.reg, rightv.reg, node);
    try pop_temp_value(c, rightv, node);
    try pop_temp_value(c, leftv, node);
    return dst;
}

/// A binary op whose result depends on the bits above the operand's width: division, remainder and
/// logical shift right. The upper bits of a narrow int register are undefined (`trunc` and a wrapped
/// `add` leave them as is), so both operands are extended in place first, like `genCompare`.
fn gen_width_binop(c: *Chunk, expr: *ir.BinOp2, op: cy.OpCode, signed: bool, cstr: Cstr, node: *ast.Node) !GenValue {
    const bits: u32 = switch (expr.left.type.kind()) {
        .int => expr.left.type.cast(.int).bits,
        .raw => expr.left.type.cast(.raw).bits,
        else => 64,
    };
    const dst = try bc.selectReg(c, expr.base.type, cstr, node);
    const leftv = try genExpr(c, expr.left, Cstr.localOrTemp());
    const rightv = try genExpr(c, expr.right, Cstr.localOrTemp());
    if (bits < 64) {
        if (signed) {
            try push_sext(c, leftv.reg, leftv.reg, @intCast(bits), node);
            try push_sext(c, rightv.reg, rightv.reg, @intCast(bits), node);
        } else {
            try push_zext(c, leftv.reg, leftv.reg, @intCast(bits), node);
            try push_zext(c, rightv.reg, rightv.reg, @intCast(bits), node);
        }
    }
    try pushInlineBinExpr(c, op, dst, leftv.reg, rightv.reg, node);
    try pop_temp_value(c, rightv, node);
    try pop_temp_value(c, leftv, node);
    return dst;
}

/// Arithmetic shift right. The instruction sign extends from the int's width since the upper bits
/// of a narrow int register are undefined.
fn gen_asr(c: *Chunk, expr: *ir.BinOp2, cstr: Cstr, node: *ast.Node) !GenValue {
    const bits = expr.base.type.cast(.int).bits;
    const dst = try bc.selectReg(c, expr.base.type, cstr, node);
    const leftv = try genExpr(c, expr.left, Cstr.localOrTemp());
    const rightv = try genExpr(c, expr.right, Cstr.localOrTemp());
    try c.pushCode2(.asr, dst.isTemp(), &.{ dst.reg, leftv.reg, rightv.reg, @intCast(bits) }, node);
    try pop_temp_value(c, rightv, node);
    try pop_temp_value(c, leftv, node);
    return dst;
}

fn genBinOp(c: *Chunk, expr: *ir.BinOp, cstr: Cstr, node: *ast.Node) !GenValue {
    // Most builtin binOps do not retain.
    const dst = try bc.selectReg(c, expr.base.type, cstr, node);

    const leftv = try genExpr(c, expr.left, Cstr.localOrTemp());
    const rightv = try genExpr(c, expr.right, Cstr.localOrTemp());

    switch (expr.op) {
        .bitwiseXor => {
            if (expr.leftT.id() == bt.I64) {
                try pushInlineBinExpr(c, getIntOpCode(expr.op), dst, leftv.reg, rightv.reg, node);
            } else return error.Unexpected;
        },
        .pow => {
            if (expr.leftT.id() == bt.F64) {
                try pushInlineBinExpr(c, getFloatOpCode(expr.op), dst, leftv.reg, rightv.reg, node);
            } else if (expr.leftT.id() == bt.I64) {
                try pushInlineBinExpr(c, getIntOpCode(expr.op), dst, leftv.reg, rightv.reg, node);
            } else return error.Unexpected;
        },
        .bang_equal,
        .equal_equal => {
            try pushCmp(c, expr.leftT, dst.reg, leftv.reg, rightv.reg, node);           
        },
        else => {
            return c.reportErrorFmt("Unsupported op: {}", &.{v(expr.op)}, node);
        },
    }

    if (expr.op == .bang_equal) {
        try c.pushFCode(.lnot, &.{dst.reg, dst.reg}, node);
    }

    try pop_temp_value(c, rightv, node);
    try pop_temp_value(c, leftv, node);

    return dst;
}

fn gen_trait(c: *Chunk, expr: *ir.Trait, cstr: Cstr, node: *ast.Node) !GenValue {
    const dst = try bc.selectReg(c, expr.base.type, cstr, node);
    const ref = try genExpr(c, expr.ref, Cstr.localOrTemp());

    const key = VtableKey{ .type = expr.impl_t.id(), .trait = expr.generic_t.base.id() };
    const vtable_idx = c.compiler.gen_vtables.get(key).?;

    try c.pushFCode(.trait, &.{ dst.reg, ref.reg, @intCast(expr.trait_t.id()), @intCast(vtable_idx) }, node);

    try pop_temp_value(c, ref, node);
    return dst;
}

fn gen_captured(c: *Chunk, expr: *ir.Captured, cstr: Cstr, node: *ast.Node) !GenValue {
    const dst = try bc.selectReg(c, expr.base.type, cstr, node);

    try c.pushCode(.captured, &.{ dst.reg, c.cur_proc.closure_local, expr.idx }, node);
    return dst;
}

/// Where an IR local lives while a proc is generated.
pub const LocalSlot = struct {
    reg: Reg,
    kind: enum(u8) {
        /// `reg` holds the local.
        reg,
        /// A pointer param of an inlined callee whose arg was `&local`: `reg` is that caller local.
        /// Field · deref accesses read its registers, and the pointer itself is materialized with `addr`
        /// only when the param is used as a value.
        addr_of,
    },
};

pub fn local_slot(c: *Chunk, ir_id: u8) LocalSlot {
    const idx = c.inline_local_base + ir_id;
    if (idx >= c.bc_local_map.items.len) {
        std.debug.panic("expected mapping to IR local `{}`.", .{ir_id});
    }
    return c.bc_local_map.items.ptr[idx];
}

pub fn toLocalReg(c: *Chunk, ir_id: u8) Reg {
    const slot = local_slot(c, ir_id);
    if (slot.kind != .reg) {
        std.debug.panic("IR local `{}` is bound to the address of a caller local.", .{ir_id});
    }
    return slot.reg;
}

fn push_load_32(c: *cy.Chunk, dst: Reg, src: Reg, src_off: u16, debugNode: *ast.Node) !void {
    try c.pushCode(.load_32, &.{ dst, src, src_off }, debugNode);
}

fn push_load_16(c: *cy.Chunk, dst: Reg, src: Reg, src_off: u16, debugNode: *ast.Node) !void {
    try c.pushCode(.load_16, &.{ dst, src, src_off }, debugNode);
}

fn push_load_8(c: *cy.Chunk, dst: Reg, src: Reg, src_off: u16, debugNode: *ast.Node) !void {
    try c.pushCode(.load_8, &.{ dst, src, src_off }, debugNode);
}

fn push_load_64(c: *cy.Chunk, dst: Reg, src: Reg, offset: u16, debugNode: *ast.Node) !void {
    try c.pushCode(.load_64, &.{ dst, src, offset }, debugNode);
}

fn push_load(c: *cy.Chunk, dst: Reg, src_ptr: Reg, src_off: u16, src_t: *cy.Type, node: *ast.Node) !void {
    const size = src_t.size();
    switch (size) {
        32 => {
            try c.pushCode(.load_4w, &.{ dst, src_ptr, src_off }, node);
        },
        24 => {
            try c.pushCode(.load_3w, &.{ dst, src_ptr, src_off }, node);
        },
        16 => {
            try c.pushCode(.load_2w, &.{ dst, src_ptr, src_off }, node);
        },
        8 => {
            try push_load_64(c, dst, src_ptr, src_off, node);
        },
        4 => {
            try push_load_32(c, dst, src_ptr, src_off, node);
        },
        2 => {
            try push_load_16(c, dst, src_ptr, src_off, node);
        },
        1 => {
            try push_load_8(c, dst, src_ptr, src_off, node);
        },
        0 => {},
        else => {
            try c.pushCode(.load_n, &.{ dst, src_ptr, src_off, @intCast(src_t.size()) }, node);
        },
    }
}

fn gen_local(c: *Chunk, expr: *ir.Local, cstr: Cstr, node: *ast.Node) !GenValue {
    const slot = local_slot(c, expr.id);
    if (slot.kind == .addr_of) {
        // The pointer param used as a value: the address of the caller local it is bound to.
        const dst = try selectReg(c, expr.base.type, cstr, node);
        if (dst.type != .discard) {
            try push_addr(c, dst.reg, slot.reg, node);
        }
        return dst;
    }
    const reg = slot.reg;
    if (cstr.type == .simple) {
        return GenValue.initLocal(reg);
    } else {
        const dst = try selectReg(c, expr.base.type, cstr, node);
        try push_mov(c, dst.reg, reg, @intCast(expr.base.type.reg_size()), node);
        return dst;
    }
}

fn gen_funcptr2(c: *Chunk, dst: Reg, func: *cy.Func, node: *ast.Node) !void {
    switch (func.type) {
        .extern_ => {
            const rt_id = c.compiler.genSymMap.get(func).?.extern_func.id;
            try c.pushCode(.extern_func, &.{ dst, @intCast(rt_id) }, node);
        },
        .hostFunc => {
            const start = c.buf.ops.items.len;
            try c.pushCode(.fn_host, &.{dst, 0, 0, 0}, node);
            c.buf.setOpArgU48(start + 2, @intCast(@intFromPtr(func.data.hostFunc.ptr)));
        },
        .userLambda,
        .userFunc => {
            const start = c.buf.ops.items.len;
            try c.pushCode(.fn_vm, &.{dst, 0, 0, 0}, node);
            try c.relocations.append(c.alloc, .{.kind = .func, .pc = start + 2, .data = .{.func = func}});
        },
        else => {
            @panic("unexpected");
        },
    }
}

fn gen_funcptr(c: *Chunk, expr: *ir.FuncPtr, cstr: Cstr, node: *ast.Node) !GenValue {
    const dst = try bc.selectReg(c, expr.base.type, cstr, node);
    try gen_funcptr2(c, dst.reg, expr.func, node);
    return dst;
}

fn genFuncUnion(c: *Chunk, expr: *ir.Func, cstr: Cstr, node: *ast.Node) !GenValue {
    const dst = try bc.selectReg(c, expr.base.type, cstr, node);
    const childv = try genExpr(c, expr.expr, Cstr.localOrTemp());

    try c.pushFCode(.fn_union, &.{ dst.reg, childv.reg, @intCast(expr.base.type.id()) }, node);
    try pop_temp_value(c, childv, node);
    return dst;
}

const NullSlot = cy.NullU8;

/// Reserve params and captured vars.
/// Function frame layout:
/// [ret 1+] [ret_info 1] [ret_pc 1] [ret_fp 1] [callee 1] [params...] [locals...]
/// `callee` is reserved so that function values can call static functions with the same call convention.
/// Captured vars are accessed from the closure in the callee slot.
fn reserveFuncSlots(c: *Chunk, params: []align(1) const ir.FuncParam, ret_t: *cy.Type) !void {
    // Reserve return.
    log.tracev("reserve func ret reg size: {}", .{ret_t.reg_size()});
    c.cur_proc.reg_end += @intCast(ret_t.reg_size());
    c.cur_proc.ret_size = @intCast(ret_t.reg_size());

    // Reserve return info, return address, previous frame pointer, and optional callee.
    c.cur_proc.reg_end += 4;

    // Closure local is the callee local.
    c.cur_proc.closure_local = @intCast(c.cur_proc.reg_end - 1);

    c.buf.ptr_layout_builder.clearRetainingCapacity();
    try c.buf.ptr_layout_builder.resize(c.alloc, c.cur_proc.reg_end);
    @memset(c.buf.ptr_layout_builder.items, false);

    c.bc_local_map.clearRetainingCapacity();

    // Reserve func params.
    for (params, 0..) |param, i| {
        log.tracev("reserve param {s} {}", .{param.name(), i});
        _ = try reserve_local(c, i, param.declType, c.cur_proc.debugNode);
    }

    c.cur_proc.max_regs = c.cur_proc.reg_end;
}

fn reserve_local(c: *Chunk, local_id_: usize, local_t: *cy.Type, node: *ast.Node) !Reg {
    const local_id = c.inline_local_base + local_id_;
    if (cy.Trace) {
        if (local_id != c.bc_local_map.items.len) {
            return c.reportErrorFmt("Expected next IR local to be {}, got {}.", &.{v(c.bc_local_map.items.len), v(local_id)}, node);
        }
    }
    std.debug.assert(local_id == c.bc_local_map.items.len);

    const reg = try reserve_reg(c, local_t);
    try c.bc_local_map.append(c.alloc, .{ .reg = reg, .kind = .reg });
    return reg;
}

fn reserve_reg(c: *Chunk, local_t: *cy.Type) !Reg {
    const reg = c.cur_proc.reg_end;
    log.tracev("reserve reg: {} {s}", .{reg, local_t.name()});
    const reg_size = type_reg_size(local_t);
    try c.buf.ptr_layout_builder.resize(c.alloc, reg + reg_size);

    c.cur_proc.reg_end += @intCast(reg_size);
    if (c.cur_proc.reg_end > c.cur_proc.max_regs) {
        c.cur_proc.max_regs = c.cur_proc.reg_end;
    }

    if (local_t.is_stack_ptr()) {
        c.buf.ptr_layout_builder.items[reg] = true;
        c.cur_proc.num_ptr_locals += 1;
        // Dump where ptr regs are reserved on the stack.
        // if (cy.Trace) {
        //     const buf = try c.alloc.print("ptr reg {}", .{reg});
        //     defer c.alloc.free(buf);
        //     try genNopLabel2(c, buf, c.ast.null_node);
        // }
    } else {
        if (reg_size == 1) {
            c.buf.ptr_layout_builder.items[reg] = false;
        } else {
            @memset(c.buf.ptr_layout_builder.items[reg..reg+reg_size], false);
        }
    }
    return reg;
}

fn gen_global(c: *Chunk, expr: *ir.Global, cstr: Cstr, node: *ast.Node) !GenValue {
    // const varId = c.compiler.genSymMap.get(expr.sym).?.varSym.id;

    const dst = try bc.selectReg(c, expr.base.type, cstr, node);

    const ptr = try reserve_reg(c, c.sema.ptr_void_t);
    _ = try gen_addr_global(c, expr.sym, Cstr.toTemp(ptr), node);

    try push_load(c, dst.reg, ptr, 0, expr.base.type, node);
    try pop_regs(c, ptr, node);

    // if (expr.sym.type == .extern_var) {
    //     try push_load_64(c, dst.reg, 0, dst.reg, node);
    // }
    return dst;
}

fn gen_set_global(c: *Chunk, stmt: *ir.SetGlobal, node: *ast.Node) !void {
    const ptr = try reserve_reg(c, c.sema.ptr_void_t);
    _ = try gen_addr_global(c, stmt.sym, Cstr.toTemp(ptr), node);

    const expr = try genExpr(c, stmt.expr, Cstr.localOrTemp());
    try push_store(c, ptr, 0, expr.reg, stmt.expr.type, node);
    try pop_regs(c, ptr, node);
}

pub fn type_reg_size(type_: *cy.Type) usize {
    return (type_.size() + 7) >> 3;
}

fn gen_discard(c: *Chunk, stmt: *ir.Discard, node: *ast.Node) !void {
    _ = node;
    const cstr = Cstr.discard();
    _ = try genExpr(c, stmt.expr, cstr);
}

fn gen_declare_local(c: *Chunk, stmt: *ir.DeclareLocal, node: *ast.Node) !void {
    // _ = node;
    const reg = try reserve_local(c, stmt.id, stmt.decl_t, node);
    log.tracev("declare local {} -> %{}, type: {s}", .{stmt.id, reg, stmt.decl_t.name()});

    if (stmt.init) |init| {
        _ = try genExpr(c, init, Cstr.toFreshLocal(reg));
    }
}

fn gen_set_captured(c: *Chunk, stmt: *ir.SetGeneric, node: *ast.Node) !void {
    _ = node;
    const capData = stmt.left.cast(.captured);

    // RHS.
    // const dstRetained = c.sema.isBoxedType(data.leftT.id);
    _ = try genExpr(c, stmt.right, Cstr.toCaptured(capData.idx, stmt.right.type.is_stack_ptr()));
}

fn gen_set_ret(c: *Chunk, stmt: *ir.SetReturn, node: *ast.Node) !void {
    _ = node;
    const dst = if (c.inline_ctx) |ctx| inline_ret_cstr(ctx) else Cstr.toLocal(0);
    _ = try genExpr(c, stmt.right, dst);
}

/// Destination of an inlined body's return value.
fn inline_ret_cstr(ctx: *InlineCtx) Cstr {
    return if (ctx.ret_is_temp) Cstr.toTemp(ctx.ret_reg) else Cstr.toLocal(ctx.ret_reg);
}

fn gen_set_local(c: *Chunk, stmt: *ir.SetLocal, node: *ast.Node) !void {
    _ = node;
    const reg = toLocalReg(c, stmt.id);
    _ = try genExpr(c, stmt.right, Cstr.toLocal(reg));
}

fn gen_ret(c: *Chunk, stmt: *ir.Return, node: *ast.Node) !void {
    if (c.inline_ctx) |ctx| {
        try inline_ret_jump(c, ctx, &stmt.base, node);
        return;
    }
    if (c.cur_proc.type == .main) {
        try c.pushCode(.end, &.{}, node);
    } else {
        try push_ret(c, c.cur_proc.ret_size, node);
    }
}

fn push_ret(c: *Chunk, ret_size: u16, node: *ast.Node) !void {
    if (ret_size == 0) {
        try c.pushCode(.ret_0, &.{}, node);
    } else if (c.cur_proc.ret_size == 1) {
        try c.pushCode(.ret, &.{}, node);
    } else {
        try c.pushCode(.ret_n, &.{c.cur_proc.ret_size}, node);
    }
}

fn gen_ret_gen(c: *Chunk, stmt: *ir.ReturnGen, node: *ast.Node) !void {
    const pc = c.buf.ops.items.len;

    var reg_size = stmt.gen_t.reg_size();
    if (stmt.next_t.reg_size() > reg_size) {
        reg_size = stmt.next_t.reg_size();
    }

    // `gen_t` is the returned `^Generator`. The heap object is the boxed `Generator`, so its type id is the
    // child's like any other box. The panic sweep and `@getDeinitObject` read the size and dtor from it.
    const box_t = stmt.gen_t.cast(.pointer).child_t;
    // The frame end (`reg_end`) is a placeholder. `genFuncBlock` patches it with the final frame size.
    std.debug.assert(c.cur_proc.ret_gen_pc == null);
    c.cur_proc.ret_gen_pc = pc;
    try c.pushFCode(.ret_gen, &.{ @intCast(box_t.id()), @intCast(reg_size), c.cur_proc.reg_end, 0 }, node);
    try genStmts(c, stmt.deinit_head);
    c.buf.ops.items[pc + 4].val = @intCast(c.buf.ops.items.len - pc);
}

fn gen_ret_expr(c: *Chunk, stmt: *ir.ReturnExpr, node: *ast.Node) !void {
    if (c.inline_ctx) |ctx| {
        _ = try genExpr(c, stmt.expr, inline_ret_cstr(ctx));
        try inline_ret_jump(c, ctx, &stmt.base, node);
        return;
    }
    if (c.cur_proc.type == .main) {
        // Main block.
        var childv: GenValue = undefined;
        childv = try genExpr(c, stmt.expr, Cstr.ret);
        try pop_temp_value(c, childv, node);

        try c.pushCode(.end, &.{}, node);
    } else {
        _ = try genExpr(c, stmt.expr, Cstr.toLocal(0));
        try push_ret(c, c.cur_proc.ret_size, node);
    }
}

pub fn reserveMainRegs(c: *Chunk) !void {
    // Reserve the first slot for the BC main frame check.
    c.cur_proc.reg_end += 1;

    c.buf.ptr_layout_builder.clearRetainingCapacity();
    try c.buf.ptr_layout_builder.resize(c.alloc, c.cur_proc.reg_end);
    @memset(c.buf.ptr_layout_builder.items, false);

    c.bc_local_map.clearRetainingCapacity();
}

pub const CallInst = struct {
    temp_start: Reg,

    // Reg for return info.
    base: Reg,

    ret: GenValue,
    has_final_dst: bool,
    final_dst: GenValue,
};

/// Returns gen strategy and advances the temp local.
pub fn beginCall(c: *Chunk, cstr: Cstr, ret_t: *cy.Type, hasCalleeValue: bool, node: *ast.Node) !CallInst {
    _ = node;

    var ret: GenValue = undefined;
    var has_final_dst = false;
    var final_dst: GenValue = undefined;
    var allocTempRet = true;

    const ret_reg_size = type_reg_size(ret_t);

    // Optimization: Check to use dst cstr as ret.
    if (cstr.type == .tempReg or cstr.type == .localReg) {
        // A generator call reserves its `?T` resume slot, which can be wider than the frame below it.
        if (c.cur_proc.reg_end >= ret_reg_size and cstr.data.slot.dst == c.cur_proc.reg_end - ret_reg_size) {
            if (cstr.data.slot.dst != 0) {
                if (cstr.type == .tempReg) {
                    ret = GenValue.initTemp(cstr.data.slot.dst);
                } else {
                    ret = GenValue.initLocal(cstr.data.slot.dst);
                }
                allocTempRet = false;

            }
        }
        if (allocTempRet) {
            has_final_dst = true;
            final_dst = GenValue.initTemp(cstr.data.slot.dst);
        }
    } else if (cstr.type == .discard) {
        ret = GenValue.discard();
        allocTempRet = false;
    }

    var temp_start = c.cur_proc.reg_end;
    if (allocTempRet) {
        const temp = try reserve_reg(c, ret_t);
        ret = GenValue.initTemp(temp);
        if (cy.Trace) std.debug.assert(ret.reg != 0);
    }

    const base = c.cur_proc.reg_end;
    if (!has_final_dst) {
        temp_start = base;
    }
    // Reserve registers for return info.
    _ = try reserve_reg(c, c.sema.i64_t);
    _ = try reserve_reg(c, c.sema.i64_t);
    _ = try reserve_reg(c, c.sema.i64_t);

    if (!hasCalleeValue) {
        // Reserve callee reg.
        _ = try reserve_reg(c, c.sema.i64_t);
    }

    return .{
        .temp_start = temp_start,
        .base = base,
        .ret = ret,
        .has_final_dst = has_final_dst,
        .final_dst = final_dst,
    };
}

pub fn push_mov(c: *Chunk, dst: Reg, src: Reg, reg_size: u16, node: *ast.Node) !void {
    if (dst == src) {
        return;
    }
    switch (reg_size) {
        0 => {},
        1 => {
            try c.pushCode(.mov, &.{dst, src}, node);
        },
        2 => {
            try c.pushCode(.mov_2, &.{dst, src}, node);
        },
        3 => {
            try c.pushCode(.mov_3, &.{dst, src}, node);
        },
        4 => {
            try c.pushCode(.mov_4, &.{dst, src}, node);
        },
        else => {
            try c.pushCode(.mov_n, &.{dst, src, reg_size}, node);
        },
    }
}

// In the case of generators, calls reserve the union return which can be bigger than the actual `ret_t`.
pub fn endCall(c: *Chunk, inst: CallInst, ret_t: *cy.Type, node: *ast.Node) !GenValue {
    if (inst.has_final_dst) {
        try push_mov(c, inst.final_dst.reg, inst.ret.reg, @intCast(ret_t.reg_size()), node);
        try pop_regs(c, inst.temp_start, node);
        return inst.final_dst;
    }
    try pop_regs(c, inst.temp_start, node);
    return inst.ret;
}

fn gen_loop_block(c: *cy.Chunk, stmt: *ir.LoopBlock, node: *ast.Node) !void {
    const top_pc = c.buf.ops.items.len;
    const jump_start: u32 = @intCast(c.blockJumpStack.items.len);

    try pushBlock(c, node);
    {
        c.cur_proc.loop_depth += 1;
        defer c.cur_proc.loop_depth -= 1;
        try genStmts(c, stmt.body_head);
        c.blockJumpStack.items.len = try c.patchForBlockJumps(jump_start, c.cur_proc.block_depth-1, c.buf.ops.items.len, top_pc, node);
    } 
    try popLoopBlock(c);
}

fn gen_for_range_stmt(c: *Chunk, stmt: *ir.ForRangeStmt, node: *ast.Node) !void {
    // Reserve vars until end of block, hidden from user.
    const counter = try reserve_reg(c, c.sema.i64_t);
    const cond = try reserve_reg(c, c.sema.bool_t);
    const rangeEnd = try bc.reserve_reg(c, c.sema.i64_t);

    // Range start.
    const startv = try genExpr(c, stmt.start, Cstr.localOrTemp());

    // Range end.
    const endv = try genExpr(c, stmt.end, Cstr.toTemp(rangeEnd));
    _ = endv;

    // Initialize counter.
    try push_mov(c, counter, startv.reg, 1, node);

    // Begin sub-block.
    try pushBlock(c, node);

    const iter_pc = c.buf.ops.items.len;

    // Perform comparison.
    if (stmt.increment) {
        if (stmt.end_inclusive) {
            try pushInlineBinExpr(c, .le, GenValue.initTemp(cond), counter, rangeEnd, node);
        } else {
            try pushInlineBinExpr(c, .lt, GenValue.initTemp(cond), counter, rangeEnd, node);
        }
    } else {
        if (stmt.end_inclusive) {
            try pushInlineBinExpr(c, .ge, GenValue.initTemp(cond), counter, rangeEnd, node);
        } else {
            try pushInlineBinExpr(c, .gt, GenValue.initTemp(cond), counter, rangeEnd, node);
        }
    }

    // Jump to end if cond is false.
    const exit_jump = try c.pushEmptyJumpNotCond(cond, node);

    // Copy counter.
    // TODO: Shouldn't be necessary since the counter will be read-only.
    var eachLocal: Reg = undefined;
    if (stmt.has_each_local) {
        try genStmts(c, stmt.declHead);
        eachLocal = toLocalReg(c, stmt.eachLocal);
        try push_mov(c, eachLocal, counter, 1, node);
    }

    const jumpStackSave = c.blockJumpStack.items.len;

    c.cur_proc.loop_depth += 1;
    try genStmts(c, stmt.bodyHead);
    c.cur_proc.loop_depth -= 1;

    const block_offset = c.cur_proc.block_depth - 1;
    try popLoopBlock(c);

    const cont_pc = c.buf.ops.items.len;

    // Update counter.
    var inc: u16 = undefined;
    if (stmt.increment) {
        inc = 1;
    } else {
        inc = @bitCast(@as(i16, -1));
    }
    try c.pushCode(.add_i16, &.{ counter, counter, inc}, node);

    try c.pushJumpBackTo(iter_pc, node);
    try c.patchJumpNotCondToCurPc(exit_jump, node);

    c.blockJumpStack.items.len = try c.patchForBlockJumps(jumpStackSave, block_offset, c.buf.ops.items.len, cont_pc, node);

    try pop_regs(c, counter, node);
}

fn verbose(c: *cy.Chunk, stmt: *ir.Verbose, node: *ast.Node) !void {
    _ = c;
    _ = node;
    cc.setVerbose(stmt.verbose);
}

fn gen_if_block(c: *cy.Chunk, stmt: *ir.IfBlock, node: *ast.Node) !void {
    const cond_n = stmt.cond_expr.node;
    var condv: GenValue = undefined;
    const jump_miss = try push_cond_miss_jump(c, stmt.cond_expr, &condv, node);

    try pushBlock(c, node);
    try genStmts(c, stmt.body_head);
    try popBlock(c);

    try c.patchJumpNotCondToCurPc(jump_miss, node);

    try pop_temp_value(c, condv, cond_n);
}

/// Jumps past a block when `cond` is false. `!x` (what `while opt |v|`, `for` iteration and `and`
/// lower to) tests `x` with `jump_t` instead of negating it first.
fn push_cond_miss_jump(c: *cy.Chunk, cond: *ir.Expr, condv: *GenValue, node: *ast.Node) !u32 {
    if (cond.code == .unary_op) {
        const un = cond.cast(.unary_op);
        if (un.op == .lnot) {
            condv.* = try genExpr(c, un.expr, Cstr.localOrTemp());
            return c.pushEmptyJumpCond(condv.reg, node);
        }
    }
    condv.* = try genExpr(c, cond, Cstr.localOrTemp());
    return c.pushEmptyJumpNotCond(condv.reg, node);
}

fn gen_switch_stmt(c: *Chunk, stmt: *ir.SwitchStmt, node: *ast.Node) !void {
    const childBreakJumpsStart: u32 = @intCast(c.blockJumpStack.items.len);
    _ = childBreakJumpsStart;

    const cases = stmt.cases[0..stmt.numCases];

    const caseBodyEndJumpsStart = c.listDataStack.items.len;

    var condMatchJumpsStart = c.listDataStack.items.len;

    var prevCaseMissJump: u32 = cy.NullId;
    for (cases) |case| {
        const case_n = case.node;
        const case_data = case.cast(.switch_case);
        const isElse = case_data.numConds == 0;

        // Jump here from prev case miss.
        if (prevCaseMissJump != cy.NullId) {
            try c.patchJumpToCurPc(prevCaseMissJump, node);
        }

        if (!isElse) {
            // const condMatchJumpsStart = c.listDataStack.items.len;
            const conds = case_data.conds[0..case_data.numConds];
            for (conds) |cond_loc| {
                const cond = cond_loc.cast(.case_cond);
                const cond_n = cond_loc.node;

                try genStmts(c, cond.body_head);
                const condv = try genExpr(c, cond.expr, Cstr.localOrTemp());

                const miss_jump = try c.pushEmptyJumpNotCond(condv.reg, cond_n);
                const match_jump = try c.pushEmptyJump(cond_n);
                try c.listDataStack.append(c.alloc, .{ .pc = match_jump });
                try c.patchJumpNotCondToCurPc(miss_jump, cond_n);
                // Miss continues to next cond.

                try pop_temp_value(c, condv, cond_n);
            }

            // No cond matches. Jump to next case.
            prevCaseMissJump = try c.pushEmptyJump(case_n);

            if (!case_data.fallthrough) {
                // Jump here from all matching conds.
                for (c.listDataStack.items[condMatchJumpsStart..]) |pc| {
                    try c.patchJumpToCurPc(pc.pc, case_n);
                }
                c.listDataStack.items.len = condMatchJumpsStart;
            } else {
                continue;
            }
        } else {
            prevCaseMissJump = cy.NullId;
        }

        try pushBlock(c, case_n);
        try genStmts(c, case_data.body_head);
        try popBlock(c);

        const caseBodyEndJump = try c.pushEmptyJump(node);
        try c.listDataStack.append(c.alloc, .{ .jumpToEndPc = caseBodyEndJump });

        condMatchJumpsStart = c.listDataStack.items.len;
    }

    // Jump here from prev case miss.
    if (prevCaseMissJump != cy.NullId) {
        try c.patchJumpToCurPc(prevCaseMissJump, node);
    }

    // Jump here from case body ends.
    for (c.listDataStack.items[caseBodyEndJumpsStart..]) |pc| {
        try c.patchJumpToCurPc(pc.jumpToEndPc, node);
    }
    c.listDataStack.items.len = caseBodyEndJumpsStart;
}

const ProcType = enum(u8) {
    main,
    func,
};

pub const Sym = union {
    varSym: struct {
        id: u32,
    },
    func: struct {
        static_pc: [*]cy.Inst,

        id: u32,
        // Offset from chunk's buffer to be used afterwards for relocation.
        pc: u32,
        end_pc: u32,
    },
    hostFunc: struct {
        id: u32,
        ptr: vmc.HostFn,
    },
    extern_func: bc.ExternFunc,
};

pub fn pushFuncBlock(c: *Chunk, data: *ir.FuncBlock, params: []align(1) const ir.FuncParam, node: *ast.Node) !void {
    log.tracev("push func block: params={}, method={}, {}", .{data.func.sig.params_len, data.func.isMethod(), node});
    try pushFuncBlockCommon(c, params, data.func, node);
}

fn pushFuncBlockCommon(c: *Chunk, params: []align(1) const ir.FuncParam, func: *cy.Func, node: *ast.Node) !void {
    const src_chunk = func.decl.?.src();
    try pushProc(c, .func, src_chunk, func, func.name(), node);

    // `reserveFuncRegs` may emit copy and box insts.
    var ret_t = func.sig.ret;
    if (func.info.generator) {
        const gen_t = ret_t.cast(.pointer).child_t;
        const val_t = gen_t.sym().instance.?.params[0].asPtr(*cy.Type).cast(.func_ptr).sig.ret;
        const next_t = try cy.sema.getOptionType(c, val_t);
        if (next_t.size() > ret_t.size()) {
            ret_t = next_t;
        }
    }
    try reserveFuncSlots(c, params, ret_t);
}

pub fn popFuncBlockCommon(c: *Chunk, func: *cy.Func) !void {
    _ = func;

    try popProc(c);
}

fn gen_lambda(c: *Chunk, expr: *ir.Lambda, cstr: Cstr, node: *ast.Node) !GenValue {
    const func = expr.func;

    const dst = try bc.selectReg(c, expr.base.type, cstr, node);

    const rt_id = try ensureFunc(c.compiler, func);
    _ = rt_id;
    if (expr.numCaptures == 0) {
        try gen_funcptr2(c, dst.reg, func, node);
    } else {
        const captures = expr.captures[0..expr.numCaptures];
        const start = c.buf.ops.items.len;
        const len_data: u16 = @as(u16, @intCast(captures.len)) | (@as(u16, @intFromBool(expr.pinned_closure)) << 15);
        // Allocates, so it can panic with `OutOfMemory`: the trace needs its debug sym.
        try c.pushFCodeExt(.closure, &.{
            dst.reg, @intCast(expr.base.type.id()), 0, 0, 0, len_data, 
        }, captures.len, node);
        try c.relocations.append(c.alloc, .{.kind = .func, .pc = start + 3, .data = .{.func = func}});
        for (captures, 0..) |irVar, i| {
            const reg = toLocalReg(c, irVar);
            c.buf.ops.items[start + 7 + i].val = reg;
        }
    }
    return dst;
}

fn gen_pop_locals(c: *Chunk, stmt: *ir.PopLocals, node: *ast.Node) !void {
    _ = node;
    const local_end = c.inline_local_base + stmt.local_end;
    const reg_start = toLocalReg(c, @intCast(stmt.local_end));
    c.bc_local_map.items.len = local_end;

    var num_ptr_locals: usize = 0;
    for (c.buf.ptr_layout_builder.items[reg_start..c.cur_proc.reg_end]) |ptr| {
        if (ptr) num_ptr_locals += 1;
    }
    if (num_ptr_locals > 0) {
        c.cur_proc.num_ptr_locals -= num_ptr_locals;
    }
    c.cur_proc.reg_end = reg_start;
}

fn gen_block(c: *Chunk, stmt: *ir.Block, node: *ast.Node) !void {
    try pushBlock(c, node);
    const jump_stack_start = c.blockJumpStack.items.len;
    try genStmts(c, stmt.bodyHead);
    c.blockJumpStack.items.len = try c.patchBreaks(jump_stack_start, c.cur_proc.block_depth - 1, c.buf.ops.items.len, node);
    try popBlock(c);
}

pub fn pushProc(c: *Chunk, btype: ProcType, src_chunk: u32, func: ?*cy.Func, name: []const u8, debugNode: *ast.Node) !void {
    const id = c.funcs_debug.items.len;
    try c.funcs_debug.append(c.alloc, .{ .func = func, .name = name, .src_chunk = src_chunk });
    try c.proc_stack.append(c.alloc, Proc.init(btype, id, c.id));
    c.cur_proc = &c.proc_stack.items[c.proc_stack.items.len-1];
    c.cur_proc.debugNode = debugNode;

    try pushBlock(c, debugNode);
}

pub fn popProc(c: *Chunk) !void {
    log.tracev("pop gen block", .{});

    try popBlock(c);

    std.debug.assert(c.cur_proc.reg_end == 0);

    var last = c.proc_stack.pop().?;
    std.debug.assert(last.num_ptr_locals == 0);

    last.deinit(c.alloc);
    if (c.proc_stack.items.len > 0) {
        c.cur_proc = &c.proc_stack.items[c.proc_stack.items.len-1];
    }
}

pub fn pushBlock(c: *Chunk, node: *ast.Node) !void {
    log.tracev("push block {}", .{c.cur_proc.block_depth});
    c.cur_proc.block_depth += 1;

    try c.blocks.append(c.alloc, .{
        .node = node,
        .local_start = c.bc_local_map.items.len,
        .reg_start = c.cur_proc.reg_end,
        .num_ptr_locals = 0,
        .saved_num_ptr_locals = c.cur_proc.num_ptr_locals,
    });

    if (cy.Trace) {
        c.indent += 1;
    }
}

pub fn popBlock(c: *Chunk) !void {
    log.tracev("pop block {}", .{c.cur_proc.block_depth});

    const b = c.blocks.pop().?;
    if (c.cur_proc.num_ptr_locals > b.saved_num_ptr_locals) {
        @memset(c.buf.ptr_layout_builder.items[b.reg_start..c.cur_proc.reg_end], false);
    }

    c.bc_local_map.items.len = b.local_start;
    c.cur_proc.reg_end = b.reg_start;
    c.cur_proc.num_ptr_locals = b.saved_num_ptr_locals;
    c.cur_proc.block_depth -= 1;

    if (cy.Trace) {
        c.indent -= 1;
    }
}

pub fn popLoopBlock(c: *Chunk) !void {
    try popBlock(c);
}

pub const Block = struct {
    node: *ast.Node,

    local_start: usize,
    reg_start: Reg,

    // Alive pointer locals.
    num_ptr_locals: usize,

    saved_num_ptr_locals: usize,

    last_ptr_layout: []const bool = &.{},
    last_ptr_layout_id: usize = 0,
};

pub const Proc = struct {
    type: ProcType,

    /// Index into `Chunk.funcs_debug`.
    id: u32,

    /// Chunk that the function belongs to.
    chunk_id: u32,

    /// If the function body belongs to a closure, the callee reg
    /// contains the closure's value which is then used to perform captured var lookup.
    closure_local: Reg,

    /// End of the current reg range.
    reg_end: Reg,

    ret_size: u16,

    /// Track the max number of registers used to know the stack size required by the block.
    max_regs: Reg,

    debugNode: *ast.Node,

    block_depth: u32,

    /// Nesting of loops being generated, including loops of inlined bodies. A call in a loop is a hot site.
    loop_depth: u32 = 0,

    // Alive pointer locals.
    num_ptr_locals: usize,

    /// Pc of the generator function's `ret_gen`. Its frame end operand is patched with the final frame size.
    ret_gen_pc: ?usize = null,

    /// LLVM

    fn init(btype: ProcType, id: usize, chunk_id: u32) Proc {
        return .{
            .id = @intCast(id),
            .chunk_id = chunk_id,
            .type = btype,
            .closure_local = cy.NullU8,
            .max_regs = 0,
            .reg_end = 0,
            .ret_size = 0,
            .debugNode = undefined,
            .block_depth = 0,
            .num_ptr_locals = 0,
        };
    }

    fn deinit(self: *Proc, alloc: std.mem.Allocator) void {
        _ = self;
        _ = alloc;
    }
};

fn genConst64_(c: *cy.Chunk, val: u64, dst: Reg, node: *ast.Node) !void {
    const pc = c.buf.len();
    try c.pushCode(.const_64, &.{ dst, 0, 0, 0, 0 }, node);
    c.buf.setOpArgU64(pc + 2, val);
}

const LocalId = u8;

const GenValueType = enum {
    discard,
    local,
    temp,
};

/// Returned from `genExpr`.
pub const GenValue = struct {
    type: GenValueType = undefined,

    /// Where the value was generated to.
    reg: Reg = undefined,

    fn discard() GenValue {
        return .{
            .type = .discard,
            .reg = 255,
        };
    }

    pub fn initLocal(reg: Reg) GenValue {
        return .{
            .type = .local,
            .reg = reg,
        };
    }

    pub fn initTemp(reg: Reg) GenValue {
        return .{
            .type = .temp,
            .reg = reg,
        };
    }

    pub fn isTemp(self: GenValue) bool {
        return self.type == .temp;
    }
};

fn pushRelease(c: *Chunk, slot_id: Reg, optional: bool, deinit_obj: *cy.Func, node: *ast.Node) !void {
    const pc = c.buf.ops.items.len;
    if (optional) {
        try c.pushCode(.release_opt, &.{slot_id, 0}, node);
    } else {
        try c.pushCode(.release, &.{slot_id, 0}, node);
    }

    // const name = try c.sema.allocTypeName(val_t);
    // defer c.alloc.free(name);
    // try genNopLabel2(c, name, node);

    const ret = c.cur_proc.reg_end;
    try push_mov(c, ret + 4, slot_id, 1, node);
    // const func = try ensureFunc(c.compiler, deinit_obj);
    try pushCall(c, @intCast(ret), deinit_obj, node);

    // Patch jump.
    c.buf.ops.items[pc + 2].val = @intCast(c.buf.ops.items.len - pc);
}

fn gen_const64(c: *Chunk, expr: *ir.Const64, cstr: Cstr, node: *ast.Node) !GenValue {
    const dst = try bc.selectReg(c, expr.base.type, cstr, node);
    switch (expr.base.type.id()) {
        bt.I64 => {
            try genConstInt(c, @bitCast(expr.val), dst, node);
        },
        else => {
            try genConst64_(c, expr.val, dst.reg, node);
        },
    }
    return dst;
}

fn genConstInt(c: *Chunk, val: i64, dst: GenValue, node: *ast.Node) !void {
    // TODO: Can be constU8.
    if (val >= 0 and val <= std.math.maxInt(i16)) {
        try c.pushCode2(.const_16s, dst.isTemp(), &.{ dst.reg, @bitCast(@as(i16, @intCast(val))) }, node);
        return;
    }
    try genConst64_(c, @bitCast(val), dst.reg, node);
}

fn get_uniq_ptr_layout(c: *cy.Chunk, layout: []const bool) !usize {
    const b = c.genBlock();
    if (std.mem.eql(bool, b.last_ptr_layout, layout)) {
        return b.last_ptr_layout_id;
    }

    const res = try c.buf.ptr_layout_map.getOrPut(c.alloc, layout);
    if (!res.found_existing) {
        // The new entry's key still points at the caller's `layout`.
        errdefer c.buf.ptr_layout_map.removeByPtr(res.key_ptr);
        try c.buf.ptr_layouts.ensureUnusedCapacity(c.alloc, 1);
        const dupe = try c.alloc.dupe(bool, layout);
        const id = c.buf.ptr_layouts.items.len;
        c.buf.ptr_layouts.appendAssumeCapacity(dupe);
        res.key_ptr.* = dupe;
        res.value_ptr.* = id;
    }
    b.last_ptr_layout = res.key_ptr.*;
    b.last_ptr_layout_id = res.value_ptr.*;
    return res.value_ptr.*;
}

fn pushCall(c: *cy.Chunk, base: Reg, func: *cy.Func, node: *ast.Node) !void {
    const start = c.buf.ops.items.len;
    switch (func.type) {
        .userFunc => {
            try c.pushFCode(.call, &.{ base, 0, 0, 0 }, node);
            try c.relocations.append(c.alloc, .{.kind = .func, .pc = start + 2, .data = .{.func = func}});
        },
        .hostFunc => {
            try c.pushFCode(.call_host, &.{ base, 0, 0, 0 }, node);
            c.buf.setOpArgU48(start + 2, @intCast(@intFromPtr(func.data.hostFunc.ptr)));
        },
        .extern_ => {
            try c.pushFCode(.call_host, &.{ base, 0, 0, 0 }, node);
            try c.rt_relocations.append(c.alloc, .{.kind = .func, .pc = start + 2, .data = .{.func = func}});
        },
        .vm_extern_variant => {
            try c.pushFCode(.call_host, &.{ base, 0, 0, 0 }, node);
            try c.rt_relocations.append(c.alloc, .{.kind = .func, .pc = start + 2, .data = .{.func = func}});
        },
        else => {
            std.debug.panic("Unexpected: {}", .{func.type});
        },
    }

    try push_site_ptr_layout(c, start);
}

/// Records the current proc's live pointer locals at a site that can be suspended under a callee frame
/// (`call` · `call_host` · `call_ptr` · `call_union` · `call_trait`, `gen_next`, `gen_end`). Growing the stack
/// patches the frame's stack pointers from this layout (F-10: the indirect calls used to have no entry).
fn push_site_ptr_layout(c: *cy.Chunk, pc: usize) !void {
    if (c.cur_proc.num_ptr_locals > 0) {
        const layout = try get_uniq_ptr_layout(c, c.buf.ptr_layout_builder.items);
        try c.buf.ptr_table.append(c.alloc, .{
            .pc = @intCast(pc),
            .layout = @intCast(layout),
        });
    }
}

fn pushInlineUnExpr(c: *cy.Chunk, code: cy.OpCode, dst: Reg, child: Reg, node: *ast.Node) !void {
    try c.pushFCode(code, &.{ dst, child }, node);
}

fn pushInlineBinExpr(c: *cy.Chunk, code: cy.OpCode, dst: GenValue, left: Reg, right: Reg, node: *ast.Node) !void {
    try c.pushFCode2(code, dst.isTemp(), &.{ dst.reg, left, right }, node);
}

fn mainEnd(c: *cy.Chunk, node: *ast.Node) !void {
    try c.pushCode(.end, &.{}, node);
}

fn getIntUnaryOpCode(op: cy.UnaryOp) cy.OpCode {
    return switch (op) {
        .bitwiseNot => .not,
        .minus => .neg,
        else => cy.fatal(),
    };
}

fn getFloatUnaryOpCode(op: cy.UnaryOp) cy.OpCode {
    return switch (op) {
        .minus => .fneg,
        else => cy.fatal(),
    };
}

fn getFloatOpCode(op: cy.BinaryExprOp) cy.OpCode {
    return switch (op) {
        .less => .flt,
        .greater => .fgt,
        .less_equal => .fle,
        .greater_equal => .fge,
        .minus => .fsub,
        .plus => .fadd,
        .slash => .fdiv,
        .percent => .fmod,
        .star => .fmul,
        else => cy.fatal(),
    };
}

fn getIntOpCode(op: cy.BinaryExprOp) cy.OpCode {
    return switch (op) {
        .less => .lt,
        .greater => .gt,
        .less_equal => .le,
        .greater_equal => .ge,
        .minus => .sub,
        .plus => .add,
        .slash => .div,
        .percent => .mod,
        .star => .mul,
        .pow => .pow,
        .bitwiseAnd => .and_,
        .bitwiseOr => .or_,
        .bitwiseXor => .xor,
        .bitwiseLeftShift => .lsl,
        .bitwiseRightShift => .lsr,
        else => cy.fatal(),
    };
}

fn push_new(c: *cy.Chunk, dst: Reg, type_: *cy.Type, val_size: u16, node: *ast.Node) !void {
    // Failable: the allocation panics with `OutOfMemory` when the heap can not grow.
    try c.pushFCode(.new, &.{ dst, @intCast(type_.id()), val_size }, node);
}

fn push_struct_init_to(c: *cy.Chunk, dst_ptr: Reg, fields: []const cy.types.Field, args: []const Reg, node: *ast.Node) !void {
    for (fields, 0..) |field, i| {
        try push_store(c, dst_ptr, @intCast(field.offset), args[i], field.type, node);
    }
}

fn push_new_init(c: *cy.Chunk, dst: Reg, type_: *cy.Type, val_size: u16, fields: []const cy.types.Field, args: []const Reg, node: *ast.Node) !void {
    try c.pushFCode(.new, &.{ dst, @intCast(type_.id()), val_size }, node);
    for (fields, 0..) |field, i| {
        try push_store(c, dst, @intCast(field.offset), args[i], field.type, node);
    }
}

pub fn selectReg(c: *Chunk, val_t: *cy.Type, cstr: Cstr, node: *ast.Node) !GenValue {
    _ = node;
    switch (cstr.type) {
        .localReg => {
            return GenValue.initLocal(cstr.data.slot.dst);
        },
        .tempReg => {
            return GenValue.initTemp(cstr.data.slot.dst);
        },
        .simple => {
            const reg = try reserve_reg(c, val_t);
            return GenValue.initTemp(reg);
        },
        .discard => {
            return GenValue.discard();
        },
        else => {
            return error.Unsupported;
        },
    }
}

const CstrType = enum(u8) {
    /// 1. Prefers local register first.
    /// 2. Allocates the next temp.
    simple,

    /// To a temp register.
    tempReg,

    /// To a local register.
    localReg,

    /// Captured.
    captured,

    discard,
};

/// Constraints on where a value should go to.
///
/// Some constraints have a `retain` flag.
/// If `retain` is true, the caller expects the value to have increased it's RC by 1.
///     * If the value already has a +1 retain (e.g. a lifted rvalue), the requirement is satisfied.
///     * If the value comes from a local, then a retain copy is generated.
///     * If the value does not have a RC, the requirement is satisfied.
/// If `retain` is false, the value can still be retained by +1 to keep it alive.
pub const Cstr = struct {
    type: CstrType,

    data: union {
        simple: struct {
        },
        slot: struct {
            dst: Reg,
            /// A local being declared: nothing in the init expression can name it, so an `init` writes
            /// its fields straight into it like a temp.
            fresh: bool = false,
        },
        varSym: struct {
            // Runtime id.
            id: u32,
        },
        captured: struct {
            is_stack_ptr: bool,
            idx: u8,
        },
        uninit: void,
    } = .{ .uninit = {} },

    /// TODO: provide hint whether the allocated reill be used or not.
    /// e.g. For expr statements, the top level expr reg isn't used.
    /// If it's not used and the current expr does not produce side-effects, it can omit generating its code.

    pub fn localOrTemp() Cstr {
        return .{
            .type = .simple,
            .data = .{ .simple = .{}},
        };
    }

    pub const ret = Cstr{ .type = .localReg, .data = .{ .slot = .{
        .dst = 0,
    }}};

    pub fn discard() Cstr {
        return .{ .type = .discard, .data = undefined };
    }

    pub fn toCaptured(idx: u8, is_stack_ptr: bool) Cstr {
        return .{ .type = .captured, .data = .{ .captured = .{
            .is_stack_ptr = is_stack_ptr,
            .idx = idx,
        }}};
    }

    pub fn toTemp(reg: Reg) Cstr {
        return .{ .type = .tempReg, .data = .{ .slot = .{
            .dst = reg,
        }}};
    }

    pub fn toFreshLocal(reg: Reg) Cstr {
        return .{ .type = .localReg, .data = .{ .slot = .{
            .dst = reg,
            .fresh = true,
        }}};
    }

    pub fn toLocal(reg: Reg) Cstr {
        return .{ .type = .localReg, .data = .{ .slot = .{
            .dst = reg,
        }}};
    }
};

pub fn pop_temp_value(c: *Chunk, val: GenValue, node: *ast.Node) !void {
    if (val.type == .temp) {
        try pop_regs(c, val.reg, node);
    }
}

pub fn pop_regs(c: *Chunk, end: Reg, node: *ast.Node) !void {
    log.tracev("trunc regs to: {}, cur={}", .{end, c.cur_proc.reg_end});
    if (end > c.cur_proc.reg_end) {
        return c.reportErrorFmt("Expected to trunc regs to {}, but found {}.", &.{v(end), v(c.cur_proc.reg_end)}, node);
    }
    if (end + 1 == c.cur_proc.reg_end) {
        if (c.buf.ptr_layout_builder.items[end]) {
            c.cur_proc.num_ptr_locals -= 1;
        }
        c.buf.ptr_layout_builder.items.len -= 1;
    } else {
        var num_stack_ptrs: usize = 0;
        for (c.buf.ptr_layout_builder.items[end..c.cur_proc.reg_end]) |ptr| {
            if (ptr) {
                num_stack_ptrs += 1;
            }
        }
        if (num_stack_ptrs > 0) {
            c.cur_proc.num_ptr_locals -= num_stack_ptrs;
        }
        c.buf.ptr_layout_builder.items.len -= c.cur_proc.reg_end - end;
    }
    c.cur_proc.reg_end = end;
}

pub const RelocationKind = enum(u8) {
    func,
    extern_func_ptr,
    global,
};

pub const Relocation = struct {
    kind: RelocationKind,
    // relative pos to a *align(2) u48
    pc: usize,
    data: union {
        extern_func_ptr: *cy.types.FuncPtr,
        func: *cy.Func,
        global: usize,
    },
}; 

fn push_zext(c: *cy.Chunk, dst: Reg, src: Reg, bits: u8, node: *ast.Node) !void {
    try c.pushCode(.zext, &.{ dst, src, bits }, node);
}

fn push_sext(c: *cy.Chunk, dst: Reg, src: Reg, bits: u8, node: *ast.Node) !void {
    try c.pushCode(.sext, &.{ dst, src, bits }, node);
}
