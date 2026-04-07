const std = @import("std");
const testing = std.testing;

/// SMS VDP (TMS9918A derivative, Mode 4).
/// 16KB VRAM, 32-byte CRAM, 11 registers, 256-pixel-wide output.
pub const SmsVdp = struct {
    vram: [16 * 1024]u8 = [_]u8{0} ** (16 * 1024),
    cram: [32]u8 = [_]u8{0} ** 32,
    regs: [11]u8 = default_regs,
    framebuffer: [framebuffer_width * max_framebuffer_height]u32 = [_]u32{0} ** (framebuffer_width * max_framebuffer_height),

    // Control port state
    control_latch: bool = false,
    control_word: u16 = 0,
    code: u2 = 0,
    addr: u14 = 0,
    read_buffer: u8 = 0,

    // Status
    status: u8 = 0,
    vint_pending: bool = false,
    hint_pending: bool = false,
    line_counter: u8 = 0,


    // Frame state
    scanline: u16 = 0,
    pal_mode: bool = false,

    pub const framebuffer_width: usize = 256;
    pub const max_framebuffer_height: usize = 240;

    const default_regs = [11]u8{ 0x06, 0x80, 0xFF, 0xFF, 0xFF, 0xFF, 0xFB, 0x00, 0x00, 0x00, 0xFF };

    // Status register bits
    const status_vint: u8 = 0x80;
    const status_sprite_overflow: u8 = 0x40;
    const status_sprite_collision: u8 = 0x20;

    pub fn init() SmsVdp {
        return .{};
    }

    pub fn reset(self: *SmsVdp) void {
        self.* = init();
    }

    // -- Display mode queries --

    pub fn activeVisibleLines(self: *const SmsVdp) u16 {
        return switch (self.displayMode()) {
            .mode_192 => 192,
            .mode_224 => 224,
            .mode_240 => 240,
        };
    }

    pub fn totalLines(self: *const SmsVdp) u16 {
        return if (self.pal_mode) 313 else 262;
    }

    pub fn screenWidth(_: *const SmsVdp) u16 {
        return 256;
    }

    const DisplayMode = enum { mode_192, mode_224, mode_240 };

    fn displayMode(self: *const SmsVdp) DisplayMode {
        const m1 = (self.regs[1] >> 4) & 1;
        const m4 = (self.regs[0] >> 2) & 1;
        if (m4 != 0) {
            const m2 = (self.regs[0] >> 1) & 1;
            const m3 = (self.regs[1] >> 3) & 1;
            if (m3 != 0 and m2 != 0 and m1 != 0) return .mode_224;
            if (m3 != 0 and m2 != 0 and m1 == 0) return .mode_240;
        }
        return .mode_192;
    }

    // -- VDP port interface --

    pub fn readData(self: *SmsVdp) u8 {
        self.control_latch = false;
        const value = self.read_buffer;
        self.read_buffer = self.vram[@as(u16, self.addr)];
        self.addr +%= 1;
        return value;
    }

    pub fn writeData(self: *SmsVdp, value: u8) void {
        self.control_latch = false;
        switch (self.code) {
            0, 1, 2 => {
                self.vram[@as(u16, self.addr)] = value;
            },
            3 => {
                self.cram[@as(u16, self.addr) & 0x1F] = value;
            },
        }
        self.read_buffer = value;
        self.addr +%= 1;
    }

    pub fn readControl(self: *SmsVdp) u8 {
        self.control_latch = false;
        const value = self.status;
        self.status = 0;
        self.vint_pending = false;
        self.hint_pending = false;
        return value;
    }

    pub fn writeControl(self: *SmsVdp, value: u8) void {
        if (!self.control_latch) {
            self.control_latch = true;
            self.control_word = (self.control_word & 0xFF00) | @as(u16, value);
            // Do NOT update addr here; it is only valid after both bytes are written.
        } else {
            self.control_latch = false;
            self.control_word = (@as(u16, value) << 8) | (self.control_word & 0x00FF);
            self.code = @truncate(value >> 6);
            self.addr = @truncate(self.control_word);

            switch (self.code) {
                0 => {
                    // VRAM read: pre-fill read buffer
                    self.read_buffer = self.vram[@as(u16, self.addr)];
                    self.addr +%= 1;
                },
                2 => {
                    // Register write
                    const reg_index = value & 0x0F;
                    if (reg_index < 11) {
                        self.regs[reg_index] = @truncate(self.control_word);
                    }
                },
                else => {},
            }
        }
    }

    // -- V/H counters --

    pub fn readVCounter(self: *const SmsVdp) u8 {
        const line = self.scanline;
        return switch (self.displayMode()) {
            .mode_192 => if (self.pal_mode)
                vCounterPal192(line)
            else
                vCounterNtsc192(line),
            .mode_224 => if (self.pal_mode)
                vCounterPal224(line)
            else
                vCounterNtsc224(line),
            .mode_240 => vCounterPal240(line),
        };
    }

    fn vCounterNtsc192(line: u16) u8 {
        if (line <= 0xDA) return @truncate(line);
        return @truncate(line -% 6);
    }

    fn vCounterPal192(line: u16) u8 {
        if (line <= 0xF2) return @truncate(line);
        return @truncate(line -% 57);
    }

    fn vCounterNtsc224(line: u16) u8 {
        if (line <= 0xEA) return @truncate(line);
        return @truncate(line -% 6);
    }

    fn vCounterPal224(line: u16) u8 {
        if (line <= 0xFF) return @truncate(line);
        if (line <= 0x102) return @truncate(line);
        return @truncate(line -% 57);
    }

    fn vCounterPal240(line: u16) u8 {
        if (line <= 0xFF) return @truncate(line);
        if (line <= 0x10A) return @truncate(line);
        return @truncate(line -% 57);
    }

    // -- Interrupts --

    pub fn isFrameInterruptEnabled(self: *const SmsVdp) bool {
        return (self.regs[1] & 0x20) != 0;
    }

    pub fn isLineInterruptEnabled(self: *const SmsVdp) bool {
        return (self.regs[0] & 0x10) != 0;
    }

    pub fn irqPending(self: *const SmsVdp) bool {
        return (self.vint_pending and self.isFrameInterruptEnabled()) or
            (self.hint_pending and self.isLineInterruptEnabled());
    }

    // -- Scanline processing --

    /// Advance VDP by one scanline. Returns true if entering vblank.
    pub fn stepScanline(self: *SmsVdp) bool {
        const visible_lines = self.activeVisibleLines();
        const total = self.totalLines();
        var entering_vblank = false;

        if (self.scanline < visible_lines) {
            // Active display: render and decrement line counter
            if (self.isDisplayEnabled()) {
                self.renderScanline(self.scanline);
            } else {
                self.renderBlankLine(self.scanline);
            }
            if (self.line_counter == 0) {
                self.line_counter = self.regs[10];
                self.hint_pending = true;
            } else {
                self.line_counter -= 1;
            }
        } else if (self.scanline == visible_lines) {
            // First vblank line
            entering_vblank = true;
            self.status |= status_vint;
            self.vint_pending = true;
            // Line counter continues to decrement once more, then reloads
            if (self.line_counter == 0) {
                self.line_counter = self.regs[10];
                self.hint_pending = true;
            } else {
                self.line_counter -= 1;
            }
        } else {
            // Vblank: reload line counter each line
            self.line_counter = self.regs[10];
        }

        self.scanline += 1;
        if (self.scanline >= total) {
            self.scanline = 0;
        }

        return entering_vblank;
    }

    pub fn beginFrame(self: *SmsVdp) void {
        self.scanline = 0;
    }

    pub fn isDisplayEnabled(self: *const SmsVdp) bool {
        return (self.regs[1] & 0x40) != 0;
    }

    fn isLeftColumnBlanked(self: *const SmsVdp) bool {
        return (self.regs[0] & 0x20) != 0;
    }

    fn isSpriteDouble(self: *const SmsVdp) bool {
        return (self.regs[1] & 0x01) != 0;
    }

    fn isTall(self: *const SmsVdp) bool {
        return (self.regs[1] & 0x02) != 0;
    }

    fn spriteHeight(self: *const SmsVdp) u8 {
        const base: u8 = if (self.isTall()) 16 else 8;
        return if (self.isSpriteDouble()) base * 2 else base;
    }

    pub fn nameTableBase(self: *const SmsVdp) u16 {
        return (@as(u16, self.regs[2] & 0x0E) << 10) | 0x0000;
    }

    fn spriteAttributeTableBase(self: *const SmsVdp) u16 {
        return @as(u16, self.regs[5] & 0x7E) << 7;
    }

    fn spritePatternBase(self: *const SmsVdp) u16 {
        // In Mode 4, bit 2 of register 6 selects pattern base: 0 = 0x0000, 1 = 0x2000
        return if ((self.regs[6] & 0x04) != 0) @as(u16, 0x2000) else 0;
    }

    fn backdropColor(self: *const SmsVdp) u32 {
        const index = (self.regs[7] & 0x0F) | 0x10; // Always palette 1
        return cramToRgba(self.cram[index]);
    }

    // -- Color conversion --

    fn cramToRgba(color: u8) u32 {
        // SMS CRAM: --BBGGRR (6-bit, 2 bits per channel)
        const r: u32 = @as(u32, color & 0x03) * 85; // Scale 0-3 to 0-255
        const g: u32 = @as(u32, (color >> 2) & 0x03) * 85;
        const b: u32 = @as(u32, (color >> 4) & 0x03) * 85;
        return (0xFF << 24) | (r << 16) | (g << 8) | b;
    }

    // -- Rendering --

    fn renderBlankLine(self: *SmsVdp, line: u16) void {
        const offset = @as(usize, line) * framebuffer_width;
        const bg = self.backdropColor();
        @memset(self.framebuffer[offset..][0..framebuffer_width], bg);
    }

    fn renderScanline(self: *SmsVdp, line: u16) void {
        const offset = @as(usize, line) * framebuffer_width;
        var line_buf: [framebuffer_width]u32 = undefined;
        var priority_buf: [framebuffer_width]bool = [_]bool{false} ** framebuffer_width;

        // Fill with backdrop
        const bg = self.backdropColor();
        @memset(&line_buf, bg);

        // Render background tiles
        self.renderBackground(line, &line_buf, &priority_buf);

        // Render sprites (behind priority tiles, in front of non-priority tiles)
        self.renderSprites(line, &line_buf, &priority_buf);

        // Left column blanking
        if (self.isLeftColumnBlanked()) {
            @memset(line_buf[0..8], bg);
        }

        @memcpy(self.framebuffer[offset..][0..framebuffer_width], &line_buf);
    }

    fn renderBackground(self: *SmsVdp, line: u16, line_buf: *[framebuffer_width]u32, priority_buf: *[framebuffer_width]bool) void {
        const name_base = self.nameTableBase();
        const visible_lines = self.activeVisibleLines();

        // Horizontal and vertical scroll
        const hscroll: u16 = self.regs[8];
        const vscroll: u16 = self.regs[9];

        const effective_y = (line +% vscroll) % (if (visible_lines > 192) @as(u16, 256) else @as(u16, 224));

        const row = effective_y / 8;
        const fine_y = @as(u3, @truncate(effective_y));

        for (0..32) |col_idx| {
            const col: u16 = @intCast(col_idx);
            // Horizontal scroll: shift columns right by hscroll pixels
            // The first two columns (0-1) are optionally not scrolled (register 0 bit 6)
            var screen_x: u16 = undefined;
            if (col_idx < 2 and (self.regs[0] & 0x40) != 0) {
                screen_x = col * 8;
            } else {
                screen_x = (col *% 8 +% hscroll) % 256;
            }

            // For vertical scroll: right two columns (24-31) can be locked
            var tile_row = row;
            var tile_fine_y = fine_y;
            if (col_idx >= 24 and (self.regs[0] & 0x80) != 0) {
                // No vertical scroll for right columns
                tile_row = line / 8;
                tile_fine_y = @truncate(line);
            }

            // Read name table entry
            const nt_offset = name_base + (tile_row * 64) + (col * 2);
            const entry_lo: u16 = self.vram[nt_offset & 0x3FFF];
            const entry_hi: u16 = self.vram[(nt_offset + 1) & 0x3FFF];
            const entry = entry_lo | (entry_hi << 8);

            const tile_index: u16 = entry & 0x01FF;
            const h_flip = (entry & 0x0200) != 0;
            const v_flip = (entry & 0x0400) != 0;
            const palette: u8 = if ((entry & 0x0800) != 0) 16 else 0;
            const priority = (entry & 0x1000) != 0;

            // Get tile row data (4bpp planar: 4 bytes per row)
            const y_in_tile: u16 = if (v_flip) 7 - @as(u16, tile_fine_y) else @as(u16, tile_fine_y);
            const tile_addr = (tile_index * 32) + (y_in_tile * 4);

            const b0 = self.vram[tile_addr & 0x3FFF];
            const b1 = self.vram[(tile_addr + 1) & 0x3FFF];
            const b2 = self.vram[(tile_addr + 2) & 0x3FFF];
            const b3 = self.vram[(tile_addr + 3) & 0x3FFF];

            for (0..8) |px_idx| {
                const bit: u3 = if (h_flip)
                    @intCast(px_idx)
                else
                    @intCast(7 - px_idx);

                const p0: u8 = (b0 >> bit) & 1;
                const p1: u8 = (b1 >> bit) & 1;
                const p2: u8 = (b2 >> bit) & 1;
                const p3: u8 = (b3 >> bit) & 1;
                const color_index = p0 | (p1 << 1) | (p2 << 2) | (p3 << 3);

                const sx = (screen_x +% @as(u16, @intCast(px_idx))) % 256;
                if (color_index != 0) {
                    line_buf[sx] = cramToRgba(self.cram[palette + color_index]);
                    priority_buf[sx] = priority;
                }
            }
        }
    }

    fn renderSprites(self: *SmsVdp, line: u16, line_buf: *[framebuffer_width]u32, priority_buf: *[framebuffer_width]bool) void {
        const sat_base = self.spriteAttributeTableBase();
        const pat_base = self.spritePatternBase();
        const height = self.spriteHeight();
        const is_double = self.isSpriteDouble();
        const tall = self.isTall();

        var sprite_count: u8 = 0;
        const max_sprites: u8 = 8;
        var sprite_drawn: [framebuffer_width]bool = [_]bool{false} ** framebuffer_width;

        // Scan SAT for sprites on this line
        for (0..64) |i| {
            const y_raw = self.vram[(sat_base + i) & 0x3FFF];

            // Y = 0xD0 terminates sprite processing in 192-line mode
            if (self.displayMode() == .mode_192 and y_raw == 0xD0) break;

            const y: u16 = @as(u16, y_raw) +% 1; // Sprite Y is offset by 1
            if (line < y or line >= y + @as(u16, height)) continue;

            if (sprite_count >= max_sprites) {
                self.status |= status_sprite_overflow;
                break;
            }

            // X and tile from second half of SAT
            const info_base = sat_base + 128 + (i * 2);
            var x: u16 = self.vram[info_base & 0x3FFF];
            var tile: u16 = self.vram[(info_base + 1) & 0x3FFF];

            // Early x shift
            if ((self.regs[0] & 0x08) != 0) {
                x -%= 8;
            }

            // Tall sprites: mask lower bit of tile index
            if (tall) {
                tile &= 0xFE;
            }

            var row_in_sprite = line - y;
            if (is_double) {
                row_in_sprite /= 2;
            }

            const tile_offset = if (row_in_sprite >= 8)
                ((tile + 1) * 32) + (@as(u16, @intCast(row_in_sprite - 8)) * 4)
            else
                (tile * 32) + (@as(u16, @intCast(row_in_sprite)) * 4);

            const tile_addr = pat_base + tile_offset;
            const b0 = self.vram[tile_addr & 0x3FFF];
            const b1 = self.vram[(tile_addr + 1) & 0x3FFF];
            const b2 = self.vram[(tile_addr + 2) & 0x3FFF];
            const b3 = self.vram[(tile_addr + 3) & 0x3FFF];

            const pixel_count: u8 = if (is_double) 16 else 8;
            for (0..pixel_count) |px_idx| {
                const base_px = if (is_double) @as(u8, @intCast(px_idx)) / 2 else @as(u8, @intCast(px_idx));
                const bit: u3 = @intCast(7 - base_px);
                const p0: u8 = (b0 >> bit) & 1;
                const p1: u8 = (b1 >> bit) & 1;
                const p2: u8 = (b2 >> bit) & 1;
                const p3: u8 = (b3 >> bit) & 1;
                const color_index = p0 | (p1 << 1) | (p2 << 2) | (p3 << 3);

                if (color_index == 0) continue;

                const sx = x +% @as(u16, @intCast(px_idx));
                if (sx >= 256) continue;

                // Priority: BG tiles with priority bit set are in front of sprites
                if (priority_buf[sx]) continue;

                // Sprite collision detection: if a sprite pixel was already drawn here
                if (sprite_drawn[sx]) {
                    self.status |= status_sprite_collision;
                } else {
                    sprite_drawn[sx] = true;
                }

                line_buf[sx] = cramToRgba(self.cram[16 + color_index]);
            }

            sprite_count += 1;
        }
    }
};

// -- Tests --

test "sms vdp init defaults" {
    const vdp = SmsVdp.init();
    try testing.expectEqual(@as(u16, 256), vdp.screenWidth());
    try testing.expectEqual(@as(u16, 192), vdp.activeVisibleLines());
    try testing.expect(!vdp.irqPending());
}

test "sms vdp control port register write" {
    var vdp = SmsVdp.init();
    // Write value 0x42 to register 1: first byte = value, second byte = 0x80 | reg
    vdp.writeControl(0x42);
    vdp.writeControl(0x80 | 0x01);
    try testing.expectEqual(@as(u8, 0x42), vdp.regs[1]);
}

test "sms vdp data port write to vram" {
    var vdp = SmsVdp.init();
    // Set address 0x0000, code 0 (VRAM read, but data write goes to VRAM for code 0-2)
    vdp.writeControl(0x00);
    vdp.writeControl(0x40); // code 1 = VRAM write
    vdp.writeData(0xAB);
    try testing.expectEqual(@as(u8, 0xAB), vdp.vram[0]);
}

test "sms vdp data port write to cram" {
    var vdp = SmsVdp.init();
    // Set address 0, code 3 (CRAM write)
    vdp.writeControl(0x00);
    vdp.writeControl(0xC0); // code 3
    vdp.writeData(0x15); // R=1, G=1, B=0
    try testing.expectEqual(@as(u8, 0x15), vdp.cram[0]);
}

test "sms vdp read status clears flags" {
    var vdp = SmsVdp.init();
    vdp.status = SmsVdp.status_vint | SmsVdp.status_sprite_overflow;
    vdp.vint_pending = true;
    const status = vdp.readControl();
    try testing.expectEqual(@as(u8, 0xC0), status);
    try testing.expectEqual(@as(u8, 0), vdp.status);
    try testing.expect(!vdp.vint_pending);
}

test "sms vdp v counter ntsc 192" {
    var vdp = SmsVdp.init();
    vdp.scanline = 0;
    try testing.expectEqual(@as(u8, 0), vdp.readVCounter());
    vdp.scanline = 0xDA;
    try testing.expectEqual(@as(u8, 0xDA), vdp.readVCounter());
    vdp.scanline = 0xDB;
    try testing.expectEqual(@as(u8, 0xD5), vdp.readVCounter());
}

test "sms vdp cram to rgba" {
    // R=3, G=0, B=0 -> 0x03
    const red = SmsVdp.cramToRgba(0x03);
    try testing.expectEqual(@as(u32, 0xFF_FF_00_00), red);
    // R=0, G=3, B=0 -> 0x0C
    const green = SmsVdp.cramToRgba(0x0C);
    try testing.expectEqual(@as(u32, 0xFF_00_FF_00), green);
    // R=0, G=0, B=3 -> 0x30
    const blue = SmsVdp.cramToRgba(0x30);
    try testing.expectEqual(@as(u32, 0xFF_00_00_FF), blue);
}

test "sms vdp sprite collision sets status flag" {
    var vdp = SmsVdp.init();
    vdp.regs[1] = 0x40; // Display enabled
    vdp.regs[5] = 0x7E; // SAT base = 0x3F00
    vdp.regs[6] = 0x00; // Pattern base = 0x0000

    const sat_base: u16 = 0x3F00;

    // Two sprites at same position, both on line 1 (Y=0 → displayed at Y+1=1)
    vdp.vram[sat_base] = 0x00; // sprite 0 Y=0
    vdp.vram[sat_base + 1] = 0x00; // sprite 1 Y=0
    vdp.vram[sat_base + 2] = 0xD0; // terminator

    vdp.vram[sat_base + 128] = 10; // sprite 0 X
    vdp.vram[sat_base + 129] = 0; // sprite 0 tile=0
    vdp.vram[sat_base + 130] = 10; // sprite 1 X (overlapping!)
    vdp.vram[sat_base + 131] = 0; // sprite 1 tile=0

    // Tile 0, row 0: make all 8 pixels non-transparent (color index 1)
    // 4bpp planar: byte 0 = plane 0
    vdp.vram[0] = 0xFF; // plane 0: all bits set
    vdp.vram[1] = 0x00;
    vdp.vram[2] = 0x00;
    vdp.vram[3] = 0x00;

    // Render line 1
    vdp.scanline = 1;
    _ = vdp.stepScanline();

    try testing.expect((vdp.status & SmsVdp.status_sprite_collision) != 0);
}

test "sms vdp no sprite collision when sprites dont overlap" {
    var vdp = SmsVdp.init();
    vdp.regs[1] = 0x40; // Display enabled
    vdp.regs[5] = 0x7E; // SAT base = 0x3F00
    vdp.regs[6] = 0x00; // Pattern base = 0x0000

    const sat_base: u16 = 0x3F00;

    // Two sprites at different X positions, no overlap (8px wide each)
    vdp.vram[sat_base] = 0x00; // sprite 0 Y=0
    vdp.vram[sat_base + 1] = 0x00; // sprite 1 Y=0
    vdp.vram[sat_base + 2] = 0xD0; // terminator

    vdp.vram[sat_base + 128] = 0; // sprite 0 X=0
    vdp.vram[sat_base + 129] = 0; // sprite 0 tile=0
    vdp.vram[sat_base + 130] = 100; // sprite 1 X=100 (far away)
    vdp.vram[sat_base + 131] = 0; // sprite 1 tile=0

    // Non-transparent tile: all pixels set
    vdp.vram[0] = 0xFF;
    vdp.vram[1] = 0x00;
    vdp.vram[2] = 0x00;
    vdp.vram[3] = 0x00;

    vdp.scanline = 1;
    _ = vdp.stepScanline();

    try testing.expect((vdp.status & SmsVdp.status_sprite_collision) == 0);
}

test "sms vdp horizontal scroll shifts background right" {
    var vdp = SmsVdp.init();
    vdp.regs[1] = 0x40; // Display enabled

    // Set up nametable: column 0 has tile 1 (non-zero), rest tile 0 (blank)
    const nt_base = vdp.nameTableBase();

    // Tile 1, row 0: all pixels color index 1 (palette 0)
    const tile1_addr: u16 = 1 * 32; // tile 1 at byte offset 32
    vdp.vram[tile1_addr] = 0xFF; // plane 0
    vdp.vram[tile1_addr + 1] = 0x00;
    vdp.vram[tile1_addr + 2] = 0x00;
    vdp.vram[tile1_addr + 3] = 0x00;

    // CRAM: palette 0, color 1 = white
    vdp.cram[1] = 0x3F; // R=3, G=3, B=3 = white

    // Name table row 0, column 0 = tile 1
    vdp.vram[nt_base] = 0x01; // tile index 1 (low byte)
    vdp.vram[nt_base + 1] = 0x00; // high byte

    // No scroll: column 0 should appear at screen X=0
    vdp.regs[8] = 0; // hscroll = 0
    vdp.scanline = 0;
    _ = vdp.stepScanline();

    const white = SmsVdp.cramToRgba(0x3F);
    // Pixel at X=0 should be white (tile 1)
    try testing.expectEqual(white, vdp.framebuffer[0]);
    // Pixel at X=8 should be backdrop (tile 0 = transparent)
    try testing.expect(vdp.framebuffer[8] != white);

    // Now set horizontal scroll to 16: column 0 content should appear at screen X=16
    vdp.regs[8] = 16;
    vdp.scanline = 0;
    _ = vdp.stepScanline();

    // X=0 should NOT be white anymore (it's now showing a different nametable column)
    try testing.expect(vdp.framebuffer[0] != white);
    // X=16 should be white (column 0 shifted right by 16)
    try testing.expectEqual(white, vdp.framebuffer[16]);
}

test "sms vdp vertical scroll wraps at 224 in mode 192" {
    var vdp = SmsVdp.init();
    vdp.regs[1] = 0x40; // Display enabled, mode 192

    const nt_base = vdp.nameTableBase();

    // Tile 1: all pixels color 1
    vdp.vram[32] = 0xFF;
    vdp.vram[33] = 0x00;
    vdp.vram[34] = 0x00;
    vdp.vram[35] = 0x00;
    vdp.cram[1] = 0x3F;

    // Put tile 1 in nametable row 1, column 0 (offset = row*64 + col*2)
    vdp.vram[nt_base + 64] = 0x01;
    vdp.vram[nt_base + 65] = 0x00;

    // With vscroll=8, line 0 should show nametable row 1 (effective_y = 0+8 = 8, row = 1)
    vdp.regs[9] = 8;
    vdp.scanline = 0;
    _ = vdp.stepScanline();

    const white = SmsVdp.cramToRgba(0x3F);
    try testing.expectEqual(white, vdp.framebuffer[0]);

    // With vscroll=0, line 0 should show nametable row 0 (which has tile 0 = backdrop)
    vdp.regs[9] = 0;
    vdp.scanline = 0;
    _ = vdp.stepScanline();
    try testing.expect(vdp.framebuffer[0] != white);
}

test "sms vdp 224-line mode" {
    var vdp = SmsVdp.init();
    // Mode 4 + M1+M2+M3 = 224-line mode
    vdp.regs[0] = 0x06; // M4=1, M2=1
    vdp.regs[1] = 0x58; // Display enabled, M1=1, M3=1
    try testing.expectEqual(@as(u16, 224), vdp.activeVisibleLines());
}

test "sms vdp 240-line mode" {
    var vdp = SmsVdp.init();
    // Mode 4 + M2+M3 (no M1) = 240-line mode
    vdp.regs[0] = 0x06; // M4=1, M2=1
    vdp.regs[1] = 0x48; // Display enabled, M3=1 (no M1)
    try testing.expectEqual(@as(u16, 240), vdp.activeVisibleLines());
}

test "sms vdp stepScanline enters vblank at line 192" {
    var vdp = SmsVdp.init();
    // Enable display
    vdp.regs[1] = 0xE0; // Display enabled + frame interrupt enabled
    vdp.scanline = 191;
    _ = vdp.stepScanline(); // line 191 (last visible)
    try testing.expect(!vdp.vint_pending);
    const entering_vblank = vdp.stepScanline(); // line 192 (first vblank)
    try testing.expect(entering_vblank);
    try testing.expect(vdp.vint_pending);
    try testing.expect((vdp.status & SmsVdp.status_vint) != 0);
}
