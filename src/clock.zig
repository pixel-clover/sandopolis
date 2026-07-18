pub const master_clock_ntsc: u32 = 53_693_175;
pub const master_clock_pal: u32 = 53_203_424;

pub const m68k_divider: u8 = 7;
pub const z80_divider: u8 = 15;

pub const ntsc_lines_per_frame: u16 = 262;
pub const ntsc_visible_lines: u16 = 224;
pub const ntsc_master_cycles_per_line: u16 = 3420;
pub const ntsc_master_cycles_per_frame: u32 = @as(u32, ntsc_lines_per_frame) * @as(u32, ntsc_master_cycles_per_line);
pub const pal_lines_per_frame: u16 = 313;
pub const pal_visible_lines: u16 = 240;
pub const pal_master_cycles_per_line: u16 = 3420;
pub const pal_master_cycles_per_frame: u32 = @as(u32, pal_lines_per_frame) * @as(u32, pal_master_cycles_per_line);

pub const ntsc_active_master_cycles: u16 = 2590;
pub const ntsc_hblank_master_cycles: u16 = 830;

pub const fm_master_cycles_per_sample: u16 = @as(u16, m68k_divider) * 6 * 6 * 4;

pub const psg_master_cycles_per_sample: u16 = @as(u16, z80_divider) * 16;

pub const refresh_interval: u32 = 128;

/// When true, the 68K gets periodic bus access windows during Memory-to-VRAM
/// DMA at VDP refresh slots, matching real hardware behavior. When false, the
/// 68K is fully halted for the entire DMA duration (legacy behavior).
pub const enable_dma_refresh_windows: bool = false;


pub inline fn m68kCyclesToMaster(cycles: u32) u32 {
    return cycles * m68k_divider;
}

/// Round a master-cycle wait up to a whole number of 68K clocks.  The 68K
/// resumes from a bus stall on its own clock edge, so a stalled access is
/// released at the next multiple of the divider (Genesis Plus GX models the
/// FIFO-full release as `(((cycles + 6) / 7) * 7)`).
pub inline fn roundMasterWaitToM68kPhase(master_cycles: u32) u32 {
    return (master_cycles + m68k_divider - 1) / m68k_divider * m68k_divider;
}

pub const M68kSync = struct {
    master_cycles: u64 = 0,
    remainder: u8 = 0,
    debt_master_cycles: u32 = 0,

    pub fn consumeDebt(self: *M68kSync, requested_master_cycles: u32) u32 {
        const consumed = @min(requested_master_cycles, self.debt_master_cycles);
        self.debt_master_cycles -= consumed;
        return consumed;
    }

    pub fn addDebt(self: *M68kSync, master_cycles: u32) void {
        self.debt_master_cycles += master_cycles;
    }

    pub fn budgetFromMaster(self: *M68kSync, master_cycles: u32) u32 {
        const total = @as(u32, self.remainder) + master_cycles;
        self.remainder = @intCast(total % m68k_divider);
        return total / m68k_divider;
    }

    pub fn commitM68kCycles(self: *M68kSync, m68k_cycles: u32) u32 {
        const master = m68kCyclesToMaster(m68k_cycles);
        self.master_cycles += master;
        return master;
    }

    pub fn commitMasterCycles(self: *M68kSync, master_cycles: u32) u32 {
        self.master_cycles += master_cycles;
        self.remainder = 0;
        return master_cycles;
    }

    pub fn flushStalledMaster(self: *M68kSync, master_cycles: u32) u32 {
        const total = @as(u32, self.remainder) + master_cycles;
        self.master_cycles += total;
        self.remainder = 0;
        return total;
    }

    pub fn flushUnusedBudget(self: *M68kSync, unused_m68k_cycles: u32) u32 {
        const total = m68kCyclesToMaster(unused_m68k_cycles) + @as(u32, self.remainder);
        self.master_cycles += total;
        self.remainder = 0;
        return total;
    }
};

test "VDP port stall waits round up to the 68K clock phase" {
    // Genesis Plus GX releases a FIFO-stalled 68K at the next multiple of 7
    // master cycles ((((fifo_cycles + 6) / 7) * 7)); charging the raw slot
    // distance instead leaks ~3.5 master cycles per stall event, which adds
    // up to ~3% missing stall time in Titan Overdrive's write-flood scenes.
    const t = @import("std").testing;
    try t.expectEqual(@as(u32, 0), roundMasterWaitToM68kPhase(0));
    try t.expectEqual(@as(u32, 7), roundMasterWaitToM68kPhase(1));
    try t.expectEqual(@as(u32, 7), roundMasterWaitToM68kPhase(7));
    try t.expectEqual(@as(u32, 14), roundMasterWaitToM68kPhase(8));
    try t.expectEqual(@as(u32, 154), roundMasterWaitToM68kPhase(150));
}
