const clock = @import("clock.zig");
const Bus = @import("memory.zig").Bus;
const Cpu = @import("cpu/cpu.zig").Cpu;

pub const idle_master_quantum: u32 = 56;
pub const halt_master_quantum: u32 = 8;

pub fn runMasterSlice(bus: *Bus, cpu: *Cpu, m68k_sync: *clock.M68kSync, total_master_cycles: u32) void {
    var remaining = total_master_cycles;
    while (remaining > 0) {
        const vdp_halts_cpu = bus.vdp.shouldHaltCpu();
        const quantum_limit = if (vdp_halts_cpu) halt_master_quantum else idle_master_quantum;
        const quantum = @min(remaining, quantum_limit);
        remaining -= quantum;

        if (vdp_halts_cpu) {
            bus.stepMaster(m68k_sync.flushStalledMaster(quantum));
            continue;
        }

        const budget = m68k_sync.budgetFromMaster(quantum);
        if (budget == 0) {
            bus.stepMaster(m68k_sync.commitMasterCycles(quantum));
            continue;
        }

        const ran = cpu.runCycles(bus, budget);
        const wait = cpu.takeWaitAccounting();
        const wait_m68k = @min(ran, wait.m68k_cycles);
        const executed_m68k = ran - wait_m68k;

        var stepped_master = clock.m68kCyclesToMaster(executed_m68k) + wait.master_cycles;
        if (stepped_master < quantum) {
            stepped_master = quantum;
        }

        bus.stepMaster(m68k_sync.commitMasterCycles(stepped_master));
    }
}
