// Runtime module - TODO

const binary = @import("../binary/mod.zig");

pub const Value = union(binary.ValType) {
    i32: i32,
    i64: i64,
    f32: f32,
    f64: f64,
    funcref: ?u32,
    externref: ?*anyopaque,
};

pub const Interpreter = struct {
    // Placeholder
};

test {
    @import("std").testing.refAllDecls(@This());
}
