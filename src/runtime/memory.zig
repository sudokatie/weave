// Linear memory implementation

const std = @import("std");

pub const PAGE_SIZE: usize = 65536; // 64KB
pub const MAX_PAGES: u32 = 65536; // 4GB max

pub const Memory = struct {
    data: []u8,
    min_pages: u32,
    max_pages: ?u32,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, min: u32, max: ?u32) !Memory {
        if (min > MAX_PAGES) return error.MemoryTooLarge;
        if (max) |m| {
            if (m > MAX_PAGES) return error.MemoryTooLarge;
            if (m < min) return error.InvalidMemoryLimits;
        }

        const byte_size = @as(usize, min) * PAGE_SIZE;
        const data = try allocator.alloc(u8, byte_size);
        @memset(data, 0);

        return Memory{
            .data = data,
            .min_pages = min,
            .max_pages = max,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Memory) void {
        self.allocator.free(self.data);
    }

    /// Current size in pages
    pub fn size(self: *Memory) u32 {
        return @intCast(self.data.len / PAGE_SIZE);
    }

    /// Grow memory by delta pages, returns previous size or -1 on failure
    pub fn grow(self: *Memory, delta: u32) i32 {
        const current = self.size();
        const new_size = current + delta;

        // Check max pages
        if (self.max_pages) |max| {
            if (new_size > max) return -1;
        }
        if (new_size > MAX_PAGES) return -1;

        // Resize
        const new_byte_size = @as(usize, new_size) * PAGE_SIZE;
        const new_data = self.allocator.realloc(self.data, new_byte_size) catch return -1;

        // Zero new pages
        @memset(new_data[self.data.len..], 0);

        self.data = new_data;
        return @intCast(current);
    }

    /// Load i32 from memory
    pub fn loadI32(self: *Memory, addr: u32) !i32 {
        if (addr + 4 > self.data.len) return error.OutOfBounds;
        return std.mem.readInt(i32, self.data[addr..][0..4], .little);
    }

    /// Load i64 from memory
    pub fn loadI64(self: *Memory, addr: u32) !i64 {
        if (addr + 8 > self.data.len) return error.OutOfBounds;
        return std.mem.readInt(i64, self.data[addr..][0..8], .little);
    }

    /// Load f32 from memory
    pub fn loadF32(self: *Memory, addr: u32) !f32 {
        if (addr + 4 > self.data.len) return error.OutOfBounds;
        return @bitCast(std.mem.readInt(u32, self.data[addr..][0..4], .little));
    }

    /// Load f64 from memory
    pub fn loadF64(self: *Memory, addr: u32) !f64 {
        if (addr + 8 > self.data.len) return error.OutOfBounds;
        return @bitCast(std.mem.readInt(u64, self.data[addr..][0..8], .little));
    }

    /// Load i32 from 8-bit signed
    pub fn loadI32_8s(self: *Memory, addr: u32) !i32 {
        if (addr >= self.data.len) return error.OutOfBounds;
        return @as(i32, @as(i8, @bitCast(self.data[addr])));
    }

    /// Load i32 from 8-bit unsigned
    pub fn loadI32_8u(self: *Memory, addr: u32) !i32 {
        if (addr >= self.data.len) return error.OutOfBounds;
        return @as(i32, self.data[addr]);
    }

    /// Load i32 from 16-bit signed
    pub fn loadI32_16s(self: *Memory, addr: u32) !i32 {
        if (addr + 2 > self.data.len) return error.OutOfBounds;
        return @as(i32, std.mem.readInt(i16, self.data[addr..][0..2], .little));
    }

    /// Load i32 from 16-bit unsigned
    pub fn loadI32_16u(self: *Memory, addr: u32) !i32 {
        if (addr + 2 > self.data.len) return error.OutOfBounds;
        return @as(i32, std.mem.readInt(u16, self.data[addr..][0..2], .little));
    }

    /// Store i32 to memory
    pub fn storeI32(self: *Memory, addr: u32, value: i32) !void {
        if (addr + 4 > self.data.len) return error.OutOfBounds;
        std.mem.writeInt(i32, self.data[addr..][0..4], value, .little);
    }

    /// Store i64 to memory
    pub fn storeI64(self: *Memory, addr: u32, value: i64) !void {
        if (addr + 8 > self.data.len) return error.OutOfBounds;
        std.mem.writeInt(i64, self.data[addr..][0..8], value, .little);
    }

    /// Store f32 to memory
    pub fn storeF32(self: *Memory, addr: u32, value: f32) !void {
        if (addr + 4 > self.data.len) return error.OutOfBounds;
        std.mem.writeInt(u32, self.data[addr..][0..4], @bitCast(value), .little);
    }

    /// Store f64 to memory
    pub fn storeF64(self: *Memory, addr: u32, value: f64) !void {
        if (addr + 8 > self.data.len) return error.OutOfBounds;
        std.mem.writeInt(u64, self.data[addr..][0..8], @bitCast(value), .little);
    }

    /// Store 8-bit value
    pub fn storeI32_8(self: *Memory, addr: u32, value: i32) !void {
        if (addr >= self.data.len) return error.OutOfBounds;
        self.data[addr] = @truncate(@as(u32, @bitCast(value)));
    }

    /// Store 16-bit value
    pub fn storeI32_16(self: *Memory, addr: u32, value: i32) !void {
        if (addr + 2 > self.data.len) return error.OutOfBounds;
        std.mem.writeInt(u16, self.data[addr..][0..2], @truncate(@as(u32, @bitCast(value))), .little);
    }

    /// Copy bytes into memory (for data segment initialization)
    pub fn fill(self: *Memory, offset: u32, data: []const u8) !void {
        if (offset + data.len > self.data.len) return error.OutOfBounds;
        @memcpy(self.data[offset .. offset + data.len], data);
    }

    /// Load u32 from memory
    pub fn loadU32(self: *Memory, addr: u32) !u32 {
        if (addr + 4 > self.data.len) return error.OutOfBounds;
        return std.mem.readInt(u32, self.data[addr..][0..4], .little);
    }

    /// Load u64 from memory
    pub fn loadU64(self: *Memory, addr: u32) !u64 {
        if (addr + 8 > self.data.len) return error.OutOfBounds;
        return std.mem.readInt(u64, self.data[addr..][0..8], .little);
    }

    /// Store u32 to memory
    pub fn storeU32(self: *Memory, addr: u32, value: u32) !void {
        if (addr + 4 > self.data.len) return error.OutOfBounds;
        std.mem.writeInt(u32, self.data[addr..][0..4], value, .little);
    }

    /// Store u64 to memory
    pub fn storeU64(self: *Memory, addr: u32, value: u64) !void {
        if (addr + 8 > self.data.len) return error.OutOfBounds;
        std.mem.writeInt(u64, self.data[addr..][0..8], value, .little);
    }

    /// Store single byte
    pub fn store(self: *Memory, addr: u32, value: u8) !void {
        if (addr >= self.data.len) return error.OutOfBounds;
        self.data[addr] = value;
    }

    /// Get slice of memory
    pub fn slice(self: *Memory, addr: u32, len: u32) ![]u8 {
        if (addr + len > self.data.len) return error.OutOfBounds;
        return self.data[addr .. addr + len];
    }

    /// Read bytes from memory (for interpreter)
    pub fn read(self: *Memory, addr: u32, len: usize) ?[]const u8 {
        if (addr + len > self.data.len) return null;
        return self.data[addr .. addr + len];
    }

    /// Write bytes to memory (for interpreter)
    pub fn write(self: *Memory, addr: u32, bytes: []const u8) ?void {
        if (addr + bytes.len > self.data.len) return null;
        @memcpy(self.data[addr .. addr + bytes.len], bytes);
    }

    /// Page count (alias for size)
    pub fn pageCount(self: *Memory) u32 {
        return self.size();
    }
};

// Tests
test "memory init" {
    const allocator = std.testing.allocator;
    var mem = try Memory.init(allocator, 1, null);
    defer mem.deinit();

    try std.testing.expectEqual(@as(u32, 1), mem.size());
    try std.testing.expectEqual(@as(usize, PAGE_SIZE), mem.data.len);
}

test "memory grow" {
    const allocator = std.testing.allocator;
    var mem = try Memory.init(allocator, 1, 3);
    defer mem.deinit();

    const old_size = mem.grow(1);
    try std.testing.expectEqual(@as(i32, 1), old_size);
    try std.testing.expectEqual(@as(u32, 2), mem.size());

    // Grow beyond max should fail
    const fail = mem.grow(2);
    try std.testing.expectEqual(@as(i32, -1), fail);
}

test "memory load store i32" {
    const allocator = std.testing.allocator;
    var mem = try Memory.init(allocator, 1, null);
    defer mem.deinit();

    try mem.storeI32(0, 42);
    try std.testing.expectEqual(@as(i32, 42), try mem.loadI32(0));

    try mem.storeI32(100, -12345);
    try std.testing.expectEqual(@as(i32, -12345), try mem.loadI32(100));
}

test "memory load store f64" {
    const allocator = std.testing.allocator;
    var mem = try Memory.init(allocator, 1, null);
    defer mem.deinit();

    try mem.storeF64(0, 3.14159);
    try std.testing.expectApproxEqAbs(@as(f64, 3.14159), try mem.loadF64(0), 0.00001);
}

test "memory bounds check" {
    const allocator = std.testing.allocator;
    var mem = try Memory.init(allocator, 1, null);
    defer mem.deinit();

    // Valid at end of page
    try mem.storeI32(PAGE_SIZE - 4, 1);

    // Out of bounds
    try std.testing.expectError(error.OutOfBounds, mem.storeI32(PAGE_SIZE - 3, 1));
    try std.testing.expectError(error.OutOfBounds, mem.loadI32(PAGE_SIZE));
}
