const std = @import("std");
const math = std.math;

// --- Constants ---

const ENV_BITS: u5 = 10;
const ENV_LEN: u32 = 1 << ENV_BITS; // 1024
const ENV_STEP: f64 = 128.0 / @as(f64, @floatFromInt(ENV_LEN));
const MAX_ATT_INDEX: i32 = @as(i32, ENV_LEN) - 1; // 1023
const MIN_ATT_INDEX: i32 = 0;

const SIN_BITS: u5 = 10;
const SIN_LEN: u32 = 1 << SIN_BITS; // 1024
const SIN_MASK: u32 = SIN_LEN - 1;

const TL_RES_LEN: u32 = 256;
const TL_TAB_LEN: u32 = 13 * 2 * TL_RES_LEN; // 6656
const ENV_QUIET: u32 = TL_TAB_LEN >> 3; // 832

const DT_BITS: u5 = 17;
const DT_LEN: u32 = 1 << DT_BITS;
const DT_MASK: u32 = DT_LEN - 1;

const RATE_STEPS: u32 = 8;

const EG_ATT: u8 = 4;
const EG_DEC: u8 = 3;
const EG_SUS: u8 = 2;
const EG_REL: u8 = 1;
const EG_OFF: u8 = 0;

// Slot indices matching the standard FM operator ordering convention.
const SLOT1: usize = 0;
const SLOT2: usize = 2;
const SLOT3: usize = 1;
const SLOT4: usize = 3;

// --- Static Lookup Tables ---

// Sustain level table (3dB per step)
// attenuation value (10 bits) = (SL << 2) << 3
fn scDb(db: u32) u32 {
    return @intFromFloat(@as(f64, @floatFromInt(db)) * (4.0 / ENV_STEP));
}

const sl_table: [16]u32 = .{
    scDb(0), scDb(1), scDb(2),  scDb(3),  scDb(4),  scDb(5),  scDb(6),  scDb(7),
    scDb(8), scDb(9), scDb(10), scDb(11), scDb(12), scDb(13), scDb(14), scDb(31),
};

// Envelope generator increment table
const eg_inc: [19 * RATE_STEPS]u8 = .{
    // cycle: 0 1  2 3  4 5  6 7
    0, 1, 0, 1, 0, 1, 0, 1, // rates 00..11 0
    0, 1, 0, 1, 1, 1, 0, 1, // rates 00..11 1
    0, 1, 1, 1, 0, 1, 1, 1, // rates 00..11 2
    0, 1, 1, 1, 1, 1, 1, 1, // rates 00..11 3
    1, 1, 1, 1, 1, 1, 1, 1, // rate 12 0
    1, 1, 1, 2, 1, 1, 1, 2, // rate 12 1
    1, 2, 1, 2, 1, 2, 1, 2, // rate 12 2
    1, 2, 2, 2, 1, 2, 2, 2, // rate 12 3
    2, 2, 2, 2, 2, 2, 2, 2, // rate 13 0
    2, 2, 2, 4, 2, 2, 2, 4, // rate 13 1
    2, 4, 2, 4, 2, 4, 2, 4, // rate 13 2
    2, 4, 4, 4, 2, 4, 4, 4, // rate 13 3
    4, 4, 4, 4, 4, 4, 4, 4, // rate 14 0
    4, 4, 4, 8, 4, 4, 4, 8, // rate 14 1
    4, 8, 4, 8, 4, 8, 4, 8, // rate 14 2
    4, 8, 8, 8, 4, 8, 8, 8, // rate 14 3
    8, 8, 8, 8, 8, 8, 8, 8, // rates 15 0-3
    16, 16, 16, 16, 16, 16, 16, 16, // rates 15 2,3 for attack
    0, 0, 0, 0, 0, 0, 0, 0, // infinity rates
};

fn oRate(a: u32) u8 {
    return @intCast(a * RATE_STEPS);
}

// Envelope generator rate select (32+64+32 = 128 entries)
const eg_rate_select: [128]u8 = .{
    // 32 infinite time rates
    oRate(18), oRate(18), oRate(18), oRate(18), oRate(18), oRate(18), oRate(18), oRate(18),
    oRate(18), oRate(18), oRate(18), oRate(18), oRate(18), oRate(18), oRate(18), oRate(18),
    oRate(18), oRate(18), oRate(18), oRate(18), oRate(18), oRate(18), oRate(18), oRate(18),
    oRate(18), oRate(18), oRate(18), oRate(18), oRate(18), oRate(18), oRate(18), oRate(18),
    // rates 00-11
    oRate(18), oRate(18), oRate(2),  oRate(3),  oRate(0),  oRate(1),  oRate(2),  oRate(3),
    oRate(0),  oRate(1),  oRate(2),  oRate(3),  oRate(0),  oRate(1),  oRate(2),  oRate(3),
    oRate(0),  oRate(1),  oRate(2),  oRate(3),  oRate(0),  oRate(1),  oRate(2),  oRate(3),
    oRate(0),  oRate(1),  oRate(2),  oRate(3),  oRate(0),  oRate(1),  oRate(2),  oRate(3),
    oRate(0),  oRate(1),  oRate(2),  oRate(3),  oRate(0),  oRate(1),  oRate(2),  oRate(3),
    oRate(0),  oRate(1),  oRate(2),  oRate(3),  oRate(0),  oRate(1),  oRate(2),  oRate(3),
    // rate 12
    oRate(4),  oRate(5),  oRate(6),  oRate(7),
    // rate 13
     oRate(8),  oRate(9),  oRate(10), oRate(11),
    // rate 14
    oRate(12), oRate(13), oRate(14), oRate(15),
    // rate 15
    oRate(16), oRate(16), oRate(16), oRate(16),
    // 32 dummy rates
    oRate(16), oRate(16), oRate(16), oRate(16), oRate(16), oRate(16), oRate(16), oRate(16),
    oRate(16), oRate(16), oRate(16), oRate(16), oRate(16), oRate(16), oRate(16), oRate(16),
    oRate(16), oRate(16), oRate(16), oRate(16), oRate(16), oRate(16), oRate(16), oRate(16),
    oRate(16), oRate(16), oRate(16), oRate(16), oRate(16), oRate(16), oRate(16), oRate(16),
};

// Envelope generator rate shift (32+64+32 = 128 entries)
const eg_rate_shift: [128]u8 = .{
    // 32 infinite time rates (fixed, same as rate 0)
    11, 11, 11, 11, 11, 11, 11, 11,
    11, 11, 11, 11, 11, 11, 11, 11,
    11, 11, 11, 11, 11, 11, 11, 11,
    11, 11, 11, 11, 11, 11, 11, 11,
    // rates 00-11
    11, 11, 11, 11, 10, 10, 10, 10,
    9,  9,  9,  9,  8,  8,  8,  8,
    7,  7,  7,  7,  6,  6,  6,  6,
    5,  5,  5,  5,  4,  4,  4,  4,
    3,  3,  3,  3,  2,  2,  2,  2,
    1,  1,  1,  1,  0,  0,  0,  0,
    // rate 12
    0,  0,  0,  0,
    // rate 13
     0,  0,  0,  0,
    // rate 14
    0,  0,  0,  0,
    // rate 15
     0,  0,  0,  0,
    // 32 dummy rates
    0,  0,  0,  0,  0,  0,  0,  0,
    0,  0,  0,  0,  0,  0,  0,  0,
    0,  0,  0,  0,  0,  0,  0,  0,
    0,  0,  0,  0,  0,  0,  0,  0,
};

// Detune table (4 * 32 = 128 entries)
const dt_tab: [128]u8 = .{
    // FD=0
    0, 0, 0, 0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,
    0, 0, 0, 0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,
    // FD=1
    0, 0, 0, 0,  1,  1,  1,  1,  1,  1,  1,  1,  2,  2,  2,  2,
    2, 3, 3, 3,  4,  4,  4,  5,  5,  6,  6,  7,  8,  8,  8,  8,
    // FD=2
    1, 1, 1, 1,  2,  2,  2,  2,  2,  3,  3,  3,  4,  4,  4,  5,
    5, 6, 6, 7,  8,  8,  9,  10, 11, 12, 13, 14, 16, 16, 16, 16,
    // FD=3
    2, 2, 2, 2,  2,  3,  3,  3,  4,  4,  4,  5,  5,  6,  6,  7,
    8, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 20, 22, 22, 22, 22,
};

// OPN key frequency number -> key code lower 2 bits
const opn_fktable: [16]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 1, 2, 3, 3, 3, 3, 3, 3, 3 };

// 8 LFO speed parameters (samples per step)
const lfo_samples_per_step: [8]u32 = .{ 108, 77, 71, 67, 62, 44, 8, 5 };

// LFO AM depth shift
const lfo_ams_depth_shift: [4]u8 = .{ 8, 3, 1, 0 };

// LFO PM output (7 bits * 8 depths, 8 levels each)
const lfo_pm_output: [56][8]u8 = .{
    // FNUM BIT 4: 000 0001xxxx
    .{ 0, 0, 0, 0, 0, 0, 0, 0 }, // DEPTH 0
    .{ 0, 0, 0, 0, 0, 0, 0, 0 }, // DEPTH 1
    .{ 0, 0, 0, 0, 0, 0, 0, 0 }, // DEPTH 2
    .{ 0, 0, 0, 0, 0, 0, 0, 0 }, // DEPTH 3
    .{ 0, 0, 0, 0, 0, 0, 0, 0 }, // DEPTH 4
    .{ 0, 0, 0, 0, 0, 0, 0, 0 }, // DEPTH 5
    .{ 0, 0, 0, 0, 0, 0, 0, 0 }, // DEPTH 6
    .{ 0, 0, 0, 0, 1, 1, 1, 1 }, // DEPTH 7
    // FNUM BIT 5: 000 0010xxxx
    .{ 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 0, 0, 0, 0, 1, 1, 1, 1 },
    .{ 0, 0, 1, 1, 2, 2, 2, 3 },
    // FNUM BIT 6: 000 0100xxxx
    .{ 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 0, 0, 0, 0, 0, 0, 0, 1 },
    .{ 0, 0, 0, 0, 1, 1, 1, 1 },
    .{ 0, 0, 1, 1, 2, 2, 2, 3 },
    .{ 0, 0, 2, 3, 4, 4, 5, 6 },
    // FNUM BIT 7: 000 1000xxxx
    .{ 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 0, 0, 0, 0, 0, 0, 1, 1 },
    .{ 0, 0, 0, 0, 1, 1, 1, 1 },
    .{ 0, 0, 0, 1, 1, 1, 1, 2 },
    .{ 0, 0, 1, 1, 2, 2, 2, 3 },
    .{ 0, 0, 2, 3, 4, 4, 5, 6 },
    .{ 0, 0, 4, 6, 8, 8, 0xa, 0xc },
    // FNUM BIT 8: 001 0000xxxx
    .{ 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 0, 0, 0, 0, 1, 1, 1, 1 },
    .{ 0, 0, 0, 1, 1, 1, 2, 2 },
    .{ 0, 0, 1, 1, 2, 2, 3, 3 },
    .{ 0, 0, 1, 2, 2, 2, 3, 4 },
    .{ 0, 0, 2, 3, 4, 4, 5, 6 },
    .{ 0, 0, 4, 6, 8, 8, 0xa, 0xc },
    .{ 0, 0, 8, 0xc, 0x10, 0x10, 0x14, 0x18 },
    // FNUM BIT 9: 010 0000xxxx
    .{ 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 0, 0, 0, 0, 2, 2, 2, 2 },
    .{ 0, 0, 0, 2, 2, 2, 4, 4 },
    .{ 0, 0, 2, 2, 4, 4, 6, 6 },
    .{ 0, 0, 2, 4, 4, 4, 6, 8 },
    .{ 0, 0, 4, 6, 8, 8, 0xa, 0xc },
    .{ 0, 0, 8, 0xc, 0x10, 0x10, 0x14, 0x18 },
    .{ 0, 0, 0x10, 0x18, 0x20, 0x20, 0x28, 0x30 },
    // FNUM BIT 10: 100 0000xxxx
    .{ 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 0, 0, 0, 0, 4, 4, 4, 4 },
    .{ 0, 0, 0, 4, 4, 4, 8, 8 },
    .{ 0, 0, 4, 4, 8, 8, 0xc, 0xc },
    .{ 0, 0, 4, 8, 8, 8, 0xc, 0x10 },
    .{ 0, 0, 8, 0xc, 0x10, 0x10, 0x14, 0x18 },
    .{ 0, 0, 0x10, 0x18, 0x20, 0x20, 0x28, 0x30 },
    .{ 0, 0, 0x20, 0x30, 0x40, 0x40, 0x50, 0x60 },
};

// Multiple table: (v&0x0f)? (v&0x0f)*2 : 1
const ml_table: [16]u32 = .{ 1, 2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 22, 24, 26, 28, 30 };

// --- LFO PM table (128*8*32 = 32768 entries, built at init time) ---
// All tables computed at comptime for deterministic results across platforms.

const tl_tab: [TL_TAB_LEN]i32 = blk: {
    @setEvalBranchQuota(200000);
    var tab = [_]i32{0} ** TL_TAB_LEN;
    for (0..TL_RES_LEN) |xi| {
        const x: f64 = @floatFromInt(xi);
        var m: f64 = @as(f64, 65536.0) / math.pow(f64, 2.0, (x + 1.0) * (ENV_STEP / 4.0) / 8.0);
        m = @floor(m);
        var n: i32 = @intFromFloat(m);
        n >>= 4;
        if (n & 1 != 0) {
            n = (n >> 1) + 1;
        } else {
            n = n >> 1;
        }
        n <<= 2;
        tab[xi * 2 + 0] = n;
        tab[xi * 2 + 1] = -n;
        for (1..13) |ii| {
            tab[xi * 2 + 0 + ii * 2 * TL_RES_LEN] = tab[xi * 2 + 0] >> @intCast(ii);
            tab[xi * 2 + 1 + ii * 2 * TL_RES_LEN] = -tab[xi * 2 + 0 + ii * 2 * TL_RES_LEN];
        }
    }
    break :blk tab;
};

const sin_tab: [SIN_LEN]u32 = blk: {
    @setEvalBranchQuota(200000);
    var tab = [_]u32{0} ** SIN_LEN;
    for (0..SIN_LEN) |ii| {
        const i_f: f64 = @floatFromInt(ii);
        const m_val: f64 = @sin(((i_f * 2.0) + 1.0) * math.pi / @as(f64, @floatFromInt(SIN_LEN)));
        var o: f64 = if (m_val > 0.0)
            8.0 * @log(1.0 / m_val) / @log(2.0)
        else
            8.0 * @log(-1.0 / m_val) / @log(2.0);
        o = o / (ENV_STEP / 4.0);
        var n: i32 = @intFromFloat(2.0 * o);
        if (n & 1 != 0) {
            n = (n >> 1) + 1;
        } else {
            n = n >> 1;
        }
        const sign_bit: u32 = if (m_val >= 0.0) 0 else 1;
        tab[ii] = @as(u32, @intCast(n)) * 2 + sign_bit;
    }
    break :blk tab;
};

const lfo_pm_table: [128 * 8 * 32]i32 = blk: {
    @setEvalBranchQuota(200000);
    var tab = [_]i32{0} ** (128 * 8 * 32);
    for (0..8) |i_depth| {
        for (0..128) |fnum| {
            for (0..8) |step| {
                var value: i32 = 0;
                for (0..7) |bit_tmp| {
                    if (fnum & (@as(usize, 1) << @intCast(bit_tmp)) != 0) {
                        const offset_fnum_bit = bit_tmp * 8;
                        value += @as(i32, lfo_pm_output[offset_fnum_bit + i_depth][step]);
                    }
                }
                tab[(fnum * 32 * 8) + (i_depth * 32) + step + 0] = value;
                tab[(fnum * 32 * 8) + (i_depth * 32) + (step ^ 7) + 8] = value;
                tab[(fnum * 32 * 8) + (i_depth * 32) + step + 16] = -value;
                tab[(fnum * 32 * 8) + (i_depth * 32) + (step ^ 7) + 24] = -value;
            }
        }
    }
    break :blk tab;
};

// --- Data Structures ---

pub const FmSlot = struct {
    // Detune table index (into the parent Ym2612Sample.dt_tab)
    dt_idx: u3 = 0,

    KSR: u8 = 0, // 3-KSR
    ar: u32 = 0, // attack rate
    d1r: u32 = 0, // decay rate
    d2r: u32 = 0, // sustain rate
    rr: u32 = 0, // release rate
    ksr: u8 = 0, // key scale rate: kcode>>(3-KSR)
    mul: u32 = 0, // multiple: ML_TABLE[ML]

    // Phase Generator
    phase: u32 = 0, // phase counter
    incr: i32 = -1, // phase step (-1 = needs recalc)

    // Envelope Generator
    state: u8 = EG_OFF,
    tl: u32 = 0, // total level: TL << 3
    volume: i32 = MAX_ATT_INDEX,
    sl: u32 = 0, // sustain level: sl_table[SL]
    vol_out: u32 = @intCast(MAX_ATT_INDEX), // current output from EG (without AM)

    eg_sh_ar: u8 = 0,
    eg_sel_ar: u8 = 0,
    eg_sh_d1r: u8 = 0,
    eg_sel_d1r: u8 = 0,
    eg_sh_d2r: u8 = 0,
    eg_sel_d2r: u8 = 0,
    eg_sh_rr: u8 = 0,
    eg_sel_rr: u8 = 0,

    ssg: u8 = 0, // SSG-EG waveform
    ssgn: u8 = 0, // SSG-EG negated output

    key: u8 = 0, // 0=KEY OFF, 1=KEY ON

    am_mask: u32 = 0, // AM enable flag (0 or 0xFFFFFFFF)
};

pub const FmChannel = struct {
    slot: [4]FmSlot = .{ FmSlot{}, FmSlot{}, FmSlot{}, FmSlot{} },

    algo: u8 = 0,
    fb: u8 = 31, // feedback shift (SIN_BITS when FB=0)
    op1_out: [2]i32 = .{ 0, 0 },

    mem_value: i32 = 0,

    pms: i32 = 0,
    ams: u8 = 0,

    fc: u32 = 0,
    kcode: u8 = 0,
    block_fnum: u32 = 0,
};

pub const Fm3Slot = struct {
    fc: [3]u32 = .{ 0, 0, 0 },
    fn_h: u8 = 0,
    kcode: [3]u8 = .{ 0, 0, 0 },
    block_fnum: [3]u32 = .{ 0, 0, 0 },
    key_csm: u8 = 0,
};

pub const ChipType = enum(u2) {
    discrete = 0,
    integrated = 1,
    enhanced = 2,
};

// Algorithm routing destination enum
// In the C code, pointers are used (connect1/2/3/4/mem_connect -> &c1, &c2, &m2, &mem, &out_fm[ch])
// In Zig, we use an enum to identify which scratch variable to write to.
const ConnDest = enum {
    m2,
    c1,
    c2,
    mem,
    carrier,
    algo5_special, // null pointer in C (algo 5 special case for slot 1)
};

pub const Ym2612Sample = struct {
    ch: [6]FmChannel = [_]FmChannel{FmChannel{}} ** 6,

    dacen: bool = false,
    dacout: i32 = 0,

    // OPN state
    address: u16 = 0,
    status: u8 = 0,
    mode: u8 = 0,
    fn_h: u8 = 0,

    // Timers
    ta: i32 = 0,
    tal: i32 = 1024,
    tac: i32 = 0,
    tb: i32 = 0,
    tbl: i32 = 256 << 4,
    tbc: i32 = 0,

    // 3-slot mode
    sl3: Fm3Slot = Fm3Slot{},

    // Panning (bitmasks)
    pan: [12]u32 = [_]u32{0} ** 12,

    // Envelope generator
    eg_cnt: u32 = 0,
    eg_timer: u32 = 0,

    // LFO
    lfo_cnt: u8 = 0,
    lfo_timer: u32 = 0,
    lfo_timer_overflow: u32 = 0,
    lfo_am: u32 = 126,
    lfo_pm: u32 = 0,

    // Detune table
    dt_tab: [8][32]i32 = [_][32]i32{[_]i32{0} ** 32} ** 8,

    // Chip type
    chip_type: ChipType = .discrete,

    // Operator output mask (for 9-bit vs 14-bit DAC)
    op_mask: [8][4]u32 = [_][4]u32{[_]u32{0xFFFFFFFF} ** 4} ** 8,

    // Scratch space for channel calculation
    out_fm: [6]i32 = [_]i32{0} ** 6,
    scratch_m2: i32 = 0,
    scratch_c1: i32 = 0,
    scratch_c2: i32 = 0,
    scratch_mem: i32 = 0,

    // ----- Public API -----

    pub fn init() Ym2612Sample {
        var self = Ym2612Sample{};
        self.buildDetuneTables();
        self.buildDefaultOpMask();
        self.reset();
        return self;
    }

    pub fn reset(self: *Ym2612Sample) void {
        self.eg_timer = 0;
        self.eg_cnt = 0;
        self.lfo_timer_overflow = 0;
        self.lfo_timer = 0;
        self.lfo_cnt = 0;
        self.lfo_am = 126;
        self.lfo_pm = 0;
        self.tac = 0;
        self.tbc = 0;
        self.sl3 = Fm3Slot{};
        self.dacen = false;
        self.dacout = 0;
        self.status = 0;

        self.setTimers(0x30);
        self.tb = 0;
        self.tbl = 256 << 4;
        self.ta = 0;
        self.tal = 1024;

        // Reset channels
        self.resetChannels();

        // Default panning (b4-b6 register writes with 0xC0)
        var i: usize = 0xb6;
        while (i >= 0xb4) : (i -= 1) {
            self.opnWriteReg(@intCast(i), 0xc0);
            self.opnWriteReg(@intCast(i | 0x100), 0xc0);
        }
        i = 0xb2;
        while (i >= 0x30) : (i -= 1) {
            self.opnWriteReg(@intCast(i), 0);
            self.opnWriteReg(@intCast(i | 0x100), 0);
            if (i == 0x30) break;
        }
    }

    pub fn config(self: *Ym2612Sample, chip_type: ChipType) void {
        self.chip_type = chip_type;
        // Reset all masks to full
        for (&self.op_mask) |*algo| {
            for (algo) |*mask| {
                mask.* = 0xFFFFFFFF;
            }
        }

        if (chip_type != .enhanced) {
            // 9-bit DAC: mask bottom 5 bits on carrier operators
            self.op_mask[0][3] = 0xFFFFFFE0;
            self.op_mask[1][3] = 0xFFFFFFE0;
            self.op_mask[2][3] = 0xFFFFFFE0;
            self.op_mask[3][3] = 0xFFFFFFE0;
            self.op_mask[4][1] = 0xFFFFFFE0;
            self.op_mask[4][3] = 0xFFFFFFE0;
            self.op_mask[5][1] = 0xFFFFFFE0;
            self.op_mask[5][2] = 0xFFFFFFE0;
            self.op_mask[5][3] = 0xFFFFFFE0;
            self.op_mask[6][1] = 0xFFFFFFE0;
            self.op_mask[6][2] = 0xFFFFFFE0;
            self.op_mask[6][3] = 0xFFFFFFE0;
            self.op_mask[7][0] = 0xFFFFFFE0;
            self.op_mask[7][1] = 0xFFFFFFE0;
            self.op_mask[7][2] = 0xFFFFFFE0;
            self.op_mask[7][3] = 0xFFFFFFE0;
        }
    }

    /// Write to a YM2612 port. `a` is 0-3 (address/data for port 0/1).
    pub fn write(self: *Ym2612Sample, a: u2, v: u8) void {
        switch (a) {
            0 => self.address = v,
            2 => self.address = @as(u16, v) | 0x100,
            else => self.writeData(v),
        }
    }

    /// Read status register.
    pub fn readStatus(self: *const Ym2612Sample) u8 {
        return self.status;
    }

    /// Generate one stereo sample. Returns [left, right].
    pub fn update(self: *Ym2612Sample) [2]i32 {
        // Refresh PG increments and EG rates
        self.refreshFcEgChan(0);
        self.refreshFcEgChan(1);

        if (self.mode & 0xC0 == 0) {
            self.refreshFcEgChan(2);
        } else {
            // 3-slot mode
            if (self.ch[2].slot[SLOT1].incr == -1) {
                self.refreshFcEgSlot(2, SLOT1, self.sl3.fc[1], self.sl3.kcode[1]);
                self.refreshFcEgSlot(2, SLOT2, self.sl3.fc[2], self.sl3.kcode[2]);
                self.refreshFcEgSlot(2, SLOT3, self.sl3.fc[0], self.sl3.kcode[0]);
                self.refreshFcEgSlot(2, SLOT4, self.ch[2].fc, self.ch[2].kcode);
            }
        }

        self.refreshFcEgChan(3);
        self.refreshFcEgChan(4);
        self.refreshFcEgChan(5);

        // Clear outputs
        self.out_fm = [_]i32{0} ** 6;

        // Update SSG-EG
        self.updateSsgEgChannels();

        // Calculate FM channels
        if (!self.dacen) {
            self.chanCalcRange(0, 6);
        } else {
            // DAC mode - channel 5 uses DAC output
            self.out_fm[5] = self.dacout;
            self.chanCalcRange(0, 5);
        }

        // Advance LFO
        self.advanceLfo();

        // EG is updated every 3 samples
        self.eg_timer += 1;
        if (self.eg_timer >= 3) {
            self.eg_timer = 0;
            self.eg_cnt += 1;
            // EG counter is 12-bit only and zero value is skipped
            if (self.eg_cnt == 4096)
                self.eg_cnt = 1;
            self.advanceEgChannels();
        }

        // Channel accumulator output clipping (14-bit max)
        for (&self.out_fm) |*out| {
            if (out.* > 8191) out.* = 8191 else if (out.* < -8192) out.* = -8192;
        }

        // Stereo DAC output panning & mixing
        var lt: i32 = 0;
        var rt: i32 = 0;
        for (0..6) |ci| {
            lt += self.out_fm[ci] & asI32(self.pan[ci * 2]);
            rt += self.out_fm[ci] & asI32(self.pan[ci * 2 + 1]);
        }

        // Discrete YM2612 DAC ladder effect
        if (self.chip_type == .discrete) {
            for (0..6) |ci| {
                if (self.out_fm[ci] < 0) {
                    lt -= @as(i32, @intCast(4 - (self.pan[ci * 2] & 1))) << 5;
                    rt -= @as(i32, @intCast(4 - (self.pan[ci * 2 + 1] & 1))) << 5;
                } else {
                    lt += 4 << 5;
                    rt += 4 << 5;
                }
            }
        }

        // CSM mode handling
        self.sl3.key_csm <<= 1;

        // Timer A control
        self.internalTimerA();

        // CSM Mode Key OFF
        if (self.sl3.key_csm & 2 != 0) {
            self.fmKeyoffCsm(2, SLOT1);
            self.fmKeyoffCsm(2, SLOT2);
            self.fmKeyoffCsm(2, SLOT3);
            self.fmKeyoffCsm(2, SLOT4);
            self.sl3.key_csm = 0;
        }

        // Timer B control (1 sample step)
        self.internalTimerB(1);

        return .{ lt, rt };
    }

    // ----- Internal functions -----

    fn writeData(self: *Ym2612Sample, v: u8) void {
        const addr = self.address;
        const addr_lo: u8 = @truncate(addr);
        if ((addr & 0x1F0) == 0x020) {
            switch (addr_lo) {
                0x2A => self.dacout = (@as(i32, v) - 0x80) << 6,
                0x2B => self.dacen = (v & 0x80) != 0,
                else => self.opnWriteMode(addr_lo, v),
            }
        } else {
            self.opnWriteReg(@intCast(addr), v);
        }
    }

    fn opnWriteMode(self: *Ym2612Sample, r: u8, v: u8) void {
        switch (r) {
            0x21 => {}, // Test
            0x22 => {
                // LFO FREQ
                if (v & 8 != 0) {
                    self.lfo_timer_overflow = lfo_samples_per_step[v & 7];
                } else {
                    self.lfo_timer_overflow = 0;
                    self.lfo_timer = 0;
                    self.lfo_cnt = 0;
                    self.lfo_pm = 0;
                    self.lfo_am = 126;
                }
            },
            0x24 => {
                // Timer A High
                self.ta = (self.ta & 0x03) | (@as(i32, v) << 2);
                self.tal = 1024 - self.ta;
            },
            0x25 => {
                // Timer A Low
                self.ta = (self.ta & 0x3fc) | @as(i32, v & 3);
                self.tal = 1024 - self.ta;
            },
            0x26 => {
                // Timer B
                self.tb = v;
                self.tbl = (256 - @as(i32, v)) << 4;
            },
            0x27 => {
                // Mode, timer control
                self.setTimers(v);
            },
            0x28 => {
                // Key on/off
                var c: usize = v & 0x03;
                if (c == 3) return;
                if (v & 0x04 != 0) c += 3;
                if (v & 0x10 != 0) self.fmKeyon(c, SLOT1) else self.fmKeyoff(c, SLOT1);
                if (v & 0x20 != 0) self.fmKeyon(c, SLOT2) else self.fmKeyoff(c, SLOT2);
                if (v & 0x40 != 0) self.fmKeyon(c, SLOT3) else self.fmKeyoff(c, SLOT3);
                if (v & 0x80 != 0) self.fmKeyon(c, SLOT4) else self.fmKeyoff(c, SLOT4);
            },
            else => {},
        }
    }

    fn opnWriteReg(self: *Ym2612Sample, r: u16, v: u8) void {
        var c: usize = @intCast(r & 3);
        if (c == 3) return;
        if (r >= 0x100) c += 3;

        const slot_idx = opnSlot(r);

        switch (@as(u8, @truncate(r & 0xf0))) {
            0x30 => {
                // DET, MUL
                self.setDetMul(c, slot_idx, v);
            },
            0x40 => {
                // TL
                self.setTl(c, slot_idx, v);
            },
            0x50 => {
                // KS, AR
                self.setArKsr(c, slot_idx, v);
            },
            0x60 => {
                // AM ENABLE, DR
                self.setDr(c, slot_idx, v);
                self.ch[c].slot[slot_idx].am_mask = if (v & 0x80 != 0) 0xFFFFFFFF else 0;
            },
            0x70 => {
                // SR
                self.setSr(c, slot_idx, v);
            },
            0x80 => {
                // SL, RR
                self.setSlRr(c, slot_idx, v);
            },
            0x90 => {
                // SSG-EG
                const slot = &self.ch[c].slot[slot_idx];
                slot.ssg = v & 0x0f;
                if (slot.state > EG_REL) {
                    if ((slot.ssg & 0x08 != 0) and (slot.ssgn ^ (slot.ssg & 0x04) != 0))
                        slot.vol_out = (@as(u32, @intCast((0x200 - slot.volume) & MAX_ATT_INDEX))) + slot.tl
                    else
                        slot.vol_out = @as(u32, @intCast(slot.volume)) + slot.tl;
                }
            },
            0xa0 => {
                switch (opnSlot(r)) {
                    0 => {
                        // FNUM1
                        const fn_val: u32 = (@as(u32, self.fn_h & 7) << 8) | @as(u32, v);
                        const blk: u5 = @intCast(self.fn_h >> 3);
                        self.ch[c].kcode = (@as(u8, blk) << 2) | opn_fktable[fn_val >> 7];
                        self.ch[c].fc = (fn_val << blk) >> 1;
                        self.ch[c].block_fnum = (@as(u32, blk) << 11) | fn_val;
                        self.ch[c].slot[SLOT1].incr = -1;
                    },
                    1 => {
                        // FNUM2, BLK
                        self.fn_h = v & 0x3f;
                    },
                    2 => {
                        // 3CH FNUM1
                        if (r < 0x100) {
                            const fn_val: u32 = (@as(u32, self.sl3.fn_h & 7) << 8) | @as(u32, v);
                            const blk: u5 = @intCast(self.sl3.fn_h >> 3);
                            self.sl3.kcode[c] = (@as(u8, blk) << 2) | opn_fktable[fn_val >> 7];
                            self.sl3.fc[c] = (fn_val << blk) >> 1;
                            self.sl3.block_fnum[c] = (@as(u32, blk) << 11) | fn_val;
                            self.ch[2].slot[SLOT1].incr = -1;
                        }
                    },
                    3 => {
                        // 3CH FNUM2, BLK
                        if (r < 0x100)
                            self.sl3.fn_h = v & 0x3f;
                    },
                }
            },
            0xb0 => {
                switch (opnSlot(r)) {
                    0 => {
                        // FB, ALGO
                        self.ch[c].algo = v & 7;
                        self.ch[c].fb = @as(u8, SIN_BITS) - ((v >> 3) & 7);
                    },
                    1 => {
                        // L, R, AMS, PMS
                        self.ch[c].pms = @as(i32, v & 7) * 32;
                        self.ch[c].ams = lfo_ams_depth_shift[(v >> 4) & 0x03];
                        self.pan[c * 2] = if (v & 0x80 != 0) 0xFFFFFFFF else 0;
                        self.pan[c * 2 + 1] = if (v & 0x40 != 0) 0xFFFFFFFF else 0;
                    },
                    else => {},
                }
            },
            else => {},
        }
    }

    fn opnSlot(r: u16) u2 {
        return @intCast((r >> 2) & 3);
    }

    // --- Key on/off ---

    fn fmKeyon(self: *Ym2612Sample, ch_idx: usize, s: usize) void {
        const slot = &self.ch[ch_idx].slot[s];

        if (slot.key == 0 and self.sl3.key_csm == 0) {
            // Restart Phase Generator
            slot.phase = 0;
            slot.ssgn = 0;

            if ((slot.ar + slot.ksr) < 94) {
                slot.state = if (slot.volume <= MIN_ATT_INDEX)
                    (if (slot.sl == @as(u32, @intCast(MIN_ATT_INDEX))) EG_SUS else EG_DEC)
                else
                    EG_ATT;
            } else {
                slot.volume = MIN_ATT_INDEX;
                slot.state = if (slot.sl == @as(u32, @intCast(MIN_ATT_INDEX))) EG_SUS else EG_DEC;
            }

            // Recalculate EG output
            if ((slot.ssg & 0x08 != 0) and (slot.ssgn ^ (slot.ssg & 0x04) != 0))
                slot.vol_out = @as(u32, @intCast((0x200 - slot.volume) & MAX_ATT_INDEX)) + slot.tl
            else
                slot.vol_out = @as(u32, @intCast(slot.volume)) + slot.tl;
        }

        slot.key = 1;
    }

    fn fmKeyoff(self: *Ym2612Sample, ch_idx: usize, s: usize) void {
        const slot = &self.ch[ch_idx].slot[s];

        if (slot.key != 0 and self.sl3.key_csm == 0) {
            if (slot.state > EG_REL) {
                slot.state = EG_REL;

                // SSG-EG specific update
                if (slot.ssg & 0x08 != 0) {
                    if (slot.ssgn ^ (slot.ssg & 0x04) != 0)
                        slot.volume = (0x200 - slot.volume) & MAX_ATT_INDEX;

                    if (slot.volume >= 0x200) {
                        slot.volume = MAX_ATT_INDEX;
                        slot.state = EG_OFF;
                    }

                    slot.vol_out = @as(u32, @intCast(slot.volume)) + slot.tl;
                }
            }
        }

        slot.key = 0;
    }

    fn fmKeyonCsm(self: *Ym2612Sample, ch_idx: usize, s: usize) void {
        const slot = &self.ch[ch_idx].slot[s];

        if (slot.key == 0 and self.sl3.key_csm == 0) {
            slot.phase = 0;
            slot.ssgn = 0;

            if ((slot.ar + slot.ksr) < 94) {
                slot.state = if (slot.volume <= MIN_ATT_INDEX)
                    (if (slot.sl == @as(u32, @intCast(MIN_ATT_INDEX))) EG_SUS else EG_DEC)
                else
                    EG_ATT;
            } else {
                slot.volume = MIN_ATT_INDEX;
                slot.state = if (slot.sl == @as(u32, @intCast(MIN_ATT_INDEX))) EG_SUS else EG_DEC;
            }

            if ((slot.ssg & 0x08 != 0) and (slot.ssgn ^ (slot.ssg & 0x04) != 0))
                slot.vol_out = @as(u32, @intCast((0x200 - slot.volume) & MAX_ATT_INDEX)) + slot.tl
            else
                slot.vol_out = @as(u32, @intCast(slot.volume)) + slot.tl;
        }
    }

    fn fmKeyoffCsm(self: *Ym2612Sample, ch_idx: usize, s: usize) void {
        const slot = &self.ch[ch_idx].slot[s];
        if (slot.key == 0) {
            if (slot.state > EG_REL) {
                slot.state = EG_REL;

                if (slot.ssg & 0x08 != 0) {
                    if (slot.ssgn ^ (slot.ssg & 0x04) != 0)
                        slot.volume = (0x200 - slot.volume) & MAX_ATT_INDEX;

                    if (slot.volume >= 0x200) {
                        slot.volume = MAX_ATT_INDEX;
                        slot.state = EG_OFF;
                    }

                    slot.vol_out = @as(u32, @intCast(slot.volume)) + slot.tl;
                }
            }
        }
    }

    fn csmKeyControll(self: *Ym2612Sample) void {
        self.fmKeyonCsm(2, SLOT1);
        self.fmKeyonCsm(2, SLOT2);
        self.fmKeyonCsm(2, SLOT3);
        self.fmKeyonCsm(2, SLOT4);
        self.sl3.key_csm = 1;
    }

    // --- Timers ---

    fn internalTimerA(self: *Ym2612Sample) void {
        if (self.mode & 0x01 != 0) {
            self.tac -= 1;
            if (self.tac <= 0) {
                if (self.mode & 0x04 != 0)
                    self.status |= 0x01;
                self.tac = self.tal;
                if ((self.mode & 0xC0) == 0x80)
                    self.csmKeyControll();
            }
        }
    }

    fn internalTimerB(self: *Ym2612Sample, step: i32) void {
        if (self.mode & 0x02 != 0) {
            self.tbc -= step;
            if (self.tbc <= 0) {
                if (self.mode & 0x08 != 0)
                    self.status |= 0x02;
                while (self.tbc <= 0) {
                    self.tbc += self.tbl;
                }
            }
        }
    }

    fn setTimers(self: *Ym2612Sample, v: u8) void {
        if ((self.mode ^ v) & 0xC0 != 0) {
            self.ch[2].slot[SLOT1].incr = -1;

            if ((v & 0xC0) != 0x80 and self.sl3.key_csm != 0) {
                self.fmKeyoffCsm(2, SLOT1);
                self.fmKeyoffCsm(2, SLOT2);
                self.fmKeyoffCsm(2, SLOT3);
                self.fmKeyoffCsm(2, SLOT4);
                self.sl3.key_csm = 0;
            }
        }

        // Reload timers
        if ((v & 1 != 0) and (self.mode & 1 == 0))
            self.tac = self.tal;
        if ((v & 2 != 0) and (self.mode & 2 == 0))
            self.tbc = self.tbl;

        // Reset timer flags
        self.status &= ~(v >> 4);

        self.mode = v;
    }

    // --- Frequency/EG helpers ---

    fn setDetMul(self: *Ym2612Sample, ch_idx: usize, s: usize, v: u8) void {
        const slot = &self.ch[ch_idx].slot[s];
        slot.mul = ml_table[v & 0x0f];
        slot.dt_idx = @intCast((v >> 4) & 7);
        self.ch[ch_idx].slot[SLOT1].incr = -1;
    }

    fn setTl(self: *Ym2612Sample, ch_idx: usize, s: usize, v: u8) void {
        const slot = &self.ch[ch_idx].slot[s];
        slot.tl = @as(u32, v & 0x7f) << (ENV_BITS - 7);

        if ((slot.ssg & 0x08 != 0) and (slot.ssgn ^ (slot.ssg & 0x04) != 0) and (slot.state > EG_REL))
            slot.vol_out = @as(u32, @intCast((0x200 - slot.volume) & MAX_ATT_INDEX)) + slot.tl
        else
            slot.vol_out = @as(u32, @intCast(slot.volume)) + slot.tl;
    }

    fn setArKsr(self: *Ym2612Sample, ch_idx: usize, s: usize, v: u8) void {
        const slot = &self.ch[ch_idx].slot[s];
        const old_KSR = slot.KSR;

        slot.ar = if (v & 0x1f != 0) @as(u32, 32) + (@as(u32, v & 0x1f) << 1) else 0;
        slot.KSR = 3 - (v >> 6);

        if (slot.KSR != old_KSR) {
            self.ch[ch_idx].slot[SLOT1].incr = -1;
        }

        if ((slot.ar + slot.ksr) < 94) {
            slot.eg_sh_ar = eg_rate_shift[slot.ar + slot.ksr];
            slot.eg_sel_ar = eg_rate_select[slot.ar + slot.ksr];
        } else {
            slot.eg_sh_ar = 0;
            slot.eg_sel_ar = 18 * RATE_STEPS;
        }
    }

    fn setDr(self: *Ym2612Sample, ch_idx: usize, s: usize, v: u8) void {
        const slot = &self.ch[ch_idx].slot[s];
        slot.d1r = if (v & 0x1f != 0) @as(u32, 32) + (@as(u32, v & 0x1f) << 1) else 0;
        slot.eg_sh_d1r = eg_rate_shift[slot.d1r + slot.ksr];
        slot.eg_sel_d1r = eg_rate_select[slot.d1r + slot.ksr];
    }

    fn setSr(self: *Ym2612Sample, ch_idx: usize, s: usize, v: u8) void {
        const slot = &self.ch[ch_idx].slot[s];
        slot.d2r = if (v & 0x1f != 0) @as(u32, 32) + (@as(u32, v & 0x1f) << 1) else 0;
        slot.eg_sh_d2r = eg_rate_shift[slot.d2r + slot.ksr];
        slot.eg_sel_d2r = eg_rate_select[slot.d2r + slot.ksr];
    }

    fn setSlRr(self: *Ym2612Sample, ch_idx: usize, s: usize, v: u8) void {
        const slot = &self.ch[ch_idx].slot[s];
        slot.sl = sl_table[v >> 4];

        if ((slot.state == EG_DEC) and (slot.volume >= @as(i32, @intCast(slot.sl))))
            slot.state = EG_SUS;

        slot.rr = 34 + (@as(u32, v & 0x0f) << 2);
        slot.eg_sh_rr = eg_rate_shift[slot.rr + slot.ksr];
        slot.eg_sel_rr = eg_rate_select[slot.rr + slot.ksr];
    }

    // --- LFO ---

    fn advanceLfo(self: *Ym2612Sample) void {
        if (self.lfo_timer_overflow != 0) {
            self.lfo_timer += 1;
            if (self.lfo_timer >= self.lfo_timer_overflow) {
                self.lfo_timer = 0;
                self.lfo_cnt = (self.lfo_cnt +% 1) & 127;

                // Triangle (inverted)
                if (self.lfo_cnt < 64)
                    self.lfo_am = @as(u32, self.lfo_cnt ^ 63) << 1
                else
                    self.lfo_am = @as(u32, self.lfo_cnt & 63) << 1;

                // PM works with 4 times slower clock
                self.lfo_pm = self.lfo_cnt >> 2;
            }
        }
    }

    // --- Envelope generator ---

    fn advanceEgChannels(self: *Ym2612Sample) void {
        const eg_cnt = self.eg_cnt;
        for (0..6) |ch_i| {
            for (0..4) |s_i| {
                const slot = &self.ch[ch_i].slot[s_i];
                switch (slot.state) {
                    EG_ATT => {
                        if (eg_cnt & ((@as(u32, 1) << @intCast(slot.eg_sh_ar)) -% 1) == 0) {
                            slot.volume += (~slot.volume *| @as(i32, @intCast(eg_inc[slot.eg_sel_ar + ((eg_cnt >> @intCast(slot.eg_sh_ar)) & 7)]))) >> 4;

                            if (slot.volume <= MIN_ATT_INDEX) {
                                slot.volume = MIN_ATT_INDEX;
                                slot.state = if (slot.sl == @as(u32, @intCast(MIN_ATT_INDEX))) EG_SUS else EG_DEC;
                            }

                            if ((slot.ssg & 0x08 != 0) and (slot.ssgn ^ (slot.ssg & 0x04) != 0))
                                slot.vol_out = @as(u32, @intCast((0x200 - slot.volume) & MAX_ATT_INDEX)) + slot.tl
                            else
                                slot.vol_out = @as(u32, @intCast(slot.volume)) + slot.tl;
                        }
                    },
                    EG_DEC => {
                        if (eg_cnt & ((@as(u32, 1) << @intCast(slot.eg_sh_d1r)) -% 1) == 0) {
                            if (slot.ssg & 0x08 != 0) {
                                if (slot.volume < 0x200) {
                                    slot.volume += 4 * @as(i32, @intCast(eg_inc[slot.eg_sel_d1r + ((eg_cnt >> @intCast(slot.eg_sh_d1r)) & 7)]));
                                    if (slot.ssgn ^ (slot.ssg & 0x04) != 0)
                                        slot.vol_out = @as(u32, @intCast((0x200 - slot.volume) & MAX_ATT_INDEX)) + slot.tl
                                    else
                                        slot.vol_out = @as(u32, @intCast(slot.volume)) + slot.tl;
                                }
                            } else {
                                slot.volume += @intCast(eg_inc[slot.eg_sel_d1r + ((eg_cnt >> @intCast(slot.eg_sh_d1r)) & 7)]);
                                slot.vol_out = @as(u32, @intCast(slot.volume)) + slot.tl;
                            }

                            if (slot.volume >= @as(i32, @intCast(slot.sl)))
                                slot.state = EG_SUS;
                        }
                    },
                    EG_SUS => {
                        if (eg_cnt & ((@as(u32, 1) << @intCast(slot.eg_sh_d2r)) -% 1) == 0) {
                            if (slot.ssg & 0x08 != 0) {
                                if (slot.volume < 0x200) {
                                    slot.volume += 4 * @as(i32, @intCast(eg_inc[slot.eg_sel_d2r + ((eg_cnt >> @intCast(slot.eg_sh_d2r)) & 7)]));
                                    if (slot.ssgn ^ (slot.ssg & 0x04) != 0)
                                        slot.vol_out = @as(u32, @intCast((0x200 - slot.volume) & MAX_ATT_INDEX)) + slot.tl
                                    else
                                        slot.vol_out = @as(u32, @intCast(slot.volume)) + slot.tl;
                                }
                            } else {
                                slot.volume += @intCast(eg_inc[slot.eg_sel_d2r + ((eg_cnt >> @intCast(slot.eg_sh_d2r)) & 7)]);
                                if (slot.volume >= MAX_ATT_INDEX)
                                    slot.volume = MAX_ATT_INDEX;
                                slot.vol_out = @as(u32, @intCast(slot.volume)) + slot.tl;
                            }
                        }
                    },
                    EG_REL => {
                        if (eg_cnt & ((@as(u32, 1) << @intCast(slot.eg_sh_rr)) -% 1) == 0) {
                            if (slot.ssg & 0x08 != 0) {
                                if (slot.volume < 0x200)
                                    slot.volume += 4 * @as(i32, @intCast(eg_inc[slot.eg_sel_rr + ((eg_cnt >> @intCast(slot.eg_sh_rr)) & 7)]));
                                if (slot.volume >= 0x200) {
                                    slot.volume = MAX_ATT_INDEX;
                                    slot.state = EG_OFF;
                                }
                            } else {
                                slot.volume += @intCast(eg_inc[slot.eg_sel_rr + ((eg_cnt >> @intCast(slot.eg_sh_rr)) & 7)]);
                                if (slot.volume >= MAX_ATT_INDEX) {
                                    slot.volume = MAX_ATT_INDEX;
                                    slot.state = EG_OFF;
                                }
                            }
                            slot.vol_out = @as(u32, @intCast(slot.volume)) + slot.tl;
                        }
                    },
                    else => {}, // EG_OFF
                }
            }
        }
    }

    fn updateSsgEgChannels(self: *Ym2612Sample) void {
        for (0..6) |ch_i| {
            for (0..4) |s_i| {
                const slot = &self.ch[ch_i].slot[s_i];
                if ((slot.ssg & 0x08 != 0) and (slot.volume >= 0x200) and (slot.state > EG_REL)) {
                    if (slot.ssg & 0x01 != 0) {
                        // Hold
                        if (slot.ssg & 0x02 != 0)
                            slot.ssgn = 4;
                        if ((slot.state != EG_ATT) and (slot.ssgn ^ (slot.ssg & 0x04) == 0))
                            slot.volume = MAX_ATT_INDEX;
                    } else {
                        // Loop
                        if (slot.ssg & 0x02 != 0)
                            slot.ssgn ^= 4
                        else
                            slot.phase = 0;

                        if (slot.state != EG_ATT) {
                            if ((slot.ar + slot.ksr) < 94) {
                                slot.state = if (slot.volume <= MIN_ATT_INDEX)
                                    (if (slot.sl == @as(u32, @intCast(MIN_ATT_INDEX))) EG_SUS else EG_DEC)
                                else
                                    EG_ATT;
                            } else {
                                slot.volume = MIN_ATT_INDEX;
                                slot.state = if (slot.sl == @as(u32, @intCast(MIN_ATT_INDEX))) EG_SUS else EG_DEC;
                            }
                        }
                    }

                    if (slot.ssgn ^ (slot.ssg & 0x04) != 0)
                        slot.vol_out = @as(u32, @intCast((0x200 - slot.volume) & MAX_ATT_INDEX)) + slot.tl
                    else
                        slot.vol_out = @as(u32, @intCast(slot.volume)) + slot.tl;
                }
            }
        }
    }

    // --- Phase generator helpers ---

    fn updatePhaseLfoSlot(self: *Ym2612Sample, ch_idx: usize, s: usize, pm: u32, kc: u8, fc: u32) void {
        const slot = &self.ch[ch_idx].slot[s];
        const lfo_fn_offset = lfo_pm_table[((fc & 0x7f0) << 4) + pm];

        if (lfo_fn_offset != 0) {
            const blk: u5 = @intCast(fc >> 11);
            var fc_mod: u32 = ((fc << 1) +% @as(u32, @bitCast(lfo_fn_offset))) & 0xfff;
            fc_mod = (((fc_mod << blk) >> 2) +% @as(u32, @bitCast(self.dt_tab[slot.dt_idx][kc]))) & DT_MASK;
            slot.phase +%= (fc_mod * slot.mul) >> 1;
        } else {
            slot.phase +%= @bitCast(slot.incr);
        }
    }

    fn updatePhaseLfoChannel(self: *Ym2612Sample, ch_idx: usize) void {
        const ch = &self.ch[ch_idx];
        const fc = ch.block_fnum;
        const lfo_fn_offset = lfo_pm_table[((fc & 0x7f0) << 4) + @as(u32, @intCast(ch.pms)) + self.lfo_pm];

        if (lfo_fn_offset != 0) {
            const blk: u5 = @intCast(fc >> 11);
            const kc = ch.kcode;
            var fc_mod: u32 = ((fc << 1) +% @as(u32, @bitCast(lfo_fn_offset))) & 0xfff;
            fc_mod = (fc_mod << blk) >> 2;

            inline for ([_]usize{ SLOT1, SLOT2, SLOT3, SLOT4 }) |si| {
                const finc = (fc_mod +% @as(u32, @bitCast(self.dt_tab[ch.slot[si].dt_idx][kc]))) & DT_MASK;
                ch.slot[si].phase +%= (finc * ch.slot[si].mul) >> 1;
            }
        } else {
            inline for ([_]usize{ SLOT1, SLOT2, SLOT3, SLOT4 }) |si| {
                ch.slot[si].phase +%= @bitCast(ch.slot[si].incr);
            }
        }
    }

    fn refreshFcEgSlot(self: *Ym2612Sample, ch_idx: usize, s: usize, fc_in: u32, kc_in: u8) void {
        const slot = &self.ch[ch_idx].slot[s];

        // Add detune value and mask
        const fc = (fc_in +% @as(u32, @bitCast(self.dt_tab[slot.dt_idx][kc_in]))) & DT_MASK;
        slot.incr = @bitCast((fc * slot.mul) >> 1);

        // ksr
        const kc: u8 = kc_in >> @intCast(slot.KSR);
        if (slot.ksr != kc) {
            slot.ksr = kc;
            if ((slot.ar + kc) < 94) {
                slot.eg_sh_ar = eg_rate_shift[slot.ar + kc];
                slot.eg_sel_ar = eg_rate_select[slot.ar + kc];
            } else {
                slot.eg_sh_ar = 0;
                slot.eg_sel_ar = 18 * RATE_STEPS;
            }
            slot.eg_sh_d1r = eg_rate_shift[slot.d1r + kc];
            slot.eg_sel_d1r = eg_rate_select[slot.d1r + kc];
            slot.eg_sh_d2r = eg_rate_shift[slot.d2r + kc];
            slot.eg_sel_d2r = eg_rate_select[slot.d2r + kc];
            slot.eg_sh_rr = eg_rate_shift[slot.rr + kc];
            slot.eg_sel_rr = eg_rate_select[slot.rr + kc];
        }
    }

    fn refreshFcEgChan(self: *Ym2612Sample, ch_idx: usize) void {
        if (self.ch[ch_idx].slot[SLOT1].incr == -1) {
            const fc = self.ch[ch_idx].fc;
            const kc = self.ch[ch_idx].kcode;
            self.refreshFcEgSlot(ch_idx, SLOT1, fc, kc);
            self.refreshFcEgSlot(ch_idx, SLOT2, fc, kc);
            self.refreshFcEgSlot(ch_idx, SLOT3, fc, kc);
            self.refreshFcEgSlot(ch_idx, SLOT4, fc, kc);
        }
    }

    // --- Operator calculation ---

    fn opCalc(phase: u32, env: u32, pm: u32, opmask: u32) i32 {
        const p_idx = (env << 3) + sin_tab[((phase >> SIN_BITS) +% (pm >> 1)) & SIN_MASK];
        if (p_idx >= TL_TAB_LEN)
            return 0;
        return tl_tab[p_idx] & asI32(opmask);
    }

    fn opCalc1(phase: u32, env: u32, pm: u32, opmask: u32) i32 {
        const p_idx = (env << 3) + sin_tab[((phase >> SIN_BITS) +% pm) & SIN_MASK];
        if (p_idx >= TL_TAB_LEN)
            return 0;
        return tl_tab[p_idx] & asI32(opmask);
    }

    fn volumeCalc(slot: *const FmSlot, am: u32) u32 {
        return slot.vol_out + (am & slot.am_mask);
    }

    // --- Channel calculation (8 algorithms) ---

    fn chanCalcRange(self: *Ym2612Sample, start: usize, count: usize) void {
        for (start..start + count) |ch_i| {
            self.chanCalcOne(ch_i);
        }
    }

    fn chanCalcOne(self: *Ym2612Sample, ch_i: usize) void {
        const ch = &self.ch[ch_i];
        const am: u32 = self.lfo_am >> @intCast(ch.ams);
        const eg_out_s1 = volumeCalc(&ch.slot[SLOT1], am);
        const mask = self.op_mask[ch.algo];

        // Clear scratch registers
        self.scratch_m2 = 0;
        self.scratch_c1 = 0;
        self.scratch_c2 = 0;
        self.scratch_mem = 0;

        // Restore delayed sample (MEM) value
        const algo = ch.algo;
        // Where does mem_value go? Depends on algorithm.
        switch (algo) {
            0 => self.scratch_m2 = ch.mem_value, // memc = &m2
            1 => self.scratch_m2 = ch.mem_value, // memc = &m2
            2 => self.scratch_m2 = ch.mem_value, // memc = &m2
            3 => self.scratch_c2 = ch.mem_value, // memc = &c2
            4 => self.scratch_mem = ch.mem_value, // memc = &mem (not used)
            5 => self.scratch_m2 = ch.mem_value, // memc = &m2
            6 => self.scratch_mem = ch.mem_value, // memc = &mem (not used)
            7 => self.scratch_mem = ch.mem_value, // memc = &mem (not used)
            else => unreachable,
        }

        // SLOT 1 output
        var out: i32 = 0;
        if (eg_out_s1 < ENV_QUIET) {
            if (ch.fb < SIN_BITS)
                out = (ch.op1_out[0] + ch.op1_out[1]) >> @intCast(ch.fb);
            out = opCalc1(ch.slot[SLOT1].phase, eg_out_s1, @bitCast(out), mask[0]);
        }

        // Update op1_out feedback
        self.ch[ch_i].op1_out[0] = ch.op1_out[1];
        self.ch[ch_i].op1_out[1] = out;

        // Route SLOT1 output based on algorithm
        // algo 5: connect1 = null (special case: mem=c1=c2=out)
        // Other algos: connect1 points to c1, mem, or c2 or carrier
        switch (algo) {
            0 => self.scratch_c1 += out, // om1 = &c1
            1 => self.scratch_mem += out, // om1 = &mem
            2 => self.scratch_c2 += out, // om1 = &c2
            3 => self.scratch_c1 += out, // om1 = &c1
            4 => self.scratch_c1 += out, // om1 = &c1
            5 => {
                // algo 5 special: mem=c1=c2=out
                self.scratch_mem = out;
                self.scratch_c1 = out;
                self.scratch_c2 = out;
            },
            6 => self.scratch_c1 += out, // om1 = &c1
            7 => self.out_fm[ch_i] += out, // om1 = carrier
            else => unreachable,
        }

        // SLOT 3 output
        const eg_out_s3 = volumeCalc(&ch.slot[SLOT3], am);
        if (eg_out_s3 < ENV_QUIET) {
            // connect3 destination
            const s3out = opCalc(ch.slot[SLOT3].phase, eg_out_s3, @bitCast(self.scratch_m2), mask[2]);
            switch (algo) {
                0 => self.scratch_c2 += s3out, // om2 = &c2
                1 => self.scratch_c2 += s3out, // om2 = &c2
                2 => self.scratch_c2 += s3out, // om2 = &c2
                3 => self.scratch_c2 += s3out, // om2 = &c2
                4 => self.scratch_c2 += s3out, // om2 = &c2
                5 => self.out_fm[ch_i] += s3out, // om2 = carrier
                6 => self.out_fm[ch_i] += s3out, // om2 = carrier
                7 => self.out_fm[ch_i] += s3out, // om2 = carrier
                else => unreachable,
            }
        }

        // SLOT 2 output
        const eg_out_s2 = volumeCalc(&ch.slot[SLOT2], am);
        if (eg_out_s2 < ENV_QUIET) {
            // connect2 destination
            const s2out = opCalc(ch.slot[SLOT2].phase, eg_out_s2, @bitCast(self.scratch_c1), mask[1]);
            switch (algo) {
                0 => self.scratch_mem += s2out, // oc1 = &mem
                1 => self.scratch_mem += s2out, // oc1 = &mem
                2 => self.scratch_mem += s2out, // oc1 = &mem
                3 => self.scratch_mem += s2out, // oc1 = &mem
                4 => self.out_fm[ch_i] += s2out, // oc1 = carrier
                5 => self.out_fm[ch_i] += s2out, // oc1 = carrier
                6 => self.out_fm[ch_i] += s2out, // oc1 = carrier
                7 => self.out_fm[ch_i] += s2out, // oc1 = carrier
                else => unreachable,
            }
        }

        // SLOT 4 output (always goes to carrier)
        const eg_out_s4 = volumeCalc(&ch.slot[SLOT4], am);
        if (eg_out_s4 < ENV_QUIET) {
            self.out_fm[ch_i] += opCalc(ch.slot[SLOT4].phase, eg_out_s4, @bitCast(self.scratch_c2), mask[3]);
        }

        // Store current MEM
        self.ch[ch_i].mem_value = self.scratch_mem;

        // Update phase counters AFTER output calculations
        if (ch.pms != 0) {
            // 3-slot mode
            if ((self.mode & 0xC0 != 0) and (ch_i == 2)) {
                const kc = self.ch[2].kcode;
                const pm: u32 = @as(u32, @intCast(self.ch[2].pms)) + self.lfo_pm;
                self.updatePhaseLfoSlot(2, SLOT1, pm, kc, self.sl3.block_fnum[1]);
                self.updatePhaseLfoSlot(2, SLOT2, pm, kc, self.sl3.block_fnum[2]);
                self.updatePhaseLfoSlot(2, SLOT3, pm, kc, self.sl3.block_fnum[0]);
                self.updatePhaseLfoSlot(2, SLOT4, pm, kc, self.ch[2].block_fnum);
            } else {
                self.updatePhaseLfoChannel(ch_i);
            }
        } else {
            // No LFO phase modulation
            self.ch[ch_i].slot[SLOT1].phase +%= @bitCast(self.ch[ch_i].slot[SLOT1].incr);
            self.ch[ch_i].slot[SLOT2].phase +%= @bitCast(self.ch[ch_i].slot[SLOT2].incr);
            self.ch[ch_i].slot[SLOT3].phase +%= @bitCast(self.ch[ch_i].slot[SLOT3].incr);
            self.ch[ch_i].slot[SLOT4].phase +%= @bitCast(self.ch[ch_i].slot[SLOT4].incr);
        }
    }

    // --- Reset helpers ---

    fn resetChannels(self: *Ym2612Sample) void {
        for (&self.ch) |*ch| {
            ch.mem_value = 0;
            ch.op1_out = .{ 0, 0 };
            for (&ch.slot) |*slot| {
                slot.incr = -1;
                slot.key = 0;
                slot.phase = 0;
                slot.ssgn = 0;
                slot.state = EG_OFF;
                slot.volume = MAX_ATT_INDEX;
                slot.vol_out = @intCast(MAX_ATT_INDEX);
            }
        }
    }

    fn buildDetuneTables(self: *Ym2612Sample) void {
        for (0..4) |d| {
            for (0..32) |i| {
                self.dt_tab[d][i] = @as(i32, dt_tab[d * 32 + i]);
                self.dt_tab[d + 4][i] = -self.dt_tab[d][i];
            }
        }
    }

    fn buildDefaultOpMask(self: *Ym2612Sample) void {
        for (&self.op_mask) |*algo| {
            for (algo) |*mask| {
                mask.* = 0xFFFFFFFF;
            }
        }
    }

    // --- Utility ---

    fn asI32(v: u32) i32 {
        return @bitCast(v);
    }
};

// --- Unit Tests ---

test "ym2612 sample init produces valid state" {
    const ym = Ym2612Sample.init();
    try std.testing.expect(!ym.dacen);
    try std.testing.expectEqual(@as(i32, 0), ym.dacout);
    try std.testing.expectEqual(EG_OFF, ym.ch[0].slot[0].state);
}

test "ym2612 sample dac write sets dacout" {
    var ym = Ym2612Sample.init();
    ym.write(0, 0x2A); // address
    ym.write(1, 0xFF); // data
    try std.testing.expectEqual(@as(i32, (0xFF - 0x80) << 6), ym.dacout);
}

test "ym2612 sample dac enable toggle" {
    var ym = Ym2612Sample.init();
    ym.write(0, 0x2B);
    ym.write(1, 0x80);
    try std.testing.expect(ym.dacen);
    ym.write(0, 0x2B);
    ym.write(1, 0x00);
    try std.testing.expect(!ym.dacen);
}

test "ym2612 sample basic tone generation" {
    var ym = Ym2612Sample.init();

    // Set channel 0, slot 1: max attack, some frequency
    // Algorithm 0, feedback 7
    ym.write(0, 0xB0); // algo/fb register for CH0
    ym.write(1, 0x38); // FB=7, ALGO=0

    // Enable panning for CH0 (L+R)
    ym.write(0, 0xB4);
    ym.write(1, 0xC0);

    // Set DET/MUL for slot 1 of CH0
    ym.write(0, 0x30);
    ym.write(1, 0x01); // DT=0, MUL=1

    // Set TL (total level) for slot 1
    ym.write(0, 0x40);
    ym.write(1, 0x00); // TL=0 (max volume)

    // Set AR (attack rate) for slot 1
    ym.write(0, 0x50);
    ym.write(1, 0x1F); // KS=0, AR=31 (max)

    // Set DR for slot 1
    ym.write(0, 0x60);
    ym.write(1, 0x00); // DR=0

    // Set SR for slot 1
    ym.write(0, 0x70);
    ym.write(1, 0x00); // SR=0

    // Set SL/RR for slot 1
    ym.write(0, 0x80);
    ym.write(1, 0x0F); // SL=0, RR=15

    // Set all 4 slots similarly (SLOT4 is the carrier for algo 0)
    // SLOT2 (register offset +8)
    ym.write(0, 0x38);
    ym.write(1, 0x01);
    ym.write(0, 0x48);
    ym.write(1, 0x00);
    ym.write(0, 0x58);
    ym.write(1, 0x1F);
    ym.write(0, 0x68);
    ym.write(1, 0x00);
    ym.write(0, 0x78);
    ym.write(1, 0x00);
    ym.write(0, 0x88);
    ym.write(1, 0x0F);

    // SLOT3 (register offset +4)
    ym.write(0, 0x34);
    ym.write(1, 0x01);
    ym.write(0, 0x44);
    ym.write(1, 0x00);
    ym.write(0, 0x54);
    ym.write(1, 0x1F);
    ym.write(0, 0x64);
    ym.write(1, 0x00);
    ym.write(0, 0x74);
    ym.write(1, 0x00);
    ym.write(0, 0x84);
    ym.write(1, 0x0F);

    // SLOT4 (register offset +0xC)
    ym.write(0, 0x3C);
    ym.write(1, 0x01);
    ym.write(0, 0x4C);
    ym.write(1, 0x00);
    ym.write(0, 0x5C);
    ym.write(1, 0x1F);
    ym.write(0, 0x6C);
    ym.write(1, 0x00);
    ym.write(0, 0x7C);
    ym.write(1, 0x00);
    ym.write(0, 0x8C);
    ym.write(1, 0x0F);

    // Set frequency for CH0
    ym.write(0, 0xA4); // FNUM2/BLK
    ym.write(1, 0x22); // BLK=4, FNUM high bits
    ym.write(0, 0xA0); // FNUM1
    ym.write(1, 0x69); // FNUM low bits

    // Key ON all slots of CH0
    ym.write(0, 0x28);
    ym.write(1, 0xF0); // All slots on, CH0

    // Generate samples and check for non-zero output
    var found_nonzero = false;
    for (0..100) |_| {
        const sample = ym.update();
        if (sample[0] != 0 or sample[1] != 0) {
            found_nonzero = true;
            break;
        }
    }
    try std.testing.expect(found_nonzero);
}

test "ym2612 sample key on off state transitions" {
    var ym = Ym2612Sample.init();

    // Set up minimum config for channel 0
    ym.write(0, 0xB0);
    ym.write(1, 0x00); // algo=0, fb=0

    ym.write(0, 0xB4);
    ym.write(1, 0xC0); // L+R panning

    // Set AR to max for slot 1
    ym.write(0, 0x50);
    ym.write(1, 0x1F);

    // Set SL/RR
    ym.write(0, 0x80);
    ym.write(1, 0x0F);

    // Verify initial state is OFF
    try std.testing.expectEqual(EG_OFF, ym.ch[0].slot[SLOT1].state);
    try std.testing.expectEqual(@as(u8, 0), ym.ch[0].slot[SLOT1].key);

    // Key ON slot 1 of CH0
    ym.write(0, 0x28);
    ym.write(1, 0x10); // slot1 on, CH0

    // Key should now be 1
    try std.testing.expectEqual(@as(u8, 1), ym.ch[0].slot[SLOT1].key);
    // State should transition from OFF (volume was MAX, ar+ksr >= 94 for ar=31*2+32=94)
    // AR = 32 + (31 << 1) = 94, ksr starts at 0, so ar+ksr = 94 which is NOT < 94
    // So it should force volume to 0 and go to DEC or SUS
    try std.testing.expect(ym.ch[0].slot[SLOT1].state > EG_REL);

    // Key OFF
    ym.write(0, 0x28);
    ym.write(1, 0x00); // all slots off, CH0

    try std.testing.expectEqual(@as(u8, 0), ym.ch[0].slot[SLOT1].key);
    // After key off with non-SSG, state should be EG_REL (was > EG_REL)
    try std.testing.expectEqual(EG_REL, ym.ch[0].slot[SLOT1].state);
}

test "ym2612 sample tl_tab and sin_tab initialization" {
    // Ensure tables are initialized
    _ = Ym2612Sample.init();

    // tl_tab[0] should be a positive 13-bit value (max power)
    try std.testing.expect(tl_tab[0] > 0);
    try std.testing.expect(tl_tab[0] <= 8192); // 13-bit

    // tl_tab[1] should be negative of tl_tab[0]
    try std.testing.expectEqual(-tl_tab[0], tl_tab[1]);

    // sin_tab values should be reasonable (0 to ~ENV_QUIET range in index)
    try std.testing.expect(sin_tab[0] < TL_TAB_LEN);
    // sin at quarter (SIN_LEN/4) should have minimum value (loudest)
    try std.testing.expect(sin_tab[SIN_LEN / 4] < sin_tab[0]);
}

test "ym2612 sample config chip types" {
    var ym = Ym2612Sample.init();

    // Default discrete: carrier masks should have bottom 5 bits cleared
    ym.config(.discrete);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFE0), ym.op_mask[0][3]);

    // Enhanced: all masks should be 0xFFFFFFFF
    ym.config(.enhanced);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), ym.op_mask[0][3]);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), ym.op_mask[7][3]);
}
