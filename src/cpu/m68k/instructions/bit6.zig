const std = @import("std");
const Cpu = @import("../cpu.zig").Cpu;
const Bus = @import("../../../memory.zig").Bus;

pub fn execBit6(self: *Cpu, opcode: u16, bus: *Bus) void {
    // Bcc / BRA / BSR
    // 0110 cccc disp
    const cond: u4 = @intCast((opcode >> 8) & 0xF);
    const offset8 = @as(i8, @bitCast(@as(u8, @intCast(opcode & 0xFF))));

    // Save PC before fetching extension word
    // PC is already pointing to the word after the opcode at this point
    const base_pc = self.pc;

    var displacement: i32 = 0;
    var fetched_extension = false;

    if (offset8 == 0) {
        // 16-bit displacement - fetch extension word
        const disp16 = self.fetch16(bus);
        displacement = @as(i16, @bitCast(disp16));
        fetched_extension = true;
    } else {
        // 8-bit displacement in the opcode
        displacement = offset8;
    }

    // PC-relative: displacement is added to the PC value BEFORE fetching extension word
    // This is the address of the word after the opcode (base_pc)
    const target_pc = base_pc +% @as(u32, @bitCast(displacement));

    // Check specific cases using 'cond'
    // 0000 -> BRA (True)
    // 0001 -> BSR

    if (cond == 0) { // BRA
        self.pc = target_pc;
        self.cycles += 10;
        return;
    }

    if (cond == 1) { // BSR
        // Push PC (address of instruction *after* this one)
        // Address after strict instruction logic:
        // If byte disp: Inst+2
        // If word disp: Inst+4
        // self.pc is already pointing there!
        self.push32(bus, self.pc);
        self.pc = target_pc;
        self.cycles += 18;
        return;
    }

    // Bcc
    if (self.checkCondition(cond)) {
        self.pc = target_pc;
        self.cycles += 10; // Branch Taken
    } else {
        // Branch Not Taken: PC is already at next instruction (self.pc)
        if (fetched_extension) {
            self.cycles += 12; // Not taken with extension word
        } else {
            self.cycles += 8; // Not taken, 8-bit displacement
        }
    }
}
