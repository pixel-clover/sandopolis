const std = @import("std");
const zsdl3 = @import("zsdl3");
const InputBindings = @import("../input/mapping.zig");
const StateFile = @import("../state_file.zig");
const toast_module = @import("toast.zig");
const Toast = toast_module.Toast;
const config_module = @import("config.zig");
const FrontendConfig = config_module.FrontendConfig;
const recent_rom_limit = config_module.recent_rom_limit;
const menu_module = @import("menu.zig");
const HomeMenuState = menu_module.HomeMenuState;
const formatHomeMenuItem = menu_module.formatHomeMenuItem;
const homeMenuActionForIndex = menu_module.homeMenuActionForIndex;
const binding_editor = @import("../input/binding_editor.zig");
const BindingEditorState = binding_editor.State;
const bindingEditorRowText = binding_editor.rowText;
const bindingEditorTargetForIndex = binding_editor.targetForIndex;

// Centralized UI color system for consistent theming across overlays
pub const Colors = struct {
    // Panel backgrounds (darker, cleaner)
    pub const panel_primary: zsdl3.Color = .{ .r = 0x0D, .g = 0x11, .b = 0x17, .a = 0xE8 }; // GitHub-dark inspired
    pub const panel_secondary: zsdl3.Color = .{ .r = 0x0E, .g = 0x14, .b = 0x19, .a = 0xEE }; // slightly warmer
    pub const panel_overlay: zsdl3.Color = .{ .r = 0x0F, .g = 0x13, .b = 0x18, .a = 0xD8 }; // for HUD

    // Accent colors (refined)
    pub const cyan: zsdl3.Color = .{ .r = 0x5A, .g = 0xD4, .b = 0xEC, .a = 0xFF }; // slightly brighter
    pub const gold: zsdl3.Color = .{ .r = 0xF5, .g = 0xC6, .b = 0x42, .a = 0xFF }; // warmer
    pub const orange: zsdl3.Color = .{ .r = 0xF9, .g = 0x8B, .b = 0x4D, .a = 0xFF }; // softer
    pub const green: zsdl3.Color = .{ .r = 0x7C, .g = 0xDB, .b = 0xB8, .a = 0xFF }; // mint
    pub const blue: zsdl3.Color = .{ .r = 0x58, .g = 0xA6, .b = 0xFF, .a = 0xFF }; // selection
    pub const red: zsdl3.Color = .{ .r = 0xE8, .g = 0x5D, .b = 0x5D, .a = 0xFF }; // errors

    // Text colors (better hierarchy)
    pub const text_primary: zsdl3.Color = .{ .r = 0xE6, .g = 0xED, .b = 0xF3, .a = 0xFF }; // softer white
    pub const text_secondary: zsdl3.Color = .{ .r = 0x8B, .g = 0x94, .b = 0x9E, .a = 0xFF }; // more muted gray
    pub const text_selected: zsdl3.Color = .{ .r = 0xFF, .g = 0xF0, .b = 0xC0, .a = 0xFF }; // warmer highlight
    pub const text_muted: zsdl3.Color = .{ .r = 0xC7, .g = 0xD2, .b = 0xE0, .a = 0xFF }; // info text

    // Shadow (softer than current 80-90%)
    pub const shadow: zsdl3.Color = .{ .r = 0x00, .g = 0x00, .b = 0x00, .a = 0x99 }; // 60% opacity

    // Status colors
    pub const success: zsdl3.Color = .{ .r = 0x89, .g = 0xDA, .b = 0xA2, .a = 0xFF };
    pub const failure: zsdl3.Color = .{ .r = 0xFF, .g = 0x9B, .b = 0x8E, .a = 0xFF };
};

// Spacing system for consistent layout
pub const Spacing = struct {
    pub const line_height: f32 = 10.0; // up from 9.0 for better readability

    pub fn shadowOffset(scale: f32) f32 {
        return 4.0 * scale; // scale-aware (was fixed 6px)
    }

    pub fn borderInset(scale: f32) f32 {
        return 3.0 * scale; // scale-aware (was fixed 3px)
    }
};

// Animation helpers for UI effects
pub const Animation = struct {
    // Generate a pulse value (0.0 to 1.0) based on frame counter
    // Returns a smooth sine-based oscillation for selected item highlighting
    pub fn pulse(frame: u64, period_frames: u32) f32 {
        const phase = @as(f32, @floatFromInt(frame % period_frames)) / @as(f32, @floatFromInt(period_frames));
        // Use sine for smooth oscillation, map from [-1,1] to [0,1]
        return (std.math.sin(phase * std.math.pi * 2.0) + 1.0) * 0.5;
    }

    // Apply pulse effect to a color's brightness
    // min_brightness: minimum brightness multiplier (e.g., 0.7)
    // max_brightness: maximum brightness multiplier (e.g., 1.0)
    pub fn pulseColor(base: zsdl3.Color, frame: u64, min_brightness: f32, max_brightness: f32) zsdl3.Color {
        const p = pulse(frame, 45); // ~0.75 second period at 60fps
        const brightness = min_brightness + (max_brightness - min_brightness) * p;
        return .{
            .r = @intFromFloat(@min(255.0, @as(f32, @floatFromInt(base.r)) * brightness)),
            .g = @intFromFloat(@min(255.0, @as(f32, @floatFromInt(base.g)) * brightness)),
            .b = @intFromFloat(@min(255.0, @as(f32, @floatFromInt(base.b)) * brightness)),
            .a = base.a,
        };
    }

    // Apply pulse to alpha only (for glow effects)
    pub fn pulseAlpha(base: zsdl3.Color, frame: u64, min_alpha: u8, max_alpha: u8) zsdl3.Color {
        const p = pulse(frame, 45);
        const alpha_range = @as(f32, @floatFromInt(max_alpha - min_alpha));
        return .{
            .r = base.r,
            .g = base.g,
            .b = base.b,
            .a = min_alpha + @as(u8, @intFromFloat(alpha_range * p)),
        };
    }
};

// Menu line types for overlay rendering
pub const OverlayLine = union(enum) {
    hotkey: struct {
        action: InputBindings.HotkeyAction,
        label: []const u8,
    },
    text: []const u8,
    blank,
    state_file_slot,
    active_state_slot,
};

// Menu section for two-column layouts
pub const MenuSection = struct {
    header: []const u8,
    items: []const OverlayLine,
};

// Pause menu sections
pub const pause_left_sections = [_]MenuSection{
    .{
        .header = "ACTIONS",
        .items = &[_]OverlayLine{
            .{ .hotkey = .{ .action = .toggle_pause, .label = "RESUME" } },
            .{ .hotkey = .{ .action = .open_rom, .label = "OPEN ROM" } },
            .{ .hotkey = .{ .action = .restart_rom, .label = "SOFT RESET" } },
            .{ .hotkey = .{ .action = .reload_rom, .label = "HARD RESET" } },
        },
    },
    .{
        .header = "SYSTEM",
        .items = &[_]OverlayLine{
            .{ .hotkey = .{ .action = .open_keyboard_editor, .label = "KEYBOARD" } },
            .{ .hotkey = .{ .action = .toggle_performance_hud, .label = "PERF HUD" } },
            .{ .hotkey = .{ .action = .toggle_help, .label = "HELP" } },
        },
    },
};

pub const pause_right_sections = [_]MenuSection{
    .{
        .header = "SAVE STATES",
        .items = &[_]OverlayLine{
            .{ .hotkey = .{ .action = .save_quick_state, .label = "QUICK SAVE" } },
            .{ .hotkey = .{ .action = .load_quick_state, .label = "QUICK LOAD" } },
            .{ .hotkey = .{ .action = .save_state_file, .label = "SAVE FILE" } },
            .{ .hotkey = .{ .action = .load_state_file, .label = "LOAD FILE" } },
            .{ .hotkey = .{ .action = .next_state_slot, .label = "NEXT SLOT" } },
        },
    },
};

// Help menu sections
pub const help_left_sections = [_]MenuSection{
    .{
        .header = "EMULATION",
        .items = &[_]OverlayLine{
            .{ .hotkey = .{ .action = .toggle_help, .label = "CLOSE HELP" } },
            .{ .hotkey = .{ .action = .toggle_pause, .label = "PAUSE/RESUME" } },
            .{ .hotkey = .{ .action = .open_rom, .label = "OPEN ROM" } },
            .{ .hotkey = .{ .action = .restart_rom, .label = "SOFT RESET" } },
            .{ .hotkey = .{ .action = .reload_rom, .label = "HARD RESET" } },
        },
    },
    .{
        .header = "DISPLAY",
        .items = &[_]OverlayLine{
            .{ .hotkey = .{ .action = .toggle_fullscreen, .label = "FULLSCREEN" } },
            .{ .hotkey = .{ .action = .toggle_performance_hud, .label = "PERF HUD" } },
            .{ .hotkey = .{ .action = .quit, .label = "QUIT" } },
        },
    },
};

pub const help_right_sections = [_]MenuSection{
    .{
        .header = "SAVE STATES",
        .items = &[_]OverlayLine{
            .{ .hotkey = .{ .action = .save_quick_state, .label = "QUICK SAVE" } },
            .{ .hotkey = .{ .action = .load_quick_state, .label = "QUICK LOAD" } },
            .{ .hotkey = .{ .action = .save_state_file, .label = "SAVE FILE" } },
            .{ .hotkey = .{ .action = .load_state_file, .label = "LOAD FILE" } },
            .{ .hotkey = .{ .action = .next_state_slot, .label = "NEXT SLOT" } },
        },
    },
    .{
        .header = "DEBUG AND CAPTURE",
        .items = &[_]OverlayLine{
            .{ .text = "F10        DEBUGGER" },
            .{ .text = "SPACE      STEP (IN DEBUGGER)" },
            .{ .hotkey = .{ .action = .record_gif, .label = "RECORD GIF" } },
            .{ .hotkey = .{ .action = .record_wav, .label = "RECORD WAV" } },
            .{ .hotkey = .{ .action = .screenshot, .label = "SCREENSHOT" } },
        },
    },
};

/// Calculate overlay scale factor based on viewport size
pub fn overlayScale(viewport: zsdl3.Rect) f32 {
    const min_dimension = @min(viewport.w, viewport.h);
    if (min_dimension < 360) return 1.0;
    if (min_dimension < 720) return 2.0;
    return 3.0;
}

/// Get bitmap glyph rows for a character (5x7 pixel font)
pub fn glyphRows(ch: u8) [7]u8 {
    const glyph = std.ascii.toUpper(ch);
    return switch (glyph) {
        ' ' => .{ 0, 0, 0, 0, 0, 0, 0 },
        'A' => .{ 0x0E, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11 },
        'B' => .{ 0x1E, 0x11, 0x11, 0x1E, 0x11, 0x11, 0x1E },
        'C' => .{ 0x0E, 0x11, 0x10, 0x10, 0x10, 0x11, 0x0E },
        'D' => .{ 0x1E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x1E },
        'E' => .{ 0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x1F },
        'F' => .{ 0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x10 },
        'G' => .{ 0x0E, 0x11, 0x10, 0x17, 0x11, 0x11, 0x0E },
        'H' => .{ 0x11, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11 },
        'I' => .{ 0x1F, 0x04, 0x04, 0x04, 0x04, 0x04, 0x1F },
        'J' => .{ 0x07, 0x02, 0x02, 0x02, 0x12, 0x12, 0x0C },
        'K' => .{ 0x11, 0x12, 0x14, 0x18, 0x14, 0x12, 0x11 },
        'L' => .{ 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x1F },
        'M' => .{ 0x11, 0x1B, 0x15, 0x15, 0x11, 0x11, 0x11 },
        'N' => .{ 0x11, 0x19, 0x15, 0x13, 0x11, 0x11, 0x11 },
        'O' => .{ 0x0E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E },
        'P' => .{ 0x1E, 0x11, 0x11, 0x1E, 0x10, 0x10, 0x10 },
        'Q' => .{ 0x0E, 0x11, 0x11, 0x11, 0x15, 0x12, 0x0D },
        'R' => .{ 0x1E, 0x11, 0x11, 0x1E, 0x14, 0x12, 0x11 },
        'S' => .{ 0x0F, 0x10, 0x10, 0x0E, 0x01, 0x01, 0x1E },
        'T' => .{ 0x1F, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04 },
        'U' => .{ 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E },
        'V' => .{ 0x11, 0x11, 0x11, 0x11, 0x11, 0x0A, 0x04 },
        'W' => .{ 0x11, 0x11, 0x11, 0x15, 0x15, 0x1B, 0x11 },
        'X' => .{ 0x11, 0x11, 0x0A, 0x04, 0x0A, 0x11, 0x11 },
        'Y' => .{ 0x11, 0x11, 0x0A, 0x04, 0x04, 0x04, 0x04 },
        'Z' => .{ 0x1F, 0x01, 0x02, 0x04, 0x08, 0x10, 0x1F },
        '0' => .{ 0x0E, 0x11, 0x13, 0x15, 0x19, 0x11, 0x0E },
        '1' => .{ 0x04, 0x0C, 0x04, 0x04, 0x04, 0x04, 0x0E },
        '2' => .{ 0x0E, 0x11, 0x01, 0x02, 0x04, 0x08, 0x1F },
        '3' => .{ 0x1E, 0x01, 0x01, 0x0E, 0x01, 0x01, 0x1E },
        '4' => .{ 0x02, 0x06, 0x0A, 0x12, 0x1F, 0x02, 0x02 },
        '5' => .{ 0x1F, 0x10, 0x10, 0x1E, 0x01, 0x01, 0x1E },
        '6' => .{ 0x0E, 0x10, 0x10, 0x1E, 0x11, 0x11, 0x0E },
        '7' => .{ 0x1F, 0x01, 0x02, 0x04, 0x08, 0x10, 0x10 },
        '8' => .{ 0x0E, 0x11, 0x11, 0x0E, 0x11, 0x11, 0x0E },
        '9' => .{ 0x0E, 0x11, 0x11, 0x0F, 0x01, 0x01, 0x0E },
        ':' => .{ 0x00, 0x04, 0x04, 0x00, 0x04, 0x04, 0x00 },
        '-' => .{ 0x00, 0x00, 0x00, 0x0E, 0x00, 0x00, 0x00 },
        '.' => .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x06, 0x06 },
        '/' => .{ 0x01, 0x02, 0x02, 0x04, 0x08, 0x08, 0x10 },
        '+' => .{ 0x00, 0x04, 0x04, 0x1F, 0x04, 0x04, 0x00 },
        '_' => .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x1F },
        '?' => .{ 0x0E, 0x11, 0x01, 0x02, 0x04, 0x00, 0x04 },
        // Icon glyphs for UI elements
        '>' => .{ 0x00, 0x08, 0x04, 0x02, 0x04, 0x08, 0x00 }, // right arrow (selected menu item)
        '<' => .{ 0x00, 0x02, 0x04, 0x08, 0x04, 0x02, 0x00 }, // left arrow (back navigation)
        '^' => .{ 0x00, 0x04, 0x0E, 0x15, 0x04, 0x04, 0x00 }, // up arrow (scroll up)
        '~' => .{ 0x00, 0x04, 0x04, 0x15, 0x0E, 0x04, 0x00 }, // down arrow (scroll down)
        '@' => .{ 0x00, 0x00, 0x01, 0x02, 0x14, 0x08, 0x00 }, // checkmark (success/enabled)
        '#' => .{ 0x00, 0x11, 0x0A, 0x04, 0x0A, 0x11, 0x00 }, // X mark (failure/disabled)
        '$' => .{ 0x00, 0x10, 0x18, 0x1C, 0x18, 0x10, 0x00 }, // play (resume game)
        '%' => .{ 0x00, 0x1B, 0x1B, 0x1B, 0x1B, 0x1B, 0x00 }, // pause (paused state)
        '[' => .{ 0x1C, 0x1F, 0x11, 0x11, 0x11, 0x1F, 0x00 }, // folder (open ROM)
        ']' => .{ 0x1F, 0x11, 0x1F, 0x11, 0x11, 0x11, 0x1F }, // disk (save state)
        '*' => .{ 0x0A, 0x1F, 0x15, 0x0E, 0x15, 0x1F, 0x0A }, // gear (settings)
        '(' => .{ 0x0E, 0x11, 0x02, 0x04, 0x00, 0x04, 0x0E }, // help (help/info) - alternative to ?
        '{' => .{ 0x00, 0x0E, 0x1F, 0x1F, 0x0A, 0x00, 0x00 }, // controller (input config)
        '|' => .{ 0x00, 0x00, 0x0E, 0x0E, 0x0E, 0x00, 0x00 }, // bullet (list item)
        '!' => .{ 0x04, 0x04, 0x04, 0x04, 0x04, 0x00, 0x04 }, // exclamation (warning)
        else => .{ 0x0E, 0x11, 0x01, 0x02, 0x04, 0x00, 0x04 },
    };
}

/// Calculate text width in pixels
pub fn textWidth(text: []const u8, scale: f32) f32 {
    return @as(f32, @floatFromInt(text.len)) * 6.0 * scale;
}

/// Draw a single glyph at the specified position
pub fn drawGlyph(renderer: *zsdl3.Renderer, x: f32, y: f32, scale: f32, ch: u8) !void {
    const rows = glyphRows(ch);
    for (rows, 0..) |bits, row| {
        for (0..5) |col| {
            const shift: u3 = @intCast(4 - col);
            if (((bits >> shift) & 1) == 0) continue;
            try zsdl3.renderFillRect(renderer, .{
                .x = x + @as(f32, @floatFromInt(col)) * scale,
                .y = y + @as(f32, @floatFromInt(row)) * scale,
                .w = scale,
                .h = scale,
            });
        }
    }
}

/// Draw text at the specified position with the given color
pub fn drawText(renderer: *zsdl3.Renderer, x: f32, y: f32, scale: f32, color: zsdl3.Color, text: []const u8) !void {
    try zsdl3.setRenderDrawColor(renderer, color);
    var cursor = x;
    for (text) |ch| {
        try drawGlyph(renderer, cursor, y, scale, ch);
        cursor += 6.0 * scale;
    }
}

/// Interpolate between two colors
fn lerpColor(a: zsdl3.Color, b: zsdl3.Color, t: f32) zsdl3.Color {
    return .{
        .r = @intFromFloat(@as(f32, @floatFromInt(a.r)) + (@as(f32, @floatFromInt(b.r)) - @as(f32, @floatFromInt(a.r))) * t),
        .g = @intFromFloat(@as(f32, @floatFromInt(a.g)) + (@as(f32, @floatFromInt(b.g)) - @as(f32, @floatFromInt(a.g))) * t),
        .b = @intFromFloat(@as(f32, @floatFromInt(a.b)) + (@as(f32, @floatFromInt(b.b)) - @as(f32, @floatFromInt(a.b))) * t),
        .a = @intFromFloat(@as(f32, @floatFromInt(a.a)) + (@as(f32, @floatFromInt(b.a)) - @as(f32, @floatFromInt(a.a))) * t),
    };
}

/// Adjust color brightness
fn adjustBrightness(color: zsdl3.Color, factor: f32) zsdl3.Color {
    return .{
        .r = @intFromFloat(@min(255.0, @as(f32, @floatFromInt(color.r)) * factor)),
        .g = @intFromFloat(@min(255.0, @as(f32, @floatFromInt(color.g)) * factor)),
        .b = @intFromFloat(@min(255.0, @as(f32, @floatFromInt(color.b)) * factor)),
        .a = color.a,
    };
}

/// Render a panel with shadow, gradient background, and double border
pub fn renderPanel(
    renderer: *zsdl3.Renderer,
    rect: zsdl3.FRect,
    fill: zsdl3.Color,
    border: zsdl3.Color,
    scale: f32,
) !void {
    const shadow_offset = Spacing.shadowOffset(scale);
    const border_inset = Spacing.borderInset(scale);

    // Draw shadow
    try zsdl3.setRenderDrawColor(renderer, Colors.shadow);
    try zsdl3.renderFillRect(renderer, .{
        .x = rect.x + shadow_offset,
        .y = rect.y + shadow_offset,
        .w = rect.w,
        .h = rect.h,
    });

    // Draw gradient background (subtle: top slightly lighter, bottom slightly darker)
    const top_color = adjustBrightness(fill, 1.15);
    const bottom_color = adjustBrightness(fill, 0.85);
    const gradient_steps: usize = 8; // Number of bands for gradient
    const band_height = rect.h / @as(f32, @floatFromInt(gradient_steps));

    for (0..gradient_steps) |i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(gradient_steps - 1));
        const band_color = lerpColor(top_color, bottom_color, t);
        try zsdl3.setRenderDrawColor(renderer, band_color);
        try zsdl3.renderFillRect(renderer, .{
            .x = rect.x,
            .y = rect.y + @as(f32, @floatFromInt(i)) * band_height,
            .w = rect.w,
            .h = band_height + 1.0, // +1 to avoid gaps
        });
    }

    // Draw double border
    try zsdl3.setRenderDrawColor(renderer, border);
    try zsdl3.renderRect(renderer, rect);
    try zsdl3.renderRect(renderer, .{
        .x = rect.x + border_inset,
        .y = rect.y + border_inset,
        .w = rect.w - border_inset * 2.0,
        .h = rect.h - border_inset * 2.0,
    });
}

/// Format an overlay line for display
pub fn formatOverlayLine(
    buffer: []u8,
    bindings: *const InputBindings.Bindings,
    line: OverlayLine,
    persistent_state_slot: u8,
) ![]const u8 {
    return switch (line) {
        .blank => "",
        .text => |text| text,
        .state_file_slot => std.fmt.bufPrint(buffer, "STATE FILE SLOT {d}/{d}", .{
            persistent_state_slot,
            StateFile.persistent_state_slot_count,
        }),
        .active_state_slot => std.fmt.bufPrint(buffer, "ACTIVE STATE SLOT {d}/{d}", .{
            persistent_state_slot,
            StateFile.persistent_state_slot_count,
        }),
        .hotkey => |item| {
            var binding_buffer: [48]u8 = undefined;
            const binding = try InputBindings.hotkeyBindingDisplayName(binding_buffer[0..], bindings.hotkeyBinding(item.action));
            return std.fmt.bufPrint(buffer, "{s} {s}", .{ binding, item.label });
        },
    };
}

/// Render a two-column overlay with sections
pub fn renderTwoColumnOverlay(
    renderer: *zsdl3.Renderer,
    viewport: zsdl3.Rect,
    bindings: *const InputBindings.Bindings,
    title: []const u8,
    subtitle: ?[]const u8,
    footer: ?[]const u8,
    left_sections: []const MenuSection,
    right_sections: []const MenuSection,
    border_color: zsdl3.Color,
    persistent_state_slot: u8,
) !void {
    const scale = overlayScale(viewport);
    const padding = 14.0 * scale;
    const line_height = 10.0 * scale;
    const section_gap = 6.0 * scale;
    const column_gap = 24.0 * scale;

    // Calculate column widths
    var left_width: f32 = 0;
    var right_width: f32 = 0;
    var line_buffer: [80]u8 = undefined;

    for (left_sections) |section| {
        left_width = @max(left_width, textWidth(section.header, scale));
        for (section.items) |item| {
            const line = try formatOverlayLine(&line_buffer, bindings, item, persistent_state_slot);
            left_width = @max(left_width, textWidth(line, scale));
        }
    }
    for (right_sections) |section| {
        right_width = @max(right_width, textWidth(section.header, scale));
        for (section.items) |item| {
            const line = try formatOverlayLine(&line_buffer, bindings, item, persistent_state_slot);
            right_width = @max(right_width, textWidth(line, scale));
        }
    }

    // Calculate heights
    var left_lines: usize = 0;
    for (left_sections, 0..) |section, i| {
        left_lines += 1 + section.items.len;
        if (i < left_sections.len - 1) left_lines += 1; // gap between sections
    }
    var right_lines: usize = 0;
    for (right_sections, 0..) |section, i| {
        right_lines += 1 + section.items.len;
        if (i < right_sections.len - 1) right_lines += 1;
    }
    const max_lines = @max(left_lines, right_lines);

    // Header height (title + subtitle if present)
    const header_height = if (subtitle != null) 22.0 * scale else 14.0 * scale;
    const footer_height: f32 = if (footer != null) 16.0 * scale else 0;
    const content_height = line_height * @as(f32, @floatFromInt(max_lines));

    // Calculate total width - must fit columns, title, subtitle, and footer
    var content_width = left_width + column_gap + right_width;
    content_width = @max(content_width, textWidth(title, scale));
    if (subtitle) |sub| {
        content_width = @max(content_width, textWidth(sub, scale));
    }
    if (footer) |foot| {
        content_width = @max(content_width, textWidth(foot, scale));
    }
    const vw: f32 = @floatFromInt(viewport.w);
    const vh: f32 = @floatFromInt(viewport.h);
    const total_width = @min(content_width + padding * 2.0, vw);
    const total_height = @min(padding * 2.0 + header_height + content_height + footer_height, vh);

    const panel = zsdl3.FRect{
        .x = @max(0.0, (vw - total_width) * 0.5),
        .y = @max(0.0, (vh - total_height) * 0.5),
        .w = total_width,
        .h = total_height,
    };

    try renderPanel(renderer, panel, Colors.panel_primary, border_color, scale);

    // Draw title centered
    try drawText(
        renderer,
        panel.x + (panel.w - textWidth(title, scale)) * 0.5,
        panel.y + padding,
        scale,
        border_color,
        title,
    );

    // Draw subtitle if present
    if (subtitle) |sub| {
        try drawText(
            renderer,
            panel.x + (panel.w - textWidth(sub, scale)) * 0.5,
            panel.y + padding + 11.0 * scale,
            scale,
            Colors.text_muted,
            sub,
        );
    }

    const content_y = panel.y + padding + header_height;
    const left_x = panel.x + padding;
    const right_x = panel.x + padding + left_width + column_gap;

    // Draw left column
    var y = content_y;
    for (left_sections, 0..) |section, section_idx| {
        // Section header
        try drawText(renderer, left_x, y, scale, Colors.cyan, section.header);
        y += line_height;

        // Section items
        for (section.items) |item| {
            const line = try formatOverlayLine(&line_buffer, bindings, item, persistent_state_slot);
            try drawText(renderer, left_x, y, scale, Colors.gold, line);
            y += line_height;
        }

        // Gap between sections
        if (section_idx < left_sections.len - 1) {
            y += section_gap;
        }
    }

    // Draw right column
    y = content_y;
    for (right_sections, 0..) |section, section_idx| {
        // Section header
        try drawText(renderer, right_x, y, scale, Colors.cyan, section.header);
        y += line_height;

        // Section items
        for (section.items) |item| {
            const line = try formatOverlayLine(&line_buffer, bindings, item, persistent_state_slot);
            try drawText(renderer, right_x, y, scale, Colors.gold, line);
            y += line_height;
        }

        // Gap between sections
        if (section_idx < right_sections.len - 1) {
            y += section_gap;
        }
    }

    // Draw footer if present
    if (footer) |foot| {
        try drawText(
            renderer,
            panel.x + (panel.w - textWidth(foot, scale)) * 0.5,
            panel.y + panel.h - padding - 7.0 * scale,
            scale,
            Colors.text_muted,
            foot,
        );
    }
}

/// Render a slot indicator badge in the top-left corner
pub fn renderSlotBadge(
    renderer: *zsdl3.Renderer,
    viewport: zsdl3.Rect,
    persistent_state_slot: u8,
) !void {
    const scale = overlayScale(viewport);
    const padding = 6.0 * scale;
    const slot = StateFile.normalizePersistentStateSlot(persistent_state_slot);

    var slot_buffer: [16]u8 = undefined;
    const slot_text = try std.fmt.bufPrint(&slot_buffer, "] SLOT {d}", .{slot});
    const text_w = textWidth(slot_text, scale);

    const badge_rect = zsdl3.FRect{
        .x = 12.0 * scale,
        .y = 12.0 * scale,
        .w = text_w + padding * 2.0,
        .h = 7.0 * scale + padding * 2.0,
    };

    try renderPanel(renderer, badge_rect, Colors.panel_primary, Colors.cyan, scale);
    try drawText(renderer, badge_rect.x + padding, badge_rect.y + padding, scale, Colors.cyan, slot_text);
}

/// Render the pause overlay
pub fn renderPauseOverlay(
    renderer: *zsdl3.Renderer,
    viewport: zsdl3.Rect,
    bindings: *const InputBindings.Bindings,
    persistent_state_slot: u8,
) !void {
    // Render slot badge in corner
    try renderSlotBadge(renderer, viewport, persistent_state_slot);

    try renderTwoColumnOverlay(
        renderer,
        viewport,
        bindings,
        "% PAUSED",
        "ENTER SAVE MANAGER  |  TAB SETTINGS",
        "PAD: A SAVE MGR  B RESUME  X SETTINGS  Y HELP",
        &pause_left_sections,
        &pause_right_sections,
        Colors.gold,
        persistent_state_slot,
    );
}

/// Render the help overlay
pub fn renderHelpOverlay(
    renderer: *zsdl3.Renderer,
    viewport: zsdl3.Rect,
    bindings: *const InputBindings.Bindings,
    persistent_state_slot: u8,
) !void {
    var slot_buffer: [64]u8 = undefined;
    const slot_text = try std.fmt.bufPrint(&slot_buffer, "CURRENT SLOT: {d}  |  MENUS FREEZE EMULATION", .{
        StateFile.normalizePersistentStateSlot(persistent_state_slot),
    });

    try renderTwoColumnOverlay(
        renderer,
        viewport,
        bindings,
        "( SANDOPOLIS HELP",
        null,
        slot_text,
        &help_left_sections,
        &help_right_sections,
        Colors.green,
        persistent_state_slot,
    );
}

/// Render the file dialog overlay
pub fn renderDialogOverlay(renderer: *zsdl3.Renderer, viewport: zsdl3.Rect) !void {
    const title = "OPEN ROM";
    const lines = [_][]const u8{
        "SYSTEM FILE DIALOG ACTIVE",
        "",
        "SELECT A ROM OR CANCEL",
    };
    const scale = overlayScale(viewport);
    const padding = 10.0 * scale;
    const line_height = 10.0 * scale;

    var max_width = textWidth(title, scale);
    for (lines) |line| {
        max_width = @max(max_width, textWidth(line, scale));
    }

    const dvw: f32 = @floatFromInt(viewport.w);
    const dvh: f32 = @floatFromInt(viewport.h);
    const dialog_w = @min(max_width + padding * 2.0, dvw);
    const dialog_h = @min(padding * 2.0 + 7.0 * scale + 4.0 * scale + line_height * @as(f32, @floatFromInt(lines.len)), dvh);
    const panel = zsdl3.FRect{
        .x = @max(0.0, (dvw - dialog_w) * 0.5),
        .y = @max(0.0, (dvh - dialog_h) * 0.5),
        .w = dialog_w,
        .h = dialog_h,
    };

    try renderPanel(
        renderer,
        panel,
        Colors.panel_primary,
        Colors.orange,
        scale,
    );

    try drawText(
        renderer,
        panel.x + (panel.w - textWidth(title, scale)) * 0.5,
        panel.y + padding,
        scale,
        Colors.orange,
        title,
    );

    var y = panel.y + padding + 11.0 * scale;
    for (lines) |line| {
        if (line.len != 0) {
            try drawText(
                renderer,
                panel.x + (panel.w - textWidth(line, scale)) * 0.5,
                y,
                scale,
                Colors.text_primary,
                line,
            );
        }
        y += line_height;
    }
}

/// Render the toast notification overlay
pub fn renderToastOverlay(renderer: *zsdl3.Renderer, viewport: zsdl3.Rect, toast: *const Toast, frame_number: u64) !void {
    if (!toast.visible(frame_number)) return;

    const scale = overlayScale(viewport);
    const padding = 8.0 * scale;
    const text = toast.slice();
    const width = textWidth(text, scale);
    const panel_width = width + padding * 2.0;
    const panel_height = padding * 2.0 + 7.0 * scale;
    const panel = zsdl3.FRect{
        .x = @max(12.0 * scale, @as(f32, @floatFromInt(viewport.w)) - panel_width - 12.0 * scale),
        .y = 12.0 * scale,
        .w = panel_width,
        .h = panel_height,
    };
    const ToastPalette = struct {
        fill: zsdl3.Color,
        border: zsdl3.Color,
    };
    const toast_colors: ToastPalette = switch (toast.style) {
        .info => .{
            .fill = Colors.panel_primary,
            .border = Colors.gold,
        },
        .success => .{
            .fill = .{ .r = 0x0D, .g = 0x18, .b = 0x12, .a = 0xE8 },
            .border = Colors.green,
        },
        .failure => .{
            .fill = .{ .r = 0x1B, .g = 0x0F, .b = 0x11, .a = 0xEC },
            .border = Colors.orange,
        },
    };

    try renderPanel(
        renderer,
        panel,
        toast_colors.fill,
        toast_colors.border,
        scale,
    );
    try drawText(
        renderer,
        panel.x + padding,
        panel.y + padding,
        scale,
        Colors.text_primary,
        text,
    );
}

/// Render the home screen overlay
pub fn renderHomeOverlay(
    renderer: *zsdl3.Renderer,
    viewport: zsdl3.Rect,
    home_menu: *const HomeMenuState,
    cfg: *const FrontendConfig,
    frame_number: u64,
) !void {
    const title = "SANDOPOLIS";
    const subtitle = "OPEN A ROM TO START";
    const empty_recent_note = "NO RECENT ROMS YET";
    const footer_a = "DPAD MOVE  A OR START SELECT";
    const footer_b = "CTRL+O OPEN ROM  F1 HELP  ESC QUIT";
    const scale = overlayScale(viewport);
    const padding = 12.0 * scale;
    const line_height = 10.0 * scale;
    const item_count = HomeMenuState.itemCount(cfg);
    const note_count: usize = if (cfg.recent_rom_count == 0) 1 else 0;

    var line_buffers: [recent_rom_limit + 3][96]u8 = undefined;
    var menu_lines: [recent_rom_limit + 3][]const u8 = undefined;
    var max_width = textWidth(title, scale);
    max_width = @max(max_width, textWidth(subtitle, scale));
    max_width = @max(max_width, textWidth(footer_a, scale));
    max_width = @max(max_width, textWidth(footer_b, scale));
    if (note_count != 0) {
        max_width = @max(max_width, textWidth(empty_recent_note, scale));
    }

    for (0..item_count) |index| {
        const line = try formatHomeMenuItem(
            line_buffers[index][0..],
            cfg,
            homeMenuActionForIndex(index, cfg),
            index == home_menu.selected_index,
        );
        menu_lines[index] = line;
        max_width = @max(max_width, textWidth(line, scale));
    }

    const body_lines = 3 + note_count + item_count;
    const hvw: f32 = @floatFromInt(viewport.w);
    const hvh: f32 = @floatFromInt(viewport.h);
    const home_w = @min(max_width + padding * 2.0, hvw);
    const home_h = @min(padding * 2.0 + 7.0 * scale + 6.0 * scale + line_height * @as(f32, @floatFromInt(body_lines)), hvh);
    const panel = zsdl3.FRect{
        .x = @max(0.0, (hvw - home_w) * 0.5),
        .y = @max(0.0, (hvh - home_h) * 0.5),
        .w = home_w,
        .h = home_h,
    };

    try renderPanel(
        renderer,
        panel,
        Colors.panel_secondary,
        Colors.cyan,
        scale,
    );

    try drawText(
        renderer,
        panel.x + (panel.w - textWidth(title, scale)) * 0.5,
        panel.y + padding,
        scale,
        Colors.cyan,
        title,
    );

    const text_x = panel.x + padding;
    var y = panel.y + padding + 13.0 * scale;
    try drawText(renderer, text_x, y, scale, Colors.text_primary, subtitle);
    y += line_height;

    if (note_count != 0) {
        try drawText(renderer, text_x, y, scale, Colors.text_muted, empty_recent_note);
        y += line_height;
    }

    for (menu_lines[0..item_count], 0..) |line, index| {
        const is_selected = index == home_menu.selected_index;
        const base_color: zsdl3.Color = if (is_selected) Colors.gold else Colors.text_primary;
        const color = if (is_selected) Animation.pulseColor(base_color, frame_number, 0.75, 1.0) else base_color;
        try drawText(renderer, text_x, y, scale, color, line);
        y += line_height;
    }

    try drawText(renderer, text_x, y, scale, Colors.text_muted, footer_a);
    y += line_height;
    try drawText(renderer, text_x, y, scale, Colors.text_muted, footer_b);
}

/// Render the keyboard binding editor overlay
pub fn renderKeyboardEditorOverlay(
    renderer: *zsdl3.Renderer,
    viewport: zsdl3.Rect,
    editor: *const BindingEditorState,
    bindings: *const InputBindings.Bindings,
    frame_number: u64,
    config_path: []const u8,
) !void {
    const title = "INPUT EDITOR";
    const controls = if (editor.capture_mode and editor.capture_gamepad)
        "PRESS A GAMEPAD BUTTON  ESC CANCEL  DEL CLEAR"
    else if (editor.capture_mode)
        "PRESS A KEY  ESC CANCEL  DEL CLEAR"
    else
        "UP/DN MOVE  ENTER REBIND  F5 SAVE  ESC CLOSE";
    const scale = overlayScale(viewport);
    const padding = 10.0 * scale;
    const line_height = 10.0 * scale;
    const header_height = 38.0 * scale;
    const footer_height = 18.0 * scale;
    const visible_rows = @min(@as(usize, 11), BindingEditorState.selectionCount());

    const panel = zsdl3.FRect{
        .x = 12.0 * scale,
        .y = 12.0 * scale,
        .w = @as(f32, @floatFromInt(viewport.w)) - 24.0 * scale,
        .h = header_height + footer_height + @as(f32, @floatFromInt(visible_rows)) * line_height + padding * 2.0,
    };

    try renderPanel(
        renderer,
        panel,
        Colors.panel_secondary,
        Colors.blue,
        scale,
    );

    try drawText(
        renderer,
        panel.x + padding,
        panel.y + padding,
        scale,
        Colors.blue,
        title,
    );
    try drawText(
        renderer,
        panel.x + padding,
        panel.y + padding + 11.0 * scale,
        scale,
        Colors.text_muted,
        controls,
    );
    try drawText(
        renderer,
        panel.x + padding,
        panel.y + padding + 22.0 * scale,
        scale,
        Colors.text_secondary,
        config_path,
    );

    const first_visible = if (editor.selected_index < visible_rows / 2)
        @as(usize, 0)
    else
        @min(
            editor.selected_index - visible_rows / 2,
            BindingEditorState.selectionCount() - visible_rows,
        );
    var y = panel.y + padding + header_height;
    for (0..visible_rows) |row| {
        const index = first_visible + row;
        const selected = index == editor.selected_index;
        const row_rect = zsdl3.FRect{
            .x = panel.x + padding - 3.0 * scale,
            .y = y - 1.0 * scale,
            .w = panel.w - padding * 2.0 + 6.0 * scale,
            .h = line_height,
        };
        if (selected and !bindingEditorTargetForIndex(index).isHeader()) {
            const pulse_alpha = Animation.pulseAlpha(.{ .r = 0x17, .g = 0x2C, .b = 0x44, .a = 0xF2 }, frame_number, 0xE0, 0xF2);
            try zsdl3.setRenderDrawColor(renderer, pulse_alpha);
            try zsdl3.renderFillRect(renderer, row_rect);
            try zsdl3.setRenderDrawColor(renderer, Animation.pulseColor(Colors.blue, frame_number, 0.8, 1.0));
            try zsdl3.renderRect(renderer, row_rect);
        }

        const target = bindingEditorTargetForIndex(index);
        var line_buffer: [96]u8 = undefined;
        const line = try bindingEditorRowText(line_buffer[0..], bindings, target);

        if (target.isHeader()) {
            // Section headers: accent color, no selection highlight
            try drawText(renderer, panel.x + padding, y, scale, Colors.cyan, line);
        } else {
            const base_color: zsdl3.Color = if (selected) Colors.text_selected else Colors.text_primary;
            const text_color = if (selected) Animation.pulseColor(base_color, frame_number, 0.85, 1.0) else base_color;
            try drawText(renderer, panel.x + padding, y, scale, text_color, line);
        }
        y += line_height;
    }

    const status_color: zsdl3.Color = switch (editor.status) {
        .neutral => Colors.text_muted,
        .success => Colors.success,
        .failed => Colors.failure,
    };
    if (editor.status_message.len != 0) {
        try drawText(
            renderer,
            panel.x + padding,
            panel.y + panel.h - padding - 7.0 * scale,
            scale,
            status_color,
            editor.status_message.slice(),
        );
    }
}

/// Render a status bar at the bottom of the screen showing ROM info
pub fn renderStatusBar(
    renderer: *zsdl3.Renderer,
    viewport: zsdl3.Rect,
    rom_name: []const u8,
    slot: u8,
    is_pal: bool,
) !void {
    const scale = overlayScale(viewport);
    const padding = 6.0 * scale;
    const bar_height = 7.0 * scale + padding * 2.0;
    const viewport_width = @as(f32, @floatFromInt(viewport.w));
    const viewport_height = @as(f32, @floatFromInt(viewport.h));

    // Semi-transparent background bar at bottom
    const bar_rect = zsdl3.FRect{
        .x = 0,
        .y = viewport_height - bar_height,
        .w = viewport_width,
        .h = bar_height,
    };

    // Dark background with low opacity
    try zsdl3.setRenderDrawColor(renderer, .{ .r = 0x00, .g = 0x00, .b = 0x00, .a = 0x60 });
    try zsdl3.renderFillRect(renderer, bar_rect);

    // ROM name on the left
    try drawText(
        renderer,
        padding,
        bar_rect.y + padding,
        scale,
        Colors.text_secondary,
        rom_name,
    );

    // Slot and region info on the right
    var info_buffer: [32]u8 = undefined;
    const region_label = if (is_pal) "PAL" else "NTSC";
    const info_text = std.fmt.bufPrint(&info_buffer, "SLOT {d} | {s}", .{ slot, region_label }) catch "SLOT ?";
    const info_width = textWidth(info_text, scale);
    try drawText(
        renderer,
        viewport_width - info_width - padding,
        bar_rect.y + padding,
        scale,
        Colors.text_secondary,
        info_text,
    );
}
