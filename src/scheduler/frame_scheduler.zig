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
