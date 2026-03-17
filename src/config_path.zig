const std = @import("std");
const builtin = @import("builtin");

pub const config_file_name = "sandopolis.cfg";
pub const app_name = "sandopolis";

/// Resolve the unified config file path.
/// Priority:
///   1. SANDOPOLIS_CONFIG environment variable (explicit override)
///   2. Platform-specific app data directory:
///      - Linux:   $XDG_CONFIG_HOME/sandopolis/sandopolis.cfg  (default ~/.config)
///      - macOS:   ~/Library/Application Support/sandopolis/sandopolis.cfg
///      - Windows: %APPDATA%/sandopolis/sandopolis.cfg
///   3. Current working directory: ./sandopolis.cfg
pub fn resolveConfigPath(allocator: std.mem.Allocator) ![]u8 {
    // 1. Explicit environment variable
    if (getEnvOwned(allocator, "SANDOPOLIS_CONFIG")) |path| return path;

    // 2. Platform-specific app data directory
    if (platformConfigDir(allocator)) |dir| {
        defer allocator.free(dir);
        std.fs.cwd().makePath(dir) catch {};
        return std.fmt.allocPrint(allocator, "{s}{c}{s}", .{ dir, std.fs.path.sep, config_file_name });
    }

    // 3. Fallback: current working directory
    return allocator.dupe(u8, config_file_name);
}

/// Return the platform-specific config directory for the app, or null if unavailable.
fn platformConfigDir(allocator: std.mem.Allocator) ?[]u8 {
    if (builtin.os.tag == .windows) {
        if (getEnvOwned(allocator, "APPDATA")) |appdata| {
            defer allocator.free(appdata);
            return std.fmt.allocPrint(allocator, "{s}{c}{s}", .{ appdata, std.fs.path.sep, app_name }) catch null;
        }
        return null;
    }

    if (builtin.os.tag == .macos) {
        if (getEnvOwned(allocator, "HOME")) |home| {
            defer allocator.free(home);
            return std.fmt.allocPrint(allocator, "{s}/Library/Application Support/{s}", .{ home, app_name }) catch null;
        }
        return null;
    }

    // Linux and other POSIX: use XDG_CONFIG_HOME, default to ~/.config
    if (getEnvOwned(allocator, "XDG_CONFIG_HOME")) |xdg| {
        defer allocator.free(xdg);
        return std.fmt.allocPrint(allocator, "{s}{c}{s}", .{ xdg, std.fs.path.sep, app_name }) catch null;
    }
    if (getEnvOwned(allocator, "HOME")) |home| {
        defer allocator.free(home);
        return std.fmt.allocPrint(allocator, "{s}/.config/{s}", .{ home, app_name }) catch null;
    }
    return null;
}

fn getEnvOwned(allocator: std.mem.Allocator, name: []const u8) ?[]u8 {
    return std.process.getEnvVarOwned(allocator, name) catch null;
}

test "resolve config path returns a non-empty string" {
    const path = try resolveConfigPath(std.testing.allocator);
    defer std.testing.allocator.free(path);
    try std.testing.expect(path.len > 0);
    try std.testing.expect(std.mem.endsWith(u8, path, config_file_name));
}
