//! CDC: Sanyo LC8951 CD data controller with 16KB buffer RAM.
//!
//! Registers are reached through the gate array's register-address
//! (0xFF8005, auto-incrementing) and register-data (0xFF8007) ports. Once
//! per sector the decoder stores the block header and user data into the
//! buffer (when DECEN and WRRQ are set) and raises the decoder interrupt.
//! A data transfer (DTTRG) moves DBC+1 bytes from DAC either to a host
//! port read a word at a time (main 0xA12008 / sub 0xFF8008) or by DMA to
//! PCM RAM, PRG-RAM, or Word RAM.

const std = @import("std");
const reader = @import("cdrom/reader.zig");

pub const buffer_bytes: u32 = 16 * 1024;

/// IFSTAT bits are active-low.
pub const Ifstat = struct {
    pub const sten: u8 = 0x01;
    pub const dten: u8 = 0x02;
    pub const stbsy: u8 = 0x04;
    pub const dtbsy: u8 = 0x08;
    pub const deci: u8 = 0x20;
    pub const dtei: u8 = 0x40;
    pub const cmdi: u8 = 0x80;
};

pub const Ifctrl = struct {
    pub const souten: u8 = 0x01;
    pub const douten: u8 = 0x02;
    pub const stwai: u8 = 0x04;
    pub const dtwai: u8 = 0x08;
    pub const cmdbk: u8 = 0x10;
    pub const decien: u8 = 0x20;
    pub const dteien: u8 = 0x40;
    pub const cmdien: u8 = 0x80;
};

pub const Ctrl0 = struct {
    pub const prq: u8 = 0x01;
    pub const qrq: u8 = 0x02;
    pub const wrrq: u8 = 0x04;
    pub const eramrq: u8 = 0x08;
    pub const autorq: u8 = 0x10;
    pub const e01rq: u8 = 0x20;
    pub const edcrq: u8 = 0x40;
    pub const decen: u8 = 0x80;
};

/// Device destination selected by the gate array CDC mode register (DD2-0).
pub const Destination = enum(u3) {
    none0 = 0,
    none1 = 1,
    main_read = 2,
    sub_read = 3,
    pcm_ram = 4,
    prg_ram = 5,
    none6 = 6,
    word_ram = 7,
};

/// Where DMA bytes go; supplied by the board.
pub const DmaSink = struct {
    ctx: *anyopaque,
    /// Write `data` starting at `address` on the destination device.
    writeFn: *const fn (*anyopaque, Destination, u32, []const u8) void,
};

pub const Cdc = struct {
    ram: [buffer_bytes]u8 = [_]u8{0} ** buffer_bytes,

    // Register file (indexed by RS).
    ifstat: u8 = 0xFF,
    ifctrl: u8 = 0,
    dbc: u16 = 0,
    dac: u16 = 0,
    head: [4]u8 = .{ 0, 0, 0, 0 },
    pt: u16 = 0,
    wa: u16 = 0,
    ctrl: [3]u8 = .{ 0, 0, 0 },
    stat: [4]u8 = .{ 0, 0, 0, 0x80 },
    comin: u8 = 0,
    sbout: u8 = 0,

    /// Host-read transfer in progress (DSR asserted, words popped by the
    /// host port until DBC is exhausted).
    host_transfer_active: bool = false,
    /// Interrupt line to the gate array (INT5), level-held.
    irq_asserted: bool = false,
    /// Set when a transfer finished (EDT in the gate array mode register).
    end_of_transfer: bool = false,

    pub fn reset(self: *Cdc) void {
        const ram = self.ram;
        self.* = .{};
        self.ram = ram;
    }

    // -----------------------------------------------------------------------
    // Register access through the gate array ports
    // -----------------------------------------------------------------------

    pub fn readRegister(self: *Cdc, rs: u4) u8 {
        return switch (rs) {
            0x0 => self.comin,
            0x1 => self.ifstat,
            0x2 => @truncate(self.dbc),
            0x3 => @truncate(self.dbc >> 8),
            0x4 => self.head[0],
            0x5 => self.head[1],
            0x6 => self.head[2],
            0x7 => self.head[3],
            0x8 => @truncate(self.pt),
            0x9 => @truncate(self.pt >> 8),
            0xA => @truncate(self.wa),
            0xB => @truncate(self.wa >> 8),
            0xC => self.stat[0],
            0xD => self.stat[1],
            0xE => self.stat[2],
            0xF => blk: {
                // Reading STAT3 acknowledges the decoder interrupt.
                self.ifstat |= Ifstat.deci;
                self.updateIrq();
                break :blk self.stat[3];
            },
        };
    }

    pub fn writeRegister(self: *Cdc, rs: u4, value: u8) void {
        switch (rs) {
            0x0 => self.sbout = value,
            0x1 => {
                self.ifctrl = value;
                self.updateIrq();
            },
            0x2 => self.dbc = (self.dbc & 0xFF00) | value,
            0x3 => self.dbc = (self.dbc & 0x00FF) | (@as(u16, value & 0x0F) << 8),
            0x4 => self.dac = (self.dac & 0xFF00) | value,
            0x5 => self.dac = (self.dac & 0x00FF) | (@as(u16, value) << 8),
            0x6 => self.triggerTransfer(),
            0x7 => {
                // DTACK: acknowledge data transfer end.
                self.ifstat |= Ifstat.dtei;
                self.updateIrq();
            },
            0x8 => self.wa = (self.wa & 0xFF00) | value,
            0x9 => self.wa = (self.wa & 0x00FF) | (@as(u16, value) << 8),
            0xA => self.ctrl[0] = value,
            0xB => self.ctrl[1] = value,
            0xC => self.pt = (self.pt & 0xFF00) | value,
            0xD => self.pt = (self.pt & 0x00FF) | (@as(u16, value) << 8),
            0xE => self.ctrl[2] = value,
            0xF => self.reset(),
        }
    }

    fn updateIrq(self: *Cdc) void {
        const deci_active = (self.ifstat & Ifstat.deci) == 0 and (self.ifctrl & Ifctrl.decien) != 0;
        const dtei_active = (self.ifstat & Ifstat.dtei) == 0 and (self.ifctrl & Ifctrl.dteien) != 0;
        self.irq_asserted = deci_active or dtei_active;
    }

    // -----------------------------------------------------------------------
    // Decoder (one raw sector per 75 Hz tick)
    // -----------------------------------------------------------------------

    /// Store a decoded block. Returns true when INT5 should be raised
    /// (decoder interrupt newly asserted).
    pub fn decodeSector(self: *Cdc, raw: *const [reader.raw_sector_bytes]u8) bool {
        if ((self.ctrl[0] & Ctrl0.decen) == 0) return false;

        @memcpy(&self.head, raw[12..16]);
        self.stat[3] = 0x00; // !VALST: header valid
        const was_asserted = self.irq_asserted;
        self.ifstat &= ~Ifstat.deci;
        self.updateIrq();

        if ((self.ctrl[0] & Ctrl0.wrrq) != 0) {
            self.pt +%= 2352;
            self.wa +%= 2352;
            var offset: u32 = self.pt & (buffer_bytes - 1);
            self.writeWrapped(offset, raw[12..16]);
            offset += 4;
            if (raw[15] == 0x01) {
                self.writeWrapped(offset, raw[16 .. 16 + 2048]);
            } else {
                // Mode 2: subheader + data (2336 bytes).
                self.writeWrapped(offset, raw[16 .. 16 + 2336]);
            }
        }
        return self.irq_asserted and !was_asserted;
    }

    fn writeWrapped(self: *Cdc, start: u32, data: []const u8) void {
        var offset = start & (buffer_bytes - 1);
        for (data) |b| {
            self.ram[offset] = b;
            offset = (offset + 1) & (buffer_bytes - 1);
        }
    }

    // -----------------------------------------------------------------------
    // Data transfer
    // -----------------------------------------------------------------------

    /// DTTRG: begin moving DBC+1 bytes from DAC. Host destinations expose
    /// the data through `hostRead`; DMA destinations complete when the board
    /// calls `runDma`.
    fn triggerTransfer(self: *Cdc) void {
        if ((self.ifctrl & Ifctrl.douten) == 0) return;
        self.ifstat &= ~Ifstat.dten;
        self.ifstat &= ~Ifstat.dtbsy;
        self.host_transfer_active = true;
        self.end_of_transfer = false;
    }

    pub fn transferPending(self: *const Cdc) bool {
        return self.host_transfer_active;
    }

    /// Data Set Ready for the host port: a transfer is active and bytes remain.
    pub fn dataSetReady(self: *const Cdc) bool {
        return self.host_transfer_active;
    }

    /// Pop one word for the main/sub host data port. Returns true in
    /// `.raise_irq` when the transfer just completed with DTEIEN set.
    pub const HostRead = struct { word: u16, raise_irq: bool };

    pub fn hostRead(self: *Cdc) HostRead {
        if (!self.host_transfer_active) return .{ .word = 0xFFFF, .raise_irq = false };
        const a = self.dac & (buffer_bytes - 1);
        const word = (@as(u16, self.ram[a]) << 8) | self.ram[(a + 1) & (buffer_bytes - 1)];
        self.dac +%= 2;
        var raise = false;
        if (self.dbc < 2) {
            self.dbc = 0;
            raise = self.finishTransfer();
        } else {
            self.dbc -= 2;
        }
        return .{ .word = word, .raise_irq = raise };
    }

    /// Complete a DMA transfer to `destination` at `address` in one step.
    /// Returns true when INT5 should be raised.
    pub fn runDma(self: *Cdc, destination: Destination, address: u32, sink: DmaSink) bool {
        if (!self.host_transfer_active) return false;
        const length: u32 = @as(u32, self.dbc) + 1;
        var remaining = length;
        var dst = address;
        var chunk: [256]u8 = undefined;
        while (remaining > 0) {
            const n: u32 = @min(remaining, chunk.len);
            var i: u32 = 0;
            while (i < n) : (i += 1) {
                chunk[i] = self.ram[(self.dac +% @as(u16, @intCast(i))) & (buffer_bytes - 1)];
            }
            sink.writeFn(sink.ctx, destination, dst, chunk[0..n]);
            self.dac +%= @intCast(n);
            dst += n;
            remaining -= n;
        }
        self.dbc = 0;
        return self.finishTransfer();
    }

    fn finishTransfer(self: *Cdc) bool {
        self.host_transfer_active = false;
        self.end_of_transfer = true;
        self.ifstat |= Ifstat.dten | Ifstat.dtbsy;
        const was_asserted = self.irq_asserted;
        self.ifstat &= ~Ifstat.dtei;
        self.updateIrq();
        return self.irq_asserted and !was_asserted;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn makeRawSector(seed: u8) [reader.raw_sector_bytes]u8 {
    var raw: [reader.raw_sector_bytes]u8 = undefined;
    for (&raw, 0..) |*b, i| b.* = @truncate(i +% seed);
    @memcpy(raw[0..12], &reader.sync_bytes);
    raw[12] = 0x00;
    raw[13] = 0x02;
    raw[14] = 0x16;
    raw[15] = 0x01;
    return raw;
}

test "register file reads back writes with the DBC high nibble mask" {
    var cdc = Cdc{};
    cdc.writeRegister(0x2, 0x34);
    cdc.writeRegister(0x3, 0xF2); // only low nibble kept
    try testing.expectEqual(@as(u16, 0x0234), cdc.dbc);
    try testing.expectEqual(@as(u8, 0x34), cdc.readRegister(0x2));
    try testing.expectEqual(@as(u8, 0x02), cdc.readRegister(0x3));
    cdc.writeRegister(0x8, 0x00);
    cdc.writeRegister(0x9, 0x10);
    try testing.expectEqual(@as(u16, 0x1000), cdc.wa);
    cdc.writeRegister(0xA, Ctrl0.decen | Ctrl0.wrrq);
    try testing.expectEqual(Ctrl0.decen | Ctrl0.wrrq, cdc.ctrl[0]);
    try testing.expectEqual(@as(u8, 0xFF), cdc.readRegister(0x1));
    // RESET clears registers but keeps buffer contents.
    cdc.ram[5] = 0xAA;
    cdc.writeRegister(0xF, 0);
    try testing.expectEqual(@as(u16, 0), cdc.wa);
    try testing.expectEqual(@as(u8, 0xAA), cdc.ram[5]);
}

test "decoder stores header and data at the advanced block pointer and raises DECI" {
    var cdc = Cdc{};
    cdc.writeRegister(0xA, Ctrl0.decen | Ctrl0.wrrq);
    cdc.writeRegister(0x1, Ifctrl.decien);
    // Start with PT = WA = 0x3FF0 so the first block wraps to 0x0930.
    cdc.pt = 0x0000;
    cdc.wa = 0x0000;

    const raw = makeRawSector(7);
    try testing.expect(cdc.decodeSector(&raw));
    try testing.expectEqual(@as(u16, 2352), cdc.pt);
    try testing.expectEqual(@as(u16, 2352), cdc.wa);
    try testing.expectEqualSlices(u8, raw[12..16], &cdc.head);
    try testing.expectEqualSlices(u8, raw[12..16], cdc.ram[2352 .. 2352 + 4]);
    try testing.expectEqualSlices(u8, raw[16 .. 16 + 2048], cdc.ram[2352 + 4 .. 2352 + 4 + 2048]);
    try testing.expectEqual(@as(u8, 0), cdc.ifstat & Ifstat.deci);
    try testing.expect(cdc.irq_asserted);
    // A second block while DECI is still pending does not re-raise.
    try testing.expect(!cdc.decodeSector(&raw));
    // Reading STAT3 acknowledges.
    _ = cdc.readRegister(0xF);
    try testing.expect(!cdc.irq_asserted);
    try testing.expect(cdc.decodeSector(&raw));

    // Decoder disabled: nothing happens.
    var off = Cdc{};
    try testing.expect(!off.decodeSector(&raw));
    try testing.expectEqual(@as(u16, 0), off.pt);
}

test "host transfer pops words from DAC and ends with EDT and DTEI" {
    var cdc = Cdc{};
    for (&cdc.ram, 0..) |*b, i| b.* = @truncate(i);
    cdc.writeRegister(0x1, Ifctrl.douten | Ifctrl.dteien);
    cdc.writeRegister(0x4, 0x04); // DAC = 0x0104
    cdc.writeRegister(0x5, 0x01);
    cdc.writeRegister(0x2, 0x05); // DBC = 5 -> 6 bytes = 3 words
    cdc.writeRegister(0x3, 0x00);
    try testing.expect(!cdc.dataSetReady());
    cdc.writeRegister(0x6, 0); // DTTRG
    try testing.expect(cdc.dataSetReady());
    try testing.expectEqual(@as(u8, 0), cdc.ifstat & Ifstat.dten);

    var r = cdc.hostRead();
    try testing.expectEqual(@as(u16, 0x0405), r.word);
    try testing.expect(!r.raise_irq);
    r = cdc.hostRead();
    try testing.expectEqual(@as(u16, 0x0607), r.word);
    r = cdc.hostRead();
    try testing.expectEqual(@as(u16, 0x0809), r.word);
    try testing.expect(r.raise_irq);
    try testing.expect(cdc.end_of_transfer);
    try testing.expect(!cdc.dataSetReady());
    try testing.expectEqual(@as(u8, 0), cdc.ifstat & Ifstat.dtei);
    // DTACK clears DTEI.
    cdc.writeRegister(0x7, 0);
    try testing.expectEqual(Ifstat.dtei, cdc.ifstat & Ifstat.dtei);
    try testing.expect(!cdc.irq_asserted);
    // Reads after completion return 0xFFFF.
    try testing.expectEqual(@as(u16, 0xFFFF), cdc.hostRead().word);
}

test "dma transfer delivers DBC+1 bytes to the sink and wraps the buffer" {
    const Sink = struct {
        dest: ?Destination = null,
        base: u32 = 0,
        bytes: [64]u8 = [_]u8{0} ** 64,
        count: usize = 0,

        fn write(ctx: *anyopaque, destination: Destination, address: u32, data: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (self.dest == null) {
                self.dest = destination;
                self.base = address;
            }
            for (data) |b| {
                self.bytes[self.count] = b;
                self.count += 1;
            }
        }
    };
    var sink = Sink{};
    var cdc = Cdc{};
    for (&cdc.ram, 0..) |*b, i| b.* = @truncate(i * 3);
    cdc.writeRegister(0x1, Ifctrl.douten);
    cdc.dac = 0x3FFC; // wraps after 4 bytes
    cdc.dbc = 7; // 8 bytes
    cdc.writeRegister(0x6, 0);
    const raise = cdc.runDma(.word_ram, 0x1000, .{ .ctx = &sink, .writeFn = Sink.write });
    try testing.expect(!raise); // DTEIEN clear
    try testing.expectEqual(Destination.word_ram, sink.dest.?);
    try testing.expectEqual(@as(u32, 0x1000), sink.base);
    try testing.expectEqual(@as(usize, 8), sink.count);
    try testing.expectEqualSlices(u8, cdc.ram[0x3FFC..0x4000], sink.bytes[0..4]);
    try testing.expectEqualSlices(u8, cdc.ram[0..4], sink.bytes[4..8]);
    try testing.expect(cdc.end_of_transfer);
    try testing.expectEqual(@as(u16, 0), cdc.dbc);
}
