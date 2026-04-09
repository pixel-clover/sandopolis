const std = @import("std");
const config = @import("config.zig");
const AudioOutput = @import("../audio/output.zig").AudioOutput;
const rom_paths = @import("../rom_paths.zig");

pub const FrontendConfig = config.FrontendConfig;
pub const VideoAspectMode = config.VideoAspectMode;
pub const VideoScaleMode = config.VideoScaleMode;
pub const FontFace = config.FontFace;

// All possible UI overlay states. Only one overlay is active at a time.
pub const Overlay = enum {
    none,
    home,
    pause,
    help,
    settings,
    save_manager,
    dialog,
    keyboard_editor,
    game_info,
    debugger,
    performance_hud,

    /// Returns true when the active overlay should pause emulation.
    pub fn pausesEmulation(self: Overlay) bool {
        return switch (self) {
            .none, .performance_hud => false,
            .home, .pause, .help, .settings, .save_manager, .dialog, .keyboard_editor, .game_info, .debugger => true,
        };
    }

    /// Returns true for overlays that show the status bar (ROM name, slot, region).
    pub fn showsStatusBar(self: Overlay) bool {
        return switch (self) {
            .pause, .help => true,
            else => false,
        };
    }

    /// Returns true for modal overlays that should dim the game framebuffer.
    pub fn shouldDimBackdrop(self: Overlay) bool {
        return switch (self) {
            .none, .debugger, .performance_hud => false,
            .home, .pause, .help, .settings, .save_manager, .dialog, .keyboard_editor, .game_info => true,
        };
    }
};

// Frontend UI visibility state
pub const FrontendUi = struct {
    overlay: Overlay = .none,
    /// Tracks the overlay that was active before opening a child overlay
    /// (help, settings, save_manager), so closing returns to the correct
    /// screen (home, pause, or none).
    parent_overlay: Overlay = .none,
    delete_confirm_pending: bool = false,

    pub fn emulationPaused(self: *const FrontendUi) bool {
        return self.overlay.pausesEmulation();
    }

    pub fn showsStatusBar(self: *const FrontendUi) bool {
        return self.overlay.showsStatusBar();
    }

    pub fn closeSaveManager(self: *FrontendUi) void {
        if (self.overlay == .save_manager) {
            self.overlay = self.parent_overlay;
            self.parent_overlay = .none;
        }
        self.delete_confirm_pending = false;
    }

    pub fn closeSettings(self: *FrontendUi) void {
        if (self.overlay == .settings) {
            self.overlay = self.parent_overlay;
            self.parent_overlay = .none;
        }
    }

    pub fn resumeGame(self: *FrontendUi) void {
        self.overlay = .none;
        self.parent_overlay = .none;
        self.delete_confirm_pending = false;
    }

    pub fn openSettings(self: *FrontendUi, settings: *SettingsMenuState) void {
        self.parent_overlay = self.overlay;
        self.overlay = .settings;
        settings.clamp();
    }

    pub fn openHelp(self: *FrontendUi) void {
        self.parent_overlay = self.overlay;
        self.overlay = .help;
    }

    pub fn closeHelp(self: *FrontendUi) void {
        if (self.overlay != .help) return;
        self.overlay = self.parent_overlay;
        self.parent_overlay = .none;
    }

    pub fn openGameInfo(self: *FrontendUi) void {
        self.parent_overlay = self.overlay;
        self.overlay = .game_info;
    }

    pub fn closeGameInfo(self: *FrontendUi) void {
        if (self.overlay != .game_info) return;
        self.overlay = self.parent_overlay;
        self.parent_overlay = .none;
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
    psg_volume,
    controller_p1_type,
    controller_p2_type,
    performance_hud,
    font_face,
    close,
};

pub const settings_menu_actions = [_]SettingsMenuAction{
    .video_aspect_mode,
    .video_scale_mode,
    .fullscreen,
    .audio_render_mode,
    .psg_volume,
    .controller_p1_type,
    .controller_p2_type,
    .performance_hud,
    .font_face,
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
pub fn formatHomeMenuItem(
    buffer: []u8,
    cfg: *const FrontendConfig,
    action: HomeMenuAction,
    selected: bool,
) ![]const u8 {
    const prefix = if (selected) "> " else "  ";
    return switch (action) {
        .open_rom => std.fmt.bufPrint(buffer, "{s}OPEN ROM", .{prefix}),
        .recent_rom => |index| blk: {
            const basename = std.fs.path.basename(cfg.recentRom(index));
            var short_buf: [64]u8 = undefined;
            const short = rom_paths.displayName(basename, &short_buf, 28);
            break :blk std.fmt.bufPrint(buffer, "{s}{s}", .{ prefix, short });
        },
        .show_settings => std.fmt.bufPrint(buffer, "{s}SETTINGS", .{prefix}),
        .show_help => std.fmt.bufPrint(buffer, "{s}HELP AND HOTKEYS", .{prefix}),
        .quit => std.fmt.bufPrint(buffer, "{s}QUIT", .{prefix}),
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

pub const ControllerType = @import("../input/io.zig").Io.ControllerType;

fn controllerTypeLabel(ct: ControllerType) []const u8 {
    return switch (ct) {
        .three_button => "3-BUTTON",
        .six_button => "6-BUTTON",
        .ea_4way_play => "4-WAY PLAY",
        .sega_mouse => "SEGA MOUSE",
    };
}

pub fn nextControllerType(ct: ControllerType) ControllerType {
    return switch (ct) {
        .three_button => .six_button,
        .six_button => .ea_4way_play,
        .ea_4way_play => .sega_mouse,
        .sega_mouse => .three_button,
    };
}

pub fn prevControllerType(ct: ControllerType) ControllerType {
    return switch (ct) {
        .three_button => .sega_mouse,
        .six_button => .three_button,
        .ea_4way_play => .six_button,
        .sega_mouse => .ea_4way_play,
    };
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
    psg_volume: u8,
    controller_types: [2]ControllerType,
    performance_hud: bool,
    font_face: FontFace,
) ![]const u8 {
    const prefix = if (selected) "> " else "  ";
    return switch (action) {
        .video_aspect_mode => std.fmt.bufPrint(buffer, "{s}ASPECT {s}", .{ prefix, aspect_mode.label() }),
        .video_scale_mode => std.fmt.bufPrint(buffer, "{s}SCALING {s}", .{ prefix, scale_mode.label() }),
        .fullscreen => std.fmt.bufPrint(buffer, "{s}FULLSCREEN {s}", .{ prefix, if (fullscreen) "ON" else "OFF" }),
        .audio_render_mode => std.fmt.bufPrint(buffer, "{s}AUDIO MODE {s}", .{ prefix, audio_mode.label() }),
        .psg_volume => std.fmt.bufPrint(buffer, "{s}PSG VOLUME {d}%", .{ prefix, psg_volume }),
        .controller_p1_type => std.fmt.bufPrint(buffer, "{s}P1 CONTROLLER {s}", .{ prefix, controllerTypeLabel(controller_types[0]) }),
        .controller_p2_type => std.fmt.bufPrint(buffer, "{s}P2 CONTROLLER {s}", .{ prefix, controllerTypeLabel(controller_types[1]) }),
        .performance_hud => std.fmt.bufPrint(buffer, "{s}PERF HUD {s}", .{ prefix, if (performance_hud) "ON" else "OFF" }),
        .font_face => std.fmt.bufPrint(buffer, "{s}FONT {s}", .{ prefix, font_face.label() }),
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
            ui.openHelp();
            break :blk .none;
        },
        .quit => .quit,
    };
}

// --- Unit tests ---

test "overlay default is none" {
    const ui = FrontendUi{};
    try std.testing.expectEqual(Overlay.none, ui.overlay);
    try std.testing.expect(!ui.emulationPaused());
}

test "only one overlay active at a time" {
    var ui = FrontendUi{};
    ui.overlay = .debugger;
    try std.testing.expectEqual(Overlay.debugger, ui.overlay);

    ui.overlay = .performance_hud;
    try std.testing.expectEqual(Overlay.performance_hud, ui.overlay);
    try std.testing.expect(ui.overlay != .debugger);
}

test "emulationPaused for each overlay" {
    var ui = FrontendUi{};
    const pausing = [_]Overlay{ .home, .pause, .help, .settings, .save_manager, .dialog, .keyboard_editor, .game_info, .debugger };
    for (pausing) |o| {
        ui.overlay = o;
        try std.testing.expect(ui.emulationPaused());
    }
    const non_pausing = [_]Overlay{ .none, .performance_hud };
    for (non_pausing) |o| {
        ui.overlay = o;
        try std.testing.expect(!ui.emulationPaused());
    }
}

test "status bar shown only for pause and help" {
    var ui = FrontendUi{};
    ui.overlay = .pause;
    try std.testing.expect(ui.showsStatusBar());
    ui.overlay = .help;
    try std.testing.expect(ui.showsStatusBar());
    ui.overlay = .settings;
    try std.testing.expect(!ui.showsStatusBar());
    ui.overlay = .debugger;
    try std.testing.expect(!ui.showsStatusBar());
    ui.overlay = .none;
    try std.testing.expect(!ui.showsStatusBar());
}

test "resumeGame returns to none" {
    var ui = FrontendUi{};
    ui.overlay = .pause;
    ui.delete_confirm_pending = true;
    ui.resumeGame();
    try std.testing.expectEqual(Overlay.none, ui.overlay);
    try std.testing.expect(!ui.delete_confirm_pending);
}

test "closeSaveManager returns to parent overlay" {
    var ui = FrontendUi{};
    ui.overlay = .pause;
    // Simulate opening save manager from pause
    ui.parent_overlay = ui.overlay;
    ui.overlay = .save_manager;
    ui.delete_confirm_pending = true;
    ui.closeSaveManager();
    try std.testing.expectEqual(Overlay.pause, ui.overlay);
    try std.testing.expect(!ui.delete_confirm_pending);
}

test "closeSettings returns to parent overlay" {
    var ui = FrontendUi{};
    ui.overlay = .pause;
    var settings = SettingsMenuState{};
    ui.openSettings(&settings);
    ui.closeSettings();
    try std.testing.expectEqual(Overlay.pause, ui.overlay);
}

test "closeSettings from home returns to home" {
    var ui = FrontendUi{};
    ui.overlay = .home;
    var settings = SettingsMenuState{};
    ui.openSettings(&settings);
    try std.testing.expectEqual(Overlay.settings, ui.overlay);
    ui.closeSettings();
    try std.testing.expectEqual(Overlay.home, ui.overlay);
}

test "openSettings transitions overlay and clamps" {
    var ui = FrontendUi{};
    ui.overlay = .pause;
    var settings = SettingsMenuState{ .selected_index = 999 };
    ui.openSettings(&settings);
    try std.testing.expectEqual(Overlay.settings, ui.overlay);
    try std.testing.expect(settings.selected_index < SettingsMenuState.itemCount());
}

test "opening debugger closes performance hud" {
    var ui = FrontendUi{};
    ui.overlay = .performance_hud;
    ui.overlay = .debugger;
    try std.testing.expectEqual(Overlay.debugger, ui.overlay);
    try std.testing.expect(ui.emulationPaused());
}

test "opening performance hud closes debugger" {
    var ui = FrontendUi{};
    ui.overlay = .debugger;
    ui.overlay = .performance_hud;
    try std.testing.expectEqual(Overlay.performance_hud, ui.overlay);
    try std.testing.expect(!ui.emulationPaused());
}

test "openHelp from pause returns to pause on close" {
    var ui = FrontendUi{};
    ui.overlay = .pause;
    ui.openHelp();
    try std.testing.expectEqual(Overlay.help, ui.overlay);
    ui.closeHelp();
    try std.testing.expectEqual(Overlay.pause, ui.overlay);
}

test "openHelp from home returns to home on close" {
    var ui = FrontendUi{};
    ui.overlay = .home;
    ui.openHelp();
    try std.testing.expectEqual(Overlay.help, ui.overlay);
    ui.closeHelp();
    try std.testing.expectEqual(Overlay.home, ui.overlay);
}

test "openHelp from none returns to none on close" {
    var ui = FrontendUi{};
    ui.openHelp();
    try std.testing.expectEqual(Overlay.help, ui.overlay);
    ui.closeHelp();
    try std.testing.expectEqual(Overlay.none, ui.overlay);
}

test "game_info overlay pauses emulation and dims backdrop" {
    try std.testing.expect(Overlay.game_info.pausesEmulation());
    try std.testing.expect(Overlay.game_info.shouldDimBackdrop());
    try std.testing.expect(!Overlay.game_info.showsStatusBar());
}

test "openGameInfo from pause returns to pause on close" {
    var ui = FrontendUi{};
    ui.overlay = .pause;
    ui.openGameInfo();
    try std.testing.expectEqual(Overlay.game_info, ui.overlay);
    ui.closeGameInfo();
    try std.testing.expectEqual(Overlay.pause, ui.overlay);
}

test "shouldDimBackdrop for each overlay" {
    const dimming = [_]Overlay{ .home, .pause, .help, .settings, .save_manager, .dialog, .keyboard_editor, .game_info };
    for (dimming) |o| {
        try std.testing.expect(o.shouldDimBackdrop());
    }
    const non_dimming = [_]Overlay{ .none, .debugger, .performance_hud };
    for (non_dimming) |o| {
        try std.testing.expect(!o.shouldDimBackdrop());
    }
}
