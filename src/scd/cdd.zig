//! CDD: the CD drive controller. The sub CPU talks to it through ten
//! command nibbles (0xFF8042-0xFF804B) and reads ten status nibbles
//! (0xFF8038-0xFF8041). Both carry a checksum nibble.
//!
//! The drive updates its status once per sector period (75 Hz). Each tick
//! also raises INT4 when host communication is enabled (HOCK) and, while
//! playing, delivers one sector: data sectors go to the CDC decoder, audio
//! sectors to the CD-DA output.

const std = @import("std");
const msf = @import("cdrom/msf.zig");
const Disc = @import("cdrom/reader.zig").Disc;
const reader = @import("cdrom/reader.zig");

pub const DriveStatus = enum(u4) {
    stopped = 0x0,
    playing = 0x1,
    seeking = 0x2,
    scanning = 0x3,
    paused = 0x4,
    tray_open = 0x5,
    no_valid_toc = 0x6,
    reading_toc = 0x7,
    no_disc = 0xB,
    lead_out = 0xC,
    lead_in = 0xD,
    tray_moving = 0xE,
    test_mode = 0xF,
};

pub const ReportFormat = enum(u4) {
    absolute_time = 0x0,
    relative_time = 0x1,
    track_number = 0x2,
    disc_length = 0x3,
    first_last_track = 0x4,
    track_start_time = 0x5,
    error_report = 0x6,
    not_ready = 0xF,
};

pub const Command = enum(u4) {
    status = 0x0,
    stop = 0x1,
    report = 0x2,
    play = 0x3,
    seek = 0x4,
    pause = 0x6,
    resume_play = 0x7,
    scan_forward = 0x8,
    scan_backward = 0x9,
    track_skip = 0xA,
    track_cue = 0xB,
    close_tray = 0xC,
    open_tray = 0xD,
    _,
};

/// Sector delivered by the drive during one tick.
pub const SectorEvent = union(enum) {
    none,
    data: struct { lba: u32, raw: *const [reader.raw_sector_bytes]u8 },
    audio: struct { lba: u32, frames: *const [reader.audio_frames_per_sector][2]i16 },
};

/// Scan speed: sectors skipped per tick during FF/RW.
pub const scan_sectors_per_tick: u32 = 10;

pub fn checksum(nibbles: *const [10]u8) u8 {
    var sum: u32 = 0;
    for (nibbles[0..9]) |n| sum += n & 0x0F;
    return @intCast((~sum) & 0x0F);
}

pub const Cdd = struct {
    status: [10]u8 = [_]u8{0} ** 10,
    drive: DriveStatus = .no_disc,
    format: ReportFormat = .absolute_time,
    /// Current head position.
    lba: u32 = 0,
    /// Track the head is on (0 when in lead-out or stopped).
    track: u8 = 0,
    seek_target: u32 = 0,
    seek_ticks_left: u32 = 0,
    /// State to enter when a seek completes.
    after_seek: DriveStatus = .paused,
    /// Requested track for track-number/track-start reports.
    report_track: u8 = 1,
    /// Volume 0x000-0x3FF applied to CD-DA (from 0xFF8034 bits 4-14).
    fader: u16 = 0x3FF,
    disc_present: bool = false,
    raw_sector: [reader.raw_sector_bytes]u8 = [_]u8{0} ** reader.raw_sector_bytes,
    audio_frames: [reader.audio_frames_per_sector][2]i16 = [_][2]i16{.{ 0, 0 }} ** reader.audio_frames_per_sector,
    scan_forward: bool = true,

    pub fn init(disc_present: bool) Cdd {
        var cdd = Cdd{ .disc_present = disc_present };
        cdd.drive = if (disc_present) .stopped else .no_disc;
        cdd.updateStatus(null);
        return cdd;
    }

    pub fn setFaderRegister(self: *Cdd, reg: u16) void {
        self.fader = (reg >> 4) & 0x3FF;
    }

    // -----------------------------------------------------------------------
    // Commands
    // -----------------------------------------------------------------------

    /// Process a completed ten-nibble command. Returns false when the
    /// checksum does not match (the command is ignored).
    pub fn command(self: *Cdd, cmd: *const [10]u8, disc: ?*Disc) bool {
        if (checksum(cmd) != (cmd[9] & 0x0F)) return false;
        const code: Command = @enumFromInt(@as(u4, @truncate(cmd[0])));

        if (!self.disc_present and code != .close_tray and code != .open_tray) {
            self.drive = .no_disc;
            self.updateStatus(disc);
            return true;
        }

        switch (code) {
            .status => {},
            .stop => {
                self.drive = .stopped;
                self.lba = 0;
                self.track = 0;
            },
            .report => {
                self.format = @enumFromInt(@as(u4, @truncate(cmd[3])));
                if (self.format == .track_start_time or self.format == .track_number) {
                    self.report_track = msf.fromBcd(@intCast(((cmd[4] & 0x0F) << 4) | (cmd[5] & 0x0F)));
                }
            },
            .play => {
                self.startSeek(commandLba(cmd), .playing, disc);
            },
            .seek => {
                self.startSeek(commandLba(cmd), .paused, disc);
            },
            .pause => {
                if (self.drive == .playing or self.drive == .scanning) self.drive = .paused;
            },
            .resume_play => {
                if (self.drive == .paused) self.drive = .playing;
            },
            .scan_forward, .scan_backward => {
                self.drive = .scanning;
                self.after_seek = if (code == .scan_forward) .playing else .paused;
                self.seek_ticks_left = 0;
                self.scan_forward = code == .scan_forward;
            },
            .track_skip, .track_cue => {
                // Track-relative positioning: seek to the start of track N
                // (nibbles 4-5, BCD) and pause there.
                const n = msf.fromBcd(@intCast(((cmd[4] & 0x0F) << 4) | (cmd[5] & 0x0F)));
                if (disc) |d| {
                    if (d.trackByNumber(n)) |t| self.startSeek(t.start_lba, .paused, disc);
                }
            },
            .close_tray => {
                self.drive = if (self.disc_present) .stopped else .no_disc;
                self.lba = 0;
            },
            .open_tray => {
                self.drive = .tray_open;
                self.lba = 0;
            },
            _ => {},
        }
        self.updateStatus(disc);
        return true;
    }

    fn commandLba(cmd: *const [10]u8) u32 {
        const m = msf.fromBcd(@intCast(((cmd[2] & 0x0F) << 4) | (cmd[3] & 0x0F)));
        const s = msf.fromBcd(@intCast(((cmd[4] & 0x0F) << 4) | (cmd[5] & 0x0F)));
        const f = msf.fromBcd(@intCast(((cmd[6] & 0x0F) << 4) | (cmd[7] & 0x0F)));
        return msf.msfToLba(.{ .m = m, .s = s, .f = f });
    }

    fn startSeek(self: *Cdd, target: u32, then: DriveStatus, disc: ?*Disc) void {
        var clamped = target;
        if (disc) |d| {
            if (clamped >= d.leadOutLba()) clamped = d.leadOutLba() - 1;
        }
        const distance = if (clamped > self.lba) clamped - self.lba else self.lba - clamped;
        self.seek_target = clamped;
        self.seek_ticks_left = @max(1, distance / 1000);
        self.after_seek = then;
        self.drive = .seeking;
    }

    // -----------------------------------------------------------------------
    // 75 Hz tick
    // -----------------------------------------------------------------------

    /// Advance one sector period. Returns the sector delivered this tick.
    pub fn tick(self: *Cdd, disc: ?*Disc) SectorEvent {
        var event: SectorEvent = .none;
        switch (self.drive) {
            .seeking => {
                self.seek_ticks_left -|= 1;
                if (self.seek_ticks_left == 0) {
                    self.lba = self.seek_target;
                    self.drive = self.after_seek;
                }
            },
            .playing => {
                if (disc) |d| {
                    if (self.lba >= d.leadOutLba()) {
                        self.drive = .lead_out;
                    } else {
                        event = self.deliver(d);
                        self.lba += 1;
                    }
                }
            },
            .scanning => {
                if (disc) |d| {
                    if (self.scan_forward) {
                        self.lba = @min(self.lba + scan_sectors_per_tick, d.leadOutLba() - 1);
                    } else {
                        self.lba -|= scan_sectors_per_tick;
                    }
                }
            },
            else => {},
        }
        self.updateStatus(disc);
        return event;
    }

    fn deliver(self: *Cdd, d: *Disc) SectorEvent {
        const track = d.trackAt(self.lba) orelse return .none;
        self.track = track.number;
        if (track.kind == .audio) {
            d.readAudioSector(self.lba, &self.audio_frames) catch return .none;
            return .{ .audio = .{ .lba = self.lba, .frames = &self.audio_frames } };
        }
        d.readSector(self.lba, &self.raw_sector) catch return .none;
        return .{ .data = .{ .lba = self.lba, .raw = &self.raw_sector } };
    }

    // -----------------------------------------------------------------------
    // Status nibbles
    // -----------------------------------------------------------------------

    fn putBcd(self: *Cdd, index: usize, value: u8) void {
        const bcd = msf.toBcd(value);
        self.status[index] = bcd >> 4;
        self.status[index + 1] = bcd & 0x0F;
    }

    fn putMsf(self: *Cdd, lba: u32) void {
        const time = msf.lbaToMsf(lba);
        self.putBcd(2, time.m);
        self.putBcd(4, time.s);
        self.putBcd(6, time.f);
    }

    pub fn updateStatus(self: *Cdd, disc: ?*Disc) void {
        @memset(&self.status, 0);
        self.status[0] = @intFromEnum(self.drive);
        self.status[1] = @intFromEnum(self.format);

        const drive_ready = self.disc_present and disc != null and switch (self.drive) {
            .no_disc, .tray_open, .tray_moving, .test_mode => false,
            else => true,
        };
        if (!drive_ready) {
            self.status[1] = @intFromEnum(ReportFormat.not_ready);
            self.status[9] = checksum(&self.status);
            return;
        }
        const d = disc.?;
        const current = d.trackAt(self.lba);
        switch (self.format) {
            .absolute_time => {
                self.putMsf(self.lba);
                if (current) |t| {
                    if (t.kind.isData()) self.status[8] = 0x4;
                }
            },
            .relative_time => {
                const start = if (current) |t| t.start_lba else 0;
                const rel = if (self.lba >= start) self.lba - start else 0;
                // Relative time has no pregap offset.
                const time = msf.Msf.fromSectors(rel);
                self.putBcd(2, time.m);
                self.putBcd(4, time.s);
                self.putBcd(6, time.f);
                if (current) |t| {
                    if (t.kind.isData()) self.status[8] = 0x4;
                }
            },
            .track_number => {
                const n = if (current) |t| t.number else 0;
                self.putBcd(2, n);
            },
            .disc_length => {
                self.putMsf(d.leadOutLba());
            },
            .first_last_track => {
                self.putBcd(2, d.firstTrack());
                self.putBcd(4, d.lastTrack());
            },
            .track_start_time => {
                if (d.trackByNumber(self.report_track)) |t| {
                    self.putMsf(t.start_lba);
                    if (t.kind.isData()) self.status[6] |= 0x08;
                    self.status[8] = msf.toBcd(t.number) & 0x0F;
                }
            },
            .error_report, .not_ready => {},
        }
        self.status[9] = checksum(&self.status);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn makeCommand(code: u8, args: []const u8) [10]u8 {
    var cmd = [_]u8{0} ** 10;
    cmd[0] = code;
    for (args, 0..) |a, i| cmd[1 + i] = a;
    cmd[9] = checksum(&cmd);
    return cmd;
}

fn testDisc(allocator: std.mem.Allocator, data_bytes: []u8, audio_bytes: []u8) !Disc {
    const sheet =
        \\FILE "d.bin" BINARY
        \\  TRACK 01 MODE1/2048
        \\    INDEX 01 00:00:00
        \\FILE "a.bin" BINARY
        \\  TRACK 02 AUDIO
        \\    PREGAP 00:02:00
        \\    INDEX 01 00:00:00
    ;
    return Disc.fromMemory(allocator, sheet, &.{ data_bytes, audio_bytes });
}

test "checksum is the inverted nibble sum" {
    var n = [_]u8{ 0, 4, 0, 0, 0, 0, 0, 0, 0, 0 };
    try testing.expectEqual(@as(u8, 0xB), checksum(&n));
    n = .{ 1, 0, 0, 2, 0, 0, 7, 4, 0, 0 };
    try testing.expectEqual(@as(u8, (~@as(u32, 14)) & 0xF), checksum(&n));
    // A bad checksum is rejected.
    var cdd = Cdd.init(true);
    var bad = makeCommand(0x1, &.{});
    bad[9] ^= 1;
    try testing.expect(!cdd.command(&bad, null));
}

test "no disc reports 0xB and ignores playback commands" {
    var cdd = Cdd.init(false);
    try testing.expectEqual(@as(u8, 0xB), cdd.status[0]);
    try testing.expectEqual(@as(u8, 0xF), cdd.status[1]);
    try testing.expectEqual(checksum(&cdd.status), cdd.status[9]);
    _ = cdd.command(&makeCommand(0x3, &.{ 0, 0, 0, 0, 2, 0, 0 }), null);
    try testing.expectEqual(DriveStatus.no_disc, cdd.drive);
    _ = cdd.command(&makeCommand(0xD, &.{}), null);
    try testing.expectEqual(DriveStatus.tray_open, cdd.drive);
    try testing.expectEqual(@as(u8, 0x5), cdd.status[0]);
}

test "toc reports: first/last, disc length, track start with data flag" {
    var data: [1000 * 2048]u8 = undefined;
    @memset(&data, 0);
    var audio: [300 * 2352]u8 = undefined;
    @memset(&audio, 0);
    var disc = try testDisc(testing.allocator, &data, &audio);
    defer disc.deinit();
    var cdd = Cdd.init(true);
    cdd.updateStatus(&disc);
    try testing.expectEqual(@as(u8, 0x0), cdd.status[0]); // stopped
    try testing.expectEqual(@as(u8, 0x0), cdd.status[1]);

    // First/last track = 01/02.
    _ = cdd.command(&makeCommand(0x2, &.{ 0, 0, 4 }), &disc);
    try testing.expectEqualSlices(u8, &.{ 0x0, 0x4, 0, 1, 0, 2, 0, 0, 0 }, cdd.status[0..9]);
    try testing.expectEqual(checksum(&cdd.status), cdd.status[9]);

    // Disc length: lead-out at LBA 1450 -> 00:21:25 absolute (1450+150=1600 = 21s 25f).
    _ = cdd.command(&makeCommand(0x2, &.{ 0, 0, 3 }), &disc);
    try testing.expectEqualSlices(u8, &.{ 0x0, 0x3, 0, 0, 2, 1, 2, 5, 0 }, cdd.status[0..9]);

    // Track 1 start: 00:02:00, data flag in S6 bit 3, track number in S8.
    _ = cdd.command(&makeCommand(0x2, &.{ 0, 0, 5, 0, 1 }), &disc);
    try testing.expectEqualSlices(u8, &.{ 0x0, 0x5, 0, 0, 0, 2, 0x8, 0, 1 }, cdd.status[0..9]);
    // Track 2 start: LBA 1150 -> 1300 sectors = 00:17:25, audio: no flag.
    _ = cdd.command(&makeCommand(0x2, &.{ 0, 0, 5, 0, 2 }), &disc);
    try testing.expectEqualSlices(u8, &.{ 0x0, 0x5, 0, 0, 1, 7, 2, 5, 2 }, cdd.status[0..9]);
}

test "play seeks then delivers one sector per tick and stops at lead-out" {
    var data: [20 * 2048]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @truncate(i);
    var audio: [5 * 2352]u8 = undefined;
    @memset(&audio, 0x11);
    var disc = try testDisc(testing.allocator, &data, &audio);
    defer disc.deinit();
    var cdd = Cdd.init(true);
    _ = cdd.command(&makeCommand(0x2, &.{ 0, 0, 0 }), &disc); // absolute time reports

    // Play from 00:02:05 (LBA 5).
    _ = cdd.command(&makeCommand(0x3, &.{ 0, 0, 0, 0, 2, 0, 5 }), &disc);
    try testing.expectEqual(DriveStatus.seeking, cdd.drive);
    try testing.expectEqual(@as(u8, 0x2), cdd.status[0]);
    try testing.expectEqual(SectorEvent.none, cdd.tick(&disc));
    try testing.expectEqual(DriveStatus.playing, cdd.drive);

    const ev = cdd.tick(&disc);
    try testing.expectEqual(@as(u32, 5), ev.data.lba);
    try testing.expectEqual(@as(u8, 5 * 2048 % 256), ev.data.raw[16]);
    try testing.expectEqualSlices(u8, &.{ 0x00, 0x02, 0x05, 0x01 }, ev.data.raw[12..16]);
    // Status shows the head position after the sector was consumed: 00:02:06, data flag.
    try testing.expectEqualSlices(u8, &.{ 0x1, 0x0, 0, 0, 0, 2, 0, 6, 0x4 }, cdd.status[0..9]);

    // Pause holds position; resume continues.
    _ = cdd.command(&makeCommand(0x6, &.{}), &disc);
    try testing.expectEqual(SectorEvent.none, cdd.tick(&disc));
    try testing.expectEqual(@as(u32, 6), cdd.lba);
    _ = cdd.command(&makeCommand(0x7, &.{}), &disc);
    try testing.expectEqual(@as(u32, 6), cdd.tick(&disc).data.lba);

    // Play through the pregap and the audio track to lead-out (LBA 175).
    var audio_sectors: u32 = 0;
    var i: u32 = 0;
    while (i < 200) : (i += 1) {
        switch (cdd.tick(&disc)) {
            .audio => |a| {
                audio_sectors += 1;
                // 150 virtual pregap sectors are silence; the file data follows.
                const expected: i16 = if (a.lba >= 170) 0x1111 else 0;
                try testing.expectEqual(expected, a.frames[0][0]);
            },
            else => {},
        }
        if (cdd.drive == .lead_out) break;
    }
    try testing.expectEqual(DriveStatus.lead_out, cdd.drive);
    try testing.expectEqual(@as(u8, 0xC), cdd.status[0]);
    // 150 virtual pregap sectors (silence) + 5 audio sectors.
    try testing.expectEqual(@as(u32, 155), audio_sectors);

    // Stop rewinds.
    _ = cdd.command(&makeCommand(0x1, &.{}), &disc);
    try testing.expectEqual(DriveStatus.stopped, cdd.drive);
    try testing.expectEqual(@as(u32, 0), cdd.lba);
}

test "seek pauses at the target and relative time counts from track start" {
    var data: [10 * 2048]u8 = undefined;
    @memset(&data, 0);
    var audio: [3000 * 2352]u8 = undefined;
    @memset(&audio, 0);
    var disc = try testDisc(testing.allocator, &data, &audio);
    defer disc.deinit();
    var cdd = Cdd.init(true);

    // Seek to 00:30:00 absolute = LBA 2100, 2100 sectors away -> 2 ticks.
    _ = cdd.command(&makeCommand(0x4, &.{ 0, 0, 0, 3, 0, 0, 0 }), &disc);
    try testing.expectEqual(@as(u32, 2), cdd.seek_ticks_left);
    _ = cdd.tick(&disc);
    try testing.expectEqual(DriveStatus.seeking, cdd.drive);
    _ = cdd.tick(&disc);
    try testing.expectEqual(DriveStatus.paused, cdd.drive);
    try testing.expectEqual(@as(u32, 2100), cdd.lba);

    // Relative time within track 2 (starts at LBA 160): 1940 sectors = 00:25:65.
    _ = cdd.command(&makeCommand(0x2, &.{ 0, 0, 1 }), &disc);
    try testing.expectEqualSlices(u8, &.{ 0x4, 0x1, 0, 0, 2, 5, 6, 5, 0 }, cdd.status[0..9]);
    // Track number report.
    _ = cdd.command(&makeCommand(0x2, &.{ 0, 0, 2 }), &disc);
    try testing.expectEqualSlices(u8, &.{ 0x4, 0x2, 0, 2, 0, 0, 0, 0, 0 }, cdd.status[0..9]);
}

test "fader register maps bits 4-14 to the volume" {
    var cdd = Cdd.init(true);
    cdd.setFaderRegister(0x3FF0);
    try testing.expectEqual(@as(u16, 0x3FF), cdd.fader);
    cdd.setFaderRegister(0x0800);
    try testing.expectEqual(@as(u16, 0x080), cdd.fader);
}
