const std = @import("std");
const testing = std.testing;
const SmsVdp = @import("vdp.zig").SmsVdp;
const SmsInput = @import("input.zig").SmsInput;

/// SMS I/O port dispatch.
/// SMS uses partial address decoding: only bits 7, 6, and 0 of the port address
/// are significant for most peripherals.
pub const SmsIo = struct {
    vdp: *SmsVdp,
    input: *SmsInput,
    psg_callback: ?PsgCallback = null,
    psg_stereo_callback: ?PsgCallback = null, // GG port 0x06 stereo panning
    irq_clear_callback: ?IrqClearCallback = null,
    memory_control: u8 = 0,
    io_control: u8 = 0,
    is_game_gear: bool = false,
    gg_regs: [7]u8 = .{ 0xC0, 0x7F, 0xFF, 0x00, 0xFF, 0x00, 0xFF },

    pub const PsgCallback = struct {
        ctx: ?*anyopaque,
        write_fn: *const fn (ctx: ?*anyopaque, value: u8) void,
    };

    pub const IrqClearCallback = struct {
        ctx: ?*anyopaque,
        clear_fn: *const fn (ctx: ?*anyopaque) void,
    };

    pub fn portIn(self: *SmsIo, port: u16) u8 {
        const p = @as(u8, @truncate(port));

        // GG-specific ports 0x00-0x06
        if (self.is_game_gear and p < 0x07) {
            if (p == 0x00) {
                // Port 0x00: START button in bit 7 (active low)
                return if (self.input.start_pressed)
                    self.gg_regs[0] & ~@as(u8, 0x80)
                else
                    self.gg_regs[0];
            }
            return self.gg_regs[p];
        }

        // Partial decoding: check bit patterns
        if (p & 0xC1 == 0x40) {
            // 0x40-0x7F even: V counter
            return self.vdp.readVCounter();
        }
        if (p & 0xC1 == 0x41) {
            // 0x40-0x7F odd: H counter (stub: return 0)
            return 0;
        }
        if (p & 0xC1 == 0x80) {
            // 0x80-0xBF even: VDP data port
            return self.vdp.readData();
        }
        if (p & 0xC1 == 0x81) {
            // 0x80-0xBF odd: VDP control/status
            const result = self.vdp.readControl();
            // Reading VDP status clears interrupt flags. Immediately de-assert
            // the Z80 IRQ line to prevent spurious re-trigger before the next
            // scanline boundary IRQ update.
            if (self.irq_clear_callback) |cb| {
                cb.clear_fn(cb.ctx);
            }
            return result;
        }
        if (p & 0xC1 == 0xC0) {
            // 0xC0-0xFF even: I/O port A (controller 1)
            return self.input.readPortDC();
        }
        if (p & 0xC1 == 0xC1) {
            // 0xC0-0xFF odd: I/O port B (controller 2 + TH pins)
            var data = self.input.readPortDD();

            // Bits 6-7 reflect TH pin state from I/O control register.
            // I/O control register (port 0x3F):
            //   Bit 1: Port A TH direction (1=input, 0=output)
            //   Bit 3: Port B TH direction (1=input, 0=output)
            //   Bit 5: Port A TH output level
            //   Bit 7: Port B TH output level
            const ctrl = self.io_control;

            // Port A TH → bit 6 of port DD
            if ((ctrl & 0x02) == 0) {
                // TH-A is output: return output level (bit 5 → bit 6)
                data = (data & ~@as(u8, 0x40)) | ((ctrl & 0x20) << 1);
            }
            // else: TH-A is input → leave as 1 (export SMS pull-up, already set)

            // Port B TH → bit 7 of port DD
            if ((ctrl & 0x08) == 0) {
                // TH-B is output: return output level (bit 7)
                data = (data & ~@as(u8, 0x80)) | (ctrl & 0x80);
            }
            // else: TH-B is input → leave as 1 (export SMS pull-up, already set)

            return data;
        }

        return 0xFF;
    }

    pub fn portOut(self: *SmsIo, port: u16, value: u8) void {
        const p = @as(u8, @truncate(port));

        // GG-specific ports 0x00-0x06 (serial, stereo, etc.)
        if (self.is_game_gear and p < 0x07) {
            self.gg_regs[p] = value;
            if (p == 0x06) {
                // Port 0x06: PSG stereo panning
                if (self.psg_stereo_callback) |cb| {
                    cb.write_fn(cb.ctx, value);
                }
            }
            return;
        }

        if (p & 0xC1 == 0x00) {
            // 0x00-0x3F even: Memory control
            self.memory_control = value;
            return;
        }
        if (p & 0xC1 == 0x01) {
            // 0x00-0x3F odd: I/O port control
            self.io_control = value;
            return;
        }
        if (p & 0xC1 == 0x40 or p & 0xC1 == 0x41) {
            // 0x40-0x7F: PSG (SN76489)
            if (self.psg_callback) |cb| {
                cb.write_fn(cb.ctx, value);
            }
            return;
        }
        if (p & 0xC1 == 0x80) {
            // 0x80-0xBF even: VDP data port
            self.vdp.writeData(value);
            return;
        }
        if (p & 0xC1 == 0x81) {
            // 0x80-0xBF odd: VDP control port
            self.vdp.writeControl(value);
            return;
        }
    }
};

test "sms io port dispatch vdp status read" {
    var vdp = SmsVdp.init();
    var input = SmsInput{};
    vdp.status = 0x80; // VInt flag set
    var io = SmsIo{ .vdp = &vdp, .input = &input };
    // Reading port 0xBF should return VDP status
    const status = io.portIn(0xBF);
    try testing.expectEqual(@as(u8, 0x80), status);
    // Status should be cleared after read
    try testing.expectEqual(@as(u8, 0), vdp.status);
}

test "sms io port dispatch controller read" {
    var vdp = SmsVdp.init();
    var input = SmsInput{};
    input.setButton(0, .up, true);
    var io = SmsIo{ .vdp = &vdp, .input = &input };
    const dc = io.portIn(0xDC);
    try testing.expectEqual(@as(u8, 0xFE), dc); // Up pressed = bit 0 clear
}

test "sms io port DD reflects TH output from io control register" {
    var vdp = SmsVdp.init();
    var input = SmsInput{};
    var io = SmsIo{ .vdp = &vdp, .input = &input };

    // Default: io_control = 0, TH direction = output (bit 1=0, bit 3=0),
    // TH level = low (bit 5=0, bit 7=0)
    // Port DD bits 6-7 should reflect TH output levels = 0
    io.io_control = 0x00; // All outputs, all low
    const dd_low = io.portIn(0xDD);
    try testing.expectEqual(@as(u8, 0), dd_low & 0xC0); // bits 6-7 should be 0

    // Set TH-A and TH-B output high: bit 5=1 (TH-A level), bit 7=1 (TH-B level)
    // Direction still output: bit 1=0, bit 3=0
    io.io_control = 0xA0; // TH-A=high (bit5), TH-B=high (bit7), direction=output
    const dd_high = io.portIn(0xDD);
    try testing.expectEqual(@as(u8, 0xC0), dd_high & 0xC0); // bits 6-7 should be 1

    // Set TH as input (bit 1=1, bit 3=1): should return 1 (export SMS pull-up)
    io.io_control = 0x0A; // TH-A direction=input (bit1), TH-B direction=input (bit3)
    const dd_input = io.portIn(0xDD);
    try testing.expectEqual(@as(u8, 0xC0), dd_input & 0xC0); // bits 6-7 = 1 (pull-up)
}

test "sms io nationality detection pattern" {
    // Simulate what SMS games do for region detection.
    // I/O control register (port 0x3F) bit encoding:
    //   Bit 1: Port A TH direction (1=input, 0=output)
    //   Bit 3: Port B TH direction (1=input, 0=output)
    //   Bit 5: Port A TH output level
    //   Bit 7: Port B TH output level
    var vdp = SmsVdp.init();
    var input = SmsInput{};
    var io = SmsIo{ .vdp = &vdp, .input = &input };

    // Step 1: Write 0x55: TH-A/TH-B as OUTPUT (bits 1,3=0), levels LOW (bits 5,7=0)
    // 0x55 = 0101_0101: bit1=0(TH-A out), bit3=0(TH-B out), bit5=0(low), bit7=0(low)
    io.portOut(0x3F, 0x55);
    const dd1 = io.portIn(0xDD);
    // TH is output with level low → bits 6-7 = 0
    try testing.expectEqual(@as(u8, 0x00), dd1 & 0xC0);

    // Step 2: Write 0xAA: TH-A/TH-B as INPUT (bits 1,3=1)
    // 0xAA = 1010_1010: bit1=1(TH-A in), bit3=1(TH-B in)
    io.portOut(0x3F, 0xAA);
    const dd2 = io.portIn(0xDD);
    // TH is input → export SMS returns 1 (pull-up)
    try testing.expectEqual(@as(u8, 0xC0), dd2 & 0xC0);

    // Export detection: dd1 != dd2 (0x00 vs 0xC0) → export console confirmed
    try testing.expect((dd1 & 0xC0) != (dd2 & 0xC0));

    // Step 3: TH output high
    // bit1=0(TH-A out), bit3=0(TH-B out), bit5=1(high), bit7=1(high)
    io.portOut(0x3F, 0xA0);
    const dd3 = io.portIn(0xDD);
    try testing.expectEqual(@as(u8, 0xC0), dd3 & 0xC0);
}

test "gg io port 0x00 start button" {
    var vdp = SmsVdp.init();
    var input = SmsInput{};
    var io = SmsIo{ .vdp = &vdp, .input = &input, .is_game_gear = true };
    // START not pressed: bit 7 = 1
    const val1 = io.portIn(0x00);
    try testing.expect((val1 & 0x80) != 0);
    // START pressed: bit 7 = 0
    input.start_pressed = true;
    const val2 = io.portIn(0x00);
    try testing.expectEqual(@as(u8, 0), val2 & 0x80);
}

test "gg io port 0x06 stereo write" {
    var vdp = SmsVdp.init();
    var input = SmsInput{};
    var io = SmsIo{ .vdp = &vdp, .input = &input, .is_game_gear = true };
    io.portOut(0x06, 0x55);
    try testing.expectEqual(@as(u8, 0x55), io.gg_regs[6]);
}
