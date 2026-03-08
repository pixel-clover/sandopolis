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
    step,
    registers,
    record_gif,
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
    lshift,
    rshift,
    semicolon,
    apostrophe,
    comma,
    period,
    slash,
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

const actions = [_]Action{
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

const hotkey_actions = [_]HotkeyAction{ .step, .registers, .record_gif, .quit };

pub const Bindings = struct {
    keyboard: [player_count][actions.len]?KeyboardInput,
    gamepad: [player_count][actions.len]?GamepadInput,
    hotkeys: [hotkey_actions.len]?KeyboardInput,
    controller_types: [player_count]ControllerType,
    gamepad_axis_threshold: i16,
    joystick_axis_threshold: i16,
    trigger_threshold: i16,

    pub fn defaults() Bindings {
        var bindings = Bindings{
            .keyboard = [_][actions.len]?KeyboardInput{[_]?KeyboardInput{null} ** actions.len} ** player_count,
            .gamepad = [_][actions.len]?GamepadInput{[_]?GamepadInput{null} ** actions.len} ** player_count,
            .hotkeys = [_]?KeyboardInput{null} ** hotkey_actions.len,
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

        bindings.setHotkey(.step, .space);
        bindings.setHotkey(.registers, .backspace);
        bindings.setHotkey(.record_gif, .r);
        bindings.setHotkey(.quit, .escape);

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
        self.hotkeys[hotkeyIndex(action)] = input;
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
        for (hotkey_actions) |action| {
            if (self.hotkeys[hotkeyIndex(action)] == input) {
                return action;
            }
        }
        return null;
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
            const input = if (std.ascii.eqlIgnoreCase(rhs, "none")) null else parseKeyboardInput(rhs) orelse return error.UnknownKeyboardInput;
            self.setHotkey(action, input);
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

fn parseKeyboardInput(name: []const u8) ?KeyboardInput {
    inline for (std.meta.fields(KeyboardInput)) |field| {
        if (std.ascii.eqlIgnoreCase(name, field.name)) {
            return @enumFromInt(field.value);
        }
    }
    return null;
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

fn parseAnalogThreshold(name: []const u8) !i16 {
    const threshold = try std.fmt.parseUnsigned(u16, name, 10);
    if (threshold > std.math.maxInt(i16)) return error.InvalidAnalogThreshold;
    return @intCast(threshold);
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
    try testing.expect(bindings.hotkeys[@intFromEnum(HotkeyAction.registers)] == null);
    try testing.expect(bindings.hotkeys[@intFromEnum(HotkeyAction.quit)] == .backspace);
    try testing.expectEqual(ControllerType.three_button, bindings.controller_types[1]);
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
    bindings.setHotkey(.registers, .space);

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
    try testing.expectEqual(HotkeyAction.registers, bindings.hotkeyForKeyboard(.space).?);
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
