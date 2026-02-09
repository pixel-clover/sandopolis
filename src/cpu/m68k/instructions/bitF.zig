const std = @import("std");
const Cpu = @import("../cpu.zig").Cpu;
const Bus = @import("../../../memory.zig").Bus;

pub fn execBitF(self: *Cpu, opcode: u16, bus: *Bus) void {
    // Line 1111 Emulator Exception (Vector 11)
    // Used for software emulation of F-Line instructions (FPU, etc.)
    std.debug.print("F-Line Exception at {X:0>8} Op: {X:0>4}\n", .{ self.pc - 2, opcode });
    self.triggerException(bus, 11);
}
