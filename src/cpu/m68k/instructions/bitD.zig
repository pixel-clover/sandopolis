const std = @import("std");
const Cpu = @import("../cpu.zig").Cpu;
const Bus = @import("../../../memory.zig").Bus;

pub fn execBitD(self: *Cpu, opcode: u16, bus: *Bus) void {
    // ADD/ADDA
    // ADD: 1101 Reg OpMode EA
    // ADDA: 1101 Reg x11/111 EA (word/long to address register)
    const reg_idx: u4 = @intCast((opcode >> 9) & 0x7);
    const op_mode: u3 = @intCast((opcode >> 6) & 0x7);
    const ea_reg: u4 = @intCast(opcode & 0x7);
    const ea_mode: u4 = @intCast((opcode >> 3) & 0x7);

    // Check for ADDA: opmode = x11 or x111 (011, 111)
    if (op_mode == 3 or op_mode == 7) {
        // ADDA <ea>, An
        const size_long = (op_mode == 7);
        var src_val: u32 = 0;

        // Read source
        if (ea_mode == 0) { // Dn
            src_val = if (size_long) self.d[ea_reg] else @as(u32, @bitCast(@as(i32, @as(i16, @bitCast(@as(u16, @truncate(self.d[ea_reg])))))));
            self.cycles += if (size_long) 8 else 8;
        } else if (ea_mode == 1) { // An
            src_val = if (size_long) self.a[ea_reg] else @as(u32, @bitCast(@as(i32, @as(i16, @bitCast(@as(u16, @truncate(self.a[ea_reg])))))));
            self.cycles += if (size_long) 8 else 8;
        } else if (ea_mode == 7 and ea_reg == 4) { // Immediate
            if (size_long) {
                src_val = self.fetch32(bus);
                self.cycles += 16;
            } else {
                const word_val = self.fetch16(bus);
                src_val = @as(u32, @bitCast(@as(i32, @as(i16, @bitCast(word_val)))));
                self.cycles += 8;
            }
        } else if (ea_mode == 2) { // (An)
            const addr = self.a[ea_reg];
            if (size_long) {
                src_val = bus.read32(addr);
                self.cycles += 14;
            } else {
                src_val = @as(u32, @bitCast(@as(i32, @as(i16, @bitCast(bus.read16(addr))))));
                self.cycles += 10;
            }
        } else {
            std.debug.print("Unimplemented ADDA EA mode {d}\n", .{ea_mode});
            return;
        }

        // Add to address register (no flags affected)
        self.a[reg_idx] = self.a[reg_idx] +% src_val;
        return;
    }

    // ADDX: 1101 Rx 1 sz 00 M Ry
    // M=0: Dx,Dy   M=1: -(Ax),-(Ay)
    // Size: 00=Byte, 01=Word, 10=Long
    if ((opcode & 0xF130) == 0xD100) {
        const rx = @as(u3, @intCast((opcode >> 9) & 0x7));
        const size = @as(u2, @intCast((opcode >> 6) & 0x3));
        const mem = ((opcode >> 3) & 1) == 1;
        const ry = @as(u3, @intCast(opcode & 0x7));

        if (size == 3) {
            std.debug.print("Invalid ADDX size\n", .{});
            return;
        }

        const x_bit = (self.sr >> 4) & 1;

        if (!mem) { // Dx, Dy
            if (size == 0) { // Byte
                const src = @as(u8, @truncate(self.d[ry]));
                const dst = @as(u8, @truncate(self.d[rx]));
                const result = dst +% src +% @as(u8, @intCast(x_bit));
                self.d[rx] = (self.d[rx] & 0xFFFFFF00) | result;

                // Update flags - Z is special: only cleared if result != 0
                const old_z = (self.sr >> 2) & 1;
                self.updateFlagsAdd(src, dst, result, 1);
                if (old_z == 1 and result == 0) {
                    self.sr |= 0x0004; // Keep Z set
                }
                self.cycles += 4;
            } else if (size == 1) { // Word
                const src = @as(u16, @truncate(self.d[ry]));
                const dst = @as(u16, @truncate(self.d[rx]));
                const result = dst +% src +% @as(u16, @intCast(x_bit));
                self.d[rx] = (self.d[rx] & 0xFFFF0000) | result;

                const old_z = (self.sr >> 2) & 1;
                self.updateFlagsAdd(src, dst, result, 2);
                if (old_z == 1 and result == 0) {
                    self.sr |= 0x0004;
                }
                self.cycles += 4;
            } else { // Long
                const src = self.d[ry];
                const dst = self.d[rx];
                const result = dst +% src +% x_bit;
                self.d[rx] = result;

                const old_z = (self.sr >> 2) & 1;
                self.updateFlagsAdd(src, dst, result, 4);
                if (old_z == 1 and result == 0) {
                    self.sr |= 0x0004;
                }
                self.cycles += 8;
            }
        } else { // -(Ax), -(Ay)
            if (size == 0) { // Byte
                self.a[ry] -%= if (ry == 7) 2 else 1;
                self.a[rx] -%= if (rx == 7) 2 else 1;
                const src = bus.read8(self.a[ry]);
                const dst = bus.read8(self.a[rx]);
                const result = dst +% src +% @as(u8, @intCast(x_bit));
                bus.write8(self.a[rx], result);

                const old_z = (self.sr >> 2) & 1;
                self.updateFlagsAdd(src, dst, result, 1);
                if (old_z == 1 and result == 0) {
                    self.sr |= 0x0004;
                }
                self.cycles += 18;
            } else if (size == 1) { // Word
                self.a[ry] -%= 2;
                self.a[rx] -%= 2;
                const src = bus.read16(self.a[ry]);
                const dst = bus.read16(self.a[rx]);
                const result = dst +% src +% @as(u16, @intCast(x_bit));
                bus.write16(self.a[rx], result);

                const old_z = (self.sr >> 2) & 1;
                self.updateFlagsAdd(src, dst, result, 2);
                if (old_z == 1 and result == 0) {
                    self.sr |= 0x0004;
                }
                self.cycles += 18;
            } else { // Long
                // For long word predecrement, must read/write in correct order
                // Decrement by 2 twice and read low word first, then high word
                self.a[ry] = self.a[ry] -% 2;
                const src_low = bus.read16(self.a[ry]);
                self.a[ry] = self.a[ry] -% 2;
                const src_high = bus.read16(self.a[ry]);
                const src = (@as(u32, src_high) << 16) | src_low;

                self.a[rx] = self.a[rx] -% 2;
                const dst_low = bus.read16(self.a[rx]);
                self.a[rx] = self.a[rx] -% 2;
                const dst_high = bus.read16(self.a[rx]);
                const dst = (@as(u32, dst_high) << 16) | dst_low;

                const result = dst +% src +% x_bit;

                // Write result back high word first, then low word
                bus.write16(self.a[rx], @truncate(result >> 16));
                bus.write16(self.a[rx] +% 2, @truncate(result));

                const old_z = (self.sr >> 2) & 1;
                self.updateFlagsAdd(src, dst, result, 4);
                if (old_z == 1 and result == 0) {
                    self.sr |= 0x0004;
                }
                self.cycles += 30;
            }
        }
        return;
    }

    // Standard ADD
    // OpMode 0-2: ADD <ea>, Dn
    // OpMode 4-6: ADD Dn, <ea>
    if (op_mode <= 2 or (op_mode >= 4 and op_mode <= 6)) {
        var src_val: u32 = 0;
        var dest_val: u32 = 0;
        var result: u32 = 0;
        var size_bytes: u32 = 0;

        // Determine Size
        if (op_mode == 0 or op_mode == 4) size_bytes = 1; // Byte
        if (op_mode == 1 or op_mode == 5) size_bytes = 2; // Word
        if (op_mode == 2 or op_mode == 6) size_bytes = 4; // Long

        if (op_mode <= 2) {
            // ADD <ea>, Dn
            // Source is EA, Dest is Dn
            dest_val = self.d[reg_idx]; // Dn

            // Read Source from EA
            // Supports all Data Addressing Modes (All except An)
            // (Byte mode: Dn, (An), (An)+, -(An), d16, Idx, Abs, Imm, PC types)
            // (An is valid for Word/Long? No, ADD <ea> is Data Addressing Modes usually?
            // Docs: Source Effective Address: All modes.
            // Wait, byte mode usually forbids An.
            // Let's implement generic read.

            if (ea_mode == 0) { // Dn
                if (size_bytes == 1) src_val = @as(u8, @truncate(self.d[ea_reg]));
                if (size_bytes == 2) src_val = @as(u16, @truncate(self.d[ea_reg]));
                if (size_bytes == 4) src_val = self.d[ea_reg];
                self.cycles += if (size_bytes == 4) 6 else 4;
            } else if (ea_mode == 1) { // An
                // Valid for Word/Long only?
                if (size_bytes == 1) {
                    // Byte disallowed for An direct?? Usually yes.
                    // But for now let's assume valid or treat as 0?
                    // Standard 68k DOES NOT ALLOW An source for byte operations?
                    // Actually "Data addressing modes" usually allows An? No, "Data" means not An.
                    // "All addressing modes" allows An.
                    // ADD docs say: Source <ea>: All modes.
                    // But usually byte operation on An is not allowed.
                    // If size is byte, fetch 16, use low 8?
                    // Let's assume it's allowed if valid instruction encoding exists.
                    // But typically '1101 ... 001 ...' -> An is valid.
                    src_val = @as(u8, @truncate(self.a[ea_reg]));
                } else if (size_bytes == 2) {
                    src_val = @as(u16, @truncate(self.a[ea_reg]));
                } else {
                    src_val = self.a[ea_reg];
                }
                self.cycles += if (size_bytes == 4) 8 else 8; // ?
            } else if (ea_mode == 2) { // (An)
                const addr = self.a[ea_reg];
                if (size_bytes == 1) {
                    src_val = bus.read8(addr);
                    self.cycles += 8;
                }
                if (size_bytes == 2) {
                    src_val = bus.read16(addr);
                    self.cycles += 8;
                }
                if (size_bytes == 4) {
                    src_val = bus.read32(addr);
                    self.cycles += 14;
                }
            } else if (ea_mode == 3) { // (An)+
                const addr = self.a[ea_reg];
                const inc = if (size_bytes == 1 and ea_reg == 7) 2 else size_bytes;
                self.a[ea_reg] +%= inc;
                if (size_bytes == 1) {
                    src_val = bus.read8(addr);
                    self.cycles += 8;
                }
                if (size_bytes == 2) {
                    src_val = bus.read16(addr);
                    self.cycles += 8;
                }
                if (size_bytes == 4) {
                    src_val = bus.read32(addr);
                    self.cycles += 14;
                }
            } else if (ea_mode == 4) { // -(An)
                const dec = if (size_bytes == 1 and ea_reg == 7) 2 else size_bytes;
                self.a[ea_reg] -%= dec;
                const addr = self.a[ea_reg];
                if (size_bytes == 1) {
                    src_val = bus.read8(addr);
                    self.cycles += 10;
                }
                if (size_bytes == 2) {
                    src_val = bus.read16(addr);
                    self.cycles += 10;
                }
                if (size_bytes == 4) {
                    src_val = bus.read32(addr);
                    self.cycles += 16;
                }
            } else if (ea_mode == 5) { // (d16, An)
                const disp = @as(i16, @bitCast(self.fetch16(bus)));
                const addr = self.a[ea_reg] +% @as(u32, @bitCast(@as(i32, disp)));
                if (size_bytes == 1) {
                    src_val = bus.read8(addr);
                    self.cycles += 12;
                }
                if (size_bytes == 2) {
                    src_val = bus.read16(addr);
                    self.cycles += 12;
                }
                if (size_bytes == 4) {
                    src_val = bus.read32(addr);
                    self.cycles += 18;
                }
            } else if (ea_mode == 6) { // (d8, An, Xn)
                const addr = self.calcIndexAddress(bus, self.a[ea_reg]);
                if (size_bytes == 1) {
                    src_val = bus.read8(addr);
                    self.cycles += 14;
                }
                if (size_bytes == 2) {
                    src_val = bus.read16(addr);
                    self.cycles += 14;
                }
                if (size_bytes == 4) {
                    src_val = bus.read32(addr);
                    self.cycles += 20;
                }
            } else if (ea_mode == 7) {
                var addr: u32 = 0;
                if (ea_reg == 0) { // Abs.W
                    const w = self.fetch16(bus);
                    addr = @as(u32, @bitCast(@as(i32, @as(i16, @bitCast(w)))));
                    self.cycles += if (size_bytes == 4) 18 else 12;
                } else if (ea_reg == 1) { // Abs.L
                    addr = self.fetch32(bus);
                    self.cycles += if (size_bytes == 4) 22 else 16;
                } else if (ea_reg == 2) { // PC+d16
                    const disp = @as(i16, @bitCast(self.fetch16(bus)));
                    addr = (self.pc - 2) +% @as(u32, @bitCast(@as(i32, disp)));
                    self.cycles += if (size_bytes == 4) 18 else 12;
                } else if (ea_reg == 3) { // PC+d8+Xn
                    addr = self.calcIndexAddress(bus, self.pc - 2);
                    self.cycles += if (size_bytes == 4) 20 else 14;
                } else if (ea_reg == 4) { // Immediate
                    if (size_bytes == 1) src_val = self.fetch16(bus) & 0xFF;
                    if (size_bytes == 2) src_val = self.fetch16(bus);
                    if (size_bytes == 4) src_val = self.fetch32(bus);
                    self.cycles += if (size_bytes == 4) 16 else 8;
                    // Skip read
                    addr = 0xFFFFFFFF;
                }

                if (ea_reg != 4) {
                    if (size_bytes == 1) src_val = bus.read8(addr);
                    if (size_bytes == 2) src_val = bus.read16(addr);
                    if (size_bytes == 4) src_val = bus.read32(addr);
                }
            } else {
                self.trapUnimplemented(opcode);
                return;
            }

            // Perform Add
            if (size_bytes == 1) {
                const s8 = @as(u8, @truncate(src_val));
                const d8 = @as(u8, @truncate(dest_val));
                const r8 = d8 +% s8;
                result = (dest_val & 0xFFFFFF00) | r8;
                self.updateFlagsAdd(s8, d8, r8, 1);
            } else if (size_bytes == 2) {
                const s16 = @as(u16, @truncate(src_val));
                const d16 = @as(u16, @truncate(dest_val));
                const r16 = d16 +% s16;
                result = (dest_val & 0xFFFF0000) | r16;
                self.updateFlagsAdd(s16, d16, r16, 2);
            } else {
                const r32 = dest_val +% src_val;
                result = r32;
                self.updateFlagsAdd(src_val, dest_val, r32, 4);
            }

            self.d[reg_idx] = result;
            return;
        } else {
            // ADD Dn, <ea>
            // Source is Dn, Dest is EA
            src_val = self.d[reg_idx];

            // Read Dest from EA
            // Memory Alterable Modes ((An), (An)+, -(An), d16, Idx, Abs)

            var addr: u32 = 0;
            var valid_ea = true;

            if (ea_mode == 2) {
                addr = self.a[ea_reg];
            } else if (ea_mode == 3) {
                addr = self.a[ea_reg];
                const inc = if (size_bytes == 1 and ea_reg == 7) 2 else size_bytes;
                self.a[ea_reg] +%= inc;
            } else if (ea_mode == 4) {
                const dec = if (size_bytes == 1 and ea_reg == 7) 2 else size_bytes;
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
                    valid_ea = false;
                }
            } else {
                valid_ea = false;
            }

            if (!valid_ea) {
                self.trapUnimplemented(opcode);
                return;
            }

            // Read Dest, Add, Write Result
            if (size_bytes == 1) {
                const s8 = @as(u8, @truncate(src_val));
                const d8 = bus.read8(addr);
                const r8 = d8 +% s8;
                bus.write8(addr, r8);
                self.updateFlagsAdd(s8, d8, r8, 1);
                self.cycles += 12; // Base + 4? Approximate.
            } else if (size_bytes == 2) {
                const s16 = @as(u16, @truncate(src_val));
                const d16 = bus.read16(addr);
                const r16 = d16 +% s16;
                bus.write16(addr, r16);
                self.updateFlagsAdd(s16, d16, r16, 2);
                self.cycles += 12;
            } else {
                const d32 = bus.read32(addr);
                const r32 = d32 +% src_val;
                bus.write32(addr, r32);
                self.updateFlagsAdd(src_val, d32, r32, 4);
                self.cycles += 20;
            }
            return;
        }
    }

    std.debug.print("Unimplemented Opcode (Bit D): {X:0>4} at PC: {X:0>8}\n", .{ opcode, self.pc - 2 });
}
