const std = @import("std");
const zsdl3 = @import("zsdl3");
const clock = @import("../clock.zig");
const PendingAudioFrames = @import("timing.zig").PendingAudioFrames;
const Z80 = @import("../cpu/z80.zig").Z80;
const YmWriteEvent = Z80.YmWriteEvent;
const YmDacSampleEvent = Z80.YmDacSampleEvent;
const YmResetEvent = Z80.YmResetEvent;
const PsgCommandEvent = Z80.PsgCommandEvent;
const Psg = @import("psg.zig").Psg;
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

const DcBlocker = struct {
    x_prev: f32 = 0.0,
    y_prev: f32 = 0.0,

    const alpha: f32 = 0.9974;

    fn process(self: *DcBlocker, x: f32) f32 {
        const y = alpha * (self.y_prev + x - self.x_prev);
        self.x_prev = x;
        self.y_prev = y;
        return y;
    }
};

const PsgOutputLpf = struct {
    prev: f32 = 0.0,
    alpha: f32,

    fn init(cutoff_hz: f32, sample_rate: f32) PsgOutputLpf {
        const rc = 1.0 / (std.math.tau * cutoff_hz);
        const dt = 1.0 / sample_rate;
        return .{ .alpha = dt / (rc + dt) };
    }

    fn process(self: *PsgOutputLpf, x: f32) f32 {
        self.prev = self.prev + self.alpha * (x - self.prev);
        return self.prev;
    }
};

const psg_cutoff_hz: f32 = 4200.0;

const psg_mix_gain: f32 = 0.4466836;

const BoardOutputLpf = struct {
    prev_l: f32 = 0.0,
    prev_r: f32 = 0.0,
    alpha: f32,

    fn init(cutoff_hz: f32, sample_rate: f32) BoardOutputLpf {
        const rc = 1.0 / (std.math.tau * cutoff_hz);
        const dt = 1.0 / sample_rate;
        return .{ .alpha = dt / (rc + dt) };
    }

    fn processL(self: *BoardOutputLpf, x: f32) f32 {
        self.prev_l = self.prev_l + self.alpha * (x - self.prev_l);
        return self.prev_l;
    }

    fn processR(self: *BoardOutputLpf, x: f32) f32 {
        self.prev_r = self.prev_r + self.alpha * (x - self.prev_r);
        return self.prev_r;
    }
};

const board_output_cutoff_hz: f32 = 15000.0;
const resample_scaling_factor: u64 = 1_000_000_000;
const resample_buffer_len: usize = 6;
const resample_output_queue_capacity: usize = 8192;

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

        fn outputBufferPopFront(self: *Self) ?[channels_count]f32 {
            if (self.output_count == 0) return null;

            const sample = self.output_samples[self.output_read];
            self.output_read = (self.output_read + 1) % self.output_samples.len;
            self.output_count -= 1;
            return sample;
        }

        fn collectSample(self: *Self, sample: [channels_count]f32) void {
            self.pushInputSample(sample);

            const scaled_output_frequency = @as(u64, self.output_frequency) * resample_scaling_factor;
            self.cycle_counter_product += scaled_output_frequency;
            while (self.cycle_counter_product >= self.scaled_source_frequency) {
                self.cycle_counter_product -= self.scaled_source_frequency;

                while (self.input_len < resample_buffer_len) {
                    self.pushFrontInputSample(if (self.input_len == 0) [_]f32{0.0} ** channels_count else self.input_samples[0]);
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
            if (self.output_count == self.output_samples.len) {
                self.output_read = (self.output_read + 1) % self.output_samples.len;
                self.output_count -= 1;
            }

            self.output_samples[self.output_write] = sample;
            self.output_write = (self.output_write + 1) % self.output_samples.len;
            self.output_count += 1;
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

pub const AudioOutput = struct {
    pub const RenderMode = enum {
        normal,
        ym_only,
        psg_only,
        unfiltered_mix,
    };

    pub const output_rate: u32 = 48_000;
    pub const channels: usize = 2;
    pub const max_queued_ms: u32 = 150;
    pub const max_queued_bytes: usize = (output_rate * max_queued_ms / 1000) * channels * @sizeOf(i16);
    const max_ym_writes_per_push: usize = 32768;
    const max_ym_dac_samples_per_push: usize = 4096;
    const max_ym_reset_events_per_push: usize = 64;
    const max_psg_commands_per_push: usize = 8192;
    const max_ym_native_samples_per_chunk: usize = 4096;
    const ym_internal_master_cycles: u16 = clock.m68k_divider * 6;
    const ym_internal_clocks_per_sample: u8 = @intCast(clock.fm_master_cycles_per_sample / ym_internal_master_cycles);

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
    ym_write_buffer: [max_ym_writes_per_push]YmWriteEvent = undefined,
    ym_dac_buffer: [max_ym_dac_samples_per_push]YmDacSampleEvent = undefined,
    ym_reset_buffer: [max_ym_reset_events_per_push]YmResetEvent = undefined,
    psg_command_buffer: [max_psg_commands_per_push]PsgCommandEvent = undefined,
    ym_native_buffer: [max_ym_native_samples_per_chunk]YmStereoSample = undefined,
    ym_synth: Ym2612Synth = .{},
    psg: Psg = Psg{},
    ym_resampler: StereoResampler = StereoResampler.init(ntscYmNativeSampleRate(), output_rate),
    psg_resampler: MonoResampler = MonoResampler.init(ntscPsgNativeSampleRate(), output_rate),
    dc_left: DcBlocker = .{},
    dc_right: DcBlocker = .{},
    psg_lpf: PsgOutputLpf = PsgOutputLpf.init(psg_cutoff_hz, @floatFromInt(output_rate)),
    board_lpf: BoardOutputLpf = BoardOutputLpf.init(board_output_cutoff_hz, @floatFromInt(output_rate)),
    render_mode: RenderMode = .normal,
    ym_internal_master_remainder: u16 = 0,
    ym_partial_sum_left: i32 = 0,
    ym_partial_sum_right: i32 = 0,
    ym_partial_internal_clocks: u8 = 0,
    last_ym_resampled_left: f32 = 0.0,
    last_ym_resampled_right: f32 = 0.0,
    last_psg_resampled: f32 = 0.0,
    last_ym_left: f32 = 0.0,
    last_ym_right: f32 = 0.0,
    last_psg_sample: i16 = 0,

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

    fn clockYmInternal(self: *AudioOutput, produced_count: *usize) void {
        const pins = self.ym_synth.clockOneInternal();
        self.ym_partial_sum_left += pins[0];
        self.ym_partial_sum_right += pins[1];
        self.ym_partial_internal_clocks += 1;

        if (self.ym_partial_internal_clocks == ym_internal_clocks_per_sample) {
            const sample = self.ym_synth.finishAccumulatedSample(
                self.ym_partial_sum_left,
                self.ym_partial_sum_right,
            );
            std.debug.assert(produced_count.* < self.ym_native_buffer.len);
            self.ym_native_buffer[produced_count.*] = sample;
            self.last_ym_left = sample.left;
            self.last_ym_right = sample.right;
            self.ym_resampler.collectSample(.{ sample.left, sample.right });
            produced_count.* += 1;
            self.ym_partial_sum_left = 0;
            self.ym_partial_sum_right = 0;
            self.ym_partial_internal_clocks = 0;
        }
    }

    fn advanceYmMaster(self: *AudioOutput, master_cycles: u32, produced_count: *usize) void {
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
            self.clockYmInternal(produced_count);
        }
    }

    fn generateYmNativeSamples(
        self: *AudioOutput,
        master_start: u32,
        master_cycles: u32,
        ym_writes: []const YmWriteEvent,
        ym_dac_samples: []const YmDacSampleEvent,
        ym_reset_events: []const YmResetEvent,
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
                self.advanceYmMaster(master_end - master_cursor, &produced_count);
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
                self.advanceYmMaster(master_end - master_cursor, &produced_count);
                break;
            }

            if (next_order.master_offset > master_cursor) {
                self.advanceYmMaster(next_order.master_offset - master_cursor, &produced_count);
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
        master_start: u32,
        master_cycles: u32,
        psg_commands: []const PsgCommandEvent,
    ) usize {
        const master_end = @min(pending.master_cycles, master_start + master_cycles);
        const psg_native_end = psgFramesBeforeMaster(pending, master_end);
        var psg_native_cursor = psgFramesBeforeMaster(pending, master_start);
        var psg_cmd_cursor: usize = 0;

        while (psg_native_cursor < psg_native_end) {
            self.applyPsgCommandsAtFrame(pending, psg_commands, &psg_cmd_cursor, psg_native_cursor);
            const next_psg_command_frame = if (psg_cmd_cursor < psg_commands.len)
                @min(psg_native_end, psgFramesBeforeMaster(pending, psg_commands[psg_cmd_cursor].master_offset))
            else
                psg_native_end;

            if (next_psg_command_frame == psg_native_cursor) {
                self.applyPsgCommandsAtFrame(pending, psg_commands, &psg_cmd_cursor, psg_native_cursor);
                continue;
            }

            while (psg_native_cursor < next_psg_command_frame) : (psg_native_cursor += 1) {
                self.last_psg_sample = self.psg.nextSample();
                self.psg_resampler.collectSample(.{self.postPsgSample(@as(f32, @floatFromInt(self.last_psg_sample)) / 32768.0)});
            }
        }

        self.applyPsgCommandsAtFrame(pending, psg_commands, &psg_cmd_cursor, std.math.maxInt(u32));
        return psg_native_end - psgFramesBeforeMaster(pending, master_start);
    }

    fn popMixedFrames(self: *AudioOutput, frames: usize) []const i16 {
        for (0..frames) |i| {
            const ym = if (self.ym_resampler.outputBufferPopFront()) |sample| blk: {
                self.last_ym_resampled_left = sample[0];
                self.last_ym_resampled_right = sample[1];
                break :blk sample;
            } else .{ self.last_ym_resampled_left, self.last_ym_resampled_right };
            const psg = if (self.psg_resampler.outputBufferPopFront()) |sample| blk: {
                self.last_psg_resampled = sample[0];
                break :blk sample;
            } else .{self.last_psg_resampled};

            const mixed = self.mixSources(ym, psg[0]);
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
        const psg_native_start = psgFramesBeforeMaster(pending, master_start);
        const expected_ym_native_frames = fmFramesBeforeMaster(pending, master_end) - fmFramesBeforeMaster(pending, master_start);
        const ym_generation = self.generateYmNativeSamples(
            master_start,
            master_end - master_start,
            ym_writes,
            ym_dac_samples,
            ym_reset_events,
        );
        const ym_native_frames = ym_generation.produced_count;

        std.debug.assert(ym_native_frames == expected_ym_native_frames);

        var psg_native_cursor: u32 = psg_native_start;
        var last_psg_sample = self.last_psg_sample;
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

            const target_psg_native = psgFramesBeforeMaster(pending, global_master_target);
            self.applyPsgCommandsAtFrame(pending, psg_commands, &psg_cmd_cursor, psg_native_cursor);

            var samples_to_generate: u32 = 0;
            var psg_sample: f32 = 0.0;
            if (psg_native_cursor < target_psg_native) {
                var sum: i32 = 0;
                while (psg_native_cursor < target_psg_native) {
                    const next_psg_command_frame = if (psg_cmd_cursor < psg_commands.len)
                        @min(target_psg_native, psgFramesBeforeMaster(pending, psg_commands[psg_cmd_cursor].master_offset))
                    else
                        target_psg_native;

                    if (next_psg_command_frame == psg_native_cursor) {
                        self.applyPsgCommandsAtFrame(pending, psg_commands, &psg_cmd_cursor, psg_native_cursor);
                        continue;
                    }

                    var generated = next_psg_command_frame - psg_native_cursor;
                    while (generated != 0) : (generated -= 1) {
                        last_psg_sample = self.psg.nextSample();
                        sum += last_psg_sample;
                        psg_native_cursor += 1;
                        samples_to_generate += 1;
                    }
                }
                psg_sample = @as(f32, @floatFromInt(sum)) / @as(f32, @floatFromInt(samples_to_generate)) / 32768.0;
            } else {
                psg_sample = @as(f32, @floatFromInt(last_psg_sample)) / 32768.0;
            }
            psg_sample = self.postPsgSample(psg_sample);
            const mixed = self.mixSources(.{ l, r }, psg_sample);
            const finished = self.finishMixedFrame(mixed[0], mixed[1]);
            self.sample_chunk[i * channels] = finished[0];
            self.sample_chunk[i * channels + 1] = finished[1];
        }

        self.applyPsgCommandsAtFrame(pending, psg_commands, &psg_cmd_cursor, std.math.maxInt(u32));
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
        self.last_psg_sample = last_psg_sample;

        return self.sample_chunk[0 .. frames * channels];
    }

    fn postPsgSample(self: *AudioOutput, sample: f32) f32 {
        return if (self.render_mode == .unfiltered_mix)
            sample
        else
            self.psg_lpf.process(sample);
    }

    fn mixSources(self: *const AudioOutput, ym: [2]f32, psg: f32) [2]f32 {
        var l: f32 = 0.0;
        var r: f32 = 0.0;

        if (self.render_mode != .psg_only) {
            l += ym[0];
            r += ym[1];
        }

        if (self.render_mode != .ym_only) {
            l += psg * psg_mix_gain;
            r += psg * psg_mix_gain;
        }

        return .{ l, r };
    }

    fn finishMixedFrame(self: *AudioOutput, left: f32, right: f32) [2]i16 {
        var l = left;
        var r = right;

        if (self.render_mode != .unfiltered_mix) {
            l = self.board_lpf.processL(l);
            r = self.board_lpf.processR(r);
            l = self.dc_left.process(l);
            r = self.dc_right.process(r);
        }

        l = clampMix(l);
        r = clampMix(r);
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
                self.last_psg_sample = self.psg.nextSample();
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
    ) void {
        const ym_generation = self.generateYmNativeSamples(
            0,
            pending.master_cycles,
            ym_writes,
            ym_dac_samples,
            ym_reset_events,
        );
        const psg_native_frames = self.generatePsgNativeSamples(pending, 0, pending.master_cycles, psg_commands);
        std.debug.assert(ym_generation.produced_count == pending.fm_frames);
        std.debug.assert(psg_native_frames == pending.psg_frames);

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
        self.ym_resampler.reset(if (is_pal) palYmNativeSampleRate() else ntscYmNativeSampleRate(), output_rate);
        self.psg_resampler.reset(if (is_pal) palPsgNativeSampleRate() else ntscPsgNativeSampleRate(), output_rate);
        self.dc_left = .{};
        self.dc_right = .{};
        self.psg_lpf = PsgOutputLpf.init(psg_cutoff_hz, @floatFromInt(output_rate));
        self.board_lpf = BoardOutputLpf.init(board_output_cutoff_hz, @floatFromInt(output_rate));
        self.last_ym_resampled_left = 0.0;
        self.last_ym_resampled_right = 0.0;
        self.last_psg_resampled = 0.0;
    }

    pub fn canAcceptPending(self: *AudioOutput) bool {
        const queued_bytes = zsdl3.getAudioStreamQueued(self.stream) catch return false;
        return queued_bytes < max_queued_bytes;
    }

    pub fn setRenderMode(self: *AudioOutput, mode: RenderMode) void {
        self.render_mode = mode;
    }

    fn processPending(self: *AudioOutput, pending: PendingAudioFrames, z80: *Z80, is_pal: bool, queue_output: bool) !void {
        self.setTimingMode(is_pal);

        const fm_frames = self.fm_converter.toOutputFrames(pending.fm_frames, output_rate);
        const psg_frames = self.psg_converter.toOutputFrames(pending.psg_frames, output_rate);
        const out_frames: u32 = @max(fm_frames, psg_frames);
        const ym_write_count = z80.takeYmWrites(self.ym_write_buffer[0..]);
        const ym_dac_count = z80.takeYmDacSamples(self.ym_dac_buffer[0..]);
        const ym_reset_count = z80.takeYmResets(self.ym_reset_buffer[0..]);
        const psg_command_count = z80.takePsgCommands(self.psg_command_buffer[0..]);
        self.collectPendingNativeSamples(
            pending,
            self.ym_write_buffer[0..ym_write_count],
            self.ym_dac_buffer[0..ym_dac_count],
            self.ym_reset_buffer[0..ym_reset_count],
            self.psg_command_buffer[0..psg_command_count],
        );
        if (out_frames == 0) return;

        const max_frames_per_push = self.sample_chunk.len / channels;
        var out_frame_offset: u32 = 0;
        while (out_frame_offset < out_frames) {
            const remaining_out_frames = out_frames - out_frame_offset;
            const chunk_frames: usize = @min(@as(usize, @intCast(remaining_out_frames)), max_frames_per_push);
            const samples = self.popMixedFrames(chunk_frames);
            if (queue_output) {
                try zsdl3.putAudioStreamData(i16, self.stream, samples);
            }
            out_frame_offset += @as(u32, @intCast(chunk_frames));
        }
    }

    pub fn pushPending(self: *AudioOutput, pending: PendingAudioFrames, z80: *Z80, is_pal: bool) !void {
        try self.processPending(pending, z80, is_pal, true);
    }

    pub fn discardPending(self: *AudioOutput, pending: PendingAudioFrames, z80: *Z80, is_pal: bool) !void {
        try self.processPending(pending, z80, is_pal, false);
    }
};

fn clampMix(x: f32) f32 {
    return std.math.clamp(x, -1.0, 1.0);
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

test "rate converter keeps FM/PSG aligned over one NTSC frame" {
    var output = AudioOutput{
        .stream = @ptrFromInt(1),
    };
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
    var output = AudioOutput{
        .stream = @ptrFromInt(1),
    };
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
    var output = AudioOutput{
        .stream = @ptrFromInt(1),
    };
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
    var output = AudioOutput{
        .stream = @ptrFromInt(1),
    };
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

    var single = AudioOutput{ .stream = @ptrFromInt(1) };
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

    var chunked = AudioOutput{ .stream = @ptrFromInt(1) };
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

    var full = AudioOutput{ .stream = @ptrFromInt(1) };
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

    var half = AudioOutput{ .stream = @ptrFromInt(1) };
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

    var reset_output = AudioOutput{ .stream = @ptrFromInt(1) };
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
    var steady_output = AudioOutput{ .stream = @ptrFromInt(1) };
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

    var reset_first = AudioOutput{ .stream = @ptrFromInt(1) };
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

    var dac_first = AudioOutput{ .stream = @ptrFromInt(1) };
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
    var output = AudioOutput{
        .stream = @ptrFromInt(1),
    };

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
    var output = AudioOutput{
        .stream = @ptrFromInt(1),
    };

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

test "render modes isolate ym and psg contributions" {
    const ym_pending = pendingWindow(32 * clock.fm_master_cycles_per_sample);
    const ym_writes = [_]YmWriteEvent{
        .{ .master_offset = 0, .sequence = 0, .port = 0, .reg = 0x2B, .value = 0x80 },
        .{ .master_offset = 0, .sequence = 1, .port = 1, .reg = 0xB6, .value = 0xC0 },
    };
    const ym_dac_samples = [_]YmDacSampleEvent{
        .{ .master_offset = 0, .sequence = 2, .value = 0xF0 },
    };

    var ym_only = AudioOutput{ .stream = @ptrFromInt(1) };
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

    var ym_normal = AudioOutput{ .stream = @ptrFromInt(1) };
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

    var psg_only_for_ym = AudioOutput{ .stream = @ptrFromInt(1) };
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

    var psg_only = AudioOutput{ .stream = @ptrFromInt(1) };
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

    var ym_only_for_psg = AudioOutput{ .stream = @ptrFromInt(1) };
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

    var ym_only_baseline = AudioOutput{ .stream = @ptrFromInt(1) };
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

    var normal = AudioOutput{ .stream = @ptrFromInt(1) };
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

    var unfiltered = AudioOutput{ .stream = @ptrFromInt(1) };
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

    var single = AudioOutput{ .stream = @ptrFromInt(1) };
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

    var chunked = AudioOutput{ .stream = @ptrFromInt(1) };
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
    var output = AudioOutput{
        .stream = @ptrFromInt(1),
    };
    var z80 = Z80.init();
    defer z80.deinit();

    z80.setAudioMasterOffset(0);
    z80.writeByte(0x4000, 0x2B);
    z80.writeByte(0x4001, 0x80);
    z80.writeByte(0x4000, 0x2A);
    z80.writeByte(0x4001, 0xF0);

    z80.writeByte(0x7F11, 0x90);
    z80.writeByte(0x7F11, 0x81);
    z80.writeByte(0x7F11, 0x00);

    const pending = pendingWindow(clock.psg_master_cycles_per_sample);
    try std.testing.expectEqual(@as(u32, 0), output.fm_converter.toOutputFrames(pending.fm_frames, AudioOutput.output_rate));
    try std.testing.expectEqual(@as(u32, 0), output.psg_converter.toOutputFrames(pending.psg_frames, AudioOutput.output_rate));

    try output.pushPending(pending, &z80, false);

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
    var output = AudioOutput{
        .stream = @ptrFromInt(1),
    };
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
    try std.testing.expect(output.last_psg_sample != 0);
}

test "psg output lpf attenuates high-frequency content" {
    var lpf = PsgOutputLpf.init(psg_cutoff_hz, @floatFromInt(AudioOutput.output_rate));

    var peak: f32 = 0.0;
    for (0..200) |i| {
        const input: f32 = if (i % 4 < 2) 1.0 else -1.0;
        const output_sample = lpf.process(input);
        if (i > 100) peak = @max(peak, @abs(output_sample));
    }

    try std.testing.expect(peak < 0.5);
}

test "psg output lpf passes low-frequency content" {
    var lpf = PsgOutputLpf.init(psg_cutoff_hz, @floatFromInt(AudioOutput.output_rate));

    var peak: f32 = 0.0;
    for (0..960) |i| {
        const phase = @as(f32, @floatFromInt(i)) * std.math.tau / 240.0;
        const input = @sin(phase);
        const output_sample = lpf.process(input);
        if (i > 480) peak = @max(peak, @abs(output_sample));
    }

    try std.testing.expect(peak > 0.85);
}

test "board output lpf provides gentle high-frequency roll-off" {
    var lpf = BoardOutputLpf.init(board_output_cutoff_hz, @floatFromInt(AudioOutput.output_rate));

    var peak: f32 = 0.0;
    for (0..500) |i| {
        const phase = @as(f32, @floatFromInt(i)) * std.math.tau * 20000.0 / 48000.0;
        const out = lpf.processL(@sin(phase));
        if (i > 250) peak = @max(peak, @abs(out));
    }

    try std.testing.expect(peak < 0.75);
}

test "board output lpf passes audible content with minimal loss" {
    var lpf = BoardOutputLpf.init(board_output_cutoff_hz, @floatFromInt(AudioOutput.output_rate));

    var peak: f32 = 0.0;
    for (0..960) |i| {
        const phase = @as(f32, @floatFromInt(i)) * std.math.tau * 1000.0 / 48000.0;
        const out = lpf.processL(@sin(phase));
        if (i > 480) peak = @max(peak, @abs(out));
    }
    try std.testing.expect(peak > 0.95);
}

test "mix clamp leaves in-range samples unchanged" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), clampMix(0.0), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), clampMix(0.5), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, -0.3), clampMix(-0.3), 0.001);
}

test "mix clamp saturates out-of-range samples" {
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), clampMix(1.0), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), clampMix(-1.0), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), clampMix(2.0), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), clampMix(-2.0), 0.001);
}

test "runtime resamplers cover requested output frames for a representative window" {
    var output = AudioOutput{ .stream = @ptrFromInt(1) };
    output.setTimingMode(false);

    const pending = pendingWindow(@as(u32, 2048) * clock.fm_master_cycles_per_sample);
    const fm_frames = output.fm_converter.toOutputFrames(pending.fm_frames, AudioOutput.output_rate);
    const psg_frames = output.psg_converter.toOutputFrames(pending.psg_frames, AudioOutput.output_rate);
    const out_frames = @max(fm_frames, psg_frames);

    output.collectPendingNativeSamples(pending, &.{}, &.{}, &.{}, &.{});

    try std.testing.expect(output.ym_resampler.outputBufferLen() >= out_frames);
    try std.testing.expect(output.psg_resampler.outputBufferLen() >= out_frames);
}
