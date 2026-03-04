const std = @import("std");
const Bus = @import("../memory.zig").Bus;

const c = @cImport({
    @cInclude("m68k.h");
});

var active_bus: ?*Bus = null;
var fallback_memory = [_]u8{0} ** 8;

fn cpuRead8(_: ?*c.M68kCpu, address: c.u32) callconv(.c) c.u8 {
    const bus = active_bus orelse return 0;
    return @intCast(bus.read8(address));
}

fn cpuRead16(_: ?*c.M68kCpu, address: c.u32) callconv(.c) c.u16 {
    const bus = active_bus orelse return 0;
    return @intCast(bus.read16(address));
}

fn cpuRead32(_: ?*c.M68kCpu, address: c.u32) callconv(.c) c.u32 {
    const bus = active_bus orelse return 0;
    return @intCast(bus.read32(address));
}

fn cpuWrite8(_: ?*c.M68kCpu, address: c.u32, value: c.u8) callconv(.c) void {
    const bus = active_bus orelse return;
    bus.write8(address, value);
}

fn cpuWrite16(_: ?*c.M68kCpu, address: c.u32, value: c.u16) callconv(.c) void {
    const bus = active_bus orelse return;
    bus.write16(address, value);
}

fn cpuWrite32(_: ?*c.M68kCpu, address: c.u32, value: c.u32) callconv(.c) void {
    const bus = active_bus orelse return;
    bus.write32(address, value);
}

pub const Cpu = struct {
    core: c.M68kCpu,
    cycles: u64,
    halted: bool,

    pub var trace_enabled: bool = false;

    pub fn init() Cpu {
        var self = Cpu{
            .core = std.mem.zeroes(c.M68kCpu),
            .cycles = 0,
            .halted = false,
        };

        c.m68k_init(&self.core, &fallback_memory[0], fallback_memory.len);
        c.m68k_set_read8_callback(&self.core, cpuRead8);
        c.m68k_set_read16_callback(&self.core, cpuRead16);
        c.m68k_set_read32_callback(&self.core, cpuRead32);
        c.m68k_set_write8_callback(&self.core, cpuWrite8);
        c.m68k_set_write16_callback(&self.core, cpuWrite16);
        c.m68k_set_write32_callback(&self.core, cpuWrite32);

        return self;
    }

    pub fn reset(self: *Cpu, bus: *Bus) void {
        active_bus = bus;
        c.m68k_reset(&self.core);
        self.cycles = 0;
        self.halted = self.core.stopped;
    }

    pub fn step(self: *Cpu, bus: *Bus) void {
        _ = trace_enabled;
        if (self.halted) return;

        active_bus = bus;
        c.m68k_step(&self.core);

        // Keep the existing external contract where this advances once per step.
        self.cycles += 1;
        self.halted = self.core.stopped;
    }

    pub fn requestInterrupt(self: *Cpu, level: u3) void {
        c.m68k_set_irq(&self.core, @intCast(level));
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
