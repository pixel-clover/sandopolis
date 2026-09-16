const std = @import("std");
const sandopolis = @import("sandopolis_testing");
const platform = sandopolis.platform;
const SystemMachine = sandopolis.SystemMachine;
const Scene = sandopolis.Scene;

// Mine a draft 3D profile from gameplay.
//
// Runs a ROM's attract mode headlessly, extracts the frame scene every
// frame, and accumulates per-tile behavior statistics that stand in for the
// judgment a human profile author would apply:
//
//   - tiles in scroll-locked rows or the window plane are status displays
//   - tiles whose pixels change often are animation (water, fire): flat
//   - very common tiles are base terrain: low
//   - rare tiles are decoration and structures: raised
//   - tiles with priority set draw in front of sprites: tall
//   - tiles that sprites pass over far more often than typical cannot be
//     tall obstacles, whatever their rarity
//
// It also clusters sprites into meta-sprites (sprites moving with identical
// deltas between frames are one game object) and reports the recurring
// entities it saw. Entities are informational for now; heights are written
// as a profile the web frontend loads by ROM content hash.
//
// The output is a draft: automation gets a game to "good enough to orbit",
// a human still owns the final art direction.
//
// Usage: mine-profile <rom> [--frames N] [--warmup N] [--out PATH] [--stats]

/// Bumped whenever the height heuristics change, so a profile records which
/// rules produced it. Without this, regenerating with a newer miner silently
/// yields different heights and a committed draft cannot be reproduced.
/// v1: HUD/animation overrides, material-share tiers, priority and
///     sprite-overlap adjustments, gameplay-gated sampling.
const heuristics_version: u32 = 1;

const Args = struct {
    rom_path: []const u8,
    frames: usize = 3600,
    warmup: usize = 600,
    out_path: ?[]const u8 = null,
    show_stats: bool = false,
    force: bool = false,
};

const TileStats = struct {
    /// Tilemap references summed over sampled frames.
    usage: u64 = 0,
    /// Samples in which the tile's pixels changed.
    dirty: u32 = 0,
    /// Samples in which the tile appeared in a HUD region (scroll-locked
    /// rows on SMS, the window plane on Genesis).
    hud: u32 = 0,
    /// References with the priority flag set.
    priority: u64 = 0,
    /// Times a sprite's bounding box covered a cell showing this tile.
    overlap: u64 = 0,
    /// Referenced by a sprite rather than the background.
    sprite: bool = false,
};

/// A recurring meta-sprite: sprites that moved together, identified by the
/// multiset of tiles they use.
const Entity = struct {
    signature: [8]u16 = [_]u16{0} ** 8,
    signature_len: u8 = 0,
    sprite_count: u8 = 0,
    width: u16 = 0,
    height: u16 = 0,
    frames_seen: u32 = 0,
};

const SpritePoint = struct {
    x: i32,
    y: i32,
    w: u16,
    h: u16,
    tile: u16,
    cluster: u16 = 0xFFFF,
};

pub fn main(init: std.process.Init) !void {
    platform.init(init);
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var arg_it = try platform.argsWithAllocator(allocator);
    defer arg_it.deinit();
    const args = try parseArgs(&arg_it);

    var out_buf: [4096]u8 = undefined;
    var w = platform.stdout().writer(&out_buf);
    const stdout = &w.interface;

    // Hash the raw file bytes the same way the web frontend does, so the
    // emitted profile lands under the key the page will look up.
    const rom_bytes = try platform.cwd().readFileAlloc(allocator, args.rom_path, 8 * 1024 * 1024);
    defer allocator.free(rom_bytes);
    const rom_key = fnv1a(rom_bytes);

    var machine = try SystemMachine.init(allocator, args.rom_path);
    defer machine.deinit(allocator);
    if (machine.asGenesis()) |g| g.reset();

    const scene = try allocator.create(Scene.FrameScene);
    defer allocator.destroy(scene);
    scene.* = .{};

    const stats = try allocator.alloc(TileStats, Scene.max_tiles);
    defer allocator.free(stats);
    @memset(stats, .{});

    var entities = std.ArrayListUnmanaged(Entity).empty;
    defer entities.deinit(allocator);

    var sprite_points = std.ArrayListUnmanaged(SpritePoint).empty;
    defer sprite_points.deinit(allocator);

    var samples: u32 = 0;
    for (0..args.frames) |frame| {
        machine.runFrame();
        machine.discardPendingAudio();
        if (frame < args.warmup) continue;
        if (!machine.extractScene(scene)) continue;
        if (!scene.contentValid()) continue;
        // Title screens and menus dominate attract-mode time and would skew
        // the usage statistics (a title logo tile would look like "base
        // terrain"). Only frames that look like play count: several
        // on-screen sprites with real pattern content.
        if (!looksLikeGameplay(scene)) continue;
        samples += 1;

        accumulateTiles(scene, stats);
        try accumulateSprites(allocator, scene, stats, &sprite_points, &entities);
    }

    if (samples == 0) {
        try stdout.print("no scene content extracted; nothing to mine\n", .{});
        try stdout.flush();
        return;
    }

    const heights = try allocator.alloc(f32, Scene.max_tiles);
    defer allocator.free(heights);
    assignHeights(scene, stats, heights, samples);

    if (args.show_stats) {
        try printStats(stdout, stats, heights, samples);
    }

    // Entity report: recurring meta-sprites, most persistent first.
    std.mem.sort(Entity, entities.items, {}, entityMoreSeen);
    var reported: usize = 0;
    try stdout.print("entities (meta-sprites seen across frames):\n", .{});
    for (entities.items) |e| {
        if (e.frames_seen < samples / 20) continue; // transient noise
        try stdout.print("  {d:>5} frames  {d} sprites  {d}x{d}px  tiles ", .{
            e.frames_seen, e.sprite_count, e.width, e.height,
        });
        for (e.signature[0..e.signature_len]) |t| try stdout.print("{d} ", .{t});
        try stdout.print("\n", .{});
        reported += 1;
        if (reported >= 12) break;
    }
    if (reported == 0) try stdout.print("  (none persisted long enough)\n", .{});

    // Emit the profile.
    var key_buf: [32]u8 = undefined;
    const key = try std.fmt.bufPrint(&key_buf, "{x:0>8}-{x}", .{ rom_key, rom_bytes.len });
    var path_buf: [128]u8 = undefined;
    const out_path = args.out_path orelse try std.fmt.bufPrint(&path_buf, "web/profiles/{s}.json", .{key});
    // A profile may carry hand-tuned heights; refuse to clobber it silently.
    // Only a file we can read AND that identifies itself as machine-generated
    // may be replaced: an unreadable or oversized existing file is treated as
    // protected, never as absent.
    if (!args.force) {
        if (platform.cwd().readFileAlloc(allocator, out_path, 1024 * 1024)) |existing| {
            defer allocator.free(existing);
            if (std.mem.indexOf(u8, existing, "Machine-generated") == null) {
                try stdout.print("refusing to overwrite {s}: not machine-generated (pass --force)\n", .{out_path});
                try stdout.flush();
                return;
            }
        } else |err| {
            if (err != error.FileNotFound) {
                try stdout.print("refusing to overwrite {s}: unreadable ({t}); pass --force\n", .{ out_path, err });
                try stdout.flush();
                return;
            }
        }
    }
    try writeProfile(allocator, out_path, args, key, heights, stats, entities.items, samples);

    try stdout.print(
        "\nmined {d} samples over {d} frames\nwrote {s}\n",
        .{ samples, args.frames, out_path },
    );
    try stdout.flush();
}

fn looksLikeGameplay(scene: *const Scene.FrameScene) bool {
    var live: u32 = 0;
    if (scene.system == @intFromEnum(Scene.SystemKind.genesis)) {
        for (scene.gen_sprites[0..scene.gen_sprite_count]) |sp| {
            if (spriteIsLive(scene, sp.x, sp.y, sp.tile_base)) live += 1;
        }
    } else {
        for (scene.sprites[0..scene.sprite_count]) |sp| {
            if (spriteIsLive(scene, sp.x, sp.y, sp.tile_index)) live += 1;
        }
    }
    return live >= 2;
}

fn spriteIsLive(scene: *const Scene.FrameScene, x: i16, y: i16, tile: u16) bool {
    if (x <= -16 or y <= -16) return false;
    if (x >= scene.picture_width or y >= scene.picture_height) return false;
    if (tile >= Scene.max_tiles) return false;
    for (scene.tilePixels(tile)) |px| {
        if (px != 0) return true;
    }
    return false;
}

fn fnv1a(bytes: []const u8) u32 {
    var h: u32 = 0x811c9dc5;
    for (bytes) |b| {
        h ^= b;
        h *%= 0x01000193;
    }
    return h;
}

fn accumulateTiles(scene: *const Scene.FrameScene, stats: []TileStats) void {
    if (scene.system == @intFromEnum(Scene.SystemKind.genesis)) {
        const cells = @as(usize, scene.gen_plane_width) * scene.gen_plane_height;
        for (scene.gen_plane_a[0..cells]) |cell| noteCell(stats, cell, false);
        for (scene.gen_plane_b[0..cells]) |cell| noteCell(stats, cell, false);
        const win = @as(usize, scene.gen_window_width) * 32;
        for (scene.gen_window[0..@min(win, Scene.gen_window_cells)]) |cell| {
            noteCell(stats, cell, true);
        }
    } else {
        const rows: usize = scene.rows;
        for (0..rows) |row| {
            const hud_row = row < scene.hud_locked_rows;
            for (0..@as(usize, scene.columns)) |col| {
                const hud = hud_row or
                    (scene.hud_locked_columns > 0 and col >= Scene.max_columns - scene.hud_locked_columns);
                noteCell(stats, scene.cell(col, row), hud);
            }
        }
    }

    for (0..Scene.max_tiles) |t| {
        if (scene.tileIsDirty(t)) stats[t].dirty += 1;
    }
}

fn noteCell(stats: []TileStats, cell: Scene.Cell, hud: bool) void {
    const t = cell.tile_index;
    if (t >= Scene.max_tiles) return;
    stats[t].usage += 1;
    if (hud) stats[t].hud += 1;
    if (cell.flags & Scene.cell_flag_priority != 0) stats[t].priority += 1;
}

fn accumulateSprites(
    allocator: std.mem.Allocator,
    scene: *const Scene.FrameScene,
    stats: []TileStats,
    points: *std.ArrayListUnmanaged(SpritePoint),
    entities: *std.ArrayListUnmanaged(Entity),
) !void {
    points.clearRetainingCapacity();

    if (scene.system == @intFromEnum(Scene.SystemKind.genesis)) {
        for (scene.gen_sprites[0..scene.gen_sprite_count]) |sp| {
            const w = @as(u16, sp.h_size) * 8;
            const h = @as(u16, sp.v_size) * 8;
            try points.append(allocator, .{ .x = sp.x, .y = sp.y, .w = w, .h = h, .tile = sp.tile_base });
            markSpriteTiles(stats, sp.tile_base, @as(u16, sp.h_size) * sp.v_size);
        }
    } else {
        for (scene.sprites[0..scene.sprite_count]) |sp| {
            try points.append(allocator, .{ .x = sp.x, .y = sp.y, .w = sp.width, .h = sp.height, .tile = sp.tile_index });
            markSpriteTiles(stats, sp.tile_index, if (sp.height > 8) 2 else 1);
        }
    }

    // Sprite-over-background: which tiles do sprites cover? Sampled at the
    // sprite's center cell to keep it cheap.
    for (points.items) |p| {
        const cx = p.x + @divTrunc(@as(i32, p.w), 2);
        const cy = p.y + @divTrunc(@as(i32, p.h), 2);
        if (cx < 0 or cy < 0 or cx >= scene.picture_width or cy >= scene.picture_height) continue;
        const t = backgroundTileAt(scene, @intCast(cx), @intCast(cy));
        if (t) |tile| {
            if (tile < Scene.max_tiles) stats[tile].overlap += 1;
        }
    }

    // Meta-sprite clustering: greedy adjacency within 24 pixels.
    var cluster_count: u16 = 0;
    for (points.items, 0..) |*p, i| {
        if (p.cluster != 0xFFFF) continue;
        p.cluster = cluster_count;
        // Grow the cluster transitively.
        var changed = true;
        while (changed) {
            changed = false;
            for (points.items[i..]) |*q| {
                if (q.cluster != 0xFFFF) continue;
                for (points.items) |r| {
                    if (r.cluster != cluster_count) continue;
                    const dx = @abs(q.x - r.x);
                    const dy = @abs(q.y - r.y);
                    if (dx <= 24 and dy <= 24) {
                        q.cluster = cluster_count;
                        changed = true;
                        break;
                    }
                }
            }
        }
        cluster_count += 1;
    }

    // Fold clusters into recurring entities by tile signature.
    var c: u16 = 0;
    while (c < cluster_count) : (c += 1) {
        var sig: [8]u16 = [_]u16{0} ** 8;
        var sig_len: u8 = 0;
        var count: u8 = 0;
        var min_x: i32 = std.math.maxInt(i32);
        var min_y: i32 = std.math.maxInt(i32);
        var max_x: i32 = std.math.minInt(i32);
        var max_y: i32 = std.math.minInt(i32);
        for (points.items) |p| {
            if (p.cluster != c) continue;
            count += 1;
            min_x = @min(min_x, p.x);
            min_y = @min(min_y, p.y);
            max_x = @max(max_x, p.x + p.w);
            max_y = @max(max_y, p.y + p.h);
            if (sig_len < sig.len) {
                sig[sig_len] = p.tile;
                sig_len += 1;
            }
        }
        if (count == 0) continue;
        var any_content = false;
        for (sig[0..sig_len]) |t| {
            if (t >= Scene.max_tiles) continue;
            for (scene.tilePixels(t)) |px| {
                if (px != 0) {
                    any_content = true;
                    break;
                }
            }
        }
        if (!any_content) continue;
        std.mem.sort(u16, sig[0..sig_len], {}, std.sort.asc(u16));

        // Merge into an existing entity with the same signature.
        var found = false;
        for (entities.items) |*e| {
            if (e.signature_len == sig_len and std.mem.eql(u16, e.signature[0..sig_len], sig[0..sig_len])) {
                e.frames_seen += 1;
                found = true;
                break;
            }
        }
        if (!found) {
            try entities.append(allocator, .{
                .signature = sig,
                .signature_len = sig_len,
                .sprite_count = count,
                .width = @intCast(@max(0, max_x - min_x)),
                .height = @intCast(@max(0, max_y - min_y)),
                .frames_seen = 1,
            });
        }
    }
}

fn markSpriteTiles(stats: []TileStats, base: u16, count: u16) void {
    var i: u16 = 0;
    while (i < count) : (i += 1) {
        const t = base + i;
        if (t < Scene.max_tiles) stats[t].sprite = true;
    }
}

/// The background tile under a picture pixel, ignoring scroll on TMS (which
/// has none) and using the frame-level scroll elsewhere. Approximate by
/// design: this feeds a statistic, not a renderer.
fn backgroundTileAt(scene: *const Scene.FrameScene, x: u16, y: u16) ?u16 {
    if (scene.system == @intFromEnum(Scene.SystemKind.genesis)) {
        const plane_w_px = @as(u32, scene.gen_plane_width) * 8;
        const plane_h_px = @as(u32, scene.gen_plane_height) * 8;
        if (plane_w_px == 0 or plane_h_px == 0) return null;
        const hs = scene.gen_a_line_hscroll[@min(y, Scene.max_lines - 1)];
        const vs = scene.gen_a_col_vscroll[0];
        const wx = @mod(@as(i32, x) - hs, @as(i32, @intCast(plane_w_px)));
        const wy = @mod(@as(i32, y) + vs, @as(i32, @intCast(plane_h_px)));
        const idx = (@as(u32, @intCast(wy)) / 8) * scene.gen_plane_width + @as(u32, @intCast(wx)) / 8;
        if (idx >= Scene.gen_plane_cells) return null;
        return scene.gen_plane_a[idx].tile_index;
    }
    if (scene.rows == 0) return null;
    const wrap: u32 = if (scene.rows > 28) 256 else 224;
    const hscroll = scene.lineScrollX(y);
    const sx = (@as(u32, x) + 256 - (hscroll & 0xFF)) % 256;
    const sy = (@as(u32, y) + scene.scroll_y) % wrap;
    const row = sy / 8;
    if (row >= scene.rows) return null;
    return scene.cell(sx / 8, row).tile_index;
}

/// Group tiles into "materials" by their two most common palette entries.
/// Tiles of one material (desert variants, tree pieces) share a height, and
/// the material's combined usage decides its tier: rarity per tile cannot
/// tell a wall from a ground variant, but rarity per material can.
fn materialKey(scene: *const Scene.FrameScene, tile: usize) u16 {
    var counts = [_]u16{0} ** 16;
    for (scene.tilePixels(tile)) |px| {
        if (px != 0 and px < 16) counts[px] += 1;
    }
    var first: u16 = 0;
    var second: u16 = 0;
    for (counts, 0..) |c, i| {
        if (c > counts[first]) {
            second = first;
            first = @intCast(i);
        } else if (i != first and c > counts[second]) {
            second = @intCast(i);
        }
    }
    if (second > first) {
        const tmp = first;
        first = second;
        second = tmp;
    }
    return first * 16 + second;
}

fn assignHeights(scene: *const Scene.FrameScene, stats: []const TileStats, heights: []f32, samples: u32) void {
    // Material grouping: sum each material's usage, then tier materials by
    // their share of everything drawn.
    var mat_usage = [_]u64{0} ** 256;
    var tile_mat: [Scene.max_tiles]u16 = undefined;
    var total_usage: u64 = 0;
    for (stats, 0..) |s, t| {
        tile_mat[t] = materialKey(scene, t);
        if (s.usage > 0) {
            mat_usage[tile_mat[t]] += s.usage;
            total_usage += s.usage;
        }
    }
    if (total_usage == 0) {
        @memset(heights, 1.0);
        return;
    }

    var overlap_rates: [Scene.max_tiles]f64 = undefined;
    var overlap_len: usize = 0;
    for (stats) |s| {
        if (s.usage > 0 and s.overlap > 0) {
            overlap_rates[overlap_len] = @as(f64, @floatFromInt(s.overlap)) / @as(f64, @floatFromInt(s.usage));
            overlap_len += 1;
        }
    }

    var overlap_median: f64 = 0;
    if (overlap_len > 0) {
        std.mem.sort(f64, overlap_rates[0..overlap_len], {}, std.sort.asc(f64));
        overlap_median = overlap_rates[overlap_len / 2];
    }

    for (stats, 0..) |s, t| {
        // Sprites carve their own slabs at full height.
        if (s.sprite) {
            heights[t] = 1.0;
            continue;
        }
        if (s.usage == 0) {
            heights[t] = 0.10; // matches defaultHeight; unreferenced
            continue;
        }
        // Status displays are flat.
        if (s.hud * 2 >= samples) {
            heights[t] = 0.0;
            continue;
        }
        // Animation (water, fire, effects) reads better flat.
        if (s.dirty * 6 >= samples) {
            heights[t] = 0.05;
            continue;
        }

        // Tier by the tile's material share of everything drawn.
        const share = @as(f64, @floatFromInt(mat_usage[tile_mat[t]])) / @as(f64, @floatFromInt(total_usage));
        var h: f32 = if (share >= 0.15)
            0.10 // dominant material: base terrain
        else if (share <= 0.02)
            0.70 // scarce material: structures and decoration
        else
            0.40;

        // Priority tiles draw in front of sprites: overhangs and walls.
        if (s.priority * 2 >= s.usage) h = @max(h, 0.85);

        // Sprites pass over this tile far more than typical, so it cannot
        // be a tall obstacle whatever its rarity.
        if (overlap_median > 0) {
            const rate = @as(f64, @floatFromInt(s.overlap)) / @as(f64, @floatFromInt(s.usage));
            if (rate > overlap_median * 3.0) h = @min(h, 0.25);
        }

        heights[t] = h;
    }
}

fn entityMoreSeen(_: void, a: Entity, b: Entity) bool {
    return a.frames_seen > b.frames_seen;
}

fn printStats(stdout: anytype, stats: []const TileStats, heights: []const f32, samples: u32) !void {
    try stdout.print("tile stats ({d} samples): index usage dirty%% hud%% overlap height\n", .{samples});
    for (stats, 0..) |s, t| {
        if (s.usage == 0 and !s.sprite) continue;
        try stdout.print("  {d:>4} {d:>8} {d:>3} {d:>3} {d:>6} {d:.2}{s}\n", .{
            t,
            s.usage,
            if (samples > 0) s.dirty * 100 / samples else 0,
            if (samples > 0) s.hud * 100 / samples else 0,
            s.overlap,
            heights[t],
            if (s.sprite) " sprite" else "",
        });
    }
}

fn writeProfile(
    allocator: std.mem.Allocator,
    path: []const u8,
    args: Args,
    key: []const u8,
    heights: []const f32,
    stats: []const TileStats,
    entities: []const Entity,
    samples: u32,
) !void {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const jw = &aw.writer;

    const base = std.fs.path.basename(args.rom_path);
    // The generator block makes a draft reproducible and diffable: rerunning
    // with the same tool inputs and heuristics version yields the same
    // heights, and `samples` shows how much gameplay the statistics rest on
    // (a low count means the attract mode never reached play).
    try jw.print(
        \\{{
        \\  "name": "{s} (auto)",
        \\  "romKey": "{s}",
        \\  "note": "Machine-generated draft profile mined from attract-mode behavior statistics; heights are heuristics, not art direction.",
        \\  "generator": {{
        \\    "tool": "mine-profile",
        \\    "heuristics": {d},
        \\    "sceneLayout": {d},
        \\    "frames": {d},
        \\    "warmup": {d},
        \\    "samples": {d}
        \\  }},
        \\  "extrudeDepth": 0.13,
        \\  "defaultHeight": 0.10,
        \\  "tiles": [
    , .{
        base,
        key,
        heuristics_version,
        Scene.layout_version,
        args.frames,
        args.warmup,
        samples,
    });

    // Emit contiguous runs of equal height, skipping the default.
    var first = true;
    var t: usize = 0;
    while (t < Scene.max_tiles) {
        const h = heights[t];
        var end = t;
        while (end + 1 < Scene.max_tiles and heights[end + 1] == h) end += 1;
        const relevant = blk: {
            if (@abs(h - 0.10) < 0.001) break :blk false;
            var any = false;
            for (t..end + 1) |i| {
                if (stats[i].usage > 0 or stats[i].sprite) any = true;
            }
            break :blk any;
        };
        if (relevant) {
            if (!first) try jw.print(",", .{});
            first = false;
            try jw.print("\n    {{\"from\": {d}, \"to\": {d}, \"height\": {d:.2}}}", .{ t, end, h });
        }
        t = end + 1;
    }
    try jw.print("\n  ],\n  \"entities\": [", .{});

    // Recurring meta-sprites, for a future renderer that attaches persistent
    // objects to them. Signature = the sorted tiles the cluster used.
    var efirst = true;
    var emitted: usize = 0;
    for (entities) |e| {
        if (e.frames_seen < samples / 20) continue;
        if (!efirst) try jw.print(",", .{});
        efirst = false;
        try jw.print(
            "\n    {{\"tiles\": [",
            .{},
        );
        for (e.signature[0..e.signature_len], 0..) |sig_tile, i| {
            if (i > 0) try jw.print(", ", .{});
            try jw.print("{d}", .{sig_tile});
        }
        try jw.print(
            "], \"sprites\": {d}, \"width\": {d}, \"height\": {d}, \"framesSeen\": {d}}}",
            .{ e.sprite_count, e.width, e.height, e.frames_seen },
        );
        emitted += 1;
        if (emitted >= 16) break;
    }
    try jw.print("\n  ]\n}}\n", .{});

    var file = try platform.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(aw.written());
}

fn parseArgs(it: *std.process.Args.Iterator) !Args {
    _ = it.next();
    const rom = it.next() orelse {
        std.debug.print("Usage: mine-profile <rom> [--frames N] [--warmup N] [--out PATH] [--stats]\n", .{});
        return error.InvalidArgs;
    };
    var a = Args{ .rom_path = rom };
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--frames")) {
            a.frames = try std.fmt.parseInt(usize, it.next() orelse return error.InvalidArgs, 10);
        } else if (std.mem.eql(u8, arg, "--warmup")) {
            a.warmup = try std.fmt.parseInt(usize, it.next() orelse return error.InvalidArgs, 10);
        } else if (std.mem.eql(u8, arg, "--out")) {
            a.out_path = it.next() orelse return error.InvalidArgs;
        } else if (std.mem.eql(u8, arg, "--stats")) {
            a.show_stats = true;
        } else if (std.mem.eql(u8, arg, "--force")) {
            a.force = true;
        } else {
            return error.InvalidArgs;
        }
    }
    return a;
}
