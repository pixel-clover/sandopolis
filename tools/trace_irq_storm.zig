const std = @import("std");
const platform = @import("sandopolis_testing").platform;
const testing = @import("sandopolis_testing");

// Per-ROM timing/regression diagnostic with two modes.
//
// Default (progress) mode reports:
//   * distinct framebuffers over N frames  -> is the game making progress?
//   * unique PCs in a single traced frame  -> is the CPU stuck bouncing
//     through the interrupt vector (a storm collapses to a handful of PCs)?
//
// --derail mode locates the exact frame + instruction where a ROM derails:
// it runs frame by frame with instruction tracing and reports the first jump
// from real code into the live 68000 vector table (ppc >= 0x100, pc_after <
// 0x100 -- 0x000..0x0FF is never valid code; note demos legitimately place
// routines in the unused-vector/header region 0x100..0x3FF), with a trace
// tail and a histogram of exceptions seen before the derail.
//
// Usage: trace-irq-storm <rom> [warmup] [frames] [--derail] [--dump N]

fn checksum(buf: []const u32) u64 {
    var h: u64 = 1469598103934665603;
    for (buf) |px| {
        h = (h ^ px) *% 1099511628211;
    }
    return h;
}

const Args = struct {
    rom_path: []const u8,
    warmup: usize = 120,
    frames: usize = 240,
    derail: bool = false,
    dump: usize = 40,
    pal: bool = false,
};

fn parseArgs(it: *std.process.Args.Iterator) !Args {
    _ = it.next(); // exe
    const rom_path = it.next() orelse {
        std.debug.print("Usage: trace-irq-storm <rom-path> [warmup] [frames] [--derail] [--dump N]\n", .{});
        return error.InvalidArgs;
    };
    var args = Args{ .rom_path = rom_path };
    var positional: usize = 0;
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "--derail")) {
            args.derail = true;
        } else if (std.mem.eql(u8, a, "--pal")) {
            args.pal = true;
        } else if (std.mem.eql(u8, a, "--dump")) {
            const n = it.next() orelse return error.InvalidArgs;
            args.dump = try std.fmt.parseInt(usize, n, 10);
        } else {
            const value = try std.fmt.parseInt(usize, a, 10);
            switch (positional) {
                0 => args.warmup = value,
                1 => args.frames = value,
                else => return error.InvalidArgs,
            }
            positional += 1;
        }
    }
    // In derail mode the "frames" positional is the scan limit; give it a
    // larger default since derails often appear only after thousands of frames.
    if (args.derail and positional < 2) args.frames = 5000;
    return args;
}

pub fn main(init: std.process.Init) !void {
    platform.init(init);
    var gpa_state = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    var arg_it = try platform.argsWithAllocator(allocator);
    defer arg_it.deinit();
    const args = try parseArgs(&arg_it);

    var emulator = try testing.Emulator.init(allocator, args.rom_path);
    defer emulator.deinit(allocator);
    if (args.pal) {
        emulator.setPalMode(true);
        emulator.reset();
    }
    var output = testing.AudioOutput.init();

    if (args.derail) {
        try runDerail(allocator, &emulator, &output, args);
    } else {
        try runProgress(allocator, &emulator, &output, args);
    }
}

fn runProgress(allocator: std.mem.Allocator, emulator: *testing.Emulator, output: *testing.AudioOutput, args: Args) !void {
    for (0..args.warmup) |_| {
        emulator.runFrame();
        try emulator.discardPendingAudioWithOutput(output);
    }

    // Progress signal: distinct framebuffer checksums across `frames` frames.
    var seen = std.AutoHashMap(u64, void).init(allocator);
    defer seen.deinit();
    var total_instrs: u64 = 0;
    for (0..args.frames) |_| {
        const counters = emulator.runFrameProfiled();
        total_instrs += counters.m68k_instructions;
        try emulator.discardPendingAudioWithOutput(output);
        try seen.put(checksum(emulator.framebuffer()), {});
    }

    // Storm signature: unique instruction PCs within a single frame.
    emulator.clearM68kInstructionTrace();
    emulator.setM68kInstructionTraceEnabled(true);
    _ = emulator.runFrameProfiled();
    emulator.setM68kInstructionTraceEnabled(false);
    var unique_pcs = std.AutoHashMap(u32, void).init(allocator);
    defer unique_pcs.deinit();
    const entries = emulator.m68kInstructionTraceEntries();
    for (entries) |e| try unique_pcs.put(e.ppc, {});

    var out_buf: [1024]u8 = undefined;
    var w = platform.stdout().writer(&out_buf);
    const stdout = &w.interface;
    try stdout.print(
        "rom={s}\n  distinct_frames={d}/{d}  avg_m68k_instrs/frame={d}\n  trace_entries={d} unique_pcs={d}  pc=0x{X:0>8} sr=0x{X:0>4}\n",
        .{
            std.fs.path.basename(args.rom_path),
            seen.count(),
            args.frames,
            total_instrs / args.frames,
            entries.len,
            unique_pcs.count(),
            emulator.cpuPc(),
            emulator.cpuSr(),
        },
    );
    try stdout.flush();
}

fn runDerail(allocator: std.mem.Allocator, emulator: *testing.Emulator, output: *testing.AudioOutput, args: Args) !void {
    _ = allocator;
    emulator.setM68kInstructionTraceEnabled(true);

    var out_buf: [8192]u8 = undefined;
    var w = platform.stdout().writer(&out_buf);
    const stdout = &w.interface;

    // Tally which exception vectors fire before the derail (2=bus,3=addr,4=illegal,
    // 5=div0,6=chk,7=trapv,8=priv; 25-31=autovector IRQ; 32+=TRAP).
    var exc_hist = [_]u64{0} ** 64;
    var last_nonirq_exc_ctx: ?struct { frame: usize, ppc: u32, ir: u16, ex: i32 } = null;

    var frame: usize = 0;
    while (frame < args.frames) : (frame += 1) {
        emulator.clearM68kInstructionTrace();
        emulator.runFrame();
        try emulator.discardPendingAudioWithOutput(output);

        const entries = emulator.m68kInstructionTraceEntries();
        for (entries, 0..) |e, i| {
            const ex = e.exception_thrown;
            if (ex > 0 and ex < 64) {
                exc_hist[@intCast(ex)] += 1;
                // Track the last non-interrupt exception before derail (ex<24).
                if (ex < 24 and e.ppc >= 0x400) {
                    last_nonirq_exc_ctx = .{ .frame = frame, .ppc = e.ppc, .ir = e.ir, .ex = ex };
                }
            }
            // The culprit: a jump from real code into the live vector table.
            if (e.ppc >= 0x100 and e.pc_after < 0x100) {
                try stdout.print("=== exception histogram before derail ===\n", .{});
                for (exc_hist, 0..) |cnt, v| {
                    if (cnt > 0) try stdout.print("  vector {d}: {d}\n", .{ v, cnt });
                }
                if (last_nonirq_exc_ctx) |c| {
                    try stdout.print("  last non-IRQ exception: frame {d} ppc=0x{X:0>6} ir=0x{X:0>4} ex={d}\n", .{ c.frame, c.ppc, c.ir, c.ex });
                } else {
                    try stdout.print("  (no non-IRQ exception seen before derail)\n", .{});
                }
                try stdout.print("\nDERAIL: frame {d}, trace idx {d}: ppc=0x{X:0>6} ir=0x{X:0>4} sr=0x{X:0>4} -> pc_after=0x{X:0>8} ex={d}\n\n", .{ frame, i, e.ppc, e.ir, e.sr, e.pc_after, e.exception_thrown });
                const start = if (i >= args.dump) i - args.dump else 0;
                for (entries[start .. i + 1], start..) |t, idx| {
                    try stdout.print("{d:0>5} cyc={d} ppc=0x{X:0>6} ir=0x{X:0>4} sr=0x{X:0>4} pc_after=0x{X:0>8} ex={d}\n", .{ idx, t.cycles, t.ppc, t.ir, t.sr, t.pc_after, t.exception_thrown });
                }
                try stdout.flush();
                return;
            }
        }
    }
    try stdout.print("No derail in {d} frames. final pc=0x{X:0>8}\n", .{ args.frames, emulator.cpuPc() });
    try stdout.flush();
}
