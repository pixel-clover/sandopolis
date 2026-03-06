const std = @import("std");
const Io = @import("io.zig").Io;

pub const default_config_name = "sandopolis_input.cfg";
pub const player_count: usize = 2;

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

const hotkey_actions = [_]HotkeyAction{ .step, .quit };

pub const Bindings = struct {
    keyboard: [player_count][actions.len]?KeyboardInput,
    gamepad: [player_count][actions.len]?GamepadInput,
    hotkeys: [hotkey_actions.len]?KeyboardInput,

    pub fn defaults() Bindings {
        var bindings = Bindings{
            .keyboard = [_][actions.len]?KeyboardInput{[_]?KeyboardInput{null} ** actions.len} ** player_count,
            .gamepad = [_][actions.len]?GamepadInput{[_]?GamepadInput{null} ** actions.len} ** player_count,
            .hotkeys = [_]?KeyboardInput{null} ** hotkey_actions.len,
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
