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
        .step => "STEP CPU",
        .registers => "REGISTER DUMP",
        .record_gif => "RECORD GIF",
        .record_wav => "RECORD WAV",
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
        else => null,
    };
}
