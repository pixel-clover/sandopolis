const std = @import("std");
const clock = @import("clock.zig");

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
    dma_copy: bool,
    dma_source_addr: u32,
    dma_length: u16,
    dma_remaining: u32,

    // Timing for V-BLANK
    scanline: u16, // Current scanline (0-261 for NTSC)
    line_master_cycle: u16, // 0..(cycles_per_line-1)
    hint_counter: i16,
    hv_latched: u16,
    hv_latched_valid: bool,
    dbg_vram_writes: u64,
    dbg_cram_writes: u64,
    dbg_vsram_writes: u64,
    dbg_unknown_writes: u64,

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
            .dma_copy = false,
            .dma_source_addr = 0,
            .dma_length = 0,
            .dma_remaining = 0,
            .scanline = 0,
            .line_master_cycle = 0,
            .hint_counter = 0,
            .hv_latched = 0,
            .hv_latched_valid = false,
            .dbg_vram_writes = 0,
            .dbg_cram_writes = 0,
            .dbg_vsram_writes = 0,
            .dbg_unknown_writes = 0,
        };
    }

    fn vramReadByte(self: *const Vdp, address: u16) u8 {
        return self.vram[address & 0xFFFF];
    }

    fn vramWriteByte(self: *Vdp, address: u16, value: u8) void {
        self.vram[address & 0xFFFF] = value;
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

        // Texture is created as ARGB8888, so keep framebuffer in 0xAARRGGBB.
        return (0xFF000000) | (r8 << 16) | (g8 << 8) | b8;
    }

    pub fn renderScanline(self: *Vdp, line: u16) void {
        if (line >= 224) return;

        // Plane table addresses.
        const plane_a_base = @as(u32, self.regs[2] & 0x38) << 10;
        const plane_b_base = @as(u32, self.regs[4] & 0x07) << 13;

        const plane_width_tiles: u16 = switch (self.regs[16] & 0x3) {
            0 => 32,
            1 => 64,
            3 => 128,
            else => 32,
        };
        const plane_height_tiles: u16 = switch ((self.regs[16] >> 4) & 0x3) {
            0 => 32,
            1 => 64,
            3 => 128,
            else => 32,
        };
        const plane_width_px: i32 = @as(i32, plane_width_tiles) * 8;
        const plane_height_px: i32 = @as(i32, plane_height_tiles) * 8;

        // Fill scanline with backdrop color.
        const backdrop_idx = self.regs[7] & 0x3F;
        const backdrop_color = self.getPaletteColor(backdrop_idx);
        const hscroll_base = (@as(u16, self.regs[13]) & 0x3F) << 10;
        const line_start = @as(usize, line) * 320;

        for (0..320) |x| {
            self.framebuffer[line_start + x] = backdrop_color;
        }

        // Window plane determination.
        const win_h_pos = self.regs[17];
        const win_v_pos = self.regs[18];
        const win_right = (win_h_pos & 0x80) != 0;
        const win_h_cell = @as(u16, win_h_pos & 0x1F) * 2; // in cells (multiply by 2 for 16-pixel units)
        const win_down = (win_v_pos & 0x80) != 0;
        const win_v_cell = @as(u16, win_v_pos & 0x1F) * 8; // in pixels

        // Determine if this line is in the window's vertical range.
        const line_in_win_v: bool = if (win_down) (line >= win_v_cell) else (line < win_v_cell);

        // Compute window horizontal boundaries (in pixels).
        const win_left_px: u16 = if (win_right) win_h_cell * 8 else 0;
        const win_right_px: u16 = if (win_right) 320 else win_h_cell * 8;

        // Render Plane B (always scrolling, full width, low priority pass).
        self.renderScrollPlanePass(line, plane_b_base, plane_width_tiles, plane_height_tiles, plane_width_px, plane_height_px, hscroll_base, false, false, 0, 320);

        // Render Plane A / Window (low priority pass).
        if (line_in_win_v and win_left_px < win_right_px) {
            // Scrolling Plane A in non-window region.
            if (win_left_px > 0) {
                self.renderScrollPlanePass(line, plane_a_base, plane_width_tiles, plane_height_tiles, plane_width_px, plane_height_px, hscroll_base, true, false, 0, win_left_px);
            }
            if (win_right_px < 320) {
                self.renderScrollPlanePass(line, plane_a_base, plane_width_tiles, plane_height_tiles, plane_width_px, plane_height_px, hscroll_base, true, false, win_right_px, 320);
            }
            // Window plane in window region.
            self.renderWindowPass(line, false, win_left_px, win_right_px);
        } else {
            // No window on this line — full Plane A.
            self.renderScrollPlanePass(line, plane_a_base, plane_width_tiles, plane_height_tiles, plane_width_px, plane_height_px, hscroll_base, true, false, 0, 320);
        }

        self.renderSpritesForLine(line, false);

        // High priority passes.
        self.renderScrollPlanePass(line, plane_b_base, plane_width_tiles, plane_height_tiles, plane_width_px, plane_height_px, hscroll_base, false, true, 0, 320);

        if (line_in_win_v and win_left_px < win_right_px) {
            if (win_left_px > 0) {
                self.renderScrollPlanePass(line, plane_a_base, plane_width_tiles, plane_height_tiles, plane_width_px, plane_height_px, hscroll_base, true, true, 0, win_left_px);
            }
            if (win_right_px < 320) {
                self.renderScrollPlanePass(line, plane_a_base, plane_width_tiles, plane_height_tiles, plane_width_px, plane_height_px, hscroll_base, true, true, win_right_px, 320);
            }
            self.renderWindowPass(line, true, win_left_px, win_right_px);
        } else {
            self.renderScrollPlanePass(line, plane_a_base, plane_width_tiles, plane_height_tiles, plane_width_px, plane_height_px, hscroll_base, true, true, 0, 320);
        }

        self.renderSpritesForLine(line, true);
    }

    fn renderScrollPlanePass(
        self: *Vdp,
        line: u16,
        plane_base: u32,
        plane_width_tiles: u16,
        plane_height_tiles: u16,
        plane_width_px: i32,
        plane_height_px: i32,
        hscroll_base: u16,
        is_plane_a: bool,
        high_priority: bool,
        start_x: u16,
        end_x: u16,
    ) void {
        const line_start = @as(usize, line) * 320;
        const hscroll = self.readHScroll(hscroll_base, line, is_plane_a);
        const vscroll_mode = (self.regs[11] >> 2) & 1;

        var x: u16 = start_x;
        while (x < end_x) : (x += 1) {
            // Per-2-cell VScroll: each 16-pixel column gets its own value.
            const vscroll_val: i32 = if (vscroll_mode != 0) blk: {
                const col_pair = x / 16; // 2-cell column index
                const vs_offset: u16 = if (is_plane_a) col_pair * 4 else col_pair * 4 + 2;
                if (vs_offset + 1 < 80) {
                    const hi = self.vsram[vs_offset & 0x4F];
                    const lo = self.vsram[(vs_offset + 1) & 0x4F];
                    const raw = (@as(u16, hi) << 8) | lo;
                    break :blk @as(i16, @bitCast(raw & 0x07FF));
                } else {
                    break :blk self.readVScroll(is_plane_a);
                }
            } else self.readVScroll(is_plane_a);

            if (self.samplePlanePixel(
                plane_base,
                plane_width_tiles,
                plane_height_tiles,
                plane_width_px,
                plane_height_px,
                @as(i32, @intCast(x)) - hscroll,
                @as(i32, line) + vscroll_val,
                high_priority,
            )) |idx| {
                self.framebuffer[line_start + x] = self.getPaletteColor(idx);
            }
        }
    }

    fn renderWindowPass(
        self: *Vdp,
        line: u16,
        high_priority: bool,
        start_x: u16,
        end_x: u16,
    ) void {
        // Window nametable base from register 3.
        // In H40 mode (320px), bit 0 is ignored, so mask with 0x3E.
        const win_base = @as(u32, self.regs[3] & 0x3E) << 10;
        // Window plane is always 64 cells wide (even in H32 mode).
        const win_width: u32 = 64;
        const line_start = @as(usize, line) * 320;
        const tile_row: u32 = @as(u32, line) / 8;
        const fine_y: u8 = @intCast(@as(u32, line) % 8);

        var x: u16 = start_x;
        while (x < end_x) : (x += 1) {
            const tile_col: u32 = @as(u32, x) / 8;
            const fine_x: u8 = @intCast(@as(u32, x) % 8);

            const table_index = tile_row * win_width + tile_col;
            const entry_addr: u16 = @intCast((win_base + table_index * 2) & 0xFFFF);
            const entry_hi = self.vramReadByte(entry_addr);
            const entry_lo = self.vramReadByte(entry_addr + 1);
            const entry = (@as(u16, entry_hi) << 8) | entry_lo;
            if (((entry & 0x8000) != 0) != high_priority) continue;

            const pattern_idx = entry & 0x07FF;
            const palette_idx: u8 = @intCast((entry >> 13) & 0x3);
            const vflip = (entry & 0x1000) != 0;
            const hflip = (entry & 0x0800) != 0;

            const px = if (hflip) @as(u8, 7 - fine_x) else fine_x;
            const py = if (vflip) @as(u8, 7 - fine_y) else fine_y;

            const pattern_addr = (@as(u32, pattern_idx) * 32) + (@as(u32, py) * 4) + @as(u32, px / 2);
            const pattern_byte = self.vramReadByte(@intCast(pattern_addr & 0xFFFF));
            const color_idx: u8 = if ((px & 1) == 0) (pattern_byte >> 4) & 0xF else pattern_byte & 0xF;
            if (color_idx == 0) continue;

            self.framebuffer[line_start + x] = self.getPaletteColor(palette_idx * 16 + color_idx);
        }
    }

    fn samplePlanePixel(
        self: *const Vdp,
        plane_base: u32,
        plane_width_tiles: u16,
        plane_height_tiles: u16,
        plane_width_px: i32,
        plane_height_px: i32,
        x_scrolled: i32,
        y_scrolled: i32,
        high_priority: bool,
    ) ?u8 {
        const x_wrapped = @mod(x_scrolled, plane_width_px);
        const y_wrapped = @mod(y_scrolled, plane_height_px);
        const tile_col: u16 = @intCast(@divFloor(x_wrapped, 8));
        const tile_row: u16 = @intCast(@divFloor(y_wrapped, 8));

        const table_index = (@as(u32, tile_row % plane_height_tiles) * @as(u32, plane_width_tiles)) + @as(u32, tile_col % plane_width_tiles);
        const entry_addr: u16 = @intCast((plane_base + (table_index * 2)) & 0xFFFF);
        const entry_hi = self.vramReadByte(entry_addr);
        const entry_lo = self.vramReadByte(entry_addr + 1);
        const entry = (@as(u16, entry_hi) << 8) | entry_lo;
        if (((entry & 0x8000) != 0) != high_priority) return null;

        const pattern_idx = entry & 0x07FF;
        const palette_idx = (entry >> 13) & 0x3;
        const vflip = (entry & 0x1000) != 0;
        const hflip = (entry & 0x0800) != 0;

        const fine_x: u8 = @intCast(@mod(x_wrapped, 8));
        const fine_y: u8 = @intCast(@mod(y_wrapped, 8));
        const px = if (hflip) @as(u8, 7 - fine_x) else fine_x;
        const py = if (vflip) @as(u8, 7 - fine_y) else fine_y;

        const pattern_addr = (@as(u32, pattern_idx) * 32) + (@as(u32, py) * 4) + @as(u32, px / 2);
        const pattern_byte = self.vramReadByte(@intCast(pattern_addr & 0xFFFF));
        const color_idx: u8 = if ((px & 1) == 0) (pattern_byte >> 4) & 0xF else pattern_byte & 0xF;
        if (color_idx == 0) return null;
        return (@as(u8, @intCast(palette_idx)) * 16) + color_idx;
    }

    fn renderSpritesForLine(self: *Vdp, line: u16, high_priority: bool) void {
        const sprite_base = (@as(u32, self.regs[5] & 0x7F) << 9) & 0xFFFF;
        const line_start = @as(usize, line) * 320;
        const y_line: i32 = @intCast(line);

        var sprite_index: u8 = 0;
        var count: u8 = 0;
        while (count < 80) : (count += 1) {
            const entry_addr: u16 = @intCast((sprite_base + (@as(u32, sprite_index) * 8)) & 0xFFFF);
            const y_word = (@as(u16, self.vramReadByte(entry_addr)) << 8) | self.vramReadByte(entry_addr + 1);
            const size = self.vramReadByte(entry_addr + 2);
            const link = self.vramReadByte(entry_addr + 3) & 0x7F;
            const attr = (@as(u16, self.vramReadByte(entry_addr + 4)) << 8) | self.vramReadByte(entry_addr + 5);
            const x_word = (@as(u16, self.vramReadByte(entry_addr + 6)) << 8) | self.vramReadByte(entry_addr + 7);

            const is_high = (attr & 0x8000) != 0;
            if (is_high == high_priority) {
                const h_size: i32 = @as(i32, ((size >> 2) & 0x3)) + 1;
                const v_size: i32 = @as(i32, (size & 0x3)) + 1;
                const sprite_h_px = h_size * 8;
                const sprite_v_px = v_size * 8;
                const y_pos = @as(i32, @intCast(y_word & 0x03FF)) - 128;
                const x_pos = @as(i32, @intCast(x_word & 0x01FF)) - 128;
                const y_in_non_flipped = y_line - y_pos;

                if (y_in_non_flipped >= 0 and y_in_non_flipped < sprite_v_px) {
                    const y_flip = (attr & 0x1000) != 0;
                    const x_flip = (attr & 0x0800) != 0;
                    const palette: u8 = @intCast((attr >> 13) & 0x3);
                    const tile_base: u16 = attr & 0x07FF;
                    const y_in_sprite = if (y_flip) (sprite_v_px - 1 - y_in_non_flipped) else y_in_non_flipped;
                    const tile_y: u16 = @intCast(@divFloor(y_in_sprite, 8));
                    const fine_y: u8 = @intCast(@mod(y_in_sprite, 8));
                    const v_size_u16: u16 = @intCast(v_size);

                    var x_pix: i32 = 0;
                    while (x_pix < sprite_h_px) : (x_pix += 1) {
                        const screen_x = x_pos + x_pix;
                        if (screen_x < 0 or screen_x >= 320) continue;

                        const x_in_sprite = if (x_flip) (sprite_h_px - 1 - x_pix) else x_pix;
                        const tile_x: u16 = @intCast(@divFloor(x_in_sprite, 8));
                        const fine_x: u8 = @intCast(@mod(x_in_sprite, 8));
                        const tile_index: u16 = tile_base + (tile_x * v_size_u16) + tile_y;
                        const pattern_addr = (@as(u32, tile_index) * 32) + (@as(u32, fine_y) * 4) + @as(u32, fine_x / 2);
                        const pattern_byte = self.vramReadByte(@intCast(pattern_addr & 0xFFFF));
                        const color_idx: u8 = if ((fine_x & 1) == 0) (pattern_byte >> 4) & 0xF else pattern_byte & 0xF;
                        if (color_idx == 0) continue;

                        const palette_index = (palette * 16) + color_idx;
                        self.framebuffer[line_start + @as(usize, @intCast(screen_x))] = self.getPaletteColor(palette_index);
                    }
                }
            }

            if (link == 0) break;
            sprite_index = link;
        }
    }

    fn readHScroll(self: *const Vdp, table_base: u16, line: u16, plane_a: bool) i32 {
        const hmode = self.regs[11] & 0x3;
        var offset: u16 = if (plane_a) @as(u16, 0) else @as(u16, 2);
        switch (hmode) {
            2 => {
                // Per-cell (8-pixel row) scroll: use row / 8 * 4.
                const cell_row = (line / 8) * 4;
                offset = cell_row + (if (plane_a) @as(u16, 0) else @as(u16, 2));
            },
            3 => {
                // Per-line scroll.
                const line_index = (line & 0xFF) * 4;
                offset = line_index + (if (plane_a) @as(u16, 0) else @as(u16, 2));
            },
            else => {},
        }
        const word = (@as(u16, self.vramReadByte(table_base + offset)) << 8) | self.vramReadByte(table_base + offset + 1);
        return @as(i16, @bitCast(word));
    }

    fn readVScroll(self: *const Vdp, plane_a: bool) i32 {
        if (((self.regs[11] >> 2) & 1) != 0) {
            // Per-2-cell mode not implemented yet; use first entry as fallback.
        }
        const offset: u16 = if (plane_a) 0 else 2;
        const hi = self.vsram[offset & 0x4F];
        const lo = self.vsram[(offset + 1) & 0x4F];
        const raw = (@as(u16, hi) << 8) | lo;
        return @as(i16, @bitCast(raw & 0x07FF));
    }

    // 0xC00000 - Data Port
    pub fn readData(self: *Vdp) u16 {
        // Read auto-increments address
        defer self.advanceAddr();

        switch (self.code & 0xF) { // Mask to relevant bits
            0x0 => { // VRAM Read
                const val_hi = self.vramReadByte(self.addr);
                const val_lo = self.vramReadByte(self.addr + 1);
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
        if (self.dma_active and self.dma_fill) {
            var len: u32 = self.dma_length;
            if (len == 0) len = 0x10000;
            const target = self.code & 0xF;
            if (target == 0x1) {
                // VRAM fill — fills with high byte.
                const fill_byte: u8 = @intCast((value >> 8) & 0xFF);
                while (len > 0) : (len -= 1) {
                    self.vramWriteByte(self.addr, fill_byte);
                    self.advanceAddr();
                }
            } else if (target == 0x3) {
                // CRAM fill — fills with full word.
                while (len > 0) : (len -= 1) {
                    const idx = self.addr & 0x7F;
                    self.cram[idx] = @intCast((value >> 8) & 0xFF);
                    if (idx + 1 < 128) self.cram[idx + 1] = @intCast(value & 0xFF);
                    self.advanceAddr();
                }
            } else if (target == 0x5) {
                // VSRAM fill — fills with full word.
                while (len > 0) : (len -= 1) {
                    const idx = self.addr & 0x4F;
                    self.vsram[idx] = @intCast((value >> 8) & 0xFF);
                    if (idx + 1 < 80) self.vsram[idx + 1] = @intCast(value & 0xFF);
                    self.advanceAddr();
                }
            }
            self.dma_length = 0;
            self.dma_remaining = 0;
            self.dma_fill = false;
            self.dma_active = false;
            return;
        }

        defer self.advanceAddr();

        // Code determines target:
        // 0001 (1): VRAM Write
        // 0011 (3): CRAM Write
        // 0101 (5): VSRAM Write

        switch (self.code & 0xF) {
            0x1 => { // VRAM Write
                self.dbg_vram_writes += 1;
                self.vramWriteByte(self.addr, @intCast((value >> 8) & 0xFF));
                self.vramWriteByte(self.addr + 1, @intCast(value & 0xFF));
            },
            0x3 => { // CRAM Write
                self.dbg_cram_writes += 1;
                const idx = self.addr & 0x7F;
                self.cram[idx] = @intCast((value >> 8) & 0xFF);
                self.cram[idx + 1] = @intCast(value & 0xFF);
            },
            0x5 => { // VSRAM Write
                self.dbg_vsram_writes += 1;
                const idx = self.addr & 0x4F;
                self.vsram[idx] = @intCast((value >> 8) & 0xFF);
                self.vsram[idx + 1] = @intCast(value & 0xFF);
            },
            else => {
                self.dbg_unknown_writes += 1;
            },
        }
    }

    pub fn advanceAddr(self: *Vdp) void {
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

    fn computeLiveHVCounter(self: *const Vdp) u16 {
        const threshold: i32 = if ((self.regs[1] & 0x08) != 0) 262 else 234;
        const frame_lines: i32 = if (self.pal_mode) clock.pal_lines_per_frame else clock.ntsc_lines_per_frame;
        var v_raw: i32 = self.scanline;
        if (v_raw > threshold) {
            v_raw -= frame_lines;
        }
        const v_counter: u8 = @intCast(@mod(v_raw, 256));
        var h_counter = self.computeHCounterShaped();
        if (self.isInterlaceMode2() and self.odd_frame) {
            h_counter +%= 1;
        }
        return (@as(u16, v_counter) << 8) | h_counter;
    }

    fn computeHCounterShaped(self: *const Vdp) u8 {
        const raw: u16 = @intCast((@as(u32, self.line_master_cycle) + 10) / 20);
        var h: u16 = raw;
        if (h >= 12) h += 0x56;
        h += 0x85;
        return @truncate(h);
    }

    pub fn readHVCounter(self: *const Vdp) u16 {
        if (self.isHVCounterLatchEnabled() and self.hv_latched_valid) {
            return self.hv_latched;
        }
        return self.computeLiveHVCounter();
    }

    /// Update VDP internals for elapsed CPU cycles.
    /// Scanline/vblank state is driven externally by the frame scheduler.
    pub fn step(self: *Vdp, cycles: u32) void {
        const total = @as(u32, self.line_master_cycle) + cycles;
        self.line_master_cycle = @intCast(total % clock.ntsc_master_cycles_per_line);
        self.hblank = self.line_master_cycle >= clock.ntsc_active_master_cycles;
    }

    pub fn setScanlineState(self: *Vdp, line: u16, visible_lines: u16, total_lines: u16) bool {
        if (line != self.scanline) {
            self.line_master_cycle = 0;
        }
        self.scanline = line;
        const in_vblank = line >= visible_lines and line < total_lines;
        const entering_vblank = !self.vblank and in_vblank;
        self.vblank = in_vblank;
        return entering_vblank;
    }

    pub fn setHBlank(self: *Vdp, active: bool) void {
        if (!self.hblank and active and self.isHVCounterLatchEnabled()) {
            self.hv_latched = self.computeLiveHVCounter();
            self.hv_latched_valid = true;
        }
        self.hblank = active;
    }

    pub fn isVBlankInterruptEnabled(self: *const Vdp) bool {
        return (self.regs[1] & 0x20) != 0;
    }

    pub fn isInterlaceMode2(self: *const Vdp) bool {
        return (self.regs[12] & 0x06) == 0x06;
    }

    pub fn isHVCounterLatchEnabled(self: *const Vdp) bool {
        return (self.regs[0] & 0x02) != 0;
    }

    pub fn beginFrame(self: *Vdp) void {
        self.hint_counter = @intCast(self.regs[10]);
    }

    pub fn consumeHintForLine(self: *Vdp, line: u16, visible_lines: u16) bool {
        if (line >= visible_lines) return false;
        self.hint_counter -= 1;
        if (self.hint_counter < 0) {
            self.hint_counter = @intCast(self.regs[10]);
            return (self.regs[0] & 0x10) != 0;
        }
        return false;
    }

    pub fn writeControl(self: *Vdp, value: u16) void {
        // Check for Register Write: 100r rrrr dddd dddd
        // (top 3 bits must be 100; 0xA000/0xB000 are command words, not register writes)
        if ((value & 0xE000) == 0x8000) {
            // Register Write (Mode Set)
            const reg = (value >> 8) & 0x1F;
            const data = value & 0xFF;
            if (reg < self.regs.len) {
                if (reg == 0 and ((self.regs[0] & 0x02) != 0) and ((data & 0x02) == 0)) {
                    self.hv_latched_valid = false;
                }
                self.regs[reg] = @intCast(data);
            }
            // Code & address are not changed by register writes.
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

                // DMA Length (Reg 20 = high byte, Reg 19 = low byte)
                self.dma_length = (@as(u16, self.regs[20]) << 8) | self.regs[19];
                self.dma_remaining = if (self.dma_length == 0) 0x10000 else self.dma_length;

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
                    self.dma_copy = false;
                    self.dma_active = true;
                    // Fill uses the data port write to trigger.
                } else {
                    // VRAM Copy — source is 16-bit (not shifted).
                    self.dma_source_addr = (@as(u32, self.regs[22]) << 8) | @as(u32, self.regs[21]);
                    self.dma_copy = true;
                    self.dma_fill = false;
                    self.dma_active = true;
                }
            }
        }
    }

    pub fn debugDump(self: *const Vdp) void {
        std.debug.print("VDP Code: {X} Addr: {X:0>4} Reg[1]: {X} Reg[15]: {X}\n", .{ self.code, self.addr, self.regs[1], self.regs[15] });
    }
};
