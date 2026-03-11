const std = @import("std");
const build_options = @import("build_options");
const zsdl3 = @import("zsdl3");
const clock = @import("clock.zig");
const PendingAudioFrames = @import("audio/timing.zig").PendingAudioFrames;
const AudioOutput = @import("audio/output.zig").AudioOutput;
const Z80 = @import("cpu/z80.zig").Z80;
const Io = @import("input/io.zig").Io;
const InputBindings = @import("input/mapping.zig");
const Machine = @import("machine.zig").Machine;
const CoreFrameCounters = @import("performance_profile.zig").CoreFrameCounters;
const Vdp = @import("video/vdp.zig").Vdp;
const GifRecorder = @import("recording/gif.zig").GifRecorder;
const StateFile = @import("state_file.zig");

const AudioInit = struct {
    stream: *zsdl3.AudioStream,
    output: AudioOutput,
    startup_mute_active: bool = true,

    pub fn handlePending(self: *AudioInit, pending: PendingAudioFrames, z80: anytype, is_pal: bool) !void {
        if (self.startupMuteActive()) {
            const saw_audible_activity = z80.hasPendingAudibleEvents();
            try self.output.discardPending(pending, z80, is_pal);
            if (saw_audible_activity) self.clearStartupMute();
            return;
        }

        if (self.queueHasRoom()) {
            try self.pushPending(pending, z80, is_pal);
        } else {
            try self.output.discardPending(pending, z80, is_pal);
        }
    }

    fn queueHasRoom(self: *const AudioInit) bool {
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

    fn startupMuteActive(self: *const AudioInit) bool {
        return self.startup_mute_active;
    }

    fn armStartupMute(self: *AudioInit) void {
        self.startup_mute_active = true;
    }

    fn clearStartupMute(self: *AudioInit) void {
        self.startup_mute_active = false;
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

fn frameDurationNs(is_pal: bool, master_cycles_per_frame: u32) u64 {
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
    show_performance_hud: bool = false,

    fn emulationPaused(self: *const FrontendUi) bool {
        return self.paused or self.show_help or self.dialog_active or self.show_keyboard_editor;
    }
};

const performance_spike_log_threshold_ns: u64 = 4 * std.time.ns_per_ms;
const performance_spike_log_burst_delta_ns: u64 = 8 * std.time.ns_per_ms;
const performance_spike_window_ns: u64 = std.time.ns_per_s;
const performance_core_sample_period: u64 = 16;
const performance_core_burst_frames: u32 = 8;

fn queuedAudioNsFromBytes(queued_bytes: usize) u64 {
    return @intCast((@as(u128, queued_bytes) * std.time.ns_per_s) /
        (@as(u128, AudioOutput.output_rate) * AudioOutput.channels * @sizeOf(i16)));
}

const PerformanceStageSample = struct {
    label: []const u8,
    ns: u64,
};

const PerformanceFramePhases = struct {
    emulation_ns: u64 = 0,
    audio_ns: u64 = 0,
    upload_ns: u64 = 0,
    draw_ns: u64 = 0,
    present_call_ns: u64 = 0,

    fn hottestStage(self: *const PerformanceFramePhases) PerformanceStageSample {
        var hottest = PerformanceStageSample{ .label = "EMU", .ns = self.emulation_ns };
        if (self.audio_ns > hottest.ns) hottest = .{ .label = "AUD", .ns = self.audio_ns };
        if (self.upload_ns > hottest.ns) hottest = .{ .label = "UPL", .ns = self.upload_ns };
        if (self.draw_ns > hottest.ns) hottest = .{ .label = "DRAW", .ns = self.draw_ns };
        if (self.present_call_ns > hottest.ns) hottest = .{ .label = "PRE", .ns = self.present_call_ns };
        return hottest;
    }
};

fn smoothPerformanceMetric(current_avg: u64, sample: u64) u64 {
    return ((current_avg * 7) + sample + 4) / 8;
}

const PerformanceHudState = struct {
    frame_count: u64 = 0,
    slow_frame_count: u64 = 0,
    core_sample_count: u64 = 0,
    last_core_counters_sampled: bool = false,
    last_work_ns: u64 = 0,
    average_work_ns: u64 = 0,
    last_present_ns: u64 = 0,
    average_present_ns: u64 = 0,
    last_target_ns: u64 = 0,
    last_sleep_ns: u64 = 0,
    last_overrun_ns: u64 = 0,
    last_other_ns: u64 = 0,
    average_other_ns: u64 = 0,
    worst_work_ns: u64 = 0,
    worst_overrun_ns: u64 = 0,
    last_audio_queued_bytes: ?usize = null,
    last_phases: PerformanceFramePhases = .{},
    average_phases: PerformanceFramePhases = .{},
    last_core_counters: CoreFrameCounters = .{},
    average_core_counters: CoreFrameCounters = .{},

    fn reset(self: *PerformanceHudState) void {
        self.* = .{};
    }

    fn noteFrame(
        self: *PerformanceHudState,
        work_ns: u64,
        present_ns: u64,
        target_ns: u64,
        audio_queued_bytes: ?usize,
        phases: PerformanceFramePhases,
        core_counters: ?CoreFrameCounters,
    ) void {
        const measured_ns = phases.emulation_ns +| phases.audio_ns +| phases.upload_ns +| phases.draw_ns +| phases.present_call_ns;
        const other_ns = work_ns -| measured_ns;
        self.frame_count += 1;
        self.last_work_ns = work_ns;
        self.last_present_ns = present_ns;
        self.last_target_ns = target_ns;
        self.last_sleep_ns = present_ns -| work_ns;
        self.last_overrun_ns = if (work_ns > target_ns) work_ns - target_ns else 0;
        self.last_other_ns = other_ns;
        self.worst_work_ns = @max(self.worst_work_ns, work_ns);
        self.worst_overrun_ns = @max(self.worst_overrun_ns, self.last_overrun_ns);
        self.last_audio_queued_bytes = audio_queued_bytes;
        self.last_phases = phases;
        self.last_core_counters_sampled = core_counters != null;
        if (self.last_overrun_ns != 0) self.slow_frame_count += 1;

        if (self.frame_count == 1) {
            self.average_work_ns = work_ns;
            self.average_present_ns = present_ns;
            self.average_phases = phases;
            self.average_other_ns = other_ns;
        } else {
            self.average_work_ns = smoothPerformanceMetric(self.average_work_ns, work_ns);
            self.average_present_ns = smoothPerformanceMetric(self.average_present_ns, present_ns);
            self.average_phases.emulation_ns = smoothPerformanceMetric(self.average_phases.emulation_ns, phases.emulation_ns);
            self.average_phases.audio_ns = smoothPerformanceMetric(self.average_phases.audio_ns, phases.audio_ns);
            self.average_phases.upload_ns = smoothPerformanceMetric(self.average_phases.upload_ns, phases.upload_ns);
            self.average_phases.draw_ns = smoothPerformanceMetric(self.average_phases.draw_ns, phases.draw_ns);
            self.average_phases.present_call_ns = smoothPerformanceMetric(self.average_phases.present_call_ns, phases.present_call_ns);
            self.average_other_ns = smoothPerformanceMetric(self.average_other_ns, other_ns);
        }

        if (core_counters) |sample| {
            self.last_core_counters = sample;
            if (self.core_sample_count == 0) {
                self.average_core_counters = sample;
            } else {
                self.average_core_counters.m68k_instructions = smoothPerformanceMetric(self.average_core_counters.m68k_instructions, sample.m68k_instructions);
                self.average_core_counters.z80_instructions = smoothPerformanceMetric(self.average_core_counters.z80_instructions, sample.z80_instructions);
                self.average_core_counters.transfer_slots = smoothPerformanceMetric(self.average_core_counters.transfer_slots, sample.transfer_slots);
                self.average_core_counters.access_slots = smoothPerformanceMetric(self.average_core_counters.access_slots, sample.access_slots);
                self.average_core_counters.dma_words = smoothPerformanceMetric(self.average_core_counters.dma_words, sample.dma_words);
                self.average_core_counters.render_scanlines = smoothPerformanceMetric(self.average_core_counters.render_scanlines, sample.render_scanlines);
                self.average_core_counters.render_sprite_entries = smoothPerformanceMetric(self.average_core_counters.render_sprite_entries, sample.render_sprite_entries);
                self.average_core_counters.render_sprite_pixels = smoothPerformanceMetric(self.average_core_counters.render_sprite_pixels, sample.render_sprite_pixels);
                self.average_core_counters.render_sprite_opaque_pixels = smoothPerformanceMetric(self.average_core_counters.render_sprite_opaque_pixels, sample.render_sprite_opaque_pixels);
            }
            self.core_sample_count += 1;
        }
    }

    fn queuedAudioNs(self: *const PerformanceHudState) ?u64 {
        const queued_bytes = self.last_audio_queued_bytes orelse return null;
        return queuedAudioNsFromBytes(queued_bytes);
    }

    fn slowFramePercentTenths(self: *const PerformanceHudState) u64 {
        if (self.frame_count == 0) return 0;
        return @intCast((@as(u128, self.slow_frame_count) * 1000 + @as(u128, self.frame_count) / 2) / @as(u128, self.frame_count));
    }

    fn hottestStage(self: *const PerformanceHudState) PerformanceStageSample {
        var hottest = self.last_phases.hottestStage();
        if (self.last_other_ns > hottest.ns) hottest = .{ .label = "OTH", .ns = self.last_other_ns };
        return hottest;
    }
};

fn shouldSampleCoreCounters(show_hud: bool, frame_number: u64, burst_frames_remaining: u32) bool {
    return show_hud and (burst_frames_remaining != 0 or frame_number % performance_core_sample_period == 0);
}

fn nextCoreBurstFramesRemaining(sampled_this_frame: bool, burst_frames_remaining: u32, perf: *const PerformanceHudState) u32 {
    var remaining = burst_frames_remaining;
    if (sampled_this_frame and remaining != 0) remaining -= 1;
    if (isThresholdSlowFrame(perf)) remaining = @max(remaining, performance_core_burst_frames);
    return remaining;
}

const PerformanceSpikeWindowSummary = struct {
    start_frame: u64,
    end_frame: u64,
    frame_count: u64,
    slow_frame_count: u64,
    average_overrun_ns: u64,
    max_overrun_ns: u64,
    audio_queued_bytes: ?usize,

    fn audioQueuedNs(self: *const PerformanceSpikeWindowSummary) ?u64 {
        const queued_bytes = self.audio_queued_bytes orelse return null;
        return queuedAudioNsFromBytes(queued_bytes);
    }
};

const PerformanceSpikeLogUpdate = struct {
    log_frame: bool = false,
    summary: ?PerformanceSpikeWindowSummary = null,
};

const PerformanceSpikeLogState = struct {
    burst_frame_count: u64 = 0,
    burst_last_logged_overrun_ns: u64 = 0,
    window_start_frame: u64 = 0,
    window_frame_count: u64 = 0,
    window_slow_frame_count: u64 = 0,
    window_overrun_ns_total: u64 = 0,
    window_max_overrun_ns: u64 = 0,
    window_target_ns_total: u64 = 0,
    window_last_audio_queued_bytes: ?usize = null,

    fn reset(self: *PerformanceSpikeLogState) void {
        self.resetBurst();
        self.resetWindow();
    }

    fn resetBurst(self: *PerformanceSpikeLogState) void {
        self.burst_frame_count = 0;
        self.burst_last_logged_overrun_ns = 0;
    }

    fn resetWindow(self: *PerformanceSpikeLogState) void {
        self.window_start_frame = 0;
        self.window_frame_count = 0;
        self.window_slow_frame_count = 0;
        self.window_overrun_ns_total = 0;
        self.window_max_overrun_ns = 0;
        self.window_target_ns_total = 0;
        self.window_last_audio_queued_bytes = null;
    }

    fn noteFrame(
        self: *PerformanceSpikeLogState,
        frame_number: u64,
        perf: *const PerformanceHudState,
    ) PerformanceSpikeLogUpdate {
        var update = PerformanceSpikeLogUpdate{};
        const threshold_slow = isThresholdSlowFrame(perf);
        if (threshold_slow) {
            if (self.burst_frame_count == 0) {
                self.burst_frame_count = 1;
                self.burst_last_logged_overrun_ns = perf.last_overrun_ns;
                update.log_frame = true;
            } else {
                self.burst_frame_count += 1;
                if (perf.last_overrun_ns >= self.burst_last_logged_overrun_ns + performance_spike_log_burst_delta_ns) {
                    self.burst_last_logged_overrun_ns = perf.last_overrun_ns;
                    update.log_frame = true;
                }
            }
        } else {
            self.resetBurst();
        }

        if (self.window_frame_count == 0) {
            self.window_start_frame = frame_number;
        }

        self.window_frame_count += 1;
        self.window_target_ns_total += perf.last_target_ns;
        self.window_last_audio_queued_bytes = perf.last_audio_queued_bytes;

        if (threshold_slow) {
            self.window_slow_frame_count += 1;
            self.window_overrun_ns_total += perf.last_overrun_ns;
            self.window_max_overrun_ns = @max(self.window_max_overrun_ns, perf.last_overrun_ns);
        }

        if (self.window_target_ns_total < performance_spike_window_ns) return update;

        if (self.window_slow_frame_count != 0) {
            update.summary = .{
                .start_frame = self.window_start_frame,
                .end_frame = frame_number,
                .frame_count = self.window_frame_count,
                .slow_frame_count = self.window_slow_frame_count,
                .average_overrun_ns = @intCast((@as(u128, self.window_overrun_ns_total) +
                    @as(u128, self.window_slow_frame_count) / 2) / @as(u128, self.window_slow_frame_count)),
                .max_overrun_ns = self.window_max_overrun_ns,
                .audio_queued_bytes = self.window_last_audio_queued_bytes,
            };
        }

        self.resetWindow();
        return update;
    }
};

fn isThresholdSlowFrame(perf: *const PerformanceHudState) bool {
    return perf.last_overrun_ns >= performance_spike_log_threshold_ns;
}

const OverlayLine = union(enum) {
    hotkey: struct {
        action: InputBindings.HotkeyAction,
        label: []const u8,
    },
    text: []const u8,
    blank,
    state_file_slot,
    active_state_slot,
};

const pause_overlay_lines = [_]OverlayLine{
    .state_file_slot,
    .{ .hotkey = .{ .action = .toggle_pause, .label = "RESUME" } },
    .{ .hotkey = .{ .action = .open_rom, .label = "OPEN ROM" } },
    .{ .hotkey = .{ .action = .restart_rom, .label = "SOFT RESET" } },
    .{ .hotkey = .{ .action = .reload_rom, .label = "HARD RESET / RELOAD" } },
    .{ .hotkey = .{ .action = .open_keyboard_editor, .label = "KEYBOARD EDITOR" } },
    .{ .hotkey = .{ .action = .toggle_performance_hud, .label = "PERF HUD" } },
    .{ .hotkey = .{ .action = .reset_performance_hud, .label = "RESET PERF HUD" } },
    .{ .hotkey = .{ .action = .save_quick_state, .label = "SAVE QUICK STATE" } },
    .{ .hotkey = .{ .action = .load_quick_state, .label = "LOAD QUICK STATE" } },
    .{ .hotkey = .{ .action = .save_state_file, .label = "SAVE STATE FILE" } },
    .{ .hotkey = .{ .action = .load_state_file, .label = "LOAD STATE FILE" } },
    .{ .hotkey = .{ .action = .next_state_slot, .label = "NEXT STATE SLOT" } },
    .{ .hotkey = .{ .action = .toggle_help, .label = "HELP" } },
};

const help_overlay_lines = [_]OverlayLine{
    .{ .hotkey = .{ .action = .toggle_help, .label = "CLOSE HELP" } },
    .{ .hotkey = .{ .action = .toggle_pause, .label = "PAUSE OR RESUME" } },
    .{ .hotkey = .{ .action = .open_rom, .label = "OPEN ROM DIALOG" } },
    .{ .hotkey = .{ .action = .restart_rom, .label = "SOFT RESET CONSOLE" } },
    .{ .hotkey = .{ .action = .reload_rom, .label = "HARD RESET OR RELOAD ROM" } },
    .{ .hotkey = .{ .action = .open_keyboard_editor, .label = "KEYBOARD EDITOR" } },
    .{ .hotkey = .{ .action = .toggle_performance_hud, .label = "TOGGLE PERF HUD" } },
    .{ .hotkey = .{ .action = .reset_performance_hud, .label = "RESET PERF HUD" } },
    .{ .hotkey = .{ .action = .save_quick_state, .label = "SAVE QUICK STATE" } },
    .{ .hotkey = .{ .action = .load_quick_state, .label = "LOAD QUICK STATE" } },
    .{ .hotkey = .{ .action = .save_state_file, .label = "SAVE STATE FILE" } },
    .{ .hotkey = .{ .action = .load_state_file, .label = "LOAD STATE FILE" } },
    .{ .hotkey = .{ .action = .next_state_slot, .label = "NEXT STATE SLOT" } },
    .blank,
    .{ .hotkey = .{ .action = .step, .label = "STEP CPU" } },
    .{ .hotkey = .{ .action = .registers, .label = "REGISTER DUMP" } },
    .{ .hotkey = .{ .action = .record_gif, .label = "START OR STOP GIF" } },
    .{ .hotkey = .{ .action = .toggle_fullscreen, .label = "TOGGLE FULLSCREEN" } },
    .{ .hotkey = .{ .action = .quit, .label = "QUIT" } },
    .blank,
    .active_state_slot,
    .{ .text = "HELP PAUSE AND MENUS FREEZE EMULATION" },
};

const max_dialog_message_bytes: usize = 256;

const DialogPathCopy = struct {
    len: usize = 0,
    bytes: [std.fs.max_path_bytes]u8 = [_]u8{0} ** std.fs.max_path_bytes,

    fn slice(self: *const DialogPathCopy) []const u8 {
        return self.bytes[0..self.len];
    }

    fn set(self: *DialogPathCopy, path: []const u8) void {
        std.debug.assert(path.len <= self.bytes.len);
        self.* = .{};
        @memcpy(self.bytes[0..path.len], path);
        self.len = path.len;
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
        self.setStatus(.neutral, "PRESS A KEY  ESC CANCEL  DEL CLEAR");
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

    fn assignHotkey(self: *BindingEditorState, bindings: *InputBindings.Bindings, binding: InputBindings.HotkeyBinding) void {
        switch (self.currentTarget()) {
            .player_action => unreachable,
            .hotkey => |action| bindings.setHotkeyWithModifiers(action, binding.input, binding.modifiers),
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
    renderer_name: ?[]const u8 = null,
    timing_mode: TimingModeOption = .auto,
    show_help: bool = false,
};

const ParseCliError = error{
    InvalidAudioMode,
    MissingAudioModeValue,
    MissingRendererValue,
    MultipleRomPaths,
    UnknownOption,
};

const TimingModeOption = enum {
    auto,
    pal,
    ntsc,
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
        error.MissingRendererValue => "--renderer requires a value",
        error.MultipleRomPaths => "only one ROM path may be provided",
        error.UnknownOption => "unknown option",
    };
}

fn keyboardStatePressed(state: []const bool, scancode: zsdl3.Scancode) bool {
    const index: usize = @intFromEnum(scancode);
    return index < state.len and state[index];
}

fn hotkeyModifiersFromKeyboardState(state: []const bool) InputBindings.HotkeyModifiers {
    return .{
        .shift = keyboardStatePressed(state, .lshift) or keyboardStatePressed(state, .rshift),
        .ctrl = keyboardStatePressed(state, .lctrl) or keyboardStatePressed(state, .rctrl),
        .alt = keyboardStatePressed(state, .lalt) or keyboardStatePressed(state, .ralt),
        .gui = keyboardStatePressed(state, .lgui) or keyboardStatePressed(state, .rgui),
    };
}

fn isHotkeyModifierScancode(scancode: zsdl3.Scancode) bool {
    return switch (scancode) {
        .lshift, .rshift, .lctrl, .rctrl, .lalt, .ralt, .lgui, .rgui => true,
        else => false,
    };
}

fn hotkeyBindingFromScancode(scancode: zsdl3.Scancode, keyboard_state: []const bool) ?InputBindings.HotkeyBinding {
    const input = keyboardInputFromScancode(scancode) orelse return null;
    return .{
        .input = input,
        .modifiers = hotkeyModifiersFromKeyboardState(keyboard_state),
    };
}

fn hotkeyActionDescription(action: InputBindings.HotkeyAction) []const u8 {
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
        .toggle_fullscreen => "FULLSCREEN",
        .quit => "QUIT",
    };
}

fn formatOverlayLine(
    buffer: []u8,
    bindings: *const InputBindings.Bindings,
    line: OverlayLine,
    persistent_state_slot: u8,
) ![]const u8 {
    return switch (line) {
        .blank => "",
        .text => |text| text,
        .state_file_slot => std.fmt.bufPrint(buffer, "STATE FILE SLOT {d}/{d}", .{
            persistent_state_slot,
            StateFile.persistent_state_slot_count,
        }),
        .active_state_slot => std.fmt.bufPrint(buffer, "ACTIVE STATE SLOT {d}/{d}", .{
            persistent_state_slot,
            StateFile.persistent_state_slot_count,
        }),
        .hotkey => |item| {
            var binding_buffer: [48]u8 = undefined;
            const binding = try InputBindings.hotkeyBindingDisplayName(binding_buffer[0..], bindings.hotkeyBinding(item.action));
            return std.fmt.bufPrint(buffer, "{s} {s}", .{ binding, item.label });
        },
    };
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
    audio.armStartupMute();
}

fn queuedAudioBytes(audio: ?*AudioInit) ?usize {
    const handle = audio orelse return null;
    return zsdl3.getAudioStreamQueued(handle.stream) catch null;
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
    timing_mode: TimingModeOption,
    audio: ?*AudioInit,
    gif_recorder: *?GifRecorder,
    frame_counter: *u32,
    rom_path: []const u8,
) !void {
    var next_machine = try Machine.init(allocator, rom_path);
    errdefer next_machine.deinit(allocator);

    logLoadedRomMetadata(&next_machine, rom_path);
    const resolved_timing = resolveTimingMode(next_machine.romMetadata(), timing_mode);
    const resolved_region = resolveConsoleRegion(next_machine.romMetadata());
    next_machine.reset();
    next_machine.setPalMode(resolved_timing.pal_mode);
    next_machine.setConsoleIsOverseas(resolved_region.overseas);
    next_machine.applyControllerTypes(input_bindings);
    std.debug.print("Timing mode: {s}\n", .{resolved_timing.description});
    std.debug.print("Console region: {s}\n", .{resolved_region.description});
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

fn softResetCurrentMachine(machine: *Machine, frame_counter: *u32) void {
    machine.softReset();
    frame_counter.* = 0;
    std.debug.print("CPU Soft Reset complete.\n", .{});
    machine.debugDump();
}

fn hardResetCurrentMachine(
    allocator: std.mem.Allocator,
    machine: *Machine,
    input_bindings: *const InputBindings.Bindings,
    timing_mode: TimingModeOption,
    audio: ?*AudioInit,
    gif_recorder: *?GifRecorder,
    frame_counter: *u32,
    rom_path: ?[]const u8,
) !void {
    if (rom_path) |path| {
        try loadRomIntoMachine(
            allocator,
            machine,
            input_bindings,
            timing_mode,
            audio,
            gif_recorder,
            frame_counter,
            path,
        );
        return;
    }

    stopGifRecording(gif_recorder, "GIF recording stopped for hard reset");
    if (audio) |a| {
        resetAudioOutput(a);
    }

    const resolved_timing = resolveTimingMode(machine.romMetadata(), timing_mode);
    const resolved_region = resolveConsoleRegion(machine.romMetadata());
    machine.reset();
    machine.setPalMode(resolved_timing.pal_mode);
    machine.setConsoleIsOverseas(resolved_region.overseas);
    machine.applyControllerTypes(input_bindings);
    frame_counter.* = 0;
    std.debug.print("Timing mode: {s}\n", .{resolved_timing.description});
    std.debug.print("Console region: {s}\n", .{resolved_region.description});
    std.debug.print("CPU Hard Reset complete.\n", .{});
    machine.debugDump();
}

fn printUsage() void {
    std.debug.print("Usage: sandopolis [options] [rom_file]\n", .{});
    std.debug.print("Options:\n", .{});
    std.debug.print("  --audio-mode <mode>   Audio render mode: normal, ym-only, psg-only, unfiltered-mix\n", .{});
    std.debug.print("  --audio-mode=<mode>   Same as above\n", .{});
    std.debug.print("  --renderer <name>     SDL render driver override (for example: software, opengl)\n", .{});
    std.debug.print("  --renderer=<name>     Same as above\n", .{});
    std.debug.print("  --pal                 Force PAL/50Hz timing and version bits\n", .{});
    std.debug.print("  --ntsc                Force NTSC/60Hz timing and version bits\n", .{});
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
        if (std.mem.eql(u8, arg, "--renderer")) {
            index += 1;
            if (index >= args.len) return error.MissingRendererValue;
            options.renderer_name = args[index];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--renderer=")) {
            options.renderer_name = arg["--renderer=".len..];
            continue;
        }
        if (std.mem.eql(u8, arg, "--pal")) {
            options.timing_mode = .pal;
            continue;
        }
        if (std.mem.eql(u8, arg, "--ntsc")) {
            options.timing_mode = .ntsc;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--")) return error.UnknownOption;
        if (options.rom_path != null) return error.MultipleRomPaths;
        options.rom_path = arg;
    }
    return options;
}

fn currentRendererName(renderer: *zsdl3.Renderer) ?[]const u8 {
    const raw = SDL_GetRendererName(renderer);
    if (raw == null) return null;
    return std.mem.span(raw);
}

fn logAvailableRenderDrivers() void {
    const count = zsdl3.getNumRenderDrivers();
    if (count <= 0) {
        std.debug.print("Available SDL render drivers: none\n", .{});
        return;
    }

    std.debug.print("Available SDL render drivers:", .{});
    var index: c_int = 0;
    while (index < count) : (index += 1) {
        if (zsdl3.getRenderDriver(index)) |name| {
            std.debug.print(" {s}", .{name});
        }
    }
    std.debug.print("\n", .{});
}

const ResolvedTimingMode = struct {
    pal_mode: bool,
    description: []const u8,
};

const ResolvedConsoleRegion = struct {
    overseas: bool,
    description: []const u8,
};

fn inferPalModeFromCountryCodes(country_codes: ?[]const u8) ?bool {
    const codes = country_codes orelse return null;

    var uses_letter_codes = false;
    for (codes) |raw| {
        switch (std.ascii.toUpper(raw)) {
            'E', 'U', 'J' => {
                uses_letter_codes = true;
                break;
            },
            else => {},
        }
    }

    var pal_compatible = false;
    var ntsc_compatible = false;
    for (codes) |raw| {
        const ch = std.ascii.toUpper(raw);
        if (uses_letter_codes) {
            switch (ch) {
                0, ' ' => {},
                'E' => pal_compatible = true,
                'U', 'J' => ntsc_compatible = true,
                else => {},
            }
            continue;
        }

        switch (ch) {
            0, ' ' => {},
            '0'...'9', 'A'...'F' => {
                const nibble = std.fmt.charToDigit(ch, 16) catch continue;
                if ((nibble & 0x8) != 0) pal_compatible = true;
                if ((nibble & 0x5) != 0) ntsc_compatible = true;
            },
            else => {},
        }
    }

    if (pal_compatible and !ntsc_compatible) return true;
    if (ntsc_compatible and !pal_compatible) return false;
    return null;
}

fn inferConsoleIsOverseasFromCountryCodes(country_codes: ?[]const u8) ?bool {
    const codes = country_codes orelse return null;

    var uses_letter_codes = false;
    for (codes) |raw| {
        switch (std.ascii.toUpper(raw)) {
            'E', 'U', 'J' => {
                uses_letter_codes = true;
                break;
            },
            else => {},
        }
    }

    var domestic_compatible = false;
    var overseas_compatible = false;
    for (codes) |raw| {
        const ch = std.ascii.toUpper(raw);
        if (uses_letter_codes) {
            switch (ch) {
                0, ' ' => {},
                'J' => domestic_compatible = true,
                'E', 'U' => overseas_compatible = true,
                else => {},
            }
            continue;
        }

        switch (ch) {
            0, ' ' => {},
            '0'...'9', 'A'...'F' => {
                const nibble = std.fmt.charToDigit(ch, 16) catch continue;
                if ((nibble & 0x1) != 0) domestic_compatible = true;
                if ((nibble & 0xC) != 0) overseas_compatible = true;
            },
            else => {},
        }
    }

    if (domestic_compatible and !overseas_compatible) return false;
    if (overseas_compatible and !domestic_compatible) return true;
    return null;
}

fn resolveTimingMode(metadata: Machine.RomMetadata, timing_mode: TimingModeOption) ResolvedTimingMode {
    return switch (timing_mode) {
        .pal => .{ .pal_mode = true, .description = "PAL/50Hz (forced)" },
        .ntsc => .{ .pal_mode = false, .description = "NTSC/60Hz (forced)" },
        .auto => {
            if (inferPalModeFromCountryCodes(metadata.country_codes)) |pal_mode| {
                return .{
                    .pal_mode = pal_mode,
                    .description = if (pal_mode) "PAL/50Hz (auto)" else "NTSC/60Hz (auto)",
                };
            }
            return .{ .pal_mode = false, .description = "NTSC/60Hz (auto default)" };
        },
    };
}

fn resolveConsoleRegion(metadata: Machine.RomMetadata) ResolvedConsoleRegion {
    if (inferConsoleIsOverseasFromCountryCodes(metadata.country_codes)) |overseas| {
        return .{
            .overseas = overseas,
            .description = if (overseas) "Overseas/export (auto)" else "Domestic/Japan (auto)",
        };
    }
    return .{ .overseas = true, .description = "Overseas/export (auto default)" };
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
    editor.setStatus(.neutral, "UP DOWN MOVE  ENTER REBIND  F5 SAVE  ESC CLOSE");
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
        .hotkey => |action| {
            var binding_buffer: [48]u8 = undefined;
            const binding = try InputBindings.hotkeyBindingDisplayName(binding_buffer[0..], bindings.hotkeyBinding(action));
            return std.fmt.bufPrint(buffer, "HOTKEY {s} = {s}", .{
                hotkeyActionDescription(action),
                binding,
            });
        },
    };
}

fn handleBindingEditorKey(
    ui: *FrontendUi,
    editor: *BindingEditorState,
    bindings: *InputBindings.Bindings,
    machine: *Machine,
    input_config_path: ?[]const u8,
    scancode: zsdl3.Scancode,
    hotkey_binding: ?InputBindings.HotkeyBinding,
    pressed: bool,
) bool {
    if (!ui.show_keyboard_editor) {
        if (!pressed) return false;
        const binding = hotkey_binding orelse return false;
        if (bindings.hotkeyForBinding(binding) != .open_keyboard_editor) return false;
        bindingEditorOpen(ui, editor, bindings, machine);
        return true;
    }

    if (!pressed) return true;

    if (editor.capture_mode) {
        switch (scancode) {
            .escape => editor.cancelCapture(),
            .delete => editor.clearSelected(bindings),
            else => {
                if (editor.currentTarget() == .hotkey and isHotkeyModifierScancode(scancode)) {
                    editor.setStatus(.failed, "PRESS A NON-MODIFIER KEY");
                } else if (keyboardInputFromScancode(scancode)) |input| {
                    switch (editor.currentTarget()) {
                        .player_action => editor.assign(bindings, input),
                        .hotkey => editor.assignHotkey(bindings, hotkey_binding orelse .{ .input = input }),
                    }
                } else {
                    editor.setStatus(.failed, "KEY NOT SUPPORTED");
                }
            },
        }
        return true;
    }

    if (scancode == .escape) {
        bindingEditorClose(ui, editor);
        return true;
    }
    if (hotkey_binding) |binding| {
        if (bindings.hotkeyForBinding(binding) == .open_keyboard_editor) {
            bindingEditorClose(ui, editor);
            return true;
        }
    }

    switch (scancode) {
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

fn handleQuickStateAction(
    allocator: std.mem.Allocator,
    action: InputBindings.HotkeyAction,
    machine: *Machine,
    quick_state: *?Machine.Snapshot,
    audio: ?*AudioInit,
    gif_recorder: *?GifRecorder,
    frame_counter: *u32,
) bool {
    switch (action) {
        .save_quick_state => {
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
        .load_quick_state => {
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

fn handlePersistentStateAction(
    allocator: std.mem.Allocator,
    action: InputBindings.HotkeyAction,
    machine: *Machine,
    explicit_state_path: ?[]const u8,
    persistent_state_slot: *u8,
    audio: ?*AudioInit,
    gif_recorder: *?GifRecorder,
    frame_counter: *u32,
) bool {
    persistent_state_slot.* = StateFile.normalizePersistentStateSlot(persistent_state_slot.*);
    if (action == .next_state_slot) {
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

    switch (action) {
        .save_state_file => {
            StateFile.saveToFile(machine, state_path) catch |err| {
                std.debug.print("Failed to save state file {s}: {s}\n", .{ state_path, @errorName(err) });
                return true;
            };
            std.debug.print("Saved state file: {s}\n", .{state_path});
            return true;
        },
        .load_state_file => {
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
                    .output = AudioOutput.init(),
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

fn formatDurationMsTenths(buffer: []u8, ns: u64) ![]const u8 {
    const tenths = (ns + 50_000) / 100_000;
    return std.fmt.bufPrint(buffer, "{d}.{d}", .{ tenths / 10, tenths % 10 });
}

fn formatRateHzTenths(buffer: []u8, ns: u64) ![]const u8 {
    if (ns == 0) return std.fmt.bufPrint(buffer, "0.0", .{});
    const tenths = (@as(u128, std.time.ns_per_s) * 10 + @as(u128, ns) / 2) / @as(u128, ns);
    return std.fmt.bufPrint(buffer, "{d}.{d}", .{ tenths / 10, tenths % 10 });
}

fn formatPercentTenths(buffer: []u8, tenths_percent: u64) ![]const u8 {
    return std.fmt.bufPrint(buffer, "{d}.{d}", .{ tenths_percent / 10, tenths_percent % 10 });
}

fn formatPerformanceSpikeLine(buffer: []u8, frame_number: u32, perf: *const PerformanceHudState) ![]const u8 {
    var metric_buffers: [4][16]u8 = undefined;
    const work_text = try formatDurationMsTenths(metric_buffers[0][0..], perf.last_work_ns);
    const overrun_text = try formatDurationMsTenths(metric_buffers[1][0..], perf.last_overrun_ns);
    const hottest_stage = perf.hottestStage();
    const hot_text = try formatDurationMsTenths(metric_buffers[2][0..], hottest_stage.ns);
    const audio_text = if (perf.queuedAudioNs()) |queued_ns|
        try formatDurationMsTenths(metric_buffers[3][0..], queued_ns)
    else
        "OFF";
    const counter_state = if (perf.last_core_counters_sampled) "LIVE" else "HOLD";

    if (!perf.last_core_counters_sampled) {
        if (perf.last_audio_queued_bytes == null) {
            return std.fmt.bufPrint(buffer, "SLOW FRAME f={d} work={s}ms over={s}ms hot={s} {s}ms ctr={s} audio=OFF", .{
                frame_number,
                work_text,
                overrun_text,
                hottest_stage.label,
                hot_text,
                counter_state,
            });
        }

        return std.fmt.bufPrint(buffer, "SLOW FRAME f={d} work={s}ms over={s}ms hot={s} {s}ms ctr={s} audio={s}ms", .{
            frame_number,
            work_text,
            overrun_text,
            hottest_stage.label,
            hot_text,
            counter_state,
            audio_text,
        });
    }

    if (perf.last_audio_queued_bytes == null) {
        return std.fmt.bufPrint(buffer, "SLOW FRAME f={d} work={s}ms over={s}ms hot={s} {s}ms ctr={s} 68k={d} z80={d} xfer={d} acc={d} dma={d} spr={d}/{d}/{d} audio=OFF", .{
            frame_number,
            work_text,
            overrun_text,
            hottest_stage.label,
            hot_text,
            counter_state,
            perf.last_core_counters.m68k_instructions,
            perf.last_core_counters.z80_instructions,
            perf.last_core_counters.transfer_slots,
            perf.last_core_counters.access_slots,
            perf.last_core_counters.dma_words,
            perf.last_core_counters.render_sprite_entries,
            perf.last_core_counters.render_sprite_pixels,
            perf.last_core_counters.render_sprite_opaque_pixels,
        });
    }

    return std.fmt.bufPrint(buffer, "SLOW FRAME f={d} work={s}ms over={s}ms hot={s} {s}ms ctr={s} 68k={d} z80={d} xfer={d} acc={d} dma={d} spr={d}/{d}/{d} audio={s}ms", .{
        frame_number,
        work_text,
        overrun_text,
        hottest_stage.label,
        hot_text,
        counter_state,
        perf.last_core_counters.m68k_instructions,
        perf.last_core_counters.z80_instructions,
        perf.last_core_counters.transfer_slots,
        perf.last_core_counters.access_slots,
        perf.last_core_counters.dma_words,
        perf.last_core_counters.render_sprite_entries,
        perf.last_core_counters.render_sprite_pixels,
        perf.last_core_counters.render_sprite_opaque_pixels,
        audio_text,
    });
}

fn formatPerformanceSpikeWindowLine(buffer: []u8, summary: *const PerformanceSpikeWindowSummary) ![]const u8 {
    var metric_buffers: [3][16]u8 = undefined;
    const max_overrun_text = try formatDurationMsTenths(metric_buffers[0][0..], summary.max_overrun_ns);
    const avg_overrun_text = try formatDurationMsTenths(metric_buffers[1][0..], summary.average_overrun_ns);
    const audio_text = if (summary.audioQueuedNs()) |queued_ns|
        try formatDurationMsTenths(metric_buffers[2][0..], queued_ns)
    else
        "OFF";

    if (summary.audio_queued_bytes == null) {
        return std.fmt.bufPrint(buffer, "SPIKE WINDOW f={d}-{d} slow={d} max_over={s}ms avg_over={s}ms audio=OFF", .{
            summary.start_frame,
            summary.end_frame,
            summary.slow_frame_count,
            max_overrun_text,
            avg_overrun_text,
        });
    }

    return std.fmt.bufPrint(buffer, "SPIKE WINDOW f={d}-{d} slow={d} max_over={s}ms avg_over={s}ms audio={s}ms", .{
        summary.start_frame,
        summary.end_frame,
        summary.slow_frame_count,
        max_overrun_text,
        avg_overrun_text,
        audio_text,
    });
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

fn renderPauseOverlay(
    renderer: *zsdl3.Renderer,
    viewport: zsdl3.Rect,
    bindings: *const InputBindings.Bindings,
    persistent_state_slot: u8,
) !void {
    const title = "PAUSED";
    const scale = overlayScale(viewport);
    const padding = 10.0 * scale;
    const line_height = 9.0 * scale;

    var line_buffers: [pause_overlay_lines.len][80]u8 = undefined;
    var lines: [pause_overlay_lines.len][]const u8 = undefined;
    var max_width = overlayTextWidth(title, scale);
    for (pause_overlay_lines, 0..) |line, i| {
        lines[i] = try formatOverlayLine(line_buffers[i][0..], bindings, line, persistent_state_slot);
    }
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

fn renderHelpOverlay(
    renderer: *zsdl3.Renderer,
    viewport: zsdl3.Rect,
    bindings: *const InputBindings.Bindings,
    persistent_state_slot: u8,
) !void {
    const title = "SANDOPOLIS HELP";
    const scale = overlayScale(viewport);
    const padding = 10.0 * scale;
    const line_height = 9.0 * scale;

    var line_buffers: [help_overlay_lines.len][96]u8 = undefined;
    var lines: [help_overlay_lines.len][]const u8 = undefined;
    var max_width = overlayTextWidth(title, scale);
    for (help_overlay_lines, 0..) |line, i| {
        lines[i] = try formatOverlayLine(line_buffers[i][0..], bindings, line, persistent_state_slot);
    }
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
    for (help_overlay_lines, lines) |line_spec, line| {
        const color: zsdl3.Color = switch (line_spec) {
            .blank => .{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .hotkey => .{ .r = 0xF2, .g = 0xD0, .b = 0x5B, .a = 0xFF },
            .text => |text| if (std.mem.startsWith(u8, text, "HELP"))
                .{ .r = 0xC7, .g = 0xD2, .b = 0xE0, .a = 0xFF }
            else
                .{ .r = 0xF4, .g = 0xF7, .b = 0xFB, .a = 0xFF },
            else => .{ .r = 0xF4, .g = 0xF7, .b = 0xFB, .a = 0xFF },
        };

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

fn renderPerformanceHud(renderer: *zsdl3.Renderer, viewport: zsdl3.Rect, perf: *const PerformanceHudState) !void {
    const title = "PERF HUD";
    const scale = overlayScale(viewport);
    const padding = 8.0 * scale;
    const line_height = 9.0 * scale;

    var metric_buffers: [19][16]u8 = undefined;
    const fps_text = try formatRateHzTenths(metric_buffers[0][0..], perf.last_present_ns);
    const avg_fps_text = try formatRateHzTenths(metric_buffers[1][0..], perf.average_present_ns);
    const target_fps_text = try formatRateHzTenths(metric_buffers[2][0..], perf.last_target_ns);
    const work_text = try formatDurationMsTenths(metric_buffers[3][0..], perf.last_work_ns);
    const target_text = try formatDurationMsTenths(metric_buffers[4][0..], perf.last_target_ns);
    const avg_text = try formatDurationMsTenths(metric_buffers[5][0..], perf.average_work_ns);
    const sleep_text = try formatDurationMsTenths(metric_buffers[6][0..], perf.last_sleep_ns);
    const overrun_text = try formatDurationMsTenths(metric_buffers[7][0..], perf.last_overrun_ns);
    const slow_percent_text = try formatPercentTenths(metric_buffers[8][0..], perf.slowFramePercentTenths());
    const worst_work_text = try formatDurationMsTenths(metric_buffers[9][0..], perf.worst_work_ns);
    const worst_overrun_text = try formatDurationMsTenths(metric_buffers[10][0..], perf.worst_overrun_ns);
    const audio_text = if (perf.queuedAudioNs()) |queued_ns|
        try formatDurationMsTenths(metric_buffers[11][0..], queued_ns)
    else
        "OFF";
    const emu_text = try formatDurationMsTenths(metric_buffers[12][0..], perf.last_phases.emulation_ns);
    const emu_avg_text = try formatDurationMsTenths(metric_buffers[13][0..], perf.average_phases.emulation_ns);
    const audio_cpu_text = try formatDurationMsTenths(metric_buffers[14][0..], perf.last_phases.audio_ns);
    const audio_cpu_avg_text = try formatDurationMsTenths(metric_buffers[15][0..], perf.average_phases.audio_ns);
    const other_text = try formatDurationMsTenths(metric_buffers[16][0..], perf.last_other_ns);
    const other_avg_text = try formatDurationMsTenths(metric_buffers[17][0..], perf.average_other_ns);
    const core_sample_text = try std.fmt.bufPrint(metric_buffers[18][0..], "1/{d}+B{d}", .{ performance_core_sample_period, performance_core_burst_frames });

    var line_buffers: [27][72]u8 = undefined;
    var lines: [27][]const u8 = undefined;
    lines[0] = try std.fmt.bufPrint(&line_buffers[0], "FPS {s} / {s}", .{ fps_text, target_fps_text });
    lines[1] = try std.fmt.bufPrint(&line_buffers[1], "FPS AVG {s}", .{avg_fps_text});
    lines[2] = try std.fmt.bufPrint(&line_buffers[2], "WORK {s} / {s} MS", .{ work_text, target_text });
    lines[3] = try std.fmt.bufPrint(&line_buffers[3], "AVG {s} MS", .{avg_text});
    lines[4] = try std.fmt.bufPrint(&line_buffers[4], "EMU {s} / {s} MS", .{ emu_text, emu_avg_text });
    lines[5] = try std.fmt.bufPrint(&line_buffers[5], "OTHER {s} / {s} MS", .{ other_text, other_avg_text });
    lines[6] = try std.fmt.bufPrint(&line_buffers[6], "CORE SAMP {s}", .{core_sample_text});
    lines[7] = try std.fmt.bufPrint(&line_buffers[7], "68K INS {d} / {d}", .{ perf.last_core_counters.m68k_instructions, perf.average_core_counters.m68k_instructions });
    lines[8] = try std.fmt.bufPrint(&line_buffers[8], "Z80 INS {d} / {d}", .{ perf.last_core_counters.z80_instructions, perf.average_core_counters.z80_instructions });
    lines[9] = try std.fmt.bufPrint(&line_buffers[9], "XFER {d} / {d}", .{ perf.last_core_counters.transfer_slots, perf.average_core_counters.transfer_slots });
    lines[10] = try std.fmt.bufPrint(&line_buffers[10], "ACCESS {d} / {d}", .{ perf.last_core_counters.access_slots, perf.average_core_counters.access_slots });
    lines[11] = try std.fmt.bufPrint(&line_buffers[11], "DMA WORDS {d} / {d}", .{ perf.last_core_counters.dma_words, perf.average_core_counters.dma_words });
    lines[12] = try std.fmt.bufPrint(&line_buffers[12], "SCANLINES {d} / {d}", .{ perf.last_core_counters.render_scanlines, perf.average_core_counters.render_scanlines });
    lines[13] = try std.fmt.bufPrint(&line_buffers[13], "SPR ENTS {d} / {d}", .{ perf.last_core_counters.render_sprite_entries, perf.average_core_counters.render_sprite_entries });
    lines[14] = try std.fmt.bufPrint(&line_buffers[14], "SPR PIX {d} / {d}", .{ perf.last_core_counters.render_sprite_pixels, perf.average_core_counters.render_sprite_pixels });
    lines[15] = try std.fmt.bufPrint(&line_buffers[15], "SPR OPAQ {d} / {d}", .{ perf.last_core_counters.render_sprite_opaque_pixels, perf.average_core_counters.render_sprite_opaque_pixels });
    lines[16] = try std.fmt.bufPrint(&line_buffers[16], "AUD CPU {s} / {s} MS", .{ audio_cpu_text, audio_cpu_avg_text });
    lines[17] = try std.fmt.bufPrint(&line_buffers[17], "UPLOAD {d} / {d} US", .{
        (perf.last_phases.upload_ns + 500) / 1000,
        (perf.average_phases.upload_ns + 500) / 1000,
    });
    lines[18] = try std.fmt.bufPrint(&line_buffers[18], "DRAW {d} / {d} US", .{
        (perf.last_phases.draw_ns + 500) / 1000,
        (perf.average_phases.draw_ns + 500) / 1000,
    });
    lines[19] = try std.fmt.bufPrint(&line_buffers[19], "PRESENT {d} / {d} US", .{
        (perf.last_phases.present_call_ns + 500) / 1000,
        (perf.average_phases.present_call_ns + 500) / 1000,
    });
    lines[20] = try std.fmt.bufPrint(&line_buffers[20], "SLEEP {s} MS", .{sleep_text});
    lines[21] = try std.fmt.bufPrint(&line_buffers[21], "OVER {s} MS", .{overrun_text});
    lines[22] = try std.fmt.bufPrint(&line_buffers[22], "SLOW {d} {s} PCT", .{ perf.slow_frame_count, slow_percent_text });
    lines[23] = try std.fmt.bufPrint(&line_buffers[23], "WORST WORK {s} MS", .{worst_work_text});
    lines[24] = try std.fmt.bufPrint(&line_buffers[24], "WORST OVR {s} MS", .{worst_overrun_text});
    lines[25] = if (perf.last_audio_queued_bytes == null)
        "AUDIO OFF"
    else
        try std.fmt.bufPrint(&line_buffers[25], "AUDIO {s} MS", .{audio_text});
    lines[26] = "F12 RESET";

    var max_width = overlayTextWidth(title, scale);
    for (lines) |line| {
        max_width = @max(max_width, overlayTextWidth(line, scale));
    }

    const panel = zsdl3.FRect{
        .x = 12.0 * scale,
        .y = 12.0 * scale,
        .w = max_width + padding * 2.0,
        .h = padding * 2.0 + 7.0 * scale + 5.0 * scale + line_height * @as(f32, @floatFromInt(lines.len)),
    };

    try renderOverlayPanel(
        renderer,
        panel,
        .{ .r = 0x12, .g = 0x16, .b = 0x1D, .a = 0xD8 },
        .{ .r = 0xFF, .g = 0x8C, .b = 0x42, .a = 0xFF },
        .{ .r = 0x00, .g = 0x00, .b = 0x00, .a = 0x80 },
    );

    try drawOverlayText(
        renderer,
        panel.x + padding,
        panel.y + padding,
        scale,
        .{ .r = 0xFF, .g = 0xC4, .b = 0x8A, .a = 0xFF },
        title,
    );

    var y = panel.y + padding + 12.0 * scale;
    for (lines) |line| {
        try drawOverlayText(
            renderer,
            panel.x + padding,
            y,
            scale,
            .{ .r = 0xF4, .g = 0xF7, .b = 0xFB, .a = 0xFF },
            line,
        );
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
        "PRESS A KEY  ESC CANCEL  DEL CLEAR"
    else
        "UP DOWN MOVE  ENTER REBIND  F5 SAVE  ESC CLOSE";
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
    perf: *const PerformanceHudState,
) !void {
    if (!ui.show_performance_hud and !ui.paused and !ui.show_help and !ui.dialog_active and !ui.show_keyboard_editor) return;

    const viewport = try zsdl3.getRenderViewport(renderer);
    try zsdl3.setRenderDrawBlendMode(renderer, .blend);
    if (ui.show_performance_hud) {
        try renderPerformanceHud(renderer, viewport, perf);
    }
    if (!ui.paused and !ui.show_help and !ui.dialog_active and !ui.show_keyboard_editor) return;
    if (ui.dialog_active) {
        try renderDialogOverlay(renderer, viewport);
    } else if (ui.show_keyboard_editor) {
        try renderKeyboardEditorOverlay(renderer, viewport, editor, bindings);
    } else if (ui.show_help) {
        try renderHelpOverlay(renderer, viewport, bindings, persistent_state_slot);
    } else {
        try renderPauseOverlay(renderer, viewport, bindings, persistent_state_slot);
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
        .{ .resizable = true },
    );
    defer window.destroy();

    const requested_renderer_name_z = if (cli.renderer_name) |name| try allocator.dupeZ(u8, name) else null;
    defer if (requested_renderer_name_z) |name| allocator.free(name);

    const renderer = zsdl3.Renderer.create(window, if (requested_renderer_name_z) |name| name else null) catch |err| {
        if (cli.renderer_name) |name| {
            std.debug.print("Renderer request failed: {s}\n", .{name});
        } else {
            std.debug.print("Renderer creation failed for auto selection\n", .{});
        }
        logAvailableRenderDrivers();
        return err;
    };
    defer renderer.destroy();
    if (cli.renderer_name) |name| {
        std.debug.print("Renderer request: {s}\n", .{name});
    }
    if (currentRendererName(renderer)) |name| {
        std.debug.print("Renderer backend: {s}\n", .{name});
    }

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

    const vdp_texture = try zsdl3.createTexture(
        renderer,
        zsdl3.PixelFormatEnum.argb8888,
        zsdl3.TextureAccess.streaming,
        @intCast(Vdp.framebuffer_width),
        @intCast(Vdp.max_framebuffer_height),
    );
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

    const resolved_timing = resolveTimingMode(machine.romMetadata(), cli.timing_mode);
    const resolved_region = resolveConsoleRegion(machine.romMetadata());
    machine.reset();
    machine.setPalMode(resolved_timing.pal_mode);
    machine.setConsoleIsOverseas(resolved_region.overseas);
    std.debug.print("Timing mode: {s}\n", .{resolved_timing.description});
    std.debug.print("Console region: {s}\n", .{resolved_region.description});
    std.debug.print("CPU Reset complete.\n", .{});
    machine.debugDump();
    var current_rom_path = DialogPathCopy{};
    if (rom_path) |path| current_rom_path.set(path);
    var frame_counter: u32 = 0;
    const uncapped_boot_frames: u32 = uncappedBootFrames(audio != null);
    var gif_recorder: ?GifRecorder = null;
    var quick_state: ?Machine.Snapshot = null;
    var persistent_state_slot: u8 = StateFile.default_persistent_state_slot;
    defer if (quick_state) |*state| state.deinit(allocator);
    var frontend_ui = FrontendUi{};
    var performance_hud = PerformanceHudState{};
    var performance_spike_log = PerformanceSpikeLogState{};
    var core_profile_frames_remaining: u32 = 0;
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
                    const keyboard_state = zsdl3.getKeyboardState();
                    const hotkey_binding = hotkeyBindingFromScancode(scancode, keyboard_state);
                    if (handleBindingEditorKey(
                        &frontend_ui,
                        &binding_editor,
                        &input_bindings,
                        &machine,
                        input_config_path,
                        scancode,
                        hotkey_binding,
                        pressed,
                    )) {
                        continue;
                    }
                    if (pressed) {
                        if (hotkey_binding) |binding| {
                            if (input_bindings.hotkeyForBinding(binding)) |action| {
                                if (handleQuickStateAction(
                                    allocator,
                                    action,
                                    &machine,
                                    &quick_state,
                                    if (audio) |*a| a else null,
                                    &gif_recorder,
                                    &frame_counter,
                                )) {
                                    continue;
                                }
                                if (handlePersistentStateAction(
                                    allocator,
                                    action,
                                    &machine,
                                    null,
                                    &persistent_state_slot,
                                    if (audio) |*a| a else null,
                                    &gif_recorder,
                                    &frame_counter,
                                )) {
                                    continue;
                                }

                                switch (action) {
                                    .toggle_help => frontend_ui.show_help = !frontend_ui.show_help,
                                    .toggle_pause => frontend_ui.paused = !frontend_ui.paused,
                                    .open_rom => _ = launchOpenRomDialog(&file_dialog_state, &frontend_ui, window),
                                    .restart_rom => softResetCurrentMachine(&machine, &frame_counter),
                                    .reload_rom => {
                                        hardResetCurrentMachine(
                                            allocator,
                                            &machine,
                                            &input_bindings,
                                            cli.timing_mode,
                                            if (audio) |*a| a else null,
                                            &gif_recorder,
                                            &frame_counter,
                                            if (current_rom_path.len != 0) current_rom_path.slice() else null,
                                        ) catch |err| {
                                            std.debug.print("Failed to hard reset or reload current ROM: {}\n", .{err});
                                        };
                                    },
                                    .toggle_performance_hud => {
                                        frontend_ui.show_performance_hud = !frontend_ui.show_performance_hud;
                                        if (!frontend_ui.show_performance_hud) {
                                            core_profile_frames_remaining = 0;
                                        } else {
                                            performance_hud.reset();
                                            performance_spike_log.reset();
                                            core_profile_frames_remaining = 0;
                                        }
                                    },
                                    .reset_performance_hud => {
                                        performance_hud.reset();
                                        performance_spike_log.reset();
                                        core_profile_frames_remaining = 0;
                                    },
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
                                            const framebuffer_height: u16 = @intCast(machine.framebuffer().len / Vdp.framebuffer_width);
                                            gif_recorder = GifRecorder.start(path_str, fps, framebuffer_height) catch |err| {
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
                                    .open_keyboard_editor,
                                    .save_quick_state,
                                    .load_quick_state,
                                    .save_state_file,
                                    .load_state_file,
                                    .next_state_slot,
                                    => {},
                                }
                                continue;
                            }
                        }
                    }
                    if (hotkey_binding) |binding| {
                        const mapped_key = binding.input orelse continue;
                        _ = machine.applyKeyboardBindings(&input_bindings, mapped_key, pressed);
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
                    cli.timing_mode,
                    if (audio) |*a| a else null,
                    &gif_recorder,
                    &frame_counter,
                    path.slice(),
                ) catch |err| {
                    std.debug.print("Failed to load ROM {s}: {}\n", .{ path.slice(), err });
                    continue;
                };
                current_rom_path = path;
            },
        }

        if (frame_counter == 0 and (performance_hud.frame_count != 0 or performance_spike_log.window_frame_count != 0)) {
            performance_hud.reset();
            performance_spike_log.reset();
            core_profile_frames_remaining = 0;
        }

        const emulation_paused = frontend_ui.emulationPaused();
        var frame_phases = PerformanceFramePhases{};
        var core_counters = CoreFrameCounters{};
        var target_frame_ns: ?u64 = null;
        const sample_core_counters = shouldSampleCoreCounters(frontend_ui.show_performance_hud, frame_counter, core_profile_frames_remaining);
        if (!emulation_paused) {
            target_frame_ns = frameDurationNs(machine.palMode(), machine.frameMasterCycles());
            const emulation_start = std.time.Instant.now() catch frame_timer;
            if (sample_core_counters) {
                machine.runFrameProfiled(&core_counters);
            } else {
                machine.runFrame();
            }
            frame_phases.emulation_ns = (std.time.Instant.now() catch emulation_start).since(emulation_start);
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
            const audio_start = std.time.Instant.now() catch frame_timer;
            const pending = machine.takePendingAudio();
            try a.handlePending(pending, &machine.bus.z80, machine.palMode());
            frame_phases.audio_ns = (std.time.Instant.now() catch audio_start).since(audio_start);
        } else {
            const audio_start = std.time.Instant.now() catch frame_timer;
            machine.discardPendingAudio();
            frame_phases.audio_ns = (std.time.Instant.now() catch audio_start).since(audio_start);
        }
        const queued_audio_bytes = queuedAudioBytes(if (audio) |*a| a else null);

        const framebuffer = machine.framebuffer();
        const framebuffer_height: i32 = @intCast(framebuffer.len / Vdp.framebuffer_width);
        const update_rect = zsdl3.Rect{
            .x = 0,
            .y = 0,
            .w = @intCast(Vdp.framebuffer_width),
            .h = framebuffer_height,
        };
        const upload_start = std.time.Instant.now() catch frame_timer;
        _ = SDL_UpdateTexture(vdp_texture, &update_rect, @ptrCast(framebuffer.ptr), @intCast(Vdp.framebuffer_width * @sizeOf(u32)));
        frame_phases.upload_ns = (std.time.Instant.now() catch upload_start).since(upload_start);

        const draw_start = std.time.Instant.now() catch frame_timer;
        try zsdl3.setRenderDrawColor(renderer, .{ .r = 0x20, .g = 0x20, .b = 0x20, .a = 0xFF });
        try zsdl3.renderClear(renderer);
        const source_rect = zsdl3.FRect{
            .x = 0,
            .y = 0,
            .w = @floatFromInt(Vdp.framebuffer_width),
            .h = @floatFromInt(framebuffer_height),
        };
        try zsdl3.renderTexture(renderer, vdp_texture, &source_rect, null);
        try renderFrontendOverlay(renderer, &frontend_ui, &binding_editor, &input_bindings, persistent_state_slot, &performance_hud);
        frame_phases.draw_ns = (std.time.Instant.now() catch draw_start).since(draw_start);
        const present_call_start = std.time.Instant.now() catch frame_timer;
        zsdl3.renderPresent(renderer);
        frame_phases.present_call_ns = (std.time.Instant.now() catch present_call_start).since(present_call_start);

        frame_counter += 1;
        const frame_now = std.time.Instant.now() catch frame_timer;
        const work_elapsed = frame_now.since(frame_timer);
        if (frame_counter > uncapped_boot_frames) {
            if (target_frame_ns) |frame_ns| {
                if (work_elapsed < frame_ns) {
                    std.Thread.sleep(frame_ns - work_elapsed);
                }
            }
        }
        const present_elapsed = (std.time.Instant.now() catch frame_now).since(frame_timer);
        if (!emulation_paused) {
            if (target_frame_ns) |frame_ns| {
                performance_hud.noteFrame(
                    work_elapsed,
                    present_elapsed,
                    frame_ns,
                    queued_audio_bytes,
                    frame_phases,
                    if (sample_core_counters) core_counters else null,
                );
                core_profile_frames_remaining = nextCoreBurstFramesRemaining(sample_core_counters, core_profile_frames_remaining, &performance_hud);
                if (frame_counter > uncapped_boot_frames) {
                    const spike_update = performance_spike_log.noteFrame(frame_counter, &performance_hud);
                    if (spike_update.log_frame) {
                        var spike_buffer: [256]u8 = undefined;
                        const spike_line = formatPerformanceSpikeLine(spike_buffer[0..], frame_counter, &performance_hud) catch "SLOW FRAME";
                        std.debug.print("{s}\n", .{spike_line});
                    }
                    if (spike_update.summary) |summary| {
                        var window_buffer: [128]u8 = undefined;
                        const window_line = formatPerformanceSpikeWindowLine(window_buffer[0..], &summary) catch "SPIKE WINDOW";
                        std.debug.print("{s}\n", .{window_line});
                    }
                }
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

test "default hotkeys include frontend commands and modifiers" {
    const bindings = InputBindings.Bindings.defaults();

    try std.testing.expectEqual(
        InputBindings.HotkeyBinding{ .input = .f1 },
        bindings.hotkeyBinding(.toggle_help),
    );
    try std.testing.expectEqual(
        InputBindings.HotkeyBinding{ .input = .f3 },
        bindings.hotkeyBinding(.open_rom),
    );
    try std.testing.expectEqual(
        InputBindings.HotkeyBinding{ .input = .f3, .modifiers = .{ .shift = true } },
        bindings.hotkeyBinding(.restart_rom),
    );
    try std.testing.expectEqual(
        InputBindings.HotkeyBinding{ .input = .f3, .modifiers = .{ .ctrl = true, .shift = true } },
        bindings.hotkeyBinding(.reload_rom),
    );
    try std.testing.expectEqual(
        InputBindings.HotkeyAction.restart_rom,
        bindings.hotkeyForBinding(.{ .input = .f3, .modifiers = .{ .shift = true } }).?,
    );
    try std.testing.expectEqual(
        InputBindings.HotkeyAction.reload_rom,
        bindings.hotkeyForBinding(.{ .input = .f3, .modifiers = .{ .ctrl = true, .shift = true } }).?,
    );
    try std.testing.expect(bindings.hotkeyForBinding(.{ .input = .f3 }) == .open_rom);
}

test "duration formatter rounds to tenths of a millisecond" {
    var buffer: [16]u8 = undefined;
    try std.testing.expectEqualStrings("16.7", try formatDurationMsTenths(buffer[0..], 16_651_000));
    try std.testing.expectEqualStrings("0.0", try formatDurationMsTenths(buffer[0..], 0));
}

test "rate and percent formatters round to tenths" {
    var buffer: [16]u8 = undefined;
    try std.testing.expectEqualStrings("59.9", try formatRateHzTenths(buffer[0..], 16_688_154));
    try std.testing.expectEqualStrings("5.3", try formatPercentTenths(buffer[0..], 53));
}

test "performance spike formatter includes frame timing and audio" {
    var perf = PerformanceHudState{};
    perf.noteFrame(17_500_000, 18_200_000, 16_700_000, 9_600, .{
        .emulation_ns = 15_100_000,
        .audio_ns = 400_000,
        .upload_ns = 200_000,
        .draw_ns = 100_000,
        .present_call_ns = 50_000,
    }, .{
        .m68k_instructions = 2400,
        .z80_instructions = 320,
        .transfer_slots = 180,
        .access_slots = 90,
        .dma_words = 44,
        .render_scanlines = 224,
        .render_sprite_entries = 12,
        .render_sprite_pixels = 96,
        .render_sprite_opaque_pixels = 48,
    });

    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "SLOW FRAME f=42 work=17.5ms over=0.8ms hot=EMU 15.1ms ctr=LIVE 68k=2400 z80=320 xfer=180 acc=90 dma=44 spr=12/96/48 audio=50.0ms",
        try formatPerformanceSpikeLine(buffer[0..], 42, &perf),
    );

    perf.noteFrame(17_500_000, 18_200_000, 16_700_000, null, .{
        .emulation_ns = 15_100_000,
        .audio_ns = 400_000,
        .upload_ns = 200_000,
        .draw_ns = 100_000,
        .present_call_ns = 50_000,
    }, .{
        .m68k_instructions = 2400,
        .z80_instructions = 320,
        .transfer_slots = 180,
        .access_slots = 90,
        .dma_words = 44,
        .render_scanlines = 224,
        .render_sprite_entries = 12,
        .render_sprite_pixels = 96,
        .render_sprite_opaque_pixels = 48,
    });
    try std.testing.expectEqualStrings(
        "SLOW FRAME f=43 work=17.5ms over=0.8ms hot=EMU 15.1ms ctr=LIVE 68k=2400 z80=320 xfer=180 acc=90 dma=44 spr=12/96/48 audio=OFF",
        try formatPerformanceSpikeLine(buffer[0..], 43, &perf),
    );
}

test "performance spike formatter reports OTHER when unmeasured work dominates" {
    var perf = PerformanceHudState{};
    perf.noteFrame(25_000_000, 25_000_000, 16_700_000, null, .{
        .emulation_ns = 8_000_000,
        .audio_ns = 500_000,
        .upload_ns = 200_000,
        .draw_ns = 150_000,
        .present_call_ns = 50_000,
    }, null);

    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "SLOW FRAME f=99 work=25.0ms over=8.3ms hot=OTH 16.1ms ctr=HOLD audio=OFF",
        try formatPerformanceSpikeLine(buffer[0..], 99, &perf),
    );
}

test "performance spike threshold ignores tiny overruns" {
    var perf = PerformanceHudState{};

    perf.noteFrame(20_600_000, 20_600_000, 16_700_000, null, .{}, null);
    try std.testing.expect(!isThresholdSlowFrame(&perf));

    perf.noteFrame(20_700_000, 20_700_000, 16_700_000, null, .{}, null);
    try std.testing.expect(isThresholdSlowFrame(&perf));
}

test "performance spike window formatter summarizes aggregate overruns" {
    const summary = PerformanceSpikeWindowSummary{
        .start_frame = 1200,
        .end_frame = 1259,
        .frame_count = 60,
        .slow_frame_count = 9,
        .average_overrun_ns = 4_800_000,
        .max_overrun_ns = 12_600_000,
        .audio_queued_bytes = 9_600,
    };

    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "SPIKE WINDOW f=1200-1259 slow=9 max_over=12.6ms avg_over=4.8ms audio=50.0ms",
        try formatPerformanceSpikeWindowLine(buffer[0..], &summary),
    );
}

test "performance spike logger suppresses repeated frames inside a burst" {
    var perf = PerformanceHudState{};
    var spikes = PerformanceSpikeLogState{};

    perf.noteFrame(20_700_000, 20_700_000, 16_700_000, null, .{ .emulation_ns = 19_500_000 }, null);
    var update = spikes.noteFrame(10, &perf);
    try std.testing.expect(update.log_frame);
    try std.testing.expect(update.summary == null);

    perf.noteFrame(25_000_000, 25_000_000, 16_700_000, null, .{ .emulation_ns = 23_800_000 }, null);
    update = spikes.noteFrame(11, &perf);
    try std.testing.expect(!update.log_frame);

    perf.noteFrame(28_800_000, 28_800_000, 16_700_000, null, .{ .emulation_ns = 27_000_000 }, null);
    update = spikes.noteFrame(12, &perf);
    try std.testing.expect(update.log_frame);

    perf.noteFrame(16_700_000, 16_700_000, 16_700_000, null, .{ .emulation_ns = 15_500_000 }, null);
    update = spikes.noteFrame(13, &perf);
    try std.testing.expect(!update.log_frame);

    perf.noteFrame(21_000_000, 21_000_000, 16_700_000, null, .{ .emulation_ns = 19_800_000 }, null);
    update = spikes.noteFrame(14, &perf);
    try std.testing.expect(update.log_frame);
}

test "performance spike window emits one-second summaries and resets" {
    var perf = PerformanceHudState{};
    var spikes = PerformanceSpikeLogState{};

    perf.noteFrame(260_000_000, 260_000_000, 250_000_000, 9_600, .{ .emulation_ns = 240_000_000 }, null);
    var update = spikes.noteFrame(100, &perf);
    try std.testing.expect(update.log_frame);
    try std.testing.expect(update.summary == null);

    perf.noteFrame(200_000_000, 200_000_000, 250_000_000, 9_600, .{ .emulation_ns = 180_000_000 }, null);
    update = spikes.noteFrame(101, &perf);
    try std.testing.expect(!update.log_frame);
    try std.testing.expect(update.summary == null);

    perf.noteFrame(280_000_000, 280_000_000, 250_000_000, 9_600, .{ .emulation_ns = 260_000_000 }, null);
    update = spikes.noteFrame(102, &perf);
    try std.testing.expect(update.log_frame);
    try std.testing.expect(update.summary == null);

    perf.noteFrame(240_000_000, 240_000_000, 250_000_000, 9_600, .{ .emulation_ns = 220_000_000 }, null);
    update = spikes.noteFrame(103, &perf);
    const summary = update.summary.?;
    try std.testing.expectEqual(@as(u64, 100), summary.start_frame);
    try std.testing.expectEqual(@as(u64, 103), summary.end_frame);
    try std.testing.expectEqual(@as(u64, 4), summary.frame_count);
    try std.testing.expectEqual(@as(u64, 2), summary.slow_frame_count);
    try std.testing.expectEqual(@as(u64, 20_000_000), summary.average_overrun_ns);
    try std.testing.expectEqual(@as(u64, 30_000_000), summary.max_overrun_ns);
    try std.testing.expectEqual(@as(?usize, 9_600), summary.audio_queued_bytes);
    try std.testing.expectEqual(@as(u64, 0), spikes.window_frame_count);
    try std.testing.expectEqual(@as(u64, 0), spikes.window_slow_frame_count);
}

test "performance spike window ignores sub-threshold overruns" {
    var perf = PerformanceHudState{};
    var spikes = PerformanceSpikeLogState{};

    perf.noteFrame(250_200_000, 250_200_000, 250_000_000, 9_600, .{ .emulation_ns = 240_000_000 }, null);
    _ = spikes.noteFrame(200, &perf);

    perf.noteFrame(253_900_000, 253_900_000, 250_000_000, 9_600, .{ .emulation_ns = 243_000_000 }, null);
    _ = spikes.noteFrame(201, &perf);

    perf.noteFrame(250_000_000, 250_000_000, 250_000_000, 9_600, .{ .emulation_ns = 240_000_000 }, null);
    _ = spikes.noteFrame(202, &perf);

    perf.noteFrame(250_000_000, 250_000_000, 250_000_000, 9_600, .{ .emulation_ns = 240_000_000 }, null);
    const update = spikes.noteFrame(203, &perf);
    try std.testing.expect(!update.log_frame);
    try std.testing.expect(update.summary == null);
    try std.testing.expectEqual(@as(u64, 0), spikes.window_frame_count);
    try std.testing.expectEqual(@as(u64, 0), spikes.window_slow_frame_count);
}

test "performance hud tracks slow frames and queued audio" {
    var perf = PerformanceHudState{};

    perf.noteFrame(17_500_000, 18_200_000, 16_700_000, 9_600, .{
        .emulation_ns = 15_100_000,
        .audio_ns = 400_000,
        .upload_ns = 200_000,
        .draw_ns = 100_000,
        .present_call_ns = 50_000,
    }, .{
        .m68k_instructions = 2400,
        .z80_instructions = 320,
        .transfer_slots = 180,
        .access_slots = 90,
        .dma_words = 44,
        .render_scanlines = 224,
        .render_sprite_entries = 12,
        .render_sprite_pixels = 96,
        .render_sprite_opaque_pixels = 48,
    });
    try std.testing.expectEqual(@as(u64, 1), perf.frame_count);
    try std.testing.expectEqual(@as(u64, 1), perf.slow_frame_count);
    try std.testing.expectEqual(@as(u64, 1), perf.core_sample_count);
    try std.testing.expect(perf.last_core_counters_sampled);
    try std.testing.expectEqual(@as(u64, 800_000), perf.last_overrun_ns);
    try std.testing.expectEqual(@as(u64, 700_000), perf.last_sleep_ns);
    try std.testing.expectEqual(@as(u64, 17_500_000), perf.worst_work_ns);
    try std.testing.expectEqual(@as(u64, 800_000), perf.worst_overrun_ns);
    try std.testing.expectEqual(@as(u64, 18_200_000), perf.last_present_ns);
    try std.testing.expectEqual(@as(u64, 15_100_000), perf.last_phases.emulation_ns);
    try std.testing.expectEqual(@as(u64, 400_000), perf.last_phases.audio_ns);
    try std.testing.expectEqual(@as(u64, 1_650_000), perf.last_other_ns);
    try std.testing.expectEqual(@as(u64, 2400), perf.last_core_counters.m68k_instructions);
    try std.testing.expectEqual(@as(u64, 44), perf.last_core_counters.dma_words);
    try std.testing.expectEqual(@as(u64, 12), perf.last_core_counters.render_sprite_entries);
    try std.testing.expectEqual(@as(u64, 96), perf.last_core_counters.render_sprite_pixels);
    try std.testing.expectEqual(@as(u64, 48), perf.last_core_counters.render_sprite_opaque_pixels);
    try std.testing.expect(perf.queuedAudioNs() != null);
    try std.testing.expectEqual(@as(u64, 1000), perf.slowFramePercentTenths());

    perf.noteFrame(12_000_000, 16_700_000, 16_700_000, null, .{
        .emulation_ns = 10_000_000,
        .audio_ns = 300_000,
        .upload_ns = 100_000,
        .draw_ns = 80_000,
        .present_call_ns = 40_000,
    }, .{
        .m68k_instructions = 1600,
        .z80_instructions = 200,
        .transfer_slots = 120,
        .access_slots = 60,
        .dma_words = 20,
        .render_scanlines = 224,
        .render_sprite_entries = 8,
        .render_sprite_pixels = 40,
        .render_sprite_opaque_pixels = 20,
    });
    try std.testing.expectEqual(@as(u64, 2), perf.frame_count);
    try std.testing.expectEqual(@as(u64, 1), perf.slow_frame_count);
    try std.testing.expectEqual(@as(u64, 2), perf.core_sample_count);
    try std.testing.expect(perf.last_core_counters_sampled);
    try std.testing.expectEqual(@as(u64, 4_700_000), perf.last_sleep_ns);
    try std.testing.expectEqual(@as(u64, 0), perf.last_overrun_ns);
    try std.testing.expectEqual(@as(?usize, null), perf.last_audio_queued_bytes);
    try std.testing.expectEqual(@as(u64, 14_462_500), perf.average_phases.emulation_ns);
    try std.testing.expectEqual(@as(u64, 1_628_750), perf.average_other_ns);
    try std.testing.expectEqual(@as(u64, 2300), perf.average_core_counters.m68k_instructions);
    try std.testing.expectEqual(@as(u64, 41), perf.average_core_counters.dma_words);
    try std.testing.expectEqual(@as(u64, 224), perf.average_core_counters.render_scanlines);
    try std.testing.expectEqual(@as(u64, 12), perf.average_core_counters.render_sprite_entries);
    try std.testing.expectEqual(@as(u64, 89), perf.average_core_counters.render_sprite_pixels);
    try std.testing.expectEqual(@as(u64, 45), perf.average_core_counters.render_sprite_opaque_pixels);
    try std.testing.expectEqual(@as(u64, 500), perf.slowFramePercentTenths());
}

test "performance hud preserves counter sample until the next sampled frame" {
    var perf = PerformanceHudState{};

    perf.noteFrame(17_000_000, 17_000_000, 16_700_000, null, .{ .emulation_ns = 15_000_000 }, .{
        .m68k_instructions = 1000,
        .z80_instructions = 200,
        .transfer_slots = 300,
        .access_slots = 120,
        .dma_words = 32,
        .render_scanlines = 224,
        .render_sprite_entries = 9,
        .render_sprite_pixels = 72,
        .render_sprite_opaque_pixels = 36,
    });
    perf.noteFrame(16_500_000, 16_500_000, 16_700_000, null, .{ .emulation_ns = 14_500_000 }, null);

    try std.testing.expectEqual(@as(u64, 2), perf.frame_count);
    try std.testing.expectEqual(@as(u64, 1), perf.core_sample_count);
    try std.testing.expect(!perf.last_core_counters_sampled);
    try std.testing.expectEqual(@as(u64, 1000), perf.last_core_counters.m68k_instructions);
    try std.testing.expectEqual(@as(u64, 32), perf.last_core_counters.dma_words);
    try std.testing.expectEqual(@as(u64, 9), perf.last_core_counters.render_sprite_entries);
    try std.testing.expectEqual(@as(u64, 72), perf.last_core_counters.render_sprite_pixels);
    try std.testing.expectEqual(@as(u64, 36), perf.last_core_counters.render_sprite_opaque_pixels);
    try std.testing.expectEqual(@as(u64, 1000), perf.average_core_counters.m68k_instructions);
    try std.testing.expectEqual(@as(u64, 32), perf.average_core_counters.dma_words);
    try std.testing.expectEqual(@as(u64, 9), perf.average_core_counters.render_sprite_entries);
    try std.testing.expectEqual(@as(u64, 72), perf.average_core_counters.render_sprite_pixels);
    try std.testing.expectEqual(@as(u64, 36), perf.average_core_counters.render_sprite_opaque_pixels);
}

test "core counter sampling enters burst mode after a threshold slow frame" {
    var perf = PerformanceHudState{};
    perf.noteFrame(20_700_000, 20_700_000, 16_700_000, null, .{ .emulation_ns = 19_500_000 }, null);

    try std.testing.expect(!shouldSampleCoreCounters(true, 1, 0));
    try std.testing.expect(shouldSampleCoreCounters(true, 16, 0));
    try std.testing.expectEqual(@as(u32, performance_core_burst_frames), nextCoreBurstFramesRemaining(false, 0, &perf));
    try std.testing.expect(shouldSampleCoreCounters(true, 2, performance_core_burst_frames));
    try std.testing.expectEqual(@as(u32, performance_core_burst_frames - 1), nextCoreBurstFramesRemaining(true, performance_core_burst_frames, &PerformanceHudState{}));
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
    try std.testing.expectEqual(@as(u16, 0), machine.controllerPadState(0) & Io.Button.A);

    try std.testing.expect(handleBindingEditorKey(
        &ui,
        &editor,
        &bindings,
        &machine,
        null,
        .f4,
        .{ .input = .f4 },
        true,
    ));
    try std.testing.expect(ui.show_keyboard_editor);
    try std.testing.expect(ui.emulationPaused());
    try std.testing.expect((machine.controllerPadState(0) & Io.Button.A) != 0);

    try std.testing.expect(handleBindingEditorKey(&ui, &editor, &bindings, &machine, null, .@"return", .{ .input = .@"return" }, true));
    try std.testing.expect(editor.capture_mode);
    try std.testing.expect(handleBindingEditorKey(&ui, &editor, &bindings, &machine, null, .v, .{ .input = .v }, true));
    try std.testing.expect(!editor.capture_mode);
    try std.testing.expectEqual(@as(?InputBindings.KeyboardInput, .v), bindings.keyboardBinding(0, .up));

    try std.testing.expect(handleBindingEditorKey(
        &ui,
        &editor,
        &bindings,
        &machine,
        null,
        .f4,
        .{ .input = .f4 },
        true,
    ));
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

    try std.testing.expect(handleBindingEditorKey(
        &ui,
        &editor,
        &bindings,
        &machine,
        null,
        .f4,
        .{ .input = .f4 },
        true,
    ));
    editor.selected_index = InputBindings.player_count * InputBindings.all_actions.len;
    try std.testing.expect(handleBindingEditorKey(&ui, &editor, &bindings, &machine, null, .@"return", .{ .input = .@"return" }, true));
    try std.testing.expect(handleBindingEditorKey(&ui, &editor, &bindings, &machine, null, .delete, .{ .input = .delete }, true));
    try std.testing.expectEqual(InputBindings.HotkeyBinding{}, bindings.hotkeyBinding(.toggle_help));
}

test "binding editor captures modifier hotkeys" {
    const allocator = std.testing.allocator;
    const rom = [_]u8{0} ** 0x400;
    var ui = FrontendUi{};
    var editor = BindingEditorState{};
    var bindings = InputBindings.Bindings.defaults();
    var machine = try Machine.initFromRomBytes(allocator, rom[0..]);
    defer machine.deinit(allocator);

    try std.testing.expect(handleBindingEditorKey(
        &ui,
        &editor,
        &bindings,
        &machine,
        null,
        .f4,
        .{ .input = .f4 },
        true,
    ));
    editor.selected_index = InputBindings.player_count * InputBindings.all_actions.len + @intFromEnum(InputBindings.HotkeyAction.reload_rom);
    try std.testing.expect(handleBindingEditorKey(&ui, &editor, &bindings, &machine, null, .@"return", .{ .input = .@"return" }, true));
    try std.testing.expect(handleBindingEditorKey(
        &ui,
        &editor,
        &bindings,
        &machine,
        null,
        .f3,
        .{ .input = .f3, .modifiers = .{ .ctrl = true, .shift = true } },
        true,
    ));
    try std.testing.expectEqual(
        InputBindings.HotkeyBinding{ .input = .f3, .modifiers = .{ .ctrl = true, .shift = true } },
        bindings.hotkeyBinding(.reload_rom),
    );
}

fn makeFrontendTestRom(allocator: std.mem.Allocator) ![]u8 {
    var rom = try allocator.alloc(u8, 0x400);
    @memset(rom, 0);
    @memcpy(rom[0x100..0x104], "SEGA");
    std.mem.writeInt(u32, rom[0x000..0x004], 0x00FF_FE00, .big);
    std.mem.writeInt(u32, rom[0x004..0x008], 0x0000_0200, .big);
    rom[0x200] = 0x4E;
    rom[0x201] = 0x71;
    return rom;
}

test "soft reset helper rewinds cpu without reloading runtime state" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rom = try makeFrontendTestRom(allocator);
    defer allocator.free(rom);
    try tmp.dir.writeFile(.{ .sub_path = "restart.bin", .data = rom });

    const rom_path = try tmp.dir.realpathAlloc(allocator, "restart.bin");
    defer allocator.free(rom_path);

    var machine = try Machine.init(allocator, rom_path);
    defer machine.deinit(allocator);

    var bindings = InputBindings.Bindings.defaults();
    machine.applyControllerTypes(&bindings);
    const resolved_timing = resolveTimingMode(machine.romMetadata(), .auto);
    const resolved_region = resolveConsoleRegion(machine.romMetadata());
    machine.reset();
    machine.setPalMode(resolved_timing.pal_mode);
    machine.setConsoleIsOverseas(resolved_region.overseas);

    machine.writeWorkRamByte(0x20, 0x5A);
    var frame_counter: u32 = 42;
    machine.runMasterSlice(clock.m68kCyclesToMaster(4));

    try std.testing.expectEqual(@as(u32, 0x0000_0202), machine.programCounter());

    softResetCurrentMachine(&machine, &frame_counter);

    try std.testing.expectEqual(@as(u8, 0x5A), machine.readWorkRamByte(0x20));
    try std.testing.expectEqual(@as(u32, 0), frame_counter);
    try std.testing.expectEqual(@as(u32, 0x0000_0200), machine.programCounter());
}

test "hard reset helper reloads the current rom path" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rom = try makeFrontendTestRom(allocator);
    defer allocator.free(rom);
    try tmp.dir.writeFile(.{ .sub_path = "restart.bin", .data = rom });

    const rom_path = try tmp.dir.realpathAlloc(allocator, "restart.bin");
    defer allocator.free(rom_path);

    var machine = try Machine.init(allocator, rom_path);
    defer machine.deinit(allocator);

    var bindings = InputBindings.Bindings.defaults();
    machine.applyControllerTypes(&bindings);
    const resolved_timing = resolveTimingMode(machine.romMetadata(), .auto);
    const resolved_region = resolveConsoleRegion(machine.romMetadata());
    machine.reset();
    machine.setPalMode(resolved_timing.pal_mode);
    machine.setConsoleIsOverseas(resolved_region.overseas);

    machine.writeWorkRamByte(0x20, 0x5A);
    var gif_recorder: ?GifRecorder = null;
    var frame_counter: u32 = 42;

    try hardResetCurrentMachine(
        allocator,
        &machine,
        &bindings,
        .auto,
        null,
        &gif_recorder,
        &frame_counter,
        rom_path,
    );

    try std.testing.expectEqual(@as(u8, 0x00), machine.readWorkRamByte(0x20));
    try std.testing.expectEqual(@as(u32, 0), frame_counter);
    try std.testing.expectEqual(@as(u32, 0x0000_0200), machine.programCounter());
}

test "audio init stays muted until it sees audible startup activity" {
    var z80 = Z80.init();
    defer z80.deinit();

    var audio = AudioInit{
        .stream = @ptrFromInt(1),
        .output = AudioOutput.init(),
        .startup_mute_active = false,
    };

    audio.armStartupMute();
    try std.testing.expect(audio.startupMuteActive());

    try audio.handlePending(std.mem.zeroes(PendingAudioFrames), &z80, false);
    try std.testing.expect(audio.startupMuteActive());

    z80.writeByte(0x7F11, 0x90);
    try std.testing.expect(z80.hasPendingAudibleEvents());

    try audio.handlePending(std.mem.zeroes(PendingAudioFrames), &z80, false);
    try std.testing.expect(!audio.startupMuteActive());
    try std.testing.expect(!z80.hasPendingAudibleEvents());
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

    machine.writeWorkRamByte(0x20, 0x5A);
    try std.testing.expect(handleQuickStateAction(allocator, .save_quick_state, &machine, &quick_state, null, &gif_recorder, &frame_counter));

    machine.writeWorkRamByte(0x20, 0x00);
    frame_counter = 99;
    try std.testing.expect(handleQuickStateAction(allocator, .load_quick_state, &machine, &quick_state, null, &gif_recorder, &frame_counter));

    try std.testing.expectEqual(@as(u8, 0x5A), machine.readWorkRamByte(0x20));
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

    machine.writeWorkRamByte(0x20, 0x5A);
    try std.testing.expect(handlePersistentStateAction(allocator, .save_state_file, &machine, state_path, &persistent_state_slot, null, &gif_recorder, &frame_counter));
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().access(state_path, .{}));
    try std.fs.cwd().access(slot1_state_path, .{});

    machine.writeWorkRamByte(0x20, 0x00);
    frame_counter = 99;
    try std.testing.expect(handlePersistentStateAction(allocator, .load_state_file, &machine, state_path, &persistent_state_slot, null, &gif_recorder, &frame_counter));

    try std.testing.expectEqual(@as(u8, 0x5A), machine.readWorkRamByte(0x20));
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

    machine.writeWorkRamByte(0x20, 0x11);
    try std.testing.expect(handlePersistentStateAction(allocator, .save_state_file, &machine, state_path, &persistent_state_slot, null, &gif_recorder, &frame_counter));

    try std.testing.expect(handlePersistentStateAction(allocator, .next_state_slot, &machine, state_path, &persistent_state_slot, null, &gif_recorder, &frame_counter));
    try std.testing.expectEqual(@as(u8, 2), persistent_state_slot);

    machine.writeWorkRamByte(0x20, 0x22);
    try std.testing.expect(handlePersistentStateAction(allocator, .save_state_file, &machine, state_path, &persistent_state_slot, null, &gif_recorder, &frame_counter));

    machine.writeWorkRamByte(0x20, 0x00);
    frame_counter = 99;
    try std.testing.expect(handlePersistentStateAction(allocator, .load_state_file, &machine, state_path, &persistent_state_slot, null, &gif_recorder, &frame_counter));
    try std.testing.expectEqual(@as(u8, 0x22), machine.readWorkRamByte(0x20));
    try std.testing.expectEqual(@as(u32, 0), frame_counter);

    try std.testing.expect(handlePersistentStateAction(allocator, .next_state_slot, &machine, state_path, &persistent_state_slot, null, &gif_recorder, &frame_counter));
    try std.testing.expectEqual(@as(u8, 3), persistent_state_slot);
    try std.testing.expect(handlePersistentStateAction(allocator, .next_state_slot, &machine, state_path, &persistent_state_slot, null, &gif_recorder, &frame_counter));
    try std.testing.expectEqual(@as(u8, 1), persistent_state_slot);

    machine.writeWorkRamByte(0x20, 0x00);
    frame_counter = 55;
    try std.testing.expect(handlePersistentStateAction(allocator, .load_state_file, &machine, state_path, &persistent_state_slot, null, &gif_recorder, &frame_counter));
    try std.testing.expectEqual(@as(u8, 0x11), machine.readWorkRamByte(0x20));
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
    try std.testing.expectEqual(@as(u64, 16_688_154), frameDurationNs(false, clock.ntsc_master_cycles_per_frame));
    try std.testing.expectEqual(@as(u64, 20_120_133), frameDurationNs(true, clock.pal_master_cycles_per_frame));
}

test "frame duration accepts interlace-sized fields" {
    const interlace_ntsc_master_cycles = clock.ntsc_master_cycles_per_frame + clock.ntsc_master_cycles_per_line;
    try std.testing.expectEqual(@as(u64, 16_751_849), frameDurationNs(false, interlace_ntsc_master_cycles));
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

test "cli parser accepts renderer override before rom path" {
    const args = [_][]const u8{
        "sandopolis",
        "--renderer=software",
        "roms/test.bin",
    };

    const options = try parseCliArgs(&args);
    try std.testing.expectEqualStrings("roms/test.bin", options.rom_path.?);
    try std.testing.expectEqualStrings("software", options.renderer_name.?);
    try std.testing.expectEqual(AudioOutput.RenderMode.normal, options.audio_mode);
}

test "cli parser accepts pal timing override" {
    const args = [_][]const u8{
        "sandopolis",
        "--pal",
        "roms/test.bin",
    };

    const options = try parseCliArgs(&args);
    try std.testing.expectEqualStrings("roms/test.bin", options.rom_path.?);
    try std.testing.expectEqual(TimingModeOption.pal, options.timing_mode);
}

test "cli parser accepts ntsc timing override" {
    const args = [_][]const u8{
        "sandopolis",
        "--ntsc",
        "roms/test.bin",
    };

    const options = try parseCliArgs(&args);
    try std.testing.expectEqualStrings("roms/test.bin", options.rom_path.?);
    try std.testing.expectEqual(TimingModeOption.ntsc, options.timing_mode);
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

test "cli parser accepts spaced renderer override after rom path" {
    const args = [_][]const u8{
        "sandopolis",
        "roms/test.bin",
        "--renderer",
        "opengl",
    };

    const options = try parseCliArgs(&args);
    try std.testing.expectEqualStrings("roms/test.bin", options.rom_path.?);
    try std.testing.expectEqualStrings("opengl", options.renderer_name.?);
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
    try std.testing.expect(options.renderer_name == null);
    try std.testing.expectEqual(TimingModeOption.auto, options.timing_mode);
}

test "cli parser rejects invalid audio mode values" {
    const args = [_][]const u8{
        "sandopolis",
        "--audio-mode",
        "broken",
    };

    try std.testing.expectError(error.InvalidAudioMode, parseCliArgs(&args));
}

test "cli parser rejects missing renderer value" {
    const args = [_][]const u8{
        "sandopolis",
        "--renderer",
    };

    try std.testing.expectError(error.MissingRendererValue, parseCliArgs(&args));
}

test "timing auto-detection chooses pal for europe-only country code" {
    const metadata = Machine.RomMetadata{
        .console = null,
        .title = null,
        .country_codes = "E               ",
        .reset_stack_pointer = 0,
        .reset_program_counter = 0,
    };

    const resolved = resolveTimingMode(metadata, .auto);
    try std.testing.expect(resolved.pal_mode);
    try std.testing.expectEqualStrings("PAL/50Hz (auto)", resolved.description);
}

test "timing auto-detection defaults to ntsc for multi-region country code" {
    const metadata = Machine.RomMetadata{
        .console = null,
        .title = null,
        .country_codes = "JUE             ",
        .reset_stack_pointer = 0,
        .reset_program_counter = 0,
    };

    const resolved = resolveTimingMode(metadata, .auto);
    try std.testing.expect(!resolved.pal_mode);
    try std.testing.expectEqualStrings("NTSC/60Hz (auto default)", resolved.description);
}

test "console region auto-detection chooses domestic for japan-only country code" {
    const metadata = Machine.RomMetadata{
        .console = null,
        .title = null,
        .country_codes = "J               ",
        .reset_stack_pointer = 0,
        .reset_program_counter = 0,
    };

    const resolved = resolveConsoleRegion(metadata);
    try std.testing.expect(!resolved.overseas);
    try std.testing.expectEqualStrings("Domestic/Japan (auto)", resolved.description);
}

test "console region auto-detection defaults to overseas for multi-region country code" {
    const metadata = Machine.RomMetadata{
        .console = null,
        .title = null,
        .country_codes = "JUE             ",
        .reset_stack_pointer = 0,
        .reset_program_counter = 0,
    };

    const resolved = resolveConsoleRegion(metadata);
    try std.testing.expect(resolved.overseas);
    try std.testing.expectEqualStrings("Overseas/export (auto default)", resolved.description);
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
extern fn SDL_GetRendererName(renderer: *zsdl3.Renderer) [*c]const u8;
extern fn SDL_SetWindowFullscreen(window: *zsdl3.Window, fullscreen: bool) bool;
extern fn SDL_GetWindowFlags(window: *zsdl3.Window) u64;
