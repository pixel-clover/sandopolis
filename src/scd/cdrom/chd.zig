const std = @import("std");
const c = @import("libchdr");
const platform = @import("../../platform.zig");
const cue = @import("cue.zig");
const msf = @import("msf.zig");

const Chd = @This();
const frame_bytes: u32 = c.CD_FRAME_SIZE;
const track_padding: u32 = c.CD_TRACK_PADDING;
const max_tracks = 99;
const max_lba = 100 * msf.sectors_per_minute - msf.pregap_sectors - 1;

const Remote = struct { id: u32, size: u64, offset: u64 = 0 };
const Source = union(enum) { file: platform.File, browser: Remote };
const browser_build = @import("builtin").target.cpu.arch == .wasm32;
extern "chd" fn read(id: u32, offset: u64, dest: [*]u8, len: usize) usize;
extern "chd" fn close(id: u32) void;

allocator: std.mem.Allocator,
source: Source,
references: usize = 1,
handle: ?*c.chd_file = null,
hunk: []u8 = &.{},
cached_hunk: ?u32 = null,

pub fn open(allocator: std.mem.Allocator, path: []const u8) !*Chd {
    const file = try platform.cwd().openFile(path, .{});
    errdefer file.close();
    return openSource(allocator, .{ .file = file });
}

pub fn openBrowser(allocator: std.mem.Allocator, id: u32, size: u64) !*Chd {
    return openSource(allocator, .{ .browser = .{ .id = id, .size = size } });
}

fn openSource(allocator: std.mem.Allocator, source: Source) !*Chd {
    const self = try allocator.create(Chd);
    errdefer allocator.destroy(self);
    self.* = .{ .allocator = allocator, .source = source };

    var header: c.chd_header = undefined;
    try check(c.chd_read_header_core_file_callbacks(&callbacks, self, &header));
    if (header.version != 5) return error.UnsupportedChdVersion;
    if (header.unitbytes != frame_bytes) return error.UnsupportedChdDisc;
    if (header.hunkbytes == 0 or header.hunkbytes % frame_bytes != 0 or
        header.logicalbytes == 0 or header.logicalbytes % frame_bytes != 0 or
        header.unitcount > max_lba + max_tracks * (track_padding - 1))
        return error.InvalidChd;

    try check(c.chd_open_core_file_callbacks(&callbacks, self, c.CHD_OPEN_READ, null, &self.handle));
    errdefer c.chd_close(self.handle);
    self.hunk = try allocator.alloc(u8, header.hunkbytes);
    return self;
}

pub fn deinit(self: *Chd) void {
    self.references -= 1;
    if (self.references != 0) return;
    c.chd_close(self.handle);
    switch (self.source) {
        .file => |file| file.close(),
        .browser => |remote| if (browser_build) close(remote.id),
    }
    const allocator = self.allocator;
    allocator.free(self.hunk);
    allocator.destroy(self);
}

pub fn layout(self: *const Chd) !cue.Layout {
    const header = c.chd_get_header(self.handle);
    var tracks: std.ArrayList(cue.Track) = .empty;
    defer tracks.deinit(self.allocator);
    var lba: u32 = 0;
    var frame: u32 = 0;

    while (true) {
        const index: u32 = @intCast(tracks.items.len);
        const meta = (try self.trackMetadata(index)) orelse break;
        if (index == max_tracks or meta.number != index + 1 or meta.frames <= meta.stored_pregap)
            return error.InvalidChdMetadata;

        // CHD padding advances the stored frame position, never the drive's LBA.
        const next_frame = @as(u64, frame) + std.mem.alignForward(u64, meta.frames, track_padding);
        const start_lba = @as(u64, lba) + meta.pregap;
        const end_lba = start_lba + (meta.frames - meta.stored_pregap) + meta.postgap;
        if (next_frame > header.*.unitcount or end_lba > max_lba) return error.InvalidChdMetadata;
        try tracks.append(self.allocator, .{
            .number = @intCast(meta.number),
            .kind = meta.kind,
            .file_index = 0,
            .file_sector = frame + meta.stored_pregap,
            .pregap_lba = lba,
            .start_lba = @intCast(start_lba),
            .end_lba = @intCast(end_lba),
            .pregap_sectors_in_file = meta.stored_pregap,
            .virtual_postgap_sectors = meta.postgap,
        });
        lba = @intCast(end_lba);
        frame = @intCast(next_frame);
    }
    if (tracks.items.len == 0 or !tracks.items[0].kind.isData()) return error.UnsupportedChdDisc;
    if (frame != header.*.unitcount) return error.InvalidChdMetadata;
    return .{
        .allocator = self.allocator,
        .files = &.{},
        .tracks = try tracks.toOwnedSlice(self.allocator),
        .lead_out_lba = lba,
    };
}

pub fn readFrame(self: *Chd, frame: u32) ![]const u8 {
    const frames_per_hunk: u32 = @intCast(self.hunk.len / frame_bytes);
    const hunk = frame / frames_per_hunk;
    if (self.cached_hunk != hunk) {
        self.cached_hunk = null;
        try check(c.chd_read(self.handle, hunk, self.hunk.ptr));
        self.cached_hunk = hunk;
    }
    return self.hunk[(frame % frames_per_hunk) * frame_bytes ..][0..frame_bytes];
}

const Metadata = struct {
    number: u32,
    kind: cue.TrackKind,
    frames: u32,
    pregap: u32 = 0,
    stored_pregap: u32 = 0,
    postgap: u32 = 0,
};

fn trackMetadata(self: *const Chd, index: u32) !?Metadata {
    var buffer: [256]u8 = undefined;
    var len: u32 = 0;
    var status = c.chd_get_metadata(self.handle, c.CDROM_TRACK_METADATA2_TAG, index, &buffer, buffer.len, &len, null, null);
    const has_gaps = status != c.CHDERR_METADATA_NOT_FOUND;
    if (!has_gaps) {
        status = c.chd_get_metadata(self.handle, c.CDROM_TRACK_METADATA_TAG, index, &buffer, buffer.len, &len, null, null);
        if (status == c.CHDERR_METADATA_NOT_FOUND) return null;
    }
    try check(status);
    if (len == 0 or len > buffer.len or buffer[len - 1] != 0) return error.InvalidChdMetadata;

    var words = std.mem.tokenizeScalar(u8, buffer[0 .. len - 1], ' ');
    var meta: Metadata = .{
        .number = try numberField(&words, "TRACK:"),
        .kind = try trackKind(try field(&words, "TYPE:")),
        .frames = 0,
    };
    _ = try field(&words, "SUBTYPE:");
    meta.frames = try numberField(&words, "FRAMES:");
    if (has_gaps) {
        meta.pregap = try numberField(&words, "PREGAP:");
        const pregap_type = try field(&words, "PGTYPE:");
        // CHD marks a stored INDEX 00 with a V prefix, despite the name.
        if (meta.pregap != 0 and pregap_type[0] == 'V') {
            if (try trackKind(pregap_type[1..]) != meta.kind) return error.UnsupportedChdTrack;
            meta.stored_pregap = meta.pregap;
        }
        _ = try field(&words, "PGSUB:");
        meta.postgap = try numberField(&words, "POSTGAP:");
    }
    if (words.next() != null) return error.InvalidChdMetadata;
    return meta;
}

const Words = std.mem.TokenIterator(u8, .scalar);

fn field(words: *Words, prefix: []const u8) ![]const u8 {
    const word = words.next() orelse return error.InvalidChdMetadata;
    if (!std.mem.startsWith(u8, word, prefix) or word.len == prefix.len) return error.InvalidChdMetadata;
    return word[prefix.len..];
}

fn numberField(words: *Words, prefix: []const u8) !u32 {
    return std.fmt.parseUnsigned(u32, try field(words, prefix), 10) catch error.InvalidChdMetadata;
}

fn trackKind(name: []const u8) !cue.TrackKind {
    return std.StaticStringMap(cue.TrackKind).initComptime(.{
        .{ "MODE1", .mode1_2048 },
        .{ "MODE1_RAW", .mode1_2352 },
        .{ "MODE2_RAW", .mode2_2352 },
        .{ "AUDIO", .audio },
    }).get(name) orelse error.UnsupportedChdTrack;
}

fn check(status: c.chd_error) !void {
    return switch (status) {
        c.CHDERR_NONE => {},
        c.CHDERR_OUT_OF_MEMORY => error.OutOfMemory,
        c.CHDERR_REQUIRES_PARENT => error.ChdRequiresParent,
        c.CHDERR_UNSUPPORTED_VERSION => error.UnsupportedChdVersion,
        c.CHDERR_UNSUPPORTED_FORMAT, c.CHDERR_NOT_SUPPORTED => error.UnsupportedChdDisc,
        else => error.InvalidChd,
    };
}

const callbacks: c.core_file_callbacks = .{
    .fsize = fileSize,
    .fread = fileRead,
    .fclose = fileClose,
    .fseek = fileSeek,
};

fn fileSize(context: ?*anyopaque) callconv(.c) u64 {
    const self: *Chd = @ptrCast(@alignCast(context.?));
    return switch (self.source) {
        .file => |file| file.getEndPos() catch std.math.maxInt(u64),
        .browser => |remote| remote.size,
    };
}

fn fileRead(dest: ?*anyopaque, size: usize, count: usize, context: ?*anyopaque) callconv(.c) usize {
    if (size == 0 or count == 0) return 0;
    const len = std.math.mul(usize, size, count) catch return 0;
    const self: *Chd = @ptrCast(@alignCast(context.?));
    const bytes: [*]u8 = @ptrCast(dest orelse return 0);
    const n = switch (self.source) {
        .file => |file| file.readAll(bytes[0..len]) catch return 0,
        .browser => |*remote| blk: {
            if (!browser_build) return 0;
            const n = read(remote.id, remote.offset, bytes, len);
            remote.offset += n;
            break :blk n;
        },
    };
    return n / size;
}

fn fileClose(_: ?*anyopaque) callconv(.c) c_int {
    // Chd owns the platform file on both open success and failure.
    return 0;
}

fn fileSeek(context: ?*anyopaque, offset: i64, whence: c_int) callconv(.c) c_int {
    // The pinned libchdr uses absolute seeks for its read callbacks.
    if (whence != c.SEEK_SET or offset < 0) return -1;
    const self: *Chd = @ptrCast(@alignCast(context.?));
    switch (self.source) {
        .file => |file| file.seekTo(@intCast(offset)) catch return -1,
        .browser => |*remote| remote.offset = @intCast(offset),
    }
    return 0;
}
