//! Portable frame scene description.
//!
//! A `FrameScene` is a snapshot of what a VDP would draw for one frame,
//! expressed as tile, sprite, and palette references instead of pixels.
//! Frontends that render the picture as 3D geometry consume this in place of
//! the framebuffer, so the core never needs to know about a graphics API.
//!
//! Extraction is a read-only observation of VDP state. It must not change
//! emulation behavior, so extractors take a `*const` VDP and never touch
//! rasterizer side effects such as the sprite overflow and collision status
//! bits.
//!
//! The layout is `extern` and stable so that a WebAssembly frontend can read
//! it directly out of linear memory. `layout_version` changes whenever field
//! offsets move.

const std = @import("std");

/// Identifies a scene buffer in memory ("SCNS", little-endian).
pub const magic: u32 = 0x534E4353;

/// Bumped whenever the binary layout changes.
pub const layout_version: u32 = 1;

pub const max_columns: usize = 32;
pub const max_rows: usize = 32;
pub const max_cells: usize = max_columns * max_rows;
pub const max_sprites: usize = 64;
pub const max_palette: usize = 32;

/// Tile atlas size. Master System Mode 4 addresses 512 patterns of 8x8
/// pixels, which is the whole 16KB of VRAM.
pub const max_tiles: usize = 512;
pub const tile_width: usize = 8;
pub const tile_height: usize = 8;
pub const pixels_per_tile: usize = tile_width * tile_height;
pub const tile_atlas_bytes: usize = max_tiles * pixels_per_tile;
pub const tile_dirty_bytes: usize = max_tiles / 8;

pub const SystemKind = enum(u8) {
    sms = 0,
    game_gear = 1,
    sg1000 = 2,
    genesis = 3,
};

pub const GraphicsMode = enum(u8) {
    mode4 = 0,
    mode0_text = 1,
    mode1_graphics1 = 2,
    mode2_graphics2 = 3,
    mode3_multicolor = 4,
};

pub const cell_flag_h_flip: u8 = 1 << 0;
pub const cell_flag_v_flip: u8 = 1 << 1;
/// Cell draws in front of sprites.
pub const cell_flag_priority: u8 = 1 << 2;

/// One background tilemap entry.
pub const Cell = extern struct {
    /// Index into the tile atlas.
    tile_index: u16 = 0,
    /// Palette bank, as a multiple of 16 entries.
    palette: u8 = 0,
    flags: u8 = 0,
};

pub const sprite_flag_h_flip: u8 = 1 << 0;
pub const sprite_flag_v_flip: u8 = 1 << 1;
pub const sprite_flag_priority: u8 = 1 << 2;
/// Sprite is drawn at double size by the hardware zoom bit.
pub const sprite_flag_doubled: u8 = 1 << 3;

/// One visible sprite.
///
/// `slot` is the hardware sprite table index. Most games keep a given game
/// object in a stable slot across frames, so it is the identity hint a
/// profile-driven frontend uses to attach a persistent 3D model.
pub const Sprite = extern struct {
    /// Left edge in screen pixels. Negative means partially off the left edge.
    x: i16 = 0,
    /// Top edge in screen pixels.
    y: i16 = 0,
    /// Index into the tile atlas of the sprite's first pattern.
    tile_index: u16 = 0,
    slot: u8 = 0,
    palette: u8 = 0,
    /// On-screen size in pixels, after any hardware zoom.
    width: u8 = 0,
    height: u8 = 0,
    flags: u8 = 0,
    reserved: u8 = 0,
};

/// Display output is enabled. When clear, the hardware shows only the
/// backdrop color and the tilemap is not drawn.
pub const scene_flag_display_enabled: u32 = 1 << 0;
/// Leftmost 8 pixels are forced to the backdrop color.
pub const scene_flag_left_column_blanked: u32 = 1 << 1;
/// The extractor understood the current graphics mode and filled in the
/// tilemap, sprite, palette, and tile atlas sections.
pub const scene_flag_content_valid: u32 = 1 << 2;

pub const FrameScene = extern struct {
    magic: u32 = 0,
    version: u32 = 0,

    /// `SystemKind`
    system: u8 = 0,
    /// `GraphicsMode`
    mode: u8 = 0,
    columns: u8 = 0,
    rows: u8 = 0,

    /// Size of the picture the tilemap and sprites are laid out in. Sprite
    /// and scroll coordinates are relative to this, not to the viewport.
    picture_width: u16 = 0,
    picture_height: u16 = 0,

    /// Region of the picture the display actually shows. This is the whole
    /// picture on Master System, and the 160x144 window on Game Gear.
    viewport_x: u16 = 0,
    viewport_y: u16 = 0,
    viewport_width: u16 = 0,
    viewport_height: u16 = 0,

    /// Frame-level playfield scroll. Per-scanline horizontal scroll is not
    /// captured yet, so parallax raster effects collapse to one offset.
    scroll_x: u16 = 0,
    scroll_y: u16 = 0,

    /// Number of entries populated in `tile_atlas`.
    tile_count: u16 = 0,
    /// Number of entries populated in `sprites`.
    sprite_count: u8 = 0,

    /// Rows at the top of the screen that the hardware locked against
    /// horizontal scrolling. Games use this for status displays, so a 3D
    /// frontend can keep the region flat instead of extruding it.
    hud_locked_rows: u8 = 0,
    /// Columns at the right of the screen locked against vertical scrolling.
    hud_locked_columns: u8 = 0,

    reserved0: u8 = 0,
    reserved1: u16 = 0,

    flags: u32 = 0,
    /// Backdrop color as 0xAARRGGBB.
    backdrop: u32 = 0,

    /// Palette as 0xAARRGGBB. Entry 0 of each 16-entry bank is transparent
    /// for tile pixels but is a real color when used as the backdrop.
    palette: [max_palette]u32 = [_]u32{0} ** max_palette,

    /// Row-major tilemap, `columns` wide and `rows` tall.
    cells: [max_cells]Cell = [_]Cell{.{}} ** max_cells,

    sprites: [max_sprites]Sprite = [_]Sprite{.{}} ** max_sprites,

    /// One bit per tile, set when the tile's pixels changed since the
    /// previous extraction into this same buffer. Lets a frontend re-upload
    /// only the tiles that moved.
    tile_dirty: [tile_dirty_bytes]u8 = [_]u8{0} ** tile_dirty_bytes,

    /// Tile atlas as palette indices in 0..15, 64 bytes per tile, row-major.
    /// Index 0 is transparent. The palette bank comes from the referencing
    /// cell or sprite, not from the atlas.
    tile_atlas: [tile_atlas_bytes]u8 = [_]u8{0} ** tile_atlas_bytes,

    pub fn cell(self: *const FrameScene, col: usize, row: usize) Cell {
        return self.cells[row * max_columns + col];
    }

    pub fn tilePixels(self: *const FrameScene, index: usize) []const u8 {
        return self.tile_atlas[index * pixels_per_tile ..][0..pixels_per_tile];
    }

    pub fn tileIsDirty(self: *const FrameScene, index: usize) bool {
        return (self.tile_dirty[index / 8] >> @intCast(index % 8)) & 1 != 0;
    }

    pub fn markTileDirty(self: *FrameScene, index: usize) void {
        self.tile_dirty[index / 8] |= @as(u8, 1) << @intCast(index % 8);
    }

    pub fn contentValid(self: *const FrameScene) bool {
        return self.flags & scene_flag_content_valid != 0;
    }
};

test "scene buffer layout is stable for external readers" {
    const testing = std.testing;
    // These offsets are a binary contract with the WebAssembly frontend.
    // Changing them requires bumping `layout_version`.
    try testing.expectEqual(@as(usize, 0), @offsetOf(FrameScene, "magic"));
    try testing.expectEqual(@as(usize, 4), @offsetOf(FrameScene, "version"));
    try testing.expectEqual(@as(usize, 8), @offsetOf(FrameScene, "system"));
    try testing.expectEqual(@as(usize, 12), @offsetOf(FrameScene, "picture_width"));
    try testing.expectEqual(@as(usize, 16), @offsetOf(FrameScene, "viewport_x"));
    try testing.expectEqual(@as(usize, 24), @offsetOf(FrameScene, "scroll_x"));
    try testing.expectEqual(@as(usize, 36), @offsetOf(FrameScene, "flags"));
    try testing.expectEqual(@as(usize, 40), @offsetOf(FrameScene, "backdrop"));
    try testing.expectEqual(@as(usize, 44), @offsetOf(FrameScene, "palette"));
    try testing.expectEqual(@as(usize, 172), @offsetOf(FrameScene, "cells"));
    try testing.expectEqual(@as(usize, 4268), @offsetOf(FrameScene, "sprites"));
    try testing.expectEqual(@as(usize, 5036), @offsetOf(FrameScene, "tile_dirty"));
    try testing.expectEqual(@as(usize, 5100), @offsetOf(FrameScene, "tile_atlas"));
    try testing.expectEqual(@as(usize, 37868), @sizeOf(FrameScene));

    try testing.expectEqual(@as(usize, 4), @sizeOf(Cell));
    try testing.expectEqual(@as(usize, 12), @sizeOf(Sprite));
}

test "tile dirty bits round-trip" {
    const testing = std.testing;
    var s = FrameScene{};
    try testing.expect(!s.tileIsDirty(0));
    try testing.expect(!s.tileIsDirty(511));
    s.markTileDirty(0);
    s.markTileDirty(511);
    s.markTileDirty(37);
    try testing.expect(s.tileIsDirty(0));
    try testing.expect(s.tileIsDirty(511));
    try testing.expect(s.tileIsDirty(37));
    try testing.expect(!s.tileIsDirty(36));
    try testing.expect(!s.tileIsDirty(38));
}
