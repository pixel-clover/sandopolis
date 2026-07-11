const std = @import("std");
const testing = @import("sandopolis_testing");

// Locate the exact frame + instruction where a ROM derails: run frame by
// frame with instruction tracing, and after each frame scan that frame's
// trace for the first sign of a crash -- a jump into the vector table
// (pc_after < 0x400) or a group-0/illegal exception (ex in {2,3,4}).

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();
    const rom_path = args.next() orelse return error.InvalidArgs;
    const max_frames: usize = if (args.next()) |a| try std.fmt.parseInt(usize, a, 10) else 2000;
    const dump: usize = if (args.next()) |a| try std.fmt.parseInt(usize, a, 10) else 40;

    var emulator = try testing.Emulator.init(allocator, rom_path);
    defer emulator.deinit(allocator);
    var output = testing.AudioOutput.init();

    emulator.setM68kInstructionTraceEnabled(true);

    var out_buf: [8192]u8 = undefined;
    var w = std.fs.File.stdout().writer(&out_buf);
    const stdout = &w.interface;

    // Tally which exception vectors fire before the derail (2=bus,3=addr,4=illegal,
    // 5=div0,6=chk,7=trapv,8=priv; 25-31=autovector IRQ; 32+=TRAP).
    var exc_hist = [_]u64{0} ** 64;
    var last_nonirq_exc_ctx: ?struct { frame: usize, ppc: u32, ir: u16, ex: i32 } = null;

    var frame: usize = 0;
    while (frame < max_frames) : (frame += 1) {
        emulator.clearM68kInstructionTrace();
        emulator.runFrame();
        try emulator.discardPendingAudioWithOutput(&output);

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
            // The culprit: a jump from valid code into the vector region.
            if (e.ppc >= 0x400 and e.pc_after < 0x400) {
                try stdout.print("=== exception histogram before derail ===\n", .{});
                for (exc_hist, 0..) |cnt, v| {
                    if (cnt > 0) try stdout.print("  vector {d}: {d}\n", .{ v, cnt });
                }
                if (last_nonirq_exc_ctx) |c| {
                    try stdout.print("  last non-IRQ exception: frame {d} ppc=0x{X:0>6} ir=0x{X:0>4} ex={d}\n", .{ c.frame, c.ppc, c.ir, c.ex });
                } else {
                    try stdout.print("  (no non-IRQ exception seen before derail)\n", .{});
                }
                try stdout.print("\n", .{});
                try stdout.print("DERAIL: frame {d}, trace idx {d}: ppc=0x{X:0>6} ir=0x{X:0>4} sr=0x{X:0>4} -> pc_after=0x{X:0>8} ex={d}\n\n", .{ frame, i, e.ppc, e.ir, e.sr, e.pc_after, e.exception_thrown });
                const start = if (i >= dump) i - dump else 0;
                for (entries[start .. i + 1], start..) |t, idx| {
                    try stdout.print("{d:0>5} cyc={d} ppc=0x{X:0>6} ir=0x{X:0>4} sr=0x{X:0>4} pc_after=0x{X:0>8} ex={d}\n", .{ idx, t.cycles, t.ppc, t.ir, t.sr, t.pc_after, t.exception_thrown });
                }
                try stdout.flush();
                return;
            }
        }
    }
    try stdout.print("No derail in {d} frames. final pc=0x{X:0>8}\n", .{ max_frames, emulator.cpuPc() });
    try stdout.flush();
}
