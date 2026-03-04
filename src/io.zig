const std = @import("std");

pub const Io = struct {
    data: [3]u8, // 0=A, 1=B, 2=C
    ctrl: [3]u8, // 0=A, 1=B, 2=C

    // Internal Controller State (Active Low: 0=Pressed, 1=Released)
    // Bit 0: Up
    // Bit 1: Down
    // Bit 2: Left
    // Bit 3: Right
    // Bit 4: B
    // Bit 5: C
    // Bit 6: A
    // Bit 7: Start
    // 0:Up, 1:Down, 2:Left, 3:Right, 4:B, 5:C, 6:A, 7:Start
    // 8:X, 9:Y, 10:Z, 11:Mode
    pad: [2]u16,
    cycle: [2]u4,

    pub fn init() Io {
        return Io{
            .data = [_]u8{0} ** 3,
            .ctrl = [_]u8{0} ** 3,
            .pad = [_]u16{0xFFFF} ** 2, // All released (Active Low)
            .cycle = [_]u4{0} ** 2,
        };
    }

    pub fn read(self: *Io, address: u32) u8 {
        switch (address & 0xFF) {
            0x01 => return 0x80, // Version register (Overseas NTSC, no Mega-CD), low byte
            0x03 => return self.readData(0), // Port A data, low byte
            0x05 => return self.readData(1), // Port B data, low byte
            0x09 => return self.ctrl[0], // Port A control, low byte
            0x0B => return self.ctrl[1], // Port B control, low byte
            else => return 0,
        }
    }

    pub fn write(self: *Io, address: u32, value: u8) void {
        switch (address & 0xFF) {
            0x03 => self.writeData(0, value),
            0x05 => self.writeData(1, value),
            0x09 => self.ctrl[0] = value,
            0x0B => self.ctrl[1] = value,
            else => {},
        }
    }

    fn readData(self: *const Io, port: usize) u8 {
        var value: u8 = self.data[port] & 0x80; // Keep TH bit
        const pad = self.pad[port];
        const cycle = self.cycle[port];

        const th = (value & 0x40) != 0;

        if (th) {
            // TH = 1: CB, RB, LB, U, D, L, R
            // Bits: 5=C, 4=B, 3=R, 2=L, 1=D, 0=U
            value |= (@as(u8, @truncate(pad)) & 0x3F);
        } else {
            // TH = 0
            // Standard: ? S A 0 0 D U
            // Cycle 3 (6-button): ? S A M X Y Z

            // Note: My cycle logic increments on writes (High->Low).
            // So when we are here (TH=0), we are IN a cycle state.

            // Cycle 3 means we have seen High->Low 3 times.
            if (cycle == 3) {
                // Return Extra Buttons
                // D3: Mode, D2: X, D1: Y, D0: Z
                value |= (@as(u8, @truncate(pad)) & 0x0C); // Bits 2,3 from pad are Left/Right? No.
                // Wait, if pad is: 0:Up, 1:Down, 2:Left, 3:Right.
                // We want bits 0-3 of value to be Z, Y, X, Mode.

                // Logic:
                // Z (Bit 10) -> D0
                if ((pad & 0x0400) != 0) value |= 0x01;
                // Y (Bit 9) -> D1
                if ((pad & 0x0200) != 0) value |= 0x02;
                // X (Bit 8) -> D2
                if ((pad & 0x0100) != 0) value |= 0x04;
                // Mode (Bit 11) -> D3
                if ((pad & 0x0800) != 0) value |= 0x08;

                // Start (Bit 5? 7?) -> D5 ? No, TH=0 means D5 is Start?
                // Standard TH=0: ? S A 0 0 D U
                // Cycle 3: ? S A M X Y Z
                // So S (Start) is on D5, A is on D4.

                // A (Bit 6) -> D4 (0x10)
                if ((pad & 0x0040) != 0) value |= 0x10;
                // Start (Bit 7) -> D5 (0x20)
                if ((pad & 0x0080) != 0) value |= 0x20;
            } else {
                // Standard TH=0
                // ? S A 0 0 D U (Bits 0-1 are U, D)
                value |= (@as(u8, @truncate(pad)) & 0x03); // U, D

                // Bit 2,3 forced to 0 (Left, Right are low in TH=0 standard mapping, meaning pressed? No meaning 0 logic level).
                // Actually standard says 0. So leaving them 0 is correct.

                if ((pad & 0x0040) != 0) value |= 0x10; // A
                if ((pad & 0x0080) != 0) value |= 0x20; // Start
            }
        }
        return value;
    }

    fn writeData(self: *Io, port: usize, value: u8) void {
        const old_val = self.data[port];
        self.data[port] = value;

        // Check TH transition (Bit 6)
        // High (1) -> Low (0)
        if ((old_val & 0x40) != 0 and (value & 0x40) == 0) {
            self.cycle[port] += 1;
        } else if ((value & 0x40) != 0) {
            // TH goes High.
            // If checking specifically for 6-button reset?
            // Usually if not reading appropriately, it resets?
            // Simple logic:
            if (self.cycle[port] == 3) {
                // After reading 6-buttons, next High resets.
                self.cycle[port] = 0;
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
