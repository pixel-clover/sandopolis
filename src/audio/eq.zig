const std = @import("std");
const testing = std.testing;

/// 3-band parametric equalizer with low, mid, and high gain controls.
///
/// Zig port of Neil C / Etanza Systems' 3-band EQ (public domain).
/// Uses 4 first-order filters in series
/// (2 for each crossover) giving 24 dB/octave roll-off at the
/// crossover frequencies.
pub const Eq3Band = struct {
    // Filter #1 (low band)
    lf: f64 = 0.0,
    f1p0: f64 = 0.0,
    f1p1: f64 = 0.0,
    f1p2: f64 = 0.0,
    f1p3: f64 = 0.0,

    // Filter #2 (high band)
    hf: f64 = 0.0,
    f2p0: f64 = 0.0,
    f2p1: f64 = 0.0,
    f2p2: f64 = 0.0,
    f2p3: f64 = 0.0,

    // Sample history
    sdm1: f64 = 0.0,
    sdm2: f64 = 0.0,
    sdm3: f64 = 0.0,

    // Gain controls
    lg: f64 = 1.0,
    mg: f64 = 1.0,
    hg: f64 = 1.0,

    // Denormal fix: very small amount to prevent denormalized floats
    const vsa: f64 = 1.0 / 4294967295.0;

    /// Initialize the EQ state for the given crossover frequencies and
    /// sample rate.  Recommended: low_freq = 880, high_freq = 5000.
    pub fn init(low_freq: u32, high_freq: u32, mix_freq: u32) Eq3Band {
        return .{
            .lf = 2.0 * @sin(std.math.pi * @as(f64, @floatFromInt(low_freq)) / @as(f64, @floatFromInt(mix_freq))),
            .hf = 2.0 * @sin(std.math.pi * @as(f64, @floatFromInt(high_freq)) / @as(f64, @floatFromInt(mix_freq))),
        };
    }

    /// Process one sample through the 3-band EQ.
    pub fn process(self: *Eq3Band, sample: f64) f64 {
        // Filter #1 (lowpass)
        self.f1p0 += (self.lf * (sample - self.f1p0)) + vsa;
        self.f1p1 += self.lf * (self.f1p0 - self.f1p1);
        self.f1p2 += self.lf * (self.f1p1 - self.f1p2);
        self.f1p3 += self.lf * (self.f1p2 - self.f1p3);

        const l = self.f1p3;

        // Filter #2 (highpass)
        self.f2p0 += (self.hf * (sample - self.f2p0)) + vsa;
        self.f2p1 += self.hf * (self.f2p0 - self.f2p1);
        self.f2p2 += self.hf * (self.f2p1 - self.f2p2);
        self.f2p3 += self.hf * (self.f2p2 - self.f2p3);

        const h = self.sdm3 - self.f2p3;

        // Mid = signal minus (low + high)
        const m = sample - (h + l);

        // Shuffle history buffer
        self.sdm3 = self.sdm2;
        self.sdm2 = self.sdm1;
        self.sdm1 = sample;

        // Scale and combine
        return l * self.lg + m * self.mg + h * self.hg;
    }

    /// Set gains for low, mid, and high bands.
    pub fn setGains(self: *Eq3Band, low: f64, mid: f64, high: f64) void {
        self.lg = low;
        self.mg = mid;
        self.hg = high;
    }

    /// Reset filter state (poles and history) without changing gains or
    /// crossover frequencies.
    pub fn resetState(self: *Eq3Band) void {
        self.f1p0 = 0.0;
        self.f1p1 = 0.0;
        self.f1p2 = 0.0;
        self.f1p3 = 0.0;
        self.f2p0 = 0.0;
        self.f2p1 = 0.0;
        self.f2p2 = 0.0;
        self.f2p3 = 0.0;
        self.sdm1 = 0.0;
        self.sdm2 = 0.0;
        self.sdm3 = 0.0;
    }
};

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

test "eq3band init sets crossover frequencies" {
    const eq = Eq3Band.init(880, 5000, 48000);
    try testing.expect(eq.lf > 0.0 and eq.lf < 1.0);
    try testing.expect(eq.hf > 0.0 and eq.hf < 1.0);
    try testing.expect(eq.hf > eq.lf);
}

test "eq3band unity gains pass signal through unchanged" {
    var eq = Eq3Band.init(880, 5000, 48000);
    // All gains at 1.0 (default): output should closely match input
    // after the filter state settles.
    var last_out: f64 = 0.0;
    for (0..2048) |i| {
        const phase = @as(f64, @floatFromInt(i)) * std.math.tau * 1000.0 / 48000.0;
        last_out = eq.process(@sin(phase));
    }
    // After settling, amplitude should be close to 1.0 (within filter phase shift)
    try testing.expect(@abs(last_out) > 0.5);
}

test "eq3band zero gains silence output" {
    var eq = Eq3Band.init(880, 5000, 48000);
    eq.setGains(0.0, 0.0, 0.0);

    for (0..512) |i| {
        const phase = @as(f64, @floatFromInt(i)) * std.math.tau * 1000.0 / 48000.0;
        const out = eq.process(@sin(phase));
        try testing.expectApproxEqAbs(@as(f64, 0.0), out, 0.001);
    }
}

test "eq3band low boost increases bass energy" {
    // 200 Hz tone: should be in the low band
    var flat = Eq3Band.init(880, 5000, 48000);
    var boosted = Eq3Band.init(880, 5000, 48000);
    boosted.setGains(2.0, 1.0, 1.0);

    var flat_energy: f64 = 0.0;
    var boosted_energy: f64 = 0.0;
    for (0..4096) |i| {
        const phase = @as(f64, @floatFromInt(i)) * std.math.tau * 200.0 / 48000.0;
        const s = @sin(phase);
        const f = flat.process(s);
        const b = boosted.process(s);
        if (i > 2048) {
            flat_energy += f * f;
            boosted_energy += b * b;
        }
    }
    try testing.expect(boosted_energy > flat_energy * 1.5);
}

test "eq3band high boost increases treble energy" {
    // 15 kHz tone: well above the 5000 Hz crossover
    var flat = Eq3Band.init(880, 5000, 48000);
    var boosted = Eq3Band.init(880, 5000, 48000);
    boosted.setGains(1.0, 1.0, 3.0);

    var flat_energy: f64 = 0.0;
    var boosted_energy: f64 = 0.0;
    for (0..8192) |i| {
        const phase = @as(f64, @floatFromInt(i)) * std.math.tau * 15000.0 / 48000.0;
        const s = @sin(phase);
        const f = flat.process(s);
        const b = boosted.process(s);
        if (i > 4096) {
            flat_energy += f * f;
            boosted_energy += b * b;
        }
    }
    try testing.expect(boosted_energy > flat_energy * 1.3);
}

test "eq3band mid boost increases midrange energy" {
    // 2 kHz tone: should be in the mid band (between 880 and 5000)
    var flat = Eq3Band.init(880, 5000, 48000);
    var boosted = Eq3Band.init(880, 5000, 48000);
    boosted.setGains(1.0, 2.0, 1.0);

    var flat_energy: f64 = 0.0;
    var boosted_energy: f64 = 0.0;
    for (0..4096) |i| {
        const phase = @as(f64, @floatFromInt(i)) * std.math.tau * 2000.0 / 48000.0;
        const s = @sin(phase);
        const f = flat.process(s);
        const b = boosted.process(s);
        if (i > 2048) {
            flat_energy += f * f;
            boosted_energy += b * b;
        }
    }
    try testing.expect(boosted_energy > flat_energy * 1.5);
}

test "eq3band reset state clears filter history" {
    var eq = Eq3Band.init(880, 5000, 48000);
    eq.setGains(1.5, 1.0, 0.5);
    // Process some signal
    for (0..256) |i| {
        _ = eq.process(@as(f64, @floatFromInt(i)) / 256.0);
    }
    try testing.expect(eq.f1p0 != 0.0);
    try testing.expect(eq.sdm1 != 0.0);

    eq.resetState();
    try testing.expectEqual(@as(f64, 0.0), eq.f1p0);
    try testing.expectEqual(@as(f64, 0.0), eq.sdm1);
    // Gains should be preserved
    try testing.expectEqual(@as(f64, 1.5), eq.lg);
    try testing.expectEqual(@as(f64, 0.5), eq.hg);
}

test "eq3band silence input produces near-zero output" {
    var eq = Eq3Band.init(880, 5000, 48000);
    var max_out: f64 = 0.0;
    for (0..256) |_| {
        const out = @abs(eq.process(0.0));
        max_out = @max(max_out, out);
    }
    // Only the vsa denormal fix should produce any output
    try testing.expect(max_out < 0.001);
}
