const std = @import("std");
const zsdl3 = @import("zsdl3");

const stbtt = @cImport({
    @cInclude("./fonts/stb_truetype.h");
});

pub const font_jbm_regular = @embedFile("fonts/ttf/JetBrainsMono-Regular.ttf");
pub const font_jbm_light = @embedFile("fonts/ttf/JetBrainsMono-Light.ttf");
pub const font_jbm_medium = @embedFile("fonts/ttf/JetBrainsMono-Medium.ttf");
pub const font_jbm_thin = @embedFile("fonts/ttf/JetBrainsMono-Thin.ttf");

/// Printable ASCII range we cache (space through tilde).
const first_char: u8 = 32;
const char_count: u16 = 95; // 32..126 inclusive

/// Maximum font pixel height we'll rasterize.
const max_pixel_height = 64;
/// Minimum font pixel height.
const min_pixel_height = 8;

/// Pre-rasterized glyph info for one character.
const Glyph = struct {
    x: u16, // atlas x offset in pixels
    advance: f32, // horizontal advance
    lsb: f32, // left side bearing
    y_offset: f32, // vertical offset from baseline
    width: u16,
    height: u16,
};

/// Cached font atlas for a specific pixel size.
pub const FontAtlas = struct {
    texture: *zsdl3.Texture,
    glyphs: [char_count]Glyph,
    pixel_height: u16,
    ascent: f32,
    /// Total line height including spacing.
    line_height: f32,

    pub fn deinit(self: *FontAtlas) void {
        zsdl3.destroyTexture(self.texture);
    }
};

/// Persistent font state — call init() once, then getAtlas() per frame.
pub const Font = struct {
    info: ?stbtt.stbtt_fontinfo = null,
    atlas: ?FontAtlas = null,
    valid: bool = false,

    pub fn init(data: []const u8) Font {
        var info: stbtt.stbtt_fontinfo = undefined;
        const ok = stbtt.stbtt_InitFont(&info, @ptrCast(data.ptr), 0);
        if (ok == 0) {
            std.debug.print("Warning: Font file is invalid or corrupted. Text rendering will be unavailable.\n", .{});
            return .{ .info = null, .valid = false };
        }
        return .{ .info = info, .valid = true };
    }

    pub fn deinit(self: *Font) void {
        if (self.atlas) |*a| a.deinit();
    }

    /// Get (or rebuild) the atlas for the given pixel height. Returns null if font is not initialized.
    pub fn getAtlas(self: *Font, renderer: *zsdl3.Renderer, pixel_height: u16) !?*const FontAtlas {
        if (!self.valid or self.info == null) return null;
        const ph = std.math.clamp(pixel_height, min_pixel_height, max_pixel_height);
        if (self.atlas) |*a| {
            if (a.pixel_height == ph) return a;
            a.deinit();
            self.atlas = null;
        }
        self.atlas = try buildAtlas(&self.info.?, renderer, ph);
        return &self.atlas.?;
    }
};

fn buildAtlas(
    info: *const stbtt.stbtt_fontinfo,
    renderer: *zsdl3.Renderer,
    pixel_height: u16,
) !FontAtlas {
    const scale = stbtt.stbtt_ScaleForPixelHeight(info, @floatFromInt(pixel_height));

    var ascent_raw: c_int = undefined;
    var descent_raw: c_int = undefined;
    var line_gap_raw: c_int = undefined;
    stbtt.stbtt_GetFontVMetrics(info, &ascent_raw, &descent_raw, &line_gap_raw);
    const ascent = @as(f32, @floatFromInt(ascent_raw)) * scale;
    const line_height = (@as(f32, @floatFromInt(ascent_raw - descent_raw + line_gap_raw)) * scale);

    // First pass: measure total atlas width
    var glyphs: [char_count]Glyph = undefined;
    var atlas_width: u32 = 0;
    var atlas_height: u32 = 0;

    for (0..char_count) |i| {
        const ch: u8 = first_char + @as(u8, @intCast(i));
        const glyph_index = stbtt.stbtt_FindGlyphIndex(info, ch);

        var advance_raw: c_int = undefined;
        var lsb_raw: c_int = undefined;
        stbtt.stbtt_GetGlyphHMetrics(info, glyph_index, &advance_raw, &lsb_raw);

        var x0: c_int = undefined;
        var y0: c_int = undefined;
        var x1: c_int = undefined;
        var y1: c_int = undefined;
        stbtt.stbtt_GetGlyphBitmapBox(info, glyph_index, scale, scale, &x0, &y0, &x1, &y1);

        const w: u32 = @intCast(@max(0, x1 - x0));
        const h: u32 = @intCast(@max(0, y1 - y0));

        glyphs[i] = .{
            .x = @intCast(atlas_width),
            .advance = @as(f32, @floatFromInt(advance_raw)) * scale,
            .lsb = @as(f32, @floatFromInt(lsb_raw)) * scale,
            .y_offset = @as(f32, @floatFromInt(y0)),
            .width = @intCast(w),
            .height = @intCast(h),
        };

        atlas_width += w + 1; // 1px gap between glyphs
        atlas_height = @max(atlas_height, h);
    }

    if (atlas_width == 0) atlas_width = 1;
    if (atlas_height == 0) atlas_height = 1;

    // Rasterize all glyphs into a single alpha bitmap
    const bitmap = try std.heap.c_allocator.alloc(u8, atlas_width * atlas_height);
    defer std.heap.c_allocator.free(bitmap);
    @memset(bitmap, 0);

    for (0..char_count) |i| {
        const g = glyphs[i];
        if (g.width == 0 or g.height == 0) continue;
        const ch: u8 = first_char + @as(u8, @intCast(i));
        const glyph_index = stbtt.stbtt_FindGlyphIndex(info, ch);
        stbtt.stbtt_MakeGlyphBitmap(
            info,
            bitmap.ptr + g.x,
            g.width,
            g.height,
            @intCast(atlas_width),
            scale,
            scale,
            glyph_index,
        );
    }

    // Convert alpha bitmap to ARGB8888 for SDL texture
    const rgba = try std.heap.c_allocator.alloc(u8, atlas_width * atlas_height * 4);
    defer std.heap.c_allocator.free(rgba);

    for (0..atlas_width * atlas_height) |j| {
        const a = bitmap[j];
        // ARGB8888: A in high byte, then R, G, B
        rgba[j * 4 + 0] = 0xFF; // B
        rgba[j * 4 + 1] = 0xFF; // G
        rgba[j * 4 + 2] = 0xFF; // R
        rgba[j * 4 + 3] = a; // A
    }

    const texture = try zsdl3.createTexture(
        renderer,
        .argb8888,
        .static,
        @intCast(atlas_width),
        @intCast(atlas_height),
    );
    if (!SDL_UpdateTexture(texture, null, rgba.ptr, @intCast(atlas_width * 4))) {
        zsdl3.destroyTexture(texture);
        return error.SdlTextureUpdateFailed;
    }

    return .{
        .texture = texture,
        .glyphs = glyphs,
        .pixel_height = pixel_height,
        .ascent = ascent,
        .line_height = line_height,
    };
}

/// Calculate text width in pixels for the given atlas.
pub fn textWidth(atlas: *const FontAtlas, text: []const u8) f32 {
    var w: f32 = 0;
    for (text) |ch| {
        if (ch >= first_char and ch <= first_char + char_count - 1) {
            w += atlas.glyphs[ch - first_char].advance;
        }
    }
    return w;
}

/// Draw text at the given position using the cached atlas.
pub fn drawText(
    renderer: *zsdl3.Renderer,
    atlas: *const FontAtlas,
    x: f32,
    y: f32,
    color: zsdl3.Color,
    text: []const u8,
) !void {
    try setTextureColorMod(atlas.texture, color.r, color.g, color.b);
    try setTextureAlphaMod(atlas.texture, color.a);

    var cursor = x;
    for (text) |ch| {
        if (ch < first_char or ch > first_char + char_count - 1) continue;
        const g = atlas.glyphs[ch - first_char];
        if (g.width > 0 and g.height > 0) {
            const src = zsdl3.FRect{
                .x = @floatFromInt(g.x),
                .y = 0,
                .w = @floatFromInt(g.width),
                .h = @floatFromInt(g.height),
            };
            const dst = zsdl3.FRect{
                .x = cursor + g.lsb,
                .y = y + atlas.ascent + g.y_offset,
                .w = @floatFromInt(g.width),
                .h = @floatFromInt(g.height),
            };
            try zsdl3.renderTexture(renderer, atlas.texture, &src, &dst);
        }
        cursor += g.advance;
    }
}

fn setTextureColorMod(texture: *zsdl3.Texture, r: u8, g: u8, b: u8) !void {
    if (!SDL_SetTextureColorMod(texture, r, g, b)) {
        return error.SdlTextureColorModFailed;
    }
}

fn setTextureAlphaMod(texture: *zsdl3.Texture, alpha: u8) !void {
    if (!SDL_SetTextureAlphaMod(texture, alpha)) {
        return error.SdlTextureAlphaModFailed;
    }
}

extern fn SDL_UpdateTexture(texture: *zsdl3.Texture, rect: ?*const zsdl3.Rect, pixels: ?*const anyopaque, pitch: c_int) bool;
extern fn SDL_SetTextureColorMod(texture: *zsdl3.Texture, r: u8, g: u8, b: u8) bool;
extern fn SDL_SetTextureAlphaMod(texture: *zsdl3.Texture, alpha: u8) bool;
