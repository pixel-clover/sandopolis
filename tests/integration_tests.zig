const std = @import("std");
const platform = @import("sandopolis_src").platform;
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

test "machine reset keeps the ROM stack pointer and falls back only for the pc" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rom = try makeGenesisRom(testing.allocator, 0x0100_0001, 0x0000_0000, &.{});
    defer testing.allocator.free(rom);
    try tmp.dir.writeFile(platform.io(), .{ .sub_path = "fallback.bin", .data = rom });

    const rom_path = try (platform.Dir{ .d = tmp.dir }).realpathAlloc(testing.allocator, "fallback.bin");
    defer testing.allocator.free(rom_path);

    var machine = try Machine.init(testing.allocator, rom_path);
    defer machine.deinit(testing.allocator);
    machine.reset();

    // The 68000 drives a 24-bit bus, so a stack pointer above 0x00FFFFFF is
    // not invalid: it simply wraps. Substituting a "sane" default instead
    // moves the stack onto whatever the program keeps at that address, which
    // is how the Mega CD BIOS (SSP 0xFFFFFD00) used to lose its mailbox. Only
    // an unusable reset pc is replaced.
    const cpu = machine.cpuState();
    try testing.expectEqual(@as(u32, 0x0100_0001), cpu.stack_pointer);
    try testing.expectEqual(@as(u32, 0x0000_0200), cpu.program_counter);
}

test "machine reset preserves zero stack pointer when reset pc is valid" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rom = try makeGenesisRom(testing.allocator, 0x0000_0000, 0x0000_0200, &.{ 0x4E, 0x71 });
    defer testing.allocator.free(rom);
    try tmp.dir.writeFile(platform.io(), .{ .sub_path = "zero-sp.bin", .data = rom });

    const rom_path = try (platform.Dir{ .d = tmp.dir }).realpathAlloc(testing.allocator, "zero-sp.bin");
    defer testing.allocator.free(rom_path);

    var machine = try Machine.init(testing.allocator, rom_path);
    defer machine.deinit(testing.allocator);
    machine.reset();

    const cpu = machine.cpuState();
    try testing.expectEqual(@as(u32, 0x0000_0000), cpu.stack_pointer);
    try testing.expectEqual(@as(u32, 0x0000_0200), cpu.program_counter);
}

test "testing emulator init starts from the ROM reset vector" {
    const rom = try makeGenesisRom(testing.allocator, 0x00FF_FE00, 0x0000_0200, &[_]u8{
        0x4E, 0x71,
        0x4E, 0x71,
    });
    defer testing.allocator.free(rom);

    var emulator = try Emulator.initFromRomBytes(testing.allocator, rom);
    defer emulator.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 0x0000_0200), emulator.cpuPc());

    emulator.runMasterSlice(clock.m68kCyclesToMaster(4));
    try testing.expectEqual(@as(u32, 0x0000_0202), emulator.cpuPc());
}

test "machine runMasterSlice advances the reset program through the public API" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rom = try makeGenesisRom(testing.allocator, 0x00FF_FE00, 0x0000_0200, &[_]u8{
        0x4E, 0x71,
        0x4E, 0x71,
    });
    defer testing.allocator.free(rom);
    try tmp.dir.writeFile(platform.io(), .{ .sub_path = "boot.bin", .data = rom });

    const rom_path = try (platform.Dir{ .d = tmp.dir }).realpathAlloc(testing.allocator, "boot.bin");
    defer testing.allocator.free(rom_path);

    var machine = try Machine.init(testing.allocator, rom_path);
    defer machine.deinit(testing.allocator);
    machine.reset();

    try testing.expectEqual(@as(u32, 0x0000_0200), machine.cpuState().program_counter);

    machine.runMasterSlice(clock.m68kCyclesToMaster(4));

    try testing.expectEqual(@as(u32, 0x0000_0202), machine.cpuState().program_counter);
}

test "machine public API softReset rewinds the cpu to the reset vector" {
    const rom = try makeGenesisRom(testing.allocator, 0x00FF_FE00, 0x0000_0200, &[_]u8{
        0x4E, 0x71,
        0x4E, 0x71,
        0x60, 0xFC,
    });
    defer testing.allocator.free(rom);

    var machine = try Machine.initFromRomBytes(testing.allocator, rom);
    defer machine.deinit(testing.allocator);
    machine.reset();

    machine.runMasterSlice(clock.m68kCyclesToMaster(8));
    try testing.expectEqual(@as(u32, 0x0000_0204), machine.cpuState().program_counter);

    machine.softReset();
    try testing.expectEqual(@as(u32, 0x0000_0200), machine.cpuState().program_counter);
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
    try tmp.dir.writeFile(platform.io(), .{ .sub_path = "persist.md", .data = rom });

    const rom_path = try (platform.Dir{ .d = tmp.dir }).realpathAlloc(testing.allocator, "persist.md");
    defer testing.allocator.free(rom_path);

    {
        var emulator = try Emulator.init(testing.allocator, rom_path);
        defer emulator.deinit(testing.allocator);
        emulator.reset();

        const save_path = emulator.persistentSavePath() orelse unreachable;
        emulator.write8(0x0020_0001, 0xA5);
        emulator.write8(0x0020_0003, 0x5A);
        try emulator.flushPersistentStorage();

        var save_file = try platform.cwd().openFile(save_path, .{});
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
    // The CPU resumes from a port stall on its own clock edge, so the
    // charged wait is the VDP's raw slot distance rounded up to a whole
    // number of 68K clocks (Genesis Plus GX: (((cycles + 6) / 7) * 7)).
    try testing.expectEqual(clock.roundMasterWaitToM68kPhase(expected_wait), wait.master_cycles);
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
    // See the write-accounting test: port stalls release on the 68K's
    // clock edge, so the charged wait rounds up to a whole 68K clock.
    try testing.expectEqual(clock.roundMasterWaitToM68kPhase(expected_wait), wait.master_cycles);
}

test "cpu z80-window accesses accrue wait accounting only when bus is granted" {
    var emulator = try Emulator.initEmpty(testing.allocator);
    defer emulator.deinit(testing.allocator);
    emulator.reset();

    emulator.noteCpuBusAccessWait(0x00A0_4000, 1, false);
    var wait = emulator.takeCpuWaitAccounting();
    try testing.expectEqual(@as(u32, 0), wait.m68k_cycles);
    try testing.expectEqual(@as(u32, 0), wait.master_cycles);

    emulator.setZ80ResetControl(0x0100);
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

test "public API exposes ROM checksum validation and product code" {
    // Build a ROM with a known program and correct checksum.
    const program = [_]u8{ 0x4E, 0x71, 0x60, 0xFE }; // NOP, BRA.S -2
    const rom = try makeGenesisRom(testing.allocator, 0x00FF_FE00, 0x0000_0200, &program);
    defer testing.allocator.free(rom);

    // Write a product code into the header.
    @memcpy(rom[0x183..0x18B], "T-123456");

    // Compute correct checksum and write it.
    var checksum: u16 = 0;
    var offset: usize = 0x200;
    while (offset + 1 < rom.len) : (offset += 2) {
        checksum +%= (@as(u16, rom[offset]) << 8) | rom[offset + 1];
    }
    rom[0x18E] = @intCast((checksum >> 8) & 0xFF);
    rom[0x18F] = @intCast(checksum & 0xFF);

    var machine = try Machine.initFromRomBytes(testing.allocator, rom);
    defer machine.deinit(testing.allocator);

    const metadata = machine.romMetadata();
    try testing.expect(metadata.checksum_valid);
    try testing.expectEqual(checksum, metadata.header_checksum);
    try testing.expectEqual(checksum, metadata.computed_checksum);
    try testing.expect(metadata.product_code != null);
    try testing.expectEqualStrings("T-123456", metadata.product_code.?);
}

test "public API detects checksum mismatch for corrupted ROMs" {
    const rom = try makeGenesisRom(testing.allocator, 0x00FF_FE00, 0x0000_0200, &[_]u8{ 0x4E, 0x71 });
    defer testing.allocator.free(rom);

    // Set a wrong checksum.
    rom[0x18E] = 0xDE;
    rom[0x18F] = 0xAD;

    var machine = try Machine.initFromRomBytes(testing.allocator, rom);
    defer machine.deinit(testing.allocator);

    const metadata = machine.romMetadata();
    try testing.expect(!metadata.checksum_valid);
    try testing.expectEqual(@as(u16, 0xDEAD), metadata.header_checksum);
    try testing.expect(metadata.computed_checksum != 0xDEAD);
}

// --- SG-1000 integration ---

const SmsMachine = sandopolis.testing.SmsMachine;

test "sg1000 machine init from rom bytes and run frame produces framebuffer output" {
    // End-to-end: create an SG-1000 machine from ROM bytes, run frames, and
    // verify the TMS9918 VDP produces a non-empty framebuffer.
    // ROM: LD SP,0xC0D0 / DI / set VDP regs for Mode 2 / enable display / halt
    const program = [_]u8{
        0xF3, // DI
        0x31, 0xD0, 0xC0, // LD SP, 0xC0D0
        // Write VDP register 0 = 0x02 (M2=1, Mode 2)
        0x3E, 0x02, // LD A, 0x02
        0xD3, 0xBF, // OUT (0xBF), A
        0x3E, 0x80, // LD A, 0x80 (reg 0)
        0xD3, 0xBF, // OUT (0xBF), A
        // Write VDP register 1 = 0xE2 (display enable, VINT, tall sprites)
        0x3E, 0xE2, // LD A, 0xE2
        0xD3, 0xBF, // OUT (0xBF), A
        0x3E, 0x81, // LD A, 0x81 (reg 1)
        0xD3, 0xBF, // OUT (0xBF), A
        // Write VDP register 7 = 0xF1 (white text on black backdrop)
        0x3E, 0xF1, // LD A, 0xF1
        0xD3, 0xBF, // OUT (0xBF), A
        0x3E, 0x87, // LD A, 0x87 (reg 7)
        0xD3, 0xBF, // OUT (0xBF), A
        // Infinite loop
        0x76, // HALT
    };

    var rom = [_]u8{0} ** 0x4000;
    @memcpy(rom[0..program.len], &program);

    var machine = try SmsMachine.initFromRomBytes(testing.allocator, &rom);
    defer machine.deinit(testing.allocator);
    machine.is_sg1000 = true;
    // bindPointers called lazily by runFrame

    for (0..10) |_| machine.runFrame();

    // VDP should be in TMS Mode 2 with display enabled
    const GraphicsMode = @TypeOf(machine.bus.vdp).GraphicsMode;
    try testing.expectEqual(GraphicsMode.mode2_graphics2, machine.bus.vdp.graphicsMode());
    try testing.expect((machine.bus.vdp.regs[1] & 0x40) != 0); // display enabled

    // Framebuffer should exist and have 256x192 pixels
    const fb = machine.framebuffer();
    try testing.expectEqual(@as(usize, 256 * 192), fb.len);
}

test "sg1000 system detection creates sms machine with sg1000 flag" {
    // Verify the system_machine dispatch correctly identifies .sg extension
    // and creates an SmsMachine with is_sg1000 = true.
    const system_detect = @import("sandopolis_src").system_detect;
    const SystemType = system_detect.SystemType;

    // Extension detection
    try testing.expectEqual(SystemType.sg1000, system_detect.detectSystemFromExtension("game.sg").?);

    // Content detection: SG-1000 ROMs have no standard header, so they
    // fall through to Genesis by default. Extension must override.
    const rom = [_]u8{0} ** 0x4000;
    try testing.expectEqual(SystemType.genesis, system_detect.detectSystem(&rom));
}

test "emulator facade exposes framebuffer and timing after init" {
    // Integration: verify the Emulator testing facade provides valid
    // framebuffer, screen dimensions, and VDP state after initialization.
    var emulator = try Emulator.initEmpty(testing.allocator);
    defer emulator.deinit(testing.allocator);
    emulator.reset();

    emulator.runFrames(1);

    // Framebuffer should exist with valid dimensions
    const fb = emulator.framebuffer();
    try testing.expect(fb.len > 0);
    const width = emulator.framebufferWidth();
    try testing.expect(width == 320 or width == 256);
}

// ---------------------------------------------------------------------------
// Sega CD: main/sub CPU communication through the gate array
// ---------------------------------------------------------------------------

fn be16(buf: []u8, offset: usize, value: u16) void {
    std.mem.writeInt(u16, buf[offset..][0..2], value, .big);
}

fn be32(buf: []u8, offset: usize, value: u32) void {
    std.mem.writeInt(u32, buf[offset..][0..4], value, .big);
}

/// A 128KB "BIOS" whose main program copies a sub program into PRG-RAM,
/// releases the sub CPU, exchanges a command/status word pair, and finally
/// raises INT2. The sub program echoes command 0 + 1 into status 0 and
/// counts INT2s in PRG-RAM.
fn makeSegaCdMiniBios(allocator: std.mem.Allocator) ![]u8 {
    const bios = try allocator.alloc(u8, 128 * 1024);
    @memset(bios, 0);
    @memcpy(bios[0x100..0x104], "SEGA");
    be32(bios, 0x0, 0x00FFFE00); // SSP
    be32(bios, 0x4, 0x00000200); // PC

    // -- Main program at 0x200 --
    var p: usize = 0x200;
    // move.b #0,$A12001        ; hold sub in reset
    be16(bios, p, 0x13FC); be16(bios, p + 2, 0x0000); be32(bios, p + 4, 0x00A12001); p += 8;
    // move.b #0,$A12003        ; PRG-RAM bank 0
    be16(bios, p, 0x13FC); be16(bios, p + 2, 0x0000); be32(bios, p + 4, 0x00A12003); p += 8;
    // lea $1000,a0 ; lea $20000,a1 ; move.w #255,d0
    be16(bios, p, 0x41F9); be32(bios, p + 2, 0x00001000); p += 6;
    be16(bios, p, 0x43F9); be32(bios, p + 2, 0x00020000); p += 6;
    be16(bios, p, 0x303C); be16(bios, p + 2, 0x00FF); p += 4;
    // copy: move.l (a0)+,(a1)+ ; dbra d0,copy
    be16(bios, p, 0x22D8); p += 2;
    be16(bios, p, 0x51C8); be16(bios, p + 2, 0xFFFC); p += 4;
    // move.b #1,$A12001        ; release sub reset
    be16(bios, p, 0x13FC); be16(bios, p + 2, 0x0001); be32(bios, p + 4, 0x00A12001); p += 8;
    // move.w #$1234,$A12010    ; command 0
    be16(bios, p, 0x33FC); be16(bios, p + 2, 0x1234); be32(bios, p + 4, 0x00A12010); p += 8;
    // poll: move.w $A12020,d0 ; cmp.w #$1235,d0 ; bne.s poll
    const poll = p;
    be16(bios, p, 0x3039); be32(bios, p + 2, 0x00A12020); p += 6;
    be16(bios, p, 0x0C40); be16(bios, p + 2, 0x1235); p += 4;
    be16(bios, p, 0x6600 | @as(u16, @truncate(@as(u32, @bitCast(@as(i32, @intCast(poll)) - @as(i32, @intCast(p + 2)))) & 0xFF))); p += 2;
    // move.b #1,$A12000        ; IFL2 -> sub INT2 (byte write: a word write
    //                          ; would also clear SRES in the low byte)
    be16(bios, p, 0x13FC); be16(bios, p + 2, 0x0001); be32(bios, p + 4, 0x00A12000); p += 8;
    // move.w #1,$A12012        ; command 1 = "IFL2 sent" marker
    be16(bios, p, 0x33FC); be16(bios, p + 2, 0x0001); be32(bios, p + 4, 0x00A12012); p += 8;
    // bra.s *
    be16(bios, p, 0x60FE);

    // -- Sub program image at 0x1000 (copied to PRG-RAM 0) --
    const s: usize = 0x1000;
    be32(bios, s + 0x0, 0x00080000); // SSP: top of PRG-RAM
    be32(bios, s + 0x4, 0x00000200); // PC
    be32(bios, s + 0x68, 0x00000300); // level 2 autovector
    var q: usize = s + 0x200;
    // move.b #4,$FF8033        ; enable INT2
    be16(bios, q, 0x13FC); be16(bios, q + 2, 0x0004); be32(bios, q + 4, 0x00FF8033); q += 8;
    // move.w #$2000,sr         ; allow interrupts
    be16(bios, q, 0x46FC); be16(bios, q + 2, 0x2000); q += 4;
    // loop: move.w $FF8010,d0 ; addq.w #1,d0 ; move.w d0,$FF8020 ; bra.s loop
    const loop = q;
    be16(bios, q, 0x3039); be32(bios, q + 2, 0x00FF8010); q += 6;
    be16(bios, q, 0x5240); q += 2;
    be16(bios, q, 0x33C0); be32(bios, q + 2, 0x00FF8020); q += 6;
    be16(bios, q, 0x6000 | @as(u16, @truncate(@as(u32, @bitCast(@as(i32, @intCast(loop)) - @as(i32, @intCast(q + 2)))) & 0xFF)));
    // INT2 handler at 0x300: addq.l #1,$400 ; rte
    be16(bios, s + 0x300, 0x52B9); be32(bios, s + 0x302, 0x00000400);
    be16(bios, s + 0x306, 0x4E73);
    return bios;
}

test "sega cd mini bios boots the sub cpu and exchanges words through the gate array" {
    const bios = try makeSegaCdMiniBios(testing.allocator);
    defer testing.allocator.free(bios);

    var emu = try Emulator.initSegaCdFromMemory(testing.allocator, bios, null);
    defer emu.deinit(testing.allocator);
    try testing.expect(emu.isSegaCd());

    emu.runFramesDiscardingAudio(4);

    // Sub echoed command 0 + 1 into status 0 and the main CPU saw it.
    try testing.expectEqual(@as(u16, 0x1234), emu.scdCommandWord(0));
    try testing.expectEqual(@as(u16, 0x1235), emu.scdStatusWord(0));
    try testing.expectEqual(@as(u16, 0x0001), emu.scdCommandWord(1));
    // INT2 handler ran exactly once (IFL2 is a pulse).
    try testing.expectEqual(@as(u32, 1), emu.scdReadPrgRam32(0x400));
    // Sub CPU is spinning in its main loop inside PRG-RAM.
    const sub_pc = emu.scdSubProgramCounter();
    try testing.expect(sub_pc >= 0x200 and sub_pc < 0x400);
    try testing.expect(emu.scdSubInstructions() > 1000);
    // Main CPU parked on its final branch.
    const main_pc = emu.cpuState().program_counter;
    try testing.expect(main_pc >= 0x200 and main_pc < 0x300);
}

test "sega cd machine resets cleanly and reboots the handshake" {
    const bios = try makeSegaCdMiniBios(testing.allocator);
    defer testing.allocator.free(bios);
    var emu = try Emulator.initSegaCdFromMemory(testing.allocator, bios, null);
    defer emu.deinit(testing.allocator);

    emu.runFramesDiscardingAudio(3);
    try testing.expectEqual(@as(u16, 0x1235), emu.scdStatusWord(0));
    emu.reset();
    try testing.expectEqual(@as(u16, 0), emu.scdStatusWord(0));
    try testing.expectEqual(@as(u32, 0), emu.scdReadPrgRam32(0x400));
    emu.runFramesDiscardingAudio(3);
    try testing.expectEqual(@as(u16, 0x1235), emu.scdStatusWord(0));
    try testing.expectEqual(@as(u32, 1), emu.scdReadPrgRam32(0x400));
}
