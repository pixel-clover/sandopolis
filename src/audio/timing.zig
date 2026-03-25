const std = @import("std");
const testing = std.testing;
const clock = @import("../clock.zig");

pub const PendingAudioFrames = struct {
    master_cycles: u32,
    fm_frames: u32,
    psg_frames: u32,
    fm_start_remainder: u16,
    psg_start_remainder: u16,
};

pub const AudioTiming = struct {
    fm_master_remainder: u16 = 0,
    psg_master_remainder: u16 = 0,
    pending_master_cycles: u32 = 0,
    pending_fm_frames: u32 = 0,
    pending_psg_frames: u32 = 0,
    pending_fm_start_remainder: u16 = 0,
    pending_psg_start_remainder: u16 = 0,

    pub fn consumeMaster(self: *AudioTiming, master_cycles: u32) void {
        if (self.pending_master_cycles == 0) {
            self.pending_fm_start_remainder = self.fm_master_remainder;
            self.pending_psg_start_remainder = self.psg_master_remainder;
        }

        self.pending_master_cycles +%= master_cycles;

        const fm_total = @as(u32, self.fm_master_remainder) + master_cycles;
        self.pending_fm_frames += fm_total / clock.fm_master_cycles_per_sample;
        self.fm_master_remainder = @intCast(fm_total % clock.fm_master_cycles_per_sample);

        const psg_total = @as(u32, self.psg_master_remainder) + master_cycles;
        self.pending_psg_frames += psg_total / clock.psg_master_cycles_per_sample;
        self.psg_master_remainder = @intCast(psg_total % clock.psg_master_cycles_per_sample);
    }

    pub fn takePending(self: *AudioTiming) PendingAudioFrames {
        const out = PendingAudioFrames{
            .master_cycles = self.pending_master_cycles,
            .fm_frames = self.pending_fm_frames,
            .psg_frames = self.pending_psg_frames,
            .fm_start_remainder = self.pending_fm_start_remainder,
            .psg_start_remainder = self.pending_psg_start_remainder,
        };

        self.pending_master_cycles = 0;
        self.pending_fm_frames = 0;
        self.pending_psg_frames = 0;
        self.pending_fm_start_remainder = 0;
        self.pending_psg_start_remainder = 0;

        return out;
    }
};

test "audio timing accrues FM/PSG native-rate frames from master cycles" {
    var timing = AudioTiming{};
    timing.consumeMaster(clock.ntsc_master_cycles_per_frame);
    const frames = timing.takePending();

    try testing.expectEqual(clock.ntsc_master_cycles_per_frame, frames.master_cycles);
    try testing.expectEqual(@as(u32, 888), frames.fm_frames);
    try testing.expectEqual(@as(u16, 0), frames.fm_start_remainder);
    try testing.expectEqual(@as(u16, 936), timing.fm_master_remainder);

    try testing.expectEqual(@as(u32, 3733), frames.psg_frames);
    try testing.expectEqual(@as(u16, 0), frames.psg_start_remainder);
    try testing.expectEqual(@as(u16, 120), timing.psg_master_remainder);
}

test "audio timing snapshots start remainders for each pending window" {
    var timing = AudioTiming{};

    timing.consumeMaster(clock.fm_master_cycles_per_sample - 8);
    const first = timing.takePending();
    try testing.expectEqual(@as(u32, clock.fm_master_cycles_per_sample - 8), first.master_cycles);
    try testing.expectEqual(@as(u32, 0), first.fm_frames);
    try testing.expectEqual(@as(u16, 0), first.fm_start_remainder);
    try testing.expectEqual(@as(u16, clock.fm_master_cycles_per_sample - 8), timing.fm_master_remainder);

    timing.consumeMaster(16);
    const second = timing.takePending();
    try testing.expectEqual(@as(u32, 16), second.master_cycles);
    try testing.expectEqual(@as(u32, 1), second.fm_frames);
    try testing.expectEqual(@as(u16, clock.fm_master_cycles_per_sample - 8), second.fm_start_remainder);
}
