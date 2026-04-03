const std = @import("std");
const testing = std.testing;

pub const Io = struct {
    const th_bit: u8 = 6;
    const th_high_delay_m68k_cycles: u32 = 30;
    const six_button_timeout_m68k_cycles: u32 = 12_150;

    pub const ControllerType = enum {
        three_button,
        six_button,
        ea_4way_play,
        sega_mouse,
    };

    data: [3]u8,
    ctrl: [3]u8,
    tx_data: [3]u8,
    serial_ctrl: [3]u8,

    pad: [4]u16,
    th_flip_count: [2]u2,
    flip_reset_counter: [2]u32,
    cycles_until_th_high: [2]u32,
    controller_th: [2]bool,
    controller_types: [2]ControllerType,
    version_is_overseas: bool,
    mouse_phase: [2]u3,
    mouse_cycle_active: [2]bool,
    mouse_buttons: [2]u4,
    mouse_dx: [2]u8,
    mouse_dy: [2]u8,
    mouse_sign_x: [2]u1,
    mouse_sign_y: [2]u1,

    pub fn init() Io {
        return Io{
            .data = [_]u8{0} ** 3,
            .ctrl = [_]u8{0} ** 3,
            .tx_data = .{ 0xFF, 0xFF, 0xFB },
            .serial_ctrl = [_]u8{0} ** 3,
            .pad = [_]u16{0xFFFF} ** 4,
            .th_flip_count = [_]u2{0} ** 2,
            .flip_reset_counter = [_]u32{0} ** 2,
            .cycles_until_th_high = [_]u32{0} ** 2,
            .controller_th = [_]bool{true} ** 2,
            .controller_types = [_]ControllerType{.six_button} ** 2,
            .version_is_overseas = true,
            .mouse_phase = [_]u3{7} ** 2,
            .mouse_cycle_active = [_]bool{false} ** 2,
            .mouse_buttons = [_]u4{0} ** 2,
            .mouse_dx = [_]u8{0} ** 2,
            .mouse_dy = [_]u8{0} ** 2,
            .mouse_sign_x = [_]u1{0} ** 2,
            .mouse_sign_y = [_]u1{0} ** 2,
        };
    }

    pub fn read(self: *Io, address: u32) u8 {
        switch (address & 0xFF) {
            0x01 => return self.readVersionRegister(false),
            0x03 => return self.readData(0),
            0x05 => return self.readData(1),
            0x07 => return self.data[2],
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

    pub fn readVersionRegister(self: *const Io, pal_mode: bool) u8 {
        var value: u8 = 0x20;
        if (self.version_is_overseas) value |= 0x80;
        if (pal_mode) value |= 0x40;
        return value;
    }

    pub fn readTxData(self: *const Io, port: usize) u8 {
        return self.tx_data[port];
    }

    pub fn readRxData(_: *const Io, _: usize) u8 {
        return 0;
    }

    pub fn readSerialControl(self: *const Io, port: usize) u8 {
        return self.serial_ctrl[port];
    }

    pub fn writeTxData(self: *Io, port: usize, value: u8) void {
        self.tx_data[port] = value;
    }

    pub fn writeSerialControl(self: *Io, port: usize, value: u8) void {
        self.serial_ctrl[port] = value & 0xF8;
    }

    pub fn versionIsOverseas(self: *const Io) bool {
        return self.version_is_overseas;
    }

    pub fn setVersionIsOverseas(self: *Io, overseas: bool) void {
        self.version_is_overseas = overseas;
    }

    pub fn resetForHardware(self: *Io) void {
        const pad = self.pad;
        const controller_types = self.controller_types;
        const version_is_overseas = self.version_is_overseas;

        self.* = Io.init();
        self.pad = pad;
        self.controller_types = controller_types;
        self.version_is_overseas = version_is_overseas;
    }

    fn effectivePadIndex(self: *const Io, port: usize) usize {
        // EA 4-Way Play: TH on port 2 selects between players
        // TH high: port 0 → pad 0 (player A), port 1 → pad 1 (player B)
        // TH low:  port 0 → pad 2 (player C), port 1 → pad 3 (player D)
        if (self.controller_types[0] == .ea_4way_play or self.controller_types[1] == .ea_4way_play) {
            const offset: usize = if (self.controller_th[1]) 0 else 2;
            return port + offset;
        }
        return port;
    }

    fn readData(self: *const Io, port: usize) u8 {
        if (self.controller_types[port] == .sega_mouse) {
            return self.readMouseData(port);
        }

        const pad_idx = self.effectivePadIndex(port);
        var controller_byte: u8 = switch (self.controllerState(port)) {
            .th_high => @as(u8, @truncate(self.pad[pad_idx] & 0x3F)),
            .th_low_standard => @as(u8, @truncate(self.pad[pad_idx] & 0x03)) | buttonBit(self.pad[pad_idx], Button.A, 4) | buttonBit(self.pad[pad_idx], Button.Start, 5),
            .th_high_six_button => buttonBit(self.pad[pad_idx], Button.Z, 0) |
                buttonBit(self.pad[pad_idx], Button.Y, 1) |
                buttonBit(self.pad[pad_idx], Button.X, 2) |
                buttonBit(self.pad[pad_idx], Button.Mode, 3) |
                buttonBit(self.pad[pad_idx], Button.B, 4) |
                buttonBit(self.pad[pad_idx], Button.C, 5),
            .th_low_id_low => buttonBit(self.pad[pad_idx], Button.A, 4) | buttonBit(self.pad[pad_idx], Button.Start, 5),
            .th_low_id_high => buttonBit(self.pad[pad_idx], Button.A, 4) | buttonBit(self.pad[pad_idx], Button.Start, 5) | 0x0F,
        };
        controller_byte |= @as(u8, @intFromBool(self.controller_th[port])) << th_bit;
        controller_byte &= ~self.ctrl[port];

        const outputs_byte = self.data[port] & (self.ctrl[port] | 0x80);
        return controller_byte | outputs_byte;
    }

    fn readMouseData(self: *const Io, port: usize) u8 {
        // Sega Mouse protocol: 8 nibbles read via TH toggling.
        // Phase 0 (TH high): 0x0 (ID high)
        // Phase 1 (TH low):  0xB (ID low)
        // Phase 2 (TH high): YO, XO, YS, XS (overflow/sign)
        // Phase 3 (TH low):  Start, Middle, Right, Left (buttons)
        // Phase 4 (TH high): X delta high nibble
        // Phase 5 (TH low):  X delta low nibble
        // Phase 6 (TH high): Y delta high nibble
        // Phase 7 (TH low):  Y delta low nibble
        const nibble: u8 = switch (self.mouse_phase[port]) {
            0 => 0x00,
            1 => 0x0B,
            2 => (@as(u8, self.mouse_sign_y[port]) << 1) | @as(u8, self.mouse_sign_x[port]),
            3 => self.mouse_buttons[port],
            4 => (self.mouse_dx[port] >> 4) & 0x0F,
            5 => self.mouse_dx[port] & 0x0F,
            6 => (self.mouse_dy[port] >> 4) & 0x0F,
            7 => self.mouse_dy[port] & 0x0F,
        };
        const th_bit_val = @as(u8, @intFromBool(self.controller_th[port])) << th_bit;
        return nibble | th_bit_val;
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
        if (self.controller_types[port] == .three_button) {
            return if (self.controller_th[port]) .th_high else .th_low_standard;
        }

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
        self.maybeSetTh(port, false);
        self.cycles_until_th_high[port] = if ((value & (1 << th_bit)) == 0) th_high_delay_m68k_cycles else 0;
    }

    fn writeData(self: *Io, port: usize, value: u8) void {
        self.data[port] = value;
        self.maybeSetTh(port, true);
    }

    fn maybeSetTh(self: *Io, port: usize, from_data_write: bool) void {
        if ((self.ctrl[port] & (1 << th_bit)) == 0) {
            return;
        } else {
            const th = (self.data[port] & (1 << th_bit)) != 0;
            if (self.controller_th[port] != th) {
                // Advance the mouse read phase only on data-port TH transitions,
                // not on CTRL register configuration changes.
                if (from_data_write and self.controller_types[port] == .sega_mouse) {
                    self.advanceMousePhase(port);
                }
                if (!self.controller_th[port] and th) {
                    self.th_flip_count[port] +%= 1;
                    self.flip_reset_counter[port] = six_button_timeout_m68k_cycles;
                }
            }
            self.controller_th[port] = th;
        }
    }

    fn advanceMousePhase(self: *Io, port: usize) void {
        if (self.mouse_phase[port] == 7) {
            // Completed a full read cycle; consume deltas and reset phase.
            // Only clear deltas if we actually went through a complete protocol
            // cycle (not the initial power-on state where phase starts at 7).
            if (self.mouse_cycle_active[port]) {
                self.mouse_dx[port] = 0;
                self.mouse_dy[port] = 0;
                self.mouse_sign_x[port] = 0;
                self.mouse_sign_y[port] = 0;
            }
            self.mouse_cycle_active[port] = true;
            self.mouse_phase[port] = 0;
        } else {
            self.mouse_phase[port] +%= 1;
        }
    }

    pub fn tick(self: *Io, m68k_cycles: u32) void {
        for (0..2) |port| {
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
        if (port >= self.pad.len) return;
        if (pressed) {
            self.pad[port] &= ~button;
        } else {
            self.pad[port] |= button;
        }
    }

    pub fn setControllerType(self: *Io, port: usize, controller_type: ControllerType) void {
        self.controller_types[port] = controller_type;
    }

    pub fn getControllerType(self: *const Io, port: usize) ControllerType {
        return self.controller_types[port];
    }

    pub const MouseButton = struct {
        pub const left: u4 = 1 << 0;
        pub const right: u4 = 1 << 1;
        pub const middle: u4 = 1 << 2;
        pub const start: u4 = 1 << 3;
    };

    pub fn setMouseButton(self: *Io, port: usize, button: u4, pressed: bool) void {
        if (port >= 2) return;
        if (pressed) {
            self.mouse_buttons[port] |= button;
        } else {
            self.mouse_buttons[port] &= ~button;
        }
    }

    pub fn setMouseDelta(self: *Io, port: usize, dx: i16, dy: i16) void {
        if (port >= 2) return;
        // Clamp to 8-bit magnitude and record sign bits.
        const abs_x: u8 = if (dx < 0)
            if (dx <= -256) 0xFF else @intCast(@as(u16, @bitCast(-dx)))
        else
            if (dx >= 256) 0xFF else @intCast(@as(u16, @bitCast(dx)));
        const abs_y: u8 = if (dy < 0)
            if (dy <= -256) 0xFF else @intCast(@as(u16, @bitCast(-dy)))
        else
            if (dy >= 256) 0xFF else @intCast(@as(u16, @bitCast(dy)));
        self.mouse_dx[port] = abs_x;
        self.mouse_dy[port] = abs_y;
        self.mouse_sign_x[port] = if (dx < 0) 1 else 0;
        self.mouse_sign_y[port] = if (dy < 0) 1 else 0;
    }

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

test "three-button controllers ignore the six-button identification cycle" {
    var io = Io.init();
    io.setControllerType(0, .three_button);

    io.write(0x09, 0x40);
    io.setButton(0, Io.Button.Z, true);
    io.setButton(0, Io.Button.C, true);

    io.write(0x03, 0x00);
    io.write(0x03, 0x40);
    io.write(0x03, 0x00);
    io.write(0x03, 0x40);
    io.write(0x03, 0x00);
    io.write(0x03, 0x40);

    try testing.expectEqual(@as(u8, 0x5F), io.read(0x03));

    io.write(0x03, 0x00);
    try testing.expectEqual(@as(u8, 0x33), io.read(0x03));
}

test "hardware reset clears transient io state but preserves controller wiring and held inputs" {
    var io = Io.init();
    io.setControllerType(0, .three_button);
    io.setVersionIsOverseas(false);
    io.setButton(0, Io.Button.A, true);
    io.write(0x09, 0x40);
    io.write(0x03, 0x00);
    io.write(0x03, 0x40);

    try testing.expect(io.th_flip_count[0] != 0);
    try testing.expectEqual(@as(u8, 0x40), io.ctrl[0]);

    io.resetForHardware();

    try testing.expectEqual(Io.ControllerType.three_button, io.getControllerType(0));
    try testing.expect(!io.versionIsOverseas());
    try testing.expectEqual(@as(u16, 0), io.pad[0] & Io.Button.A);
    try testing.expectEqual(@as(u8, 0), io.ctrl[0]);
    try testing.expectEqual(@as(u2, 0), io.th_flip_count[0]);
    try testing.expect(io.controller_th[0]);
}

test "ea 4-way play multiplexes four controllers via port 2 th" {
    var io = Io.init();
    io.setControllerType(0, .ea_4way_play);
    io.setControllerType(1, .ea_4way_play);

    io.write(0x09, 0x40); // port 1 ctrl = TH output
    io.write(0x0B, 0x40); // port 2 ctrl = TH output

    // Player C has C button pressed, player A does not
    io.setButton(2, Io.Button.C, true);

    // TH high on port 2 → port 1 reads pad[0] (player A)
    io.write(0x05, 0x40);
    io.write(0x03, 0x40);
    const a_high = io.read(0x03);

    // TH low on port 2 → port 1 reads pad[2] (player C)
    io.write(0x05, 0x00);
    io.write(0x03, 0x40);
    const c_high = io.read(0x03);

    // In TH-high format: bit 5 = C button (active low)
    try testing.expect((c_high & 0x20) == 0); // C pressed on player C
    try testing.expect((a_high & 0x20) != 0); // C not pressed on player A
}

test "sega mouse returns identification nibbles on first two TH transitions" {
    var io = Io.init();
    io.setControllerType(0, .sega_mouse);
    io.write(0x09, 0x40); // port 1 CTRL = TH output

    // TH high: should read 0x00 in low nibble (mouse ID high)
    io.write(0x03, 0x40);
    try testing.expectEqual(@as(u8, 0x00), io.read(0x03) & 0x0F);

    // TH low: should read 0x0B in low nibble (mouse ID low)
    io.write(0x03, 0x00);
    try testing.expectEqual(@as(u8, 0x0B), io.read(0x03) & 0x0F);
}

test "sega mouse reports button state on the fourth nibble" {
    var io = Io.init();
    io.setControllerType(0, .sega_mouse);
    io.write(0x09, 0x40);

    io.setMouseButton(0, Io.MouseButton.left, true);
    io.setMouseButton(0, Io.MouseButton.right, true);

    // Phase 0 (TH high): ID high nibble 0x0
    io.write(0x03, 0x40);
    // Phase 1 (TH low): ID low nibble 0xB
    io.write(0x03, 0x00);
    // Phase 2 (TH high): overflow/sign nibble (no movement = 0x0)
    io.write(0x03, 0x40);
    // Phase 3 (TH low): button nibble: Start=3, Middle=2, Right=1, Left=0
    io.write(0x03, 0x00);

    // Left (bit 0) and Right (bit 1) pressed → bits 0 and 1 set
    const buttons = io.read(0x03) & 0x0F;
    try testing.expectEqual(@as(u8, 0x03), buttons);
}

test "sega mouse reports movement deltas in the last four nibbles" {
    var io = Io.init();
    io.setControllerType(0, .sega_mouse);
    io.write(0x09, 0x40);

    // Queue a movement of X=+0x1A, Y=-0x05
    io.setMouseDelta(0, 0x1A, @as(i16, @bitCast(@as(u16, 0xFFFB)))); // Y = -5

    // Phase 0-1: identification
    io.write(0x03, 0x40);
    io.write(0x03, 0x00);
    // Phase 2 (TH high): overflow/sign nibble
    // Y sign = 1 (negative), X sign = 0 (positive) → bits: YO=0, XO=0, YS=1, XS=0 = 0x02
    io.write(0x03, 0x40);
    try testing.expectEqual(@as(u8, 0x02), io.read(0x03) & 0x0F);
    // Phase 3 (TH low): buttons (none pressed = 0x0)
    io.write(0x03, 0x00);
    // Phase 4 (TH high): X high nibble (0x1A >> 4 = 0x1)
    io.write(0x03, 0x40);
    try testing.expectEqual(@as(u8, 0x01), io.read(0x03) & 0x0F);
    // Phase 5 (TH low): X low nibble (0x1A & 0xF = 0xA)
    io.write(0x03, 0x00);
    try testing.expectEqual(@as(u8, 0x0A), io.read(0x03) & 0x0F);
    // Phase 6 (TH high): Y high nibble (|-5| = 5, 0x05 >> 4 = 0x0)
    io.write(0x03, 0x40);
    try testing.expectEqual(@as(u8, 0x00), io.read(0x03) & 0x0F);
    // Phase 7 (TH low): Y low nibble (0x05 & 0xF = 0x5)
    io.write(0x03, 0x00);
    try testing.expectEqual(@as(u8, 0x05), io.read(0x03) & 0x0F);
}

test "sega mouse resets read phase after a complete 8-nibble cycle" {
    var io = Io.init();
    io.setControllerType(0, .sega_mouse);
    io.write(0x09, 0x40);

    // Complete one full 8-nibble read cycle
    io.write(0x03, 0x40); // phase 0
    io.write(0x03, 0x00); // phase 1
    io.write(0x03, 0x40); // phase 2
    io.write(0x03, 0x00); // phase 3
    io.write(0x03, 0x40); // phase 4
    io.write(0x03, 0x00); // phase 5
    io.write(0x03, 0x40); // phase 6
    io.write(0x03, 0x00); // phase 7

    // Next cycle should restart with identification
    io.write(0x03, 0x40); // phase 0 again
    try testing.expectEqual(@as(u8, 0x00), io.read(0x03) & 0x0F);
    io.write(0x03, 0x00); // phase 1 again
    try testing.expectEqual(@as(u8, 0x0B), io.read(0x03) & 0x0F);
}

test "sega mouse deltas are consumed after a complete read cycle" {
    var io = Io.init();
    io.setControllerType(0, .sega_mouse);
    io.write(0x09, 0x40);

    io.setMouseDelta(0, 0x10, 0x20);

    // Complete one full read cycle
    for (0..4) |_| {
        io.write(0x03, 0x40);
        io.write(0x03, 0x00);
    }

    // After completing the cycle, deltas should be cleared.
    // Start a new cycle and check movement nibbles are zero.
    io.write(0x03, 0x40); // phase 0
    io.write(0x03, 0x00); // phase 1
    io.write(0x03, 0x40); // phase 2: sign/overflow
    try testing.expectEqual(@as(u8, 0x00), io.read(0x03) & 0x0F);
    io.write(0x03, 0x00); // phase 3: buttons
    io.write(0x03, 0x40); // phase 4: X high
    try testing.expectEqual(@as(u8, 0x00), io.read(0x03) & 0x0F);
}

test "serial and tx registers keep hardware defaults and serial control masks low status bits" {
    var io = Io.init();

    try testing.expectEqual(@as(u8, 0xFF), io.readTxData(0));
    try testing.expectEqual(@as(u8, 0xFF), io.readTxData(1));
    try testing.expectEqual(@as(u8, 0xFB), io.readTxData(2));
    try testing.expectEqual(@as(u8, 0x00), io.readRxData(0));
    try testing.expectEqual(@as(u8, 0x00), io.readSerialControl(2));

    io.writeTxData(1, 0x5A);
    io.writeSerialControl(2, 0xA7);

    try testing.expectEqual(@as(u8, 0x5A), io.readTxData(1));
    try testing.expectEqual(@as(u8, 0xA0), io.readSerialControl(2));

    io.resetForHardware();

    try testing.expectEqual(@as(u8, 0xFF), io.readTxData(0));
    try testing.expectEqual(@as(u8, 0xFF), io.readTxData(1));
    try testing.expectEqual(@as(u8, 0xFB), io.readTxData(2));
    try testing.expectEqual(@as(u8, 0x00), io.readSerialControl(2));
}
