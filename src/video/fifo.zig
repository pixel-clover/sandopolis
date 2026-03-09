const std = @import("std");
const testing = std.testing;
const clock = @import("../clock.zig");
const Vdp = @import("vdp.zig").Vdp;

const dma_fifo_latency_slots: u8 = 3;
const pending_port_write_replay_delay_pixels: u16 = 5;
const h32_access_slots = [_]u8{ 5, 13, 21, 37, 45, 53, 69, 77, 85, 101, 109, 117, 132, 133, 147, 161 };
const h40_access_slots = [_]u8{ 6, 14, 22, 38, 46, 54, 70, 78, 86, 102, 110, 118, 134, 142, 150, 165, 166, 190 };
const h32_refresh_slots = [_]u8{ 1, 33, 65, 97, 129 };
const h40_refresh_slots = [_]u8{ 26, 58, 90, 122, 154, 204 };
const h32_slot_count: u16 = 171;
const h40_slot_count: u16 = 210;
const h40_hsync_slot_start: u16 = 184;
const h40_hsync_slot_count: u16 = 17;
const h40_hsync_slot_base_master: u16 = 2944;
const h40_hsync_pattern_master: u16 = 166;
const h40_hsync_end_master: u16 = 3276;

const TransferPhaseState = struct {
    scanline: u16,
    line_master_cycle: u16,
    hblank: bool,
    odd_frame: bool,
};

const TransferPhaseBoundary = enum {
    hblank_start,
    line_end,
};

const TransferPhaseBoundaryEvent = struct {
    kind: TransferPhaseBoundary,
    wait_master_cycles: u32,
};

pub fn fifoIsEmpty(self: *const Vdp) bool {
    return self.fifo_len == 0;
}

pub fn fifoIsFull(self: *const Vdp) bool {
    return @as(usize, self.fifo_len) >= self.fifo.len;
}

fn pendingFifoIsEmpty(self: *const Vdp) bool {
    return self.pending_fifo_len == 0;
}

fn pendingFifoIsFull(self: *const Vdp) bool {
    return @as(usize, self.pending_fifo_len) >= self.pending_fifo.len;
}

fn makeWriteFifoEntry(self: *const Vdp, value: u16, latency: u8) Vdp.VdpWriteFifoEntry {
    return .{
        .code = self.code,
        .addr = self.addr,
        .word = value,
        .latency = latency,
        .second_service_pending = false,
    };
}

fn fifoPush(self: *Vdp, entry: Vdp.VdpWriteFifoEntry) void {
    if (fifoIsFull(self)) return;

    const tail: usize = (@as(usize, self.fifo_head) + @as(usize, self.fifo_len)) % self.fifo.len;
    self.fifo[tail] = entry;
    self.fifo_len += 1;
}

fn pendingFifoPush(self: *Vdp, entry: Vdp.VdpWriteFifoEntry) void {
    if (pendingFifoIsFull(self)) return;

    const tail: usize = (@as(usize, self.pending_fifo_head) + @as(usize, self.pending_fifo_len)) % self.pending_fifo.len;
    self.pending_fifo[tail] = entry;
    self.pending_fifo_len += 1;
}

fn fifoFront(self: *Vdp) *Vdp.VdpWriteFifoEntry {
    return &self.fifo[self.fifo_head];
}

fn pendingFifoFront(self: *Vdp) *Vdp.VdpWriteFifoEntry {
    return &self.pending_fifo[self.pending_fifo_head];
}

fn fifoPop(self: *Vdp) void {
    if (fifoIsEmpty(self)) return;

    self.fifo_head = @intCast((@as(usize, self.fifo_head) + 1) % self.fifo.len);
    self.fifo_len -= 1;
}

fn pendingFifoPop(self: *Vdp) void {
    if (pendingFifoIsEmpty(self)) return;

    self.pending_fifo_head = @intCast((@as(usize, self.pending_fifo_head) + 1) % self.pending_fifo.len);
    self.pending_fifo_len -= 1;
}

fn pendingPortWritesIsEmpty(self: *const Vdp) bool {
    return self.pending_port_write_len == 0;
}

fn pendingPortWritesIsFull(self: *const Vdp) bool {
    return @as(usize, self.pending_port_write_len) >= self.pending_port_writes.len;
}

pub fn shouldBufferPortWrite(self: *const Vdp) bool {
    return (self.dma_active and !self.dma_fill and !self.dma_copy) or
        self.pending_port_write_delay_master_cycles != 0;
}

fn pushPendingPortWrite(self: *Vdp, write: Vdp.PendingPortWrite) void {
    if (pendingPortWritesIsFull(self)) return;

    const tail: usize = (@as(usize, self.pending_port_write_head) + @as(usize, self.pending_port_write_len)) % self.pending_port_writes.len;
    self.pending_port_writes[tail] = write;
    self.pending_port_write_len += 1;
}

fn popPendingPortWrite(self: *Vdp) ?Vdp.PendingPortWrite {
    if (pendingPortWritesIsEmpty(self)) return null;

    const write = self.pending_port_writes[self.pending_port_write_head];
    self.pending_port_write_head = @intCast((@as(usize, self.pending_port_write_head) + 1) % self.pending_port_writes.len);
    self.pending_port_write_len -= 1;
    return write;
}

fn advanceTransferCursor(self: *Vdp, master_cycles: u32) void {
    self.transfer_line_master_cycle +%= @intCast(master_cycles);
}

fn slotIndexInSet(slot_idx: u16, comptime slot_set: []const u8) bool {
    inline for (slot_set) |set_idx| {
        if (slot_idx == set_idx) return true;
    }
    return false;
}

fn transferSlotCount(self: *const Vdp) u16 {
    return if (self.isH40()) h40_slot_count else h32_slot_count;
}

fn h40PixelStartMasterCycles(pixel: u16) u16 {
    if (pixel < h40_hsync_slot_start * 2) return pixel * 8;
    if (pixel >= 402) return h40_hsync_end_master + ((pixel - 402) * 8);

    const hsync_pixel = pixel - (h40_hsync_slot_start * 2);
    const pattern = hsync_pixel / 17;
    const pattern_pixel = hsync_pixel % 17;
    const pattern_base = pattern * h40_hsync_pattern_master;
    const pixel_offset = switch (pattern_pixel) {
        0 => 0,
        1...8 => 8 + ((pattern_pixel - 1) * 10),
        9...10 => 87 + ((pattern_pixel - 9) * 9),
        else => 106 + ((pattern_pixel - 11) * 10),
    };
    return h40_hsync_slot_base_master + pattern_base + pixel_offset;
}

fn transferSlotStartMasterCycles(self: *const Vdp, slot_idx: u16) u16 {
    if (!self.isH40()) return slot_idx * 20;
    return h40PixelStartMasterCycles(slot_idx * 2);
}

fn transferSlotEndMasterCycles(self: *const Vdp, slot_idx: u16) u16 {
    const next_slot = slot_idx + 1;
    if (next_slot < transferSlotCount(self)) return transferSlotStartMasterCycles(self, next_slot);
    return clock.ntsc_master_cycles_per_line;
}

fn transferSlotIsRefresh(self: *const Vdp, slot_idx: u16) bool {
    return if (self.isH40())
        slotIndexInSet(slot_idx, &h40_refresh_slots)
    else
        slotIndexInSet(slot_idx, &h32_refresh_slots);
}

fn transferSlotIsAccess(self: *const Vdp, slot_idx: u16, blanking: bool) bool {
    if (blanking) return !transferSlotIsRefresh(self, slot_idx);
    return if (self.isH40())
        slotIndexInSet(slot_idx, &h40_access_slots)
    else
        slotIndexInSet(slot_idx, &h32_access_slots);
}

fn activeVisibleLinesForPhase(self: *const Vdp) u16 {
    if (!self.pal_mode) return clock.ntsc_visible_lines;
    return if ((self.regs[1] & 0x08) != 0) clock.pal_visible_lines else clock.ntsc_visible_lines;
}

fn totalLinesForOddFrame(self: *const Vdp, odd_frame: bool) u16 {
    if ((self.regs[12] & 0x06) != 0x06) {
        return if (self.pal_mode) clock.pal_lines_per_frame else clock.ntsc_lines_per_frame;
    }

    if (self.pal_mode) {
        return if (odd_frame) clock.pal_lines_per_frame else clock.pal_lines_per_frame - 1;
    }

    return if (odd_frame) clock.ntsc_lines_per_frame + 1 else clock.ntsc_lines_per_frame;
}

fn phaseIsVBlank(self: *const Vdp, phase: TransferPhaseState) bool {
    return phase.scanline >= activeVisibleLinesForPhase(self);
}

fn phaseIsBlanking(self: *const Vdp, phase: TransferPhaseState) bool {
    return phaseIsVBlank(self, phase) or phase.hblank;
}

fn currentTransferPhase(self: *const Vdp) TransferPhaseState {
    return .{
        .scanline = self.scanline,
        .line_master_cycle = self.transfer_line_master_cycle,
        .hblank = self.hblank,
        .odd_frame = self.odd_frame,
    };
}

fn projectedTransferPhase(self: *const Vdp) TransferPhaseState {
    const projected = &self.projected_data_port_write_wait;
    return .{
        .scanline = projected.transfer_scanline,
        .line_master_cycle = projected.transfer_line_master_cycle,
        .hblank = projected.transfer_hblank,
        .odd_frame = projected.transfer_odd_frame,
    };
}

fn storeProjectedTransferPhase(self: *Vdp, phase: TransferPhaseState) void {
    self.projected_data_port_write_wait.transfer_scanline = phase.scanline;
    self.projected_data_port_write_wait.transfer_line_master_cycle = phase.line_master_cycle;
    self.projected_data_port_write_wait.transfer_hblank = phase.hblank;
    self.projected_data_port_write_wait.transfer_odd_frame = phase.odd_frame;
}

fn nextTransferPhaseBoundary(self: *const Vdp, phase: TransferPhaseState) TransferPhaseBoundaryEvent {
    const line_end_wait = clock.ntsc_master_cycles_per_line - phase.line_master_cycle;
    if (!phase.hblank and !phaseIsVBlank(self, phase)) {
        const hblank_start = self.hblankStartMasterCycles();
        if (phase.line_master_cycle < hblank_start) {
            return .{
                .kind = .hblank_start,
                .wait_master_cycles = hblank_start - phase.line_master_cycle,
            };
        }
    }

    return .{
        .kind = .line_end,
        .wait_master_cycles = line_end_wait,
    };
}

fn applyTransferPhaseBoundary(self: *const Vdp, phase: *TransferPhaseState, boundary: TransferPhaseBoundary) void {
    switch (boundary) {
        .hblank_start => {
            phase.line_master_cycle = self.hblankStartMasterCycles();
            phase.hblank = true;
        },
        .line_end => {
            const total_lines = totalLinesForOddFrame(self, phase.odd_frame);
            phase.scanline += 1;
            if (phase.scanline >= total_lines) {
                phase.scanline = 0;
                phase.odd_frame = !phase.odd_frame;
            }
            phase.line_master_cycle = 0;
            phase.hblank = false;
        },
    }
}

fn advanceTransferPhaseState(self: *const Vdp, phase: *TransferPhaseState, master_cycles: u32) void {
    var remaining = master_cycles;
    while (remaining != 0) {
        const boundary = nextTransferPhaseBoundary(self, phase.*);
        if (remaining < boundary.wait_master_cycles) {
            phase.line_master_cycle += @intCast(remaining);
            return;
        }

        remaining -= boundary.wait_master_cycles;
        applyTransferPhaseBoundary(self, phase, boundary.kind);
    }
}

const TransferEvent = struct {
    slot_idx: u16,
    wait_master_cycles: u32,
};

fn nextTransferEventForState(self: *const Vdp, line_master_cycle: u16, blanking: bool, needs_non_refresh: bool, needs_access_only: bool) ?TransferEvent {
    var slot_idx: u16 = 0;
    while (slot_idx < transferSlotCount(self)) : (slot_idx += 1) {
        const slot_end = transferSlotEndMasterCycles(self, slot_idx);
        if (slot_end <= line_master_cycle) continue;

        const is_refresh = transferSlotIsRefresh(self, slot_idx);
        const has_non_refresh_effect = needs_non_refresh and !is_refresh;
        const has_access_effect = needs_access_only and transferSlotIsAccess(self, slot_idx, blanking);
        if (has_non_refresh_effect or has_access_effect) {
            return .{
                .slot_idx = slot_idx,
                .wait_master_cycles = slot_end - line_master_cycle,
            };
        }
    }

    return null;
}

fn nextTransferStepForState(self: *const Vdp, line_master_cycle: u16, blanking: bool) u32 {
    const needs_non_refresh = (self.dma_active and !self.dma_fill and !self.dma_copy) or
        !fifoIsEmpty(self) or
        !pendingFifoIsEmpty(self);
    const needs_access_only = self.dma_copy;
    const event = nextTransferEventForState(self, line_master_cycle, blanking, needs_non_refresh, needs_access_only) orelse
        return clock.ntsc_master_cycles_per_line - line_master_cycle;
    return event.wait_master_cycles;
}

pub fn nextTransferStepMasterCycles(self: *const Vdp) u32 {
    return nextTransferStepForState(self, self.transfer_line_master_cycle, self.vblank or self.hblank);
}

fn pendingPortWriteReplayDelayMasterCycles(self: *const Vdp) u16 {
    const master_cycles_per_pixel: u16 = if (self.isH40()) 8 else 10;
    return pending_port_write_replay_delay_pixels * master_cycles_per_pixel;
}

fn memoryToVramDmaStartDelaySlots(self: *const Vdp) u8 {
    return if ((self.code & 0xF) == 0x5) 5 else 8;
}

fn invalidateProjectedDataPortWriteWait(self: *Vdp) void {
    self.projected_data_port_write_wait.valid = false;
}

pub fn resetTransferPhase(self: *Vdp) void {
    self.transfer_line_master_cycle = self.line_master_cycle;
    invalidateProjectedDataPortWriteWait(self);
}

fn entryRequiresSecondService(code: u8) bool {
    return switch (code & 0xF) {
        0x3, 0x5 => false,
        else => true,
    };
}

fn makeProjectedFifoEntry(entry: Vdp.VdpWriteFifoEntry) Vdp.ProjectedFifoEntry {
    return .{
        .latency = entry.latency,
        .requires_second_service = entryRequiresSecondService(entry.code),
        .second_service_pending = entry.second_service_pending,
    };
}

fn shiftSimEntriesLeft(entries: []Vdp.ProjectedFifoEntry, len: *u8) void {
    if (len.* == 0) return;

    var i: usize = 1;
    while (i < @as(usize, len.*)) : (i += 1) {
        entries[i - 1] = entries[i];
    }
    len.* -= 1;
}

fn moveSimPendingIntoFifo(fifo_entries: []Vdp.ProjectedFifoEntry, fifo_len: *u8, pending_entries: []Vdp.ProjectedFifoEntry, pending_len: *u8) void {
    if (pending_len.* == 0 or @as(usize, fifo_len.*) >= fifo_entries.len) return;

    fifo_entries[@as(usize, fifo_len.*)] = pending_entries[0];
    fifo_len.* += 1;
    shiftSimEntriesLeft(pending_entries, pending_len);
}

fn processSimAccessSlot(fifo_entries: []Vdp.ProjectedFifoEntry, fifo_len: *u8, pending_entries: []Vdp.ProjectedFifoEntry, pending_len: *u8) void {
    if (fifo_len.* == 0 or fifo_entries[0].latency != 0) return;

    if (fifo_entries[0].requires_second_service and !fifo_entries[0].second_service_pending) {
        fifo_entries[0].second_service_pending = true;
        return;
    }

    shiftSimEntriesLeft(fifo_entries, fifo_len);
    moveSimPendingIntoFifo(fifo_entries, fifo_len, pending_entries, pending_len);
}

fn tickSimLatency(fifo_entries: []Vdp.ProjectedFifoEntry, fifo_len: u8) void {
    var i: usize = 0;
    while (i < @as(usize, fifo_len)) : (i += 1) {
        if (fifo_entries[i].latency > 0) {
            fifo_entries[i].latency -= 1;
        }
    }
}

fn processSimTransferSlot(self: *const Vdp, slot_idx: u16, blanking: bool, fifo_entries: []Vdp.ProjectedFifoEntry, fifo_len: *u8, pending_entries: []Vdp.ProjectedFifoEntry, pending_len: *u8) void {
    if (transferSlotIsRefresh(self, slot_idx)) return;

    tickSimLatency(fifo_entries, fifo_len.*);
    if (transferSlotIsAccess(self, slot_idx, blanking)) {
        processSimAccessSlot(fifo_entries, fifo_len, pending_entries, pending_len);
    }
}

fn snapshotSimFifos(self: *const Vdp, fifo_entries: []Vdp.ProjectedFifoEntry, fifo_len: *u8, pending_entries: []Vdp.ProjectedFifoEntry, pending_len: *u8) void {
    fifo_len.* = 0;
    pending_len.* = 0;

    var i: usize = 0;
    while (i < @as(usize, self.fifo_len)) : (i += 1) {
        const idx = (@as(usize, self.fifo_head) + i) % self.fifo.len;
        fifo_entries[i] = makeProjectedFifoEntry(self.fifo[idx]);
        fifo_len.* += 1;
    }

    i = 0;
    while (i < @as(usize, self.pending_fifo_len)) : (i += 1) {
        const idx = (@as(usize, self.pending_fifo_head) + i) % self.pending_fifo.len;
        pending_entries[i] = makeProjectedFifoEntry(self.pending_fifo[idx]);
        pending_len.* += 1;
    }
}

fn syncProjectedDataPortWriteWait(self: *Vdp) void {
    if (self.projected_data_port_write_wait.valid) return;

    const phase = currentTransferPhase(self);
    self.projected_data_port_write_wait = .{
        .valid = true,
        .transfer_scanline = phase.scanline,
        .transfer_line_master_cycle = phase.line_master_cycle,
        .transfer_hblank = phase.hblank,
        .transfer_odd_frame = phase.odd_frame,
        .pending_port_write_delay_master_cycles = self.pending_port_write_delay_master_cycles,
    };
    snapshotSimFifos(
        self,
        self.projected_data_port_write_wait.fifo_entries[0..],
        &self.projected_data_port_write_wait.fifo_len,
        self.projected_data_port_write_wait.pending_fifo_entries[0..],
        &self.projected_data_port_write_wait.pending_fifo_len,
    );
}

fn projectedDataPortWriteHasRoom(self: *const Vdp) bool {
    const projected = &self.projected_data_port_write_wait;
    return projected.pending_fifo_len == 0 and @as(usize, projected.fifo_len) < self.fifo.len;
}

fn projectedAdvanceTransferPhase(self: *Vdp, master_cycles: u32) void {
    var phase = projectedTransferPhase(self);
    advanceTransferPhaseState(self, &phase, master_cycles);
    storeProjectedTransferPhase(self, phase);
}

fn projectedProcessTransferSlot(self: *Vdp, slot_idx: u16, blanking: bool) void {
    const projected = &self.projected_data_port_write_wait;
    processSimTransferSlot(
        self,
        slot_idx,
        blanking,
        projected.fifo_entries[0..],
        &projected.fifo_len,
        projected.pending_fifo_entries[0..],
        &projected.pending_fifo_len,
    );
}

fn reserveProjectedDataPortWriteWait(self: *Vdp) u32 {
    syncProjectedDataPortWriteWait(self);

    var wait_master_cycles: u32 = 0;
    while (!projectedDataPortWriteHasRoom(self)) {
        const projected = &self.projected_data_port_write_wait;
        var phase = projectedTransferPhase(self);

        if (projected.pending_port_write_delay_master_cycles != 0) {
            wait_master_cycles += projected.pending_port_write_delay_master_cycles;
            projectedAdvanceTransferPhase(self, projected.pending_port_write_delay_master_cycles);
            projected.pending_port_write_delay_master_cycles = 0;
            continue;
        }

        const boundary = nextTransferPhaseBoundary(self, phase);
        const event = nextTransferEventForState(self, phase.line_master_cycle, phaseIsBlanking(self, phase), true, false);
        if (event) |slot_event| {
            if (slot_event.wait_master_cycles <= boundary.wait_master_cycles) {
                wait_master_cycles += slot_event.wait_master_cycles;
                phase.line_master_cycle += @intCast(slot_event.wait_master_cycles);
                storeProjectedTransferPhase(self, phase);
                projectedProcessTransferSlot(self, slot_event.slot_idx, phaseIsBlanking(self, phase));
                if (slot_event.wait_master_cycles == boundary.wait_master_cycles) {
                    phase = projectedTransferPhase(self);
                    applyTransferPhaseBoundary(self, &phase, boundary.kind);
                    storeProjectedTransferPhase(self, phase);
                }
                continue;
            }
        }

        wait_master_cycles += boundary.wait_master_cycles;
        advanceTransferPhaseState(self, &phase, boundary.wait_master_cycles);
        storeProjectedTransferPhase(self, phase);
    }

    const projected = &self.projected_data_port_write_wait;
    projected.fifo_entries[@as(usize, projected.fifo_len)] = .{
        .latency = dma_fifo_latency_slots,
        .requires_second_service = entryRequiresSecondService(self.code),
        .second_service_pending = false,
    };
    projected.fifo_len += 1;
    return wait_master_cycles;
}

fn fifoTickLatency(self: *Vdp) void {
    var i: usize = 0;
    while (i < @as(usize, self.fifo_len)) : (i += 1) {
        const idx = (@as(usize, self.fifo_head) + i) % self.fifo.len;
        if (self.fifo[idx].latency > 0) {
            self.fifo[idx].latency -= 1;
        }
    }
}

fn fifoWaitUntilNextOpen(self: *const Vdp) u32 {
    var fifo_entries = [_]Vdp.ProjectedFifoEntry{.{}} ** 4;
    var pending_entries = [_]Vdp.ProjectedFifoEntry{.{}} ** 16;
    var fifo_len: u8 = 0;
    var pending_len: u8 = 0;
    snapshotSimFifos(self, fifo_entries[0..], &fifo_len, pending_entries[0..], &pending_len);

    if (pending_len == 0 and @as(usize, fifo_len) < fifo_entries.len) return 0;

    var wait_master_cycles: u32 = 0;
    var phase = currentTransferPhase(self);

    while (true) {
        const boundary = nextTransferPhaseBoundary(self, phase);
        const event = nextTransferEventForState(self, phase.line_master_cycle, phaseIsBlanking(self, phase), true, false);
        if (event) |slot_event| {
            if (slot_event.wait_master_cycles <= boundary.wait_master_cycles) {
                wait_master_cycles += slot_event.wait_master_cycles;
                phase.line_master_cycle += @intCast(slot_event.wait_master_cycles);
                processSimTransferSlot(self, slot_event.slot_idx, phaseIsBlanking(self, phase), fifo_entries[0..], &fifo_len, pending_entries[0..], &pending_len);
                if (pending_len == 0 and @as(usize, fifo_len) < fifo_entries.len) return wait_master_cycles;
                if (slot_event.wait_master_cycles == boundary.wait_master_cycles) {
                    applyTransferPhaseBoundary(self, &phase, boundary.kind);
                }
                continue;
            }
        }

        wait_master_cycles += boundary.wait_master_cycles;
        applyTransferPhaseBoundary(self, &phase, boundary.kind);
        if (pending_len == 0 and @as(usize, fifo_len) < fifo_entries.len) return wait_master_cycles;
    }
}

fn fifoWaitUntilDrained(self: *const Vdp) u32 {
    var fifo_entries = [_]Vdp.ProjectedFifoEntry{.{}} ** 4;
    var pending_entries = [_]Vdp.ProjectedFifoEntry{.{}} ** 16;
    var fifo_len: u8 = 0;
    var pending_len: u8 = 0;
    snapshotSimFifos(self, fifo_entries[0..], &fifo_len, pending_entries[0..], &pending_len);

    var phase = currentTransferPhase(self);
    var wait_master_cycles: u32 = 0;
    while (fifo_len != 0 or pending_len != 0) {
        const boundary = nextTransferPhaseBoundary(self, phase);
        const event = nextTransferEventForState(self, phase.line_master_cycle, phaseIsBlanking(self, phase), true, false);
        if (event) |slot_event| {
            if (slot_event.wait_master_cycles <= boundary.wait_master_cycles) {
                wait_master_cycles += slot_event.wait_master_cycles;
                phase.line_master_cycle += @intCast(slot_event.wait_master_cycles);
                processSimTransferSlot(self, slot_event.slot_idx, phaseIsBlanking(self, phase), fifo_entries[0..], &fifo_len, pending_entries[0..], &pending_len);
                if (slot_event.wait_master_cycles == boundary.wait_master_cycles) {
                    applyTransferPhaseBoundary(self, &phase, boundary.kind);
                }
                continue;
            }
        }

        wait_master_cycles += boundary.wait_master_cycles;
        applyTransferPhaseBoundary(self, &phase, boundary.kind);
    }

    return wait_master_cycles;
}

fn dataPortReadTargetFor(code: u8, addr: u16) ?Vdp.DataPortReadTarget {
    switch (code & 0xF) {
        0x0 => {
            const high_index = addr ^ 1;
            return .{
                .storage = .vram,
                .high_index = high_index,
                .low_index = high_index ^ 1,
            };
        },
        0x8 => {
            const idx = addr & 0x7E;
            return .{
                .storage = .cram,
                .high_index = idx,
                .low_index = idx + 1,
            };
        },
        0x4 => {
            const idx: u16 = (addr >> 1) % 40 * 2;
            return .{
                .storage = .vsram,
                .high_index = idx,
                .low_index = idx + 1,
            };
        },
        else => return null,
    }
}

fn currentDataPortReadWord(self: *const Vdp, code: u8, addr: u16) ?u16 {
    const target = dataPortReadTargetFor(code, addr) orelse return null;
    const high: u8 = switch (target.storage) {
        .vram => self.vramReadByte(target.high_index),
        .cram => self.cram[target.high_index],
        .vsram => self.vsram[target.high_index],
    };
    const low: u8 = switch (target.storage) {
        .vram => self.vramReadByte(target.low_index),
        .cram => self.cram[target.low_index],
        .vsram => self.vsram[target.low_index],
    };
    return (@as(u16, high) << 8) | low;
}

fn applyQueuedWriteToDataPortReadTarget(target: Vdp.DataPortReadTarget, high: *u8, low: *u8, write_storage: Vdp.DataPortReadStorage, write_base: u16, value: u16) void {
    if (target.storage != write_storage) return;

    const write_high: u8 = @intCast((value >> 8) & 0xFF);
    const write_low: u8 = @intCast(value & 0xFF);
    const write_next = write_base +% 1;

    if (target.high_index == write_base) {
        high.* = write_high;
    } else if (target.high_index == write_next) {
        high.* = write_low;
    }

    if (target.low_index == write_base) {
        low.* = write_high;
    } else if (target.low_index == write_next) {
        low.* = write_low;
    }
}

fn applyQueuedEntryToDataPortReadTarget(target: Vdp.DataPortReadTarget, high: *u8, low: *u8, entry: Vdp.VdpWriteFifoEntry) void {
    switch (entry.code & 0xF) {
        0x1 => applyQueuedWriteToDataPortReadTarget(target, high, low, .vram, entry.addr, entry.word),
        0x3 => applyQueuedWriteToDataPortReadTarget(target, high, low, .cram, entry.addr & 0x7E, entry.word),
        0x5 => applyQueuedWriteToDataPortReadTarget(target, high, low, .vsram, (entry.addr >> 1) % 40 * 2, entry.word),
        else => {},
    }
}

fn currentDataPortReadWordWithQueuedWrites(self: *const Vdp, code: u8, addr: u16) ?u16 {
    const target = dataPortReadTargetFor(code, addr) orelse return null;
    var high: u8 = undefined;
    var low: u8 = undefined;

    const base = currentDataPortReadWord(self, code, addr) orelse return null;
    high = @intCast((base >> 8) & 0xFF);
    low = @intCast(base & 0xFF);

    var i: usize = 0;
    while (i < @as(usize, self.fifo_len)) : (i += 1) {
        const idx = (@as(usize, self.fifo_head) + i) % self.fifo.len;
        applyQueuedEntryToDataPortReadTarget(target, &high, &low, self.fifo[idx]);
    }

    i = 0;
    while (i < @as(usize, self.pending_fifo_len)) : (i += 1) {
        const idx = (@as(usize, self.pending_fifo_head) + i) % self.pending_fifo.len;
        applyQueuedEntryToDataPortReadTarget(target, &high, &low, self.pending_fifo[idx]);
    }

    return (@as(u16, high) << 8) | low;
}

pub fn readData(self: *Vdp) u16 {
    self.pending_command = false;
    const result = self.read_buffer;

    if (currentDataPortReadWordWithQueuedWrites(self, self.code, self.addr)) |word| {
        self.read_buffer = word;
    }

    advanceAddr(self);
    return result;
}

fn writeTargetWord(self: *Vdp, code: u8, addr: u16, value: u16) void {
    switch (code & 0xF) {
        0x1 => {
            self.dbg_vram_writes += 1;
            self.vramWriteByte(addr, @intCast((value >> 8) & 0xFF));
            self.vramWriteByte(addr +% 1, @intCast(value & 0xFF));
        },
        0x3 => {
            self.dbg_cram_writes += 1;
            const idx = addr & 0x7E;
            self.cram[idx] = @intCast((value >> 8) & 0xFF);
            self.cram[idx + 1] = @intCast(value & 0xFF);
        },
        0x5 => {
            self.dbg_vsram_writes += 1;
            const idx: u16 = (addr >> 1) % 40 * 2;
            self.vsram[idx] = @intCast((value >> 8) & 0xFF);
            self.vsram[idx + 1] = @intCast(value & 0xFF);
        },
        else => {
            self.dbg_unknown_writes += 1;
        },
    }
}

pub fn writeData(self: *Vdp, value: u16) void {
    if (shouldBufferPortWrite(self)) {
        pushPendingPortWrite(self, .{ .data = value });
        return;
    }

    self.pending_command = false;

    if (self.dma_active and self.dma_fill) {
        var len: u32 = self.dma_length;
        if (len == 0) len = 0x10000;
        const target = self.code & 0xF;
        if (target == 0x1) {
            const fill_byte: u8 = @intCast((value >> 8) & 0xFF);
            while (len > 0) : (len -= 1) {
                self.vramWriteByte(self.addr ^ 1, fill_byte);
                advanceAddr(self);
            }
        } else if (target == 0x3) {
            while (len > 0) : (len -= 1) {
                const idx = self.addr & 0x7E;
                self.cram[idx] = @intCast((value >> 8) & 0xFF);
                self.cram[idx + 1] = @intCast(value & 0xFF);
                advanceAddr(self);
            }
        } else if (target == 0x5) {
            while (len > 0) : (len -= 1) {
                const idx: u16 = (self.addr >> 1) % 40 * 2;
                self.vsram[idx] = @intCast((value >> 8) & 0xFF);
                self.vsram[idx + 1] = @intCast(value & 0xFF);
                advanceAddr(self);
            }
        }
        self.dma_length = 0;
        self.dma_remaining = 0;
        self.dma_fill = false;
        self.dma_active = false;
        self.dma_start_delay_slots = 0;
        self.fifo_head = 0;
        self.fifo_len = 0;
        self.pending_fifo_head = 0;
        self.pending_fifo_len = 0;
        return;
    }

    const entry = makeWriteFifoEntry(self, value, dma_fifo_latency_slots);
    if (fifoIsFull(self)) {
        pendingFifoPush(self, entry);
    } else {
        fifoPush(self, entry);
    }
    advanceAddr(self);
}

pub fn advanceAddr(self: *Vdp) void {
    const auto_inc = self.regs[15];
    self.addr = self.addr +% auto_inc;
}

fn finishDmaIfIdle(self: *Vdp) void {
    if (self.dma_remaining != 0 or !fifoIsEmpty(self)) return;

    self.dma_length = 0;
    self.dma_active = false;
    self.dma_fill = false;
    self.dma_copy = false;
    self.dma_start_delay_slots = 0;
    if (!pendingPortWritesIsEmpty(self)) {
        self.pending_port_write_delay_master_cycles = pendingPortWriteReplayDelayMasterCycles(self);
    }
}

fn progressMemoryToVramDmaReadSlot(self: *Vdp, slot_idx: u16, read_ctx: ?*anyopaque, read_word: Vdp.DmaReadFn) void {
    var can_transfer = true;
    if (self.dma_start_delay_slots != 0) {
        self.dma_start_delay_slots -= 1;
        can_transfer = self.dma_start_delay_slots == 0;
    }

    if (!can_transfer or fifoIsFull(self) or self.dma_remaining == 0) return;
    if (slot_idx != 0 and transferSlotIsRefresh(self, slot_idx - 1)) return;

    const word = read_word(read_ctx, self.dma_source_addr);
    const entry = makeWriteFifoEntry(self, word, dma_fifo_latency_slots);
    self.dma_source_addr +%= 2;
    self.dma_remaining -= 1;
    fifoPush(self, entry);
    advanceAddr(self);
}

fn progressVramCopyDma(self: *Vdp, access_slots: u32) void {
    if (self.dma_remaining == 0) {
        finishDmaIfIdle(self);
        return;
    }

    var budget = access_slots;
    if (budget > self.dma_remaining) budget = self.dma_remaining;

    var copied: u32 = 0;
    while (copied < budget) : (copied += 1) {
        const src_addr: u16 = @truncate(self.dma_source_addr);
        const byte = self.vram[@as(usize, src_addr)];
        self.vramWriteByte(self.addr, byte);
        self.dma_source_addr +%= 1;
        advanceAddr(self);
    }

    self.dma_remaining -= copied;
    finishDmaIfIdle(self);
}

fn serviceAccessSlot(self: *Vdp) void {
    if (!fifoIsEmpty(self)) {
        serviceFifoFront(self);
        if (!fifoIsFull(self) and !pendingFifoIsEmpty(self)) {
            const pending = pendingFifoFront(self).*;
            pendingFifoPop(self);
            fifoPush(self, pending);
        }
        return;
    }

    if (self.dma_active and self.dma_copy) {
        progressVramCopyDma(self, 1);
    }
}

fn serviceFifoFront(self: *Vdp) void {
    if (fifoIsEmpty(self)) return;

    const entry = fifoFront(self);
    if (entry.latency != 0) return;

    const committed = entry.*;
    if (!committed.second_service_pending) {
        writeTargetWord(self, committed.code, committed.addr, committed.word);
    }

    if (entryRequiresSecondService(committed.code) and !committed.second_service_pending) {
        entry.second_service_pending = true;
        return;
    }

    fifoPop(self);
}

fn applyBufferedPortWrites(self: *Vdp) void {
    while (!pendingPortWritesIsEmpty(self)) {
        if (self.dma_active and !self.dma_fill and !self.dma_copy) return;

        const pending = popPendingPortWrite(self) orelse return;
        switch (pending) {
            .data => |value| writeData(self, value),
            .control => |value| writeControl(self, value),
        }
    }
}

pub fn progressTransfers(self: *Vdp, master_cycles: u32, read_ctx: ?*anyopaque, read_word: ?Vdp.DmaReadFn) void {
    defer invalidateProjectedDataPortWriteWait(self);

    var available_master_cycles = master_cycles;
    if (self.pending_port_write_delay_master_cycles != 0) {
        const delay_step = @min(available_master_cycles, self.pending_port_write_delay_master_cycles);
        advanceTransferCursor(self, delay_step);
        self.pending_port_write_delay_master_cycles -= @intCast(delay_step);
        available_master_cycles -= delay_step;

        if (self.pending_port_write_delay_master_cycles == 0) {
            applyBufferedPortWrites(self);
        }
    }

    if (available_master_cycles == 0) return;

    const blanking = self.vblank or self.hblank;
    const end_master_cycle: u16 = @intCast(self.transfer_line_master_cycle + available_master_cycles);
    var slot_idx: u16 = 0;
    while (slot_idx < transferSlotCount(self)) : (slot_idx += 1) {
        const slot_end = transferSlotEndMasterCycles(self, slot_idx);
        if (slot_end <= self.transfer_line_master_cycle) continue;
        if (slot_end > end_master_cycle) break;

        if (!transferSlotIsRefresh(self, slot_idx)) {
            if (self.dma_active and !self.dma_fill and !self.dma_copy) {
                if (read_word) |reader| {
                    progressMemoryToVramDmaReadSlot(self, slot_idx, read_ctx, reader);
                }
            }

            fifoTickLatency(self);
        }

        if (transferSlotIsAccess(self, slot_idx, blanking)) {
            serviceAccessSlot(self);
        }
    }

    self.transfer_line_master_cycle = end_master_cycle;
    finishDmaIfIdle(self);
}

pub fn dataPortWriteWaitMasterCycles(self: *const Vdp) u32 {
    if (self.dma_active and self.dma_fill) return 0;

    const pending_ahead = self.pending_fifo_len;
    const blocked = pending_ahead != 0 or fifoIsFull(self);
    if (!blocked) return 0;

    return fifoWaitUntilNextOpen(self);
}

pub fn reserveDataPortWriteWaitMasterCycles(self: *Vdp) u32 {
    if (self.dma_active and self.dma_fill) return 0;
    return reserveProjectedDataPortWriteWait(self);
}

pub fn dataPortReadWaitMasterCycles(self: *const Vdp) u32 {
    if (self.dma_active and self.dma_fill) return 0;
    if (fifoIsEmpty(self) and pendingFifoIsEmpty(self)) return 0;

    return fifoWaitUntilDrained(self);
}

pub fn shouldHaltCpu(self: *const Vdp) bool {
    return self.dma_active and !self.dma_fill and !self.dma_copy;
}

pub fn controlPortWriteWaitMasterCycles(self: *const Vdp) u32 {
    if (self.dma_active and !self.dma_fill and !self.dma_copy) return 0;
    return self.pending_port_write_delay_master_cycles;
}

pub fn writeControl(self: *Vdp, value: u16) void {
    if (shouldBufferPortWrite(self)) {
        pushPendingPortWrite(self, .{ .control = value });
        return;
    }

    if (!self.pending_command and (value & 0xE000) == 0x8000) {
        const reg = (value >> 8) & 0x1F;
        const data: u8 = @intCast(value & 0xFF);
        if (reg < self.regs.len) {
            if (reg == 0 and ((self.regs[0] & 0x02) != 0) and ((data & 0x02) == 0)) {
                self.hv_latched_valid = false;
            }
            self.regs[reg] = data;
        }
        self.pending_command = false;
        return;
    }

    if (!self.pending_command) {
        self.command_word = (@as(u32, value) << 16);
        self.addr = (self.addr & 0xC000) | @as(u16, @intCast(value & 0x3FFF));
        self.code = (self.code & 0x3C) | @as(u8, @intCast((value >> 14) & 0x3));
        self.pending_command = true;
    } else {
        self.command_word |= value;
        self.pending_command = false;

        const hi = (self.command_word >> 16);
        const lo = (self.command_word & 0xFFFF);

        const cd0_1 = (hi >> 14) & 0x3;
        const cd2_5 = (lo >> 4) & 0xF;
        self.code = @intCast((cd2_5 << 2) | cd0_1);

        const a0_13 = (hi & 0x3FFF);
        const a14_15 = (lo & 0x3);
        self.addr = @intCast((a14_15 << 14) | a0_13);

        if ((self.code & 0x20) != 0 and (self.regs[1] & 0x10) != 0) {
            const dma_mode = (self.regs[23] >> 6) & 0x3;

            const dma_src_lo = self.regs[21];
            const dma_src_mid = self.regs[22];
            const dma_src_hi = self.regs[23] & 0x7F;
            self.dma_source_addr = (@as(u32, dma_src_hi) << 17) | (@as(u32, dma_src_mid) << 9) | (@as(u32, dma_src_lo) << 1);

            self.dma_length = (@as(u16, self.regs[20]) << 8) | self.regs[19];
            self.dma_remaining = if (self.dma_length == 0) 0x10000 else self.dma_length;

            if (dma_mode <= 1) {
                self.dma_fill = false;
                self.dma_copy = false;
                self.dma_active = true;
                self.dma_start_delay_slots = memoryToVramDmaStartDelaySlots(self);
            } else if (dma_mode == 2) {
                self.dma_fill = true;
                self.dma_copy = false;
                self.dma_active = true;
                self.dma_start_delay_slots = 0;
            } else {
                self.dma_source_addr = (@as(u32, self.regs[22]) << 8) | @as(u32, self.regs[21]);
                self.dma_copy = true;
                self.dma_fill = false;
                self.dma_active = true;
                self.dma_start_delay_slots = 0;
            }
            self.fifo_head = 0;
            self.fifo_len = 0;
            self.pending_fifo_head = 0;
            self.pending_fifo_len = 0;
        }
    }
}

test "data port write wait accounts for pending fifo entries" {
    var vdp = Vdp.init();
    vdp.regs[12] = 0x81;
    vdp.code = 0x1;

    for (0..5) |i| {
        vdp.writeData(@intCast(0x1000 + i));
    }

    const initial_wait = vdp.dataPortWriteWaitMasterCycles();
    try testing.expect(initial_wait > 0);

    vdp.progressTransfers(vdp.nextTransferStepMasterCycles(), null, null);
    const after_first_step = vdp.dataPortWriteWaitMasterCycles();
    try testing.expect(after_first_step < initial_wait);

    vdp.progressTransfers(after_first_step, null, null);
    try testing.expectEqual(@as(u32, 0), vdp.dataPortWriteWaitMasterCycles());
}

test "reserving data port write wait composes projected fifo timing" {
    var vdp = Vdp.init();
    vdp.regs[12] = 0x81;
    vdp.code = 0x1;

    for (0..5) |i| {
        vdp.writeData(@intCast(0x2000 + i));
    }

    const first_wait = vdp.reserveDataPortWriteWaitMasterCycles();
    const second_wait = vdp.reserveDataPortWriteWaitMasterCycles();
    try testing.expect(first_wait > 0);
    try testing.expect(second_wait > 0);
    try testing.expect(second_wait < first_wait);
}

test "data port waits account for partial transfer remainder" {
    var baseline_read = Vdp.init();
    baseline_read.regs[12] = 0x81;
    baseline_read.code = 0x1;
    baseline_read.writeData(0x1234);

    var progressed_read = Vdp.init();
    progressed_read.regs[12] = 0x81;
    progressed_read.code = 0x1;
    progressed_read.writeData(0x1234);
    progressed_read.progressTransfers(15, null, null);
    try testing.expect(progressed_read.dataPortReadWaitMasterCycles() > 0);
    try testing.expect(progressed_read.dataPortReadWaitMasterCycles() < baseline_read.dataPortReadWaitMasterCycles());

    var baseline_write = Vdp.init();
    baseline_write.regs[12] = 0x81;
    baseline_write.code = 0x1;
    baseline_write.writeData(0x2000);
    baseline_write.writeData(0x2001);
    baseline_write.writeData(0x2002);
    baseline_write.writeData(0x2003);

    var progressed_write = Vdp.init();
    progressed_write.regs[12] = 0x81;
    progressed_write.code = 0x1;
    progressed_write.writeData(0x2000);
    progressed_write.writeData(0x2001);
    progressed_write.writeData(0x2002);
    progressed_write.writeData(0x2003);
    progressed_write.progressTransfers(15, null, null);

    try testing.expect(progressed_write.dataPortWriteWaitMasterCycles() > 0);
    try testing.expect(progressed_write.dataPortWriteWaitMasterCycles() < baseline_write.dataPortWriteWaitMasterCycles());
    try testing.expectEqual(progressed_write.dataPortWriteWaitMasterCycles(), progressed_write.reserveDataPortWriteWaitMasterCycles());
}

test "VRAM fifo entries commit before their second service slot" {
    var vdp = Vdp.init();
    vdp.regs[12] = 0x81;
    vdp.code = 0x1;
    vdp.addr = 0x0020;

    vdp.writeData(0xABCD);
    var committed = false;
    var iterations: usize = 0;
    while (!committed and iterations < 32) : (iterations += 1) {
        const step = vdp.nextTransferStepMasterCycles();
        try testing.expect(step > 0);
        vdp.progressTransfers(step, null, null);
        committed = vdp.vramReadByte(0x0020) == 0xAB and vdp.vramReadByte(0x0021) == 0xCD;
    }

    try testing.expect(committed);
    try testing.expectEqual(@as(u8, 0xAB), vdp.vramReadByte(0x0020));
    try testing.expectEqual(@as(u8, 0xCD), vdp.vramReadByte(0x0021));
    try testing.expectEqual(@as(u8, 1), vdp.fifo_len);
    try testing.expect(vdp.fifo[vdp.fifo_head].second_service_pending);
    const remaining_wait = vdp.dataPortReadWaitMasterCycles();
    try testing.expect(remaining_wait > 0);

    vdp.progressTransfers(remaining_wait, null, null);
    try testing.expectEqual(@as(u8, 0), vdp.fifo_len);
}

test "CRAM fifo entries still drain in a single service slot" {
    var vdp = Vdp.init();
    vdp.regs[12] = 0x81;
    vdp.code = 0x3;
    vdp.addr = 0x0004;

    vdp.writeData(0x1357);
    const drain_wait = vdp.dataPortReadWaitMasterCycles();
    try testing.expect(drain_wait > 0);

    vdp.progressTransfers(drain_wait, null, null);
    try testing.expectEqual(@as(u8, 0), vdp.fifo_len);
    try testing.expectEqual(@as(u8, 0x13), vdp.cram[0x0004]);
    try testing.expectEqual(@as(u8, 0x57), vdp.cram[0x0005]);
}

test "data port read wait crosses the external hblank edge" {
    var vdp = Vdp.init();
    vdp.regs[12] = 0x81;
    vdp.code = 0x3;
    vdp.addr = 0x0000;
    vdp.scanline = 12;
    vdp.line_master_cycle = vdp.hblankStartMasterCycles() - 1;
    vdp.transfer_line_master_cycle = vdp.line_master_cycle;

    vdp.writeData(0x1234);
    vdp.fifo[vdp.fifo_head].latency = 0;

    const predicted = vdp.dataPortReadWaitMasterCycles();
    try testing.expect(predicted > 1);

    var progressed = vdp;
    progressed.step(1);
    progressed.progressTransfers(1, null, null);
    progressed.setHBlank(true);
    progressed.progressTransfers(predicted - 1, null, null);

    try testing.expectEqual(@as(u8, 0), progressed.fifo_len);
}

test "projected data port write wait carries hblank phase across reservations" {
    var vdp = Vdp.init();
    vdp.regs[12] = 0x81;
    vdp.code = 0x3;
    vdp.addr = 0x0000;
    vdp.scanline = 12;
    vdp.line_master_cycle = vdp.hblankStartMasterCycles() - 1;
    vdp.transfer_line_master_cycle = vdp.line_master_cycle;

    for (0..5) |i| {
        vdp.writeData(@intCast(0x2000 + i));
    }

    var i: usize = 0;
    while (i < @as(usize, vdp.fifo_len)) : (i += 1) {
        const idx = (@as(usize, vdp.fifo_head) + i) % vdp.fifo.len;
        vdp.fifo[idx].latency = 0;
    }

    i = 0;
    while (i < @as(usize, vdp.pending_fifo_len)) : (i += 1) {
        const idx = (@as(usize, vdp.pending_fifo_head) + i) % vdp.pending_fifo.len;
        vdp.pending_fifo[idx].latency = 0;
    }

    const first_wait = vdp.reserveDataPortWriteWaitMasterCycles();
    const second_wait = vdp.reserveDataPortWriteWaitMasterCycles();
    try testing.expect(first_wait > 0);
    try testing.expect(second_wait > 0);
    try testing.expect(second_wait < first_wait);
}
