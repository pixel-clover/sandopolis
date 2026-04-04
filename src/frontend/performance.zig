const std = @import("std");
const zsdl3 = @import("zsdl3");
const AudioOutput = @import("../audio/output.zig").AudioOutput;
const CoreFrameCounters = @import("../performance_profile.zig").CoreFrameCounters;
const ui = @import("ui.zig");

// Performance monitoring thresholds and sampling configuration
pub const spike_log_threshold_ns: u64 = 4 * std.time.ns_per_ms;
pub const spike_log_burst_delta_ns: u64 = 8 * std.time.ns_per_ms;
pub const spike_window_ns: u64 = std.time.ns_per_s;
pub const core_sample_period: u64 = 16;
pub const core_burst_frames: u32 = 8;

pub fn queuedAudioNsFromBytes(queued_bytes: usize) u64 {
    return @intCast((@as(u128, queued_bytes) * std.time.ns_per_s) /
        (@as(u128, AudioOutput.output_rate) * AudioOutput.channels * @sizeOf(i16)));
}

pub fn queueIsBackloggedForBudget(queued_bytes: usize, budget_bytes: usize) bool {
    return queued_bytes >= budget_bytes;
}

pub fn queueIsBacklogged(queued_bytes: usize) bool {
    return queueIsBackloggedForBudget(queued_bytes, AudioOutput.queueBudgetBytes(AudioOutput.default_queue_budget_ms));
}

pub const StageSample = struct {
    label: []const u8,
    ns: u64,
};

pub const FramePhases = struct {
    emulation_ns: u64 = 0,
    audio_ns: u64 = 0,
    upload_ns: u64 = 0,
    draw_ns: u64 = 0,
    present_call_ns: u64 = 0,

    pub fn hottestStage(self: *const FramePhases) StageSample {
        var hottest = StageSample{ .label = "EMU", .ns = self.emulation_ns };
        if (self.audio_ns > hottest.ns) hottest = .{ .label = "AUD", .ns = self.audio_ns };
        if (self.upload_ns > hottest.ns) hottest = .{ .label = "UPL", .ns = self.upload_ns };
        if (self.draw_ns > hottest.ns) hottest = .{ .label = "DRAW", .ns = self.draw_ns };
        if (self.present_call_ns > hottest.ns) hottest = .{ .label = "PRE", .ns = self.present_call_ns };
        return hottest;
    }
};

fn smoothMetric(current_avg: u64, sample: u64) u64 {
    return ((current_avg * 7) + sample + 4) / 8;
}

pub const HudState = struct {
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
    last_audio_queue_budget_bytes: ?usize = null,
    last_audio_backlog_recoveries: ?u64 = null,
    last_audio_overflow_events: ?u64 = null,
    last_phases: FramePhases = .{},
    average_phases: FramePhases = .{},
    last_core_counters: CoreFrameCounters = .{},
    average_core_counters: CoreFrameCounters = .{},

    pub fn reset(self: *HudState) void {
        self.* = .{};
    }

    pub fn noteFrame(
        self: *HudState,
        work_ns: u64,
        present_ns: u64,
        target_ns: u64,
        audio_queued_bytes: ?usize,
        audio_queue_budget_bytes: ?usize,
        audio_backlog_recoveries: ?u64,
        audio_overflow_events: ?u64,
        phases: FramePhases,
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
        self.last_audio_queue_budget_bytes = audio_queue_budget_bytes;
        self.last_audio_backlog_recoveries = audio_backlog_recoveries;
        self.last_audio_overflow_events = audio_overflow_events;
        self.last_phases = phases;
        self.last_core_counters_sampled = core_counters != null;
        if (self.last_overrun_ns != 0) self.slow_frame_count += 1;

        if (self.frame_count == 1) {
            self.average_work_ns = work_ns;
            self.average_present_ns = present_ns;
            self.average_phases = phases;
            self.average_other_ns = other_ns;
        } else {
            self.average_work_ns = smoothMetric(self.average_work_ns, work_ns);
            self.average_present_ns = smoothMetric(self.average_present_ns, present_ns);
            self.average_phases.emulation_ns = smoothMetric(self.average_phases.emulation_ns, phases.emulation_ns);
            self.average_phases.audio_ns = smoothMetric(self.average_phases.audio_ns, phases.audio_ns);
            self.average_phases.upload_ns = smoothMetric(self.average_phases.upload_ns, phases.upload_ns);
            self.average_phases.draw_ns = smoothMetric(self.average_phases.draw_ns, phases.draw_ns);
            self.average_phases.present_call_ns = smoothMetric(self.average_phases.present_call_ns, phases.present_call_ns);
            self.average_other_ns = smoothMetric(self.average_other_ns, other_ns);
        }

        if (core_counters) |sample| {
            self.last_core_counters = sample;
            if (self.core_sample_count == 0) {
                self.average_core_counters = sample;
            } else {
                self.average_core_counters.m68k_instructions = smoothMetric(self.average_core_counters.m68k_instructions, sample.m68k_instructions);
                self.average_core_counters.z80_instructions = smoothMetric(self.average_core_counters.z80_instructions, sample.z80_instructions);
                self.average_core_counters.transfer_slots = smoothMetric(self.average_core_counters.transfer_slots, sample.transfer_slots);
                self.average_core_counters.access_slots = smoothMetric(self.average_core_counters.access_slots, sample.access_slots);
                self.average_core_counters.dma_words = smoothMetric(self.average_core_counters.dma_words, sample.dma_words);
                self.average_core_counters.render_scanlines = smoothMetric(self.average_core_counters.render_scanlines, sample.render_scanlines);
                self.average_core_counters.render_sprite_entries = smoothMetric(self.average_core_counters.render_sprite_entries, sample.render_sprite_entries);
                self.average_core_counters.render_sprite_pixels = smoothMetric(self.average_core_counters.render_sprite_pixels, sample.render_sprite_pixels);
                self.average_core_counters.render_sprite_opaque_pixels = smoothMetric(self.average_core_counters.render_sprite_opaque_pixels, sample.render_sprite_opaque_pixels);
            }
            self.core_sample_count += 1;
        }
    }

    pub fn queuedAudioNs(self: *const HudState) ?u64 {
        const queued_bytes = self.last_audio_queued_bytes orelse return null;
        return queuedAudioNsFromBytes(queued_bytes);
    }

    pub fn queuedAudioBudgetNs(self: *const HudState) ?u64 {
        const queued_bytes = self.last_audio_queue_budget_bytes orelse return null;
        return queuedAudioNsFromBytes(queued_bytes);
    }

    pub fn slowFramePercentTenths(self: *const HudState) u64 {
        if (self.frame_count == 0) return 0;
        return @intCast((@as(u128, self.slow_frame_count) * 1000 + @as(u128, self.frame_count) / 2) / @as(u128, self.frame_count));
    }

    pub fn hottestStage(self: *const HudState) StageSample {
        var hottest = self.last_phases.hottestStage();
        if (self.last_other_ns > hottest.ns) hottest = .{ .label = "OTH", .ns = self.last_other_ns };
        return hottest;
    }
};

pub fn shouldSampleCoreCounters(show_hud: bool, frame_number: u64, burst_frames_remaining: u32) bool {
    return show_hud and (burst_frames_remaining != 0 or frame_number % core_sample_period == 0);
}

pub fn nextCoreBurstFramesRemaining(sampled_this_frame: bool, burst_frames_remaining: u32, perf: *const HudState) u32 {
    var remaining = burst_frames_remaining;
    if (sampled_this_frame and remaining != 0) remaining -= 1;
    if (isThresholdSlowFrame(perf)) remaining = @max(remaining, core_burst_frames);
    return remaining;
}

pub const SpikeWindowSummary = struct {
    start_frame: u64,
    end_frame: u64,
    frame_count: u64,
    slow_frame_count: u64,
    average_overrun_ns: u64,
    max_overrun_ns: u64,
    audio_queued_bytes: ?usize,

    pub fn audioQueuedNs(self: *const SpikeWindowSummary) ?u64 {
        const queued_bytes = self.audio_queued_bytes orelse return null;
        return queuedAudioNsFromBytes(queued_bytes);
    }
};

pub const SpikeLogUpdate = struct {
    log_frame: bool = false,
    summary: ?SpikeWindowSummary = null,
};

pub const SpikeLogState = struct {
    burst_frame_count: u64 = 0,
    burst_last_logged_overrun_ns: u64 = 0,
    window_start_frame: u64 = 0,
    window_frame_count: u64 = 0,
    window_slow_frame_count: u64 = 0,
    window_overrun_ns_total: u64 = 0,
    window_max_overrun_ns: u64 = 0,
    window_target_ns_total: u64 = 0,
    window_last_audio_queued_bytes: ?usize = null,

    pub fn reset(self: *SpikeLogState) void {
        self.resetBurst();
        self.resetWindow();
    }

    pub fn resetBurst(self: *SpikeLogState) void {
        self.burst_frame_count = 0;
        self.burst_last_logged_overrun_ns = 0;
    }

    pub fn resetWindow(self: *SpikeLogState) void {
        self.window_start_frame = 0;
        self.window_frame_count = 0;
        self.window_slow_frame_count = 0;
        self.window_overrun_ns_total = 0;
        self.window_max_overrun_ns = 0;
        self.window_target_ns_total = 0;
        self.window_last_audio_queued_bytes = null;
    }

    pub fn noteFrame(
        self: *SpikeLogState,
        frame_number: u64,
        perf: *const HudState,
    ) SpikeLogUpdate {
        var update = SpikeLogUpdate{};
        const threshold_slow = isThresholdSlowFrame(perf);
        if (threshold_slow) {
            if (self.burst_frame_count == 0) {
                self.burst_frame_count = 1;
                self.burst_last_logged_overrun_ns = perf.last_overrun_ns;
                update.log_frame = true;
            } else {
                self.burst_frame_count += 1;
                if (perf.last_overrun_ns >= self.burst_last_logged_overrun_ns + spike_log_burst_delta_ns) {
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

        if (self.window_target_ns_total < spike_window_ns) return update;

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

pub fn isThresholdSlowFrame(perf: *const HudState) bool {
    return perf.last_overrun_ns >= spike_log_threshold_ns;
}

// Formatting helpers
pub fn formatDurationMsTenths(buffer: []u8, ns: u64) ![]const u8 {
    const tenths = (ns + 50_000) / 100_000;
    return std.fmt.bufPrint(buffer, "{d}.{d}", .{ tenths / 10, tenths % 10 });
}

pub fn formatRateHzTenths(buffer: []u8, ns: u64) ![]const u8 {
    if (ns == 0) return std.fmt.bufPrint(buffer, "0.0", .{});
    const tenths = (@as(u128, std.time.ns_per_s) * 10 + @as(u128, ns) / 2) / @as(u128, ns);
    return std.fmt.bufPrint(buffer, "{d}.{d}", .{ tenths / 10, tenths % 10 });
}

pub fn formatPercentTenths(buffer: []u8, tenths_percent: u64) ![]const u8 {
    return std.fmt.bufPrint(buffer, "{d}.{d}", .{ tenths_percent / 10, tenths_percent % 10 });
}

pub fn formatSpikeLine(buffer: []u8, frame_number: u32, perf: *const HudState) ![]const u8 {
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

pub fn formatSpikeWindowLine(buffer: []u8, summary: *const SpikeWindowSummary) ![]const u8 {
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

// HUD Rendering
pub fn renderHud(renderer: *zsdl3.Renderer, viewport: zsdl3.Rect, perf: *const HudState) !void {
    const title = "PERF HUD";
    const scale = @min(ui.overlayScale(viewport), 2.0);
    const padding = 8.0 * scale;
    const line_height = 10.0 * scale;

    var metric_buffers: [14][16]u8 = undefined;
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
    const audio_budget_text = if (perf.queuedAudioBudgetNs()) |queued_ns|
        try formatDurationMsTenths(metric_buffers[12][0..], queued_ns)
    else
        null;

    var line_buffers: [12][72]u8 = undefined;
    var lines: [12][]const u8 = undefined;
    lines[0] = try std.fmt.bufPrint(&line_buffers[0], "FPS {s} / {s}", .{ fps_text, target_fps_text });
    lines[1] = try std.fmt.bufPrint(&line_buffers[1], "FPS AVG {s}", .{avg_fps_text});
    lines[2] = try std.fmt.bufPrint(&line_buffers[2], "WORK {s} / {s} MS", .{ work_text, target_text });
    lines[3] = try std.fmt.bufPrint(&line_buffers[3], "AVG {s} MS", .{avg_text});
    lines[4] = try std.fmt.bufPrint(&line_buffers[4], "SLEEP {s} MS", .{sleep_text});
    lines[5] = try std.fmt.bufPrint(&line_buffers[5], "OVER {s} MS", .{overrun_text});
    lines[6] = try std.fmt.bufPrint(&line_buffers[6], "SLOW {d} {s} PCT", .{ perf.slow_frame_count, slow_percent_text });
    lines[7] = try std.fmt.bufPrint(&line_buffers[7], "WORST WORK {s} MS", .{worst_work_text});
    lines[8] = try std.fmt.bufPrint(&line_buffers[8], "WORST OVR {s} MS", .{worst_overrun_text});
    lines[9] = if (perf.last_audio_queued_bytes == null)
        "AUDIO OFF"
    else if (audio_budget_text) |budget_text|
        try std.fmt.bufPrint(&line_buffers[9], "AUDIO {s}/{s} MS", .{ audio_text, budget_text })
    else
        try std.fmt.bufPrint(&line_buffers[9], "AUDIO {s} MS", .{audio_text});
    lines[10] = if (perf.last_audio_backlog_recoveries) |backlog_recoveries|
        try std.fmt.bufPrint(&line_buffers[10], "ABK {d} AOV {d}", .{ backlog_recoveries, perf.last_audio_overflow_events orelse 0 })
    else if (perf.last_audio_overflow_events) |overflow_events|
        try std.fmt.bufPrint(&line_buffers[10], "ABK 0 AOV {d}", .{overflow_events})
    else
        "ABK OFF AOV OFF";
    lines[11] = "F12 RESET";

    var max_width = ui.textWidth(title, scale);
    for (lines) |line| {
        max_width = @max(max_width, ui.textWidth(line, scale));
    }

    const panel = zsdl3.FRect{
        .x = 12.0 * scale,
        .y = 12.0 * scale,
        .w = max_width + padding * 2.0,
        .h = padding * 2.0 + 7.0 * scale + 5.0 * scale + line_height * @as(f32, @floatFromInt(lines.len)),
    };

    try ui.renderPanel(
        renderer,
        panel,
        ui.Colors.panel_overlay,
        ui.Colors.blue,
        scale,
    );
    try ui.setClipRect(renderer, panel);
    defer ui.clearClipRect(renderer) catch {};

    try ui.drawText(
        renderer,
        panel.x + padding,
        panel.y + padding,
        scale,
        ui.Colors.blue,
        title,
    );

    var y = panel.y + padding + 12.0 * scale;
    for (lines) |line| {
        try ui.drawText(
            renderer,
            panel.x + padding,
            y,
            scale,
            ui.Colors.text_primary,
            line,
        );
        y += line_height;
    }
}
