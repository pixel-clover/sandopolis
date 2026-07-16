const std = @import("std");
const platform = @import("sandopolis_testing").platform;
const testing = @import("sandopolis_testing");

const c = @cImport({
    @cInclude("libretro.h");
});

// Capture a single framebuffer from BOTH Sandopolis and the Genesis Plus GX
// libretro reference core at the same frame, and write each as a PPM (P6) so
// the video output can be compared visually.  Region is forced identical on
// both cores (like trace-diff).
//
// Usage: dump-frames <rom> <frame> [--pal] [--out PREFIX]

const default_core_path = "external/Genesis-Plus-GX/genesis_plus_gx_libretro.so";

const Args = struct {
    rom_path: []const u8,
    frame: usize = 600,
    pal: bool = false,
    out_prefix: []const u8 = "frame",
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
        };
    }
};

fn sym(lib: *std.DynLib, comptime T: type, name: [:0]const u8) !T {
    return lib.lookup(T, name) orelse error.MissingSymbol;
}

// Captured reference video frame (RGB, one byte per channel).
const Captured = struct {
    rgb: std.ArrayListUnmanaged(u8) = .empty,
    width: usize = 0,
    height: usize = 0,
};

const Frontend = struct {
    system_dir_z: [:0]const u8,
    pal: bool,
    pixel_format: c_uint = c.RETRO_PIXEL_FORMAT_0RGB1555,
    allocator: std.mem.Allocator,
    cap: Captured = .{},
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
        c.RETRO_ENVIRONMENT_SET_PIXEL_FORMAT => {
            const fmt: *const c_uint = @ptrCast(@alignCast(data.?));
            front.pixel_format = fmt.*;
            return true;
        },
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

fn videoCb(data: ?*const anyopaque, width: c_uint, height: c_uint, pitch: usize) callconv(.c) void {
    const front = active orelse return;
    const ptr = data orelse return; // dupe frame (libretro can pass null to repeat)
    const w: usize = width;
    const h: usize = height;
    front.cap.rgb.clearRetainingCapacity();
    front.cap.rgb.ensureTotalCapacity(front.allocator, w * h * 3) catch return;
    front.cap.width = w;
    front.cap.height = h;
    const base: [*]const u8 = @ptrCast(ptr);
    var y: usize = 0;
    while (y < h) : (y += 1) {
        const row = base + y * pitch;
        var x: usize = 0;
        while (x < w) : (x += 1) {
            var r: u8 = undefined;
            var g: u8 = undefined;
            var b: u8 = undefined;
            switch (front.pixel_format) {
                c.RETRO_PIXEL_FORMAT_XRGB8888 => {
                    const px = std.mem.readInt(u32, @ptrCast(row + x * 4), .little);
                    r = @truncate(px >> 16);
                    g = @truncate(px >> 8);
                    b = @truncate(px);
                },
                c.RETRO_PIXEL_FORMAT_RGB565 => {
                    const px = std.mem.readInt(u16, @ptrCast(row + x * 2), .little);
                    r = @truncate((px >> 11) << 3);
                    g = @truncate(((px >> 5) & 0x3F) << 2);
                    b = @truncate((px & 0x1F) << 3);
                },
                else => { // 0RGB1555
                    const px = std.mem.readInt(u16, @ptrCast(row + x * 2), .little);
                    r = @truncate(((px >> 10) & 0x1F) << 3);
                    g = @truncate(((px >> 5) & 0x1F) << 3);
                    b = @truncate((px & 0x1F) << 3);
                },
            }
            front.cap.rgb.appendAssumeCapacity(r);
            front.cap.rgb.appendAssumeCapacity(g);
            front.cap.rgb.appendAssumeCapacity(b);
        }
    }
}

fn audioSampleCb(_: i16, _: i16) callconv(.c) void {}
fn audioBatchCb(_: [*c]const i16, frames: usize) callconv(.c) usize {
    return frames;
}
fn inputPollCb() callconv(.c) void {}
fn inputStateCb(_: c_uint, _: c_uint, _: c_uint, _: c_uint) callconv(.c) i16 {
    return 0;
}

fn writePpm(path: []const u8, rgb: []const u8, width: usize, height: usize) !void {
    var file = try platform.cwd().createFile(path, .{});
    defer file.close();
    var buf: [64]u8 = undefined;
    const header = try std.fmt.bufPrint(&buf, "P6\n{d} {d}\n255\n", .{ width, height });
    try file.writeAll(header);
    try file.writeAll(rgb);
}

pub fn main(init: std.process.Init) !void {
    platform.init(init);
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var arg_it = try platform.argsWithAllocator(allocator);
    defer arg_it.deinit();
    const args = try parseArgs(&arg_it);

    var api = try ReferenceApi.open(default_core_path);
    defer api.lib.close();

    const cwd = try platform.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd);
    const cwd_z = try allocator.dupeZ(u8, cwd);
    defer allocator.free(cwd_z);
    var front = Frontend{ .system_dir_z = cwd_z, .pal = args.pal, .allocator = allocator };
    defer front.cap.rgb.deinit(allocator);
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

    var emu = try testing.Emulator.init(allocator, args.rom_path);
    defer emu.deinit(allocator);
    if (args.pal) {
        emu.setPalMode(true);
        emu.reset();
    }

    // Run both cores to the target frame (inclusive).
    var f: usize = 0;
    while (f <= args.frame) : (f += 1) {
        api.run();
        emu.runFrame();
    }

    // Reference (Genesis Plus GX).
    const ref_path = try std.fmt.allocPrint(allocator, "{s}_gpgx.ppm", .{args.out_prefix});
    defer allocator.free(ref_path);
    try writePpm(ref_path, front.cap.rgb.items, front.cap.width, front.cap.height);

    // Sandopolis (XRGB8888 u32 framebuffer).
    const fb = emu.framebuffer();
    const sw: usize = emu.framebufferWidth();
    const sh: usize = if (sw != 0) fb.len / sw else 0;
    var srgb = try allocator.alloc(u8, sw * sh * 3);
    defer allocator.free(srgb);
    for (fb[0 .. sw * sh], 0..) |px, i| {
        srgb[i * 3 + 0] = @truncate(px >> 16);
        srgb[i * 3 + 1] = @truncate(px >> 8);
        srgb[i * 3 + 2] = @truncate(px);
    }
    const sando_path = try std.fmt.allocPrint(allocator, "{s}_sando.ppm", .{args.out_prefix});
    defer allocator.free(sando_path);
    try writePpm(sando_path, srgb, sw, sh);

    var out_buf: [512]u8 = undefined;
    var w = platform.stdout().writer(&out_buf);
    const stdout = &w.interface;
    try stdout.print(
        "frame {d} ({s}) pixfmt={d}\n  gpgx : {d}x{d} -> {s}\n  sando: {d}x{d} -> {s}\n",
        .{ args.frame, if (args.pal) "PAL" else "NTSC", front.pixel_format, front.cap.width, front.cap.height, ref_path, sw, sh, sando_path },
    );
    try stdout.flush();
}

fn parseArgs(it: *std.process.Args.Iterator) !Args {
    _ = it.next();
    const rom = it.next() orelse {
        std.debug.print("Usage: dump-frames <rom> <frame> [--pal] [--out PREFIX]\n", .{});
        return error.InvalidArgs;
    };
    var a = Args{ .rom_path = rom };
    var positional: usize = 0;
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--pal")) {
            a.pal = true;
        } else if (std.mem.eql(u8, arg, "--out")) {
            a.out_prefix = it.next() orelse return error.InvalidArgs;
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
