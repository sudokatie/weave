// Weave - WebAssembly Runtime Library
//
// A WASM interpreter implementation in Zig.

pub const binary = @import("binary/mod.zig");
pub const validate = @import("validate/mod.zig");
pub const runtime = @import("runtime/mod.zig");
pub const wasi = @import("wasi/mod.zig");

// Re-export common types
pub const Module = binary.Module;
pub const ValType = binary.ValType;
pub const Value = runtime.stack.Value;

test {
    @import("std").testing.refAllDecls(@This());
}
