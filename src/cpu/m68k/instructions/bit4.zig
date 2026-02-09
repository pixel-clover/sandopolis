const std = @import("std");
const Cpu = @import("../cpu.zig").Cpu;
const Bus = @import("../../../memory.zig").Bus;

pub fn execBit4(self: *Cpu, opcode: u16, bus: *Bus) void {
    // Misc
    if (opcode == 0x4E71) { // NOP
        self.cycles += 4;
        return;
    }
    if (opcode == 0x4E70) { // RESET
        // NOP for now
        return;
    }
    if (opcode == 0x46FC) { // MOVE #imm, SR
        const imm = self.fetch16(bus);
        self.sr = imm;
        self.cycles += 12;
        return;
    }

    // LEA: 0100 Reg 111 Mode Reg
    if ((opcode & 0xF1C0) == 0x41C0) {
        const reg_idx = (opcode >> 9) & 0x7;
        const ea_mode = (opcode >> 3) & 0x7;
        const ea_reg = opcode & 0x7;

        var addr: u32 = 0;
        if (ea_mode == 2) { // (An)
            addr = self.a[ea_reg];
        } else if (ea_mode == 5) { // (d16, An)
            const disp = @as(i16, @bitCast(self.fetch16(bus)));
            addr = self.a[ea_reg] +% @as(u32, @bitCast(@as(i32, disp)));
        } else if (ea_mode == 7) {
            if (ea_reg == 0) { // Abs.W
                const w = self.fetch16(bus);
                addr = @as(u32, @bitCast(@as(i32, @as(i16, @bitCast(w)))));
            } else if (ea_reg == 1) { // Abs.L
                addr = self.fetch32(bus);
            } else if (ea_reg == 2) { // PC+d16
                const disp = @as(i16, @bitCast(self.fetch16(bus)));
                addr = (self.pc - 2) +% @as(u32, @bitCast(@as(i32, disp)));
            } else if (ea_reg == 3) { // PC+d8+Xn
                addr = self.calcIndexAddress(bus, self.pc - 2);
                self.cycles += 4;
            } else {
                self.trapUnimplemented(opcode);
                return;
            }
        } else if (ea_mode == 6) { // (d8, An, Xn)
            addr = self.calcIndexAddress(bus, self.a[ea_reg]);
            self.cycles += 4;
        } else {
            self.trapUnimplemented(opcode);
            return;
        }

        self.a[reg_idx] = addr;
        self.cycles += 4;
        return;
    }

    // CHK: 0100 Dn 110 EA (0x4180-0x41FF, 0x4380-0x43FF, etc.)
    if ((opcode & 0xF1C0) == 0x4180) {
        const reg_idx = (opcode >> 9) & 0x7;
        const ea_mode = (opcode >> 3) & 0x7;
        const ea_reg = opcode & 0x7;

        var upper_bound: i16 = 0;

        // Read upper bound (word)
        if (ea_mode == 0) { // Dn
            upper_bound = @as(i16, @bitCast(@as(u16, @truncate(self.d[ea_reg]))));
            self.cycles += 10;
        } else if (ea_mode == 7 and ea_reg == 4) { // Immediate
            upper_bound = @as(i16, @bitCast(self.fetch16(bus)));
            self.cycles += 10;
        } else if (ea_mode == 2) { // (An)
            const addr = self.a[ea_reg];
            upper_bound = @as(i16, @bitCast(bus.read16(addr)));
            self.cycles += 14;
        } else {
            self.trapUnimplemented(opcode);
            return;
        }

        const value = @as(i16, @bitCast(@as(u16, @truncate(self.d[reg_idx]))));

        // Clear V flag
        self.sr &= 0xFFFD;

        // Check if value < 0 or value > upper_bound
        if (value < 0) {
            // Negative - set N flag and trigger exception
            self.sr |= 0x0008; // Set N
            std.debug.print("CHK exception: value < 0 at PC: {X:0>8}, triggering exception\n", .{self.pc - 2});
            self.triggerException(bus, 6); // Vector 6 = CHK instruction
        } else if (value > upper_bound) {
            // Out of bounds - clear N flag and trigger exception
            self.sr &= 0xFFF7; // Clear N
            std.debug.print("CHK exception: value > bound at PC: {X:0>8}, triggering exception\n", .{self.pc - 2});
            self.triggerException(bus, 6); // Vector 6 = CHK instruction
        } else {
            // In bounds - no exception
            return;
        }
        return;
    }

    // TAS: 0100 1010 11xx xxxx (0x4AC0-0x4AFF)
    if ((opcode & 0xFFC0) == 0x4AC0) {
        const ea_mode = (opcode >> 3) & 0x7;
        const ea_reg = opcode & 0x7;

        var value: u8 = 0;

        if (ea_mode == 0) { // Dn
            value = @as(u8, @truncate(self.d[ea_reg]));

            // Test and set flags
            self.updateN(value, 1);
            self.updateZ(value, 1);
            self.sr &= 0xFFFE; // Clear C
            self.sr &= 0xFFFD; // Clear V

            // Set bit 7
            self.d[ea_reg] = (self.d[ea_reg] & 0xFFFFFF00) | (value | 0x80);
            self.cycles += 4;
        } else if (ea_mode == 2) { // (An)
            const addr = self.a[ea_reg];
            value = bus.read8(addr);

            // Test and set flags
            self.updateN(value, 1);
            self.updateZ(value, 1);
            self.sr &= 0xFFFE; // Clear C
            self.sr &= 0xFFFD; // Clear V

            // Set bit 7 and write back
            bus.write8(addr, value | 0x80);
            self.cycles += 14;
        } else {
            self.trapUnimplemented(opcode);
            return;
        }
        return;
    }

    // MOVEM: 0100 1c00 1s EA -> 4C80 / 4C00 (Wait, logic?)
    // Opcode: 0100 1 (dr) 00 1 (sz) (EA)
    // dr: 0 = R->M, 1 = M->R
    // sz: 0 = Word, 1 = Long

    if ((opcode & 0xFB80) == 0x4880) {
        const dr = (opcode >> 10) & 1; // 0=R->M, 1=M->R
        const size_bit = (opcode >> 6) & 1; // 0=Word, 1=Long
        const ea_mode = (opcode >> 3) & 0x7;
        const ea_reg = opcode & 0x7;

        const list = self.fetch16(bus); // Register Mask
        self.cycles += 4; // Fetch mask

        var addr: u32 = 0;
        var addr_valid = true;

        // Calculate EA
        if (ea_mode == 2) { // (An)
            addr = self.a[ea_reg];
        } else if (ea_mode == 3) { // (An)+
            addr = self.a[ea_reg];
        } else if (ea_mode == 4) { // -(An)
            addr = self.a[ea_reg]; // Will be decremented during transfer?
        } else if (ea_mode == 5) { // (d16, An)
            const disp = @as(i16, @bitCast(self.fetch16(bus)));
            addr = self.a[ea_reg] +% @as(u32, @bitCast(@as(i32, disp)));
        } else if (ea_mode == 7 and ea_reg == 1) { // Abs.L
            addr = self.fetch32(bus);
        } else if (ea_mode == 7 and ea_reg == 2) { // PC+d16
            const disp = @as(i16, @bitCast(self.fetch16(bus)));
            addr = (self.pc - 2) +% @as(u32, @bitCast(@as(i32, disp)));
        } else {
            addr_valid = false;
        }

        if (!addr_valid) {
            self.trapUnimplemented(opcode);
            return;
        }

        var count: u32 = 0;

        if (dr == 1) { // Memory to Register
            // Low bit to High bit (0..15).
            // Logic: 0-7 = D0-D7, 8-15 = A0-A7.
            for (0..16) |i| {
                if ((list & (@as(u16, 1) << @as(u4, @intCast(i)))) != 0) {
                    var val: u32 = 0;
                    if (size_bit == 1) { // Long
                        val = bus.read32(addr);
                        addr += 4;
                        self.cycles += 8; // move data
                    } else { // Word
                        const word_val = bus.read16(addr);
                        // Sign extend for address registers, zero extend for data registers
                        if (i >= 8) {
                            val = @as(u32, @bitCast(@as(i32, @as(i16, @bitCast(word_val))))); // Sign extend for An
                        } else {
                            val = word_val; // Zero extend for Dn
                        }
                        addr += 2;
                        self.cycles += 4;
                    }

                    if (i < 8) {
                        if (size_bit == 0) { // Word - preserve upper word for data registers
                            self.d[i] = (self.d[i] & 0xFFFF0000) | (val & 0xFFFF);
                        } else {
                            self.d[i] = val;
                        }
                    } else {
                        self.a[i - 8] = val;
                    }
                    count += 1;
                }
            }

            // If Mode 3 (PostInc), update An, BUT ONLY if An was not in the list!
            if (ea_mode == 3) {
                const an_in_list = (list & (@as(u16, 1) << @as(u4, @intCast(8 + ea_reg)))) != 0;
                if (!an_in_list) {
                    self.a[ea_reg] = addr;
                }
            }
        } else { // Register to Memory
            // If Mode 4 (PreDec), order is reversed? High to Low? or Low to High with predec?
            // "If the addressing mode is pre-decrement, the mask is scanned from bit 15 to 0."
            if (ea_mode == 4) {
                var temp_addr = self.a[ea_reg];
                var i: usize = 0;
                while (i < 16) : (i += 1) {
                    const idx: usize = 15 - i;
                    if ((list & (@as(u16, 1) << @as(u4, @intCast(idx)))) != 0) {
                        var val: u32 = 0;
                        if (idx < 8) {
                            val = self.d[idx];
                        } else {
                            val = self.a[idx - 8];
                        }

                        if (size_bit == 1) { // Long
                            temp_addr -%= 4; // Wrapping arithmetic!
                            bus.write32(temp_addr, val);
                            self.cycles += 8;
                        } else { // Word
                            temp_addr -%= 2;
                            bus.write16(temp_addr, @as(u16, @truncate(val)));
                            self.cycles += 4;
                        }
                    }
                }
                self.a[ea_reg] = temp_addr;
            } else {
                // Standard modes (Control)
                for (0..16) |i| {
                    if ((list & (@as(u16, 1) << @as(u4, @intCast(i)))) != 0) {
                        var val: u32 = 0;
                        if (i < 8) {
                            val = self.d[i];
                        } else {
                            val = self.a[i - 8];
                        }

                        if (size_bit == 1) {
                            bus.write32(addr, val);
                            addr += 4;
                            self.cycles += 8;
                        } else {
                            bus.write16(addr, @as(u16, @truncate(val)));
                            addr += 2;
                            self.cycles += 4;
                        }
                    }
                }
            }
        }
        return;
    }

    // TST: 0100 1010 sz EA
    if ((opcode & 0xFF00) == 0x4A00) {
        const size_bits = (opcode >> 6) & 0x3;
        const ea_mode = (opcode >> 3) & 0x7;
        const ea_reg = opcode & 0x7;

        var val: u32 = 0;
        const size_bytes: u8 = switch (size_bits) {
            0 => 1,
            1 => 2,
            else => 4,
        };

        // 1. Calculate Effective Address and Read Value
        // TST supports Data Addressing Modes (Dn, (An), (An)+, -(An), (d16,An), (d8,An,Xn), Abs.W, Abs.L, (d16,PC), (d8,PC,Xn))
        // Address Register Direct (An) is NOT allowed.

        var addr: u32 = 0;
        var valid_mode = true;

        if (ea_mode == 0) { // Dn
            if (size_bits == 0) val = @as(u8, @truncate(self.d[ea_reg]));
            if (size_bits == 1) val = @as(u16, @truncate(self.d[ea_reg]));
            if (size_bits == 2) val = self.d[ea_reg];
        } else if (ea_mode == 2) { // (An)
            addr = self.a[ea_reg];
        } else if (ea_mode == 3) { // (An)+
            addr = self.a[ea_reg];
            const inc = @as(u32, if (size_bytes == 1 and ea_reg == 7) 2 else size_bytes);
            self.a[ea_reg] +%= inc;
        } else if (ea_mode == 4) { // -(An)
            const dec = @as(u32, if (size_bytes == 1 and ea_reg == 7) 2 else size_bytes);
            self.a[ea_reg] -%= dec;
            addr = self.a[ea_reg];
        } else if (ea_mode == 5) { // (d16, An)
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
            } else if (ea_reg == 2) { // PC+d16
                const disp = @as(i16, @bitCast(self.fetch16(bus)));
                addr = (self.pc - 2) +% @as(u32, @bitCast(@as(i32, disp)));
            } else if (ea_reg == 3) { // PC+d8+Xn
                addr = self.calcIndexAddress(bus, self.pc - 2);
            } else if (ea_reg == 4) { // Immediate
                if (size_bits == 0) {
                    val = @as(u8, @truncate(self.fetch16(bus)));
                } else if (size_bits == 1) {
                    val = self.fetch16(bus);
                } else {
                    val = self.fetch32(bus);
                }
                // Immediate has no address to read from, value is already fetched
            } else {
                valid_mode = false;
            }
        } else {
            valid_mode = false;
        }

        if (!valid_mode) {
            self.trapUnimplemented(opcode);
            return;
        }

        // If EA was memory (not Dn or Imm), read the value
        if (ea_mode != 0 and !(ea_mode == 7 and ea_reg == 4)) {
            if (size_bits == 0) {
                val = bus.read8(addr);
                self.cycles += 4;
            } else if (size_bits == 1) {
                val = bus.read16(addr);
                self.cycles += 4;
            } else {
                val = bus.read32(addr);
                self.cycles += 4;
            }
        }

        // Mode 0 cycles
        // TST Dn: 4 cycles. TST Mem: 4 + EA.
        // My cycle counts above are approximations.

        self.updateN(val, size_bytes);
        self.updateZ(val, size_bytes);
        self.sr &= 0xFFFE; // Clear C
        self.sr &= 0xFFFD; // Clear V
        self.cycles += 4;
        return;
    }

    // RTS: 4E75
    if (opcode == 0x4E75) {
        self.pc = self.pop32(bus);
        self.cycles += 16;
        return;
    }

    // JSR <ea>: 0100 1110 10xx xxxx (0x4E80-0x4EBF)
    if ((opcode & 0xFFC0) == 0x4E80) {
        const ea_mode = (opcode >> 3) & 0x7;
        const ea_reg = opcode & 0x7;

        var target_addr: u32 = 0;

        if (ea_mode == 2) { // (An)
            target_addr = self.a[ea_reg];
            self.cycles += 16;
        } else if (ea_mode == 5) { // (d16, An)
            const disp = @as(i16, @bitCast(self.fetch16(bus)));
            target_addr = self.a[ea_reg] +% @as(u32, @bitCast(@as(i32, disp)));
            self.cycles += 18;
        } else if (ea_mode == 6) { // (d8, An, Xn)
            target_addr = self.calcIndexAddress(bus, self.a[ea_reg]);
            self.cycles += 22;
        } else if (ea_mode == 7) {
            if (ea_reg == 0) { // Abs.W
                const w = self.fetch16(bus);
                target_addr = @as(u32, @bitCast(@as(i32, @as(i16, @bitCast(w)))));
                self.cycles += 18;
            } else if (ea_reg == 1) { // Abs.L
                target_addr = self.fetch32(bus);
                self.cycles += 20;
            } else if (ea_reg == 2) { // PC+d16
                const disp = @as(i16, @bitCast(self.fetch16(bus)));
                target_addr = (self.pc - 2) +% @as(u32, @bitCast(@as(i32, disp)));
                self.cycles += 18;
            } else if (ea_reg == 3) { // PC+d8+Xn
                target_addr = self.calcIndexAddress(bus, self.pc - 2);
                self.cycles += 22;
            } else {
                self.trapUnimplemented(opcode);
                return;
            }
        } else {
            self.trapUnimplemented(opcode);
            return;
        }

        self.push32(bus, self.pc);
        self.pc = target_addr;
        return;
    }

    // JMP <ea>: 0100 1110 11xx xxxx (0x4EC0-0x4EFF)
    if ((opcode & 0xFFC0) == 0x4EC0) {
        const ea_mode = (opcode >> 3) & 0x7;
        const ea_reg = opcode & 0x7;

        var target_addr: u32 = 0;
        if (ea_mode == 2) { // (An)
            target_addr = self.a[ea_reg];
            self.cycles += 8;
        } else if (ea_mode == 5) { // (d16, An)
            const disp = @as(i16, @bitCast(self.fetch16(bus)));
            target_addr = self.a[ea_reg] +% @as(u32, @bitCast(@as(i32, disp)));
            self.cycles += 10;
        } else if (ea_mode == 6) { // (d8, An, Xn)
            target_addr = self.calcIndexAddress(bus, self.a[ea_reg]);
            self.cycles += 14;
        } else if (ea_mode == 7) {
            if (ea_reg == 0) { // Abs.W
                const w = self.fetch16(bus);
                target_addr = @as(u32, @bitCast(@as(i32, @as(i16, @bitCast(w)))));
                self.cycles += 10;
            } else if (ea_reg == 1) { // Abs.L
                target_addr = self.fetch32(bus);
                self.cycles += 12;
            } else if (ea_reg == 2) { // PC+d16
                const disp = @as(i16, @bitCast(self.fetch16(bus)));
                target_addr = (self.pc - 2) +% @as(u32, @bitCast(@as(i32, disp)));
                self.cycles += 10;
            } else if (ea_reg == 3) { // PC+d8+Xn
                target_addr = self.calcIndexAddress(bus, self.pc - 2);
                self.cycles += 14;
            } else {
                self.trapUnimplemented(opcode);
                return;
            }
        } else {
            self.trapUnimplemented(opcode);
            return;
        }

        self.pc = target_addr;
        return;
    }

    // MOVE USP
    // 4E60-4E67: MOVE An, USP
    // 4E68-4E6F: MOVE USP, An
    if ((opcode & 0xFFF0) == 0x4E60) {
        const dr = (opcode >> 3) & 1; // 0=To USP, 1=From USP
        const reg_idx = opcode & 0x7;

        if (dr == 0) { // An -> USP
            self.usp = self.a[reg_idx];
        } else { // USP -> An
            self.a[reg_idx] = self.usp;
        }
        self.cycles += 4;
        return;
    }

    // CLR: 0100 0010 sz EA (0x4200-0x42FF)
    if ((opcode & 0xFF00) == 0x4200) {
        const size = (opcode >> 6) & 0x3;
        const ea_mode = (opcode >> 3) & 0x7;
        const ea_reg = opcode & 0x7;

        if (size == 3) {
            self.trapUnimplemented(opcode);
            return;
        }

        var addr: u32 = 0;
        var valid_mode = true;

        if (ea_mode == 0) { // Dn
            // Valid for CLR
            if (size == 0) self.d[ea_reg] &= 0xFFFFFF00;
            if (size == 1) self.d[ea_reg] &= 0xFFFF0000;
            if (size == 2) self.d[ea_reg] = 0;
            self.cycles += if (size == 2) 6 else 4;
        } else if (ea_mode == 2) { // (An)
            addr = self.a[ea_reg];
        } else if (ea_mode == 3) { // (An)+
            addr = self.a[ea_reg];
            const inc: u32 = if (size == 0 and ea_reg == 7) 2 else if (size == 0) 1 else if (size == 1) 2 else 4;
            self.a[ea_reg] +%= inc;
        } else if (ea_mode == 4) { // -(An)
            const dec: u32 = if (size == 0 and ea_reg == 7) 2 else if (size == 0) 1 else if (size == 1) 2 else 4;
            self.a[ea_reg] -%= dec;
            addr = self.a[ea_reg];
        } else if (ea_mode == 5) { // (d16, An)
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
            } else {
                valid_mode = false;
            }
        } else {
            valid_mode = false;
        }

        if (valid_mode and ea_mode != 0) {
            // Write 0 to generic address
            if (size == 0) {
                // CLR.b reads before write? "One operand instruction... read-modify-write cycle?"
                // CLR is Write Only on 68000? Docs: "Read-Modify-Write cycle" for memory.
                // So we should read it first? (dummy read).
                _ = bus.read8(addr);
                bus.write8(addr, 0);
                self.cycles += 12; // approx
            } else if (size == 1) {
                _ = bus.read16(addr);
                bus.write16(addr, 0);
                self.cycles += 12;
            } else {
                _ = bus.read16(addr); // Read upper?
                _ = bus.read16(addr + 2); // Read lower?
                bus.write32(addr, 0);
                self.cycles += 20;
            }
        } else if (!valid_mode) {
            self.trapUnimplemented(opcode);
            return;
        }

        // Set flags: N=0, Z=1, V=0, C=0
        self.sr &= 0xFFF0; // Clear N, Z, V, C
        self.sr |= 0x0004; // Set Z
        return;
    }

    // NEG: 0100 0100 sz EA (0x4400-0x44FF)
    if ((opcode & 0xFF00) == 0x4400) {
        const size = (opcode >> 6) & 0x3;
        const ea_mode = (opcode >> 3) & 0x7;
        const ea_reg = opcode & 0x7;

        if (size == 3) {
            // MOVE to CCR: 0100 0100 11 <ea> (0x44C0)
            var val: u16 = 0;
            if (ea_mode == 0) { // Dn
                val = @as(u16, @truncate(self.d[ea_reg]));
                self.cycles += 4;
            } else if (ea_mode == 2) { // (An)
                const addr = self.a[ea_reg];
                val = bus.read16(addr);
                self.cycles += 12;
            } else if (ea_mode == 3) { // (An)+
                const addr = self.a[ea_reg];
                val = bus.read16(addr);
                self.a[ea_reg] +%= 2;
                self.cycles += 12;
            } else if (ea_mode == 4) { // -(An)
                self.a[ea_reg] -%= 2;
                const addr = self.a[ea_reg];
                val = bus.read16(addr);
                self.cycles += 14;
            } else if (ea_mode == 5) { // (d16, An)
                const disp = @as(i16, @bitCast(self.fetch16(bus)));
                const addr = self.a[ea_reg] +% @as(u32, @bitCast(@as(i32, disp)));
                val = bus.read16(addr);
                self.cycles += 16;
            } else if (ea_mode == 7 and ea_reg == 4) { // Immediate
                val = self.fetch16(bus);
                self.cycles += 12;
            } else if (ea_mode == 7 and ea_reg == 0) { // Abs.W
                const w = self.fetch16(bus);
                const addr = @as(u32, @bitCast(@as(i32, @as(i16, @bitCast(w)))));
                val = bus.read16(addr);
                self.cycles += 16;
            } else if (ea_mode == 7 and ea_reg == 1) { // Abs.L
                const addr = self.fetch32(bus);
                val = bus.read16(addr);
                self.cycles += 16;
            } else if (ea_mode == 7 and ea_reg == 2) { // PC+d16
                const disp = @as(i16, @bitCast(self.fetch16(bus)));
                const addr = (self.pc - 2) +% @as(u32, @bitCast(@as(i32, disp)));
                val = bus.read16(addr);
                self.cycles += 16;
            } else if (ea_mode == 6) { // (d8, An, Xn)
                const addr = self.calcIndexAddress(bus, self.a[ea_reg]);
                val = bus.read16(addr);
                self.cycles += 16; // approx
            } else if (ea_mode == 7 and ea_reg == 3) { // PC+d8+Xn
                const addr = self.calcIndexAddress(bus, self.pc - 2);
                val = bus.read16(addr);
                self.cycles += 16; // approx
            } else {
                self.trapUnimplemented(opcode);
                return;
            }

            self.sr = (self.sr & 0xFF00) | (val & 0xFF);
            return;
        }

        // NEG supports Data Alterable support (Dn + Memory)
        var addr: u32 = 0;
        var valid = true;

        if (ea_mode == 0) { // Dn
            // handled below
        } else if (ea_mode == 2) {
            addr = self.a[ea_reg];
        } else if (ea_mode == 3) {
            addr = self.a[ea_reg];
            const inc: u32 = if (size == 0 and ea_reg == 7) 2 else if (size == 0) 1 else if (size == 1) 2 else 4;
            self.a[ea_reg] +%= inc;
        } else if (ea_mode == 4) {
            const dec: u32 = if (size == 0 and ea_reg == 7) 2 else if (size == 0) 1 else if (size == 1) 2 else 4;
            self.a[ea_reg] -%= dec;
            addr = self.a[ea_reg];
        } else if (ea_mode == 5) {
            const disp = @as(i16, @bitCast(self.fetch16(bus)));
            addr = self.a[ea_reg] +% @as(u32, @bitCast(@as(i32, disp)));
        } else if (ea_mode == 6) {
            addr = self.calcIndexAddress(bus, self.a[ea_reg]);
        } else if (ea_mode == 7) {
            if (ea_reg == 0) {
                const w = self.fetch16(bus);
                addr = @as(u32, @bitCast(@as(i32, @as(i16, @bitCast(w)))));
            } else if (ea_reg == 1) {
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

        if (ea_mode == 0) { // Dn
            if (size == 0) { // Byte
                const val = @as(u8, @truncate(self.d[ea_reg]));
                const result = -%val;
                self.d[ea_reg] = (self.d[ea_reg] & 0xFFFFFF00) | result;
                self.updateFlagsSub(0, val, result, 1);
                self.cycles += 4;
            } else if (size == 1) { // Word
                const val = @as(u16, @truncate(self.d[ea_reg]));
                const result = -%val;
                self.d[ea_reg] = (self.d[ea_reg] & 0xFFFF0000) | result;
                self.updateFlagsSub(0, val, result, 2);
                self.cycles += 4;
            } else { // Long
                const val = self.d[ea_reg];
                const result = -%val;
                self.d[ea_reg] = result;
                self.updateFlagsSub(0, val, result, 4);
                self.cycles += 6;
            }
        } else { // Memory
            if (size == 0) {
                const val = bus.read8(addr);
                const result = -%val;
                bus.write8(addr, result);
                self.updateFlagsSub(0, val, result, 1);
                self.cycles += 12;
            } else if (size == 1) {
                const val = bus.read16(addr);
                const result = -%val;
                bus.write16(addr, result);
                self.updateFlagsSub(0, val, result, 2);
                self.cycles += 12;
            } else {
                const val = bus.read32(addr);
                const result = -%val;
                bus.write32(addr, result);
                self.updateFlagsSub(0, val, result, 4);
                self.cycles += 20;
            }
        }
        return;
    }

    // NOT: 0100 0110 sz EA (0x4600-0x46FF)
    if ((opcode & 0xFF00) == 0x4600) {
        const size = (opcode >> 6) & 0x3;
        const ea_mode = (opcode >> 3) & 0x7;
        const ea_reg = opcode & 0x7;

        if (size == 3) {
            // MOVE to SR: 0100 0110 11 <ea> (0x46C0)
            if ((self.sr & 0x2000) == 0) {
                // Privilege violation
                std.debug.print("MOVE to SR in user mode at PC: {X:0>8}\n", .{self.pc - 2});
                self.triggerException(bus, 8);
                return;
            }

            var val: u16 = 0;
            if (ea_mode == 0) { // Dn
                val = @as(u16, @truncate(self.d[ea_reg]));
                self.cycles += 4;
            } else if (ea_mode == 2) { // (An)
                const addr = self.a[ea_reg];
                val = bus.read16(addr);
                self.cycles += 12;
            } else if (ea_mode == 3) { // (An)+
                const addr = self.a[ea_reg];
                val = bus.read16(addr);
                self.a[ea_reg] +%= 2;
                self.cycles += 12;
            } else if (ea_mode == 4) { // -(An)
                self.a[ea_reg] -%= 2;
                const addr = self.a[ea_reg];
                val = bus.read16(addr);
                self.cycles += 14;
            } else if (ea_mode == 5) { // (d16, An)
                const disp = @as(i16, @bitCast(self.fetch16(bus)));
                const addr = self.a[ea_reg] +% @as(u32, @bitCast(@as(i32, disp)));
                val = bus.read16(addr);
                self.cycles += 16;
            } else if (ea_mode == 7 and ea_reg == 4) { // Immediate
                val = self.fetch16(bus);
                self.cycles += 12;
            } else if (ea_mode == 7 and ea_reg == 0) { // Abs.W
                const w = self.fetch16(bus);
                const addr = @as(u32, @bitCast(@as(i32, @as(i16, @bitCast(w)))));
                val = bus.read16(addr);
                self.cycles += 16;
            } else if (ea_mode == 7 and ea_reg == 1) { // Abs.L
                const addr = self.fetch32(bus);
                val = bus.read16(addr);
                self.cycles += 16;
            } else if (ea_mode == 7 and ea_reg == 2) { // PC+d16
                const disp = @as(i16, @bitCast(self.fetch16(bus)));
                const addr = (self.pc - 2) +% @as(u32, @bitCast(@as(i32, disp)));
                val = bus.read16(addr);
                self.cycles += 16;
            } else if (ea_mode == 6) { // (d8, An, Xn)
                const addr = self.calcIndexAddress(bus, self.a[ea_reg]);
                val = bus.read16(addr);
                self.cycles += 16; // approx
            } else if (ea_mode == 7 and ea_reg == 3) { // PC+d8+Xn
                const addr = self.calcIndexAddress(bus, self.pc - 2);
                val = bus.read16(addr);
                self.cycles += 16; // approx
            } else {
                self.trapUnimplemented(opcode);
                return;
            }

            self.sr = val; // Set full SR
            return;
        }

        if (ea_mode == 0) { // Dn
            if (size == 0) { // Byte
                const val = @as(u8, @truncate(self.d[ea_reg]));
                const result = ~val;
                self.d[ea_reg] = (self.d[ea_reg] & 0xFFFFFF00) | result;
                self.updateN(result, 1);
                self.updateZ(result, 1);
                self.cycles += 4;
            } else if (size == 1) { // Word
                const val = @as(u16, @truncate(self.d[ea_reg]));
                const result = ~val;
                self.d[ea_reg] = (self.d[ea_reg] & 0xFFFF0000) | result;
                self.updateN(result, 2);
                self.updateZ(result, 2);
                self.cycles += 4;
            } else { // Long
                const result = ~self.d[ea_reg];
                self.d[ea_reg] = result;
                self.updateN(result, 4);
                self.updateZ(result, 4);
                self.cycles += 6;
            }
            self.sr &= 0xFFFE; // Clear C
            self.sr &= 0xFFFD; // Clear V
        } else {
            self.trapUnimplemented(opcode);
        }
        return;
    }

    // EXT: 0100 100 0sz 000 Reg (0x4880-0x48C0, 0x48C0-0x48FF for long)
    // Byte to Word: 010 (0x4880)
    // Word to Long: 011 (0x48C0)
    if ((opcode & 0xFFF8) == 0x4880 or (opcode & 0xFFF8) == 0x48C0) {
        const reg_idx = opcode & 0x7;
        const word_to_long = ((opcode >> 6) & 1) == 1;

        if (word_to_long) {
            // Word to Long
            const val16 = @as(i16, @bitCast(@as(u16, @truncate(self.d[reg_idx]))));
            self.d[reg_idx] = @as(u32, @bitCast(@as(i32, val16)));
            self.updateN(self.d[reg_idx], 4);
            self.updateZ(self.d[reg_idx], 4);
        } else {
            // Byte to Word
            const val8 = @as(i8, @bitCast(@as(u8, @truncate(self.d[reg_idx]))));
            const result = @as(u16, @bitCast(@as(i16, val8)));
            self.d[reg_idx] = (self.d[reg_idx] & 0xFFFF0000) | result;
            self.updateN(result, 2);
            self.updateZ(result, 2);
        }

        self.sr &= 0xFFFE; // Clear C
        self.sr &= 0xFFFD; // Clear V
        self.cycles += 4;
        return;
    }

    // SWAP: 0100 1000 0100 0Reg (0x4840-0x4847)
    if ((opcode & 0xFFF8) == 0x4840) {
        const reg_idx = opcode & 0x7;
        const val = self.d[reg_idx];
        const swapped = (val << 16) | (val >> 16);
        self.d[reg_idx] = swapped;

        self.updateN(swapped, 4);
        self.updateZ(swapped, 4);
        self.sr &= 0xFFFE; // Clear C
        self.sr &= 0xFFFD; // Clear V
        self.cycles += 4;
        return;
    }

    // TRAP: 0100 1110 0100 vvvv (0x4E40-0x4E4F)
    if ((opcode & 0xFFF0) == 0x4E40) {
        const vector = opcode & 0xF;

        // TRAP exception processing
        // 1. Push PC
        self.push32(bus, self.pc);

        // 2. Push SR
        self.push16(bus, self.sr);

        // 3. Set supervisor mode
        self.sr |= 0x2000; // Set supervisor bit

        // 4. Read trap vector and jump
        // Trap vectors are at 0x80 + (vector * 4)
        const vector_addr = 0x80 + (@as(u32, vector) * 4);
        const trap_handler = bus.read32(vector_addr);
        self.pc = trap_handler;

        self.cycles += 34;
        return;
    }

    // LINK: 0100 1110 0101 0Reg (0x4E50-0x4E57)
    if ((opcode & 0xFFF8) == 0x4E50) {
        const reg_idx = opcode & 0x7;

        // 1. Push An to stack
        self.push32(bus, self.a[reg_idx]);

        // 2. An = SP
        self.a[reg_idx] = self.a[7];

        // 3. SP = SP + displacement (sign-extended)
        const disp = @as(i16, @bitCast(self.fetch16(bus)));
        self.a[7] = self.a[7] +% @as(u32, @bitCast(@as(i32, disp)));

        self.cycles += 16;
        return;
    }

    // UNLK: 0100 1110 0101 1Reg (0x4E58-0x4E5F)
    if ((opcode & 0xFFF8) == 0x4E58) {
        const reg_idx = opcode & 0x7;

        // 1. SP = An
        self.a[7] = self.a[reg_idx];

        // 2. Pop An from stack
        self.a[reg_idx] = self.pop32(bus);

        self.cycles += 12;
        return;
    }

    // PEA: 0100 1000 01xx xxxx (0x4840-0x487F, but 0x4840-0x4847 is SWAP)
    // Need to check mode bits more carefully
    if ((opcode & 0xFFC0) == 0x4840 and (opcode & 0x38) != 0) {
        const ea_mode = (opcode >> 3) & 0x7;
        const ea_reg = opcode & 0x7;

        var addr: u32 = 0;
        if (ea_mode == 2) { // (An)
            addr = self.a[ea_reg];
            self.cycles += 12;
        } else if (ea_mode == 5) { // (d16, An)
            const disp = @as(i16, @bitCast(self.fetch16(bus)));
            addr = self.a[ea_reg] +% @as(u32, @bitCast(@as(i32, disp)));
            self.cycles += 16;
        } else if (ea_mode == 7) {
            if (ea_reg == 0) { // Abs.W
                const w = self.fetch16(bus);
                addr = @as(u32, @bitCast(@as(i32, @as(i16, @bitCast(w)))));
                self.cycles += 16;
            } else if (ea_reg == 1) { // Abs.L
                addr = self.fetch32(bus);
                self.cycles += 20;
            } else if (ea_reg == 2) { // PC+d16
                const disp = @as(i16, @bitCast(self.fetch16(bus)));
                addr = (self.pc - 2) +% @as(u32, @bitCast(@as(i32, disp)));
                self.cycles += 16;
            } else {
                self.trapUnimplemented(opcode);
                return;
            }
        } else if (ea_mode == 6) { // (d8, An, Xn)
            addr = self.calcIndexAddress(bus, self.a[ea_reg]);
            self.cycles += 20;
        } else if (ea_mode == 7) {
            if (ea_reg == 0) { // Abs.W
                const w = self.fetch16(bus);
                addr = @as(u32, @bitCast(@as(i32, @as(i16, @bitCast(w)))));
                self.cycles += 16;
            } else if (ea_reg == 1) { // Abs.L
                addr = self.fetch32(bus);
                self.cycles += 20;
            } else if (ea_reg == 2) { // PC+d16
                const disp = @as(i16, @bitCast(self.fetch16(bus)));
                addr = (self.pc - 2) +% @as(u32, @bitCast(@as(i32, disp)));
                self.cycles += 16;
            } else if (ea_reg == 3) { // PC+d8+Xn
                addr = self.calcIndexAddress(bus, self.pc - 2);
                self.cycles += 20;
            } else {
                self.trapUnimplemented(opcode);
                return;
            }
        } else {
            self.trapUnimplemented(opcode);
            return;
        }

        self.push32(bus, addr);
        return;
    }

    // RTE: 0100 1110 0111 0011 (0x4E73)
    // RTE: 0100 1110 0111 0011 (0x4E73)
    if (opcode == 0x4E73) {
        // Return from Exception
        // 1. Pop SR (Word)
        const new_sr = self.pop16(bus);
        self.sr = new_sr;

        // 2. Pop PC (Long)
        self.pc = self.pop32(bus);

        self.cycles += 20;
        return;
    }

    // RTR: 0100 1110 0111 0111 (0x4E77)
    if (opcode == 0x4E77) {
        // Return and Restore Condition Codes
        // 1. Pop CCR (only lower byte of SR)
        const new_ccr = @as(u8, @truncate(self.pop32(bus)));
        self.sr = (self.sr & 0xFF00) | new_ccr;

        // 2. Pop PC
        self.pc = self.pop32(bus);

        self.cycles += 20;
        return;
    }

    // NBCD: 0100 1000 00 EA (0x4800-0x483F)
    if ((opcode & 0xFFC0) == 0x4800) {
        const ea_mode = (opcode >> 3) & 0x7;
        const ea_reg = opcode & 0x7;

        var temp_val: u8 = 0;
        var addr: u32 = 0;

        if (ea_mode == 0) { // Dn
            temp_val = @as(u8, @truncate(self.d[ea_reg]));
            self.cycles += 6;
        } else if (ea_mode == 2) { // (An)
            addr = self.a[ea_reg];
            temp_val = bus.read8(addr);
            self.cycles += 8;
        } else {
            // ... other modes
            self.trapUnimplemented(opcode);
            return;
        }

        const x_bit = (self.sr >> 4) & 1;
        // 0 - val - x
        var res = 0 - @as(i16, @intCast(temp_val)) - @as(i16, @intCast(x_bit));
        const bcd_carry: u1 = if (res < 0) 1 else 0;

        if ((temp_val & 0xF) + x_bit > 0) { // Low nibble borrow
            res -= 6;
        }
        if (bcd_carry == 1) {
            res -= 0x60;
        }

        const result8 = @as(u8, @truncate(@as(u16, @bitCast(res))));

        if (ea_mode == 0) {
            self.d[ea_reg] = (self.d[ea_reg] & 0xFFFFFF00) | result8;
        } else {
            bus.write8(addr, result8);
        }

        if (result8 != 0) self.sr &= 0xFFFB; // Clear Z
        if (bcd_carry == 1) self.sr |= 0x0011 else self.sr &= 0xFFEE;

        return;
    }

    // STOP: 0100 1110 0111 0010 (0x4E72)
    if (opcode == 0x4E72) {
        // Privileged
        if ((self.sr & 0x2000) == 0) {
            self.triggerException(bus, 8); // Privilege Violation
            return;
        }
        const imm = self.fetch16(bus);
        self.sr = imm;
        self.halted = true; // Stop fetch loop until interrupt
        self.cycles += 4;
        return;
    }

    // TRAPV: 0100 1110 0111 0110 (0x4E76)
    if (opcode == 0x4E76) {
        if ((self.sr & 0x0002) != 0) { // If V is set
            self.triggerException(bus, 7); // TRAPV exception
        }
        self.cycles += 4;
        return;
    }

    // MOVE to CCR: 0100 0100 11 EA (0x44C0+)
    if ((opcode & 0xFFC0) == 0x44C0) {
        const ea_mode = (opcode >> 3) & 0x7;
        const ea_reg = opcode & 0x7;
        var imm: u16 = 0;

        if (ea_mode == 0) {
            imm = @as(u16, @truncate(self.d[ea_reg]));
        } else if (ea_mode == 7 and ea_reg == 4) {
            imm = self.fetch16(bus);
        } else if (ea_mode == 2) {
            imm = bus.read16(self.a[ea_reg]);
        } else {
            self.trapUnimplemented(opcode);
            return;
        }

        const ccr = imm & 0xFF;
        self.sr = (self.sr & 0xFF00) | ccr;
        self.cycles += 12;
        return;
    }

    // MOVE to SR: 0100 0110 11 EA (0x46C0+)
    if ((opcode & 0xFFC0) == 0x46C0) {
        // Privileged
        if ((self.sr & 0x2000) == 0) {
            self.triggerException(bus, 8);
            return;
        }

        const ea_mode = (opcode >> 3) & 0x7;
        const ea_reg = opcode & 0x7;
        var imm: u16 = 0;

        if (ea_mode == 0) {
            imm = @as(u16, @truncate(self.d[ea_reg]));
        } else if (ea_mode == 7 and ea_reg == 4) {
            imm = self.fetch16(bus);
        } else {
            // Basic EA read
            if (ea_mode == 2) {
                imm = bus.read16(self.a[ea_reg]);
            } else {
                self.trapUnimplemented(opcode);
                return;
            }
        }

        self.sr = imm;
        self.cycles += 12;
        return;
    }

    // MOVE from SR: 0100 0000 11 EA (0x40C0+)
    if ((opcode & 0xFFC0) == 0x40C0) {
        // Privileged? No, on 68000 it is NOT privileged. 68010+ it is.
        // Genesis is 68000. So allowed.
        const ea_mode = (opcode >> 3) & 0x7;
        const ea_reg = opcode & 0x7;

        if (ea_mode == 0) { // Dn
            self.d[ea_reg] = (self.d[ea_reg] & 0xFFFF0000) | self.sr;
            self.cycles += 6; // ?
        } else if (ea_mode == 2) { // (An)
            bus.write16(self.a[ea_reg], self.sr);
            self.cycles += 8;
        } else {
            self.trapUnimplemented(opcode);
            return;
        }
        return;
    }

    self.trapUnimplemented(opcode);
}
