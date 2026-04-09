const std = @import("std");
const zsdl3 = @import("zsdl3");
const InputBindings = @import("mapping.zig");

// Check if a keyboard key is pressed
pub fn keyboardStatePressed(state: []const bool, scancode: zsdl3.Scancode) bool {
    const index: usize = @intFromEnum(scancode);
    return index < state.len and state[index];
}

// Extract hotkey modifiers from keyboard state
pub fn hotkeyModifiersFromKeyboardState(state: []const bool) InputBindings.HotkeyModifiers {
    return .{
        .shift = keyboardStatePressed(state, .lshift) or keyboardStatePressed(state, .rshift),
        .ctrl = keyboardStatePressed(state, .lctrl) or keyboardStatePressed(state, .rctrl),
        .alt = keyboardStatePressed(state, .lalt) or keyboardStatePressed(state, .ralt),
        .gui = keyboardStatePressed(state, .lgui) or keyboardStatePressed(state, .rgui),
    };
}

// Check if a scancode is a modifier key
pub fn isHotkeyModifierScancode(scancode: zsdl3.Scancode) bool {
    return switch (scancode) {
        .lshift, .rshift, .lctrl, .rctrl, .lalt, .ralt, .lgui, .rgui => true,
        else => false,
    };
}

// Create a hotkey binding from a scancode and keyboard state
pub fn hotkeyBindingFromScancode(scancode: zsdl3.Scancode, keyboard_state: []const bool) ?InputBindings.HotkeyBinding {
    const input = keyboardInputFromScancode(scancode) orelse return null;
    return .{
        .input = input,
        .modifiers = hotkeyModifiersFromKeyboardState(keyboard_state),
    };
}

// Get human-readable description for a hotkey action
pub fn hotkeyActionDescription(action: InputBindings.HotkeyAction) []const u8 {
    return switch (action) {
        .toggle_help => "HELP",
        .toggle_pause => "PAUSE",
        .open_rom => "OPEN ROM",
        .restart_rom => "SOFT RESET",
        .reload_rom => "HARD RESET / RELOAD",
        .open_keyboard_editor => "KEYBOARD EDITOR",
        .toggle_performance_hud => "PERF HUD",
        .reset_performance_hud => "RESET PERF HUD",
        .save_quick_state => "SAVE QUICK STATE",
        .load_quick_state => "LOAD QUICK STATE",
        .save_state_file => "SAVE STATE FILE",
        .load_state_file => "LOAD STATE FILE",
        .next_state_slot => "NEXT STATE SLOT",
        .record_gif => "RECORD GIF",
        .record_wav => "RECORD WAV",
        .screenshot => "SCREENSHOT",
        .toggle_fullscreen => "FULLSCREEN",
        .quit => "QUIT",
    };
}

// Map SDL scancode to keyboard input binding
pub fn keyboardInputFromScancode(scancode: zsdl3.Scancode) ?InputBindings.KeyboardInput {
    return switch (scancode) {
        .up => .up,
        .down => .down,
        .left => .left,
        .right => .right,
        .a => .a,
        .s => .s,
        .d => .d,
        .q => .q,
        .w => .w,
        .e => .e,
        .r => .r,
        .f => .f,
        .h => .h,
        .i => .i,
        .j => .j,
        .k => .k,
        .l => .l,
        .m => .m,
        .n => .n,
        .o => .o,
        .p => .p,
        .u => .u,
        .z => .z,
        .x => .x,
        .c => .c,
        .v => .v,
        .@"return" => .@"return",
        .tab => .tab,
        .backspace => .backspace,
        .space => .space,
        .escape => .escape,
        .delete => .delete,
        .lshift => .lshift,
        .rshift => .rshift,
        .semicolon => .semicolon,
        .apostrophe => .apostrophe,
        .comma => .comma,
        .period => .period,
        .slash => .slash,
        .f1 => .f1,
        .f2 => .f2,
        .f3 => .f3,
        .f4 => .f4,
        .f5 => .f5,
        .f6 => .f6,
        .f7 => .f7,
        .f8 => .f8,
        .f9 => .f9,
        .f10 => .f10,
        .f11 => .f11,
        .f12 => .f12,
        .printscreen => .print_screen,
        else => null,
    };
}

const testing = @import("std").testing;

test "isHotkeyModifierScancode identifies all modifiers" {
    try testing.expect(isHotkeyModifierScancode(.lshift));
    try testing.expect(isHotkeyModifierScancode(.rshift));
    try testing.expect(isHotkeyModifierScancode(.lctrl));
    try testing.expect(isHotkeyModifierScancode(.rctrl));
    try testing.expect(isHotkeyModifierScancode(.lalt));
    try testing.expect(isHotkeyModifierScancode(.ralt));
    try testing.expect(isHotkeyModifierScancode(.lgui));
    try testing.expect(isHotkeyModifierScancode(.rgui));
    try testing.expect(!isHotkeyModifierScancode(.a));
    try testing.expect(!isHotkeyModifierScancode(.space));
    try testing.expect(!isHotkeyModifierScancode(.f1));
}

test "keyboardInputFromScancode maps arrows and letters" {
    try testing.expectEqual(InputBindings.KeyboardInput.up, keyboardInputFromScancode(.up).?);
    try testing.expectEqual(InputBindings.KeyboardInput.down, keyboardInputFromScancode(.down).?);
    try testing.expectEqual(InputBindings.KeyboardInput.a, keyboardInputFromScancode(.a).?);
    try testing.expectEqual(InputBindings.KeyboardInput.f1, keyboardInputFromScancode(.f1).?);
    try testing.expectEqual(InputBindings.KeyboardInput.@"return", keyboardInputFromScancode(.@"return").?);
    try testing.expect(keyboardInputFromScancode(.home) == null);
}

test "hotkeyActionDescription returns non-empty strings for all actions" {
    const actions = [_]InputBindings.HotkeyAction{
        .toggle_help,       .toggle_pause,     .open_rom,
        .restart_rom,       .reload_rom,       .open_keyboard_editor,
        .toggle_performance_hud, .reset_performance_hud,
        .save_quick_state,  .load_quick_state,
        .save_state_file,   .load_state_file,  .next_state_slot,
        .record_gif,        .record_wav,       .screenshot,
        .toggle_fullscreen, .quit,
    };
    for (actions) |action| {
        try testing.expect(hotkeyActionDescription(action).len > 0);
    }
}

test "keyboardStatePressed handles bounds correctly" {
    var state = [_]bool{false} ** 16;
    state[5] = true;
    // In-bounds access
    try testing.expect(keyboardStatePressed(&state, @enumFromInt(5)));
    try testing.expect(!keyboardStatePressed(&state, @enumFromInt(0)));
    // Out-of-bounds returns false
    try testing.expect(!keyboardStatePressed(&state, @enumFromInt(100)));
}
