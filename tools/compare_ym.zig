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

const StatusReadKind = enum {
    status,
    irq,
    test_pin,
};

const ScheduledStatusRead = struct {
    clock: usize,
    kind: StatusReadKind,
    port: u2 = 0,
};

const StatusScenario = struct {
    name: []const u8,
    description: []const u8,
    total_internal_clocks: usize,
    writes: []const ScheduledWrite,
    reads: []const ScheduledStatusRead,
    read_mode: bool = false,
};

const StatusFirstMismatch = struct {
    clock: usize,
    kind: StatusReadKind,
    port: u2,
    sandopolis: u8,
    nuked: u8,
};

const StatusMetrics = struct {
    compared_reads: usize = 0,
    mismatched_reads: usize = 0,
    first_mismatch: ?StatusFirstMismatch = null,

    fn observe(self: *StatusMetrics, read: ScheduledStatusRead, sandopolis: u8, nuked: u8) void {
        self.compared_reads += 1;
        if (sandopolis != nuked) {
            self.mismatched_reads += 1;
            if (self.first_mismatch == null) {
                self.first_mismatch = .{
                    .clock = read.clock,
                    .kind = read.kind,
                    .port = read.port,
                    .sandopolis = sandopolis,
                    .nuked = nuked,
                };
            }
        }
    }
};

fn scheduled(clock: usize, port: u1, reg: u8, value: u8) ScheduledWrite {
    return .{
        .clock = clock,
        .port = port,
        .reg = reg,
        .value = value,
    };
}

fn statusRead(clock: usize, port: u2) ScheduledStatusRead {
    return .{
        .clock = clock,
        .kind = .status,
        .port = port,
    };
}

fn irqRead(clock: usize) ScheduledStatusRead {
    return .{
        .clock = clock,
        .kind = .irq,
    };
}

fn testPinRead(clock: usize) ScheduledStatusRead {
    return .{
        .clock = clock,
        .kind = .test_pin,
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

const lfo_pm_writes = [_]ScheduledWrite{
    scheduled(0, 0, 0x22, 0x0F),
    scheduled(1, 0, 0xA4, 0x22),
    scheduled(2, 0, 0xA0, 0x80),
    scheduled(3, 0, 0xB0, 0x07),
    scheduled(4, 0, 0xB4, 0xC7),
    scheduled(5, 0, 0x30, 0x01),
    scheduled(6, 0, 0x40, 0x18),
    scheduled(7, 0, 0x50, 0x1F),
    scheduled(8, 0, 0x60, 0x0C),
    scheduled(9, 0, 0x70, 0x08),
    scheduled(10, 0, 0x80, 0x24),
    scheduled(11, 0, 0x38, 0x01),
    scheduled(12, 0, 0x48, 0x18),
    scheduled(13, 0, 0x58, 0x1F),
    scheduled(14, 0, 0x68, 0x0C),
    scheduled(15, 0, 0x78, 0x08),
    scheduled(16, 0, 0x88, 0x24),
    scheduled(17, 0, 0x34, 0x01),
    scheduled(18, 0, 0x44, 0x18),
    scheduled(19, 0, 0x54, 0x1F),
    scheduled(20, 0, 0x64, 0x0C),
    scheduled(21, 0, 0x74, 0x08),
    scheduled(22, 0, 0x84, 0x24),
    scheduled(23, 0, 0x3C, 0x01),
    scheduled(24, 0, 0x4C, 0x00),
    scheduled(25, 0, 0x5C, 0x1F),
    scheduled(26, 0, 0x6C, 0x0C),
    scheduled(27, 0, 0x7C, 0x08),
    scheduled(28, 0, 0x8C, 0x24),
    scheduled(29, 0, 0x28, 0xF0),
    scheduled(1200, 0, 0x28, 0x00),
};

const lfo_am_writes = [_]ScheduledWrite{
    scheduled(0, 0, 0x22, 0x0F),
    scheduled(1, 0, 0xA4, 0x22),
    scheduled(2, 0, 0xA0, 0x80),
    scheduled(3, 0, 0xB0, 0x07),
    scheduled(4, 0, 0xB4, 0xF0),
    scheduled(5, 0, 0x30, 0x01),
    scheduled(6, 0, 0x40, 0x18),
    scheduled(7, 0, 0x50, 0x1F),
    scheduled(8, 0, 0x60, 0x0C),
    scheduled(9, 0, 0x70, 0x08),
    scheduled(10, 0, 0x80, 0x24),
    scheduled(11, 0, 0x38, 0x01),
    scheduled(12, 0, 0x48, 0x18),
    scheduled(13, 0, 0x58, 0x1F),
    scheduled(14, 0, 0x68, 0x0C),
    scheduled(15, 0, 0x78, 0x08),
    scheduled(16, 0, 0x88, 0x24),
    scheduled(17, 0, 0x34, 0x01),
    scheduled(18, 0, 0x44, 0x18),
    scheduled(19, 0, 0x54, 0x1F),
    scheduled(20, 0, 0x64, 0x0C),
    scheduled(21, 0, 0x74, 0x08),
    scheduled(22, 0, 0x84, 0x24),
    scheduled(23, 0, 0x3C, 0x01),
    scheduled(24, 0, 0x4C, 0x00),
    scheduled(25, 0, 0x5C, 0x1F),
    scheduled(26, 0, 0x6C, 0x8C),
    scheduled(27, 0, 0x7C, 0x08),
    scheduled(28, 0, 0x8C, 0x24),
    scheduled(29, 0, 0x28, 0xF0),
    scheduled(1200, 0, 0x28, 0x00),
};

const ch3_special_writes = [_]ScheduledWrite{
    scheduled(0, 0, 0x27, 0x40),
    scheduled(1, 0, 0xA6, 0x22),
    scheduled(2, 0, 0xA2, 0x80),
    scheduled(3, 0, 0xAC, 0x19),
    scheduled(4, 0, 0xA8, 0x40),
    scheduled(5, 0, 0xAD, 0x2B),
    scheduled(6, 0, 0xA9, 0x40),
    scheduled(7, 0, 0xAE, 0x11),
    scheduled(8, 0, 0xAA, 0xE0),
    scheduled(9, 0, 0xB2, 0x07),
    scheduled(10, 0, 0xB6, 0xC0),
    scheduled(11, 0, 0x32, 0x01),
    scheduled(12, 0, 0x42, 0x18),
    scheduled(13, 0, 0x52, 0x1F),
    scheduled(14, 0, 0x62, 0x0C),
    scheduled(15, 0, 0x72, 0x08),
    scheduled(16, 0, 0x82, 0x24),
    scheduled(17, 0, 0x3A, 0x01),
    scheduled(18, 0, 0x4A, 0x18),
    scheduled(19, 0, 0x5A, 0x1F),
    scheduled(20, 0, 0x6A, 0x0C),
    scheduled(21, 0, 0x7A, 0x08),
    scheduled(22, 0, 0x8A, 0x24),
    scheduled(23, 0, 0x36, 0x01),
    scheduled(24, 0, 0x46, 0x18),
    scheduled(25, 0, 0x56, 0x1F),
    scheduled(26, 0, 0x66, 0x0C),
    scheduled(27, 0, 0x76, 0x08),
    scheduled(28, 0, 0x86, 0x24),
    scheduled(29, 0, 0x3E, 0x01),
    scheduled(30, 0, 0x4E, 0x00),
    scheduled(31, 0, 0x5E, 0x1F),
    scheduled(32, 0, 0x6E, 0x0C),
    scheduled(33, 0, 0x7E, 0x08),
    scheduled(34, 0, 0x8E, 0x24),
    scheduled(35, 0, 0x28, 0xF2),
    scheduled(1408, 0, 0x28, 0x02),
};

const csm_tone_writes = [_]ScheduledWrite{
    scheduled(0, 0, 0xA6, 0x22),
    scheduled(1, 0, 0xA2, 0x80),
    scheduled(2, 0, 0xB2, 0x07),
    scheduled(3, 0, 0xB6, 0xC0),
    scheduled(4, 0, 0x32, 0x01),
    scheduled(5, 0, 0x42, 0x18),
    scheduled(6, 0, 0x52, 0x1F),
    scheduled(7, 0, 0x62, 0x0C),
    scheduled(8, 0, 0x72, 0x08),
    scheduled(9, 0, 0x82, 0x24),
    scheduled(10, 0, 0x3A, 0x01),
    scheduled(11, 0, 0x4A, 0x18),
    scheduled(12, 0, 0x5A, 0x1F),
    scheduled(13, 0, 0x6A, 0x0C),
    scheduled(14, 0, 0x7A, 0x08),
    scheduled(15, 0, 0x8A, 0x24),
    scheduled(16, 0, 0x36, 0x01),
    scheduled(17, 0, 0x46, 0x18),
    scheduled(18, 0, 0x56, 0x1F),
    scheduled(19, 0, 0x66, 0x0C),
    scheduled(20, 0, 0x76, 0x08),
    scheduled(21, 0, 0x86, 0x24),
    scheduled(22, 0, 0x3E, 0x01),
    scheduled(23, 0, 0x4E, 0x00),
    scheduled(24, 0, 0x5E, 0x1F),
    scheduled(25, 0, 0x6E, 0x0C),
    scheduled(26, 0, 0x7E, 0x08),
    scheduled(27, 0, 0x8E, 0x24),
    scheduled(28, 0, 0x24, 0xFF),
    scheduled(29, 0, 0x25, 0x03),
    scheduled(30, 0, 0x27, 0x85),
    scheduled(96, 0, 0x27, 0x84),
};

const ssg_setup_writes = [_]ScheduledWrite{
    scheduled(0, 0, 0xA4, 0x22),
    scheduled(1, 0, 0xA0, 0x80),
    scheduled(2, 0, 0xB0, 0x07),
    scheduled(3, 0, 0xB4, 0xC0),
    scheduled(4, 0, 0x30, 0x01),
    scheduled(5, 0, 0x40, 0x7F),
    scheduled(6, 0, 0x50, 0x1F),
    scheduled(7, 0, 0x60, 0x1F),
    scheduled(8, 0, 0x70, 0x1F),
    scheduled(9, 0, 0x80, 0x0F),
    scheduled(10, 0, 0x38, 0x01),
    scheduled(11, 0, 0x48, 0x7F),
    scheduled(12, 0, 0x58, 0x1F),
    scheduled(13, 0, 0x68, 0x1F),
    scheduled(14, 0, 0x78, 0x1F),
    scheduled(15, 0, 0x88, 0x0F),
    scheduled(16, 0, 0x34, 0x01),
    scheduled(17, 0, 0x44, 0x7F),
    scheduled(18, 0, 0x54, 0x1F),
    scheduled(19, 0, 0x64, 0x1F),
    scheduled(20, 0, 0x74, 0x1F),
    scheduled(21, 0, 0x84, 0x0F),
    scheduled(22, 0, 0x3C, 0x01),
    scheduled(23, 0, 0x4C, 0x00),
    scheduled(24, 0, 0x5C, 0x1F),
    scheduled(25, 0, 0x6C, 0x1F),
    scheduled(26, 0, 0x7C, 0x1F),
    scheduled(27, 0, 0x8C, 0x0F),
};

const ssg_repeat_writes = ssg_setup_writes ++ [_]ScheduledWrite{
    scheduled(28, 0, 0x9C, 0x08),
    scheduled(29, 0, 0x28, 0xF0),
    scheduled(2048, 0, 0x28, 0x00),
};

const ssg_hold_writes = ssg_setup_writes ++ [_]ScheduledWrite{
    scheduled(28, 0, 0x9C, 0x09),
    scheduled(29, 0, 0x28, 0xF0),
    scheduled(2048, 0, 0x28, 0x00),
};

const ssg_alternate_writes = ssg_setup_writes ++ [_]ScheduledWrite{
    scheduled(28, 0, 0x9C, 0x0A),
    scheduled(29, 0, 0x28, 0xF0),
    scheduled(2048, 0, 0x28, 0x00),
};

const ssg_alternate_hold_writes = ssg_setup_writes ++ [_]ScheduledWrite{
    scheduled(28, 0, 0x9C, 0x0B),
    scheduled(29, 0, 0x28, 0xF0),
    scheduled(2048, 0, 0x28, 0x00),
};

const ssg_inverted_repeat_writes = ssg_setup_writes ++ [_]ScheduledWrite{
    scheduled(28, 0, 0x9C, 0x0C),
    scheduled(29, 0, 0x28, 0xF0),
    scheduled(2048, 0, 0x28, 0x00),
};

const ssg_inverted_hold_writes = ssg_setup_writes ++ [_]ScheduledWrite{
    scheduled(28, 0, 0x9C, 0x0D),
    scheduled(29, 0, 0x28, 0xF0),
    scheduled(2048, 0, 0x28, 0x00),
};

const ssg_inverted_alternate_writes = ssg_setup_writes ++ [_]ScheduledWrite{
    scheduled(28, 0, 0x9C, 0x0E),
    scheduled(29, 0, 0x28, 0xF0),
    scheduled(2048, 0, 0x28, 0x00),
};

const ssg_inverted_alternate_hold_writes = ssg_setup_writes ++ [_]ScheduledWrite{
    scheduled(28, 0, 0x9C, 0x0F),
    scheduled(29, 0, 0x28, 0xF0),
    scheduled(2048, 0, 0x28, 0x00),
};

// Detune test: DT1=7 (maximum detune) on all operators
const detune_max_writes = [_]ScheduledWrite{
    scheduled(0, 0, 0xA4, 0x22),
    scheduled(1, 0, 0xA0, 0x80),
    scheduled(2, 0, 0xB0, 0x07),
    scheduled(3, 0, 0xB4, 0xC0),
    scheduled(4, 0, 0x30, 0x71), // DT1=7, MUL=1
    scheduled(5, 0, 0x40, 0x18),
    scheduled(6, 0, 0x50, 0x1F),
    scheduled(7, 0, 0x60, 0x0C),
    scheduled(8, 0, 0x70, 0x08),
    scheduled(9, 0, 0x80, 0x24),
    scheduled(10, 0, 0x38, 0x71),
    scheduled(11, 0, 0x48, 0x18),
    scheduled(12, 0, 0x58, 0x1F),
    scheduled(13, 0, 0x68, 0x0C),
    scheduled(14, 0, 0x78, 0x08),
    scheduled(15, 0, 0x88, 0x24),
    scheduled(16, 0, 0x34, 0x71),
    scheduled(17, 0, 0x44, 0x18),
    scheduled(18, 0, 0x54, 0x1F),
    scheduled(19, 0, 0x64, 0x0C),
    scheduled(20, 0, 0x74, 0x08),
    scheduled(21, 0, 0x84, 0x24),
    scheduled(22, 0, 0x3C, 0x71),
    scheduled(23, 0, 0x4C, 0x00),
    scheduled(24, 0, 0x5C, 0x1F),
    scheduled(25, 0, 0x6C, 0x0C),
    scheduled(26, 0, 0x7C, 0x08),
    scheduled(27, 0, 0x8C, 0x24),
    scheduled(28, 0, 0x28, 0xF0),
    scheduled(1200, 0, 0x28, 0x00),
};

// Detune test: DT1=4 (negative detune) on all operators
const detune_neg_writes = [_]ScheduledWrite{
    scheduled(0, 0, 0xA4, 0x22),
    scheduled(1, 0, 0xA0, 0x80),
    scheduled(2, 0, 0xB0, 0x07),
    scheduled(3, 0, 0xB4, 0xC0),
    scheduled(4, 0, 0x30, 0x41), // DT1=4, MUL=1
    scheduled(5, 0, 0x40, 0x18),
    scheduled(6, 0, 0x50, 0x1F),
    scheduled(7, 0, 0x60, 0x0C),
    scheduled(8, 0, 0x70, 0x08),
    scheduled(9, 0, 0x80, 0x24),
    scheduled(10, 0, 0x38, 0x41),
    scheduled(11, 0, 0x48, 0x18),
    scheduled(12, 0, 0x58, 0x1F),
    scheduled(13, 0, 0x68, 0x0C),
    scheduled(14, 0, 0x78, 0x08),
    scheduled(15, 0, 0x88, 0x24),
    scheduled(16, 0, 0x34, 0x41),
    scheduled(17, 0, 0x44, 0x18),
    scheduled(18, 0, 0x54, 0x1F),
    scheduled(19, 0, 0x64, 0x0C),
    scheduled(20, 0, 0x74, 0x08),
    scheduled(21, 0, 0x84, 0x24),
    scheduled(22, 0, 0x3C, 0x41),
    scheduled(23, 0, 0x4C, 0x00),
    scheduled(24, 0, 0x5C, 0x1F),
    scheduled(25, 0, 0x6C, 0x0C),
    scheduled(26, 0, 0x7C, 0x08),
    scheduled(27, 0, 0x8C, 0x24),
    scheduled(28, 0, 0x28, 0xF0),
    scheduled(1200, 0, 0x28, 0x00),
};

// Envelope: maximum attack rate (rate=31) for instant attack
const eg_max_attack_writes = [_]ScheduledWrite{
    scheduled(0, 0, 0xA4, 0x22),
    scheduled(1, 0, 0xA0, 0x80),
    scheduled(2, 0, 0xB0, 0x07),
    scheduled(3, 0, 0xB4, 0xC0),
    scheduled(4, 0, 0x30, 0x01),
    scheduled(5, 0, 0x40, 0x18),
    scheduled(6, 0, 0x50, 0x1F), // AR=31
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
    scheduled(1200, 0, 0x28, 0x00),
};

// Envelope: slow attack rate (rate=1) with high rate scaling (KS=3)
const eg_slow_attack_ks_writes = [_]ScheduledWrite{
    scheduled(0, 0, 0xA4, 0x3A), // High block for strong rate scaling
    scheduled(1, 0, 0xA0, 0x80),
    scheduled(2, 0, 0xB0, 0x07),
    scheduled(3, 0, 0xB4, 0xC0),
    scheduled(4, 0, 0x30, 0x01),
    scheduled(5, 0, 0x40, 0x18),
    scheduled(6, 0, 0x50, 0xC1), // AR=1, KS=3
    scheduled(7, 0, 0x60, 0x0C),
    scheduled(8, 0, 0x70, 0x08),
    scheduled(9, 0, 0x80, 0x24),
    scheduled(10, 0, 0x38, 0x01),
    scheduled(11, 0, 0x48, 0x18),
    scheduled(12, 0, 0x58, 0xC1),
    scheduled(13, 0, 0x68, 0x0C),
    scheduled(14, 0, 0x78, 0x08),
    scheduled(15, 0, 0x88, 0x24),
    scheduled(16, 0, 0x34, 0x01),
    scheduled(17, 0, 0x44, 0x18),
    scheduled(18, 0, 0x54, 0xC1),
    scheduled(19, 0, 0x64, 0x0C),
    scheduled(20, 0, 0x74, 0x08),
    scheduled(21, 0, 0x84, 0x24),
    scheduled(22, 0, 0x3C, 0x01),
    scheduled(23, 0, 0x4C, 0x00),
    scheduled(24, 0, 0x5C, 0xC1),
    scheduled(25, 0, 0x6C, 0x0C),
    scheduled(26, 0, 0x7C, 0x08),
    scheduled(27, 0, 0x8C, 0x24),
    scheduled(28, 0, 0x28, 0xF0),
    scheduled(4000, 0, 0x28, 0x00),
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

const status_busy_writes = [_]ScheduledWrite{
    scheduled(0, 0, 0x22, 0x0F),
};

const status_busy_reads = [_]ScheduledStatusRead{
    statusRead(1, 0),
    statusRead(2, 2),
    statusRead(33, 2),
    statusRead(33, 0),
};

const status_readmode_reads = [_]ScheduledStatusRead{
    statusRead(1, 2),
    statusRead(33, 2),
};

const status_timer_a_writes = [_]ScheduledWrite{
    scheduled(0, 0, 0x24, 0xFF),
    scheduled(1, 0, 0x25, 0x03),
    scheduled(2, 0, 0x27, 0x05),
    scheduled(40, 0, 0x27, 0x10),
};

const status_timer_a_reads = [_]ScheduledStatusRead{
    statusRead(70, 0),
    irqRead(70),
    statusRead(90, 0),
    irqRead(90),
};

const status_timer_b_writes = [_]ScheduledWrite{
    scheduled(0, 0, 0x26, 0xFF),
    scheduled(1, 0, 0x27, 0x0A),
    scheduled(220, 0, 0x27, 0x20),
};

const status_timer_b_reads = [_]ScheduledStatusRead{
    statusRead(192, 0),
    irqRead(192),
    statusRead(400, 0),
    irqRead(400),
    statusRead(472, 0),
    irqRead(472),
};

const status_test_pin_writes = [_]ScheduledWrite{
    scheduled(0, 0, 0x2C, 0x80),
};

const status_test_pin_reads = [_]ScheduledStatusRead{
    testPinRead(21),
    testPinRead(22),
    testPinRead(23),
};

const status_test_data_writes = tone_setup_writes ++ [_]ScheduledWrite{
    scheduled(40, 0, 0x21, 0x40),
    scheduled(80, 0, 0x21, 0xC0),
    scheduled(120, 0, 0x21, 0x00),
};

const status_test_data_reads = [_]ScheduledStatusRead{
    statusRead(96, 0),
    statusRead(176, 0),
    statusRead(256, 0),
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
    .{
        .name = "lfo-pm",
        .description = "Tone with LFO enabled and maximum phase modulation sensitivity",
        .total_clocks = 2048,
        .writes = lfo_pm_writes[0..],
    },
    .{
        .name = "lfo-am",
        .description = "Tone with LFO enabled and maximum amplitude modulation sensitivity",
        .total_clocks = 2048,
        .writes = lfo_am_writes[0..],
    },
    .{
        .name = "ch3-special",
        .description = "Channel 3 special mode with operator-specific frequencies",
        .total_clocks = 2048,
        .writes = ch3_special_writes[0..],
    },
    .{
        .name = "csm-tone",
        .description = "Channel 3 CSM retriggering driven by Timer A overflow",
        .total_clocks = 1024,
        .writes = csm_tone_writes[0..],
    },
    .{
        .name = "ssg-repeat",
        .description = "Carrier operator with SSG-EG repeat enabled",
        .total_clocks = 4096,
        .writes = ssg_repeat_writes[0..],
    },
    .{
        .name = "ssg-hold",
        .description = "Carrier operator with SSG-EG hold enabled",
        .total_clocks = 4096,
        .writes = ssg_hold_writes[0..],
    },
    .{
        .name = "ssg-alternate",
        .description = "Carrier operator with SSG-EG alternate enabled",
        .total_clocks = 4096,
        .writes = ssg_alternate_writes[0..],
    },
    .{
        .name = "ssg-alternate-hold",
        .description = "Carrier operator with SSG-EG alternate+hold (mode 0x0B)",
        .total_clocks = 4096,
        .writes = ssg_alternate_hold_writes[0..],
    },
    .{
        .name = "ssg-inverted-repeat",
        .description = "Carrier operator with SSG-EG inverted repeat (mode 0x0C)",
        .total_clocks = 4096,
        .writes = ssg_inverted_repeat_writes[0..],
    },
    .{
        .name = "ssg-inverted-hold",
        .description = "Carrier operator with SSG-EG inverted hold (mode 0x0D)",
        .total_clocks = 4096,
        .writes = ssg_inverted_hold_writes[0..],
    },
    .{
        .name = "ssg-inverted-alternate",
        .description = "Carrier operator with SSG-EG inverted alternate (mode 0x0E)",
        .total_clocks = 4096,
        .writes = ssg_inverted_alternate_writes[0..],
    },
    .{
        .name = "ssg-inverted-alternate-hold",
        .description = "Carrier operator with SSG-EG inverted alternate+hold (mode 0x0F)",
        .total_clocks = 4096,
        .writes = ssg_inverted_alternate_hold_writes[0..],
    },
    .{
        .name = "detune-max",
        .description = "All operators with DT1=7 (maximum positive detune)",
        .total_clocks = 2048,
        .writes = detune_max_writes[0..],
    },
    .{
        .name = "detune-neg",
        .description = "All operators with DT1=4 (maximum negative detune)",
        .total_clocks = 2048,
        .writes = detune_neg_writes[0..],
    },
    .{
        .name = "eg-max-attack",
        .description = "All operators with maximum attack rate (AR=31, instant attack)",
        .total_clocks = 2048,
        .writes = eg_max_attack_writes[0..],
    },
    .{
        .name = "eg-slow-attack-ks",
        .description = "Slow attack rate (AR=1) with high rate scaling (KS=3, high block)",
        .total_clocks = 8192,
        .writes = eg_slow_attack_ks_writes[0..],
    },
};

const status_scenarios = [_]StatusScenario{
    .{
        .name = "status-busy",
        .description = "BUSY latch behavior on port 0 vs nonzero ports",
        .total_internal_clocks = 48,
        .writes = status_busy_writes[0..],
        .reads = status_busy_reads[0..],
    },
    .{
        .name = "status-readmode",
        .description = "Read-mode behavior for nonzero status ports",
        .total_internal_clocks = 48,
        .writes = status_busy_writes[0..],
        .reads = status_readmode_reads[0..],
        .read_mode = true,
    },
    .{
        .name = "status-timer-a",
        .description = "Timer A overflow status and IRQ behavior",
        .total_internal_clocks = 128,
        .writes = status_timer_a_writes[0..],
        .reads = status_timer_a_reads[0..],
    },
    .{
        .name = "status-timer-b",
        .description = "Timer B overflow status and IRQ behavior",
        .total_internal_clocks = 544,
        .writes = status_timer_b_writes[0..],
        .reads = status_timer_b_reads[0..],
    },
    .{
        .name = "status-test-pin",
        .description = "TEST pin phase when test mode 2 bit 7 is enabled",
        .total_internal_clocks = 32,
        .writes = status_test_pin_writes[0..],
        .reads = status_test_pin_reads[0..],
    },
    .{
        .name = "status-test-data",
        .description = "Status reads returning test-data bytes while a tone is running",
        .total_internal_clocks = 288,
        .writes = status_test_data_writes[0..],
        .reads = status_test_data_reads[0..],
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
        if (findScenario(name)) |scenario| {
            try runOne(stdout, scenario);
            continue;
        }

        if (findStatusScenario(name)) |scenario| {
            try runStatusOne(stdout, scenario);
            continue;
        }

        {
            try stderr.print("Unknown scenario: {s}\n\n", .{name});
            try printUsage(stderr);
            try stderr.flush();
            return error.InvalidScenario;
        }
    }
    try stdout.flush();
}

fn runAll(writer: anytype) !void {
    for (scenarios, 0..) |scenario, index| {
        if (index != 0) try writer.writeByte('\n');
        try runOne(writer, scenario);
    }

    for (status_scenarios) |scenario| {
        try writer.writeByte('\n');
        try runStatusOne(writer, scenario);
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

fn runStatusOne(writer: anytype, scenario: StatusScenario) !void {
    const metrics = runStatusScenario(scenario);

    try writer.print(
        "{s}: reads={d} mismatches={d}\n",
        .{
            scenario.name,
            metrics.compared_reads,
            metrics.mismatched_reads,
        },
    );
    try writer.print("  {s}\n", .{scenario.description});

    if (metrics.first_mismatch) |mismatch| {
        try writer.print(
            "  first mismatch @ clock {d}: {s} port={d} sandopolis=0x{X:0>2} nuked=0x{X:0>2}\n",
            .{
                mismatch.clock,
                statusKindLabel(mismatch.kind),
                mismatch.port,
                mismatch.sandopolis,
                mismatch.nuked,
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
    var pending_data_write: ?ScheduledWrite = null;
    var nuked_buffer: [2]c.Bit16s = .{ 0, 0 };
    const total_internal_clocks = scenario.total_clocks * 2;

    for (0..total_internal_clocks) |clock_idx| {
        while (next_write_index < scenario.writes.len and scenario.writes[next_write_index].clock * 2 == clock_idx) : (next_write_index += 1) {
            const write = scenario.writes[next_write_index];
            std.debug.assert(pending_data_write == null);
            pending_data_write = write;

            const address_port: c.Bit32u = @as(c.Bit32u, write.port) * 2;
            c.OPN2_Write(&nuked, address_port, write.reg);
        }

        if (pending_data_write) |write| {
            if (write.clock * 2 + 1 == clock_idx) {
                const address_port: c.Bit32u = @as(c.Bit32u, write.port) * 2;
                c.OPN2_Write(&nuked, address_port + 1, write.value);
                sandopolis.applyWrite(testing.ymWriteEvent(write.port, write.reg, write.value));
                pending_data_write = null;
            }
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
    std.debug.assert(pending_data_write == null);
    return metrics;
}

fn runStatusScenario(scenario: StatusScenario) StatusMetrics {
    var sandopolis = testing.Ym2612Synth{};
    sandopolis.setReadMode(scenario.read_mode);

    var nuked: c.ym3438_t = undefined;
    const chip_type: c.Bit32u =
        @as(c.Bit32u, @intCast(c.ym3438_mode_ym2612)) |
        if (scenario.read_mode) @as(c.Bit32u, @intCast(c.ym3438_mode_readmode)) else 0;
    c.OPN2_SetChipType(chip_type);
    c.OPN2_Reset(&nuked);

    var metrics = StatusMetrics{};
    var next_write_index: usize = 0;
    var pending_data_write: ?ScheduledWrite = null;
    var next_read_index: usize = 0;
    var nuked_buffer: [2]c.Bit16s = .{ 0, 0 };

    for (0..scenario.total_internal_clocks) |clock_idx| {
        while (next_write_index < scenario.writes.len and scenario.writes[next_write_index].clock * 2 == clock_idx) : (next_write_index += 1) {
            const write = scenario.writes[next_write_index];
            std.debug.assert(pending_data_write == null);
            pending_data_write = write;

            const address_port: c.Bit32u = @as(c.Bit32u, write.port) * 2;
            c.OPN2_Write(&nuked, address_port, write.reg);
        }

        if (pending_data_write) |write| {
            if (write.clock * 2 + 1 == clock_idx) {
                const address_port: c.Bit32u = @as(c.Bit32u, write.port) * 2;
                c.OPN2_Write(&nuked, address_port + 1, write.value);
                sandopolis.applyWrite(testing.ymWriteEvent(write.port, write.reg, write.value));
                pending_data_write = null;
            }
        }

        _ = sandopolis.clockOneInternal();
        c.OPN2_Clock(&nuked, &nuked_buffer[0]);

        while (next_read_index < scenario.reads.len and scenario.reads[next_read_index].clock == clock_idx) : (next_read_index += 1) {
            const read = scenario.reads[next_read_index];
            const sandopolis_value = switch (read.kind) {
                .status => sandopolis.readStatus(read.port),
                .irq => sandopolis.readIrqPin(),
                .test_pin => sandopolis.readTestPin(),
            };
            const nuked_value: u8 = switch (read.kind) {
                .status => c.OPN2_Read(&nuked, read.port),
                .irq => @intCast(c.OPN2_ReadIRQPin(&nuked)),
                .test_pin => @intCast(c.OPN2_ReadTestPin(&nuked)),
            };
            metrics.observe(read, sandopolis_value, nuked_value);
        }
    }

    std.debug.assert(next_write_index == scenario.writes.len);
    std.debug.assert(pending_data_write == null);
    std.debug.assert(next_read_index == scenario.reads.len);
    return metrics;
}

fn findScenario(name: []const u8) ?Scenario {
    for (scenarios) |scenario| {
        if (std.mem.eql(u8, scenario.name, name)) return scenario;
    }
    return null;
}

fn findStatusScenario(name: []const u8) ?StatusScenario {
    for (status_scenarios) |scenario| {
        if (std.mem.eql(u8, scenario.name, name)) return scenario;
    }
    return null;
}

fn printUsage(writer: anytype) !void {
    try writer.writeAll(
        "Usage: zig build compare-ym -- [all|scenario...]\n" ++
            "Compares Sandopolis raw YM2612 pin output against external/Nuked-OPN2\n" ++
            "for deterministic decoded register-write and status-read scenarios.\n\n",
    );
    try writer.writeAll("Available scenarios:\n");
    for (scenarios) |scenario| {
        try writer.print("  {s}: {s}\n", .{ scenario.name, scenario.description });
    }
    for (status_scenarios) |scenario| {
        try writer.print("  {s}: {s}\n", .{ scenario.name, scenario.description });
    }
}

fn signedDiff(a: i16, b: i16) i32 {
    return @as(i32, a) - @as(i32, b);
}

fn absI32(value: i32) u32 {
    return @intCast(if (value < 0) -value else value);
}

fn statusKindLabel(kind: StatusReadKind) []const u8 {
    return switch (kind) {
        .status => "status",
        .irq => "irq",
        .test_pin => "test-pin",
    };
}
