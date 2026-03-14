const std = @import("std");
const zsdl3 = @import("zsdl3");
const InputBindings = @import("../input/mapping.zig");
const StateFile = @import("../state_file.zig");

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
        .header = "DEBUG",
        .items = &[_]OverlayLine{
            .{ .hotkey = .{ .action = .step, .label = "STEP CPU" } },
            .{ .hotkey = .{ .action = .registers, .label = "REGISTERS" } },
            .{ .hotkey = .{ .action = .record_gif, .label = "RECORD GIF" } },
            .{ .hotkey = .{ .action = .record_wav, .label = "RECORD WAV" } },
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

/// Render a panel with shadow and double border
pub fn renderPanel(
    renderer: *zsdl3.Renderer,
    rect: zsdl3.FRect,
    fill: zsdl3.Color,
    border: zsdl3.Color,
    scale: f32,
) !void {
    const shadow_offset = Spacing.shadowOffset(scale);
    const border_inset = Spacing.borderInset(scale);
    try zsdl3.setRenderDrawColor(renderer, Colors.shadow);
    try zsdl3.renderFillRect(renderer, .{
        .x = rect.x + shadow_offset,
        .y = rect.y + shadow_offset,
        .w = rect.w,
        .h = rect.h,
    });
    try zsdl3.setRenderDrawColor(renderer, fill);
    try zsdl3.renderFillRect(renderer, rect);
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
    const total_width = content_width + padding * 2.0;
    const total_height = padding * 2.0 + header_height + content_height + footer_height;

    const panel = zsdl3.FRect{
        .x = (@as(f32, @floatFromInt(viewport.w)) - total_width) * 0.5,
        .y = (@as(f32, @floatFromInt(viewport.h)) - total_height) * 0.5,
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

/// Render the pause overlay
pub fn renderPauseOverlay(
    renderer: *zsdl3.Renderer,
    viewport: zsdl3.Rect,
    bindings: *const InputBindings.Bindings,
    persistent_state_slot: u8,
) !void {
    var slot_buffer: [64]u8 = undefined;
    const slot_text = try std.fmt.bufPrint(&slot_buffer, "] SLOT {d}  |  ENTER SAVE MANAGER  |  TAB SETTINGS", .{
        StateFile.normalizePersistentStateSlot(persistent_state_slot),
    });

    try renderTwoColumnOverlay(
        renderer,
        viewport,
        bindings,
        "% PAUSED",
        slot_text,
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
