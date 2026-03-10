const std = @import("std");
const build_options = @import("build_options");
const zsdl3 = @import("zsdl3");
const clock = @import("clock.zig");
const PendingAudioFrames = @import("audio/timing.zig").PendingAudioFrames;
const AudioOutput = @import("audio/output.zig").AudioOutput;
const Io = @import("input/io.zig").Io;
const InputBindings = @import("input/mapping.zig");
const Machine = @import("machine.zig").Machine;
const GifRecorder = @import("recording/gif.zig").GifRecorder;
const StateFile = @import("state_file.zig");

const AudioInit = struct {
    stream: *zsdl3.AudioStream,
    output: AudioOutput,

    pub fn canAcceptPending(self: *AudioInit) bool {
        const queued_bytes = zsdl3.getAudioStreamQueued(self.stream) catch return false;
        return queued_bytes < AudioOutput.max_queued_bytes;
    }

    pub fn pushPending(self: *AudioInit, pending: PendingAudioFrames, z80: anytype, is_pal: bool) !void {
        const StreamSink = struct {
            stream: *zsdl3.AudioStream,

            pub fn consumeSamples(sink: *@This(), samples: []const i16) !void {
                try zsdl3.putAudioStreamData(i16, sink.stream, samples);
            }
        };

        var sink = StreamSink{ .stream = self.stream };
        try self.output.renderPending(pending, z80, is_pal, &sink);
    }

    pub fn discardPending(self: *AudioInit, pending: PendingAudioFrames, z80: anytype, is_pal: bool) !void {
        try self.output.discardPending(pending, z80, is_pal);
    }
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
    show_keyboard_editor: bool = false,

    fn emulationPaused(self: *const FrontendUi) bool {
        return self.paused or self.show_help or self.dialog_active or self.show_keyboard_editor;
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

const BindingEditorTarget = union(enum) {
    player_action: struct {
        port: usize,
        action: InputBindings.Action,
    },
    hotkey: InputBindings.HotkeyAction,
};

const BindingEditorStatus = enum {
    neutral,
    success,
    failed,
};

const BindingEditorState = struct {
    selected_index: usize = 0,
    capture_mode: bool = false,
    status: BindingEditorStatus = .neutral,
    status_message: DialogMessageCopy = .{},

    fn selectionCount() usize {
        return InputBindings.player_count * InputBindings.all_actions.len + InputBindings.all_hotkey_actions.len;
    }

    fn currentTarget(self: *const BindingEditorState) BindingEditorTarget {
        return targetForIndex(self.selected_index);
    }

    fn move(self: *BindingEditorState, delta: isize) void {
        const count: isize = @intCast(selectionCount());
        var next: isize = @intCast(self.selected_index);
        next += delta;
        while (next < 0) next += count;
        while (next >= count) next -= count;
        self.selected_index = @intCast(next);
    }

    fn beginCapture(self: *BindingEditorState) void {
        self.capture_mode = true;
        self.setStatus(.neutral, "PRESS A KEY  ESC CANCEL  F12 CLEAR");
    }

    fn cancelCapture(self: *BindingEditorState) void {
        self.capture_mode = false;
        self.setStatus(.neutral, "REBIND CANCELED");
    }

    fn assign(self: *BindingEditorState, bindings: *InputBindings.Bindings, input: InputBindings.KeyboardInput) void {
        switch (self.currentTarget()) {
            .player_action => |target| bindings.setKeyboardForPort(target.port, target.action, input),
            .hotkey => |action| bindings.setHotkey(action, input),
        }
        self.capture_mode = false;
        self.setStatus(.success, "BINDING UPDATED");
    }

    fn clearSelected(self: *BindingEditorState, bindings: *InputBindings.Bindings) void {
        switch (self.currentTarget()) {
            .player_action => |target| bindings.setKeyboardForPort(target.port, target.action, null),
            .hotkey => |action| bindings.setHotkey(action, null),
        }
        self.capture_mode = false;
        self.setStatus(.success, "BINDING CLEARED");
    }

    fn clearStatus(self: *BindingEditorState) void {
        self.status = .neutral;
        self.status_message = .{};
    }

    fn setStatus(self: *BindingEditorState, status: BindingEditorStatus, message: []const u8) void {
        self.status = status;
        self.status_message = .{};
        const len = @min(message.len, self.status_message.bytes.len);
        @memcpy(self.status_message.bytes[0..len], message[0..len]);
        self.status_message.len = len;
    }

    fn targetForIndex(index: usize) BindingEditorTarget {
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
    const metadata = machine.romMetadata();
    std.debug.print("Loading ROM: {s}\n", .{rom_path});
    if (metadata.console) |console| {
        std.debug.print("Console: {s}\n", .{console});
    }
    if (metadata.title) |title| {
        std.debug.print("Title:   {s}\n", .{title});
    }
    std.debug.print("Reset Vectors: SSP={X:0>8} PC={X:0>8}\n", .{
        metadata.reset_stack_pointer,
        metadata.reset_program_counter,
    });
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
    next_machine.applyControllerTypes(input_bindings);
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
    machine.rebindRuntimePointers();
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

fn effectiveInputConfigPath(input_config_path: ?[]const u8) []const u8 {
    return input_config_path orelse InputBindings.default_config_name;
}

fn bindingName(input: ?InputBindings.KeyboardInput) []const u8 {
    return if (input) |value| InputBindings.keyboardInputName(value) else "none";
}

fn bindingEditorOpen(ui: *FrontendUi, editor: *BindingEditorState, bindings: *const InputBindings.Bindings, machine: *Machine) void {
    ui.show_keyboard_editor = true;
    ui.show_help = false;
    editor.capture_mode = false;
    editor.setStatus(.neutral, "UP DOWN MOVE  ENTER REBIND  F5 SAVE  F4 CLOSE");
    machine.releaseKeyboardBindings(bindings);
}

fn bindingEditorClose(ui: *FrontendUi, editor: *BindingEditorState) void {
    ui.show_keyboard_editor = false;
    editor.capture_mode = false;
    editor.clearStatus();
}

fn bindingEditorRowText(
    buffer: []u8,
    bindings: *const InputBindings.Bindings,
    target: BindingEditorTarget,
) ![]const u8 {
    return switch (target) {
        .player_action => |item| std.fmt.bufPrint(buffer, "P{d} {s} = {s}", .{
            item.port + 1,
            InputBindings.actionName(item.action),
            bindingName(bindings.keyboardBinding(item.port, item.action)),
        }),
        .hotkey => |action| std.fmt.bufPrint(buffer, "HOTKEY {s} = {s}", .{
            InputBindings.hotkeyActionName(action),
            bindingName(bindings.hotkeyBinding(action)),
        }),
    };
}

fn handleBindingEditorKey(
    ui: *FrontendUi,
    editor: *BindingEditorState,
    bindings: *InputBindings.Bindings,
    machine: *Machine,
    input_config_path: ?[]const u8,
    scancode: zsdl3.Scancode,
    pressed: bool,
) bool {
    if (!ui.show_keyboard_editor) {
        if (!pressed or scancode != .f4) return false;
        bindingEditorOpen(ui, editor, bindings, machine);
        return true;
    }

    if (!pressed) return true;

    if (editor.capture_mode) {
        switch (scancode) {
            .escape => editor.cancelCapture(),
            .f12 => editor.clearSelected(bindings),
            else => {
                if (keyboardInputFromScancode(scancode)) |input| {
                    editor.assign(bindings, input);
                } else {
                    editor.setStatus(.failed, "KEY NOT SUPPORTED");
                }
            },
        }
        return true;
    }

    switch (scancode) {
        .f4, .escape => bindingEditorClose(ui, editor),
        .up => editor.move(-1),
        .down => editor.move(1),
        .@"return" => editor.beginCapture(),
        .f5 => {
            const path = effectiveInputConfigPath(input_config_path);
            bindings.saveToFile(path) catch |err| {
                std.debug.print("Failed to save input config {s}: {s}\n", .{ path, @errorName(err) });
                editor.setStatus(.failed, "FAILED TO SAVE CONFIG");
                return true;
            };
            std.debug.print("Saved input config: {s}\n", .{path});
            editor.setStatus(.success, "CONFIG SAVED");
        },
        else => {},
    }
    return true;
}

fn handleQuickStateKey(
    allocator: std.mem.Allocator,
    scancode: zsdl3.Scancode,
    pressed: bool,
    machine: *Machine,
    quick_state: *?Machine.Snapshot,
    audio: ?*AudioInit,
    gif_recorder: *?GifRecorder,
    frame_counter: *u32,
) bool {
    if (!pressed) return false;

    switch (scancode) {
        .f6 => {
            const snapshot = machine.captureSnapshot(allocator) catch |err| {
                std.debug.print("Failed to save quick state: {}\n", .{err});
                return true;
            };
            if (quick_state.*) |*saved| {
                saved.deinit(allocator);
            }
            quick_state.* = snapshot;
            std.debug.print("Quick state saved.\n", .{});
            return true;
        },
        .f7 => {
            if (quick_state.*) |*saved| {
                machine.restoreSnapshot(allocator, saved) catch |err| {
                    std.debug.print("Failed to load quick state: {}\n", .{err});
                    return true;
                };
                stopGifRecording(gif_recorder, "GIF recording stopped for state load");
                if (audio) |a| {
                    resetAudioOutput(a);
                }
                frame_counter.* = 0;
                std.debug.print("Quick state loaded.\n", .{});
            } else {
                std.debug.print("No quick state saved.\n", .{});
            }
            return true;
        },
        else => return false,
    }
}

fn resolvePersistentStatePath(
    allocator: std.mem.Allocator,
    machine: *const Machine,
    explicit_state_path: ?[]const u8,
    persistent_state_slot: u8,
) ![]u8 {
    if (explicit_state_path) |path| {
        return StateFile.pathForSlot(allocator, path, persistent_state_slot);
    }
    return StateFile.pathForMachineSlot(allocator, machine, persistent_state_slot);
}

fn handlePersistentStateKey(
    allocator: std.mem.Allocator,
    scancode: zsdl3.Scancode,
    pressed: bool,
    machine: *Machine,
    explicit_state_path: ?[]const u8,
    persistent_state_slot: *u8,
    audio: ?*AudioInit,
    gif_recorder: *?GifRecorder,
    frame_counter: *u32,
) bool {
    if (!pressed) return false;

    persistent_state_slot.* = StateFile.normalizePersistentStateSlot(persistent_state_slot.*);
    if (scancode == .f10) {
        persistent_state_slot.* = StateFile.nextPersistentStateSlot(persistent_state_slot.*);

        const state_path = resolvePersistentStatePath(allocator, machine, explicit_state_path, persistent_state_slot.*) catch |err| {
            std.debug.print("Failed to resolve state-file slot path: {s}\n", .{@errorName(err)});
            return true;
        };
        defer allocator.free(state_path);

        std.debug.print("Persistent state slot {d}/{d}: {s}\n", .{
            persistent_state_slot.*,
            StateFile.persistent_state_slot_count,
            state_path,
        });
        return true;
    }

    var owned_state_path: ?[]u8 = null;
    defer if (owned_state_path) |path| allocator.free(path);

    owned_state_path = resolvePersistentStatePath(allocator, machine, explicit_state_path, persistent_state_slot.*) catch |err| {
        std.debug.print("Failed to resolve state-file path: {s}\n", .{@errorName(err)});
        return true;
    };
    const state_path = owned_state_path.?;

    switch (scancode) {
        .f8 => {
            StateFile.saveToFile(machine, state_path) catch |err| {
                std.debug.print("Failed to save state file {s}: {s}\n", .{ state_path, @errorName(err) });
                return true;
            };
            std.debug.print("Saved state file: {s}\n", .{state_path});
            return true;
        },
        .f9 => {
            var next_machine = StateFile.loadFromFile(allocator, state_path) catch |err| {
                std.debug.print("Failed to load state file {s}: {s}\n", .{ state_path, @errorName(err) });
                return true;
            };
            errdefer next_machine.deinit(allocator);

            stopGifRecording(gif_recorder, "GIF recording stopped for state-file load");
            if (audio) |a| {
                resetAudioOutput(a);
            }

            var old_machine = machine.*;
            machine.* = next_machine;
            machine.rebindRuntimePointers();
            old_machine.deinit(allocator);
            frame_counter.* = 0;
            std.debug.print("Loaded state file: {s}\n", .{state_path});
            return true;
        },
        else => return false,
    }
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
                    .output = .{},
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

fn renderPauseOverlay(renderer: *zsdl3.Renderer, viewport: zsdl3.Rect, persistent_state_slot: u8) !void {
    const title = "PAUSED";
    var slot_line_buffer: [32]u8 = undefined;
    const slot_line = try std.fmt.bufPrint(&slot_line_buffer, "STATE FILE SLOT {d}/{d}", .{
        persistent_state_slot,
        StateFile.persistent_state_slot_count,
    });
    const lines = [_][]const u8{
        slot_line,
        "F2 RESUME",
        "F3 OPEN ROM",
        "F4 KEYBOARD EDITOR",
        "F6 SAVE QUICK STATE",
        "F7 LOAD QUICK STATE",
        "F8 SAVE STATE FILE",
        "F9 LOAD STATE FILE",
        "F10 NEXT STATE SLOT",
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

fn renderHelpOverlay(renderer: *zsdl3.Renderer, viewport: zsdl3.Rect, persistent_state_slot: u8) !void {
    const title = "SANDOPOLIS HELP";
    var slot_line_buffer: [32]u8 = undefined;
    const slot_line = try std.fmt.bufPrint(&slot_line_buffer, "ACTIVE STATE SLOT {d}/{d}", .{
        persistent_state_slot,
        StateFile.persistent_state_slot_count,
    });
    const lines = [_][]const u8{
        "F1 CLOSE HELP",
        "F2 PAUSE OR RESUME",
        "F3 OPEN ROM DIALOG",
        "F4 KEYBOARD EDITOR",
        "F6 SAVE QUICK STATE",
        "F7 LOAD QUICK STATE",
        "F8 SAVE STATE FILE",
        "F9 LOAD STATE FILE",
        "F10 NEXT STATE SLOT",
        "",
        "SPACE STEP CPU",
        "BACKSPACE REGISTER DUMP",
        "R START OR STOP GIF",
        "F11 TOGGLE FULLSCREEN",
        "ESC QUIT",
        "",
        slot_line,
        "HELP PAUSE AND MENUS FREEZE EMULATION",
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
        else if (std.mem.startsWith(u8, line, "F1") or
            std.mem.startsWith(u8, line, "F2") or
            std.mem.startsWith(u8, line, "F3") or
            std.mem.startsWith(u8, line, "F4") or
            std.mem.startsWith(u8, line, "F6") or
            std.mem.startsWith(u8, line, "F7") or
            std.mem.startsWith(u8, line, "F8") or
            std.mem.startsWith(u8, line, "F9"))
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

fn renderKeyboardEditorOverlay(
    renderer: *zsdl3.Renderer,
    viewport: zsdl3.Rect,
    editor: *const BindingEditorState,
    bindings: *const InputBindings.Bindings,
) !void {
    const title = "KEYBOARD EDITOR";
    const controls = if (editor.capture_mode)
        "PRESS A KEY  ESC CANCEL  F12 CLEAR"
    else
        "UP DOWN MOVE  ENTER REBIND  F5 SAVE  F4 CLOSE";
    const scale = overlayScale(viewport);
    const padding = 10.0 * scale;
    const row_height = 10.0 * scale;
    const header_height = 28.0 * scale;
    const footer_height = 18.0 * scale;
    const visible_rows = @min(@as(usize, 11), BindingEditorState.selectionCount());

    const panel = zsdl3.FRect{
        .x = 12.0 * scale,
        .y = 12.0 * scale,
        .w = @as(f32, @floatFromInt(viewport.w)) - 24.0 * scale,
        .h = header_height + footer_height + @as(f32, @floatFromInt(visible_rows)) * row_height + padding * 2.0,
    };

    try renderOverlayPanel(
        renderer,
        panel,
        .{ .r = 0x0B, .g = 0x11, .b = 0x19, .a = 0xED },
        .{ .r = 0x6A, .g = 0xB5, .b = 0xFF, .a = 0xFF },
        .{ .r = 0x00, .g = 0x00, .b = 0x00, .a = 0x90 },
    );

    try drawOverlayText(
        renderer,
        panel.x + padding,
        panel.y + padding,
        scale,
        .{ .r = 0x6A, .g = 0xB5, .b = 0xFF, .a = 0xFF },
        title,
    );
    try drawOverlayText(
        renderer,
        panel.x + padding,
        panel.y + padding + 11.0 * scale,
        scale,
        .{ .r = 0xD7, .g = 0xE2, .b = 0xEE, .a = 0xFF },
        controls,
    );

    const first_visible = if (editor.selected_index < visible_rows / 2)
        @as(usize, 0)
    else
        @min(
            editor.selected_index - visible_rows / 2,
            BindingEditorState.selectionCount() - visible_rows,
        );
    var y = panel.y + padding + header_height;
    for (0..visible_rows) |row| {
        const index = first_visible + row;
        const selected = index == editor.selected_index;
        const row_rect = zsdl3.FRect{
            .x = panel.x + padding - 3.0 * scale,
            .y = y - 1.0 * scale,
            .w = panel.w - padding * 2.0 + 6.0 * scale,
            .h = row_height,
        };
        if (selected) {
            try zsdl3.setRenderDrawColor(renderer, .{ .r = 0x17, .g = 0x2C, .b = 0x44, .a = 0xF2 });
            try zsdl3.renderFillRect(renderer, row_rect);
            try zsdl3.setRenderDrawColor(renderer, .{ .r = 0x6A, .g = 0xB5, .b = 0xFF, .a = 0xFF });
            try zsdl3.renderRect(renderer, row_rect);
        }

        var line_buffer: [96]u8 = undefined;
        const line = try bindingEditorRowText(line_buffer[0..], bindings, BindingEditorState.targetForIndex(index));
        try drawOverlayText(
            renderer,
            panel.x + padding,
            y,
            scale,
            if (selected)
                .{ .r = 0xFF, .g = 0xF4, .b = 0xC4, .a = 0xFF }
            else
                .{ .r = 0xF4, .g = 0xF7, .b = 0xFB, .a = 0xFF },
            line,
        );
        y += row_height;
    }

    const status_color: zsdl3.Color = switch (editor.status) {
        .neutral => .{ .r = 0xD7, .g = 0xE2, .b = 0xEE, .a = 0xFF },
        .success => .{ .r = 0x89, .g = 0xDA, .b = 0xA2, .a = 0xFF },
        .failed => .{ .r = 0xFF, .g = 0x9B, .b = 0x8E, .a = 0xFF },
    };
    if (editor.status_message.len != 0) {
        try drawOverlayText(
            renderer,
            panel.x + padding,
            panel.y + panel.h - padding - 7.0 * scale,
            scale,
            status_color,
            editor.status_message.slice(),
        );
    }
}

fn renderFrontendOverlay(
    renderer: *zsdl3.Renderer,
    ui: *const FrontendUi,
    editor: *const BindingEditorState,
    bindings: *const InputBindings.Bindings,
    persistent_state_slot: u8,
) !void {
    if (!ui.paused and !ui.show_help and !ui.dialog_active and !ui.show_keyboard_editor) return;

    const viewport = try zsdl3.getRenderViewport(renderer);
    try zsdl3.setRenderDrawBlendMode(renderer, .blend);
    if (ui.dialog_active) {
        try renderDialogOverlay(renderer, viewport);
    } else if (ui.show_keyboard_editor) {
        try renderKeyboardEditorOverlay(renderer, viewport, editor, bindings);
    } else if (ui.show_help) {
        try renderHelpOverlay(renderer, viewport, persistent_state_slot);
    } else {
        try renderPauseOverlay(renderer, viewport, persistent_state_slot);
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

    if (rom_path == null) {
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
    machine.applyControllerTypes(&input_bindings);

    if (rom_path == null) {
        machine.installDummyTestRom();
    } else {
        logLoadedRomMetadata(&machine, rom_path.?);
    }

    machine.reset();
    std.debug.print("CPU Reset complete.\n", .{});
    machine.debugDump();
    var frame_counter: u32 = 0;
    const uncapped_boot_frames: u32 = uncappedBootFrames(audio != null);
    var gif_recorder: ?GifRecorder = null;
    var quick_state: ?Machine.Snapshot = null;
    var persistent_state_slot: u8 = StateFile.default_persistent_state_slot;
    defer if (quick_state) |*state| state.deinit(allocator);
    var frontend_ui = FrontendUi{};
    var file_dialog_state = FileDialogState{};
    var binding_editor = BindingEditorState{};

    var frame_timer = std.time.Instant.now() catch unreachable;
    mainLoop: while (true) {
        frame_timer = std.time.Instant.now() catch frame_timer;
        var event: zsdl3.Event = undefined;
        while (zsdl3.pollEvent(&event)) {
            switch (event.type) {
                zsdl3.EventType.quit => break :mainLoop,
                zsdl3.EventType.gamepad_added => assignGamepadSlot(&gamepads, &joysticks, &gamepad_sticks, &gamepad_triggers, event.gdevice.which),
                zsdl3.EventType.gamepad_removed => removeGamepadSlot(&gamepads, &gamepad_sticks, &gamepad_triggers, &machine, &input_bindings, event.gdevice.which),
                zsdl3.EventType.joystick_added => assignJoystickSlot(&gamepads, &joysticks, &joystick_axes, &joystick_hats, event.jdevice.which),
                zsdl3.EventType.joystick_removed => removeJoystickSlot(&joysticks, &joystick_axes, &joystick_hats, &machine, &input_bindings, event.jdevice.which),
                zsdl3.EventType.gamepad_button_down, zsdl3.EventType.gamepad_button_up => {
                    const pressed = (event.type == zsdl3.EventType.gamepad_button_down);
                    const button = event.gbutton.button;
                    const port = findGamepadPort(&gamepads, event.gbutton.which) orelse continue;
                    if (gamepadInputFromButton(button)) |mapped_button| {
                        _ = machine.applyGamepadBindings(&input_bindings, port, mapped_button, pressed);
                    }
                },
                zsdl3.EventType.gamepad_axis_motion => {
                    const port = findGamepadPort(&gamepads, event.gaxis.which) orelse continue;
                    const axis: zsdl3.Gamepad.Axis = @enumFromInt(event.gaxis.axis);
                    applyInputTransitions(
                        &input_bindings,
                        &machine,
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
                        _ = machine.applyGamepadBindings(&input_bindings, port, mapped_button, pressed);
                    }
                },
                zsdl3.EventType.joystick_axis_motion => {
                    const port = findJoystickPort(&joysticks, event.jaxis.which) orelse continue;
                    applyInputTransitions(
                        &input_bindings,
                        &machine,
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
                        &machine,
                        port,
                        updateHatState(&joystick_hats[port], event.jhat.value),
                    );
                },
                zsdl3.EventType.key_down, zsdl3.EventType.key_up => {
                    const pressed = (event.type == zsdl3.EventType.key_down);
                    const scancode = event.key.scancode;
                    if (handleBindingEditorKey(
                        &frontend_ui,
                        &binding_editor,
                        &input_bindings,
                        &machine,
                        input_config_path,
                        scancode,
                        pressed,
                    )) {
                        continue;
                    }
                    if (handleQuickStateKey(
                        allocator,
                        scancode,
                        pressed,
                        &machine,
                        &quick_state,
                        if (audio) |*a| a else null,
                        &gif_recorder,
                        &frame_counter,
                    )) {
                        continue;
                    }
                    if (handlePersistentStateKey(
                        allocator,
                        scancode,
                        pressed,
                        &machine,
                        null,
                        &persistent_state_slot,
                        if (audio) |*a| a else null,
                        &gif_recorder,
                        &frame_counter,
                    )) {
                        continue;
                    }
                    if (frontendShortcutForKey(scancode, pressed)) |shortcut| {
                        _ = applyFrontendShortcut(&frontend_ui, scancode, pressed);
                        if (shortcut == .open_rom) {
                            _ = launchOpenRomDialog(&file_dialog_state, &frontend_ui, window);
                        }
                        continue;
                    }
                    if (keyboardInputFromScancode(scancode)) |mapped_key| {
                        _ = machine.applyKeyboardBindings(&input_bindings, mapped_key, pressed);

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
                                        const fps: u16 = if (machine.palMode()) 25 else 30;
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
            machine.runFrame();
        }

        if (!emulation_paused) {
            const framebuffer = machine.framebuffer();
            if (gif_recorder) |*rec| {
                if (frame_counter % 2 == 0) {
                    rec.addFrame(framebuffer) catch |err| {
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
            std.debug.print("f={d} pc={X:0>8}\n", .{ frame_counter, machine.programCounter() });
        }
        if (audio) |*a| {
            try machine.drainPendingAudio(a);
        } else {
            machine.discardPendingAudio();
        }

        const framebuffer = machine.framebuffer();
        _ = SDL_UpdateTexture(vdp_texture, null, @ptrCast(framebuffer), 320 * 4);

        try zsdl3.setRenderDrawColor(renderer, .{ .r = 0x20, .g = 0x20, .b = 0x20, .a = 0xFF });
        try zsdl3.renderClear(renderer);
        try zsdl3.renderTexture(renderer, vdp_texture, null, null);
        try renderFrontendOverlay(renderer, &frontend_ui, &binding_editor, &input_bindings, persistent_state_slot);
        zsdl3.renderPresent(renderer);

        frame_counter += 1;
        if (frame_counter > uncapped_boot_frames) {
            const target_frame_ns = frameDurationNs(machine.palMode());
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

test "binding editor opens releases inputs and rebinds selected action" {
    const allocator = std.testing.allocator;
    const rom = [_]u8{0} ** 0x400;
    var ui = FrontendUi{};
    var editor = BindingEditorState{};
    var bindings = InputBindings.Bindings.defaults();
    var machine = try Machine.initFromRomBytes(allocator, rom[0..]);
    defer machine.deinit(allocator);

    _ = machine.applyKeyboardBindings(&bindings, .a, true);
    try std.testing.expectEqual(@as(u16, 0), machine.bus.io.pad[0] & Io.Button.A);

    try std.testing.expect(handleBindingEditorKey(&ui, &editor, &bindings, &machine, null, .f4, true));
    try std.testing.expect(ui.show_keyboard_editor);
    try std.testing.expect(ui.emulationPaused());
    try std.testing.expect((machine.bus.io.pad[0] & Io.Button.A) != 0);

    try std.testing.expect(handleBindingEditorKey(&ui, &editor, &bindings, &machine, null, .@"return", true));
    try std.testing.expect(editor.capture_mode);
    try std.testing.expect(handleBindingEditorKey(&ui, &editor, &bindings, &machine, null, .v, true));
    try std.testing.expect(!editor.capture_mode);
    try std.testing.expectEqual(@as(?InputBindings.KeyboardInput, .v), bindings.keyboardBinding(0, .up));

    try std.testing.expect(handleBindingEditorKey(&ui, &editor, &bindings, &machine, null, .f4, true));
    try std.testing.expect(!ui.show_keyboard_editor);
}

test "binding editor clears hotkeys during capture" {
    const allocator = std.testing.allocator;
    const rom = [_]u8{0} ** 0x400;
    var ui = FrontendUi{};
    var editor = BindingEditorState{};
    var bindings = InputBindings.Bindings.defaults();
    var machine = try Machine.initFromRomBytes(allocator, rom[0..]);
    defer machine.deinit(allocator);

    try std.testing.expect(handleBindingEditorKey(&ui, &editor, &bindings, &machine, null, .f4, true));
    editor.selected_index = InputBindings.player_count * InputBindings.all_actions.len;
    try std.testing.expect(handleBindingEditorKey(&ui, &editor, &bindings, &machine, null, .@"return", true));
    try std.testing.expect(handleBindingEditorKey(&ui, &editor, &bindings, &machine, null, .f12, true));
    try std.testing.expectEqual(@as(?InputBindings.KeyboardInput, null), bindings.hotkeyBinding(.step));
}

test "quick state helper saves and restores machine state" {
    const allocator = std.testing.allocator;
    const rom = [_]u8{0} ** 0x400;

    var machine = try Machine.initFromRomBytes(allocator, rom[0..]);
    defer machine.deinit(allocator);

    var quick_state: ?Machine.Snapshot = null;
    defer if (quick_state) |*state| state.deinit(allocator);
    var gif_recorder: ?GifRecorder = null;
    var frame_counter: u32 = 42;

    machine.bus.ram[0x20] = 0x5A;
    try std.testing.expect(handleQuickStateKey(allocator, .f6, true, &machine, &quick_state, null, &gif_recorder, &frame_counter));

    machine.bus.ram[0x20] = 0x00;
    frame_counter = 99;
    try std.testing.expect(handleQuickStateKey(allocator, .f7, true, &machine, &quick_state, null, &gif_recorder, &frame_counter));

    try std.testing.expectEqual(@as(u8, 0x5A), machine.bus.ram[0x20]);
    try std.testing.expectEqual(@as(u32, 0), frame_counter);
}

test "persistent state helper saves and restores machine state" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rom = [_]u8{0} ** 0x400;
    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);
    const state_path = try std.fs.path.join(allocator, &.{ dir_path, "frontend.state" });
    defer allocator.free(state_path);

    var machine = try Machine.initFromRomBytes(allocator, rom[0..]);
    defer machine.deinit(allocator);

    var gif_recorder: ?GifRecorder = null;
    var frame_counter: u32 = 42;
    var persistent_state_slot: u8 = StateFile.default_persistent_state_slot;
    const slot1_state_path = try StateFile.pathForSlot(allocator, state_path, persistent_state_slot);
    defer allocator.free(slot1_state_path);

    machine.bus.ram[0x20] = 0x5A;
    try std.testing.expect(handlePersistentStateKey(allocator, .f8, true, &machine, state_path, &persistent_state_slot, null, &gif_recorder, &frame_counter));
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().access(state_path, .{}));
    try std.fs.cwd().access(slot1_state_path, .{});

    machine.bus.ram[0x20] = 0x00;
    frame_counter = 99;
    try std.testing.expect(handlePersistentStateKey(allocator, .f9, true, &machine, state_path, &persistent_state_slot, null, &gif_recorder, &frame_counter));

    try std.testing.expectEqual(@as(u8, 0x5A), machine.bus.ram[0x20]);
    try std.testing.expectEqual(@as(u32, 0), frame_counter);
}

test "persistent state helper cycles slots and keeps files separate" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rom = [_]u8{0} ** 0x400;
    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);
    const state_path = try std.fs.path.join(allocator, &.{ dir_path, "frontend.state" });
    defer allocator.free(state_path);

    var machine = try Machine.initFromRomBytes(allocator, rom[0..]);
    defer machine.deinit(allocator);

    var gif_recorder: ?GifRecorder = null;
    var frame_counter: u32 = 17;
    var persistent_state_slot: u8 = StateFile.default_persistent_state_slot;

    machine.bus.ram[0x20] = 0x11;
    try std.testing.expect(handlePersistentStateKey(allocator, .f8, true, &machine, state_path, &persistent_state_slot, null, &gif_recorder, &frame_counter));

    try std.testing.expect(handlePersistentStateKey(allocator, .f10, true, &machine, state_path, &persistent_state_slot, null, &gif_recorder, &frame_counter));
    try std.testing.expectEqual(@as(u8, 2), persistent_state_slot);

    machine.bus.ram[0x20] = 0x22;
    try std.testing.expect(handlePersistentStateKey(allocator, .f8, true, &machine, state_path, &persistent_state_slot, null, &gif_recorder, &frame_counter));

    machine.bus.ram[0x20] = 0x00;
    frame_counter = 99;
    try std.testing.expect(handlePersistentStateKey(allocator, .f9, true, &machine, state_path, &persistent_state_slot, null, &gif_recorder, &frame_counter));
    try std.testing.expectEqual(@as(u8, 0x22), machine.bus.ram[0x20]);
    try std.testing.expectEqual(@as(u32, 0), frame_counter);

    try std.testing.expect(handlePersistentStateKey(allocator, .f10, true, &machine, state_path, &persistent_state_slot, null, &gif_recorder, &frame_counter));
    try std.testing.expectEqual(@as(u8, 3), persistent_state_slot);
    try std.testing.expect(handlePersistentStateKey(allocator, .f10, true, &machine, state_path, &persistent_state_slot, null, &gif_recorder, &frame_counter));
    try std.testing.expectEqual(@as(u8, 1), persistent_state_slot);

    machine.bus.ram[0x20] = 0x00;
    frame_counter = 55;
    try std.testing.expect(handlePersistentStateKey(allocator, .f9, true, &machine, state_path, &persistent_state_slot, null, &gif_recorder, &frame_counter));
    try std.testing.expectEqual(@as(u8, 0x11), machine.bus.ram[0x20]);
    try std.testing.expectEqual(@as(u32, 0), frame_counter);
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
