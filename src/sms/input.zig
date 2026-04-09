const std = @import("std");
const testing = std.testing;

/// SMS controller state for two players.
/// Port 0xDC returns player 1 buttons + player 2 up/down.
/// Port 0xDD returns player 2 left/right/buttons + reset/nationality.
pub const SmsInput = struct {
    // Button state: active low (0 = pressed, 1 = released)
    port1: Buttons = .{},
    port2: Buttons = .{},
    pause_pressed: bool = false,
    start_pressed: bool = false, // GG START button (read via port 0x00, not NMI)

    pub const Buttons = struct {
        up: bool = false,
        down: bool = false,
        left: bool = false,
        right: bool = false,
        button1: bool = false,
        button2: bool = false,
    };

    pub fn readPortDC(self: *const SmsInput) u8 {
        var value: u8 = 0xFF;
        if (self.port1.up) value &= ~@as(u8, 0x01);
        if (self.port1.down) value &= ~@as(u8, 0x02);
        if (self.port1.left) value &= ~@as(u8, 0x04);
        if (self.port1.right) value &= ~@as(u8, 0x08);
        if (self.port1.button1) value &= ~@as(u8, 0x10);
        if (self.port1.button2) value &= ~@as(u8, 0x20);
        // Bits 6-7: player 2 up/down
        if (self.port2.up) value &= ~@as(u8, 0x40);
        if (self.port2.down) value &= ~@as(u8, 0x80);
        return value;
    }

    pub fn readPortDD(self: *const SmsInput) u8 {
        var value: u8 = 0xFF;
        if (self.port2.left) value &= ~@as(u8, 0x01);
        if (self.port2.right) value &= ~@as(u8, 0x02);
        if (self.port2.button1) value &= ~@as(u8, 0x04);
        if (self.port2.button2) value &= ~@as(u8, 0x08);
        // Bit 4: reset button (active low, normally 1)
        // Bits 5-7: nationality / unused (leave high)
        return value;
    }

    pub fn setButton(self: *SmsInput, port: u1, button: Button, pressed: bool) void {
        switch (button) {
            .start => {
                self.start_pressed = pressed;
                return;
            },
            else => {},
        }
        const btns = if (port == 0) &self.port1 else &self.port2;
        switch (button) {
            .up => btns.up = pressed,
            .down => btns.down = pressed,
            .left => btns.left = pressed,
            .right => btns.right = pressed,
            .button1 => btns.button1 = pressed,
            .button2 => btns.button2 = pressed,
            .start => unreachable,
        }
    }

    pub const Button = enum { up, down, left, right, button1, button2, start };
};

test "sms input port DC all released" {
    const input = SmsInput{};
    try testing.expectEqual(@as(u8, 0xFF), input.readPortDC());
}

test "sms input port DC player 1 pressed" {
    var input = SmsInput{};
    input.setButton(0, .up, true);
    input.setButton(0, .button1, true);
    try testing.expectEqual(@as(u8, 0xFF & ~@as(u8, 0x01) & ~@as(u8, 0x10)), input.readPortDC());
}

test "sms input port DD player 2 left" {
    var input = SmsInput{};
    input.setButton(1, .left, true);
    try testing.expectEqual(@as(u8, 0xFE), input.readPortDD());
}
