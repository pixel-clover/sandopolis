//! Frame scene extraction for the Genesis VDP.
//!
//! Fills the Genesis section of `scene.FrameScene`: both scroll planes, the
//! window plane, the full 2048-pattern atlas, all four palette banks, and
//! the sprite table in link order.
//!
//! Like the Master System extractor, this is a read-only end-of-frame
//! observation, so effects the rasterizer resolves mid-line cannot be
//! represented: CRAM dot writes, register changes between pixels, and
//! scroll-table rewrites during the frame collapse to their end-of-frame
//! values. Interlace mode 2 and shadow/highlight are reported as flags but
//! the tile atlas is always decoded as 8x8.
//!
//! The extractor must not touch the VDP's sprite cache (building it is a
//! mutation); the sprite attribute table is parsed directly from VRAM.

const std = @import("std");
const scene = @import("../scene.zig");
const Vdp = @import("vdp.zig").Vdp;
const render = @import("render.zig");

/// Extract the current frame into `out`. Returns true; every Genesis mode is
/// describable to the same end-of-frame approximation.
pub fn extract(vdp: *const Vdp, out: *scene.FrameScene) bool {
    out.magic = scene.magic;
    out.version = scene.layout_version;
    out.system = @intFromEnum(scene.SystemKind.genesis);
    out.mode = 0;
    out.columns = 0; // the SMS cell grid is unused; planes live in the Genesis section
    out.rows = 0;
    for (0..scene.max_cells) |i| out.cells[i] = .{};
    out.scroll_x = 0;
    out.scroll_y = 0;
    out.hud_locked_rows = 0;
    out.hud_locked_columns = 0;
    out.sprite_count = 0;
    for (0..scene.max_sprites) |i| out.sprites[i] = .{};
    for (0..scene.max_lines) |i| out.line_scroll_x[i] = 0;

    const width = vdp.screenWidth();
    // V30 (240-line) display is a PAL-only register setting.
    const height: u16 = if (vdp.pal_mode and (vdp.regs[1] & 0x08) != 0) 240 else 224;
    out.picture_width = width;
    out.picture_height = height;
    out.viewport_x = 0;
    out.viewport_y = 0;
    out.viewport_width = width;
    out.viewport_height = height;

    var flags: u32 = scene.scene_flag_content_valid;
    if (vdp.isDisplayEnabled()) flags |= scene.scene_flag_display_enabled;
    // Register 0 bit 5 (left-column blank) is not implemented by this
    // emulator's Genesis rasterizer, so the scene does not claim it either.
    out.flags = flags;

    var gen_flags: u32 = 0;
    if (vdp.isShadowHighlightEnabled()) gen_flags |= scene.gen_flag_shadow_highlight;
    if (vdp.isInterlaceMode2()) gen_flags |= scene.gen_flag_interlace2;
    if (vdp.isH40()) gen_flags |= scene.gen_flag_h40;
    if ((vdp.regs[11] & 0x04) != 0) gen_flags |= scene.gen_flag_column_vscroll;
    out.gen_flags = gen_flags;

    // Palette: all 64 CRAM colors through the same conversion the
    // rasterizer uses (including the palette-mode masking).
    out.backdrop = render.getPaletteColor(vdp, vdp.regs[7] & 0x3F);
    for (0..scene.max_palette) |i| {
        out.palette[i] = render.getPaletteColor(vdp, @intCast(i));
        out.gen_palette2[i] = render.getPaletteColor(vdp, @intCast(32 + i));
    }
    // Entry 0 of each bank is transparent for tiles; the backdrop field
    // carries the visible background color.

    extractPlanes(vdp, out);
    extractScroll(vdp, out, height);
    extractSpritesGen(vdp, out);
    extractTilesGen(vdp, out);
    return true;
}

fn cellFromEntry(entry: u16) scene.Cell {
    var cell_flags: u8 = 0;
    if (entry & 0x0800 != 0) cell_flags |= scene.cell_flag_h_flip;
    if (entry & 0x1000 != 0) cell_flags |= scene.cell_flag_v_flip;
    if (entry & 0x8000 != 0) cell_flags |= scene.cell_flag_priority;
    return .{
        .tile_index = entry & 0x07FF,
        .palette = @intCast(((entry >> 13) & 0x3) * 16),
        .flags = cell_flags,
    };
}

fn extractPlanes(vdp: *const Vdp, out: *scene.FrameScene) void {
    const plane_a_base = @as(u32, vdp.regs[2] & 0x38) << 10;
    const plane_b_base = @as(u32, vdp.regs[4] & 0x07) << 13;
    const plane_width: u16 = switch (vdp.regs[16] & 0x3) {
        0 => 32,
        1 => 64,
        3 => 128,
        else => 32,
    };
    var plane_height: u16 = switch ((vdp.regs[16] >> 4) & 0x3) {
        0 => 32,
        1 => 64,
        3 => 128,
        else => 32,
    };
    // Name tables hold at most 8KB (4096 entries); hardware prohibits size
    // combinations past that. Clamp the reported height so the stored
    // dimensions always describe the stored cells, otherwise a ROM
    // programming an illegal size would send consumers out of bounds.
    while (@as(usize, plane_width) * plane_height > scene.gen_plane_cells) plane_height /= 2;
    out.gen_plane_width = plane_width;
    out.gen_plane_height = plane_height;

    const entries = @min(scene.gen_plane_cells, @as(usize, plane_width) * plane_height);
    for (0..entries) |i| {
        const a_addr: u16 = @intCast((plane_a_base + i * 2) & 0xFFFF);
        const b_addr: u16 = @intCast((plane_b_base + i * 2) & 0xFFFF);
        out.gen_plane_a[i] = cellFromEntry((@as(u16, vdp.vram[a_addr]) << 8) | vdp.vram[a_addr +% 1]);
        out.gen_plane_b[i] = cellFromEntry((@as(u16, vdp.vram[b_addr]) << 8) | vdp.vram[b_addr +% 1]);
    }
    for (entries..scene.gen_plane_cells) |i| {
        out.gen_plane_a[i] = .{};
        out.gen_plane_b[i] = .{};
    }

    // Window plane: fixed in screen space, no scroll.
    const win_base: u32 = if (vdp.isH40())
        (@as(u32, vdp.regs[3]) << 10) & 0xF000
    else
        (@as(u32, vdp.regs[3]) << 10) & 0xF800;
    const win_width: u16 = if (vdp.isH40()) 64 else 32;
    out.gen_window_width = win_width;
    out.gen_reg17 = vdp.regs[17];
    out.gen_reg18 = vdp.regs[18];

    const win_entries = @min(scene.gen_window_cells, @as(usize, win_width) * 32);
    for (0..win_entries) |i| {
        const addr: u16 = @intCast((win_base + i * 2) & 0xFFFF);
        out.gen_window[i] = cellFromEntry((@as(u16, vdp.vram[addr]) << 8) | vdp.vram[addr +% 1]);
    }
    for (win_entries..scene.gen_window_cells) |i| out.gen_window[i] = .{};
}

fn extractScroll(vdp: *const Vdp, out: *scene.FrameScene, height: u16) void {
    const hscroll_base = (@as(u16, vdp.regs[13]) & 0x3F) << 10;
    const lines = @min(scene.max_lines, @as(usize, height));
    for (0..lines) |line| {
        out.gen_a_line_hscroll[line] = @intCast(render.readHScroll(vdp, hscroll_base, @intCast(line), true));
        out.gen_b_line_hscroll[line] = @intCast(render.readHScroll(vdp, hscroll_base, @intCast(line), false));
    }
    for (lines..scene.max_lines) |line| {
        out.gen_a_line_hscroll[line] = 0;
        out.gen_b_line_hscroll[line] = 0;
    }

    for (0..scene.gen_vscroll_columns) |pair| {
        const offset = pair * 4;
        out.gen_a_col_vscroll[pair] = ((@as(u16, vdp.vsram[offset]) << 8) | vdp.vsram[offset + 1]) & 0x07FF;
        out.gen_b_col_vscroll[pair] = ((@as(u16, vdp.vsram[offset + 2]) << 8) | vdp.vsram[offset + 3]) & 0x07FF;
    }
}

/// Parse the sprite attribute table in link order, the order that decides
/// overlap between sprites. Per-line count and pixel limits are rasterizer
/// artifacts and deliberately not applied.
fn extractSpritesGen(vdp: *const Vdp, out: *scene.FrameScene) void {
    const sprite_base = vdp.spriteAttributeTableBase();
    const max_total = vdp.maxSpritesTotal();

    var count: u8 = 0;
    var sprite_index: u8 = 0;
    var visited: u8 = 0;
    while (visited < max_total and count < scene.gen_max_sprites) : (visited += 1) {
        const entry_addr = @as(usize, sprite_base) + @as(usize, sprite_index) * 8;
        const y_word = (@as(u16, vdp.vram[entry_addr]) << 8) | vdp.vram[entry_addr + 1];
        const size = vdp.vram[entry_addr + 2];
        const link = vdp.vram[entry_addr + 3] & 0x7F;
        const attr = (@as(u16, vdp.vram[entry_addr + 4]) << 8) | vdp.vram[entry_addr + 5];
        const x_word = (@as(u16, vdp.vram[entry_addr + 6]) << 8) | vdp.vram[entry_addr + 7];

        var sprite_flags: u8 = 0;
        if (attr & 0x0800 != 0) sprite_flags |= scene.sprite_flag_h_flip;
        if (attr & 0x1000 != 0) sprite_flags |= scene.sprite_flag_v_flip;
        if (attr & 0x8000 != 0) sprite_flags |= scene.sprite_flag_priority;

        out.gen_sprites[count] = .{
            // The hardware offsets sprite coordinates by 128; in interlace
            // mode 2 the Y coordinate is in double-resolution lines.
            .x = @as(i16, @intCast(x_word & 0x01FF)) - 128,
            .y = @as(i16, @intCast(y_word & 0x03FF)) - 128,
            .tile_base = attr & 0x07FF,
            .h_size = @intCast(((size >> 2) & 0x3) + 1),
            .v_size = @intCast((size & 0x3) + 1),
            .palette = @intCast(((attr >> 13) & 0x3) * 16),
            .flags = sprite_flags,
            .slot = sprite_index,
        };
        count += 1;

        if (link == 0 or link >= max_total) break;
        sprite_index = link;
    }

    out.gen_sprite_count = count;
    for (count..scene.gen_max_sprites) |i| out.gen_sprites[i] = .{};
}

fn extractTilesGen(vdp: *const Vdp, out: *scene.FrameScene) void {
    @memset(&out.tile_dirty, 0);

    var pixels: [scene.pixels_per_tile]u8 = undefined;
    for (0..scene.max_tiles) |tile| {
        const base = tile * 32;
        for (0..8) |row| {
            for (0..4) |byte| {
                const b = vdp.vram[(base + row * 4 + byte) & 0xFFFF];
                pixels[row * 8 + byte * 2] = (b >> 4) & 0xF;
                pixels[row * 8 + byte * 2 + 1] = b & 0xF;
            }
        }
        const dest = out.tile_atlas[tile * scene.pixels_per_tile ..][0..scene.pixels_per_tile];
        if (!std.mem.eql(u8, dest, &pixels)) {
            out.markTileDirty(tile);
            @memcpy(dest, &pixels);
        }
    }

    out.tile_count = @intCast(scene.max_tiles);
}

// -- Tests --

const testing = std.testing;

fn testVdp() !*Vdp {
    const vdp = try testing.allocator.create(Vdp);
    vdp.* = Vdp.init();
    vdp.regs[1] |= 0x40; // display on
    vdp.regs[2] = 0x30; // plane A at 0xC000
    vdp.regs[3] = 0x3C; // window at 0xF000
    vdp.regs[4] = 0x07; // plane B at 0xE000
    vdp.regs[5] = 0x6C; // sprite table at 0xD800
    vdp.regs[16] = 0x01; // 64x32 planes
    return vdp;
}

fn allocScene() !*scene.FrameScene {
    const s = try testing.allocator.create(scene.FrameScene);
    s.* = .{};
    return s;
}

test "genesis extract fills the header and palette" {
    const vdp = try testVdp();
    defer testing.allocator.destroy(vdp);
    vdp.regs[12] = 0x81; // H40
    vdp.regs[7] = 0x05; // backdrop: palette 0 entry 5
    // CRAM entry 5: full-intensity red (Mode 5 word 0x000E).
    vdp.regs[0] |= 0x04; // full palette mode
    vdp.cram[10] = 0x00;
    vdp.cram[11] = 0x0E;

    const s = try allocScene();
    defer testing.allocator.destroy(s);
    try testing.expect(extract(vdp, s));

    try testing.expectEqual(@intFromEnum(scene.SystemKind.genesis), s.system);
    try testing.expectEqual(@as(u16, 320), s.picture_width);
    try testing.expectEqual(@as(u16, 224), s.picture_height);
    try testing.expect(s.contentValid());
    try testing.expect(s.gen_flags & scene.gen_flag_h40 != 0);
    try testing.expectEqual(@as(u16, 64), s.gen_plane_width);
    try testing.expectEqual(@as(u16, 32), s.gen_plane_height);
    try testing.expectEqual(render.getPaletteColor(vdp, 5), s.backdrop);
    try testing.expectEqual(render.getPaletteColor(vdp, 5), s.palette[5]);
    try testing.expectEqual(render.getPaletteColor(vdp, 33), s.gen_palette2[1]);
}

test "genesis extract decodes plane entries" {
    const vdp = try testVdp();
    defer testing.allocator.destroy(vdp);
    // Plane A entry (1, 2): priority, palette 3, vflip, tile 0x2A5.
    const entry: u16 = 0x8000 | (3 << 13) | 0x1000 | 0x2A5;
    const addr = 0xC000 + (2 * 64 + 1) * 2;
    vdp.vram[addr] = @intCast(entry >> 8);
    vdp.vram[addr + 1] = @intCast(entry & 0xFF);

    const s = try allocScene();
    defer testing.allocator.destroy(s);
    try testing.expect(extract(vdp, s));

    const c = s.gen_plane_a[2 * 64 + 1];
    try testing.expectEqual(@as(u16, 0x2A5), c.tile_index);
    try testing.expectEqual(@as(u8, 48), c.palette);
    try testing.expect(c.flags & scene.cell_flag_priority != 0);
    try testing.expect(c.flags & scene.cell_flag_v_flip != 0);
    try testing.expect(c.flags & scene.cell_flag_h_flip == 0);
}

test "genesis extract walks sprites in link order" {
    const vdp = try testVdp();
    defer testing.allocator.destroy(vdp);
    const sat: usize = 0xD800;
    // Sprite 0: y=0x100, 2x3 tiles, link 5, priority + palette 2, x=0x120.
    vdp.vram[sat + 0] = 0x01;
    vdp.vram[sat + 1] = 0x00;
    vdp.vram[sat + 2] = (1 << 2) | 2; // h_size 2, v_size 3
    vdp.vram[sat + 3] = 5;
    vdp.vram[sat + 4] = 0xC0; // priority, palette 2
    vdp.vram[sat + 5] = 0x10; // tile 0x010
    vdp.vram[sat + 6] = 0x01;
    vdp.vram[sat + 7] = 0x20;
    // Sprite 5: link 0 terminates.
    vdp.vram[sat + 5 * 8 + 0] = 0x00;
    vdp.vram[sat + 5 * 8 + 1] = 0x90;
    vdp.vram[sat + 5 * 8 + 6] = 0x00;
    vdp.vram[sat + 5 * 8 + 7] = 0xA0;

    const s = try allocScene();
    defer testing.allocator.destroy(s);
    try testing.expect(extract(vdp, s));

    try testing.expectEqual(@as(u8, 2), s.gen_sprite_count);
    const sp = s.gen_sprites[0];
    try testing.expectEqual(@as(i16, 0x120 - 128), sp.x);
    try testing.expectEqual(@as(i16, 0x100 - 128), sp.y);
    try testing.expectEqual(@as(u8, 2), sp.h_size);
    try testing.expectEqual(@as(u8, 3), sp.v_size);
    try testing.expectEqual(@as(u8, 32), sp.palette);
    try testing.expectEqual(@as(u16, 0x010), sp.tile_base);
    try testing.expect(sp.flags & scene.sprite_flag_priority != 0);
    try testing.expectEqual(@as(u8, 0), sp.slot);
    try testing.expectEqual(@as(u8, 5), s.gen_sprites[1].slot);
    try testing.expectEqual(@as(i16, 0xA0 - 128), s.gen_sprites[1].x);
}

test "genesis extract reads per-line hscroll and per-column vscroll" {
    const vdp = try testVdp();
    defer testing.allocator.destroy(vdp);
    vdp.regs[11] = 0x03 | 0x04; // per-line hscroll, per-column vscroll
    vdp.regs[13] = 0x3F; // hscroll table at 0xFC00
    // Line 3, plane A: hscroll -5 (0xFFFB); plane B at +2 bytes: 7.
    const base = 0xFC00 + 3 * 4;
    vdp.vram[base] = 0xFF;
    vdp.vram[base + 1] = 0xFB;
    vdp.vram[base + 2] = 0x00;
    vdp.vram[base + 3] = 0x07;
    // Column pair 4, plane B vscroll = 0x30.
    vdp.vsram[4 * 4 + 2] = 0x00;
    vdp.vsram[4 * 4 + 3] = 0x30;

    const s = try allocScene();
    defer testing.allocator.destroy(s);
    try testing.expect(extract(vdp, s));

    try testing.expect(s.gen_flags & scene.gen_flag_column_vscroll != 0);
    try testing.expectEqual(@as(i16, -5), s.gen_a_line_hscroll[3]);
    try testing.expectEqual(@as(i16, 7), s.gen_b_line_hscroll[3]);
    try testing.expectEqual(@as(u16, 0x30), s.gen_b_col_vscroll[4]);
}

test "genesis extract decodes tiles as 4bpp palette indices" {
    const vdp = try testVdp();
    defer testing.allocator.destroy(vdp);
    // Tile 2, row 0: pixels 1,2,3,4,5,6,7,8.
    const base = 2 * 32;
    vdp.vram[base + 0] = 0x12;
    vdp.vram[base + 1] = 0x34;
    vdp.vram[base + 2] = 0x56;
    vdp.vram[base + 3] = 0x78;

    const s = try allocScene();
    defer testing.allocator.destroy(s);
    try testing.expect(extract(vdp, s));

    const px = s.tilePixels(2);
    for (0..8) |i| try testing.expectEqual(@as(u8, @intCast(i + 1)), px[i]);
    try testing.expect(s.tileIsDirty(2));
}

test "genesis extract clamps hardware-prohibited plane sizes" {
    const vdp = try testVdp();
    defer testing.allocator.destroy(vdp);
    vdp.regs[16] = 0x33; // 128x128 tiles: past the 8KB name-table budget

    const s = try allocScene();
    defer testing.allocator.destroy(s);
    try testing.expect(extract(vdp, s));

    try testing.expect(@as(usize, s.gen_plane_width) * s.gen_plane_height <= scene.gen_plane_cells);
    try testing.expectEqual(@as(u16, 128), s.gen_plane_width);
    try testing.expectEqual(@as(u16, 32), s.gen_plane_height);
}

test "genesis extract leaves emulation state byte-identical" {
    const before = try testing.allocator.create(Vdp);
    defer testing.allocator.destroy(before);
    const vdp = try testVdp();
    defer testing.allocator.destroy(vdp);
    vdp.vram[0xD800] = 0x01;
    before.* = vdp.*;

    const s = try allocScene();
    defer testing.allocator.destroy(s);
    try testing.expect(extract(vdp, s));
    try testing.expect(std.mem.eql(u8, std.mem.asBytes(before), std.mem.asBytes(vdp)));
}
