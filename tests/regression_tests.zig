const std = @import("std");
const testing = std.testing;
const sandopolis = @import("sandopolis_src");
const clock = sandopolis.clock;
const scheduler = sandopolis.scheduler;
const Bus = sandopolis.Bus;
const Cpu = sandopolis.Cpu;

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

test "sonic rom advances startup state across frames" {
    var bus = try Bus.init(testing.allocator, "roms/sn.smd");
    defer bus.deinit(testing.allocator);
    var cpu = Cpu.init();
    var memory = bus.cpuMemory();
    cpu.reset(&memory);

    var m68k_sync = clock.M68kSync{};
    runEmulatedFrames(&bus, &cpu, &m68k_sync, 12);

    try testing.expect(@as(u32, cpu.core.pc) != 0x0000_0200);
    try testing.expect(bus.vdp.regs[1] != 0 or bus.vdp.regs[2] != 0 or bus.vdp.regs[4] != 0);
}

test "sonic rom reaches non-uniform visible output" {
    var bus = try Bus.init(testing.allocator, "roms/sn.smd");
    defer bus.deinit(testing.allocator);
    var cpu = Cpu.init();
    var memory = bus.cpuMemory();
    cpu.reset(&memory);

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

test "sonic rom initializes audio shadow state" {
    var bus = try Bus.init(testing.allocator, "roms/sn.smd");
    defer bus.deinit(testing.allocator);
    var cpu = Cpu.init();
    var memory = bus.cpuMemory();
    cpu.reset(&memory);

    var m68k_sync = clock.M68kSync{};
    runEmulatedFrames(&bus, &cpu, &m68k_sync, 180);

    const psg_active = bus.z80.getPsgLast() != 0 or
        bus.z80.getPsgTone(0) != 0 or
        bus.z80.getPsgTone(1) != 0 or
        bus.z80.getPsgTone(2) != 0 or
        bus.z80.getPsgVolume(0) != 0x0F or
        bus.z80.getPsgVolume(1) != 0x0F or
        bus.z80.getPsgVolume(2) != 0x0F or
        bus.z80.getPsgVolume(3) != 0x0F or
        bus.z80.getPsgNoise() != 0;
    const ym_active = bus.z80.getYmKeyMask() != 0 or
        bus.z80.getYmRegister(0, 0x28) != 0 or
        bus.z80.getYmRegister(0, 0x2B) != 0 or
        bus.z80.getYmRegister(0, 0x2A) != 0 or
        bus.z80.getYmRegister(0, 0xA0) != 0 or
        bus.z80.getYmRegister(0, 0xA4) != 0 or
        bus.z80.getYmRegister(1, 0xA0) != 0 or
        bus.z80.getYmRegister(1, 0xA4) != 0;

    try testing.expect(psg_active or ym_active);
}
