const std = @import("std");

/// Shorten a filename for display. Names longer than `max_len` are truncated
/// with an ellipsis in the middle: "Adventures...02).gg"
pub fn displayName(name: []const u8, buf: []u8, max_len: usize) []const u8 {
    if (name.len <= max_len) return name;
    if (max_len < 5) {
        // Too small for ellipsis; just truncate
        const n = @min(name.len, buf.len);
        @memcpy(buf[0..n], name[0..n]);
        return buf[0..@min(n, max_len)];
    }
    const ellipsis = "...";
    const prefix_len = (max_len - ellipsis.len) / 2;
    const suffix_len = max_len - ellipsis.len - prefix_len;
    const total = prefix_len + ellipsis.len + suffix_len;
    if (total > buf.len) return name;
    @memcpy(buf[0..prefix_len], name[0..prefix_len]);
    @memcpy(buf[prefix_len..][0..ellipsis.len], ellipsis);
    @memcpy(buf[prefix_len + ellipsis.len ..][0..suffix_len], name[name.len - suffix_len ..]);
    return buf[0..total];
}

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
                p,         std.fs.path.sep,
                stem,      std.fs.path.sep,
                stem,      i,
                extension,
            }) catch return null
        else
            std.fmt.bufPrint(&result, "{s}{c}{s}_{d:0>3}.{s}", .{
                stem,      std.fs.path.sep,
                stem,      i,
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

test "displayName returns short names unchanged" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("sonic.md", displayName("sonic.md", &buf, 32));
}

test "displayName truncates long names with ellipsis" {
    var buf: [64]u8 = undefined;
    const long = "Adventures of Batman & Robin, The (USA).gg";
    const short = displayName(long, &buf, 20);
    try std.testing.expectEqual(@as(usize, 20), short.len);
    // Should start with prefix and end with suffix
    try std.testing.expect(std.mem.startsWith(u8, short, "Adventu"));
    try std.testing.expect(std.mem.endsWith(u8, short, "USA).gg"));
    try std.testing.expect(std.mem.indexOf(u8, short, "...") != null);
}

test "state path puts slot inside rom data directory" {
    const path = try statePath(std.testing.allocator, "roms/sonic.md", 2);
    defer std.testing.allocator.free(path);
    try std.testing.expect(std.mem.endsWith(u8, path, "sonic/slot2.state") or
        std.mem.endsWith(u8, path, "sonic\\slot2.state"));
}
