// Integration tests - real WASM execution

const std = @import("std");
const binary = @import("binary/mod.zig");
const runtime = @import("runtime/mod.zig");

// Helper to build a simple WASM module
fn buildAddModule() []const u8 {
    // Module that exports add(a: i32, b: i32) -> i32
    return &[_]u8{
        // Magic + version
        0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00,
        // Type section
        0x01, 0x07, // section id=1, size=7
        0x01, // 1 type
        0x60, // functype
        0x02, 0x7F, 0x7F, // 2 params: i32, i32
        0x01, 0x7F, // 1 result: i32
        // Function section
        0x03, 0x02, // section id=3, size=2
        0x01, // 1 function
        0x00, // type index 0
        // Export section
        0x07, 0x07, // section id=7, size=7
        0x01, // 1 export
        0x03, 'a', 'd', 'd', // name "add"
        0x00, // func
        0x00, // index 0
        // Code section
        0x0A, 0x09, // section id=10, size=9
        0x01, // 1 function body
        0x07, // body size=7
        0x00, // 0 locals
        0x20, 0x00, // local.get 0
        0x20, 0x01, // local.get 1
        0x6A, // i32.add
        0x0B, // end
    };
}

fn buildConstModule() []const u8 {
    // Module that exports const42() -> i32 returning 42
    return &[_]u8{
        // Magic + version
        0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00,
        // Type section
        0x01, 0x05, // section id=1, size=5
        0x01, // 1 type
        0x60, // functype
        0x00, // 0 params
        0x01, 0x7F, // 1 result: i32
        // Function section
        0x03, 0x02, // section id=3, size=2
        0x01, // 1 function
        0x00, // type index 0
        // Export section
        0x07, 0x0B, // section id=7, size=11
        0x01, // 1 export
        0x07, 'c', 'o', 'n', 's', 't', '4', '2', // name "const42"
        0x00, // func
        0x00, // index 0
        // Code section
        0x0A, 0x06, // section id=10, size=6
        0x01, // 1 function body
        0x04, // body size=4
        0x00, // 0 locals
        0x41, 0x2A, // i32.const 42
        0x0B, // end
    };
}

test "execute const42" {
    const allocator = std.testing.allocator;
    const wasm = buildConstModule();

    var module = try binary.Module.parse(allocator, wasm);
    defer module.deinit();

    var interp = runtime.Interpreter.init(allocator, &module);
    defer interp.deinit();

    const results = try interp.call(0, &.{});
    defer allocator.free(results);

    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqual(@as(i32, 42), try results[0].asI32());
}

test "execute add" {
    const allocator = std.testing.allocator;
    const wasm = buildAddModule();

    var module = try binary.Module.parse(allocator, wasm);
    defer module.deinit();

    var interp = runtime.Interpreter.init(allocator, &module);
    defer interp.deinit();

    const args = [_]runtime.Value{
        .{ .i32 = 10 },
        .{ .i32 = 32 },
    };
    const results = try interp.call(0, &args);
    defer allocator.free(results);

    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqual(@as(i32, 42), try results[0].asI32());
}
