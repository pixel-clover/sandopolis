const std = @import("std");
const testing = std.testing;
const Io = @import("io.zig").Io;
const ControllerType = Io.ControllerType;

pub const default_config_name = "sandopolis_input.cfg";
pub const player_count: usize = 2;
pub const default_gamepad_axis_threshold: i16 = 16_000;
pub const default_joystick_axis_threshold: i16 = 16_000;
pub const default_trigger_threshold: i16 = 16_000;

pub const Action = enum(u8) {
    up,
    down,
    left,
    right,
    a,
    b,
    c,
    x,
    y,
    z,
    mode,
    start,
};

pub const HotkeyAction = enum(u8) {
    toggle_help,
    toggle_pause,
    open_rom,
    restart_rom,
    reload_rom,
    open_keyboard_editor,
    toggle_performance_hud,
    reset_performance_hud,
    save_quick_state,
    load_quick_state,
    save_state_file,
    load_state_file,
    next_state_slot,
    step,
    registers,
    record_gif,
    record_wav,
    screenshot,
    toggle_fullscreen,
    quit,
};

pub const KeyboardInput = enum(u8) {
    up,
    down,
    left,
    right,
    a,
    s,
    d,
    q,
    w,
    e,
    r,
    f,
    h,
    i,
    j,
    k,
    l,
    m,
    n,
    o,
    p,
    u,
    z,
    x,
    c,
    v,
    @"return",
    tab,
    backspace,
    space,
    escape,
    delete,
    lshift,
    rshift,
    semicolon,
    apostrophe,
    comma,
    period,
    slash,
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
    print_screen,
};

pub const HotkeyModifiers = packed struct(u4) {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    gui: bool = false,
};

pub const HotkeyBinding = struct {
    input: ?KeyboardInput = null,
    modifiers: HotkeyModifiers = .{},
};

pub const GamepadInput = enum(u8) {
    dpad_up,
    dpad_down,
    dpad_left,
    dpad_right,
    south,
    east,
    west,
    north,
    left_shoulder,
    right_shoulder,
    back,
    start,
    guide,
    left_stick,
    right_stick,
    misc1,
    left_trigger,
    right_trigger,
};

pub const all_actions = [_]Action{
    .up,
    .down,
    .left,
    .right,
    .a,
    .b,
    .c,
    .x,
    .y,
    .z,
    .mode,
    .start,
};

pub const all_hotkey_actions = [_]HotkeyAction{
    .toggle_help,
    .toggle_pause,
    .open_rom,
    .restart_rom,
    .reload_rom,
    .open_keyboard_editor,
    .toggle_performance_hud,
    .reset_performance_hud,
    .save_quick_state,
    .load_quick_state,
    .save_state_file,
    .load_state_file,
    .next_state_slot,
    .step,
    .registers,
    .record_gif,
    .record_wav,
    .screenshot,
    .toggle_fullscreen,
    .quit,
};

const actions = all_actions;
const hotkey_actions = all_hotkey_actions;

pub const Bindings = struct {
    keyboard: [player_count][actions.len]?KeyboardInput,
    gamepad: [player_count][actions.len]?GamepadInput,
    hotkeys: [hotkey_actions.len]HotkeyBinding,
    controller_types: [player_count]ControllerType,
    gamepad_axis_threshold: i16,
    joystick_axis_threshold: i16,
    trigger_threshold: i16,

    pub fn defaults() Bindings {
        var bindings = Bindings{
            .keyboard = [_][actions.len]?KeyboardInput{[_]?KeyboardInput{null} ** actions.len} ** player_count,
            .gamepad = [_][actions.len]?GamepadInput{[_]?GamepadInput{null} ** actions.len} ** player_count,
            .hotkeys = [_]HotkeyBinding{.{}} ** hotkey_actions.len,
            .controller_types = [_]ControllerType{.six_button} ** player_count,
            .gamepad_axis_threshold = default_gamepad_axis_threshold,
            .joystick_axis_threshold = default_joystick_axis_threshold,
            .trigger_threshold = default_trigger_threshold,
        };

        bindings.setKeyboard(.up, .up);
        bindings.setKeyboard(.down, .down);
        bindings.setKeyboard(.left, .left);
        bindings.setKeyboard(.right, .right);
        bindings.setKeyboard(.a, .a);
        bindings.setKeyboard(.b, .s);
        bindings.setKeyboard(.c, .d);
        bindings.setKeyboard(.x, .q);
        bindings.setKeyboard(.y, .w);
        bindings.setKeyboard(.z, .e);
        bindings.setKeyboard(.mode, .tab);
        bindings.setKeyboard(.start, .@"return");

        bindings.setKeyboardForPort(1, .up, .i);
        bindings.setKeyboardForPort(1, .down, .k);
        bindings.setKeyboardForPort(1, .left, .j);
        bindings.setKeyboardForPort(1, .right, .l);
        bindings.setKeyboardForPort(1, .a, .u);
        bindings.setKeyboardForPort(1, .b, .o);
        bindings.setKeyboardForPort(1, .c, .p);
        bindings.setKeyboardForPort(1, .x, .semicolon);
        bindings.setKeyboardForPort(1, .y, .apostrophe);
        bindings.setKeyboardForPort(1, .z, .slash);
        bindings.setKeyboardForPort(1, .mode, .period);
        bindings.setKeyboardForPort(1, .start, .rshift);

        inline for (0..player_count) |port| {
            bindings.setGamepadForPort(port, .up, .dpad_up);
            bindings.setGamepadForPort(port, .down, .dpad_down);
            bindings.setGamepadForPort(port, .left, .dpad_left);
            bindings.setGamepadForPort(port, .right, .dpad_right);
            bindings.setGamepadForPort(port, .a, .south);
            bindings.setGamepadForPort(port, .b, .east);
            bindings.setGamepadForPort(port, .c, .right_shoulder);
            bindings.setGamepadForPort(port, .x, .west);
            bindings.setGamepadForPort(port, .y, .north);
            bindings.setGamepadForPort(port, .z, .left_shoulder);
            bindings.setGamepadForPort(port, .mode, .back);
            bindings.setGamepadForPort(port, .start, .start);
        }

        // Optimized hotkey layout (alpha v2)
        // Core controls - most intuitive keys
        bindings.setHotkey(.toggle_pause, .escape); // Escape opens pause menu
        bindings.setHotkeyWithModifiers(.quit, .q, .{ .ctrl = true }); // Ctrl+Q to quit (standard)
        bindings.setHotkeyWithModifiers(.open_rom, .o, .{ .ctrl = true }); // Ctrl+O to open (standard)
        bindings.setHotkey(.toggle_fullscreen, .f11); // F11 fullscreen (standard)

        // Reset controls - R for reset
        bindings.setHotkey(.restart_rom, .r); // R = soft reset
        bindings.setHotkeyWithModifiers(.reload_rom, .r, .{ .shift = true }); // Shift+R = hard reset

        // Save states - F5/F7 quick, F2/F4 file, F3 slot
        bindings.setHotkey(.save_quick_state, .f5); // F5 = quick save (common convention)
        bindings.setHotkey(.load_quick_state, .f7); // F7 = quick load
        bindings.setHotkey(.save_state_file, .f2); // F2 = save to slot file
        bindings.setHotkey(.load_state_file, .f4); // F4 = load from slot file
        bindings.setHotkey(.next_state_slot, .f3); // F3 = cycle slot

        // Help and tools
        bindings.setHotkey(.toggle_help, .f1); // F1 = help (standard)
        bindings.setHotkey(.open_keyboard_editor, .f8); // F8 = key config
        bindings.setHotkey(.toggle_performance_hud, .f6); // F6 = perf HUD
        bindings.setHotkey(.reset_performance_hud, .f9); // F9 = reset perf stats

        // Recording - F12 family
        bindings.setHotkey(.record_gif, .f12); // F12 = record GIF
        bindings.setHotkeyWithModifiers(.record_wav, .f12, .{ .shift = true }); // Shift+F12 = record audio
        bindings.setHotkeyWithModifiers(.screenshot, .f12, .{ .ctrl = true }); // Ctrl+F12 = screenshot

        // Debug controls
        bindings.setHotkey(.step, .backspace); // Backspace = step CPU
        bindings.setHotkey(.registers, .f10); // F10 = show registers

        return bindings;
    }

    pub fn parseContents(contents: []const u8) !Bindings {
        var bindings = defaults();
        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |raw_line| {
            const line = trimLine(raw_line);
            if (line.len == 0) continue;

            const equals = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidBindingLine;
            const lhs = std.mem.trim(u8, line[0..equals], " \t\r");
            const rhs = std.mem.trim(u8, line[equals + 1 ..], " \t\r");
            if (lhs.len == 0 or rhs.len == 0) return error.InvalidBindingLine;

            try bindings.applyAssignment(lhs, rhs);
        }

        return bindings;
    }

    pub fn loadFromFile(allocator: std.mem.Allocator, path: []const u8) !Bindings {
        const contents = try std.fs.cwd().readFileAlloc(allocator, path, 64 * 1024);
        defer allocator.free(contents);
        return parseContents(contents);
    }

    pub fn setKeyboard(self: *Bindings, action: Action, input: ?KeyboardInput) void {
        self.setKeyboardForPort(0, action, input);
    }

    pub fn setKeyboardForPort(self: *Bindings, port: usize, action: Action, input: ?KeyboardInput) void {
        self.keyboard[port][actionIndex(action)] = input;
    }

    pub fn setGamepad(self: *Bindings, action: Action, input: ?GamepadInput) void {
        self.setGamepadForPort(0, action, input);
    }

    pub fn setGamepadForPort(self: *Bindings, port: usize, action: Action, input: ?GamepadInput) void {
        self.gamepad[port][actionIndex(action)] = input;
    }

    pub fn setHotkey(self: *Bindings, action: HotkeyAction, input: ?KeyboardInput) void {
        self.setHotkeyWithModifiers(action, input, .{});
    }

    pub fn setHotkeyWithModifiers(self: *Bindings, action: HotkeyAction, input: ?KeyboardInput, modifiers: HotkeyModifiers) void {
        self.hotkeys[hotkeyIndex(action)] = .{
            .input = input,
            .modifiers = if (input == null) .{} else modifiers,
        };
    }

    pub fn setControllerType(self: *Bindings, port: usize, controller_type: ControllerType) void {
        self.controller_types[port] = controller_type;
    }

    pub fn setGamepadAxisThreshold(self: *Bindings, threshold: i16) void {
        self.gamepad_axis_threshold = threshold;
    }

    pub fn setJoystickAxisThreshold(self: *Bindings, threshold: i16) void {
        self.joystick_axis_threshold = threshold;
    }

    pub fn setTriggerThreshold(self: *Bindings, threshold: i16) void {
        self.trigger_threshold = threshold;
    }

    pub fn applyControllerTypes(self: *const Bindings, io: *Io) void {
        for (0..player_count) |port| {
            io.setControllerType(port, self.controller_types[port]);
        }
    }

    pub fn applyKeyboard(self: *const Bindings, io: *Io, input: KeyboardInput, pressed: bool) bool {
        var handled = false;
        for (0..player_count) |port| {
            for (actions) |action| {
                if (self.keyboard[port][actionIndex(action)] == input) {
                    io.setButton(port, actionToIoButton(action), pressed);
                    handled = true;
                }
            }
        }
        return handled;
    }

    pub fn releaseKeyboard(self: *const Bindings, io: *Io) void {
        for (0..player_count) |port| {
            for (actions) |action| {
                if (self.keyboard[port][actionIndex(action)] != null) {
                    io.setButton(port, actionToIoButton(action), false);
                }
            }
        }
    }

    pub fn applyGamepad(self: *const Bindings, io: *Io, port: usize, input: GamepadInput, pressed: bool) bool {
        var handled = false;
        for (actions) |action| {
            if (self.gamepad[port][actionIndex(action)] == input) {
                io.setButton(port, actionToIoButton(action), pressed);
                handled = true;
            }
        }
        return handled;
    }

    pub fn releaseGamepad(self: *const Bindings, io: *Io, port: usize) void {
        for (actions) |action| {
            if (self.gamepad[port][actionIndex(action)] != null) {
                io.setButton(port, actionToIoButton(action), false);
            }
        }
    }

    pub fn hotkeyForKeyboard(self: *const Bindings, input: KeyboardInput) ?HotkeyAction {
        return self.hotkeyForBinding(.{ .input = input });
    }

    pub fn hotkeyForBinding(self: *const Bindings, binding: HotkeyBinding) ?HotkeyAction {
        for (hotkey_actions) |action| {
            if (hotkeyBindingEql(self.hotkeys[hotkeyIndex(action)], binding)) {
                return action;
            }
        }
        return null;
    }

    pub fn keyboardBinding(self: *const Bindings, port: usize, action: Action) ?KeyboardInput {
        return self.keyboard[port][actionIndex(action)];
    }

    pub fn hotkeyBinding(self: *const Bindings, action: HotkeyAction) HotkeyBinding {
        return self.hotkeys[hotkeyIndex(action)];
    }

    pub fn writeContents(self: *const Bindings, writer: anytype) !void {
        for (0..player_count) |port| {
            try writer.print("controller.{s} = {s}\n", .{
                portName(port),
                controllerTypeName(self.controller_types[port]),
            });
        }
        try writer.writeByte('\n');

        try writer.print("analog.gamepad_axis = {d}\n", .{self.gamepad_axis_threshold});
        try writer.print("analog.joystick_axis = {d}\n", .{self.joystick_axis_threshold});
        try writer.print("analog.trigger = {d}\n", .{self.trigger_threshold});
        try writer.writeByte('\n');

        for (0..player_count) |port| {
            for (actions) |action| {
                try writer.print("keyboard.{s}.{s} = ", .{
                    portName(port),
                    actionName(action),
                });
                try writeOptionalInputName(writer, self.keyboardBinding(port, action));
                try writer.writeByte('\n');
            }
            try writer.writeByte('\n');
        }

        for (0..player_count) |port| {
            for (actions) |action| {
                try writer.print("gamepad.{s}.{s} = ", .{
                    portName(port),
                    actionName(action),
                });
                try writeOptionalInputName(writer, self.gamepad[port][actionIndex(action)]);
                try writer.writeByte('\n');
            }
            try writer.writeByte('\n');
        }

        for (hotkey_actions) |action| {
            try writer.print("hotkey.{s} = ", .{hotkeyActionName(action)});
            try writeHotkeyBinding(writer, self.hotkeyBinding(action));
            try writer.writeByte('\n');
        }
    }

    pub fn saveToFile(self: *const Bindings, path: []const u8) !void {
        var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
        defer file.close();
        var buffer: [4096]u8 = undefined;
        var writer = file.writer(&buffer);
        try self.writeContents(&writer.interface);
        try writer.interface.flush();
    }

    fn applyAssignment(self: *Bindings, lhs: []const u8, rhs: []const u8) !void {
        if (std.mem.startsWith(u8, lhs, "keyboard.")) {
            const target = try parsePortAction(lhs["keyboard.".len..]);
            const input = if (std.ascii.eqlIgnoreCase(rhs, "none")) null else parseKeyboardInput(rhs) orelse return error.UnknownKeyboardInput;
            self.setKeyboardForPort(target.port, target.action, input);
            return;
        }
        if (std.mem.startsWith(u8, lhs, "gamepad.")) {
            const target = try parsePortAction(lhs["gamepad.".len..]);
            const input = if (std.ascii.eqlIgnoreCase(rhs, "none")) null else parseGamepadInput(rhs) orelse return error.UnknownGamepadInput;
            self.setGamepadForPort(target.port, target.action, input);
            return;
        }
        if (std.mem.startsWith(u8, lhs, "hotkey.")) {
            const action = parseHotkeyAction(lhs["hotkey.".len..]) orelse return error.UnknownHotkeyAction;
            const binding = try parseHotkeyBinding(rhs);
            self.hotkeys[hotkeyIndex(action)] = binding;
            return;
        }
        if (std.mem.startsWith(u8, lhs, "controller.")) {
            const port = parsePortName(lhs["controller.".len..]) orelse return error.UnknownPort;
            const controller_type = parseControllerType(rhs) orelse return error.UnknownControllerType;
            self.setControllerType(port, controller_type);
            return;
        }
        if (std.mem.startsWith(u8, lhs, "analog.")) {
            const threshold = try parseAnalogThreshold(rhs);
            if (std.ascii.eqlIgnoreCase(lhs["analog.".len..], "gamepad_axis")) {
                self.setGamepadAxisThreshold(threshold);
                return;
            }
            if (std.ascii.eqlIgnoreCase(lhs["analog.".len..], "joystick_axis")) {
                self.setJoystickAxisThreshold(threshold);
                return;
            }
            if (std.ascii.eqlIgnoreCase(lhs["analog.".len..], "trigger")) {
                self.setTriggerThreshold(threshold);
                return;
            }
            return error.UnknownAnalogTarget;
        }

        return error.UnknownBindingTarget;
    }
};

pub fn defaultConfigPath(allocator: std.mem.Allocator) !?[]u8 {
    const env_path = std.process.getEnvVarOwned(allocator, "SANDOPOLIS_INPUT_CONFIG") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    if (env_path) |path| return path;

    std.fs.cwd().access(default_config_name, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };

    return try allocator.dupe(u8, default_config_name);
}

pub fn actionName(action: Action) []const u8 {
    return @tagName(action);
}

pub fn hotkeyActionName(action: HotkeyAction) []const u8 {
    return @tagName(action);
}

pub fn keyboardInputName(input: KeyboardInput) []const u8 {
    return @tagName(input);
}

pub fn hotkeyBindingDisplayName(buffer: []u8, binding: HotkeyBinding) ![]const u8 {
    const input = binding.input orelse return std.fmt.bufPrint(buffer, "NONE", .{});

    var stream = std.io.fixedBufferStream(buffer);
    const writer = stream.writer();

    if (binding.modifiers.ctrl) try writer.writeAll("CTRL+");
    if (binding.modifiers.alt) try writer.writeAll("ALT+");
    if (binding.modifiers.shift) try writer.writeAll("SHIFT+");
    if (binding.modifiers.gui) try writer.writeAll("GUI+");
    try writeKeyboardInputDisplay(writer, input);

    return stream.getWritten();
}

pub fn gamepadInputName(input: GamepadInput) []const u8 {
    return @tagName(input);
}

fn trimLine(raw_line: []const u8) []const u8 {
    const line_without_comment = if (std.mem.indexOfAny(u8, raw_line, "#;")) |comment_start|
        raw_line[0..comment_start]
    else
        raw_line;
    return std.mem.trim(u8, line_without_comment, " \t\r");
}

fn actionIndex(action: Action) usize {
    return @intFromEnum(action);
}

fn hotkeyIndex(action: HotkeyAction) usize {
    return @intFromEnum(action);
}

fn hotkeyBindingEql(a: HotkeyBinding, b: HotkeyBinding) bool {
    if (a.input != b.input) return false;
    if (a.input == null) return true;
    return @as(u4, @bitCast(a.modifiers)) == @as(u4, @bitCast(b.modifiers));
}

fn actionToIoButton(action: Action) u16 {
    return switch (action) {
        .up => Io.Button.Up,
        .down => Io.Button.Down,
        .left => Io.Button.Left,
        .right => Io.Button.Right,
        .a => Io.Button.A,
        .b => Io.Button.B,
        .c => Io.Button.C,
        .x => Io.Button.X,
        .y => Io.Button.Y,
        .z => Io.Button.Z,
        .mode => Io.Button.Mode,
        .start => Io.Button.Start,
    };
}

const PortActionTarget = struct {
    port: usize,
    action: Action,
};

fn parsePortAction(name: []const u8) !PortActionTarget {
    if (std.mem.indexOfScalar(u8, name, '.')) |dot| {
        const port_name = name[0..dot];
        const action_name = name[dot + 1 ..];
        const port = parsePortName(port_name) orelse return error.UnknownPort;
        const action = parseAction(action_name) orelse return error.UnknownAction;
        return .{ .port = port, .action = action };
    }

    const action = parseAction(name) orelse return error.UnknownAction;
    return .{ .port = 0, .action = action };
}

fn parsePortName(name: []const u8) ?usize {
    if (std.ascii.eqlIgnoreCase(name, "p1")) return 0;
    if (std.ascii.eqlIgnoreCase(name, "p2")) return 1;
    return null;
}

fn portName(port: usize) []const u8 {
    return switch (port) {
        0 => "p1",
        1 => "p2",
        else => unreachable,
    };
}

fn parseAction(name: []const u8) ?Action {
    inline for (std.meta.fields(Action)) |field| {
        if (std.ascii.eqlIgnoreCase(name, field.name)) {
            return @enumFromInt(field.value);
        }
    }
    return null;
}

fn parseHotkeyAction(name: []const u8) ?HotkeyAction {
    inline for (std.meta.fields(HotkeyAction)) |field| {
        if (std.ascii.eqlIgnoreCase(name, field.name)) {
            return @enumFromInt(field.value);
        }
    }
    return null;
}

fn parseHotkeyBinding(name: []const u8) !HotkeyBinding {
    const trimmed = std.mem.trim(u8, name, " \t\r");
    if (std.ascii.eqlIgnoreCase(trimmed, "none")) return .{};

    var binding = HotkeyBinding{};
    var saw_input = false;
    var tokens = std.mem.splitScalar(u8, trimmed, '+');
    while (tokens.next()) |raw_token| {
        const token = std.mem.trim(u8, raw_token, " \t\r");
        if (token.len == 0) return error.InvalidHotkeyBinding;

        if (std.ascii.eqlIgnoreCase(token, "shift")) {
            binding.modifiers.shift = true;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(token, "ctrl") or std.ascii.eqlIgnoreCase(token, "control")) {
            binding.modifiers.ctrl = true;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(token, "alt")) {
            binding.modifiers.alt = true;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(token, "gui") or
            std.ascii.eqlIgnoreCase(token, "meta") or
            std.ascii.eqlIgnoreCase(token, "super"))
        {
            binding.modifiers.gui = true;
            continue;
        }

        if (saw_input) return error.InvalidHotkeyBinding;
        binding.input = parseKeyboardInput(token) orelse return error.UnknownKeyboardInput;
        saw_input = true;
    }

    if (!saw_input) return error.InvalidHotkeyBinding;
    return binding;
}

fn parseKeyboardInput(name: []const u8) ?KeyboardInput {
    inline for (std.meta.fields(KeyboardInput)) |field| {
        if (std.ascii.eqlIgnoreCase(name, field.name)) {
            return @enumFromInt(field.value);
        }
    }
    return null;
}

fn writeKeyboardInputDisplay(writer: anytype, input: KeyboardInput) !void {
    switch (input) {
        .@"return" => return writer.writeAll("ENTER"),
        .escape => return writer.writeAll("ESC"),
        .delete => return writer.writeAll("DELETE"),
        .backspace => return writer.writeAll("BACKSPACE"),
        .space => return writer.writeAll("SPACE"),
        .tab => return writer.writeAll("TAB"),
        .semicolon => return writer.writeAll(";"),
        .apostrophe => return writer.writeAll("'"),
        .comma => return writer.writeAll(","),
        .period => return writer.writeAll("."),
        .slash => return writer.writeAll("/"),
        else => {},
    }

    for (@tagName(input)) |ch| {
        try writer.writeByte(std.ascii.toUpper(ch));
    }
}

fn parseGamepadInput(name: []const u8) ?GamepadInput {
    inline for (std.meta.fields(GamepadInput)) |field| {
        if (std.ascii.eqlIgnoreCase(name, field.name)) {
            return @enumFromInt(field.value);
        }
    }
    return null;
}

fn parseControllerType(name: []const u8) ?ControllerType {
    if (std.ascii.eqlIgnoreCase(name, "three_button") or
        std.ascii.eqlIgnoreCase(name, "three") or
        std.ascii.eqlIgnoreCase(name, "3button") or
        std.ascii.eqlIgnoreCase(name, "3-button"))
    {
        return .three_button;
    }
    if (std.ascii.eqlIgnoreCase(name, "six_button") or
        std.ascii.eqlIgnoreCase(name, "six") or
        std.ascii.eqlIgnoreCase(name, "6button") or
        std.ascii.eqlIgnoreCase(name, "6-button"))
    {
        return .six_button;
    }
    return null;
}

fn controllerTypeName(controller_type: ControllerType) []const u8 {
    return switch (controller_type) {
        .three_button => "three_button",
        .six_button => "six_button",
        .ea_4way_play => "ea_4way_play",
    };
}

fn parseAnalogThreshold(name: []const u8) !i16 {
    const threshold = try std.fmt.parseUnsigned(u16, name, 10);
    if (threshold > std.math.maxInt(i16)) return error.InvalidAnalogThreshold;
    return @intCast(threshold);
}

fn writeOptionalInputName(writer: anytype, input: anytype) !void {
    if (input) |value| {
        try writer.writeAll(@tagName(value));
    } else {
        try writer.writeAll("none");
    }
}

fn writeHotkeyBinding(writer: anytype, binding: HotkeyBinding) !void {
    if (binding.input) |input| {
        if (binding.modifiers.ctrl) try writer.writeAll("ctrl+");
        if (binding.modifiers.alt) try writer.writeAll("alt+");
        if (binding.modifiers.shift) try writer.writeAll("shift+");
        if (binding.modifiers.gui) try writer.writeAll("gui+");
        try writer.writeAll(@tagName(input));
    } else {
        try writer.writeAll("none");
    }
}

test "input bindings parse overrides and unbinds" {
    const bindings = try Bindings.parseContents(
        \\# Player 1 remap
        \\keyboard.a = q
        \\keyboard.b = none
        \\keyboard.p2.start = rshift
        \\gamepad.p2.start = guide
        \\gamepad.mode = misc1
        \\analog.gamepad_axis = 12000
        \\analog.trigger = 20000
        \\hotkey.reload_rom = ctrl+shift+f3
        \\hotkey.registers = none
        \\hotkey.quit = backspace
        \\controller.p2 = three_button
    );

    try testing.expect(bindings.keyboard[0][@intFromEnum(Action.a)] == .q);
    try testing.expect(bindings.keyboard[0][@intFromEnum(Action.b)] == null);
    try testing.expect(bindings.keyboard[1][@intFromEnum(Action.start)] == .rshift);
    try testing.expect(bindings.gamepad[1][@intFromEnum(Action.start)] == .guide);
    try testing.expect(bindings.gamepad[0][@intFromEnum(Action.mode)] == .misc1);
    try testing.expectEqual(@as(i16, 12_000), bindings.gamepad_axis_threshold);
    try testing.expectEqual(@as(i16, default_joystick_axis_threshold), bindings.joystick_axis_threshold);
    try testing.expectEqual(@as(i16, 20_000), bindings.trigger_threshold);
    try testing.expectEqual(HotkeyBinding{}, bindings.hotkeys[@intFromEnum(HotkeyAction.registers)]);
    try testing.expectEqual(HotkeyBinding{ .input = .backspace }, bindings.hotkeys[@intFromEnum(HotkeyAction.quit)]);
    try testing.expectEqual(
        HotkeyBinding{ .input = .f3, .modifiers = .{ .shift = true, .ctrl = true } },
        bindings.hotkeys[@intFromEnum(HotkeyAction.reload_rom)],
    );
    try testing.expectEqual(ControllerType.three_button, bindings.controller_types[1]);
}

test "default hotkeys distinguish open rom soft reset and hard reload" {
    const bindings = Bindings.defaults();

    // open_rom = Ctrl+O
    try testing.expectEqual(HotkeyBinding{ .input = .o, .modifiers = .{ .ctrl = true } }, bindings.hotkeyBinding(.open_rom));
    // restart_rom (soft reset) = R
    try testing.expectEqual(
        HotkeyBinding{ .input = .r },
        bindings.hotkeyBinding(.restart_rom),
    );
    // reload_rom (hard reset) = Shift+R
    try testing.expectEqual(
        HotkeyBinding{ .input = .r, .modifiers = .{ .shift = true } },
        bindings.hotkeyBinding(.reload_rom),
    );
    try testing.expectEqual(HotkeyAction.open_rom, bindings.hotkeyForBinding(.{ .input = .o, .modifiers = .{ .ctrl = true } }).?);
    try testing.expectEqual(
        HotkeyAction.restart_rom,
        bindings.hotkeyForBinding(.{ .input = .r }).?,
    );
    try testing.expectEqual(
        HotkeyAction.reload_rom,
        bindings.hotkeyForBinding(.{ .input = .r, .modifiers = .{ .shift = true } }).?,
    );
}

test "input bindings apply remapped inputs" {
    var io = Io.init();
    var bindings = Bindings.defaults();
    bindings.setKeyboard(.a, null);
    bindings.setKeyboardForPort(1, .x, .q);
    bindings.setGamepad(.a, .left_trigger);
    bindings.setGamepad(.mode, .guide);
    bindings.setGamepadForPort(1, .c, .left_stick);
    bindings.setHotkey(.step, .backspace);
    bindings.setHotkeyWithModifiers(.registers, .space, .{ .shift = true });

    try testing.expect(bindings.applyKeyboard(&io, .q, true));
    try testing.expectEqual(@as(u16, 0), io.pad[1] & Io.Button.X);
    try testing.expect((io.pad[0] & Io.Button.A) != 0);

    io.setButton(1, Io.Button.X, false);
    try testing.expect(bindings.applyGamepad(&io, 1, .left_stick, true));
    try testing.expectEqual(@as(u16, 0), io.pad[1] & Io.Button.C);
    try testing.expect(bindings.applyGamepad(&io, 0, .left_trigger, true));
    try testing.expectEqual(@as(u16, 0), io.pad[0] & Io.Button.A);
    io.setButton(0, Io.Button.A, false);
    try testing.expect(bindings.applyGamepad(&io, 0, .guide, true));
    try testing.expectEqual(@as(u16, 0), io.pad[0] & Io.Button.Mode);
    try testing.expectEqual(HotkeyAction.step, bindings.hotkeyForKeyboard(.backspace).?);
    try testing.expectEqual(
        HotkeyAction.registers,
        bindings.hotkeyForBinding(.{ .input = .space, .modifiers = .{ .shift = true } }).?,
    );
    try testing.expect(bindings.hotkeyForKeyboard(.space) == null);
}

test "input bindings release mapped keyboard inputs for both ports" {
    var io = Io.init();
    const bindings = Bindings.defaults();

    _ = bindings.applyKeyboard(&io, .a, true);
    _ = bindings.applyKeyboard(&io, .u, true);
    try testing.expectEqual(@as(u16, 0), io.pad[0] & Io.Button.A);
    try testing.expectEqual(@as(u16, 0), io.pad[1] & Io.Button.A);

    bindings.releaseKeyboard(&io);

    try testing.expect((io.pad[0] & Io.Button.A) != 0);
    try testing.expect((io.pad[1] & Io.Button.A) != 0);
}

test "input bindings write contents round trip" {
    var bindings = Bindings.defaults();
    bindings.setKeyboard(.a, .q);
    bindings.setKeyboardForPort(1, .start, null);
    bindings.setHotkeyWithModifiers(.quit, .backspace, .{ .ctrl = true });
    bindings.setControllerType(1, .three_button);
    bindings.setGamepadAxisThreshold(12_345);

    var output = std.ArrayList(u8).empty;
    defer output.deinit(testing.allocator);
    try bindings.writeContents(output.writer(testing.allocator));

    const round_tripped = try Bindings.parseContents(output.items);
    try testing.expectEqual(@as(?KeyboardInput, .q), round_tripped.keyboardBinding(0, .a));
    try testing.expectEqual(@as(?KeyboardInput, null), round_tripped.keyboardBinding(1, .start));
    try testing.expectEqual(
        HotkeyBinding{ .input = .backspace, .modifiers = .{ .ctrl = true } },
        round_tripped.hotkeyBinding(.quit),
    );
    try testing.expectEqual(ControllerType.three_button, round_tripped.controller_types[1]);
    try testing.expectEqual(@as(i16, 12_345), round_tripped.gamepad_axis_threshold);
}

test "hotkey bindings format display names with modifiers" {
    var buffer: [32]u8 = undefined;

    try testing.expectEqualStrings("SHIFT+F3", try hotkeyBindingDisplayName(
        buffer[0..],
        .{ .input = .f3, .modifiers = .{ .shift = true } },
    ));

    try testing.expectEqualStrings("NONE", try hotkeyBindingDisplayName(buffer[0..], .{}));
}

test "input bindings reject hotkey entries without a primary key" {
    try testing.expectError(error.InvalidHotkeyBinding, Bindings.parseContents(
        \\hotkey.restart_rom = shift
    ));
}

test "input bindings reject out-of-range analog thresholds" {
    try testing.expectError(error.InvalidAnalogThreshold, Bindings.parseContents(
        \\analog.trigger = 40000
    ));
}

test "input bindings apply configured controller types" {
    var io = Io.init();
    var bindings = Bindings.defaults();
    bindings.setControllerType(1, .three_button);

    bindings.applyControllerTypes(&io);

    try testing.expectEqual(ControllerType.six_button, io.getControllerType(0));
    try testing.expectEqual(ControllerType.three_button, io.getControllerType(1));
}

test "input bindings release mapped gamepad inputs for one port" {
    var io = Io.init();
    const bindings = Bindings.defaults();

    io.setButton(0, Io.Button.Up, true);
    io.setButton(0, Io.Button.A, true);
    io.setButton(1, Io.Button.Up, true);

    bindings.releaseGamepad(&io, 0);

    try testing.expect((io.pad[0] & Io.Button.Up) != 0);
    try testing.expect((io.pad[0] & Io.Button.A) != 0);
    try testing.expectEqual(@as(u16, 0), io.pad[1] & Io.Button.Up);
}
