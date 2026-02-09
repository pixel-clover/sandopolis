const std = @import("std");
const Bus = @import("../../memory.zig").Bus;

pub const Cpu = struct {
    // Data Registers D0-D7
    d: [8]u32,
    // Address Registers A0-A7 (A7 is USP/SSP)
    a: [8]u32,
    // Program Counter
    pc: u32,
    // Status Register
    sr: u16,
    // User Stack Pointer (Shadow)
    usp: u32,

    // Internal state
    cycles: u64,
    halted: bool,

    // Interrupt handling
    interrupt_pending: bool,
    interrupt_level: u3, // 0-7, 0 = no interrupt

    // Debug: instruction history (last 20 PC/opcode pairs)
    history_pc: [20]u32,
    history_opcode: [20]u16,
    history_idx: u8,

    // Trace flag for debugging
    pub var trace_enabled: bool = true; // Enable for first 100 instructions

    pub fn init() Cpu {
        return Cpu{
            .d = [_]u32{0} ** 8,
            .a = [_]u32{0} ** 8,
            .pc = 0,
            .sr = 0,
            .usp = 0,
            .cycles = 0,
            .halted = false,
            .interrupt_pending = false,
            .interrupt_level = 0,
            .history_pc = [_]u32{0} ** 20,
            .history_opcode = [_]u16{0} ** 20,
            .history_idx = 0,
        };
    }

    /// Reset Exception (standard M68k reset)
    /// Reads SSP from 0x000000 and PC from 0x000004
    pub fn reset(self: *Cpu, bus: *Bus) void {
        self.a[7] = bus.read32(0x000000); // Initial SSP
        self.pc = bus.read32(0x000004); // Initial PC
        self.sr = 0x2700; // Supervisor mode, interrupts disabled
        self.cycles = 0;
        self.halted = false;

        // Validate vectors
        if (self.a[7] == 0 or self.a[7] > 0x01000000) {
            std.debug.print("WARNING: Invalid SSP: {X:0>8}, defaulting to 0x00FFFE00\n", .{self.a[7]});
            self.a[7] = 0x00FFFE00; // Default to top of RAM
        }

        if (self.pc == 0 or self.pc > 0x00400000) {
            std.debug.print("WARNING: Invalid PC: {X:0>8}, defaulting to 0x00000200\n", .{self.pc});
            self.pc = 0x00000200; // Default entry point
        }

        // Initialize unhandled exception vectors to safe handler
        // This prevents crashes when exceptions occur
        for (0..64) |i| {
            const vector_addr = @as(u32, @intCast(i * 4));
            if (vector_addr >= 0x08 and vector_addr < 0x100) { // Skip reset vectors
                const vector_value = bus.read32(vector_addr);
                if (vector_value == 0 or vector_value == 0xFFFFFFFF) {
                    // Uninitialized vector - point to safe RTS handler
                    // We can't write to ROM, so just log it
                    if (i < 10) { // Only log first few to avoid spam
                        std.debug.print("INFO: Uninitialized exception vector {d} at {X:0>8}\n", .{ i, vector_addr });
                    }
                }
            }
        }
    }

    /// Execute a single instruction cycle
    pub fn step(self: *Cpu, bus: *Bus) void {
        if (self.halted) return;

        // Check for pending interrupts before fetching instruction
        if (self.interrupt_pending) {
            self.processInterrupt(bus);
            return;
        }

        const current_pc = self.pc;

        const instructions = @import("instructions.zig");

        // Fetch opcode (16-bit)
        const opcode = self.fetch16(bus);

        // Record in history for crash debugging
        self.history_pc[self.history_idx] = current_pc;
        self.history_opcode[self.history_idx] = opcode;
        self.history_idx = (self.history_idx + 1) % 20;

        // Trace first 100 instructions for debugging
        if (trace_enabled and self.cycles < 2000) {
            std.debug.print("[{d:>3}] PC:{X:0>6} Op:{X:0>4} SP:{X:0>8} SR:{X:0>4}\n", .{ self.cycles, current_pc, opcode, self.a[7], self.sr });
        }

        // Top 4 bits determine the instruction category
        switch (opcode >> 12) {
            0x0 => instructions.execBit0(self, opcode, bus),
            0x1 => instructions.execBit1(self, opcode, bus),
            0x2 => instructions.execBit2(self, opcode, bus),
            0x3 => instructions.execBit3(self, opcode, bus),
            0x4 => instructions.execBit4(self, opcode, bus),
            0x5 => instructions.execBit5(self, opcode, bus),
            0x6 => instructions.execBit6(self, opcode, bus),
            0x7 => instructions.execBit7(self, opcode, bus),
            0x8 => instructions.execBit8(self, opcode, bus),
            0x9 => instructions.execBit9(self, opcode, bus),
            0xA => instructions.execBitA(self, opcode, bus),
            0xB => instructions.execBitB(self, opcode, bus),
            0xC => instructions.execBitC(self, opcode, bus),
            0xD => instructions.execBitD(self, opcode, bus),
            0xE => instructions.execBitE(self, opcode, bus),
            0xF => instructions.execBitF(self, opcode, bus),
            else => unreachable,
        }

        self.cycles += 1;
    }

    pub fn fetch16(self: *Cpu, bus: *Bus) u16 {
        const val = bus.read16(self.pc & 0x00FF_FFFF);
        self.pc = (self.pc +% 2) & 0x00FF_FFFF;
        return val;
    }

    pub fn fetch32(self: *Cpu, bus: *Bus) u32 {
        const val = bus.read32(self.pc & 0x00FF_FFFF);
        self.pc = (self.pc +% 4) & 0x00FF_FFFF;
        return val;
    }

    /// Calculate Effective Address for Index Mode (d8, An, Xn) or (d8, PC, Xn)
    /// Fetches the extension word and calculates address.
    /// base_addr should be the value of An or PC (PC pointing to extension word).
    pub fn calcIndexAddress(self: *Cpu, bus: *Bus, base_addr: u32) u32 {
        const ext = self.fetch16(bus);
        const da_bit = (ext >> 15) & 1;
        const reg_idx = (ext >> 12) & 7;
        const wl_bit = (ext >> 11) & 1;
        // scale (bits 9-10) is always 1 on 68000
        const disp8 = @as(i8, @bitCast(@as(u8, @truncate(ext))));

        var index_val: u32 = 0;
        if (da_bit == 0) { // Dn
            index_val = self.d[reg_idx];
        } else { // An
            index_val = self.a[reg_idx];
        }

        // Sign extend index based on W/L size
        if (wl_bit == 0) { // Word (sign extended)
            index_val = @as(u32, @bitCast(@as(i32, @as(i16, @bitCast(@as(u16, @truncate(index_val)))))));
        } // else Long (use full 32-bit value)

        return base_addr +% index_val +% @as(u32, @bitCast(@as(i32, disp8)));
    }

    pub fn push32(self: *Cpu, bus: *Bus, val: u32) void {
        self.a[7] -= 4;
        bus.write32(self.a[7], val);
    }

    pub fn pop32(self: *Cpu, bus: *Bus) u32 {
        const val = bus.read32(self.a[7]);
        self.a[7] += 4;
        return val;
    }

    pub fn push16(self: *Cpu, bus: *Bus, val: u16) void {
        self.a[7] -= 2;
        bus.write16(self.a[7], val);
    }

    pub fn pop16(self: *Cpu, bus: *Bus) u16 {
        const val = bus.read16(self.a[7]);
        self.a[7] += 2;
        return val;
    }

    /// Request a hardware interrupt
    pub fn requestInterrupt(self: *Cpu, level: u3) void {
        if (level == 0) return; // Level 0 = no interrupt

        // Check if interrupt level is higher than current mask in SR
        const current_mask = @as(u3, @intCast((self.sr >> 8) & 0x7));

        if (level > current_mask or level == 7) { // Level 7 (NMI) is non-maskable
            self.interrupt_pending = true;
            self.interrupt_level = level;
        }
    }

    /// Process a pending interrupt
    fn processInterrupt(self: *Cpu, bus: *Bus) void {
        if (!self.interrupt_pending) return;

        const level = self.interrupt_level;
        self.interrupt_pending = false;

        // Save current SR and PC
        self.push32(bus, self.pc);
        self.push32(bus, @as(u32, self.sr));

        // Set supervisor mode and update interrupt mask
        self.sr |= 0x2000; // Set supervisor bit
        self.sr = (self.sr & 0xF8FF) | (@as(u16, level) << 8); // Update interrupt mask

        // Auto-vectored interrupts: vectors at 0x60 + (level * 4)
        const vector_addr = 0x60 + (@as(u32, level) * 4);
        const handler_addr = bus.read32(vector_addr);

        if (trace_enabled and self.cycles < 100) {
            std.debug.print("INTERRUPT: Level {d}, Vector {X:0>8} -> {X:0>8}\n", .{ level, vector_addr, handler_addr });
        }

        self.pc = handler_addr;
        self.cycles += 44; // Interrupt processing cycles
    }

    /// Trigger an exception (trap, CHK, division by zero, etc.)
    pub fn triggerException(self: *Cpu, bus: *Bus, vector_number: u8) void {
        // Save current SR and PC
        // 68000 Exception Frame:
        // SP-4 <- PC (Long)
        // SP-6 <- SR (Word)
        // SP = SP - 6
        self.push32(bus, self.pc);
        self.push16(bus, self.sr);

        // Set supervisor mode
        self.sr |= 0x2000; // Set supervisor bit

        // Read exception vector and jump
        const vector_addr = @as(u32, vector_number) * 4;
        const handler_addr = bus.read32(vector_addr);

        if (trace_enabled and self.cycles < 100) {
            std.debug.print("EXCEPTION: Vector {d} at {X:0>8} -> {X:0>8}\n", .{ vector_number, vector_addr, handler_addr });
        }

        // Check if vector is valid
        if (handler_addr == 0 or handler_addr == 0xFFFFFFFF) {
            std.debug.print("ERROR: Uninitialized exception vector {d}! Halting.\n", .{vector_number});
            self.halted = true;
            return;
        }

        // Dump History
        std.debug.print("Last Instructions:\n", .{});
        for (0..20) |i| {
            const idx = (self.history_idx + i) % 20;
            if (self.history_opcode[idx] != 0) {
                std.debug.print("  PC: {X:0>8} -> {X:0>4}\n", .{ self.history_pc[idx], self.history_opcode[idx] });
            }
        }

        self.pc = handler_addr;
        self.cycles += 34; // Exception processing cycles
    }

    pub fn debugDump(self: *const Cpu) void {
        std.debug.print("PC: {X:0>8} SR: {X:0>4} SP: {X:0>8}\n", .{ self.pc, self.sr, self.a[7] });
        for (0..8) |i| {
            std.debug.print("D{d}: {X:0>8} A{d}: {X:0>8}\n", .{ i, self.d[i], i, self.a[i] });
        }
    }

    /// Trap on the first unimplemented opcode
    pub fn trapUnimplemented(self: *Cpu, opcode: u16) void {
        if (self.halted) return;
        self.halted = true;

        std.debug.print("\n==== UNIMPLEMENTED OPCODE ====\n", .{});
        std.debug.print("Opcode: {X:0>4} at PC: {X:0>8}\n", .{ opcode, self.pc - 2 });

        // Show register state
        std.debug.print("\nRegister State:\n", .{});
        std.debug.print("SR: {X:0>4} SP: {X:0>8}\n", .{ self.sr, self.a[7] });
        for (0..8) |i| {
            std.debug.print("D{d}: {X:0>8}  A{d}: {X:0>8}\n", .{ i, self.d[i], i, self.a[i] });
        }

        // Show last 10 instructions executed
        std.debug.print("\nLast 10 Instructions:\n", .{});
        var count: u8 = 0;
        var idx = self.history_idx;
        while (count < 10) : (count += 1) {
            if (idx == 0) idx = 20;
            idx -= 1;

            if (self.history_pc[idx] != 0) {
                std.debug.print("  PC: {X:0>6} -> {X:0>4}\n", .{ self.history_pc[idx], self.history_opcode[idx] });
            }
        }
        std.debug.print("==============================\n\n", .{});
    }

    // --- Flag Helpers ---

    pub fn updateN(self: *Cpu, val: anytype, size: u8) void {
        const msb: u1 = switch (size) {
            1 => @intCast((@as(u8, @intCast(val)) >> 7) & 1),
            2 => @intCast((@as(u16, @intCast(val)) >> 15) & 1),
            4 => @intCast((@as(u32, @intCast(val)) >> 31) & 1),
            else => 0,
        };
        if (msb == 1) {
            self.sr |= 0x0008; // Set N
        } else {
            self.sr &= 0xFFF7; // Clear N
        }
    }

    pub fn updateZ(self: *Cpu, val: anytype, size: u8) void {
        const masked: u32 = switch (size) {
            1 => @as(u8, @intCast(val)),
            2 => @as(u16, @intCast(val)),
            4 => @as(u32, @intCast(val)),
            else => @as(u32, @intCast(val)),
        };
        if (masked == 0) {
            self.sr |= 0x0004; // Set Z
        } else {
            self.sr &= 0xFFFB; // Clear Z
        }
    }

    pub fn updateFlagsAdd(self: *Cpu, src: anytype, dest: anytype, result: anytype, size: u8) void {
        self.updateN(result, size);
        self.updateZ(result, size);

        var sm: u1 = 0;
        var dm: u1 = 0;
        var rm: u1 = 0;

        if (size == 1) {
            sm = @intCast((@as(u8, @intCast(src)) >> 7) & 1);
            dm = @intCast((@as(u8, @intCast(dest)) >> 7) & 1);
            rm = @intCast((@as(u8, @intCast(result)) >> 7) & 1);
        } else if (size == 2) {
            sm = @intCast((@as(u16, @intCast(src)) >> 15) & 1);
            dm = @intCast((@as(u16, @intCast(dest)) >> 15) & 1);
            rm = @intCast((@as(u16, @intCast(result)) >> 15) & 1);
        } else {
            sm = @intCast((@as(u32, @intCast(src)) >> 31) & 1);
            dm = @intCast((@as(u32, @intCast(dest)) >> 31) & 1);
            rm = @intCast((@as(u32, @intCast(result)) >> 31) & 1);
        }

        // V = (Sm & Dm & !Rm) | (!Sm & !Dm & Rm)
        const v = (sm & dm & ~rm) | (~sm & ~dm & rm);
        if ((v & 1) == 1) self.sr |= 0x0002 else self.sr &= 0xFFFD;

        // C = (Sm & Dm) | (!Rm & Dm) | (Sm & !Rm)
        const c = (sm & dm) | (~rm & dm) | (sm & ~rm);
        if ((c & 1) == 1) {
            self.sr |= 0x0001; // C
            self.sr |= 0x0010; // X
        } else {
            self.sr &= 0xFFFE; // C
            self.sr &= 0xFFEF; // X
        }
    }

    pub fn updateFlagsSub(self: *Cpu, dest: anytype, src: anytype, result: anytype, size: u8) void {
        // Sub: Dest - Src = Result
        self.updateN(result, size);
        self.updateZ(result, size);

        // Calculate overflow and borrow flags properly
        const overflow = blk: {
            if (size == 1) {
                const s = @as(u8, @intCast(src));
                const d = @as(u8, @intCast(dest));
                const r = @as(u8, @intCast(result));
                const sm = (s >> 7) & 1;
                const dm = (d >> 7) & 1;
                const rm = (r >> 7) & 1;
                // V = (!Sm & Dm & !Rm) | (Sm & !Dm & Rm)
                break :blk ((~sm & dm & ~rm) | (sm & ~dm & rm)) & 1;
            } else if (size == 2) {
                const s = @as(u16, @intCast(src));
                const d = @as(u16, @intCast(dest));
                const r = @as(u16, @intCast(result));
                const sm = (s >> 15) & 1;
                const dm = (d >> 15) & 1;
                const rm = (r >> 15) & 1;
                break :blk ((~sm & dm & ~rm) | (sm & ~dm & rm)) & 1;
            } else {
                const s = @as(u32, @intCast(src));
                const d = @as(u32, @intCast(dest));
                const r = @as(u32, @intCast(result));
                const sm = (s >> 31) & 1;
                const dm = (d >> 31) & 1;
                const rm = (r >> 31) & 1;
                break :blk ((~sm & dm & ~rm) | (sm & ~dm & rm)) & 1;
            }
        };

        // Borrow (carry): C = (Sm & !Dm) | (Rm & !Dm) | (Sm & Rm)
        const carry = blk: {
            if (size == 1) {
                const s = @as(u8, @intCast(src));
                const d = @as(u8, @intCast(dest));
                const r = @as(u8, @intCast(result));
                const sm = (s >> 7) & 1;
                const dm = (d >> 7) & 1;
                const rm = (r >> 7) & 1;
                break :blk ((sm & ~dm) | (rm & ~dm) | (sm & rm)) & 1;
            } else if (size == 2) {
                const s = @as(u16, @intCast(src));
                const d = @as(u16, @intCast(dest));
                const r = @as(u16, @intCast(result));
                const sm = (s >> 15) & 1;
                const dm = (d >> 15) & 1;
                const rm = (r >> 15) & 1;
                break :blk ((sm & ~dm) | (rm & ~dm) | (sm & rm)) & 1;
            } else {
                const s = @as(u32, @intCast(src));
                const d = @as(u32, @intCast(dest));
                const r = @as(u32, @intCast(result));
                const sm = (s >> 31) & 1;
                const dm = (d >> 31) & 1;
                const rm = (r >> 31) & 1;
                break :blk ((sm & ~dm) | (rm & ~dm) | (sm & rm)) & 1;
            }
        };

        if (overflow == 1) self.sr |= 0x0002 else self.sr &= 0xFFFD;
        if (carry == 1) {
            self.sr |= 0x0001; // C
            self.sr |= 0x0010; // X
        } else {
            self.sr &= 0xFFFE; // C
            self.sr &= 0xFFEF; // X
        }
    }

    pub fn checkCondition(self: *const Cpu, c: u4) bool {
        const C: u1 = @intCast((self.sr >> 0) & 1);
        const V: u1 = @intCast((self.sr >> 1) & 1);
        const Z: u1 = @intCast((self.sr >> 2) & 1);
        const N: u1 = @intCast((self.sr >> 3) & 1);

        return switch (c) {
            0x0 => true, // T
            0x1 => false, // F
            0x2 => (C == 0 and Z == 0), // HI
            0x3 => (C == 1 or Z == 1), // LS
            0x4 => (C == 0), // CC
            0x5 => (C == 1), // CS
            0x6 => (Z == 0), // NE
            0x7 => (Z == 1), // EQ
            0x8 => (V == 0), // VC
            0x9 => (V == 1), // VS
            0xA => (N == 0), // PL
            0xB => (N == 1), // MI
            0xC => ((N ^ V) == 0), // GE (N & V) | (!N & !V) == !(N^V)
            0xD => ((N ^ V) == 1), // LT
            0xE => (Z == 0 and (N ^ V) == 0), // GT
            0xF => (Z == 1 or (N ^ V) == 1), // LE
        };
    }
};
