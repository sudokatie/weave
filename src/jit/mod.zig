// JIT compilation module

pub const hotpath = @import("hotpath.zig");

pub const HotPathDetector = hotpath.HotPathDetector;

test {
    _ = hotpath;
}
