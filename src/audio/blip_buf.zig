const std = @import("std");
const testing = std.testing;

/// Band-limited sample buffer that resamples from input clock rate to output
/// sample rate using windowed-sinc synthesis.
///
/// Zig port of Shay Green's blip_buf (LGPL-2.1), extended with stereo buffer
/// support.
///
/// Each delta added at a precise clock time is convolved with a pre-computed
/// sinc kernel so that the output is correctly band-limited at the target
/// sample rate.  A built-in single-pole high-pass (bass_shift = 9) removes
/// DC during readout, matching the original C implementation.

const pre_shift: u6 = 32;
const time_bits: u6 = pre_shift + 20;
const time_unit: u64 = @as(u64, 1) << time_bits;

const bass_shift: u5 = 9;
const end_frame_extra: usize = 2;

const half_width: usize = 8;
const buf_extra: usize = half_width * 2 + end_frame_extra;
const phase_bits: u5 = 5;
const phase_count: usize = 1 << phase_bits;
const delta_bits: u5 = 15;
const delta_unit: i32 = 1 << delta_bits;
const frac_bits: u6 = time_bits - pre_shift;
const phase_shift: u5 = frac_bits - phase_bits;

const max_sample: i32 = 32767;
const min_sample: i32 = -32768;

pub const max_ratio: u64 = 1 << 20;
pub const max_frame: usize = 4000;

fn clampSample(n: i32) i16 {
    if (n > max_sample) return @intCast(max_sample);
    if (n < min_sample) return @intCast(min_sample);
    return @intCast(n);
}

fn arithShift(n: i32, comptime shift: u5) i32 {
    return n >> shift;
}

// Sinc_Generator( 0.9, 0.55, 4.5 )
const bl_step: [phase_count + 1][half_width]i16 = .{
    .{ 43, -115, 350, -488, 1136, -914, 5861, 21022 },
    .{ 44, -118, 348, -473, 1076, -799, 5274, 21001 },
    .{ 45, -121, 344, -454, 1011, -677, 4706, 20936 },
    .{ 46, -122, 336, -431, 942, -549, 4156, 20829 },
    .{ 47, -123, 327, -404, 868, -418, 3629, 20679 },
    .{ 47, -122, 316, -375, 792, -285, 3124, 20488 },
    .{ 47, -120, 303, -344, 714, -151, 2644, 20256 },
    .{ 46, -117, 289, -310, 634, -17, 2188, 19985 },
    .{ 46, -114, 273, -275, 553, 117, 1758, 19675 },
    .{ 44, -108, 255, -237, 471, 247, 1356, 19327 },
    .{ 43, -103, 237, -199, 390, 373, 981, 18944 },
    .{ 42, -98, 218, -160, 310, 495, 633, 18527 },
    .{ 40, -91, 198, -121, 231, 611, 314, 18078 },
    .{ 38, -84, 178, -81, 153, 722, 22, 17599 },
    .{ 36, -76, 157, -43, 80, 824, -241, 17092 },
    .{ 34, -68, 135, -3, 8, 919, -476, 16558 },
    .{ 32, -61, 115, 34, -60, 1006, -683, 16001 },
    .{ 29, -52, 94, 70, -123, 1083, -862, 15422 },
    .{ 27, -44, 73, 106, -184, 1152, -1015, 14824 },
    .{ 25, -36, 53, 139, -239, 1211, -1142, 14210 },
    .{ 22, -27, 34, 170, -290, 1261, -1244, 13582 },
    .{ 20, -20, 16, 199, -335, 1301, -1322, 12942 },
    .{ 18, -12, -3, 226, -375, 1331, -1376, 12293 },
    .{ 15, -4, -19, 250, -410, 1351, -1408, 11638 },
    .{ 13, 3, -35, 272, -439, 1361, -1419, 10979 },
    .{ 11, 9, -49, 292, -464, 1362, -1410, 10319 },
    .{ 9, 16, -63, 309, -483, 1354, -1383, 9660 },
    .{ 7, 22, -75, 322, -496, 1337, -1339, 9005 },
    .{ 6, 26, -85, 333, -504, 1312, -1280, 8355 },
    .{ 4, 31, -94, 341, -507, 1278, -1205, 7713 },
    .{ 3, 35, -102, 347, -506, 1238, -1119, 7082 },
    .{ 1, 40, -110, 350, -499, 1190, -1021, 6464 },
    .{ 0, 43, -115, 350, -488, 1136, -914, 5861 },
};

/// Stereo band-limited sample buffer.
///
/// `capacity` is the maximum number of output samples the buffer can hold.
pub fn BlipBuf(comptime capacity: usize) type {
    const buf_len = capacity + buf_extra;

    return struct {
        const Self = @This();

        factor: u64 = time_unit / max_ratio,
        offset: u64 = time_unit / max_ratio / 2,
        size: usize = capacity,
        integrator: [2]i32 = .{ 0, 0 },
        buffer: [2][buf_len]i32 = .{ .{0} ** buf_len, .{0} ** buf_len },

        /// Set input clock rate and output sample rate.
        pub fn setRates(self: *Self, clock_rate: f64, sample_rate: f64) void {
            const factor_f: f64 = @as(f64, @floatFromInt(time_unit)) * sample_rate / clock_rate;
            self.factor = @intFromFloat(factor_f);
            if (@as(f64, @floatFromInt(self.factor)) < factor_f) {
                self.factor += 1;
            }
        }

        /// Clear buffer and reset state.
        pub fn clear(self: *Self) void {
            self.offset = self.factor / 2;
            self.integrator = .{ 0, 0 };
            self.buffer = .{ .{0} ** buf_len, .{0} ** buf_len };
        }

        /// Number of clocks needed to produce `samples` additional output samples.
        pub fn clocksNeeded(self: *const Self, samples: usize) u64 {
            const needed: u64 = @as(u64, @intCast(samples)) * time_unit;
            if (needed < self.offset) return 0;
            return (needed - self.offset + self.factor - 1) / self.factor;
        }

        /// End the current time frame of `clock_duration` clocks.
        /// Makes samples available for reading.
        pub fn endFrame(self: *Self, clock_duration: u32) void {
            self.offset += @as(u64, clock_duration) * self.factor;
        }

        /// Number of output samples available for reading.
        pub fn samplesAvail(self: *const Self) usize {
            return @intCast(self.offset >> @intCast(time_bits));
        }

        /// Add a stereo delta at the given clock time (high quality, sinc-windowed).
        pub fn addDelta(self: *Self, time: u32, delta_l: i32, delta_r: i32) void {
            if ((delta_l | delta_r) == 0) return;

            const fixed: u32 = @truncate(((@as(u64, time) * self.factor + self.offset) >> pre_shift));
            const phase: usize = @intCast((fixed >> phase_shift) & (phase_count - 1));
            const interp: i32 = @intCast((fixed >> (phase_shift - delta_bits)) & (@as(u32, @intCast(delta_unit)) - 1));
            const pos: usize = @intCast(fixed >> frac_bits);

            // In the original C code, `in` is a pointer to bl_step[phase][0].
            // Accessing in[half_width + i] reads into bl_step[phase + 1][i].
            // Similarly, rev points to bl_step[phase_count - phase][0] and
            // rev[i - half_width] reads bl_step[phase_count - phase - 1][i].
            const in0 = bl_step[phase];
            const in1 = bl_step[phase + 1];
            const rev_phase = phase_count - phase;
            const rev0 = bl_step[rev_phase];
            const rev_prev = bl_step[rev_phase - 1];

            if (delta_l == delta_r) {
                addSincKernelBoth(self, pos, in0, in1, rev0, rev_prev, interp, delta_l);
            } else {
                addSincKernelCh(self, 0, pos, in0, in1, rev0, rev_prev, interp, delta_l);
                addSincKernelCh(self, 1, pos, in0, in1, rev0, rev_prev, interp, delta_r);
            }
        }

        fn addSincKernelCh(
            self: *Self,
            ch: usize,
            pos: usize,
            in0: [half_width]i16,
            in1: [half_width]i16,
            rev0: [half_width]i16,
            rev_prev: [half_width]i16,
            interp: i32,
            delta_in: i32,
        ) void {
            var d = delta_in;
            const delta = @divTrunc(d * interp, delta_unit);
            d -= delta;

            // Forward half (positions 0..7)
            inline for (0..half_width) |i| {
                self.buffer[ch][pos + i] += @as(i32, in0[i]) * d + @as(i32, in1[i]) * delta;
            }
            // Reverse half (positions 8..15)
            inline for (0..half_width) |j| {
                self.buffer[ch][pos + half_width + j] += @as(i32, rev0[half_width - 1 - j]) * d + @as(i32, rev_prev[half_width - 1 - j]) * delta;
            }
        }

        fn addSincKernelBoth(
            self: *Self,
            pos: usize,
            in0: [half_width]i16,
            in1: [half_width]i16,
            rev0: [half_width]i16,
            rev_prev: [half_width]i16,
            interp: i32,
            delta_in: i32,
        ) void {
            var d = delta_in;
            const delta = @divTrunc(d * interp, delta_unit);
            d -= delta;

            inline for (0..half_width) |i| {
                const val = @as(i32, in0[i]) * d + @as(i32, in1[i]) * delta;
                self.buffer[0][pos + i] += val;
                self.buffer[1][pos + i] += val;
            }
            inline for (0..half_width) |j| {
                const val = @as(i32, rev0[half_width - 1 - j]) * d + @as(i32, rev_prev[half_width - 1 - j]) * delta;
                self.buffer[0][pos + half_width + j] += val;
                self.buffer[1][pos + half_width + j] += val;
            }
        }

        /// Add a stereo delta at the given clock time (fast, lower quality).
        pub fn addDeltaFast(self: *Self, time: u32, delta_l: i32, delta_r: i32) void {
            if ((delta_l | delta_r) == 0) return;

            const fixed: u32 = @truncate((@as(u64, time) * self.factor + self.offset) >> pre_shift);
            const interp: i32 = @intCast((fixed >> (frac_bits - delta_bits)) & (@as(u32, @intCast(delta_unit)) - 1));
            const pos: usize = @intCast(fixed >> frac_bits);

            if (delta_l == delta_r) {
                const delta = delta_l * interp;
                const val_7 = delta_l * delta_unit - delta;
                self.buffer[0][pos + 7] += val_7;
                self.buffer[0][pos + 8] += delta;
                self.buffer[1][pos + 7] += val_7;
                self.buffer[1][pos + 8] += delta;
            } else {
                const delta_l_interp = delta_l * interp;
                self.buffer[0][pos + 7] += delta_l * delta_unit - delta_l_interp;
                self.buffer[0][pos + 8] += delta_l_interp;
                const delta_r_interp = delta_r * interp;
                self.buffer[1][pos + 7] += delta_r * delta_unit - delta_r_interp;
                self.buffer[1][pos + 8] += delta_r_interp;
            }
        }

        /// Read and remove up to `count` stereo sample pairs, writing
        /// interleaved i16 values to `out`.  Returns the number of frames
        /// (stereo pairs) actually read.
        pub fn readSamples(self: *Self, out: []i16, count: usize) usize {
            const avail = self.samplesAvail();
            const n = @min(count, @min(avail, out.len / 2));
            if (n == 0) return 0;

            var sum_l = self.integrator[0];
            var sum_r = self.integrator[1];
            var i: usize = 0;
            while (i < n) : (i += 1) {
                // Left channel
                var s = arithShift(sum_l, delta_bits);
                sum_l += self.buffer[0][i];
                out[i * 2] = clampSample(s);
                sum_l -= @as(i32, clampSample(s)) << (delta_bits - bass_shift);

                // Right channel
                s = arithShift(sum_r, delta_bits);
                sum_r += self.buffer[1][i];
                out[i * 2 + 1] = clampSample(s);
                sum_r -= @as(i32, clampSample(s)) << (delta_bits - bass_shift);
            }
            self.integrator[0] = sum_l;
            self.integrator[1] = sum_r;

            self.removeSamples(n);
            return n;
        }

        fn removeSamples(self: *Self, count: usize) void {
            const remain = self.samplesAvail() + buf_extra - count;
            self.offset -= @as(u64, count) << @intCast(time_bits);

            // Shift remaining buffer content forward
            for (0..2) |ch| {
                std.mem.copyForwards(i32, self.buffer[ch][0..remain], self.buffer[ch][count .. count + remain]);
                @memset(self.buffer[ch][remain .. remain + count], 0);
            }
        }
    };
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

test "blip buffer starts empty" {
    var buf = BlipBuf(4800){};
    buf.setRates(53693175.0, 48000.0);
    try testing.expectEqual(@as(usize, 0), buf.samplesAvail());
}

test "blip buffer end frame produces expected sample count" {
    var buf = BlipBuf(4800){};
    buf.setRates(53693175.0, 48000.0);
    // One NTSC frame: 896040 master clocks
    buf.endFrame(896040);
    const avail = buf.samplesAvail();
    // 896040 / 53693175 * 48000 ≈ 800.7 → expect ~800 samples
    try testing.expect(avail >= 799 and avail <= 802);
}

test "blip buffer clear resets to empty" {
    var buf = BlipBuf(4800){};
    buf.setRates(53693175.0, 48000.0);
    buf.endFrame(896040);
    try testing.expect(buf.samplesAvail() > 0);
    buf.clear();
    try testing.expectEqual(@as(usize, 0), buf.samplesAvail());
}

test "blip buffer silence produces zero output" {
    var buf = BlipBuf(4800){};
    buf.setRates(53693175.0, 48000.0);
    // No deltas added, just end frame
    buf.endFrame(896040);
    const avail = buf.samplesAvail();
    var out: [2400]i16 = undefined;
    const read = buf.readSamples(out[0..], avail);
    try testing.expectEqual(avail, read);
    for (out[0 .. read * 2]) |s| {
        try testing.expectEqual(@as(i16, 0), s);
    }
}

test "blip buffer addDelta produces nonzero output" {
    var buf = BlipBuf(4800){};
    buf.setRates(53693175.0, 48000.0);
    buf.addDelta(0, 4000, 4000);
    buf.endFrame(896040);
    var out: [2400]i16 = undefined;
    const read = buf.readSamples(out[0..], buf.samplesAvail());
    var has_nonzero = false;
    for (out[0 .. read * 2]) |s| {
        if (s != 0) has_nonzero = true;
    }
    try testing.expect(has_nonzero);
}

test "blip buffer addDeltaFast produces nonzero output" {
    var buf = BlipBuf(4800){};
    buf.setRates(53693175.0, 48000.0);
    buf.addDeltaFast(0, 4000, 4000);
    buf.endFrame(896040);
    var out: [2400]i16 = undefined;
    const read = buf.readSamples(out[0..], buf.samplesAvail());
    var has_nonzero = false;
    for (out[0 .. read * 2]) |s| {
        if (s != 0) has_nonzero = true;
    }
    try testing.expect(has_nonzero);
}

test "blip buffer stereo separation works" {
    var buf = BlipBuf(4800){};
    buf.setRates(53693175.0, 48000.0);
    // Only left channel delta
    buf.addDelta(0, 8000, 0);
    buf.endFrame(896040);
    var out: [2400]i16 = undefined;
    const read = buf.readSamples(out[0..], buf.samplesAvail());
    var left_energy: u64 = 0;
    var right_energy: u64 = 0;
    for (0..read) |i| {
        left_energy += @intCast(@abs(out[i * 2]));
        right_energy += @intCast(@abs(out[i * 2 + 1]));
    }
    try testing.expect(left_energy > 0);
    try testing.expectEqual(@as(u64, 0), right_energy);
}

test "blip buffer high-pass removes DC over time" {
    var buf = BlipBuf(4800){};
    buf.setRates(53693175.0, 48000.0);
    // Add a single step: the integrator turns it into a DC offset, and the
    // built-in high-pass (bass_shift = 9) should gradually decay it.
    buf.addDelta(0, 10000, 10000);
    buf.endFrame(896040);
    var out: [2400]i16 = undefined;
    const read = buf.readSamples(out[0..], buf.samplesAvail());
    try testing.expect(read > 100);

    // Compare early energy (first quarter) vs late energy (last quarter)
    var early_energy: u64 = 0;
    var late_energy: u64 = 0;
    const quarter = read / 4;
    for (0..quarter) |i| {
        early_energy += @intCast(@abs(out[i * 2]));
    }
    for (read - quarter..read) |i| {
        late_energy += @intCast(@abs(out[i * 2]));
    }
    try testing.expect(early_energy > 0);
    try testing.expect(late_energy < early_energy);
}

test "blip buffer clocks needed round-trips with end frame" {
    var buf = BlipBuf(4800){};
    buf.setRates(53693175.0, 48000.0);
    const clocks = buf.clocksNeeded(800);
    buf.endFrame(@intCast(clocks));
    const avail = buf.samplesAvail();
    try testing.expect(avail >= 800);
}

test "blip buffer read removes samples and makes room" {
    var buf = BlipBuf(4800){};
    buf.setRates(53693175.0, 48000.0);
    buf.addDelta(0, 1000, 1000);
    buf.endFrame(896040);
    const first_avail = buf.samplesAvail();
    var out: [2400]i16 = undefined;
    const read = buf.readSamples(out[0..], first_avail);
    try testing.expectEqual(first_avail, read);
    try testing.expectEqual(@as(usize, 0), buf.samplesAvail());
}

test "blip buffer multiple frames accumulate correctly" {
    var buf = BlipBuf(4800){};
    buf.setRates(53693175.0, 48000.0);
    buf.addDelta(0, 5000, 5000);
    buf.endFrame(448020);
    const first_avail = buf.samplesAvail();
    var out: [2400]i16 = undefined;
    _ = buf.readSamples(out[0..], first_avail);

    buf.addDelta(0, -5000, -5000);
    buf.endFrame(448020);
    const second_avail = buf.samplesAvail();
    try testing.expect(second_avail > 0);
}

test "blip buffer square wave produces alternating output" {
    var buf = BlipBuf(4800){};
    // Use Genesis master clock rate like real usage
    buf.setRates(53693175.0, 48000.0);
    // Generate a square wave with ~1000 cycle half-period
    const half_period: u32 = 1000;
    var prev: i32 = 0;
    var t: u32 = 0;
    while (t < 100000) : (t += half_period) {
        const target: i32 = if ((t / half_period) % 2 == 0) @as(i32, 8000) else @as(i32, -8000);
        buf.addDelta(t, target - prev, target - prev);
        prev = target;
    }
    buf.endFrame(100000);
    var out: [2400]i16 = undefined;
    const read = buf.readSamples(out[0..], buf.samplesAvail());
    try testing.expect(read > 0);

    // Check that output has both positive and negative values (alternating)
    var has_positive = false;
    var has_negative = false;
    for (0..read) |i| {
        if (out[i * 2] > 100) has_positive = true;
        if (out[i * 2] < -100) has_negative = true;
    }
    try testing.expect(has_positive);
    try testing.expect(has_negative);
}
