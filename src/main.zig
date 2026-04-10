const std = @import("std");
const build_options = @import("build_options");
const zsdl3 = @import("zsdl3");
const clock = @import("clock.zig");
const PendingAudioFrames = @import("audio/timing.zig").PendingAudioFrames;
const AudioOutput = @import("audio/output.zig").AudioOutput;
const Z80 = @import("cpu/z80.zig").Z80;
const Io = @import("input/io.zig").Io;
const InputBindings = @import("input/mapping.zig");
const gamepad = @import("input/gamepad.zig");
const keyboard = @import("input/keyboard.zig");
const binding_editor_module = @import("input/binding_editor.zig");
const Machine = @import("machine.zig").Machine;
const SystemMachine = @import("system_machine.zig").SystemMachine;
const SmsMachine = @import("sms/machine.zig").SmsMachine;
const CoreFrameCounters = @import("performance_profile.zig").CoreFrameCounters;
const Vdp = @import("video/vdp.zig").Vdp;
const GifRecorder = @import("recording/gif.zig").GifRecorder;
const WavRecorder = @import("recording/wav.zig").WavRecorder;
const screenshot = @import("recording/screenshot.zig");
const StateFile = @import("state_file.zig");
const rom_paths = @import("rom_paths.zig");
const unified_config = @import("unified_config.zig");
const config_path_mod = @import("config_path.zig");
const ui_render = @import("frontend/ui.zig");
const debugger_mod = @import("frontend/debugger.zig");
const perf_monitor = @import("frontend/performance.zig");
const config_module = @import("frontend/config.zig");
const saves_module = @import("frontend/saves.zig");
const toast_module = @import("frontend/toast.zig");
const dialog_module = @import("frontend/dialog.zig");
const menu_module = @import("frontend/menu.zig");
const rom_metadata = @import("rom_metadata.zig");
const cli_module = @import("cli.zig");

const AudioRuntimeMetrics = struct {
    queue_budget_bytes: usize,
    backlog_recoveries: u64,
    overflow_events: u64,
};

const AudioInit = struct {
    stream: *zsdl3.AudioStream,
    output: AudioOutput,
    startup_mute_active: bool = true,
    startup_mute_warmup_frames: u8 = 0,
    queue_budget_ms: u16 = AudioOutput.default_queue_budget_ms,
    backlog_recovery_count: u64 = 0,
    playback_shadow: [playback_shadow_capacity]i16 = undefined,
    playback_shadow_len: usize = 0,

    const playback_shadow_capacity = (AudioOutput.max_queued_bytes / @sizeOf(i16)) + 4096;

    pub fn handlePending(self: *AudioInit, pending: PendingAudioFrames, z80: anytype, is_pal: bool, wav_recorder: ?*WavRecorder) !void {
        if (self.startupMuteActive()) {
            const saw_audible_activity = z80.hasPendingAudibleEvents();
            try self.output.discardPending(pending, z80, is_pal);
            if (saw_audible_activity) {
                // Warm up filters for several frames before unmuting.
                // This prevents the DC blocker transient "beep" on state load.
                if (self.startup_mute_warmup_frames < 8) {
                    self.startup_mute_warmup_frames += 1;
                } else {
                    self.clearStartupMute();
                }
            }
            return;
        }

        self.syncRecordedPlayback(wav_recorder);
        if (self.queueHasRoom()) {
            try self.pushPending(pending, z80, is_pal, wav_recorder);
        } else if (self.queueIsSeverelyBacklogged()) {
            // Only hard-clear on severe backlog (2x budget) to avoid
            // accumulating unbounded latency after long stalls.
            try self.recoverBackloggedQueue(pending, z80, is_pal, wav_recorder);
        } else {
            // Mild backlog: skip this frame's audio and let the queue
            // drain naturally.  This avoids the pop/click from a hard
            // clear while still recovering within a few frames.
            try self.output.discardPending(pending, z80, is_pal);
        }
    }

    fn queueHasRoom(self: *const AudioInit) bool {
        const queued_bytes = zsdl3.getAudioStreamQueued(self.stream) catch return false;
        return !queueIsBackloggedForBudget(@intCast(queued_bytes), self.queueBudgetBytes());
    }

    fn queueIsSeverelyBacklogged(self: *const AudioInit) bool {
        const queued_bytes = zsdl3.getAudioStreamQueued(self.stream) catch return true;
        return queued_bytes >= self.queueBudgetBytes() * 2;
    }

    fn recoverBackloggedQueue(self: *AudioInit, pending: PendingAudioFrames, z80: anytype, is_pal: bool, wav_recorder: ?*WavRecorder) !void {
        zsdl3.clearAudioStream(self.stream) catch {
            try self.output.discardPending(pending, z80, is_pal);
            return;
        };
        self.backlog_recovery_count += 1;
        self.clearPlaybackShadow();
        self.output.dropQueuedOutput(is_pal);
        try self.pushPending(pending, z80, is_pal, wav_recorder);
    }

    pub fn pushPending(self: *AudioInit, pending: PendingAudioFrames, z80: anytype, is_pal: bool, wav_recorder: ?*WavRecorder) !void {
        const StreamSink = struct {
            stream: *zsdl3.AudioStream,
            audio: *AudioInit,

            pub fn consumeSamples(sink: *@This(), samples: []const i16) !void {
                try zsdl3.putAudioStreamData(i16, sink.stream, samples);
                sink.audio.appendPlaybackShadow(samples);
            }
        };

        _ = wav_recorder;
        var sink = StreamSink{ .stream = self.stream, .audio = self };
        try self.output.renderPending(pending, z80, is_pal, &sink);
    }

    pub fn queueRawSamples(self: *AudioInit, samples: []const i16) !void {
        if (self.startupMuteActive()) {
            if (samples.len > 0) self.clearStartupMute();
            return;
        }
        if (self.queueHasRoom()) {
            try zsdl3.putAudioStreamData(i16, self.stream, samples);
        }
    }

    fn startupMuteActive(self: *const AudioInit) bool {
        return self.startup_mute_active;
    }

    fn armStartupMute(self: *AudioInit) void {
        self.startup_mute_active = true;
        self.startup_mute_warmup_frames = 0;
    }

    fn queueBudgetBytes(self: *const AudioInit) usize {
        return AudioOutput.queueBudgetBytes(self.queue_budget_ms);
    }

    fn setQueueBudgetMs(self: *AudioInit, queue_budget_ms: u16) void {
        self.queue_budget_ms = AudioOutput.clampQueueBudgetMs(queue_budget_ms);
    }

    fn runtimeMetrics(self: *const AudioInit) AudioRuntimeMetrics {
        return .{
            .queue_budget_bytes = self.queueBudgetBytes(),
            .backlog_recoveries = self.backlog_recovery_count,
            .overflow_events = self.output.totalOverflowEvents(),
        };
    }

    fn resetTelemetry(self: *AudioInit) void {
        self.backlog_recovery_count = 0;
    }

    fn clearStartupMute(self: *AudioInit) void {
        self.startup_mute_active = false;
    }

    fn appendPlaybackShadow(self: *AudioInit, samples: []const i16) void {
        if (samples.len == 0) return;
        if (samples.len >= self.playback_shadow.len) {
            const tail = samples[samples.len - self.playback_shadow.len ..];
            @memcpy(self.playback_shadow[0..self.playback_shadow.len], tail);
            self.playback_shadow_len = self.playback_shadow.len;
            return;
        }

        const required_len = self.playback_shadow_len + samples.len;
        if (required_len > self.playback_shadow.len) {
            const drop = required_len - self.playback_shadow.len;
            if (drop < self.playback_shadow_len) {
                const retained = self.playback_shadow_len - drop;
                std.mem.copyForwards(
                    i16,
                    self.playback_shadow[0..retained],
                    self.playback_shadow[drop..self.playback_shadow_len],
                );
                self.playback_shadow_len = retained;
            } else {
                self.playback_shadow_len = 0;
            }
        }

        @memcpy(
            self.playback_shadow[self.playback_shadow_len .. self.playback_shadow_len + samples.len],
            samples,
        );
        self.playback_shadow_len += samples.len;
    }

    fn reconcilePlaybackShadow(self: *AudioInit, queued_bytes: usize, wav_recorder: ?*WavRecorder) void {
        const queued_samples = queued_bytes / @sizeOf(i16);
        if (queued_samples >= self.playback_shadow_len) return;

        const consumed_samples = self.playback_shadow_len - queued_samples;
        if (wav_recorder) |rec| {
            rec.addSamples(self.playback_shadow[0..consumed_samples]) catch {};
        }
        if (queued_samples != 0) {
            std.mem.copyForwards(
                i16,
                self.playback_shadow[0..queued_samples],
                self.playback_shadow[consumed_samples .. consumed_samples + queued_samples],
            );
        }
        self.playback_shadow_len = queued_samples;
    }

    fn syncRecordedPlayback(self: *AudioInit, wav_recorder: ?*WavRecorder) void {
        const queued_bytes = zsdl3.getAudioStreamQueued(self.stream) catch return;
        self.reconcilePlaybackShadow(@intCast(queued_bytes), wav_recorder);
    }

    fn clearPlaybackShadow(self: *AudioInit) void {
        self.playback_shadow_len = 0;
    }
};

const SdlAudioSpecRaw = extern struct {
    format: zsdl3.AudioFormat,
    channels: c_int,
    freq: c_int,
};

// Re-export gamepad types from input/gamepad.zig
const GamepadSlot = gamepad.GamepadSlot;
const SdlJoystick = gamepad.SdlJoystick;
const JoystickSlot = gamepad.JoystickSlot;
const DirectionState = gamepad.DirectionState;
const TriggerState = gamepad.TriggerState;
const GamepadTransition = gamepad.Transition;
const max_input_transitions = gamepad.max_transitions;
const joystick_hat_up = gamepad.hat_up;
const joystick_hat_right = gamepad.hat_right;
const joystick_hat_down = gamepad.hat_down;
const joystick_hat_left = gamepad.hat_left;

// Re-export SDL joystick externs from gamepad module
const SDL_IsGamepad = gamepad.SDL_IsGamepad;
const SDL_OpenJoystick = gamepad.SDL_OpenJoystick;
const SDL_CloseJoystick = gamepad.SDL_CloseJoystick;

fn frameDurationNs(is_pal: bool, master_cycles_per_frame: u32) u64 {
    const master_clock: u32 = if (is_pal) clock.master_clock_pal else clock.master_clock_ntsc;
    return @intCast((@as(u128, master_cycles_per_frame) * std.time.ns_per_s) / master_clock);
}

fn smsFrameDurationNs(is_pal: bool) u64 {
    const sms_clock = @import("sms/clock.zig");
    const master_clock: u32 = if (is_pal) sms_clock.pal_master_clock else sms_clock.ntsc_master_clock;
    const lines: u32 = if (is_pal) sms_clock.pal_lines_per_frame else sms_clock.ntsc_lines_per_frame;
    const master_cycles: u32 = lines * sms_clock.master_cycles_per_line;
    return @intCast((@as(u128, master_cycles) * std.time.ns_per_s) / master_clock);
}

fn uncappedBootFrames(audio_enabled: bool) u32 {
    return if (audio_enabled) 0 else 240;
}

// Re-export config types and constants from frontend/config.zig
const frontend_config_name = config_module.config_file_name;
const frontend_recent_rom_limit = config_module.recent_rom_limit;
const DialogPathCopy = config_module.PathCopy;
const VideoAspectMode = config_module.VideoAspectMode;
const VideoScaleMode = config_module.VideoScaleMode;
const FrontendConfig = config_module.FrontendConfig;
const defaultFrontendConfigPath = config_module.defaultConfigPath;
const computeVideoDestinationRect = config_module.computeVideoDestinationRect;

// Re-export toast notification types from frontend/toast.zig
const max_dialog_message_bytes = toast_module.max_message_bytes;
const frontend_toast_duration_frames = toast_module.duration_frames;
const DialogMessageCopy = toast_module.MessageCopy;
const FrontendToastStyle = toast_module.Style;
const FrontendToast = toast_module.Toast;
const FrontendNotifications = toast_module.Notifications;
const notifyFrontend = toast_module.notify;

// Re-export file dialog types from frontend/dialog.zig
const FileDialogOutcome = dialog_module.Outcome;
const FileDialogState = dialog_module.State;

// Re-export menu types from frontend/menu.zig
const HomeMenuAction = menu_module.HomeMenuAction;
const HomeMenuState = menu_module.HomeMenuState;
const SettingsMenuAction = menu_module.SettingsMenuAction;
const settings_menu_actions = menu_module.settings_menu_actions;
const SettingsMenuState = menu_module.SettingsMenuState;
const HomeScreenCommand = menu_module.HomeScreenCommand;
const FrontendGamepadCommand = menu_module.FrontendGamepadCommand;
const FrontendEventDisposition = menu_module.EventDisposition;
const FrontendUi = menu_module.FrontendUi;
const Overlay = menu_module.Overlay;
const formatHomeMenuItem = menu_module.formatHomeMenuItem;
const homeMenuActionForIndex = menu_module.homeMenuActionForIndex;
const formatSettingsActionLine = menu_module.formatSettingsActionLine;
const frontendGamepadCommandFromHome = menu_module.gamepadCommandFromHome;
const activateHomeMenuSelection = menu_module.activateHomeMenuSelection;

// Re-export save state types and constants from frontend/saves.zig
const save_state_preview_width = saves_module.preview_width;
const save_state_preview_height = saves_module.preview_height;
const save_state_preview_pixel_count = saves_module.preview_pixel_count;
const SaveStatePreview = saves_module.Preview;
const SaveManagerSlotMetadata = saves_module.SlotMetadata;
const SaveManagerState = saves_module.ManagerState;
const save_manager_slot_count = saves_module.slot_count;
const previousPersistentStateSlot = saves_module.previousSlot;
const resolveStatePreviewPath = saves_module.resolvePreviewPath;
const saveStatePreviewFile = saves_module.savePreviewFile;
const deleteStatePreviewFile = saves_module.deletePreviewFile;
const resolvePersistentStatePath = saves_module.resolvePersistentStatePath;
const formatTimestampRelative = saves_module.formatTimestampRelative;
const formatSaveManagerSlotLine = saves_module.formatSlotLine;
const formatSaveManagerPathLine = saves_module.formatPathLine;

// Re-export performance monitoring types from frontend/performance.zig
const performance_spike_log_threshold_ns = perf_monitor.spike_log_threshold_ns;
const performance_core_sample_period = perf_monitor.core_sample_period;
const performance_core_burst_frames = perf_monitor.core_burst_frames;
const PerformanceFramePhases = perf_monitor.FramePhases;
const PerformanceHudState = perf_monitor.HudState;
const PerformanceSpikeLogState = perf_monitor.SpikeLogState;
const PerformanceSpikeWindowSummary = perf_monitor.SpikeWindowSummary;
const queuedAudioNsFromBytes = perf_monitor.queuedAudioNsFromBytes;
const queueIsBacklogged = perf_monitor.queueIsBacklogged;
const queueIsBackloggedForBudget = perf_monitor.queueIsBackloggedForBudget;
const shouldSampleCoreCounters = perf_monitor.shouldSampleCoreCounters;
const nextCoreBurstFramesRemaining = perf_monitor.nextCoreBurstFramesRemaining;
const isThresholdSlowFrame = perf_monitor.isThresholdSlowFrame;

// Re-export UI types from frontend/ui.zig
const UiColors = ui_render.Colors;
const UiSpacing = ui_render.Spacing;
const UiAnimation = ui_render.Animation;
const OverlayLine = ui_render.OverlayLine;
const renderStatusBar = ui_render.renderStatusBar;

fn persistFrontendConfig(frontend_config: *const FrontendConfig, bindings: *const InputBindings.Bindings, frontend_config_path: []const u8, notifications: FrontendNotifications) void {
    unified_config.save(frontend_config, bindings, frontend_config_path) catch |err| {
        std.debug.print("Failed to save config {s}: {s}\n", .{ frontend_config_path, @errorName(err) });
        notifyFrontend(notifications, .failure, "FAILED TO SAVE CONFIG", .{});
    };
}

fn refreshSaveManager(
    save_manager: *SaveManagerState,
    allocator: std.mem.Allocator,
    machine: *const SystemMachine,
    explicit_state_path: ?[]const u8,
    notifications: FrontendNotifications,
) void {
    if (machine.asGenesisConst()) |gen| {
        save_manager.refresh(allocator, gen, explicit_state_path) catch |err| {
            std.debug.print("Failed to refresh save manager metadata: {s}\n", .{@errorName(err)});
            notifyFrontend(notifications, .failure, "FAILED TO REFRESH SAVE MANAGER", .{});
        };
    } else if (machine.sourcePath()) |source_path| {
        // SMS: refresh using source path for slot resolution
        for (0..save_manager_slot_count) |slot_index| {
            const slot_number: u8 = @intCast(slot_index + 1);
            const path = rom_paths.statePath(allocator, source_path, slot_number) catch continue;
            defer allocator.free(path);
            var metadata = saves_module.SlotMetadata{};
            metadata.path.set(path);
            const file = std.fs.cwd().openFile(path, .{}) catch {
                save_manager.slots[slot_index] = metadata;
                continue;
            };
            defer file.close();
            const stat = file.stat() catch {
                save_manager.slots[slot_index] = metadata;
                continue;
            };
            metadata.exists = true;
            metadata.size_bytes = stat.size;
            metadata.modified_ns = stat.mtime;
            save_manager.slots[slot_index] = metadata;
        }
    }
}

fn openSaveManager(
    ui: *FrontendUi,
    save_manager: *SaveManagerState,
    allocator: std.mem.Allocator,
    machine: *const SystemMachine,
    explicit_state_path: ?[]const u8,
    notifications: FrontendNotifications,
) void {
    ui.overlay = .save_manager;
    refreshSaveManager(save_manager, allocator, machine, explicit_state_path, notifications);
}

fn deletePersistentStateFile(
    allocator: std.mem.Allocator,
    machine: *const SystemMachine,
    explicit_state_path: ?[]const u8,
    persistent_state_slot: u8,
    notifications: FrontendNotifications,
) bool {
    const state_path = resolveStatePathForSystem(allocator, machine, explicit_state_path, persistent_state_slot) orelse {
        notifyFrontend(notifications, .failure, "FAILED TO RESOLVE STATE FILE", .{});
        return true;
    };
    defer allocator.free(state_path);

    std.fs.cwd().deleteFile(state_path) catch |err| switch (err) {
        error.FileNotFound => {
            notifyFrontend(notifications, .info, "STATE SLOT {d} IS EMPTY", .{persistent_state_slot});
            return true;
        },
        else => {
            std.debug.print("Failed to delete state file {s}: {s}\n", .{ state_path, @errorName(err) });
            notifyFrontend(notifications, .failure, "FAILED TO DELETE STATE FILE", .{});
            return true;
        },
    };

    std.debug.print("Deleted state file: {s}\n", .{state_path});
    deleteStatePreviewFile(allocator, state_path) catch |err| {
        std.debug.print("Failed to delete state preview {s}.preview: {s}\n", .{ state_path, @errorName(err) });
    };
    notifyFrontend(notifications, .success, "STATE FILE DELETED", .{});
    return true;
}

fn handlePauseOverlayKey(
    ui: *FrontendUi,
    save_manager: *SaveManagerState,
    settings: *SettingsMenuState,
    allocator: std.mem.Allocator,
    machine: *const SystemMachine,
    explicit_state_path: ?[]const u8,
    scancode: zsdl3.Scancode,
    pressed: bool,
    notifications: FrontendNotifications,
) bool {
    if (ui.overlay != .pause) return false;
    if (!pressed) return false;

    switch (scancode) {
        .@"return" => {
            openSaveManager(ui, save_manager, allocator, machine, explicit_state_path, notifications);
            return true;
        },
        .tab => {
            ui.openSettings(settings);
            return true;
        },
        .i => {
            ui.openGameInfo();
            return true;
        },
        else => return false,
    }
}

fn handleGameInfoKey(
    ui: *FrontendUi,
    scancode: zsdl3.Scancode,
    pressed: bool,
) bool {
    if (ui.overlay != .game_info) return false;
    if (!pressed) return true;

    switch (scancode) {
        .escape, .i => {
            ui.closeGameInfo();
            return true;
        },
        else => return true,
    }
}

fn handleSettingsKey(
    ui: *FrontendUi,
    settings: *SettingsMenuState,
    frontend_config: *FrontendConfig,
    frontend_config_path: []const u8,
    perf: *PerformanceHudState,
    spike_log: *PerformanceSpikeLogState,
    core_profile_frames_remaining: *u32,
    window: *zsdl3.Window,
    audio: ?*AudioInit,
    current_audio_mode: *AudioOutput.RenderMode,
    bindings: *InputBindings.Bindings,
    machine: *SystemMachine,
    ui_font: *ui_render.Font,
    renderer: *zsdl3.Renderer,
    scancode: zsdl3.Scancode,
    pressed: bool,
    notifications: FrontendNotifications,
) bool {
    if (ui.overlay != .settings) return false;
    if (!pressed) return true;

    switch (scancode) {
        .escape, .tab => {
            ui.closeSettings();
            return true;
        },
        .up => {
            settings.move(-1);
            return true;
        },
        .down => {
            settings.move(1);
            return true;
        },
        .left => {
            applySettingsAction(
                ui,
                settings,
                frontend_config,
                frontend_config_path,
                perf,
                spike_log,
                core_profile_frames_remaining,
                window,
                audio,
                current_audio_mode,
                bindings,
                machine,
                ui_font,
                renderer,
                settings.currentAction(),
                -1,
                notifications,
            );
            return true;
        },
        .right => {
            applySettingsAction(
                ui,
                settings,
                frontend_config,
                frontend_config_path,
                perf,
                spike_log,
                core_profile_frames_remaining,
                window,
                audio,
                current_audio_mode,
                bindings,
                machine,
                ui_font,
                renderer,
                settings.currentAction(),
                1,
                notifications,
            );
            return true;
        },
        .@"return", .space => {
            applySettingsAction(
                ui,
                settings,
                frontend_config,
                frontend_config_path,
                perf,
                spike_log,
                core_profile_frames_remaining,
                window,
                audio,
                current_audio_mode,
                bindings,
                machine,
                ui_font,
                renderer,
                settings.currentAction(),
                0,
                notifications,
            );
            return true;
        },
        else => return true,
    }
}

fn handleSaveManagerKey(
    ui: *FrontendUi,
    save_manager: *SaveManagerState,
    allocator: std.mem.Allocator,
    machine: *SystemMachine,
    explicit_state_path: ?[]const u8,
    persistent_state_slot: *u8,
    gif_recorder: *?GifRecorder,
    wav_recorder: *?WavRecorder,
    audio: ?*AudioInit,
    frame_counter: *u32,
    scancode: zsdl3.Scancode,
    hotkey_action: ?InputBindings.HotkeyAction,
    pressed: bool,
    notifications: FrontendNotifications,
) bool {
    if (ui.overlay != .save_manager) return false;
    if (!pressed) return true;

    switch (scancode) {
        .escape => {
            if (ui.delete_confirm_pending) {
                ui.cancelDeleteConfirm();
                notifyFrontend(notifications, .info, "DELETE CANCELLED", .{});
            } else {
                ui.closeSaveManager();
            }
            return true;
        },
        .up => {
            ui.cancelDeleteConfirm(); // Cancel any pending delete on navigation
            persistent_state_slot.* = previousPersistentStateSlot(persistent_state_slot.*);
            return true;
        },
        .down => {
            ui.cancelDeleteConfirm(); // Cancel any pending delete on navigation
            persistent_state_slot.* = StateFile.nextPersistentStateSlot(persistent_state_slot.*);
            return true;
        },
        .@"return" => {
            if (ui.delete_confirm_pending) {
                // Confirm delete
                ui.cancelDeleteConfirm();
                _ = deletePersistentStateFile(allocator, machine, explicit_state_path, persistent_state_slot.*, notifications);
                refreshSaveManager(save_manager, allocator, machine, explicit_state_path, notifications);
            } else {
                _ = handlePersistentStateAction(
                    allocator,
                    .load_state_file,
                    machine,
                    explicit_state_path,
                    persistent_state_slot,
                    audio,
                    gif_recorder,
                    wav_recorder,
                    frame_counter,
                    notifications,
                );
                refreshSaveManager(save_manager, allocator, machine, explicit_state_path, notifications);
            }
            return true;
        },
        .delete, .backspace => {
            if (ui.delete_confirm_pending) {
                // Second press confirms delete
                ui.cancelDeleteConfirm();
                _ = deletePersistentStateFile(allocator, machine, explicit_state_path, persistent_state_slot.*, notifications);
                refreshSaveManager(save_manager, allocator, machine, explicit_state_path, notifications);
            } else {
                // First press asks for confirmation
                const metadata = save_manager.slotMetadata(persistent_state_slot.*);
                if (metadata.exists) {
                    ui.delete_confirm_pending = true;
                    notifyFrontend(notifications, .info, "PRESS DEL AGAIN TO CONFIRM DELETE", .{});
                } else {
                    notifyFrontend(notifications, .info, "SLOT IS ALREADY EMPTY", .{});
                }
            }
            return true;
        },
        else => {},
    }

    if (hotkey_action) |action| {
        switch (action) {
            .save_state_file, .load_state_file, .next_state_slot => {
                _ = handlePersistentStateAction(
                    allocator,
                    action,
                    machine,
                    explicit_state_path,
                    persistent_state_slot,
                    audio,
                    gif_recorder,
                    wav_recorder,
                    frame_counter,
                    notifications,
                );
                refreshSaveManager(save_manager, allocator, machine, explicit_state_path, notifications);
                return true;
            },
            else => {},
        }
    }

    return true;
}

const SdlDialogFileFilter = extern struct {
    name: [*c]const u8,
    pattern: [*c]const u8,
};

const rom_dialog_filters = [_]SdlDialogFileFilter{
    .{ .name = "ROM files", .pattern = "bin;md;smd;gen;sms;gg;zip" },
    .{ .name = "All files", .pattern = "*" },
};

// Re-export CLI types from cli.zig
const CliConfig = cli_module.Config;
const createCliCommand = cli_module.createCommand;

// Re-export ROM metadata types from rom_metadata.zig
const TimingModeOption = cli_module.TimingModeOption;
const ResolvedTimingMode = rom_metadata.ResolvedTimingMode;
const ResolvedConsoleRegion = rom_metadata.ResolvedConsoleRegion;

// Re-export keyboard/hotkey functions from input/keyboard.zig
const keyboardStatePressed = keyboard.keyboardStatePressed;
const hotkeyModifiersFromKeyboardState = keyboard.hotkeyModifiersFromKeyboardState;
const isHotkeyModifierScancode = keyboard.isHotkeyModifierScancode;
const hotkeyBindingFromScancode = keyboard.hotkeyBindingFromScancode;
const hotkeyActionDescription = keyboard.hotkeyActionDescription;
const keyboardInputFromScancode = keyboard.keyboardInputFromScancode;

// Re-export binding editor types from input/binding_editor.zig
const BindingEditorTarget = binding_editor_module.Target;
const BindingEditorStatus = binding_editor_module.Status;
const BindingEditorState = binding_editor_module.State;
const bindingEditorTargetForIndex = binding_editor_module.targetForIndex;
const bindingName = binding_editor_module.bindingName;
const bindingEditorRowText = binding_editor_module.rowText;

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

fn preferredOpenRomLocation(frontend_config: *const FrontendConfig, current_rom_path: *const DialogPathCopy) ?[]const u8 {
    if (frontend_config.last_open_dir.len != 0) return frontend_config.last_open_dir.slice();
    if (current_rom_path.len != 0) {
        return std.fs.path.dirname(current_rom_path.slice()) orelse current_rom_path.slice();
    }
    return null;
}

fn rememberLoadedRom(frontend_config: *FrontendConfig, bindings: *const InputBindings.Bindings, frontend_config_path: []const u8, notifications: FrontendNotifications, rom_path: []const u8) void {
    frontend_config.noteLoadedRom(rom_path);
    persistFrontendConfig(frontend_config, bindings, frontend_config_path, notifications);
}

const SDL_WINDOW_FULLSCREEN: u64 = 0x00000001;

fn fullscreenEnabled(window: *zsdl3.Window) bool {
    return (SDL_GetWindowFlags(window) & SDL_WINDOW_FULLSCREEN) != 0;
}

fn setFullscreenEnabled(window: *zsdl3.Window, enable: bool, notifications: FrontendNotifications) void {
    _ = SDL_SetWindowFullscreen(window, enable);
    if (enable) {
        notifyFrontend(notifications, .info, "FULLSCREEN ON", .{});
    } else {
        notifyFrontend(notifications, .info, "FULLSCREEN OFF", .{});
    }
}

fn fontDataForFace(face: config_module.FontFace) []const u8 {
    return switch (face) {
        .jbm_regular => ui_render.font_jbm_regular,
        .jbm_light => ui_render.font_jbm_light,
        .jbm_medium => ui_render.font_jbm_medium,
        .jbm_thin => ui_render.font_jbm_thin,
    };
}

fn configurePerformanceHud(
    ui: *FrontendUi,
    perf: *PerformanceHudState,
    spike_log: *PerformanceSpikeLogState,
    core_profile_frames_remaining: *u32,
    enabled: bool,
) void {
    if (enabled) {
        ui.overlay = .performance_hud;
    } else if (ui.overlay == .performance_hud) {
        ui.overlay = .none;
    }
    if (!enabled) {
        core_profile_frames_remaining.* = 0;
        return;
    }

    perf.reset();
    spike_log.reset();
    core_profile_frames_remaining.* = 0;
}

fn applyAudioRenderModeSetting(
    audio: ?*AudioInit,
    current_mode: *AudioOutput.RenderMode,
    next_mode: AudioOutput.RenderMode,
    notifications: FrontendNotifications,
) void {
    current_mode.* = next_mode;
    if (audio) |a| {
        a.output.setRenderMode(next_mode);
    }
    notifyFrontend(notifications, .info, "AUDIO MODE {s}", .{next_mode.label()});
}

fn applySettingsAction(
    ui: *FrontendUi,
    settings: *SettingsMenuState,
    frontend_config: *FrontendConfig,
    frontend_config_path: []const u8,
    perf: *PerformanceHudState,
    spike_log: *PerformanceSpikeLogState,
    core_profile_frames_remaining: *u32,
    window: *zsdl3.Window,
    audio: ?*AudioInit,
    current_audio_mode: *AudioOutput.RenderMode,
    bindings: *InputBindings.Bindings,
    machine: *SystemMachine,
    ui_font: *ui_render.Font,
    renderer: *zsdl3.Renderer,
    action: SettingsMenuAction,
    delta: isize,
    notifications: FrontendNotifications,
) void {
    const nextCT = menu_module.nextControllerType;
    const prevCT = menu_module.prevControllerType;
    switch (action) {
        .video_aspect_mode => {
            const next_mode = frontend_config.video_aspect_mode.cycle(if (delta == 0) 1 else delta);
            frontend_config.video_aspect_mode = next_mode;
            persistFrontendConfig(frontend_config, bindings, frontend_config_path, notifications);
            notifyFrontend(notifications, .info, "ASPECT {s}", .{next_mode.label()});
        },
        .video_scale_mode => {
            const next_mode = frontend_config.video_scale_mode.cycle(if (delta == 0) 1 else delta);
            frontend_config.video_scale_mode = next_mode;
            persistFrontendConfig(frontend_config, bindings, frontend_config_path, notifications);
            notifyFrontend(notifications, .info, "SCALING {s}", .{next_mode.label()});
        },
        .fullscreen => {
            if (delta < 0) {
                setFullscreenEnabled(window, false, notifications);
            } else if (delta > 0) {
                setFullscreenEnabled(window, true, notifications);
            } else {
                setFullscreenEnabled(window, !fullscreenEnabled(window), notifications);
            }
        },
        .audio_render_mode => {
            const next_mode = current_audio_mode.cycle(if (delta == 0) 1 else delta);
            frontend_config.audio_render_mode = next_mode;
            persistFrontendConfig(frontend_config, bindings, frontend_config_path, notifications);
            applyAudioRenderModeSetting(audio, current_audio_mode, next_mode, notifications);
        },
        .psg_volume => {
            var vol: i16 = @intCast(frontend_config.psg_volume);
            vol += if (delta == 0) 10 else @as(i16, @intCast(delta)) * 10;
            vol = std.math.clamp(vol, 0, 200);
            frontend_config.psg_volume = @intCast(vol);
            if (audio) |a| {
                a.output.setPsgVolume(frontend_config.psg_volume);
            }
            persistFrontendConfig(frontend_config, bindings, frontend_config_path, notifications);
            notifyFrontend(notifications, .info, "PSG VOLUME {d}%", .{frontend_config.psg_volume});
        },
        .performance_hud => {
            if (delta < 0) {
                configurePerformanceHud(ui, perf, spike_log, core_profile_frames_remaining, false);
            } else if (delta > 0) {
                configurePerformanceHud(ui, perf, spike_log, core_profile_frames_remaining, true);
            } else {
                configurePerformanceHud(ui, perf, spike_log, core_profile_frames_remaining, ui.overlay != .performance_hud);
            }
            if (ui.overlay == .performance_hud) {
                notifyFrontend(notifications, .info, "PERF HUD ON", .{});
            } else {
                notifyFrontend(notifications, .info, "PERF HUD OFF", .{});
            }
        },
        .controller_p1_type => {
            const ct = if (delta >= 0) nextCT(bindings.controller_types[0]) else prevCT(bindings.controller_types[0]);
            bindings.controller_types[0] = ct;
            if (machine.genesisIo()) |io| io.setControllerType(0, ct);
        },
        .controller_p2_type => {
            const ct = if (delta >= 0) nextCT(bindings.controller_types[1]) else prevCT(bindings.controller_types[1]);
            bindings.controller_types[1] = ct;
            if (machine.genesisIo()) |io| io.setControllerType(1, ct);
        },
        .font_face => {
            const next = frontend_config.font_face.cycle(if (delta == 0) 1 else delta);
            frontend_config.font_face = next;
            ui_font.deinit();
            ui_font.* = ui_render.Font.init(fontDataForFace(next));
            ui_render.initFont(ui_font);
            _ = renderer;
            persistFrontendConfig(frontend_config, bindings, frontend_config_path, notifications);
            notifyFrontend(notifications, .info, "FONT {s}", .{next.label()});
        },
        .close => {
            _ = settings;
            ui.closeSettings();
        },
    }
}

fn handleHomeScreenKey(
    ui: *FrontendUi,
    home_menu: *HomeMenuState,
    settings: *SettingsMenuState,
    config: *const FrontendConfig,
    scancode: zsdl3.Scancode,
    pressed: bool,
) HomeScreenCommand {
    if (ui.overlay != .home) return .none;
    if (!pressed) return .none;

    switch (scancode) {
        .up => {
            home_menu.move(-1, config);
            return .none;
        },
        .down => {
            home_menu.move(1, config);
            return .none;
        },
        .@"return" => return activateHomeMenuSelection(ui, home_menu, settings, config),
        else => return .none,
    }
}

fn handleHomeScreenGamepadInput(
    ui: *FrontendUi,
    home_menu: *HomeMenuState,
    settings: *SettingsMenuState,
    config: *const FrontendConfig,
    input: InputBindings.GamepadInput,
    pressed: bool,
) FrontendGamepadCommand {
    if (ui.overlay != .home) return .ignored;

    return switch (input) {
        .dpad_up => blk: {
            if (pressed) home_menu.move(-1, config);
            break :blk .consumed;
        },
        .dpad_down => blk: {
            if (pressed) home_menu.move(1, config);
            break :blk .consumed;
        },
        .south, .start => blk: {
            if (!pressed) break :blk .consumed;
            break :blk frontendGamepadCommandFromHome(activateHomeMenuSelection(ui, home_menu, settings, config));
        },
        .west => blk: {
            if (pressed) ui.openSettings(settings);
            break :blk .consumed;
        },
        .north => blk: {
            if (pressed) ui.overlay = .help;
            break :blk .consumed;
        },
        else => .ignored,
    };
}

fn handleHelpOverlayGamepadInput(
    ui: *FrontendUi,
    input: InputBindings.GamepadInput,
    pressed: bool,
) FrontendGamepadCommand {
    if (ui.overlay != .help) return .ignored;

    return switch (input) {
        .south, .east, .back, .start => blk: {
            if (pressed) ui.closeHelp();
            break :blk .consumed;
        },
        .guide => blk: {
            if (pressed) {
                if (ui.parent_overlay == .home) {
                    ui.closeHelp();
                } else {
                    ui.resumeGame();
                }
            }
            break :blk .consumed;
        },
        else => .ignored,
    };
}

fn handlePauseOverlayGamepadInput(
    ui: *FrontendUi,
    save_manager: *SaveManagerState,
    settings: *SettingsMenuState,
    allocator: std.mem.Allocator,
    machine: *const SystemMachine,
    explicit_state_path: ?[]const u8,
    input: InputBindings.GamepadInput,
    pressed: bool,
    notifications: FrontendNotifications,
) FrontendGamepadCommand {
    if (ui.overlay != .pause) return .ignored;

    return switch (input) {
        .south => blk: {
            if (pressed) openSaveManager(ui, save_manager, allocator, machine, explicit_state_path, notifications);
            break :blk .consumed;
        },
        .west => blk: {
            if (pressed) ui.openSettings(settings);
            break :blk .consumed;
        },
        .north => blk: {
            if (pressed) ui.openHelp();
            break :blk .consumed;
        },
        .east, .back, .start, .guide => blk: {
            if (pressed) ui.resumeGame();
            break :blk .consumed;
        },
        else => .ignored,
    };
}

fn handleSettingsGamepadInput(
    ui: *FrontendUi,
    settings: *SettingsMenuState,
    frontend_config: *FrontendConfig,
    frontend_config_path: []const u8,
    perf: *PerformanceHudState,
    spike_log: *PerformanceSpikeLogState,
    core_profile_frames_remaining: *u32,
    window: *zsdl3.Window,
    audio: ?*AudioInit,
    current_audio_mode: *AudioOutput.RenderMode,
    bindings: *InputBindings.Bindings,
    machine: *SystemMachine,
    ui_font: *ui_render.Font,
    renderer: *zsdl3.Renderer,
    input: InputBindings.GamepadInput,
    pressed: bool,
    notifications: FrontendNotifications,
) FrontendGamepadCommand {
    if (ui.overlay != .settings) return .ignored;

    return switch (input) {
        .dpad_up => blk: {
            if (pressed) settings.move(-1);
            break :blk .consumed;
        },
        .dpad_down => blk: {
            if (pressed) settings.move(1);
            break :blk .consumed;
        },
        .dpad_left, .left_shoulder => blk: {
            if (pressed) applySettingsAction(
                ui,
                settings,
                frontend_config,
                frontend_config_path,
                perf,
                spike_log,
                core_profile_frames_remaining,
                window,
                audio,
                current_audio_mode,
                bindings,
                machine,
                ui_font,
                renderer,
                settings.currentAction(),
                -1,
                notifications,
            );
            break :blk .consumed;
        },
        .dpad_right, .right_shoulder => blk: {
            if (pressed) applySettingsAction(
                ui,
                settings,
                frontend_config,
                frontend_config_path,
                perf,
                spike_log,
                core_profile_frames_remaining,
                window,
                audio,
                current_audio_mode,
                bindings,
                machine,
                ui_font,
                renderer,
                settings.currentAction(),
                1,
                notifications,
            );
            break :blk .consumed;
        },
        .south, .start => blk: {
            if (pressed) applySettingsAction(
                ui,
                settings,
                frontend_config,
                frontend_config_path,
                perf,
                spike_log,
                core_profile_frames_remaining,
                window,
                audio,
                current_audio_mode,
                bindings,
                machine,
                ui_font,
                renderer,
                settings.currentAction(),
                0,
                notifications,
            );
            break :blk .consumed;
        },
        .east, .back => blk: {
            if (pressed) ui.closeSettings();
            break :blk .consumed;
        },
        .guide => blk: {
            if (pressed) {
                if (ui.parent_overlay == .home) {
                    ui.closeSettings();
                } else {
                    ui.resumeGame();
                }
            }
            break :blk .consumed;
        },
        else => .ignored,
    };
}

fn handleSaveManagerGamepadInput(
    ui: *FrontendUi,
    save_manager: *SaveManagerState,
    allocator: std.mem.Allocator,
    machine: *SystemMachine,
    explicit_state_path: ?[]const u8,
    persistent_state_slot: *u8,
    gif_recorder: *?GifRecorder,
    wav_recorder: *?WavRecorder,
    audio: ?*AudioInit,
    frame_counter: *u32,
    input: InputBindings.GamepadInput,
    pressed: bool,
    notifications: FrontendNotifications,
) FrontendGamepadCommand {
    if (ui.overlay != .save_manager) return .ignored;

    return switch (input) {
        .east, .back => blk: {
            if (pressed) {
                if (ui.delete_confirm_pending) {
                    ui.cancelDeleteConfirm();
                    notifyFrontend(notifications, .info, "DELETE CANCELLED", .{});
                } else {
                    ui.closeSaveManager();
                }
            }
            break :blk .consumed;
        },
        .guide => blk: {
            if (pressed) ui.resumeGame();
            break :blk .consumed;
        },
        .dpad_up, .dpad_left, .left_shoulder => blk: {
            if (pressed) {
                ui.cancelDeleteConfirm();
                persistent_state_slot.* = previousPersistentStateSlot(persistent_state_slot.*);
            }
            break :blk .consumed;
        },
        .dpad_down, .dpad_right, .right_shoulder => blk: {
            if (pressed) {
                ui.cancelDeleteConfirm();
                persistent_state_slot.* = StateFile.nextPersistentStateSlot(persistent_state_slot.*);
            }
            break :blk .consumed;
        },
        .south, .start => blk: {
            if (pressed) {
                if (ui.delete_confirm_pending) {
                    // Confirm delete with A button
                    ui.cancelDeleteConfirm();
                    _ = deletePersistentStateFile(allocator, machine, explicit_state_path, persistent_state_slot.*, notifications);
                    refreshSaveManager(save_manager, allocator, machine, explicit_state_path, notifications);
                } else {
                    _ = handlePersistentStateAction(
                        allocator,
                        .load_state_file,
                        machine,
                        explicit_state_path,
                        persistent_state_slot,
                        audio,
                        gif_recorder,
                        wav_recorder,
                        frame_counter,
                        notifications,
                    );
                    refreshSaveManager(save_manager, allocator, machine, explicit_state_path, notifications);
                }
            }
            break :blk .consumed;
        },
        .west => blk: {
            if (pressed) {
                ui.cancelDeleteConfirm();
                _ = handlePersistentStateAction(
                    allocator,
                    .save_state_file,
                    machine,
                    explicit_state_path,
                    persistent_state_slot,
                    audio,
                    gif_recorder,
                    wav_recorder,
                    frame_counter,
                    notifications,
                );
                refreshSaveManager(save_manager, allocator, machine, explicit_state_path, notifications);
            }
            break :blk .consumed;
        },
        .north => blk: {
            if (pressed) {
                if (ui.delete_confirm_pending) {
                    // Second Y press confirms delete
                    ui.cancelDeleteConfirm();
                    _ = deletePersistentStateFile(allocator, machine, explicit_state_path, persistent_state_slot.*, notifications);
                    refreshSaveManager(save_manager, allocator, machine, explicit_state_path, notifications);
                } else {
                    // First Y press asks for confirmation
                    const metadata = save_manager.slotMetadata(persistent_state_slot.*);
                    if (metadata.exists) {
                        ui.delete_confirm_pending = true;
                        notifyFrontend(notifications, .info, "PRESS Y AGAIN TO CONFIRM DELETE", .{});
                    } else {
                        notifyFrontend(notifications, .info, "SLOT IS ALREADY EMPTY", .{});
                    }
                }
            }
            break :blk .consumed;
        },
        else => .ignored,
    };
}

fn handleFrontendGamepadInput(
    ui: *FrontendUi,
    home_menu: *HomeMenuState,
    settings: *SettingsMenuState,
    config: *FrontendConfig,
    frontend_config_path: []const u8,
    save_manager: *SaveManagerState,
    allocator: std.mem.Allocator,
    machine: *SystemMachine,
    explicit_state_path: ?[]const u8,
    persistent_state_slot: *u8,
    gif_recorder: *?GifRecorder,
    wav_recorder: *?WavRecorder,
    audio: ?*AudioInit,
    current_audio_mode: *AudioOutput.RenderMode,
    perf: *PerformanceHudState,
    spike_log: *PerformanceSpikeLogState,
    core_profile_frames_remaining: *u32,
    window: *zsdl3.Window,
    frame_counter: *u32,
    debugger: *debugger_mod.DebuggerState,
    bindings: *InputBindings.Bindings,
    ui_font: *ui_render.Font,
    renderer: *zsdl3.Renderer,
    input: InputBindings.GamepadInput,
    pressed: bool,
    notifications: FrontendNotifications,
) FrontendGamepadCommand {
    // Debugger gamepad handling (checked first when debugger is active)
    if (ui.overlay == .debugger) {
        if (pressed) {
            switch (input) {
                .east, .back => {
                    debugger.toggle();
                    if (!debugger.active) ui.overlay = .none;
                },
                .south => debugger.stepOnce(),
                .dpad_left, .left_shoulder => debugger.prevTab(),
                .dpad_right, .right_shoulder => debugger.nextTab(),
                .dpad_up => debugger.adjustMemoryAddress(-256),
                .dpad_down => debugger.adjustMemoryAddress(256),
                else => {},
            }
        }
        return .consumed;
    }

    const settings_result = handleSettingsGamepadInput(
        ui,
        settings,
        config,
        frontend_config_path,
        perf,
        spike_log,
        core_profile_frames_remaining,
        window,
        audio,
        current_audio_mode,
        bindings,
        machine,
        ui_font,
        renderer,
        input,
        pressed,
        notifications,
    );
    if (settings_result != .ignored) return settings_result;

    const save_result = handleSaveManagerGamepadInput(
        ui,
        save_manager,
        allocator,
        machine,
        explicit_state_path,
        persistent_state_slot,
        gif_recorder,
        wav_recorder,
        audio,
        frame_counter,
        input,
        pressed,
        notifications,
    );
    if (save_result != .ignored) return save_result;

    const help_result = handleHelpOverlayGamepadInput(ui, input, pressed);
    if (help_result != .ignored) return help_result;

    const home_result = handleHomeScreenGamepadInput(ui, home_menu, settings, config, input, pressed);
    if (home_result != .ignored) return home_result;

    const pause_result = handlePauseOverlayGamepadInput(
        ui,
        save_manager,
        settings,
        allocator,
        machine,
        explicit_state_path,
        input,
        pressed,
        notifications,
    );
    if (pause_result != .ignored) return pause_result;

    if (input == .guide and ui.overlay != .home and ui.overlay != .dialog and ui.overlay != .keyboard_editor) {
        if (pressed) {
            if (ui.overlay.pausesEmulation()) {
                ui.resumeGame();
            } else {
                ui.overlay = .pause;
            }
        }
        return .consumed;
    }

    return .ignored;
}

fn launchOpenRomDialog(dialog_state: *FileDialogState, ui: *FrontendUi, window: *zsdl3.Window, default_location: ?[]const u8) bool {
    if (!dialog_state.begin(default_location)) return false;
    ui.parent_overlay = ui.overlay;
    ui.overlay = .dialog;
    SDL_ShowOpenFileDialog(
        openRomDialogCallback,
        dialog_state,
        window,
        &rom_dialog_filters,
        @intCast(rom_dialog_filters.len),
        dialog_state.defaultLocation(),
        false,
    );
    return true;
}

fn dispatchHomeScreenCommand(
    command: HomeScreenCommand,
    allocator: std.mem.Allocator,
    machine: *SystemMachine,
    input_bindings: *InputBindings.Bindings,
    timing_mode: TimingModeOption,
    audio: ?*AudioInit,
    gif_recorder: *?GifRecorder,
    wav_recorder: *?WavRecorder,
    frame_counter: *u32,
    frontend_config: *FrontendConfig,
    frontend_config_path: []const u8,
    home_menu: *HomeMenuState,
    current_rom_path: *DialogPathCopy,
    ui: *FrontendUi,
    dialog_state: *FileDialogState,
    window: *zsdl3.Window,
    toast: *FrontendToast,
    frontend_frame_counter: u64,
) FrontendEventDisposition {
    switch (command) {
        .none => return .unhandled,
        .open_dialog => {
            _ = launchOpenRomDialog(
                dialog_state,
                ui,
                window,
                preferredOpenRomLocation(frontend_config, current_rom_path),
            );
            return .handled;
        },
        .load_recent => |index| {
            const notifications = FrontendNotifications{
                .toast = toast,
                .frame_number = frontend_frame_counter,
            };
            var selected_path = DialogPathCopy{};
            selected_path.set(frontend_config.recentRom(index));
            loadRomIntoMachine(
                allocator,
                machine,
                input_bindings,
                timing_mode,
                audio,
                gif_recorder,
                wav_recorder,
                frame_counter,
                selected_path.slice(),
                notifications,
            ) catch |err| {
                std.debug.print("Failed to load recent ROM {s}: {}\n", .{ selected_path.slice(), err });
                notifyFrontend(notifications, .failure, "FAILED TO LOAD {s}", .{std.fs.path.basename(selected_path.slice())});
                if (err == error.FileNotFound) {
                    frontend_config.removeRecentRom(index);
                    persistFrontendConfig(frontend_config, input_bindings, frontend_config_path, notifications);
                    home_menu.clamp(frontend_config);
                }
                return .handled;
            };
            current_rom_path.* = selected_path;
            rememberLoadedRom(frontend_config, input_bindings, frontend_config_path, notifications, selected_path.slice());
            home_menu.clamp(frontend_config);
            ui.overlay = .none;
            return .handled;
        },
        .quit => return .quit,
    }
}

fn dispatchFrontendGamepadCommand(
    command: FrontendGamepadCommand,
    allocator: std.mem.Allocator,
    machine: *SystemMachine,
    input_bindings: *InputBindings.Bindings,
    timing_mode: TimingModeOption,
    audio: ?*AudioInit,
    gif_recorder: *?GifRecorder,
    wav_recorder: *?WavRecorder,
    frame_counter: *u32,
    frontend_config: *FrontendConfig,
    frontend_config_path: []const u8,
    home_menu: *HomeMenuState,
    current_rom_path: *DialogPathCopy,
    ui: *FrontendUi,
    dialog_state: *FileDialogState,
    window: *zsdl3.Window,
    toast: *FrontendToast,
    frontend_frame_counter: u64,
) FrontendEventDisposition {
    return switch (command) {
        .ignored => .unhandled,
        .consumed => .handled,
        .open_dialog => dispatchHomeScreenCommand(
            .open_dialog,
            allocator,
            machine,
            input_bindings,
            timing_mode,
            audio,
            gif_recorder,
            wav_recorder,
            frame_counter,
            frontend_config,
            frontend_config_path,
            home_menu,
            current_rom_path,
            ui,
            dialog_state,
            window,
            toast,
            frontend_frame_counter,
        ),
        .load_recent => |index| dispatchHomeScreenCommand(
            .{ .load_recent = index },
            allocator,
            machine,
            input_bindings,
            timing_mode,
            audio,
            gif_recorder,
            wav_recorder,
            frame_counter,
            frontend_config,
            frontend_config_path,
            home_menu,
            current_rom_path,
            ui,
            dialog_state,
            window,
            toast,
            frontend_frame_counter,
        ),
        .quit => .quit,
    };
}

fn resetAudioOutput(audio: *AudioInit, wav_recorder: ?*WavRecorder) void {
    audio.syncRecordedPlayback(wav_recorder);
    zsdl3.clearAudioStream(audio.stream) catch |err| {
        std.debug.print("Failed to clear queued audio on ROM load: {}\n", .{err});
    };
    audio.clearPlaybackShadow();
    audio.output.reset();
    audio.resetTelemetry();
    audio.armStartupMute();
}

fn stopGifRecording(gif_recorder: *?GifRecorder, reason: []const u8) void {
    if (gif_recorder.*) |*rec| {
        const frames = rec.frame_count;
        rec.finish();
        gif_recorder.* = null;
        std.debug.print("{s} ({d} frames)\n", .{ reason, frames });
    }
}

fn stopWavRecording(audio: ?*AudioInit, wav_recorder: *?WavRecorder, reason: []const u8) void {
    if (wav_recorder.*) |*rec| {
        if (audio) |a| {
            a.syncRecordedPlayback(rec);
        }
        const duration = rec.getDurationSeconds();
        const samples = rec.sample_count;
        rec.finish();
        wav_recorder.* = null;
        std.debug.print("{s} ({d} samples, {d:.2}s)\n", .{ reason, samples, duration });
    }
}

fn loadRomIntoMachine(
    allocator: std.mem.Allocator,
    machine: *SystemMachine,
    input_bindings: *const InputBindings.Bindings,
    timing_mode: TimingModeOption,
    audio: ?*AudioInit,
    gif_recorder: *?GifRecorder,
    wav_recorder: *?WavRecorder,
    frame_counter: *u32,
    rom_path: []const u8,
    notifications: FrontendNotifications,
) !void {
    var next_machine = try SystemMachine.init(allocator, rom_path);
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
    stopWavRecording(audio, wav_recorder, "WAV recording stopped for ROM switch");
    if (audio) |a| {
        resetAudioOutput(a, null);
    }

    machine.flushPersistentStorage() catch |err| {
        std.debug.print("Failed to flush persistent SRAM before ROM load: {s}\n", .{@errorName(err)});
    };

    var old_machine = machine.*;
    machine.* = next_machine;
    machine.rebindRuntimePointers();
    old_machine.deinit(allocator);
    frame_counter.* = 0;
    notifyFrontend(notifications, .success, "LOADED {s}", .{std.fs.path.basename(rom_path)});
}

fn softResetCurrentMachine(machine: *SystemMachine, frame_counter: *u32, notifications: FrontendNotifications) void {
    machine.softReset();
    frame_counter.* = 0;
    std.debug.print("CPU Soft Reset complete.\n", .{});
    machine.debugDump();
    notifyFrontend(notifications, .info, "SOFT RESET COMPLETE", .{});
}

fn hardResetCurrentMachine(
    allocator: std.mem.Allocator,
    machine: *SystemMachine,
    input_bindings: *const InputBindings.Bindings,
    timing_mode: TimingModeOption,
    audio: ?*AudioInit,
    gif_recorder: *?GifRecorder,
    wav_recorder: *?WavRecorder,
    frame_counter: *u32,
    rom_path: ?[]const u8,
    notifications: FrontendNotifications,
) !void {
    if (rom_path) |path| {
        try loadRomIntoMachine(
            allocator,
            machine,
            input_bindings,
            timing_mode,
            audio,
            gif_recorder,
            wav_recorder,
            frame_counter,
            path,
            notifications,
        );
        return;
    }

    stopGifRecording(gif_recorder, "GIF recording stopped for hard reset");
    stopWavRecording(audio, wav_recorder, "WAV recording stopped for hard reset");
    if (audio) |a| {
        resetAudioOutput(a, null);
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
    notifyFrontend(notifications, .info, "HARD RESET COMPLETE", .{});
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

// Re-export ROM metadata functions from rom_metadata.zig
const inferPalModeFromCountryCodes = rom_metadata.inferPalModeFromCountryCodes;
const inferConsoleIsOverseasFromCountryCodes = rom_metadata.inferConsoleIsOverseasFromCountryCodes;
const resolveTimingMode = rom_metadata.resolveTimingMode;
const resolveConsoleRegion = rom_metadata.resolveConsoleRegion;
fn logLoadedRomMetadata(machine: anytype, rom_path: []const u8) void {
    const metadata = machine.romMetadata();
    std.debug.print("Loading ROM: {s}\n", .{rom_path});
    if (metadata.console) |console| {
        std.debug.print("Console: {s}\n", .{console});
    }
    if (metadata.title) |title| {
        std.debug.print("Title:   {s}\n", .{title});
    }
    if (metadata.product_code) |code| {
        std.debug.print("Product: {s}\n", .{code});
    }
    std.debug.print("Reset Vectors: SSP={X:0>8} PC={X:0>8}\n", .{ metadata.reset_stack_pointer, metadata.reset_program_counter });
    std.debug.print("Checksum: header={X:0>4} computed={X:0>4} ({s})\n", .{
        metadata.header_checksum, metadata.computed_checksum, if (metadata.checksum_valid) "OK" else "MISMATCH",
    });
}

const SmsInput = @import("sms/input.zig").SmsInput;

fn applySmsKeyboardInput(machine: *SystemMachine, input: InputBindings.KeyboardInput, pressed: bool) void {
    // Default SMS keyboard layout:
    // Arrows = D-Pad, A/S = Button1/Button2, Enter = Pause (NMI)
    const mapping = smsKeyboardMapping(input);
    if (mapping.button) |btn| {
        machine.setSmsButton(mapping.port, btn, pressed);
    } else if (mapping.pause and pressed) {
        machine.setSmsStartOrPause(true);
    }
}

const SmsKeyMapping = struct {
    port: u1 = 0,
    button: ?SmsInput.Button = null,
    pause: bool = false,
};

fn applySmsGamepadInput(machine: *SystemMachine, port: u1, input: InputBindings.GamepadInput, pressed: bool) void {
    const btn: ?SmsInput.Button = switch (input) {
        .dpad_up => .up,
        .dpad_down => .down,
        .dpad_left => .left,
        .dpad_right => .right,
        .south, .west => .button1,
        .east, .north => .button2,
        .start => {
            machine.setSmsStartOrPause(pressed);
            return;
        },
        else => null,
    };
    if (btn) |b| machine.setSmsButton(port, b, pressed);
}

fn smsKeyboardMapping(input: InputBindings.KeyboardInput) SmsKeyMapping {
    return switch (input) {
        .up => .{ .button = .up },
        .down => .{ .button = .down },
        .left => .{ .button = .left },
        .right => .{ .button = .right },
        .a, .s => .{ .button = .button1 },
        .d => .{ .button = .button2 },
        .@"return" => .{ .pause = true },
        // Player 2: I/J/K/L = D-Pad, N/M = buttons
        .i => .{ .port = 1, .button = .up },
        .k => .{ .port = 1, .button = .down },
        .j => .{ .port = 1, .button = .left },
        .l => .{ .port = 1, .button = .right },
        .n => .{ .port = 1, .button = .button1 },
        .m => .{ .port = 1, .button = .button2 },
        else => .{},
    };
}

fn handleBindingEditorKey(
    ui: *FrontendUi,
    editor: *BindingEditorState,
    bindings: *InputBindings.Bindings,
    machine: *SystemMachine,
    unified_cfg_path: []const u8,
    frontend_cfg: *const FrontendConfig,
    scancode: zsdl3.Scancode,
    hotkey_binding: ?InputBindings.HotkeyBinding,
    pressed: bool,
) bool {
    if (ui.overlay != .keyboard_editor) {
        if (!pressed) return false;
        const binding = hotkey_binding orelse return false;
        if (bindings.hotkeyForBinding(binding) != .open_keyboard_editor) return false;
        ui.overlay = .keyboard_editor;
        editor.open();
        if (machine.asGenesis()) |gen| gen.releaseKeyboardBindings(bindings);
        return true;
    }

    if (!pressed) return true;

    if (editor.capture_mode) {
        switch (scancode) {
            .escape => editor.cancelCapture(),
            .delete => editor.clearSelected(bindings),
            else => {
                if (editor.capture_gamepad) {
                    // In gamepad capture mode, keyboard events cancel or clear
                    editor.setStatus(.neutral, "PRESS A GAMEPAD BUTTON");
                } else if (editor.currentTarget().isHeader()) {
                    // Skip
                } else if (switch (editor.currentTarget()) {
                    .hotkey => true,
                    else => false,
                } and isHotkeyModifierScancode(scancode)) {
                    editor.setStatus(.failed, "PRESS A NON-MODIFIER KEY");
                } else if (keyboardInputFromScancode(scancode)) |input| {
                    switch (editor.currentTarget()) {
                        .keyboard_action => editor.assign(bindings, input),
                        .hotkey => editor.assignHotkey(bindings, hotkey_binding orelse .{ .input = input }),
                        .gamepad_action => editor.setStatus(.failed, "USE GAMEPAD BUTTON"),
                        .section_header => {},
                    }
                } else {
                    editor.setStatus(.failed, "KEY NOT SUPPORTED");
                }
            },
        }
        return true;
    }

    if (scancode == .escape) {
        ui.overlay = .none;
        editor.close();
        unified_config.save(frontend_cfg, bindings, unified_cfg_path) catch {};
        return true;
    }
    if (hotkey_binding) |binding| {
        if (bindings.hotkeyForBinding(binding) == .open_keyboard_editor) {
            ui.overlay = .none;
            editor.close();
            unified_config.save(frontend_cfg, bindings, unified_cfg_path) catch {};
            return true;
        }
    }

    switch (scancode) {
        .up => editor.move(-1),
        .down => editor.move(1),
        .@"return" => editor.beginCapture(),
        .f5 => {
            unified_config.save(frontend_cfg, bindings, unified_cfg_path) catch |err| {
                std.debug.print("Failed to save config {s}: {s}\n", .{ unified_cfg_path, @errorName(err) });
                editor.setStatus(.failed, "FAILED TO SAVE CONFIG");
                return true;
            };
            std.debug.print("Saved config: {s}\n", .{unified_cfg_path});
            editor.setStatus(.success, "CONFIG SAVED");
        },
        else => {},
    }
    return true;
}

fn handleQuickStateAction(
    allocator: std.mem.Allocator,
    action: InputBindings.HotkeyAction,
    machine: *SystemMachine,
    quick_state: *?SystemMachine.Snapshot,
    audio: ?*AudioInit,
    gif_recorder: *?GifRecorder,
    wav_recorder: *?WavRecorder,
    frame_counter: *u32,
    notifications: FrontendNotifications,
) bool {
    switch (action) {
        .save_quick_state => {
            const snapshot = machine.captureSnapshot(allocator) catch |err| {
                std.debug.print("Failed to save quick state: {}\n", .{err});
                notifyFrontend(notifications, .failure, "FAILED TO SAVE QUICK STATE", .{});
                return true;
            };
            if (quick_state.*) |*saved| {
                saved.deinit(allocator);
            }
            quick_state.* = snapshot;
            std.debug.print("Quick state saved.\n", .{});
            notifyFrontend(notifications, .success, "QUICK STATE SAVED", .{});
            return true;
        },
        .load_quick_state => {
            if (quick_state.*) |*saved| {
                machine.restoreSnapshot(allocator, saved) catch |err| {
                    std.debug.print("Failed to load quick state: {}\n", .{err});
                    notifyFrontend(notifications, .failure, "FAILED TO LOAD QUICK STATE", .{});
                    return true;
                };
                stopGifRecording(gif_recorder, "GIF recording stopped for state load");
                stopWavRecording(audio, wav_recorder, "WAV recording stopped for state load");
                if (audio) |a| {
                    resetAudioOutput(a, null);
                    if (machine.audioZ80()) |z80| a.output.syncYmStateFromZ80(z80);
                }
                frame_counter.* = 0;
                std.debug.print("Quick state loaded.\n", .{});
                notifyFrontend(notifications, .success, "QUICK STATE LOADED", .{});
            } else {
                std.debug.print("No quick state saved.\n", .{});
                notifyFrontend(notifications, .info, "NO QUICK STATE SAVED", .{});
            }
            return true;
        },
        else => return false,
    }
}

const PersistentStateActionResult = enum {
    ignored,
    handled,
    loaded_machine,
};

fn syncFrontendAfterPersistentStateLoad(
    ui: *FrontendUi,
    current_rom_path: *DialogPathCopy,
    machine: *const SystemMachine,
) void {
    if (machine.sourcePath()) |source_path| {
        current_rom_path.set(source_path);
    } else {
        current_rom_path.* = .{};
    }
    if (ui.overlay == .home) ui.overlay = .none;
}

fn handlePersistentStateAction(
    allocator: std.mem.Allocator,
    action: InputBindings.HotkeyAction,
    machine: *SystemMachine,
    explicit_state_path: ?[]const u8,
    persistent_state_slot: *u8,
    audio: ?*AudioInit,
    gif_recorder: *?GifRecorder,
    wav_recorder: *?WavRecorder,
    frame_counter: *u32,
    notifications: FrontendNotifications,
) PersistentStateActionResult {
    persistent_state_slot.* = StateFile.normalizePersistentStateSlot(persistent_state_slot.*);
    if (action == .next_state_slot) {
        persistent_state_slot.* = StateFile.nextPersistentStateSlot(persistent_state_slot.*);

        // Resolve path using source path from either system
        const state_path = resolveStatePathForSystem(allocator, machine, explicit_state_path, persistent_state_slot.*) orelse {
            notifyFrontend(notifications, .failure, "FAILED TO RESOLVE STATE SLOT", .{});
            return .handled;
        };
        defer allocator.free(state_path);

        std.debug.print("Persistent state slot {d}/{d}: {s}\n", .{
            persistent_state_slot.*,
            StateFile.persistent_state_slot_count,
            state_path,
        });
        notifyFrontend(notifications, .info, "STATE SLOT {d}/{d}", .{
            persistent_state_slot.*,
            StateFile.persistent_state_slot_count,
        });
        return .handled;
    }

    const state_path = resolveStatePathForSystem(allocator, machine, explicit_state_path, persistent_state_slot.*) orelse {
        notifyFrontend(notifications, .failure, "FAILED TO RESOLVE STATE FILE", .{});
        return .handled;
    };
    defer allocator.free(state_path);

    switch (action) {
        .save_state_file => {
            switch (machine.*) {
                .genesis => |*gen| {
                    StateFile.saveToFile(gen, state_path) catch |err| {
                        std.debug.print("Failed to save state file {s}: {s}\n", .{ state_path, @errorName(err) });
                        notifyFrontend(notifications, .failure, "FAILED TO SAVE STATE FILE", .{});
                        return .handled;
                    };
                    saveStatePreviewFile(allocator, gen, state_path) catch |err| {
                        std.debug.print("Failed to save state preview for {s}: {s}\n", .{ state_path, @errorName(err) });
                    };
                },
                .sms => |*sms| {
                    saveSmsStateFile(allocator, sms, state_path) catch |err| {
                        std.debug.print("Failed to save SMS state file {s}: {s}\n", .{ state_path, @errorName(err) });
                        notifyFrontend(notifications, .failure, "FAILED TO SAVE STATE FILE", .{});
                        return .handled;
                    };
                },
            }
            std.debug.print("Saved state file: {s}\n", .{state_path});
            notifyFrontend(notifications, .success, "STATE FILE SAVED", .{});
            return .handled;
        },
        .load_state_file => {
            switch (machine.*) {
                .genesis => {
                    var next_machine = StateFile.loadFromFile(allocator, state_path) catch |err| {
                        if (err == error.FileNotFound) {
                            notifyFrontend(notifications, .info, "NO STATE FILE IN SLOT", .{});
                        } else {
                            std.debug.print("Failed to load state file {s}: {s}\n", .{ state_path, @errorName(err) });
                            notifyFrontend(notifications, .failure, "FAILED TO LOAD STATE FILE", .{});
                        }
                        return .handled;
                    };
                    errdefer next_machine.deinit(allocator);

                    stopGifRecording(gif_recorder, "GIF recording stopped for state-file load");
                    stopWavRecording(audio, wav_recorder, "WAV recording stopped for state-file load");
                    if (audio) |a| resetAudioOutput(a, null);

                    var old_machine = machine.*;
                    machine.* = .{ .genesis = next_machine };
                    machine.rebindRuntimePointers();
                    old_machine.deinit(allocator);

                    if (audio) |a| {
                        if (machine.audioZ80()) |z80| a.output.syncYmStateFromZ80(z80);
                    }
                },
                .sms => |*sms| {
                    loadSmsStateFile(allocator, sms, state_path) catch |err| {
                        if (err == error.FileNotFound) {
                            notifyFrontend(notifications, .info, "NO STATE FILE IN SLOT", .{});
                        } else {
                            std.debug.print("Failed to load SMS state file {s}: {s}\n", .{ state_path, @errorName(err) });
                            notifyFrontend(notifications, .failure, "FAILED TO LOAD STATE FILE", .{});
                        }
                        return .handled;
                    };
                    stopGifRecording(gif_recorder, "GIF recording stopped for state-file load");
                    stopWavRecording(audio, wav_recorder, "WAV recording stopped for state-file load");
                    if (audio) |a| resetAudioOutput(a, null);
                },
            }
            frame_counter.* = 0;
            std.debug.print("Loaded state file: {s}\n", .{state_path});
            notifyFrontend(notifications, .success, "STATE FILE LOADED", .{});
            return .loaded_machine;
        },
        else => return .ignored,
    }
}

/// Resolve the persistent state file path for either Genesis or SMS.
fn resolveStatePathForSystem(
    allocator: std.mem.Allocator,
    machine: *const SystemMachine,
    explicit_state_path: ?[]const u8,
    slot: u8,
) ?[]u8 {
    const normalized = StateFile.normalizePersistentStateSlot(slot);
    if (explicit_state_path) |path| {
        return rom_paths.statePath(allocator, path, normalized) catch null;
    }
    // Use source path from either system
    if (machine.sourcePath()) |source_path| {
        return rom_paths.statePath(allocator, source_path, normalized) catch null;
    }
    // Genesis fallback: use Machine-specific path derivation
    if (machine.asGenesisConst()) |gen| {
        return StateFile.pathForMachineSlot(allocator, gen, normalized) catch null;
    }
    return null;
}

const sms_state_file = @import("sms/state_file.zig");

fn saveSmsStateFile(allocator: std.mem.Allocator, sms: *const SmsMachine, path: []const u8) !void {
    const data = try sms_state_file.saveToBuffer(allocator, sms);
    defer allocator.free(data);
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(data);
}

fn loadSmsStateFile(allocator: std.mem.Allocator, sms: *SmsMachine, path: []const u8) !void {
    const file_data = try std.fs.cwd().readFileAlloc(allocator, path, 16 * 1024 * 1024);
    defer allocator.free(file_data);

    var new_machine = try sms_state_file.loadFromBuffer(allocator, file_data);
    errdefer new_machine.deinit(allocator);

    // Copy source path from current machine
    if (sms.bus.sourcePath()) |sp| {
        try new_machine.bus.setSourcePath(allocator, sp);
    }

    // Swap in the new machine
    var old = sms.*;
    sms.* = new_machine;
    sms.bindPointers();
    old.deinit(allocator);
}

// Re-export gamepad input functions from input/gamepad.zig
const gamepadInputFromButton = gamepad.inputFromGamepadButton;
const joystickInputFromButton = gamepad.inputFromJoystickButton;
const updateAxisPair = gamepad.updateAxisPair;
const updateLeftStickState = gamepad.updateLeftStickState;
const updateTriggerState = gamepad.updateTriggerState;
const updateGamepadAxisState = gamepad.updateGamepadAxisState;
const updateJoystickAxisState = gamepad.updateJoystickAxisState;
const updateHatState = gamepad.updateHatState;
const applyInputTransitions = gamepad.applyTransitions;
const applyReleaseTransitionsOnly = gamepad.applyReleaseTransitionsOnly;

fn handleFrontendGamepadTransitions(
    ui: *FrontendUi,
    home_menu: *HomeMenuState,
    settings: *SettingsMenuState,
    config: *FrontendConfig,
    frontend_config_path: []const u8,
    save_manager: *SaveManagerState,
    allocator: std.mem.Allocator,
    machine: *SystemMachine,
    explicit_state_path: ?[]const u8,
    persistent_state_slot: *u8,
    gif_recorder: *?GifRecorder,
    wav_recorder: *?WavRecorder,
    audio: ?*AudioInit,
    current_audio_mode: *AudioOutput.RenderMode,
    perf: *PerformanceHudState,
    spike_log: *PerformanceSpikeLogState,
    core_profile_frames_remaining: *u32,
    window: *zsdl3.Window,
    frame_counter: *u32,
    debugger: *debugger_mod.DebuggerState,
    bindings: *InputBindings.Bindings,
    ui_font: *ui_render.Font,
    renderer: *zsdl3.Renderer,
    notifications: FrontendNotifications,
    transitions: anytype,
) FrontendGamepadCommand {
    for (transitions) |maybe_transition| {
        if (maybe_transition) |transition| {
            const result = handleFrontendGamepadInput(
                ui,
                home_menu,
                settings,
                config,
                frontend_config_path,
                save_manager,
                allocator,
                machine,
                explicit_state_path,
                persistent_state_slot,
                gif_recorder,
                wav_recorder,
                audio,
                current_audio_mode,
                perf,
                spike_log,
                core_profile_frames_remaining,
                window,
                frame_counter,
                debugger,
                bindings,
                ui_font,
                renderer,
                transition.input,
                transition.pressed,
                notifications,
            );
            switch (result) {
                .ignored => {},
                else => return result,
            }
        }
    }
    return .ignored;
}

// Re-export gamepad slot functions from input/gamepad.zig
const findGamepadPort = gamepad.findGamepadPort;
const findJoystickPort = gamepad.findJoystickPort;
const portOccupied = gamepad.portOccupied;
const assignGamepadSlot = gamepad.assignGamepadSlot;
const removeGamepadSlot = gamepad.removeGamepadSlot;
const assignJoystickSlot = gamepad.assignJoystickSlot;
const removeJoystickSlot = gamepad.removeJoystickSlot;

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
                const format_name: []const u8 = switch (format) {
                    .S16LE => "S16LE",
                    .S16BE => "S16BE",
                    .F32LE => "F32LE",
                    .F32BE => "F32BE",
                    else => "unknown",
                };
                std.debug.print("Audio enabled: {s} {d}Hz\n", .{ format_name, freq });
                return .{
                    .stream = stream,
                    .output = AudioOutput.init(),
                };
            }
        }
    }

    return null;
}

// Re-export UI rendering functions from frontend/ui.zig
const overlayScale = ui_render.overlayScale;
const overlayTextWidth = ui_render.textWidth;
const drawOverlayText = ui_render.drawText;
const renderOverlayPanel = ui_render.renderPanel;

// Re-export performance formatting functions from frontend/performance.zig
const formatDurationMsTenths = perf_monitor.formatDurationMsTenths;
const formatRateHzTenths = perf_monitor.formatRateHzTenths;
const formatPercentTenths = perf_monitor.formatPercentTenths;
const formatPerformanceSpikeLine = perf_monitor.formatSpikeLine;
const formatPerformanceSpikeWindowLine = perf_monitor.formatSpikeWindowLine;

// Re-export pause/help overlay rendering from frontend/ui.zig
const renderPauseOverlay = ui_render.renderPauseOverlay;
const renderHelpOverlay = ui_render.renderHelpOverlay;
const renderDialogOverlay = ui_render.renderDialogOverlay;
const renderToastOverlay = ui_render.renderToastOverlay;
const renderHomeOverlay = ui_render.renderHomeOverlay;
const renderKeyboardEditorOverlay = ui_render.renderKeyboardEditorOverlay;
const formatOverlayLine = ui_render.formatOverlayLine;

fn renderSaveManagerPreview(
    renderer: *zsdl3.Renderer,
    frame: zsdl3.FRect,
    metadata: *const SaveManagerSlotMetadata,
    scale: f32,
) !void {
    try renderOverlayPanel(
        renderer,
        frame,
        .{ .r = 0x08, .g = 0x0E, .b = 0x13, .a = 0xF0 },
        UiColors.blue,
        scale,
    );

    const preview_rect = zsdl3.FRect{
        .x = frame.x + 3.0 * scale,
        .y = frame.y + 3.0 * scale,
        .w = frame.w - 6.0 * scale,
        .h = frame.h - 6.0 * scale,
    };

    if (metadata.preview.available) {
        const preview_texture = try zsdl3.createTexture(
            renderer,
            zsdl3.PixelFormatEnum.argb8888,
            zsdl3.TextureAccess.streaming,
            @intCast(save_state_preview_width),
            @intCast(save_state_preview_height),
        );
        defer preview_texture.destroy();

        _ = SDL_UpdateTexture(
            preview_texture,
            null,
            @ptrCast(metadata.preview.pixels[0..].ptr),
            @intCast(save_state_preview_width * @sizeOf(u32)),
        );
        try zsdl3.renderTexture(renderer, preview_texture, null, &preview_rect);
        return;
    }

    const lines = if (metadata.exists)
        [_][]const u8{
            "NO PREVIEW",
            "SAVE AGAIN TO",
            "CAPTURE SCREEN",
        }
    else
        [_][]const u8{
            "EMPTY SLOT",
            "SAVE HERE TO",
            "ADD PREVIEW",
        };
    const line_height = 9.0 * scale;
    var y = frame.y + (frame.h - line_height * @as(f32, @floatFromInt(lines.len))) * 0.5;
    for (lines) |line| {
        try drawOverlayText(
            renderer,
            frame.x + (frame.w - overlayTextWidth(line, scale)) * 0.5,
            y,
            scale,
            UiColors.text_muted,
            line,
        );
        y += line_height;
    }
}

fn renderSaveManagerOverlay(
    renderer: *zsdl3.Renderer,
    viewport: zsdl3.Rect,
    save_manager: *const SaveManagerState,
    persistent_state_slot: u8,
    frame_number: u64,
) !void {
    const title = "SAVE MANAGER";
    const controls_a = "(DPAD) OR (LB) (RB) SLOT  (A) LOAD  (X) SAVE";
    const controls_b = "(B) CLOSE  (Y) DELETE  [F8] [F9] [DEL] ALSO WORK";
    const scale = overlayScale(viewport);
    const padding = 12.0 * scale;
    const summary_height = 9.0 * scale;
    const path_height = 8.0 * scale;
    const row_gap = 4.0 * scale;
    const preview_gap = 12.0 * scale;
    // Enlarged preview (1.5x) for better visibility
    const preview_scale = 1.5;
    const preview_width = @as(f32, @floatFromInt(save_state_preview_width)) * scale * preview_scale;
    const preview_height = @as(f32, @floatFromInt(save_state_preview_height)) * scale * preview_scale;
    const preview_frame_width = preview_width + 6.0 * scale;
    const preview_frame_height = preview_height + 6.0 * scale;
    const preview_title = "SELECTED SLOT PREVIEW";

    var summary_buffers: [save_manager_slot_count][96]u8 = undefined;
    var path_buffers: [save_manager_slot_count][96]u8 = undefined;
    var summary_lines: [save_manager_slot_count][]const u8 = undefined;
    var path_lines: [save_manager_slot_count][]const u8 = undefined;
    var list_width = overlayTextWidth(controls_a, scale);
    list_width = @max(list_width, overlayTextWidth(controls_b, scale));
    const selected_metadata = save_manager.slotMetadata(persistent_state_slot);
    const preview_note = if (selected_metadata.preview.available)
        "CAPTURED ON SAVE"
    else if (selected_metadata.exists)
        "NO PREVIEW SIDECAR"
    else
        "SAVE THIS SLOT TO CREATE ONE";
    const preview_name = std.fs.path.basename(selected_metadata.path.slice());
    var preview_width_required = overlayTextWidth(preview_title, scale);
    preview_width_required = @max(preview_width_required, preview_frame_width);
    preview_width_required = @max(preview_width_required, overlayTextWidth(preview_note, scale));
    preview_width_required = @max(preview_width_required, overlayTextWidth(preview_name, scale));

    for (0..save_manager_slot_count) |slot_index| {
        const slot_number: u8 = @intCast(slot_index + 1);
        const metadata = &save_manager.slots[slot_index];
        summary_lines[slot_index] = try formatSaveManagerSlotLine(
            summary_buffers[slot_index][0..],
            metadata,
            slot_number,
            slot_number == StateFile.normalizePersistentStateSlot(persistent_state_slot),
        );
        path_lines[slot_index] = try formatSaveManagerPathLine(path_buffers[slot_index][0..], metadata);
        list_width = @max(list_width, overlayTextWidth(summary_lines[slot_index], scale));
        list_width = @max(list_width, overlayTextWidth(path_lines[slot_index], scale));
    }

    const svw: f32 = @floatFromInt(viewport.w);
    const svh: f32 = @floatFromInt(viewport.h);

    // Hide preview column if viewport is too narrow for two-column layout
    const two_col_width = list_width + preview_gap + preview_width_required + padding * 2.0;
    const show_preview = two_col_width <= svw;

    var max_width = overlayTextWidth(title, scale);
    if (show_preview) {
        max_width = @max(max_width, list_width + preview_gap + preview_width_required);
    } else {
        max_width = @max(max_width, list_width);
    }

    const row_height = summary_height + path_height + row_gap;
    const header_height = 13.0 * scale + summary_height * 2.0 + row_gap;
    const list_height = row_height * @as(f32, @floatFromInt(save_manager_slot_count));
    const content_height = if (show_preview) blk: {
        const preview_block_height = summary_height + row_gap + preview_frame_height + row_gap + path_height * 2.0;
        break :blk @max(list_height, preview_block_height);
    } else list_height;
    const panel_w = @min(max_width + padding * 2.0, svw);
    const panel_h = @min(padding * 2.0 + 7.0 * scale + 6.0 * scale + header_height + content_height, svh);
    const panel = zsdl3.FRect{
        .x = @max(0.0, (svw - panel_w) * 0.5),
        .y = @max(0.0, (svh - panel_h) * 0.5),
        .w = panel_w,
        .h = panel_h,
    };

    try renderOverlayPanel(
        renderer,
        panel,
        UiColors.panel_secondary,
        UiColors.orange,
        scale,
    );
    try ui_render.setClipRect(renderer, panel);
    defer ui_render.clearClipRect(renderer) catch {};

    try drawOverlayText(
        renderer,
        panel.x + (panel.w - overlayTextWidth(title, scale)) * 0.5,
        panel.y + padding,
        scale,
        UiColors.orange,
        title,
    );

    const text_x = panel.x + padding;
    var y = panel.y + padding + 13.0 * scale;
    try drawOverlayText(renderer, text_x, y, scale, UiColors.text_muted, controls_a);
    y += summary_height;
    try drawOverlayText(renderer, text_x, y, scale, UiColors.text_muted, controls_b);
    y = panel.y + padding + header_height;

    for (summary_lines, path_lines, 0..) |summary_line, path_line, slot_index| {
        const selected = slot_index + 1 == StateFile.normalizePersistentStateSlot(persistent_state_slot);
        const summary_color = if (selected)
            UiAnimation.pulseColor(UiColors.orange, frame_number, 0.75, 1.0)
        else
            UiColors.text_primary;
        try drawOverlayText(
            renderer,
            text_x,
            y,
            scale,
            summary_color,
            summary_line,
        );
        y += summary_height;
        const path_color = if (selected)
            UiAnimation.pulseColor(UiColors.gold, frame_number, 0.8, 1.0)
        else
            UiColors.text_muted;
        try drawOverlayText(
            renderer,
            text_x,
            y,
            scale,
            path_color,
            path_line,
        );
        y += path_height + row_gap;
    }

    if (show_preview) {
        const preview_x = text_x + list_width + preview_gap;
        var preview_y = panel.y + padding + header_height;
        try drawOverlayText(
            renderer,
            preview_x + (preview_width_required - overlayTextWidth(preview_title, scale)) * 0.5,
            preview_y,
            scale,
            UiColors.cyan,
            preview_title,
        );
        preview_y += summary_height + row_gap;

        const preview_frame = zsdl3.FRect{
            .x = preview_x + (preview_width_required - preview_frame_width) * 0.5,
            .y = preview_y,
            .w = preview_frame_width,
            .h = preview_frame_height,
        };
        try renderSaveManagerPreview(renderer, preview_frame, selected_metadata, scale);
        preview_y += preview_frame_height + row_gap;

        try drawOverlayText(
            renderer,
            preview_x + (preview_width_required - overlayTextWidth(preview_note, scale)) * 0.5,
            preview_y,
            scale,
            UiColors.text_muted,
            preview_note,
        );
        preview_y += path_height;
        try drawOverlayText(
            renderer,
            preview_x + (preview_width_required - overlayTextWidth(preview_name, scale)) * 0.5,
            preview_y,
            scale,
            UiColors.orange,
            preview_name,
        );
    }
}

// Re-export performance HUD rendering from frontend/performance.zig
const renderPerformanceHud = perf_monitor.renderHud;

fn renderGameInfoOverlay(
    renderer: *zsdl3.Renderer,
    viewport: zsdl3.Rect,
    machine: *const SystemMachine,
) !void {
    const metadata = machine.romMetadata();
    const game_lookup = rom_metadata.lookupGameByProductCode(metadata.product_code);

    const scale = overlayScale(viewport);
    const padding = 14.0 * scale;
    const line_height = 10.0 * scale;
    const heading_color = UiColors.cyan;
    const value_color = UiColors.text_primary;

    var line_bufs: [8][80]u8 = undefined;
    var lines: [8][]const u8 = undefined;
    var line_count: usize = 0;

    lines[line_count] = std.fmt.bufPrint(&line_bufs[line_count], "CONSOLE   {s}", .{metadata.console orelse "UNKNOWN"}) catch "CONSOLE   ???";
    line_count += 1;
    lines[line_count] = std.fmt.bufPrint(&line_bufs[line_count], "TITLE     {s}", .{metadata.title orelse "UNKNOWN"}) catch "TITLE     ???";
    line_count += 1;
    lines[line_count] = std.fmt.bufPrint(&line_bufs[line_count], "PRODUCT   {s}", .{metadata.product_code orelse "UNKNOWN"}) catch "PRODUCT   ???";
    line_count += 1;
    lines[line_count] = std.fmt.bufPrint(&line_bufs[line_count], "REGION    {s}", .{metadata.country_codes orelse "UNKNOWN"}) catch "REGION    ???";
    line_count += 1;
    lines[line_count] = std.fmt.bufPrint(&line_bufs[line_count], "CHECKSUM  {X:0>4} {s}", .{
        metadata.header_checksum,
        if (metadata.checksum_valid) "OK" else "MISMATCH",
    }) catch "CHECKSUM  ???";
    line_count += 1;
    lines[line_count] = std.fmt.bufPrint(&line_bufs[line_count], "TIMING    {s}", .{if (machine.palMode()) "PAL 50HZ" else "NTSC 60HZ"}) catch "TIMING    ???";
    line_count += 1;

    if (game_lookup) |info| {
        lines[line_count] = std.fmt.bufPrint(&line_bufs[line_count], "KNOWN AS  {s}", .{info.title}) catch "KNOWN AS  ???";
        line_count += 1;
    }

    const title = "GAME INFO";
    const footer = "[ESC] OR [I] CLOSE";
    var max_width = overlayTextWidth(title, scale);
    max_width = @max(max_width, overlayTextWidth(footer, scale));
    for (lines[0..line_count]) |line| max_width = @max(max_width, overlayTextWidth(line, scale));

    const total_rows: f32 = 3.0 + @as(f32, @floatFromInt(line_count));
    const stw: f32 = @floatFromInt(viewport.w);
    const sth: f32 = @floatFromInt(viewport.h);
    const panel_w = @min(max_width + padding * 2.0, stw);
    const panel_h = @min(padding * 2.0 + 7.0 * scale + 5.0 * scale + line_height * total_rows, sth);
    const panel = zsdl3.FRect{
        .x = @max(0.0, (stw - panel_w) * 0.5),
        .y = @max(0.0, (sth - panel_h) * 0.5),
        .w = panel_w,
        .h = panel_h,
    };

    try renderOverlayPanel(renderer, panel, UiColors.panel_primary, heading_color, scale);
    try ui_render.setClipRect(renderer, panel);
    defer ui_render.clearClipRect(renderer) catch {};

    try drawOverlayText(
        renderer,
        panel.x + (panel.w - overlayTextWidth(title, scale)) * 0.5,
        panel.y + padding,
        scale,
        UiColors.orange,
        title,
    );

    const text_x = panel.x + padding;
    var y = panel.y + padding + 14.0 * scale;

    for (lines[0..line_count]) |line| {
        try drawOverlayText(renderer, text_x, y, scale, value_color, line);
        y += line_height;
    }

    y += line_height * 0.5;
    try drawOverlayText(renderer, text_x, y, scale, UiColors.text_muted, footer);
}

fn renderSettingsOverlay(
    renderer: *zsdl3.Renderer,
    viewport: zsdl3.Rect,
    ui: *const FrontendUi,
    settings: *const SettingsMenuState,
    frontend_config: *const FrontendConfig,
    machine: *const SystemMachine,
    window: *zsdl3.Window,
    audio_enabled: bool,
    current_audio_mode: AudioOutput.RenderMode,
    config_path: []const u8,
) !void {
    const title = "SETTINGS";
    const controls_a = "[UP] [DOWN] MOVE  [LEFT] [RIGHT] ADJUST";
    const controls_b = "[ENTER] APPLY  [ESC] BACK  (B) CLOSE";
    const heading_video = "VIDEO";
    const heading_audio = "AUDIO";
    const heading_system = "SYSTEM";
    const scale = overlayScale(viewport);
    const padding = 12.0 * scale;
    const line_height = 10.0 * scale;

    var action_buffers: [settings_menu_actions.len][96]u8 = undefined;
    var action_lines: [settings_menu_actions.len][]const u8 = undefined;
    for (settings_menu_actions, 0..) |action, index| {
        action_lines[index] = try formatSettingsActionLine(
            action_buffers[index][0..],
            action,
            action == settings.currentAction(),
            frontend_config.video_aspect_mode,
            frontend_config.video_scale_mode,
            fullscreenEnabled(window),
            current_audio_mode,
            frontend_config.psg_volume,
            if (machine.genesisIoConst()) |io| io.controller_types else .{ .six_button, .six_button },
            ui.overlay == .performance_hud,
            frontend_config.font_face,
        );
    }

    var renderer_buffer: [96]u8 = undefined;
    const renderer_line = try std.fmt.bufPrint(
        renderer_buffer[0..],
        "RENDERER {s}",
        .{currentRendererName(renderer) orelse "UNKNOWN"},
    );
    const audio_output_line = if (audio_enabled) "OUTPUT ENABLED" else "OUTPUT DISABLED";
    const timing_line = if (machine.palMode()) "TIMING PAL 50HZ" else "TIMING NTSC 60HZ";
    const region_line = if (machine.consoleIsOverseas()) "REGION OVERSEAS" else "REGION DOMESTIC";

    var max_width = overlayTextWidth(title, scale);
    max_width = @max(max_width, overlayTextWidth(controls_a, scale));
    max_width = @max(max_width, overlayTextWidth(controls_b, scale));
    for (action_lines) |line| max_width = @max(max_width, overlayTextWidth(line, scale));
    for ([_][]const u8{ heading_video, heading_audio, heading_system, renderer_line, audio_output_line, timing_line, region_line, config_path }) |line| {
        max_width = @max(max_width, overlayTextWidth(line, scale));
    }

    const row_count: usize = 33;
    const stw: f32 = @floatFromInt(viewport.w);
    const sth: f32 = @floatFromInt(viewport.h);
    const settings_w = @min(max_width + padding * 2.0, stw);
    const settings_h = @min(padding * 2.0 + 7.0 * scale + 5.0 * scale + line_height * @as(f32, @floatFromInt(row_count)), sth);
    const panel = zsdl3.FRect{
        .x = @max(0.0, (stw - settings_w) * 0.5),
        .y = @max(0.0, (sth - settings_h) * 0.5),
        .w = settings_w,
        .h = settings_h,
    };

    try renderOverlayPanel(
        renderer,
        panel,
        UiColors.panel_secondary,
        UiColors.orange,
        scale,
    );
    try ui_render.setClipRect(renderer, panel);
    defer ui_render.clearClipRect(renderer) catch {};

    try drawOverlayText(
        renderer,
        panel.x + (panel.w - overlayTextWidth(title, scale)) * 0.5,
        panel.y + padding,
        scale,
        UiColors.orange,
        title,
    );

    const text_x = panel.x + padding;
    var y = panel.y + padding + 12.0 * scale;
    try drawOverlayText(renderer, text_x, y, scale, UiColors.text_muted, controls_a);
    y += line_height;
    try drawOverlayText(renderer, text_x, y, scale, UiColors.text_muted, controls_b);
    y += line_height;

    const heading_color = UiColors.cyan;
    const info_color = UiColors.text_muted;
    const selected_color = UiColors.text_selected;
    const normal_color = UiColors.text_primary;

    // Render settings entries grouped by section
    // action_lines[]: 0=aspect, 1=scale, 2=fullscreen, 3=audio_mode, 4=psg_vol, 5=ctrl_p1, 6=ctrl_p2, 7=perf, 8=font_face, 9=close
    const actionColor = struct {
        fn f(cur: SettingsMenuAction, target: SettingsMenuAction, sel: zsdl3.Color, norm: zsdl3.Color) zsdl3.Color {
            return if (cur == target) sel else norm;
        }
    }.f;
    const cur = settings.currentAction();

    try drawOverlayText(renderer, text_x, y, scale, heading_color, heading_video);
    y += line_height;
    try drawOverlayText(renderer, text_x, y, scale, actionColor(cur, .video_aspect_mode, selected_color, normal_color), action_lines[0]);
    y += line_height;
    try drawOverlayText(renderer, text_x, y, scale, actionColor(cur, .video_scale_mode, selected_color, normal_color), action_lines[1]);
    y += line_height;
    try drawOverlayText(renderer, text_x, y, scale, actionColor(cur, .fullscreen, selected_color, normal_color), action_lines[2]);
    y += line_height;
    try drawOverlayText(renderer, text_x, y, scale, info_color, renderer_line);
    y += line_height * 2.0;

    try drawOverlayText(renderer, text_x, y, scale, heading_color, heading_audio);
    y += line_height;
    try drawOverlayText(renderer, text_x, y, scale, actionColor(cur, .audio_render_mode, selected_color, normal_color), action_lines[3]);
    y += line_height;
    try drawOverlayText(renderer, text_x, y, scale, actionColor(cur, .psg_volume, selected_color, normal_color), action_lines[4]);
    y += line_height;
    try drawOverlayText(renderer, text_x, y, scale, info_color, audio_output_line);
    y += line_height * 2.0;

    try drawOverlayText(renderer, text_x, y, scale, heading_color, "INPUT");
    y += line_height;
    try drawOverlayText(renderer, text_x, y, scale, actionColor(cur, .controller_p1_type, selected_color, normal_color), action_lines[5]);
    y += line_height;
    try drawOverlayText(renderer, text_x, y, scale, actionColor(cur, .controller_p2_type, selected_color, normal_color), action_lines[6]);
    y += line_height * 2.0;

    try drawOverlayText(renderer, text_x, y, scale, heading_color, heading_system);
    y += line_height;
    try drawOverlayText(renderer, text_x, y, scale, actionColor(cur, .performance_hud, selected_color, normal_color), action_lines[7]);
    y += line_height;
    try drawOverlayText(renderer, text_x, y, scale, info_color, timing_line);
    y += line_height;
    try drawOverlayText(renderer, text_x, y, scale, info_color, region_line);
    y += line_height;
    try drawOverlayText(renderer, text_x, y, scale, info_color, config_path);
    y += line_height * 2.0;

    try drawOverlayText(renderer, text_x, y, scale, heading_color, "UI");
    y += line_height;
    try drawOverlayText(renderer, text_x, y, scale, actionColor(cur, .font_face, selected_color, normal_color), action_lines[8]);
    y += line_height * 2.0;

    try drawOverlayText(renderer, text_x, y, scale, actionColor(cur, .close, selected_color, normal_color), action_lines[9]);
}

fn renderFrontendOverlay(
    renderer: *zsdl3.Renderer,
    ui: *const FrontendUi,
    home_menu: *const HomeMenuState,
    settings: *const SettingsMenuState,
    frontend_config: *const FrontendConfig,
    save_manager: *const SaveManagerState,
    toast: *const FrontendToast,
    frontend_frame_number: u64,
    editor: *const BindingEditorState,
    bindings: *const InputBindings.Bindings,
    machine: *const SystemMachine,
    window: *zsdl3.Window,
    audio_enabled: bool,
    current_audio_mode: AudioOutput.RenderMode,
    persistent_state_slot: u8,
    current_rom_path: ?[]const u8,
    config_path: []const u8,
) !void {
    const show_toast = toast.visible(frontend_frame_number);
    const has_rom = current_rom_path != null and current_rom_path.?.len > 0;
    const show_status_bar = has_rom and ui.showsStatusBar();
    if (ui.overlay == .none and !show_toast) return;

    const viewport = try zsdl3.getRenderViewport(renderer);
    try zsdl3.setRenderDrawBlendMode(renderer, .blend);
    if (ui.overlay.shouldDimBackdrop()) {
        try zsdl3.setRenderDrawColor(renderer, .{ .r = 0, .g = 0, .b = 0, .a = 0x80 });
        try zsdl3.renderFillRect(renderer, .{ .x = 0, .y = 0, .w = @floatFromInt(viewport.w), .h = @floatFromInt(viewport.h) });
    }
    if (show_status_bar) {
        const rom_basename = std.fs.path.basename(current_rom_path.?);
        var name_buf: [64]u8 = undefined;
        const rom_name = rom_paths.displayName(rom_basename, &name_buf, 32);
        try renderStatusBar(renderer, viewport, rom_name, persistent_state_slot, machine.palMode());
    }
    if (show_toast) {
        try renderToastOverlay(renderer, viewport, toast, frontend_frame_number);
    }
    switch (ui.overlay) {
        .none, .debugger, .performance_hud => {},
        .game_info => try renderGameInfoOverlay(renderer, viewport, machine),
        .dialog => try renderDialogOverlay(renderer, viewport),
        .keyboard_editor => try renderKeyboardEditorOverlay(renderer, viewport, editor, bindings, frontend_frame_number, config_path),
        .settings => try renderSettingsOverlay(renderer, viewport, ui, settings, frontend_config, machine, window, audio_enabled, current_audio_mode, config_path),
        .save_manager => try renderSaveManagerOverlay(renderer, viewport, save_manager, persistent_state_slot, frontend_frame_number),
        .help => try renderHelpOverlay(renderer, viewport, bindings, persistent_state_slot),
        .home => try renderHomeOverlay(renderer, viewport, home_menu, frontend_config, frontend_frame_number),
        .pause => try renderPauseOverlay(renderer, viewport, bindings, persistent_state_slot),
    }
}

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    var cli_config = CliConfig{};
    const root_cmd = try createCliCommand(allocator);
    defer root_cmd.deinit();
    try root_cmd.run(&cli_config);
    if (cli_config.show_version) {
        try std.fs.File.stdout().writeAll(cli_module.version_summary ++ "\n");
        return;
    }
    if (!cli_config.should_run) return;

    const cli = cli_config;
    defer if (cli.rom_path) |p| allocator.free(p);
    defer if (cli.renderer_name) |p| allocator.free(p);
    defer if (cli.config_path) |p| allocator.free(p);
    const rom_path = cli.rom_path;

    std.debug.print("=== Sandopolis Emulator Started ===\n", .{});

    try zsdl3.init(.{ .audio = true, .video = true, .joystick = true, .gamepad = true });
    defer zsdl3.quit();

    const window = try zsdl3.Window.create(
        "Sandopolis Emulator (" ++ build_options.version ++ "; " ++ build_options.git_branch ++ "@" ++ build_options.git_hash ++ ")",
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

    // Initialize TTF font for UI overlays
    var ui_font = ui_render.Font.init(ui_render.font_jbm_regular);
    defer ui_font.deinit();
    ui_render.initFont(&ui_font);
    defer ui_render.deinitFont();

    var audio_userdata: u8 = 0;
    var audio: ?AudioInit = tryInitAudio(&audio_userdata);
    if (audio == null) {
        std.debug.print("Audio disabled: no compatible stream format\n", .{});
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
        std.debug.print("No ROM file specified. Starting at the frontend home screen.\n", .{});
        std.debug.print("Loading dummy backend ROM for the idle frontend shell.\n", .{});
    }

    // Load unified config (frontend settings + input bindings in one file)
    const config_file_path = if (cli.config_path) |custom_path|
        try allocator.dupe(u8, custom_path)
    else
        try config_path_mod.resolveConfigPath(allocator);
    defer allocator.free(config_file_path);
    const loaded_config = try unified_config.load(allocator, config_file_path);
    var input_bindings = loaded_config.bindings;
    var frontend_config = loaded_config.frontend;
    std.debug.print("Config: {s}\n", .{config_file_path});

    // Write default config on first run if file doesn't exist
    std.fs.cwd().access(config_file_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            unified_config.save(&frontend_config, &input_bindings, config_file_path) catch |save_err| {
                std.debug.print("Failed to create default config file: {s}\n", .{@errorName(save_err)});
            };
        },
        else => {},
    };

    // Unified config path is used for all saves
    const frontend_config_path = config_file_path;

    // Apply configured font face
    if (frontend_config.font_face != .jbm_regular) {
        ui_font.deinit();
        ui_font = ui_render.Font.init(fontDataForFace(frontend_config.font_face));
        ui_render.initFont(&ui_font);
    }

    var current_audio_mode = frontend_config.audio_render_mode;
    if (cli.audio_mode_overridden) current_audio_mode = cli.audio_mode;
    const current_audio_queue_ms = if (cli.audio_queue_ms_overridden) cli.audio_queue_ms else frontend_config.audio_queue_ms;
    if (audio) |*a| {
        a.output.setRenderMode(current_audio_mode);
        a.output.setPsgVolume(frontend_config.psg_volume);
        a.output.setEqEnabled(frontend_config.eq_enabled);
        a.output.setEqGains(
            @as(f64, @floatFromInt(frontend_config.eq_low)) / 100.0,
            @as(f64, @floatFromInt(frontend_config.eq_mid)) / 100.0,
            @as(f64, @floatFromInt(frontend_config.eq_high)) / 100.0,
        );
        a.setQueueBudgetMs(current_audio_queue_ms);
    }
    if (current_audio_mode != .normal) {
        std.debug.print("Audio render mode: {s}\n", .{current_audio_mode.name()});
    }
    if (current_audio_queue_ms != AudioOutput.default_queue_budget_ms) {
        std.debug.print("Audio queue budget: {d} ms\n", .{current_audio_queue_ms});
    }

    var machine = try SystemMachine.init(allocator, rom_path);
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
    var frontend_frame_counter: u64 = 0;
    const uncapped_boot_frames: u32 = uncappedBootFrames(audio != null);
    var gif_recorder: ?GifRecorder = null;
    var wav_recorder: ?WavRecorder = null;
    var quick_state: ?SystemMachine.Snapshot = null;
    var persistent_state_slot: u8 = StateFile.default_persistent_state_slot;
    defer if (quick_state) |*state| state.deinit(allocator);
    var frontend_ui = FrontendUi{ .overlay = if (rom_path == null) .home else .none };
    var home_menu = HomeMenuState{};
    var settings_menu = SettingsMenuState{};
    var save_manager = SaveManagerState{};
    var frontend_toast = FrontendToast{};
    var performance_hud = PerformanceHudState{};
    var debugger_state = debugger_mod.DebuggerState{};
    var performance_spike_log = PerformanceSpikeLogState{};
    var core_profile_frames_remaining: u32 = 0;
    var file_dialog_state = FileDialogState{};
    var binding_editor = BindingEditorState{};

    if (rom_path) |path| {
        rememberLoadedRom(&frontend_config, &input_bindings, frontend_config_path, .{ .toast = &frontend_toast, .frame_number = frontend_frame_counter }, path);
    }
    home_menu.clamp(&frontend_config);

    var frame_timer = std.time.Instant.now() catch unreachable;
    mainLoop: while (true) {
        frame_timer = std.time.Instant.now() catch frame_timer;
        var event: zsdl3.Event = undefined;
        while (zsdl3.pollEvent(&event)) {
            switch (event.type) {
                zsdl3.EventType.quit => break :mainLoop,
                zsdl3.EventType.gamepad_added => assignGamepadSlot(&gamepads, &joysticks, &gamepad_sticks, &gamepad_triggers, event.gdevice.which),
                zsdl3.EventType.gamepad_removed => {
                    if (machine.asGenesis()) |gen| {
                        removeGamepadSlot(&gamepads, &gamepad_sticks, &gamepad_triggers, gen, &input_bindings, event.gdevice.which);
                    } else {
                        // SMS: just close the gamepad slot without machine interaction
                        for (&gamepads, 0..) |*slot, port| {
                            if (slot.*) |assigned| {
                                if (assigned.id == event.gdevice.which) {
                                    gamepad_sticks[port] = .{};
                                    gamepad_triggers[port] = .{};
                                    assigned.handle.close();
                                    slot.* = null;
                                    break;
                                }
                            }
                        }
                    }
                },
                zsdl3.EventType.joystick_added => assignJoystickSlot(&gamepads, &joysticks, &joystick_axes, &joystick_hats, event.jdevice.which),
                zsdl3.EventType.joystick_removed => {
                    if (machine.asGenesis()) |gen| {
                        removeJoystickSlot(&joysticks, &joystick_axes, &joystick_hats, gen, &input_bindings, event.jdevice.which);
                    }
                },
                zsdl3.EventType.gamepad_button_down, zsdl3.EventType.gamepad_button_up => {
                    const pressed = (event.type == zsdl3.EventType.gamepad_button_down);
                    const button = event.gbutton.button;
                    const port = findGamepadPort(&gamepads, event.gbutton.which) orelse continue;

                    // Binding editor gamepad capture
                    if (frontend_ui.overlay == .keyboard_editor and binding_editor.capture_mode and binding_editor.capture_gamepad) {
                        const pressed_gp = (event.type == zsdl3.EventType.gamepad_button_down);
                        if (pressed_gp) {
                            if (gamepadInputFromButton(button)) |gp_input| {
                                binding_editor.assignGamepad(&input_bindings, gp_input);
                            }
                        }
                        continue;
                    }
                    // Binding editor navigation via gamepad (when open but not capturing)
                    if (frontend_ui.overlay == .keyboard_editor and !binding_editor.capture_mode) {
                        const pressed_gp = (event.type == zsdl3.EventType.gamepad_button_down);
                        if (pressed_gp) {
                            if (gamepadInputFromButton(button)) |gp_input| {
                                switch (gp_input) {
                                    .dpad_up => binding_editor.move(-1),
                                    .dpad_down => binding_editor.move(1),
                                    .south => binding_editor.beginCapture(),
                                    .east, .back => {
                                        frontend_ui.overlay = .none;
                                        binding_editor.close();
                                    },
                                    else => {},
                                }
                            }
                        }
                        continue;
                    }

                    if (gamepadInputFromButton(button)) |mapped_button| {
                        const notifications = FrontendNotifications{
                            .toast = &frontend_toast,
                            .frame_number = frontend_frame_counter,
                        };
                        const explicit_state_path = if (current_rom_path.len != 0) current_rom_path.slice() else null;
                        switch (dispatchFrontendGamepadCommand(
                            handleFrontendGamepadInput(
                                &frontend_ui,
                                &home_menu,
                                &settings_menu,
                                &frontend_config,
                                frontend_config_path,
                                &save_manager,
                                allocator,
                                &machine,
                                explicit_state_path,
                                &persistent_state_slot,
                                &gif_recorder,
                                &wav_recorder,
                                if (audio) |*a| a else null,
                                &current_audio_mode,
                                &performance_hud,
                                &performance_spike_log,
                                &core_profile_frames_remaining,
                                window,
                                &frame_counter,
                                &debugger_state,
                                &input_bindings,
                                &ui_font,
                                renderer,
                                mapped_button,
                                pressed,
                                notifications,
                            ),
                            allocator,
                            &machine,
                            &input_bindings,
                            cli.timing_mode,
                            if (audio) |*a| a else null,
                            &gif_recorder,
                            &wav_recorder,
                            &frame_counter,
                            &frontend_config,
                            frontend_config_path,
                            &home_menu,
                            &current_rom_path,
                            &frontend_ui,
                            &file_dialog_state,
                            window,
                            &frontend_toast,
                            frontend_frame_counter,
                        )) {
                            .quit => break :mainLoop,
                            .handled => continue,
                            .unhandled => {},
                        }
                    }
                    if (frontend_ui.emulationPaused() and pressed) continue;
                    if (gamepadInputFromButton(button)) |mapped_button| {
                        if (machine.asGenesis()) |gen| {
                            _ = gen.applyGamepadBindings(&input_bindings, port, mapped_button, pressed);
                        } else {
                            applySmsGamepadInput(&machine, @intCast(@min(port, 1)), mapped_button, pressed);
                        }
                    }
                },
                zsdl3.EventType.gamepad_axis_motion => {
                    const port = findGamepadPort(&gamepads, event.gaxis.which) orelse continue;
                    const axis: zsdl3.Gamepad.Axis = @enumFromInt(event.gaxis.axis);
                    const transitions = updateGamepadAxisState(
                        &gamepad_sticks[port],
                        &gamepad_triggers[port],
                        axis,
                        event.gaxis.value,
                        input_bindings.gamepad_axis_threshold,
                        input_bindings.trigger_threshold,
                    );
                    const notifications = FrontendNotifications{
                        .toast = &frontend_toast,
                        .frame_number = frontend_frame_counter,
                    };
                    const explicit_state_path = if (current_rom_path.len != 0) current_rom_path.slice() else null;
                    switch (dispatchFrontendGamepadCommand(
                        handleFrontendGamepadTransitions(
                            &frontend_ui,
                            &home_menu,
                            &settings_menu,
                            &frontend_config,
                            frontend_config_path,
                            &save_manager,
                            allocator,
                            &machine,
                            explicit_state_path,
                            &persistent_state_slot,
                            &gif_recorder,
                            &wav_recorder,
                            if (audio) |*a| a else null,
                            &current_audio_mode,
                            &performance_hud,
                            &performance_spike_log,
                            &core_profile_frames_remaining,
                            window,
                            &frame_counter,
                            &debugger_state,
                            &input_bindings,
                            &ui_font,
                            renderer,
                            notifications,
                            transitions,
                        ),
                        allocator,
                        &machine,
                        &input_bindings,
                        cli.timing_mode,
                        if (audio) |*a| a else null,
                        &gif_recorder,
                        &wav_recorder,
                        &frame_counter,
                        &frontend_config,
                        frontend_config_path,
                        &home_menu,
                        &current_rom_path,
                        &frontend_ui,
                        &file_dialog_state,
                        window,
                        &frontend_toast,
                        frontend_frame_counter,
                    )) {
                        .quit => break :mainLoop,
                        .handled => continue,
                        .unhandled => {},
                    }
                    if (frontend_ui.emulationPaused()) {
                        if (machine.asGenesis()) |gen| applyReleaseTransitionsOnly(&input_bindings, gen, port, transitions);
                        continue;
                    }
                    if (machine.asGenesis()) |gen| {
                        applyInputTransitions(&input_bindings, gen, port, transitions);
                    } else {
                        for (transitions) |maybe_transition| {
                            if (maybe_transition) |transition| {
                                applySmsGamepadInput(&machine, @intCast(@min(port, 1)), transition.input, transition.pressed);
                            }
                        }
                    }
                },
                zsdl3.EventType.joystick_button_down, zsdl3.EventType.joystick_button_up => {
                    const pressed = (event.type == zsdl3.EventType.joystick_button_down);
                    const port = findJoystickPort(&joysticks, event.jbutton.which) orelse continue;
                    if (joystickInputFromButton(event.jbutton.button)) |mapped_button| {
                        const notifications = FrontendNotifications{
                            .toast = &frontend_toast,
                            .frame_number = frontend_frame_counter,
                        };
                        const explicit_state_path = if (current_rom_path.len != 0) current_rom_path.slice() else null;
                        switch (dispatchFrontendGamepadCommand(
                            handleFrontendGamepadInput(
                                &frontend_ui,
                                &home_menu,
                                &settings_menu,
                                &frontend_config,
                                frontend_config_path,
                                &save_manager,
                                allocator,
                                &machine,
                                explicit_state_path,
                                &persistent_state_slot,
                                &gif_recorder,
                                &wav_recorder,
                                if (audio) |*a| a else null,
                                &current_audio_mode,
                                &performance_hud,
                                &performance_spike_log,
                                &core_profile_frames_remaining,
                                window,
                                &frame_counter,
                                &debugger_state,
                                &input_bindings,
                                &ui_font,
                                renderer,
                                mapped_button,
                                pressed,
                                notifications,
                            ),
                            allocator,
                            &machine,
                            &input_bindings,
                            cli.timing_mode,
                            if (audio) |*a| a else null,
                            &gif_recorder,
                            &wav_recorder,
                            &frame_counter,
                            &frontend_config,
                            frontend_config_path,
                            &home_menu,
                            &current_rom_path,
                            &frontend_ui,
                            &file_dialog_state,
                            window,
                            &frontend_toast,
                            frontend_frame_counter,
                        )) {
                            .quit => break :mainLoop,
                            .handled => continue,
                            .unhandled => {},
                        }
                    }
                    if (frontend_ui.emulationPaused() and pressed) continue;
                    if (joystickInputFromButton(event.jbutton.button)) |mapped_button| {
                        if (machine.asGenesis()) |gen| {
                            _ = gen.applyGamepadBindings(&input_bindings, port, mapped_button, pressed);
                        } else {
                            applySmsGamepadInput(&machine, @intCast(@min(port, 1)), mapped_button, pressed);
                        }
                    }
                },
                zsdl3.EventType.joystick_axis_motion => {
                    const port = findJoystickPort(&joysticks, event.jaxis.which) orelse continue;
                    const transitions = updateJoystickAxisState(
                        &joystick_axes[port],
                        event.jaxis.axis,
                        event.jaxis.value,
                        input_bindings.joystick_axis_threshold,
                    );
                    const notifications = FrontendNotifications{
                        .toast = &frontend_toast,
                        .frame_number = frontend_frame_counter,
                    };
                    const explicit_state_path = if (current_rom_path.len != 0) current_rom_path.slice() else null;
                    switch (dispatchFrontendGamepadCommand(
                        handleFrontendGamepadTransitions(
                            &frontend_ui,
                            &home_menu,
                            &settings_menu,
                            &frontend_config,
                            frontend_config_path,
                            &save_manager,
                            allocator,
                            &machine,
                            explicit_state_path,
                            &persistent_state_slot,
                            &gif_recorder,
                            &wav_recorder,
                            if (audio) |*a| a else null,
                            &current_audio_mode,
                            &performance_hud,
                            &performance_spike_log,
                            &core_profile_frames_remaining,
                            window,
                            &frame_counter,
                            &debugger_state,
                            &input_bindings,
                            &ui_font,
                            renderer,
                            notifications,
                            transitions,
                        ),
                        allocator,
                        &machine,
                        &input_bindings,
                        cli.timing_mode,
                        if (audio) |*a| a else null,
                        &gif_recorder,
                        &wav_recorder,
                        &frame_counter,
                        &frontend_config,
                        frontend_config_path,
                        &home_menu,
                        &current_rom_path,
                        &frontend_ui,
                        &file_dialog_state,
                        window,
                        &frontend_toast,
                        frontend_frame_counter,
                    )) {
                        .quit => break :mainLoop,
                        .handled => continue,
                        .unhandled => {},
                    }
                    if (frontend_ui.emulationPaused()) {
                        if (machine.asGenesis()) |gen| applyReleaseTransitionsOnly(&input_bindings, gen, port, transitions);
                        continue;
                    }
                    if (machine.asGenesis()) |gen| {
                        applyInputTransitions(&input_bindings, gen, port, transitions);
                    } else {
                        for (transitions) |maybe_transition| {
                            if (maybe_transition) |transition| {
                                applySmsGamepadInput(&machine, @intCast(@min(port, 1)), transition.input, transition.pressed);
                            }
                        }
                    }
                },
                zsdl3.EventType.joystick_hat_motion => {
                    if (event.jhat.hat != 0) continue;
                    const port = findJoystickPort(&joysticks, event.jhat.which) orelse continue;
                    const transitions = updateHatState(&joystick_hats[port], event.jhat.value);
                    const notifications = FrontendNotifications{
                        .toast = &frontend_toast,
                        .frame_number = frontend_frame_counter,
                    };
                    const explicit_state_path = if (current_rom_path.len != 0) current_rom_path.slice() else null;
                    switch (dispatchFrontendGamepadCommand(
                        handleFrontendGamepadTransitions(
                            &frontend_ui,
                            &home_menu,
                            &settings_menu,
                            &frontend_config,
                            frontend_config_path,
                            &save_manager,
                            allocator,
                            &machine,
                            explicit_state_path,
                            &persistent_state_slot,
                            &gif_recorder,
                            &wav_recorder,
                            if (audio) |*a| a else null,
                            &current_audio_mode,
                            &performance_hud,
                            &performance_spike_log,
                            &core_profile_frames_remaining,
                            window,
                            &frame_counter,
                            &debugger_state,
                            &input_bindings,
                            &ui_font,
                            renderer,
                            notifications,
                            transitions,
                        ),
                        allocator,
                        &machine,
                        &input_bindings,
                        cli.timing_mode,
                        if (audio) |*a| a else null,
                        &gif_recorder,
                        &wav_recorder,
                        &frame_counter,
                        &frontend_config,
                        frontend_config_path,
                        &home_menu,
                        &current_rom_path,
                        &frontend_ui,
                        &file_dialog_state,
                        window,
                        &frontend_toast,
                        frontend_frame_counter,
                    )) {
                        .quit => break :mainLoop,
                        .handled => continue,
                        .unhandled => {},
                    }
                    if (frontend_ui.emulationPaused()) {
                        if (machine.asGenesis()) |gen| applyReleaseTransitionsOnly(&input_bindings, gen, port, transitions);
                        continue;
                    }
                    if (machine.asGenesis()) |gen| {
                        applyInputTransitions(&input_bindings, gen, port, transitions);
                    } else {
                        for (transitions) |maybe_transition| {
                            if (maybe_transition) |transition| {
                                applySmsGamepadInput(&machine, @intCast(@min(port, 1)), transition.input, transition.pressed);
                            }
                        }
                    }
                },
                zsdl3.EventType.key_down, zsdl3.EventType.key_up => {
                    const pressed = (event.type == zsdl3.EventType.key_down);
                    const scancode = event.key.scancode;
                    const keyboard_state = zsdl3.getKeyboardState();
                    const hotkey_binding = hotkeyBindingFromScancode(scancode, keyboard_state);
                    const hotkey_action = if (hotkey_binding) |binding| input_bindings.hotkeyForBinding(binding) else null;
                    const explicit_state_path = if (current_rom_path.len != 0) current_rom_path.slice() else null;
                    if (handleSettingsKey(
                        &frontend_ui,
                        &settings_menu,
                        &frontend_config,
                        frontend_config_path,
                        &performance_hud,
                        &performance_spike_log,
                        &core_profile_frames_remaining,
                        window,
                        if (audio) |*a| a else null,
                        &current_audio_mode,
                        &input_bindings,
                        &machine,
                        &ui_font,
                        renderer,
                        scancode,
                        pressed,
                        .{ .toast = &frontend_toast, .frame_number = frontend_frame_counter },
                    )) {
                        continue;
                    }
                    if (handleSaveManagerKey(
                        &frontend_ui,
                        &save_manager,
                        allocator,
                        &machine,
                        explicit_state_path,
                        &persistent_state_slot,
                        &gif_recorder,
                        &wav_recorder,
                        if (audio) |*a| a else null,
                        &frame_counter,
                        scancode,
                        hotkey_action,
                        pressed,
                        .{ .toast = &frontend_toast, .frame_number = frontend_frame_counter },
                    )) {
                        continue;
                    }
                    if (handleGameInfoKey(&frontend_ui, scancode, pressed)) {
                        continue;
                    }
                    if (handlePauseOverlayKey(
                        &frontend_ui,
                        &save_manager,
                        &settings_menu,
                        allocator,
                        &machine,
                        explicit_state_path,
                        scancode,
                        pressed,
                        .{ .toast = &frontend_toast, .frame_number = frontend_frame_counter },
                    )) {
                        continue;
                    }
                    if (handleBindingEditorKey(
                        &frontend_ui,
                        &binding_editor,
                        &input_bindings,
                        &machine,
                        config_file_path,
                        &frontend_config,
                        scancode,
                        hotkey_binding,
                        pressed,
                    )) {
                        continue;
                    }
                    switch (dispatchHomeScreenCommand(
                        handleHomeScreenKey(&frontend_ui, &home_menu, &settings_menu, &frontend_config, scancode, pressed),
                        allocator,
                        &machine,
                        &input_bindings,
                        cli.timing_mode,
                        if (audio) |*a| a else null,
                        &gif_recorder,
                        &wav_recorder,
                        &frame_counter,
                        &frontend_config,
                        frontend_config_path,
                        &home_menu,
                        &current_rom_path,
                        &frontend_ui,
                        &file_dialog_state,
                        window,
                        &frontend_toast,
                        frontend_frame_counter,
                    )) {
                        .quit => break :mainLoop,
                        .handled => continue,
                        .unhandled => {},
                    }
                    // Debugger controls (F10 toggle, Space step, Tab switch tabs)
                    if (pressed and scancode == .f10) {
                        if (frontend_ui.overlay == .debugger) {
                            debugger_state.active = false;
                            frontend_ui.overlay = .none;
                        } else {
                            debugger_state.active = true;
                            frontend_ui.overlay = .debugger;
                        }
                        continue;
                    }
                    if (pressed and frontend_ui.overlay == .debugger and debugger_state.active) {
                        const consumed = switch (scancode) {
                            .space => blk: {
                                debugger_state.stepOnce();
                                break :blk true;
                            },
                            .b => blk: {
                                debugger_state.toggleBreakpoint(machine.programCounter());
                                break :blk true;
                            },
                            .g => blk: {
                                debugger_state.runToBreakpoint();
                                break :blk true;
                            },
                            .tab => blk: {
                                debugger_state.nextTab();
                                break :blk true;
                            },
                            .pageup => blk: {
                                debugger_state.adjustMemoryAddress(-256);
                                break :blk true;
                            },
                            .pagedown => blk: {
                                debugger_state.adjustMemoryAddress(256);
                                break :blk true;
                            },
                            else => false,
                        };
                        if (consumed) continue;
                    }

                    if (pressed) {
                        if (hotkey_action) |action| {
                            const notifications = FrontendNotifications{
                                .toast = &frontend_toast,
                                .frame_number = frontend_frame_counter,
                            };
                            if (handleQuickStateAction(
                                allocator,
                                action,
                                &machine,
                                &quick_state,
                                if (audio) |*a| a else null,
                                &gif_recorder,
                                &wav_recorder,
                                &frame_counter,
                                notifications,
                            )) {
                                continue;
                            }
                            const persistent_state_result = handlePersistentStateAction(
                                allocator,
                                action,
                                &machine,
                                null,
                                &persistent_state_slot,
                                if (audio) |*a| a else null,
                                &gif_recorder,
                                &wav_recorder,
                                &frame_counter,
                                notifications,
                            );
                            if (persistent_state_result == .loaded_machine) {
                                syncFrontendAfterPersistentStateLoad(&frontend_ui, &current_rom_path, &machine);
                                continue;
                            }
                            if (persistent_state_result != .ignored) {
                                continue;
                            }

                            switch (action) {
                                .toggle_help => {
                                    if (frontend_ui.overlay == .help) {
                                        frontend_ui.closeHelp();
                                    } else {
                                        frontend_ui.openHelp();
                                    }
                                },
                                .toggle_pause => {
                                    if (frontend_ui.overlay != .home) {
                                        if (frontend_ui.overlay == .pause) {
                                            frontend_ui.resumeGame();
                                        } else if (frontend_ui.overlay == .none or frontend_ui.overlay == .performance_hud) {
                                            frontend_ui.overlay = .pause;
                                            if (audio) |*a| {
                                                zsdl3.clearAudioStream(a.stream) catch {};
                                            }
                                        }
                                    }
                                },
                                .open_rom => _ = launchOpenRomDialog(
                                    &file_dialog_state,
                                    &frontend_ui,
                                    window,
                                    preferredOpenRomLocation(&frontend_config, &current_rom_path),
                                ),
                                .restart_rom => {
                                    if (frontend_ui.overlay != .home) {
                                        softResetCurrentMachine(&machine, &frame_counter, notifications);
                                    }
                                },
                                .reload_rom => {
                                    hardResetCurrentMachine(
                                        allocator,
                                        &machine,
                                        &input_bindings,
                                        cli.timing_mode,
                                        if (audio) |*a| a else null,
                                        &gif_recorder,
                                        &wav_recorder,
                                        &frame_counter,
                                        if (current_rom_path.len != 0) current_rom_path.slice() else null,
                                        notifications,
                                    ) catch |err| {
                                        std.debug.print("Failed to hard reset or reload current ROM: {}\n", .{err});
                                        notifyFrontend(notifications, .failure, "FAILED TO RELOAD CURRENT ROM", .{});
                                    };
                                },
                                .toggle_performance_hud => {
                                    configurePerformanceHud(
                                        &frontend_ui,
                                        &performance_hud,
                                        &performance_spike_log,
                                        &core_profile_frames_remaining,
                                        frontend_ui.overlay != .performance_hud,
                                    );
                                },
                                .reset_performance_hud => {
                                    performance_hud.reset();
                                    performance_spike_log.reset();
                                    core_profile_frames_remaining = 0;
                                },
                                .record_gif => {
                                    if (frontend_ui.overlay == .help) continue;
                                    if (gif_recorder) |*rec| {
                                        const frames = rec.frame_count;
                                        rec.finish();
                                        gif_recorder = null;
                                        std.debug.print("GIF recording stopped ({d} frames)\n", .{frames});
                                        notifyFrontend(notifications, .success, "GIF RECORDING STOPPED", .{});
                                    } else {
                                        const fps: u16 = if (machine.palMode()) 25 else 30;
                                        const path = gifOutputPath(if (current_rom_path.len != 0) current_rom_path.slice() else "") orelse {
                                            std.debug.print("No available GIF output slot (001-999 all exist)\n", .{});
                                            notifyFrontend(notifications, .failure, "NO AVAILABLE GIF SLOT", .{});
                                            continue;
                                        };
                                        const path_str = std.mem.sliceTo(&path, 0);
                                        const fb_width = machine.framebufferWidth();
                                        const framebuffer_height: u16 = @intCast(machine.framebuffer().len / fb_width);
                                        gif_recorder = GifRecorder.start(path_str, fps, fb_width, framebuffer_height) catch |err| {
                                            std.debug.print("Failed to start GIF recording: {}\n", .{err});
                                            notifyFrontend(notifications, .failure, "FAILED TO START GIF RECORDING", .{});
                                            continue;
                                        };
                                        std.debug.print("GIF recording started: {s}\n", .{path_str});
                                        notifyFrontend(notifications, .success, "GIF RECORDING STARTED", .{});
                                    }
                                },
                                .record_wav => {
                                    if (frontend_ui.overlay == .help) continue;
                                    if (wav_recorder) |*rec| {
                                        if (audio) |*a| {
                                            a.syncRecordedPlayback(rec);
                                        }
                                        const duration = rec.getDurationSeconds();
                                        const samples = rec.sample_count;
                                        rec.finish();
                                        wav_recorder = null;
                                        std.debug.print("WAV recording stopped ({d} samples, {d:.2}s)\n", .{ samples, duration });
                                        notifyFrontend(notifications, .success, "WAV RECORDING STOPPED", .{});
                                    } else {
                                        if (audio) |*a| {
                                            a.syncRecordedPlayback(null);
                                        }
                                        const path = wavOutputPath(if (current_rom_path.len != 0) current_rom_path.slice() else "") orelse {
                                            std.debug.print("No available WAV output slot (001-999 all exist)\n", .{});
                                            notifyFrontend(notifications, .failure, "NO AVAILABLE WAV SLOT", .{});
                                            continue;
                                        };
                                        const path_str = std.mem.sliceTo(&path, 0);
                                        wav_recorder = WavRecorder.start(path_str, AudioOutput.output_rate, AudioOutput.channels) catch |err| {
                                            std.debug.print("Failed to start WAV recording: {}\n", .{err});
                                            notifyFrontend(notifications, .failure, "FAILED TO START WAV RECORDING", .{});
                                            continue;
                                        };
                                        std.debug.print("WAV recording started: {s}\n", .{path_str});
                                        notifyFrontend(notifications, .success, "WAV RECORDING STARTED", .{});
                                    }
                                },
                                .screenshot => {
                                    if (frontend_ui.overlay == .help) continue;
                                    const path = screenshotOutputPath(if (current_rom_path.len != 0) current_rom_path.slice() else "") orelse {
                                        std.debug.print("No available screenshot slot (001-999 all exist)\n", .{});
                                        notifyFrontend(notifications, .failure, "NO AVAILABLE SCREENSHOT SLOT", .{});
                                        continue;
                                    };
                                    const path_str = std.mem.sliceTo(&path, 0);
                                    const framebuffer = machine.framebuffer();
                                    const active_width: u32 = machine.framebufferWidth();
                                    const framebuffer_height: u32 = @intCast(framebuffer.len / active_width);
                                    screenshot.saveBmp(path_str, framebuffer, active_width, framebuffer_height) catch |err| {
                                        std.debug.print("Failed to save screenshot: {}\n", .{err});
                                        notifyFrontend(notifications, .failure, "FAILED TO SAVE SCREENSHOT", .{});
                                        continue;
                                    };
                                    std.debug.print("Screenshot saved: {s}\n", .{path_str});
                                    notifyFrontend(notifications, .success, "SCREENSHOT SAVED", .{});
                                },
                                .toggle_fullscreen => {
                                    setFullscreenEnabled(window, !fullscreenEnabled(window), notifications);
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
                    if (!frontend_ui.emulationPaused() or !pressed) {
                        if (hotkey_binding) |binding| {
                            const mapped_key = binding.input orelse continue;
                            if (machine.asGenesis()) |gen| {
                                _ = gen.applyKeyboardBindings(&input_bindings, mapped_key, pressed);
                            } else {
                                applySmsKeyboardInput(&machine, mapped_key, pressed);
                            }
                        }
                    }
                },
                else => {},
            }
        }

        switch (file_dialog_state.take()) {
            .none => {},
            .canceled => {
                frontend_ui.overlay = if (frontend_ui.parent_overlay != .none) frontend_ui.parent_overlay else .home;
                frontend_ui.parent_overlay = .none;
            },
            .failed => |message| {
                frontend_ui.overlay = if (frontend_ui.parent_overlay != .none) frontend_ui.parent_overlay else .home;
                frontend_ui.parent_overlay = .none;
                std.debug.print("Open ROM dialog failed: {s}\n", .{message.slice()});
                notifyFrontend(
                    .{ .toast = &frontend_toast, .frame_number = frontend_frame_counter },
                    .failure,
                    "OPEN ROM DIALOG FAILED",
                    .{},
                );
            },
            .selected => |path| {
                frontend_ui.overlay = .none;
                frontend_ui.parent_overlay = .none;
                loadRomIntoMachine(
                    allocator,
                    &machine,
                    &input_bindings,
                    cli.timing_mode,
                    if (audio) |*a| a else null,
                    &gif_recorder,
                    &wav_recorder,
                    &frame_counter,
                    path.slice(),
                    .{ .toast = &frontend_toast, .frame_number = frontend_frame_counter },
                ) catch |err| {
                    std.debug.print("Failed to load ROM {s}: {}\n", .{ path.slice(), err });
                    notifyFrontend(
                        .{ .toast = &frontend_toast, .frame_number = frontend_frame_counter },
                        .failure,
                        "FAILED TO LOAD {s}",
                        .{std.fs.path.basename(path.slice())},
                    );
                    continue;
                };
                current_rom_path = path;
                rememberLoadedRom(
                    &frontend_config,
                    &input_bindings,
                    frontend_config_path,
                    .{ .toast = &frontend_toast, .frame_number = frontend_frame_counter },
                    path.slice(),
                );
                home_menu.clamp(&frontend_config);
                // ROM loaded successfully: dismiss any overlay and start emulating
                frontend_ui.overlay = .none;
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
        const sample_core_counters = shouldSampleCoreCounters(frontend_ui.overlay == .performance_hud, frame_counter, core_profile_frames_remaining);
        if (!emulation_paused) {
            const sys = machine.systemType();
            target_frame_ns = if (sys == .sms or sys == .gg)
                smsFrameDurationNs(machine.palMode())
            else
                frameDurationNs(machine.palMode(), machine.frameMasterCycles());
            const emulation_start = std.time.Instant.now() catch frame_timer;
            if (sample_core_counters) {
                machine.runFrameProfiled(&core_counters);
            } else {
                machine.runFrame();
            }
            frame_phases.emulation_ns = (std.time.Instant.now() catch emulation_start).since(emulation_start);
        } else if (debugger_state.active and debugger_state.running_to_breakpoint) {
            // Run instructions until a breakpoint is hit or one frame's worth of
            // instructions have executed (to keep the UI responsive).
            if (machine.testing()) |tv| {
                var testing_view = tv;
                var budget: u32 = 100_000;
                while (budget > 0) : (budget -= 1) {
                    _ = testing_view.runCpuCycles(1);
                    if (debugger_state.hasBreakpoint(machine.programCounter())) {
                        debugger_state.stopRunning();
                        break;
                    }
                }
            }
        } else if (debugger_state.active and debugger_state.shouldStep()) {
            // Single-step: run one M68K instruction
            if (machine.testing()) |tv| {
                var testing_view = tv;
                _ = testing_view.runCpuCycles(1);
            }
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
            if (machine.audioZ80()) |z80| {
                // Genesis: render audio from pending YM+PSG events
                const pending = machine.takePendingAudio();
                const wav_rec_ptr = if (wav_recorder) |*rec| rec else null;
                try a.handlePending(pending, z80, machine.palMode(), wav_rec_ptr);
            } else if (!emulation_paused) {
                if (machine.smsAudioBuffer()) |sms_samples| {
                    // SMS: audio already rendered in runFrame; queue to SDL
                    try a.queueRawSamples(sms_samples);
                }
            }
            frame_phases.audio_ns = (std.time.Instant.now() catch audio_start).since(audio_start);
        } else {
            const audio_start = std.time.Instant.now() catch frame_timer;
            machine.discardPendingAudio();
            frame_phases.audio_ns = (std.time.Instant.now() catch audio_start).since(audio_start);
        }
        const queued_audio_bytes: ?usize = if (audio) |*a|
            zsdl3.getAudioStreamQueued(a.stream) catch null
        else
            null;
        const audio_runtime_metrics: ?AudioRuntimeMetrics = if (audio) |*a|
            a.runtimeMetrics()
        else
            null;

        const framebuffer = machine.framebuffer();
        const fb_stride = machine.framebufferStride();
        const framebuffer_height: i32 = @intCast(framebuffer.len / @as(usize, fb_stride));
        const update_rect = zsdl3.Rect{
            .x = 0,
            .y = 0,
            .w = @intCast(fb_stride),
            .h = framebuffer_height,
        };
        const upload_start = std.time.Instant.now() catch frame_timer;
        _ = SDL_UpdateTexture(vdp_texture, &update_rect, @ptrCast(framebuffer.ptr), @intCast(@as(u32, fb_stride) * @sizeOf(u32)));
        frame_phases.upload_ns = (std.time.Instant.now() catch upload_start).since(upload_start);

        const draw_start = std.time.Instant.now() catch frame_timer;
        try zsdl3.setRenderDrawColor(renderer, .{ .r = 0x20, .g = 0x20, .b = 0x20, .a = 0xFF });
        try zsdl3.renderClear(renderer);
        const active_width = machine.framebufferWidth();
        const source_rect = zsdl3.FRect{
            .x = 0,
            .y = 0,
            .w = @floatFromInt(active_width),
            .h = @floatFromInt(framebuffer_height),
        };
        const viewport = try zsdl3.getRenderViewport(renderer);
        const dest_rect = computeVideoDestinationRect(
            viewport,
            active_width,
            framebuffer_height,
            frontend_config.video_aspect_mode,
            frontend_config.video_scale_mode,
        );
        try zsdl3.renderTexture(renderer, vdp_texture, &source_rect, &dest_rect);
        frontend_toast.advance(frontend_frame_counter);
        try renderFrontendOverlay(
            renderer,
            &frontend_ui,
            &home_menu,
            &settings_menu,
            &frontend_config,
            &save_manager,
            &frontend_toast,
            frontend_frame_counter,
            &binding_editor,
            &input_bindings,
            &machine,
            window,
            audio != null,
            current_audio_mode,
            persistent_state_slot,
            if (current_rom_path.len != 0) current_rom_path.slice() else null,
            config_file_path,
        );
        if (frontend_ui.overlay == .performance_hud) {
            const perf_viewport = try zsdl3.getRenderViewport(renderer);
            try zsdl3.setRenderDrawBlendMode(renderer, .blend);
            try renderPerformanceHud(renderer, perf_viewport, &performance_hud);
        }
        if (frontend_ui.overlay == .debugger and debugger_state.active) {
            const dbg_viewport = try zsdl3.getRenderViewport(renderer);
            try zsdl3.setRenderDrawBlendMode(renderer, .blend);
            if (machine.asGenesisConst()) |gen| try debugger_mod.render(renderer, dbg_viewport, gen, &debugger_state);
        }
        frame_phases.draw_ns = (std.time.Instant.now() catch draw_start).since(draw_start);
        const present_call_start = std.time.Instant.now() catch frame_timer;
        zsdl3.renderPresent(renderer);
        frame_phases.present_call_ns = (std.time.Instant.now() catch present_call_start).since(present_call_start);

        frame_counter += 1;
        frontend_frame_counter += 1;
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
                    if (audio_runtime_metrics) |metrics| metrics.queue_budget_bytes else null,
                    if (audio_runtime_metrics) |metrics| metrics.backlog_recoveries else null,
                    if (audio_runtime_metrics) |metrics| metrics.overflow_events else null,
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
    if (wav_recorder) |*rec| {
        if (audio) |*a| {
            a.syncRecordedPlayback(rec);
        }
        const duration = rec.getDurationSeconds();
        std.debug.print("WAV recording stopped on exit ({d} samples, {d:.2}s)\n", .{ rec.sample_count, duration });
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
        InputBindings.HotkeyBinding{ .input = .o, .modifiers = .{ .ctrl = true } },
        bindings.hotkeyBinding(.open_rom),
    );
    try std.testing.expectEqual(
        InputBindings.HotkeyBinding{ .input = .r, .modifiers = .{ .ctrl = true } },
        bindings.hotkeyBinding(.restart_rom),
    );
    try std.testing.expectEqual(
        InputBindings.HotkeyBinding{ .input = .r, .modifiers = .{ .ctrl = true, .shift = true } },
        bindings.hotkeyBinding(.reload_rom),
    );
    try std.testing.expectEqual(
        InputBindings.HotkeyAction.restart_rom,
        bindings.hotkeyForBinding(.{ .input = .r, .modifiers = .{ .ctrl = true } }).?,
    );
    try std.testing.expectEqual(
        InputBindings.HotkeyAction.reload_rom,
        bindings.hotkeyForBinding(.{ .input = .r, .modifiers = .{ .ctrl = true, .shift = true } }).?,
    );
    try std.testing.expect(bindings.hotkeyForBinding(.{ .input = .o, .modifiers = .{ .ctrl = true } }) == .open_rom);
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
    perf.noteFrame(17_500_000, 18_200_000, 16_700_000, 9_600, null, null, null, .{
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

    perf.noteFrame(17_500_000, 18_200_000, 16_700_000, null, null, null, null, .{
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
    perf.noteFrame(25_000_000, 25_000_000, 16_700_000, null, null, null, null, .{
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

    perf.noteFrame(20_600_000, 20_600_000, 16_700_000, null, null, null, null, .{}, null);
    try std.testing.expect(!isThresholdSlowFrame(&perf));

    perf.noteFrame(20_700_000, 20_700_000, 16_700_000, null, null, null, null, .{}, null);
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

    perf.noteFrame(20_700_000, 20_700_000, 16_700_000, null, null, null, null, .{ .emulation_ns = 19_500_000 }, null);
    var update = spikes.noteFrame(10, &perf);
    try std.testing.expect(update.log_frame);
    try std.testing.expect(update.summary == null);

    perf.noteFrame(25_000_000, 25_000_000, 16_700_000, null, null, null, null, .{ .emulation_ns = 23_800_000 }, null);
    update = spikes.noteFrame(11, &perf);
    try std.testing.expect(!update.log_frame);

    perf.noteFrame(28_800_000, 28_800_000, 16_700_000, null, null, null, null, .{ .emulation_ns = 27_000_000 }, null);
    update = spikes.noteFrame(12, &perf);
    try std.testing.expect(update.log_frame);

    perf.noteFrame(16_700_000, 16_700_000, 16_700_000, null, null, null, null, .{ .emulation_ns = 15_500_000 }, null);
    update = spikes.noteFrame(13, &perf);
    try std.testing.expect(!update.log_frame);

    perf.noteFrame(21_000_000, 21_000_000, 16_700_000, null, null, null, null, .{ .emulation_ns = 19_800_000 }, null);
    update = spikes.noteFrame(14, &perf);
    try std.testing.expect(update.log_frame);
}

test "performance spike window emits one-second summaries and resets" {
    var perf = PerformanceHudState{};
    var spikes = PerformanceSpikeLogState{};

    perf.noteFrame(260_000_000, 260_000_000, 250_000_000, 9_600, null, null, null, .{ .emulation_ns = 240_000_000 }, null);
    var update = spikes.noteFrame(100, &perf);
    try std.testing.expect(update.log_frame);
    try std.testing.expect(update.summary == null);

    perf.noteFrame(200_000_000, 200_000_000, 250_000_000, 9_600, null, null, null, .{ .emulation_ns = 180_000_000 }, null);
    update = spikes.noteFrame(101, &perf);
    try std.testing.expect(!update.log_frame);
    try std.testing.expect(update.summary == null);

    perf.noteFrame(280_000_000, 280_000_000, 250_000_000, 9_600, null, null, null, .{ .emulation_ns = 260_000_000 }, null);
    update = spikes.noteFrame(102, &perf);
    try std.testing.expect(update.log_frame);
    try std.testing.expect(update.summary == null);

    perf.noteFrame(240_000_000, 240_000_000, 250_000_000, 9_600, null, null, null, .{ .emulation_ns = 220_000_000 }, null);
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

    perf.noteFrame(250_200_000, 250_200_000, 250_000_000, 9_600, null, null, null, .{ .emulation_ns = 240_000_000 }, null);
    _ = spikes.noteFrame(200, &perf);

    perf.noteFrame(253_900_000, 253_900_000, 250_000_000, 9_600, null, null, null, .{ .emulation_ns = 243_000_000 }, null);
    _ = spikes.noteFrame(201, &perf);

    perf.noteFrame(250_000_000, 250_000_000, 250_000_000, 9_600, null, null, null, .{ .emulation_ns = 240_000_000 }, null);
    _ = spikes.noteFrame(202, &perf);

    perf.noteFrame(250_000_000, 250_000_000, 250_000_000, 9_600, null, null, null, .{ .emulation_ns = 240_000_000 }, null);
    const update = spikes.noteFrame(203, &perf);
    try std.testing.expect(!update.log_frame);
    try std.testing.expect(update.summary == null);
    try std.testing.expectEqual(@as(u64, 0), spikes.window_frame_count);
    try std.testing.expectEqual(@as(u64, 0), spikes.window_slow_frame_count);
}

test "performance hud tracks slow frames and queued audio" {
    var perf = PerformanceHudState{};
    const queue_budget_bytes = AudioOutput.queueBudgetBytes(AudioOutput.default_queue_budget_ms);

    perf.noteFrame(17_500_000, 18_200_000, 16_700_000, 9_600, queue_budget_bytes, 2, 7, .{
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
    try std.testing.expect(perf.queuedAudioBudgetNs() != null);
    try std.testing.expectEqual(@as(?usize, queue_budget_bytes), perf.last_audio_queue_budget_bytes);
    try std.testing.expectEqual(@as(?u64, 2), perf.last_audio_backlog_recoveries);
    try std.testing.expectEqual(@as(?u64, 7), perf.last_audio_overflow_events);
    try std.testing.expectEqual(@as(u64, 1000), perf.slowFramePercentTenths());

    perf.noteFrame(12_000_000, 16_700_000, 16_700_000, null, null, null, null, .{
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

    perf.noteFrame(17_000_000, 17_000_000, 16_700_000, null, null, null, null, .{ .emulation_ns = 15_000_000 }, .{
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
    perf.noteFrame(16_500_000, 16_500_000, 16_700_000, null, null, null, null, .{ .emulation_ns = 14_500_000 }, null);

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
    perf.noteFrame(20_700_000, 20_700_000, 16_700_000, null, null, null, null, .{ .emulation_ns = 19_500_000 }, null);

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
    var machine = SystemMachine{ .genesis = try Machine.initFromRomBytes(allocator, rom[0..]) };
    defer machine.deinit(allocator);
    const test_cfg_path = "test_sandopolis.cfg";
    var test_frontend_cfg = FrontendConfig{};

    _ = machine.genesis.applyKeyboardBindings(&bindings, .a, true);
    try std.testing.expectEqual(@as(u16, 0), machine.genesis.controllerPadState(0) & Io.Button.A);

    try std.testing.expect(handleBindingEditorKey(
        &ui,
        &editor,
        &bindings,
        &machine,
        test_cfg_path,
        &test_frontend_cfg,
        .f8,
        .{ .input = .f8 },
        true,
    ));
    try std.testing.expectEqual(Overlay.keyboard_editor, ui.overlay);
    try std.testing.expect(ui.emulationPaused());
    try std.testing.expect((machine.genesis.controllerPadState(0) & Io.Button.A) != 0);

    try std.testing.expect(handleBindingEditorKey(&ui, &editor, &bindings, &machine, test_cfg_path, &test_frontend_cfg, .@"return", .{ .input = .@"return" }, true));
    try std.testing.expect(editor.capture_mode);
    try std.testing.expect(handleBindingEditorKey(&ui, &editor, &bindings, &machine, test_cfg_path, &test_frontend_cfg, .v, .{ .input = .v }, true));
    try std.testing.expect(!editor.capture_mode);
    try std.testing.expectEqual(@as(?InputBindings.KeyboardInput, .v), bindings.keyboardBinding(0, .up));

    try std.testing.expect(handleBindingEditorKey(
        &ui,
        &editor,
        &bindings,
        &machine,
        test_cfg_path,
        &test_frontend_cfg,
        .f8,
        .{ .input = .f8 },
        true,
    ));
    try std.testing.expect(ui.overlay != .keyboard_editor);
}

test "binding editor clears hotkeys during capture" {
    const allocator = std.testing.allocator;
    const rom = [_]u8{0} ** 0x400;
    var ui = FrontendUi{};
    var editor = BindingEditorState{};
    var bindings = InputBindings.Bindings.defaults();
    var machine = SystemMachine{ .genesis = try Machine.initFromRomBytes(allocator, rom[0..]) };
    defer machine.deinit(allocator);
    const test_cfg_path = "test_sandopolis.cfg";
    var test_frontend_cfg = FrontendConfig{};

    try std.testing.expect(handleBindingEditorKey(
        &ui,
        &editor,
        &bindings,
        &machine,
        test_cfg_path,
        &test_frontend_cfg,
        .f8,
        .{ .input = .f8 },
        true,
    ));
    // Navigate to first hotkey entry (after all keyboard/gamepad sections + headers)
    const hotkey_start = 5 + InputBindings.player_count * InputBindings.all_actions.len * 2;
    editor.selected_index = hotkey_start;
    try std.testing.expect(handleBindingEditorKey(&ui, &editor, &bindings, &machine, test_cfg_path, &test_frontend_cfg, .@"return", .{ .input = .@"return" }, true));
    try std.testing.expect(handleBindingEditorKey(&ui, &editor, &bindings, &machine, test_cfg_path, &test_frontend_cfg, .delete, .{ .input = .delete }, true));
    try std.testing.expectEqual(InputBindings.HotkeyBinding{}, bindings.hotkeyBinding(.toggle_help));
}

test "binding editor captures modifier hotkeys" {
    const allocator = std.testing.allocator;
    const rom = [_]u8{0} ** 0x400;
    var ui = FrontendUi{};
    var editor = BindingEditorState{};
    var bindings = InputBindings.Bindings.defaults();
    var machine = SystemMachine{ .genesis = try Machine.initFromRomBytes(allocator, rom[0..]) };
    defer machine.deinit(allocator);
    const test_cfg_path = "test_sandopolis.cfg";
    var test_frontend_cfg = FrontendConfig{};

    try std.testing.expect(handleBindingEditorKey(
        &ui,
        &editor,
        &bindings,
        &machine,
        test_cfg_path,
        &test_frontend_cfg,
        .f8,
        .{ .input = .f8 },
        true,
    ));
    const hotkey_base = 5 + InputBindings.player_count * InputBindings.all_actions.len * 2;
    editor.selected_index = hotkey_base + @intFromEnum(InputBindings.HotkeyAction.reload_rom);
    try std.testing.expect(handleBindingEditorKey(&ui, &editor, &bindings, &machine, test_cfg_path, &test_frontend_cfg, .@"return", .{ .input = .@"return" }, true));
    try std.testing.expect(handleBindingEditorKey(
        &ui,
        &editor,
        &bindings,
        &machine,
        test_cfg_path,
        &test_frontend_cfg,
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

    var machine = SystemMachine{ .genesis = try Machine.init(allocator, rom_path) };
    defer machine.deinit(allocator);

    var bindings = InputBindings.Bindings.defaults();
    machine.applyControllerTypes(&bindings);
    const resolved_timing = resolveTimingMode(machine.romMetadata(), .auto);
    const resolved_region = resolveConsoleRegion(machine.romMetadata());
    machine.reset();
    machine.setPalMode(resolved_timing.pal_mode);
    machine.setConsoleIsOverseas(resolved_region.overseas);

    machine.genesis.writeWorkRamByte(0x20, 0x5A);
    var frame_counter: u32 = 42;
    machine.genesis.runMasterSlice(clock.m68kCyclesToMaster(4));

    try std.testing.expectEqual(@as(u32, 0x0000_0202), machine.programCounter());

    softResetCurrentMachine(&machine, &frame_counter, .{});

    try std.testing.expectEqual(@as(u8, 0x5A), machine.genesis.readWorkRamByte(0x20));
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

    var machine = SystemMachine{ .genesis = try Machine.init(allocator, rom_path) };
    defer machine.deinit(allocator);

    var bindings = InputBindings.Bindings.defaults();
    machine.applyControllerTypes(&bindings);
    const resolved_timing = resolveTimingMode(machine.romMetadata(), .auto);
    const resolved_region = resolveConsoleRegion(machine.romMetadata());
    machine.reset();
    machine.setPalMode(resolved_timing.pal_mode);
    machine.setConsoleIsOverseas(resolved_region.overseas);

    machine.genesis.writeWorkRamByte(0x20, 0x5A);
    var gif_recorder: ?GifRecorder = null;
    var wav_recorder: ?WavRecorder = null;
    var frame_counter: u32 = 42;

    try hardResetCurrentMachine(
        allocator,
        &machine,
        &bindings,
        .auto,
        null,
        &gif_recorder,
        &wav_recorder,
        &frame_counter,
        rom_path,
        .{},
    );

    try std.testing.expectEqual(@as(u8, 0x00), machine.genesis.readWorkRamByte(0x20));
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

    try audio.handlePending(std.mem.zeroes(PendingAudioFrames), &z80, false, null);
    try std.testing.expect(audio.startupMuteActive());

    z80.writeByte(0x7F11, 0x90);
    try std.testing.expect(z80.hasPendingAudibleEvents());

    // First frame with audible events starts warmup but stays muted
    try audio.handlePending(std.mem.zeroes(PendingAudioFrames), &z80, false, null);
    try std.testing.expect(audio.startupMuteActive());

    // Warmup requires several frames of audible activity before unmuting
    for (0..8) |_| {
        z80.writeByte(0x7F11, 0x90);
        try audio.handlePending(std.mem.zeroes(PendingAudioFrames), &z80, false, null);
    }
    try std.testing.expect(!audio.startupMuteActive());
}

test "audio backlog threshold trips at the queued audio budget" {
    const default_budget = AudioOutput.queueBudgetBytes(AudioOutput.default_queue_budget_ms);
    const widened_budget = AudioOutput.queueBudgetBytes(100);
    try std.testing.expect(!queueIsBacklogged(default_budget - 1));
    try std.testing.expect(queueIsBacklogged(default_budget));
    try std.testing.expect(!queueIsBackloggedForBudget(widened_budget - 1, widened_budget));
    try std.testing.expect(queueIsBackloggedForBudget(widened_budget, widened_budget));
}

test "audio playback shadow only records samples that have actually drained" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_dir_path);
    const wav_path = try std.fs.path.join(std.testing.allocator, &.{ tmp_dir_path, "shadow.wav" });
    defer std.testing.allocator.free(wav_path);

    var recorder = try WavRecorder.start(wav_path, AudioOutput.output_rate, AudioOutput.channels);
    var audio = AudioInit{
        .stream = @ptrFromInt(1),
        .output = AudioOutput.init(),
    };
    const queued = [_]i16{ 1, 2, 3, 4, 5, 6, 7, 8 };

    audio.appendPlaybackShadow(queued[0..]);
    audio.reconcilePlaybackShadow(4 * @sizeOf(i16), &recorder);

    try std.testing.expectEqual(@as(u32, 2), recorder.sample_count);
    try std.testing.expectEqual(@as(usize, 4), audio.playback_shadow_len);
    try std.testing.expectEqualSlices(i16, queued[4..], audio.playback_shadow[0..audio.playback_shadow_len]);

    audio.reconcilePlaybackShadow(0, &recorder);
    try std.testing.expectEqual(@as(u32, 4), recorder.sample_count);
    try std.testing.expectEqual(@as(usize, 0), audio.playback_shadow_len);

    recorder.finish();
}

test "audio playback shadow clamps to its mirror capacity instead of overflowing" {
    const allocator = std.testing.allocator;
    var audio = AudioInit{
        .stream = @ptrFromInt(1),
        .output = AudioOutput.init(),
    };

    const capacity = audio.playback_shadow.len;
    const oversized = try allocator.alloc(i16, capacity + 4);
    defer allocator.free(oversized);
    for (oversized, 0..) |*sample, index| {
        sample.* = @intCast(index);
    }

    audio.appendPlaybackShadow(oversized);

    try std.testing.expectEqual(capacity, audio.playback_shadow_len);
    try std.testing.expectEqual(@as(i16, 4), audio.playback_shadow[0]);
    try std.testing.expectEqual(@as(i16, @intCast(capacity + 3)), audio.playback_shadow[audio.playback_shadow_len - 1]);
}

test "quick state helper saves and restores machine state" {
    const allocator = std.testing.allocator;
    const rom = [_]u8{0} ** 0x400;

    var machine = SystemMachine{ .genesis = try Machine.initFromRomBytes(allocator, rom[0..]) };
    defer machine.deinit(allocator);

    var quick_state: ?SystemMachine.Snapshot = null;
    defer if (quick_state) |*state| state.deinit(allocator);
    var gif_recorder: ?GifRecorder = null;
    var wav_recorder: ?WavRecorder = null;
    var frame_counter: u32 = 42;

    machine.genesis.writeWorkRamByte(0x20, 0x5A);
    try std.testing.expect(handleQuickStateAction(allocator, .save_quick_state, &machine, &quick_state, null, &gif_recorder, &wav_recorder, &frame_counter, .{}));

    machine.genesis.writeWorkRamByte(0x20, 0x00);
    frame_counter = 99;
    try std.testing.expect(handleQuickStateAction(allocator, .load_quick_state, &machine, &quick_state, null, &gif_recorder, &wav_recorder, &frame_counter, .{}));

    try std.testing.expectEqual(@as(u8, 0x5A), machine.genesis.readWorkRamByte(0x20));
    try std.testing.expectEqual(@as(u32, 0), frame_counter);
}

test "persistent state helper saves and restores machine state" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rom = [_]u8{0} ** 0x400;
    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);
    const rom_path = try std.fs.path.join(allocator, &.{ dir_path, "frontend.bin" });
    defer allocator.free(rom_path);

    var machine = SystemMachine{ .genesis = try Machine.initFromRomBytes(allocator, rom[0..]) };
    defer machine.deinit(allocator);

    var gif_recorder: ?GifRecorder = null;
    var wav_recorder: ?WavRecorder = null;
    var frame_counter: u32 = 42;
    var persistent_state_slot: u8 = StateFile.default_persistent_state_slot;
    const slot1_state_path = try rom_paths.statePath(allocator, rom_path, persistent_state_slot);
    defer allocator.free(slot1_state_path);

    machine.genesis.writeWorkRamByte(0x20, 0x5A);
    try std.testing.expectEqual(PersistentStateActionResult.handled, handlePersistentStateAction(allocator, .save_state_file, &machine, rom_path, &persistent_state_slot, null, &gif_recorder, &wav_recorder, &frame_counter, .{}));
    try std.fs.cwd().access(slot1_state_path, .{});

    machine.genesis.writeWorkRamByte(0x20, 0x00);
    frame_counter = 99;
    try std.testing.expectEqual(PersistentStateActionResult.loaded_machine, handlePersistentStateAction(allocator, .load_state_file, &machine, rom_path, &persistent_state_slot, null, &gif_recorder, &wav_recorder, &frame_counter, .{}));

    try std.testing.expectEqual(@as(u8, 0x5A), machine.genesis.readWorkRamByte(0x20));
    try std.testing.expectEqual(@as(u32, 0), frame_counter);
}

test "persistent state helper cycles slots and keeps files separate" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rom = [_]u8{0} ** 0x400;
    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);
    const rom_path = try std.fs.path.join(allocator, &.{ dir_path, "frontend.bin" });
    defer allocator.free(rom_path);

    var machine = SystemMachine{ .genesis = try Machine.initFromRomBytes(allocator, rom[0..]) };
    defer machine.deinit(allocator);

    var gif_recorder: ?GifRecorder = null;
    var wav_recorder: ?WavRecorder = null;
    var frame_counter: u32 = 17;
    var persistent_state_slot: u8 = StateFile.default_persistent_state_slot;

    machine.genesis.writeWorkRamByte(0x20, 0x11);
    try std.testing.expectEqual(PersistentStateActionResult.handled, handlePersistentStateAction(allocator, .save_state_file, &machine, rom_path, &persistent_state_slot, null, &gif_recorder, &wav_recorder, &frame_counter, .{}));

    try std.testing.expectEqual(PersistentStateActionResult.handled, handlePersistentStateAction(allocator, .next_state_slot, &machine, rom_path, &persistent_state_slot, null, &gif_recorder, &wav_recorder, &frame_counter, .{}));
    try std.testing.expectEqual(@as(u8, 2), persistent_state_slot);

    machine.genesis.writeWorkRamByte(0x20, 0x22);
    try std.testing.expectEqual(PersistentStateActionResult.handled, handlePersistentStateAction(allocator, .save_state_file, &machine, rom_path, &persistent_state_slot, null, &gif_recorder, &wav_recorder, &frame_counter, .{}));

    machine.genesis.writeWorkRamByte(0x20, 0x00);
    frame_counter = 99;
    try std.testing.expectEqual(PersistentStateActionResult.loaded_machine, handlePersistentStateAction(allocator, .load_state_file, &machine, rom_path, &persistent_state_slot, null, &gif_recorder, &wav_recorder, &frame_counter, .{}));
    try std.testing.expectEqual(@as(u8, 0x22), machine.genesis.readWorkRamByte(0x20));
    try std.testing.expectEqual(@as(u32, 0), frame_counter);

    try std.testing.expectEqual(PersistentStateActionResult.handled, handlePersistentStateAction(allocator, .next_state_slot, &machine, rom_path, &persistent_state_slot, null, &gif_recorder, &wav_recorder, &frame_counter, .{}));
    try std.testing.expectEqual(@as(u8, 3), persistent_state_slot);
    try std.testing.expectEqual(PersistentStateActionResult.handled, handlePersistentStateAction(allocator, .next_state_slot, &machine, rom_path, &persistent_state_slot, null, &gif_recorder, &wav_recorder, &frame_counter, .{}));
    try std.testing.expectEqual(@as(u8, 1), persistent_state_slot);

    machine.genesis.writeWorkRamByte(0x20, 0x00);
    frame_counter = 55;
    try std.testing.expectEqual(PersistentStateActionResult.loaded_machine, handlePersistentStateAction(allocator, .load_state_file, &machine, rom_path, &persistent_state_slot, null, &gif_recorder, &wav_recorder, &frame_counter, .{}));
    try std.testing.expectEqual(@as(u8, 0x11), machine.genesis.readWorkRamByte(0x20));
    try std.testing.expectEqual(@as(u32, 0), frame_counter);
}

test "persistent state load sync exits home screen and updates current rom path" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rom = [_]u8{0} ** 0x400;
    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);
    const rom_path = try std.fs.path.join(allocator, &.{ dir_path, "frontend.bin" });
    defer allocator.free(rom_path);

    var saved_machine = try Machine.initFromRomBytes(allocator, rom[0..]);
    defer saved_machine.deinit(allocator);
    saved_machine.bus.replaceStoragePaths(allocator, null, try allocator.dupe(u8, rom_path));
    saved_machine.writeWorkRamByte(0x20, 0x5A);

    const state_path = try rom_paths.statePath(allocator, rom_path, StateFile.default_persistent_state_slot);
    defer allocator.free(state_path);
    try StateFile.saveToFile(&saved_machine, state_path);

    var machine = SystemMachine{ .genesis = try Machine.initFromRomBytes(allocator, rom[0..]) };
    defer machine.deinit(allocator);

    var gif_recorder: ?GifRecorder = null;
    var wav_recorder: ?WavRecorder = null;
    var frame_counter: u32 = 0;
    var persistent_state_slot: u8 = StateFile.default_persistent_state_slot;
    var ui = FrontendUi{ .overlay = .home };
    var current_rom_path = DialogPathCopy{};

    try std.testing.expectEqual(
        PersistentStateActionResult.loaded_machine,
        handlePersistentStateAction(
            allocator,
            .load_state_file,
            &machine,
            rom_path,
            &persistent_state_slot,
            null,
            &gif_recorder,
            &wav_recorder,
            &frame_counter,
            .{},
        ),
    );
    syncFrontendAfterPersistentStateLoad(&ui, &current_rom_path, &machine);

    try std.testing.expectEqual(@as(u8, 0x5A), machine.genesis.readWorkRamByte(0x20));
    try std.testing.expect(ui.overlay != .home);
    try std.testing.expectEqualStrings(rom_path, current_rom_path.slice());
}

test "save manager metadata tracks slot files and deletions" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rom = [_]u8{0} ** 0x400;
    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);
    const rom_path = try std.fs.path.join(allocator, &.{ dir_path, "frontend.bin" });
    defer allocator.free(rom_path);
    const slot2_state_path = try rom_paths.statePath(allocator, rom_path, 2);
    defer allocator.free(slot2_state_path);
    const slot2_preview_path = try resolveStatePreviewPath(allocator, slot2_state_path);
    defer allocator.free(slot2_preview_path);

    var machine = SystemMachine{ .genesis = try Machine.initFromRomBytes(allocator, rom[0..]) };
    defer machine.deinit(allocator);

    var gif_recorder: ?GifRecorder = null;
    var wav_recorder: ?WavRecorder = null;
    var frame_counter: u32 = 0;
    var persistent_state_slot: u8 = StateFile.default_persistent_state_slot;

    machine.genesis.writeWorkRamByte(0x20, 0x11);
    try std.testing.expectEqual(PersistentStateActionResult.handled, handlePersistentStateAction(
        allocator,
        .save_state_file,
        &machine,
        rom_path,
        &persistent_state_slot,
        null,
        &gif_recorder,
        &wav_recorder,
        &frame_counter,
        .{},
    ));

    persistent_state_slot = 2;
    machine.genesis.writeWorkRamByte(0x20, 0x22);
    try std.testing.expectEqual(PersistentStateActionResult.handled, handlePersistentStateAction(
        allocator,
        .save_state_file,
        &machine,
        rom_path,
        &persistent_state_slot,
        null,
        &gif_recorder,
        &wav_recorder,
        &frame_counter,
        .{},
    ));

    var save_manager = SaveManagerState{};
    try save_manager.refresh(allocator, &machine.genesis, rom_path);

    try std.testing.expect(save_manager.slotMetadata(1).exists);
    try std.testing.expect(save_manager.slotMetadata(2).exists);
    try std.testing.expect(!save_manager.slotMetadata(3).exists);
    try std.testing.expect(save_manager.slotMetadata(1).preview.available);
    try std.testing.expect(save_manager.slotMetadata(2).preview.available);
    try std.testing.expect(save_manager.slotMetadata(1).size_bytes != 0);
    try std.testing.expect(save_manager.slotMetadata(1).modified_ns != 0);
    try std.testing.expectEqualStrings("slot1.state", std.fs.path.basename(save_manager.slotMetadata(1).path.slice()));
    try std.testing.expectEqualStrings("slot2.state", std.fs.path.basename(save_manager.slotMetadata(2).path.slice()));
    try std.fs.cwd().access(slot2_preview_path, .{});

    try std.testing.expect(deletePersistentStateFile(allocator, &machine, rom_path, 2, .{}));
    try save_manager.refresh(allocator, &machine.genesis, rom_path);
    try std.testing.expect(!save_manager.slotMetadata(2).exists);
    try std.testing.expect(!save_manager.slotMetadata(2).preview.available);
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().access(slot2_preview_path, .{}));
}

test "save state preview sidecar round-trips sampled pixels" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);
    const preview_path = try std.fs.path.join(allocator, &.{ dir_path, "slot1.state.preview" });
    defer allocator.free(preview_path);

    var framebuffer = [_]u32{0} ** (Vdp.framebuffer_width * 224);
    for (0..224) |y| {
        for (0..Vdp.framebuffer_width) |x| {
            framebuffer[y * Vdp.framebuffer_width + x] =
                0xFF00_0000 |
                (@as(u32, @intCast(y)) << 8) |
                @as(u32, @intCast(x & 0xFF));
        }
    }

    const preview = SaveStatePreview.captureFromFramebuffer(framebuffer[0..]);
    try std.testing.expect(preview.available);
    try std.testing.expectEqual(framebuffer[0], preview.pixels[0]);
    try std.testing.expectEqual(framebuffer[(224 - 1) * Vdp.framebuffer_width + (Vdp.framebuffer_width - 1)], preview.pixels[save_state_preview_pixel_count - 1]);

    try preview.saveToFile(preview_path);
    const loaded = try SaveStatePreview.loadFromFile(preview_path);
    try std.testing.expect(loaded.available);
    try std.testing.expectEqualSlices(u32, preview.pixels[0..], loaded.pixels[0..]);
}

test "frontend config tracks recent roms and last directory" {
    var config = FrontendConfig{};

    config.noteLoadedRom("roms/a.bin");
    config.noteLoadedRom("roms/b.bin");
    config.noteLoadedRom("roms/a.bin");

    try std.testing.expectEqualStrings("roms", config.last_open_dir.slice());
    try std.testing.expectEqual(@as(usize, 2), config.recent_rom_count);
    try std.testing.expectEqualStrings("roms/a.bin", config.recentRom(0));
    try std.testing.expectEqualStrings("roms/b.bin", config.recentRom(1));
}

test "frontend config parsing preserves recent rom order" {
    const contents =
        \\last_open_dir = roms
        \\video_aspect = 4:3
        \\video_scale = whole_pixels
        \\audio_mode = unfiltered-mix
        \\audio_queue_ms = 80
        \\recent_rom = roms/b.bin
        \\recent_rom = roms/a.bin
    ;
    const config = try FrontendConfig.parseContents(contents);

    try std.testing.expectEqualStrings("roms", config.last_open_dir.slice());
    try std.testing.expectEqual(VideoAspectMode.four_three, config.video_aspect_mode);
    try std.testing.expectEqual(VideoScaleMode.whole_pixels, config.video_scale_mode);
    try std.testing.expectEqual(AudioOutput.RenderMode.unfiltered_mix, config.audio_render_mode);
    try std.testing.expectEqual(@as(u16, 80), config.audio_queue_ms);
    try std.testing.expectEqual(@as(usize, 2), config.recent_rom_count);
    try std.testing.expectEqualStrings("roms/b.bin", config.recentRom(0));
    try std.testing.expectEqualStrings("roms/a.bin", config.recentRom(1));
}

test "home menu wraps across dynamic recent rom entries" {
    var config = FrontendConfig{};
    config.noteLoadedRom("roms/a.bin");
    config.noteLoadedRom("roms/b.bin");

    var menu = HomeMenuState{};
    switch (menu.currentAction(&config)) {
        .open_rom => {},
        else => try std.testing.expect(false),
    }

    menu.move(-1, &config);
    switch (menu.currentAction(&config)) {
        .quit => {},
        else => try std.testing.expect(false),
    }

    menu.move(1, &config);
    menu.move(1, &config);
    switch (menu.currentAction(&config)) {
        .recent_rom => |index| try std.testing.expectEqual(@as(usize, 0), index),
        else => try std.testing.expect(false),
    }
}

test "home screen gamepad navigation loads recent rom entries" {
    var config = FrontendConfig{};
    config.noteLoadedRom("roms/a.bin");
    config.noteLoadedRom("roms/b.bin");

    var ui = FrontendUi{ .overlay = .home };
    var menu = HomeMenuState{};
    var settings = SettingsMenuState{};

    switch (handleHomeScreenGamepadInput(&ui, &menu, &settings, &config, .dpad_down, true)) {
        .consumed => {},
        else => try std.testing.expect(false),
    }
    switch (menu.currentAction(&config)) {
        .recent_rom => |index| try std.testing.expectEqual(@as(usize, 0), index),
        else => try std.testing.expect(false),
    }
    switch (handleHomeScreenGamepadInput(&ui, &menu, &settings, &config, .south, true)) {
        .load_recent => |index| try std.testing.expectEqual(@as(usize, 0), index),
        else => try std.testing.expect(false),
    }

    // Reset to home for next sub-test
    ui.overlay = .home;
    switch (handleHomeScreenGamepadInput(&ui, &menu, &settings, &config, .west, true)) {
        .consumed => {},
        else => try std.testing.expect(false),
    }
    try std.testing.expectEqual(Overlay.settings, ui.overlay);
    ui.closeSettings();

    switch (handleHomeScreenGamepadInput(&ui, &menu, &settings, &config, .north, true)) {
        .consumed => {},
        else => try std.testing.expect(false),
    }
    try std.testing.expectEqual(Overlay.help, ui.overlay);
}

test "frontend toast visibility expires after its frame window" {
    var toast = FrontendToast{};
    toast.show(.success, "STATE FILE SAVED", 25);

    try std.testing.expect(toast.visible(25));
    try std.testing.expect(toast.visible(25 + frontend_toast_duration_frames - 1));
    try std.testing.expect(!toast.visible(25 + frontend_toast_duration_frames));
}

test "frontend ui treats save manager as a paused overlay" {
    var ui = FrontendUi{ .overlay = .save_manager };
    try std.testing.expect(ui.emulationPaused());
}

test "frontend ui treats settings as a paused overlay" {
    var ui = FrontendUi{ .overlay = .settings };
    try std.testing.expect(ui.emulationPaused());
}

test "settings menu wraps and audio render mode cycles" {
    var settings = SettingsMenuState{};
    try std.testing.expectEqual(SettingsMenuAction.video_aspect_mode, settings.currentAction());

    settings.move(-1);
    try std.testing.expectEqual(SettingsMenuAction.close, settings.currentAction());

    try std.testing.expectEqual(VideoAspectMode.four_three, VideoAspectMode.stretch.cycle(1));
    try std.testing.expectEqual(VideoAspectMode.square_pixels, VideoAspectMode.stretch.cycle(-1));
    try std.testing.expectEqual(VideoScaleMode.whole_pixels, VideoScaleMode.fit.cycle(1));
    try std.testing.expectEqual(VideoScaleMode.fit, VideoScaleMode.whole_pixels.cycle(1));
    try std.testing.expectEqual(AudioOutput.RenderMode.ym_only, AudioOutput.RenderMode.normal.cycle(1));
    try std.testing.expectEqual(AudioOutput.RenderMode.unfiltered_mix, AudioOutput.RenderMode.normal.cycle(-1));
    try std.testing.expectEqual(AudioOutput.RenderMode.normal, AudioOutput.RenderMode.unfiltered_mix.cycle(1));
}

test "video destination rect honors aspect and integer scaling" {
    const viewport = zsdl3.Rect{ .x = 0, .y = 0, .w = 1280, .h = 720 };

    const stretch = computeVideoDestinationRect(viewport, 320, 224, .stretch, .fit);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), stretch.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), stretch.y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1280.0), stretch.w, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 720.0), stretch.h, 0.001);

    const four_three = computeVideoDestinationRect(viewport, 320, 224, .four_three, .fit);
    try std.testing.expectApproxEqAbs(@as(f32, 160.0), four_three.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), four_three.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 960.0), four_three.w, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 720.0), four_three.h, 0.01);

    const integer_scaled = computeVideoDestinationRect(viewport, 320, 224, .square_pixels, .whole_pixels);
    try std.testing.expectApproxEqAbs(@as(f32, 160.0), integer_scaled.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 24.0), integer_scaled.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 960.0), integer_scaled.w, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 672.0), integer_scaled.h, 0.01);
}

test "settings actions persist frontend video settings" {
    var config = FrontendConfig{};

    // Test cycling video aspect mode
    try std.testing.expectEqual(VideoAspectMode.stretch, config.video_aspect_mode);
    config.video_aspect_mode = config.video_aspect_mode.cycle(1);
    try std.testing.expectEqual(VideoAspectMode.four_three, config.video_aspect_mode);

    // Test cycling video scale mode
    try std.testing.expectEqual(VideoScaleMode.fit, config.video_scale_mode);
    config.video_scale_mode = config.video_scale_mode.cycle(1);
    try std.testing.expectEqual(VideoScaleMode.whole_pixels, config.video_scale_mode);
}

test "guide button toggles pause and resumes overlays" {
    const allocator = std.testing.allocator;
    const rom = [_]u8{0} ** 0x400;

    var machine = SystemMachine{ .genesis = try Machine.initFromRomBytes(allocator, rom[0..]) };
    defer machine.deinit(allocator);

    var ui = FrontendUi{};
    var menu = HomeMenuState{};
    var settings = SettingsMenuState{};
    var config = FrontendConfig{};
    var save_manager = SaveManagerState{};
    var performance_hud = PerformanceHudState{};
    var performance_spike_log = PerformanceSpikeLogState{};
    var current_audio_mode: AudioOutput.RenderMode = .normal;
    var persistent_state_slot: u8 = StateFile.default_persistent_state_slot;
    var gif_recorder: ?GifRecorder = null;
    var wav_recorder: ?WavRecorder = null;
    var frame_counter: u32 = 0;
    var core_profile_frames_remaining: u32 = 0;
    var dbg_state = debugger_mod.DebuggerState{};
    var test_bindings = InputBindings.Bindings.defaults();
    const fake_window: *zsdl3.Window = @ptrFromInt(1);
    var test_font = ui_render.Font{};
    const fake_renderer: *zsdl3.Renderer = @ptrFromInt(2);

    switch (handleFrontendGamepadInput(
        &ui,
        &menu,
        &settings,
        &config,
        "frontend.cfg",
        &save_manager,
        allocator,
        &machine,
        null,
        &persistent_state_slot,
        &gif_recorder,
        &wav_recorder,
        null,
        &current_audio_mode,
        &performance_hud,
        &performance_spike_log,
        &core_profile_frames_remaining,
        fake_window,
        &frame_counter,
        &dbg_state,
        &test_bindings,
        &test_font,
        fake_renderer,
        .guide,
        true,
        .{},
    )) {
        .consumed => {},
        else => try std.testing.expect(false),
    }
    try std.testing.expectEqual(Overlay.pause, ui.overlay);

    // Open help from pause, then press guide to resume
    ui.openHelp();
    switch (handleFrontendGamepadInput(
        &ui,
        &menu,
        &settings,
        &config,
        "frontend.cfg",
        &save_manager,
        allocator,
        &machine,
        null,
        &persistent_state_slot,
        &gif_recorder,
        &wav_recorder,
        null,
        &current_audio_mode,
        &performance_hud,
        &performance_spike_log,
        &core_profile_frames_remaining,
        fake_window,
        &frame_counter,
        &dbg_state,
        &test_bindings,
        &test_font,
        fake_renderer,
        .guide,
        true,
        .{},
    )) {
        .consumed => {},
        else => try std.testing.expect(false),
    }
    try std.testing.expectEqual(Overlay.none, ui.overlay);
}

test "save manager gamepad controls save load delete and close" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rom = [_]u8{0} ** 0x400;
    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);
    const rom_path = try std.fs.path.join(allocator, &.{ dir_path, "frontend.bin" });
    defer allocator.free(rom_path);
    const slot1_state_path = try rom_paths.statePath(allocator, rom_path, 1);
    defer allocator.free(slot1_state_path);

    var machine = SystemMachine{ .genesis = try Machine.initFromRomBytes(allocator, rom[0..]) };
    defer machine.deinit(allocator);

    var ui = FrontendUi{ .overlay = .save_manager, .parent_overlay = .pause };
    var save_manager = SaveManagerState{};
    var persistent_state_slot: u8 = StateFile.default_persistent_state_slot;
    var gif_recorder: ?GifRecorder = null;
    var wav_recorder: ?WavRecorder = null;
    var frame_counter: u32 = 5;

    machine.genesis.writeWorkRamByte(0x20, 0x44);
    switch (handleSaveManagerGamepadInput(
        &ui,
        &save_manager,
        allocator,
        &machine,
        rom_path,
        &persistent_state_slot,
        &gif_recorder,
        &wav_recorder,
        null,
        &frame_counter,
        .west,
        true,
        .{},
    )) {
        .consumed => {},
        else => try std.testing.expect(false),
    }
    try std.fs.cwd().access(slot1_state_path, .{});
    try std.testing.expect(save_manager.slotMetadata(1).exists);

    machine.genesis.writeWorkRamByte(0x20, 0x00);
    frame_counter = 99;
    switch (handleSaveManagerGamepadInput(
        &ui,
        &save_manager,
        allocator,
        &machine,
        rom_path,
        &persistent_state_slot,
        &gif_recorder,
        &wav_recorder,
        null,
        &frame_counter,
        .south,
        true,
        .{},
    )) {
        .consumed => {},
        else => try std.testing.expect(false),
    }
    try std.testing.expectEqual(@as(u8, 0x44), machine.genesis.readWorkRamByte(0x20));
    try std.testing.expectEqual(@as(u32, 0), frame_counter);

    switch (handleSaveManagerGamepadInput(
        &ui,
        &save_manager,
        allocator,
        &machine,
        rom_path,
        &persistent_state_slot,
        &gif_recorder,
        &wav_recorder,
        null,
        &frame_counter,
        .right_shoulder,
        true,
        .{},
    )) {
        .consumed => {},
        else => try std.testing.expect(false),
    }
    try std.testing.expectEqual(@as(u8, 2), persistent_state_slot);

    switch (handleSaveManagerGamepadInput(
        &ui,
        &save_manager,
        allocator,
        &machine,
        rom_path,
        &persistent_state_slot,
        &gif_recorder,
        &wav_recorder,
        null,
        &frame_counter,
        .left_shoulder,
        true,
        .{},
    )) {
        .consumed => {},
        else => try std.testing.expect(false),
    }
    try std.testing.expectEqual(@as(u8, 1), persistent_state_slot);

    // First press initiates delete confirmation
    switch (handleSaveManagerGamepadInput(
        &ui,
        &save_manager,
        allocator,
        &machine,
        rom_path,
        &persistent_state_slot,
        &gif_recorder,
        &wav_recorder,
        null,
        &frame_counter,
        .north,
        true,
        .{},
    )) {
        .consumed => {},
        else => try std.testing.expect(false),
    }
    try std.testing.expect(ui.delete_confirm_pending);
    try std.testing.expect(save_manager.slotMetadata(1).exists); // Not deleted yet

    // Second press confirms delete
    switch (handleSaveManagerGamepadInput(
        &ui,
        &save_manager,
        allocator,
        &machine,
        rom_path,
        &persistent_state_slot,
        &gif_recorder,
        &wav_recorder,
        null,
        &frame_counter,
        .north,
        true,
        .{},
    )) {
        .consumed => {},
        else => try std.testing.expect(false),
    }
    try std.testing.expect(!ui.delete_confirm_pending);
    try std.testing.expect(!save_manager.slotMetadata(1).exists);
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().access(slot1_state_path, .{}));

    switch (handleSaveManagerGamepadInput(
        &ui,
        &save_manager,
        allocator,
        &machine,
        rom_path,
        &persistent_state_slot,
        &gif_recorder,
        &wav_recorder,
        null,
        &frame_counter,
        .east,
        true,
        .{},
    )) {
        .consumed => {},
        else => try std.testing.expect(false),
    }
    try std.testing.expectEqual(Overlay.pause, ui.overlay);
}

test "file dialog state records selected paths and failures" {
    var dialog = FileDialogState{};
    try std.testing.expect(dialog.begin(null));
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

    try std.testing.expect(dialog.begin("/tmp"));
    dialog.finishFailed("FAILED");
    const failed = dialog.take();
    switch (failed) {
        .failed => |message| try std.testing.expectEqualStrings("FAILED", message.slice()),
        else => try std.testing.expect(false),
    }
    try std.testing.expectEqualStrings("/tmp", std.mem.span(dialog.defaultLocation().?));
}

test "file dialog state records cancellations" {
    var dialog = FileDialogState{};
    try std.testing.expect(dialog.begin(null));
    dialog.finishCanceled();
    switch (dialog.take()) {
        .canceled => {},
        else => try std.testing.expect(false),
    }
    try std.testing.expect(dialog.begin(null));
}

test "dialog path copy truncates paths exceeding buffer capacity" {
    var path_copy = DialogPathCopy{};
    const long_path = "a" ** (std.fs.max_path_bytes + 100);
    path_copy.set(long_path);
    try std.testing.expectEqual(std.fs.max_path_bytes, path_copy.len);
    try std.testing.expectEqual(std.fs.max_path_bytes, path_copy.slice().len);
    for (path_copy.slice()) |c| {
        try std.testing.expectEqual(@as(u8, 'a'), c);
    }
}

test "dialog path copy handles exact buffer capacity" {
    var path_copy = DialogPathCopy{};
    const exact_path = "b" ** std.fs.max_path_bytes;
    path_copy.set(exact_path);
    try std.testing.expectEqual(std.fs.max_path_bytes, path_copy.len);
}

test "dialog path copy handles normal paths" {
    var path_copy = DialogPathCopy{};
    const normal_path = "/home/user/roms/game.bin";
    path_copy.set(normal_path);
    try std.testing.expectEqual(normal_path.len, path_copy.len);
    try std.testing.expectEqualStrings(normal_path, path_copy.slice());
}

test "frame duration uses console master clock" {
    try std.testing.expectEqual(@as(u64, 16_688_154), frameDurationNs(false, clock.ntsc_master_cycles_per_frame));
    try std.testing.expectEqual(@as(u64, 20_120_133), frameDurationNs(true, clock.pal_master_cycles_per_frame));
}

test "frame duration accepts interlace-sized fields" {
    const interlace_ntsc_master_cycles = clock.ntsc_master_cycles_per_frame + clock.ntsc_master_cycles_per_line;
    try std.testing.expectEqual(@as(u64, 16_751_849), frameDurationNs(false, interlace_ntsc_master_cycles));
}

test "sms frame duration targets 60 Hz NTSC and 50 Hz PAL" {
    const ntsc_ns = smsFrameDurationNs(false);
    const pal_ns = smsFrameDurationNs(true);
    // NTSC: ~16.69 ms (59.9 Hz)
    try std.testing.expect(ntsc_ns > 16_600_000 and ntsc_ns < 16_800_000);
    // PAL: ~20.13 ms (49.7 Hz)
    try std.testing.expect(pal_ns > 20_000_000 and pal_ns < 20_200_000);
}

test "audio-enabled runs do not use uncapped boot frames" {
    try std.testing.expectEqual(@as(u32, 0), uncappedBootFrames(true));
    try std.testing.expectEqual(@as(u32, 240), uncappedBootFrames(false));
}

const CliTestResult = struct {
    config: CliConfig,

    fn deinit(self: CliTestResult) void {
        if (self.config.rom_path) |p| std.testing.allocator.free(p);
        if (self.config.renderer_name) |p| std.testing.allocator.free(p);
        if (self.config.config_path) |p| std.testing.allocator.free(p);
    }
};

fn runCliTest(args: []const []const u8) !CliTestResult {
    const chilli = @import("chilli");
    var config = CliConfig{};
    const cmd = try createCliCommand(std.testing.allocator);
    defer cmd.deinit();
    var failed_cmd: ?*const chilli.Command = null;
    try cmd.execute(args, @ptrCast(&config), &failed_cmd);
    return .{ .config = config };
}

test "cli parser accepts audio mode before rom path" {
    const result = try runCliTest(&.{ "--audio-mode=psg-only", "roms/test.bin" });
    defer result.deinit();
    try std.testing.expectEqualStrings("roms/test.bin", result.config.rom_path.?);
    try std.testing.expectEqual(AudioOutput.RenderMode.psg_only, result.config.audio_mode);
    try std.testing.expect(result.config.audio_mode_overridden);
}

test "cli parser accepts renderer override before rom path" {
    const result = try runCliTest(&.{ "--renderer=software", "roms/test.bin" });
    defer result.deinit();
    try std.testing.expectEqualStrings("roms/test.bin", result.config.rom_path.?);
    try std.testing.expectEqualStrings("software", result.config.renderer_name.?);
    try std.testing.expectEqual(AudioOutput.RenderMode.normal, result.config.audio_mode);
    try std.testing.expect(!result.config.audio_mode_overridden);
    try std.testing.expect(!result.config.audio_queue_ms_overridden);
}

test "cli parser accepts config override" {
    const result = try runCliTest(&.{ "--config=custom/sandopolis.cfg", "roms/test.bin" });
    defer result.deinit();
    try std.testing.expectEqualStrings("roms/test.bin", result.config.rom_path.?);
    try std.testing.expectEqualStrings("custom/sandopolis.cfg", result.config.config_path.?);
}

test "cli parser accepts version flag without starting the emulator" {
    const result = try runCliTest(&.{"--version"});
    defer result.deinit();
    try std.testing.expect(result.config.show_version);
    try std.testing.expect(!result.config.should_run);
}

test "cli version summary includes git branch and hash" {
    const expected = std.fmt.comptimePrint("{s} ({s}@{s})", .{
        build_options.version,
        build_options.git_branch,
        build_options.git_hash,
    });
    try std.testing.expectEqualStrings(expected, cli_module.version_summary);
}

test "cli parser accepts pal timing override" {
    const result = try runCliTest(&.{ "--pal", "roms/test.bin" });
    defer result.deinit();
    try std.testing.expectEqualStrings("roms/test.bin", result.config.rom_path.?);
    try std.testing.expectEqual(TimingModeOption.pal, result.config.timing_mode);
}

test "cli parser accepts ntsc timing override" {
    const result = try runCliTest(&.{ "--ntsc", "roms/test.bin" });
    defer result.deinit();
    try std.testing.expectEqualStrings("roms/test.bin", result.config.rom_path.?);
    try std.testing.expectEqual(TimingModeOption.ntsc, result.config.timing_mode);
}

test "cli parser accepts spaced audio mode after rom path" {
    const result = try runCliTest(&.{ "roms/test.bin", "--audio-mode", "unfiltered-mix" });
    defer result.deinit();
    try std.testing.expectEqualStrings("roms/test.bin", result.config.rom_path.?);
    try std.testing.expectEqual(AudioOutput.RenderMode.unfiltered_mix, result.config.audio_mode);
    try std.testing.expect(result.config.audio_mode_overridden);
}

test "cli parser accepts audio queue override" {
    const result = try runCliTest(&.{ "--audio-queue-ms=80", "roms/test.bin" });
    defer result.deinit();
    try std.testing.expectEqualStrings("roms/test.bin", result.config.rom_path.?);
    try std.testing.expectEqual(@as(u16, 80), result.config.audio_queue_ms);
    try std.testing.expect(result.config.audio_queue_ms_overridden);
}

test "cli parser accepts spaced renderer override after rom path" {
    const result = try runCliTest(&.{ "roms/test.bin", "--renderer", "opengl" });
    defer result.deinit();
    try std.testing.expectEqualStrings("roms/test.bin", result.config.rom_path.?);
    try std.testing.expectEqualStrings("opengl", result.config.renderer_name.?);
}

test "cli parser rejects invalid audio mode values" {
    try std.testing.expectError(error.InvalidAudioMode, runCliTest(&.{ "--audio-mode", "broken" }));
}

test "cli parser rejects invalid audio queue values" {
    try std.testing.expectError(error.InvalidAudioQueueMs, runCliTest(&.{ "--audio-queue-ms", "20" }));
    try std.testing.expectError(error.InvalidAudioQueueMs, runCliTest(&.{ "--audio-queue-ms", "broken" }));
}

test "cli parser rejects missing renderer value" {
    const chilli = @import("chilli");
    var config = CliConfig{};
    const cmd = try createCliCommand(std.testing.allocator);
    defer cmd.deinit();
    var failed_cmd: ?*const chilli.Command = null;
    try std.testing.expectError(error.MissingFlagValue, cmd.execute(&.{"--renderer"}, @ptrCast(&config), &failed_cmd));
}

test "timing auto-detection chooses pal for europe-only country code" {
    const metadata = Machine.RomMetadata{
        .console = null,
        .title = null,
        .product_code = null,
        .country_codes = "E               ",
        .reset_stack_pointer = 0,
        .reset_program_counter = 0,
        .header_checksum = 0,
        .computed_checksum = 0,
        .checksum_valid = false,
    };

    const resolved = resolveTimingMode(metadata, .auto);
    try std.testing.expect(resolved.pal_mode);
    try std.testing.expectEqualStrings("PAL/50Hz (auto)", resolved.description);
}

test "timing auto-detection defaults to ntsc for multi-region country code" {
    const metadata = Machine.RomMetadata{
        .console = null,
        .title = null,
        .product_code = null,
        .country_codes = "JUE             ",
        .reset_stack_pointer = 0,
        .reset_program_counter = 0,
        .header_checksum = 0,
        .computed_checksum = 0,
        .checksum_valid = false,
    };

    const resolved = resolveTimingMode(metadata, .auto);
    try std.testing.expect(!resolved.pal_mode);
    try std.testing.expectEqualStrings("NTSC/60Hz (auto default)", resolved.description);
}

test "console region auto-detection chooses domestic for japan-only country code" {
    const metadata = Machine.RomMetadata{
        .console = null,
        .title = null,
        .product_code = null,
        .country_codes = "J               ",
        .reset_stack_pointer = 0,
        .reset_program_counter = 0,
        .header_checksum = 0,
        .computed_checksum = 0,
        .checksum_valid = false,
    };

    const resolved = resolveConsoleRegion(metadata);
    try std.testing.expect(!resolved.overseas);
    try std.testing.expectEqualStrings("Domestic/Japan (auto)", resolved.description);
}

test "console region auto-detection defaults to overseas for multi-region country code" {
    const metadata = Machine.RomMetadata{
        .console = null,
        .title = null,
        .product_code = null,
        .country_codes = "JUE             ",
        .reset_stack_pointer = 0,
        .reset_program_counter = 0,
        .header_checksum = 0,
        .computed_checksum = 0,
        .checksum_valid = false,
    };

    const resolved = resolveConsoleRegion(metadata);
    try std.testing.expect(resolved.overseas);
    try std.testing.expectEqualStrings("Overseas/export (auto default)", resolved.description);
}

fn gifOutputPath(current_rom: []const u8) ?[256]u8 {
    if (current_rom.len > 0) {
        if (rom_paths.nextOutputPath(current_rom, "gif")) |path| {
            // Ensure directory exists
            const stem = std.fs.path.stem(current_rom);
            const parent = std.fs.path.dirname(current_rom);
            var dir_buf: [256]u8 = undefined;
            const dir = (if (parent) |p|
                std.fmt.bufPrint(&dir_buf, "{s}{c}{s}", .{ p, std.fs.path.sep, stem })
            else
                std.fmt.bufPrint(&dir_buf, "{s}", .{stem})) catch return path;
            std.fs.cwd().makePath(dir) catch {};
            return path;
        }
    }
    // Fallback to CWD
    var buf: [256]u8 = [_]u8{0} ** 256;
    var i: u32 = 1;
    while (i <= 999) : (i += 1) {
        const name = std.fmt.bufPrint(&buf, "sandopolis_{d:0>3}.gif", .{i}) catch return null;
        buf[name.len] = 0;
        std.fs.cwd().access(name, .{}) catch return buf;
    }
    return null;
}

fn wavOutputPath(current_rom: []const u8) ?[256]u8 {
    if (current_rom.len > 0) {
        if (rom_paths.nextOutputPath(current_rom, "wav")) |path| {
            const stem = std.fs.path.stem(current_rom);
            const parent = std.fs.path.dirname(current_rom);
            var dir_buf: [256]u8 = undefined;
            const dir = (if (parent) |p|
                std.fmt.bufPrint(&dir_buf, "{s}{c}{s}", .{ p, std.fs.path.sep, stem })
            else
                std.fmt.bufPrint(&dir_buf, "{s}", .{stem})) catch return path;
            std.fs.cwd().makePath(dir) catch {};
            return path;
        }
    }
    var buf: [256]u8 = [_]u8{0} ** 256;
    var i: u32 = 1;
    while (i <= 999) : (i += 1) {
        const name = std.fmt.bufPrint(&buf, "sandopolis_{d:0>3}.wav", .{i}) catch return null;
        buf[name.len] = 0;
        std.fs.cwd().access(name, .{}) catch return buf;
    }
    return null;
}

fn screenshotOutputPath(current_rom: []const u8) ?[256]u8 {
    if (current_rom.len > 0) {
        if (rom_paths.nextOutputPath(current_rom, "bmp")) |path| {
            const stem = std.fs.path.stem(current_rom);
            const parent = std.fs.path.dirname(current_rom);
            var dir_buf: [256]u8 = undefined;
            const dir = (if (parent) |p|
                std.fmt.bufPrint(&dir_buf, "{s}{c}{s}", .{ p, std.fs.path.sep, stem })
            else
                std.fmt.bufPrint(&dir_buf, "{s}", .{stem})) catch return path;
            std.fs.cwd().makePath(dir) catch {};
            return path;
        }
    }
    var buf: [256]u8 = [_]u8{0} ** 256;
    var i: u32 = 1;
    while (i <= 999) : (i += 1) {
        const name = std.fmt.bufPrint(&buf, "sandopolis_{d:0>3}.bmp", .{i}) catch return null;
        buf[name.len] = 0;
        std.fs.cwd().access(name, .{}) catch return buf;
    }
    return null;
}

test "gif output path returns optional type" {
    // Verify the function returns an optional - this tests the fix for the
    // bug where returning non-null on exhausted slots would overwrite files
    const ResultType = @TypeOf(gifOutputPath(""));
    const info = @typeInfo(ResultType);
    try std.testing.expect(info == .optional);
}

test "wav output path returns optional type" {
    // Verify the function returns an optional - this tests the fix for the
    // bug where returning non-null on exhausted slots would overwrite files
    const ResultType = @TypeOf(wavOutputPath(""));
    const info = @typeInfo(ResultType);
    try std.testing.expect(info == .optional);
}

test "screenshot output path returns optional type" {
    // Verify the function returns an optional - this tests the fix for the
    // bug where returning non-null on exhausted slots would overwrite files
    const ResultType = @TypeOf(screenshotOutputPath(""));
    const info = @typeInfo(ResultType);
    try std.testing.expect(info == .optional);
}

test "output path format matches expected pattern" {
    // Test that the format string produces expected filenames
    var buf: [48]u8 = [_]u8{0} ** 48;
    const name1 = std.fmt.bufPrint(&buf, "sandopolis_{d:0>3}.gif", .{@as(u32, 1)}) catch unreachable;
    try std.testing.expectEqualStrings("sandopolis_001.gif", name1);

    const name999 = std.fmt.bufPrint(&buf, "sandopolis_{d:0>3}.gif", .{@as(u32, 999)}) catch unreachable;
    try std.testing.expectEqualStrings("sandopolis_999.gif", name999);

    const wav_name = std.fmt.bufPrint(&buf, "sandopolis_{d:0>3}.wav", .{@as(u32, 42)}) catch unreachable;
    try std.testing.expectEqualStrings("sandopolis_042.wav", wav_name);

    const bmp_name = std.fmt.bufPrint(&buf, "sandopolis_{d:0>3}.bmp", .{@as(u32, 123)}) catch unreachable;
    try std.testing.expectEqualStrings("sandopolis_123.bmp", bmp_name);
}

test "handleGameInfoKey opens from pause and closes with escape" {
    var ui = FrontendUi{ .overlay = .pause };
    // Game info key should not handle input when not in game_info overlay
    try std.testing.expect(!handleGameInfoKey(&ui, .i, true));
    try std.testing.expectEqual(Overlay.pause, ui.overlay);

    // Open game info from pause menu via the pause handler
    ui.openGameInfo();
    try std.testing.expectEqual(Overlay.game_info, ui.overlay);

    // Game info key handler should consume all presses
    try std.testing.expect(handleGameInfoKey(&ui, .a, true));
    try std.testing.expectEqual(Overlay.game_info, ui.overlay);

    // Escape closes back to pause
    try std.testing.expect(handleGameInfoKey(&ui, .escape, true));
    try std.testing.expectEqual(Overlay.pause, ui.overlay);
}

test "handleGameInfoKey closes with i key" {
    var ui = FrontendUi{ .overlay = .pause };
    ui.openGameInfo();
    try std.testing.expect(handleGameInfoKey(&ui, .i, true));
    try std.testing.expectEqual(Overlay.pause, ui.overlay);
}

test "frontend config parses psg_volume" {
    const contents =
        \\psg_volume = 80
    ;
    const config = try FrontendConfig.parseContents(contents);
    try std.testing.expectEqual(@as(u8, 80), config.psg_volume);
}

test "frontend config psg_volume defaults to 150" {
    const config = FrontendConfig{};
    try std.testing.expectEqual(@as(u8, 150), config.psg_volume);
}

test "frontend config psg_volume clamps to 200" {
    const contents =
        \\psg_volume = 255
    ;
    const config = try FrontendConfig.parseContents(contents);
    try std.testing.expectEqual(@as(u8, 200), config.psg_volume);
}

test "pause overlay key opens game info with i" {
    const allocator = std.testing.allocator;
    const rom = [_]u8{0} ** 0x400;
    var machine = SystemMachine{ .genesis = try Machine.initFromRomBytes(allocator, rom[0..]) };
    defer machine.deinit(allocator);
    var ui = FrontendUi{ .overlay = .pause };
    var save_manager = SaveManagerState{};
    var settings = SettingsMenuState{};

    try std.testing.expect(handlePauseOverlayKey(
        &ui,
        &save_manager,
        &settings,
        allocator,
        &machine,
        null,
        .i,
        true,
        .{},
    ));
    try std.testing.expectEqual(Overlay.game_info, ui.overlay);
}

extern fn SDL_GetGamepads(count: *c_int) ?[*]zsdl3.Joystick.Id;
extern fn SDL_GetJoysticks(count: *c_int) ?[*]zsdl3.Joystick.Id;
// SDL_IsGamepad, SDL_OpenJoystick, SDL_CloseJoystick are re-exported from input/gamepad.zig
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
