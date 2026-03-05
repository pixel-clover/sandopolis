const std = @import("std");
const testing = std.testing;
const clock = @import("clock.zig");
const frame_scheduler = @import("frame_scheduler.zig");
const Bus = @import("memory.zig").Bus;
const Cpu = @import("cpu/cpu.zig").Cpu;
const Vdp = @import("vdp.zig").Vdp;

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
    try testing.expect(bus.vdp.shouldHaltCpu());
    try testing.expectEqual(@as(u16, 0x000A), bus.vdp.addr);
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

test "vdp hv counter advances with line master cycles" {
    var vdp = Vdp.init();
    _ = vdp.setScanlineState(10, clock.ntsc_visible_lines, clock.ntsc_lines_per_frame);

    const hv0 = vdp.readHVCounter();
    try testing.expectEqual(@as(u8, 10), @as(u8, @truncate(hv0 >> 8)));
    try testing.expectEqual(@as(u8, 0x85), @as(u8, @truncate(hv0)));

    vdp.step(100);
    const hv1 = vdp.readHVCounter();
    try testing.expectEqual(@as(u8, 0x8A), @as(u8, @truncate(hv1)));

    vdp.step(clock.ntsc_active_master_cycles - 100);
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

test "vdp interlace odd frame shifts h counter by one" {
    var vdp = Vdp.init();
    vdp.regs[12] = 0x06; // Interlace mode 2
    _ = vdp.setScanlineState(0, clock.ntsc_visible_lines, clock.ntsc_lines_per_frame);

    vdp.odd_frame = false;
    const hv_even = vdp.readHVCounter();
    vdp.odd_frame = true;
    const hv_odd = vdp.readHVCounter();

    try testing.expectEqual(@as(u8, @truncate(hv_even)) +% 1, @as(u8, @truncate(hv_odd)));
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

test "vdp pal 240-line v counter aliases after line 262" {
    var vdp = Vdp.init();
    vdp.pal_mode = true;
    vdp.regs[1] |= 0x08; // 240-line mode threshold

    _ = vdp.setScanlineState(262, clock.pal_visible_lines, clock.pal_lines_per_frame);
    const hv_262 = vdp.readHVCounter();
    try testing.expectEqual(@as(u8, 0x06), @as(u8, @truncate(hv_262 >> 8)));

    _ = vdp.setScanlineState(263, clock.pal_visible_lines, clock.pal_lines_per_frame);
    const hv_263 = vdp.readHVCounter();
    try testing.expectEqual(@as(u8, 0xCE), @as(u8, @truncate(hv_263 >> 8)));
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

test "sonic rom advances startup state across frames" {
    var bus = try Bus.init(testing.allocator, "roms/sn.smd");
    defer bus.deinit(testing.allocator);
    var cpu = Cpu.init();
    cpu.reset(&bus);

    var m68k_sync = clock.M68kSync{};
    const visible_lines = clock.ntsc_visible_lines;
    const total_lines = clock.ntsc_lines_per_frame;

    for (0..12) |_| {
        bus.vdp.beginFrame();
        for (0..total_lines) |line_idx| {
            const line: u16 = @intCast(line_idx);
            const entering_vblank = bus.vdp.setScanlineState(line, visible_lines, total_lines);
            if (entering_vblank and bus.vdp.isVBlankInterruptEnabled()) {
                cpu.requestInterrupt(6);
            }
            bus.vdp.setHBlank(false);

            frame_scheduler.runMasterSlice(&bus, &cpu, &m68k_sync, clock.ntsc_active_master_cycles);

            if (bus.vdp.consumeHintForLine(line, visible_lines)) {
                cpu.requestInterrupt(4);
            }

            bus.vdp.setHBlank(true);
            frame_scheduler.runMasterSlice(&bus, &cpu, &m68k_sync, clock.ntsc_hblank_master_cycles);
            bus.vdp.setHBlank(false);

            if (line < visible_lines) {
                bus.vdp.renderScanline(line);
            }
        }
        bus.vdp.odd_frame = !bus.vdp.odd_frame;
    }

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

test "debug sonic long-run state snapshots" {
    var bus = try Bus.init(testing.allocator, "roms/sn.smd");
    defer bus.deinit(testing.allocator);
    var cpu = Cpu.init();
    cpu.reset(&bus);

    var m68k_sync = clock.M68kSync{};
    const visible_lines = clock.ntsc_visible_lines;
    const total_lines = clock.ntsc_lines_per_frame;

    // Dump deinterleaved ROM vectors and code
    std.debug.print("ROM SSP: {X:0>8}\n", .{bus.read32(0x000000)});
    std.debug.print("ROM PC:  {X:0>8}\n", .{bus.read32(0x000004)});
    std.debug.print("VB vec:  {X:0>8}\n", .{bus.read32(0x000078)});
    std.debug.print("Code at 0x330:\n", .{});
    {
        var ci: u32 = 0x330;
        while (ci < 0x360) : (ci += 2) {
            std.debug.print("  {X:0>6}: {X:0>4}\n", .{ ci, bus.read16(ci) });
        }
    }

    for (0..2000) |frame_idx| {
        bus.vdp.beginFrame();
        for (0..total_lines) |line_idx| {
            const line: u16 = @intCast(line_idx);
            const entering_vblank = bus.vdp.setScanlineState(line, visible_lines, total_lines);
            if (entering_vblank and bus.vdp.isVBlankInterruptEnabled()) {
                cpu.requestInterrupt(6);
            }
            bus.vdp.setHBlank(false);

            frame_scheduler.runMasterSlice(&bus, &cpu, &m68k_sync, clock.ntsc_active_master_cycles);

            if (bus.vdp.consumeHintForLine(line, visible_lines)) {
                cpu.requestInterrupt(4);
            }

            bus.vdp.setHBlank(true);
            frame_scheduler.runMasterSlice(&bus, &cpu, &m68k_sync, clock.ntsc_hblank_master_cycles);
            bus.vdp.setHBlank(false);

            if (line < visible_lines) {
                bus.vdp.renderScanline(line);
            }
        }
        bus.vdp.odd_frame = !bus.vdp.odd_frame;

        if ((frame_idx % 60) == 0) {
            var cram_nz: usize = 0;
            for (bus.vdp.cram) |b| {
                if (b != 0) cram_nz += 1;
            }
            // Read VBlank vector (level 6 auto-vector at $78)
            const vb_vector = bus.read32(0x78);
            // Read RAM at $F600 (Sonic uses this for game state)
            const ram_f600: u8 = bus.ram[0xF600];
            // SR interrupt mask level
            const sr_ipl = (cpu.core.sr >> 8) & 0x7;
            std.debug.print(
                "DBG frame={d} pc={X:0>8} sr={X:0>4} ipl={d} reg1={X:0>2} reg15={X:0>2} cram_nz={d} wr(v/c/vs/u)={d}/{d}/{d}/{d} d6={X:0>8} a6={X:0>8} vb_vec={X:0>8} f600={X:0>2}\n",
                .{
                    frame_idx,
                    cpu.core.pc,
                    cpu.core.sr,
                    sr_ipl,
                    bus.vdp.regs[1],
                    bus.vdp.regs[15],
                    cram_nz,
                    bus.vdp.dbg_vram_writes,
                    bus.vdp.dbg_cram_writes,
                    bus.vdp.dbg_vsram_writes,
                    bus.vdp.dbg_unknown_writes,
                    cpu.core.d_regs[6].l,
                    cpu.core.a_regs[6].l,
                    vb_vector,
                    ram_f600,
                },
            );
        }
    }
}
