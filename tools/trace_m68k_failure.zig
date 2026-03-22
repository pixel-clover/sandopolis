const std = @import("std");
const testing = @import("sandopolis_testing");
const AudioOutput = testing.AudioOutput;
const TraceEntry = testing.M68kInstructionTraceEntry;

const default_frames: usize = 60;
const default_limit: usize = 128;

const Config = struct {
    rom_path: []const u8,
    frames: usize = default_frames,
    skip_frames: usize = 0,
    limit: usize = default_limit,
};

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    const config = try parseArgs(allocator);
    defer allocator.free(config.rom_path);

    var emulator = try testing.Emulator.init(allocator, config.rom_path);
    defer emulator.deinit(allocator);

    var output = AudioOutput.init();
    for (0..config.skip_frames) |_| {
        emulator.runFrame();
        try emulator.discardPendingAudioWithOutput(&output);
    }

    emulator.clearM68kInstructionTrace();
    emulator.setM68kInstructionTraceStopOnFault(true);
    emulator.setM68kInstructionTraceEnabled(true);
    defer {
        emulator.setM68kInstructionTraceEnabled(false);
        emulator.setM68kInstructionTraceStopOnFault(false);
    }

    var failure_detected = false;
    for (0..config.frames) |_| {
        emulator.runFrame();
        try emulator.discardPendingAudioWithOutput(&output);
        if (emulator.cpuPc() == 0xFFFF_FFFF or emulator.cpuExceptionThrown() != 0) {
            failure_detected = true;
            break;
        }
    }

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    const entries = emulator.m68kInstructionTraceEntries();
    const dropped = emulator.m68kInstructionTraceDroppedCount();
    try stdout.print(
        "trace: rom={s} frames={d} skip={d} failure={s} entries={d} dropped={d} cpu_pc=0x{X:0>8} ir=0x{X:0>4} ex={d} z80_pc=0x{X:0>4}\n",
        .{
            config.rom_path,
            config.frames,
            config.skip_frames,
            if (failure_detected) "yes" else "no",
            entries.len,
            dropped,
            emulator.cpuPc(),
            emulator.cpuInstructionRegister(),
            emulator.cpuExceptionThrown(),
            emulator.z80ProgramCounter(),
        },
    );

    const print_count = @min(entries.len, config.limit);
    const start = entries.len - print_count;
    for (entries[start..], start..) |entry, index| {
        try printEntry(stdout, index, entry);
    }
    try stdout.flush();
}

fn parseArgs(allocator: std.mem.Allocator) !Config {
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.next();
    const rom_arg = args.next() orelse return usageError();
    const maybe_frames_arg = args.next();
    var frames = default_frames;
    var skip_frames: usize = 0;
    var limit: usize = default_limit;

    if (maybe_frames_arg) |arg| {
        if (!std.mem.startsWith(u8, arg, "--")) {
            frames = try std.fmt.parseInt(usize, arg, 10);
        } else if (std.mem.eql(u8, arg, "--skip")) {
            const skip_arg = args.next() orelse return usageError();
            skip_frames = try std.fmt.parseInt(usize, skip_arg, 10);
        } else if (std.mem.eql(u8, arg, "--limit")) {
            const limit_arg = args.next() orelse return usageError();
            limit = try std.fmt.parseInt(usize, limit_arg, 10);
        } else {
            return usageError();
        }
    }

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--skip")) {
            const skip_arg = args.next() orelse return usageError();
            skip_frames = try std.fmt.parseInt(usize, skip_arg, 10);
        } else if (std.mem.eql(u8, arg, "--limit")) {
            const limit_arg = args.next() orelse return usageError();
            limit = try std.fmt.parseInt(usize, limit_arg, 10);
        } else {
            return usageError();
        }
    }

    return .{
        .rom_path = try allocator.dupe(u8, rom_arg),
        .frames = frames,
        .skip_frames = skip_frames,
        .limit = limit,
    };
}

fn usageError() error{InvalidArgs} {
    std.debug.print(
        "Usage: zig build trace-m68k-failure -- <rom-path> [frames] [--skip frames] [--limit entries]\n",
        .{},
    );
    return error.InvalidArgs;
}

fn printEntry(writer: anytype, index: usize, entry: TraceEntry) !void {
    try writer.print(
        "{d:0>5} cycles={d:0>10} ppc=0x{X:0>8} ir=0x{X:0>4} sr=0x{X:0>4} pc_after=0x{X:0>8} ex={d} halt={d}\n",
        .{
            index,
            entry.cycles,
            entry.ppc,
            entry.ir,
            entry.sr,
            entry.pc_after,
            entry.exception_thrown,
            @intFromBool(entry.halted),
        },
    );
}
