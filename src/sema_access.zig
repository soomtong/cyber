const std = @import("std");
const cy = @import("cyber.zig");
const ir = cy.ir;
const bt = cy.types.BuiltinTypes;
const sema_func = cy.sema_func;
const sema_type = cy.sema_type;
const Argument = cy.sema_func.Argument;
const fmt = cy.fmt;
const v = fmt.v;
const module = cy.module;
const ast = cy.ast;
const Sym = cy.Sym;
const sema = cy.sema;
const sema_local = cy.sema_local;
const sema_call = cy.sema_call;
const sema_expr = cy.sema_expr;
const sema_hint = cy.sema_hint;
const sema_move = cy.sema_move;

pub fn semaIndexExpr2(c: *cy.Chunk, left: sema.ExprResult, left_n: *ast.Node, arg0: sema.ExprResult, arg0_n: *ast.Node, node: *ast.Node) !sema.ExprResult {
    const leftT = left.type;

    const sym = try c.accessResolvedSymOrFail(leftT, "@index", node);
    const func_sym = try sema_call.requireFuncSym(c, sym, node);

    const args = [2]sema_func.Argument{
        sema_func.Argument.initReceiver(left_n, left),
        sema_func.Argument.initPreResolved(arg0_n, arg0),
    };
    return c.semaCallFuncSymRec2(func_sym, &args, node);
}

/// The end of `a..=b` as an exclusive end: `b + 1`.
pub fn semaRangeEndPlusOne(c: *cy.Chunk, end: *ast.Node) !sema.ExprResult {
    const end_res = try c.semaExprCstr(end, c.sema.i64_t);
    const one = try c.semaConst(1, c.sema.i64_t, end);
    const add = try c.ir.newExpr(.add, c.sema.i64_t, end, .{
        .left = end_res.ir,
        .right = one.ir,
    });
    return sema.ExprResult.initOwned(add);
}

fn semaSliceExpr(c: *cy.Chunk, left: *ast.Node, left_res: sema.ExprResult, range: *ast.Range, node: *ast.Node) !sema.ExprResult {
    //     // TODO: This auto conversion to `uint` should be defined by another `uint` compatible type that allows implicit conversion from `int`.
    //     //       @index doesn't need this special treatment since it accepts only one index arg.
    //     const start_res = try semaUintIndex(c, start);
    const sym = try c.accessResolvedSymOrFail(left_res.type, "@slice", node);
    const func_sym = try sema_call.requireFuncSym(c, sym, node);
    if (!range.inc) {
        return c.reportError("A decreasing range can not be a slice index.", @ptrCast(range));
    }
    if (range.end_inclusive) {
        // `a[i..=j]` is `a[i..j+1]`. The receiver and the start are evaluated before the end.
        const seq_start = c.seq_pending.items.len;
        errdefer sema_move.seqPop(c, seq_start);
        var recv_res = left_res;
        try sema_move.seqPushRes(c, &recv_res, left);
        var start_res = if (range.start) |start|
            try c.semaExprCstr(start, c.sema.i64_t)
        else
            try c.semaConst(0, c.sema.i64_t, @ptrCast(range));
        try sema_move.seqPushRes(c, &start_res, @ptrCast(range));
        const end_res = try semaRangeEndPlusOne(c, range.end.?);
        sema_move.seqPop(c, seq_start);
        const args = [_]sema_func.Argument{
            sema_func.Argument.initReceiver(left, recv_res),
            sema_func.Argument.initPreResolved(range.start orelse @ptrCast(range), start_res),
            sema_func.Argument.initPreResolved(range.end.?, end_res),
        };
        return c.semaCallFuncSymRec2(func_sym, &args, node);
    }
    if (range.start == null) {
        if (range.end) |end| {
            // `a[..end]` is `a[0..end]`.
            const zero = try c.semaConst(0, c.sema.i64_t, @ptrCast(range));
            const args = [_]sema_func.Argument{
                sema_func.Argument.initReceiver(left, left_res),
                sema_func.Argument.initPreResolved(@ptrCast(range), zero),
                sema_func.Argument.init(end),
            };
            return c.semaCallFuncSymRec2(func_sym, &args, node);
        }
        const args = [_]sema_func.Argument{
            sema_func.Argument.initReceiver(left, left_res),
        };
        return c.semaCallFuncSymRec2(func_sym, &args, node);
    }

    const start_arg = sema_func.Argument.init(range.start.?);
    if (range.end) |end| {
        const args = [_]sema_func.Argument{
            sema_func.Argument.initReceiver(left, left_res),
            // sema_func.Argument.initPreResolved(@ptrCast(range), start_res),
            // sema_func.Argument.initPreResolved(@ptrCast(range), end_res),
            start_arg,
            sema_func.Argument.init(end),
        };
        return c.semaCallFuncSymRec2(func_sym, &args, node);
    } else {
        const args = [_]sema_func.Argument{
            sema_func.Argument.initReceiver(left, left_res),
            // sema_func.Argument.initPreResolved(@ptrCast(range), start_res),
            start_arg,
        };
        return c.semaCallFuncSymRec2(func_sym, &args, node);
    }
}

pub fn sema_ptr_index(c: *cy.Chunk, ptr: sema.ExprResult, idx: sema.ExprResult, node: *ast.Node) !sema.ExprResult {
    const child_t = ptr.type.cast(.pointer).child_t;

    const intptr = try sema_expr.sema_bitcast_nocheck(c, ptr, c.sema.i64_t, node);
    const elem_size = try c.semaConst(@intCast(child_t.size()), c.sema.i64_t, node);
    const offset = try c.ir.newExpr(.mul, idx.type, node, .{
        .left = idx.ir,
        .right = elem_size.ir,
    });
    const expr = try c.ir.newExpr(.add, idx.type, node, .{
        .left = intptr.ir,
        .right = offset,
    });
    var res = try sema_expr.sema_bitcast_nocheck(c, sema.ExprResult.init2(expr), ptr.type, node);
    res.addressable = ptr.addressable;
    return res;
}

pub fn semaIndexExpr(c: *cy.Chunk, left: *ast.Node, left_res: sema.ExprResult, cstr: sema.Cstr, node: *ast.Node) !sema.ExprResult {
    const index_expr = node.cast(.index_expr);
    if (index_expr.args.len != 1) {
        return c.reportErrorFmt("Unsupported array expr.", &.{}, node);
    }

    if (index_expr.args.ptr[0].type() == .range) {
        return semaSliceExpr(c, left, left_res, index_expr.args.ptr[0].cast(.range), node);
    }

    const leftT = left_res.type;
    if (leftT.isPointer()) {
        // The pointer is evaluated before a statement that the index adds (`seqFlush`).
        var ptr_res = left_res;
        const seq_start = c.seq_pending.items.len;
        errdefer sema_move.seqPop(c, seq_start);
        try sema_move.seqPushRes(c, &ptr_res, left);
        const idx = try c.semaExprCstr(index_expr.args.ptr[0], c.sema.i64_t);
        sema_move.seqPop(c, seq_start);
        const res = try sema_ptr_index(c, ptr_res, idx, node);
        return sema_expr.semaDeref(c, res, node);
    }

    const args = [2]sema_func.Argument{
        sema_func.Argument.initReceiver(left, left_res),
        sema_func.Argument.init(index_expr.args.ptr[0]),
    };

    // Will first look for @index_addr.
    if (try c.accessResolvedSym(leftT, "@index_addr", node)) |sym| {
        const func_sym = try sema_call.requireFuncSym(c, sym, node);
        var res = try c.semaCallFuncSymRec2(func_sym, &args, node);
        res.addressable = true;

        if (res.type.isPointer() or res.type.kind() == .borrow) {
            return sema_expr.semaDeref(c, res, node);
        } else if (res.type.isInstanceOf(c.sema.ref_child_tmpl)) {
            const ptr_t = res.type.cast(.struct_t).fields_ptr[1].type;
            if (cstr.target_t) |target_t| {
                if (target_t.id() == res.type.id()) {
                    // Target wants the RefChild.
                    return res;
                }
            }
            // `semaField` will manage the RefChild.
            res = try semaField(c, res, node, 1, ptr_t, node);
            return sema_expr.semaDeref(c, res, node);
        } else {
            return c.reportErrorFmt("Expected `Ptr`, `Borrow`, or `RefChild` return type for `@index_addr`.", &.{}, node);
        }
    } else {
        if (cstr.use_as_borrow) {
            return c.reportErrorFmt("Cannot borrow. Missing `@index_addr`.", &.{}, node);
        }
    }

    // Fallback to @index.
    const sym = try c.accessResolvedSymOrFail(leftT, "@index", node);
    const func_sym = try sema_call.requireFuncSym(c, sym, node);
    return c.semaCallFuncSymRec2(func_sym, &args, node);
}

pub fn semaUnwrapResultNoCheck(c: *cy.Chunk, rec: sema.ExprResult, node: *ast.Node) !sema.ExprResult {
    const base_t = rec.type.getBaseType();
    if (base_t.kind() != .result) {
        return c.reportErrorFmt("Expected result type.", &.{}, node);
    }
    const payload_t = base_t.cast(.result).child_t;

    const final_rec = try sema_move.semaManage(c, rec, node);
    var loc = try c.ir.newExpr(.field, payload_t, node, .{
        .idx = 1,
        .rec = final_rec.ir,
    });
    loc = try c.ir.newExpr(.case, payload_t, node, .{
        .child = loc,
        .union_t = rec.type,
        .case = 1,
    });
    var res = sema.ExprResult.initField(loc, final_rec.recParentLocal());
    res.addressable = final_rec.addressable;
    return res;
}

pub fn semaUnwrapResultErrorNoCheck(c: *cy.Chunk, rec: sema.ExprResult, node: *ast.Node) !sema.ExprResult {
    const base_t = rec.type.getBaseType();
    if (base_t.kind() != .result) {
        return c.reportErrorFmt("Expected result type.", &.{}, node);
    }
    const final_rec = try sema_move.semaManage(c, rec, node);
    var loc = try c.ir.newExpr(.field, c.sema.error_t, node, .{
        .idx = 1,
        .rec = final_rec.ir,
    });
    loc = try c.ir.newExpr(.case, c.sema.error_t, node, .{
        .child = loc,
        .union_t = rec.type,
        .case = 0,
    });
    var res = sema.ExprResult.initField(loc, final_rec.recParentLocal());
    res.addressable = final_rec.addressable;
    return res;
}

pub fn semaUnwrapOptionNoCheck(c: *cy.Chunk, rec: sema.ExprResult, node: *ast.Node) !sema.ExprResult {
    if (rec.type.kind() != .option) {
        return c.reportErrorFmt("Expected option type.", &.{}, node);
    }

    const option_t = rec.type.cast(.option);
    if (option_t.zero_union) {
        return rec;
    } else {
        const final_rec = try sema_move.semaManage(c, rec, node);
        const loc = try c.ir.newExpr(.field, option_t.child_t, node, .{
            .idx = 1,
            .rec = final_rec.ir,
        });
        const parent_local = try final_rec.recParentLocalOrError(c, node);
        var res = sema.ExprResult.initField(loc, parent_local);
        res.addressable = true;
        return res;
    }
}

fn semaAccessChoicePayload(c: *cy.Chunk, rec: sema.ExprResult, name: []const u8, node: *ast.Node) !sema.ExprResult {
    const sym = rec.type.sym().getMod().getSym(name) orelse {
        return c.reportErrorFmt("Choice case `{}` does not exist in `{}`.", &.{v(name), v(rec.type.name())}, node);
    };
    if (sym.type != .choice_case) {
        return c.reportErrorFmt("Choice `{}` does not have a case named `{}`.", &.{v(rec.type.name()), v(name)}, node);
    }
    const final_rec = try sema_move.semaManage(c, rec, node);
    const payload_t = sym.cast(.choice_case).payload_t;
    const loc = try c.ir.newExpr(.field, payload_t, node, .{
        .idx = 1,
        .rec = final_rec.ir,
    });
    var res = sema.ExprResult.initCustom(loc, .field, payload_t, undefined);
    res.addressable = true;
    return res;
}

/// `check_visible` is false for `meta.access`: metaprogramming reads the fields that `type.info` lists,
/// private ones included (docs/decisions/project_symbol_visibility.md).
fn semaAccessFieldName(c: *cy.Chunk, rec_n: *ast.Node, rec: sema.ExprResult, name: []const u8, field: *ast.Node, check_visible: bool) !sema.ExprResult {
    var type_ = rec.type;

    if (type_.kind() == .c_union) {
        const mod = type_.sym().getMod();
        const sym = mod.getSym(name) orelse {
            const type_name = try c.sema.allocTypeName(type_);
            defer c.alloc.free(type_name);
            return c.reportErrorFmt("Case `{}` does not exist in `{}`.", &.{v(name), v(type_name)}, field);
        };

        if (sym.type != .union_case) {
            return c.reportErrorFmt("`{}` is not a union case.", &.{v(name)}, field);
        }
        const case = sym.cast(.union_case);

        var final_rec = rec;
        if (!rec.addressable) {
            final_rec = try sema_move.semaManage(c, rec, rec_n);
        }
        var loc = try c.ir.newExpr(.field, case.payload_t, field, .{
            .idx = 0,
            .rec = final_rec.ir,
        });
        loc = try c.ir.newExpr(.case, case.payload_t, field, .{
            .child = loc,
            .union_t = rec.type,
            .case = case.idx,
        });

        const parent_local = final_rec.recParentLocal();
        var res = sema.ExprResult.initField(loc, parent_local);
        res.addressable = true;
        return res;
    }

    type_ = type_.getBaseType();
    const mod = type_.sym().getMod();

    if (c.compiler.record_refs) {
        if (mod.getSym(name)) |member| cy.refs.recordSym(c, field, name, member);
    }
    const sym = mod.getSym(name) orelse {
        if (type_.has_embeddings()) {
            if (try sema_call.get_embedded_sym(c, type_.cast(.struct_t), name, @ptrCast(field))) |embedded_res| {
                if (embedded_res.sym.type == .field) {
                    const embedded_field = embedded_res.sym.cast(.field);
                    const final_rec = try semaField(c, rec, @ptrCast(field), embedded_res.field_idx, embedded_res.embedded_t, @ptrCast(field));
                    return semaField(c, final_rec, @ptrCast(field), embedded_field.idx, embedded_field.type, @ptrCast(field));
                }
            }
        }

        if (try c.getResolvedSym(&type_.sym().head, "@get", field)) |get_sym| {
            const func_sym = try sema_call.requireFuncSym(c, get_sym, field);

            const field_name = try c.heap.init_eval_str(name);
            defer c.heap.release(field_name);

            const args = [_]sema_func.Argument{
                sema_func.Argument.initReceiver(rec_n, rec),
                sema_func.Argument.initPreResolved(field, sema.ExprResult.initCtValue2(c.sema.eval_str_t, field_name)),
            };
            var call = try c.semaCallFuncSymRec2(func_sym, &args, field);
            const parent_local = rec.recParentLocal();
            call = sema.ExprResult.initField(call.ir, parent_local);
            call.owned = true;
            return call;
        }

        var child_t: *cy.Type = undefined;
        if (type_.kind() == .pointer) {
            child_t = type_.cast(.pointer).child_t;
        } else if (type_.kind() == .borrow) {
            child_t = type_.cast(.borrow).child_t;
        } else if (type_.kind() == .ex_borrow) {
            child_t = type_.cast(.ex_borrow).child_t;
        } else {
            const type_name = try c.sema.allocTypeName(type_);
            defer c.alloc.free(type_name);
            const hint = try sema_hint.suggestField(c, type_, name, field);
            return c.reportErrorFix("Field `{}` does not exist in `{}`.{}", &.{v(name), v(type_name), v(hint)}, field, sema_hint.suggestedFix(c, name, field));
        }
        const child_ts = child_t.sym();
        const sym = child_ts.getMod().getSym(name) orelse {
            const type_name = try c.sema.allocTypeName(child_t);
            defer c.alloc.free(type_name);
            const hint = try sema_hint.suggestField(c, child_t, name, field);
            return c.reportErrorFix("Field `{}` does not exist in `{}`.{}", &.{v(name), v(type_name), v(hint)}, field, sema_hint.suggestedFix(c, name, field));
        };
        if (check_visible) try cy.module.check_sym_visible(c, sym, field);
        if (sym.type != .field) {
            const type_name = try c.sema.allocTypeName(child_t);
            defer c.alloc.free(type_name);
            return reportNotField(c, type_name, name, sym, field);
        }
        const field_s = sym.cast(.field);
        // Access on typed pointer.
        const final_rec = try sema_move.semaManage(c, rec, rec_n);
        const loc = try c.ir.newExpr(.field, field_s.type, field, .{
            .idx = @intCast(field_s.idx),
            .rec = final_rec.ir,
        });

        const parent_local = final_rec.recParentLocal();
        var res = sema.ExprResult.initField(loc, parent_local);
        res.addressable = true;
        return res;
    };
    if (check_visible) try cy.module.check_sym_visible(c, sym, field);
    if (sym.type != .field) {
        return reportNotField(c, type_.name(), name, sym, field);
    }
    const field_sym = sym.cast(.field);
    return semaField(c, rec, rec_n, field_sym.idx, field_sym.type, field);
}

/// `name` is a member of the type but not a field. A method of the same name is suggested with a call: `s.len()`.
pub fn reportNotField(c: *cy.Chunk, type_name: []const u8, name: []const u8, sym: *cy.Sym, node: *ast.Node) error{CompileError, OutOfMemory, FormatError, WriteFailed} {
    if (sym.type == .func) {
        sema_hint.setSuggestNew("{s}()", .{name});
        return c.reportErrorFix("Type `{}` does not have a field named `{}`. Did you mean the method `{}()`?", &.{v(type_name), v(name), v(name)}, node, sema_hint.suggestedFix(c, name, node));
    }
    return c.reportErrorFmt("Type `{}` does not have a field named `{}`.", &.{v(type_name), v(name)}, node);
}

/// The accessed member is alive when any of its states is active.
/// A nested struct member stays accessible while only some of its own members were moved out.
fn check_struct_access_path(c: *cy.Chunk, node: *ast.Node) !void {
    const fields = c.proc().var_active_struct_fields.get(c.temp_access_path.var_id).?;
    const start = c.temp_access_path.struct_field_offset;
    const states = fields[start..start + c.temp_access_path.state_len];
    if (states.len == 0 or std.mem.findScalar(bool, states, true) != null) {
        return;
    } else {
        return c.reportError("Member is no longer alive.", node);
    }
}

/// A partially moved value can not be used as a whole (copied, borrowed, moved): the moved members are dead.
/// `expr` carries the access path from `semaLocal` / `semaField` when its root local has inactive members.
pub fn checkPartialMoveWhole(c: *cy.Chunk, expr: sema.ExprResult, action: []const u8, node: *ast.Node) !void {
    if (!expr.check_struct_field_access) {
        return;
    }
    const fields = c.proc().var_active_struct_fields.get(c.temp_access_path.var_id).?;
    const start = c.temp_access_path.struct_field_offset;
    const states = fields[start..start + c.temp_access_path.state_len];
    if (std.mem.findScalar(bool, states, false) != null) {
        return c.reportErrorFmt("Cannot {} a partially moved value.", &.{v(action)}, node);
    }
}

pub fn ensure_partial_struct_layout(c: *cy.Chunk, fields: []bool) !*sema.PartialStructLayout {
    const res = try c.sema.partial_struct_layouts.getOrPut(c.alloc, fields);
    if (!res.found_existing) {
        const dupe = try c.alloc.dupe(bool, fields);
        res.key_ptr.* = dupe;
        res.value_ptr.* = try c.alloc.create(sema.PartialStructLayout);
        res.value_ptr.*.* = .{
            .fields = dupe,
        };
    }
    return res.value_ptr.*;
}

/// Backtrack from ExprResult to build temp access path.
pub fn build_move_access_path(c: *cy.Chunk, res: sema.ExprResult, node: *ast.Node) !bool {
    const var_id = res.recParentLocal() orelse {
        return c.reportError("Can only move a local or local member.", node);
    };
    c.temp_access_path.var_id = var_id;
    c.temp_access_path.struct_field_offset = 0;
    c.temp_access_path.state_len = 1;
    var expr = res.ir;
    var field_access = false;
    var root = true;
    // The member being moved is the outermost field access, or the first one after a choice payload unwrap.
    var moved_member_known = false;
    while (true) {
        switch (expr.code) {
            .local => {
                if (expr.type.isObjectLike() and !root) {
                    return c.reportError("Cannot move a member from a shared reference.", node);
                }
                return field_access;
            },
            .field => {
                const field = expr.cast(.field);
                const member_t = expr.type;
                expr = field.rec;
                if (expr.type.isObjectLike()) {
                    return c.reportError("Cannot move a member from a shared reference.", node);
                }
                const rec_struct = expr.type.cast(.struct_t);
                if (rec_struct.base.sym().has_decl("@deinit")) {
                    return c.reportErrorFmt("Cannot move a member out of `{}`. The type has a custom `@deinit`.", &.{v(expr.type.name())}, node);
                }
                const state_offset = rec_struct.fields()[field.idx].state_offset;
                c.temp_access_path.struct_field_offset += state_offset;
                if (!moved_member_known) {
                    c.temp_access_path.state_len = sema_type.fieldStateLen(member_t);
                    moved_member_known = true;
                }
                field_access = true;
            },
            .deref => {
                expr = expr.cast(.deref).expr;
            },
            .unwrap_addr => {
                expr = expr.cast(.unwrap_addr).choice;
                c.temp_access_path.struct_field_offset = 0;
                moved_member_known = false;
            },
            .address_of => {
                expr = expr.cast(.address_of).expr;
            },
            else => {
                return c.reportError("Can only move a local or local member.", node);
            },
        }
        root = false;
    }
}

pub fn semaField(c: *cy.Chunk, rec: sema.ExprResult, rec_n: *ast.Node, idx: usize, field_t: *cy.Type, node: *ast.Node) !sema.ExprResult {
    var final_rec = rec;
    if (!rec.addressable) {
        final_rec = try sema_move.semaManage(c, rec, rec_n);
    }
    const expr = try c.ir.newExpr(.field, field_t, node, .{
        .idx = @intCast(idx),
        .rec = final_rec.ir,
    });

    // const parent_local = try final_rec.recParentLocalOrError(c, node);
    const parent_local = final_rec.recParentLocal();
    var res = sema.ExprResult.initField(expr, parent_local);

    // final_rec is ensured to be addressable.
    res.addressable = final_rec.addressable;
    if (rec.check_struct_field_access and rec.type.kind() == .struct_t) {
        step_member_access_path(c, rec.type, idx, field_t);
        try check_struct_access_path(c, node);
        res.check_struct_field_access = true;
    }
    return res;
}

/// Advance `c.temp_access_path` from a struct `rec_t` to its member `idx` of type `field_t`.
/// A struct with a custom `@deinit` occupies a single state (`sema_type.fieldStateLen`) and is moved as a whole,
/// so its members share that state and the path stays on it. Stepping into them with `fieldStateLen(field_t)`
/// would read the states of the following members (or past the end of the state vector) (F-80).
pub fn step_member_access_path(c: *cy.Chunk, rec_t: *cy.Type, idx: usize, field_t: *cy.Type) void {
    if (rec_t.sym().has_decl("@deinit")) {
        return;
    }
    c.temp_access_path.struct_field_offset += rec_t.cast(.struct_t).fields()[idx].state_offset;
    c.temp_access_path.state_len = sema_type.fieldStateLen(field_t);
}

pub fn checkSymInitField(c: *cy.Chunk, type_sym: *cy.Sym, name: []const u8, node: *ast.Node) !InitFieldResult {
    const sym = type_sym.getMod().?.getSym(name) orelse {
        // // TODO: This depends on @get being known, make sure @get is a nested declaration.
        // const type_e = c.sema.types.items[type_sym.getStaticType().?];
        // if (type_e.has_get) {
        //     return .{ .idx = undefined, .typeId = undefined, .use_get_method = true };
        // } else {
            const type_name = type_sym.name();
            return c.reportErrorFmt("Field `{}` does not exist in `{}`.", &.{v(name), v(type_name)}, node);
        // }
    };
    try cy.module.check_sym_visible(c, sym, node);
    if (c.compiler.record_refs) {
        // The name of a field in an initializer: `Vec2{x = 1.0}`.
        cy.refs.recordSym(c, node, name, sym);
    }
    if (sym.type != .field) {
        const type_name = type_sym.name();
        return c.reportErrorFmt("Type `{}` does not have a field named `{}`.", &.{v(type_name), v(name)}, node);
    }
    const field = sym.cast(.field);
    return .{
        .idx = @intCast(field.idx),
        .type = field.type,
    };
}

const SetFieldResult = struct {
    type: *cy.Type,
    idx: u8,
    use_set_method: bool,
};

const InitFieldResult = struct {
    type: *cy.Type,
    idx: u8,
};

pub fn semaAccessExpr(c: *cy.Chunk, access: *ast.AccessExpr, prefer_ct_sym: bool, target_t: ?*cy.Type) !sema.ExprResult {
    const right_name = access.right.as_name();
    return semaAccessExpr2(c, access.left, right_name, access.right, prefer_ct_sym, target_t);
}

pub fn semaAccessExpr2(c: *cy.Chunk, left_n: *ast.Node, right_name: []const u8, right_n: *ast.Node, prefer_ct_sym: bool, target_t: ?*cy.Type) !sema.ExprResult {
    return semaAccessExpr3(c, left_n, right_name, right_n, prefer_ct_sym, target_t, true);
}

/// `meta.access(rec, name)`. A field of a value is read whatever its visibility. A member of a module or a type
/// is still looked up like `rec.name`.
pub fn semaMetaAccess(c: *cy.Chunk, left_n: *ast.Node, right_name: []const u8, right_n: *ast.Node) !sema.ExprResult {
    return semaAccessExpr3(c, left_n, right_name, right_n, false, null, false);
}

fn semaAccessExpr3(c: *cy.Chunk, left_n: *ast.Node, right_name: []const u8, right_n: *ast.Node, prefer_ct_sym: bool, target_t: ?*cy.Type, check_visible: bool) !sema.ExprResult {
    if (!check_visible and left_n.type() == .ident) {
        // A type parameter such as `%T type` is a compile-time `type` value: `meta.access(T, name)`
        // looks up `name` in the type like `T.name` does. Only `meta.access` checks this, so that
        // `rec.name` looks up `rec` once.
        const ident = try sema_local.lookupIdent(c, left_n.cast(.ident).name.slice(), left_n);
        if (ident == .ct_value) {
            const ct_value = ident.ct_value;
            defer c.heap.destructValue(ct_value);
            if (ct_value.type.id() == bt.Type) {
                const sym: *Sym = @ptrCast(ct_value.value.asPtr(*cy.Type).sym());
                const rightSym = try c.getResolvedSymOrFail(sym, right_name, right_n);
                return sema_expr.symbol2(c, rightSym, prefer_ct_sym, target_t, right_n);
            }
        }
    }
    const rec = try c.semaExprSkipSym(left_n, .{});
    if (rec.resType == .sym) {
        const sym = rec.data.sym;
        if (sym.getStaticType() == c.sema.symbol_t) {
            // `symbol.name` is a symbol literal, like `error.Name`.
            return sema_expr.sema_at_symbol(c, right_name, right_n);
        }
        const rightSym = try c.getResolvedSymOrFail(sym, right_name, right_n);
        return sema_expr.symbol2(c, rightSym, prefer_ct_sym, target_t, right_n);
    } else {
        return semaAccessFieldName(c, left_n, rec, right_name, right_n, check_visible);
    }
}
