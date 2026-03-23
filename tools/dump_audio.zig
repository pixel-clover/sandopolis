const std = @import("std");
const testing = @import("sandopolis_testing");
const AudioOutput = testing.AudioOutput;
const WavRecorder = testing.WavRecorder;

const c = @cImport({
    @cInclude("libretro.h");
});

const default_gpgx_core_path = "tmp/Genesis-Plus-GX/genesis_plus_gx_libretro.so";
const default_frames: usize = 600;

const Backend = enum {
    sandopolis,
    gpgx,

    fn parse(value: []const u8) error{InvalidBackend}!Backend {
        if (std.mem.eql(u8, value, "sandopolis")) return .sandopolis;
        if (std.mem.eql(u8, value, "gpgx")) return .gpgx;
        return error.InvalidBackend;
    }
};

const CaptureMode = enum {
    normal,
    ym_only,
    psg_only,
    unfiltered_mix,

    fn parse(value: []const u8) error{InvalidMode}!CaptureMode {
        if (std.mem.eql(u8, value, "normal")) return .normal;
        if (std.mem.eql(u8, value, "ym-only") or std.mem.eql(u8, value, "ym_only")) return .ym_only;
        if (std.mem.eql(u8, value, "psg-only") or std.mem.eql(u8, value, "psg_only")) return .psg_only;
        if (std.mem.eql(u8, value, "unfiltered-mix") or std.mem.eql(u8, value, "unfiltered_mix")) return .unfiltered_mix;
        return error.InvalidMode;
    }
};

const Config = struct {
    backend: Backend,
    rom_path: []const u8,
    out_path: []const u8,
    frames: usize = default_frames,
    skip_frames: usize = 0,
    mode: CaptureMode = .normal,
    gpgx_core_path: []const u8 = default_gpgx_core_path,
};

const WavSink = struct {
    recorder: *WavRecorder,

    pub fn consumeSamples(self: *WavSink, samples: []const i16) !void {
        try self.recorder.addSamples(samples);
    }
};

const GpgxApi = struct {
    lib: std.DynLib,
    retro_set_environment: *const fn (c.retro_environment_t) callconv(.c) void,
    retro_set_video_refresh: *const fn (c.retro_video_refresh_t) callconv(.c) void,
    retro_set_audio_sample: *const fn (c.retro_audio_sample_t) callconv(.c) void,
    retro_set_audio_sample_batch: *const fn (c.retro_audio_sample_batch_t) callconv(.c) void,
    retro_set_input_poll: *const fn (c.retro_input_poll_t) callconv(.c) void,
    retro_set_input_state: *const fn (c.retro_input_state_t) callconv(.c) void,
    retro_init: *const fn () callconv(.c) void,
    retro_deinit: *const fn () callconv(.c) void,
    retro_get_system_av_info: *const fn (*c.struct_retro_system_av_info) callconv(.c) void,
    retro_load_game: *const fn (?*const c.struct_retro_game_info) callconv(.c) bool,
    retro_unload_game: *const fn () callconv(.c) void,
    retro_run: *const fn () callconv(.c) void,

    fn open(path: []const u8) !GpgxApi {
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
            .retro_get_system_av_info = try lookup(&lib, *const fn (*c.struct_retro_system_av_info) callconv(.c) void, "retro_get_system_av_info"),
            .retro_load_game = try lookup(&lib, *const fn (?*const c.struct_retro_game_info) callconv(.c) bool, "retro_load_game"),
            .retro_unload_game = try lookup(&lib, *const fn () callconv(.c) void, "retro_unload_game"),
            .retro_run = try lookup(&lib, *const fn () callconv(.c) void, "retro_run"),
        };
    }

    fn close(self: *GpgxApi) void {
        self.lib.close();
    }
};

fn lookup(lib: *std.DynLib, comptime T: type, symbol_name: [:0]const u8) !T {
    return lib.lookup(T, symbol_name) orelse error.MissingSymbol;
}

const GpgxFrontend = struct {
    recorder: ?*WavRecorder = null,
    system_dir_z: [:0]const u8,
    save_dir_z: [:0]const u8,
    mode: CaptureMode,
    write_failed: bool = false,
};

var active_gpgx_frontend: ?*GpgxFrontend = null;

fn gpgxVariableValue(frontend: *const GpgxFrontend, key: []const u8) ?[*:0]const u8 {
    if (std.mem.eql(u8, key, "genesis_plus_gx_ym2612")) {
        return "nuked (ym2612)";
    }
    if (std.mem.eql(u8, key, "genesis_plus_gx_sound_output")) {
        return "stereo";
    }
    if (std.mem.eql(u8, key, "genesis_plus_gx_audio_filter")) {
        return switch (frontend.mode) {
            .unfiltered_mix => "disabled",
            .normal, .ym_only, .psg_only => "low-pass",
        };
    }
    if (std.mem.eql(u8, key, "genesis_plus_gx_psg_preamp")) {
        return switch (frontend.mode) {
            .normal, .psg_only => "150",
            .ym_only, .unfiltered_mix => "0",
        };
    }
    if (std.mem.eql(u8, key, "genesis_plus_gx_fm_preamp")) {
        return switch (frontend.mode) {
            .normal, .ym_only, .unfiltered_mix => "100",
            .psg_only => "0",
        };
    }
    return null;
}

fn gpgxEnvironmentCallback(cmd: c_uint, data: ?*anyopaque) callconv(.c) bool {
    const frontend = active_gpgx_frontend orelse return false;

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
            variable.value = gpgxVariableValue(frontend, key);
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

fn gpgxVideoRefreshCallback(_: ?*const anyopaque, _: c_uint, _: c_uint, _: usize) callconv(.c) void {}

fn gpgxAudioSampleCallback(_: i16, _: i16) callconv(.c) void {}

fn gpgxAudioBatchCallback(data: [*c]const i16, frames: usize) callconv(.c) usize {
    if (active_gpgx_frontend) |frontend| {
        if (frontend.recorder) |recorder| {
            const sample_ptr: [*]const i16 = @ptrCast(data);
            const samples = sample_ptr[0 .. frames * AudioOutput.channels];
            recorder.addSamples(samples) catch {
                frontend.write_failed = true;
            };
        }
    }
    return frames;
}

fn gpgxInputPollCallback() callconv(.c) void {}

fn gpgxInputStateCallback(_: c_uint, _: c_uint, _: c_uint, _: c_uint) callconv(.c) i16 {
    return 0;
}

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    const config = try parseArgs(allocator);
    defer allocator.free(config.rom_path);
    defer allocator.free(config.out_path);
    defer allocator.free(config.gpgx_core_path);

    switch (config.backend) {
        .sandopolis => try dumpSandopolis(allocator, config),
        .gpgx => try dumpGpgx(allocator, config),
    }
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
    var mode: CaptureMode = .normal;

    if (maybe_frames_arg) |arg| {
        if (!std.mem.startsWith(u8, arg, "--")) {
            frames = try std.fmt.parseInt(usize, arg, 10);
        } else if (std.mem.eql(u8, arg, "--mode")) {
            const mode_arg = args.next() orelse return usageError();
            mode = try CaptureMode.parse(mode_arg);
        } else if (std.mem.eql(u8, arg, "--skip")) {
            const skip_arg = args.next() orelse return usageError();
            skip_frames = try std.fmt.parseInt(usize, skip_arg, 10);
        } else {
            return usageError();
        }
    }

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--mode")) {
            const mode_arg = args.next() orelse return usageError();
            mode = try CaptureMode.parse(mode_arg);
        } else if (std.mem.eql(u8, arg, "--skip")) {
            const skip_arg = args.next() orelse return usageError();
            skip_frames = try std.fmt.parseInt(usize, skip_arg, 10);
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
        .mode = mode,
        .gpgx_core_path = try allocator.dupe(u8, default_gpgx_core_path),
    };
}

fn usageError() error{InvalidArgs} {
    std.debug.print(
        "Usage: zig build dump-audio -- <sandopolis|gpgx> <rom-path> <wav-path> [frames] [--skip frames] [--mode normal|ym-only|psg-only|unfiltered-mix]\n",
        .{},
    );
    return error.InvalidArgs;
}

fn dumpSandopolis(allocator: std.mem.Allocator, config: Config) !void {
    var emulator = try testing.Emulator.init(allocator, config.rom_path);
    defer emulator.deinit(allocator);

    var output = AudioOutput.init();
    output.setRenderMode(switch (config.mode) {
        .normal => .normal,
        .ym_only => .ym_only,
        .psg_only => .psg_only,
        .unfiltered_mix => .unfiltered_mix,
    });
    var recorder = try WavRecorder.start(config.out_path, AudioOutput.output_rate, AudioOutput.channels);
    var sink = WavSink{ .recorder = &recorder };
    defer recorder.finish();
    var total_ym_writes: u64 = 0;
    var total_ym_dac_samples: u64 = 0;
    var total_psg_commands: u64 = 0;

    for (0..config.skip_frames) |_| {
        emulator.runFrame();
        total_ym_writes += emulator.pendingYmWriteCount();
        total_ym_dac_samples += emulator.pendingYmDacCount();
        total_psg_commands += emulator.pendingPsgCommandCount();
        try emulator.discardPendingAudioWithOutput(&output);
    }

    var total_m68k_instructions: u64 = 0;
    var total_z80_instructions: u64 = 0;
    var total_dma_words: u64 = 0;
    for (0..config.frames) |_| {
        const counters = emulator.runFrameProfiled();
        total_m68k_instructions += counters.m68k_instructions;
        total_z80_instructions += counters.z80_instructions;
        total_dma_words += counters.dma_words;
        total_ym_writes += emulator.pendingYmWriteCount();
        total_ym_dac_samples += emulator.pendingYmDacCount();
        total_psg_commands += emulator.pendingPsgCommandCount();
        try emulator.renderPendingAudio(&output, &sink);
    }
    const overflow_count = emulator.takeAudioOverflowCounts();

    std.debug.print(
        "sandopolis: wrote {d} frames to {s} ({d:.2}s) | ym_writes={d} ym_dac={d} psg_cmds={d} overflows={d} z80_pc=0x{X:0>4} busack=0x{X:0>4} reset=0x{X:0>4} ym_key=0x{X:0>2} dac_en=0x{X:0>2} iff1={d} im={d} halt={d}\n",
        .{
            recorder.sample_count,
            config.out_path,
            recorder.getDurationSeconds(),
            total_ym_writes,
            total_ym_dac_samples,
            total_psg_commands,
            overflow_count,
            emulator.z80ProgramCounter(),
            emulator.z80BusAckWord(),
            emulator.z80ResetControlWord(),
            emulator.ymKeyMask(),
            emulator.ymRegister(0, 0x2B),
            emulator.z80Iff1(),
            emulator.z80InterruptMode(),
            emulator.z80Halted(),
        },
    );
    // Read VBlank vector and M68K SR
    const vblank_vec_hi = emulator.read16(0x78);
    const vblank_vec_lo = emulator.read16(0x7A);
    const vblank_vec: u32 = (@as(u32, vblank_vec_hi) << 16) | vblank_vec_lo;
    std.debug.print("m68k_sr=0x{X:0>4} vblank_vec=0x{X:0>8} m68k_pc=0x{X:0>8}\n", .{ emulator.cpuSr(), vblank_vec, emulator.cpuPc() });
    std.debug.print("m68k_insns={d} z80_insns={d} dma_words={d} m68k/frame={d} z80/frame={d}\n", .{
        total_m68k_instructions,
        total_z80_instructions,
        total_dma_words,
        total_m68k_instructions / config.frames,
        total_z80_instructions / config.frames,
    });
    // Dump Z80 state details
    std.debug.print("z80 bank=0x{X:0>3} comm[0x1FF0-0x2000]: ", .{emulator.z80Bank()});
    for (0x1FF0..0x2000) |addr| {
        std.debug.print("{X:0>2} ", .{emulator.z80ReadByte(@intCast(addr))});
    }
    std.debug.print("\n", .{});
}

fn dumpGpgx(allocator: std.mem.Allocator, config: Config) !void {
    var api = try GpgxApi.open(config.gpgx_core_path);
    defer api.close();

    const cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);
    const cwd_z = try allocator.dupeZ(u8, cwd_path);
    defer allocator.free(cwd_z);
    const rom_path_z = try allocator.dupeZ(u8, config.rom_path);
    defer allocator.free(rom_path_z);

    var frontend = GpgxFrontend{
        .system_dir_z = cwd_z,
        .save_dir_z = cwd_z,
        .mode = config.mode,
    };
    active_gpgx_frontend = &frontend;
    defer active_gpgx_frontend = null;

    api.retro_set_environment(gpgxEnvironmentCallback);
    api.retro_set_video_refresh(gpgxVideoRefreshCallback);
    api.retro_set_audio_sample(gpgxAudioSampleCallback);
    api.retro_set_audio_sample_batch(gpgxAudioBatchCallback);
    api.retro_set_input_poll(gpgxInputPollCallback);
    api.retro_set_input_state(gpgxInputStateCallback);
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

    var av_info: c.struct_retro_system_av_info = undefined;
    api.retro_get_system_av_info(&av_info);

    var recorder = try WavRecorder.start(
        config.out_path,
        @intFromFloat(@round(av_info.timing.sample_rate)),
        AudioOutput.channels,
    );
    defer recorder.finish();

    for (0..config.skip_frames) |_| {
        api.retro_run();
    }

    frontend.recorder = &recorder;
    for (0..config.frames) |_| {
        api.retro_run();
        if (frontend.write_failed) return error.WavWriteFailed;
    }

    std.debug.print(
        "gpgx: wrote {d} frames to {s} ({d:.2}s @ {d} Hz)\n",
        .{
            recorder.sample_count,
            config.out_path,
            recorder.getDurationSeconds(),
            recorder.sample_rate,
        },
    );
}
