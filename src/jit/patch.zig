// Runtime patching for JIT entry/exit
//
// Provides mechanisms to patch function entry points to redirect
// execution to JIT-compiled native code.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Represents a patch point where original bytes have been saved
/// and can be restored later.
pub const PatchPoint = struct {
    /// Original bytes that were overwritten by the patch
    original_bytes: [5]u8,
    /// Address where the patch was applied
    address: [*]u8,
    /// Whether this patch point is currently active
    is_patched: bool,

    const Self = @This();

    /// Create a new unpatched patch point
    pub fn init(address: [*]u8) Self {
        return Self{
            .original_bytes = undefined,
            .address = address,
            .is_patched = false,
        };
    }
};

/// Patch a function entry point to jump to JIT-compiled code.
/// Writes a 5-byte JMP rel32 instruction (0xE9 + rel32 offset).
///
/// Returns a PatchPoint that can be used to restore the original bytes.
pub fn patch_entry(fn_addr: [*]u8, jit_addr: [*]const u8) PatchPoint {
    var patch = PatchPoint.init(fn_addr);

    // Save original bytes
    for (0..5) |i| {
        patch.original_bytes[i] = fn_addr[i];
    }

    // Calculate relative offset for JMP rel32
    // rel32 = target - (source + 5)
    const source: i64 = @intCast(@intFromPtr(fn_addr));
    const target: i64 = @intCast(@intFromPtr(jit_addr));
    const rel32: i32 = @intCast(target - (source + 5));

    // Write JMP rel32 (0xE9 + 4-byte relative offset)
    fn_addr[0] = 0xE9;
    const rel_bytes = std.mem.asBytes(&rel32);
    fn_addr[1] = rel_bytes[0];
    fn_addr[2] = rel_bytes[1];
    fn_addr[3] = rel_bytes[2];
    fn_addr[4] = rel_bytes[3];

    patch.is_patched = true;
    return patch;
}

/// Restore the original bytes at a patch point.
pub fn restore_entry(patch_point: *PatchPoint) void {
    if (!patch_point.is_patched) {
        return;
    }

    // Restore original bytes using direct assignment
    for (0..5) |i| {
        patch_point.address[i] = patch_point.original_bytes[i];
    }

    patch_point.is_patched = false;
}

// =============================================================================
// Tests
// =============================================================================

test "PatchPoint init" {
    var buffer: [16]u8 = undefined;
    const patch = PatchPoint.init(&buffer);

    try std.testing.expectEqual(false, patch.is_patched);
    try std.testing.expectEqual(@as([*]u8, &buffer), patch.address);
}

test "patch_entry writes JMP instruction" {
    // Create a buffer to simulate function entry
    var fn_buffer: [16]u8 = .{ 0x55, 0x48, 0x89, 0xE5, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90 };
    // Create a buffer to simulate JIT code
    var jit_buffer: [16]u8 = .{ 0xC3, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90 };

    const patch = patch_entry(&fn_buffer, &jit_buffer);

    // Check that original bytes were saved
    try std.testing.expectEqual(@as(u8, 0x55), patch.original_bytes[0]);
    try std.testing.expectEqual(@as(u8, 0x48), patch.original_bytes[1]);
    try std.testing.expectEqual(@as(u8, 0x89), patch.original_bytes[2]);
    try std.testing.expectEqual(@as(u8, 0xE5), patch.original_bytes[3]);
    try std.testing.expectEqual(@as(u8, 0x90), patch.original_bytes[4]);

    // Check that JMP was written
    try std.testing.expectEqual(@as(u8, 0xE9), fn_buffer[0]);

    // Check that patch is marked as active
    try std.testing.expect(patch.is_patched);
}

test "restore_entry restores original bytes" {
    var fn_buffer: [16]u8 = .{ 0x55, 0x48, 0x89, 0xE5, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90 };
    var jit_buffer: [16]u8 = .{ 0xC3, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90 };

    var patch = patch_entry(&fn_buffer, &jit_buffer);

    // Verify JMP was written
    try std.testing.expectEqual(@as(u8, 0xE9), fn_buffer[0]);

    // Restore
    restore_entry(&patch);

    // Check original bytes restored
    try std.testing.expectEqual(@as(u8, 0x55), fn_buffer[0]);
    try std.testing.expectEqual(@as(u8, 0x48), fn_buffer[1]);
    try std.testing.expectEqual(@as(u8, 0x89), fn_buffer[2]);
    try std.testing.expectEqual(@as(u8, 0xE5), fn_buffer[3]);
    try std.testing.expectEqual(@as(u8, 0x90), fn_buffer[4]);

    // Check patch is no longer active
    try std.testing.expect(!patch.is_patched);
}

test "restore_entry does nothing if not patched" {
    var buffer: [16]u8 = .{ 0x55, 0x48, 0x89, 0xE5, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90 };
    var patch = PatchPoint.init(&buffer);

    // Should not crash or change anything
    restore_entry(&patch);

    // Buffer should be unchanged
    try std.testing.expectEqual(@as(u8, 0x55), buffer[0]);
    try std.testing.expect(!patch.is_patched);
}

test "patch_entry calculates correct relative offset" {
    // Use a larger buffer with known layout
    var memory: [256]u8 = undefined;
    @memset(&memory, 0x90);

    // Function at start of buffer
    const fn_ptr: [*]u8 = &memory;
    // JIT code at offset 128
    const jit_ptr: [*]u8 = memory[128..].ptr;

    const patch = patch_entry(fn_ptr, jit_ptr);
    _ = patch;

    // JMP should be written
    try std.testing.expectEqual(@as(u8, 0xE9), memory[0]);

    // rel32 = target - (source + 5) = 128 - 5 = 123 = 0x7B
    try std.testing.expectEqual(@as(u8, 0x7B), memory[1]);
    try std.testing.expectEqual(@as(u8, 0x00), memory[2]);
    try std.testing.expectEqual(@as(u8, 0x00), memory[3]);
    try std.testing.expectEqual(@as(u8, 0x00), memory[4]);
}

test "patch and restore cycle" {
    var buffer: [16]u8 = .{ 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99 };
    var jit: [16]u8 = undefined;

    // Patch
    var patch = patch_entry(&buffer, &jit);
    try std.testing.expectEqual(@as(u8, 0xE9), buffer[0]);
    try std.testing.expect(patch.is_patched);

    // Restore
    restore_entry(&patch);
    try std.testing.expectEqual(@as(u8, 0xAA), buffer[0]);
    try std.testing.expectEqual(@as(u8, 0xBB), buffer[1]);
    try std.testing.expectEqual(@as(u8, 0xCC), buffer[2]);
    try std.testing.expectEqual(@as(u8, 0xDD), buffer[3]);
    try std.testing.expectEqual(@as(u8, 0xEE), buffer[4]);
    try std.testing.expect(!patch.is_patched);

    // Patch again
    patch = patch_entry(&buffer, &jit);
    try std.testing.expectEqual(@as(u8, 0xE9), buffer[0]);
    try std.testing.expect(patch.is_patched);
}
