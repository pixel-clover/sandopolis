const c = @cImport({
    @cInclude("jgz80_bridge.h");
});

pub const Z80 = struct {
    handle: ?*c.Jgz80Handle,

    pub const YmWriteEvent = c.Jgz80YmWriteEvent;

    pub const HostReadFn = *const fn (userdata: ?*anyopaque, addr: u32) callconv(.c) u8;
    pub const HostWriteFn = *const fn (userdata: ?*anyopaque, addr: u32, val: u8) callconv(.c) void;

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

    pub fn stepInstruction(self: *Z80) u32 {
        if (self.handle) |h| return c.jgz80_step_one(h);
        return 0;
    }

    pub fn readByte(self: *Z80, addr: u16) u8 {
        if (self.handle) |h| return c.jgz80_read_byte(h, addr);
        return 0;
    }

    pub fn writeByte(self: *Z80, addr: u16, val: u8) void {
        if (self.handle) |h| c.jgz80_write_byte(h, addr, val);
    }

    pub fn setHostCallbacks(self: *Z80, userdata: ?*anyopaque, host_read: HostReadFn, host_write: HostWriteFn) void {
        if (self.handle) |h| c.jgz80_set_host_callbacks(h, host_read, host_write, userdata);
    }

    pub fn getBank(self: *const Z80) u16 {
        if (self.handle) |h| return c.jgz80_get_bank(h);
        return 0;
    }

    pub fn getPc(self: *const Z80) u16 {
        if (self.handle) |h| return c.jgz80_get_pc(h);
        return 0;
    }

    pub fn take68kBusAccessCount(self: *Z80) u32 {
        if (self.handle) |h| return c.jgz80_take_68k_bus_access_count(h);
        return 0;
    }

    pub fn assertIrq(self: *Z80, data: u8) void {
        if (self.handle) |h| c.jgz80_assert_irq(h, data);
    }

    pub fn clearIrq(self: *Z80) void {
        if (self.handle) |h| c.jgz80_clear_irq(h);
    }

    pub fn getYmRegister(self: *const Z80, port: u1, reg: u8) u8 {
        if (self.handle) |h| return c.jgz80_get_ym_register(h, port, reg);
        return 0;
    }

    pub fn getYmKeyMask(self: *const Z80) u8 {
        if (self.handle) |h| return c.jgz80_get_ym_key_mask(h);
        return 0;
    }

    pub fn takeYmWrites(self: *Z80, dest: []YmWriteEvent) usize {
        if (dest.len == 0) return 0;
        if (self.handle) |h| return c.jgz80_take_ym_writes(h, dest.ptr, @intCast(dest.len));
        return 0;
    }

    pub fn takeYmDacSamples(self: *Z80, dest: []u8) usize {
        if (dest.len == 0) return 0;
        if (self.handle) |h| return c.jgz80_take_ym_dac_samples(h, dest.ptr, @intCast(dest.len));
        return 0;
    }

    pub fn takePsgCommands(self: *Z80, dest: []u8) usize {
        if (dest.len == 0) return 0;
        if (self.handle) |h| return c.jgz80_take_psg_commands(h, dest.ptr, @intCast(dest.len));
        return 0;
    }

    pub fn getPsgLast(self: *const Z80) u8 {
        if (self.handle) |h| return c.jgz80_get_psg_last(h);
        return 0;
    }

    pub fn getPsgTone(self: *const Z80, channel: u2) u16 {
        if (self.handle) |h| return c.jgz80_get_psg_tone(h, channel);
        return 0;
    }

    pub fn getPsgVolume(self: *const Z80, channel: u2) u8 {
        if (self.handle) |h| return c.jgz80_get_psg_volume(h, channel);
        return 0x0F;
    }

    pub fn getPsgNoise(self: *const Z80) u8 {
        if (self.handle) |h| return c.jgz80_get_psg_noise(h);
        return 0;
    }

    // Bus Request (0xA11100)
    pub fn writeBusReq(self: *Z80, val: u16) void {
        if (self.handle) |h| c.jgz80_write_bus_req(h, val);
    }

    // Reads the 68k-visible BUSACK register state at $A11100.
    pub fn readBusReq(self: *const Z80) u16 {
        if (self.handle) |h| return c.jgz80_read_bus_req(@constCast(h));
        return 0x0100;
    }

    pub fn canRun(self: *const Z80) bool {
        return self.readBusReq() != 0x0000 and self.readReset() != 0x0000;
    }

    // Bus Reset (0xA11200)
    pub fn writeReset(self: *Z80, val: u16) void {
        if (self.handle) |h| c.jgz80_write_reset(h, val);
    }

    pub fn readReset(self: *const Z80) u16 {
        if (self.handle) |h| return c.jgz80_read_reset(@constCast(h));
        return 0x0100;
    }
};
