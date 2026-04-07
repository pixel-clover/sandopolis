/// SMS timing constants.

/// NTSC master clock: 10,738,635 Hz (same as NTSC colorburst * 3).
pub const ntsc_master_clock: u32 = 10_738_635;

/// PAL master clock: 10,640,684 Hz.
pub const pal_master_clock: u32 = 10_640_684;

/// Z80 CPU clock divider from master: master / 3 = ~3.58 MHz.
pub const z80_divider: u8 = 3;

/// VDP clock divider from master: master / 2.
pub const vdp_divider: u8 = 2;

/// Z80 cycles per scanline: 228 (684 master cycles / 3).
pub const z80_cycles_per_line: u16 = 228;

/// Master cycles per scanline: 684.
pub const master_cycles_per_line: u16 = 684;

/// NTSC: 262 lines per frame.
pub const ntsc_lines_per_frame: u16 = 262;

/// PAL: 313 lines per frame.
pub const pal_lines_per_frame: u16 = 313;

/// NTSC visible lines (standard 192-line mode).
pub const ntsc_visible_lines: u16 = 192;

/// PAL visible lines (standard 192-line mode, can also be 224 or 240).
pub const pal_visible_lines: u16 = 192;

/// PSG sample divider: Z80 clock / 16.
pub const psg_divider: u8 = 16;
