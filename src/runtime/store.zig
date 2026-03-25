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
            // TODO: evaluate init expression
            const glob = Global.init(module.globals[i].global_type, Value{ .i32 = 0 });
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
                // Evaluate offset (simple case: i32.const followed by end)
                const offset = evalConstExpr(data.offset);
                mem.fill(offset, data.init) catch {};
            }
        }

        // Initialize element segments
        for (module.elements) |elem| {
            if (elem.table_idx < table_addrs.len) {
                const tbl = self.getTable(table_addrs[elem.table_idx]);
                const offset = evalConstExpr(elem.offset);
                for (elem.init, 0..) |func_idx, i| {
                    tbl.set(offset + @as(u32, @intCast(i)), func_idx) catch {};
                }
            }
        }

        return instance;
    }

    /// Evaluate a constant expression (simplified: only handles i32.const)
    fn evalConstExpr(expr: []const u8) u32 {
        if (expr.len >= 2 and expr[0] == 0x41) { // i32.const
            // Simple LEB128 decode
            var result: u32 = 0;
            var shift: u5 = 0;
            for (expr[1..]) |byte| {
                result |= @as(u32, byte & 0x7F) << shift;
                if (byte & 0x80 == 0) break;
                shift +|= 7;
            }
            return result;
        }
        return 0;
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
