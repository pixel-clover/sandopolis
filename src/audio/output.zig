const std = @import("std");
const log = std.log.scoped(.audio);
const clock = @import("../clock.zig");
const blip_buf = @import("blip_buf.zig");
const eq_mod = @import("eq.zig");
const Eq3Band = eq_mod.Eq3Band;
const PendingAudioFrames = @import("timing.zig").PendingAudioFrames;
const Z80 = @import("../cpu/z80.zig").Z80;
const YmWriteEvent = Z80.YmWriteEvent;
const YmDacSampleEvent = Z80.YmDacSampleEvent;
const YmResetEvent = Z80.YmResetEvent;
const PsgCommandEvent = Z80.PsgCommandEvent;
const psg_mod = @import("psg.zig");
const Psg = psg_mod.Psg;
const PsgStereoSample = psg_mod.PsgStereoSample;
const ym2612 = @import("ym2612.zig");
const Ym2612Synth = ym2612.Ym2612Synth;
const YmStereoSample = ym2612.StereoSample;

const YmEventKind = enum {
    write,
    dac,
    reset,
};

const YmEventOrder = struct {
    master_offset: u32,
    sequence: u32,
};

const YmGenerationResult = struct {
    produced_count: usize,
    ym_write_cursor: usize,
    ym_dac_cursor: usize,
    ym_reset_cursor: usize,
};

const PendingAudioEvents = struct {
    ym_writes: []const YmWriteEvent,
    ym_dac_samples: []const YmDacSampleEvent,
    ym_reset_events: []const YmResetEvent,
    psg_commands: []const PsgCommandEvent,
};

const DcBlocker = struct {
    x_prev: f32 = 0.0,
    y_prev: f32 = 0.0,
    alpha: f32,
    warmup_samples: u8 = 0,

    // The blip buffer's built-in high-pass applies a single-pole filter while
    // converting mixed chip output to PCM:
    //   y[n] = x[n] - x[n-1] + (1 - 2^-bass_shift) * y[n-1]
    // Match that coefficient here so DAC-heavy playback sees the same DC
    // removal before the board low-pass stage.
    const bass_shift: u5 = 9;
    const blip_highpass_alpha: f32 = 1.0 - (1.0 / @as(f32, 1 << bass_shift));
    const warmup_count: u8 = 8;

    fn init(sample_rate: f64) DcBlocker {
        _ = sample_rate;
        return .{
            .alpha = blip_highpass_alpha,
        };
    }

    fn process(self: *DcBlocker, x: f32) f32 {
        const y = self.alpha * (self.y_prev + x - self.x_prev);
        self.x_prev = x;
        self.y_prev = y;

        // Apply gradual fade-in during warmup to avoid startup click.
        // The filter needs a few samples to stabilize; blending prevents
        // the transient from being audible.
        if (self.warmup_samples < warmup_count) {
            self.warmup_samples += 1;
            const blend = @as(f32, @floatFromInt(self.warmup_samples)) / @as(f32, warmup_count);
            return y * blend;
        }
        return y;
    }
};

// The default Mega Drive audio profile runs PSG at 150% preamp versus FM at 100%.
// The base mix gain accounts for the amplitude difference between PSG (unipolar, 4-channel
// sum up to ~32K) and FM (bipolar, 6-channel sum with internal scaling). The effective
// gain is calibrated so PSG-only RMS matches expected console output within ~5%.
const fm_preamp_percent: f32 = 100.0;
const psg_preamp_percent: f32 = 150.0;
const psg_base_mix_gain: f32 = 0.3425;
const psg_mix_gain: f32 = psg_base_mix_gain * (psg_preamp_percent / fm_preamp_percent);

const BoardOutputLpf = struct {
    prev_l: f32 = 0.0,
    prev_r: f32 = 0.0,
    history_factor: f32,
    input_factor: f32,
    warmup_samples: u8 = 0,

    const warmup_count: u8 = 8;

    fn init() BoardOutputLpf {
        return .{
            .history_factor = board_output_history_factor,
            .input_factor = board_output_input_factor,
        };
    }

    fn processL(self: *BoardOutputLpf, x: f32) f32 {
        self.prev_l = self.prev_l * self.history_factor + x * self.input_factor;

        // Apply gradual fade-in during warmup to avoid startup transient.
        if (self.warmup_samples < warmup_count) {
            self.warmup_samples += 1;
            const blend = @as(f32, @floatFromInt(self.warmup_samples)) / @as(f32, warmup_count);
            return self.prev_l * blend;
        }
        return self.prev_l;
    }

    fn processR(self: *BoardOutputLpf, x: f32) f32 {
        self.prev_r = self.prev_r * self.history_factor + x * self.input_factor;

        // Warmup already counted in processL (called first in stereo pair)
        if (self.warmup_samples < warmup_count) {
            const blend = @as(f32, @floatFromInt(self.warmup_samples)) / @as(f32, warmup_count);
            return self.prev_r * blend;
        }
        return self.prev_r;
    }
};

// Board output low-pass filter, modelling the analog path on the Genesis
// mainboard.  Uses lp_range = 0x9999 (single-pole IIR, fc ≈ 3.9 kHz at
// 44.1 kHz).  Empirical A/B comparison of all four test ROMs (SOR, GA2,
// ROS, SN) showed that this coefficient at our 48 kHz output rate
// (fc ≈ 4.0 kHz) produces the closest match in both RMS level and
// spectral content above 6 kHz.  The earlier 0x6000 value
// (fc ≈ 8 kHz) left Sandopolis +4 to +13 dB too bright above 6 kHz.
const board_output_history_factor: f32 = @as(f32, 0x9999) / 65536.0;
const board_output_input_factor: f32 = 1.0 - board_output_history_factor;
// PSG low-pass filter before downsampling. The blip buffer already handles
// anti-aliasing, so no additional PSG filtering is needed. Setting this very high (22 kHz)
// essentially passes through all audible content, preserving the bright, buzzy
// character of real Genesis PSG square waves. Only ultrasonic content is attenuated.
const psg_native_cutoff_hz: f32 = 22000.0;
const resample_scaling_factor: u64 = 1_000_000_000;
const resample_buffer_len: usize = 6;
const resample_output_queue_capacity: usize = 8192;

// BlipBuf capacity: enough for several frames at 48 kHz output.
const blip_buf_capacity: usize = 4800;
const BlipBuffer = blip_buf.BlipBuf(blip_buf_capacity);

// Default 3-band EQ crossover frequencies, commonly used in Genesis emulators.
const eq_default_low_freq: u32 = 880;
const eq_default_high_freq: u32 = 5000;

const FirstOrderLpf = struct {
    prev: f32 = 0.0,
    history_factor: f32,
    input_factor: f32,
    warmup_samples: u8 = 0,

    const warmup_count: u8 = 8;

    fn init(cutoff_hz: f32, sample_rate: f64) FirstOrderLpf {
        const history: f32 = @floatCast(@exp((-std.math.tau * @as(f64, cutoff_hz)) / sample_rate));
        return .{
            .history_factor = history,
            .input_factor = 1.0 - history,
        };
    }

    fn process(self: *FirstOrderLpf, x: f32) f32 {
        self.prev = self.prev * self.history_factor + x * self.input_factor;

        // Apply gradual fade-in during warmup to avoid startup transient.
        if (self.warmup_samples < warmup_count) {
            self.warmup_samples += 1;
            const blend = @as(f32, @floatFromInt(self.warmup_samples)) / @as(f32, warmup_count);
            return self.prev * blend;
        }
        return self.prev;
    }
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

fn interpolateCubicHermite6p(samples: [6]f64, x: f64) f64 {
    const ym2 = samples[0];
    const ym1 = samples[1];
    const y0 = samples[2];
    const y1 = samples[3];
    const y2 = samples[4];
    const y3 = samples[5];

    const c0 = y0;
    const c1 = (1.0 / 12.0) * (ym2 - y2) + (2.0 / 3.0) * (y1 - ym1);
    const c2 = (5.0 / 4.0) * ym1 - (7.0 / 3.0) * y0 + (5.0 / 3.0) * y1 - (1.0 / 2.0) * y2 + (1.0 / 12.0) * y3 -
        (1.0 / 6.0) * ym2;
    const c3 = (1.0 / 12.0) * (ym2 - y3) + (7.0 / 12.0) * (y2 - ym1) + (4.0 / 3.0) * (y0 - y1);

    return ((c3 * x + c2) * x + c1) * x + c0;
}

fn CubicResampler(comptime channels_count: usize) type {
    return struct {
        const Self = @This();

        scaled_source_frequency: u64,
        output_frequency: u32,
        cycle_counter_product: u64 = 0,
        scaled_x_counter: u64 = 0,
        input_samples: [resample_buffer_len + 1][channels_count]f32 = [_][channels_count]f32{[_]f32{0.0} ** channels_count} ** (resample_buffer_len + 1),
        input_len: usize = resample_buffer_len,
        output_samples: [resample_output_queue_capacity][channels_count]f32 = undefined,
        output_read: usize = 0,
        output_write: usize = 0,
        output_count: usize = 0,

        fn init(source_frequency: f64, output_frequency: u32) Self {
            return .{
                .scaled_source_frequency = scaleSourceFrequency(source_frequency),
                .output_frequency = output_frequency,
            };
        }

        fn reset(self: *Self, source_frequency: f64, output_frequency: u32) void {
            self.* = init(source_frequency, output_frequency);
        }

        fn outputBufferLen(self: *const Self) usize {
            return self.output_count;
        }

        fn hasValidState(self: *const Self) bool {
            if (self.scaled_source_frequency == 0 or self.output_frequency == 0) return false;
            if (self.input_len > self.input_samples.len) return false;
            if (self.output_read >= self.output_samples.len) return false;
            if (self.output_write >= self.output_samples.len) return false;
            if (self.output_count > self.output_samples.len) return false;

            if (self.output_count == self.output_samples.len) {
                return self.output_read == self.output_write;
            }

            if (self.output_count == 0) {
                return self.output_read == self.output_write;
            }

            // Use saturating arithmetic to prevent any overflow panics
            const distance = if (self.output_write >= self.output_read)
                self.output_write -| self.output_read
            else
                (self.output_samples.len -| self.output_read) +| self.output_write;
            return self.output_count == distance;
        }

        fn outputBufferPopFront(self: *Self) ?[channels_count]f32 {
            if (self.output_count == 0) return null;
            // Guard against corrupted output_read index
            if (self.output_read >= self.output_samples.len) return null;

            const sample = self.output_samples[self.output_read];
            self.output_read = (self.output_read + 1) % self.output_samples.len;
            self.output_count -|= 1; // Use saturating subtraction for safety
            return sample;
        }

        fn collectSample(self: *Self, sample: [channels_count]f32) void {
            self.pushInputSample(sample);

            const scaled_output_frequency = @as(u64, self.output_frequency) * resample_scaling_factor;
            self.cycle_counter_product += scaled_output_frequency;
            while (self.cycle_counter_product >= self.scaled_source_frequency) {
                self.cycle_counter_product -= self.scaled_source_frequency;

                while (self.input_len < resample_buffer_len) {
                    // Use the first available sample for padding instead of zeros to avoid
                    // startup clicks and discontinuities at buffer boundaries.
                    self.pushFrontInputSample(self.input_samples[0]);
                }

                const x = @as(f64, @floatFromInt(self.scaled_x_counter)) / @as(f64, @floatFromInt(scaled_output_frequency));
                var output: [channels_count]f32 = undefined;
                for (0..channels_count) |channel| {
                    var points: [6]f64 = undefined;
                    for (0..resample_buffer_len) |i| {
                        points[i] = @as(f64, self.input_samples[i][channel]);
                    }
                    output[channel] = @floatCast(std.math.clamp(interpolateCubicHermite6p(points, x), -1.0, 1.0));
                }
                self.pushOutputSample(output);

                self.scaled_x_counter += self.scaled_source_frequency;
                while (self.scaled_x_counter >= scaled_output_frequency) {
                    self.scaled_x_counter -= scaled_output_frequency;
                    self.popFrontInputSample();
                }
            }

            while (self.input_len > resample_buffer_len + 1) {
                self.popFrontInputSample();
            }
        }

        fn pushOutputSample(self: *Self, sample: [channels_count]f32) void {
            // Guard against corrupted indices
            if (self.output_write >= self.output_samples.len or
                self.output_read >= self.output_samples.len or
                self.output_count > self.output_samples.len)
            {
                return;
            }

            if (self.output_count == self.output_samples.len) {
                self.output_read = (self.output_read + 1) % self.output_samples.len;
                self.output_count -|= 1; // Use saturating subtraction for safety
            }

            self.output_samples[self.output_write] = sample;
            self.output_write = (self.output_write + 1) % self.output_samples.len;
            self.output_count +|= 1; // Use saturating addition for safety
        }

        fn pushInputSample(self: *Self, sample: [channels_count]f32) void {
            if (self.input_len == self.input_samples.len) {
                self.popFrontInputSample();
            }

            self.input_samples[self.input_len] = sample;
            self.input_len += 1;
        }

        fn pushFrontInputSample(self: *Self, sample: [channels_count]f32) void {
            if (self.input_len == self.input_samples.len) return;
            std.mem.copyBackwards([channels_count]f32, self.input_samples[1 .. self.input_len + 1], self.input_samples[0..self.input_len]);
            self.input_samples[0] = sample;
            self.input_len += 1;
        }

        fn popFrontInputSample(self: *Self) void {
            if (self.input_len == 0) return;
            if (self.input_len > 1) {
                std.mem.copyForwards([channels_count]f32, self.input_samples[0 .. self.input_len - 1], self.input_samples[1..self.input_len]);
            }
            self.input_len -= 1;
        }
    };
}

fn scaleSourceFrequency(source_frequency: f64) u64 {
    return @intFromFloat(@round(source_frequency * @as(f64, @floatFromInt(resample_scaling_factor))));
}

const StereoResampler = CubicResampler(2);
const MonoResampler = CubicResampler(1);

fn initNtscBlip() BlipBuffer {
    var b = BlipBuffer{};
    b.setRates(@as(f64, @floatFromInt(clock.master_clock_ntsc)), @as(f64, output_rate_f));
    return b;
}

fn initPalBlip() BlipBuffer {
    var b = BlipBuffer{};
    b.setRates(@as(f64, @floatFromInt(clock.master_clock_pal)), @as(f64, output_rate_f));
    return b;
}

const output_rate_f: f64 = 48_000.0;

pub const AudioOutput = struct {
    pub const RenderMode = enum {
        normal,
        ym_only,
        psg_only,
        unfiltered_mix,

        pub fn name(self: RenderMode) []const u8 {
            return switch (self) {
                .normal => "normal",
                .ym_only => "ym-only",
                .psg_only => "psg-only",
                .unfiltered_mix => "unfiltered-mix",
            };
        }

        pub fn label(self: RenderMode) []const u8 {
            return switch (self) {
                .normal => "NORMAL",
                .ym_only => "YM ONLY",
                .psg_only => "PSG ONLY",
                .unfiltered_mix => "UNFILTERED MIX",
            };
        }

        pub fn parse(value: []const u8) error{InvalidAudioMode}!RenderMode {
            if (std.mem.eql(u8, value, "normal")) return .normal;
            if (std.mem.eql(u8, value, "ym-only") or std.mem.eql(u8, value, "ym_only")) return .ym_only;
            if (std.mem.eql(u8, value, "psg-only") or std.mem.eql(u8, value, "psg_only")) return .psg_only;
            if (std.mem.eql(u8, value, "unfiltered-mix") or std.mem.eql(u8, value, "unfiltered_mix")) return .unfiltered_mix;
            return error.InvalidAudioMode;
        }

        pub fn cycle(self: RenderMode, delta: isize) RenderMode {
            const modes = [_]RenderMode{ .normal, .ym_only, .psg_only, .unfiltered_mix };
            var index: isize = 0;
            for (modes, 0..) |candidate, i| {
                if (candidate == self) {
                    index = @intCast(i);
                    break;
                }
            }
            index += delta;
            const count: isize = @intCast(modes.len);
            while (index < 0) index += count;
            while (index >= count) index -= count;
            return modes[@intCast(index)];
        }
    };

    pub const output_rate: u32 = 48_000;
    pub const channels: usize = 2;
    pub const min_queue_budget_ms: u16 = 40;
    pub const default_queue_budget_ms: u16 = 60;
    pub const max_queue_budget_ms: u16 = 150;
    pub const max_queued_ms: u32 = max_queue_budget_ms;
    pub const max_queued_bytes: usize = queueBudgetBytes(max_queue_budget_ms);
    const max_ym_writes_per_push: usize = 32768;
    const max_ym_dac_samples_per_push: usize = 4096;
    const max_ym_reset_events_per_push: usize = 64;
    const max_psg_commands_per_push: usize = 8192;
    const max_ym_native_samples_per_chunk: usize = 4096;
    const ym_internal_master_cycles: u16 = clock.m68k_divider * 6;
    const ym_internal_clocks_per_sample: u8 = @intCast(clock.fm_master_cycles_per_sample / ym_internal_master_cycles);

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
    ym_write_buffer: [max_ym_writes_per_push]YmWriteEvent = undefined,
    ym_dac_buffer: [max_ym_dac_samples_per_push]YmDacSampleEvent = undefined,
    ym_reset_buffer: [max_ym_reset_events_per_push]YmResetEvent = undefined,
    psg_command_buffer: [max_psg_commands_per_push]PsgCommandEvent = undefined,
    ym_native_buffer: [max_ym_native_samples_per_chunk]YmStereoSample = undefined,
    ym_synth: Ym2612Synth = .{},
    psg: Psg = Psg{},
    ym_resampler: StereoResampler = StereoResampler.init(ntscYmNativeSampleRate(), output_rate),
    psg_resampler: StereoResampler = StereoResampler.init(ntscPsgNativeSampleRate(), output_rate),
    psg_native_lpf_l: FirstOrderLpf = FirstOrderLpf.init(psg_native_cutoff_hz, ntscPsgNativeSampleRate()),
    psg_native_lpf_r: FirstOrderLpf = FirstOrderLpf.init(psg_native_cutoff_hz, ntscPsgNativeSampleRate()),
    dc_left: DcBlocker = DcBlocker.init(output_rate),
    dc_right: DcBlocker = DcBlocker.init(output_rate),
    board_lpf: BoardOutputLpf = BoardOutputLpf.init(),
    eq_left: Eq3Band = Eq3Band.init(eq_default_low_freq, eq_default_high_freq, output_rate),
    eq_right: Eq3Band = Eq3Band.init(eq_default_low_freq, eq_default_high_freq, output_rate),
    eq_enabled: bool = false,
    blip: BlipBuffer = initNtscBlip(),
    blip_fm_last_left: i32 = 0,
    blip_fm_last_right: i32 = 0,
    blip_psg_last_left: i32 = 0,
    blip_psg_last_right: i32 = 0,
    render_mode: RenderMode = .normal,
    psg_volume_percent: u8 = 150,
    total_overflow_events: u64 = 0,
    last_overflow_events: u32 = 0,
    ym_internal_master_remainder: u16 = 0,
    ym_partial_sum_left: i32 = 0,
    ym_partial_sum_right: i32 = 0,
    ym_partial_internal_clocks: u8 = 0,
    last_ym_resampled_left: f32 = 0.0,
    last_ym_resampled_right: f32 = 0.0,
    last_psg_resampled_left: f32 = 0.0,
    last_psg_resampled_right: f32 = 0.0,
    last_ym_left: f32 = 0.0,
    last_ym_right: f32 = 0.0,
    last_psg_sample_left: i16 = 0,
    last_psg_sample_right: i16 = 0,
    last_psg_filtered_left: f32 = 0.0,
    last_psg_filtered_right: f32 = 0.0,
    psg_partial_master_cycles: u16 = 0,
    psg_partial_sum_left: i64 = 0,
    psg_partial_sum_right: i64 = 0,

    pub fn init() AudioOutput {
        var output: AudioOutput = .{};
        output.reset();
        return output;
    }

    pub fn isValidQueueBudgetMs(ms: u16) bool {
        return ms >= min_queue_budget_ms and ms <= max_queue_budget_ms;
    }

    pub fn clampQueueBudgetMs(ms: u16) u16 {
        return std.math.clamp(ms, min_queue_budget_ms, max_queue_budget_ms);
    }

    pub fn queueBudgetBytes(ms: u16) usize {
        return (@as(usize, output_rate) * @as(usize, ms) / 1000) * channels * @sizeOf(i16);
    }

    pub fn totalOverflowEvents(self: *const AudioOutput) u64 {
        return self.total_overflow_events;
    }

    pub fn lastOverflowEvents(self: *const AudioOutput) u32 {
        return self.last_overflow_events;
    }

    fn ymPortAndChannelBase(channel: u3) struct { port: u1, base: u8 } {
        return if (channel >= 3)
            .{ .port = 1, .base = @as(u8, channel - 3) }
        else
            .{ .port = 0, .base = channel };
    }

    fn ymDacEnabled(z80: *const Z80) bool {
        return (z80.getYmRegister(0, 0x2B) & 0x80) != 0;
    }

    fn ymDacByteToSample(sample: u8) f32 {
        return (@as(f32, @floatFromInt(sample)) - 128.0) / 128.0;
    }

    fn ymDacCurrentSample(z80: *const Z80) f32 {
        return ymDacByteToSample(z80.getYmRegister(0, 0x2A));
    }

    fn ntscYmNativeSampleRate() f64 {
        return @as(f64, @floatFromInt(clock.master_clock_ntsc)) /
            @as(f64, @floatFromInt(clock.fm_master_cycles_per_sample));
    }

    fn palYmNativeSampleRate() f64 {
        return @as(f64, @floatFromInt(clock.master_clock_pal)) /
            @as(f64, @floatFromInt(clock.fm_master_cycles_per_sample));
    }

    fn ntscPsgNativeSampleRate() f64 {
        return @as(f64, @floatFromInt(clock.master_clock_ntsc)) /
            @as(f64, @floatFromInt(clock.psg_master_cycles_per_sample));
    }

    fn palPsgNativeSampleRate() f64 {
        return @as(f64, @floatFromInt(clock.master_clock_pal)) /
            @as(f64, @floatFromInt(clock.psg_master_cycles_per_sample));
    }

    fn ymNativeSampleRate(is_pal: bool) f64 {
        return if (is_pal) palYmNativeSampleRate() else ntscYmNativeSampleRate();
    }

    fn psgNativeSampleRate(is_pal: bool) f64 {
        return if (is_pal) palPsgNativeSampleRate() else ntscPsgNativeSampleRate();
    }

    fn resetOutputPipeline(self: *AudioOutput, is_pal: bool, reset_psg_partial: bool) void {
        self.ym_resampler.reset(ymNativeSampleRate(is_pal), output_rate);
        self.psg_resampler.reset(psgNativeSampleRate(is_pal), output_rate);
        const psg_rate = psgNativeSampleRate(is_pal);
        self.psg_native_lpf_l = FirstOrderLpf.init(psg_native_cutoff_hz, psg_rate);
        self.psg_native_lpf_r = FirstOrderLpf.init(psg_native_cutoff_hz, psg_rate);
        self.dc_left = DcBlocker.init(output_rate);
        self.dc_right = DcBlocker.init(output_rate);
        self.board_lpf = BoardOutputLpf.init();
        self.resetBlip(is_pal);
        self.eq_left.resetState();
        self.eq_right.resetState();
        self.last_ym_resampled_left = 0.0;
        self.last_ym_resampled_right = 0.0;
        self.last_psg_resampled_left = 0.0;
        self.last_psg_resampled_right = 0.0;
        self.last_psg_filtered_left = 0.0;
        self.last_psg_filtered_right = 0.0;
        if (reset_psg_partial) {
            self.psg_partial_master_cycles = 0;
            self.psg_partial_sum_left = 0;
            self.psg_partial_sum_right = 0;
        }
    }

    pub fn dropQueuedOutput(self: *AudioOutput, is_pal: bool) void {
        self.resetOutputPipeline(is_pal, false);
    }

    fn repairPreparedOutputIfCorrupt(self: *AudioOutput) bool {
        if (self.ym_resampler.hasValidState() and self.psg_resampler.hasValidState()) return false;
        self.dropQueuedOutput(self.timing_is_pal);
        return true;
    }

    fn pushFilteredPsgNativeSample(self: *AudioOutput, sample: PsgStereoSample) void {
        const normalized_l = @as(f32, @floatFromInt(sample.left)) / 32768.0;
        const normalized_r = @as(f32, @floatFromInt(sample.right)) / 32768.0;
        const filtered_l = self.psg_native_lpf_l.process(normalized_l);
        const filtered_r = self.psg_native_lpf_r.process(normalized_r);
        self.last_psg_filtered_left = filtered_l;
        self.last_psg_filtered_right = filtered_r;
        self.psg_resampler.collectSample(.{ filtered_l, filtered_r });
    }

    fn nativeFramesBeforeMaster(start_remainder: u16, master_offset: u32, master_cycles_per_sample: u16) u32 {
        return (@as(u32, start_remainder) + master_offset) / master_cycles_per_sample;
    }

    fn fmFramesBeforeMaster(pending: PendingAudioFrames, master_offset: u32) u32 {
        return nativeFramesBeforeMaster(
            pending.fm_start_remainder,
            @min(master_offset, pending.master_cycles),
            clock.fm_master_cycles_per_sample,
        );
    }

    fn psgFramesBeforeMaster(pending: PendingAudioFrames, master_offset: u32) u32 {
        return nativeFramesBeforeMaster(
            pending.psg_start_remainder,
            @min(master_offset, pending.master_cycles),
            clock.psg_master_cycles_per_sample,
        );
    }

    fn outputFrameToMaster(pending: PendingAudioFrames, frame: u32, total_frames: u32) u32 {
        if (pending.master_cycles == 0 or total_frames == 0) return 0;
        return @intCast((@as(u64, frame) * pending.master_cycles) / total_frames);
    }

    fn applyYmWriteEvent(self: *AudioOutput, event: YmWriteEvent) void {
        self.ym_synth.applyWrite(event);
    }

    fn isYmDacDataWrite(event: YmWriteEvent) bool {
        return (event.port & 0x01) == 0 and event.reg == 0x2A;
    }

    fn applyYmDacSampleEvent(self: *AudioOutput, event: YmDacSampleEvent) void {
        self.applyYmWriteEvent(.{
            .master_offset = event.master_offset,
            .sequence = event.sequence,
            .port = 0,
            .reg = 0x2A,
            .value = event.value,
        });
    }

    fn ymEventOrderLessThan(a: YmEventOrder, b: YmEventOrder) bool {
        if (a.master_offset != b.master_offset) return a.master_offset < b.master_offset;
        return a.sequence < b.sequence;
    }

    fn ymWriteOrder(event: YmWriteEvent) YmEventOrder {
        return .{
            .master_offset = event.master_offset,
            .sequence = event.sequence,
        };
    }

    fn ymDacOrder(event: YmDacSampleEvent) YmEventOrder {
        return .{
            .master_offset = event.master_offset,
            .sequence = event.sequence,
        };
    }

    fn ymResetOrder(event: YmResetEvent) YmEventOrder {
        return .{
            .master_offset = event.master_offset,
            .sequence = event.sequence,
        };
    }

    fn nextYmEventKind(
        ym_writes: []const YmWriteEvent,
        ym_write_cursor: usize,
        ym_dac_samples: []const YmDacSampleEvent,
        ym_dac_cursor: usize,
        ym_reset_events: []const YmResetEvent,
        ym_reset_cursor: usize,
    ) ?YmEventKind {
        var best_kind: ?YmEventKind = null;
        var best_order: YmEventOrder = undefined;

        if (ym_write_cursor < ym_writes.len) {
            best_kind = .write;
            best_order = ymWriteOrder(ym_writes[ym_write_cursor]);
        }
        if (ym_dac_cursor < ym_dac_samples.len) {
            const order = ymDacOrder(ym_dac_samples[ym_dac_cursor]);
            if (best_kind == null or ymEventOrderLessThan(order, best_order)) {
                best_kind = .dac;
                best_order = order;
            }
        }
        if (ym_reset_cursor < ym_reset_events.len) {
            const order = ymResetOrder(ym_reset_events[ym_reset_cursor]);
            if (best_kind == null or ymEventOrderLessThan(order, best_order)) {
                best_kind = .reset;
                best_order = order;
            }
        }

        return best_kind;
    }

    fn currentYmEventOrder(
        kind: YmEventKind,
        ym_writes: []const YmWriteEvent,
        ym_write_cursor: usize,
        ym_dac_samples: []const YmDacSampleEvent,
        ym_dac_cursor: usize,
        ym_reset_events: []const YmResetEvent,
        ym_reset_cursor: usize,
    ) YmEventOrder {
        return switch (kind) {
            .write => ymWriteOrder(ym_writes[ym_write_cursor]),
            .dac => ymDacOrder(ym_dac_samples[ym_dac_cursor]),
            .reset => ymResetOrder(ym_reset_events[ym_reset_cursor]),
        };
    }

    fn applyNextYmEvent(
        self: *AudioOutput,
        kind: YmEventKind,
        ym_writes: []const YmWriteEvent,
        ym_write_cursor: *usize,
        ym_dac_samples: []const YmDacSampleEvent,
        ym_dac_cursor: *usize,
        ym_reset_cursor: *usize,
    ) void {
        switch (kind) {
            .write => {
                self.applyYmWriteEvent(ym_writes[ym_write_cursor.*]);
                ym_write_cursor.* += 1;
            },
            .dac => {
                self.applyYmDacSampleEvent(ym_dac_samples[ym_dac_cursor.*]);
                ym_dac_cursor.* += 1;
            },
            .reset => {
                self.resetYmRenderState();
                ym_reset_cursor.* += 1;
            },
        }
    }

    fn applyRemainingYmEvents(
        self: *AudioOutput,
        ym_writes: []const YmWriteEvent,
        ym_write_cursor: *usize,
        ym_dac_samples: []const YmDacSampleEvent,
        ym_dac_cursor: *usize,
        ym_reset_events: []const YmResetEvent,
        ym_reset_cursor: *usize,
    ) void {
        while (nextYmEventKind(
            ym_writes,
            ym_write_cursor.*,
            ym_dac_samples,
            ym_dac_cursor.*,
            ym_reset_events,
            ym_reset_cursor.*,
        )) |kind| {
            self.applyNextYmEvent(
                kind,
                ym_writes,
                ym_write_cursor,
                ym_dac_samples,
                ym_dac_cursor,
                ym_reset_cursor,
            );
        }
    }

    fn fmFrequencyFromChannel(z80: *const Z80, channel: u3) f32 {
        const mapping = ymPortAndChannelBase(channel);
        const fnum_low = z80.getYmRegister(mapping.port, 0xA0 + mapping.base);
        const high = z80.getYmRegister(mapping.port, 0xA4 + mapping.base);
        const block = (high >> 3) & 0x07;
        const fnum_high = high & 0x07;
        const fnum: u16 = (@as(u16, fnum_high) << 8) | @as(u16, fnum_low);
        if (fnum == 0) return 0.0;

        const base_hz = 0.052_7 * @as(f32, @floatFromInt(fnum));
        return base_hz * @as(f32, @floatFromInt(@as(u32, 1) << @intCast(block)));
    }

    fn resetYmRenderState(self: *AudioOutput) void {
        self.ym_synth.resetChipState();
        self.ym_synth.setTimingMode(self.timing_is_pal);
    }

    fn clockYmInternal(self: *AudioOutput, produced_count: *usize, collect_resampled: bool) void {
        const pins = self.ym_synth.clockOneInternal();
        self.ym_partial_sum_left += pins[0];
        self.ym_partial_sum_right += pins[1];
        self.ym_partial_internal_clocks += 1;

        if (self.ym_partial_internal_clocks == ym_internal_clocks_per_sample) {
            const sample = self.ym_synth.finishAccumulatedSample(
                self.ym_partial_sum_left,
                self.ym_partial_sum_right,
            );
            // Bounds check instead of assert to avoid panic
            if (produced_count.* >= self.ym_native_buffer.len) return;
            self.ym_native_buffer[produced_count.*] = sample;
            self.last_ym_left = sample.left;
            self.last_ym_right = sample.right;
            if (collect_resampled) {
                self.ym_resampler.collectSample(.{ sample.left, sample.right });
            }
            produced_count.* += 1;
            self.ym_partial_sum_left = 0;
            self.ym_partial_sum_right = 0;
            self.ym_partial_internal_clocks = 0;
        }
    }

    fn advanceYmMaster(self: *AudioOutput, master_cycles: u32, produced_count: *usize, collect_resampled: bool) void {
        var remaining = master_cycles;
        while (remaining != 0) {
            const until_boundary: u32 = if (self.ym_internal_master_remainder == 0)
                ym_internal_master_cycles
            else
                ym_internal_master_cycles - self.ym_internal_master_remainder;

            if (remaining < until_boundary) {
                self.ym_internal_master_remainder = @intCast(@as(u32, self.ym_internal_master_remainder) + remaining);
                return;
            }

            remaining -= until_boundary;
            self.ym_internal_master_remainder = 0;
            self.clockYmInternal(produced_count, collect_resampled);
        }
    }

    fn generateYmNativeSamples(
        self: *AudioOutput,
        master_start: u32,
        master_cycles: u32,
        ym_writes: []const YmWriteEvent,
        ym_dac_samples: []const YmDacSampleEvent,
        ym_reset_events: []const YmResetEvent,
        collect_resampled: bool,
    ) YmGenerationResult {
        const master_end = master_start + master_cycles;
        var produced_count: usize = 0;
        var master_cursor = master_start;
        var ym_write_cursor: usize = 0;
        var ym_dac_cursor: usize = 0;
        var ym_reset_cursor: usize = 0;

        while (master_cursor < master_end) {
            const next_kind = nextYmEventKind(
                ym_writes,
                ym_write_cursor,
                ym_dac_samples,
                ym_dac_cursor,
                ym_reset_events,
                ym_reset_cursor,
            ) orelse {
                self.advanceYmMaster(master_end - master_cursor, &produced_count, collect_resampled);
                break;
            };
            const next_order = currentYmEventOrder(
                next_kind,
                ym_writes,
                ym_write_cursor,
                ym_dac_samples,
                ym_dac_cursor,
                ym_reset_events,
                ym_reset_cursor,
            );

            if (next_order.master_offset >= master_end) {
                self.advanceYmMaster(master_end - master_cursor, &produced_count, collect_resampled);
                break;
            }

            if (next_order.master_offset > master_cursor) {
                self.advanceYmMaster(next_order.master_offset - master_cursor, &produced_count, collect_resampled);
                master_cursor = next_order.master_offset;
            }

            self.applyNextYmEvent(
                next_kind,
                ym_writes,
                &ym_write_cursor,
                ym_dac_samples,
                &ym_dac_cursor,
                &ym_reset_cursor,
            );
        }

        return .{
            .produced_count = produced_count,
            .ym_write_cursor = ym_write_cursor,
            .ym_dac_cursor = ym_dac_cursor,
            .ym_reset_cursor = ym_reset_cursor,
        };
    }

    fn generatePsgNativeSamples(
        self: *AudioOutput,
        pending: PendingAudioFrames,
        psg_commands: []const PsgCommandEvent,
    ) ?usize {
        // Check invariant instead of asserting - return null on mismatch
        if (self.psg_partial_master_cycles != pending.psg_start_remainder) return null;

        const sample_master_cycles: u32 = clock.psg_master_cycles_per_sample;
        var produced_count: usize = 0;
        var master_cursor: u32 = 0;
        var psg_cmd_cursor: usize = 0;

        while (master_cursor < pending.master_cycles) {
            if (self.psg_partial_master_cycles == 0) {
                while (psg_cmd_cursor < psg_commands.len and psg_commands[psg_cmd_cursor].master_offset <= master_cursor) : (psg_cmd_cursor += 1) {
                    self.psg.doCommand(psg_commands[psg_cmd_cursor].value);
                }
                self.psg.advanceOneSample();
            } else {
                while (psg_cmd_cursor < psg_commands.len and psg_commands[psg_cmd_cursor].master_offset <= master_cursor) : (psg_cmd_cursor += 1) {
                    self.psg.doCommand(psg_commands[psg_cmd_cursor].value);
                }
            }

            const next_command_master = if (psg_cmd_cursor < psg_commands.len)
                @min(pending.master_cycles, psg_commands[psg_cmd_cursor].master_offset)
            else
                pending.master_cycles;
            const until_sample_end = sample_master_cycles - self.psg_partial_master_cycles;
            const next_sample_master = master_cursor + until_sample_end;
            const segment_end = @min(next_command_master, @min(next_sample_master, pending.master_cycles));
            const segment_master_cycles = segment_end - master_cursor;

            // Break loop instead of asserting on zero segment
            if (segment_master_cycles == 0) break;
            const current_sample = self.psg.currentStereoSample();
            const segment_weight: i64 = @intCast(segment_master_cycles);
            self.psg_partial_sum_left += @as(i64, current_sample.left) * segment_weight;
            self.psg_partial_sum_right += @as(i64, current_sample.right) * segment_weight;
            self.psg_partial_master_cycles += @intCast(segment_master_cycles);
            master_cursor = segment_end;

            if (self.psg_partial_master_cycles == sample_master_cycles) {
                self.last_psg_sample_left = @intCast(@divFloor(self.psg_partial_sum_left + @divTrunc(sample_master_cycles, 2), sample_master_cycles));
                self.last_psg_sample_right = @intCast(@divFloor(self.psg_partial_sum_right + @divTrunc(sample_master_cycles, 2), sample_master_cycles));
                self.pushFilteredPsgNativeSample(.{ .left = self.last_psg_sample_left, .right = self.last_psg_sample_right });
                produced_count += 1;
                self.psg_partial_master_cycles = 0;
                self.psg_partial_sum_left = 0;
                self.psg_partial_sum_right = 0;
            }

            if (self.psg_partial_master_cycles != 0) {
                while (psg_cmd_cursor < psg_commands.len and psg_commands[psg_cmd_cursor].master_offset <= master_cursor) : (psg_cmd_cursor += 1) {
                    self.psg.doCommand(psg_commands[psg_cmd_cursor].value);
                }
            }
        }

        while (psg_cmd_cursor < psg_commands.len) : (psg_cmd_cursor += 1) {
            self.psg.doCommand(psg_commands[psg_cmd_cursor].value);
        }

        return produced_count;
    }

    fn popMixedFrames(self: *AudioOutput, frames: usize) []const i16 {
        for (0..frames) |i| {
            const ym = if (self.ym_resampler.outputBufferPopFront()) |sample| blk: {
                self.last_ym_resampled_left = sample[0];
                self.last_ym_resampled_right = sample[1];
                break :blk sample;
            } else .{ self.last_ym_resampled_left, self.last_ym_resampled_right };
            const psg_raw = if (self.psg_resampler.outputBufferPopFront()) |sample| blk: {
                self.last_psg_resampled_left = sample[0];
                self.last_psg_resampled_right = sample[1];
                break :blk sample;
            } else .{ self.last_psg_resampled_left, self.last_psg_resampled_right };
            const psg = self.postPsgSampleStereo(psg_raw);

            const mixed = self.mixSources(ym, psg);
            const finished = self.finishMixedFrame(mixed[0], mixed[1]);
            self.sample_chunk[i * channels] = finished[0];
            self.sample_chunk[i * channels + 1] = finished[1];
        }

        return self.sample_chunk[0 .. frames * channels];
    }

    fn applyPsgCommandsAtFrame(self: *AudioOutput, pending: PendingAudioFrames, psg_commands: []const PsgCommandEvent, psg_cmd_cursor: *usize, frame: u32) void {
        while (psg_cmd_cursor.* < psg_commands.len and psgFramesBeforeMaster(pending, psg_commands[psg_cmd_cursor.*].master_offset) <= frame) : (psg_cmd_cursor.* += 1) {
            self.psg.doCommand(psg_commands[psg_cmd_cursor.*].value);
        }
    }

    const StereoWeightedSum = struct { left: i64, right: i64 };

    fn advancePsgMasterRange(
        self: *AudioOutput,
        psg_commands: []const PsgCommandEvent,
        psg_cmd_cursor: *usize,
        master_cursor: *u32,
        master_target: u32,
    ) StereoWeightedSum {
        const sample_master_cycles: u32 = clock.psg_master_cycles_per_sample;
        var weighted_sum_left: i64 = 0;
        var weighted_sum_right: i64 = 0;

        while (master_cursor.* < master_target) {
            if (self.psg_partial_master_cycles == 0) {
                while (psg_cmd_cursor.* < psg_commands.len and psg_commands[psg_cmd_cursor.*].master_offset <= master_cursor.*) : (psg_cmd_cursor.* += 1) {
                    self.psg.doCommand(psg_commands[psg_cmd_cursor.*].value);
                }
                self.psg.advanceOneSample();
            } else {
                while (psg_cmd_cursor.* < psg_commands.len and psg_commands[psg_cmd_cursor.*].master_offset <= master_cursor.*) : (psg_cmd_cursor.* += 1) {
                    self.psg.doCommand(psg_commands[psg_cmd_cursor.*].value);
                }
            }

            const next_command_master = if (psg_cmd_cursor.* < psg_commands.len)
                @min(master_target, psg_commands[psg_cmd_cursor.*].master_offset)
            else
                master_target;
            const until_sample_end = sample_master_cycles - self.psg_partial_master_cycles;
            const segment_end = @min(master_target, @min(next_command_master, master_cursor.* + until_sample_end));
            const segment_master_cycles = segment_end - master_cursor.*;

            // Break loop instead of asserting on zero segment
            if (segment_master_cycles == 0) break;
            const current_sample = self.psg.currentStereoSample();
            const segment_weight: i64 = @intCast(segment_master_cycles);
            const weighted_segment_left = @as(i64, current_sample.left) * segment_weight;
            const weighted_segment_right = @as(i64, current_sample.right) * segment_weight;
            weighted_sum_left += weighted_segment_left;
            weighted_sum_right += weighted_segment_right;
            self.psg_partial_sum_left += weighted_segment_left;
            self.psg_partial_sum_right += weighted_segment_right;
            self.psg_partial_master_cycles += @intCast(segment_master_cycles);
            master_cursor.* = segment_end;

            if (self.psg_partial_master_cycles == sample_master_cycles) {
                self.last_psg_sample_left = @intCast(@divFloor(self.psg_partial_sum_left + @divTrunc(sample_master_cycles, 2), sample_master_cycles));
                self.last_psg_sample_right = @intCast(@divFloor(self.psg_partial_sum_right + @divTrunc(sample_master_cycles, 2), sample_master_cycles));
                self.psg_partial_master_cycles = 0;
                self.psg_partial_sum_left = 0;
                self.psg_partial_sum_right = 0;
            }

            if (self.psg_partial_master_cycles != 0) {
                while (psg_cmd_cursor.* < psg_commands.len and psg_commands[psg_cmd_cursor.*].master_offset <= master_cursor.*) : (psg_cmd_cursor.* += 1) {
                    self.psg.doCommand(psg_commands[psg_cmd_cursor.*].value);
                }
            }
        }

        return .{ .left = weighted_sum_left, .right = weighted_sum_right };
    }

    fn renderChunk(
        self: *AudioOutput,
        pending: PendingAudioFrames,
        master_start: u32,
        master_cycles: u32,
        output_frame_start: u32,
        total_output_frames: u32,
        frames: usize,
        ym_writes: []const YmWriteEvent,
        ym_dac_samples: []const YmDacSampleEvent,
        ym_reset_events: []const YmResetEvent,
        psg_commands: []const PsgCommandEvent,
    ) []const i16 {
        const master_end = @min(pending.master_cycles, master_start + master_cycles);
        const expected_ym_native_frames = fmFramesBeforeMaster(pending, master_end) - fmFramesBeforeMaster(pending, master_start);
        const ym_generation = self.generateYmNativeSamples(
            master_start,
            master_end - master_start,
            ym_writes,
            ym_dac_samples,
            ym_reset_events,
            false,
        );
        const ym_native_frames = ym_generation.produced_count;

        // Skip processing if frame count mismatch (return silence)
        if (ym_native_frames != expected_ym_native_frames) {
            @memset(self.sample_chunk[0 .. frames * channels], 0);
            return self.sample_chunk[0 .. frames * channels];
        }

        if (master_start == 0 and self.psg_partial_master_cycles == 0 and pending.psg_start_remainder != 0) {
            self.psg.advanceOneSample();
            self.psg_partial_master_cycles = pending.psg_start_remainder;
            const init_sample = self.psg.currentStereoSample();
            const init_weight: i64 = @intCast(pending.psg_start_remainder);
            self.psg_partial_sum_left = @as(i64, init_sample.left) * init_weight;
            self.psg_partial_sum_right = @as(i64, init_sample.right) * init_weight;
            self.last_psg_sample_left = init_sample.left;
            self.last_psg_sample_right = init_sample.right;
        }

        var psg_master_cursor: u32 = master_start;
        var last_psg_sample_left = self.last_psg_sample_left;
        var last_psg_sample_right = self.last_psg_sample_right;
        var ym_native_cursor: usize = 0;
        var last_ym_left = self.last_ym_left;
        var last_ym_right = self.last_ym_right;
        var ym_write_cursor = ym_generation.ym_write_cursor;
        var ym_dac_cursor = ym_generation.ym_dac_cursor;
        var ym_reset_cursor = ym_generation.ym_reset_cursor;
        var psg_cmd_cursor: usize = 0;
        var i: usize = 0;
        while (i < frames) : (i += 1) {
            const global_output_frame = output_frame_start + @as(u32, @intCast(i + 1));
            const global_master_target = outputFrameToMaster(pending, global_output_frame, total_output_frames);
            const target_ym_native_abs = fmFramesBeforeMaster(pending, global_master_target);
            const target_ym_native: usize = @intCast(target_ym_native_abs - fmFramesBeforeMaster(pending, master_start));
            var l: f32 = 0.0;
            var r: f32 = 0.0;

            if (ym_native_cursor < target_ym_native) {
                const ym_start = ym_native_cursor;
                var ym_sum_left: f32 = 0.0;
                var ym_sum_right: f32 = 0.0;
                while (ym_native_cursor < target_ym_native) : (ym_native_cursor += 1) {
                    const ym_sample = self.ym_native_buffer[ym_native_cursor];
                    last_ym_left = ym_sample.left;
                    last_ym_right = ym_sample.right;
                    ym_sum_left += ym_sample.left;
                    ym_sum_right += ym_sample.right;
                }

                const ym_samples_to_mix = target_ym_native - ym_start;
                l += ym_sum_left / @as(f32, @floatFromInt(ym_samples_to_mix));
                r += ym_sum_right / @as(f32, @floatFromInt(ym_samples_to_mix));
            } else {
                l += last_ym_left;
                r += last_ym_right;
            }

            var psg_sample: [2]f32 = .{ 0.0, 0.0 };
            if (psg_master_cursor < global_master_target) {
                const weighted_sum = self.advancePsgMasterRange(
                    psg_commands,
                    &psg_cmd_cursor,
                    &psg_master_cursor,
                    global_master_target,
                );
                const master_cycles_to_mix = global_master_target - outputFrameToMaster(pending, output_frame_start + @as(u32, @intCast(i)), total_output_frames);
                if (master_cycles_to_mix == 0) {
                    psg_sample[0] = @as(f32, @floatFromInt(last_psg_sample_left)) / 32768.0;
                    psg_sample[1] = @as(f32, @floatFromInt(last_psg_sample_right)) / 32768.0;
                } else {
                    const cycles_f: f32 = @floatFromInt(master_cycles_to_mix);
                    psg_sample[0] = @as(f32, @floatFromInt(weighted_sum.left)) / cycles_f / 32768.0;
                    psg_sample[1] = @as(f32, @floatFromInt(weighted_sum.right)) / cycles_f / 32768.0;
                }
                last_psg_sample_left = self.last_psg_sample_left;
                last_psg_sample_right = self.last_psg_sample_right;
            } else {
                psg_sample[0] = @as(f32, @floatFromInt(last_psg_sample_left)) / 32768.0;
                psg_sample[1] = @as(f32, @floatFromInt(last_psg_sample_right)) / 32768.0;
            }
            psg_sample = self.postPsgSampleStereo(psg_sample);
            const mixed = self.mixSources(.{ l, r }, psg_sample);
            const finished = self.finishMixedFrame(mixed[0], mixed[1]);
            self.sample_chunk[i * channels] = finished[0];
            self.sample_chunk[i * channels + 1] = finished[1];
        }

        while (psg_cmd_cursor < psg_commands.len) : (psg_cmd_cursor += 1) {
            self.psg.doCommand(psg_commands[psg_cmd_cursor].value);
        }
        self.applyRemainingYmEvents(
            ym_writes,
            &ym_write_cursor,
            ym_dac_samples,
            &ym_dac_cursor,
            ym_reset_events,
            &ym_reset_cursor,
        );

        self.last_ym_left = last_ym_left;
        self.last_ym_right = last_ym_right;
        self.last_psg_sample_left = last_psg_sample_left;
        self.last_psg_sample_right = last_psg_sample_right;

        return self.sample_chunk[0 .. frames * channels];
    }

    fn postPsgSample(self: *AudioOutput, sample: f32) f32 {
        _ = self;
        // The Mega Drive path relies on band-limited PSG generation plus the final board filter.
        return sample;
    }

    fn postPsgSampleStereo(self: *AudioOutput, sample: [2]f32) [2]f32 {
        _ = self;
        // The Mega Drive path relies on band-limited PSG generation plus the final board filter.
        return sample;
    }

    fn runtimePsgMixGain(self: *const AudioOutput) f32 {
        return psg_base_mix_gain * (@as(f32, @floatFromInt(self.psg_volume_percent)) / fm_preamp_percent);
    }

    pub fn setPsgVolume(self: *AudioOutput, percent: u8) void {
        self.psg_volume_percent = @min(percent, 200);
    }

    fn mixSources(self: *const AudioOutput, ym: [2]f32, psg: [2]f32) [2]f32 {
        var l: f32 = 0.0;
        var r: f32 = 0.0;

        if (self.render_mode != .psg_only) {
            l += ym[0];
            r += ym[1];
        }

        if (self.render_mode != .ym_only) {
            const gain = self.runtimePsgMixGain();
            l += psg[0] * gain;
            r += psg[1] * gain;
        }

        return .{ l, r };
    }

    fn finishMixedFrame(self: *AudioOutput, left: f32, right: f32) [2]i16 {
        var l = left;
        var r = right;

        // Always apply DC blocking — the blip buffer inherently removes DC
        // even when the board low-pass is disabled. Without this, PSG's unipolar
        // output creates a massive positive DC offset (~2400 LSB in unfiltered mode).
        l = self.dc_left.process(l);
        r = self.dc_right.process(r);

        if (self.render_mode != .unfiltered_mix) {
            l = self.board_lpf.processL(l);
            r = self.board_lpf.processR(r);
        }

        if (self.eq_enabled) {
            // EQ operates on i16-range values scaled to [-32768, 32767].
            // Convert from [-1, 1] float, process, then convert back.
            l = @floatCast(self.eq_left.process(@as(f64, l) * 32768.0) / 32768.0);
            r = @floatCast(self.eq_right.process(@as(f64, r) * 32768.0) / 32768.0);
        }

        l = softSaturate(l);
        r = softSaturate(r);
        return .{
            @as(i16, @intFromFloat(l * 32767.0)),
            @as(i16, @intFromFloat(r * 32767.0)),
        };
    }

    fn advanceWindowWithoutOutput(
        self: *AudioOutput,
        pending: PendingAudioFrames,
        ym_writes: []const YmWriteEvent,
        ym_dac_samples: []const YmDacSampleEvent,
        ym_reset_events: []const YmResetEvent,
        psg_commands: []const PsgCommandEvent,
    ) void {
        const ym_generation = self.generateYmNativeSamples(
            0,
            pending.master_cycles,
            ym_writes,
            ym_dac_samples,
            ym_reset_events,
            false,
        );
        const ym_native_frames = ym_generation.produced_count;
        if (ym_native_frames != 0) {
            const last = self.ym_native_buffer[ym_native_frames - 1];
            self.last_ym_left = last.left;
            self.last_ym_right = last.right;
        }

        var psg_cmd_cursor: usize = 0;
        var psg_native_cursor: u32 = 0;
        while (psg_native_cursor < pending.psg_frames) {
            self.applyPsgCommandsAtFrame(pending, psg_commands, &psg_cmd_cursor, psg_native_cursor);
            const next_psg_command_frame = if (psg_cmd_cursor < psg_commands.len)
                @min(pending.psg_frames, psgFramesBeforeMaster(pending, psg_commands[psg_cmd_cursor].master_offset))
            else
                pending.psg_frames;

            if (next_psg_command_frame == psg_native_cursor) {
                self.applyPsgCommandsAtFrame(pending, psg_commands, &psg_cmd_cursor, psg_native_cursor);
                continue;
            }

            while (psg_native_cursor < next_psg_command_frame) : (psg_native_cursor += 1) {
                const sample = self.psg.nextStereoSample();
                self.last_psg_sample_left = sample.left;
                self.last_psg_sample_right = sample.right;
            }
        }
        self.applyPsgCommandsAtFrame(pending, psg_commands, &psg_cmd_cursor, std.math.maxInt(u32));
        var ym_write_cursor = ym_generation.ym_write_cursor;
        var ym_dac_cursor = ym_generation.ym_dac_cursor;
        var ym_reset_cursor = ym_generation.ym_reset_cursor;
        self.applyRemainingYmEvents(
            ym_writes,
            &ym_write_cursor,
            ym_dac_samples,
            &ym_dac_cursor,
            ym_reset_events,
            &ym_reset_cursor,
        );
    }

    fn collectPendingNativeSamples(
        self: *AudioOutput,
        pending: PendingAudioFrames,
        ym_writes: []const YmWriteEvent,
        ym_dac_samples: []const YmDacSampleEvent,
        ym_reset_events: []const YmResetEvent,
        psg_commands: []const PsgCommandEvent,
    ) bool {
        const ym_generation = self.generateYmNativeSamples(
            0,
            pending.master_cycles,
            ym_writes,
            ym_dac_samples,
            ym_reset_events,
            true,
        );
        const psg_native_frames = self.generatePsgNativeSamples(pending, psg_commands) orelse return false;

        // Verify sample counts match expectations - return false on mismatch to trigger recovery
        if (ym_generation.produced_count != pending.fm_frames or psg_native_frames != pending.psg_frames) {
            return false;
        }

        var ym_write_cursor = ym_generation.ym_write_cursor;
        var ym_dac_cursor = ym_generation.ym_dac_cursor;
        var ym_reset_cursor = ym_generation.ym_reset_cursor;
        self.applyRemainingYmEvents(
            ym_writes,
            &ym_write_cursor,
            ym_dac_samples,
            &ym_dac_cursor,
            ym_reset_events,
            &ym_reset_cursor,
        );
        return true;
    }

    fn pendingOutputFrames(self: *AudioOutput) u32 {
        // Check resampler validity first, before any arithmetic
        if (!self.ym_resampler.hasValidState() or !self.psg_resampler.hasValidState()) {
            self.dropQueuedOutput(self.timing_is_pal);
            return 0;
        }

        const ym_len = self.ym_resampler.outputBufferLen();
        const psg_len = self.psg_resampler.outputBufferLen();
        const max_len = @max(ym_len, psg_len);

        // Use std.math.cast for safe conversion - returns null if value doesn't fit in u32.
        // This handles cases where state corruption causes impossibly large values.
        return std.math.cast(u32, max_len) orelse blk: {
            self.dropQueuedOutput(self.timing_is_pal);
            break :blk 0;
        };
    }

    fn previewOutputFramesForPending(self: *const AudioOutput, pending: PendingAudioFrames) u32 {
        var fm_converter = self.fm_converter;
        var psg_converter = self.psg_converter;
        const fm_frames = fm_converter.toOutputFrames(pending.fm_frames, output_rate);
        const psg_frames = psg_converter.toOutputFrames(pending.psg_frames, output_rate);
        return @max(fm_frames, psg_frames);
    }

    fn takeOutputFramesForPending(self: *AudioOutput, pending: PendingAudioFrames) u32 {
        const fm_frames = self.fm_converter.toOutputFrames(pending.fm_frames, output_rate);
        const psg_frames = self.psg_converter.toOutputFrames(pending.psg_frames, output_rate);
        return @max(fm_frames, psg_frames);
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
        self.ym_synth.setTimingMode(is_pal);
        self.resetOutputPipeline(is_pal, true);
    }

    pub fn setRenderMode(self: *AudioOutput, mode: RenderMode) void {
        self.render_mode = mode;
    }

    pub fn setEqEnabled(self: *AudioOutput, enabled: bool) void {
        self.eq_enabled = enabled;
        if (!enabled) {
            self.eq_left.resetState();
            self.eq_right.resetState();
        }
    }

    pub fn setEqGains(self: *AudioOutput, low: f64, mid: f64, high: f64) void {
        self.eq_left.setGains(low, mid, high);
        self.eq_right.setGains(low, mid, high);
    }

    fn resetBlip(self: *AudioOutput, is_pal: bool) void {
        const master_clock: f64 = if (is_pal)
            @as(f64, @floatFromInt(clock.master_clock_pal))
        else
            @as(f64, @floatFromInt(clock.master_clock_ntsc));
        self.blip.clear();
        self.blip.setRates(master_clock, output_rate_f);
        self.blip_fm_last_left = 0;
        self.blip_fm_last_right = 0;
        self.blip_psg_last_left = 0;
        self.blip_psg_last_right = 0;
    }

    pub fn reset(self: *AudioOutput) void {
        const render_mode = self.render_mode;
        const psg_vol = self.psg_volume_percent;
        const timing_is_pal = self.timing_is_pal;
        const eq_en = self.eq_enabled;
        const eq_lg = self.eq_left.lg;
        const eq_mg = self.eq_left.mg;
        const eq_hg = self.eq_left.hg;
        self.* = .{};
        self.psg = Psg.powerOn();
        self.render_mode = render_mode;
        self.psg_volume_percent = psg_vol;
        self.eq_enabled = eq_en;
        self.setEqGains(eq_lg, eq_mg, eq_hg);
        if (timing_is_pal) {
            self.setTimingMode(true);
        }
    }

    fn takePendingEvents(self: *AudioOutput, z80: *Z80) PendingAudioEvents {
        const overflow = z80.takeOverflowCounts();
        self.last_overflow_events = overflow;
        if (overflow > 0) {
            self.total_overflow_events += overflow;
            log.warn("audio event buffer overflow: {d} events dropped", .{overflow});
        }
        const ym_write_count = z80.takeYmWrites(self.ym_write_buffer[0..]);
        const ym_dac_count = z80.takeYmDacSamples(self.ym_dac_buffer[0..]);
        const ym_reset_count = z80.takeYmResets(self.ym_reset_buffer[0..]);
        const psg_command_count = z80.takePsgCommands(self.psg_command_buffer[0..]);
        return .{
            .ym_writes = self.ym_write_buffer[0..ym_write_count],
            .ym_dac_samples = self.ym_dac_buffer[0..ym_dac_count],
            .ym_reset_events = self.ym_reset_buffer[0..ym_reset_count],
            .psg_commands = self.psg_command_buffer[0..psg_command_count],
        };
    }

    fn preparePending(self: *AudioOutput, pending: PendingAudioFrames, z80: *Z80, is_pal: bool) u32 {
        self.setTimingMode(is_pal);
        _ = self.repairPreparedOutputIfCorrupt();

        const events = self.takePendingEvents(z80);
        const collect_ok = self.collectPendingNativeSamples(
            pending,
            events.ym_writes,
            events.ym_dac_samples,
            events.ym_reset_events,
            events.psg_commands,
        );
        // If sample collection failed (count mismatch), reset and return 0
        if (!collect_ok) {
            self.dropQueuedOutput(is_pal);
            return 0;
        }
        if (self.repairPreparedOutputIfCorrupt()) return 0;
        return self.pendingOutputFrames();
    }

    fn drainPreparedOutput(self: *AudioOutput, out_frames: u32, sink: anytype) !void {
        var remaining = out_frames;
        const max_frames_per_push = self.sample_chunk.len / channels;
        while (remaining != 0) {
            const chunk_frames: usize = @min(@as(usize, @intCast(remaining)), max_frames_per_push);
            try sink.consumeSamples(self.popMixedFrames(chunk_frames));
            remaining -= @as(u32, @intCast(chunk_frames));
        }
    }

    // Blip buffer integer scaling: FM float [-1,1] maps to [-21000,21000].
    // PSG i16 is scaled by (psg_mix_gain * 21000 / 32768) ≈ 0.328.
    // The combined peak is ~21000 + ~5500 = ~26500, safely within i16 range.
    const blip_fm_scale: f32 = 21000.0;
    const blip_psg_scale: f32 = blip_fm_scale * psg_base_mix_gain;

    fn blipPsgScaleForVolume(self: *const AudioOutput) f32 {
        return blip_fm_scale * psg_base_mix_gain * (@as(f32, @floatFromInt(self.psg_volume_percent)) / fm_preamp_percent);
    }

    fn feedYmNativeSamplesToBlip(
        self: *AudioOutput,
        pending: PendingAudioFrames,
        ym_writes: []const YmWriteEvent,
        ym_dac_samples: []const YmDacSampleEvent,
        ym_reset_events: []const YmResetEvent,
    ) void {
        const ym_generation = self.generateYmNativeSamples(
            0,
            pending.master_cycles,
            ym_writes,
            ym_dac_samples,
            ym_reset_events,
            false,
        );

        const fm_cycle_period: u32 = clock.fm_master_cycles_per_sample;
        for (0..ym_generation.produced_count) |i| {
            const sample = self.ym_native_buffer[i];
            const master_time: u32 = @intCast(pending.fm_start_remainder + @as(u32, @intCast(i)) * fm_cycle_period);

            var cur_l: i32 = @intFromFloat(sample.left * blip_fm_scale);
            var cur_r: i32 = @intFromFloat(sample.right * blip_fm_scale);

            if (self.render_mode == .psg_only) {
                cur_l = 0;
                cur_r = 0;
            }

            const dl = cur_l - self.blip_fm_last_left;
            const dr = cur_r - self.blip_fm_last_right;
            self.blip_fm_last_left = cur_l;
            self.blip_fm_last_right = cur_r;
            self.blip.addDelta(master_time, dl, dr);
        }
        if (ym_generation.produced_count != 0) {
            const last = self.ym_native_buffer[ym_generation.produced_count - 1];
            self.last_ym_left = last.left;
            self.last_ym_right = last.right;
        }

        var ym_write_cursor = ym_generation.ym_write_cursor;
        var ym_dac_cursor = ym_generation.ym_dac_cursor;
        var ym_reset_cursor = ym_generation.ym_reset_cursor;
        self.applyRemainingYmEvents(
            ym_writes,
            &ym_write_cursor,
            ym_dac_samples,
            &ym_dac_cursor,
            ym_reset_events,
            &ym_reset_cursor,
        );
    }

    fn feedPsgNativeSamplesToBlip(
        self: *AudioOutput,
        pending: PendingAudioFrames,
        psg_commands: []const PsgCommandEvent,
    ) void {
        const psg_scale = self.blipPsgScaleForVolume();
        const psg_cycle_period: u32 = clock.psg_master_cycles_per_sample;
        var psg_cmd_cursor: usize = 0;
        var master_cursor: u32 = 0;
        var produced: u32 = 0;

        while (produced < pending.psg_frames) {
            const master_time: u32 = pending.psg_start_remainder + produced * psg_cycle_period;

            while (psg_cmd_cursor < psg_commands.len and psg_commands[psg_cmd_cursor].master_offset <= master_cursor) : (psg_cmd_cursor += 1) {
                self.psg.doCommand(psg_commands[psg_cmd_cursor].value);
            }

            const sample = self.psg.nextStereoSample();
            self.last_psg_sample_left = sample.left;
            self.last_psg_sample_right = sample.right;

            var cur_l: i32 = 0;
            var cur_r: i32 = 0;
            if (self.render_mode != .ym_only) {
                cur_l = @intFromFloat(@as(f32, @floatFromInt(sample.left)) / 32768.0 * psg_scale);
                cur_r = @intFromFloat(@as(f32, @floatFromInt(sample.right)) / 32768.0 * psg_scale);
            }

            const dl = cur_l - self.blip_psg_last_left;
            const dr = cur_r - self.blip_psg_last_right;
            self.blip_psg_last_left = cur_l;
            self.blip_psg_last_right = cur_r;
            self.blip.addDelta(master_time, dl, dr);

            master_cursor = master_time + psg_cycle_period;
            produced += 1;
        }

        while (psg_cmd_cursor < psg_commands.len) : (psg_cmd_cursor += 1) {
            self.psg.doCommand(psg_commands[psg_cmd_cursor].value);
        }
    }

    fn finishBlipFrame(self: *AudioOutput, sample_l: i16, sample_r: i16) [2]i16 {
        // Convert blip i16 output to float, then apply board LPF, EQ,
        // and soft saturation.  The blip buffer already applies a DC-blocking
        // high-pass, so skip the separate DcBlocker.
        var l: f32 = @as(f32, @floatFromInt(sample_l)) / 32768.0;
        var r: f32 = @as(f32, @floatFromInt(sample_r)) / 32768.0;

        if (self.render_mode != .unfiltered_mix) {
            l = self.board_lpf.processL(l);
            r = self.board_lpf.processR(r);
        }

        if (self.eq_enabled) {
            l = @floatCast(self.eq_left.process(@as(f64, l) * 32768.0) / 32768.0);
            r = @floatCast(self.eq_right.process(@as(f64, r) * 32768.0) / 32768.0);
        }

        l = softSaturate(l);
        r = softSaturate(r);
        return .{
            @as(i16, @intFromFloat(l * 32767.0)),
            @as(i16, @intFromFloat(r * 32767.0)),
        };
    }

    fn preparePendingBlip(self: *AudioOutput, pending: PendingAudioFrames, z80: *Z80, is_pal: bool) u32 {
        self.setTimingMode(is_pal);
        const events = self.takePendingEvents(z80);

        self.feedYmNativeSamplesToBlip(
            pending,
            events.ym_writes,
            events.ym_dac_samples,
            events.ym_reset_events,
        );
        self.feedPsgNativeSamplesToBlip(pending, events.psg_commands);

        self.blip.endFrame(pending.master_cycles);
        return @intCast(self.blip.samplesAvail());
    }

    fn drainBlipOutput(self: *AudioOutput, out_frames: u32, sink: anytype) !void {
        var remaining = out_frames;
        const max_frames_per_push = self.sample_chunk.len / channels;
        while (remaining != 0) {
            const chunk_frames: usize = @min(@as(usize, @intCast(remaining)), max_frames_per_push);
            var raw: [4096]i16 = undefined;
            const read = self.blip.readSamples(raw[0..], chunk_frames);
            for (0..read) |i| {
                const finished = self.finishBlipFrame(raw[i * 2], raw[i * 2 + 1]);
                self.sample_chunk[i * channels] = finished[0];
                self.sample_chunk[i * channels + 1] = finished[1];
            }
            try sink.consumeSamples(self.sample_chunk[0 .. read * channels]);
            remaining -= @as(u32, @intCast(read));
        }
    }

    pub fn renderPending(self: *AudioOutput, pending: PendingAudioFrames, z80: *Z80, is_pal: bool, sink: anytype) !void {
        const out_frames = self.preparePendingBlip(pending, z80, is_pal);
        if (out_frames == 0) return;
        try self.drainBlipOutput(out_frames, sink);
    }

    pub fn discardPending(self: *AudioOutput, pending: PendingAudioFrames, z80: *Z80, is_pal: bool) !void {
        const DiscardSink = struct {
            fn consumeSamples(_: *@This(), _: []const i16) !void {}
        };

        var sink = DiscardSink{};
        const out_frames = self.preparePendingBlip(pending, z80, is_pal);
        if (out_frames == 0) return;
        try self.drainBlipOutput(out_frames, &sink);
    }
};

/// Soft saturation using tanh-like curve to avoid harsh digital clipping.
/// This provides gentle compression near the limits instead of hard clipping,
/// which reduces harmonic distortion in loud passages.
fn softSaturate(x: f32) f32 {
    // For values within normal range, pass through unchanged
    if (x >= -0.9 and x <= 0.9) return x;
    // For values approaching limits, apply soft knee compression
    // Uses a simplified tanh approximation for efficiency
    if (x > 0) {
        const excess = x - 0.9;
        return 0.9 + 0.1 * (1.0 - @exp(-excess * 10.0));
    } else {
        const excess = -x - 0.9;
        return -0.9 - 0.1 * (1.0 - @exp(-excess * 10.0));
    }
}

fn pendingWindow(master_cycles: u32) PendingAudioFrames {
    return .{
        .master_cycles = master_cycles,
        .fm_frames = master_cycles / clock.fm_master_cycles_per_sample,
        .psg_frames = master_cycles / clock.psg_master_cycles_per_sample,
        .fm_start_remainder = 0,
        .psg_start_remainder = 0,
    };
}

fn pendingWindowWithRemainders(master_cycles: u32, fm_start_remainder: u16, psg_start_remainder: u16) PendingAudioFrames {
    return .{
        .master_cycles = master_cycles,
        .fm_frames = (@as(u32, fm_start_remainder) + master_cycles) / clock.fm_master_cycles_per_sample,
        .psg_frames = (@as(u32, psg_start_remainder) + master_cycles) / clock.psg_master_cycles_per_sample,
        .fm_start_remainder = fm_start_remainder,
        .psg_start_remainder = psg_start_remainder,
    };
}

fn renderChunkedForTest(
    output: *AudioOutput,
    pending: PendingAudioFrames,
    total_frames: u32,
    chunk_frames: []const u32,
    ym_writes: []const YmWriteEvent,
    ym_dac_samples: []const YmDacSampleEvent,
    ym_reset_events: []const YmResetEvent,
    psg_commands: []const PsgCommandEvent,
    dest: []i16,
) void {
    var out_frame_offset: u32 = 0;
    var ym_write_offset: usize = 0;
    var ym_dac_offset: usize = 0;
    var ym_reset_offset: usize = 0;
    var psg_cmd_offset: usize = 0;

    for (chunk_frames) |chunk_frame_count| {
        const chunk_out_end = out_frame_offset + chunk_frame_count;
        const chunk_master_offset = AudioOutput.outputFrameToMaster(pending, out_frame_offset, total_frames);
        const chunk_master_end = AudioOutput.outputFrameToMaster(pending, chunk_out_end, total_frames);

        var ym_write_end = ym_write_offset;
        while (ym_write_end < ym_writes.len and ym_writes[ym_write_end].master_offset < chunk_master_end) : (ym_write_end += 1) {}

        var ym_dac_end = ym_dac_offset;
        while (ym_dac_end < ym_dac_samples.len and ym_dac_samples[ym_dac_end].master_offset < chunk_master_end) : (ym_dac_end += 1) {}

        var ym_reset_end = ym_reset_offset;
        while (ym_reset_end < ym_reset_events.len and ym_reset_events[ym_reset_end].master_offset < chunk_master_end) : (ym_reset_end += 1) {}

        var psg_cmd_end = psg_cmd_offset;
        while (psg_cmd_end < psg_commands.len and psg_commands[psg_cmd_end].master_offset < chunk_master_end) : (psg_cmd_end += 1) {}

        const samples = output.renderChunk(
            pending,
            chunk_master_offset,
            chunk_master_end - chunk_master_offset,
            out_frame_offset,
            total_frames,
            chunk_frame_count,
            ym_writes[ym_write_offset..ym_write_end],
            ym_dac_samples[ym_dac_offset..ym_dac_end],
            ym_reset_events[ym_reset_offset..ym_reset_end],
            psg_commands[psg_cmd_offset..psg_cmd_end],
        );
        const sample_offset = @as(usize, @intCast(out_frame_offset)) * AudioOutput.channels;
        @memcpy(dest[sample_offset .. sample_offset + samples.len], samples);

        out_frame_offset = chunk_out_end;
        ym_write_offset = ym_write_end;
        ym_dac_offset = ym_dac_end;
        ym_reset_offset = ym_reset_end;
        psg_cmd_offset = psg_cmd_end;
    }
}

fn expectSamplesClose(expected: []const i16, actual: []const i16, max_abs_diff: i16) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual, 0..) |lhs, rhs, index| {
        const diff = @abs(@as(i32, lhs) - @as(i32, rhs));
        if (diff > max_abs_diff) {
            std.debug.print("sample mismatch at {d}: expected {d}, found {d}, diff {d}\n", .{ index, lhs, rhs, diff });
            return error.TestExpectedEqual;
        }
    }
}

fn sampleEnergy(samples: []const i16) u64 {
    var total: u64 = 0;
    for (samples) |sample| {
        total += @intCast(@abs(sample));
    }
    return total;
}

fn channelEnergy(samples: []const i16, channel: usize) u64 {
    var total: u64 = 0;
    var index = channel;
    while (index < samples.len) : (index += AudioOutput.channels) {
        total += @intCast(@abs(samples[index]));
    }
    return total;
}

fn stereoDifferenceEnergy(samples: []const i16) u64 {
    var total: u64 = 0;
    var index: usize = 0;
    while (index + 1 < samples.len) : (index += AudioOutput.channels) {
        total += @intCast(@abs(@as(i32, samples[index]) - @as(i32, samples[index + 1])));
    }
    return total;
}

test "rate converter keeps FM/PSG aligned over one NTSC frame" {
    var output = AudioOutput{};
    const pending = PendingAudioFrames{
        .master_cycles = clock.ntsc_master_cycles_per_frame,
        .fm_frames = 888,
        .psg_frames = 3733,
        .fm_start_remainder = 0,
        .psg_start_remainder = 0,
    };

    const fm_out = output.fm_converter.toOutputFrames(pending.fm_frames, AudioOutput.output_rate);
    const psg_out = output.psg_converter.toOutputFrames(pending.psg_frames, AudioOutput.output_rate);

    try std.testing.expectEqual(@as(u32, 800), fm_out);
    try std.testing.expectEqual(@as(u32, 800), psg_out);
}

test "rate converter keeps FM/PSG aligned over one PAL frame" {
    var output = AudioOutput{};
    output.setTimingMode(true);

    const pending = PendingAudioFrames{
        .master_cycles = clock.pal_master_cycles_per_frame,
        .fm_frames = 1061,
        .psg_frames = 4460,
        .fm_start_remainder = 0,
        .psg_start_remainder = 0,
    };

    const fm_out = output.fm_converter.toOutputFrames(pending.fm_frames, AudioOutput.output_rate);
    const psg_out = output.psg_converter.toOutputFrames(pending.psg_frames, AudioOutput.output_rate);

    try std.testing.expectEqual(@as(u32, 964), fm_out);
    try std.testing.expectEqual(@as(u32, 965), psg_out);
}

test "psg native-rate rendering stays audible after downsampling" {
    var output = AudioOutput{};
    output.psg.doCommand(0x90);
    output.psg.doCommand(0x85);
    output.psg.doCommand(0x00);

    const samples = output.renderChunk(
        pendingWindow(256 * clock.psg_master_cycles_per_sample),
        0,
        256 * clock.psg_master_cycles_per_sample,
        0,
        64,
        64,
        &.{},
        &.{},
        &.{},
        &.{},
    );

    var nonzero: usize = 0;
    for (samples) |sample| {
        if (sample != 0) nonzero += 1;
    }
    try std.testing.expect(nonzero > 0);
}

test "ym dac state uses port 0 and queued writes stay audible" {
    var output = AudioOutput{};
    var z80 = Z80.init();
    defer z80.deinit();

    z80.setAudioMasterOffset(0);
    z80.writeByte(0x4000, 0x2B);
    z80.writeByte(0x4001, 0x80);
    z80.writeByte(0x4002, 0xB6);
    z80.writeByte(0x4003, 0xC0);

    z80.setAudioMasterOffset(0);
    z80.writeByte(0x4000, 0x2A);
    z80.writeByte(0x4001, 0x10);

    z80.setAudioMasterOffset(32 * clock.fm_master_cycles_per_sample);
    z80.writeByte(0x4001, 0xF0);

    z80.setAudioMasterOffset(64 * clock.fm_master_cycles_per_sample);
    z80.writeByte(0x4001, 0x40);

    try std.testing.expect(AudioOutput.ymDacEnabled(&z80));
    try std.testing.expectApproxEqAbs(@as(f32, -0.5), AudioOutput.ymDacCurrentSample(&z80), 0.01);

    const ym_write_count = z80.takeYmWrites(output.ym_write_buffer[0..]);
    const ym_dac_count = z80.takeYmDacSamples(output.ym_dac_buffer[0..]);
    try std.testing.expectEqual(@as(usize, 2), ym_write_count);
    try std.testing.expectEqual(@as(usize, 3), ym_dac_count);
    const samples = output.renderChunk(
        pendingWindow(@as(u32, 96) * clock.fm_master_cycles_per_sample),
        0,
        @as(u32, 96) * clock.fm_master_cycles_per_sample,
        0,
        96,
        96,
        output.ym_write_buffer[0..ym_write_count],
        output.ym_dac_buffer[0..ym_dac_count],
        &.{},
        &.{},
    );

    var nonzero: usize = 0;
    var distinct_left: usize = 0;
    var last_left: i16 = 0;
    for (samples) |sample| {
        if (sample != 0) nonzero += 1;
    }
    for (0..samples.len / AudioOutput.channels) |frame| {
        const left = samples[frame * AudioOutput.channels];
        if (frame == 0 or left != last_left) {
            distinct_left += 1;
            last_left = left;
        }
    }
    try std.testing.expect(nonzero > 0);
    try std.testing.expect(distinct_left > 4);
}

test "chunked ym dac rendering matches single chunk output" {
    const pending = pendingWindow(@as(u32, 96) * clock.fm_master_cycles_per_sample);
    const ym_writes = [_]YmWriteEvent{
        .{ .master_offset = 0, .sequence = 0, .port = 0, .reg = 0x2B, .value = 0x80 },
        .{ .master_offset = 0, .sequence = 1, .port = 1, .reg = 0xB6, .value = 0xC0 },
    };
    const ym_dac_samples = [_]YmDacSampleEvent{
        .{ .master_offset = 0, .sequence = 2, .value = 0x10 },
        .{ .master_offset = 13 * clock.fm_master_cycles_per_sample, .sequence = 3, .value = 0xA0 },
        .{ .master_offset = 47 * clock.fm_master_cycles_per_sample, .sequence = 4, .value = 0x40 },
        .{ .master_offset = 63 * clock.fm_master_cycles_per_sample, .sequence = 5, .value = 0xF0 },
    };
    const chunk_frames = [_]u32{ 17, 31, 48 };

    var single = AudioOutput{};
    const single_samples = single.renderChunk(
        pending,
        0,
        pending.master_cycles,
        0,
        96,
        96,
        ym_writes[0..],
        ym_dac_samples[0..],
        &.{},
        &.{},
    );

    var chunked = AudioOutput{};
    var chunked_samples: [96 * AudioOutput.channels]i16 = undefined;
    renderChunkedForTest(
        &chunked,
        pending,
        96,
        chunk_frames[0..],
        ym_writes[0..],
        ym_dac_samples[0..],
        &.{},
        &.{},
        chunked_samples[0..],
    );

    try std.testing.expectEqualSlices(i16, single_samples, chunked_samples[0..]);
}

test "mid-sample ym dac updates do not apply at the start of the sample" {
    const pending = pendingWindow(clock.fm_master_cycles_per_sample);
    const ym_writes = [_]YmWriteEvent{
        .{ .master_offset = 0, .sequence = 0, .port = 0, .reg = 0x2B, .value = 0x80 },
        .{ .master_offset = 0, .sequence = 1, .port = 1, .reg = 0xB6, .value = 0xC0 },
    };
    const full_high_dac = [_]YmDacSampleEvent{
        .{ .master_offset = 0, .sequence = 2, .value = 0xFF },
    };
    const half_high_dac = [_]YmDacSampleEvent{
        .{ .master_offset = 0, .sequence = 2, .value = 0x80 },
        .{ .master_offset = clock.fm_master_cycles_per_sample / 2, .sequence = 3, .value = 0xFF },
    };

    var full = AudioOutput{};
    full.setRenderMode(.unfiltered_mix);
    const full_samples = full.renderChunk(
        pending,
        0,
        pending.master_cycles,
        0,
        1,
        1,
        ym_writes[0..],
        full_high_dac[0..],
        &.{},
        &.{},
    );

    var half = AudioOutput{};
    half.setRenderMode(.unfiltered_mix);
    const half_samples = half.renderChunk(
        pending,
        0,
        pending.master_cycles,
        0,
        1,
        1,
        ym_writes[0..],
        half_high_dac[0..],
        &.{},
        &.{},
    );

    const full_left = @abs(full_samples[0]);
    const half_left = @abs(half_samples[0]);
    try std.testing.expect(full_left > 0);
    try std.testing.expect(half_left > 0);
    try std.testing.expect(half_left < full_left);
}

test "ym reset event clears render-side ym state for later samples" {
    const pending = pendingWindow(2 * clock.fm_master_cycles_per_sample);
    const ym_writes = [_]YmWriteEvent{
        .{ .master_offset = 0, .sequence = 0, .port = 0, .reg = 0x2B, .value = 0x80 },
        .{ .master_offset = 0, .sequence = 1, .port = 1, .reg = 0xB6, .value = 0xC0 },
    };
    const ym_dac_samples = [_]YmDacSampleEvent{
        .{ .master_offset = 0, .sequence = 2, .value = 0xFF },
    };
    const ym_resets = [_]YmResetEvent{
        .{ .master_offset = clock.fm_master_cycles_per_sample, .sequence = 3 },
    };

    var reset_output = AudioOutput{};
    const reset_samples = reset_output.renderChunk(
        pending,
        0,
        pending.master_cycles,
        0,
        2,
        2,
        ym_writes[0..],
        ym_dac_samples[0..],
        ym_resets[0..],
        &.{},
    );
    var steady_output = AudioOutput{};
    const steady_samples = steady_output.renderChunk(
        pending,
        0,
        pending.master_cycles,
        0,
        2,
        2,
        ym_writes[0..],
        ym_dac_samples[0..],
        &.{},
        &.{},
    );

    const reset_second_left = @abs(reset_samples[AudioOutput.channels]);
    const steady_second_left = @abs(steady_samples[AudioOutput.channels]);
    try std.testing.expect(steady_second_left > 0);
    try std.testing.expect(reset_second_left < steady_second_left);
    try std.testing.expectEqual(@as(u8, 0), reset_output.ym_synth.core.dacen);
    try std.testing.expectEqual(@as(u16, 0), reset_output.ym_synth.core.dacdata);
}

test "same-timestamp ym reset and dac events follow capture sequence order" {
    const pending = pendingWindow(clock.fm_master_cycles_per_sample);
    const ym_writes = [_]YmWriteEvent{
        .{ .master_offset = 0, .sequence = 0, .port = 0, .reg = 0x2B, .value = 0x80 },
        .{ .master_offset = 0, .sequence = 1, .port = 1, .reg = 0xB6, .value = 0xC0 },
    };
    const reset_then_dac = [_]YmResetEvent{
        .{ .master_offset = 0, .sequence = 2 },
    };
    const reset_then_dac_samples = [_]YmDacSampleEvent{
        .{ .master_offset = 0, .sequence = 3, .value = 0xFF },
    };
    const dac_then_reset = [_]YmResetEvent{
        .{ .master_offset = 0, .sequence = 3 },
    };
    const dac_then_reset_samples = [_]YmDacSampleEvent{
        .{ .master_offset = 0, .sequence = 2, .value = 0xFF },
    };

    var reset_first = AudioOutput{};
    const reset_first_samples = reset_first.renderChunk(
        pending,
        0,
        pending.master_cycles,
        0,
        1,
        1,
        ym_writes[0..],
        reset_then_dac_samples[0..],
        reset_then_dac[0..],
        &.{},
    );

    var dac_first = AudioOutput{};
    const dac_first_samples = dac_first.renderChunk(
        pending,
        0,
        pending.master_cycles,
        0,
        1,
        1,
        ym_writes[0..],
        dac_then_reset_samples[0..],
        dac_then_reset[0..],
        &.{},
    );

    _ = reset_first_samples;
    _ = dac_first_samples;
    try std.testing.expect(reset_first.ym_synth.core.dacdata != 0);
    try std.testing.expectEqual(@as(u16, 0), dac_first.ym_synth.core.dacdata);
    try std.testing.expectEqual(@as(u8, 0), reset_first.ym_synth.core.dacen);
    try std.testing.expectEqual(@as(u8, 0), dac_first.ym_synth.core.dacen);
}

test "audio output reset preserves mode and clears render-side state" {
    var output = AudioOutput{};
    output.render_mode = .psg_only;
    output.timing_is_pal = true;
    output.ym_synth.core.dacen = 1;
    output.last_psg_sample_left = 99;
    output.last_psg_sample_right = 99;
    output.last_psg_filtered_left = 0.25;
    output.last_psg_filtered_right = 0.25;
    output.last_ym_resampled_left = 0.5;

    output.reset();

    try std.testing.expectEqual(AudioOutput.RenderMode.psg_only, output.render_mode);
    try std.testing.expect(output.timing_is_pal);
    try std.testing.expectEqual(@as(u8, 0), output.ym_synth.core.dacen);
    try std.testing.expectEqual(@as(i16, 0), output.last_psg_sample_left);
    try std.testing.expectEqual(@as(i16, 0), output.last_psg_sample_right);
    try std.testing.expectEqual(@as(f32, 0.0), output.last_psg_filtered_left);
    try std.testing.expectEqual(@as(f32, 0.0), output.last_psg_filtered_right);
    try std.testing.expectEqual(@as(f32, 0.0), output.last_ym_resampled_left);
    try std.testing.expectEqual(@as(u4, 0), output.psg.tones[0].attenuation);
    try std.testing.expectEqual(@as(u4, 0), output.psg.tones[1].attenuation);
    try std.testing.expectEqual(@as(u4, 0), output.psg.tones[2].attenuation);
    try std.testing.expectEqual(@as(u4, 0), output.psg.noise.attenuation);
}

test "audio output init seeds runtime power-on psg state" {
    const output = AudioOutput.init();

    try std.testing.expectEqual(@as(u4, 0), output.psg.tones[0].attenuation);
    try std.testing.expectEqual(@as(u4, 0), output.psg.tones[1].attenuation);
    try std.testing.expectEqual(@as(u4, 0), output.psg.tones[2].attenuation);
    try std.testing.expectEqual(@as(u4, 0), output.psg.noise.attenuation);
    try std.testing.expectEqual(@as(u1, 1), output.psg.tones[0].output_bit);
    try std.testing.expectEqual(@as(u1, 1), output.psg.tones[1].output_bit);
    try std.testing.expectEqual(@as(u1, 1), output.psg.tones[2].output_bit);
}

test "fm high bank frequency uses port 1 a0 and a4" {
    var z80 = Z80.init();
    defer z80.deinit();

    z80.writeByte(0x4002, 0xA2);
    z80.writeByte(0x4003, 0x34);
    z80.writeByte(0x4002, 0xA6);
    z80.writeByte(0x4003, 0x21);

    try std.testing.expect(AudioOutput.fmFrequencyFromChannel(&z80, 5) > 0.0);
}

test "psg commands are applied before chunk rendering" {
    var output = AudioOutput{};

    output.psg_command_buffer[0] = .{ .master_offset = 0, .value = 0x90 };
    output.psg_command_buffer[1] = .{ .master_offset = 0, .value = 0x85 };
    output.psg_command_buffer[2] = .{ .master_offset = 0, .value = 0x00 };

    const samples = output.renderChunk(
        pendingWindow(256 * clock.psg_master_cycles_per_sample),
        0,
        256 * clock.psg_master_cycles_per_sample,
        0,
        64,
        64,
        &.{},
        &.{},
        &.{},
        output.psg_command_buffer[0..3],
    );

    var nonzero: usize = 0;
    for (samples) |sample| {
        if (sample != 0) nonzero += 1;
    }
    try std.testing.expect(nonzero > 0);
}

test "psg command timestamps keep late mute out of early samples" {
    var output = AudioOutput{};

    const commands = [_]PsgCommandEvent{
        .{ .master_offset = 0, .value = 0x90 },
        .{ .master_offset = 0, .value = 0x81 },
        .{ .master_offset = 0, .value = 0x00 },
        .{ .master_offset = @as(u32, 512) * clock.psg_master_cycles_per_sample, .value = 0x9F },
    };

    const samples = output.renderChunk(
        pendingWindow(@as(u32, 1024) * clock.psg_master_cycles_per_sample),
        0,
        @as(u32, 1024) * clock.psg_master_cycles_per_sample,
        0,
        128,
        128,
        &.{},
        &.{},
        &.{},
        commands[0..],
    );

    var early_energy: u64 = 0;
    var late_energy: u64 = 0;
    for (0..32) |i| {
        early_energy += @intCast(@abs(samples[(i * AudioOutput.channels)]));
    }
    for (96..128) |i| {
        late_energy += @intCast(@abs(samples[(i * AudioOutput.channels)]));
    }

    try std.testing.expect(early_energy > late_energy);
}

test "mid-sample psg updates do not apply at the start of the output sample" {
    const pending = pendingWindow(clock.psg_master_cycles_per_sample);
    const full_commands = [_]PsgCommandEvent{
        .{ .master_offset = 0, .value = 0xBF },
        .{ .master_offset = 0, .value = 0xDF },
        .{ .master_offset = 0, .value = 0xFF },
        .{ .master_offset = 0, .value = 0x90 },
        .{ .master_offset = 0, .value = 0x81 },
        .{ .master_offset = 0, .value = 0x00 },
    };
    const half_muted_commands = [_]PsgCommandEvent{
        .{ .master_offset = 0, .value = 0xBF },
        .{ .master_offset = 0, .value = 0xDF },
        .{ .master_offset = 0, .value = 0xFF },
        .{ .master_offset = 0, .value = 0x90 },
        .{ .master_offset = 0, .value = 0x81 },
        .{ .master_offset = 0, .value = 0x00 },
        .{ .master_offset = clock.psg_master_cycles_per_sample / 2, .value = 0x9F },
    };

    var full = AudioOutput.init();
    full.setRenderMode(.unfiltered_mix);
    const full_samples = full.renderChunk(
        pending,
        0,
        pending.master_cycles,
        0,
        1,
        1,
        &.{},
        &.{},
        &.{},
        full_commands[0..],
    );

    var half = AudioOutput.init();
    half.setRenderMode(.unfiltered_mix);
    const half_samples = half.renderChunk(
        pending,
        0,
        pending.master_cycles,
        0,
        1,
        1,
        &.{},
        &.{},
        &.{},
        half_muted_commands[0..],
    );

    const full_left = @abs(full_samples[0]);
    const half_left = @abs(half_samples[0]);
    try std.testing.expect(full_left > 0);
    try std.testing.expect(half_left > 0);
    try std.testing.expect(half_left < full_left);
}

test "render modes isolate ym and psg contributions" {
    const ym_pending = pendingWindow(32 * clock.fm_master_cycles_per_sample);
    const ym_writes = [_]YmWriteEvent{
        .{ .master_offset = 0, .sequence = 0, .port = 0, .reg = 0x2B, .value = 0x80 },
        .{ .master_offset = 0, .sequence = 1, .port = 1, .reg = 0xB6, .value = 0xC0 },
    };
    const ym_dac_samples = [_]YmDacSampleEvent{
        .{ .master_offset = 0, .sequence = 2, .value = 0xF0 },
    };

    var ym_only = AudioOutput{};
    ym_only.setRenderMode(.ym_only);
    const ym_only_samples = ym_only.renderChunk(
        ym_pending,
        0,
        ym_pending.master_cycles,
        0,
        32,
        32,
        ym_writes[0..],
        ym_dac_samples[0..],
        &.{},
        &.{},
    );

    var ym_normal = AudioOutput{};
    const ym_normal_samples = ym_normal.renderChunk(
        ym_pending,
        0,
        ym_pending.master_cycles,
        0,
        32,
        32,
        ym_writes[0..],
        ym_dac_samples[0..],
        &.{},
        &.{},
    );

    var psg_only_for_ym = AudioOutput{};
    psg_only_for_ym.setRenderMode(.psg_only);
    const ym_suppressed_samples = psg_only_for_ym.renderChunk(
        ym_pending,
        0,
        ym_pending.master_cycles,
        0,
        32,
        32,
        ym_writes[0..],
        ym_dac_samples[0..],
        &.{},
        &.{},
    );

    try std.testing.expectEqualSlices(i16, ym_normal_samples, ym_only_samples);
    try std.testing.expectEqual(@as(u64, 0), sampleEnergy(ym_suppressed_samples));

    const psg_pending = pendingWindow(256 * clock.psg_master_cycles_per_sample);
    const psg_commands = [_]PsgCommandEvent{
        .{ .master_offset = 0, .value = 0x90 },
        .{ .master_offset = 0, .value = 0x85 },
        .{ .master_offset = 0, .value = 0x00 },
    };

    var psg_only = AudioOutput{};
    psg_only.setRenderMode(.psg_only);
    const psg_only_samples = psg_only.renderChunk(
        psg_pending,
        0,
        psg_pending.master_cycles,
        0,
        64,
        64,
        &.{},
        &.{},
        &.{},
        psg_commands[0..],
    );

    var ym_only_for_psg = AudioOutput{};
    ym_only_for_psg.setRenderMode(.ym_only);
    const psg_suppressed_samples = ym_only_for_psg.renderChunk(
        psg_pending,
        0,
        psg_pending.master_cycles,
        0,
        64,
        64,
        &.{},
        &.{},
        &.{},
        psg_commands[0..],
    );

    var ym_only_baseline = AudioOutput{};
    ym_only_baseline.setRenderMode(.ym_only);
    const ym_only_baseline_samples = ym_only_baseline.renderChunk(
        psg_pending,
        0,
        psg_pending.master_cycles,
        0,
        64,
        64,
        &.{},
        &.{},
        &.{},
        &.{},
    );

    try std.testing.expect(sampleEnergy(psg_only_samples) > 0);
    try std.testing.expectEqualSlices(i16, ym_only_baseline_samples, psg_suppressed_samples);
}

test "unfiltered mix preserves more high-frequency psg energy than the filtered path" {
    const pending = pendingWindow(@as(u32, 1024) * clock.psg_master_cycles_per_sample);
    const psg_commands = [_]PsgCommandEvent{
        .{ .master_offset = 0, .value = 0x90 },
        .{ .master_offset = 0, .value = 0x81 },
        .{ .master_offset = 0, .value = 0x00 },
    };

    var normal = AudioOutput{};
    const normal_samples = normal.renderChunk(
        pending,
        0,
        pending.master_cycles,
        0,
        128,
        128,
        &.{},
        &.{},
        &.{},
        psg_commands[0..],
    );

    var unfiltered = AudioOutput{};
    unfiltered.setRenderMode(.unfiltered_mix);
    const unfiltered_samples = unfiltered.renderChunk(
        pending,
        0,
        pending.master_cycles,
        0,
        128,
        128,
        &.{},
        &.{},
        &.{},
        psg_commands[0..],
    );

    try std.testing.expect(sampleEnergy(unfiltered_samples) > sampleEnergy(normal_samples));
}

test "default filtered mix applies blip high-pass before the board low-pass" {
    var output = AudioOutput{};
    output.dc_left.warmup_samples = DcBlocker.warmup_count;
    output.dc_right.warmup_samples = DcBlocker.warmup_count;
    output.board_lpf.warmup_samples = BoardOutputLpf.warmup_count;

    const step = output.finishMixedFrame(1.0, 1.0);
    const expected = DcBlocker.blip_highpass_alpha * board_output_input_factor;
    const expected_i16: i16 = @intFromFloat(softSaturate(expected) * 32767.0);

    try std.testing.expectEqual(expected_i16, step[0]);
    try std.testing.expectEqual(expected_i16, step[1]);
}

test "default filtered mix rejects a sustained dc offset" {
    var output = AudioOutput{};
    output.dc_left.warmup_samples = DcBlocker.warmup_count;
    output.dc_right.warmup_samples = DcBlocker.warmup_count;
    output.board_lpf.warmup_samples = BoardOutputLpf.warmup_count;

    var last = output.finishMixedFrame(0.25, 0.25);
    for (0..2048) |_| {
        last = output.finishMixedFrame(0.25, 0.25);
    }

    try std.testing.expect(@abs(last[0]) <= 512);
    try std.testing.expect(@abs(last[1]) <= 512);
}

test "default board mix applies the reference PSG preamp ratio" {
    var output = AudioOutput.init();
    const mixed = output.mixSources(.{ 0.25, -0.125 }, .{ 0.5, 0.5 });

    try std.testing.expectApproxEqAbs(@as(f32, 0.25) + 0.5 * psg_mix_gain, mixed[0], 0.000001);
    try std.testing.expectApproxEqAbs(@as(f32, -0.125) + 0.5 * psg_mix_gain, mixed[1], 0.000001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), psg_mix_gain / psg_base_mix_gain, 0.000001);
}

test "default psg volume matches compile-time preamp" {
    var output = AudioOutput.init();
    try std.testing.expectEqual(@as(u8, 150), output.psg_volume_percent);
    const mixed = output.mixSources(.{ 0.0, 0.0 }, .{ 1.0, 1.0 });
    try std.testing.expectApproxEqAbs(psg_mix_gain, mixed[0], 0.000001);
}

test "psg volume at zero silences psg in mix" {
    var output = AudioOutput.init();
    output.setPsgVolume(0);
    const mixed = output.mixSources(.{ 0.5, 0.5 }, .{ 1.0, 1.0 });
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), mixed[0], 0.000001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), mixed[1], 0.000001);
}

test "psg volume at 200 doubles gain relative to default base" {
    var output = AudioOutput.init();
    output.setPsgVolume(200);
    const mixed = output.mixSources(.{ 0.0, 0.0 }, .{ 1.0, 1.0 });
    const expected = psg_base_mix_gain * 2.0;
    try std.testing.expectApproxEqAbs(expected, mixed[0], 0.000001);
}

test "psg volume survives reset" {
    var output = AudioOutput.init();
    output.setPsgVolume(80);
    output.reset();
    try std.testing.expectEqual(@as(u8, 80), output.psg_volume_percent);
}

test "setPsgVolume clamps to 200" {
    var output = AudioOutput.init();
    output.setPsgVolume(255);
    try std.testing.expectEqual(@as(u8, 200), output.psg_volume_percent);
}

test "master offsets account for pending start remainders when converting to native frames" {
    const pending = pendingWindowWithRemainders(16, clock.fm_master_cycles_per_sample - 8, clock.psg_master_cycles_per_sample - 4);

    try std.testing.expectEqual(@as(u32, 0), AudioOutput.fmFramesBeforeMaster(pending, 7));
    try std.testing.expectEqual(@as(u32, 1), AudioOutput.fmFramesBeforeMaster(pending, 8));
    try std.testing.expectEqual(@as(u32, 0), AudioOutput.psgFramesBeforeMaster(pending, 3));
    try std.testing.expectEqual(@as(u32, 1), AudioOutput.psgFramesBeforeMaster(pending, 4));
}

test "chunked psg rendering matches single chunk output with start remainders" {
    const pending = pendingWindowWithRemainders(
        @as(u32, 1024) * clock.psg_master_cycles_per_sample,
        0,
        clock.psg_master_cycles_per_sample - 17,
    );
    const commands = [_]PsgCommandEvent{
        .{ .master_offset = 0, .value = 0x90 },
        .{ .master_offset = 0, .value = 0x81 },
        .{ .master_offset = 0, .value = 0x00 },
        .{ .master_offset = @as(u32, 511) * clock.psg_master_cycles_per_sample + 60, .value = 0x9F },
    };
    const chunk_frames = [_]u32{ 19, 47, 71 };

    var single = AudioOutput{};
    const single_samples = single.renderChunk(
        pending,
        0,
        pending.master_cycles,
        0,
        137,
        137,
        &.{},
        &.{},
        &.{},
        commands[0..],
    );

    var chunked = AudioOutput{};
    var chunked_samples: [137 * AudioOutput.channels]i16 = undefined;
    renderChunkedForTest(
        &chunked,
        pending,
        137,
        chunk_frames[0..],
        &.{},
        &.{},
        &.{},
        commands[0..],
        chunked_samples[0..],
    );

    try expectSamplesClose(single_samples, chunked_samples[0..], 8);
}

test "zero-output windows still advance chip state and drain queued events" {
    var output = AudioOutput{};
    var z80 = Z80.init();
    defer z80.deinit();
    const NullSink = struct {
        fn consumeSamples(_: *@This(), _: []const i16) !void {}
    };
    var sink = NullSink{};

    z80.setAudioMasterOffset(0);
    z80.writeByte(0x4000, 0x2B);
    z80.writeByte(0x4001, 0x80);
    z80.writeByte(0x4000, 0x2A);
    z80.writeByte(0x4001, 0xF0);

    z80.writeByte(0x7F11, 0x90);
    z80.writeByte(0x7F11, 0x81);
    z80.writeByte(0x7F11, 0x00);

    const pending = pendingWindow(clock.psg_master_cycles_per_sample);
    try std.testing.expectEqual(@as(u32, 0), output.previewOutputFramesForPending(pending));

    try output.renderPending(pending, &z80, false, &sink);

    var ym_writes: [1]YmWriteEvent = undefined;
    var ym_dac_samples: [1]YmDacSampleEvent = undefined;
    var psg_commands: [1]PsgCommandEvent = undefined;
    try std.testing.expectEqual(@as(usize, 0), z80.takeYmWrites(ym_writes[0..]));
    try std.testing.expectEqual(@as(usize, 0), z80.takeYmDacSamples(ym_dac_samples[0..]));
    try std.testing.expectEqual(@as(usize, 0), z80.takePsgCommands(psg_commands[0..]));

    try std.testing.expect(output.ym_synth.core.dacen != 0);
    try std.testing.expect(output.ym_synth.core.dacdata != 0);
    try std.testing.expect(output.psg.tones[0].attenuation != 0xF);
}

test "discard pending drains a nonzero-output audio window without leaving queued events behind" {
    var output = AudioOutput{};
    var z80 = Z80.init();
    defer z80.deinit();

    z80.setAudioMasterOffset(0);
    z80.writeByte(0x4000, 0x2B);
    z80.writeByte(0x4001, 0x80);
    z80.writeByte(0x4002, 0xB6);
    z80.writeByte(0x4003, 0xC0);
    z80.writeByte(0x4000, 0x2A);
    z80.writeByte(0x4001, 0xE0);

    z80.writeByte(0x7F11, 0x90);
    z80.writeByte(0x7F11, 0x81);
    z80.writeByte(0x7F11, 0x00);

    try output.discardPending(pendingWindow(@as(u32, 96) * clock.fm_master_cycles_per_sample), &z80, false);

    var ym_writes: [1]YmWriteEvent = undefined;
    var ym_dac_samples: [1]YmDacSampleEvent = undefined;
    var ym_resets: [1]YmResetEvent = undefined;
    var psg_commands: [1]PsgCommandEvent = undefined;
    try std.testing.expectEqual(@as(usize, 0), z80.takeYmWrites(ym_writes[0..]));
    try std.testing.expectEqual(@as(usize, 0), z80.takeYmDacSamples(ym_dac_samples[0..]));
    try std.testing.expectEqual(@as(usize, 0), z80.takeYmResets(ym_resets[0..]));
    try std.testing.expectEqual(@as(usize, 0), z80.takePsgCommands(psg_commands[0..]));
    try std.testing.expect(output.last_ym_left != 0.0 or output.last_ym_right != 0.0);
    try std.testing.expectEqual(@as(u4, 0), output.psg.tones[0].attenuation);
    try std.testing.expectEqual(@as(u16, 1), output.psg.tones[0].countdown_master);
    try std.testing.expect(output.psg.tones[0].countdown != 0);
}

test "runtime psg mid-sample mute preserves earlier sample energy" {
    const pending = pendingWindow(clock.psg_master_cycles_per_sample);
    const full_commands = [_]PsgCommandEvent{
        .{ .master_offset = 0, .value = 0xBF },
        .{ .master_offset = 0, .value = 0xDF },
        .{ .master_offset = 0, .value = 0xFF },
        .{ .master_offset = 0, .value = 0x90 },
        .{ .master_offset = 0, .value = 0x81 },
        .{ .master_offset = 0, .value = 0x00 },
    };
    const half_muted_commands = [_]PsgCommandEvent{
        .{ .master_offset = 0, .value = 0xBF },
        .{ .master_offset = 0, .value = 0xDF },
        .{ .master_offset = 0, .value = 0xFF },
        .{ .master_offset = 0, .value = 0x90 },
        .{ .master_offset = 0, .value = 0x81 },
        .{ .master_offset = 0, .value = 0x00 },
        .{ .master_offset = clock.psg_master_cycles_per_sample / 2, .value = 0x9F },
    };

    var full = AudioOutput.init();
    const full_count = full.generatePsgNativeSamples(pending, full_commands[0..]).?;
    try std.testing.expectEqual(@as(usize, 1), full_count);
    try std.testing.expect(full.last_psg_sample_left > 0);

    var half_muted = AudioOutput.init();
    const half_muted_count = half_muted.generatePsgNativeSamples(pending, half_muted_commands[0..]).?;
    try std.testing.expectEqual(@as(usize, 1), half_muted_count);
    try std.testing.expect(half_muted.last_psg_sample_left > 0);
    try std.testing.expect(half_muted.last_psg_sample_left < full.last_psg_sample_left);
}

test "runtime psg window-start commands apply cleanly while a sample is already in progress" {
    const half_sample = clock.psg_master_cycles_per_sample / 2;
    const pending = pendingWindowWithRemainders(half_sample, 0, half_sample);
    const mute_command = [_]PsgCommandEvent{
        .{ .master_offset = 0, .value = 0x9F },
    };

    var output = AudioOutput.init();
    output.psg.doCommand(0xBF);
    output.psg.doCommand(0xDF);
    output.psg.doCommand(0xFF);
    output.psg.doCommand(0x90);
    output.psg.doCommand(0x81);
    output.psg.doCommand(0x00);
    output.psg.advanceOneSample();
    output.psg_partial_master_cycles = half_sample;
    const init_sample = output.psg.currentStereoSample();
    output.psg_partial_sum_left = @as(i64, init_sample.left) * @as(i64, half_sample);
    output.psg_partial_sum_right = @as(i64, init_sample.right) * @as(i64, half_sample);

    const produced = output.generatePsgNativeSamples(pending, mute_command[0..]).?;
    try std.testing.expectEqual(@as(usize, 1), produced);
    try std.testing.expect(output.last_psg_sample_left > 0);
    try std.testing.expect(output.last_psg_sample_left < output.psg.currentSample() or output.psg.currentSample() == 0);
}

test "runtime board filtering is applied after resampling" {
    const pending = pendingWindow(@as(u32, 1024) * clock.psg_master_cycles_per_sample);
    const commands = [_]u8{ 0x90, 0x81, 0x00 };

    var normal = AudioOutput{};
    var normal_z80 = Z80.init();
    defer normal_z80.deinit();
    for (commands) |command| normal_z80.writeByte(0x7F11, command);

    var unfiltered = AudioOutput{};
    unfiltered.setRenderMode(.unfiltered_mix);
    var unfiltered_z80 = Z80.init();
    defer unfiltered_z80.deinit();
    for (commands) |command| unfiltered_z80.writeByte(0x7F11, command);

    const normal_frames = normal.preparePending(pending, &normal_z80, false);
    const unfiltered_frames = unfiltered.preparePending(pending, &unfiltered_z80, false);
    try std.testing.expectEqual(normal_frames, unfiltered_frames);

    const compare_frames = @min(@as(usize, @intCast(normal_frames)), 32);
    for (0..compare_frames) |_| {
        const normal_sample = normal.psg_resampler.outputBufferPopFront().?;
        const unfiltered_sample = unfiltered.psg_resampler.outputBufferPopFront().?;
        try std.testing.expectApproxEqAbs(normal_sample[0], unfiltered_sample[0], 0.000001);
    }

    const CollectSink = struct {
        samples: [512]i16 = undefined,
        len: usize = 0,

        fn consumeSamples(self: *@This(), input: []const i16) !void {
            std.debug.assert(self.len + input.len <= self.samples.len);
            @memcpy(self.samples[self.len .. self.len + input.len], input);
            self.len += input.len;
        }
    };

    var normal_runtime = AudioOutput{};
    var normal_runtime_z80 = Z80.init();
    defer normal_runtime_z80.deinit();
    for (commands) |command| normal_runtime_z80.writeByte(0x7F11, command);
    var normal_sink = CollectSink{};
    try normal_runtime.renderPending(pending, &normal_runtime_z80, false, &normal_sink);

    var unfiltered_runtime = AudioOutput{};
    unfiltered_runtime.setRenderMode(.unfiltered_mix);
    var unfiltered_runtime_z80 = Z80.init();
    defer unfiltered_runtime_z80.deinit();
    for (commands) |command| unfiltered_runtime_z80.writeByte(0x7F11, command);
    var unfiltered_sink = CollectSink{};
    try unfiltered_runtime.renderPending(pending, &unfiltered_runtime_z80, false, &unfiltered_sink);

    try std.testing.expectEqual(normal_sink.len, unfiltered_sink.len);
    try std.testing.expect(sampleEnergy(unfiltered_sink.samples[0..unfiltered_sink.len]) > sampleEnergy(normal_sink.samples[0..normal_sink.len]));
}

test "blip buffer runtime pending render produces nonzero mixed audio" {
    const pending = pendingWindow(@as(u32, 96) * clock.fm_master_cycles_per_sample);

    var runtime = AudioOutput{};
    var runtime_z80 = Z80.init();
    defer runtime_z80.deinit();
    runtime_z80.setAudioMasterOffset(0);
    runtime_z80.writeByte(0x4000, 0x2B);
    runtime_z80.writeByte(0x4001, 0x80);
    runtime_z80.writeByte(0x4002, 0xB6);
    runtime_z80.writeByte(0x4003, 0xC0);
    runtime_z80.writeByte(0x4000, 0x2A);
    runtime_z80.writeByte(0x4001, 0x20);
    runtime_z80.setAudioMasterOffset(32 * clock.fm_master_cycles_per_sample);
    runtime_z80.writeByte(0x4001, 0xF0);
    runtime_z80.writeByte(0x7F11, 0x90);
    runtime_z80.writeByte(0x7F11, 0x81);
    runtime_z80.writeByte(0x7F11, 0x00);
    runtime_z80.setAudioMasterOffset(48 * clock.psg_master_cycles_per_sample);
    runtime_z80.writeByte(0x7F11, 0x9F);

    const CollectSink = struct {
        samples: [1024]i16 = undefined,
        len: usize = 0,

        fn consumeSamples(self: *@This(), input: []const i16) !void {
            std.debug.assert(self.len + input.len <= self.samples.len);
            @memcpy(self.samples[self.len .. self.len + input.len], input);
            self.len += input.len;
        }
    };

    var runtime_sink = CollectSink{};
    try runtime.renderPending(pending, &runtime_z80, false, &runtime_sink);

    try std.testing.expect(runtime_sink.len > 0);
    try std.testing.expect(sampleEnergy(runtime_sink.samples[0..runtime_sink.len]) > 0);
}

test "runtime pending render preserves ym stereo separation from pan registers" {
    const pending = pendingWindow(@as(u32, 96) * clock.fm_master_cycles_per_sample);

    var runtime = AudioOutput{};
    var runtime_z80 = Z80.init();
    defer runtime_z80.deinit();
    runtime_z80.setAudioMasterOffset(0);
    runtime_z80.writeByte(0x4000, 0x2B);
    runtime_z80.writeByte(0x4001, 0x80);
    runtime_z80.writeByte(0x4002, 0xB6);
    runtime_z80.writeByte(0x4003, 0x80);
    runtime_z80.writeByte(0x4000, 0x2A);
    runtime_z80.writeByte(0x4001, 0x20);
    runtime_z80.setAudioMasterOffset(24 * clock.fm_master_cycles_per_sample);
    runtime_z80.writeByte(0x4001, 0xF0);
    runtime_z80.setAudioMasterOffset(56 * clock.fm_master_cycles_per_sample);
    runtime_z80.writeByte(0x4001, 0x60);

    const CollectSink = struct {
        samples: [1024]i16 = undefined,
        len: usize = 0,

        fn consumeSamples(self: *@This(), input: []const i16) !void {
            std.debug.assert(self.len + input.len <= self.samples.len);
            @memcpy(self.samples[self.len .. self.len + input.len], input);
            self.len += input.len;
        }
    };

    var runtime_sink = CollectSink{};
    try runtime.renderPending(pending, &runtime_z80, false, &runtime_sink);

    const samples = runtime_sink.samples[0..runtime_sink.len];
    try std.testing.expect(samples.len != 0);
    try std.testing.expect(stereoDifferenceEnergy(samples) > 0);
    try std.testing.expect(channelEnergy(samples, 0) > channelEnergy(samples, 1));
}

test "psg post-resample path does not apply an extra low-pass stage" {
    var output = AudioOutput.init();

    try std.testing.expectApproxEqAbs(@as(f32, 0.75), output.postPsgSample(0.75), 0.000001);
    try std.testing.expectApproxEqAbs(@as(f32, -0.5), output.postPsgSample(-0.5), 0.000001);
}

test "native psg lpf preserves audible content with minimal filtering" {
    const ntsc_psg_rate = AudioOutput.ntscPsgNativeSampleRate();

    // 1 kHz fundamental - should pass through with virtually no attenuation
    var low_lpf = FirstOrderLpf.init(psg_native_cutoff_hz, ntsc_psg_rate);
    var low_peak: f32 = 0.0;
    for (0..4096) |i| {
        const phase = @as(f32, @floatFromInt(i)) * std.math.tau * 1000.0 / @as(f32, @floatCast(ntsc_psg_rate));
        const out = low_lpf.process(@sin(phase));
        if (i > 2048) low_peak = @max(low_peak, @abs(out));
    }

    // 20 kHz - with 22 kHz cutoff, this should also pass through mostly unattenuated
    // (no additional PSG filtering is applied - the cutoff is set very high to pass through all audible content)
    var high_lpf = FirstOrderLpf.init(psg_native_cutoff_hz, ntsc_psg_rate);
    var high_peak: f32 = 0.0;
    for (0..4096) |i| {
        const phase = @as(f32, @floatFromInt(i)) * std.math.tau * 20_000.0 / @as(f32, @floatCast(ntsc_psg_rate));
        const out = high_lpf.process(@sin(phase));
        if (i > 2048) high_peak = @max(high_peak, @abs(out));
    }

    // Both audible frequencies should pass through with minimal loss
    try std.testing.expect(low_peak > 0.95);
    try std.testing.expect(high_peak > 0.7); // 20 kHz near but below 22 kHz cutoff
}

test "board output lpf matches the 0x9999 default recurrence" {
    var lpf = BoardOutputLpf.init();

    // Process enough samples to complete warmup phase
    for (0..BoardOutputLpf.warmup_count) |_| {
        _ = lpf.processL(0.0);
    }

    // Now test the steady-state recurrence relation
    const first = lpf.processL(1.0);
    const second = lpf.processL(-0.5);

    // After warmup, filter should follow standard recurrence: y[n] = history * y[n-1] + input * x[n]
    try std.testing.expectApproxEqAbs(board_output_input_factor, first, 0.000001);
    try std.testing.expectApproxEqAbs(first * board_output_history_factor - 0.5 * board_output_input_factor, second, 0.000001);
}

test "board output lpf applies high-frequency roll-off" {
    var lpf = BoardOutputLpf.init();

    var peak: f32 = 0.0;
    for (0..500) |i| {
        // 20 kHz test tone at 48 kHz sample rate
        const phase = @as(f32, @floatFromInt(i)) * std.math.tau * 20000.0 / 48000.0;
        const out = lpf.processL(@sin(phase));
        if (i > 250) peak = @max(peak, @abs(out));
    }

    // The board LPF (fc ≈ 4 kHz, 0x9999 coefficient) attenuates 20 kHz to ~0.26.
    try std.testing.expect(peak < 0.30);
}

test "board output lpf passes audible content with minimal loss" {
    var lpf = BoardOutputLpf.init();

    var peak: f32 = 0.0;
    for (0..960) |i| {
        const phase = @as(f32, @floatFromInt(i)) * std.math.tau * 1000.0 / 48000.0;
        const out = lpf.processL(@sin(phase));
        if (i > 480) peak = @max(peak, @abs(out));
    }
    // With fc ≈ 4 kHz (0x9999 coefficient), a 1 kHz tone passes with
    // only ~3% attenuation (single-pole IIR well below cutoff).
    try std.testing.expect(peak > 0.95);
}

test "soft saturate leaves in-range samples unchanged" {
    // Values within [-0.9, 0.9] pass through unchanged
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), softSaturate(0.0), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), softSaturate(0.5), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, -0.3), softSaturate(-0.3), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.89), softSaturate(0.89), 0.001);
}

test "soft saturate applies soft knee compression near limits" {
    // Values at or near 1.0 get soft compressed, not hard clipped
    // At exactly 0.9, should pass through
    try std.testing.expectApproxEqAbs(@as(f32, 0.9), softSaturate(0.9), 0.001);
    // At 1.0, soft saturation compresses it below 1.0 but above 0.9
    const sat_1_0 = softSaturate(1.0);
    try std.testing.expect(sat_1_0 > 0.9 and sat_1_0 < 1.0);
    // At 2.0, approaches 1.0 asymptotically
    const sat_2_0 = softSaturate(2.0);
    try std.testing.expect(sat_2_0 > sat_1_0 and sat_2_0 < 1.0);
    // Negative values work symmetrically
    const sat_neg_1_0 = softSaturate(-1.0);
    try std.testing.expect(sat_neg_1_0 < -0.9 and sat_neg_1_0 > -1.0);
}

test "runtime resamplers cover requested output frames for a representative window" {
    var output = AudioOutput{};
    output.setTimingMode(false);

    const pending = pendingWindow(@as(u32, 2048) * clock.fm_master_cycles_per_sample);
    const fm_frames = output.fm_converter.toOutputFrames(pending.fm_frames, AudioOutput.output_rate);
    const psg_frames = output.psg_converter.toOutputFrames(pending.psg_frames, AudioOutput.output_rate);
    const out_frames = @max(fm_frames, psg_frames);

    try std.testing.expect(output.collectPendingNativeSamples(pending, &.{}, &.{}, &.{}, &.{}));

    try std.testing.expect(output.ym_resampler.outputBufferLen() >= out_frames);
    try std.testing.expect(output.psg_resampler.outputBufferLen() >= out_frames);
}

test "pending output frames keeps the longer source queue" {
    var output = AudioOutput{};
    output.ym_resampler.output_count = 3;
    output.ym_resampler.output_write = 3;
    output.psg_resampler.output_count = 5;
    output.psg_resampler.output_write = 5;
    try std.testing.expectEqual(@as(u32, 5), output.pendingOutputFrames());

    output.ym_resampler.output_count = 9;
    output.ym_resampler.output_write = 9;
    output.psg_resampler.output_count = 4;
    output.psg_resampler.output_write = 4;
    try std.testing.expectEqual(@as(u32, 9), output.pendingOutputFrames());
}

test "pending output frames drops impossible queue lengths instead of trapping" {
    var output = AudioOutput{};
    output.ym_resampler.output_count = std.math.maxInt(usize);

    try std.testing.expectEqual(@as(u32, 0), output.pendingOutputFrames());
    try std.testing.expect(output.ym_resampler.hasValidState());
    try std.testing.expect(output.psg_resampler.hasValidState());
}

test "drop queued output clears resampler queues without resetting PSG sub-sample progress" {
    var output = AudioOutput{};
    output.ym_resampler.output_write = 2;
    output.ym_resampler.output_count = 2;
    output.psg_resampler.output_write = 3;
    output.psg_resampler.output_count = 3;
    output.last_ym_resampled_left = 0.5;
    output.last_psg_resampled_right = -0.25;
    output.last_psg_filtered_left = 0.125;
    output.psg_partial_master_cycles = 7;
    output.psg_partial_sum_left = 1234;
    output.psg_partial_sum_right = -5678;

    output.dropQueuedOutput(false);

    try std.testing.expectEqual(@as(usize, 0), output.ym_resampler.outputBufferLen());
    try std.testing.expectEqual(@as(usize, 0), output.psg_resampler.outputBufferLen());
    try std.testing.expectEqual(@as(f32, 0.0), output.last_ym_resampled_left);
    try std.testing.expectEqual(@as(f32, 0.0), output.last_psg_resampled_right);
    try std.testing.expectEqual(@as(f32, 0.0), output.last_psg_filtered_left);
    try std.testing.expectEqual(@as(u16, 7), output.psg_partial_master_cycles);
    try std.testing.expectEqual(@as(i64, 1234), output.psg_partial_sum_left);
    try std.testing.expectEqual(@as(i64, -5678), output.psg_partial_sum_right);
}

test "prepare pending repairs corrupt resampler state before counting output frames" {
    var output = AudioOutput{};
    var z80 = Z80.init();
    defer z80.deinit();

    output.ym_resampler.output_read = output.ym_resampler.output_samples.len;
    output.ym_resampler.output_count = std.math.maxInt(usize);
    output.psg_resampler.output_write = output.psg_resampler.output_samples.len;
    output.psg_resampler.output_count = 17;

    const out_frames = output.preparePending(pendingWindow(clock.ntsc_master_cycles_per_frame), &z80, false);

    try std.testing.expect(out_frames > 0);
    try std.testing.expect(output.ym_resampler.hasValidState());
    try std.testing.expect(output.psg_resampler.hasValidState());
}

test "queue budget helpers clamp and size supported audio latency budgets" {
    try std.testing.expect(AudioOutput.isValidQueueBudgetMs(AudioOutput.default_queue_budget_ms));
    try std.testing.expect(!AudioOutput.isValidQueueBudgetMs(AudioOutput.min_queue_budget_ms - 1));
    try std.testing.expectEqual(AudioOutput.min_queue_budget_ms, AudioOutput.clampQueueBudgetMs(1));
    try std.testing.expectEqual(AudioOutput.max_queue_budget_ms, AudioOutput.clampQueueBudgetMs(255));
    try std.testing.expect(AudioOutput.queueBudgetBytes(AudioOutput.max_queue_budget_ms) >= AudioOutput.queueBudgetBytes(AudioOutput.default_queue_budget_ms));
}

test "eq disabled by default and does not alter output" {
    var with_eq = AudioOutput{};
    var without_eq = AudioOutput{};
    try std.testing.expect(!with_eq.eq_enabled);

    // Both should produce identical results since EQ is disabled
    const step_with = with_eq.finishMixedFrame(0.5, -0.3);
    const step_without = without_eq.finishMixedFrame(0.5, -0.3);
    try std.testing.expectEqual(step_with[0], step_without[0]);
    try std.testing.expectEqual(step_with[1], step_without[1]);
}

test "eq enabled with unity gains preserves approximate output level" {
    var output = AudioOutput{};
    output.setEqEnabled(true);
    output.dc_left.warmup_samples = DcBlocker.warmup_count;
    output.dc_right.warmup_samples = DcBlocker.warmup_count;
    output.board_lpf.warmup_samples = BoardOutputLpf.warmup_count;

    // Feed several samples to let EQ settle
    var last: [2]i16 = undefined;
    for (0..256) |_| {
        last = output.finishMixedFrame(0.4, 0.4);
    }
    // With unity gains the output should still be nonzero
    try std.testing.expect(@abs(last[0]) > 0);
}

test "eq enabled with boosted low changes output relative to flat" {
    var flat = AudioOutput{};
    flat.setEqEnabled(true);
    flat.dc_left.warmup_samples = DcBlocker.warmup_count;
    flat.dc_right.warmup_samples = DcBlocker.warmup_count;
    flat.board_lpf.warmup_samples = BoardOutputLpf.warmup_count;

    var boosted = AudioOutput{};
    boosted.setEqEnabled(true);
    boosted.setEqGains(2.0, 1.0, 1.0);
    boosted.dc_left.warmup_samples = DcBlocker.warmup_count;
    boosted.dc_right.warmup_samples = DcBlocker.warmup_count;
    boosted.board_lpf.warmup_samples = BoardOutputLpf.warmup_count;

    // Feed a 200 Hz signal (low band)
    var flat_energy: u64 = 0;
    var boosted_energy: u64 = 0;
    for (0..2048) |i| {
        const phase = @as(f32, @floatFromInt(i)) * std.math.tau * 200.0 / 48000.0;
        const sample = @sin(phase) * 0.5;
        const f = flat.finishMixedFrame(sample, sample);
        const b = boosted.finishMixedFrame(sample, sample);
        if (i > 1024) {
            flat_energy += @intCast(@abs(f[0]));
            boosted_energy += @intCast(@abs(b[0]));
        }
    }
    try std.testing.expect(flat_energy > 0);
    try std.testing.expect(boosted_energy > flat_energy);
}

test "eq gains survive audio output reset" {
    var output = AudioOutput.init();
    output.setEqEnabled(true);
    output.setEqGains(1.5, 0.8, 1.2);
    output.reset();
    try std.testing.expect(output.eq_enabled);
    try std.testing.expectEqual(@as(f64, 1.5), output.eq_left.lg);
    try std.testing.expectEqual(@as(f64, 0.8), output.eq_left.mg);
    try std.testing.expectEqual(@as(f64, 1.2), output.eq_left.hg);
}

test "blip buffer field initializes with ntsc rates" {
    const output = AudioOutput{};
    try std.testing.expect(output.blip.factor > 0);
    try std.testing.expectEqual(@as(usize, 0), output.blip.samplesAvail());
}

test "blip buffer resets with timing mode change" {
    var output = AudioOutput{};
    output.blip.addDelta(0, 1000, 1000);
    // Use a full NTSC frame to guarantee output samples
    output.blip.endFrame(clock.ntsc_master_cycles_per_frame);
    try std.testing.expect(output.blip.samplesAvail() > 0);

    output.setTimingMode(true);
    try std.testing.expectEqual(@as(usize, 0), output.blip.samplesAvail());
}

test "blip delta tracking resets on audio output reset" {
    var output = AudioOutput{};
    output.blip_fm_last_left = 5000;
    output.blip_psg_last_right = -3000;
    output.reset();
    try std.testing.expectEqual(@as(i32, 0), output.blip_fm_last_left);
    try std.testing.expectEqual(@as(i32, 0), output.blip_psg_last_right);
}
