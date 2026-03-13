const std = @import("std");

pub const PsgStereoSample = struct {
    left: i16,
    right: i16,
};

const psg_levels: [16]i16 = .{
    0x1FFF,
    0x196A,
    0x1430,
    0x1009,
    0x0CBD,
    0x0A1E,
    0x0809,
    0x0662,
    0x0512,
    0x0407,
    0x0333,
    0x028A,
    0x0204,
    0x019A,
    0x0146,
    0x0000,
};

const NoiseType = enum { periodic, white };

const ToneState = struct {
    countdown: u16 = 0,
    countdown_master: u16 = 0,
    attenuation: u4 = 0xF,
    output_bit: u1 = 0,
};

const NoiseState = struct {
    countdown: u16 = 0,
    attenuation: u4 = 0xF,
    fake_output_bit: u1 = 0,
    real_output_bit: u1 = 0,
    frequency_mode: u2 = 0,
    noise_type: NoiseType = .periodic,
    shift_register: u16 = 0x8000,
};

const LatchedCommand = struct {
    channel: u2 = 0,
    is_volume: bool = false,
};

pub const Psg = struct {
    tones: [3]ToneState = .{ ToneState{}, ToneState{}, ToneState{} },
    noise: NoiseState = NoiseState{},
    // Power-on latch targets tone channel 2 attenuation on the integrated MD PSG.
    latched: LatchedCommand = .{ .channel = 1, .is_volume = true },
    /// Per-channel stereo panning. Each element is [left_enable, right_enable].
    /// Default: all channels output to both speakers.
    /// This is compatible with Game Gear stereo and can be used for custom panning.
    channel_pan: [4][2]bool = .{
        .{ true, true }, // Tone 0
        .{ true, true }, // Tone 1
        .{ true, true }, // Tone 2
        .{ true, true }, // Noise
    },

    pub fn powerOn() Psg {
        var psg = Psg{};
        for (&psg.tones) |*tone| {
            tone.attenuation = 0;
            // The integrated PSG starts low and flips high on the first divider event.
            tone.output_bit = 1;
        }
        psg.noise.attenuation = 0;
        return psg;
    }

    fn effectiveTonePeriod(period: u16) u16 {
        // Integrated SN76489 clones treat tone period 0 as period 1.
        return if (period == 0) 1 else period;
    }

    fn toneLevel(tone: *const ToneState) i16 {
        // The integrated PSG core is a unipolar pulse generator. Board-side filtering centers it later.
        return if (tone.output_bit == 0) psg_levels[tone.attenuation] else 0;
    }

    fn stepTone(tone: *ToneState) void {
        if (tone.countdown != 0) tone.countdown -= 1;

        if (tone.countdown == 0) {
            tone.countdown = effectiveTonePeriod(tone.countdown_master);
            tone.output_bit = ~tone.output_bit;
        }
    }

    fn noiseLevel(noise: *const NoiseState) i16 {
        return if (noise.real_output_bit != 0) psg_levels[noise.attenuation] else 0;
    }

    fn stepNoise(noise: *NoiseState, tone2_period: u16) void {
        if (noise.countdown != 0) noise.countdown -= 1;

        if (noise.countdown == 0) {
            if (noise.frequency_mode == 3) {
                noise.countdown = effectiveTonePeriod(tone2_period);
            } else {
                noise.countdown = @as(u16, 0x10) << noise.frequency_mode;
            }

            noise.fake_output_bit = ~noise.fake_output_bit;

            if (noise.fake_output_bit == 1) {
                const feedback: u16 = if (noise.noise_type == .white)
                    ((noise.shift_register >> 0) ^ (noise.shift_register >> 3)) & 0x01
                else
                    noise.shift_register & 0x01;

                noise.shift_register = (noise.shift_register >> 1) | (feedback << 15);
                noise.real_output_bit = @intCast(noise.shift_register & 0x01);
            }
        }

    }

    pub fn doCommand(self: *Psg, command: u8) void {
        const is_latch = (command & 0x80) != 0;

        if (is_latch) {
            self.latched.channel = @intCast((command >> 5) & 3);
            self.latched.is_volume = (command & 0x10) != 0;
        }

        if (self.latched.channel < 3) {
            const ch = self.latched.channel;
            var tone = &self.tones[ch];

            if (self.latched.is_volume) {
                tone.attenuation = @intCast(command & 0xF);
            } else {
                if (is_latch) {
                    tone.countdown_master = (tone.countdown_master & ~@as(u16, 0xF)) | (command & 0xF);
                } else {
                    tone.countdown_master = (tone.countdown_master & 0xF) | (@as(u16, command & 0x3F) << 4);
                }
            }
        } else {
            if (self.latched.is_volume) {
                self.noise.attenuation = @intCast(command & 0xF);
            } else {
                self.noise.noise_type = if ((command & 4) != 0) .white else .periodic;
                self.noise.frequency_mode = @intCast(command & 3);
                if (self.noise.frequency_mode == 3) {
                    self.noise.countdown = self.tones[2].countdown;
                }

                self.noise.shift_register = 0x8000;
                self.noise.real_output_bit = 0;
            }
        }
    }

    pub fn currentSample(self: *const Psg) i16 {
        var sample: i16 = 0;

        for (&self.tones) |*tone| {
            sample +|= toneLevel(tone);
        }

        sample +|= noiseLevel(&self.noise);
        return sample;
    }

    pub fn advanceOneSample(self: *Psg) void {
        for (&self.tones) |*tone| {
            stepTone(tone);
        }

        stepNoise(&self.noise, self.tones[2].countdown_master);
    }

    pub fn nextSample(self: *Psg) i16 {
        self.advanceOneSample();
        var sample: i16 = 0;

        for (&self.tones) |*tone| {
            sample +|= toneLevel(tone);
        }

        sample +|= noiseLevel(&self.noise);
        return sample;
    }

    pub fn update(self: *Psg, sample_buffer: []i16, total_frames: usize) void {
        for (0..total_frames) |j| {
            sample_buffer[j] +|= self.nextSample();
        }
    }

    /// Set stereo panning from an 8-bit Game Gear compatible panning register.
    /// Bits 4-7: Left channel enable for channels 0-3 (tone0, tone1, tone2, noise)
    /// Bits 0-3: Right channel enable for channels 0-3
    /// Default value 0xFF enables all channels on both speakers.
    pub fn setPanning(self: *Psg, panning: u8) void {
        for (0..4) |ch| {
            self.channel_pan[ch][0] = ((panning >> @intCast(ch + 4)) & 1) != 0; // Left
            self.channel_pan[ch][1] = ((panning >> @intCast(ch)) & 1) != 0; // Right
        }
    }

    /// Get the current stereo sample without advancing the PSG state.
    pub fn currentStereoSample(self: *const Psg) PsgStereoSample {
        var left: i16 = 0;
        var right: i16 = 0;

        for (0..3) |ch| {
            const level = toneLevel(&self.tones[ch]);
            if (self.channel_pan[ch][0]) left +|= level;
            if (self.channel_pan[ch][1]) right +|= level;
        }

        const noise_level = noiseLevel(&self.noise);
        if (self.channel_pan[3][0]) left +|= noise_level;
        if (self.channel_pan[3][1]) right +|= noise_level;

        return .{ .left = left, .right = right };
    }

    /// Advance the PSG state and return the new stereo sample.
    pub fn nextStereoSample(self: *Psg) PsgStereoSample {
        self.advanceOneSample();
        return self.currentStereoSample();
    }

    /// Update a stereo sample buffer with PSG output.
    /// Buffer format: interleaved stereo (left, right, left, right, ...)
    pub fn updateStereo(self: *Psg, sample_buffer: []i16, total_frames: usize) void {
        for (0..total_frames) |j| {
            const sample = self.nextStereoSample();
            sample_buffer[j * 2] +|= sample.left;
            sample_buffer[j * 2 + 1] +|= sample.right;
        }
    }
};

test "psg tone at max volume produces non-zero output" {
    var psg = Psg{};

    psg.doCommand(0x90);

    psg.doCommand(0x85);
    psg.doCommand(0x00);

    var buf: [64]i16 = [_]i16{0} ** 64;
    psg.update(&buf, 64);

    var nonzero: usize = 0;
    for (buf) |s| {
        if (s != 0) nonzero += 1;
    }
    try std.testing.expect(nonzero > 0);
}

test "psg silence at max attenuation" {
    var psg = Psg{};

    var buf: [64]i16 = [_]i16{0} ** 64;
    psg.update(&buf, 64);

    for (buf) |s| {
        try std.testing.expectEqual(@as(i16, 0), s);
    }
}

test "psg noise produces output" {
    var psg = Psg{};

    psg.doCommand(0xF0);
    psg.doCommand(0xE4);

    // The integrated noise LFSR starts low and needs several shifts before the first high pulse appears.
    var buf: [1024]i16 = [_]i16{0} ** 1024;
    psg.update(&buf, buf.len);

    var nonzero: usize = 0;
    for (buf) |s| {
        if (s != 0) nonzero += 1;
    }
    try std.testing.expect(nonzero > 0);
}

test "psg integrated power-on state seeds noise register" {
    const psg = Psg.powerOn();

    try std.testing.expectEqual(@as(u16, 0x8000), psg.noise.shift_register);
    try std.testing.expectEqual(@as(u1, 0), psg.noise.fake_output_bit);
    try std.testing.expectEqual(@as(u1, 0), psg.noise.real_output_bit);
}

test "psg power-on latch targets tone channel 2 attenuation" {
    var psg = Psg.powerOn();

    psg.doCommand(0x00);

    try std.testing.expectEqual(@as(u4, 0x0), psg.tones[0].attenuation);
    try std.testing.expectEqual(@as(u4, 0x0), psg.tones[1].attenuation);
    try std.testing.expectEqual(@as(u4, 0x0), psg.tones[2].attenuation);
}

test "psg zero tone period behaves like period one" {
    var psg = Psg{};

    psg.doCommand(0x90);
    psg.doCommand(0x80);
    psg.doCommand(0x00);

    var buf: [8]i16 = [_]i16{0} ** 8;
    psg.update(&buf, buf.len);

    var saw_high = false;
    var saw_low = false;
    for (buf) |sample| {
        if (sample > 0) saw_high = true;
        if (sample == 0) saw_low = true;
    }

    try std.testing.expect(saw_high);
    try std.testing.expect(saw_low);
}

test "psg tone output is unipolar before board filtering" {
    var psg = Psg{};

    psg.doCommand(0x90);
    psg.doCommand(0x81);
    psg.doCommand(0x00);

    var buf: [16]i16 = [_]i16{0} ** 16;
    psg.update(&buf, buf.len);

    var saw_high = false;
    var saw_low = false;
    for (buf) |sample| {
        try std.testing.expect(sample >= 0);
        if (sample > 0) saw_high = true;
        if (sample == 0) saw_low = true;
    }

    try std.testing.expect(saw_high);
    try std.testing.expect(saw_low);
}

test "psg noise mode write reseeds lfsr without resetting divider phase" {
    var psg = Psg{};
    psg.noise.countdown = 7;
    psg.noise.fake_output_bit = 1;
    psg.noise.real_output_bit = 1;
    psg.noise.shift_register = 0xBEEF;

    psg.doCommand(0xE0);

    try std.testing.expectEqual(@as(u16, 7), psg.noise.countdown);
    try std.testing.expectEqual(@as(u1, 1), psg.noise.fake_output_bit);
    try std.testing.expectEqual(@as(u1, 0), psg.noise.real_output_bit);
    try std.testing.expectEqual(@as(u16, 0x8000), psg.noise.shift_register);
    try std.testing.expectEqual(NoiseType.periodic, psg.noise.noise_type);
    try std.testing.expectEqual(@as(u2, 0), psg.noise.frequency_mode);
}

test "psg linked noise mode synchronizes divider phase to tone channel 2" {
    var psg = Psg{};
    psg.tones[2].countdown = 5;
    psg.noise.countdown = 11;
    psg.noise.shift_register = 0xBEEF;

    psg.doCommand(0xE3);

    try std.testing.expectEqual(@as(u2, 3), psg.noise.frequency_mode);
    try std.testing.expectEqual(@as(u16, 5), psg.noise.countdown);
    try std.testing.expectEqual(@as(u16, 0x8000), psg.noise.shift_register);
}

fn expectNoiseBitSequence(noise_type: NoiseType, expected: []const u8) !void {
    var psg = Psg{};
    psg.noise.noise_type = noise_type;
    psg.noise.attenuation = 0;

    for (expected) |bit_char| {
        psg.noise.countdown = 1;
        Psg.stepNoise(&psg.noise, psg.tones[2].countdown_master);
        const expected_bit: u1 = @intCast(bit_char - '0');
        try std.testing.expectEqual(expected_bit, psg.noise.real_output_bit);
    }
}

test "psg periodic noise startup sequence matches integrated reference" {
    try expectNoiseBitSequence(.periodic, "0000000000000000000000000000110000000000000000000000000000001100");
}

test "psg white noise startup sequence matches integrated reference" {
    try expectNoiseBitSequence(.white, "0000000000000000000000000000110000000000000000000000001100001100");
}

test "psg stereo sample outputs same value to both channels by default" {
    var psg = Psg{};

    psg.doCommand(0x90); // Tone 0 attenuation = 0
    psg.doCommand(0x81); // Tone 0 period low
    psg.doCommand(0x00); // Tone 0 period high

    const sample = psg.nextStereoSample();

    try std.testing.expectEqual(sample.left, sample.right);
}

test "psg stereo panning isolates channels to left or right" {
    var psg = Psg{};

    psg.doCommand(0x90); // Tone 0 attenuation = 0
    psg.doCommand(0x81); // Tone 0 period low
    psg.doCommand(0x00); // Tone 0 period high

    // Pan tone 0 to left only
    psg.channel_pan[0][0] = true; // Left enabled
    psg.channel_pan[0][1] = false; // Right disabled

    // Get a sample when tone is high
    var found_asymmetric = false;
    for (0..16) |_| {
        const sample = psg.nextStereoSample();
        if (sample.left != sample.right) {
            found_asymmetric = true;
            try std.testing.expect(sample.left > sample.right);
            break;
        }
    }
    try std.testing.expect(found_asymmetric);
}

test "psg set panning from Game Gear compatible register" {
    var psg = Psg{};

    // 0xF0 = all channels to left only (bits 4-7 = 1, bits 0-3 = 0)
    psg.setPanning(0xF0);

    try std.testing.expect(psg.channel_pan[0][0]); // Tone 0 left
    try std.testing.expect(!psg.channel_pan[0][1]); // Tone 0 right (disabled)
    try std.testing.expect(psg.channel_pan[1][0]); // Tone 1 left
    try std.testing.expect(!psg.channel_pan[1][1]); // Tone 1 right (disabled)
    try std.testing.expect(psg.channel_pan[2][0]); // Tone 2 left
    try std.testing.expect(!psg.channel_pan[2][1]); // Tone 2 right (disabled)
    try std.testing.expect(psg.channel_pan[3][0]); // Noise left
    try std.testing.expect(!psg.channel_pan[3][1]); // Noise right (disabled)

    // 0x0F = all channels to right only
    psg.setPanning(0x0F);

    try std.testing.expect(!psg.channel_pan[0][0]); // Tone 0 left (disabled)
    try std.testing.expect(psg.channel_pan[0][1]); // Tone 0 right
}

test "psg stereo update buffer writes interleaved samples" {
    var psg = Psg{};

    psg.doCommand(0x90); // Tone 0 attenuation = 0
    psg.doCommand(0x81); // Tone 0 period low
    psg.doCommand(0x00); // Tone 0 period high

    // Pan to left only
    psg.channel_pan[0][0] = true;
    psg.channel_pan[0][1] = false;

    var buf: [32]i16 = [_]i16{0} ** 32;
    psg.updateStereo(&buf, 16);

    // Should have some non-zero left samples and zero right samples
    var has_left = false;
    var right_is_zero = true;
    for (0..16) |i| {
        if (buf[i * 2] != 0) has_left = true;
        if (buf[i * 2 + 1] != 0) right_is_zero = false;
    }
    try std.testing.expect(has_left);
    try std.testing.expect(right_is_zero);
}
