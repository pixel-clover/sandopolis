const std = @import("std");
const testing = std.testing;
const sandopolis = @import("sandopolis_src");
const clock = sandopolis.clock;
const Emulator = sandopolis.testing.Emulator;

const graphics_sampler_rom = "tests/testroms/Graphics & Joystick Sampler by Charles Doty (PD).bin";
const window_test_rom = "tests/testroms/Window Test by Fonzie (PD).bin";
const fm_test_rom = "tests/testroms/FM Test by DevSter (PD).bin";

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
    contended.writeRomByte(0x0000, 0x12);
    contended.z80Reset();
    contended.z80WriteByte(0x0000, 0x3A);
    contended.z80WriteByte(0x0001, 0x00);
    contended.z80WriteByte(0x0002, 0x80);
    contended.z80WriteByte(0x0003, 0x18);
    contended.z80WriteByte(0x0004, 0xFB);
    contended.reset();
    contended.runMasterSlice(224);

    try testing.expect(contended.cpuState().program_counter < base.cpuState().program_counter);
    try testing.expect(contended.cpuState().program_counter > 0x0200);
    try testing.expect(contended.z80ProgramCounter() != 0);
}

test "read16 routes full io window range through io handler" {
    const rom = try seedResetNopsRom(testing.allocator, 1);
    defer testing.allocator.free(rom);

    var emulator = try Emulator.initFromRomBytes(testing.allocator, rom);
    defer emulator.deinit(testing.allocator);
    emulator.reset();

    const base = emulator.read16(0xA10000);
    try testing.expect(base != 0);

    const mirrored = emulator.read16(0xA10020);
    try testing.expectEqual(base, mirrored);
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
