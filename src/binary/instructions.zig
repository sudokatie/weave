// WASM instruction decoding

const std = @import("std");
const Reader = @import("reader.zig").Reader;
const types = @import("types.zig");

/// WASM opcodes (1.0 spec)
pub const Opcode = enum(u8) {
    // Control
    @"unreachable" = 0x00,
    nop = 0x01,
    block = 0x02,
    loop = 0x03,
    @"if" = 0x04,
    @"else" = 0x05,
    end = 0x0B,
    br = 0x0C,
    br_if = 0x0D,
    br_table = 0x0E,
    @"return" = 0x0F,
    call = 0x10,
    call_indirect = 0x11,

    // Parametric
    drop = 0x1A,
    select = 0x1B,

    // Variable
    local_get = 0x20,
    local_set = 0x21,
    local_tee = 0x22,
    global_get = 0x23,
    global_set = 0x24,

    // Memory
    i32_load = 0x28,
    i64_load = 0x29,
    f32_load = 0x2A,
    f64_load = 0x2B,
    i32_load8_s = 0x2C,
    i32_load8_u = 0x2D,
    i32_load16_s = 0x2E,
    i32_load16_u = 0x2F,
    i64_load8_s = 0x30,
    i64_load8_u = 0x31,
    i64_load16_s = 0x32,
    i64_load16_u = 0x33,
    i64_load32_s = 0x34,
    i64_load32_u = 0x35,
    i32_store = 0x36,
    i64_store = 0x37,
    f32_store = 0x38,
    f64_store = 0x39,
    i32_store8 = 0x3A,
    i32_store16 = 0x3B,
    i64_store8 = 0x3C,
    i64_store16 = 0x3D,
    i64_store32 = 0x3E,
    memory_size = 0x3F,
    memory_grow = 0x40,

    // Numeric - constants
    i32_const = 0x41,
    i64_const = 0x42,
    f32_const = 0x43,
    f64_const = 0x44,

    // Numeric - i32 comparison
    i32_eqz = 0x45,
    i32_eq = 0x46,
    i32_ne = 0x47,
    i32_lt_s = 0x48,
    i32_lt_u = 0x49,
    i32_gt_s = 0x4A,
    i32_gt_u = 0x4B,
    i32_le_s = 0x4C,
    i32_le_u = 0x4D,
    i32_ge_s = 0x4E,
    i32_ge_u = 0x4F,

    // Numeric - i64 comparison
    i64_eqz = 0x50,
    i64_eq = 0x51,
    i64_ne = 0x52,
    i64_lt_s = 0x53,
    i64_lt_u = 0x54,
    i64_gt_s = 0x55,
    i64_gt_u = 0x56,
    i64_le_s = 0x57,
    i64_le_u = 0x58,
    i64_ge_s = 0x59,
    i64_ge_u = 0x5A,

    // Numeric - f32 comparison
    f32_eq = 0x5B,
    f32_ne = 0x5C,
    f32_lt = 0x5D,
    f32_gt = 0x5E,
    f32_le = 0x5F,
    f32_ge = 0x60,

    // Numeric - f64 comparison
    f64_eq = 0x61,
    f64_ne = 0x62,
    f64_lt = 0x63,
    f64_gt = 0x64,
    f64_le = 0x65,
    f64_ge = 0x66,

    // Numeric - i32 operations
    i32_clz = 0x67,
    i32_ctz = 0x68,
    i32_popcnt = 0x69,
    i32_add = 0x6A,
    i32_sub = 0x6B,
    i32_mul = 0x6C,
    i32_div_s = 0x6D,
    i32_div_u = 0x6E,
    i32_rem_s = 0x6F,
    i32_rem_u = 0x70,
    i32_and = 0x71,
    i32_or = 0x72,
    i32_xor = 0x73,
    i32_shl = 0x74,
    i32_shr_s = 0x75,
    i32_shr_u = 0x76,
    i32_rotl = 0x77,
    i32_rotr = 0x78,

    // Numeric - i64 operations
    i64_clz = 0x79,
    i64_ctz = 0x7A,
    i64_popcnt = 0x7B,
    i64_add = 0x7C,
    i64_sub = 0x7D,
    i64_mul = 0x7E,
    i64_div_s = 0x7F,
    i64_div_u = 0x80,
    i64_rem_s = 0x81,
    i64_rem_u = 0x82,
    i64_and = 0x83,
    i64_or = 0x84,
    i64_xor = 0x85,
    i64_shl = 0x86,
    i64_shr_s = 0x87,
    i64_shr_u = 0x88,
    i64_rotl = 0x89,
    i64_rotr = 0x8A,

    // Numeric - f32 operations
    f32_abs = 0x8B,
    f32_neg = 0x8C,
    f32_ceil = 0x8D,
    f32_floor = 0x8E,
    f32_trunc = 0x8F,
    f32_nearest = 0x90,
    f32_sqrt = 0x91,
    f32_add = 0x92,
    f32_sub = 0x93,
    f32_mul = 0x94,
    f32_div = 0x95,
    f32_min = 0x96,
    f32_max = 0x97,
    f32_copysign = 0x98,

    // Numeric - f64 operations
    f64_abs = 0x99,
    f64_neg = 0x9A,
    f64_ceil = 0x9B,
    f64_floor = 0x9C,
    f64_trunc = 0x9D,
    f64_nearest = 0x9E,
    f64_sqrt = 0x9F,
    f64_add = 0xA0,
    f64_sub = 0xA1,
    f64_mul = 0xA2,
    f64_div = 0xA3,
    f64_min = 0xA4,
    f64_max = 0xA5,
    f64_copysign = 0xA6,

    // Conversions
    i32_wrap_i64 = 0xA7,
    i32_trunc_f32_s = 0xA8,
    i32_trunc_f32_u = 0xA9,
    i32_trunc_f64_s = 0xAA,
    i32_trunc_f64_u = 0xAB,
    i64_extend_i32_s = 0xAC,
    i64_extend_i32_u = 0xAD,
    i64_trunc_f32_s = 0xAE,
    i64_trunc_f32_u = 0xAF,
    i64_trunc_f64_s = 0xB0,
    i64_trunc_f64_u = 0xB1,
    f32_convert_i32_s = 0xB2,
    f32_convert_i32_u = 0xB3,
    f32_convert_i64_s = 0xB4,
    f32_convert_i64_u = 0xB5,
    f32_demote_f64 = 0xB6,
    f64_convert_i32_s = 0xB7,
    f64_convert_i32_u = 0xB8,
    f64_convert_i64_s = 0xB9,
    f64_convert_i64_u = 0xBA,
    f64_promote_f32 = 0xBB,
    i32_reinterpret_f32 = 0xBC,
    i64_reinterpret_f64 = 0xBD,
    f32_reinterpret_i32 = 0xBE,
    f64_reinterpret_i64 = 0xBF,

    // Sign extension (WASM 1.0+)
    i32_extend8_s = 0xC0,
    i32_extend16_s = 0xC1,
    i64_extend8_s = 0xC2,
    i64_extend16_s = 0xC3,
    i64_extend32_s = 0xC4,

    _,
};

/// Instruction immediate operands
pub const Immediate = union(enum) {
    none,
    block_type: types.BlockType,
    label_idx: u32,
    labels: []const u32, // For br_table
    func_idx: u32,
    call_indirect: struct { type_idx: u32, table_idx: u32 },
    local_idx: u32,
    global_idx: u32,
    mem_arg: struct { align_: u32, offset: u32 },
    i32: i32,
    i64: i64,
    f32: f32,
    f64: f64,
};

/// Decoded instruction
pub const Instruction = struct {
    opcode: Opcode,
    immediate: Immediate,
};

/// Decode a single instruction from the reader
pub fn decode(reader: *Reader) !Instruction {
    const opcode_byte = try reader.readByte();
    const opcode: Opcode = @enumFromInt(opcode_byte);

    const immediate: Immediate = switch (opcode) {
        // Control with block type
        .block, .loop, .@"if" => Immediate{ .block_type = try types.BlockType.read(reader) },

        // Branch
        .br, .br_if => Immediate{ .label_idx = try reader.readU32Leb128() },

        // br_table (variable length)
        .br_table => blk: {
            // Read label count + labels + default
            // For now, skip the labels (we'd need allocator)
            const count = try reader.readU32Leb128();
            for (0..count + 1) |_| {
                _ = try reader.readU32Leb128();
            }
            break :blk Immediate{ .none = {} };
        },

        // Call
        .call => Immediate{ .func_idx = try reader.readU32Leb128() },
        .call_indirect => Immediate{ .call_indirect = .{
            .type_idx = try reader.readU32Leb128(),
            .table_idx = try reader.readU32Leb128(),
        } },

        // Variable
        .local_get, .local_set, .local_tee => Immediate{ .local_idx = try reader.readU32Leb128() },
        .global_get, .global_set => Immediate{ .global_idx = try reader.readU32Leb128() },

        // Memory load/store
        .i32_load, .i64_load, .f32_load, .f64_load,
        .i32_load8_s, .i32_load8_u, .i32_load16_s, .i32_load16_u,
        .i64_load8_s, .i64_load8_u, .i64_load16_s, .i64_load16_u,
        .i64_load32_s, .i64_load32_u,
        .i32_store, .i64_store, .f32_store, .f64_store,
        .i32_store8, .i32_store16,
        .i64_store8, .i64_store16, .i64_store32,
        => Immediate{ .mem_arg = .{
            .align_ = try reader.readU32Leb128(),
            .offset = try reader.readU32Leb128(),
        } },

        // Memory size/grow (reserved byte)
        .memory_size, .memory_grow => blk: {
            _ = try reader.readByte(); // Reserved 0x00
            break :blk Immediate{ .none = {} };
        },

        // Constants
        .i32_const => Immediate{ .i32 = try reader.readI32Leb128() },
        .i64_const => Immediate{ .i64 = try reader.readI64Leb128() },
        .f32_const => Immediate{ .f32 = try reader.readF32() },
        .f64_const => Immediate{ .f64 = try reader.readF64() },

        // All other instructions have no immediates
        else => Immediate{ .none = {} },
    };

    return Instruction{
        .opcode = opcode,
        .immediate = immediate,
    };
}

/// Decode all instructions from code body until end
pub fn decodeAll(allocator: std.mem.Allocator, code: []const u8) ![]Instruction {
    var reader = Reader.init(code);
    var instructions: std.ArrayList(Instruction) = .empty;
    errdefer instructions.deinit(allocator);

    while (!reader.atEnd()) {
        const instr = try decode(&reader);
        try instructions.append(allocator, instr);

        // Stop at end instruction
        if (instr.opcode == .end) break;
    }

    return try instructions.toOwnedSlice(allocator);
}

// Tests
test "decode local.get" {
    var reader = Reader.init(&[_]u8{ 0x20, 0x00 });
    const instr = try decode(&reader);

    try std.testing.expectEqual(Opcode.local_get, instr.opcode);
    try std.testing.expectEqual(@as(u32, 0), instr.immediate.local_idx);
}

test "decode i32.const" {
    var reader = Reader.init(&[_]u8{ 0x41, 0x2A }); // i32.const 42
    const instr = try decode(&reader);

    try std.testing.expectEqual(Opcode.i32_const, instr.opcode);
    try std.testing.expectEqual(@as(i32, 42), instr.immediate.i32);
}

test "decode i32.add" {
    var reader = Reader.init(&[_]u8{0x6A});
    const instr = try decode(&reader);

    try std.testing.expectEqual(Opcode.i32_add, instr.opcode);
}

test "decode block" {
    var reader = Reader.init(&[_]u8{ 0x02, 0x40 }); // block (empty)
    const instr = try decode(&reader);

    try std.testing.expectEqual(Opcode.block, instr.opcode);
    try std.testing.expectEqual(types.BlockType{ .empty = {} }, instr.immediate.block_type);
}

test "decode memory load" {
    var reader = Reader.init(&[_]u8{ 0x28, 0x02, 0x10 }); // i32.load align=2 offset=16
    const instr = try decode(&reader);

    try std.testing.expectEqual(Opcode.i32_load, instr.opcode);
    try std.testing.expectEqual(@as(u32, 2), instr.immediate.mem_arg.align_);
    try std.testing.expectEqual(@as(u32, 16), instr.immediate.mem_arg.offset);
}
