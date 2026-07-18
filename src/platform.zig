//! Platform I/O boundary: the single place where Sandopolis talks to the
//! host OS through Zig's `std.Io` interface (files, directories, clocks,
//! env, args, sleeping).
//!
//! All other code must go through this module instead of using `std.Io`,
//! `std.fs`, or `std.process` directly. This keeps standard-library churn
//! between Zig versions contained to this one file: when an upcoming Zig
//! release changes the Io/fs/process APIs, only the wrapper bodies here
//! need updating, not the ~30 call-site files.
//!
//! Executables must call `init()` from `main(init: std.process.Init)` so
//! I/O uses the process Io and env/args are available. Code running
//! without `init()` (unit tests) falls back to a single-threaded blocking Io.

const std = @import("std");

var fallback_threaded: std.Io.Threaded = .init_single_threaded;

var process_io: ?std.Io = null;
var process_environ: ?*std.process.Environ.Map = null;
var process_args: ?std.process.Args = null;

pub fn init(pi: std.process.Init) void {
    process_io = pi.io;
    process_environ = pi.environ_map;
    process_args = pi.minimal.args;
}

pub fn io() std.Io {
    return process_io orelse fallback_threaded.io();
}

pub const File = struct {
    f: std.Io.File,

    pub fn close(self: File) void {
        self.f.close(io());
    }

    pub fn writeAll(self: File, bytes: []const u8) !void {
        return self.f.writeStreamingAll(io(), bytes);
    }

    pub fn write(self: File, bytes: []const u8) !usize {
        return self.f.writeStreaming(io(), &.{}, &.{bytes}, 1);
    }

    pub fn read(self: File, buffer: []u8) !usize {
        var bufs = [_][]u8{buffer};
        return self.f.readStreaming(io(), &bufs);
    }

    pub fn readAll(self: File, buffer: []u8) !usize {
        var total: usize = 0;
        while (total < buffer.len) {
            var bufs = [_][]u8{buffer[total..]};
            const n = try self.f.readStreaming(io(), &bufs);
            if (n == 0) break;
            total += n;
        }
        return total;
    }

    pub fn getEndPos(self: File) !u64 {
        return self.f.length(io());
    }

    pub fn stat(self: File) !std.Io.File.Stat {
        return self.f.stat(io());
    }

    pub fn reader(self: File, buffer: []u8) std.Io.File.Reader {
        return self.f.reader(io(), buffer);
    }

    pub fn writer(self: File, buffer: []u8) std.Io.File.Writer {
        return self.f.writer(io(), buffer);
    }

    // std.Io.File exposes no public seek wrappers (only positional reads and
    // writes), so go through the Io vtable, which implements seeking for
    // every supported OS.
    pub fn seekTo(self: File, offset: u64) !void {
        const i = io();
        return i.vtable.fileSeekTo(i.userdata, self.f, offset);
    }

    pub fn seekBy(self: File, offset: i64) !void {
        const i = io();
        return i.vtable.fileSeekBy(i.userdata, self.f, offset);
    }

    pub fn readToEndAlloc(self: File, allocator: std.mem.Allocator, max_bytes: usize) ![]u8 {
        var r = self.f.reader(io(), &.{});
        return r.interface.allocRemaining(allocator, .limited(max_bytes)) catch |err| switch (err) {
            error.ReadFailed => return r.err orelse error.InputOutput,
            else => |e| return e,
        };
    }
};

test "File seekTo and seekBy reposition the stream" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try (Dir{ .d = tmp.dir }).createFile("seek.bin", .{ .read = true });
    defer file.close();
    try file.writeAll("abcdef");

    try file.seekTo(1);
    var buf: [2]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), try file.readAll(buf[0..2]));
    try std.testing.expectEqualSlices(u8, "bc", buf[0..2]);

    try file.seekBy(-1);
    try std.testing.expectEqual(@as(usize, 1), try file.readAll(buf[0..1]));
    try std.testing.expectEqual(@as(u8, 'c'), buf[0]);

    try file.seekTo(0);
    try std.testing.expectEqual(@as(usize, 1), try file.readAll(buf[0..1]));
    try std.testing.expectEqual(@as(u8, 'a'), buf[0]);
}

pub fn stdout() File {
    return .{ .f = std.Io.File.stdout() };
}

pub fn stderr() File {
    return .{ .f = std.Io.File.stderr() };
}

pub const Dir = struct {
    d: std.Io.Dir,

    pub fn openFile(self: Dir, sub_path: []const u8, opts: std.Io.Dir.OpenFileOptions) !File {
        return .{ .f = try self.d.openFile(io(), sub_path, opts) };
    }

    pub fn createFile(self: Dir, sub_path: []const u8, opts: std.Io.Dir.CreateFileOptions) !File {
        return .{ .f = try self.d.createFile(io(), sub_path, opts) };
    }

    pub fn access(self: Dir, sub_path: []const u8, opts: std.Io.Dir.AccessOptions) !void {
        return self.d.access(io(), sub_path, opts);
    }

    pub fn deleteFile(self: Dir, sub_path: []const u8) !void {
        return self.d.deleteFile(io(), sub_path);
    }

    pub fn makePath(self: Dir, sub_path: []const u8) !void {
        return self.d.createDirPath(io(), sub_path);
    }

    pub fn readFileAlloc(self: Dir, allocator: std.mem.Allocator, sub_path: []const u8, max_bytes: usize) ![]u8 {
        return self.d.readFileAlloc(io(), sub_path, allocator, .limited(max_bytes));
    }

    pub fn realpathAlloc(self: Dir, allocator: std.mem.Allocator, sub_path: []const u8) ![]u8 {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try self.d.realPathFile(io(), sub_path, &buf);
        return allocator.dupe(u8, buf[0..n]);
    }

    pub fn rename(self: Dir, old_sub_path: []const u8, new_sub_path: []const u8) !void {
        return std.Io.Dir.rename(self.d, old_sub_path, self.d, new_sub_path, io());
    }

    pub fn close(self: *Dir) void {
        self.d.close(io());
    }
};

pub fn cwd() Dir {
    return .{ .d = std.Io.Dir.cwd() };
}

/// 0.15-style monotonic instant measured in nanoseconds.
pub const Instant = struct {
    ns: i96,

    pub fn now() error{Unsupported}!Instant {
        return .{ .ns = std.Io.Clock.now(.awake, io()).nanoseconds };
    }

    pub fn since(self: Instant, earlier: Instant) u64 {
        const d = self.ns - earlier.ns;
        return if (d < 0) 0 else @intCast(d);
    }
};

pub fn getEnvVarOwned(allocator: std.mem.Allocator, key: []const u8) ![]u8 {
    const map = process_environ orelse return error.EnvironmentVariableNotFound;
    const value = map.get(key) orelse return error.EnvironmentVariableNotFound;
    return allocator.dupe(u8, value);
}

pub fn argsWithAllocator(allocator: std.mem.Allocator) !std.process.Args.Iterator {
    const args = process_args orelse return error.Unsupported;
    return std.process.Args.Iterator.initAllocator(args, allocator);
}

/// 0.15-style blocking mutex over std.Io.Mutex.
pub const Mutex = struct {
    m: std.Io.Mutex = .init,

    pub fn lock(self: *Mutex) void {
        self.m.lockUncancelable(io());
    }

    pub fn unlock(self: *Mutex) void {
        self.m.unlock(io());
    }
};

pub fn sleep(ns: u64) void {
    std.Io.sleep(io(), .{ .nanoseconds = @intCast(ns) }, .awake) catch {};
}

pub fn nanoTimestamp() i128 {
    return std.Io.Clock.now(.real, io()).nanoseconds;
}
