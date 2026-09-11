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
    /// Motor spinning up / TOC being read. A drive with a disc enters this
    /// by itself after STOP or CLOSE TRAY and stays until positioned.
    reading_toc = 0x9,
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
    /// The decoder ran but the drive had no block to hand over (it is
    /// seeking). The CDC latches a zero header and still raises DECI.
    blank,
    data: struct { lba: i32, raw: *const [reader.raw_sector_bytes]u8 },
    audio: struct { lba: i32, frames: *const [reader.audio_frames_per_sector][2]i16 },
};

/// Scan speed: sectors skipped per tick during FF/RW.
pub const scan_sectors_per_tick: u32 = 10;

/// Drive latency floor, in 75 Hz sector periods. The BIOS hangs when a seek
/// reports its target too soon, and several games need a good deal more; the
/// same 12-interrupt floor is what Genesis Plus GX settled on.
pub const seek_latency_ticks: u32 = 12;

/// How many sector periods before the end of a seek the drive starts
/// reporting the status it is about to reach. The BIOS uses that window to
/// arm the CDC decoder, so without it the first block of a play arrives
/// before anything is listening.
pub const seek_report_lead_ticks: u32 = 3;

/// Largest addressable disc, used to scale seek time with head travel:
/// a full-width seek takes about 1.5 s = 120 sector periods.
const max_disc_sectors: u32 = 270_000;

pub fn checksum(nibbles: *const [10]u8) u8 {
    var sum: u32 = 0;
    for (nibbles[0..9]) |n| sum += n & 0x0F;
    return @intCast((~sum) & 0x0F);
}

pub const Cdd = struct {
    status: [10]u8 = [_]u8{0} ** 10,
    drive: DriveStatus = .no_disc,
    format: ReportFormat = .absolute_time,
    /// Current head position. Negative while the head is parked in the
    /// lead-in, which the BIOS uses during its drive check.
    lba: i32 = 0,
    /// Track the head is on (0 when in lead-out or stopped).
    track: u8 = 0,
    /// Sector periods left before the head settles. While this is non-zero
    /// the drive reads no blocks, even though it already reports the status
    /// and the position it is moving to.
    seek_ticks_left: u32 = 0,
    /// Requested track for track-number/track-start reports.
    report_track: u8 = 1,
    /// Volume 0x000-0x3FF applied to CD-DA (from 0xFF8034 bits 4-14).
    fader: u16 = 0x3FF,
    disc_present: bool = false,
    raw_sector: [reader.raw_sector_bytes]u8 = [_]u8{0} ** reader.raw_sector_bytes,
    audio_frames: [reader.audio_frames_per_sector][2]i16 = [_][2]i16{.{ 0, 0 }} ** reader.audio_frames_per_sector,
    scan_forward: bool = true,

    /// Power-on: the status registers read as all zeros with a valid
    /// checksum until the first command is processed. The BIOS checks for
    /// exactly this pattern during its drive handshake.
    pub fn init(disc_present: bool) Cdd {
        // The drive reports "stopped" until the host stops it or asks for
        // the TOC; only then does an empty tray read back as NO DISC.
        var cdd = Cdd{ .disc_present = disc_present };
        cdd.drive = .stopped;
        cdd.status = [_]u8{0} ** 10;
        cdd.status[9] = checksum(&cdd.status);
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
            // A bare status poll keeps whatever the drive last reported;
            // any real drive command reveals the empty tray.
            if (code != .status) self.drive = .no_disc;
            self.replyDrive();
            return true;
        }

        switch (code) {
            .status => self.replyPoll(disc),
            .stop => self.replyStopped(),
            .report => {
                self.format = @enumFromInt(@as(u4, @truncate(cmd[3])));
                if (self.format == .track_start_time or self.format == .track_number) {
                    self.report_track = msf.fromBcd(@intCast(((cmd[4] & 0x0F) << 4) | (cmd[5] & 0x0F)));
                }
                self.replyReport(self.format, disc);
            },
            .play => {
                self.startSeek(commandLba(cmd), .playing, disc);
                self.replySeeking();
            },
            .seek => {
                self.startSeek(commandLba(cmd), .paused, disc);
                self.replySeeking();
            },
            .pause => {
                if (self.drive == .playing or self.drive == .scanning) self.drive = .paused;
                self.replyDrive();
            },
            .resume_play => {
                if (self.drive == .paused) self.drive = .playing;
                self.replyDrive();
            },
            .scan_forward, .scan_backward => {
                self.drive = .scanning;
                self.seek_ticks_left = 0;
                self.scan_forward = code == .scan_forward;
                self.replyDrive();
            },
            .track_skip, .track_cue => {
                // Track-relative positioning: seek to the start of track N
                // (nibbles 4-5, BCD) and pause there.
                const n = msf.fromBcd(@intCast(((cmd[4] & 0x0F) << 4) | (cmd[5] & 0x0F)));
                const found = if (disc) |d| d.trackByNumber(n) else null;
                if (found) |t| {
                    self.startSeek(@intCast(t.start_lba), .paused, disc);
                    self.replySeeking();
                } else {
                    self.replyDrive();
                }
            },
            .close_tray => {
                if (self.disc_present) {
                    self.replyStopped();
                } else {
                    self.drive = .no_disc;
                    self.lba = 0;
                    self.replyDrive();
                }
            },
            .open_tray => {
                self.drive = .tray_open;
                self.lba = 0;
                self.replyTrayOpen();
            },
            _ => self.replyDrive(),
        }
        return true;
    }

    fn commandLba(cmd: *const [10]u8) i32 {
        const m = msf.fromBcd(@intCast(((cmd[2] & 0x0F) << 4) | (cmd[3] & 0x0F)));
        const s = msf.fromBcd(@intCast(((cmd[4] & 0x0F) << 4) | (cmd[5] & 0x0F)));
        const f = msf.fromBcd(@intCast(((cmd[6] & 0x0F) << 4) | (cmd[7] & 0x0F)));
        return msf.msfToLba(.{ .m = m, .s = s, .f = f });
    }

    fn startSeek(self: *Cdd, target: i32, then: DriveStatus, disc: ?*Disc) void {
        var clamped = target;
        if (disc) |d| {
            const lead_out: i32 = @intCast(d.leadOutLba());
            if (clamped >= lead_out) clamped = lead_out - 1;
        }
        const distance: u32 = @intCast(@abs(clamped - self.lba));
        self.seek_ticks_left = seek_latency_ticks + (distance * 120) / max_disc_sectors;
        // The drive takes on the status and position it is moving to right
        // away. Only the blocks it reads wait for the head to settle, and
        // only its status register keeps saying SEEKING in the meantime.
        self.lba = clamped;
        self.drive = then;
    }

    // -----------------------------------------------------------------------
    // 75 Hz tick
    // -----------------------------------------------------------------------

    /// Advance one sector period. Returns the sector delivered this tick.
    pub fn tick(self: *Cdd, disc: ?*Disc) SectorEvent {
        // While the head is still moving the decoder free-runs on empty
        // blocks; nothing is read off the disc.
        if (self.seek_ticks_left > 0) {
            self.seek_ticks_left -= 1;
            return .blank;
        }
        var event: SectorEvent = .none;
        switch (self.drive) {
            .playing => {
                if (disc) |d| {
                    if (self.lba >= @as(i32, @intCast(d.leadOutLba()))) {
                        self.drive = .lead_out;
                    } else {
                        event = self.deliver(d);
                        self.lba += 1;
                    }
                }
            },
            .scanning => {
                if (disc) |d| {
                    const step: i32 = @intCast(scan_sectors_per_tick);
                    if (self.scan_forward) {
                        self.lba = @min(self.lba + step, @as(i32, @intCast(d.leadOutLba())) - 1);
                    } else {
                        self.lba = @max(self.lba - step, 0);
                    }
                }
            },
            .stopped => {
                // Spin-up: with a disc in the tray the drive reads the TOC on
                // its own one tick after the motor stopped (jgenesis models
                // the same; Genesis Plus GX reports TOC immediately). The
                // BIOS's "CHECKING DISC" step waits for exactly this.
                if (self.disc_present and disc != null) self.drive = .reading_toc;
            },
            else => {},
        }
        // The status registers are deliberately left alone: the drive only
        // rewrites them when it processes a command (see replyPoll).
        return event;
    }

    fn deliver(self: *Cdd, d: *Disc) SectorEvent {
        // The lead-in holds no user data, but the drive still hands over a
        // sector there, carrying a valid header and nothing else. The BIOS
        // counts those while it walks the head onto track 1, so dropping
        // them stalls its disc check.
        if (self.lba < 0) {
            const first = d.trackByNumber(d.firstTrack()) orelse return .none;
            if (first.kind.isData()) {
                @memset(&self.raw_sector, 0);
                reader.writeMode1Header(&self.raw_sector, self.lba);
                return .{ .data = .{ .lba = self.lba, .raw = &self.raw_sector } };
            }
            @memset(&self.audio_frames, .{ 0, 0 });
            return .{ .audio = .{ .lba = self.lba, .frames = &self.audio_frames } };
        }
        const lba: u32 = @intCast(self.lba);
        const track = d.trackAt(lba) orelse return .none;
        self.track = track.number;
        if (track.kind == .audio) {
            d.readAudioSector(lba, &self.audio_frames) catch return .none;
            return .{ .audio = .{ .lba = self.lba, .frames = &self.audio_frames } };
        }
        d.readSector(lba, &self.raw_sector) catch return .none;
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

    fn putMsf(self: *Cdd, lba: i32) void {
        const time = msf.lbaSignedToMsf(lba);
        self.putBcd(2, time.m);
        self.putBcd(4, time.s);
        self.putBcd(6, time.f);
    }

    // -----------------------------------------------------------------------
    // Status registers
    //
    // RS0-RS9 are latched register state, not a recomputed view: the CDD only
    // rewrites them while processing a command, so whatever the last reply
    // left behind is what the host keeps reading between commands. RS1
    // doubles as the "what is being reported" selector, and 0xF means "no
    // valid position" - set while seeking and after a stop, and cleared by
    // the first poll that finds the drive parked again.
    // -----------------------------------------------------------------------

    /// RS1 value meaning "RS2-RS8 hold no valid position".
    const rs1_no_position: u8 = 0xF;

    fn seal(self: *Cdd) void {
        self.status[9] = checksum(&self.status);
    }

    /// Reply carrying only the drive state; RS1-RS8 keep the previous one.
    fn replyDrive(self: *Cdd) void {
        self.status[0] = @intFromEnum(self.drive);
        self.seal();
    }

    /// STOP / CLOSE TRAY: RS0 reports "stopped" once and the position is
    /// invalidated. The drive then spins back up on its own (see `tick`).
    fn replyStopped(self: *Cdd) void {
        self.drive = .stopped;
        self.seek_ticks_left = 0;
        self.lba = 0;
        self.track = 0;
        @memset(&self.status, 0);
        self.status[1] = rs1_no_position;
        self.seal();
    }

    /// OPEN TRAY: like a stop, but the drive stays open.
    fn replyTrayOpen(self: *Cdd) void {
        @memset(&self.status, 0);
        self.status[0] = @intFromEnum(DriveStatus.tray_open);
        self.status[1] = rs1_no_position;
        self.seal();
    }

    /// PLAY / SEEK: the drive reports SEEKING with no valid position and
    /// holds that reply for every poll until it arrives at the target.
    fn replySeeking(self: *Cdd) void {
        @memset(&self.status, 0);
        self.status[0] = @intFromEnum(DriveStatus.seeking);
        self.status[1] = rs1_no_position;
        self.seal();
    }

    /// Command 0x00 (get drive status).
    fn replyPoll(self: *Cdd, disc: ?*Disc) void {
        // A seek in flight keeps answering with the seek command's reply,
        // until the head is nearly there: the drive reports the status it is
        // about to reach a few interrupts early, and that window is what the
        // BIOS uses to arm the CDC decoder before the first block lands.
        if (self.seek_ticks_left > seek_report_lead_ticks) return;

        const reported = self.drive;
        self.status[0] = @intFromEnum(reported);
        const d = disc orelse {
            self.seal();
            return;
        };
        // Stopped, or any state past PAUSE (tray open, no disc, reading the
        // TOC, lead-out): there is no position to report, so RS1-RS8 stand.
        if (reported == .stopped or @intFromEnum(reported) > @intFromEnum(DriveStatus.paused)) {
            self.seal();
            return;
        }
        if (self.status[1] == rs1_no_position) {
            // Seeking has ended, so absolute time is meaningful again.
            self.status[1] = @intFromEnum(ReportFormat.absolute_time);
        }
        // Only the three position formats refresh on a poll; a TOC report
        // stands until the host asks for it again.
        const fmt: ReportFormat = @enumFromInt(@as(u4, @truncate(self.status[1])));
        switch (fmt) {
            .absolute_time, .relative_time, .track_number => self.writeReport(fmt, d),
            else => {},
        }
        self.seal();
    }

    /// Command 0x02 (report TOC / position info): RS1 selects the format.
    fn replyReport(self: *Cdd, fmt: ReportFormat, disc: ?*Disc) void {
        self.status[0] = @intFromEnum(self.drive);
        @memset(self.status[1..9], 0);
        self.status[1] = @intFromEnum(fmt);
        if (disc) |d| self.writeReport(fmt, d);
        self.seal();
    }

    /// Fill RS2-RS8 for one report format.
    fn writeReport(self: *Cdd, fmt: ReportFormat, d: *Disc) void {
        @memset(self.status[2..9], 0);
        // A head in the lead-in belongs to the first track's pregap, so that
        // is the track whose number and type the drive reports.
        const current = if (self.lba >= 0)
            d.trackAt(@intCast(self.lba))
        else
            d.trackByNumber(d.firstTrack());
        switch (fmt) {
            .absolute_time => {
                self.putMsf(self.lba);
                if (current) |t| {
                    if (t.kind.isData()) self.status[8] = 0x4;
                }
            },
            .relative_time => {
                const start: i32 = if (current) |t| @intCast(t.start_lba) else 0;
                const rel: u32 = @intCast(@abs(self.lba - start));
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
                self.putMsf(@intCast(d.leadOutLba()));
            },
            .first_last_track => {
                self.putBcd(2, d.firstTrack());
                self.putBcd(4, d.lastTrack());
            },
            .track_start_time => {
                if (d.trackByNumber(self.report_track)) |t| {
                    self.putMsf(@intCast(t.start_lba));
                    if (t.kind.isData()) self.status[6] |= 0x08;
                    self.status[8] = msf.toBcd(t.number) & 0x0F;
                }
            },
            .error_report, .not_ready => {},
        }
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
    // Power-on: all zeros with a valid checksum until the first command.
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xF }, &cdd.status);
    _ = cdd.command(&makeCommand(0x0, &.{}), null);
    try testing.expectEqual(@as(u8, 0x0), cdd.status[0]); // still "stopped"
    _ = cdd.command(&makeCommand(0x1, &.{}), null);
    try testing.expectEqual(@as(u8, 0xB), cdd.status[0]);
    try testing.expectEqual(@as(u8, 0x0), cdd.status[1]);
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
    _ = cdd.command(&makeCommand(0x0, &.{}), &disc);
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
    try testing.expect(cdd.seek_ticks_left > 0);
    // The seek reply invalidates the position until the head arrives.
    try testing.expectEqualSlices(u8, &.{ 0x2, 0xF, 0, 0, 0, 0, 0, 0, 0 }, cdd.status[0..9]);
    var latency: u32 = 0;
    while (latency < seek_latency_ticks) : (latency += 1) {
        try testing.expectEqual(SectorEvent.blank, cdd.tick(&disc));
        // Polls during the seek keep answering "seeking, no position".
        _ = cdd.command(&makeCommand(0x0, &.{}), &disc);
        // The drive starts reporting its end state a few interrupts early.
        if (seek_latency_ticks - latency - 1 > seek_report_lead_ticks) {
            try testing.expectEqualSlices(u8, &.{ 0x2, 0xF, 0, 0, 0, 0, 0, 0, 0 }, cdd.status[0..9]);
        }
    }
    try testing.expectEqual(@as(u32, 0), cdd.seek_ticks_left);
    // The first poll after arriving re-validates RS1 as absolute time.
    try testing.expectEqualSlices(u8, &.{ 0x1, 0x0, 0, 0, 0, 2, 0, 5, 0x4 }, cdd.status[0..9]);

    const ev = cdd.tick(&disc);
    try testing.expectEqual(@as(i32, 5), ev.data.lba);
    try testing.expectEqual(@as(u8, 5 * 2048 % 256), ev.data.raw[16]);
    try testing.expectEqualSlices(u8, &.{ 0x00, 0x02, 0x05, 0x01 }, ev.data.raw[12..16]);
    // The next poll shows the head position after the sector was consumed:
    // 00:02:06, data flag.
    _ = cdd.command(&makeCommand(0x0, &.{}), &disc);
    try testing.expectEqualSlices(u8, &.{ 0x1, 0x0, 0, 0, 0, 2, 0, 6, 0x4 }, cdd.status[0..9]);

    // Pause holds position; resume continues.
    _ = cdd.command(&makeCommand(0x6, &.{}), &disc);
    try testing.expectEqual(SectorEvent.none, cdd.tick(&disc));
    try testing.expectEqual(@as(i32, 6), cdd.lba);
    _ = cdd.command(&makeCommand(0x7, &.{}), &disc);
    try testing.expectEqual(@as(i32, 6), cdd.tick(&disc).data.lba);

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
    _ = cdd.command(&makeCommand(0x0, &.{}), &disc);
    try testing.expectEqual(@as(u8, 0xC), cdd.status[0]);
    // 150 virtual pregap sectors (silence) + 5 audio sectors.
    try testing.expectEqual(@as(u32, 155), audio_sectors);

    // Stop rewinds.
    _ = cdd.command(&makeCommand(0x1, &.{}), &disc);
    try testing.expectEqual(DriveStatus.stopped, cdd.drive);
    try testing.expectEqual(@as(i32, 0), cdd.lba);
}

test "a loaded disc spins up from stopped to reading-toc without a command" {
    // Both the BIOS and reference cores expect a drive with a disc to leave
    // STOP by itself (motor spin-up + TOC read = status 0x9) and to stay
    // there until the host issues a positioning command.
    var data: [10 * 2048]u8 = undefined;
    @memset(&data, 0);
    var audio: [5 * 2352]u8 = undefined;
    @memset(&audio, 0);
    var disc = try testDisc(testing.allocator, &data, &audio);
    defer disc.deinit();

    var cdd = Cdd.init(true);
    try testing.expectEqual(DriveStatus.stopped, cdd.drive);
    _ = cdd.tick(&disc);
    try testing.expectEqual(DriveStatus.reading_toc, cdd.drive);
    _ = cdd.command(&makeCommand(0x0, &.{}), &disc);
    try testing.expectEqual(@as(u8, 0x9), cdd.status[0]);
    try testing.expectEqual(checksum(&cdd.status), cdd.status[9]);
    // Polling does not change it.
    _ = cdd.tick(&disc);
    _ = cdd.command(&makeCommand(0x0, &.{}), &disc);
    try testing.expectEqual(@as(u8, 0x9), cdd.status[0]);

    // TOC reports still answer while reading the TOC.
    _ = cdd.command(&makeCommand(0x2, &.{ 0, 0, 4 }), &disc);
    try testing.expectEqual(@as(u8, 0x9), cdd.status[0]);
    try testing.expectEqual(@as(u8, 0x4), cdd.status[1]);

    // STOP and CLOSE TRAY go back to stopped, then spin up again. The STOP
    // reply itself is RS0 = 0 with RS1 = F ("no position") and RS2-8 clear.
    _ = cdd.command(&makeCommand(0x1, &.{}), &disc);
    try testing.expectEqual(DriveStatus.stopped, cdd.drive);
    try testing.expectEqualSlices(u8, &.{ 0, 0xF, 0, 0, 0, 0, 0, 0, 0, 0 }, &cdd.status);
    _ = cdd.tick(&disc);
    try testing.expectEqual(DriveStatus.reading_toc, cdd.drive);
    _ = cdd.command(&makeCommand(0xC, &.{}), &disc);
    try testing.expectEqual(DriveStatus.stopped, cdd.drive);
    _ = cdd.tick(&disc);
    try testing.expectEqual(DriveStatus.reading_toc, cdd.drive);

    // A seek leaves the TOC state: the drive takes on the status it is
    // moving to while its register keeps reporting SEEKING.
    _ = cdd.command(&makeCommand(0x4, &.{ 0, 0, 0, 0, 0, 0, 0 }), &disc);
    try testing.expectEqual(DriveStatus.paused, cdd.drive);
    try testing.expect(cdd.seek_ticks_left > 0);
    try testing.expectEqual(@as(u8, @intFromEnum(DriveStatus.seeking)), cdd.status[0]);

    // Without a disc nothing spins up.
    var empty = Cdd.init(false);
    _ = empty.tick(null);
    try testing.expect(empty.drive != .reading_toc);
}

test "a seek reports the status it is about to reach before it arrives" {
    var data: [20 * 2048]u8 = undefined;
    @memset(&data, 0);
    var audio: [5 * 2352]u8 = undefined;
    @memset(&audio, 0);
    var disc = try testDisc(testing.allocator, &data, &audio);
    defer disc.deinit();
    var cdd = Cdd.init(true);

    _ = cdd.command(&makeCommand(0x3, &.{ 0, 0, 0, 0, 2, 0, 5 }), &disc); // play 00:02:05
    const seeking_reply = [_]u8{ 0x2, 0xF, 0, 0, 0, 0, 0, 0, 0 };
    try testing.expectEqualSlices(u8, &seeking_reply, cdd.status[0..9]);

    // Most of the seek answers "seeking, no position".
    var t: u32 = 0;
    while (t < seek_latency_ticks - seek_report_lead_ticks - 1) : (t += 1) {
        _ = cdd.tick(&disc);
        _ = cdd.command(&makeCommand(0x0, &.{}), &disc);
        try testing.expectEqualSlices(u8, &seeking_reply, cdd.status[0..9]);
    }

    // The last few interrupts already report playing at the target, even
    // though the head is still settling and no block has been read.
    while (t < seek_latency_ticks - 1) : (t += 1) {
        _ = cdd.tick(&disc);
        _ = cdd.command(&makeCommand(0x0, &.{}), &disc);
        try testing.expect(cdd.seek_ticks_left > 0);
        try testing.expectEqualSlices(u8, &.{ 0x1, 0x0, 0, 0, 0, 2, 0, 5, 0x4 }, cdd.status[0..9]);
    }
    // Still nothing decoded until the head actually arrives.
    try testing.expectEqual(SectorEvent.blank, cdd.tick(&disc));
    try testing.expectEqual(@as(u32, 0), cdd.seek_ticks_left);
    try testing.expectEqual(@as(i32, 5), cdd.tick(&disc).data.lba);
}

test "the decoder keeps running while the drive seeks" {
    // The CDC decoder free-runs: while the head is moving the drive still
    // clocks it once per sector period with an empty block. The BIOS syncs
    // onto a disc by watching those blocks turn into the sector it asked
    // for, so a drive that goes quiet during a seek breaks its disc check.
    var data: [10 * 2048]u8 = undefined;
    @memset(&data, 0);
    var audio: [5 * 2352]u8 = undefined;
    @memset(&audio, 0);
    var disc = try testDisc(testing.allocator, &data, &audio);
    defer disc.deinit();
    var cdd = Cdd.init(true);

    _ = cdd.command(&makeCommand(0x3, &.{ 0, 0, 0, 0, 2, 0, 5 }), &disc); // play 00:02:05
    var t: u32 = 0;
    while (t < seek_latency_ticks) : (t += 1) {
        try testing.expectEqual(SectorEvent.blank, cdd.tick(&disc));
    }
    try testing.expectEqual(@as(u32, 0), cdd.seek_ticks_left);
    // The first real block is the one the host asked to play from.
    try testing.expectEqual(@as(i32, 5), cdd.tick(&disc).data.lba);
}

test "a head parked in the lead-in reports the first track" {
    // The BIOS parks the head a few sectors before LBA 0 and then asks for
    // absolute time, relative time and track number. The lead-in belongs to
    // the first track, so its type flag and number are what comes back.
    var data: [10 * 2048]u8 = undefined;
    @memset(&data, 0);
    var audio: [3000 * 2352]u8 = undefined;
    @memset(&audio, 0);
    var disc = try testDisc(testing.allocator, &data, &audio);
    defer disc.deinit();
    var cdd = Cdd.init(true);

    // Seek to 00:01:70, five sectors inside the lead-in.
    _ = cdd.command(&makeCommand(0x4, &.{ 0, 0, 0, 0, 1, 7, 0 }), &disc);
    try testing.expectEqual(@as(i32, -5), cdd.lba);
    var t: u32 = 0;
    while (t <= seek_latency_ticks) : (t += 1) _ = cdd.tick(&disc);
    try testing.expectEqual(DriveStatus.paused, cdd.drive);
    try testing.expectEqual(@as(i32, -5), cdd.lba);

    // Absolute time reads back exactly what was asked for, with the data
    // flag of track 1 in RS8.
    _ = cdd.command(&makeCommand(0x0, &.{}), &disc);
    try testing.expectEqualSlices(u8, &.{ 0x4, 0x0, 0, 0, 0, 1, 7, 0, 0x4 }, cdd.status[0..9]);
    // Relative time counts back from the start of track 1.
    _ = cdd.command(&makeCommand(0x2, &.{ 0, 0, 1 }), &disc);
    try testing.expectEqualSlices(u8, &.{ 0x4, 0x1, 0, 0, 0, 0, 0, 5, 0x4 }, cdd.status[0..9]);
    // Track number is 1, not "no track".
    _ = cdd.command(&makeCommand(0x2, &.{ 0, 0, 2 }), &disc);
    try testing.expectEqualSlices(u8, &.{ 0x4, 0x2, 0, 1, 0, 0, 0, 0, 0 }, cdd.status[0..9]);

    // Playing the lead-in still hands the CDC a sector each tick: a valid
    // mode 1 header addressing 00:01:70, with no user data behind it.
    _ = cdd.command(&makeCommand(0x7, &.{}), &disc); // resume -> playing
    const ev = cdd.tick(&disc);
    try testing.expectEqual(@as(i32, -5), ev.data.lba);
    try testing.expectEqualSlices(u8, &.{ 0x00, 0x01, 0x70, 0x01 }, ev.data.raw[12..16]);
    try testing.expectEqualSlices(u8, &([_]u8{0} ** 32), ev.data.raw[16..48]);
    try testing.expectEqual(@as(i32, -4), cdd.lba);
}

test "seek pauses at the target and relative time counts from track start" {
    var data: [10 * 2048]u8 = undefined;
    @memset(&data, 0);
    var audio: [3000 * 2352]u8 = undefined;
    @memset(&audio, 0);
    var disc = try testDisc(testing.allocator, &data, &audio);
    defer disc.deinit();
    var cdd = Cdd.init(true);

    // Seek to 00:30:00 absolute = LBA 2100. That is a short hop, so the
    // latency floor alone decides how long it takes.
    _ = cdd.command(&makeCommand(0x4, &.{ 0, 0, 0, 3, 0, 0, 0 }), &disc);
    try testing.expectEqual(seek_latency_ticks, cdd.seek_ticks_left);
    var elapsed: u32 = 1;
    while (elapsed < seek_latency_ticks) : (elapsed += 1) {
        _ = cdd.tick(&disc);
        try testing.expect(cdd.seek_ticks_left > 0);
    }
    _ = cdd.tick(&disc);
    try testing.expectEqual(DriveStatus.paused, cdd.drive);
    try testing.expectEqual(@as(i32, 2100), cdd.lba);

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
