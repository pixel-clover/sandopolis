const std = @import("std");
const AudioOutput = @import("audio/output.zig").AudioOutput;
const FrontendConfig = @import("frontend/config.zig").FrontendConfig;
const FontFace = @import("frontend/config.zig").FontFace;
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
    try w.writeAll("\n# Audio\n");
    try w.print("audio.mode = {s}\n", .{frontend.audio_render_mode.name()});
    try w.print("audio.queue_ms = {d}\n", .{frontend.audio_queue_ms});
    try w.print("font_face = {s}\n", .{frontend.font_face.name()});

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
    } else if (std.mem.eql(u8, key, "audio.mode") or std.mem.eql(u8, key, "audio_mode") or std.mem.eql(u8, key, "audio_render_mode")) {
        config.audio_render_mode = AudioOutput.RenderMode.parse(value) catch return;
    } else if (std.mem.eql(u8, key, "audio.queue_ms") or std.mem.eql(u8, key, "audio_queue_ms")) {
        const parsed = std.fmt.parseUnsigned(u16, value, 10) catch return;
        config.audio_queue_ms = AudioOutput.clampQueueBudgetMs(parsed);
    } else if (std.mem.eql(u8, key, "font_face")) {
        config.font_face = FontFace.parse(value) catch return;
    } else if (std.mem.eql(u8, key, "last_open_dir")) {
        config.last_open_dir.set(value);
    } else if (std.mem.eql(u8, key, "recent_rom")) {
        config.appendRecentRom(value);
    }
}

test "unified config round-trips whole-pixel scale and font face" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);
    const config_path = try std.fs.path.join(allocator, &.{ dir_path, "sandopolis.cfg" });
    defer allocator.free(config_path);

    var frontend = FrontendConfig{};
    frontend.video_scale_mode = .whole_pixels;
    frontend.font_face = .jbm_thin;
    frontend.audio_render_mode = .unfiltered_mix;
    frontend.audio_queue_ms = 80;

    const bindings = InputBindings.Bindings.defaults();
    try save(&frontend, &bindings, config_path);

    const loaded = try load(allocator, config_path);
    try std.testing.expectEqual(VideoScaleMode.whole_pixels, loaded.frontend.video_scale_mode);
    try std.testing.expectEqual(FontFace.jbm_thin, loaded.frontend.font_face);
    try std.testing.expectEqual(AudioOutput.RenderMode.unfiltered_mix, loaded.frontend.audio_render_mode);
    try std.testing.expectEqual(@as(u16, 80), loaded.frontend.audio_queue_ms);
}

test "unified config accepts legacy whole video-scale token" {
    var frontend = FrontendConfig{};
    parseFrontendLine(&frontend, "video.scale = whole");
    try std.testing.expectEqual(VideoScaleMode.whole_pixels, frontend.video_scale_mode);
}

test "unified config accepts legacy audio frontend keys" {
    var frontend = FrontendConfig{};
    parseFrontendLine(&frontend, "audio_mode = psg-only");
    parseFrontendLine(&frontend, "audio_queue_ms = 100");
    try std.testing.expectEqual(AudioOutput.RenderMode.psg_only, frontend.audio_render_mode);
    try std.testing.expectEqual(@as(u16, 100), frontend.audio_queue_ms);
}
