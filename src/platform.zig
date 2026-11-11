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

test "Dir and File wrappers preserve file contents and metadata" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = Dir{ .d = tmp.dir };
    try dir.makePath("nested");

    var file = try dir.createFile("nested/data.bin", .{ .read = true });
    try file.writeAll("ab");
    try std.testing.expectEqual(@as(usize, 2), try file.write("cd"));
    try std.testing.expectEqual(@as(u64, 4), try file.getEndPos());
    try std.testing.expectEqual(@as(u64, 4), (try file.stat()).size);
    try file.seekTo(0);
    const contents = try file.readToEndAlloc(std.testing.allocator, 4);
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqualStrings("abcd", contents);
    try file.seekTo(0);
    const unlimited_contents = try file.readToEndAlloc(std.testing.allocator, std.math.maxInt(usize));
    defer std.testing.allocator.free(unlimited_contents);
    try std.testing.expectEqualStrings("abcd", unlimited_contents);
    file.close();

    try dir.access("nested/data.bin", .{});
    try dir.rename("nested/data.bin", "nested/moved.bin");
    var reopened = try dir.openFile("nested/moved.bin", .{});
    defer reopened.close();
    var buf: [4]u8 = undefined;
    _ = reopened.reader(&buf);
    _ = reopened.writer(&buf);
    try std.testing.expectEqual(@as(usize, 4), try reopened.read(&buf));
    try std.testing.expectEqualSlices(u8, "abcd", &buf);

    const path = try dir.realpathAlloc(std.testing.allocator, "nested/moved.bin");
    defer std.testing.allocator.free(path);
    try std.testing.expect(std.mem.endsWith(u8, path, "nested/moved.bin"));
    const read_contents = try dir.readFileAlloc(std.testing.allocator, "nested/moved.bin", 4);
    defer std.testing.allocator.free(read_contents);
    try std.testing.expectEqualStrings("abcd", read_contents);
    const unlimited_read = try dir.readFileAlloc(std.testing.allocator, "nested/moved.bin", std.math.maxInt(usize));
    defer std.testing.allocator.free(unlimited_read);
    try std.testing.expectEqualStrings("abcd", unlimited_read);
    try std.testing.expectError(error.StreamTooLong, dir.readFileAlloc(std.testing.allocator, "nested/moved.bin", 3));
    try dir.deleteFile("nested/moved.bin");
    try std.testing.expectError(error.FileNotFound, dir.access("nested/moved.bin", .{}));

    const empty = try dir.createFile("nested/empty.bin", .{});
    empty.close();
    const empty_contents = try dir.readFileAlloc(std.testing.allocator, "nested/empty.bin", 0);
    defer std.testing.allocator.free(empty_contents);
    try std.testing.expectEqual(@as(usize, 0), empty_contents.len);
}

test "clock and synchronization wrappers work without process init" {
    var mutex: Mutex = .{};
    mutex.lock();
    mutex.unlock();
    const before = try Instant.now();
    sleep(1);
    const after = try Instant.now();
    try std.testing.expect(after.ns >= before.ns);
    try std.testing.expectEqual(@as(u64, @intCast(after.ns - before.ns)), after.since(before));
    try std.testing.expectEqual(@as(u64, 0), before.since(after));
    try std.testing.expect(nanoTimestamp() != 0);
}

test "process wrappers use initialized args and environment" {
    const saved_io = process_io;
    const saved_environ = process_environ;
    const saved_args = process_args;
    defer {
        process_io = saved_io;
        process_environ = saved_environ;
        process_args = saved_args;
    }
    process_io = null;
    process_environ = null;
    process_args = null;
    try std.testing.expectError(error.EnvironmentVariableNotFound, getEnvVarOwned(std.testing.allocator, "SANDOPOLIS_PLATFORM_TEST"));
    try std.testing.expectError(error.Unsupported, argsWithAllocator(std.testing.allocator));

    var environ: std.process.Environ.Map = .init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("SANDOPOLIS_PLATFORM_TEST", "working");
    const args: std.process.Args = .{ .vector = switch (@import("builtin").os.tag) {
        .windows => &.{},
        .wasi, .emscripten => if (@import("builtin").link_libc) &.{ "sandopolis", "example.bin" } else {},
        .freestanding, .other => {},
        else => &.{ "sandopolis", "example.bin" },
    } };
    init(.{
        .minimal = .{ .environ = .empty, .args = args },
        .arena = undefined,
        .gpa = std.testing.allocator,
        .io = io(),
        .environ_map = &environ,
        .preopens = undefined,
    });
    const value = try getEnvVarOwned(std.testing.allocator, "SANDOPOLIS_PLATFORM_TEST");
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("working", value);
    try std.testing.expectError(error.EnvironmentVariableNotFound, getEnvVarOwned(std.testing.allocator, "SANDOPOLIS_PLATFORM_MISSING"));

    if (@import("builtin").os.tag != .windows and @import("builtin").os.tag != .wasi and
        @import("builtin").os.tag != .emscripten and @import("builtin").os.tag != .freestanding and
        @import("builtin").os.tag != .other)
    {
        var iterator = try argsWithAllocator(std.testing.allocator);
        defer iterator.deinit();
        try std.testing.expectEqualStrings("sandopolis", iterator.next().?);
        try std.testing.expectEqualStrings("example.bin", iterator.next().?);
        try std.testing.expect(iterator.next() == null);
    }
    try cwd().access(".", .{});
    _ = stdout();
    _ = stderr();
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
        const limit: std.Io.Limit = if (max_bytes == std.math.maxInt(usize))
            .unlimited
        else
            .limited(max_bytes + 1);
        return self.d.readFileAlloc(io(), sub_path, allocator, limit);
    }

    pub fn realpathAlloc(self: Dir, allocator: std.mem.Allocator, sub_path: []const u8) ![]u8 {
        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const n = try self.d.realPathFile(io(), sub_path, &buf);
        return allocator.dupe(u8, buf[0..n]);
    }

    pub fn rename(self: Dir, old_sub_path: []const u8, new_sub_path: []const u8) !void {
        return std.Io.Dir.rename(self.d, old_sub_path, self.d, new_sub_path, io());
    }

    pub const OpenDirOptions = std.Io.Dir.OpenOptions;
    pub const Entry = std.Io.Dir.Entry;

    pub const Iterator = struct {
        it: std.Io.Dir.Iterator,

        pub fn next(self: *Iterator) !?Entry {
            return self.it.next(io());
        }
    };

    pub fn openDir(self: Dir, sub_path: []const u8, opts: OpenDirOptions) !Dir {
        return .{ .d = try self.d.openDir(io(), sub_path, opts) };
    }

    pub fn iterate(self: Dir) Iterator {
        return .{ .it = self.d.iterate() };
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
