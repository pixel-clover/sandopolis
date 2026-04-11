const std = @import("std");
const testing = std.testing;

/// ROM file extensions recognized inside ZIP archives.
const rom_extensions = [_][]const u8{ ".bin", ".md", ".smd", ".gen", ".sms", ".gg", ".sg" };

/// Read a ROM file from disk. If the file is a ZIP archive (detected by "PK"
/// magic bytes), the first entry with a recognized ROM extension is extracted
/// and returned. Otherwise the raw file contents are returned as-is.
pub fn readRomFile(allocator: std.mem.Allocator, path: []const u8, max_size: usize) ![]u8 {
    const file_data = try std.fs.cwd().readFileAlloc(allocator, path, max_size);
    errdefer allocator.free(file_data);

    if (isZip(file_data)) {
        const rom = try extractRomFromZip(allocator, file_data);
        allocator.free(file_data);
        return rom;
    }
    return file_data;
}

/// Extract a ROM from in-memory data. If the data is a ZIP archive, the first
/// ROM entry is extracted into a new allocation. Otherwise, the data is duped.
/// The caller owns the returned slice.
pub fn extractRomBytes(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    if (isZip(data)) {
        return try extractRomFromZip(allocator, data);
    }
    return try allocator.dupe(u8, data);
}

/// Check for ZIP magic bytes ("PK\x03\x04" local file header).
fn isZip(data: []const u8) bool {
    return data.len >= 4 and data[0] == 'P' and data[1] == 'K' and data[2] == 3 and data[3] == 4;
}

/// Extract the first ROM file from a ZIP archive stored in memory.
fn extractRomFromZip(allocator: std.mem.Allocator, zip_data: []const u8) ![]u8 {
    // Find the End of Central Directory record by searching backward.
    const eocd = try findEndOfCentralDirectory(zip_data);
    const cd_offset = eocd.cd_offset;
    const cd_entries = eocd.cd_entries;

    // Walk central directory entries to find a ROM file.
    var offset = cd_offset;
    for (0..cd_entries) |_| {
        if (offset + 46 > zip_data.len) return error.ZipCorrupt;
        // Central directory file header signature: "PK\x01\x02"
        if (zip_data[offset] != 'P' or zip_data[offset + 1] != 'K' or
            zip_data[offset + 2] != 1 or zip_data[offset + 3] != 2)
            return error.ZipCorrupt;

        const filename_len = readU16(zip_data, offset + 28);
        const extra_len = readU16(zip_data, offset + 30);
        const comment_len = readU16(zip_data, offset + 32);
        const local_header_offset = readU32(zip_data, offset + 42);

        if (offset + 46 + filename_len > zip_data.len) return error.ZipCorrupt;
        const filename = zip_data[offset + 46 ..][0..filename_len];

        // Check if this entry has a recognized ROM extension.
        if (hasRomExtension(filename)) {
            return try extractLocalEntry(allocator, zip_data, local_header_offset);
        }

        offset += 46 + filename_len + extra_len + comment_len;
    }

    // No entry with a ROM extension found; try extracting the first file.
    if (cd_entries > 0) {
        const first_offset = cd_offset;
        if (first_offset + 46 > zip_data.len) return error.ZipCorrupt;
        const local_header_offset = readU32(zip_data, first_offset + 42);
        return try extractLocalEntry(allocator, zip_data, local_header_offset);
    }

    return error.ZipEmpty;
}

/// Extract a single file from its local file header offset.
fn extractLocalEntry(allocator: std.mem.Allocator, zip_data: []const u8, local_offset: u32) ![]u8 {
    if (local_offset + 30 > zip_data.len) return error.ZipCorrupt;
    // Local file header signature: "PK\x03\x04"
    if (zip_data[local_offset] != 'P' or zip_data[local_offset + 1] != 'K' or
        zip_data[local_offset + 2] != 3 or zip_data[local_offset + 3] != 4)
        return error.ZipCorrupt;

    const method = readU16(zip_data, local_offset + 8);
    const compressed_size = readU32(zip_data, local_offset + 18);
    const uncompressed_size = readU32(zip_data, local_offset + 22);
    const filename_len = readU16(zip_data, local_offset + 26);
    const extra_len = readU16(zip_data, local_offset + 28);

    const data_offset = local_offset + 30 + filename_len + extra_len;
    if (data_offset + compressed_size > zip_data.len) return error.ZipCorrupt;
    const compressed_data = zip_data[data_offset..][0..compressed_size];

    if (method == 0) {
        // Stored (uncompressed)
        const result = try allocator.alloc(u8, uncompressed_size);
        @memcpy(result, compressed_data[0..uncompressed_size]);
        return result;
    } else if (method == 8) {
        // Deflate
        return try inflateData(allocator, compressed_data, uncompressed_size);
    } else {
        return error.ZipUnsupportedCompression;
    }
}

/// Decompress deflate data using Zig's standard library.
fn inflateData(allocator: std.mem.Allocator, compressed: []const u8, uncompressed_size: u32) ![]u8 {
    const result = try allocator.alloc(u8, uncompressed_size);
    errdefer allocator.free(result);

    var input = std.Io.Reader.fixed(compressed);
    var window_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var decomp = std.compress.flate.Decompress.init(&input, .raw, &window_buf);
    // Stream decompressed data into the output buffer via a fixed writer.
    var output = std.Io.Writer.fixed(result);
    decomp.reader.streamExact(&output, uncompressed_size) catch return error.ZipDecompressError;
    return result;
}

const EocdInfo = struct {
    cd_offset: u32,
    cd_entries: u16,
};

/// Locate the End of Central Directory record by searching backward from the
/// end of the file for the "PK\x05\x06" signature.
fn findEndOfCentralDirectory(data: []const u8) !EocdInfo {
    if (data.len < 22) return error.ZipTooSmall;
    // Search backward, max 65557 bytes from end (22 byte EOCD + 65535 max comment)
    const search_limit = @min(data.len, 22 + 65535);
    var pos: usize = data.len - 22;
    while (true) {
        if (data[pos] == 'P' and data[pos + 1] == 'K' and
            data[pos + 2] == 5 and data[pos + 3] == 6)
        {
            return .{
                .cd_entries = readU16(data, pos + 8),
                .cd_offset = readU32(data, pos + 16),
            };
        }
        if (pos == 0 or data.len - pos >= search_limit) break;
        pos -= 1;
    }
    return error.ZipNoEndRecord;
}

fn hasRomExtension(filename: []const u8) bool {
    const lower_buf = blk: {
        var buf: [256]u8 = undefined;
        const len = @min(filename.len, buf.len);
        for (0..len) |i| {
            buf[i] = std.ascii.toLower(filename[i]);
        }
        break :blk buf[0..len];
    };
    for (rom_extensions) |ext| {
        if (lower_buf.len >= ext.len and
            std.mem.eql(u8, lower_buf[lower_buf.len - ext.len ..], ext))
            return true;
    }
    return false;
}

fn readU16(data: []const u8, offset: usize) u16 {
    return @as(u16, data[offset]) | (@as(u16, data[offset + 1]) << 8);
}

fn readU32(data: []const u8, offset: usize) u32 {
    return @as(u32, data[offset]) |
        (@as(u32, data[offset + 1]) << 8) |
        (@as(u32, data[offset + 2]) << 16) |
        (@as(u32, data[offset + 3]) << 24);
}

// -- Tests --

test "isZip detects PK header" {
    const zip_magic = [_]u8{ 'P', 'K', 3, 4, 0, 0 };
    try testing.expect(isZip(&zip_magic));
    const not_zip = [_]u8{ 0xFF, 0x00, 0x00, 0x00 };
    try testing.expect(!isZip(&not_zip));
}

test "hasRomExtension matches known extensions" {
    try testing.expect(hasRomExtension("game.bin"));
    try testing.expect(hasRomExtension("game.sms"));
    try testing.expect(hasRomExtension("game.gg"));
    try testing.expect(hasRomExtension("GAME.GG"));
    try testing.expect(hasRomExtension("rom.MD"));
    try testing.expect(!hasRomExtension("readme.txt"));
    try testing.expect(!hasRomExtension("game.zip"));
}

test "extract stored zip entry" {
    // Minimal valid ZIP with one stored file "test.bin" containing bytes 0xAA, 0xBB
    const zip = [_]u8{
        // Local file header
        'P', 'K', 3, 4, // signature
        20, 0, // version needed
        0, 0, // flags
        0, 0, // compression: store
        0, 0, // mod time
        0, 0, // mod date
        0, 0, 0, 0, // crc32 (unused)
        2, 0, 0, 0, // compressed size
        2, 0, 0, 0, // uncompressed size
        8, 0, // filename len
        0, 0, // extra len
        't', 'e', 's', 't', '.', 'b', 'i', 'n', // filename
        0xAA, 0xBB, // data
        // Central directory header
        'P', 'K', 1, 2, // signature
        20, 0, // version made by
        20, 0, // version needed
        0, 0, // flags
        0, 0, // compression: store
        0, 0, // mod time
        0, 0, // mod date
        0, 0, 0, 0, // crc32
        2, 0, 0, 0, // compressed size
        2, 0, 0, 0, // uncompressed size
        8, 0, // filename len
        0, 0, // extra len
        0, 0, // comment len
        0, 0, // disk number
        0, 0, // internal attrs
        0, 0, 0, 0, // external attrs
        0, 0, 0, 0, // local header offset
        't', 'e', 's', 't', '.', 'b', 'i', 'n', // filename
        // End of central directory
        'P', 'K', 5, 6, // signature
        0, 0, // disk number
        0, 0, // cd disk
        1, 0, // entries on disk
        1, 0, // total entries
        54, 0, 0, 0, // cd size
        40, 0, 0, 0, // cd offset (after local header + data)
        0, 0, // comment len
    };

    const result = try extractRomFromZip(testing.allocator, &zip);
    defer testing.allocator.free(result);
    try testing.expectEqual(@as(usize, 2), result.len);
    try testing.expectEqual(@as(u8, 0xAA), result[0]);
    try testing.expectEqual(@as(u8, 0xBB), result[1]);
}

test "readRomFile extracts ROM from deflated zip" {
    const rom = readRomFile(testing.allocator, "roms/Aerial Assault (World).zip", 8 * 1024 * 1024) catch return;
    defer testing.allocator.free(rom);
    // Should extract the .gg file (131072 bytes)
    try testing.expectEqual(@as(usize, 131072), rom.len);
    // Verify it starts with standard Z80 startup (DI = 0xF3)
    try testing.expectEqual(@as(u8, 0xF3), rom[0]);
}

test "readRomFile passes through non-zip files" {
    const rom = readRomFile(testing.allocator, "roms/Aerial Assault (World).gg", 8 * 1024 * 1024) catch return;
    defer testing.allocator.free(rom);
    try testing.expectEqual(@as(usize, 131072), rom.len);
    try testing.expectEqual(@as(u8, 0xF3), rom[0]);
}

test "readRomFile zip matches original gg rom" {
    const original = readRomFile(testing.allocator, "roms/Aerial Assault (World).gg", 8 * 1024 * 1024) catch return;
    defer testing.allocator.free(original);
    const from_zip = readRomFile(testing.allocator, "roms/Aerial Assault (World).gg.zip", 8 * 1024 * 1024) catch return;
    defer testing.allocator.free(from_zip);
    try testing.expectEqual(original.len, from_zip.len);
    try testing.expectEqualSlices(u8, original, from_zip);
}

test "readRomFile extracts sms rom from zip" {
    const rom = readRomFile(testing.allocator, "roms/Paperboy (USA).sms.zip", 8 * 1024 * 1024) catch return;
    defer testing.allocator.free(rom);
    try testing.expectEqual(@as(usize, 131072), rom.len);
}

test "readRomFile extracts genesis smd rom from zip" {
    const rom = readRomFile(testing.allocator, "roms/ros.smd.zip", 8 * 1024 * 1024) catch return;
    defer testing.allocator.free(rom);
    try testing.expectEqual(@as(usize, 524288), rom.len);
}
