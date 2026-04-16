// Weave - WebAssembly Runtime Library
//
// A WASM interpreter implementation in Zig.

pub const binary = @import("binary/mod.zig");
pub const validate = @import("validate/mod.zig");
pub const runtime = @import("runtime/mod.zig");
pub const wasi = @import("wasi/mod.zig");
pub const jit = @import("jit/mod.zig");
pub const jit_compiler = @import("jit.zig");

// Re-export common types
pub const Module = binary.Module;
pub const ValType = binary.ValType;
pub const Value = runtime.stack.Value;
pub const HotPathDetector = jit.HotPathDetector;
pub const JitCompiler = jit_compiler.JitCompiler;

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("test_integration.zig");
}
