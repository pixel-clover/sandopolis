const std = @import("std");
const render = @import("render.zig");
const fifo_mod = @import("fifo.zig");
const timing_mod = @import("timing.zig");

pub const Vdp = struct {
    pub const framebuffer_width: usize = 320;
    pub const max_framebuffer_height: usize = 240;

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
        };
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
        self.vram[address & 0xFFFF] = value;
    }

    pub fn vramWriteWord(self: *Vdp, address: u16, value: u16) void {
        const addr = address & 0xFFFE;
        self.vram[addr] = @intCast((value >> 8) & 0xFF);
        self.vram[addr + 1] = @intCast(value & 0xFF);
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
    pub const consumeHintForLine = timing_mod.consumeHintForLine;
    pub const hInterruptMasterCycles = timing_mod.hInterruptMasterCycles;
    pub const hblankStartMasterCycles = timing_mod.hblankStartMasterCycles;
    pub const adjustedLineState = timing_mod.adjustedLineState;

    pub fn debugDump(self: *const Vdp) void {
        std.debug.print("VDP Code: {X} Addr: {X:0>4} Reg[1]: {X} Reg[15]: {X}\n", .{ self.code, self.addr, self.regs[1], self.regs[15] });
    }
};
