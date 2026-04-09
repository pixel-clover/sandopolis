const std = @import("std");
const zsdl3 = @import("zsdl3");
const AudioOutput = @import("../audio/output.zig").AudioOutput;

// Configuration constants
pub const config_file_name = "sandopolis_frontend.cfg";
pub const recent_rom_limit: usize = 8;

// Path storage for config values
pub const PathCopy = struct {
    len: usize = 0,
    bytes: [std.fs.max_path_bytes]u8 = [_]u8{0} ** std.fs.max_path_bytes,

    pub fn slice(self: *const PathCopy) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn set(self: *PathCopy, path: []const u8) void {
        self.* = .{};
        const copy_len = @min(path.len, self.bytes.len);
        @memcpy(self.bytes[0..copy_len], path[0..copy_len]);
        self.len = copy_len;
    }
};

// Video display modes
pub const VideoAspectMode = enum {
    stretch,
    four_three,
    square_pixels,

    pub fn name(self: VideoAspectMode) []const u8 {
        return switch (self) {
            .stretch => "stretch",
            .four_three => "4:3",
            .square_pixels => "square",
        };
    }

    pub fn label(self: VideoAspectMode) []const u8 {
        return switch (self) {
            .stretch => "STRETCH",
            .four_three => "4:3",
            .square_pixels => "SQUARE",
        };
    }

    pub fn configValue(self: VideoAspectMode) []const u8 {
        return switch (self) {
            .stretch => "stretch",
            .four_three => "4:3",
            .square_pixels => "square",
        };
    }

    pub fn parse(value: []const u8) error{InvalidVideoAspect}!VideoAspectMode {
        if (std.mem.eql(u8, value, "stretch")) return .stretch;
        if (std.mem.eql(u8, value, "4:3")) return .four_three;
        if (std.mem.eql(u8, value, "square")) return .square_pixels;
        return error.InvalidVideoAspect;
    }

    pub fn cycle(self: VideoAspectMode, delta: isize) VideoAspectMode {
        const modes = [_]VideoAspectMode{ .stretch, .four_three, .square_pixels };
        var index: isize = 0;
        for (modes, 0..) |candidate, i| {
            if (candidate == self) {
                index = @intCast(i);
                break;
            }
        }
        index += delta;
        const count: isize = @intCast(modes.len);
        while (index < 0) index += count;
        while (index >= count) index -= count;
        return modes[@intCast(index)];
    }
};

pub const VideoScaleMode = enum {
    fit,
    whole_pixels,

    pub fn name(self: VideoScaleMode) []const u8 {
        return switch (self) {
            .fit => "fit",
            .whole_pixels => "whole_pixels",
        };
    }

    pub fn label(self: VideoScaleMode) []const u8 {
        return switch (self) {
            .fit => "FIT",
            .whole_pixels => "WHOLE",
        };
    }

    pub fn configValue(self: VideoScaleMode) []const u8 {
        return switch (self) {
            .fit => "fit",
            .whole_pixels => "whole_pixels",
        };
    }

    pub fn parse(value: []const u8) error{InvalidVideoScale}!VideoScaleMode {
        if (std.mem.eql(u8, value, "fit")) return .fit;
        if (std.mem.eql(u8, value, "whole_pixels") or std.mem.eql(u8, value, "whole")) return .whole_pixels;
        return error.InvalidVideoScale;
    }

    pub fn cycle(self: VideoScaleMode, delta: isize) VideoScaleMode {
        const modes = [_]VideoScaleMode{ .fit, .whole_pixels };
        var index: isize = 0;
        for (modes, 0..) |candidate, i| {
            if (candidate == self) {
                index = @intCast(i);
                break;
            }
        }
        index += delta;
        const count: isize = @intCast(modes.len);
        while (index < 0) index += count;
        while (index >= count) index -= count;
        return modes[@intCast(index)];
    }
};

pub const FontFace = enum {
    jbm_regular,
    jbm_light,
    jbm_medium,
    jbm_thin,

    pub fn name(self: FontFace) []const u8 {
        return switch (self) {
            .jbm_regular => "jbm_regular",
            .jbm_light => "jbm_light",
            .jbm_medium => "jbm_medium",
            .jbm_thin => "jbm_thin",
        };
    }

    pub fn label(self: FontFace) []const u8 {
        return switch (self) {
            .jbm_regular => "JBM REGULAR",
            .jbm_light => "JBM LIGHT",
            .jbm_medium => "JBM MEDIUM",
            .jbm_thin => "JBM THIN",
        };
    }

    pub fn parse(value: []const u8) error{InvalidFontFace}!FontFace {
        if (std.mem.eql(u8, value, "jbm_regular")) return .jbm_regular;
        if (std.mem.eql(u8, value, "jbm_light")) return .jbm_light;
        if (std.mem.eql(u8, value, "jbm_medium")) return .jbm_medium;
        if (std.mem.eql(u8, value, "jbm_thin")) return .jbm_thin;
        return error.InvalidFontFace;
    }

    pub fn cycle(self: FontFace, delta: isize) FontFace {
        const faces = [_]FontFace{ .jbm_regular, .jbm_light, .jbm_medium, .jbm_thin };
        var index: isize = 0;
        for (faces, 0..) |candidate, i| {
            if (candidate == self) {
                index = @intCast(i);
                break;
            }
        }
        index += delta;
        const count: isize = @intCast(faces.len);
        while (index < 0) index += count;
        while (index >= count) index -= count;
        return faces[@intCast(index)];
    }
};

// Frontend configuration
pub const FrontendConfig = struct {
    recent_rom_count: usize = 0,
    recent_roms: [recent_rom_limit]PathCopy = [_]PathCopy{.{}} ** recent_rom_limit,
    last_open_dir: PathCopy = .{},
    video_aspect_mode: VideoAspectMode = .stretch,
    video_scale_mode: VideoScaleMode = .fit,
    font_face: FontFace = .jbm_regular,
    audio_render_mode: AudioOutput.RenderMode = .normal,
    audio_queue_ms: u16 = AudioOutput.default_queue_budget_ms,
    psg_volume: u8 = 150,
    eq_enabled: bool = false,
    eq_low: u8 = 100,
    eq_mid: u8 = 100,
    eq_high: u8 = 100,

    pub fn parseContents(contents: []const u8) !FrontendConfig {
        var config = FrontendConfig{};
        var line_iter = std.mem.splitScalar(u8, contents, '\n');
        while (line_iter.next()) |raw_line| {
            const line = trimConfigLine(raw_line);
            if (line.len == 0) continue;

            const separator = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const lhs = std.mem.trim(u8, line[0..separator], " \t\r");
            const rhs = std.mem.trim(u8, line[separator + 1 ..], " \t\r");
            if (rhs.len == 0) continue;

            if (std.ascii.eqlIgnoreCase(lhs, "last_open_dir")) {
                config.setLastOpenDir(rhs);
            } else if (std.ascii.eqlIgnoreCase(lhs, "video_aspect")) {
                config.video_aspect_mode = VideoAspectMode.parse(rhs) catch config.video_aspect_mode;
            } else if (std.ascii.eqlIgnoreCase(lhs, "video_scale")) {
                config.video_scale_mode = VideoScaleMode.parse(rhs) catch config.video_scale_mode;
            } else if (std.ascii.eqlIgnoreCase(lhs, "font_face")) {
                config.font_face = FontFace.parse(rhs) catch config.font_face;
            } else if (std.ascii.eqlIgnoreCase(lhs, "audio_mode") or std.ascii.eqlIgnoreCase(lhs, "audio_render_mode") or std.ascii.eqlIgnoreCase(lhs, "audio.mode")) {
                config.audio_render_mode = AudioOutput.RenderMode.parse(rhs) catch config.audio_render_mode;
            } else if (std.ascii.eqlIgnoreCase(lhs, "audio_queue_ms") or std.ascii.eqlIgnoreCase(lhs, "audio.queue_ms")) {
                const parsed = std.fmt.parseUnsigned(u16, rhs, 10) catch config.audio_queue_ms;
                config.audio_queue_ms = AudioOutput.clampQueueBudgetMs(parsed);
            } else if (std.ascii.eqlIgnoreCase(lhs, "psg_volume")) {
                const parsed = std.fmt.parseUnsigned(u8, rhs, 10) catch config.psg_volume;
                config.psg_volume = @min(parsed, 200);
            } else if (std.ascii.eqlIgnoreCase(lhs, "eq_enabled")) {
                config.eq_enabled = std.ascii.eqlIgnoreCase(rhs, "true") or std.mem.eql(u8, rhs, "1");
            } else if (std.ascii.eqlIgnoreCase(lhs, "eq_low")) {
                config.eq_low = std.fmt.parseUnsigned(u8, rhs, 10) catch config.eq_low;
            } else if (std.ascii.eqlIgnoreCase(lhs, "eq_mid")) {
                config.eq_mid = std.fmt.parseUnsigned(u8, rhs, 10) catch config.eq_mid;
            } else if (std.ascii.eqlIgnoreCase(lhs, "eq_high")) {
                config.eq_high = std.fmt.parseUnsigned(u8, rhs, 10) catch config.eq_high;
            } else if (std.ascii.eqlIgnoreCase(lhs, "recent_rom")) {
                config.appendRecentRom(rhs);
            }
        }

        return config;
    }

    pub fn loadFromFile(allocator: std.mem.Allocator, path: []const u8) !FrontendConfig {
        const file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
            error.FileNotFound => return .{},
            else => return err,
        };
        defer file.close();

        const contents = try file.readToEndAlloc(allocator, 64 * 1024);
        defer allocator.free(contents);
        return try FrontendConfig.parseContents(contents);
    }

    pub fn writeContents(self: *const FrontendConfig, writer: *std.Io.Writer) !void {
        if (self.last_open_dir.len != 0) {
            try writer.print("last_open_dir = {s}\n", .{self.last_open_dir.slice()});
        }
        try writer.print("video_aspect = {s}\n", .{self.video_aspect_mode.name()});
        try writer.print("video_scale = {s}\n", .{self.video_scale_mode.name()});
        try writer.print("font_face = {s}\n", .{self.font_face.name()});
        try writer.print("audio_mode = {s}\n", .{self.audio_render_mode.name()});
        try writer.print("audio_queue_ms = {d}\n", .{self.audio_queue_ms});
        try writer.print("psg_volume = {d}\n", .{self.psg_volume});
        try writer.print("eq_enabled = {s}\n", .{if (self.eq_enabled) "true" else "false"});
        try writer.print("eq_low = {d}\n", .{self.eq_low});
        try writer.print("eq_mid = {d}\n", .{self.eq_mid});
        try writer.print("eq_high = {d}\n", .{self.eq_high});
        for (self.recent_roms[0..self.recent_rom_count]) |path| {
            try writer.print("recent_rom = {s}\n", .{path.slice()});
        }
    }

    pub fn saveToFile(self: *const FrontendConfig, path: []const u8) !void {
        // Write to a temporary file first, then atomically rename over the
        // real config so a crash mid-write cannot lose the previous config.
        var tmp_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const tmp_path = std.fmt.bufPrint(&tmp_path_buf, "{s}.tmp", .{path}) catch
            return error.NameTooLong;
        {
            var file = try std.fs.cwd().createFile(tmp_path, .{ .truncate = true });
            defer file.close();
            var buffer: [4096]u8 = undefined;
            var writer = file.writer(&buffer);
            try self.writeContents(&writer.interface);
            try writer.interface.flush();
        }
        std.fs.cwd().rename(tmp_path, path) catch {
            // Rename failed (e.g. cross-device); fall back to direct write.
            std.fs.cwd().deleteFile(tmp_path) catch {};
            var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
            defer file.close();
            var buffer: [4096]u8 = undefined;
            var writer = file.writer(&buffer);
            try self.writeContents(&writer.interface);
            try writer.interface.flush();
        };
    }

    pub fn recentRom(self: *const FrontendConfig, index: usize) []const u8 {
        std.debug.assert(index < self.recent_rom_count);
        return self.recent_roms[index].slice();
    }

    pub fn noteLoadedRom(self: *FrontendConfig, path: []const u8) void {
        self.setLastOpenDirFromPath(path);
        self.noteRecentRom(path);
    }

    pub fn removeRecentRom(self: *FrontendConfig, index: usize) void {
        if (index >= self.recent_rom_count) return;
        var next = index;
        while (next + 1 < self.recent_rom_count) : (next += 1) {
            self.recent_roms[next] = self.recent_roms[next + 1];
        }
        self.recent_rom_count -= 1;
        self.recent_roms[self.recent_rom_count] = .{};
    }

    fn noteRecentRom(self: *FrontendConfig, path: []const u8) void {
        if (path.len == 0 or path.len > std.fs.max_path_bytes) return;

        var target = PathCopy{};
        target.set(path);
        const previous_entries = self.recent_roms;
        const previous_count = self.recent_rom_count;
        self.recent_roms = [_]PathCopy{.{}} ** recent_rom_limit;
        self.recent_roms[0] = target;
        var next_count: usize = 1;
        for (previous_entries[0..previous_count]) |entry| {
            if (std.mem.eql(u8, entry.slice(), path)) continue;
            if (next_count >= recent_rom_limit) break;
            self.recent_roms[next_count] = entry;
            next_count += 1;
        }
        self.recent_rom_count = next_count;
    }

    pub fn appendRecentRom(self: *FrontendConfig, path: []const u8) void {
        if (path.len == 0 or path.len > std.fs.max_path_bytes) return;
        for (self.recent_roms[0..self.recent_rom_count]) |entry| {
            if (std.mem.eql(u8, entry.slice(), path)) return;
        }
        if (self.recent_rom_count >= recent_rom_limit) return;
        self.recent_roms[self.recent_rom_count].set(path);
        self.recent_rom_count += 1;
    }

    pub fn setLastOpenDirFromPath(self: *FrontendConfig, path: []const u8) void {
        if (std.fs.path.dirname(path)) |dir| {
            self.setLastOpenDir(dir);
        } else {
            self.setLastOpenDir(".");
        }
    }

    pub fn setLastOpenDir(self: *FrontendConfig, path: []const u8) void {
        if (path.len == 0 or path.len > std.fs.max_path_bytes) return;
        self.last_open_dir.set(path);
    }
};

fn trimConfigLine(raw_line: []const u8) []const u8 {
    const line = std.mem.trim(u8, raw_line, " \t\r");
    if (line.len == 0) return "";
    if (line[0] == '#' or line[0] == ';') return "";
    return line;
}

pub fn defaultConfigPath(allocator: std.mem.Allocator) ![]u8 {
    const env_path = std.process.getEnvVarOwned(allocator, "SANDOPOLIS_FRONTEND_CONFIG") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    if (env_path) |path| return path;
    return try allocator.dupe(u8, config_file_name);
}

// Compute video destination rectangle based on aspect and scale modes
pub fn computeVideoDestinationRect(
    viewport: zsdl3.Rect,
    source_width: u16,
    source_height: i32,
    aspect_mode: VideoAspectMode,
    scale_mode: VideoScaleMode,
) zsdl3.FRect {
    const viewport_w = @as(f32, @floatFromInt(@max(viewport.w, 0)));
    const viewport_h = @as(f32, @floatFromInt(@max(viewport.h, 0)));
    if (viewport_w == 0 or viewport_h == 0 or source_height <= 0) {
        return .{ .x = 0, .y = 0, .w = viewport_w, .h = viewport_h };
    }
    if (aspect_mode == .stretch) {
        return .{ .x = 0, .y = 0, .w = viewport_w, .h = viewport_h };
    }

    const nominal_h = @as(f32, @floatFromInt(source_height));
    const nominal_w = switch (aspect_mode) {
        .stretch => unreachable,
        .four_three => nominal_h * (4.0 / 3.0),
        .square_pixels => @as(f32, @floatFromInt(source_width)),
    };

    var scale = @min(viewport_w / nominal_w, viewport_h / nominal_h);
    if (scale_mode == .whole_pixels and scale >= 1.0) {
        const whole = @floor(scale);
        if (whole >= 1.0) scale = whole;
    }

    const dest_w = nominal_w * scale;
    const dest_h = nominal_h * scale;
    return .{
        .x = (viewport_w - dest_w) * 0.5,
        .y = (viewport_h - dest_h) * 0.5,
        .w = dest_w,
        .h = dest_h,
    };
}

const t = @import("std").testing;

test "VideoAspectMode parse accepts valid modes" {
    try t.expectEqual(VideoAspectMode.stretch, try VideoAspectMode.parse("stretch"));
    try t.expectEqual(VideoAspectMode.four_three, try VideoAspectMode.parse("4:3"));
    try t.expectEqual(VideoAspectMode.square_pixels, try VideoAspectMode.parse("square"));
    try t.expectError(error.InvalidVideoAspect, VideoAspectMode.parse("invalid"));
}

test "VideoAspectMode cycle wraps around" {
    try t.expectEqual(VideoAspectMode.four_three, VideoAspectMode.stretch.cycle(1));
    try t.expectEqual(VideoAspectMode.square_pixels, VideoAspectMode.stretch.cycle(-1));
    try t.expectEqual(VideoAspectMode.stretch, VideoAspectMode.stretch.cycle(3));
    try t.expectEqual(VideoAspectMode.stretch, VideoAspectMode.stretch.cycle(0));
}

test "VideoScaleMode parse accepts valid modes and alias" {
    try t.expectEqual(VideoScaleMode.fit, try VideoScaleMode.parse("fit"));
    try t.expectEqual(VideoScaleMode.whole_pixels, try VideoScaleMode.parse("whole_pixels"));
    try t.expectEqual(VideoScaleMode.whole_pixels, try VideoScaleMode.parse("whole"));
    try t.expectError(error.InvalidVideoScale, VideoScaleMode.parse("bad"));
}

test "VideoScaleMode cycle wraps between two modes" {
    try t.expectEqual(VideoScaleMode.whole_pixels, VideoScaleMode.fit.cycle(1));
    try t.expectEqual(VideoScaleMode.whole_pixels, VideoScaleMode.fit.cycle(-1));
    try t.expectEqual(VideoScaleMode.fit, VideoScaleMode.fit.cycle(2));
}

test "FontFace parse accepts all faces" {
    try t.expectEqual(FontFace.jbm_regular, try FontFace.parse("jbm_regular"));
    try t.expectEqual(FontFace.jbm_light, try FontFace.parse("jbm_light"));
    try t.expectEqual(FontFace.jbm_medium, try FontFace.parse("jbm_medium"));
    try t.expectEqual(FontFace.jbm_thin, try FontFace.parse("jbm_thin"));
    try t.expectError(error.InvalidFontFace, FontFace.parse("comic_sans"));
}

test "FontFace cycle wraps through all four faces" {
    try t.expectEqual(FontFace.jbm_light, FontFace.jbm_regular.cycle(1));
    try t.expectEqual(FontFace.jbm_thin, FontFace.jbm_regular.cycle(-1));
    try t.expectEqual(FontFace.jbm_regular, FontFace.jbm_regular.cycle(4));
}

test "PathCopy set truncates long paths" {
    var pc = PathCopy{};
    pc.set("short.md");
    try t.expectEqualStrings("short.md", pc.slice());

    // Fill to capacity
    const max = std.fs.max_path_bytes;
    var long: [max + 10]u8 = undefined;
    @memset(&long, 'x');
    pc.set(&long);
    try t.expectEqual(max, pc.slice().len);
}
