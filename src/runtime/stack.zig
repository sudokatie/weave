// Value stack and call frames

const std = @import("std");
const binary = @import("../binary/mod.zig");

/// Runtime value
pub const Value = union(enum) {
    i32: i32,
    i64: i64,
    f32: f32,
    f64: f64,
    funcref: ?u32,
    externref: ?*anyopaque,

    pub fn fromValType(val_type: binary.ValType) Value {
        return switch (val_type) {
            .i32 => Value{ .i32 = 0 },
            .i64 => Value{ .i64 = 0 },
            .f32 => Value{ .f32 = 0 },
            .f64 => Value{ .f64 = 0 },
            .funcref => Value{ .funcref = null },
            .externref => Value{ .externref = null },
            _ => Value{ .i32 = 0 },
        };
    }

    pub fn asI32(self: Value) !i32 {
        return switch (self) {
            .i32 => |v| v,
            else => error.TypeMismatch,
        };
    }

    pub fn asI64(self: Value) !i64 {
        return switch (self) {
            .i64 => |v| v,
            else => error.TypeMismatch,
        };
    }

    pub fn asF32(self: Value) !f32 {
        return switch (self) {
            .f32 => |v| v,
            else => error.TypeMismatch,
        };
    }

    pub fn asF64(self: Value) !f64 {
        return switch (self) {
            .f64 => |v| v,
            else => error.TypeMismatch,
        };
    }
};

/// Label for block/loop/if
pub const Label = struct {
    arity: u32, // Number of results
    target: usize, // Branch target (instruction index)
    is_loop: bool, // Loop vs block semantics
    stack_height: usize, // Stack height at label entry
};

/// Call frame
pub const Frame = struct {
    func_idx: u32,
    locals: []Value,
    return_arity: u32,
    ip: usize, // Instruction pointer
    module_idx: u32, // For multi-module support
    stack_height: usize, // Stack height at call

    pub fn deinit(self: *Frame, allocator: std.mem.Allocator) void {
        if (self.locals.len > 0) {
            allocator.free(self.locals);
        }
    }
};

/// Operand and control stack
pub const Stack = struct {
    values: std.ArrayList(Value),
    labels: std.ArrayList(Label),
    frames: std.ArrayList(Frame),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Stack {
        return Stack{
            .values = std.ArrayList(Value).empty,
            .labels = std.ArrayList(Label).empty,
            .frames = std.ArrayList(Frame).empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Stack) void {
        for (self.frames.items) |*f| {
            f.deinit(self.allocator);
        }
        self.values.deinit(self.allocator);
        self.labels.deinit(self.allocator);
        self.frames.deinit(self.allocator);
    }

    // Value stack operations

    pub fn push(self: *Stack, value: Value) !void {
        try self.values.append(self.allocator, value);
    }

    pub fn pop(self: *Stack) !Value {
        if (self.values.items.len == 0) return error.StackUnderflow;
        return self.values.pop() orelse error.StackUnderflow;
    }

    pub fn peek(self: *Stack) !Value {
        if (self.values.items.len == 0) return error.StackUnderflow;
        return self.values.items[self.values.items.len - 1];
    }

    pub fn pushI32(self: *Stack, v: i32) !void {
        try self.push(Value{ .i32 = v });
    }

    pub fn pushI64(self: *Stack, v: i64) !void {
        try self.push(Value{ .i64 = v });
    }

    pub fn pushF32(self: *Stack, v: f32) !void {
        try self.push(Value{ .f32 = v });
    }

    pub fn pushF64(self: *Stack, v: f64) !void {
        try self.push(Value{ .f64 = v });
    }

    pub fn popI32(self: *Stack) !i32 {
        return (try self.pop()).asI32();
    }

    pub fn popI64(self: *Stack) !i64 {
        return (try self.pop()).asI64();
    }

    pub fn popF32(self: *Stack) !f32 {
        return (try self.pop()).asF32();
    }

    pub fn popF64(self: *Stack) !f64 {
        return (try self.pop()).asF64();
    }

    // Label operations

    pub fn pushLabel(self: *Stack, label: Label) !void {
        try self.labels.append(self.allocator, label);
    }

    pub fn popLabel(self: *Stack) !Label {
        if (self.labels.items.len == 0) return error.LabelStackUnderflow;
        return self.labels.pop() orelse error.LabelStackUnderflow;
    }

    pub fn getLabel(self: *Stack, depth: u32) !*Label {
        if (depth >= self.labels.items.len) return error.InvalidLabelDepth;
        return &self.labels.items[self.labels.items.len - 1 - depth];
    }

    // Frame operations

    pub fn pushFrame(self: *Stack, frame: Frame) !void {
        try self.frames.append(self.allocator, frame);
    }

    pub fn popFrame(self: *Stack) !Frame {
        if (self.frames.items.len == 0) return error.FrameStackUnderflow;
        return self.frames.pop() orelse error.FrameStackUnderflow;
    }

    pub fn currentFrame(self: *Stack) !*Frame {
        if (self.frames.items.len == 0) return error.NoActiveFrame;
        return &self.frames.items[self.frames.items.len - 1];
    }

    // Utility

    pub fn valueStackHeight(self: *Stack) usize {
        return self.values.items.len;
    }

    pub fn truncateValues(self: *Stack, height: usize) void {
        if (height < self.values.items.len) {
            self.values.shrinkRetainingCapacity(height);
        }
    }
};

// Tests
test "stack push pop" {
    const allocator = std.testing.allocator;
    var stack = Stack.init(allocator);
    defer stack.deinit();

    try stack.pushI32(42);
    try stack.pushI64(100);

    try std.testing.expectEqual(@as(i64, 100), try stack.popI64());
    try std.testing.expectEqual(@as(i32, 42), try stack.popI32());
}

test "stack underflow" {
    const allocator = std.testing.allocator;
    var stack = Stack.init(allocator);
    defer stack.deinit();

    try std.testing.expectError(error.StackUnderflow, stack.pop());
}

test "stack labels" {
    const allocator = std.testing.allocator;
    var stack = Stack.init(allocator);
    defer stack.deinit();

    try stack.pushLabel(.{ .arity = 0, .target = 10, .is_loop = false, .stack_height = 0 });
    try stack.pushLabel(.{ .arity = 1, .target = 20, .is_loop = true, .stack_height = 5 });

    const inner = try stack.getLabel(0);
    try std.testing.expectEqual(@as(usize, 20), inner.target);

    const outer = try stack.getLabel(1);
    try std.testing.expectEqual(@as(usize, 10), outer.target);
}

test "value type conversion" {
    try std.testing.expectEqual(@as(i32, 42), try (Value{ .i32 = 42 }).asI32());
    try std.testing.expectError(error.TypeMismatch, (Value{ .i64 = 42 }).asI32());
}
