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
        "cram_dot_events",
        "cram_dot_event_count",
        "reg_change_events",
        "reg_change_event_count",
    };

    pub const framebuffer_width: usize = 320;
    pub const max_framebuffer_height: usize = 240;
    pub const sprite_cache_entry_count: usize = 80;
    // TiTAN Overdrive writes CRAM hundreds of times per scanline for
    // raster-bar effects.  320 entries covers one write per pixel in H40.
    pub const max_cram_dot_events: usize = 320;

    pub const CramDotEvent = struct {
        pixel_x: u16,
        cram_addr: u8, // CRAM byte address (0x00-0x7E, even)
        old_hi: u8, // previous CRAM value (high byte)
        old_lo: u8, // previous CRAM value (low byte)
        written_word: u16, // 16-bit word written to CRAM
    };

    // TiTAN Overdrive changes registers every HBlank (224+ times per frame).
    // Multiple registers can change per line.  512 covers practical cases.
    pub const max_reg_change_events: usize = 512;

    pub const RegChangeEvent = struct {
        pixel_x: u16,
        reg: u8,
        old_value: u8,
        new_value: u8,
    };

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
    dma_fill_ready: bool,
    dma_fill_word: u16,
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
    cram_dot_events: [max_cram_dot_events]CramDotEvent,
    cram_dot_event_count: u16,
    reg_change_events: [max_reg_change_events]RegChangeEvent,
    reg_change_event_count: u16,

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
        /// When true, the CRAM write was already applied at M68K write
        /// time (immediate) and writeTargetWord should skip the CRAM
        /// update when this entry drains from the FIFO.
        cram_already_applied: bool = false,
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
        replay_pending_port_writes: [8]PendingPortWrite = [_]PendingPortWrite{.{ .data = 0 }} ** 8,
        replay_pending_port_write_len: u8 = 0,
        projected_code: u8 = 0,
        projected_addr: u16 = 0,
        projected_pending_command: bool = false,
        projected_command_word: u32 = 0,
        projected_regs: [32]u8 = [_]u8{0} ** 32,
        projected_dma_active: bool = false,
        projected_dma_fill: bool = false,
        projected_dma_copy: bool = false,
        projected_dma_fill_ready: bool = false,
        projected_dma_remaining: u32 = 0,
        projected_dma_start_delay_slots: u8 = 0,
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
            .dma_fill_ready = false,
            .dma_fill_word = 0,
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
            .cram_dot_events = [_]CramDotEvent{.{ .pixel_x = 0, .cram_addr = 0, .old_hi = 0, .old_lo = 0, .written_word = 0 }} ** max_cram_dot_events,
            .cram_dot_event_count = 0,
            .reg_change_events = [_]RegChangeEvent{.{ .pixel_x = 0, .reg = 0, .old_value = 0, .new_value = 0 }} ** max_reg_change_events,
            .reg_change_event_count = 0,
        };
    }

    pub fn setActiveExecutionCounters(self: *Vdp, counters: ?*CoreFrameCounters) void {
        self.active_execution_counters = counters;
    }

    pub fn isH40(self: *const Vdp) bool {
        return (self.regs[12] & 0x01) != 0;
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

    pub fn preParseSpritesForLine(self: *Vdp, line: u16) void {
        if (!self.isDisplayEnabled()) return;
        const tile_h: u8 = self.tileHeight();
        const max_sprites = self.maxSpritesPerLine();
        const max_total = self.maxSpritesTotal();
        self.ensureSpriteCache();

        var sprites_on_line: u8 = 0;
        var sprite_index: u8 = 0;
        var count: u8 = 0;
        while (count < max_total) : (count += 1) {
            const entry = self.sprite_cache_entries[sprite_index];
            const sprite_v_px = @as(i32, entry.v_size) * @as(i32, tile_h);
            const y_in = @as(i32, @intCast(line)) - @as(i32, entry.y_pos);
            if (y_in >= 0 and y_in < sprite_v_px) {
                sprites_on_line += 1;
                if (sprites_on_line > max_sprites) {
                    self.sprite_overflow = true;
                    return;
                }
            }
            sprite_index = entry.link;
            if (sprite_index == 0 or sprite_index >= max_total) break;
        }
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

    pub fn recordCramDot(self: *Vdp, line_master_cycle: u16, cram_addr: u8, written_word: u16) void {
        // Allow HBlank writes — TiTAN Overdrive updates CRAM during HBlank
        // for palette-per-line effects.  These events get pixel_x >= screen_w
        // so they don't produce visible dots, but the undo/redo logic in
        // renderScanline uses them to restore start-of-line CRAM state.
        // Only reject VBlank writes (inter-frame palette setup).
        if (self.vblank or !self.isDisplayEnabled()) return;
        if (self.cram_dot_event_count >= max_cram_dot_events) return;

        const pixel: u16 = if (self.isH40())
            line_master_cycle / 8
        else
            line_master_cycle / 10;

        self.cram_dot_events[self.cram_dot_event_count] = .{
            .pixel_x = pixel,
            .cram_addr = cram_addr,
            .old_hi = self.cram[cram_addr],
            .old_lo = self.cram[cram_addr + 1],
            .written_word = written_word,
        };
        self.cram_dot_event_count += 1;

        // Apply the CRAM write immediately so subsequent events for
        // the same entry capture the correct "old" value.  The FIFO
        // will write the same value again when it drains (harmless).
        const masked = written_word & 0x0EEE;
        self.cram[cram_addr] = @intCast((masked >> 8) & 0xFF);
        self.cram[cram_addr + 1] = @intCast(masked & 0xFF);
    }

    pub fn recordRegChange(self: *Vdp, reg_index: u8, new_value: u8) void {
        // Allow HBlank register changes — games like TiTAN Overdrive
        // change scroll/plane-base/backdrop registers during HBlank for
        // per-scanline raster effects.  Only reject VBlank changes.
        if (self.vblank) return;
        if (self.reg_change_event_count >= max_reg_change_events) return;

        // Track registers that affect rendering:
        // 0: palette mode, 1: display enable, 7: backdrop color (output pass)
        // 2: plane A base, 4: plane B base, 11: scroll mode, 12: display mode,
        // 13: hscroll table, 16: plane size, 17: window H split, 18: window V split
        switch (reg_index) {
            0, 1, 2, 4, 7, 11, 12, 13, 16, 17, 18 => {},
            else => return,
        }

        const old_value = self.regs[reg_index];
        if (old_value == new_value) return;

        const pixel: u16 = if (self.isH40())
            self.line_master_cycle / 8
        else
            self.line_master_cycle / 10;

        const screen_w = self.screenWidth();
        if (pixel >= screen_w) return;

        self.reg_change_events[self.reg_change_event_count] = .{
            .pixel_x = pixel,
            .reg = reg_index,
            .old_value = old_value,
            .new_value = new_value,
        };
        self.reg_change_event_count += 1;
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
    pub const masterCyclesToNextRefreshSlot = fifo_mod.masterCyclesToNextRefreshSlot;
    pub const refreshSlotDurationMasterCycles = fifo_mod.refreshSlotDurationMasterCycles;
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
    pub const currentInterruptLevel = timing_mod.currentInterruptLevel;
    pub const beginFrame = timing_mod.beginFrame;
    pub const applyPowerOnResetTiming = timing_mod.applyPowerOnResetTiming;
    pub const consumeHintForLine = timing_mod.consumeHintForLine;
    pub const hInterruptMasterCycles = timing_mod.hInterruptMasterCycles;
    pub const hblankStartMasterCycles = timing_mod.hblankStartMasterCycles;
    pub const vIntMasterCycles = timing_mod.vIntMasterCycles;
    pub const adjustedLineState = timing_mod.adjustedLineState;

    pub fn debugDump(self: *const Vdp) void {
        std.debug.print("VDP Code: {X} Addr: {X:0>4} Reg[1]: {X} Reg[15]: {X}\n", .{ self.code, self.addr, self.regs[1], self.regs[15] });
    }
};

test "H40-derived geometry depends only on reg 12 bit 0" {
    var vdp = Vdp.init();
    vdp.regs[5] = 0x7F;

    vdp.regs[12] = 0x80;
    try std.testing.expect(!vdp.isH40());
    try std.testing.expectEqual(@as(u16, 256), vdp.screenWidth());
    try std.testing.expectEqual(@as(u8, 64), vdp.maxSpritesTotal());
    try std.testing.expectEqual(@as(u16, 0xFE00), vdp.spriteAttributeTableBase());

    vdp.regs[12] = 0x01;
    try std.testing.expect(vdp.isH40());
    try std.testing.expectEqual(@as(u16, 320), vdp.screenWidth());
    try std.testing.expectEqual(@as(u8, 80), vdp.maxSpritesTotal());
    try std.testing.expectEqual(@as(u16, 0xFC00), vdp.spriteAttributeTableBase());
}

test "VDP init returns expected defaults" {
    const vdp = Vdp.init();

    // Video state defaults
    try std.testing.expect(!vdp.vblank);
    try std.testing.expect(!vdp.hblank);
    try std.testing.expect(!vdp.odd_frame);
    try std.testing.expect(!vdp.pal_mode);
    try std.testing.expect(!vdp.vint_pending);
    try std.testing.expect(!vdp.sprite_overflow);
    try std.testing.expect(!vdp.sprite_collision);

    // DMA state defaults
    try std.testing.expect(!vdp.dma_active);
    try std.testing.expect(!vdp.dma_fill);
    try std.testing.expect(!vdp.dma_copy);
    try std.testing.expectEqual(@as(u32, 0), vdp.dma_remaining);

    // Command state defaults
    try std.testing.expect(!vdp.pending_command);
    try std.testing.expectEqual(@as(u8, 0), vdp.code);
    try std.testing.expectEqual(@as(u16, 0), vdp.addr);

    // FIFO defaults
    try std.testing.expectEqual(@as(u8, 0), vdp.fifo_len);
    try std.testing.expectEqual(@as(u8, 0), vdp.pending_fifo_len);
}

test "display enable controlled by reg 1 bit 6" {
    var vdp = Vdp.init();

    try std.testing.expect(!vdp.isDisplayEnabled());

    vdp.regs[1] = 0x40;
    try std.testing.expect(vdp.isDisplayEnabled());

    vdp.regs[1] = 0x3F;
    try std.testing.expect(!vdp.isDisplayEnabled());

    vdp.regs[1] = 0xFF;
    try std.testing.expect(vdp.isDisplayEnabled());
}

test "shadow highlight mode controlled by reg 12 bit 3" {
    var vdp = Vdp.init();

    try std.testing.expect(!vdp.isShadowHighlightEnabled());

    vdp.regs[12] = 0x08;
    try std.testing.expect(vdp.isShadowHighlightEnabled());

    vdp.regs[12] = 0xF7;
    try std.testing.expect(!vdp.isShadowHighlightEnabled());
}

test "interlace mode 2 requires reg 12 bits 1 and 2 both set" {
    var vdp = Vdp.init();

    try std.testing.expect(!vdp.isInterlaceMode2());
    try std.testing.expectEqual(@as(u8, 8), vdp.tileHeight());
    try std.testing.expectEqual(@as(u32, 32), vdp.tileSizeBytes());

    // Only bit 1 set - not interlace mode 2
    vdp.regs[12] = 0x02;
    try std.testing.expect(!vdp.isInterlaceMode2());

    // Only bit 2 set - not interlace mode 2
    vdp.regs[12] = 0x04;
    try std.testing.expect(!vdp.isInterlaceMode2());

    // Both bits set - interlace mode 2
    vdp.regs[12] = 0x06;
    try std.testing.expect(vdp.isInterlaceMode2());
    try std.testing.expectEqual(@as(u8, 16), vdp.tileHeight());
    try std.testing.expectEqual(@as(u32, 64), vdp.tileSizeBytes());
}

test "HV counter latch controlled by reg 0 bit 1" {
    var vdp = Vdp.init();

    try std.testing.expect(!vdp.isHVCounterLatchEnabled());

    vdp.regs[0] = 0x02;
    try std.testing.expect(vdp.isHVCounterLatchEnabled());

    vdp.regs[0] = 0xFD;
    try std.testing.expect(!vdp.isHVCounterLatchEnabled());
}

test "mid-scanline shadow highlight toggle via register 12" {
    // Set up VDP in H40 mode with shadow/highlight enabled and display on.
    var vdp = Vdp.init();
    vdp.regs[1] = 0x44; // display enable
    vdp.regs[12] = 0x09; // H40 + shadow/highlight

    // Write a non-zero backdrop color (red) to CRAM entry 0.
    vdp.cram[0] = 0x00;
    vdp.cram[1] = 0x0E; // red in 9-bit Genesis format

    // Inject a mid-scanline register 12 change at pixel 160: disable S/H.
    vdp.reg_change_events[0] = .{
        .pixel_x = 160,
        .reg = 12,
        .old_value = 0x09,
        .new_value = 0x01, // H40 without shadow/highlight
    };
    vdp.reg_change_event_count = 1;
    // Set regs to end-of-line state (after the change was applied by the CPU).
    vdp.regs[12] = 0x01;

    vdp.renderScanline(0);

    // Pixels 0-159 should be rendered with shadow/highlight (shadowed backdrop).
    // Pixels 160-319 should be rendered with normal palette colors.
    const shadow_red = vdp.getPaletteColorShadow(0);
    const normal_red = vdp.getPaletteColor(0);
    try std.testing.expect(shadow_red != normal_red);

    // Check a pixel in the S/H region and one in the normal region.
    try std.testing.expectEqual(shadow_red, vdp.framebuffer[80]);
    try std.testing.expectEqual(normal_red, vdp.framebuffer[200]);
}

test "mid-scanline H40 to H32 switch renders backdrop for inactive pixels" {
    // Start in H40 mode, switch to H32 mid-line.
    var vdp = Vdp.init();
    vdp.regs[1] = 0x44; // display enable
    vdp.regs[12] = 0x01; // H40

    // Write a non-zero backdrop color (blue) to CRAM entry 0.
    vdp.cram[0] = 0x0E;
    vdp.cram[1] = 0x00; // blue in 9-bit Genesis format

    // Inject a mid-scanline register 12 change at pixel 128: switch to H32.
    vdp.reg_change_events[0] = .{
        .pixel_x = 128,
        .reg = 12,
        .old_value = 0x01,
        .new_value = 0x00, // H32
    };
    vdp.reg_change_event_count = 1;
    vdp.regs[12] = 0x00; // end-of-line state

    vdp.renderScanline(0);

    const backdrop_color = vdp.getPaletteColor(0);

    // Pixels before the switch (H40 region) should have backdrop.
    try std.testing.expectEqual(backdrop_color, vdp.framebuffer[64]);
    // Pixels after the switch but within H32 range should still be rendered.
    try std.testing.expectEqual(backdrop_color, vdp.framebuffer[200]);
    // Pixels beyond H32 range (256-319) should be filled with backdrop
    // by the right-edge fill pass.
    try std.testing.expectEqual(backdrop_color, vdp.framebuffer[300]);
}

test "mid-scanline H32 to H40 switch extends rendered area" {
    // Start in H32 mode, switch to H40 mid-line.
    var vdp = Vdp.init();
    vdp.regs[1] = 0x44; // display enable
    vdp.regs[12] = 0x00; // H32

    // Write a green backdrop to CRAM entry 0.
    vdp.cram[0] = 0x02;
    vdp.cram[1] = 0x00; // green in 9-bit Genesis format

    // Inject a mid-scanline register 12 change at pixel 128: switch to H40.
    vdp.reg_change_events[0] = .{
        .pixel_x = 128,
        .reg = 12,
        .old_value = 0x00,
        .new_value = 0x01, // H40
    };
    vdp.reg_change_event_count = 1;
    vdp.regs[12] = 0x01; // end-of-line state

    vdp.renderScanline(0);

    const backdrop_color = vdp.getPaletteColor(0);

    // Pixels in the H32 region should have backdrop.
    try std.testing.expectEqual(backdrop_color, vdp.framebuffer[64]);
    // After the switch, H40 extends to 320 pixels.
    // Pixels 128-319 should be rendered (backdrop since no tile data).
    try std.testing.expectEqual(backdrop_color, vdp.framebuffer[200]);
    try std.testing.expectEqual(backdrop_color, vdp.framebuffer[300]);
}

test "recordRegChange tracks register 12 changes" {
    var vdp = Vdp.init();
    vdp.regs[1] = 0x44; // display enable
    vdp.regs[12] = 0x09; // H40 + shadow/highlight
    vdp.line_master_cycle = 640; // pixel 80 in H40 mode (640/8)

    vdp.recordRegChange(12, 0x01); // disable shadow/highlight

    try std.testing.expectEqual(@as(u16, 1), vdp.reg_change_event_count);
    try std.testing.expectEqual(@as(u16, 80), vdp.reg_change_events[0].pixel_x);
    try std.testing.expectEqual(@as(u8, 12), vdp.reg_change_events[0].reg);
    try std.testing.expectEqual(@as(u8, 0x09), vdp.reg_change_events[0].old_value);
    try std.testing.expectEqual(@as(u8, 0x01), vdp.reg_change_events[0].new_value);
}

test "cram dot artifact ors written color with display output at write pixel" {
    // On real hardware, a CRAM write during active display produces a
    // single-pixel artifact where the written 9-bit color is OR'd with
    // the display output at the write position.
    var vdp = Vdp.init();
    vdp.regs[0] = 0x04; // palette mode enabled
    vdp.regs[1] = 0x44; // display enable
    vdp.regs[12] = 0x01; // H40

    // Set backdrop (palette 0, entry 0) to pure red: 0x000E → R=7, G=0, B=0
    vdp.cram[0] = 0x00;
    vdp.cram[1] = 0x0E;

    // Inject a CRAM write at pixel 100 that writes pure blue (0x0E00).
    // The artifact should OR red backdrop with blue write = red+blue (magenta).
    vdp.cram_dot_events[0] = .{
        .pixel_x = 100,
        .cram_addr = 0, // writing to palette entry 0
        .old_hi = 0x00, // previous CRAM high byte
        .old_lo = 0x0E, // previous CRAM low byte (red)
        .written_word = 0x0E00, // pure blue in Genesis format
    };
    vdp.cram_dot_event_count = 1;
    // End-of-line CRAM should reflect the write.
    vdp.cram[0] = 0x0E;
    vdp.cram[1] = 0x00;

    vdp.renderScanline(0);

    // The backdrop at pixel 50 (before the write) should be red.
    const red = vdp.getPaletteColor(0);
    _ = red;

    // The pixel at 100 should show the OR artifact: red | blue.
    // Red in ARGB: 0xFF_FF0000 (from color_lut[7]=255 for R, 0 for G, B)
    // Blue in ARGB: 0xFF_0000FF (from color_lut[7]=255 for B, 0 for R, G)
    // OR'd: 0xFF_FF00FF (magenta)
    const artifact_pixel = vdp.framebuffer[100];
    // The artifact pixel should have both R and B channels set.
    try std.testing.expect((artifact_pixel & 0x00FF0000) != 0); // R channel
    try std.testing.expect((artifact_pixel & 0x000000FF) != 0); // B channel

    // The pixel at 101 (after the write) should be pure blue (new palette).
    const blue_argb = vdp.framebuffer[101];
    try std.testing.expect((blue_argb & 0x000000FF) != 0); // B channel
    try std.testing.expect((blue_argb & 0x00FF0000) == 0); // no R channel
}
