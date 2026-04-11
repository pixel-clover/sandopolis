const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const Machine = @import("machine.zig").Machine;
const Vdp = @import("video/vdp.zig").Vdp;
const Io = @import("input/io.zig").Io;
const AudioOutput = @import("audio/output.zig").AudioOutput;
const state_file = @import("state_file.zig");
const system_detect = @import("system.zig");
const rom_loader = @import("rom_loader.zig");
const sms_state_file = @import("sms/state_file.zig");
const SmsMachine = @import("sms/machine.zig").SmsMachine;
const SmsInput = @import("sms/input.zig").SmsInput;

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
    system: SystemInstance,
    audio_buffer: [8192]i16,
    audio_sample_count: usize,
    last_save_buf: ?[]u8,
    last_save_len: usize,
    frame_count: u64 = 0,

    const SystemInstance = union(enum) {
        genesis: GenesisInstance,
        sms: SmsInstance,
    };

    const GenesisInstance = struct {
        machine: Machine,
        audio: AudioOutput,
        snapshot: ?Machine.Snapshot,
    };

    const SmsInstance = struct {
        machine: SmsMachine,
        snapshot: ?SmsMachine.Snapshot = null,

        pub fn deinit(self: *SmsInstance, alloc: std.mem.Allocator) void {
            if (self.snapshot) |*snap| snap.deinit(alloc);
            self.machine.deinit(alloc);
        }
    };
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
    // Extract ROM from ZIP if needed.
    const rom_bytes = try rom_loader.extractRomBytes(alloc, raw_bytes);
    defer alloc.free(rom_bytes);

    // Use the system hint from JS if provided (e.g. from file extension);
    // fall back to content-based detection.
    const sys: system_detect.SystemType = switch (system_hint) {
        1 => .sms,
        2 => .gg,
        3 => .sg1000,
        else => system_detect.detectSystem(rom_bytes),
    };
    switch (sys) {
        .genesis => {
            var machine = try Machine.initFromRomBytes(alloc, rom_bytes);
            machine.reset();
            return .{
                .system = .{ .genesis = .{
                    .machine = machine,
                    .audio = AudioOutput.init(),
                    .snapshot = null,
                } },
                .audio_buffer = [_]i16{0} ** 8192,
                .audio_sample_count = 0,
                .last_save_buf = null,
                .last_save_len = 0,
            };
        },
        .sms, .gg, .sg1000 => {
            var sms = try SmsMachine.initFromRomBytes(alloc, rom_bytes);
            sms.is_game_gear = (sys == .gg);
            sms.is_sg1000 = (sys == .sg1000);
            return .{
                .system = .{ .sms = .{ .machine = sms } },
                .audio_buffer = [_]i16{0} ** 8192,
                .audio_sample_count = 0,
                .last_save_buf = null,
                .last_save_len = 0,
            };
        },
    }
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
    switch (emu.system) {
        .genesis => |*g| {
            if (g.snapshot) |*snap| snap.deinit(allocator);
            g.machine.deinit(allocator);
        },
        .sms => |*s| s.deinit(allocator),
    }
    allocator.destroy(emu);
}

// Frame execution

export fn sandopolis_run_frame(emu: *WasmEmulator) void {
    switch (emu.system) {
        .genesis => |*g| g.machine.runFrame(),
        .sms => |*s| s.machine.runFrame(),
    }
    emu.frame_count += 1;
}

// Video

export fn sandopolis_framebuffer_ptr(emu: *const WasmEmulator) [*]const u32 {
    return switch (emu.system) {
        .genesis => |*g| g.machine.framebuffer().ptr,
        .sms => |*s| s.machine.framebuffer().ptr,
    };
}

export fn sandopolis_framebuffer_len(emu: *const WasmEmulator) usize {
    return switch (emu.system) {
        .genesis => |*g| g.machine.framebuffer().len,
        .sms => |*s| s.machine.framebuffer().len,
    };
}

export fn sandopolis_screen_width(emu: *const WasmEmulator) u32 {
    return switch (emu.system) {
        .genesis => |*g| g.machine.framebufferWidth(),
        .sms => |*s| s.machine.framebufferWidth(),
    };
}

export fn sandopolis_screen_height(emu: *const WasmEmulator) u32 {
    return switch (emu.system) {
        .genesis => |*g| g.machine.screenHeight(),
        .sms => |*s| s.machine.screenHeight(),
    };
}

// Input

export fn sandopolis_set_button(emu: *WasmEmulator, port: u32, button: u16, pressed: bool) void {
    switch (emu.system) {
        .genesis => |*g| g.machine.setButton(@intCast(port), button, pressed),
        .sms => |*s| {
            const m = &s.machine;
            const sms_port: u1 = @intCast(@min(port, 1));
            const sms_btn: ?SmsInput.Button = switch (button) {
                Io.Button.Up => .up,
                Io.Button.Down => .down,
                Io.Button.Left => .left,
                Io.Button.Right => .right,
                Io.Button.A, Io.Button.B => .button1,
                Io.Button.C => .button2,
                Io.Button.Start => blk: {
                    if (m.is_game_gear) {
                        m.bus.input.start_pressed = pressed;
                    } else if (pressed) {
                        m.bus.input.pause_pressed = true;
                    }
                    break :blk null;
                },
                else => null,
            };
            if (sms_btn) |btn| m.setButton(sms_port, btn, pressed);
        },
    }
}

// Machine control

export fn sandopolis_reset(emu: *WasmEmulator) void {
    switch (emu.system) {
        .genesis => |*g| g.machine.softReset(),
        .sms => |*s| s.machine.softReset(),
    }
}

export fn sandopolis_is_pal(emu: *const WasmEmulator) bool {
    return switch (emu.system) {
        .genesis => |*g| g.machine.palMode(),
        .sms => |*s| s.machine.isPal(),
    };
}

// Audio

export fn sandopolis_audio_render(emu: *WasmEmulator) usize {
    switch (emu.system) {
        .genesis => |*g| {
            emu.audio_sample_count = 0;
            const pending = g.machine.takePendingAudio();
            var sink = WasmAudioSink{
                .buffer = &emu.audio_buffer,
                .count = &emu.audio_sample_count,
            };
            g.audio.renderPending(pending, &g.machine.bus.z80, g.machine.palMode(), &sink) catch {};
        },
        .sms => |*s| {
            // SMS audio is rendered during runFrame; copy from SMS audio buffer.
            // audioBuffer() returns interleaved stereo i16 (L, R, L, R, ...).
            // audio_sample_count must match Genesis convention: total i16 count
            // (not stereo pairs), since JS reads this many elements from the buffer.
            const src = s.machine.audioBuffer();
            const n = @min(src.len, emu.audio_buffer.len);
            @memcpy(emu.audio_buffer[0..n], src[0..n]);
            emu.audio_sample_count = n;
        },
    }
    return emu.audio_sample_count;
}

export fn sandopolis_audio_buffer_ptr(emu: *const WasmEmulator) [*]const i16 {
    return &emu.audio_buffer;
}

export fn sandopolis_set_audio_mode(emu: *WasmEmulator, mode: u8) void {
    switch (emu.system) {
        .genesis => |*g| g.audio.setRenderMode(switch (mode) {
            1 => .ym_only,
            2 => .psg_only,
            3 => .unfiltered_mix,
            else => .normal,
        }),
        .sms => {},
    }
}

export fn sandopolis_get_audio_mode(emu: *const WasmEmulator) u8 {
    return switch (emu.system) {
        .genesis => |*g| switch (g.audio.render_mode) {
            .normal => 0,
            .ym_only => 1,
            .psg_only => 2,
            .unfiltered_mix => 3,
        },
        .sms => 0,
    };
}

export fn sandopolis_set_psg_volume(emu: *WasmEmulator, percent: u8) void {
    switch (emu.system) {
        .genesis => |*g| g.audio.setPsgVolume(percent),
        .sms => {},
    }
}

export fn sandopolis_get_psg_volume(emu: *const WasmEmulator) u8 {
    return switch (emu.system) {
        .genesis => |*g| g.audio.psg_volume_percent,
        .sms => 100,
    };
}

export fn sandopolis_set_eq_enabled(emu: *WasmEmulator, enabled: u8) void {
    switch (emu.system) {
        .genesis => |*g| g.audio.setEqEnabled(enabled != 0),
        .sms => {},
    }
}

export fn sandopolis_get_eq_enabled(emu: *const WasmEmulator) u8 {
    return switch (emu.system) {
        .genesis => |*g| if (g.audio.eq_enabled) @as(u8, 1) else 0,
        .sms => 0,
    };
}

export fn sandopolis_set_eq_gains(emu: *WasmEmulator, low: f64, mid: f64, high: f64) void {
    switch (emu.system) {
        .genesis => |*g| g.audio.setEqGains(low, mid, high),
        .sms => {},
    }
}

export fn sandopolis_get_eq_low(emu: *const WasmEmulator) f64 {
    return switch (emu.system) {
        .genesis => |*g| g.audio.eq_left.lg,
        .sms => 1.0,
    };
}

export fn sandopolis_get_eq_mid(emu: *const WasmEmulator) f64 {
    return switch (emu.system) {
        .genesis => |*g| g.audio.eq_left.mg,
        .sms => 1.0,
    };
}

export fn sandopolis_get_eq_high(emu: *const WasmEmulator) f64 {
    return switch (emu.system) {
        .genesis => |*g| g.audio.eq_left.hg,
        .sms => 1.0,
    };
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
    return @intCast(Vdp.framebuffer_width);
}

export fn sandopolis_save_state_version() u32 {
    return state_file.save_state_version;
}

// Statistics

export fn sandopolis_frame_count(emu: *const WasmEmulator) u32 {
    return @intCast(@min(emu.frame_count, std.math.maxInt(u32)));
}

export fn sandopolis_rom_size(emu: *const WasmEmulator) u32 {
    return switch (emu.system) {
        .genesis => |*g| @intCast(g.machine.romSize()),
        .sms => |*s| @intCast(s.machine.romSize()),
    };
}

export fn sandopolis_rom_title_ptr(emu: *const WasmEmulator) ?[*]const u8 {
    return switch (emu.system) {
        .genesis => |*g| blk: {
            const meta = g.machine.romMetadata();
            break :blk if (meta.title) |t| t.ptr else null;
        },
        .sms => null, // SMS ROMs don't have a title field
    };
}

export fn sandopolis_rom_title_len() u32 {
    return 0x30; // Fixed length in Genesis header (0x150..0x180)
}

export fn sandopolis_rom_checksum_valid(emu: *const WasmEmulator) bool {
    return switch (emu.system) {
        .genesis => |*g| g.machine.romMetadata().checksum_valid,
        .sms => true,
    };
}

export fn sandopolis_display_mode(emu: *const WasmEmulator) u32 {
    return switch (emu.system) {
        .genesis => |*g| g.machine.displayModeFlags(),
        .sms => 0, // SMS is always 256px, no interlace or shadow/highlight
    };
}

export fn sandopolis_system_type(emu: *const WasmEmulator) u32 {
    return switch (emu.system) {
        .genesis => 0,
        .sms => |*s| if (s.machine.is_game_gear) @as(u32, 2) else if (s.machine.is_sg1000) @as(u32, 3) else 1,
    };
}

// Settings

export fn sandopolis_set_controller_type(emu: *WasmEmulator, port: u32, ct: u8) void {
    switch (emu.system) {
        .genesis => |*g| {
            const controller_type: Io.ControllerType = switch (ct) {
                0 => .three_button,
                2 => .ea_4way_play,
                3 => .sega_mouse,
                else => .six_button,
            };
            g.machine.setControllerType(@intCast(port), controller_type);
        },
        .sms => {}, // SMS has fixed 2-button controllers
    }
}

export fn sandopolis_get_controller_type(emu: *const WasmEmulator, port: u32) u8 {
    return switch (emu.system) {
        .genesis => |*g| switch (g.machine.controllerType(@intCast(port))) {
            .three_button => 0,
            .six_button => 1,
            .ea_4way_play => 2,
            .sega_mouse => 3,
        },
        .sms => 0, // Report as simple controller
    };
}

// Quick save/load (in-memory snapshots)

export fn sandopolis_quick_save(emu: *WasmEmulator) bool {
    switch (emu.system) {
        .genesis => |*g| {
            if (g.snapshot) |*old| old.deinit(allocator);
            g.snapshot = g.machine.captureSnapshot(allocator) catch {
                g.snapshot = null;
                return false;
            };
            return true;
        },
        .sms => |*s| {
            if (s.snapshot) |*old| old.deinit(allocator);
            s.snapshot = s.machine.captureSnapshot(allocator) catch {
                s.snapshot = null;
                return false;
            };
            return true;
        },
    }
}

export fn sandopolis_quick_load(emu: *WasmEmulator) bool {
    switch (emu.system) {
        .genesis => |*g| {
            const snap = &(g.snapshot orelse return false);
            g.machine.restoreSnapshot(allocator, snap) catch return false;
            g.audio.reset();
            g.audio.syncYmStateFromZ80(&g.machine.bus.z80);
            return true;
        },
        .sms => |*s| {
            const snap = &(s.snapshot orelse return false);
            s.machine.restoreSnapshot(allocator, snap) catch return false;
            return true;
        },
    }
}

// Persistent save/load (serialized bytes for IndexedDB)

export fn sandopolis_save_state(emu: *WasmEmulator) ?[*]u8 {
    if (emu.last_save_buf) |buf| allocator.free(buf);
    emu.last_save_buf = null;
    emu.last_save_len = 0;

    switch (emu.system) {
        .genesis => |*g| {
            const buf = state_file.saveToBuffer(allocator, &g.machine) catch return null;
            emu.last_save_buf = buf;
            emu.last_save_len = buf.len;
            return buf.ptr;
        },
        .sms => |*s| {
            const buf = sms_state_file.saveToBuffer(allocator, &s.machine) catch return null;
            emu.last_save_buf = buf;
            emu.last_save_len = buf.len;
            return buf.ptr;
        },
    }
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
    switch (emu.system) {
        .genesis => |*g| {
            const new_machine = state_file.loadFromBuffer(allocator, ptr[0..len]) catch return false;
            g.machine.deinit(allocator);
            g.machine = new_machine;
            g.audio.reset();
            return true;
        },
        .sms => |*s| {
            var new_machine = sms_state_file.loadFromBuffer(allocator, ptr[0..len]) catch return false;
            new_machine.bindPointers();
            s.machine.deinit(allocator);
            s.machine = new_machine;
            return true;
        },
    }
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
    defer {
        switch (emu.system) {
            .genesis => |*g| g.machine.deinit(test_allocator),
            .sms => |*s| s.deinit(allocator),
        }
    }

    const g = &emu.system.genesis;
    try std.testing.expectEqual(@as(@TypeOf(g.machine.pending_frame_phase), .hard_reset), g.machine.pending_frame_phase);
    try std.testing.expectEqual(@as(u32, 0x0000_0200), g.machine.programCounter());

    const pc_before = g.machine.programCounter();
    g.machine.runFrame();
    try std.testing.expect(g.machine.programCounter() != pc_before);
}
