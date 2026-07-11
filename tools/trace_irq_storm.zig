const std = @import("std");
const testing = @import("sandopolis_testing");

// Diagnostic harness for the Rocket 68 v0.2.2 interrupt-storm regression.
//
// Two signals are reported per ROM:
//   * distinct framebuffers over N frames  -> is the game making progress?
//   * unique PCs in a single traced frame  -> is the CPU stuck bouncing
//     through the interrupt vector (a storm collapses to a handful of PCs)?

fn checksum(buf: []const u32) u64 {
    var h: u64 = 1469598103934665603;
    for (buf) |px| {
        h = (h ^ px) *% 1099511628211;
    }
    return h;
}

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();
    const rom_path = args.next() orelse {
        std.debug.print("Usage: trace-irq-storm <rom-path> [warmup] [frames]\n", .{});
        return error.InvalidArgs;
    };
    const warmup: usize = if (args.next()) |a| try std.fmt.parseInt(usize, a, 10) else 120;
    const frames: usize = if (args.next()) |a| try std.fmt.parseInt(usize, a, 10) else 240;

    var emulator = try testing.Emulator.init(allocator, rom_path);
    defer emulator.deinit(allocator);

    var output = testing.AudioOutput.init();
    for (0..warmup) |_| {
        emulator.runFrame();
        try emulator.discardPendingAudioWithOutput(&output);
    }

    // Progress signal: distinct framebuffer checksums across `frames` frames.
    var seen = std.AutoHashMap(u64, void).init(allocator);
    defer seen.deinit();
    var total_instrs: u64 = 0;
    for (0..frames) |_| {
        const counters = emulator.runFrameProfiled();
        total_instrs += counters.m68k_instructions;
        try emulator.discardPendingAudioWithOutput(&output);
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
    var w = std.fs.File.stdout().writer(&out_buf);
    const stdout = &w.interface;
    try stdout.print(
        "rom={s}\n  distinct_frames={d}/{d}  avg_m68k_instrs/frame={d}\n  trace_entries={d} unique_pcs={d}  pc=0x{X:0>8} sr=0x{X:0>4}\n",
        .{
            std.fs.path.basename(rom_path),
            seen.count(),
            frames,
            total_instrs / frames,
            entries.len,
            unique_pcs.count(),
            emulator.cpuPc(),
            emulator.cpuSr(),
        },
    );
    try stdout.flush();
}
