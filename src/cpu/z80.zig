const c = @cImport({
    @cInclude("jgz80_bridge.h");
});

const std = @import("std");

pub const Z80 = struct {
    handle: ?*c.Jgz80Handle,

    pub const YmWriteEvent = c.Jgz80YmWriteEvent;
    pub const YmDacSampleEvent = c.Jgz80YmDacSampleEvent;
    pub const YmResetEvent = c.Jgz80YmResetEvent;
    pub const PsgCommandEvent = c.Jgz80PsgCommandEvent;
    pub const RegisterDump = c.Jgz80RegisterDump;

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

    pub fn getRegisterDump(self: *const Z80) RegisterDump {
        if (self.handle) |h| return c.jgz80_get_register_dump(h);
        return std.mem.zeroes(RegisterDump);
    }

    pub fn debugDump(self: *const Z80) void {
        const dump = self.getRegisterDump();
        std.debug.print("Z80 PC: {X:0>4} SP: {X:0>4} IX: {X:0>4} IY: {X:0>4} BANK: {X:0>3}\n", .{
            dump.pc,
            dump.sp,
            dump.ix,
            dump.iy,
            self.getBank(),
        });
        std.debug.print("Z80 AF: {X:0>4} BC: {X:0>4} DE: {X:0>4} HL: {X:0>4}\n", .{
            dump.af,
            dump.bc,
            dump.de,
            dump.hl,
        });
        std.debug.print("Z80 AF': {X:0>4} BC': {X:0>4} DE': {X:0>4} HL': {X:0>4}\n", .{
            dump.af_alt,
            dump.bc_alt,
            dump.de_alt,
            dump.hl_alt,
        });
        std.debug.print(
            "Z80 IR: {X:0>4} WZ: {X:0>4} IM: {d} IRQ: {X:0>2} IFF1: {d} IFF2: {d} HALT: {d} BUSREQ: {X:0>4} RESET: {X:0>4}\n",
            .{
                dump.ir,
                dump.wz,
                dump.interrupt_mode,
                dump.irq_data,
                dump.iff1,
                dump.iff2,
                dump.halted,
                self.readBusReq(),
                self.readReset(),
            },
        );
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

    pub fn takeYmDacSamples(self: *Z80, dest: []YmDacSampleEvent) usize {
        if (dest.len == 0) return 0;
        if (self.handle) |h| return c.jgz80_take_ym_dac_samples(h, dest.ptr, @intCast(dest.len));
        return 0;
    }

    pub fn takeYmResets(self: *Z80, dest: []YmResetEvent) usize {
        if (dest.len == 0) return 0;
        if (self.handle) |h| return c.jgz80_take_ym_resets(h, dest.ptr, @intCast(dest.len));
        return 0;
    }

    pub fn takePsgCommands(self: *Z80, dest: []PsgCommandEvent) usize {
        if (dest.len == 0) return 0;
        if (self.handle) |h| return c.jgz80_take_psg_commands(h, dest.ptr, @intCast(dest.len));
        return 0;
    }

    pub fn setAudioMasterOffset(self: *Z80, master_offset: u32) void {
        if (self.handle) |h| c.jgz80_set_audio_master_offset(h, master_offset);
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

test "z80 register dump reflects stepped state" {
    var z80 = Z80.init();
    defer z80.deinit();

    z80.writeByte(0x0000, 0x00); // NOP
    try std.testing.expectEqual(@as(u32, 4), z80.stepInstruction());

    const dump = z80.getRegisterDump();
    try std.testing.expectEqual(@as(u16, 0x0001), dump.pc);
    try std.testing.expectEqual(@as(u8, 0), dump.halted);
}

test "z80 audio events retain scheduler master offsets" {
    var z80 = Z80.init();
    defer z80.deinit();

    z80.setAudioMasterOffset(12);
    z80.writeByte(0x4000, 0x2A);
    z80.writeByte(0x4001, 0x56);
    z80.writeByte(0x4000, 0x22);
    z80.writeByte(0x4001, 0x0F);
    z80.writeByte(0x7F11, 0x90);

    var ym_events: [1]Z80.YmWriteEvent = undefined;
    try std.testing.expectEqual(@as(usize, 1), z80.takeYmWrites(ym_events[0..]));
    try std.testing.expectEqual(@as(u32, 12), ym_events[0].master_offset);
    try std.testing.expectEqual(@as(u8, 0x22), ym_events[0].reg);
    try std.testing.expectEqual(@as(u8, 0x0F), ym_events[0].value);

    var ym_dac_events: [1]Z80.YmDacSampleEvent = undefined;
    try std.testing.expectEqual(@as(usize, 1), z80.takeYmDacSamples(ym_dac_events[0..]));
    try std.testing.expectEqual(@as(u32, 12), ym_dac_events[0].master_offset);
    try std.testing.expectEqual(@as(u8, 0x56), ym_dac_events[0].value);

    var psg_events: [1]Z80.PsgCommandEvent = undefined;
    try std.testing.expectEqual(@as(usize, 1), z80.takePsgCommands(psg_events[0..]));
    try std.testing.expectEqual(@as(u32, 12), psg_events[0].master_offset);
    try std.testing.expectEqual(@as(u8, 0x90), psg_events[0].value);
}

test "z80 reset emits a timed ym reset event without dropping earlier ym audio events" {
    var z80 = Z80.init();
    defer z80.deinit();

    z80.setAudioMasterOffset(9);
    z80.writeByte(0x4000, 0x2A);
    z80.writeByte(0x4001, 0x44);
    z80.writeByte(0x4000, 0x22);
    z80.writeByte(0x4001, 0x33);

    z80.setAudioMasterOffset(27);
    z80.writeReset(0);

    var ym_events: [1]Z80.YmWriteEvent = undefined;
    try std.testing.expectEqual(@as(usize, 1), z80.takeYmWrites(ym_events[0..]));
    try std.testing.expectEqual(@as(u32, 9), ym_events[0].master_offset);

    var ym_dac_events: [1]Z80.YmDacSampleEvent = undefined;
    try std.testing.expectEqual(@as(usize, 1), z80.takeYmDacSamples(ym_dac_events[0..]));
    try std.testing.expectEqual(@as(u32, 9), ym_dac_events[0].master_offset);

    var ym_reset_events: [1]Z80.YmResetEvent = undefined;
    try std.testing.expectEqual(@as(usize, 1), z80.takeYmResets(ym_reset_events[0..]));
    try std.testing.expectEqual(@as(u32, 27), ym_reset_events[0].master_offset);
}
