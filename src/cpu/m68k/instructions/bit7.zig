const std = @import("std");
const Cpu = @import("../cpu.zig").Cpu;
const Bus = @import("../../../memory.zig").Bus;

pub fn execBit7(self: *Cpu, opcode: u16, bus: *Bus) void {
    _ = bus;
    // MOVEQ: 0111 RRRo DDDDDDDD
    // Data is 8-bit sign extended to 32-bit
    const reg = (opcode >> 9) & 0x7;
    const data = @as(i8, @bitCast(@as(u8, @intCast(opcode & 0xFF))));

    self.d[reg] = @as(u32, @bitCast(@as(i32, data)));

    self.updateN(self.d[reg], 4);
    self.updateZ(self.d[reg], 4);
    self.sr &= 0xFFFE; // Clear C
    self.sr &= 0xFFFD; // Clear V
    self.cycles += 4;
}
