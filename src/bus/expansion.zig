//! Expansion-slot device hook for the 68K bus.
//!
//! A device attached through the expansion port (Sega CD) or the cartridge
//! slot (32X) can claim any 68K address before the built-in decode runs.
//! Reads return `null` and writes return `false` when the device does not
//! claim the address, letting the standard cartridge/RAM/VDP/IO decode take
//! over. The device also receives master-clock credit so it can run its own
//! processors in deferred bursts, mirroring the Z80 scheduling model.

const std = @import("std");

pub const ExpansionDevice = struct {
    ctx: *anyopaque,
    read8Fn: *const fn (*anyopaque, u32) ?u8,
    read16Fn: *const fn (*anyopaque, u32) ?u16,
    write8Fn: *const fn (*anyopaque, u32, u8) bool,
    write16Fn: *const fn (*anyopaque, u32, u16) bool,
    /// Accumulate master-clock credit. Cheap; called after every 68K step.
    stepMasterFn: *const fn (*anyopaque, u32) void,
    /// Run the device's processors up to the accumulated credit.
    flushFn: *const fn (*anyopaque) void,
    resetFn: *const fn (*anyopaque) void,

    /// Bind a context type that provides `read8/read16/write8/write16/
    /// stepMaster/flush/reset` methods with the signatures above.
    pub fn bind(comptime Context: type, ctx: *Context) ExpansionDevice {
        const Impl = struct {
            fn cast(raw: *anyopaque) *Context {
                return @ptrCast(@alignCast(raw));
            }
            fn read8(raw: *anyopaque, address: u32) ?u8 {
                return cast(raw).read8(address);
            }
            fn read16(raw: *anyopaque, address: u32) ?u16 {
                return cast(raw).read16(address);
            }
            fn write8(raw: *anyopaque, address: u32, value: u8) bool {
                return cast(raw).write8(address, value);
            }
            fn write16(raw: *anyopaque, address: u32, value: u16) bool {
                return cast(raw).write16(address, value);
            }
            fn stepMaster(raw: *anyopaque, master_cycles: u32) void {
                cast(raw).stepMaster(master_cycles);
            }
            fn flush(raw: *anyopaque) void {
                cast(raw).flush();
            }
            fn reset(raw: *anyopaque) void {
                cast(raw).reset();
            }
        };
        return .{
            .ctx = ctx,
            .read8Fn = Impl.read8,
            .read16Fn = Impl.read16,
            .write8Fn = Impl.write8,
            .write16Fn = Impl.write16,
            .stepMasterFn = Impl.stepMaster,
            .flushFn = Impl.flush,
            .resetFn = Impl.reset,
        };
    }

    pub inline fn read8(self: ExpansionDevice, address: u32) ?u8 {
        return self.read8Fn(self.ctx, address);
    }
    pub inline fn read16(self: ExpansionDevice, address: u32) ?u16 {
        return self.read16Fn(self.ctx, address);
    }
    pub inline fn write8(self: ExpansionDevice, address: u32, value: u8) bool {
        return self.write8Fn(self.ctx, address, value);
    }
    pub inline fn write16(self: ExpansionDevice, address: u32, value: u16) bool {
        return self.write16Fn(self.ctx, address, value);
    }
    pub inline fn stepMaster(self: ExpansionDevice, master_cycles: u32) void {
        self.stepMasterFn(self.ctx, master_cycles);
    }
    pub inline fn flush(self: ExpansionDevice) void {
        self.flushFn(self.ctx);
    }
    pub inline fn reset(self: ExpansionDevice) void {
        self.resetFn(self.ctx);
    }
};

/// Minimal device used by bus tests: claims one 64KB page of RAM at
/// `base` and records scheduling calls.
pub const ProbeDevice = struct {
    base: u32,
    ram: [64 * 1024]u8 = [_]u8{0} ** (64 * 1024),
    master_credit: u64 = 0,
    flush_count: u32 = 0,
    reset_count: u32 = 0,

    fn claims(self: *const ProbeDevice, address: u32) bool {
        return (address & 0xFF0000) == self.base;
    }

    pub fn read8(self: *ProbeDevice, address: u32) ?u8 {
        if (!self.claims(address)) return null;
        return self.ram[address & 0xFFFF];
    }
    pub fn read16(self: *ProbeDevice, address: u32) ?u16 {
        if (!self.claims(address)) return null;
        const i = address & 0xFFFE;
        return (@as(u16, self.ram[i]) << 8) | self.ram[i + 1];
    }
    pub fn write8(self: *ProbeDevice, address: u32, value: u8) bool {
        if (!self.claims(address)) return false;
        self.ram[address & 0xFFFF] = value;
        return true;
    }
    pub fn write16(self: *ProbeDevice, address: u32, value: u16) bool {
        if (!self.claims(address)) return false;
        const i = address & 0xFFFE;
        self.ram[i] = @truncate(value >> 8);
        self.ram[i + 1] = @truncate(value);
        return true;
    }
    pub fn stepMaster(self: *ProbeDevice, master_cycles: u32) void {
        self.master_credit += master_cycles;
    }
    pub fn flush(self: *ProbeDevice) void {
        self.flush_count += 1;
    }
    pub fn reset(self: *ProbeDevice) void {
        self.reset_count += 1;
    }

    pub fn device(self: *ProbeDevice) ExpansionDevice {
        return ExpansionDevice.bind(ProbeDevice, self);
    }
};

test "bound device forwards claimed accesses and rejects others" {
    var probe = ProbeDevice{ .base = 0x200000 };
    const dev = probe.device();

    try std.testing.expect(dev.write16(0x200010, 0xBEEF));
    try std.testing.expectEqual(@as(?u16, 0xBEEF), dev.read16(0x200010));
    try std.testing.expectEqual(@as(?u8, 0xEF), dev.read8(0x200011));

    try std.testing.expect(!dev.write8(0x300000, 1));
    try std.testing.expectEqual(@as(?u8, null), dev.read8(0x300000));
    try std.testing.expectEqual(@as(?u16, null), dev.read16(0xA12000));
}

test "bound device forwards scheduling calls" {
    var probe = ProbeDevice{ .base = 0x200000 };
    const dev = probe.device();
    dev.stepMaster(7);
    dev.stepMaster(14);
    dev.flush();
    dev.reset();
    try std.testing.expectEqual(@as(u64, 21), probe.master_credit);
    try std.testing.expectEqual(@as(u32, 1), probe.flush_count);
    try std.testing.expectEqual(@as(u32, 1), probe.reset_count);
}
