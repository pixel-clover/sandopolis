const std = @import("std");

/// GIF89a encoder for Genesis framebuffer capture.
/// Writes frames as a GIF animation with LZW compression.
pub const GifRecorder = struct {
    file: std.fs.File,
    frame_count: u32,
    prev_palette: [64]u32,
    delay_cs: u16, // Frame delay in centiseconds

    const width = 320;
    const height = 224;
    const max_colors: u16 = 256;
    const color_depth: u3 = 7; // 2^(7+1) = 256 colors
    const min_code_size: u8 = 8; // For 256-color palette

    pub fn start(path: []const u8, fps: u16) !GifRecorder {
        const file = try std.fs.cwd().createFile(path, .{});
        errdefer file.close();

        // GIF89a header
        try file.writeAll("GIF89a");

        // Logical screen descriptor
        try writeU16(file, @intCast(width));
        try writeU16(file, @intCast(height));
        // Global color table: yes, color_depth bits, not sorted, 256 entries
        try file.writeAll(&.{0x80 | (@as(u8, color_depth) << 4) | color_depth});
        try file.writeAll(&.{0}); // Background color index
        try file.writeAll(&.{0}); // Pixel aspect ratio

        // Write a placeholder global color table (256 * 3 bytes, all black)
        const zeros = [_]u8{0} ** 768;
        try file.writeAll(&zeros);

        // Netscape looping extension (loop forever)
        try file.writeAll(&.{ 0x21, 0xFF, 0x0B }); // Application extension
        try file.writeAll("NETSCAPE2.0");
        try file.writeAll(&.{ 0x03, 0x01, 0x00, 0x00, 0x00 }); // Loop count = 0 (infinite)

        // Compute delay: centiseconds per frame
        const delay_cs: u16 = if (fps > 0) @intCast(@min(65535, (100 + fps / 2) / fps)) else 2;

        return .{
            .file = file,
            .frame_count = 0,
            .prev_palette = [_]u32{0} ** 64,
            .delay_cs = delay_cs,
        };
    }

    pub fn addFrame(self: *GifRecorder, framebuffer: *const [width * height]u32) !void {
        const file = self.file;

        // Build local palette from unique colors in this frame
        var palette: [max_colors]u32 = [_]u32{0} ** max_colors;
        var palette_size: u16 = 0;

        // Index buffer for this frame
        var indices: [width * height]u8 = undefined;

        for (framebuffer, 0..) |pixel, i| {
            const color = pixel & 0x00FFFFFF; // Strip alpha
            const idx = findOrAdd(&palette, &palette_size, color);
            indices[i] = idx;
        }

        // Graphic control extension (for frame delay and disposal)
        try file.writeAll(&.{ 0x21, 0xF9, 0x04 });
        try file.writeAll(&.{0x00}); // Disposal: none, no transparency
        try writeU16(file, self.delay_cs);
        try file.writeAll(&.{0}); // Transparent color index (unused)
        try file.writeAll(&.{0}); // Block terminator

        // Image descriptor
        try file.writeAll(&.{0x2C}); // Image separator
        try writeU16(file, 0); // Left
        try writeU16(file, 0); // Top
        try writeU16(file, @intCast(width));
        try writeU16(file, @intCast(height));
        // Local color table, 256 entries
        try file.writeAll(&.{0x80 | @as(u8, color_depth)});

        // Write local color table
        var color_table: [max_colors * 3]u8 = undefined;
        for (0..max_colors) |ci| {
            const c = palette[ci];
            color_table[ci * 3 + 0] = @intCast((c >> 16) & 0xFF); // R
            color_table[ci * 3 + 1] = @intCast((c >> 8) & 0xFF); // G
            color_table[ci * 3 + 2] = @intCast(c & 0xFF); // B
        }
        try file.writeAll(&color_table);

        // LZW-compressed image data
        try file.writeAll(&.{min_code_size});
        try lzwCompress(file, &indices);
        try file.writeAll(&.{0x00}); // Block terminator

        self.frame_count += 1;
    }

    pub fn finish(self: *GifRecorder) void {
        self.file.writeAll(&.{0x3B}) catch {}; // GIF trailer
        self.file.close();
    }

    fn writeU16(file: std.fs.File, value: u16) !void {
        const bytes = [2]u8{ @truncate(value), @truncate(value >> 8) };
        try file.writeAll(&bytes);
    }

    fn findOrAdd(palette: *[max_colors]u32, size: *u16, color: u32) u8 {
        for (0..size.*) |i| {
            if (palette[i] == color) return @intCast(i);
        }
        if (size.* < max_colors) {
            palette[size.*] = color;
            size.* += 1;
            return @intCast(size.* - 1);
        }
        // Palette full — find nearest color
        return findNearest(palette, color);
    }

    fn findNearest(palette: *const [max_colors]u32, color: u32) u8 {
        const r: i32 = @intCast((color >> 16) & 0xFF);
        const g: i32 = @intCast((color >> 8) & 0xFF);
        const b: i32 = @intCast(color & 0xFF);
        var best_idx: u8 = 0;
        var best_dist: i32 = std.math.maxInt(i32);
        for (0..max_colors) |i| {
            const pr: i32 = @intCast((palette[i] >> 16) & 0xFF);
            const pg: i32 = @intCast((palette[i] >> 8) & 0xFF);
            const pb: i32 = @intCast(palette[i] & 0xFF);
            const dr = r - pr;
            const dg = g - pg;
            const db = b - pb;
            const dist = dr * dr + dg * dg + db * db;
            if (dist < best_dist) {
                best_dist = dist;
                best_idx = @intCast(i);
            }
        }
        return best_idx;
    }
};

/// LZW compression for GIF image data.
/// Uses variable-width codes with sub-block output (max 255 bytes per sub-block).
fn lzwCompress(file: std.fs.File, data: *const [320 * 224]u8) !void {
    const clear_code: u16 = 256;
    const eoi_code: u16 = 257;
    const first_code: u16 = 258;
    const max_code_value: u16 = 4095;

    // LZW table: for each code, store (prefix_code, suffix_byte).
    const TableEntry = struct { prefix: u16, suffix: u8 };
    var table: [4096]TableEntry = undefined;
    var table_size: u16 = first_code;
    var code_size: u4 = 9; // Start with 9-bit codes (min_code_size + 1)

    // Bit packing buffer
    var bit_buf: u32 = 0;
    var bit_count: u5 = 0;
    var block_buf: [255]u8 = undefined;
    var block_len: u8 = 0;

    // Emit clear code
    try emitCode(file, clear_code, code_size, &bit_buf, &bit_count, &block_buf, &block_len);

    var prefix: u16 = data[0];
    for (data[1..]) |byte| {
        // Search table for (prefix, byte)
        const found = blk: {
            for (first_code..table_size) |i| {
                if (table[i].prefix == prefix and table[i].suffix == byte) {
                    break :blk @as(u16, @intCast(i));
                }
            }
            break :blk null;
        };

        if (found) |code| {
            prefix = code;
        } else {
            // Output prefix code
            try emitCode(file, prefix, code_size, &bit_buf, &bit_count, &block_buf, &block_len);

            // Add new entry if table not full
            if (table_size <= max_code_value) {
                table[table_size] = .{ .prefix = prefix, .suffix = byte };
                table_size += 1;

                // Increase code size when needed
                if (table_size > (@as(u16, 1) << code_size) and code_size < 12) {
                    code_size += 1;
                }
            } else {
                // Table full — emit clear and reset
                try emitCode(file, clear_code, code_size, &bit_buf, &bit_count, &block_buf, &block_len);
                table_size = first_code;
                code_size = 9;
            }

            prefix = byte;
        }
    }

    // Output final prefix
    try emitCode(file, prefix, code_size, &bit_buf, &bit_count, &block_buf, &block_len);
    // End of information
    try emitCode(file, eoi_code, code_size, &bit_buf, &bit_count, &block_buf, &block_len);

    // Flush remaining bits
    if (bit_count > 0) {
        block_buf[block_len] = @truncate(bit_buf);
        block_len += 1;
    }
    if (block_len > 0) {
        try file.writeAll(&.{block_len});
        try file.writeAll(block_buf[0..block_len]);
    }
}

fn emitCode(
    file: std.fs.File,
    code: u16,
    cs: u4,
    bb: *u32,
    bc: *u5,
    blk: *[255]u8,
    bl: *u8,
) !void {
    bb.* |= @as(u32, code) << bc.*;
    bc.* +%= cs;
    while (bc.* >= 8) {
        blk[bl.*] = @truncate(bb.*);
        bl.* += 1;
        if (bl.* == 255) {
            try file.writeAll(&.{255});
            try file.writeAll(blk);
            bl.* = 0;
        }
        bb.* >>= 8;
        bc.* -%= 8;
    }
}

test "GIF recorder creates valid single-frame GIF" {
    var framebuffer: [320 * 224]u32 = undefined;
    // Fill with a simple gradient pattern
    for (0..224) |y| {
        for (0..320) |x| {
            const r: u32 = @intCast(x * 255 / 319);
            const g: u32 = @intCast(y * 255 / 223);
            framebuffer[y * 320 + x] = 0xFF000000 | (r << 16) | (g << 8) | 0x80;
        }
    }

    const tmp_path = "test_output.gif";
    var recorder = try GifRecorder.start(tmp_path, 60);
    try recorder.addFrame(&framebuffer);
    recorder.finish();

    // Verify file starts with GIF89a
    const file = try std.fs.cwd().openFile(tmp_path, .{});
    defer file.close();
    var header: [6]u8 = undefined;
    _ = try file.readAll(&header);
    try std.testing.expectEqualStrings("GIF89a", &header);

    // Clean up
    try std.fs.cwd().deleteFile(tmp_path);
}
