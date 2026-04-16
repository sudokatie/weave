// JIT compilation module

pub const hotpath = @import("hotpath.zig");
pub const x86 = @import("x86.zig");
pub const patch = @import("patch.zig");

pub const HotPathDetector = hotpath.HotPathDetector;
pub const X86CodeGen = x86.X86CodeGen;
pub const PatchPoint = patch.PatchPoint;

test {
    _ = hotpath;
    _ = x86;
    _ = patch;
}
