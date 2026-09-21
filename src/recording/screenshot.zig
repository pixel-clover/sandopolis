const std = @import("std");
const platform = @import("../platform.zig");

/// Save framebuffer as BMP file
/// framebuffer format: XRGB8888 (u32 per pixel, 0x00RRGGBB)
/// `stride` is the row pitch of `framebuffer` in pixels (>= width).
pub fn saveBmp(path: []const u8, framebuffer: []const u32, width: u32, height: u32, stride: u32) !void {
    if (width == 0 or height == 0 or stride < width) return error.InvalidFrameSize;
    // Widened arithmetic: caller-supplied dimensions must not overflow u32.
    if (@as(u64, width) * height > 1 << 26) return error.InvalidFrameSize;
    if (framebuffer.len < @as(usize, stride) * (height - 1) + width) return error.InvalidFrameSize;

    const file = try platform.cwd().createFile(path, .{});
    defer file.close();

    var buffer: [4096]u8 = undefined;
    var file_writer = file.writer(&buffer);
    const writer = &file_writer.interface;

    const row_size = width * 3;
    const row_padding = (4 - (row_size % 4)) % 4;
    const padded_row_size = row_size + row_padding;
    const pixel_data_size = padded_row_size * height;
    const file_size = 54 + pixel_data_size;

    try writer.writeAll("BM");
    try writer.writeInt(u32, @intCast(file_size), .little);
    try writer.writeInt(u16, 0, .little);
    try writer.writeInt(u16, 0, .little);
    try writer.writeInt(u32, 54, .little);

    try writer.writeInt(u32, 40, .little);
    try writer.writeInt(i32, @intCast(width), .little);
    try writer.writeInt(i32, @intCast(height), .little);
    try writer.writeInt(u16, 1, .little);
    try writer.writeInt(u16, 24, .little);
    try writer.writeInt(u32, 0, .little);
    try writer.writeInt(u32, @intCast(pixel_data_size), .little);
    try writer.writeInt(i32, 2835, .little);
    try writer.writeInt(i32, 2835, .little);
    try writer.writeInt(u32, 0, .little);
    try writer.writeInt(u32, 0, .little);

    const padding_bytes = [_]u8{ 0, 0, 0 };
    var y: usize = height;
    while (y > 0) {
        y -= 1;
        const row_start = y * stride;
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

    const dir_path = try (platform.Dir{ .d = tmp.dir }).realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);
    const path = try std.fs.path.join(allocator, &.{ dir_path, "test.bmp" });
    defer allocator.free(path);

    const pixels = [_]u32{
        0x00FF0000, 0x0000FF00, 0x000000FF, 0x00FFFFFF,
        0x00000000, 0x00808080, 0x00FFFF00, 0x00FF00FF,
    };

    try saveBmp(path, &pixels, 4, 2, 4);

    const file = try platform.cwd().openFile(path, .{});
    defer file.close();

    var header: [54]u8 = undefined;
    _ = try file.readAll(&header);

    try std.testing.expectEqualSlices(u8, "BM", header[0..2]);

    const file_size = std.mem.readInt(u32, header[2..6], .little);
    try std.testing.expectEqual(@as(u32, 54 + 24), file_size);

    const width = std.mem.readInt(i32, header[18..22], .little);
    const height = std.mem.readInt(i32, header[22..26], .little);
    try std.testing.expectEqual(@as(i32, 4), width);
    try std.testing.expectEqual(@as(i32, 2), height);

    const bpp = std.mem.readInt(u16, header[28..30], .little);
    try std.testing.expectEqual(@as(u16, 24), bpp);
}

test "bmp pixel data is correct" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try (platform.Dir{ .d = tmp.dir }).realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);
    const path = try std.fs.path.join(allocator, &.{ dir_path, "test2.bmp" });
    defer allocator.free(path);

    const pixels = [_]u32{0x00FF0000};
    try saveBmp(path, &pixels, 1, 1, 1);

    const file = try platform.cwd().openFile(path, .{});
    defer file.close();

    try file.seekTo(54);
    var pixel_data: [4]u8 = undefined;
    _ = try file.readAll(&pixel_data);

    try std.testing.expectEqual(@as(u8, 0x00), pixel_data[0]);
    try std.testing.expectEqual(@as(u8, 0x00), pixel_data[1]);
    try std.testing.expectEqual(@as(u8, 0xFF), pixel_data[2]);
}
