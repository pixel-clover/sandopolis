const std = @import("std");
const Cpu = @import("../cpu.zig").Cpu;
const Bus = @import("../../../memory.zig").Bus;

pub fn execBitC(self: *Cpu, opcode: u16, bus: *Bus) void {
    // AND / MULU / MULS / ABCD / EXG
    // AND: 1100 ...
    const reg_idx: u4 = @intCast((opcode >> 9) & 0x7);
    const op_mode: u3 = @intCast((opcode >> 6) & 0x7);
    const ea_reg: u4 = @intCast(opcode & 0x7);
    const ea_mode: u4 = @intCast((opcode >> 3) & 0x7);

    // MULU: 1100 Dn 011 EA (opmode = 3) - Unsigned multiply
    // MULS: 1100 Dn 111 EA (opmode = 7) - Signed multiply
    if (op_mode == 3 or op_mode == 7) {
        const is_signed = (op_mode == 7);
        var src_val: u16 = 0;

        // Read source operand (word)
        if (ea_mode == 0) { // Dn
            src_val = @as(u16, @truncate(self.d[ea_reg]));
            self.cycles += 38; // Base cycles
        } else if (ea_mode == 7 and ea_reg == 4) { // Immediate
            src_val = self.fetch16(bus);
            self.cycles += 38;
        } else if (ea_mode == 2) { // (An)
            const addr = self.a[ea_reg];
            src_val = bus.read16(addr);
            self.cycles += 42;
        } else {
            std.debug.print("Unimplemented MUL EA mode {d}\n", .{ea_mode});
            return;
        }

        const dest_val = @as(u16, @truncate(self.d[reg_idx]));
        var result: u32 = 0;

        if (is_signed) {
            // Signed multiply
            const s_src = @as(i16, @bitCast(src_val));
            const s_dest = @as(i16, @bitCast(dest_val));
            const s_result = @as(i32, s_src) * @as(i32, s_dest);
            result = @as(u32, @bitCast(s_result));
        } else {
            // Unsigned multiply
            result = @as(u32, src_val) * @as(u32, dest_val);
        }

        self.d[reg_idx] = result;

        // Set flags
        self.updateN(result, 4);
        self.updateZ(result, 4);
        self.sr &= 0xFFFE; // Clear C
        self.sr &= 0xFFFD; // Clear V

        return;
    }

    // EXG: 1100 Rx 1 opmode Ry
    // opmode: 01000 = data regs, 01001 = addr regs, 10001 = data/addr
    if ((opcode & 0xF130) == 0xC100) {
        const rx = (opcode >> 9) & 0x7;
        const opmode = (opcode >> 3) & 0x1F;
        const ry = opcode & 0x7;

        if (opmode == 0x08) { // Exchange data registers
            const temp = self.d[rx];
            self.d[rx] = self.d[ry];
            self.d[ry] = temp;
            self.cycles += 6;
            return;
        } else if (opmode == 0x09) { // Exchange address registers
            const temp = self.a[rx];
            self.a[rx] = self.a[ry];
            self.a[ry] = temp;
            self.cycles += 6;
            return;
        } else if (opmode == 0x11) { // Exchange data and address
            const temp = self.d[rx];
            self.d[rx] = self.a[ry];
            self.a[ry] = temp;
            self.cycles += 6;
            return;
        }
    }

    if (ea_mode == 0 and op_mode <= 2) {
        const src_val = self.d[ea_reg];
        const dest_val = self.d[reg_idx];
        var result: u32 = 0;

        if (op_mode == 0) { // Byte
            const val8 = @as(u8, @truncate(src_val)) & @as(u8, @truncate(dest_val));
            result = (dest_val & 0xFFFFFF00) | val8;
            self.updateN(val8, 1);
            self.updateZ(val8, 1);
        } else if (op_mode == 1) { // Word
            const val16 = @as(u16, @truncate(src_val)) & @as(u16, @truncate(dest_val));
            result = (dest_val & 0xFFFF0000) | val16;
            self.updateN(val16, 2);
            self.updateZ(val16, 2);
        } else { // Long
            result = src_val & dest_val;
            self.updateN(result, 4);
            self.updateZ(result, 4);
        }

        // Clear V, C
        self.sr &= 0xFFFE;
        self.sr &= 0xFFFD;

        self.d[reg_idx] = result;
        self.cycles += 4;
        return;
    }
    // ABCD: 1100 Rx 1000 00 M Ry
    // 0xC100 masking
    // Rx = Dest, Ry = Src
    if ((opcode & 0xF1F0) == 0xC100) {
        const rx = (opcode >> 9) & 0x7;
        const ry = opcode & 0x7;
        const mem = ((opcode >> 3) & 1) == 1;

        const x_bit = (self.sr >> 4) & 1;
        var src_val: u8 = 0;
        var dest_val: u8 = 0;

        if (mem) {
            // -(Ax), -(Ay)
            self.a[ry] -%= 1;
            if (ry == 7) self.a[ry] -%= 1;
            src_val = bus.read8(self.a[ry]);

            self.a[rx] -%= 1;
            if (rx == 7) self.a[rx] -%= 1;
            dest_val = bus.read8(self.a[rx]);
        } else {
            // Dx, Dy
            src_val = @as(u8, @truncate(self.d[ry]));
            dest_val = @as(u8, @truncate(self.d[rx]));
        }

        // BCD Addition
        var res = @as(u16, src_val) + @as(u16, dest_val) + x_bit;
        var bcd_carry: u1 = 0;

        if ((src_val & 0xF) + (dest_val & 0xF) + x_bit > 9) {
            res += 6;
        }
        if (res > 0x9F) {
            res += 0x60;
            bcd_carry = 1;
        }

        const result8 = @as(u8, @truncate(res));

        // Write back
        if (mem) {
            bus.write8(self.a[rx], result8);
            self.cycles += 18;
        } else {
            self.d[rx] = (self.d[rx] & 0xFFFFFF00) | result8;
            self.cycles += 6;
        }

        // Flags
        // const z_cond = ((self.sr >> 2) & 1) == 1 and result8 == 0;
        // C and X are set if decimal carry was generated
        // Z is cleared if result is non-zero, else unchanged
        // N, V undefined

        // Z
        if (result8 != 0) self.sr &= 0xFFFB; // Clear Z
        // If result is 0, Z remains unchanged (usually set before loop)

        // C, X
        if (bcd_carry == 1) self.sr |= 0x0011 else self.sr &= 0xFFEE;

        return;
    }

    std.debug.print("Unimplemented Opcode (Bit C): {X:0>4} at PC: {X:0>8}\n", .{ opcode, self.pc - 2 });
}
