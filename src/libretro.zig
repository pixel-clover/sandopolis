const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const Machine = @import("machine.zig").Machine;
const Vdp = @import("video/vdp.zig").Vdp;
const Io = @import("input/io.zig").Io;
const AudioOutput = @import("audio/output.zig").AudioOutput;
const state_file = @import("state_file.zig");
const clock = @import("clock.zig");

// Libretro API constants.
const RETRO_API_VERSION: c_uint = 1;
const RETRO_REGION_NTSC: c_uint = 0;
const RETRO_REGION_PAL: c_uint = 1;
const RETRO_MEMORY_SAVE_RAM: c_uint = 0;
const RETRO_MEMORY_SYSTEM_RAM: c_uint = 2;

const RETRO_DEVICE_JOYPAD: c_uint = 1;

// Joypad button IDs (standard SNES-style mapping).
const RETRO_DEVICE_ID_JOYPAD_B: c_uint = 0;
const RETRO_DEVICE_ID_JOYPAD_Y: c_uint = 1;
const RETRO_DEVICE_ID_JOYPAD_SELECT: c_uint = 2;
const RETRO_DEVICE_ID_JOYPAD_START: c_uint = 3;
const RETRO_DEVICE_ID_JOYPAD_UP: c_uint = 4;
const RETRO_DEVICE_ID_JOYPAD_DOWN: c_uint = 5;
const RETRO_DEVICE_ID_JOYPAD_LEFT: c_uint = 6;
const RETRO_DEVICE_ID_JOYPAD_RIGHT: c_uint = 7;
const RETRO_DEVICE_ID_JOYPAD_A: c_uint = 8;
const RETRO_DEVICE_ID_JOYPAD_X: c_uint = 9;
const RETRO_DEVICE_ID_JOYPAD_L: c_uint = 10;
const RETRO_DEVICE_ID_JOYPAD_R: c_uint = 11;

// Genesis button masks (from io.zig).
const GEN_UP: u16 = 0x0001;
const GEN_DOWN: u16 = 0x0002;
const GEN_LEFT: u16 = 0x0004;
const GEN_RIGHT: u16 = 0x0008;
const GEN_B: u16 = 0x0010;
const GEN_C: u16 = 0x0020;
const GEN_A: u16 = 0x0040;
const GEN_START: u16 = 0x0080;
const GEN_Z: u16 = 0x0100;
const GEN_Y: u16 = 0x0200;
const GEN_X: u16 = 0x0400;
const GEN_MODE: u16 = 0x0800;

// Libretro callback types.
const RetroEnvironmentFn = *const fn (c_uint, ?*anyopaque) callconv(.c) bool;
const RetroVideoRefreshFn = *const fn (?*const anyopaque, c_uint, c_uint, usize) callconv(.c) void;
const RetroAudioSampleFn = *const fn (i16, i16) callconv(.c) void;
const RetroAudioSampleBatchFn = *const fn ([*]const i16, usize) callconv(.c) usize;
const RetroInputPollFn = *const fn () callconv(.c) void;
const RetroInputStateFn = *const fn (c_uint, c_uint, c_uint, c_uint) callconv(.c) i16;

// Libretro structs.
const RetroSystemInfo = extern struct {
    library_name: [*:0]const u8,
    library_version: [*:0]const u8,
    valid_extensions: [*:0]const u8,
    need_fullpath: bool,
    block_extract: bool,
};

const RetroGameGeometry = extern struct {
    base_width: c_uint,
    base_height: c_uint,
    max_width: c_uint,
    max_height: c_uint,
    aspect_ratio: f32,
};

const RetroSystemTiming = extern struct {
    fps: f64,
    sample_rate: f64,
};

const RetroSystemAvInfo = extern struct {
    geometry: RetroGameGeometry,
    timing: RetroSystemTiming,
};

const RetroGameInfo = extern struct {
    path: ?[*:0]const u8,
    data: ?[*]const u8,
    size: usize,
    meta: ?[*:0]const u8,
};

// Core state.
var environment_cb: ?RetroEnvironmentFn = null;
var video_cb: ?RetroVideoRefreshFn = null;
var audio_sample_cb: ?RetroAudioSampleFn = null;
var audio_batch_cb: ?RetroAudioSampleBatchFn = null;
var input_poll_cb: ?RetroInputPollFn = null;
var input_state_cb: ?RetroInputStateFn = null;

const allocator: std.mem.Allocator = std.heap.page_allocator;

const CoreState = struct {
    machine: Machine,
    audio: AudioOutput,
    audio_buffer: [8192]i16,
    audio_sample_count: usize,
};

var core: ?*CoreState = null;

// --- Required Libretro API exports ---

export fn retro_set_environment(cb: RetroEnvironmentFn) callconv(.c) void {
    environment_cb = cb;
}

export fn retro_set_video_refresh(cb: RetroVideoRefreshFn) callconv(.c) void {
    video_cb = cb;
}

export fn retro_set_audio_sample(cb: RetroAudioSampleFn) callconv(.c) void {
    audio_sample_cb = cb;
}

export fn retro_set_audio_sample_batch(cb: RetroAudioSampleBatchFn) callconv(.c) void {
    audio_batch_cb = cb;
}

export fn retro_set_input_poll(cb: RetroInputPollFn) callconv(.c) void {
    input_poll_cb = cb;
}

export fn retro_set_input_state(cb: RetroInputStateFn) callconv(.c) void {
    input_state_cb = cb;
}

export fn retro_init() callconv(.c) void {}

export fn retro_deinit() callconv(.c) void {
    if (core) |c| {
        c.machine.deinit(allocator);
        allocator.destroy(c);
        core = null;
    }
}

export fn retro_api_version() callconv(.c) c_uint {
    return RETRO_API_VERSION;
}

export fn retro_get_system_info(info: *RetroSystemInfo) callconv(.c) void {
    info.* = .{
        .library_name = "Sandopolis",
        .library_version = std.fmt.comptimePrint("{s}", .{build_options.version}),
        .valid_extensions = "bin|md|smd",
        .need_fullpath = false,
        .block_extract = false,
    };
}

export fn retro_get_system_av_info(info: *RetroSystemAvInfo) callconv(.c) void {
    const c_state = core orelse return;
    const is_pal = c_state.machine.palMode();
    const fps: f64 = if (is_pal)
        @as(f64, @floatFromInt(clock.master_clock_pal)) / @as(f64, @floatFromInt(clock.pal_master_cycles_per_frame))
    else
        @as(f64, @floatFromInt(clock.master_clock_ntsc)) / @as(f64, @floatFromInt(clock.ntsc_master_cycles_per_frame));

    info.* = .{
        .geometry = .{
            .base_width = c_state.machine.bus.vdp.screenWidth(),
            .base_height = c_state.machine.bus.vdp.activeVisibleLines(),
            .max_width = Vdp.framebuffer_width,
            .max_height = Vdp.max_framebuffer_height,
            .aspect_ratio = 4.0 / 3.0,
        },
        .timing = .{
            .fps = fps,
            .sample_rate = @as(f64, AudioOutput.output_rate),
        },
    };
}

export fn retro_set_controller_port_device(_: c_uint, _: c_uint) callconv(.c) void {}

export fn retro_reset() callconv(.c) void {
    if (core) |c| c.machine.softReset();
}

export fn retro_run() callconv(.c) void {
    const c_state = core orelse return;

    // Poll input.
    if (input_poll_cb) |poll| poll();
    if (input_state_cb) |state_cb| {
        for (0..2) |port| {
            const p: c_uint = @intCast(port);
            const button_map = [_]struct { retro: c_uint, gen: u16 }{
                .{ .retro = RETRO_DEVICE_ID_JOYPAD_UP, .gen = GEN_UP },
                .{ .retro = RETRO_DEVICE_ID_JOYPAD_DOWN, .gen = GEN_DOWN },
                .{ .retro = RETRO_DEVICE_ID_JOYPAD_LEFT, .gen = GEN_LEFT },
                .{ .retro = RETRO_DEVICE_ID_JOYPAD_RIGHT, .gen = GEN_RIGHT },
                .{ .retro = RETRO_DEVICE_ID_JOYPAD_B, .gen = GEN_A },
                .{ .retro = RETRO_DEVICE_ID_JOYPAD_A, .gen = GEN_B },
                .{ .retro = RETRO_DEVICE_ID_JOYPAD_X, .gen = GEN_C },
                .{ .retro = RETRO_DEVICE_ID_JOYPAD_START, .gen = GEN_START },
                .{ .retro = RETRO_DEVICE_ID_JOYPAD_Y, .gen = GEN_X },
                .{ .retro = RETRO_DEVICE_ID_JOYPAD_L, .gen = GEN_Y },
                .{ .retro = RETRO_DEVICE_ID_JOYPAD_R, .gen = GEN_Z },
                .{ .retro = RETRO_DEVICE_ID_JOYPAD_SELECT, .gen = GEN_MODE },
            };
            for (button_map) |mapping| {
                const pressed = state_cb(p, RETRO_DEVICE_JOYPAD, 0, mapping.retro) != 0;
                c_state.machine.bus.io.setButton(port, mapping.gen, pressed);
            }
        }
    }

    // Run one frame.
    c_state.machine.runFrame();

    // Video output.
    if (video_cb) |vcb| {
        const fb = c_state.machine.framebuffer();
        const w = c_state.machine.bus.vdp.screenWidth();
        const h = c_state.machine.bus.vdp.activeVisibleLines();
        const pitch = Vdp.framebuffer_width * @sizeOf(u32);
        vcb(fb.ptr, w, h, pitch);
    }

    // Audio output.
    c_state.audio_sample_count = 0;
    const pending = c_state.machine.takePendingAudio();
    const LibretroAudioSink = struct {
        buf: *[8192]i16,
        count: *usize,

        pub fn consumeSamples(self: *@This(), samples: []const i16) !void {
            const remaining = self.buf.len - self.count.*;
            const n = @min(samples.len, remaining);
            @memcpy(self.buf[self.count.*..][0..n], samples[0..n]);
            self.count.* += n;
        }
    };
    var sink = LibretroAudioSink{
        .buf = &c_state.audio_buffer,
        .count = &c_state.audio_sample_count,
    };
    c_state.audio.renderPending(
        pending,
        &c_state.machine.bus.z80,
        c_state.machine.palMode(),
        &sink,
    ) catch {};

    if (audio_batch_cb) |batch| {
        const frames = c_state.audio_sample_count / AudioOutput.channels;
        if (frames > 0) {
            _ = batch(&c_state.audio_buffer, frames);
        }
    }
}

export fn retro_serialize_size() callconv(.c) usize {
    const c_state = core orelse return 0;
    const buf = state_file.saveToBuffer(allocator, &c_state.machine) catch return 0;
    defer allocator.free(buf);
    return buf.len;
}

export fn retro_serialize(data: ?*anyopaque, size: usize) callconv(.c) bool {
    const c_state = core orelse return false;
    const buf = state_file.saveToBuffer(allocator, &c_state.machine) catch return false;
    defer allocator.free(buf);
    if (buf.len > size) return false;
    const out: [*]u8 = @ptrCast(data orelse return false);
    @memcpy(out[0..buf.len], buf);
    return true;
}

export fn retro_unserialize(data: ?*const anyopaque, size: usize) callconv(.c) bool {
    const c_state = core orelse return false;
    const in: [*]const u8 = @ptrCast(data orelse return false);
    var restored = state_file.loadFromBuffer(allocator, in[0..size]) catch return false;
    c_state.machine.deinit(allocator);
    c_state.machine = restored;
    c_state.machine.rebindRuntimePointers();
    c_state.machine.clearPendingAudioTransferState();
    _ = &restored;
    return true;
}

export fn retro_cheat_reset() callconv(.c) void {}

export fn retro_cheat_set(_: c_uint, _: bool, _: ?[*:0]const u8) callconv(.c) void {}

export fn retro_load_game(game: ?*const RetroGameInfo) callconv(.c) bool {
    const info = game orelse return false;
    const rom_data = info.data orelse return false;
    if (info.size == 0) return false;

    const c_state = allocator.create(CoreState) catch return false;
    c_state.* = .{
        .machine = Machine.initFromRomBytes(allocator, rom_data[0..info.size]) catch {
            allocator.destroy(c_state);
            return false;
        },
        .audio = AudioOutput.init(),
        .audio_buffer = [_]i16{0} ** 8192,
        .audio_sample_count = 0,
    };
    c_state.machine.reset();
    core = c_state;
    return true;
}

export fn retro_load_game_special(_: c_uint, _: ?*const RetroGameInfo, _: usize) callconv(.c) bool {
    return false;
}

export fn retro_unload_game() callconv(.c) void {
    if (core) |c| {
        c.machine.deinit(allocator);
        allocator.destroy(c);
        core = null;
    }
}

export fn retro_get_region() callconv(.c) c_uint {
    const c_state = core orelse return RETRO_REGION_NTSC;
    return if (c_state.machine.palMode()) RETRO_REGION_PAL else RETRO_REGION_NTSC;
}

export fn retro_get_memory_data(id: c_uint) callconv(.c) ?*anyopaque {
    const c_state = core orelse return null;
    return switch (id) {
        RETRO_MEMORY_SYSTEM_RAM => @ptrCast(&c_state.machine.bus.ram),
        else => null,
    };
}

export fn retro_get_memory_size(id: c_uint) callconv(.c) usize {
    _ = core orelse return 0;
    return switch (id) {
        RETRO_MEMORY_SYSTEM_RAM => 64 * 1024,
        else => 0,
    };
}
