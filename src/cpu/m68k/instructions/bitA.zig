const std = @import("std");
const Cpu = @import("../cpu.zig").Cpu;
const Bus = @import("../../../memory.zig").Bus;

pub fn execBitA(self: *Cpu, opcode: u16, bus: *Bus) void {
    _ = bus;
    std.debug.print("Unimplemented Opcode (Bit A): {X:0>4} at PC: {X:0>8}\n", .{ opcode, self.pc - 2 });
}
