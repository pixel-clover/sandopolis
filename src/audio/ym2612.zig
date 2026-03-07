const std = @import("std");
const clock = @import("../clock.zig");
const Z80 = @import("../cpu/z80.zig").Z80;

pub const YmWriteEvent = Z80.YmWriteEvent;

pub const StereoSample = struct {
    left: f32,
    right: f32,
};

const operator_reg_offsets = [_]u8{ 0x00, 0x08, 0x04, 0x0C };
const internal_clock_master_cycles: u16 = @as(u16, clock.m68k_divider) * 6;
const internal_clocks_per_sample: usize = clock.fm_master_cycles_per_sample / internal_clock_master_cycles;
const ym_output_scale: f32 = 1.0 / 256.0;
const ym_cutoff_hz: f32 = 8500.0;

const fn_note = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 1, 2, 3, 3, 3, 3, 3, 3, 3 };
const eg_stephi = [4][4]u8{
    .{ 0, 0, 0, 0 },
    .{ 1, 0, 0, 0 },
    .{ 1, 0, 1, 0 },
    .{ 1, 1, 1, 0 },
};
const eg_am_shift = [_]u8{ 7, 3, 1, 0 };
const pg_detune = [_]u8{ 16, 17, 19, 20, 22, 24, 27, 29 };
const pg_lfo_sh1 = [8][8]u8{
    .{ 7, 7, 7, 7, 7, 7, 7, 7 },
    .{ 7, 7, 7, 7, 7, 7, 7, 7 },
    .{ 7, 7, 7, 7, 7, 7, 1, 1 },
    .{ 7, 7, 7, 7, 1, 1, 1, 1 },
    .{ 7, 7, 7, 1, 1, 1, 1, 0 },
    .{ 7, 7, 1, 1, 0, 0, 0, 0 },
    .{ 7, 7, 1, 1, 0, 0, 0, 0 },
    .{ 7, 7, 1, 1, 0, 0, 0, 0 },
};
const pg_lfo_sh2 = [8][8]u8{
    .{ 7, 7, 7, 7, 7, 7, 7, 7 },
    .{ 7, 7, 7, 7, 2, 2, 2, 2 },
    .{ 7, 7, 7, 2, 2, 2, 7, 7 },
    .{ 7, 7, 2, 2, 7, 7, 2, 2 },
    .{ 7, 7, 2, 7, 7, 7, 2, 7 },
    .{ 7, 7, 7, 2, 7, 7, 2, 1 },
    .{ 7, 7, 7, 2, 7, 7, 2, 1 },
    .{ 7, 7, 7, 2, 7, 7, 2, 1 },
};
const lfo_cycles = [_]u32{ 108, 77, 71, 67, 62, 44, 8, 5 };
const op_offsets = [_]u16{
    0x000,
    0x001,
    0x002,
    0x100,
    0x101,
    0x102,
    0x004,
    0x005,
    0x006,
    0x104,
    0x105,
    0x106,
};
const channel_offsets = [_]u16{ 0x000, 0x001, 0x002, 0x100, 0x101, 0x102 };
const max_pending_writes: usize = 32768;
const fm_algorithm = [4][6][8]u8{
    .{
        .{ 1, 1, 1, 1, 1, 1, 1, 1 },
        .{ 1, 1, 1, 1, 1, 1, 1, 1 },
        .{ 0, 0, 0, 0, 0, 0, 0, 0 },
        .{ 0, 0, 0, 0, 0, 0, 0, 0 },
        .{ 0, 0, 0, 0, 0, 0, 0, 0 },
        .{ 0, 0, 0, 0, 0, 0, 0, 1 },
    },
    .{
        .{ 0, 1, 0, 0, 0, 1, 0, 0 },
        .{ 0, 0, 0, 0, 0, 0, 0, 0 },
        .{ 1, 1, 1, 0, 0, 0, 0, 0 },
        .{ 0, 0, 0, 0, 0, 0, 0, 0 },
        .{ 0, 0, 0, 0, 0, 0, 0, 0 },
        .{ 0, 0, 0, 0, 0, 1, 1, 1 },
    },
    .{
        .{ 0, 0, 0, 0, 0, 0, 0, 0 },
        .{ 0, 0, 0, 0, 0, 0, 0, 0 },
        .{ 0, 0, 0, 0, 0, 0, 0, 0 },
        .{ 1, 0, 0, 1, 1, 1, 1, 0 },
        .{ 0, 0, 0, 0, 0, 0, 0, 0 },
        .{ 0, 0, 0, 0, 1, 1, 1, 1 },
    },
    .{
        .{ 0, 0, 1, 0, 0, 1, 0, 0 },
        .{ 0, 0, 0, 0, 0, 0, 0, 0 },
        .{ 0, 0, 0, 1, 0, 0, 0, 0 },
        .{ 1, 1, 0, 1, 1, 0, 0, 0 },
        .{ 0, 0, 1, 0, 0, 0, 0, 0 },
        .{ 1, 1, 1, 1, 1, 1, 1, 1 },
    },
};

// Exact logsin/exp ROM values from the YM2612 die.
// The comptime-computed versions are off-by-one on ~50% of entries due to
// floor() vs the chip's internal rounding, which compounds through FM
// operator feedback chains and produces audibly wrong timbres.
const logsin_rom = [256]u16{
    0x859, 0x6c3, 0x607, 0x58b, 0x52e, 0x4e4, 0x4a6, 0x471,
    0x443, 0x41a, 0x3f5, 0x3d3, 0x3b5, 0x398, 0x37e, 0x365,
    0x34e, 0x339, 0x324, 0x311, 0x2ff, 0x2ed, 0x2dc, 0x2cd,
    0x2bd, 0x2af, 0x2a0, 0x293, 0x286, 0x279, 0x26d, 0x261,
    0x256, 0x24b, 0x240, 0x236, 0x22c, 0x222, 0x218, 0x20f,
    0x206, 0x1fd, 0x1f5, 0x1ec, 0x1e4, 0x1dc, 0x1d4, 0x1cd,
    0x1c5, 0x1be, 0x1b7, 0x1b0, 0x1a9, 0x1a2, 0x19b, 0x195,
    0x18f, 0x188, 0x182, 0x17c, 0x177, 0x171, 0x16b, 0x166,
    0x160, 0x15b, 0x155, 0x150, 0x14b, 0x146, 0x141, 0x13c,
    0x137, 0x133, 0x12e, 0x129, 0x125, 0x121, 0x11c, 0x118,
    0x114, 0x10f, 0x10b, 0x107, 0x103, 0x0ff, 0x0fb, 0x0f8,
    0x0f4, 0x0f0, 0x0ec, 0x0e9, 0x0e5, 0x0e2, 0x0de, 0x0db,
    0x0d7, 0x0d4, 0x0d1, 0x0cd, 0x0ca, 0x0c7, 0x0c4, 0x0c1,
    0x0be, 0x0bb, 0x0b8, 0x0b5, 0x0b2, 0x0af, 0x0ac, 0x0a9,
    0x0a7, 0x0a4, 0x0a1, 0x09f, 0x09c, 0x099, 0x097, 0x094,
    0x092, 0x08f, 0x08d, 0x08a, 0x088, 0x086, 0x083, 0x081,
    0x07f, 0x07d, 0x07a, 0x078, 0x076, 0x074, 0x072, 0x070,
    0x06e, 0x06c, 0x06a, 0x068, 0x066, 0x064, 0x062, 0x060,
    0x05e, 0x05c, 0x05b, 0x059, 0x057, 0x055, 0x053, 0x052,
    0x050, 0x04e, 0x04d, 0x04b, 0x04a, 0x048, 0x046, 0x045,
    0x043, 0x042, 0x040, 0x03f, 0x03e, 0x03c, 0x03b, 0x039,
    0x038, 0x037, 0x035, 0x034, 0x033, 0x031, 0x030, 0x02f,
    0x02e, 0x02d, 0x02b, 0x02a, 0x029, 0x028, 0x027, 0x026,
    0x025, 0x024, 0x023, 0x022, 0x021, 0x020, 0x01f, 0x01e,
    0x01d, 0x01c, 0x01b, 0x01a, 0x019, 0x018, 0x017, 0x017,
    0x016, 0x015, 0x014, 0x014, 0x013, 0x012, 0x011, 0x011,
    0x010, 0x00f, 0x00f, 0x00e, 0x00d, 0x00d, 0x00c, 0x00c,
    0x00b, 0x00a, 0x00a, 0x009, 0x009, 0x008, 0x008, 0x007,
    0x007, 0x007, 0x006, 0x006, 0x005, 0x005, 0x005, 0x004,
    0x004, 0x004, 0x003, 0x003, 0x003, 0x002, 0x002, 0x002,
    0x002, 0x001, 0x001, 0x001, 0x001, 0x001, 0x001, 0x001,
    0x000, 0x000, 0x000, 0x000, 0x000, 0x000, 0x000, 0x000,
};
const exp_rom = [256]u16{
    0x000, 0x003, 0x006, 0x008, 0x00b, 0x00e, 0x011, 0x014,
    0x016, 0x019, 0x01c, 0x01f, 0x022, 0x025, 0x028, 0x02a,
    0x02d, 0x030, 0x033, 0x036, 0x039, 0x03c, 0x03f, 0x042,
    0x045, 0x048, 0x04b, 0x04e, 0x051, 0x054, 0x057, 0x05a,
    0x05d, 0x060, 0x063, 0x066, 0x069, 0x06c, 0x06f, 0x072,
    0x075, 0x078, 0x07b, 0x07e, 0x082, 0x085, 0x088, 0x08b,
    0x08e, 0x091, 0x094, 0x098, 0x09b, 0x09e, 0x0a1, 0x0a4,
    0x0a8, 0x0ab, 0x0ae, 0x0b1, 0x0b5, 0x0b8, 0x0bb, 0x0be,
    0x0c2, 0x0c5, 0x0c8, 0x0cc, 0x0cf, 0x0d2, 0x0d6, 0x0d9,
    0x0dc, 0x0e0, 0x0e3, 0x0e7, 0x0ea, 0x0ed, 0x0f1, 0x0f4,
    0x0f8, 0x0fb, 0x0ff, 0x102, 0x106, 0x109, 0x10c, 0x110,
    0x114, 0x117, 0x11b, 0x11e, 0x122, 0x125, 0x129, 0x12c,
    0x130, 0x134, 0x137, 0x13b, 0x13e, 0x142, 0x146, 0x149,
    0x14d, 0x151, 0x154, 0x158, 0x15c, 0x160, 0x163, 0x167,
    0x16b, 0x16f, 0x172, 0x176, 0x17a, 0x17e, 0x181, 0x185,
    0x189, 0x18d, 0x191, 0x195, 0x199, 0x19c, 0x1a0, 0x1a4,
    0x1a8, 0x1ac, 0x1b0, 0x1b4, 0x1b8, 0x1bc, 0x1c0, 0x1c4,
    0x1c8, 0x1cc, 0x1d0, 0x1d4, 0x1d8, 0x1dc, 0x1e0, 0x1e4,
    0x1e8, 0x1ec, 0x1f0, 0x1f5, 0x1f9, 0x1fd, 0x201, 0x205,
    0x209, 0x20e, 0x212, 0x216, 0x21a, 0x21e, 0x223, 0x227,
    0x22b, 0x230, 0x234, 0x238, 0x23c, 0x241, 0x245, 0x249,
    0x24e, 0x252, 0x257, 0x25b, 0x25f, 0x264, 0x268, 0x26d,
    0x271, 0x276, 0x27a, 0x27f, 0x283, 0x288, 0x28c, 0x291,
    0x295, 0x29a, 0x29e, 0x2a3, 0x2a8, 0x2ac, 0x2b1, 0x2b5,
    0x2ba, 0x2bf, 0x2c4, 0x2c8, 0x2cd, 0x2d2, 0x2d6, 0x2db,
    0x2e0, 0x2e5, 0x2e9, 0x2ee, 0x2f3, 0x2f8, 0x2fd, 0x302,
    0x306, 0x30b, 0x310, 0x315, 0x31a, 0x31f, 0x324, 0x329,
    0x32e, 0x333, 0x338, 0x33d, 0x342, 0x347, 0x34c, 0x351,
    0x356, 0x35b, 0x360, 0x365, 0x36a, 0x370, 0x375, 0x37a,
    0x37f, 0x384, 0x38a, 0x38f, 0x394, 0x399, 0x39f, 0x3a4,
    0x3a9, 0x3ae, 0x3b4, 0x3b9, 0x3bf, 0x3c4, 0x3c9, 0x3cf,
    0x3d4, 0x3da, 0x3df, 0x3e4, 0x3ea, 0x3ef, 0x3f5, 0x3fa,
};

const EgState = enum(u8) {
    attack = 0,
    decay = 1,
    sustain = 2,
    release = 3,
};

const PitchState = struct {
    fnum: u16,
    block: u8,
    kcode: u8,
};

const CoreClockResult = struct {
    pins: [2]i16,
    consumed_write: bool,
};

const Opn2Core = struct {
    cycles: u8 = 0,
    channel: u8 = 0,
    mol: i16 = 0,
    mor: i16 = 0,

    lfo_enabled_mask: u8 = 0,
    lfo_freq: u8 = 0,
    lfo_pm: u8 = 0,
    lfo_am: u8 = 0,
    lfo_cnt: u8 = 0,
    lfo_inc: u8 = 0,
    lfo_quotient: u32 = 0,

    pg_fnum: u16 = 0,
    pg_block: u8 = 0,
    pg_kcode: u8 = 0,
    pg_inc: [24]u32 = [_]u32{0} ** 24,
    pg_phase: [24]u32 = [_]u32{0} ** 24,
    pg_reset: [24]bool = [_]bool{false} ** 24,
    pg_read: u32 = 0,

    eg_cycle: u8 = 0,
    eg_cycle_stop: bool = false,
    eg_shift: u8 = 0,
    eg_shift_lock: u8 = 0,
    eg_timer_low_lock: u8 = 0,
    eg_timer: u16 = 0,
    eg_timer_inc: u8 = 0,
    eg_quotient: u16 = 0,
    eg_custom_timer: u8 = 0,
    eg_rate: u8 = 0,
    eg_ksv: u8 = 0,
    eg_inc: u8 = 0,
    eg_ratemax: bool = false,
    eg_sl: [2]u8 = .{ 0, 0 },
    eg_lfo_am: u8 = 0,
    eg_tl: [2]u8 = .{ 0, 0 },
    eg_state: [24]u8 = [_]u8{@intFromEnum(EgState.release)} ** 24,
    eg_level: [24]u16 = [_]u16{0x3ff} ** 24,
    eg_out: [24]u16 = [_]u16{0x3ff} ** 24,
    eg_kon: [24]u8 = [_]u8{0} ** 24,
    eg_kon_csm: [24]u8 = [_]u8{0} ** 24,
    eg_kon_latch: [24]u8 = [_]u8{0} ** 24,
    eg_ssg_enable: [24]u8 = [_]u8{0} ** 24,
    eg_ssg_pgrst_latch: [24]u8 = [_]u8{0} ** 24,
    eg_ssg_repeat_latch: [24]u8 = [_]u8{0} ** 24,
    eg_ssg_hold_up_latch: [24]u8 = [_]u8{0} ** 24,
    eg_ssg_dir: [24]u8 = [_]u8{0} ** 24,
    eg_ssg_inv: [24]u8 = [_]u8{0} ** 24,
    eg_read: [2]u32 = .{ 0, 0 },
    eg_read_inc: u8 = 0,

    fm_op1: [6][2]i16 = [_][2]i16{[_]i16{ 0, 0 }} ** 6,
    fm_op2: [6]i16 = [_]i16{0} ** 6,
    fm_out: [24]i16 = [_]i16{0} ** 24,
    fm_mod: [24]i16 = [_]i16{0} ** 24,

    ch_acc: [6]i16 = [_]i16{0} ** 6,
    ch_out: [6]i16 = [_]i16{0} ** 6,
    ch_lock: i16 = 0,
    ch_lock_l: u8 = 0,
    ch_lock_r: u8 = 0,
    ch_read: i16 = 0,

    timer_a_cnt: u16 = 0,
    timer_a_reg: u16 = 0,
    timer_a_load_lock: u8 = 0,
    timer_a_load: u8 = 0,
    timer_a_enable: u8 = 0,
    timer_a_reset: u8 = 0,
    timer_a_load_latch: u8 = 0,
    timer_a_overflow_flag: u8 = 0,
    timer_a_overflow: u8 = 0,

    timer_b_cnt: u16 = 0,
    timer_b_subcnt: u8 = 0,
    timer_b_reg: u16 = 0,
    timer_b_load_lock: u8 = 0,
    timer_b_load: u8 = 0,
    timer_b_enable: u8 = 0,
    timer_b_reset: u8 = 0,
    timer_b_load_latch: u8 = 0,
    timer_b_overflow_flag: u8 = 0,
    timer_b_overflow: u8 = 0,

    mode_test_21: [8]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
    mode_test_2c: [8]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0 },

    mode_ch3: u8 = 0,
    mode_kon_channel: u8 = 0xFF,
    mode_kon_operator: [4]u8 = .{ 0, 0, 0, 0 },
    dacen: u8 = 0,
    dacdata: u16 = 0,
    mode_kon: [24]u8 = [_]u8{0} ** 24,
    mode_csm: u8 = 0,
    mode_kon_csm: u8 = 0,

    ks: [24]u8 = [_]u8{0} ** 24,
    ar: [24]u8 = [_]u8{0} ** 24,
    sr: [24]u8 = [_]u8{0} ** 24,
    dt: [24]u8 = [_]u8{0} ** 24,
    multi: [24]u8 = [_]u8{1} ** 24,
    sl: [24]u8 = [_]u8{0} ** 24,
    rr: [24]u8 = [_]u8{0} ** 24,
    dr: [24]u8 = [_]u8{0} ** 24,
    am: [24]u8 = [_]u8{0} ** 24,
    tl: [24]u8 = [_]u8{0} ** 24,
    ssg_eg: [24]u8 = [_]u8{0} ** 24,

    fnum: [6]u16 = [_]u16{0} ** 6,
    block: [6]u8 = [_]u8{0} ** 6,
    kcode: [6]u8 = [_]u8{0} ** 6,
    fnum_3ch: [6]u16 = [_]u16{0} ** 6,
    block_3ch: [6]u8 = [_]u8{0} ** 6,
    kcode_3ch: [6]u8 = [_]u8{0} ** 6,
    reg_a4: [6]u8 = [_]u8{0} ** 6,
    reg_ac: [6]u8 = [_]u8{0} ** 6,
    connect: [6]u8 = [_]u8{0} ** 6,
    fb: [6]u8 = [_]u8{0} ** 6,
    pan_l: [6]u8 = [_]u8{1} ** 6,
    pan_r: [6]u8 = [_]u8{1} ** 6,
    ams: [6]u8 = [_]u8{0} ** 6,
    pms: [6]u8 = [_]u8{0} ** 6,
    pin_test_in: u8 = 0,

    fn reset(self: *Opn2Core) void {
        self.* = .{};
    }

    fn doRegWrite(self: *Opn2Core, write: YmWriteEvent) bool {
        const port: u1 = @intCast(write.port & 0x01);
        const address: u16 = (@as(u16, port) << 8) | write.reg;
        const slot = self.cycles % 12;
        const channel = self.channel;

        if (op_offsets[slot] == (address & 0x107)) {
            var slot_index: usize = slot;
            if ((address & 0x08) != 0) slot_index += 12;

            switch (address & 0xF0) {
                0x30 => {
                    self.multi[slot_index] = write.value & 0x0F;
                    if (self.multi[slot_index] == 0) self.multi[slot_index] = 1 else self.multi[slot_index] <<= 1;
                    self.dt[slot_index] = (write.value >> 4) & 0x07;
                },
                0x40 => self.tl[slot_index] = write.value & 0x7F,
                0x50 => {
                    self.ar[slot_index] = write.value & 0x1F;
                    self.ks[slot_index] = (write.value >> 6) & 0x03;
                },
                0x60 => {
                    self.dr[slot_index] = write.value & 0x1F;
                    self.am[slot_index] = (write.value >> 7) & 0x01;
                },
                0x70 => self.sr[slot_index] = write.value & 0x1F,
                0x80 => {
                    self.rr[slot_index] = write.value & 0x0F;
                    self.sl[slot_index] = (write.value >> 4) & 0x0F;
                    self.sl[slot_index] |= (self.sl[slot_index] + 1) & 0x10;
                },
                0x90 => self.ssg_eg[slot_index] = write.value & 0x0F,
                else => {},
            }
            return true;
        }

        if (channel_offsets[channel] == (address & 0x103)) {
            switch (address & 0xFC) {
                0xA0 => {
                    self.fnum[channel] = (@as(u16, self.reg_a4[channel] & 0x07) << 8) | write.value;
                    self.block[channel] = (self.reg_a4[channel] >> 3) & 0x07;
                    self.kcode[channel] = (self.block[channel] << 2) | fn_note[self.fnum[channel] >> 7];
                },
                0xA4 => self.reg_a4[channel] = write.value,
                0xA8 => {
                    self.fnum_3ch[channel] = (@as(u16, self.reg_ac[channel] & 0x07) << 8) | write.value;
                    self.block_3ch[channel] = (self.reg_ac[channel] >> 3) & 0x07;
                    self.kcode_3ch[channel] = (self.block_3ch[channel] << 2) | fn_note[self.fnum_3ch[channel] >> 7];
                },
                0xAC => self.reg_ac[channel] = write.value,
                0xB0 => {
                    self.connect[channel] = write.value & 0x07;
                    self.fb[channel] = (write.value >> 3) & 0x07;
                },
                0xB4 => {
                    self.pms[channel] = write.value & 0x07;
                    self.ams[channel] = (write.value >> 4) & 0x03;
                    self.pan_l[channel] = (write.value >> 7) & 0x01;
                    self.pan_r[channel] = (write.value >> 6) & 0x01;
                },
                else => {},
            }
            return true;
        }

        if (write.reg < 0x30) {
            if (port == 0) {
                switch (write.reg) {
                    0x21 => {
                        inline for (0..8) |i| {
                            self.mode_test_21[i] = (write.value >> @intCast(i)) & 0x01;
                        }
                    },
                    0x22 => {
                        self.lfo_enabled_mask = if (((write.value >> 3) & 0x01) != 0) 0x7F else 0;
                        self.lfo_freq = write.value & 0x07;
                    },
                    0x24 => {
                        self.timer_a_reg &= 0x03;
                        self.timer_a_reg |= @as(u16, write.value) << 2;
                    },
                    0x25 => {
                        self.timer_a_reg &= 0x3FC;
                        self.timer_a_reg |= write.value & 0x03;
                    },
                    0x26 => self.timer_b_reg = write.value,
                    0x27 => {
                        self.mode_ch3 = (write.value & 0xC0) >> 6;
                        self.mode_csm = @intFromBool(self.mode_ch3 == 0x02);
                        self.timer_a_load = write.value & 0x01;
                        self.timer_a_enable = (write.value >> 2) & 0x01;
                        self.timer_a_reset = (write.value >> 4) & 0x01;
                        self.timer_b_load = (write.value >> 1) & 0x01;
                        self.timer_b_enable = (write.value >> 3) & 0x01;
                        self.timer_b_reset = (write.value >> 5) & 0x01;
                    },
                    0x28 => {
                        inline for (0..4) |i| {
                            self.mode_kon_operator[i] = (write.value >> @intCast(4 + i)) & 0x01;
                        }
                        if ((write.value & 0x03) == 0x03) {
                            self.mode_kon_channel = 0xFF;
                        } else {
                            self.mode_kon_channel = (write.value & 0x03) + (((write.value >> 2) & 0x01) * 3);
                        }
                    },
                    0x2A => {
                        self.dacdata &= 0x01;
                        self.dacdata |= @as(u16, write.value ^ 0x80) << 1;
                    },
                    0x2B => self.dacen = write.value >> 7,
                    0x2C => {
                        inline for (0..8) |i| {
                            self.mode_test_2c[i] = (write.value >> @intCast(i)) & 0x01;
                        }
                        self.dacdata &= 0x1FE;
                        self.dacdata |= self.mode_test_2c[3];
                        self.eg_custom_timer = @intFromBool(self.mode_test_2c[7] == 0 and self.mode_test_2c[6] != 0);
                    },
                    else => {},
                }
            }
            return true;
        }

        if ((write.reg >= 0x30 and write.reg <= 0x9F) or (write.reg >= 0xA0 and write.reg <= 0xB6)) {
            return (write.reg & 0x03) == 0x03;
        }

        return true;
    }

    fn doTimerA(self: *Opn2Core) void {
        var load = self.timer_a_overflow;
        if (self.cycles == 2) {
            load |= @intFromBool(self.timer_a_load_lock == 0 and self.timer_a_load != 0);
            self.timer_a_load_lock = self.timer_a_load;
            self.mode_kon_csm = if (self.mode_csm != 0) load else 0;
        }

        var time: u16 = if (self.timer_a_load_latch != 0) self.timer_a_reg else self.timer_a_cnt;
        self.timer_a_load_latch = load;

        if ((self.cycles == 1 and self.timer_a_load_lock != 0) or self.mode_test_21[2] != 0) {
            time +%= 1;
        }

        if (self.timer_a_reset != 0) {
            self.timer_a_reset = 0;
            self.timer_a_overflow_flag = 0;
        } else {
            self.timer_a_overflow_flag |= self.timer_a_overflow & self.timer_a_enable;
        }

        self.timer_a_overflow = @intCast(time >> 10);
        self.timer_a_cnt = time & 0x03FF;
    }

    fn doTimerB(self: *Opn2Core) void {
        var load = self.timer_b_overflow;
        if (self.cycles == 2) {
            load |= @intFromBool(self.timer_b_load_lock == 0 and self.timer_b_load != 0);
            self.timer_b_load_lock = self.timer_b_load;
        }

        var time: u16 = if (self.timer_b_load_latch != 0) self.timer_b_reg else self.timer_b_cnt;
        self.timer_b_load_latch = load;

        if (self.cycles == 1) self.timer_b_subcnt +%= 1;
        if ((self.timer_b_subcnt == 0x10 and self.timer_b_load_lock != 0) or self.mode_test_21[2] != 0) {
            time +%= 1;
        }
        self.timer_b_subcnt &= 0x0F;

        if (self.timer_b_reset != 0) {
            self.timer_b_reset = 0;
            self.timer_b_overflow_flag = 0;
        } else {
            self.timer_b_overflow_flag |= self.timer_b_overflow & self.timer_b_enable;
        }

        self.timer_b_overflow = @intCast(time >> 8);
        self.timer_b_cnt = time & 0x00FF;
    }

    fn clockOne(self: *Opn2Core, write: ?YmWriteEvent) CoreClockResult {
        const slot = self.cycles;

        self.lfo_inc = self.mode_test_21[1];
        self.pg_read >>= 1;
        self.eg_read[1] >>= 1;
        self.eg_cycle +%= 1;
        if (slot == 1 and self.eg_quotient == 2) {
            self.eg_shift_lock = if (self.eg_cycle_stop) 0 else self.eg_shift + 1;
            self.eg_timer_low_lock = @intCast(self.eg_timer & 0x03);
        }

        switch (slot) {
            0 => {
                self.lfo_pm = self.lfo_cnt >> 2;
                self.lfo_am = if ((self.lfo_cnt & 0x40) != 0)
                    (self.lfo_cnt & 0x3F) << 1
                else
                    (self.lfo_cnt ^ 0x3F) << 1;
            },
            1 => {
                self.eg_quotient = (self.eg_quotient + 1) % 3;
                self.eg_cycle = 0;
                self.eg_cycle_stop = true;
                self.eg_shift = 0;
                self.eg_timer_inc |= @intCast(self.eg_quotient >> 1);
                const total = @as(u32, self.eg_timer) + self.eg_timer_inc;
                self.eg_timer = @intCast(total & 0x0FFF);
                self.eg_timer_inc = @intCast(total >> 12);
            },
            2 => {
                self.pg_read = self.pg_phase[21] & 0x03FF;
                self.eg_read[1] = self.eg_out[0];
            },
            13 => {
                self.eg_cycle = 0;
                self.eg_cycle_stop = true;
                self.eg_shift = 0;
                const total = @as(u32, self.eg_timer) + self.eg_timer_inc;
                self.eg_timer = @intCast(total & 0x0FFF);
                self.eg_timer_inc = @intCast(total >> 12);
            },
            23 => self.lfo_inc |= 1,
            else => {},
        }

        self.eg_timer &= ~(@as(u16, self.mode_test_21[5]) << @intCast(self.eg_cycle));
        if (self.eg_cycle_stop and
            ((((self.eg_timer >> @intCast(self.eg_cycle)) | (self.pin_test_in & self.eg_custom_timer)) & 0x01) != 0))
        {
            self.eg_shift = self.eg_cycle;
            self.eg_cycle_stop = false;
        }

        self.doTimerA();
        self.doTimerB();
        self.keyOnClock();
        self.channelOutput();
        self.channelGenerate();
        self.fmPrepare();
        self.fmGenerate();
        self.phaseGenerate();
        self.phaseCalcIncrement();
        self.envelopeAdsr();
        self.envelopeGenerate();
        self.envelopeSsgEg();
        self.envelopePrepare();

        const next_pitch = self.selectPhasePitch();
        self.pg_fnum = next_pitch.fnum;
        self.pg_block = next_pitch.block;
        self.pg_kcode = next_pitch.kcode;

        self.updateLfo();
        const consumed_write = if (write) |event| self.doRegWrite(event) else false;

        self.cycles = (slot + 1) % 24;
        self.channel = self.cycles % 6;

        return .{
            .pins = .{ self.mol, self.mor },
            .consumed_write = consumed_write,
        };
    }

    fn keyOnClock(self: *Opn2Core) void {
        const slot = self.cycles;
        const channel = self.channel;
        self.eg_kon_latch[slot] = self.mode_kon[slot];
        self.eg_kon_csm[slot] = 0;
        if (channel == 2 and self.mode_kon_csm != 0) {
            self.eg_kon_latch[slot] = 1;
            self.eg_kon_csm[slot] = 1;
        }
        if (self.cycles == self.mode_kon_channel) {
            self.mode_kon[channel] = self.mode_kon_operator[0];
            self.mode_kon[channel + 12] = self.mode_kon_operator[1];
            self.mode_kon[channel + 6] = self.mode_kon_operator[2];
            self.mode_kon[channel + 18] = self.mode_kon_operator[3];
        }
    }

    fn channelOutput(self: *Opn2Core) void {
        const slot = self.cycles;
        const test_dac = self.mode_test_2c[5] != 0;
        var mux_channel = self.channel;
        if (slot < 12) mux_channel +%= 1;

        self.ch_read = self.ch_lock;
        if ((slot & 0x03) == 0) {
            const lock_channel = mux_channel % 6;
            if (!test_dac) self.ch_lock = self.ch_out[lock_channel];
            self.ch_lock_l = self.pan_l[lock_channel];
            self.ch_lock_r = self.pan_r[lock_channel];
        }

        var out = self.ch_lock;
        const use_dac = (((slot >> 2) == 1) and self.dacen != 0) or test_dac;
        if (use_dac) {
            out = signExtend(8, self.dacdata);
        }

        self.mol = 0;
        self.mor = 0;

        const out_enabled = test_dac or ((slot & 0x03) == 0x03);
        var sign = out >> 8;
        if (out >= 0) {
            out += 1;
            sign += 1;
        }

        self.mol = if (self.ch_lock_l != 0 and out_enabled) out else sign;
        self.mor = if (self.ch_lock_r != 0 and out_enabled) out else sign;
        self.mol *= 3;
        self.mor *= 3;
    }

    fn channelGenerate(self: *Opn2Core) void {
        const slot = (self.cycles + 18) % 24;
        const channel = self.channel;
        const op = slot / 6;
        const test_dac = self.mode_test_2c[5];

        var acc = self.ch_acc[channel];
        if (op == 0 and test_dac == 0) acc = 0;

        var add: i16 = @intCast(test_dac);
        if (fm_algorithm[op][5][self.connect[channel]] != 0 and test_dac == 0) {
            add += self.fm_out[slot] >> 5;
        }

        const sum = clampI16(@as(i32, acc) + add, -256, 255);
        if (op == 0 or test_dac != 0) {
            self.ch_out[channel] = self.ch_acc[channel];
        }
        self.ch_acc[channel] = sum;
    }

    fn fmPrepare(self: *Opn2Core) void {
        const slot = (self.cycles + 6) % 24;
        const channel = self.channel;
        const op = slot / 6;
        const connect = self.connect[channel];
        const prevslot = (self.cycles + 18) % 24;

        var mod1: i16 = 0;
        var mod2: i16 = 0;

        if (fm_algorithm[op][0][connect] != 0) mod2 |= self.fm_op1[channel][0];
        if (fm_algorithm[op][1][connect] != 0) mod1 |= self.fm_op1[channel][1];
        if (fm_algorithm[op][2][connect] != 0) mod1 |= self.fm_op2[channel];
        if (fm_algorithm[op][3][connect] != 0) mod2 |= self.fm_out[prevslot];
        if (fm_algorithm[op][4][connect] != 0) mod1 |= self.fm_out[prevslot];

        var mod = mod1 + mod2;
        if (op == 0) {
            if (self.fb[channel] == 0) {
                mod = 0;
            } else {
                mod = @intCast(@as(i32, mod) >> @intCast(10 - self.fb[channel]));
            }
        } else {
            mod >>= 1;
        }
        self.fm_mod[slot] = mod;

        const feedback_slot = (self.cycles + 18) % 24;
        switch (feedback_slot / 6) {
            0 => {
                self.fm_op1[channel][1] = self.fm_op1[channel][0];
                self.fm_op1[channel][0] = self.fm_out[feedback_slot];
            },
            2 => self.fm_op2[channel] = self.fm_out[feedback_slot],
            else => {},
        }
    }

    fn fmGenerate(self: *Opn2Core) void {
        const slot = (self.cycles + 19) % 24;
        const phase_total = (@as(i32, self.fm_mod[slot]) + @as(i32, @intCast(self.pg_phase[slot] >> 10))) & 0x03FF;
        const phase: u16 = @intCast(phase_total);
        const quarter: u16 = if ((phase & 0x100) != 0)
            (phase ^ 0x0FF) & 0x0FF
        else
            phase & 0x0FF;

        var level = @as(u16, logsin_rom[quarter]) + (self.eg_out[slot] << 2);
        if (level > 0x1FFF) level = 0x1FFF;

        const output_shift: u5 = @intCast(level >> 8);
        var output: u16 = @intCast((@as(u32, exp_rom[(level & 0x0FF) ^ 0x0FF] | 0x400) << 2) >> output_shift);
        output ^= @as(u16, self.mode_test_21[4]) << 13;
        if ((phase & 0x200) != 0) {
            output = (~output) +% 1;
        }
        self.fm_out[slot] = signExtend(13, output);
    }

    fn phaseGenerate(self: *Opn2Core) void {
        const masked_slot = (self.cycles + 20) % 24;
        if (self.pg_reset[masked_slot]) self.pg_inc[masked_slot] = 0;

        const phase_slot = (self.cycles + 19) % 24;
        if (self.pg_reset[phase_slot] or self.mode_test_21[3] != 0) self.pg_phase[phase_slot] = 0;
        self.pg_phase[phase_slot] = (self.pg_phase[phase_slot] + self.pg_inc[phase_slot]) & 0xFFFFF;
    }

    fn phaseCalcIncrement(self: *Opn2Core) void {
        const slot = self.cycles;
        const channel = self.channel;
        const fnum = self.pg_fnum;
        const pms = self.pms[channel];
        const dt_value = self.dt[slot];
        var kcode = self.pg_kcode;

        var fnum_work = @as(u32, fnum) << 1;
        const fnum_high = fnum_work >> 4;

        const lfo = self.lfo_pm;
        var lfo_low = lfo & 0x0F;
        if ((lfo_low & 0x08) != 0) lfo_low ^= 0x0F;

        var fm = (fnum_high >> @intCast(pg_lfo_sh1[pms][lfo_low])) +
            (fnum_high >> @intCast(pg_lfo_sh2[pms][lfo_low]));
        if (pms > 5) fm <<= @intCast(pms - 5);
        fm >>= 2;

        if ((lfo & 0x10) != 0) {
            fnum_work -%= fm;
        } else {
            fnum_work +%= fm;
        }
        fnum_work &= 0x0FFF;

        var basefreq = (fnum_work << @intCast(self.pg_block)) >> 2;
        if ((dt_value & 0x03) != 0) {
            if (kcode > 0x1C) kcode = 0x1C;
            const block = kcode >> 2;
            const note = kcode & 0x03;
            const sum = block + 9 + @as(u8, @intFromBool((dt_value & 0x03) == 0x03 or (dt_value & 0x02) != 0));
            const sum_h = sum >> 1;
            const sum_l = sum & 0x01;
            const detune = @as(u32, pg_detune[(sum_l << 2) | note]) >> @intCast(9 - sum_h);

            if ((dt_value & 0x04) != 0) {
                basefreq -%= detune;
            } else {
                basefreq +%= detune;
            }
        }

        basefreq &= 0x1FFFF;
        self.pg_inc[slot] = ((basefreq * self.multi[slot]) >> 1) & 0xFFFFF;
    }

    fn envelopeSsgEg(self: *Opn2Core) void {
        const slot = self.cycles;
        self.eg_ssg_pgrst_latch[slot] = 0;
        self.eg_ssg_repeat_latch[slot] = 0;
        self.eg_ssg_hold_up_latch[slot] = 0;

        var direction = self.eg_ssg_dir[slot];
        if ((self.ssg_eg[slot] & 0x08) != 0) {
            if ((self.eg_level[slot] & 0x200) != 0) {
                if ((self.ssg_eg[slot] & 0x03) == 0x00) self.eg_ssg_pgrst_latch[slot] = 1;
                if ((self.ssg_eg[slot] & 0x01) == 0x00) self.eg_ssg_repeat_latch[slot] = 1;
                if ((self.ssg_eg[slot] & 0x03) == 0x02) direction ^= 1;
                if ((self.ssg_eg[slot] & 0x03) == 0x03) direction = 1;
            }

            if (self.eg_kon_latch[slot] != 0 and
                (((self.ssg_eg[slot] & 0x07) == 0x05) or ((self.ssg_eg[slot] & 0x07) == 0x03)))
            {
                self.eg_ssg_hold_up_latch[slot] = 1;
            }

            direction &= self.eg_kon[slot];
        } else {
            direction = 0;
        }

        self.eg_ssg_dir[slot] = direction;
        self.eg_ssg_enable[slot] = (self.ssg_eg[slot] >> 3) & 0x01;
        self.eg_ssg_inv[slot] = (self.eg_ssg_dir[slot] ^
            (((self.ssg_eg[slot] >> 2) & 0x01) & ((self.ssg_eg[slot] >> 3) & 0x01))) & self.eg_kon[slot];
    }

    fn envelopeAdsr(self: *Opn2Core) void {
        const slot = (self.cycles + 22) % 24;
        const nkon = self.eg_kon_latch[slot];
        const okon = self.eg_kon[slot];
        const kon_event = (nkon != 0 and okon == 0) or (okon != 0 and self.eg_ssg_repeat_latch[slot] != 0);
        const koff_event = okon != 0 and nkon == 0;

        self.pg_reset[slot] = (nkon != 0 and okon == 0) or self.eg_ssg_pgrst_latch[slot] != 0;
        self.eg_read[0] = self.eg_read_inc;
        self.eg_read_inc = @intFromBool(self.eg_inc > 0);

        const current_state: EgState = @enumFromInt(self.eg_state[slot]);
        var next_state = current_state;
        var level: i16 = @intCast(self.eg_level[slot]);
        var ssg_level = level;

        if (self.eg_ssg_inv[slot] != 0) {
            ssg_level = @intCast((512 - level) & 0x03FF);
        }
        if (koff_event) level = ssg_level;

        const eg_off = if (self.eg_ssg_enable[slot] != 0)
            ((level >> 9) != 0)
        else
            ((level & 0x03F0) == 0x03F0);

        var next_level: i16 = level;
        var inc: i16 = 0;

        if (kon_event) {
            next_state = .attack;
            if (self.eg_ratemax) {
                next_level = 0;
            } else if (current_state == .attack and level != 0 and self.eg_inc != 0 and nkon != 0) {
                inc = (@as(i16, ~level) << @intCast(self.eg_inc)) >> 5;
            }
        } else {
            switch (current_state) {
                .attack => {
                    if (level == 0) {
                        next_state = .decay;
                    } else if (self.eg_inc != 0 and !self.eg_ratemax and nkon != 0) {
                        inc = (@as(i16, ~level) << @intCast(self.eg_inc)) >> 5;
                    }
                },
                .decay => {
                    if ((level >> 4) == (@as(i16, self.eg_sl[1]) << 1)) {
                        next_state = .sustain;
                    } else if (!eg_off and self.eg_inc != 0) {
                        inc = @as(i16, 1) << @intCast(self.eg_inc - 1);
                        if (self.eg_ssg_enable[slot] != 0) inc <<= 2;
                    }
                },
                .sustain, .release => {
                    if (!eg_off and self.eg_inc != 0) {
                        inc = @as(i16, 1) << @intCast(self.eg_inc - 1);
                        if (self.eg_ssg_enable[slot] != 0) inc <<= 2;
                    }
                },
            }

            if (nkon == 0) next_state = .release;
        }

        if (self.eg_kon_csm[slot] != 0) {
            next_level |= @as(i16, self.eg_tl[1]) << 3;
        }

        if (!kon_event and self.eg_ssg_hold_up_latch[slot] == 0 and current_state != .attack and eg_off) {
            next_state = .release;
            next_level = 0x03FF;
        }

        next_level +%= inc;

        self.eg_kon[slot] = self.eg_kon_latch[slot];
        self.eg_level[slot] = @intCast(@as(u16, @bitCast(next_level)) & 0x03FF);
        self.eg_state[slot] = @intFromEnum(next_state);
    }

    fn envelopePrepare(self: *Opn2Core) void {
        const slot = self.cycles;
        var rate: u8 = (self.eg_rate << 1) + self.eg_ksv;
        if (rate > 0x3F) rate = 0x3F;

        var inc: u8 = 0;
        const sum = ((rate >> 2) + self.eg_shift_lock) & 0x0F;
        if (self.eg_rate != 0 and self.eg_quotient == 2) {
            if (rate < 48) {
                switch (sum) {
                    12 => inc = 1,
                    13 => inc = (rate >> 1) & 0x01,
                    14 => inc = rate & 0x01,
                    else => {},
                }
            } else {
                const hi = eg_stephi[rate & 0x03][self.eg_timer_low_lock] + (rate >> 2) - 11;
                inc = @min(@as(u8, 4), hi);
            }
        }
        self.eg_inc = inc;
        self.eg_ratemax = (rate >> 1) == 0x1F;

        var rate_sel: EgState = @enumFromInt(self.eg_state[slot]);
        if ((self.eg_kon[slot] != 0 and self.eg_ssg_repeat_latch[slot] != 0) or
            (self.eg_kon[slot] == 0 and self.eg_kon_latch[slot] != 0))
        {
            rate_sel = .attack;
        }

        self.eg_rate = switch (rate_sel) {
            .attack => self.ar[slot],
            .decay => self.dr[slot],
            .sustain => self.sr[slot],
            .release => (self.rr[slot] << 1) | 0x01,
        };
        self.eg_ksv = self.pg_kcode >> @intCast(self.ks[slot] ^ 0x03);
        self.eg_lfo_am = if (self.am[slot] != 0)
            self.lfo_am >> @intCast(eg_am_shift[self.ams[self.channel]])
        else
            0;

        self.eg_tl[1] = self.eg_tl[0];
        self.eg_tl[0] = self.tl[slot];
        self.eg_sl[1] = self.eg_sl[0];
        self.eg_sl[0] = self.sl[slot];
    }

    fn envelopeGenerate(self: *Opn2Core) void {
        const slot = (self.cycles + 23) % 24;
        var level = self.eg_level[slot];
        if (self.eg_ssg_inv[slot] != 0) level = (512 - level) & 0x03FF;
        if (self.mode_test_21[5] != 0) level = 0;

        level +%= self.eg_lfo_am;
        if (!(self.mode_csm != 0 and self.channel == 3)) {
            level +%= @as(u16, self.eg_tl[0]) << 3;
        }
        if (level > 0x03FF) level = 0x03FF;
        self.eg_out[slot] = level;
    }

    fn updateLfo(self: *Opn2Core) void {
        if ((self.lfo_quotient & lfo_cycles[self.lfo_freq]) == lfo_cycles[self.lfo_freq]) {
            self.lfo_quotient = 0;
            self.lfo_cnt +%= 1;
        } else {
            self.lfo_quotient +%= self.lfo_inc;
        }
        self.lfo_cnt &= self.lfo_enabled_mask;
    }

    fn selectPhasePitch(self: *const Opn2Core) PitchState {
        if (self.mode_ch3 != 0) {
            return switch (self.cycles) {
                1 => .{
                    .fnum = self.fnum_3ch[1],
                    .block = self.block_3ch[1],
                    .kcode = self.kcode_3ch[1],
                },
                7 => .{
                    .fnum = self.fnum_3ch[0],
                    .block = self.block_3ch[0],
                    .kcode = self.kcode_3ch[0],
                },
                13 => .{
                    .fnum = self.fnum_3ch[2],
                    .block = self.block_3ch[2],
                    .kcode = self.kcode_3ch[2],
                },
                else => .{
                    .fnum = self.fnum[(self.channel + 1) % 6],
                    .block = self.block[(self.channel + 1) % 6],
                    .kcode = self.kcode[(self.channel + 1) % 6],
                },
            };
        }

        return .{
            .fnum = self.fnum[(self.channel + 1) % 6],
            .block = self.block[(self.channel + 1) % 6],
            .kcode = self.kcode[(self.channel + 1) % 6],
        };
    }
};

/// 2nd-order biquad low-pass filter (transposed direct form II).
/// Matches the ~-12 dB/oct rolloff of the YM2612 analog output stage.
const BiquadLpf = struct {
    b0: f32 = 0,
    b1: f32 = 0,
    b2: f32 = 0,
    a1: f32 = 0,
    a2: f32 = 0,
    z1: f32 = 0,
    z2: f32 = 0,

    fn process(self: *BiquadLpf, x: f32) f32 {
        const y = self.b0 * x + self.z1;
        self.z1 = self.b1 * x - self.a1 * y + self.z2;
        self.z2 = self.b2 * x - self.a2 * y;
        return y;
    }
};

fn buildBiquadLpf(sample_rate: f32, cutoff_hz: f32) BiquadLpf {
    const w0 = std.math.tau * cutoff_hz / sample_rate;
    const cos_w0 = @cos(w0);
    const sin_w0 = @sin(w0);
    // Q = 0.707 (Butterworth) for maximally flat passband.
    const alpha = sin_w0 / (2.0 * 0.7071067811865476);

    const a0_inv = 1.0 / (1.0 + alpha);
    return .{
        .b0 = ((1.0 - cos_w0) / 2.0) * a0_inv,
        .b1 = (1.0 - cos_w0) * a0_inv,
        .b2 = ((1.0 - cos_w0) / 2.0) * a0_inv,
        .a1 = (-2.0 * cos_w0) * a0_inv,
        .a2 = (1.0 - alpha) * a0_inv,
    };
}

pub const Ym2612Synth = struct {
    core: Opn2Core = .{},
    timing_is_pal: bool = false,
    native_sample_rate: f32 = ntscNativeSampleRate(),
    lpf_left: BiquadLpf = buildBiquadLpf(ntscNativeSampleRate(), ym_cutoff_hz),
    lpf_right: BiquadLpf = buildBiquadLpf(ntscNativeSampleRate(), ym_cutoff_hz),
    pending_writes: [max_pending_writes]YmWriteEvent = undefined,
    pending_write_read: usize = 0,
    pending_write_write: usize = 0,
    pending_write_count: usize = 0,

    pub fn setTimingMode(self: *Ym2612Synth, is_pal: bool) void {
        if (self.timing_is_pal == is_pal) return;
        self.timing_is_pal = is_pal;
        self.native_sample_rate = if (is_pal) palNativeSampleRate() else ntscNativeSampleRate();
        self.lpf_left = buildBiquadLpf(self.native_sample_rate, ym_cutoff_hz);
        self.lpf_right = buildBiquadLpf(self.native_sample_rate, ym_cutoff_hz);
    }

    pub fn reset(self: *Ym2612Synth) void {
        self.* = .{};
    }

    pub fn applyWrite(self: *Ym2612Synth, event: YmWriteEvent) void {
        self.enqueueWrite(.{
            .port = @intCast(event.port & 0x01),
            .reg = event.reg,
            .value = event.value,
        });
    }

    pub fn tick(self: *Ym2612Synth) StereoSample {
        var sum_left: i32 = 0;
        var sum_right: i32 = 0;
        for (0..internal_clocks_per_sample) |_| {
            const pins = self.clockInternal();
            sum_left += pins[0];
            sum_right += pins[1];
        }

        const inv_cycles = 1.0 / @as(f32, @floatFromInt(internal_clocks_per_sample));
        const left = @as(f32, @floatFromInt(sum_left)) * inv_cycles * ym_output_scale;
        const right = @as(f32, @floatFromInt(sum_right)) * inv_cycles * ym_output_scale;

        return .{
            .left = self.lpf_left.process(left),
            .right = self.lpf_right.process(right),
        };
    }

    fn enqueueWrite(self: *Ym2612Synth, event: YmWriteEvent) void {
        if (self.pending_write_count == self.pending_writes.len) {
            self.pending_write_read = (self.pending_write_read + 1) % self.pending_writes.len;
            self.pending_write_count -= 1;
        }

        self.pending_writes[self.pending_write_write] = event;
        self.pending_write_write = (self.pending_write_write + 1) % self.pending_writes.len;
        self.pending_write_count += 1;
    }

    fn clockInternal(self: *Ym2612Synth) [2]i16 {
        const pending: ?YmWriteEvent = if (self.pending_write_count != 0)
            self.pending_writes[self.pending_write_read]
        else
            null;
        const result = self.core.clockOne(pending);
        if (result.consumed_write) self.popPendingWrite();
        return result.pins;
    }

    fn popPendingWrite(self: *Ym2612Synth) void {
        if (self.pending_write_count == 0) return;
        self.pending_write_read = (self.pending_write_read + 1) % self.pending_writes.len;
        self.pending_write_count -= 1;
    }
};

fn ntscNativeSampleRate() f32 {
    return @as(f32, @floatFromInt(clock.master_clock_ntsc)) /
        @as(f32, @floatFromInt(clock.fm_master_cycles_per_sample));
}

fn palNativeSampleRate() f32 {
    return @as(f32, @floatFromInt(clock.master_clock_pal)) /
        @as(f32, @floatFromInt(clock.fm_master_cycles_per_sample));
}

fn signExtend(comptime sign_bit_index: u4, value: u16) i16 {
    const sign = @as(u16, 1) << sign_bit_index;
    const magnitude = sign - 1;
    return @intCast(@as(i32, @intCast(value & magnitude)) - @as(i32, @intCast(value & sign)));
}

fn clampI16(value: i32, min: i16, max: i16) i16 {
    return @intCast(std.math.clamp(value, @as(i32, min), @as(i32, max)));
}

fn decodeChannel(port: u1, base: u8) ?usize {
    if (base == 0x03) return null;
    const channel = @as(usize, port) * 3 + base;
    if (channel >= 6) return null;
    return channel;
}

fn operatorIndexFromRegister(reg: u8) u2 {
    return switch (reg & 0x0C) {
        0x00 => 0,
        0x04 => 2,
        0x08 => 1,
        0x0C => 3,
        else => unreachable,
    };
}

fn operatorSlot(channel: usize, operator: u2) usize {
    return switch (operator) {
        0 => channel,
        1 => channel + 12,
        2 => channel + 6,
        3 => channel + 18,
    };
}

fn channelPortBase(channel: u3) struct { port: u1, base: u8 } {
    return if (channel >= 3)
        .{ .port = 1, .base = @as(u8, channel - 3) }
    else
        .{ .port = 0, .base = channel };
}

fn writeEvent(port: u1, reg: u8, value: u8) YmWriteEvent {
    return .{ .master_offset = 0, .port = port, .reg = reg, .value = value };
}

fn keyEvent(channel: u3, operators: u4) YmWriteEvent {
    const mapping = channelPortBase(channel);
    const channel_bits = mapping.base | (mapping.port << 2);
    return writeEvent(0, 0x28, (@as(u8, operators) << 4) | channel_bits);
}

fn configureTestChannel(synth: *Ym2612Synth, channel: u3, algorithm: u8) void {
    const mapping = channelPortBase(channel);
    synth.applyWrite(writeEvent(mapping.port, 0xA4 + mapping.base, 0x22));
    synth.applyWrite(writeEvent(mapping.port, 0xA0 + mapping.base, 0x80));
    synth.applyWrite(writeEvent(mapping.port, 0xB0 + mapping.base, algorithm));
    synth.applyWrite(writeEvent(mapping.port, 0xB4 + mapping.base, 0xC0));

    inline for (0..4) |op_idx| {
        const offset = operator_reg_offsets[op_idx];
        synth.applyWrite(writeEvent(mapping.port, 0x30 + offset + mapping.base, 0x01));
        synth.applyWrite(writeEvent(mapping.port, 0x40 + offset + mapping.base, if (op_idx == 3) 0x00 else 0x18));
        synth.applyWrite(writeEvent(mapping.port, 0x50 + offset + mapping.base, 0x1F));
        synth.applyWrite(writeEvent(mapping.port, 0x60 + offset + mapping.base, 0x0C));
        synth.applyWrite(writeEvent(mapping.port, 0x70 + offset + mapping.base, 0x08));
        synth.applyWrite(writeEvent(mapping.port, 0x80 + offset + mapping.base, 0x24));
    }

    synth.applyWrite(keyEvent(channel, 0xF));
}

fn advanceInternalClocks(synth: *Ym2612Synth, clocks: usize) void {
    for (0..clocks) |_| {
        _ = synth.clockInternal();
    }
}

fn drainPendingWrites(synth: *Ym2612Synth, max_clocks: usize) usize {
    var elapsed: usize = 0;
    while (synth.pending_write_count != 0 and elapsed < max_clocks) : (elapsed += 1) {
        _ = synth.clockInternal();
    }
    return elapsed;
}

test "ym a4 high latch applies on the next a0 write" {
    var synth = Ym2612Synth{};

    synth.applyWrite(writeEvent(0, 0xA4, 0x22));
    try std.testing.expect(drainPendingWrites(&synth, 32) > 0);
    try std.testing.expectEqual(@as(u8, 0x22), synth.core.reg_a4[0]);
    try std.testing.expectEqual(@as(u16, 0), synth.core.fnum[0]);

    synth.applyWrite(writeEvent(0, 0xA0, 0x80));
    try std.testing.expect(drainPendingWrites(&synth, 32) > 0);
    try std.testing.expectEqual(@as(u16, 0x280), synth.core.fnum[0]);
    try std.testing.expectEqual(@as(u8, 4), synth.core.block[0]);
}

test "ym a4 high latches are tracked per channel" {
    var synth = Ym2612Synth{};

    synth.applyWrite(writeEvent(0, 0xA4, 0x22));
    synth.applyWrite(writeEvent(0, 0xA5, 0x1F));
    synth.applyWrite(writeEvent(0, 0xA0, 0x80));
    synth.applyWrite(writeEvent(0, 0xA1, 0x40));

    try std.testing.expect(drainPendingWrites(&synth, 128) > 0);
    try std.testing.expectEqual(@as(u8, 0x22), synth.core.reg_a4[0]);
    try std.testing.expectEqual(@as(u8, 0x1F), synth.core.reg_a4[1]);
    try std.testing.expectEqual(@as(u16, 0x280), synth.core.fnum[0]);
    try std.testing.expectEqual(@as(u8, 4), synth.core.block[0]);
    try std.testing.expectEqual(@as(u16, 0x740), synth.core.fnum[1]);
    try std.testing.expectEqual(@as(u8, 3), synth.core.block[1]);
}

test "ym native sample drains exactly one frame of internal writes" {
    var synth = Ym2612Synth{};

    for (0..internal_clocks_per_sample + 1) |_| {
        synth.applyWrite(writeEvent(0, 0x22, 0x00));
    }

    _ = synth.tick();

    try std.testing.expectEqual(@as(usize, 1), synth.pending_write_count);
}

test "ym key on waits for the channel phase latch" {
    var synth = Ym2612Synth{};

    synth.applyWrite(keyEvent(0, 0xF));
    advanceInternalClocks(&synth, 1);
    try std.testing.expectEqual(@as(u8, 0), synth.core.mode_kon[0]);
    try std.testing.expectEqual(@as(u8, 0), synth.core.eg_kon_latch[0]);

    advanceInternalClocks(&synth, 24);
    try std.testing.expectEqual(@as(u8, 1), synth.core.mode_kon[0]);
    try std.testing.expectEqual(@as(u8, 1), synth.core.mode_kon[6]);
    try std.testing.expectEqual(@as(u8, 1), synth.core.mode_kon[12]);
    try std.testing.expectEqual(@as(u8, 1), synth.core.mode_kon[18]);
}

test "ym timer a overflow triggers csm key on" {
    var synth = Ym2612Synth{};

    synth.applyWrite(writeEvent(0, 0x24, 0xFF));
    synth.applyWrite(writeEvent(0, 0x25, 0x03));
    synth.applyWrite(writeEvent(0, 0x27, 0x85));

    var saw_csm_key_on = false;
    for (0..256) |_| {
        _ = synth.clockInternal();
        for (synth.core.eg_kon_csm) |flag| {
            if (flag != 0) saw_csm_key_on = true;
        }
    }

    try std.testing.expect(saw_csm_key_on);
    try std.testing.expectEqual(@as(u8, 1), synth.core.timer_a_overflow_flag);
}

test "ym operator algorithms produce distinct output" {
    var synth_a = Ym2612Synth{};
    var synth_b = Ym2612Synth{};
    configureTestChannel(&synth_a, 0, 0);
    configureTestChannel(&synth_b, 0, 7);

    var sum_diff: f32 = 0.0;
    for (0..512) |_| {
        const a = synth_a.tick();
        const b = synth_b.tick();
        sum_diff += @abs(a.left - b.left) + @abs(a.right - b.right);
    }

    try std.testing.expect(sum_diff > 0.1);
}

test "ym key off releases output over time" {
    var synth = Ym2612Synth{};
    configureTestChannel(&synth, 0, 4);

    var pre_release_energy: f32 = 0.0;
    for (0..384) |_| {
        const sample = synth.tick();
        pre_release_energy += @abs(sample.left) + @abs(sample.right);
    }

    synth.applyWrite(keyEvent(0, 0x0));

    var post_release_energy: f32 = 0.0;
    for (0..768) |_| {
        const sample = synth.tick();
        post_release_energy += @abs(sample.left) + @abs(sample.right);
    }

    try std.testing.expect(pre_release_energy > 0.05);
    try std.testing.expect(post_release_energy < pre_release_energy);
}

test "ym channel 3 special mode uses operator-specific frequencies" {
    var normal = Ym2612Synth{};
    var special = Ym2612Synth{};

    configureTestChannel(&normal, 2, 0);
    configureTestChannel(&special, 2, 0);

    special.applyWrite(writeEvent(0, 0x27, 0x40));
    special.applyWrite(writeEvent(0, 0xAC, 0x25));
    special.applyWrite(writeEvent(0, 0xA8, 0x40));
    special.applyWrite(writeEvent(0, 0xAD, 0x1F));
    special.applyWrite(writeEvent(0, 0xA9, 0x10));
    special.applyWrite(writeEvent(0, 0xAE, 0x29));
    special.applyWrite(writeEvent(0, 0xAA, 0xE0));

    var sum_diff: f32 = 0.0;
    for (0..512) |_| {
        const a = normal.tick();
        const b = special.tick();
        sum_diff += @abs(a.left - b.left) + @abs(a.right - b.right);
    }

    try std.testing.expect(sum_diff > 0.1);
}

test "ym lfo sensitivity modulates output" {
    var no_lfo = Ym2612Synth{};
    var with_lfo = Ym2612Synth{};

    configureTestChannel(&no_lfo, 1, 4);
    configureTestChannel(&with_lfo, 1, 4);
    with_lfo.applyWrite(writeEvent(0, 0x22, 0x0F));
    with_lfo.applyWrite(writeEvent(0, 0x60 + operator_reg_offsets[3] + 1, 0x80 | 0x0C));
    with_lfo.applyWrite(writeEvent(0, 0xB4 + 1, 0xF7));

    var sum_diff: f32 = 0.0;
    for (0..1024) |_| {
        const a = no_lfo.tick();
        const b = with_lfo.tick();
        sum_diff += @abs(a.left - b.left) + @abs(a.right - b.right);
    }

    try std.testing.expect(sum_diff > 0.1);
}

test "ym ssg-eg repeat type produces sustained output" {
    var normal = Ym2612Synth{};
    var ssg_synth = Ym2612Synth{};

    configureTestChannel(&normal, 0, 4);
    configureTestChannel(&ssg_synth, 0, 4);

    inline for (0..4) |op_idx| {
        const offset = operator_reg_offsets[op_idx];
        ssg_synth.applyWrite(writeEvent(0, 0x90 + offset, 0x08));
    }

    var normal_late_energy: f32 = 0.0;
    var ssg_late_energy: f32 = 0.0;

    for (0..3072) |_| {
        _ = normal.tick();
        _ = ssg_synth.tick();
    }

    for (0..1024) |_| {
        const a = normal.tick();
        const b = ssg_synth.tick();
        normal_late_energy += @abs(a.left) + @abs(a.right);
        ssg_late_energy += @abs(b.left) + @abs(b.right);
    }

    try std.testing.expect(ssg_late_energy > normal_late_energy);
}

test "ym dac output appears when enabled" {
    var disabled = Ym2612Synth{};
    var enabled = Ym2612Synth{};

    disabled.applyWrite(writeEvent(0, 0x2A, 0xFF));
    enabled.applyWrite(writeEvent(0, 0x2B, 0x80));
    enabled.applyWrite(writeEvent(0, 0x2A, 0xFF));

    var disabled_energy: f32 = 0.0;
    var enabled_energy: f32 = 0.0;
    for (0..256) |_| {
        const a = disabled.tick();
        const b = enabled.tick();
        disabled_energy += @abs(a.left) + @abs(a.right);
        enabled_energy += @abs(b.left) + @abs(b.right);
    }

    try std.testing.expect(enabled_energy > disabled_energy);
}

test "ym fmGenerate tolerates fully attenuated levels" {
    var synth = Ym2612Synth{};
    const slot: usize = 19;
    synth.core.eg_out[slot] = 0x03FF;
    synth.core.pg_phase[slot] = 0;
    synth.core.fm_mod[slot] = 0;
    synth.core.cycles = 0;

    synth.core.fmGenerate();

    try std.testing.expectEqual(@as(i16, 0), synth.core.fm_out[slot]);
}
