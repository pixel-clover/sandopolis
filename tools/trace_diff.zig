const std = @import("std");
const platform = @import("sandopolis_testing").platform;
const testing = @import("sandopolis_testing");

const c = @cImport({
    @cInclude("libretro.h");
});

// Differential testing harness: lockstep-run Sandopolis and Genesis Plus GX
// (dlopen'd libretro core, the same one the audio tools use as a reference)
// on the same ROM, and report the first frame where the 68K work RAM
// (0xFF0000-0xFFFFFF, where game state lives) diverges sharply.
//
// RAM is compared instead of the framebuffer because it is rendering- and
// color-convention-independent, so a divergence is a real state/logic/timing
// desync rather than a palette-rounding artifact.  Two accurate emulators
// drift a little on real games (frame counters, timing-seeded RNG), so the
// signal is the first SPIKE above the running baseline, not exact equality.
//
// Usage: trace-diff <rom> [frames] [--pal] [--skip N] [--every N] [--spike N]

const default_core_path = "external/Genesis-Plus-GX/genesis_plus_gx_libretro.so";

const Args = struct {
    rom_path: []const u8,
    frames: usize = 4000,
    pal: bool = false,
    skip: usize = 0,
    every: usize = 30,
    spike: usize = 2000,
    persist: usize = 10,
};

// ---- Genesis Plus GX libretro reference core ----

const ReferenceApi = struct {
    lib: std.DynLib,
    set_environment: *const fn (c.retro_environment_t) callconv(.c) void,
    set_video_refresh: *const fn (c.retro_video_refresh_t) callconv(.c) void,
    set_audio_sample: *const fn (c.retro_audio_sample_t) callconv(.c) void,
    set_audio_sample_batch: *const fn (c.retro_audio_sample_batch_t) callconv(.c) void,
    set_input_poll: *const fn (c.retro_input_poll_t) callconv(.c) void,
    set_input_state: *const fn (c.retro_input_state_t) callconv(.c) void,
    init: *const fn () callconv(.c) void,
    deinit: *const fn () callconv(.c) void,
    load_game: *const fn (?*const c.struct_retro_game_info) callconv(.c) bool,
    unload_game: *const fn () callconv(.c) void,
    run: *const fn () callconv(.c) void,
    get_memory_data: *const fn (c_uint) callconv(.c) ?[*]u8,
    get_memory_size: *const fn (c_uint) callconv(.c) usize,

    fn open(path: []const u8) !ReferenceApi {
        var lib = try std.DynLib.open(path);
        errdefer lib.close();
        return .{
            .lib = lib,
            .set_environment = try sym(&lib, *const fn (c.retro_environment_t) callconv(.c) void, "retro_set_environment"),
            .set_video_refresh = try sym(&lib, *const fn (c.retro_video_refresh_t) callconv(.c) void, "retro_set_video_refresh"),
            .set_audio_sample = try sym(&lib, *const fn (c.retro_audio_sample_t) callconv(.c) void, "retro_set_audio_sample"),
            .set_audio_sample_batch = try sym(&lib, *const fn (c.retro_audio_sample_batch_t) callconv(.c) void, "retro_set_audio_sample_batch"),
            .set_input_poll = try sym(&lib, *const fn (c.retro_input_poll_t) callconv(.c) void, "retro_set_input_poll"),
            .set_input_state = try sym(&lib, *const fn (c.retro_input_state_t) callconv(.c) void, "retro_set_input_state"),
            .init = try sym(&lib, *const fn () callconv(.c) void, "retro_init"),
            .deinit = try sym(&lib, *const fn () callconv(.c) void, "retro_deinit"),
            .load_game = try sym(&lib, *const fn (?*const c.struct_retro_game_info) callconv(.c) bool, "retro_load_game"),
            .unload_game = try sym(&lib, *const fn () callconv(.c) void, "retro_unload_game"),
            .run = try sym(&lib, *const fn () callconv(.c) void, "retro_run"),
            .get_memory_data = try sym(&lib, *const fn (c_uint) callconv(.c) ?[*]u8, "retro_get_memory_data"),
            .get_memory_size = try sym(&lib, *const fn (c_uint) callconv(.c) usize, "retro_get_memory_size"),
        };
    }
};

fn sym(lib: *std.DynLib, comptime T: type, name: [:0]const u8) !T {
    return lib.lookup(T, name) orelse error.MissingSymbol;
}

const Frontend = struct {
    system_dir_z: [:0]const u8,
    pal: bool,
};
var active: ?*Frontend = null;

fn coreVar(front: *const Frontend, key: []const u8) ?[*:0]const u8 {
    // Force region so both cores take the same code paths.  Everything else is
    // left default; RAM contents don't depend on GPGX's render/filter options.
    if (std.mem.eql(u8, key, "genesis_plus_gx_region_detect"))
        return if (front.pal) "pal" else "ntsc-u";
    return null;
}

fn envCb(cmd: c_uint, data: ?*anyopaque) callconv(.c) bool {
    const front = active orelse return false;
    switch (cmd) {
        c.RETRO_ENVIRONMENT_SET_PIXEL_FORMAT,
        c.RETRO_ENVIRONMENT_SET_INPUT_DESCRIPTORS,
        c.RETRO_ENVIRONMENT_SET_CONTROLLER_INFO,
        c.RETRO_ENVIRONMENT_SET_PERFORMANCE_LEVEL,
        c.RETRO_ENVIRONMENT_SET_CORE_OPTIONS_DISPLAY,
        => return true,
        c.RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY, c.RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY => {
            const out: *?[*:0]const u8 = @ptrCast(@alignCast(data.?));
            out.* = front.system_dir_z.ptr;
            return true;
        },
        c.RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE => {
            const updated: *bool = @ptrCast(@alignCast(data.?));
            updated.* = false;
            return true;
        },
        c.RETRO_ENVIRONMENT_GET_VARIABLE => {
            const v: *c.struct_retro_variable = @ptrCast(@alignCast(data.?));
            if (v.key == null) return false;
            v.value = coreVar(front, std.mem.span(v.key));
            return v.value != null;
        },
        else => return false,
    }
}

fn videoCb(_: ?*const anyopaque, _: c_uint, _: c_uint, _: usize) callconv(.c) void {}
fn audioSampleCb(_: i16, _: i16) callconv(.c) void {}
fn audioBatchCb(_: [*c]const i16, frames: usize) callconv(.c) usize {
    return frames;
}
fn inputPollCb() callconv(.c) void {}
fn inputStateCb(_: c_uint, _: c_uint, _: c_uint, _: c_uint) callconv(.c) i16 {
    return 0;
}

// ---- RAM divergence ----

/// Count 68K-work-RAM byte differences.  GPGX stores work RAM word-swapped on
/// little-endian hosts (READ_BYTE(base, addr^1)); `swapped` selects that
/// alignment.  Returns the differing byte count for the given alignment.
fn diffCount(sando: []const u8, ref: []const u8, swapped: bool) usize {
    var n: usize = 0;
    for (sando, 0..) |b, i| {
        const rb = if (swapped) ref[i ^ 1] else ref[i];
        if (b != rb) n += 1;
    }
    return n;
}

pub fn main(init: std.process.Init) !void {
    platform.init(init);
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var arg_it = try platform.argsWithAllocator(allocator);
    defer arg_it.deinit();
    const args = try parseArgs(&arg_it);

    // --- Genesis Plus GX ---
    var api = ReferenceApi.open(default_core_path) catch |err| {
        std.debug.print(
            "error: cannot open Genesis Plus GX reference core at {s} ({s}).\n" ++
                "Build it once:\n" ++
                "  git submodule update --init external/Genesis-Plus-GX\n" ++
                "  make -C external/Genesis-Plus-GX -f Makefile.libretro\n",
            .{ default_core_path, @errorName(err) },
        );
        return err;
    };
    defer api.lib.close();

    const cwd = try platform.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd);
    const cwd_z = try allocator.dupeZ(u8, cwd);
    defer allocator.free(cwd_z);
    var front = Frontend{ .system_dir_z = cwd_z, .pal = args.pal };
    active = &front;
    defer active = null;

    api.set_environment(envCb);
    api.set_video_refresh(videoCb);
    api.set_audio_sample(audioSampleCb);
    api.set_audio_sample_batch(audioBatchCb);
    api.set_input_poll(inputPollCb);
    api.set_input_state(inputStateCb);
    api.init();
    defer api.deinit();

    const rom_z = try allocator.dupeZ(u8, args.rom_path);
    defer allocator.free(rom_z);
    var game = c.struct_retro_game_info{ .path = rom_z.ptr, .data = null, .size = 0, .meta = null };
    if (!api.load_game(&game)) return error.RetroLoadGameFailed;
    defer api.unload_game();

    const ref_ram_ptr = api.get_memory_data(c.RETRO_MEMORY_SYSTEM_RAM) orelse return error.NoReferenceRam;
    const ref_ram_len = api.get_memory_size(c.RETRO_MEMORY_SYSTEM_RAM);

    // --- Sandopolis ---
    var emu = try testing.Emulator.init(allocator, args.rom_path);
    defer emu.deinit(allocator);
    if (args.pal) {
        emu.setPalMode(true);
        emu.reset();
    }
    var output = testing.AudioOutput.init();

    const sando_ram = emu.workRamSlice();
    const compare_len = @min(sando_ram.len, ref_ram_len);
    const ref_ram = ref_ram_ptr[0..ref_ram_len];

    var out_buf: [4096]u8 = undefined;
    var w = platform.stdout().writer(&out_buf);
    const stdout = &w.interface;
    try stdout.print("trace-diff rom={s} region={s} frames={d} ram={d}B skip={d}\n", .{
        std.fs.path.basename(args.rom_path),
        if (args.pal) "PAL" else "NTSC",
        args.frames,
        compare_len,
        args.skip,
    });

    for (0..args.skip) |_| {
        api.run();
        emu.runFrame();
        try emu.discardPendingAudioWithOutput(&output);
    }

    // Detect GPGX byte-order alignment once, after a few frames of warmup.
    var swapped = false;
    var alignment_locked = false;
    // Track contiguous "divergence episodes" (runs above the spike threshold).
    // A recovered episode is a transient timing nit; an episode still open at
    // the end is a permanent desync (the crash/lockup).
    var in_episode = false;
    var onset_frame: usize = 0;
    var onset_pc: u32 = 0;
    var peak_diverge: usize = 0;
    var episode_count: usize = 0;

    var frame: usize = 0;
    while (frame < args.frames) : (frame += 1) {
        api.run();
        emu.runFrame();
        try emu.discardPendingAudioWithOutput(&output);

        if (!alignment_locked and frame >= 8) {
            const direct = diffCount(sando_ram[0..compare_len], ref_ram, false);
            const swap = diffCount(sando_ram[0..compare_len], ref_ram, true);
            swapped = swap < direct;
            alignment_locked = true;
        }

        const diverge = if (alignment_locked) diffCount(sando_ram[0..compare_len], ref_ram, swapped) else 0;

        // TEMP diagnostic: watch beam-phase probe bytes the demo stores.
        if (alignment_locked and frame >= 300 and frame % 50 == 0) {
            const watch = [_]usize{ 0x4E01, 0x4E51, 0x0502, 0x0271 };
            try stdout.print("  WATCH f{d}:", .{frame});
            for (watch) |a| {
                const rb = if (swapped) ref_ram[a ^ 1] else ref_ram[a];
                try stdout.print(" {X:0>4}={X:0>2}/{X:0>2}", .{ a, sando_ram[a], rb });
            }
            try stdout.print("\n", .{});
        }

        const is_sample = (frame % args.every == 0) or (frame + 1 == args.frames);
        if (is_sample) {
            const pct = @as(f64, @floatFromInt(diverge)) * 100.0 / @as(f64, @floatFromInt(compare_len));
            try stdout.print("  frame {d:>5}: diverge={d:>6} bytes ({d:.2}%)\n", .{ frame, diverge, pct });
        }

        if (diverge > args.spike) {
            if (!in_episode) {
                in_episode = true;
                onset_frame = frame;
                onset_pc = emu.cpuPc();
                peak_diverge = diverge;
            }
            peak_diverge = @max(peak_diverge, diverge);
        } else if (in_episode) {
            // Episode closed (recovered) -- report it if long enough to matter.
            const dur = frame - onset_frame;
            if (dur >= args.persist) {
                episode_count += 1;
                try stdout.print("  ~ transient divergence: frames {d}-{d} ({d} frames, peak {d} bytes) recovered; onset pc=0x{X:0>8}\n", .{ onset_frame, frame - 1, dur, peak_diverge, onset_pc });
            }
            in_episode = false;
        }
    }

    if (in_episode) {
        episode_count += 1;
        const dur = args.frames - onset_frame;
        try stdout.print(">>> PERMANENT DESYNC: onset frame {d}, still diverging at end ({d} frames, peak {d} bytes); onset pc=0x{X:0>8}, final pc=0x{X:0>8} sr=0x{X:0>4}\n", .{ onset_frame, dur, peak_diverge, onset_pc, emu.cpuPc(), emu.cpuSr() });
    } else if (episode_count == 0) {
        try stdout.print("MATCH: no divergence > {d} bytes for {d}+ frames across {d} frames\n", .{ args.spike, args.persist, args.frames });
    }
    try stdout.print("byte-order: {s}\n", .{if (swapped) "gpgx word-swapped (addr^1)" else "direct"});
    try stdout.flush();
}

fn parseArgs(it: *std.process.Args.Iterator) !Args {
    _ = it.next();
    const rom = it.next() orelse {
        std.debug.print("Usage: trace-diff <rom> [frames] [--pal] [--skip N] [--every N] [--spike N]\n", .{});
        return error.InvalidArgs;
    };
    var a = Args{ .rom_path = rom };
    var positional: usize = 0;
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--pal")) {
            a.pal = true;
        } else if (std.mem.eql(u8, arg, "--skip")) {
            a.skip = try std.fmt.parseInt(usize, it.next() orelse return error.InvalidArgs, 10);
        } else if (std.mem.eql(u8, arg, "--every")) {
            a.every = try std.fmt.parseInt(usize, it.next() orelse return error.InvalidArgs, 10);
        } else if (std.mem.eql(u8, arg, "--spike")) {
            a.spike = try std.fmt.parseInt(usize, it.next() orelse return error.InvalidArgs, 10);
        } else if (std.mem.eql(u8, arg, "--persist")) {
            a.persist = try std.fmt.parseInt(usize, it.next() orelse return error.InvalidArgs, 10);
        } else {
            switch (positional) {
                0 => a.frames = try std.fmt.parseInt(usize, arg, 10),
                else => return error.InvalidArgs,
            }
            positional += 1;
        }
    }
    return a;
}
