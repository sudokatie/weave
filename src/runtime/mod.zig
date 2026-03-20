// Runtime module

pub const memory = @import("memory.zig");
pub const stack = @import("stack.zig");

pub const Memory = memory.Memory;
pub const PAGE_SIZE = memory.PAGE_SIZE;
pub const Stack = stack.Stack;
pub const Value = stack.Value;
pub const Frame = stack.Frame;
pub const Label = stack.Label;

pub const Interpreter = struct {
    // Placeholder - TODO in Task 11
};

test {
    _ = memory;
    _ = stack;
}
