// Table and global instances

const std = @import("std");
const binary = @import("../binary/mod.zig");
const stack_mod = @import("stack.zig");

const Value = stack_mod.Value;

/// Table instance (funcref or externref)
pub const Table = struct {
    elements: []?u32, // Function indices (funcref) or null
    elem_type: binary.ValType,
    min: u32,
    max: ?u32,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, table_type: binary.TableType) !Table {
        const elements = try allocator.alloc(?u32, table_type.limits.min);
        @memset(elements, null);

        return Table{
            .elements = elements,
            .elem_type = table_type.elem_type,
            .min = table_type.limits.min,
            .max = table_type.limits.max,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Table) void {
        self.allocator.free(self.elements);
    }

    pub fn size(self: *Table) u32 {
        return @intCast(self.elements.len);
    }

    pub fn get(self: *Table, idx: u32) !?u32 {
        if (idx >= self.elements.len) return error.TableOutOfBounds;
        return self.elements[idx];
    }

    pub fn set(self: *Table, idx: u32, value: ?u32) !void {
        if (idx >= self.elements.len) return error.TableOutOfBounds;
        self.elements[idx] = value;
    }

    pub fn grow(self: *Table, delta: u32, init_val: ?u32) i32 {
        const current = self.size();
        const new_size = current + delta;

        if (self.max) |max| {
            if (new_size > max) return -1;
        }

        const new_elements = self.allocator.realloc(self.elements, new_size) catch return -1;
        for (current..new_size) |i| {
            new_elements[i] = init_val;
        }
        self.elements = new_elements;

        return @intCast(current);
    }
};

/// Global instance
pub const Global = struct {
    value: Value,
    mutable: bool,

    pub fn init(global_type: binary.GlobalType, initial: Value) Global {
        return Global{
            .value = initial,
            .mutable = global_type.mutable,
        };
    }

    pub fn get(self: *Global) Value {
        return self.value;
    }

    pub fn set(self: *Global, value: Value) !void {
        if (!self.mutable) return error.ImmutableGlobal;
        self.value = value;
    }
};

// Tests
test "table init" {
    const allocator = std.testing.allocator;
    var table = try Table.init(allocator, .{
        .elem_type = .funcref,
        .limits = .{ .min = 10, .max = 100 },
    });
    defer table.deinit();

    try std.testing.expectEqual(@as(u32, 10), table.size());
    try std.testing.expectEqual(@as(?u32, null), try table.get(0));
}

test "table set get" {
    const allocator = std.testing.allocator;
    var table = try Table.init(allocator, .{
        .elem_type = .funcref,
        .limits = .{ .min = 10, .max = null },
    });
    defer table.deinit();

    try table.set(5, 42);
    try std.testing.expectEqual(@as(?u32, 42), try table.get(5));
    try std.testing.expectEqual(@as(?u32, null), try table.get(0));
}

test "table bounds" {
    const allocator = std.testing.allocator;
    var table = try Table.init(allocator, .{
        .elem_type = .funcref,
        .limits = .{ .min = 5, .max = null },
    });
    defer table.deinit();

    try std.testing.expectError(error.TableOutOfBounds, table.get(10));
    try std.testing.expectError(error.TableOutOfBounds, table.set(10, 1));
}

test "global mutable" {
    var global = Global.init(.{
        .val_type = .i32,
        .mutable = true,
    }, Value{ .i32 = 0 });

    try std.testing.expectEqual(@as(i32, 0), global.get().i32);

    try global.set(Value{ .i32 = 42 });
    try std.testing.expectEqual(@as(i32, 42), global.get().i32);
}

test "global immutable" {
    var global = Global.init(.{
        .val_type = .i32,
        .mutable = false,
    }, Value{ .i32 = 100 });

    try std.testing.expectEqual(@as(i32, 100), global.get().i32);
    try std.testing.expectError(error.ImmutableGlobal, global.set(Value{ .i32 = 42 }));
}
