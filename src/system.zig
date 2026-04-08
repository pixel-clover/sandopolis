const std = @import("std");
const testing = std.testing;
const sms_cartridge = @import("sms/cartridge.zig");

pub const SystemType = enum {
    genesis,
    sms,
    game_gear,
};

/// Detect whether a ROM belongs to a Genesis or SMS system.
/// Checks for SMS "TMR SEGA" header first, then Genesis "SEGA" header.
/// Falls back to Genesis if neither is found (most common case for headerless ROMs).
pub fn detectSystem(rom: []const u8) SystemType {
    if (sms_cartridge.isSmsRom(rom)) {
        // Check region code to distinguish Game Gear from SMS.
        const meta = sms_cartridge.parseMetadata(rom);
        return switch (meta.region) {
            .game_gear_japanese, .game_gear_export, .game_gear_international => .game_gear,
            else => .sms,
        };
    }
    // Genesis ROMs have "SEGA" at offset 0x100
    if (rom.len >= 0x104 and std.mem.eql(u8, rom[0x100..0x104], "SEGA")) return .genesis;
    // Default to Genesis for unknown ROMs
    return .genesis;
}

test "detect system genesis" {
    var rom = [_]u8{0} ** 0x200;
    @memcpy(rom[0x100..0x104], "SEGA");
    try testing.expectEqual(SystemType.genesis, detectSystem(&rom));
}

test "detect system sms" {
    var rom = [_]u8{0} ** 0x8000;
    @memcpy(rom[0x7FF0..][0..8], "TMR SEGA");
    try testing.expectEqual(SystemType.sms, detectSystem(&rom));
}

test "detect system game gear" {
    var rom = [_]u8{0} ** 0x8000;
    @memcpy(rom[0x7FF0..][0..8], "TMR SEGA");
    rom[0x7FFF] = 0x6C; // Region=game_gear_export(6), size=C
    try testing.expectEqual(SystemType.game_gear, detectSystem(&rom));
}

test "detect system unknown defaults to genesis" {
    const rom = [_]u8{0} ** 0x100;
    try testing.expectEqual(SystemType.genesis, detectSystem(&rom));
}
