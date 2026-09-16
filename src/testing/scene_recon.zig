//! Frame scene reconstruction: rebuild a picture from a `FrameScene` alone,
//! mirroring the rasterizer's compositing rules. A high pixel-match ratio
//! against the real framebuffer proves the scene carries everything needed
//! to draw the frame, which is the correctness contract for 3D frontends.
//!
//! Shared by the `dump-scene` developer tool and the regression suite.

const std = @import("std");
const Scene = @import("../scene.zig");

/// Dispatch on the system that produced the scene.
pub fn reconstruct(s: *const Scene.FrameScene, r: *Reconstruction) void {
    if (s.system == @intFromEnum(Scene.SystemKind.genesis)) {
        reconstructGenesis(s, r);
    } else {
        reconstructSms(s, r);
    }
}

/// Compare a reconstruction against the machine's framebuffer over the
/// visible viewport. Returns matched and total pixel counts (RGB only; the
/// alpha channel is presentation).
pub fn compareToFramebuffer(
    s: *const Scene.FrameScene,
    r: *const Reconstruction,
    framebuffer: []const u32,
    stride: usize,
) struct { matched: usize, total: usize } {
    const vw: usize = s.viewport_width;
    const vh: usize = s.viewport_height;
    var matched: usize = 0;
    var total: usize = 0;
    if (framebuffer.len < vw * vh) return .{ .matched = 0, .total = 0 };
    for (0..vh) |y| {
        for (0..vw) |x| {
            const from_scene = r.pixels[(s.viewport_y + y) * r.width + (s.viewport_x + x)];
            const from_raster = framebuffer[y * stride + x];
            total += 1;
            if (from_scene & 0xFFFFFF == from_raster & 0xFFFFFF) matched += 1;
        }
    }
    return .{ .matched = matched, .total = total };
}



pub const Reconstruction = struct {
    pixels: []u32,
    priority: []bool,
    sprite_drawn: []bool,
    width: usize,
    height: usize,

    pub fn init(allocator: std.mem.Allocator, width: usize, height: usize) !Reconstruction {
        return .{
            .pixels = try allocator.alloc(u32, width * height),
            .priority = try allocator.alloc(bool, width * height),
            .sprite_drawn = try allocator.alloc(bool, width * height),
            .width = width,
            .height = height,
        };
    }

    pub fn deinit(self: *Reconstruction, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
        allocator.free(self.priority);
        allocator.free(self.sprite_drawn);
    }
};

/// Rebuild the frame from the scene description alone, mirroring the order
/// the VDP composites in: backdrop, background, sprites, left column blank.
pub fn reconstructSms(s: *const Scene.FrameScene, r: *Reconstruction) void {
    @memset(r.pixels, s.backdrop);
    @memset(r.priority, false);
    @memset(r.sprite_drawn, false);

    if (!s.contentValid()) return;
    if (s.flags & Scene.scene_flag_display_enabled == 0) return;

    const rows: usize = s.rows;
    // The 224 and 240 line modes wrap the tilemap at 256 pixels, not 224.
    const vertical_wrap: usize = if (rows > 28) 256 else 224;
    const locked_lines: usize = @as(usize, s.hud_locked_rows) * 8;
    const locked_col_start: usize = if (s.hud_locked_columns > 0)
        Scene.max_columns - s.hud_locked_columns
    else
        Scene.max_columns;

    for (0..r.height) |y| {
        const h_locked = y < locked_lines;
        // Per-line scroll: a mid-frame rewrite of the scroll register splits
        // the screen into bands moving at different rates.
        const hscroll: usize = if (h_locked) 0 else s.lineScrollX(y);
        const coarse = (hscroll >> 3) & 0x1F;
        const fine = hscroll & 0x7;

        for (0..r.width) |x| {
            const col = x / 8;
            // Fine scrolling leaves the leftmost pixels on the backdrop
            // rather than wrapping them in from the right edge.
            if (!h_locked and fine != 0 and x < fine) continue;

            const scrolled_x = if (h_locked) x else x - fine;
            const source_col = if (h_locked)
                col
            else
                (scrolled_x / 8 + Scene.max_columns - coarse) % Scene.max_columns;

            const v_locked = col >= locked_col_start;
            const effective_y = if (v_locked) y else (y + s.scroll_y) % vertical_wrap;
            const row = effective_y / 8;
            if (row >= rows) continue;

            const cell = s.cell(source_col, row);
            const fine_y = effective_y % 8;
            const ty = if (cell.flags & Scene.cell_flag_v_flip != 0) 7 - fine_y else fine_y;
            const fine_x = scrolled_x % 8;
            const tx = if (cell.flags & Scene.cell_flag_h_flip != 0) 7 - fine_x else fine_x;

            const color = s.tilePixels(cell.tile_index)[ty * 8 + tx];
            if (color == 0) continue;

            const at = y * r.width + x;
            r.pixels[at] = s.palette[cell.palette + color];
            r.priority[at] = cell.flags & Scene.cell_flag_priority != 0;
        }
    }

    // Sprites composite in table order, so the lowest slot covering a pixel
    // wins even when a higher slot is also opaque there.
    for (0..s.sprite_count) |i| {
        const sp = s.sprites[i];
        const doubled = sp.flags & Scene.sprite_flag_doubled != 0;

        for (0..sp.height) |ry| {
            const sy = @as(i32, sp.y) + @as(i32, @intCast(ry));
            if (sy < 0 or sy >= r.height) continue;

            const source_row = if (doubled) ry / 2 else ry;
            // Tall sprites continue into the next pattern after eight rows.
            const tile = sp.tile_index + @as(u16, if (source_row >= 8) 1 else 0);
            if (tile >= Scene.max_tiles) continue;
            const pattern = s.tilePixels(tile);
            const in_row = source_row % 8;

            for (0..sp.width) |rx| {
                const sx = @as(i32, sp.x) + @as(i32, @intCast(rx));
                if (sx < 0 or sx >= r.width) continue;

                const source_col = if (doubled) rx / 2 else rx;
                const color = pattern[in_row * 8 + source_col];
                if (color == 0) continue;

                const at = @as(usize, @intCast(sy)) * r.width + @as(usize, @intCast(sx));
                if (r.sprite_drawn[at]) continue;
                r.sprite_drawn[at] = true;
                // Background cells flagged as high priority stay in front.
                if (r.priority[at]) continue;
                r.pixels[at] = s.palette[sp.palette + color];
            }
        }
    }

    if (s.flags & Scene.scene_flag_left_column_blanked != 0) {
        for (0..r.height) |y| {
            for (0..@min(8, r.width)) |x| r.pixels[y * r.width + x] = s.backdrop;
        }
    }
}


/// Shadow/highlight state per pixel, matching the rasterizer's operators.
const sh_shadow: u8 = 0;
const sh_normal: u8 = 1;
const sh_highlight: u8 = 2;

fn shadowColor(color: u32) u32 {
    const r = (color >> 16) & 0xFF;
    const g = (color >> 8) & 0xFF;
    const b = color & 0xFF;
    return 0xFF000000 | ((r >> 1) << 16) | ((g >> 1) << 8) | (b >> 1);
}

fn highlightColor(color: u32) u32 {
    const r: u32 = @min(((color >> 16) & 0xFF) / 2 + 0x80, 0xFF);
    const g: u32 = @min(((color >> 8) & 0xFF) / 2 + 0x80, 0xFF);
    const b: u32 = @min((color & 0xFF) / 2 + 0x80, 0xFF);
    return 0xFF000000 | (r << 16) | (g << 8) | b;
}

/// Rebuild a Genesis frame from the scene description, mirroring the
/// compositor in src/video/render.zig without mid-line effects: register
/// changes between pixels and CRAM dot writes are not represented in an
/// end-of-frame scene, so frames using them show up in the match
/// percentage. Shadow/highlight is implemented; interlace mode 2 is not.
pub fn reconstructGenesis(s: *const Scene.FrameScene, r: *Reconstruction) void {
    @memset(r.pixels, s.backdrop);

    if (!s.contentValid()) return;
    if (s.flags & Scene.scene_flag_display_enabled == 0) return;

    const h40 = s.gen_flags & Scene.gen_flag_h40 != 0;
    const col_vscroll = s.gen_flags & Scene.gen_flag_column_vscroll != 0;
    const plane_w_px: i32 = @as(i32, s.gen_plane_width) * 8;
    const plane_h_px: i32 = @as(i32, s.gen_plane_height) * 8;

    const sh_mode = s.gen_flags & Scene.gen_flag_shadow_highlight != 0;

    // Layer indices, matching render.zig: backdrop 0, B low 1, A low 2,
    // sprite low 3, B high 4, A high 5, sprite high 6. Planes overwrite at
    // >=, sprites only at >.
    var pixel_line: [320]u8 = undefined;
    var layer_line: [320]u8 = undefined;
    var sh_line: [320]u8 = undefined;

    // The rasterizer carries the sprite pixel-budget mask across lines.
    var dot_overflow = false;

    const max_line_sprites: u8 = if (h40) 20 else 16;
    const max_line_pixels: u16 = if (h40) 320 else 256;

    for (0..r.height) |y| {
        @memset(pixel_line[0..r.width], 0);
        @memset(layer_line[0..r.width], 0);
        @memset(sh_line[0..r.width], if (sh_mode) sh_shadow else sh_normal);

        // Plane B covers the whole line.
        drawGenPlane(s, &s.gen_plane_b, s.gen_b_line_hscroll[y], &s.gen_b_col_vscroll, col_vscroll, h40, plane_w_px, plane_h_px, y, 0, @intCast(r.width), 1, 4, false, &pixel_line, &layer_line, &sh_line, sh_mode);

        // Window layout: the window replaces plane A in its region.
        const window_down = s.gen_reg18 & 0x80 != 0;
        const v_boundary = @as(usize, s.gen_reg18 & 0x1F) * 8;
        var win_start: u16 = 0;
        var win_end: u16 = 0;
        var a_start: u16 = 0;
        var a_end: u16 = @intCast(r.width);
        if (window_down == (y >= v_boundary)) {
            win_end = @intCast(r.width);
            a_end = 0;
        } else {
            const split_cells = @as(u16, s.gen_reg17 & 0x1F);
            const window_right = s.gen_reg17 & 0x80 != 0;
            const screen_cells: u16 = if (h40) 20 else 16;
            if (split_cells == 0) {
                if (window_right) {
                    win_end = @intCast(r.width);
                    a_end = 0;
                }
            } else if (split_cells > screen_cells) {
                if (!window_right) {
                    win_end = @intCast(r.width);
                    a_end = 0;
                }
            } else {
                const split_x = @min(split_cells * 16, @as(u16, @intCast(r.width)));
                if (window_right) {
                    a_end = split_x;
                    win_start = split_x;
                    win_end = @intCast(r.width);
                } else {
                    win_end = split_x;
                    a_start = split_x;
                }
            }
        }

        if (a_start < a_end) {
            drawGenPlane(s, &s.gen_plane_a, s.gen_a_line_hscroll[y], &s.gen_a_col_vscroll, col_vscroll, h40, plane_w_px, plane_h_px, y, a_start, a_end, 2, 5, true, &pixel_line, &layer_line, &sh_line, sh_mode);
        }
        if (win_start < win_end) {
            drawGenWindow(s, y, win_start, win_end, &pixel_line, &layer_line, &sh_line, sh_mode);
        }

        dot_overflow = drawGenSprites(s, y, max_line_sprites, max_line_pixels, dot_overflow, @intCast(r.width), &pixel_line, &layer_line, &sh_line, sh_mode);

        for (0..r.width) |x| {
            const base = if (pixel_line[x] != 0) genColor(s, pixel_line[x]) else s.backdrop;
            // The backdrop also honors the shadow/highlight state: priority
            // bits and sprite operators lift or lower it like any pixel.
            r.pixels[y * r.width + x] = if (!sh_mode)
                (if (pixel_line[x] != 0) base else s.backdrop)
            else switch (sh_line[x]) {
                sh_shadow => shadowColor(base),
                sh_highlight => highlightColor(base),
                else => base,
            };
        }
    }
}

fn genColor(s: *const Scene.FrameScene, index: u8) u32 {
    return if (index < 32) s.palette[index] else s.gen_palette2[index - 32];
}

fn drawGenPlane(
    s: *const Scene.FrameScene,
    cells: *const [Scene.gen_plane_cells]Scene.Cell,
    hscroll: i16,
    col_vscroll: *const [Scene.gen_vscroll_columns]u16,
    col_mode: bool,
    h40: bool,
    plane_w_px: i32,
    plane_h_px: i32,
    y: usize,
    start_x: u16,
    end_x: u16,
    base_layer: u8,
    high_layer: u8,
    is_plane_a: bool,
    pixel_line: *[320]u8,
    layer_line: *[320]u8,
    sh_line: *[320]u8,
    sh_mode: bool,
) void {
    const hscroll_shift: u4 = @truncate(@as(u16, @bitCast(hscroll)));
    // Hardware quirk mirrored from the rasterizer: when the window occupies
    // the left of the line and fine scroll is active, plane A resumes
    // hscroll_shift pixels later.
    const render_start: u16 = if (is_plane_a and start_x != 0 and hscroll_shift != 0)
        @min(end_x, start_x + hscroll_shift)
    else
        start_x;

    var x: u16 = render_start;
    while (x < end_x) : (x += 1) {
        var vscroll: i32 = @intCast(col_vscroll[0]);
        if (col_mode) {
            if (hscroll_shift != 0 and x < hscroll_shift) {
                // The columns hidden by fine scroll read an undefined VSRAM
                // location: H40 ANDs the two plane values of column 19, H32
                // reads zero.
                vscroll = if (h40)
                    @intCast(s.gen_a_col_vscroll[19] & s.gen_b_col_vscroll[19])
                else
                    0;
            } else {
                const pair: usize = if (hscroll_shift != 0)
                    (@as(usize, x) - hscroll_shift) / 16
                else
                    x / 16;
                vscroll = @intCast(col_vscroll[@min(pair, Scene.gen_vscroll_columns - 1)]);
            }
        }

        const x_scrolled = @as(i32, @intCast(x)) - @as(i32, hscroll);
        const y_scrolled = @as(i32, @intCast(y)) + vscroll;
        const x_wrapped: u32 = @intCast(@mod(x_scrolled, plane_w_px));
        const y_wrapped: u32 = @intCast(@mod(y_scrolled, plane_h_px));
        const tile_col = x_wrapped >> 3;
        const tile_row = y_wrapped >> 3;

        const cell = cells[@min(tile_row * s.gen_plane_width + tile_col, Scene.gen_plane_cells - 1)];
        const fine_x: u8 = @intCast(x_wrapped & 7);
        const fine_y: u8 = @intCast(y_wrapped & 7);
        const px = if (cell.flags & Scene.cell_flag_h_flip != 0) 7 - fine_x else fine_x;
        const py = if (cell.flags & Scene.cell_flag_v_flip != 0) 7 - fine_y else fine_y;

        const high = cell.flags & Scene.cell_flag_priority != 0;
        // The priority bit lifts the pixel out of shadow even when this
        // tile's pixel is transparent: hardware keys shadow off the
        // name-table priority bits, not pixel opacity.
        if (sh_mode and high) sh_line[x] = sh_normal;

        const color = s.tilePixels(cell.tile_index)[@as(usize, py) * 8 + px];
        if (color == 0) continue;

        const new_layer = if (high) high_layer else base_layer;
        if (new_layer >= layer_line[x]) {
            pixel_line[x] = cell.palette + color;
            layer_line[x] = new_layer;
        }
    }
}

fn drawGenWindow(
    s: *const Scene.FrameScene,
    y: usize,
    start_x: u16,
    end_x: u16,
    pixel_line: *[320]u8,
    layer_line: *[320]u8,
    sh_line: *[320]u8,
    sh_mode: bool,
) void {
    const tile_row = y >> 3;
    const fine_y: u8 = @intCast(y & 7);
    var x: u16 = start_x;
    while (x < end_x) : (x += 1) {
        const tile_col = x >> 3;
        const cell = s.gen_window[@min(tile_row * s.gen_window_width + tile_col, Scene.gen_window_cells - 1)];
        const fine_x: u8 = @intCast(x & 7);
        const px = if (cell.flags & Scene.cell_flag_h_flip != 0) 7 - fine_x else fine_x;
        const py = if (cell.flags & Scene.cell_flag_v_flip != 0) 7 - fine_y else fine_y;
        const high = cell.flags & Scene.cell_flag_priority != 0;
        if (sh_mode and high) sh_line[x] = sh_normal;
        const color = s.tilePixels(cell.tile_index)[@as(usize, py) * 8 + px];
        if (color == 0) continue;
        const new_layer: u8 = if (high) 5 else 2;
        if (new_layer >= layer_line[x]) {
            pixel_line[x] = cell.palette + color;
            layer_line[x] = new_layer;
        }
    }
}

/// Sprites for one line, in link order, with the rasterizer's per-line
/// limits: count, pixel budget, and the x=0 masking rule. Returns whether
/// the pixel budget overflowed (which masks sprites on the next line).
fn drawGenSprites(
    s: *const Scene.FrameScene,
    y: usize,
    max_line_sprites: u8,
    max_line_pixels: u16,
    prev_dot_overflow: bool,
    screen_w: i32,
    pixel_line: *[320]u8,
    layer_line: *[320]u8,
    sh_line: *[320]u8,
    sh_mode: bool,
) bool {
    var sprites_on_line: u8 = 0;
    var pixel_budget: u16 = 0;
    var masked = false;
    var had_nonzero_x = false;
    var next_line_mask = false;

    for (0..s.gen_sprite_count) |i| {
        const sp = s.gen_sprites[i];
        const v_px = @as(i32, sp.v_size) * 8;
        const y_in = @as(i32, @intCast(y)) - sp.y;
        if (y_in < 0 or y_in >= v_px) continue;

        sprites_on_line += 1;
        if (sprites_on_line > max_line_sprites) break;

        const width_px = @as(u16, sp.h_size) * 8;
        const new_budget = pixel_budget + width_px;
        var draw_width = width_px;
        if (new_budget > max_line_pixels) draw_width -= new_budget - max_line_pixels;
        pixel_budget = new_budget;

        // Sprite masking: an on-line sprite at raw x = 0 hides the rest of
        // the line's sprites, once any nonzero-x sprite has been seen (or
        // the previous line overflowed the pixel budget).
        if (sp.x == -128) {
            if (had_nonzero_x or prev_dot_overflow) masked = true;
        } else {
            had_nonzero_x = true;
        }

        if (!masked) {
            const y_flipped = sp.flags & Scene.sprite_flag_v_flip != 0;
            const y_sprite: u32 = @intCast(if (y_flipped) v_px - 1 - y_in else y_in);
            const tile_y: u16 = @intCast(y_sprite >> 3);
            const fine_y: u8 = @intCast(y_sprite & 7);
            const x_flipped = sp.flags & Scene.sprite_flag_h_flip != 0;
            const high = sp.flags & Scene.sprite_flag_priority != 0;
            const new_layer: u8 = if (high) 6 else 3;

            var px_idx: u16 = 0;
            while (px_idx < draw_width) : (px_idx += 1) {
                const screen_x = @as(i32, sp.x) + px_idx;
                if (screen_x < 0 or screen_x >= screen_w) continue;

                const sprite_px: u16 = if (x_flipped) width_px - 1 - px_idx else px_idx;
                const tile_x = sprite_px >> 3;
                const fine_x: u8 = @intCast(sprite_px & 7);
                // Sprite patterns advance column-major.
                const tile = sp.tile_base +% tile_x *% @as(u16, sp.v_size) +% tile_y;
                const color = s.tilePixels(tile & (Scene.max_tiles - 1))[@as(usize, fine_y) * 8 + fine_x];
                if (color == 0) continue;

                const sx: usize = @intCast(screen_x);
                if (sh_mode and sp.palette == 48 and color == 14) {
                    // Highlight operator (sprite color 0x3E): the pixel is
                    // not drawn; the underlying pixel is raised one step.
                    sh_line[sx] = if (sh_line[sx] == sh_shadow) sh_normal else sh_highlight;
                    continue;
                }
                if (sh_mode and sp.palette == 48 and color == 15) {
                    // Shadow operator (sprite color 0x3F): forced shadow.
                    sh_line[sx] = sh_shadow;
                    continue;
                }
                if (new_layer > layer_line[sx]) {
                    pixel_line[sx] = sp.palette + color;
                    layer_line[sx] = new_layer;
                    // Priority sprites and sprite color 14 of any palette
                    // always display at normal intensity.
                    if (sh_mode and (high or color == 14)) sh_line[sx] = sh_normal;
                }
            }
        }

        if (pixel_budget >= max_line_pixels) {
            next_line_mask = true;
            break;
        }
    }

    return next_line_mask;
}


// -- Tests --

const testing = std.testing;

/// A minimal Genesis scene: shadow/highlight on, one plane B cell of solid
/// color 1 (low priority), palette entry 1 = full red.
fn shTestScene() !*Scene.FrameScene {
    const s = try testing.allocator.create(Scene.FrameScene);
    s.* = .{};
    s.magic = Scene.magic;
    s.version = Scene.layout_version;
    s.system = @intFromEnum(Scene.SystemKind.genesis);
    s.picture_width = 320;
    s.picture_height = 224;
    s.viewport_width = 320;
    s.viewport_height = 224;
    s.flags = Scene.scene_flag_content_valid | Scene.scene_flag_display_enabled;
    s.gen_flags = Scene.gen_flag_shadow_highlight | Scene.gen_flag_h40;
    s.gen_plane_width = 64;
    s.gen_plane_height = 32;
    s.gen_window_width = 64;
    // reg18 = 0: the window is empty and plane A covers the screen.
    s.backdrop = 0xFF000000;
    s.palette[1] = 0xFF800040;
    // Tile 1: solid color 1. Tile 2: solid color 14. Tile 3: solid color 15.
    for (0..64) |i| {
        s.tile_atlas[64 + i] = 1;
        s.tile_atlas[128 + i] = 14;
        s.tile_atlas[192 + i] = 15;
    }
    // Plane B: tile 1 everywhere, low priority.
    for (0..64 * 32) |i| s.gen_plane_b[i] = .{ .tile_index = 1 };
    return s;
}

test "shadow mode halves unlifted pixels and the backdrop" {
    const s = try shTestScene();
    defer testing.allocator.destroy(s);
    var r = try Reconstruction.init(testing.allocator, 320, 224);
    defer r.deinit(testing.allocator);
    reconstruct(s, &r);

    // Low-priority pixel with nothing lifting it: half intensity.
    try testing.expectEqual(@as(u32, 0xFF400020), r.pixels[0] & 0xFFFFFFFF);
}

test "plane priority lifts shadow even for transparent pixels" {
    const s = try shTestScene();
    defer testing.allocator.destroy(s);
    // Plane A cell (0, 0): transparent tile 0, priority set. The priority
    // bit keys the lift; pixel opacity does not matter.
    s.gen_plane_a[0] = .{ .tile_index = 0, .flags = Scene.cell_flag_priority };

    var r = try Reconstruction.init(testing.allocator, 320, 224);
    defer r.deinit(testing.allocator);
    reconstruct(s, &r);

    try testing.expectEqual(@as(u32, 0xFF800040), r.pixels[0]); // lifted
    try testing.expectEqual(@as(u32, 0xFF400020), r.pixels[8]); // next tile: shadowed
}

test "sprite operators highlight and shadow without drawing" {
    const s = try shTestScene();
    defer testing.allocator.destroy(s);
    // Sprite 0: palette 3 color 14 = highlight operator at (0, 0).
    // Sprite 1: palette 3 color 15 = shadow operator at (16, 0).
    s.gen_sprite_count = 2;
    s.gen_sprites[0] = .{ .x = 0, .y = 0, .tile_base = 2, .h_size = 1, .v_size = 1, .palette = 48 };
    s.gen_sprites[1] = .{ .x = 16, .y = 0, .tile_base = 3, .h_size = 1, .v_size = 1, .palette = 48 };

    var r = try Reconstruction.init(testing.allocator, 320, 224);
    defer r.deinit(testing.allocator);
    reconstruct(s, &r);

    // Highlight operator on a shadowed pixel raises it to normal.
    try testing.expectEqual(@as(u32, 0xFF800040), r.pixels[0]);
    // Shadow operator on an already shadowed pixel keeps it shadowed, and
    // the operator itself is never drawn.
    try testing.expectEqual(@as(u32, 0xFF400020), r.pixels[16]);
    // Untouched pixel stays shadowed.
    try testing.expectEqual(@as(u32, 0xFF400020), r.pixels[32]);
}

test "highlight operator over a lifted pixel highlights it" {
    const s = try shTestScene();
    defer testing.allocator.destroy(s);
    s.gen_plane_a[0] = .{ .tile_index = 0, .flags = Scene.cell_flag_priority };
    s.gen_sprite_count = 1;
    s.gen_sprites[0] = .{ .x = 0, .y = 0, .tile_base = 2, .h_size = 1, .v_size = 1, .palette = 48 };

    var r = try Reconstruction.init(testing.allocator, 320, 224);
    defer r.deinit(testing.allocator);
    reconstruct(s, &r);

    // palette[1] = 0xFF800040 -> highlight = c/2 + 0x80 per channel.
    try testing.expectEqual(@as(u32, 0xFFC080A0), r.pixels[0]);
}

test "priority sprites draw at normal intensity in shadow mode" {
    const s = try shTestScene();
    defer testing.allocator.destroy(s);
    s.gen_sprite_count = 1;
    s.gen_sprites[0] = .{
        .x = 0,
        .y = 0,
        .tile_base = 1,
        .h_size = 1,
        .v_size = 1,
        .palette = 0,
        .flags = Scene.sprite_flag_priority,
    };

    var r = try Reconstruction.init(testing.allocator, 320, 224);
    defer r.deinit(testing.allocator);
    reconstruct(s, &r);

    try testing.expectEqual(@as(u32, 0xFF800040), r.pixels[0]);
}
