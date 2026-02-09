const std = @import("std");

pub const Z80 = struct {
    ram: [8 * 1024]u8,
    bus_req: bool,
    bus_ack: bool,
    reset_line: bool,

    pub fn init() Z80 {
        return Z80{
            .ram = [_]u8{0} ** (8 * 1024),
            .bus_req = false,
            .bus_ack = false,
            .reset_line = false,
        };
    }

    pub fn reset(self: *Z80) void {
        self.bus_req = false;
        self.bus_ack = false;
        self.reset_line = false;
        @memset(&self.ram, 0);
    }

    pub fn step(self: *Z80, cycles: u32) void {
        _ = self;
        _ = cycles;
        // Todo: Implement Z80 core
    }

    pub fn readByte(self: *Z80, addr: u16) u8 {
        return self.ram[addr & 0x1FFF];
    }

    pub fn writeByte(self: *Z80, addr: u16, val: u8) void {
        self.ram[addr & 0x1FFF] = val;
    }

    // Bus Request (0xA11100)
    pub fn writeBusReq(self: *Z80, val: u16) void {
        if ((val & 0x100) != 0) {
            self.bus_req = false;
            self.bus_ack = false; // Release bus
        } else {
            self.bus_req = true;
            self.bus_ack = true; // Instant grant for now
        }
    }

    pub fn readBusReq(self: *Z80) u16 {
        return if (self.bus_req) 0x0000 else 0x0100;
        // Wait, 0x100 means Z80 has bus? Or 68k has bus?
        // 0 = Requesting Bus (Z80 wants it? No, 68k requesting Z80 bus?)
        // bit 8: 0 = Z80 enabled/bus requested?, 1 = Z80 disabled?
        // Let's check docs.
        // 0xA11100 Write: 0x100 = Release Bus (Z80 runs), 0x000 = Request Bus (Z80 stops).
        // Read: bit 8 is status.
    }

    // Bus Reset (0xA11200)
    pub fn writeReset(self: *Z80, val: u16) void {
        if (val == 0) {
            self.reset_line = true;
            self.reset(); // Reset logic
        } else {
            self.reset_line = false;
        }
    }
};
