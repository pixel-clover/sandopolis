const clock = @import("clock.zig");

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
