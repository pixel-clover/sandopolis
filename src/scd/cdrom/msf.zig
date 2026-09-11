//! CD time addressing: minute/second/frame (MSF) <-> logical block address.
//!
//! 75 sectors per second, 60 seconds per minute. Absolute MSF on a disc
//! starts 2 seconds (150 sectors) before LBA 0, so LBA 0 == 00:02:00.
//! The CDD exchanges times as BCD nibbles.

const std = @import("std");

pub const sectors_per_second: u32 = 75;
pub const sectors_per_minute: u32 = 60 * sectors_per_second;
/// Sectors in the lead-in pregap that precede LBA 0.
pub const pregap_sectors: u32 = 150;

pub const Msf = struct {
    m: u8,
    s: u8,
    f: u8,

    pub fn toSectors(self: Msf) u32 {
        return @as(u32, self.m) * sectors_per_minute + @as(u32, self.s) * sectors_per_second + self.f;
    }

    pub fn fromSectors(total: u32) Msf {
        return .{
            .m = @intCast(total / sectors_per_minute),
            .s = @intCast((total % sectors_per_minute) / sectors_per_second),
            .f = @intCast(total % sectors_per_second),
        };
    }
};

/// Absolute disc time for a logical block address.
pub fn lbaToMsf(lba: u32) Msf {
    return Msf.fromSectors(lba + pregap_sectors);
}

/// Logical block address for an absolute disc time. Times inside the
/// lead-in pregap clamp to LBA 0.
pub fn msfToLba(msf: Msf) u32 {
    const total = msf.toSectors();
    return if (total < pregap_sectors) 0 else total - pregap_sectors;
}

pub fn toBcd(value: u8) u8 {
    return @intCast(((value / 10) << 4) | (value % 10));
}

pub fn fromBcd(value: u8) u8 {
    return @intCast((value >> 4) * 10 + (value & 0x0F));
}

const testing = std.testing;

test "lba to msf includes the two second pregap" {
    try testing.expectEqual(Msf{ .m = 0, .s = 2, .f = 0 }, lbaToMsf(0));
    try testing.expectEqual(Msf{ .m = 0, .s = 2, .f = 74 }, lbaToMsf(74));
    try testing.expectEqual(Msf{ .m = 0, .s = 3, .f = 0 }, lbaToMsf(75));
    try testing.expectEqual(Msf{ .m = 1, .s = 2, .f = 0 }, lbaToMsf(4500));
    try testing.expectEqual(Msf{ .m = 74, .s = 0, .f = 0 }, lbaToMsf(74 * 4500 - 150));
}

test "msf to lba round trips and clamps the pregap" {
    var lba: u32 = 0;
    while (lba < 400_000) : (lba += 7919) {
        try testing.expectEqual(lba, msfToLba(lbaToMsf(lba)));
    }
    try testing.expectEqual(@as(u32, 0), msfToLba(.{ .m = 0, .s = 0, .f = 0 }));
    try testing.expectEqual(@as(u32, 0), msfToLba(.{ .m = 0, .s = 1, .f = 74 }));
    try testing.expectEqual(@as(u32, 1), msfToLba(.{ .m = 0, .s = 2, .f = 1 }));
}

test "bcd conversion" {
    try testing.expectEqual(@as(u8, 0x00), toBcd(0));
    try testing.expectEqual(@as(u8, 0x09), toBcd(9));
    try testing.expectEqual(@as(u8, 0x10), toBcd(10));
    try testing.expectEqual(@as(u8, 0x74), toBcd(74));
    try testing.expectEqual(@as(u8, 0x99), toBcd(99));
    var v: u8 = 0;
    while (v < 100) : (v += 1) try testing.expectEqual(v, fromBcd(toBcd(v)));
}
