const std = @import("std");
const sandopolis = @import("sandopolis_testing");
const platform = sandopolis.platform;
const SystemMachine = sandopolis.SystemMachine;
const Scene = sandopolis.Scene;

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
};

const max_picture_pixels = Scene.max_columns * 8 * 256;

const Reconstruction = struct {
    pixels: []u32,
    priority: []bool,
    sprite_drawn: []bool,
    width: usize,
    height: usize,

    fn init(allocator: std.mem.Allocator, width: usize, height: usize) !Reconstruction {
        return .{
            .pixels = try allocator.alloc(u32, width * height),
            .priority = try allocator.alloc(bool, width * height),
            .sprite_drawn = try allocator.alloc(bool, width * height),
            .width = width,
            .height = height,
        };
    }

    fn deinit(self: *Reconstruction, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
        allocator.free(self.priority);
        allocator.free(self.sprite_drawn);
    }
};

/// Rebuild the frame from the scene description alone, mirroring the order
/// the VDP composites in: backdrop, background, sprites, left column blank.
fn reconstruct(s: *const Scene.FrameScene, r: *Reconstruction) void {
    @memset(r.pixels, s.backdrop);
    @memset(r.priority, false);
    @memset(r.sprite_drawn, false);

    if (!s.contentValid()) return;
    if (s.flags & Scene.scene_flag_display_enabled == 0) return;

    const rows: usize = s.rows;
    // The 224 and 240 line modes wrap the tilemap at 256 pixels, not 224.
    const vertical_wrap: usize = if (rows > 28) 256 else 224;
    const locked_lines: usize = @as(usize, s.hud_locked_rows) * 8;
    const locked_col_start: usize = if (s.hud_locked_columns > 0)
        Scene.max_columns - s.hud_locked_columns
    else
        Scene.max_columns;

    for (0..r.height) |y| {
        const h_locked = y < locked_lines;
        const hscroll: usize = if (h_locked) 0 else s.scroll_x;
        const coarse = (hscroll >> 3) & 0x1F;
        const fine = hscroll & 0x7;

        for (0..r.width) |x| {
            const col = x / 8;
            // Fine scrolling leaves the leftmost pixels on the backdrop
            // rather than wrapping them in from the right edge.
            if (!h_locked and fine != 0 and x < fine) continue;

            const scrolled_x = if (h_locked) x else x - fine;
            const source_col = if (h_locked)
                col
            else
                (scrolled_x / 8 + Scene.max_columns - coarse) % Scene.max_columns;

            const v_locked = col >= locked_col_start;
            const effective_y = if (v_locked) y else (y + s.scroll_y) % vertical_wrap;
            const row = effective_y / 8;
            if (row >= rows) continue;

            const cell = s.cell(source_col, row);
            const fine_y = effective_y % 8;
            const ty = if (cell.flags & Scene.cell_flag_v_flip != 0) 7 - fine_y else fine_y;
            const fine_x = scrolled_x % 8;
            const tx = if (cell.flags & Scene.cell_flag_h_flip != 0) 7 - fine_x else fine_x;

            const color = s.tilePixels(cell.tile_index)[ty * 8 + tx];
            if (color == 0) continue;

            const at = y * r.width + x;
            r.pixels[at] = s.palette[cell.palette + color];
            r.priority[at] = cell.flags & Scene.cell_flag_priority != 0;
        }
    }

    // Sprites composite in table order, so the lowest slot covering a pixel
    // wins even when a higher slot is also opaque there.
    for (0..s.sprite_count) |i| {
        const sp = s.sprites[i];
        const doubled = sp.flags & Scene.sprite_flag_doubled != 0;

        for (0..sp.height) |ry| {
            const sy = @as(i32, sp.y) + @as(i32, @intCast(ry));
            if (sy < 0 or sy >= r.height) continue;

            const source_row = if (doubled) ry / 2 else ry;
            // Tall sprites continue into the next pattern after eight rows.
            const tile = sp.tile_index + @as(u16, if (source_row >= 8) 1 else 0);
            if (tile >= Scene.max_tiles) continue;
            const pattern = s.tilePixels(tile);
            const in_row = source_row % 8;

            for (0..sp.width) |rx| {
                const sx = @as(i32, sp.x) + @as(i32, @intCast(rx));
                if (sx < 0 or sx >= r.width) continue;

                const source_col = if (doubled) rx / 2 else rx;
                const color = pattern[in_row * 8 + source_col];
                if (color == 0) continue;

                const at = @as(usize, @intCast(sy)) * r.width + @as(usize, @intCast(sx));
                if (r.sprite_drawn[at]) continue;
                r.sprite_drawn[at] = true;
                // Background cells flagged as high priority stay in front.
                if (r.priority[at]) continue;
                r.pixels[at] = s.palette[sp.palette + color];
            }
        }
    }

    if (s.flags & Scene.scene_flag_left_column_blanked != 0) {
        for (0..r.height) |y| {
            for (0..@min(8, r.width)) |x| r.pixels[y * r.width + x] = s.backdrop;
        }
    }
}

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
    reconstruct(s, &recon);

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
    if (args.raw_path) |path| {
        // The exact bytes a WebAssembly frontend would read, so the JS
        // offset table can be checked against the real struct layout.
        var file = try platform.cwd().createFile(path, .{});
        defer file.close();
        try file.writeAll(std.mem.asBytes(s));
        try stdout.print("wrote {s} ({d} bytes)\n", .{ path, @sizeOf(Scene.FrameScene) });
    }

    try stdout.print("wrote {s} and {s}\n", .{ scene_path, raster_path });
    try stdout.flush();
}

fn parseArgs(it: *std.process.Args.Iterator) !Args {
    _ = it.next();
    const rom = it.next() orelse {
        std.debug.print("Usage: dump-scene <rom> [frame] [--pal] [--out PREFIX] [--tiles]\n", .{});
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
        } else {
            a.frame = std.fmt.parseInt(usize, arg, 10) catch return error.InvalidArgs;
        }
    }
    return a;
}
