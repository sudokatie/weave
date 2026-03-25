// WASM module parsing

const std = @import("std");
const Reader = @import("reader.zig").Reader;
const types = @import("types.zig");

pub const Module = struct {
    types: []types.FuncType,
    funcs: []u32,
    tables: []types.TableType,
    mems: []types.Limits,
    globals: []Global,
    exports: []Export,
    imports: []Import,
    start: ?u32,
    code: []Code,
    data: []Data,
    allocator: std.mem.Allocator,

    pub const Global = struct {
        global_type: types.GlobalType,
        init: []const u8, // Init expression bytes
    };

    pub const Export = struct {
        name: []const u8,
        kind: ExportKind,
        index: u32,
    };

    pub const ExportKind = enum(u8) {
        func = 0,
        table = 1,
        mem = 2,
        global = 3,
    };

    pub const Import = struct {
        module: []const u8,
        name: []const u8,
        kind: ImportKind,
    };

    pub const ImportKind = union(enum) {
        func: u32, // Type index
        table: types.TableType,
        mem: types.Limits,
        global: types.GlobalType,
    };

    pub const Code = struct {
        locals: []Local,
        body: []const u8,
    };

    pub const Local = struct {
        count: u32,
        val_type: types.ValType,
    };

    pub const Data = struct {
        mem_idx: u32,
        offset: []const u8, // Init expression
        init: []const u8,
    };

    const MAGIC = "\x00asm";
    const VERSION: u32 = 1;

    pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !Module {
        var reader = Reader.init(bytes);

        // Check magic number
        const magic = try reader.readBytes(4);
        if (!std.mem.eql(u8, magic, MAGIC)) return error.InvalidMagic;

        // Check version
        const version = std.mem.readInt(u32, (try reader.readBytes(4))[0..4], .little);
        if (version != VERSION) return error.UnsupportedVersion;

        var module = Module{
            .types = &.{},
            .funcs = &.{},
            .tables = &.{},
            .mems = &.{},
            .globals = &.{},
            .exports = &.{},
            .imports = &.{},
            .start = null,
            .code = &.{},
            .data = &.{},
            .allocator = allocator,
        };
        errdefer module.deinit();

        // Parse sections
        while (!reader.atEnd()) {
            const section_id = try reader.readByte();
            const section_size = try reader.readU32Leb128();
            const section_end = reader.position + section_size;

            switch (section_id) {
                0 => try reader.skip(section_size), // Custom section
                1 => module.types = try parseTypeSection(&reader, allocator), // Type
                2 => module.imports = try parseImportSection(&reader, allocator), // Import
                3 => module.funcs = try parseFunctionSection(&reader, allocator), // Function
                4 => module.tables = try parseTableSection(&reader, allocator), // Table
                5 => module.mems = try parseMemorySection(&reader, allocator), // Memory
                6 => module.globals = try parseGlobalSection(&reader, allocator), // Global
                7 => module.exports = try parseExportSection(&reader, allocator), // Export
                8 => module.start = try reader.readU32Leb128(), // Start
                9 => try reader.skip(section_size), // Element (TODO)
                10 => module.code = try parseCodeSection(&reader, allocator), // Code
                11 => module.data = try parseDataSection(&reader, allocator), // Data
                else => try reader.skip(section_size), // Unknown
            }

            // Ensure we consumed exactly section_size bytes
            if (reader.position != section_end) {
                if (reader.position < section_end) {
                    try reader.skip(section_end - reader.position);
                } else {
                    return error.SectionOverflow;
                }
            }
        }

        return module;
    }

    fn parseTypeSection(reader: *Reader, allocator: std.mem.Allocator) ![]types.FuncType {
        const count = try reader.readU32Leb128();
        var result = try allocator.alloc(types.FuncType, count);
        errdefer allocator.free(result);

        for (0..count) |i| {
            result[i] = try types.FuncType.read(reader, allocator);
        }

        return result;
    }

    fn parseImportSection(reader: *Reader, allocator: std.mem.Allocator) ![]Import {
        const count = try reader.readU32Leb128();
        var result = try allocator.alloc(Import, count);
        errdefer allocator.free(result);

        for (0..count) |i| {
            const module_name = try reader.readName();
            const name = try reader.readName();
            const kind_byte = try reader.readByte();

            const kind: ImportKind = switch (kind_byte) {
                0 => ImportKind{ .func = try reader.readU32Leb128() },
                1 => ImportKind{ .table = try types.TableType.read(reader) },
                2 => ImportKind{ .mem = try types.Limits.read(reader) },
                3 => ImportKind{ .global = try types.GlobalType.read(reader) },
                else => return error.InvalidImportKind,
            };

            result[i] = Import{
                .module = module_name,
                .name = name,
                .kind = kind,
            };
        }

        return result;
    }

    fn parseFunctionSection(reader: *Reader, allocator: std.mem.Allocator) ![]u32 {
        const count = try reader.readU32Leb128();
        var result = try allocator.alloc(u32, count);
        errdefer allocator.free(result);

        for (0..count) |i| {
            result[i] = try reader.readU32Leb128();
        }

        return result;
    }

    fn parseTableSection(reader: *Reader, allocator: std.mem.Allocator) ![]types.TableType {
        const count = try reader.readU32Leb128();
        var result = try allocator.alloc(types.TableType, count);
        errdefer allocator.free(result);

        for (0..count) |i| {
            result[i] = try types.TableType.read(reader);
        }

        return result;
    }

    fn parseMemorySection(reader: *Reader, allocator: std.mem.Allocator) ![]types.Limits {
        const count = try reader.readU32Leb128();
        var result = try allocator.alloc(types.Limits, count);
        errdefer allocator.free(result);

        for (0..count) |i| {
            result[i] = try types.Limits.read(reader);
        }

        return result;
    }

    fn parseGlobalSection(reader: *Reader, allocator: std.mem.Allocator) ![]Global {
        const count = try reader.readU32Leb128();
        var result = try allocator.alloc(Global, count);
        errdefer allocator.free(result);

        for (0..count) |i| {
            const global_type = try types.GlobalType.read(reader);
            // Read init expression (until 0x0B = end)
            const start = reader.position;
            while ((try reader.readByte()) != 0x0B) {}
            const init = reader.data[start..reader.position];

            result[i] = Global{
                .global_type = global_type,
                .init = init,
            };
        }

        return result;
    }

    fn parseExportSection(reader: *Reader, allocator: std.mem.Allocator) ![]Export {
        const count = try reader.readU32Leb128();
        var result = try allocator.alloc(Export, count);
        errdefer allocator.free(result);

        for (0..count) |i| {
            const name = try reader.readName();
            const kind_byte = try reader.readByte();
            const index = try reader.readU32Leb128();

            result[i] = Export{
                .name = name,
                .kind = @enumFromInt(kind_byte),
                .index = index,
            };
        }

        return result;
    }

    fn parseCodeSection(reader: *Reader, allocator: std.mem.Allocator) ![]Code {
        const count = try reader.readU32Leb128();
        var result = try allocator.alloc(Code, count);
        errdefer allocator.free(result);

        for (0..count) |i| {
            const code_size = try reader.readU32Leb128();
            const code_end = reader.position + code_size;

            // Parse locals
            const local_count = try reader.readU32Leb128();
            var locals = try allocator.alloc(Local, local_count);
            errdefer allocator.free(locals);

            for (0..local_count) |j| {
                locals[j] = Local{
                    .count = try reader.readU32Leb128(),
                    .val_type = try types.ValType.read(reader),
                };
            }

            // Body is the rest until code_end
            const body = reader.data[reader.position..code_end];
            reader.position = code_end;

            result[i] = Code{
                .locals = locals,
                .body = body,
            };
        }

        return result;
    }

    fn parseDataSection(reader: *Reader, allocator: std.mem.Allocator) ![]Data {
        const count = try reader.readU32Leb128();
        var result = try allocator.alloc(Data, count);
        errdefer allocator.free(result);

        for (0..count) |i| {
            const mem_idx = try reader.readU32Leb128();

            // Read offset expression (until 0x0B)
            const offset_start = reader.position;
            while ((try reader.readByte()) != 0x0B) {}
            const offset = reader.data[offset_start..reader.position];

            // Read data bytes
            const data_len = try reader.readU32Leb128();
            const init = try reader.readBytes(data_len);

            result[i] = Data{
                .mem_idx = mem_idx,
                .offset = offset,
                .init = init,
            };
        }

        return result;
    }

    pub fn deinit(self: *Module) void {
        for (self.types) |*t| {
            var ft = t.*;
            ft.deinit();
        }
        if (self.types.len > 0) self.allocator.free(self.types);
        if (self.funcs.len > 0) self.allocator.free(self.funcs);
        if (self.tables.len > 0) self.allocator.free(self.tables);
        if (self.mems.len > 0) self.allocator.free(self.mems);
        if (self.globals.len > 0) self.allocator.free(self.globals);
        if (self.exports.len > 0) self.allocator.free(self.exports);
        if (self.imports.len > 0) self.allocator.free(self.imports);
        for (self.code) |*c| {
            if (c.locals.len > 0) self.allocator.free(c.locals);
        }
        if (self.code.len > 0) self.allocator.free(self.code);
        if (self.data.len > 0) self.allocator.free(self.data);
    }
};

// Tests
test "parse minimal module" {
    const allocator = std.testing.allocator;
    // Minimal valid WASM: magic + version only
    const bytes = "\x00asm\x01\x00\x00\x00";
    var module = try Module.parse(allocator, bytes);
    defer module.deinit();

    try std.testing.expectEqual(@as(usize, 0), module.types.len);
    try std.testing.expectEqual(@as(usize, 0), module.funcs.len);
}

test "parse module with type section" {
    const allocator = std.testing.allocator;
    // WASM with one function type: () -> ()
    const bytes = "\x00asm\x01\x00\x00\x00" ++ // Magic + version
        "\x01" ++ // Type section
        "\x04" ++ // Section size
        "\x01" ++ // 1 type
        "\x60\x00\x00"; // functype () -> ()

    var module = try Module.parse(allocator, bytes);
    defer module.deinit();

    try std.testing.expectEqual(@as(usize, 1), module.types.len);
    try std.testing.expectEqual(@as(usize, 0), module.types[0].params.len);
    try std.testing.expectEqual(@as(usize, 0), module.types[0].results.len);
}
