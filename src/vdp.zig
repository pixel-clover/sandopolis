const std = @import("std");
const testing = std.testing;
const clock = @import("clock.zig");

pub const Vdp = struct {
    vram: [64 * 1024]u8,
    cram: [128]u8, // 64 colors * 2 bytes (9-bit color stored as word)
    vsram: [80]u8, // 40 entries * 2 bytes
    regs: [32]u8, // 24 defined, safe to have 32

    // Output Buffer (320x224 ARGB8888)
    framebuffer: [320 * 224]u32,

    // Internal State
    code: u8, // Command Code (CD0-CD5)
    addr: u16, // Address Register (16-bit enough for VRAM 64k)
    pending_command: bool, // Second half of command word pending
    command_word: u32,
    read_buffer: u16, // Prefetch buffer for VRAM reads

    // Status Flags
    vblank: bool,
    hblank: bool,
    odd_frame: bool,
    pal_mode: bool,
    vint_pending: bool,
    sprite_overflow: bool,
    sprite_collision: bool,

    dma_active: bool,

    // DMA State
    dma_fill: bool,
    dma_copy: bool,
    dma_source_addr: u32,
    dma_length: u16,
    dma_remaining: u32,
    dma_start_delay_slots: u8,
    fifo: [4]VdpWriteFifoEntry,
    fifo_head: u8,
    fifo_len: u8,
    pending_fifo: [16]VdpWriteFifoEntry,
    pending_fifo_head: u8,
    pending_fifo_len: u8,
    pending_port_writes: [8]PendingPortWrite,
    pending_port_write_head: u8,
    pending_port_write_len: u8,
    pending_port_write_delay_master_cycles: u16,
    transfer_master_remainder: u8,
    projected_data_port_write_wait: ProjectedDataPortWriteWait,

    // Timing for V-BLANK
    scanline: u16, // Current scanline (0-261 for NTSC)
    line_master_cycle: u16, // 0..(cycles_per_line-1)
    hint_counter: i16,
    hv_latched: u16,
    hv_latched_valid: bool,

    // Sprite dot overflow tracking (persists across scanlines)
    sprite_dot_overflow: bool,

    dbg_vram_writes: u64,
    dbg_cram_writes: u64,
    dbg_vsram_writes: u64,
    dbg_unknown_writes: u64,

    const DmaReadFn = *const fn (ctx: ?*anyopaque, addr: u32) u16;
    const dma_access_slot_cycles: u32 = 8;
    const dma_fifo_latency_slots: u8 = 3;
    const pending_port_write_replay_delay_pixels: u16 = 5;

    const VdpWriteFifoEntry = struct {
        code: u8 = 0,
        addr: u16 = 0,
        word: u16 = 0,
        latency: u8 = 0,
    };

    const PendingPortWrite = union(enum) {
        data: u16,
        control: u16,
    };

    const DataPortReadStorage = enum {
        vram,
        cram,
        vsram,
    };

    const DataPortReadTarget = struct {
        storage: DataPortReadStorage,
        high_index: u16,
        low_index: u16,
    };

    const ProjectedDataPortWriteWait = struct {
        valid: bool = false,
        fifo_latencies: [4]u8 = [_]u8{0} ** 4,
        fifo_len: u8 = 0,
        pending_fifo_len: u8 = 0,
        transfer_remainder: u8 = 0,
        pending_port_write_delay_master_cycles: u16 = 0,
    };

    // 3-bit Genesis color to 8-bit lookup: 0->0, 1->36, 2->73, 3->109, 4->146, 5->182, 6->219, 7->255
    const color_lut = [8]u8{ 0, 36, 73, 109, 146, 182, 219, 255 };

    pub fn init() Vdp {
        return Vdp{
            .vram = [_]u8{0} ** (64 * 1024),
            .cram = [_]u8{0} ** 128,
            .vsram = [_]u8{0} ** 80,
            .regs = [_]u8{0} ** 32,
            .framebuffer = [_]u32{0} ** (320 * 224),
            .code = 0,
            .addr = 0,
            .pending_command = false,
            .command_word = 0,
            .read_buffer = 0,
            .vblank = false,
            .hblank = false,
            .dma_active = false,
            .odd_frame = false,
            .pal_mode = false,
            .vint_pending = false,
            .sprite_overflow = false,
            .sprite_collision = false,
            .dma_fill = false,
            .dma_copy = false,
            .dma_source_addr = 0,
            .dma_length = 0,
            .dma_remaining = 0,
            .dma_start_delay_slots = 0,
            .fifo = [_]VdpWriteFifoEntry{.{}} ** 4,
            .fifo_head = 0,
            .fifo_len = 0,
            .pending_fifo = [_]VdpWriteFifoEntry{.{}} ** 16,
            .pending_fifo_head = 0,
            .pending_fifo_len = 0,
            .pending_port_writes = [_]PendingPortWrite{.{ .data = 0 }} ** 8,
            .pending_port_write_head = 0,
            .pending_port_write_len = 0,
            .pending_port_write_delay_master_cycles = 0,
            .transfer_master_remainder = 0,
            .projected_data_port_write_wait = .{},
            .scanline = 0,
            .line_master_cycle = 0,
            .hint_counter = 0,
            .hv_latched = 0,
            .hv_latched_valid = false,
            .sprite_dot_overflow = false,
            .dbg_vram_writes = 0,
            .dbg_cram_writes = 0,
            .dbg_vsram_writes = 0,
            .dbg_unknown_writes = 0,
        };
    }

    fn fifoIsEmpty(self: *const Vdp) bool {
        return self.fifo_len == 0;
    }

    fn fifoIsFull(self: *const Vdp) bool {
        return @as(usize, self.fifo_len) >= self.fifo.len;
    }

    fn pendingFifoIsEmpty(self: *const Vdp) bool {
        return self.pending_fifo_len == 0;
    }

    fn pendingFifoIsFull(self: *const Vdp) bool {
        return @as(usize, self.pending_fifo_len) >= self.pending_fifo.len;
    }

    fn makeWriteFifoEntry(self: *const Vdp, value: u16, latency: u8) VdpWriteFifoEntry {
        return .{
            .code = self.code,
            .addr = self.addr,
            .word = value,
            .latency = latency,
        };
    }

    fn fifoPush(self: *Vdp, entry: VdpWriteFifoEntry) void {
        if (self.fifoIsFull()) return;

        const tail: usize = (@as(usize, self.fifo_head) + @as(usize, self.fifo_len)) % self.fifo.len;
        self.fifo[tail] = entry;
        self.fifo_len += 1;
    }

    fn pendingFifoPush(self: *Vdp, entry: VdpWriteFifoEntry) void {
        if (self.pendingFifoIsFull()) return;

        const tail: usize = (@as(usize, self.pending_fifo_head) + @as(usize, self.pending_fifo_len)) % self.pending_fifo.len;
        self.pending_fifo[tail] = entry;
        self.pending_fifo_len += 1;
    }

    fn fifoFront(self: *Vdp) *VdpWriteFifoEntry {
        return &self.fifo[self.fifo_head];
    }

    fn pendingFifoFront(self: *Vdp) *VdpWriteFifoEntry {
        return &self.pending_fifo[self.pending_fifo_head];
    }

    fn fifoPop(self: *Vdp) void {
        if (self.fifoIsEmpty()) return;

        self.fifo_head = @intCast((@as(usize, self.fifo_head) + 1) % self.fifo.len);
        self.fifo_len -= 1;
    }

    fn pendingFifoPop(self: *Vdp) void {
        if (self.pendingFifoIsEmpty()) return;

        self.pending_fifo_head = @intCast((@as(usize, self.pending_fifo_head) + 1) % self.pending_fifo.len);
        self.pending_fifo_len -= 1;
    }

    fn pendingPortWritesIsEmpty(self: *const Vdp) bool {
        return self.pending_port_write_len == 0;
    }

    fn pendingPortWritesIsFull(self: *const Vdp) bool {
        return @as(usize, self.pending_port_write_len) >= self.pending_port_writes.len;
    }

    fn shouldBufferPortWrite(self: *const Vdp) bool {
        return (self.dma_active and !self.dma_fill and !self.dma_copy) or
            self.pending_port_write_delay_master_cycles != 0;
    }

    fn pushPendingPortWrite(self: *Vdp, write: PendingPortWrite) void {
        if (self.pendingPortWritesIsFull()) return;

        const tail: usize = (@as(usize, self.pending_port_write_head) + @as(usize, self.pending_port_write_len)) % self.pending_port_writes.len;
        self.pending_port_writes[tail] = write;
        self.pending_port_write_len += 1;
    }

    fn popPendingPortWrite(self: *Vdp) ?PendingPortWrite {
        if (self.pendingPortWritesIsEmpty()) return null;

        const write = self.pending_port_writes[self.pending_port_write_head];
        self.pending_port_write_head = @intCast((@as(usize, self.pending_port_write_head) + 1) % self.pending_port_writes.len);
        self.pending_port_write_len -= 1;
        return write;
    }

    fn advanceTransferPhase(self: *Vdp, master_cycles: u32) void {
        const total_cycles = @as(u32, self.transfer_master_remainder) + master_cycles;
        self.transfer_master_remainder = @intCast(total_cycles % dma_access_slot_cycles);
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
        const total_cycles = @as(u32, projected.transfer_remainder) + master_cycles;
        projected.transfer_remainder = @intCast(total_cycles % dma_access_slot_cycles);
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
        self.syncProjectedDataPortWriteWait();

        var wait_master_cycles: u32 = 0;
        while (!self.projectedDataPortWriteHasRoom()) {
            const projected = &self.projected_data_port_write_wait;

            if (projected.pending_port_write_delay_master_cycles != 0) {
                wait_master_cycles += projected.pending_port_write_delay_master_cycles;
                self.projectedAdvanceTransferPhase(projected.pending_port_write_delay_master_cycles);
                projected.pending_port_write_delay_master_cycles = 0;
                continue;
            }

            const slot_wait = dma_access_slot_cycles - @as(u32, projected.transfer_remainder);
            wait_master_cycles += slot_wait;
            projected.transfer_remainder = 0;
            self.projectedProcessAccessSlot();
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

    fn dataPortReadTargetFor(code: u8, addr: u16) ?DataPortReadTarget {
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

    fn applyQueuedWriteToDataPortReadTarget(target: DataPortReadTarget, high: *u8, low: *u8, write_storage: DataPortReadStorage, write_base: u16, value: u16) void {
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

    fn applyQueuedEntryToDataPortReadTarget(target: DataPortReadTarget, high: *u8, low: *u8, entry: VdpWriteFifoEntry) void {
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

        const base = self.currentDataPortReadWord(code, addr) orelse return null;
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

    // -- Mode queries --

    pub fn isH40(self: *const Vdp) bool {
        // Register 12: bits 7 and 0 both enable H40 mode
        return (self.regs[12] & 0x81) != 0;
    }

    fn screenWidth(self: *const Vdp) u16 {
        return if (self.isH40()) 320 else 256;
    }

    fn screenWidthCells(self: *const Vdp) u16 {
        return if (self.isH40()) 40 else 32;
    }

    fn maxSpritesPerLine(self: *const Vdp) u8 {
        return if (self.isH40()) 20 else 16;
    }

    fn maxSpritePixelsPerLine(self: *const Vdp) u16 {
        return if (self.isH40()) 320 else 256;
    }

    fn maxSpritesTotal(self: *const Vdp) u8 {
        return if (self.isH40()) 80 else 64;
    }

    fn isDisplayEnabled(self: *const Vdp) bool {
        return (self.regs[1] & 0x40) != 0;
    }

    fn isShadowHighlightEnabled(self: *const Vdp) bool {
        return (self.regs[12] & 0x08) != 0;
    }

    pub fn isInterlaceMode2(self: *const Vdp) bool {
        return (self.regs[12] & 0x06) == 0x06;
    }

    pub fn isHVCounterLatchEnabled(self: *const Vdp) bool {
        return (self.regs[0] & 0x02) != 0;
    }

    fn tileHeightShift(self: *const Vdp) u4 {
        return if (self.isInterlaceMode2()) 4 else 3;
    }

    fn tileHeight(self: *const Vdp) u8 {
        return if (self.isInterlaceMode2()) 16 else 8;
    }

    fn tileHeightMask(self: *const Vdp) u8 {
        return if (self.isInterlaceMode2()) 0xF else 0x7;
    }

    fn tileSizeBytes(self: *const Vdp) u32 {
        return if (self.isInterlaceMode2()) 64 else 32;
    }

    // -- VRAM access (with byte-swap for word-oriented access) --

    fn vramReadByte(self: *const Vdp, address: u16) u8 {
        return self.vram[address & 0xFFFF];
    }

    fn vramWriteByte(self: *Vdp, address: u16, value: u8) void {
        self.vram[address & 0xFFFF] = value;
    }

    // VRAM word write with byte-swap (address XOR 1 for odd/even byte ordering)
    fn vramWriteWord(self: *Vdp, address: u16, value: u16) void {
        const addr = address & 0xFFFE; // Word-align
        self.vram[addr] = @intCast((value >> 8) & 0xFF);
        self.vram[addr + 1] = @intCast(value & 0xFF);
    }

    // -- Color conversion --

    pub fn getPaletteColor(self: *const Vdp, index: u8) u32 {
        const offset = @as(usize, index & 0x3F) * 2;
        const val_hi = self.cram[offset];
        const val_lo = self.cram[offset + 1];
        const color = (@as(u16, val_hi) << 8) | val_lo;

        const b3: u3 = @intCast((color >> 9) & 0x7);
        const g3: u3 = @intCast((color >> 5) & 0x7);
        const r3: u3 = @intCast((color >> 1) & 0x7);

        const r8: u32 = color_lut[r3];
        const g8: u32 = color_lut[g3];
        const b8: u32 = color_lut[b3];

        return (0xFF000000) | (r8 << 16) | (g8 << 8) | b8;
    }

    fn getPaletteColorShadow(self: *const Vdp, index: u8) u32 {
        const normal = self.getPaletteColor(index);
        // Shadow = color / 2
        const r = (normal >> 16) & 0xFF;
        const g = (normal >> 8) & 0xFF;
        const b = normal & 0xFF;
        return 0xFF000000 | ((r >> 1) << 16) | ((g >> 1) << 8) | (b >> 1);
    }

    fn getPaletteColorHighlight(self: *const Vdp, index: u8) u32 {
        const normal = self.getPaletteColor(index);
        // Highlight = color / 2 + 0x808080
        const r: u32 = @min(((normal >> 16) & 0xFF) / 2 + 0x80, 0xFF);
        const g: u32 = @min(((normal >> 8) & 0xFF) / 2 + 0x80, 0xFF);
        const b: u32 = @min((normal & 0xFF) / 2 + 0x80, 0xFF);
        return 0xFF000000 | (r << 16) | (g << 8) | b;
    }

    // -- Rendering --

    // Shadow/highlight pixel tags stored in bits [31:30] of a temporary line buffer.
    // We use a separate priority/SH line buffer to avoid corrupting the framebuffer format.
    const SH_NORMAL: u8 = 0;
    const SH_SHADOW: u8 = 1;
    const SH_HIGHLIGHT: u8 = 2;

    const LAYER_BACKDROP: u8 = 0;
    const LAYER_PLANE_B_LOW: u8 = 1;
    const LAYER_PLANE_A_LOW: u8 = 2;
    const LAYER_SPRITE_LOW: u8 = 3;
    const LAYER_PLANE_B_HIGH: u8 = 4;
    const LAYER_PLANE_A_HIGH: u8 = 5;
    const LAYER_SPRITE_HIGH: u8 = 6;

    fn layerOrder(source_id: u8, high_pri: bool) u8 {
        return switch (source_id) {
            1 => if (high_pri) LAYER_PLANE_B_HIGH else LAYER_PLANE_B_LOW,
            2 => if (high_pri) LAYER_PLANE_A_HIGH else LAYER_PLANE_A_LOW,
            3 => if (high_pri) LAYER_SPRITE_HIGH else LAYER_SPRITE_LOW,
            else => LAYER_BACKDROP,
        };
    }

    pub fn renderScanline(self: *Vdp, line: u16) void {
        const screen_w = self.screenWidth();
        if (line >= 224) return;
        if (!self.isDisplayEnabled()) {
            // Display disabled — fill with backdrop.
            const line_start = @as(usize, line) * 320;
            const backdrop = self.getPaletteColor(self.regs[7] & 0x3F);
            for (0..320) |x| {
                self.framebuffer[line_start + x] = backdrop;
            }
            return;
        }

        const sh_mode = self.isShadowHighlightEnabled();
        const tile_h = self.tileHeight();
        const tile_h_shift = self.tileHeightShift();
        const tile_h_mask = self.tileHeightMask();
        const tile_sz = self.tileSizeBytes();

        // Plane table addresses.
        const plane_a_base = @as(u32, self.regs[2] & 0x38) << 10;
        const plane_b_base = @as(u32, self.regs[4] & 0x07) << 13;

        const plane_width_tiles: u16 = switch (self.regs[16] & 0x3) {
            0 => 32,
            1 => 64,
            3 => 128,
            else => 32,
        };
        const plane_height_tiles: u16 = switch ((self.regs[16] >> 4) & 0x3) {
            0 => 32,
            1 => 64,
            3 => 128,
            else => 32,
        };
        const plane_width_px: i32 = @as(i32, plane_width_tiles) * 8;
        const plane_height_px: i32 = @as(i32, plane_height_tiles) * @as(i32, tile_h);

        const backdrop_idx = self.regs[7] & 0x3F;
        const hscroll_base = (@as(u16, self.regs[13]) & 0x3F) << 10;
        const line_start = @as(usize, line) * 320;

        // Per-pixel line buffers for compositing.
        // pixel_buf stores palette index (0 = transparent/backdrop).
        // layer_buf stores the resolved Genesis layer order for each pixel.
        // source_buf tracks which producer last won the pixel so sprite collision can be detected.
        var pixel_buf: [320]u8 = [_]u8{0} ** 320;
        var layer_buf: [320]u8 = [_]u8{LAYER_BACKDROP} ** 320;
        var source_buf: [320]u8 = [_]u8{0} ** 320;
        var sh_buf: [320]u8 = undefined;
        if (sh_mode) {
            // In S/H mode, all pixels start as shadow unless overwritten.
            @memset(&sh_buf, SH_SHADOW);
        } else {
            @memset(&sh_buf, SH_NORMAL);
        }

        // Window plane determination.
        const win_h_pos = self.regs[17];
        const win_v_pos = self.regs[18];
        const win_right = (win_h_pos & 0x80) != 0;
        const win_h_cell = @as(u16, win_h_pos & 0x1F) * 2;
        const win_down = (win_v_pos & 0x80) != 0;
        const win_v_cell = @as(u16, win_v_pos & 0x1F) * 8;
        const line_in_win_v: bool = if (win_down) (line >= win_v_cell) else (line < win_v_cell);
        const win_left_px: u16 = if (win_right) @min(win_h_cell * 8, screen_w) else 0;
        const win_right_px: u16 = if (win_right) screen_w else @min(win_h_cell * 8, screen_w);

        // Render Plane B.
        self.renderPlaneToBuffer(line, plane_b_base, plane_width_tiles, plane_height_tiles, plane_width_px, plane_height_px, hscroll_base, false, tile_h, tile_h_shift, tile_h_mask, tile_sz, &pixel_buf, &layer_buf, &source_buf, 1, 0, screen_w);

        // Render Plane A / Window.
        if (line_in_win_v and win_left_px < win_right_px) {
            if (win_left_px > 0) {
                self.renderPlaneToBuffer(line, plane_a_base, plane_width_tiles, plane_height_tiles, plane_width_px, plane_height_px, hscroll_base, true, tile_h, tile_h_shift, tile_h_mask, tile_sz, &pixel_buf, &layer_buf, &source_buf, 2, 0, win_left_px);
            }
            if (win_right_px < screen_w) {
                self.renderPlaneToBuffer(line, plane_a_base, plane_width_tiles, plane_height_tiles, plane_width_px, plane_height_px, hscroll_base, true, tile_h, tile_h_shift, tile_h_mask, tile_sz, &pixel_buf, &layer_buf, &source_buf, 2, win_right_px, screen_w);
            }
            self.renderWindowToBuffer(line, tile_h_mask, tile_sz, &pixel_buf, &layer_buf, &source_buf, win_left_px, win_right_px);
        } else {
            self.renderPlaneToBuffer(line, plane_a_base, plane_width_tiles, plane_height_tiles, plane_width_px, plane_height_px, hscroll_base, true, tile_h, tile_h_shift, tile_h_mask, tile_sz, &pixel_buf, &layer_buf, &source_buf, 2, 0, screen_w);
        }

        // Render sprites.
        self.renderSpritesToBuffer(line, tile_h, tile_h_mask, tile_sz, &pixel_buf, &layer_buf, &source_buf, &sh_buf, sh_mode);

        // Final compositing to framebuffer.
        for (0..@as(usize, screen_w)) |x| {
            const pal_idx = pixel_buf[x];
            if (sh_mode) {
                if (pal_idx == 0) {
                    self.framebuffer[line_start + x] = self.getPaletteColorShadow(backdrop_idx);
                } else {
                    self.framebuffer[line_start + x] = switch (sh_buf[x]) {
                        SH_SHADOW => self.getPaletteColorShadow(pal_idx),
                        SH_HIGHLIGHT => self.getPaletteColorHighlight(pal_idx),
                        else => self.getPaletteColor(pal_idx),
                    };
                }
            } else {
                if (pal_idx == 0) {
                    self.framebuffer[line_start + x] = self.getPaletteColor(backdrop_idx);
                } else {
                    self.framebuffer[line_start + x] = self.getPaletteColor(pal_idx);
                }
            }
        }
        // If H32, fill the right 64 pixels with backdrop.
        if (screen_w < 320) {
            const backdrop = self.getPaletteColor(backdrop_idx);
            for (@as(usize, screen_w)..320) |x| {
                self.framebuffer[line_start + x] = backdrop;
            }
        }
    }

    fn renderPlaneToBuffer(
        self: *Vdp,
        line: u16,
        plane_base: u32,
        plane_width_tiles: u16,
        plane_height_tiles: u16,
        plane_width_px: i32,
        plane_height_px: i32,
        hscroll_base: u16,
        is_plane_a: bool,
        tile_h: u8,
        tile_h_shift: u4,
        tile_h_mask: u8,
        tile_sz: u32,
        pixel_buf: *[320]u8,
        layer_buf: *[320]u8,
        source_buf: *[320]u8,
        source_id: u8,
        start_x: u16,
        end_x: u16,
    ) void {
        const hscroll = self.readHScroll(hscroll_base, line, is_plane_a);
        const vscroll_mode = (self.regs[11] >> 2) & 1;
        _ = tile_h;

        var x: u16 = start_x;
        while (x < end_x) : (x += 1) {
            const vscroll_val: i32 = if (vscroll_mode != 0) blk: {
                const col_pair = x / 16;
                const vs_offset: u16 = if (is_plane_a) col_pair * 4 else col_pair * 4 + 2;
                if (vs_offset + 1 < 80) {
                    const hi = self.vsram[vs_offset];
                    const lo = self.vsram[vs_offset + 1];
                    const raw = (@as(u16, hi) << 8) | lo;
                    break :blk @as(i32, @as(i16, @bitCast(raw & 0x07FF)));
                } else {
                    break :blk self.readVScroll(is_plane_a);
                }
            } else self.readVScroll(is_plane_a);

            const x_scrolled = @as(i32, @intCast(x)) - hscroll;
            const y_scrolled = @as(i32, line) + vscroll_val;
            const x_wrapped = @mod(x_scrolled, plane_width_px);
            const y_wrapped = @mod(y_scrolled, plane_height_px);
            const tile_col: u16 = @intCast(@divFloor(x_wrapped, 8));
            const tile_row: u16 = @intCast(@as(u32, @intCast(y_wrapped)) >> tile_h_shift);

            const table_index = (@as(u32, tile_row % plane_height_tiles) * @as(u32, plane_width_tiles)) + @as(u32, tile_col % plane_width_tiles);
            const entry_addr: u16 = @intCast((plane_base + (table_index * 2)) & 0xFFFF);
            const entry_hi = self.vramReadByte(entry_addr);
            const entry_lo = self.vramReadByte(entry_addr + 1);
            const entry = (@as(u16, entry_hi) << 8) | entry_lo;

            const pattern_idx = entry & 0x07FF;
            const palette_idx: u8 = @intCast((entry >> 13) & 0x3);
            const vflip = (entry & 0x1000) != 0;
            const hflip = (entry & 0x0800) != 0;
            const high_pri = (entry & 0x8000) != 0;

            const fine_x: u8 = @intCast(@mod(x_wrapped, 8));
            const fine_y: u8 = @intCast(@as(u32, @intCast(y_wrapped)) & tile_h_mask);
            const px = if (hflip) @as(u8, 7) - fine_x else fine_x;
            const py = if (vflip) tile_h_mask - fine_y else fine_y;

            const pattern_addr = (@as(u32, pattern_idx) * tile_sz) + (@as(u32, py) * 4) + @as(u32, px / 2);
            const pattern_byte = self.vramReadByte(@intCast(pattern_addr & 0xFFFF));
            const color_idx: u8 = if ((px & 1) == 0) (pattern_byte >> 4) & 0xF else pattern_byte & 0xF;
            if (color_idx == 0) continue;

            const full_idx = palette_idx * 16 + color_idx;
            const new_layer = layerOrder(source_id, high_pri);
            const cur_layer = layer_buf[x];

            if (new_layer >= cur_layer) {
                pixel_buf[x] = full_idx;
                layer_buf[x] = new_layer;
                source_buf[x] = source_id;
            }
        }
    }

    fn renderWindowToBuffer(
        self: *Vdp,
        line: u16,
        tile_h_mask: u8,
        tile_sz: u32,
        pixel_buf: *[320]u8,
        layer_buf: *[320]u8,
        source_buf: *[320]u8,
        start_x: u16,
        end_x: u16,
    ) void {
        // Window nametable base: In H40 mode bit 0 is ignored.
        const win_base: u32 = if (self.isH40())
            @as(u32, self.regs[3] & 0x3E) << 10
        else
            @as(u32, self.regs[3] & 0x3F) << 10;
        const win_width: u32 = if (self.isH40()) 64 else 32;
        const tile_row: u32 = @as(u32, line) / 8;
        const fine_y: u8 = @intCast(@as(u32, line) & tile_h_mask);

        var x: u16 = start_x;
        while (x < end_x) : (x += 1) {
            const tile_col: u32 = @as(u32, x) / 8;
            const fine_x: u8 = @intCast(@as(u32, x) % 8);

            const table_index = tile_row * win_width + tile_col;
            const entry_addr: u16 = @intCast((win_base + table_index * 2) & 0xFFFF);
            const entry_hi = self.vramReadByte(entry_addr);
            const entry_lo = self.vramReadByte(entry_addr + 1);
            const entry = (@as(u16, entry_hi) << 8) | entry_lo;

            const pattern_idx = entry & 0x07FF;
            const palette_idx: u8 = @intCast((entry >> 13) & 0x3);
            const vflip = (entry & 0x1000) != 0;
            const hflip = (entry & 0x0800) != 0;
            const high_pri = (entry & 0x8000) != 0;

            const px = if (hflip) @as(u8, 7) - fine_x else fine_x;
            const py = if (vflip) tile_h_mask - fine_y else fine_y;

            const pattern_addr = (@as(u32, pattern_idx) * tile_sz) + (@as(u32, py) * 4) + @as(u32, px / 2);
            const pattern_byte = self.vramReadByte(@intCast(pattern_addr & 0xFFFF));
            const color_idx: u8 = if ((px & 1) == 0) (pattern_byte >> 4) & 0xF else pattern_byte & 0xF;
            if (color_idx == 0) continue;

            const full_idx = palette_idx * 16 + color_idx;
            const new_layer = layerOrder(2, high_pri);
            const cur_layer = layer_buf[x];

            if (new_layer >= cur_layer) {
                pixel_buf[x] = full_idx;
                layer_buf[x] = new_layer;
                source_buf[x] = 2;
            }
        }
    }

    fn renderSpritesToBuffer(
        self: *Vdp,
        line: u16,
        tile_h: u8,
        tile_h_mask: u8,
        tile_sz: u32,
        pixel_buf: *[320]u8,
        layer_buf: *[320]u8,
        source_buf: *[320]u8,
        sh_buf: *[320]u8,
        sh_mode: bool,
    ) void {
        const screen_w = self.screenWidth();
        const sprite_base: u16 = if (self.isH40())
            ((@as(u16, self.regs[5] & 0x7F) << 9) & 0xFC00)
        else
            ((@as(u16, self.regs[5] & 0x7F) << 9) & 0xFE00);
        const y_line: i32 = @intCast(line);
        const max_sprites = self.maxSpritesPerLine();
        const max_pixels = self.maxSpritePixelsPerLine();
        const max_total = self.maxSpritesTotal();

        var sprites_on_line: u8 = 0;
        var pixels_drawn: u16 = 0;
        var sprite_masked = false;
        var had_nonzero_x = false;
        var dot_overflow = false;

        var sprite_index: u8 = 0;
        var count: u8 = 0;
        while (count < max_total) : (count += 1) {
            const entry_addr: u16 = sprite_base +% (@as(u16, sprite_index) *% 8);
            const y_word = (@as(u16, self.vramReadByte(entry_addr)) << 8) | self.vramReadByte(entry_addr + 1);
            const size = self.vramReadByte(entry_addr + 2);
            const link = self.vramReadByte(entry_addr + 3) & 0x7F;
            const attr = (@as(u16, self.vramReadByte(entry_addr + 4)) << 8) | self.vramReadByte(entry_addr + 5);
            const x_word = (@as(u16, self.vramReadByte(entry_addr + 6)) << 8) | self.vramReadByte(entry_addr + 7);

            const h_size: i32 = @as(i32, ((size >> 2) & 0x3)) + 1;
            const v_size: i32 = @as(i32, (size & 0x3)) + 1;
            const sprite_h_px = h_size * 8;
            const sprite_v_px = v_size * @as(i32, tile_h);
            const y_pos = @as(i32, @intCast(y_word & 0x03FF)) - 128;
            const x_pos_raw: u16 = x_word & 0x01FF;
            const x_pos = @as(i32, @intCast(x_pos_raw)) - 128;
            const y_in_non_flipped = y_line - y_pos;

            if (y_in_non_flipped >= 0 and y_in_non_flipped < sprite_v_px) {
                sprites_on_line += 1;

                // Sprite per-line limit check.
                if (sprites_on_line > max_sprites) {
                    self.sprite_overflow = true;
                    break;
                }

                // Sprite masking: x=0 sprite masks remaining sprites on this line,
                // but only if a non-zero-x sprite was already seen, OR if dot overflow
                // occurred on the previous line.
                if (x_pos_raw == 0) {
                    if (had_nonzero_x or self.sprite_dot_overflow) {
                        sprite_masked = true;
                        // Masked sprites still count toward limits but don't draw.
                    }
                } else {
                    had_nonzero_x = true;
                }

                if (!sprite_masked) {
                    const is_high = (attr & 0x8000) != 0;
                    const y_flip = (attr & 0x1000) != 0;
                    const x_flip = (attr & 0x0800) != 0;
                    const palette: u8 = @intCast((attr >> 13) & 0x3);
                    const tile_base: u16 = attr & 0x07FF;
                    const y_in_sprite = if (y_flip) (sprite_v_px - 1 - y_in_non_flipped) else y_in_non_flipped;
                    const tile_y: u16 = @intCast(@as(u32, @intCast(y_in_sprite)) >> @intCast(self.tileHeightShift()));
                    const fine_y: u8 = @intCast(@as(u32, @intCast(y_in_sprite)) & tile_h_mask);
                    const v_size_u16: u16 = @intCast(v_size);

                    var x_pix: i32 = 0;
                    while (x_pix < sprite_h_px) : (x_pix += 1) {
                        const screen_x = x_pos + x_pix;
                        if (screen_x < 0 or screen_x >= screen_w) continue;

                        pixels_drawn += 1;
                        if (pixels_drawn > max_pixels) {
                            dot_overflow = true;
                            break;
                        }

                        const x_in_sprite = if (x_flip) (sprite_h_px - 1 - x_pix) else x_pix;
                        const tile_x: u16 = @intCast(@divFloor(x_in_sprite, 8));
                        const fine_x: u8 = @intCast(@mod(x_in_sprite, 8));
                        const tile_index: u16 = tile_base +% (tile_x *% v_size_u16) +% tile_y;
                        const pattern_addr = (@as(u32, tile_index) * tile_sz) + (@as(u32, fine_y) * 4) + @as(u32, fine_x / 2);
                        const pattern_byte = self.vramReadByte(@intCast(pattern_addr & 0xFFFF));
                        const color_idx: u8 = if ((fine_x & 1) == 0) (pattern_byte >> 4) & 0xF else pattern_byte & 0xF;
                        if (color_idx == 0) continue;

                        const sx: usize = @intCast(screen_x);
                        const palette_index = (palette * 16) + color_idx;

                        // Sprite collision: non-transparent sprite pixel on already-drawn sprite pixel
                        if (source_buf[sx] == 3) {
                            self.sprite_collision = true;
                        }

                        // Shadow/Highlight special sprite colors
                        if (sh_mode and palette == 3 and color_idx == 14) {
                            // Palette 3, color 14 = always normal (cancels shadow)
                            sh_buf[sx] = SH_NORMAL;
                            continue;
                        }
                        if (sh_mode and palette == 3 and color_idx == 15) {
                            // Palette 3, color 15 = highlight
                            if (sh_buf[sx] == SH_SHADOW) {
                                sh_buf[sx] = SH_NORMAL;
                            } else {
                                sh_buf[sx] = SH_HIGHLIGHT;
                            }
                            continue;
                        }

                        const new_layer = layerOrder(3, is_high);
                        const cur_layer = layer_buf[sx];

                        // Sprites: higher layer wins; same-layer earlier sprite keeps the pixel.
                        if (new_layer > cur_layer) {
                            pixel_buf[sx] = palette_index;
                            layer_buf[sx] = new_layer;
                            source_buf[sx] = 3;
                            if (sh_mode) {
                                if (is_high) {
                                    sh_buf[sx] = SH_NORMAL;
                                }
                                // Low priority sprite pixels keep the background's S/H state.
                            }
                        }
                    }
                    if (dot_overflow) break;
                }
            }

            if (link == 0 or link >= max_total) break;
            sprite_index = link;
        }

        self.sprite_dot_overflow = dot_overflow;
    }

    // -- Scroll reading --

    fn readHScroll(self: *const Vdp, table_base: u16, line: u16, plane_a: bool) i32 {
        const hmode = self.regs[11] & 0x3;
        var offset: u16 = if (plane_a) @as(u16, 0) else @as(u16, 2);
        switch (hmode) {
            2 => {
                const cell_row = (line / 8) * 4;
                offset = cell_row + (if (plane_a) @as(u16, 0) else @as(u16, 2));
            },
            3 => {
                const line_index = (line & 0xFF) * 4;
                offset = line_index + (if (plane_a) @as(u16, 0) else @as(u16, 2));
            },
            else => {},
        }
        const word = (@as(u16, self.vramReadByte(table_base +% offset)) << 8) | self.vramReadByte(table_base +% offset +% 1);
        return @as(i16, @bitCast(word));
    }

    fn readVScroll(self: *const Vdp, plane_a: bool) i32 {
        const offset: u16 = if (plane_a) 0 else 2;
        const hi = self.vsram[offset];
        const lo = self.vsram[offset + 1];
        const raw = (@as(u16, hi) << 8) | lo;
        return @as(i16, @bitCast(raw & 0x07FF));
    }

    // -- Data Port --

    pub fn readData(self: *Vdp) u16 {
        self.pending_command = false;
        const result = self.read_buffer;

        // Prefetch next value into buffer.
        if (self.currentDataPortReadWordWithQueuedWrites(self.code, self.addr)) |word| {
            self.read_buffer = word;
        }

        self.advanceAddr();
        return result;
    }

    fn writeTargetWord(self: *Vdp, code: u8, addr: u16, value: u16) void {
        switch (code & 0xF) {
            0x1 => { // VRAM Write
                self.dbg_vram_writes += 1;
                // VRAM writes swap bytes: low byte to addr, high byte to addr^1.
                self.vramWriteByte(addr, @intCast((value >> 8) & 0xFF));
                self.vramWriteByte(addr +% 1, @intCast(value & 0xFF));
            },
            0x3 => { // CRAM Write
                self.dbg_cram_writes += 1;
                const idx = addr & 0x7E;
                self.cram[idx] = @intCast((value >> 8) & 0xFF);
                self.cram[idx + 1] = @intCast(value & 0xFF);
            },
            0x5 => { // VSRAM Write
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
        if (self.shouldBufferPortWrite()) {
            self.pushPendingPortWrite(.{ .data = value });
            return;
        }

        self.pending_command = false;

        if (self.dma_active and self.dma_fill) {
            var len: u32 = self.dma_length;
            if (len == 0) len = 0x10000;
            const target = self.code & 0xF;
            if (target == 0x1) {
                // VRAM fill — fills with high byte at each address.
                const fill_byte: u8 = @intCast((value >> 8) & 0xFF);
                while (len > 0) : (len -= 1) {
                    // VRAM fill writes to addr XOR 1 (byte-swap).
                    self.vramWriteByte(self.addr ^ 1, fill_byte);
                    self.advanceAddr();
                }
            } else if (target == 0x3) {
                while (len > 0) : (len -= 1) {
                    const idx = self.addr & 0x7E;
                    self.cram[idx] = @intCast((value >> 8) & 0xFF);
                    self.cram[idx + 1] = @intCast(value & 0xFF);
                    self.advanceAddr();
                }
            } else if (target == 0x5) {
                while (len > 0) : (len -= 1) {
                    const idx: u16 = (self.addr >> 1) % 40 * 2;
                    self.vsram[idx] = @intCast((value >> 8) & 0xFF);
                    self.vsram[idx + 1] = @intCast(value & 0xFF);
                    self.advanceAddr();
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

        const entry = self.makeWriteFifoEntry(value, dma_fifo_latency_slots);
        if (self.fifoIsFull()) {
            self.pendingFifoPush(entry);
        } else {
            self.fifoPush(entry);
        }
        self.advanceAddr();
    }

    pub fn advanceAddr(self: *Vdp) void {
        const auto_inc = self.regs[15];
        self.addr = self.addr +% auto_inc;
    }

    fn finishDmaIfIdle(self: *Vdp) void {
        if (self.dma_remaining != 0 or !self.fifoIsEmpty()) return;

        self.dma_length = 0;
        self.dma_active = false;
        self.dma_fill = false;
        self.dma_copy = false;
        self.dma_start_delay_slots = 0;
        if (!self.pendingPortWritesIsEmpty()) {
            self.pending_port_write_delay_master_cycles = self.pendingPortWriteReplayDelayMasterCycles();
        }
    }

    fn progressMemoryToVramDma(self: *Vdp, access_slots: u32, read_ctx: ?*anyopaque, read_word: DmaReadFn) void {
        var slots_left = access_slots;
        while (slots_left > 0) : (slots_left -= 1) {
            var can_transfer = true;
            if (self.dma_start_delay_slots != 0) {
                self.dma_start_delay_slots -= 1;
                can_transfer = self.dma_start_delay_slots == 0;
            }

            if (can_transfer and !self.fifoIsFull() and self.dma_remaining > 0) {
                const word = read_word(read_ctx, self.dma_source_addr);
                const entry = self.makeWriteFifoEntry(word, dma_fifo_latency_slots);
                self.dma_source_addr +%= 2;
                self.dma_remaining -= 1;
                self.fifoPush(entry);
                self.advanceAddr();
            }

            self.fifoTickLatency();

            self.serviceFifoFront();
            if (!self.fifoIsFull() and !self.pendingFifoIsEmpty()) {
                const pending = self.pendingFifoFront().*;
                self.pendingFifoPop();
                self.fifoPush(pending);
            }
        }

        self.finishDmaIfIdle();
    }

    fn progressVramCopyDma(self: *Vdp, access_slots: u32) void {
        if (self.dma_remaining == 0) {
            self.finishDmaIfIdle();
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
            self.advanceAddr();
        }

        self.dma_remaining -= copied;
        self.finishDmaIfIdle();
    }

    fn serviceFifoFront(self: *Vdp) void {
        if (self.fifoIsEmpty()) return;

        const entry = self.fifoFront();
        if (entry.latency != 0) return;

        const committed = entry.*;
        self.fifoPop();
        self.writeTargetWord(committed.code, committed.addr, committed.word);
    }

    fn applyBufferedPortWrites(self: *Vdp) void {
        while (!self.pendingPortWritesIsEmpty()) {
            if (self.dma_active and !self.dma_fill and !self.dma_copy) return;

            const pending = self.popPendingPortWrite() orelse return;
            switch (pending) {
                .data => |value| self.writeData(value),
                .control => |value| self.writeControl(value),
            }
        }
    }

    pub fn progressTransfers(self: *Vdp, master_cycles: u32, read_ctx: ?*anyopaque, read_word: ?DmaReadFn) void {
        defer self.invalidateProjectedDataPortWriteWait();

        var available_master_cycles = master_cycles;
        if (self.pending_port_write_delay_master_cycles != 0) {
            const delay_step = @min(available_master_cycles, self.pending_port_write_delay_master_cycles);
            self.advanceTransferPhase(delay_step);
            self.pending_port_write_delay_master_cycles -= @intCast(delay_step);
            available_master_cycles -= delay_step;

            if (self.pending_port_write_delay_master_cycles == 0) {
                self.applyBufferedPortWrites();
            }
        }

        const total_cycles = @as(u32, self.transfer_master_remainder) + available_master_cycles;
        const access_slots = total_cycles / dma_access_slot_cycles;
        self.transfer_master_remainder = @intCast(total_cycles % dma_access_slot_cycles);
        if (access_slots == 0) return;

        if (self.dma_active and !self.dma_fill) {
            if (self.dma_copy) {
                self.progressVramCopyDma(access_slots);
                return;
            }

            if (read_word) |reader| {
                self.progressMemoryToVramDma(access_slots, read_ctx, reader);
            }
            return;
        }

        var slots_left = access_slots;
        while (slots_left > 0) : (slots_left -= 1) {
            self.fifoTickLatency();
            self.serviceFifoFront();
            if (!self.fifoIsFull() and !self.pendingFifoIsEmpty()) {
                const pending = self.pendingFifoFront().*;
                self.pendingFifoPop();
                self.fifoPush(pending);
            }
        }
    }

    pub fn dataPortWriteWaitMasterCycles(self: *const Vdp) u32 {
        if (self.dma_active and self.dma_fill) return 0;

        const pending_ahead = self.pending_fifo_len;
        const blocked = pending_ahead != 0 or self.fifoIsFull();
        if (!blocked) return 0;

        return self.fifoSlotsUntilNextOpen(pending_ahead) * dma_access_slot_cycles;
    }

    pub fn reserveDataPortWriteWaitMasterCycles(self: *Vdp) u32 {
        if (self.dma_active and self.dma_fill) return 0;
        return self.reserveProjectedDataPortWriteWait();
    }

    pub fn dataPortReadWaitMasterCycles(self: *const Vdp) u32 {
        if (self.dma_active and self.dma_fill) return 0;
        if (self.fifoIsEmpty() and self.pendingFifoIsEmpty()) return 0;

        return self.fifoSlotsUntilDrained(self.pending_fifo_len) * dma_access_slot_cycles;
    }

    pub fn shouldHaltCpu(self: *const Vdp) bool {
        return self.dma_active and !self.dma_fill;
    }

    pub fn controlPortWriteWaitMasterCycles(self: *const Vdp) u32 {
        if (self.dma_active and !self.dma_fill and !self.dma_copy) return 0;
        return self.pending_port_write_delay_master_cycles;
    }

    // -- Control Port --

    pub fn readControl(self: *Vdp) u16 {
        const current = self.adjustedLineState(0);
        const status = self.statusWordForAdjustedState(current);

        // Reading status clears pending command, vint pending, and sprite flags.
        self.pending_command = false;
        self.vint_pending = false;
        self.sprite_overflow = false;
        self.sprite_collision = false;

        return status;
    }

    fn statusReadAdjustmentMasterCycles(opcode: u16) u32 {
        // Approximate the local jgenesis timing hack: MOVE/CMP reads tend to resolve near the
        // current point, CMPI/immediate BTST reads resolve a little later, and other instructions
        // use a conservative future sample.
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

    const AdjustedLineState = struct {
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
        if (line_master_cycle < self.hInterruptMasterCycles()) return scanline;

        const total_lines = self.totalLinesForCurrentFrame();
        if (scanline + 1 >= total_lines) return 0;
        return scanline + 1;
    }

    fn vCounterAt(self: *const Vdp, scanline: u16, line_master_cycle: u16) VCounterState {
        const effective_scanline = self.effectiveScanlineForVCounter(scanline, line_master_cycle);
        const active_scanlines = self.activeVisibleLines();

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
        const scanlines_per_frame = self.totalLinesForCurrentFrame();
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
        const internal_h = self.internalHFor(line_master_cycle);
        if (self.isH40()) {
            return !(internal_h >= 0x000B and internal_h < 0x0166);
        }

        return !(internal_h >= 0x000A and internal_h < 0x0126);
    }

    fn adjustedLineState(self: *const Vdp, adjustment_master_cycles: u32) AdjustedLineState {
        const total_master = @as(u32, self.line_master_cycle) + adjustment_master_cycles;
        const line_advance = total_master / clock.ntsc_master_cycles_per_line;
        const total_lines = self.totalLinesForCurrentFrame();
        const line_master_cycle: u16 = @intCast(total_master % clock.ntsc_master_cycles_per_line);
        const scanline: u16 = @intCast((@as(u32, self.scanline) + line_advance) % total_lines);
        const v_counter = self.vCounterAt(scanline, line_master_cycle);
        return .{
            .scanline = scanline,
            .line_master_cycle = line_master_cycle,
            .hblank = self.statusHBlankFlagAt(line_master_cycle),
            .vblank = v_counter.vblank,
        };
    }

    fn computeLiveHVCounterAt(self: *const Vdp, scanline: u16, line_master_cycle: u16) u16 {
        const v_counter = self.vCounterAt(scanline, line_master_cycle).counter;
        const h_counter = self.computeHCounterFor(line_master_cycle);
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
        const internal_h = self.internalHFor(line_master_cycle);
        return @truncate(internal_h >> 1);
    }

    fn vintFlagForAdjustedState(self: *const Vdp, adjusted: AdjustedLineState) bool {
        if (self.vint_pending) return true;

        const current = self.adjustedLineState(0);
        return !current.vblank and adjusted.vblank;
    }

    fn statusWordForAdjustedState(self: *const Vdp, adjusted: AdjustedLineState) u16 {
        var status: u16 = 0;

        if (self.fifoIsEmpty()) status |= 0x0200;
        if (self.fifoIsFull()) status |= 0x0100;

        if (adjusted.vblank or !self.isDisplayEnabled()) status |= 0x0008;
        if (adjusted.hblank) status |= 0x0004;
        if (self.dma_active) status |= 0x0002;
        if (self.pal_mode) status |= 0x0001;
        if (self.odd_frame) status |= 0x0010;
        if (self.sprite_collision) status |= 0x0020;
        if (self.sprite_overflow) status |= 0x0040;
        if (self.vintFlagForAdjustedState(adjusted)) status |= 0x0080;

        return status;
    }

    pub fn readControlAdjusted(self: *Vdp, opcode: u16) u16 {
        const adjusted = self.adjustedLineState(statusReadAdjustmentMasterCycles(opcode));
        const status = self.statusWordForAdjustedState(adjusted);

        // Reading status clears pending command, vint pending, and sprite flags.
        self.pending_command = false;
        self.vint_pending = false;
        self.sprite_overflow = false;
        self.sprite_collision = false;

        return status;
    }

    // -- HV Counter --

    fn computeLiveHVCounter(self: *const Vdp) u16 {
        return self.computeLiveHVCounterAt(self.scanline, self.line_master_cycle);
    }

    fn computeHCounterShaped(self: *const Vdp) u8 {
        return self.computeHCounterFor(self.line_master_cycle);
    }

    pub fn readHVCounter(self: *const Vdp) u16 {
        const mutable_self: *Vdp = @constCast(self);
        mutable_self.pending_command = false;
        if (self.isHVCounterLatchEnabled() and self.hv_latched_valid) {
            return self.hv_latched;
        }
        return self.computeLiveHVCounter();
    }

    pub fn readHVCounterAdjusted(self: *Vdp, opcode: u16) u16 {
        self.pending_command = false;
        if (self.isHVCounterLatchEnabled() and self.hv_latched_valid) {
            return self.hv_latched;
        }
        const adjusted = self.adjustedLineState(statusReadAdjustmentMasterCycles(opcode));
        return self.computeLiveHVCounterAt(adjusted.scanline, adjusted.line_master_cycle);
    }

    // -- Timing --

    pub fn step(self: *Vdp, cycles: u32) void {
        const total = @as(u32, self.line_master_cycle) + cycles;
        self.line_master_cycle = @intCast(total % clock.ntsc_master_cycles_per_line);
        self.hblank = self.line_master_cycle >= self.hblankStartMasterCycles();
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
            self.hv_latched = self.computeLiveHVCounter();
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

    // -- Control Port Write --

    pub fn writeControl(self: *Vdp, value: u16) void {
        if (self.shouldBufferPortWrite()) {
            self.pushPendingPortWrite(.{ .control = value });
            return;
        }

        // Register writes are single-word control writes. If a command word is already pending,
        // a 0x8*** value is the second half of that command, not a register write.
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
            // First word: update address bits [13:0] and code bits [1:0] immediately.
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
                    self.dma_start_delay_slots = self.memoryToVramDmaStartDelaySlots();
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

    pub fn debugDump(self: *const Vdp) void {
        std.debug.print("VDP Code: {X} Addr: {X:0>4} Reg[1]: {X} Reg[15]: {X}\n", .{ self.code, self.addr, self.regs[1], self.regs[15] });
    }
};

fn vdpTestDmaReadWord(_: ?*anyopaque, _: u32) u16 {
    return 0x1234;
}

test "vdp copy dma progresses internally" {
    var vdp = Vdp.init();
    vdp.regs[15] = 1;
    vdp.code = 0x1;
    vdp.addr = 0x0020;
    vdp.vram[0x0010] = 0x12;
    vdp.vram[0x0011] = 0x34;
    vdp.dma_active = true;
    vdp.dma_fill = false;
    vdp.dma_copy = true;
    vdp.dma_source_addr = 0x0010;
    vdp.dma_length = 2;
    vdp.dma_remaining = 2;

    vdp.progressTransfers(8, null, null);
    try testing.expectEqual(@as(u8, 0x12), vdp.vram[0x0020]);
    try testing.expect(vdp.dma_active);

    vdp.progressTransfers(8, null, null);
    try testing.expectEqual(@as(u8, 0x34), vdp.vram[0x0021]);
    try testing.expect(!vdp.dma_active);
    try testing.expect(!vdp.dma_copy);
}

test "vdp memory-to-vram dma waits startup delay after control command" {
    var vdp = Vdp.init();
    vdp.regs[1] |= 0x10; // DMA enable
    vdp.regs[15] = 2;
    vdp.regs[19] = 1;
    vdp.regs[20] = 0;

    vdp.writeControl(0x4000);
    vdp.writeControl(0x0080);

    try testing.expect(vdp.dma_active);
    try testing.expectEqual(@as(u8, 8), vdp.dma_start_delay_slots);
    try testing.expect(vdp.shouldHaltCpu());

    vdp.progressTransfers(56, null, vdpTestDmaReadWord);
    try testing.expectEqual(@as(u32, 1), vdp.dma_remaining);
    try testing.expectEqual(@as(u8, 0), vdp.fifo_len);
    try testing.expectEqual(@as(u16, 0x0000), vdp.addr);

    vdp.progressTransfers(8, null, vdpTestDmaReadWord);
    try testing.expectEqual(@as(u32, 0), vdp.dma_remaining);
    try testing.expectEqual(@as(u8, 1), vdp.fifo_len);
    try testing.expectEqual(@as(u16, 0x0002), vdp.addr);
    try testing.expect(vdp.dma_active);

    vdp.progressTransfers(24, null, vdpTestDmaReadWord);
    try testing.expectEqual(@as(u8, 0x12), vdp.vram[0]);
    try testing.expectEqual(@as(u8, 0x34), vdp.vram[1]);
    try testing.expect(!vdp.dma_active);
}

test "vdp memory-to-vram dma to vsram uses shorter startup delay" {
    var vdp = Vdp.init();
    vdp.regs[1] |= 0x10; // DMA enable
    vdp.regs[15] = 2;
    vdp.regs[19] = 1;
    vdp.regs[20] = 0;

    vdp.writeControl(0x4000);
    vdp.writeControl(0x0090);

    try testing.expect(vdp.dma_active);
    try testing.expectEqual(@as(u8, 5), vdp.dma_start_delay_slots);

    vdp.progressTransfers(32, null, vdpTestDmaReadWord);
    try testing.expectEqual(@as(u32, 1), vdp.dma_remaining);
    try testing.expectEqual(@as(u8, 0), vdp.fifo_len);

    vdp.progressTransfers(8, null, vdpTestDmaReadWord);
    try testing.expectEqual(@as(u32, 0), vdp.dma_remaining);
    try testing.expectEqual(@as(u8, 1), vdp.fifo_len);
    try testing.expectEqual(@as(u16, 0x0002), vdp.addr);

    vdp.progressTransfers(24, null, vdpTestDmaReadWord);
    try testing.expectEqual(@as(u8, 0x12), vdp.vsram[0]);
    try testing.expectEqual(@as(u8, 0x34), vdp.vsram[1]);
    try testing.expect(!vdp.dma_active);
}

test "vdp buffers control writes until memory-to-vram dma completes" {
    var vdp = Vdp.init();
    vdp.regs[15] = 2;
    vdp.code = 0x1;
    vdp.addr = 0x0000;
    vdp.dma_active = true;
    vdp.dma_fill = false;
    vdp.dma_copy = false;
    vdp.dma_length = 1;
    vdp.dma_remaining = 1;

    vdp.writeControl(0x4000);
    vdp.writeControl(0x0002);

    try testing.expect(!vdp.pending_command);
    try testing.expectEqual(@as(u16, 0x0000), vdp.addr);
    try testing.expectEqual(@as(u8, 0x1), vdp.code);

    vdp.progressTransfers(24, null, vdpTestDmaReadWord);

    try testing.expect(!vdp.dma_active);
    try testing.expect(!vdp.pending_command);
    try testing.expectEqual(@as(u16, 0x0002), vdp.addr);
    try testing.expectEqual(@as(u8, 0x1), vdp.code);

    vdp.progressTransfers(40, null, null);
    try testing.expectEqual(@as(u16, 0x0002), vdp.addr);

    vdp.progressTransfers(10, null, null);
    try testing.expectEqual(@as(u16, 0x8000), vdp.addr);
    try testing.expectEqual(@as(u8, 0x1), vdp.code);
}

test "vdp buffers data writes until memory-to-vram dma completes" {
    var vdp = Vdp.init();
    vdp.regs[15] = 2;
    vdp.code = 0x1;
    vdp.addr = 0x0000;
    vdp.dma_active = true;
    vdp.dma_fill = false;
    vdp.dma_copy = false;
    vdp.dma_length = 1;
    vdp.dma_remaining = 1;

    vdp.writeData(0xBEEF);

    try testing.expectEqual(@as(u16, 0x0000), vdp.addr);
    try testing.expectEqual(@as(u8, 0), vdp.vram[0]);
    try testing.expectEqual(@as(u8, 0), vdp.vram[1]);

    vdp.progressTransfers(24, null, vdpTestDmaReadWord);
    try testing.expectEqual(@as(u8, 0x12), vdp.vram[0]);
    try testing.expectEqual(@as(u8, 0x34), vdp.vram[1]);
    try testing.expectEqual(@as(u16, 0x0002), vdp.addr);

    vdp.progressTransfers(40, null, null);
    try testing.expectEqual(@as(u16, 0x0002), vdp.addr);
    try testing.expectEqual(@as(u8, 0), vdp.vram[2]);
    try testing.expectEqual(@as(u8, 0), vdp.vram[3]);

    vdp.progressTransfers(10, null, null);
    try testing.expectEqual(@as(u16, 0x0004), vdp.addr);
    try testing.expectEqual(@as(u8, 0), vdp.vram[2]);
    try testing.expectEqual(@as(u8, 0), vdp.vram[3]);

    vdp.progressTransfers(24, null, null);
    try testing.expectEqual(@as(u8, 0xBE), vdp.vram[2]);
    try testing.expectEqual(@as(u8, 0xEF), vdp.vram[3]);
}

test "vdp h40 buffered control writes replay after shorter delay" {
    var vdp = Vdp.init();
    vdp.regs[12] = 0x81;
    vdp.regs[15] = 2;
    vdp.code = 0x1;
    vdp.addr = 0x0000;
    vdp.dma_active = true;
    vdp.dma_fill = false;
    vdp.dma_copy = false;
    vdp.dma_length = 1;
    vdp.dma_remaining = 1;

    vdp.writeControl(0x4000);
    vdp.writeControl(0x0002);

    vdp.progressTransfers(24, null, vdpTestDmaReadWord);
    try testing.expectEqual(@as(u16, 0x0002), vdp.addr);

    vdp.progressTransfers(32, null, null);
    try testing.expectEqual(@as(u16, 0x0002), vdp.addr);

    vdp.progressTransfers(8, null, null);
    try testing.expectEqual(@as(u16, 0x8000), vdp.addr);
}

test "vdp buffers new control writes while post-dma replay delay is active" {
    var vdp = Vdp.init();
    vdp.regs[15] = 2;
    vdp.code = 0x1;
    vdp.addr = 0x0000;
    vdp.dma_active = true;
    vdp.dma_fill = false;
    vdp.dma_copy = false;
    vdp.dma_length = 1;
    vdp.dma_remaining = 1;

    vdp.writeControl(0x4000);
    vdp.writeControl(0x0002);

    vdp.progressTransfers(24, null, vdpTestDmaReadWord);
    try testing.expectEqual(@as(u16, 50), vdp.pending_port_write_delay_master_cycles);
    try testing.expectEqual(@as(u16, 0x0002), vdp.addr);

    vdp.writeControl(0x4004);
    vdp.writeControl(0x0000);

    try testing.expectEqual(@as(u8, 4), vdp.pending_port_write_len);
    try testing.expectEqual(@as(u16, 0x0002), vdp.addr);

    vdp.progressTransfers(49, null, null);
    try testing.expectEqual(@as(u16, 0x0002), vdp.addr);

    vdp.progressTransfers(1, null, null);
    try testing.expectEqual(@as(u16, 0x0004), vdp.addr);
    try testing.expectEqual(@as(u8, 0x1), vdp.code);
}

test "vdp buffers new data writes while post-dma replay delay is active" {
    var vdp = Vdp.init();
    vdp.regs[15] = 2;
    vdp.code = 0x1;
    vdp.addr = 0x0000;
    vdp.dma_active = true;
    vdp.dma_fill = false;
    vdp.dma_copy = false;
    vdp.dma_length = 1;
    vdp.dma_remaining = 1;

    vdp.writeData(0xBEEF);

    vdp.progressTransfers(24, null, vdpTestDmaReadWord);
    try testing.expectEqual(@as(u16, 50), vdp.pending_port_write_delay_master_cycles);
    try testing.expectEqual(@as(u16, 0x0002), vdp.addr);

    vdp.writeData(0xCAFE);

    try testing.expectEqual(@as(u8, 2), vdp.pending_port_write_len);
    try testing.expectEqual(@as(u16, 0x0002), vdp.addr);
    try testing.expectEqual(@as(u8, 0), vdp.vram[2]);
    try testing.expectEqual(@as(u8, 0), vdp.vram[3]);
    try testing.expectEqual(@as(u8, 0), vdp.vram[4]);
    try testing.expectEqual(@as(u8, 0), vdp.vram[5]);

    vdp.progressTransfers(50, null, null);
    try testing.expectEqual(@as(u16, 0x0006), vdp.addr);
    try testing.expectEqual(@as(u8, 0), vdp.vram[2]);
    try testing.expectEqual(@as(u8, 0), vdp.vram[3]);
    try testing.expectEqual(@as(u8, 0), vdp.vram[4]);
    try testing.expectEqual(@as(u8, 0), vdp.vram[5]);

    vdp.progressTransfers(24, null, null);
    try testing.expectEqual(@as(u8, 0xBE), vdp.vram[2]);
    try testing.expectEqual(@as(u8, 0xEF), vdp.vram[3]);
    try testing.expectEqual(@as(u8, 0), vdp.vram[4]);
    try testing.expectEqual(@as(u8, 0), vdp.vram[5]);

    vdp.progressTransfers(8, null, null);
    try testing.expectEqual(@as(u8, 0xCA), vdp.vram[4]);
    try testing.expectEqual(@as(u8, 0xFE), vdp.vram[5]);
}

test "vdp queued writes accumulate sub-slot master cycles" {
    var vdp = Vdp.init();
    vdp.regs[15] = 2;
    vdp.code = 0x1;
    vdp.addr = 0x0000;

    vdp.writeData(0xABCD);
    try testing.expectEqual(@as(u16, 0x0002), vdp.addr);
    try testing.expectEqual(@as(u8, 0), vdp.vram[0]);
    try testing.expectEqual(@as(u8, 0), vdp.vram[1]);

    inline for (0..3) |_| {
        vdp.progressTransfers(clock.m68k_divider, null, null);
        try testing.expectEqual(@as(u8, 0), vdp.vram[0]);
        try testing.expectEqual(@as(u8, 0), vdp.vram[1]);
    }

    vdp.progressTransfers(clock.m68k_divider, null, null);
    try testing.expectEqual(@as(u8, 0xAB), vdp.vram[0]);
    try testing.expectEqual(@as(u8, 0xCD), vdp.vram[1]);
}

test "vdp data-port read prefetch sees queued fifo writes" {
    var vdp = Vdp.init();
    vdp.regs[15] = 2;
    vdp.code = 0x1;
    vdp.addr = 0x0000;
    vdp.writeData(0xABCD);

    vdp.code = 0x0;
    vdp.addr = 0x0000;
    vdp.read_buffer = 0x1234;

    try testing.expectEqual(@as(u16, 0x1234), vdp.readData());
    try testing.expectEqual(@as(u16, 0xCDAB), vdp.read_buffer);
}

test "vdp data-port read prefetch sees pending fifo writes after drain" {
    var vdp = Vdp.init();
    vdp.regs[15] = 2;
    vdp.code = 0x1;
    vdp.addr = 0x0000;
    vdp.writeData(0x0102);
    vdp.writeData(0x0304);
    vdp.writeData(0x0506);
    vdp.writeData(0x0708);
    vdp.writeData(0xA1B2);

    try testing.expectEqual(@as(u8, 4), vdp.fifo_len);
    try testing.expectEqual(@as(u8, 1), vdp.pending_fifo_len);

    vdp.code = 0x0;
    vdp.addr = 0x0008;
    vdp.read_buffer = 0x5678;

    try testing.expectEqual(@as(u16, 0x5678), vdp.readData());
    try testing.expectEqual(@as(u16, 0xB2A1), vdp.read_buffer);
}

test "vdp data-port read wait tracks fifo drain time" {
    var vdp = Vdp.init();
    vdp.regs[15] = 2;
    vdp.code = 0x1;
    vdp.addr = 0x0000;

    vdp.writeData(0xABCD);
    try testing.expectEqual(@as(u32, 24), vdp.dataPortReadWaitMasterCycles());

    vdp.progressTransfers(8, null, null);
    try testing.expectEqual(@as(u32, 16), vdp.dataPortReadWaitMasterCycles());

    vdp.progressTransfers(8, null, null);
    try testing.expectEqual(@as(u32, 8), vdp.dataPortReadWaitMasterCycles());

    vdp.progressTransfers(8, null, null);
    try testing.expectEqual(@as(u32, 0), vdp.dataPortReadWaitMasterCycles());
}

test "vdp reserves incremental waits for repeated blocked data-port writes" {
    var vdp = Vdp.init();
    vdp.regs[15] = 2;
    vdp.code = 0x1;
    vdp.addr = 0x0000;

    vdp.writeData(0x0102);
    vdp.writeData(0x0304);
    vdp.writeData(0x0506);
    vdp.writeData(0x0708);

    const wait_first = vdp.reserveDataPortWriteWaitMasterCycles();
    vdp.writeData(0x090A);

    const wait_second = vdp.reserveDataPortWriteWaitMasterCycles();
    vdp.writeData(0x0B0C);

    try testing.expectEqual(@as(u32, 24), wait_first);
    try testing.expectEqual(@as(u32, 8), wait_second);

    vdp.progressTransfers(wait_first + wait_second, null, null);
    try testing.expectEqual(@as(u16, 0x000C), vdp.addr);
    try testing.expectEqual(@as(u16, 0x0100), vdp.readControl() & 0x0300);
}

test "vdp status reports fifo empty and full bits" {
    var vdp = Vdp.init();
    vdp.regs[15] = 2;
    vdp.code = 0x1;
    vdp.addr = 0x0000;

    const fifo_status_mask: u16 = 0x0300;

    try testing.expectEqual(@as(u16, 0x0200), vdp.readControl() & fifo_status_mask);

    vdp.writeData(0x0102);
    try testing.expectEqual(@as(u16, 0x0000), vdp.readControl() & fifo_status_mask);

    vdp.writeData(0x0304);
    vdp.writeData(0x0506);
    vdp.writeData(0x0708);
    try testing.expectEqual(@as(u16, 0x0100), vdp.readControl() & fifo_status_mask);

    vdp.progressTransfers(24, null, null);
    try testing.expectEqual(@as(u16, 0x0000), vdp.readControl() & fifo_status_mask);

    vdp.progressTransfers(24, null, null);
    try testing.expectEqual(@as(u16, 0x0200), vdp.readControl() & fifo_status_mask);
}

test "vdp hv counter advances with line master cycles" {
    var vdp = Vdp.init();
    _ = vdp.setScanlineState(10, clock.ntsc_visible_lines, clock.ntsc_lines_per_frame);

    const hv0 = vdp.readHVCounter();
    try testing.expectEqual(@as(u8, 10), @as(u8, @truncate(hv0 >> 8)));
    try testing.expectEqual(@as(u8, 0x00), @as(u8, @truncate(hv0)));

    vdp.step(100);
    const hv1 = vdp.readHVCounter();
    try testing.expectEqual(@as(u8, 0x05), @as(u8, @truncate(hv1)));

    vdp.step(vdp.hblankStartMasterCycles() - 100);
    try testing.expect(vdp.hblank);

    _ = vdp.setScanlineState(11, clock.ntsc_visible_lines, clock.ntsc_lines_per_frame);
    const hv2 = vdp.readHVCounter();
    try testing.expectEqual(@as(u8, 11), @as(u8, @truncate(hv2 >> 8)));
    try testing.expect(@as(u8, @truncate(hv2)) < @as(u8, @truncate(hv1)));
}

test "vdp reports vblank entry edge once" {
    var vdp = Vdp.init();

    try testing.expect(!vdp.setScanlineState(clock.ntsc_visible_lines - 1, clock.ntsc_visible_lines, clock.ntsc_lines_per_frame));
    try testing.expect(vdp.setScanlineState(clock.ntsc_visible_lines, clock.ntsc_visible_lines, clock.ntsc_lines_per_frame));
    try testing.expect(!vdp.setScanlineState(clock.ntsc_visible_lines + 1, clock.ntsc_visible_lines, clock.ntsc_lines_per_frame));
}

test "vdp hint counter triggers every reg10+1 visible lines" {
    var vdp = Vdp.init();
    vdp.regs[0] = 0x10; // HINT enable
    vdp.regs[10] = 2; // trigger cadence: 3 lines
    vdp.beginFrame();

    var triggered_lines = [_]u16{ 0, 0 };
    var trigger_count: usize = 0;

    for (0..8) |i| {
        const line: u16 = @intCast(i);
        if (vdp.consumeHintForLine(line, clock.ntsc_visible_lines)) {
            if (trigger_count < triggered_lines.len) {
                triggered_lines[trigger_count] = line;
            }
            trigger_count += 1;
        }
    }

    try testing.expectEqual(@as(usize, 2), trigger_count);
    try testing.expectEqual(@as(u16, 2), triggered_lines[0]);
    try testing.expectEqual(@as(u16, 5), triggered_lines[1]);
}

test "vdp pal timing enters vblank at pal visible line count" {
    var vdp = Vdp.init();
    vdp.pal_mode = true;

    try testing.expect(!vdp.setScanlineState(clock.pal_visible_lines - 1, clock.pal_visible_lines, clock.pal_lines_per_frame));
    try testing.expect(vdp.setScanlineState(clock.pal_visible_lines, clock.pal_visible_lines, clock.pal_lines_per_frame));
}

test "vdp interlace odd frame does not shift h counter" {
    var vdp = Vdp.init();
    vdp.regs[12] = 0x06; // Interlace mode 2
    _ = vdp.setScanlineState(0, clock.ntsc_visible_lines, clock.ntsc_lines_per_frame);

    vdp.odd_frame = false;
    const hv_even = vdp.readHVCounter();
    vdp.odd_frame = true;
    const hv_odd = vdp.readHVCounter();

    try testing.expectEqual(@as(u8, @truncate(hv_even)), @as(u8, @truncate(hv_odd)));
}

test "vdp adjusted hv counter samples future line master cycles" {
    var vdp = Vdp.init();
    _ = vdp.setScanlineState(10, clock.ntsc_visible_lines, clock.ntsc_lines_per_frame);

    try testing.expectEqual(vdp.readHVCounter(), vdp.readHVCounterAdjusted(0x3039)); // MOVE

    const hv_cmpi = vdp.readHVCounterAdjusted(0x0C39);
    try testing.expectEqual(@as(u8, 0x01), @as(u8, @truncate(hv_cmpi)));

    const hv_other = vdp.readHVCounterAdjusted(0x4A79);
    try testing.expectEqual(@as(u8, 0x02), @as(u8, @truncate(hv_other)));
}

test "vdp h40 h counter jumps to the hsync range encoding" {
    var vdp = Vdp.init();
    vdp.regs[12] = 0x81; // H40 mode
    _ = vdp.setScanlineState(0, clock.ntsc_visible_lines, clock.ntsc_lines_per_frame);

    vdp.line_master_cycle = 2912;
    try testing.expectEqual(@as(u8, 0xB6), @as(u8, @truncate(vdp.readHVCounter())));

    vdp.line_master_cycle = 2920;
    try testing.expectEqual(@as(u8, 0xE4), @as(u8, @truncate(vdp.readHVCounter())));
}

test "vdp line timing points are mode-aware" {
    var vdp = Vdp.init();
    try testing.expectEqual(@as(u16, 2660), vdp.hInterruptMasterCycles());
    try testing.expectEqual(@as(u16, 2640), vdp.hblankStartMasterCycles());

    vdp.regs[12] = 0x81; // H40 mode
    try testing.expectEqual(@as(u16, 2640), vdp.hInterruptMasterCycles());
    try testing.expectEqual(@as(u16, 2768), vdp.hblankStartMasterCycles());
}

test "vdp adjusted status can see hblank edge earlier for non-move reads" {
    var vdp = Vdp.init();
    _ = vdp.setScanlineState(0, clock.ntsc_visible_lines, clock.ntsc_lines_per_frame);
    vdp.line_master_cycle = 2920;
    vdp.hblank = false;

    try testing.expectEqual(@as(u16, 0), vdp.readControlAdjusted(0x3039) & 0x0004); // MOVE
    try testing.expectEqual(@as(u16, 0x0004), vdp.readControlAdjusted(0x4A79) & 0x0004);
}

test "vdp adjusted status can see vint edge earlier for non-move reads" {
    var move_vdp = Vdp.init();
    _ = move_vdp.setScanlineState(clock.ntsc_visible_lines - 1, clock.ntsc_visible_lines, clock.ntsc_lines_per_frame);
    move_vdp.line_master_cycle = move_vdp.hInterruptMasterCycles() - 1;

    try testing.expectEqual(@as(u16, 0), move_vdp.readControlAdjusted(0x3039) & 0x0080); // MOVE

    var other_vdp = Vdp.init();
    _ = other_vdp.setScanlineState(clock.ntsc_visible_lines - 1, clock.ntsc_visible_lines, clock.ntsc_lines_per_frame);
    other_vdp.line_master_cycle = other_vdp.hInterruptMasterCycles() - 1;

    try testing.expectEqual(@as(u16, 0x0080), other_vdp.readControlAdjusted(0x4A79) & 0x0080);
}

test "vdp status hblank bit follows mode-aware timing" {
    var vdp = Vdp.init();
    _ = vdp.setScanlineState(0, clock.ntsc_visible_lines, clock.ntsc_lines_per_frame);
    vdp.hblank = false;

    vdp.line_master_cycle = 0;
    try testing.expectEqual(@as(u16, 0x0004), vdp.readControl() & 0x0004);

    vdp.line_master_cycle = 100;
    try testing.expectEqual(@as(u16, 0), vdp.readControl() & 0x0004);

    vdp.line_master_cycle = 2940;
    try testing.expectEqual(@as(u16, 0x0004), vdp.readControl() & 0x0004);
}

test "vdp ntsc 224-line v counter aliases after line 234" {
    var vdp = Vdp.init();
    vdp.pal_mode = false;
    vdp.regs[1] &= ~@as(u8, 0x08); // 224-line mode threshold

    _ = vdp.setScanlineState(234, clock.ntsc_visible_lines, clock.ntsc_lines_per_frame);
    const hv_234 = vdp.readHVCounter();
    try testing.expectEqual(@as(u8, 0xEA), @as(u8, @truncate(hv_234 >> 8)));

    _ = vdp.setScanlineState(235, clock.ntsc_visible_lines, clock.ntsc_lines_per_frame);
    const hv_235 = vdp.readHVCounter();
    try testing.expectEqual(@as(u8, 0xE5), @as(u8, @truncate(hv_235 >> 8)));
}

test "vdp hv counter advances to the next line during hblank" {
    var vdp = Vdp.init();
    _ = vdp.setScanlineState(10, clock.ntsc_visible_lines, clock.ntsc_lines_per_frame);

    vdp.line_master_cycle = 2659;
    try testing.expectEqual(@as(u8, 10), @as(u8, @truncate(vdp.readHVCounter() >> 8)));

    vdp.line_master_cycle = 2660;
    try testing.expectEqual(@as(u8, 11), @as(u8, @truncate(vdp.readHVCounter() >> 8)));
}

test "vdp ntsc v counter ignores the 240-line bit" {
    var vdp = Vdp.init();
    vdp.pal_mode = false;
    vdp.regs[1] |= 0x08; // Should not affect NTSC V counter mapping.

    _ = vdp.setScanlineState(235, clock.ntsc_visible_lines, clock.ntsc_lines_per_frame);
    try testing.expectEqual(@as(u8, 0xE5), @as(u8, @truncate(vdp.readHVCounter() >> 8)));
}

test "vdp pal 240-line v counter aliases after line 266" {
    var vdp = Vdp.init();
    vdp.pal_mode = true;
    vdp.regs[1] |= 0x08; // 240-line mode threshold

    _ = vdp.setScanlineState(266, clock.pal_visible_lines, clock.pal_lines_per_frame);
    const hv_266 = vdp.readHVCounter();
    try testing.expectEqual(@as(u8, 0x0A), @as(u8, @truncate(hv_266 >> 8)));

    _ = vdp.setScanlineState(267, clock.pal_visible_lines, clock.pal_lines_per_frame);
    const hv_267 = vdp.readHVCounter();
    try testing.expectEqual(@as(u8, 0xD2), @as(u8, @truncate(hv_267 >> 8)));
}

test "vdp pal 224-line v counter follows the hardware alias window" {
    var vdp = Vdp.init();
    vdp.pal_mode = true;
    vdp.regs[1] &= ~@as(u8, 0x08); // 224-line mode

    const expected = [_]u8{ 0xFF, 0x00, 0x01, 0x02, 0xCA, 0xCB, 0xCC };
    for (expected, 255..) |expected_v, line| {
        _ = vdp.setScanlineState(@intCast(line), clock.ntsc_visible_lines, clock.pal_lines_per_frame);
        try testing.expectEqual(expected_v, @as(u8, @truncate(vdp.readHVCounter() >> 8)));
    }
}

test "vdp pal 240-line v counter follows the hardware alias window" {
    var vdp = Vdp.init();
    vdp.pal_mode = true;
    vdp.regs[1] |= 0x08; // 240-line mode

    const expected = [_]u8{ 0xFF, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0xD2, 0xD3 };
    for (expected, 255..) |expected_v, line| {
        _ = vdp.setScanlineState(@intCast(line), clock.pal_visible_lines, clock.pal_lines_per_frame);
        try testing.expectEqual(expected_v, @as(u8, @truncate(vdp.readHVCounter() >> 8)));
    }
}

test "vdp interlace mode 2 doubles the external v counter" {
    var vdp = Vdp.init();
    vdp.regs[12] = 0x06; // Interlace mode 2
    vdp.odd_frame = false;

    const expected = [_]u8{ 0x00, 0x02, 0x04, 0x06, 0x08 };
    for (expected, 0..) |expected_v, line| {
        _ = vdp.setScanlineState(@intCast(line), clock.ntsc_visible_lines, clock.ntsc_lines_per_frame);
        try testing.expectEqual(expected_v, @as(u8, @truncate(vdp.readHVCounter() >> 8)));
    }
}

test "vdp hv latch holds value while latch bit is enabled" {
    var vdp = Vdp.init();
    vdp.regs[0] |= 0x02; // Enable H/V latch

    _ = vdp.setScanlineState(32, clock.ntsc_visible_lines, clock.ntsc_lines_per_frame);
    vdp.step(400);
    const before_latch = vdp.readHVCounter();

    vdp.setHBlank(true); // Capture live counter on HBlank edge.
    const latched = vdp.readHVCounter();
    try testing.expectEqual(latched, vdp.readHVCounter());

    _ = vdp.setScanlineState(33, clock.ntsc_visible_lines, clock.ntsc_lines_per_frame);
    vdp.step(800);
    try testing.expectEqual(latched, vdp.readHVCounter());

    // Disable latch and verify live counter becomes visible again.
    vdp.writeControl(0x8000); // Reg0 = 0, clears latch mode
    const live_after_disable = vdp.readHVCounter();
    try testing.expect(live_after_disable != latched);
    try testing.expect(before_latch != 0 or latched != 0);
}

test "vdp control decode does not treat 0xA*** command word as register write" {
    var vdp = Vdp.init();

    // 0xA000 has top bits 101 and is part of address/code command space.
    vdp.writeControl(0xA000);
    try testing.expect(vdp.pending_command);
}

test "vdp pending second control word with 0x8*** is not decoded as register write" {
    var vdp = Vdp.init();
    vdp.regs[1] = 0x55;

    vdp.writeControl(0x4000);
    try testing.expect(vdp.pending_command);

    vdp.writeControl(0x8100);
    try testing.expect(!vdp.pending_command);
    try testing.expectEqual(@as(u8, 0x55), vdp.regs[1]);
    try testing.expectEqual(@as(u8, 0x1), vdp.code);
    try testing.expectEqual(@as(u16, 0), vdp.addr);
}

test "vdp hv counter reads clear pending command latch" {
    var vdp = Vdp.init();

    vdp.writeControl(0xA000);
    try testing.expect(vdp.pending_command);
    _ = vdp.readHVCounter();
    try testing.expect(!vdp.pending_command);

    vdp.writeControl(0xA000);
    try testing.expect(vdp.pending_command);
    _ = vdp.readHVCounterAdjusted(0x4A79);
    try testing.expect(!vdp.pending_command);
}

test "vdp renders plane B when plane A is transparent" {
    var vdp = Vdp.init();
    vdp.regs[1] = 0x44; // Display enable + mode 5
    vdp.regs[2] = 0x00; // Plane A base 0x0000
    vdp.regs[4] = 0x01; // Plane B base 0x2000
    vdp.regs[16] = 0x01; // 64-cell width

    // Backdrop color left as black. Put visible blue-ish color at palette 0 color 1.
    vdp.cram[2] = 0x02; // hi
    vdp.cram[3] = 0x00; // lo

    // Plane A tile entry at (0,0): tile 0 (all-zero -> transparent)
    vdp.vram[0x0000] = 0x00;
    vdp.vram[0x0001] = 0x00;

    // Plane B tile entry at (0,0): tile 1, palette 0
    vdp.vram[0x2000] = 0x00;
    vdp.vram[0x2001] = 0x01;

    // Tile 1 first row: all pixels index 1
    const tile1_base: usize = 32;
    vdp.vram[tile1_base + 0] = 0x11;
    vdp.vram[tile1_base + 1] = 0x11;
    vdp.vram[tile1_base + 2] = 0x11;
    vdp.vram[tile1_base + 3] = 0x11;

    vdp.renderScanline(0);
    const pixel = vdp.framebuffer[0];
    try testing.expect(pixel != 0xFF000000);
}

test "vdp low priority sprite renders above low priority plane A" {
    var vdp = Vdp.init();
    vdp.regs[1] = 0x44; // Display enable + mode 5
    vdp.regs[2] = 0x30; // Plane A base 0xC000
    vdp.regs[5] = 0x7C; // Sprite table base 0xF800 in H40
    vdp.regs[12] = 0x81; // H40
    vdp.regs[16] = 0x01; // 64x32 scroll plane

    vdp.cram[2] = 0x02; // palette 0 color 1 -> blue-ish
    vdp.cram[3] = 0x00;
    vdp.cram[4] = 0x00; // palette 0 color 2 -> red-ish
    vdp.cram[5] = 0x0E;

    // Plane A tile 1 at the top-left, low priority.
    vdp.vram[0xC000] = 0x00;
    vdp.vram[0xC001] = 0x01;

    // Tile 1 row 0 = color 1 for all pixels.
    const plane_tile_base: usize = 32;
    for (0..4) |i| vdp.vram[plane_tile_base + i] = 0x11;

    // Sprite tile 2, low priority, covering the same pixels.
    const sprite_tile_base: usize = 64;
    for (0..4) |i| vdp.vram[sprite_tile_base + i] = 0x22;

    const sat_base: usize = 0xF800;
    vdp.vram[sat_base + 0] = 0x00;
    vdp.vram[sat_base + 1] = 0x80; // y = 0
    vdp.vram[sat_base + 2] = 0x00; // 1x1 sprite
    vdp.vram[sat_base + 3] = 0x00; // end of list
    vdp.vram[sat_base + 4] = 0x00;
    vdp.vram[sat_base + 5] = 0x02; // tile 2, low priority
    vdp.vram[sat_base + 6] = 0x00;
    vdp.vram[sat_base + 7] = 0x80; // x = 0

    vdp.renderScanline(0);
    try testing.expectEqual(vdp.getPaletteColor(2), vdp.framebuffer[0]);
}

test "vdp high priority plane A hides low priority sprite" {
    var vdp = Vdp.init();
    vdp.regs[1] = 0x44; // Display enable + mode 5
    vdp.regs[2] = 0x30; // Plane A base 0xC000
    vdp.regs[5] = 0x7C; // Sprite table base 0xF800 in H40
    vdp.regs[12] = 0x81; // H40
    vdp.regs[16] = 0x01; // 64x32 scroll plane

    vdp.cram[2] = 0x02; // palette 0 color 1 -> blue-ish
    vdp.cram[3] = 0x00;
    vdp.cram[4] = 0x00; // palette 0 color 2 -> red-ish
    vdp.cram[5] = 0x0E;

    // Plane A tile 1 at the top-left, high priority.
    vdp.vram[0xC000] = 0x80;
    vdp.vram[0xC001] = 0x01;

    const plane_tile_base: usize = 32;
    for (0..4) |i| vdp.vram[plane_tile_base + i] = 0x11;

    const sprite_tile_base: usize = 64;
    for (0..4) |i| vdp.vram[sprite_tile_base + i] = 0x22;

    const sat_base: usize = 0xF800;
    vdp.vram[sat_base + 0] = 0x00;
    vdp.vram[sat_base + 1] = 0x80; // y = 0
    vdp.vram[sat_base + 2] = 0x00; // 1x1 sprite
    vdp.vram[sat_base + 3] = 0x00; // end of list
    vdp.vram[sat_base + 4] = 0x00;
    vdp.vram[sat_base + 5] = 0x02; // tile 2, low priority
    vdp.vram[sat_base + 6] = 0x00;
    vdp.vram[sat_base + 7] = 0x80; // x = 0

    vdp.renderScanline(0);
    try testing.expectEqual(vdp.getPaletteColor(1), vdp.framebuffer[0]);
}
