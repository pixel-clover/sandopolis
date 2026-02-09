const std = @import("std");
const Cpu = @import("../cpu.zig").Cpu;
const Bus = @import("../../../memory.zig").Bus;

pub fn execBit0(self: *Cpu, opcode: u16, bus: *Bus) void {
    // ANDI / ORI / EORI / CMPI / BCHG / BCLR / BSET / BTST
    // Logic Ops: 0000 xxx0 sz EA
    // ANDI: 0010 (2)
    // ORI:  0000 (0)
    // EORI: 1010 (A)
    // CMPI: 1100 (C)

    // ANDI to CCR: 0000 0010 0011 1100 (0x023C)
    if (opcode == 0x023C) {
        const imm = @as(u8, @truncate(self.fetch16(bus)));
        const ccr = @as(u8, @truncate(self.sr));
        self.sr = (self.sr & 0xFF00) | (ccr & imm);
        self.cycles += 20;
        return;
    }

    // ANDI to SR: 0000 0010 0111 1100 (0x027C)
    if (opcode == 0x027C) {
        // Check supervisor mode
        if ((self.sr & 0x2000) == 0) {
            // Privilege violation
            std.debug.print("ANDI to SR in user mode at PC: {X:0>8}\n", .{self.pc - 2});
            return;
        }
        const imm = self.fetch16(bus);
        self.sr &= imm;
        self.cycles += 20;
        return;
    }

    // ORI to CCR: 0000 0000 0011 1100 (0x003C)
    if (opcode == 0x003C) {
        const imm = @as(u8, @truncate(self.fetch16(bus)));
        const ccr = @as(u8, @truncate(self.sr));
        self.sr = (self.sr & 0xFF00) | (ccr | imm);
        self.cycles += 20;
        return;
    }

    // ORI to SR: 0000 0000 0111 1100 (0x007C)
    if (opcode == 0x007C) {
        // Check supervisor mode
        if ((self.sr & 0x2000) == 0) {
            // Privilege violation
            std.debug.print("ORI to SR in user mode at PC: {X:0>8}\n", .{self.pc - 2});
            return;
        }
        const imm = self.fetch16(bus);
        self.sr |= imm;
        self.cycles += 20;
        return;
    }

    // EORI to CCR: 0000 1010 0011 1100 (0x0A3C)
    if (opcode == 0x0A3C) {
        const imm = @as(u8, @truncate(self.fetch16(bus)));
        const ccr = @as(u8, @truncate(self.sr));
        self.sr = (self.sr & 0xFF00) | (ccr ^ imm);
        self.cycles += 20;
        return;
    }

    // EORI to SR: 0000 1010 0111 1100 (0x0A7C)
    if (opcode == 0x0A7C) {
        // Check supervisor mode
        if ((self.sr & 0x2000) == 0) {
            // Privilege violation
            std.debug.print("EORI to SR in user mode at PC: {X:0>8}\n", .{self.pc - 2});
            return;
        }
        const imm = self.fetch16(bus);
        self.sr ^= imm;
        self.cycles += 20;
        return;
    }

    const type_byte = (opcode >> 8) & 0xFF;

    if (type_byte == 0x00 or type_byte == 0x02 or type_byte == 0x0A or type_byte == 0x0C) {
        const size_bits = (opcode >> 6) & 0x3;
        const ea_mode = (opcode >> 3) & 0x7;
        const ea_reg = opcode & 0x7;

        if (size_bits == 3) {
            // Invalid size? Or maybe CAS?
            return;
        }

        // 1. Fetch Immediate
        var imm: u32 = 0;
        var size_bytes: u8 = 0;
        if (size_bits == 0) { // Byte
            imm = self.fetch16(bus) & 0xFF;
            size_bytes = 1;
        } else if (size_bits == 1) { // Word
            imm = self.fetch16(bus);
            size_bytes = 2;
        } else { // Long
            imm = self.fetch32(bus);
            size_bytes = 4;
        }

        // 2. Fetch Destination (EA)
        var dest: u32 = 0;
        var addr: u32 = 0;
        var is_memory = false;

        if (ea_mode == 0) { // Dn
            if (size_bits == 0) {
                dest = self.d[ea_reg] & 0xFF;
            } else if (size_bits == 1) {
                dest = self.d[ea_reg] & 0xFFFF;
            } else {
                dest = self.d[ea_reg];
            }
        } else if (ea_mode == 1) { // An (Only valid for CMPI? Others cannot write to An)
            // Check validity (ORI/ANDI/EORI to An is invalid)
            if (type_byte != 0x0C) { // Not CMPI
                // Invalid instruction?
                // std.debug.print("Invalid Logic Op to An {X:0>4}\n", .{opcode});
                // return;
                // Or maybe it executes but traps?
            }
            // Fetch An
            if (size_bits == 0) {
                dest = self.a[ea_reg] & 0xFF; // Byte on An invalid?
            } else if (size_bits == 1) {
                dest = self.a[ea_reg] & 0xFFFF;
            } else {
                dest = self.a[ea_reg];
            }
        } else {
            is_memory = true;
            if (ea_mode == 2) {
                addr = self.a[ea_reg];
            } else if (ea_mode == 3) {
                addr = self.a[ea_reg];
                // PostInc later
            } else if (ea_mode == 4) {
                // PreDec
                const dec = @as(u32, if (size_bytes == 1 and ea_reg == 7) 2 else size_bytes);
                self.a[ea_reg] -%= dec;
                addr = self.a[ea_reg];
            } else if (ea_mode == 5) {
                const disp = @as(i16, @bitCast(self.fetch16(bus)));
                addr = self.a[ea_reg] +% @as(u32, @bitCast(@as(i32, disp)));
            } else if (ea_mode == 6) { // (d8, An, Xn)
                addr = self.calcIndexAddress(bus, self.a[ea_reg]);
                self.cycles += 2; // Extra
            } else if (ea_mode == 7 and ea_reg == 0) { // Abs.W
                const w = self.fetch16(bus);
                addr = @as(u32, @bitCast(@as(i32, @as(i16, @bitCast(w)))));
            } else if (ea_mode == 7 and ea_reg == 1) {
                addr = self.fetch32(bus);
            } else if (ea_mode == 7 and ea_reg == 2) { // PC+d16
                if (type_byte == 0x0C) { // CMPI allows PC Rel
                    const disp = @as(i16, @bitCast(self.fetch16(bus)));
                    addr = (self.pc - 2) +% @as(u32, @bitCast(@as(i32, disp)));
                } else {
                    // Invalid for write
                    std.debug.print("Invalid PC Rel for Write Op {X:0>4}\n", .{opcode});
                    return;
                }
            } else if (ea_mode == 7 and ea_reg == 3) { // PC+d8+Xn
                if (type_byte == 0x0C) { // CMPI
                    addr = self.calcIndexAddress(bus, self.pc - 2);
                } else {
                    std.debug.print("Invalid PC Rel for Write Op {X:0>4}\n", .{opcode});
                    return;
                }
            } else {
                std.debug.print("Unimpl Logic Op Mode {d} Reg {d} Op {X:0>4}\n", .{ ea_mode, ea_reg, opcode });
                return;
            }

            if (size_bits == 0) {
                dest = bus.read8(addr);
            } else if (size_bits == 1) {
                dest = bus.read16(addr);
            } else {
                dest = bus.read32(addr);
            }
        }

        // 3. Perform Operation
        var res: u32 = 0;
        if (type_byte == 0x00) { // ORI
            res = dest | imm;
            self.sr &= 0xFFFE; // Clear C
            self.sr &= 0xFFFD; // Clear V
        } else if (type_byte == 0x02) { // ANDI
            res = dest & imm;
            self.sr &= 0xFFFE;
            self.sr &= 0xFFFD;
        } else if (type_byte == 0x0A) { // EORI
            res = dest ^ imm;
            self.sr &= 0xFFFE;
            self.sr &= 0xFFFD;
        } else if (type_byte == 0x0C) { // CMPI
            // CMP: Dest - Source (Dest - Imm)
            // CMPI #imm, Dest
            // res = dest - imm?
            // We need subtraction result to set flags
            // Use a helper or inline subtraction logic with flags
            const sub_res = @as(u64, dest) -% @as(u64, imm);
            res = @as(u32, @truncate(sub_res));

            // Flags for CMP (subtraction: dest - imm)
            self.updateN(res, size_bytes);
            self.updateZ(res, size_bytes);

            // Calculate shift amount for MSB based on size
            const shift_amt: u5 = if (size_bytes == 1) 7 else if (size_bytes == 2) 15 else 31;
            const sm = @as(u1, @intCast((imm >> shift_amt) & 1));
            const dm = @as(u1, @intCast((dest >> shift_amt) & 1));
            const rm = @as(u1, @intCast((res >> shift_amt) & 1));

            // Subtraction overflow: V = (!Sm & Dm & !Rm) | (Sm & !Dm & Rm)
            const v_bit = ((~sm & dm & ~rm) | (sm & ~dm & rm)) & 1;

            // Subtraction borrow (carry): Sm & !Dm | Rm & !Dm | Sm & Rm
            const c_bit = ((sm & ~dm) | (rm & ~dm) | (sm & rm)) & 1;

            if (c_bit != 0) {
                self.sr |= 1;
            } else {
                self.sr &= 0xFFFE;
            }
            if (v_bit != 0) {
                self.sr |= 2;
            } else {
                self.sr &= 0xFFFD;
            }

            self.cycles += 8; // Approx
            return; // CMPI doesn't write back
        }

        // 4. Update Flags (Logic Ops)
        if (type_byte != 0x0C) {
            self.updateN(res, size_bytes);
            self.updateZ(res, size_bytes);
        }

        // 5. Write Back
        if (is_memory) {
            if (size_bits == 0) {
                bus.write8(addr, @as(u8, @truncate(res)));
            } else if (size_bits == 1) {
                bus.write16(addr, @as(u16, @truncate(res)));
            } else {
                bus.write32(addr, res);
            }

            // PostInc Update
            if (ea_mode == 3) {
                const inc = @as(u32, if (size_bytes == 1 and ea_reg == 7) 2 else size_bytes);
                self.a[ea_reg] +%= inc;
            }
            self.cycles += 12; // Base
        } else {
            // Register
            if (size_bits == 0) {
                self.d[ea_reg] = (self.d[ea_reg] & 0xFFFFFF00) | (res & 0xFF);
            } else if (size_bits == 1) {
                self.d[ea_reg] = (self.d[ea_reg] & 0xFFFF0000) | (res & 0xFFFF);
            } else {
                self.d[ea_reg] = res;
            }
            self.cycles += 8;
        }
        return;
    }

    // BTST (Static): 0000 1000 00 EA -> 0800
    if ((opcode & 0xFFC0) == 0x0800) {
        const ea_mode = (opcode >> 3) & 0x7;
        const ea_reg = opcode & 0x7;

        const bit_num = self.fetch16(bus) & 0xFF;

        if (ea_mode == 0) { // Dn (Long)
            const val = self.d[ea_reg];
            const bit = bit_num % 32;
            const z = (val & (@as(u32, 1) << @as(u5, @intCast(bit)))) == 0;
            if (z) self.sr |= 0x0004 else self.sr &= 0xFFFB;
            self.cycles += 10;
            return;
        } else {
            // Memory (Byte)
            // Calculate Effective Address
            var addr: u32 = 0;
            // Support common effective addressing modes
            if (ea_mode == 2) { // (An)
                addr = self.a[ea_reg];
            } else if (ea_mode == 3) { // (An)+
                addr = self.a[ea_reg];
                self.a[ea_reg] +%= if (ea_reg == 7) 2 else 1; // Stack pointer increments by 2
            } else if (ea_mode == 4) { // -(An)
                self.a[ea_reg] -%= if (ea_reg == 7) 2 else 1;
                addr = self.a[ea_reg];
            } else if (ea_mode == 5) { // (d16,An)
                const disp = @as(i16, @bitCast(self.fetch16(bus)));
                addr = self.a[ea_reg] +% @as(u32, @bitCast(@as(i32, disp)));
            } else if (ea_mode == 6) { // (d8, An, Xn)
                addr = self.calcIndexAddress(bus, self.a[ea_reg]);
            } else if (ea_mode == 7) {
                if (ea_reg == 0) { // Abs.W
                    const w = self.fetch16(bus);
                    addr = @as(u32, @bitCast(@as(i32, @as(i16, @bitCast(w)))));
                } else if (ea_reg == 1) { // Abs.L
                    addr = self.fetch32(bus);
                } else if (ea_reg == 2) { // (d16,PC)
                    const disp = @as(i16, @bitCast(self.fetch16(bus)));
                    addr = (self.pc - 2) +% @as(u32, @bitCast(@as(i32, disp)));
                } else if (ea_reg == 3) { // (d8,PC,Xn)
                    addr = self.calcIndexAddress(bus, self.pc - 2);
                } else {
                    std.debug.print("Unimpl Static BTST Mode 7 Reg {d}\n", .{ea_reg});
                    return;
                }
            } else {
                std.debug.print("Unimpl Static BTST Mode {d} Reg {d}\n", .{ ea_mode, ea_reg });
                return;
            }

            const val = bus.read8(addr);
            const bit = bit_num % 8;
            const z = (val & (@as(u8, 1) << @as(u3, @intCast(bit)))) == 0;
            if (z) self.sr |= 0x0004 else self.sr &= 0xFFFB;
            self.cycles += 8; // Memory
            return;
        }
    }

    // Dynamic Bit Ops: 0000 RRR 1xx MMM RRR
    // 100 = BTST, 101 = BCHG, 110 = BCLR, 111 = BSET
    if ((opcode & 0xF100) == 0x0100) {
        const bit_reg = (opcode >> 9) & 0x7;
        const op_type = (opcode >> 6) & 0x3; // 0=BTST, 1=BCHG, 2=BCLR, 3=BSET
        const ea_mode = (opcode >> 3) & 0x7;
        const ea_reg = opcode & 0x7;

        const bit_val = self.d[bit_reg]; // Dynamic bit number

        if (ea_mode == 0) { // Dn (Long)
            const bit = bit_val % 32;
            const mask = @as(u32, 1) << @as(u5, @intCast(bit));
            const dest_val = self.d[ea_reg];

            // Test
            const z = (dest_val & mask) == 0;
            if (z) self.sr |= 0x0004 else self.sr &= 0xFFFB;

            // Modify
            if (op_type == 1) { // BCHG
                self.d[ea_reg] ^= mask;
            } else if (op_type == 2) { // BCLR
                self.d[ea_reg] &= ~mask;
            } else if (op_type == 3) { // BSET
                self.d[ea_reg] |= mask;
            }
            self.cycles += if (op_type == 0) 6 else 8;
            return;
        } else {
            // Memory (Byte)
            const bit = bit_val % 8;
            const mask = @as(u8, 1) << @as(u3, @intCast(bit));

            var addr: u32 = 0;
            if (ea_mode == 2) {
                addr = self.a[ea_reg];
            } else if (ea_mode == 3) {
                addr = self.a[ea_reg];
                self.a[ea_reg] +%= 1;
            } else if (ea_mode == 4) {
                self.a[ea_reg] -%= 1;
                addr = self.a[ea_reg];
            } else if (ea_mode == 5) { // (d16, An)
                const disp = @as(i16, @bitCast(self.fetch16(bus)));
                addr = self.a[ea_reg] +% @as(u32, @bitCast(@as(i32, disp)));
            } else if (ea_mode == 6) { // (d8, An, Xn)
                addr = self.calcIndexAddress(bus, self.a[ea_reg]);
            } else if (ea_mode == 7 and ea_reg == 1) { // Abs.L
                addr = self.fetch32(bus);
            } else {
                std.debug.print("Unimpl Dynamic Bit Op Mode {d} Reg {d}\n", .{ ea_mode, ea_reg });
                return;
            }

            const val = bus.read8(addr);

            // Test
            const z = (val & mask) == 0;
            if (z) self.sr |= 0x0004 else self.sr &= 0xFFFB;

            // Modify
            if (op_type != 0) { // Not BTST
                var new_val = val;
                if (op_type == 1) {
                    new_val ^= mask;
                } else if (op_type == 2) {
                    new_val &= ~mask;
                } else if (op_type == 3) {
                    new_val |= mask;
                }

                bus.write8(addr, new_val);
                self.cycles += 4; // Read-Modify-Write adds cycles
            }
            self.cycles += 4; // Base
            return;
        }
    }

    std.debug.print("Unimplemented Opcode (Bit 0): {X:0>4} at PC: {X:0>8}\n", .{ opcode, self.pc - 2 });
}
