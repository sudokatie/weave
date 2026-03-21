// Benchmarks for weave

const std = @import("std");
const binary = @import("binary/mod.zig");
const runtime = @import("runtime/mod.zig");
const validate = @import("validate/mod.zig");

// Simple add module for benchmarking
fn buildAddModule() []const u8 {
    return &[_]u8{
        0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x07, 0x01, 0x60, 0x02, 0x7F, 0x7F, 0x01, 0x7F,
        0x03, 0x02, 0x01, 0x00,
        0x07, 0x07, 0x01, 0x03, 'a', 'd', 'd', 0x00, 0x00,
        0x0A, 0x09, 0x01, 0x07, 0x00, 0x20, 0x00, 0x20, 0x01, 0x6A, 0x0B,
    };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const iterations: usize = 10_000;
    const wasm = buildAddModule();

    // Benchmark: Module parsing
    {
        const start = std.time.nanoTimestamp();
        for (0..iterations) |_| {
            var module = try binary.Module.parse(allocator, wasm);
            module.deinit();
        }
        const elapsed = std.time.nanoTimestamp() - start;
        const ns_per_op = @divFloor(elapsed, iterations);
        const ops_per_sec = @divFloor(1_000_000_000 * iterations, @as(u64, @intCast(elapsed)));
        std.debug.print("Module parse:    {d} ns/op ({d} ops/sec)\n", .{ ns_per_op, ops_per_sec });
    }

    // Benchmark: Validation
    {
        var module = try binary.Module.parse(allocator, wasm);
        defer module.deinit();

        const start = std.time.nanoTimestamp();
        for (0..iterations) |_| {
            var validator = validate.Validator.init(allocator, &module);
            defer validator.deinit();
            try validator.validate();
        }
        const elapsed = std.time.nanoTimestamp() - start;
        const ns_per_op = @divFloor(elapsed, iterations);
        const ops_per_sec = @divFloor(1_000_000_000 * iterations, @as(u64, @intCast(elapsed)));
        std.debug.print("Validation:      {d} ns/op ({d} ops/sec)\n", .{ ns_per_op, ops_per_sec });
    }

    // Benchmark: Function call
    {
        var module = try binary.Module.parse(allocator, wasm);
        defer module.deinit();

        var interp = runtime.Interpreter.init(allocator, &module);
        defer interp.deinit();

        const args = [_]runtime.Value{ .{ .i32 = 10 }, .{ .i32 = 32 } };

        const start = std.time.nanoTimestamp();
        for (0..iterations) |_| {
            const results = try interp.call(0, &args);
            allocator.free(results);
        }
        const elapsed = std.time.nanoTimestamp() - start;
        const ns_per_op = @divFloor(elapsed, iterations);
        const ops_per_sec = @divFloor(1_000_000_000 * iterations, @as(u64, @intCast(elapsed)));
        std.debug.print("Function call:   {d} ns/op ({d} ops/sec)\n", .{ ns_per_op, ops_per_sec });
    }

    std.debug.print("\nBenchmarks complete ({d} iterations each)\n", .{iterations});
}
