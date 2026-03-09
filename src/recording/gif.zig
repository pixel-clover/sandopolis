const std = @import("std");

pub const GifRecorder = struct {
    file: std.fs.File,
    frame_count: u32,
    delay_cs: u16,

    out_buf: [out_buf_size]u8 = undefined,
    out_len: usize = 0,

    const width = 320;
    const height = 224;
    const pixel_count = width * height;
    const max_colors: u16 = 256;
    const color_depth: u3 = 7;
    const min_code_size: u8 = 8;
    const out_buf_size = 64 * 1024;

    pub fn start(path: []const u8, fps: u16) !GifRecorder {
        const file = try std.fs.cwd().createFile(path, .{});
        errdefer file.close();

        const delay_cs: u16 = if (fps > 0) @intCast(@min(65535, (100 + fps / 2) / fps)) else 2;

        var self = GifRecorder{
            .file = file,
            .frame_count = 0,
            .delay_cs = delay_cs,
        };

        self.bufWrite("GIF89a");

        self.bufWriteU16(@intCast(width));
        self.bufWriteU16(@intCast(height));
        self.bufWriteByte(0x80 | (@as(u8, color_depth) << 4) | color_depth);
        self.bufWriteByte(0);
        self.bufWriteByte(0);

        self.bufWriteZeros(max_colors * 3);

        self.bufWrite(&.{ 0x21, 0xFF, 0x0B });
        self.bufWrite("NETSCAPE2.0");
        self.bufWrite(&.{ 0x03, 0x01, 0x00, 0x00, 0x00 });

        try self.flushBuf();
        return self;
    }

    pub fn addFrame(self: *GifRecorder, framebuffer: *const [pixel_count]u32) !void {
        if (self.frame_count > 0) {
            const pos = self.file.getPos() catch 0;
            if (pos > 0) self.file.seekTo(pos - 1) catch {};
        }

        var palette: [max_colors]u32 = [_]u32{0} ** max_colors;
        var palette_size: u16 = 0;

        var color_map: [4096]ColorEntry = [_]ColorEntry{.{ .color = 0, .index = 0, .used = false }} ** 4096;

        var indices: [pixel_count]u8 = undefined;

        for (framebuffer, 0..) |pixel, i| {
            const color = pixel & 0x00FFFFFF;
            indices[i] = findOrAddColor(&palette, &palette_size, &color_map, color);
        }

        self.bufWrite(&.{ 0x21, 0xF9, 0x04, 0x00 });
        self.bufWriteU16(self.delay_cs);
        self.bufWriteByte(0);
        self.bufWriteByte(0);

        self.bufWriteByte(0x2C);
        self.bufWriteU16(0);
        self.bufWriteU16(0);
        self.bufWriteU16(@intCast(width));
        self.bufWriteU16(@intCast(height));
        self.bufWriteByte(0x80 | @as(u8, color_depth));

        for (0..max_colors) |ci| {
            const c = palette[ci];
            self.bufWriteByte(@intCast((c >> 16) & 0xFF));
            self.bufWriteByte(@intCast((c >> 8) & 0xFF));
            self.bufWriteByte(@intCast(c & 0xFF));
        }

        self.bufWriteByte(min_code_size);
        try self.flushBuf();
        try lzwCompress(self, &indices);
        self.bufWriteByte(0x00);

        self.bufWriteByte(0x3B);
        try self.flushBuf();

        self.frame_count += 1;
    }

    pub fn finish(self: *GifRecorder) void {
        if (self.frame_count == 0) {
            self.bufWriteByte(0x3B);
            self.flushBuf() catch {};
        }

        self.file.close();
    }

    fn bufWriteByte(self: *GifRecorder, byte: u8) void {
        self.out_buf[self.out_len] = byte;
        self.out_len += 1;
    }

    fn bufWriteU16(self: *GifRecorder, value: u16) void {
        self.out_buf[self.out_len] = @truncate(value);
        self.out_buf[self.out_len + 1] = @truncate(value >> 8);
        self.out_len += 2;
    }

    fn bufWrite(self: *GifRecorder, data: []const u8) void {
        @memcpy(self.out_buf[self.out_len..][0..data.len], data);
        self.out_len += data.len;
    }

    fn bufWriteZeros(self: *GifRecorder, count: usize) void {
        @memset(self.out_buf[self.out_len..][0..count], 0);
        self.out_len += count;
    }

    fn flushBuf(self: *GifRecorder) !void {
        if (self.out_len > 0) {
            try self.file.writeAll(self.out_buf[0..self.out_len]);
            self.out_len = 0;
        }
    }

    const ColorEntry = struct { color: u32, index: u8, used: bool };

    fn colorHash(color: u32) u12 {
        const r = (color >> 16) & 0xFF;
        const g = (color >> 8) & 0xFF;
        const b = color & 0xFF;
        return @truncate(r *% 7 +% g *% 13 +% b *% 23);
    }

    fn findOrAddColor(
        palette: *[max_colors]u32,
        size: *u16,
        color_map: *[4096]ColorEntry,
        color: u32,
    ) u8 {
        var h: usize = colorHash(color);

        var probes: usize = 0;
        while (probes < 4096) : ({
            h = (h + 1) & 0xFFF;
            probes += 1;
        }) {
            if (!color_map[h].used) {
                if (size.* < max_colors) {
                    const idx: u8 = @intCast(size.*);
                    palette[idx] = color;
                    size.* += 1;
                    color_map[h] = .{ .color = color, .index = idx, .used = true };
                    return idx;
                }

                return findNearest(palette, color);
            }
            if (color_map[h].color == color) {
                return color_map[h].index;
            }
        }

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

const LzwHashEntry = struct {
    prefix: u16 = 0,
    suffix: u8 = 0,
    code: u16 = 0,
    used: bool = false,
};

const lzw_hash_size = 8192;

fn lzwHash(prefix: u16, suffix: u8) u13 {
    return @truncate((@as(u32, prefix) << 8 ^ @as(u32, suffix)) *% 2654435761);
}

fn lzwCompress(rec: *GifRecorder, data: *const [320 * 224]u8) !void {
    const clear_code: u16 = 256;
    const eoi_code: u16 = 257;
    const first_code: u16 = 258;
    const max_code_value: u16 = 4095;

    var hash_table: [lzw_hash_size]LzwHashEntry = [_]LzwHashEntry{.{}} ** lzw_hash_size;
    var table_size: u16 = first_code;
    var code_size: u4 = 9;

    var bit_buf: u32 = 0;
    var bit_count: u5 = 0;

    var block_buf: [255]u8 = undefined;
    var block_len: u8 = 0;

    emitCode(rec, clear_code, code_size, &bit_buf, &bit_count, &block_buf, &block_len);

    var prefix: u16 = data[0];
    for (data[1..]) |byte| {
        var h: usize = lzwHash(prefix, byte);
        const found = blk: {
            var probes: usize = 0;
            while (probes < lzw_hash_size) : ({
                h = (h + 1) & (lzw_hash_size - 1);
                probes += 1;
            }) {
                if (!hash_table[h].used) break :blk false;
                if (hash_table[h].prefix == prefix and hash_table[h].suffix == byte) break :blk true;
            }
            break :blk false;
        };

        if (found) {
            prefix = hash_table[h].code;
        } else {
            emitCode(rec, prefix, code_size, &bit_buf, &bit_count, &block_buf, &block_len);

            if (table_size <= max_code_value) {
                hash_table[h] = .{ .prefix = prefix, .suffix = byte, .code = table_size, .used = true };
                table_size += 1;
                if (table_size > (@as(u16, 1) << code_size) and code_size < 12) {
                    code_size += 1;
                }
            } else {
                emitCode(rec, clear_code, code_size, &bit_buf, &bit_count, &block_buf, &block_len);
                hash_table = [_]LzwHashEntry{.{}} ** lzw_hash_size;
                table_size = first_code;
                code_size = 9;
            }

            prefix = byte;
        }
    }

    emitCode(rec, prefix, code_size, &bit_buf, &bit_count, &block_buf, &block_len);
    emitCode(rec, eoi_code, code_size, &bit_buf, &bit_count, &block_buf, &block_len);

    if (bit_count > 0) {
        block_buf[block_len] = @truncate(bit_buf);
        block_len += 1;
    }
    if (block_len > 0) {
        rec.bufWriteByte(block_len);
        rec.bufWrite(block_buf[0..block_len]);
    }
    try rec.flushBuf();
}

fn emitCode(
    rec: *GifRecorder,
    code: u16,
    cs: u4,
    bb: *u32,
    bc: *u5,
    blk: *[255]u8,
    bl: *u8,
) void {
    bb.* |= @as(u32, code) << bc.*;
    bc.* +%= cs;
    while (bc.* >= 8) {
        blk[bl.*] = @truncate(bb.*);
        bl.* += 1;
        if (bl.* == 255) {
            rec.bufWriteByte(255);
            rec.bufWrite(blk);
            bl.* = 0;
        }
        bb.* >>= 8;
        bc.* -%= 8;
    }
}

test "GIF recorder creates valid single-frame GIF" {
    var framebuffer: [320 * 224]u32 = undefined;
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

    const file = try std.fs.cwd().openFile(tmp_path, .{});
    defer file.close();
    var header: [6]u8 = undefined;
    _ = try file.readAll(&header);
    try std.testing.expectEqualStrings("GIF89a", &header);

    const stat = try file.stat();
    try std.testing.expect(stat.size > 1000);

    try std.fs.cwd().deleteFile(tmp_path);
}

test "GIF recorder handles multiple frames" {
    const tmp_path = "test_multi.gif";
    var recorder = try GifRecorder.start(tmp_path, 30);

    var fb: [320 * 224]u32 = undefined;
    for (0..3) |frame| {
        const shade: u32 = @intCast(frame * 80);
        @memset(&fb, 0xFF000000 | (shade << 16) | (shade << 8) | shade);
        try recorder.addFrame(&fb);
    }
    recorder.finish();

    try std.testing.expectEqual(@as(u32, 3), recorder.frame_count);

    const file = try std.fs.cwd().openFile(tmp_path, .{});
    defer file.close();
    const stat = try file.stat();
    try std.testing.expect(stat.size > 2000);

    try std.fs.cwd().deleteFile(tmp_path);
}
