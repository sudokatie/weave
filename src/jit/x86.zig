// x86-64 machine code generation for JIT compilation
//
// Generates native x86-64 machine code from WASM instructions.
// Uses the hardware stack for the WASM value stack.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const BranchCondition = enum {
    eq,
    ne,
    lt,
    gt,
    le,
    ge,
};

pub const X86CodeGen = struct {
    buffer: std.ArrayList(u8),
    label_offsets: std.AutoHashMap(u32, u64),
    current_offset: u64,
    stack_size: u32,
    allocator: Allocator,

    const Self = @This();

    // Register encodings
    const RAX: u8 = 0;
    const RCX: u8 = 1;
    const RDX: u8 = 2;
    const RBX: u8 = 3;
    const RSP: u8 = 4;
    const RBP: u8 = 5;
    const RSI: u8 = 6;
    const RDI: u8 = 7;

    // REX prefixes
    const REX_W: u8 = 0x48; // 64-bit operand size
    const REX_R: u8 = 0x44; // Extension of ModRM reg field
    const REX_X: u8 = 0x42; // Extension of SIB index field
    const REX_B: u8 = 0x41; // Extension of ModRM r/m, SIB base, or opcode reg

    pub fn init(allocator: Allocator) Self {
        return Self{
            .buffer = std.ArrayList(u8).empty,
            .label_offsets = std.AutoHashMap(u32, u64).init(allocator),
            .current_offset = 0,
            .stack_size = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.buffer.deinit(self.allocator);
        self.label_offsets.deinit();
    }

    /// Append raw bytes to the output buffer.
    pub fn emit(self: *Self, bytes: []const u8) void {
        self.buffer.appendSlice(self.allocator, bytes) catch return;
        self.current_offset += bytes.len;
    }

    /// Emit a single byte.
    fn emit_byte(self: *Self, byte: u8) void {
        self.buffer.append(self.allocator, byte) catch return;
        self.current_offset += 1;
    }

    /// Emit a 32-bit value in little-endian order.
    fn emit_i32_le(self: *Self, value: i32) void {
        const bytes = std.mem.asBytes(&value);
        self.emit(bytes);
    }

    /// Emit a 32-bit unsigned value in little-endian order.
    fn emit_u32_le(self: *Self, value: u32) void {
        const bytes = std.mem.asBytes(&value);
        self.emit(bytes);
    }

    /// Emit a 64-bit value in little-endian order.
    fn emit_i64_le(self: *Self, value: i64) void {
        const bytes = std.mem.asBytes(&value);
        self.emit(bytes);
    }

    /// Emit function prologue: push rbp; mov rbp, rsp; sub rsp, <space for locals>
    pub fn emit_prologue(self: *Self) void {
        // push rbp (0x55)
        self.emit_byte(0x55);
        // mov rbp, rsp (REX.W + 0x89 + ModRM for rsp -> rbp)
        self.emit(&[_]u8{ REX_W, 0x89, 0xE5 });
        // sub rsp, 64 (reserve space for locals, adjust as needed)
        // REX.W + 0x83 + ModRM (rsp, imm8) + imm8
        self.emit(&[_]u8{ REX_W, 0x83, 0xEC, 0x40 });
        self.stack_size = 0;
    }

    /// Emit function epilogue: add rsp, <locals>; pop rbp; ret
    pub fn emit_epilogue(self: *Self) void {
        // add rsp, 64 (restore stack)
        self.emit(&[_]u8{ REX_W, 0x83, 0xC4, 0x40 });
        // pop rbp (0x5D)
        self.emit_byte(0x5D);
        // ret (0xC3)
        self.emit_byte(0xC3);
    }

    /// Push an i32 constant onto the value stack.
    /// mov dword [rsp + offset], value
    pub fn emit_i32_const(self: *Self, value: i32) void {
        // Decrement stack pointer: sub rsp, 8
        self.emit(&[_]u8{ REX_W, 0x83, 0xEC, 0x08 });
        // mov dword [rsp], imm32
        // 0xC7 /0 with ModRM = 0x04 (mod=00, reg=0, r/m=100 for SIB)
        // SIB = 0x24 (scale=0, index=RSP, base=RSP)
        self.emit(&[_]u8{ 0xC7, 0x04, 0x24 });
        self.emit_i32_le(value);
        self.stack_size += 1;
    }

    /// Pop two i32 values, add them, push the result.
    pub fn emit_i32_add(self: *Self) void {
        // mov eax, [rsp] (pop first value into eax)
        self.emit(&[_]u8{ 0x8B, 0x04, 0x24 });
        // add rsp, 8
        self.emit(&[_]u8{ REX_W, 0x83, 0xC4, 0x08 });
        // add eax, [rsp] (add second value)
        self.emit(&[_]u8{ 0x03, 0x04, 0x24 });
        // mov [rsp], eax (store result)
        self.emit(&[_]u8{ 0x89, 0x04, 0x24 });
        self.stack_size -= 1;
    }

    /// Pop two i32 values, subtract them (second - first), push the result.
    pub fn emit_i32_sub(self: *Self) void {
        // mov eax, [rsp] (pop first value - the subtrahend)
        self.emit(&[_]u8{ 0x8B, 0x04, 0x24 });
        // add rsp, 8
        self.emit(&[_]u8{ REX_W, 0x83, 0xC4, 0x08 });
        // mov ecx, [rsp] (get second value - the minuend)
        self.emit(&[_]u8{ 0x8B, 0x0C, 0x24 });
        // sub ecx, eax (minuend - subtrahend)
        self.emit(&[_]u8{ 0x29, 0xC1 });
        // mov [rsp], ecx (store result)
        self.emit(&[_]u8{ 0x89, 0x0C, 0x24 });
        self.stack_size -= 1;
    }

    /// Pop two i32 values, multiply them, push the result.
    pub fn emit_i32_mul(self: *Self) void {
        // mov eax, [rsp] (pop first value)
        self.emit(&[_]u8{ 0x8B, 0x04, 0x24 });
        // add rsp, 8
        self.emit(&[_]u8{ REX_W, 0x83, 0xC4, 0x08 });
        // imul eax, [rsp] (multiply by second value)
        // 0x0F 0xAF /r
        self.emit(&[_]u8{ 0x0F, 0xAF, 0x04, 0x24 });
        // mov [rsp], eax (store result)
        self.emit(&[_]u8{ 0x89, 0x04, 0x24 });
        self.stack_size -= 1;
    }

    /// Load i32 from memory at base (stored in rdi) + offset.
    /// Pushes the loaded value onto the stack.
    pub fn emit_i32_load(self: *Self, offset: u32) void {
        // Pop address offset from stack into eax
        self.emit(&[_]u8{ 0x8B, 0x04, 0x24 });
        // add rsp, 8 (consume the address)
        self.emit(&[_]u8{ REX_W, 0x83, 0xC4, 0x08 });
        // add eax, offset (add static offset)
        if (offset > 0) {
            self.emit(&[_]u8{ 0x05 }); // add eax, imm32
            self.emit_u32_le(offset);
        }
        // movsxd rax, eax (sign extend to 64-bit for addressing)
        self.emit(&[_]u8{ REX_W, 0x63, 0xC0 });
        // mov eax, [rdi + rax] (load from memory base + computed address)
        self.emit(&[_]u8{ 0x8B, 0x04, 0x07 });
        // sub rsp, 8 (make room)
        self.emit(&[_]u8{ REX_W, 0x83, 0xEC, 0x08 });
        // mov [rsp], eax (push result)
        self.emit(&[_]u8{ 0x89, 0x04, 0x24 });
    }

    /// Store i32 to memory at base (stored in rdi) + offset.
    /// Pops value and address from the stack.
    pub fn emit_i32_store(self: *Self, offset: u32) void {
        // Pop value to store into ecx
        self.emit(&[_]u8{ 0x8B, 0x0C, 0x24 });
        // add rsp, 8
        self.emit(&[_]u8{ REX_W, 0x83, 0xC4, 0x08 });
        // Pop address into eax
        self.emit(&[_]u8{ 0x8B, 0x04, 0x24 });
        // add rsp, 8
        self.emit(&[_]u8{ REX_W, 0x83, 0xC4, 0x08 });
        // add eax, offset
        if (offset > 0) {
            self.emit(&[_]u8{ 0x05 }); // add eax, imm32
            self.emit_u32_le(offset);
        }
        // movsxd rax, eax
        self.emit(&[_]u8{ REX_W, 0x63, 0xC0 });
        // mov [rdi + rax], ecx (store to memory)
        self.emit(&[_]u8{ 0x89, 0x0C, 0x07 });
        self.stack_size -= 2;
    }

    /// Emit a conditional branch based on comparing top two stack values.
    pub fn emit_branch(self: *Self, condition: BranchCondition, target: u32) void {
        // Pop two values and compare
        // mov eax, [rsp] (first value)
        self.emit(&[_]u8{ 0x8B, 0x04, 0x24 });
        // add rsp, 8
        self.emit(&[_]u8{ REX_W, 0x83, 0xC4, 0x08 });
        // cmp [rsp], eax (compare second with first)
        self.emit(&[_]u8{ 0x39, 0x04, 0x24 });
        // add rsp, 8 (pop second value too)
        self.emit(&[_]u8{ REX_W, 0x83, 0xC4, 0x08 });

        // Conditional jump (0x0F 0x8x rel32)
        const opcode: u8 = switch (condition) {
            .eq => 0x84, // JE
            .ne => 0x85, // JNE
            .lt => 0x8C, // JL
            .ge => 0x8D, // JGE
            .le => 0x8E, // JLE
            .gt => 0x8F, // JG
        };
        self.emit(&[_]u8{ 0x0F, opcode });

        // Calculate relative offset (placeholder for now, will be patched)
        const target_offset = self.label_offsets.get(target) orelse 0;
        const current = self.current_offset + 4; // after the rel32
        const rel: i32 = @intCast(@as(i64, @intCast(target_offset)) - @as(i64, @intCast(current)));
        self.emit_i32_le(rel);

        self.stack_size -= 2;
    }

    /// Emit an unconditional jump to a target label.
    pub fn emit_jump(self: *Self, target: u32) void {
        // Try short jump first, fall back to near jump
        const target_offset = self.label_offsets.get(target) orelse 0;
        const current = self.current_offset + 2; // assuming short jump
        const rel: i64 = @as(i64, @intCast(target_offset)) - @as(i64, @intCast(current));

        if (rel >= -128 and rel <= 127) {
            // JMP rel8 (0xEB)
            self.emit_byte(0xEB);
            self.emit_byte(@bitCast(@as(i8, @intCast(rel))));
        } else {
            // JMP rel32 (0xE9)
            // Recalculate for 5-byte instruction
            const current_near = self.current_offset + 5;
            const rel_near: i32 = @intCast(@as(i64, @intCast(target_offset)) - @as(i64, @intCast(current_near)));
            self.emit_byte(0xE9);
            self.emit_i32_le(rel_near);
        }
    }

    /// Emit a call to a native function at the given address.
    pub fn emit_call(self: *Self, addr: u64) void {
        // mov rax, imm64 (load absolute address)
        self.emit(&[_]u8{ REX_W, 0xB8 }); // REX.W + MOV rax, imm64
        self.emit_i64_le(@bitCast(addr));
        // call rax (0xFF /2 with ModRM for rax)
        self.emit(&[_]u8{ 0xFF, 0xD0 });
    }

    /// Set a label at the current offset for branch targets.
    pub fn set_label(self: *Self, label: u32) void {
        self.label_offsets.put(label, self.current_offset) catch {};
    }

    /// Return the compiled code as a byte slice.
    pub fn get_code(self: *Self) []const u8 {
        return self.buffer.items;
    }

    /// Reset the code generator for reuse.
    pub fn reset(self: *Self) void {
        self.buffer.clearRetainingCapacity();
        self.label_offsets.clearRetainingCapacity();
        self.current_offset = 0;
        self.stack_size = 0;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "init and deinit" {
    var codegen = X86CodeGen.init(std.testing.allocator);
    defer codegen.deinit();

    try std.testing.expectEqual(@as(u64, 0), codegen.current_offset);
    try std.testing.expectEqual(@as(u32, 0), codegen.stack_size);
    try std.testing.expectEqual(@as(usize, 0), codegen.buffer.items.len);
}

test "emit appends bytes" {
    var codegen = X86CodeGen.init(std.testing.allocator);
    defer codegen.deinit();

    codegen.emit(&[_]u8{ 0x90, 0x90, 0x90 }); // NOP NOP NOP

    try std.testing.expectEqual(@as(usize, 3), codegen.buffer.items.len);
    try std.testing.expectEqual(@as(u64, 3), codegen.current_offset);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x90, 0x90, 0x90 }, codegen.get_code());
}

test "emit_prologue generates correct bytes" {
    var codegen = X86CodeGen.init(std.testing.allocator);
    defer codegen.deinit();

    codegen.emit_prologue();

    const expected = [_]u8{
        0x55, // push rbp
        0x48, 0x89, 0xE5, // mov rbp, rsp
        0x48, 0x83, 0xEC, 0x40, // sub rsp, 64
    };
    try std.testing.expectEqualSlices(u8, &expected, codegen.get_code());
}

test "emit_epilogue generates correct bytes" {
    var codegen = X86CodeGen.init(std.testing.allocator);
    defer codegen.deinit();

    codegen.emit_epilogue();

    const expected = [_]u8{
        0x48, 0x83, 0xC4, 0x40, // add rsp, 64
        0x5D, // pop rbp
        0xC3, // ret
    };
    try std.testing.expectEqualSlices(u8, &expected, codegen.get_code());
}

test "emit_i32_const generates correct bytes" {
    var codegen = X86CodeGen.init(std.testing.allocator);
    defer codegen.deinit();

    codegen.emit_i32_const(0x12345678);

    const expected = [_]u8{
        0x48, 0x83, 0xEC, 0x08, // sub rsp, 8
        0xC7, 0x04, 0x24, // mov dword [rsp], imm32
        0x78, 0x56, 0x34, 0x12, // 0x12345678 in little-endian
    };
    try std.testing.expectEqualSlices(u8, &expected, codegen.get_code());
    try std.testing.expectEqual(@as(u32, 1), codegen.stack_size);
}

test "emit_i32_const negative value" {
    var codegen = X86CodeGen.init(std.testing.allocator);
    defer codegen.deinit();

    codegen.emit_i32_const(-1);

    const expected = [_]u8{
        0x48, 0x83, 0xEC, 0x08, // sub rsp, 8
        0xC7, 0x04, 0x24, // mov dword [rsp], imm32
        0xFF, 0xFF, 0xFF, 0xFF, // -1 in little-endian (two's complement)
    };
    try std.testing.expectEqualSlices(u8, &expected, codegen.get_code());
}

test "emit_i32_add generates correct bytes" {
    var codegen = X86CodeGen.init(std.testing.allocator);
    defer codegen.deinit();

    codegen.stack_size = 2;
    codegen.emit_i32_add();

    const expected = [_]u8{
        0x8B, 0x04, 0x24, // mov eax, [rsp]
        0x48, 0x83, 0xC4, 0x08, // add rsp, 8
        0x03, 0x04, 0x24, // add eax, [rsp]
        0x89, 0x04, 0x24, // mov [rsp], eax
    };
    try std.testing.expectEqualSlices(u8, &expected, codegen.get_code());
    try std.testing.expectEqual(@as(u32, 1), codegen.stack_size);
}

test "emit_i32_sub generates correct bytes" {
    var codegen = X86CodeGen.init(std.testing.allocator);
    defer codegen.deinit();

    codegen.stack_size = 2;
    codegen.emit_i32_sub();

    const expected = [_]u8{
        0x8B, 0x04, 0x24, // mov eax, [rsp]
        0x48, 0x83, 0xC4, 0x08, // add rsp, 8
        0x8B, 0x0C, 0x24, // mov ecx, [rsp]
        0x29, 0xC1, // sub ecx, eax
        0x89, 0x0C, 0x24, // mov [rsp], ecx
    };
    try std.testing.expectEqualSlices(u8, &expected, codegen.get_code());
    try std.testing.expectEqual(@as(u32, 1), codegen.stack_size);
}

test "emit_i32_mul generates correct bytes" {
    var codegen = X86CodeGen.init(std.testing.allocator);
    defer codegen.deinit();

    codegen.stack_size = 2;
    codegen.emit_i32_mul();

    const expected = [_]u8{
        0x8B, 0x04, 0x24, // mov eax, [rsp]
        0x48, 0x83, 0xC4, 0x08, // add rsp, 8
        0x0F, 0xAF, 0x04, 0x24, // imul eax, [rsp]
        0x89, 0x04, 0x24, // mov [rsp], eax
    };
    try std.testing.expectEqualSlices(u8, &expected, codegen.get_code());
    try std.testing.expectEqual(@as(u32, 1), codegen.stack_size);
}

test "emit_call generates correct bytes" {
    var codegen = X86CodeGen.init(std.testing.allocator);
    defer codegen.deinit();

    codegen.emit_call(0x0000000012345678);

    const expected = [_]u8{
        0x48, 0xB8, // mov rax, imm64
        0x78, 0x56, 0x34, 0x12, 0x00, 0x00, 0x00, 0x00, // address in little-endian
        0xFF, 0xD0, // call rax
    };
    try std.testing.expectEqualSlices(u8, &expected, codegen.get_code());
}

test "emit_jump short generates correct bytes" {
    var codegen = X86CodeGen.init(std.testing.allocator);
    defer codegen.deinit();

    // Set label at offset 0
    codegen.set_label(0);
    // Emit some padding
    codegen.emit(&[_]u8{ 0x90, 0x90, 0x90, 0x90 }); // 4 NOPs
    // Jump back to label 0 (should be short jump)
    codegen.emit_jump(0);

    const code = codegen.get_code();
    // Last two bytes should be JMP rel8
    try std.testing.expectEqual(@as(u8, 0xEB), code[4]); // JMP rel8 opcode
    // rel8 = target - (current + 2) = 0 - 6 = -6 = 0xFA
    try std.testing.expectEqual(@as(u8, 0xFA), code[5]);
}

test "emit_jump near generates correct bytes" {
    var codegen = X86CodeGen.init(std.testing.allocator);
    defer codegen.deinit();

    // Jump forward to a label not yet set (rel32 will be computed as negative from 0)
    // For this test, set label first then pad with more than 127 bytes
    codegen.set_label(0);

    // Emit 130 NOPs to exceed short jump range
    var i: usize = 0;
    while (i < 130) : (i += 1) {
        codegen.emit_byte(0x90);
    }

    codegen.emit_jump(0);

    const code = codegen.get_code();
    // Should use near jump (E9)
    try std.testing.expectEqual(@as(u8, 0xE9), code[130]);
}

test "emit_branch eq generates conditional jump" {
    var codegen = X86CodeGen.init(std.testing.allocator);
    defer codegen.deinit();

    codegen.stack_size = 2;
    codegen.set_label(0);
    codegen.emit_branch(.eq, 0);

    const code = codegen.get_code();
    // Should contain 0x0F 0x84 for JE
    var found = false;
    for (0..code.len - 1) |j| {
        if (code[j] == 0x0F and code[j + 1] == 0x84) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
    try std.testing.expectEqual(@as(u32, 0), codegen.stack_size);
}

test "emit_branch generates different opcodes for conditions" {
    const TestCase = struct {
        condition: BranchCondition,
        expected_opcode: u8,
    };

    const cases = [_]TestCase{
        .{ .condition = .eq, .expected_opcode = 0x84 },
        .{ .condition = .ne, .expected_opcode = 0x85 },
        .{ .condition = .lt, .expected_opcode = 0x8C },
        .{ .condition = .ge, .expected_opcode = 0x8D },
        .{ .condition = .le, .expected_opcode = 0x8E },
        .{ .condition = .gt, .expected_opcode = 0x8F },
    };

    for (cases) |case| {
        var codegen = X86CodeGen.init(std.testing.allocator);
        defer codegen.deinit();

        codegen.stack_size = 2;
        codegen.set_label(0);
        codegen.emit_branch(case.condition, 0);

        const code = codegen.get_code();
        // Find the 0x0F prefix and check the following byte
        var found = false;
        for (0..code.len - 1) |j| {
            if (code[j] == 0x0F and code[j + 1] == case.expected_opcode) {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }
}

test "emit_i32_load generates correct bytes without offset" {
    var codegen = X86CodeGen.init(std.testing.allocator);
    defer codegen.deinit();

    codegen.emit_i32_load(0);

    const code = codegen.get_code();
    // Should start with mov eax, [rsp]
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x8B, 0x04, 0x24 }, code[0..3]);
    // Should contain movsxd rax, eax
    var found_movsxd = false;
    for (0..code.len - 2) |i| {
        if (code[i] == 0x48 and code[i + 1] == 0x63 and code[i + 2] == 0xC0) {
            found_movsxd = true;
            break;
        }
    }
    try std.testing.expect(found_movsxd);
}

test "emit_i32_load generates correct bytes with offset" {
    var codegen = X86CodeGen.init(std.testing.allocator);
    defer codegen.deinit();

    codegen.emit_i32_load(16);

    const code = codegen.get_code();
    // Should contain add eax, imm32 (0x05 + 16 in little endian)
    var found_add = false;
    for (0..code.len - 4) |i| {
        if (code[i] == 0x05 and code[i + 1] == 0x10 and code[i + 2] == 0x00) {
            found_add = true;
            break;
        }
    }
    try std.testing.expect(found_add);
}

test "emit_i32_store generates correct bytes" {
    var codegen = X86CodeGen.init(std.testing.allocator);
    defer codegen.deinit();

    codegen.stack_size = 2;
    codegen.emit_i32_store(0);

    const code = codegen.get_code();
    // Should start with mov ecx, [rsp] (pop value)
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x8B, 0x0C, 0x24 }, code[0..3]);
    // Should end with mov [rdi + rax], ecx
    const last_three = code[code.len - 3 ..];
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x89, 0x0C, 0x07 }, last_three);
    try std.testing.expectEqual(@as(u32, 0), codegen.stack_size);
}

test "get_code returns buffer contents" {
    var codegen = X86CodeGen.init(std.testing.allocator);
    defer codegen.deinit();

    codegen.emit(&[_]u8{ 0x90, 0xC3 });

    const code = codegen.get_code();
    try std.testing.expectEqual(@as(usize, 2), code.len);
    try std.testing.expectEqual(@as(u8, 0x90), code[0]);
    try std.testing.expectEqual(@as(u8, 0xC3), code[1]);
}

test "reset clears all state" {
    var codegen = X86CodeGen.init(std.testing.allocator);
    defer codegen.deinit();

    codegen.emit(&[_]u8{ 0x90, 0x90 });
    codegen.set_label(0);
    codegen.stack_size = 5;

    codegen.reset();

    try std.testing.expectEqual(@as(usize, 0), codegen.buffer.items.len);
    try std.testing.expectEqual(@as(u64, 0), codegen.current_offset);
    try std.testing.expectEqual(@as(u32, 0), codegen.stack_size);
    try std.testing.expectEqual(@as(?u64, null), codegen.label_offsets.get(0));
}

test "full function sequence" {
    var codegen = X86CodeGen.init(std.testing.allocator);
    defer codegen.deinit();

    // Generate a simple function that adds two constants
    codegen.emit_prologue();
    codegen.emit_i32_const(10);
    codegen.emit_i32_const(20);
    codegen.emit_i32_add();
    codegen.emit_epilogue();

    const code = codegen.get_code();
    // Verify the code was generated
    try std.testing.expect(code.len > 0);
    // Should start with push rbp
    try std.testing.expectEqual(@as(u8, 0x55), code[0]);
    // Should end with ret
    try std.testing.expectEqual(@as(u8, 0xC3), code[code.len - 1]);
    // Stack size should be 1 (two pushes, one add that pops two and pushes one)
    try std.testing.expectEqual(@as(u32, 1), codegen.stack_size);
}
