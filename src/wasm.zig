const std = @import("std");
const Machine = @import("machine.zig").Machine;
const Vdp = @import("video/vdp.zig").Vdp;
const Io = @import("input/io.zig").Io;
const AudioOutput = @import("audio/output.zig").AudioOutput;
const state_file = @import("state_file.zig");

const allocator = std.heap.wasm_allocator;

pub const std_options: std.Options = .{
    .log_level = .err,
    .logFn = wasmLogNoop,
};

fn wasmLogNoop(
    comptime _: std.log.Level,
    comptime _: @TypeOf(.enum_literal),
    comptime _: []const u8,
    _: anytype,
) void {}

// Emulator instance holding machine, audio output, and save state.
const WasmEmulator = struct {
    machine: Machine,
    audio: AudioOutput,
    audio_buffer: [8192]i16,
    audio_sample_count: usize,
    snapshot: ?Machine.Snapshot,
    last_save_buf: ?[]u8,
    last_save_len: usize,
};

const WasmAudioSink = struct {
    buffer: *[8192]i16,
    count: *usize,

    pub fn consumeSamples(self: *WasmAudioSink, samples: []const i16) !void {
        const remaining = self.buffer.len - self.count.*;
        const n = @min(samples.len, remaining);
        @memcpy(self.buffer[self.count.*..][0..n], samples[0..n]);
        self.count.* += n;
    }
};

// Memory allocation for JS interop

export fn sandopolis_alloc(len: usize) ?[*]u8 {
    const slice = allocator.alloc(u8, len) catch return null;
    return slice.ptr;
}

export fn sandopolis_free(ptr: [*]u8, len: usize) void {
    allocator.free(ptr[0..len]);
}

// Lifecycle

export fn sandopolis_create(rom_ptr: [*]const u8, rom_len: usize) ?*WasmEmulator {
    const emu = allocator.create(WasmEmulator) catch return null;
    emu.* = .{
        .machine = Machine.initFromRomBytes(allocator, rom_ptr[0..rom_len]) catch {
            allocator.destroy(emu);
            return null;
        },
        .audio = AudioOutput.init(),
        .audio_buffer = [_]i16{0} ** 8192,
        .audio_sample_count = 0,
        .snapshot = null,
        .last_save_buf = null,
        .last_save_len = 0,
    };
    return emu;
}

export fn sandopolis_destroy(emu: *WasmEmulator) void {
    if (emu.snapshot) |*snap| snap.deinit(allocator);
    if (emu.last_save_buf) |buf| allocator.free(buf);
    emu.machine.deinit(allocator);
    allocator.destroy(emu);
}

// Frame execution

export fn sandopolis_run_frame(emu: *WasmEmulator) void {
    emu.machine.runFrame();
}

// Video

export fn sandopolis_framebuffer_ptr(emu: *const WasmEmulator) [*]const u32 {
    return emu.machine.framebuffer().ptr;
}

export fn sandopolis_framebuffer_len(emu: *const WasmEmulator) usize {
    return emu.machine.framebuffer().len;
}

export fn sandopolis_screen_width(emu: *const WasmEmulator) u32 {
    return emu.machine.bus.vdp.screenWidth();
}

export fn sandopolis_screen_height(emu: *const WasmEmulator) u32 {
    return emu.machine.bus.vdp.activeVisibleLines();
}

// Input

export fn sandopolis_set_button(emu: *WasmEmulator, port: u32, button: u16, pressed: bool) void {
    emu.machine.bus.io.setButton(@intCast(port), button, pressed);
}

// Machine control

export fn sandopolis_reset(emu: *WasmEmulator) void {
    emu.machine.softReset();
}

export fn sandopolis_is_pal(emu: *const WasmEmulator) bool {
    return emu.machine.palMode();
}

// Audio

export fn sandopolis_audio_render(emu: *WasmEmulator) usize {
    emu.audio_sample_count = 0;
    const pending = emu.machine.takePendingAudio();
    var sink = WasmAudioSink{
        .buffer = &emu.audio_buffer,
        .count = &emu.audio_sample_count,
    };
    emu.audio.renderPending(pending, &emu.machine.bus.z80, emu.machine.palMode(), &sink) catch {};
    return emu.audio_sample_count;
}

export fn sandopolis_audio_buffer_ptr(emu: *const WasmEmulator) [*]const i16 {
    return &emu.audio_buffer;
}

export fn sandopolis_set_audio_mode(emu: *WasmEmulator, mode: u8) void {
    emu.audio.setRenderMode(switch (mode) {
        1 => .ym_only,
        2 => .psg_only,
        3 => .unfiltered_mix,
        else => .normal,
    });
}

export fn sandopolis_get_audio_mode(emu: *const WasmEmulator) u8 {
    return switch (emu.audio.render_mode) {
        .normal => 0,
        .ym_only => 1,
        .psg_only => 2,
        .unfiltered_mix => 3,
    };
}

export fn sandopolis_set_psg_volume(emu: *WasmEmulator, percent: u8) void {
    emu.audio.setPsgVolume(percent);
}

export fn sandopolis_get_psg_volume(emu: *const WasmEmulator) u8 {
    return emu.audio.psg_volume_percent;
}

// Settings

export fn sandopolis_set_controller_type(emu: *WasmEmulator, port: u32, ct: u8) void {
    const controller_type: Io.ControllerType = switch (ct) {
        0 => .three_button,
        2 => .ea_4way_play,
        3 => .sega_mouse,
        else => .six_button,
    };
    emu.machine.bus.io.setControllerType(@intCast(port), controller_type);
}

export fn sandopolis_get_controller_type(emu: *const WasmEmulator, port: u32) u8 {
    return switch (emu.machine.bus.io.controller_types[@intCast(port)]) {
        .three_button => 0,
        .six_button => 1,
        .ea_4way_play => 2,
        .sega_mouse => 3,
    };
}

// Quick save/load (in-memory snapshots)

export fn sandopolis_quick_save(emu: *WasmEmulator) bool {
    if (emu.snapshot) |*old| old.deinit(allocator);
    emu.snapshot = emu.machine.captureSnapshot(allocator) catch {
        emu.snapshot = null;
        return false;
    };
    return true;
}

export fn sandopolis_quick_load(emu: *WasmEmulator) bool {
    const snap = &(emu.snapshot orelse return false);
    emu.machine.restoreSnapshot(allocator, snap) catch return false;
    emu.audio.reset();
    return true;
}

// Persistent save/load (serialized bytes for IndexedDB)

export fn sandopolis_save_state(emu: *WasmEmulator) ?[*]u8 {
    if (emu.last_save_buf) |buf| allocator.free(buf);
    emu.last_save_buf = null;
    emu.last_save_len = 0;

    const buf = state_file.saveToBuffer(allocator, &emu.machine) catch return null;
    emu.last_save_buf = buf;
    emu.last_save_len = buf.len;
    return buf.ptr;
}

export fn sandopolis_save_state_len(emu: *const WasmEmulator) usize {
    return emu.last_save_len;
}

export fn sandopolis_free_save_buffer(emu: *WasmEmulator) void {
    if (emu.last_save_buf) |buf| allocator.free(buf);
    emu.last_save_buf = null;
    emu.last_save_len = 0;
}

export fn sandopolis_load_state(emu: *WasmEmulator, ptr: [*]const u8, len: usize) bool {
    var new_machine = state_file.loadFromBuffer(allocator, ptr[0..len]) catch return false;
    emu.machine.deinit(allocator);
    emu.machine = new_machine;
    emu.audio.reset();
    _ = &new_machine;
    return true;
}

// Button constants

export fn sandopolis_button_up() u16 {
    return Io.Button.Up;
}
export fn sandopolis_button_down() u16 {
    return Io.Button.Down;
}
export fn sandopolis_button_left() u16 {
    return Io.Button.Left;
}
export fn sandopolis_button_right() u16 {
    return Io.Button.Right;
}
export fn sandopolis_button_a() u16 {
    return Io.Button.A;
}
export fn sandopolis_button_b() u16 {
    return Io.Button.B;
}
export fn sandopolis_button_c() u16 {
    return Io.Button.C;
}
export fn sandopolis_button_start() u16 {
    return Io.Button.Start;
}
export fn sandopolis_button_x() u16 {
    return Io.Button.X;
}
export fn sandopolis_button_y() u16 {
    return Io.Button.Y;
}
export fn sandopolis_button_z() u16 {
    return Io.Button.Z;
}
