// WASM interpreter - Full implementation

const std = @import("std");
const binary = @import("../binary/mod.zig");
const stack_mod = @import("stack.zig");
const memory_mod = @import("memory.zig");
const store_mod = @import("store.zig");
const table_mod = @import("table.zig");

const Stack = stack_mod.Stack;
const Value = stack_mod.Value;
const Frame = stack_mod.Frame;
const Label = stack_mod.Label;
const Memory = memory_mod.Memory;
const Table = table_mod.Table;
const Opcode = binary.Opcode;
const Reader = binary.Reader;

pub const Interpreter = struct {
    stack: Stack,
    memory: ?*Memory,
    globals: []Value,
    tables: []Table,
    module: *binary.Module,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, module: *binary.Module) Interpreter {
        return Interpreter{
            .stack = Stack.init(allocator),
            .memory = null,
            .globals = &[_]Value{},
            .tables = &[_]Table{},
            .module = module,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Interpreter) void {
        self.stack.deinit();
        if (self.globals.len > 0) {
            self.allocator.free(self.globals);
        }
    }

    pub fn setMemory(self: *Interpreter, mem: *Memory) void {
        self.memory = mem;
    }

    pub fn setTables(self: *Interpreter, tables: []Table) void {
        self.tables = tables;
    }

    pub fn initGlobals(self: *Interpreter, globals: []const binary.Module.Global) !void {
        if (globals.len == 0) return;
        self.globals = try self.allocator.alloc(Value, globals.len);
        for (globals, 0..) |g, i| {
            // Evaluate init expression for this global
            self.globals[i] = self.evaluateInitExpr(g.init) catch
                Value.fromValType(g.global_type.val_type);
        }
    }

    /// Evaluate a constant init expression and return the resulting Value
    /// Handles: i32.const, i64.const, f32.const, f64.const, global.get, end
    fn evaluateInitExpr(self: *Interpreter, expr: []const u8) ExecuteError!Value {
        var reader = Reader.init(expr);

        while (!reader.atEnd()) {
            const opcode = reader.readByte() catch return error.UnexpectedEof;

            switch (opcode) {
                0x41 => { // i32.const
                    const val = reader.readI32Leb128() catch return error.LEB128Overflow;
                    return Value{ .i32 = val };
                },
                0x42 => { // i64.const
                    const val = reader.readI64Leb128() catch return error.LEB128Overflow;
                    return Value{ .i64 = val };
                },
                0x43 => { // f32.const
                    const val = reader.readF32() catch return error.UnexpectedEof;
                    return Value{ .f32 = val };
                },
                0x44 => { // f64.const
                    const val = reader.readF64() catch return error.UnexpectedEof;
                    return Value{ .f64 = val };
                },
                0x23 => { // global.get
                    const idx = reader.readU32Leb128() catch return error.LEB128Overflow;
                    if (idx >= self.globals.len) return error.InvalidGlobalIndex;
                    return self.globals[idx];
                },
                0x0B => { // end
                    // Should have returned a value before reaching end
                    return error.InvalidInitExpression;
                },
                else => return error.InvalidInitExpression,
            }
        }

        return error.UnexpectedEof;
    }

    /// Execute a function by index
    pub fn call(self: *Interpreter, func_idx: u32, args: []const Value) ![]Value {
        const type_idx = self.module.funcs[func_idx];
        const func_type = &self.module.types[type_idx];

        if (args.len != func_type.params.len) return error.ArgumentCountMismatch;

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

        // Push implicit function label
        try self.stack.pushLabel(Label{
            .arity = @intCast(func_type.results.len),
            .target = code.body.len,
            .is_loop = false,
            .stack_height = self.stack.valueStackHeight(),
        });

        // Execute
        _ = try self.executeCode(code.body);

        // Pop function label
        _ = self.stack.popLabel() catch {};

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

    /// Error types for execution
    pub const ExecuteError = error{
        Unreachable,
        StackUnderflow,
        TypeMismatch,
        ArgumentCountMismatch,
        NoActiveFrame,
        LabelStackUnderflow,
        FrameStackUnderflow,
        InvalidLabelDepth,
        OutOfMemory,
        NoMemory,
        OutOfBoundsMemoryAccess,
        DivisionByZero,
        IntegerOverflow,
        InvalidConversion,
        UnimplementedOpcode,
        InvalidGlobalIndex,
        UnexpectedEof,
        InvalidBlockType,
        LEB128Overflow,
        InvalidInitExpression,
        UndefinedElement,
        IndirectCallTypeMismatch,
        TableOutOfBounds,
    };

    /// Execute code, returns branch depth or null if completed normally
    fn executeCode(self: *Interpreter, code: []const u8) ExecuteError!?u32 {
        var reader = Reader.init(code);

        while (!reader.atEnd()) {
            const instr = try binary.instructions.decode(&reader);

            const branch_result = try self.executeInstruction(instr, &reader);
            if (branch_result) |depth| {
                return depth;
            }
        }
        return null;
    }

    fn executeInstruction(self: *Interpreter, instr: binary.instructions.Instruction, reader: *Reader) ExecuteError!?u32 {
        switch (instr.opcode) {
            // ========== Control Flow ==========
            .@"unreachable" => return error.Unreachable,
            .nop => {},
            .end => return null,

            .block => {
                const block_type = instr.immediate.block_type;
                const arity = self.blockArity(block_type, false);
                const block_start = reader.position;

                try self.stack.pushLabel(Label{
                    .arity = arity,
                    .target = 0, // Will find end
                    .is_loop = false,
                    .stack_height = self.stack.valueStackHeight(),
                });

                // Find and execute block body
                const body = try self.findBlockBody(reader);
                const branch = try self.executeCode(body);

                _ = self.stack.popLabel() catch {};
                _ = block_start;

                if (branch) |d| {
                    if (d > 0) return d - 1;
                }
            },

            .loop => {
                const block_type = instr.immediate.block_type;
                const arity = self.blockArity(block_type, true);

                try self.stack.pushLabel(Label{
                    .arity = arity,
                    .target = 0,
                    .is_loop = true,
                    .stack_height = self.stack.valueStackHeight(),
                });

                const body = try self.findBlockBody(reader);

                while (true) {
                    const branch = try self.executeCode(body);
                    if (branch) |d| {
                        if (d == 0) {
                            // Branch to loop start - continue
                            continue;
                        } else {
                            _ = self.stack.popLabel() catch {};
                            return d - 1;
                        }
                    }
                    break;
                }

                _ = self.stack.popLabel() catch {};
            },

            .@"if" => {
                const cond = try self.stack.popI32();
                const block_type = instr.immediate.block_type;
                const arity = self.blockArity(block_type, false);

                try self.stack.pushLabel(Label{
                    .arity = arity,
                    .target = 0,
                    .is_loop = false,
                    .stack_height = self.stack.valueStackHeight(),
                });

                const if_body = try self.findIfBody(reader);

                if (cond != 0) {
                    const branch = try self.executeCode(if_body.then_body);
                    _ = self.stack.popLabel() catch {};
                    if (branch) |d| {
                        if (d > 0) return d - 1;
                    }
                } else if (if_body.else_body) |else_body| {
                    const branch = try self.executeCode(else_body);
                    _ = self.stack.popLabel() catch {};
                    if (branch) |d| {
                        if (d > 0) return d - 1;
                    }
                } else {
                    _ = self.stack.popLabel() catch {};
                }
            },

            .br => {
                const depth = instr.immediate.label_idx;
                try self.branchTo(depth);
                return depth;
            },

            .br_if => {
                const cond = try self.stack.popI32();
                if (cond != 0) {
                    const depth = instr.immediate.label_idx;
                    try self.branchTo(depth);
                    return depth;
                }
            },

            .br_table => {
                const idx = @as(u32, @bitCast(try self.stack.popI32()));
                const table = instr.immediate.br_table;
                const depth = if (idx < table.labels.len)
                    table.labels[idx]
                else
                    table.default;
                try self.branchTo(depth);
                return depth;
            },

            .@"return" => {
                // Return from function - branch to outermost label
                const frame = try self.stack.currentFrame();
                _ = frame;
                return 0xFFFFFFFF; // Special value for return
            },

            .call => {
                const func_idx = instr.immediate.func_idx;
                try self.callFunction(func_idx);
            },

            .call_indirect => {
                const type_idx = instr.immediate.call_indirect.type_idx;
                const tbl_idx = instr.immediate.call_indirect.table_idx;

                // Pop the element index from the stack
                const elem_idx = @as(u32, @bitCast(try self.stack.popI32()));

                // Get the table
                if (tbl_idx >= self.tables.len) return error.TableOutOfBounds;
                const table = &self.tables[tbl_idx];

                // Look up the function reference in the table
                const func_ref = table.get(elem_idx) catch return error.TableOutOfBounds;

                // Check if the table entry is null (undefined element)
                const func_idx = func_ref orelse return error.UndefinedElement;

                // Validate the function exists
                if (func_idx >= self.module.funcs.len) return error.UndefinedElement;

                // Type check: verify the function's type matches the expected type
                const actual_type_idx = self.module.funcs[func_idx];
                if (actual_type_idx != type_idx) {
                    // Compare the actual type signatures
                    if (type_idx >= self.module.types.len or actual_type_idx >= self.module.types.len) {
                        return error.IndirectCallTypeMismatch;
                    }
                    const expected_type = &self.module.types[type_idx];
                    const actual_type = &self.module.types[actual_type_idx];

                    // Check params match
                    if (expected_type.params.len != actual_type.params.len) {
                        return error.IndirectCallTypeMismatch;
                    }
                    for (expected_type.params, actual_type.params) |e, a| {
                        if (e != a) return error.IndirectCallTypeMismatch;
                    }

                    // Check results match
                    if (expected_type.results.len != actual_type.results.len) {
                        return error.IndirectCallTypeMismatch;
                    }
                    for (expected_type.results, actual_type.results) |e, a| {
                        if (e != a) return error.IndirectCallTypeMismatch;
                    }
                }

                // Call the function
                try self.callFunction(func_idx);
            },

            // ========== Parametric ==========
            .drop => _ = try self.stack.pop(),
            .select => {
                const cond = try self.stack.popI32();
                const val2 = try self.stack.pop();
                const val1 = try self.stack.pop();
                try self.stack.push(if (cond != 0) val1 else val2);
            },

            // ========== Variable ==========
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
            .global_get => {
                const idx = instr.immediate.global_idx;
                if (idx >= self.globals.len) return error.InvalidGlobalIndex;
                try self.stack.push(self.globals[idx]);
            },
            .global_set => {
                const idx = instr.immediate.global_idx;
                if (idx >= self.globals.len) return error.InvalidGlobalIndex;
                self.globals[idx] = try self.stack.pop();
            },

            // ========== Memory ==========
            .i32_load => try self.memLoad(i32, 4, instr.immediate.memarg),
            .i64_load => try self.memLoad(i64, 8, instr.immediate.memarg),
            .f32_load => try self.memLoadF32(instr.immediate.memarg),
            .f64_load => try self.memLoadF64(instr.immediate.memarg),
            .i32_load8_s => try self.memLoadExtend(i32, i8, 1, instr.immediate.memarg),
            .i32_load8_u => try self.memLoadExtend(i32, u8, 1, instr.immediate.memarg),
            .i32_load16_s => try self.memLoadExtend(i32, i16, 2, instr.immediate.memarg),
            .i32_load16_u => try self.memLoadExtend(i32, u16, 2, instr.immediate.memarg),
            .i64_load8_s => try self.memLoadExtend(i64, i8, 1, instr.immediate.memarg),
            .i64_load8_u => try self.memLoadExtend(i64, u8, 1, instr.immediate.memarg),
            .i64_load16_s => try self.memLoadExtend(i64, i16, 2, instr.immediate.memarg),
            .i64_load16_u => try self.memLoadExtend(i64, u16, 2, instr.immediate.memarg),
            .i64_load32_s => try self.memLoadExtend(i64, i32, 4, instr.immediate.memarg),
            .i64_load32_u => try self.memLoadExtend(i64, u32, 4, instr.immediate.memarg),

            .i32_store => try self.memStore(i32, 4, instr.immediate.memarg),
            .i64_store => try self.memStore(i64, 8, instr.immediate.memarg),
            .f32_store => try self.memStoreF32(instr.immediate.memarg),
            .f64_store => try self.memStoreF64(instr.immediate.memarg),
            .i32_store8 => try self.memStoreTrunc(i32, u8, 1, instr.immediate.memarg),
            .i32_store16 => try self.memStoreTrunc(i32, u16, 2, instr.immediate.memarg),
            .i64_store8 => try self.memStoreTrunc(i64, u8, 1, instr.immediate.memarg),
            .i64_store16 => try self.memStoreTrunc(i64, u16, 2, instr.immediate.memarg),
            .i64_store32 => try self.memStoreTrunc(i64, u32, 4, instr.immediate.memarg),

            .memory_size => {
                const mem = self.memory orelse return error.NoMemory;
                try self.stack.pushI32(@intCast(mem.pageCount()));
            },
            .memory_grow => {
                const mem = self.memory orelse return error.NoMemory;
                const delta = @as(u32, @bitCast(try self.stack.popI32()));
                const result = mem.grow(delta);
                try self.stack.pushI32(result);
            },

            // ========== Numeric Constants ==========
            .i32_const => try self.stack.pushI32(instr.immediate.i32),
            .i64_const => try self.stack.pushI64(instr.immediate.i64),
            .f32_const => try self.stack.pushF32(instr.immediate.f32),
            .f64_const => try self.stack.pushF64(instr.immediate.f64),

            // ========== i32 Comparison ==========
            .i32_eqz => {
                const v = try self.stack.popI32();
                try self.stack.pushI32(if (v == 0) 1 else 0);
            },
            .i32_eq => try self.cmpI32(struct { fn f(a: i32, b: i32) bool { return a == b; } }.f),
            .i32_ne => try self.cmpI32(struct { fn f(a: i32, b: i32) bool { return a != b; } }.f),
            .i32_lt_s => try self.cmpI32(struct { fn f(a: i32, b: i32) bool { return a < b; } }.f),
            .i32_lt_u => try self.cmpU32(struct { fn f(a: u32, b: u32) bool { return a < b; } }.f),
            .i32_gt_s => try self.cmpI32(struct { fn f(a: i32, b: i32) bool { return a > b; } }.f),
            .i32_gt_u => try self.cmpU32(struct { fn f(a: u32, b: u32) bool { return a > b; } }.f),
            .i32_le_s => try self.cmpI32(struct { fn f(a: i32, b: i32) bool { return a <= b; } }.f),
            .i32_le_u => try self.cmpU32(struct { fn f(a: u32, b: u32) bool { return a <= b; } }.f),
            .i32_ge_s => try self.cmpI32(struct { fn f(a: i32, b: i32) bool { return a >= b; } }.f),
            .i32_ge_u => try self.cmpU32(struct { fn f(a: u32, b: u32) bool { return a >= b; } }.f),

            // ========== i64 Comparison ==========
            .i64_eqz => {
                const v = try self.stack.popI64();
                try self.stack.pushI32(if (v == 0) 1 else 0);
            },
            .i64_eq => try self.cmpI64(struct { fn f(a: i64, b: i64) bool { return a == b; } }.f),
            .i64_ne => try self.cmpI64(struct { fn f(a: i64, b: i64) bool { return a != b; } }.f),
            .i64_lt_s => try self.cmpI64(struct { fn f(a: i64, b: i64) bool { return a < b; } }.f),
            .i64_lt_u => try self.cmpU64(struct { fn f(a: u64, b: u64) bool { return a < b; } }.f),
            .i64_gt_s => try self.cmpI64(struct { fn f(a: i64, b: i64) bool { return a > b; } }.f),
            .i64_gt_u => try self.cmpU64(struct { fn f(a: u64, b: u64) bool { return a > b; } }.f),
            .i64_le_s => try self.cmpI64(struct { fn f(a: i64, b: i64) bool { return a <= b; } }.f),
            .i64_le_u => try self.cmpU64(struct { fn f(a: u64, b: u64) bool { return a <= b; } }.f),
            .i64_ge_s => try self.cmpI64(struct { fn f(a: i64, b: i64) bool { return a >= b; } }.f),
            .i64_ge_u => try self.cmpU64(struct { fn f(a: u64, b: u64) bool { return a >= b; } }.f),

            // ========== f32 Comparison ==========
            .f32_eq => try self.cmpF32(struct { fn f(a: f32, b: f32) bool { return a == b; } }.f),
            .f32_ne => try self.cmpF32(struct { fn f(a: f32, b: f32) bool { return a != b; } }.f),
            .f32_lt => try self.cmpF32(struct { fn f(a: f32, b: f32) bool { return a < b; } }.f),
            .f32_gt => try self.cmpF32(struct { fn f(a: f32, b: f32) bool { return a > b; } }.f),
            .f32_le => try self.cmpF32(struct { fn f(a: f32, b: f32) bool { return a <= b; } }.f),
            .f32_ge => try self.cmpF32(struct { fn f(a: f32, b: f32) bool { return a >= b; } }.f),

            // ========== f64 Comparison ==========
            .f64_eq => try self.cmpF64(struct { fn f(a: f64, b: f64) bool { return a == b; } }.f),
            .f64_ne => try self.cmpF64(struct { fn f(a: f64, b: f64) bool { return a != b; } }.f),
            .f64_lt => try self.cmpF64(struct { fn f(a: f64, b: f64) bool { return a < b; } }.f),
            .f64_gt => try self.cmpF64(struct { fn f(a: f64, b: f64) bool { return a > b; } }.f),
            .f64_le => try self.cmpF64(struct { fn f(a: f64, b: f64) bool { return a <= b; } }.f),
            .f64_ge => try self.cmpF64(struct { fn f(a: f64, b: f64) bool { return a >= b; } }.f),

            // ========== i32 Arithmetic ==========
            .i32_clz => {
                const v = try self.stack.popI32();
                try self.stack.pushI32(@clz(@as(u32, @bitCast(v))));
            },
            .i32_ctz => {
                const v = try self.stack.popI32();
                try self.stack.pushI32(@ctz(@as(u32, @bitCast(v))));
            },
            .i32_popcnt => {
                const v = try self.stack.popI32();
                try self.stack.pushI32(@popCount(@as(u32, @bitCast(v))));
            },
            .i32_add => try self.binopI32(struct { fn f(a: i32, b: i32) i32 { return a +% b; } }.f),
            .i32_sub => try self.binopI32(struct { fn f(a: i32, b: i32) i32 { return a -% b; } }.f),
            .i32_mul => try self.binopI32(struct { fn f(a: i32, b: i32) i32 { return a *% b; } }.f),
            .i32_div_s => {
                const b = try self.stack.popI32();
                const a = try self.stack.popI32();
                if (b == 0) return error.DivisionByZero;
                if (a == std.math.minInt(i32) and b == -1) return error.IntegerOverflow;
                try self.stack.pushI32(@divTrunc(a, b));
            },
            .i32_div_u => {
                const b = @as(u32, @bitCast(try self.stack.popI32()));
                const a = @as(u32, @bitCast(try self.stack.popI32()));
                if (b == 0) return error.DivisionByZero;
                try self.stack.pushI32(@bitCast(a / b));
            },
            .i32_rem_s => {
                const b = try self.stack.popI32();
                const a = try self.stack.popI32();
                if (b == 0) return error.DivisionByZero;
                try self.stack.pushI32(@rem(a, b));
            },
            .i32_rem_u => {
                const b = @as(u32, @bitCast(try self.stack.popI32()));
                const a = @as(u32, @bitCast(try self.stack.popI32()));
                if (b == 0) return error.DivisionByZero;
                try self.stack.pushI32(@bitCast(a % b));
            },
            .i32_and => try self.binopI32(struct { fn f(a: i32, b: i32) i32 { return a & b; } }.f),
            .i32_or => try self.binopI32(struct { fn f(a: i32, b: i32) i32 { return a | b; } }.f),
            .i32_xor => try self.binopI32(struct { fn f(a: i32, b: i32) i32 { return a ^ b; } }.f),
            .i32_shl => {
                const b = @as(u5, @truncate(@as(u32, @bitCast(try self.stack.popI32()))));
                const a = try self.stack.popI32();
                try self.stack.pushI32(a << b);
            },
            .i32_shr_s => {
                const b = @as(u5, @truncate(@as(u32, @bitCast(try self.stack.popI32()))));
                const a = try self.stack.popI32();
                try self.stack.pushI32(a >> b);
            },
            .i32_shr_u => {
                const b = @as(u5, @truncate(@as(u32, @bitCast(try self.stack.popI32()))));
                const a = @as(u32, @bitCast(try self.stack.popI32()));
                try self.stack.pushI32(@bitCast(a >> b));
            },
            .i32_rotl => {
                const b = @as(u5, @truncate(@as(u32, @bitCast(try self.stack.popI32()))));
                const a = @as(u32, @bitCast(try self.stack.popI32()));
                try self.stack.pushI32(@bitCast(std.math.rotl(u32, a, b)));
            },
            .i32_rotr => {
                const b = @as(u5, @truncate(@as(u32, @bitCast(try self.stack.popI32()))));
                const a = @as(u32, @bitCast(try self.stack.popI32()));
                try self.stack.pushI32(@bitCast(std.math.rotr(u32, a, b)));
            },

            // ========== i64 Arithmetic ==========
            .i64_clz => {
                const v = try self.stack.popI64();
                try self.stack.pushI64(@clz(@as(u64, @bitCast(v))));
            },
            .i64_ctz => {
                const v = try self.stack.popI64();
                try self.stack.pushI64(@ctz(@as(u64, @bitCast(v))));
            },
            .i64_popcnt => {
                const v = try self.stack.popI64();
                try self.stack.pushI64(@popCount(@as(u64, @bitCast(v))));
            },
            .i64_add => try self.binopI64(struct { fn f(a: i64, b: i64) i64 { return a +% b; } }.f),
            .i64_sub => try self.binopI64(struct { fn f(a: i64, b: i64) i64 { return a -% b; } }.f),
            .i64_mul => try self.binopI64(struct { fn f(a: i64, b: i64) i64 { return a *% b; } }.f),
            .i64_div_s => {
                const b = try self.stack.popI64();
                const a = try self.stack.popI64();
                if (b == 0) return error.DivisionByZero;
                if (a == std.math.minInt(i64) and b == -1) return error.IntegerOverflow;
                try self.stack.pushI64(@divTrunc(a, b));
            },
            .i64_div_u => {
                const b = @as(u64, @bitCast(try self.stack.popI64()));
                const a = @as(u64, @bitCast(try self.stack.popI64()));
                if (b == 0) return error.DivisionByZero;
                try self.stack.pushI64(@bitCast(a / b));
            },
            .i64_rem_s => {
                const b = try self.stack.popI64();
                const a = try self.stack.popI64();
                if (b == 0) return error.DivisionByZero;
                try self.stack.pushI64(@rem(a, b));
            },
            .i64_rem_u => {
                const b = @as(u64, @bitCast(try self.stack.popI64()));
                const a = @as(u64, @bitCast(try self.stack.popI64()));
                if (b == 0) return error.DivisionByZero;
                try self.stack.pushI64(@bitCast(a % b));
            },
            .i64_and => try self.binopI64(struct { fn f(a: i64, b: i64) i64 { return a & b; } }.f),
            .i64_or => try self.binopI64(struct { fn f(a: i64, b: i64) i64 { return a | b; } }.f),
            .i64_xor => try self.binopI64(struct { fn f(a: i64, b: i64) i64 { return a ^ b; } }.f),
            .i64_shl => {
                const b = @as(u6, @truncate(@as(u64, @bitCast(try self.stack.popI64()))));
                const a = try self.stack.popI64();
                try self.stack.pushI64(a << b);
            },
            .i64_shr_s => {
                const b = @as(u6, @truncate(@as(u64, @bitCast(try self.stack.popI64()))));
                const a = try self.stack.popI64();
                try self.stack.pushI64(a >> b);
            },
            .i64_shr_u => {
                const b = @as(u6, @truncate(@as(u64, @bitCast(try self.stack.popI64()))));
                const a = @as(u64, @bitCast(try self.stack.popI64()));
                try self.stack.pushI64(@bitCast(a >> b));
            },
            .i64_rotl => {
                const b = @as(u6, @truncate(@as(u64, @bitCast(try self.stack.popI64()))));
                const a = @as(u64, @bitCast(try self.stack.popI64()));
                try self.stack.pushI64(@bitCast(std.math.rotl(u64, a, b)));
            },
            .i64_rotr => {
                const b = @as(u6, @truncate(@as(u64, @bitCast(try self.stack.popI64()))));
                const a = @as(u64, @bitCast(try self.stack.popI64()));
                try self.stack.pushI64(@bitCast(std.math.rotr(u64, a, b)));
            },

            // ========== f32 Arithmetic ==========
            .f32_abs => { const v = try self.stack.popF32(); try self.stack.pushF32(@abs(v)); },
            .f32_neg => { const v = try self.stack.popF32(); try self.stack.pushF32(-v); },
            .f32_ceil => { const v = try self.stack.popF32(); try self.stack.pushF32(@ceil(v)); },
            .f32_floor => { const v = try self.stack.popF32(); try self.stack.pushF32(@floor(v)); },
            .f32_trunc => { const v = try self.stack.popF32(); try self.stack.pushF32(@trunc(v)); },
            .f32_nearest => { const v = try self.stack.popF32(); try self.stack.pushF32(@round(v)); },
            .f32_sqrt => { const v = try self.stack.popF32(); try self.stack.pushF32(@sqrt(v)); },
            .f32_add => try self.binopF32(struct { fn f(a: f32, b: f32) f32 { return a + b; } }.f),
            .f32_sub => try self.binopF32(struct { fn f(a: f32, b: f32) f32 { return a - b; } }.f),
            .f32_mul => try self.binopF32(struct { fn f(a: f32, b: f32) f32 { return a * b; } }.f),
            .f32_div => try self.binopF32(struct { fn f(a: f32, b: f32) f32 { return a / b; } }.f),
            .f32_min => try self.binopF32(struct { fn f(a: f32, b: f32) f32 { return @min(a, b); } }.f),
            .f32_max => try self.binopF32(struct { fn f(a: f32, b: f32) f32 { return @max(a, b); } }.f),
            .f32_copysign => {
                const b = try self.stack.popF32();
                const a = try self.stack.popF32();
                try self.stack.pushF32(std.math.copysign(a, b));
            },

            // ========== f64 Arithmetic ==========
            .f64_abs => { const v = try self.stack.popF64(); try self.stack.pushF64(@abs(v)); },
            .f64_neg => { const v = try self.stack.popF64(); try self.stack.pushF64(-v); },
            .f64_ceil => { const v = try self.stack.popF64(); try self.stack.pushF64(@ceil(v)); },
            .f64_floor => { const v = try self.stack.popF64(); try self.stack.pushF64(@floor(v)); },
            .f64_trunc => { const v = try self.stack.popF64(); try self.stack.pushF64(@trunc(v)); },
            .f64_nearest => { const v = try self.stack.popF64(); try self.stack.pushF64(@round(v)); },
            .f64_sqrt => { const v = try self.stack.popF64(); try self.stack.pushF64(@sqrt(v)); },
            .f64_add => try self.binopF64(struct { fn f(a: f64, b: f64) f64 { return a + b; } }.f),
            .f64_sub => try self.binopF64(struct { fn f(a: f64, b: f64) f64 { return a - b; } }.f),
            .f64_mul => try self.binopF64(struct { fn f(a: f64, b: f64) f64 { return a * b; } }.f),
            .f64_div => try self.binopF64(struct { fn f(a: f64, b: f64) f64 { return a / b; } }.f),
            .f64_min => try self.binopF64(struct { fn f(a: f64, b: f64) f64 { return @min(a, b); } }.f),
            .f64_max => try self.binopF64(struct { fn f(a: f64, b: f64) f64 { return @max(a, b); } }.f),
            .f64_copysign => {
                const b = try self.stack.popF64();
                const a = try self.stack.popF64();
                try self.stack.pushF64(std.math.copysign(a, b));
            },

            // ========== Conversions ==========
            .i32_wrap_i64 => {
                const v = try self.stack.popI64();
                try self.stack.pushI32(@truncate(v));
            },
            .i32_trunc_f32_s => {
                const v = try self.stack.popF32();
                if (std.math.isNan(v) or std.math.isInf(v)) return error.InvalidConversion;
                try self.stack.pushI32(@intFromFloat(v));
            },
            .i32_trunc_f32_u => {
                const v = try self.stack.popF32();
                if (std.math.isNan(v) or std.math.isInf(v) or v < 0) return error.InvalidConversion;
                try self.stack.pushI32(@bitCast(@as(u32, @intFromFloat(v))));
            },
            .i32_trunc_f64_s => {
                const v = try self.stack.popF64();
                if (std.math.isNan(v) or std.math.isInf(v)) return error.InvalidConversion;
                try self.stack.pushI32(@intFromFloat(v));
            },
            .i32_trunc_f64_u => {
                const v = try self.stack.popF64();
                if (std.math.isNan(v) or std.math.isInf(v) or v < 0) return error.InvalidConversion;
                try self.stack.pushI32(@bitCast(@as(u32, @intFromFloat(v))));
            },
            .i64_extend_i32_s => {
                const v = try self.stack.popI32();
                try self.stack.pushI64(v);
            },
            .i64_extend_i32_u => {
                const v = try self.stack.popI32();
                try self.stack.pushI64(@as(u32, @bitCast(v)));
            },
            .i64_trunc_f32_s => {
                const v = try self.stack.popF32();
                if (std.math.isNan(v) or std.math.isInf(v)) return error.InvalidConversion;
                try self.stack.pushI64(@intFromFloat(v));
            },
            .i64_trunc_f32_u => {
                const v = try self.stack.popF32();
                if (std.math.isNan(v) or std.math.isInf(v) or v < 0) return error.InvalidConversion;
                try self.stack.pushI64(@bitCast(@as(u64, @intFromFloat(v))));
            },
            .i64_trunc_f64_s => {
                const v = try self.stack.popF64();
                if (std.math.isNan(v) or std.math.isInf(v)) return error.InvalidConversion;
                try self.stack.pushI64(@intFromFloat(v));
            },
            .i64_trunc_f64_u => {
                const v = try self.stack.popF64();
                if (std.math.isNan(v) or std.math.isInf(v) or v < 0) return error.InvalidConversion;
                try self.stack.pushI64(@bitCast(@as(u64, @intFromFloat(v))));
            },
            .f32_convert_i32_s => {
                const v = try self.stack.popI32();
                try self.stack.pushF32(@floatFromInt(v));
            },
            .f32_convert_i32_u => {
                const v = @as(u32, @bitCast(try self.stack.popI32()));
                try self.stack.pushF32(@floatFromInt(v));
            },
            .f32_convert_i64_s => {
                const v = try self.stack.popI64();
                try self.stack.pushF32(@floatFromInt(v));
            },
            .f32_convert_i64_u => {
                const v = @as(u64, @bitCast(try self.stack.popI64()));
                try self.stack.pushF32(@floatFromInt(v));
            },
            .f32_demote_f64 => {
                const v = try self.stack.popF64();
                try self.stack.pushF32(@floatCast(v));
            },
            .f64_convert_i32_s => {
                const v = try self.stack.popI32();
                try self.stack.pushF64(@floatFromInt(v));
            },
            .f64_convert_i32_u => {
                const v = @as(u32, @bitCast(try self.stack.popI32()));
                try self.stack.pushF64(@floatFromInt(v));
            },
            .f64_convert_i64_s => {
                const v = try self.stack.popI64();
                try self.stack.pushF64(@floatFromInt(v));
            },
            .f64_convert_i64_u => {
                const v = @as(u64, @bitCast(try self.stack.popI64()));
                try self.stack.pushF64(@floatFromInt(v));
            },
            .f64_promote_f32 => {
                const v = try self.stack.popF32();
                try self.stack.pushF64(v);
            },
            .i32_reinterpret_f32 => {
                const v = try self.stack.popF32();
                try self.stack.pushI32(@bitCast(v));
            },
            .i64_reinterpret_f64 => {
                const v = try self.stack.popF64();
                try self.stack.pushI64(@bitCast(v));
            },
            .f32_reinterpret_i32 => {
                const v = try self.stack.popI32();
                try self.stack.pushF32(@bitCast(v));
            },
            .f64_reinterpret_i64 => {
                const v = try self.stack.popI64();
                try self.stack.pushF64(@bitCast(v));
            },

            // ========== Sign Extension ==========
            .i32_extend8_s => {
                const v = try self.stack.popI32();
                try self.stack.pushI32(@as(i8, @truncate(v)));
            },
            .i32_extend16_s => {
                const v = try self.stack.popI32();
                try self.stack.pushI32(@as(i16, @truncate(v)));
            },
            .i64_extend8_s => {
                const v = try self.stack.popI64();
                try self.stack.pushI64(@as(i8, @truncate(v)));
            },
            .i64_extend16_s => {
                const v = try self.stack.popI64();
                try self.stack.pushI64(@as(i16, @truncate(v)));
            },
            .i64_extend32_s => {
                const v = try self.stack.popI64();
                try self.stack.pushI64(@as(i32, @truncate(v)));
            },

            else => return error.UnimplementedOpcode,
        }
        return null;
    }

    // ========== Helper Functions ==========

    fn blockArity(self: *Interpreter, block_type: binary.types.BlockType, is_loop: bool) u32 {
        _ = is_loop;
        return switch (block_type) {
            .empty => 0,
            .val_type => 1,
            .type_index => |idx| blk: {
                if (idx < self.module.types.len) {
                    break :blk @intCast(self.module.types[idx].results.len);
                }
                break :blk 0;
            },
        };
    }

    fn findBlockBody(self: *Interpreter, reader: *Reader) ![]const u8 {
        _ = self;
        const start = reader.position;
        var depth: u32 = 1;

        while (!reader.atEnd() and depth > 0) {
            const byte = try reader.readByte();
            switch (byte) {
                0x02, 0x03, 0x04 => depth += 1, // block, loop, if
                0x0B => depth -= 1, // end
                else => {},
            }
        }

        return reader.data[start .. reader.position - 1];
    }

    const IfBody = struct {
        then_body: []const u8,
        else_body: ?[]const u8,
    };

    fn findIfBody(self: *Interpreter, reader: *Reader) !IfBody {
        _ = self;
        const start = reader.position;
        var depth: u32 = 1;
        var else_pos: ?usize = null;

        while (!reader.atEnd() and depth > 0) {
            const byte = try reader.readByte();
            switch (byte) {
                0x02, 0x03, 0x04 => depth += 1,
                0x05 => if (depth == 1) { else_pos = reader.position; }, // else
                0x0B => depth -= 1,
                else => {},
            }
        }

        if (else_pos) |ep| {
            return IfBody{
                .then_body = reader.data[start .. ep - 1],
                .else_body = reader.data[ep .. reader.position - 1],
            };
        } else {
            return IfBody{
                .then_body = reader.data[start .. reader.position - 1],
                .else_body = null,
            };
        }
    }

    fn branchTo(self: *Interpreter, depth: u32) !void {
        const label = try self.stack.getLabel(depth);
        // Save result values
        var results: [16]Value = undefined;
        var i: u32 = 0;
        while (i < label.arity) : (i += 1) {
            results[i] = try self.stack.pop();
        }
        // Truncate stack
        self.stack.truncateValues(label.stack_height);
        // Restore results
        while (i > 0) {
            i -= 1;
            try self.stack.push(results[i]);
        }
    }

    fn callFunction(self: *Interpreter, func_idx: u32) !void {
        const type_idx = self.module.funcs[func_idx];
        const func_type = &self.module.types[type_idx];

        // Pop arguments
        var args: [16]Value = undefined;
        var i: usize = func_type.params.len;
        while (i > 0) {
            i -= 1;
            args[i] = try self.stack.pop();
        }

        // Call
        const results = try self.call(func_idx, args[0..func_type.params.len]);
        defer self.allocator.free(results);

        // Push results
        for (results) |r| {
            try self.stack.push(r);
        }
    }

    // Memory helpers
    fn memLoad(self: *Interpreter, comptime T: type, comptime size: usize, memarg: binary.instructions.MemArg) !void {
        const mem = self.memory orelse return error.NoMemory;
        const base = @as(u32, @bitCast(try self.stack.popI32()));
        const addr = base +% memarg.offset;
        const bytes = mem.read(addr, size) orelse return error.OutOfBoundsMemoryAccess;
        const value = std.mem.readInt(T, bytes[0..size], .little);
        if (T == i32) {
            try self.stack.pushI32(value);
        } else {
            try self.stack.pushI64(value);
        }
    }

    fn memLoadF32(self: *Interpreter, memarg: binary.instructions.MemArg) !void {
        const mem = self.memory orelse return error.NoMemory;
        const base = @as(u32, @bitCast(try self.stack.popI32()));
        const addr = base +% memarg.offset;
        const bytes = mem.read(addr, 4) orelse return error.OutOfBoundsMemoryAccess;
        try self.stack.pushF32(@bitCast(std.mem.readInt(u32, bytes[0..4], .little)));
    }

    fn memLoadF64(self: *Interpreter, memarg: binary.instructions.MemArg) !void {
        const mem = self.memory orelse return error.NoMemory;
        const base = @as(u32, @bitCast(try self.stack.popI32()));
        const addr = base +% memarg.offset;
        const bytes = mem.read(addr, 8) orelse return error.OutOfBoundsMemoryAccess;
        try self.stack.pushF64(@bitCast(std.mem.readInt(u64, bytes[0..8], .little)));
    }

    fn memLoadExtend(self: *Interpreter, comptime T: type, comptime S: type, comptime size: usize, memarg: binary.instructions.MemArg) !void {
        const mem = self.memory orelse return error.NoMemory;
        const base = @as(u32, @bitCast(try self.stack.popI32()));
        const addr = base +% memarg.offset;
        const bytes = mem.read(addr, size) orelse return error.OutOfBoundsMemoryAccess;
        const small = std.mem.readInt(S, bytes[0..size], .little);
        if (T == i32) {
            try self.stack.pushI32(@as(i32, small));
        } else {
            try self.stack.pushI64(@as(i64, small));
        }
    }

    fn memStore(self: *Interpreter, comptime T: type, comptime size: usize, memarg: binary.instructions.MemArg) !void {
        const mem = self.memory orelse return error.NoMemory;
        const value = if (T == i32) try self.stack.popI32() else try self.stack.popI64();
        const base = @as(u32, @bitCast(try self.stack.popI32()));
        const addr = base +% memarg.offset;
        var bytes: [size]u8 = undefined;
        std.mem.writeInt(T, &bytes, value, .little);
        mem.write(addr, &bytes) orelse return error.OutOfBoundsMemoryAccess;
    }

    fn memStoreF32(self: *Interpreter, memarg: binary.instructions.MemArg) !void {
        const mem = self.memory orelse return error.NoMemory;
        const value = try self.stack.popF32();
        const base = @as(u32, @bitCast(try self.stack.popI32()));
        const addr = base +% memarg.offset;
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, @bitCast(value), .little);
        mem.write(addr, &bytes) orelse return error.OutOfBoundsMemoryAccess;
    }

    fn memStoreF64(self: *Interpreter, memarg: binary.instructions.MemArg) !void {
        const mem = self.memory orelse return error.NoMemory;
        const value = try self.stack.popF64();
        const base = @as(u32, @bitCast(try self.stack.popI32()));
        const addr = base +% memarg.offset;
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, @bitCast(value), .little);
        mem.write(addr, &bytes) orelse return error.OutOfBoundsMemoryAccess;
    }

    fn memStoreTrunc(self: *Interpreter, comptime T: type, comptime S: type, comptime size: usize, memarg: binary.instructions.MemArg) !void {
        const mem = self.memory orelse return error.NoMemory;
        const value = if (T == i32) try self.stack.popI32() else try self.stack.popI64();
        const base = @as(u32, @bitCast(try self.stack.popI32()));
        const addr = base +% memarg.offset;
        var bytes: [size]u8 = undefined;
        std.mem.writeInt(S, &bytes, @truncate(@as(if (T == i32) u32 else u64, @bitCast(value))), .little);
        mem.write(addr, &bytes) orelse return error.OutOfBoundsMemoryAccess;
    }

    // Binary operation helpers
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

    // Comparison helpers
    fn cmpI32(self: *Interpreter, op: fn (i32, i32) bool) !void {
        const b = try self.stack.popI32();
        const a = try self.stack.popI32();
        try self.stack.pushI32(if (op(a, b)) 1 else 0);
    }

    fn cmpU32(self: *Interpreter, op: fn (u32, u32) bool) !void {
        const b = @as(u32, @bitCast(try self.stack.popI32()));
        const a = @as(u32, @bitCast(try self.stack.popI32()));
        try self.stack.pushI32(if (op(a, b)) 1 else 0);
    }

    fn cmpI64(self: *Interpreter, op: fn (i64, i64) bool) !void {
        const b = try self.stack.popI64();
        const a = try self.stack.popI64();
        try self.stack.pushI32(if (op(a, b)) 1 else 0);
    }

    fn cmpU64(self: *Interpreter, op: fn (u64, u64) bool) !void {
        const b = @as(u64, @bitCast(try self.stack.popI64()));
        const a = @as(u64, @bitCast(try self.stack.popI64()));
        try self.stack.pushI32(if (op(a, b)) 1 else 0);
    }

    fn cmpF32(self: *Interpreter, op: fn (f32, f32) bool) !void {
        const b = try self.stack.popF32();
        const a = try self.stack.popF32();
        try self.stack.pushI32(if (op(a, b)) 1 else 0);
    }

    fn cmpF64(self: *Interpreter, op: fn (f64, f64) bool) !void {
        const b = try self.stack.popF64();
        const a = try self.stack.popF64();
        try self.stack.pushI32(if (op(a, b)) 1 else 0);
    }
};

test "interpreter init" {
    _ = Interpreter;
}

// Init expression evaluation tests
test "interpreter evaluateInitExpr i32.const" {
    const allocator = std.testing.allocator;

    // Minimal module
    const wasm = "\x00asm\x01\x00\x00\x00";
    var module = try binary.Module.parse(allocator, wasm);
    defer module.deinit();

    var interp = Interpreter.init(allocator, &module);
    defer interp.deinit();

    // i32.const 42, end
    const expr = &[_]u8{ 0x41, 0x2a, 0x0b };
    const val = try interp.evaluateInitExpr(expr);
    try std.testing.expectEqual(@as(i32, 42), val.i32);
}

test "interpreter evaluateInitExpr i64.const" {
    const allocator = std.testing.allocator;

    const wasm = "\x00asm\x01\x00\x00\x00";
    var module = try binary.Module.parse(allocator, wasm);
    defer module.deinit();

    var interp = Interpreter.init(allocator, &module);
    defer interp.deinit();

    // i64.const 999, end
    const expr = &[_]u8{ 0x42, 0xe7, 0x07, 0x0b };
    const val = try interp.evaluateInitExpr(expr);
    try std.testing.expectEqual(@as(i64, 999), val.i64);
}

test "interpreter evaluateInitExpr f32.const" {
    const allocator = std.testing.allocator;

    const wasm = "\x00asm\x01\x00\x00\x00";
    var module = try binary.Module.parse(allocator, wasm);
    defer module.deinit();

    var interp = Interpreter.init(allocator, &module);
    defer interp.deinit();

    // f32.const 3.14159..., end
    const expr = &[_]u8{ 0x43, 0xdb, 0x0f, 0x49, 0x40, 0x0b };
    const val = try interp.evaluateInitExpr(expr);
    try std.testing.expect(@abs(val.f32 - 3.14159) < 0.001);
}

test "interpreter evaluateInitExpr f64.const" {
    const allocator = std.testing.allocator;

    const wasm = "\x00asm\x01\x00\x00\x00";
    var module = try binary.Module.parse(allocator, wasm);
    defer module.deinit();

    var interp = Interpreter.init(allocator, &module);
    defer interp.deinit();

    // f64.const 1.0, end
    const expr = &[_]u8{ 0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xf0, 0x3f, 0x0b };
    const val = try interp.evaluateInitExpr(expr);
    try std.testing.expectEqual(@as(f64, 1.0), val.f64);
}

test "interpreter evaluateInitExpr global.get" {
    const allocator = std.testing.allocator;

    const wasm = "\x00asm\x01\x00\x00\x00";
    var module = try binary.Module.parse(allocator, wasm);
    defer module.deinit();

    var interp = Interpreter.init(allocator, &module);
    defer interp.deinit();

    // Set up a global
    interp.globals = try allocator.alloc(Value, 1);
    interp.globals[0] = Value{ .i32 = 789 };

    // global.get 0, end
    const expr = &[_]u8{ 0x23, 0x00, 0x0b };
    const val = try interp.evaluateInitExpr(expr);
    try std.testing.expectEqual(@as(i32, 789), val.i32);
}

test "interpreter evaluateInitExpr invalid opcode" {
    const allocator = std.testing.allocator;

    const wasm = "\x00asm\x01\x00\x00\x00";
    var module = try binary.Module.parse(allocator, wasm);
    defer module.deinit();

    var interp = Interpreter.init(allocator, &module);
    defer interp.deinit();

    // nop (not allowed), end
    const expr = &[_]u8{ 0x01, 0x0b };
    try std.testing.expectError(error.InvalidInitExpression, interp.evaluateInitExpr(expr));
}

test "interpreter evaluateInitExpr invalid global index" {
    const allocator = std.testing.allocator;

    const wasm = "\x00asm\x01\x00\x00\x00";
    var module = try binary.Module.parse(allocator, wasm);
    defer module.deinit();

    var interp = Interpreter.init(allocator, &module);
    defer interp.deinit();

    // global.get 5 (doesn't exist), end
    const expr = &[_]u8{ 0x23, 0x05, 0x0b };
    try std.testing.expectError(error.InvalidGlobalIndex, interp.evaluateInitExpr(expr));
}

test "interpreter initGlobals with init expressions" {
    const allocator = std.testing.allocator;

    // Module with global section containing i32.const 42
    const wasm = "\x00asm\x01\x00\x00\x00" ++
        "\x06\x06\x01\x7f\x00\x41\x2a\x0b"; // global section: i32, immutable, i32.const 42, end

    var module = try binary.Module.parse(allocator, wasm);
    defer module.deinit();

    var interp = Interpreter.init(allocator, &module);
    defer interp.deinit();

    try interp.initGlobals(module.globals);

    try std.testing.expectEqual(@as(usize, 1), interp.globals.len);
    try std.testing.expectEqual(@as(i32, 42), interp.globals[0].i32);
}

// Indirect call tests
test "interpreter call_indirect valid" {
    const allocator = std.testing.allocator;

    // Module with a table, a function, and element initialization
    // Type: () -> i32
    // Function: returns 42
    // Table: 1 element
    // Element: table[0] = func 0
    const wasm = "\x00asm\x01\x00\x00\x00" ++
        "\x01\x05\x01\x60\x00\x01\x7f" ++ // type section: () -> i32
        "\x03\x02\x01\x00" ++ // function section: 1 func, type 0
        "\x04\x04\x01\x70\x00\x01" ++ // table section: funcref, min=1
        "\x09\x07\x01\x00\x41\x00\x0b\x01\x00" ++ // element section: table 0, offset 0, [func 0]
        "\x0a\x06\x01\x04\x00\x41\x2a\x0b"; // code section: i32.const 42, end

    var module = try binary.Module.parse(allocator, wasm);
    defer module.deinit();

    var interp = Interpreter.init(allocator, &module);
    defer interp.deinit();

    // Set up table
    var tables = try allocator.alloc(Table, 1);
    defer allocator.free(tables);
    tables[0] = try Table.init(allocator, .{ .elem_type = .funcref, .limits = .{ .min = 1, .max = null } });
    defer tables[0].deinit();
    try tables[0].set(0, 0); // table[0] = func 0

    interp.setTables(tables);

    // Push table index on stack and call indirectly
    try interp.stack.pushI32(0); // element index 0

    // Create call_indirect instruction
    const instr = binary.instructions.Instruction{
        .opcode = .call_indirect,
        .immediate = .{ .call_indirect = .{ .type_idx = 0, .table_idx = 0 } },
    };

    var reader = Reader.init(&[_]u8{});
    _ = try interp.executeInstruction(instr, &reader);

    // Result should be on stack
    const result = try interp.stack.popI32();
    try std.testing.expectEqual(@as(i32, 42), result);
}

test "interpreter call_indirect null entry" {
    const allocator = std.testing.allocator;

    const wasm = "\x00asm\x01\x00\x00\x00" ++
        "\x01\x05\x01\x60\x00\x01\x7f" ++ // type section: () -> i32
        "\x03\x02\x01\x00" ++ // function section: 1 func, type 0
        "\x04\x04\x01\x70\x00\x02" ++ // table section: funcref, min=2
        "\x0a\x06\x01\x04\x00\x41\x2a\x0b"; // code section

    var module = try binary.Module.parse(allocator, wasm);
    defer module.deinit();

    var interp = Interpreter.init(allocator, &module);
    defer interp.deinit();

    var tables = try allocator.alloc(Table, 1);
    defer allocator.free(tables);
    tables[0] = try Table.init(allocator, .{ .elem_type = .funcref, .limits = .{ .min = 2, .max = null } });
    defer tables[0].deinit();
    // table[0] is null (not initialized)
    try tables[0].set(1, 0); // only table[1] = func 0

    interp.setTables(tables);

    try interp.stack.pushI32(0); // element index 0 (null)

    const instr = binary.instructions.Instruction{
        .opcode = .call_indirect,
        .immediate = .{ .call_indirect = .{ .type_idx = 0, .table_idx = 0 } },
    };

    var reader = Reader.init(&[_]u8{});
    try std.testing.expectError(error.UndefinedElement, interp.executeInstruction(instr, &reader));
}

test "interpreter call_indirect out of bounds" {
    const allocator = std.testing.allocator;

    const wasm = "\x00asm\x01\x00\x00\x00" ++
        "\x01\x05\x01\x60\x00\x01\x7f" ++
        "\x03\x02\x01\x00" ++
        "\x04\x04\x01\x70\x00\x01" ++
        "\x0a\x06\x01\x04\x00\x41\x2a\x0b";

    var module = try binary.Module.parse(allocator, wasm);
    defer module.deinit();

    var interp = Interpreter.init(allocator, &module);
    defer interp.deinit();

    var tables = try allocator.alloc(Table, 1);
    defer allocator.free(tables);
    tables[0] = try Table.init(allocator, .{ .elem_type = .funcref, .limits = .{ .min = 1, .max = null } });
    defer tables[0].deinit();

    interp.setTables(tables);

    try interp.stack.pushI32(99); // element index 99 (out of bounds)

    const instr = binary.instructions.Instruction{
        .opcode = .call_indirect,
        .immediate = .{ .call_indirect = .{ .type_idx = 0, .table_idx = 0 } },
    };

    var reader = Reader.init(&[_]u8{});
    try std.testing.expectError(error.TableOutOfBounds, interp.executeInstruction(instr, &reader));
}

test "interpreter call_indirect type mismatch" {
    const allocator = std.testing.allocator;

    // Two types: () -> i32 and (i32) -> i32
    // Type section: count=2, type0=(0x60,0x00,0x01,0x7f), type1=(0x60,0x01,0x7f,0x01,0x7f)
    // Size = 1 + 4 + 5 = 10 bytes = 0x0a
    const wasm = "\x00asm\x01\x00\x00\x00" ++
        "\x01\x0a\x02\x60\x00\x01\x7f\x60\x01\x7f\x01\x7f" ++ // type section: () -> i32, (i32) -> i32
        "\x03\x02\x01\x00" ++ // function section: 1 func, type 0 (no params)
        "\x04\x04\x01\x70\x00\x01" ++ // table section
        "\x0a\x06\x01\x04\x00\x41\x2a\x0b"; // code section

    var module = try binary.Module.parse(allocator, wasm);
    defer module.deinit();

    var interp = Interpreter.init(allocator, &module);
    defer interp.deinit();

    var tables = try allocator.alloc(Table, 1);
    defer allocator.free(tables);
    tables[0] = try Table.init(allocator, .{ .elem_type = .funcref, .limits = .{ .min = 1, .max = null } });
    defer tables[0].deinit();
    try tables[0].set(0, 0); // table[0] = func 0 (which has type 0)

    interp.setTables(tables);

    try interp.stack.pushI32(0); // element index 0

    // call_indirect with type 1 (expects i32 param), but func 0 has type 0 (no params)
    const instr = binary.instructions.Instruction{
        .opcode = .call_indirect,
        .immediate = .{ .call_indirect = .{ .type_idx = 1, .table_idx = 0 } },
    };

    var reader = Reader.init(&[_]u8{});
    try std.testing.expectError(error.IndirectCallTypeMismatch, interp.executeInstruction(instr, &reader));
}

test "interpreter call_indirect multiple calls" {
    const allocator = std.testing.allocator;

    // Two functions: func0 returns 10, func1 returns 20
    const wasm = "\x00asm\x01\x00\x00\x00" ++
        "\x01\x05\x01\x60\x00\x01\x7f" ++ // type section: () -> i32
        "\x03\x03\x02\x00\x00" ++ // function section: 2 funcs, both type 0
        "\x04\x04\x01\x70\x00\x02" ++ // table section: min=2
        "\x0a\x0b\x02\x04\x00\x41\x0a\x0b\x04\x00\x41\x14\x0b"; // code: const 10, const 20

    var module = try binary.Module.parse(allocator, wasm);
    defer module.deinit();

    var interp = Interpreter.init(allocator, &module);
    defer interp.deinit();

    var tables = try allocator.alloc(Table, 1);
    defer allocator.free(tables);
    tables[0] = try Table.init(allocator, .{ .elem_type = .funcref, .limits = .{ .min = 2, .max = null } });
    defer tables[0].deinit();
    try tables[0].set(0, 0); // table[0] = func 0
    try tables[0].set(1, 1); // table[1] = func 1

    interp.setTables(tables);

    // First call: table[0] -> func 0 -> 10
    try interp.stack.pushI32(0);
    const instr = binary.instructions.Instruction{
        .opcode = .call_indirect,
        .immediate = .{ .call_indirect = .{ .type_idx = 0, .table_idx = 0 } },
    };
    var reader = Reader.init(&[_]u8{});
    _ = try interp.executeInstruction(instr, &reader);
    try std.testing.expectEqual(@as(i32, 10), try interp.stack.popI32());

    // Second call: table[1] -> func 1 -> 20
    try interp.stack.pushI32(1);
    _ = try interp.executeInstruction(instr, &reader);
    try std.testing.expectEqual(@as(i32, 20), try interp.stack.popI32());
}

test "interpreter call_indirect table index out of bounds" {
    const allocator = std.testing.allocator;

    const wasm = "\x00asm\x01\x00\x00\x00" ++
        "\x01\x05\x01\x60\x00\x01\x7f" ++
        "\x03\x02\x01\x00" ++
        "\x0a\x06\x01\x04\x00\x41\x2a\x0b";

    var module = try binary.Module.parse(allocator, wasm);
    defer module.deinit();

    var interp = Interpreter.init(allocator, &module);
    defer interp.deinit();

    // No tables set
    interp.tables = &[_]Table{};

    try interp.stack.pushI32(0);

    // call_indirect with table_idx=0, but no tables exist
    const instr = binary.instructions.Instruction{
        .opcode = .call_indirect,
        .immediate = .{ .call_indirect = .{ .type_idx = 0, .table_idx = 0 } },
    };

    var reader = Reader.init(&[_]u8{});
    try std.testing.expectError(error.TableOutOfBounds, interp.executeInstruction(instr, &reader));
}

test "interpreter call_indirect same type different index" {
    const allocator = std.testing.allocator;

    // Two identical types (structurally equal)
    const wasm = "\x00asm\x01\x00\x00\x00" ++
        "\x01\x09\x02\x60\x00\x01\x7f\x60\x00\x01\x7f" ++ // two () -> i32 types
        "\x03\x02\x01\x01" ++ // func uses type 1
        "\x04\x04\x01\x70\x00\x01" ++
        "\x0a\x06\x01\x04\x00\x41\x2a\x0b";

    var module = try binary.Module.parse(allocator, wasm);
    defer module.deinit();

    var interp = Interpreter.init(allocator, &module);
    defer interp.deinit();

    var tables = try allocator.alloc(Table, 1);
    defer allocator.free(tables);
    tables[0] = try Table.init(allocator, .{ .elem_type = .funcref, .limits = .{ .min = 1, .max = null } });
    defer tables[0].deinit();
    try tables[0].set(0, 0);

    interp.setTables(tables);

    try interp.stack.pushI32(0);

    // call_indirect with type 0, but func has type 1 (structurally equal)
    const instr = binary.instructions.Instruction{
        .opcode = .call_indirect,
        .immediate = .{ .call_indirect = .{ .type_idx = 0, .table_idx = 0 } },
    };

    var reader = Reader.init(&[_]u8{});
    // Should succeed because types are structurally equal
    _ = try interp.executeInstruction(instr, &reader);
    try std.testing.expectEqual(@as(i32, 42), try interp.stack.popI32());
}

test "interpreter call_indirect negative index" {
    const allocator = std.testing.allocator;

    const wasm = "\x00asm\x01\x00\x00\x00" ++
        "\x01\x05\x01\x60\x00\x01\x7f" ++
        "\x03\x02\x01\x00" ++
        "\x04\x04\x01\x70\x00\x01" ++
        "\x0a\x06\x01\x04\x00\x41\x2a\x0b";

    var module = try binary.Module.parse(allocator, wasm);
    defer module.deinit();

    var interp = Interpreter.init(allocator, &module);
    defer interp.deinit();

    var tables = try allocator.alloc(Table, 1);
    defer allocator.free(tables);
    tables[0] = try Table.init(allocator, .{ .elem_type = .funcref, .limits = .{ .min = 1, .max = null } });
    defer tables[0].deinit();

    interp.setTables(tables);

    // Push -1 as signed i32 (large unsigned value)
    try interp.stack.pushI32(-1);

    const instr = binary.instructions.Instruction{
        .opcode = .call_indirect,
        .immediate = .{ .call_indirect = .{ .type_idx = 0, .table_idx = 0 } },
    };

    var reader = Reader.init(&[_]u8{});
    // -1 as u32 = 0xFFFFFFFF, way out of bounds
    try std.testing.expectError(error.TableOutOfBounds, interp.executeInstruction(instr, &reader));
}
