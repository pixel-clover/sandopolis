//! Ricoh RF5C164 PCM sound source: 8 channels of 8-bit sign-magnitude
//! samples from 64KB of wave RAM, mixed at 12.5 MHz / 384 = 32,552 Hz.
//!
//! Sub-CPU window 0xFF0000-0xFF3FFF (odd bytes only):
//!   0x0001 ENV   channel volume            0x0003 PAN  L nibble | R nibble << 4
//!   0x0005 FDL   frequency delta low       0x0007 FDH  frequency delta high
//!   0x0009 LSL   loop start low            0x000B LSH  loop start high
//!   0x000D ST    start address high byte   0x000F CTRL bit7 on, bit6 MOD,
//!                                                       MOD=1: bits 2-0 channel
//!                                                       MOD=0: bits 3-0 wave bank
//!   0x0011 ON/OFF mask (bit n = 1 turns channel n off)
//!   0x0021-0x003F  read-only address counters (byte address, L then H per channel)
//!   0x2001-0x3FFF  4KB wave RAM window into the selected bank

const std = @import("std");

pub const channel_count: usize = 8;
pub const wave_ram_bytes: u32 = 64 * 1024;
pub const bank_bytes: u32 = 4 * 1024;
/// Address counters carry 11 fractional bits.
pub const address_fraction_bits: u5 = 11;
/// Sample byte that marks the end of a waveform (jump to loop start).
pub const loop_marker: u8 = 0xFF;

pub const Channel = struct {
    env: u8 = 0,
    pan: u8 = 0,
    fd: u16 = 0,
    ls: u16 = 0,
    st: u8 = 0,
    /// 27-bit address counter (16 integer + 11 fractional bits).
    addr: u32 = 0,
    on: bool = false,
};

pub const Pcm = struct {
    ram: [wave_ram_bytes]u8 = [_]u8{0} ** wave_ram_bytes,
    channels: [channel_count]Channel = [_]Channel{.{}} ** channel_count,
    enabled: bool = false,
    selected_channel: u3 = 0,
    bank: u4 = 0,
    /// Last mixed sample, for meters and tests.
    last_sample: [2]i16 = .{ 0, 0 },

    pub fn reset(self: *Pcm) void {
        const ram = self.ram;
        self.* = .{};
        self.ram = ram;
    }

    // -- Register / RAM access (window-relative offset, odd bytes) ----------

    pub fn read8(self: *const Pcm, offset: u32) u8 {
        const off = offset & 0x3FFF;
        if ((off & 1) == 0) return 0;
        if (off >= 0x2000) {
            return self.ram[(@as(u32, self.bank) * bank_bytes) + ((off - 0x2001) >> 1)];
        }
        if (off >= 0x0021 and off <= 0x003F) {
            const index = (off - 0x0021) >> 1; // 0..15
            const ch = &self.channels[index >> 1];
            const byte_addr: u16 = @truncate(ch.addr >> address_fraction_bits);
            return if ((index & 1) == 0) @truncate(byte_addr) else @truncate(byte_addr >> 8);
        }
        return 0;
    }

    pub fn write8(self: *Pcm, offset: u32, value: u8) void {
        const off = offset & 0x3FFF;
        if ((off & 1) == 0) return;
        if (off >= 0x2000) {
            self.ram[(@as(u32, self.bank) * bank_bytes) + ((off - 0x2001) >> 1)] = value;
            return;
        }
        const ch = &self.channels[self.selected_channel];
        switch (off) {
            0x0001 => ch.env = value,
            0x0003 => ch.pan = value,
            0x0005 => ch.fd = (ch.fd & 0xFF00) | value,
            0x0007 => ch.fd = (ch.fd & 0x00FF) | (@as(u16, value) << 8),
            0x0009 => ch.ls = (ch.ls & 0xFF00) | value,
            0x000B => ch.ls = (ch.ls & 0x00FF) | (@as(u16, value) << 8),
            0x000D => {
                ch.st = value;
                // The start address is latched into a stopped channel's
                // counter so key-on begins there.
                if (!ch.on) ch.addr = @as(u32, value) << (8 + address_fraction_bits);
            },
            0x000F => {
                self.enabled = (value & 0x80) != 0;
                if ((value & 0x40) != 0) {
                    self.selected_channel = @truncate(value & 0x07);
                } else {
                    self.bank = @truncate(value & 0x0F);
                }
            },
            0x0011 => {
                for (&self.channels, 0..) |*c, i| {
                    const off_bit = (value >> @intCast(i)) & 1 == 1;
                    const was_on = c.on;
                    c.on = !off_bit;
                    if (c.on and !was_on) c.addr = @as(u32, c.st) << (8 + address_fraction_bits);
                }
            },
            else => {},
        }
    }

    // -- Synthesis -----------------------------------------------------------

    /// Produce one stereo sample (called every 384 sub-CPU cycles).
    pub fn clockSample(self: *Pcm) [2]i16 {
        if (!self.enabled) {
            self.last_sample = .{ 0, 0 };
            return self.last_sample;
        }
        var left: i32 = 0;
        var right: i32 = 0;
        for (&self.channels) |*ch| {
            if (!ch.on) continue;
            var data = self.ram[(ch.addr >> address_fraction_bits) & (wave_ram_bytes - 1)];
            if (data == loop_marker) {
                ch.addr = @as(u32, ch.ls) << address_fraction_bits;
                data = self.ram[ch.ls];
                if (data == loop_marker) continue; // empty loop: silence
            }
            const magnitude: i32 = @as(i32, data & 0x7F) * @as(i32, ch.env);
            const l = (magnitude * @as(i32, ch.pan & 0x0F)) >> 5;
            const r = (magnitude * @as(i32, ch.pan >> 4)) >> 5;
            if ((data & 0x80) != 0) {
                left += l;
                right += r;
            } else {
                left -= l;
                right -= r;
            }
            ch.addr = (ch.addr + ch.fd) & ((@as(u32, 1) << (16 + address_fraction_bits)) - 1);
        }
        self.last_sample = .{
            @intCast(std.math.clamp(left, -32768, 32767)),
            @intCast(std.math.clamp(right, -32768, 32767)),
        };
        return self.last_sample;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn selectChannel(pcm: *Pcm, ch: u3) void {
    pcm.write8(0x000F, 0xC0 | @as(u8, ch)); // enabled, MOD=1
}

test "wave ram window follows the selected bank" {
    var pcm = Pcm{};
    pcm.write8(0x000F, 0x80 | 0x3); // MOD=0: bank 3
    pcm.write8(0x2001, 0xAB);
    pcm.write8(0x3FFF, 0xCD);
    try testing.expectEqual(@as(u8, 0xAB), pcm.ram[3 * bank_bytes]);
    try testing.expectEqual(@as(u8, 0xCD), pcm.ram[3 * bank_bytes + 0xFFF]);
    try testing.expectEqual(@as(u8, 0xAB), pcm.read8(0x2001));
    // Even bytes are not connected.
    pcm.write8(0x2000, 0x11);
    try testing.expectEqual(@as(u8, 0), pcm.read8(0x2000));
    try testing.expectEqual(@as(u8, 0xAB), pcm.ram[3 * bank_bytes]);
}

test "a channel plays a ramp at unit speed and loops at the marker" {
    var pcm = Pcm{};
    // Waveform at 0x0100: 4 positive samples 0x81..0x84 then the marker;
    // loop start points at 0x0102.
    pcm.ram[0x100] = 0x81;
    pcm.ram[0x101] = 0x82;
    pcm.ram[0x102] = 0x83;
    pcm.ram[0x103] = 0x84;
    pcm.ram[0x104] = loop_marker;

    selectChannel(&pcm, 0);
    pcm.write8(0x0001, 0xFF); // ENV max
    pcm.write8(0x0003, 0xFF); // PAN full both
    pcm.write8(0x0005, 0x00); // FD = 0x0800 -> 1.0 byte per sample
    pcm.write8(0x0007, 0x08);
    pcm.write8(0x0009, 0x02); // LS = 0x0102
    pcm.write8(0x000B, 0x01);
    pcm.write8(0x000D, 0x01); // ST = 0x01 -> 0x0100
    pcm.write8(0x0011, 0xFE); // channel 0 on

    // magnitude * env * pan >> 5 = m * 255 * 15 >> 5
    const expect = struct {
        fn level(m: i32) i16 {
            return @intCast((m * 255 * 15) >> 5);
        }
    };
    try testing.expectEqual(expect.level(1), pcm.clockSample()[0]);
    try testing.expectEqual(expect.level(2), pcm.clockSample()[1]);
    try testing.expectEqual(expect.level(3), pcm.clockSample()[0]);
    try testing.expectEqual(expect.level(4), pcm.clockSample()[0]);
    // Marker: jump to LS (0x0102) and play from there.
    try testing.expectEqual(expect.level(3), pcm.clockSample()[0]);
    try testing.expectEqual(expect.level(4), pcm.clockSample()[0]);
    try testing.expectEqual(expect.level(3), pcm.clockSample()[0]);
    // Address counter readback: channel 0 at 0x0103 after that sample.
    try testing.expectEqual(@as(u8, 0x03), pcm.read8(0x0021));
    try testing.expectEqual(@as(u8, 0x01), pcm.read8(0x0023));
}

test "sign bit, panning, envelope, and channel/chip enables" {
    var pcm = Pcm{};
    pcm.ram[0x0000] = 0x7F; // negative full scale
    pcm.ram[0x0001] = 0x7F;
    selectChannel(&pcm, 1);
    pcm.write8(0x0001, 0x80);
    pcm.write8(0x0003, 0x0F); // left only
    pcm.write8(0x0005, 0x00);
    pcm.write8(0x0007, 0x08);
    pcm.write8(0x000D, 0x00);
    pcm.write8(0x0011, 0xFD); // channel 1 on
    const s = pcm.clockSample();
    try testing.expectEqual(@as(i16, -((127 * 128 * 15) >> 5)), s[0]);
    try testing.expectEqual(@as(i16, 0), s[1]);

    // Turning the channel off silences it; turning it back on restarts at ST.
    pcm.write8(0x0011, 0xFF);
    try testing.expectEqual(@as(i16, 0), pcm.clockSample()[0]);
    pcm.write8(0x000D, 0x01); // ST -> 0x0100 while off
    pcm.ram[0x0100] = 0x81;
    pcm.write8(0x0011, 0xFD);
    try testing.expectEqual(@as(i16, (1 * 128 * 15) >> 5), pcm.clockSample()[0]);

    // Chip disabled: silence and counters hold.
    pcm.write8(0x000F, 0x40 | 1);
    const addr_before = pcm.channels[1].addr;
    try testing.expectEqual(@as(i16, 0), pcm.clockSample()[0]);
    try testing.expectEqual(addr_before, pcm.channels[1].addr);
}

test "eight saturated channels clamp to 16 bits" {
    var pcm = Pcm{};
    pcm.ram[0] = 0xFF - 0; // marker would loop; use 0xFE (max positive) instead
    pcm.ram[0] = 0xFE;
    var ch: u8 = 0;
    while (ch < 8) : (ch += 1) {
        selectChannel(&pcm, @intCast(ch));
        pcm.write8(0x0001, 0xFF);
        pcm.write8(0x0003, 0xFF);
        pcm.write8(0x0005, 0x00);
        pcm.write8(0x0007, 0x00); // FD = 0: stay on byte 0
        pcm.write8(0x000D, 0x00);
    }
    pcm.write8(0x0011, 0x00);
    const s = pcm.clockSample();
    try testing.expectEqual(@as(i16, 32767), s[0]);
    try testing.expectEqual(@as(i16, 32767), s[1]);
}
