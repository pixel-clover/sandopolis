const std = @import("std");
const zsdl3 = @import("zsdl3");
const InputBindings = @import("mapping.zig");
const Machine = @import("../machine.zig").Machine;

// Slot types for tracking connected controllers
pub const GamepadSlot = struct {
    id: zsdl3.Joystick.Id,
    handle: *zsdl3.Gamepad,
};

pub const SdlJoystick = opaque {};

pub const JoystickSlot = struct {
    id: zsdl3.Joystick.Id,
    handle: *SdlJoystick,
};

// State tracking for analog inputs
pub const DirectionState = struct {
    left: bool = false,
    right: bool = false,
    up: bool = false,
    down: bool = false,
};

pub const TriggerState = struct {
    left: bool = false,
    right: bool = false,
};

// Input transition for event handling
pub const Transition = struct {
    input: InputBindings.GamepadInput,
    pressed: bool,
};

pub const max_transitions: usize = 4;

// Hat direction bitmasks
pub const hat_up: u8 = 0x01;
pub const hat_right: u8 = 0x02;
pub const hat_down: u8 = 0x04;
pub const hat_left: u8 = 0x08;

// SDL extern declarations for joystick handling
pub extern fn SDL_IsGamepad(id: zsdl3.Joystick.Id) bool;
pub extern fn SDL_OpenJoystick(id: zsdl3.Joystick.Id) ?*SdlJoystick;
pub extern fn SDL_CloseJoystick(joystick: *SdlJoystick) void;

// Button mapping functions
pub fn inputFromGamepadButton(button: u8) ?InputBindings.GamepadInput {
    if (button == @intFromEnum(zsdl3.Gamepad.Button.dpad_up)) return .dpad_up;
    if (button == @intFromEnum(zsdl3.Gamepad.Button.dpad_down)) return .dpad_down;
    if (button == @intFromEnum(zsdl3.Gamepad.Button.dpad_left)) return .dpad_left;
    if (button == @intFromEnum(zsdl3.Gamepad.Button.dpad_right)) return .dpad_right;
    if (button == @intFromEnum(zsdl3.Gamepad.Button.south)) return .south;
    if (button == @intFromEnum(zsdl3.Gamepad.Button.east)) return .east;
    if (button == @intFromEnum(zsdl3.Gamepad.Button.west)) return .west;
    if (button == @intFromEnum(zsdl3.Gamepad.Button.north)) return .north;
    if (button == @intFromEnum(zsdl3.Gamepad.Button.left_shoulder)) return .left_shoulder;
    if (button == @intFromEnum(zsdl3.Gamepad.Button.right_shoulder)) return .right_shoulder;
    if (button == @intFromEnum(zsdl3.Gamepad.Button.back)) return .back;
    if (button == @intFromEnum(zsdl3.Gamepad.Button.start)) return .start;
    if (button == @intFromEnum(zsdl3.Gamepad.Button.guide)) return .guide;
    if (button == @intFromEnum(zsdl3.Gamepad.Button.left_stick)) return .left_stick;
    if (button == @intFromEnum(zsdl3.Gamepad.Button.right_stick)) return .right_stick;
    if (button == @intFromEnum(zsdl3.Gamepad.Button.misc1)) return .misc1;
    return null;
}

pub fn inputFromJoystickButton(button: u8) ?InputBindings.GamepadInput {
    return switch (button) {
        0 => .south,
        1 => .east,
        2 => .west,
        3 => .north,
        4 => .left_shoulder,
        5 => .right_shoulder,
        6 => .back,
        7 => .start,
        else => null,
    };
}

// Axis state update functions
pub fn updateAxisPair(
    negative: *bool,
    positive: *bool,
    value: i16,
    threshold: i16,
    negative_input: InputBindings.GamepadInput,
    positive_input: InputBindings.GamepadInput,
) [max_transitions]?Transition {
    var transitions = [_]?Transition{null} ** max_transitions;
    var next_index: usize = 0;
    const next_negative = value <= -threshold;
    const next_positive = value >= threshold;

    if (negative.* != next_negative) {
        transitions[next_index] = .{
            .input = negative_input,
            .pressed = next_negative,
        };
        negative.* = next_negative;
        next_index += 1;
    }
    if (positive.* != next_positive) {
        transitions[next_index] = .{
            .input = positive_input,
            .pressed = next_positive,
        };
        positive.* = next_positive;
    }

    return transitions;
}

pub fn updateLeftStickState(
    state: *DirectionState,
    axis: zsdl3.Gamepad.Axis,
    value: i16,
    threshold: i16,
) [max_transitions]?Transition {
    return switch (axis) {
        .leftx => updateAxisPair(&state.left, &state.right, value, threshold, .dpad_left, .dpad_right),
        .lefty => updateAxisPair(&state.up, &state.down, value, threshold, .dpad_up, .dpad_down),
        else => [_]?Transition{null} ** max_transitions,
    };
}

pub fn updateTriggerState(
    state: *bool,
    value: i16,
    threshold: i16,
    input: InputBindings.GamepadInput,
) [max_transitions]?Transition {
    var transitions = [_]?Transition{null} ** max_transitions;
    const pressed = value >= threshold;
    if (state.* != pressed) {
        transitions[0] = .{
            .input = input,
            .pressed = pressed,
        };
        state.* = pressed;
    }
    return transitions;
}

pub fn updateGamepadAxisState(
    stick_state: *DirectionState,
    trigger_state: *TriggerState,
    axis: zsdl3.Gamepad.Axis,
    value: i16,
    axis_threshold: i16,
    trigger_threshold: i16,
) [max_transitions]?Transition {
    return switch (axis) {
        .leftx, .lefty => updateLeftStickState(stick_state, axis, value, axis_threshold),
        .left_trigger => updateTriggerState(&trigger_state.left, value, trigger_threshold, .left_trigger),
        .right_trigger => updateTriggerState(&trigger_state.right, value, trigger_threshold, .right_trigger),
        else => [_]?Transition{null} ** max_transitions,
    };
}

pub fn updateJoystickAxisState(
    state: *DirectionState,
    axis: u8,
    value: i16,
    threshold: i16,
) [max_transitions]?Transition {
    return switch (axis) {
        0 => updateAxisPair(&state.left, &state.right, value, threshold, .dpad_left, .dpad_right),
        1 => updateAxisPair(&state.up, &state.down, value, threshold, .dpad_up, .dpad_down),
        else => [_]?Transition{null} ** max_transitions,
    };
}

pub fn updateHatState(state: *DirectionState, value: u8) [max_transitions]?Transition {
    var transitions = [_]?Transition{null} ** max_transitions;
    var next_index: usize = 0;
    const next_up = (value & hat_up) != 0;
    const next_down = (value & hat_down) != 0;
    const next_left = (value & hat_left) != 0;
    const next_right = (value & hat_right) != 0;

    if (state.up != next_up) {
        transitions[next_index] = .{ .input = .dpad_up, .pressed = next_up };
        state.up = next_up;
        next_index += 1;
    }
    if (state.down != next_down) {
        transitions[next_index] = .{ .input = .dpad_down, .pressed = next_down };
        state.down = next_down;
        next_index += 1;
    }
    if (state.left != next_left) {
        transitions[next_index] = .{ .input = .dpad_left, .pressed = next_left };
        state.left = next_left;
        next_index += 1;
    }
    if (state.right != next_right) {
        transitions[next_index] = .{ .input = .dpad_right, .pressed = next_right };
        state.right = next_right;
    }

    return transitions;
}

// Apply input transitions to machine
pub fn applyTransitions(
    bindings: *const InputBindings.Bindings,
    machine: *Machine,
    port: usize,
    transitions: anytype,
) void {
    for (transitions) |maybe_transition| {
        if (maybe_transition) |transition| {
            _ = machine.applyGamepadBindings(bindings, port, transition.input, transition.pressed);
        }
    }
}

// Port management functions
pub fn findGamepadPort(gamepads: *const [InputBindings.player_count]?GamepadSlot, id: zsdl3.Joystick.Id) ?usize {
    for (gamepads, 0..) |slot, port| {
        if (slot) |assigned| {
            if (assigned.id == id) return port;
        }
    }
    return null;
}

pub fn findJoystickPort(joysticks: *const [InputBindings.player_count]?JoystickSlot, id: zsdl3.Joystick.Id) ?usize {
    for (joysticks, 0..) |slot, port| {
        if (slot) |assigned| {
            if (assigned.id == id) return port;
        }
    }
    return null;
}

pub fn portOccupied(
    gamepads: *const [InputBindings.player_count]?GamepadSlot,
    joysticks: *const [InputBindings.player_count]?JoystickSlot,
    port: usize,
) bool {
    return gamepads[port] != null or joysticks[port] != null;
}

// Slot assignment functions
pub fn assignGamepadSlot(
    gamepads: *[InputBindings.player_count]?GamepadSlot,
    joysticks: *const [InputBindings.player_count]?JoystickSlot,
    stick_states: *[InputBindings.player_count]DirectionState,
    trigger_states: *[InputBindings.player_count]TriggerState,
    id: zsdl3.Joystick.Id,
) void {
    if (findGamepadPort(gamepads, id) != null) return;
    for (gamepads, 0..) |slot, port| {
        if (slot == null and !portOccupied(gamepads, joysticks, port)) {
            if (zsdl3.openGamepad(id)) |handle| {
                gamepads[port] = .{ .id = id, .handle = handle };
                stick_states[port] = .{};
                trigger_states[port] = .{};
                std.debug.print("Opened Gamepad ID: {d} for player {d}\n", .{ @intFromEnum(id), port + 1 });
            }
            return;
        }
    }
}

pub fn removeGamepadSlot(
    gamepads: *[InputBindings.player_count]?GamepadSlot,
    stick_states: *[InputBindings.player_count]DirectionState,
    trigger_states: *[InputBindings.player_count]TriggerState,
    machine: *Machine,
    bindings: *const InputBindings.Bindings,
    id: zsdl3.Joystick.Id,
) void {
    for (gamepads, 0..) |slot, port| {
        if (slot) |assigned| {
            if (assigned.id == id) {
                machine.releaseGamepadBindings(bindings, port);
                stick_states[port] = .{};
                trigger_states[port] = .{};
                assigned.handle.close();
                gamepads[port] = null;
                std.debug.print("Closed Gamepad ID: {d} from player {d}\n", .{ @intFromEnum(id), port + 1 });
                return;
            }
        }
    }
}

pub fn assignJoystickSlot(
    gamepads: *const [InputBindings.player_count]?GamepadSlot,
    joysticks: *[InputBindings.player_count]?JoystickSlot,
    axis_states: *[InputBindings.player_count]DirectionState,
    hat_states: *[InputBindings.player_count]DirectionState,
    id: zsdl3.Joystick.Id,
) void {
    if (SDL_IsGamepad(id)) return;
    if (findJoystickPort(joysticks, id) != null) return;

    for (joysticks, 0..) |slot, port| {
        if (slot == null and !portOccupied(gamepads, joysticks, port)) {
            if (SDL_OpenJoystick(id)) |handle| {
                joysticks[port] = .{ .id = id, .handle = handle };
                axis_states[port] = .{};
                hat_states[port] = .{};
                std.debug.print("Opened Joystick ID: {d} for player {d}\n", .{ @intFromEnum(id), port + 1 });
            }
            return;
        }
    }
}

pub fn removeJoystickSlot(
    joysticks: *[InputBindings.player_count]?JoystickSlot,
    axis_states: *[InputBindings.player_count]DirectionState,
    hat_states: *[InputBindings.player_count]DirectionState,
    machine: *Machine,
    bindings: *const InputBindings.Bindings,
    id: zsdl3.Joystick.Id,
) void {
    for (joysticks, 0..) |slot, port| {
        if (slot) |assigned| {
            if (assigned.id == id) {
                machine.releaseGamepadBindings(bindings, port);
                axis_states[port] = .{};
                hat_states[port] = .{};
                SDL_CloseJoystick(assigned.handle);
                joysticks[port] = null;
                std.debug.print("Closed Joystick ID: {d} from player {d}\n", .{ @intFromEnum(id), port + 1 });
                return;
            }
        }
    }
}
