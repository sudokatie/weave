// WASM interpreter

const std = @import("std");
const binary = @import("../binary/mod.zig");
const stack_mod = @import("stack.zig");
const memory_mod = @import("memory.zig");

const Stack = stack_mod.Stack;
const Value = stack_mod.Value;
const Frame = stack_mod.Frame;
const Label = stack_mod.Label;
const Memory = memory_mod.Memory;
const Opcode = binary.Opcode;

pub const Interpreter = struct {
    stack: Stack,
    memory: ?*Memory,
    module: *binary.Module,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, module: *binary.Module) Interpreter {
        return Interpreter{
            .stack = Stack.init(allocator),
            .memory = null,
            .module = module,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Interpreter) void {
        self.stack.deinit();
    }

    /// Execute a function by index
    pub fn call(self: *Interpreter, func_idx: u32, args: []const Value) ![]Value {
        // Get function type
        const type_idx = self.module.funcs[func_idx];
        const func_type = &self.module.types[type_idx];

        // Check argument count
        if (args.len != func_type.params.len) return error.ArgumentCountMismatch;

        // Get code
        const code = &self.module.code[func_idx];

        // Set up locals
        var total_locals: usize = func_type.params.len;
        for (code.locals) |local| {
            total_locals += local.count;
        }

        var locals = try self.allocator.alloc(Value, total_locals);
        errdefer self.allocator.free(locals);

        // Copy arguments
        for (args, 0..) |arg, i| {
            locals[i] = arg;
        }

        // Initialize remaining locals to zero
        var local_idx = args.len;
        for (code.locals) |local| {
            for (0..local.count) |_| {
                locals[local_idx] = Value.fromValType(local.val_type);
                local_idx += 1;
            }
        }

        // Push frame
        try self.stack.pushFrame(Frame{
            .func_idx = func_idx,
            .locals = locals,
            .return_arity = @intCast(func_type.results.len),
            .ip = 0,
            .module_idx = 0,
            .stack_height = self.stack.valueStackHeight(),
        });

        // Execute
        try self.execute(code.body);

        // Get results
        var results = try self.allocator.alloc(Value, func_type.results.len);
        for (0..func_type.results.len) |i| {
            results[func_type.results.len - 1 - i] = try self.stack.pop();
        }

        // Pop frame
        var frame = try self.stack.popFrame();
        frame.deinit(self.allocator);

        return results;
    }

    /// Execute code body
    fn execute(self: *Interpreter, code: []const u8) !void {
        var reader = binary.Reader.init(code);

        while (!reader.atEnd()) {
            const instr = try binary.instructions.decode(&reader);

            switch (instr.opcode) {
                // Control
                .@"unreachable" => return error.Unreachable,
                .nop => {},
                .end, .@"else" => {
                    // End of block/function
                    break;
                },
                .@"return" => {
                    // Return from function
                    break;
                },

                // Parametric
                .drop => _ = try self.stack.pop(),
                .select => {
                    const cond = try self.stack.popI32();
                    const val2 = try self.stack.pop();
                    const val1 = try self.stack.pop();
                    try self.stack.push(if (cond != 0) val1 else val2);
                },

                // Variable
                .local_get => {
                    const frame = try self.stack.currentFrame();
                    const idx = instr.immediate.local_idx;
                    try self.stack.push(frame.locals[idx]);
                },
                .local_set => {
                    const frame = try self.stack.currentFrame();
                    const idx = instr.immediate.local_idx;
                    frame.locals[idx] = try self.stack.pop();
                },
                .local_tee => {
                    const frame = try self.stack.currentFrame();
                    const idx = instr.immediate.local_idx;
                    frame.locals[idx] = try self.stack.peek();
                },

                // Numeric constants
                .i32_const => try self.stack.pushI32(instr.immediate.i32),
                .i64_const => try self.stack.pushI64(instr.immediate.i64),
                .f32_const => try self.stack.pushF32(instr.immediate.f32),
                .f64_const => try self.stack.pushF64(instr.immediate.f64),

                // i32 comparison
                .i32_eqz => {
                    const v = try self.stack.popI32();
                    try self.stack.pushI32(if (v == 0) 1 else 0);
                },
                .i32_eq => try self.binopI32(struct {
                    fn op(a: i32, b: i32) i32 {
                        return if (a == b) 1 else 0;
                    }
                }.op),
                .i32_ne => try self.binopI32(struct {
                    fn op(a: i32, b: i32) i32 {
                        return if (a != b) 1 else 0;
                    }
                }.op),
                .i32_lt_s => try self.binopI32(struct {
                    fn op(a: i32, b: i32) i32 {
                        return if (a < b) 1 else 0;
                    }
                }.op),
                .i32_gt_s => try self.binopI32(struct {
                    fn op(a: i32, b: i32) i32 {
                        return if (a > b) 1 else 0;
                    }
                }.op),
                .i32_le_s => try self.binopI32(struct {
                    fn op(a: i32, b: i32) i32 {
                        return if (a <= b) 1 else 0;
                    }
                }.op),
                .i32_ge_s => try self.binopI32(struct {
                    fn op(a: i32, b: i32) i32 {
                        return if (a >= b) 1 else 0;
                    }
                }.op),

                // i32 arithmetic
                .i32_add => try self.binopI32(struct {
                    fn op(a: i32, b: i32) i32 {
                        return a +% b;
                    }
                }.op),
                .i32_sub => try self.binopI32(struct {
                    fn op(a: i32, b: i32) i32 {
                        return a -% b;
                    }
                }.op),
                .i32_mul => try self.binopI32(struct {
                    fn op(a: i32, b: i32) i32 {
                        return a *% b;
                    }
                }.op),
                .i32_div_s => {
                    const b = try self.stack.popI32();
                    const a = try self.stack.popI32();
                    if (b == 0) return error.DivisionByZero;
                    try self.stack.pushI32(@divTrunc(a, b));
                },
                .i32_rem_s => {
                    const b = try self.stack.popI32();
                    const a = try self.stack.popI32();
                    if (b == 0) return error.DivisionByZero;
                    try self.stack.pushI32(@rem(a, b));
                },
                .i32_and => try self.binopI32(struct {
                    fn op(a: i32, b: i32) i32 {
                        return a & b;
                    }
                }.op),
                .i32_or => try self.binopI32(struct {
                    fn op(a: i32, b: i32) i32 {
                        return a | b;
                    }
                }.op),
                .i32_xor => try self.binopI32(struct {
                    fn op(a: i32, b: i32) i32 {
                        return a ^ b;
                    }
                }.op),

                // i64 arithmetic (subset)
                .i64_add => try self.binopI64(struct {
                    fn op(a: i64, b: i64) i64 {
                        return a +% b;
                    }
                }.op),
                .i64_sub => try self.binopI64(struct {
                    fn op(a: i64, b: i64) i64 {
                        return a -% b;
                    }
                }.op),
                .i64_mul => try self.binopI64(struct {
                    fn op(a: i64, b: i64) i64 {
                        return a *% b;
                    }
                }.op),

                // f32 arithmetic (subset)
                .f32_add => try self.binopF32(struct {
                    fn op(a: f32, b: f32) f32 {
                        return a + b;
                    }
                }.op),
                .f32_sub => try self.binopF32(struct {
                    fn op(a: f32, b: f32) f32 {
                        return a - b;
                    }
                }.op),
                .f32_mul => try self.binopF32(struct {
                    fn op(a: f32, b: f32) f32 {
                        return a * b;
                    }
                }.op),
                .f32_div => try self.binopF32(struct {
                    fn op(a: f32, b: f32) f32 {
                        return a / b;
                    }
                }.op),

                // f64 arithmetic (subset)
                .f64_add => try self.binopF64(struct {
                    fn op(a: f64, b: f64) f64 {
                        return a + b;
                    }
                }.op),
                .f64_sub => try self.binopF64(struct {
                    fn op(a: f64, b: f64) f64 {
                        return a - b;
                    }
                }.op),
                .f64_mul => try self.binopF64(struct {
                    fn op(a: f64, b: f64) f64 {
                        return a * b;
                    }
                }.op),
                .f64_div => try self.binopF64(struct {
                    fn op(a: f64, b: f64) f64 {
                        return a / b;
                    }
                }.op),

                // Conversions (subset)
                .i32_wrap_i64 => {
                    const v = try self.stack.popI64();
                    try self.stack.pushI32(@truncate(v));
                },
                .i64_extend_i32_s => {
                    const v = try self.stack.popI32();
                    try self.stack.pushI64(v);
                },
                .i64_extend_i32_u => {
                    const v = try self.stack.popI32();
                    try self.stack.pushI64(@as(i64, @as(u32, @bitCast(v))));
                },

                else => {
                    // Unimplemented opcode
                    return error.UnimplementedOpcode;
                },
            }
        }
    }

    fn binopI32(self: *Interpreter, op: fn (i32, i32) i32) !void {
        const b = try self.stack.popI32();
        const a = try self.stack.popI32();
        try self.stack.pushI32(op(a, b));
    }

    fn binopI64(self: *Interpreter, op: fn (i64, i64) i64) !void {
        const b = try self.stack.popI64();
        const a = try self.stack.popI64();
        try self.stack.pushI64(op(a, b));
    }

    fn binopF32(self: *Interpreter, op: fn (f32, f32) f32) !void {
        const b = try self.stack.popF32();
        const a = try self.stack.popF32();
        try self.stack.pushF32(op(a, b));
    }

    fn binopF64(self: *Interpreter, op: fn (f64, f64) f64) !void {
        const b = try self.stack.popF64();
        const a = try self.stack.popF64();
        try self.stack.pushF64(op(a, b));
    }
};

// Tests are in test_integration.zig since they need full modules
test "interpreter init" {
    // Just verify the struct compiles
    _ = Interpreter;
}
