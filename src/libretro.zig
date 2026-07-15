const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const Io = @import("input/io.zig").Io;
const AudioOutput = @import("audio/output.zig").AudioOutput;
const SystemMachine = @import("system_machine.zig").SystemMachine;
const system_detect = @import("system.zig");

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
    machine: SystemMachine,
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
        .valid_extensions = "bin|md|smd|gen|sms|gg|sg",
        .need_fullpath = false,
        .block_extract = false,
    };
}

export fn retro_get_system_av_info(info: *RetroSystemAvInfo) callconv(.c) void {
    // Never leave the out-param uninitialized, even on out-of-spec call
    // ordering (no game loaded).
    info.* = std.mem.zeroes(RetroSystemAvInfo);
    const c_state = core orelse return;

    info.* = .{
        .geometry = .{
            .base_width = c_state.machine.framebufferWidth(),
            .base_height = c_state.machine.screenHeight(),
            .max_width = SystemMachine.maxFramebufferWidth(),
            .max_height = SystemMachine.maxFramebufferHeight(),
            .aspect_ratio = 4.0 / 3.0,
        },
        .timing = .{
            .fps = c_state.machine.framesPerSecond(),
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

    // Poll input. The facade maps the Genesis-style masks onto SMS buttons.
    if (input_poll_cb) |poll| poll();
    if (input_state_cb) |state_cb| {
        for (0..2) |port| {
            const p: c_uint = @intCast(port);
            const button_map = [_]struct { retro: c_uint, gen: u16 }{
                .{ .retro = RETRO_DEVICE_ID_JOYPAD_UP, .gen = Io.Button.Up },
                .{ .retro = RETRO_DEVICE_ID_JOYPAD_DOWN, .gen = Io.Button.Down },
                .{ .retro = RETRO_DEVICE_ID_JOYPAD_LEFT, .gen = Io.Button.Left },
                .{ .retro = RETRO_DEVICE_ID_JOYPAD_RIGHT, .gen = Io.Button.Right },
                .{ .retro = RETRO_DEVICE_ID_JOYPAD_B, .gen = Io.Button.A },
                .{ .retro = RETRO_DEVICE_ID_JOYPAD_A, .gen = Io.Button.B },
                .{ .retro = RETRO_DEVICE_ID_JOYPAD_X, .gen = Io.Button.C },
                .{ .retro = RETRO_DEVICE_ID_JOYPAD_START, .gen = Io.Button.Start },
                .{ .retro = RETRO_DEVICE_ID_JOYPAD_Y, .gen = Io.Button.X },
                .{ .retro = RETRO_DEVICE_ID_JOYPAD_L, .gen = Io.Button.Y },
                .{ .retro = RETRO_DEVICE_ID_JOYPAD_R, .gen = Io.Button.Z },
                .{ .retro = RETRO_DEVICE_ID_JOYPAD_SELECT, .gen = Io.Button.Mode },
            };
            for (button_map) |mapping| {
                const pressed = state_cb(p, RETRO_DEVICE_JOYPAD, 0, mapping.retro) != 0;
                c_state.machine.setButton(@intCast(port), mapping.gen, pressed);
            }
        }
    }

    // Run one frame.
    c_state.machine.runFrame();

    // Video output.
    if (video_cb) |vcb| {
        const fb = c_state.machine.framebuffer();
        const w = c_state.machine.framebufferWidth();
        const h = c_state.machine.screenHeight();
        const pitch = @as(usize, c_state.machine.framebufferStride()) * @sizeOf(u32);
        vcb(fb.ptr, w, h, pitch);
    }

    // Audio output. Genesis renders pending event-based audio through
    // AudioOutput; SMS/GG audio is already rendered per frame.
    if (c_state.machine.audioZ80()) |z80| {
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
            z80,
            c_state.machine.palMode(),
            &sink,
        ) catch {};
    } else if (c_state.machine.smsAudioBuffer()) |sms_samples| {
        const n = @min(sms_samples.len, c_state.audio_buffer.len);
        @memcpy(c_state.audio_buffer[0..n], sms_samples[0..n]);
        c_state.audio_sample_count = n;
    }

    if (audio_batch_cb) |batch| {
        const frames = c_state.audio_sample_count / AudioOutput.channels;
        if (frames > 0) {
            _ = batch(&c_state.audio_buffer, frames);
        }
    }
}

export fn retro_serialize_size() callconv(.c) usize {
    const c_state = core orelse return 0;
    const buf = c_state.machine.saveStateToBuffer(allocator) catch return 0;
    defer allocator.free(buf);
    return buf.len;
}

export fn retro_serialize(data: ?*anyopaque, size: usize) callconv(.c) bool {
    const c_state = core orelse return false;
    const buf = c_state.machine.saveStateToBuffer(allocator) catch return false;
    defer allocator.free(buf);
    if (buf.len > size) return false;
    const out: [*]u8 = @ptrCast(data orelse return false);
    @memcpy(out[0..buf.len], buf);
    return true;
}

export fn retro_unserialize(data: ?*const anyopaque, size: usize) callconv(.c) bool {
    const c_state = core orelse return false;
    const in: [*]const u8 = @ptrCast(data orelse return false);
    c_state.machine.loadStateFromBuffer(allocator, in[0..size]) catch return false;
    if (c_state.machine.audioZ80()) |z80| c_state.audio.syncYmStateFromZ80(z80);
    return true;
}

export fn retro_cheat_reset() callconv(.c) void {}

export fn retro_cheat_set(_: c_uint, _: bool, _: ?[*:0]const u8) callconv(.c) void {}

export fn retro_load_game(game: ?*const RetroGameInfo) callconv(.c) bool {
    const info = game orelse return false;
    const rom_data = info.data orelse return false;
    if (info.size == 0) return false;

    // The framebuffer is XRGB8888 (u32); without this the frontend assumes
    // the libretro default 0RGB1555 and renders garbage.
    const env = environment_cb orelse return false;
    var pixel_format: c_int = 1; // RETRO_PIXEL_FORMAT_XRGB8888
    if (!env(10, @ptrCast(&pixel_format))) return false; // RETRO_ENVIRONMENT_SET_PIXEL_FORMAT

    // Free a still-loaded instance if the frontend skips retro_unload_game.
    retro_unload_game();

    // Prefer the file extension for system detection when the frontend
    // provides a path (e.g. ".sg" for SG-1000 ROMs that content detection
    // cannot distinguish from SMS); fall back to content-based detection.
    const hint: ?system_detect.SystemType = if (info.path) |p|
        system_detect.detectSystemFromExtension(std.mem.span(p))
    else
        null;

    const c_state = allocator.create(CoreState) catch return false;
    c_state.* = .{
        .machine = SystemMachine.initFromRomBytes(allocator, rom_data[0..info.size], hint) catch {
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
        RETRO_MEMORY_SAVE_RAM => if (c_state.machine.persistentSaveRam()) |bytes| @ptrCast(bytes.ptr) else null,
        RETRO_MEMORY_SYSTEM_RAM => @ptrCast(c_state.machine.workRam().ptr),
        else => null,
    };
}

export fn retro_get_memory_size(id: c_uint) callconv(.c) usize {
    const c_state = core orelse return 0;
    return switch (id) {
        RETRO_MEMORY_SAVE_RAM => if (c_state.machine.persistentSaveRam()) |bytes| bytes.len else 0,
        RETRO_MEMORY_SYSTEM_RAM => c_state.machine.workRam().len,
        else => 0,
    };
}

test "retro memory api exposes battery sram" {
    const talloc = std.testing.allocator;
    var rom = [_]u8{0} ** 0x400;
    @memcpy(rom[0x100..0x104], "SEGA");
    rom[0x1B0] = 'R';
    rom[0x1B1] = 'A';
    rom[0x1B2] = 0xF8;
    rom[0x1B3] = 0x20;
    std.mem.writeInt(u32, rom[0x1B4..0x1B8], 0x200001, .big);
    std.mem.writeInt(u32, rom[0x1B8..0x1BC], 0x203FFF, .big);

    var machine = try SystemMachine.initFromRomBytes(talloc, &rom, null);
    defer machine.deinit(talloc);

    const bytes = machine.persistentSaveRam() orelse return error.TestUnexpectedResult;
    try std.testing.expect(bytes.len > 0);
    try std.testing.expectEqual(@as(usize, 64 * 1024), machine.workRam().len);

    // A machine with no SRAM header and no EEPROM exposes nothing.
    var plain = try SystemMachine.initFromRomBytes(talloc, &[_]u8{0} ** 0x400, null);
    defer plain.deinit(talloc);
    try std.testing.expectEqual(@as(?[]u8, null), plain.persistentSaveRam());
}

test "libretro core runs sms machines through the facade" {
    const talloc = std.testing.allocator;
    const rom = [_]u8{0} ** 0x4000;
    var machine = try SystemMachine.initFromRomBytes(talloc, &rom, .sms);
    defer machine.deinit(talloc);

    machine.runFrame();
    try std.testing.expectEqual(@as(u16, 256), machine.framebufferWidth());
    try std.testing.expectEqual(@as(usize, 8 * 1024), machine.workRam().len);
    try std.testing.expectEqual(@as(?[]u8, null), machine.persistentSaveRam());
    try std.testing.expect(machine.smsAudioBuffer() != null);
    try std.testing.expect(machine.framesPerSecond() > 59.0);
    try std.testing.expect(machine.framesPerSecond() < 61.0);
}
