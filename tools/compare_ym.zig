const std = @import("std");
const testing = @import("sandopolis_testing");

const c = @cImport({
    @cInclude("ym3438.h");
});

const ScheduledWrite = struct {
    clock: usize,
    port: u1,
    reg: u8,
    value: u8,
};

const SamplePair = struct {
    left: i16,
    right: i16,
};

const FirstMismatch = struct {
    clock: usize,
    sandopolis: SamplePair,
    nuked: SamplePair,
};

const Metrics = struct {
    compared_clocks: usize = 0,
    mismatched_clocks: usize = 0,
    max_abs_left: u16 = 0,
    max_abs_right: u16 = 0,
    sum_sq_left: f64 = 0,
    sum_sq_right: f64 = 0,
    first_mismatch: ?FirstMismatch = null,

    fn observe(self: *Metrics, clock_idx: usize, sandopolis: SamplePair, nuked: SamplePair) void {
        const left_diff = signedDiff(sandopolis.left, nuked.left);
        const right_diff = signedDiff(sandopolis.right, nuked.right);
        const left_abs = absI32(left_diff);
        const right_abs = absI32(right_diff);

        self.compared_clocks += 1;
        self.max_abs_left = @max(self.max_abs_left, @as(u16, @intCast(left_abs)));
        self.max_abs_right = @max(self.max_abs_right, @as(u16, @intCast(right_abs)));
        self.sum_sq_left += @as(f64, @floatFromInt(left_diff * left_diff));
        self.sum_sq_right += @as(f64, @floatFromInt(right_diff * right_diff));

        if (left_diff != 0 or right_diff != 0) {
            self.mismatched_clocks += 1;
            if (self.first_mismatch == null) {
                self.first_mismatch = .{
                    .clock = clock_idx,
                    .sandopolis = sandopolis,
                    .nuked = nuked,
                };
            }
        }
    }

    fn rmsLeft(self: Metrics) f64 {
        if (self.compared_clocks == 0) return 0;
        return @sqrt(self.sum_sq_left / @as(f64, @floatFromInt(self.compared_clocks)));
    }

    fn rmsRight(self: Metrics) f64 {
        if (self.compared_clocks == 0) return 0;
        return @sqrt(self.sum_sq_right / @as(f64, @floatFromInt(self.compared_clocks)));
    }
};

const Scenario = struct {
    name: []const u8,
    description: []const u8,
    total_clocks: usize,
    writes: []const ScheduledWrite,
};

fn scheduled(clock: usize, port: u1, reg: u8, value: u8) ScheduledWrite {
    return .{
        .clock = clock,
        .port = port,
        .reg = reg,
        .value = value,
    };
}

const tone_setup_writes = [_]ScheduledWrite{
    scheduled(0, 0, 0xA4, 0x22),
    scheduled(1, 0, 0xA0, 0x80),
    scheduled(2, 0, 0xB0, 0x07),
    scheduled(3, 0, 0xB4, 0xC0),
    scheduled(4, 0, 0x30, 0x01),
    scheduled(5, 0, 0x40, 0x18),
    scheduled(6, 0, 0x50, 0x1F),
    scheduled(7, 0, 0x60, 0x0C),
    scheduled(8, 0, 0x70, 0x08),
    scheduled(9, 0, 0x80, 0x24),
    scheduled(10, 0, 0x38, 0x01),
    scheduled(11, 0, 0x48, 0x18),
    scheduled(12, 0, 0x58, 0x1F),
    scheduled(13, 0, 0x68, 0x0C),
    scheduled(14, 0, 0x78, 0x08),
    scheduled(15, 0, 0x88, 0x24),
    scheduled(16, 0, 0x34, 0x01),
    scheduled(17, 0, 0x44, 0x18),
    scheduled(18, 0, 0x54, 0x1F),
    scheduled(19, 0, 0x64, 0x0C),
    scheduled(20, 0, 0x74, 0x08),
    scheduled(21, 0, 0x84, 0x24),
    scheduled(22, 0, 0x3C, 0x01),
    scheduled(23, 0, 0x4C, 0x00),
    scheduled(24, 0, 0x5C, 0x1F),
    scheduled(25, 0, 0x6C, 0x0C),
    scheduled(26, 0, 0x7C, 0x08),
    scheduled(27, 0, 0x8C, 0x24),
    scheduled(28, 0, 0x28, 0xF0),
};

const basic_tone_writes = tone_setup_writes ++ [_]ScheduledWrite{
    scheduled(1200, 0, 0x28, 0x00),
};

const pan_swap_writes = tone_setup_writes ++ [_]ScheduledWrite{
    scheduled(384, 0, 0xB4, 0x80),
    scheduled(768, 0, 0xB4, 0x40),
    scheduled(1152, 0, 0xB4, 0xC0),
    scheduled(1408, 0, 0x28, 0x00),
};

const dac_step_writes = [_]ScheduledWrite{
    scheduled(0, 0, 0x2B, 0x80),
    scheduled(32, 0, 0x2A, 0x00),
    scheduled(96, 0, 0x2A, 0x10),
    scheduled(160, 0, 0x2A, 0x40),
    scheduled(224, 0, 0x2A, 0x80),
    scheduled(288, 0, 0x2A, 0xC0),
    scheduled(352, 0, 0x2A, 0xFF),
    scheduled(416, 0, 0x2A, 0x7F),
    scheduled(480, 0, 0x2B, 0x00),
};

const scenarios = [_]Scenario{
    .{
        .name = "basic-tone",
        .description = "Single channel tone with key on/off and operator routing",
        .total_clocks = 2048,
        .writes = basic_tone_writes[0..],
    },
    .{
        .name = "pan-swap",
        .description = "Tone with mid-stream pan changes across both output pins",
        .total_clocks = 1792,
        .writes = pan_swap_writes[0..],
    },
    .{
        .name = "dac-step",
        .description = "DAC enable/data stepping without the channel mixer path",
        .total_clocks = 640,
        .writes = dac_step_writes[0..],
    },
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    const args = try std.process.argsAlloc(allocator);
    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stdout = &stdout_writer.interface;
    const stderr = &stderr_writer.interface;

    if (args.len <= 1) {
        try runAll(stdout);
        try stdout.flush();
        return;
    }

    if (std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h")) {
        try printUsage(stdout);
        try stdout.flush();
        return;
    }

    if (args.len == 2 and std.mem.eql(u8, args[1], "all")) {
        try runAll(stdout);
        try stdout.flush();
        return;
    }

    for (args[1..]) |name| {
        const scenario = findScenario(name) orelse {
            try stderr.print("Unknown scenario: {s}\n\n", .{name});
            try printUsage(stderr);
            try stderr.flush();
            return error.InvalidScenario;
        };
        try runOne(stdout, scenario);
    }
    try stdout.flush();
}

fn runAll(writer: anytype) !void {
    for (scenarios, 0..) |scenario, index| {
        if (index != 0) try writer.writeByte('\n');
        try runOne(writer, scenario);
    }
}

fn runOne(writer: anytype, scenario: Scenario) !void {
    const metrics = runScenario(scenario);

    try writer.print(
        "{s}: clocks={d} mismatches={d} max_abs=({d},{d}) rms=({d:.3},{d:.3})\n",
        .{
            scenario.name,
            metrics.compared_clocks,
            metrics.mismatched_clocks,
            metrics.max_abs_left,
            metrics.max_abs_right,
            metrics.rmsLeft(),
            metrics.rmsRight(),
        },
    );
    try writer.print("  {s}\n", .{scenario.description});

    if (metrics.first_mismatch) |mismatch| {
        try writer.print(
            "  first mismatch @ clock {d}: sandopolis=({d},{d}) nuked=({d},{d})\n",
            .{
                mismatch.clock,
                mismatch.sandopolis.left,
                mismatch.sandopolis.right,
                mismatch.nuked.left,
                mismatch.nuked.right,
            },
        );
    } else {
        try writer.writeAll("  exact match for this scenario\n");
    }
}

fn runScenario(scenario: Scenario) Metrics {
    var sandopolis = testing.Ym2612Synth{};
    sandopolis.resetChipState();

    var nuked: c.ym3438_t = undefined;
    c.OPN2_SetChipType(c.ym3438_mode_ym2612);
    c.OPN2_Reset(&nuked);

    var metrics = Metrics{};
    var next_write_index: usize = 0;
    var nuked_buffer: [2]c.Bit16s = .{ 0, 0 };

    for (0..scenario.total_clocks) |clock_idx| {
        while (next_write_index < scenario.writes.len and scenario.writes[next_write_index].clock == clock_idx) : (next_write_index += 1) {
            const write = scenario.writes[next_write_index];
            sandopolis.applyWrite(testing.ymWriteEvent(write.port, write.reg, write.value));

            const address_port: c.Bit32u = @as(c.Bit32u, write.port) * 2;
            c.OPN2_Write(&nuked, address_port, write.reg);
            c.OPN2_Write(&nuked, address_port + 1, write.value);
        }

        const sandopolis_pins = sandopolis.clockOneInternal();
        c.OPN2_Clock(&nuked, &nuked_buffer[0]);

        metrics.observe(
            clock_idx,
            .{
                .left = sandopolis_pins[0],
                .right = sandopolis_pins[1],
            },
            .{
                .left = @intCast(nuked_buffer[0]),
                .right = @intCast(nuked_buffer[1]),
            },
        );
    }

    std.debug.assert(next_write_index == scenario.writes.len);
    return metrics;
}

fn findScenario(name: []const u8) ?Scenario {
    for (scenarios) |scenario| {
        if (std.mem.eql(u8, scenario.name, name)) return scenario;
    }
    return null;
}

fn printUsage(writer: anytype) !void {
    try writer.writeAll(
        "Usage: zig build compare-ym -- [all|scenario...]\n" ++
            "Compares Sandopolis raw YM2612 pin output against external/Nuked-OPN2\n" ++
            "for deterministic decoded register-write scenarios.\n\n",
    );
    try writer.writeAll("Available scenarios:\n");
    for (scenarios) |scenario| {
        try writer.print("  {s}: {s}\n", .{ scenario.name, scenario.description });
    }
}

fn signedDiff(a: i16, b: i16) i32 {
    return @as(i32, a) - @as(i32, b);
}

fn absI32(value: i32) u32 {
    return @intCast(if (value < 0) -value else value);
}
