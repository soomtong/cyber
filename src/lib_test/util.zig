// Shared by the lib tests.
const builtin = @import("builtin");

/// The tests that cannot run on wasm return early on this.
pub const is_wasm = builtin.target.cpu.arch.isWasm();
