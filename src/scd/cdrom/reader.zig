//! Disc image reader: lazy sector access over CUE/BIN, ISO, or in-memory
//! images. Data sectors are always delivered as 2352-byte raw sectors (sync,
//! header, user data, and zeroed EDC/ECC for 2048-byte images) so the CDC
//! model sees one format. Audio sectors decode to 588 stereo frames.

const std = @import("std");
const platform = @import("../../platform.zig");
const cue = @import("cue.zig");
const msf = @import("msf.zig");

pub const raw_sector_bytes: usize = 2352;
pub const user_data_bytes: usize = 2048;
pub const audio_frames_per_sector: usize = 588;
pub const sync_bytes = [12]u8{ 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00 };

pub const Layout = cue.Layout;
pub const Track = cue.Track;
pub const TrackKind = cue.TrackKind;

/// Backing storage for one FILE entry. Memory images are owned copies.
pub const SectorSource = union(enum) {
    file: platform.File,
    memory: []u8,

    /// Read up to `buf.len` bytes at `offset`; short reads return fewer bytes.
    pub fn readAt(self: SectorSource, offset: u64, buf: []u8) !usize {
        switch (self) {
            .memory => |bytes| {
                if (offset >= bytes.len) return 0;
                const avail = bytes.len - offset;
                const n = @min(avail, buf.len);
                @memcpy(buf[0..n], bytes[@intCast(offset)..][0..n]);
                return n;
            },
            .file => |file| {
                try file.seekTo(offset);
                return file.readAll(buf);
            },
        }
    }

    pub fn close(self: *SectorSource) void {
        switch (self.*) {
            .file => |file| file.close(),
            .memory => {},
        }
    }
};

pub const ReadError = error{
    LbaOutOfRange,
    NotAudioTrack,
    ShortRead,
    InputOutput,
} || anyerror;

pub const Disc = struct {
    allocator: std.mem.Allocator,
    layout: Layout,
    sources: []SectorSource,
    /// Path of the .cue/.iso this disc was opened from, when file-backed.
    source_path: ?[]u8 = null,

    pub fn deinit(self: *Disc) void {
        for (self.sources) |*s| {
            switch (s.*) {
                .memory => |bytes| self.allocator.free(bytes),
                .file => s.close(),
            }
        }
        self.allocator.free(self.sources);
        if (self.source_path) |p| self.allocator.free(p);
        self.layout.deinit();
        self.* = undefined;
    }

    /// Duplicate the disc: memory images are copied, file-backed discs are
    /// reopened from their path.
    pub fn clone(self: *const Disc) !Disc {
        if (self.source_path) |path| {
            const ext = std.fs.path.extension(path);
            return if (std.ascii.eqlIgnoreCase(ext, ".cue"))
                openCuePath(self.allocator, path)
            else
                openIsoPath(self.allocator, path);
        }
        var files = try self.allocator.alloc([]const u8, self.sources.len);
        defer self.allocator.free(files);
        for (self.sources, 0..) |src, i| files[i] = src.memory;
        // Rebuild from the same layout text is not kept; re-derive a sheet
        // that reproduces the layout instead.
        return fromLayout(self.allocator, &self.layout, files);
    }

    /// Memory disc reproducing an existing layout (used by clone).
    fn fromLayout(allocator: std.mem.Allocator, layout: *const Layout, files: []const []const u8) !Disc {
        var new_layout = Layout{
            .allocator = allocator,
            .files = try allocator.alloc(cue.FileEntry, layout.files.len),
            .tracks = try allocator.dupe(Track, layout.tracks),
            .lead_out_lba = layout.lead_out_lba,
        };
        var named: usize = 0;
        errdefer {
            for (new_layout.files[0..named]) |f| allocator.free(f.name);
            allocator.free(new_layout.files);
            allocator.free(new_layout.tracks);
        }
        for (layout.files, 0..) |f, i| {
            new_layout.files[i] = .{ .name = try allocator.dupe(u8, f.name), .kind = f.kind, .size_bytes = f.size_bytes };
            named += 1;
        }
        errdefer new_layout.deinit();
        const sources = try ownedMemorySources(allocator, files);
        return .{ .allocator = allocator, .layout = new_layout, .sources = sources };
    }

    fn ownedMemorySources(allocator: std.mem.Allocator, files: []const []const u8) ![]SectorSource {
        const sources = try allocator.alloc(SectorSource, files.len);
        var copied: usize = 0;
        errdefer {
            for (sources[0..copied]) |*s| allocator.free(s.memory);
            allocator.free(sources);
        }
        for (sources, files) |*s, bytes| {
            s.* = .{ .memory = try allocator.dupe(u8, bytes) };
            copied += 1;
        }
        return sources;
    }

    // -- Constructors -------------------------------------------------------

    /// In-memory disc. `cue_text` null means a single MODE1/2048 image in
    /// `files[0]`. Otherwise `files[i]` backs the i-th FILE entry of the
    /// sheet, in order, and file names in the sheet are not consulted.
    pub fn fromMemory(allocator: std.mem.Allocator, cue_text: ?[]const u8, files: []const []const u8) !Disc {
        if (files.len == 0) return error.NoTracks;
        var ctx = MemorySizes{ .files = files };
        const text = cue_text orelse single_iso_sheet;
        var layout = try cue.parse(allocator, text, &ctx, MemorySizes.lookup);
        errdefer layout.deinit();
        if (layout.files.len != files.len) return error.FileCountMismatch;

        const sources = try ownedMemorySources(allocator, files);
        return .{ .allocator = allocator, .layout = layout, .sources = sources };
    }

    /// Open a CUE sheet from disk; FILE names resolve relative to the sheet.
    pub fn openCuePath(allocator: std.mem.Allocator, path: []const u8) !Disc {
        const text = try platform.cwd().readFileAlloc(allocator, path, 1024 * 1024);
        defer allocator.free(text);
        const dir = std.fs.path.dirname(path) orelse ".";
        var disc = try openCueText(allocator, text, dir);
        errdefer disc.deinit();
        disc.source_path = try allocator.dupe(u8, path);
        return disc;
    }

    pub fn openCueText(allocator: std.mem.Allocator, text: []const u8, base_dir: []const u8) !Disc {
        var ctx = DirSizes{ .allocator = allocator, .base_dir = base_dir };
        var layout = try cue.parse(allocator, text, &ctx, DirSizes.lookup);
        errdefer layout.deinit();

        const sources = try allocator.alloc(SectorSource, layout.files.len);
        var opened: usize = 0;
        errdefer {
            for (sources[0..opened]) |*s| s.close();
            allocator.free(sources);
        }
        for (layout.files, 0..) |entry, i| {
            const full = try std.fs.path.join(allocator, &.{ base_dir, entry.name });
            defer allocator.free(full);
            sources[i] = .{ .file = try platform.cwd().openFile(full, .{}) };
            opened += 1;
        }
        return .{ .allocator = allocator, .layout = layout, .sources = sources };
    }

    /// Open a bare ISO (single MODE1/2048 data track).
    pub fn openIsoPath(allocator: std.mem.Allocator, path: []const u8) !Disc {
        const file = try platform.cwd().openFile(path, .{});
        errdefer file.close();
        const size = try file.getEndPos();
        var ctx = FixedSize{ .size = size };
        var layout = try cue.parse(allocator, single_iso_sheet, &ctx, FixedSize.lookup);
        errdefer layout.deinit();
        const sources = try allocator.alloc(SectorSource, 1);
        errdefer allocator.free(sources);
        sources[0] = .{ .file = file };
        const source_path = try allocator.dupe(u8, path);
        return .{ .allocator = allocator, .layout = layout, .sources = sources, .source_path = source_path };
    }

    // -- Queries ------------------------------------------------------------

    pub fn leadOutLba(self: *const Disc) u32 {
        return self.layout.lead_out_lba;
    }

    pub fn trackAt(self: *const Disc, lba: u32) ?*const Track {
        return self.layout.trackAt(lba);
    }

    pub fn trackByNumber(self: *const Disc, number: u8) ?*const Track {
        return self.layout.trackByNumber(number);
    }

    pub fn firstTrack(self: *const Disc) u8 {
        return self.layout.firstTrack();
    }

    pub fn lastTrack(self: *const Disc) u8 {
        return self.layout.lastTrack();
    }

    pub fn trackCount(self: *const Disc) usize {
        return self.layout.tracks.len;
    }

    // -- Sector access ------------------------------------------------------

    /// Read one 2352-byte raw sector. Data tracks stored as 2048-byte user
    /// data get a synthesized sync/header (mode 1) with zeroed EDC/ECC.
    /// Pregap and audio sectors are returned as stored (audio = raw PCM).
    pub fn readSector(self: *Disc, lba: u32, out: *[raw_sector_bytes]u8) !void {
        const track = self.trackAt(lba) orelse return error.LbaOutOfRange;
        @memset(out, 0);

        const offset = track.fileByteOffset(lba) orelse {
            // Virtual pregap: no backing bytes. Data tracks still carry a
            // valid header so the CDC decoder can keep tracking position.
            if (track.kind.isData()) writeMode1Header(out, lba);
            return;
        };
        const file = self.layout.files[track.file_index];
        const source = self.sources[track.file_index];

        switch (track.kind) {
            .mode1_2048 => {
                writeMode1Header(out, lba);
                const n = try source.readAt(file.dataOffset() + offset, out[16 .. 16 + user_data_bytes]);
                if (n != user_data_bytes) return error.ShortRead;
            },
            .mode1_2352, .mode2_2352, .audio => {
                const n = try source.readAt(file.dataOffset() + offset, out);
                if (n != raw_sector_bytes) return error.ShortRead;
            },
        }
    }

    /// Decode one audio sector into little-endian signed 16-bit stereo
    /// frames. Non-audio sectors are an error; virtual pregap is silence.
    pub fn readAudioSector(self: *Disc, lba: u32, out: *[audio_frames_per_sector][2]i16) !void {
        const track = self.trackAt(lba) orelse return error.LbaOutOfRange;
        if (track.kind != .audio) return error.NotAudioTrack;
        var raw: [raw_sector_bytes]u8 = undefined;
        try self.readSector(lba, &raw);
        for (out, 0..) |*frame, i| {
            const base = i * 4;
            frame[0] = @bitCast(std.mem.readInt(u16, raw[base..][0..2], .little));
            frame[1] = @bitCast(std.mem.readInt(u16, raw[base + 2 ..][0..2], .little));
        }
    }
};

/// Fill the 12-byte sync and 4-byte header (BCD MSF + mode 1) of a raw sector.
pub fn writeMode1Header(out: *[raw_sector_bytes]u8, lba: u32) void {
    @memcpy(out[0..12], &sync_bytes);
    const time = msf.lbaToMsf(lba);
    out[12] = msf.toBcd(time.m);
    out[13] = msf.toBcd(time.s);
    out[14] = msf.toBcd(time.f);
    out[15] = 0x01;
}

const single_iso_sheet =
    \\FILE "image.iso" BINARY
    \\  TRACK 01 MODE1/2048
    \\    INDEX 01 00:00:00
;

const MemorySizes = struct {
    files: []const []const u8,
    next: usize = 0,

    fn lookup(ctx: ?*anyopaque, _: []const u8) ?u64 {
        const self: *MemorySizes = @ptrCast(@alignCast(ctx.?));
        if (self.next >= self.files.len) return null;
        defer self.next += 1;
        return self.files[self.next].len;
    }
};

const FixedSize = struct {
    size: u64,
    fn lookup(ctx: ?*anyopaque, _: []const u8) ?u64 {
        const self: *const FixedSize = @ptrCast(@alignCast(ctx.?));
        return self.size;
    }
};

const DirSizes = struct {
    allocator: std.mem.Allocator,
    base_dir: []const u8,

    fn lookup(ctx: ?*anyopaque, name: []const u8) ?u64 {
        const self: *const DirSizes = @ptrCast(@alignCast(ctx.?));
        const full = std.fs.path.join(self.allocator, &.{ self.base_dir, name }) catch return null;
        defer self.allocator.free(full);
        const file = platform.cwd().openFile(full, .{}) catch return null;
        defer file.close();
        return file.getEndPos() catch null;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn fillPattern(buf: []u8, seed: u8) void {
    for (buf, 0..) |*b, i| b.* = @truncate(@as(usize, seed) +% i * 7);
}

test "iso image sectors get a synthesized mode 1 header" {
    var image: [3 * user_data_bytes]u8 = undefined;
    fillPattern(&image, 0x10);
    var disc = try Disc.fromMemory(testing.allocator, null, &.{&image});
    defer disc.deinit();

    try testing.expectEqual(@as(u32, 3), disc.leadOutLba());
    try testing.expectEqual(@as(usize, 1), disc.trackCount());
    try testing.expectEqual(TrackKind.mode1_2048, disc.trackAt(0).?.kind);

    var raw: [raw_sector_bytes]u8 = undefined;
    try disc.readSector(2, &raw);
    try testing.expectEqualSlices(u8, &sync_bytes, raw[0..12]);
    // LBA 2 = 00:02:02 in BCD, mode 1.
    try testing.expectEqualSlices(u8, &.{ 0x00, 0x02, 0x02, 0x01 }, raw[12..16]);
    try testing.expectEqualSlices(u8, image[2 * user_data_bytes ..][0..user_data_bytes], raw[16 .. 16 + user_data_bytes]);
    // EDC/ECC area is zeroed.
    for (raw[16 + user_data_bytes ..]) |b| try testing.expectEqual(@as(u8, 0), b);

    try testing.expectError(error.LbaOutOfRange, disc.readSector(3, &raw));
    var frames: [audio_frames_per_sector][2]i16 = undefined;
    try testing.expectError(error.NotAudioTrack, disc.readAudioSector(0, &frames));
}

test "raw 2352 data and audio tracks from a cue sheet in memory" {
    const sheet =
        \\FILE "x.bin" BINARY
        \\  TRACK 01 MODE1/2352
        \\    INDEX 01 00:00:00
        \\  TRACK 02 AUDIO
        \\    INDEX 00 00:00:02
        \\    INDEX 01 00:00:03
    ;
    // 5 raw sectors: 0,1 data; 2 pregap-in-file; 3,4 audio.
    var image: [5 * raw_sector_bytes]u8 = undefined;
    fillPattern(&image, 0x33);
    // Put a recognisable LE stereo pattern in sector 3.
    const s3 = image[3 * raw_sector_bytes ..][0..raw_sector_bytes];
    std.mem.writeInt(u16, s3[0..2], 0x1234, .little); // L frame 0
    std.mem.writeInt(u16, s3[2..4], 0xFFFE, .little); // R frame 0 = -2
    std.mem.writeInt(u16, s3[4..6], 0x8000, .little); // L frame 1 = -32768

    var disc = try Disc.fromMemory(testing.allocator, sheet, &.{&image});
    defer disc.deinit();

    var raw: [raw_sector_bytes]u8 = undefined;
    try disc.readSector(1, &raw);
    try testing.expectEqualSlices(u8, image[raw_sector_bytes..][0..raw_sector_bytes], &raw);

    // In-file pregap sector is returned as stored.
    try disc.readSector(2, &raw);
    try testing.expectEqualSlices(u8, image[2 * raw_sector_bytes ..][0..raw_sector_bytes], &raw);
    try testing.expectEqual(@as(u8, 2), disc.trackAt(2).?.number);

    var frames: [audio_frames_per_sector][2]i16 = undefined;
    try disc.readAudioSector(3, &frames);
    try testing.expectEqual(@as(i16, 0x1234), frames[0][0]);
    try testing.expectEqual(@as(i16, -2), frames[0][1]);
    try testing.expectEqual(@as(i16, -32768), frames[1][0]);
    try testing.expectError(error.NotAudioTrack, disc.readAudioSector(0, &frames));
}

test "virtual pregap reads as silence or a bare data header" {
    const sheet =
        \\FILE "d.bin" BINARY
        \\  TRACK 01 MODE1/2048
        \\    INDEX 01 00:00:00
        \\FILE "a.bin" BINARY
        \\  TRACK 02 AUDIO
        \\    PREGAP 00:02:00
        \\    INDEX 01 00:00:00
    ;
    var data: [2 * user_data_bytes]u8 = undefined;
    fillPattern(&data, 1);
    var audio: [1 * raw_sector_bytes]u8 = undefined;
    fillPattern(&audio, 2);
    var disc = try Disc.fromMemory(testing.allocator, sheet, &.{ &data, &audio });
    defer disc.deinit();

    // Layout: data 0..1, virtual pregap 2..151, audio 152.
    try testing.expectEqual(@as(u32, 153), disc.leadOutLba());
    var frames: [audio_frames_per_sector][2]i16 = undefined;
    try disc.readAudioSector(10, &frames);
    for (frames) |f| {
        try testing.expectEqual(@as(i16, 0), f[0]);
        try testing.expectEqual(@as(i16, 0), f[1]);
    }
    try disc.readAudioSector(152, &frames);
    try testing.expectEqual(@as(i16, @bitCast(std.mem.readInt(u16, audio[0..2], .little))), frames[0][0]);
}

test "file count must match the sheet" {
    const sheet =
        \\FILE "a.bin" BINARY
        \\  TRACK 01 AUDIO
        \\    INDEX 01 00:00:00
        \\FILE "b.bin" BINARY
        \\  TRACK 02 AUDIO
        \\    INDEX 01 00:00:00
    ;
    var one: [raw_sector_bytes]u8 = undefined;
    try testing.expectError(error.FileNotFound, Disc.fromMemory(testing.allocator, sheet, &.{&one}));
}

test "cue and bin on disk open lazily through the file backend" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = platform.Dir{ .d = tmp.dir };

    var image: [4 * raw_sector_bytes]u8 = undefined;
    fillPattern(&image, 0x55);
    {
        var f = try dir.createFile("Disc Image.bin", .{});
        defer f.close();
        try f.writeAll(&image);
    }
    const sheet =
        \\FILE "Disc Image.bin" BINARY
        \\  TRACK 01 MODE1/2352
        \\    INDEX 01 00:00:00
        \\  TRACK 02 AUDIO
        \\    INDEX 01 00:00:02
    ;
    {
        var f = try dir.createFile("disc.cue", .{});
        defer f.close();
        try f.writeAll(sheet);
    }

    const dir_path = try dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(dir_path);
    const cue_path = try std.fs.path.join(testing.allocator, &.{ dir_path, "disc.cue" });
    defer testing.allocator.free(cue_path);

    var disc = try Disc.openCuePath(testing.allocator, cue_path);
    defer disc.deinit();
    try testing.expectEqual(@as(u32, 4), disc.leadOutLba());
    try testing.expectEqual(@as(u32, 2), disc.trackAt(3).?.start_lba);

    var raw: [raw_sector_bytes]u8 = undefined;
    try disc.readSector(3, &raw);
    try testing.expectEqualSlices(u8, image[3 * raw_sector_bytes ..][0..raw_sector_bytes], &raw);
    try disc.readSector(0, &raw);
    try testing.expectEqualSlices(u8, image[0..raw_sector_bytes], &raw);

    // A sheet naming a missing BIN fails to open.
    {
        var f = try dir.createFile("bad.cue", .{});
        defer f.close();
        try f.writeAll("FILE \"nope.bin\" BINARY\nTRACK 01 AUDIO\nINDEX 01 00:00:00\n");
    }
    const bad_path = try std.fs.path.join(testing.allocator, &.{ dir_path, "bad.cue" });
    defer testing.allocator.free(bad_path);
    try testing.expectError(error.FileNotFound, Disc.openCuePath(testing.allocator, bad_path));

    // Bare ISO open.
    var iso: [2 * user_data_bytes]u8 = undefined;
    fillPattern(&iso, 9);
    {
        var f = try dir.createFile("game.iso", .{});
        defer f.close();
        try f.writeAll(&iso);
    }
    const iso_path = try std.fs.path.join(testing.allocator, &.{ dir_path, "game.iso" });
    defer testing.allocator.free(iso_path);
    var iso_disc = try Disc.openIsoPath(testing.allocator, iso_path);
    defer iso_disc.deinit();
    try testing.expectEqual(@as(u32, 2), iso_disc.leadOutLba());
    try iso_disc.readSector(1, &raw);
    try testing.expectEqualSlices(u8, iso[user_data_bytes..], raw[16 .. 16 + user_data_bytes]);
}

test "clone duplicates a memory disc and reopens a file disc" {
    var image: [2 * user_data_bytes]u8 = undefined;
    fillPattern(&image, 3);
    var disc = try Disc.fromMemory(testing.allocator, null, &.{&image});
    defer disc.deinit();
    var copy = try disc.clone();
    defer copy.deinit();
    // The copy owns its bytes: mutating the original image does not leak in.
    image[16] = 0xEE;
    var raw: [raw_sector_bytes]u8 = undefined;
    try copy.readSector(0, &raw);
    try testing.expectEqual(@as(u8, @truncate(3 + 16 * 7)), raw[16 + 16]);
    try testing.expectEqual(disc.leadOutLba(), copy.leadOutLba());
    try testing.expect(copy.source_path == null);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = platform.Dir{ .d = tmp.dir };
    {
        var f = try dir.createFile("c.iso", .{});
        defer f.close();
        try f.writeAll(&image);
    }
    const dir_path = try dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(dir_path);
    const iso_path = try std.fs.path.join(testing.allocator, &.{ dir_path, "c.iso" });
    defer testing.allocator.free(iso_path);
    var file_disc = try Disc.openIsoPath(testing.allocator, iso_path);
    defer file_disc.deinit();
    var file_copy = try file_disc.clone();
    defer file_copy.deinit();
    try testing.expectEqualStrings(iso_path, file_copy.source_path.?);
    try file_copy.readSector(1, &raw);
    try testing.expectEqualSlices(u8, image[user_data_bytes..], raw[16 .. 16 + user_data_bytes]);
}
