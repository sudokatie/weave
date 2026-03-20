// Binary reader with LEB128 decoding

const std = @import("std");

pub const Reader = struct {
    data: []const u8,
    pos: usize,

    pub fn init(data: []const u8) Reader {
        return .{ .data = data, .pos = 0 };
    }

    pub fn readByte(self: *Reader) !u8 {
        if (self.pos >= self.data.len) return error.UnexpectedEof;
        const b = self.data[self.pos];
        self.pos += 1;
        return b;
    }

    pub fn readBytes(self: *Reader, n: usize) ![]const u8 {
        if (self.pos + n > self.data.len) return error.UnexpectedEof;
        const result = self.data[self.pos .. self.pos + n];
        self.pos += n;
        return result;
    }

    pub fn peekByte(self: *Reader) !u8 {
        if (self.pos >= self.data.len) return error.UnexpectedEof;
        return self.data[self.pos];
    }

    /// Read unsigned LEB128 encoded u32
    pub fn readU32Leb128(self: *Reader) !u32 {
        var result: u32 = 0;
        var shift: u5 = 0;

        while (true) {
            const byte = try self.readByte();
            result |= @as(u32, byte & 0x7F) << shift;

            if (byte & 0x80 == 0) break;

            shift += 7;
            if (shift >= 35) return error.LEB128Overflow;
        }

        return result;
    }

    /// Read signed LEB128 encoded i32
    pub fn readI32Leb128(self: *Reader) !i32 {
        var result: i32 = 0;
        var shift: u5 = 0;
        var byte: u8 = 0;

        while (true) {
            byte = try self.readByte();
            result |= @as(i32, @intCast(byte & 0x7F)) << shift;
            shift += 7;

            if (byte & 0x80 == 0) break;
            if (shift >= 35) return error.LEB128Overflow;
        }

        // Sign extend
        if (shift < 32 and (byte & 0x40) != 0) {
            result |= @as(i32, -1) << shift;
        }

        return result;
    }

    /// Read unsigned LEB128 encoded u64
    pub fn readU64Leb128(self: *Reader) !u64 {
        var result: u64 = 0;
        var shift: u6 = 0;

        while (true) {
            const byte = try self.readByte();
            result |= @as(u64, byte & 0x7F) << shift;

            if (byte & 0x80 == 0) break;

            shift += 7;
            if (shift >= 70) return error.LEB128Overflow;
        }

        return result;
    }

    /// Read signed LEB128 encoded i64
    pub fn readI64Leb128(self: *Reader) !i64 {
        var result: i64 = 0;
        var shift: u6 = 0;
        var byte: u8 = 0;

        while (true) {
            byte = try self.readByte();
            result |= @as(i64, @intCast(byte & 0x7F)) << shift;
            shift += 7;

            if (byte & 0x80 == 0) break;
            if (shift >= 70) return error.LEB128Overflow;
        }

        // Sign extend
        if (shift < 64 and (byte & 0x40) != 0) {
            result |= @as(i64, -1) << shift;
        }

        return result;
    }

    /// Read IEEE 754 f32
    pub fn readF32(self: *Reader) !f32 {
        const bytes = try self.readBytes(4);
        return @bitCast(std.mem.readInt(u32, bytes[0..4], .little));
    }

    /// Read IEEE 754 f64
    pub fn readF64(self: *Reader) !f64 {
        const bytes = try self.readBytes(8);
        return @bitCast(std.mem.readInt(u64, bytes[0..8], .little));
    }

    /// Read a name (length-prefixed UTF-8 string)
    pub fn readName(self: *Reader) ![]const u8 {
        const len = try self.readU32Leb128();
        return try self.readBytes(len);
    }

    /// Read a vector (count + elements)
    pub fn readVec(self: *Reader, comptime T: type, allocator: std.mem.Allocator, readFn: fn (*Reader, std.mem.Allocator) anyerror!T) ![]T {
        const count = try self.readU32Leb128();
        var result = try allocator.alloc(T, count);
        errdefer allocator.free(result);

        for (0..count) |i| {
            result[i] = try readFn(self, allocator);
        }

        return result;
    }

    pub fn atEnd(self: *Reader) bool {
        return self.pos >= self.data.len;
    }

    pub fn remaining(self: *Reader) usize {
        return self.data.len - self.pos;
    }

    pub fn skip(self: *Reader, n: usize) !void {
        if (self.pos + n > self.data.len) return error.UnexpectedEof;
        self.pos += n;
    }
};

// Tests
test "read byte" {
    var r = Reader.init(&[_]u8{ 0x41, 0x42, 0x43 });
    try std.testing.expectEqual(@as(u8, 0x41), try r.readByte());
    try std.testing.expectEqual(@as(u8, 0x42), try r.readByte());
    try std.testing.expectEqual(@as(u8, 0x43), try r.readByte());
    try std.testing.expectError(error.UnexpectedEof, r.readByte());
}

test "read u32 leb128" {
    // 0 -> 0x00
    var r1 = Reader.init(&[_]u8{0x00});
    try std.testing.expectEqual(@as(u32, 0), try r1.readU32Leb128());

    // 127 -> 0x7F
    var r2 = Reader.init(&[_]u8{0x7F});
    try std.testing.expectEqual(@as(u32, 127), try r2.readU32Leb128());

    // 128 -> 0x80 0x01
    var r3 = Reader.init(&[_]u8{ 0x80, 0x01 });
    try std.testing.expectEqual(@as(u32, 128), try r3.readU32Leb128());

    // 624485 -> 0xE5 0x8E 0x26
    var r4 = Reader.init(&[_]u8{ 0xE5, 0x8E, 0x26 });
    try std.testing.expectEqual(@as(u32, 624485), try r4.readU32Leb128());
}

test "read i32 leb128" {
    // 0 -> 0x00
    var r1 = Reader.init(&[_]u8{0x00});
    try std.testing.expectEqual(@as(i32, 0), try r1.readI32Leb128());

    // -1 -> 0x7F
    var r2 = Reader.init(&[_]u8{0x7F});
    try std.testing.expectEqual(@as(i32, -1), try r2.readI32Leb128());

    // -128 -> 0x80 0x7F
    var r3 = Reader.init(&[_]u8{ 0x80, 0x7F });
    try std.testing.expectEqual(@as(i32, -128), try r3.readI32Leb128());
}

test "read f32" {
    // 1.0f -> 0x00 0x00 0x80 0x3F (little endian)
    var r = Reader.init(&[_]u8{ 0x00, 0x00, 0x80, 0x3F });
    try std.testing.expectEqual(@as(f32, 1.0), try r.readF32());
}

test "read name" {
    var r = Reader.init(&[_]u8{ 0x05, 'h', 'e', 'l', 'l', 'o' });
    try std.testing.expectEqualStrings("hello", try r.readName());
}
