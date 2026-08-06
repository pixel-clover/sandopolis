//! Frame scene extraction for the Master System VDP.
//!
//! Produces a `scene.FrameScene` describing the tilemap, sprites, palette,
//! and tile patterns the VDP would draw, for frontends that render the
//! picture as 3D geometry rather than as pixels.
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
        // The TMS9918 modes are not described yet. Report the header so a
        // frontend can tell what it is looking at, and leave the content
        // sections empty.
        out.flags = flags;
        out.columns = 0;
        out.rows = 0;
        out.scroll_x = 0;
        out.scroll_y = 0;
        out.tile_count = 0;
        out.sprite_count = 0;
        out.hud_locked_rows = 0;
        out.hud_locked_columns = 0;
        out.backdrop = 0;
        return false;
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

    extractCells(vdp, out);
    extractSprites(vdp, out);
    extractTiles(vdp, out);
    return true;
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

    var pixels: [scene.pixels_per_tile]u8 = undefined;
    for (0..scene.max_tiles) |tile| {
        decodePattern(vdp, @intCast(tile), &pixels);
        const dest = out.tile_atlas[tile * scene.pixels_per_tile ..][0..scene.pixels_per_tile];
        if (!std.mem.eql(u8, dest, &pixels)) {
            out.markTileDirty(tile);
            @memcpy(dest, &pixels);
        }
    }

    out.tile_count = @intCast(scene.max_tiles);
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
    try testing.expectEqual(@as(u16, scene.max_tiles), s.tile_count);
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

test "extract reports unsupported graphics modes without content" {
    var vdp = testVdp();
    vdp.is_sg1000 = true; // register 0 bit 2 is not Mode 4 on SG-1000
    vdp.regs[0] = 0x02; // M2 selects TMS9918 Graphics II

    const s = try allocScene();
    defer testing.allocator.destroy(s);

    try testing.expect(!extract(&vdp, s));
    try testing.expectEqual(scene.magic, s.magic);
    try testing.expectEqual(@intFromEnum(scene.SystemKind.sg1000), s.system);
    try testing.expectEqual(@intFromEnum(scene.GraphicsMode.mode2_graphics2), s.mode);
    try testing.expect(!s.contentValid());
    try testing.expectEqual(@as(u8, 0), s.sprite_count);
}
