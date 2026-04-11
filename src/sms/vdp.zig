const std = @import("std");
const testing = std.testing;

/// SMS VDP (TMS9918A derivative, Mode 4).
/// 16KB VRAM, 32-byte CRAM, 11 registers, 256-pixel-wide output.
pub const SmsVdp = struct {
    vram: [16 * 1024]u8 = [_]u8{0} ** (16 * 1024),
    cram: [64]u8 = [_]u8{0} ** 64, // SMS: 32 bytes (1 per color), GG: 64 bytes (2 per color)
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
    is_game_gear: bool = false,
    is_sg1000: bool = false,
    gg_cram_latch: u8 = 0, // GG CRAM even-byte latch for two-byte writes

    pub const framebuffer_width: usize = 256;
    pub const max_framebuffer_height: usize = 240;

    const default_regs = [11]u8{ 0x06, 0x80, 0xFF, 0xFF, 0xFF, 0xFF, 0xFB, 0x00, 0x00, 0x00, 0xFF };

    // Status register bits
    const status_vint: u8 = 0x80;
    const status_sprite_overflow: u8 = 0x40;
    const status_sprite_collision: u8 = 0x20;

    // TMS9918A / SMS display mode classification
    pub const GraphicsMode = enum {
        mode4, // SMS Mode 4 (standard SMS/GG)
        mode0_text, // TMS9918 Mode 0: 40x24 text, 6x8 chars, no sprites
        mode1_graphics1, // TMS9918 Mode 1: 32x24 tiles, 1 color per 8 tiles
        mode2_graphics2, // TMS9918 Mode 2: 32x24 tiles, per-row colors, 3 pattern groups
        mode3_multicolor, // TMS9918 Mode 3: 64x48 colored blocks
    };

    /// Determine the active graphics mode from VDP register bits.
    /// M4 (reg0 bit 2) selects SMS Mode 4. For TMS9918 modes:
    /// M1 (reg1 bit 4), M2 (reg0 bit 1), M3 (reg1 bit 3).
    pub fn graphicsMode(self: *const SmsVdp) GraphicsMode {
        // SG-1000 uses a TMS9918A where register 0 bit 2 is unused (not M4).
        // The SMS VDP repurposed that bit for Mode 4. Ignore it for SG-1000.
        if (!self.is_sg1000 and (self.regs[0] & 0x04) != 0) return .mode4;
        if ((self.regs[1] & 0x10) != 0) return .mode0_text;
        if ((self.regs[0] & 0x02) != 0) return .mode2_graphics2;
        if ((self.regs[1] & 0x08) != 0) return .mode3_multicolor;
        return .mode1_graphics1;
    }

    // Fixed TMS9918A 16-color palette (ARGB format)
    pub const tms_palette = [16]u32{
        0x00000000, // 0: transparent (rendered as black)
        0xFF000000, // 1: black
        0xFF21C842, // 2: medium green
        0xFF5EDC78, // 3: light green
        0xFF5455ED, // 4: dark blue
        0xFF7D76FC, // 5: light blue
        0xFFD4524D, // 6: dark red
        0xFF42EBF5, // 7: cyan
        0xFFFC5554, // 8: medium red
        0xFFFF7978, // 9: light red
        0xFFD4C154, // 10: dark yellow
        0xFFE6CE80, // 11: light yellow
        0xFF21B03B, // 12: dark green
        0xFFC95BBA, // 13: magenta
        0xFFCCCCCC, // 14: gray
        0xFFFFFFFF, // 15: white
    };

    /// Look up a TMS9918A fixed palette color by index.
    pub fn tmsPaletteColor(index: u4) u32 {
        return tms_palette[index];
    }

    pub fn init() SmsVdp {
        return .{};
    }

    pub fn reset(self: *SmsVdp) void {
        self.* = init();
    }

    // -- Display mode queries --

    /// Internal visible lines for VDP timing and interrupts.
    /// On GG, the VDP still runs in 192-line SMS mode internally;
    /// the 144-line viewport is applied only during rendering.
    pub fn activeVisibleLines(self: *const SmsVdp) u16 {
        return switch (self.displayMode()) {
            .mode_192 => 192,
            .mode_224 => 224,
            .mode_240 => 240,
        };
    }

    /// Display height as seen by the frontend (after GG viewport crop).
    pub fn displayHeight(self: *const SmsVdp) u16 {
        if (self.is_game_gear) return gg_visible_height;
        return self.activeVisibleLines();
    }

    pub fn totalLines(self: *const SmsVdp) u16 {
        return if (self.pal_mode) 313 else 262;
    }

    pub fn screenWidth(self: *const SmsVdp) u16 {
        return if (self.is_game_gear) 160 else 256;
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
                if (self.is_game_gear) {
                    // GG CRAM: two-byte sequential writes (little-endian).
                    // Even address: latch LSB. Odd address: combine and write both bytes.
                    const byte_addr = @as(u16, self.addr);
                    if (byte_addr & 1 == 0) {
                        self.gg_cram_latch = value;
                    } else {
                        const word_addr = byte_addr & 0x3E;
                        self.cram[word_addr] = self.gg_cram_latch;
                        self.cram[word_addr + 1] = value;
                    }
                } else {
                    self.cram[@as(u16, self.addr) & 0x1F] = value;
                }
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
            // First byte immediately updates the low byte of the address register
            self.addr = (self.addr & 0x3F00) | @as(u14, value);
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
        } else if (self.scanline == total - 1) {
            // Last line of frame: decrement line counter (not reload)
            // per jgenesis reference: HINT can fire on the frame boundary
            if (self.line_counter == 0) {
                self.line_counter = self.regs[10];
                self.hint_pending = true;
            } else {
                self.line_counter -= 1;
            }
        } else {
            // Vblank (except last line): reload line counter each line
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
        return self.paletteColor(index);
    }

    // -- Color conversion --

    fn cramToRgba(color: u8) u32 {
        // SMS CRAM: --BBGGRR (6-bit, 2 bits per channel)
        const r: u32 = @as(u32, color & 0x03) * 85; // Scale 0-3 to 0-255
        const g: u32 = @as(u32, (color >> 2) & 0x03) * 85;
        const b: u32 = @as(u32, (color >> 4) & 0x03) * 85;
        return (0xFF << 24) | (r << 16) | (g << 8) | b;
    }

    fn ggCramToRgba(lo: u8, hi: u8) u32 {
        // GG CRAM: ----BBBBGGGGRRRR (12-bit, 4 bits per channel)
        const data: u16 = @as(u16, hi) << 8 | @as(u16, lo);
        const r: u32 = @as(u32, data & 0x0F) * 17; // Scale 0-15 to 0-255
        const g: u32 = @as(u32, (data >> 4) & 0x0F) * 17;
        const b: u32 = @as(u32, (data >> 8) & 0x0F) * 17;
        return (0xFF << 24) | (r << 16) | (g << 8) | b;
    }

    fn paletteColor(self: *const SmsVdp, index: u8) u32 {
        if (self.is_game_gear) {
            const byte_offset = @as(usize, index) * 2;
            return ggCramToRgba(self.cram[byte_offset], self.cram[byte_offset + 1]);
        }
        return cramToRgba(self.cram[index]);
    }

    // -- Rendering --

    fn renderBlankLine(self: *SmsVdp, line: u16) void {
        const bg = self.backdropColor();
        if (self.is_game_gear) {
            if (line >= gg_top and line < gg_top + gg_visible_height) {
                const gg_line = line - gg_top;
                const offset = @as(usize, gg_line) * gg_visible_width;
                @memset(self.framebuffer[offset..][0..gg_visible_width], bg);
            }
        } else {
            const offset = @as(usize, line) * framebuffer_width;
            @memset(self.framebuffer[offset..][0..framebuffer_width], bg);
        }
    }

    // GG viewport: 160x144 centered in 256x192
    const gg_left: usize = 48;
    const gg_right: usize = 208; // 48 + 160
    const gg_top: u16 = 24;
    pub const gg_visible_width: usize = 160;
    pub const gg_visible_height: u16 = 144;

    fn renderScanline(self: *SmsVdp, line: u16) void {
        var line_buf: [framebuffer_width]u32 = undefined;
        var priority_buf: [framebuffer_width]bool = [_]bool{false} ** framebuffer_width;

        // TMS9918 modes use different rendering paths
        if (self.graphicsMode() != .mode4) {
            self.renderScanlineTms(line, &line_buf);
            const offset = @as(usize, line) * framebuffer_width;
            @memcpy(self.framebuffer[offset..][0..framebuffer_width], &line_buf);
            return;
        }

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

        if (self.is_game_gear) {
            // GG: write only the center 160 pixels of visible lines into a
            // compact 160-wide framebuffer.
            if (line >= gg_top and line < gg_top + gg_visible_height) {
                const gg_line = line - gg_top;
                const offset = @as(usize, gg_line) * gg_visible_width;
                @memcpy(self.framebuffer[offset..][0..gg_visible_width], line_buf[gg_left..gg_right]);
            }
        } else {
            const offset = @as(usize, line) * framebuffer_width;
            @memcpy(self.framebuffer[offset..][0..framebuffer_width], &line_buf);
        }
    }

    // -- TMS9918A rendering (SG-1000) --

    fn renderScanlineTms(self: *SmsVdp, line: u16, line_buf: *[framebuffer_width]u32) void {
        // Backdrop: register 7 lower nibble (TMS palette index)
        const bd_color: u4 = @truncate(self.regs[7] & 0x0F);
        const bg = if (bd_color == 0) @as(u32, 0xFF000000) else tmsPaletteColor(bd_color);
        @memset(line_buf, bg);

        switch (self.graphicsMode()) {
            .mode2_graphics2 => self.renderBackgroundTmsMode2(line, line_buf),
            .mode1_graphics1 => self.renderBackgroundTmsMode1(line, line_buf),
            .mode0_text => self.renderBackgroundTmsMode0(line, line_buf),
            .mode3_multicolor => self.renderBackgroundTmsMode3(line, line_buf),
            .mode4 => unreachable,
        }

        // TMS sprites (all modes except Mode 0/text have sprites)
        if (self.graphicsMode() != .mode0_text) {
            self.renderSpritesTms(line, line_buf);
        }
    }

    /// Mode 2 (Graphics II): 32x24 tiles, 3 pattern groups, per-row color table.
    /// Used by ~95% of SG-1000 games.
    fn renderBackgroundTmsMode2(self: *SmsVdp, line: u16, line_buf: *[framebuffer_width]u32) void {
        const tile_row = line / 8;
        const fine_y = line & 7;
        // Name table base: register 2, bits 0-3, shifted left by 10
        const name_base: u16 = (@as(u16, self.regs[2]) & 0x0F) << 10;
        // Pattern generator base: register 4 bit 2 selects 0x0000 or 0x2000
        // (masking with 0x04 then shift to get actual base; top bit acts as mask)
        const pg_base: u16 = (@as(u16, self.regs[4]) & 0x04) << 11; // 0x0000 or 0x2000
        const pg_mask: u16 = ((@as(u16, self.regs[4]) & 0x03) << 8) | 0xFF;
        // Color table base: register 3 upper bits; lower bits act as mask
        const ct_base: u16 = (@as(u16, self.regs[3]) & 0x80) << 6; // 0x0000 or 0x2000
        const ct_mask: u16 = ((@as(u16, self.regs[3]) & 0x7F) << 3) | 0x07;
        // Screen divided into thirds (rows 0-7, 8-15, 16-23)
        const group_offset: u16 = (tile_row / 8) * 256;

        for (0..32) |col_idx| {
            const col: u16 = @intCast(col_idx);
            const name_addr = name_base + tile_row * 32 + col;
            const tile: u16 = self.vram[name_addr & 0x3FFF];
            const pattern_index = (tile + group_offset) & pg_mask;
            const pg_addr = pg_base + pattern_index * 8 + fine_y;
            const ct_addr = ct_base + ((tile + group_offset) & ct_mask) * 8 + fine_y;
            const pattern_byte = self.vram[pg_addr & 0x3FFF];
            const color_byte = self.vram[ct_addr & 0x3FFF];
            const fg_idx: u4 = @truncate(color_byte >> 4);
            const bg_idx: u4 = @truncate(color_byte & 0x0F);
            const fg = if (fg_idx == 0) @as(u32, 0xFF000000) else tmsPaletteColor(fg_idx);
            const bg_col = if (bg_idx == 0) @as(u32, 0xFF000000) else tmsPaletteColor(bg_idx);

            const x_base = col * 8;
            inline for (0..8) |bit| {
                const mask = @as(u8, 0x80) >> @intCast(bit);
                const pixel = if ((pattern_byte & mask) != 0) fg else bg_col;
                line_buf[x_base + bit] = pixel;
            }
        }
    }

    /// Mode 1 (Graphics I): 32x24 tiles, one pattern set, color per 8 tiles.
    fn renderBackgroundTmsMode1(self: *SmsVdp, line: u16, line_buf: *[framebuffer_width]u32) void {
        const tile_row = line / 8;
        const fine_y = line & 7;
        const name_base: u16 = (@as(u16, self.regs[2]) & 0x0F) << 10;
        const pg_base: u16 = (@as(u16, self.regs[4]) & 0x07) << 11;
        const ct_base: u16 = @as(u16, self.regs[3]) << 6;

        for (0..32) |col_idx| {
            const col: u16 = @intCast(col_idx);
            const name_addr = name_base + tile_row * 32 + col;
            const tile: u16 = self.vram[name_addr & 0x3FFF];
            const pg_addr = pg_base + tile * 8 + fine_y;
            // Color table: one byte per 8 tiles
            const ct_addr = ct_base + tile / 8;
            const pattern_byte = self.vram[pg_addr & 0x3FFF];
            const color_byte = self.vram[ct_addr & 0x3FFF];
            const fg_idx: u4 = @truncate(color_byte >> 4);
            const bg_idx: u4 = @truncate(color_byte & 0x0F);
            const fg = if (fg_idx == 0) @as(u32, 0xFF000000) else tmsPaletteColor(fg_idx);
            const bg_col = if (bg_idx == 0) @as(u32, 0xFF000000) else tmsPaletteColor(bg_idx);

            const x_base = col * 8;
            inline for (0..8) |bit| {
                const mask = @as(u8, 0x80) >> @intCast(bit);
                line_buf[x_base + bit] = if ((pattern_byte & mask) != 0) fg else bg_col;
            }
        }
    }

    /// Mode 0 (Text): 40x24 text, 6x8 characters, no sprites.
    fn renderBackgroundTmsMode0(self: *SmsVdp, line: u16, line_buf: *[framebuffer_width]u32) void {
        const tile_row = line / 8;
        const fine_y = line & 7;
        const name_base: u16 = (@as(u16, self.regs[2]) & 0x0F) << 10;
        const pg_base: u16 = (@as(u16, self.regs[4]) & 0x07) << 11;
        const fg_idx: u4 = @truncate(self.regs[7] >> 4);
        const bg_idx: u4 = @truncate(self.regs[7] & 0x0F);
        const fg = if (fg_idx == 0) @as(u32, 0xFF000000) else tmsPaletteColor(fg_idx);
        const bg_col = if (bg_idx == 0) @as(u32, 0xFF000000) else tmsPaletteColor(bg_idx);

        // 40 columns of 6-pixel-wide chars; total = 240 pixels, centered with 8px border each side
        for (0..40) |col_idx| {
            const col: u16 = @intCast(col_idx);
            const name_addr = name_base + tile_row * 40 + col;
            const tile: u16 = self.vram[name_addr & 0x3FFF];
            const pg_addr = pg_base + tile * 8 + fine_y;
            const pattern_byte = self.vram[pg_addr & 0x3FFF];

            const x_base = 8 + col * 6; // 8px left border
            inline for (0..6) |bit| {
                const mask = @as(u8, 0x80) >> @intCast(bit);
                if (x_base + bit < framebuffer_width) {
                    line_buf[x_base + bit] = if ((pattern_byte & mask) != 0) fg else bg_col;
                }
            }
        }
    }

    /// Mode 3 (Multicolor): 64x48 colored blocks (4x4 pixel blocks).
    fn renderBackgroundTmsMode3(self: *SmsVdp, line: u16, line_buf: *[framebuffer_width]u32) void {
        const tile_row = line / 8;
        const sub_row = (line / 4) & 1; // which half of the 8-pixel-tall row
        const name_base: u16 = (@as(u16, self.regs[2]) & 0x0F) << 10;
        const pg_base: u16 = (@as(u16, self.regs[4]) & 0x07) << 11;

        for (0..32) |col_idx| {
            const col: u16 = @intCast(col_idx);
            const name_addr = name_base + tile_row * 32 + col;
            const tile: u16 = self.vram[name_addr & 0x3FFF];
            // Pattern byte encodes 2 colors (upper=left, lower=right) for this 4px sub-row
            const pg_addr = pg_base + tile * 8 + (tile_row & 3) * 2 + sub_row;
            const color_byte = self.vram[pg_addr & 0x3FFF];
            const left_idx: u4 = @truncate(color_byte >> 4);
            const right_idx: u4 = @truncate(color_byte & 0x0F);
            const left = if (left_idx == 0) @as(u32, 0xFF000000) else tmsPaletteColor(left_idx);
            const right = if (right_idx == 0) @as(u32, 0xFF000000) else tmsPaletteColor(right_idx);

            const x_base = col * 8;
            line_buf[x_base + 0] = left;
            line_buf[x_base + 1] = left;
            line_buf[x_base + 2] = left;
            line_buf[x_base + 3] = left;
            line_buf[x_base + 4] = right;
            line_buf[x_base + 5] = right;
            line_buf[x_base + 6] = right;
            line_buf[x_base + 7] = right;
        }
    }

    /// TMS9918 sprite rendering (shared by Modes 1, 2, 3).
    fn renderSpritesTms(self: *SmsVdp, line: u16, line_buf: *[framebuffer_width]u32) void {
        const sat_base: u16 = (@as(u16, self.regs[5]) & 0x7F) << 7;
        const sg_base: u16 = (@as(u16, self.regs[6]) & 0x07) << 11;
        const is_16x16 = (self.regs[1] & 0x02) != 0;
        const is_magnified = (self.regs[1] & 0x01) != 0;
        const sprite_height: u16 = if (is_16x16) 16 else 8;
        const display_height: u16 = if (is_magnified) sprite_height * 2 else sprite_height;

        var sprite_drawn: [framebuffer_width]bool = [_]bool{false} ** framebuffer_width;
        var sprites_on_line: usize = 0;

        var sprite_idx: usize = 0;
        while (sprite_idx < 32) : (sprite_idx += 1) {
            // TMS9918 SAT: 4 bytes per sprite (Y, X, pattern, color/EC)
            const sat_entry = sat_base + @as(u16, @intCast(sprite_idx)) * 4;
            const y_raw = self.vram[sat_entry & 0x3FFF];
            if (y_raw == 0xD0) break;
            const sprite_y: i16 = @as(i16, y_raw) + 1;
            if (sprite_y > @as(i16, @intCast(line)) or sprite_y + @as(i16, @intCast(display_height)) <= @as(i16, @intCast(line)))
                continue;

            sprites_on_line += 1;
            if (sprites_on_line > 4) {
                self.status |= status_sprite_overflow;
                break;
            }

            const sprite_x_raw = self.vram[(sat_entry + 1) & 0x3FFF];
            const pattern = self.vram[(sat_entry + 2) & 0x3FFF];
            const attr = self.vram[(sat_entry + 3) & 0x3FFF];
            const color_idx: u4 = @truncate(attr & 0x0F);
            const early_clock = (attr & 0x80) != 0;
            const sprite_x: i16 = @as(i16, sprite_x_raw) - if (early_clock) @as(i16, 32) else 0;

            if (color_idx == 0) continue;
            const color = tmsPaletteColor(color_idx);

            const row_in_sprite: u16 = if (is_magnified)
                (@as(u16, @intCast(line)) -| @as(u16, @intCast(@max(sprite_y, 0)))) / 2
            else
                @as(u16, @intCast(line)) -| @as(u16, @intCast(@max(sprite_y, 0)));

            const effective_pattern: u16 = if (is_16x16) @as(u16, pattern) & 0xFC else pattern;
            const cols: usize = if (is_16x16) 2 else 1;

            for (0..cols) |col| {
                const pg_offset: u16 = if (is_16x16)
                    effective_pattern * 8 + @as(u16, @intCast(col)) * 16 + row_in_sprite
                else
                    effective_pattern * 8 + row_in_sprite;
                const pg_addr = sg_base + pg_offset;
                const pattern_byte = self.vram[pg_addr & 0x3FFF];

                for (0..8) |bit| {
                    const mask = @as(u8, 0x80) >> @intCast(bit);
                    if ((pattern_byte & mask) == 0) continue;

                    const px_offset: i16 = @intCast(col * 8 + bit);
                    const raw_px = sprite_x + if (is_magnified) px_offset * 2 else px_offset;

                    const pixels_to_draw: usize = if (is_magnified) 2 else 1;
                    for (0..pixels_to_draw) |sub| {
                        const px = raw_px + @as(i16, @intCast(sub));
                        if (px >= 0 and px < framebuffer_width) {
                            const ux: usize = @intCast(px);
                            if (sprite_drawn[ux]) {
                                self.status |= status_sprite_collision;
                            } else {
                                line_buf[ux] = color;
                                sprite_drawn[ux] = true;
                            }
                        }
                    }
                }
            }
        }
    }

    // -- Mode 4 rendering (SMS/GG) --

    fn renderBackground(self: *SmsVdp, line: u16, line_buf: *[framebuffer_width]u32, priority_buf: *[framebuffer_width]bool) void {
        const name_base = self.nameTableBase();
        const visible_lines = self.activeVisibleLines();

        const vscroll: u16 = self.regs[9];
        const hscroll_locked = (self.regs[0] & 0x40) != 0 and line < 16;
        const hscroll: u16 = if (hscroll_locked) 0 else self.regs[8];
        const coarse_hscroll: u16 = (hscroll >> 3) & 0x1F;
        const fine_hscroll: u16 = hscroll & 0x7;
        const vertical_wrap: u16 = if (visible_lines > 192) 256 else 224;

        for (0..framebuffer_width) |screen_x_idx| {
            const screen_x: u16 = @intCast(screen_x_idx);
            const screen_col = screen_x / 8;

            // Fine horizontal scrolling does not wrap partial pixels from the
            // right edge into the leftmost 1-7 pixels. Those pixels remain in
            // the backdrop color unless the top two rows disable scroll.
            if (!hscroll_locked and fine_hscroll != 0 and screen_x < fine_hscroll) continue;

            const scrolled_x: u16 = if (hscroll_locked)
                screen_x
            else
                screen_x - fine_hscroll;
            const source_col: u16 = if (hscroll_locked)
                screen_col
            else
                @intCast((@as(u32, scrolled_x / 8) + 32 - coarse_hscroll) % 32);

            var effective_y = line;
            if (!((self.regs[0] & 0x80) != 0 and screen_col >= 24)) {
                effective_y = (line +% vscroll) % vertical_wrap;
            }

            const tile_row = effective_y / 8;
            const tile_fine_y: u3 = @truncate(effective_y);

            const nt_offset = name_base + (tile_row * 64) + (source_col * 2);
            const entry_lo: u16 = self.vram[nt_offset & 0x3FFF];
            const entry_hi: u16 = self.vram[(nt_offset + 1) & 0x3FFF];
            const entry = entry_lo | (entry_hi << 8);

            const tile_index: u16 = entry & 0x01FF;
            const h_flip = (entry & 0x0200) != 0;
            const v_flip = (entry & 0x0400) != 0;
            const palette: u8 = if ((entry & 0x0800) != 0) 16 else 0;
            const priority = (entry & 0x1000) != 0;

            const y_in_tile: u16 = if (v_flip) 7 - @as(u16, tile_fine_y) else @as(u16, tile_fine_y);
            const tile_addr = (tile_index * 32) + (y_in_tile * 4);

            const b0 = self.vram[tile_addr & 0x3FFF];
            const b1 = self.vram[(tile_addr + 1) & 0x3FFF];
            const b2 = self.vram[(tile_addr + 2) & 0x3FFF];
            const b3 = self.vram[(tile_addr + 3) & 0x3FFF];

            const x_in_tile: u3 = @truncate(scrolled_x);
            const bit: u3 = if (h_flip)
                x_in_tile
            else
                @intCast(7 - x_in_tile);

            const p0: u8 = (b0 >> bit) & 1;
            const p1: u8 = (b1 >> bit) & 1;
            const p2: u8 = (b2 >> bit) & 1;
            const p3: u8 = (b3 >> bit) & 1;
            const color_index = p0 | (p1 << 1) | (p2 << 2) | (p3 << 3);

            if (color_index != 0) {
                line_buf[screen_x_idx] = self.paletteColor(palette + color_index);
                priority_buf[screen_x_idx] = priority;
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

                // Sprite collision detection: occurs regardless of BG priority
                if (sprite_drawn[sx]) {
                    self.status |= status_sprite_collision;
                } else {
                    sprite_drawn[sx] = true;
                }

                // Priority: BG tiles with priority bit set are in front of sprites
                if (priority_buf[sx]) continue;

                line_buf[sx] = self.paletteColor(16 + color_index);
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

test "sms vdp fine horizontal scroll leaves the left edge in backdrop color" {
    var vdp = SmsVdp.init();
    vdp.regs[1] = 0x40; // Display enabled

    const nt_base = vdp.nameTableBase();

    // Tile 1: solid white
    vdp.vram[32] = 0xFF;
    vdp.vram[33] = 0x00;
    vdp.vram[34] = 0x00;
    vdp.vram[35] = 0x00;

    // Tile 2: solid red
    vdp.vram[64] = 0x00;
    vdp.vram[65] = 0xFF;
    vdp.vram[66] = 0x00;
    vdp.vram[67] = 0x00;

    const white_idx: u8 = 1;
    const red_idx: u8 = 2;
    const backdrop_idx: u8 = 0x10;
    vdp.cram[white_idx] = 0x3F;
    vdp.cram[red_idx] = 0x03;
    vdp.cram[backdrop_idx] = 0x30;
    vdp.regs[7] = 0x00;

    // Rightmost nametable column uses white; column 0 uses red.
    const last_col_offset = nt_base + (31 * 2);
    vdp.vram[last_col_offset] = 0x01;
    vdp.vram[last_col_offset + 1] = 0x00;
    vdp.vram[nt_base] = 0x02;
    vdp.vram[nt_base + 1] = 0x00;

    vdp.regs[8] = 3; // fine scroll by 3 pixels
    vdp.scanline = 0;
    _ = vdp.stepScanline();

    const backdrop = SmsVdp.cramToRgba(vdp.cram[backdrop_idx]);
    const red = SmsVdp.cramToRgba(vdp.cram[red_idx]);
    const white = SmsVdp.cramToRgba(vdp.cram[white_idx]);

    try testing.expectEqual(backdrop, vdp.framebuffer[0]);
    try testing.expectEqual(backdrop, vdp.framebuffer[1]);
    try testing.expectEqual(backdrop, vdp.framebuffer[2]);
    try testing.expectEqual(red, vdp.framebuffer[3]);
    try testing.expect(vdp.framebuffer[0] != white);
}

test "sms vdp horizontal scroll lock applies to the top two rows only" {
    var vdp = SmsVdp.init();
    vdp.regs[1] = 0x40; // Display enabled
    vdp.regs[0] |= 0x40; // top two rows ignore horizontal scroll

    const nt_base = vdp.nameTableBase();

    // Tile 1: solid white
    vdp.vram[32] = 0xFF;
    vdp.vram[33] = 0x00;
    vdp.vram[34] = 0x00;
    vdp.vram[35] = 0x00;

    // Tile 2: solid red
    vdp.vram[64] = 0x00;
    vdp.vram[65] = 0xFF;
    vdp.vram[66] = 0x00;
    vdp.vram[67] = 0x00;

    const white_idx: u8 = 1;
    const red_idx: u8 = 2;
    vdp.cram[white_idx] = 0x3F;
    vdp.cram[red_idx] = 0x03;

    // Column 31 = white, column 0 = red.
    const last_col_offset = nt_base + (31 * 2);
    vdp.vram[last_col_offset] = 0x01;
    vdp.vram[last_col_offset + 1] = 0x00;
    vdp.vram[nt_base] = 0x02;
    vdp.vram[nt_base + 1] = 0x00;
    const row2_base = nt_base + (2 * 64);
    const row2_last_col = row2_base + (31 * 2);
    vdp.vram[row2_last_col] = 0x01;
    vdp.vram[row2_last_col + 1] = 0x00;
    vdp.vram[row2_base] = 0x02;
    vdp.vram[row2_base + 1] = 0x00;

    vdp.regs[8] = 8; // coarse scroll by one tile

    vdp.scanline = 0;
    _ = vdp.stepScanline();

    const red = SmsVdp.cramToRgba(vdp.cram[red_idx]);
    const white = SmsVdp.cramToRgba(vdp.cram[white_idx]);
    try testing.expectEqual(red, vdp.framebuffer[0]);

    vdp.scanline = 16;
    _ = vdp.stepScanline();
    try testing.expectEqual(white, vdp.framebuffer[16 * SmsVdp.framebuffer_width]);
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

test "gg vdp viewport dimensions" {
    var vdp = SmsVdp.init();
    vdp.is_game_gear = true;
    try testing.expectEqual(@as(u16, 160), vdp.screenWidth());
    try testing.expectEqual(@as(u16, 144), vdp.displayHeight());
    // Internal VDP timing still uses 192 lines
    try testing.expectEqual(@as(u16, 192), vdp.activeVisibleLines());
}

test "gg vdp cram two-byte write" {
    var vdp = SmsVdp.init();
    vdp.is_game_gear = true;
    // Set up CRAM write mode: code=3, addr=0
    vdp.code = 3;
    vdp.addr = 0;
    // Write color 0: 0x0F0A = R=10, G=0, B=15
    vdp.writeData(0x0A); // Even byte: latched
    vdp.writeData(0x0F); // Odd byte: combined and written
    try testing.expectEqual(@as(u8, 0x0A), vdp.cram[0]);
    try testing.expectEqual(@as(u8, 0x0F), vdp.cram[1]);
    // Verify RGBA conversion: R=10*17=170, G=0, B=15*17=255
    const rgba = SmsVdp.ggCramToRgba(0x0A, 0x0F);
    try testing.expectEqual(@as(u32, 0xFF00_00FF | (170 << 16)), rgba);
}

test "gg vdp display height is always 144" {
    var vdp = SmsVdp.init();
    vdp.is_game_gear = true;
    // Set mode bits that would enable 224-line mode on SMS
    vdp.regs[0] = 0x06; // M4=1, M2=1
    vdp.regs[1] = 0x98; // M1=1, M3=1
    // GG display height should still return 144
    try testing.expectEqual(@as(u16, 144), vdp.displayHeight());
}

test "displayMode returns mode4 when M4 bit is set" {
    var vdp = SmsVdp.init();
    vdp.regs[0] = 0x04; // M4=1
    try testing.expectEqual(SmsVdp.GraphicsMode.mode4, vdp.graphicsMode());
}

test "displayMode returns mode2_graphics2 when M2 bit is set" {
    var vdp = SmsVdp.init();
    vdp.regs[0] = 0x02; // M2=1, M4=0
    vdp.regs[1] = 0x00;
    try testing.expectEqual(SmsVdp.GraphicsMode.mode2_graphics2, vdp.graphicsMode());
}

test "displayMode returns mode0_text when M1 bit is set" {
    var vdp = SmsVdp.init();
    vdp.regs[0] = 0x00; // M4=0, M2=0
    vdp.regs[1] = 0x10; // M1=1
    try testing.expectEqual(SmsVdp.GraphicsMode.mode0_text, vdp.graphicsMode());
}

test "displayMode returns mode3_multicolor when M3 bit is set" {
    var vdp = SmsVdp.init();
    vdp.regs[0] = 0x00;
    vdp.regs[1] = 0x08; // M3=1
    try testing.expectEqual(SmsVdp.GraphicsMode.mode3_multicolor, vdp.graphicsMode());
}

test "displayMode returns mode1_graphics1 as default TMS mode" {
    var vdp = SmsVdp.init();
    vdp.regs[0] = 0x00;
    vdp.regs[1] = 0x00;
    try testing.expectEqual(SmsVdp.GraphicsMode.mode1_graphics1, vdp.graphicsMode());
}

test "tms palette has 16 entries with correct black and white" {
    try testing.expectEqual(@as(u32, 0xFF000000), SmsVdp.tmsPaletteColor(1)); // black
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), SmsVdp.tmsPaletteColor(15)); // white
    try testing.expect(SmsVdp.tms_palette[0] != SmsVdp.tms_palette[1]); // transparent != black
}

test "sg1000 ignores M4 bit in register 0 for graphics mode" {
    // On a real TMS9918A, register 0 bit 2 is unused. SG-1000 games may set
    // it without intending Mode 4. The VDP must ignore M4 for SG-1000.
    var vdp = SmsVdp.init();
    vdp.is_sg1000 = true;
    vdp.regs[0] = 0x06; // M4=1 (bit 2) + M2=1 (bit 1)
    vdp.regs[1] = 0x00;
    // SG-1000 should see Mode 2 (Graphics II), not Mode 4
    try testing.expectEqual(SmsVdp.GraphicsMode.mode2_graphics2, vdp.graphicsMode());

    // SMS with the same registers should see Mode 4
    vdp.is_sg1000 = false;
    try testing.expectEqual(SmsVdp.GraphicsMode.mode4, vdp.graphicsMode());
}

test "sg1000 tms mode 2 renders non-black pixels with pattern data" {
    // Regression: TMS Mode 2 renderer must produce visible output when
    // pattern and color tables have data.
    var vdp = SmsVdp.init();
    vdp.is_sg1000 = true;
    vdp.regs[0] = 0x02; // M2=1 (Mode 2)
    vdp.regs[1] = 0x42; // Display enabled, sprites tall
    vdp.regs[2] = 0x0E; // Name table at 0x3800
    vdp.regs[3] = 0xFF; // Color table mask 0xFF
    vdp.regs[4] = 0x03; // Pattern gen mask 0x03
    vdp.regs[7] = 0xF1; // Backdrop: white foreground, black background

    // Write a non-zero tile in the name table
    vdp.vram[0x3800] = 0x01; // Tile 1 at position (0,0)

    // Write a pattern byte for tile 1, row 0 (all pixels set)
    // Pattern gen base: (0x03 & 0x04)<<11 = 0, mask: 0x03FF
    // Tile 1, row 0: addr = 0 + 1*8 + 0 = 8
    vdp.vram[8] = 0xFF; // All 8 pixels on

    // Write a color byte: foreground=white (0xF), background=black (0x1)
    // Color table base: (0xFF & 0x80)<<6 = 0x2000
    // Tile 1, row 0: addr = 0x2000 + (1 & 0x3FF)*8 + 0 = 0x2008
    vdp.vram[0x2008] = 0xF1; // White foreground, black background

    vdp.beginFrame();
    _ = vdp.stepScanline(); // Renders line 0

    // Check that the first 8 pixels are white (TMS color 15)
    const white = SmsVdp.tmsPaletteColor(15);
    try testing.expectEqual(white, vdp.framebuffer[0]);
    try testing.expectEqual(white, vdp.framebuffer[7]);
}
