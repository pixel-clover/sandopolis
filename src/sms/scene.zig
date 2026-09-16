//! Frame scene extraction for the Master System VDP.
//!
//! Produces a `scene.FrameScene` describing the tilemap, sprites, palette,
//! and tile patterns the VDP would draw, for frontends that render the
//! picture as 3D geometry rather than as pixels.
//!
//! Mode 4 tiles map straight onto the shared pattern atlas. The TMS9918
//! modes cannot: their color tables bind color to screen position rather
//! than to the pattern, so each screen cell is rasterized into its own
//! atlas slot instead (see `extractTms`).
//!
//! This is a read-only observation. The VDP is taken by const pointer, and
//! unlike the rasterizer in `vdp.zig` the sprite scan here never writes the
//! overflow or collision status bits, and never applies the eight-sprites-
//! per-line hardware limit. Dropping sprites is a rasterizer artifact that
//! would show up as flickering geometry in 3D.

const std = @import("std");
const scene = @import("../scene.zig");
const SmsVdp = @import("vdp.zig").SmsVdp;

/// Sprite pattern indices are relative to a base of either 0x0000 or 0x2000.
/// Dividing by the 32 bytes per pattern folds that base into the same tile
/// atlas index space the background uses.
const bytes_per_pattern: u16 = 32;

/// Extract the current frame into `out`.
///
/// Returns true when the graphics mode was understood and the tilemap,
/// sprite, palette, and tile atlas sections were filled in. The header is
/// always written, so an unsupported mode still reports its system and mode.
///
/// Tile dirty bits are computed against whatever `out` already held, so
/// passing the same buffer each frame yields an accurate changed-tile set.
/// A freshly zeroed buffer reports every non-empty tile as dirty.
pub fn extract(vdp: *const SmsVdp, out: *scene.FrameScene) bool {
    const mode = vdp.graphicsMode();

    out.magic = scene.magic;
    out.version = scene.layout_version;
    out.system = @intFromEnum(systemKind(vdp));
    out.mode = @intFromEnum(sceneMode(mode));
    // The tilemap is always laid out in a 256-pixel-wide picture. Game Gear
    // shows a smaller window onto that same picture rather than changing it.
    out.picture_width = @intCast(SmsVdp.framebuffer_width);
    out.picture_height = vdp.activeVisibleLines();
    out.viewport_x = if (vdp.is_game_gear) @intCast(SmsVdp.gg_left) else 0;
    out.viewport_y = if (vdp.is_game_gear) vdp.ggViewportTop() else 0;
    out.viewport_width = vdp.screenWidth();
    out.viewport_height = vdp.displayHeight();

    var flags: u32 = 0;
    if (vdp.isDisplayEnabled()) flags |= scene.scene_flag_display_enabled;
    if (vdp.isLeftColumnBlanked()) flags |= scene.scene_flag_left_column_blanked;

    if (mode != .mode4) {
        extractTms(vdp, out, mode, flags);
        return true;
    }

    out.flags = flags | scene.scene_flag_content_valid;
    out.columns = @intCast(scene.max_columns);
    // The 224 and 240 line modes wrap the tilemap at 256 pixels rather than
    // 224, giving four more rows.
    out.rows = if (vdp.activeVisibleLines() > 192) 32 else 28;
    out.scroll_x = vdp.regs[8];
    out.scroll_y = vdp.latched_vscroll;
    out.hud_locked_rows = if (vdp.regs[0] & 0x40 != 0) 2 else 0;
    out.hud_locked_columns = if (vdp.regs[0] & 0x80 != 0) 8 else 0;
    out.backdrop = vdp.backdropColor();

    for (0..scene.max_palette) |i| {
        out.palette[i] = vdp.paletteColor(@intCast(i));
    }

    const lines = @min(scene.max_lines, @as(usize, out.picture_height));
    for (0..lines) |i| out.line_scroll_x[i] = vdp.line_hscroll[i];
    for (lines..scene.max_lines) |i| out.line_scroll_x[i] = 0;

    extractCells(vdp, out);
    extractSprites(vdp, out);
    extractTiles(vdp, out);
    return true;
}


// -- TMS9918 modes (SG-1000, and SMS titles that select a legacy mode) --

/// First atlas slot used for TMS sprite patterns. Slots 0-767 belong to the
/// background, one per screen cell.
const tms_sprite_slot_base: u16 = 768;

/// Atlas value used for TMS color 0. The hardware treats color 0 as
/// transparent-to-backdrop, but this emulator's rasterizer draws it as black
/// regardless of the backdrop, so it needs an opaque palette slot of its own;
/// atlas value 0 stays reserved for genuinely backdrop-showing pixels (the
/// Text mode side borders).
const tms_black_slot: u8 = 16;

/// The TMS color tables bind color to screen position rather than to the
/// pattern, so a shared pattern atlas cannot represent them. Instead every
/// screen cell is rasterized into its own atlas slot with the final TMS
/// color index per pixel, and the palette carries the fixed TMS colors.
fn extractTms(vdp: *const SmsVdp, out: *scene.FrameScene, mode: SmsVdp.GraphicsMode, flags_in: u32) void {
    // Register 0 bit 5 is Mode 4 left-column blanking, not a TMS feature.
    out.flags = (flags_in & ~scene.scene_flag_left_column_blanked) |
        scene.scene_flag_content_valid;
    out.columns = @intCast(scene.max_columns);
    out.rows = 24;
    out.scroll_x = 0;
    out.scroll_y = 0;
    out.hud_locked_rows = 0;
    out.hud_locked_columns = 0;
    out.tile_count = @intCast(scene.max_tiles);
    @memset(&out.tile_dirty, 0);
    for (0..scene.max_lines) |i| out.line_scroll_x[i] = 0;

    // Fixed TMS palette in bank 0, opaque black for TMS color 0 at slot 16.
    for (0..16) |i| {
        out.palette[i] = if (i == 0) 0 else SmsVdp.tmsPaletteColor(@intCast(i));
    }
    out.palette[tms_black_slot] = 0xFF000000;
    for (tms_black_slot + 1..scene.max_palette) |i| out.palette[i] = 0;

    // Backdrop: register 7 low nibble, black when 0 (mirrors the rasterizer).
    const bd: u4 = @truncate(vdp.regs[7] & 0x0F);
    out.backdrop = if (bd == 0) 0xFF000000 else SmsVdp.tmsPaletteColor(bd);

    // Background: one atlas slot per cell, cell (r, c) -> slot r * 32 + c.
    var pixels: [scene.pixels_per_tile]u8 = undefined;
    for (0..24) |row| {
        for (0..scene.max_columns) |col| {
            const slot = row * scene.max_columns + col;
            out.cells[slot] = .{ .tile_index = @intCast(slot) };
            rasterizeTmsCell(vdp, mode, row, col, &pixels);
            storeTile(out, slot, &pixels);
        }
    }
    for (24 * scene.max_columns..scene.max_cells) |i| out.cells[i] = .{};

    extractTmsSprites(vdp, out);
}

/// Rasterize one 8x8 screen cell of the background into TMS color indices,
/// mirroring the corresponding mode renderer in `vdp.zig` exactly. Output
/// values: 0 = backdrop shows through, `tms_black_slot` = explicit TMS color
/// 0 (drawn black), otherwise the TMS color index.
fn rasterizeTmsCell(
    vdp: *const SmsVdp,
    mode: SmsVdp.GraphicsMode,
    row: usize,
    col: usize,
    pixels: *[scene.pixels_per_tile]u8,
) void {
    const name_base: u16 = (@as(u16, vdp.regs[2]) & 0x0F) << 10;

    switch (mode) {
        .mode2_graphics2 => {
            const pg_base: u16 = (@as(u16, vdp.regs[4]) & 0x04) << 11;
            const pg_mask: u16 = ((@as(u16, vdp.regs[4]) & 0x03) << 8) | 0xFF;
            const ct_base: u16 = (@as(u16, vdp.regs[3]) & 0x80) << 6;
            const ct_mask: u16 = ((@as(u16, vdp.regs[3]) & 0x7F) << 3) | 0x07;
            const group_offset: u16 = @intCast((row / 8) * 256);
            const tile: u16 = vdp.vram[(name_base + row * 32 + col) & 0x3FFF];
            for (0..8) |fine_y| {
                const pg_addr = pg_base + ((tile + group_offset) & pg_mask) * 8 + fine_y;
                const ct_addr = ct_base + ((tile + group_offset) & ct_mask) * 8 + fine_y;
                writeTmsPatternRow(
                    pixels[fine_y * 8 ..][0..8],
                    vdp.vram[pg_addr & 0x3FFF],
                    @truncate(vdp.vram[ct_addr & 0x3FFF] >> 4),
                    @truncate(vdp.vram[ct_addr & 0x3FFF] & 0x0F),
                );
            }
        },
        .mode1_graphics1 => {
            const pg_base: u16 = (@as(u16, vdp.regs[4]) & 0x07) << 11;
            const ct_base: u16 = @as(u16, vdp.regs[3]) << 6;
            const tile: u16 = vdp.vram[(name_base + row * 32 + col) & 0x3FFF];
            const color_byte = vdp.vram[(ct_base + tile / 8) & 0x3FFF];
            for (0..8) |fine_y| {
                writeTmsPatternRow(
                    pixels[fine_y * 8 ..][0..8],
                    vdp.vram[(pg_base + tile * 8 + fine_y) & 0x3FFF],
                    @truncate(color_byte >> 4),
                    @truncate(color_byte & 0x0F),
                );
            }
        },
        .mode0_text => {
            // 40 characters of 6 pixels each, centered with 8-pixel borders;
            // characters straddle the 8-pixel cell grid, so each cell pixel
            // resolves its own character.
            const pg_base: u16 = (@as(u16, vdp.regs[4]) & 0x07) << 11;
            const fg: u4 = @truncate(vdp.regs[7] >> 4);
            const bg: u4 = @truncate(vdp.regs[7] & 0x0F);
            for (0..8) |fine_y| {
                for (0..8) |px| {
                    const x = col * 8 + px;
                    if (x < 8 or x >= 8 + 40 * 6) {
                        pixels[fine_y * 8 + px] = 0; // border: backdrop
                        continue;
                    }
                    const char_col = (x - 8) / 6;
                    const bit: u3 = @intCast((x - 8) % 6);
                    const tile: u16 = vdp.vram[(name_base + row * 40 + char_col) & 0x3FFF];
                    const pattern = vdp.vram[(pg_base + tile * 8 + fine_y) & 0x3FFF];
                    const set = (pattern & (@as(u8, 0x80) >> bit)) != 0;
                    pixels[fine_y * 8 + px] = tmsIndexValue(if (set) fg else bg);
                }
            }
        },
        .mode3_multicolor => {
            const pg_base: u16 = (@as(u16, vdp.regs[4]) & 0x07) << 11;
            const tile: u16 = vdp.vram[(name_base + row * 32 + col) & 0x3FFF];
            for (0..8) |fine_y| {
                const sub_row = (fine_y / 4) & 1;
                const color_byte = vdp.vram[(pg_base + tile * 8 + (row & 3) * 2 + sub_row) & 0x3FFF];
                const left = tmsIndexValue(@truncate(color_byte >> 4));
                const right = tmsIndexValue(@truncate(color_byte & 0x0F));
                for (0..4) |px| pixels[fine_y * 8 + px] = left;
                for (4..8) |px| pixels[fine_y * 8 + px] = right;
            }
        },
        .mode4 => unreachable,
    }
}

fn tmsIndexValue(color: u4) u8 {
    return if (color == 0) tms_black_slot else color;
}

fn writeTmsPatternRow(row_pixels: []u8, pattern: u8, fg: u4, bg: u4) void {
    for (0..8) |bit| {
        const set = (pattern & (@as(u8, 0x80) >> @as(u3, @intCast(bit)))) != 0;
        row_pixels[bit] = tmsIndexValue(if (set) fg else bg);
    }
}

/// TMS sprites are monochrome with a per-sprite color and their own pattern
/// table. Each hardware sprite gets four atlas slots; 16x16 sprites become
/// two 8-wide scene sprites so the renderer's vertical tile-pair convention
/// applies unchanged.
fn extractTmsSprites(vdp: *const SmsVdp, out: *scene.FrameScene) void {
    const sat_base: u16 = (@as(u16, vdp.regs[5]) & 0x7F) << 7;
    const sg_base: u16 = (@as(u16, vdp.regs[6]) & 0x07) << 11;
    const is_16x16 = (vdp.regs[1] & 0x02) != 0;
    const is_magnified = (vdp.regs[1] & 0x01) != 0;

    var pixels: [scene.pixels_per_tile]u8 = undefined;
    var count: u8 = 0;
    for (0..32) |i| {
        const entry = sat_base + @as(u16, @intCast(i)) * 4;
        const y_raw = vdp.vram[entry & 0x3FFF];
        if (y_raw == 0xD0) break;

        const x_raw = vdp.vram[(entry + 1) & 0x3FFF];
        const pattern = vdp.vram[(entry + 2) & 0x3FFF];
        const attr = vdp.vram[(entry + 3) & 0x3FFF];
        const color: u4 = @truncate(attr & 0x0F);
        // An invisible sprite still occupies its table slot; the rasterizer
        // skips it entirely, so the scene does too.
        if (color == 0) continue;

        const x: i16 = @as(i16, x_raw) - if (attr & 0x80 != 0) @as(i16, 32) else 0;
        const y: i16 = @as(i16, y_raw) + 1;
        const size: u8 = if (is_magnified) 16 else 8;
        const doubled_flag: u8 = if (is_magnified) scene.sprite_flag_doubled else 0;
        const base: u16 = tms_sprite_slot_base + @as(u16, @intCast(i)) * 4;

        if (is_16x16) {
            const masked: u16 = @as(u16, pattern) & 0xFC;
            // Block layout in the sprite generator: left column rows 0-15,
            // then right column rows 0-15, eight bytes per block.
            for (0..4) |block| {
                rasterizeTmsSpriteBlock(vdp, sg_base + masked * 8 + @as(u16, @intCast(block)) * 8, color, &pixels);
                storeTile(out, base + block, &pixels);
            }
            if (count + 2 > scene.max_sprites) break;
            out.sprites[count] = .{
                .x = x,
                .y = y,
                .tile_index = base,
                .slot = @intCast(i),
                .width = size,
                .height = size * 2,
                .flags = doubled_flag,
            };
            out.sprites[count + 1] = .{
                .x = x + size,
                .y = y,
                .tile_index = base + 2,
                .slot = @intCast(i),
                .width = size,
                .height = size * 2,
                .flags = doubled_flag,
            };
            count += 2;
        } else {
            rasterizeTmsSpriteBlock(vdp, sg_base + @as(u16, pattern) * 8, color, &pixels);
            storeTile(out, base, &pixels);
            if (count + 1 > scene.max_sprites) break;
            out.sprites[count] = .{
                .x = x,
                .y = y,
                .tile_index = base,
                .slot = @intCast(i),
                .width = size,
                .height = size,
                .flags = doubled_flag,
            };
            count += 1;
        }
    }

    out.sprite_count = count;
    for (count..scene.max_sprites) |i| out.sprites[i] = .{};
}

fn rasterizeTmsSpriteBlock(
    vdp: *const SmsVdp,
    addr: u16,
    color: u4,
    pixels: *[scene.pixels_per_tile]u8,
) void {
    for (0..8) |fine_y| {
        const pattern = vdp.vram[(addr + fine_y) & 0x3FFF];
        for (0..8) |bit| {
            const set = (pattern & (@as(u8, 0x80) >> @as(u3, @intCast(bit)))) != 0;
            pixels[fine_y * 8 + bit] = if (set) color else 0;
        }
    }
}

fn systemKind(vdp: *const SmsVdp) scene.SystemKind {
    if (vdp.is_game_gear) return .game_gear;
    if (vdp.is_sg1000) return .sg1000;
    return .sms;
}

fn sceneMode(mode: SmsVdp.GraphicsMode) scene.GraphicsMode {
    return switch (mode) {
        .mode4 => .mode4,
        .mode0_text => .mode0_text,
        .mode1_graphics1 => .mode1_graphics1,
        .mode2_graphics2 => .mode2_graphics2,
        .mode3_multicolor => .mode3_multicolor,
    };
}

fn extractCells(vdp: *const SmsVdp, out: *scene.FrameScene) void {
    const name_base = vdp.nameTableBase();
    const rows: usize = out.rows;

    for (0..rows) |row| {
        for (0..scene.max_columns) |col| {
            const offset = name_base +% @as(u16, @intCast(row * 64 + col * 2));
            const lo: u16 = vdp.vram[offset & 0x3FFF];
            const hi: u16 = vdp.vram[(offset +% 1) & 0x3FFF];
            const entry = lo | (hi << 8);

            var cell_flags: u8 = 0;
            if (entry & 0x0200 != 0) cell_flags |= scene.cell_flag_h_flip;
            if (entry & 0x0400 != 0) cell_flags |= scene.cell_flag_v_flip;
            if (entry & 0x1000 != 0) cell_flags |= scene.cell_flag_priority;

            out.cells[row * scene.max_columns + col] = .{
                .tile_index = entry & 0x01FF,
                .palette = if (entry & 0x0800 != 0) 16 else 0,
                .flags = cell_flags,
            };
        }
    }

    // Clear rows past the visible tilemap so a mode change cannot leave
    // stale cells visible to the frontend.
    for (rows * scene.max_columns..scene.max_cells) |i| {
        out.cells[i] = .{};
    }
}

fn extractSprites(vdp: *const SmsVdp, out: *scene.FrameScene) void {
    const sat_base = vdp.spriteAttributeTableBase();
    const pattern_offset: u16 = vdp.spritePatternBase() / bytes_per_pattern;
    const height = vdp.spriteHeight();
    const doubled = vdp.isSpriteDouble();
    const tall = vdp.isTall();
    const early_shift: i16 = if (vdp.regs[0] & 0x08 != 0) 8 else 0;
    // Only the 192-line mode treats Y = 0xD0 as an end-of-list marker.
    const terminates = vdp.activeVisibleLines() == 192;

    var count: u8 = 0;
    for (0..scene.max_sprites) |i| {
        const y_raw = vdp.vram[(sat_base +% @as(u16, @intCast(i))) & 0x3FFF];
        if (terminates and y_raw == 0xD0) break;

        const info = sat_base +% @as(u16, @intCast(128 + i * 2));
        const x_raw = vdp.vram[info & 0x3FFF];
        var tile: u16 = vdp.vram[(info +% 1) & 0x3FFF];
        // Tall sprites use a pattern pair, so the low index bit is ignored.
        if (tall) tile &= 0xFE;

        out.sprites[count] = .{
            // The hardware compares the scanline against Y + 1 with 8-bit
            // wraparound, so a sprite placed near 0xFF reappears at the top
            // of the screen.
            .y = @as(i16, y_raw +% 1),
            // Signed, so a sprite clipped by the left edge keeps its real
            // position instead of wrapping the way the rasterizer's unsigned
            // arithmetic does.
            .x = @as(i16, x_raw) - early_shift,
            .tile_index = tile + pattern_offset,
            .slot = @intCast(i),
            // Mode 4 sprites always use the second palette bank, and the
            // sprite table carries no flip or priority bits.
            .palette = 16,
            .width = if (doubled) 16 else 8,
            .height = height,
            .flags = if (doubled) scene.sprite_flag_doubled else 0,
        };
        count += 1;
    }

    out.sprite_count = count;
    for (count..scene.max_sprites) |i| {
        out.sprites[i] = .{};
    }
}

fn extractTiles(vdp: *const SmsVdp, out: *scene.FrameScene) void {
    @memset(&out.tile_dirty, 0);

    // Mode 4 VRAM holds 512 patterns; the atlas slots above that belong to
    // the TMS modes and are left untouched (nothing references them here).
    var pixels: [scene.pixels_per_tile]u8 = undefined;
    for (0..512) |tile| {
        decodePattern(vdp, @intCast(tile), &pixels);
        storeTile(out, tile, &pixels);
    }

    out.tile_count = 512;
}

/// Write one tile into the atlas, marking it dirty only when the pixels
/// actually changed since the previous extraction into this buffer.
fn storeTile(out: *scene.FrameScene, index: usize, pixels: *const [scene.pixels_per_tile]u8) void {
    const dest = out.tile_atlas[index * scene.pixels_per_tile ..][0..scene.pixels_per_tile];
    if (!std.mem.eql(u8, dest, pixels)) {
        out.markTileDirty(index);
        @memcpy(dest, pixels);
    }
}

/// Decode one 8x8 pattern from the four-bitplane VRAM format into one
/// palette index per pixel.
fn decodePattern(vdp: *const SmsVdp, tile: u16, pixels: *[scene.pixels_per_tile]u8) void {
    const base = tile *% bytes_per_pattern;
    for (0..scene.tile_height) |row| {
        const addr = base +% @as(u16, @intCast(row * 4));
        const b0 = vdp.vram[addr & 0x3FFF];
        const b1 = vdp.vram[(addr +% 1) & 0x3FFF];
        const b2 = vdp.vram[(addr +% 2) & 0x3FFF];
        const b3 = vdp.vram[(addr +% 3) & 0x3FFF];
        for (0..scene.tile_width) |x| {
            const bit: u3 = @intCast(7 - x);
            pixels[row * scene.tile_width + x] =
                ((b0 >> bit) & 1) |
                (((b1 >> bit) & 1) << 1) |
                (((b2 >> bit) & 1) << 2) |
                (((b3 >> bit) & 1) << 3);
        }
    }
}

// -- Tests --

const testing = std.testing;

fn testVdp() SmsVdp {
    var vdp = SmsVdp.init();
    vdp.regs[1] |= 0x40; // enable display
    return vdp;
}

/// Write a background tilemap entry for (col, row) with no scroll applied.
fn writeCell(vdp: *SmsVdp, col: u16, row: u16, entry: u16) void {
    const offset = vdp.nameTableBase() + (row * 64) + (col * 2);
    vdp.vram[offset & 0x3FFF] = @truncate(entry);
    vdp.vram[(offset + 1) & 0x3FFF] = @truncate(entry >> 8);
}

fn writeSprite(vdp: *SmsVdp, slot: u16, y: u8, x: u8, tile: u8) void {
    const base = vdp.spriteAttributeTableBase();
    vdp.vram[(base + slot) & 0x3FFF] = y;
    const info = base + 128 + slot * 2;
    vdp.vram[info & 0x3FFF] = x;
    vdp.vram[(info + 1) & 0x3FFF] = tile;
}

fn endSpriteList(vdp: *SmsVdp, slot: u16) void {
    const base = vdp.spriteAttributeTableBase();
    vdp.vram[(base + slot) & 0x3FFF] = 0xD0;
}

/// Write one 8x8 pattern where every pixel takes `color`.
fn writeSolidPattern(vdp: *SmsVdp, tile: u16, color: u4) void {
    const addr = tile * bytes_per_pattern;
    for (0..8) |row| {
        const at = (addr + row * 4) & 0x3FFF;
        vdp.vram[at] = if (color & 0x1 != 0) 0xFF else 0x00;
        vdp.vram[at + 1] = if (color & 0x2 != 0) 0xFF else 0x00;
        vdp.vram[at + 2] = if (color & 0x4 != 0) 0xFF else 0x00;
        vdp.vram[at + 3] = if (color & 0x8 != 0) 0xFF else 0x00;
    }
}

fn allocScene() !*scene.FrameScene {
    const s = try testing.allocator.create(scene.FrameScene);
    s.* = .{};
    return s;
}

test "extract fills the header for Mode 4" {
    var vdp = testVdp();
    const s = try allocScene();
    defer testing.allocator.destroy(s);

    try testing.expect(extract(&vdp, s));
    try testing.expectEqual(scene.magic, s.magic);
    try testing.expectEqual(scene.layout_version, s.version);
    try testing.expectEqual(@intFromEnum(scene.SystemKind.sms), s.system);
    try testing.expectEqual(@intFromEnum(scene.GraphicsMode.mode4), s.mode);
    try testing.expectEqual(@as(u8, 32), s.columns);
    try testing.expectEqual(@as(u8, 28), s.rows);
    try testing.expectEqual(@as(u16, 256), s.picture_width);
    try testing.expectEqual(@as(u16, 192), s.picture_height);
    // Master System shows the whole picture.
    try testing.expectEqual(@as(u16, 0), s.viewport_x);
    try testing.expectEqual(@as(u16, 0), s.viewport_y);
    try testing.expectEqual(@as(u16, 256), s.viewport_width);
    try testing.expectEqual(@as(u16, 192), s.viewport_height);
    // Mode 4 VRAM holds 512 patterns; the rest of the atlas is TMS-only.
    try testing.expectEqual(@as(u16, 512), s.tile_count);
    try testing.expect(s.contentValid());
    try testing.expect(s.flags & scene.scene_flag_display_enabled != 0);
}

test "extract reports the Game Gear viewport as a window on the full picture" {
    var vdp = testVdp();
    vdp.is_game_gear = true;
    const s = try allocScene();
    defer testing.allocator.destroy(s);

    try testing.expect(extract(&vdp, s));
    try testing.expectEqual(@intFromEnum(scene.SystemKind.game_gear), s.system);
    // The VDP still lays the tilemap out at the full Master System size.
    try testing.expectEqual(@as(u16, 256), s.picture_width);
    try testing.expectEqual(@as(u16, 192), s.picture_height);
    // The LCD shows a 160x144 window centered horizontally.
    try testing.expectEqual(@as(u16, 48), s.viewport_x);
    try testing.expectEqual(@as(u16, 24), s.viewport_y);
    try testing.expectEqual(@as(u16, 160), s.viewport_width);
    try testing.expectEqual(@as(u16, 144), s.viewport_height);
}

test "extract decodes tilemap entries" {
    var vdp = testVdp();
    // Tile 0x1A5, horizontally and vertically flipped, palette bank 1,
    // drawn in front of sprites.
    writeCell(&vdp, 3, 2, 0x1A5 | 0x0200 | 0x0400 | 0x0800 | 0x1000);
    writeCell(&vdp, 0, 0, 0x012);

    const s = try allocScene();
    defer testing.allocator.destroy(s);
    try testing.expect(extract(&vdp, s));

    const c = s.cell(3, 2);
    try testing.expectEqual(@as(u16, 0x1A5), c.tile_index);
    try testing.expectEqual(@as(u8, 16), c.palette);
    try testing.expectEqual(
        scene.cell_flag_h_flip | scene.cell_flag_v_flip | scene.cell_flag_priority,
        c.flags,
    );

    const plain = s.cell(0, 0);
    try testing.expectEqual(@as(u16, 0x012), plain.tile_index);
    try testing.expectEqual(@as(u8, 0), plain.palette);
    try testing.expectEqual(@as(u8, 0), plain.flags);
}

test "extract converts the palette and backdrop" {
    var vdp = testVdp();
    vdp.cram[5] = 0x2A; // --BBGGRR: R=2, G=2, B=2
    vdp.regs[7] = 0x05; // backdrop is palette entry 0x15

    const s = try allocScene();
    defer testing.allocator.destroy(s);
    try testing.expect(extract(&vdp, s));

    const expected: u32 = (0xFF << 24) | (170 << 16) | (170 << 8) | 170;
    try testing.expectEqual(expected, s.palette[5]);
    try testing.expectEqual(vdp.paletteColor(0x15), s.backdrop);
}

test "extract reports hardware scroll locks as HUD regions" {
    const s = try allocScene();
    defer testing.allocator.destroy(s);

    var vdp = testVdp();
    try testing.expect(extract(&vdp, s));
    try testing.expectEqual(@as(u8, 0), s.hud_locked_rows);
    try testing.expectEqual(@as(u8, 0), s.hud_locked_columns);

    vdp.regs[0] |= 0x40; // lock horizontal scroll on the top two rows
    vdp.regs[0] |= 0x80; // lock vertical scroll on the right eight columns
    try testing.expect(extract(&vdp, s));
    try testing.expectEqual(@as(u8, 2), s.hud_locked_rows);
    try testing.expectEqual(@as(u8, 8), s.hud_locked_columns);
}

test "extract captures horizontal scroll for each line" {
    var vdp = testVdp();
    // A raster split: the top band scrolls at one offset, the rest at another.
    vdp.regs[8] = 0x10;
    _ = vdp.stepScanline();
    _ = vdp.stepScanline();
    vdp.regs[8] = 0x40;
    _ = vdp.stepScanline();

    const s = try allocScene();
    defer testing.allocator.destroy(s);
    try testing.expect(extract(&vdp, s));

    try testing.expectEqual(@as(u16, 0x10), s.line_scroll_x[0]);
    try testing.expectEqual(@as(u16, 0x10), s.line_scroll_x[1]);
    try testing.expectEqual(@as(u16, 0x40), s.line_scroll_x[2]);
    try testing.expectEqual(@as(u16, 0x10), s.lineScrollX(0));
    try testing.expectEqual(@as(u16, 0x40), s.lineScrollX(2));
}

test "extract clears per-line scroll beyond the visible picture" {
    var vdp = testVdp();
    vdp.regs[8] = 0x22;
    for (0..vdp.activeVisibleLines()) |_| _ = vdp.stepScanline();

    const s = try allocScene();
    defer testing.allocator.destroy(s);
    try testing.expect(extract(&vdp, s));

    try testing.expectEqual(@as(u16, 0x22), s.line_scroll_x[191]);
    // 192-line mode leaves the rest of the array untouched by the game.
    try testing.expectEqual(@as(u16, 0), s.line_scroll_x[192]);
    try testing.expectEqual(@as(u16, 0), s.line_scroll_x[scene.max_lines - 1]);
}

test "extract reports frame scroll offsets" {
    var vdp = testVdp();
    vdp.regs[8] = 0x37;
    vdp.regs[9] = 0x11;
    vdp.beginFrame(); // latches vertical scroll

    const s = try allocScene();
    defer testing.allocator.destroy(s);
    try testing.expect(extract(&vdp, s));
    try testing.expectEqual(@as(u16, 0x37), s.scroll_x);
    try testing.expectEqual(@as(u16, 0x11), s.scroll_y);
}

test "extract decodes sprites and folds the pattern base into the atlas index" {
    var vdp = testVdp();
    writeSprite(&vdp, 0, 0x20, 100, 5);
    endSpriteList(&vdp, 1);

    const s = try allocScene();
    defer testing.allocator.destroy(s);
    try testing.expect(extract(&vdp, s));

    try testing.expectEqual(@as(u8, 1), s.sprite_count);
    const sp = s.sprites[0];
    try testing.expectEqual(@as(u8, 0), sp.slot);
    try testing.expectEqual(@as(i16, 100), sp.x);
    try testing.expectEqual(@as(i16, 0x21), sp.y); // hardware adds one
    try testing.expectEqual(@as(u8, 8), sp.width);
    try testing.expectEqual(@as(u8, 8), sp.height);
    try testing.expectEqual(@as(u8, 16), sp.palette);
    // Register 6 bit 2 clear puts sprite patterns at 0x0000, so the atlas
    // index is the raw pattern number.
    try testing.expectEqual(@as(u16, 5), sp.tile_index);

    // Setting it moves them to 0x2000, which is atlas tile 256.
    vdp.regs[6] |= 0x04;
    try testing.expect(extract(&vdp, s));
    try testing.expectEqual(@as(u16, 5 + 256), s.sprites[0].tile_index);
}

test "extract applies the early X shift as a negative position" {
    var vdp = testVdp();
    vdp.regs[0] |= 0x08; // shift sprites eight pixels left
    writeSprite(&vdp, 0, 0x20, 4, 0);
    endSpriteList(&vdp, 1);

    const s = try allocScene();
    defer testing.allocator.destroy(s);
    try testing.expect(extract(&vdp, s));
    try testing.expectEqual(@as(i16, -4), s.sprites[0].x);
}

test "extract reports doubled and tall sprite sizes" {
    var vdp = testVdp();
    vdp.regs[1] |= 0x02; // tall sprites, 8x16
    vdp.regs[1] |= 0x01; // zoom, doubling both axes
    vdp.regs[6] |= 0x04; // sprite patterns at 0x2000
    writeSprite(&vdp, 0, 0x20, 10, 0x07);
    endSpriteList(&vdp, 1);

    const s = try allocScene();
    defer testing.allocator.destroy(s);
    try testing.expect(extract(&vdp, s));

    const sp = s.sprites[0];
    try testing.expectEqual(@as(u8, 16), sp.width);
    try testing.expectEqual(@as(u8, 32), sp.height);
    try testing.expect(sp.flags & scene.sprite_flag_doubled != 0);
    // Tall sprites mask off the low bit of the pattern index.
    try testing.expectEqual(@as(u16, 0x06 + 256), sp.tile_index);
}

test "extract honors the sprite list terminator in 192-line mode" {
    var vdp = testVdp();
    writeSprite(&vdp, 0, 0x20, 10, 1);
    writeSprite(&vdp, 1, 0x30, 20, 2);
    endSpriteList(&vdp, 2);
    writeSprite(&vdp, 3, 0x40, 30, 3);

    const s = try allocScene();
    defer testing.allocator.destroy(s);
    try testing.expect(extract(&vdp, s));
    try testing.expectEqual(@as(u8, 2), s.sprite_count);
}

test "extract ignores the eight-sprites-per-line limit" {
    var vdp = testVdp();
    // Twelve sprites sharing a scanline. The rasterizer would drop four.
    for (0..12) |i| {
        writeSprite(&vdp, @intCast(i), 0x20, @intCast(i * 10), @intCast(i));
    }
    endSpriteList(&vdp, 12);

    const s = try allocScene();
    defer testing.allocator.destroy(s);
    try testing.expect(extract(&vdp, s));
    try testing.expectEqual(@as(u8, 12), s.sprite_count);
}

test "extract does not touch sprite overflow or collision status" {
    var vdp = testVdp();
    // Twelve overlapping sprites on one line: enough to trip both the
    // overflow and the collision bits if the rasterizer ran.
    writeSolidPattern(&vdp, 256, 1);
    for (0..12) |i| {
        writeSprite(&vdp, @intCast(i), 0x20, 40, 0);
    }
    endSpriteList(&vdp, 12);

    const s = try allocScene();
    defer testing.allocator.destroy(s);
    try testing.expect(extract(&vdp, s));
    try testing.expectEqual(@as(u8, 0), vdp.status);
}

test "extract leaves emulation state byte-identical" {
    const before = try testing.allocator.create(SmsVdp);
    defer testing.allocator.destroy(before);
    const vdp = try testing.allocator.create(SmsVdp);
    defer testing.allocator.destroy(vdp);

    vdp.* = testVdp();
    writeCell(vdp, 1, 1, 0x0123);
    writeSprite(vdp, 0, 0x20, 10, 4);
    endSpriteList(vdp, 1);
    writeSolidPattern(vdp, 12, 9);
    before.* = vdp.*;

    const s = try allocScene();
    defer testing.allocator.destroy(s);
    try testing.expect(extract(vdp, s));

    try testing.expect(std.mem.eql(u8, std.mem.asBytes(before), std.mem.asBytes(vdp)));
}

test "extract decodes tile patterns as palette indices" {
    var vdp = testVdp();
    writeSolidPattern(&vdp, 3, 0xA);
    // A single pixel of color 6 at (1, 0) of tile 4: planes 1 and 2 set.
    const addr = 4 * bytes_per_pattern;
    vdp.vram[addr + 1] = 0x40;
    vdp.vram[addr + 2] = 0x40;

    const s = try allocScene();
    defer testing.allocator.destroy(s);
    try testing.expect(extract(&vdp, s));

    for (s.tilePixels(3)) |px| try testing.expectEqual(@as(u8, 0xA), px);

    const t4 = s.tilePixels(4);
    try testing.expectEqual(@as(u8, 0), t4[0]);
    try testing.expectEqual(@as(u8, 6), t4[1]);
    try testing.expectEqual(@as(u8, 0), t4[2]);
}

test "extract marks only changed tiles dirty" {
    var vdp = testVdp();
    writeSolidPattern(&vdp, 7, 3);

    const s = try allocScene();
    defer testing.allocator.destroy(s);

    try testing.expect(extract(&vdp, s));
    try testing.expect(s.tileIsDirty(7));

    // Nothing changed, so a second extraction into the same buffer reports
    // no dirty tiles at all.
    try testing.expect(extract(&vdp, s));
    for (0..scene.max_tiles) |i| {
        try testing.expect(!s.tileIsDirty(i));
    }

    writeSolidPattern(&vdp, 7, 5);
    try testing.expect(extract(&vdp, s));
    try testing.expect(s.tileIsDirty(7));
    try testing.expect(!s.tileIsDirty(6));
    try testing.expect(!s.tileIsDirty(8));
}

fn testTmsVdp() SmsVdp {
    var vdp = SmsVdp.init();
    vdp.is_sg1000 = true; // register 0 bit 2 is not Mode 4 on SG-1000
    vdp.regs[0] = 0x02; // M2 selects TMS9918 Graphics II
    vdp.regs[1] = 0xE0; // display on
    vdp.regs[2] = 0x0E; // name table at 0x3800
    vdp.regs[3] = 0xFF; // color table at 0x2000, full mask
    vdp.regs[4] = 0x03; // patterns at 0x0000, full mask
    vdp.regs[5] = 0x76; // SAT at 0x3B00
    vdp.regs[6] = 0x03; // sprite patterns at 0x1800
    vdp.regs[7] = 0x01; // backdrop black (TMS color 1)
    return vdp;
}

test "extract describes TMS Graphics II with one atlas slot per cell" {
    var vdp = testTmsVdp();
    // Cell (2, 1) shows tile 5 of the top screen third. Pattern row 0 is
    // 0xF0 (left half set), colored white on dark blue for that row.
    vdp.vram[0x3800 + 1 * 32 + 2] = 5;
    vdp.vram[5 * 8 + 0] = 0xF0;
    vdp.vram[0x2000 + 5 * 8 + 0] = 0xF4; // fg 15 (white), bg 4 (dark blue)

    const s = try allocScene();
    defer testing.allocator.destroy(s);
    try testing.expect(extract(&vdp, s));

    try testing.expectEqual(@intFromEnum(scene.SystemKind.sg1000), s.system);
    try testing.expectEqual(@intFromEnum(scene.GraphicsMode.mode2_graphics2), s.mode);
    try testing.expect(s.contentValid());
    try testing.expectEqual(@as(u8, 32), s.columns);
    try testing.expectEqual(@as(u8, 24), s.rows);
    // TMS has no scrolling, so no per-line offsets and no HUD locks.
    try testing.expectEqual(@as(u16, 0), s.scroll_x);
    try testing.expectEqual(@as(u8, 0), s.hud_locked_rows);
    // The fixed TMS palette, with backdrop from register 7.
    try testing.expectEqual(SmsVdp.tms_palette[15], s.palette[15]);
    try testing.expectEqual(@as(u32, 0xFF000000), s.palette[16]);
    try testing.expectEqual(@as(u32, 0xFF000000), s.backdrop); // TMS color 1

    // Every cell maps to its own atlas slot: index = row * 32 + col.
    const c = s.cell(2, 1);
    try testing.expectEqual(@as(u16, 1 * 32 + 2), c.tile_index);
    try testing.expectEqual(@as(u8, 0), c.flags);

    const px = s.tilePixels(c.tile_index);
    try testing.expectEqual(@as(u8, 15), px[0]); // set bit: fg white
    try testing.expectEqual(@as(u8, 15), px[3]);
    try testing.expectEqual(@as(u8, 4), px[4]); // clear bit: bg dark blue
    try testing.expectEqual(@as(u8, 4), px[7]);
}

test "extract maps TMS color 0 to the opaque black palette entry" {
    var vdp = testTmsVdp();
    // Color byte 0x50: fg 5, bg 0. TMS color 0 renders as black, not as
    // the backdrop, so it cannot share atlas value 0 with transparency.
    vdp.vram[0x3800] = 1;
    vdp.vram[1 * 8] = 0xAA;
    vdp.vram[0x2000 + 1 * 8] = 0x50;

    const s = try allocScene();
    defer testing.allocator.destroy(s);
    try testing.expect(extract(&vdp, s));

    const px = s.tilePixels(0);
    try testing.expectEqual(@as(u8, 5), px[0]); // set bit: fg 5
    try testing.expectEqual(@as(u8, 16), px[1]); // clear bit: color 0 -> slot 16
}

test "extract describes TMS 8x8 sprites" {
    var vdp = testTmsVdp();
    // Sprite 0: y=40, x=100, pattern 3, color 6 with early clock.
    const sat = 0x3B00;
    vdp.vram[sat + 0] = 40;
    vdp.vram[sat + 1] = 100;
    vdp.vram[sat + 2] = 3;
    vdp.vram[sat + 3] = 0x80 | 6;
    vdp.vram[sat + 4] = 0xD0; // terminator
    vdp.vram[0x1800 + 3 * 8 + 0] = 0xC0; // top row: two left pixels

    const s = try allocScene();
    defer testing.allocator.destroy(s);
    try testing.expect(extract(&vdp, s));

    try testing.expectEqual(@as(u8, 1), s.sprite_count);
    const sp = s.sprites[0];
    try testing.expectEqual(@as(i16, 100 - 32), sp.x); // early clock shifts 32
    try testing.expectEqual(@as(i16, 41), sp.y); // hardware adds one
    try testing.expectEqual(@as(u16, 768), sp.tile_index); // sprite slots start at 768
    try testing.expectEqual(@as(u8, 8), sp.width);
    try testing.expectEqual(@as(u8, 8), sp.height);
    try testing.expectEqual(@as(u8, 0), sp.palette);

    const px = s.tilePixels(768);
    try testing.expectEqual(@as(u8, 6), px[0]);
    try testing.expectEqual(@as(u8, 6), px[1]);
    try testing.expectEqual(@as(u8, 0), px[2]); // clear bit: transparent
}

test "extract splits TMS 16x16 sprites into two tall scene sprites" {
    var vdp = testTmsVdp();
    vdp.regs[1] |= 0x02; // 16x16 sprites
    const sat = 0x3B00;
    vdp.vram[sat + 0] = 20;
    vdp.vram[sat + 1] = 50;
    vdp.vram[sat + 2] = 4; // masked to 4 (&0xFC)
    vdp.vram[sat + 3] = 9;
    vdp.vram[sat + 4] = 0xD0;
    // Distinct first bytes in each of the four 8x8 blocks.
    vdp.vram[0x1800 + 4 * 8 + 0] = 0x80; // left top
    vdp.vram[0x1800 + 4 * 8 + 8] = 0x80; // left bottom
    vdp.vram[0x1800 + 4 * 8 + 16] = 0x80; // right top
    vdp.vram[0x1800 + 4 * 8 + 24] = 0x80; // right bottom

    const s = try allocScene();
    defer testing.allocator.destroy(s);
    try testing.expect(extract(&vdp, s));

    try testing.expectEqual(@as(u8, 2), s.sprite_count);
    const left = s.sprites[0];
    const right = s.sprites[1];
    try testing.expectEqual(@as(i16, 50), left.x);
    try testing.expectEqual(@as(i16, 58), right.x);
    try testing.expectEqual(left.y, right.y);
    try testing.expectEqual(@as(u8, 8), left.width);
    try testing.expectEqual(@as(u8, 16), left.height);
    // Left half uses the slot pair (base, base + 1) so the renderer's
    // vertical tile continuation applies; right half uses (base+2, base+3).
    try testing.expectEqual(@as(u16, 768), left.tile_index);
    try testing.expectEqual(@as(u16, 770), right.tile_index);
    try testing.expectEqual(left.slot, right.slot);

    try testing.expectEqual(@as(u8, 9), s.tilePixels(768)[0]); // left top
    try testing.expectEqual(@as(u8, 9), s.tilePixels(769)[0]); // left bottom
    try testing.expectEqual(@as(u8, 9), s.tilePixels(770)[0]); // right top
    try testing.expectEqual(@as(u8, 9), s.tilePixels(771)[0]); // right bottom
}

test "extract leaves TMS emulation state byte-identical" {
    const before = try testing.allocator.create(SmsVdp);
    defer testing.allocator.destroy(before);
    const vdp = try testing.allocator.create(SmsVdp);
    defer testing.allocator.destroy(vdp);

    vdp.* = testTmsVdp();
    vdp.vram[0x3800] = 7;
    vdp.vram[0x3B00] = 0xD0;
    before.* = vdp.*;

    const s = try allocScene();
    defer testing.allocator.destroy(s);
    try testing.expect(extract(vdp, s));
    try testing.expect(std.mem.eql(u8, std.mem.asBytes(before), std.mem.asBytes(vdp)));
}
