const std = @import("std");

/// Compute the per-ROM data directory path.
/// For a ROM at "roms/sonic.md", returns "roms/sonic/".
/// The directory is created if it does not exist.
pub fn ensureRomDataDir(allocator: std.mem.Allocator, rom_path: []const u8) ![]u8 {
    const dir_name = std.fs.path.stem(rom_path);
    const parent = std.fs.path.dirname(rom_path);

    const dir_path = if (parent) |p|
        try std.fmt.allocPrint(allocator, "{s}{c}{s}", .{ p, std.fs.path.sep, dir_name })
    else
        try allocator.dupe(u8, dir_name);
    errdefer allocator.free(dir_path);

    std.fs.cwd().makePath(dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    return dir_path;
}

/// Build a path inside the ROM data directory: "roms/sonic/<filename>"
pub fn romDataPath(allocator: std.mem.Allocator, rom_path: []const u8, filename: []const u8) ![]u8 {
    const dir = try ensureRomDataDir(allocator, rom_path);
    defer allocator.free(dir);
    return std.fmt.allocPrint(allocator, "{s}{c}{s}", .{ dir, std.fs.path.sep, filename });
}

/// Build the SRAM save path: "roms/sonic/sonic.sav"
pub fn sramPath(allocator: std.mem.Allocator, rom_path: []const u8) ![]u8 {
    const stem = std.fs.path.stem(rom_path);
    var filename_buf: [256]u8 = undefined;
    const filename = std.fmt.bufPrint(&filename_buf, "{s}.sav", .{stem}) catch return error.NameTooLong;
    return romDataPath(allocator, rom_path, filename);
}

/// Build a state file path: "roms/sonic/slot1.state"
pub fn statePath(allocator: std.mem.Allocator, rom_path: []const u8, slot: u8) ![]u8 {
    var filename_buf: [64]u8 = undefined;
    const filename = std.fmt.bufPrint(&filename_buf, "slot{d}.state", .{slot}) catch return error.NameTooLong;
    return romDataPath(allocator, rom_path, filename);
}

/// Build a default (non-slotted) state path: "roms/sonic/quick.state"
pub fn quickStatePath(allocator: std.mem.Allocator, rom_path: []const u8) ![]u8 {
    return romDataPath(allocator, rom_path, "quick.state");
}

/// Find the next available numbered output path: "roms/sonic/sonic_001.gif"
pub fn nextOutputPath(rom_path: []const u8, extension: []const u8) ?[256]u8 {
    const stem = std.fs.path.stem(rom_path);
    const parent = std.fs.path.dirname(rom_path);

    var result: [256]u8 = [_]u8{0} ** 256;
    var i: u32 = 1;
    while (i <= 999) : (i += 1) {
        const name = if (parent) |p|
            std.fmt.bufPrint(&result, "{s}{c}{s}{c}{s}_{d:0>3}.{s}", .{
                p,           std.fs.path.sep,
                stem,        std.fs.path.sep,
                stem,        i,
                extension,
            }) catch return null
        else
            std.fmt.bufPrint(&result, "{s}{c}{s}_{d:0>3}.{s}", .{
                stem,        std.fs.path.sep,
                stem,        i,
                extension,
            }) catch return null;
        result[name.len] = 0;
        std.fs.cwd().access(name, .{}) catch {
            return result;
        };
    }
    return null;
}

test "sram path puts save inside rom data directory" {
    const path = try sramPath(std.testing.allocator, "roms/sonic.md");
    defer std.testing.allocator.free(path);
    try std.testing.expect(std.mem.endsWith(u8, path, "sonic/sonic.sav") or
        std.mem.endsWith(u8, path, "sonic\\sonic.sav"));
}

test "state path puts slot inside rom data directory" {
    const path = try statePath(std.testing.allocator, "roms/sonic.md", 2);
    defer std.testing.allocator.free(path);
    try std.testing.expect(std.mem.endsWith(u8, path, "sonic/slot2.state") or
        std.mem.endsWith(u8, path, "sonic\\slot2.state"));
}
