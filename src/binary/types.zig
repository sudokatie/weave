// WASM type definitions

const std = @import("std");
const Reader = @import("reader.zig").Reader;

/// Value types
pub const ValType = enum(u8) {
    i32 = 0x7F,
    i64 = 0x7E,
    f32 = 0x7D,
    f64 = 0x7C,
    funcref = 0x70,
    externref = 0x6F,
    _,

    pub fn read(reader: *Reader) !ValType {
        const byte = try reader.readByte();
        return @enumFromInt(byte);
    }

    pub fn isNum(self: ValType) bool {
        return switch (self) {
            .i32, .i64, .f32, .f64 => true,
            else => false,
        };
    }

    pub fn isRef(self: ValType) bool {
        return switch (self) {
            .funcref, .externref => true,
            else => false,
        };
    }
};

/// Function type
pub const FuncType = struct {
    params: []const ValType,
    results: []const ValType,
    allocator: std.mem.Allocator,

    pub fn read(reader: *Reader, allocator: std.mem.Allocator) !FuncType {
        const tag = try reader.readByte();
        if (tag != 0x60) return error.InvalidFuncType;

        const param_count = try reader.readU32Leb128();
        var params = try allocator.alloc(ValType, param_count);
        errdefer allocator.free(params);

        for (0..param_count) |i| {
            params[i] = try ValType.read(reader);
        }

        const result_count = try reader.readU32Leb128();
        var results = try allocator.alloc(ValType, result_count);
        errdefer allocator.free(results);

        for (0..result_count) |i| {
            results[i] = try ValType.read(reader);
        }

        return FuncType{
            .params = params,
            .results = results,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *FuncType) void {
        self.allocator.free(self.params);
        self.allocator.free(self.results);
    }
};

/// Limits (min, optional max)
pub const Limits = struct {
    min: u32,
    max: ?u32,

    pub fn read(reader: *Reader) !Limits {
        const has_max = try reader.readByte();
        const min = try reader.readU32Leb128();
        const max: ?u32 = if (has_max == 1) try reader.readU32Leb128() else null;
        return Limits{ .min = min, .max = max };
    }
};

/// Memory type
pub const MemType = Limits;

/// Table type
pub const TableType = struct {
    elem_type: ValType,
    limits: Limits,

    pub fn read(reader: *Reader) !TableType {
        const elem_type = try ValType.read(reader);
        const limits = try Limits.read(reader);
        return TableType{ .elem_type = elem_type, .limits = limits };
    }
};

/// Global type
pub const GlobalType = struct {
    val_type: ValType,
    mutable: bool,

    pub fn read(reader: *Reader) !GlobalType {
        const val_type = try ValType.read(reader);
        const mutable = try reader.readByte() == 1;
        return GlobalType{ .val_type = val_type, .mutable = mutable };
    }
};

/// Block type (for control instructions)
pub const BlockType = union(enum) {
    empty,
    val_type: ValType,
    type_index: u32,

    pub fn read(reader: *Reader) !BlockType {
        const byte = try reader.peekByte();

        if (byte == 0x40) {
            _ = try reader.readByte();
            return BlockType{ .empty = {} };
        }

        // Check if it's a valtype
        if (byte >= 0x7C and byte <= 0x7F) {
            _ = try reader.readByte();
            return BlockType{ .val_type = @enumFromInt(byte) };
        }

        // Otherwise it's a type index (signed LEB128)
        const idx = try reader.readI32Leb128();
        if (idx < 0) return error.InvalidBlockType;
        return BlockType{ .type_index = @intCast(idx) };
    }
};

// Tests
test "read valtype" {
    var r = Reader.init(&[_]u8{0x7F});
    try std.testing.expectEqual(ValType.i32, try ValType.read(&r));
}

test "read functype" {
    const allocator = std.testing.allocator;
    // (i32, i32) -> (i32)
    var r = Reader.init(&[_]u8{ 0x60, 0x02, 0x7F, 0x7F, 0x01, 0x7F });
    var ft = try FuncType.read(&r, allocator);
    defer ft.deinit();

    try std.testing.expectEqual(@as(usize, 2), ft.params.len);
    try std.testing.expectEqual(@as(usize, 1), ft.results.len);
    try std.testing.expectEqual(ValType.i32, ft.params[0]);
    try std.testing.expectEqual(ValType.i32, ft.results[0]);
}

test "read limits" {
    // min only
    var r1 = Reader.init(&[_]u8{ 0x00, 0x01 });
    const l1 = try Limits.read(&r1);
    try std.testing.expectEqual(@as(u32, 1), l1.min);
    try std.testing.expect(l1.max == null);

    // min and max
    var r2 = Reader.init(&[_]u8{ 0x01, 0x01, 0x10 });
    const l2 = try Limits.read(&r2);
    try std.testing.expectEqual(@as(u32, 1), l2.min);
    try std.testing.expectEqual(@as(u32, 16), l2.max.?);
}
