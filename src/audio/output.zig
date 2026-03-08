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

/// DC-blocking high-pass filter (models AC coupling on Genesis audio output).
/// Single-pole HPF at ~20 Hz removes DC offset from DAC-heavy output.
const DcBlocker = struct {
    x_prev: f32 = 0.0,
    y_prev: f32 = 0.0,
    // alpha ≈ 1 - (2π × 20 / 48000) ≈ 0.9974
    const alpha: f32 = 0.9974;

    fn process(self: *DcBlocker, x: f32) f32 {
        const y = alpha * (self.y_prev + x - self.x_prev);
        self.x_prev = x;
        self.y_prev = y;
        return y;
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

pub const AudioOutput = struct {
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
    dc_left: DcBlocker = .{},
    dc_right: DcBlocker = .{},
    ym_internal_master_remainder: u16 = 0,
    ym_partial_sum_left: i32 = 0,
    ym_partial_sum_right: i32 = 0,
    ym_partial_internal_clocks: u8 = 0,
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
            std.debug.assert(produced_count.* < self.ym_native_buffer.len);
            self.ym_native_buffer[produced_count.*] = self.ym_synth.finishAccumulatedSample(
                self.ym_partial_sum_left,
                self.ym_partial_sum_right,
            );
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
        frames: usize,
        ym_writes: []const YmWriteEvent,
        ym_dac_samples: []const YmDacSampleEvent,
        ym_reset_events: []const YmResetEvent,
        psg_commands: []const PsgCommandEvent,
    ) []const i16 {
        const master_end = @min(pending.master_cycles, master_start + master_cycles);
        const psg_native_start = psgFramesBeforeMaster(pending, master_start);
        const psg_native_end = psgFramesBeforeMaster(pending, master_end);
        const psg_native_frames = psg_native_end - psg_native_start;
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
            const target_ym_native: usize = @intCast((@as(u64, i + 1) * ym_native_frames) / frames);
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

            const target_psg_native = psg_native_start + @as(u32, @intCast((@as(u64, i + 1) * psg_native_frames) / frames));
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
            l += psg_sample * 0.44;
            r += psg_sample * 0.44;

            l = self.dc_left.process(l);
            r = self.dc_right.process(r);
            l = @max(-0.95, @min(0.95, l));
            r = @max(-0.95, @min(0.95, r));
            self.sample_chunk[i * channels] = @as(i16, @intFromFloat(l * 32767.0));
            self.sample_chunk[i * channels + 1] = @as(i16, @intFromFloat(r * 32767.0));
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
        self.dc_left = .{};
        self.dc_right = .{};
    }

    pub fn canAcceptPending(self: *AudioOutput) bool {
        const queued_bytes = zsdl3.getAudioStreamQueued(self.stream) catch return false;
        return queued_bytes < max_queued_bytes;
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
        if (out_frames == 0) {
            self.advanceWindowWithoutOutput(
                pending,
                self.ym_write_buffer[0..ym_write_count],
                self.ym_dac_buffer[0..ym_dac_count],
                self.ym_reset_buffer[0..ym_reset_count],
                self.psg_command_buffer[0..psg_command_count],
            );
            return;
        }

        const max_frames_per_push = self.sample_chunk.len / channels;
        const total_out_frames = out_frames;
        var out_frame_offset: u32 = 0;
        var ym_write_offset: usize = 0;
        var ym_dac_offset: usize = 0;
        var ym_reset_offset: usize = 0;
        var psg_cmd_offset: usize = 0;
        while (out_frame_offset < total_out_frames) {
            const remaining_out_frames = total_out_frames - out_frame_offset;
            const chunk_frames: usize = @min(@as(usize, @intCast(remaining_out_frames)), max_frames_per_push);
            const chunk_out_end = out_frame_offset + @as(u32, @intCast(chunk_frames));
            const chunk_master_offset = outputFrameToMaster(pending, out_frame_offset, total_out_frames);
            const chunk_master_end = outputFrameToMaster(pending, chunk_out_end, total_out_frames);

            var ym_write_end = ym_write_offset;
            while (ym_write_end < ym_write_count and self.ym_write_buffer[ym_write_end].master_offset < chunk_master_end) : (ym_write_end += 1) {}

            var ym_dac_end = ym_dac_offset;
            while (ym_dac_end < ym_dac_count and self.ym_dac_buffer[ym_dac_end].master_offset < chunk_master_end) : (ym_dac_end += 1) {}

            var ym_reset_end = ym_reset_offset;
            while (ym_reset_end < ym_reset_count and self.ym_reset_buffer[ym_reset_end].master_offset < chunk_master_end) : (ym_reset_end += 1) {}

            var psg_cmd_end = psg_cmd_offset;
            while (psg_cmd_end < psg_command_count and self.psg_command_buffer[psg_cmd_end].master_offset < chunk_master_end) : (psg_cmd_end += 1) {}
            const samples = self.renderChunk(
                pending,
                chunk_master_offset,
                chunk_master_end - chunk_master_offset,
                chunk_frames,
                self.ym_write_buffer[ym_write_offset..ym_write_end],
                self.ym_dac_buffer[ym_dac_offset..ym_dac_end],
                self.ym_reset_buffer[ym_reset_offset..ym_reset_end],
                self.psg_command_buffer[psg_cmd_offset..psg_cmd_end],
            );
            if (queue_output) {
                try zsdl3.putAudioStreamData(i16, self.stream, samples);
            }
            out_frame_offset = chunk_out_end;
            ym_write_offset = ym_write_end;
            ym_dac_offset = ym_dac_end;
            ym_reset_offset = ym_reset_end;
            psg_cmd_offset = psg_cmd_end;
        }

        while (ym_reset_offset < ym_reset_count) : (ym_reset_offset += 1) {
            self.resetYmRenderState();
        }
        while (ym_write_offset < ym_write_count) : (ym_write_offset += 1) {
            self.applyYmWriteEvent(self.ym_write_buffer[ym_write_offset]);
        }
        while (ym_dac_offset < ym_dac_count) : (ym_dac_offset += 1) {
            self.applyYmDacSampleEvent(self.ym_dac_buffer[ym_dac_offset]);
        }
        while (psg_cmd_offset < psg_command_count) : (psg_cmd_offset += 1) {
            self.psg.doCommand(self.psg_command_buffer[psg_cmd_offset].value);
        }
    }

    pub fn pushPending(self: *AudioOutput, pending: PendingAudioFrames, z80: *Z80, is_pal: bool) !void {
        try self.processPending(pending, z80, is_pal, true);
    }

    pub fn discardPending(self: *AudioOutput, pending: PendingAudioFrames, z80: *Z80, is_pal: bool) !void {
        try self.processPending(pending, z80, is_pal, false);
    }
};

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
    output.psg.doCommand(0x90); // ch0 volume = 0
    output.psg.doCommand(0x85); // ch0 tone low = 5
    output.psg.doCommand(0x00); // ch0 tone high = 0

    const samples = output.renderChunk(
        pendingWindow(256 * clock.psg_master_cycles_per_sample),
        0,
        256 * clock.psg_master_cycles_per_sample,
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
        1,
        ym_writes[0..],
        half_high_dac[0..],
        &.{},
        &.{},
    );

    const full_left = @abs(full_samples[0]);
    const half_left = @abs(half_samples[0]);
    try std.testing.expect(full_left > 0);
    try std.testing.expect(half_left > full_left / 4);
    try std.testing.expect(half_left < (full_left * 3) / 4);
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

    var output = AudioOutput{ .stream = @ptrFromInt(1) };
    const samples = output.renderChunk(
        pending,
        0,
        pending.master_cycles,
        2,
        ym_writes[0..],
        ym_dac_samples[0..],
        ym_resets[0..],
        &.{},
    );

    const first_left = @abs(samples[0]);
    const second_left = @abs(samples[AudioOutput.channels]);
    try std.testing.expect(first_left > 0);
    try std.testing.expect(second_left < first_left / 8);
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
        1,
        ym_writes[0..],
        dac_then_reset_samples[0..],
        dac_then_reset[0..],
        &.{},
    );

    try std.testing.expect(@abs(reset_first_samples[0]) > @abs(dac_first_samples[0]) * 4);
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

    try std.testing.expect(early_energy > late_energy * 3);
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

    try std.testing.expectEqualSlices(i16, single_samples, chunked_samples[0..]);
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

    try std.testing.expect(output.last_ym_left != 0.0 or output.last_ym_right != 0.0);
    try std.testing.expect(output.last_psg_sample != 0);
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
