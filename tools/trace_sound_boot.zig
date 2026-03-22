const std = @import("std");
const testing = @import("sandopolis_testing");
const AudioOutput = testing.AudioOutput;
const TraceEntry = testing.M68kSoundWriteTraceEntry;
const TraceKind = testing.M68kSoundWriteTraceKind;
const TraceOutcome = testing.M68kSoundWriteTraceOutcome;

const default_frames: usize = 120;
const default_limit: usize = 256;

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

    emulator.clearM68kSoundWriteTrace();
    emulator.setM68kSoundWriteTraceEnabled(true);
    defer emulator.setM68kSoundWriteTraceEnabled(false);

    for (0..config.frames) |_| {
        emulator.runFrame();
        try emulator.discardPendingAudioWithOutput(&output);
    }

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    const entries = emulator.m68kSoundWriteTraceEntries();
    const dropped = emulator.m68kSoundWriteTraceDroppedCount();
    try stdout.print(
        "trace: rom={s} frames={d} skip={d} entries={d} dropped={d} cpu_pc=0x{X:0>8} z80_pc=0x{X:0>4} busack=0x{X:0>4} reset=0x{X:0>4}\n",
        .{
            config.rom_path,
            config.frames,
            config.skip_frames,
            entries.len,
            dropped,
            emulator.cpuPc(),
            emulator.z80ProgramCounter(),
            emulator.z80BusAckWord(),
            emulator.z80ResetControlWord(),
        },
    );

    const print_count = @min(entries.len, config.limit);
    for (entries[0..print_count], 0..) |entry, index| {
        try printEntry(stdout, index, entry);
    }

    if (print_count < entries.len) {
        try stdout.print("... omitted {d} additional entries\n", .{entries.len - print_count});
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
        "Usage: zig build trace-sound-boot -- <rom-path> [frames] [--skip frames] [--limit entries]\n",
        .{},
    );
    return error.InvalidArgs;
}

fn printEntry(writer: anytype, index: usize, entry: TraceEntry) !void {
    try writer.print(
        "{d:0>5} +{d:0>8} op=0x{X:0>4} write{d} 0x{X:0>6}=0x{X:0>4} {s} {s} busack=0x{X:0>4} reset=0x{X:0>4}\n",
        .{
            index,
            entry.access_master_offset,
            entry.opcode,
            entry.size_bytes,
            entry.address,
            entry.value,
            kindLabel(entry.kind),
            outcomeLabel(entry.outcome),
            entry.busack,
            entry.reset,
        },
    );
}

fn kindLabel(kind: TraceKind) []const u8 {
    return switch (kind) {
        .z80_window => "z80-window",
        .bus_request => "busreq",
        .reset => "reset",
    };
}

fn outcomeLabel(outcome: TraceOutcome) []const u8 {
    return switch (outcome) {
        .applied => "applied",
        .blocked_no_bus => "blocked-no-bus",
        .ignored_host_misc => "ignored-host-misc",
        .ignored_odd_control_byte => "ignored-odd-control-byte",
    };
}
