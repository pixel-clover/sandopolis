const std = @import("std");
const zsdl3 = @import("zsdl3");
const clock = @import("clock.zig");
const AudioOutput = @import("audio/output.zig").AudioOutput;
const Io = @import("input/io.zig").Io;
const InputBindings = @import("input/mapping.zig");
const Machine = @import("machine.zig").Machine;

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

fn findDefaultRomPath(allocator: std.mem.Allocator) !?[]u8 {
    var dir = std.fs.cwd().openDir("roms", .{ .iterate = true }) catch return null;
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        const name = entry.name;
        if (std.mem.endsWith(u8, name, ".smd") or std.mem.endsWith(u8, name, ".bin") or std.mem.endsWith(u8, name, ".md")) {
            return try std.fmt.allocPrint(allocator, "roms/{s}", .{name});
        }
    }
    return null;
}

pub fn main() !void {
    // -- Emulator Initialization --
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    std.debug.print("=== Sandopolis Emulator Started ===\n", .{});

    try zsdl3.init(.{ .audio = true, .video = true, .joystick = true, .gamepad = true });
    defer zsdl3.quit();

    const window = try zsdl3.Window.create(
        "Sandopolis - Sega Genesis Emulator",
        800,
        600,
        .{ .opengl = true },
    );
    defer window.destroy();

    const renderer = try zsdl3.Renderer.create(window, null);
    defer renderer.destroy();

    var audio_userdata: u8 = 0;
    var audio: ?AudioInit = tryInitAudio(&audio_userdata);
    if (audio == null) {
        std.debug.print("Audio disabled: no compatible stream format\n", .{});
    }
    defer if (audio) |a| SDL_DestroyAudioStream(a.stream);

    // Open up to two gamepads and assign them to players by SDL device ID.
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

    // Create VDP Texture (320x224)
    const vdp_texture = try zsdl3.createTexture(renderer, zsdl3.PixelFormatEnum.argb8888, zsdl3.TextureAccess.streaming, 320, 224);
    defer vdp_texture.destroy();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var rom_path: ?[]const u8 = null;
    var owned_rom_path: ?[]u8 = null;
    defer if (owned_rom_path) |p| allocator.free(p);
    if (args.len > 1) {
        rom_path = args[1];
        std.debug.print("Loading ROM: {s}\n", .{rom_path.?});
    } else {
        owned_rom_path = try findDefaultRomPath(allocator);
        if (owned_rom_path) |path| {
            rom_path = path;
            std.debug.print("No ROM argument provided. Auto-loading: {s}\n", .{path});
        } else {
            std.debug.print("No ROM file specified. Usage: sandopolis <rom_file>\n", .{});
            std.debug.print("Loading dummy test ROM...\n", .{});
        }
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

    // -- Setup Test Environment (Dummy ROM for Tile Rendering) --
    if (rom_path == null) {
        // Vectors
        std.mem.writeInt(u32, bus.rom[0..4], 0x00FF0000, .big); // SSP
        std.mem.writeInt(u32, bus.rom[4..8], 0x00000200, .big); // PC

        // Opcode at 0x200: VDP Tile Test

        // 1. Setup VDP Registers
        var pc: u32 = 0x200;

        // Reg 2 (Plane A) -> 0x38 (0xE000)
        // MOVE.w #0x8238, 0xC00004
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

        // Reg 15 (Auto Inc) -> 2
        // MOVE.w #0x8F02, 0xC00004
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

        // 2. Write Palette (Red / Green)
        // CRAM Write @ 0 (Color 0) -> 0xC0000000
        // MOVE.w #0xC000, 0xC00004
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
        // MOVE.w #0x0000, 0xC00004
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

        // Color 1: Red (0000 000 000 111 -> 0x00E) in Grp 0, Idx 1
        // Auto-inc is 2. So we are at Color 1.
        // MOVE.w #0x000E, 0xC00000 (Data Port)
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

        // Color 2: Green (0000 000 111 000 -> 0x0E0)
        // MOVE.w #0x00E0, 0xC00000
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

        // -- Input Test ROM --
        // 1. Set TH = 1 (Port A)
        // MOVE.w #0x40, 0xA10002 -> Writes 0x40 to 0xA10003
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

        const loop_start = pc; // Mark loop start

        // 2. Read Port A (0xA10003) -> D0 (Byte)
        // MOVE.b 0xA10003, D0
        // Opcode: 1039 00xx ...
        // 0001 0000 0011 1001 -> 1039
        bus.rom[pc] = 0x10;
        bus.rom[pc + 1] = 0x39;
        pc += 2;
        bus.rom[pc] = 0x00;
        bus.rom[pc + 1] = 0xA1;
        pc += 2;
        bus.rom[pc] = 0x00;
        bus.rom[pc + 1] = 0x03;
        pc += 2;

        // 3. Test Button B (Bit 4)
        // ANDI.b #0x10, D0
        bus.rom[pc] = 0x02;
        bus.rom[pc + 1] = 0x00;
        pc += 2;
        bus.rom[pc] = 0x00;
        bus.rom[pc + 1] = 0x10;
        pc += 2;

        // 4. Branch if Zero (Pressed) -> BEQ Pressed
        // Offset: Forward X bytes.
        // BEQ opcode: 67xx (xx = 8-bit offset)
        // Needs target label.
        const branch_loc = pc;
        pc += 2; // fill later

        // Released (Red)
        // Set CRAM Addr 0
        bus.rom[pc] = 0x33;
        bus.rom[pc + 1] = 0xFC;
        pc += 2; // MOVE.w #...
        bus.rom[pc] = 0xC0;
        bus.rom[pc + 1] = 0x00;
        pc += 2; // Data
        bus.rom[pc] = 0x00;
        bus.rom[pc + 1] = 0xC0;
        pc += 2; // Addr Hi
        bus.rom[pc] = 0x00;
        bus.rom[pc + 1] = 0x04;
        pc += 2; // Addr Lo
        bus.rom[pc] = 0x33;
        bus.rom[pc + 1] = 0xFC;
        pc += 2;
        bus.rom[pc] = 0x00;
        bus.rom[pc + 1] = 0x00;
        pc += 2; // Data
        bus.rom[pc] = 0x00;
        bus.rom[pc + 1] = 0xC0;
        pc += 2;
        bus.rom[pc] = 0x00;
        bus.rom[pc + 1] = 0x04;
        pc += 2;

        // Write Red (0x000E)
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

        // BRA Loop
        // Opcode 60xx
        // Target: loop_start. Current pc is at start of BRA.
        const back_jump = @as(i32, @intCast(loop_start)) - @as(i32, @intCast(pc + 2));
        bus.rom[pc] = 0x60;
        bus.rom[pc + 1] = @as(u8, @intCast(back_jump & 0xFF));
        pc += 2;

        // Pressed Label Target
        const pressed_target = pc;
        // Fix up branch offset
        const fwd_jump = @as(i32, @intCast(pressed_target)) - @as(i32, @intCast(branch_loc + 2));
        bus.rom[branch_loc] = 0x67;
        bus.rom[branch_loc + 1] = @as(u8, @intCast(fwd_jump & 0xFF));

        // Pressed (Green)
        // Set CRAM Addr 0
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

        // Write Green (0x00E0)
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

        // BRA Loop
        const back_jump2 = @as(i32, @intCast(loop_start)) - @as(i32, @intCast(pc + 2));
        bus.rom[pc] = 0x60;
        bus.rom[pc + 1] = @as(u8, @intCast(back_jump2 & 0xFF));
        pc += 2;

        // 5. Halt loop
        bus.rom[pc] = 0x60;
        bus.rom[pc + 1] = 0xFE;
        pc += 2;
    } else {
        // Parse ROM Header (Basic)
        if (bus.rom.len >= 0x200) {
            const console = bus.rom[0x100..0x110];
            const title = bus.rom[0x150..0x180]; // Domestic Name
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

    mainLoop: while (true) {
        const frame_start = std.time.nanoTimestamp();
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
                    if (keyboardInputFromScancode(scancode)) |mapped_key| {
                        _ = input_bindings.applyKeyboard(&bus.io, mapped_key, pressed);

                        if (pressed) {
                            switch (input_bindings.hotkeyForKeyboard(mapped_key) orelse continue) {
                                .step => {
                                    machine.runMasterSlice(clock.m68k_divider);
                                    machine.debugDump();
                                },
                                .registers => machine.debugDump(),
                                .quit => break :mainLoop,
                            }
                        }
                    }
                },
                else => {},
            }
        }

        // Frame scheduler (NTSC-like): active display + HBlank per line, then VBlank lines.
        const visible_lines: u16 = if (bus.vdp.pal_mode) clock.pal_visible_lines else clock.ntsc_visible_lines;
        const total_lines: u16 = if (bus.vdp.pal_mode) clock.pal_lines_per_frame else clock.ntsc_lines_per_frame;
        bus.vdp.beginFrame();
        for (0..total_lines) |line_idx| {
            const line: u16 = @intCast(line_idx);
            const entering_vblank = bus.vdp.setScanlineState(line, visible_lines, total_lines);
            if (entering_vblank and bus.vdp.isVBlankInterruptEnabled()) {
                cpu.requestInterrupt(6); // V-BLANK interrupt at vblank entry
            }
            if (entering_vblank) {
                bus.z80.assertIrq(0xFF);
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
            if (entering_vblank) {
                bus.z80.clearIrq();
            }

            if (line < visible_lines) {
                bus.vdp.renderScanline(line);
            }
        }
        bus.vdp.odd_frame = !bus.vdp.odd_frame;
        if ((frame_counter % 300) == 0) {
            std.debug.print("f={d} pc={X:0>8}\n", .{ frame_counter, cpu.core.pc });
        }
        if (audio) |*a| {
            if (a.output.canAcceptPending()) {
                const audio_frames = bus.audio_timing.takePending();
                try a.output.pushPending(audio_frames, &bus.z80, bus.vdp.pal_mode);
            }
        } else {
            _ = bus.audio_timing.takePending();
        }

        // Update texture from framebuffer
        _ = SDL_UpdateTexture(vdp_texture, null, @ptrCast(&bus.vdp.framebuffer), 320 * 4);

        // Render
        try zsdl3.setRenderDrawColor(renderer, .{ .r = 0x20, .g = 0x20, .b = 0x20, .a = 0xFF });
        try zsdl3.renderClear(renderer);
        try zsdl3.renderTexture(renderer, vdp_texture, null, null);
        zsdl3.renderPresent(renderer);

        frame_counter += 1;
        if (frame_counter > uncapped_boot_frames) {
            const target_frame_ns = frameDurationNs(bus.vdp.pal_mode);
            const frame_elapsed: u64 = @intCast(std.time.nanoTimestamp() - frame_start);
            if (frame_elapsed < target_frame_ns) {
                std.Thread.sleep(target_frame_ns - frame_elapsed);
            }
        }
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

test "frame duration uses console master clock" {
    try std.testing.expectEqual(@as(u64, 16_688_154), frameDurationNs(false));
    try std.testing.expectEqual(@as(u64, 20_120_133), frameDurationNs(true));
}

test "audio-enabled runs do not use uncapped boot frames" {
    try std.testing.expectEqual(@as(u32, 0), uncappedBootFrames(true));
    try std.testing.expectEqual(@as(u32, 240), uncappedBootFrames(false));
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
extern fn SDL_DestroyAudioStream(stream: *zsdl3.AudioStream) void;
extern fn SDL_UpdateTexture(texture: *zsdl3.Texture, rect: ?*const zsdl3.Rect, pixels: ?*const anyopaque, pitch: c_int) bool;
