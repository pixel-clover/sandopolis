//! Sega CD BIOS image handling: validation and region selection.
//!
//! The BIOS is the boot ROM the main 68000 executes from address 0 in
//! Mode 2 (no cartridge). It is region-locked; a disc whose security sector
//! targets another region shows a "not compatible" screen, so selection
//! prefers the disc's own region when the user has not forced one.

const std = @import("std");

pub const BiosRegion = enum {
    us,
    eu,
    jp,

    pub fn name(self: BiosRegion) []const u8 {
        return switch (self) {
            .us => "us",
            .eu => "eu",
            .jp => "jp",
        };
    }

    /// Conventional libretro system-directory file names.
    pub fn defaultFileName(self: BiosRegion) []const u8 {
        return switch (self) {
            .us => "bios_CD_U.bin",
            .eu => "bios_CD_E.bin",
            .jp => "bios_CD_J.bin",
        };
    }

    pub fn parse(text: []const u8) ?BiosRegion {
        if (std.ascii.eqlIgnoreCase(text, "us") or std.ascii.eqlIgnoreCase(text, "u")) return .us;
        if (std.ascii.eqlIgnoreCase(text, "eu") or std.ascii.eqlIgnoreCase(text, "e")) return .eu;
        if (std.ascii.eqlIgnoreCase(text, "jp") or std.ascii.eqlIgnoreCase(text, "j")) return .jp;
        return null;
    }
};

pub const bios_size: usize = 128 * 1024;

pub const ValidationError = error{
    BiosWrongSize,
    BiosMissingHeader,
};

/// A Sega CD BIOS is exactly 128KB and carries a standard Genesis-style
/// header with "SEGA" at 0x100.
pub fn validate(bytes: []const u8) ValidationError!void {
    if (bytes.len != bios_size) return error.BiosWrongSize;
    if (!std.mem.eql(u8, bytes[0x100..0x104], "SEGA")) return error.BiosMissingHeader;
}

/// The set of BIOS images available to the frontend. Slices are borrowed;
/// the owner keeps them alive for the machine's lifetime.
pub const BiosSet = struct {
    us: ?[]const u8 = null,
    eu: ?[]const u8 = null,
    jp: ?[]const u8 = null,

    pub fn get(self: *const BiosSet, region: BiosRegion) ?[]const u8 {
        return switch (region) {
            .us => self.us,
            .eu => self.eu,
            .jp => self.jp,
        };
    }

    pub fn isEmpty(self: *const BiosSet) bool {
        return self.us == null and self.eu == null and self.jp == null;
    }

    /// Pick the BIOS region to boot with. Precedence: explicit user
    /// preference (must be present), then the disc's own region, then any
    /// available image in US/EU/JP order.
    pub fn selectForDisc(
        self: *const BiosSet,
        disc_region: ?BiosRegion,
        preferred: ?BiosRegion,
    ) error{BiosMissing}!BiosRegion {
        if (preferred) |p| {
            if (self.get(p) != null) return p;
            return error.BiosMissing;
        }
        if (disc_region) |d| {
            if (self.get(d) != null) return d;
        }
        inline for (.{ BiosRegion.us, BiosRegion.eu, BiosRegion.jp }) |r| {
            if (self.get(r) != null) return r;
        }
        return error.BiosMissing;
    }
};

/// Region of a disc from the security sector's country byte at 0x1F0
/// (Genesis-style: 'U' overseas NTSC, 'E' PAL, 'J' Japan). `sector0` is the
/// first 2048 bytes of user data.
pub fn discRegion(sector0: []const u8) ?BiosRegion {
    if (sector0.len <= 0x1F0) return null;
    return switch (sector0[0x1F0]) {
        'U', 'u', '4' => .us,
        'E', 'e', '8' => .eu,
        'J', 'j', '1' => .jp,
        else => null,
    };
}

const testing = std.testing;

test "validate accepts a 128KB image with SEGA header and rejects others" {
    var good = [_]u8{0} ** bios_size;
    @memcpy(good[0x100..0x104], "SEGA");
    try validate(&good);

    var short = [_]u8{0} ** 0x200;
    @memcpy(short[0x100..0x104], "SEGA");
    try testing.expectError(error.BiosWrongSize, validate(&short));

    const blank = [_]u8{0} ** bios_size;
    try testing.expectError(error.BiosMissingHeader, validate(&blank));
}

test "selectForDisc precedence: preference, then disc region, then any" {
    const us = [_]u8{1} ** 4;
    const jp = [_]u8{2} ** 4;
    const set = BiosSet{ .us = &us, .jp = &jp };

    // Explicit preference wins when present, errors when absent.
    try testing.expectEqual(BiosRegion.jp, try set.selectForDisc(.us, .jp));
    try testing.expectError(error.BiosMissing, set.selectForDisc(.us, .eu));

    // Disc region used when no preference.
    try testing.expectEqual(BiosRegion.jp, try set.selectForDisc(.jp, null));
    // Disc region not available: fall back to any, US first.
    try testing.expectEqual(BiosRegion.us, try set.selectForDisc(.eu, null));
    // Unknown disc region: any available.
    try testing.expectEqual(BiosRegion.us, try set.selectForDisc(null, null));

    const empty = BiosSet{};
    try testing.expect(empty.isEmpty());
    try testing.expectError(error.BiosMissing, empty.selectForDisc(.us, null));
}

test "disc region from security sector country byte" {
    var sector = [_]u8{0} ** 2048;
    sector[0x1F0] = 'U';
    try testing.expectEqual(BiosRegion.us, discRegion(&sector).?);
    sector[0x1F0] = 'E';
    try testing.expectEqual(BiosRegion.eu, discRegion(&sector).?);
    sector[0x1F0] = 'J';
    try testing.expectEqual(BiosRegion.jp, discRegion(&sector).?);
    sector[0x1F0] = ' ';
    try testing.expect(discRegion(&sector) == null);
    try testing.expect(discRegion(sector[0..0x100]) == null);
}

test "region names and default file names" {
    try testing.expectEqualStrings("bios_CD_U.bin", BiosRegion.us.defaultFileName());
    try testing.expectEqual(BiosRegion.eu, BiosRegion.parse("E").?);
    try testing.expect(BiosRegion.parse("xx") == null);
}
