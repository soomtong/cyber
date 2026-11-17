const cy = @import("../cyber.zig");
const C = @import("../capi.zig");

const Src = @embedFile("path.cy");

pub fn bind(_: *C.VM, mod: *C.Sym) callconv(.c) C.Bytes {
    cy.core.markBuiltinModule(mod);
    return C.to_bytes(Src);
}

comptime {
    @export(&bind, .{ .name = "cl_mod_bind_path", .linkage = .strong });
}
