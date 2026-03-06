const std = @import("std");
const testing = std.testing;

pub const Io = struct {
    const th_bit: u8 = 6;
    const th_high_delay_m68k_cycles: u32 = 30;
    const six_button_timeout_m68k_cycles: u32 = 12_150;

    data: [3]u8, // 0=A, 1=B, 2=C
    ctrl: [3]u8, // 0=A, 1=B, 2=C

    pad: [2]u16,
    th_flip_count: [2]u2,
    flip_reset_counter: [2]u32,
    cycles_until_th_high: [2]u32,
    controller_th: [2]bool,

    pub fn init() Io {
        return Io{
            .data = [_]u8{0} ** 3,
            .ctrl = [_]u8{0} ** 3,
            .pad = [_]u16{0xFFFF} ** 2,
            .th_flip_count = [_]u2{0} ** 2,
            .flip_reset_counter = [_]u32{0} ** 2,
            .cycles_until_th_high = [_]u32{0} ** 2,
            .controller_th = [_]bool{true} ** 2,
        };
    }

    pub fn read(self: *Io, address: u32) u8 {
        switch (address & 0xFF) {
            0x01 => return 0xA0, // Version: bit7=Overseas, bit5=No Mega-CD, bit6=0(NTSC)
            0x03 => return self.readData(0), // Port A data, low byte
            0x05 => return self.readData(1), // Port B data, low byte
            0x07 => return self.data[2], // Port C data, raw
            0x09 => return self.ctrl[0],
            0x0B => return self.ctrl[1],
            0x0D => return self.ctrl[2],
            else => return 0,
        }
    }

    pub fn write(self: *Io, address: u32, value: u8) void {
        switch (address & 0xFF) {
            0x03 => self.writeData(0, value),
            0x05 => self.writeData(1, value),
            0x07 => self.data[2] = value,
            0x09 => self.writeCtrl(0, value),
            0x0B => self.writeCtrl(1, value),
            0x0D => self.ctrl[2] = value,
            else => {},
        }
    }

    fn readData(self: *const Io, port: usize) u8 {
        var controller_byte: u8 = switch (self.controllerState(port)) {
            .th_high => @as(u8, @truncate(self.pad[port] & 0x3F)),
            .th_low_standard => @as(u8, @truncate(self.pad[port] & 0x03)) | buttonBit(self.pad[port], Button.A, 4) | buttonBit(self.pad[port], Button.Start, 5),
            .th_high_six_button => buttonBit(self.pad[port], Button.Z, 0) |
                buttonBit(self.pad[port], Button.Y, 1) |
                buttonBit(self.pad[port], Button.X, 2) |
                buttonBit(self.pad[port], Button.Mode, 3) |
                buttonBit(self.pad[port], Button.B, 4) |
                buttonBit(self.pad[port], Button.C, 5),
            .th_low_id_low => buttonBit(self.pad[port], Button.A, 4) | buttonBit(self.pad[port], Button.Start, 5),
            .th_low_id_high => buttonBit(self.pad[port], Button.A, 4) | buttonBit(self.pad[port], Button.Start, 5) | 0x0F,
        };
        controller_byte |= @as(u8, @intFromBool(self.controller_th[port])) << th_bit;
        controller_byte &= ~self.ctrl[port];

        const outputs_byte = self.data[port] & (self.ctrl[port] | 0x80);
        return controller_byte | outputs_byte;
    }

    fn buttonBit(pad: u16, button: u16, output_bit: u3) u8 {
        return @as(u8, @intFromBool((pad & button) != 0)) << output_bit;
    }

    const ControllerState = enum {
        th_high,
        th_low_standard,
        th_high_six_button,
        th_low_id_low,
        th_low_id_high,
    };

    fn controllerState(self: *const Io, port: usize) ControllerState {
        if (self.controller_th[port]) {
            return if (self.th_flip_count[port] == 3) .th_high_six_button else .th_high;
        }

        return switch (self.th_flip_count[port]) {
            0, 1 => .th_low_standard,
            2 => .th_low_id_low,
            3 => .th_low_id_high,
        };
    }

    fn writeCtrl(self: *Io, port: usize, value: u8) void {
        self.ctrl[port] = value;
        self.maybeSetTh(port);
        self.cycles_until_th_high[port] = if ((value & (1 << th_bit)) == 0) th_high_delay_m68k_cycles else 0;
    }

    fn writeData(self: *Io, port: usize, value: u8) void {
        self.data[port] = value;
        self.maybeSetTh(port);
    }

    fn maybeSetTh(self: *Io, port: usize) void {
        if ((self.ctrl[port] & (1 << th_bit)) == 0) {
            return;
        } else {
            const th = (self.data[port] & (1 << th_bit)) != 0;
            if (!self.controller_th[port] and th) {
                self.th_flip_count[port] +%= 1;
                self.flip_reset_counter[port] = six_button_timeout_m68k_cycles;
            }
            self.controller_th[port] = th;
        }
    }

    pub fn tick(self: *Io, m68k_cycles: u32) void {
        for (0..self.pad.len) |port| {
            self.flip_reset_counter[port] = self.flip_reset_counter[port] -| m68k_cycles;
            if (self.flip_reset_counter[port] == 0) {
                self.th_flip_count[port] = 0;
            }

            if (self.cycles_until_th_high[port] != 0) {
                self.cycles_until_th_high[port] = self.cycles_until_th_high[port] -| m68k_cycles;
                if (self.cycles_until_th_high[port] == 0) {
                    self.controller_th[port] = true;
                }
            }
        }
    }

    pub fn setButton(self: *Io, port: usize, button: u16, pressed: bool) void {
        if (pressed) {
            self.pad[port] &= ~button;
        } else {
            self.pad[port] |= button;
        }
    }

    // Button Constants
    pub const Button = struct {
        pub const Up: u16 = 1 << 0;
        pub const Down: u16 = 1 << 1;
        pub const Left: u16 = 1 << 2;
        pub const Right: u16 = 1 << 3;
        pub const B: u16 = 1 << 4;
        pub const C: u16 = 1 << 5;
        pub const A: u16 = 1 << 6;
        pub const Start: u16 = 1 << 7;
        pub const X: u16 = 1 << 8;
        pub const Y: u16 = 1 << 9;
        pub const Z: u16 = 1 << 10;
        pub const Mode: u16 = 1 << 11;
    };
};

test "controller TH input is pulled high after delay" {
    var io = Io.init();

    io.write(0x03, 0x00);
    io.write(0x09, 0x40);
    try testing.expectEqual(@as(u8, 0x03), io.read(0x03) & 0x43);

    io.write(0x09, 0x00);
    try testing.expectEqual(@as(u8, 0x03), io.read(0x03) & 0x43);

    io.tick(29);
    try testing.expectEqual(@as(u8, 0x03), io.read(0x03) & 0x43);

    io.tick(1);
    try testing.expectEqual(@as(u8, 0x43), io.read(0x03) & 0x43);
}

test "controller six-button state resets after timeout" {
    var io = Io.init();

    io.write(0x09, 0x40);
    io.setButton(0, Io.Button.Z, true);

    io.write(0x03, 0x00);
    io.write(0x03, 0x40);
    io.write(0x03, 0x00);
    io.write(0x03, 0x40);
    io.write(0x03, 0x00);
    io.write(0x03, 0x40);

    try testing.expectEqual(@as(u8, 0x7E), io.read(0x03));

    io.tick(12_149);
    try testing.expectEqual(@as(u8, 0x7E), io.read(0x03));

    io.tick(1);
    try testing.expectEqual(@as(u8, 0x7F), io.read(0x03));
}
