const std = @import("std");
const clock = @import("../clock.zig");
const Bus = @import("../memory.zig").Bus;

const c = @cImport({
    @cInclude("m68k.h");
});

var active_bus: ?*Bus = null;
var active_cpu: ?*Cpu = null;
var fallback_memory = [_]u8{0} ** 8;

fn isVdpDataPortAddress(address: u32) bool {
    const addr = address & 0xFFFFFF;
    return addr >= 0xC00000 and addr <= 0xDFFFFF and (addr & 0x1F) < 0x04;
}

fn isVdpControlPortAddress(address: u32) bool {
    const addr = address & 0xFFFFFF;
    const port = addr & 0x1F;
    return addr >= 0xC00000 and addr <= 0xDFFFFF and port >= 0x04 and port < 0x08;
}

fn cpuRead8(_: ?*c.M68kCpu, address: c.u32) callconv(.c) c.u8 {
    const bus = active_bus orelse return 0;
    const cpu = active_cpu orelse return 0;
    cpu.noteBusAccessWait(bus, address, 1, false);
    return @intCast(bus.read8(address));
}

fn cpuRead16(_: ?*c.M68kCpu, address: c.u32) callconv(.c) c.u16 {
    const bus = active_bus orelse return 0;
    const cpu = active_cpu orelse return 0;
    cpu.noteBusAccessWait(bus, address, 2, false);
    return @intCast(bus.read16(address));
}

fn cpuRead32(_: ?*c.M68kCpu, address: c.u32) callconv(.c) c.u32 {
    const bus = active_bus orelse return 0;
    const cpu = active_cpu orelse return 0;
    cpu.noteBusAccessWait(bus, address, 4, false);
    return @intCast(bus.read32(address));
}

fn cpuWrite8(_: ?*c.M68kCpu, address: c.u32, value: c.u8) callconv(.c) void {
    const bus = active_bus orelse return;
    const cpu = active_cpu orelse return;
    cpu.noteBusAccessWait(bus, address, 1, true);
    bus.write8(address, value);
}

fn cpuWrite16(_: ?*c.M68kCpu, address: c.u32, value: c.u16) callconv(.c) void {
    const bus = active_bus orelse return;
    const cpu = active_cpu orelse return;
    cpu.noteBusAccessWait(bus, address, 2, true);
    bus.write16(address, value);
}

fn cpuWrite32(_: ?*c.M68kCpu, address: c.u32, value: c.u32) callconv(.c) void {
    const bus = active_bus orelse return;
    const cpu = active_cpu orelse return;
    cpu.noteBusAccessWait(bus, address, 4, true);
    if (isVdpDataPortAddress(address)) {
        bus.write16(address, @intCast((value >> 16) & 0xFFFF));
        bus.write16(address + 2, @intCast(value & 0xFFFF));
        return;
    }

    bus.write32(address, value);
}

fn cpuIntAck(_: ?*c.M68kCpu, _: c_int) callconv(.c) c_int {
    // Do NOT clear irq_level here — rocket68 reads it after this callback
    // to compute the autovector (24 + irq_level). Clearing it would make
    // every interrupt use vector 24 (spurious) instead of the correct one.
    // The level is cleared when the VDP status register is read.
    return -1;
}

pub fn getActiveCpu() ?*Cpu {
    return active_cpu;
}

pub const Cpu = struct {
    const default_stack_pointer: u32 = 0x00FF_FE00;
    const default_program_counter: u32 = 0x0000_0200;

    pub const WaitAccounting = struct {
        m68k_cycles: u32 = 0,
        master_cycles: u32 = 0,
    };

    pub const InstructionStep = struct {
        m68k_cycles: u32,
        wait: WaitAccounting,
    };

    core: c.M68kCpu,
    cycles: u64,
    halted: bool,
    pending_wait_cycles: u32,
    pending_wait_master_cycles: u32,

    pub var trace_enabled: bool = false;

    pub fn init() Cpu {
        var self = Cpu{
            .core = std.mem.zeroes(c.M68kCpu),
            .cycles = 0,
            .halted = false,
            .pending_wait_cycles = 0,
            .pending_wait_master_cycles = 0,
        };

        c.m68k_init(&self.core, &fallback_memory[0], fallback_memory.len);
        c.m68k_set_read8_callback(&self.core, cpuRead8);
        c.m68k_set_read16_callback(&self.core, cpuRead16);
        c.m68k_set_read32_callback(&self.core, cpuRead32);
        c.m68k_set_write8_callback(&self.core, cpuWrite8);
        c.m68k_set_write16_callback(&self.core, cpuWrite16);
        c.m68k_set_write32_callback(&self.core, cpuWrite32);
        c.m68k_set_int_ack_callback(&self.core, cpuIntAck);

        return self;
    }

    pub fn reset(self: *Cpu, bus: *Bus) void {
        active_bus = bus;
        c.m68k_reset(&self.core);

        // Some ROMs/test payloads leave vectors unset. Keep behavior deterministic by
        // applying sane boot defaults that point into 68k-visible memory.
        if (self.core.a_regs[7].l == 0 or self.core.a_regs[7].l > 0x0100_0000) {
            c.m68k_set_ar(&self.core, 7, default_stack_pointer);
            self.core.ssp = default_stack_pointer;
        }
        if (self.core.pc == 0 or self.core.pc > 0x0040_0000) {
            c.m68k_set_pc(&self.core, default_program_counter);
        }

        self.cycles = 0;
        self.halted = self.core.stopped;
        self.pending_wait_cycles = 0;
        self.pending_wait_master_cycles = 0;
    }

    fn addBusWaitMaster(self: *Cpu, master_cycles: u32) void {
        if (master_cycles == 0) return;

        const extra_cycles = std.math.divCeil(u32, master_cycles, clock.m68k_divider) catch unreachable;
        c.m68k_modify_timeslice(&self.core, @intCast(extra_cycles));
        self.pending_wait_cycles += extra_cycles;
        self.pending_wait_master_cycles += master_cycles;
    }

    pub fn noteBusAccessWait(self: *Cpu, bus: *Bus, address: u32, size_bytes: u8, is_write: bool) void {
        self.addBusWaitMaster(bus.m68kAccessWaitMasterCycles(address, size_bytes));

        if (!isVdpDataPortAddress(address)) {
            if (is_write and isVdpControlPortAddress(address)) {
                self.addBusWaitMaster(bus.vdp.controlPortWriteWaitMasterCycles());
            }
            return;
        }

        if (!is_write) {
            if (size_bytes >= 4) {
                self.addBusWaitMaster(bus.vdp.dataPortReadWaitMasterCycles());
                self.addBusWaitMaster(bus.vdp.dataPortReadWaitMasterCycles());
                return;
            }

            self.addBusWaitMaster(bus.vdp.dataPortReadWaitMasterCycles());
            return;
        }

        if (size_bytes >= 4) {
            self.addBusWaitMaster(bus.vdp.reserveDataPortWriteWaitMasterCycles());
            self.addBusWaitMaster(bus.vdp.reserveDataPortWriteWaitMasterCycles());
            return;
        }

        self.addBusWaitMaster(bus.vdp.reserveDataPortWriteWaitMasterCycles());
    }

    pub fn step(self: *Cpu, bus: *Bus) void {
        _ = self.stepInstruction(bus);
    }

    pub fn stepInstruction(self: *Cpu, bus: *Bus) InstructionStep {
        _ = trace_enabled;

        active_bus = bus;
        active_cpu = self;
        self.pending_wait_cycles = 0;
        self.pending_wait_master_cycles = 0;
        self.core.target_cycles = 0;
        self.core.cycles_remaining = 0;

        c.m68k_step(&self.core);

        const ran_cycles_raw = c.m68k_cycles_run(&self.core);
        const ran_cycles: u32 = if (ran_cycles_raw > 0) @intCast(ran_cycles_raw) else 0;
        self.core.target_cycles = 0;
        self.core.cycles_remaining = 0;
        self.cycles += ran_cycles;
        self.halted = self.core.stopped;

        return .{
            .m68k_cycles = ran_cycles,
            .wait = self.takeWaitAccounting(),
        };
    }

    pub fn runCycles(self: *Cpu, bus: *Bus, budget: u32) u32 {
        if (budget == 0) return 0;

        active_bus = bus;
        active_cpu = self;
        const ran = c.m68k_execute(&self.core, @intCast(budget));
        const consumed: u32 = if (ran > 0) @intCast(ran) else 0;
        self.cycles += consumed;
        self.halted = self.core.stopped;
        return consumed;
    }

    pub fn takeWaitAccounting(self: *Cpu) WaitAccounting {
        const accounting = WaitAccounting{
            .m68k_cycles = self.pending_wait_cycles,
            .master_cycles = self.pending_wait_master_cycles,
        };
        self.pending_wait_cycles = 0;
        self.pending_wait_master_cycles = 0;
        return accounting;
    }

    pub fn clearInterrupt(self: *Cpu) void {
        self.core.irq_level = 0;
    }

    pub fn requestInterrupt(self: *Cpu, level: u3) void {
        const current: c_int = @intCast(self.core.irq_level);
        const new_level: c_int = @intCast(level);
        if (new_level > current) {
            c.m68k_set_irq(&self.core, new_level);
        }
    }

    pub fn debugDump(self: *const Cpu) void {
        std.debug.print("PC: {X:0>8} SR: {X:0>4} SP: {X:0>8}\n", .{
            @as(u32, self.core.pc),
            @as(u16, self.core.sr),
            @as(u32, self.core.a_regs[7].l),
        });
        for (0..8) |i| {
            std.debug.print("D{d}: {X:0>8} A{d}: {X:0>8}\n", .{
                i,
                @as(u32, self.core.d_regs[i].l),
                i,
                @as(u32, self.core.a_regs[i].l),
            });
        }
    }
};
