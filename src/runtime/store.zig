// WASM Store and Module Instances

const std = @import("std");
const binary = @import("../binary/mod.zig");
const memory_mod = @import("memory.zig");
const table_mod = @import("table.zig");
const stack_mod = @import("stack.zig");

const Memory = memory_mod.Memory;
const Table = table_mod.Table;
const Global = table_mod.Global;
const Value = stack_mod.Value;

/// Error types for init expression evaluation
pub const InitExprError = error{
    UnexpectedEof,
    InvalidInitExpression,
    InvalidGlobalIndex,
    LEB128Overflow,
};

/// Address types for store
pub const FuncAddr = u32;
pub const TableAddr = u32;
pub const MemAddr = u32;
pub const GlobalAddr = u32;

/// Function instance
pub const FuncInst = struct {
    type_idx: u32,
    module_idx: u32,
    code_idx: u32,
};

/// Module instance - runtime representation of an instantiated module
pub const Instance = struct {
    func_addrs: []FuncAddr,
    table_addrs: []TableAddr,
    mem_addrs: []MemAddr,
    global_addrs: []GlobalAddr,
    exports: std.StringHashMap(ExportValue),
    allocator: std.mem.Allocator,

    pub const ExportValue = struct {
        kind: binary.Module.ExportKind,
        addr: u32,
    };

    pub fn deinit(self: *Instance) void {
        if (self.func_addrs.len > 0) self.allocator.free(self.func_addrs);
        if (self.table_addrs.len > 0) self.allocator.free(self.table_addrs);
        if (self.mem_addrs.len > 0) self.allocator.free(self.mem_addrs);
        if (self.global_addrs.len > 0) self.allocator.free(self.global_addrs);
        self.exports.deinit();
    }

    pub fn getExport(self: *Instance, name: []const u8) ?ExportValue {
        return self.exports.get(name);
    }
};

/// Store - holds all runtime objects
pub const Store = struct {
    funcs: std.ArrayList(FuncInst),
    tables: std.ArrayList(Table),
    mems: std.ArrayList(Memory),
    globals: std.ArrayList(Global),
    instances: std.ArrayList(Instance),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Store {
        return Store{
            .funcs = std.ArrayList(FuncInst).empty,
            .tables = std.ArrayList(Table).empty,
            .mems = std.ArrayList(Memory).empty,
            .globals = std.ArrayList(Global).empty,
            .instances = std.ArrayList(Instance).empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Store) void {
        for (self.tables.items) |*t| t.deinit();
        for (self.mems.items) |*m| m.deinit();
        for (self.instances.items) |*i| i.deinit();

        self.funcs.deinit(self.allocator);
        self.tables.deinit(self.allocator);
        self.mems.deinit(self.allocator);
        self.globals.deinit(self.allocator);
        self.instances.deinit(self.allocator);
    }

    /// Instantiate a module
    pub fn instantiate(self: *Store, module: *binary.Module) !*Instance {
        const module_idx: u32 = @intCast(self.instances.items.len);

        // Allocate function addresses
        var func_addrs = try self.allocator.alloc(FuncAddr, module.funcs.len);
        for (0..module.funcs.len) |i| {
            const addr: FuncAddr = @intCast(self.funcs.items.len);
            try self.funcs.append(self.allocator, FuncInst{
                .type_idx = module.funcs[i],
                .module_idx = module_idx,
                .code_idx = @intCast(i),
            });
            func_addrs[i] = addr;
        }

        // Allocate memory addresses
        var mem_addrs = try self.allocator.alloc(MemAddr, module.mems.len);
        for (0..module.mems.len) |i| {
            const addr: MemAddr = @intCast(self.mems.items.len);
            const mem = try Memory.init(self.allocator, module.mems[i].min, module.mems[i].max);
            try self.mems.append(self.allocator, mem);
            mem_addrs[i] = addr;
        }

        // Allocate table addresses
        var table_addrs = try self.allocator.alloc(TableAddr, module.tables.len);
        for (0..module.tables.len) |i| {
            const addr: TableAddr = @intCast(self.tables.items.len);
            const tbl = try Table.init(self.allocator, module.tables[i]);
            try self.tables.append(self.allocator, tbl);
            table_addrs[i] = addr;
        }

        // Allocate global addresses
        var global_addrs = try self.allocator.alloc(GlobalAddr, module.globals.len);
        for (0..module.globals.len) |i| {
            const addr: GlobalAddr = @intCast(self.globals.items.len);
            // Evaluate the init expression for this global
            const init_value = self.evaluateInitExpr(module.globals[i].init) catch
                Value.fromValType(module.globals[i].global_type.val_type);
            const glob = Global.init(module.globals[i].global_type, init_value);
            try self.globals.append(self.allocator, glob);
            global_addrs[i] = addr;
        }

        // Build exports map
        var exports = std.StringHashMap(Instance.ExportValue).init(self.allocator);
        for (module.exports) |exp| {
            const addr = switch (exp.kind) {
                .func => func_addrs[exp.index],
                .table => table_addrs[exp.index],
                .mem => mem_addrs[exp.index],
                .global => global_addrs[exp.index],
            };
            try exports.put(exp.name, Instance.ExportValue{
                .kind = exp.kind,
                .addr = addr,
            });
        }

        // Create instance
        try self.instances.append(self.allocator, Instance{
            .func_addrs = func_addrs,
            .table_addrs = table_addrs,
            .mem_addrs = mem_addrs,
            .global_addrs = global_addrs,
            .exports = exports,
            .allocator = self.allocator,
        });

        const instance = &self.instances.items[self.instances.items.len - 1];

        // Initialize data segments
        for (module.data) |data| {
            if (data.mem_idx < mem_addrs.len) {
                const mem = self.getMemory(mem_addrs[data.mem_idx]);
                // Evaluate offset expression
                const offset = self.evalConstExpr(data.offset);
                mem.fill(offset, data.init) catch {};
            }
        }

        // Initialize element segments
        for (module.elements) |elem| {
            if (elem.table_idx < table_addrs.len) {
                const tbl = self.getTable(table_addrs[elem.table_idx]);
                const offset = self.evalConstExpr(elem.offset);
                for (elem.init, 0..) |func_idx, i| {
                    tbl.set(offset + @as(u32, @intCast(i)), func_idx) catch {};
                }
            }
        }

        return instance;
    }

    /// Evaluate a constant init expression and return the resulting Value
    /// Handles: i32.const, i64.const, f32.const, f64.const, global.get, end
    pub fn evaluateInitExpr(self: *Store, expr: []const u8) InitExprError!Value {
        var reader = binary.Reader.init(expr);

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
                    if (idx >= self.globals.items.len) return error.InvalidGlobalIndex;
                    return self.globals.items[idx].value;
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

    /// Evaluate a constant expression (simple version for offsets, returns u32)
    fn evalConstExpr(self: *Store, expr: []const u8) u32 {
        const val = self.evaluateInitExpr(expr) catch return 0;
        return switch (val) {
            .i32 => |v| @bitCast(v),
            .i64 => |v| @truncate(@as(u64, @bitCast(v))),
            else => 0,
        };
    }

    pub fn getFunc(self: *Store, addr: FuncAddr) *FuncInst {
        return &self.funcs.items[addr];
    }

    pub fn getMemory(self: *Store, addr: MemAddr) *Memory {
        return &self.mems.items[addr];
    }

    pub fn getTable(self: *Store, addr: TableAddr) *Table {
        return &self.tables.items[addr];
    }

    pub fn getGlobal(self: *Store, addr: GlobalAddr) *Global {
        return &self.globals.items[addr];
    }
};

// Tests
test "store init" {
    const allocator = std.testing.allocator;
    var store = Store.init(allocator);
    defer store.deinit();

    try std.testing.expectEqual(@as(usize, 0), store.funcs.items.len);
}

test "store instantiate simple module" {
    const allocator = std.testing.allocator;

    // Minimal module with one function
    const wasm = "\x00asm\x01\x00\x00\x00" ++
        "\x01\x05\x01\x60\x00\x01\x7f" ++ // type section: () -> i32
        "\x03\x02\x01\x00" ++ // function section: 1 func, type 0
        "\x07\x08\x01\x04test\x00\x00" ++ // export section: "test" -> func 0
        "\x0a\x06\x01\x04\x00\x41\x2a\x0b"; // code section: i32.const 42, end

    var module = try binary.Module.parse(allocator, wasm);
    defer module.deinit();

    var store = Store.init(allocator);
    defer store.deinit();

    const instance = try store.instantiate(&module);

    // Check export exists
    const exp = instance.getExport("test");
    try std.testing.expect(exp != null);
    try std.testing.expectEqual(binary.Module.ExportKind.func, exp.?.kind);
}

// Init expression evaluation tests
test "evaluateInitExpr i32.const" {
    const allocator = std.testing.allocator;
    var store = Store.init(allocator);
    defer store.deinit();

    // i32.const 42, end
    const expr = &[_]u8{ 0x41, 0x2a, 0x0b };
    const val = try store.evaluateInitExpr(expr);
    try std.testing.expectEqual(@as(i32, 42), val.i32);
}

test "evaluateInitExpr i32.const negative" {
    const allocator = std.testing.allocator;
    var store = Store.init(allocator);
    defer store.deinit();

    // i32.const -1 (0x7f in signed LEB128), end
    const expr = &[_]u8{ 0x41, 0x7f, 0x0b };
    const val = try store.evaluateInitExpr(expr);
    try std.testing.expectEqual(@as(i32, -1), val.i32);
}

test "evaluateInitExpr i64.const" {
    const allocator = std.testing.allocator;
    var store = Store.init(allocator);
    defer store.deinit();

    // i64.const 100, end (100 in signed LEB128 = 0xe4, 0x00)
    const expr = &[_]u8{ 0x42, 0xe4, 0x00, 0x0b };
    const val = try store.evaluateInitExpr(expr);
    try std.testing.expectEqual(@as(i64, 100), val.i64);
}

test "evaluateInitExpr f32.const" {
    const allocator = std.testing.allocator;
    var store = Store.init(allocator);
    defer store.deinit();

    // f32.const 1.0, end (IEEE 754: 0x3f800000)
    const expr = &[_]u8{ 0x43, 0x00, 0x00, 0x80, 0x3f, 0x0b };
    const val = try store.evaluateInitExpr(expr);
    try std.testing.expectEqual(@as(f32, 1.0), val.f32);
}

test "evaluateInitExpr f64.const" {
    const allocator = std.testing.allocator;
    var store = Store.init(allocator);
    defer store.deinit();

    // f64.const 2.0, end (IEEE 754: 0x4000000000000000)
    const expr = &[_]u8{ 0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x40, 0x0b };
    const val = try store.evaluateInitExpr(expr);
    try std.testing.expectEqual(@as(f64, 2.0), val.f64);
}

test "evaluateInitExpr global.get" {
    const allocator = std.testing.allocator;
    var store = Store.init(allocator);
    defer store.deinit();

    // First add a global with value 123
    const glob = Global.init(.{ .val_type = .i32, .mutable = false }, Value{ .i32 = 123 });
    try store.globals.append(allocator, glob);

    // global.get 0, end
    const expr = &[_]u8{ 0x23, 0x00, 0x0b };
    const val = try store.evaluateInitExpr(expr);
    try std.testing.expectEqual(@as(i32, 123), val.i32);
}

test "evaluateInitExpr global.get chained" {
    const allocator = std.testing.allocator;
    var store = Store.init(allocator);
    defer store.deinit();

    // Add first global with value 456
    const glob1 = Global.init(.{ .val_type = .i32, .mutable = false }, Value{ .i32 = 456 });
    try store.globals.append(allocator, glob1);

    // Add second global referencing first (simulated by adding with same value)
    const glob2 = Global.init(.{ .val_type = .i32, .mutable = false }, Value{ .i32 = 456 });
    try store.globals.append(allocator, glob2);

    // global.get 1, end
    const expr = &[_]u8{ 0x23, 0x01, 0x0b };
    const val = try store.evaluateInitExpr(expr);
    try std.testing.expectEqual(@as(i32, 456), val.i32);
}

test "evaluateInitExpr invalid opcode" {
    const allocator = std.testing.allocator;
    var store = Store.init(allocator);
    defer store.deinit();

    // i32.add (not allowed in init expressions), end
    const expr = &[_]u8{ 0x6a, 0x0b };
    try std.testing.expectError(error.InvalidInitExpression, store.evaluateInitExpr(expr));
}

test "evaluateInitExpr invalid global index" {
    const allocator = std.testing.allocator;
    var store = Store.init(allocator);
    defer store.deinit();

    // global.get 99 (doesn't exist), end
    const expr = &[_]u8{ 0x23, 0x63, 0x0b };
    try std.testing.expectError(error.InvalidGlobalIndex, store.evaluateInitExpr(expr));
}

test "evaluateInitExpr empty expression" {
    const allocator = std.testing.allocator;
    var store = Store.init(allocator);
    defer store.deinit();

    // Just end (invalid - no value produced)
    const expr = &[_]u8{0x0b};
    try std.testing.expectError(error.InvalidInitExpression, store.evaluateInitExpr(expr));
}
