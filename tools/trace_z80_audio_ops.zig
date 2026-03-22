const std = @import("std");
const testing = @import("sandopolis_testing");

const Emulator = testing.Emulator;
const Z80AudioOpTraceEntry = testing.Z80AudioOpTraceEntry;

const default_frames: usize = 120;

const Config = struct {
    rom_path: []const u8,
    out_path: []const u8,
    frames: usize = default_frames,
    skip_frames: usize = 0,
};

const StreamSummary = struct {
    events: usize = 0,
    stream_hash: u64 = 0xcbf29ce484222325,
    dropped: u32 = 0,
};

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    const config = try parseArgs(allocator);
    defer allocator.free(config.rom_path);
    defer allocator.free(config.out_path);

    const summary = try traceZ80AudioOps(allocator, config);

    std.debug.print(
        "sandopolis: traced {d} Z80 audio ops to {s} over {d} frames after skipping {d}; dropped={d}; stream_hash=0x{X:0>16}\n",
        .{
            summary.events,
            config.out_path,
            config.frames,
            config.skip_frames,
            summary.dropped,
            summary.stream_hash,
        },
    );
}

fn parseArgs(allocator: std.mem.Allocator) !Config {
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.next();
    const rom_arg = args.next() orelse return usageError();
    const out_arg = args.next() orelse return usageError();
    const maybe_frames_arg = args.next();

    var frames = default_frames;
    var skip_frames: usize = 0;

    if (maybe_frames_arg) |arg| {
        if (!std.mem.startsWith(u8, arg, "--")) {
            frames = try std.fmt.parseInt(usize, arg, 10);
        } else if (std.mem.eql(u8, arg, "--skip")) {
            const skip_arg = args.next() orelse return usageError();
            skip_frames = try std.fmt.parseInt(usize, skip_arg, 10);
        } else {
            return usageError();
        }
    }

    while (args.next()) |flag| {
        if (std.mem.eql(u8, flag, "--skip")) {
            const skip_arg = args.next() orelse return usageError();
            skip_frames = try std.fmt.parseInt(usize, skip_arg, 10);
        } else {
            return usageError();
        }
    }

    return .{
        .rom_path = try allocator.dupe(u8, rom_arg),
        .out_path = try allocator.dupe(u8, out_arg),
        .frames = frames,
        .skip_frames = skip_frames,
    };
}

fn usageError() error{InvalidUsage} {
    std.debug.print(
        "Usage: zig build trace-z80-audio-ops -- <rom-path> <out-path> [frames] [--skip frames]\n",
        .{},
    );
    return error.InvalidUsage;
}

fn traceZ80AudioOps(allocator: std.mem.Allocator, config: Config) !StreamSummary {
    var emulator = try Emulator.init(allocator, config.rom_path);
    defer emulator.deinit(allocator);

    var file = try std.fs.cwd().createFile(config.out_path, .{ .truncate = true });
    defer file.close();
    var buffer: [4096]u8 = undefined;
    var file_writer = file.writer(&buffer);
    const writer = &file_writer.interface;

    try writer.print("frame\tmaster_offset\tsequence\tpc\topcode\taddr\tkind\tvalue\n", .{});

    emulator.setZ80AudioOpTraceEnabled(false);
    emulator.runFramesDiscardingAudio(config.skip_frames);

    emulator.setZ80AudioOpTraceEnabled(true);
    emulator.clearZ80AudioOpTrace();

    var summary = StreamSummary{};
    var events: [512]Z80AudioOpTraceEntry = undefined;

    for (0..config.frames) |frame_index| {
        emulator.runFrame();
        emulator.discardPendingAudio();

        while (true) {
            const count = emulator.takeZ80AudioOpTrace(events[0..]);
            if (count == 0) break;

            for (events[0..count]) |event| {
                try writer.print(
                    "{d}\t{d}\t{d}\t0x{X:0>4}\t0x{X:0>2}\t0x{X:0>4}\t{s}\t0x{X:0>2}\n",
                    .{
                        frame_index,
                        event.master_offset,
                        event.sequence,
                        event.pc,
                        event.opcode,
                        event.addr,
                        kindName(event.kind),
                        event.value,
                    },
                );
                summary.events += 1;
                summary.stream_hash = hashTraceEntry(summary.stream_hash, frame_index, event);
            }
        }
    }

    summary.dropped = emulator.takeZ80AudioOpTraceDroppedCount();
    try writer.flush();
    return summary;
}

fn kindName(kind: u8) []const u8 {
    return switch (kind) {
        0 => "ym-addr",
        1 => "ym-data",
        2 => "psg",
        else => "unknown",
    };
}

fn hashTraceEntry(seed: u64, frame_index: usize, event: Z80AudioOpTraceEntry) u64 {
    var hash = seed;
    inline for ([_]u64{
        @intCast(frame_index),
        event.master_offset,
        event.sequence,
        event.pc,
        event.opcode,
        event.addr,
        event.kind,
        event.value,
    }) |value| {
        hash ^= value;
        hash *%= 0x100000001B3;
    }
    return hash;
}
