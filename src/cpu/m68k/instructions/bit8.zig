const std = @import("std");
const Cpu = @import("../cpu.zig").Cpu;
const Bus = @import("../../../memory.zig").Bus;

pub fn execBit8(self: *Cpu, opcode: u16, bus: *Bus) void {
    // OR / DIVU / DIVS / SBCD
    // OR: 1000 Reg OpMode EA
    // DIVU: 1000 Dn 011 EA (opmode = 3) - Unsigned divide
    // DIVS: 1000 Dn 111 EA (opmode = 7) - Signed divide
    const reg_idx: u4 = @intCast((opcode >> 9) & 0x7);
    const op_mode: u3 = @intCast((opcode >> 6) & 0x7);
    const ea_reg: u4 = @intCast(opcode & 0x7);
    const ea_mode: u4 = @intCast((opcode >> 3) & 0x7);

    // DIVU: 1000 Dn 011 EA - Unsigned divide
    // DIVS: 1000 Dn 111 EA - Signed divide
    if (op_mode == 3 or op_mode == 7) {
        const is_signed = (op_mode == 7);
        var divisor: u16 = 0;

        // Read divisor (word)
        // Read divisor (word)
        if (ea_mode == 0) { // Dn
            divisor = @as(u16, @truncate(self.d[ea_reg]));
            self.cycles += 76;
        } else if (ea_mode == 2) { // (An)
            const addr = self.a[ea_reg];
            divisor = bus.read16(addr);
            self.cycles += 80;
        } else if (ea_mode == 3) { // (An)+
            const addr = self.a[ea_reg];
            divisor = bus.read16(addr);
            self.a[ea_reg] +%= 2;
            self.cycles += 80;
        } else if (ea_mode == 4) { // -(An)
            self.a[ea_reg] -%= 2;
            const addr = self.a[ea_reg];
            divisor = bus.read16(addr);
            self.cycles += 82;
        } else if (ea_mode == 5) { // (d16, An)
            const disp = @as(i16, @bitCast(self.fetch16(bus)));
            const addr = self.a[ea_reg] +% @as(u32, @bitCast(@as(i32, disp)));
            divisor = bus.read16(addr);
            self.cycles += 84;
        } else if (ea_mode == 6) { // (d8, An, Xn)
            const addr = self.calcIndexAddress(bus, self.a[ea_reg]);
            divisor = bus.read16(addr);
            self.cycles += 86;
        } else if (ea_mode == 7) {
            if (ea_reg == 0) { // Abs.W
                const w = self.fetch16(bus);
                const addr = @as(u32, @bitCast(@as(i32, @as(i16, @bitCast(w)))));
                divisor = bus.read16(addr);
                self.cycles += 84;
            } else if (ea_reg == 1) { // Abs.L
                const addr = self.fetch32(bus);
                divisor = bus.read16(addr);
                self.cycles += 88;
            } else if (ea_reg == 2) { // PC+d16
                const disp = @as(i16, @bitCast(self.fetch16(bus)));
                const addr = (self.pc - 2) +% @as(u32, @bitCast(@as(i32, disp)));
                divisor = bus.read16(addr);
                self.cycles += 84;
            } else if (ea_reg == 3) { // PC+d8+Xn
                const addr = self.calcIndexAddress(bus, self.pc - 2);
                divisor = bus.read16(addr);
                self.cycles += 86;
            } else if (ea_reg == 4) { // Immediate
                divisor = self.fetch16(bus);
                self.cycles += 80;
            } else {
                std.debug.print("Unimplemented DIV EA mode 7 reg {d}\n", .{ea_reg});
                return;
            }
        } else {
            std.debug.print("Unimplemented DIV EA mode {d}\n", .{ea_mode});
            return;
        }

        // Check for division by zero
        if (divisor == 0) {
            // Trigger divide-by-zero exception (vector 5)
            std.debug.print("Division by zero at PC: {X:0>8} Op: {X:0>4} Divisor: {X} Dividend: {X} EA: {d}/{d}\n", .{ self.pc - 2, opcode, divisor, self.d[reg_idx], ea_mode, ea_reg });
            self.triggerException(bus, 5); // Vector 5 = divide by zero
            return;
        }

        const dividend = self.d[reg_idx]; // 32-bit dividend

        if (is_signed) {
            // Signed divide
            const s_dividend = @as(i32, @bitCast(dividend));
            const s_divisor = @as(i32, @as(i16, @bitCast(divisor)));
            const s_quotient = @divTrunc(s_dividend, s_divisor);
            const s_remainder = @rem(s_dividend, s_divisor);

            // Check for overflow (quotient doesn't fit in 16 bits)
            if (s_quotient > 32767 or s_quotient < -32768) {
                // Set overflow flag
                self.sr |= 0x0002; // Set V
                return;
            }

            // Result: lower 16 bits = quotient, upper 16 bits = remainder
            const quotient = @as(u16, @bitCast(@as(i16, @intCast(s_quotient))));
            const remainder = @as(u16, @bitCast(@as(i16, @intCast(s_remainder))));
            self.d[reg_idx] = (@as(u32, remainder) << 16) | quotient;

            // Set flags based on quotient
            self.updateN(quotient, 2);
            self.updateZ(quotient, 2);
        } else {
            // Unsigned divide
            const quotient_32 = dividend / @as(u32, divisor);
            const remainder = dividend % @as(u32, divisor);

            // Check for overflow (quotient doesn't fit in 16 bits)
            if (quotient_32 > 0xFFFF) {
                // Set overflow flag
                self.sr |= 0x0002; // Set V
                return;
            }

            const quotient = @as(u16, @truncate(quotient_32));
            const remainder_16 = @as(u16, @truncate(remainder));

            // Result: lower 16 bits = quotient, upper 16 bits = remainder
            self.d[reg_idx] = (@as(u32, remainder_16) << 16) | quotient;

            // Set flags based on quotient
            self.updateN(quotient, 2);
            self.updateZ(quotient, 2);
        }

        self.sr &= 0xFFFE; // Clear C
        self.sr &= 0xFFFD; // Clear V (if no overflow)
        return;
    }

    // OR instruction
    if (ea_mode == 0 and op_mode <= 2) {
        const src_val = self.d[ea_reg];
        const dest_val = self.d[reg_idx];
        var result: u32 = 0;

        if (op_mode == 0) { // Byte
            const val8 = @as(u8, @truncate(src_val)) | @as(u8, @truncate(dest_val));
            result = (dest_val & 0xFFFFFF00) | val8;
            self.updateN(val8, 1);
            self.updateZ(val8, 1);
        } else if (op_mode == 1) { // Word
            const val16 = @as(u16, @truncate(src_val)) | @as(u16, @truncate(dest_val));
            result = (dest_val & 0xFFFF0000) | val16;
            self.updateN(val16, 2);
            self.updateZ(val16, 2);
        } else { // Long
            result = src_val | dest_val;
            self.updateN(result, 4);
            self.updateZ(result, 4);
        }

        // Clear V, C
        self.sr &= 0xFFFE; // Clear Carry (bit 0)
        self.sr &= 0xFFFD; // Clear Overflow (bit 1)

        self.d[reg_idx] = result;
        self.cycles += 4; // Basic assumption
        return;
    }

    // SBCD: 1000 Rx 1000 00 M Ry
    if ((opcode & 0xF1F0) == 0x8100) {
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

        // BCD Subtraction
        // dest - src - x

        // Re-do with binary

        // const src_x = @as(u16, src_val) + x_bit; // Not used
        var checked_res = @as(i16, @intCast(dest_val)) - @as(i16, @intCast(src_val)) - @as(i16, @intCast(x_bit));
        const bcd_c: u1 = if (checked_res < 0) 1 else 0;

        if ((dest_val & 0xF) < (src_val & 0xF) + x_bit) {
            checked_res -= 6;
        }
        if (bcd_c == 1) {
            checked_res -= 0x60;
        }

        const result8 = @as(u8, @truncate(@as(u16, @bitCast(checked_res))));

        // Write back
        if (mem) {
            bus.write8(self.a[rx], result8);
            self.cycles += 18;
        } else {
            self.d[rx] = (self.d[rx] & 0xFFFFFF00) | result8;
            self.cycles += 6;
        }

        // Z: Cleared if result is non-zero, else unchanged.
        if (result8 != 0) self.sr &= 0xFFFB;

        // C, X
        if (bcd_c == 1) self.sr |= 0x0011 else self.sr &= 0xFFEE;

        return;
    }

    std.debug.print("Unimplemented Opcode (Bit 8 - OR/DIV): {X:0>4} at PC: {X:0>8}\n", .{ opcode, self.pc - 2 });
}
