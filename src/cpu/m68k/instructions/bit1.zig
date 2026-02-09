const std = @import("std");
const Cpu = @import("../cpu.zig").Cpu;
const Bus = @import("../../../memory.zig").Bus;

pub fn execBit1(self: *Cpu, opcode: u16, bus: *Bus) void {
    // MOVE.b (Byte)
    // Opcode: 0001 (1) DDD MMM MMM SSS
    // Dest Reg (9-11), Dest Mode (6-8), Src Mode (3-5), Src Reg (0-2)

    const dest_reg = @as(u4, @intCast((opcode >> 9) & 0x7));
    const dest_mode = @as(u4, @intCast((opcode >> 6) & 0x7));
    const src_mode = @as(u4, @intCast((opcode >> 3) & 0x7));
    const src_reg = @as(u4, @intCast(opcode & 0x7));

    // Source
    var val: u8 = 0;

    // Source Mode 7 (000 = Abs.W, 001 = Abs.L, 010 = PC+d16, ...)
    if (src_mode == 0) { // Dn
        val = @as(u8, @truncate(self.d[src_reg]));
        self.cycles += 4;
    } else if (src_mode == 1) { // An (Valid for Source)
        val = @as(u8, @truncate(self.a[src_reg])); // Low byte
        self.cycles += 4;
    } else if (src_mode == 2) { // (An)
        const addr = self.a[src_reg];
        val = bus.read8(addr);
        self.cycles += 8;
    } else if (src_mode == 3) { // (An)+
        const addr = self.a[src_reg];
        val = bus.read8(addr);
        self.a[src_reg] +%= if (src_reg == 7) 2 else 1; // A7 keeps stack aligned? Byte ops on A7 +/- 2.
        self.cycles += 8; // Std says 8?
    } else if (src_mode == 4) { // -(An)
        const dec_amount: u32 = if (src_reg == 7) 2 else 1;
        self.a[src_reg] -%= dec_amount;
        const addr = self.a[src_reg];
        val = bus.read8(addr);
        self.cycles += 10;
    } else if (src_mode == 5) { // (d16, An)
        const disp = @as(i16, @bitCast(self.fetch16(bus)));
        const addr = self.a[src_reg] +% @as(u32, @bitCast(@as(i32, disp)));
        val = bus.read8(addr);
        self.cycles += 12;
    } else if (src_mode == 7) {
        // Abs.L (001) -> Reg 1
        if (src_reg == 1) {
            const addr = self.fetch32(bus);
            val = bus.read8(addr);
            self.cycles += 12; // Base
        } else if (src_reg == 2) { // PC+d16
            const disp = @as(i16, @bitCast(self.fetch16(bus)));
            const addr = (self.pc - 2) +% @as(u32, @bitCast(@as(i32, disp)));
            val = bus.read8(addr);
            self.cycles += 12;
        } else if (src_reg == 4) { // Immediate
            val = @as(u8, @truncate(self.fetch16(bus)));
            self.cycles += 8;
        } else if (src_reg == 0) { // Abs.W
            const w = self.fetch16(bus);
            const addr = @as(u32, @bitCast(@as(i32, @as(i16, @bitCast(w)))));
            val = bus.read8(addr);
            self.cycles += 12;
        } else if (src_reg == 3) { // PC+d8+Xn
            const addr = self.calcIndexAddress(bus, self.pc - 2);
            val = bus.read8(addr);
            self.cycles += 12;
        } else {
            std.debug.print("Unimplemented MOVE.b Source Mode 7 Reg {d}\n", .{src_reg});
            return;
        }
    } else if (src_mode == 6) { // (d8, An, Xn)
        const addr = self.calcIndexAddress(bus, self.a[src_reg]);
        val = bus.read8(addr);
        self.cycles += 12; // Base + 2 approx
    } else {
        std.debug.print("Unimplemented MOVE.b Source Mode {d}\n", .{src_mode});
        return;
    }

    // Dest Mode 0 (Dn)
    if (dest_mode == 0) {
        self.d[dest_reg] = (self.d[dest_reg] & 0xFFFFFF00) | val;
    } else if (dest_mode == 1) { // An (Dest) -> MOVEA? No, byte move to Ax is not allowed (encodable but usually invalid/reserved or ignored?).
        // M68k: "Destination ... Data Register, Address Register (Word/Long only)..."
        // Byte to Address Register is INVALID.
        // But let's check if Genesis games use it for side effects? Unlikely.
        // Treat as NOP or unimpl?
        std.debug.print("Invalid MOVE.b Dest An Reg {d}\n", .{dest_reg});
        return;
    } else if (dest_mode == 2) { // (An)
        const addr = self.a[dest_reg];
        bus.write8(addr, val);
        self.cycles += 8;
    } else if (dest_mode == 3) { // (An)+
        const addr = self.a[dest_reg];
        bus.write8(addr, val);
        self.a[dest_reg] +%= if (dest_reg == 7) 2 else 1;
        self.cycles += 8;
    } else if (dest_mode == 4) { // -(An)
        const dec_amount: u32 = if (dest_reg == 7) 2 else 1;
        self.a[dest_reg] -%= dec_amount;
        const addr = self.a[dest_reg];
        bus.write8(addr, val);
        self.cycles += 10;
    } else if (dest_mode == 5) { // (d16, An)
        const disp = @as(i16, @bitCast(self.fetch16(bus)));
        const addr = self.a[dest_reg] +% @as(u32, @bitCast(@as(i32, disp)));
        bus.write8(addr, val);
        self.cycles += 12;
    } else if (dest_mode == 7 and dest_reg == 1) { // Abs.L
        const addr = self.fetch32(bus);
        bus.write8(addr, val);
        self.cycles += 12;
    } else if (dest_mode == 7 and dest_reg == 0) { // Abs.W
        const w = self.fetch16(bus);
        const addr = @as(u32, @bitCast(@as(i32, @as(i16, @bitCast(w)))));
        bus.write8(addr, val);
        self.cycles += 12;
    } else if (dest_mode == 6) { // (d8, An, Xn)
        const addr = self.calcIndexAddress(bus, self.a[dest_reg]);
        bus.write8(addr, val);
        self.cycles += 12;
    } else {
        std.debug.print("Unimplemented MOVE.b Dest Mode {d}\n", .{dest_mode});
        return;
    }

    // Status Flags
    self.updateN(val, 1);
    self.updateZ(val, 1);
    self.sr &= 0xFFFE; // Clear C
    self.sr &= 0xFFFD; // Clear V
}
