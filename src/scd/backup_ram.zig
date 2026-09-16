//! Internal backup RAM (8KB) and the BIOS format block that occupies its
//! last 64 bytes. A freshly created image is pre-formatted so the BIOS does
//! not stop at the "format backup RAM?" prompt.
//!
//! Format block layout (relative to the last 0x40 bytes):
//!   +0x00  11 x '_'  volume name filler
//!   +0x0B  4 x 0x00
//!   +0x0F  0x40      block size marker
//!   +0x10  4 x u16   free blocks, big-endian, each = (size / 64) - 3
//!   +0x18  8 x 0x00
//!   +0x20  "SEGA_CD_ROM" NUL          signature
//!   +0x2C  0x01 0x00 0x00 0x00         format version
//!   +0x30  "RAM_CARTRIDGE___"          media type

const std = @import("std");

pub const size: usize = 8 * 1024;
pub const format_block_bytes: usize = 0x40;
pub const format_block_offset: usize = size - format_block_bytes;
pub const block_bytes: usize = 64;

const signature = "SEGA_CD_ROM\x00\x01\x00\x00\x00RAM_CARTRIDGE___";

pub fn formatBlock(total_bytes: usize) [format_block_bytes]u8 {
    var block = [_]u8{0} ** format_block_bytes;
    @memset(block[0..11], '_');
    block[0x0F] = 0x40;
    const free_blocks: u16 = @intCast(total_bytes / block_bytes - 3);
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        std.mem.writeInt(u16, block[0x10 + i * 2 ..][0..2], free_blocks, .big);
    }
    @memcpy(block[0x20..0x40], signature);
    return block;
}

pub fn format(ram: *[size]u8) void {
    @memset(ram[0..format_block_offset], 0);
    ram[format_block_offset..].* = formatBlock(size);
}

/// True when the trailing signature block matches the BIOS format.
pub fn isFormatted(ram: *const [size]u8) bool {
    return std.mem.eql(u8, ram[format_block_offset + 0x20 ..], signature);
}

/// Fresh, formatted image.
pub fn initialImage() [size]u8 {
    var ram = [_]u8{0} ** size;
    format(&ram);
    return ram;
}

const testing = std.testing;

test "fresh image carries a valid format block with 125 free blocks" {
    const ram = initialImage();
    try testing.expect(isFormatted(&ram));
    const block = ram[format_block_offset..];
    try testing.expectEqualStrings("___________", block[0..11]);
    try testing.expectEqual(@as(u8, 0x40), block[0x0F]);
    try testing.expectEqual(@as(u16, 125), std.mem.readInt(u16, block[0x10..0x12], .big));
    try testing.expectEqual(@as(u16, 125), std.mem.readInt(u16, block[0x16..0x18], .big));
    try testing.expectEqualStrings("SEGA_CD_ROM", block[0x20..0x2B]);
    try testing.expectEqual(@as(u8, 1), block[0x2C]);
    try testing.expectEqualStrings("RAM_CARTRIDGE___", block[0x30..0x40]);
    // Payload area is clear.
    for (ram[0..format_block_offset]) |b| try testing.expectEqual(@as(u8, 0), b);
}

test "a blank or corrupted image is not formatted" {
    var ram = [_]u8{0} ** size;
    try testing.expect(!isFormatted(&ram));
    format(&ram);
    try testing.expect(isFormatted(&ram));
    ram[size - 1] = 'X';
    try testing.expect(!isFormatted(&ram));
}
