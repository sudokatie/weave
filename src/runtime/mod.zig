// Runtime module

const binary = @import("../binary/mod.zig");
pub const memory = @import("memory.zig");

pub const Memory = memory.Memory;
pub const PAGE_SIZE = memory.PAGE_SIZE;

pub const Value = union(binary.ValType) {
    i32: i32,
    i64: i64,
    f32: f32,
    f64: f64,
    funcref: ?u32,
    externref: ?*anyopaque,
};

pub const Interpreter = struct {
    // Placeholder - TODO in Task 11
};

test {
    _ = memory;
}
