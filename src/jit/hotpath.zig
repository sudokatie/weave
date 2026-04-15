// Hot path detection for JIT compilation
//
// Tracks function call counts and identifies functions that exceed a
// configurable threshold, indicating they are "hot" and candidates for
// JIT compilation.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const HotPathDetector = struct {
    call_counts: std.AutoHashMap(u32, u64),
    compiled: std.AutoHashMap(u32, bool),
    threshold: u32,
    allocator: Allocator,

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return Self{
            .call_counts = std.AutoHashMap(u32, u64).init(allocator),
            .compiled = std.AutoHashMap(u32, bool).init(allocator),
            .threshold = 1000,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.call_counts.deinit();
        self.compiled.deinit();
    }

    /// Record a function call. Returns true when the threshold is first
    /// crossed and the function has not already been marked as compiled.
    pub fn record_call(self: *Self, fn_index: u32) bool {
        const current = self.call_counts.get(fn_index) orelse 0;
        const new_count = current + 1;
        self.call_counts.put(fn_index, new_count) catch return false;

        // Return true only when we first cross the threshold and not already compiled
        if (new_count >= self.threshold and current < self.threshold) {
            if (self.compiled.get(fn_index)) |_| {
                return false;
            }
            return true;
        }
        return false;
    }

    /// Check if a function's call count meets or exceeds the threshold.
    pub fn is_hot(self: *Self, fn_index: u32) bool {
        const count = self.call_counts.get(fn_index) orelse 0;
        return count >= self.threshold;
    }

    /// Mark a function as compiled so record_call won't return true again.
    pub fn mark_compiled(self: *Self, fn_index: u32) void {
        self.compiled.put(fn_index, true) catch {};
    }

    /// Get the current call count for a function.
    pub fn get_count(self: *Self, fn_index: u32) u64 {
        return self.call_counts.get(fn_index) orelse 0;
    }

    /// Clear all call counts and compiled markers.
    pub fn reset(self: *Self) void {
        self.call_counts.clearRetainingCapacity();
        self.compiled.clearRetainingCapacity();
    }

    /// Change the threshold for hot path detection.
    pub fn set_threshold(self: *Self, threshold: u32) void {
        self.threshold = threshold;
    }
};

test "init and deinit" {
    var detector = HotPathDetector.init(std.testing.allocator);
    defer detector.deinit();

    try std.testing.expectEqual(@as(u32, 1000), detector.threshold);
}

test "record_call increments count" {
    var detector = HotPathDetector.init(std.testing.allocator);
    defer detector.deinit();

    _ = detector.record_call(0);
    try std.testing.expectEqual(@as(u64, 1), detector.get_count(0));

    _ = detector.record_call(0);
    try std.testing.expectEqual(@as(u64, 2), detector.get_count(0));
}

test "record_call returns true when threshold first crossed" {
    var detector = HotPathDetector.init(std.testing.allocator);
    defer detector.deinit();
    detector.set_threshold(3);

    try std.testing.expect(!detector.record_call(0)); // count = 1
    try std.testing.expect(!detector.record_call(0)); // count = 2
    try std.testing.expect(detector.record_call(0)); // count = 3, threshold crossed
    try std.testing.expect(!detector.record_call(0)); // count = 4, already past threshold
}

test "record_call returns false when already compiled" {
    var detector = HotPathDetector.init(std.testing.allocator);
    defer detector.deinit();
    detector.set_threshold(2);

    _ = detector.record_call(0); // count = 1
    detector.mark_compiled(0);
    try std.testing.expect(!detector.record_call(0)); // count = 2, but already compiled
}

test "is_hot returns correct state" {
    var detector = HotPathDetector.init(std.testing.allocator);
    defer detector.deinit();
    detector.set_threshold(2);

    try std.testing.expect(!detector.is_hot(0));
    _ = detector.record_call(0);
    try std.testing.expect(!detector.is_hot(0));
    _ = detector.record_call(0);
    try std.testing.expect(detector.is_hot(0));
}

test "reset clears all state" {
    var detector = HotPathDetector.init(std.testing.allocator);
    defer detector.deinit();
    detector.set_threshold(2);

    _ = detector.record_call(0);
    _ = detector.record_call(0);
    detector.mark_compiled(0);

    try std.testing.expectEqual(@as(u64, 2), detector.get_count(0));
    try std.testing.expect(detector.is_hot(0));

    detector.reset();

    try std.testing.expectEqual(@as(u64, 0), detector.get_count(0));
    try std.testing.expect(!detector.is_hot(0));

    // After reset, record_call should trigger again at threshold
    _ = detector.record_call(0);
    try std.testing.expect(detector.record_call(0)); // should return true since compiled was cleared
}

test "multiple functions tracked independently" {
    var detector = HotPathDetector.init(std.testing.allocator);
    defer detector.deinit();
    detector.set_threshold(2);

    _ = detector.record_call(0);
    _ = detector.record_call(1);
    _ = detector.record_call(1);

    try std.testing.expectEqual(@as(u64, 1), detector.get_count(0));
    try std.testing.expectEqual(@as(u64, 2), detector.get_count(1));
    try std.testing.expect(!detector.is_hot(0));
    try std.testing.expect(detector.is_hot(1));
}

test "set_threshold changes detection boundary" {
    var detector = HotPathDetector.init(std.testing.allocator);
    defer detector.deinit();

    try std.testing.expectEqual(@as(u32, 1000), detector.threshold);
    detector.set_threshold(500);
    try std.testing.expectEqual(@as(u32, 500), detector.threshold);

    // Function with count below new threshold should not be hot
    var i: u32 = 0;
    while (i < 499) : (i += 1) {
        _ = detector.record_call(0);
    }
    try std.testing.expect(!detector.is_hot(0));

    // One more call should make it hot
    try std.testing.expect(detector.record_call(0));
    try std.testing.expect(detector.is_hot(0));
}
