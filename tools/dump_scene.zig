const std = @import("std");
const sandopolis = @import("sandopolis_testing");
const platform = sandopolis.platform;
const SystemMachine = sandopolis.SystemMachine;
const Scene = sandopolis.Scene;
const recon_mod = sandopolis.SceneRecon;
const Reconstruction = recon_mod.Reconstruction;

// Dump the frame scene description a 3D frontend would consume, and check
// that it is complete enough to rebuild the picture.
//
// The tool reconstructs the frame from the scene alone, then compares that
// against the rasterizer's own framebuffer. A high match rate means the
// scene carries everything needed to draw the frame. The remaining pixels
// are the known gaps, which today are per-scanline horizontal scroll and
// the deliberately unenforced eight-sprites-per-line limit.
//
// Usage: dump-scene <rom> [frame] [--pal] [--out PREFIX] [--tiles]

const Args = struct {
    rom_path: []const u8,
    frame: usize = 120,
    pal: bool = false,
    out_prefix: []const u8 = "scene",
    show_tiles: bool = false,
    raw_path: ?[]const u8 = null,
    atlas_path: ?[]const u8 = null,
    /// With --raw, also write this many consecutive frames (path.0, path.1, ...).
    raw_seq: usize = 0,
};

fn writePpm(path: []const u8, pixels: []const u32, stride: usize, x0: usize, y0: usize, width: usize, height: usize, allocator: std.mem.Allocator) !void {
    const rgb = try allocator.alloc(u8, width * height * 3);
    defer allocator.free(rgb);
    for (0..height) |y| {
        for (0..width) |x| {
            const px = pixels[(y0 + y) * stride + (x0 + x)];
            const at = (y * width + x) * 3;
            rgb[at] = @truncate(px >> 16);
            rgb[at + 1] = @truncate(px >> 8);
            rgb[at + 2] = @truncate(px);
        }
    }

    var file = try platform.cwd().createFile(path, .{});
    defer file.close();
    var buf: [64]u8 = undefined;
    try file.writeAll(try std.fmt.bufPrint(&buf, "P6\n{d} {d}\n255\n", .{ width, height }));
    try file.writeAll(rgb);
}

/// Write the tile atlas as a contact sheet, 32 tiles across, with a
/// one-pixel gutter between tiles so indices can be counted by eye. This is
/// the view a person needs in order to say "tiles 96 to 111 are the maze
/// walls", which is the first step of authoring a per-game 3D profile.
fn writeAtlasSheet(
    path: []const u8,
    s: *const Scene.FrameScene,
    bank: u8,
    allocator: std.mem.Allocator,
) !void {
    const cols: usize = 32;
    const rows: usize = Scene.max_tiles / cols;
    const cell: usize = 9; // 8 pixels plus a gutter
    const w = cols * cell + 1;
    const h = rows * cell + 1;

    const rgb = try allocator.alloc(u8, w * h * 3);
    defer allocator.free(rgb);
    // Gutters in a mid grey so empty tiles stay distinguishable from them.
    @memset(rgb, 0x40);

    for (0..Scene.max_tiles) |tile| {
        const tx = (tile % cols) * cell + 1;
        const ty = (tile / cols) * cell + 1;
        const pixels = s.tilePixels(tile);
        for (0..8) |py| {
            for (0..8) |px| {
                const ci = pixels[py * 8 + px];
                const color: u32 = if (ci == 0) 0xFF000000 else s.palette[bank + ci];
                const at = ((ty + py) * w + (tx + px)) * 3;
                rgb[at] = @truncate(color >> 16);
                rgb[at + 1] = @truncate(color >> 8);
                rgb[at + 2] = @truncate(color);
            }
        }
    }

    var file = try platform.cwd().createFile(path, .{});
    defer file.close();
    var buf: [64]u8 = undefined;
    try file.writeAll(try std.fmt.bufPrint(&buf, "P6\n{d} {d}\n255\n", .{ w, h }));
    try file.writeAll(rgb);
}

/// Report which tile indices the tilemap actually references, and how often.
/// Rare tiles are usually decoration; the most common ones are the terrain
/// worth assigning a height to.
fn reportTileUsage(s: *const Scene.FrameScene, stdout: anytype) !void {
    var counts = [_]u16{0} ** Scene.max_tiles;
    for (0..s.rows) |row| {
        for (0..s.columns) |col| {
            counts[s.cell(col, row).tile_index] += 1;
        }
    }
    try stdout.print("\ntilemap tile usage (index x count):\n  ", .{});
    var shown: usize = 0;
    for (0..Scene.max_tiles) |i| {
        if (counts[i] == 0) continue;
        try stdout.print("{d}x{d} ", .{ i, counts[i] });
        shown += 1;
        if (shown % 10 == 0) try stdout.print("\n  ", .{});
    }
    try stdout.print("\n  ({d} distinct tiles used)\n", .{shown});
}

fn systemName(kind: u8) []const u8 {
    return switch (kind) {
        @intFromEnum(Scene.SystemKind.sms) => "Master System",
        @intFromEnum(Scene.SystemKind.game_gear) => "Game Gear",
        @intFromEnum(Scene.SystemKind.sg1000) => "SG-1000",
        @intFromEnum(Scene.SystemKind.genesis) => "Genesis",
        else => "unknown",
    };
}

fn modeName(mode: u8) []const u8 {
    return switch (mode) {
        @intFromEnum(Scene.GraphicsMode.mode4) => "Mode 4",
        @intFromEnum(Scene.GraphicsMode.mode0_text) => "TMS9918 Mode 0 (text)",
        @intFromEnum(Scene.GraphicsMode.mode1_graphics1) => "TMS9918 Mode 1 (graphics I)",
        @intFromEnum(Scene.GraphicsMode.mode2_graphics2) => "TMS9918 Mode 2 (graphics II)",
        @intFromEnum(Scene.GraphicsMode.mode3_multicolor) => "TMS9918 Mode 3 (multicolor)",
        else => "unknown",
    };
}

pub fn main(init: std.process.Init) !void {
    platform.init(init);
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var arg_it = try platform.argsWithAllocator(allocator);
    defer arg_it.deinit();
    const args = try parseArgs(&arg_it);

    var machine = try SystemMachine.init(allocator, args.rom_path);
    defer machine.deinit(allocator);
    // Genesis boots through an explicit reset (stack pointer and program
    // counter come from the ROM vector table); SMS power-on state is the
    // init state.
    if (machine.asGenesis()) |g| g.reset();
    if (args.pal) {
        machine.setPalMode(true);
        machine.reset();
    }
    for (0..args.frame) |_| machine.runFrame();

    const s = try allocator.create(Scene.FrameScene);
    defer allocator.destroy(s);
    s.* = .{};

    var out_buf: [4096]u8 = undefined;
    var w = platform.stdout().writer(&out_buf);
    const stdout = &w.interface;

    const ok = machine.extractScene(s);

    try stdout.print("rom     : {s}\n", .{args.rom_path});
    try stdout.print("frame   : {d} ({s})\n", .{ args.frame, if (args.pal) "PAL" else "NTSC" });
    try stdout.print("system  : {s}\n", .{systemName(s.system)});
    try stdout.print("mode    : {s}\n", .{modeName(s.mode)});

    if (!ok) {
        try stdout.print("\nNo scene content: this mode is not described yet.\n", .{});
        try stdout.flush();
        return;
    }

    try stdout.print("picture : {d}x{d}\n", .{ s.picture_width, s.picture_height });
    try stdout.print("viewport: {d}x{d} at ({d},{d})\n", .{
        s.viewport_width, s.viewport_height, s.viewport_x, s.viewport_y,
    });
    try stdout.print("tilemap : {d}x{d} cells\n", .{ s.columns, s.rows });
    try stdout.print("scroll  : x={d} y={d}\n", .{ s.scroll_x, s.scroll_y });
    try stdout.print("hud     : {d} locked rows, {d} locked columns\n", .{
        s.hud_locked_rows, s.hud_locked_columns,
    });
    try stdout.print("display : {s}{s}\n", .{
        if (s.flags & Scene.scene_flag_display_enabled != 0) "on" else "off",
        if (s.flags & Scene.scene_flag_left_column_blanked != 0) ", left column blanked" else "",
    });
    try stdout.print("backdrop: #{X:0>6}\n", .{s.backdrop & 0xFFFFFF});

    var dirty: usize = 0;
    var used: usize = 0;
    for (0..Scene.max_tiles) |i| {
        if (s.tileIsDirty(i)) dirty += 1;
        for (s.tilePixels(i)) |px| {
            if (px != 0) {
                used += 1;
                break;
            }
        }
    }
    try stdout.print("tiles   : {d} of {d} non-empty, {d} changed this extraction\n", .{
        used, s.tile_count, dirty,
    });

    if (s.system == @intFromEnum(Scene.SystemKind.genesis)) {
        var hs = std.AutoHashMapUnmanaged(i16, void){};
        defer hs.deinit(allocator);
        var hsb = std.AutoHashMapUnmanaged(i16, void){};
        defer hsb.deinit(allocator);
        for (0..s.picture_height) |y| {
            hs.put(allocator, s.gen_a_line_hscroll[y], {}) catch {};
            hsb.put(allocator, s.gen_b_line_hscroll[y], {}) catch {};
        }
        try stdout.print("genesis : plane {d}x{d} tiles, {d} sprites, {d}/{d} distinct A/B hscroll values{s}{s}\n", .{
            s.gen_plane_width,           s.gen_plane_height,
            s.gen_sprite_count,          hs.count(),
            hsb.count(),
            if (s.gen_flags & Scene.gen_flag_shadow_highlight != 0) ", S/H" else "",
            if (s.gen_flags & Scene.gen_flag_interlace2 != 0) ", interlace2" else "",
        });
    }

    try stdout.print("\nsprites ({d}):\n", .{s.sprite_count});
    const shown = @min(s.sprite_count, 16);
    for (0..shown) |i| {
        const sp = s.sprites[i];
        try stdout.print("  slot {d:>2}  pos ({d:>4},{d:>4})  {d}x{d}  tile {d:>3}{s}\n", .{
            sp.slot, sp.x, sp.y, sp.width, sp.height, sp.tile_index,
            if (sp.flags & Scene.sprite_flag_doubled != 0) "  doubled" else "",
        });
    }
    if (s.sprite_count > shown) {
        try stdout.print("  ... {d} more\n", .{s.sprite_count - shown});
    }

    if (args.show_tiles) {
        try stdout.print("\ntilemap (tile index per cell, hex):\n", .{});
        for (0..s.rows) |row| {
            try stdout.print("  ", .{});
            for (0..s.columns) |col| {
                try stdout.print("{x:0>3} ", .{s.cell(col, row).tile_index});
            }
            try stdout.print("\n", .{});
        }
    }

    // Rebuild the frame from the scene and compare it against the picture
    // the rasterizer actually produced.
    var recon = try Reconstruction.init(allocator, s.picture_width, s.picture_height);
    defer recon.deinit(allocator);
    recon_mod.reconstruct(s, &recon);

    const actual = machine.framebuffer();
    const stride: usize = machine.framebufferStride();
    const vw: usize = s.viewport_width;
    const vh: usize = s.viewport_height;

    var matched: usize = 0;
    var compared: usize = 0;
    if (actual.len >= vw * vh) {
        for (0..vh) |y| {
            for (0..vw) |x| {
                const from_scene = recon.pixels[(s.viewport_y + y) * recon.width + (s.viewport_x + x)];
                const from_raster = actual[y * stride + x];
                compared += 1;
                if (from_scene & 0xFFFFFF == from_raster & 0xFFFFFF) matched += 1;
            }
        }
    }

    const scene_path = try std.fmt.allocPrint(allocator, "{s}-from-scene.ppm", .{args.out_prefix});
    defer allocator.free(scene_path);
    const raster_path = try std.fmt.allocPrint(allocator, "{s}-raster.ppm", .{args.out_prefix});
    defer allocator.free(raster_path);

    try writePpm(scene_path, recon.pixels, recon.width, s.viewport_x, s.viewport_y, vw, vh, allocator);
    try writePpm(raster_path, actual, stride, 0, 0, vw, vh, allocator);

    if (compared > 0) {
        const pct = @as(f64, @floatFromInt(matched)) * 100.0 / @as(f64, @floatFromInt(compared));
        try stdout.print("\nrebuilt from scene: {d}/{d} pixels match the rasterizer ({d:.3}%)\n", .{
            matched, compared, pct,
        });
    }
    if (args.atlas_path) |path| {
        try writeAtlasSheet(path, s, 0, allocator);
        try stdout.print("wrote {s} (tile contact sheet)\n", .{path});
        try reportTileUsage(s, stdout);
    }

    if (args.raw_path) |path| {
        // The exact bytes a WebAssembly frontend would read, so the JS
        // offset table can be checked against the real struct layout.
        var file = try platform.cwd().createFile(path, .{});
        defer file.close();
        try file.writeAll(std.mem.asBytes(s));
        try stdout.print("wrote {s} ({d} bytes)\n", .{ path, @sizeOf(Scene.FrameScene) });

        // Consecutive frames, for consumers that need inter-frame state
        // (the renderer's scroll-velocity depth inference).
        for (0..args.raw_seq) |i| {
            machine.runFrame();
            machine.discardPendingAudio();
            if (!machine.extractScene(s)) break;
            var seq_buf: [160]u8 = undefined;
            const seq_path = try std.fmt.bufPrint(&seq_buf, "{s}.{d}", .{ path, i });
            var seq_file = try platform.cwd().createFile(seq_path, .{});
            defer seq_file.close();
            try seq_file.writeAll(std.mem.asBytes(s));
        }
        if (args.raw_seq > 0) try stdout.print("wrote {d} consecutive frames ({s}.0 ..)\n", .{ args.raw_seq, path });
    }

    try stdout.print("wrote {s} and {s}\n", .{ scene_path, raster_path });
    try stdout.flush();
}

fn parseArgs(it: *std.process.Args.Iterator) !Args {
    _ = it.next();
    const rom = it.next() orelse {
        std.debug.print("Usage: dump-scene <rom> [frame] [--pal] [--out PREFIX] [--tiles] [--raw PATH] [--atlas PATH]\n", .{});
        return error.InvalidArgs;
    };
    var a = Args{ .rom_path = rom };
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--pal")) {
            a.pal = true;
        } else if (std.mem.eql(u8, arg, "--tiles")) {
            a.show_tiles = true;
        } else if (std.mem.eql(u8, arg, "--out")) {
            a.out_prefix = it.next() orelse return error.InvalidArgs;
        } else if (std.mem.eql(u8, arg, "--raw")) {
            a.raw_path = it.next() orelse return error.InvalidArgs;
        } else if (std.mem.eql(u8, arg, "--raw-seq")) {
            a.raw_seq = std.fmt.parseInt(usize, it.next() orelse return error.InvalidArgs, 10) catch return error.InvalidArgs;
        } else if (std.mem.eql(u8, arg, "--atlas")) {
            a.atlas_path = it.next() orelse return error.InvalidArgs;
        } else {
            a.frame = std.fmt.parseInt(usize, arg, 10) catch return error.InvalidArgs;
        }
    }
    return a;
}
