const Vdp = @import("vdp.zig").Vdp;

const dma_fifo_latency_slots: u8 = 3;
const pending_port_write_replay_delay_pixels: u16 = 5;

// -- FIFO queue operations --

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

// -- Transfer timing --

fn advanceTransferPhase(self: *Vdp, master_cycles: u32) void {
    const slot_cycles = self.accessSlotCycles();
    const total_cycles = @as(u32, self.transfer_master_remainder) + master_cycles;
    self.transfer_master_remainder = @intCast(total_cycles % slot_cycles);
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

fn syncProjectedDataPortWriteWait(self: *Vdp) void {
    if (self.projected_data_port_write_wait.valid) return;

    self.projected_data_port_write_wait = .{
        .valid = true,
        .fifo_len = self.fifo_len,
        .pending_fifo_len = self.pending_fifo_len,
        .transfer_remainder = self.transfer_master_remainder,
        .pending_port_write_delay_master_cycles = self.pending_port_write_delay_master_cycles,
    };

    var i: usize = 0;
    while (i < @as(usize, self.fifo_len)) : (i += 1) {
        const idx = (@as(usize, self.fifo_head) + i) % self.fifo.len;
        self.projected_data_port_write_wait.fifo_latencies[i] = self.fifo[idx].latency;
    }
}

fn projectedDataPortWriteHasRoom(self: *const Vdp) bool {
    const projected = &self.projected_data_port_write_wait;
    return projected.pending_fifo_len == 0 and @as(usize, projected.fifo_len) < self.fifo.len;
}

fn projectedAdvanceTransferPhase(self: *Vdp, master_cycles: u32) void {
    const projected = &self.projected_data_port_write_wait;
    const slot_cycles = self.accessSlotCycles();
    const total_cycles = @as(u32, projected.transfer_remainder) + master_cycles;
    projected.transfer_remainder = @intCast(total_cycles % slot_cycles);
}

fn projectedProcessAccessSlot(self: *Vdp) void {
    const projected = &self.projected_data_port_write_wait;

    var i: usize = 0;
    while (i < @as(usize, projected.fifo_len)) : (i += 1) {
        if (projected.fifo_latencies[i] > 0) {
            projected.fifo_latencies[i] -= 1;
        }
    }

    if (projected.fifo_len > 0 and projected.fifo_latencies[0] == 0) {
        i = 1;
        while (i < @as(usize, projected.fifo_len)) : (i += 1) {
            projected.fifo_latencies[i - 1] = projected.fifo_latencies[i];
        }
        projected.fifo_len -= 1;
    }

    if (projected.pending_fifo_len != 0 and @as(usize, projected.fifo_len) < self.fifo.len) {
        projected.fifo_latencies[projected.fifo_len] = dma_fifo_latency_slots;
        projected.fifo_len += 1;
        projected.pending_fifo_len -= 1;
    }
}

fn reserveProjectedDataPortWriteWait(self: *Vdp) u32 {
    syncProjectedDataPortWriteWait(self);

    var wait_master_cycles: u32 = 0;
    while (!projectedDataPortWriteHasRoom(self)) {
        const projected = &self.projected_data_port_write_wait;

        if (projected.pending_port_write_delay_master_cycles != 0) {
            wait_master_cycles += projected.pending_port_write_delay_master_cycles;
            projectedAdvanceTransferPhase(self, projected.pending_port_write_delay_master_cycles);
            projected.pending_port_write_delay_master_cycles = 0;
            continue;
        }

        const slot_wait = self.accessSlotCycles() - @as(u32, projected.transfer_remainder);
        wait_master_cycles += slot_wait;
        projected.transfer_remainder = 0;
        projectedProcessAccessSlot(self);
    }

    const projected = &self.projected_data_port_write_wait;
    projected.fifo_latencies[projected.fifo_len] = dma_fifo_latency_slots;
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

// -- Drain analysis --

fn fifoSlotsUntilNextOpen(self: *const Vdp, pending_ahead: u8) u32 {
    var fifo_latencies = [_]u8{0} ** 4;
    var fifo_len: u8 = 0;

    var i: usize = 0;
    while (i < @as(usize, self.fifo_len)) : (i += 1) {
        const idx = (@as(usize, self.fifo_head) + i) % self.fifo.len;
        fifo_latencies[i] = self.fifo[idx].latency;
        fifo_len += 1;
    }

    var queued_ahead = pending_ahead;
    while (fifo_len < fifo_latencies.len and queued_ahead > 0) {
        fifo_latencies[fifo_len] = dma_fifo_latency_slots;
        fifo_len += 1;
        queued_ahead -= 1;
    }

    if (fifo_len < fifo_latencies.len and queued_ahead == 0) return 0;

    var slots: u32 = 0;
    while (true) {
        slots += 1;

        i = 0;
        while (i < fifo_len) : (i += 1) {
            if (fifo_latencies[i] > 0) {
                fifo_latencies[i] -= 1;
            }
        }

        if (fifo_len > 0 and fifo_latencies[0] == 0) {
            i = 1;
            while (i < fifo_len) : (i += 1) {
                fifo_latencies[i - 1] = fifo_latencies[i];
            }
            fifo_len -= 1;
        }

        while (fifo_len < fifo_latencies.len) {
            if (queued_ahead > 0) {
                fifo_latencies[fifo_len] = dma_fifo_latency_slots;
                fifo_len += 1;
                queued_ahead -= 1;
                continue;
            }

            return slots;
        }
    }
}

fn fifoSlotsUntilDrained(self: *const Vdp, pending_ahead: u8) u32 {
    var fifo_latencies = [_]u8{0} ** 4;
    var fifo_len: u8 = 0;

    var i: usize = 0;
    while (i < @as(usize, self.fifo_len)) : (i += 1) {
        const idx = (@as(usize, self.fifo_head) + i) % self.fifo.len;
        fifo_latencies[i] = self.fifo[idx].latency;
        fifo_len += 1;
    }

    var queued_ahead = pending_ahead;
    var slots: u32 = 0;
    while (fifo_len != 0 or queued_ahead != 0) {
        slots += 1;

        i = 0;
        while (i < fifo_len) : (i += 1) {
            if (fifo_latencies[i] > 0) {
                fifo_latencies[i] -= 1;
            }
        }

        if (fifo_len > 0 and fifo_latencies[0] == 0) {
            i = 1;
            while (i < fifo_len) : (i += 1) {
                fifo_latencies[i - 1] = fifo_latencies[i];
            }
            fifo_len -= 1;
        }

        if (queued_ahead != 0 and fifo_len < fifo_latencies.len) {
            fifo_latencies[fifo_len] = dma_fifo_latency_slots;
            fifo_len += 1;
            queued_ahead -= 1;
        }
    }

    return slots;
}

// -- Data port read --

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

// -- Data port I/O --

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

// -- DMA operations --

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

fn progressMemoryToVramDma(self: *Vdp, access_slots: u32, read_ctx: ?*anyopaque, read_word: Vdp.DmaReadFn) void {
    var slots_left = access_slots;
    while (slots_left > 0) : (slots_left -= 1) {
        var can_transfer = true;
        if (self.dma_start_delay_slots != 0) {
            self.dma_start_delay_slots -= 1;
            can_transfer = self.dma_start_delay_slots == 0;
        }

        if (can_transfer and !fifoIsFull(self) and self.dma_remaining > 0) {
            const word = read_word(read_ctx, self.dma_source_addr);
            const entry = makeWriteFifoEntry(self, word, dma_fifo_latency_slots);
            self.dma_source_addr +%= 2;
            self.dma_remaining -= 1;
            fifoPush(self, entry);
            advanceAddr(self);
        }

        fifoTickLatency(self);

        serviceFifoFront(self);
        if (!fifoIsFull(self) and !pendingFifoIsEmpty(self)) {
            const pending = pendingFifoFront(self).*;
            pendingFifoPop(self);
            fifoPush(self, pending);
        }
    }

    finishDmaIfIdle(self);
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

fn serviceFifoFront(self: *Vdp) void {
    if (fifoIsEmpty(self)) return;

    const entry = fifoFront(self);
    if (entry.latency != 0) return;

    const committed = entry.*;
    fifoPop(self);
    writeTargetWord(self, committed.code, committed.addr, committed.word);
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
        advanceTransferPhase(self, delay_step);
        self.pending_port_write_delay_master_cycles -= @intCast(delay_step);
        available_master_cycles -= delay_step;

        if (self.pending_port_write_delay_master_cycles == 0) {
            applyBufferedPortWrites(self);
        }
    }

    const slot_cycles = self.accessSlotCycles();
    const total_cycles = @as(u32, self.transfer_master_remainder) + available_master_cycles;
    const access_slots = total_cycles / slot_cycles;
    self.transfer_master_remainder = @intCast(total_cycles % slot_cycles);
    if (access_slots == 0) return;

    if (self.dma_active and !self.dma_fill) {
        if (self.dma_copy) {
            progressVramCopyDma(self, access_slots);
            return;
        }

        if (read_word) |reader| {
            progressMemoryToVramDma(self, access_slots, read_ctx, reader);
        }
        return;
    }

    var slots_left = access_slots;
    while (slots_left > 0) : (slots_left -= 1) {
        fifoTickLatency(self);
        serviceFifoFront(self);
        if (!fifoIsFull(self) and !pendingFifoIsEmpty(self)) {
            const pending = pendingFifoFront(self).*;
            pendingFifoPop(self);
            fifoPush(self, pending);
        }
    }
}

// -- Wait queries --

pub fn dataPortWriteWaitMasterCycles(self: *const Vdp) u32 {
    if (self.dma_active and self.dma_fill) return 0;

    const pending_ahead = self.pending_fifo_len;
    const blocked = pending_ahead != 0 or fifoIsFull(self);
    if (!blocked) return 0;

    return fifoSlotsUntilNextOpen(self, pending_ahead) * self.accessSlotCycles();
}

pub fn reserveDataPortWriteWaitMasterCycles(self: *Vdp) u32 {
    if (self.dma_active and self.dma_fill) return 0;
    return reserveProjectedDataPortWriteWait(self);
}

pub fn dataPortReadWaitMasterCycles(self: *const Vdp) u32 {
    if (self.dma_active and self.dma_fill) return 0;
    if (fifoIsEmpty(self) and pendingFifoIsEmpty(self)) return 0;

    return fifoSlotsUntilDrained(self, self.pending_fifo_len) * self.accessSlotCycles();
}

pub fn shouldHaltCpu(self: *const Vdp) bool {
    return self.dma_active and !self.dma_fill and !self.dma_copy;
}

pub fn controlPortWriteWaitMasterCycles(self: *const Vdp) u32 {
    if (self.dma_active and !self.dma_fill and !self.dma_copy) return 0;
    return self.pending_port_write_delay_master_cycles;
}

// -- Control port write --

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

        // DMA
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
