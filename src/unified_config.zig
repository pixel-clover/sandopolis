const std = @import("std");
const FrontendConfig = @import("frontend/config.zig").FrontendConfig;
const VideoAspectMode = @import("frontend/config.zig").VideoAspectMode;
const VideoScaleMode = @import("frontend/config.zig").VideoScaleMode;
const InputBindings = @import("input/mapping.zig");

pub const Result = struct {
    frontend: FrontendConfig,
    bindings: InputBindings.Bindings,
};

/// Load both frontend config and input bindings from the unified config file.
/// If the file doesn't exist, returns defaults for both.
pub fn load(allocator: std.mem.Allocator, path: []const u8) !Result {
    var frontend = FrontendConfig{};
    var bindings = InputBindings.Bindings.defaults();

    const file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return .{ .frontend = frontend, .bindings = bindings },
        else => return err,
    };
    defer file.close();

    const contents = try file.readToEndAlloc(allocator, 256 * 1024);
    defer allocator.free(contents);

    var iter = std.mem.splitScalar(u8, contents, '\n');
    while (iter.next()) |raw_line| {
        const line = trimLine(raw_line);
        if (line.len == 0) continue;

        // Input bindings
        if (std.mem.startsWith(u8, line, "keyboard.") or
            std.mem.startsWith(u8, line, "gamepad.") or
            std.mem.startsWith(u8, line, "hotkey.") or
            std.mem.startsWith(u8, line, "controller.") or
            std.mem.startsWith(u8, line, "analog."))
        {
            bindings.applyConfigLine(line);
            continue;
        }

        // Frontend settings
        parseFrontendLine(&frontend, line);
    }

    return .{ .frontend = frontend, .bindings = bindings };
}

/// Save both frontend config and input bindings to the unified config file.
pub fn save(
    frontend: *const FrontendConfig,
    bindings: *const InputBindings.Bindings,
    path: []const u8,
) !void {
    const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();

    var buf: [4096]u8 = undefined;
    var writer = file.writer(&buf);
    const w = &writer.interface;

    try w.writeAll("# Sandopolis configuration\n");
    try w.writeAll("# Delete this file to reset all settings to defaults.\n\n");

    // Frontend settings
    try w.writeAll("# Video\n");
    try w.print("video.aspect = {s}\n", .{frontend.video_aspect_mode.configValue()});
    try w.print("video.scale = {s}\n", .{frontend.video_scale_mode.configValue()});

    if (frontend.last_open_dir.len > 0) {
        try w.print("\nlast_open_dir = {s}\n", .{frontend.last_open_dir.slice()});
    }

    if (frontend.recent_rom_count > 0) {
        try w.writeAll("\n# Recent ROMs\n");
        for (0..frontend.recent_rom_count) |i| {
            try w.print("recent_rom = {s}\n", .{frontend.recentRom(i)});
        }
    }

    try w.writeByte('\n');

    // Input bindings (uses existing writeContents)
    try bindings.writeContents(w);

    try w.flush();
}

fn trimLine(raw: []const u8) []const u8 {
    const line = std.mem.trim(u8, raw, " \t\r");
    if (line.len == 0) return "";
    if (line[0] == '#' or line[0] == ';') return "";
    return line;
}

fn parseFrontendLine(config: *FrontendConfig, line: []const u8) void {
    const eq_pos = std.mem.indexOfScalar(u8, line, '=') orelse return;
    const key = std.mem.trim(u8, line[0..eq_pos], " \t");
    const value = std.mem.trim(u8, line[eq_pos + 1 ..], " \t");

    if (std.mem.eql(u8, key, "video.aspect") or std.mem.eql(u8, key, "video_aspect")) {
        config.video_aspect_mode = VideoAspectMode.parse(value) catch return;
    } else if (std.mem.eql(u8, key, "video.scale") or std.mem.eql(u8, key, "video_scale")) {
        config.video_scale_mode = VideoScaleMode.parse(value) catch return;
    } else if (std.mem.eql(u8, key, "last_open_dir")) {
        config.last_open_dir.set(value);
    } else if (std.mem.eql(u8, key, "recent_rom")) {
        config.appendRecentRom(value);
    }
}
