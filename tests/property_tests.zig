const std = @import("std");
const testing = std.testing;
const minish = @import("minish");
const sandopolis = @import("sandopolis_src");

const Bus = sandopolis.Bus;
const AudioTiming = sandopolis.AudioTiming;
const Io = sandopolis.Io;
const Vdp = sandopolis.Vdp;
const clock = sandopolis.clock;

const empty_rom = [_]u8{};

const AudioChunkCase = struct {
    first: u32,
    second: u32,
};

const RamByteMirrorCase = struct {
    address: u16,
    first_value: u8,
    second_value: u8,
};

const RamWordCase = struct {
    address: u16,
    value: u16,
};

const OddByteSramCase = struct {
    byte_index: u16,
    value: u8,
};

const SixteenBitSramCase = struct {
    word_index: u16,
    value: u16,
};

const SixButtonCase = struct {
    pressed_mask: u6,
};

const TickSplitCase = struct {
    first: u16,
    second: u16,
};

const BusControlCase = struct {
    open_bus: u16,
    request_bus: bool,
    reset_asserted: bool,
};

const OpenBusStatusCase = struct {
    open_bus: u16,
};

const Z80WindowCase = struct {
    open_bus: u16,
    offset: u16,
};

const UnusedVdpPortCase = struct {
    even_offset: u8,
};

const VdpStateCase = struct {
    pal_mode: bool,
    h40: bool,
    scanline: u16,
    line_master_cycle: u16,
    odd_frame: bool,
    dma_active: bool,
    vint_pending: bool,
    sprite_overflow: bool,
    sprite_collision: bool,
};

const VdpFifoCase = struct {
    write_count: u8,
    progress_master_cycles: u8,
};

const Z80WindowWriteCase = struct {
    offset: u16,
    granted_value: u8,
    blocked_value: u8,
};

const Z80ControlByteCase = struct {
    request_bus: bool,
    release_reset: bool,
    low_busreq_value: u8,
    low_reset_value: u8,
};

const audio_chunk_gen = minish.gen.Generator(AudioChunkCase){
    .generateFn = struct {
        fn generate(tc: *minish.TestCase) minish.GenError!AudioChunkCase {
            return .{
                .first = try tc.choiceInRange(u32, 0, clock.ntsc_master_cycles_per_frame * 4),
                .second = try tc.choiceInRange(u32, 0, clock.ntsc_master_cycles_per_frame * 4),
            };
        }
    }.generate,
    .shrinkFn = null,
    .freeFn = null,
};

const ram_byte_mirror_gen = minish.gen.Generator(RamByteMirrorCase){
    .generateFn = struct {
        fn generate(tc: *minish.TestCase) minish.GenError!RamByteMirrorCase {
            return .{
                .address = try tc.choiceInRange(u16, 0, std.math.maxInt(u16)),
                .first_value = try tc.choiceInRange(u8, 0, std.math.maxInt(u8)),
                .second_value = try tc.choiceInRange(u8, 0, std.math.maxInt(u8)),
            };
        }
    }.generate,
    .shrinkFn = null,
    .freeFn = null,
};

const ram_word_gen = minish.gen.Generator(RamWordCase){
    .generateFn = struct {
        fn generate(tc: *minish.TestCase) minish.GenError!RamWordCase {
            const raw_address = try tc.choiceInRange(u16, 0, 0xFFFE);
            return .{
                .address = raw_address & 0xFFFE,
                .value = try tc.choiceInRange(u16, 0, std.math.maxInt(u16)),
            };
        }
    }.generate,
    .shrinkFn = null,
    .freeFn = null,
};

const odd_byte_sram_gen = minish.gen.Generator(OddByteSramCase){
    .generateFn = struct {
        fn generate(tc: *minish.TestCase) minish.GenError!OddByteSramCase {
            return .{
                .byte_index = try tc.choiceInRange(u16, 0, 8191),
                .value = try tc.choiceInRange(u8, 0, std.math.maxInt(u8)),
            };
        }
    }.generate,
    .shrinkFn = null,
    .freeFn = null,
};

const sixteen_bit_sram_gen = minish.gen.Generator(SixteenBitSramCase){
    .generateFn = struct {
        fn generate(tc: *minish.TestCase) minish.GenError!SixteenBitSramCase {
            return .{
                .word_index = try tc.choiceInRange(u16, 0, 0x7FFF),
                .value = try tc.choiceInRange(u16, 0, std.math.maxInt(u16)),
            };
        }
    }.generate,
    .shrinkFn = null,
    .freeFn = null,
};

const six_button_gen = minish.gen.Generator(SixButtonCase){
    .generateFn = struct {
        fn generate(tc: *minish.TestCase) minish.GenError!SixButtonCase {
            return .{
                .pressed_mask = @intCast(try tc.choiceInRange(u8, 0, 0x3F)),
            };
        }
    }.generate,
    .shrinkFn = null,
    .freeFn = null,
};

const tick_split_gen = minish.gen.Generator(TickSplitCase){
    .generateFn = struct {
        fn generate(tc: *minish.TestCase) minish.GenError!TickSplitCase {
            return .{
                .first = try tc.choiceInRange(u16, 0, 13_000),
                .second = try tc.choiceInRange(u16, 0, 13_000),
            };
        }
    }.generate,
    .shrinkFn = null,
    .freeFn = null,
};

const bus_control_gen = minish.gen.Generator(BusControlCase){
    .generateFn = struct {
        fn generate(tc: *minish.TestCase) minish.GenError!BusControlCase {
            return .{
                .open_bus = try tc.choiceInRange(u16, 0, std.math.maxInt(u16)),
                .request_bus = (try tc.choiceInRange(u8, 0, 1)) != 0,
                .reset_asserted = (try tc.choiceInRange(u8, 0, 1)) != 0,
            };
        }
    }.generate,
    .shrinkFn = null,
    .freeFn = null,
};

const open_bus_status_gen = minish.gen.Generator(OpenBusStatusCase){
    .generateFn = struct {
        fn generate(tc: *minish.TestCase) minish.GenError!OpenBusStatusCase {
            return .{
                .open_bus = try tc.choiceInRange(u16, 0, std.math.maxInt(u16)),
            };
        }
    }.generate,
    .shrinkFn = null,
    .freeFn = null,
};

const z80_window_gen = minish.gen.Generator(Z80WindowCase){
    .generateFn = struct {
        fn generate(tc: *minish.TestCase) minish.GenError!Z80WindowCase {
            const raw_offset = try tc.choiceInRange(u16, 0, 0xFFFE);
            return .{
                .open_bus = try tc.choiceInRange(u16, 0, std.math.maxInt(u16)),
                .offset = raw_offset & 0xFFFE,
            };
        }
    }.generate,
    .shrinkFn = null,
    .freeFn = null,
};

const unused_vdp_port_gen = minish.gen.Generator(UnusedVdpPortCase){
    .generateFn = struct {
        fn generate(tc: *minish.TestCase) minish.GenError!UnusedVdpPortCase {
            return .{
                .even_offset = @as(u8, @intCast(0x10 + (try tc.choiceInRange(u8, 0, 7)) * 2)),
            };
        }
    }.generate,
    .shrinkFn = null,
    .freeFn = null,
};

const vdp_state_gen = minish.gen.Generator(VdpStateCase){
    .generateFn = struct {
        fn generate(tc: *minish.TestCase) minish.GenError!VdpStateCase {
            return .{
                .pal_mode = (try tc.choiceInRange(u8, 0, 1)) != 0,
                .h40 = (try tc.choiceInRange(u8, 0, 1)) != 0,
                .scanline = try tc.choiceInRange(u16, 0, clock.pal_lines_per_frame - 1),
                .line_master_cycle = try tc.choiceInRange(u16, 0, clock.ntsc_master_cycles_per_line - 1),
                .odd_frame = (try tc.choiceInRange(u8, 0, 1)) != 0,
                .dma_active = (try tc.choiceInRange(u8, 0, 1)) != 0,
                .vint_pending = (try tc.choiceInRange(u8, 0, 1)) != 0,
                .sprite_overflow = (try tc.choiceInRange(u8, 0, 1)) != 0,
                .sprite_collision = (try tc.choiceInRange(u8, 0, 1)) != 0,
            };
        }
    }.generate,
    .shrinkFn = null,
    .freeFn = null,
};

const vdp_fifo_gen = minish.gen.Generator(VdpFifoCase){
    .generateFn = struct {
        fn generate(tc: *minish.TestCase) minish.GenError!VdpFifoCase {
            return .{
                .write_count = try tc.choiceInRange(u8, 0, 6),
                .progress_master_cycles = try tc.choiceInRange(u8, 0, 64),
            };
        }
    }.generate,
    .shrinkFn = null,
    .freeFn = null,
};

const z80_window_write_gen = minish.gen.Generator(Z80WindowWriteCase){
    .generateFn = struct {
        fn generate(tc: *minish.TestCase) minish.GenError!Z80WindowWriteCase {
            return .{
                .offset = try tc.choiceInRange(u16, 0, 0x1FFF),
                .granted_value = try tc.choiceInRange(u8, 0, std.math.maxInt(u8)),
                .blocked_value = try tc.choiceInRange(u8, 0, std.math.maxInt(u8)),
            };
        }
    }.generate,
    .shrinkFn = null,
    .freeFn = null,
};

const z80_control_byte_gen = minish.gen.Generator(Z80ControlByteCase){
    .generateFn = struct {
        fn generate(tc: *minish.TestCase) minish.GenError!Z80ControlByteCase {
            return .{
                .request_bus = (try tc.choiceInRange(u8, 0, 1)) != 0,
                .release_reset = (try tc.choiceInRange(u8, 0, 1)) != 0,
                .low_busreq_value = try tc.choiceInRange(u8, 0, std.math.maxInt(u8)),
                .low_reset_value = try tc.choiceInRange(u8, 0, std.math.maxInt(u8)),
            };
        }
    }.generate,
    .shrinkFn = null,
    .freeFn = null,
};

fn initEmptyBus() !Bus {
    return Bus.initFromRomBytes(testing.allocator, &empty_rom);
}

fn seedOpenBus(bus: *Bus, value: u16) void {
    bus.write16(0x00E0_0000, value);
    _ = bus.read16(0x00E0_0000);
}

fn configureVdpFromCase(vdp: *Vdp, input: VdpStateCase) void {
    vdp.* = Vdp.init();
    vdp.pal_mode = input.pal_mode;
    if (input.h40) {
        vdp.regs[12] = 0x81;
    }
    const total_lines = if (input.pal_mode) clock.pal_lines_per_frame else clock.ntsc_lines_per_frame;
    const visible_lines = if (input.pal_mode) clock.pal_visible_lines else clock.ntsc_visible_lines;
    const line = input.scanline % total_lines;
    _ = vdp.setScanlineState(line, visible_lines, total_lines);
    vdp.line_master_cycle = input.line_master_cycle;
    vdp.odd_frame = input.odd_frame;
    vdp.dma_active = input.dma_active;
    vdp.vint_pending = input.vint_pending;
    vdp.sprite_overflow = input.sprite_overflow;
    vdp.sprite_collision = input.sprite_collision;
}

fn makeRomWithSramHeader(
    allocator: std.mem.Allocator,
    rom_len: usize,
    ram_type: u8,
    start_address: u32,
    end_address: u32,
) ![]u8 {
    var rom = try allocator.alloc(u8, rom_len);
    @memset(rom, 0);
    @memcpy(rom[0x100..0x104], "SEGA");
    rom[0x1B0] = 'R';
    rom[0x1B1] = 'A';
    rom[0x1B2] = ram_type;
    rom[0x1B3] = 0x20;
    std.mem.writeInt(u32, rom[0x1B4..0x1B8], start_address, .big);
    std.mem.writeInt(u32, rom[0x1B8..0x1BC], end_address, .big);
    return rom;
}

fn audioTimingChunkingProperty(input: AudioChunkCase) !void {
    var split = AudioTiming{};
    split.consumeMaster(input.first);
    split.consumeMaster(input.second);
    const split_frames = split.takePending();

    var combined = AudioTiming{};
    combined.consumeMaster(input.first + input.second);
    const combined_frames = combined.takePending();

    try testing.expectEqual(combined_frames.fm_frames, split_frames.fm_frames);
    try testing.expectEqual(combined_frames.psg_frames, split_frames.psg_frames);
    try testing.expectEqual(combined.fm_master_remainder, split.fm_master_remainder);
    try testing.expectEqual(combined.psg_master_remainder, split.psg_master_remainder);
}

fn workRamByteMirrorProperty(input: RamByteMirrorCase) !void {
    var bus = try initEmptyBus();
    defer bus.deinit(testing.allocator);

    const offset = @as(u32, input.address);
    const base_address = 0xE00000 | offset;
    const mirror_address = 0xFF0000 | offset;

    bus.write8(base_address, input.first_value);
    try testing.expectEqual(input.first_value, bus.read8(base_address));
    try testing.expectEqual(input.first_value, bus.read8(mirror_address));

    bus.write8(mirror_address, input.second_value);
    try testing.expectEqual(input.second_value, bus.read8(base_address));
    try testing.expectEqual(input.second_value, bus.read8(mirror_address));
}

fn workRamWordProperty(input: RamWordCase) !void {
    var bus = try initEmptyBus();
    defer bus.deinit(testing.allocator);

    const offset = @as(u32, input.address);
    const base_address = 0xE00000 | offset;
    const mirror_address = 0xFF0000 | offset;
    const high_byte: u8 = @truncate(input.value >> 8);
    const low_byte: u8 = @truncate(input.value);

    bus.write16(base_address, input.value);

    try testing.expectEqual(input.value, bus.read16(base_address));
    try testing.expectEqual(input.value, bus.read16(mirror_address));
    try testing.expectEqual(high_byte, bus.read8(base_address));
    try testing.expectEqual(low_byte, bus.read8(base_address + 1));
    try testing.expectEqual(high_byte, bus.read8(mirror_address));
    try testing.expectEqual(low_byte, bus.read8(mirror_address + 1));
}

fn oddByteSramProperty(input: OddByteSramCase) !void {
    const rom = try makeRomWithSramHeader(testing.allocator, 0x200000, 0xF8, 0x200001, 0x203FFF);
    defer testing.allocator.free(rom);

    var bus = try Bus.initFromRomBytes(testing.allocator, rom);
    defer bus.deinit(testing.allocator);

    const address = 0x0020_0001 + @as(u32, input.byte_index) * 2;
    const paired_word_address = address - 1;

    bus.write8(address, input.value);

    try testing.expect(bus.hasCartridgeRam());
    try testing.expect(bus.isCartridgeRamMapped());
    try testing.expectEqual(input.value, bus.read8(address));
    try testing.expectEqual(@as(u16, input.value) << 8 | input.value, bus.read16(paired_word_address));
    try testing.expectEqual(@as(u8, 0), bus.read8(paired_word_address));
}

fn sixteenBitSramProperty(input: SixteenBitSramCase) !void {
    const rom = try makeRomWithSramHeader(testing.allocator, 0x100000, 0xE0, 0x200000, 0x20FFFF);
    defer testing.allocator.free(rom);

    var bus = try Bus.initFromRomBytes(testing.allocator, rom);
    defer bus.deinit(testing.allocator);

    const address = 0x0020_0000 + @as(u32, input.word_index) * 2;
    const high_byte: u8 = @truncate(input.value >> 8);
    const low_byte: u8 = @truncate(input.value);

    bus.write16(address, input.value);

    try testing.expect(bus.hasCartridgeRam());
    try testing.expect(bus.isCartridgeRamMapped());
    try testing.expectEqual(input.value, bus.read16(address));
    try testing.expectEqual(high_byte, bus.read8(address));
    try testing.expectEqual(low_byte, bus.read8(address + 1));
}

fn sixButtonReadProperty(input: SixButtonCase) !void {
    var io = Io.init();
    io.write(0x09, 0x40);

    const buttons = [_]u16{ Io.Button.Z, Io.Button.Y, Io.Button.X, Io.Button.Mode, Io.Button.B, Io.Button.C };
    for (buttons, 0..) |button, index| {
        const pressed = ((input.pressed_mask >> @intCast(index)) & 1) != 0;
        io.setButton(0, button, pressed);
    }

    io.write(0x03, 0x00);
    io.write(0x03, 0x40);
    io.write(0x03, 0x00);
    io.write(0x03, 0x40);
    io.write(0x03, 0x00);
    io.write(0x03, 0x40);

    const expected_low: u8 = @as(u8, ~@as(u8, input.pressed_mask)) & 0x3F;
    try testing.expectEqual(@as(u8, 0x40) | expected_low, io.read(0x03));
}

fn thHighDelayProperty(input: TickSplitCase) !void {
    var io = Io.init();

    io.write(0x03, 0x00);
    io.write(0x09, 0x40);
    io.write(0x09, 0x00);

    io.tick(input.first);
    io.tick(input.second);

    const total = @as(u32, input.first) + @as(u32, input.second);
    const expected: u8 = if (total >= 30) 0x43 else 0x03;
    try testing.expectEqual(expected, io.read(0x03) & 0x43);
}

fn sixButtonTimeoutProperty(input: TickSplitCase) !void {
    var io = Io.init();

    io.write(0x09, 0x40);
    io.setButton(0, Io.Button.Z, true);

    io.write(0x03, 0x00);
    io.write(0x03, 0x40);
    io.write(0x03, 0x00);
    io.write(0x03, 0x40);
    io.write(0x03, 0x00);
    io.write(0x03, 0x40);

    io.tick(input.first);
    io.tick(input.second);

    const total = @as(u32, input.first) + @as(u32, input.second);
    const expected: u8 = if (total >= 12_150) 0x7F else 0x7E;
    try testing.expectEqual(expected, io.read(0x03));
}

fn busControlRegisterMirrorProperty(input: BusControlCase) !void {
    var bus = try initEmptyBus();
    defer bus.deinit(testing.allocator);

    bus.write16(0x00A1_1200, if (input.reset_asserted) 0x0000 else 0x0100);
    bus.write16(0x00A1_1100, if (input.request_bus) 0x0100 else 0x0000);

    seedOpenBus(&bus, input.open_bus);
    const bus_ack = bus.read16(0x00A1_1100);
    const expected_bus_ack_bit: u16 = if (input.request_bus and !input.reset_asserted) 0x0000 else 0x0100;
    try testing.expectEqual((input.open_bus & ~@as(u16, 0x0100)) | expected_bus_ack_bit, bus_ack);

    seedOpenBus(&bus, input.open_bus);
    const reset = bus.read16(0x00A1_1200);
    const expected_reset_bit: u16 = if (input.reset_asserted) 0x0000 else 0x0100;
    try testing.expectEqual((input.open_bus & ~@as(u16, 0x0100)) | expected_reset_bit, reset);
}

fn vdpStatusOpenBusHighBitsProperty(input: OpenBusStatusCase) !void {
    var bus = try initEmptyBus();
    defer bus.deinit(testing.allocator);

    seedOpenBus(&bus, input.open_bus);
    const status = bus.read16(0x00C0_0004);
    try testing.expectEqual(input.open_bus & @as(u16, 0xFC00), status & @as(u16, 0xFC00));
}

fn z80WindowBlockedReadProperty(input: Z80WindowCase) !void {
    var bus = try initEmptyBus();
    defer bus.deinit(testing.allocator);

    seedOpenBus(&bus, input.open_bus);
    const address = 0x00A0_0000 + @as(u32, input.offset);
    try testing.expectEqual(@as(u8, @truncate(input.open_bus >> 8)), bus.read8(address));
    try testing.expectEqual(input.open_bus & @as(u16, 0xFF00), bus.read16(address));
}

fn unusedVdpPortReadProperty(input: UnusedVdpPortCase) !void {
    var bus = try initEmptyBus();
    defer bus.deinit(testing.allocator);

    const address = 0x00C0_0000 + @as(u32, input.even_offset);
    try testing.expectEqual(@as(u8, 0xFF), bus.read8(address));
    try testing.expectEqual(@as(u8, 0xFF), bus.read8(address + 1));
    try testing.expectEqual(@as(u16, 0xFFFF), bus.read16(address));
}

fn vdpMoveAdjustedHvProperty(input: VdpStateCase) !void {
    var vdp = Vdp.init();
    configureVdpFromCase(&vdp, input);
    try testing.expectEqual(vdp.readHVCounter(), vdp.readHVCounterAdjusted(0x3039));
}

fn vdpMoveAdjustedStatusProperty(input: VdpStateCase) !void {
    var immediate = Vdp.init();
    configureVdpFromCase(&immediate, input);

    var adjusted = immediate;

    try testing.expectEqual(immediate.readControl(), adjusted.readControlAdjusted(0x3039));
}

fn vdpFifoStatusProperty(input: VdpFifoCase) !void {
    var vdp = Vdp.init();
    vdp.regs[15] = 2;
    vdp.code = 0x1;
    vdp.addr = 0x0000;

    var word: u16 = 0x0102;
    var i: u8 = 0;
    while (i < input.write_count) : (i += 1) {
        vdp.writeData(word);
        word +%= 0x0202;
    }

    vdp.progressTransfers(input.progress_master_cycles, null, null);

    const status = vdp.readControl() & 0x0300;
    const expected: u16 = if (vdp.fifo_len == 0)
        0x0200
    else if (vdp.fifo_len == 4)
        0x0100
    else
        0x0000;

    try testing.expect(vdp.fifo_len <= 4);
    try testing.expectEqual(expected, status);
}

fn z80WindowBlockedWriteProperty(input: Z80WindowWriteCase) !void {
    var bus = try initEmptyBus();
    defer bus.deinit(testing.allocator);

    const address = 0x00A0_0000 + @as(u32, input.offset);

    bus.write16(0x00A1_1100, 0x0100);
    bus.write8(address, input.granted_value);
    try testing.expectEqual(input.granted_value, bus.read8(address));

    bus.write16(0x00A1_1100, 0x0000);
    bus.write8(address, input.blocked_value);

    bus.write16(0x00A1_1100, 0x0100);
    try testing.expectEqual(input.granted_value, bus.read8(address));
}

fn z80ControlLowByteNoOpProperty(input: Z80ControlByteCase) !void {
    var bus = try initEmptyBus();
    defer bus.deinit(testing.allocator);

    bus.write8(0x00A1_1200, if (input.release_reset) 0x01 else 0x00);
    bus.write8(0x00A1_1100, if (input.request_bus) 0x01 else 0x00);

    const busreq_before = bus.read16(0x00A1_1100) & 0x0100;
    const reset_before = bus.read16(0x00A1_1200) & 0x0100;

    bus.write8(0x00A1_1101, input.low_busreq_value);
    bus.write8(0x00A1_1201, input.low_reset_value);

    try testing.expectEqual(busreq_before, bus.read16(0x00A1_1100) & 0x0100);
    try testing.expectEqual(reset_before, bus.read16(0x00A1_1200) & 0x0100);
}

test "property: audio timing is chunk-invariant" {
    try minish.check(testing.allocator, audio_chunk_gen, audioTimingChunkingProperty, .{
        .num_runs = 128,
        .seed = 0xA0010123,
    });
}

test "property: work RAM byte writes mirror across the 64KB window" {
    try minish.check(testing.allocator, ram_byte_mirror_gen, workRamByteMirrorProperty, .{
        .num_runs = 96,
        .seed = 0xB17E1234,
    });
}

test "property: work RAM word writes match mirrored word and byte reads" {
    try minish.check(testing.allocator, ram_word_gen, workRamWordProperty, .{
        .num_runs = 96,
        .seed = 0xF00D1234,
    });
}

test "property: odd-byte SRAM writes round-trip through byte and word reads" {
    try minish.check(testing.allocator, odd_byte_sram_gen, oddByteSramProperty, .{
        .num_runs = 64,
        .seed = 0x0DD5A123,
    });
}

test "property: sixteen-bit SRAM writes preserve full word contents" {
    try minish.check(testing.allocator, sixteen_bit_sram_gen, sixteenBitSramProperty, .{
        .num_runs = 64,
        .seed = 0x516E1234,
    });
}

test "property: six-button reads expose the visible button mask after TH toggles" {
    try minish.check(testing.allocator, six_button_gen, sixButtonReadProperty, .{
        .num_runs = 96,
        .seed = 0x51AB1234,
    });
}

test "property: TH input pull-high delay depends only on total elapsed cycles" {
    try minish.check(testing.allocator, tick_split_gen, thHighDelayProperty, .{
        .num_runs = 96,
        .seed = 0x7A101234,
    });
}

test "property: six-button timeout depends only on total elapsed cycles" {
    try minish.check(testing.allocator, tick_split_gen, sixButtonTimeoutProperty, .{
        .num_runs = 96,
        .seed = 0x612A1234,
    });
}

test "property: Z80 control-register reads preserve open-bus bits outside bit 8" {
    try minish.check(testing.allocator, bus_control_gen, busControlRegisterMirrorProperty, .{
        .num_runs = 96,
        .seed = 0xB05C1234,
    });
}

test "property: VDP status top bits come from the current open bus latch" {
    try minish.check(testing.allocator, open_bus_status_gen, vdpStatusOpenBusHighBitsProperty, .{
        .num_runs = 96,
        .seed = 0x5A471234,
    });
}

test "property: blocked Z80-window reads reflect the open-bus high byte" {
    try minish.check(testing.allocator, z80_window_gen, z80WindowBlockedReadProperty, .{
        .num_runs = 96,
        .seed = 0x220A1234,
    });
}

test "property: unused VDP port reads stay high" {
    try minish.check(testing.allocator, unused_vdp_port_gen, unusedVdpPortReadProperty, .{
        .num_runs = 96,
        .seed = 0xC0001234,
    });
}

test "property: MOVE-adjusted HV reads match immediate HV reads" {
    try minish.check(testing.allocator, vdp_state_gen, vdpMoveAdjustedHvProperty, .{
        .num_runs = 128,
        .seed = 0xA0AD1234,
    });
}

test "property: MOVE-adjusted status reads match immediate status reads" {
    try minish.check(testing.allocator, vdp_state_gen, vdpMoveAdjustedStatusProperty, .{
        .num_runs = 128,
        .seed = 0x57A71234,
    });
}

test "property: VDP fifo status bits reflect fifo occupancy boundaries" {
    try minish.check(testing.allocator, vdp_fifo_gen, vdpFifoStatusProperty, .{
        .num_runs = 128,
        .seed = 0xF1F01234,
    });
}

test "property: blocked Z80-window writes do not overwrite granted data" {
    try minish.check(testing.allocator, z80_window_write_gen, z80WindowBlockedWriteProperty, .{
        .num_runs = 96,
        .seed = 0x20A01234,
    });
}

test "property: low-byte writes do not change Z80 control register state" {
    try minish.check(testing.allocator, z80_control_byte_gen, z80ControlLowByteNoOpProperty, .{
        .num_runs = 96,
        .seed = 0xB17E5678,
    });
}
