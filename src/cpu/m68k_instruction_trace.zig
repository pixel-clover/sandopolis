pub const max_entries: usize = 8192;

pub const Entry = struct {
    ppc: u32,
    pc_after: u32,
    cycles: u64,
    sr: u16,
    ir: u16,
    exception_thrown: i32,
    halted: bool,
};

pub const Trace = struct {
    enabled: bool = false,
    stop_on_fault: bool = false,
    frozen: bool = false,
    count: usize = 0,
    dropped: u32 = 0,
    entries: [max_entries]Entry = undefined,

    pub fn clear(self: *Trace) void {
        self.frozen = false;
        self.count = 0;
        self.dropped = 0;
    }

    pub fn setEnabled(self: *Trace, enabled: bool) void {
        self.enabled = enabled;
        if (!enabled) self.frozen = false;
    }

    pub fn setStopOnFault(self: *Trace, stop_on_fault: bool) void {
        self.stop_on_fault = stop_on_fault;
        if (!stop_on_fault) self.frozen = false;
    }

    pub fn entriesSlice(self: *const Trace) []const Entry {
        return self.entries[0..self.count];
    }

    pub fn record(
        self: *Trace,
        ppc: u32,
        pc_after: u32,
        cycles: u64,
        sr: u16,
        ir: u16,
        exception_thrown: i32,
        halted: bool,
    ) void {
        if (!self.enabled) return;
        if (self.frozen) return;

        if (self.count >= self.entries.len) {
            self.dropped += 1;
            return;
        }

        self.entries[self.count] = .{
            .ppc = ppc,
            .pc_after = pc_after,
            .cycles = cycles,
            .sr = sr,
            .ir = ir,
            .exception_thrown = exception_thrown,
            .halted = halted,
        };
        self.count += 1;

        if (self.stop_on_fault and (exception_thrown != 0 or pc_after == 0xFFFF_FFFF)) {
            self.frozen = true;
        }
    }
};

test "m68k instruction trace can freeze on the first fault" {
    const testing = @import("std").testing;

    var trace = Trace{};
    trace.setStopOnFault(true);
    trace.setEnabled(true);

    trace.record(0x10, 0x12, 8, 0x2000, 0x4E71, 0, false);
    trace.record(0x12, 0xFFFF_FFFF, 42, 0x2004, 0xFFFF, 11, false);
    trace.record(0xFFFF_FFFF, 0xFFFF_FFFF, 50, 0x2004, 0x0000, 11, false);

    const entries = trace.entriesSlice();
    try testing.expectEqual(@as(usize, 2), entries.len);
    try testing.expectEqual(@as(u32, 0x10), entries[0].ppc);
    try testing.expectEqual(@as(u32, 0x12), entries[1].ppc);
    try testing.expectEqual(@as(i32, 11), entries[1].exception_thrown);
}
