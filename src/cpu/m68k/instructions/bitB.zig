const std = @import("std");
const Cpu = @import("../cpu.zig").Cpu;
const Bus = @import("../../../memory.zig").Bus;

pub fn execBitB(self: *Cpu, opcode: u16, bus: *Bus) void {
    // CMP/CMPA/CMPM/EOR
    // CMP: 1011 Reg OpMode EA
    // CMPA: 1011 Reg 0xx011/111 EA (word/long)
    // EOR: 1011 Reg 1xx EA (to memory/data)

    const reg_idx = @as(u3, @intCast((opcode >> 9) & 0x7));
    const opmode = @as(u3, @intCast((opcode >> 6) & 0x7));
    const ea_mode = @as(u3, @intCast((opcode >> 3) & 0x7));
    const ea_reg = @as(u3, @intCast(opcode & 0x7));

    // Check for CMPA: opmode = 011 (word) or 111 (long)
    if (opmode == 3 or opmode == 7) {
        // CMPA <ea>, An
        const size_long = (opmode == 7);
        var src_val: u32 = 0;

        // Read source operand
        if (ea_mode == 0) { // Dn
            src_val = if (size_long) self.d[ea_reg] else @as(u32, @bitCast(@as(i32, @as(i16, @bitCast(@as(u16, @truncate(self.d[ea_reg])))))));
            self.cycles += 6;
        } else if (ea_mode == 1) { // An
            src_val = if (size_long) self.a[ea_reg] else @as(u32, @bitCast(@as(i32, @as(i16, @bitCast(@as(u16, @truncate(self.a[ea_reg])))))));
            self.cycles += 6;
        } else if (ea_mode == 7 and ea_reg == 4) { // Immediate
            if (size_long) {
                src_val = self.fetch32(bus);
            } else {
                const word_val = self.fetch16(bus);
                src_val = @as(u32, @bitCast(@as(i32, @as(i16, @bitCast(word_val)))));
            }
            self.cycles += if (size_long) 14 else 8;
        } else if (ea_mode == 2) { // (An)
            const addr = self.a[ea_reg];
            if (size_long) {
                src_val = bus.read32(addr);
                self.cycles += 14;
            } else {
                const word_val = bus.read16(addr);
                src_val = @as(u32, @bitCast(@as(i32, @as(i16, @bitCast(word_val)))));
                self.cycles += 10;
            }
        } else {
            self.trapUnimplemented(opcode);
            return;
        }

        const dest_val = self.a[reg_idx];
        const result = dest_val -% src_val;

        // Set flags (compare is subtraction without storing)
        self.updateFlagsSub(dest_val, src_val, result, 4);
        return;
    }

    // Check for EOR: opmode = 1xx (bit 8 set)
    if ((opmode & 0x4) != 0) {
        // EOR Dn, <ea>
        const size = opmode & 0x3;
        if (size == 3) {
            self.trapUnimplemented(opcode);
            return;
        }

        // const size_bytes: u8 = if (size == 0) 1 else if (size == 1) 2 else 4; // Unused

        // Source is always Dn
        const src_val = self.d[reg_idx];

        if (ea_mode == 0) { // EOR Dn, Dm
            const dest_val = self.d[ea_reg];
            var result: u32 = 0;

            if (size == 0) { // Byte
                const res8 = @as(u8, @truncate(src_val)) ^ @as(u8, @truncate(dest_val));
                result = (dest_val & 0xFFFFFF00) | res8;
                self.updateN(res8, 1);
                self.updateZ(res8, 1);
            } else if (size == 1) { // Word
                const res16 = @as(u16, @truncate(src_val)) ^ @as(u16, @truncate(dest_val));
                result = (dest_val & 0xFFFF0000) | res16;
                self.updateN(res16, 2);
                self.updateZ(res16, 2);
            } else { // Long
                result = src_val ^ dest_val;
                self.updateN(result, 4);
                self.updateZ(result, 4);
            }

            self.sr &= 0xFFFE; // Clear C
            self.sr &= 0xFFFD; // Clear V
            self.d[ea_reg] = result;
            self.cycles += if (size == 2) 8 else 4;
            return;
        } else {
            // EOR supports Data Alterable addressing modes
            // (An) (Mode 2), (An)+ (Mode 3), -(An) (Mode 4), (d16,An) (Mode 5), (d8,An,Xn) (Mode 6)
            // Abs.W (Mode 7 Reg 0), Abs.L (Mode 7 Reg 1)

            var addr: u32 = 0;
            var valid = true;

            if (ea_mode == 2) {
                addr = self.a[ea_reg];
            } else if (ea_mode == 3) {
                addr = self.a[ea_reg];
                const inc = @as(u32, if (size == 0 and ea_reg == 7) 2 else if (size == 0) 1 else if (size == 1) 2 else 4);
                self.a[ea_reg] +%= inc;
            } else if (ea_mode == 4) {
                const dec = @as(u32, if (size == 0 and ea_reg == 7) 2 else if (size == 0) 1 else if (size == 1) 2 else 4);
                self.a[ea_reg] -%= dec;
                addr = self.a[ea_reg];
            } else if (ea_mode == 5) {
                const disp = @as(i16, @bitCast(self.fetch16(bus)));
                addr = self.a[ea_reg] +% @as(u32, @bitCast(@as(i32, disp)));
            } else if (ea_mode == 6) {
                addr = self.calcIndexAddress(bus, self.a[ea_reg]);
            } else if (ea_mode == 7) {
                if (ea_reg == 0) { // Abs.W
                    const w = self.fetch16(bus);
                    addr = @as(u32, @bitCast(@as(i32, @as(i16, @bitCast(w)))));
                } else if (ea_reg == 1) { // Abs.L
                    addr = self.fetch32(bus);
                } else {
                    valid = false;
                }
            } else {
                valid = false;
            }

            if (!valid) {
                self.trapUnimplemented(opcode);
                return;
            }

            // Read-Modify-Write
            if (size == 0) { // Byte
                const mem_val = bus.read8(addr);
                const result = @as(u8, @truncate(src_val)) ^ mem_val;
                bus.write8(addr, result);
                self.updateN(result, 1);
                self.updateZ(result, 1);
                self.cycles += 12;
            } else if (size == 1) { // Word
                const mem_val = bus.read16(addr);
                const result = @as(u16, @truncate(src_val)) ^ mem_val;
                bus.write16(addr, result);
                self.updateN(result, 2);
                self.updateZ(result, 2);
                self.cycles += 12;
            } else { // Long
                const mem_val = bus.read32(addr);
                const result = src_val ^ mem_val;
                bus.write32(addr, result);
                self.updateN(result, 4);
                self.updateZ(result, 4);
                self.cycles += 20;
            }

            self.sr &= 0xFFFE; // Clear C
            self.sr &= 0xFFFD; // Clear V
            return;
        }
    }

    // CMP <ea>, Dn
    const size = opmode & 0x3;
    if (size == 3) {
        self.trapUnimplemented(opcode);
        return;
    }

    var src_val: u32 = 0;

    // Read source operand
    if (ea_mode == 0) { // Dn
        src_val = self.d[ea_reg];
        self.cycles += if (size == 2) 6 else 4;
    } else if (ea_mode == 1) { // An
        src_val = self.a[ea_reg];
        self.cycles += if (size == 2) 6 else 4;
    } else if (ea_mode == 7 and ea_reg == 4) { // Immediate
        if (size == 0) {
            src_val = self.fetch16(bus) & 0xFF;
            self.cycles += 8;
        } else if (size == 1) {
            src_val = self.fetch16(bus);
            self.cycles += 8;
        } else {
            src_val = self.fetch32(bus);
            self.cycles += 12;
        }
    } else if (ea_mode == 2) { // (An)
        const addr = self.a[ea_reg];
        if (size == 0) {
            src_val = bus.read8(addr);
            self.cycles += 8;
        } else if (size == 1) {
            src_val = bus.read16(addr);
            self.cycles += 8;
        } else {
            src_val = bus.read32(addr);
            self.cycles += 14;
        }
    } else if (ea_mode == 3) { // (An)+
        const addr = self.a[ea_reg];
        if (size == 0) {
            src_val = bus.read8(addr);
            self.a[ea_reg] +%= if (ea_reg == 7) 2 else 1;
            self.cycles += 8;
        } else if (size == 1) {
            src_val = bus.read16(addr);
            self.a[ea_reg] +%= 2;
            self.cycles += 8;
        } else {
            src_val = bus.read32(addr);
            self.a[ea_reg] +%= 4;
            self.cycles += 14;
        }
    } else if (ea_mode == 4) { // -(An)
        if (size == 0) {
            self.a[ea_reg] -%= if (ea_reg == 7) 2 else 1;
            src_val = bus.read8(self.a[ea_reg]);
            self.cycles += 10;
        } else if (size == 1) {
            self.a[ea_reg] -%= 2;
            src_val = bus.read16(self.a[ea_reg]);
            self.cycles += 10;
        } else {
            self.a[ea_reg] -%= 4;
            src_val = bus.read32(self.a[ea_reg]);
            self.cycles += 16;
        }
    } else if (ea_mode == 5) { // (d16, An)
        const disp = @as(i16, @bitCast(self.fetch16(bus)));
        const addr = self.a[ea_reg] +% @as(u32, @bitCast(@as(i32, disp)));
        if (size == 0) {
            src_val = bus.read8(addr);
            self.cycles += 12;
        } else if (size == 1) {
            src_val = bus.read16(addr);
            self.cycles += 12;
        } else {
            src_val = bus.read32(addr);
            self.cycles += 18;
        }
    } else if (ea_mode == 6) { // (d8, An, Xn)
        const addr = self.calcIndexAddress(bus, self.a[ea_reg]);
        if (size == 0) {
            src_val = bus.read8(addr);
            self.cycles += 14;
        } else if (size == 1) {
            src_val = bus.read16(addr);
            self.cycles += 14;
        } else {
            src_val = bus.read32(addr);
            self.cycles += 20;
        }
    } else if (ea_mode == 7) {
        var addr: u32 = 0;
        if (ea_reg == 0) { // Abs.W
            const w = self.fetch16(bus);
            addr = @as(u32, @bitCast(@as(i32, @as(i16, @bitCast(w)))));
            self.cycles += if (size == 2) 18 else 12;
        } else if (ea_reg == 1) { // Abs.L
            addr = self.fetch32(bus);
            self.cycles += if (size == 2) 22 else 16;
        } else if (ea_reg == 2) { // PC+d16
            const disp = @as(i16, @bitCast(self.fetch16(bus)));
            addr = (self.pc - 2) +% @as(u32, @bitCast(@as(i32, disp)));
            self.cycles += if (size == 2) 18 else 12;
        } else if (ea_reg == 3) { // PC+d8+Xn
            addr = self.calcIndexAddress(bus, self.pc - 2);
            self.cycles += if (size == 2) 20 else 14;
        } else if (ea_reg == 4) { // Immediate
            if (size == 0) {
                src_val = self.fetch16(bus) & 0xFF;
                self.cycles += 8;
            } else if (size == 1) {
                src_val = self.fetch16(bus);
                self.cycles += 8;
            } else {
                src_val = self.fetch32(bus);
                self.cycles += 12;
            }
            // Imm logic already assigned src_val, skip memory read
            // Wait, logic flow is a bit split here.
            // Let's just return to main flow for Imm, others read from addr.
        } else {
            self.trapUnimplemented(opcode);
            return;
        }

        if (ea_reg != 4) { // If not Immediate, read memory
            if (size == 0) {
                src_val = bus.read8(addr);
            } else if (size == 1) {
                src_val = bus.read16(addr);
            } else {
                src_val = bus.read32(addr);
            }
        }
    } else {
        self.trapUnimplemented(opcode);
        return;
    }

    const dest_val = self.d[reg_idx];
    var result: u32 = 0;

    if (size == 0) { // Byte
        const d = @as(u8, @truncate(dest_val));
        const s = @as(u8, @truncate(src_val));
        result = d -% s;
        self.updateFlagsSub(d, s, @as(u8, @truncate(result)), 1);
    } else if (size == 1) { // Word
        const d = @as(u16, @truncate(dest_val));
        const s = @as(u16, @truncate(src_val));
        result = d -% s;
        self.updateFlagsSub(d, s, @as(u16, @truncate(result)), 2);
    } else { // Long
        result = dest_val -% src_val;
        self.updateFlagsSub(dest_val, src_val, result, 4);
    }
}
