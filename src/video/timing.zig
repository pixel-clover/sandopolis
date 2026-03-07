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

fn activeVisibleLines(self: *const Vdp) u16 {
    if (!self.pal_mode) return clock.ntsc_visible_lines;
    return if ((self.regs[1] & 0x08) != 0) clock.pal_visible_lines else clock.ntsc_visible_lines;
}

fn totalLinesForCurrentFrame(self: *const Vdp) u16 {
    if (!self.isInterlaceMode2()) {
        return if (self.pal_mode) clock.pal_lines_per_frame else clock.ntsc_lines_per_frame;
    }

    if (self.pal_mode) {
        return if (self.odd_frame) clock.pal_lines_per_frame else clock.pal_lines_per_frame - 1;
    }

    return if (self.odd_frame) clock.ntsc_lines_per_frame + 1 else clock.ntsc_lines_per_frame;
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

fn computeHCounterFor(self: *const Vdp, line_master_cycle: u16) u8 {
    const internal_h = internalHFor(self, line_master_cycle);
    return @truncate(internal_h >> 1);
}

fn vintFlagForAdjustedState(self: *const Vdp, adjusted: AdjustedLineState) bool {
    if (self.vint_pending) return true;

    const current = adjustedLineState(self, 0);
    return !current.vblank and adjusted.vblank;
}

fn statusWordForAdjustedState(self: *const Vdp, adjusted: AdjustedLineState) u16 {
    var status: u16 = 0;

    if (fifo.fifoIsEmpty(self)) status |= 0x0200;
    if (fifo.fifoIsFull(self)) status |= 0x0100;

    if (adjusted.vblank or !self.isDisplayEnabled()) status |= 0x0008;
    if (adjusted.hblank) status |= 0x0004;
    if (self.dma_active) status |= 0x0002;
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

// -- Control port read --

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

// -- HV counter --

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

// -- Timing state --

pub fn step(self: *Vdp, cycles: u32) void {
    const total = @as(u32, self.line_master_cycle) + cycles;
    self.line_master_cycle = @intCast(total % clock.ntsc_master_cycles_per_line);
    self.hblank = self.line_master_cycle >= hblankStartMasterCycles(self);
}

pub fn setScanlineState(self: *Vdp, line: u16, visible_lines: u16, total_lines: u16) bool {
    if (line != self.scanline) {
        self.line_master_cycle = 0;
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

pub fn consumeHintForLine(self: *Vdp, line: u16, visible_lines: u16) bool {
    if (line >= visible_lines) return false;
    self.hint_counter -= 1;
    if (self.hint_counter < 0) {
        self.hint_counter = @intCast(self.regs[10]);
        return (self.regs[0] & 0x10) != 0;
    }
    return false;
}
