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

const ym_operator_offsets = [_]u8{ 0x00, 0x08, 0x04, 0x0C };

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
    timing_is_pal: bool = false,
    sample_chunk: [4096]i16 = [_]i16{0} ** 4096,
    ym_phase: [6]f32 = [_]f32{0.0} ** 6,
    ym_level: [6]f32 = [_]f32{0.0} ** 6,
    psg: Psg = Psg{},

    fn ymPortAndChannelBase(channel: u3) struct { port: u1, base: u8 } {
        return if (channel >= 3)
            .{ .port = 1, .base = @as(u8, channel - 3) }
        else
            .{ .port = 0, .base = channel };
    }

    fn ymOperatorRegister(z80: *const Z80, channel: u3, reg_base: u8, operator: u2) u8 {
        const mapping = ymPortAndChannelBase(channel);
        return z80.getYmRegister(mapping.port, reg_base + ym_operator_offsets[operator] + mapping.base);
    }

    fn ymTotalLevelToGain(total_level: u8) f32 {
        return std.math.exp2(-@as(f32, @floatFromInt(total_level & 0x7F)) / 16.0);
    }

    fn ymAttackStep(z80: *const Z80, channel: u3) f32 {
        const attack_rate = ymOperatorRegister(z80, channel, 0x50, 3) & 0x1F;
        return 0.0001 + (@as(f32, @floatFromInt(attack_rate)) / 31.0) * 0.01;
    }

    fn ymReleaseStep(z80: *const Z80, channel: u3) f32 {
        const release_rate = ymOperatorRegister(z80, channel, 0x80, 3) & 0x0F;
        return 0.00002 + (@as(f32, @floatFromInt(release_rate)) / 15.0) * 0.002;
    }

    fn ymTargetGain(z80: *const Z80, channel: u3, keyed_on: bool, dac_enable: bool) f32 {
        if (!keyed_on) return 0.0;
        if (dac_enable and channel == 5) return 0.0;

        const carrier_tl = ymOperatorRegister(z80, channel, 0x40, 3);
        const algorithm_feedback = z80.getYmRegister(ymPortAndChannelBase(channel).port, 0xB0 + ymPortAndChannelBase(channel).base);
        const algorithm = algorithm_feedback & 0x07;
        const feedback = (algorithm_feedback >> 3) & 0x07;

        var gain = 0.05 * ymTotalLevelToGain(carrier_tl);
        gain *= 1.0 + @as(f32, @floatFromInt(algorithm)) * 0.04;
        gain *= 1.0 + @as(f32, @floatFromInt(feedback)) * 0.03;
        return gain;
    }

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
        psg_native_frames: u32,
        z80: *const Z80,
        fm_hz: [6]f32,
        fm_target_gain: [6]f32,
        fm_pan: [6]StereoPan,
        ym_dac_gain: f32,
        ym_dac_sample: f32,
        dac_pan: StereoPan,
    ) []const i16 {
        // Mix FM placeholder + resampled PSG into stereo output.
        const sample_rate: f32 = @floatFromInt(output_rate);
        const two_pi = std.math.tau;
        var psg_native_cursor: u32 = 0;
        var last_psg_sample: i16 = 0;
        var i: usize = 0;
        while (i < frames) : (i += 1) {
            var l: f32 = 0.0;
            var r: f32 = 0.0;

            // FM channels (placeholder sine synthesis until FM operators are ported).
            for (0..6) |ch| {
                if (fm_hz[ch] <= 0.0) continue;

                const channel: u3 = @intCast(ch);
                const target_gain = fm_target_gain[ch];
                if (self.ym_level[ch] < target_gain) {
                    self.ym_level[ch] = @min(target_gain, self.ym_level[ch] + ymAttackStep(z80, channel));
                } else if (self.ym_level[ch] > target_gain) {
                    self.ym_level[ch] = @max(target_gain, self.ym_level[ch] - ymReleaseStep(z80, channel));
                }
                if (self.ym_level[ch] <= 0.0001) continue;

                self.ym_phase[ch] += fm_hz[ch] / sample_rate;
                if (self.ym_phase[ch] >= 1.0) self.ym_phase[ch] -= 1.0;
                const voice = std.math.sin(self.ym_phase[ch] * two_pi) * self.ym_level[ch];
                l += voice * fm_pan[ch].left;
                r += voice * fm_pan[ch].right;
            }
            if (ym_dac_gain > 0.0) {
                const voice = ym_dac_sample * ym_dac_gain;
                l += voice * dac_pan.left;
                r += voice * dac_pan.right;
            }

            // Resample PSG from native chip ticks to output-rate stereo.
            const target_native = @as(u32, @intCast((@as(u64, i + 1) * psg_native_frames) / frames));
            const samples_to_generate = target_native - psg_native_cursor;
            var psg_sample: f32 = 0.0;
            if (samples_to_generate != 0) {
                var sum: i32 = 0;
                var generated = samples_to_generate;
                while (generated != 0) : (generated -= 1) {
                    last_psg_sample = self.psg.nextSample();
                    sum += last_psg_sample;
                    psg_native_cursor += 1;
                }
                psg_sample = @as(f32, @floatFromInt(@divTrunc(sum, @as(i32, @intCast(samples_to_generate))))) / 32768.0;
            } else {
                psg_sample = @as(f32, @floatFromInt(last_psg_sample)) / 32768.0;
            }
            l += psg_sample * 0.5;
            r += psg_sample * 0.5;

            l = @max(-0.95, @min(0.95, l));
            r = @max(-0.95, @min(0.95, r));
            self.sample_chunk[i * channels] = @as(i16, @intFromFloat(l * 32767.0));
            self.sample_chunk[i * channels + 1] = @as(i16, @intFromFloat(r * 32767.0));
        }
        return self.sample_chunk[0 .. frames * channels];
    }

    fn setConverterRate(converter: *RateConverter, in_rate_num: u32) void {
        if (converter.in_rate_num == in_rate_num) return;
        converter.in_rate_num = in_rate_num;
        converter.remainder = 0;
    }

    pub fn setTimingMode(self: *AudioOutput, is_pal: bool) void {
        if (self.timing_is_pal == is_pal) return;

        self.timing_is_pal = is_pal;
        const master_clock = if (is_pal) clock.master_clock_pal else clock.master_clock_ntsc;
        setConverterRate(&self.fm_converter, master_clock);
        setConverterRate(&self.psg_converter, master_clock);
    }

    pub fn pushPending(self: *AudioOutput, pending: PendingAudioFrames, z80: *const Z80, is_pal: bool) !void {
        self.setTimingMode(is_pal);

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
        var fm_target_gain = [_]f32{0.0} ** 6;
        var fm_pan = [_]StereoPan{.{ .left = 0.0, .right = 0.0 }} ** 6;
        const dac_pan = fmPanFromChannel(z80, 5);
        for (0..6) |ch| {
            const channel: u3 = @intCast(ch);
            fm_hz[ch] = fmFrequencyFromChannel(z80, channel);
            fm_pan[ch] = fmPanFromChannel(z80, channel);
            const keyed_on = (ym_key_mask & (@as(u8, 1) << @intCast(ch))) != 0;
            fm_target_gain[ch] = ymTargetGain(z80, channel, keyed_on, dac_enable);
        }

        const max_frames_per_push = self.sample_chunk.len / channels;
        var remaining_psg_native = pending.psg_frames;
        var remaining_out_frames = out_frames;
        while (out_frames > 0) {
            const chunk_frames: usize = @min(out_frames, max_frames_per_push);
            const chunk_psg_native: u32 = if (remaining_out_frames == chunk_frames)
                remaining_psg_native
            else
                @intCast((@as(u64, remaining_psg_native) * chunk_frames) / remaining_out_frames);
            const samples = self.renderChunk(chunk_frames, chunk_psg_native, z80, fm_hz, fm_target_gain, fm_pan, ym_dac_gain, ym_dac_sample, dac_pan);
            try zsdl3.putAudioStreamData(i16, self.stream, samples);
            remaining_psg_native -= chunk_psg_native;
            remaining_out_frames -= @intCast(chunk_frames);
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

    try std.testing.expectEqual(@as(u32, 800), fm_out);
    try std.testing.expectEqual(@as(u32, 800), psg_out);
}

test "rate converter keeps FM/PSG aligned over one PAL frame" {
    var output = AudioOutput{
        .stream = @ptrFromInt(1),
    };
    output.setTimingMode(true);

    const pending = PendingAudioFrames{
        .fm_frames = 1061,
        .psg_frames = 4460,
    };

    const fm_out = output.fm_converter.toOutputFrames(pending.fm_frames, AudioOutput.output_rate);
    const psg_out = output.psg_converter.toOutputFrames(pending.psg_frames, AudioOutput.output_rate);

    try std.testing.expectEqual(@as(u32, 964), fm_out);
    try std.testing.expectEqual(@as(u32, 965), psg_out);
}

test "psg native-rate rendering stays audible after downsampling" {
    var output = AudioOutput{
        .stream = @ptrFromInt(1),
    };
    var z80 = Z80.init();
    defer z80.deinit();
    output.psg.doCommand(0x90); // ch0 volume = 0
    output.psg.doCommand(0x85); // ch0 tone low = 5
    output.psg.doCommand(0x00); // ch0 tone high = 0

    const silent_fm = [_]f32{0.0} ** 6;
    const silent_pan = [_]StereoPan{.{ .left = 0.0, .right = 0.0 }} ** 6;
    const samples = output.renderChunk(64, 256, &z80, silent_fm, silent_fm, silent_pan, 0.0, 0.0, .{ .left = 1.0, .right = 1.0 });

    var nonzero: usize = 0;
    for (samples) |sample| {
        if (sample != 0) nonzero += 1;
    }
    try std.testing.expect(nonzero > 0);
}
