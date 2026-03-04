const c = @cImport({
    @cInclude("jgz80_bridge.h");
});

pub const Z80 = struct {
    handle: ?*c.Jgz80Handle,

    pub fn init() Z80 {
        return .{ .handle = c.jgz80_create() };
    }

    pub fn deinit(self: *Z80) void {
        if (self.handle) |h| {
            c.jgz80_destroy(h);
            self.handle = null;
        }
    }

    pub fn reset(self: *Z80) void {
        if (self.handle) |h| c.jgz80_reset(h);
    }

    pub fn step(self: *Z80, cycles: u32) void {
        if (self.handle) |h| c.jgz80_step(h, cycles);
    }

    pub fn readByte(self: *Z80, addr: u16) u8 {
        if (self.handle) |h| return c.jgz80_read_byte(h, addr);
        return 0;
    }

    pub fn writeByte(self: *Z80, addr: u16, val: u8) void {
        if (self.handle) |h| c.jgz80_write_byte(h, addr, val);
    }

    // Bus Request (0xA11100)
    pub fn writeBusReq(self: *Z80, val: u16) void {
        if (self.handle) |h| c.jgz80_write_bus_req(h, val);
    }

    pub fn readBusReq(self: *Z80) u16 {
        if (self.handle) |h| return c.jgz80_read_bus_req(h);
        return 0x0100;
    }

    // Bus Reset (0xA11200)
    pub fn writeReset(self: *Z80, val: u16) void {
        if (self.handle) |h| c.jgz80_write_reset(h, val);
    }
};
