const std = @import("std");
const config = @import("config.zig");
const AudioOutput = @import("../audio/output.zig").AudioOutput;

pub const FrontendConfig = config.FrontendConfig;
pub const VideoAspectMode = config.VideoAspectMode;
pub const VideoScaleMode = config.VideoScaleMode;

// Frontend UI visibility state
pub const FrontendUi = struct {
    paused: bool = false,
    show_home: bool = false,
    show_save_manager: bool = false,
    show_settings: bool = false,
    show_help: bool = false,
    dialog_active: bool = false,
    show_keyboard_editor: bool = false,
    show_performance_hud: bool = false,
    show_debugger: bool = false,
    delete_confirm_pending: bool = false, // Waiting for delete confirmation

    pub fn emulationPaused(self: *const FrontendUi) bool {
        return self.paused or self.show_home or self.show_save_manager or self.show_settings or self.show_help or self.dialog_active or self.show_keyboard_editor;
    }

    pub fn closeSaveManager(self: *FrontendUi) void {
        self.show_save_manager = false;
        self.delete_confirm_pending = false;
    }

    pub fn closeSettings(self: *FrontendUi) void {
        self.show_settings = false;
    }

    pub fn resumeGame(self: *FrontendUi) void {
        self.paused = false;
        self.show_save_manager = false;
        self.show_settings = false;
        self.show_help = false;
        self.delete_confirm_pending = false;
    }

    pub fn openSettings(self: *FrontendUi, settings: *SettingsMenuState) void {
        self.show_settings = true;
        self.show_save_manager = false;
        self.show_help = false;
        settings.clamp();
    }

    pub fn cancelDeleteConfirm(self: *FrontendUi) void {
        self.delete_confirm_pending = false;
    }
};

// Animation state for slide-in effects (separate from FrontendUi to avoid complexity)
pub const SlideAnimation = struct {
    panel_open_frame: u64 = 0,
    was_panel_visible: bool = false,

    const animation_frames: u64 = 12; // ~200ms at 60fps

    // Update animation state based on current panel visibility
    pub fn update(self: *SlideAnimation, panel_visible: bool, current_frame: u64) void {
        if (panel_visible and !self.was_panel_visible) {
            self.panel_open_frame = current_frame;
        }
        self.was_panel_visible = panel_visible;
    }

    // Calculate slide-in animation progress (0.0 = start, 1.0 = complete)
    pub fn progress(self: *const SlideAnimation, current_frame: u64) f32 {
        if (self.panel_open_frame == 0) return 1.0;
        const elapsed = current_frame -| self.panel_open_frame;
        if (elapsed >= animation_frames) return 1.0;
        const t = @as(f32, @floatFromInt(elapsed)) / @as(f32, @floatFromInt(animation_frames));
        // Ease-out cubic: 1 - (1 - t)^3
        const inv = 1.0 - t;
        return 1.0 - (inv * inv * inv);
    }

    // Calculate Y offset for slide-down animation (returns pixels to offset from top)
    pub fn slideOffset(self: *const SlideAnimation, current_frame: u64, panel_height: f32) f32 {
        const p = self.progress(current_frame);
        return -panel_height * (1.0 - p);
    }
};

// Home menu action types
pub const HomeMenuAction = union(enum) {
    open_rom,
    recent_rom: usize,
    show_settings,
    show_help,
    quit,
};

// Home menu state
pub const HomeMenuState = struct {
    selected_index: usize = 0,

    pub fn itemCount(cfg: *const FrontendConfig) usize {
        return cfg.recent_rom_count + 4;
    }

    pub fn clamp(self: *HomeMenuState, cfg: *const FrontendConfig) void {
        const count = itemCount(cfg);
        if (count == 0) {
            self.selected_index = 0;
        } else if (self.selected_index >= count) {
            self.selected_index = count - 1;
        }
    }

    pub fn move(self: *HomeMenuState, delta: isize, cfg: *const FrontendConfig) void {
        const count: isize = @intCast(itemCount(cfg));
        if (count == 0) {
            self.selected_index = 0;
            return;
        }

        var next: isize = @intCast(self.selected_index);
        next += delta;
        while (next < 0) next += count;
        while (next >= count) next -= count;
        self.selected_index = @intCast(next);
    }

    pub fn currentAction(self: *const HomeMenuState, cfg: *const FrontendConfig) HomeMenuAction {
        if (self.selected_index == 0) return .open_rom;
        const recent_end = 1 + cfg.recent_rom_count;
        if (self.selected_index < recent_end) {
            return .{ .recent_rom = self.selected_index - 1 };
        }
        if (self.selected_index == recent_end) return .show_settings;
        if (self.selected_index == recent_end + 1) return .show_help;
        return .quit;
    }
};

// Settings menu action types
pub const SettingsMenuAction = enum {
    video_aspect_mode,
    video_scale_mode,
    fullscreen,
    audio_render_mode,
    performance_hud,
    close,
};

pub const settings_menu_actions = [_]SettingsMenuAction{
    .video_aspect_mode,
    .video_scale_mode,
    .fullscreen,
    .audio_render_mode,
    .performance_hud,
    .close,
};

// Settings menu state
pub const SettingsMenuState = struct {
    selected_index: usize = 0,

    pub fn itemCount() usize {
        return settings_menu_actions.len;
    }

    pub fn clamp(self: *SettingsMenuState) void {
        if (self.selected_index >= itemCount()) self.selected_index = itemCount() - 1;
    }

    pub fn move(self: *SettingsMenuState, delta: isize) void {
        const count: isize = @intCast(itemCount());
        var next: isize = @intCast(self.selected_index);
        next += delta;
        while (next < 0) next += count;
        while (next >= count) next -= count;
        self.selected_index = @intCast(next);
    }

    pub fn currentAction(self: *const SettingsMenuState) SettingsMenuAction {
        return settings_menu_actions[self.selected_index];
    }
};

// Home screen command result
pub const HomeScreenCommand = union(enum) {
    none,
    open_dialog,
    load_recent: usize,
    quit,
};

// Frontend gamepad command result
pub const FrontendGamepadCommand = union(enum) {
    ignored,
    consumed,
    open_dialog,
    load_recent: usize,
    quit,
};

// Frontend event handling disposition
pub const EventDisposition = enum {
    unhandled,
    handled,
    quit,
};

// Format a home menu item for display
// Icons: [ = folder, ] = disk, * = gear, ( = help, { = controller
pub fn formatHomeMenuItem(
    buffer: []u8,
    cfg: *const FrontendConfig,
    action: HomeMenuAction,
    selected: bool,
) ![]const u8 {
    const prefix = if (selected) "> " else "  ";
    return switch (action) {
        .open_rom => std.fmt.bufPrint(buffer, "{s}[ OPEN ROM", .{prefix}),
        .recent_rom => |index| std.fmt.bufPrint(buffer, "{s}] {s}", .{
            prefix,
            std.fs.path.basename(cfg.recentRom(index)),
        }),
        .show_settings => std.fmt.bufPrint(buffer, "{s}* SETTINGS", .{prefix}),
        .show_help => std.fmt.bufPrint(buffer, "{s}( HELP AND HOTKEYS", .{prefix}),
        .quit => std.fmt.bufPrint(buffer, "{s}! QUIT", .{prefix}),
    };
}

// Get the action for a home menu index
pub fn homeMenuActionForIndex(selected_index: usize, cfg: *const FrontendConfig) HomeMenuAction {
    if (selected_index == 0) return .open_rom;
    const recent_end = 1 + cfg.recent_rom_count;
    if (selected_index < recent_end) {
        return .{ .recent_rom = selected_index - 1 };
    }
    if (selected_index == recent_end) return .show_settings;
    if (selected_index == recent_end + 1) return .show_help;
    return .quit;
}

// Format a settings menu action line for display
pub fn formatSettingsActionLine(
    buffer: []u8,
    action: SettingsMenuAction,
    selected: bool,
    aspect_mode: VideoAspectMode,
    scale_mode: VideoScaleMode,
    fullscreen: bool,
    audio_mode: AudioOutput.RenderMode,
    performance_hud: bool,
) ![]const u8 {
    const prefix = if (selected) "> " else "  ";
    return switch (action) {
        .video_aspect_mode => std.fmt.bufPrint(buffer, "{s}ASPECT {s}", .{ prefix, aspect_mode.label() }),
        .video_scale_mode => std.fmt.bufPrint(buffer, "{s}SCALING {s}", .{ prefix, scale_mode.label() }),
        .fullscreen => std.fmt.bufPrint(buffer, "{s}FULLSCREEN {s}", .{ prefix, if (fullscreen) "ON" else "OFF" }),
        .audio_render_mode => std.fmt.bufPrint(buffer, "{s}AUDIO MODE {s}", .{ prefix, audio_mode.label() }),
        .performance_hud => std.fmt.bufPrint(buffer, "{s}PERF HUD {s}", .{ prefix, if (performance_hud) "ON" else "OFF" }),
        .close => std.fmt.bufPrint(buffer, "{s}CLOSE SETTINGS", .{prefix}),
    };
}

// Convert a home screen command to a frontend gamepad command
pub fn gamepadCommandFromHome(command: HomeScreenCommand) FrontendGamepadCommand {
    return switch (command) {
        .none => .consumed,
        .open_dialog => .open_dialog,
        .load_recent => |index| .{ .load_recent = index },
        .quit => .quit,
    };
}

// Activate the currently selected home menu item and return the resulting command
pub fn activateHomeMenuSelection(
    ui: *FrontendUi,
    home_menu: *const HomeMenuState,
    settings: *SettingsMenuState,
    cfg: *const FrontendConfig,
) HomeScreenCommand {
    return switch (home_menu.currentAction(cfg)) {
        .open_rom => .open_dialog,
        .recent_rom => |index| .{ .load_recent = index },
        .show_settings => blk: {
            ui.openSettings(settings);
            break :blk .none;
        },
        .show_help => blk: {
            ui.show_help = true;
            break :blk .none;
        },
        .quit => .quit,
    };
}
