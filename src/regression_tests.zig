const std = @import("std");
const testing = std.testing;
const clock = @import("clock.zig");
const frame_scheduler = @import("frame_scheduler.zig");
const InputBindings = @import("input_mapping.zig");
const Bus = @import("memory.zig").Bus;
const Cpu = @import("cpu/cpu.zig").Cpu;
const Io = @import("io.zig").Io;
const Vdp = @import("vdp.zig").Vdp;

fn vdpTestDmaReadWord(_: ?*anyopaque, _: u32) u16 {
    return 0x1234;
}

fn runEmulatedFrames(bus: *Bus, cpu: *Cpu, m68k_sync: *clock.M68kSync, frames: usize) void {
    const visible_lines = clock.ntsc_visible_lines;
    const total_lines = clock.ntsc_lines_per_frame;

    for (0..frames) |_| {
        bus.vdp.beginFrame();
        for (0..total_lines) |line_idx| {
            const line: u16 = @intCast(line_idx);
            const entering_vblank = bus.vdp.setScanlineState(line, visible_lines, total_lines);
            if (entering_vblank and bus.vdp.isVBlankInterruptEnabled()) {
                cpu.requestInterrupt(6);
            }
            bus.vdp.setHBlank(false);

            const hint_master_cycles = bus.vdp.hInterruptMasterCycles();
            const hblank_start_master_cycles = bus.vdp.hblankStartMasterCycles();
            const first_event_master_cycles = @min(hint_master_cycles, hblank_start_master_cycles);
            const second_event_master_cycles = @max(hint_master_cycles, hblank_start_master_cycles);

            frame_scheduler.runMasterSlice(bus, cpu, m68k_sync, first_event_master_cycles);

            if (hblank_start_master_cycles == first_event_master_cycles) {
                bus.vdp.setHBlank(true);
            }
            if (hint_master_cycles == first_event_master_cycles and bus.vdp.consumeHintForLine(line, visible_lines)) {
                cpu.requestInterrupt(4);
            }

            frame_scheduler.runMasterSlice(bus, cpu, m68k_sync, second_event_master_cycles - first_event_master_cycles);

            if (hblank_start_master_cycles == second_event_master_cycles and hblank_start_master_cycles != first_event_master_cycles) {
                bus.vdp.setHBlank(true);
            }
            if (hint_master_cycles == second_event_master_cycles and hint_master_cycles != first_event_master_cycles and bus.vdp.consumeHintForLine(line, visible_lines)) {
                cpu.requestInterrupt(4);
            }

            frame_scheduler.runMasterSlice(bus, cpu, m68k_sync, clock.ntsc_master_cycles_per_line - second_event_master_cycles);
            bus.vdp.setHBlank(false);

            if (line < visible_lines) {
                bus.vdp.renderScanline(line);
            }
        }
        bus.vdp.odd_frame = !bus.vdp.odd_frame;
    }
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

test "cartridge odd-byte sram past end of rom is auto-mapped" {
    const rom = try makeRomWithSramHeader(testing.allocator, 0x200000, 0xF8, 0x200001, 0x203FFF);
    defer testing.allocator.free(rom);

    var bus = try Bus.initFromRomBytes(testing.allocator, rom);
    defer bus.deinit(testing.allocator);

    try testing.expect(bus.hasCartridgeRam());
    try testing.expect(bus.isCartridgeRamMapped());
    try testing.expect(bus.isCartridgeRamPersistent());

    bus.write8(0x0020_0001, 0x5A);
    try testing.expectEqual(@as(u8, 0x5A), bus.read8(0x0020_0001));
    try testing.expectEqual(@as(u16, 0x5A5A), bus.read16(0x0020_0000));
}

test "cartridge sram map register toggles rom fallback" {
    var rom = try makeRomWithSramHeader(testing.allocator, 0x400000, 0xF8, 0x200001, 0x203FFF);
    defer testing.allocator.free(rom);
    rom[0x200001] = 0x33;

    var bus = try Bus.initFromRomBytes(testing.allocator, rom);
    defer bus.deinit(testing.allocator);

    try testing.expect(bus.hasCartridgeRam());
    try testing.expect(!bus.isCartridgeRamMapped());
    try testing.expectEqual(@as(u8, 0x33), bus.read8(0x0020_0001));

    bus.write8(0x0020_0001, 0xAA);
    try testing.expectEqual(@as(u8, 0x33), bus.read8(0x0020_0001));

    bus.write16(0x00A1_30F0, 0x0001);
    try testing.expect(bus.isCartridgeRamMapped());

    bus.write8(0x0020_0001, 0xAA);
    try testing.expectEqual(@as(u8, 0xAA), bus.read8(0x0020_0001));

    bus.write16(0x00A1_30F0, 0x0000);
    try testing.expect(!bus.isCartridgeRamMapped());
    try testing.expectEqual(@as(u8, 0x33), bus.read8(0x0020_0001));

    bus.write16(0x00A1_30F0, 0x0001);
    try testing.expectEqual(@as(u8, 0xAA), bus.read8(0x0020_0001));
}

test "cartridge sixteen-bit sram stores both bytes of a word" {
    const rom = try makeRomWithSramHeader(testing.allocator, 0x100000, 0xE0, 0x200000, 0x20FFFF);
    defer testing.allocator.free(rom);

    var bus = try Bus.initFromRomBytes(testing.allocator, rom);
    defer bus.deinit(testing.allocator);

    try testing.expect(bus.hasCartridgeRam());
    try testing.expect(bus.isCartridgeRamMapped());

    bus.write16(0x0020_0000, 0x1234);
    try testing.expectEqual(@as(u16, 0x1234), bus.read16(0x0020_0000));
    try testing.expectEqual(@as(u8, 0x12), bus.read8(0x0020_0000));
    try testing.expectEqual(@as(u8, 0x34), bus.read8(0x0020_0001));
}

test "persistent cartridge sram flushes to save file and reloads" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rom = try makeRomWithSramHeader(testing.allocator, 0x200000, 0xF8, 0x200001, 0x203FFF);
    defer testing.allocator.free(rom);
    try tmp.dir.writeFile(.{ .sub_path = "persist.md", .data = rom });

    const rom_path = try tmp.dir.realpathAlloc(testing.allocator, "persist.md");
    defer testing.allocator.free(rom_path);

    {
        var bus = try Bus.init(testing.allocator, rom_path);
        defer bus.deinit(testing.allocator);

        const save_path = bus.persistentSavePath() orelse unreachable;
        bus.write8(0x0020_0001, 0xA5);
        bus.write8(0x0020_0003, 0x5A);
        try bus.flushPersistentStorage();

        var save_file = try std.fs.cwd().openFile(save_path, .{});
        defer save_file.close();

        var first_bytes: [2]u8 = undefined;
        const bytes_read = try save_file.readAll(&first_bytes);
        try testing.expectEqual(@as(usize, 2), bytes_read);
        try testing.expectEqualSlices(u8, &[_]u8{ 0xA5, 0x5A }, first_bytes[0..]);
    }

    {
        var bus = try Bus.init(testing.allocator, rom_path);
        defer bus.deinit(testing.allocator);

        try testing.expectEqual(@as(u8, 0xA5), bus.read8(0x0020_0001));
        try testing.expectEqual(@as(u8, 0x5A), bus.read8(0x0020_0003));
    }
}

test "z80 bus mapped memory and busreq registers behave as expected" {
    var bus = try Bus.init(testing.allocator, null);
    defer bus.deinit(testing.allocator);

    // Without BUSREQ, 68k should not see/modify Z80 window.
    bus.write8(0x00A0_0010, 0x5A);
    try testing.expectEqual(@as(u8, 0x5A), bus.read8(0x00A0_0010));
    try testing.expectEqual(@as(u16, 0x5A00), bus.read16(0x00A0_0010));

    bus.write16(0x00A1_1100, 0x0000); // Request Z80 bus
    try testing.expectEqual(@as(u16, 0x0000), bus.read16(0x00A1_1100));

    bus.write8(0x00A0_0010, 0x5A);
    try testing.expectEqual(@as(u8, 0x5A), bus.read8(0x00A0_0010));

    bus.write16(0x00A1_1100, 0x0100); // Release Z80 bus
    try testing.expectEqual(@as(u16, 0x0100), bus.read16(0x00A1_1100));

    // Once released, 68k window should be blocked again.
    bus.write8(0x00A0_0010, 0xA5);
    try testing.expectEqual(@as(u8, 0xA5), bus.read8(0x00A0_0010));
    try testing.expectEqual(@as(u16, 0xA500), bus.read16(0x00A0_0010));
}

test "z80 bus request does not grant bus while reset is held" {
    var bus = try Bus.init(testing.allocator, null);
    defer bus.deinit(testing.allocator);

    bus.write16(0x00A1_1200, 0x0000); // Assert reset
    bus.write16(0x00A1_1100, 0x0000); // Request Z80 bus

    try testing.expectEqual(@as(u16, 0x0100), bus.read16(0x00A1_1100));
    bus.write8(0x00A0_0010, 0x5A);
    try testing.expectEqual(@as(u8, 0x5A), bus.read8(0x00A0_0010));
    try testing.expectEqual(@as(u16, 0x5A00), bus.read16(0x00A0_0010));

    bus.write16(0x00A1_1200, 0x0100); // Release reset

    try testing.expectEqual(@as(u16, 0x0000), bus.read16(0x00A1_1100));
    bus.write8(0x00A0_0010, 0x5A);
    try testing.expectEqual(@as(u8, 0x5A), bus.read8(0x00A0_0010));
}

test "z80 busack and reset reads preserve open-bus bits" {
    var bus = try Bus.init(testing.allocator, null);
    defer bus.deinit(testing.allocator);

    bus.open_bus = 0xA400;
    try testing.expectEqual(@as(u16, 0xA500), bus.read16(0x00A1_1100));

    bus.write16(0x00A1_1100, 0x0000); // Request/grant Z80 bus
    bus.open_bus = 0xA400;
    try testing.expectEqual(@as(u16, 0xA400), bus.read16(0x00A1_1100));

    bus.write16(0x00A1_1200, 0x0000); // Assert reset
    bus.open_bus = 0xB600;
    try testing.expectEqual(@as(u16, 0xB600), bus.read16(0x00A1_1200));

    bus.write16(0x00A1_1200, 0x0100); // Release reset
    bus.open_bus = 0xB600;
    try testing.expectEqual(@as(u16, 0xB700), bus.read16(0x00A1_1200));
}

test "unused vdp port reads return ff" {
    var bus = try Bus.init(testing.allocator, null);
    defer bus.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0xFF), bus.read8(0x00C0_0011));
    try testing.expectEqual(@as(u16, 0xFFFF), bus.read16(0x00C0_0010));
}

test "input bindings parse overrides and unbinds" {
    const bindings = try InputBindings.Bindings.parseContents(
        \\# Player 1 remap
        \\keyboard.a = q
        \\keyboard.b = none
        \\keyboard.p2.start = rshift
        \\gamepad.p2.start = back
        \\hotkey.quit = backspace
    );

    try testing.expect(bindings.keyboard[0][@intFromEnum(InputBindings.Action.a)] == .q);
    try testing.expect(bindings.keyboard[0][@intFromEnum(InputBindings.Action.b)] == null);
    try testing.expect(bindings.keyboard[1][@intFromEnum(InputBindings.Action.start)] == .rshift);
    try testing.expect(bindings.gamepad[1][@intFromEnum(InputBindings.Action.start)] == .back);
    try testing.expect(bindings.hotkeys[@intFromEnum(InputBindings.HotkeyAction.quit)] == .backspace);
}

test "input bindings apply remapped inputs" {
    var io = Io.init();
    var bindings = InputBindings.Bindings.defaults();
    bindings.setKeyboard(.a, null);
    bindings.setKeyboardForPort(1, .x, .q);
    bindings.setGamepad(.a, null);
    bindings.setGamepadForPort(1, .c, .south);
    bindings.setHotkey(.step, .backspace);

    try testing.expect(bindings.applyKeyboard(&io, .q, true));
    try testing.expectEqual(@as(u16, 0), io.pad[1] & Io.Button.X);
    try testing.expect((io.pad[0] & Io.Button.A) != 0);

    io.setButton(1, Io.Button.X, false);
    try testing.expect(bindings.applyGamepad(&io, 1, .south, true));
    try testing.expectEqual(@as(u16, 0), io.pad[1] & Io.Button.C);
    try testing.expect((io.pad[0] & Io.Button.A) != 0);
    try testing.expectEqual(InputBindings.HotkeyAction.step, bindings.hotkeyForKeyboard(.backspace).?);
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

test "controller TH input is pulled high after delay" {
    var io = Io.init();

    io.write(0x03, 0x00);
    io.write(0x09, 0x40);
    try testing.expectEqual(@as(u8, 0x03), io.read(0x03) & 0x43);

    io.write(0x09, 0x00);
    try testing.expectEqual(@as(u8, 0x03), io.read(0x03) & 0x43);

    io.tick(29);
    try testing.expectEqual(@as(u8, 0x03), io.read(0x03) & 0x43);

    io.tick(1);
    try testing.expectEqual(@as(u8, 0x43), io.read(0x03) & 0x43);
}

test "controller six-button state resets after timeout" {
    var io = Io.init();

    io.write(0x09, 0x40);
    io.setButton(0, Io.Button.Z, true);

    io.write(0x03, 0x00);
    io.write(0x03, 0x40);
    io.write(0x03, 0x00);
    io.write(0x03, 0x40);
    io.write(0x03, 0x00);
    io.write(0x03, 0x40);

    try testing.expectEqual(@as(u8, 0x7E), io.read(0x03));

    io.tick(12_149);
    try testing.expectEqual(@as(u8, 0x7E), io.read(0x03));

    io.tick(1);
    try testing.expectEqual(@as(u8, 0x7F), io.read(0x03));
}

test "bus stepping advances controller timing" {
    var bus = try Bus.init(testing.allocator, null);
    defer bus.deinit(testing.allocator);

    bus.write8(0x00A1_0003, 0x00);
    bus.write8(0x00A1_0009, 0x40);
    bus.write8(0x00A1_0009, 0x00);

    try testing.expectEqual(@as(u8, 0x03), bus.read8(0x00A1_0003) & 0x43);
    bus.stepMaster(clock.m68kCyclesToMaster(29));
    try testing.expectEqual(@as(u8, 0x03), bus.read8(0x00A1_0003) & 0x43);
    bus.stepMaster(clock.m68kCyclesToMaster(1));
    try testing.expectEqual(@as(u8, 0x43), bus.read8(0x00A1_0003) & 0x43);
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

test "z80 68k-bus stall is applied before the next instruction" {
    var bus = try Bus.init(testing.allocator, null);
    defer bus.deinit(testing.allocator);

    // Loop forever on: LD A,($8000) ; JR $0000
    bus.z80.reset();
    bus.z80.writeByte(0x0000, 0x3A);
    bus.z80.writeByte(0x0001, 0x00);
    bus.z80.writeByte(0x0002, 0x80);
    bus.z80.writeByte(0x0003, 0x18);
    bus.z80.writeByte(0x0004, 0xFB);

    bus.rom[0x0000] = 0x12;

    // This is enough time for the first banked read and its reciprocal stall,
    // but not enough to begin the following JR if the stall is applied inline.
    bus.stepMaster(258);
    try testing.expectEqual(@as(u16, 0x0003), bus.z80.getPc());
    try testing.expectEqual(@as(u32, 0), bus.z80_wait_master_cycles);
    try testing.expectEqual(clock.m68kCyclesToMaster(11), bus.pendingM68kWaitMasterCycles());

    // The next master cycle starts the JR, and the remaining instruction cost is
    // carried as debt instead of letting the following instruction run early.
    bus.stepMaster(1);
    try testing.expectEqual(@as(u16, 0x0000), bus.z80.getPc());
    try testing.expect(bus.z80_master_credit < 0);

    bus.stepMaster(164);
    try testing.expectEqual(@as(u16, 0x0000), bus.z80.getPc());
    try testing.expectEqual(@as(i64, -1), bus.z80_master_credit);

    bus.stepMaster(16);
    try testing.expectEqual(@as(u16, 0x0003), bus.z80.getPc());
    try testing.expect(bus.z80_master_credit < 0);
    try testing.expectEqual(clock.m68kCyclesToMaster(22), bus.pendingM68kWaitMasterCycles());
}

test "z80 instruction overshoot carries between bus slices" {
    var bus = try Bus.init(testing.allocator, null);
    defer bus.deinit(testing.allocator);

    bus.z80.reset();
    bus.z80.writeByte(0x0000, 0x00); // NOP
    bus.z80.writeByte(0x0001, 0x00); // NOP

    bus.stepMaster(clock.z80_divider);
    try testing.expectEqual(@as(u16, 0x0001), bus.z80.getPc());
    try testing.expectEqual(@as(i64, -45), bus.z80_master_credit);

    bus.stepMaster(45);
    try testing.expectEqual(@as(u16, 0x0001), bus.z80.getPc());
    try testing.expectEqual(@as(i64, 0), bus.z80_master_credit);

    bus.stepMaster(clock.z80_divider);
    try testing.expectEqual(@as(u16, 0x0002), bus.z80.getPc());
    try testing.expectEqual(@as(i64, -45), bus.z80_master_credit);
}

test "vdp memory-to-vram dma is progressed by vdp with fifo latency" {
    var bus = try Bus.init(testing.allocator, null);
    defer bus.deinit(testing.allocator);

    bus.write16(0x00E0_0000, 0xABCD);

    bus.vdp.regs[15] = 2;
    bus.vdp.code = 0x1;
    bus.vdp.addr = 0x0000;
    bus.vdp.dma_active = true;
    bus.vdp.dma_fill = false;
    bus.vdp.dma_copy = false;
    bus.vdp.dma_source_addr = 0x00E0_0000;
    bus.vdp.dma_length = 1;
    bus.vdp.dma_remaining = 1;

    try testing.expect(bus.vdp.shouldHaltCpu());

    bus.stepMaster(8);
    try testing.expectEqual(@as(u8, 0), bus.vdp.vram[0]);
    try testing.expectEqual(@as(u8, 0), bus.vdp.vram[1]);
    try testing.expect(bus.vdp.dma_active);

    bus.stepMaster(8);
    try testing.expectEqual(@as(u8, 0), bus.vdp.vram[0]);
    try testing.expect(bus.vdp.dma_active);

    bus.stepMaster(8);
    try testing.expectEqual(@as(u8, 0xAB), bus.vdp.vram[0]);
    try testing.expectEqual(@as(u8, 0xCD), bus.vdp.vram[1]);
    try testing.expect(!bus.vdp.dma_active);
    try testing.expect(!bus.vdp.shouldHaltCpu());
}

test "vdp copy dma progresses internally" {
    var vdp = Vdp.init();
    vdp.regs[15] = 1;
    vdp.code = 0x1;
    vdp.addr = 0x0020;
    vdp.vram[0x0010] = 0x12;
    vdp.vram[0x0011] = 0x34;
    vdp.dma_active = true;
    vdp.dma_fill = false;
    vdp.dma_copy = true;
    vdp.dma_source_addr = 0x0010;
    vdp.dma_length = 2;
    vdp.dma_remaining = 2;

    vdp.progressTransfers(8, null, null);
    try testing.expectEqual(@as(u8, 0x12), vdp.vram[0x0020]);
    try testing.expect(vdp.dma_active);

    vdp.progressTransfers(8, null, null);
    try testing.expectEqual(@as(u8, 0x34), vdp.vram[0x0021]);
    try testing.expect(!vdp.dma_active);
    try testing.expect(!vdp.dma_copy);
}

test "vdp memory-to-vram dma waits startup delay after control command" {
    var vdp = Vdp.init();
    vdp.regs[1] |= 0x10; // DMA enable
    vdp.regs[15] = 2;
    vdp.regs[19] = 1;
    vdp.regs[20] = 0;

    vdp.writeControl(0x4000);
    vdp.writeControl(0x0080);

    try testing.expect(vdp.dma_active);
    try testing.expectEqual(@as(u8, 8), vdp.dma_start_delay_slots);
    try testing.expect(vdp.shouldHaltCpu());

    vdp.progressTransfers(56, null, vdpTestDmaReadWord);
    try testing.expectEqual(@as(u32, 1), vdp.dma_remaining);
    try testing.expectEqual(@as(u8, 0), vdp.fifo_len);
    try testing.expectEqual(@as(u16, 0x0000), vdp.addr);

    vdp.progressTransfers(8, null, vdpTestDmaReadWord);
    try testing.expectEqual(@as(u32, 0), vdp.dma_remaining);
    try testing.expectEqual(@as(u8, 1), vdp.fifo_len);
    try testing.expectEqual(@as(u16, 0x0002), vdp.addr);
    try testing.expect(vdp.dma_active);

    vdp.progressTransfers(24, null, vdpTestDmaReadWord);
    try testing.expectEqual(@as(u8, 0x12), vdp.vram[0]);
    try testing.expectEqual(@as(u8, 0x34), vdp.vram[1]);
    try testing.expect(!vdp.dma_active);
}

test "vdp memory-to-vram dma to vsram uses shorter startup delay" {
    var vdp = Vdp.init();
    vdp.regs[1] |= 0x10; // DMA enable
    vdp.regs[15] = 2;
    vdp.regs[19] = 1;
    vdp.regs[20] = 0;

    vdp.writeControl(0x4000);
    vdp.writeControl(0x0090);

    try testing.expect(vdp.dma_active);
    try testing.expectEqual(@as(u8, 5), vdp.dma_start_delay_slots);

    vdp.progressTransfers(32, null, vdpTestDmaReadWord);
    try testing.expectEqual(@as(u32, 1), vdp.dma_remaining);
    try testing.expectEqual(@as(u8, 0), vdp.fifo_len);

    vdp.progressTransfers(8, null, vdpTestDmaReadWord);
    try testing.expectEqual(@as(u32, 0), vdp.dma_remaining);
    try testing.expectEqual(@as(u8, 1), vdp.fifo_len);
    try testing.expectEqual(@as(u16, 0x0002), vdp.addr);

    vdp.progressTransfers(24, null, vdpTestDmaReadWord);
    try testing.expectEqual(@as(u8, 0x12), vdp.vsram[0]);
    try testing.expectEqual(@as(u8, 0x34), vdp.vsram[1]);
    try testing.expect(!vdp.dma_active);
}

test "vdp buffers control writes until memory-to-vram dma completes" {
    var vdp = Vdp.init();
    vdp.regs[15] = 2;
    vdp.code = 0x1;
    vdp.addr = 0x0000;
    vdp.dma_active = true;
    vdp.dma_fill = false;
    vdp.dma_copy = false;
    vdp.dma_length = 1;
    vdp.dma_remaining = 1;

    vdp.writeControl(0x4000);
    vdp.writeControl(0x0002);

    try testing.expect(!vdp.pending_command);
    try testing.expectEqual(@as(u16, 0x0000), vdp.addr);
    try testing.expectEqual(@as(u8, 0x1), vdp.code);

    vdp.progressTransfers(24, null, vdpTestDmaReadWord);

    try testing.expect(!vdp.dma_active);
    try testing.expect(!vdp.pending_command);
    try testing.expectEqual(@as(u16, 0x0002), vdp.addr);
    try testing.expectEqual(@as(u8, 0x1), vdp.code);

    vdp.progressTransfers(40, null, null);
    try testing.expectEqual(@as(u16, 0x0002), vdp.addr);

    vdp.progressTransfers(10, null, null);
    try testing.expectEqual(@as(u16, 0x8000), vdp.addr);
    try testing.expectEqual(@as(u8, 0x1), vdp.code);
}

test "vdp buffers data writes until memory-to-vram dma completes" {
    var vdp = Vdp.init();
    vdp.regs[15] = 2;
    vdp.code = 0x1;
    vdp.addr = 0x0000;
    vdp.dma_active = true;
    vdp.dma_fill = false;
    vdp.dma_copy = false;
    vdp.dma_length = 1;
    vdp.dma_remaining = 1;

    vdp.writeData(0xBEEF);

    try testing.expectEqual(@as(u16, 0x0000), vdp.addr);
    try testing.expectEqual(@as(u8, 0), vdp.vram[0]);
    try testing.expectEqual(@as(u8, 0), vdp.vram[1]);

    vdp.progressTransfers(24, null, vdpTestDmaReadWord);
    try testing.expectEqual(@as(u8, 0x12), vdp.vram[0]);
    try testing.expectEqual(@as(u8, 0x34), vdp.vram[1]);
    try testing.expectEqual(@as(u16, 0x0002), vdp.addr);

    vdp.progressTransfers(40, null, null);
    try testing.expectEqual(@as(u16, 0x0002), vdp.addr);
    try testing.expectEqual(@as(u8, 0), vdp.vram[2]);
    try testing.expectEqual(@as(u8, 0), vdp.vram[3]);

    vdp.progressTransfers(10, null, null);
    try testing.expectEqual(@as(u16, 0x0004), vdp.addr);
    try testing.expectEqual(@as(u8, 0), vdp.vram[2]);
    try testing.expectEqual(@as(u8, 0), vdp.vram[3]);

    vdp.progressTransfers(24, null, null);
    try testing.expectEqual(@as(u8, 0xBE), vdp.vram[2]);
    try testing.expectEqual(@as(u8, 0xEF), vdp.vram[3]);
}

test "vdp h40 buffered control writes replay after shorter delay" {
    var vdp = Vdp.init();
    vdp.regs[12] = 0x81;
    vdp.regs[15] = 2;
    vdp.code = 0x1;
    vdp.addr = 0x0000;
    vdp.dma_active = true;
    vdp.dma_fill = false;
    vdp.dma_copy = false;
    vdp.dma_length = 1;
    vdp.dma_remaining = 1;

    vdp.writeControl(0x4000);
    vdp.writeControl(0x0002);

    vdp.progressTransfers(24, null, vdpTestDmaReadWord);
    try testing.expectEqual(@as(u16, 0x0002), vdp.addr);

    vdp.progressTransfers(32, null, null);
    try testing.expectEqual(@as(u16, 0x0002), vdp.addr);

    vdp.progressTransfers(8, null, null);
    try testing.expectEqual(@as(u16, 0x8000), vdp.addr);
}

test "vdp buffers new control writes while post-dma replay delay is active" {
    var vdp = Vdp.init();
    vdp.regs[15] = 2;
    vdp.code = 0x1;
    vdp.addr = 0x0000;
    vdp.dma_active = true;
    vdp.dma_fill = false;
    vdp.dma_copy = false;
    vdp.dma_length = 1;
    vdp.dma_remaining = 1;

    vdp.writeControl(0x4000);
    vdp.writeControl(0x0002);

    vdp.progressTransfers(24, null, vdpTestDmaReadWord);
    try testing.expectEqual(@as(u16, 50), vdp.pending_port_write_delay_master_cycles);
    try testing.expectEqual(@as(u16, 0x0002), vdp.addr);

    vdp.writeControl(0x4004);
    vdp.writeControl(0x0000);

    try testing.expectEqual(@as(u8, 4), vdp.pending_port_write_len);
    try testing.expectEqual(@as(u16, 0x0002), vdp.addr);

    vdp.progressTransfers(49, null, null);
    try testing.expectEqual(@as(u16, 0x0002), vdp.addr);

    vdp.progressTransfers(1, null, null);
    try testing.expectEqual(@as(u16, 0x0004), vdp.addr);
    try testing.expectEqual(@as(u8, 0x1), vdp.code);
}

test "vdp buffers new data writes while post-dma replay delay is active" {
    var vdp = Vdp.init();
    vdp.regs[15] = 2;
    vdp.code = 0x1;
    vdp.addr = 0x0000;
    vdp.dma_active = true;
    vdp.dma_fill = false;
    vdp.dma_copy = false;
    vdp.dma_length = 1;
    vdp.dma_remaining = 1;

    vdp.writeData(0xBEEF);

    vdp.progressTransfers(24, null, vdpTestDmaReadWord);
    try testing.expectEqual(@as(u16, 50), vdp.pending_port_write_delay_master_cycles);
    try testing.expectEqual(@as(u16, 0x0002), vdp.addr);

    vdp.writeData(0xCAFE);

    try testing.expectEqual(@as(u8, 2), vdp.pending_port_write_len);
    try testing.expectEqual(@as(u16, 0x0002), vdp.addr);
    try testing.expectEqual(@as(u8, 0), vdp.vram[2]);
    try testing.expectEqual(@as(u8, 0), vdp.vram[3]);
    try testing.expectEqual(@as(u8, 0), vdp.vram[4]);
    try testing.expectEqual(@as(u8, 0), vdp.vram[5]);

    vdp.progressTransfers(50, null, null);
    try testing.expectEqual(@as(u16, 0x0006), vdp.addr);
    try testing.expectEqual(@as(u8, 0), vdp.vram[2]);
    try testing.expectEqual(@as(u8, 0), vdp.vram[3]);
    try testing.expectEqual(@as(u8, 0), vdp.vram[4]);
    try testing.expectEqual(@as(u8, 0), vdp.vram[5]);

    vdp.progressTransfers(24, null, null);
    try testing.expectEqual(@as(u8, 0xBE), vdp.vram[2]);
    try testing.expectEqual(@as(u8, 0xEF), vdp.vram[3]);
    try testing.expectEqual(@as(u8, 0), vdp.vram[4]);
    try testing.expectEqual(@as(u8, 0), vdp.vram[5]);

    vdp.progressTransfers(8, null, null);
    try testing.expectEqual(@as(u8, 0xCA), vdp.vram[4]);
    try testing.expectEqual(@as(u8, 0xFE), vdp.vram[5]);
}

test "vdp queued writes accumulate sub-slot master cycles" {
    var vdp = Vdp.init();
    vdp.regs[15] = 2;
    vdp.code = 0x1;
    vdp.addr = 0x0000;

    vdp.writeData(0xABCD);
    try testing.expectEqual(@as(u16, 0x0002), vdp.addr);
    try testing.expectEqual(@as(u8, 0), vdp.vram[0]);
    try testing.expectEqual(@as(u8, 0), vdp.vram[1]);

    inline for (0..3) |_| {
        vdp.progressTransfers(clock.m68k_divider, null, null);
        try testing.expectEqual(@as(u8, 0), vdp.vram[0]);
        try testing.expectEqual(@as(u8, 0), vdp.vram[1]);
    }

    vdp.progressTransfers(clock.m68k_divider, null, null);
    try testing.expectEqual(@as(u8, 0xAB), vdp.vram[0]);
    try testing.expectEqual(@as(u8, 0xCD), vdp.vram[1]);
}

test "vdp data-port read prefetch sees queued fifo writes" {
    var vdp = Vdp.init();
    vdp.regs[15] = 2;
    vdp.code = 0x1;
    vdp.addr = 0x0000;
    vdp.writeData(0xABCD);

    vdp.code = 0x0;
    vdp.addr = 0x0000;
    vdp.read_buffer = 0x1234;

    try testing.expectEqual(@as(u16, 0x1234), vdp.readData());
    try testing.expectEqual(@as(u16, 0xCDAB), vdp.read_buffer);
}

test "vdp data-port read prefetch sees pending fifo writes after drain" {
    var vdp = Vdp.init();
    vdp.regs[15] = 2;
    vdp.code = 0x1;
    vdp.addr = 0x0000;
    vdp.writeData(0x0102);
    vdp.writeData(0x0304);
    vdp.writeData(0x0506);
    vdp.writeData(0x0708);
    vdp.writeData(0xA1B2);

    try testing.expectEqual(@as(u8, 4), vdp.fifo_len);
    try testing.expectEqual(@as(u8, 1), vdp.pending_fifo_len);

    vdp.code = 0x0;
    vdp.addr = 0x0008;
    vdp.read_buffer = 0x5678;

    try testing.expectEqual(@as(u16, 0x5678), vdp.readData());
    try testing.expectEqual(@as(u16, 0xB2A1), vdp.read_buffer);
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

    try testing.expectEqual(@as(u32, 24), bus.vdp.dataPortWriteWaitMasterCycles());

    var cpu = Cpu.init();
    cpu.reset(&bus);

    const ran = cpu.runCycles(&bus, 64);
    try testing.expect(ran != 0);

    const wait = cpu.takeWaitAccounting();
    try testing.expectEqual(@as(u32, 4), wait.m68k_cycles);
    try testing.expectEqual(@as(u32, 24), wait.master_cycles);
    try testing.expect(!bus.vdp.shouldHaltCpu());
    try testing.expectEqual(@as(u16, 0x000A), bus.vdp.addr);
}

test "vdp data-port read wait tracks fifo drain time" {
    var vdp = Vdp.init();
    vdp.regs[15] = 2;
    vdp.code = 0x1;
    vdp.addr = 0x0000;

    vdp.writeData(0xABCD);
    try testing.expectEqual(@as(u32, 24), vdp.dataPortReadWaitMasterCycles());

    vdp.progressTransfers(8, null, null);
    try testing.expectEqual(@as(u32, 16), vdp.dataPortReadWaitMasterCycles());

    vdp.progressTransfers(8, null, null);
    try testing.expectEqual(@as(u32, 8), vdp.dataPortReadWaitMasterCycles());

    vdp.progressTransfers(8, null, null);
    try testing.expectEqual(@as(u32, 0), vdp.dataPortReadWaitMasterCycles());
}

test "cpu data-port reads accrue vdp fifo drain wait accounting" {
    var bus = try Bus.init(testing.allocator, null);
    defer bus.deinit(testing.allocator);
    var cpu = Cpu.init();
    cpu.reset(&bus);

    bus.vdp.regs[15] = 2;
    bus.vdp.code = 0x1;
    bus.vdp.addr = 0x0000;
    bus.vdp.writeData(0xABCD);

    cpu.noteBusAccessWait(&bus, 0x00C0_0000, 2, false);
    const wait = cpu.takeWaitAccounting();
    try testing.expectEqual(@as(u32, 4), wait.m68k_cycles);
    try testing.expectEqual(@as(u32, 24), wait.master_cycles);
}

test "cpu z80-window accesses accrue wait accounting only when bus is granted" {
    var bus = try Bus.init(testing.allocator, null);
    defer bus.deinit(testing.allocator);
    var cpu = Cpu.init();
    cpu.reset(&bus);

    cpu.noteBusAccessWait(&bus, 0x00A0_4000, 1, false);
    var wait = cpu.takeWaitAccounting();
    try testing.expectEqual(@as(u32, 0), wait.m68k_cycles);
    try testing.expectEqual(@as(u32, 0), wait.master_cycles);

    bus.write16(0x00A1_1100, 0x0000); // Request/grant Z80 bus

    cpu.noteBusAccessWait(&bus, 0x00A0_4000, 1, false);
    wait = cpu.takeWaitAccounting();
    try testing.expectEqual(@as(u32, 1), wait.m68k_cycles);
    try testing.expectEqual(clock.m68kCyclesToMaster(1), wait.master_cycles);

    cpu.noteBusAccessWait(&bus, 0x00A0_8000, 4, false);
    wait = cpu.takeWaitAccounting();
    try testing.expectEqual(@as(u32, 2), wait.m68k_cycles);
    try testing.expectEqual(clock.m68kCyclesToMaster(2), wait.master_cycles);

    bus.write16(0x00A1_1200, 0x0000); // Assert reset, revoking grant

    cpu.noteBusAccessWait(&bus, 0x00A0_4000, 1, false);
    wait = cpu.takeWaitAccounting();
    try testing.expectEqual(@as(u32, 0), wait.m68k_cycles);
    try testing.expectEqual(@as(u32, 0), wait.master_cycles);
}

test "cpu control-port writes wait for pending post-dma replay delay" {
    var bus = try Bus.init(testing.allocator, null);
    defer bus.deinit(testing.allocator);
    var cpu = Cpu.init();
    cpu.reset(&bus);

    bus.vdp.regs[15] = 2;
    bus.vdp.code = 0x1;
    bus.vdp.addr = 0x0000;
    bus.vdp.dma_active = true;
    bus.vdp.dma_fill = false;
    bus.vdp.dma_copy = false;
    bus.vdp.dma_length = 1;
    bus.vdp.dma_remaining = 1;

    bus.vdp.writeControl(0x4000);
    bus.vdp.writeControl(0x0002);
    bus.vdp.progressTransfers(24, null, vdpTestDmaReadWord);

    cpu.noteBusAccessWait(&bus, 0x00C0_0004, 2, true);
    var wait = cpu.takeWaitAccounting();
    try testing.expectEqual(@as(u32, 8), wait.m68k_cycles);
    try testing.expectEqual(@as(u32, 50), wait.master_cycles);

    cpu.noteBusAccessWait(&bus, 0x00C0_0004, 4, true);
    wait = cpu.takeWaitAccounting();
    try testing.expectEqual(@as(u32, 8), wait.m68k_cycles);
    try testing.expectEqual(@as(u32, 50), wait.master_cycles);
}

test "vdp reserves incremental waits for repeated blocked data-port writes" {
    var vdp = Vdp.init();
    vdp.regs[15] = 2;
    vdp.code = 0x1;
    vdp.addr = 0x0000;

    vdp.writeData(0x0102);
    vdp.writeData(0x0304);
    vdp.writeData(0x0506);
    vdp.writeData(0x0708);

    const wait_first = vdp.reserveDataPortWriteWaitMasterCycles();
    vdp.writeData(0x090A);

    const wait_second = vdp.reserveDataPortWriteWaitMasterCycles();
    vdp.writeData(0x0B0C);

    try testing.expectEqual(@as(u32, 24), wait_first);
    try testing.expectEqual(@as(u32, 8), wait_second);

    vdp.progressTransfers(wait_first + wait_second, null, null);
    try testing.expectEqual(@as(u16, 0x000C), vdp.addr);
    try testing.expectEqual(@as(u16, 0x0100), vdp.readControl() & 0x0300);
}

test "vdp status reports fifo empty and full bits" {
    var vdp = Vdp.init();
    vdp.regs[15] = 2;
    vdp.code = 0x1;
    vdp.addr = 0x0000;

    const fifo_status_mask: u16 = 0x0300;

    try testing.expectEqual(@as(u16, 0x0200), vdp.readControl() & fifo_status_mask);

    vdp.writeData(0x0102);
    try testing.expectEqual(@as(u16, 0x0000), vdp.readControl() & fifo_status_mask);

    vdp.writeData(0x0304);
    vdp.writeData(0x0506);
    vdp.writeData(0x0708);
    try testing.expectEqual(@as(u16, 0x0100), vdp.readControl() & fifo_status_mask);

    vdp.progressTransfers(24, null, null);
    try testing.expectEqual(@as(u16, 0x0000), vdp.readControl() & fifo_status_mask);

    vdp.progressTransfers(24, null, null);
    try testing.expectEqual(@as(u16, 0x0200), vdp.readControl() & fifo_status_mask);
}

test "vdp status high bits come from bus open bus" {
    var bus = try Bus.init(testing.allocator, null);
    defer bus.deinit(testing.allocator);

    bus.write16(0x00E0_0000, 0xA5A5);

    const status = bus.read16(0x00C0_0004);
    try testing.expectEqual(@as(u16, 0xA400), status & 0xFC00);
    try testing.expectEqual(@as(u16, 0x0200), status & 0x0300);
}

test "frame scheduler stalls cpu while vdp dma owns the bus" {
    var bus = try Bus.init(testing.allocator, null);
    defer bus.deinit(testing.allocator);

    std.mem.writeInt(u32, bus.rom[0..4], 0x00FF_FE00, .big);
    std.mem.writeInt(u32, bus.rom[4..8], 0x0000_0200, .big);
    bus.rom[0x0200] = 0x4E; // NOP
    bus.rom[0x0201] = 0x71;
    bus.write16(0x00E0_0000, 0xABCD);

    var cpu = Cpu.init();
    cpu.reset(&bus);
    var m68k_sync = clock.M68kSync{};

    const pc_before = @as(u32, cpu.core.pc);

    bus.vdp.regs[15] = 2;
    bus.vdp.code = 0x1;
    bus.vdp.addr = 0x0000;
    bus.vdp.dma_active = true;
    bus.vdp.dma_fill = false;
    bus.vdp.dma_copy = false;
    bus.vdp.dma_source_addr = 0x00E0_0000;
    bus.vdp.dma_length = 1;
    bus.vdp.dma_remaining = 1;

    frame_scheduler.runMasterSlice(&bus, &cpu, &m68k_sync, 8);

    try testing.expectEqual(pc_before, @as(u32, cpu.core.pc));
    try testing.expect(bus.vdp.dma_active);
    try testing.expect(bus.vdp.shouldHaltCpu());
}

test "frame scheduler does not stall cpu for pending vdp fifo writes" {
    var bus = try Bus.init(testing.allocator, null);
    defer bus.deinit(testing.allocator);

    std.mem.writeInt(u32, bus.rom[0..4], 0x00FF_FE00, .big);
    std.mem.writeInt(u32, bus.rom[4..8], 0x0000_0200, .big);
    bus.rom[0x0200] = 0x4E; // NOP
    bus.rom[0x0201] = 0x71;
    bus.rom[0x0202] = 0x4E; // NOP
    bus.rom[0x0203] = 0x71;

    bus.vdp.regs[15] = 2;
    bus.vdp.code = 0x1;
    bus.vdp.addr = 0x0000;
    bus.vdp.writeData(0x0102);
    bus.vdp.writeData(0x0304);
    bus.vdp.writeData(0x0506);
    bus.vdp.writeData(0x0708);
    bus.vdp.writeData(0x090A);

    try testing.expect(!bus.vdp.shouldHaltCpu());

    var cpu = Cpu.init();
    cpu.reset(&bus);
    var m68k_sync = clock.M68kSync{};

    const pc_before = @as(u32, cpu.core.pc);
    frame_scheduler.runMasterSlice(&bus, &cpu, &m68k_sync, 56);

    try testing.expect(@as(u32, cpu.core.pc) != pc_before);
}

test "frame scheduler consumes pending z80-induced m68k wait before running cpu" {
    var bus = try Bus.init(testing.allocator, null);
    defer bus.deinit(testing.allocator);

    std.mem.writeInt(u32, bus.rom[0..4], 0x00FF_FE00, .big);
    std.mem.writeInt(u32, bus.rom[4..8], 0x0000_0200, .big);
    bus.rom[0x0200] = 0x4E; // NOP
    bus.rom[0x0201] = 0x71;
    bus.rom[0x0202] = 0x4E; // NOP
    bus.rom[0x0203] = 0x71;

    var cpu = Cpu.init();
    cpu.reset(&bus);
    var m68k_sync = clock.M68kSync{};

    bus.m68k_wait_master_cycles = clock.m68kCyclesToMaster(11);

    const pc_before = @as(u32, cpu.core.pc);
    frame_scheduler.runMasterSlice(&bus, &cpu, &m68k_sync, 56);
    try testing.expectEqual(pc_before, @as(u32, cpu.core.pc));
    try testing.expectEqual(clock.m68kCyclesToMaster(3), bus.pendingM68kWaitMasterCycles());

    frame_scheduler.runMasterSlice(&bus, &cpu, &m68k_sync, clock.m68kCyclesToMaster(3));
    try testing.expectEqual(pc_before, @as(u32, cpu.core.pc));
    try testing.expectEqual(@as(u32, 0), bus.pendingM68kWaitMasterCycles());

    frame_scheduler.runMasterSlice(&bus, &cpu, &m68k_sync, 56);
    try testing.expect(@as(u32, cpu.core.pc) != pc_before);
}

test "frame scheduler interleaves z80 contention within a master slice" {
    var base_bus = try Bus.init(testing.allocator, null);
    defer base_bus.deinit(testing.allocator);

    std.mem.writeInt(u32, base_bus.rom[0..4], 0x00FF_FE00, .big);
    std.mem.writeInt(u32, base_bus.rom[4..8], 0x0000_0200, .big);
    for (0..32) |i| {
        base_bus.rom[0x0200 + i * 2] = 0x4E;
        base_bus.rom[0x0201 + i * 2] = 0x71;
    }

    var base_cpu = Cpu.init();
    base_cpu.reset(&base_bus);
    var base_sync = clock.M68kSync{};
    frame_scheduler.runMasterSlice(&base_bus, &base_cpu, &base_sync, 224);

    var contended_bus = try Bus.init(testing.allocator, null);
    defer contended_bus.deinit(testing.allocator);
    std.mem.copyForwards(u8, contended_bus.rom, base_bus.rom);

    // Start a Z80 program whose first instruction immediately reads banked 68k space.
    contended_bus.z80.reset();
    contended_bus.z80.writeByte(0x0000, 0x3A);
    contended_bus.z80.writeByte(0x0001, 0x00);
    contended_bus.z80.writeByte(0x0002, 0x80);
    contended_bus.z80.writeByte(0x0003, 0x18);
    contended_bus.z80.writeByte(0x0004, 0xFB);
    contended_bus.rom[0x0000] = 0x12;

    var contended_cpu = Cpu.init();
    contended_cpu.reset(&contended_bus);
    var contended_sync = clock.M68kSync{};

    frame_scheduler.runMasterSlice(&contended_bus, &contended_cpu, &contended_sync, 224);

    try testing.expect(@as(u32, contended_cpu.core.pc) < @as(u32, base_cpu.core.pc));
    try testing.expect(@as(u32, contended_cpu.core.pc) > 0x0200);
    try testing.expect(contended_bus.z80.getPc() != 0);
}

test "frame scheduler carries instruction overshoot between slices" {
    var bus = try Bus.init(testing.allocator, null);
    defer bus.deinit(testing.allocator);

    std.mem.writeInt(u32, bus.rom[0..4], 0x00FF_FE00, .big);
    std.mem.writeInt(u32, bus.rom[4..8], 0x0000_0200, .big);
    bus.rom[0x0200] = 0x4E;
    bus.rom[0x0201] = 0x71;
    bus.rom[0x0202] = 0x4E;
    bus.rom[0x0203] = 0x71;

    var cpu = Cpu.init();
    cpu.reset(&bus);
    var m68k_sync = clock.M68kSync{};

    frame_scheduler.runMasterSlice(&bus, &cpu, &m68k_sync, 7);
    try testing.expectEqual(@as(u32, 0x0202), @as(u32, cpu.core.pc));
    try testing.expectEqual(@as(u32, 21), m68k_sync.debt_master_cycles);

    frame_scheduler.runMasterSlice(&bus, &cpu, &m68k_sync, 21);
    try testing.expectEqual(@as(u32, 0x0202), @as(u32, cpu.core.pc));
    try testing.expectEqual(@as(u32, 0), m68k_sync.debt_master_cycles);

    frame_scheduler.runMasterSlice(&bus, &cpu, &m68k_sync, 7);
    try testing.expectEqual(@as(u32, 0x0204), @as(u32, cpu.core.pc));
    try testing.expectEqual(@as(u32, 21), m68k_sync.debt_master_cycles);
}

test "vdp hv counter advances with line master cycles" {
    var vdp = Vdp.init();
    _ = vdp.setScanlineState(10, clock.ntsc_visible_lines, clock.ntsc_lines_per_frame);

    const hv0 = vdp.readHVCounter();
    try testing.expectEqual(@as(u8, 10), @as(u8, @truncate(hv0 >> 8)));
    try testing.expectEqual(@as(u8, 0x00), @as(u8, @truncate(hv0)));

    vdp.step(100);
    const hv1 = vdp.readHVCounter();
    try testing.expectEqual(@as(u8, 0x05), @as(u8, @truncate(hv1)));

    vdp.step(vdp.hblankStartMasterCycles() - 100);
    try testing.expect(vdp.hblank);

    _ = vdp.setScanlineState(11, clock.ntsc_visible_lines, clock.ntsc_lines_per_frame);
    const hv2 = vdp.readHVCounter();
    try testing.expectEqual(@as(u8, 11), @as(u8, @truncate(hv2 >> 8)));
    try testing.expect(@as(u8, @truncate(hv2)) < @as(u8, @truncate(hv1)));
}

test "vdp reports vblank entry edge once" {
    var vdp = Vdp.init();

    try testing.expect(!vdp.setScanlineState(clock.ntsc_visible_lines - 1, clock.ntsc_visible_lines, clock.ntsc_lines_per_frame));
    try testing.expect(vdp.setScanlineState(clock.ntsc_visible_lines, clock.ntsc_visible_lines, clock.ntsc_lines_per_frame));
    try testing.expect(!vdp.setScanlineState(clock.ntsc_visible_lines + 1, clock.ntsc_visible_lines, clock.ntsc_lines_per_frame));
}

test "vdp hint counter triggers every reg10+1 visible lines" {
    var vdp = Vdp.init();
    vdp.regs[0] = 0x10; // HINT enable
    vdp.regs[10] = 2; // trigger cadence: 3 lines
    vdp.beginFrame();

    var triggered_lines = [_]u16{ 0, 0 };
    var trigger_count: usize = 0;

    for (0..8) |i| {
        const line: u16 = @intCast(i);
        if (vdp.consumeHintForLine(line, clock.ntsc_visible_lines)) {
            if (trigger_count < triggered_lines.len) {
                triggered_lines[trigger_count] = line;
            }
            trigger_count += 1;
        }
    }

    try testing.expectEqual(@as(usize, 2), trigger_count);
    try testing.expectEqual(@as(u16, 2), triggered_lines[0]);
    try testing.expectEqual(@as(u16, 5), triggered_lines[1]);
}

test "vdp pal timing enters vblank at pal visible line count" {
    var vdp = Vdp.init();
    vdp.pal_mode = true;

    try testing.expect(!vdp.setScanlineState(clock.pal_visible_lines - 1, clock.pal_visible_lines, clock.pal_lines_per_frame));
    try testing.expect(vdp.setScanlineState(clock.pal_visible_lines, clock.pal_visible_lines, clock.pal_lines_per_frame));
}

test "vdp interlace odd frame does not shift h counter" {
    var vdp = Vdp.init();
    vdp.regs[12] = 0x06; // Interlace mode 2
    _ = vdp.setScanlineState(0, clock.ntsc_visible_lines, clock.ntsc_lines_per_frame);

    vdp.odd_frame = false;
    const hv_even = vdp.readHVCounter();
    vdp.odd_frame = true;
    const hv_odd = vdp.readHVCounter();

    try testing.expectEqual(@as(u8, @truncate(hv_even)), @as(u8, @truncate(hv_odd)));
}

test "vdp adjusted hv counter samples future line master cycles" {
    var vdp = Vdp.init();
    _ = vdp.setScanlineState(10, clock.ntsc_visible_lines, clock.ntsc_lines_per_frame);

    try testing.expectEqual(vdp.readHVCounter(), vdp.readHVCounterAdjusted(0x3039)); // MOVE

    const hv_cmpi = vdp.readHVCounterAdjusted(0x0C39);
    try testing.expectEqual(@as(u8, 0x01), @as(u8, @truncate(hv_cmpi)));

    const hv_other = vdp.readHVCounterAdjusted(0x4A79);
    try testing.expectEqual(@as(u8, 0x02), @as(u8, @truncate(hv_other)));
}

test "vdp h40 h counter jumps to the hsync range encoding" {
    var vdp = Vdp.init();
    vdp.regs[12] = 0x81; // H40 mode
    _ = vdp.setScanlineState(0, clock.ntsc_visible_lines, clock.ntsc_lines_per_frame);

    vdp.line_master_cycle = 2912;
    try testing.expectEqual(@as(u8, 0xB6), @as(u8, @truncate(vdp.readHVCounter())));

    vdp.line_master_cycle = 2920;
    try testing.expectEqual(@as(u8, 0xE4), @as(u8, @truncate(vdp.readHVCounter())));
}

test "vdp line timing points are mode-aware" {
    var vdp = Vdp.init();
    try testing.expectEqual(@as(u16, 2660), vdp.hInterruptMasterCycles());
    try testing.expectEqual(@as(u16, 2640), vdp.hblankStartMasterCycles());

    vdp.regs[12] = 0x81; // H40 mode
    try testing.expectEqual(@as(u16, 2640), vdp.hInterruptMasterCycles());
    try testing.expectEqual(@as(u16, 2768), vdp.hblankStartMasterCycles());
}

test "vdp adjusted status can see hblank edge earlier for non-move reads" {
    var vdp = Vdp.init();
    _ = vdp.setScanlineState(0, clock.ntsc_visible_lines, clock.ntsc_lines_per_frame);
    vdp.line_master_cycle = 2920;
    vdp.hblank = false;

    try testing.expectEqual(@as(u16, 0), vdp.readControlAdjusted(0x3039) & 0x0004); // MOVE
    try testing.expectEqual(@as(u16, 0x0004), vdp.readControlAdjusted(0x4A79) & 0x0004);
}

test "vdp adjusted status can see vint edge earlier for non-move reads" {
    var move_vdp = Vdp.init();
    _ = move_vdp.setScanlineState(clock.ntsc_visible_lines - 1, clock.ntsc_visible_lines, clock.ntsc_lines_per_frame);
    move_vdp.line_master_cycle = move_vdp.hInterruptMasterCycles() - 1;

    try testing.expectEqual(@as(u16, 0), move_vdp.readControlAdjusted(0x3039) & 0x0080); // MOVE

    var other_vdp = Vdp.init();
    _ = other_vdp.setScanlineState(clock.ntsc_visible_lines - 1, clock.ntsc_visible_lines, clock.ntsc_lines_per_frame);
    other_vdp.line_master_cycle = other_vdp.hInterruptMasterCycles() - 1;

    try testing.expectEqual(@as(u16, 0x0080), other_vdp.readControlAdjusted(0x4A79) & 0x0080);
}

test "vdp status hblank bit follows mode-aware timing" {
    var vdp = Vdp.init();
    _ = vdp.setScanlineState(0, clock.ntsc_visible_lines, clock.ntsc_lines_per_frame);
    vdp.hblank = false;

    vdp.line_master_cycle = 0;
    try testing.expectEqual(@as(u16, 0x0004), vdp.readControl() & 0x0004);

    vdp.line_master_cycle = 100;
    try testing.expectEqual(@as(u16, 0), vdp.readControl() & 0x0004);

    vdp.line_master_cycle = 2940;
    try testing.expectEqual(@as(u16, 0x0004), vdp.readControl() & 0x0004);
}

test "vdp ntsc 224-line v counter aliases after line 234" {
    var vdp = Vdp.init();
    vdp.pal_mode = false;
    vdp.regs[1] &= ~@as(u8, 0x08); // 224-line mode threshold

    _ = vdp.setScanlineState(234, clock.ntsc_visible_lines, clock.ntsc_lines_per_frame);
    const hv_234 = vdp.readHVCounter();
    try testing.expectEqual(@as(u8, 0xEA), @as(u8, @truncate(hv_234 >> 8)));

    _ = vdp.setScanlineState(235, clock.ntsc_visible_lines, clock.ntsc_lines_per_frame);
    const hv_235 = vdp.readHVCounter();
    try testing.expectEqual(@as(u8, 0xE5), @as(u8, @truncate(hv_235 >> 8)));
}

test "vdp hv counter advances to the next line during hblank" {
    var vdp = Vdp.init();
    _ = vdp.setScanlineState(10, clock.ntsc_visible_lines, clock.ntsc_lines_per_frame);

    vdp.line_master_cycle = 2659;
    try testing.expectEqual(@as(u8, 10), @as(u8, @truncate(vdp.readHVCounter() >> 8)));

    vdp.line_master_cycle = 2660;
    try testing.expectEqual(@as(u8, 11), @as(u8, @truncate(vdp.readHVCounter() >> 8)));
}

test "vdp ntsc v counter ignores the 240-line bit" {
    var vdp = Vdp.init();
    vdp.pal_mode = false;
    vdp.regs[1] |= 0x08; // Should not affect NTSC V counter mapping.

    _ = vdp.setScanlineState(235, clock.ntsc_visible_lines, clock.ntsc_lines_per_frame);
    try testing.expectEqual(@as(u8, 0xE5), @as(u8, @truncate(vdp.readHVCounter() >> 8)));
}

test "vdp pal 240-line v counter aliases after line 266" {
    var vdp = Vdp.init();
    vdp.pal_mode = true;
    vdp.regs[1] |= 0x08; // 240-line mode threshold

    _ = vdp.setScanlineState(266, clock.pal_visible_lines, clock.pal_lines_per_frame);
    const hv_266 = vdp.readHVCounter();
    try testing.expectEqual(@as(u8, 0x0A), @as(u8, @truncate(hv_266 >> 8)));

    _ = vdp.setScanlineState(267, clock.pal_visible_lines, clock.pal_lines_per_frame);
    const hv_267 = vdp.readHVCounter();
    try testing.expectEqual(@as(u8, 0xD2), @as(u8, @truncate(hv_267 >> 8)));
}

test "vdp pal 224-line v counter follows the hardware alias window" {
    var vdp = Vdp.init();
    vdp.pal_mode = true;
    vdp.regs[1] &= ~@as(u8, 0x08); // 224-line mode

    const expected = [_]u8{ 0xFF, 0x00, 0x01, 0x02, 0xCA, 0xCB, 0xCC };
    for (expected, 255..) |expected_v, line| {
        _ = vdp.setScanlineState(@intCast(line), clock.ntsc_visible_lines, clock.pal_lines_per_frame);
        try testing.expectEqual(expected_v, @as(u8, @truncate(vdp.readHVCounter() >> 8)));
    }
}

test "vdp pal 240-line v counter follows the hardware alias window" {
    var vdp = Vdp.init();
    vdp.pal_mode = true;
    vdp.regs[1] |= 0x08; // 240-line mode

    const expected = [_]u8{ 0xFF, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0xD2, 0xD3 };
    for (expected, 255..) |expected_v, line| {
        _ = vdp.setScanlineState(@intCast(line), clock.pal_visible_lines, clock.pal_lines_per_frame);
        try testing.expectEqual(expected_v, @as(u8, @truncate(vdp.readHVCounter() >> 8)));
    }
}

test "vdp interlace mode 2 doubles the external v counter" {
    var vdp = Vdp.init();
    vdp.regs[12] = 0x06; // Interlace mode 2
    vdp.odd_frame = false;

    const expected = [_]u8{ 0x00, 0x02, 0x04, 0x06, 0x08 };
    for (expected, 0..) |expected_v, line| {
        _ = vdp.setScanlineState(@intCast(line), clock.ntsc_visible_lines, clock.ntsc_lines_per_frame);
        try testing.expectEqual(expected_v, @as(u8, @truncate(vdp.readHVCounter() >> 8)));
    }
}

test "vdp hv latch holds value while latch bit is enabled" {
    var vdp = Vdp.init();
    vdp.regs[0] |= 0x02; // Enable H/V latch

    _ = vdp.setScanlineState(32, clock.ntsc_visible_lines, clock.ntsc_lines_per_frame);
    vdp.step(400);
    const before_latch = vdp.readHVCounter();

    vdp.setHBlank(true); // Capture live counter on HBlank edge.
    const latched = vdp.readHVCounter();
    try testing.expectEqual(latched, vdp.readHVCounter());

    _ = vdp.setScanlineState(33, clock.ntsc_visible_lines, clock.ntsc_lines_per_frame);
    vdp.step(800);
    try testing.expectEqual(latched, vdp.readHVCounter());

    // Disable latch and verify live counter becomes visible again.
    vdp.writeControl(0x8000); // Reg0 = 0, clears latch mode
    const live_after_disable = vdp.readHVCounter();
    try testing.expect(live_after_disable != latched);
    try testing.expect(before_latch != 0 or latched != 0);
}

test "vdp control decode does not treat 0xA*** command word as register write" {
    var vdp = Vdp.init();

    // 0xA000 has top bits 101 and is part of address/code command space.
    vdp.writeControl(0xA000);
    try testing.expect(vdp.pending_command);
}

test "vdp hv counter reads clear pending command latch" {
    var vdp = Vdp.init();

    vdp.writeControl(0xA000);
    try testing.expect(vdp.pending_command);
    _ = vdp.readHVCounter();
    try testing.expect(!vdp.pending_command);

    vdp.writeControl(0xA000);
    try testing.expect(vdp.pending_command);
    _ = vdp.readHVCounterAdjusted(0x4A79);
    try testing.expect(!vdp.pending_command);
}

test "sonic rom advances startup state across frames" {
    var bus = try Bus.init(testing.allocator, "roms/sn.smd");
    defer bus.deinit(testing.allocator);
    var cpu = Cpu.init();
    cpu.reset(&bus);

    var m68k_sync = clock.M68kSync{};
    runEmulatedFrames(&bus, &cpu, &m68k_sync, 12);

    try testing.expect(@as(u32, cpu.core.pc) != 0x0000_0200);
    try testing.expect(bus.vdp.regs[1] != 0 or bus.vdp.regs[2] != 0 or bus.vdp.regs[4] != 0);
}

test "vdp renders plane B when plane A is transparent" {
    var vdp = Vdp.init();
    vdp.regs[1] = 0x44; // Display enable + mode 5
    vdp.regs[2] = 0x00; // Plane A base 0x0000
    vdp.regs[4] = 0x01; // Plane B base 0x2000
    vdp.regs[16] = 0x01; // 64-cell width

    // Backdrop color left as black. Put visible blue-ish color at palette 0 color 1.
    vdp.cram[2] = 0x02; // hi
    vdp.cram[3] = 0x00; // lo

    // Plane A tile entry at (0,0): tile 0 (all-zero -> transparent)
    vdp.vram[0x0000] = 0x00;
    vdp.vram[0x0001] = 0x00;

    // Plane B tile entry at (0,0): tile 1, palette 0
    vdp.vram[0x2000] = 0x00;
    vdp.vram[0x2001] = 0x01;

    // Tile 1 first row: all pixels index 1
    const tile1_base: usize = 32;
    vdp.vram[tile1_base + 0] = 0x11;
    vdp.vram[tile1_base + 1] = 0x11;
    vdp.vram[tile1_base + 2] = 0x11;
    vdp.vram[tile1_base + 3] = 0x11;

    vdp.renderScanline(0);
    const pixel = vdp.framebuffer[0];
    try testing.expect(pixel != 0xFF000000);
}

test "sonic rom reaches non-uniform visible output" {
    var bus = try Bus.init(testing.allocator, "roms/sn.smd");
    defer bus.deinit(testing.allocator);
    var cpu = Cpu.init();
    cpu.reset(&bus);

    var m68k_sync = clock.M68kSync{};
    runEmulatedFrames(&bus, &cpu, &m68k_sync, 90);

    const first_pixel = bus.vdp.framebuffer[0];
    var differing_pixels: usize = 0;
    var non_black_pixels: usize = 0;
    for (bus.vdp.framebuffer) |pixel| {
        if (pixel != first_pixel) differing_pixels += 1;
        if (pixel != 0xFF000000) non_black_pixels += 1;
    }

    try testing.expect((bus.vdp.regs[1] & 0x40) != 0);
    try testing.expect(non_black_pixels > 0);
    try testing.expect(differing_pixels > 0);
    try testing.expect(countUniqueFramebufferColors(bus.vdp.framebuffer[0..], 8) > 1);
}
