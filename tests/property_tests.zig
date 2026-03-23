const std = @import("std");
const testing = std.testing;
const minish = @import("minish");
const sandopolis = @import("sandopolis_src");

const clock = sandopolis.clock;
const AudioTiming = sandopolis.testing.AudioTiming;
const Button = sandopolis.testing.Button;
const ControllerIo = sandopolis.testing.ControllerIo;
const Emulator = sandopolis.testing.Emulator;
const Vdp = sandopolis.testing.Vdp;

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
    base_offset: u8,
    open_bus: u16,
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

const VdpWaitCase = struct {
    h40: bool,
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
                .base_offset = if ((try tc.choiceInRange(u8, 0, 1)) != 0) 0x18 else 0x1C,
                .open_bus = try tc.choiceInRange(u16, 0, std.math.maxInt(u16)),
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

const vdp_wait_gen = minish.gen.Generator(VdpWaitCase){
    .generateFn = struct {
        fn generate(tc: *minish.TestCase) minish.GenError!VdpWaitCase {
            return .{
                .h40 = (try tc.choiceInRange(u8, 0, 1)) != 0,
                .write_count = try tc.choiceInRange(u8, 0, 8),
                .progress_master_cycles = try tc.choiceInRange(u8, 0, 127),
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

const SaveStateRamCase = struct {
    ram_offset: u16,
    ram_value: u8,
    vdp_reg_index: u4,
    vdp_reg_value: u8,
    cpu_pc: u24,
    cpu_sr: u16,
    m68k_sync_cycles: u32,
};

const save_state_ram_gen = minish.gen.Generator(SaveStateRamCase){
    .generateFn = struct {
        fn generate(tc: *minish.TestCase) minish.GenError!SaveStateRamCase {
            return .{
                .ram_offset = try tc.choiceInRange(u16, 0, 0xFFFF),
                .ram_value = try tc.choiceInRange(u8, 0, std.math.maxInt(u8)),
                .vdp_reg_index = @intCast(try tc.choiceInRange(u8, 0, 15)),
                .vdp_reg_value = try tc.choiceInRange(u8, 0, std.math.maxInt(u8)),
                .cpu_pc = @intCast(try tc.choiceInRange(u32, 0, 0xFFFFFF)),
                .cpu_sr = try tc.choiceInRange(u16, 0, std.math.maxInt(u16)),
                .m68k_sync_cycles = try tc.choiceInRange(u32, 0, clock.ntsc_master_cycles_per_frame * 10),
            };
        }
    }.generate,
    .shrinkFn = null,
    .freeFn = null,
};

const SaveStateZ80Case = struct {
    z80_ram_offset: u13,
    z80_ram_value: u8,
    ym_port: u1,
    ym_reg: u8,
    ym_value: u8,
};

const VdpRenderDeterminismCase = struct {
    vram_offset: u14,
    vram_value: u16,
    scroll_a_h: u10,
    scroll_a_v: u10,
    bg_color: u6,
};

const save_state_z80_gen = minish.gen.Generator(SaveStateZ80Case){
    .generateFn = struct {
        fn generate(tc: *minish.TestCase) minish.GenError!SaveStateZ80Case {
            return .{
                .z80_ram_offset = @intCast(try tc.choiceInRange(u16, 0, 0x1FFF)),
                .z80_ram_value = try tc.choiceInRange(u8, 0, std.math.maxInt(u8)),
                .ym_port = @intCast(try tc.choiceInRange(u8, 0, 1)),
                .ym_reg = try tc.choiceInRange(u8, 0, 0x2F),
                .ym_value = try tc.choiceInRange(u8, 0, std.math.maxInt(u8)),
            };
        }
    }.generate,
    .shrinkFn = null,
    .freeFn = null,
};

const vdp_render_determinism_gen = minish.gen.Generator(VdpRenderDeterminismCase){
    .generateFn = struct {
        fn generate(tc: *minish.TestCase) minish.GenError!VdpRenderDeterminismCase {
            return .{
                .vram_offset = @intCast(try tc.choiceInRange(u16, 0, 0x3FFF)),
                .vram_value = try tc.choiceInRange(u16, 0, std.math.maxInt(u16)),
                .scroll_a_h = @intCast(try tc.choiceInRange(u16, 0, 0x3FF)),
                .scroll_a_v = @intCast(try tc.choiceInRange(u16, 0, 0x3FF)),
                .bg_color = @intCast(try tc.choiceInRange(u8, 0, 0x3F)),
            };
        }
    }.generate,
    .shrinkFn = null,
    .freeFn = null,
};

fn initEmptyEmulator() !Emulator {
    return Emulator.initEmpty(testing.allocator);
}

fn seedOpenBus(emulator: *Emulator, prefetch_ctx: *Emulator.TestPrefetchCtx) void {
    emulator.setTestPrefetch(prefetch_ctx);
}

fn configureVdpFromCase(vdp: *Vdp, input: VdpStateCase) void {
    vdp.reset();
    vdp.setPalMode(input.pal_mode);
    vdp.setH40(input.h40);
    const total_lines = if (input.pal_mode) clock.pal_lines_per_frame else clock.ntsc_lines_per_frame;
    const visible_lines = if (input.pal_mode) clock.pal_visible_lines else clock.ntsc_visible_lines;
    const line = input.scanline % total_lines;
    _ = vdp.setScanlineState(line, visible_lines, total_lines);
    vdp.setLineMasterCycle(input.line_master_cycle);
    vdp.setOddFrame(input.odd_frame);
    vdp.setDmaActive(input.dma_active);
    vdp.setVintPending(input.vint_pending);
    vdp.setSpriteOverflow(input.sprite_overflow);
    vdp.setSpriteCollision(input.sprite_collision);
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
    var split = try AudioTiming.init(testing.allocator);
    defer split.deinit(testing.allocator);
    split.consumeMaster(input.first);
    split.consumeMaster(input.second);
    const split_frames = split.takePending();

    var combined = try AudioTiming.init(testing.allocator);
    defer combined.deinit(testing.allocator);
    combined.consumeMaster(input.first + input.second);
    const combined_frames = combined.takePending();

    try testing.expectEqual(combined_frames.master_cycles, split_frames.master_cycles);
    try testing.expectEqual(combined_frames.fm_frames, split_frames.fm_frames);
    try testing.expectEqual(combined_frames.psg_frames, split_frames.psg_frames);
    try testing.expectEqual(combined_frames.fm_start_remainder, split_frames.fm_start_remainder);
    try testing.expectEqual(combined_frames.psg_start_remainder, split_frames.psg_start_remainder);
    try testing.expectEqual(combined.fmMasterRemainder(), split.fmMasterRemainder());
    try testing.expectEqual(combined.psgMasterRemainder(), split.psgMasterRemainder());
}

fn workRamByteMirrorProperty(input: RamByteMirrorCase) !void {
    var emulator = try initEmptyEmulator();
    defer emulator.deinit(testing.allocator);

    const offset = @as(u32, input.address);
    const base_address = 0xE00000 | offset;
    const mirror_address = 0xFF0000 | offset;

    emulator.write8(base_address, input.first_value);
    try testing.expectEqual(input.first_value, emulator.read8(base_address));
    try testing.expectEqual(input.first_value, emulator.read8(mirror_address));

    emulator.write8(mirror_address, input.second_value);
    try testing.expectEqual(input.second_value, emulator.read8(base_address));
    try testing.expectEqual(input.second_value, emulator.read8(mirror_address));
}

fn workRamWordProperty(input: RamWordCase) !void {
    var emulator = try initEmptyEmulator();
    defer emulator.deinit(testing.allocator);

    const offset = @as(u32, input.address);
    const base_address = 0xE00000 | offset;
    const mirror_address = 0xFF0000 | offset;
    const high_byte: u8 = @truncate(input.value >> 8);
    const low_byte: u8 = @truncate(input.value);

    emulator.write16(base_address, input.value);

    try testing.expectEqual(input.value, emulator.read16(base_address));
    try testing.expectEqual(input.value, emulator.read16(mirror_address));
    try testing.expectEqual(high_byte, emulator.read8(base_address));
    try testing.expectEqual(low_byte, emulator.read8(base_address + 1));
    try testing.expectEqual(high_byte, emulator.read8(mirror_address));
    try testing.expectEqual(low_byte, emulator.read8(mirror_address + 1));
}

fn oddByteSramProperty(input: OddByteSramCase) !void {
    const rom = try makeRomWithSramHeader(testing.allocator, 0x200000, 0xF8, 0x200001, 0x203FFF);
    defer testing.allocator.free(rom);

    var emulator = try Emulator.initFromRomBytes(testing.allocator, rom);
    defer emulator.deinit(testing.allocator);

    const address = 0x0020_0001 + @as(u32, input.byte_index) * 2;
    const paired_word_address = address - 1;

    emulator.write8(address, input.value);

    try testing.expect(emulator.hasCartridgeRam());
    try testing.expect(emulator.isCartridgeRamMapped());
    try testing.expectEqual(input.value, emulator.read8(address));
    try testing.expectEqual(@as(u16, input.value) << 8 | input.value, emulator.read16(paired_word_address));
    try testing.expectEqual(@as(u8, 0), emulator.read8(paired_word_address));
}

fn sixteenBitSramProperty(input: SixteenBitSramCase) !void {
    const rom = try makeRomWithSramHeader(testing.allocator, 0x100000, 0xE0, 0x200000, 0x20FFFF);
    defer testing.allocator.free(rom);

    var emulator = try Emulator.initFromRomBytes(testing.allocator, rom);
    defer emulator.deinit(testing.allocator);

    const address = 0x0020_0000 + @as(u32, input.word_index) * 2;
    const high_byte: u8 = @truncate(input.value >> 8);
    const low_byte: u8 = @truncate(input.value);

    emulator.write16(address, input.value);

    try testing.expect(emulator.hasCartridgeRam());
    try testing.expect(emulator.isCartridgeRamMapped());
    try testing.expectEqual(input.value, emulator.read16(address));
    try testing.expectEqual(high_byte, emulator.read8(address));
    try testing.expectEqual(low_byte, emulator.read8(address + 1));
}

fn sixButtonReadProperty(input: SixButtonCase) !void {
    var io = try ControllerIo.init(testing.allocator);
    defer io.deinit(testing.allocator);
    io.write(0x09, 0x40);

    const buttons = [_]u16{ Button.Z, Button.Y, Button.X, Button.Mode, Button.B, Button.C };
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
    var io = try ControllerIo.init(testing.allocator);
    defer io.deinit(testing.allocator);

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
    var io = try ControllerIo.init(testing.allocator);
    defer io.deinit(testing.allocator);

    io.write(0x09, 0x40);
    io.setButton(0, Button.Z, true);

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
    var emulator = try initEmptyEmulator();
    defer emulator.deinit(testing.allocator);

    emulator.write16(0x00A1_1200, if (input.reset_asserted) 0x0000 else 0x0100);
    emulator.write16(0x00A1_1100, if (input.request_bus) 0x0100 else 0x0000);

    var prefetch_ctx = Emulator.TestPrefetchCtx{ .opcode = input.open_bus };
    seedOpenBus(&emulator, &prefetch_ctx);
    const bus_ack = emulator.read16(0x00A1_1100);
    const expected_bus_ack_bit: u16 = if (input.request_bus and !input.reset_asserted) 0x0000 else 0x0100;
    try testing.expectEqual((input.open_bus & ~@as(u16, 0x0100)) | expected_bus_ack_bit, bus_ack);

    const expected_reset_bit: u16 = if (input.reset_asserted) 0x0000 else 0x0100;
    try testing.expectEqual(expected_reset_bit, emulator.z80ResetControlWord());
}

fn vdpStatusOpenBusHighBitsProperty(input: OpenBusStatusCase) !void {
    var emulator = try initEmptyEmulator();
    defer emulator.deinit(testing.allocator);

    var prefetch_ctx = Emulator.TestPrefetchCtx{ .opcode = input.open_bus };
    seedOpenBus(&emulator, &prefetch_ctx);
    const status = emulator.read16(0x00C0_0004);
    try testing.expectEqual(input.open_bus & @as(u16, 0xFC00), status & @as(u16, 0xFC00));
}

fn z80WindowBlockedReadProperty(input: Z80WindowCase) !void {
    var emulator = try initEmptyEmulator();
    defer emulator.deinit(testing.allocator);

    var prefetch_ctx = Emulator.TestPrefetchCtx{ .opcode = input.open_bus };
    seedOpenBus(&emulator, &prefetch_ctx);
    const address = 0x00A0_0000 + @as(u32, input.offset);
    try testing.expectEqual(@as(u8, @truncate(input.open_bus >> 8)), emulator.read8(address));
    try testing.expectEqual(input.open_bus, emulator.read16(address));
}

fn unusedVdpPortReadProperty(input: UnusedVdpPortCase) !void {
    var emulator = try initEmptyEmulator();
    defer emulator.deinit(testing.allocator);

    var prefetch_ctx = Emulator.TestPrefetchCtx{ .opcode = input.open_bus };
    seedOpenBus(&emulator, &prefetch_ctx);
    const address = 0x00C0_0000 + @as(u32, input.base_offset);
    try testing.expectEqual(@as(u8, @truncate(input.open_bus >> 8)), emulator.read8(address));
    try testing.expectEqual(@as(u8, @truncate(input.open_bus)), emulator.read8(address + 1));
    try testing.expectEqual(input.open_bus, emulator.read16(address));
}

fn vdpMoveAdjustedHvProperty(input: VdpStateCase) !void {
    var vdp = try Vdp.init(testing.allocator);
    defer vdp.deinit(testing.allocator);
    configureVdpFromCase(&vdp, input);
    try testing.expectEqual(vdp.readHVCounter(), vdp.readHVCounterAdjusted(0x3039));
}

fn vdpMoveAdjustedStatusProperty(input: VdpStateCase) !void {
    var immediate = try Vdp.init(testing.allocator);
    defer immediate.deinit(testing.allocator);
    configureVdpFromCase(&immediate, input);

    var adjusted = try immediate.clone(testing.allocator);
    defer adjusted.deinit(testing.allocator);

    try testing.expectEqual(immediate.readControl(), adjusted.readControlAdjusted(0x3039));
}

fn vdpFifoStatusProperty(input: VdpFifoCase) !void {
    var vdp = try Vdp.init(testing.allocator);
    defer vdp.deinit(testing.allocator);
    vdp.setRegister(15, 2);
    vdp.setCode(0x1);
    vdp.setAddr(0x0000);

    var word: u16 = 0x0102;
    var i: u8 = 0;
    while (i < input.write_count) : (i += 1) {
        vdp.writeData(word);
        word +%= 0x0202;
    }

    vdp.progressTransfers(input.progress_master_cycles);

    const status = vdp.readControl() & 0x0300;
    const expected: u16 = if (vdp.fifoLen() == 0)
        0x0200
    else if (vdp.fifoLen() == 4)
        0x0100
    else
        0x0000;

    try testing.expect(vdp.fifoLen() <= 4);
    try testing.expectEqual(expected, status);
}

fn initVdpWaitCase(input: VdpWaitCase) !Vdp {
    var vdp = try Vdp.init(testing.allocator);
    vdp.setH40(input.h40);
    vdp.setRegister(15, 2);
    vdp.setCode(0x1);
    vdp.setAddr(0x0000);

    var word: u16 = 0x0102;
    var i: u8 = 0;
    while (i < input.write_count) : (i += 1) {
        vdp.writeData(word);
        word +%= 0x0202;
    }

    vdp.progressTransfersWithEvents(input.progress_master_cycles);
    return vdp;
}

fn vdpReadWaitMatchesDrainProperty(input: VdpWaitCase) !void {
    var vdp = try initVdpWaitCase(input);
    defer vdp.deinit(testing.allocator);
    const predicted = vdp.dataPortReadWaitMasterCycles();

    if (predicted == 0) {
        try testing.expect(vdp.fifoLen() == 0 and vdp.pendingFifoLen() == 0);
        return;
    }

    var before = try vdp.clone(testing.allocator);
    defer before.deinit(testing.allocator);
    before.progressTransfersWithEvents(predicted - 1);
    try testing.expect(before.fifoLen() != 0 or before.pendingFifoLen() != 0);

    var drained = try vdp.clone(testing.allocator);
    defer drained.deinit(testing.allocator);
    drained.progressTransfersWithEvents(predicted);
    try testing.expectEqual(@as(u8, 0), drained.fifoLen());
    try testing.expectEqual(@as(u8, 0), drained.pendingFifoLen());
    try testing.expectEqual(@as(u32, 0), drained.dataPortReadWaitMasterCycles());
}

fn vdpWriteWaitMatchesNextOpenProperty(input: VdpWaitCase) !void {
    var vdp = try initVdpWaitCase(input);
    defer vdp.deinit(testing.allocator);
    const predicted = vdp.dataPortWriteWaitMasterCycles();

    if (predicted == 0) {
        try testing.expect(vdp.pendingFifoLen() == 0 and vdp.fifoLen() < 4);
        return;
    }

    var before = try vdp.clone(testing.allocator);
    defer before.deinit(testing.allocator);
    before.progressTransfersWithEvents(predicted - 1);
    try testing.expect(before.pendingFifoLen() != 0 or before.fifoLen() == 4);

    var opened = try vdp.clone(testing.allocator);
    defer opened.deinit(testing.allocator);
    opened.progressTransfersWithEvents(predicted);
    try testing.expect(opened.pendingFifoLen() == 0 and opened.fifoLen() < 4);
    try testing.expectEqual(@as(u32, 0), opened.dataPortWriteWaitMasterCycles());
}

fn z80WindowBlockedWriteProperty(input: Z80WindowWriteCase) !void {
    var emulator = try initEmptyEmulator();
    defer emulator.deinit(testing.allocator);

    const address = 0x00A0_0000 + @as(u32, input.offset);

    emulator.write16(0x00A1_1200, 0x0100);
    emulator.write16(0x00A1_1100, 0x0100);
    emulator.write8(address, input.granted_value);
    try testing.expectEqual(input.granted_value, emulator.read8(address));

    emulator.write16(0x00A1_1100, 0x0000);
    emulator.write8(address, input.blocked_value);

    emulator.write16(0x00A1_1100, 0x0100);
    try testing.expectEqual(input.granted_value, emulator.read8(address));
}

fn z80ControlLowByteNoOpProperty(input: Z80ControlByteCase) !void {
    var emulator = try initEmptyEmulator();
    defer emulator.deinit(testing.allocator);

    emulator.write8(0x00A1_1200, if (input.release_reset) 0x01 else 0x00);
    emulator.write8(0x00A1_1100, if (input.request_bus) 0x01 else 0x00);

    const busreq_before = emulator.read16(0x00A1_1100) & 0x0100;
    const reset_before = emulator.z80ResetControlWord() & 0x0100;

    emulator.write8(0x00A1_1101, input.low_busreq_value);
    emulator.write8(0x00A1_1201, input.low_reset_value);

    try testing.expectEqual(busreq_before, emulator.read16(0x00A1_1100) & 0x0100);
    try testing.expectEqual(reset_before, emulator.z80ResetControlWord() & 0x0100);
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

test "property: VDP data-port read wait matches actual drain time" {
    try minish.check(testing.allocator, vdp_wait_gen, vdpReadWaitMatchesDrainProperty, .{
        .num_runs = 128,
        .seed = 0xDA7A1234,
    });
}

test "property: VDP data-port write wait matches actual open time" {
    try minish.check(testing.allocator, vdp_wait_gen, vdpWriteWaitMatchesNextOpenProperty, .{
        .num_runs = 128,
        .seed = 0x0F3E1234,
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

fn tempFilePath(allocator: std.mem.Allocator, tmp: *testing.TmpDir, file_name: []const u8) ![]u8 {
    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);
    return std.fs.path.join(allocator, &.{ dir_path, file_name });
}

fn saveStateRamRoundTripProperty(input: SaveStateRamCase) !void {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const state_path = try tempFilePath(testing.allocator, &tmp, "property.state");
    defer testing.allocator.free(state_path);

    // Create a minimal ROM with valid SEGA header
    const rom = try makeRomWithSramHeader(testing.allocator, 0x1000, 0xF8, 0x200001, 0x203FFF);
    defer testing.allocator.free(rom);

    var emulator = try Emulator.initFromRomBytes(testing.allocator, rom);
    defer emulator.deinit(testing.allocator);

    // Set various machine state based on random input
    emulator.writeRam(input.ram_offset, input.ram_value);
    emulator.setVdpRegister(input.vdp_reg_index, input.vdp_reg_value);
    emulator.setCpuPc(input.cpu_pc);
    emulator.setCpuSr(input.cpu_sr);
    emulator.setM68kSyncCycles(input.m68k_sync_cycles);

    // Save the state
    try emulator.saveToFile(state_path);

    // Load the state into a new emulator
    var restored = try Emulator.loadFromFile(testing.allocator, state_path);
    defer restored.deinit(testing.allocator);

    // Verify all state matches
    try testing.expectEqual(input.ram_value, restored.readRam(input.ram_offset));
    try testing.expectEqual(input.vdp_reg_value, restored.vdpRegister(input.vdp_reg_index));
    try testing.expectEqual(@as(u32, input.cpu_pc), restored.cpuPc());
    try testing.expectEqual(input.cpu_sr, restored.cpuSr());
    try testing.expectEqual(@as(u64, input.m68k_sync_cycles), restored.m68kSyncCycles());
}

fn saveStateZ80RoundTripProperty(input: SaveStateZ80Case) !void {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const state_path = try tempFilePath(testing.allocator, &tmp, "z80_property.state");
    defer testing.allocator.free(state_path);

    // Create a minimal ROM with valid SEGA header
    const rom = try makeRomWithSramHeader(testing.allocator, 0x1000, 0xF8, 0x200001, 0x203FFF);
    defer testing.allocator.free(rom);

    var emulator = try Emulator.initFromRomBytes(testing.allocator, rom);
    defer emulator.deinit(testing.allocator);

    // Request Z80 bus and release reset to allow writes
    emulator.setZ80BusRequest(0x0100);
    emulator.setZ80ResetControl(0x0100);

    // Set Z80 state
    emulator.z80WriteByte(input.z80_ram_offset, input.z80_ram_value);

    // Write to YM2612 registers
    emulator.write8(0x00A0_4000, input.ym_reg);
    emulator.write8(0x00A0_4001, input.ym_value);

    // Save state
    try emulator.saveToFile(state_path);

    // Load into new emulator
    var restored = try Emulator.loadFromFile(testing.allocator, state_path);
    defer restored.deinit(testing.allocator);

    // Verify Z80 RAM
    const restored_value = restored.read8(0x00A0_0000 + @as(u32, input.z80_ram_offset));
    try testing.expectEqual(input.z80_ram_value, restored_value);

    // Verify YM2612 register (if it's not a keyon register which has side effects)
    if (input.ym_reg != 0x28) {
        try testing.expectEqual(input.ym_value, restored.ymRegister(0, input.ym_reg));
    }
}

test "property: save-state round-trip preserves M68K state" {
    try minish.check(testing.allocator, save_state_ram_gen, saveStateRamRoundTripProperty, .{
        .num_runs = 64,
        .seed = 0x5A7E0001,
    });
}

test "property: save-state round-trip preserves Z80 and YM2612 state" {
    try minish.check(testing.allocator, save_state_z80_gen, saveStateZ80RoundTripProperty, .{
        .num_runs = 64,
        .seed = 0x280A0002,
    });
}

fn computeFramebufferHash(framebuffer: []const u32) u64 {
    var hash: u64 = 0;
    for (framebuffer, 0..) |pixel, i| {
        // Simple hash combining position and value
        hash ^= @as(u64, pixel) ^ (@as(u64, @intCast(i)) << 32);
        hash = hash *% 0x517cc1b727220a95;
    }
    return hash;
}

fn vdpRenderDeterminismProperty(input: VdpRenderDeterminismCase) !void {
    // Create a minimal ROM with valid SEGA header
    const rom = try makeRomWithSramHeader(testing.allocator, 0x1000, 0xF8, 0x200001, 0x203FFF);
    defer testing.allocator.free(rom);

    var emulator = try Emulator.initFromRomBytes(testing.allocator, rom);
    defer emulator.deinit(testing.allocator);

    // Enable display (register 1, bit 6)
    emulator.setVdpRegister(1, 0x40);

    // Set background color register (register 7)
    emulator.setVdpRegister(7, input.bg_color);

    // Write to VRAM: configure data port for VRAM write
    emulator.configureVdpDataPort(0x01, @as(u16, input.vram_offset) * 2, 2);
    emulator.writeVdpData(input.vram_value);

    // Set scroll values via registers
    // Register 13 = horizontal scroll data table address (bits 5-0 = SA13-SA8)
    emulator.setVdpRegister(13, 0);

    // Run one full frame
    emulator.runFramesDiscardingAudio(1);

    // Capture first framebuffer state
    const fb1 = emulator.framebuffer();
    const hash1 = computeFramebufferHash(fb1);

    // Save state
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const state_path = try tempFilePath(testing.allocator, &tmp, "render.state");
    defer testing.allocator.free(state_path);
    try emulator.saveToFile(state_path);

    // Run another frame (advancing state)
    emulator.runFramesDiscardingAudio(1);

    // Restore state
    var restored = try Emulator.loadFromFile(testing.allocator, state_path);
    defer restored.deinit(testing.allocator);

    // The restored framebuffer should match the saved state
    const fb2 = restored.framebuffer();
    const hash2 = computeFramebufferHash(fb2);

    try testing.expectEqual(hash1, hash2);
}

test "property: VDP rendering is deterministic through save-state round-trip" {
    try minish.check(testing.allocator, vdp_render_determinism_gen, vdpRenderDeterminismProperty, .{
        .num_runs = 32,
        .seed = 0x7D900003,
    });
}
