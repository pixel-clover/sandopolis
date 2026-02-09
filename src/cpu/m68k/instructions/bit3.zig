const std = @import("std");
const Cpu = @import("../cpu.zig").Cpu;
const Bus = @import("../../../memory.zig").Bus;

pub fn execBit3(self: *Cpu, opcode: u16, bus: *Bus) void {
    // MOVE.w (Word)
    // Opcode: 0011 (3) RRR MMM MMM RRR
    // Dest Reg (9-11), Dest Mode (6-8), Src Mode (3-5), Src Reg (0-2)

    const dest_reg = @as(u4, @intCast((opcode >> 9) & 0x7));
    const dest_mode = @as(u4, @intCast((opcode >> 6) & 0x7));
    const src_mode = @as(u4, @intCast((opcode >> 3) & 0x7));
    const src_reg = @as(u4, @intCast(opcode & 0x7));

    var src_val: u16 = 0;

    // 1. Fetch Source
    if (src_mode == 0) { // Dn
        src_val = @intCast(self.d[src_reg] & 0xFFFF);
    } else if (src_mode == 1) { // An
        src_val = @intCast(self.a[src_reg] & 0xFFFF); // Valid? MOVE from An is valid.
    } else if (src_mode == 2) { // (An)
        const addr = self.a[src_reg];
        src_val = bus.read16(addr);
        self.cycles += 4;
    } else if (src_mode == 3) { // (An)+
        const addr = self.a[src_reg];
        src_val = bus.read16(addr);
        self.a[src_reg] +%= 2;
        self.cycles += 4;
    } else if (src_mode == 4) { // -(An)
        self.a[src_reg] -%= 2;
        const addr = self.a[src_reg];
        src_val = bus.read16(addr);
        self.cycles += 6;
    } else if (src_mode == 5) { // (d16, An)
        const disp = @as(i16, @bitCast(self.fetch16(bus)));
        const addr = self.a[src_reg] +% @as(u32, @bitCast(@as(i32, disp)));
        src_val = bus.read16(addr);
        self.cycles += 8;
    } else if (src_mode == 7 and src_reg == 4) { // Immediate
        src_val = self.fetch16(bus);
    } else if (src_mode == 7 and src_reg == 1) { // Abs.L
        const addr = self.fetch32(bus);
        src_val = bus.read16(addr);
        self.cycles += 8;
    } else if (src_mode == 7 and src_reg == 0) { // Abs.W
        const w = self.fetch16(bus);
        const addr = @as(u32, @bitCast(@as(i32, @as(i16, @bitCast(w)))));
        src_val = bus.read16(addr);
        self.cycles += 8;
    } else if (src_mode == 7 and src_reg == 2) { // PC+d16
        const disp = @as(i16, @bitCast(self.fetch16(bus)));
        const addr = (self.pc - 2) +% @as(u32, @bitCast(@as(i32, disp)));
        src_val = bus.read16(addr);
        self.cycles += 8;
    } else if (src_mode == 7 and src_reg == 3) { // PC+d8+Xn
        const addr = self.calcIndexAddress(bus, self.pc - 2);
        src_val = bus.read16(addr);
        self.cycles += 8;
    } else if (src_mode == 6) { // (d8, An, Xn)
        const addr = self.calcIndexAddress(bus, self.a[src_reg]);
        src_val = bus.read16(addr);
        self.cycles += 8;
    } else {
        std.debug.print("Unimplemened Source Mode {d} Reg {d} for MOVE.w at {X:0>8}\n", .{ src_mode, src_reg, self.pc - 2 });
        return;
    }

    // 2. Write Destination
    if (dest_mode == 0) { // Dn
        self.d[dest_reg] = (self.d[dest_reg] & 0xFFFF0000) | src_val;
    } else if (dest_mode == 1) { // An (Destination) - Valid but doesn't affect flags!
        // Move to An (MOVEA)
        self.a[dest_reg] = @as(u32, @bitCast(@as(i32, @as(i16, @bitCast(src_val))))); // Sign extend for Word
        self.cycles += 4;
        return; // No flags update
    } else if (dest_mode == 2) { // (An)
        const addr = self.a[dest_reg];
        bus.write16(addr, src_val);
        self.cycles += 4;
    } else if (dest_mode == 3) { // (An)+
        const addr = self.a[dest_reg];
        bus.write16(addr, src_val);
        self.a[dest_reg] +%= 2;
        self.cycles += 4;
    } else if (dest_mode == 4) { // -(An)
        self.a[dest_reg] -%= 2;
        const addr = self.a[dest_reg];
        bus.write16(addr, src_val);
        self.cycles += 5; // 4 + ?
    } else if (dest_mode == 5) { // (d16, An)
        const disp = @as(i16, @bitCast(self.fetch16(bus)));
        const addr = self.a[dest_reg] +% @as(u32, @bitCast(@as(i32, disp)));
        bus.write16(addr, src_val);
        self.cycles += 8;
    } else if (dest_mode == 7 and dest_reg == 1) { // Abs.L
        const addr = self.fetch32(bus);
        bus.write16(addr, src_val);
        self.cycles += 8;
    } else if (dest_mode == 7 and dest_reg == 0) { // Abs.W
        const w = self.fetch16(bus);
        const addr = @as(u32, @bitCast(@as(i32, @as(i16, @bitCast(w)))));
        bus.write16(addr, src_val);
        self.cycles += 8;
    } else if (dest_mode == 6) { // (d8, An, Xn)
        const addr = self.calcIndexAddress(bus, self.a[dest_reg]);
        bus.write16(addr, src_val);
        self.cycles += 8;
    } else {
        std.debug.print("Unimplemened Dest Mode {d} Reg {d} for MOVE.w at {X:0>8}\n", .{ dest_mode, dest_reg, self.pc - 2 });
        return;
    }

    // Flags (for Register Dest)
    self.updateN(src_val, 2);
    self.updateZ(src_val, 2);
    self.sr &= 0xFFFE;
    self.sr &= 0xFFFD;
    self.cycles += 4;
}
