const std = @import("std");
const build_options = @import("build_options");
const zsdl3 = @import("zsdl3");
const clock = @import("clock.zig");
const AudioOutput = @import("audio/output.zig").AudioOutput;
const Io = @import("input/io.zig").Io;
const InputBindings = @import("input/mapping.zig");
const Machine = @import("machine.zig").Machine;
const GifRecorder = @import("recording/gif.zig").GifRecorder;

const AudioInit = struct {
    stream: *zsdl3.AudioStream,
    output: AudioOutput,
};

const SdlAudioSpecRaw = extern struct {
    format: zsdl3.AudioFormat,
    channels: c_int,
    freq: c_int,
};

const GamepadSlot = struct {
    id: zsdl3.Joystick.Id,
    handle: *zsdl3.Gamepad,
};

const SdlJoystick = opaque {};

const JoystickSlot = struct {
    id: zsdl3.Joystick.Id,
    handle: *SdlJoystick,
};

const DirectionState = struct {
    left: bool = false,
    right: bool = false,
    up: bool = false,
    down: bool = false,
};

const TriggerState = struct {
    left: bool = false,
    right: bool = false,
};

const GamepadTransition = struct {
    input: InputBindings.GamepadInput,
    pressed: bool,
};

const max_input_transitions: usize = 4;
const joystick_hat_up: u8 = 0x01;
const joystick_hat_right: u8 = 0x02;
const joystick_hat_down: u8 = 0x04;
const joystick_hat_left: u8 = 0x08;

fn frameDurationNs(is_pal: bool) u64 {
    const master_cycles_per_frame: u32 = if (is_pal) clock.pal_master_cycles_per_frame else clock.ntsc_master_cycles_per_frame;
    const master_clock: u32 = if (is_pal) clock.master_clock_pal else clock.master_clock_ntsc;
    return @intCast((@as(u128, master_cycles_per_frame) * std.time.ns_per_s) / master_clock);
}

fn uncappedBootFrames(audio_enabled: bool) u32 {
    return if (audio_enabled) 0 else 240;
}

const FrontendUi = struct {
    paused: bool = false,
    show_help: bool = false,
    dialog_active: bool = false,

    fn emulationPaused(self: *const FrontendUi) bool {
        return self.paused or self.show_help or self.dialog_active;
    }
};

const FrontendShortcut = enum {
    toggle_help,
    toggle_pause,
    open_rom,
};

const max_dialog_message_bytes: usize = 256;

const DialogPathCopy = struct {
    len: usize = 0,
    bytes: [std.fs.max_path_bytes]u8 = [_]u8{0} ** std.fs.max_path_bytes,

    fn slice(self: *const DialogPathCopy) []const u8 {
        return self.bytes[0..self.len];
    }
};

const DialogMessageCopy = struct {
    len: usize = 0,
    bytes: [max_dialog_message_bytes]u8 = [_]u8{0} ** max_dialog_message_bytes,

    fn slice(self: *const DialogMessageCopy) []const u8 {
        return self.bytes[0..self.len];
    }
};

const FileDialogOutcome = union(enum) {
    none,
    selected: DialogPathCopy,
    canceled,
    failed: DialogMessageCopy,
};

const FileDialogState = struct {
    mutex: std.Thread.Mutex = .{},
    in_flight: bool = false,
    selected_path: DialogPathCopy = .{},
    failure_message: DialogMessageCopy = .{},
    outcome: enum {
        idle,
        selected,
        canceled,
        failed,
    } = .idle,

    fn begin(self: *FileDialogState) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.in_flight) return false;
        self.in_flight = true;
        self.outcome = .idle;
        self.selected_path = .{};
        self.failure_message = .{};
        return true;
    }

    fn finishSelected(self: *FileDialogState, path: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (path.len > self.selected_path.bytes.len) {
            self.writeFailureLocked("SELECTED PATH TOO LONG");
            return;
        }
        self.selected_path = .{};
        @memcpy(self.selected_path.bytes[0..path.len], path);
        self.selected_path.len = path.len;
        self.outcome = .selected;
        self.in_flight = false;
    }

    fn finishCanceled(self: *FileDialogState) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.outcome = .canceled;
        self.in_flight = false;
    }

    fn finishFailed(self: *FileDialogState, message: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.writeFailureLocked(message);
    }

    fn take(self: *FileDialogState) FileDialogOutcome {
        self.mutex.lock();
        defer self.mutex.unlock();
        const result: FileDialogOutcome = switch (self.outcome) {
            .idle => .none,
            .selected => .{ .selected = self.selected_path },
            .canceled => .canceled,
            .failed => .{ .failed = self.failure_message },
        };
        self.outcome = .idle;
        return result;
    }

    fn writeFailureLocked(self: *FileDialogState, message: []const u8) void {
        self.failure_message = .{};
        const len = @min(message.len, self.failure_message.bytes.len);
        @memcpy(self.failure_message.bytes[0..len], message[0..len]);
        self.failure_message.len = len;
        self.outcome = .failed;
        self.in_flight = false;
    }
};

const SdlDialogFileFilter = extern struct {
    name: [*c]const u8,
    pattern: [*c]const u8,
};

const rom_dialog_filters = [_]SdlDialogFileFilter{
    .{ .name = "Genesis ROMs", .pattern = "bin;md;smd;gen" },
    .{ .name = "All files", .pattern = "*" },
};

const CliOptions = struct {
    rom_path: ?[]const u8 = null,
    audio_mode: AudioOutput.RenderMode = .normal,
    show_help: bool = false,
};

const ParseCliError = error{
    InvalidAudioMode,
    MissingAudioModeValue,
    MultipleRomPaths,
    UnknownOption,
};

fn audioRenderModeName(mode: AudioOutput.RenderMode) []const u8 {
    return switch (mode) {
        .normal => "normal",
        .ym_only => "ym-only",
        .psg_only => "psg-only",
        .unfiltered_mix => "unfiltered-mix",
    };
}

fn parseAudioRenderMode(value: []const u8) ParseCliError!AudioOutput.RenderMode {
    if (std.mem.eql(u8, value, "normal")) return .normal;
    if (std.mem.eql(u8, value, "ym-only") or std.mem.eql(u8, value, "ym_only")) return .ym_only;
    if (std.mem.eql(u8, value, "psg-only") or std.mem.eql(u8, value, "psg_only")) return .psg_only;
    if (std.mem.eql(u8, value, "unfiltered-mix") or std.mem.eql(u8, value, "unfiltered_mix")) return .unfiltered_mix;
    return error.InvalidAudioMode;
}

fn cliErrorMessage(err: ParseCliError) []const u8 {
    return switch (err) {
        error.InvalidAudioMode => "invalid --audio-mode value",
        error.MissingAudioModeValue => "--audio-mode requires a value",
        error.MultipleRomPaths => "only one ROM path may be provided",
        error.UnknownOption => "unknown option",
    };
}

fn frontendShortcutForKey(scancode: zsdl3.Scancode, pressed: bool) ?FrontendShortcut {
    if (!pressed) return null;
    return switch (scancode) {
        .f1 => .toggle_help,
        .f2 => .toggle_pause,
        .f3 => .open_rom,
        else => null,
    };
}

fn applyFrontendShortcut(ui: *FrontendUi, scancode: zsdl3.Scancode, pressed: bool) bool {
    const shortcut = frontendShortcutForKey(scancode, pressed) orelse return false;
    switch (shortcut) {
        .toggle_help => ui.show_help = !ui.show_help,
        .toggle_pause => ui.paused = !ui.paused,
        .open_rom => {},
    }
    return true;
}

fn openRomDialogCallback(
    userdata: ?*anyopaque,
    filelist: [*c]const [*c]const u8,
    filter: c_int,
) callconv(.c) void {
    _ = filter;
    const dialog_state: *FileDialogState = @ptrCast(@alignCast(userdata orelse return));
    if (filelist == null) {
        const message = if (zsdl3.getError()) |err| err else "FILE DIALOG ERROR";
        dialog_state.finishFailed(message);
        return;
    }

    const selected_list = filelist;
    if (selected_list[0] == null) {
        dialog_state.finishCanceled();
        return;
    }

    const selected_path = selected_list[0];
    dialog_state.finishSelected(std.mem.span(@as([*:0]const u8, @ptrCast(selected_path))));
}

fn launchOpenRomDialog(dialog_state: *FileDialogState, ui: *FrontendUi, window: *zsdl3.Window) bool {
    if (!dialog_state.begin()) return false;
    ui.dialog_active = true;
    ui.show_help = false;
    SDL_ShowOpenFileDialog(
        openRomDialogCallback,
        dialog_state,
        window,
        &rom_dialog_filters,
        @intCast(rom_dialog_filters.len),
        null,
        false,
    );
    return true;
}

fn resetAudioOutput(audio: *AudioInit) void {
    zsdl3.clearAudioStream(audio.stream) catch |err| {
        std.debug.print("Failed to clear queued audio on ROM load: {}\n", .{err});
    };
    audio.output.reset();
}

fn stopGifRecording(gif_recorder: *?GifRecorder, reason: []const u8) void {
    if (gif_recorder.*) |*rec| {
        const frames = rec.frame_count;
        rec.finish();
        gif_recorder.* = null;
        std.debug.print("{s} ({d} frames)\n", .{ reason, frames });
    }
}

fn logLoadedRomMetadata(machine: *Machine, rom_path: []const u8) void {
    const bus = &machine.bus;
    std.debug.print("Loading ROM: {s}\n", .{rom_path});
    if (bus.rom.len >= 0x200) {
        const console = bus.rom[0x100..0x110];
        const title = bus.rom[0x150..0x180];
        std.debug.print("Console: {s}\n", .{console});
        std.debug.print("Title:   {s}\n", .{title});
    }
    const ssp = bus.read32(0x000000);
    const pc = bus.read32(0x000004);
    std.debug.print("Reset Vectors: SSP={X:0>8} PC={X:0>8}\n", .{ ssp, pc });
}

fn loadRomIntoMachine(
    allocator: std.mem.Allocator,
    machine: *Machine,
    input_bindings: *const InputBindings.Bindings,
    audio: ?*AudioInit,
    gif_recorder: *?GifRecorder,
    frame_counter: *u32,
    rom_path: []const u8,
) !void {
    var next_machine = try Machine.init(allocator, rom_path);
    errdefer next_machine.deinit(allocator);

    logLoadedRomMetadata(&next_machine, rom_path);
    next_machine.reset();
    input_bindings.applyControllerTypes(&next_machine.bus.io);
    std.debug.print("CPU Reset complete.\n", .{});
    next_machine.debugDump();

    stopGifRecording(gif_recorder, "GIF recording stopped for ROM switch");
    if (audio) |a| {
        resetAudioOutput(a);
    }

    machine.flushPersistentStorage() catch |err| {
        std.debug.print("Failed to flush persistent SRAM before ROM load: {s}\n", .{@errorName(err)});
    };

    var old_machine = machine.*;
    machine.* = next_machine;
    old_machine.deinit(allocator);
    frame_counter.* = 0;
}

fn printUsage() void {
    std.debug.print("Usage: sandopolis [options] [rom_file]\n", .{});
    std.debug.print("Options:\n", .{});
    std.debug.print("  --audio-mode <mode>   Audio render mode: normal, ym-only, psg-only, unfiltered-mix\n", .{});
    std.debug.print("  --audio-mode=<mode>   Same as above\n", .{});
    std.debug.print("  -h, --help            Show this help text\n", .{});
}

fn parseCliArgs(args: []const []const u8) ParseCliError!CliOptions {
    var options = CliOptions{};
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            options.show_help = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--audio-mode")) {
            index += 1;
            if (index >= args.len) return error.MissingAudioModeValue;
            options.audio_mode = try parseAudioRenderMode(args[index]);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--audio-mode=")) {
            options.audio_mode = try parseAudioRenderMode(arg["--audio-mode=".len..]);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--")) return error.UnknownOption;
        if (options.rom_path != null) return error.MultipleRomPaths;
        options.rom_path = arg;
    }
    return options;
}

fn formatName(format: zsdl3.AudioFormat) []const u8 {
    return switch (format) {
        .S16LE => "S16LE",
        .S16BE => "S16BE",
        .F32LE => "F32LE",
        .F32BE => "F32BE",
        else => "unknown",
    };
}

fn keyboardInputFromScancode(scancode: zsdl3.Scancode) ?InputBindings.KeyboardInput {
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
        .lshift => .lshift,
        .rshift => .rshift,
        .semicolon => .semicolon,
        .apostrophe => .apostrophe,
        .comma => .comma,
        .period => .period,
        .slash => .slash,
        .f11 => .f11,
        else => null,
    };
}

fn gamepadInputFromButton(button: u8) ?InputBindings.GamepadInput {
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

fn joystickInputFromButton(button: u8) ?InputBindings.GamepadInput {
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

fn updateAxisPair(
    negative: *bool,
    positive: *bool,
    value: i16,
    threshold: i16,
    negative_input: InputBindings.GamepadInput,
    positive_input: InputBindings.GamepadInput,
) [max_input_transitions]?GamepadTransition {
    var transitions = [_]?GamepadTransition{null} ** max_input_transitions;
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

fn updateLeftStickState(
    state: *DirectionState,
    axis: zsdl3.Gamepad.Axis,
    value: i16,
    threshold: i16,
) [max_input_transitions]?GamepadTransition {
    return switch (axis) {
        .leftx => updateAxisPair(&state.left, &state.right, value, threshold, .dpad_left, .dpad_right),
        .lefty => updateAxisPair(&state.up, &state.down, value, threshold, .dpad_up, .dpad_down),
        else => [_]?GamepadTransition{null} ** max_input_transitions,
    };
}

fn updateTriggerState(
    state: *bool,
    value: i16,
    threshold: i16,
    input: InputBindings.GamepadInput,
) [max_input_transitions]?GamepadTransition {
    var transitions = [_]?GamepadTransition{null} ** max_input_transitions;
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

fn updateGamepadAxisState(
    stick_state: *DirectionState,
    trigger_state: *TriggerState,
    axis: zsdl3.Gamepad.Axis,
    value: i16,
    axis_threshold: i16,
    trigger_threshold: i16,
) [max_input_transitions]?GamepadTransition {
    return switch (axis) {
        .leftx, .lefty => updateLeftStickState(stick_state, axis, value, axis_threshold),
        .left_trigger => updateTriggerState(&trigger_state.left, value, trigger_threshold, .left_trigger),
        .right_trigger => updateTriggerState(&trigger_state.right, value, trigger_threshold, .right_trigger),
        else => [_]?GamepadTransition{null} ** max_input_transitions,
    };
}

fn updateJoystickAxisState(
    state: *DirectionState,
    axis: u8,
    value: i16,
    threshold: i16,
) [max_input_transitions]?GamepadTransition {
    return switch (axis) {
        0 => updateAxisPair(&state.left, &state.right, value, threshold, .dpad_left, .dpad_right),
        1 => updateAxisPair(&state.up, &state.down, value, threshold, .dpad_up, .dpad_down),
        else => [_]?GamepadTransition{null} ** max_input_transitions,
    };
}

fn updateHatState(state: *DirectionState, value: u8) [max_input_transitions]?GamepadTransition {
    var transitions = [_]?GamepadTransition{null} ** max_input_transitions;
    var next_index: usize = 0;
    const next_up = (value & joystick_hat_up) != 0;
    const next_down = (value & joystick_hat_down) != 0;
    const next_left = (value & joystick_hat_left) != 0;
    const next_right = (value & joystick_hat_right) != 0;

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

fn applyInputTransitions(
    bindings: *const InputBindings.Bindings,
    io: *Io,
    port: usize,
    transitions: anytype,
) void {
    for (transitions) |maybe_transition| {
        if (maybe_transition) |transition| {
            _ = bindings.applyGamepad(io, port, transition.input, transition.pressed);
        }
    }
}

fn findGamepadPort(gamepads: *const [InputBindings.player_count]?GamepadSlot, id: zsdl3.Joystick.Id) ?usize {
    for (gamepads, 0..) |slot, port| {
        if (slot) |assigned| {
            if (assigned.id == id) return port;
        }
    }
    return null;
}

fn findJoystickPort(joysticks: *const [InputBindings.player_count]?JoystickSlot, id: zsdl3.Joystick.Id) ?usize {
    for (joysticks, 0..) |slot, port| {
        if (slot) |assigned| {
            if (assigned.id == id) return port;
        }
    }
    return null;
}

fn portOccupied(
    gamepads: *const [InputBindings.player_count]?GamepadSlot,
    joysticks: *const [InputBindings.player_count]?JoystickSlot,
    port: usize,
) bool {
    return gamepads[port] != null or joysticks[port] != null;
}

fn assignGamepadSlot(
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

fn removeGamepadSlot(
    gamepads: *[InputBindings.player_count]?GamepadSlot,
    stick_states: *[InputBindings.player_count]DirectionState,
    trigger_states: *[InputBindings.player_count]TriggerState,
    bindings: *const InputBindings.Bindings,
    io: *Io,
    id: zsdl3.Joystick.Id,
) void {
    for (gamepads, 0..) |slot, port| {
        if (slot) |assigned| {
            if (assigned.id == id) {
                bindings.releaseGamepad(io, port);
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

fn assignJoystickSlot(
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

fn removeJoystickSlot(
    joysticks: *[InputBindings.player_count]?JoystickSlot,
    axis_states: *[InputBindings.player_count]DirectionState,
    hat_states: *[InputBindings.player_count]DirectionState,
    bindings: *const InputBindings.Bindings,
    io: *Io,
    id: zsdl3.Joystick.Id,
) void {
    for (joysticks, 0..) |slot, port| {
        if (slot) |assigned| {
            if (assigned.id == id) {
                bindings.releaseGamepad(io, port);
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

fn tryInitAudio(userdata: *u8) ?AudioInit {
    const playback_device: zsdl3.AudioDeviceId = @enumFromInt(zsdl3.AUDIO_DEVICE_DEFAULT_PLAYBACK);
    const candidate_formats = [_]zsdl3.AudioFormat{
        zsdl3.AudioFormat.S16,
    };
    const candidate_rates = [_]c_int{AudioOutput.output_rate};

    for (candidate_formats) |format| {
        for (candidate_rates) |freq| {
            const spec = SdlAudioSpecRaw{
                .format = format,
                .channels = 2,
                .freq = freq,
            };
            if (SDL_OpenAudioDeviceStream(playback_device, &spec, null, userdata)) |stream| {
                const audio_device = zsdl3.getAudioStreamDevice(stream);
                _ = zsdl3.resumeAudioDevice(audio_device);
                std.debug.print("Audio enabled: {s} {d}Hz\n", .{ formatName(format), freq });
                return .{
                    .stream = stream,
                    .output = AudioOutput{ .stream = stream },
                };
            }
        }
    }

    return null;
}

fn overlayScale(viewport: zsdl3.Rect) f32 {
    const min_dimension = @min(viewport.w, viewport.h);
    if (min_dimension < 360) return 1.0;
    if (min_dimension < 720) return 2.0;
    return 3.0;
}

fn overlayGlyphRows(ch: u8) [7]u8 {
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
        else => .{ 0x0E, 0x11, 0x01, 0x02, 0x04, 0x00, 0x04 },
    };
}

fn overlayTextWidth(text: []const u8, scale: f32) f32 {
    return @as(f32, @floatFromInt(text.len)) * 6.0 * scale;
}

fn drawOverlayGlyph(renderer: *zsdl3.Renderer, x: f32, y: f32, scale: f32, ch: u8) !void {
    const rows = overlayGlyphRows(ch);
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

fn drawOverlayText(renderer: *zsdl3.Renderer, x: f32, y: f32, scale: f32, color: zsdl3.Color, text: []const u8) !void {
    try zsdl3.setRenderDrawColor(renderer, color);
    var cursor = x;
    for (text) |ch| {
        try drawOverlayGlyph(renderer, cursor, y, scale, ch);
        cursor += 6.0 * scale;
    }
}

fn renderOverlayPanel(
    renderer: *zsdl3.Renderer,
    rect: zsdl3.FRect,
    fill: zsdl3.Color,
    border: zsdl3.Color,
    shadow: zsdl3.Color,
) !void {
    try zsdl3.setRenderDrawColor(renderer, shadow);
    try zsdl3.renderFillRect(renderer, .{
        .x = rect.x + 6.0,
        .y = rect.y + 6.0,
        .w = rect.w,
        .h = rect.h,
    });
    try zsdl3.setRenderDrawColor(renderer, fill);
    try zsdl3.renderFillRect(renderer, rect);
    try zsdl3.setRenderDrawColor(renderer, border);
    try zsdl3.renderRect(renderer, rect);
    try zsdl3.renderRect(renderer, .{
        .x = rect.x + 3.0,
        .y = rect.y + 3.0,
        .w = rect.w - 6.0,
        .h = rect.h - 6.0,
    });
}

fn renderPauseOverlay(renderer: *zsdl3.Renderer, viewport: zsdl3.Rect) !void {
    const title = "PAUSED";
    const lines = [_][]const u8{
        "F2 RESUME",
        "F3 OPEN ROM",
        "F1 HELP",
    };
    const scale = overlayScale(viewport);
    const padding = 10.0 * scale;
    const line_height = 9.0 * scale;

    var max_width = overlayTextWidth(title, scale);
    for (lines) |line| {
        max_width = @max(max_width, overlayTextWidth(line, scale));
    }

    const panel = zsdl3.FRect{
        .x = (@as(f32, @floatFromInt(viewport.w)) - (max_width + padding * 2.0)) * 0.5,
        .y = (@as(f32, @floatFromInt(viewport.h)) - (padding * 2.0 + 7.0 * scale + 4.0 * scale + line_height * @as(f32, @floatFromInt(lines.len)))) * 0.5,
        .w = max_width + padding * 2.0,
        .h = padding * 2.0 + 7.0 * scale + 4.0 * scale + line_height * @as(f32, @floatFromInt(lines.len)),
    };

    try renderOverlayPanel(
        renderer,
        panel,
        .{ .r = 0x10, .g = 0x13, .b = 0x1A, .a = 0xD8 },
        .{ .r = 0xF2, .g = 0xD0, .b = 0x5B, .a = 0xFF },
        .{ .r = 0x00, .g = 0x00, .b = 0x00, .a = 0x80 },
    );

    try drawOverlayText(
        renderer,
        panel.x + (panel.w - overlayTextWidth(title, scale)) * 0.5,
        panel.y + padding,
        scale,
        .{ .r = 0xF2, .g = 0xD0, .b = 0x5B, .a = 0xFF },
        title,
    );

    var y = panel.y + padding + 11.0 * scale;
    for (lines) |line| {
        try drawOverlayText(
            renderer,
            panel.x + (panel.w - overlayTextWidth(line, scale)) * 0.5,
            y,
            scale,
            .{ .r = 0xF4, .g = 0xF7, .b = 0xFB, .a = 0xFF },
            line,
        );
        y += line_height;
    }
}

fn renderHelpOverlay(renderer: *zsdl3.Renderer, viewport: zsdl3.Rect) !void {
    const title = "SANDOPOLIS HELP";
    const lines = [_][]const u8{
        "F1 CLOSE HELP",
        "F2 PAUSE OR RESUME",
        "F3 OPEN ROM DIALOG",
        "",
        "SPACE STEP CPU",
        "BACKSPACE REGISTER DUMP",
        "R START OR STOP GIF",
        "F11 TOGGLE FULLSCREEN",
        "ESC QUIT",
        "",
        "HELP AND PAUSE FREEZE EMULATION",
    };
    const scale = overlayScale(viewport);
    const padding = 10.0 * scale;
    const line_height = 9.0 * scale;

    var max_width = overlayTextWidth(title, scale);
    for (lines) |line| {
        max_width = @max(max_width, overlayTextWidth(line, scale));
    }

    const panel = zsdl3.FRect{
        .x = (@as(f32, @floatFromInt(viewport.w)) - (max_width + padding * 2.0)) * 0.5,
        .y = (@as(f32, @floatFromInt(viewport.h)) - (padding * 2.0 + 7.0 * scale + 5.0 * scale + line_height * @as(f32, @floatFromInt(lines.len)))) * 0.5,
        .w = max_width + padding * 2.0,
        .h = padding * 2.0 + 7.0 * scale + 5.0 * scale + line_height * @as(f32, @floatFromInt(lines.len)),
    };

    try renderOverlayPanel(
        renderer,
        panel,
        .{ .r = 0x0C, .g = 0x10, .b = 0x16, .a = 0xE4 },
        .{ .r = 0x79, .g = 0xD2, .b = 0xB2, .a = 0xFF },
        .{ .r = 0x00, .g = 0x00, .b = 0x00, .a = 0x88 },
    );

    try drawOverlayText(
        renderer,
        panel.x + (panel.w - overlayTextWidth(title, scale)) * 0.5,
        panel.y + padding,
        scale,
        .{ .r = 0x79, .g = 0xD2, .b = 0xB2, .a = 0xFF },
        title,
    );

    var y = panel.y + padding + 12.0 * scale;
    for (lines) |line| {
        const color: zsdl3.Color = if (line.len == 0)
            .{ .r = 0, .g = 0, .b = 0, .a = 0 }
        else if (std.mem.startsWith(u8, line, "F1") or std.mem.startsWith(u8, line, "F2") or std.mem.startsWith(u8, line, "F3"))
            .{ .r = 0xF2, .g = 0xD0, .b = 0x5B, .a = 0xFF }
        else if (std.mem.startsWith(u8, line, "HELP"))
            .{ .r = 0xC7, .g = 0xD2, .b = 0xE0, .a = 0xFF }
        else
            .{ .r = 0xF4, .g = 0xF7, .b = 0xFB, .a = 0xFF };

        if (line.len != 0) {
            try drawOverlayText(
                renderer,
                panel.x + (panel.w - overlayTextWidth(line, scale)) * 0.5,
                y,
                scale,
                color,
                line,
            );
        }
        y += line_height;
    }
}

fn renderDialogOverlay(renderer: *zsdl3.Renderer, viewport: zsdl3.Rect) !void {
    const title = "OPEN ROM";
    const lines = [_][]const u8{
        "SYSTEM FILE DIALOG ACTIVE",
        "",
        "SELECT A ROM OR CANCEL",
    };
    const scale = overlayScale(viewport);
    const padding = 10.0 * scale;
    const line_height = 9.0 * scale;

    var max_width = overlayTextWidth(title, scale);
    for (lines) |line| {
        max_width = @max(max_width, overlayTextWidth(line, scale));
    }

    const panel = zsdl3.FRect{
        .x = (@as(f32, @floatFromInt(viewport.w)) - (max_width + padding * 2.0)) * 0.5,
        .y = (@as(f32, @floatFromInt(viewport.h)) - (padding * 2.0 + 7.0 * scale + 4.0 * scale + line_height * @as(f32, @floatFromInt(lines.len)))) * 0.5,
        .w = max_width + padding * 2.0,
        .h = padding * 2.0 + 7.0 * scale + 4.0 * scale + line_height * @as(f32, @floatFromInt(lines.len)),
    };

    try renderOverlayPanel(
        renderer,
        panel,
        .{ .r = 0x10, .g = 0x13, .b = 0x1A, .a = 0xE4 },
        .{ .r = 0xE6, .g = 0x7E, .b = 0x22, .a = 0xFF },
        .{ .r = 0x00, .g = 0x00, .b = 0x00, .a = 0x88 },
    );

    try drawOverlayText(
        renderer,
        panel.x + (panel.w - overlayTextWidth(title, scale)) * 0.5,
        panel.y + padding,
        scale,
        .{ .r = 0xE6, .g = 0x7E, .b = 0x22, .a = 0xFF },
        title,
    );

    var y = panel.y + padding + 11.0 * scale;
    for (lines) |line| {
        if (line.len != 0) {
            try drawOverlayText(
                renderer,
                panel.x + (panel.w - overlayTextWidth(line, scale)) * 0.5,
                y,
                scale,
                .{ .r = 0xF4, .g = 0xF7, .b = 0xFB, .a = 0xFF },
                line,
            );
        }
        y += line_height;
    }
}

fn renderFrontendOverlay(renderer: *zsdl3.Renderer, ui: *const FrontendUi) !void {
    if (!ui.paused and !ui.show_help and !ui.dialog_active) return;

    const viewport = try zsdl3.getRenderViewport(renderer);
    try zsdl3.setRenderDrawBlendMode(renderer, .blend);
    if (ui.dialog_active) {
        try renderDialogOverlay(renderer, viewport);
    } else if (ui.show_help) {
        try renderHelpOverlay(renderer, viewport);
    } else {
        try renderPauseOverlay(renderer, viewport);
    }
}

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const cli = parseCliArgs(args) catch |err| {
        printUsage();
        std.debug.print("Argument error: {s}\n", .{cliErrorMessage(err)});
        return err;
    };
    if (cli.show_help) {
        printUsage();
        return;
    }
    const rom_path = cli.rom_path;

    std.debug.print("=== Sandopolis Emulator Started ===\n", .{});

    try zsdl3.init(.{ .audio = true, .video = true, .joystick = true, .gamepad = true });
    defer zsdl3.quit();

    const window = try zsdl3.Window.create(
        "Sandopolis Emulator (v" ++ build_options.version ++ ")",
        800,
        600,
        .{ .opengl = true, .resizable = true },
    );
    defer window.destroy();

    const renderer = try zsdl3.Renderer.create(window, null);
    defer renderer.destroy();

    var audio_userdata: u8 = 0;
    var audio: ?AudioInit = tryInitAudio(&audio_userdata);
    if (audio == null) {
        std.debug.print("Audio disabled: no compatible stream format\n", .{});
    } else {
        audio.?.output.setRenderMode(cli.audio_mode);
    }
    if (cli.audio_mode != .normal) {
        std.debug.print("Audio render mode: {s}\n", .{audioRenderModeName(cli.audio_mode)});
    }
    defer if (audio) |a| SDL_DestroyAudioStream(a.stream);

    var gamepads = [_]?GamepadSlot{null} ** InputBindings.player_count;
    var gamepad_sticks = [_]DirectionState{.{}} ** InputBindings.player_count;
    var gamepad_triggers = [_]TriggerState{.{}} ** InputBindings.player_count;
    var joysticks = [_]?JoystickSlot{null} ** InputBindings.player_count;
    var joystick_axes = [_]DirectionState{.{}} ** InputBindings.player_count;
    var joystick_hats = [_]DirectionState{.{}} ** InputBindings.player_count;
    defer {
        for (gamepads) |slot| {
            if (slot) |assigned| assigned.handle.close();
        }
        for (joysticks) |slot| {
            if (slot) |assigned| SDL_CloseJoystick(assigned.handle);
        }
    }
    var count: c_int = 0;
    if (SDL_GetGamepads(&count)) |gamepads_ptr| {
        defer zsdl3.free(gamepads_ptr);
        const gamepad_count: usize = @intCast(@max(count, 0));
        for (0..@min(gamepad_count, InputBindings.player_count)) |i| {
            assignGamepadSlot(&gamepads, &joysticks, &gamepad_sticks, &gamepad_triggers, gamepads_ptr[i]);
        }
    }
    if (SDL_GetJoysticks(&count)) |joysticks_ptr| {
        defer zsdl3.free(joysticks_ptr);
        const joystick_count: usize = @intCast(@max(count, 0));
        for (0..joystick_count) |i| {
            assignJoystickSlot(&gamepads, &joysticks, &joystick_axes, &joystick_hats, joysticks_ptr[i]);
        }
    }

    const vdp_texture = try zsdl3.createTexture(renderer, zsdl3.PixelFormatEnum.argb8888, zsdl3.TextureAccess.streaming, 320, 224);
    defer vdp_texture.destroy();

    if (rom_path) |_| {
        std.debug.print("Loading ROM: {s}\n", .{rom_path.?});
    } else {
        std.debug.print("No ROM file specified. Usage: sandopolis [options] [rom_file]\n", .{});
        std.debug.print("Loading dummy test ROM...\n", .{});
    }

    const input_config_path = try InputBindings.defaultConfigPath(allocator);
    defer if (input_config_path) |path| allocator.free(path);

    var input_bindings = InputBindings.Bindings.defaults();
    if (input_config_path) |path| {
        input_bindings = try InputBindings.Bindings.loadFromFile(allocator, path);
        std.debug.print("Loaded input config: {s}\n", .{path});
    }

    var machine = try Machine.init(allocator, rom_path);
    defer {
        machine.flushPersistentStorage() catch |err| {
            std.debug.print("Failed to flush persistent SRAM: {s}\n", .{@errorName(err)});
        };
        machine.deinit(allocator);
    }
    const bus = &machine.bus;
    input_bindings.applyControllerTypes(&bus.io);

    const cpu = &machine.cpu;

    if (rom_path == null) {
        std.mem.writeInt(u32, bus.rom[0..4], 0x00FF0000, .big);
        std.mem.writeInt(u32, bus.rom[4..8], 0x00000200, .big);

        var pc: u32 = 0x200;

        bus.rom[pc] = 0x33;
        bus.rom[pc + 1] = 0xFC;
        pc += 2;
        bus.rom[pc] = 0x82;
        bus.rom[pc + 1] = 0x38;
        pc += 2;
        bus.rom[pc] = 0x00;
        bus.rom[pc + 1] = 0xC0;
        pc += 2;
        bus.rom[pc] = 0x00;
        bus.rom[pc + 1] = 0x04;
        pc += 2;

        bus.rom[pc] = 0x33;
        bus.rom[pc + 1] = 0xFC;
        pc += 2;
        bus.rom[pc] = 0x8F;
        bus.rom[pc + 1] = 0x02;
        pc += 2;
        bus.rom[pc] = 0x00;
        bus.rom[pc + 1] = 0xC0;
        pc += 2;
        bus.rom[pc] = 0x00;
        bus.rom[pc + 1] = 0x04;
        pc += 2;

        bus.rom[pc] = 0x33;
        bus.rom[pc + 1] = 0xFC;
        pc += 2;
        bus.rom[pc] = 0xC0;
        bus.rom[pc + 1] = 0x00;
        pc += 2;
        bus.rom[pc] = 0x00;
        bus.rom[pc + 1] = 0xC0;
        pc += 2;
        bus.rom[pc] = 0x00;
        bus.rom[pc + 1] = 0x04;
        pc += 2;

        bus.rom[pc] = 0x33;
        bus.rom[pc + 1] = 0xFC;
        pc += 2;
        bus.rom[pc] = 0x00;
        bus.rom[pc + 1] = 0x00;
        pc += 2;
        bus.rom[pc] = 0x00;
        bus.rom[pc + 1] = 0xC0;
        pc += 2;
        bus.rom[pc] = 0x00;
        bus.rom[pc + 1] = 0x04;
        pc += 2;

        bus.rom[pc] = 0x33;
        bus.rom[pc + 1] = 0xFC;
        pc += 2;
        bus.rom[pc] = 0x00;
        bus.rom[pc + 1] = 0x0E;
        pc += 2;
        bus.rom[pc] = 0x00;
        bus.rom[pc + 1] = 0xC0;
        pc += 2;
        bus.rom[pc] = 0x00;
        bus.rom[pc + 1] = 0x00;
        pc += 2;

        bus.rom[pc] = 0x33;
        bus.rom[pc + 1] = 0xFC;
        pc += 2;
        bus.rom[pc] = 0x00;
        bus.rom[pc + 1] = 0xE0;
        pc += 2;
        bus.rom[pc] = 0x00;
        bus.rom[pc + 1] = 0xC0;
        pc += 2;
        bus.rom[pc] = 0x00;
        bus.rom[pc + 1] = 0x00;
        pc += 2;

        bus.rom[pc] = 0x33;
        bus.rom[pc + 1] = 0xFC;
        pc += 2;
        bus.rom[pc] = 0x00;
        bus.rom[pc + 1] = 0x40;
        pc += 2;
        bus.rom[pc] = 0x00;
        bus.rom[pc + 1] = 0xA1;
        pc += 2;
        bus.rom[pc] = 0x00;
        bus.rom[pc + 1] = 0x02;
        pc += 2;

        const loop_start = pc;

        bus.rom[pc] = 0x10;
        bus.rom[pc + 1] = 0x39;
        pc += 2;
        bus.rom[pc] = 0x00;
        bus.rom[pc + 1] = 0xA1;
        pc += 2;
        bus.rom[pc] = 0x00;
        bus.rom[pc + 1] = 0x03;
        pc += 2;

        bus.rom[pc] = 0x02;
        bus.rom[pc + 1] = 0x00;
        pc += 2;
        bus.rom[pc] = 0x00;
        bus.rom[pc + 1] = 0x10;
        pc += 2;

        const branch_loc = pc;
        pc += 2;

        bus.rom[pc] = 0x33;
        bus.rom[pc + 1] = 0xFC;
        pc += 2;
        bus.rom[pc] = 0xC0;
        bus.rom[pc + 1] = 0x00;
        pc += 2;
        bus.rom[pc] = 0x00;
        bus.rom[pc + 1] = 0xC0;
        pc += 2;
        bus.rom[pc] = 0x00;
        bus.rom[pc + 1] = 0x04;
        pc += 2;
        bus.rom[pc] = 0x33;
        bus.rom[pc + 1] = 0xFC;
        pc += 2;
        bus.rom[pc] = 0x00;
        bus.rom[pc + 1] = 0x00;
        pc += 2;
        bus.rom[pc] = 0x00;
        bus.rom[pc + 1] = 0xC0;
        pc += 2;
        bus.rom[pc] = 0x00;
        bus.rom[pc + 1] = 0x04;
        pc += 2;

        bus.rom[pc] = 0x33;
        bus.rom[pc + 1] = 0xFC;
        pc += 2;
        bus.rom[pc] = 0x00;
        bus.rom[pc + 1] = 0x0E;
        pc += 2;
        bus.rom[pc] = 0x00;
        bus.rom[pc + 1] = 0xC0;
        pc += 2;
        bus.rom[pc] = 0x00;
        bus.rom[pc + 1] = 0x00;
        pc += 2;

        const back_jump = @as(i32, @intCast(loop_start)) - @as(i32, @intCast(pc + 2));
        bus.rom[pc] = 0x60;
        bus.rom[pc + 1] = @as(u8, @intCast(back_jump & 0xFF));
        pc += 2;

        const pressed_target = pc;

        const fwd_jump = @as(i32, @intCast(pressed_target)) - @as(i32, @intCast(branch_loc + 2));
        bus.rom[branch_loc] = 0x67;
        bus.rom[branch_loc + 1] = @as(u8, @intCast(fwd_jump & 0xFF));

        bus.rom[pc] = 0x33;
        bus.rom[pc + 1] = 0xFC;
        pc += 2;
        bus.rom[pc] = 0xC0;
        bus.rom[pc + 1] = 0x00;
        pc += 2;
        bus.rom[pc] = 0x00;
        bus.rom[pc + 1] = 0xC0;
        pc += 2;
        bus.rom[pc] = 0x00;
        bus.rom[pc + 1] = 0x04;
        pc += 2;
        bus.rom[pc] = 0x33;
        bus.rom[pc + 1] = 0xFC;
        pc += 2;
        bus.rom[pc] = 0x00;
        bus.rom[pc + 1] = 0x00;
        pc += 2;
        bus.rom[pc] = 0x00;
        bus.rom[pc + 1] = 0xC0;
        pc += 2;
        bus.rom[pc] = 0x00;
        bus.rom[pc + 1] = 0x04;
        pc += 2;

        bus.rom[pc] = 0x33;
        bus.rom[pc + 1] = 0xFC;
        pc += 2;
        bus.rom[pc] = 0x00;
        bus.rom[pc + 1] = 0xE0;
        pc += 2;
        bus.rom[pc] = 0x00;
        bus.rom[pc + 1] = 0xC0;
        pc += 2;
        bus.rom[pc] = 0x00;
        bus.rom[pc + 1] = 0x00;
        pc += 2;

        const back_jump2 = @as(i32, @intCast(loop_start)) - @as(i32, @intCast(pc + 2));
        bus.rom[pc] = 0x60;
        bus.rom[pc + 1] = @as(u8, @intCast(back_jump2 & 0xFF));
        pc += 2;

        bus.rom[pc] = 0x60;
        bus.rom[pc + 1] = 0xFE;
        pc += 2;
    } else {
        if (bus.rom.len >= 0x200) {
            const console = bus.rom[0x100..0x110];
            const title = bus.rom[0x150..0x180];
            std.debug.print("Console: {s}\n", .{console});
            std.debug.print("Title:   {s}\n", .{title});
        }
        const ssp = bus.read32(0x000000);
        const pc = bus.read32(0x000004);
        std.debug.print("Reset Vectors: SSP={X:0>8} PC={X:0>8}\n", .{ ssp, pc });
    }

    machine.reset();
    std.debug.print("CPU Reset complete.\n", .{});
    machine.debugDump();
    var frame_counter: u32 = 0;
    const uncapped_boot_frames: u32 = uncappedBootFrames(audio != null);
    var gif_recorder: ?GifRecorder = null;
    var frontend_ui = FrontendUi{};
    var file_dialog_state = FileDialogState{};

    var frame_timer = std.time.Instant.now() catch unreachable;
    mainLoop: while (true) {
        frame_timer = std.time.Instant.now() catch frame_timer;
        var event: zsdl3.Event = undefined;
        while (zsdl3.pollEvent(&event)) {
            switch (event.type) {
                zsdl3.EventType.quit => break :mainLoop,
                zsdl3.EventType.gamepad_added => assignGamepadSlot(&gamepads, &joysticks, &gamepad_sticks, &gamepad_triggers, event.gdevice.which),
                zsdl3.EventType.gamepad_removed => removeGamepadSlot(&gamepads, &gamepad_sticks, &gamepad_triggers, &input_bindings, &bus.io, event.gdevice.which),
                zsdl3.EventType.joystick_added => assignJoystickSlot(&gamepads, &joysticks, &joystick_axes, &joystick_hats, event.jdevice.which),
                zsdl3.EventType.joystick_removed => removeJoystickSlot(&joysticks, &joystick_axes, &joystick_hats, &input_bindings, &bus.io, event.jdevice.which),
                zsdl3.EventType.gamepad_button_down, zsdl3.EventType.gamepad_button_up => {
                    const pressed = (event.type == zsdl3.EventType.gamepad_button_down);
                    const button = event.gbutton.button;
                    const port = findGamepadPort(&gamepads, event.gbutton.which) orelse continue;
                    if (gamepadInputFromButton(button)) |mapped_button| {
                        _ = input_bindings.applyGamepad(&bus.io, port, mapped_button, pressed);
                    }
                },
                zsdl3.EventType.gamepad_axis_motion => {
                    const port = findGamepadPort(&gamepads, event.gaxis.which) orelse continue;
                    const axis: zsdl3.Gamepad.Axis = @enumFromInt(event.gaxis.axis);
                    applyInputTransitions(
                        &input_bindings,
                        &bus.io,
                        port,
                        updateGamepadAxisState(
                            &gamepad_sticks[port],
                            &gamepad_triggers[port],
                            axis,
                            event.gaxis.value,
                            input_bindings.gamepad_axis_threshold,
                            input_bindings.trigger_threshold,
                        ),
                    );
                },
                zsdl3.EventType.joystick_button_down, zsdl3.EventType.joystick_button_up => {
                    const pressed = (event.type == zsdl3.EventType.joystick_button_down);
                    const port = findJoystickPort(&joysticks, event.jbutton.which) orelse continue;
                    if (joystickInputFromButton(event.jbutton.button)) |mapped_button| {
                        _ = input_bindings.applyGamepad(&bus.io, port, mapped_button, pressed);
                    }
                },
                zsdl3.EventType.joystick_axis_motion => {
                    const port = findJoystickPort(&joysticks, event.jaxis.which) orelse continue;
                    applyInputTransitions(
                        &input_bindings,
                        &bus.io,
                        port,
                        updateJoystickAxisState(
                            &joystick_axes[port],
                            event.jaxis.axis,
                            event.jaxis.value,
                            input_bindings.joystick_axis_threshold,
                        ),
                    );
                },
                zsdl3.EventType.joystick_hat_motion => {
                    if (event.jhat.hat != 0) continue;
                    const port = findJoystickPort(&joysticks, event.jhat.which) orelse continue;
                    applyInputTransitions(
                        &input_bindings,
                        &bus.io,
                        port,
                        updateHatState(&joystick_hats[port], event.jhat.value),
                    );
                },
                zsdl3.EventType.key_down, zsdl3.EventType.key_up => {
                    const pressed = (event.type == zsdl3.EventType.key_down);
                    const scancode = event.key.scancode;
                    if (frontendShortcutForKey(scancode, pressed)) |shortcut| {
                        _ = applyFrontendShortcut(&frontend_ui, scancode, pressed);
                        if (shortcut == .open_rom) {
                            _ = launchOpenRomDialog(&file_dialog_state, &frontend_ui, window);
                        }
                        continue;
                    }
                    if (keyboardInputFromScancode(scancode)) |mapped_key| {
                        _ = input_bindings.applyKeyboard(&bus.io, mapped_key, pressed);

                        if (pressed) {
                            switch (input_bindings.hotkeyForKeyboard(mapped_key) orelse continue) {
                                .step => {
                                    if (frontend_ui.show_help) continue;
                                    machine.runMasterSlice(clock.m68k_divider);
                                    machine.debugDump();
                                },
                                .registers => {
                                    if (frontend_ui.show_help) continue;
                                    machine.debugDump();
                                },
                                .record_gif => {
                                    if (frontend_ui.show_help) continue;
                                    if (gif_recorder) |*rec| {
                                        const frames = rec.frame_count;
                                        rec.finish();
                                        gif_recorder = null;
                                        std.debug.print("GIF recording stopped ({d} frames)\n", .{frames});
                                    } else {
                                        const fps: u16 = if (bus.vdp.pal_mode) 25 else 30;
                                        const path = gifOutputPath();
                                        const path_str = std.mem.sliceTo(&path, 0);
                                        gif_recorder = GifRecorder.start(path_str, fps) catch |err| {
                                            std.debug.print("Failed to start GIF recording: {}\n", .{err});
                                            continue;
                                        };
                                        std.debug.print("GIF recording started: {s}\n", .{path_str});
                                    }
                                },
                                .toggle_fullscreen => {
                                    const flags = SDL_GetWindowFlags(window);
                                    _ = SDL_SetWindowFullscreen(window, flags & 1 == 0);
                                },
                                .quit => break :mainLoop,
                            }
                        }
                    }
                },
                else => {},
            }
        }

        switch (file_dialog_state.take()) {
            .none => {},
            .canceled => frontend_ui.dialog_active = false,
            .failed => |message| {
                frontend_ui.dialog_active = false;
                std.debug.print("Open ROM dialog failed: {s}\n", .{message.slice()});
            },
            .selected => |path| {
                frontend_ui.dialog_active = false;
                frontend_ui.show_help = false;
                loadRomIntoMachine(
                    allocator,
                    &machine,
                    &input_bindings,
                    if (audio) |*a| a else null,
                    &gif_recorder,
                    &frame_counter,
                    path.slice(),
                ) catch |err| {
                    std.debug.print("Failed to load ROM {s}: {}\n", .{ path.slice(), err });
                };
            },
        }

        const emulation_paused = frontend_ui.emulationPaused();
        if (!emulation_paused) {
            const visible_lines: u16 = if (bus.vdp.pal_mode) clock.pal_visible_lines else clock.ntsc_visible_lines;
            const total_lines: u16 = if (bus.vdp.pal_mode) clock.pal_lines_per_frame else clock.ntsc_lines_per_frame;
            bus.vdp.beginFrame();
            for (0..total_lines) |line_idx| {
                const line: u16 = @intCast(line_idx);
                const entering_vblank = bus.vdp.setScanlineState(line, visible_lines, total_lines);
                if (entering_vblank and bus.vdp.isVBlankInterruptEnabled()) {
                    cpu.requestInterrupt(6);
                }
                if (entering_vblank) {
                    bus.z80.assertIrq(0xFF);
                } else if (!bus.vdp.vint_pending) {
                    bus.z80.clearIrq();
                }
                bus.vdp.setHBlank(false);

                const hint_master_cycles = bus.vdp.hInterruptMasterCycles();
                const hblank_start_master_cycles = bus.vdp.hblankStartMasterCycles();
                const first_event_master_cycles = @min(hint_master_cycles, hblank_start_master_cycles);
                const second_event_master_cycles = @max(hint_master_cycles, hblank_start_master_cycles);

                machine.runMasterSlice(first_event_master_cycles);

                if (hblank_start_master_cycles == first_event_master_cycles) {
                    bus.vdp.setHBlank(true);
                }
                if (hint_master_cycles == first_event_master_cycles and bus.vdp.consumeHintForLine(line, visible_lines)) {
                    cpu.requestInterrupt(4);
                }

                machine.runMasterSlice(second_event_master_cycles - first_event_master_cycles);

                if (hblank_start_master_cycles == second_event_master_cycles and hblank_start_master_cycles != first_event_master_cycles) {
                    bus.vdp.setHBlank(true);
                }
                if (hint_master_cycles == second_event_master_cycles and hint_master_cycles != first_event_master_cycles and bus.vdp.consumeHintForLine(line, visible_lines)) {
                    cpu.requestInterrupt(4);
                }

                machine.runMasterSlice(clock.ntsc_master_cycles_per_line - second_event_master_cycles);
                bus.vdp.setHBlank(false);

                if (line < visible_lines) {
                    bus.vdp.renderScanline(line);
                }
            }
            bus.vdp.odd_frame = !bus.vdp.odd_frame;
        }

        if (!emulation_paused) {
            if (gif_recorder) |*rec| {
                if (frame_counter % 2 == 0) {
                    rec.addFrame(&bus.vdp.framebuffer) catch |err| {
                        std.debug.print("GIF frame capture failed: {}\n", .{err});
                        const frames = rec.frame_count;
                        rec.finish();
                        gif_recorder = null;
                        std.debug.print("GIF recording aborted after {d} frames\n", .{frames});
                    };
                }
            }
        }

        if (!emulation_paused and (frame_counter % 300) == 0) {
            std.debug.print("f={d} pc={X:0>8}\n", .{ frame_counter, cpu.core.pc });
        }
        if (audio) |*a| {
            const audio_frames = bus.audio_timing.takePending();
            if (a.output.canAcceptPending()) {
                try a.output.pushPending(audio_frames, &bus.z80, bus.vdp.pal_mode);
            } else {
                try a.output.discardPending(audio_frames, &bus.z80, bus.vdp.pal_mode);
            }
        } else {
            _ = bus.audio_timing.takePending();
        }

        _ = SDL_UpdateTexture(vdp_texture, null, @ptrCast(&bus.vdp.framebuffer), 320 * 4);

        try zsdl3.setRenderDrawColor(renderer, .{ .r = 0x20, .g = 0x20, .b = 0x20, .a = 0xFF });
        try zsdl3.renderClear(renderer);
        try zsdl3.renderTexture(renderer, vdp_texture, null, null);
        try renderFrontendOverlay(renderer, &frontend_ui);
        zsdl3.renderPresent(renderer);

        frame_counter += 1;
        if (frame_counter > uncapped_boot_frames) {
            const target_frame_ns = frameDurationNs(bus.vdp.pal_mode);
            const now = std.time.Instant.now() catch frame_timer;
            const frame_elapsed = now.since(frame_timer);
            if (frame_elapsed < target_frame_ns) {
                std.Thread.sleep(target_frame_ns - frame_elapsed);
            }
        }
    }

    if (gif_recorder) |*rec| {
        std.debug.print("GIF recording stopped on exit ({d} frames)\n", .{rec.frame_count});
        rec.finish();
    }
}

test "left stick transitions mirror dpad directions across threshold crossings" {
    var state = DirectionState{};

    var transitions = updateLeftStickState(&state, .leftx, -20_000, 16_000);
    try std.testing.expectEqual(InputBindings.GamepadInput.dpad_left, transitions[0].?.input);
    try std.testing.expect(transitions[0].?.pressed);
    try std.testing.expect(transitions[1] == null);

    transitions = updateLeftStickState(&state, .leftx, 0, 16_000);
    try std.testing.expectEqual(InputBindings.GamepadInput.dpad_left, transitions[0].?.input);
    try std.testing.expect(!transitions[0].?.pressed);
    try std.testing.expect(transitions[1] == null);

    transitions = updateLeftStickState(&state, .lefty, 20_000, 16_000);
    try std.testing.expectEqual(InputBindings.GamepadInput.dpad_down, transitions[0].?.input);
    try std.testing.expect(transitions[0].?.pressed);
}

test "gamepad trigger transitions mirror threshold crossings" {
    var state = false;

    var transitions = updateTriggerState(&state, 20_000, 16_000, .left_trigger);
    try std.testing.expectEqual(InputBindings.GamepadInput.left_trigger, transitions[0].?.input);
    try std.testing.expect(transitions[0].?.pressed);
    try std.testing.expect(transitions[1] == null);

    transitions = updateTriggerState(&state, 0, 16_000, .left_trigger);
    try std.testing.expectEqual(InputBindings.GamepadInput.left_trigger, transitions[0].?.input);
    try std.testing.expect(!transitions[0].?.pressed);
    try std.testing.expect(transitions[1] == null);
}

test "axis helpers honor custom thresholds" {
    var stick_state = DirectionState{};
    var trigger_state = TriggerState{};

    var transitions = updateLeftStickState(&stick_state, .leftx, 14_000, 15_000);
    try std.testing.expect(transitions[0] == null);

    transitions = updateLeftStickState(&stick_state, .leftx, 16_000, 15_000);
    try std.testing.expectEqual(InputBindings.GamepadInput.dpad_right, transitions[0].?.input);
    try std.testing.expect(transitions[0].?.pressed);

    transitions = updateTriggerState(&trigger_state.left, 14_000, 15_000, .left_trigger);
    try std.testing.expect(transitions[0] == null);

    transitions = updateGamepadAxisState(&stick_state, &trigger_state, .left_trigger, 16_000, 15_000, 15_000);
    try std.testing.expectEqual(InputBindings.GamepadInput.left_trigger, transitions[0].?.input);
    try std.testing.expect(transitions[0].?.pressed);
}

test "gamepad button mapping includes guide and stick clicks" {
    try std.testing.expectEqual(InputBindings.GamepadInput.guide, gamepadInputFromButton(@intFromEnum(zsdl3.Gamepad.Button.guide)).?);
    try std.testing.expectEqual(InputBindings.GamepadInput.left_stick, gamepadInputFromButton(@intFromEnum(zsdl3.Gamepad.Button.left_stick)).?);
    try std.testing.expectEqual(InputBindings.GamepadInput.right_stick, gamepadInputFromButton(@intFromEnum(zsdl3.Gamepad.Button.right_stick)).?);
    try std.testing.expectEqual(InputBindings.GamepadInput.misc1, gamepadInputFromButton(@intFromEnum(zsdl3.Gamepad.Button.misc1)).?);
}

test "joystick hat transitions mirror dpad directions and diagonals" {
    var state = DirectionState{};

    var transitions = updateHatState(&state, joystick_hat_up | joystick_hat_left);
    try std.testing.expectEqual(InputBindings.GamepadInput.dpad_up, transitions[0].?.input);
    try std.testing.expect(transitions[0].?.pressed);
    try std.testing.expectEqual(InputBindings.GamepadInput.dpad_left, transitions[1].?.input);
    try std.testing.expect(transitions[1].?.pressed);
    try std.testing.expect(transitions[2] == null);

    transitions = updateHatState(&state, joystick_hat_right);
    try std.testing.expectEqual(InputBindings.GamepadInput.dpad_up, transitions[0].?.input);
    try std.testing.expect(!transitions[0].?.pressed);
    try std.testing.expectEqual(InputBindings.GamepadInput.dpad_left, transitions[1].?.input);
    try std.testing.expect(!transitions[1].?.pressed);
    try std.testing.expectEqual(InputBindings.GamepadInput.dpad_right, transitions[2].?.input);
    try std.testing.expect(transitions[2].?.pressed);
    try std.testing.expect(transitions[3] == null);
}

test "joystick axis transitions mirror the first stick axes" {
    var state = DirectionState{};

    var transitions = updateJoystickAxisState(&state, 0, 20_000, 16_000);
    try std.testing.expectEqual(InputBindings.GamepadInput.dpad_right, transitions[0].?.input);
    try std.testing.expect(transitions[0].?.pressed);
    try std.testing.expect(transitions[1] == null);

    transitions = updateJoystickAxisState(&state, 1, -20_000, 16_000);
    try std.testing.expectEqual(InputBindings.GamepadInput.dpad_up, transitions[0].?.input);
    try std.testing.expect(transitions[0].?.pressed);
}

test "joystick button fallback maps conventional start and face buttons" {
    try std.testing.expectEqual(InputBindings.GamepadInput.south, joystickInputFromButton(0).?);
    try std.testing.expectEqual(InputBindings.GamepadInput.right_shoulder, joystickInputFromButton(5).?);
    try std.testing.expectEqual(InputBindings.GamepadInput.start, joystickInputFromButton(7).?);
    try std.testing.expect(joystickInputFromButton(8) == null);
}

test "frontend shortcuts toggle help and pause only on key down" {
    var ui = FrontendUi{};

    try std.testing.expect(applyFrontendShortcut(&ui, .f1, true));
    try std.testing.expect(ui.show_help);
    try std.testing.expect(ui.emulationPaused());

    try std.testing.expect(!applyFrontendShortcut(&ui, .f1, false));
    try std.testing.expect(ui.show_help);

    try std.testing.expect(applyFrontendShortcut(&ui, .f2, true));
    try std.testing.expect(ui.paused);

    try std.testing.expect(applyFrontendShortcut(&ui, .f1, true));
    try std.testing.expect(!ui.show_help);
    try std.testing.expect(ui.emulationPaused());

    try std.testing.expect(applyFrontendShortcut(&ui, .f2, true));
    try std.testing.expect(!ui.emulationPaused());
}

test "frontend shortcut helper ignores unrelated keys" {
    var ui = FrontendUi{};
    try std.testing.expect(!applyFrontendShortcut(&ui, .f11, true));
    try std.testing.expect(!ui.emulationPaused());
}

test "frontend shortcut helper exposes open rom key" {
    var ui = FrontendUi{};
    try std.testing.expectEqual(FrontendShortcut.open_rom, frontendShortcutForKey(.f3, true).?);
    try std.testing.expect(applyFrontendShortcut(&ui, .f3, true));
    try std.testing.expect(!ui.emulationPaused());
}

test "file dialog state records selected paths and failures" {
    var dialog = FileDialogState{};
    try std.testing.expect(dialog.begin());
    dialog.finishSelected("roms/test.bin");

    const selected = dialog.take();
    switch (selected) {
        .selected => |path| try std.testing.expectEqualStrings("roms/test.bin", path.slice()),
        else => try std.testing.expect(false),
    }
    switch (dialog.take()) {
        .none => {},
        else => try std.testing.expect(false),
    }

    try std.testing.expect(dialog.begin());
    dialog.finishFailed("FAILED");
    const failed = dialog.take();
    switch (failed) {
        .failed => |message| try std.testing.expectEqualStrings("FAILED", message.slice()),
        else => try std.testing.expect(false),
    }
}

test "file dialog state records cancellations" {
    var dialog = FileDialogState{};
    try std.testing.expect(dialog.begin());
    dialog.finishCanceled();
    switch (dialog.take()) {
        .canceled => {},
        else => try std.testing.expect(false),
    }
    try std.testing.expect(dialog.begin());
}

test "frame duration uses console master clock" {
    try std.testing.expectEqual(@as(u64, 16_688_154), frameDurationNs(false));
    try std.testing.expectEqual(@as(u64, 20_120_133), frameDurationNs(true));
}

test "audio-enabled runs do not use uncapped boot frames" {
    try std.testing.expectEqual(@as(u32, 0), uncappedBootFrames(true));
    try std.testing.expectEqual(@as(u32, 240), uncappedBootFrames(false));
}

test "cli parser accepts audio mode before rom path" {
    const args = [_][]const u8{
        "sandopolis",
        "--audio-mode=psg-only",
        "roms/test.bin",
    };

    const options = try parseCliArgs(&args);
    try std.testing.expectEqualStrings("roms/test.bin", options.rom_path.?);
    try std.testing.expectEqual(AudioOutput.RenderMode.psg_only, options.audio_mode);
    try std.testing.expect(!options.show_help);
}

test "cli parser accepts spaced audio mode after rom path" {
    const args = [_][]const u8{
        "sandopolis",
        "roms/test.bin",
        "--audio-mode",
        "unfiltered-mix",
    };

    const options = try parseCliArgs(&args);
    try std.testing.expectEqualStrings("roms/test.bin", options.rom_path.?);
    try std.testing.expectEqual(AudioOutput.RenderMode.unfiltered_mix, options.audio_mode);
}

test "cli parser handles help without a rom path" {
    const args = [_][]const u8{
        "sandopolis",
        "--help",
    };

    const options = try parseCliArgs(&args);
    try std.testing.expect(options.show_help);
    try std.testing.expect(options.rom_path == null);
    try std.testing.expectEqual(AudioOutput.RenderMode.normal, options.audio_mode);
}

test "cli parser rejects invalid audio mode values" {
    const args = [_][]const u8{
        "sandopolis",
        "--audio-mode",
        "broken",
    };

    try std.testing.expectError(error.InvalidAudioMode, parseCliArgs(&args));
}

fn gifOutputPath() [48]u8 {
    var buf: [48]u8 = [_]u8{0} ** 48;
    var i: u32 = 1;
    while (i <= 999) : (i += 1) {
        const name = std.fmt.bufPrint(&buf, "sandopolis_{d:0>3}.gif", .{i}) catch break;
        buf[name.len] = 0;
        std.fs.cwd().access(name, .{}) catch {
            return buf;
        };
    }

    return buf;
}

extern fn SDL_GetGamepads(count: *c_int) ?[*]zsdl3.Joystick.Id;
extern fn SDL_GetJoysticks(count: *c_int) ?[*]zsdl3.Joystick.Id;
extern fn SDL_IsGamepad(id: zsdl3.Joystick.Id) bool;
extern fn SDL_OpenJoystick(id: zsdl3.Joystick.Id) ?*SdlJoystick;
extern fn SDL_CloseJoystick(joystick: *SdlJoystick) void;
extern fn SDL_OpenAudioDeviceStream(
    device: zsdl3.AudioDeviceId,
    spec: *const SdlAudioSpecRaw,
    callback: ?zsdl3.AudioStreamCallback,
    userdata: *anyopaque,
) ?*zsdl3.AudioStream;
extern fn SDL_ShowOpenFileDialog(
    callback: *const fn (?*anyopaque, [*c]const [*c]const u8, c_int) callconv(.c) void,
    userdata: ?*anyopaque,
    window: ?*zsdl3.Window,
    filters: [*]const SdlDialogFileFilter,
    nfilters: c_int,
    default_location: ?[*:0]const u8,
    allow_many: bool,
) void;
extern fn SDL_DestroyAudioStream(stream: *zsdl3.AudioStream) void;
extern fn SDL_UpdateTexture(texture: *zsdl3.Texture, rect: ?*const zsdl3.Rect, pixels: ?*const anyopaque, pitch: c_int) bool;
extern fn SDL_SetWindowFullscreen(window: *zsdl3.Window, fullscreen: bool) bool;
extern fn SDL_GetWindowFlags(window: *zsdl3.Window) u64;
