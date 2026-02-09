const std = @import("std");

pub const Vdp = struct {
    vram: [64 * 1024]u8,
    cram: [128]u8, // 64 colors * 2 bytes (9-bit color stored as word)
    vsram: [80]u8, // 40 entries * 2 bytes
    regs: [32]u8, // 24 defined, safe to have 32

    // Output Buffer (320x224 RGB888 or RGBA8888)
    framebuffer: [320 * 224]u32,

    // Internal State
    code: u8, // Command Code (CD0-CD5)
    addr: u16, // Address Register (16-bit enough for VRAM 64k)
    pending_command: bool, // Second half of command word pending
    command_word: u32,

    // Status Flags (Mock)
    vblank: bool,
    hblank: bool,
    odd_frame: bool,
    pal_mode: bool,

    dma_active: bool,

    // DMA State
    dma_fill: bool,
    dma_source_addr: u32,
    dma_length: u16,

    // Timing for V-BLANK
    scanline: u16, // Current scanline (0-261 for NTSC)

    pub fn init() Vdp {
        return Vdp{
            .vram = [_]u8{0} ** (64 * 1024),
            .cram = [_]u8{0} ** 128,
            .vsram = [_]u8{0} ** 80,
            .regs = [_]u8{0} ** 32,
            .framebuffer = [_]u32{0} ** (320 * 224),
            .code = 0,
            .addr = 0,
            .pending_command = false,
            .command_word = 0,
            .vblank = false,
            .hblank = false,
            .dma_active = false,
            .odd_frame = false,
            .pal_mode = false,
            .dma_fill = false,
            .dma_source_addr = 0,
            .dma_length = 0,
            .scanline = 0,
        };
    }

    fn getPaletteColor(self: *const Vdp, index: u8) u32 {
        // Index is 0-63. CRAM is 128 bytes.
        // Each entry is 2 bytes: 0000 BBB GGG RRR
        const offset = @as(usize, index) * 2;
        const val_hi = self.cram[offset];
        const val_lo = self.cram[offset + 1];
        const color = (@as(u16, val_hi) << 8) | val_lo;

        // Extract 3-bit components (0-7)
        // R: bits 1-3
        // G: bits 5-7
        // B: bits 9-11

        const b3 = (color >> 9) & 0x7;
        const g3 = (color >> 5) & 0x7;
        const r3 = (color >> 1) & 0x7;

        // Scale to 8-bit (0-255).
        // 0->0, 7->255.  Simple shift: val << 5 | val << 2?
        // Standard Genesis expansion:
        // 000->0, 001->36, 010->73... 111->255?
        // Simple: x * 36

        const r8: u32 = @intCast(r3 * 36);
        const g8: u32 = @intCast(g3 * 36);
        const b8: u32 = @intCast(b3 * 36);

        // ABGR or ARGB? SDL uses Packed U32.
        // If texture format is RGBA8888 ?
        // Let's assume ABGR for Little Endian (R G B A) -> 0xAABBGGRR
        return (0xFF000000) | (b8 << 16) | (g8 << 8) | r8;
    }

    pub fn renderScanline(self: *Vdp, line: u16) void {
        if (line >= 224) return;

        // Plane A Table Address
        // Defined by Reg[2] (bits 3-5 -> shifted left 10? + bits 13-15?)
        // Standard: (Reg[2] & 0x38) << 10.  Ex: 0x38 -> 0xE000??
        // Wait, Reg 2 value * 0x400.
        const plane_a_base = @as(u32, self.regs[2] & 0x38) << 10;

        // For line 'line', which row of tiles is it?
        const tile_row = line / 8;
        const fine_y = line % 8;

        // Plane width (assume 64 tiles for now, Reg 16 determines it)
        const plane_width_tiles = 64;

        // Screen width 320 -> 40 tiles.
        for (0..40) |col| {
            // Fetch Name Table Entry
            // 2 bytes per entry
            // Pattern Index (11 bits), Palette (2 bits), Priority (1), FlipXY (2)
            const row_offset = (tile_row * plane_width_tiles * 2);
            const col_offset = (col * 2);
            const addr = (plane_a_base + row_offset + col_offset) & 0xFFFF;

            const entry_hi = self.vram[addr];
            const entry_lo = self.vram[addr + 1];
            const entry = (@as(u16, entry_hi) << 8) | entry_lo;

            const pattern_idx = entry & 0x07FF;
            const palette_idx = (entry >> 13) & 0x3;
            const vflip = (entry & 0x1000) != 0;
            const hflip = (entry & 0x0800) != 0;

            // Fetch Pattern Data
            // Each tile is 32 bytes (4 bytes per line x 8 lines)
            const pattern_addr = (@as(u32, pattern_idx) * 32);

            // Effective line depending on vflip
            const eff_y = if (vflip) (7 - fine_y) else fine_y;
            const line_offset = pattern_addr + (@as(u32, eff_y) * 4); // 4 bytes per row (8 pixels, 4 bits each -> 32 bits = 4 bytes)

            // Read 8 pixels (4 bytes)
            const p0 = self.vram[(line_offset + 0) & 0xFFFF];
            const p1 = self.vram[(line_offset + 1) & 0xFFFF];
            const p2 = self.vram[(line_offset + 2) & 0xFFFF];
            const p3 = self.vram[(line_offset + 3) & 0xFFFF];

            // Decode 8 pixels
            // Byte 0: [P0 P1]
            const pixels = [_]u8{
                (p0 >> 4) & 0xF, p0 & 0xF,
                (p1 >> 4) & 0xF, p1 & 0xF,
                (p2 >> 4) & 0xF, p2 & 0xF,
                (p3 >> 4) & 0xF, p3 & 0xF,
            };

            for (0..8) |px| {
                const x_in_tile = if (hflip) (7 - px) else px;
                const color_idx = pixels[x_in_tile];

                // Palette Offset: CRAM + (PaletteIdx * 32) + (ColorIdx * 2)
                // Total 64 colors. 4 Palettes of 16 colors.
                // Index into getPaletteColor (0-63)
                const final_idx = (@as(u8, @intCast(palette_idx)) * 16) + color_idx;

                const offset_x = (col * 8) + px;
                self.framebuffer[@as(usize, line) * 320 + offset_x] = self.getPaletteColor(final_idx);
            }
        }
    }

    // 0xC00000 - Data Port
    pub fn readData(self: *Vdp) u16 {
        // Read auto-increments address
        defer self.advanceAddr();

        switch (self.code & 0xF) { // Mask to relevant bits
            0x0 => { // VRAM Read
                const val_hi = self.vram[self.addr & 0xFFFF];
                const val_lo = self.vram[(self.addr + 1) & 0xFFFF];
                return (@as(u16, val_hi) << 8) | val_lo;
            },
            0x8 => { // CRAM Read
                const idx = self.addr & 0x7F; // 128 bytes
                const val_hi = self.cram[idx];
                const val_lo = self.cram[idx + 1];
                return (@as(u16, val_hi) << 8) | val_lo;
            },
            0x4 => { // VSRAM Read
                const idx = self.addr & 0x4F; // 80 bytes
                const val_hi = self.vsram[idx];
                const val_lo = self.vsram[idx + 1];
                return (@as(u16, val_hi) << 8) | val_lo;
            },
            else => return 0,
        }
    }

    pub fn writeData(self: *Vdp, value: u16) void {
        defer self.advanceAddr();

        // Code determines target:
        // 0001 (1): VRAM Write
        // 0011 (3): CRAM Write
        // 0101 (5): VSRAM Write

        switch (self.code & 0xF) {
            0x1 => { // VRAM Write
                // M68k writes byte-swapped? No, VRAM is byte-array.
                // Address is byte address.
                self.vram[self.addr & 0xFFFF] = @intCast((value >> 8) & 0xFF);
                self.vram[(self.addr + 1) & 0xFFFF] = @intCast(value & 0xFF);
            },
            0x3 => { // CRAM Write
                const idx = self.addr & 0x7F;
                self.cram[idx] = @intCast((value >> 8) & 0xFF);
                self.cram[idx + 1] = @intCast(value & 0xFF);
            },
            0x5 => { // VSRAM Write
                const idx = self.addr & 0x4F;
                self.vsram[idx] = @intCast((value >> 8) & 0xFF);
                self.vsram[idx + 1] = @intCast(value & 0xFF);
            },
            else => {
                // Ignore or handle DMA?
            },
        }
    }

    fn advanceAddr(self: *Vdp) void {
        const auto_inc = self.regs[15];
        self.addr = self.addr +% auto_inc;
    }

    // 0xC00004 - Control Port
    pub fn readControl(self: *Vdp) u16 {
        // Status Register Layout:
        // Bit 15-14: Always 0
        // Bit 13-12: Always 1
        // Bit 11-10: Always 0
        // Bit 9:  FIFO Empty (1=Empty)
        // Bit 8:  FIFO Full (1=Full)
        // Bit 7:  VInt Pending
        // Bit 6:  Sprite Overflow
        // Bit 5:  Sprite Collision
        // Bit 4:  Odd Frame
        // Bit 3:  VBlank (1=Active)
        // Bit 2:  HBlank (1=Active)
        // Bit 1:  DMA Busy (1=Active)
        // Bit 0:  PAL/NTSC (1=PAL, 0=NTSC)

        // Base Status: 0011 0100 0000 0000 -> 0x3400 (bits 13-12 = 1, FIFO Empty)
        var status: u16 = 0x3400;

        // Add status flags
        if (self.vblank) status |= 0x0008; // Bit 3
        if (self.hblank) status |= 0x0004; // Bit 2
        if (self.dma_active) status |= 0x0002; // Bit 1
        if (self.pal_mode) status |= 0x0001; // Bit 0
        if (self.odd_frame) status |= 0x0010; // Bit 4

        // Clear pending command on status read
        self.pending_command = false;

        return status;
    }

    /// Update VDP timing (call this every scanline or frame)
    pub fn step(self: *Vdp, cycles: u32) void {
        _ = cycles;

        // Simple scanline counter (NTSC: 262 lines, PAL: 312 lines)
        const max_scanlines: u16 = if (self.pal_mode) 312 else 262;

        self.scanline += 1;
        if (self.scanline >= max_scanlines) {
            self.scanline = 0;
            self.odd_frame = !self.odd_frame;
        }

        // V-BLANK occurs at scanline 224-261 (NTSC)
        if (self.scanline >= 224 and self.scanline < 261) {
            if (!self.vblank) {
                self.vblank = true;
                // V-BLANK interrupt should be requested here
            }
        } else {
            self.vblank = false;
        }

        // H-BLANK occurs during horizontal retrace (not implemented precisely)
        self.hblank = false; // Simplified
    }

    /// Check if V-BLANK interrupt should fire
    pub fn shouldFireVBlankInterrupt(self: *const Vdp) bool {
        // Check if interrupts are enabled in register 1, bit 5
        const int_enabled = (self.regs[1] & 0x20) != 0;
        return self.vblank and int_enabled;
    }

    pub fn writeControl(self: *Vdp, value: u16) void {
        // Check for Register Write: 10xx xxxx xxxx xxxx
        if ((value & 0xC000) == 0x8000) {
            // Register Write (Mode Set)
            const reg = (value >> 8) & 0x1F;
            const data = value & 0xFF;
            if (reg < self.regs.len) {
                self.regs[reg] = @intCast(data);
            }
            // Code & Address are NOT changed by Register writes!
            self.code = 0; // Or reset? Docs say "Code is not affected"?
            self.pending_command = false; // Reset pending state
            return;
        }

        if (!self.pending_command) {
            // First word of command
            // Format: CD1 CD0 A13 A12 ... A1 A0 0 0
            // Save it
            self.command_word = (@as(u32, value) << 16);
            self.pending_command = true;

            // Provide partial address/code update?
            // "The VDP updates the address register and code register after the first word is written."
            // But incomplete.
        } else {
            // Second word of command
            // Format: ? ? ? ? ? ? ? ? ? ? CD5 CD4 CD3 CD2 0 0
            // Actually it's complex swizzle.

            self.command_word |= value;
            self.pending_command = false;

            // Decode Code & Address
            // Full 32-bit Command:
            // bits 31..30: CD1 CD0
            // bits 29..16: A13..A0
            // bits 15..8:  Unused?
            // bits 7..4:   CD5..CD2
            // bits 3..0:   Unused?

            // Standard VDP address swizzling:
            // Addr = (Cmd & 0x3FFF0000) >> 16  | (Cmd & 0x00000003) << 14
            // Code = (Cmd & 0xC0000000) >> 30  | (Cmd & 0x000000F0) >> 2

            // Wait, my write16/write32 passes 'value' to writeControl.
            // If CPU writes 32-bit: It writes Hi Word then Lo Word.
            // My write32 splits it.

            // Correct Swizzle logic:
            // First write (Hi): CD1 CD0 A13 ... A0
            // Second write (Lo): CD5 CD4 CD3 CD2 0 0 A15 A14

            // Let's use the standard formula:
            // Address = ((Hi & 0x3) << 14) | ((Hi >> 2) & 0x3FFF)? NO.

            // Let's look at the Genesis VDP doc:
            // Command Long:
            // C1 C0 A13 A12 A11 A10 A09 A08 A07 A06 A05 A04 A03 A02 A01 A00
            // 0  0  0   0   0   0   0   0   C5  C4  C3  C2  0   0   A15 A14

            // Code = (C5..C0)
            // Address = (A15..A0)

            const hi = (self.command_word >> 16);
            const lo = (self.command_word & 0xFFFF);

            const cd0_1 = (hi >> 14) & 0x3;
            const cd2_5 = (lo >> 4) & 0xF;
            self.code = @intCast((cd2_5 << 2) | cd0_1);

            const a0_13 = (hi & 0x3FFF);
            const a14_15 = (lo & 0x3);
            self.addr = @intCast((a14_15 << 14) | a0_13);

            // Check for DMA
            if ((self.code & 0x20) != 0) {
                // DMA Designated
                // Mode determined by Reg 23 (bits 7,6)
                // 00,01: Memory to VRAM (CPU Transfer? No, DMA)
                // 10: VRAM Fill
                // 11: VRAM Copy
                const dma_mode = (self.regs[23] >> 6) & 0x3;

                // DMA Source Address (Regs 21, 22, 23)
                // 21: High byte of lo word
                // 22: Low byte of hi word
                // 23: High byte of hi word (bits 0-6)

                const dma_src_lo = self.regs[21];
                const dma_src_mid = self.regs[22];
                const dma_src_hi = self.regs[23] & 0x7F;
                self.dma_source_addr = (@as(u32, dma_src_hi) << 17) | (@as(u32, dma_src_mid) << 9) | (@as(u32, dma_src_lo) << 1);

                // DMA Length (Regs 19, 20)
                self.dma_length = (@as(u16, self.regs[19]) << 8) | self.regs[20];

                if (dma_mode <= 1) {
                    // Memory to VRAM Transfer
                    // Needs access to Bus! Vdp struct doesn't have Bus access.
                    // IMPORTANT: In a real emulator, the VDP often requests the bus or the CPU pushes data.
                    // Here, we might need a callback or just set a flag for the main loop to handle?
                    // Or, since we don't have cyclic dependency issues if we pass 'bus' to a method...
                    // But 'step' or 'writeData' is called from Bus.
                    // Let's set a flag "dma_active" and handle it in 'step' or a specific 'doDma' function.
                    self.dma_active = true;
                } else if (dma_mode == 2) {
                    // Fill
                    self.dma_fill = true;
                    self.dma_active = true;
                    // Fill uses the data port write to trigger.
                } else {
                    // Copy
                    self.dma_active = true; // Todo
                }
            }
        }
    }

    pub fn debugDump(self: *const Vdp) void {
        std.debug.print("VDP Code: {X} Addr: {X:0>4} Reg[1]: {X} Reg[15]: {X}\n", .{ self.code, self.addr, self.regs[1], self.regs[15] });
    }
};
