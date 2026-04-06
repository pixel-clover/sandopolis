const std = @import("std");
const testing = @import("sandopolis_testing");
const AudioOutput = testing.AudioOutput;
const YmDacSampleEvent = testing.YmDacSampleEvent;
const YmWriteEvent = testing.YmWriteEvent;

const c = @cImport({
    @cInclude("libretro.h");
});

const default_reference_core_path = "tmp/Genesis-Plus-GX/genesis_plus_gx_libretro.so";
const default_frames: usize = 120;

const Backend = enum {
    sandopolis,
    reference,

    fn parse(value: []const u8) error{InvalidBackend}!Backend {
        if (std.mem.eql(u8, value, "sandopolis")) return .sandopolis;
        if (std.mem.eql(u8, value, "reference")) return .reference;
        return error.InvalidBackend;
    }
};

const Config = struct {
    backend: Backend,
    rom_path: []const u8,
    out_path: []const u8,
    frames: usize = default_frames,
    skip_frames: usize = 0,
    reference_core_path: []const u8 = default_reference_core_path,
};

const ReferenceYmTraceEvent = extern struct {
    cycles: c_uint,
    sequence: c_uint,
    port: u8,
    reg: u8,
    value: u8,
};

const ReferenceApi = struct {
    lib: std.DynLib,
    retro_set_environment: *const fn (c.retro_environment_t) callconv(.c) void,
    retro_set_video_refresh: *const fn (c.retro_video_refresh_t) callconv(.c) void,
    retro_set_audio_sample: *const fn (c.retro_audio_sample_t) callconv(.c) void,
    retro_set_audio_sample_batch: *const fn (c.retro_audio_sample_batch_t) callconv(.c) void,
    retro_set_input_poll: *const fn (c.retro_input_poll_t) callconv(.c) void,
    retro_set_input_state: *const fn (c.retro_input_state_t) callconv(.c) void,
    retro_init: *const fn () callconv(.c) void,
    retro_deinit: *const fn () callconv(.c) void,
    retro_load_game: *const fn (?*const c.struct_retro_game_info) callconv(.c) bool,
    retro_unload_game: *const fn () callconv(.c) void,
    retro_run: *const fn () callconv(.c) void,
    sandopolis_trace_ym_reset: *const fn () callconv(.c) void,
    sandopolis_trace_ym_set_enabled: *const fn (c_uint) callconv(.c) void,
    sandopolis_trace_ym_take: *const fn ([*]ReferenceYmTraceEvent, c_uint) callconv(.c) c_uint,

    fn open(path: []const u8) !ReferenceApi {
        var lib = try std.DynLib.open(path);
        errdefer lib.close();

        return .{
            .lib = lib,
            .retro_set_environment = try lookup(&lib, *const fn (c.retro_environment_t) callconv(.c) void, "retro_set_environment"),
            .retro_set_video_refresh = try lookup(&lib, *const fn (c.retro_video_refresh_t) callconv(.c) void, "retro_set_video_refresh"),
            .retro_set_audio_sample = try lookup(&lib, *const fn (c.retro_audio_sample_t) callconv(.c) void, "retro_set_audio_sample"),
            .retro_set_audio_sample_batch = try lookup(&lib, *const fn (c.retro_audio_sample_batch_t) callconv(.c) void, "retro_set_audio_sample_batch"),
            .retro_set_input_poll = try lookup(&lib, *const fn (c.retro_input_poll_t) callconv(.c) void, "retro_set_input_poll"),
            .retro_set_input_state = try lookup(&lib, *const fn (c.retro_input_state_t) callconv(.c) void, "retro_set_input_state"),
            .retro_init = try lookup(&lib, *const fn () callconv(.c) void, "retro_init"),
            .retro_deinit = try lookup(&lib, *const fn () callconv(.c) void, "retro_deinit"),
            .retro_load_game = try lookup(&lib, *const fn (?*const c.struct_retro_game_info) callconv(.c) bool, "retro_load_game"),
            .retro_unload_game = try lookup(&lib, *const fn () callconv(.c) void, "retro_unload_game"),
            .retro_run = try lookup(&lib, *const fn () callconv(.c) void, "retro_run"),
            .sandopolis_trace_ym_reset = try lookup(&lib, *const fn () callconv(.c) void, "sandopolis_trace_ym_reset"),
            .sandopolis_trace_ym_set_enabled = try lookup(&lib, *const fn (c_uint) callconv(.c) void, "sandopolis_trace_ym_set_enabled"),
            .sandopolis_trace_ym_take = try lookup(&lib, *const fn ([*]ReferenceYmTraceEvent, c_uint) callconv(.c) c_uint, "sandopolis_trace_ym_take"),
        };
    }

    fn close(self: *ReferenceApi) void {
        self.lib.close();
    }
};

const ReferenceFrontend = struct {
    system_dir_z: [:0]const u8,
    save_dir_z: [:0]const u8,
};

const StreamSummary = struct {
    events: usize = 0,
    stream_hash: u64 = 0xcbf29ce484222325,
};

var active_reference_frontend: ?*ReferenceFrontend = null;

fn lookup(lib: *std.DynLib, comptime T: type, symbol_name: [:0]const u8) !T {
    return lib.lookup(T, symbol_name) orelse error.MissingSymbol;
}

fn referenceVariableValue(key: []const u8) ?[*:0]const u8 {
    if (std.mem.eql(u8, key, "genesis_plus_gx_ym2612")) return "nuked (ym2612)";
    if (std.mem.eql(u8, key, "genesis_plus_gx_sound_output")) return "stereo";
    if (std.mem.eql(u8, key, "genesis_plus_gx_audio_filter")) return "disabled";
    if (std.mem.eql(u8, key, "genesis_plus_gx_psg_preamp")) return "0";
    if (std.mem.eql(u8, key, "genesis_plus_gx_fm_preamp")) return "100";
    return null;
}

fn referenceEnvironmentCallback(cmd: c_uint, data: ?*anyopaque) callconv(.c) bool {
    const frontend = active_reference_frontend orelse return false;

    switch (cmd) {
        c.RETRO_ENVIRONMENT_SET_PIXEL_FORMAT,
        c.RETRO_ENVIRONMENT_SET_INPUT_DESCRIPTORS,
        c.RETRO_ENVIRONMENT_SET_CONTROLLER_INFO,
        c.RETRO_ENVIRONMENT_SET_CONTENT_INFO_OVERRIDE,
        c.RETRO_ENVIRONMENT_SET_PERFORMANCE_LEVEL,
        c.RETRO_ENVIRONMENT_SET_SERIALIZATION_QUIRKS,
        c.RETRO_ENVIRONMENT_SET_DISK_CONTROL_INTERFACE,
        c.RETRO_ENVIRONMENT_SET_CORE_OPTIONS_DISPLAY,
        => return true,
        c.RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY => {
            const out_ptr: *?[*:0]const u8 = @ptrCast(@alignCast(data.?));
            out_ptr.* = frontend.system_dir_z.ptr;
            return true;
        },
        c.RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY => {
            const out_ptr: *?[*:0]const u8 = @ptrCast(@alignCast(data.?));
            out_ptr.* = frontend.save_dir_z.ptr;
            return true;
        },
        c.RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE => {
            const updated: *bool = @ptrCast(@alignCast(data.?));
            updated.* = false;
            return true;
        },
        c.RETRO_ENVIRONMENT_GET_VARIABLE => {
            const variable: *c.struct_retro_variable = @ptrCast(@alignCast(data.?));
            if (variable.key == null) return false;
            const key = std.mem.span(variable.key);
            variable.value = referenceVariableValue(key);
            return variable.value != null;
        },
        c.RETRO_ENVIRONMENT_GET_GAME_INFO_EXT,
        c.RETRO_ENVIRONMENT_GET_VFS_INTERFACE,
        c.RETRO_ENVIRONMENT_GET_LOG_INTERFACE,
        c.RETRO_ENVIRONMENT_GET_INPUT_BITMASKS,
        => return false,
        else => return false,
    }
}

fn referenceVideoRefreshCallback(_: ?*const anyopaque, _: c_uint, _: c_uint, _: usize) callconv(.c) void {}
fn referenceAudioSampleCallback(_: i16, _: i16) callconv(.c) void {}
fn referenceAudioBatchCallback(_: [*c]const i16, frames: usize) callconv(.c) usize {
    return frames;
}
fn referenceInputPollCallback() callconv(.c) void {}
fn referenceInputStateCallback(_: c_uint, _: c_uint, _: c_uint, _: c_uint) callconv(.c) i16 {
    return 0;
}

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    const config = try parseArgs(allocator);
    defer allocator.free(config.rom_path);
    defer allocator.free(config.out_path);
    defer allocator.free(config.reference_core_path);

    const summary = switch (config.backend) {
        .sandopolis => try traceSandopolis(allocator, config),
        .reference => try traceReference(allocator, config),
    };

    std.debug.print(
        "{s}: traced {d} YM writes to {s} over {d} frames after skipping {d}; stream_hash=0x{X:0>16}\n",
        .{
            @tagName(config.backend),
            summary.events,
            config.out_path,
            config.frames,
            config.skip_frames,
            summary.stream_hash,
        },
    );
}

fn parseArgs(allocator: std.mem.Allocator) !Config {
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.next();
    const backend_arg = args.next() orelse return usageError();
    const rom_arg = args.next() orelse return usageError();
    const out_arg = args.next() orelse return usageError();
    const maybe_frames_arg = args.next();
    var frames = default_frames;
    var skip_frames: usize = 0;
    var reference_core_path = try allocator.dupe(u8, default_reference_core_path);
    errdefer allocator.free(reference_core_path);

    if (maybe_frames_arg) |arg| {
        if (!std.mem.startsWith(u8, arg, "--")) {
            frames = try std.fmt.parseInt(usize, arg, 10);
        } else if (std.mem.eql(u8, arg, "--skip")) {
            const skip_arg = args.next() orelse return usageError();
            skip_frames = try std.fmt.parseInt(usize, skip_arg, 10);
        } else if (std.mem.eql(u8, arg, "--reference-core")) {
            allocator.free(reference_core_path);
            const path_arg = args.next() orelse return usageError();
            reference_core_path = try allocator.dupe(u8, path_arg);
        } else {
            return usageError();
        }
    }

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--skip")) {
            const skip_arg = args.next() orelse return usageError();
            skip_frames = try std.fmt.parseInt(usize, skip_arg, 10);
        } else if (std.mem.eql(u8, arg, "--reference-core")) {
            allocator.free(reference_core_path);
            const path_arg = args.next() orelse return usageError();
            reference_core_path = try allocator.dupe(u8, path_arg);
        } else {
            return usageError();
        }
    }

    return .{
        .backend = try Backend.parse(backend_arg),
        .rom_path = try allocator.dupe(u8, rom_arg),
        .out_path = try allocator.dupe(u8, out_arg),
        .frames = frames,
        .skip_frames = skip_frames,
        .reference_core_path = reference_core_path,
    };
}

fn usageError() error{InvalidArgs} {
    std.debug.print(
        "Usage: zig build trace-ym-writes -- <sandopolis|reference> <rom-path> <out-path> [frames] [--skip frames] [--reference-core path]\n",
        .{},
    );
    return error.InvalidArgs;
}

fn updateStreamHash(summary: *StreamSummary, port: u8, reg: u8, value: u8) void {
    summary.stream_hash ^= port;
    summary.stream_hash *%= 0x100000001b3;
    summary.stream_hash ^= reg;
    summary.stream_hash *%= 0x100000001b3;
    summary.stream_hash ^= value;
    summary.stream_hash *%= 0x100000001b3;
}

fn traceSandopolis(allocator: std.mem.Allocator, config: Config) !StreamSummary {
    var emulator = try testing.Emulator.init(allocator, config.rom_path);
    defer emulator.deinit(allocator);

    var output = AudioOutput.init();
    var file = try std.fs.cwd().createFile(config.out_path, .{ .truncate = true });
    defer file.close();
    var buffer: [4096]u8 = undefined;
    var file_writer = file.writer(&buffer);
    const writer = &file_writer.interface;

    try writer.print("frame\tmaster_offset\tsequence\tport\treg\tvalue\n", .{});

    for (0..config.skip_frames) |_| {
        emulator.runFrame();
        try drainSandopolisYmEvents(allocator, &emulator, null, null, null);
        try emulator.discardPendingAudioWithOutput(&output);
    }

    var summary = StreamSummary{};
    for (0..config.frames) |frame_index| {
        emulator.runFrame();
        try drainSandopolisYmEvents(allocator, &emulator, writer, &summary, frame_index);
        try emulator.discardPendingAudioWithOutput(&output);
    }

    try writer.flush();
    return summary;
}

fn sandopolisEventOrderLessThan(a_master_offset: u32, a_sequence: u32, b_master_offset: u32, b_sequence: u32) bool {
    if (a_master_offset != b_master_offset) return a_master_offset < b_master_offset;
    return a_sequence < b_sequence;
}

fn drainSandopolisYmEvents(
    allocator: std.mem.Allocator,
    emulator: *testing.Emulator,
    writer: ?*std.Io.Writer,
    summary: ?*StreamSummary,
    frame_index: ?usize,
) !void {
    const write_count = emulator.pendingYmWriteCount();
    const dac_count = emulator.pendingYmDacCount();

    const writes = try allocator.alloc(YmWriteEvent, write_count);
    defer allocator.free(writes);
    const dac_samples = try allocator.alloc(YmDacSampleEvent, dac_count);
    defer allocator.free(dac_samples);

    const actual_write_count = emulator.takeYmWrites(writes);
    const actual_dac_count = emulator.takeYmDacSamples(dac_samples);

    var write_index: usize = 0;
    var dac_index: usize = 0;
    while (write_index < actual_write_count or dac_index < actual_dac_count) {
        const use_write = if (write_index >= actual_write_count)
            false
        else if (dac_index >= actual_dac_count)
            true
        else
            sandopolisEventOrderLessThan(
                writes[write_index].master_offset,
                writes[write_index].sequence,
                dac_samples[dac_index].master_offset,
                dac_samples[dac_index].sequence,
            );

        if (use_write) {
            const event = writes[write_index];
            if (writer) |out| {
                try out.print(
                    "{d}\t{d}\t{d}\t{d}\t0x{X:0>2}\t0x{X:0>2}\n",
                    .{
                        frame_index.?,
                        event.master_offset,
                        event.sequence,
                        event.port,
                        event.reg,
                        event.value,
                    },
                );
            }
            if (summary) |state| {
                state.events += 1;
                updateStreamHash(state, event.port, event.reg, event.value);
            }
            write_index += 1;
        } else {
            const event = dac_samples[dac_index];
            if (writer) |out| {
                try out.print(
                    "{d}\t{d}\t{d}\t0\t0x2A\t0x{X:0>2}\n",
                    .{
                        frame_index.?,
                        event.master_offset,
                        event.sequence,
                        event.value,
                    },
                );
            }
            if (summary) |state| {
                state.events += 1;
                updateStreamHash(state, 0, 0x2A, event.value);
            }
            dac_index += 1;
        }
    }
}

fn traceReference(allocator: std.mem.Allocator, config: Config) !StreamSummary {
    var api = try ReferenceApi.open(config.reference_core_path);
    defer api.close();

    const cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);
    const cwd_z = try allocator.dupeZ(u8, cwd_path);
    defer allocator.free(cwd_z);
    const rom_path_z = try allocator.dupeZ(u8, config.rom_path);
    defer allocator.free(rom_path_z);

    var frontend = ReferenceFrontend{
        .system_dir_z = cwd_z,
        .save_dir_z = cwd_z,
    };
    active_reference_frontend = &frontend;
    defer active_reference_frontend = null;

    api.retro_set_environment(referenceEnvironmentCallback);
    api.retro_set_video_refresh(referenceVideoRefreshCallback);
    api.retro_set_audio_sample(referenceAudioSampleCallback);
    api.retro_set_audio_sample_batch(referenceAudioBatchCallback);
    api.retro_set_input_poll(referenceInputPollCallback);
    api.retro_set_input_state(referenceInputStateCallback);
    api.retro_init();
    defer api.retro_deinit();

    var game_info = c.struct_retro_game_info{
        .path = rom_path_z.ptr,
        .data = null,
        .size = 0,
        .meta = null,
    };

    if (!api.retro_load_game(&game_info)) return error.RetroLoadGameFailed;
    defer api.retro_unload_game();

    api.sandopolis_trace_ym_set_enabled(0);
    api.sandopolis_trace_ym_reset();

    for (0..config.skip_frames) |_| {
        api.retro_run();
    }

    api.sandopolis_trace_ym_reset();
    api.sandopolis_trace_ym_set_enabled(1);
    for (0..config.frames) |_| {
        api.retro_run();
    }
    api.sandopolis_trace_ym_set_enabled(0);

    var file = try std.fs.cwd().createFile(config.out_path, .{ .truncate = true });
    defer file.close();
    var buffer: [4096]u8 = undefined;
    var file_writer = file.writer(&buffer);
    const writer = &file_writer.interface;
    try writer.print("cycles\tsequence\tport\treg\tvalue\n", .{});

    var summary = StreamSummary{};
    var events: [512]ReferenceYmTraceEvent = undefined;
    while (true) {
        const count = api.sandopolis_trace_ym_take(events[0..].ptr, events.len);
        if (count == 0) break;
        for (events[0..count]) |event| {
            try writer.print(
                "{d}\t{d}\t{d}\t0x{X:0>2}\t0x{X:0>2}\n",
                .{
                    event.cycles,
                    event.sequence,
                    event.port,
                    event.reg,
                    event.value,
                },
            );
            summary.events += 1;
            updateStreamHash(&summary, event.port, event.reg, event.value);
        }
    }

    try writer.flush();
    return summary;
}
