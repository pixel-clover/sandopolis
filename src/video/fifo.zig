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

fn normalizeTransferLineMasterCycle(total_master_cycles: u32) u16 {
    return @intCast(total_master_cycles % clock.ntsc_master_cycles_per_line);
}

fn advanceTransferCursor(self: *Vdp, master_cycles: u32) void {
    const total = (@as(u32, self.transfer_line_master_cycle) + master_cycles) % clock.ntsc_master_cycles_per_line;
    self.transfer_line_master_cycle = @intCast(total);
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

const ProjectedDmaTransferState = struct {
    fifo_entries: [4]Vdp.ProjectedFifoEntry = [_]Vdp.ProjectedFifoEntry{.{}} ** 4,
    fifo_len: u8 = 0,
    pending_fifo_entries: [16]Vdp.ProjectedFifoEntry = [_]Vdp.ProjectedFifoEntry{.{}} ** 16,
    pending_fifo_len: u8 = 0,
    dma_active: bool = false,
    dma_fill: bool = false,
    dma_copy: bool = false,
    dma_fill_ready: bool = false,
    dma_remaining: u32 = 0,
    dma_start_delay_slots: u8 = 0,
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

fn nextTransferStepForState(self: *const Vdp, initial_phase: TransferPhaseState) u32 {
    var phase = initial_phase;
    phase.line_master_cycle = normalizeTransferLineMasterCycle(phase.line_master_cycle);

    const needs_non_refresh = (self.dma_active and !self.dma_fill and !self.dma_copy) or
        !fifoIsEmpty(self) or
        !pendingFifoIsEmpty(self);
    const needs_access_only = self.dma_copy or (self.dma_fill and self.dma_fill_ready);
    if (!needs_non_refresh and !needs_access_only) {
        return clock.ntsc_master_cycles_per_line - phase.line_master_cycle;
    }

    var wait_master_cycles: u32 = 0;
    while (true) {
        const boundary = nextTransferPhaseBoundary(self, phase);
        const event =
            nextTransferEventForState(self, phase.line_master_cycle, phaseIsBlanking(self, phase), needs_non_refresh, needs_access_only);
        if (event) |slot_event| {
            if (slot_event.wait_master_cycles <= boundary.wait_master_cycles) {
                return wait_master_cycles + slot_event.wait_master_cycles;
            }
        }

        wait_master_cycles += boundary.wait_master_cycles;
        applyTransferPhaseBoundary(self, &phase, boundary.kind);
    }
}

pub fn nextTransferStepMasterCycles(self: *const Vdp) u32 {
    return nextTransferStepForState(self, currentTransferPhase(self));
}

fn pendingPortWriteReplayDelayMasterCycles(self: *const Vdp) u16 {
    const master_cycles_per_pixel: u16 = if (self.isH40()) 8 else 10;
    return pending_port_write_replay_delay_pixels * master_cycles_per_pixel;
}

fn memoryToVramDmaStartDelaySlotsForCode(code: u8) u8 {
    return if ((code & 0xF) == 0x5) 5 else 8;
}

fn memoryToVramDmaStartDelaySlots(self: *const Vdp) u8 {
    return memoryToVramDmaStartDelaySlotsForCode(self.code);
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
            fifo_entries[i].latency -|= 1;
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

fn snapshotProjectedBufferedPortWrites(self: *const Vdp, projected: *Vdp.ProjectedDataPortWriteWait) void {
    projected.replay_pending_port_write_len = 0;
    projected.projected_code = self.code;
    projected.projected_addr = self.addr;
    projected.projected_pending_command = self.pending_command;
    projected.projected_command_word = self.command_word;
    projected.projected_regs = self.regs;
    projected.projected_dma_active = self.dma_active;
    projected.projected_dma_fill = self.dma_fill;
    projected.projected_dma_copy = self.dma_copy;
    projected.projected_dma_fill_ready = self.dma_fill_ready;
    projected.projected_dma_remaining = self.dma_remaining;
    projected.projected_dma_start_delay_slots = self.dma_start_delay_slots;

    var i: usize = 0;
    while (i < @as(usize, self.pending_port_write_len)) : (i += 1) {
        const idx = (@as(usize, self.pending_port_write_head) + i) % self.pending_port_writes.len;
        projected.replay_pending_port_writes[i] = self.pending_port_writes[idx];
        projected.replay_pending_port_write_len += 1;
    }
}

fn snapshotProjectedDmaTransferState(self: *const Vdp) ProjectedDmaTransferState {
    var projected = ProjectedDmaTransferState{
        .dma_active = self.dma_active,
        .dma_fill = self.dma_fill,
        .dma_copy = self.dma_copy,
        .dma_fill_ready = self.dma_fill_ready,
        .dma_remaining = self.dma_remaining,
        .dma_start_delay_slots = self.dma_start_delay_slots,
    };
    snapshotSimFifos(
        self,
        projected.fifo_entries[0..],
        &projected.fifo_len,
        projected.pending_fifo_entries[0..],
        &projected.pending_fifo_len,
    );
    return projected;
}

fn projectedFinishDmaIfIdle(projected: *ProjectedDmaTransferState) void {
    if (projected.dma_remaining != 0 or projected.fifo_len != 0) return;

    projected.dma_active = false;
    projected.dma_fill = false;
    projected.dma_copy = false;
    projected.dma_fill_ready = false;
    projected.dma_start_delay_slots = 0;
}

fn projectedProgressMemoryToVramDmaReadSlot(self: *const Vdp, slot_idx: u16, projected: *ProjectedDmaTransferState) void {
    var can_transfer = true;
    if (projected.dma_start_delay_slots != 0) {
        projected.dma_start_delay_slots -= 1;
        can_transfer = projected.dma_start_delay_slots == 0;
    }

    if (!can_transfer or @as(usize, projected.fifo_len) >= projected.fifo_entries.len or projected.dma_remaining == 0) return;
    if (slot_idx != 0 and transferSlotIsRefresh(self, slot_idx - 1)) return;

    projected.fifo_entries[@as(usize, projected.fifo_len)] = .{
        .latency = dma_fifo_latency_slots,
        .requires_second_service = entryRequiresSecondService(self.code),
        .second_service_pending = false,
    };
    projected.fifo_len += 1;
    projected.dma_remaining -= 1;
}

fn projectedProgressVramCopyDma(projected: *ProjectedDmaTransferState) void {
    if (projected.dma_remaining == 0) {
        projectedFinishDmaIfIdle(projected);
        return;
    }

    projected.dma_remaining -= 1;
    projectedFinishDmaIfIdle(projected);
}

fn projectedProgressDmaFill(projected: *ProjectedDmaTransferState) void {
    if (!projected.dma_fill_ready or projected.dma_remaining == 0) {
        projectedFinishDmaIfIdle(projected);
        return;
    }

    projected.dma_remaining -= 1;
    projectedFinishDmaIfIdle(projected);
}

fn projectedServiceAccessSlot(projected: *ProjectedDmaTransferState) void {
    if (projected.fifo_len != 0) {
        processSimAccessSlot(
            projected.fifo_entries[0..],
            &projected.fifo_len,
            projected.pending_fifo_entries[0..],
            &projected.pending_fifo_len,
        );
        return;
    }

    if (projected.dma_active and projected.dma_copy) {
        projectedProgressVramCopyDma(projected);
        return;
    }

    if (projected.dma_active and projected.dma_fill) {
        projectedProgressDmaFill(projected);
    }
}

pub fn dmaBusyAfterMasterCycles(self: *const Vdp, master_cycles: u32) bool {
    if (!self.dma_active) return false;
    if (master_cycles == 0) return self.dma_active;

    var projected = snapshotProjectedDmaTransferState(self);
    var phase = currentTransferPhase(self);
    var remaining = master_cycles;

    while (remaining != 0 and projected.dma_active) {
        const boundary = nextTransferPhaseBoundary(self, phase);
        const needs_non_refresh = (projected.dma_active and !projected.dma_fill and !projected.dma_copy) or
            projected.fifo_len != 0 or projected.pending_fifo_len != 0;
        const needs_access_only = projected.dma_active and (projected.dma_copy or (projected.dma_fill and projected.dma_fill_ready));
        const event =
            nextTransferEventForState(self, phase.line_master_cycle, phaseIsBlanking(self, phase), needs_non_refresh, needs_access_only);

        if (event) |slot_event| {
            if (slot_event.wait_master_cycles <= remaining and slot_event.wait_master_cycles <= boundary.wait_master_cycles) {
                remaining -= slot_event.wait_master_cycles;
                phase.line_master_cycle += @intCast(slot_event.wait_master_cycles);

                if (!transferSlotIsRefresh(self, slot_event.slot_idx)) {
                    if (projected.dma_active and !projected.dma_fill and !projected.dma_copy) {
                        projectedProgressMemoryToVramDmaReadSlot(self, slot_event.slot_idx, &projected);
                    }
                    tickSimLatency(projected.fifo_entries[0..], projected.fifo_len);
                }

                if (transferSlotIsAccess(self, slot_event.slot_idx, phaseIsBlanking(self, phase))) {
                    projectedServiceAccessSlot(&projected);
                    projectedFinishDmaIfIdle(&projected);
                }

                if (slot_event.wait_master_cycles == boundary.wait_master_cycles) {
                    applyTransferPhaseBoundary(self, &phase, boundary.kind);
                }
                continue;
            }
        }

        const step = @min(remaining, boundary.wait_master_cycles);
        remaining -= step;
        if (step == boundary.wait_master_cycles) {
            applyTransferPhaseBoundary(self, &phase, boundary.kind);
        } else {
            phase.line_master_cycle += @intCast(step);
        }
    }

    return projected.dma_active;
}

fn initProjectedDataPortWriteWait(self: *const Vdp, projected: *Vdp.ProjectedDataPortWriteWait) void {
    const phase = currentTransferPhase(self);
    projected.* = .{
        .valid = true,
        .transfer_scanline = phase.scanline,
        .transfer_line_master_cycle = phase.line_master_cycle,
        .transfer_hblank = phase.hblank,
        .transfer_odd_frame = phase.odd_frame,
        .pending_port_write_delay_master_cycles = self.pending_port_write_delay_master_cycles,
    };
    snapshotSimFifos(
        self,
        projected.fifo_entries[0..],
        &projected.fifo_len,
        projected.pending_fifo_entries[0..],
        &projected.pending_fifo_len,
    );
    snapshotProjectedBufferedPortWrites(self, projected);
}

fn syncProjectedDataPortWriteWait(self: *Vdp) void {
    if (self.projected_data_port_write_wait.valid) return;

    initProjectedDataPortWriteWait(self, &self.projected_data_port_write_wait);
}

fn projectedDataPortWriteHasRoom(projected: *const Vdp.ProjectedDataPortWriteWait) bool {
    return projected.pending_fifo_len == 0 and @as(usize, projected.fifo_len) < projected.fifo_entries.len;
}

fn projectedShouldBufferPortWrite(projected: *const Vdp.ProjectedDataPortWriteWait) bool {
    return (projected.projected_dma_active and !projected.projected_dma_fill and !projected.projected_dma_copy) or
        projected.pending_port_write_delay_master_cycles != 0;
}

fn projectedAdvanceTransferPhase(self: *const Vdp, projected: *Vdp.ProjectedDataPortWriteWait, master_cycles: u32) void {
    var phase: TransferPhaseState = .{
        .scanline = projected.transfer_scanline,
        .line_master_cycle = projected.transfer_line_master_cycle,
        .hblank = projected.transfer_hblank,
        .odd_frame = projected.transfer_odd_frame,
    };
    advanceTransferPhaseState(self, &phase, master_cycles);
    projected.transfer_scanline = phase.scanline;
    projected.transfer_line_master_cycle = phase.line_master_cycle;
    projected.transfer_hblank = phase.hblank;
    projected.transfer_odd_frame = phase.odd_frame;
}

fn projectedProcessTransferSlot(self: *const Vdp, projected: *Vdp.ProjectedDataPortWriteWait, slot_idx: u16, blanking: bool) void {
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

fn projectedPopPendingPortWrite(projected: *Vdp.ProjectedDataPortWriteWait) ?Vdp.PendingPortWrite {
    if (projected.replay_pending_port_write_len == 0) return null;

    const write = projected.replay_pending_port_writes[0];
    var i: usize = 1;
    while (i < @as(usize, projected.replay_pending_port_write_len)) : (i += 1) {
        projected.replay_pending_port_writes[i - 1] = projected.replay_pending_port_writes[i];
    }
    projected.replay_pending_port_write_len -= 1;
    return write;
}

fn projectedAdvanceAddr(projected: *Vdp.ProjectedDataPortWriteWait) void {
    projected.projected_addr = projected.projected_addr +% projected.projected_regs[15];
}

fn projectedReplayDataWrite(projected: *Vdp.ProjectedDataPortWriteWait, _: u16) void {
    projected.projected_pending_command = false;
    const entry: Vdp.ProjectedFifoEntry = .{
        .latency = dma_fifo_latency_slots,
        .requires_second_service = entryRequiresSecondService(projected.projected_code),
        .second_service_pending = false,
    };
    const tail = @as(usize, projected.fifo_len);
    if (tail < projected.fifo_entries.len) {
        projected.fifo_entries[tail] = entry;
        projected.fifo_len += 1;
    } else if (@as(usize, projected.pending_fifo_len) < projected.pending_fifo_entries.len) {
        projected.pending_fifo_entries[@as(usize, projected.pending_fifo_len)] = entry;
        projected.pending_fifo_len += 1;
    }

    if (projected.projected_dma_active and projected.projected_dma_fill and !projected.projected_dma_fill_ready) {
        projected.projected_dma_fill_ready = true;
    }
    projectedAdvanceAddr(projected);
}

fn projectedReplayControlWrite(projected: *Vdp.ProjectedDataPortWriteWait, value: u16) void {
    if (!projected.projected_pending_command and (value & 0xE000) == 0x8000) {
        const reg = (value >> 8) & 0x1F;
        if (reg < projected.projected_regs.len) {
            projected.projected_regs[reg] = @intCast(value & 0xFF);
        }
        projected.projected_pending_command = false;
        return;
    }

    if (!projected.projected_pending_command) {
        projected.projected_command_word = (@as(u32, value) << 16);
        projected.projected_addr = (projected.projected_addr & 0xC000) | @as(u16, @intCast(value & 0x3FFF));
        projected.projected_code = (projected.projected_code & 0x3C) | @as(u8, @intCast((value >> 14) & 0x3));
        projected.projected_pending_command = true;
        return;
    }

    projected.projected_command_word |= value;
    projected.projected_pending_command = false;

    const hi = projected.projected_command_word >> 16;
    const lo = projected.projected_command_word & 0xFFFF;

    const cd0_1 = (hi >> 14) & 0x3;
    const cd2_5 = (lo >> 4) & 0xF;
    projected.projected_code = @intCast((cd2_5 << 2) | cd0_1);

    const a0_13 = hi & 0x3FFF;
    const a14_15 = lo & 0x3;
    projected.projected_addr = @intCast((a14_15 << 14) | a0_13);

    if ((projected.projected_code & 0x20) != 0 and (projected.projected_regs[1] & 0x10) != 0) {
        const dma_mode = (projected.projected_regs[23] >> 6) & 0x3;
        const dma_length = (@as(u16, projected.projected_regs[20]) << 8) | projected.projected_regs[19];

        projected.projected_dma_remaining = if (dma_length == 0) 0x10000 else dma_length;

        if (dma_mode <= 1) {
            projected.projected_dma_fill = false;
            projected.projected_dma_copy = false;
            projected.projected_dma_fill_ready = false;
            projected.projected_dma_active = true;
            projected.projected_dma_start_delay_slots = memoryToVramDmaStartDelaySlotsForCode(projected.projected_code);
        } else if (dma_mode == 2) {
            projected.projected_dma_fill = true;
            projected.projected_dma_copy = false;
            projected.projected_dma_fill_ready = false;
            projected.projected_dma_active = true;
            projected.projected_dma_start_delay_slots = 0;
        } else {
            projected.projected_dma_copy = true;
            projected.projected_dma_fill = false;
            projected.projected_dma_fill_ready = false;
            projected.projected_dma_active = true;
            projected.projected_dma_start_delay_slots = 0;
        }

        projected.fifo_len = 0;
        projected.pending_fifo_len = 0;
    }
}

fn projectedReplayBufferedPortWrites(projected: *Vdp.ProjectedDataPortWriteWait) void {
    while (!projectedShouldBufferPortWrite(projected)) {
        const write = projectedPopPendingPortWrite(projected) orelse return;
        switch (write) {
            .data => |value| projectedReplayDataWrite(projected, value),
            .control => |value| projectedReplayControlWrite(projected, value),
        }

        if (projectedShouldBufferPortWrite(projected)) return;
    }
}

fn projectedFinishReplayDmaIfIdle(self: *const Vdp, projected: *Vdp.ProjectedDataPortWriteWait) void {
    if (projected.projected_dma_remaining != 0 or projected.fifo_len != 0) return;

    projected.projected_dma_active = false;
    projected.projected_dma_fill = false;
    projected.projected_dma_copy = false;
    projected.projected_dma_fill_ready = false;
    projected.projected_dma_remaining = 0;
    projected.projected_dma_start_delay_slots = 0;
    if (projected.replay_pending_port_write_len != 0) {
        projected.pending_port_write_delay_master_cycles = pendingPortWriteReplayDelayMasterCycles(self);
    }
}

fn projectedReplayProgressMemoryToVramDmaReadSlot(self: *const Vdp, slot_idx: u16, projected: *Vdp.ProjectedDataPortWriteWait) void {
    var can_transfer = true;
    if (projected.projected_dma_start_delay_slots != 0) {
        projected.projected_dma_start_delay_slots -= 1;
        can_transfer = projected.projected_dma_start_delay_slots == 0;
    }

    if (!can_transfer or @as(usize, projected.fifo_len) >= projected.fifo_entries.len or projected.projected_dma_remaining == 0) return;
    if (slot_idx != 0 and transferSlotIsRefresh(self, slot_idx - 1)) return;

    projected.fifo_entries[@as(usize, projected.fifo_len)] = .{
        .latency = dma_fifo_latency_slots,
        .requires_second_service = entryRequiresSecondService(projected.projected_code),
        .second_service_pending = false,
    };
    projected.fifo_len += 1;
    projected.projected_dma_remaining -= 1;
}

fn projectedWaitUntilReplayDmaStopsBlocking(self: *const Vdp, projected: *Vdp.ProjectedDataPortWriteWait) u32 {
    var wait_master_cycles: u32 = 0;

    while (projected.projected_dma_active and !projected.projected_dma_fill and !projected.projected_dma_copy) {
        var phase: TransferPhaseState = .{
            .scanline = projected.transfer_scanline,
            .line_master_cycle = projected.transfer_line_master_cycle,
            .hblank = projected.transfer_hblank,
            .odd_frame = projected.transfer_odd_frame,
        };
        const boundary = nextTransferPhaseBoundary(self, phase);
        const event = nextTransferEventForState(
            self,
            phase.line_master_cycle,
            phaseIsBlanking(self, phase),
            true,
            false,
        );

        if (event) |slot_event| {
            if (slot_event.wait_master_cycles <= boundary.wait_master_cycles) {
                wait_master_cycles += slot_event.wait_master_cycles;
                phase.line_master_cycle += @intCast(slot_event.wait_master_cycles);
                projected.transfer_scanline = phase.scanline;
                projected.transfer_line_master_cycle = phase.line_master_cycle;
                projected.transfer_hblank = phase.hblank;
                projected.transfer_odd_frame = phase.odd_frame;

                if (!transferSlotIsRefresh(self, slot_event.slot_idx)) {
                    projectedReplayProgressMemoryToVramDmaReadSlot(self, slot_event.slot_idx, projected);
                    tickSimLatency(projected.fifo_entries[0..], projected.fifo_len);
                }

                if (transferSlotIsAccess(self, slot_event.slot_idx, phaseIsBlanking(self, phase))) {
                    processSimAccessSlot(
                        projected.fifo_entries[0..],
                        &projected.fifo_len,
                        projected.pending_fifo_entries[0..],
                        &projected.pending_fifo_len,
                    );
                    projectedFinishReplayDmaIfIdle(self, projected);
                }

                if (slot_event.wait_master_cycles == boundary.wait_master_cycles) {
                    phase = .{
                        .scanline = projected.transfer_scanline,
                        .line_master_cycle = projected.transfer_line_master_cycle,
                        .hblank = projected.transfer_hblank,
                        .odd_frame = projected.transfer_odd_frame,
                    };
                    applyTransferPhaseBoundary(self, &phase, boundary.kind);
                    projected.transfer_scanline = phase.scanline;
                    projected.transfer_line_master_cycle = phase.line_master_cycle;
                    projected.transfer_hblank = phase.hblank;
                    projected.transfer_odd_frame = phase.odd_frame;
                }
                continue;
            }
        }

        wait_master_cycles += boundary.wait_master_cycles;
        advanceTransferPhaseState(self, &phase, boundary.wait_master_cycles);
        projected.transfer_scanline = phase.scanline;
        projected.transfer_line_master_cycle = phase.line_master_cycle;
        projected.transfer_hblank = phase.hblank;
        projected.transfer_odd_frame = phase.odd_frame;
    }

    return wait_master_cycles;
}

fn projectedDataPortWriteWaitMasterCyclesForState(self: *const Vdp, projected: *Vdp.ProjectedDataPortWriteWait, reserve: bool) u32 {
    var wait_master_cycles: u32 = 0;
    while (true) {
        if (!projectedShouldBufferPortWrite(projected) and projectedDataPortWriteHasRoom(projected)) break;

        var phase: TransferPhaseState = .{
            .scanline = projected.transfer_scanline,
            .line_master_cycle = projected.transfer_line_master_cycle,
            .hblank = projected.transfer_hblank,
            .odd_frame = projected.transfer_odd_frame,
        };

        if (projected.pending_port_write_delay_master_cycles != 0) {
            wait_master_cycles += projected.pending_port_write_delay_master_cycles;
            projectedAdvanceTransferPhase(self, projected, projected.pending_port_write_delay_master_cycles);
            projected.pending_port_write_delay_master_cycles = 0;
            projectedReplayBufferedPortWrites(projected);
            continue;
        }

        if (projected.projected_dma_active and !projected.projected_dma_fill and !projected.projected_dma_copy) {
            wait_master_cycles += projectedWaitUntilReplayDmaStopsBlocking(self, projected);
            continue;
        }

        const boundary = nextTransferPhaseBoundary(self, phase);
        const event = nextTransferEventForState(self, phase.line_master_cycle, phaseIsBlanking(self, phase), true, false);
        if (event) |slot_event| {
            if (slot_event.wait_master_cycles <= boundary.wait_master_cycles) {
                wait_master_cycles += slot_event.wait_master_cycles;
                phase.line_master_cycle += @intCast(slot_event.wait_master_cycles);
                projected.transfer_scanline = phase.scanline;
                projected.transfer_line_master_cycle = phase.line_master_cycle;
                projected.transfer_hblank = phase.hblank;
                projected.transfer_odd_frame = phase.odd_frame;
                projectedProcessTransferSlot(self, projected, slot_event.slot_idx, phaseIsBlanking(self, phase));
                if (slot_event.wait_master_cycles == boundary.wait_master_cycles) {
                    phase = .{
                        .scanline = projected.transfer_scanline,
                        .line_master_cycle = projected.transfer_line_master_cycle,
                        .hblank = projected.transfer_hblank,
                        .odd_frame = projected.transfer_odd_frame,
                    };
                    applyTransferPhaseBoundary(self, &phase, boundary.kind);
                    projected.transfer_scanline = phase.scanline;
                    projected.transfer_line_master_cycle = phase.line_master_cycle;
                    projected.transfer_hblank = phase.hblank;
                    projected.transfer_odd_frame = phase.odd_frame;
                }
                continue;
            }
        }

        wait_master_cycles += boundary.wait_master_cycles;
        advanceTransferPhaseState(self, &phase, boundary.wait_master_cycles);
        projected.transfer_scanline = phase.scanline;
        projected.transfer_line_master_cycle = phase.line_master_cycle;
        projected.transfer_hblank = phase.hblank;
        projected.transfer_odd_frame = phase.odd_frame;
    }

    if (reserve) {
        projectedReplayDataWrite(projected, 0);
    }
    return wait_master_cycles;
}

fn fifoTickLatency(self: *Vdp) void {
    var i: usize = 0;
    while (i < @as(usize, self.fifo_len)) : (i += 1) {
        const idx = (@as(usize, self.fifo_head) + i) % self.fifo.len;
        if (self.fifo[idx].latency > 0) {
            self.fifo[idx].latency -|= 1;
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
    switch (code & 0x1F) {
        0x00 => {
            const high_index = addr ^ 1;
            return .{
                .storage = .vram,
                .high_index = high_index,
                .low_index = high_index ^ 1,
            };
        },
        0x08 => {
            const idx = addr & 0x7E;
            return .{
                .storage = .cram,
                .high_index = idx,
                .low_index = idx + 1,
            };
        },
        0x04 => {
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

fn fifoWordForUndrivenReadBits(self: *const Vdp) u16 {
    if (fifoIsEmpty(self)) return 0;
    return self.fifo[self.fifo_head].word;
}

fn applyUndrivenReadBits(code: u8, value: u16, fifo_word: u16) u16 {
    return switch (code & 0x1F) {
        0x04 => value | (fifo_word & 0xF800),
        0x08 => value | (fifo_word & 0xF111),
        0x0C => value | (fifo_word & 0xFF00),
        else => value,
    };
}

fn current8BitVramReadWordWithQueuedWrites(self: *const Vdp, addr: u16) ?u16 {
    const word = currentDataPortReadWordWithQueuedWrites(self, 0x00, addr) orelse return null;
    return @as(u16, @truncate(word >> 8));
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

    var write_high: u8 = @intCast((value >> 8) & 0xFF);
    var write_low: u8 = @intCast(value & 0xFF);
    var write_addr = write_base;
    if (write_storage == .vram) {
        write_addr &= 0xFFFE;
        if ((write_base & 1) != 0) {
            const swapped_high = write_low;
            write_low = write_high;
            write_high = swapped_high;
        }
    }
    const write_next = write_addr +% 1;

    if (target.high_index == write_addr) {
        high.* = write_high;
    } else if (target.high_index == write_next) {
        high.* = write_low;
    }

    if (target.low_index == write_addr) {
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
    if ((code & 0x1F) == 0x0C) {
        const value = current8BitVramReadWordWithQueuedWrites(self, addr) orelse return null;
        return applyUndrivenReadBits(code, value, fifoWordForUndrivenReadBits(self));
    }

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

    const value = (@as(u16, high) << 8) | low;
    return applyUndrivenReadBits(code, value, fifoWordForUndrivenReadBits(self));
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
            const base = addr & 0xFFFE;
            const high: u8 = @intCast((value >> 8) & 0xFF);
            const low: u8 = @intCast(value & 0xFF);
            if ((addr & 1) == 0) {
                self.vramWriteByte(base, high);
                self.vramWriteByte(base +% 1, low);
            } else {
                self.vramWriteByte(base, low);
                self.vramWriteByte(base +% 1, high);
            }
        },
        0x3 => {
            self.dbg_cram_writes += 1;
            const idx = addr & 0x7E;
            // Record CRAM event at FIFO service time.  The event captures
            // the old CRAM value before overwrite, enabling the undo/redo
            // pass in renderScanline to restore per-line palette state.
            self.recordCramDot(self.transfer_line_master_cycle, @intCast(idx), value);
            // CRAM stores 9-bit color in format ----BBB0GGG0RRR0.
            // Mask out unused bits so readback returns canonical values.
            const masked = value & 0x0EEE;
            self.cram[idx] = @intCast((masked >> 8) & 0xFF);
            self.cram[idx + 1] = @intCast(masked & 0xFF);
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
    const dma_fill_start = self.dma_active and self.dma_fill and !self.dma_fill_ready;

    if (shouldBufferPortWrite(self)) {
        pushPendingPortWrite(self, .{ .data = value });
        return;
    }

    self.pending_command = false;

    // Apply CRAM writes immediately at M68K write time, matching GPGX's
    // vdp_bus_w() behavior.  The FIFO entry is still created for timing
    // (M68K wait cycles) but the actual CRAM update happens NOW so that
    // mid-scanline palette changes take effect at the correct pixel.
    var entry = makeWriteFifoEntry(self, value, dma_fifo_latency_slots);
    if ((self.code & 0xF) == 0x3) {
        const cram_idx: u8 = @intCast(self.addr & 0x7E);
        // Record the CRAM dot event (for undo/redo during rendering).
        // This may be rejected if in VBlank or display off, but the
        // actual CRAM write below always applies.
        self.recordCramDot(self.line_master_cycle, cram_idx, value);
        // Apply CRAM write immediately regardless of display state.
        const masked = value & 0x0EEE;
        self.cram[cram_idx] = @intCast((masked >> 8) & 0xFF);
        self.cram[cram_idx + 1] = @intCast(masked & 0xFF);
        entry.cram_already_applied = true;
    }

    if (fifoIsFull(self)) {
        pendingFifoPush(self, entry);
    } else {
        fifoPush(self, entry);
    }
    advanceAddr(self);

    if (dma_fill_start) {
        self.dma_fill_word = value;
        self.dma_fill_ready = true;
    }
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
    self.dma_fill_ready = false;
    self.dma_fill_word = 0;
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
    var entry = makeWriteFifoEntry(self, word, dma_fifo_latency_slots);
    // Apply DMA-to-CRAM immediately, same as data port CRAM writes.
    if ((self.code & 0xF) == 0x3) {
        const cram_idx: u8 = @intCast(self.addr & 0x7E);
        self.recordCramDot(self.transfer_line_master_cycle, cram_idx, word);
        const masked = word & 0x0EEE;
        self.cram[cram_idx] = @intCast((masked >> 8) & 0xFF);
        self.cram[cram_idx + 1] = @intCast(masked & 0xFF);
        entry.cram_already_applied = true;
    }
    // DMA source wraps within a 128K window (bits 0-16), preserving the
    // upper address from reg[23].  GPGX: source = (reg[23] << 17) | (source & 0x1FFFF)
    const next_src = self.dma_source_addr +% 2;
    self.dma_source_addr = (self.dma_source_addr & 0xFFFE0000) | (next_src & 0x1FFFF);
    self.dma_remaining -= 1;
    if (self.active_execution_counters) |counters| counters.dma_words += 1;
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
        const byte = self.vramReadByte(src_addr ^ 1);
        self.vramWriteByte(self.addr ^ 1, byte);
        self.dma_source_addr +%= 1;
        advanceAddr(self);
    }

    self.dma_remaining -= copied;
    if (self.active_execution_counters) |counters| counters.dma_words += copied;
    finishDmaIfIdle(self);
}

fn progressDmaFill(self: *Vdp, access_slots: u32) void {
    if (!self.dma_fill_ready or self.dma_remaining == 0) {
        finishDmaIfIdle(self);
        return;
    }

    var budget = access_slots;
    if (budget > self.dma_remaining) budget = self.dma_remaining;

    const target = self.code & 0xF;
    const fill_word = self.dma_fill_word;
    const fill_byte: u8 = @intCast((fill_word >> 8) & 0xFF);

    var filled: u32 = 0;
    while (filled < budget) : (filled += 1) {
        switch (target) {
            0x1 => {
                self.dbg_vram_writes += 1;
                self.vramWriteByte(self.addr ^ 1, fill_byte);
            },
            0x3 => {
                self.dbg_cram_writes += 1;
                const idx = self.addr & 0x7E;
                self.recordCramDot(self.transfer_line_master_cycle, @intCast(idx & 0x7E), fill_word);
                const masked = fill_word & 0x0EEE;
                self.cram[idx] = @intCast((masked >> 8) & 0xFF);
                self.cram[idx + 1] = @intCast(masked & 0xFF);
            },
            0x5 => {
                self.dbg_vsram_writes += 1;
                const idx: u16 = (self.addr >> 1) % 40 * 2;
                self.vsram[idx] = @intCast((fill_word >> 8) & 0xFF);
                self.vsram[idx + 1] = @intCast(fill_word & 0xFF);
            },
            else => {
                self.dbg_unknown_writes += 1;
            },
        }
        advanceAddr(self);
    }

    self.dma_remaining -= filled;
    if (self.active_execution_counters) |counters| counters.dma_words += filled;
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
        return;
    }

    if (self.dma_active and self.dma_fill) {
        progressDmaFill(self, 1);
    }
}

fn serviceFifoFront(self: *Vdp) void {
    if (fifoIsEmpty(self)) return;

    const entry = fifoFront(self);
    if (entry.latency != 0) return;

    const committed = entry.*;
    if (!committed.second_service_pending and !committed.cram_already_applied) {
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

    var phase = currentTransferPhase(self);
    var available_master_cycles = master_cycles;
    if (self.pending_port_write_delay_master_cycles != 0) {
        const delay_step = @min(available_master_cycles, self.pending_port_write_delay_master_cycles);
        advanceTransferPhaseState(self, &phase, delay_step);
        self.pending_port_write_delay_master_cycles -= @intCast(delay_step);
        available_master_cycles -= delay_step;

        if (self.pending_port_write_delay_master_cycles == 0) {
            applyBufferedPortWrites(self);
        }
    }

    while (available_master_cycles != 0) {
        const boundary = nextTransferPhaseBoundary(self, phase);
        const needs_non_refresh = (self.dma_active and !self.dma_fill and !self.dma_copy) or
            !fifoIsEmpty(self) or
            !pendingFifoIsEmpty(self);
        const needs_access_only = self.dma_copy or (self.dma_fill and self.dma_fill_ready);
        const event =
            nextTransferEventForState(self, phase.line_master_cycle, phaseIsBlanking(self, phase), needs_non_refresh, needs_access_only);

        if (event) |slot_event| {
            if (slot_event.wait_master_cycles <= available_master_cycles and slot_event.wait_master_cycles <= boundary.wait_master_cycles) {
                available_master_cycles -= slot_event.wait_master_cycles;
                phase.line_master_cycle += @intCast(slot_event.wait_master_cycles);

                if (!transferSlotIsRefresh(self, slot_event.slot_idx)) {
                    if (self.active_execution_counters) |counters| counters.transfer_slots += 1;
                    if (self.dma_active and !self.dma_fill and !self.dma_copy) {
                        if (read_word) |reader| {
                            progressMemoryToVramDmaReadSlot(self, slot_event.slot_idx, read_ctx, reader);
                        }
                    }

                    fifoTickLatency(self);
                }

                if (transferSlotIsAccess(self, slot_event.slot_idx, phaseIsBlanking(self, phase))) {
                    if (self.active_execution_counters) |counters| counters.access_slots += 1;
                    self.transfer_line_master_cycle = phase.line_master_cycle;
                    serviceAccessSlot(self);
                }

                if (slot_event.wait_master_cycles == boundary.wait_master_cycles) {
                    applyTransferPhaseBoundary(self, &phase, boundary.kind);
                }
                continue;
            }
        }

        const step = @min(available_master_cycles, boundary.wait_master_cycles);
        available_master_cycles -= step;
        if (step == boundary.wait_master_cycles) {
            applyTransferPhaseBoundary(self, &phase, boundary.kind);
        } else {
            phase.line_master_cycle += @intCast(step);
        }
    }

    self.transfer_line_master_cycle = phase.line_master_cycle;
    finishDmaIfIdle(self);
}

pub fn dataPortWriteWaitMasterCycles(self: *const Vdp) u32 {
    var projected: Vdp.ProjectedDataPortWriteWait = undefined;
    initProjectedDataPortWriteWait(self, &projected);
    return projectedDataPortWriteWaitMasterCyclesForState(self, &projected, false);
}

pub fn reserveDataPortWriteWaitMasterCycles(self: *Vdp) u32 {
    syncProjectedDataPortWriteWait(self);
    return projectedDataPortWriteWaitMasterCyclesForState(self, &self.projected_data_port_write_wait, true);
}

pub fn dataPortReadWaitMasterCycles(self: *const Vdp) u32 {
    if (fifoIsEmpty(self) and pendingFifoIsEmpty(self)) return 0;

    return fifoWaitUntilDrained(self);
}

pub fn shouldHaltCpu(self: *const Vdp) bool {
    return self.dma_active and !self.dma_fill and !self.dma_copy;
}

/// Returns the master cycles until the next VDP refresh slot boundary
/// from the current transfer phase position.  During refresh slots the
/// VDP does not use the 68K bus, so the CPU can execute.  Returns 0 if
/// the current position is already inside a refresh slot.
pub fn masterCyclesToNextRefreshSlot(self: *const Vdp) u32 {
    const phase = currentTransferPhase(self);
    const lmc = normalizeTransferLineMasterCycle(phase.line_master_cycle);
    const slot_count = transferSlotCount(self);

    // Walk slots from the current position to find the next refresh slot.
    var slot_idx: u16 = 0;
    while (slot_idx < slot_count) : (slot_idx += 1) {
        const slot_start = transferSlotStartMasterCycles(self, slot_idx);
        const slot_end = transferSlotEndMasterCycles(self, slot_idx);
        if (slot_end <= lmc) continue;

        if (transferSlotIsRefresh(self, slot_idx)) {
            // This refresh slot is at or ahead of us.
            if (slot_start <= lmc) return 0; // already inside a refresh slot
            return slot_start - lmc;
        }
    }

    // No refresh slot remaining on this line; distance to end of line
    // where the next line's first refresh slot will be reached.
    return clock.ntsc_master_cycles_per_line - lmc;
}

/// Returns the duration of the current or next refresh slot in master cycles.
pub fn refreshSlotDurationMasterCycles(self: *const Vdp) u32 {
    const phase = currentTransferPhase(self);
    const lmc = normalizeTransferLineMasterCycle(phase.line_master_cycle);
    const slot_count = transferSlotCount(self);

    var slot_idx: u16 = 0;
    while (slot_idx < slot_count) : (slot_idx += 1) {
        const slot_end = transferSlotEndMasterCycles(self, slot_idx);
        if (slot_end <= lmc) continue;

        if (transferSlotIsRefresh(self, slot_idx)) {
            const slot_start = transferSlotStartMasterCycles(self, slot_idx);
            return slot_end - slot_start;
        }
    }
    return 0;
}

pub fn controlPortWriteWaitMasterCycles(self: *const Vdp) u32 {
    if (self.dma_active and !self.dma_fill and !self.dma_copy) return 0;
    return self.pending_port_write_delay_master_cycles;
}

pub fn writeControl(self: *Vdp, value: u16) void {
    // VDP register writes (8xxx pattern) are always processed immediately,
    // even during active DMA.  Only the second word of a 2-word command
    // is cached during 68K-bus DMA, matching GPGX (vdp_68k_ctrl_w).
    if (!self.pending_command and (value & 0xE000) == 0x8000) {
        // Register write — never buffered
    } else if (shouldBufferPortWrite(self)) {
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
            self.recordRegChange(@intCast(reg), data);
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
                self.dma_fill_ready = false;
                self.dma_fill_word = 0;
                self.dma_active = true;
                self.dma_start_delay_slots = memoryToVramDmaStartDelaySlots(self);
            } else if (dma_mode == 2) {
                self.dma_fill = true;
                self.dma_copy = false;
                self.dma_fill_ready = false;
                self.dma_fill_word = 0;
                self.dma_active = true;
                self.dma_start_delay_slots = 0;
            } else {
                self.dma_source_addr = (@as(u32, self.regs[22]) << 8) | @as(u32, self.regs[21]);
                self.dma_copy = true;
                self.dma_fill = false;
                self.dma_fill_ready = false;
                self.dma_fill_word = 0;
                self.dma_active = true;
                self.dma_start_delay_slots = 0;
            }
            // Do NOT clear the FIFO when DMA starts.  GPGX only resets the
            // FIFO at VDP hard reset, not on DMA activation.  Clearing here
            // would drop any pending data port writes that are still in the
            // pipeline, corrupting VRAM (e.g. Warsong's stats panel tiles).
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

test "dma fill begins after the initiating fifo-backed data write" {
    var vdp = Vdp.init();
    vdp.regs[12] = 0x81;
    vdp.regs[15] = 2;
    vdp.code = 0x1;
    vdp.addr = 0x0020;
    vdp.dma_active = true;
    vdp.dma_fill = true;
    vdp.dma_copy = false;
    vdp.dma_fill_ready = false;
    vdp.dma_fill_word = 0;
    vdp.dma_length = 2;
    vdp.dma_remaining = 2;

    vdp.writeData(0xABCD);

    try testing.expect(vdp.dma_active);
    try testing.expect(vdp.dma_fill_ready);
    try testing.expectEqual(@as(u16, 0xABCD), vdp.dma_fill_word);
    try testing.expectEqual(@as(u8, 1), vdp.fifo_len);
    try testing.expectEqual(@as(u8, 0), vdp.vramReadByte(0x0020));
    try testing.expectEqual(@as(u8, 0), vdp.vramReadByte(0x0021));
    try testing.expectEqual(@as(u8, 0), vdp.vramReadByte(0x0023));

    var iterations: usize = 0;
    while (vdp.dma_active and iterations < 64) : (iterations += 1) {
        const step = vdp.nextTransferStepMasterCycles();
        try testing.expect(step > 0);
        vdp.progressTransfers(step, null, null);
    }

    try testing.expect(!vdp.dma_active);
    try testing.expectEqual(@as(u8, 0xAB), vdp.vramReadByte(0x0020));
    try testing.expectEqual(@as(u8, 0xCD), vdp.vramReadByte(0x0021));
    try testing.expectEqual(@as(u8, 0xAB), vdp.vramReadByte(0x0023));
    try testing.expectEqual(@as(u8, 0xAB), vdp.vramReadByte(0x0025));
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

test "odd-address VRAM fifo writes swap byte lanes" {
    var vdp = Vdp.init();
    vdp.regs[12] = 0x81;
    vdp.code = 0x1;
    vdp.addr = 0x0021;

    vdp.writeData(0xABCD);

    var committed = false;
    var iterations: usize = 0;
    while (!committed and iterations < 32) : (iterations += 1) {
        const step = vdp.nextTransferStepMasterCycles();
        try testing.expect(step > 0);
        vdp.progressTransfers(step, null, null);
        committed = vdp.vramReadByte(0x0020) == 0xCD and vdp.vramReadByte(0x0021) == 0xAB;
    }

    try testing.expect(committed);
    try testing.expectEqual(@as(u8, 0xCD), vdp.vramReadByte(0x0020));
    try testing.expectEqual(@as(u8, 0xAB), vdp.vramReadByte(0x0021));
}

test "VRAM copy DMA uses adjacent byte addressing" {
    var vdp = Vdp.init();
    vdp.regs[15] = 1;
    vdp.addr = 0x0041;
    vdp.dma_active = true;
    vdp.dma_copy = true;
    vdp.dma_fill = false;
    vdp.dma_remaining = 1;
    vdp.dma_source_addr = 0x0020;

    vdp.vramWriteByte(0x0020, 0x12);
    vdp.vramWriteByte(0x0021, 0x34);

    progressVramCopyDma(&vdp, 1);

    try testing.expectEqual(@as(u8, 0x34), vdp.vramReadByte(0x0040));
    try testing.expectEqual(@as(u8, 0x00), vdp.vramReadByte(0x0041));
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
    // CRAM masks to 9-bit color format ----BBB0GGG0RRR0: 0x1357 & 0x0EEE = 0x0246
    try testing.expectEqual(@as(u8, 0x02), vdp.cram[0x0004]);
    try testing.expectEqual(@as(u8, 0x46), vdp.cram[0x0005]);
}

test "CRAM data reads inherit undriven bits from the fifo front word" {
    var vdp = Vdp.init();
    vdp.regs[15] = 0;
    vdp.code = 0x08;
    vdp.addr = 0x0000;
    vdp.cram[0x0000] = 0x02;
    vdp.cram[0x0001] = 0x22;
    fifoPush(&vdp, .{ .word = 0xABCD });

    try testing.expectEqual(@as(u16, 0), vdp.readData());
    try testing.expectEqual(@as(u16, 0xA323), vdp.read_buffer);
}

test "VSRAM data reads inherit undriven bits from the fifo front word" {
    var vdp = Vdp.init();
    vdp.regs[15] = 0;
    vdp.code = 0x04;
    vdp.addr = 0x0000;
    vdp.vsram[0x0000] = 0x03;
    vdp.vsram[0x0001] = 0x45;
    fifoPush(&vdp, .{ .word = 0xABCD });

    try testing.expectEqual(@as(u16, 0), vdp.readData());
    try testing.expectEqual(@as(u16, 0xAB45), vdp.read_buffer);
}

test "undocumented 8-bit VRAM reads use the adjacent byte and fifo high bits" {
    var vdp = Vdp.init();
    vdp.regs[15] = 0;
    vdp.code = 0x0C;
    vdp.addr = 0x0021;
    vdp.vramWriteByte(0x0020, 0x12);
    vdp.vramWriteByte(0x0021, 0x34);
    fifoPush(&vdp, .{ .word = 0xABCD });

    try testing.expectEqual(@as(u16, 0), vdp.readData());
    try testing.expectEqual(@as(u16, 0xAB12), vdp.read_buffer);
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

test "progressTransfers uses hblank access rules when a chunk crosses the hblank boundary" {
    var split = Vdp.init();
    split.regs[12] = 0x81;
    split.code = 0x3;
    split.addr = 0x0000;
    split.scanline = 12;
    split.line_master_cycle = split.hblankStartMasterCycles() - 1;
    split.transfer_line_master_cycle = split.line_master_cycle;
    split.writeData(0x1234);
    split.fifo[split.fifo_head].latency = 0;

    split.step(1);
    split.progressTransfers(1, null, null);
    split.setHBlank(true);
    const hblank_wait = split.nextTransferStepMasterCycles();
    try testing.expect(hblank_wait > 0);
    split.step(hblank_wait);
    split.progressTransfers(hblank_wait, null, null);
    try testing.expectEqual(@as(u8, 0), split.fifo_len);

    var combined = Vdp.init();
    combined.regs[12] = 0x81;
    combined.code = 0x3;
    combined.addr = 0x0000;
    combined.scanline = 12;
    combined.line_master_cycle = combined.hblankStartMasterCycles() - 1;
    combined.transfer_line_master_cycle = combined.line_master_cycle;
    combined.writeData(0x1234);
    combined.fifo[combined.fifo_head].latency = 0;

    const total = 1 + hblank_wait;
    combined.step(total);
    combined.progressTransfers(total, null, null);
    try testing.expectEqual(@as(u8, 0), combined.fifo_len);
}

test "nextTransferStepMasterCycles crosses the external hblank edge for dma copy" {
    var split = Vdp.init();
    split.regs[12] = 0x81;
    split.scanline = 12;
    split.line_master_cycle = split.hblankStartMasterCycles() - 1;
    split.transfer_line_master_cycle = split.line_master_cycle;
    split.dma_active = true;
    split.dma_copy = true;
    split.dma_fill = false;
    split.dma_remaining = 1;
    split.dma_length = 1;

    split.step(1);
    split.progressTransfers(1, null, null);
    split.setHBlank(true);
    const hblank_wait = split.nextTransferStepMasterCycles();
    try testing.expect(hblank_wait > 0);

    var combined = Vdp.init();
    combined.regs[12] = 0x81;
    combined.scanline = 12;
    combined.line_master_cycle = combined.hblankStartMasterCycles() - 1;
    combined.transfer_line_master_cycle = combined.line_master_cycle;
    combined.dma_active = true;
    combined.dma_copy = true;
    combined.dma_fill = false;
    combined.dma_remaining = 1;
    combined.dma_length = 1;

    try testing.expectEqual(@as(u32, 1) + hblank_wait, combined.nextTransferStepMasterCycles());
}

test "progressTransfers normalizes the transfer cursor after line overshoot" {
    var vdp = Vdp.init();
    vdp.regs[12] = 0x81;
    vdp.transfer_line_master_cycle = clock.ntsc_master_cycles_per_line - 4;

    vdp.progressTransfers(16, null, null);

    try testing.expectEqual(@as(u16, 12), vdp.transfer_line_master_cycle);
    try testing.expect(vdp.nextTransferStepMasterCycles() > 0);
}

test "advanceTransferCursor wraps correctly across multiple line periods" {
    var vdp = Vdp.init();
    vdp.regs[12] = 0x81;
    vdp.transfer_line_master_cycle = 50;

    advanceTransferCursor(&vdp, clock.ntsc_master_cycles_per_line * 2 + 100);
    try testing.expectEqual(@as(u16, 150), vdp.transfer_line_master_cycle);
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

test "projected data port write wait replays buffered data writes after the delay" {
    var split = Vdp.init();
    split.regs[12] = 0x81;
    split.code = 0x3;
    split.addr = 0x0000;
    split.scanline = 12;
    split.line_master_cycle = split.hblankStartMasterCycles() - 1;
    split.transfer_line_master_cycle = split.line_master_cycle;

    for (0..4) |i| {
        split.writeData(@intCast(0x2000 + i));
    }
    var i: usize = 0;
    while (i < @as(usize, split.fifo_len)) : (i += 1) {
        const idx = (@as(usize, split.fifo_head) + i) % split.fifo.len;
        split.fifo[idx].latency = 0;
    }

    split.pending_port_write_delay_master_cycles = pendingPortWriteReplayDelayMasterCycles(&split);
    split.writeData(0x3000);
    split.writeData(0x3001);

    const replay_delay = split.pending_port_write_delay_master_cycles;
    split.step(replay_delay);
    split.progressTransfers(replay_delay, null, null);
    split.setHBlank(true);
    const expected_wait = replay_delay + split.reserveDataPortWriteWaitMasterCycles();

    var combined = Vdp.init();
    combined.regs[12] = 0x81;
    combined.code = 0x3;
    combined.addr = 0x0000;
    combined.scanline = 12;
    combined.line_master_cycle = combined.hblankStartMasterCycles() - 1;
    combined.transfer_line_master_cycle = combined.line_master_cycle;

    for (0..4) |j| {
        combined.writeData(@intCast(0x2000 + j));
    }
    i = 0;
    while (i < @as(usize, combined.fifo_len)) : (i += 1) {
        const idx = (@as(usize, combined.fifo_head) + i) % combined.fifo.len;
        combined.fifo[idx].latency = 0;
    }

    combined.pending_port_write_delay_master_cycles = pendingPortWriteReplayDelayMasterCycles(&combined);
    combined.writeData(0x3000);
    combined.writeData(0x3001);

    try testing.expectEqual(expected_wait, combined.reserveDataPortWriteWaitMasterCycles());
}

test "projected data port write wait replays buffered control writes before buffered data writes" {
    var split = Vdp.init();
    split.regs[12] = 0x81;
    split.code = 0x1;
    split.addr = 0x0000;
    split.scanline = 12;
    split.line_master_cycle = split.hblankStartMasterCycles() - 1;
    split.transfer_line_master_cycle = split.line_master_cycle;

    for (0..4) |i| {
        split.writeData(@intCast(0x2000 + i));
    }
    var i: usize = 0;
    while (i < @as(usize, split.fifo_len)) : (i += 1) {
        const idx = (@as(usize, split.fifo_head) + i) % split.fifo.len;
        split.fifo[idx].latency = 0;
    }

    split.pending_port_write_delay_master_cycles = pendingPortWriteReplayDelayMasterCycles(&split);
    split.writeControl(0xC000);
    split.writeControl(0x0000);
    split.writeData(0x3000);
    split.writeData(0x3001);

    const replay_delay = split.pending_port_write_delay_master_cycles;
    split.step(replay_delay);
    split.progressTransfers(replay_delay, null, null);
    split.setHBlank(true);
    try testing.expectEqual(@as(u8, 0x03), split.code & 0x0F);
    const expected_wait = replay_delay + split.reserveDataPortWriteWaitMasterCycles();

    var combined = Vdp.init();
    combined.regs[12] = 0x81;
    combined.code = 0x1;
    combined.addr = 0x0000;
    combined.scanline = 12;
    combined.line_master_cycle = combined.hblankStartMasterCycles() - 1;
    combined.transfer_line_master_cycle = combined.line_master_cycle;

    for (0..4) |j| {
        combined.writeData(@intCast(0x2000 + j));
    }
    i = 0;
    while (i < @as(usize, combined.fifo_len)) : (i += 1) {
        const idx = (@as(usize, combined.fifo_head) + i) % combined.fifo.len;
        combined.fifo[idx].latency = 0;
    }

    combined.pending_port_write_delay_master_cycles = pendingPortWriteReplayDelayMasterCycles(&combined);
    combined.writeControl(0xC000);
    combined.writeControl(0x0000);
    combined.writeData(0x3000);
    combined.writeData(0x3001);

    try testing.expectEqual(expected_wait, combined.reserveDataPortWriteWaitMasterCycles());
}

fn testDmaReadWord(_: ?*anyopaque, _: u32) u16 {
    return 0xABCD;
}

test "projected data port write wait blocks on dma started by buffered control replay" {
    var split = Vdp.init();
    split.regs[1] = 0x10;
    split.regs[12] = 0x81;
    split.regs[19] = 0x01;
    split.regs[20] = 0x00;
    split.regs[21] = 0x00;
    split.regs[22] = 0x00;
    split.regs[23] = 0x00;
    split.code = 0x1;
    split.addr = 0x0000;
    split.scanline = 12;
    split.line_master_cycle = split.hblankStartMasterCycles() - 1;
    split.transfer_line_master_cycle = split.line_master_cycle;

    for (0..4) |i| {
        split.writeData(@intCast(0x2000 + i));
    }
    var i: usize = 0;
    while (i < @as(usize, split.fifo_len)) : (i += 1) {
        const idx = (@as(usize, split.fifo_head) + i) % split.fifo.len;
        split.fifo[idx].latency = 0;
    }

    split.pending_port_write_delay_master_cycles = pendingPortWriteReplayDelayMasterCycles(&split);
    split.writeControl(0x4000);
    split.writeControl(0x0080);
    split.writeData(0x3000);
    split.writeData(0x3001);

    const first_replay_delay = split.pending_port_write_delay_master_cycles;
    split.step(first_replay_delay);
    split.progressTransfers(first_replay_delay, null, null);
    split.setHBlank(true);
    try testing.expect(split.dma_active);
    try testing.expectEqual(@as(u8, 2), split.pending_port_write_len);

    var dma_wait: u32 = 0;
    while (split.dma_active) {
        const step = split.nextTransferStepMasterCycles();
        dma_wait += step;
        split.step(step);
        split.progressTransfers(step, null, testDmaReadWord);
    }

    const second_replay_delay = split.pending_port_write_delay_master_cycles;
    try testing.expect(second_replay_delay > 0);
    split.step(second_replay_delay);
    split.progressTransfers(second_replay_delay, null, null);

    const expected_wait = first_replay_delay + dma_wait + second_replay_delay + split.reserveDataPortWriteWaitMasterCycles();

    var combined = Vdp.init();
    combined.regs[1] = 0x10;
    combined.regs[12] = 0x81;
    combined.regs[19] = 0x01;
    combined.regs[20] = 0x00;
    combined.regs[21] = 0x00;
    combined.regs[22] = 0x00;
    combined.regs[23] = 0x00;
    combined.code = 0x1;
    combined.addr = 0x0000;
    combined.scanline = 12;
    combined.line_master_cycle = combined.hblankStartMasterCycles() - 1;
    combined.transfer_line_master_cycle = combined.line_master_cycle;

    for (0..4) |j| {
        combined.writeData(@intCast(0x2000 + j));
    }
    i = 0;
    while (i < @as(usize, combined.fifo_len)) : (i += 1) {
        const idx = (@as(usize, combined.fifo_head) + i) % combined.fifo.len;
        combined.fifo[idx].latency = 0;
    }

    combined.pending_port_write_delay_master_cycles = pendingPortWriteReplayDelayMasterCycles(&combined);
    combined.writeControl(0x4000);
    combined.writeControl(0x0080);
    combined.writeData(0x3000);
    combined.writeData(0x3001);

    try testing.expectEqual(expected_wait, combined.dataPortWriteWaitMasterCycles());
    try testing.expectEqual(expected_wait, combined.reserveDataPortWriteWaitMasterCycles());
}
