/// Chip-accurate SN76489 PSG emulation.
/// Ported from clownmdemu-core/psg.c — integer-only, no global state.
const std = @import("std");

/// Pre-computed 16-level volume table (2 dB attenuation steps).
/// Each entry is {positive_phase, negative_phase}.
const psg_volumes: [16][2]i16 = .{
    .{ 0x1FFF, -0x1FFF },
    .{ 0x196A, -0x196A },
    .{ 0x1430, -0x1430 },
    .{ 0x1009, -0x1009 },
    .{ 0x0CBD, -0x0CBD },
    .{ 0x0A1E, -0x0A1E },
    .{ 0x0809, -0x0809 },
    .{ 0x0662, -0x0662 },
    .{ 0x0512, -0x0512 },
    .{ 0x0407, -0x0407 },
    .{ 0x0333, -0x0333 },
    .{ 0x028A, -0x028A },
    .{ 0x0204, -0x0204 },
    .{ 0x019A, -0x019A },
    .{ 0x0146, -0x0146 },
    .{ 0x0000, 0 },
};

const NoiseType = enum { periodic, white };

const ToneState = struct {
    countdown: u16 = 0,
    countdown_master: u16 = 0,
    attenuation: u4 = 0xF, // Silence on startup
    output_bit: u1 = 0,
};

const NoiseState = struct {
    countdown: u16 = 0,
    attenuation: u4 = 0xF,
    fake_output_bit: u1 = 0,
    real_output_bit: u1 = 0,
    frequency_mode: u2 = 0,
    noise_type: NoiseType = .periodic,
    shift_register: u16 = 0,
};

const LatchedCommand = struct {
    channel: u2 = 0,
    is_volume: bool = false,
};

pub const Psg = struct {
    tones: [3]ToneState = .{ ToneState{}, ToneState{}, ToneState{} },
    noise: NoiseState = NoiseState{},
    latched: LatchedCommand = LatchedCommand{},

    fn nextToneSample(tone: *ToneState) i16 {
        if (tone.countdown != 0) tone.countdown -= 1;

        // Phase never changes if period is 0 (exploit for PCM playback).
        if (tone.countdown_master != 0 and tone.countdown == 0) {
            tone.countdown = tone.countdown_master;
            tone.output_bit = ~tone.output_bit;
        }

        return psg_volumes[tone.attenuation][tone.output_bit];
    }

    fn nextNoiseSample(noise: *NoiseState, tone2_period: u16) i16 {
        if (noise.countdown != 0) noise.countdown -= 1;

        if (noise.countdown == 0) {
            // Reset countdown.
            if (noise.frequency_mode == 3) {
                // Use last tone channel's frequency.
                noise.countdown = tone2_period;
            } else {
                noise.countdown = @as(u16, 0x10) << noise.frequency_mode;
            }

            noise.fake_output_bit = ~noise.fake_output_bit;

            if (noise.fake_output_bit == 1) {
                // Rotate shift register and produce output bit.
                noise.real_output_bit = @intCast((noise.shift_register & 0x8000) >> 15);

                noise.shift_register <<= 1;
                noise.shift_register |= noise.real_output_bit;

                if (noise.noise_type == .white) {
                    noise.shift_register ^= (noise.shift_register & 0x2000) >> 13;
                }
            }
        }

        return psg_volumes[noise.attenuation][noise.real_output_bit];
    }

    pub fn doCommand(self: *Psg, command: u8) void {
        const is_latch = (command & 0x80) != 0;

        if (is_latch) {
            self.latched.channel = @intCast((command >> 5) & 3);
            self.latched.is_volume = (command & 0x10) != 0;
        }

        if (self.latched.channel < 3) {
            // Tone channel.
            const ch = self.latched.channel;
            var tone = &self.tones[ch];

            if (self.latched.is_volume) {
                tone.attenuation = @intCast(command & 0xF);
            } else {
                if (is_latch) {
                    // Low frequency bits.
                    tone.countdown_master = (tone.countdown_master & ~@as(u16, 0xF)) | (command & 0xF);
                } else {
                    // High frequency bits.
                    tone.countdown_master = (tone.countdown_master & 0xF) | (@as(u16, command & 0x3F) << 4);
                }
            }
        } else {
            // Noise channel.
            if (self.latched.is_volume) {
                self.noise.attenuation = @intCast(command & 0xF);
            } else {
                self.noise.noise_type = if ((command & 4) != 0) .white else .periodic;
                self.noise.frequency_mode = @intCast(command & 3);
                // Reset shift register on noise register write.
                self.noise.shift_register = 1;
            }
        }
    }

    pub fn nextSample(self: *Psg) i16 {
        var sample: i16 = 0;

        for (&self.tones) |*tone| {
            sample +|= nextToneSample(tone);
        }

        sample +|= nextNoiseSample(&self.noise, self.tones[2].countdown_master);
        return sample;
    }

    /// Generate `total_frames` mono samples into `sample_buffer`.
    /// Samples are additive (mixed into the buffer).
    pub fn update(self: *Psg, sample_buffer: []i16, total_frames: usize) void {
        for (0..total_frames) |j| {
            sample_buffer[j] +|= self.nextSample();
        }
    }
};

// ── Tests ──

test "psg tone at max volume produces non-zero output" {
    var psg = Psg{};
    // Set channel 0 volume to max (attenuation 0).
    psg.doCommand(0x90); // Latch ch0 volume = 0
    // Set channel 0 frequency to a small period.
    psg.doCommand(0x85); // Latch ch0 tone low = 5
    psg.doCommand(0x00); // Data high = 0 → period = 5

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
    // All channels default to attenuation 0xF (silent).
    var buf: [64]i16 = [_]i16{0} ** 64;
    psg.update(&buf, 64);

    for (buf) |s| {
        try std.testing.expectEqual(@as(i16, 0), s);
    }
}

test "psg noise produces output" {
    var psg = Psg{};
    // Noise volume = 0 (max), white noise mode, freq mode 0.
    psg.doCommand(0xF0); // Latch noise volume = 0
    psg.doCommand(0xE4); // Latch noise: white noise, freq mode 0

    var buf: [128]i16 = [_]i16{0} ** 128;
    psg.update(&buf, 128);

    var nonzero: usize = 0;
    for (buf) |s| {
        if (s != 0) nonzero += 1;
    }
    try std.testing.expect(nonzero > 0);
}
