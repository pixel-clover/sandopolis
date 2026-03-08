const std = @import("std");
const testing = std.testing;
const sandopolis = @import("sandopolis_src");
const clock = sandopolis.clock;
const scheduler = sandopolis.scheduler;
const Bus = sandopolis.Bus;
const Cpu = sandopolis.Cpu;

const graphics_sampler_rom = "tests/testroms/Graphics & Joystick Sampler by Charles Doty (PD).bin";
const window_test_rom = "tests/testroms/Window Test by Fonzie (PD).bin";
const fm_test_rom = "tests/testroms/FM Test by DevSter (PD).bin";

fn runEmulatedFrame(bus: *Bus, cpu: *Cpu, m68k_sync: *clock.M68kSync) void {
    const visible_lines = clock.ntsc_visible_lines;
    const total_lines = clock.ntsc_lines_per_frame;

    bus.vdp.beginFrame();
    for (0..total_lines) |line_idx| {
        const line: u16 = @intCast(line_idx);
        const entering_vblank = bus.vdp.setScanlineState(line, visible_lines, total_lines);
        if (entering_vblank and bus.vdp.isVBlankInterruptEnabled()) {
            cpu.requestInterrupt(6);
        }
        if (entering_vblank) {
            bus.z80.assertIrq(0xFF);
        }
        bus.vdp.setHBlank(false);

        const hint_master_cycles = bus.vdp.hInterruptMasterCycles();
        const hblank_start_master_cycles = bus.vdp.hblankStartMasterCycles();
        const first_event_master_cycles = @min(hint_master_cycles, hblank_start_master_cycles);
        const second_event_master_cycles = @max(hint_master_cycles, hblank_start_master_cycles);

        scheduler.runMasterSlice(bus.schedulerRuntime(), cpu.schedulerRuntime(), m68k_sync, first_event_master_cycles);

        if (hblank_start_master_cycles == first_event_master_cycles) {
            bus.vdp.setHBlank(true);
        }
        if (hint_master_cycles == first_event_master_cycles and bus.vdp.consumeHintForLine(line, visible_lines)) {
            cpu.requestInterrupt(4);
        }

        scheduler.runMasterSlice(bus.schedulerRuntime(), cpu.schedulerRuntime(), m68k_sync, second_event_master_cycles - first_event_master_cycles);

        if (hblank_start_master_cycles == second_event_master_cycles and hblank_start_master_cycles != first_event_master_cycles) {
            bus.vdp.setHBlank(true);
        }
        if (hint_master_cycles == second_event_master_cycles and hint_master_cycles != first_event_master_cycles and bus.vdp.consumeHintForLine(line, visible_lines)) {
            cpu.requestInterrupt(4);
        }

        scheduler.runMasterSlice(bus.schedulerRuntime(), cpu.schedulerRuntime(), m68k_sync, clock.ntsc_master_cycles_per_line - second_event_master_cycles);
        bus.vdp.setHBlank(false);
        if (entering_vblank) {
            bus.z80.clearIrq();
        }

        if (line < visible_lines) {
            bus.vdp.renderScanline(line);
        }
    }
    bus.vdp.odd_frame = !bus.vdp.odd_frame;
}

fn runEmulatedFrames(bus: *Bus, cpu: *Cpu, m68k_sync: *clock.M68kSync, frames: usize) void {
    for (0..frames) |_| {
        runEmulatedFrame(bus, cpu, m68k_sync);
    }
}

fn seedResetNops(bus: *Bus, nop_count: usize) void {
    std.mem.writeInt(u32, bus.rom[0..4], 0x00FF_FE00, .big);
    std.mem.writeInt(u32, bus.rom[4..8], 0x0000_0200, .big);
    for (0..nop_count) |i| {
        bus.rom[0x0200 + i * 2] = 0x4E;
        bus.rom[0x0201 + i * 2] = 0x71;
    }
}

fn resetCpuForBus(bus: *Bus) Cpu {
    var cpu = Cpu.init();
    var memory = bus.cpuMemory();
    cpu.reset(&memory);
    return cpu;
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
    var bus = try Bus.init(testing.allocator, graphics_sampler_rom);
    defer bus.deinit(testing.allocator);
    var cpu = resetCpuForBus(&bus);

    var m68k_sync = clock.M68kSync{};
    runEmulatedFrames(&bus, &cpu, &m68k_sync, 24);

    try testing.expect(@as(u32, cpu.core.pc) != 0x0000_0200);
    try testing.expect(bus.vdp.regs[1] != 0 or bus.vdp.regs[2] != 0 or bus.vdp.regs[4] != 0);
}

test "window test rom reaches non-uniform visible output" {
    var bus = try Bus.init(testing.allocator, window_test_rom);
    defer bus.deinit(testing.allocator);
    var cpu = resetCpuForBus(&bus);

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

test "fm test rom initializes ym shadow state" {
    var bus = try Bus.init(testing.allocator, fm_test_rom);
    defer bus.deinit(testing.allocator);
    var cpu = resetCpuForBus(&bus);

    var m68k_sync = clock.M68kSync{};
    runEmulatedFrames(&bus, &cpu, &m68k_sync, 120);
    const pending = bus.audio_timing.takePending();

    const ym_active = bus.z80.getYmKeyMask() != 0 or
        bus.z80.getYmRegister(0, 0x28) != 0 or
        bus.z80.getYmRegister(0, 0x2B) != 0 or
        bus.z80.getYmRegister(0, 0x2A) != 0 or
        bus.z80.getYmRegister(0, 0xA0) != 0 or
        bus.z80.getYmRegister(0, 0xA4) != 0 or
        bus.z80.getYmRegister(1, 0xA0) != 0 or
        bus.z80.getYmRegister(1, 0xA4) != 0;

    try testing.expect(pending.fm_frames != 0 or pending.psg_frames != 0);
    try testing.expect(ym_active);
}

test "frame scheduler stalls cpu while vdp dma owns the bus" {
    var bus = try Bus.init(testing.allocator, null);
    defer bus.deinit(testing.allocator);
    seedResetNops(&bus, 1);
    bus.write16(0x00E0_0000, 0xABCD);

    var cpu = resetCpuForBus(&bus);
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

    scheduler.runMasterSlice(bus.schedulerRuntime(), cpu.schedulerRuntime(), &m68k_sync, 8);

    try testing.expectEqual(pc_before, @as(u32, cpu.core.pc));
    try testing.expect(bus.vdp.dma_active);
    try testing.expect(bus.vdp.shouldHaltCpu());
}

test "frame scheduler does not stall cpu for pending vdp fifo writes" {
    var bus = try Bus.init(testing.allocator, null);
    defer bus.deinit(testing.allocator);
    seedResetNops(&bus, 2);

    bus.vdp.regs[15] = 2;
    bus.vdp.code = 0x1;
    bus.vdp.addr = 0x0000;
    bus.vdp.writeData(0x0102);
    bus.vdp.writeData(0x0304);
    bus.vdp.writeData(0x0506);
    bus.vdp.writeData(0x0708);
    bus.vdp.writeData(0x090A);

    try testing.expect(!bus.vdp.shouldHaltCpu());

    var cpu = resetCpuForBus(&bus);
    var m68k_sync = clock.M68kSync{};
    const pc_before = @as(u32, cpu.core.pc);

    scheduler.runMasterSlice(bus.schedulerRuntime(), cpu.schedulerRuntime(), &m68k_sync, 56);

    try testing.expect(@as(u32, cpu.core.pc) != pc_before);
}

test "frame scheduler consumes pending z80-induced m68k wait before running cpu" {
    var bus = try Bus.init(testing.allocator, null);
    defer bus.deinit(testing.allocator);
    seedResetNops(&bus, 2);

    var cpu = resetCpuForBus(&bus);
    var m68k_sync = clock.M68kSync{};

    bus.m68k_wait_master_cycles = clock.m68kCyclesToMaster(11);

    const pc_before = @as(u32, cpu.core.pc);
    scheduler.runMasterSlice(bus.schedulerRuntime(), cpu.schedulerRuntime(), &m68k_sync, 56);
    try testing.expectEqual(pc_before, @as(u32, cpu.core.pc));
    try testing.expectEqual(clock.m68kCyclesToMaster(3), bus.pendingM68kWaitMasterCycles());

    scheduler.runMasterSlice(bus.schedulerRuntime(), cpu.schedulerRuntime(), &m68k_sync, clock.m68kCyclesToMaster(3));
    try testing.expectEqual(pc_before, @as(u32, cpu.core.pc));
    try testing.expectEqual(@as(u32, 0), bus.pendingM68kWaitMasterCycles());

    scheduler.runMasterSlice(bus.schedulerRuntime(), cpu.schedulerRuntime(), &m68k_sync, 56);
    try testing.expect(@as(u32, cpu.core.pc) != pc_before);
}

test "frame scheduler interleaves z80 contention within a master slice" {
    var base_bus = try Bus.init(testing.allocator, null);
    defer base_bus.deinit(testing.allocator);
    seedResetNops(&base_bus, 32);

    var base_cpu = resetCpuForBus(&base_bus);
    var base_sync = clock.M68kSync{};
    scheduler.runMasterSlice(base_bus.schedulerRuntime(), base_cpu.schedulerRuntime(), &base_sync, 224);

    var contended_bus = try Bus.init(testing.allocator, null);
    defer contended_bus.deinit(testing.allocator);
    std.mem.copyForwards(u8, contended_bus.rom, base_bus.rom);

    contended_bus.z80.reset();
    contended_bus.z80.writeByte(0x0000, 0x3A);
    contended_bus.z80.writeByte(0x0001, 0x00);
    contended_bus.z80.writeByte(0x0002, 0x80);
    contended_bus.z80.writeByte(0x0003, 0x18);
    contended_bus.z80.writeByte(0x0004, 0xFB);
    contended_bus.rom[0x0000] = 0x12;

    var contended_cpu = resetCpuForBus(&contended_bus);
    var contended_sync = clock.M68kSync{};
    scheduler.runMasterSlice(contended_bus.schedulerRuntime(), contended_cpu.schedulerRuntime(), &contended_sync, 224);

    try testing.expect(@as(u32, contended_cpu.core.pc) < @as(u32, base_cpu.core.pc));
    try testing.expect(@as(u32, contended_cpu.core.pc) > 0x0200);
    try testing.expect(contended_bus.z80.getPc() != 0);
}

test "frame scheduler carries instruction overshoot between slices" {
    var bus = try Bus.init(testing.allocator, null);
    defer bus.deinit(testing.allocator);
    seedResetNops(&bus, 2);

    var cpu = resetCpuForBus(&bus);
    var m68k_sync = clock.M68kSync{};

    scheduler.runMasterSlice(bus.schedulerRuntime(), cpu.schedulerRuntime(), &m68k_sync, 7);
    try testing.expectEqual(@as(u32, 0x0202), @as(u32, cpu.core.pc));
    try testing.expectEqual(@as(u32, 21), m68k_sync.debt_master_cycles);

    scheduler.runMasterSlice(bus.schedulerRuntime(), cpu.schedulerRuntime(), &m68k_sync, 21);
    try testing.expectEqual(@as(u32, 0x0202), @as(u32, cpu.core.pc));
    try testing.expectEqual(@as(u32, 0), m68k_sync.debt_master_cycles);

    scheduler.runMasterSlice(bus.schedulerRuntime(), cpu.schedulerRuntime(), &m68k_sync, 7);
    try testing.expectEqual(@as(u32, 0x0204), @as(u32, cpu.core.pc));
    try testing.expectEqual(@as(u32, 21), m68k_sync.debt_master_cycles);
}
