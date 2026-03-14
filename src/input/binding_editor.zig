const std = @import("std");
const InputBindings = @import("mapping.zig");
const keyboard = @import("keyboard.zig");
const toast = @import("../frontend/toast.zig");

// Get display name for a keyboard input binding
pub fn bindingName(input: ?InputBindings.KeyboardInput) []const u8 {
    return if (input) |value| InputBindings.keyboardInputName(value) else "none";
}

// Format a binding editor row for display
pub fn rowText(
    buffer: []u8,
    bindings: *const InputBindings.Bindings,
    target: Target,
) ![]const u8 {
    return switch (target) {
        .player_action => |item| std.fmt.bufPrint(buffer, "P{d} {s} = {s}", .{
            item.port + 1,
            InputBindings.actionName(item.action),
            bindingName(bindings.keyboardBinding(item.port, item.action)),
        }),
        .hotkey => |action| {
            var binding_buffer: [48]u8 = undefined;
            const binding = try InputBindings.hotkeyBindingDisplayName(binding_buffer[0..], bindings.hotkeyBinding(action));
            return std.fmt.bufPrint(buffer, "HOTKEY {s} = {s}", .{
                keyboard.hotkeyActionDescription(action),
                binding,
            });
        },
    };
}

// Binding editor target - what binding is being edited
pub const Target = union(enum) {
    player_action: struct {
        port: usize,
        action: InputBindings.Action,
    },
    hotkey: InputBindings.HotkeyAction,
};

// Binding editor status
pub const Status = enum {
    neutral,
    success,
    failed,
};

// Binding editor state
pub const State = struct {
    selected_index: usize = 0,
    capture_mode: bool = false,
    status: Status = .neutral,
    status_message: toast.MessageCopy = .{},

    pub fn selectionCount() usize {
        return InputBindings.player_count * InputBindings.all_actions.len + InputBindings.all_hotkey_actions.len;
    }

    pub fn currentTarget(self: *const State) Target {
        return targetForIndex(self.selected_index);
    }

    pub fn move(self: *State, delta: isize) void {
        const count: isize = @intCast(selectionCount());
        var next: isize = @intCast(self.selected_index);
        next += delta;
        while (next < 0) next += count;
        while (next >= count) next -= count;
        self.selected_index = @intCast(next);
    }

    pub fn beginCapture(self: *State) void {
        self.capture_mode = true;
        self.setStatus(.neutral, "PRESS A KEY  ESC CANCEL  DEL CLEAR");
    }

    pub fn cancelCapture(self: *State) void {
        self.capture_mode = false;
        self.setStatus(.neutral, "REBIND CANCELED");
    }

    pub fn assign(self: *State, bindings: *InputBindings.Bindings, input: InputBindings.KeyboardInput) void {
        switch (self.currentTarget()) {
            .player_action => |target| bindings.setKeyboardForPort(target.port, target.action, input),
            .hotkey => |action| bindings.setHotkey(action, input),
        }
        self.capture_mode = false;
        self.setStatus(.success, "BINDING UPDATED");
    }

    pub fn assignHotkey(self: *State, bindings: *InputBindings.Bindings, binding: InputBindings.HotkeyBinding) void {
        switch (self.currentTarget()) {
            .player_action => unreachable,
            .hotkey => |action| bindings.setHotkeyWithModifiers(action, binding.input, binding.modifiers),
        }
        self.capture_mode = false;
        self.setStatus(.success, "BINDING UPDATED");
    }

    pub fn clearSelected(self: *State, bindings: *InputBindings.Bindings) void {
        switch (self.currentTarget()) {
            .player_action => |target| bindings.setKeyboardForPort(target.port, target.action, null),
            .hotkey => |action| bindings.setHotkey(action, null),
        }
        self.capture_mode = false;
        self.setStatus(.success, "BINDING CLEARED");
    }

    pub fn clearStatus(self: *State) void {
        self.status = .neutral;
        self.status_message = .{};
    }

    pub fn close(self: *State) void {
        self.capture_mode = false;
        self.clearStatus();
    }

    pub fn open(self: *State) void {
        self.capture_mode = false;
        self.setStatus(.neutral, "UP DOWN MOVE  ENTER REBIND  F5 SAVE  ESC CLOSE");
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
    const per_player_count = InputBindings.all_actions.len;
    const player_action_count = InputBindings.player_count * per_player_count;
    if (index < player_action_count) {
        return .{
            .player_action = .{
                .port = index / per_player_count,
                .action = InputBindings.all_actions[index % per_player_count],
            },
        };
    }
    return .{
        .hotkey = InputBindings.all_hotkey_actions[index - player_action_count],
    };
}
