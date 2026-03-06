const clock = @import("clock.zig");
const Bus = @import("memory.zig").Bus;
const Cpu = @import("cpu/cpu.zig").Cpu;

pub const idle_master_quantum: u32 = 56;
pub const halt_master_quantum: u32 = 8;

pub fn runMasterSlice(bus: *Bus, cpu: *Cpu, m68k_sync: *clock.M68kSync, total_master_cycles: u32) void {
    var remaining = total_master_cycles;
    remaining -= m68k_sync.consumeDebt(remaining);

    while (remaining > 0) {
        const vdp_halts_cpu = bus.vdp.shouldHaltCpu();

        if (bus.pendingM68kWaitMasterCycles() != 0) {
            const stalled_master = bus.consumeM68kWaitMasterCycles(remaining);
            remaining -= stalled_master;
            bus.stepMaster(m68k_sync.flushStalledMaster(stalled_master));
            continue;
        }

        if (vdp_halts_cpu) {
            const quantum = @min(remaining, halt_master_quantum);
            remaining -= quantum;
            bus.stepMaster(m68k_sync.flushStalledMaster(quantum));
            continue;
        }

        if (remaining < clock.m68k_divider) {
            bus.stepMaster(m68k_sync.commitMasterCycles(remaining));
            remaining = 0;
            continue;
        }

        const step = cpu.stepInstruction(bus);
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
