const Vdp = @import("vdp.zig").Vdp;

const color_lut = [8]u8{ 0, 36, 73, 109, 146, 182, 219, 255 };

const SH_NORMAL: u8 = 0;
const SH_SHADOW: u8 = 1;
const SH_HIGHLIGHT: u8 = 2;

const LAYER_BACKDROP: u8 = 0;
const LAYER_PLANE_B_LOW: u8 = 1;
const LAYER_PLANE_A_LOW: u8 = 2;
const LAYER_SPRITE_LOW: u8 = 3;
const LAYER_PLANE_B_HIGH: u8 = 4;
const LAYER_PLANE_A_HIGH: u8 = 5;
const LAYER_SPRITE_HIGH: u8 = 6;

fn layerOrder(source_id: u8, high_pri: bool) u8 {
    return switch (source_id) {
        1 => if (high_pri) LAYER_PLANE_B_HIGH else LAYER_PLANE_B_LOW,
        2 => if (high_pri) LAYER_PLANE_A_HIGH else LAYER_PLANE_A_LOW,
        3 => if (high_pri) LAYER_SPRITE_HIGH else LAYER_SPRITE_LOW,
        else => LAYER_BACKDROP,
    };
}

pub fn getPaletteColor(self: *const Vdp, index: u8) u32 {
    const offset = @as(usize, index & 0x3F) * 2;
    const val_hi = self.cram[offset];
    const val_lo = self.cram[offset + 1];
    const color = (@as(u16, val_hi) << 8) | val_lo;

    const b3: u3 = @intCast((color >> 9) & 0x7);
    const g3: u3 = @intCast((color >> 5) & 0x7);
    const r3: u3 = @intCast((color >> 1) & 0x7);

    const r8: u32 = color_lut[r3];
    const g8: u32 = color_lut[g3];
    const b8: u32 = color_lut[b3];

    return (0xFF000000) | (r8 << 16) | (g8 << 8) | b8;
}

pub fn getPaletteColorShadow(self: *const Vdp, index: u8) u32 {
    const normal = getPaletteColor(self, index);
    const r = (normal >> 16) & 0xFF;
    const g = (normal >> 8) & 0xFF;
    const b = normal & 0xFF;
    return 0xFF000000 | ((r >> 1) << 16) | ((g >> 1) << 8) | (b >> 1);
}

pub fn getPaletteColorHighlight(self: *const Vdp, index: u8) u32 {
    const normal = getPaletteColor(self, index);
    const r: u32 = @min(((normal >> 16) & 0xFF) / 2 + 0x80, 0xFF);
    const g: u32 = @min(((normal >> 8) & 0xFF) / 2 + 0x80, 0xFF);
    const b: u32 = @min((normal & 0xFF) / 2 + 0x80, 0xFF);
    return 0xFF000000 | (r << 16) | (g << 8) | b;
}

pub fn readHScroll(self: *const Vdp, table_base: u16, line: u16, plane_a: bool) i32 {
    const hmode = self.regs[11] & 0x3;
    var offset: u16 = if (plane_a) @as(u16, 0) else @as(u16, 2);
    switch (hmode) {
        2 => {
            const cell_row = (line / 8) * 4;
            offset = cell_row + (if (plane_a) @as(u16, 0) else @as(u16, 2));
        },
        3 => {
            const line_index = (line & 0xFF) * 4;
            offset = line_index + (if (plane_a) @as(u16, 0) else @as(u16, 2));
        },
        else => {},
    }
    const word = (@as(u16, self.vramReadByte(table_base +% offset)) << 8) | self.vramReadByte(table_base +% offset +% 1);
    return @as(i16, @bitCast(word));
}

pub fn readVScroll(self: *const Vdp, plane_a: bool) i32 {
    const offset: u16 = if (plane_a) 0 else 2;
    const hi = self.vsram[offset];
    const lo = self.vsram[offset + 1];
    const raw = (@as(u16, hi) << 8) | lo;
    return @as(i16, @bitCast(raw & 0x07FF));
}

pub fn renderScanline(self: *Vdp, line: u16) void {
    const screen_w = self.screenWidth();
    if (line >= Vdp.max_framebuffer_height) return;
    if (!self.isDisplayEnabled()) {
        const line_start = @as(usize, line) * Vdp.framebuffer_width;
        const backdrop = getPaletteColor(self, self.regs[7] & 0x3F);
        for (0..Vdp.framebuffer_width) |x| {
            self.framebuffer[line_start + x] = backdrop;
        }
        return;
    }

    const sh_mode = self.isShadowHighlightEnabled();
    const tile_h = self.tileHeight();
    const tile_h_shift = self.tileHeightShift();
    const tile_h_mask = self.tileHeightMask();
    const tile_sz = self.tileSizeBytes();

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
    const plane_height_px: i32 = @as(i32, plane_height_tiles) * @as(i32, tile_h);

    const backdrop_idx = self.regs[7] & 0x3F;
    const hscroll_base = (@as(u16, self.regs[13]) & 0x3F) << 10;
    const line_start = @as(usize, line) * Vdp.framebuffer_width;

    var pixel_buf: [Vdp.framebuffer_width]u8 = [_]u8{0} ** Vdp.framebuffer_width;
    var layer_buf: [Vdp.framebuffer_width]u8 = [_]u8{LAYER_BACKDROP} ** Vdp.framebuffer_width;
    var source_buf: [Vdp.framebuffer_width]u8 = [_]u8{0} ** Vdp.framebuffer_width;
    var sh_buf: [Vdp.framebuffer_width]u8 = undefined;
    if (sh_mode) {
        @memset(&sh_buf, SH_SHADOW);
    } else {
        @memset(&sh_buf, SH_NORMAL);
    }

    const win_h_pos = self.regs[17];
    const win_v_pos = self.regs[18];
    const win_right = (win_h_pos & 0x80) != 0;
    const win_h_cell = @as(u16, win_h_pos & 0x1F) * 2;
    const win_down = (win_v_pos & 0x80) != 0;
    const win_v_cell = @as(u16, win_v_pos & 0x1F) * 8;
    const line_in_win_v: bool = if (win_down) (line >= win_v_cell) else (line < win_v_cell);
    const win_left_px: u16 = if (win_right) @min(win_h_cell * 8, screen_w) else 0;
    const win_right_px: u16 = if (win_right) screen_w else @min(win_h_cell * 8, screen_w);

    renderPlaneToBuffer(self, line, plane_b_base, plane_width_tiles, plane_height_tiles, plane_width_px, plane_height_px, hscroll_base, false, tile_h, tile_h_shift, tile_h_mask, tile_sz, &pixel_buf, &layer_buf, &source_buf, 1, 0, screen_w);

    if (line_in_win_v and win_left_px < win_right_px) {
        if (win_left_px > 0) {
            renderPlaneToBuffer(self, line, plane_a_base, plane_width_tiles, plane_height_tiles, plane_width_px, plane_height_px, hscroll_base, true, tile_h, tile_h_shift, tile_h_mask, tile_sz, &pixel_buf, &layer_buf, &source_buf, 2, 0, win_left_px);
        }
        if (win_right_px < screen_w) {
            renderPlaneToBuffer(self, line, plane_a_base, plane_width_tiles, plane_height_tiles, plane_width_px, plane_height_px, hscroll_base, true, tile_h, tile_h_shift, tile_h_mask, tile_sz, &pixel_buf, &layer_buf, &source_buf, 2, win_right_px, screen_w);
        }
        renderWindowToBuffer(self, line, tile_h_shift, tile_h_mask, tile_sz, &pixel_buf, &layer_buf, &source_buf, win_left_px, win_right_px);
    } else {
        renderPlaneToBuffer(self, line, plane_a_base, plane_width_tiles, plane_height_tiles, plane_width_px, plane_height_px, hscroll_base, true, tile_h, tile_h_shift, tile_h_mask, tile_sz, &pixel_buf, &layer_buf, &source_buf, 2, 0, screen_w);
    }

    renderSpritesToBuffer(self, line, tile_h, tile_h_mask, tile_sz, &pixel_buf, &layer_buf, &source_buf, &sh_buf, sh_mode);

    for (0..@as(usize, screen_w)) |x| {
        const pal_idx = pixel_buf[x];
        if (sh_mode) {
            if (pal_idx == 0) {
                self.framebuffer[line_start + x] = getPaletteColorShadow(self, backdrop_idx);
            } else {
                self.framebuffer[line_start + x] = switch (sh_buf[x]) {
                    SH_SHADOW => getPaletteColorShadow(self, pal_idx),
                    SH_HIGHLIGHT => getPaletteColorHighlight(self, pal_idx),
                    else => getPaletteColor(self, pal_idx),
                };
            }
        } else {
            if (pal_idx == 0) {
                self.framebuffer[line_start + x] = getPaletteColor(self, backdrop_idx);
            } else {
                self.framebuffer[line_start + x] = getPaletteColor(self, pal_idx);
            }
        }
    }
    if (screen_w < Vdp.framebuffer_width) {
        const backdrop = getPaletteColor(self, backdrop_idx);
        for (@as(usize, screen_w)..Vdp.framebuffer_width) |x| {
            self.framebuffer[line_start + x] = backdrop;
        }
    }
}

fn renderPlaneToBuffer(
    self: *Vdp,
    line: u16,
    plane_base: u32,
    plane_width_tiles: u16,
    plane_height_tiles: u16,
    plane_width_px: i32,
    plane_height_px: i32,
    hscroll_base: u16,
    is_plane_a: bool,
    tile_h: u8,
    tile_h_shift: u4,
    tile_h_mask: u8,
    tile_sz: u32,
    pixel_buf: *[Vdp.framebuffer_width]u8,
    layer_buf: *[Vdp.framebuffer_width]u8,
    source_buf: *[Vdp.framebuffer_width]u8,
    source_id: u8,
    start_x: u16,
    end_x: u16,
) void {
    const hscroll = readHScroll(self, hscroll_base, line, is_plane_a);
    const vscroll_mode = (self.regs[11] >> 2) & 1;
    _ = tile_h;

    var x: u16 = start_x;
    while (x < end_x) : (x += 1) {
        const vscroll_val: i32 = if (vscroll_mode != 0) blk: {
            const col_pair = x / 16;
            const vs_offset: u16 = if (is_plane_a) col_pair * 4 else col_pair * 4 + 2;
            if (vs_offset + 1 < 80) {
                const hi = self.vsram[vs_offset];
                const lo = self.vsram[vs_offset + 1];
                const raw = (@as(u16, hi) << 8) | lo;
                break :blk @as(i32, @as(i16, @bitCast(raw & 0x07FF)));
            } else {
                break :blk readVScroll(self, is_plane_a);
            }
        } else readVScroll(self, is_plane_a);

        const x_scrolled = @as(i32, @intCast(x)) - hscroll;
        const y_scrolled = @as(i32, line) + vscroll_val;
        const x_wrapped = @mod(x_scrolled, plane_width_px);
        const y_wrapped = @mod(y_scrolled, plane_height_px);
        const tile_col: u16 = @intCast(@divFloor(x_wrapped, 8));
        const tile_row: u16 = @intCast(@as(u32, @intCast(y_wrapped)) >> tile_h_shift);

        const table_index = (@as(u32, tile_row % plane_height_tiles) * @as(u32, plane_width_tiles)) + @as(u32, tile_col % plane_width_tiles);
        const entry_addr: u16 = @intCast((plane_base + (table_index * 2)) & 0xFFFF);
        const entry_hi = self.vramReadByte(entry_addr);
        const entry_lo = self.vramReadByte(entry_addr + 1);
        const entry = (@as(u16, entry_hi) << 8) | entry_lo;

        const pattern_idx = entry & 0x07FF;
        const palette_idx: u8 = @intCast((entry >> 13) & 0x3);
        const vflip = (entry & 0x1000) != 0;
        const hflip = (entry & 0x0800) != 0;
        const high_pri = (entry & 0x8000) != 0;

        const fine_x: u8 = @intCast(@mod(x_wrapped, 8));
        const fine_y: u8 = @intCast(@as(u32, @intCast(y_wrapped)) & tile_h_mask);
        const px = if (hflip) @as(u8, 7) - fine_x else fine_x;
        const py = if (vflip) tile_h_mask - fine_y else fine_y;

        const pattern_addr = (@as(u32, pattern_idx) * tile_sz) + (@as(u32, py) * 4) + @as(u32, px / 2);
        const pattern_byte = self.vramReadByte(@intCast(pattern_addr & 0xFFFF));
        const color_idx: u8 = if ((px & 1) == 0) (pattern_byte >> 4) & 0xF else pattern_byte & 0xF;
        if (color_idx == 0) continue;

        const full_idx = palette_idx * 16 + color_idx;
        const new_layer = layerOrder(source_id, high_pri);
        const cur_layer = layer_buf[x];

        if (new_layer >= cur_layer) {
            pixel_buf[x] = full_idx;
            layer_buf[x] = new_layer;
            source_buf[x] = source_id;
        }
    }
}

fn renderWindowToBuffer(
    self: *Vdp,
    line: u16,
    tile_h_shift: u4,
    tile_h_mask: u8,
    tile_sz: u32,
    pixel_buf: *[Vdp.framebuffer_width]u8,
    layer_buf: *[Vdp.framebuffer_width]u8,
    source_buf: *[Vdp.framebuffer_width]u8,
    start_x: u16,
    end_x: u16,
) void {
    const win_base: u32 = if (self.isH40())
        @as(u32, self.regs[3] & 0x3E) << 10
    else
        @as(u32, self.regs[3] & 0x3F) << 10;
    const win_width: u32 = if (self.isH40()) 64 else 32;
    const tile_row: u32 = @as(u32, line) >> tile_h_shift;
    const fine_y: u8 = @intCast(@as(u32, line) & tile_h_mask);

    var x: u16 = start_x;
    while (x < end_x) : (x += 1) {
        const tile_col: u32 = @as(u32, x) / 8;
        const fine_x: u8 = @intCast(@as(u32, x) % 8);

        const table_index = tile_row * win_width + tile_col;
        const entry_addr: u16 = @intCast((win_base + table_index * 2) & 0xFFFF);
        const entry_hi = self.vramReadByte(entry_addr);
        const entry_lo = self.vramReadByte(entry_addr + 1);
        const entry = (@as(u16, entry_hi) << 8) | entry_lo;

        const pattern_idx = entry & 0x07FF;
        const palette_idx: u8 = @intCast((entry >> 13) & 0x3);
        const vflip = (entry & 0x1000) != 0;
        const hflip = (entry & 0x0800) != 0;
        const high_pri = (entry & 0x8000) != 0;

        const px = if (hflip) @as(u8, 7) - fine_x else fine_x;
        const py = if (vflip) tile_h_mask - fine_y else fine_y;

        const pattern_addr = (@as(u32, pattern_idx) * tile_sz) + (@as(u32, py) * 4) + @as(u32, px / 2);
        const pattern_byte = self.vramReadByte(@intCast(pattern_addr & 0xFFFF));
        const color_idx: u8 = if ((px & 1) == 0) (pattern_byte >> 4) & 0xF else pattern_byte & 0xF;
        if (color_idx == 0) continue;

        const full_idx = palette_idx * 16 + color_idx;
        const new_layer = layerOrder(2, high_pri);
        const cur_layer = layer_buf[x];

        if (new_layer >= cur_layer) {
            pixel_buf[x] = full_idx;
            layer_buf[x] = new_layer;
            source_buf[x] = 2;
        }
    }
}

fn renderSpritesToBuffer(
    self: *Vdp,
    line: u16,
    tile_h: u8,
    tile_h_mask: u8,
    tile_sz: u32,
    pixel_buf: *[Vdp.framebuffer_width]u8,
    layer_buf: *[Vdp.framebuffer_width]u8,
    source_buf: *[Vdp.framebuffer_width]u8,
    sh_buf: *[Vdp.framebuffer_width]u8,
    sh_mode: bool,
) void {
    const screen_w = self.screenWidth();
    const sprite_base: u16 = if (self.isH40())
        ((@as(u16, self.regs[5] & 0x7F) << 9) & 0xFC00)
    else
        ((@as(u16, self.regs[5] & 0x7F) << 9) & 0xFE00);
    const y_line: i32 = @intCast(line);
    const max_sprites = self.maxSpritesPerLine();
    const max_pixels = self.maxSpritePixelsPerLine();
    const max_total = self.maxSpritesTotal();

    var sprites_on_line: u8 = 0;
    var pixels_drawn: u16 = 0;
    var sprite_masked = false;
    var had_nonzero_x = false;
    var dot_overflow = false;

    var sprite_index: u8 = 0;
    var count: u8 = 0;
    while (count < max_total) : (count += 1) {
        if (self.active_execution_counters) |counters| {
            counters.render_sprite_entries += 1;
        }
        const entry_addr: u16 = sprite_base +% (@as(u16, sprite_index) *% 8);
        const y_word = (@as(u16, self.vramReadByte(entry_addr)) << 8) | self.vramReadByte(entry_addr + 1);
        const size = self.vramReadByte(entry_addr + 2);
        const link = self.vramReadByte(entry_addr + 3) & 0x7F;
        const attr = (@as(u16, self.vramReadByte(entry_addr + 4)) << 8) | self.vramReadByte(entry_addr + 5);
        const x_word = (@as(u16, self.vramReadByte(entry_addr + 6)) << 8) | self.vramReadByte(entry_addr + 7);

        const h_size: i32 = @as(i32, ((size >> 2) & 0x3)) + 1;
        const v_size: i32 = @as(i32, (size & 0x3)) + 1;
        const sprite_h_px = h_size * 8;
        const sprite_v_px = v_size * @as(i32, tile_h);
        const y_pos = @as(i32, @intCast(y_word & 0x03FF)) - 128;
        const x_pos_raw: u16 = x_word & 0x01FF;
        const x_pos = @as(i32, @intCast(x_pos_raw)) - 128;
        const y_in_non_flipped = y_line - y_pos;

        if (y_in_non_flipped >= 0 and y_in_non_flipped < sprite_v_px) {
            sprites_on_line += 1;

            if (sprites_on_line > max_sprites) {
                self.sprite_overflow = true;
                break;
            }

            if (x_pos_raw == 0) {
                if (had_nonzero_x or self.sprite_dot_overflow) {
                    sprite_masked = true;
                }
            } else {
                had_nonzero_x = true;
            }

            if (!sprite_masked) {
                const is_high = (attr & 0x8000) != 0;
                const y_flip = (attr & 0x1000) != 0;
                const x_flip = (attr & 0x0800) != 0;
                const palette: u8 = @intCast((attr >> 13) & 0x3);
                const tile_base: u16 = attr & 0x07FF;
                const y_in_sprite = if (y_flip) (sprite_v_px - 1 - y_in_non_flipped) else y_in_non_flipped;
                const tile_y: u16 = @intCast(@as(u32, @intCast(y_in_sprite)) >> @intCast(self.tileHeightShift()));
                const fine_y: u8 = @intCast(@as(u32, @intCast(y_in_sprite)) & tile_h_mask);
                const v_size_u16: u16 = @intCast(v_size);

                var x_pix: i32 = 0;
                while (x_pix < sprite_h_px) : (x_pix += 1) {
                    const screen_x = x_pos + x_pix;
                    if (screen_x < 0 or screen_x >= screen_w) continue;
                    if (self.active_execution_counters) |counters| {
                        counters.render_sprite_pixels += 1;
                    }

                    pixels_drawn += 1;
                    if (pixels_drawn > max_pixels) {
                        dot_overflow = true;
                        break;
                    }

                    const x_in_sprite = if (x_flip) (sprite_h_px - 1 - x_pix) else x_pix;
                    const tile_x: u16 = @intCast(@divFloor(x_in_sprite, 8));
                    const fine_x: u8 = @intCast(@mod(x_in_sprite, 8));
                    const tile_index: u16 = tile_base +% (tile_x *% v_size_u16) +% tile_y;
                    const pattern_addr = (@as(u32, tile_index) * tile_sz) + (@as(u32, fine_y) * 4) + @as(u32, fine_x / 2);
                    const pattern_byte = self.vramReadByte(@intCast(pattern_addr & 0xFFFF));
                    const color_idx: u8 = if ((fine_x & 1) == 0) (pattern_byte >> 4) & 0xF else pattern_byte & 0xF;
                    if (color_idx == 0) continue;
                    if (self.active_execution_counters) |counters| {
                        counters.render_sprite_opaque_pixels += 1;
                    }

                    const sx: usize = @intCast(screen_x);
                    const palette_index = (palette * 16) + color_idx;

                    if (source_buf[sx] == 3) {
                        self.sprite_collision = true;
                    }

                    if (sh_mode and palette == 3 and color_idx == 14) {
                        sh_buf[sx] = SH_NORMAL;
                        continue;
                    }
                    if (sh_mode and palette == 3 and color_idx == 15) {
                        if (sh_buf[sx] == SH_SHADOW) {
                            sh_buf[sx] = SH_NORMAL;
                        } else {
                            sh_buf[sx] = SH_HIGHLIGHT;
                        }
                        continue;
                    }

                    const new_layer = layerOrder(3, is_high);
                    const cur_layer = layer_buf[sx];

                    if (new_layer > cur_layer) {
                        pixel_buf[sx] = palette_index;
                        layer_buf[sx] = new_layer;
                        source_buf[sx] = 3;
                        if (sh_mode) {
                            if (is_high) {
                                sh_buf[sx] = SH_NORMAL;
                            }
                        }
                    }
                }
                if (dot_overflow) break;
            }
        }

        if (link == 0 or link >= max_total) break;
        sprite_index = link;
    }

    self.sprite_dot_overflow = dot_overflow;
}
