const std = @import("std");
const testing = std.testing;
const clock = @import("../clock.zig");

pub const PendingAudioFrames = struct {
    fm_frames: u32,
    psg_frames: u32,
};

pub const AudioTiming = struct {
    fm_master_remainder: u16 = 0,
    psg_master_remainder: u16 = 0,
    pending_fm_frames: u32 = 0,
    pending_psg_frames: u32 = 0,

    pub fn consumeMaster(self: *AudioTiming, master_cycles: u32) void {
        const fm_total = @as(u32, self.fm_master_remainder) + master_cycles;
        self.pending_fm_frames += fm_total / clock.fm_master_cycles_per_sample;
        self.fm_master_remainder = @intCast(fm_total % clock.fm_master_cycles_per_sample);

        const psg_total = @as(u32, self.psg_master_remainder) + master_cycles;
        self.pending_psg_frames += psg_total / clock.psg_master_cycles_per_sample;
        self.psg_master_remainder = @intCast(psg_total % clock.psg_master_cycles_per_sample);
    }

    pub fn takePending(self: *AudioTiming) PendingAudioFrames {
        const out = PendingAudioFrames{
            .fm_frames = self.pending_fm_frames,
            .psg_frames = self.pending_psg_frames,
        };

        self.pending_fm_frames = 0;
        self.pending_psg_frames = 0;

        return out;
    }
};

test "audio timing accrues FM/PSG native-rate frames from master cycles" {
    var timing = AudioTiming{};
    timing.consumeMaster(clock.ntsc_master_cycles_per_frame);
    const frames = timing.takePending();

    try testing.expectEqual(@as(u32, 888), frames.fm_frames);
    try testing.expectEqual(@as(u16, 936), timing.fm_master_remainder);

    try testing.expectEqual(@as(u32, 3733), frames.psg_frames);
    try testing.expectEqual(@as(u16, 120), timing.psg_master_remainder);
}
