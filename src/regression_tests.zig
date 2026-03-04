const std = @import("std");
const testing = std.testing;
const clock = @import("clock.zig");
const Bus = @import("memory.zig").Bus;
const Cpu = @import("cpu/cpu.zig").Cpu;

test "cpu reset applies fallback vectors when ROM vectors are invalid" {
    var bus = try Bus.init(testing.allocator, null);
    defer bus.deinit(testing.allocator);

    // Invalid stack vector, valid entrypoint vector.
    std.mem.writeInt(u32, bus.rom[0..4], 0x0000_0000, .big);
    std.mem.writeInt(u32, bus.rom[4..8], 0x0000_0200, .big);

    var cpu = Cpu.init();
    cpu.reset(&bus);

    try testing.expectEqual(@as(u32, 0x00FF_FE00), @as(u32, cpu.core.a_regs[7].l));
    try testing.expectEqual(@as(u32, 0x0000_0200), @as(u32, cpu.core.pc));
}

test "z80 bus mapped memory and busreq registers behave as expected" {
    var bus = try Bus.init(testing.allocator, null);
    defer bus.deinit(testing.allocator);

    // Without BUSREQ, 68k should not see/modify Z80 window.
    bus.write8(0x00A0_0010, 0x5A);
    try testing.expectEqual(@as(u8, 0xFF), bus.read8(0x00A0_0010));

    bus.write16(0x00A1_1100, 0x0000); // Request Z80 bus
    try testing.expectEqual(@as(u16, 0x0000), bus.read16(0x00A1_1100));

    bus.write8(0x00A0_0010, 0x5A);
    try testing.expectEqual(@as(u8, 0x5A), bus.read8(0x00A0_0010));

    bus.write16(0x00A1_1100, 0x0100); // Release Z80 bus
    try testing.expectEqual(@as(u16, 0x0100), bus.read16(0x00A1_1100));

    // Once released, 68k window should be blocked again.
    bus.write8(0x00A0_0010, 0xA5);
    try testing.expectEqual(@as(u8, 0xFF), bus.read8(0x00A0_0010));
}

test "audio timing accrues FM/PSG native-rate frames from master cycles" {
    var bus = try Bus.init(testing.allocator, null);
    defer bus.deinit(testing.allocator);

    bus.stepMaster(clock.ntsc_master_cycles_per_frame);
    const frames = bus.audio_timing.takePending();

    // 896040 / 1008 = 888 FM frames, remainder 936
    try testing.expectEqual(@as(u32, 888), frames.fm_frames);
    try testing.expectEqual(@as(u16, 936), bus.audio_timing.fm_master_remainder);

    // 896040 / 240 = 3733 PSG frames, remainder 120
    try testing.expectEqual(@as(u32, 3733), frames.psg_frames);
    try testing.expectEqual(@as(u16, 120), bus.audio_timing.psg_master_remainder);
}

test "z80 audio window latches YM2612 and PSG writes" {
    var bus = try Bus.init(testing.allocator, null);
    defer bus.deinit(testing.allocator);

    bus.write16(0x00A1_1100, 0x0000); // Request Z80 bus

    // YM2612 port 0: addr then data
    bus.write8(0x00A0_4000, 0x22);
    bus.write8(0x00A0_4001, 0x0F);
    try testing.expectEqual(@as(u8, 0x0F), bus.z80.getYmRegister(0, 0x22));

    // YM2612 port 1: addr then data
    bus.write8(0x00A0_4002, 0x2B);
    bus.write8(0x00A0_4003, 0x80);
    try testing.expectEqual(@as(u8, 0x80), bus.z80.getYmRegister(1, 0x2B));

    // PSG latch/data byte
    bus.write8(0x00A0_7F11, 0x90);
    try testing.expectEqual(@as(u8, 0x90), bus.z80.getPsgLast());
}

test "psg latch/data writes decode tone and volume registers" {
    var bus = try Bus.init(testing.allocator, null);
    defer bus.deinit(testing.allocator);

    bus.write16(0x00A1_1100, 0x0000); // Request Z80 bus

    // Tone channel 0: latch low nibble, then data high bits.
    bus.write8(0x00A0_7F11, 0x80 | 0x0A); // ch0 tone low=0xA
    bus.write8(0x00A0_7F11, 0x15); // high 6 bits
    try testing.expectEqual(@as(u16, 0x15A), bus.z80.getPsgTone(0));

    // Volume channel 2 attenuation.
    bus.write8(0x00A0_7F11, 0xC0 | 0x10 | 0x07); // ch2 volume=7
    try testing.expectEqual(@as(u8, 0x07), bus.z80.getPsgVolume(2));

    // Noise register write.
    bus.write8(0x00A0_7F11, 0xE0 | 0x03);
    try testing.expectEqual(@as(u8, 0x03), bus.z80.getPsgNoise());
}

test "ym key-on register updates channel key mask" {
    var bus = try Bus.init(testing.allocator, null);
    defer bus.deinit(testing.allocator);

    bus.write16(0x00A1_1100, 0x0000); // Request Z80 bus

    // Key on channel 0 (operators set in upper nibble).
    bus.write8(0x00A0_4000, 0x28);
    bus.write8(0x00A0_4001, 0xF0);
    try testing.expectEqual(@as(u8, 0x01), bus.z80.getYmKeyMask());

    // Key on channel 4 (ch=1 with high-bank bit set).
    bus.write8(0x00A0_4000, 0x28);
    bus.write8(0x00A0_4001, 0xF5);
    try testing.expectEqual(@as(u8, 0x11), bus.z80.getYmKeyMask());

    // Key off channel 0.
    bus.write8(0x00A0_4000, 0x28);
    bus.write8(0x00A0_4001, 0x00);
    try testing.expectEqual(@as(u8, 0x10), bus.z80.getYmKeyMask());
}

test "z80 bank register selects 68k ROM window" {
    var bus = try Bus.init(testing.allocator, null);
    defer bus.deinit(testing.allocator);

    // Populate distinct bytes in ROM bank 0 and bank 1.
    bus.rom[0x0000] = 0x12;
    bus.rom[0x8000] = 0x34;

    bus.write16(0x00A1_1100, 0x0000); // Request Z80 bus

    // Default bank is 0, so Z80 0x8000 maps to 68k 0x000000.
    try testing.expectEqual(@as(u8, 0x12), bus.read8(0x00A0_8000));

    // Bank register is 9-bit serial, shifted by writes to 0x6000..0x60FF.
    // Program bank=1 by writing bit0=1 followed by zeros for remaining bits.
    bus.write8(0x00A0_6000, 1);
    for (0..8) |_| {
        bus.write8(0x00A0_6000, 0);
    }

    try testing.expectEqual(@as(u16, 1), bus.z80.getBank());
    try testing.expectEqual(@as(u8, 0x34), bus.read8(0x00A0_8000));
}
