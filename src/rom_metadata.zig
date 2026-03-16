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
    std.debug.print("Reset Vectors: SSP={X:0>8} PC={X:0>8}\n", .{
        metadata.reset_stack_pointer,
        metadata.reset_program_counter,
    });
}
