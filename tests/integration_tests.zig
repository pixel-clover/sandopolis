const std = @import("std");
const testing = std.testing;
const sandopolis = @import("sandopolis_src");
const clock = sandopolis.clock;
const Bus = sandopolis.Bus;
const Cpu = sandopolis.Cpu;
const Machine = sandopolis.Machine;

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

fn makeGenesisRomWithResetProgram(allocator: std.mem.Allocator, program: []const u8) ![]u8 {
    var rom = try allocator.alloc(u8, 0x4000);
    @memset(rom, 0);
    @memcpy(rom[0x100..0x104], "SEGA");
    std.mem.writeInt(u32, rom[0..4], 0x00FF_FE00, .big);
    std.mem.writeInt(u32, rom[4..8], 0x0000_0200, .big);
    @memcpy(rom[0x0200 .. 0x0200 + program.len], program);
    return rom;
}

fn resetCpuForBus(bus: *Bus) Cpu {
    var cpu = Cpu.init();
    var memory = bus.cpuMemory();
    cpu.reset(&memory);
    return cpu;
}

test "cpu reset applies fallback vectors when ROM vectors are invalid" {
    var bus = try Bus.init(testing.allocator, null);
    defer bus.deinit(testing.allocator);

    std.mem.writeInt(u32, bus.rom[0..4], 0x0000_0000, .big);
    std.mem.writeInt(u32, bus.rom[4..8], 0x0000_0200, .big);

    var cpu = Cpu.init();
    var memory = bus.cpuMemory();
    cpu.reset(&memory);

    try testing.expectEqual(@as(u32, 0x00FF_FE00), @as(u32, cpu.core.a_regs[7].l));
    try testing.expectEqual(@as(u32, 0x0000_0200), @as(u32, cpu.core.pc));
}

test "machine runMasterSlice advances the reset program through the public API" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rom = try makeGenesisRomWithResetProgram(testing.allocator, &[_]u8{
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

    try testing.expectEqual(@as(u32, 0x0000_0200), @as(u32, machine.cpu.core.pc));

    machine.runMasterSlice(clock.m68kCyclesToMaster(4));

    try testing.expectEqual(@as(u32, 0x0000_0202), @as(u32, machine.cpu.core.pc));
}

test "machine persistent cartridge sram flushes to save file and reloads" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rom = try makeRomWithSramHeader(testing.allocator, 0x200000, 0xF8, 0x200001, 0x203FFF);
    defer testing.allocator.free(rom);
    try tmp.dir.writeFile(.{ .sub_path = "persist.md", .data = rom });

    const rom_path = try tmp.dir.realpathAlloc(testing.allocator, "persist.md");
    defer testing.allocator.free(rom_path);

    {
        var machine = try Machine.init(testing.allocator, rom_path);
        defer machine.deinit(testing.allocator);
        machine.reset();

        const save_path = machine.bus.persistentSavePath() orelse unreachable;
        machine.bus.write8(0x0020_0001, 0xA5);
        machine.bus.write8(0x0020_0003, 0x5A);
        try machine.flushPersistentStorage();

        var save_file = try std.fs.cwd().openFile(save_path, .{});
        defer save_file.close();

        var first_bytes: [2]u8 = undefined;
        const bytes_read = try save_file.readAll(&first_bytes);
        try testing.expectEqual(@as(usize, 2), bytes_read);
        try testing.expectEqualSlices(u8, &[_]u8{ 0xA5, 0x5A }, first_bytes[0..]);
    }

    {
        var machine = try Machine.init(testing.allocator, rom_path);
        defer machine.deinit(testing.allocator);

        try testing.expectEqual(@as(u8, 0xA5), machine.bus.read8(0x0020_0001));
        try testing.expectEqual(@as(u8, 0x5A), machine.bus.read8(0x0020_0003));
    }
}

test "cpu data-port writes accrue vdp fifo wait accounting" {
    var bus = try Bus.init(testing.allocator, null);
    defer bus.deinit(testing.allocator);

    std.mem.writeInt(u32, bus.rom[0..4], 0x00FF_FE00, .big);
    std.mem.writeInt(u32, bus.rom[4..8], 0x0000_0200, .big);

    var pc: u32 = 0x0200;
    bus.rom[pc] = 0x33;
    bus.rom[pc + 1] = 0xFC;
    pc += 2;
    bus.rom[pc] = 0xAB;
    bus.rom[pc + 1] = 0xCD;
    pc += 2;
    bus.rom[pc] = 0x00;
    bus.rom[pc + 1] = 0xC0;
    pc += 2;
    bus.rom[pc] = 0x00;
    bus.rom[pc + 1] = 0x00;
    pc += 2;
    bus.rom[pc] = 0x4E;
    bus.rom[pc + 1] = 0x71;

    bus.vdp.regs[15] = 2;
    bus.vdp.code = 0x1;
    bus.vdp.addr = 0x0000;
    bus.vdp.writeData(0x0102);
    bus.vdp.writeData(0x0304);
    bus.vdp.writeData(0x0506);
    bus.vdp.writeData(0x0708);

    const expected_wait = bus.vdp.dataPortWriteWaitMasterCycles();
    try testing.expect(expected_wait > 0);

    var cpu = resetCpuForBus(&bus);
    var memory = bus.cpuMemory();
    const ran = cpu.runCycles(&memory, 64);
    try testing.expect(ran != 0);

    const wait = cpu.takeWaitAccounting();
    try testing.expect(wait.m68k_cycles > 0);
    try testing.expectEqual(expected_wait, wait.master_cycles);
    try testing.expect(!bus.vdp.shouldHaltCpu());
    try testing.expectEqual(@as(u16, 0x000A), bus.vdp.addr);
}

test "cpu data-port reads accrue vdp fifo drain wait accounting" {
    var bus = try Bus.init(testing.allocator, null);
    defer bus.deinit(testing.allocator);
    var cpu = resetCpuForBus(&bus);
    var memory = bus.cpuMemory();

    bus.vdp.regs[15] = 2;
    bus.vdp.code = 0x1;
    bus.vdp.addr = 0x0000;
    bus.vdp.writeData(0xABCD);

    const expected_wait = bus.vdp.dataPortReadWaitMasterCycles();
    try testing.expect(expected_wait > 0);

    cpu.noteBusAccessWait(&memory, 0x00C0_0000, 2, false);
    const wait = cpu.takeWaitAccounting();
    try testing.expect(wait.m68k_cycles > 0);
    try testing.expectEqual(expected_wait, wait.master_cycles);
}

test "cpu z80-window accesses accrue wait accounting only when bus is granted" {
    var bus = try Bus.init(testing.allocator, null);
    defer bus.deinit(testing.allocator);
    var cpu = resetCpuForBus(&bus);
    var memory = bus.cpuMemory();

    cpu.noteBusAccessWait(&memory, 0x00A0_4000, 1, false);
    var wait = cpu.takeWaitAccounting();
    try testing.expectEqual(@as(u32, 0), wait.m68k_cycles);
    try testing.expectEqual(@as(u32, 0), wait.master_cycles);

    bus.write16(0x00A1_1100, 0x0100);

    cpu.noteBusAccessWait(&memory, 0x00A0_4000, 1, false);
    wait = cpu.takeWaitAccounting();
    try testing.expectEqual(@as(u32, 1), wait.m68k_cycles);
    try testing.expectEqual(clock.m68kCyclesToMaster(1), wait.master_cycles);

    cpu.noteBusAccessWait(&memory, 0x00A0_8000, 4, false);
    wait = cpu.takeWaitAccounting();
    try testing.expectEqual(@as(u32, 2), wait.m68k_cycles);
    try testing.expectEqual(clock.m68kCyclesToMaster(2), wait.master_cycles);

    bus.write16(0x00A1_1200, 0x0000);

    cpu.noteBusAccessWait(&memory, 0x00A0_4000, 1, false);
    wait = cpu.takeWaitAccounting();
    try testing.expectEqual(@as(u32, 0), wait.m68k_cycles);
    try testing.expectEqual(@as(u32, 0), wait.master_cycles);
}

test "cpu formats current instruction with the built-in disassembler" {
    var bus = try Bus.init(testing.allocator, null);
    defer bus.deinit(testing.allocator);

    std.mem.writeInt(u32, bus.rom[0..4], 0x00FF_FE00, .big);
    std.mem.writeInt(u32, bus.rom[4..8], 0x0000_0200, .big);
    bus.rom[0x0200] = 0x4E;
    bus.rom[0x0201] = 0x71;

    var cpu = resetCpuForBus(&bus);
    var memory = bus.cpuMemory();

    var buffer: [64]u8 = undefined;
    const text = cpu.formatCurrentInstruction(&memory, &buffer);
    try testing.expect(std.mem.indexOf(u8, text, "NOP") != null);
}
