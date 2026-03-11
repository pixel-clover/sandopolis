const std = @import("std");
const testing = std.testing;
const sandopolis = @import("sandopolis_src");
const clock = sandopolis.clock;
const Emulator = sandopolis.testing.Emulator;

const graphics_sampler_rom = "tests/testroms/Graphics & Joystick Sampler by Charles Doty (PD).bin";
const window_test_rom = "tests/testroms/Window Test by Fonzie (PD).bin";
const fm_test_rom = "tests/testroms/FM Test by DevSter (PD).bin";
const overdrive_rom = "tests/testroms/TiTAN - Overdrive (Rev1.1-106-Final) (Hardware).bin";

fn makeSsfMapperRom(allocator: std.mem.Allocator, bank_count: usize) ![]u8 {
    const bank_size = 512 * 1024;
    const rom_len = bank_count * bank_size;
    var rom = try allocator.alloc(u8, rom_len);
    @memset(rom, 0);
    @memcpy(rom[0x100..0x108], "SEGA SSF");
    std.mem.writeInt(u32, rom[0..4], 0x00FF_FE00, .big);
    std.mem.writeInt(u32, rom[4..8], 0x0000_0200, .big);
    rom[0x0200] = 0x60;
    rom[0x0201] = 0xFE;

    const marker_offset = 0x0400;
    for (0..bank_count) |bank| {
        rom[bank * bank_size + marker_offset] = @truncate(bank);
    }

    return rom;
}

fn makeGenesisRom(allocator: std.mem.Allocator, stack_pointer: u32, program_counter: u32, program: []const u8) ![]u8 {
    const rom_len = @max(@as(usize, 0x4000), 0x0200 + program.len);
    var rom = try allocator.alloc(u8, rom_len);
    @memset(rom, 0);
    @memcpy(rom[0x100..0x104], "SEGA");
    std.mem.writeInt(u32, rom[0..4], stack_pointer, .big);
    std.mem.writeInt(u32, rom[4..8], program_counter, .big);
    @memcpy(rom[0x0200 .. 0x0200 + program.len], program);
    return rom;
}

fn seedResetNopsRom(allocator: std.mem.Allocator, nop_count: usize) ![]u8 {
    var program = try allocator.alloc(u8, nop_count * 2);
    errdefer allocator.free(program);
    for (0..nop_count) |i| {
        program[i * 2] = 0x4E;
        program[i * 2 + 1] = 0x71;
    }

    const rom = try makeGenesisRom(allocator, 0x00FF_FE00, 0x0000_0200, program);
    allocator.free(program);
    return rom;
}

fn countUniqueFramebufferColors(framebuffer: []const u32, max_unique: usize) usize {
    var uniques: [64]u32 = undefined;
    var count: usize = 0;

    for (framebuffer) |pixel| {
        var seen = false;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            if (uniques[i] == pixel) {
                seen = true;
                break;
            }
        }

        if (!seen) {
            if (count < max_unique) {
                uniques[count] = pixel;
            }
            count += 1;
            if (count >= max_unique) break;
        }
    }

    return count;
}

test "graphics sampler rom advances startup state across frames" {
    var emulator = try Emulator.init(testing.allocator, graphics_sampler_rom);
    defer emulator.deinit(testing.allocator);
    emulator.reset();

    emulator.runFrames(24);

    try testing.expect(emulator.cpuState().program_counter != 0x0000_0200);
    try testing.expect(emulator.vdpRegister(1) != 0 or emulator.vdpRegister(2) != 0 or emulator.vdpRegister(4) != 0);
}

test "window test rom reaches non-uniform visible output" {
    var emulator = try Emulator.init(testing.allocator, window_test_rom);
    defer emulator.deinit(testing.allocator);
    emulator.reset();

    emulator.runFrames(90);

    const framebuffer = emulator.framebuffer();
    const first_pixel = framebuffer[0];
    var differing_pixels: usize = 0;
    var non_black_pixels: usize = 0;
    for (framebuffer) |pixel| {
        if (pixel != first_pixel) differing_pixels += 1;
        if (pixel != 0xFF000000) non_black_pixels += 1;
    }

    try testing.expect((emulator.vdpRegister(1) & 0x40) != 0);
    try testing.expect(non_black_pixels > 0);
    try testing.expect(differing_pixels > 0);
    try testing.expect(countUniqueFramebufferColors(framebuffer, 8) > 1);
}

test "fm test rom initializes ym shadow state" {
    var emulator = try Emulator.init(testing.allocator, fm_test_rom);
    defer emulator.deinit(testing.allocator);
    emulator.reset();

    emulator.runFrames(120);
    const pending = emulator.takePendingAudio();

    const ym_active = emulator.ymKeyMask() != 0 or
        emulator.ymRegister(0, 0x28) != 0 or
        emulator.ymRegister(0, 0x2B) != 0 or
        emulator.ymRegister(0, 0x2A) != 0 or
        emulator.ymRegister(0, 0xA0) != 0 or
        emulator.ymRegister(0, 0xA4) != 0 or
        emulator.ymRegister(1, 0xA0) != 0 or
        emulator.ymRegister(1, 0xA4) != 0;

    try testing.expect(pending.fm_frames != 0 or pending.psg_frames != 0);
    try testing.expect(ym_active);
}

test "ssf mapper remaps switchable rom windows" {
    const rom = try makeSsfMapperRom(testing.allocator, 16);
    defer testing.allocator.free(rom);

    var emulator = try Emulator.initFromRomBytes(testing.allocator, rom);
    defer emulator.deinit(testing.allocator);

    const marker_offset: u32 = 0x0400;

    try testing.expectEqual(@as(u8, 0), emulator.read8(0x000000 + marker_offset));
    try testing.expectEqual(@as(u8, 1), emulator.read8(0x080000 + marker_offset));
    try testing.expectEqual(@as(u8, 7), emulator.read8(0x380000 + marker_offset));

    emulator.write8(0xA130F3, 10);
    try testing.expectEqual(@as(u8, 10), emulator.read8(0x080000 + marker_offset));

    emulator.write16(0xA130F4, 0x000C);
    try testing.expectEqual(@as(u8, 12), emulator.read8(0x100000 + marker_offset));

    emulator.write8(0xA130FF, 15);
    try testing.expectEqual(@as(u8, 15), emulator.read8(0x380000 + marker_offset));
}

test "overdrive rom runs for 5000 frames without wedging the core" {
    var emulator = try Emulator.init(testing.allocator, overdrive_rom);
    defer emulator.deinit(testing.allocator);
    emulator.reset();

    emulator.runFramesDiscardingAudio(5000);

    var non_black_pixels: usize = 0;
    for (emulator.framebuffer()) |pixel| {
        if (pixel != 0xFF000000) non_black_pixels += 1;
    }

    try testing.expect((emulator.vdpRegister(1) & 0x40) != 0);
    try testing.expect(non_black_pixels > 0);
    try testing.expect(emulator.cpuState().program_counter != 0);
}

test "overdrive rom runs for 5000 frames with audio output processing" {
    var emulator = try Emulator.init(testing.allocator, overdrive_rom);
    defer emulator.deinit(testing.allocator);
    emulator.reset();

    try emulator.runFramesProcessingAudio(5000);

    var non_black_pixels: usize = 0;
    for (emulator.framebuffer()) |pixel| {
        if (pixel != 0xFF000000) non_black_pixels += 1;
    }

    try testing.expect((emulator.vdpRegister(1) & 0x40) != 0);
    try testing.expect(non_black_pixels > 0);
    try testing.expect(emulator.cpuState().program_counter != 0);
}

test "zero reset stack pointer survives ram clear rts trampoline" {
    const program = [_]u8{
        0x2F, 0x3C, 0x00, 0x00, 0x02, 0x1C, // move.l #$0000021C, -(sp)
        0x70, 0x00, // moveq #0, d0
        0x22, 0x3C, 0x00, 0x00, 0x3F, 0xFD, // move.l #$00003FFD, d1
        0x41, 0xF9, 0x00, 0xFF, 0x00, 0x00, // lea $00FF0000.l, a0
        0x20, 0xC0, // move.l d0, (a0)+
        0x51, 0xC9, 0xFF, 0xFC, // dbf d1, -4
        0x4E, 0x75, // rts
        0x13, 0xFC, 0x00, 0x42, 0x00, 0xFF, 0x00, 0x00, // move.b #$42, $00FF0000.l
        0x60, 0xFE, // bra.s -2
    };
    const rom = try makeGenesisRom(testing.allocator, 0x0000_0000, 0x0000_0200, &program);
    defer testing.allocator.free(rom);

    var emulator = try Emulator.initFromRomBytes(testing.allocator, rom);
    defer emulator.deinit(testing.allocator);
    emulator.reset();

    emulator.runFrames(6);

    try testing.expectEqual(@as(u8, 0x42), emulator.read8(0x00FF_0000));
}

test "hard reset seeds the first mode-5 hv counter read to the reference values" {
    const program = [_]u8{
        0x33, 0xFC, 0x81, 0x04, 0x00, 0xC0, 0x00, 0x04, // move.w #$8104, $00C00004.l
        0x30, 0x39, 0x00, 0xC0, 0x00, 0x08, // move.w $00C00008.l, d0
        0x33, 0xC0, 0x00, 0xFF, 0x00, 0x00, // move.w d0, $00FF0000.l
        0x60, 0xFE, // bra.s -2
    };
    const rom = try makeGenesisRom(testing.allocator, 0x00FF_FE00, 0x0000_0200, &program);
    defer testing.allocator.free(rom);

    var ntsc = try Emulator.initFromRomBytes(testing.allocator, rom);
    defer ntsc.deinit(testing.allocator);
    ntsc.reset();
    ntsc.runFrame();
    try testing.expectEqual(@as(u16, 0x9F21), ntsc.read16(0x00FF_0000));

    var pal = try Emulator.initFromRomBytes(testing.allocator, rom);
    defer pal.deinit(testing.allocator);
    pal.reset();
    pal.setPalMode(true);
    pal.runFrame();
    try testing.expectEqual(@as(u16, 0x8421), pal.read16(0x00FF_0000));
}

test "frame scheduler stalls cpu while vdp dma owns the bus" {
    const rom = try seedResetNopsRom(testing.allocator, 1);
    defer testing.allocator.free(rom);

    var emulator = try Emulator.initFromRomBytes(testing.allocator, rom);
    defer emulator.deinit(testing.allocator);
    emulator.reset();
    emulator.write16(0x00E0_0000, 0xABCD);

    const pc_before = emulator.cpuState().program_counter;
    emulator.configureVdpDataPort(0x1, 0x0000, 2);
    emulator.forceMemoryToVramDma(0x00E0_0000, 1);

    emulator.runMasterSlice(8);

    try testing.expectEqual(pc_before, emulator.cpuState().program_counter);
    try testing.expect(emulator.vdpIsDmaActive());
    try testing.expect(emulator.vdpShouldHaltCpu());
}

test "frame scheduler does not stall cpu for pending vdp fifo writes" {
    const rom = try seedResetNopsRom(testing.allocator, 2);
    defer testing.allocator.free(rom);

    var emulator = try Emulator.initFromRomBytes(testing.allocator, rom);
    defer emulator.deinit(testing.allocator);
    emulator.reset();

    emulator.configureVdpDataPort(0x1, 0x0000, 2);
    emulator.writeVdpData(0x0102);
    emulator.writeVdpData(0x0304);
    emulator.writeVdpData(0x0506);
    emulator.writeVdpData(0x0708);
    emulator.writeVdpData(0x090A);

    try testing.expect(!emulator.vdpShouldHaltCpu());

    const pc_before = emulator.cpuState().program_counter;
    emulator.runMasterSlice(56);

    try testing.expect(emulator.cpuState().program_counter != pc_before);
}

test "frame scheduler consumes pending z80-induced m68k wait before running cpu" {
    const rom = try seedResetNopsRom(testing.allocator, 2);
    defer testing.allocator.free(rom);

    var emulator = try Emulator.initFromRomBytes(testing.allocator, rom);
    defer emulator.deinit(testing.allocator);
    emulator.reset();

    emulator.setPendingM68kWaitMasterCycles(clock.m68kCyclesToMaster(11));

    const pc_before = emulator.cpuState().program_counter;
    emulator.runMasterSlice(56);
    try testing.expectEqual(pc_before, emulator.cpuState().program_counter);
    try testing.expectEqual(clock.m68kCyclesToMaster(3), emulator.pendingM68kWaitMasterCycles());

    emulator.runMasterSlice(clock.m68kCyclesToMaster(3));
    try testing.expectEqual(pc_before, emulator.cpuState().program_counter);
    try testing.expectEqual(@as(u32, 0), emulator.pendingM68kWaitMasterCycles());

    emulator.runMasterSlice(56);
    try testing.expect(emulator.cpuState().program_counter != pc_before);
}

test "frame scheduler interleaves z80 contention within a master slice" {
    const rom = try seedResetNopsRom(testing.allocator, 32);
    defer testing.allocator.free(rom);

    var base = try Emulator.initFromRomBytes(testing.allocator, rom);
    defer base.deinit(testing.allocator);
    base.reset();
    base.runMasterSlice(224);

    var contended = try Emulator.initFromRomBytes(testing.allocator, rom);
    defer contended.deinit(testing.allocator);
    contended.reset();
    contended.writeRomByte(0x0000, 0x12);
    contended.z80Reset();
    contended.z80WriteByte(0x0000, 0x3A);
    contended.z80WriteByte(0x0001, 0x00);
    contended.z80WriteByte(0x0002, 0x80);
    contended.z80WriteByte(0x0003, 0x18);
    contended.z80WriteByte(0x0004, 0xFB);
    contended.runMasterSlice(224);

    try testing.expect(contended.cpuState().program_counter < base.cpuState().program_counter);
    try testing.expect(contended.cpuState().program_counter > 0x0200);
    try testing.expect(contended.z80ProgramCounter() != 0);
}

test "frame scheduler interleaves z80 vdp-window contention within a master slice" {
    const rom = try seedResetNopsRom(testing.allocator, 32);
    defer testing.allocator.free(rom);

    var base = try Emulator.initFromRomBytes(testing.allocator, rom);
    defer base.deinit(testing.allocator);
    base.reset();
    base.runMasterSlice(224);

    var contended = try Emulator.initFromRomBytes(testing.allocator, rom);
    defer contended.deinit(testing.allocator);
    contended.reset();
    contended.z80Reset();
    contended.z80WriteByte(0x0000, 0x21);
    contended.z80WriteByte(0x0001, 0x08);
    contended.z80WriteByte(0x0002, 0x7F);
    contended.z80WriteByte(0x0003, 0x7E);
    contended.z80WriteByte(0x0004, 0x18);
    contended.z80WriteByte(0x0005, 0xFD);
    contended.runMasterSlice(224);

    try testing.expect(contended.cpuState().program_counter < base.cpuState().program_counter);
    try testing.expect(contended.cpuState().program_counter > 0x0200);
    try testing.expect(contended.z80ProgramCounter() != 0);
}

test "frame scheduler does not stall cpu for z80 psg writes" {
    const rom = try seedResetNopsRom(testing.allocator, 32);
    defer testing.allocator.free(rom);

    var base = try Emulator.initFromRomBytes(testing.allocator, rom);
    defer base.deinit(testing.allocator);
    base.reset();
    base.runMasterSlice(448);

    var psg = try Emulator.initFromRomBytes(testing.allocator, rom);
    defer psg.deinit(testing.allocator);
    psg.reset();
    psg.z80Reset();
    psg.z80WriteByte(0x0000, 0x3E);
    psg.z80WriteByte(0x0001, 0x90);
    psg.z80WriteByte(0x0002, 0x21);
    psg.z80WriteByte(0x0003, 0x11);
    psg.z80WriteByte(0x0004, 0x7F);
    psg.z80WriteByte(0x0005, 0x77);
    psg.z80WriteByte(0x0006, 0x18);
    psg.z80WriteByte(0x0007, 0xFD);
    psg.runMasterSlice(448);

    try testing.expectEqual(base.cpuState().program_counter, psg.cpuState().program_counter);
    try testing.expect(psg.z80ProgramCounter() >= 0x0005);
    try testing.expectEqual(@as(u32, 0), psg.pendingM68kWaitMasterCycles());
}

test "frame scheduler interleaves z80 vdp-window writes within a master slice" {
    const rom = try seedResetNopsRom(testing.allocator, 32);
    defer testing.allocator.free(rom);

    var base = try Emulator.initFromRomBytes(testing.allocator, rom);
    defer base.deinit(testing.allocator);
    base.reset();
    base.runMasterSlice(448);

    var contended = try Emulator.initFromRomBytes(testing.allocator, rom);
    defer contended.deinit(testing.allocator);
    contended.reset();
    contended.z80Reset();
    contended.z80WriteByte(0x0000, 0x3E);
    contended.z80WriteByte(0x0001, 0x5A);
    contended.z80WriteByte(0x0002, 0x21);
    contended.z80WriteByte(0x0003, 0x08);
    contended.z80WriteByte(0x0004, 0x7F);
    contended.z80WriteByte(0x0005, 0x77);
    contended.z80WriteByte(0x0006, 0x18);
    contended.z80WriteByte(0x0007, 0xFD);
    contended.runMasterSlice(448);

    try testing.expect(contended.cpuState().program_counter < base.cpuState().program_counter);
    try testing.expect(contended.cpuState().program_counter > 0x0200);
    try testing.expect(contended.z80ProgramCounter() >= 0x0005);
}

test "read16 routes only the primary io window through io handler" {
    const rom = try seedResetNopsRom(testing.allocator, 1);
    defer testing.allocator.free(rom);

    var emulator = try Emulator.initFromRomBytes(testing.allocator, rom);
    defer emulator.deinit(testing.allocator);
    emulator.reset();

    const base = emulator.read16(0xA10000);
    try testing.expectEqual(@as(u16, 0xA0A0), base);

    emulator.write16(0xE00000, 0x5A3C);
    _ = emulator.read16(0xE00000);

    const open_bus = emulator.read16(0xA10020);
    try testing.expectEqual(@as(u16, 0x5A3C), open_bus);
    try testing.expect(open_bus != base);
}

test "pal 240-line mode exposes and renders the extra visible scanlines" {
    const rom = try seedResetNopsRom(testing.allocator, 1);
    defer testing.allocator.free(rom);

    var emulator = try Emulator.initFromRomBytes(testing.allocator, rom);
    defer emulator.deinit(testing.allocator);
    emulator.reset();

    emulator.setPalMode(true);
    emulator.setVdpRegister(0, 0x04);
    emulator.setVdpRegister(1, 0x48);
    emulator.configureVdpDataPort(0x03, 0x0000, 2);
    emulator.writeVdpData(0x000E);

    emulator.runFrame();

    const fb = emulator.framebuffer();
    const red: u32 = 0xFFFF0000;
    const first_extended_line = @as(usize, clock.ntsc_visible_lines) * 320;
    const last_visible_line = (@as(usize, clock.pal_visible_lines) - 1) * 320;

    try testing.expectEqual(@as(usize, 320) * @as(usize, clock.pal_visible_lines), fb.len);
    try testing.expectEqual(red, fb[first_extended_line]);
    try testing.expectEqual(red, fb[last_visible_line]);
}

test "interlace mode 2 alternates field length by one scanline" {
    const rom = try seedResetNopsRom(testing.allocator, 1);
    defer testing.allocator.free(rom);

    var emulator = try Emulator.initFromRomBytes(testing.allocator, rom);
    defer emulator.deinit(testing.allocator);
    emulator.reset();

    emulator.setVdpRegister(12, 0x06);

    emulator.runFrame();
    try testing.expectEqual(@as(u16, clock.ntsc_lines_per_frame - 1), emulator.vdpScanline());

    emulator.runFrame();
    try testing.expectEqual(@as(u16, clock.ntsc_lines_per_frame), emulator.vdpScanline());
}

test "window plane uses tile height shift for interlace mode 2 tile row" {
    const rom = try seedResetNopsRom(testing.allocator, 1);
    defer testing.allocator.free(rom);

    var emulator = try Emulator.initFromRomBytes(testing.allocator, rom);
    defer emulator.deinit(testing.allocator);
    emulator.reset();

    emulator.setVdpRegister(0, 0x04);
    emulator.setVdpRegister(1, 0x40);
    emulator.setVdpRegister(3, 0x04);
    emulator.setVdpRegister(12, 0x06);
    emulator.setVdpRegister(17, 0x80);
    emulator.setVdpRegister(18, 0x80);

    emulator.configureVdpDataPort(0x03, 0x0002, 2);
    emulator.writeVdpData(0x000E);
    emulator.writeVdpData(0x00E0);

    emulator.configureVdpDataPort(0x01, 0x0020, 2);
    emulator.writeVdpData(0x1111);
    emulator.writeVdpData(0x1111);

    emulator.configureVdpDataPort(0x01, 0x0040, 2);
    emulator.writeVdpData(0x2222);
    emulator.writeVdpData(0x2222);

    emulator.configureVdpDataPort(0x01, 0x0060, 2);
    emulator.writeVdpData(0x2222);
    emulator.writeVdpData(0x2222);

    emulator.configureVdpDataPort(0x01, 0x1000, 2);
    emulator.writeVdpData(0x0000);

    emulator.configureVdpDataPort(0x01, 0x1040, 2);
    emulator.writeVdpData(0x0001);

    emulator.runFrame();

    const fb = emulator.framebuffer();
    const red: u32 = 0xFFFF0000;
    const green: u32 = 0xFF00FF00;

    try testing.expectEqual(red, fb[8 * 320]);
    try testing.expect(fb[8 * 320] != green);

    try testing.expectEqual(green, fb[16 * 320]);
}

test "frame scheduler carries instruction overshoot between slices" {
    const rom = try seedResetNopsRom(testing.allocator, 2);
    defer testing.allocator.free(rom);

    var emulator = try Emulator.initFromRomBytes(testing.allocator, rom);
    defer emulator.deinit(testing.allocator);
    emulator.reset();

    emulator.runMasterSlice(7);
    try testing.expectEqual(@as(u32, 0x0202), emulator.cpuState().program_counter);
    try testing.expectEqual(@as(u32, 21), emulator.cpuDebtMasterCycles());

    emulator.runMasterSlice(21);
    try testing.expectEqual(@as(u32, 0x0202), emulator.cpuState().program_counter);
    try testing.expectEqual(@as(u32, 0), emulator.cpuDebtMasterCycles());

    emulator.runMasterSlice(7);
    try testing.expectEqual(@as(u32, 0x0204), emulator.cpuState().program_counter);
    try testing.expectEqual(@as(u32, 21), emulator.cpuDebtMasterCycles());
}
