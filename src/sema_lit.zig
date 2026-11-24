const std = @import("std");
const stdx = @import("stdx");
const cy = @import("cyber.zig");
const ir = cy.ir;
const bt = cy.types.BuiltinTypes;
const fmt = cy.fmt;
const v = fmt.v;
const ast = cy.ast;
const Value = cy.Value;
const sema = cy.sema;
const sema_borrow = cy.sema_borrow;
const sema_type = cy.sema_type;
const sema_call = cy.sema_call;
const sema_expr = cy.sema_expr;
const sema_hint = cy.sema_hint;
const sema_move = cy.sema_move;
const sema_init = cy.sema_init;

pub fn semaStringTarget(c: *cy.Chunk, lit: []const u8, opt_target: ?*cy.Type, node: *ast.Node) !sema.ExprResult {
    if (opt_target) |target_t| {
        if (target_t.isPointer()) {
            const child_t = target_t.cast(.pointer).child_t;
            if (child_t.id() == bt.R8 or child_t.id() == bt.I8) {
                return c.semaStringAs(lit, target_t, node);
            }
        }

        var base_t = target_t;
        if (target_t.kind() == .option) {
            base_t = target_t.cast(.option).child_t;
        }

        var target_bits: ?u32 = null;
        if (base_t.id() == bt.Type) {
            // `type` is a host type with an integer layout. A code point is not a type.
        } else if (base_t.kind() == .int) {
            target_bits = base_t.cast(.int).bits;
        } else if (base_t.kind() == .raw) {
            target_bits = base_t.cast(.raw).bits;
        }
        if (target_bits) |bits| {
            if (try semaTryStringLitCodepoint(c, lit, bits, node)) |val| {
                switch (bits) {
                    8 => return semaConst8(c, val.byte, base_t, node),
                    16 => return semaConst16(c, val.u16, base_t, node),
                    32 => return semaConst32(c, val.u32, base_t, node),
                    64 => return semaConst(c, val.val, base_t, node),
                    else => @panic("unexpected"),
                }
            }
        }
    }        
    return semaStringAs(c, lit, c.sema.str_t, node);
}

pub fn semaString(c: *cy.Chunk, lit: []const u8, node: *ast.Node) !sema.ExprResult {
    return semaStringAs(c, lit, c.sema.str_t, node);
}

pub fn semaStringAs(c: *cy.Chunk, lit: []const u8, type_: *cy.Type, node: *ast.Node) !sema.ExprResult {
    const raw = c.unescapeString(lit) catch |err| {
        if (err == error.InvalidEscapeSeq) return reportEscapeError(c, lit, node);
        return err;
    };
    if (raw.ptr != lit.ptr) {
        // Dupe and track in ast.strs.
        const dupe = try c.alloc.dupe(u8, raw);
        c.parser.ast.strs.append(c.alloc, dupe) catch |err| {
            c.alloc.free(dupe);
            return err;
        };
        return c.semaRawStringAs(dupe, type_, node);
    } else {
        return c.semaRawStringAs(raw, type_, node);
    }
}

pub fn semaRawString(c: *cy.Chunk, raw: []const u8, node: *ast.Node) !sema.ExprResult {
    return semaRawStringAs(c, raw, c.sema.str_t, node);
}

pub fn semaRawStringAs(c: *cy.Chunk, raw: []const u8, type_: *cy.Type, node: *ast.Node) !sema.ExprResult {
    const expr = try c.ir.newExpr(.string, type_, node, .{ .raw_ptr = raw.ptr, .raw_len = raw.len });
    return sema.ExprResult.initOwned(expr);
}

pub fn semaConst16(c: *cy.Chunk, val: u16, type_: *cy.Type, node: *ast.Node) !sema.ExprResult {
    const expr = try c.ir.newExpr(.const16, type_, node, .{ .val = val });
    return sema.ExprResult.init2(expr);
}

pub fn semaConst32(c: *cy.Chunk, val: u32, type_: *cy.Type, node: *ast.Node) !sema.ExprResult {
    const expr = try c.ir.newExpr(.const32, type_, node, .{ .val = val });
    return sema.ExprResult.init2(expr);
}

pub fn semaConst(c: *cy.Chunk, val: u64, type_: *cy.Type, node: *ast.Node) !sema.ExprResult {
    const expr = try c.ir.newExpr(.const64, type_, node, .{ .val = val });
    return sema.ExprResult.init2(expr);
}

pub fn semaConst8(c: *cy.Chunk, val: u8, type_: *cy.Type, node: *ast.Node) !sema.ExprResult {
    const expr = try c.ir.newExpr(.const8, type_, node, .{ .val = val });
    return sema.ExprResult.init2(expr);
}

pub fn semaVoid(c: *cy.Chunk, node: *ast.Node) !sema.ExprResult {
    const loc = try c.ir.newExpr(.voidv, c.sema.void_t, node, .{});
    return sema.ExprResult.init(loc, c.sema.void_t);
}

pub fn semaTrue(c: *cy.Chunk, node: *ast.Node) !sema.ExprResult {
    const loc = try c.ir.newExpr(.truev, c.sema.bool_t, node, .{});
    return sema.ExprResult.init(loc, c.sema.bool_t);
}

pub fn semaFalse(c: *cy.Chunk, node: *ast.Node) !sema.ExprResult {
    const irIdx = try c.ir.newExpr(.falsev, c.sema.bool_t, node, .{});
    return sema.ExprResult.init(irIdx, c.sema.bool_t);
}

/// `buf` is assumed to be big enough.
pub fn unescapeString(buf: []u8, literal: []const u8, always_copy: bool) ![]const u8 {
    var i = std.mem.findScalar(u8, literal, '\\') orelse {
        if (always_copy) {
            @memcpy(buf[0..literal.len], literal);
            return buf[0..literal.len];
        } else {
            return literal;
        }
    };
    @memcpy(buf[0..i], literal[0..i]);
    var len = i;
    var res = try unescapeSeq(literal[i+1..]);
    buf[len] = res.char;
    len += 1;
    var rest = literal[i+1+res.advance..];

    while (true) {
        i = std.mem.findScalar(u8, rest, '\\') orelse break;
        @memcpy(buf[len..len+i], rest[0..i]);
        len += i;
        res = try unescapeSeq(rest[i+1..]);
        buf[len] = res.char;
        len += 1;
        rest = rest[i+1+res.advance..];
    }

    @memcpy(buf[len..len+rest.len], rest);
    return buf[0..len+rest.len];
}

const CharAdvance = struct {
    char: u8,
    advance: u8,

    pub fn init(char: u8, advance: u8) CharAdvance {
        return CharAdvance{ .char = char, .advance = advance };
    }
};

/// Reports the first escape sequence in `lit` that `unescapeSeq` does not take.
fn reportEscapeError(c: *cy.Chunk, lit: []const u8, node: *ast.Node) anyerror {
    var i: usize = 0;
    while (std.mem.findScalarPos(u8, lit, i, '\\')) |pos| {
        const seq = lit[pos + 1 ..];
        if (unescapeSeq(seq)) |res| {
            i = pos + 1 + res.advance;
            continue;
        } else |_| {}
        if (seq.len == 0) break;
        if (seq[0] == 'x') {
            const end = @min(seq.len, 3);
            return c.reportErrorFmt("Invalid escape sequence `\\{}`. `\\x` takes two hex digits: `\\x41`. Write `\\\\` for a backslash.", &.{v(seq[0..end])}, node);
        }
        const len = std.unicode.utf8ByteSequenceLength(seq[0]) catch 1;
        const end = @min(seq.len, len);
        return c.reportErrorFmt("Invalid escape sequence `\\{}`. A backslash in a string is followed by one of: n t r 0 a b e \\ ' \" ` xHH. Write `\\\\{}` for a backslash.", &.{v(seq[0..end]), v(seq[0..end])}, node);
    }
    return c.reportErrorFmt("Invalid escape sequence. A string can not end with a single backslash. Write `\\\\` for a backslash.", &.{}, node);
}

pub fn unescapeSeq(seq: []const u8) error{InvalidEscapeSeq}!CharAdvance {
    if (seq.len == 0) {
        return error.InvalidEscapeSeq;
    }
    switch (seq[0]) {
        'a' => {
            return CharAdvance.init(0x07, 1);
        },
        'b' => {
            return CharAdvance.init(0x08, 1);
        },
        'e' => {
            return CharAdvance.init(0x1b, 1);
        },
        'n' => {
            return CharAdvance.init('\n', 1);
        },
        'r' => {
            return CharAdvance.init('\r', 1);
        },
        't' => {
            return CharAdvance.init('\t', 1);
        },
        '\\' => {
            return CharAdvance.init('\\', 1);
        },
        '"' => {
            return CharAdvance.init('"', 1);
        },
        '\'' => {
            return CharAdvance.init('\'', 1);
        },
        '0' => {
            return CharAdvance.init(0, 1);
        },
        '`' => {
            return CharAdvance.init('`', 1);
        },
        'x' => {
            if (seq.len < 3) {
                return error.InvalidEscapeSeq;
            }
            const ch = std.fmt.parseInt(u8, seq[1..3], 16) catch return error.InvalidEscapeSeq;
            return CharAdvance.init(ch, 3);
        },
        else => {
            return error.InvalidEscapeSeq;
        }
    }
}

pub fn semaTryStringLitCodepoint(c: *cy.Chunk, lit: []const u8, bits: u32, node: *ast.Node) !?cy.Value {
    if (lit.len == 0) {
        return null;
    }
    if (lit[0] == '\\') {
        const res = unescapeSeq(lit[1..]) catch {
            return reportEscapeError(c, lit, node);
        };
        if (lit.len > res.advance + 1) {
            return null;
        }

        return Value.initRaw(res.char);
    } else {
        const len = std.unicode.utf8ByteSequenceLength(lit[0]) catch {
            return null;
        };
        if (lit.len != len) {
            return null;
        }
        const val = stdx.utf8Decode(lit[0..0+len]) catch {
            return null;
        };
        if (val <= 0xFF) {
            const byte: u8 = @intCast(val);
            return Value.initRaw(byte);
        } else {
            if (bits >= 32) {
                return Value.initRaw(val);
            } else {
                return null;
            }
        }
    }
}

pub fn semaStringLitCodepoint(c: *cy.Chunk, lit: []const u8, node: *ast.Node) !u64 {
    if (lit.len == 0) {
        return c.reportErrorFmt("Invalid UTF-8 Rune.", &.{}, node);
    }
    var val: u64 = undefined;
    if (lit[0] == '\\') {
        const res = unescapeSeq(lit[1..]) catch {
            return reportEscapeError(c, lit, node);
        };
        val = res.char;
        if (lit.len > res.advance + 1) {
            return c.reportErrorFmt("Invalid escape sequence.", &.{}, node);
        }
    } else {
        const len = std.unicode.utf8ByteSequenceLength(lit[0]) catch {
            return c.reportErrorFmt("Invalid UTF-8 Rune.", &.{}, node);
        };
        if (lit.len != len) {
            return c.reportErrorFmt("Invalid UTF-8 Rune.", &.{}, node);
        }
        val = stdx.utf8Decode(lit[0..0+len]) catch {
            return c.reportErrorFmt("Invalid UTF-8 Rune.", &.{}, node);
        };
    }
    return val;
}

pub fn semaFitTarget(c: *cy.Chunk, expr: sema.ExprResult, target_t: *cy.Type, node: *ast.Node) !?sema.ExprResult {
    switch (target_t.kind()) {
        .struct_t => {
            // if (target_t.id() == bt.Object and expr.type.id() != bt.Object) {
            //     if (expr.type.isObjectLike()) {
            //         // Ensure `deinitObject` for child type.
            //         if (expr.type.kind() == .pointer) {
            //             _ = try getDeinitObjFunc(c, expr.type.getRefLikeChild().?, node);
            //         } else {
            //             _ = try getDeinitObjFunc(c, expr.type, node);
            //         }

            //         // Cast.
            //         var owned = try semaOwn(c, expr, node);
            //         owned = try sema_object(c, owned, node);
            //         owned.owned = true;
            //         return owned;
            //     }
            // }
        },
        .option => {
            // Check if type is compatible with Optional's some payload.
            const child_t = target_t.cast(.option).child_t;
            if (expr.type.id() == child_t.id()) {
                return try sema_init.semaWrapSome(c, target_t.cast(.option), expr, node);
            }
        },
        .result => {
            if (expr.type.id() == bt.Error) {
                return try sema_init.semaInitChoice(c, target_t, 0, 0, expr, node);
            }

            const child_t = target_t.cast(.result).child_t;
            if (expr.type.id() == child_t.id()) {
                const owned = try sema_move.semaOwn(c, expr, node);
                return try sema_init.semaInitChoice(c, target_t, 1, 1, owned, node);
            }

            // Does not match the child type. Attempt to fit child type.
            // T -> !S
            // T -> !?T
            if (try semaFitTarget(c, expr, child_t, node)) |new| {
                return try sema_init.semaInitChoice(c, target_t, 1, 1, new, node);
            }
        },
        .ref_trait => {
            if (expr.type.isRefPointer()) {
                const child_t = expr.type.cast(.pointer).child_t;
                if (child_t.kind() == .struct_t) {
                    if (child_t.cast(.struct_t).implements(target_t.cast(.ref_trait).generic)) {
                        try sema_type.checkDynReceivers(c, child_t, target_t.cast(.ref_trait).generic, node);
                        _ = try sema.getDeinitObjFunc(c, child_t, node);
                        const loc = try c.ir.newExpr(.trait, target_t, node, .{
                            .ref = expr.ir,
                            .impl_t = child_t,
                            .trait_t = target_t,
                            .generic_t = target_t.cast(.ref_trait).generic,
                        });
                        return sema.ExprResult.initOwned(loc);
                    }
                }
            }
        },
        .borrow => {
            // Implicit Ref to Borrow.
            const borrow = target_t.cast(.borrow);
            if (expr.type.isRefPointer()) {
                if (borrow.child_t.id() == expr.type.cast(.pointer).child_t.id()) {
                    return try sema_expr.semaBitcast(c, expr, target_t, node);
                }
            }
            if (borrow.child_t.kind() == .func) {
                if (expr.type.kind() == .func_ptr) {
                    const ir_expr = try c.ir.newExpr(.func, borrow.child_t, node, .{
                        .expr = expr.ir,
                    });
                    const new = sema.ExprResult.initOwned(ir_expr);
                    return try sema_borrow.semaBorrow(c, new, node);
                }
                // A closure (`Func` or `OpaqueFunc`) or a borrow of one is borrowed as an `OpaqueFunc`.
                // Both are the same function union, so only the type changes.
                const target_func = borrow.child_t.cast(.func);
                if (target_func.opaque_) {
                    if (expr.type.kind() == .func and expr.type.cast(.func).sig == target_func.sig) {
                        const res = try sema_borrow.semaBorrow(c, expr, node);
                        return try sema_expr.semaBitcast(c, res, target_t, node);
                    }
                    if (expr.type.kind() == .borrow) {
                        const child_t = expr.type.cast(.borrow).child_t;
                        if (child_t.kind() == .func and child_t.cast(.func).sig == target_func.sig) {
                            return try sema_expr.semaBitcast(c, expr, target_t, node);
                        }
                    }
                }
            }
        },
        .borrow_trait => {
            if (expr.type.kind() == .borrow) {
                const child_t = expr.type.cast(.borrow).child_t;
                if (child_t.kind() == .struct_t) {
                    if (child_t.cast(.struct_t).implements(target_t.cast(.borrow_trait).generic)) {
                        try sema_type.checkDynReceivers(c, child_t, target_t.cast(.borrow_trait).generic, node);
                        const loc = try c.ir.newExpr(.trait, target_t, node, .{
                            .ref = expr.ir,
                            .impl_t = child_t,
                            .trait_t = target_t,
                            .generic_t = target_t.cast(.borrow_trait).generic,
                        });
                        return sema.ExprResult.init(loc, target_t);
                    }
                }
            }
        },
        .func_ptr => {
            if (expr.type.id() == c.sema.ptr_void_t.id()) {
                return try sema_expr.semaBitcast(c, expr, target_t, node);
            }
        },
        .func => {
            if (expr.type.kind() == .func_ptr and expr.type.cast(.func_ptr).sig == target_t.cast(.func).sig) {
                const loc = try c.ir.newExpr(.func, target_t, node, .{
                    .expr = expr.ir,
                });
                return sema.ExprResult.initOwned(loc);
            }
        },
        .pointer => {
            const target_ptr = target_t.cast(.pointer);

            // Ptr[T] -> Ptr[void]
            if (target_t.id() == c.sema.ptr_void_t.id()) {
                if (expr.type.isPointer()) {
                    return try sema_expr.semaBitcast(c, expr, target_t, node);
                }
                if (expr.type.kind() == .func_ptr) {
                    return try sema_expr.semaBitcast(c, expr, target_t, node);
                }
            }

            // Ptr[void] -> Ptr[T] (mimics unsafe C)
            if (expr.type.id() == c.sema.ptr_void_t.id() and target_t.isPointer()) {
                return try sema_expr.semaBitcast(c, expr, target_t, node);
            }

            if (expr.type.isPointer()) {
                const expr_ptr = expr.type.cast(.pointer);
                // Ptr[Int[Bits]] -> Ptr[Raw[Bits]] (mimics unsafe C)
                if (expr_ptr.child_t.kind() == .int and target_ptr.child_t.kind() == .raw) {
                    if (expr_ptr.child_t.cast(.int).bits == target_ptr.child_t.cast(.raw).bits) {
                        return try sema_expr.semaBitcast(c, expr, target_t, node);
                    }
                }
                // Ptr[Raw[Bits]] -> Ptr[Int[Bits]] (mimics unsafe C)
                if (expr_ptr.child_t.kind() == .raw and target_ptr.child_t.kind() == .int) {
                    if (expr_ptr.child_t.cast(.raw).bits == target_ptr.child_t.cast(.int).bits) {
                        return try sema_expr.semaBitcast(c, expr, target_t, node);
                    }
                }
            }

            // &T -> Ptr[T]
            if (!target_ptr.ref and expr.type.kind() == .borrow) {
                const borrow_t = expr.type.cast(.borrow);
                if (target_ptr.child_t.id() == borrow_t.child_t.id()) {
                    return try sema_expr.semaBitcast(c, expr, target_t, node);
                }

                // &Int[Bits] -> Ptr[Raw[Bits]]
                if (target_ptr.child_t.kind() == .raw and borrow_t.child_t.kind() == .int) {
                    if (borrow_t.child_t.cast(.int).bits == target_ptr.child_t.cast(.raw).bits) {
                        return try sema_expr.semaBitcast(c, expr, target_t, node);
                    }
                }

                // &Raw[Bits] -> Ptr[Int[Bits]]
                if (target_ptr.child_t.kind() == .int and borrow_t.child_t.kind() == .raw) {
                    if (borrow_t.child_t.cast(.raw).bits == target_ptr.child_t.cast(.int).bits) {
                        return try sema_expr.semaBitcast(c, expr, target_t, node);
                    }
                }
            }

            if (expr.type.kind() == .borrow) {
                // &T -> Ptr[void]
                if (target_t.id() == c.sema.ptr_void_t.id()) {
                    return try sema_expr.semaBitcast(c, expr, target_t, node);
                }

                const borrow_t = expr.type.cast(.borrow);

                // &[N]T -> Ptr[T]
                if (borrow_t.child_t.kind() == .vector) {
                    if (borrow_t.child_t.cast(.vector).elem_t.id() == target_ptr.child_t.id()) {
                        return try sema_expr.semaBitcast(c, expr, target_t, node);
                    }
                }

                // &[..N]T -> Ptr[T]
                if (borrow_t.child_t.kind() == .partial_vector) {
                    if (borrow_t.child_t.cast(.partial_vector).elem_t.id() == target_ptr.child_t.id()) {
                        const ptr = try sema_expr.semaBitcast(c, expr, target_t, node);
                        const offset = try semaConst(c, 8, c.sema.i64_t, node);
                        const add = try c.ir.newExpr(.add, target_t, node, .{
                            .left = ptr.ir,
                            .right = offset.ir,
                        });
                        return cy.sema.ExprResult.init2(add);
                    }
                }
            }
        },
        .float => {
            if (target_t.id() == bt.F64) {
                if (expr.type.id() == bt.F32) {
                    // f32 -> f64
                    const sym = try c.getResolvedSymOrFail(&c.sema.f64_t.sym().head, "@init", node);
                    const init_sym = try sema_call.requireFuncSym(c, sym, node);
                    return try c.semaCallFuncSym1(init_sym, node, expr, node);
                }
            }
            // Int[] -> Float[]
            if (expr.type.kind() == .int) {
                return try semaIntToFloat(c, target_t, expr, node);
            }

            // Raw[] -> Float[]. A distinct raw type (`symbol`, `error`) is a name, not a number.
            if (expr.type.kind() == .raw and !expr.type.cast(.raw).distinct) {
                return try semaIntToFloat(c, target_t, expr, node);
            }
        },
        .int => {
            if (expr.type.kind() == .int) {
                const int_t = expr.type.cast(.int);
                const target_int_t = target_t.cast(.int);
                if (int_t.bits < target_int_t.bits) {
                    // Widen.
                    return try semaSext(c, target_t, int_t.bits, expr, node);
                }
            }
            if (expr.type.kind() == .raw) {
                const raw_t = expr.type.cast(.raw);
                const target_int_t = target_t.cast(.int);
                if (raw_t.bits == target_int_t.bits) {
                    return try sema_expr.semaBitcast(c, expr, target_t, node);
                }
                if (raw_t.bits < target_int_t.bits) {
                    // Widen.
                    return try semaZext(c, target_t, raw_t.bits, expr, node);
                }
            }
        },
        .raw => {
            const target_raw_t = target_t.cast(.raw);
            if (target_raw_t.distinct) {
                return null;
            }
            if (expr.type.kind() == .raw) {
                const raw_t = expr.type.cast(.raw);
                if (raw_t.distinct) {
                    return null;
                }
                if (raw_t.bits < target_raw_t.bits) {
                    // Widen.
                    return try semaZext(c, target_t, raw_t.bits, expr, node);
                }
            }

            // Int[] -> Raw[]
            if (expr.type.kind() == .int) {
                const int_t = expr.type.cast(.int);

                if (int_t.bits == target_raw_t.bits) {
                    return try sema_expr.semaBitcast(c, expr, target_t, node);
                }
                if (int_t.bits < target_raw_t.bits) {
                    // Widen.
                    return try semaZext(c, target_t, int_t.bits, expr, node);
                }
            }
        },
        else => {},
    }
    return null;
}

pub fn semaCZero(c: *cy.Chunk, type_: *cy.Type, node: *ast.Node) !sema.ExprResult {
    switch (type_.id()) {
        bt.R8,
        bt.I8  => return c.semaConst8(0, type_, node),
        bt.Bool  => return c.semaFalse(node),
        bt.R16,
        bt.I16   => return c.semaConst16(0, type_, node),
        bt.R32,
        bt.F32,
        bt.I32   => return c.semaConst32(0, type_, node),
        bt.R64,
        bt.I64,
        bt.F64 => return c.semaConst(0, type_, node),
        else => {
            switch (type_.kind()) {
                .struct_t => {
                    const struct_t = type_.cast(.struct_t);
                    if (!struct_t.cstruct) {
                        const name = try c.sema.allocTypeName(type_);
                        defer c.alloc.free(name);
                        return c.reportErrorFmt("Unsupported zero initializer for `{}`. Can only zero initialize a `cstruct` type.", &.{v(name)}, node);
                    }
                    const ir_args = try c.ir.allocArray(*ir.Expr, struct_t.fields_len);
                    for (struct_t.fields(), 0..) |field, i| {
                        const arg = try semaCZero(c, field.type, node);
                        ir_args[i] = arg.ir;
                    }
                    const loc = try c.ir.newExpr(.init, @ptrCast(struct_t), node, .{
                        .nargs = @as(u32, @intCast(struct_t.fields_len)),
                        .args = ir_args.ptr,
                    });
                    return sema.ExprResult.initOwned(loc);
                },
                .c_union => {
                    const union_t = type_.cast(.c_union);
                    const expr = try c.ir.newExpr(.init_zero, type_, node, .{ .size = union_t.size });
                    return sema.ExprResult.initOwned(expr);
                },
                .vector => {
                    const array_t = type_.cast(.vector);
                    if (!array_t.elem_t.isCZeroEligible()) {
                        const name = try c.sema.allocTypeName(array_t.elem_t);
                        defer c.alloc.free(name);
                        return c.reportErrorFmt("Unsupported zero initializer for `{}`. Can only zero initialize a `cstruct` type.", &.{v(name)}, node);
                    }
                    const expr = try c.ir.newExpr(.init_zero, type_, node, .{ .size = array_t.size });
                    return sema.ExprResult.initOwned(expr);
                },
                .func_ptr => {
                    const func_ptr = type_.cast(.func_ptr);
                    if (func_ptr.sig.extern_) {
                        return c.semaConst(0, type_, node);
                    }
                },
                .pointer => {
                    const pointer = type_.cast(.pointer);
                    if (!pointer.ref) {
                        return c.semaConst(0, type_, node);
                    }
                },
                else => {},
            }
            const name = try c.sema.allocTypeName(type_);
            defer c.alloc.free(name);
            return c.reportErrorFmt("Unsupported zero initializer for `{}`.", &.{v(name)}, node);
        },
    }
}

pub fn reportExpectedType(c: *cy.Chunk, exp_t: *cy.Type, act_t: *cy.Type, node: *ast.Node) anyerror {
    if (act_t.id() == bt.Void) try sema_call.checkSliceInPlaceAssign(c, node);
    const exp_name = try c.sema.allocTypeName(exp_t);
    defer c.alloc.free(exp_name);
    const act_name = try c.sema.allocTypeName(act_t);
    defer c.alloc.free(act_name);
    const hint = try sema_hint.resultTypeHint(c, exp_t, act_t, node);
    return c.reportErrorFmt("Expected type `{}`, got `{}`.{}", &.{v(exp_name), v(act_name), v(hint)}, node);
}

pub fn semaInferSignedLit(c: *cy.Chunk, literal: []const u8, target_t: *cy.Type, base: u8, node: *ast.Node) !?sema.ExprResult {
    switch (target_t.id()) {
        bt.F32 => {
            const val = try std.fmt.parseFloat(f32, literal);
            return try c.semaConst32(@bitCast(val), target_t, node);
        },
        bt.F64 => {
            const val = try std.fmt.parseFloat(f64, literal);
            return try c.semaConst(@bitCast(val), target_t, node);
        },
        bt.R8 => {
            const val = try semaParseInt(c, u8, literal, base, node);
            return try c.semaConst8(val, target_t, node);
        },
        bt.I8 => {
            const val = try semaParseInt(c, i8, literal, base, node);
            return try c.semaConst8(@bitCast(val), target_t, node);
        },
        bt.R16 => {
            const val = try semaParseInt(c, u16, literal, base, node);
            return try c.semaConst16(val, target_t, node);
        },
        bt.I16 => {
            const val = try semaParseInt(c, i16, literal, base, node);
            return try c.semaConst16(@bitCast(val), target_t, node);
        },
        bt.R32 => {
            const val = try semaParseInt(c, u32, literal, base, node);
            return try c.semaConst32(val, target_t, node);
        },
        bt.I32 => {
            const val = try semaParseInt(c, i32, literal, base, node);
            return try c.semaConst32(@bitCast(val), target_t, node);
        },
        bt.R64 => {
            const val = try semaParseInt(c, u64, literal, base, node);
            return try c.semaConst(val, target_t, node);
        },
        bt.I64 => {
            const val = try semaParseInt(c, i64, literal, base, node);
            return try c.semaConst(@bitCast(val), target_t, node);
        },
        else => {
            if (target_t.kind() == .option) {
                return semaInferSignedLit(c, literal, target_t.cast(.option).child_t, base, node);
            } else if (target_t.kind() == .result) {
                return semaInferSignedLit(c, literal, target_t.cast(.result).child_t, base, node);
            }
        },
    }
    return null;
}

pub fn semaInferUnsignedLit(c: *cy.Chunk, literal: []const u8, target_t: *cy.Type, base: u8, node: *ast.Node) !?sema.ExprResult {
    switch (target_t.id()) {
        // The digits are in `base`. They are not a decimal float literal.
        bt.F32 => {
            const int = try semaParseInt(c, u64, literal, base, node);
            const val: f32 = @floatFromInt(int);
            return try c.semaConst32(@bitCast(val), target_t, node);
        },
        bt.F64 => {
            const int = try semaParseInt(c, u64, literal, base, node);
            const val: f64 = @floatFromInt(int);
            return try c.semaConst(@bitCast(val), target_t, node);
        },
        bt.R8,
        bt.I8 => {
            const val = try semaParseInt(c, u8, literal, base, node);
            return try c.semaConst8(val, target_t, node);
        },
        bt.R16,
        bt.I16 => {
            const val = try semaParseInt(c, u16, literal, base, node);
            return try c.semaConst16(val, target_t, node);
        },
        bt.R32,
        bt.I32 => {
            const val = try semaParseInt(c, u32, literal, base, node);
            return try c.semaConst32(val, target_t, node);
        },
        bt.R64 => {
            const val = try semaParseInt(c, u64, literal, base, node);
            return try c.semaConst(val, target_t, node);
        },
        else => {
            if (target_t.kind() == .option) {
                return semaInferUnsignedLit(c, literal, target_t.cast(.option).child_t, base, node);
            } else if (target_t.kind() == .result) {
                return semaInferUnsignedLit(c, literal, target_t.cast(.result).child_t, base, node);
            }
        },
    }
    return null;
}

pub fn semaParseFloat(c: *cy.Chunk, comptime T: type, literal: []const u8, node: *ast.Node) !T {
    return std.fmt.parseFloat(T, literal) catch |err| {
        switch (err) {
            // error.Overflow => {
            //     return c.reportError("Parsing decimal literal overflows integer type.", node);
            // },
            error.InvalidCharacter => {
                return c.reportError("Parsed invalid character.", node);
            },
        }
        return err;
    };
}

pub fn semaParseInt(c: *cy.Chunk, comptime T: type, literal: []const u8, base: u8, node: *ast.Node) !T {
    return std.fmt.parseInt(T, literal, base) catch |err| {
        switch (err) {
            error.Overflow => {
                return c.reportError("Integer literal does not fit the target type.", node);
            },
            error.InvalidCharacter => {
                return c.reportError("Parsed invalid character.", node);
            },
        }
        return err;
    };
}

pub fn semaSext(c: *cy.Chunk, target_t: *cy.Type, src_bits: u32, expr: sema.ExprResult, node: *ast.Node) !sema.ExprResult {
    const ext = try c.ir.newExpr(.sext, target_t, node, .{
        .expr = expr.ir,
        .src_bits = src_bits,
    });
    return sema.ExprResult.init2(ext);
}

pub fn semaZext(c: *cy.Chunk, target_t: *cy.Type, src_bits: u32, expr: sema.ExprResult, node: *ast.Node) !sema.ExprResult {
    const ext = try c.ir.newExpr(.zext, target_t, node, .{
        .expr = expr.ir,
        .src_bits = src_bits,
    });
    return sema.ExprResult.init2(ext);
}

pub fn semaIntToFloat(c: *cy.Chunk, target_t: *cy.Type, int: sema.ExprResult, node: *ast.Node) !sema.ExprResult {
    const expr = try c.ir.newExpr(.i2f, target_t, node, .{
        .expr = int.ir,
    });
    return sema.ExprResult.init2(expr);
}

/// `@name` that names no declaration. It used to be a symbol literal.
pub fn reportOldSymbolLit(c: *cy.Chunk, at_name: []const u8, node: *ast.Node) anyerror {
    return c.reportErrorFmt("Undeclared `{}`. A symbol literal is written `symbol.{}`.", &.{v(at_name), v(at_name[1..])}, node);
}
