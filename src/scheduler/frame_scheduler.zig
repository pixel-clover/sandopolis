const clock = @import("../clock.zig");
const SchedulerBus = @import("runtime.zig").SchedulerBus;
const SchedulerCpu = @import("runtime.zig").SchedulerCpu;

pub const idle_master_quantum: u32 = 56;

pub fn runMasterSlice(bus: SchedulerBus, cpu: SchedulerCpu, m68k_sync: *clock.M68kSync, total_master_cycles: u32) void {
    var remaining = total_master_cycles;
    remaining -= m68k_sync.consumeDebt(remaining);

    // Hoist the memory interface outside the loop — the memory map does not
    // change during a single scheduler slice, so constructing the vtable
    // struct once avoids rebuilding 12 function pointers per instruction.
    var memory = bus.cpuMemory();

    while (remaining > 0) {
        const vdp_halts_cpu = bus.shouldHaltM68k();

        if (bus.pendingM68kWaitMasterCycles() != 0) {
            const stalled_master = bus.consumeM68kWaitMasterCycles(remaining);
            remaining -= stalled_master;
            bus.stepMaster(m68k_sync.flushStalledMaster(stalled_master));
            continue;
        }

        if (vdp_halts_cpu) {
            if (clock.enable_dma_refresh_windows) {
                // Check how far we are from the next refresh slot.
                const gap = bus.dmaRefreshGapMasterCycles();
                if (gap > 0) {
                    // Not in a refresh slot: stall until one begins.
                    bus.resetRefreshCounter();
                    const stall = @min(remaining, gap);
                    remaining -= stall;
                    bus.stepMaster(m68k_sync.flushStalledMaster(stall));
                    continue;
                }
                // Inside a refresh slot: run the 68K. Each bus access
                // within noteBusAccessWait injects DMA contention wait
                // cycles via projectedDmaWaitMasterCycles, so the 68K
                // instruction naturally stretches across refresh slots
                // if it requires multiple bus accesses.
                if (remaining >= clock.m68k_divider) {
                    const step = cpu.stepInstruction(&memory);
                    const stepped_master = clock.m68kCyclesToMaster(step.m68k_cycles) + step.wait.master_cycles;
                    if (stepped_master == 0) {
                        bus.resetRefreshCounter();
                        const quantum = @min(remaining, idle_master_quantum);
                        remaining -= quantum;
                        bus.stepMaster(m68k_sync.commitMasterCycles(quantum));
                        continue;
                    }
                    bus.recordRefreshCycles(step.m68k_cycles, step.ppc);
                    bus.stepMaster(m68k_sync.commitMasterCycles(stepped_master));
                    if (stepped_master > remaining) {
                        m68k_sync.addDebt(stepped_master - remaining);
                        remaining = 0;
                    } else {
                        remaining -= stepped_master;
                    }
                    continue;
                }
            }
            // Fallback (or refresh windows disabled): monolithic halt.
            bus.resetRefreshCounter();
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

        const step = cpu.stepInstruction(&memory);
        const stepped_master = clock.m68kCyclesToMaster(step.m68k_cycles) + step.wait.master_cycles;
        if (stepped_master == 0) {
            bus.resetRefreshCounter();
            const quantum = @min(remaining, idle_master_quantum);
            remaining -= quantum;
            bus.stepMaster(m68k_sync.commitMasterCycles(quantum));
            continue;
        }

        bus.recordRefreshCycles(step.m68k_cycles, step.ppc);
        bus.stepMaster(m68k_sync.commitMasterCycles(stepped_master));
        if (stepped_master > remaining) {
            m68k_sync.addDebt(stepped_master - remaining);
            remaining = 0;
        } else {
            remaining -= stepped_master;
        }
    }

    // Run the Z80 as a burst after all M68K instructions for this slice.
    // This matches the per-line burst model where both CPUs run to the same
    // target: M68K first, then Z80.  The Z80 sees all M68K shared-RAM
    // writes before executing, avoiding race conditions in Z80 sound
    // drivers like SOR's GEMS that depend on initialization order.
    bus.flushDeferredZ80();
}
