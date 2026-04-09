const std = @import("std");
const testing = std.testing;
const Psg = @import("../audio/psg.zig").Psg;
const sms_clock = @import("clock.zig");

/// SMS audio output: PSG-only pipeline.
/// Renders SN76489 output to interleaved stereo i16 at 48 kHz.
pub const SmsAudio = struct {
    psg: Psg = Psg{},

    // PSG command buffer (timestamped for accurate rendering)
    psg_commands: [4096]PsgCommand = undefined,
    psg_command_count: u16 = 0,

    // Accumulator for sample timing
    sample_counter: u32 = 0,

    pub const output_rate: u32 = 48_000;
    pub const channels: usize = 2;

    pub const PsgCommand = struct {
        z80_cycle: u32,
        value: u8,
    };

    pub fn init() SmsAudio {
        var audio = SmsAudio{};
        audio.psg = Psg.powerOn();
        return audio;
    }

    pub fn reset(self: *SmsAudio) void {
        self.psg = Psg.powerOn();
        self.psg_command_count = 0;
        self.sample_counter = 0;
    }

    pub fn pushPsgCommand(self: *SmsAudio, z80_cycle: u32, value: u8) void {
        if (self.psg_command_count < self.psg_commands.len) {
            self.psg_commands[self.psg_command_count] = .{ .z80_cycle = z80_cycle, .value = value };
            self.psg_command_count += 1;
        }
    }

    /// Render one frame of audio into the output buffer.
    /// Returns the number of stereo sample pairs written.
    pub fn renderFrame(self: *SmsAudio, is_pal: bool, output: []i16) usize {
        const z80_clock: u32 = if (is_pal)
            sms_clock.pal_master_clock / sms_clock.z80_divider
        else
            sms_clock.ntsc_master_clock / sms_clock.z80_divider;

        const total_lines: u32 = if (is_pal) sms_clock.pal_lines_per_frame else sms_clock.ntsc_lines_per_frame;
        const z80_cycles_frame = total_lines * sms_clock.z80_cycles_per_line;

        // Simple approach: render PSG at native rate, downsample to 48kHz
        // PSG advances once every 16 Z80 cycles
        const psg_samples_per_frame = z80_cycles_frame / sms_clock.psg_divider;

        var samples_written: usize = 0;
        var cmd_idx: u16 = 0;
        var z80_cycle: u32 = 0;

        for (0..psg_samples_per_frame) |_| {
            // Apply any pending PSG commands up to this cycle
            const psg_cycle = z80_cycle;
            while (cmd_idx < self.psg_command_count and
                self.psg_commands[cmd_idx].z80_cycle <= psg_cycle)
            {
                self.psg.doCommand(self.psg_commands[cmd_idx].value);
                cmd_idx += 1;
            }

            const sample = self.psg.nextStereoSample();
            z80_cycle += sms_clock.psg_divider;

            // Accumulate and output at 48kHz
            self.sample_counter += output_rate;
            if (self.sample_counter >= z80_clock / sms_clock.psg_divider) {
                self.sample_counter -= z80_clock / sms_clock.psg_divider;
                const out_idx = samples_written * 2;
                if (out_idx + 1 < output.len) {
                    output[out_idx] = sample.left;
                    output[out_idx + 1] = sample.right;
                    samples_written += 1;
                }
            }
        }

        // Apply any remaining commands
        while (cmd_idx < self.psg_command_count) {
            self.psg.doCommand(self.psg_commands[cmd_idx].value);
            cmd_idx += 1;
        }

        self.psg_command_count = 0;
        return samples_written;
    }
};

test "sms audio init and render silence" {
    var audio = SmsAudio.init();
    var buf = [_]i16{0} ** 2048;
    const samples = audio.renderFrame(false, &buf);
    try testing.expect(samples > 0);
    // With default PSG state (all attenuated), output should be near-silent
}
