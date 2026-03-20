// Binary parsing module

pub const reader = @import("reader.zig");
pub const types = @import("types.zig");
pub const module = @import("module.zig");
pub const instructions = @import("instructions.zig");

pub const Reader = reader.Reader;
pub const Module = module.Module;
pub const ValType = types.ValType;
pub const FuncType = types.FuncType;
pub const Limits = types.Limits;
pub const TableType = types.TableType;
pub const GlobalType = types.GlobalType;
pub const BlockType = types.BlockType;
pub const Opcode = instructions.Opcode;
pub const Instruction = instructions.Instruction;
pub const Immediate = instructions.Immediate;

test {
    _ = reader;
    _ = types;
    _ = module;
    _ = instructions;
}
