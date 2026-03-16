const std = @import("std");
const clock = @import("../clock.zig");
const internal_vdp = @import("../video/vdp.zig");

const State = struct {
    vdp: internal_vdp.Vdp = internal_vdp.Vdp.init(),
};

pub const Vdp = struct {
    handle: *State,

    pub fn init(allocator: std.mem.Allocator) !Vdp {
        const state = try allocator.create(State);
        errdefer allocator.destroy(state);
        state.* = .{};
        return .{ .handle = state };
    }

    pub fn clone(self: *const Vdp, allocator: std.mem.Allocator) !Vdp {
        const state = try allocator.create(State);
        errdefer allocator.destroy(state);
        state.* = .{ .vdp = self.handle.vdp };
        return .{ .handle = state };
    }

    pub fn deinit(self: *Vdp, allocator: std.mem.Allocator) void {
        allocator.destroy(self.handle);
    }

    pub fn reset(self: *Vdp) void {
        self.handle.vdp = internal_vdp.Vdp.init();
    }

    pub fn setPalMode(self: *Vdp, pal_mode: bool) void {
        self.handle.vdp.pal_mode = pal_mode;
    }

    pub fn setH40(self: *Vdp, h40: bool) void {
        self.handle.vdp.regs[12] &= ~@as(u8, 0x81);
        if (h40) {
            self.handle.vdp.regs[12] |= 0x81;
        }
    }

    pub fn setScanlineState(self: *Vdp, line: u16, visible_lines: u16, total_lines: u16) bool {
        return self.handle.vdp.setScanlineState(line, visible_lines, total_lines);
    }

    pub fn setLineMasterCycle(self: *Vdp, line_master_cycle: u16) void {
        self.handle.vdp.line_master_cycle = line_master_cycle;
    }

    pub fn setOddFrame(self: *Vdp, odd_frame: bool) void {
        self.handle.vdp.odd_frame = odd_frame;
    }

    pub fn setDmaActive(self: *Vdp, dma_active: bool) void {
        self.handle.vdp.dma_active = dma_active;
    }

    pub fn setVintPending(self: *Vdp, vint_pending: bool) void {
        self.handle.vdp.vint_pending = vint_pending;
    }

    pub fn setSpriteOverflow(self: *Vdp, sprite_overflow: bool) void {
        self.handle.vdp.sprite_overflow = sprite_overflow;
    }

    pub fn setSpriteCollision(self: *Vdp, sprite_collision: bool) void {
        self.handle.vdp.sprite_collision = sprite_collision;
    }

    pub fn setHBlank(self: *Vdp, active: bool) void {
        self.handle.vdp.setHBlank(active);
    }

    pub fn isHBlank(self: *const Vdp) bool {
        return self.handle.vdp.hblank;
    }

    pub fn isVBlank(self: *const Vdp) bool {
        return self.handle.vdp.vblank;
    }

    pub fn scanline(self: *const Vdp) u16 {
        return self.handle.vdp.scanline;
    }

    pub fn lineMasterCycle(self: *const Vdp) u16 {
        return self.handle.vdp.line_master_cycle;
    }

    pub fn hblankStartMasterCycles(self: *const Vdp) u16 {
        return self.handle.vdp.hblankStartMasterCycles();
    }

    pub fn step(self: *Vdp, cycles: u32) void {
        self.handle.vdp.step(cycles);
    }

    pub fn progressTransfers(self: *Vdp, master_cycles: u32) void {
        self.handle.vdp.progressTransfers(master_cycles, null, null);
    }

    pub fn progressTransfersWithEvents(self: *Vdp, master_cycles: u32) void {
        const vdp = &self.handle.vdp;
        var remaining = master_cycles;

        while (remaining != 0) {
            if (!vdp.hblank and !vdp.vblank and vdp.line_master_cycle == vdp.hblankStartMasterCycles()) {
                vdp.setHBlank(true);
                continue;
            }

            const to_line_end = clock.ntsc_master_cycles_per_line - vdp.line_master_cycle;
            var chunk = @as(u32, to_line_end);
            var hit_hblank = false;
            if (!vdp.hblank and !vdp.vblank) {
                const to_hblank = vdp.hblankStartMasterCycles() - vdp.line_master_cycle;
                if (to_hblank < chunk) {
                    chunk = to_hblank;
                    hit_hblank = true;
                }
            }

            if (chunk > remaining) {
                chunk = remaining;
                hit_hblank = false;
            }

            vdp.step(chunk);
            vdp.progressTransfers(chunk, null, null);
            remaining -= chunk;

            if (remaining == 0) break;
            if (hit_hblank) {
                vdp.setHBlank(true);
                continue;
            }
            if (chunk == to_line_end) {
                const visible_lines = vdp.activeVisibleLines();
                const total_lines = vdp.totalLinesForCurrentFrame();
                const next_line: u16 = if (vdp.scanline + 1 >= total_lines) 0 else vdp.scanline + 1;
                if (next_line == 0) {
                    vdp.odd_frame = !vdp.odd_frame;
                }
                _ = vdp.setScanlineState(next_line, visible_lines, total_lines);
                vdp.setHBlank(false);
            }
        }
    }

    pub fn readHVCounter(self: *Vdp) u16 {
        return self.handle.vdp.readHVCounter();
    }

    pub fn readHVCounterAdjusted(self: *Vdp, opcode: u16) u16 {
        return self.handle.vdp.readHVCounterAdjusted(opcode);
    }

    pub fn readControl(self: *Vdp) u16 {
        return self.handle.vdp.readControl();
    }

    pub fn readControlAdjusted(self: *Vdp, opcode: u16) u16 {
        return self.handle.vdp.readControlAdjusted(opcode);
    }

    pub fn setRegister(self: *Vdp, index: usize, value: u8) void {
        std.debug.assert(index < self.handle.vdp.regs.len);
        self.handle.vdp.regs[index] = value;
    }

    pub fn register(self: *const Vdp, index: usize) u8 {
        std.debug.assert(index < self.handle.vdp.regs.len);
        return self.handle.vdp.regs[index];
    }

    pub fn setCode(self: *Vdp, code: u8) void {
        self.handle.vdp.code = code;
    }

    pub fn setAddr(self: *Vdp, address: u16) void {
        self.handle.vdp.addr = address;
    }

    pub fn addr(self: *const Vdp) u16 {
        return self.handle.vdp.addr;
    }

    pub fn writeData(self: *Vdp, value: u16) void {
        self.handle.vdp.writeData(value);
    }

    pub fn fifoLen(self: *const Vdp) u8 {
        return self.handle.vdp.fifo_len;
    }

    pub fn pendingFifoLen(self: *const Vdp) u8 {
        return self.handle.vdp.pending_fifo_len;
    }

    pub fn dataPortReadWaitMasterCycles(self: *const Vdp) u32 {
        return self.handle.vdp.dataPortReadWaitMasterCycles();
    }

    pub fn dataPortWriteWaitMasterCycles(self: *const Vdp) u32 {
        return self.handle.vdp.dataPortWriteWaitMasterCycles();
    }
};
