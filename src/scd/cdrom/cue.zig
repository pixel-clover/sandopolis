//! CUE sheet parser producing a disc layout: files, tracks, and absolute
//! logical block addresses. The parser is filesystem-free; file sizes come
//! through a callback so it can run on in-memory images (wasm, tests).
//!
//! Supported directives: FILE "name" BINARY|WAVE, TRACK nn MODE1/2048 |
//! MODE1/2352 | MODE2/2352 | AUDIO, INDEX nn mm:ss:ff, PREGAP mm:ss:ff,
//! POSTGAP mm:ss:ff, and REM/CATALOG/TITLE/PERFORMER/FLAGS/ISRC (ignored).

const std = @import("std");
const msf = @import("msf.zig");

pub const TrackKind = enum {
    mode1_2048,
    mode1_2352,
    mode2_2352,
    audio,

    pub fn bytesPerSector(self: TrackKind) u32 {
        return switch (self) {
            .mode1_2048 => 2048,
            .mode1_2352, .mode2_2352, .audio => 2352,
        };
    }

    pub fn isData(self: TrackKind) bool {
        return self != .audio;
    }
};

pub const FileKind = enum { binary, wave };

/// Byte offset of PCM data in a canonical 44-byte WAVE header.
pub const wave_header_bytes: u64 = 44;

pub const FileEntry = struct {
    name: []const u8,
    kind: FileKind,
    size_bytes: u64,

    /// Bytes available for sector data (WAVE headers are skipped).
    pub fn dataBytes(self: FileEntry) u64 {
        return switch (self.kind) {
            .binary => self.size_bytes,
            .wave => if (self.size_bytes > wave_header_bytes) self.size_bytes - wave_header_bytes else 0,
        };
    }

    pub fn dataOffset(self: FileEntry) u64 {
        return switch (self.kind) {
            .binary => 0,
            .wave => wave_header_bytes,
        };
    }
};

pub const Track = struct {
    number: u8,
    kind: TrackKind,
    file_index: u16,
    /// Sector index within the file where INDEX 01 begins.
    file_sector: u32,
    /// Absolute LBA where the track's pregap region begins (INDEX 00 or the
    /// start of a virtual PREGAP). Equals `start_lba` when there is none.
    pregap_lba: u32,
    /// Absolute LBA of INDEX 01.
    start_lba: u32,
    /// Absolute LBA one past the last sector belonging to this track.
    end_lba: u32,
    /// Sectors of the pregap that exist in the file (INDEX 00 to INDEX 01),
    /// as opposed to virtual PREGAP sectors which read as zero.
    pregap_sectors_in_file: u32,

    pub fn lengthSectors(self: Track) u32 {
        return self.end_lba - self.start_lba;
    }

    pub fn containsLba(self: Track, lba: u32) bool {
        return lba >= self.pregap_lba and lba < self.end_lba;
    }

    /// Byte offset within the file's data area for an LBA inside this track,
    /// or null for virtual-pregap sectors that have no backing bytes.
    pub fn fileByteOffset(self: Track, lba: u32) ?u64 {
        const bps: u64 = self.kind.bytesPerSector();
        if (lba >= self.start_lba) {
            return (@as(u64, self.file_sector) + (lba - self.start_lba)) * bps;
        }
        // Inside the pregap: only the in-file portion is backed by data.
        const before_start = self.start_lba - lba;
        if (before_start > self.pregap_sectors_in_file) return null;
        return (@as(u64, self.file_sector) - before_start) * bps;
    }
};

pub const Layout = struct {
    allocator: std.mem.Allocator,
    files: []FileEntry,
    tracks: []Track,
    lead_out_lba: u32,

    pub fn deinit(self: *Layout) void {
        for (self.files) |f| self.allocator.free(f.name);
        self.allocator.free(self.files);
        self.allocator.free(self.tracks);
        self.* = undefined;
    }

    pub fn trackAt(self: *const Layout, lba: u32) ?*const Track {
        for (self.tracks) |*t| {
            if (t.containsLba(lba)) return t;
        }
        return null;
    }

    pub fn firstTrack(self: *const Layout) u8 {
        return self.tracks[0].number;
    }

    pub fn lastTrack(self: *const Layout) u8 {
        return self.tracks[self.tracks.len - 1].number;
    }

    pub fn trackByNumber(self: *const Layout, number: u8) ?*const Track {
        for (self.tracks) |*t| {
            if (t.number == number) return t;
        }
        return null;
    }
};

pub const ParseError = error{
    MissingFile,
    MissingTrack,
    MissingIndex01,
    UnsupportedTrackMode,
    UnsupportedFileType,
    MalformedLine,
    FileNotFound,
    NoTracks,
    OutOfMemory,
};

/// Resolves a FILE name (as written in the sheet) to its size in bytes, or
/// null when the file does not exist.
pub const FileSizeFn = *const fn (ctx: ?*anyopaque, name: []const u8) ?u64;

const PendingTrack = struct {
    number: u8,
    kind: TrackKind,
    file_index: u16,
    index00: ?u32 = null,
    index01: ?u32 = null,
    pregap: u32 = 0,
    postgap: u32 = 0,
};

pub fn parse(allocator: std.mem.Allocator, text: []const u8, size_ctx: ?*anyopaque, size_fn: FileSizeFn) ParseError!Layout {
    var files = std.ArrayList(FileEntry).empty;
    errdefer {
        for (files.items) |f| allocator.free(f.name);
        files.deinit(allocator);
    }
    var pending = std.ArrayList(PendingTrack).empty;
    defer pending.deinit(allocator);

    var lines = std.mem.splitAny(u8, text, "\r\n");
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t");
        if (line.len == 0) continue;
        var it = std.mem.tokenizeAny(u8, line, " \t");
        const keyword = it.next() orelse continue;

        if (std.ascii.eqlIgnoreCase(keyword, "FILE")) {
            const name = try parseFileName(it.rest());
            const type_word = lastWord(it.rest()) orelse return error.MalformedLine;
            const kind: FileKind = if (std.ascii.eqlIgnoreCase(type_word, "BINARY"))
                .binary
            else if (std.ascii.eqlIgnoreCase(type_word, "WAVE"))
                .wave
            else
                return error.UnsupportedFileType;
            const size = size_fn(size_ctx, name) orelse return error.FileNotFound;
            const owned = try allocator.dupe(u8, name);
            errdefer allocator.free(owned);
            try files.append(allocator, .{ .name = owned, .kind = kind, .size_bytes = size });
        } else if (std.ascii.eqlIgnoreCase(keyword, "TRACK")) {
            if (files.items.len == 0) return error.MissingFile;
            const num_word = it.next() orelse return error.MalformedLine;
            const mode_word = it.next() orelse return error.MalformedLine;
            const number = std.fmt.parseUnsigned(u8, num_word, 10) catch return error.MalformedLine;
            const kind: TrackKind = if (std.ascii.eqlIgnoreCase(mode_word, "MODE1/2048"))
                .mode1_2048
            else if (std.ascii.eqlIgnoreCase(mode_word, "MODE1/2352"))
                .mode1_2352
            else if (std.ascii.eqlIgnoreCase(mode_word, "MODE2/2352"))
                .mode2_2352
            else if (std.ascii.eqlIgnoreCase(mode_word, "AUDIO"))
                .audio
            else
                return error.UnsupportedTrackMode;
            try pending.append(allocator, .{
                .number = number,
                .kind = kind,
                .file_index = @intCast(files.items.len - 1),
            });
        } else if (std.ascii.eqlIgnoreCase(keyword, "INDEX")) {
            const track = lastPending(&pending) orelse return error.MissingTrack;
            const idx_word = it.next() orelse return error.MalformedLine;
            const time_word = it.next() orelse return error.MalformedLine;
            const idx = std.fmt.parseUnsigned(u8, idx_word, 10) catch return error.MalformedLine;
            const sectors = try parseTime(time_word);
            switch (idx) {
                0 => track.index00 = sectors,
                1 => track.index01 = sectors,
                else => {}, // Sub-indices carry no layout meaning here.
            }
        } else if (std.ascii.eqlIgnoreCase(keyword, "PREGAP")) {
            const track = lastPending(&pending) orelse return error.MissingTrack;
            track.pregap = try parseTime(it.next() orelse return error.MalformedLine);
        } else if (std.ascii.eqlIgnoreCase(keyword, "POSTGAP")) {
            const track = lastPending(&pending) orelse return error.MissingTrack;
            track.postgap = try parseTime(it.next() orelse return error.MalformedLine);
        }
        // REM, CATALOG, TITLE, PERFORMER, FLAGS, ISRC, SONGWRITER: ignored.
    }

    if (pending.items.len == 0) return error.NoTracks;

    var tracks = try allocator.alloc(Track, pending.items.len);
    errdefer allocator.free(tracks);

    // Lay files out back to back on the disc. Virtual PREGAP/POSTGAP
    // sectors are inserted into the disc address space without consuming
    // file bytes.
    var disc_cursor: u32 = 0; // disc LBA of the next file's sector 0 (before virtual gaps)
    var file_i: usize = 0;
    var t: usize = 0;
    while (file_i < files.items.len) : (file_i += 1) {
        const file = files.items[file_i];
        const first_t = t;
        var virtual_accum: u32 = 0;
        var bytes_per_sector: u32 = 2352;
        while (t < pending.items.len and pending.items[t].file_index == file_i) : (t += 1) {
            const p = pending.items[t];
            if (t == first_t) bytes_per_sector = p.kind.bytesPerSector();
            const index01 = p.index01 orelse return error.MissingIndex01;
            const index00 = p.index00 orelse index01;
            if (index00 > index01) return error.MalformedLine;
            virtual_accum += p.pregap;
            const in_file_pregap = index01 - index00;
            const start_lba = disc_cursor + virtual_accum + index01;
            tracks[t] = .{
                .number = p.number,
                .kind = p.kind,
                .file_index = @intCast(file_i),
                .file_sector = index01,
                .pregap_lba = start_lba - in_file_pregap - p.pregap,
                .start_lba = start_lba,
                .end_lba = 0, // filled below
                .pregap_sectors_in_file = in_file_pregap,
            };
            virtual_accum += p.postgap;
        }
        if (t == first_t) continue; // FILE with no tracks: contributes nothing.

        const file_sectors: u32 = @intCast(file.dataBytes() / bytes_per_sector);
        const file_end_lba = disc_cursor + virtual_accum + file_sectors;
        // Track ends: next track's pregap start within the same file, else
        // the end of the file.
        var k = first_t;
        while (k < t) : (k += 1) {
            tracks[k].end_lba = if (k + 1 < t) tracks[k + 1].pregap_lba else file_end_lba;
            if (tracks[k].end_lba < tracks[k].start_lba) tracks[k].end_lba = tracks[k].start_lba;
        }
        disc_cursor = file_end_lba;
    }

    return .{
        .allocator = allocator,
        .files = try files.toOwnedSlice(allocator),
        .tracks = tracks,
        .lead_out_lba = disc_cursor,
    };
}

fn lastPending(list: *std.ArrayList(PendingTrack)) ?*PendingTrack {
    if (list.items.len == 0) return null;
    return &list.items[list.items.len - 1];
}

fn lastWord(rest: []const u8) ?[]const u8 {
    const trimmed = std.mem.trimEnd(u8, rest, " \t");
    if (trimmed.len == 0) return null;
    const start = if (std.mem.lastIndexOfAny(u8, trimmed, " \t")) |i| i + 1 else 0;
    return trimmed[start..];
}

/// FILE argument: a quoted name (may contain spaces) or a bare word,
/// followed by the type word.
fn parseFileName(rest: []const u8) ParseError![]const u8 {
    const trimmed = std.mem.trim(u8, rest, " \t");
    if (trimmed.len == 0) return error.MalformedLine;
    if (trimmed[0] == '"') {
        const close = std.mem.indexOfScalarPos(u8, trimmed, 1, '"') orelse return error.MalformedLine;
        return trimmed[1..close];
    }
    const end = std.mem.indexOfAny(u8, trimmed, " \t") orelse return error.MalformedLine;
    return trimmed[0..end];
}

/// mm:ss:ff -> sector count.
fn parseTime(word: []const u8) ParseError!u32 {
    var it = std.mem.splitScalar(u8, word, ':');
    const m = std.fmt.parseUnsigned(u8, it.next() orelse return error.MalformedLine, 10) catch return error.MalformedLine;
    const s = std.fmt.parseUnsigned(u8, it.next() orelse return error.MalformedLine, 10) catch return error.MalformedLine;
    const f = std.fmt.parseUnsigned(u8, it.next() orelse return error.MalformedLine, 10) catch return error.MalformedLine;
    if (it.next() != null or s >= 60 or f >= 75) return error.MalformedLine;
    return (msf.Msf{ .m = m, .s = s, .f = f }).toSectors();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const SizeTable = struct {
    entries: []const struct { name: []const u8, size: u64 },

    fn lookup(ctx: ?*anyopaque, name: []const u8) ?u64 {
        const self: *const SizeTable = @ptrCast(@alignCast(ctx.?));
        for (self.entries) |e| {
            if (std.mem.eql(u8, e.name, name)) return e.size;
        }
        return null;
    }
};

test "single bin with data track and audio tracks" {
    // Data track 0..999, audio 2 with in-file pregap at 1000..1149 and
    // start 1150, audio 3 starting at 3000 with no pregap. File holds 5000
    // raw sectors.
    const sheet =
        \\FILE "Game (USA).bin" BINARY
        \\  TRACK 01 MODE1/2352
        \\    INDEX 01 00:00:00
        \\  TRACK 02 AUDIO
        \\    INDEX 00 00:13:25
        \\    INDEX 01 00:15:25
        \\  TRACK 03 AUDIO
        \\    INDEX 01 00:40:00
    ;
    var table = SizeTable{ .entries = &.{.{ .name = "Game (USA).bin", .size = 5000 * 2352 }} };
    var layout = try parse(testing.allocator, sheet, &table, SizeTable.lookup);
    defer layout.deinit();

    try testing.expectEqual(@as(usize, 1), layout.files.len);
    try testing.expectEqual(@as(usize, 3), layout.tracks.len);
    try testing.expectEqual(@as(u32, 5000), layout.lead_out_lba);

    const t1 = layout.tracks[0];
    try testing.expectEqual(TrackKind.mode1_2352, t1.kind);
    try testing.expectEqual(@as(u32, 0), t1.start_lba);
    try testing.expectEqual(@as(u32, 1000), t1.end_lba);

    const t2 = layout.tracks[1];
    try testing.expectEqual(TrackKind.audio, t2.kind);
    try testing.expectEqual(@as(u32, 1000), t2.pregap_lba);
    try testing.expectEqual(@as(u32, 1150), t2.start_lba);
    try testing.expectEqual(@as(u32, 3000), t2.end_lba);
    try testing.expectEqual(@as(u32, 150), t2.pregap_sectors_in_file);
    try testing.expectEqual(@as(u64, 1150 * 2352), t2.fileByteOffset(1150).?);
    try testing.expectEqual(@as(u64, 1000 * 2352), t2.fileByteOffset(1000).?);

    const t3 = layout.tracks[2];
    try testing.expectEqual(@as(u32, 3000), t3.start_lba);
    try testing.expectEqual(@as(u32, 5000), t3.end_lba);
    try testing.expectEqual(@as(u32, 2000), t3.lengthSectors());

    try testing.expectEqual(@as(u8, 1), layout.trackAt(999).?.number);
    try testing.expectEqual(@as(u8, 2), layout.trackAt(1000).?.number);
    try testing.expectEqual(@as(u8, 3), layout.trackAt(4999).?.number);
    try testing.expect(layout.trackAt(5000) == null);
}

test "multi file sheet with virtual pregaps and a wave file" {
    const sheet =
        \\REM COMMENT "made up"
        \\FILE "data.iso" BINARY
        \\  TRACK 01 MODE1/2048
        \\    INDEX 01 00:00:00
        \\FILE "track02.bin" BINARY
        \\  TRACK 02 AUDIO
        \\    PREGAP 00:02:00
        \\    INDEX 01 00:00:00
        \\FILE "track03.wav" WAVE
        \\  TRACK 03 AUDIO
        \\    PREGAP 00:02:00
        \\    INDEX 01 00:00:00
    ;
    var table = SizeTable{ .entries = &.{
        .{ .name = "data.iso", .size = 1000 * 2048 },
        .{ .name = "track02.bin", .size = 300 * 2352 },
        .{ .name = "track03.wav", .size = 44 + 200 * 2352 },
    } };
    var layout = try parse(testing.allocator, sheet, &table, SizeTable.lookup);
    defer layout.deinit();

    try testing.expectEqual(@as(usize, 3), layout.files.len);
    try testing.expectEqual(FileKind.wave, layout.files[2].kind);
    try testing.expectEqual(@as(u64, 200 * 2352), layout.files[2].dataBytes());

    const t1 = layout.tracks[0];
    try testing.expectEqual(TrackKind.mode1_2048, t1.kind);
    try testing.expectEqual(@as(u32, 0), t1.start_lba);
    try testing.expectEqual(@as(u32, 1000), t1.end_lba);

    // Track 2: 150 virtual pregap sectors after the data file, then 300.
    const t2 = layout.tracks[1];
    try testing.expectEqual(@as(u32, 1000), t2.pregap_lba);
    try testing.expectEqual(@as(u32, 1150), t2.start_lba);
    try testing.expectEqual(@as(u32, 1450), t2.end_lba);
    try testing.expectEqual(@as(u32, 0), t2.pregap_sectors_in_file);
    try testing.expect(t2.fileByteOffset(1100) == null); // virtual pregap
    try testing.expectEqual(@as(u64, 0), t2.fileByteOffset(1150).?);

    const t3 = layout.tracks[2];
    try testing.expectEqual(@as(u32, 1450), t3.pregap_lba);
    try testing.expectEqual(@as(u32, 1600), t3.start_lba);
    try testing.expectEqual(@as(u32, 1800), t3.end_lba);
    try testing.expectEqual(@as(u32, 1800), layout.lead_out_lba);
    try testing.expectEqual(@as(u8, 1), layout.firstTrack());
    try testing.expectEqual(@as(u8, 3), layout.lastTrack());
    try testing.expectEqual(@as(u32, 1600), layout.trackByNumber(3).?.start_lba);
}

test "unquoted file names and case-insensitive keywords" {
    const sheet = "file game.bin binary\ntrack 01 mode1/2352\nindex 01 00:00:00\n";
    var table = SizeTable{ .entries = &.{.{ .name = "game.bin", .size = 10 * 2352 }} };
    var layout = try parse(testing.allocator, sheet, &table, SizeTable.lookup);
    defer layout.deinit();
    try testing.expectEqualStrings("game.bin", layout.files[0].name);
    try testing.expectEqual(@as(u32, 10), layout.lead_out_lba);
}

test "malformed sheets are rejected" {
    var table = SizeTable{ .entries = &.{.{ .name = "a.bin", .size = 2352 }} };
    try testing.expectError(error.MissingFile, parse(testing.allocator, "TRACK 01 AUDIO\nINDEX 01 00:00:00\n", &table, SizeTable.lookup));
    try testing.expectError(error.FileNotFound, parse(testing.allocator, "FILE \"missing.bin\" BINARY\nTRACK 01 AUDIO\nINDEX 01 00:00:00\n", &table, SizeTable.lookup));
    try testing.expectError(error.UnsupportedTrackMode, parse(testing.allocator, "FILE \"a.bin\" BINARY\nTRACK 01 CDG\nINDEX 01 00:00:00\n", &table, SizeTable.lookup));
    try testing.expectError(error.UnsupportedFileType, parse(testing.allocator, "FILE \"a.bin\" MP3\nTRACK 01 AUDIO\nINDEX 01 00:00:00\n", &table, SizeTable.lookup));
    try testing.expectError(error.MissingIndex01, parse(testing.allocator, "FILE \"a.bin\" BINARY\nTRACK 01 AUDIO\nINDEX 00 00:00:00\n", &table, SizeTable.lookup));
    try testing.expectError(error.MalformedLine, parse(testing.allocator, "FILE \"a.bin\" BINARY\nTRACK 01 AUDIO\nINDEX 01 00:99:00\n", &table, SizeTable.lookup));
    try testing.expectError(error.MalformedLine, parse(testing.allocator, "FILE \"a.bin\" BINARY\nTRACK 01 AUDIO\nINDEX 01 0:0\n", &table, SizeTable.lookup));
    try testing.expectError(error.MissingTrack, parse(testing.allocator, "FILE \"a.bin\" BINARY\nINDEX 01 00:00:00\n", &table, SizeTable.lookup));
    try testing.expectError(error.NoTracks, parse(testing.allocator, "FILE \"a.bin\" BINARY\n", &table, SizeTable.lookup));
}
