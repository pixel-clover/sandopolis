const std = @import("std");
const Z80 = @import("../cpu/z80.zig").Z80;

pub const HostReadByteFn = *const fn (ctx: ?*anyopaque, address: u32) u8;
pub const HostWriteByteFn = *const fn (ctx: ?*anyopaque, address: u32, value: u8) void;
pub const HostM68kBusAccessFn = *const fn (ctx: ?*anyopaque) void;

pub const HostBridge = struct {
    ctx: ?*anyopaque,
    read_host_byte_fn: HostReadByteFn,
    write_host_byte_fn: HostWriteByteFn,
    m68k_bus_access_fn: HostM68kBusAccessFn,

    pub fn init(
        read_host_byte_fn: HostReadByteFn,
        write_host_byte_fn: HostWriteByteFn,
        m68k_bus_access_fn: HostM68kBusAccessFn,
    ) HostBridge {
        return .{
            .ctx = null,
            .read_host_byte_fn = read_host_byte_fn,
            .write_host_byte_fn = write_host_byte_fn,
            .m68k_bus_access_fn = m68k_bus_access_fn,
        };
    }

    pub fn bind(self: *HostBridge, z80: *Z80, ctx: ?*anyopaque) void {
        self.ctx = ctx;
        z80.setHostCallbacks(self, readCallback, writeCallback, m68kBusAccessCallback);
    }

    fn readCallback(userdata: ?*anyopaque, address: u32) callconv(.c) u8 {
        const self: *HostBridge = @ptrCast(@alignCast(userdata orelse return 0xFF));
        const addr = address & 0xFFFFFF;
        if (addr >= 0xA00000 and addr < 0xA10000) return 0xFF;
        return self.read_host_byte_fn(self.ctx, addr);
    }

    fn writeCallback(userdata: ?*anyopaque, address: u32, value: u8) callconv(.c) void {
        const self: *HostBridge = @ptrCast(@alignCast(userdata orelse return));
        const addr = address & 0xFFFFFF;
        if (addr >= 0xA00000 and addr < 0xA10000) return;
        self.write_host_byte_fn(self.ctx, addr, value);
    }

    fn m68kBusAccessCallback(userdata: ?*anyopaque) callconv(.c) void {
        const self: *HostBridge = @ptrCast(@alignCast(userdata orelse return));
        self.m68k_bus_access_fn(self.ctx);
    }
};

const TimingProbe = struct {
    time: u32 = 0,
    pending_wait: u32 = 0,
    odd_access: bool = false,
    last_write_time: u32 = 0,
    last_write_value: u8 = 0,

    fn readHostByte(ctx: ?*anyopaque, address: u32) u8 {
        const self: *TimingProbe = @ptrCast(@alignCast(ctx orelse return 0xFF));
        _ = self;
        _ = address;
        return 0x10;
    }

    fn writeHostByte(ctx: ?*anyopaque, address: u32, value: u8) void {
        const self: *TimingProbe = @ptrCast(@alignCast(ctx orelse return));
        _ = address;
        self.last_write_time = self.time;
        self.last_write_value = value;
    }

    fn onM68kBusAccess(ctx: ?*anyopaque) void {
        const self: *TimingProbe = @ptrCast(@alignCast(ctx orelse return));
        if (self.pending_wait != 0) {
            self.time += self.pending_wait;
            self.pending_wait = 0;
        }
        self.pending_wait = if (self.odd_access) 50 else 49;
        self.odd_access = !self.odd_access;
    }
};

test "banked z80 read-modify-write can advance host timing between accesses" {
    var z80 = Z80.init();
    defer z80.deinit();

    var probe = TimingProbe{};
    var bridge = HostBridge.init(TimingProbe.readHostByte, TimingProbe.writeHostByte, TimingProbe.onM68kBusAccess);
    bridge.bind(&z80, &probe);

    z80.writeByte(0x0000, 0x34); // INC (HL)

    var state = z80.captureState();
    state.pc = 0x0000;
    state.hl = 0x8000;
    state.bank = 0x0000;
    z80.restoreState(&state);

    try std.testing.expectEqual(@as(u32, 11), z80.stepInstruction());
    try std.testing.expectEqual(@as(u32, 49), probe.last_write_time);
    try std.testing.expectEqual(@as(u8, 0x11), probe.last_write_value);
    try std.testing.expectEqual(@as(u32, 49), probe.time);
    try std.testing.expectEqual(@as(u32, 50), probe.pending_wait);
}
