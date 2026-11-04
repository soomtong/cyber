const std = @import("std");
const stdx = @import("stdx");
const fatal = cy.fatal;
const builtin = @import("builtin");

const cy = @import("../cyber.zig");
const vmc = cy.vmc;
const types = cy.types;
const rt = cy.rt;
const sema = cy.sema;
const ir = cy.ir;
const bt = cy.types.BuiltinTypes;
const Value = cy.Value;
const vm_ = @import("../vm.zig");
const TrackGlobalRC = vm_.TrackGlobalRC;
const fmt = @import("../fmt.zig");
const C = @import("../capi.zig");

const debug = builtin.mode == .debug;
const log = cy.log.scoped(.bindings);

const NullId = std.math.maxInt(u32);

pub const Symbol = enum {
    bool,
    char,
    uchar,
    short,
    ushort,
    int,
    uint,
    long,
    ulong,
    usize,
    double,
    charPtr,
    voidPtr,
    funcPtr,
    void,

    little,
    big,

    left,
    right,
    ends,

    // Encoding.
    utf8,
    bytes,

    AssertError,
    EvalError,
    FileNotFound,
    MissingSymbol,
    EndOfStream,
    OutOfBounds,
    InvalidResult,
    InvalidArgument,
    InvalidSignature,
    InvalidRune,
    StreamTooLong,
    NotAllowed,
    Closed,
    PermissionDenied,
    UnknownError,
    Unicode,
    Unsupported,
    ParseError,

    running,
    paused,
    done,

    float,

    // Open modes.
    read,
    write,
    readWrite,

    // File types.
    file,
    dir,

    unknown,
};

const anyNone = cy.builtins.anyNone;
const anySome = cy.builtins.anySome;

pub fn getBuiltinSymbol(id: u64) ?Symbol {
    return std.enums.fromInt(Symbol, id);
}

pub fn bindCore(self: *cy.VM) !void {
    @branchHint(.cold);
    for (std.enums.values(Symbol)) |sym| {
        try ensureSymbol(self, @tagName(sym), sym);
    }
}

fn ensureSymbol(vm: *cy.VM, name: []const u8, sym: Symbol) !void {
    const id = try vm.sema.ensureSymbol(name);
    std.debug.assert(id == @backingInt(sym));
}

// Keep as reference in case resume should be a function call.
// Although it works, it requires native func calls to perform additional copies of pc and framePtr back to the eval loop,
// which is a bad tradeoff for every other function call that doesn't need to.
// One solution is to add another bytecode to call nativeFunc1 with control over execution context.
// fn fiberResume(vm: *cy.UserVM, recv: Value, args: [*]const Value, _: u8) Value {
//     const obj = recv.asHeapObject();
//     if (&obj.fiber != @ptrCast(*cy.VM, vm).curFiber) {
//         // Only resume fiber if it's not done.
//         if (obj.fiber.pc != NullId) {
//             // Obtain the startLocal from looking at previous inst operand.
//             const startLocal = (@ptrCast(*cy.VM, vm).pc - 14 + 1)[0].arg;
//             // Obtain previous framePtr by subtracting from args pointer.
//             const prevFramePtr = @intToPtr([*]Value, @intFromPtr(args - startLocal - 4));

//             const pcOffset = @intCast(u32, @intFromPtr(@ptrCast(*cy.VM, vm).pc) - @intFromPtr(@ptrCast(*cy.VM, vm).ops.ptr));
//             const res = cy.pushFiber(@ptrCast(*cy.VM, vm), pcOffset, prevFramePtr, &obj.fiber, startLocal);
//             @ptrCast(*cy.VM, vm).pc = res.pc;
//             @ptrCast(*cy.VM, vm).framePtr = res.framePtr;
//             return Value.None;
//         }
//     }
//     vm.releaseObject(obj);
//     return Value.None;
// }

pub fn asr(c: *cy.Chunk, ctx: *cy.BuiltinContext, out: *cy.sema.ExprResult) !void {
    const x = try c.sema_expr_cstr_template(ctx.args[0], c.sema.int_tmpl);
    const amt = try c.semaExprCstr(ctx.args[1], x.type);
    const expr = try c.ir.newExpr(.asr, x.type, ctx.node, .{
        .left = x.ir,
        .right = amt.ir,
    });
    out.* = cy.sema.ExprResult.init2(expr);
}

pub fn fabs(c: *cy.Chunk, ctx: *cy.BuiltinContext, out: *cy.sema.ExprResult) !void {
    const x = try c.sema_expr_cstr_template(ctx.args[0], c.sema.float_tmpl);
    const expr = try c.ir.newExpr(.fabs, x.type, ctx.node, .{
        .expr = x.ir,
    });
    out.* = cy.sema.ExprResult.init2(expr);
}

pub fn float_pow(t: *cy.Thread) callconv(.c) C.Ret {
    const ret = t.ret(f64);
    ret.* = std.math.pow(f64, t.param(f64), t.param(f64));
    return C.RetOk;
}

pub fn float_pow32(t: *cy.Thread) callconv(.c) C.Ret {
    const ret = t.ret(f32);
    ret.* = std.math.pow(f32, t.param(f32), t.param(f32));
    return C.RetOk;
}

pub const QuickenType = enum(u8) {
    _,
};

pub const ModuleBuilder = struct {
    sym: *cy.Sym,
    chunk: *cy.Chunk,
    compiler: *cy.Compiler,
    vm: *cy.VM,

    pub fn init(c: *cy.Compiler, symOpt: ?*cy.Sym) ModuleBuilder {
        var new = ModuleBuilder{
            .sym = undefined,
            .compiler = c,
            .chunk = undefined,
            .vm = c.vm,
        };
        if (symOpt) |sym| {
            new.chunk = c.chunks.items[sym.declNode().src()];
            new.sym = sym;
        }
        return new;
    }

};
