// WASI - WebAssembly System Interface
//
// Implements WASI preview1 for running WASM programs with system access.
// Supports: fd_write, proc_exit, args/environ, clock, random

const std = @import("std");
const runtime = @import("../runtime/mod.zig");

/// WASI error codes (errno)
pub const Errno = enum(u16) {
    success = 0,
    toobig = 1,
    acces = 2,
    addrinuse = 3,
    addrnotavail = 4,
    afnosupport = 5,
    again = 6,
    already = 7,
    badf = 8,
    badmsg = 9,
    busy = 10,
    canceled = 11,
    child = 12,
    connaborted = 13,
    connrefused = 14,
    connreset = 15,
    deadlk = 16,
    destaddrreq = 17,
    dom = 18,
    dquot = 19,
    exist = 20,
    fault = 21,
    fbig = 22,
    hostunreach = 23,
    idrm = 24,
    ilseq = 25,
    inprogress = 26,
    intr = 27,
    inval = 28,
    io = 29,
    isconn = 30,
    isdir = 31,
    loop = 32,
    mfile = 33,
    mlink = 34,
    msgsize = 35,
    multihop = 36,
    nametoolong = 37,
    netdown = 38,
    netreset = 39,
    netunreach = 40,
    nfile = 41,
    nobufs = 42,
    nodev = 43,
    noent = 44,
    noexec = 45,
    nolck = 46,
    nolink = 47,
    nomem = 48,
    nomsg = 49,
    noprotoopt = 50,
    nospc = 51,
    nosys = 52,
    notconn = 53,
    notdir = 54,
    notempty = 55,
    notrecoverable = 56,
    notsock = 57,
    notsup = 58,
    notty = 59,
    nxio = 60,
    overflow = 61,
    ownerdead = 62,
    perm = 63,
    pipe = 64,
    proto = 65,
    protonosupport = 66,
    prototype = 67,
    range = 68,
    rofs = 69,
    spipe = 70,
    srch = 71,
    stale = 72,
    timedout = 73,
    txtbsy = 74,
    xdev = 75,
    notcapable = 76,
};

/// WASI clock IDs
pub const ClockId = enum(u32) {
    realtime = 0,
    monotonic = 1,
    process_cputime_id = 2,
    thread_cputime_id = 3,
};

/// Ciovec for scatter/gather I/O
pub const Ciovec = struct {
    buf: u32, // Pointer to buffer
    buf_len: u32, // Length of buffer
};

/// WASI configuration
pub const WasiConfig = struct {
    args: []const []const u8 = &.{},
    env: []const [2][]const u8 = &.{}, // [key, value] pairs
    preopens: []const Preopen = &.{},
    exit_code: ?u32 = null,
    allocator: std.mem.Allocator,

    pub const Preopen = struct {
        path: []const u8,
        dir: std.fs.Dir,
    };

    pub fn init(allocator: std.mem.Allocator) WasiConfig {
        return .{ .allocator = allocator };
    }

    pub fn withArgs(self: *WasiConfig, args: []const []const u8) *WasiConfig {
        self.args = args;
        return self;
    }

    pub fn withEnv(self: *WasiConfig, env: []const [2][]const u8) *WasiConfig {
        self.env = env;
        return self;
    }
};

/// WASI context - holds state for WASI calls
pub const Wasi = struct {
    config: WasiConfig,
    memory: ?*runtime.Memory = null,

    pub fn init(config: WasiConfig) Wasi {
        return .{ .config = config };
    }

    pub fn setMemory(self: *Wasi, mem: *runtime.Memory) void {
        self.memory = mem;
    }

    // === WASI Functions ===

    /// fd_write - Write to a file descriptor
    /// Params: fd, iovs_ptr, iovs_len, nwritten_ptr
    /// Returns: errno
    pub fn fd_write(self: *Wasi, fd: u32, iovs_ptr: u32, iovs_len: u32, nwritten_ptr: u32) Errno {
        const mem = self.memory orelse return .fault;

        // Only support stdout (1) and stderr (2)
        if (fd != 1 and fd != 2) return .badf;

        var total_written: u32 = 0;
        var i: u32 = 0;
        while (i < iovs_len) : (i += 1) {
            // Read iovec: buf_ptr (u32) + buf_len (u32)
            const iov_offset = iovs_ptr + i * 8;
            const buf_ptr = mem.loadU32(iov_offset) catch return .fault;
            const buf_len = mem.loadU32(iov_offset + 4) catch return .fault;

            // Get buffer slice
            const buf = mem.slice(buf_ptr, buf_len) catch return .fault;

            // Write to stdout/stderr using posix
            const written = std.posix.write(@intCast(fd), buf) catch return .io;
            total_written += @intCast(written);
        }

        // Write total bytes written
        mem.storeU32(nwritten_ptr, total_written) catch return .fault;
        return .success;
    }

    /// proc_exit - Terminate the process
    /// Params: exit_code
    pub fn proc_exit(self: *Wasi, exit_code: u32) noreturn {
        self.config.exit_code = exit_code;
        std.process.exit(@intCast(exit_code));
    }

    /// args_sizes_get - Get argument count and total size
    /// Params: argc_ptr, argv_buf_size_ptr
    /// Returns: errno
    pub fn args_sizes_get(self: *Wasi, argc_ptr: u32, argv_buf_size_ptr: u32) Errno {
        const mem = self.memory orelse return .fault;

        // Count args and total size
        var total_size: u32 = 0;
        for (self.config.args) |arg| {
            total_size += @intCast(arg.len + 1); // +1 for null terminator
        }

        mem.storeU32(argc_ptr, @intCast(self.config.args.len)) catch return .fault;
        mem.storeU32(argv_buf_size_ptr, total_size) catch return .fault;
        return .success;
    }

    /// args_get - Get arguments
    /// Params: argv_ptr, argv_buf_ptr
    /// Returns: errno
    pub fn args_get(self: *Wasi, argv_ptr: u32, argv_buf_ptr: u32) Errno {
        const mem = self.memory orelse return .fault;

        var buf_offset: u32 = 0;
        for (0..self.config.args.len) |i| {
            const arg = self.config.args[i];

            // Write pointer to argv array
            mem.storeU32(argv_ptr + @as(u32, @intCast(i)) * 4, argv_buf_ptr + buf_offset) catch return .fault;

            // Write string to buffer
            const buf = mem.slice(argv_buf_ptr + buf_offset, @intCast(arg.len + 1)) catch return .fault;
            @memcpy(buf[0..arg.len], arg);
            buf[arg.len] = 0; // Null terminator

            buf_offset += @intCast(arg.len + 1);
        }

        return .success;
    }

    /// environ_sizes_get - Get environment count and total size
    /// Params: count_ptr, buf_size_ptr
    /// Returns: errno
    pub fn environ_sizes_get(self: *Wasi, count_ptr: u32, buf_size_ptr: u32) Errno {
        const mem = self.memory orelse return .fault;

        var total_size: u32 = 0;
        for (self.config.env) |kv| {
            total_size += @intCast(kv[0].len + 1 + kv[1].len + 1); // KEY=VALUE\0
        }

        mem.storeU32(count_ptr, @intCast(self.config.env.len)) catch return .fault;
        mem.storeU32(buf_size_ptr, total_size) catch return .fault;
        return .success;
    }

    /// environ_get - Get environment variables
    /// Params: environ_ptr, environ_buf_ptr
    /// Returns: errno
    pub fn environ_get(self: *Wasi, environ_ptr: u32, environ_buf_ptr: u32) Errno {
        const mem = self.memory orelse return .fault;

        var buf_offset: u32 = 0;
        for (0..self.config.env.len) |i| {
            const kv = self.config.env[i];
            const entry_len = kv[0].len + 1 + kv[1].len + 1; // KEY=VALUE\0

            // Write pointer
            mem.storeU32(environ_ptr + @as(u32, @intCast(i)) * 4, environ_buf_ptr + buf_offset) catch return .fault;

            // Write KEY=VALUE\0
            const buf = mem.slice(environ_buf_ptr + buf_offset, @intCast(entry_len)) catch return .fault;
            @memcpy(buf[0..kv[0].len], kv[0]);
            buf[kv[0].len] = '=';
            @memcpy(buf[kv[0].len + 1 ..][0..kv[1].len], kv[1]);
            buf[entry_len - 1] = 0;

            buf_offset += @intCast(entry_len);
        }

        return .success;
    }

    /// clock_time_get - Get current time
    /// Params: clock_id, precision, time_ptr
    /// Returns: errno
    pub fn clock_time_get(self: *Wasi, clock_id: u32, _: u64, time_ptr: u32) Errno {
        const mem = self.memory orelse return .fault;

        const clock: ClockId = @enumFromInt(clock_id);
        const time: u64 = switch (clock) {
            .realtime => blk: {
                const ts = std.time.nanoTimestamp();
                break :blk @intCast(ts);
            },
            .monotonic => blk: {
                const ts = std.time.nanoTimestamp();
                break :blk @intCast(ts);
            },
            else => return .inval,
        };

        mem.storeU64(time_ptr, time) catch return .fault;
        return .success;
    }

    /// random_get - Fill buffer with random bytes
    /// Params: buf_ptr, buf_len
    /// Returns: errno
    pub fn random_get(self: *Wasi, buf_ptr: u32, buf_len: u32) Errno {
        const mem = self.memory orelse return .fault;

        const buf = mem.slice(buf_ptr, buf_len) catch return .fault;
        std.crypto.random.bytes(buf);
        return .success;
    }

    /// fd_prestat_get - Get preopen info
    /// Params: fd, prestat_ptr
    /// Returns: errno
    pub fn fd_prestat_get(self: *Wasi, fd: u32, prestat_ptr: u32) Errno {
        const mem = self.memory orelse return .fault;

        // fd 0-2 are stdin/stdout/stderr, preopens start at 3
        const preopen_idx = fd -| 3;
        if (preopen_idx >= self.config.preopens.len) return .badf;

        const preopen = &self.config.preopens[preopen_idx];

        // prestat struct: tag (u8) + pad[3] + dir_name_len (u32)
        mem.store(prestat_ptr, 0) catch return .fault; // tag = DIR
        mem.storeU32(prestat_ptr + 4, @intCast(preopen.path.len)) catch return .fault;
        return .success;
    }

    /// fd_prestat_dir_name - Get preopen directory name
    /// Params: fd, path_ptr, path_len
    /// Returns: errno
    pub fn fd_prestat_dir_name(self: *Wasi, fd: u32, path_ptr: u32, path_len: u32) Errno {
        const mem = self.memory orelse return .fault;

        const preopen_idx = fd -| 3;
        if (preopen_idx >= self.config.preopens.len) return .badf;

        const preopen = &self.config.preopens[preopen_idx];
        if (path_len < preopen.path.len) return .nametoolong;

        const buf = mem.slice(path_ptr, @intCast(preopen.path.len)) catch return .fault;
        @memcpy(buf, preopen.path);
        return .success;
    }
};

// Tests
test "wasi init" {
    const allocator = std.testing.allocator;
    const config = WasiConfig.init(allocator);
    var wasi = Wasi.init(config);
    _ = &wasi;
}

test "wasi args_sizes_get" {
    const allocator = std.testing.allocator;

    // Create memory
    var mem = try runtime.Memory.init(allocator, 1, null);
    defer mem.deinit();

    var config = WasiConfig.init(allocator);
    const args = [_][]const u8{ "program", "arg1", "arg2" };
    _ = config.withArgs(&args);

    var wasi = Wasi.init(config);
    wasi.setMemory(&mem);

    const result = wasi.args_sizes_get(0, 4);
    try std.testing.expectEqual(Errno.success, result);

    // Check argc = 3
    const argc = try mem.loadU32(0);
    try std.testing.expectEqual(@as(u32, 3), argc);

    // Check total size = "program\0arg1\0arg2\0" = 8+5+5 = 18
    const buf_size = try mem.loadU32(4);
    try std.testing.expectEqual(@as(u32, 18), buf_size);
}

test "wasi environ_sizes_get" {
    const allocator = std.testing.allocator;

    var mem = try runtime.Memory.init(allocator, 1, null);
    defer mem.deinit();

    var config = WasiConfig.init(allocator);
    const env = [_][2][]const u8{
        .{ "HOME", "/home/user" },
        .{ "PATH", "/bin" },
    };
    _ = config.withEnv(&env);

    var wasi = Wasi.init(config);
    wasi.setMemory(&mem);

    const result = wasi.environ_sizes_get(0, 4);
    try std.testing.expectEqual(Errno.success, result);

    // Check count = 2
    const count = try mem.loadU32(0);
    try std.testing.expectEqual(@as(u32, 2), count);

    // Check total size = "HOME=/home/user\0PATH=/bin\0" = 16+10 = 26
    const buf_size = try mem.loadU32(4);
    try std.testing.expectEqual(@as(u32, 26), buf_size);
}

test "wasi random_get" {
    const allocator = std.testing.allocator;

    var mem = try runtime.Memory.init(allocator, 1, null);
    defer mem.deinit();

    const config = WasiConfig.init(allocator);
    var wasi = Wasi.init(config);
    wasi.setMemory(&mem);

    // Fill with zeros first
    @memset(mem.data[0..16], 0);

    const result = wasi.random_get(0, 16);
    try std.testing.expectEqual(Errno.success, result);

    // Check that buffer is not all zeros (very unlikely with random)
    var all_zero = true;
    for (mem.data[0..16]) |b| {
        if (b != 0) all_zero = false;
    }
    try std.testing.expect(!all_zero);
}

test "wasi clock_time_get" {
    const allocator = std.testing.allocator;

    var mem = try runtime.Memory.init(allocator, 1, null);
    defer mem.deinit();

    const config = WasiConfig.init(allocator);
    var wasi = Wasi.init(config);
    wasi.setMemory(&mem);

    // Get realtime
    const result = wasi.clock_time_get(@intFromEnum(ClockId.realtime), 0, 0);
    try std.testing.expectEqual(Errno.success, result);

    // Check time is reasonable (after year 2020)
    const time = try mem.loadU64(0);
    const year_2020_ns: u64 = 1577836800 * 1_000_000_000;
    try std.testing.expect(time > year_2020_ns);
}
