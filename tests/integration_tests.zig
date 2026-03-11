const std = @import("std");
const testing = std.testing;
const sandopolis = @import("sandopolis_src");
const clock = sandopolis.clock;
const Machine = sandopolis.Machine;
const Emulator = sandopolis.testing.Emulator;

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

test "machine reset applies fallback vectors when ROM vectors are invalid" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rom = try makeGenesisRom(testing.allocator, 0x0100_0001, 0x0000_0000, &.{});
    defer testing.allocator.free(rom);
    try tmp.dir.writeFile(.{ .sub_path = "fallback.bin", .data = rom });

    const rom_path = try tmp.dir.realpathAlloc(testing.allocator, "fallback.bin");
    defer testing.allocator.free(rom_path);

    var machine = try Machine.init(testing.allocator, rom_path);
    defer machine.deinit(testing.allocator);
    machine.reset();

    const cpu = machine.cpuState();
    try testing.expectEqual(@as(u32, 0x00FF_FE00), cpu.stack_pointer);
    try testing.expectEqual(@as(u32, 0x0000_0200), cpu.program_counter);
}

test "machine reset preserves zero stack pointer when reset pc is valid" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rom = try makeGenesisRom(testing.allocator, 0x0000_0000, 0x0000_0200, &.{ 0x4E, 0x71 });
    defer testing.allocator.free(rom);
    try tmp.dir.writeFile(.{ .sub_path = "zero-sp.bin", .data = rom });

    const rom_path = try tmp.dir.realpathAlloc(testing.allocator, "zero-sp.bin");
    defer testing.allocator.free(rom_path);

    var machine = try Machine.init(testing.allocator, rom_path);
    defer machine.deinit(testing.allocator);
    machine.reset();

    const cpu = machine.cpuState();
    try testing.expectEqual(@as(u32, 0x0000_0000), cpu.stack_pointer);
    try testing.expectEqual(@as(u32, 0x0000_0200), cpu.program_counter);
}

test "machine runMasterSlice advances the reset program through the public API" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rom = try makeGenesisRom(testing.allocator, 0x00FF_FE00, 0x0000_0200, &[_]u8{
        0x4E, 0x71,
        0x4E, 0x71,
    });
    defer testing.allocator.free(rom);
    try tmp.dir.writeFile(.{ .sub_path = "boot.bin", .data = rom });

    const rom_path = try tmp.dir.realpathAlloc(testing.allocator, "boot.bin");
    defer testing.allocator.free(rom_path);

    var machine = try Machine.init(testing.allocator, rom_path);
    defer machine.deinit(testing.allocator);
    machine.reset();

    try testing.expectEqual(@as(u32, 0x0000_0200), machine.cpuState().program_counter);

    machine.runMasterSlice(clock.m68kCyclesToMaster(4));

    try testing.expectEqual(@as(u32, 0x0000_0202), machine.cpuState().program_counter);
}

test "machine public API exposes metadata framebuffer and timing mode from ROM bytes" {
    const rom = try makeGenesisRom(testing.allocator, 0x00FF_FE00, 0x0000_0200, &[_]u8{
        0x4E, 0x71,
    });
    defer testing.allocator.free(rom);

    var machine = try Machine.initFromRomBytes(testing.allocator, rom);
    defer machine.deinit(testing.allocator);
    machine.reset();

    const metadata = machine.romMetadata();
    try testing.expect(metadata.console != null);
    try testing.expect(metadata.title != null);
    try testing.expectEqualStrings("SEGA", metadata.console.?[0..4]);
    try testing.expectEqual(@as(u32, 0x00FF_FE00), metadata.reset_stack_pointer);
    try testing.expectEqual(@as(u32, 0x0000_0200), metadata.reset_program_counter);
    try testing.expectEqual(@as(usize, 320 * 224), machine.framebuffer().len);
    try testing.expect(!machine.palMode());
}

test "machine public snapshot restores cpu state" {
    const rom = try makeGenesisRom(testing.allocator, 0x00FF_FE00, 0x0000_0200, &[_]u8{
        0x4E, 0x71,
        0x4E, 0x71,
        0x60, 0xFC,
    });
    defer testing.allocator.free(rom);

    var machine = try Machine.initFromRomBytes(testing.allocator, rom);
    defer machine.deinit(testing.allocator);
    machine.reset();

    var snapshot = try machine.captureSnapshot(testing.allocator);
    defer snapshot.deinit(testing.allocator);

    machine.runMasterSlice(clock.m68kCyclesToMaster(4));
    machine.runMasterSlice(clock.m68kCyclesToMaster(4));
    try testing.expectEqual(@as(u32, 0x0000_0204), machine.cpuState().program_counter);

    try machine.restoreSnapshot(testing.allocator, &snapshot);
    try testing.expectEqual(@as(u32, 0x0000_0200), machine.cpuState().program_counter);
}

test "emulator persistent cartridge sram flushes to save file and reloads" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rom = try makeRomWithSramHeader(testing.allocator, 0x200000, 0xF8, 0x200001, 0x203FFF);
    defer testing.allocator.free(rom);
    try tmp.dir.writeFile(.{ .sub_path = "persist.md", .data = rom });

    const rom_path = try tmp.dir.realpathAlloc(testing.allocator, "persist.md");
    defer testing.allocator.free(rom_path);

    {
        var emulator = try Emulator.init(testing.allocator, rom_path);
        defer emulator.deinit(testing.allocator);
        emulator.reset();

        const save_path = emulator.persistentSavePath() orelse unreachable;
        emulator.write8(0x0020_0001, 0xA5);
        emulator.write8(0x0020_0003, 0x5A);
        try emulator.flushPersistentStorage();

        var save_file = try std.fs.cwd().openFile(save_path, .{});
        defer save_file.close();

        var first_bytes: [2]u8 = undefined;
        const bytes_read = try save_file.readAll(&first_bytes);
        try testing.expectEqual(@as(usize, 2), bytes_read);
        try testing.expectEqualSlices(u8, &[_]u8{ 0xA5, 0x5A }, first_bytes[0..]);
    }

    {
        var emulator = try Emulator.init(testing.allocator, rom_path);
        defer emulator.deinit(testing.allocator);

        try testing.expectEqual(@as(u8, 0xA5), emulator.read8(0x0020_0001));
        try testing.expectEqual(@as(u8, 0x5A), emulator.read8(0x0020_0003));
    }
}

test "cpu data-port writes accrue vdp fifo wait accounting" {
    const program = [_]u8{
        0x33, 0xFC,
        0xAB, 0xCD,
        0x00, 0xC0,
        0x00, 0x00,
        0x4E, 0x71,
    };
    const rom = try makeGenesisRom(testing.allocator, 0x00FF_FE00, 0x0000_0200, &program);
    defer testing.allocator.free(rom);

    var emulator = try Emulator.initFromRomBytes(testing.allocator, rom);
    defer emulator.deinit(testing.allocator);
    emulator.reset();

    emulator.configureVdpDataPort(0x1, 0x0000, 2);
    emulator.writeVdpData(0x0102);
    emulator.writeVdpData(0x0304);
    emulator.writeVdpData(0x0506);
    emulator.writeVdpData(0x0708);

    const expected_wait = emulator.vdpDataPortWriteWaitMasterCycles();
    try testing.expect(expected_wait > 0);

    const ran = emulator.runCpuCycles(64);
    try testing.expect(ran != 0);

    const wait = emulator.takeCpuWaitAccounting();
    try testing.expect(wait.m68k_cycles > 0);
    try testing.expectEqual(expected_wait, wait.master_cycles);
    try testing.expect(!emulator.vdpShouldHaltCpu());
    try testing.expectEqual(@as(u16, 0x000A), emulator.vdpAddr());
}

test "cpu data-port reads accrue vdp fifo drain wait accounting" {
    var emulator = try Emulator.initEmpty(testing.allocator);
    defer emulator.deinit(testing.allocator);
    emulator.reset();

    emulator.configureVdpDataPort(0x1, 0x0000, 2);
    emulator.writeVdpData(0xABCD);

    const expected_wait = emulator.vdpDataPortReadWaitMasterCycles();
    try testing.expect(expected_wait > 0);

    emulator.noteCpuBusAccessWait(0x00C0_0000, 2, false);
    const wait = emulator.takeCpuWaitAccounting();
    try testing.expect(wait.m68k_cycles > 0);
    try testing.expectEqual(expected_wait, wait.master_cycles);
}

test "cpu z80-window accesses accrue wait accounting only when bus is granted" {
    var emulator = try Emulator.initEmpty(testing.allocator);
    defer emulator.deinit(testing.allocator);
    emulator.reset();

    emulator.noteCpuBusAccessWait(0x00A0_4000, 1, false);
    var wait = emulator.takeCpuWaitAccounting();
    try testing.expectEqual(@as(u32, 0), wait.m68k_cycles);
    try testing.expectEqual(@as(u32, 0), wait.master_cycles);

    emulator.setZ80BusRequest(0x0100);

    emulator.noteCpuBusAccessWait(0x00A0_4000, 1, false);
    wait = emulator.takeCpuWaitAccounting();
    try testing.expectEqual(@as(u32, 1), wait.m68k_cycles);
    try testing.expectEqual(clock.m68kCyclesToMaster(1), wait.master_cycles);

    emulator.noteCpuBusAccessWait(0x00A0_8000, 4, false);
    wait = emulator.takeCpuWaitAccounting();
    try testing.expectEqual(@as(u32, 2), wait.m68k_cycles);
    try testing.expectEqual(clock.m68kCyclesToMaster(2), wait.master_cycles);

    emulator.setZ80ResetControl(0x0000);

    emulator.noteCpuBusAccessWait(0x00A0_4000, 1, false);
    wait = emulator.takeCpuWaitAccounting();
    try testing.expectEqual(@as(u32, 0), wait.m68k_cycles);
    try testing.expectEqual(@as(u32, 0), wait.master_cycles);
}

test "cpu formats current instruction with the built-in disassembler" {
    const rom = try makeGenesisRom(testing.allocator, 0x00FF_FE00, 0x0000_0200, &[_]u8{ 0x4E, 0x71 });
    defer testing.allocator.free(rom);

    var emulator = try Emulator.initFromRomBytes(testing.allocator, rom);
    defer emulator.deinit(testing.allocator);
    emulator.reset();

    var buffer: [64]u8 = undefined;
    const text = emulator.formatCurrentInstruction(&buffer);
    try testing.expect(std.mem.indexOf(u8, text, "NOP") != null);
}
