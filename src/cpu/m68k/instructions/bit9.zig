const std = @import("std");
const Cpu = @import("../cpu.zig").Cpu;
const Bus = @import("../../../memory.zig").Bus;

pub fn execBit9(self: *Cpu, opcode: u16, bus: *Bus) void {
    // SUB/SUBA
    // SUB: 1001 Reg OpMode EA
    // SUBA: 1001 Reg x11/111 EA (word/long from address register)
    const reg_idx: u4 = @intCast((opcode >> 9) & 0x7);
    const op_mode: u3 = @intCast((opcode >> 6) & 0x7);
    const ea_reg: u4 = @intCast(opcode & 0x7);
    const ea_mode: u4 = @intCast((opcode >> 3) & 0x7);

    // Check for SUBA: opmode = x11 or x111 (011, 111)
    if (op_mode == 3 or op_mode == 7) {
        // SUBA <ea>, An
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
                const word_val = bus.read16(addr);
                src_val = @as(u32, @bitCast(@as(i32, @as(i16, @bitCast(word_val)))));
                self.cycles += 10;
            }
        } else {
            std.debug.print("Unimplemented SUBA EA mode {d}\n", .{ea_mode});
            return;
        }

        // Subtract from address register (no flags affected)
        self.a[reg_idx] = self.a[reg_idx] -% src_val;
        return;
    }

    // SUBX: 1001 Rx 1 sz 00 M Ry
    // M=0: Dx,Dy   M=1: -(Ax),-(Ay)
    if ((opcode & 0xF130) == 0x9100) {
        const rx = @as(u3, @intCast((opcode >> 9) & 0x7));
        const size = @as(u2, @intCast((opcode >> 6) & 0x3));
        const mem = ((opcode >> 3) & 1) == 1;
        const ry = @as(u3, @intCast(opcode & 0x7));

        if (size == 3) {
            std.debug.print("Invalid SUBX size\n", .{});
            return;
        }

        const x_bit = (self.sr >> 4) & 1;

        if (!mem) { // Dx, Dy
            if (size == 0) { // Byte
                const src = @as(u8, @truncate(self.d[ry]));
                const dst = @as(u8, @truncate(self.d[rx]));
                const result = dst -% src -% @as(u8, @intCast(x_bit));
                self.d[rx] = (self.d[rx] & 0xFFFFFF00) | result;

                const old_z = (self.sr >> 2) & 1;
                self.updateFlagsSub(dst, src, result, 1);
                if (old_z == 1 and result == 0) {
                    self.sr |= 0x0004;
                }
                self.cycles += 4;
            } else if (size == 1) { // Word
                const src = @as(u16, @truncate(self.d[ry]));
                const dst = @as(u16, @truncate(self.d[rx]));
                const result = dst -% src -% @as(u16, @intCast(x_bit));
                self.d[rx] = (self.d[rx] & 0xFFFF0000) | result;

                const old_z = (self.sr >> 2) & 1;
                self.updateFlagsSub(dst, src, result, 2);
                if (old_z == 1 and result == 0) {
                    self.sr |= 0x0004;
                }
                self.cycles += 4;
            } else { // Long
                const src = self.d[ry];
                const dst = self.d[rx];
                const result = dst -% src -% x_bit;
                self.d[rx] = result;

                const old_z = (self.sr >> 2) & 1;
                self.updateFlagsSub(dst, src, result, 4);
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
                const result = dst -% src -% @as(u8, @intCast(x_bit));
                bus.write8(self.a[rx], result);

                const old_z = (self.sr >> 2) & 1;
                self.updateFlagsSub(dst, src, result, 1);
                if (old_z == 1 and result == 0) {
                    self.sr |= 0x0004;
                }
                self.cycles += 18;
            } else if (size == 1) { // Word
                self.a[ry] -%= 2;
                self.a[rx] -%= 2;
                const src = bus.read16(self.a[ry]);
                const dst = bus.read16(self.a[rx]);
                const result = dst -% src -% @as(u16, @intCast(x_bit));
                bus.write16(self.a[rx], result);

                const old_z = (self.sr >> 2) & 1;
                self.updateFlagsSub(dst, src, result, 2);
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

                const result = dst -% src -% x_bit;

                // Write result back high word first, then low word
                bus.write16(self.a[rx], @truncate(result >> 16));
                bus.write16(self.a[rx] +% 2, @truncate(result));

                const old_z = (self.sr >> 2) & 1;
                self.updateFlagsSub(dst, src, result, 4);
                if (old_z == 1 and result == 0) {
                    self.sr |= 0x0004;
                }
                self.cycles += 30;
            }
        }
        return;
    }

    // Standard SUB
    if (ea_mode == 0 and op_mode <= 2) {
        const src_val = self.d[ea_reg];
        const dest_val = self.d[reg_idx];
        var result: u32 = 0;

        // Update X, N, Z, V, C
        // Logic: Dest - Source

        if (op_mode == 0) { // Byte
            const s8 = @as(u8, @truncate(src_val));
            const d8 = @as(u8, @truncate(dest_val));
            const r8 = d8 -% s8;
            result = (dest_val & 0xFFFFFF00) | r8;
            self.updateFlagsSub(d8, s8, r8, 1);
        } else if (op_mode == 1) { // Word
            const s16 = @as(u16, @truncate(src_val));
            const d16 = @as(u16, @truncate(dest_val));
            const r16 = d16 -% s16;
            result = (dest_val & 0xFFFF0000) | r16;
            self.updateFlagsSub(d16, s16, r16, 2);
        } else { // Long
            const r32 = dest_val -% src_val;
            result = r32;
            self.updateFlagsSub(dest_val, src_val, r32, 4);
        }

        self.d[reg_idx] = result;
        self.cycles += 4;
        return;
    }
    std.debug.print("Unimplemented Opcode (Bit 9 - SUB): {X:0>4} at PC: {X:0>8}\n", .{ opcode, self.pc - 2 });
}
