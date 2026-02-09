const std = @import("std");
const Cpu = @import("../cpu.zig").Cpu;
const Bus = @import("../../../memory.zig").Bus;

pub fn execBit2(self: *Cpu, opcode: u16, bus: *Bus) void {
    // MOVE.l (Long)
    // Opcode: 0010 (2) RRR MMM MMM RRR
    // Dest Reg (9-11), Dest Mode (6-8), Src Mode (3-5), Src Reg (0-2)

    const dest_reg = @as(u4, @intCast((opcode >> 9) & 0x7));
    const dest_mode = @as(u4, @intCast((opcode >> 6) & 0x7));
    const src_mode = @as(u4, @intCast((opcode >> 3) & 0x7));
    const src_reg = @as(u4, @intCast(opcode & 0x7));

    // Source
    var val: u32 = 0;

    if (src_mode == 0) { // Dn
        val = self.d[src_reg];
        self.cycles += 4;
    } else if (src_mode == 1) { // An
        val = self.a[src_reg];
        self.cycles += 4;
    } else if (src_mode == 2) { // (An)
        const addr = self.a[src_reg];
        val = bus.read32(addr);
        self.cycles += 12;
    } else if (src_mode == 3) { // (An)+
        const addr = self.a[src_reg];
        val = bus.read32(addr);
        self.a[src_reg] +%= 4;
        self.cycles += 12;
    } else if (src_mode == 4) { // -(An)
        self.a[src_reg] -%= 4;
        const addr = self.a[src_reg];
        val = bus.read32(addr);
        self.cycles += 14;
    } else if (src_mode == 5) { // (d16, An)
        const disp = @as(i16, @bitCast(self.fetch16(bus)));
        const addr = self.a[src_reg] +% @as(u32, @bitCast(@as(i32, disp)));
        val = bus.read32(addr);
        self.cycles += 16;
    } else if (src_mode == 7 and src_reg == 1) { // Abs.L
        const addr = self.fetch32(bus);
        val = bus.read32(addr);
        self.cycles += 16;
    } else if (src_mode == 7 and src_reg == 4) { // Immediate
        val = self.fetch32(bus);
        self.cycles += 12;
    } else if (src_mode == 7 and src_reg == 2) { // PC+d16
        const disp = @as(i16, @bitCast(self.fetch16(bus)));
        const addr = (self.pc - 2) +% @as(u32, @bitCast(@as(i32, disp)));
        val = bus.read32(addr);
        self.cycles += 16;
    } else if (src_mode == 7 and src_reg == 3) { // PC+d8+Xn
        const addr = self.calcIndexAddress(bus, self.pc - 2);
        val = bus.read32(addr);
        self.cycles += 16;
    } else if (src_mode == 6) { // (d8, An, Xn)
        const addr = self.calcIndexAddress(bus, self.a[src_reg]);
        val = bus.read32(addr);
        self.cycles += 16;
    } else if (src_mode == 7 and src_reg == 0) { // Abs.W
        const w = self.fetch16(bus);
        const addr = @as(u32, @bitCast(@as(i32, @as(i16, @bitCast(w)))));
        val = bus.read32(addr);
        self.cycles += 16;
    } else {
        std.debug.print("Unimplemented MOVE.l Source Mode {d} Reg {d}\n", .{ src_mode, src_reg });
        return;
    }

    // Check Dest Mode 0 (Data Register Direct)
    if (dest_mode == 0) {
        self.d[dest_reg] = val;
        self.cycles += 4;
    } else if (dest_mode == 1) {
        // MOVE to An affects no flags
        self.a[dest_reg] = val;
        self.cycles += 4;
        return;
    } else if (dest_mode == 2) {
        const addr = self.a[dest_reg];
        bus.write32(addr, val);
        self.cycles += 12;
    } else if (dest_mode == 3) {
        const addr = self.a[dest_reg];
        bus.write32(addr, val);
        self.a[dest_reg] +%= 4;
        self.cycles += 12;
    } else if (dest_mode == 4) { // -(An)
        self.a[dest_reg] -%= 4;
        const addr = self.a[dest_reg];
        bus.write32(addr, val);
        self.cycles += 14;
    } else if (dest_mode == 5) { // (d16, An)
        const disp = @as(i16, @bitCast(self.fetch16(bus)));
        const addr = self.a[dest_reg] +% @as(u32, @bitCast(@as(i32, disp)));
        bus.write32(addr, val);
        self.cycles += 16;
    } else if (dest_mode == 7 and dest_reg == 1) { // Abs.L
        const addr = self.fetch32(bus);
        bus.write32(addr, val);
        self.cycles += 16;
    } else if (dest_mode == 7 and dest_reg == 0) { // Abs.W
        const w = self.fetch16(bus);
        const addr = @as(u32, @bitCast(@as(i32, @as(i16, @bitCast(w)))));
        bus.write32(addr, val);
        self.cycles += 16;
    } else if (dest_mode == 6) { // (d8, An, Xn)
        const addr = self.calcIndexAddress(bus, self.a[dest_reg]);
        bus.write32(addr, val);
        self.cycles += 16;
    } else {
        std.debug.print("Unimplemented MOVE.l Dest Mode {d} Reg {d}\n", .{ dest_mode, dest_reg });
        return;
    }

    // MOVE updates N and Z, clears V and C
    self.updateN(val, 4);
    self.updateZ(val, 4);
    self.sr &= 0xFFFE; // Clear C
    self.sr &= 0xFFFD; // Clear V
    return;
}
