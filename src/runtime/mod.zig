// Runtime module

pub const memory = @import("memory.zig");
pub const stack = @import("stack.zig");
pub const interpreter = @import("interpreter.zig");
pub const table = @import("table.zig");
pub const store = @import("store.zig");

pub const Memory = memory.Memory;
pub const PAGE_SIZE = memory.PAGE_SIZE;
pub const Stack = stack.Stack;
pub const Value = stack.Value;
pub const Frame = stack.Frame;
pub const Label = stack.Label;
pub const Interpreter = interpreter.Interpreter;
pub const Table = table.Table;
pub const Global = table.Global;
pub const Store = store.Store;
pub const Instance = store.Instance;

test {
    _ = memory;
    _ = stack;
    _ = interpreter;
    _ = table;
    _ = store;
}
