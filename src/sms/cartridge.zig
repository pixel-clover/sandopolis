const std = @import("std");
const testing = std.testing;

/// Detect whether a ROM is an SMS ROM by looking for the "TMR SEGA" header
/// at standard offsets: 0x7FF0, 0x3FF0, or 0x1FF0.
pub fn isSmsRom(rom: []const u8) bool {
    const signature = "TMR SEGA";
    const offsets = [_]usize{ 0x7FF0, 0x3FF0, 0x1FF0 };
    for (offsets) |offset| {
        if (rom.len >= offset + signature.len) {
            if (std.mem.eql(u8, rom[offset..][0..signature.len], signature)) {
                return true;
            }
        }
    }
    return false;
}

/// Extract SMS ROM metadata from header.
pub const SmsRomMetadata = struct {
    has_header: bool,
    product_code: u32,
    version: u4,
    region: Region,
    rom_size_code: u4,
    checksum: u16,

    pub const Region = enum {
        japanese,
        international,
        game_gear_japanese,
        game_gear_export,
        game_gear_international,
        unknown,
    };
};

pub fn parseMetadata(rom: []const u8) SmsRomMetadata {
    const offsets = [_]usize{ 0x7FF0, 0x3FF0, 0x1FF0 };
    const signature = "TMR SEGA";

    for (offsets) |offset| {
        if (rom.len >= offset + 16) {
            if (std.mem.eql(u8, rom[offset..][0..signature.len], signature)) {
                const checksum = @as(u16, rom[offset + 0x0A]) |
                    (@as(u16, rom[offset + 0x0B]) << 8);
                const product_lo = rom[offset + 0x0C];
                const product_mid = rom[offset + 0x0D];
                const product_hi_ver = rom[offset + 0x0E];
                const product_code = @as(u32, decodeBcd(product_lo)) +
                    @as(u32, decodeBcd(product_mid)) * 100 +
                    @as(u32, product_hi_ver >> 4) * 10000;
                const version: u4 = @truncate(product_hi_ver);
                const region_size = rom[offset + 0x0F];
                const region = decodeRegion(@truncate(region_size >> 4));
                const rom_size_code: u4 = @truncate(region_size);

                return .{
                    .has_header = true,
                    .product_code = product_code,
                    .version = version,
                    .region = region,
                    .rom_size_code = rom_size_code,
                    .checksum = checksum,
                };
            }
        }
    }

    return .{
        .has_header = false,
        .product_code = 0,
        .version = 0,
        .region = .unknown,
        .rom_size_code = 0,
        .checksum = 0,
    };
}

fn decodeBcd(byte: u8) u8 {
    return (byte >> 4) * 10 + (byte & 0x0F);
}

fn decodeRegion(code: u4) SmsRomMetadata.Region {
    return switch (code) {
        3 => .japanese,
        4 => .international,
        5 => .game_gear_japanese,
        6 => .game_gear_export,
        7 => .game_gear_international,
        else => .unknown,
    };
}

test "sms cartridge detection positive" {
    var rom = [_]u8{0} ** 0x8000; // 32KB
    @memcpy(rom[0x7FF0..][0..8], "TMR SEGA");
    try testing.expect(isSmsRom(&rom));
}

test "sms cartridge detection negative" {
    var rom = [_]u8{0} ** 0x200;
    @memcpy(rom[0x100..][0..4], "SEGA"); // Genesis header
    try testing.expect(!isSmsRom(&rom));
}

test "sms cartridge metadata parsing" {
    var rom = [_]u8{0} ** 0x8000;
    @memcpy(rom[0x7FF0..][0..8], "TMR SEGA");
    rom[0x7FFA] = 0x34; // Checksum low
    rom[0x7FFB] = 0x12; // Checksum high
    rom[0x7FFF] = 0x4C; // Region=export(4), size=C
    const meta = parseMetadata(&rom);
    try testing.expect(meta.has_header);
    try testing.expectEqual(@as(u16, 0x1234), meta.checksum);
    try testing.expectEqual(SmsRomMetadata.Region.international, meta.region);
}

test "decodeBcd converts packed BCD digits" {
    try testing.expectEqual(@as(u8, 0), decodeBcd(0x00));
    try testing.expectEqual(@as(u8, 9), decodeBcd(0x09));
    try testing.expectEqual(@as(u8, 10), decodeBcd(0x10));
    try testing.expectEqual(@as(u8, 42), decodeBcd(0x42));
    try testing.expectEqual(@as(u8, 99), decodeBcd(0x99));
}

test "decodeRegion maps all known codes" {
    try testing.expectEqual(SmsRomMetadata.Region.japanese, decodeRegion(3));
    try testing.expectEqual(SmsRomMetadata.Region.international, decodeRegion(4));
    try testing.expectEqual(SmsRomMetadata.Region.game_gear_japanese, decodeRegion(5));
    try testing.expectEqual(SmsRomMetadata.Region.game_gear_export, decodeRegion(6));
    try testing.expectEqual(SmsRomMetadata.Region.game_gear_international, decodeRegion(7));
    try testing.expectEqual(SmsRomMetadata.Region.unknown, decodeRegion(0));
    try testing.expectEqual(SmsRomMetadata.Region.unknown, decodeRegion(15));
}

test "sms cartridge detection at alternate offsets" {
    // Header at 0x3FF0
    var rom16k = [_]u8{0} ** 0x4000;
    @memcpy(rom16k[0x3FF0..][0..8], "TMR SEGA");
    try testing.expect(isSmsRom(&rom16k));

    // Header at 0x1FF0
    var rom8k = [_]u8{0} ** 0x2000;
    @memcpy(rom8k[0x1FF0..][0..8], "TMR SEGA");
    try testing.expect(isSmsRom(&rom8k));

    // ROM too short for any header
    const tiny = [_]u8{0} ** 16;
    try testing.expect(!isSmsRom(&tiny));
}
