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
    memory_control: u8 = 0,
    io_control: u8 = 0,

    pub const PsgCallback = struct {
        ctx: ?*anyopaque,
        write_fn: *const fn (ctx: ?*anyopaque, value: u8) void,
    };

    pub fn portIn(self: *SmsIo, port: u16) u8 {
        const p = @as(u8, @truncate(port));

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
            return self.vdp.readControl();
        }
        if (p & 0xC1 == 0xC0) {
            // 0xC0-0xFF even: I/O port A (controller 1)
            return self.input.readPortDC();
        }
        if (p & 0xC1 == 0xC1) {
            // 0xC0-0xFF odd: I/O port B (controller 2)
            return self.input.readPortDD();
        }

        return 0xFF;
    }

    pub fn portOut(self: *SmsIo, port: u16, value: u8) void {
        const p = @as(u8, @truncate(port));

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
