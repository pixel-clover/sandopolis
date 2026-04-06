const std = @import("std");
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

const Span = struct {
    start_x: u16 = 0,
    end_x: u16 = 0,

    fn enabled(self: Span) bool {
        return self.start_x < self.end_x;
    }
};

const WindowLineLayout = struct {
    plane_a: Span = .{},
    window: Span = .{},
};

pub fn layerOrder(source_id: u8, high_pri: bool) u8 {
    return switch (source_id) {
        1 => if (high_pri) LAYER_PLANE_B_HIGH else LAYER_PLANE_B_LOW,
        2 => if (high_pri) LAYER_PLANE_A_HIGH else LAYER_PLANE_A_LOW,
        3 => if (high_pri) LAYER_SPRITE_HIGH else LAYER_SPRITE_LOW,
        else => LAYER_BACKDROP,
    };
}

fn paletteColorWord(self: *const Vdp, index: u8) u16 {
    const offset = @as(usize, index & 0x3F) * 2;
    const val_hi = self.cram[offset];
    const val_lo = self.cram[offset +% 1];
    var color = (@as(u16, val_hi) << 8) | val_lo;

    // With palette mode disabled, only the lowest bit of each Mode 5 channel is visible.
    if ((self.regs[0] & 0x04) == 0) {
        color &= 0x0222;
    }

    return color;
}

fn isPlaneDependentReg(reg: u8) bool {
    return switch (reg) {
        2, 4, 11, 12, 13, 16, 17, 18 => true,
        else => false,
    };
}

fn sortCramDotEvents(events: []Vdp.CramDotEvent) void {
    if (events.len < 2) return;

    var si: usize = 1;
    while (si < events.len) : (si += 1) {
        const key = events[si];
        var j = si;
        while (j != 0) {
            const prev = j - 1;
            if (events[prev].pixel_x <= key.pixel_x) break;
            events[j] = events[prev];
            j = prev;
        }
        events[j] = key;
    }
}

fn windowBaseAddress(self: *const Vdp) u32 {
    return if (self.isH40())
        (@as(u32, self.regs[3]) << 10) & 0xF000
    else
        (@as(u32, self.regs[3]) << 10) & 0xF800;
}

fn windowHorizontalLayout(self: *const Vdp, screen_w: u16) WindowLineLayout {
    const split_cells = @as(u16, self.regs[17] & 0x1F);
    const window_right = (self.regs[17] & 0x80) != 0;
    const screen_cells: u16 = if (self.isH40()) 20 else 16;

    if (split_cells == 0) {
        return if (window_right)
            .{ .window = .{ .start_x = 0, .end_x = screen_w } }
        else
            .{ .plane_a = .{ .start_x = 0, .end_x = screen_w } };
    }

    if (split_cells > screen_cells) {
        return if (window_right)
            .{ .plane_a = .{ .start_x = 0, .end_x = screen_w } }
        else
            .{ .window = .{ .start_x = 0, .end_x = screen_w } };
    }

    const split_x = @min(split_cells * 16, screen_w);
    return if (window_right)
        .{
            .plane_a = .{ .start_x = 0, .end_x = split_x },
            .window = .{ .start_x = split_x, .end_x = screen_w },
        }
    else
        .{
            .window = .{ .start_x = 0, .end_x = split_x },
            .plane_a = .{ .start_x = split_x, .end_x = screen_w },
        };
}

fn windowLayoutForLine(self: *const Vdp, line: u16, screen_w: u16) WindowLineLayout {
    const window_down = (self.regs[18] & 0x80) != 0;
    const vertical_boundary = @as(u16, self.regs[18] & 0x1F) * 8;

    if (window_down == (line >= vertical_boundary)) {
        return .{ .window = .{ .start_x = 0, .end_x = screen_w } };
    }

    return windowHorizontalLayout(self, screen_w);
}

pub fn getPaletteColor(self: *const Vdp, index: u8) u32 {
    const color = paletteColorWord(self, index);

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
    const line_mask: u16 = switch (hmode) {
        0 => 0x00,
        1 => 0x07,
        2 => 0xF8,
        else => 0xFF,
    };
    const offset = ((line & line_mask) * 4) + (if (plane_a) @as(u16, 0) else @as(u16, 2));
    const word = (@as(u16, self.vramReadByte(table_base +% offset)) << 8) | self.vramReadByte(table_base +% offset +% 1);
    return @as(i16, @bitCast(word));
}

pub fn readVScroll(self: *const Vdp, plane_a: bool) i32 {
    const offset: u16 = if (plane_a) 0 else 2;
    const hi = self.vsram[offset];
    const lo = self.vsram[offset +% 1];
    const raw = (@as(u16, hi) << 8) | lo;
    return @as(i16, @bitCast(raw & 0x07FF));
}

fn readVScrollColumnRaw(self: *const Vdp, column_pair: u16, plane_a: bool) ?u16 {
    const base_offset = @as(u16, if (plane_a) 0 else 2);
    const offset = column_pair * 4 + base_offset;
    if (offset +% 1 >= self.vsram.len) return null;

    const hi = self.vsram[offset];
    const lo = self.vsram[offset +% 1];
    return ((@as(u16, hi) << 8) | lo) & 0x07FF;
}

fn readVScrollColumn(self: *const Vdp, column_pair: u16, plane_a: bool) i32 {
    const raw = readVScrollColumnRaw(self, column_pair, plane_a) orelse {
        return readVScroll(self, plane_a);
    };
    return @as(i32, raw);
}

fn planeVScrollForPixel(self: *const Vdp, x: u16, hscroll_shift: u4, plane_a: bool) i32 {
    if (((self.regs[11] >> 2) & 1) == 0) return readVScroll(self, plane_a);

    if (hscroll_shift != 0 and x < hscroll_shift) {
        if (!self.isH40()) return 0;

        const plane_a_raw = readVScrollColumnRaw(self, 19, true) orelse 0;
        const plane_b_raw = readVScrollColumnRaw(self, 19, false) orelse 0;
        return @as(i32, plane_a_raw & plane_b_raw);
    }

    const column_pair: u16 = if (hscroll_shift != 0)
        @intCast((@as(u32, x) - hscroll_shift) / 16)
    else
        x / 16;
    return readVScrollColumn(self, column_pair, plane_a);
}

pub fn renderScanline(self: *Vdp, line: u16) void {
    const screen_w = self.screenWidth();
    if (line >= Vdp.max_framebuffer_height) return;

    // Capture per-scanline event logs before clearing.
    const cram_dot_count = self.cram_dot_event_count;
    const cram_dot_events = self.cram_dot_events;
    self.cram_dot_event_count = 0;

    const reg_change_count = self.reg_change_event_count;
    const reg_change_events = self.reg_change_events;
    self.reg_change_event_count = 0;

    // Undo register changes to reconstruct start-of-line state.
    // The current regs reflect end-of-line state after all 68K execution.
    var saved_regs: [32]u8 = undefined;
    if (reg_change_count > 0) {
        saved_regs = self.regs;
        var i: usize = reg_change_count;
        while (i > 0) {
            i -= 1;
            self.regs[reg_change_events[i].reg] = reg_change_events[i].old_value;
        }
    }
    defer if (reg_change_count > 0) {
        self.regs = saved_regs;
    };

    if (!self.isDisplayEnabled() and reg_change_count == 0) {
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

    // Render planes in segments, applying register changes at boundaries.
    // Plane-affecting registers: 2 (plane A base), 4 (plane B base),
    // 11 (scroll mode), 12 (display mode), 13 (hscroll table),
    // 16 (plane size), 17/18 (window).
    var max_rendered_x: u16 = screen_w;
    {
        var seg_start: u16 = 0;
        var effective_w = screen_w;
        while (seg_start < effective_w) {
            // Apply all register changes at or before seg_start
            for (0..@as(usize, reg_change_count)) |ei| {
                const evt = reg_change_events[ei];
                if (evt.pixel_x <= seg_start and isPlaneDependentReg(evt.reg)) {
                    self.regs[evt.reg] = evt.new_value;
                }
            }
            // Recompute effective width after applying register 12 changes.
            effective_w = @max(effective_w, self.screenWidth());

            // Find next plane-affecting register change boundary
            var seg_end = effective_w;
            for (0..@as(usize, reg_change_count)) |ei| {
                const evt = reg_change_events[ei];
                if (evt.pixel_x > seg_start and isPlaneDependentReg(evt.reg)) {
                    seg_end = @min(seg_end, evt.pixel_x);
                    break;
                }
            }

            // Read plane parameters from current register state
            const seg_screen_w = self.screenWidth();
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
            const hscroll_base = (@as(u16, self.regs[13]) & 0x3F) << 10;

            const window_layout = windowLayoutForLine(self, line, seg_screen_w);

            // Clamp segment to current mode's screen width.
            const clamped_end = @min(seg_end, seg_screen_w);
            const seg_plane_b_start = seg_start;
            const seg_plane_b_end = clamped_end;

            renderPlaneToBuffer(self, line, plane_b_base, plane_width_tiles, plane_height_tiles, plane_width_px, plane_height_px, hscroll_base, false, tile_h, tile_h_shift, tile_h_mask, tile_sz, &pixel_buf, &layer_buf, &source_buf, 1, seg_plane_b_start, seg_plane_b_end);

            if (window_layout.plane_a.enabled()) {
                const pa_start = @max(window_layout.plane_a.start_x, seg_start);
                const pa_end = @min(window_layout.plane_a.end_x, clamped_end);
                if (pa_start < pa_end) {
                    renderPlaneToBuffer(self, line, plane_a_base, plane_width_tiles, plane_height_tiles, plane_width_px, plane_height_px, hscroll_base, true, tile_h, tile_h_shift, tile_h_mask, tile_sz, &pixel_buf, &layer_buf, &source_buf, 2, pa_start, pa_end);
                }
            }
            if (window_layout.window.enabled()) {
                const win_start = @max(window_layout.window.start_x, seg_start);
                const win_end = @min(window_layout.window.end_x, clamped_end);
                if (win_start < win_end) {
                    renderWindowToBuffer(self, line, tile_h_shift, tile_h_mask, tile_sz, &pixel_buf, &layer_buf, &source_buf, win_start, win_end);
                }
            }

            seg_start = seg_end;
        }
        max_rendered_x = effective_w;

        // Restore regs to the state expected by the output pass (undo plane-only changes).
        // The output pass will replay ALL events from the beginning.
        if (reg_change_count > 0) {
            // Reset to start-of-line state for the output pass
            var k: usize = reg_change_count;
            while (k > 0) {
                k -= 1;
                self.regs[reg_change_events[k].reg] = reg_change_events[k].old_value;
            }
        }
    }

    renderSpritesToBuffer(self, line, tile_h, tile_h_mask, tile_sz, &pixel_buf, &layer_buf, &source_buf, &sh_buf, sh_mode);

    // Output pass: apply register changes at the correct pixel positions and
    // render each visible pixel with the current register state.
    {
        var event_cursor: usize = 0;
        const output_w = @min(max_rendered_x, Vdp.framebuffer_width);
        for (0..output_w) |x| {
            const x_px: u16 = @intCast(x);
            while (event_cursor < reg_change_count and reg_change_events[event_cursor].pixel_x <= x_px) {
                const evt = reg_change_events[event_cursor];
                self.regs[evt.reg] = evt.new_value;
                event_cursor += 1;
            }

            const cur_w = self.screenWidth();
            if (x_px >= cur_w) continue;

            const display_on = self.isDisplayEnabled();
            const seg_backdrop_idx = self.regs[7] & 0x3F;
            const seg_sh = self.isShadowHighlightEnabled();
            const pal_idx = pixel_buf[x];
            if (!display_on) {
                self.framebuffer[line_start + x] = getPaletteColor(self, seg_backdrop_idx);
            } else if (seg_sh) {
                if (pal_idx == 0) {
                    self.framebuffer[line_start + x] = getPaletteColorShadow(self, seg_backdrop_idx);
                } else {
                    self.framebuffer[line_start + x] = switch (sh_buf[x]) {
                        SH_SHADOW => getPaletteColorShadow(self, pal_idx),
                        SH_HIGHLIGHT => getPaletteColorHighlight(self, pal_idx),
                        else => getPaletteColor(self, pal_idx),
                    };
                }
            } else {
                if (pal_idx == 0) {
                    self.framebuffer[line_start + x] = getPaletteColor(self, seg_backdrop_idx);
                } else {
                    self.framebuffer[line_start + x] = getPaletteColor(self, pal_idx);
                }
            }
        }

        while (event_cursor < reg_change_count) {
            const evt = reg_change_events[event_cursor];
            self.regs[evt.reg] = evt.new_value;
            event_cursor += 1;
        }
    }

    // Fill pixels beyond the final active display width with backdrop.
    {
        const final_w = self.screenWidth();
        const fill_start = @min(final_w, max_rendered_x);
        if (fill_start < Vdp.framebuffer_width) {
            const final_backdrop = getPaletteColor(self, self.regs[7] & 0x3F);
            for (@as(usize, fill_start)..Vdp.framebuffer_width) |x| {
                self.framebuffer[line_start + x] = final_backdrop;
            }
        }
    }

    if ((self.regs[0] & 0x20) != 0) {
        const clipped_backdrop = getPaletteColor(self, self.regs[7] & 0x3F);
        const clip_width = @min(@as(usize, 8), @as(usize, screen_w));
        for (0..clip_width) |x| {
            self.framebuffer[line_start + x] = clipped_backdrop;
        }
    }

    // Apply mid-scanline CRAM updates.
    // On real hardware, a CRAM write during active display changes the palette
    // permanently: all subsequent pixels using that entry get the new color.
    // There is also a single-pixel "dot" artifact at the write position where
    // the written value is OR'd with the display output.
    //
    // Strategy: undo all CRAM events to get the start-of-line palette, sort
    // events by pixel position, then re-render pixel spans between events.
    if (cram_dot_count > 0) {
        // Sort events by pixel_x using insertion sort (small N).
        var sorted: [Vdp.max_cram_dot_events]Vdp.CramDotEvent = undefined;
        @memcpy(sorted[0..cram_dot_count], cram_dot_events[0..cram_dot_count]);
        sortCramDotEvents(sorted[0..cram_dot_count]);

        // Undo events in reverse to get start-of-line CRAM.
        {
            var ui: usize = cram_dot_count;
            while (ui > 0) {
                ui -= 1;
                const ev = cram_dot_events[ui]; // use original order for undo
                self.cram[ev.cram_addr] = ev.old_hi;
                self.cram[ev.cram_addr +% 1] = ev.old_lo;
            }
        }

        // Re-render from the earliest visible event (or pixel 0 if all
        // events are in HBlank) to end of screen, applying CRAM changes
        // at each event's pixel position.  Even if all events are in
        // HBlank, we must re-render the visible area because the main
        // pipeline used end-of-line CRAM.  Use max_rendered_x to cover
        // all pixels that were rendered by the output pass (accounts for
        // mid-scanline H32/H40 mode switches).
        const cram_render_w: usize = @as(usize, max_rendered_x);
        const backdrop_idx = self.regs[7] & 0x3F;
        const first_px: usize = @min(@as(usize, sorted[0].pixel_x), cram_render_w);
        var ev_idx: usize = 0;

        // Re-render from pixel 0 if any CRAM change happened (even in HBlank).
        const render_start: usize = if (first_px >= cram_render_w) 0 else first_px;

        for (render_start..cram_render_w) |x| {
            // Apply all CRAM events BEFORE this pixel (strictly less than).
            // Events at earlier positions must update the palette before we
            // render this pixel.
            while (ev_idx < @as(usize, cram_dot_count) and sorted[ev_idx].pixel_x < @as(u16, @intCast(x))) {
                const ev = sorted[ev_idx];
                const masked = ev.written_word & 0x0EEE;
                self.cram[ev.cram_addr] = @intCast((masked >> 8) & 0xFF);
                self.cram[ev.cram_addr +% 1] = @intCast(masked & 0xFF);
                ev_idx += 1;
            }

            // Check if a CRAM event fires at exactly this pixel position.
            // The dot artifact uses the pre-write palette color (current
            // CRAM state before this event is applied).
            var dot_word: ?u16 = null;
            if (ev_idx < @as(usize, cram_dot_count) and sorted[ev_idx].pixel_x == @as(u16, @intCast(x))) {
                dot_word = sorted[ev_idx].written_word;
            }

            // Render the pixel with the current palette (pre-event for dots).
            const pal_idx = if (pixel_buf[x] == 0) backdrop_idx else pixel_buf[x];
            if (sh_mode) {
                if (pixel_buf[x] == 0) {
                    self.framebuffer[line_start + x] = getPaletteColorShadow(self, backdrop_idx);
                } else {
                    self.framebuffer[line_start + x] = switch (sh_buf[x]) {
                        SH_SHADOW => getPaletteColorShadow(self, pal_idx),
                        SH_HIGHLIGHT => getPaletteColorHighlight(self, pal_idx),
                        else => getPaletteColor(self, pal_idx),
                    };
                }
            } else {
                self.framebuffer[line_start + x] = getPaletteColor(self, pal_idx);
            }

            // CRAM dot artifact: OR the written 9-bit color with the
            // display output at the write position.
            if (dot_word) |written| {
                const dot_masked = written & 0x0EEE;
                const b3: u3 = @intCast((dot_masked >> 9) & 0x7);
                const g3: u3 = @intCast((dot_masked >> 5) & 0x7);
                const r3: u3 = @intCast((dot_masked >> 1) & 0x7);
                const dot_argb: u32 = (@as(u32, color_lut[r3]) << 16) |
                    (@as(u32, color_lut[g3]) << 8) |
                    @as(u32, color_lut[b3]);
                self.framebuffer[line_start + x] |= dot_argb;
            }

            // Now apply the event at this pixel position (if any).
            while (ev_idx < @as(usize, cram_dot_count) and sorted[ev_idx].pixel_x <= @as(u16, @intCast(x))) {
                const ev = sorted[ev_idx];
                const masked = ev.written_word & 0x0EEE;
                self.cram[ev.cram_addr] = @intCast((masked >> 8) & 0xFF);
                self.cram[ev.cram_addr +% 1] = @intCast(masked & 0xFF);
                ev_idx += 1;
            }
        }
        // Apply remaining events beyond the visible area (HBlank CRAM
        // writes with pixel_x >= screen_w).  This restores CRAM to the
        // correct end-of-line state for the next scanline.
        while (ev_idx < @as(usize, cram_dot_count)) {
            const ev = sorted[ev_idx];
            const masked = ev.written_word & 0x0EEE;
            self.cram[ev.cram_addr] = @intCast((masked >> 8) & 0xFF);
            self.cram[ev.cram_addr +% 1] = @intCast(masked & 0xFF);
            ev_idx += 1;
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
    const hscroll_shift: u4 = @truncate(@as(u16, @bitCast(@as(i16, @intCast(hscroll)))));
    _ = tile_h;

    const render_start_x: u16 = if (is_plane_a and start_x != 0 and hscroll_shift != 0)
        @min(end_x, start_x + hscroll_shift)
    else
        start_x;

    var x: u16 = render_start_x;
    while (x < end_x) : (x += 1) {
        const vscroll_val = planeVScrollForPixel(self, x, hscroll_shift, is_plane_a);

        const x_scrolled = @as(i32, @intCast(x)) - hscroll;
        const y_scrolled = @as(i32, line) + vscroll_val;
        const x_wrapped = @mod(x_scrolled, plane_width_px);
        const y_wrapped = @mod(y_scrolled, plane_height_px);
        const tile_col: u16 = @intCast(@divFloor(x_wrapped, 8));
        const tile_row: u16 = @intCast(@as(u32, @intCast(y_wrapped)) >> tile_h_shift);

        const table_index = (@as(u32, tile_row % plane_height_tiles) * @as(u32, plane_width_tiles)) + @as(u32, tile_col % plane_width_tiles);
        const entry_addr: u16 = @intCast((plane_base + (table_index * 2)) & 0xFFFF);
        const entry_hi = self.vramReadByte(entry_addr);
        const entry_lo = self.vramReadByte(entry_addr +% 1);
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
    const win_base = windowBaseAddress(self);
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
        const entry_lo = self.vramReadByte(entry_addr +% 1);
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

test "window base address masks ignored bits in h32 and h40 modes" {
    var h32 = Vdp.init();
    h32.regs[12] = 0x00;
    h32.regs[3] = 0x01;
    try std.testing.expectEqual(@as(u32, 0x0000), windowBaseAddress(&h32));

    var h40 = Vdp.init();
    h40.regs[12] = 0x01;
    h40.regs[3] = 0x02;
    try std.testing.expectEqual(@as(u32, 0x0000), windowBaseAddress(&h40));

    h32.regs[3] = 0x3F;
    try std.testing.expectEqual(@as(u32, 0xF800), windowBaseAddress(&h32));

    h40.regs[3] = 0x3F;
    try std.testing.expectEqual(@as(u32, 0xF000), windowBaseAddress(&h40));
}

test "window layout matches hardware full-line and split behavior" {
    var vdp = Vdp.init();
    vdp.regs[12] = 0x01;
    vdp.regs[17] = 0x81;
    vdp.regs[18] = 0x01;

    const top_layout = windowLayoutForLine(&vdp, 0, 320);
    try std.testing.expect(!top_layout.plane_a.enabled());
    try std.testing.expectEqual(@as(u16, 0), top_layout.window.start_x);
    try std.testing.expectEqual(@as(u16, 320), top_layout.window.end_x);

    const lower_layout = windowLayoutForLine(&vdp, 8, 320);
    try std.testing.expectEqual(@as(u16, 0), lower_layout.plane_a.start_x);
    try std.testing.expectEqual(@as(u16, 16), lower_layout.plane_a.end_x);
    try std.testing.expectEqual(@as(u16, 16), lower_layout.window.start_x);
    try std.testing.expectEqual(@as(u16, 320), lower_layout.window.end_x);
}

test "window renderer uses masked base address bits" {
    var vdp = Vdp.init();
    vdp.regs[0] = 0x04;
    vdp.regs[1] = 0x40;
    vdp.regs[3] = 0x06;
    vdp.regs[7] = 0x00;
    vdp.regs[12] = 0x01;
    vdp.regs[17] = 0x80;
    vdp.regs[18] = 0x80;

    // Palette 0 color 1 = red, color 2 = green.
    vdp.cram[2] = 0x00;
    vdp.cram[3] = 0x0E;
    vdp.cram[4] = 0x00;
    vdp.cram[5] = 0xE0;

    // Tile 0 uses color 1, tile 1 uses color 2.
    vdp.vramWriteByte(0x0000, 0x11);
    vdp.vramWriteByte(0x0001, 0x11);
    vdp.vramWriteByte(0x0002, 0x11);
    vdp.vramWriteByte(0x0003, 0x11);
    vdp.vramWriteByte(0x0020, 0x22);
    vdp.vramWriteByte(0x0021, 0x22);
    vdp.vramWriteByte(0x0022, 0x22);
    vdp.vramWriteByte(0x0023, 0x22);

    // Correct base in H40 masks register 3 to 0x1000.
    vdp.vramWriteWord(0x1000, 0x0000);
    // Old decode would incorrectly fetch the window tile from 0x1800.
    vdp.vramWriteWord(0x1800, 0x0001);

    vdp.renderScanline(0);

    try std.testing.expectEqual(@as(u32, 0xFFFF0000), vdp.framebuffer[0]);
    try std.testing.expect(vdp.framebuffer[0] != @as(u32, 0xFF00FF00));
}

test "per-column vscroll follows shifted visible columns and special leftmost partial column" {
    var vdp = Vdp.init();
    vdp.regs[0] = 0x04;
    vdp.regs[1] = 0x40;
    vdp.regs[4] = 0x01;
    vdp.regs[7] = 0x00;
    vdp.regs[11] = 0x04;
    vdp.regs[12] = 0x01;
    vdp.regs[13] = 0x01;

    // Palette 0 colors: 1 = red, 2 = green, 3 = blue, 4 = yellow.
    vdp.cram[2] = 0x00;
    vdp.cram[3] = 0x0E;
    vdp.cram[4] = 0x00;
    vdp.cram[5] = 0xE0;
    vdp.cram[6] = 0x0E;
    vdp.cram[7] = 0x00;
    vdp.cram[8] = 0x0E;
    vdp.cram[9] = 0xEE;

    // Tiles 1-4 are solid colors 1-4.
    for (0..4) |row| {
        const row_offset: u16 = @intCast(row * 4);
        vdp.vramWriteByte(0x0020 + row_offset, 0x11);
        vdp.vramWriteByte(0x0021 + row_offset, 0x11);
        vdp.vramWriteByte(0x0022 + row_offset, 0x11);
        vdp.vramWriteByte(0x0023 + row_offset, 0x11);

        vdp.vramWriteByte(0x0040 + row_offset, 0x22);
        vdp.vramWriteByte(0x0041 + row_offset, 0x22);
        vdp.vramWriteByte(0x0042 + row_offset, 0x22);
        vdp.vramWriteByte(0x0043 + row_offset, 0x22);

        vdp.vramWriteByte(0x0060 + row_offset, 0x33);
        vdp.vramWriteByte(0x0061 + row_offset, 0x33);
        vdp.vramWriteByte(0x0062 + row_offset, 0x33);
        vdp.vramWriteByte(0x0063 + row_offset, 0x33);

        vdp.vramWriteByte(0x0080 + row_offset, 0x44);
        vdp.vramWriteByte(0x0081 + row_offset, 0x44);
        vdp.vramWriteByte(0x0082 + row_offset, 0x44);
        vdp.vramWriteByte(0x0083 + row_offset, 0x44);
    }

    // HScroll plane B word: shift by 4 pixels.
    vdp.vramWriteWord(0x0402, 0x0004);

    // Plane B name table at 0x2000.
    vdp.vramWriteWord(0x2000, 0x0001); // row 0, col 0 => red
    vdp.vramWriteWord(0x2040, 0x0004); // row 1, col 0 => yellow
    vdp.vramWriteWord(0x203E, 0x0003); // row 0, col 31 => blue
    vdp.vramWriteWord(0x207E, 0x0002); // row 1, col 31 => green

    // Special H40 partial-column value comes from column 19 and is shared.
    vdp.vsram[76] = 0x00;
    vdp.vsram[77] = 0x08;
    vdp.vsram[78] = 0x00;
    vdp.vsram[79] = 0x08;

    vdp.renderScanline(0);

    try std.testing.expectEqual(@as(u32, 0xFF00FF00), vdp.framebuffer[0]);
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), vdp.framebuffer[4]);
}

test "8-line hscroll mode uses the masked line index spacing from hardware" {
    var vdp = Vdp.init();
    vdp.regs[11] = 0x02;

    vdp.vramWriteWord(0x0400, 0x0011);
    vdp.vramWriteWord(0x0402, 0x0022);
    vdp.vramWriteWord(0x0420, 0x0033);
    vdp.vramWriteWord(0x0422, 0x0044);

    try std.testing.expectEqual(@as(i32, 0x0011), readHScroll(&vdp, 0x0400, 0, true));
    try std.testing.expectEqual(@as(i32, 0x0022), readHScroll(&vdp, 0x0400, 0, false));
    try std.testing.expectEqual(@as(i32, 0x0033), readHScroll(&vdp, 0x0400, 8, true));
    try std.testing.expectEqual(@as(i32, 0x0044), readHScroll(&vdp, 0x0400, 8, false));
}

test "reg 0 left-column blanking forces the first 8 pixels to backdrop" {
    var vdp = Vdp.init();
    vdp.regs[0] = 0x24;
    vdp.regs[1] = 0x40;
    vdp.regs[4] = 0x01;
    vdp.regs[7] = 0x00;

    vdp.cram[0] = 0x00;
    vdp.cram[1] = 0x00;
    vdp.cram[2] = 0x00;
    vdp.cram[3] = 0x0E;

    for (0..4) |row| {
        const row_offset: u16 = @intCast(row * 4);
        vdp.vramWriteByte(0x0020 + row_offset, 0x11);
        vdp.vramWriteByte(0x0021 + row_offset, 0x11);
        vdp.vramWriteByte(0x0022 + row_offset, 0x11);
        vdp.vramWriteByte(0x0023 + row_offset, 0x11);
    }

    vdp.vramWriteWord(0x2000, 0x0001);
    vdp.vramWriteWord(0x2002, 0x0001);
    vdp.renderScanline(0);

    for (0..8) |x| {
        try std.testing.expectEqual(@as(u32, 0xFF000000), vdp.framebuffer[x]);
    }
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), vdp.framebuffer[8]);
}

test "plane A window split honors the shifted left-edge gap" {
    var vdp = Vdp.init();
    vdp.regs[0] = 0x04;
    vdp.regs[1] = 0x40;
    vdp.regs[2] = 0x30;
    vdp.regs[4] = 0x01;
    vdp.regs[7] = 0x00;
    vdp.regs[12] = 0x01;
    vdp.regs[13] = 0x01;
    vdp.regs[17] = 0x01;
    vdp.regs[18] = 0x81;

    vdp.cram[2] = 0x00;
    vdp.cram[3] = 0x0E;
    vdp.cram[4] = 0x0E;
    vdp.cram[5] = 0x00;

    for (0..4) |row| {
        const row_offset: u16 = @intCast(row * 4);
        vdp.vramWriteByte(0x0020 + row_offset, 0x11);
        vdp.vramWriteByte(0x0021 + row_offset, 0x11);
        vdp.vramWriteByte(0x0022 + row_offset, 0x11);
        vdp.vramWriteByte(0x0023 + row_offset, 0x11);

        vdp.vramWriteByte(0x0040 + row_offset, 0x22);
        vdp.vramWriteByte(0x0041 + row_offset, 0x22);
        vdp.vramWriteByte(0x0042 + row_offset, 0x22);
        vdp.vramWriteByte(0x0043 + row_offset, 0x22);
    }

    vdp.vramWriteWord(0x0400, 0x0004);

    vdp.vramWriteWord(0x2000, 0x0002);
    vdp.vramWriteWord(0x2002, 0x0002);
    vdp.vramWriteWord(0x2004, 0x0002);
    vdp.vramWriteWord(0xC000, 0x0001);
    vdp.vramWriteWord(0xC002, 0x0001);
    vdp.vramWriteWord(0xC004, 0x0001);

    vdp.renderScanline(0);

    try std.testing.expectEqual(@as(u32, 0xFF0000FF), vdp.framebuffer[16]);
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), vdp.framebuffer[20]);
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
    const screen_w_i32: i32 = @intCast(screen_w);
    const y_line: i32 = @intCast(line);
    const tile_h_shift = self.tileHeightShift();
    const max_sprites = self.maxSpritesPerLine();
    const max_pixels = self.maxSpritePixelsPerLine();
    const max_total = self.maxSpritesTotal();
    self.ensureSpriteCache();

    // Collision buffer covers the full 512-pixel internal coordinate space.
    // On real hardware, the VDP detects sprite overlap across all positions,
    // including off-screen pixels outside the visible display area.
    var collision_buf = [_]u8{0} ** 512;

    var sprites_on_line: u8 = 0;
    var pixel_budget_used: u16 = 0;
    var sprite_masked = false;
    var had_nonzero_x = false;
    var next_line_mask = false;

    var sprite_index: u8 = 0;
    var count: u8 = 0;
    while (count < max_total) : (count += 1) {
        if (self.active_execution_counters) |counters| {
            counters.render_sprite_entries += 1;
        }
        const entry = self.sprite_cache_entries[sprite_index];
        const sprite_v_px = @as(i32, entry.v_size) * @as(i32, tile_h);
        const y_in_non_flipped = y_line - @as(i32, entry.y_pos);

        if (y_in_non_flipped >= 0 and y_in_non_flipped < sprite_v_px) {
            sprites_on_line += 1;

            if (sprites_on_line > max_sprites) {
                self.sprite_overflow = true;
                break;
            }

            const sprite_width_px: u16 = @as(u16, entry.h_size) * 8;
            const new_pixel_budget = pixel_budget_used + sprite_width_px;
            var draw_width_px = sprite_width_px;
            if (new_pixel_budget > max_pixels) {
                draw_width_px -= new_pixel_budget - max_pixels;
            }
            pixel_budget_used = new_pixel_budget;

            if (entry.x_pos_raw == 0) {
                if (had_nonzero_x or self.sprite_dot_overflow) {
                    sprite_masked = true;
                }
            } else {
                had_nonzero_x = true;
            }

            if (!sprite_masked) {
                const y_in_sprite = if (entry.y_flip) (sprite_v_px - 1 - y_in_non_flipped) else y_in_non_flipped;
                const tile_y: u16 = @intCast(@as(u32, @intCast(y_in_sprite)) >> tile_h_shift);
                const fine_y: u8 = @intCast(@as(u32, @intCast(y_in_sprite)) & tile_h_mask);
                const h_size_u16 = @as(u16, entry.h_size);
                const v_size_u16 = @as(u16, entry.v_size);
                var sprite_limit_hit = false;

                var screen_tile_x: u16 = 0;
                while (screen_tile_x < h_size_u16) : (screen_tile_x += 1) {
                    const tile_screen_start = @as(i32, entry.x_pos) + (@as(i32, screen_tile_x) * 8);
                    const tile_x: u16 = if (entry.x_flip) h_size_u16 - 1 - screen_tile_x else screen_tile_x;
                    const tile_index: u16 = entry.tile_base +% (tile_x *% v_size_u16) +% tile_y;
                    const pattern_row_addr = (@as(u32, tile_index) * tile_sz) + (@as(u32, fine_y) * 4);
                    const pattern_row = [4]u8{
                        self.vramReadByte(@intCast(pattern_row_addr & 0xFFFF)),
                        self.vramReadByte(@intCast((pattern_row_addr + 1) & 0xFFFF)),
                        self.vramReadByte(@intCast((pattern_row_addr + 2) & 0xFFFF)),
                        self.vramReadByte(@intCast((pattern_row_addr + 3) & 0xFFFF)),
                    };

                    // Iterate over all 8 pixels in the tile for collision detection,
                    // including off-screen pixels. Only draw visible ones to the framebuffer.
                    var px_in_tile: u8 = 0;
                    while (px_in_tile < 8) : (px_in_tile += 1) {
                        const sprite_px = (screen_tile_x * 8) + px_in_tile;
                        if (sprite_px >= draw_width_px) {
                            sprite_limit_hit = true;
                            break;
                        }

                        const fine_x: u8 = if (entry.x_flip) @as(u8, 7) - px_in_tile else px_in_tile;
                        const pattern_byte = pattern_row[fine_x >> 1];
                        const color_idx: u8 = if ((fine_x & 1) == 0) (pattern_byte >> 4) & 0xF else pattern_byte & 0xF;
                        if (color_idx == 0) continue;

                        // Collision detection in the full 512-pixel internal space.
                        // The VDP wraps the 9-bit X coordinate, so pixels past
                        // position 511 wrap to position 0.
                        const col_x: i32 = tile_screen_start + px_in_tile;
                        const raw_x = @as(u32, @intCast(col_x + 128)) & 0x1FF;
                        if (collision_buf[raw_x] != 0) {
                            self.sprite_collision = true;
                        }
                        collision_buf[raw_x] = 1;

                        // Only render to the framebuffer for visible pixels.
                        const screen_x = tile_screen_start + @as(i32, px_in_tile);
                        if (screen_x < 0 or screen_x >= screen_w_i32) continue;

                        if (self.active_execution_counters) |counters| {
                            counters.render_sprite_pixels += 1;
                        }
                        if (self.active_execution_counters) |counters| {
                            counters.render_sprite_opaque_pixels += 1;
                        }

                        const sx: usize = @intCast(screen_x);
                        const palette_index = (entry.palette * 16) + color_idx;

                        if (sh_mode and entry.palette == 3 and color_idx == 14) {
                            sh_buf[sx] = SH_NORMAL;
                            continue;
                        }
                        if (sh_mode and entry.palette == 3 and color_idx == 15) {
                            if (sh_buf[sx] == SH_SHADOW) {
                                sh_buf[sx] = SH_NORMAL;
                            } else {
                                sh_buf[sx] = SH_HIGHLIGHT;
                            }
                            continue;
                        }

                        const cur_layer = layer_buf[sx];
                        if (entry.new_layer > cur_layer) {
                            pixel_buf[sx] = palette_index;
                            layer_buf[sx] = entry.new_layer;
                            source_buf[sx] = 3;
                            if (sh_mode and entry.is_high) {
                                sh_buf[sx] = SH_NORMAL;
                            }
                        }
                    }
                    if (sprite_limit_hit) break;
                }
            }

            if (pixel_budget_used >= max_pixels) {
                next_line_mask = true;
                break;
            }
        }

        if (entry.link == 0 or entry.link >= max_total) break;
        sprite_index = entry.link;
    }

    self.sprite_dot_overflow = next_line_mask;
}

fn seedAscendingSpritePattern(vdp: *Vdp, tile_index: u16) void {
    const pattern_addr = @as(u32, tile_index) * vdp.tileSizeBytes();
    vdp.vramWriteByte(@intCast(pattern_addr & 0xFFFF), 0x12);
    vdp.vramWriteByte(@intCast((pattern_addr + 1) & 0xFFFF), 0x34);
    vdp.vramWriteByte(@intCast((pattern_addr + 2) & 0xFFFF), 0x56);
    vdp.vramWriteByte(@intCast((pattern_addr + 3) & 0xFFFF), 0x78);
}

fn writeTestSpriteEntryFull(vdp: *Vdp, sprite_base: u16, y: u16, size: u8, link: u8, attr: u16, x: u16) void {
    vdp.vramWriteWord(sprite_base, y);
    vdp.vramWriteByte(sprite_base + 2, size);
    vdp.vramWriteByte(sprite_base + 3, link);
    vdp.vramWriteWord(sprite_base + 4, attr);
    vdp.vramWriteWord(sprite_base + 6, x);
}

fn writeTestSpriteEntry(vdp: *Vdp, sprite_base: u16, attr: u16, x: u16) void {
    writeTestSpriteEntryFull(vdp, sprite_base, 128, 0x00, 0x00, attr, x);
}

fn clearSpriteBuffers(
    pixel_buf: *[Vdp.framebuffer_width]u8,
    layer_buf: *[Vdp.framebuffer_width]u8,
    source_buf: *[Vdp.framebuffer_width]u8,
    sh_buf: *[Vdp.framebuffer_width]u8,
) void {
    @memset(pixel_buf, 0);
    @memset(layer_buf, LAYER_BACKDROP);
    @memset(source_buf, 0);
    @memset(sh_buf, SH_NORMAL);
}

fn renderSpriteLineForTest(
    vdp: *Vdp,
    pixel_buf: *[Vdp.framebuffer_width]u8,
    layer_buf: *[Vdp.framebuffer_width]u8,
    source_buf: *[Vdp.framebuffer_width]u8,
    sh_buf: *[Vdp.framebuffer_width]u8,
) void {
    renderSpritesToBuffer(
        vdp,
        0,
        vdp.tileHeight(),
        vdp.tileHeightMask(),
        vdp.tileSizeBytes(),
        pixel_buf,
        layer_buf,
        source_buf,
        sh_buf,
        false,
    );
}

test "sprite renderer draws a simple sprite row and tracks counters" {
    var vdp = Vdp.init();
    vdp.regs[1] = 0x40;
    vdp.regs[5] = 0x01;

    seedAscendingSpritePattern(&vdp, 0);

    const sprite_base: u16 = 0x0200;
    writeTestSpriteEntry(&vdp, sprite_base, 0x0000, 128);

    var pixel_buf: [Vdp.framebuffer_width]u8 = [_]u8{0} ** Vdp.framebuffer_width;
    var layer_buf: [Vdp.framebuffer_width]u8 = [_]u8{LAYER_BACKDROP} ** Vdp.framebuffer_width;
    var source_buf: [Vdp.framebuffer_width]u8 = [_]u8{0} ** Vdp.framebuffer_width;
    var sh_buf: [Vdp.framebuffer_width]u8 = [_]u8{SH_NORMAL} ** Vdp.framebuffer_width;
    var counters = @import("../performance_profile.zig").CoreFrameCounters{};
    vdp.setActiveExecutionCounters(&counters);
    defer vdp.setActiveExecutionCounters(null);

    renderSpriteLineForTest(&vdp, &pixel_buf, &layer_buf, &source_buf, &sh_buf);

    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 }, pixel_buf[0..8]);
    try std.testing.expectEqual(@as(u64, 1), counters.render_sprite_entries);
    try std.testing.expectEqual(@as(u64, 8), counters.render_sprite_pixels);
    try std.testing.expectEqual(@as(u64, 8), counters.render_sprite_opaque_pixels);
}

test "sprite renderer respects horizontal flip" {
    var vdp = Vdp.init();
    vdp.regs[1] = 0x40;
    vdp.regs[5] = 0x01;

    seedAscendingSpritePattern(&vdp, 0);

    const sprite_base: u16 = 0x0200;
    writeTestSpriteEntry(&vdp, sprite_base, 0x0800, 128);

    var pixel_buf: [Vdp.framebuffer_width]u8 = [_]u8{0} ** Vdp.framebuffer_width;
    var layer_buf: [Vdp.framebuffer_width]u8 = [_]u8{LAYER_BACKDROP} ** Vdp.framebuffer_width;
    var source_buf: [Vdp.framebuffer_width]u8 = [_]u8{0} ** Vdp.framebuffer_width;
    var sh_buf: [Vdp.framebuffer_width]u8 = [_]u8{SH_NORMAL} ** Vdp.framebuffer_width;

    renderSpriteLineForTest(&vdp, &pixel_buf, &layer_buf, &source_buf, &sh_buf);

    try std.testing.expectEqualSlices(u8, &[_]u8{ 8, 7, 6, 5, 4, 3, 2, 1 }, pixel_buf[0..8]);
}

test "sprite renderer invalidates cached sprite entries on SAT writes" {
    var vdp = Vdp.init();
    vdp.regs[1] = 0x40;
    vdp.regs[5] = 0x01;

    seedAscendingSpritePattern(&vdp, 0);

    const sprite_base: u16 = 0x0200;
    writeTestSpriteEntry(&vdp, sprite_base, 0x0000, 128);

    var pixel_buf: [Vdp.framebuffer_width]u8 = [_]u8{0} ** Vdp.framebuffer_width;
    var layer_buf: [Vdp.framebuffer_width]u8 = [_]u8{LAYER_BACKDROP} ** Vdp.framebuffer_width;
    var source_buf: [Vdp.framebuffer_width]u8 = [_]u8{0} ** Vdp.framebuffer_width;
    var sh_buf: [Vdp.framebuffer_width]u8 = [_]u8{SH_NORMAL} ** Vdp.framebuffer_width;

    renderSpriteLineForTest(&vdp, &pixel_buf, &layer_buf, &source_buf, &sh_buf);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 }, pixel_buf[0..8]);

    clearSpriteBuffers(&pixel_buf, &layer_buf, &source_buf, &sh_buf);
    vdp.vramWriteWord(sprite_base + 6, 136);
    renderSpriteLineForTest(&vdp, &pixel_buf, &layer_buf, &source_buf, &sh_buf);

    try std.testing.expectEqualSlices(u8, &[_]u8{0} ** 8, pixel_buf[0..8]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 }, pixel_buf[8..16]);
}

test "off-screen sprite widths still trigger next-line sprite masking" {
    var vdp = Vdp.init();
    vdp.regs[1] = 0x40;
    vdp.regs[5] = 0x02;
    vdp.regs[12] = 0x01;

    seedAscendingSpritePattern(&vdp, 0);

    const sprite_base: u16 = 0x0400;
    for (0..10) |i| {
        const entry_base = sprite_base + @as(u16, @intCast(i * 8));
        const next_link: u8 = if (i == 9) 0 else @intCast(i + 1);
        writeTestSpriteEntryFull(&vdp, entry_base, 128, 0x0C, next_link, 0x0000, 96);
    }

    var pixel_buf: [Vdp.framebuffer_width]u8 = [_]u8{0} ** Vdp.framebuffer_width;
    var layer_buf: [Vdp.framebuffer_width]u8 = [_]u8{LAYER_BACKDROP} ** Vdp.framebuffer_width;
    var source_buf: [Vdp.framebuffer_width]u8 = [_]u8{0} ** Vdp.framebuffer_width;
    var sh_buf: [Vdp.framebuffer_width]u8 = [_]u8{SH_NORMAL} ** Vdp.framebuffer_width;

    renderSpriteLineForTest(&vdp, &pixel_buf, &layer_buf, &source_buf, &sh_buf);
    try std.testing.expect(vdp.sprite_dot_overflow);

    clearSpriteBuffers(&pixel_buf, &layer_buf, &source_buf, &sh_buf);
    writeTestSpriteEntryFull(&vdp, sprite_base, 128, 0x00, 1, 0x0000, 0);
    writeTestSpriteEntryFull(&vdp, sprite_base + 8, 128, 0x00, 0, 0x0000, 128);

    renderSpriteLineForTest(&vdp, &pixel_buf, &layer_buf, &source_buf, &sh_buf);

    try std.testing.expectEqualSlices(u8, &[_]u8{0} ** 8, pixel_buf[0..8]);
}

test "sprite renderer rebuilds cache when the SAT base changes" {
    var vdp = Vdp.init();
    vdp.regs[1] = 0x40;
    vdp.regs[5] = 0x01;

    seedAscendingSpritePattern(&vdp, 0);

    writeTestSpriteEntry(&vdp, 0x0200, 0x0000, 128);
    writeTestSpriteEntry(&vdp, 0x0400, 0x0000, 136);

    var pixel_buf: [Vdp.framebuffer_width]u8 = [_]u8{0} ** Vdp.framebuffer_width;
    var layer_buf: [Vdp.framebuffer_width]u8 = [_]u8{LAYER_BACKDROP} ** Vdp.framebuffer_width;
    var source_buf: [Vdp.framebuffer_width]u8 = [_]u8{0} ** Vdp.framebuffer_width;
    var sh_buf: [Vdp.framebuffer_width]u8 = [_]u8{SH_NORMAL} ** Vdp.framebuffer_width;

    renderSpriteLineForTest(&vdp, &pixel_buf, &layer_buf, &source_buf, &sh_buf);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 }, pixel_buf[0..8]);

    clearSpriteBuffers(&pixel_buf, &layer_buf, &source_buf, &sh_buf);
    vdp.regs[5] = 0x02;
    renderSpriteLineForTest(&vdp, &pixel_buf, &layer_buf, &source_buf, &sh_buf);

    try std.testing.expectEqualSlices(u8, &[_]u8{0} ** 8, pixel_buf[0..8]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 }, pixel_buf[8..16]);
}

test "sprite collision wraps in the 9-bit internal coordinate space" {
    var vdp = Vdp.init();
    vdp.regs[1] = 0x40;
    vdp.regs[5] = 0x02;
    vdp.regs[12] = 0x01; // H40

    seedAscendingSpritePattern(&vdp, 0);
    seedAscendingSpritePattern(&vdp, 1);

    const sprite_base: u16 = 0x0400;
    // Sprite 0 at x_pos_raw = 508 (near right edge of 512-pixel space).
    // An 8-pixel sprite spans raw positions 508-515.  Positions 512-515
    // wrap to 0-3 in the 9-bit internal coordinate space.
    writeTestSpriteEntryFull(&vdp, sprite_base, 128, 0x00, 1, 0x0000, 508);
    // Sprite 1 at x_pos_raw = 1 (overlaps with wrapped pixels from sprite 0
    // at raw positions 1-3).  Use x_pos_raw > 0 to avoid triggering the
    // x=0 sprite masking behavior.
    writeTestSpriteEntryFull(&vdp, sprite_base + 8, 128, 0x00, 0, 0x0001, 1);

    var pixel_buf: [Vdp.framebuffer_width]u8 = [_]u8{0} ** Vdp.framebuffer_width;
    var layer_buf: [Vdp.framebuffer_width]u8 = [_]u8{LAYER_BACKDROP} ** Vdp.framebuffer_width;
    var source_buf: [Vdp.framebuffer_width]u8 = [_]u8{0} ** Vdp.framebuffer_width;
    var sh_buf: [Vdp.framebuffer_width]u8 = [_]u8{SH_NORMAL} ** Vdp.framebuffer_width;

    renderSpriteLineForTest(&vdp, &pixel_buf, &layer_buf, &source_buf, &sh_buf);

    // Sprite 0's wrapped pixels at raw positions 0-3 overlap with
    // sprite 1's pixels at raw positions 1-8.  The collision flag
    // should be set for the overlapping positions.
    try std.testing.expect(vdp.sprite_collision);
}

test "palette mode off masks mode 5 CRAM channel bits" {
    var masked = Vdp.init();
    masked.regs[0] = 0x00;
    masked.cram[0] = 0x0E;
    masked.cram[1] = 0xEE;

    var unmasked = masked;
    unmasked.regs[0] = 0x04;

    var reference = Vdp.init();
    reference.regs[0] = 0x04;
    reference.cram[0] = 0x02;
    reference.cram[1] = 0x22;

    try std.testing.expect(masked.getPaletteColor(0) != unmasked.getPaletteColor(0));
    try std.testing.expectEqual(reference.getPaletteColor(0), masked.getPaletteColor(0));
}

test "cram dot event sort orders pixel positions without underflow" {
    var events = [_]Vdp.CramDotEvent{
        .{ .pixel_x = 120, .cram_addr = 0, .old_hi = 0, .old_lo = 0, .written_word = 0 },
        .{ .pixel_x = 12, .cram_addr = 0, .old_hi = 0, .old_lo = 0, .written_word = 0 },
        .{ .pixel_x = 12, .cram_addr = 0, .old_hi = 0, .old_lo = 0, .written_word = 0 },
        .{ .pixel_x = 0, .cram_addr = 0, .old_hi = 0, .old_lo = 0, .written_word = 0 },
    };

    sortCramDotEvents(events[0..]);

    try std.testing.expectEqual(@as(u16, 0), events[0].pixel_x);
    try std.testing.expectEqual(@as(u16, 12), events[1].pixel_x);
    try std.testing.expectEqual(@as(u16, 12), events[2].pixel_x);
    try std.testing.expectEqual(@as(u16, 120), events[3].pixel_x);
}

test "render scanline handles more than 255 register events" {
    var vdp = Vdp.init();
    vdp.regs[0] = 0x04; // palette mode enabled
    vdp.regs[1] = 0x44; // display enable
    vdp.regs[12] = 0x01; // H40
    vdp.regs[7] = 0x00; // backdrop color 0
    vdp.cram[0] = 0x00;
    vdp.cram[1] = 0x0E; // red backdrop

    for (0..256) |i| {
        vdp.reg_change_events[i] = .{
            .pixel_x = 0,
            .reg = 7,
            .old_value = 0x00,
            .new_value = 0x00,
        };
    }
    vdp.reg_change_event_count = 256;

    vdp.renderScanline(0);

    try std.testing.expectEqual(@as(u32, 0xFFFF0000), vdp.framebuffer[0]);
    try std.testing.expectEqual(@as(u16, 0), vdp.reg_change_event_count);
}
