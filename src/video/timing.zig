const std = @import("std");
const testing = std.testing;
const clock = @import("../clock.zig");
const Vdp = @import("vdp.zig").Vdp;
const fifo = @import("fifo.zig");

pub const AdjustedLineState = struct {
    scanline: u16,
    line_master_cycle: u16,
    hblank: bool,
    vblank: bool,
};

const VCounterState = struct {
    counter: u8,
    vblank: bool,
};

pub fn activeVisibleLines(self: *const Vdp) u16 {
    if (!self.pal_mode) return clock.ntsc_visible_lines;
    return if ((self.regs[1] & 0x08) != 0) clock.pal_visible_lines else clock.ntsc_visible_lines;
}

fn powerOnStartScanline(self: *const Vdp) u16 {
    return if (self.pal_mode) 132 else 159;
}

fn powerOnStartLineMasterCycle() u16 {
    // Genesis Plus GX seeds hard reset from the measured first-HVC point; Sandopolis's
    // internal line origin differs, so this maps the same hardware point into our timing model.
    return 522;
}

pub fn totalLinesForCurrentFrame(self: *const Vdp) u16 {
    if (!self.isInterlaceMode2()) {
        return if (self.pal_mode) clock.pal_lines_per_frame else clock.ntsc_lines_per_frame;
    }

    if (self.pal_mode) {
        return if (self.odd_frame) clock.pal_lines_per_frame else clock.pal_lines_per_frame - 1;
    }

    return if (self.odd_frame) clock.ntsc_lines_per_frame + 1 else clock.ntsc_lines_per_frame;
}

pub fn frameMasterCycles(self: *const Vdp) u32 {
    const master_cycles_per_line: u16 = if (self.pal_mode)
        clock.pal_master_cycles_per_line
    else
        clock.ntsc_master_cycles_per_line;
    return @as(u32, totalLinesForCurrentFrame(self)) * @as(u32, master_cycles_per_line);
}

pub fn hInterruptMasterCycles(self: *const Vdp) u16 {
    return if (self.isH40()) 0x014A * 8 else 0x010A * 10;
}

pub fn hblankStartMasterCycles(self: *const Vdp) u16 {
    return if (self.isH40()) 0x015A * 8 else 0x0108 * 10;
}

fn effectiveScanlineForVCounter(self: *const Vdp, scanline: u16, line_master_cycle: u16) u16 {
    if (line_master_cycle < hInterruptMasterCycles(self)) return scanline;

    const total_lines = totalLinesForCurrentFrame(self);
    if (scanline + 1 >= total_lines) return 0;
    return scanline + 1;
}

fn vCounterAt(self: *const Vdp, scanline: u16, line_master_cycle: u16) VCounterState {
    const effective_scanline = effectiveScanlineForVCounter(self, scanline, line_master_cycle);
    const active_scanlines = activeVisibleLines(self);

    if (!self.isInterlaceMode2()) {
        const threshold: u16 = if (!self.pal_mode)
            0x00EA
        else if ((self.regs[1] & 0x08) != 0)
            0x010A
        else
            0x0102;
        const scanlines_per_frame: u16 = if (self.pal_mode) clock.pal_lines_per_frame else clock.ntsc_lines_per_frame;
        const counter_u16: u16 = if (effective_scanline <= threshold)
            effective_scanline
        else
            (effective_scanline -% scanlines_per_frame) & 0x01FF;

        return .{
            .counter = @truncate(counter_u16),
            .vblank = counter_u16 >= active_scanlines and counter_u16 != 0x01FF,
        };
    }

    const threshold: u16 = if (!self.pal_mode)
        0x00EA
    else if ((self.regs[1] & 0x08) != 0)
        0x0109
    else
        0x0101;
    const scanlines_per_frame = totalLinesForCurrentFrame(self);
    const internal_counter: u16 = if (effective_scanline <= threshold)
        effective_scanline
    else
        (effective_scanline -% scanlines_per_frame) & 0x01FF;
    const external_counter: u16 = ((internal_counter << 1) & 0x00FE) | ((internal_counter >> 7) & 0x0001);

    return .{
        .counter = @truncate(external_counter),
        .vblank = internal_counter >= active_scanlines and internal_counter != 0x01FF,
    };
}

fn internalHFor(self: *const Vdp, line_master_cycle: u16) u16 {
    const pixel = if (self.isH40())
        scanlineMasterCyclesToPixelH40(line_master_cycle)
    else
        scanlineMasterCyclesToPixelH32(line_master_cycle);
    return if (self.isH40())
        pixelToInternalHH40(pixel)
    else
        pixelToInternalHH32(pixel);
}

fn statusHBlankFlagAt(self: *const Vdp, line_master_cycle: u16) bool {
    const internal_h = internalHFor(self, line_master_cycle);
    if (self.isH40()) {
        return !(internal_h >= 0x000B and internal_h < 0x0166);
    }

    return !(internal_h >= 0x000A and internal_h < 0x0126);
}

pub fn adjustedLineState(self: *const Vdp, adjustment_master_cycles: u32) AdjustedLineState {
    const total_master = @as(u32, self.line_master_cycle) + adjustment_master_cycles;
    const line_advance = total_master / clock.ntsc_master_cycles_per_line;
    const total_lines = totalLinesForCurrentFrame(self);
    const line_master_cycle: u16 = @intCast(total_master % clock.ntsc_master_cycles_per_line);
    const scanline: u16 = @intCast((@as(u32, self.scanline) + line_advance) % total_lines);
    const v_counter = vCounterAt(self, scanline, line_master_cycle);
    return .{
        .scanline = scanline,
        .line_master_cycle = line_master_cycle,
        .hblank = statusHBlankFlagAt(self, line_master_cycle),
        .vblank = v_counter.vblank,
    };
}

fn computeLiveHVCounterAt(self: *const Vdp, scanline: u16, line_master_cycle: u16) u16 {
    const v_counter = vCounterAt(self, scanline, line_master_cycle).counter;
    const h_counter = computeHCounterFor(self, line_master_cycle);
    return (@as(u16, v_counter) << 8) | h_counter;
}

fn scanlineMasterCyclesToPixelH32(line_master_cycle: u16) u16 {
    return line_master_cycle / 10;
}

fn pixelToInternalHH32(pixel: u16) u16 {
    return if (pixel <= 0x0127) pixel else pixel + (0x01D2 - 0x0128);
}

fn scanlineMasterCyclesToPixelH40(line_master_cycle: u16) u16 {
    const jump_diff: u32 = 0x01C9 - 0x016D;
    const line_master_u32: u32 = line_master_cycle;

    if (line_master_u32 < (0x01CC - jump_diff) * 8) {
        return @intCast(line_master_u32 / 8);
    }

    const hsync_start_master = (0x01CC - jump_diff) * 8;
    const hsync_pattern_master = 8 + 7 * 10 + 2 * 9 + 7 * 10;
    const hsync_end_master = hsync_start_master + 2 * hsync_pattern_master;
    if (line_master_u32 < hsync_end_master) {
        const hsync_master = line_master_u32 - hsync_start_master;
        const pattern_master = hsync_master % hsync_pattern_master;
        const pattern_pixel: u32 = switch (pattern_master) {
            0...7 => 0,
            8...77 => 1 + (pattern_master - 8) / 10,
            78...95 => 8 + (pattern_master - 78) / 9,
            96...165 => 10 + (pattern_master - 96) / 10,
            else => unreachable,
        };

        return @intCast(if (hsync_master < hsync_pattern_master)
            0x01CC - jump_diff + pattern_pixel
        else
            0x01CC - jump_diff + 17 + pattern_pixel);
    }

    const post_hsync_master = line_master_u32 - hsync_end_master;
    return @intCast(0x01CC - jump_diff + 34 + post_hsync_master / 8);
}

fn pixelToInternalHH40(pixel: u16) u16 {
    return if (pixel <= 0x016C) pixel else pixel + (0x01C9 - 0x016D);
}

fn h40UsesEarlyCounterIncrement(line_master_cycle: u16) bool {
    return switch (line_master_cycle) {
        2961, 2981, 3001, 3021, 3039, 3059, 3079, 3099, 3137, 3157, 3177, 3215, 3235, 3255, 3275 => true,
        else => false,
    };
}

fn computeHCounterFor(self: *const Vdp, line_master_cycle: u16) u8 {
    const internal_h = internalHFor(self, line_master_cycle);
    var counter: u8 = @truncate(internal_h >> 1);
    // Standard H40 mode has a handful of single-master-cycle counter edges during HSYNC
    // that occur one cycle earlier than the simplified EDCLK phase model predicts.
    if (self.isH40() and h40UsesEarlyCounterIncrement(line_master_cycle)) {
        counter +%= 1;
    }
    return counter;
}

fn vintFlagForAdjustedState(self: *const Vdp, adjusted: AdjustedLineState) bool {
    if (self.vint_pending) return true;

    const current = adjustedLineState(self, 0);
    return !current.vblank and adjusted.vblank;
}

fn fifoEmptyFlagForAdjustedState(self: *const Vdp, adjustment_master_cycles: u32) bool {
    const drain_wait = fifo.dataPortReadWaitMasterCycles(self);
    return drain_wait == 0 or drain_wait <= adjustment_master_cycles;
}

fn fifoFullFlagForAdjustedState(self: *const Vdp, adjustment_master_cycles: u32) bool {
    const open_wait = fifo.dataPortWriteWaitMasterCycles(self);
    return open_wait > adjustment_master_cycles;
}

fn dmaBusyFlagForAdjustedState(self: *const Vdp, adjustment_master_cycles: u32) bool {
    return fifo.dmaBusyAfterMasterCycles(self, adjustment_master_cycles);
}

fn statusWordForAdjustedState(self: *const Vdp, adjusted: AdjustedLineState) u16 {
    var status: u16 = 0;
    const adjustment_master_cycles = lineMasterCycleDelta(self, self.scanline, self.line_master_cycle, adjusted.scanline, adjusted.line_master_cycle);

    if (fifoEmptyFlagForAdjustedState(self, adjustment_master_cycles)) status |= 0x0200;
    if (fifoFullFlagForAdjustedState(self, adjustment_master_cycles)) status |= 0x0100;

    if (adjusted.vblank or !self.isDisplayEnabled()) status |= 0x0008;
    if (adjusted.hblank) status |= 0x0004;
    if (dmaBusyFlagForAdjustedState(self, adjustment_master_cycles)) status |= 0x0002;
    if (self.pal_mode) status |= 0x0001;
    if (self.odd_frame) status |= 0x0010;
    if (self.sprite_collision) status |= 0x0020;
    if (self.sprite_overflow) status |= 0x0040;
    if (vintFlagForAdjustedState(self, adjusted)) status |= 0x0080;

    return status;
}

fn statusReadAdjustmentMasterCycles(opcode: u16) u32 {
    if ((opcode & 0xC000) == 0 and ((opcode >> 12) & 0x3) != 0) {
        return 0;
    }

    if ((opcode & 0xFF00) == 0x0C00) {
        return clock.m68kCyclesToMaster(4);
    }

    if ((opcode & 0xFF00) == 0x0800 and ((opcode >> 6) & 0x3) == 0) {
        return clock.m68kCyclesToMaster(4);
    }

    if ((opcode & 0xF000) == 0xB000) {
        return 0;
    }

    if ((opcode & 0x0100) != 0 and ((opcode >> 6) & 0x3) == 0) {
        return clock.m68kCyclesToMaster(2);
    }

    return clock.m68kCyclesToMaster(8);
}

fn lineMasterCycleDelta(
    self: *const Vdp,
    from_scanline: u16,
    from_line_master_cycle: u16,
    to_scanline: u16,
    to_line_master_cycle: u16,
) u32 {
    const total_lines = totalLinesForCurrentFrame(self);
    const from_total =
        (@as(u32, from_scanline) * clock.ntsc_master_cycles_per_line) + from_line_master_cycle;
    var to_total =
        (@as(u32, to_scanline) * clock.ntsc_master_cycles_per_line) + to_line_master_cycle;
    if (to_total < from_total) {
        to_total += @as(u32, total_lines) * clock.ntsc_master_cycles_per_line;
    }
    return to_total - from_total;
}

pub fn readControl(self: *Vdp) u16 {
    const current = adjustedLineState(self, 0);
    const status = statusWordForAdjustedState(self, current);

    self.pending_command = false;
    self.vint_pending = false;
    self.sprite_overflow = false;
    self.sprite_collision = false;

    return status;
}

pub fn readControlAdjusted(self: *Vdp, opcode: u16) u16 {
    const adjusted = adjustedLineState(self, statusReadAdjustmentMasterCycles(opcode));
    const status = statusWordForAdjustedState(self, adjusted);

    self.pending_command = false;
    self.vint_pending = false;
    self.sprite_overflow = false;
    self.sprite_collision = false;

    return status;
}

fn computeLiveHVCounter(self: *const Vdp) u16 {
    return computeLiveHVCounterAt(self, self.scanline, self.line_master_cycle);
}

fn computeHCounterShaped(self: *const Vdp) u8 {
    return computeHCounterFor(self, self.line_master_cycle);
}

pub fn readHVCounter(self: *Vdp) u16 {
    self.pending_command = false;
    if (self.isHVCounterLatchEnabled() and self.hv_latched_valid) {
        return self.hv_latched;
    }
    return computeLiveHVCounter(self);
}

pub fn readHVCounterAdjusted(self: *Vdp, opcode: u16) u16 {
    self.pending_command = false;
    if (self.isHVCounterLatchEnabled() and self.hv_latched_valid) {
        return self.hv_latched;
    }
    const adjusted = adjustedLineState(self, statusReadAdjustmentMasterCycles(opcode));
    return computeLiveHVCounterAt(self, adjusted.scanline, adjusted.line_master_cycle);
}

pub fn step(self: *Vdp, cycles: u32) void {
    const total = @as(u32, self.line_master_cycle) + cycles;
    self.line_master_cycle = @intCast(total % clock.ntsc_master_cycles_per_line);
}

pub fn setScanlineState(self: *Vdp, line: u16, visible_lines: u16, total_lines: u16) bool {
    if (line != self.scanline) {
        self.line_master_cycle = 0;
        fifo.resetTransferPhase(self);
    }
    self.scanline = line;
    const in_vblank = line >= visible_lines and line < total_lines;
    const entering_vblank = !self.vblank and in_vblank;
    self.vblank = in_vblank;
    if (entering_vblank) {
        self.vint_pending = true;
    }
    return entering_vblank;
}

pub fn setHBlank(self: *Vdp, active: bool) void {
    if (self.hblank != active) {
        fifo.resetTransferPhase(self);
    }
    if (!self.hblank and active and self.isHVCounterLatchEnabled()) {
        self.hv_latched = computeLiveHVCounter(self);
        self.hv_latched_valid = true;
    }
    self.hblank = active;
}

pub fn isVBlankInterruptEnabled(self: *const Vdp) bool {
    return (self.regs[1] & 0x20) != 0;
}

pub fn beginFrame(self: *Vdp) void {
    self.hint_counter = @intCast(self.regs[10]);
}

pub fn applyPowerOnResetTiming(self: *Vdp) void {
    self.scanline = powerOnStartScanline(self);
    self.line_master_cycle = powerOnStartLineMasterCycle();
    self.hblank = false;
    self.vblank = false;
    self.vint_pending = false;
    self.hv_latched_valid = false;
    self.transfer_line_master_cycle = self.line_master_cycle;
    self.projected_data_port_write_wait = .{};
}

pub fn consumeHintForLine(self: *Vdp, line: u16, visible_lines: u16) bool {
    if (line >= visible_lines) return false;
    self.hint_counter -= 1;
    if (self.hint_counter < 0) {
        self.hint_counter = @intCast(self.regs[10]);
        return (self.regs[0] & 0x10) != 0;
    }
    return false;
}

test "H40 status hblank flag turns on after the external hblank edge" {
    var vdp = Vdp.init();
    vdp.regs[12] = 0x81;

    const hblank_signal_start = vdp.hblankStartMasterCycles();
    vdp.line_master_cycle = hblank_signal_start;
    try testing.expectEqual(@as(u16, 0), vdp.readControl() & 0x0004);

    vdp.line_master_cycle = hblank_signal_start + 95;
    try testing.expectEqual(@as(u16, 0), vdp.readControl() & 0x0004);

    vdp.line_master_cycle = hblank_signal_start + 96;
    try testing.expectEqual(@as(u16, 0x0004), vdp.readControl() & 0x0004);
}

test "status read adjustment can observe fifo empty after the next access slot" {
    var vdp = Vdp.init();
    vdp.regs[12] = 0x81;
    vdp.code = 0x3;
    vdp.addr = 0x0000;
    vdp.scanline = 12;
    vdp.line_master_cycle = vdp.hblankStartMasterCycles() - 1;
    vdp.transfer_line_master_cycle = vdp.line_master_cycle;

    vdp.writeData(0x1234);
    vdp.fifo[vdp.fifo_head].latency = 0;

    const drain_wait = vdp.dataPortReadWaitMasterCycles();
    try testing.expect(drain_wait > 0);
    try testing.expect(drain_wait <= clock.m68kCyclesToMaster(8));

    try testing.expectEqual(@as(u16, 0), vdp.readControl() & 0x0200);
    try testing.expectEqual(@as(u16, 0x0200), vdp.readControlAdjusted(0x4E71) & 0x0200);
}

test "status read adjustment can observe fifo no longer full after the next access slot" {
    var vdp = Vdp.init();
    vdp.regs[12] = 0x81;
    vdp.code = 0x3;
    vdp.addr = 0x0000;
    vdp.scanline = 12;
    vdp.line_master_cycle = vdp.hblankStartMasterCycles() - 1;
    vdp.transfer_line_master_cycle = vdp.line_master_cycle;

    for (0..4) |i| {
        vdp.writeData(@intCast(0x2000 + i));
    }

    var i: usize = 0;
    while (i < @as(usize, vdp.fifo_len)) : (i += 1) {
        const idx = (@as(usize, vdp.fifo_head) + i) % vdp.fifo.len;
        vdp.fifo[idx].latency = 0;
    }

    const open_wait = vdp.dataPortWriteWaitMasterCycles();
    try testing.expect(open_wait > 0);
    try testing.expect(open_wait <= clock.m68kCyclesToMaster(8));

    try testing.expectEqual(@as(u16, 0x0100), vdp.readControl() & 0x0100);
    try testing.expectEqual(@as(u16, 0), vdp.readControlAdjusted(0x4E71) & 0x0100);
}

test "status read adjustment can observe buffered replay delay ending before the next instruction completes" {
    var vdp = Vdp.init();
    vdp.regs[12] = 0x81;
    vdp.code = 0x1;
    vdp.addr = 0x0000;
    vdp.scanline = 12;
    vdp.line_master_cycle = 0;
    vdp.transfer_line_master_cycle = 0;
    vdp.pending_port_write_delay_master_cycles = 5 * 8;
    vdp.pending_port_writes[0] = .{ .data = 0x1234 };
    vdp.pending_port_write_len = 1;

    try testing.expect(vdp.dataPortWriteWaitMasterCycles() > 0);
    try testing.expect(vdp.dataPortWriteWaitMasterCycles() <= clock.m68kCyclesToMaster(8));

    try testing.expectEqual(@as(u16, 0x0100), vdp.readControl() & 0x0100);
    try testing.expectEqual(@as(u16, 0), vdp.readControlAdjusted(0x4E71) & 0x0100);
}

test "status read adjustment can observe dma copy complete after the next access slot" {
    var vdp = Vdp.init();
    vdp.regs[12] = 0x81;
    vdp.scanline = 12;
    vdp.dma_active = true;
    vdp.dma_copy = true;
    vdp.dma_fill = false;
    vdp.dma_remaining = 1;
    vdp.dma_length = 1;

    const status_window = clock.m68kCyclesToMaster(8);
    var completion_wait: u32 = 0;
    var found_phase = false;
    var line_master_cycle: u16 = 0;
    while (line_master_cycle < vdp.hblankStartMasterCycles()) : (line_master_cycle += 1) {
        vdp.line_master_cycle = line_master_cycle;
        vdp.transfer_line_master_cycle = line_master_cycle;
        completion_wait = vdp.nextTransferStepMasterCycles();
        if (completion_wait > 0 and completion_wait <= status_window) {
            found_phase = true;
            break;
        }
    }

    try testing.expect(found_phase);

    try testing.expectEqual(@as(u16, 0x0002), vdp.readControl() & 0x0002);
    try testing.expectEqual(@as(u16, 0), vdp.readControlAdjusted(0x4E71) & 0x0002);
}

test "status read adjustment can observe dma fill complete after the next access slot" {
    var vdp = Vdp.init();
    vdp.regs[12] = 0x81;
    vdp.scanline = 12;
    vdp.code = 0x1;
    vdp.addr = 0x0020;
    vdp.dma_active = true;
    vdp.dma_fill = true;
    vdp.dma_copy = false;
    vdp.dma_fill_ready = true;
    vdp.dma_fill_word = 0xABCD;
    vdp.dma_length = 1;
    vdp.dma_remaining = 1;

    const status_window = clock.m68kCyclesToMaster(8);
    var completion_wait: u32 = 0;
    var found_phase = false;
    var line_master_cycle: u16 = 0;
    while (line_master_cycle < vdp.hblankStartMasterCycles()) : (line_master_cycle += 1) {
        vdp.line_master_cycle = line_master_cycle;
        vdp.transfer_line_master_cycle = line_master_cycle;
        completion_wait = vdp.nextTransferStepMasterCycles();
        if (completion_wait > 0 and completion_wait <= status_window) {
            found_phase = true;
            break;
        }
    }

    try testing.expect(found_phase);

    try testing.expectEqual(@as(u16, 0x0002), vdp.readControl() & 0x0002);
    try testing.expectEqual(@as(u16, 0), vdp.readControlAdjusted(0x4E71) & 0x0002);
}

test "HV counter advances to the next scanline at the H interrupt boundary" {
    var vdp = Vdp.init();
    vdp.regs[12] = 0x81;
    vdp.scanline = 0x22;

    const hint_boundary = vdp.hInterruptMasterCycles();
    vdp.line_master_cycle = hint_boundary - 1;
    try testing.expectEqual(@as(u8, 0x22), @as(u8, @truncate(vdp.readHVCounter() >> 8)));

    vdp.line_master_cycle = hint_boundary;
    try testing.expectEqual(@as(u8, 0x23), @as(u8, @truncate(vdp.readHVCounter() >> 8)));
}

test "power-on reset timing seeds the reference startup phase" {
    var ntsc = Vdp.init();
    ntsc.applyPowerOnResetTiming();
    try testing.expectEqual(@as(u16, 159), ntsc.scanline);
    try testing.expectEqual(@as(u16, 522), ntsc.line_master_cycle);
    try testing.expect(!ntsc.hblank);
    try testing.expect(!ntsc.vblank);
    try testing.expectEqual(ntsc.line_master_cycle, ntsc.transfer_line_master_cycle);

    var pal = Vdp.init();
    pal.pal_mode = true;
    pal.applyPowerOnResetTiming();
    try testing.expectEqual(@as(u16, 132), pal.scanline);
    try testing.expectEqual(@as(u16, 522), pal.line_master_cycle);
    try testing.expect(!pal.hblank);
    try testing.expect(!pal.vblank);
}

test "H40 HV counter matches reference single-cycle HSYNC edges" {
    var vdp = Vdp.init();
    vdp.regs[12] = 0x81;

    const checkpoints = [_]struct {
        line_master_cycle: u16,
        expected_h: u8,
    }{
        .{ .line_master_cycle = 2960, .expected_h = 0xE6 },
        .{ .line_master_cycle = 2961, .expected_h = 0xE7 },
        .{ .line_master_cycle = 2980, .expected_h = 0xE7 },
        .{ .line_master_cycle = 2981, .expected_h = 0xE8 },
        .{ .line_master_cycle = 3020, .expected_h = 0xE9 },
        .{ .line_master_cycle = 3021, .expected_h = 0xEA },
        .{ .line_master_cycle = 3038, .expected_h = 0xEA },
        .{ .line_master_cycle = 3039, .expected_h = 0xEB },
        .{ .line_master_cycle = 3136, .expected_h = 0xEF },
        .{ .line_master_cycle = 3137, .expected_h = 0xF0 },
        .{ .line_master_cycle = 3274, .expected_h = 0xF6 },
        .{ .line_master_cycle = 3275, .expected_h = 0xF7 },
    };

    for (checkpoints) |checkpoint| {
        vdp.line_master_cycle = checkpoint.line_master_cycle;
        try testing.expectEqual(checkpoint.expected_h, @as(u8, @truncate(vdp.readHVCounter())));
    }
}

test "stepping to the hblank boundary preserves the external hblank edge" {
    var vdp = Vdp.init();
    vdp.regs[0] = 0x02;
    vdp.regs[12] = 0x81;
    vdp.scanline = 0x22;

    vdp.step(vdp.hblankStartMasterCycles());
    try testing.expect(!vdp.hblank);
    try testing.expect(!vdp.hv_latched_valid);

    vdp.setHBlank(true);
    try testing.expect(vdp.hblank);
    try testing.expect(vdp.hv_latched_valid);
}

test "H40 line transitions rephase VDP transfer timing" {
    var vdp = Vdp.init();
    vdp.regs[12] = 0x81;

    vdp.setHBlank(true);
    vdp.progressTransfers(clock.ntsc_master_cycles_per_line - vdp.hblankStartMasterCycles(), null, null);
    try testing.expect(vdp.nextTransferStepMasterCycles() > vdp.accessSlotCycles());

    var fresh_active = Vdp.init();
    fresh_active.regs[12] = 0x81;
    _ = vdp.setScanlineState(1, clock.ntsc_visible_lines, clock.ntsc_lines_per_frame);
    vdp.setHBlank(false);
    _ = fresh_active.setScanlineState(1, clock.ntsc_visible_lines, clock.ntsc_lines_per_frame);
    fresh_active.setHBlank(false);
    try testing.expectEqual(fresh_active.nextTransferStepMasterCycles(), vdp.nextTransferStepMasterCycles());

    var fresh_hblank = Vdp.init();
    fresh_hblank.regs[12] = 0x81;
    fresh_hblank.step(fresh_hblank.hblankStartMasterCycles());
    vdp.progressTransfers(vdp.hblankStartMasterCycles(), null, null);
    vdp.step(vdp.hblankStartMasterCycles());
    vdp.setHBlank(true);
    fresh_hblank.setHBlank(true);
    try testing.expectEqual(fresh_hblank.nextTransferStepMasterCycles(), vdp.nextTransferStepMasterCycles());
}
