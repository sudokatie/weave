// Weave - WebAssembly Runtime
//
// Usage: weave <command> [options]
//
// Commands:
//   run <file.wasm>      Run a WASM module
//   validate <file.wasm> Validate a WASM module

const std = @import("std");
const lib = @import("lib.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();

    if (args.len < 2) {
        try printUsage(stderr);
        std.process.exit(1);
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        try printUsage(stdout);
        return;
    }

    if (std.mem.eql(u8, command, "--version") or std.mem.eql(u8, command, "-v")) {
        try stdout.writeAll("weave 0.1.0\n");
        return;
    }

    if (std.mem.eql(u8, command, "run")) {
        if (args.len < 3) {
            try stderr.writeAll("error: missing WASM file\n");
            std.process.exit(1);
        }
        const wasm_file = args[2];
        const wasm_args = if (args.len > 3) args[3..] else &[_][]const u8{};
        try runWasm(allocator, wasm_file, wasm_args, stdout, stderr);
    } else if (std.mem.eql(u8, command, "validate")) {
        if (args.len < 3) {
            try stderr.writeAll("error: missing WASM file\n");
            std.process.exit(1);
        }
        const wasm_file = args[2];
        try validateWasm(allocator, wasm_file, stdout, stderr);
    } else {
        try stderr.print("error: unknown command '{s}'\n", .{command});
        try printUsage(stderr);
        std.process.exit(1);
    }
}

fn printUsage(writer: anytype) !void {
    try writer.writeAll(
        \\Usage: weave <command> [options]
        \\
        \\Commands:
        \\  run <file.wasm> [args...]  Run a WASM module
        \\  validate <file.wasm>       Validate a WASM module
        \\
        \\Options:
        \\  --help, -h     Show this help
        \\  --version, -v  Show version
        \\
    );
}

fn runWasm(allocator: std.mem.Allocator, path: []const u8, wasm_args: []const []const u8, stdout: anytype, stderr: anytype) !void {
    _ = wasm_args;
    _ = stdout;

    // Read WASM file
    const bytes = std.fs.cwd().readFileAlloc(allocator, path, 100 * 1024 * 1024) catch |err| {
        try stderr.print("error: could not read '{s}': {any}\n", .{ path, err });
        std.process.exit(1);
    };
    defer allocator.free(bytes);

    // Parse module
    var module = lib.binary.Module.parse(allocator, bytes) catch |err| {
        try stderr.print("error: invalid WASM module: {any}\n", .{err});
        std.process.exit(1);
    };
    defer module.deinit();

    // TODO: Instantiate and run
    try stderr.writeAll("note: execution not yet implemented\n");
}

fn validateWasm(allocator: std.mem.Allocator, path: []const u8, stdout: anytype, stderr: anytype) !void {
    // Read WASM file
    const bytes = std.fs.cwd().readFileAlloc(allocator, path, 100 * 1024 * 1024) catch |err| {
        try stderr.print("error: could not read '{s}': {any}\n", .{ path, err });
        std.process.exit(1);
    };
    defer allocator.free(bytes);

    // Parse module
    var module = lib.binary.Module.parse(allocator, bytes) catch |err| {
        try stderr.print("error: invalid WASM module: {any}\n", .{err});
        std.process.exit(1);
    };
    defer module.deinit();

    try stdout.print("{s}: valid WASM module\n", .{path});
}
