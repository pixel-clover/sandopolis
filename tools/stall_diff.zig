const std = @import("std");
const platform = @import("sandopolis_testing").platform;
const testing = @import("sandopolis_testing");

const c = @cImport({
    @cInclude("libretro.h");
});

// 68K stall-accounting differential: lockstep-run Sandopolis and an
// instrumented Genesis Plus GX build (sando_probe_counters in vdp_ctrl.c)
// on the same ROM and compare, per frame, how many master cycles each
// emulator charged the 68K per stall mechanism:
//
//   fifo_w  - data port write stall (FIFO full)
//   dma     - 68K halt during 68k-bus DMA
//   refresh - DRAM refresh delay
//   cont    - 68K wait-states while the Z80 accesses the 68K bus
//
// The purpose is CPU-throughput calibration: if Sandopolis's 68K finishes
// work-bounded scenes earlier than GPGX (Titan Overdrive loader scenes),
// the mechanism whose cumulative total falls short is the lever to fix.
//
// The reference core must be built with the stall probes applied:
//   git -C external/Genesis-Plus-GX apply ../../tools/genesis-plus-gx-stall-probes.patch
//   make -C external/Genesis-Plus-GX -f Makefile.libretro
// (The probes only add counters; oracle behavior is unchanged, so the
// instrumented .so is also fine for trace-diff / vram-diff.)
//
// Usage: stall-diff <rom> [frames] [--pal] [--csv path] [--window N]

const default_core_path = "external/Genesis-Plus-GX/genesis_plus_gx_libretro.so";

const Args = struct {
    rom_path: []const u8,
    frames: usize = 3000,
    pal: bool = false,
    csv_path: ?[]const u8 = null,
    window: usize = 100,
};

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

// The probe counters are file-local BSS in the .so (the libretro version
// script hides everything but retro_*), so resolve their address via the
// symbol's link-time offset (nm) plus the runtime load base (/proc/self/maps),
// same technique as vram-diff.
fn soLoadBase(allocator: std.mem.Allocator, so_realpath: []const u8) !usize {
    // procfs files stat as 0 bytes, so size-based readFileAlloc returns
    // nothing; read in a plain loop instead.
    var file = try platform.cwd().openFile("/proc/self/maps", .{});
    defer file.close();
    var maps_list: std.ArrayList(u8) = .empty;
    defer maps_list.deinit(allocator);
    var chunk: [64 * 1024]u8 = undefined;
    while (true) {
        const n = file.read(&chunk) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (n == 0) break;
        try maps_list.appendSlice(allocator, chunk[0..n]);
    }
    const maps = maps_list.items;
    var min: ?usize = null;
    var it = std.mem.splitScalar(u8, maps, '\n');
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, so_realpath) == null) continue;
        const dash = std.mem.indexOfScalar(u8, line, '-') orelse continue;
        const start = std.fmt.parseInt(usize, line[0..dash], 16) catch continue;
        if (min == null or start < min.?) min = start;
    }
    return min orelse error.SoNotMapped;
}

fn symOffset(allocator: std.mem.Allocator, so_path: []const u8, name: []const u8) !usize {
    const res = try std.process.run(allocator, platform.io(), .{
        .argv = &.{ "nm", "--defined-only", so_path },
        .stdout_limit = .limited(128 * 1024 * 1024),
    });
    defer allocator.free(res.stdout);
    defer allocator.free(res.stderr);
    var it = std.mem.splitScalar(u8, res.stdout, '\n');
    while (it.next()) |line| {
        var tok = std.mem.tokenizeAny(u8, line, " \t");
        const addr = tok.next() orelse continue;
        _ = tok.next() orelse continue; // symbol type
        const sym_name = tok.next() orelse continue;
        if (std.mem.eql(u8, sym_name, name)) return std.fmt.parseInt(usize, addr, 16) catch continue;
    }
    return error.SymbolNotFound;
}

fn diffCount(sando: []const u8, ref: []const u8, swapped: bool) usize {
    var n: usize = 0;
    for (sando, 0..) |b, i| {
        const rb = if (swapped) ref[i ^ 1] else ref[i];
        if (b != rb) n += 1;
    }
    return n;
}

const Totals = struct {
    fifo_w: u64 = 0,
    dma: u64 = 0,
    refresh: u64 = 0,
    cont: u64 = 0,

    fn add(self: *Totals, other: Totals) void {
        self.fifo_w += other.fifo_w;
        self.dma += other.dma;
        self.refresh += other.refresh;
        self.cont += other.cont;
    }
};

pub fn main(init: std.process.Init) !void {
    platform.init(init);
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var arg_it = try platform.argsWithAllocator(allocator);
    defer arg_it.deinit();
    const args = try parseArgs(&arg_it);

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
    const ref_ram = ref_ram_ptr[0..ref_ram_len];

    // Resolve the probe counter array in the instrumented core.
    const so_real = try platform.cwd().realpathAlloc(allocator, default_core_path);
    defer allocator.free(so_real);
    const base = try soLoadBase(allocator, so_real);
    const probe_off = symOffset(allocator, so_real, "sando_probe_counters") catch {
        std.debug.print(
            "error: sando_probe_counters not found in {s}.\n" ++
                "Rebuild the instrumented core: make -C external/Genesis-Plus-GX -f Makefile.libretro\n",
            .{default_core_path},
        );
        return error.SymbolNotFound;
    };
    const ref_probes: *const [4]u64 = @ptrFromInt(base + probe_off);

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

    var out_buf: [4096]u8 = undefined;
    var w = platform.stdout().writer(&out_buf);
    const stdout = &w.interface;
    try stdout.print("stall-diff rom={s} region={s} frames={d} window={d}\n", .{
        std.fs.path.basename(args.rom_path),
        if (args.pal) "PAL" else "NTSC",
        args.frames,
        args.window,
    });
    try stdout.flush();

    var csv_file: ?platform.File = null;
    defer if (csv_file) |*f| f.close();
    if (args.csv_path) |path| {
        csv_file = try platform.cwd().createFile(path, .{ .truncate = true });
        try csv_file.?.writeAll(
            "frame,ours_fifo_w,ours_dma,ours_refresh,ours_cont,ours_access,ours_read,ours_ctrl,ours_exec_m68k,gpgx_fifo_w,gpgx_dma,gpgx_refresh,gpgx_cont,ram_diff,scene_ours,scene_gpgx\n",
        );
    }

    var prev_probes: [4]u64 = ref_probes.*;
    var ours_total = Totals{};
    var gpgx_total = Totals{};
    var ours_window = Totals{};
    var gpgx_window = Totals{};
    var swapped = false;
    var alignment_locked = false;

    var frame: usize = 0;
    while (frame < args.frames) : (frame += 1) {
        api.run();
        const counters = emu.runFrameProfiled();
        try emu.discardPendingAudioWithOutput(&output);

        if (!alignment_locked and frame >= 8) {
            const direct = diffCount(sando_ram[0..compare_len], ref_ram, false);
            const swap = diffCount(sando_ram[0..compare_len], ref_ram, true);
            swapped = swap < direct;
            alignment_locked = true;
        }

        var gpgx_frame = Totals{};
        gpgx_frame.fifo_w = ref_probes[0] - prev_probes[0];
        gpgx_frame.dma = ref_probes[1] - prev_probes[1];
        gpgx_frame.refresh = ref_probes[2] - prev_probes[2];
        gpgx_frame.cont = ref_probes[3] - prev_probes[3];
        prev_probes = ref_probes.*;

        const ours_frame = Totals{
            .fifo_w = counters.m68k_dataport_write_wait_master,
            .dma = counters.m68k_dma_halt_master,
            .refresh = counters.m68k_refresh_wait_master,
            .cont = counters.m68k_contention_wait_master,
        };

        ours_total.add(ours_frame);
        gpgx_total.add(gpgx_frame);
        ours_window.add(ours_frame);
        gpgx_window.add(gpgx_frame);

        if (csv_file) |*cf| {
            const ram_diff = if (alignment_locked) diffCount(sando_ram[0..compare_len], ref_ram, swapped) else 0;
            const scene_ours = sando_ram[0x271];
            const scene_gpgx = ref_ram[if (swapped) 0x271 ^ 1 else 0x271];
            var line_buf: [512]u8 = undefined;
            const line = try std.fmt.bufPrint(&line_buf, "{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d}\n", .{
                frame,
                ours_frame.fifo_w,
                ours_frame.dma,
                ours_frame.refresh,
                ours_frame.cont,
                counters.m68k_access_wait_master,
                counters.m68k_dataport_read_wait_master,
                counters.m68k_ctrlport_write_wait_master,
                counters.m68k_executed_cycles,
                gpgx_frame.fifo_w,
                gpgx_frame.dma,
                gpgx_frame.refresh,
                gpgx_frame.cont,
                ram_diff,
                scene_ours,
                scene_gpgx,
            });
            try cf.writeAll(line);
        }

        if ((frame + 1) % args.window == 0) {
            try stdout.print(
                "  f{d:>5}: ours fifo_w={d:>8} dma={d:>8} rfsh={d:>7} cont={d:>7} | gpgx fifo_w={d:>8} dma={d:>8} rfsh={d:>7} cont={d:>7}\n",
                .{
                    frame + 1,
                    ours_window.fifo_w,
                    ours_window.dma,
                    ours_window.refresh,
                    ours_window.cont,
                    gpgx_window.fifo_w,
                    gpgx_window.dma,
                    gpgx_window.refresh,
                    gpgx_window.cont,
                },
            );
            try stdout.flush();
            ours_window = .{};
            gpgx_window = .{};
        }
    }

    const ours_sum = ours_total.fifo_w + ours_total.dma + ours_total.refresh + ours_total.cont;
    const gpgx_sum = gpgx_total.fifo_w + gpgx_total.dma + gpgx_total.refresh + gpgx_total.cont;
    try stdout.print(
        "\ntotals over {d} frames (master cycles):\n" ++
            "  fifo_w : ours={d:>12} gpgx={d:>12} delta={d}\n" ++
            "  dma    : ours={d:>12} gpgx={d:>12} delta={d}\n" ++
            "  refresh: ours={d:>12} gpgx={d:>12} delta={d}\n" ++
            "  cont   : ours={d:>12} gpgx={d:>12} delta={d}\n" ++
            "  sum    : ours={d:>12} gpgx={d:>12} delta={d}\n",
        .{
            args.frames,
            ours_total.fifo_w,      gpgx_total.fifo_w,      @as(i64, @intCast(ours_total.fifo_w)) - @as(i64, @intCast(gpgx_total.fifo_w)),
            ours_total.dma,         gpgx_total.dma,         @as(i64, @intCast(ours_total.dma)) - @as(i64, @intCast(gpgx_total.dma)),
            ours_total.refresh,     gpgx_total.refresh,     @as(i64, @intCast(ours_total.refresh)) - @as(i64, @intCast(gpgx_total.refresh)),
            ours_total.cont,        gpgx_total.cont,        @as(i64, @intCast(ours_total.cont)) - @as(i64, @intCast(gpgx_total.cont)),
            ours_sum,               gpgx_sum,               @as(i64, @intCast(ours_sum)) - @as(i64, @intCast(gpgx_sum)),
        },
    );
    try stdout.flush();
}

fn parseArgs(it: *std.process.Args.Iterator) !Args {
    _ = it.next();
    const rom = it.next() orelse {
        std.debug.print("Usage: stall-diff <rom> [frames] [--pal] [--csv path] [--window N]\n", .{});
        return error.InvalidArgs;
    };
    var a = Args{ .rom_path = rom };
    var positional: usize = 0;
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--pal")) {
            a.pal = true;
        } else if (std.mem.eql(u8, arg, "--csv")) {
            a.csv_path = it.next() orelse return error.InvalidArgs;
        } else if (std.mem.eql(u8, arg, "--window")) {
            a.window = try std.fmt.parseInt(usize, it.next() orelse return error.InvalidArgs, 10);
        } else if (positional == 0) {
            a.frames = try std.fmt.parseInt(usize, arg, 10);
            positional += 1;
        } else {
            return error.InvalidArgs;
        }
    }
    return a;
}
