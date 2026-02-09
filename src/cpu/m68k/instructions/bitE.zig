const std = @import("std");
const Cpu = @import("../cpu.zig").Cpu;
const Bus = @import("../../../memory.zig").Bus;

pub fn execBitE(self: *Cpu, opcode: u16, bus: *Bus) void {
    // Shift/Rotate Instructions
    // Opcode: 1110 cnt/reg(3) dr(1) sz(2) ir(1) ty(2) reg(3)
    // ty: 00=AS, 01=LS, 10=ROX, 11=RO
    // dr: 0=Right, 1=Left
    // sz: 0=Byte, 1=Word, 2=Long
    // ir: 0=Imm Count (1-8), 1=Reg Count (Dk % 64)

    // Memory Shifts: 1110 0 ty(2) dr(1) 11 <ea> (Word only)
    // 1110 0xx1 11xx xxxx for memory shifts
    if ((opcode & 0xFEC0) == 0xE0C0) {
        const ty = (opcode >> 9) & 0x3; // Shift type
        const dr = (opcode >> 8) & 1; // Direction: 0=Right, 1=Left
        const ea_mode = (opcode >> 3) & 0x7;
        const ea_reg = opcode & 0x7;

        // Read memory word
        var addr: u32 = 0;
        if (ea_mode == 2) { // (An)
            addr = self.a[ea_reg];
        } else if (ea_mode == 7 and ea_reg == 1) { // Abs.L
            addr = self.fetch32(bus);
        } else {
            std.debug.print("Unimpl Memory Shift EA mode {d}\n", .{ea_mode});
            return;
        }

        var val = bus.read16(addr);
        var c_bit: u1 = 0;
        var v_bit: u1 = 0;
        var x_bit: u1 = @intCast((self.sr >> 4) & 1);

        // Perform single shift/rotate (memory operations always shift by 1)
        if (ty == 0) { // AS - Arithmetic Shift
            if (dr == 0) { // ASR
                c_bit = @intCast(val & 1);
                x_bit = c_bit;
                const sign = val & 0x8000;
                val = (val >> 1) | sign; // Preserve sign bit
            } else { // ASL
                const old_msb = (val & 0x8000) != 0;
                c_bit = if (old_msb) 1 else 0;
                x_bit = c_bit;
                val <<= 1;
                const new_msb = (val & 0x8000) != 0;
                v_bit = if (old_msb != new_msb) 1 else 0;
            }
        } else if (ty == 1) { // LS - Logical Shift
            if (dr == 0) { // LSR
                c_bit = @intCast(val & 1);
                x_bit = c_bit;
                val >>= 1;
            } else { // LSL
                c_bit = if ((val & 0x8000) != 0) 1 else 0;
                x_bit = c_bit;
                val <<= 1;
            }
            v_bit = 0;
        } else if (ty == 2) { // ROX - Rotate through Extend
            if (dr == 0) { // ROXR
                const old_x = x_bit;
                c_bit = @intCast(val & 1);
                x_bit = c_bit;
                val >>= 1;
                if (old_x == 1) val |= 0x8000;
            } else { // ROXL
                const old_x = x_bit;
                c_bit = if ((val & 0x8000) != 0) 1 else 0;
                x_bit = c_bit;
                val <<= 1;
                if (old_x == 1) val |= 1;
            }
            v_bit = 0;
        } else { // ty == 3: RO - Rotate
            if (dr == 0) { // ROR
                c_bit = @intCast(val & 1);
                val = (val >> 1) | (if (c_bit == 1) @as(u16, 0x8000) else 0);
            } else { // ROL
                c_bit = if ((val & 0x8000) != 0) 1 else 0;
                val = (val << 1) | c_bit;
            }
            v_bit = 0;
        }

        // Write back
        bus.write16(addr, val);

        // Update flags
        self.updateN(val, 2);
        self.updateZ(val, 2);
        if (v_bit == 1) self.sr |= 0x0002 else self.sr &= 0xFFFD;
        if (c_bit == 1) self.sr |= 0x0001 else self.sr &= 0xFFFE;
        if (ty != 3) { // ROX updates X, RO doesn't
            if (x_bit == 1) self.sr |= 0x0010 else self.sr &= 0xFFEF;
        }

        self.cycles += 12;
        return;
    }

    const count_field = (opcode >> 9) & 0x7;
    const dr = (opcode >> 8) & 1; // 0=Right, 1=Left
    const sz = (opcode >> 6) & 0x3;
    const ir = (opcode >> 5) & 1;
    const ty = (opcode >> 3) & 0x3;
    const reg_idx = opcode & 0x7;

    if (sz == 3) {
        // Invalid size
        return;
    }

    var count: u32 = 0;
    if (ir == 0) {
        // Immediate count 1-8 (0 means 8)
        count = count_field;
        if (count == 0) count = 8;
    } else {
        // Register count
        count = self.d[count_field] & 63;
    }

    // Perform operation
    // Size:
    var val: u32 = 0;
    if (sz == 0) { // Byte
        val = self.d[reg_idx] & 0xFF;
    } else if (sz == 1) { // Word
        val = self.d[reg_idx] & 0xFFFF;
    } else { // Long
        val = self.d[reg_idx];
    }

    // Flags
    var c_bit: u1 = 0;
    var v_bit: u1 = 0;
    var x_bit: u1 = @intCast((self.sr >> 4) & 1); // Get existing X

    // Helper for updating Result
    // ...

    // Dispatch Type
    if (ty == 0) { // AS (Arithmetic Shift)
        // ASR (Right): Sign extension.
        // ASL (Left): Zeros in, but check overflow (V).

        if (dr == 0) { // ASR
            // Arith Right: Copies MSB.
            // Check sign
            // Use casting to signed integers for generic impl?
            // Or loop
            var temp = val;
            const msb_mask: u32 = if (sz == 0) 0x80 else if (sz == 1) 0x8000 else 0x80000000;
            const sign = (temp & msb_mask) != 0;

            if (count > 0) {
                // Get last bit shifted out -> C, X
                // For ASR, X/C is the last bit shifted out.
                // If count > size, it propagates sign.
                // If count=0, flags affected? C=0 in most docs, but here count > 0 is guaranteed by loop or logic?
                // M68k: count=0 -> C cleared, V cleared? (If reg count is 0)

                // Emulate loop for correctness
                for (0..count) |_| {
                    const out = temp & 1;
                    c_bit = @intCast(out);
                    x_bit = c_bit;
                    temp >>= 1;
                    if (sign) temp |= msb_mask;
                }
            } else {
                c_bit = 0; // "If count is zero, C is cleared"
            }
            val = temp;
            v_bit = 0; // ASR clears V
        } else { // ASL
            // Arith Left. Shift zero in LSB.
            // V is set if ANY bit shifted out differs from ANY bit shifted out? No.
            // V is set if the most significant bit is changed at any time during the shift operation.
            var temp = val;
            const msb_mask: u32 = if (sz == 0) 0x80 else if (sz == 1) 0x8000 else 0x80000000;

            if (count > 0) {
                for (0..count) |_| {
                    const old_msb = (temp & msb_mask) != 0;
                    const out: u1 = if (old_msb) 1 else 0;
                    c_bit = out;
                    x_bit = c_bit;
                    temp <<= 1;

                    // Check new MSB logic for V?
                    // Standard definition: V is set if the sign bit changes at any point.
                    // Wait, ASL shifts OUT the msb. The new msb comes from bit-1.
                    // "V is set if the most significant bit is changed at any time during the shift operation."
                    // Actually, V=1 if valid 2's complement number overflows.
                    // (sign bit changes).
                    // In loop: if old_msb != new_msb (after shift)?
                    const new_msb = (temp & msb_mask) != 0;
                    if (old_msb != new_msb) v_bit = 1;
                }
            } else {
                c_bit = 0;
                v_bit = 0;
            }
            val = temp;
        }
    } else if (ty == 1) { // LS (Logical Shift)
        // LSR (Right): 0 in MSB.
        // LSL (Left): 0 in LSB. Same as ASL but V is always 0.
        if (dr == 0) { // LSR
            if (count > 0) {
                for (0..count) |_| {
                    c_bit = @intCast(val & 1);
                    x_bit = c_bit;
                    val >>= 1;
                }
            } else {
                c_bit = 0;
            }
            v_bit = 0;
        } else { // LSL
            if (count > 0) {
                const msb_mask: u32 = if (sz == 0) 0x80 else if (sz == 1) 0x8000 else 0x80000000;
                for (0..count) |_| {
                    const out: u1 = if ((val & msb_mask) != 0) 1 else 0;
                    c_bit = @intCast(out);
                    x_bit = c_bit;
                    val <<= 1;
                }
            } else {
                c_bit = 0;
            }
            v_bit = 0;
        }
    } else {
        // RO/ROX (Simple Rotates)
        // Assume minimal impl for now (or no-op logic that won't crash)
        // std.debug.print("Unimpl Rotate Ty {d}\n", .{ty});
        // We'll just return for safety or implement standard rotate?
        // Let's implement ROL/ROR (Ty=3)
        if (ty == 3) { // RO
            if (dr == 0) { // ROR
                // Rotate Right
                if (count > 0) {
                    const width: u6 = if (sz == 0) 8 else if (sz == 1) 16 else 32;
                    // Optimize: val = (val >> count) | (val << (width-count))
                    // But we need C bit (last bit shifted out).
                    // Loop is safer for flags
                    for (0..count) |_| {
                        c_bit = @intCast(val & 1);
                        val >>= 1;
                        if (c_bit == 1) val |= (@as(u32, 1) << @as(u5, @intCast(width - 1)));
                    }
                } else {
                    c_bit = 0;
                }
                v_bit = 0;
            } else { // ROL
                if (count > 0) {
                    const msb_mask: u32 = if (sz == 0) 0x80 else if (sz == 1) 0x8000 else 0x80000000;
                    for (0..count) |_| {
                        c_bit = if ((val & msb_mask) != 0) 1 else 0;
                        val <<= 1;
                        if (c_bit == 1) val |= 1;
                    }
                } else {
                    c_bit = 0;
                }
                v_bit = 0;
            }
            v_bit = 0; // This line was added by the diff, outside the ROL/ROR branches but inside the RO block
        }
        // ROX (Ty=2) - Uses X bit
        else if (ty == 2) { // ROX - Rotate through X
            if (dr == 0) { // ROXR - Rotate Right through X
                if (count > 0) {
                    for (0..count) |_| {
                        const old_x = x_bit;
                        c_bit = @intCast(val & 1);
                        x_bit = c_bit;
                        val >>= 1;
                        // Put old X into MSB
                        if (sz == 0) {
                            if (old_x == 1) val |= 0x80;
                        } else if (sz == 1) {
                            if (old_x == 1) val |= 0x8000;
                        } else {
                            if (old_x == 1) val |= 0x80000000;
                        }
                    }
                } else {
                    c_bit = x_bit;
                }
            } else { // ROXL - Rotate Left through X
                if (count > 0) {
                    const msb_mask: u32 = if (sz == 0) 0x80 else if (sz == 1) 0x8000 else 0x80000000;
                    for (0..count) |_| {
                        const old_x = x_bit;
                        c_bit = if ((val & msb_mask) != 0) 1 else 0;
                        x_bit = c_bit;
                        val <<= 1;
                        // Put old X into LSB
                        if (old_x == 1) val |= 1;
                    }
                } else {
                    c_bit = x_bit;
                }
            }
            v_bit = 0;
        } else {
            // Unknown type
            return;
        }
    }

    // Mask Result
    if (sz == 0) val &= 0xFF;
    if (sz == 1) val &= 0xFFFF;

    // Write back
    if (sz == 0) {
        self.d[reg_idx] = (self.d[reg_idx] & 0xFFFFFF00) | (val & 0xFF);
    } else if (sz == 1) {
        self.d[reg_idx] = (self.d[reg_idx] & 0xFFFF0000) | (val & 0xFFFF);
    } else {
        self.d[reg_idx] = val;
    }

    // Update Flags
    self.updateN(val, if (sz == 0) 1 else if (sz == 1) 2 else 4);
    self.updateZ(val, if (sz == 0) 1 else if (sz == 1) 2 else 4);
    if (v_bit == 1) self.sr |= 0x0002 else self.sr &= 0xFFFD;
    if (c_bit == 1) self.sr |= 0x0001 else self.sr &= 0xFFFE;

    // X bit updated for AS, LS, ROX (not RO?)
    // Manual: RO -> X is NOT affected.
    // AS, LS, ROX -> X is affected.
    if (ty != 3) {
        if (x_bit == 1) self.sr |= 0x0010 else self.sr &= 0xFFEF;
    }

    self.cycles += (count * 2) + 6; // Approximate
}
