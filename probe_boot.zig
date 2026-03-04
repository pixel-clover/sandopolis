const std = @import("std");
const clock = @import("src/clock.zig");
const Bus = @import("src/memory.zig").Bus;
const Cpu = @import("src/cpu/cpu.zig").Cpu;

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    var bus = try Bus.init(allocator, "roms/sn.smd");
    defer bus.deinit(allocator);
    var cpu = Cpu.init();
    cpu.reset(&bus);

    var m68k_sync = clock.M68kSync{};
    const visible_lines = clock.ntsc_visible_lines;
    const total_lines = clock.ntsc_lines_per_frame;

    var frame: u32 = 0;
    while (frame < 2000 and !cpu.halted) : (frame += 1) {
        bus.vdp.beginFrame();
        for (0..total_lines) |line_idx| {
            const line: u16 = @intCast(line_idx);
            const entering_vblank = bus.vdp.setScanlineState(line, visible_lines, total_lines);
            if (entering_vblank and bus.vdp.isVBlankInterruptEnabled()) {
                cpu.requestInterrupt(6);
            }
            bus.vdp.setHBlank(false);

            const active_budget = m68k_sync.budgetFromMaster(clock.ntsc_active_master_cycles);
            const active_ran = cpu.runCycles(&bus, active_budget);
            bus.stepMaster(m68k_sync.commitM68kCycles(active_ran));

            if (bus.vdp.consumeHintForLine(line, visible_lines)) {
                cpu.requestInterrupt(4);
            }

            bus.vdp.setHBlank(true);
            const hblank_budget = m68k_sync.budgetFromMaster(clock.ntsc_hblank_master_cycles);
            const hblank_ran = cpu.runCycles(&bus, hblank_budget);
            bus.stepMaster(m68k_sync.commitM68kCycles(hblank_ran));
            bus.vdp.setHBlank(false);
        }
        bus.vdp.odd_frame = !bus.vdp.odd_frame;

        if (frame % 60 == 0) {
            var cram_nz: usize = 0;
            for (bus.vdp.cram) |b| {
                if (b != 0) cram_nz += 1;
            }
            std.debug.print(
                "f={d} pc={X:0>8} sr={X:0>4} reg1={X:0>2} reg15={X:0>2} cram_nz={d} wr(v/c/vs/u)={d}/{d}/{d}/{d} d6={X:0>8} a6={X:0>8}\n",
                .{ frame, cpu.core.pc, cpu.core.sr, bus.vdp.regs[1], bus.vdp.regs[15], cram_nz, bus.vdp.dbg_vram_writes, bus.vdp.dbg_cram_writes, bus.vdp.dbg_vsram_writes, bus.vdp.dbg_unknown_writes, cpu.core.d_regs[6].l, cpu.core.a_regs[6].l },
            );
        }
    }

    std.debug.print("done: f={d} pc={X:0>8} halted={any}\n", .{ frame, cpu.core.pc, cpu.halted });
}
