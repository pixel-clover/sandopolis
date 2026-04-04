const std = @import("std");
const Machine = @import("machine.zig").Machine;

// Timing mode options
pub const TimingModeOption = enum {
    auto,
    pal,
    ntsc,
};

// Resolved timing configuration
pub const ResolvedTimingMode = struct {
    pal_mode: bool,
    description: []const u8,
};

// Resolved console region configuration
pub const ResolvedConsoleRegion = struct {
    overseas: bool,
    description: []const u8,
};

// Infer PAL mode from ROM country codes
// Returns true for PAL, false for NTSC, or null if ambiguous
pub fn inferPalModeFromCountryCodes(country_codes: ?[]const u8) ?bool {
    const codes = country_codes orelse return null;

    var uses_letter_codes = false;
    for (codes) |raw| {
        switch (std.ascii.toUpper(raw)) {
            'E', 'U', 'J' => {
                uses_letter_codes = true;
                break;
            },
            else => {},
        }
    }

    var pal_compatible = false;
    var ntsc_compatible = false;
    for (codes) |raw| {
        const ch = std.ascii.toUpper(raw);
        if (uses_letter_codes) {
            switch (ch) {
                0, ' ' => {},
                'E' => pal_compatible = true,
                'U', 'J' => ntsc_compatible = true,
                else => {},
            }
            continue;
        }

        switch (ch) {
            0, ' ' => {},
            '0'...'9', 'A'...'F' => {
                const nibble = std.fmt.charToDigit(ch, 16) catch continue;
                if ((nibble & 0x8) != 0) pal_compatible = true;
                if ((nibble & 0x5) != 0) ntsc_compatible = true;
            },
            else => {},
        }
    }

    if (pal_compatible and !ntsc_compatible) return true;
    if (ntsc_compatible and !pal_compatible) return false;
    return null;
}

// Infer console region from ROM country codes
// Returns true for overseas/export, false for domestic/Japan, or null if ambiguous
pub fn inferConsoleIsOverseasFromCountryCodes(country_codes: ?[]const u8) ?bool {
    const codes = country_codes orelse return null;

    var uses_letter_codes = false;
    for (codes) |raw| {
        switch (std.ascii.toUpper(raw)) {
            'E', 'U', 'J' => {
                uses_letter_codes = true;
                break;
            },
            else => {},
        }
    }

    var domestic_compatible = false;
    var overseas_compatible = false;
    for (codes) |raw| {
        const ch = std.ascii.toUpper(raw);
        if (uses_letter_codes) {
            switch (ch) {
                0, ' ' => {},
                'J' => domestic_compatible = true,
                'E', 'U' => overseas_compatible = true,
                else => {},
            }
            continue;
        }

        switch (ch) {
            0, ' ' => {},
            '0'...'9', 'A'...'F' => {
                const nibble = std.fmt.charToDigit(ch, 16) catch continue;
                if ((nibble & 0x1) != 0) domestic_compatible = true;
                if ((nibble & 0xC) != 0) overseas_compatible = true;
            },
            else => {},
        }
    }

    if (domestic_compatible and !overseas_compatible) return false;
    if (overseas_compatible and !domestic_compatible) return true;
    return null;
}

// Resolve timing mode from ROM metadata and user preference
pub fn resolveTimingMode(metadata: Machine.RomMetadata, timing_mode: TimingModeOption) ResolvedTimingMode {
    return switch (timing_mode) {
        .pal => .{ .pal_mode = true, .description = "PAL/50Hz (forced)" },
        .ntsc => .{ .pal_mode = false, .description = "NTSC/60Hz (forced)" },
        .auto => {
            if (inferPalModeFromCountryCodes(metadata.country_codes)) |pal_mode| {
                return .{
                    .pal_mode = pal_mode,
                    .description = if (pal_mode) "PAL/50Hz (auto)" else "NTSC/60Hz (auto)",
                };
            }
            return .{ .pal_mode = false, .description = "NTSC/60Hz (auto default)" };
        },
    };
}

// Resolve console region from ROM metadata
pub fn resolveConsoleRegion(metadata: Machine.RomMetadata) ResolvedConsoleRegion {
    if (inferConsoleIsOverseasFromCountryCodes(metadata.country_codes)) |overseas| {
        return .{
            .overseas = overseas,
            .description = if (overseas) "Overseas/export (auto)" else "Domestic/Japan (auto)",
        };
    }
    return .{ .overseas = true, .description = "Overseas/export (auto default)" };
}

// Log ROM metadata to debug output
pub fn logLoadedRomMetadata(machine: *Machine, rom_path: []const u8) void {
    const metadata = machine.romMetadata();
    std.debug.print("Loading ROM: {s}\n", .{rom_path});
    if (metadata.console) |console| {
        std.debug.print("Console: {s}\n", .{console});
    }
    if (metadata.title) |title| {
        std.debug.print("Title:   {s}\n", .{title});
    }
    if (metadata.product_code) |code| {
        std.debug.print("Product: {s}\n", .{code});
    }
    if (lookupGameByProductCode(metadata.product_code)) |game| {
        std.debug.print("Game:    {s}\n", .{game.title});
    }
    std.debug.print("Reset Vectors: SSP={X:0>8} PC={X:0>8}\n", .{
        metadata.reset_stack_pointer,
        metadata.reset_program_counter,
    });
    if (metadata.header_checksum != 0 or metadata.computed_checksum != 0) {
        if (metadata.checksum_valid) {
            std.debug.print("Checksum: {X:0>4} (valid)\n", .{metadata.header_checksum});
        } else {
            std.debug.print("Checksum: header={X:0>4} computed={X:0>4} (MISMATCH)\n", .{
                metadata.header_checksum,
                metadata.computed_checksum,
            });
        }
    }
}

// Game database entry for product code lookups.
pub const GameInfo = struct {
    title: []const u8,
    notes: []const u8 = "",
};

// Look up game info from a ROM product code (header bytes 0x183-0x18B).
// Returns null if the product code is not in the database.
pub fn lookupGameByProductCode(product_code: ?[]const u8) ?GameInfo {
    const code = product_code orelse return null;
    for (game_db) |entry| {
        if (entry.id.len <= code.len and std.mem.startsWith(u8, code, entry.id)) {
            return .{ .title = entry.title, .notes = entry.notes };
        }
    }
    return null;
}

const GameDbEntry = struct {
    id: []const u8,
    title: []const u8,
    notes: []const u8 = "",
};

// A curated subset of well-known Genesis titles for display purposes.
const game_db = [_]GameDbEntry{
    .{ .id = "MK-1079 ", .title = "Sonic the Hedgehog" },
    .{ .id = "MK-1124 ", .title = "Sonic the Hedgehog 2" },
    .{ .id = "MK-1563 ", .title = "Sonic the Hedgehog 3" },
    .{ .id = "MK-1635 ", .title = "Sonic & Knuckles" },
    .{ .id = "MK-1105 ", .title = "Streets of Rage" },
    .{ .id = "MK-1215 ", .title = "Streets of Rage 2" },
    .{ .id = "MK-1536 ", .title = "Streets of Rage 3" },
    .{ .id = "MK-1027 ", .title = "Golden Axe" },
    .{ .id = "MK-1132 ", .title = "Golden Axe II" },
    .{ .id = "MK-1231 ", .title = "Golden Axe III" },
    .{ .id = "MK-1028 ", .title = "The Revenge of Shinobi" },
    .{ .id = "MK-1044 ", .title = "Shinobi III" },
    .{ .id = "MK-1176 ", .title = "Gunstar Heroes" },
    .{ .id = "MK-1548 ", .title = "Castlevania: Bloodlines" },
    .{ .id = "MK-1055 ", .title = "Phantasy Star IV" },
    .{ .id = "MK-1234 ", .title = "Shining Force II" },
    .{ .id = "T-113016", .title = "Thunderforce IV", .notes = "Technosoft" },
    .{ .id = "T-50076 ", .title = "Warsong", .notes = "Treco" },
    .{ .id = "T-50136 ", .title = "Landstalker", .notes = "Sega" },
    .{ .id = "T-81033 ", .title = "Phantasy Star II", .notes = "Sega" },
    .{ .id = "MK-1228 ", .title = "Contra: Hard Corps" },
    .{ .id = "MK-1073 ", .title = "Ecco the Dolphin" },
    .{ .id = "T-70096 ", .title = "Beyond Oasis", .notes = "Sega" },
    .{ .id = "MK-1182 ", .title = "Comix Zone" },
    .{ .id = "MK-1049 ", .title = "ToeJam & Earl" },
    .{ .id = "T-12056 ", .title = "Road Rash II", .notes = "EA" },
};

test "game database returns known titles by product code" {
    const sonic = lookupGameByProductCode("MK-1079 ");
    try std.testing.expect(sonic != null);
    try std.testing.expectEqualStrings("Sonic the Hedgehog", sonic.?.title);

    const sor2 = lookupGameByProductCode("MK-1215 ");
    try std.testing.expect(sor2 != null);
    try std.testing.expectEqualStrings("Streets of Rage 2", sor2.?.title);

    const tf4 = lookupGameByProductCode("T-113016");
    try std.testing.expect(tf4 != null);
    try std.testing.expectEqualStrings("Thunderforce IV", tf4.?.title);
}

test "game database returns null for unknown product codes" {
    try std.testing.expect(lookupGameByProductCode("XX-99999") == null);
    try std.testing.expect(lookupGameByProductCode(null) == null);
}

test "game database matches product code prefix" {
    // Product codes in ROM headers may have trailing spaces or version suffixes.
    const result = lookupGameByProductCode("MK-1079 -00");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("Sonic the Hedgehog", result.?.title);
}
