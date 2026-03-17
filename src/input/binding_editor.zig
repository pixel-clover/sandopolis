const std = @import("std");
const InputBindings = @import("mapping.zig");
const keyboard = @import("keyboard.zig");
const toast = @import("../frontend/toast.zig");

pub fn bindingName(input: ?InputBindings.KeyboardInput) []const u8 {
    return if (input) |value| InputBindings.keyboardInputName(value) else "NONE";
}

fn gamepadBindingName(input: ?InputBindings.GamepadInput) []const u8 {
    return if (input) |value| InputBindings.gamepadInputName(value) else "NONE";
}

pub fn rowText(
    buffer: []u8,
    bindings: *const InputBindings.Bindings,
    target: Target,
) ![]const u8 {
    return switch (target) {
        .section_header => |label| std.fmt.bufPrint(buffer, "--- {s} ---", .{label}),
        .keyboard_action => |item| std.fmt.bufPrint(buffer, "  KEY P{d} {s: <6} {s}", .{
            item.port + 1,
            InputBindings.actionName(item.action),
            bindingName(bindings.keyboardBinding(item.port, item.action)),
        }),
        .gamepad_action => |item| std.fmt.bufPrint(buffer, "  PAD P{d} {s: <6} {s}", .{
            item.port + 1,
            InputBindings.actionName(item.action),
            gamepadBindingName(bindings.gamepad[item.port][InputBindings.actionIndex(item.action)]),
        }),
        .hotkey => |action| blk: {
            var binding_buffer: [48]u8 = undefined;
            const binding = try InputBindings.hotkeyBindingDisplayName(binding_buffer[0..], bindings.hotkeyBinding(action));
            break :blk std.fmt.bufPrint(buffer, "  {s: <18} {s}", .{
                keyboard.hotkeyActionDescription(action),
                binding,
            });
        },
    };
}

pub const Target = union(enum) {
    section_header: []const u8,
    keyboard_action: struct {
        port: usize,
        action: InputBindings.Action,
    },
    gamepad_action: struct {
        port: usize,
        action: InputBindings.Action,
    },
    hotkey: InputBindings.HotkeyAction,

    pub fn isHeader(self: Target) bool {
        return switch (self) {
            .section_header => true,
            else => false,
        };
    }

    pub fn isEditable(self: Target) bool {
        return !self.isHeader();
    }
};

pub const Status = enum {
    neutral,
    success,
    failed,
};

// Layout: section headers + entries
const actions_per_player = InputBindings.all_actions.len;
const hotkey_count = InputBindings.all_hotkey_actions.len;

// Sections:
// "KEYBOARD P1" header + 12 entries
// "KEYBOARD P2" header + 12 entries
// "GAMEPAD P1" header + 12 entries
// "GAMEPAD P2" header + 12 entries
// "HOTKEYS" header + N entries
const section_count = 5;
const total_entry_count = section_count + InputBindings.player_count * actions_per_player * 2 + hotkey_count;

pub const State = struct {
    selected_index: usize = 0,
    capture_mode: bool = false,
    capture_gamepad: bool = false,
    status: Status = .neutral,
    status_message: toast.MessageCopy = .{},

    pub fn selectionCount() usize {
        return total_entry_count;
    }

    pub fn currentTarget(self: *const State) Target {
        return targetForIndex(self.selected_index);
    }

    pub fn move(self: *State, delta: isize) void {
        const count: isize = @intCast(selectionCount());
        var next: isize = @intCast(self.selected_index);
        // Skip section headers when navigating
        var attempts: usize = 0;
        while (attempts < selectionCount()) : (attempts += 1) {
            next += delta;
            while (next < 0) next += count;
            while (next >= count) next -= count;
            const target = targetForIndex(@intCast(next));
            if (target.isEditable()) break;
        }
        self.selected_index = @intCast(next);
    }

    pub fn beginCapture(self: *State) void {
        const target = self.currentTarget();
        self.capture_mode = true;
        self.capture_gamepad = (target == .gamepad_action);
        if (self.capture_gamepad) {
            self.setStatus(.neutral, "PRESS A GAMEPAD BUTTON  ESC CANCEL  DEL CLEAR");
        } else {
            self.setStatus(.neutral, "PRESS A KEY  ESC CANCEL  DEL CLEAR");
        }
    }

    pub fn cancelCapture(self: *State) void {
        self.capture_mode = false;
        self.capture_gamepad = false;
        self.setStatus(.neutral, "REBIND CANCELED");
    }

    pub fn assign(self: *State, bindings: *InputBindings.Bindings, input: InputBindings.KeyboardInput) void {
        switch (self.currentTarget()) {
            .keyboard_action => |target| bindings.setKeyboardForPort(target.port, target.action, input),
            .hotkey => |action| bindings.setHotkey(action, input),
            else => {},
        }
        self.capture_mode = false;
        self.capture_gamepad = false;
        self.setStatus(.success, "BINDING UPDATED");
    }

    pub fn assignGamepad(self: *State, bindings: *InputBindings.Bindings, input: InputBindings.GamepadInput) void {
        switch (self.currentTarget()) {
            .gamepad_action => |target| bindings.setGamepadForPort(target.port, target.action, input),
            else => {},
        }
        self.capture_mode = false;
        self.capture_gamepad = false;
        self.setStatus(.success, "GAMEPAD BINDING UPDATED");
    }

    pub fn assignHotkey(self: *State, bindings: *InputBindings.Bindings, binding: InputBindings.HotkeyBinding) void {
        switch (self.currentTarget()) {
            .keyboard_action => unreachable,
            .hotkey => |action| bindings.setHotkeyWithModifiers(action, binding.input, binding.modifiers),
            else => unreachable,
        }
        self.capture_mode = false;
        self.capture_gamepad = false;
        self.setStatus(.success, "BINDING UPDATED");
    }

    pub fn clearSelected(self: *State, bindings: *InputBindings.Bindings) void {
        switch (self.currentTarget()) {
            .keyboard_action => |target| bindings.setKeyboardForPort(target.port, target.action, null),
            .gamepad_action => |target| bindings.setGamepadForPort(target.port, target.action, null),
            .hotkey => |action| bindings.setHotkey(action, null),
            .section_header => {},
        }
        self.capture_mode = false;
        self.capture_gamepad = false;
        self.setStatus(.success, "BINDING CLEARED");
    }

    pub fn clearStatus(self: *State) void {
        self.status = .neutral;
        self.status_message = .{};
    }

    pub fn close(self: *State) void {
        self.capture_mode = false;
        self.capture_gamepad = false;
        self.clearStatus();
    }

    pub fn open(self: *State) void {
        self.capture_mode = false;
        self.capture_gamepad = false;
        // Start on first editable row (skip header)
        if (targetForIndex(self.selected_index).isHeader()) {
            self.selected_index = 1;
        }
        self.setStatus(.neutral, "UP/DN MOVE  ENTER REBIND  F5 SAVE  ESC CLOSE");
    }

    pub fn setStatus(self: *State, status: Status, message: []const u8) void {
        self.status = status;
        self.status_message = .{};
        const len = @min(message.len, self.status_message.bytes.len);
        @memcpy(self.status_message.bytes[0..len], message[0..len]);
        self.status_message.len = len;
    }
};

pub fn targetForIndex(index: usize) Target {
    var i: usize = 0;
    var cursor: usize = 0;

    // "KEYBOARD P1" section
    if (index == cursor) return .{ .section_header = "KEYBOARD P1" };
    cursor += 1;
    for (0..actions_per_player) |a| {
        if (index == cursor) return .{ .keyboard_action = .{ .port = 0, .action = InputBindings.all_actions[a] } };
        cursor += 1;
    }

    // "KEYBOARD P2" section
    if (index == cursor) return .{ .section_header = "KEYBOARD P2" };
    cursor += 1;
    for (0..actions_per_player) |a| {
        if (index == cursor) return .{ .keyboard_action = .{ .port = 1, .action = InputBindings.all_actions[a] } };
        cursor += 1;
    }

    // "GAMEPAD P1" section
    if (index == cursor) return .{ .section_header = "GAMEPAD P1" };
    cursor += 1;
    for (0..actions_per_player) |a| {
        if (index == cursor) return .{ .gamepad_action = .{ .port = 0, .action = InputBindings.all_actions[a] } };
        cursor += 1;
    }

    // "GAMEPAD P2" section
    if (index == cursor) return .{ .section_header = "GAMEPAD P2" };
    cursor += 1;
    for (0..actions_per_player) |a| {
        if (index == cursor) return .{ .gamepad_action = .{ .port = 1, .action = InputBindings.all_actions[a] } };
        cursor += 1;
    }

    // "HOTKEYS" section
    if (index == cursor) return .{ .section_header = "HOTKEYS" };
    cursor += 1;
    i = index - cursor;
    if (i < hotkey_count) {
        return .{ .hotkey = InputBindings.all_hotkey_actions[i] };
    }

    return .{ .section_header = "?" };
}
