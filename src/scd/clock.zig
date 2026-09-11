//! Sega CD sub-board timing constants and the master->sub clock converter.
//!
//! The sub-CPU runs from its own 12.5 MHz crystal, so its relation to the
//! Genesis master clock (53.693175 MHz NTSC / 53.203424 MHz PAL) is not a
//! small integer ratio. `SubSync` converts master-clock credit into whole
//! sub-CPU cycles with an exact rational remainder so long runs never drift.

const std = @import("std");
const genesis_clock = @import("../clock.zig");

pub const sub_clock_hz: u64 = 12_500_000;

/// Timer, stopwatch, and RF5C164 sample period in sub-CPU cycles
/// (12.5 MHz / 384 = 32,552.08 Hz).
pub const timer_divider: u32 = 384;

/// CDD/CDC sector cadence: 75 sectors per second.
pub const sector_rate_hz: u32 = 75;
pub const sub_cycles_per_sector_x75: u64 = sub_clock_hz; // 12.5M / 75 = 166,666.67

/// CD-DA sample rate.
pub const cdda_rate_hz: u32 = 44_100;

pub fn masterClockHz(pal_mode: bool) u64 {
    return if (pal_mode) genesis_clock.master_clock_pal else genesis_clock.master_clock_ntsc;
}

/// Exact master -> sub cycle conversion with carried remainder.
///
/// sub_cycles = master_cycles * sub_clock_hz / master_clock_hz
pub const SubSync = struct {
    master_clock_hz: u64,
    /// Accumulated master cycles not yet converted (< master_clock_hz / gcd).
    remainder: u64 = 0,
    /// Whole sub-CPU cycles available to run.
    credit: u64 = 0,
    /// Total sub cycles ever produced (monotonic, for timers).
    total_sub_cycles: u64 = 0,

    pub fn init(pal_mode: bool) SubSync {
        return .{ .master_clock_hz = masterClockHz(pal_mode) };
    }

    /// Add master-clock cycles; returns the number of new whole sub cycles.
    pub fn addMaster(self: *SubSync, master_cycles: u32) u64 {
        const numer = self.remainder + @as(u64, master_cycles) * sub_clock_hz;
        const whole = numer / self.master_clock_hz;
        self.remainder = numer % self.master_clock_hz;
        self.credit += whole;
        self.total_sub_cycles += whole;
        return whole;
    }

    pub fn consume(self: *SubSync, sub_cycles: u64) void {
        self.credit -= @min(self.credit, sub_cycles);
    }

    pub fn drain(self: *SubSync) void {
        self.credit = 0;
    }
};

const testing = std.testing;

test "master to sub conversion is exact over ten seconds" {
    var sync = SubSync.init(false);
    // 10 seconds of NTSC master cycles in one-scanline steps.
    const line: u32 = genesis_clock.ntsc_master_cycles_per_line;
    var master_total: u64 = 0;
    while (master_total + line <= 10 * genesis_clock.master_clock_ntsc) : (master_total += line) {
        _ = sync.addMaster(line);
    }
    // Remaining partial second.
    const tail: u32 = @intCast(10 * genesis_clock.master_clock_ntsc - master_total);
    _ = sync.addMaster(tail);
    try testing.expectEqual(@as(u64, 10 * sub_clock_hz), sync.total_sub_cycles);
    try testing.expectEqual(@as(u64, 0), sync.remainder);
}

test "pal master clock yields the same sub clock" {
    var sync = SubSync.init(true);
    _ = sync.addMaster(@intCast(genesis_clock.master_clock_pal));
    try testing.expectEqual(@as(u64, sub_clock_hz), sync.total_sub_cycles);
}

test "consume never underflows credit" {
    var sync = SubSync.init(false);
    _ = sync.addMaster(430); // ~100 sub cycles
    try testing.expectEqual(@as(u64, 100), sync.credit);
    sync.consume(150);
    try testing.expectEqual(@as(u64, 0), sync.credit);
}
