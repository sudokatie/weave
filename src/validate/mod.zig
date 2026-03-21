// WASM Module Validation
//
// Validates module structure and instruction sequences per WASM spec.
// Type checks all instructions, validates stack usage, handles unreachable code.

const std = @import("std");
const binary = @import("../binary/mod.zig");
const types = binary.types;
const instructions = binary.instructions;

pub const ValidationError = error{
    InvalidType,
    TypeMismatch,
    StackUnderflow,
    StackOverflow,
    UnknownLocal,
    UnknownGlobal,
    UnknownFunction,
    UnknownType,
    InvalidBranch,
    InvalidBlockType,
    ImmutableGlobal,
    MemoryRequired,
    TableRequired,
    InvalidAlignment,
    OutOfMemory,
};

/// Control frame for tracking block/loop/if structure
const ControlFrame = struct {
    opcode: instructions.Opcode,
    start_types: []const types.ValType, // Types on stack when entered
    end_types: []const types.ValType, // Types on stack when exited
    height: usize, // Stack height when entered
    is_unreachable: bool, // True after unreachable instruction
};

/// Validation context
pub const Validator = struct {
    allocator: std.mem.Allocator,
    module: *binary.Module,
    // Type stack for current function
    type_stack: std.ArrayList(types.ValType),
    // Control stack for blocks
    control_stack: std.ArrayList(ControlFrame),
    // Current function's locals
    locals: []const types.ValType,
    // Scratch space for block types
    scratch: std.ArrayList(types.ValType),

    pub fn init(allocator: std.mem.Allocator, module: *binary.Module) Validator {
        return .{
            .allocator = allocator,
            .module = module,
            .type_stack = .empty,
            .control_stack = .empty,
            .locals = &.{},
            .scratch = .empty,
        };
    }

    pub fn deinit(self: *Validator) void {
        self.type_stack.deinit(self.allocator);
        self.control_stack.deinit(self.allocator);
        self.scratch.deinit(self.allocator);
    }

    /// Validate entire module
    pub fn validate(self: *Validator) ValidationError!void {
        // Validate all function bodies
        for (0..self.module.code.len) |i| {
            try self.validateFunction(@intCast(i));
        }
    }

    /// Validate a single function body
    pub fn validateFunction(self: *Validator, func_idx: u32) ValidationError!void {
        // Get function type
        const type_idx = self.module.funcs[func_idx];
        if (type_idx >= self.module.types.len) return error.UnknownType;
        const func_type = &self.module.types[type_idx];

        // Get code
        const code = &self.module.code[func_idx];

        // Build locals: params + local declarations
        self.scratch.clearRetainingCapacity();
        for (func_type.params) |p| {
            self.scratch.append(self.allocator, p) catch return error.OutOfMemory;
        }
        for (code.locals) |local| {
            for (0..local.count) |_| {
                self.scratch.append(self.allocator, local.val_type) catch return error.OutOfMemory;
            }
        }
        self.locals = self.scratch.items;

        // Reset stacks
        self.type_stack.clearRetainingCapacity();
        self.control_stack.clearRetainingCapacity();

        // Push implicit function block
        self.control_stack.append(self.allocator, ControlFrame{
            .opcode = .block,
            .start_types = &.{},
            .end_types = func_type.results,
            .height = 0,
            .is_unreachable = false,
        }) catch return error.OutOfMemory;

        // Validate each instruction
        var reader = binary.Reader.init(code.body);
        while (!reader.atEnd()) {
            const instr = instructions.decode(&reader) catch return error.InvalidType;
            try self.validateInstruction(instr);

            // Stop at final end
            if (instr.opcode == .end and self.control_stack.items.len == 0) break;
        }
    }

    /// Validate a single instruction
    fn validateInstruction(self: *Validator, instr: instructions.Instruction) ValidationError!void {
        const frame = if (self.control_stack.items.len > 0)
            &self.control_stack.items[self.control_stack.items.len - 1]
        else
            null;
        const is_unreachable = if (frame) |f| f.is_unreachable else false;

        switch (instr.opcode) {
            // Control
            .@"unreachable" => {
                if (frame) |f| f.is_unreachable = true;
            },
            .nop => {},
            .block => try self.pushBlock(instr.opcode, instr.immediate.block_type),
            .loop => try self.pushBlock(instr.opcode, instr.immediate.block_type),
            .@"if" => {
                try self.popExpect(.i32);
                try self.pushBlock(instr.opcode, instr.immediate.block_type);
            },
            .@"else" => try self.handleElse(),
            .end => try self.handleEnd(),
            .br => try self.validateBranch(instr.immediate.label_idx),
            .br_if => {
                try self.popExpect(.i32);
                try self.validateBranch(instr.immediate.label_idx);
            },
            .br_table => {
                try self.popExpect(.i32);
                // Already validated structure during decode
            },
            .@"return" => {
                // Pop return values
                if (self.control_stack.items.len > 0) {
                    const func_frame = &self.control_stack.items[0];
                    try self.popExpectTypes(func_frame.end_types);
                    if (frame) |f| f.is_unreachable = true;
                }
            },
            .call => {
                const func_idx = instr.immediate.func_idx;
                if (func_idx >= self.module.funcs.len) return error.UnknownFunction;
                const type_idx = self.module.funcs[func_idx];
                const func_type = &self.module.types[type_idx];
                try self.popExpectTypes(func_type.params);
                try self.pushTypes(func_type.results);
            },
            .call_indirect => {
                try self.popExpect(.i32); // Table index
                const ci = instr.immediate.call_indirect;
                if (ci.type_idx >= self.module.types.len) return error.UnknownType;
                const func_type = &self.module.types[ci.type_idx];
                try self.popExpectTypes(func_type.params);
                try self.pushTypes(func_type.results);
            },

            // Parametric
            .drop => {
                _ = try self.pop();
            },
            .select => {
                try self.popExpect(.i32);
                const t1 = try self.pop();
                const t2 = try self.pop();
                if (!is_unreachable and t1 != t2) return error.TypeMismatch;
                try self.push(t1);
            },

            // Variable
            .local_get => {
                const idx = instr.immediate.local_idx;
                if (idx >= self.locals.len) return error.UnknownLocal;
                try self.push(self.locals[idx]);
            },
            .local_set => {
                const idx = instr.immediate.local_idx;
                if (idx >= self.locals.len) return error.UnknownLocal;
                try self.popExpect(self.locals[idx]);
            },
            .local_tee => {
                const idx = instr.immediate.local_idx;
                if (idx >= self.locals.len) return error.UnknownLocal;
                try self.popExpect(self.locals[idx]);
                try self.push(self.locals[idx]);
            },
            .global_get => {
                const idx = instr.immediate.global_idx;
                if (idx >= self.module.globals.len) return error.UnknownGlobal;
                try self.push(self.module.globals[idx].global_type.val_type);
            },
            .global_set => {
                const idx = instr.immediate.global_idx;
                if (idx >= self.module.globals.len) return error.UnknownGlobal;
                if (!self.module.globals[idx].global_type.mutable) return error.ImmutableGlobal;
                try self.popExpect(self.module.globals[idx].global_type.val_type);
            },

            // Memory
            .i32_load, .i32_load8_s, .i32_load8_u, .i32_load16_s, .i32_load16_u => {
                if (self.module.mems.len == 0) return error.MemoryRequired;
                try self.popExpect(.i32);
                try self.push(.i32);
            },
            .i64_load, .i64_load8_s, .i64_load8_u, .i64_load16_s, .i64_load16_u, .i64_load32_s, .i64_load32_u => {
                if (self.module.mems.len == 0) return error.MemoryRequired;
                try self.popExpect(.i32);
                try self.push(.i64);
            },
            .f32_load => {
                if (self.module.mems.len == 0) return error.MemoryRequired;
                try self.popExpect(.i32);
                try self.push(.f32);
            },
            .f64_load => {
                if (self.module.mems.len == 0) return error.MemoryRequired;
                try self.popExpect(.i32);
                try self.push(.f64);
            },
            .i32_store, .i32_store8, .i32_store16 => {
                if (self.module.mems.len == 0) return error.MemoryRequired;
                try self.popExpect(.i32);
                try self.popExpect(.i32);
            },
            .i64_store, .i64_store8, .i64_store16, .i64_store32 => {
                if (self.module.mems.len == 0) return error.MemoryRequired;
                try self.popExpect(.i64);
                try self.popExpect(.i32);
            },
            .f32_store => {
                if (self.module.mems.len == 0) return error.MemoryRequired;
                try self.popExpect(.f32);
                try self.popExpect(.i32);
            },
            .f64_store => {
                if (self.module.mems.len == 0) return error.MemoryRequired;
                try self.popExpect(.f64);
                try self.popExpect(.i32);
            },
            .memory_size, .memory_grow => {
                if (self.module.mems.len == 0) return error.MemoryRequired;
                if (instr.opcode == .memory_grow) try self.popExpect(.i32);
                try self.push(.i32);
            },

            // Numeric constants
            .i32_const => try self.push(.i32),
            .i64_const => try self.push(.i64),
            .f32_const => try self.push(.f32),
            .f64_const => try self.push(.f64),

            // i32 comparison (i32 -> i32 -> i32)
            .i32_eqz => {
                try self.popExpect(.i32);
                try self.push(.i32);
            },
            .i32_eq, .i32_ne, .i32_lt_s, .i32_lt_u, .i32_gt_s, .i32_gt_u, .i32_le_s, .i32_le_u, .i32_ge_s, .i32_ge_u => {
                try self.popExpect(.i32);
                try self.popExpect(.i32);
                try self.push(.i32);
            },

            // i64 comparison (i64 -> i32)
            .i64_eqz => {
                try self.popExpect(.i64);
                try self.push(.i32);
            },
            .i64_eq, .i64_ne, .i64_lt_s, .i64_lt_u, .i64_gt_s, .i64_gt_u, .i64_le_s, .i64_le_u, .i64_ge_s, .i64_ge_u => {
                try self.popExpect(.i64);
                try self.popExpect(.i64);
                try self.push(.i32);
            },

            // f32 comparison
            .f32_eq, .f32_ne, .f32_lt, .f32_gt, .f32_le, .f32_ge => {
                try self.popExpect(.f32);
                try self.popExpect(.f32);
                try self.push(.i32);
            },

            // f64 comparison
            .f64_eq, .f64_ne, .f64_lt, .f64_gt, .f64_le, .f64_ge => {
                try self.popExpect(.f64);
                try self.popExpect(.f64);
                try self.push(.i32);
            },

            // i32 unary (i32 -> i32)
            .i32_clz, .i32_ctz, .i32_popcnt => {
                try self.popExpect(.i32);
                try self.push(.i32);
            },

            // i32 binary (i32 i32 -> i32)
            .i32_add, .i32_sub, .i32_mul, .i32_div_s, .i32_div_u, .i32_rem_s, .i32_rem_u, .i32_and, .i32_or, .i32_xor, .i32_shl, .i32_shr_s, .i32_shr_u, .i32_rotl, .i32_rotr => {
                try self.popExpect(.i32);
                try self.popExpect(.i32);
                try self.push(.i32);
            },

            // i64 unary (i64 -> i64)
            .i64_clz, .i64_ctz, .i64_popcnt => {
                try self.popExpect(.i64);
                try self.push(.i64);
            },

            // i64 binary (i64 i64 -> i64)
            .i64_add, .i64_sub, .i64_mul, .i64_div_s, .i64_div_u, .i64_rem_s, .i64_rem_u, .i64_and, .i64_or, .i64_xor, .i64_shl, .i64_shr_s, .i64_shr_u, .i64_rotl, .i64_rotr => {
                try self.popExpect(.i64);
                try self.popExpect(.i64);
                try self.push(.i64);
            },

            // f32 unary (f32 -> f32)
            .f32_abs, .f32_neg, .f32_ceil, .f32_floor, .f32_trunc, .f32_nearest, .f32_sqrt => {
                try self.popExpect(.f32);
                try self.push(.f32);
            },

            // f32 binary (f32 f32 -> f32)
            .f32_add, .f32_sub, .f32_mul, .f32_div, .f32_min, .f32_max, .f32_copysign => {
                try self.popExpect(.f32);
                try self.popExpect(.f32);
                try self.push(.f32);
            },

            // f64 unary (f64 -> f64)
            .f64_abs, .f64_neg, .f64_ceil, .f64_floor, .f64_trunc, .f64_nearest, .f64_sqrt => {
                try self.popExpect(.f64);
                try self.push(.f64);
            },

            // f64 binary (f64 f64 -> f64)
            .f64_add, .f64_sub, .f64_mul, .f64_div, .f64_min, .f64_max, .f64_copysign => {
                try self.popExpect(.f64);
                try self.popExpect(.f64);
                try self.push(.f64);
            },

            // Conversions
            .i32_wrap_i64 => {
                try self.popExpect(.i64);
                try self.push(.i32);
            },
            .i32_trunc_f32_s, .i32_trunc_f32_u => {
                try self.popExpect(.f32);
                try self.push(.i32);
            },
            .i32_trunc_f64_s, .i32_trunc_f64_u => {
                try self.popExpect(.f64);
                try self.push(.i32);
            },
            .i64_extend_i32_s, .i64_extend_i32_u => {
                try self.popExpect(.i32);
                try self.push(.i64);
            },
            .i64_trunc_f32_s, .i64_trunc_f32_u => {
                try self.popExpect(.f32);
                try self.push(.i64);
            },
            .i64_trunc_f64_s, .i64_trunc_f64_u => {
                try self.popExpect(.f64);
                try self.push(.i64);
            },
            .f32_convert_i32_s, .f32_convert_i32_u => {
                try self.popExpect(.i32);
                try self.push(.f32);
            },
            .f32_convert_i64_s, .f32_convert_i64_u => {
                try self.popExpect(.i64);
                try self.push(.f32);
            },
            .f32_demote_f64 => {
                try self.popExpect(.f64);
                try self.push(.f32);
            },
            .f64_convert_i32_s, .f64_convert_i32_u => {
                try self.popExpect(.i32);
                try self.push(.f64);
            },
            .f64_convert_i64_s, .f64_convert_i64_u => {
                try self.popExpect(.i64);
                try self.push(.f64);
            },
            .f64_promote_f32 => {
                try self.popExpect(.f32);
                try self.push(.f64);
            },
            .i32_reinterpret_f32 => {
                try self.popExpect(.f32);
                try self.push(.i32);
            },
            .i64_reinterpret_f64 => {
                try self.popExpect(.f64);
                try self.push(.i64);
            },
            .f32_reinterpret_i32 => {
                try self.popExpect(.i32);
                try self.push(.f32);
            },
            .f64_reinterpret_i64 => {
                try self.popExpect(.i64);
                try self.push(.f64);
            },

            // Sign extension
            .i32_extend8_s, .i32_extend16_s => {
                try self.popExpect(.i32);
                try self.push(.i32);
            },
            .i64_extend8_s, .i64_extend16_s, .i64_extend32_s => {
                try self.popExpect(.i64);
                try self.push(.i64);
            },

            else => {},
        }
    }

    // Stack operations

    fn push(self: *Validator, t: types.ValType) ValidationError!void {
        self.type_stack.append(self.allocator, t) catch return error.OutOfMemory;
    }

    fn pushTypes(self: *Validator, ts: []const types.ValType) ValidationError!void {
        for (ts) |t| {
            try self.push(t);
        }
    }

    fn pop(self: *Validator) ValidationError!types.ValType {
        const frame = if (self.control_stack.items.len > 0)
            &self.control_stack.items[self.control_stack.items.len - 1]
        else
            null;

        // Check underflow relative to control frame
        const min_height = if (frame) |f| f.height else 0;
        if (self.type_stack.items.len <= min_height) {
            // In unreachable code, we can pop anything
            if (frame) |f| {
                if (f.is_unreachable) return .i32; // Any type is fine
            }
            return error.StackUnderflow;
        }

        return self.type_stack.pop() orelse unreachable;
    }

    fn popExpect(self: *Validator, expected: types.ValType) ValidationError!void {
        const frame = if (self.control_stack.items.len > 0)
            &self.control_stack.items[self.control_stack.items.len - 1]
        else
            null;

        const min_height = if (frame) |f| f.height else 0;
        if (self.type_stack.items.len <= min_height) {
            if (frame) |f| {
                if (f.is_unreachable) return; // OK in unreachable
            }
            return error.StackUnderflow;
        }

        const actual = self.type_stack.pop() orelse unreachable;
        // Skip type check in unreachable code
        if (frame) |f| {
            if (f.is_unreachable) return;
        }
        if (actual != expected) return error.TypeMismatch;
    }

    fn popExpectTypes(self: *Validator, ts: []const types.ValType) ValidationError!void {
        // Pop in reverse order
        var i = ts.len;
        while (i > 0) {
            i -= 1;
            try self.popExpect(ts[i]);
        }
    }

    // Control flow

    fn pushBlock(self: *Validator, opcode: instructions.Opcode, block_type: types.BlockType) ValidationError!void {
        const end_types: []const types.ValType = switch (block_type) {
            .empty => &.{},
            .val_type => |vt| blk: {
                // Single result type - need to allocate
                self.scratch.clearRetainingCapacity();
                self.scratch.append(self.allocator, vt) catch return error.OutOfMemory;
                break :blk self.scratch.items;
            },
            .type_index => |idx| blk: {
                if (idx >= self.module.types.len) return error.UnknownType;
                break :blk self.module.types[idx].results;
            },
        };

        self.control_stack.append(self.allocator, ControlFrame{
            .opcode = opcode,
            .start_types = &.{},
            .end_types = end_types,
            .height = self.type_stack.items.len,
            .is_unreachable = false,
        }) catch return error.OutOfMemory;
    }

    fn handleElse(self: *Validator) ValidationError!void {
        if (self.control_stack.items.len == 0) return error.InvalidBlockType;
        var frame = &self.control_stack.items[self.control_stack.items.len - 1];
        if (frame.opcode != .@"if") return error.InvalidBlockType;

        // Pop expected results
        try self.popExpectTypes(frame.end_types);

        // Reset to block start height
        self.type_stack.shrinkRetainingCapacity(frame.height);
        frame.is_unreachable = false;
    }

    fn handleEnd(self: *Validator) ValidationError!void {
        if (self.control_stack.items.len == 0) return;
        const frame = self.control_stack.pop() orelse return;

        // Pop expected results
        try self.popExpectTypes(frame.end_types);

        // Reset to frame start height and push results
        self.type_stack.shrinkRetainingCapacity(frame.height);
        try self.pushTypes(frame.end_types);
    }

    fn validateBranch(self: *Validator, label_idx: u32) ValidationError!void {
        if (label_idx >= self.control_stack.items.len) return error.InvalidBranch;

        // Get target frame (counting from top)
        const target_idx = self.control_stack.items.len - 1 - label_idx;
        const target = &self.control_stack.items[target_idx];

        // For loop, branch to start (no values); for block/if, branch to end (results)
        const target_types = if (target.opcode == .loop) &[_]types.ValType{} else target.end_types;

        // Check we have the right types
        for (target_types) |expected| {
            const stack_idx = self.type_stack.items.len - target_types.len;
            if (stack_idx < target.height) return error.StackUnderflow;
            const actual = self.type_stack.items[stack_idx + (target_types.len - 1)];
            if (actual != expected) return error.TypeMismatch;
        }
    }
};

// Tests
test "validate simple function" {
    const allocator = std.testing.allocator;

    // Function: () -> i32 { i32.const 42 }
    const wasm = "\x00asm\x01\x00\x00\x00" ++
        "\x01\x05\x01\x60\x00\x01\x7f" ++ // type section: () -> i32
        "\x03\x02\x01\x00" ++ // function section: 1 func, type 0
        "\x0a\x06\x01\x04\x00\x41\x2a\x0b"; // code: i32.const 42, end

    var module = try binary.Module.parse(allocator, wasm);
    defer module.deinit();

    var validator = Validator.init(allocator, &module);
    defer validator.deinit();

    try validator.validate();
}

test "validate add function" {
    const allocator = std.testing.allocator;

    // Function: (i32, i32) -> i32 { local.get 0, local.get 1, i32.add }
    const wasm = "\x00asm\x01\x00\x00\x00" ++
        "\x01\x07\x01\x60\x02\x7f\x7f\x01\x7f" ++ // type: (i32, i32) -> i32
        "\x03\x02\x01\x00" ++ // function section: 1 func, type 0
        "\x0a\x09\x01\x07\x00\x20\x00\x20\x01\x6a\x0b"; // code: local.get 0, local.get 1, i32.add, end

    var module = try binary.Module.parse(allocator, wasm);
    defer module.deinit();

    var validator = Validator.init(allocator, &module);
    defer validator.deinit();

    try validator.validate();
}

test "validate type mismatch" {
    const allocator = std.testing.allocator;

    // Function: () -> i32 { i64.const 42 } - wrong return type
    const wasm = "\x00asm\x01\x00\x00\x00" ++
        "\x01\x05\x01\x60\x00\x01\x7f" ++ // type: () -> i32
        "\x03\x02\x01\x00" ++ // function section
        "\x0a\x06\x01\x04\x00\x42\x2a\x0b"; // code: i64.const 42, end

    var module = try binary.Module.parse(allocator, wasm);
    defer module.deinit();

    var validator = Validator.init(allocator, &module);
    defer validator.deinit();

    const result = validator.validate();
    try std.testing.expectError(error.TypeMismatch, result);
}

test "validate stack underflow" {
    const allocator = std.testing.allocator;

    // Function: () -> i32 { i32.add } - no values on stack
    // Code section: section_id(0x0a) section_size(5) num_funcs(1) body_size(3) num_locals(0) i32.add(0x6a) end(0x0b)
    const wasm = "\x00asm\x01\x00\x00\x00" ++
        "\x01\x05\x01\x60\x00\x01\x7f" ++ // type: () -> i32
        "\x03\x02\x01\x00" ++ // function section
        "\x0a\x05\x01\x03\x00\x6a\x0b"; // code: body_size=3, no locals, i32.add, end

    var module = try binary.Module.parse(allocator, wasm);
    defer module.deinit();

    var validator = Validator.init(allocator, &module);
    defer validator.deinit();

    const result = validator.validate();
    try std.testing.expectError(error.StackUnderflow, result);
}

test "validate unknown local" {
    const allocator = std.testing.allocator;

    // Function: () -> i32 { local.get 5 } - no local 5
    // Code section: section_id(0x0a) section_size(6) num_funcs(1) body_size(4) num_locals(0) local.get(0x20) 5 end(0x0b)
    const wasm = "\x00asm\x01\x00\x00\x00" ++
        "\x01\x05\x01\x60\x00\x01\x7f" ++ // type: () -> i32
        "\x03\x02\x01\x00" ++ // function section
        "\x0a\x06\x01\x04\x00\x20\x05\x0b"; // code: body_size=4, no locals, local.get 5, end

    var module = try binary.Module.parse(allocator, wasm);
    defer module.deinit();

    var validator = Validator.init(allocator, &module);
    defer validator.deinit();

    const result = validator.validate();
    try std.testing.expectError(error.UnknownLocal, result);
}

test "validate with locals" {
    const allocator = std.testing.allocator;

    // Function: () -> i32 { (local i32) local.get 0 }
    // Code section: section_id(0x0a) section_size(8) num_funcs(1) body_size(6) num_local_entries(1) count(1) type(i32) local.get(0x20) 0 end(0x0b)
    const wasm = "\x00asm\x01\x00\x00\x00" ++
        "\x01\x05\x01\x60\x00\x01\x7f" ++ // type: () -> i32
        "\x03\x02\x01\x00" ++ // function section
        "\x0a\x08\x01\x06\x01\x01\x7f\x20\x00\x0b"; // code: body_size=6, 1 local entry (1 x i32), local.get 0, end

    var module = try binary.Module.parse(allocator, wasm);
    defer module.deinit();

    var validator = Validator.init(allocator, &module);
    defer validator.deinit();

    try validator.validate();
}

test "validate block" {
    const allocator = std.testing.allocator;

    // Function: () -> i32 { block (result i32) i32.const 42 end }
    const wasm = "\x00asm\x01\x00\x00\x00" ++
        "\x01\x05\x01\x60\x00\x01\x7f" ++ // type: () -> i32
        "\x03\x02\x01\x00" ++ // function section
        "\x0a\x09\x01\x07\x00\x02\x7f\x41\x2a\x0b\x0b"; // code: block i32, i32.const 42, end, end

    var module = try binary.Module.parse(allocator, wasm);
    defer module.deinit();

    var validator = Validator.init(allocator, &module);
    defer validator.deinit();

    try validator.validate();
}
