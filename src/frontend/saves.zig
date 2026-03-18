const std = @import("std");
const Vdp = @import("../video/vdp.zig").Vdp;
const StateFile = @import("../state_file.zig");
const rom_paths = @import("../rom_paths.zig");
const Machine = @import("../machine.zig").Machine;
const config = @import("config.zig");

// Save state preview constants
pub const preview_width: usize = 80;
pub const preview_height: usize = 56;
pub const preview_pixel_count: usize = preview_width * preview_height;
pub const preview_magic = [_]u8{ 'S', 'P', 'R', 'V' };
pub const preview_version: u16 = 1;

pub const slot_count: usize = StateFile.persistent_state_slot_count;

pub const Preview = struct {
    available: bool = false,
    pixels: [preview_pixel_count]u32 = [_]u32{0} ** preview_pixel_count,

    pub fn captureFromFramebuffer(framebuffer: []const u32) Preview {
        const source_height = framebuffer.len / Vdp.framebuffer_width;
        if (source_height == 0) return .{};

        var preview = Preview{ .available = true };
        for (0..preview_height) |preview_y| {
            const source_y = if (preview_height == 1)
                0
            else
                (preview_y * (source_height - 1)) / (preview_height - 1);
            for (0..preview_width) |preview_x| {
                const source_x = if (preview_width == 1)
                    0
                else
                    (preview_x * (Vdp.framebuffer_width - 1)) / (preview_width - 1);
                preview.pixels[preview_y * preview_width + preview_x] =
                    framebuffer[source_y * Vdp.framebuffer_width + source_x];
            }
        }
        return preview;
    }

    pub fn saveToFile(self: *const Preview, path: []const u8) !void {
        if (!self.available) return;

        var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
        defer file.close();

        var buffer: [4096]u8 = undefined;
        var file_writer = file.writer(&buffer);
        const writer = &file_writer.interface;
        try writer.writeAll(&preview_magic);
        try writer.writeInt(u16, preview_version, .little);
        try writer.writeInt(u16, @intCast(preview_width), .little);
        try writer.writeInt(u16, @intCast(preview_height), .little);
        for (self.pixels) |pixel| {
            try writer.writeInt(u32, pixel, .little);
        }
        try writer.flush();
    }

    pub fn loadFromFile(path: []const u8) !Preview {
        var file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        var buffer: [4096]u8 = undefined;
        var file_reader = file.reader(&buffer);
        const reader = &file_reader.interface;
        const magic = try reader.takeArray(preview_magic.len);
        if (!std.mem.eql(u8, magic, &preview_magic)) return error.InvalidStatePreview;

        const version = try reader.takeInt(u16, .little);
        if (version != preview_version) return error.UnsupportedStatePreviewVersion;

        const width = try reader.takeInt(u16, .little);
        const height = try reader.takeInt(u16, .little);
        if (width != preview_width or height != preview_height) {
            return error.InvalidStatePreviewDimensions;
        }

        var preview = Preview{ .available = true };
        for (0..preview_pixel_count) |index| {
            preview.pixels[index] = try reader.takeInt(u32, .little);
        }
        return preview;
    }
};

pub const SlotMetadata = struct {
    path: config.PathCopy = .{},
    exists: bool = false,
    size_bytes: u64 = 0,
    modified_ns: i128 = 0,
    preview: Preview = .{},
};

pub const ManagerState = struct {
    slots: [slot_count]SlotMetadata = [_]SlotMetadata{.{}} ** slot_count,

    pub fn refresh(
        self: *ManagerState,
        allocator: std.mem.Allocator,
        machine: *const Machine,
        explicit_state_path: ?[]const u8,
    ) !void {
        for (0..slot_count) |slot_index| {
            const slot_number: u8 = @intCast(slot_index + 1);
            const path = try resolvePersistentStatePath(allocator, machine, explicit_state_path, slot_number);
            defer allocator.free(path);

            var metadata = SlotMetadata{};
            metadata.path.set(path);

            const file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
                error.FileNotFound => {
                    self.slots[slot_index] = metadata;
                    continue;
                },
                else => return err,
            };
            defer file.close();

            const stat = try file.stat();
            metadata.exists = true;
            metadata.size_bytes = stat.size;
            metadata.modified_ns = stat.mtime;
            const preview_path = try resolvePreviewPath(allocator, path);
            defer allocator.free(preview_path);
            metadata.preview = Preview.loadFromFile(preview_path) catch |err| switch (err) {
                error.FileNotFound => .{},
                error.EndOfStream,
                error.InvalidStatePreview,
                error.InvalidStatePreviewDimensions,
                error.UnsupportedStatePreviewVersion,
                => blk: {
                    std.debug.print("Ignoring invalid state preview {s}: {s}\n", .{ preview_path, @errorName(err) });
                    break :blk .{};
                },
                else => return err,
            };
            self.slots[slot_index] = metadata;
        }
    }

    pub fn slotMetadata(self: *const ManagerState, slot: u8) *const SlotMetadata {
        const normalized = StateFile.normalizePersistentStateSlot(slot);
        return &self.slots[normalized - StateFile.default_persistent_state_slot];
    }
};

pub fn resolvePersistentStatePath(
    allocator: std.mem.Allocator,
    machine: *const Machine,
    explicit_state_path: ?[]const u8,
    persistent_state_slot: u8,
) ![]u8 {
    // Use per-ROM data directory when a ROM path is available
    if (explicit_state_path) |path| {
        return rom_paths.statePath(allocator, path, persistent_state_slot);
    }
    return StateFile.pathForMachineSlot(allocator, machine, persistent_state_slot);
}

pub fn previousSlot(slot: u8) u8 {
    const normalized = StateFile.normalizePersistentStateSlot(slot);
    return if (normalized == StateFile.default_persistent_state_slot)
        StateFile.persistent_state_slot_count
    else
        normalized - 1;
}

pub fn resolvePreviewPath(allocator: std.mem.Allocator, state_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}.preview", .{state_path});
}

pub fn savePreviewFile(allocator: std.mem.Allocator, machine: *const Machine, state_path: []const u8) !void {
    const preview_path = try resolvePreviewPath(allocator, state_path);
    defer allocator.free(preview_path);

    const preview = Preview.captureFromFramebuffer(machine.framebuffer());
    try preview.saveToFile(preview_path);
}

pub fn deletePreviewFile(allocator: std.mem.Allocator, state_path: []const u8) !void {
    const preview_path = try resolvePreviewPath(allocator, state_path);
    defer allocator.free(preview_path);

    std.fs.cwd().deleteFile(preview_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

// Format timestamp as relative time string (e.g., "2 DAYS AGO", "JUST NOW")
pub fn formatTimestampRelative(buffer: []u8, ns: i128) ![]const u8 {
    if (ns <= 0) return std.fmt.bufPrint(buffer, "UNKNOWN", .{});

    const now_ns: i128 = std.time.nanoTimestamp();
    const diff_ns = now_ns - ns;

    if (diff_ns < 0) {
        return std.fmt.bufPrint(buffer, "JUST NOW", .{});
    }

    const diff_seconds: u64 = @intCast(@divFloor(diff_ns, std.time.ns_per_s));
    const diff_minutes = diff_seconds / 60;
    const diff_hours = diff_minutes / 60;
    const diff_days = diff_hours / 24;

    if (diff_seconds < 60) {
        return std.fmt.bufPrint(buffer, "JUST NOW", .{});
    } else if (diff_minutes < 60) {
        if (diff_minutes == 1) {
            return std.fmt.bufPrint(buffer, "1 MIN AGO", .{});
        }
        return std.fmt.bufPrint(buffer, "{d} MINS AGO", .{diff_minutes});
    } else if (diff_hours < 24) {
        if (diff_hours == 1) {
            return std.fmt.bufPrint(buffer, "1 HOUR AGO", .{});
        }
        return std.fmt.bufPrint(buffer, "{d} HOURS AGO", .{diff_hours});
    } else if (diff_days < 30) {
        if (diff_days == 1) {
            return std.fmt.bufPrint(buffer, "YESTERDAY", .{});
        }
        return std.fmt.bufPrint(buffer, "{d} DAYS AGO", .{diff_days});
    } else {
        // For older saves, show the actual date
        const seconds: u64 = @intCast(@divFloor(ns, std.time.ns_per_s));
        const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = seconds };
        const epoch_day = epoch_seconds.getEpochDay();
        const year_day = epoch_day.calculateYearDay();
        const month_day = year_day.calculateMonthDay();

        return std.fmt.bufPrint(buffer, "{d:0>4}-{d:0>2}-{d:0>2}", .{
            year_day.year,
            @intFromEnum(month_day.month) + 1,
            month_day.day_index + 1,
        });
    }
}

// Format save slot line for display
pub fn formatSlotLine(
    buffer: []u8,
    metadata: *const SlotMetadata,
    slot: u8,
    selected: bool,
) ![]const u8 {
    const prefix = if (selected) "> " else "| ";
    if (!metadata.exists) {
        return std.fmt.bufPrint(buffer, "{s}SLOT {d} EMPTY", .{ prefix, slot });
    }

    var time_buffer: [32]u8 = undefined;
    const modified_text = try formatTimestampRelative(time_buffer[0..], metadata.modified_ns);
    const size_kib = (metadata.size_bytes + 1023) / 1024;
    return std.fmt.bufPrint(buffer, "{s}SLOT {d} {s} {d}KB", .{
        prefix,
        slot,
        modified_text,
        size_kib,
    });
}

// Format save file path line for display
pub fn formatPathLine(buffer: []u8, metadata: *const SlotMetadata) ![]const u8 {
    return std.fmt.bufPrint(buffer, "FILE {s}", .{std.fs.path.basename(metadata.path.slice())});
}
