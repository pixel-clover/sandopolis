pub const master_clock_ntsc: u32 = 53_693_175;
pub const master_clock_pal: u32 = 53_203_424;

pub const m68k_divider: u8 = 7;
pub const z80_divider: u8 = 15;

pub const ntsc_lines_per_frame: u16 = 262;
pub const ntsc_visible_lines: u16 = 224;
pub const ntsc_master_cycles_per_line: u16 = 3420;
pub const ntsc_master_cycles_per_frame: u32 = @as(u32, ntsc_lines_per_frame) * @as(u32, ntsc_master_cycles_per_line);

// Coarse phase split used by current scheduler.
// 2590 + 830 = 3420 master cycles per line.
pub const ntsc_active_master_cycles: u16 = 2590;
pub const ntsc_hblank_master_cycles: u16 = 830;

// FM: 68k-domain sample divider used by reference cores.
// master/sample = m68k_divider * 6(prescaler) * 6(channels) * 4(operators).
pub const fm_master_cycles_per_sample: u16 = @as(u16, m68k_divider) * 6 * 6 * 4; // 1008

// PSG: one sample every 16 Z80 cycles.
pub const psg_master_cycles_per_sample: u16 = @as(u16, z80_divider) * 16; // 240

pub inline fn m68kCyclesToMaster(cycles: u32) u32 {
    return cycles * m68k_divider;
}

pub const M68kSync = struct {
    master_cycles: u64 = 0,
    remainder: u8 = 0,

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
};
