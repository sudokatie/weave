// JIT Compiler - Top-level orchestrator
//
// Coordinates hot path detection, code generation, and runtime patching
// to provide JIT compilation for WebAssembly functions.

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;

// Import JIT submodules
pub const hotpath = @import("jit/hotpath.zig");
pub const x86 = @import("jit/x86.zig");
pub const patch = @import("jit/patch.zig");

pub const HotPathDetector = hotpath.HotPathDetector;
pub const X86CodeGen = x86.X86CodeGen;
pub const PatchPoint = patch.PatchPoint;

/// WASM opcodes for translation
const WasmOp = struct {
    const i32_const: u8 = 0x41;
    const i32_add: u8 = 0x6A;
    const i32_sub: u8 = 0x6B;
    const i32_mul: u8 = 0x6C;
    const i32_load: u8 = 0x28;
    const i32_store: u8 = 0x36;
    const @"if": u8 = 0x04;
    const end: u8 = 0x0B;
};

/// Page size for executable memory allocation
const PAGE_SIZE: usize = 4096;

/// JIT Compiler orchestrates hot path detection, code generation,
/// and management of compiled native code.
pub const JitCompiler = struct {
    allocator: Allocator,
    detector: HotPathDetector,
    compiled: std.AutoHashMap(u32, []const u8),
    code_pages: std.ArrayList([]align(4096) u8),
    enabled: bool,

    const Self = @This();

    /// Initialize a new JIT compiler
    pub fn init(allocator: Allocator) Self {
        return Self{
            .allocator = allocator,
            .detector = HotPathDetector.init(allocator),
            .compiled = std.AutoHashMap(u32, []const u8).init(allocator),
            .code_pages = std.ArrayList([]align(4096) u8).empty,
            .enabled = true,
        };
    }

    /// Cleanup and free all resources
    pub fn deinit(self: *Self) void {
        // Free all allocated executable pages
        for (self.code_pages.items) |page| {
            posix.munmap(page);
        }
        self.code_pages.deinit(self.allocator);
        self.compiled.deinit();
        self.detector.deinit();
    }

    /// Record a function call. Returns true when compilation should be triggered.
    pub fn record_call(self: *Self, fn_index: u32) bool {
        if (!self.enabled) {
            return false;
        }
        return self.detector.record_call(fn_index);
    }

    /// Check if a function has been compiled
    pub fn is_compiled(self: *Self, fn_index: u32) bool {
        return self.compiled.contains(fn_index);
    }

    /// Get compiled native code for a function
    pub fn get_compiled(self: *Self, fn_index: u32) ?[]const u8 {
        return self.compiled.get(fn_index);
    }

    /// Compile a WASM function to native x86-64 code
    pub fn compile(self: *Self, fn_index: u32, wasm_bytes: []const u8) !void {
        if (!self.enabled) {
            return;
        }

        // Create code generator
        var codegen = X86CodeGen.init(self.allocator);
        defer codegen.deinit();

        // Emit function prologue
        codegen.emit_prologue();

        // Translate WASM opcodes to x86-64
        var i: usize = 0;
        while (i < wasm_bytes.len) {
            const opcode = wasm_bytes[i];
            i += 1;

            switch (opcode) {
                WasmOp.i32_const => {
                    // Read LEB128 encoded value
                    const value = decodeLeb128Signed(wasm_bytes[i..]);
                    i += leb128Size(wasm_bytes[i..]);
                    codegen.emit_i32_const(value);
                },
                WasmOp.i32_add => {
                    codegen.emit_i32_add();
                },
                WasmOp.i32_sub => {
                    codegen.emit_i32_sub();
                },
                WasmOp.i32_mul => {
                    codegen.emit_i32_mul();
                },
                WasmOp.i32_load => {
                    // Read alignment and offset (both LEB128)
                    _ = decodeLeb128Unsigned(wasm_bytes[i..]); // alignment (ignored)
                    i += leb128Size(wasm_bytes[i..]);
                    const offset = decodeLeb128Unsigned(wasm_bytes[i..]);
                    i += leb128Size(wasm_bytes[i..]);
                    codegen.emit_i32_load(offset);
                },
                WasmOp.i32_store => {
                    // Read alignment and offset (both LEB128)
                    _ = decodeLeb128Unsigned(wasm_bytes[i..]); // alignment (ignored)
                    i += leb128Size(wasm_bytes[i..]);
                    const offset = decodeLeb128Unsigned(wasm_bytes[i..]);
                    i += leb128Size(wasm_bytes[i..]);
                    codegen.emit_i32_store(offset);
                },
                WasmOp.@"if" => {
                    // Skip block type
                    i += 1;
                    // Emit branch (simplified - uses label 0)
                    codegen.emit_branch(.ne, 0);
                },
                WasmOp.end => {
                    // Function end - emit epilogue
                    codegen.emit_epilogue();
                    break;
                },
                else => {
                    // Unknown opcode - emit call to interpreter fallback
                    // For now, just emit a NOP as placeholder
                    codegen.emit(&[_]u8{0x90});
                },
            }
        }

        // If we didn't hit an 'end' opcode, still emit epilogue
        if (wasm_bytes.len == 0 or wasm_bytes[wasm_bytes.len - 1] != WasmOp.end) {
            codegen.emit_epilogue();
        }

        // Get generated code
        const code = codegen.get_code();
        if (code.len == 0) {
            return;
        }

        // Allocate executable memory
        const page_count = (code.len + PAGE_SIZE - 1) / PAGE_SIZE;
        const alloc_size = page_count * PAGE_SIZE;

        const executable_mem = try posix.mmap(
            null,
            alloc_size,
            posix.PROT.READ | posix.PROT.WRITE | posix.PROT.EXEC,
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
            -1,
            0,
        );

        // Copy code to executable memory
        @memcpy(executable_mem[0..code.len], code);

        // Track the page for cleanup
        try self.code_pages.append(self.allocator, executable_mem);

        // Store in compiled map
        try self.compiled.put(fn_index, executable_mem[0..code.len]);

        // Mark as compiled in detector
        self.detector.mark_compiled(fn_index);
    }

    /// Enable JIT compilation
    pub fn enable(self: *Self) void {
        self.enabled = true;
    }

    /// Disable JIT compilation
    pub fn disable(self: *Self) void {
        self.enabled = false;
    }

    /// Set the hot path threshold
    pub fn set_threshold(self: *Self, threshold: u32) void {
        self.detector.set_threshold(threshold);
    }

    /// Reset all state (call counts, compiled code)
    pub fn reset(self: *Self) void {
        // Free all code pages
        for (self.code_pages.items) |page| {
            posix.munmap(page);
        }
        self.code_pages.clearRetainingCapacity();
        self.compiled.clearRetainingCapacity();
        self.detector.reset();
    }
};

/// Decode a signed LEB128 value
fn decodeLeb128Signed(bytes: []const u8) i32 {
    var result: i32 = 0;
    var shift: u5 = 0;
    var i: usize = 0;

    while (i < bytes.len) {
        const byte = bytes[i];
        const value: i32 = @intCast(byte & 0x7F);
        result |= value << shift;
        shift +|= 7;
        i += 1;

        if (byte & 0x80 == 0) {
            // Sign extend if needed
            if (shift < 32 and (byte & 0x40) != 0) {
                result |= @as(i32, -1) << shift;
            }
            break;
        }
    }

    return result;
}

/// Decode an unsigned LEB128 value
fn decodeLeb128Unsigned(bytes: []const u8) u32 {
    var result: u32 = 0;
    var shift: u5 = 0;

    for (bytes) |byte| {
        const value: u32 = @intCast(byte & 0x7F);
        result |= value << shift;
        shift +|= 7;

        if (byte & 0x80 == 0) {
            break;
        }
    }

    return result;
}

/// Get the size of a LEB128 encoded value
fn leb128Size(bytes: []const u8) usize {
    for (bytes, 0..) |byte, i| {
        if (byte & 0x80 == 0) {
            return i + 1;
        }
    }
    return bytes.len;
}

// =============================================================================
// Tests
// =============================================================================

test "JitCompiler init and deinit" {
    var jit = JitCompiler.init(std.testing.allocator);
    defer jit.deinit();

    try std.testing.expect(jit.enabled);
    try std.testing.expectEqual(@as(usize, 0), jit.compiled.count());
    try std.testing.expectEqual(@as(usize, 0), jit.code_pages.items.len);
}

test "JitCompiler record_call delegates to detector" {
    var jit = JitCompiler.init(std.testing.allocator);
    defer jit.deinit();

    jit.set_threshold(3);

    try std.testing.expect(!jit.record_call(0)); // count = 1
    try std.testing.expect(!jit.record_call(0)); // count = 2
    try std.testing.expect(jit.record_call(0)); // count = 3, threshold crossed
    try std.testing.expect(!jit.record_call(0)); // count = 4, already past threshold
}

test "JitCompiler record_call respects enabled flag" {
    var jit = JitCompiler.init(std.testing.allocator);
    defer jit.deinit();

    jit.set_threshold(1);

    jit.disable();
    try std.testing.expect(!jit.record_call(0)); // should return false when disabled

    jit.enable();
    try std.testing.expect(jit.record_call(0)); // should return true when enabled
}

test "JitCompiler compile simple WASM" {
    var jit = JitCompiler.init(std.testing.allocator);
    defer jit.deinit();

    // Simple WASM: i32.const 10, i32.const 20, i32.add, end
    const wasm_bytes = [_]u8{
        0x41, 10, // i32.const 10
        0x41, 20, // i32.const 20
        0x6A, // i32.add
        0x0B, // end
    };

    try jit.compile(0, &wasm_bytes);

    try std.testing.expect(jit.is_compiled(0));
    try std.testing.expect(jit.get_compiled(0) != null);
    try std.testing.expectEqual(@as(usize, 1), jit.code_pages.items.len);
}

test "JitCompiler is_compiled check" {
    var jit = JitCompiler.init(std.testing.allocator);
    defer jit.deinit();

    try std.testing.expect(!jit.is_compiled(0));
    try std.testing.expect(!jit.is_compiled(1));

    const wasm_bytes = [_]u8{ 0x41, 42, 0x0B };
    try jit.compile(0, &wasm_bytes);

    try std.testing.expect(jit.is_compiled(0));
    try std.testing.expect(!jit.is_compiled(1));
}

test "JitCompiler get_compiled returns code" {
    var jit = JitCompiler.init(std.testing.allocator);
    defer jit.deinit();

    try std.testing.expectEqual(@as(?[]const u8, null), jit.get_compiled(0));

    const wasm_bytes = [_]u8{ 0x41, 42, 0x0B };
    try jit.compile(0, &wasm_bytes);

    const code = jit.get_compiled(0);
    try std.testing.expect(code != null);
    try std.testing.expect(code.?.len > 0);

    // Verify code starts with push rbp (0x55)
    try std.testing.expectEqual(@as(u8, 0x55), code.?[0]);
    // Verify code ends with ret (0xC3)
    try std.testing.expectEqual(@as(u8, 0xC3), code.?[code.?.len - 1]);
}

test "JitCompiler enable and disable" {
    var jit = JitCompiler.init(std.testing.allocator);
    defer jit.deinit();

    try std.testing.expect(jit.enabled);

    jit.disable();
    try std.testing.expect(!jit.enabled);

    jit.enable();
    try std.testing.expect(jit.enabled);
}

test "JitCompiler compile when disabled does nothing" {
    var jit = JitCompiler.init(std.testing.allocator);
    defer jit.deinit();

    jit.disable();

    const wasm_bytes = [_]u8{ 0x41, 42, 0x0B };
    try jit.compile(0, &wasm_bytes);

    try std.testing.expect(!jit.is_compiled(0));
    try std.testing.expectEqual(@as(usize, 0), jit.code_pages.items.len);
}

test "JitCompiler multiple function compilation" {
    var jit = JitCompiler.init(std.testing.allocator);
    defer jit.deinit();

    const wasm1 = [_]u8{ 0x41, 10, 0x0B };
    const wasm2 = [_]u8{ 0x41, 20, 0x41, 30, 0x6A, 0x0B };
    const wasm3 = [_]u8{ 0x41, 5, 0x41, 3, 0x6C, 0x0B };

    try jit.compile(0, &wasm1);
    try jit.compile(1, &wasm2);
    try jit.compile(2, &wasm3);

    try std.testing.expect(jit.is_compiled(0));
    try std.testing.expect(jit.is_compiled(1));
    try std.testing.expect(jit.is_compiled(2));
    try std.testing.expect(!jit.is_compiled(3));

    try std.testing.expectEqual(@as(usize, 3), jit.compiled.count());
    try std.testing.expectEqual(@as(usize, 3), jit.code_pages.items.len);
}

test "JitCompiler reset clears all state" {
    var jit = JitCompiler.init(std.testing.allocator);
    defer jit.deinit();

    const wasm_bytes = [_]u8{ 0x41, 42, 0x0B };
    try jit.compile(0, &wasm_bytes);
    try jit.compile(1, &wasm_bytes);

    try std.testing.expectEqual(@as(usize, 2), jit.compiled.count());
    try std.testing.expectEqual(@as(usize, 2), jit.code_pages.items.len);

    jit.reset();

    try std.testing.expectEqual(@as(usize, 0), jit.compiled.count());
    try std.testing.expectEqual(@as(usize, 0), jit.code_pages.items.len);
}

test "JitCompiler compile with subtraction" {
    var jit = JitCompiler.init(std.testing.allocator);
    defer jit.deinit();

    // i32.const 50, i32.const 30, i32.sub, end
    const wasm_bytes = [_]u8{
        0x41, 50, // i32.const 50
        0x41, 30, // i32.const 30
        0x6B, // i32.sub
        0x0B, // end
    };

    try jit.compile(0, &wasm_bytes);

    try std.testing.expect(jit.is_compiled(0));
    const code = jit.get_compiled(0);
    try std.testing.expect(code != null);
}

test "JitCompiler compile with multiplication" {
    var jit = JitCompiler.init(std.testing.allocator);
    defer jit.deinit();

    // i32.const 6, i32.const 7, i32.mul, end
    const wasm_bytes = [_]u8{
        0x41, 6, // i32.const 6
        0x41, 7, // i32.const 7
        0x6C, // i32.mul
        0x0B, // end
    };

    try jit.compile(0, &wasm_bytes);

    try std.testing.expect(jit.is_compiled(0));
}

test "JitCompiler compile complex sequence" {
    var jit = JitCompiler.init(std.testing.allocator);
    defer jit.deinit();

    // (10 + 20) * (5 - 2) = 30 * 3 = 90
    const wasm_bytes = [_]u8{
        0x41, 10, // i32.const 10
        0x41, 20, // i32.const 20
        0x6A, // i32.add (= 30)
        0x41, 5, // i32.const 5
        0x41, 2, // i32.const 2
        0x6B, // i32.sub (= 3)
        0x6C, // i32.mul (= 90)
        0x0B, // end
    };

    try jit.compile(0, &wasm_bytes);

    try std.testing.expect(jit.is_compiled(0));
    const code = jit.get_compiled(0);
    try std.testing.expect(code != null);
    try std.testing.expect(code.?.len > 20); // Should have substantial code
}

test "patch module exports" {
    // Verify patch module exports work correctly
    var buffer: [16]u8 = .{ 0x55, 0x48, 0x89, 0xE5, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90 };
    var jit_buffer: [16]u8 = .{ 0xC3, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90 };

    var patch_point = patch.patch_entry(&buffer, &jit_buffer);
    try std.testing.expect(patch_point.is_patched);
    try std.testing.expectEqual(@as(u8, 0xE9), buffer[0]);

    patch.restore_entry(&patch_point);
    try std.testing.expect(!patch_point.is_patched);
    try std.testing.expectEqual(@as(u8, 0x55), buffer[0]);
}

test "LEB128 decoding" {
    // Single byte positive (bit 6 must be 0 to avoid sign extension)
    try std.testing.expectEqual(@as(i32, 0), decodeLeb128Signed(&[_]u8{0x00}));
    try std.testing.expectEqual(@as(i32, 1), decodeLeb128Signed(&[_]u8{0x01}));
    try std.testing.expectEqual(@as(i32, 63), decodeLeb128Signed(&[_]u8{0x3F})); // max single-byte positive

    // Single byte negative (bit 6 set triggers sign extension)
    try std.testing.expectEqual(@as(i32, -1), decodeLeb128Signed(&[_]u8{0x7F}));
    try std.testing.expectEqual(@as(i32, -2), decodeLeb128Signed(&[_]u8{0x7E}));
    try std.testing.expectEqual(@as(i32, -64), decodeLeb128Signed(&[_]u8{0x40})); // min single-byte negative

    // Multi-byte positive (127 needs two bytes to avoid sign extension)
    try std.testing.expectEqual(@as(i32, 127), decodeLeb128Signed(&[_]u8{ 0xFF, 0x00 }));
    try std.testing.expectEqual(@as(i32, 128), decodeLeb128Signed(&[_]u8{ 0x80, 0x01 }));
    try std.testing.expectEqual(@as(i32, 256), decodeLeb128Signed(&[_]u8{ 0x80, 0x02 }));

    // Unsigned
    try std.testing.expectEqual(@as(u32, 0), decodeLeb128Unsigned(&[_]u8{0x00}));
    try std.testing.expectEqual(@as(u32, 127), decodeLeb128Unsigned(&[_]u8{0x7F}));
    try std.testing.expectEqual(@as(u32, 128), decodeLeb128Unsigned(&[_]u8{ 0x80, 0x01 }));
}

test "LEB128 size calculation" {
    try std.testing.expectEqual(@as(usize, 1), leb128Size(&[_]u8{0x00}));
    try std.testing.expectEqual(@as(usize, 1), leb128Size(&[_]u8{0x7F}));
    try std.testing.expectEqual(@as(usize, 2), leb128Size(&[_]u8{ 0x80, 0x01 }));
    try std.testing.expectEqual(@as(usize, 3), leb128Size(&[_]u8{ 0x80, 0x80, 0x01 }));
}

test {
    // Reference submodules for test discovery
    _ = hotpath;
    _ = x86;
    _ = patch;
}
