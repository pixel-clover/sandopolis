const std = @import("std");
const render = @import("render.zig");
const fifo_mod = @import("fifo.zig");
const timing_mod = @import("timing.zig");
const CoreFrameCounters = @import("../performance_profile.zig").CoreFrameCounters;

pub const Vdp = struct {
    pub const save_state_skip_fields = .{
        "active_execution_counters",
        "sprite_cache_entries",
        "sprite_cache_valid",
        "sprite_cache_base",
        "sprite_cache_total",
    };

    pub const framebuffer_width: usize = 320;
    pub const max_framebuffer_height: usize = 240;
    pub const sprite_cache_entry_count: usize = 80;

    pub const SpriteCacheEntry = struct {
        y_pos: i16 = 0,
        x_pos_raw: u16 = 0,
        x_pos: i16 = 0,
        h_size: u8 = 0,
        v_size: u8 = 0,
        link: u8 = 0,
        tile_base: u16 = 0,
        palette: u8 = 0,
        is_high: bool = false,
        x_flip: bool = false,
        y_flip: bool = false,
        new_layer: u8 = 0,
    };

    vram: [64 * 1024]u8,
    cram: [128]u8,
    vsram: [80]u8,
    regs: [32]u8,

    framebuffer: [framebuffer_width * max_framebuffer_height]u32,

    code: u8,
    addr: u16,
    pending_command: bool,
    command_word: u32,
    read_buffer: u16,

    vblank: bool,
    hblank: bool,
    odd_frame: bool,
    pal_mode: bool,
    vint_pending: bool,
    sprite_overflow: bool,
    sprite_collision: bool,

    dma_active: bool,

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
    transfer_line_master_cycle: u16,
    projected_data_port_write_wait: ProjectedDataPortWriteWait,

    scanline: u16,
    line_master_cycle: u16,
    hint_counter: i16,
    hv_latched: u16,
    hv_latched_valid: bool,

    sprite_dot_overflow: bool,

    dbg_vram_writes: u64,
    dbg_cram_writes: u64,
    dbg_vsram_writes: u64,
    dbg_unknown_writes: u64,
    active_execution_counters: ?*CoreFrameCounters,
    sprite_cache_entries: [sprite_cache_entry_count]SpriteCacheEntry,
    sprite_cache_valid: bool,
    sprite_cache_base: u16,
    sprite_cache_total: u8,

    pub const DmaReadFn = *const fn (ctx: ?*anyopaque, addr: u32) u16;

    const active_access_slot_cycles_h40: u32 = 16;
    const active_access_slot_cycles_h32: u32 = 20;
    const blanking_access_slot_cycles_h40: u32 = 8;
    const blanking_access_slot_cycles_h32: u32 = 10;

    pub const VdpWriteFifoEntry = struct {
        code: u8 = 0,
        addr: u16 = 0,
        word: u16 = 0,
        latency: u8 = 0,
        second_service_pending: bool = false,
    };

    pub const ProjectedFifoEntry = struct {
        latency: u8 = 0,
        requires_second_service: bool = false,
        second_service_pending: bool = false,
    };

    pub const PendingPortWrite = union(enum) {
        data: u16,
        control: u16,
    };

    pub const DataPortReadStorage = enum {
        vram,
        cram,
        vsram,
    };

    pub const DataPortReadTarget = struct {
        storage: DataPortReadStorage,
        high_index: u16,
        low_index: u16,
    };

    pub const ProjectedDataPortWriteWait = struct {
        valid: bool = false,
        fifo_entries: [4]ProjectedFifoEntry = [_]ProjectedFifoEntry{.{}} ** 4,
        fifo_len: u8 = 0,
        pending_fifo_entries: [16]ProjectedFifoEntry = [_]ProjectedFifoEntry{.{}} ** 16,
        pending_fifo_len: u8 = 0,
        transfer_scanline: u16 = 0,
        transfer_line_master_cycle: u16 = 0,
        transfer_hblank: bool = false,
        transfer_odd_frame: bool = false,
        pending_port_write_delay_master_cycles: u16 = 0,
    };

    pub fn init() Vdp {
        return Vdp{
            .vram = [_]u8{0} ** (64 * 1024),
            .cram = [_]u8{0} ** 128,
            .vsram = [_]u8{0} ** 80,
            .regs = [_]u8{0} ** 32,
            .framebuffer = [_]u32{0} ** (framebuffer_width * max_framebuffer_height),
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
            .transfer_line_master_cycle = 0,
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
            .active_execution_counters = null,
            .sprite_cache_entries = [_]SpriteCacheEntry{.{}} ** sprite_cache_entry_count,
            .sprite_cache_valid = false,
            .sprite_cache_base = 0,
            .sprite_cache_total = 0,
        };
    }

    pub fn setActiveExecutionCounters(self: *Vdp, counters: ?*CoreFrameCounters) void {
        self.active_execution_counters = counters;
    }

    pub fn isH40(self: *const Vdp) bool {
        return (self.regs[12] & 0x81) != 0;
    }

    pub fn screenWidth(self: *const Vdp) u16 {
        return if (self.isH40()) 320 else 256;
    }

    pub fn screenWidthCells(self: *const Vdp) u16 {
        return if (self.isH40()) 40 else 32;
    }

    pub fn maxSpritesPerLine(self: *const Vdp) u8 {
        return if (self.isH40()) 20 else 16;
    }

    pub fn maxSpritePixelsPerLine(self: *const Vdp) u16 {
        return if (self.isH40()) 320 else 256;
    }

    pub fn maxSpritesTotal(self: *const Vdp) u8 {
        return if (self.isH40()) 80 else 64;
    }

    pub fn spriteAttributeTableBase(self: *const Vdp) u16 {
        return if (self.isH40())
            ((@as(u16, self.regs[5] & 0x7F) << 9) & 0xFC00)
        else
            ((@as(u16, self.regs[5] & 0x7F) << 9) & 0xFE00);
    }

    pub fn invalidateSpriteCache(self: *Vdp) void {
        self.sprite_cache_valid = false;
    }

    pub fn ensureSpriteCache(self: *Vdp) void {
        const sprite_base = self.spriteAttributeTableBase();
        const max_total = self.maxSpritesTotal();
        if (self.sprite_cache_valid and self.sprite_cache_base == sprite_base and self.sprite_cache_total == max_total) {
            return;
        }

        const vram = &self.vram;
        for (0..max_total) |sprite_index_usize| {
            const entry_addr = @as(usize, sprite_base) + (sprite_index_usize * 8);
            const y_word = (@as(u16, vram[entry_addr]) << 8) | vram[entry_addr + 1];
            const size = vram[entry_addr + 2];
            const link = vram[entry_addr + 3] & 0x7F;
            const attr = (@as(u16, vram[entry_addr + 4]) << 8) | vram[entry_addr + 5];
            const x_word = (@as(u16, vram[entry_addr + 6]) << 8) | vram[entry_addr + 7];
            const h_size: u8 = @intCast(((size >> 2) & 0x3) + 1);
            const v_size: u8 = @intCast((size & 0x3) + 1);
            const x_pos_raw = x_word & 0x01FF;

            self.sprite_cache_entries[sprite_index_usize] = .{
                .y_pos = @as(i16, @intCast(y_word & 0x03FF)) - 128,
                .x_pos_raw = x_pos_raw,
                .x_pos = @as(i16, @intCast(x_pos_raw)) - 128,
                .h_size = h_size,
                .v_size = v_size,
                .link = link,
                .tile_base = attr & 0x07FF,
                .palette = @intCast((attr >> 13) & 0x3),
                .is_high = (attr & 0x8000) != 0,
                .x_flip = (attr & 0x0800) != 0,
                .y_flip = (attr & 0x1000) != 0,
                .new_layer = render.layerOrder(3, (attr & 0x8000) != 0),
            };
        }

        self.sprite_cache_base = sprite_base;
        self.sprite_cache_total = max_total;
        self.sprite_cache_valid = true;
    }

    pub fn isDisplayEnabled(self: *const Vdp) bool {
        return (self.regs[1] & 0x40) != 0;
    }

    pub fn isShadowHighlightEnabled(self: *const Vdp) bool {
        return (self.regs[12] & 0x08) != 0;
    }

    pub fn isInterlaceMode2(self: *const Vdp) bool {
        return (self.regs[12] & 0x06) == 0x06;
    }

    pub fn isHVCounterLatchEnabled(self: *const Vdp) bool {
        return (self.regs[0] & 0x02) != 0;
    }

    pub fn tileHeightShift(self: *const Vdp) u4 {
        return if (self.isInterlaceMode2()) 4 else 3;
    }

    pub fn tileHeight(self: *const Vdp) u8 {
        return if (self.isInterlaceMode2()) 16 else 8;
    }

    pub fn tileHeightMask(self: *const Vdp) u8 {
        return if (self.isInterlaceMode2()) 0xF else 0x7;
    }

    pub fn tileSizeBytes(self: *const Vdp) u32 {
        return if (self.isInterlaceMode2()) 64 else 32;
    }

    pub fn accessSlotCycles(self: *const Vdp) u32 {
        const in_blanking = self.vblank or self.hblank;
        if (self.isH40()) {
            return if (in_blanking) blanking_access_slot_cycles_h40 else active_access_slot_cycles_h40;
        } else {
            return if (in_blanking) blanking_access_slot_cycles_h32 else active_access_slot_cycles_h32;
        }
    }

    pub fn vramReadByte(self: *const Vdp, address: u16) u8 {
        return self.vram[address & 0xFFFF];
    }

    pub fn vramWriteByte(self: *Vdp, address: u16, value: u8) void {
        const addr = address & 0xFFFF;
        self.vram[addr] = value;
        self.noteSpriteTableWrite(addr);
    }

    pub fn vramWriteWord(self: *Vdp, address: u16, value: u16) void {
        const addr = address & 0xFFFE;
        self.vram[addr] = @intCast((value >> 8) & 0xFF);
        self.vram[addr + 1] = @intCast(value & 0xFF);
        self.noteSpriteTableWrite(addr);
        self.noteSpriteTableWrite(addr + 1);
    }

    fn noteSpriteTableWrite(self: *Vdp, address: u16) void {
        if (!self.sprite_cache_valid) return;

        const sprite_base = self.spriteAttributeTableBase();
        const sprite_end = @as(u32, sprite_base) + (@as(u32, self.maxSpritesTotal()) * 8);
        const addr_u32 = @as(u32, address);
        if (addr_u32 >= sprite_base and addr_u32 < sprite_end) {
            self.invalidateSpriteCache();
        }
    }

    pub const renderScanline = render.renderScanline;
    pub const getPaletteColor = render.getPaletteColor;
    pub const getPaletteColorShadow = render.getPaletteColorShadow;
    pub const getPaletteColorHighlight = render.getPaletteColorHighlight;

    pub const fifoIsEmpty = fifo_mod.fifoIsEmpty;
    pub const fifoIsFull = fifo_mod.fifoIsFull;
    pub const shouldBufferPortWrite = fifo_mod.shouldBufferPortWrite;
    pub const readData = fifo_mod.readData;
    pub const writeData = fifo_mod.writeData;
    pub const advanceAddr = fifo_mod.advanceAddr;
    pub const writeControl = fifo_mod.writeControl;
    pub const progressTransfers = fifo_mod.progressTransfers;
    pub const resetTransferPhase = fifo_mod.resetTransferPhase;
    pub const nextTransferStepMasterCycles = fifo_mod.nextTransferStepMasterCycles;
    pub const dataPortWriteWaitMasterCycles = fifo_mod.dataPortWriteWaitMasterCycles;
    pub const reserveDataPortWriteWaitMasterCycles = fifo_mod.reserveDataPortWriteWaitMasterCycles;
    pub const dataPortReadWaitMasterCycles = fifo_mod.dataPortReadWaitMasterCycles;
    pub const shouldHaltCpu = fifo_mod.shouldHaltCpu;
    pub const controlPortWriteWaitMasterCycles = fifo_mod.controlPortWriteWaitMasterCycles;

    pub const readControl = timing_mod.readControl;
    pub const readControlAdjusted = timing_mod.readControlAdjusted;
    pub const readHVCounter = timing_mod.readHVCounter;
    pub const readHVCounterAdjusted = timing_mod.readHVCounterAdjusted;
    pub const step = timing_mod.step;
    pub const activeVisibleLines = timing_mod.activeVisibleLines;
    pub const totalLinesForCurrentFrame = timing_mod.totalLinesForCurrentFrame;
    pub const frameMasterCycles = timing_mod.frameMasterCycles;
    pub const setScanlineState = timing_mod.setScanlineState;
    pub const setHBlank = timing_mod.setHBlank;
    pub const isVBlankInterruptEnabled = timing_mod.isVBlankInterruptEnabled;
    pub const beginFrame = timing_mod.beginFrame;
    pub const applyPowerOnResetTiming = timing_mod.applyPowerOnResetTiming;
    pub const consumeHintForLine = timing_mod.consumeHintForLine;
    pub const hInterruptMasterCycles = timing_mod.hInterruptMasterCycles;
    pub const hblankStartMasterCycles = timing_mod.hblankStartMasterCycles;
    pub const adjustedLineState = timing_mod.adjustedLineState;

    pub fn debugDump(self: *const Vdp) void {
        std.debug.print("VDP Code: {X} Addr: {X:0>4} Reg[1]: {X} Reg[15]: {X}\n", .{ self.code, self.addr, self.regs[1], self.regs[15] });
    }
};
