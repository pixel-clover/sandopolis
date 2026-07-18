const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const Io = @import("input/io.zig").Io;
const AudioOutput = @import("audio/output.zig").AudioOutput;
const state_file = @import("state_file.zig");
const system_detect = @import("system.zig");
const SystemMachine = @import("system_machine.zig").SystemMachine;

const allocator: std.mem.Allocator = if (builtin.target.cpu.arch == .wasm32)
    std.heap.wasm_allocator
else
    std.heap.page_allocator;
const version_cstr = std.fmt.comptimePrint("{s}", .{build_options.version});
const build_label_cstr = std.fmt.comptimePrint("Zig {s}", .{builtin.zig_version_string});
const git_ref_cstr = std.fmt.comptimePrint("{s}@{s}", .{ build_options.git_branch, build_options.git_hash });
const build_time_cstr = std.fmt.comptimePrint("{s}", .{build_options.build_time});

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
    machine: SystemMachine,
    audio: AudioOutput,
    snapshot: ?SystemMachine.Snapshot,
    audio_buffer: [8192]i16,
    audio_sample_count: usize,
    last_save_buf: ?[]u8,
    last_save_len: usize,
    frame_count: u64 = 0,
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

fn initWasmEmulator(alloc: std.mem.Allocator, raw_bytes: []const u8, system_hint: u8) !WasmEmulator {
    // Use the system hint from JS if provided (e.g. from file extension);
    // fall back to content-based detection.
    const hint: ?system_detect.SystemType = switch (system_hint) {
        1 => .sms,
        2 => .gg,
        3 => .sg1000,
        else => null,
    };
    var machine = try SystemMachine.initFromRomBytes(alloc, raw_bytes, hint);
    // Genesis boots through an explicit reset; SMS power-on state is the
    // init state and its runtime pointers bind lazily on the first frame.
    if (machine.asGenesis()) |g| g.reset();
    return .{
        .machine = machine,
        .audio = AudioOutput.init(),
        .snapshot = null,
        .audio_buffer = [_]i16{0} ** 8192,
        .audio_sample_count = 0,
        .last_save_buf = null,
        .last_save_len = 0,
    };
}

// Memory allocation for JS interop

export fn sandopolis_alloc(len: usize) ?[*]u8 {
    const slice = allocator.alloc(u8, len) catch return null;
    return slice.ptr;
}

export fn sandopolis_free(ptr: [*]u8, len: usize) void {
    allocator.free(ptr[0..len]);
}

// Lifecycle

/// Create an emulator instance. `system_hint`: 0=auto-detect, 1=SMS, 2=GG, 3=SG-1000.
export fn sandopolis_create(rom_ptr: [*]const u8, rom_len: usize, system_hint: u8) ?*WasmEmulator {
    const emu = allocator.create(WasmEmulator) catch return null;
    emu.* = initWasmEmulator(allocator, rom_ptr[0..rom_len], system_hint) catch {
        allocator.destroy(emu);
        return null;
    };
    return emu;
}

export fn sandopolis_destroy(emu: *WasmEmulator) void {
    if (emu.last_save_buf) |buf| allocator.free(buf);
    if (emu.snapshot) |*snap| snap.deinit(allocator);
    emu.machine.deinit(allocator);
    allocator.destroy(emu);
}

// Frame execution

export fn sandopolis_run_frame(emu: *WasmEmulator) void {
    emu.machine.runFrame();
    emu.frame_count += 1;
}

// Video

export fn sandopolis_framebuffer_ptr(emu: *const WasmEmulator) [*]const u32 {
    return emu.machine.framebuffer().ptr;
}

export fn sandopolis_framebuffer_len(emu: *const WasmEmulator) usize {
    return emu.machine.framebuffer().len;
}

export fn sandopolis_screen_width(emu: *const WasmEmulator) u32 {
    return emu.machine.framebufferWidth();
}

export fn sandopolis_framebuffer_stride(emu: *const WasmEmulator) u32 {
    return emu.machine.framebufferStride();
}

export fn sandopolis_screen_height(emu: *const WasmEmulator) u32 {
    return emu.machine.screenHeight();
}

// Input

export fn sandopolis_set_button(emu: *WasmEmulator, port: u32, button: u16, pressed: bool) void {
    emu.machine.setButton(port, button, pressed);
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
    if (emu.machine.audioZ80()) |z80| {
        const pending = emu.machine.takePendingAudio();
        var sink = WasmAudioSink{
            .buffer = &emu.audio_buffer,
            .count = &emu.audio_sample_count,
        };
        emu.audio.renderPending(pending, z80, emu.machine.palMode(), &sink) catch {};
    } else if (emu.machine.smsAudioBuffer()) |src| {
        // SMS audio is rendered during runFrame; copy from the SMS audio
        // buffer. audioBuffer() returns interleaved stereo i16 (L, R, ...).
        // audio_sample_count must match Genesis convention: total i16 count
        // (not stereo pairs), since JS reads this many elements.
        const n = @min(src.len, emu.audio_buffer.len);
        @memcpy(emu.audio_buffer[0..n], src[0..n]);
        emu.audio_sample_count = n;
    }
    return emu.audio_sample_count;
}

export fn sandopolis_audio_buffer_ptr(emu: *const WasmEmulator) [*]const i16 {
    return &emu.audio_buffer;
}

export fn sandopolis_set_audio_mode(emu: *WasmEmulator, mode: u8) void {
    // Audio render settings only affect the Genesis path; the SMS path
    // bypasses AudioOutput, so for SMS these are inert.
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

export fn sandopolis_set_eq_enabled(emu: *WasmEmulator, enabled: u8) void {
    emu.audio.setEqEnabled(enabled != 0);
}

export fn sandopolis_get_eq_enabled(emu: *const WasmEmulator) u8 {
    return if (emu.audio.eq_enabled) 1 else 0;
}

export fn sandopolis_set_eq_gains(emu: *WasmEmulator, low: f64, mid: f64, high: f64) void {
    emu.audio.setEqGains(low, mid, high);
}

export fn sandopolis_get_eq_low(emu: *const WasmEmulator) f64 {
    return emu.audio.eq_left.lg;
}

export fn sandopolis_get_eq_mid(emu: *const WasmEmulator) f64 {
    return emu.audio.eq_left.mg;
}

export fn sandopolis_get_eq_high(emu: *const WasmEmulator) f64 {
    return emu.audio.eq_left.hg;
}

// About metadata

export fn sandopolis_version_ptr() [*:0]const u8 {
    return version_cstr.ptr;
}

export fn sandopolis_version_len() usize {
    return version_cstr.len;
}

export fn sandopolis_build_label_ptr() [*:0]const u8 {
    return build_label_cstr.ptr;
}

export fn sandopolis_build_label_len() usize {
    return build_label_cstr.len;
}

export fn sandopolis_git_hash_ptr() [*:0]const u8 {
    return git_ref_cstr.ptr;
}

export fn sandopolis_git_hash_len() usize {
    return git_ref_cstr.len;
}

export fn sandopolis_build_time_ptr() [*:0]const u8 {
    return build_time_cstr.ptr;
}

export fn sandopolis_build_time_len() usize {
    return build_time_cstr.len;
}

export fn sandopolis_audio_sample_rate() u32 {
    return AudioOutput.output_rate;
}

export fn sandopolis_video_width() u32 {
    // Maximum framebuffer width across all supported systems
    return SystemMachine.maxFramebufferWidth();
}

export fn sandopolis_save_state_version() u32 {
    return state_file.save_state_version;
}

// Statistics

export fn sandopolis_frame_count(emu: *const WasmEmulator) u32 {
    return @intCast(@min(emu.frame_count, std.math.maxInt(u32)));
}

export fn sandopolis_rom_size(emu: *const WasmEmulator) u32 {
    return @intCast(emu.machine.romSize());
}

export fn sandopolis_rom_title_ptr(emu: *const WasmEmulator) ?[*]const u8 {
    // SMS ROMs carry no title field; the facade reports null for them.
    const meta = emu.machine.romMetadata();
    return if (meta.title) |t| t.ptr else null;
}

export fn sandopolis_rom_title_len() u32 {
    return 0x30; // Fixed length in Genesis header (0x150..0x180)
}

export fn sandopolis_rom_checksum_valid(emu: *const WasmEmulator) bool {
    return emu.machine.romMetadata().checksum_valid;
}

export fn sandopolis_display_mode(emu: *const WasmEmulator) u32 {
    return emu.machine.displayModeFlags();
}

export fn sandopolis_system_type(emu: *const WasmEmulator) u32 {
    return switch (emu.machine.systemType()) {
        .genesis => 0,
        .sms => 1,
        .gg => 2,
        .sg1000 => 3,
    };
}

// Settings

export fn sandopolis_set_controller_type(emu: *WasmEmulator, port: u32, ct: u8) void {
    // SMS has fixed 2-button controllers; controller types are Genesis-only.
    const genesis = emu.machine.asGenesis() orelse return;
    const controller_type: Io.ControllerType = switch (ct) {
        0 => .three_button,
        2 => .ea_4way_play,
        3 => .sega_mouse,
        else => .six_button,
    };
    genesis.setControllerType(@intCast(port), controller_type);
}

export fn sandopolis_get_controller_type(emu: *const WasmEmulator, port: u32) u8 {
    const genesis = emu.machine.asGenesisConst() orelse return 0;
    return switch (genesis.controllerType(@intCast(port))) {
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
    if (emu.machine.audioZ80()) |z80| {
        emu.audio.reset();
        emu.audio.syncYmStateFromZ80(z80);
    }
    return true;
}

// Persistent save/load (serialized bytes for IndexedDB)

export fn sandopolis_save_state(emu: *WasmEmulator) ?[*]u8 {
    if (emu.last_save_buf) |buf| allocator.free(buf);
    emu.last_save_buf = null;
    emu.last_save_len = 0;

    const buf = emu.machine.saveStateToBuffer(allocator) catch return null;
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
    // The facade dispatches on the buffer's magic (and rebinds runtime
    // pointers after placement), so this can even switch system variants.
    emu.machine.loadStateFromBuffer(allocator, ptr[0..len]) catch return false;
    if (emu.machine.audioZ80()) |z80| {
        emu.audio.reset();
        emu.audio.syncYmStateFromZ80(z80);
    }
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

fn makeGenesisRom(alloc: std.mem.Allocator, stack_pointer: u32, program_counter: u32, program: []const u8) ![]u8 {
    const rom_len = @max(@as(usize, 0x4000), 0x0200 + program.len);
    var rom = try alloc.alloc(u8, rom_len);
    @memset(rom, 0);
    @memcpy(rom[0x100..0x104], "SEGA");
    std.mem.writeInt(u32, rom[0..4], stack_pointer, .big);
    std.mem.writeInt(u32, rom[4..8], program_counter, .big);
    @memcpy(rom[0x0200 .. 0x0200 + program.len], program);
    return rom;
}

test "wasm emulator creation resets the machine before the first frame" {
    const test_allocator = std.testing.allocator;
    const rom = try makeGenesisRom(test_allocator, 0x00FF_FE00, 0x0000_0200, &[_]u8{
        0x4E, 0x71,
        0x4E, 0x71,
        0x60, 0xFC,
    });
    defer test_allocator.free(rom);

    var emu = try initWasmEmulator(test_allocator, rom, 0);
    defer emu.machine.deinit(test_allocator);

    const genesis = emu.machine.asGenesis().?;
    try std.testing.expectEqual(@as(@TypeOf(genesis.pending_frame_phase), .hard_reset), genesis.pending_frame_phase);
    try std.testing.expectEqual(@as(u32, 0x0000_0200), genesis.programCounter());

    const pc_before = genesis.programCounter();
    emu.machine.runFrame();
    try std.testing.expect(genesis.programCounter() != pc_before);
}

test "wasm framebuffer stride export reports the row stride independent of screen width" {
    const test_allocator = std.testing.allocator;
    const rom = try makeGenesisRom(test_allocator, 0x00FF_FE00, 0x0000_0200, &[_]u8{
        0x4E, 0x71,
        0x4E, 0x71,
        0x60, 0xFC,
    });
    defer test_allocator.free(rom);

    var emu = try initWasmEmulator(test_allocator, rom, 0);
    defer emu.machine.deinit(test_allocator);

    // The Genesis VDP boots in H32 (256-wide screen), but framebuffer rows
    // are always 320 pixels apart. Reading the framebuffer packed at
    // screen_width shears every row after the first.
    try std.testing.expectEqual(@as(u32, 256), sandopolis_screen_width(&emu));
    try std.testing.expectEqual(@as(u32, 320), sandopolis_framebuffer_stride(&emu));
}

test "wasm sms audio sample count returns interleaved i16 count not stereo pairs" {
    // Regression: the WASM SMS audio path previously returned n/2 (stereo pairs)
    // but JS reads audio_sample_count as individual i16 elements. This caused
    // half the audio data to be silently dropped on the web.
    const rom = [_]u8{0} ** 0x4000;
    var emu = try initWasmEmulator(std.testing.allocator, &rom, 1); // hint=1 (SMS)
    defer emu.machine.deinit(std.testing.allocator);

    // Run a frame to generate audio
    emu.machine.runFrame();

    // Render audio
    const sample_count = sandopolis_audio_render(&emu);

    // SMS audio buffer is interleaved stereo (L, R, L, R, ...) so the
    // count must be even (matching the total i16 elements, not pairs).
    try std.testing.expect(sample_count > 0);
    try std.testing.expect(sample_count % 2 == 0);

    // Verify count matches the SMS machine's audio buffer length
    const buf = emu.machine.smsAudioBuffer().?;
    try std.testing.expectEqual(buf.len, sample_count);
}
