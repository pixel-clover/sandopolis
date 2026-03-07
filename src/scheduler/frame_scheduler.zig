const std = @import("std");
const testing = std.testing;
const clock = @import("../clock.zig");
const SchedulerBus = @import("runtime.zig").SchedulerBus;
const SchedulerCpu = @import("runtime.zig").SchedulerCpu;

pub const idle_master_quantum: u32 = 56;

pub fn runMasterSlice(bus: SchedulerBus, cpu: SchedulerCpu, m68k_sync: *clock.M68kSync, total_master_cycles: u32) void {
    var remaining = total_master_cycles;
    remaining -= m68k_sync.consumeDebt(remaining);

    while (remaining > 0) {
        const vdp_halts_cpu = bus.shouldHaltM68k();

        if (bus.pendingM68kWaitMasterCycles() != 0) {
            const stalled_master = bus.consumeM68kWaitMasterCycles(remaining);
            remaining -= stalled_master;
            bus.stepMaster(m68k_sync.flushStalledMaster(stalled_master));
            continue;
        }

        if (vdp_halts_cpu) {
            const quantum = @min(remaining, bus.dmaHaltQuantum());
            remaining -= quantum;
            bus.stepMaster(m68k_sync.flushStalledMaster(quantum));
            continue;
        }

        if (remaining < clock.m68k_divider) {
            bus.stepMaster(m68k_sync.commitMasterCycles(remaining));
            remaining = 0;
            continue;
        }

        var memory = bus.cpuMemory();
        const step = cpu.stepInstruction(&memory);
        const stepped_master = clock.m68kCyclesToMaster(step.m68k_cycles) + step.wait.master_cycles;
        if (stepped_master == 0) {
            const quantum = @min(remaining, idle_master_quantum);
            remaining -= quantum;
            bus.stepMaster(m68k_sync.commitMasterCycles(quantum));
            continue;
        }

        bus.stepMaster(m68k_sync.commitMasterCycles(stepped_master));
        if (stepped_master > remaining) {
            m68k_sync.addDebt(stepped_master - remaining);
            remaining = 0;
        } else {
            remaining -= stepped_master;
        }
    }
}

test "frame scheduler stalls cpu while vdp dma owns the bus" {
    const Bus = @import("../bus/bus.zig").Bus;
    const Cpu = @import("../cpu/cpu.zig").Cpu;
    var bus = try Bus.init(testing.allocator, null);
    defer bus.deinit(testing.allocator);

    std.mem.writeInt(u32, bus.rom[0..4], 0x00FF_FE00, .big);
    std.mem.writeInt(u32, bus.rom[4..8], 0x0000_0200, .big);
    bus.rom[0x0200] = 0x4E; // NOP
    bus.rom[0x0201] = 0x71;
    bus.write16(0x00E0_0000, 0xABCD);

    var cpu = Cpu.init();
    var memory = bus.cpuMemory();
    cpu.reset(&memory);
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

    runMasterSlice(bus.schedulerRuntime(), cpu.schedulerRuntime(), &m68k_sync, 8);

    try testing.expectEqual(pc_before, @as(u32, cpu.core.pc));
    try testing.expect(bus.vdp.dma_active);
    try testing.expect(bus.vdp.shouldHaltCpu());
}

test "frame scheduler does not stall cpu for pending vdp fifo writes" {
    const Bus = @import("../bus/bus.zig").Bus;
    const Cpu = @import("../cpu/cpu.zig").Cpu;
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
    var memory = bus.cpuMemory();
    cpu.reset(&memory);
    var m68k_sync = clock.M68kSync{};

    const pc_before = @as(u32, cpu.core.pc);
    runMasterSlice(bus.schedulerRuntime(), cpu.schedulerRuntime(), &m68k_sync, 56);

    try testing.expect(@as(u32, cpu.core.pc) != pc_before);
}

test "frame scheduler consumes pending z80-induced m68k wait before running cpu" {
    const Bus = @import("../bus/bus.zig").Bus;
    const Cpu = @import("../cpu/cpu.zig").Cpu;
    var bus = try Bus.init(testing.allocator, null);
    defer bus.deinit(testing.allocator);

    std.mem.writeInt(u32, bus.rom[0..4], 0x00FF_FE00, .big);
    std.mem.writeInt(u32, bus.rom[4..8], 0x0000_0200, .big);
    bus.rom[0x0200] = 0x4E; // NOP
    bus.rom[0x0201] = 0x71;
    bus.rom[0x0202] = 0x4E; // NOP
    bus.rom[0x0203] = 0x71;

    var cpu = Cpu.init();
    var memory = bus.cpuMemory();
    cpu.reset(&memory);
    var m68k_sync = clock.M68kSync{};

    bus.m68k_wait_master_cycles = clock.m68kCyclesToMaster(11);

    const pc_before = @as(u32, cpu.core.pc);
    runMasterSlice(bus.schedulerRuntime(), cpu.schedulerRuntime(), &m68k_sync, 56);
    try testing.expectEqual(pc_before, @as(u32, cpu.core.pc));
    try testing.expectEqual(clock.m68kCyclesToMaster(3), bus.pendingM68kWaitMasterCycles());

    runMasterSlice(bus.schedulerRuntime(), cpu.schedulerRuntime(), &m68k_sync, clock.m68kCyclesToMaster(3));
    try testing.expectEqual(pc_before, @as(u32, cpu.core.pc));
    try testing.expectEqual(@as(u32, 0), bus.pendingM68kWaitMasterCycles());

    runMasterSlice(bus.schedulerRuntime(), cpu.schedulerRuntime(), &m68k_sync, 56);
    try testing.expect(@as(u32, cpu.core.pc) != pc_before);
}

test "frame scheduler interleaves z80 contention within a master slice" {
    const Bus = @import("../bus/bus.zig").Bus;
    const Cpu = @import("../cpu/cpu.zig").Cpu;
    var base_bus = try Bus.init(testing.allocator, null);
    defer base_bus.deinit(testing.allocator);

    std.mem.writeInt(u32, base_bus.rom[0..4], 0x00FF_FE00, .big);
    std.mem.writeInt(u32, base_bus.rom[4..8], 0x0000_0200, .big);
    for (0..32) |i| {
        base_bus.rom[0x0200 + i * 2] = 0x4E;
        base_bus.rom[0x0201 + i * 2] = 0x71;
    }

    var base_cpu = Cpu.init();
    var base_memory = base_bus.cpuMemory();
    base_cpu.reset(&base_memory);
    var base_sync = clock.M68kSync{};
    runMasterSlice(base_bus.schedulerRuntime(), base_cpu.schedulerRuntime(), &base_sync, 224);

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
    var contended_memory = contended_bus.cpuMemory();
    contended_cpu.reset(&contended_memory);
    var contended_sync = clock.M68kSync{};

    runMasterSlice(contended_bus.schedulerRuntime(), contended_cpu.schedulerRuntime(), &contended_sync, 224);

    try testing.expect(@as(u32, contended_cpu.core.pc) < @as(u32, base_cpu.core.pc));
    try testing.expect(@as(u32, contended_cpu.core.pc) > 0x0200);
    try testing.expect(contended_bus.z80.getPc() != 0);
}

test "frame scheduler carries instruction overshoot between slices" {
    const Bus = @import("../bus/bus.zig").Bus;
    const Cpu = @import("../cpu/cpu.zig").Cpu;
    var bus = try Bus.init(testing.allocator, null);
    defer bus.deinit(testing.allocator);

    std.mem.writeInt(u32, bus.rom[0..4], 0x00FF_FE00, .big);
    std.mem.writeInt(u32, bus.rom[4..8], 0x0000_0200, .big);
    bus.rom[0x0200] = 0x4E;
    bus.rom[0x0201] = 0x71;
    bus.rom[0x0202] = 0x4E;
    bus.rom[0x0203] = 0x71;

    var cpu = Cpu.init();
    var memory = bus.cpuMemory();
    cpu.reset(&memory);
    var m68k_sync = clock.M68kSync{};

    runMasterSlice(bus.schedulerRuntime(), cpu.schedulerRuntime(), &m68k_sync, 7);
    try testing.expectEqual(@as(u32, 0x0202), @as(u32, cpu.core.pc));
    try testing.expectEqual(@as(u32, 21), m68k_sync.debt_master_cycles);

    runMasterSlice(bus.schedulerRuntime(), cpu.schedulerRuntime(), &m68k_sync, 21);
    try testing.expectEqual(@as(u32, 0x0202), @as(u32, cpu.core.pc));
    try testing.expectEqual(@as(u32, 0), m68k_sync.debt_master_cycles);

    runMasterSlice(bus.schedulerRuntime(), cpu.schedulerRuntime(), &m68k_sync, 7);
    try testing.expectEqual(@as(u32, 0x0204), @as(u32, cpu.core.pc));
    try testing.expectEqual(@as(u32, 21), m68k_sync.debt_master_cycles);
}
