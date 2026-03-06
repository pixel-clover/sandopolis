const std = @import("std");
const zsdl3 = @import("zsdl3");
const clock = @import("clock.zig");
const PendingAudioFrames = @import("audio_timing.zig").PendingAudioFrames;
const Z80 = @import("z80.zig").Z80;
const YmWriteEvent = Z80.YmWriteEvent;
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
    const max_ym_writes_per_push: usize = 32768;
    const max_psg_commands_per_push: usize = 8192;

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
    psg_command_buffer: [max_psg_commands_per_push]u8 = undefined,
    ym_shadow_regs: [2][256]u8 = [_][256]u8{[_]u8{0} ** 256} ** 2,
    ym_key_mask_shadow: u8 = 0,
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
        const mapping = AudioOutput.ymPortAndChannelBase(channel);
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

    fn ymDacEnabled(z80: *const Z80) bool {
        return (z80.getYmRegister(0, 0x2B) & 0x80) != 0;
    }

    fn ymDacByteToSample(sample: u8) f32 {
        return (@as(f32, @floatFromInt(sample)) - 128.0) / 128.0;
    }

    fn ymDacCurrentSample(z80: *const Z80) f32 {
        return ymDacByteToSample(z80.getYmRegister(0, 0x2A));
    }

    fn ymOperatorRegisterFromShadow(self: *const AudioOutput, channel: u3, reg_base: u8, operator: u2) u8 {
        const mapping = AudioOutput.ymPortAndChannelBase(channel);
        return self.ym_shadow_regs[mapping.port][reg_base + ym_operator_offsets[operator] + mapping.base];
    }

    fn ymAttackStepFromShadow(self: *const AudioOutput, channel: u3) f32 {
        const attack_rate = self.ymOperatorRegisterFromShadow(channel, 0x50, 3) & 0x1F;
        return 0.0001 + (@as(f32, @floatFromInt(attack_rate)) / 31.0) * 0.01;
    }

    fn ymReleaseStepFromShadow(self: *const AudioOutput, channel: u3) f32 {
        const release_rate = self.ymOperatorRegisterFromShadow(channel, 0x80, 3) & 0x0F;
        return 0.00002 + (@as(f32, @floatFromInt(release_rate)) / 15.0) * 0.002;
    }

    fn ymDacEnabledFromShadow(self: *const AudioOutput) bool {
        return (self.ym_shadow_regs[0][0x2B] & 0x80) != 0;
    }

    fn ymDacCurrentSampleFromShadow(self: *const AudioOutput) f32 {
        return ymDacByteToSample(self.ym_shadow_regs[0][0x2A]);
    }

    fn ymTargetGainFromShadow(self: *const AudioOutput, channel: u3) f32 {
        const keyed_on = (self.ym_key_mask_shadow & (@as(u8, 1) << @intCast(channel))) != 0;
        if (!keyed_on) return 0.0;
        if (self.ymDacEnabledFromShadow() and channel == 5) return 0.0;

        const carrier_tl = self.ymOperatorRegisterFromShadow(channel, 0x40, 3);
        const mapping = AudioOutput.ymPortAndChannelBase(channel);
        const algorithm_feedback = self.ym_shadow_regs[mapping.port][0xB0 + mapping.base];
        const algorithm = algorithm_feedback & 0x07;
        const feedback = (algorithm_feedback >> 3) & 0x07;

        var gain = 0.05 * ymTotalLevelToGain(carrier_tl);
        gain *= 1.0 + @as(f32, @floatFromInt(algorithm)) * 0.04;
        gain *= 1.0 + @as(f32, @floatFromInt(feedback)) * 0.03;
        return gain;
    }

    fn fmFrequencyFromShadow(self: *const AudioOutput, channel: u3) f32 {
        const mapping = ymPortAndChannelBase(channel);
        const fnum_low = self.ym_shadow_regs[mapping.port][0xA0 + mapping.base];
        const high = self.ym_shadow_regs[mapping.port][0xA4 + mapping.base];
        const block = (high >> 3) & 0x07;
        const fnum_high = high & 0x07;
        const fnum: u16 = (@as(u16, fnum_high) << 8) | @as(u16, fnum_low);
        if (fnum == 0) return 0.0;

        const base_hz = 0.052_7 * @as(f32, @floatFromInt(fnum));
        return base_hz * @as(f32, @floatFromInt(@as(u32, 1) << @intCast(block)));
    }

    fn fmPanFromShadow(self: *const AudioOutput, channel: u3) StereoPan {
        const mapping = ymPortAndChannelBase(channel);
        const pan = self.ym_shadow_regs[mapping.port][0xB4 + mapping.base];
        const right_on = (pan & 0x40) != 0;
        const left_on = (pan & 0x80) != 0;
        return .{
            .left = if (left_on) 1.0 else 0.0,
            .right = if (right_on) 1.0 else 0.0,
        };
    }

    fn applyYmWriteEvent(self: *AudioOutput, event: YmWriteEvent) void {
        const port: u1 = @intCast(event.port & 1);
        self.ym_shadow_regs[port][event.reg] = event.value;
        if (port == 0 and event.reg == 0x28) {
            var channel = event.value & 0x03;
            if (channel != 0x03) {
                if ((event.value & 0x04) != 0) {
                    channel +%= 3;
                }
                const channel_mask: u8 = @as(u8, 1) << @intCast(channel);
                if ((event.value & 0xF0) != 0) {
                    self.ym_key_mask_shadow |= channel_mask;
                } else {
                    self.ym_key_mask_shadow &= ~channel_mask;
                }
            }
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

    fn renderChunk(
        self: *AudioOutput,
        frames: usize,
        psg_native_frames: u32,
        ym_writes: []const YmWriteEvent,
        psg_commands: []const u8,
    ) []const i16 {
        const sample_rate: f32 = @floatFromInt(output_rate);
        const two_pi = std.math.tau;
        var psg_native_cursor: u32 = 0;
        var last_psg_sample: i16 = 0;
        var ym_write_cursor: usize = 0;
        var psg_command_cursor: usize = 0;
        var i: usize = 0;
        while (i < frames) : (i += 1) {
            const target_ym_writes: usize = @intCast((@as(u64, i + 1) * ym_writes.len) / frames);
            while (ym_write_cursor < target_ym_writes) : (ym_write_cursor += 1) {
                self.applyYmWriteEvent(ym_writes[ym_write_cursor]);
            }

            const target_psg_commands: usize = @intCast((@as(u64, i + 1) * psg_commands.len) / frames);
            while (psg_command_cursor < target_psg_commands) : (psg_command_cursor += 1) {
                self.psg.doCommand(psg_commands[psg_command_cursor]);
            }

            var l: f32 = 0.0;
            var r: f32 = 0.0;

            for (0..6) |ch| {
                const channel: u3 = @intCast(ch);
                const fm_hz = self.fmFrequencyFromShadow(channel);
                if (fm_hz <= 0.0) continue;

                const target_gain = self.ymTargetGainFromShadow(channel);
                if (self.ym_level[ch] < target_gain) {
                    self.ym_level[ch] = @min(target_gain, self.ym_level[ch] + self.ymAttackStepFromShadow(channel));
                } else if (self.ym_level[ch] > target_gain) {
                    self.ym_level[ch] = @max(target_gain, self.ym_level[ch] - self.ymReleaseStepFromShadow(channel));
                }
                if (self.ym_level[ch] <= 0.0001) continue;

                self.ym_phase[ch] += fm_hz / sample_rate;
                if (self.ym_phase[ch] >= 1.0) self.ym_phase[ch] -= 1.0;
                const voice = std.math.sin(self.ym_phase[ch] * two_pi) * self.ym_level[ch];
                const pan = self.fmPanFromShadow(channel);
                l += voice * pan.left;
                r += voice * pan.right;
            }

            if (self.ymDacEnabledFromShadow()) {
                const voice = self.ymDacCurrentSampleFromShadow() * 0.16;
                const dac_pan = self.fmPanFromShadow(5);
                l += voice * dac_pan.left;
                r += voice * dac_pan.right;
            }

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

    pub fn pushPending(self: *AudioOutput, pending: PendingAudioFrames, z80: *Z80, is_pal: bool) !void {
        self.setTimingMode(is_pal);

        const queued_bytes = zsdl3.getAudioStreamQueued(self.stream) catch return;
        if (queued_bytes >= max_queued_bytes) return;

        const fm_frames = self.fm_converter.toOutputFrames(pending.fm_frames, output_rate);
        const psg_frames = self.psg_converter.toOutputFrames(pending.psg_frames, output_rate);
        var out_frames: u32 = @max(fm_frames, psg_frames);
        if (out_frames == 0) return;

        const ym_write_count = z80.takeYmWrites(self.ym_write_buffer[0..]);
        const psg_command_count = z80.takePsgCommands(self.psg_command_buffer[0..]);

        const max_frames_per_push = self.sample_chunk.len / channels;
        var remaining_psg_native = pending.psg_frames;
        var remaining_out_frames = out_frames;
        var remaining_ym_writes = ym_write_count;
        var ym_write_offset: usize = 0;
        var remaining_psg_commands = psg_command_count;
        var psg_command_offset: usize = 0;
        while (out_frames > 0) {
            const chunk_frames: usize = @min(out_frames, max_frames_per_push);
            const chunk_out_frames: u32 = @intCast(chunk_frames);
            const chunk_psg_native: u32 = if (remaining_out_frames == chunk_frames)
                remaining_psg_native
            else
                @intCast((@as(u64, remaining_psg_native) * chunk_frames) / remaining_out_frames);
            const chunk_ym_writes: usize = if (remaining_out_frames == chunk_out_frames)
                remaining_ym_writes
            else
                @intCast((@as(u64, remaining_ym_writes) * chunk_frames) / remaining_out_frames);
            const chunk_psg_commands: usize = if (remaining_out_frames == chunk_out_frames)
                remaining_psg_commands
            else
                @intCast((@as(u64, remaining_psg_commands) * chunk_frames) / remaining_out_frames);
            const samples = self.renderChunk(
                chunk_frames,
                chunk_psg_native,
                self.ym_write_buffer[ym_write_offset .. ym_write_offset + chunk_ym_writes],
                self.psg_command_buffer[psg_command_offset .. psg_command_offset + chunk_psg_commands],
            );
            try zsdl3.putAudioStreamData(i16, self.stream, samples);
            remaining_psg_native -= chunk_psg_native;
            remaining_out_frames -= chunk_out_frames;
            remaining_ym_writes -= chunk_ym_writes;
            ym_write_offset += chunk_ym_writes;
            remaining_psg_commands -= chunk_psg_commands;
            psg_command_offset += chunk_psg_commands;
            out_frames -= chunk_out_frames;
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
    output.psg.doCommand(0x90); // ch0 volume = 0
    output.psg.doCommand(0x85); // ch0 tone low = 5
    output.psg.doCommand(0x00); // ch0 tone high = 0

    const samples = output.renderChunk(64, 256, &.{}, &.{});

    var nonzero: usize = 0;
    for (samples) |sample| {
        if (sample != 0) nonzero += 1;
    }
    try std.testing.expect(nonzero > 0);
}

test "ym dac state uses port 0 and queued samples stay audible" {
    var output = AudioOutput{
        .stream = @ptrFromInt(1),
    };
    var z80 = Z80.init();
    defer z80.deinit();

    z80.writeByte(0x4000, 0x2B);
    z80.writeByte(0x4001, 0x80);
    z80.writeByte(0x4002, 0xB6);
    z80.writeByte(0x4003, 0xC0);
    z80.writeByte(0x4000, 0x2A);
    z80.writeByte(0x4001, 0x10);
    z80.writeByte(0x4001, 0xF0);
    z80.writeByte(0x4001, 0x40);

    try std.testing.expect(AudioOutput.ymDacEnabled(&z80));
    try std.testing.expectApproxEqAbs(@as(f32, -0.5), AudioOutput.ymDacCurrentSample(&z80), 0.01);

    const ym_write_count = z80.takeYmWrites(output.ym_write_buffer[0..]);
    try std.testing.expectEqual(@as(usize, 5), ym_write_count);
    const samples = output.renderChunk(96, 0, output.ym_write_buffer[0..ym_write_count], &.{});

    var nonzero: usize = 0;
    for (samples) |sample| {
        if (sample != 0) nonzero += 1;
    }
    try std.testing.expect(nonzero > 0);
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

test "sonic boot synthesized audio chunk is nonzero" {
    const Bus = @import("memory.zig").Bus;
    const Cpu = @import("cpu/cpu.zig").Cpu;
    const frame_scheduler = @import("frame_scheduler.zig");

    var bus = try Bus.init(std.testing.allocator, "roms/sn.smd");
    defer bus.deinit(std.testing.allocator);
    var cpu = Cpu.init();
    cpu.reset(&bus);
    var m68k_sync = clock.M68kSync{};

    const visible_lines = clock.ntsc_visible_lines;
    const total_lines = clock.ntsc_lines_per_frame;
    var output = AudioOutput{ .stream = @ptrFromInt(1) };
    var total_nonzero: usize = 0;
    for (0..600) |_| {
        bus.vdp.beginFrame();
        for (0..total_lines) |line_idx| {
            const line: u16 = @intCast(line_idx);
            const entering_vblank = bus.vdp.setScanlineState(line, visible_lines, total_lines);
            if (entering_vblank and bus.vdp.isVBlankInterruptEnabled()) cpu.requestInterrupt(6);
            if (entering_vblank) bus.z80.assertIrq(0xFF);
            bus.vdp.setHBlank(false);

            const hint_master_cycles = bus.vdp.hInterruptMasterCycles();
            const hblank_start_master_cycles = bus.vdp.hblankStartMasterCycles();
            const first_event_master_cycles = @min(hint_master_cycles, hblank_start_master_cycles);
            const second_event_master_cycles = @max(hint_master_cycles, hblank_start_master_cycles);

            frame_scheduler.runMasterSlice(&bus, &cpu, &m68k_sync, first_event_master_cycles);
            if (hblank_start_master_cycles == first_event_master_cycles) bus.vdp.setHBlank(true);
            if (hint_master_cycles == first_event_master_cycles and bus.vdp.consumeHintForLine(line, visible_lines)) cpu.requestInterrupt(4);

            frame_scheduler.runMasterSlice(&bus, &cpu, &m68k_sync, second_event_master_cycles - first_event_master_cycles);
            if (hblank_start_master_cycles == second_event_master_cycles and hblank_start_master_cycles != first_event_master_cycles) bus.vdp.setHBlank(true);
            if (hint_master_cycles == second_event_master_cycles and hint_master_cycles != first_event_master_cycles and bus.vdp.consumeHintForLine(line, visible_lines)) cpu.requestInterrupt(4);

            frame_scheduler.runMasterSlice(&bus, &cpu, &m68k_sync, clock.ntsc_master_cycles_per_line - second_event_master_cycles);
            bus.vdp.setHBlank(false);
            if (entering_vblank) bus.z80.clearIrq();
        }
        bus.vdp.odd_frame = !bus.vdp.odd_frame;

        const pending = bus.audio_timing.takePending();
        const fm_frames = output.fm_converter.toOutputFrames(pending.fm_frames, AudioOutput.output_rate);
        const psg_frames = output.psg_converter.toOutputFrames(pending.psg_frames, AudioOutput.output_rate);
        var out_frames: u32 = @max(fm_frames, psg_frames);
        if (out_frames == 0) continue;

        const ym_write_count = bus.z80.takeYmWrites(output.ym_write_buffer[0..]);
        const psg_command_count = bus.z80.takePsgCommands(output.psg_command_buffer[0..]);
        const max_frames_per_push = output.sample_chunk.len / AudioOutput.channels;
        var remaining_psg_native = pending.psg_frames;
        var remaining_out_frames = out_frames;
        var remaining_ym_writes = ym_write_count;
        var ym_write_offset: usize = 0;
        var remaining_psg_commands = psg_command_count;
        var psg_command_offset: usize = 0;
        while (out_frames > 0) {
            const chunk_frames: usize = @min(out_frames, max_frames_per_push);
            const chunk_out_frames: u32 = @intCast(chunk_frames);
            const chunk_psg_native: u32 = if (remaining_out_frames == chunk_out_frames)
                remaining_psg_native
            else
                @intCast((@as(u64, remaining_psg_native) * chunk_frames) / remaining_out_frames);
            const chunk_ym_writes: usize = if (remaining_out_frames == chunk_out_frames)
                remaining_ym_writes
            else
                @intCast((@as(u64, remaining_ym_writes) * chunk_frames) / remaining_out_frames);
            const chunk_psg_commands: usize = if (remaining_out_frames == chunk_out_frames)
                remaining_psg_commands
            else
                @intCast((@as(u64, remaining_psg_commands) * chunk_frames) / remaining_out_frames);

            const samples = output.renderChunk(
                chunk_frames,
                chunk_psg_native,
                output.ym_write_buffer[ym_write_offset .. ym_write_offset + chunk_ym_writes],
                output.psg_command_buffer[psg_command_offset .. psg_command_offset + chunk_psg_commands],
            );
            for (samples) |sample| {
                if (sample != 0) total_nonzero += 1;
            }

            remaining_psg_native -= chunk_psg_native;
            remaining_out_frames -= chunk_out_frames;
            remaining_ym_writes -= chunk_ym_writes;
            ym_write_offset += chunk_ym_writes;
            remaining_psg_commands -= chunk_psg_commands;
            psg_command_offset += chunk_psg_commands;
            out_frames -= chunk_out_frames;
        }
    }

    try std.testing.expect(total_nonzero > 0);
}
