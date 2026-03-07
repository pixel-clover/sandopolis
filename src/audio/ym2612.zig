const std = @import("std");
const clock = @import("../clock.zig");
const Z80 = @import("../cpu/z80.zig").Z80;

pub const YmWriteEvent = Z80.YmWriteEvent;

pub const StereoSample = struct {
    left: f32,
    right: f32,
};

const StereoPan = struct {
    left: f32,
    right: f32,
};

const EnvelopePhase = enum {
    off,
    attack,
    decay,
    sustain,
    release,
};

const operator_reg_offsets = [_]u8{ 0x00, 0x08, 0x04, 0x0C };
const operator_detune_factors = [_]f32{ 1.0, 1.0030, 1.0060, 1.0120, 0.9970, 0.9940, 0.9880, 0.9820 };
const modulation_phase_scale: f32 = 0.25;
const output_scale: f32 = 0.28;
const ym_cutoff_hz: f32 = 6200.0;
const lfo_dividers = [_]u8{ 108, 77, 71, 67, 62, 44, 8, 5 };
const am_depths = [_]f32{ 0.0, 0.08, 0.18, 0.35 };
const fm_depths = [_]f32{ 0.0, 0.004, 0.008, 0.015, 0.03, 0.06, 0.12, 0.24 };

const OperatorState = struct {
    phase: f32 = 0.0,
    envelope: f32 = 0.0,
    current_output: f32 = 0.0,
    last_output: f32 = 0.0,
    key_on: bool = false,
    envelope_phase: EnvelopePhase = .off,
    ssg_invert: bool = false,
};

pub const Ym2612Synth = struct {
    shadow_regs: [2][256]u8 = [_][256]u8{[_]u8{0} ** 256} ** 2,
    operators: [6][4]OperatorState = [_][4]OperatorState{[_]OperatorState{OperatorState{}} ** 4} ** 6,
    timing_is_pal: bool = false,
    native_sample_rate: f32 = ntscNativeSampleRate(),
    filter_alpha: f32 = filterAlpha(ntscNativeSampleRate()),
    filter_left: f32 = 0.0,
    filter_right: f32 = 0.0,
    channel_am_sensitivity: [6]u8 = [_]u8{0} ** 6,
    channel_fm_sensitivity: [6]u8 = [_]u8{0} ** 6,
    channel3_multi_frequency: bool = false,
    channel3_pending_fnum_high: [3]u8 = [_]u8{0} ** 3,
    channel3_pending_blocks: [3]u8 = [_]u8{0} ** 3,
    channel3_operator_fnums: [3]u16 = [_]u16{0} ** 3,
    channel3_operator_blocks: [3]u8 = [_]u8{0} ** 3,
    lfo_enabled: bool = false,
    lfo_counter: u8 = 0,
    lfo_divider: u8 = 0,
    lfo_frequency_divider: u8 = lfo_dividers[0],

    pub fn setTimingMode(self: *Ym2612Synth, is_pal: bool) void {
        if (self.timing_is_pal == is_pal) return;

        self.timing_is_pal = is_pal;
        self.native_sample_rate = if (is_pal) palNativeSampleRate() else ntscNativeSampleRate();
        self.filter_alpha = filterAlpha(self.native_sample_rate);
    }

    pub fn reset(self: *Ym2612Synth) void {
        self.* = .{};
    }

    pub fn applyWrite(self: *Ym2612Synth, event: YmWriteEvent) void {
        const port: u1 = @intCast(event.port & 1);
        self.shadow_regs[port][event.reg] = event.value;

        if (port == 0) {
            switch (event.reg) {
                0x22 => {
                    self.lfo_enabled = (event.value & 0x08) != 0;
                    self.lfo_frequency_divider = lfo_dividers[event.value & 0x07];
                    if (!self.lfo_enabled) {
                        self.lfo_counter = 0;
                        self.lfo_divider = 0;
                    }
                },
                0x27 => {
                    self.channel3_multi_frequency = (event.value & 0xC0) != 0;
                },
                0xA8...0xAA => self.writeChannel3OperatorLow(event.reg, event.value),
                0xAC...0xAE => self.writeChannel3OperatorHigh(event.reg, event.value),
                else => {},
            }
        }

        if (event.reg >= 0xB4 and event.reg <= 0xB6) {
            const channel_idx = @as(usize, event.port) * 3 + @as(usize, event.reg & 0x03);
            if (channel_idx < 6) {
                self.channel_am_sensitivity[channel_idx] = (event.value >> 4) & 0x03;
                self.channel_fm_sensitivity[channel_idx] = event.value & 0x07;
            }
        }

        if (port == 0 and event.reg == 0x28) {
            self.applyKeyEvent(event.value);
        }
    }

    pub fn tick(self: *Ym2612Synth) StereoSample {
        self.tickLfo();

        var left: f32 = 0.0;
        var right: f32 = 0.0;
        const dac_enabled = self.dacEnabled();

        for (0..6) |channel_idx| {
            const channel: u3 = @intCast(channel_idx);
            const pan = self.channelPan(channel);
            if (pan.left == 0.0 and pan.right == 0.0) continue;

            const mono = if (dac_enabled and channel == 5)
                self.dacCurrentSample() * 0.18
            else
                self.tickChannel(channel) * output_scale;

            left += mono * pan.left;
            right += mono * pan.right;
        }

        self.filter_left += self.filter_alpha * (left - self.filter_left);
        self.filter_right += self.filter_alpha * (right - self.filter_right);

        return .{
            .left = self.filter_left,
            .right = self.filter_right,
        };
    }

    fn ntscNativeSampleRate() f32 {
        return @as(f32, @floatFromInt(clock.master_clock_ntsc)) /
            @as(f32, @floatFromInt(clock.fm_master_cycles_per_sample));
    }

    fn palNativeSampleRate() f32 {
        return @as(f32, @floatFromInt(clock.master_clock_pal)) /
            @as(f32, @floatFromInt(clock.fm_master_cycles_per_sample));
    }

    fn filterAlpha(sample_rate: f32) f32 {
        return 1.0 - @exp(-(std.math.tau * ym_cutoff_hz) / sample_rate);
    }

    fn channelMapping(channel: u3) struct { port: u1, base: u8 } {
        return if (channel >= 3)
            .{ .port = 1, .base = @as(u8, channel - 3) }
        else
            .{ .port = 0, .base = channel };
    }

    fn channelRegister(self: *const Ym2612Synth, channel: u3, reg_base: u8) u8 {
        const mapping = channelMapping(channel);
        return self.shadow_regs[mapping.port][reg_base + mapping.base];
    }

    fn operatorRegister(self: *const Ym2612Synth, channel: u3, reg_base: u8, operator: u2) u8 {
        const mapping = channelMapping(channel);
        return self.shadow_regs[mapping.port][reg_base + operator_reg_offsets[operator] + mapping.base];
    }

    fn attenuationToGain(attenuation: u8) f32 {
        return std.math.exp2(-@as(f32, @floatFromInt(attenuation)) / 16.0);
    }

    fn tickLfo(self: *Ym2612Synth) void {
        self.lfo_divider +%= 1;
        if (self.lfo_divider >= self.lfo_frequency_divider) {
            self.lfo_divider = 0;
            if (self.lfo_enabled) {
                self.lfo_counter = (self.lfo_counter + 1) & 0x7F;
            } else {
                self.lfo_counter = 0;
            }
        }
    }

    fn lfoSignedWave(self: *const Ym2612Synth) f32 {
        const ramp = @as(f32, @floatFromInt(self.lfo_counter & 0x3F)) / 63.0;
        return if ((self.lfo_counter & 0x40) != 0) -ramp else ramp;
    }

    fn lfoAmplitudeWave(self: *const Ym2612Synth) f32 {
        const ramp = if ((self.lfo_counter & 0x40) != 0)
            @as(f32, @floatFromInt(self.lfo_counter & 0x3F)) / 63.0
        else
            @as(f32, @floatFromInt(0x3F - (self.lfo_counter & 0x3F))) / 63.0;
        return ramp;
    }

    fn channel3OperatorIndex(register: u8) u2 {
        return switch (register) {
            0xA8, 0xAC => 2,
            0xA9, 0xAD => 0,
            0xAA, 0xAE => 1,
            else => unreachable,
        };
    }

    fn writeChannel3OperatorLow(self: *Ym2612Synth, register: u8, value: u8) void {
        const operator = channel3OperatorIndex(register);
        const fnum_high = self.channel3_pending_fnum_high[operator];
        self.channel3_operator_fnums[operator] = (@as(u16, fnum_high) << 8) | value;
        self.channel3_operator_blocks[operator] = self.channel3_pending_blocks[operator];
    }

    fn writeChannel3OperatorHigh(self: *Ym2612Synth, register: u8, value: u8) void {
        const operator = channel3OperatorIndex(register);
        self.channel3_pending_fnum_high[operator] = value & 0x07;
        self.channel3_pending_blocks[operator] = (value >> 3) & 0x07;
    }

    fn sustainTargetGain(self: *const Ym2612Synth, channel: u3, operator: u2) f32 {
        const sl = (self.operatorRegister(channel, 0x80, operator) >> 4) & 0x0F;
        const attenuation: u8 = if (sl == 0x0F) 0x7F else sl * 8;
        return attenuationToGain(attenuation);
    }

    fn totalLevelGain(self: *const Ym2612Synth, channel: u3, operator: u2) f32 {
        return attenuationToGain(self.operatorRegister(channel, 0x40, operator) & 0x7F);
    }

    // Compute the effective envelope rate incorporating key scaling.
    // On hardware, the rate is shifted by the key scale value derived from
    // the channel's block and fnum.
    fn effectiveRate(self: *const Ym2612Synth, channel: u3, operator: u2, base_rate: u8) u8 {
        if (base_rate == 0) return 0;
        const ks_reg = self.operatorRegister(channel, 0x50, operator);
        const ks = (ks_reg >> 6) & 0x03;
        const block = (self.channelRegister(channel, 0xA4) >> 3) & 0x07;
        const fnum_high = (self.channelRegister(channel, 0xA4) & 0x07);
        const key_code: u8 = (block << 1) | (fnum_high >> 2);
        const ks_shift: u2 = @intCast(ks);
        const scaled = @as(u16, base_rate) * 2 + (key_code >> (3 - ks_shift));
        return @intCast(@min(63, scaled));
    }

    // Hardware-derived exponential step from effective rate.
    // Rate 0 = no change; rate 63 = instant.
    fn rateToStep(effective: u8) f32 {
        if (effective == 0) return 0.0;
        if (effective >= 63) return 1.0;
        // The hardware uses a power-of-2 attenuation table; approximate with
        // an exponential curve fitted to YM2612 die measurements.
        return std.math.exp2(@as(f32, @floatFromInt(effective)) * 0.26 - 18.0);
    }

    fn attackStep(self: *const Ym2612Synth, channel: u3, operator: u2) f32 {
        const base = self.operatorRegister(channel, 0x50, operator) & 0x1F;
        const eff = self.effectiveRate(channel, operator, base);
        // Attack is faster than decay: use a larger base multiplier.
        if (eff >= 63) return 1.0;
        return rateToStep(eff) * 40.0;
    }

    fn decayStep(self: *const Ym2612Synth, channel: u3, operator: u2) f32 {
        const base = self.operatorRegister(channel, 0x60, operator) & 0x1F;
        return rateToStep(self.effectiveRate(channel, operator, base));
    }

    fn sustainStep(self: *const Ym2612Synth, channel: u3, operator: u2) f32 {
        const base = self.operatorRegister(channel, 0x70, operator) & 0x1F;
        return rateToStep(self.effectiveRate(channel, operator, base));
    }

    fn releaseStep(self: *const Ym2612Synth, channel: u3, operator: u2) f32 {
        const base = self.operatorRegister(channel, 0x80, operator) & 0x0F;
        // Release rate register is 4-bit; doubled to match 5-bit scale.
        return rateToStep(self.effectiveRate(channel, operator, base * 2 + 1));
    }

    fn frequencyFromFnumBlock(fnum: u16, block: u8) f32 {
        if (fnum == 0) return 0.0;

        const base_hz = 0.0527 * @as(f32, @floatFromInt(fnum));
        return base_hz * @as(f32, @floatFromInt(@as(u32, 1) << @intCast(block)));
    }

    fn baseFrequency(self: *const Ym2612Synth, channel: u3) f32 {
        const fnum_low = self.channelRegister(channel, 0xA0);
        const high = self.channelRegister(channel, 0xA4);
        const block = (high >> 3) & 0x07;
        const fnum_high = high & 0x07;
        const fnum: u16 = (@as(u16, fnum_high) << 8) | @as(u16, fnum_low);
        return frequencyFromFnumBlock(fnum, block);
    }

    fn operatorFrequency(self: *const Ym2612Synth, channel: u3, operator: u2) f32 {
        const base = if (channel == 2 and self.channel3_multi_frequency and operator < 3)
            frequencyFromFnumBlock(self.channel3_operator_fnums[operator], self.channel3_operator_blocks[operator])
        else
            self.baseFrequency(channel);
        if (base <= 0.0) return 0.0;

        const dt_mul = self.operatorRegister(channel, 0x30, operator);
        const multiple = dt_mul & 0x0F;
        const detune = (dt_mul >> 4) & 0x07;
        const multiple_factor: f32 = if (multiple == 0) 0.5 else @floatFromInt(multiple);
        const fm_lfo = 1.0 + self.lfoSignedWave() * fm_depths[self.channel_fm_sensitivity[channel]];
        return base * multiple_factor * operator_detune_factors[detune] * fm_lfo;
    }

    fn feedbackAmount(self: *const Ym2612Synth, channel: u3) f32 {
        const feedback = (self.channelRegister(channel, 0xB0) >> 3) & 0x07;
        if (feedback == 0) return 0.0;
        return 0.004 * @as(f32, @floatFromInt(@as(u32, 1) << @intCast(feedback)));
    }

    fn channelAlgorithm(self: *const Ym2612Synth, channel: u3) u8 {
        return self.channelRegister(channel, 0xB0) & 0x07;
    }

    fn channelPan(self: *const Ym2612Synth, channel: u3) StereoPan {
        const pan = self.channelRegister(channel, 0xB4);
        const right_on = (pan & 0x40) != 0;
        const left_on = (pan & 0x80) != 0;
        return .{
            .left = if (left_on) 1.0 else 0.0,
            .right = if (right_on) 1.0 else 0.0,
        };
    }

    fn dacEnabled(self: *const Ym2612Synth) bool {
        return (self.shadow_regs[0][0x2B] & 0x80) != 0;
    }

    fn dacCurrentSample(self: *const Ym2612Synth) f32 {
        return (@as(f32, @floatFromInt(self.shadow_regs[0][0x2A])) - 128.0) / 128.0;
    }

    fn applyKeyEvent(self: *Ym2612Synth, value: u8) void {
        var channel = value & 0x03;
        if (channel == 0x03) return;
        if ((value & 0x04) != 0) channel +%= 3;

        inline for (0..4) |operator_idx| {
            const operator_bit: u8 = @as(u8, 1) << @intCast(4 + operator_idx);
            const key_on = (value & operator_bit) != 0;
            self.setOperatorKey(@intCast(channel), @intCast(operator_idx), key_on);
        }
    }

    fn setOperatorKey(self: *Ym2612Synth, channel: u3, operator: u2, key_on: bool) void {
        var state = &self.operators[channel][operator];
        if (key_on) {
            if (!state.key_on) {
                state.phase = 0.0;
                state.key_on = true;
                state.envelope_phase = .attack;
                // SSG-EG: set initial inversion based on bit 2.
                if (self.ssgEgEnabled(channel, operator)) {
                    state.ssg_invert = (self.ssgEgRegister(channel, operator) & 0x04) != 0;
                } else {
                    state.ssg_invert = false;
                }
                if ((self.operatorRegister(channel, 0x50, operator) & 0x1F) >= 31) {
                    state.envelope = 1.0;
                    state.envelope_phase = .decay;
                }
            }
        } else if (state.key_on) {
            state.key_on = false;
            if (state.envelope_phase != .off) {
                state.envelope_phase = .release;
            }
        }
    }

    fn ssgEgRegister(self: *const Ym2612Synth, channel: u3, operator: u2) u8 {
        return self.operatorRegister(channel, 0x90, operator) & 0x0F;
    }

    fn ssgEgEnabled(self: *const Ym2612Synth, channel: u3, operator: u2) bool {
        return (self.ssgEgRegister(channel, operator) & 0x08) != 0;
    }

    fn tickEnvelope(self: *Ym2612Synth, channel: u3, operator: u2) f32 {
        var state = &self.operators[channel][operator];
        switch (state.envelope_phase) {
            .off => state.envelope = 0.0,
            .attack => {
                state.envelope += (1.0 - state.envelope) * self.attackStep(channel, operator);
                if (state.envelope >= 0.995) {
                    state.envelope = 1.0;
                    state.envelope_phase = .decay;
                }
            },
            .decay => {
                const target = self.sustainTargetGain(channel, operator);
                state.envelope = @max(target, state.envelope - self.decayStep(channel, operator) * @max(state.envelope, 0.02));
                if (state.envelope <= target + 0.0001) {
                    state.envelope = target;
                    state.envelope_phase = .sustain;
                }
            },
            .sustain => {
                state.envelope = @max(0.0, state.envelope - self.sustainStep(channel, operator) * @max(state.envelope, 0.02));
                if (state.envelope <= 0.0001) {
                    state.envelope = 0.0;
                    // SSG-EG: handle envelope repeat/invert when reaching minimum.
                    if (self.ssgEgEnabled(channel, operator) and state.key_on) {
                        self.handleSsgEgCycle(channel, operator);
                    } else {
                        state.envelope_phase = .off;
                    }
                }
            },
            .release => {
                state.envelope = @max(0.0, state.envelope - self.releaseStep(channel, operator) * @max(state.envelope, 0.02));
                if (state.envelope <= 0.0001) {
                    state.envelope = 0.0;
                    state.envelope_phase = .off;
                    state.ssg_invert = false;
                }
            },
        }

        var effective_envelope = state.envelope;
        // SSG-EG inversion: when ssg_invert is set, output is (1 - envelope).
        if (state.ssg_invert) {
            effective_envelope = 1.0 - effective_envelope;
        }

        var gain = effective_envelope * self.totalLevelGain(channel, operator);
        if ((self.operatorRegister(channel, 0x60, operator) & 0x80) != 0) {
            gain *= 1.0 - am_depths[self.channel_am_sensitivity[channel]] * self.lfoAmplitudeWave();
        }
        return gain;
    }

    fn handleSsgEgCycle(self: *Ym2612Synth, channel: u3, operator: u2) void {
        var state = &self.operators[channel][operator];
        const ssg = self.ssgEgRegister(channel, operator) & 0x07;
        // SSG-EG types (bit 2 = invert initial, bit 1 = alternate, bit 0 = hold):
        //   0: \\\\  repeat attack (no invert)
        //   1: \___  decay then hold at min
        //   2: \/\/  alternate (sawtooth)
        //   3: \‾‾‾  decay then hold at max (inverted)
        //   4: ////  repeat attack (inverted)
        //   5: /‾‾‾  attack then hold at max
        //   6: /\/\  alternate (inverted sawtooth)
        //   7: /___  attack then hold at min (inverted)
        const alternate = (ssg & 0x02) != 0;
        const hold = (ssg & 0x01) != 0;

        if (hold) {
            if (alternate) {
                state.ssg_invert = !state.ssg_invert;
            }
            state.envelope_phase = .off;
            if (state.ssg_invert) {
                state.envelope = 1.0;
            } else {
                state.envelope = 0.0;
            }
        } else {
            if (alternate) {
                state.ssg_invert = !state.ssg_invert;
            }
            state.envelope = 0.0;
            state.envelope_phase = .attack;
            state.phase = 0.0;
        }
    }

    fn sampleOperator(self: *Ym2612Synth, channel: u3, operator: u2, modulation: f32) f32 {
        var state = &self.operators[channel][operator];
        const frequency = self.operatorFrequency(channel, operator);
        const gain = self.tickEnvelope(channel, operator);
        if (frequency <= 0.0 or gain <= 0.00005) {
            state.last_output = state.current_output;
            state.current_output = 0.0;
            return 0.0;
        }

        state.phase += frequency / self.native_sample_rate;
        state.phase -= @floor(state.phase);

        const phase = (state.phase + modulation * modulation_phase_scale) * std.math.tau;
        const sample = std.math.sin(phase) * gain;
        state.last_output = state.current_output;
        state.current_output = sample;
        return sample;
    }

    fn clampCarrierSum(sum: f32) f32 {
        return @max(-1.0, @min(1.0, sum));
    }

    fn tickChannel(self: *Ym2612Synth, channel: u3) f32 {
        const feedback = self.feedbackAmount(channel) *
            (self.operators[channel][0].current_output + self.operators[channel][0].last_output);

        return switch (self.channelAlgorithm(channel)) {
            0 => blk: {
                const m1 = self.sampleOperator(channel, 0, feedback);
                const m2_old = self.operators[channel][1].current_output;
                _ = self.sampleOperator(channel, 1, m1);
                const m3 = self.sampleOperator(channel, 2, m2_old);
                break :blk self.sampleOperator(channel, 3, m3);
            },
            1 => blk: {
                const m1_old = self.operators[channel][0].current_output;
                _ = self.sampleOperator(channel, 0, feedback);
                const m2_old = self.operators[channel][1].current_output;
                _ = self.sampleOperator(channel, 1, 0.0);
                const m3 = self.sampleOperator(channel, 2, m1_old + m2_old);
                break :blk self.sampleOperator(channel, 3, m3);
            },
            2 => blk: {
                const m1 = self.sampleOperator(channel, 0, feedback);
                const m2_old = self.operators[channel][1].current_output;
                _ = self.sampleOperator(channel, 1, 0.0);
                const m3 = self.sampleOperator(channel, 2, m2_old);
                break :blk self.sampleOperator(channel, 3, m1 + m3);
            },
            3 => blk: {
                const m1 = self.sampleOperator(channel, 0, feedback);
                const m2_old = self.operators[channel][1].current_output;
                _ = self.sampleOperator(channel, 1, m1);
                const m3 = self.sampleOperator(channel, 2, 0.0);
                break :blk self.sampleOperator(channel, 3, m2_old + m3);
            },
            4 => blk: {
                const m1 = self.sampleOperator(channel, 0, feedback);
                const c2 = self.sampleOperator(channel, 1, m1);
                const m3 = self.sampleOperator(channel, 2, 0.0);
                const c4 = self.sampleOperator(channel, 3, m3);
                break :blk clampCarrierSum(c2 + c4);
            },
            5 => blk: {
                const m1_old = self.operators[channel][0].current_output;
                const m1 = self.sampleOperator(channel, 0, feedback);
                const c2 = self.sampleOperator(channel, 1, m1);
                const c3 = self.sampleOperator(channel, 2, m1_old);
                const c4 = self.sampleOperator(channel, 3, m1);
                break :blk clampCarrierSum(c2 + c3 + c4);
            },
            6 => blk: {
                const m1 = self.sampleOperator(channel, 0, feedback);
                const c2 = self.sampleOperator(channel, 1, m1);
                const c3 = self.sampleOperator(channel, 2, 0.0);
                const c4 = self.sampleOperator(channel, 3, 0.0);
                break :blk clampCarrierSum(c2 + c3 + c4);
            },
            else => blk: {
                const c1 = self.sampleOperator(channel, 0, feedback);
                const c2 = self.sampleOperator(channel, 1, 0.0);
                const c3 = self.sampleOperator(channel, 2, 0.0);
                const c4 = self.sampleOperator(channel, 3, 0.0);
                break :blk clampCarrierSum(c1 + c2 + c3 + c4);
            },
        };
    }
};

fn writeEvent(port: u1, reg: u8, value: u8) YmWriteEvent {
    return .{ .port = port, .reg = reg, .value = value };
}

fn configureTestChannel(synth: *Ym2612Synth, algorithm: u8) void {
    synth.applyWrite(writeEvent(0, 0xA0, 0x80));
    synth.applyWrite(writeEvent(0, 0xA4, 0x22));
    synth.applyWrite(writeEvent(0, 0xB0, algorithm));
    synth.applyWrite(writeEvent(0, 0xB4, 0xC0));

    inline for (0..4) |op_idx| {
        const offset = operator_reg_offsets[op_idx];
        synth.applyWrite(writeEvent(0, 0x30 + offset, 0x01));
        synth.applyWrite(writeEvent(0, 0x40 + offset, if (op_idx == 3) 0x00 else 0x18));
        synth.applyWrite(writeEvent(0, 0x50 + offset, 0x1F));
        synth.applyWrite(writeEvent(0, 0x60 + offset, 0x0C));
        synth.applyWrite(writeEvent(0, 0x70 + offset, 0x08));
        synth.applyWrite(writeEvent(0, 0x80 + offset, 0x24));
    }

    synth.applyWrite(writeEvent(0, 0x28, 0xF0));
}

test "ym operator algorithms produce distinct output" {
    var synth_a = Ym2612Synth{};
    var synth_b = Ym2612Synth{};
    configureTestChannel(&synth_a, 0);
    configureTestChannel(&synth_b, 7);

    var sum_diff: f32 = 0.0;
    for (0..256) |_| {
        const a = synth_a.tick();
        const b = synth_b.tick();
        sum_diff += @abs(a.left - b.left) + @abs(a.right - b.right);
    }

    try std.testing.expect(sum_diff > 0.5);
}

test "ym key off releases output over time" {
    var synth = Ym2612Synth{};
    configureTestChannel(&synth, 4);

    var pre_release_energy: f32 = 0.0;
    for (0..192) |_| {
        const sample = synth.tick();
        pre_release_energy += @abs(sample.left) + @abs(sample.right);
    }

    synth.applyWrite(writeEvent(0, 0x28, 0x00));

    var post_release_energy: f32 = 0.0;
    for (0..384) |_| {
        const sample = synth.tick();
        post_release_energy += @abs(sample.left) + @abs(sample.right);
    }

    try std.testing.expect(pre_release_energy > 0.1);
    try std.testing.expect(post_release_energy < pre_release_energy);
}

test "ym channel 3 special mode uses operator-specific frequencies" {
    var normal = Ym2612Synth{};
    var special = Ym2612Synth{};

    configureTestChannel(&normal, 0);
    configureTestChannel(&special, 0);
    special.applyWrite(writeEvent(0, 0x27, 0x40));
    special.applyWrite(writeEvent(0, 0xAC, 0x25));
    special.applyWrite(writeEvent(0, 0xA8, 0x40));
    special.applyWrite(writeEvent(0, 0xAD, 0x1F));
    special.applyWrite(writeEvent(0, 0xA9, 0x10));
    special.applyWrite(writeEvent(0, 0xAE, 0x29));
    special.applyWrite(writeEvent(0, 0xAA, 0xE0));

    var sum_diff: f32 = 0.0;
    for (0..256) |_| {
        const a = normal.tick();
        const b = special.tick();
        sum_diff += @abs(a.left - b.left) + @abs(a.right - b.right);
    }

    try std.testing.expect(sum_diff > 0.5);
}

test "ym lfo sensitivity modulates output" {
    var no_lfo = Ym2612Synth{};
    var with_lfo = Ym2612Synth{};

    configureTestChannel(&no_lfo, 4);
    configureTestChannel(&with_lfo, 4);
    with_lfo.applyWrite(writeEvent(0, 0x22, 0x0F));
    with_lfo.applyWrite(writeEvent(0, 0x60 + operator_reg_offsets[3], 0x80 | 0x0C));
    with_lfo.applyWrite(writeEvent(0, 0xB4, 0xF7));

    var sum_diff: f32 = 0.0;
    for (0..512) |_| {
        const a = no_lfo.tick();
        const b = with_lfo.tick();
        sum_diff += @abs(a.left - b.left) + @abs(a.right - b.right);
    }

    try std.testing.expect(sum_diff > 0.5);
}

test "ym ssg-eg repeat type produces sustained output" {
    var normal = Ym2612Synth{};
    var ssg_synth = Ym2612Synth{};

    configureTestChannel(&normal, 4);
    configureTestChannel(&ssg_synth, 4);

    // Enable SSG-EG type 0 (repeat, no invert) on all operators.
    inline for (0..4) |op_idx| {
        const offset = operator_reg_offsets[op_idx];
        ssg_synth.applyWrite(writeEvent(0, 0x90 + offset, 0x08));
    }

    var ssg_late_energy: f32 = 0.0;
    var normal_late_energy: f32 = 0.0;

    for (0..2048) |_| {
        _ = normal.tick();
        _ = ssg_synth.tick();
    }

    for (0..1024) |_| {
        const ns = normal.tick();
        const ss = ssg_synth.tick();
        normal_late_energy += @abs(ns.left) + @abs(ns.right);
        ssg_late_energy += @abs(ss.left) + @abs(ss.right);
    }

    try std.testing.expect(ssg_late_energy > normal_late_energy);
}

test "ym ssg-eg inverted type flips output polarity" {
    var normal = Ym2612Synth{};
    var inverted = Ym2612Synth{};

    configureTestChannel(&normal, 7);
    configureTestChannel(&inverted, 7);

    const offset = operator_reg_offsets[3];
    inverted.applyWrite(writeEvent(0, 0x90 + offset, 0x0C));

    var sum_diff: f32 = 0.0;
    for (0..512) |_| {
        const n = normal.tick();
        const i = inverted.tick();
        sum_diff += @abs(n.left - i.left) + @abs(n.right - i.right);
    }

    try std.testing.expect(sum_diff > 0.1);
}
