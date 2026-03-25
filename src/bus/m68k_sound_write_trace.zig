pub const max_entries: usize = 16 * 1024;

pub const Kind = enum(u8) {
    z80_window,
    bus_request,
    reset,
};

pub const Outcome = enum(u8) {
    applied,
    blocked_no_bus,
    ignored_host_misc,
    ignored_odd_control_byte,
};

pub const Entry = struct {
    address: u32,
    value: u32,
    access_master_offset: u32,
    opcode: u16,
    busack: u16,
    reset: u16,
    size_bytes: u8,
    kind: Kind,
    outcome: Outcome,
};

pub const Trace = struct {
    enabled: bool = false,
    count: usize = 0,
    dropped: u32 = 0,
    entries: [max_entries]Entry = undefined,

    pub fn clear(self: *Trace) void {
        self.count = 0;
        self.dropped = 0;
    }

    pub fn setEnabled(self: *Trace, enabled: bool) void {
        self.enabled = enabled;
    }

    pub fn entriesSlice(self: *const Trace) []const Entry {
        return self.entries[0..self.count];
    }

    pub fn record(
        self: *Trace,
        address: u32,
        value: u32,
        access_master_offset: u32,
        opcode: u16,
        busack: u16,
        reset: u16,
        size_bytes: u8,
        kind: Kind,
        outcome: Outcome,
    ) void {
        if (!self.enabled) return;

        if (self.count >= self.entries.len) {
            self.dropped += 1;
            return;
        }

        self.entries[self.count] = .{
            .address = address & 0xFFFFFF,
            .value = value,
            .access_master_offset = access_master_offset,
            .opcode = opcode,
            .busack = busack,
            .reset = reset,
            .size_bytes = size_bytes,
            .kind = kind,
            .outcome = outcome,
        };
        self.count += 1;
    }
};
