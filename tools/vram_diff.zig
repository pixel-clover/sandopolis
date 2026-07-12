const std = @import("std");
const testing = @import("sandopolis_testing");

const c = @cImport({
    @cInclude("libretro.h");
});

// VRAM differential: run BOTH Sandopolis and the Genesis Plus GX reference core
// to the same frame, then compare their 64KB VRAM byte-for-byte.  trace-diff
// only compares 68K work RAM (0xFF0000), so a picture that differs while RAM
// matches (e.g. the OD1 PAL "TITAN" gradient shear) points at VDP memory that
// trace-diff can't see. This closes that blind spot.
//
// Output: total differing bytes (for the better of the two byte alignments)
// plus a per-4KB-region histogram, so tile data (low VRAM) vs nametables
// (high VRAM) divergence is immediately visible.
//
// Usage: vram-diff <rom> <frame> [--pal]

const default_core_path = "external/Genesis-Plus-GX/genesis_plus_gx_libretro.so";

const Args = struct {
    rom_path: []const u8,
    frame: usize = 2000,
    pal: bool = false,
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

// Genesis Plus GX keeps vram/cram/vsram as file-local BSS globals, so they are
// NOT in the .so's dynamic symbol table (dlsym can't see them) and libretro
// exposes no VRAM memory id.  Resolve the address directly: the symbol's
// link-time offset (from `nm`) plus the .so's runtime load base (from
// /proc/self/maps).  Robust to rebuilds because both are read live.
fn soLoadBase(allocator: std.mem.Allocator, so_realpath: []const u8) !usize {
    const maps = try std.fs.cwd().readFileAlloc(allocator, "/proc/self/maps", 8 * 1024 * 1024);
    defer allocator.free(maps);
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
    const res = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "nm", "--defined-only", so_path },
        .max_output_bytes = 128 * 1024 * 1024,
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

fn refMemory(allocator: std.mem.Allocator, base: usize, so_path: []const u8, name: []const u8, len: usize) ![]const u8 {
    const off = try symOffset(allocator, so_path, name);
    const ptr: [*]const u8 = @ptrFromInt(base + off);
    return ptr[0..len];
}

fn diffSmall(stdout: anytype, allocator: std.mem.Allocator, base: usize, so_path: []const u8, name: []const u8, sando: []const u8) !void {
    const ref = refMemory(allocator, base, so_path, name, sando.len) catch |err| {
        try stdout.print("{s}: (unavailable: {s})\n", .{ name, @errorName(err) });
        return;
    };
    const direct = diffCount(sando, ref, false);
    const swap = diffCount(sando, ref, true);
    const swapped = swap < direct;
    const total = @min(direct, swap);
    try stdout.print("{s}: {d}/{d} bytes differ (align={s})\n", .{
        name, total, sando.len, if (swapped) "swapped" else "direct",
    });
    if (total != 0 and total <= 32) {
        var i: usize = 0;
        while (i < sando.len) : (i += 1) {
            const rb = if (swapped) ref[i ^ 1] else ref[i];
            if (sando[i] != rb) {
                try stdout.print("    [0x{X:0>2}] sando=0x{X:0>2} gpgx=0x{X:0>2}\n", .{ i, sando[i], rb });
            }
        }
    }
}

fn diffCount(sando: []const u8, ref: []const u8, swapped: bool) usize {
    var n: usize = 0;
    for (sando, 0..) |b, i| {
        const rb = if (swapped) ref[i ^ 1] else ref[i];
        if (b != rb) n += 1;
    }
    return n;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var arg_it = try std.process.argsWithAllocator(allocator);
    defer arg_it.deinit();
    const args = try parseArgs(&arg_it);

    var api = try ReferenceApi.open(default_core_path);
    defer api.lib.close();

    const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
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

    const so_real = try std.fs.cwd().realpathAlloc(allocator, default_core_path);
    defer allocator.free(so_real);
    const base = try soLoadBase(allocator, so_real);
    const ref_vram = try refMemory(allocator, base, so_real, "vram", 0x10000);
    const ref_vram_len: usize = 0x10000;

    var emu = try testing.Emulator.init(allocator, args.rom_path);
    defer emu.deinit(allocator);
    if (args.pal) {
        emu.setPalMode(true);
        emu.reset();
    }
    var output = testing.AudioOutput.init();

    // Run both cores to the target frame (inclusive).
    var f: usize = 0;
    while (f <= args.frame) : (f += 1) {
        api.run();
        emu.runFrame();
        try emu.discardPendingAudioWithOutput(&output);
    }

    const vram_len: usize = @min(ref_vram_len, 0x10000);

    // Snapshot Sandopolis VRAM.
    const sando_vram = try allocator.alloc(u8, vram_len);
    defer allocator.free(sando_vram);
    for (0..vram_len) |i| sando_vram[i] = emu.vramReadByte(@intCast(i));

    // gpgx may store VRAM byte-swapped on little-endian hosts; pick the better
    // alignment (same trick trace-diff uses for work RAM).
    const direct = diffCount(sando_vram, ref_vram[0..vram_len], false);
    const swap = diffCount(sando_vram, ref_vram[0..vram_len], true);
    const swapped = swap < direct;
    const total = @min(direct, swap);

    var out_buf: [8192]u8 = undefined;
    var w = std.fs.File.stdout().writer(&out_buf);
    const stdout = &w.interface;

    try stdout.print("vram-diff rom={s} region={s} frame={d} vram={d}B align={s}\n", .{
        std.fs.path.basename(args.rom_path),
        if (args.pal) "PAL" else "NTSC",
        args.frame,
        vram_len,
        if (swapped) "swapped(addr^1)" else "direct",
    });
    const pct = @as(f64, @floatFromInt(total)) * 100.0 / @as(f64, @floatFromInt(vram_len));
    try stdout.print("TOTAL diverging: {d} / {d} bytes ({d:.2}%)\n", .{ total, vram_len, pct });

    // Per-4KB-region histogram.
    const region = 0x1000;
    try stdout.print("per-4KB region (diff bytes, first differing addr):\n", .{});
    var rbase: usize = 0;
    while (rbase < vram_len) : (rbase += region) {
        var rn: usize = 0;
        var first: ?usize = null;
        var i = rbase;
        while (i < rbase + region and i < vram_len) : (i += 1) {
            const rb = if (swapped) ref_vram[i ^ 1] else ref_vram[i];
            if (sando_vram[i] != rb) {
                rn += 1;
                if (first == null) first = i;
            }
        }
        if (rn != 0) {
            try stdout.print("  0x{X:0>4}-0x{X:0>4}: {d:>5} bytes, first@0x{X:0>4}\n", .{ rbase, rbase + region - 1, rn, first.? });
        }
    }

    // CRAM (palette, 64x9-bit) and VSRAM (40x11-bit vscroll).  End-of-frame
    // snapshot: if these match while the picture differs, the shear is in
    // per-line render state, not memory content.
    // CRAM must be compared on decoded 9-bit color, NOT raw bytes: Sandopolis
    // stores the raw 0x0EEE bus word (big-endian); gpgx stores it packed to
    // 9-bit BBBGGGRRR (little-endian).  Different encodings, same color.
    const cram_ref = try refMemory(allocator, base, so_real, "cram", 0x80);
    var cram_diff: usize = 0;
    try stdout.print("cram (64 entries, decoded 9-bit BGR):\n", .{});
    for (0..64) |e| {
        const sw: u16 = (@as(u16, emu.cramReadByte(@intCast(e * 2))) << 8) | emu.cramReadByte(@intCast(e * 2 + 1));
        const s9 = ((sw & 0xE00) >> 3) | ((sw & 0x0E0) >> 2) | ((sw & 0x00E) >> 1);
        const g9: u16 = @as(u16, cram_ref[e * 2]) | (@as(u16, cram_ref[e * 2 + 1]) << 8);
        if (s9 != g9) {
            cram_diff += 1;
            if (cram_diff <= 40)
                try stdout.print("    [{d:>2}] sando=0x{X:0>3} gpgx=0x{X:0>3}\n", .{ e, s9, g9 });
        }
    }
    try stdout.print("  -> {d}/64 color entries differ\n", .{cram_diff});

    var vsram_buf: [0x50]u8 = undefined;
    for (0..vsram_buf.len) |i| vsram_buf[i] = emu.vsramReadByte(@intCast(i));
    try diffSmall(stdout, allocator, base, so_real, "vsram", &vsram_buf);

    try stdout.flush();
}

fn parseArgs(it: *std.process.ArgIterator) !Args {
    _ = it.next();
    const rom = it.next() orelse {
        std.debug.print("Usage: vram-diff <rom> <frame> [--pal]\n", .{});
        return error.InvalidArgs;
    };
    var a = Args{ .rom_path = rom };
    var positional: usize = 0;
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--pal")) {
            a.pal = true;
        } else {
            switch (positional) {
                0 => a.frame = try std.fmt.parseInt(usize, arg, 10),
                else => return error.InvalidArgs,
            }
            positional += 1;
        }
    }
    return a;
}
