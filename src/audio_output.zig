const std = @import("std");
const zsdl3 = @import("zsdl3");
const clock = @import("clock.zig");
const PendingAudioFrames = @import("audio_timing.zig").PendingAudioFrames;
const Z80 = @import("z80.zig").Z80;
const Psg = @import("psg.zig").Psg;

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
    psg_sample_buf: [2048]i16 = [_]i16{0} ** 2048,
    ym_phase: [6]f32 = [_]f32{0.0} ** 6,
    psg: Psg = Psg{},

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

    /// Sync PSG state from the Z80 bridge's decoded registers.
    /// Called each frame before rendering audio.
    fn syncPsgFromBridge(self: *AudioOutput, z80: *const Z80) void {
        // Sync tone channel frequencies and volumes.
        for (0..3) |ch| {
            const tone = z80.getPsgTone(@intCast(ch));
            self.psg.tones[ch].countdown_master = tone;
            self.psg.tones[ch].attenuation = @intCast(z80.getPsgVolume(@intCast(ch)) & 0xF);
        }
        // Sync noise channel.
        self.psg.noise.attenuation = @intCast(z80.getPsgVolume(3) & 0xF);
        const noise_reg = z80.getPsgNoise();
        self.psg.noise.noise_type = if ((noise_reg & 4) != 0) .white else .periodic;
        self.psg.noise.frequency_mode = @intCast(noise_reg & 3);
    }

    fn renderChunk(
        self: *AudioOutput,
        frames: usize,
        fm_hz: [6]f32,
        fm_gain: [6]f32,
        fm_pan: [6]StereoPan,
        ym_dac_gain: f32,
        ym_dac_sample: f32,
    ) []const i16 {
        // --- PSG: generate chip-accurate mono samples ---
        const psg_frames = @min(frames, self.psg_sample_buf.len);
        @memset(self.psg_sample_buf[0..psg_frames], 0);
        self.psg.update(self.psg_sample_buf[0..psg_frames], psg_frames);

        // --- Mix FM (still float-based) + PSG (integer) into stereo output ---
        const sample_rate: f32 = @floatFromInt(output_rate);
        const two_pi = std.math.tau;
        var i: usize = 0;
        while (i < frames) : (i += 1) {
            var l: f32 = 0.0;
            var r: f32 = 0.0;

            // FM channels (placeholder sine synthesis until FM operators are ported).
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

            // Mix PSG (mono → both channels). Scale i16 down to -0.5..0.5 range.
            const psg_sample: f32 = if (i < psg_frames) @as(f32, @floatFromInt(self.psg_sample_buf[i])) / 32768.0 else 0.0;
            l += psg_sample * 0.5;
            r += psg_sample * 0.5;

            l = @max(-0.95, @min(0.95, l));
            r = @max(-0.95, @min(0.95, r));
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

        // Sync PSG state from Z80 bridge.
        self.syncPsgFromBridge(z80);

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

        const max_frames_per_push = self.sample_chunk.len / channels;
        while (out_frames > 0) {
            const chunk_frames: usize = @min(out_frames, max_frames_per_push);
            const samples = self.renderChunk(chunk_frames, fm_hz, fm_gain, fm_pan, ym_dac_gain, ym_dac_sample);
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
