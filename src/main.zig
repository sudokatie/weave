// Weave - WebAssembly Runtime
//
// Usage: weave <command> [options]
//
// Commands:
//   run <file.wasm>      Run a WASM module
//   validate <file.wasm> Validate a WASM module

const std = @import("std");
const lib = @import("lib.zig");

// Simple stdout/stderr wrappers for Zig 0.15 compatibility
const StdWriter = struct {
    fd: std.posix.fd_t,

    pub fn writeAll(self: @This(), bytes: []const u8) !void {
        var written: usize = 0;
        while (written < bytes.len) {
            written += try std.posix.write(self.fd, bytes[written..]);
        }
    }

    pub fn print(self: @This(), comptime fmt: []const u8, args: anytype) !void {
        var buf: [4096]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, fmt, args) catch {
            try self.writeAll("<format error>");
            return;
        };
        try self.writeAll(s);
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const stdout = StdWriter{ .fd = 1 };
    const stderr = StdWriter{ .fd = 2 };

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

    // Validate module
    var validator = lib.validate.Validator.init(allocator, &module);
    defer validator.deinit();
    validator.validate() catch |err| {
        try stderr.print("error: validation failed: {any}\n", .{err});
        std.process.exit(1);
    };

    // Set up WASI
    var wasi_config = lib.wasi.WasiConfig.init(allocator);
    _ = wasi_config.withArgs(wasm_args);

    var wasi = lib.wasi.Wasi.init(wasi_config);

    // Create store and instantiate
    var store = lib.runtime.Store.init(allocator);
    defer store.deinit();

    const instance = store.instantiate(&module) catch |err| {
        try stderr.print("error: instantiation failed: {any}\n", .{err});
        std.process.exit(1);
    };

    // Set up memory for WASI
    if (store.mems.items.len > 0) {
        wasi.setMemory(store.getMemory(0));
    }

    // Look for _start or main export
    const start_export = instance.getExport("_start") orelse instance.getExport("main");
    if (start_export) |exp| {
        if (exp.kind != .func) {
            try stderr.writeAll("error: _start is not a function\n");
            std.process.exit(1);
        }

        // Create interpreter and run
        var interp = lib.runtime.Interpreter.init(allocator, &module);
        defer interp.deinit();

        if (store.mems.items.len > 0) {
            interp.memory = store.getMemory(0);
        }

        // Call with no arguments (WASI _start takes no params)
        const results = interp.call(exp.addr, &.{}) catch |err| {
            try stderr.print("error: execution failed: {any}\n", .{err});
            std.process.exit(1);
        };
        allocator.free(results);
    } else if (module.start) |start_idx| {
        // Use start section
        var interp = lib.runtime.Interpreter.init(allocator, &module);
        defer interp.deinit();

        if (store.mems.items.len > 0) {
            interp.memory = store.getMemory(0);
        }

        const results = interp.call(start_idx, &.{}) catch |err| {
            try stderr.print("error: execution failed: {any}\n", .{err});
            std.process.exit(1);
        };
        allocator.free(results);
    } else {
        try stderr.writeAll("error: no _start, main, or start section found\n");
        std.process.exit(1);
    }
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
        try stderr.print("error: parse failed: {any}\n", .{err});
        std.process.exit(1);
    };
    defer module.deinit();

    // Validate module
    var validator = lib.validate.Validator.init(allocator, &module);
    defer validator.deinit();
    validator.validate() catch |err| {
        try stderr.print("error: validation failed: {any}\n", .{err});
        std.process.exit(1);
    };

    // Print module info
    try stdout.print("{s}: valid WASM module\n", .{path});
    try stdout.print("  types:     {d}\n", .{module.types.len});
    try stdout.print("  functions: {d}\n", .{module.funcs.len});
    try stdout.print("  tables:    {d}\n", .{module.tables.len});
    try stdout.print("  memories:  {d}\n", .{module.mems.len});
    try stdout.print("  globals:   {d}\n", .{module.globals.len});
    try stdout.print("  exports:   {d}\n", .{module.exports.len});
    try stdout.print("  imports:   {d}\n", .{module.imports.len});
}
