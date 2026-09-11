//! Sega CD gate array: the register file shared by the main CPU
//! (0xA12000-0xA1203F) and the sub CPU (0xFF8000-0xFF81FF).
//!
//! The same physical registers appear in both windows with different access
//! rights per side (e.g. command words are main-write/sub-read, status words
//! the reverse). This module owns the register state, the sub-CPU interrupt
//! mask/latch logic, the INT3 timer, the stopwatch, and the font renderer.
//! Word RAM ownership bits are forwarded to `WordRam`; CDC/CDD/PCM ports are
//! routed through `Peripherals` hooks once those devices exist.

const std = @import("std");
const Cpu = @import("../cpu/cpu.zig").Cpu;
const word_ram_mod = @import("word_ram.zig");
const WordRam = word_ram_mod.WordRam;
const scd_clock = @import("clock.zig");

/// Sub-CPU interrupt sources by 68000 level.
pub const IrqSource = enum(u3) {
    graphics = 1,
    main = 2,
    timer = 3,
    cdd = 4,
    cdc = 5,
    subcode = 6,

    pub fn level(self: IrqSource) u3 {
        return @intFromEnum(self);
    }
    pub fn bit(self: IrqSource) u8 {
        return @as(u8, 1) << self.level();
    }
};

/// Devices the register file must reach when a port is touched.
pub const Peripherals = struct {
    cpu: *Cpu,
    word_ram: *WordRam,
};

/// Side effects the board must act on after a main-side write.
pub const MainWriteEffects = struct {
    /// SRES went 0 -> 1: pull the sub CPU out of reset.
    sub_reset_released: bool = false,
    /// SRES went 1 -> 0: hold the sub CPU in reset.
    sub_reset_asserted: bool = false,
};

pub const GateArray = struct {
    // -- Reset / bus request (0x00) --
    /// SRES bit: false = sub CPU held in reset (power-on state).
    sub_running: bool = false,
    /// SBRQ bit: main CPU has requested the sub bus (sub halted).
    sub_bus_requested: bool = false,
    /// IFL2: INT2 requested by main and not yet delivered to the sub.
    ifl2: bool = false,
    leds: u2 = 0,

    // -- Memory mode (0x02) --
    write_protect: u8 = 0,
    prg_bank: u2 = 0,

    // -- CDC mode (0x04) --
    cdc_device_destination: u3 = 0,
    cdc_data_set_ready: bool = false,
    cdc_end_of_transfer: bool = false,
    cdc_register_address: u4 = 0,
    cdc_register_data: u8 = 0,
    /// 0x0A: DMA destination address in units of 8 bytes.
    cdc_dma_address: u16 = 0,

    // -- 0x06 --
    hint_vector: u16 = 0xFFFF,

    // -- 0x0C --
    stopwatch: u12 = 0,

    // -- 0x0E..0x2E --
    comm_flag_main: u8 = 0,
    comm_flag_sub: u8 = 0,
    command: [8]u16 = [_]u16{0} ** 8,
    status: [8]u16 = [_]u16{0} ** 8,

    // -- 0x30..0x36 --
    timer_reload: u8 = 0,
    timer_count: u8 = 0,
    /// Bits 1-6 enable INT1-INT6.
    irq_mask: u8 = 0,
    /// Sources latched while masked; re-requested when unmasked.
    irq_latched: u8 = 0,
    cd_fader: u16 = 0,
    cdd_control: u16 = 0,
    cdd_status: [10]u8 = [_]u8{0} ** 10,
    cdd_command: [10]u8 = [_]u8{0} ** 10,

    // -- Font (0x4C..0x56) --
    font_color: u8 = 0,
    font_bits: u16 = 0,

    // -- Graphics ASIC (0x58..0x66), stored raw until implemented --
    gfx_regs: [8]u16 = [_]u16{0} ** 8,

    // -- Subcode (0x68, 0x100..0x17F) --
    subcode_address: u16 = 0,
    subcode_buffer: [64]u16 = [_]u16{0} ** 64,

    /// Sub cycles accumulated toward the next 384-cycle tick.
    tick_accumulator: u32 = 0,

    pub fn reset(self: *GateArray) void {
        self.* = .{};
    }

    // -----------------------------------------------------------------------
    // Interrupts
    // -----------------------------------------------------------------------

    pub fn irqEnabled(self: *const GateArray, source: IrqSource) bool {
        return (self.irq_mask & source.bit()) != 0;
    }

    /// A source fired. Delivered at once if unmasked, else latched.
    pub fn raise(self: *GateArray, source: IrqSource, cpu: *Cpu) void {
        if (self.irqEnabled(source)) {
            cpu.requestInterrupt(source.level());
        } else {
            self.irq_latched |= source.bit();
        }
    }

    /// Sub CPU wrote the IRQ mask (0xFF8032).
    pub fn setIrqMask(self: *GateArray, mask: u8, cpu: *Cpu) void {
        const new_mask = mask & 0x7E;
        const enabled_now = new_mask & ~self.irq_mask;
        const disabled_now = self.irq_mask & ~new_mask;
        self.irq_mask = new_mask;

        var level: u3 = 1;
        while (level <= 6) : (level += 1) {
            const bit = @as(u8, 1) << level;
            if ((disabled_now & bit) != 0) {
                if (cpu.withdrawInterrupt(level)) self.irq_latched |= bit;
            }
            if ((enabled_now & bit) != 0 and (self.irq_latched & bit) != 0) {
                self.irq_latched &= ~bit;
                cpu.requestInterrupt(level);
            }
        }
        // Enabling INT2 delivers a pending IFL2 request.
        if ((enabled_now & IrqSource.main.bit()) != 0 and self.ifl2 and !cpu.isInterruptPending(2)) {
            cpu.requestInterrupt(2);
        }
    }

    /// Called from the sub burst loop so IFL2 reads back 0 once the sub
    /// CPU has taken the INT2.
    pub fn observeInterruptService(self: *GateArray, cpu: *const Cpu) void {
        if (self.ifl2 and self.irqEnabled(.main) and !cpu.isInterruptPending(2)) self.ifl2 = false;
    }

    // -----------------------------------------------------------------------
    // Timer / stopwatch (384 sub-cycle tick)
    // -----------------------------------------------------------------------

    /// Advance the 384-cycle tick domain by `sub_cycles`. Returns the
    /// number of ticks elapsed so PCM can be driven from the same clock.
    pub fn advanceSubCycles(self: *GateArray, sub_cycles: u32, cpu: *Cpu) u32 {
        self.tick_accumulator += sub_cycles;
        var ticks: u32 = 0;
        while (self.tick_accumulator >= scd_clock.timer_divider) {
            self.tick_accumulator -= scd_clock.timer_divider;
            ticks += 1;
            self.stopwatch +%= 1;
            if (self.timer_reload != 0) {
                if (self.timer_count == 0) {
                    self.timer_count = self.timer_reload;
                } else {
                    self.timer_count -= 1;
                    if (self.timer_count == 0) {
                        self.raise(.timer, cpu);
                        self.timer_count = self.timer_reload;
                    }
                }
            }
        }
        return ticks;
    }

    // -----------------------------------------------------------------------
    // Font renderer (0x4C..0x56)
    // -----------------------------------------------------------------------

    /// Font data word `index` (0-3) covers source bits 15-12, 11-8, 7-4, 3-0
    /// respectively; each set bit becomes the high color nibble, each clear
    /// bit the low color nibble.
    pub fn fontData(self: *const GateArray, index: u2) u16 {
        const shift: u4 = @intCast(12 - @as(u32, index) * 4);
        const nibble: u4 = @truncate(self.font_bits >> shift);
        const on: u16 = self.font_color >> 4;
        const off: u16 = self.font_color & 0x0F;
        var out: u16 = 0;
        var i: u2 = 0;
        while (true) : (i += 1) {
            const bit_set = (nibble >> (3 - i)) & 1 == 1;
            out = (out << 4) | (if (bit_set) on else off);
            if (i == 3) break;
        }
        return out;
    }

    // -----------------------------------------------------------------------
    // Shared register image (word offsets are the same on both sides)
    // -----------------------------------------------------------------------

    fn memoryModeWord(self: *const GateArray, wr: *const WordRam, sub_side: bool) u16 {
        var v: u16 = @as(u16, self.write_protect) << 8;
        v |= @as(u16, self.prg_bank) << 6;
        if (sub_side) v |= @as(u16, @intFromEnum(wr.priority)) << 3;
        v |= @as(u16, @intFromEnum(wr.mode)) << 2;
        v |= @as(u16, @intFromBool(wr.dmna)) << 1;
        v |= @intFromBool(wr.ret);
        return v;
    }

    fn cdcModeWord(self: *const GateArray) u16 {
        var v: u16 = @as(u16, self.cdc_device_destination) << 8;
        if (self.cdc_data_set_ready) v |= 0x4000;
        if (self.cdc_end_of_transfer) v |= 0x8000;
        return v | self.cdc_register_address;
    }

    // -----------------------------------------------------------------------
    // Main CPU side (offset within 0xA12000-0xA1203F)
    // -----------------------------------------------------------------------

    pub fn mainRead16(self: *const GateArray, offset: u8, wr: *const WordRam) u16 {
        return switch (offset & 0x3E) {
            0x00 => blk: {
                var v: u16 = 0;
                if (self.irqEnabled(.main)) v |= 0x8000;
                if (self.ifl2) v |= 0x0100;
                if (self.sub_bus_requested) v |= 0x0002;
                if (self.sub_running) v |= 0x0001;
                break :blk v;
            },
            0x02 => self.memoryModeWord(wr, false),
            0x04 => self.cdcModeWord() & 0xFF00,
            0x06 => self.hint_vector,
            0x08 => 0, // CDC host data: routed by the board when a CDC exists.
            0x0C => self.stopwatch,
            0x0E => (@as(u16, self.comm_flag_main) << 8) | self.comm_flag_sub,
            0x10, 0x12, 0x14, 0x16, 0x18, 0x1A, 0x1C, 0x1E => self.command[(offset - 0x10) >> 1],
            0x20, 0x22, 0x24, 0x26, 0x28, 0x2A, 0x2C, 0x2E => self.status[(offset - 0x20) >> 1],
            0x30 => self.timer_reload,
            0x32 => self.irq_mask,
            0x34 => self.cd_fader,
            0x36 => self.cdd_control,
            else => 0,
        };
    }

    pub fn mainRead8(self: *const GateArray, offset: u8, wr: *const WordRam) u8 {
        const word = self.mainRead16(offset & 0x3E, wr);
        return if ((offset & 1) == 0) @truncate(word >> 8) else @truncate(word);
    }

    /// `lanes`: bit 1 = high byte written, bit 0 = low byte written.
    pub fn mainWrite(self: *GateArray, offset: u8, value: u16, lanes: u2, p: Peripherals) MainWriteEffects {
        var effects = MainWriteEffects{};
        const hi = (lanes & 2) != 0;
        const lo = (lanes & 1) != 0;
        switch (offset & 0x3E) {
            0x00 => {
                if (hi and (value & 0x0100) != 0) {
                    self.ifl2 = true;
                    self.raise(.main, p.cpu);
                }
                if (lo) {
                    self.sub_bus_requested = (value & 0x0002) != 0;
                    const running = (value & 0x0001) != 0;
                    if (running and !self.sub_running) effects.sub_reset_released = true;
                    if (!running and self.sub_running) effects.sub_reset_asserted = true;
                    self.sub_running = running;
                }
            },
            0x02 => {
                if (hi) self.write_protect = @truncate(value >> 8);
                if (lo) {
                    self.prg_bank = @truncate((value >> 6) & 3);
                    if ((value & 0x0002) != 0) p.word_ram.mainRequestHandoff();
                }
            },
            0x04 => {
                if (hi) self.cdc_device_destination = @truncate((value >> 8) & 7);
            },
            0x06 => {
                var v = self.hint_vector;
                if (hi) v = (v & 0x00FF) | (value & 0xFF00);
                if (lo) v = (v & 0xFF00) | (value & 0x00FF);
                self.hint_vector = v;
            },
            0x0E => {
                if (hi) self.comm_flag_main = @truncate(value >> 8);
            },
            0x10, 0x12, 0x14, 0x16, 0x18, 0x1A, 0x1C, 0x1E => {
                const i = (offset - 0x10) >> 1;
                var v = self.command[i];
                if (hi) v = (v & 0x00FF) | (value & 0xFF00);
                if (lo) v = (v & 0xFF00) | (value & 0x00FF);
                self.command[i] = v;
            },
            else => {},
        }
        return effects;
    }

    // -----------------------------------------------------------------------
    // Sub CPU side (offset within 0xFF8000-0xFF81FF)
    // -----------------------------------------------------------------------

    pub fn subRead16(self: *const GateArray, offset: u16, wr: *const WordRam) u16 {
        const off = offset & 0x1FE;
        if (off >= 0x100) return self.subcode_buffer[(off - 0x100) >> 1];
        return switch (off) {
            0x00 => (@as(u16, self.leds) << 8) | @intFromBool(self.sub_running),
            0x02 => self.memoryModeWord(wr, true),
            0x04 => self.cdcModeWord(),
            0x06 => self.cdc_register_data,
            0x08 => 0, // CDC host data: routed by the board.
            0x0A => self.cdc_dma_address,
            0x0C => self.stopwatch,
            0x0E => (@as(u16, self.comm_flag_main) << 8) | self.comm_flag_sub,
            0x10, 0x12, 0x14, 0x16, 0x18, 0x1A, 0x1C, 0x1E => self.command[(off - 0x10) >> 1],
            0x20, 0x22, 0x24, 0x26, 0x28, 0x2A, 0x2C, 0x2E => self.status[(off - 0x20) >> 1],
            0x30 => self.timer_reload,
            0x32 => self.irq_mask,
            0x34 => self.cd_fader & 0x7FFF, // EFDT reads 0: fades complete instantly.
            0x36 => self.cdd_control,
            0x38, 0x3A, 0x3C, 0x3E, 0x40 => blk: {
                const i = (off - 0x38);
                break :blk (@as(u16, self.cdd_status[i] & 0x0F) << 8) | (self.cdd_status[i + 1] & 0x0F);
            },
            0x42, 0x44, 0x46, 0x48, 0x4A => blk: {
                const i = (off - 0x42);
                break :blk (@as(u16, self.cdd_command[i] & 0x0F) << 8) | (self.cdd_command[i + 1] & 0x0F);
            },
            0x4C => self.font_color,
            0x4E => self.font_bits,
            0x50, 0x52, 0x54, 0x56 => self.fontData(@intCast((off - 0x50) >> 1)),
            0x58, 0x5A, 0x5C, 0x5E, 0x60, 0x62, 0x64, 0x66 => self.gfx_regs[(off - 0x58) >> 1],
            0x68 => self.subcode_address,
            else => 0,
        };
    }

    pub fn subRead8(self: *const GateArray, offset: u16, wr: *const WordRam) u8 {
        const word = self.subRead16(offset & 0x1FE, wr);
        return if ((offset & 1) == 0) @truncate(word >> 8) else @truncate(word);
    }

    /// Returns true when the write completed a CDD command (all ten nibbles
    /// including the checksum at 0x4B), so the board can hand it to the CDD.
    pub fn subWrite(self: *GateArray, offset: u16, value: u16, lanes: u2, p: Peripherals) bool {
        const off = offset & 0x1FE;
        const hi = (lanes & 2) != 0;
        const lo = (lanes & 1) != 0;
        if (off >= 0x100) {
            return false; // Subcode buffer is read-only.
        }
        switch (off) {
            0x00 => {
                if (hi) self.leds = @truncate((value >> 8) & 3);
            },
            0x02 => {
                if (lo) {
                    p.word_ram.priority = @enumFromInt(@as(u2, @truncate((value >> 3) & 3)));
                    p.word_ram.subSetMode(@enumFromInt(@as(u1, @truncate((value >> 2) & 1))));
                    p.word_ram.subSetRet((value & 1) != 0);
                }
            },
            0x04 => {
                if (hi) self.cdc_device_destination = @truncate((value >> 8) & 7);
                if (lo) self.cdc_register_address = @truncate(value & 0x0F);
            },
            0x06 => {
                if (lo) self.cdc_register_data = @truncate(value);
            },
            0x0A => {
                var v = self.cdc_dma_address;
                if (hi) v = (v & 0x00FF) | (value & 0xFF00);
                if (lo) v = (v & 0xFF00) | (value & 0x00FF);
                self.cdc_dma_address = v;
            },
            0x0C => self.stopwatch = 0,
            0x0E => {
                if (lo) self.comm_flag_sub = @truncate(value);
            },
            0x20, 0x22, 0x24, 0x26, 0x28, 0x2A, 0x2C, 0x2E => {
                const i = (off - 0x20) >> 1;
                var v = self.status[i];
                if (hi) v = (v & 0x00FF) | (value & 0xFF00);
                if (lo) v = (v & 0xFF00) | (value & 0x00FF);
                self.status[i] = v;
            },
            0x30 => {
                if (lo) {
                    self.timer_reload = @truncate(value);
                    self.timer_count = self.timer_reload;
                }
            },
            0x32 => {
                if (lo) self.setIrqMask(@truncate(value), p.cpu);
            },
            0x34 => {
                var v = self.cd_fader;
                if (hi) v = (v & 0x00FF) | (value & 0xFF00);
                if (lo) v = (v & 0xFF00) | (value & 0x00FF);
                self.cd_fader = v & 0x7FFF;
            },
            0x36 => {
                if (lo) self.cdd_control = (self.cdd_control & 0xFF00) | (value & 0x0004);
            },
            0x42, 0x44, 0x46, 0x48, 0x4A => {
                const i = off - 0x42;
                if (hi) self.cdd_command[i] = @truncate((value >> 8) & 0x0F);
                if (lo) self.cdd_command[i + 1] = @truncate(value & 0x0F);
                return off == 0x4A and lo;
            },
            0x4C => {
                if (lo) self.font_color = @truncate(value);
            },
            0x4E => {
                var v = self.font_bits;
                if (hi) v = (v & 0x00FF) | (value & 0xFF00);
                if (lo) v = (v & 0xFF00) | (value & 0x00FF);
                self.font_bits = v;
            },
            0x58, 0x5A, 0x5C, 0x5E, 0x60, 0x62, 0x64, 0x66 => {
                const i = (off - 0x58) >> 1;
                var v = self.gfx_regs[i];
                if (hi) v = (v & 0x00FF) | (value & 0xFF00);
                if (lo) v = (v & 0xFF00) | (value & 0x00FF);
                self.gfx_regs[i] = v;
            },
            0x68 => {
                if (lo) self.subcode_address = value & 0x007E;
            },
            else => {},
        }
        return false;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const Fixture = struct {
    cpu: Cpu,
    wr: WordRam,
    ga: GateArray,

    fn init() Fixture {
        return .{ .cpu = Cpu.init(), .wr = .{}, .ga = .{} };
    }
    fn p(self: *Fixture) Peripherals {
        return .{ .cpu = &self.cpu, .word_ram = &self.wr };
    }
};

test "power-on state holds the sub CPU in reset and SRES edges are reported" {
    var f = Fixture.init();
    try testing.expectEqual(@as(u16, 0x0000), f.ga.mainRead16(0x00, &f.wr));

    const rel = f.ga.mainWrite(0x00, 0x0001, 0b01, f.p());
    try testing.expect(rel.sub_reset_released);
    try testing.expect(!rel.sub_reset_asserted);
    try testing.expect(f.ga.sub_running);
    try testing.expectEqual(@as(u16, 0x0001), f.ga.mainRead16(0x00, &f.wr));

    const same = f.ga.mainWrite(0x00, 0x0003, 0b01, f.p());
    try testing.expect(!same.sub_reset_released and !same.sub_reset_asserted);
    try testing.expect(f.ga.sub_bus_requested);
    try testing.expectEqual(@as(u8, 0x03), f.ga.mainRead8(0x01, &f.wr));

    const asserted = f.ga.mainWrite(0x00, 0x0002, 0b01, f.p());
    try testing.expect(asserted.sub_reset_asserted);
    try testing.expect(!f.ga.sub_running);
}

test "IFL2 raises INT2 when enabled and latches while masked" {
    var f = Fixture.init();
    // Masked: latched, visible in IFL2, not delivered.
    _ = f.ga.mainWrite(0x00, 0x0100, 0b10, f.p());
    try testing.expect(!f.cpu.isInterruptPending(2));
    try testing.expectEqual(@as(u16, 0x0100), f.ga.mainRead16(0x00, &f.wr) & 0x0100);

    // Sub enables INT2: delivered now, IEN2 visible to main.
    _ = f.ga.subWrite(0x32, 0x0004, 0b01, f.p());
    try testing.expect(f.cpu.isInterruptPending(2));
    try testing.expectEqual(@as(u16, 0x8000), f.ga.mainRead16(0x00, &f.wr) & 0x8000);

    // Once the CPU services it (simulated by clearing), IFL2 drops.
    f.cpu.clearInterrupt();
    f.ga.observeInterruptService(&f.cpu);
    try testing.expect(!f.ga.ifl2);
    try testing.expectEqual(@as(u16, 0), f.ga.mainRead16(0x00, &f.wr) & 0x0100);
}

test "irq mask withdraws asserted levels and re-requests latched ones" {
    var f = Fixture.init();
    _ = f.ga.subWrite(0x32, 0x0010, 0b01, f.p()); // enable INT4 only
    f.ga.raise(.cdd, &f.cpu);
    f.ga.raise(.cdc, &f.cpu); // masked -> latched
    try testing.expect(f.cpu.isInterruptPending(4));
    try testing.expect(!f.cpu.isInterruptPending(5));
    try testing.expectEqual(IrqSource.cdc.bit(), f.ga.irq_latched);

    // Mask INT4 before service: withdrawn from the CPU, kept latched.
    _ = f.ga.subWrite(0x32, 0x0020, 0b01, f.p()); // enable INT5 only
    try testing.expect(!f.cpu.isInterruptPending(4));
    try testing.expect(f.cpu.isInterruptPending(5));
    try testing.expectEqual(IrqSource.cdd.bit(), f.ga.irq_latched);

    // Re-enable INT4: the latched request comes back.
    _ = f.ga.subWrite(0x32, 0x0030, 0b01, f.p());
    try testing.expect(f.cpu.isInterruptPending(4));
    try testing.expectEqual(@as(u8, 0), f.ga.irq_latched);
    try testing.expectEqual(@as(u16, 0x30), f.ga.subRead16(0x32, &f.wr));
}

test "memory mode register: WP and bank from main, priority/mode/ret from sub" {
    var f = Fixture.init();
    _ = f.ga.mainWrite(0x02, 0x1A80, 0b11, f.p()); // WP=0x1A, BK=2
    try testing.expectEqual(@as(u8, 0x1A), f.ga.write_protect);
    try testing.expectEqual(@as(u2, 2), f.ga.prg_bank);
    // 2M, main owns: RET=1, DMNA=0
    try testing.expectEqual(@as(u16, 0x1A81), f.ga.mainRead16(0x02, &f.wr));

    // Main requests handoff.
    _ = f.ga.mainWrite(0x03, 0x0082, 0b01, f.p());
    try testing.expectEqual(@as(u16, 0x1A82), f.ga.mainRead16(0x02, &f.wr));
    try testing.expect(f.wr.subOwns2M());

    // Sub returns it and sets priority underwrite.
    _ = f.ga.subWrite(0x03, 0x0009, 0b01, f.p());
    try testing.expect(f.wr.mainOwns2M());
    try testing.expectEqual(word_ram_mod.PriorityMode.underwrite, f.wr.priority);
    try testing.expectEqual(@as(u16, 0x1A89), f.ga.subRead16(0x02, &f.wr));
    // Main never sees the priority bits.
    try testing.expectEqual(@as(u16, 0x1A81), f.ga.mainRead16(0x02, &f.wr));

    // Sub switches to 1M mode.
    _ = f.ga.subWrite(0x03, 0x0005, 0b01, f.p());
    try testing.expectEqual(word_ram_mod.Mode.one_m, f.wr.mode);
    try testing.expectEqual(@as(u16, 0x0004), f.ga.mainRead16(0x02, &f.wr) & 0x0004);
}

test "communication registers have one writer per side" {
    var f = Fixture.init();
    _ = f.ga.mainWrite(0x0E, 0xAB55, 0b11, f.p()); // only high byte lands
    _ = f.ga.subWrite(0x0E, 0x9933, 0b11, f.p()); // only low byte lands
    try testing.expectEqual(@as(u16, 0xAB33), f.ga.mainRead16(0x0E, &f.wr));
    try testing.expectEqual(@as(u16, 0xAB33), f.ga.subRead16(0x0E, &f.wr));

    _ = f.ga.mainWrite(0x10, 0x1234, 0b11, f.p());
    _ = f.ga.mainWrite(0x1F, 0x0077, 0b01, f.p()); // low byte of command 7
    _ = f.ga.subWrite(0x10, 0xFFFF, 0b11, f.p()); // sub cannot write commands
    try testing.expectEqual(@as(u16, 0x1234), f.ga.subRead16(0x10, &f.wr));
    try testing.expectEqual(@as(u16, 0x0077), f.ga.subRead16(0x1E, &f.wr));

    _ = f.ga.subWrite(0x20, 0xBEEF, 0b11, f.p());
    _ = f.ga.mainWrite(0x20, 0x0000, 0b11, f.p()); // main cannot write status
    try testing.expectEqual(@as(u16, 0xBEEF), f.ga.mainRead16(0x20, &f.wr));
    try testing.expectEqual(@as(u8, 0xEF), f.ga.mainRead8(0x21, &f.wr));
}

test "hint vector is main-writable per byte" {
    var f = Fixture.init();
    try testing.expectEqual(@as(u16, 0xFFFF), f.ga.mainRead16(0x06, &f.wr));
    _ = f.ga.mainWrite(0x06, 0xFD00, 0b11, f.p());
    try testing.expectEqual(@as(u16, 0xFD00), f.ga.hint_vector);
    _ = f.ga.mainWrite(0x07, 0x0042, 0b01, f.p());
    try testing.expectEqual(@as(u16, 0xFD42), f.ga.mainRead16(0x06, &f.wr));
}

test "timer fires INT3 every reload ticks of 384 sub cycles and stopwatch counts" {
    var f = Fixture.init();
    _ = f.ga.subWrite(0x32, 0x0008, 0b01, f.p()); // enable INT3
    _ = f.ga.subWrite(0x30, 0x0003, 0b01, f.p()); // reload = 3

    // 3 ticks = 1152 sub cycles -> one INT3.
    const ticks = f.ga.advanceSubCycles(3 * 384 - 1, &f.cpu);
    try testing.expectEqual(@as(u32, 2), ticks);
    try testing.expect(!f.cpu.isInterruptPending(3));
    _ = f.ga.advanceSubCycles(1, &f.cpu);
    try testing.expect(f.cpu.isInterruptPending(3));
    try testing.expectEqual(@as(u16, 3), f.ga.subRead16(0x0C, &f.wr));

    // Stopwatch reset by any sub write; timer 0 disables INT3.
    f.cpu.clearInterrupt();
    _ = f.ga.subWrite(0x0C, 0x1234, 0b11, f.p());
    try testing.expectEqual(@as(u16, 0), f.ga.mainRead16(0x0C, &f.wr));
    _ = f.ga.subWrite(0x30, 0x0000, 0b01, f.p());
    _ = f.ga.advanceSubCycles(384 * 50, &f.cpu);
    try testing.expect(!f.cpu.isInterruptPending(3));
    try testing.expectEqual(@as(u16, 50), f.ga.stopwatch);
}

test "font renderer expands 1bpp source bits into two-color nibbles" {
    var f = Fixture.init();
    _ = f.ga.subWrite(0x4C, 0x00F3, 0b01, f.p()); // on = 0xF, off = 0x3
    _ = f.ga.subWrite(0x4E, 0xA50F, 0b11, f.p());
    try testing.expectEqual(@as(u16, 0xF3F3), f.ga.subRead16(0x50, &f.wr)); // 1010
    try testing.expectEqual(@as(u16, 0x3F3F), f.ga.subRead16(0x52, &f.wr)); // 0101
    try testing.expectEqual(@as(u16, 0x3333), f.ga.subRead16(0x54, &f.wr)); // 0000
    try testing.expectEqual(@as(u16, 0xFFFF), f.ga.subRead16(0x56, &f.wr)); // 1111
}

test "cdd command completes on the checksum nibble write" {
    var f = Fixture.init();
    try testing.expect(!f.ga.subWrite(0x42, 0x0203, 0b11, f.p()));
    try testing.expect(!f.ga.subWrite(0x4A, 0x0100, 0b10, f.p()));
    try testing.expect(f.ga.subWrite(0x4A, 0x0107, 0b11, f.p()));
    try testing.expectEqual(@as(u8, 2), f.ga.cdd_command[0]);
    try testing.expectEqual(@as(u8, 3), f.ga.cdd_command[1]);
    try testing.expectEqual(@as(u8, 7), f.ga.cdd_command[9]);
    f.ga.cdd_status = .{ 0, 4, 0, 0, 0, 0, 0, 0, 0, 0xB };
    try testing.expectEqual(@as(u16, 0x0004), f.ga.subRead16(0x38, &f.wr));
    try testing.expectEqual(@as(u16, 0x000B), f.ga.subRead16(0x40, &f.wr));
}
