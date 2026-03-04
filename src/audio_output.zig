const std = @import("std");
const zsdl3 = @import("zsdl3");
const clock = @import("clock.zig");
const PendingAudioFrames = @import("audio_timing.zig").PendingAudioFrames;
const Z80 = @import("z80.zig").Z80;

const StereoPan = struct {
    left: f32,
    right: f32,
};

const RateConverter = struct {
    in_rate_num: u32,
    in_rate_den: u16,
    remainder: u64 = 0,

    fn toOutputFrames(self: *RateConverter, in_frames: u32, out_rate: u32) u32 {
        if (in_frames == 0) return 0;
        const total: u64 = @as(u64, in_frames) * @as(u64, out_rate) * @as(u64, self.in_rate_den) + self.remainder;
        const out_frames: u32 = @intCast(total / self.in_rate_num);
        self.remainder = total % self.in_rate_num;
        return out_frames;
    }
};

pub const AudioOutput = struct {
    pub const output_rate: u32 = 48_000;
    pub const channels: usize = 2;
    pub const max_queued_ms: u32 = 150;
    pub const max_queued_bytes: usize = (output_rate * max_queued_ms / 1000) * channels * @sizeOf(i16);

    stream: *zsdl3.AudioStream,
    fm_converter: RateConverter = .{
        .in_rate_num = clock.master_clock_ntsc,
        .in_rate_den = clock.fm_master_cycles_per_sample,
    },
    psg_converter: RateConverter = .{
        .in_rate_num = clock.master_clock_ntsc,
        .in_rate_den = clock.psg_master_cycles_per_sample,
    },
    sample_chunk: [4096]i16 = [_]i16{0} ** 4096,
    ym_phase: [6]f32 = [_]f32{0.0} ** 6,
    psg_phase: [3]f32 = [_]f32{0.0} ** 3,
    psg_noise_phase: f32 = 0.0,
    psg_noise_lfsr: u16 = 0x8000,
    psg_noise_out: f32 = 1.0,

    fn fmFrequencyFromChannel(z80: *const Z80, channel: u3) f32 {
        const is_high_bank = channel >= 3;
        const port: u1 = if (is_high_bank) 1 else 0;
        const base: u8 = if (is_high_bank) channel - 3 else channel;

        const fnum_low_reg: u8 = if (is_high_bank) 0xA8 + base else 0xA0 + base;
        const fnum_high_reg: u8 = if (is_high_bank) 0xAC + base else 0xA4 + base;

        const fnum_low = z80.getYmRegister(port, fnum_low_reg);
        const high = z80.getYmRegister(port, fnum_high_reg);
        const block = (high >> 3) & 0x07;
        const fnum_high = high & 0x07;
        const fnum: u16 = (@as(u16, fnum_high) << 8) | @as(u16, fnum_low);
        if (fnum == 0) return 0.0;

        const base_hz = 0.052_7 * @as(f32, @floatFromInt(fnum));
        return base_hz * @as(f32, @floatFromInt(@as(u32, 1) << @intCast(block)));
    }

    fn fmPanFromChannel(z80: *const Z80, channel: u3) StereoPan {
        const is_high_bank = channel >= 3;
        const port: u1 = if (is_high_bank) 1 else 0;
        const base: u8 = if (is_high_bank) channel - 3 else channel;
        const pan = z80.getYmRegister(port, 0xB4 + base);
        const right_on = (pan & 0x40) != 0;
        const left_on = (pan & 0x80) != 0;
        return .{
            .left = if (left_on) 1.0 else 0.0,
            .right = if (right_on) 1.0 else 0.0,
        };
    }

    fn psgToneFrequency(period: u16) f32 {
        const psg_clock = @as(f32, @floatFromInt(clock.master_clock_ntsc)) / @as(f32, @floatFromInt(clock.z80_divider));
        const n: u16 = if (period == 0) 1 else period;
        return psg_clock / (32.0 * @as(f32, @floatFromInt(n)));
    }

    fn attenuationToGain(att: u8) f32 {
        const a: f32 = @floatFromInt(att & 0x0F);
        return std.math.pow(f32, 0.794_328_2, a);
    }

    fn clockNoiseLfsr(self: *AudioOutput, noise_ctrl: u8) void {
        const white = (noise_ctrl & 0x04) != 0;
        const bit0 = self.psg_noise_lfsr & 1;
        const feedback_bit: u16 = if (white) ((self.psg_noise_lfsr ^ (self.psg_noise_lfsr >> 3)) & 1) else bit0;
        self.psg_noise_lfsr = (self.psg_noise_lfsr >> 1) | (feedback_bit << 15);
        self.psg_noise_out = if ((self.psg_noise_lfsr & 1) != 0) 1.0 else -1.0;
    }

    fn renderChunk(
        self: *AudioOutput,
        frames: usize,
        fm_hz: [6]f32,
        fm_gain: [6]f32,
        fm_pan: [6]StereoPan,
        ym_dac_gain: f32,
        ym_dac_sample: f32,
        psg_hz: [3]f32,
        psg_gain: [4]f32,
        psg_noise_hz: f32,
        noise_ctrl: u8,
    ) []const i16 {
        const sample_rate: f32 = @floatFromInt(output_rate);
        const two_pi = std.math.tau;
        var i: usize = 0;
        while (i < frames) : (i += 1) {
            var l: f32 = 0.0;
            var r: f32 = 0.0;
            for (0..6) |ch| {
                if (fm_gain[ch] <= 0.0001 or fm_hz[ch] <= 0.0) continue;
                self.ym_phase[ch] += fm_hz[ch] / sample_rate;
                if (self.ym_phase[ch] >= 1.0) self.ym_phase[ch] -= 1.0;
                const voice = std.math.sin(self.ym_phase[ch] * two_pi) * fm_gain[ch];
                l += voice * fm_pan[ch].left;
                r += voice * fm_pan[ch].right;
            }
            if (ym_dac_gain > 0.0) {
                const voice = ym_dac_sample * ym_dac_gain;
                l += voice;
                r += voice;
            }

            for (0..3) |ch| {
                if (psg_gain[ch] <= 0.0001 or psg_hz[ch] <= 0.0) continue;
                self.psg_phase[ch] += psg_hz[ch] / sample_rate;
                if (self.psg_phase[ch] >= 1.0) self.psg_phase[ch] -= 1.0;
                const square: f32 = if (self.psg_phase[ch] < 0.5) 1.0 else -1.0;
                const voice = square * psg_gain[ch] * 0.08;
                l += voice;
                r += voice;
            }

            if (psg_gain[3] > 0.0001 and psg_noise_hz > 0.0) {
                self.psg_noise_phase += psg_noise_hz / sample_rate;
                if (self.psg_noise_phase >= 1.0) {
                    self.psg_noise_phase -= 1.0;
                    self.clockNoiseLfsr(noise_ctrl);
                }
                const voice = self.psg_noise_out * psg_gain[3] * 0.06;
                l += voice;
                r += voice;
            }
            l = @max(-0.8, @min(0.8, l));
            r = @max(-0.8, @min(0.8, r));
            self.sample_chunk[i * channels] = @as(i16, @intFromFloat(l * 32767.0));
            self.sample_chunk[i * channels + 1] = @as(i16, @intFromFloat(r * 32767.0));
        }
        return self.sample_chunk[0 .. frames * channels];
    }

    pub fn pushPending(self: *AudioOutput, pending: PendingAudioFrames, z80: *const Z80) !void {
        const queued_bytes = zsdl3.getAudioStreamQueued(self.stream) catch return;
        if (queued_bytes >= max_queued_bytes) return;

        const fm_frames = self.fm_converter.toOutputFrames(pending.fm_frames, output_rate);
        const psg_frames = self.psg_converter.toOutputFrames(pending.psg_frames, output_rate);
        var out_frames: u32 = @max(fm_frames, psg_frames);
        if (out_frames == 0) return;

        const dac_enable = (z80.getYmRegister(1, 0x2B) & 0x80) != 0;
        const ym_dac_gain: f32 = if (dac_enable) 0.16 else 0.0;
        const ym_dac_sample = (@as(f32, @floatFromInt(z80.getYmRegister(1, 0x2A))) - 128.0) / 128.0;

        const ym_key_mask = z80.getYmKeyMask();
        var fm_hz = [_]f32{0.0} ** 6;
        var fm_gain = [_]f32{0.0} ** 6;
        var fm_pan = [_]StereoPan{.{ .left = 0.0, .right = 0.0 }} ** 6;
        for (0..6) |ch| {
            fm_hz[ch] = fmFrequencyFromChannel(z80, @intCast(ch));
            fm_pan[ch] = fmPanFromChannel(z80, @intCast(ch));
            if ((ym_key_mask & (@as(u8, 1) << @intCast(ch))) != 0 and !dac_enable) {
                fm_gain[ch] = 0.025;
            }
        }

        var psg_hz = [_]f32{0.0} ** 3;
        var psg_gain = [_]f32{0.0} ** 4;
        for (0..3) |ch| {
            const tone = z80.getPsgTone(@intCast(ch));
            psg_hz[ch] = psgToneFrequency(tone);
            psg_gain[ch] = attenuationToGain(z80.getPsgVolume(@intCast(ch)));
        }
        psg_gain[3] = attenuationToGain(z80.getPsgVolume(3));
        const noise_ctrl = z80.getPsgNoise();
        const noise_rate_sel = noise_ctrl & 0x03;
        const psg_clock = @as(f32, @floatFromInt(clock.master_clock_ntsc)) / @as(f32, @floatFromInt(clock.z80_divider));
        const psg_noise_hz = switch (noise_rate_sel) {
            0 => psg_clock / 512.0,
            1 => psg_clock / 1024.0,
            2 => psg_clock / 2048.0,
            else => psg_hz[2],
        };

        const max_frames_per_push = self.sample_chunk.len / channels;
        while (out_frames > 0) {
            const chunk_frames: usize = @min(out_frames, max_frames_per_push);
            const samples = self.renderChunk(chunk_frames, fm_hz, fm_gain, fm_pan, ym_dac_gain, ym_dac_sample, psg_hz, psg_gain, psg_noise_hz, noise_ctrl);
            try zsdl3.putAudioStreamData(i16, self.stream, samples);
            out_frames -= @intCast(chunk_frames);
        }
    }
};

test "rate converter keeps FM/PSG aligned over one NTSC frame" {
    var output = AudioOutput{
        .stream = @ptrFromInt(1),
    };
    const pending = PendingAudioFrames{
        .fm_frames = 888,
        .psg_frames = 3733,
    };

    const fm_out = output.fm_converter.toOutputFrames(pending.fm_frames, AudioOutput.output_rate);
    const psg_out = output.psg_converter.toOutputFrames(pending.psg_frames, AudioOutput.output_rate);

    try std.testing.expectEqual(@as(u32, 799), fm_out);
    try std.testing.expectEqual(@as(u32, 800), psg_out);
}
