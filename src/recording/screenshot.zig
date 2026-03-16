const std = @import("std");

/// Save framebuffer as BMP file
/// framebuffer format: XRGB8888 (u32 per pixel, 0x00RRGGBB)
pub fn saveBmp(path: []const u8, framebuffer: []const u32, width: u32, height: u32) !void {
    if (framebuffer.len != width * height) return error.InvalidFrameSize;

    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();

    var buffer: [4096]u8 = undefined;
    var file_writer = file.writer(&buffer);
    const writer = &file_writer.interface;

    // BMP row size must be multiple of 4 bytes
    const row_size = width * 3;
    const row_padding = (4 - (row_size % 4)) % 4;
    const padded_row_size = row_size + row_padding;
    const pixel_data_size = padded_row_size * height;
    const file_size = 54 + pixel_data_size;

    // BMP File Header (14 bytes)
    try writer.writeAll("BM"); // Signature
    try writer.writeInt(u32, @intCast(file_size), .little); // File size
    try writer.writeInt(u16, 0, .little); // Reserved
    try writer.writeInt(u16, 0, .little); // Reserved
    try writer.writeInt(u32, 54, .little); // Pixel data offset

    // DIB Header (BITMAPINFOHEADER - 40 bytes)
    try writer.writeInt(u32, 40, .little); // Header size
    try writer.writeInt(i32, @intCast(width), .little); // Width
    try writer.writeInt(i32, @intCast(height), .little); // Height (positive = bottom-up)
    try writer.writeInt(u16, 1, .little); // Color planes
    try writer.writeInt(u16, 24, .little); // Bits per pixel
    try writer.writeInt(u32, 0, .little); // Compression (none)
    try writer.writeInt(u32, @intCast(pixel_data_size), .little); // Image size
    try writer.writeInt(i32, 2835, .little); // Horizontal resolution (72 DPI)
    try writer.writeInt(i32, 2835, .little); // Vertical resolution (72 DPI)
    try writer.writeInt(u32, 0, .little); // Colors in palette
    try writer.writeInt(u32, 0, .little); // Important colors

    // Pixel data (bottom-up, BGR order)
    const padding_bytes = [_]u8{ 0, 0, 0 };
    var y: usize = height;
    while (y > 0) {
        y -= 1;
        const row_start = y * width;
        for (0..width) |x| {
            const pixel = framebuffer[row_start + x];
            const r: u8 = @truncate((pixel >> 16) & 0xFF);
            const g: u8 = @truncate((pixel >> 8) & 0xFF);
            const b: u8 = @truncate(pixel & 0xFF);
            try writer.writeAll(&[_]u8{ b, g, r });
        }
        if (row_padding > 0) {
            try writer.writeAll(padding_bytes[0..row_padding]);
        }
    }
    try writer.flush();
}

test "bmp file has correct header structure" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);
    const path = try std.fs.path.join(allocator, &.{ dir_path, "test.bmp" });
    defer allocator.free(path);

    // Create a small test image (4x2 pixels)
    const pixels = [_]u32{
        0x00FF0000, 0x0000FF00, 0x000000FF, 0x00FFFFFF, // Row 0: red, green, blue, white
        0x00000000, 0x00808080, 0x00FFFF00, 0x00FF00FF, // Row 1: black, gray, yellow, magenta
    };

    try saveBmp(path, &pixels, 4, 2);

    // Read and verify the file
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    var header: [54]u8 = undefined;
    _ = try file.readAll(&header);

    // Check BMP signature
    try std.testing.expectEqualSlices(u8, "BM", header[0..2]);

    // Check file size (54 header + 2 rows * 12 bytes per row (4 pixels * 3 bytes))
    // Row size = 12, padded to 12 (already multiple of 4)
    const file_size = std.mem.readInt(u32, header[2..6], .little);
    try std.testing.expectEqual(@as(u32, 54 + 24), file_size);

    // Check width and height
    const width = std.mem.readInt(i32, header[18..22], .little);
    const height = std.mem.readInt(i32, header[22..26], .little);
    try std.testing.expectEqual(@as(i32, 4), width);
    try std.testing.expectEqual(@as(i32, 2), height);

    // Check bits per pixel
    const bpp = std.mem.readInt(u16, header[28..30], .little);
    try std.testing.expectEqual(@as(u16, 24), bpp);
}

test "bmp pixel data is correct" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);
    const path = try std.fs.path.join(allocator, &.{ dir_path, "test2.bmp" });
    defer allocator.free(path);

    // Single red pixel
    const pixels = [_]u32{0x00FF0000};
    try saveBmp(path, &pixels, 1, 1);

    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    // Skip header, read pixel data
    try file.seekTo(54);
    var pixel_data: [4]u8 = undefined; // 3 bytes + 1 padding (row must be multiple of 4)
    _ = try file.readAll(&pixel_data);

    // BMP stores as BGR
    try std.testing.expectEqual(@as(u8, 0x00), pixel_data[0]); // B
    try std.testing.expectEqual(@as(u8, 0x00), pixel_data[1]); // G
    try std.testing.expectEqual(@as(u8, 0xFF), pixel_data[2]); // R
}
