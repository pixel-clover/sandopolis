const std = @import("std");
const Cpu = @import("../cpu.zig").Cpu;
const Bus = @import("../../../memory.zig").Bus;

pub fn execBit5(self: *Cpu, opcode: u16, bus: *Bus) void {
    // ADDQ/SUBQ, Scc, DBcc
    // DBcc: 0101 cccc 1100 1ddd
    // cccc = Condition
    // ddd = Register

    // Check for DBcc signature: 0101 xxxx 1100 1xxx -> 5xxC8 + reg?
    // Mask: 1111 0000 1111 1000 -> F0F8 matches 50C8?
    // Logic: if ((opcode & 0xF0F8) == 0x50C8)

    if ((opcode & 0xF0F8) == 0x50C8) {
        const cond: u4 = @intCast((opcode >> 8) & 0xF);
        const reg_idx: u4 = @intCast(opcode & 0x7);

        const cc_met = self.checkCondition(cond);
        if (!cc_met) {
            // Decrement count
            // Word operation on Dn
            const old_val = @as(u16, @truncate(self.d[reg_idx]));
            const new_val = old_val -% 1;
            // Preserve high word, update low word
            self.d[reg_idx] = (self.d[reg_idx] & 0xFFFF0000) | new_val;

            if (new_val != 0xFFFF) { // -1 in u16
                // Branch
                const disp = self.fetch16(bus);
                const signed_disp = @as(i16, @bitCast(disp));
                self.pc = (self.pc - 2) +% @as(u32, @bitCast(@as(i32, signed_disp)));
                self.cycles += 10;
            } else {
                // Fallthrough (counter expired)
                self.pc += 2; // Skip displacement
                self.cycles += 14;
            }
        } else {
            // Condition True: Fallthrough
            self.pc += 2; // Skip displacement
            self.cycles += 12;
        }
        return;
    }

    // ADDQ/SUBQ: 0101 data(3) op(1) sz(2) mode(3) reg(3)
    // op: 0=ADDQ, 1=SUBQ
    // data: 1-8 (0 encodes 8)
    // sz: 00=Byte, 01=Word, 10=Long

    // Scc: 0101 cccc 11xx xxxx (0x50C0-0x5FFF except DBcc which is 0x50C8-0x5FC8)
    // Check if it's Scc: mode must not be 001 (An direct not allowed)
    if ((opcode & 0xF0C0) == 0x50C0) {
        const cond: u4 = @intCast((opcode >> 8) & 0xF);
        const ea_mode = (opcode >> 3) & 0x7;
        const ea_reg = opcode & 0x7;

        // Mode 001 is An direct - not valid for Scc, it's DBcc
        if (ea_mode == 1) {
            // This is DBcc, already handled above
            self.trapUnimplemented(opcode);
            return;
        }

        const condition_met = self.checkCondition(cond);
        const value: u8 = if (condition_met) 0xFF else 0x00;

        // Write to destination
        if (ea_mode == 0) { // Dn
            self.d[ea_reg] = (self.d[ea_reg] & 0xFFFFFF00) | value;
            self.cycles += if (condition_met) 6 else 4;
        } else if (ea_mode == 2) { // (An)
            const addr = self.a[ea_reg];
            bus.write8(addr, value);
            self.cycles += 12;
        } else if (ea_mode == 7 and ea_reg == 1) { // Abs.L
            const addr = self.fetch32(bus);
            bus.write8(addr, value);
            self.cycles += 20;
        } else {
            self.trapUnimplemented(opcode);
            return;
        }
        return;
    }

    const data_field = @as(u4, @intCast((opcode >> 9) & 0x7));
    const data = if (data_field == 0) @as(u32, 8) else @as(u32, data_field);
    const is_sub = ((opcode >> 8) & 1) == 1;
    const size = @as(u2, @intCast((opcode >> 6) & 0x3));
    const mode = @as(u3, @intCast((opcode >> 3) & 0x7));
    const reg = @as(u3, @intCast(opcode & 0x7));

    if (size == 3) {
        // Invalid size
        self.trapUnimplemented(opcode);
        return;
    }

    // Handle different addressing modes
    if (mode == 0) { // Dn
        const old_val = self.d[reg];
        var result: u32 = 0;

        if (size == 0) { // Byte
            const val8 = @as(u8, @truncate(old_val));
            const res8 = if (is_sub) val8 -% @as(u8, @truncate(data)) else val8 +% @as(u8, @truncate(data));
            result = (old_val & 0xFFFFFF00) | res8;

            if (is_sub) {
                self.updateFlagsSub(val8, @as(u8, @truncate(data)), res8, 1);
            } else {
                self.updateFlagsAdd(@as(u8, @truncate(data)), val8, res8, 1);
            }
        } else if (size == 1) { // Word
            const val16 = @as(u16, @truncate(old_val));
            const res16 = if (is_sub) val16 -% @as(u16, @truncate(data)) else val16 +% @as(u16, @truncate(data));
            result = (old_val & 0xFFFF0000) | res16;

            if (is_sub) {
                self.updateFlagsSub(val16, @as(u16, @truncate(data)), res16, 2);
            } else {
                self.updateFlagsAdd(@as(u16, @truncate(data)), val16, res16, 2);
            }
        } else { // Long
            result = if (is_sub) old_val -% data else old_val +% data;

            if (is_sub) {
                self.updateFlagsSub(old_val, data, result, 4);
            } else {
                self.updateFlagsAdd(data, old_val, result, 4);
            }
        }

        self.d[reg] = result;
        self.cycles += if (size == 2) 8 else 4;
        return;
    } else if (mode == 1) { // An - Address register (no flags affected, word/long only)
        if (size == 0) {
            // Byte operation on An is invalid
            self.trapUnimplemented(opcode);
            return;
        }

        const old_val = self.a[reg];
        // For word operations, sign extend the data
        const operand = if (size == 1) @as(u32, @bitCast(@as(i32, @as(i16, @bitCast(@as(u16, @truncate(data))))))) else data;
        self.a[reg] = if (is_sub) old_val -% operand else old_val +% operand;
        self.cycles += 8;
        return;
    } else {
        // Memory Modes - Data Alterable
        var addr: u32 = 0;
        var valid_ea = true;

        if (mode == 2) { // (An)
            addr = self.a[reg];
            self.cycles += 8; // Base for memory
        } else if (mode == 3) { // (An)+
            addr = self.a[reg];
            const inc: u32 = if (size == 0 and reg == 7) 2 else if (size == 0) 1 else if (size == 1) 2 else 4;
            self.a[reg] +%= inc;
            self.cycles += 8;
        } else if (mode == 4) { // -(An)
            const dec: u32 = if (size == 0 and reg == 7) 2 else if (size == 0) 1 else if (size == 1) 2 else 4;
            self.a[reg] -%= dec;
            addr = self.a[reg];
            self.cycles += 10;
        } else if (mode == 5) { // (d16, An)
            const disp = @as(i16, @bitCast(self.fetch16(bus)));
            addr = self.a[reg] +% @as(u32, @bitCast(@as(i32, disp)));
            self.cycles += 12;
        } else if (mode == 6) { // (d8, An, Xn)
            addr = self.calcIndexAddress(bus, self.a[reg]);
            self.cycles += 14;
        } else if (mode == 7) {
            if (reg == 0) { // Abs.W
                const w = self.fetch16(bus);
                addr = @as(u32, @bitCast(@as(i32, @as(i16, @bitCast(w)))));
                self.cycles += 12;
            } else if (reg == 1) { // Abs.L
                addr = self.fetch32(bus);
                self.cycles += 16;
            } else {
                valid_ea = false;
            }
        } else {
            valid_ea = false;
        }

        if (!valid_ea) {
            std.debug.print("ADDQ/SUBQ invalid/unimplemented EA mode {d} reg {d}\n", .{ mode, reg });
            self.trapUnimplemented(opcode);
            return;
        }

        // Perform RMW
        if (size == 0) { // Byte
            const old_val = bus.read8(addr);
            const res8 = if (is_sub) old_val -% @as(u8, @truncate(data)) else old_val +% @as(u8, @truncate(data));
            bus.write8(addr, res8);

            if (is_sub) {
                self.updateFlagsSub(old_val, @as(u8, @truncate(data)), res8, 1);
            } else {
                self.updateFlagsAdd(@as(u8, @truncate(data)), old_val, res8, 1);
            }
            self.cycles += 4; // Add write cycles? Standard says 8/12 etc for op. My base above + 4 for write?
            // "Add 4 cycles for byte/word, 8 for long" - Is this for the arithmetic?
            // Existing (An) code: 12 cycles total for Byte.
            // My (An) above: 8. + 4 here = 12. Correct.
        } else if (size == 1) { // Word
            const old_val = bus.read16(addr);
            const res16 = if (is_sub) old_val -% @as(u16, @truncate(data)) else old_val +% @as(u16, @truncate(data));
            bus.write16(addr, res16);

            if (is_sub) {
                self.updateFlagsSub(old_val, @as(u16, @truncate(data)), res16, 2);
            } else {
                self.updateFlagsAdd(@as(u16, @truncate(data)), old_val, res16, 2);
            }
            self.cycles += 4;
        } else { // Long
            const old_val = bus.read32(addr);
            const result = if (is_sub) old_val -% data else old_val +% data;
            bus.write32(addr, result);

            if (is_sub) {
                self.updateFlagsSub(old_val, data, result, 4);
            } else {
                self.updateFlagsAdd(data, old_val, result, 4);
            }
            self.cycles += 12; // 20 total for (An). 8 + 12 = 20. Correct.
        }
        return;
    }

    // Other addressing modes not yet implemented
    self.trapUnimplemented(opcode);
}
