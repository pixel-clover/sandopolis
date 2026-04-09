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
const Ym2612Sample = @import("ym2612_sample.zig").Ym2612Sample;

const YmEventKind = enum {
    write,
    dac,
    reset,
};

const YmEventOrder = struct {
    master_offset: u32,
    sequence: u32,
};

const PendingAudioEvents = struct {
    ym_writes: []const YmWriteEvent,
    ym_dac_samples: []const YmDacSampleEvent,
    ym_reset_events: []const YmResetEvent,
    psg_commands: []const PsgCommandEvent,
};

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
// mainboard.  The reference uses coefficient 0x9999 at 44.1 kHz, giving
// fc ≈ 3585 Hz.  Adjusted for our 48 kHz output rate to match the same
// analog cutoff frequency: 0xA01B at 48 kHz → fc ≈ 3585 Hz.
const board_output_history_factor: f32 = @as(f32, 0xA01B) / 65536.0;
const board_output_input_factor: f32 = 1.0 - board_output_history_factor;

// BlipBuf capacity: enough for several frames at 48 kHz output.
const blip_buf_capacity: usize = 4800;
const BlipBuffer = blip_buf.BlipBuf(blip_buf_capacity);

// Default 3-band EQ crossover frequencies, commonly used in Genesis emulators.
const eq_default_low_freq: u32 = 880;
const eq_default_high_freq: u32 = 5000;

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

    timing_is_pal: bool = false,
    sample_chunk: [4096]i16 = [_]i16{0} ** 4096,
    ym_write_buffer: [max_ym_writes_per_push]YmWriteEvent = undefined,
    ym_dac_buffer: [max_ym_dac_samples_per_push]YmDacSampleEvent = undefined,
    ym_reset_buffer: [max_ym_reset_events_per_push]YmResetEvent = undefined,
    psg_command_buffer: [max_psg_commands_per_push]PsgCommandEvent = undefined,
    ym_sample: Ym2612Sample = .{},
    psg: Psg = Psg{},
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
    last_ym_left: f32 = 0.0,
    last_ym_right: f32 = 0.0,
    last_psg_sample_left: i16 = 0,
    last_psg_sample_right: i16 = 0,

    pub fn init() AudioOutput {
        var output: AudioOutput = .{};
        output.ym_sample = Ym2612Sample.init();
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

    fn resetOutputPipeline(self: *AudioOutput, is_pal: bool) void {
        self.board_lpf = BoardOutputLpf.init();
        self.resetBlip(is_pal);
        self.eq_left.resetState();
        self.eq_right.resetState();
    }

    pub fn dropQueuedOutput(self: *AudioOutput, is_pal: bool) void {
        self.resetOutputPipeline(is_pal);
    }

    pub fn setPsgVolume(self: *AudioOutput, percent: u8) void {
        self.psg_volume_percent = @min(percent, 200);
    }

    pub fn setTimingMode(self: *AudioOutput, is_pal: bool) void {
        if (self.timing_is_pal == is_pal) return;

        self.timing_is_pal = is_pal;
        self.resetOutputPipeline(is_pal);
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
        self.ym_sample = Ym2612Sample.init();
        self.render_mode = render_mode;
        self.psg_volume_percent = psg_vol;
        self.eq_enabled = eq_en;
        self.setEqGains(eq_lg, eq_mg, eq_hg);
        if (timing_is_pal) {
            self.setTimingMode(true);
        }
    }

    /// Rebuild the sample-based YM2612 core's state from the Z80
    /// bridge's register shadow.  Call this after loading a save state
    /// so the FM synthesis matches the restored machine state.
    pub fn syncYmStateFromZ80(self: *AudioOutput, z80: *const Z80) void {
        self.ym_sample.reset();

        // Replay all YM registers from the shadow into the sample core.
        // Register order matters: write frequency/operator params before
        // key-on, and mode registers before channel registers.
        for (0..2) |port| {
            const p: u1 = @intCast(port);
            const addr_port: u2 = @as(u2, p) * 2;

            // Mode registers (0x20-0x2F): only port 0
            if (port == 0) {
                // LFO
                self.ym_sample.write(addr_port, 0x22);
                self.ym_sample.write(addr_port + 1, z80.getYmRegister(p, 0x22));
                // Timer A
                self.ym_sample.write(addr_port, 0x24);
                self.ym_sample.write(addr_port + 1, z80.getYmRegister(p, 0x24));
                self.ym_sample.write(addr_port, 0x25);
                self.ym_sample.write(addr_port + 1, z80.getYmRegister(p, 0x25));
                // Timer B
                self.ym_sample.write(addr_port, 0x26);
                self.ym_sample.write(addr_port + 1, z80.getYmRegister(p, 0x26));
                // Mode/timer control
                self.ym_sample.write(addr_port, 0x27);
                self.ym_sample.write(addr_port + 1, z80.getYmRegister(p, 0x27));
                // DAC data and enable
                self.ym_sample.write(addr_port, 0x2A);
                self.ym_sample.write(addr_port + 1, z80.getYmRegister(p, 0x2A));
                self.ym_sample.write(addr_port, 0x2B);
                self.ym_sample.write(addr_port + 1, z80.getYmRegister(p, 0x2B));
            }

            // Operator registers (0x30-0x8F)
            var reg: u16 = 0x30;
            while (reg <= 0x8F) : (reg += 1) {
                self.ym_sample.write(addr_port, @intCast(reg));
                self.ym_sample.write(addr_port + 1, z80.getYmRegister(p, @intCast(reg)));
            }

            // SSG-EG (0x90-0x9F)
            reg = 0x90;
            while (reg <= 0x9F) : (reg += 1) {
                self.ym_sample.write(addr_port, @intCast(reg));
                self.ym_sample.write(addr_port + 1, z80.getYmRegister(p, @intCast(reg)));
            }

            // Frequency (0xA0-0xAF): write high byte first (latch)
            var ch: u16 = 0;
            while (ch < 3) : (ch += 1) {
                self.ym_sample.write(addr_port, @intCast(0xA4 + ch));
                self.ym_sample.write(addr_port + 1, z80.getYmRegister(p, @intCast(0xA4 + ch)));
                self.ym_sample.write(addr_port, @intCast(0xA0 + ch));
                self.ym_sample.write(addr_port + 1, z80.getYmRegister(p, @intCast(0xA0 + ch)));
            }

            // Ch3 special mode frequencies (0xA8-0xAE)
            if (port == 0) {
                ch = 0;
                while (ch < 3) : (ch += 1) {
                    self.ym_sample.write(addr_port, @intCast(0xAC + ch));
                    self.ym_sample.write(addr_port + 1, z80.getYmRegister(p, @intCast(0xAC + ch)));
                    self.ym_sample.write(addr_port, @intCast(0xA8 + ch));
                    self.ym_sample.write(addr_port + 1, z80.getYmRegister(p, @intCast(0xA8 + ch)));
                }
            }

            // Algorithm/feedback (0xB0-0xB2) and pan/LFO sensitivity (0xB4-0xB6)
            reg = 0xB0;
            while (reg <= 0xB6) : (reg += 1) {
                self.ym_sample.write(addr_port, @intCast(reg));
                self.ym_sample.write(addr_port + 1, z80.getYmRegister(p, @intCast(reg)));
            }
        }

        // Replay key-on state: register 0x28 on port 0 controls all channels.
        // The shadow stores the last value written; replay it to restore
        // which operators are keyed on.
        self.ym_sample.write(0, 0x28);
        self.ym_sample.write(1, z80.getYmRegister(0, 0x28));

        // Reset blip delta tracking so the first sample after restore
        // doesn't produce a huge discontinuity pop.
        self.blip_fm_last_left = 0;
        self.blip_fm_last_right = 0;
        self.blip_psg_last_left = 0;
        self.blip_psg_last_right = 0;
        self.blip.clear();
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

    // PSG volume table is calibrated to the reference (max 2800 per
    // channel).  The gain factor is simply preamp_percent / 100,
    // matching the reference's chanAmp = preamp * panning / 100.
    // Both FM and PSG feed raw integers into the blip buffer; peaks
    // that exceed i16 range clip inside the blip buffer, matching
    // the reference behavior.
    fn blipPsgGainForVolume(self: *const AudioOutput) f32 {
        return @as(f32, @floatFromInt(self.psg_volume_percent)) / 100.0;
    }

    /// Feed FM samples from the sample-based YM2612 core into the blip buffer.
    /// Register writes and DAC updates are interleaved with sample
    /// generation based on their master clock timestamps.
    fn feedYmNativeSamplesToBlip(
        self: *AudioOutput,
        pending: PendingAudioFrames,
        ym_writes: []const YmWriteEvent,
        ym_dac_samples: []const YmDacSampleEvent,
        ym_reset_events: []const YmResetEvent,
    ) void {
        const fm_period: u32 = clock.fm_master_cycles_per_sample;
        var yw: usize = 0; // YM write cursor
        var yd: usize = 0; // DAC cursor
        var yr: usize = 0; // reset cursor
        var produced: u32 = 0;

        while (produced < pending.fm_frames) {
            const master_time: u32 = pending.fm_start_remainder + produced * fm_period;
            const next_boundary: u32 = master_time + fm_period;

            // Apply all events that fall before this sample boundary.
            while (true) {
                // Find the next event (write, DAC, or reset) by timestamp.
                var best_offset: u32 = next_boundary;
                var best_kind: ?YmEventKind = null;

                if (yw < ym_writes.len and ym_writes[yw].master_offset < next_boundary) {
                    if (ym_writes[yw].master_offset < best_offset or best_kind == null) {
                        best_offset = ym_writes[yw].master_offset;
                        best_kind = .write;
                    }
                }
                if (yd < ym_dac_samples.len and ym_dac_samples[yd].master_offset < next_boundary) {
                    if (ym_dac_samples[yd].master_offset < best_offset or best_kind == null) {
                        best_offset = ym_dac_samples[yd].master_offset;
                        best_kind = .dac;
                    }
                }
                if (yr < ym_reset_events.len and ym_reset_events[yr].master_offset < next_boundary) {
                    if (ym_reset_events[yr].master_offset < best_offset or best_kind == null) {
                        best_offset = ym_reset_events[yr].master_offset;
                        best_kind = .reset;
                    }
                }

                const kind = best_kind orelse break;
                switch (kind) {
                    .write => {
                        const ev = ym_writes[yw];
                        // Port 0: address on port 0, data on port 1
                        // Port 1: address on port 2, data on port 3
                        const addr_port: u2 = @as(u2, @intCast(ev.port & 1)) * 2;
                        self.ym_sample.write(addr_port, ev.reg);
                        self.ym_sample.write(addr_port + 1, ev.value);
                        yw += 1;
                    },
                    .dac => {
                        const ev = ym_dac_samples[yd];
                        self.ym_sample.write(@as(u2, 0), 0x2A);
                        self.ym_sample.write(@as(u2, 1), ev.value);
                        yd += 1;
                    },
                    .reset => {
                        self.ym_sample.reset();
                        yr += 1;
                    },
                }
            }

            // Generate one FM sample from the sample-based core.
            const sample = self.ym_sample.update();

            var cur_l: i32 = sample[0];
            var cur_r: i32 = sample[1];

            if (self.render_mode == .psg_only) {
                cur_l = 0;
                cur_r = 0;
            }

            // Feed delta into blip buffer.
            const dl = cur_l - self.blip_fm_last_left;
            const dr = cur_r - self.blip_fm_last_right;
            self.blip_fm_last_left = cur_l;
            self.blip_fm_last_right = cur_r;
            self.blip.addDelta(master_time, dl, dr);

            self.last_ym_left = @as(f32, @floatFromInt(cur_l)) / 49152.0;
            self.last_ym_right = @as(f32, @floatFromInt(cur_r)) / 49152.0;

            produced += 1;
        }

        // Apply any remaining events past the last sample boundary.
        while (yw < ym_writes.len) : (yw += 1) {
            const ev = ym_writes[yw];
            const ap: u2 = @as(u2, @intCast(ev.port & 1)) * 2;
            self.ym_sample.write(ap, ev.reg);
            self.ym_sample.write(ap + 1, ev.value);
        }
        while (yd < ym_dac_samples.len) : (yd += 1) {
            const ev = ym_dac_samples[yd];
            self.ym_sample.write(@as(u2, 0), 0x2A);
            self.ym_sample.write(@as(u2, 1), ev.value);
        }
        while (yr < ym_reset_events.len) : (yr += 1) {
            self.ym_sample.reset();
        }
    }

    /// Feed PSG output into the blip buffer using per-transition deltas.
    /// Instead of generating averaged samples at PSG native rate, step the
    /// PSG clock-by-clock and inject a blip delta at the exact master cycle
    /// when a channel's output level changes (polarity flip or volume
    /// change).  This matches the reference approach and produces cleaner
    /// band-limited output from the blip buffer's sinc kernel.
    fn feedPsgNativeSamplesToBlip(
        self: *AudioOutput,
        pending: PendingAudioFrames,
        psg_commands: []const PsgCommandEvent,
    ) void {
        const psg_gain = self.blipPsgGainForVolume();
        const psg_clock: u32 = clock.psg_master_cycles_per_sample;
        var psg_cmd_cursor: usize = 0;
        var master_cursor: u32 = 0;
        var produced: u32 = 0;

        while (produced < pending.psg_frames) {
            const master_time: u32 = pending.psg_start_remainder + produced * psg_clock;

            while (psg_cmd_cursor < psg_commands.len and psg_commands[psg_cmd_cursor].master_offset <= master_cursor) : (psg_cmd_cursor += 1) {
                self.psg.doCommand(psg_commands[psg_cmd_cursor].value);
                // Volume/frequency change: emit delta at command time.
                self.emitPsgBlipDelta(master_time, psg_gain);
            }

            // Step PSG one clock and check for transitions.
            self.psg.advanceOneSample();
            self.last_psg_sample_left = self.psg.currentStereoSample().left;
            self.last_psg_sample_right = self.psg.currentStereoSample().right;

            // Emit delta if the PSG output level changed after this step.
            self.emitPsgBlipDelta(master_time, psg_gain);

            master_cursor = master_time + psg_clock;
            produced += 1;
        }

        while (psg_cmd_cursor < psg_commands.len) : (psg_cmd_cursor += 1) {
            self.psg.doCommand(psg_commands[psg_cmd_cursor].value);
        }
    }

    fn emitPsgBlipDelta(self: *AudioOutput, master_time: u32, psg_gain: f32) void {
        const sample = self.psg.currentStereoSample();
        var cur_l: i32 = 0;
        var cur_r: i32 = 0;
        if (self.render_mode != .ym_only) {
            cur_l = @intFromFloat(@as(f32, @floatFromInt(sample.left)) * psg_gain);
            cur_r = @intFromFloat(@as(f32, @floatFromInt(sample.right)) * psg_gain);
        }

        const dl = cur_l - self.blip_psg_last_left;
        const dr = cur_r - self.blip_psg_last_right;
        if ((dl | dr) != 0) {
            self.blip_psg_last_left = cur_l;
            self.blip_psg_last_right = cur_r;
            self.blip.addDelta(master_time, dl, dr);
        }
    }

    fn finishBlipFrame(self: *AudioOutput, sample_l: i16, sample_r: i16) [2]i16 {
        // Apply the Genesis mainboard analog low-pass filter after the
        // blip buffer.  The blip buffer handles band-limiting at the
        // Nyquist frequency, but the real hardware has an additional
        // analog LPF (fc ≈ 4 kHz) that shapes the output.  The
        // reference also applies this filter in audio_update().
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

        return .{
            @as(i16, @intFromFloat(std.math.clamp(l * 32767.0, -32767.0, 32767.0))),
            @as(i16, @intFromFloat(std.math.clamp(r * 32767.0, -32767.0, 32767.0))),
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

test "psg commands produce nonzero blip output before mute" {
    // Validate that PSG commands produce audible output in the blip
    // buffer path.  The old renderChunk path averages bipolar PSG
    // samples to near-zero; the blip path correctly uses per-transition
    // deltas.
    var output = AudioOutput{};
    var z80 = Z80.init();
    defer z80.deinit();

    z80.writeByte(0x7F11, 0x90); // Tone 0 attenuation = 0
    z80.writeByte(0x7F11, 0x81); // Tone 0 period low = 1
    z80.writeByte(0x7F11, 0x00); // Tone 0 period high = 0

    const pending = pendingWindow(@as(u32, 512) * clock.psg_master_cycles_per_sample);
    const CollectSink = struct {
        samples: [512]i16 = undefined,
        len: usize = 0,
        fn consumeSamples(self: *@This(), input: []const i16) !void {
            const n = @min(input.len, self.samples.len - self.len);
            @memcpy(self.samples[self.len .. self.len + n], input[0..n]);
            self.len += n;
        }
    };
    var sink = CollectSink{};
    try output.renderPending(pending, &z80, false, &sink);
    try std.testing.expect(sampleEnergy(sink.samples[0..sink.len]) > 0);
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

    try output.renderPending(pending, &z80, false, &sink);

    var ym_writes: [1]YmWriteEvent = undefined;
    var ym_dac_samples: [1]YmDacSampleEvent = undefined;
    var psg_commands: [1]PsgCommandEvent = undefined;
    try std.testing.expectEqual(@as(usize, 0), z80.takeYmWrites(ym_writes[0..]));
    try std.testing.expectEqual(@as(usize, 0), z80.takeYmDacSamples(ym_dac_samples[0..]));
    try std.testing.expectEqual(@as(usize, 0), z80.takePsgCommands(psg_commands[0..]));

    try std.testing.expect(output.ym_sample.dacen);
    try std.testing.expect(output.ym_sample.dacout != 0);
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

test "queue budget helpers clamp and size supported audio latency budgets" {
    try std.testing.expect(AudioOutput.isValidQueueBudgetMs(AudioOutput.default_queue_budget_ms));
    try std.testing.expect(!AudioOutput.isValidQueueBudgetMs(AudioOutput.min_queue_budget_ms - 1));
    try std.testing.expectEqual(AudioOutput.min_queue_budget_ms, AudioOutput.clampQueueBudgetMs(1));
    try std.testing.expectEqual(AudioOutput.max_queue_budget_ms, AudioOutput.clampQueueBudgetMs(255));
    try std.testing.expect(AudioOutput.queueBudgetBytes(AudioOutput.max_queue_budget_ms) >= AudioOutput.queueBudgetBytes(AudioOutput.default_queue_budget_ms));
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

test "blip fm typical output stays within i16 range" {
    // Typical FM output (single channel, moderate level) should not clip
    // in the blip buffer.  Raw FM values are accumulated_sum * 11; a
    // single channel at moderate level produces ~5000.
    const blip_buf_mod = @import("blip_buf.zig");
    var buf = blip_buf_mod.BlipBuf(4800){};
    buf.setRates(53693175.0, 48000.0);

    // Moderate single-channel FM step.
    buf.addDelta(0, 5000, 5000);
    buf.addDelta(500, -5000, -5000);
    buf.endFrame(1000);

    var out: [100]i16 = undefined;
    const read = buf.readSamples(out[0..], buf.samplesAvail());

    var clipped = false;
    for (out[0 .. read * 2]) |s| {
        if (s == 32767 or s == -32768) clipped = true;
    }
    try std.testing.expect(!clipped);
}
