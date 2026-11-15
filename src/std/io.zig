const std = @import("std");
const cy = @import("../cyber.zig");
const C = @import("../capi.zig");

const core = @import("../builtins/core.zig");
const zErrFunc = core.zErrFunc;

const Src = @embedFile("io.cy");

const funcs = [_]struct{[]const u8, C.BindFunc}{
    .{"indexOfNewLine",    zErrFunc(indexOfNewLine)},
};

pub fn bind(_: *C.VM, mod: *C.Sym) callconv(.c) C.Bytes {
    cy.core.markBuiltinModule(mod);
    for (funcs) |e| {
        C.mod_add_func(mod, e.@"0", e.@"1");
    }
    return C.to_bytes(Src);
}

fn indexOfNewLine(t: *cy.Thread) !C.Ret {
    const ret = t.ret(cy.value.Option(i64));
    const buf = t.param(cy.heap.Span);
    if (cy.string.indexOfNewLine(buf.items(u8))) |idx| {
        ret.* = cy.value.Option(i64).some(@intCast(idx));
    } else {
        ret.* = cy.value.Option(i64).none();
    }
    return C.RetOk;
}

comptime {
    @export(&bind, .{ .name = "cl_mod_bind_io", .linkage = .strong });
}