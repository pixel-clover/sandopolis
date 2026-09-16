//! Sega CD Word RAM: 256KB shared between the main and sub CPUs.
//!
//! Two physical 128KB banks. In 2M mode they appear as one linear 256KB
//! block, word-interleaved (even words bank 0, odd words bank 1), owned by
//! one CPU at a time (RET/DMNA handshake). In 1M mode each CPU owns one bank;
//! the sub-CPU additionally sees its bank as a nibble-per-byte "dot image"
//! and the main CPU sees its bank rearranged into VDP tile order as the
//! "cell image" (0x220000-0x23FFFF).

const std = @import("std");

pub const bank_bytes: u32 = 128 * 1024;
pub const total_bytes: u32 = 2 * bank_bytes;

pub const Mode = enum(u1) { two_m = 0, one_m = 1 };

/// Sub-CPU dot-image write priority (0xFF8003 bits 4-3).
pub const PriorityMode = enum(u2) {
    off = 0,
    /// Write only where the existing pixel is transparent (0).
    underwrite = 1,
    /// Write only non-transparent (non-zero) source pixels.
    overwrite = 2,
    prohibited = 3,
};

pub const WordRam = struct {
    banks: [2][bank_bytes]u8 = .{ [_]u8{0} ** bank_bytes, [_]u8{0} ** bank_bytes },
    mode: Mode = .two_m,
    /// 2M: 1 = main CPU owns the whole block, 0 = sub CPU owns it.
    /// 1M: selects which bank the main CPU owns (bank = ret); sub gets the other.
    ret: bool = true,
    /// 2M: main has requested handoff to sub (set by main, cleared when
    /// the sub returns the RAM). 1M: swap in progress (cleared at once here).
    dmna: bool = false,
    priority: PriorityMode = .off,

    // -- Ownership / handshake ---------------------------------------------

    pub fn mainOwns2M(self: *const WordRam) bool {
        return self.ret and !self.dmna;
    }

    pub fn subOwns2M(self: *const WordRam) bool {
        return !self.ret;
    }

    /// Main CPU writes DMNA=1 (0xA12003 bit 1).
    pub fn mainRequestHandoff(self: *WordRam) void {
        switch (self.mode) {
            .two_m => {
                self.dmna = true;
                self.ret = false;
            },
            .one_m => {
                // Bank swap request: completes immediately in this model.
                self.ret = !self.ret;
                self.dmna = false;
            },
        }
    }

    /// Sub CPU writes RET (0xFF8003 bit 0).
    pub fn subSetRet(self: *WordRam, value: bool) void {
        switch (self.mode) {
            .two_m => {
                if (value) {
                    self.ret = true;
                    self.dmna = false;
                }
            },
            .one_m => {
                self.ret = value;
                self.dmna = false;
            },
        }
    }

    /// Sub CPU writes MODE (0xFF8003 bit 2).
    pub fn subSetMode(self: *WordRam, mode: Mode) void {
        if (mode == self.mode) return;
        self.mode = mode;
        self.dmna = false;
    }

    /// Bank index the main CPU owns in 1M mode.
    pub fn mainBank1M(self: *const WordRam) u1 {
        return @intFromBool(self.ret);
    }

    pub fn subBank1M(self: *const WordRam) u1 {
        return @intFromBool(!self.ret);
    }

    // -- 2M linear view ------------------------------------------------------

    fn linearIndex(offset: u32) struct { bank: u1, index: usize } {
        const word = offset >> 1;
        return .{
            .bank = @intCast(word & 1),
            .index = @as(usize, (word >> 1) << 1) | (offset & 1),
        };
    }

    pub fn read8Linear(self: *const WordRam, offset: u32) u8 {
        const li = linearIndex(offset & (total_bytes - 1));
        return self.banks[li.bank][li.index];
    }

    pub fn write8Linear(self: *WordRam, offset: u32, value: u8) void {
        const li = linearIndex(offset & (total_bytes - 1));
        self.banks[li.bank][li.index] = value;
    }

    pub fn read16Linear(self: *const WordRam, offset: u32) u16 {
        const o = offset & (total_bytes - 1) & ~@as(u32, 1);
        return (@as(u16, self.read8Linear(o)) << 8) | self.read8Linear(o + 1);
    }

    pub fn write16Linear(self: *WordRam, offset: u32, value: u16) void {
        const o = offset & (total_bytes - 1) & ~@as(u32, 1);
        self.write8Linear(o, @truncate(value >> 8));
        self.write8Linear(o + 1, @truncate(value));
    }

    // -- 1M bank view --------------------------------------------------------

    pub fn read8Bank(self: *const WordRam, bank: u1, offset: u32) u8 {
        return self.banks[bank][offset & (bank_bytes - 1)];
    }

    pub fn write8Bank(self: *WordRam, bank: u1, offset: u32, value: u8) void {
        self.banks[bank][offset & (bank_bytes - 1)] = value;
    }

    pub fn read16Bank(self: *const WordRam, bank: u1, offset: u32) u16 {
        const o = offset & (bank_bytes - 1) & ~@as(u32, 1);
        return (@as(u16, self.banks[bank][o]) << 8) | self.banks[bank][o + 1];
    }

    pub fn write16Bank(self: *WordRam, bank: u1, offset: u32, value: u16) void {
        const o = offset & (bank_bytes - 1) & ~@as(u32, 1);
        self.banks[bank][o] = @truncate(value >> 8);
        self.banks[bank][o + 1] = @truncate(value);
    }

    // -- 1M dot image (sub CPU, 0x080000-0x0BFFFF) -------------------------

    /// One pixel per byte address: even addresses map to the high nibble.
    pub fn readDot(self: *const WordRam, bank: u1, dot_offset: u32) u8 {
        const byte = self.banks[bank][(dot_offset >> 1) & (bank_bytes - 1)];
        return if ((dot_offset & 1) != 0) byte & 0x0F else byte >> 4;
    }

    pub fn writeDot(self: *WordRam, bank: u1, dot_offset: u32, value: u8) void {
        const idx = (dot_offset >> 1) & (bank_bytes - 1);
        const prev = self.banks[bank][idx];
        const pixel: u8 = value & 0x0F;
        const old_pixel: u8 = if ((dot_offset & 1) != 0) prev & 0x0F else prev >> 4;
        const new_pixel = switch (self.priority) {
            .off, .prohibited => pixel,
            .underwrite => if (old_pixel == 0) pixel else old_pixel,
            .overwrite => if (pixel != 0) pixel else old_pixel,
        };
        self.banks[bank][idx] = if ((dot_offset & 1) != 0)
            (prev & 0xF0) | new_pixel
        else
            (prev & 0x0F) | (new_pixel << 4);
    }

    // -- 1M cell image (main CPU, 0x220000-0x23FFFF) -------------------------

    /// Translate a cell-image byte offset (0..0x1FFFF, relative to 0x220000)
    /// to a bank byte offset. The bitmap in Word RAM is row-major with 256
    /// bytes (512 pixels) per line; the cell image presents it as
    /// consecutive 32-byte VDP tiles stacked column by column.
    ///
    /// Regions: 0x00000-0x0FFFF V32 (32 cells tall), 0x10000-0x17FFF V16,
    /// 0x18000-0x1BFFF V8, 0x1C000-0x1DFFF V4, 0x1E000-0x1FFFF V4.
    pub fn cellImageToBank(cell_offset: u32) u32 {
        const c = cell_offset & (bank_bytes - 1);
        const region: struct { base: u32, y_bits: u5 } = if (c < 0x10000)
            .{ .base = 0x00000, .y_bits = 5 }
        else if (c < 0x18000)
            .{ .base = 0x10000, .y_bits = 4 }
        else if (c < 0x1C000)
            .{ .base = 0x18000, .y_bits = 3 }
        else if (c < 0x1E000)
            .{ .base = 0x1C000, .y_bits = 2 }
        else
            .{ .base = 0x1E000, .y_bits = 2 };

        const unit = (c - region.base) >> 2; // 4 bytes per cell line
        const vline = unit & 7;
        const y_mask = (@as(u32, 1) << region.y_bits) - 1;
        const y = (unit >> 3) & y_mask;
        const x = (unit >> (3 + region.y_bits)) & 0x3F;
        return region.base | (vline << 8) | (x << 2) | (y << 11) | (c & 3);
    }

    pub fn readCell8(self: *const WordRam, bank: u1, cell_offset: u32) u8 {
        return self.banks[bank][cellImageToBank(cell_offset)];
    }

    pub fn writeCell8(self: *WordRam, bank: u1, cell_offset: u32, value: u8) void {
        self.banks[bank][cellImageToBank(cell_offset)] = value;
    }

    pub fn readCell16(self: *const WordRam, bank: u1, cell_offset: u32) u16 {
        const o = cell_offset & ~@as(u32, 1);
        return (@as(u16, self.readCell8(bank, o)) << 8) | self.readCell8(bank, o + 1);
    }

    pub fn writeCell16(self: *WordRam, bank: u1, cell_offset: u32, value: u16) void {
        const o = cell_offset & ~@as(u32, 1);
        self.writeCell8(bank, o, @truncate(value >> 8));
        self.writeCell8(bank, o + 1, @truncate(value));
    }
};

const testing = std.testing;

test "2M handshake: main hands off with DMNA, sub returns with RET" {
    var wr = WordRam{};
    try testing.expect(wr.mainOwns2M());
    try testing.expect(!wr.subOwns2M());

    wr.mainRequestHandoff();
    try testing.expect(!wr.ret);
    try testing.expect(wr.dmna);
    try testing.expect(wr.subOwns2M());
    try testing.expect(!wr.mainOwns2M());

    // Sub writing RET=0 in 2M mode changes nothing.
    wr.subSetRet(false);
    try testing.expect(wr.subOwns2M());

    wr.subSetRet(true);
    try testing.expect(wr.ret);
    try testing.expect(!wr.dmna);
    try testing.expect(wr.mainOwns2M());
}

test "1M mode swaps banks on DMNA and follows RET" {
    var wr = WordRam{};
    wr.subSetMode(.one_m);
    try testing.expectEqual(@as(u1, 1), wr.mainBank1M());
    try testing.expectEqual(@as(u1, 0), wr.subBank1M());

    wr.mainRequestHandoff();
    try testing.expectEqual(@as(u1, 0), wr.mainBank1M());
    try testing.expectEqual(@as(u1, 1), wr.subBank1M());
    try testing.expect(!wr.dmna);

    wr.subSetRet(true);
    try testing.expectEqual(@as(u1, 1), wr.mainBank1M());
    wr.subSetRet(false);
    try testing.expectEqual(@as(u1, 0), wr.mainBank1M());
}

test "2M linear view interleaves the two banks by word" {
    var wr = WordRam{};
    wr.write16Linear(0x00000, 0x1122); // word 0 -> bank 0 word 0
    wr.write16Linear(0x00002, 0x3344); // word 1 -> bank 1 word 0
    wr.write16Linear(0x00004, 0x5566); // word 2 -> bank 0 word 1
    wr.write8Linear(0x00007, 0x99); //  word 3 low byte -> bank 1 byte 3
    try testing.expectEqual(@as(u16, 0x1122), wr.read16Bank(0, 0));
    try testing.expectEqual(@as(u16, 0x3344), wr.read16Bank(1, 0));
    try testing.expectEqual(@as(u16, 0x5566), wr.read16Bank(0, 2));
    try testing.expectEqual(@as(u8, 0x99), wr.read8Bank(1, 3));
    try testing.expectEqual(@as(u16, 0x1122), wr.read16Linear(0));
    try testing.expectEqual(@as(u8, 0x44), wr.read8Linear(3));
    // Address wraps at 256KB.
    try testing.expectEqual(@as(u16, 0x1122), wr.read16Linear(0x40000));
}

test "dot image addresses one nibble per byte with priority modes" {
    var wr = WordRam{};
    wr.writeDot(0, 0, 0xA); // high nibble of byte 0
    wr.writeDot(0, 1, 0x5); // low nibble of byte 0
    try testing.expectEqual(@as(u8, 0xA5), wr.read8Bank(0, 0));
    try testing.expectEqual(@as(u8, 0xA), wr.readDot(0, 0));
    try testing.expectEqual(@as(u8, 0x5), wr.readDot(0, 1));
    // Only the low nibble of the written value is used.
    wr.writeDot(0, 2, 0xF7);
    try testing.expectEqual(@as(u8, 0x70), wr.read8Bank(0, 1));

    wr.priority = .underwrite;
    wr.writeDot(0, 0, 0x3); // existing 0xA: kept
    wr.writeDot(0, 3, 0x3); // existing 0: written
    try testing.expectEqual(@as(u8, 0xA), wr.readDot(0, 0));
    try testing.expectEqual(@as(u8, 0x3), wr.readDot(0, 3));

    wr.priority = .overwrite;
    wr.writeDot(0, 0, 0x0); // transparent source: kept
    wr.writeDot(0, 0, 0x6); // opaque source: written
    try testing.expectEqual(@as(u8, 0x6), wr.readDot(0, 0));

    // Dot image spans 256KB of addresses over a 128KB bank.
    wr.priority = .off;
    wr.writeDot(1, 0x3FFFF, 0xC);
    try testing.expectEqual(@as(u8, 0x0C), wr.read8Bank(1, 0x1FFFF));
}

test "cell image maps VDP tile order onto the row-major bitmap" {
    // V32 region: cell (x, y) line v, byte b lives at bitmap offset
    // (y*8 + v) * 256 + x*4 + b. Cell image lists cells column by column
    // (x major), 32 bytes per cell.
    const cell = struct {
        fn at(x: u32, y: u32, v: u32, b: u32) u32 {
            return ((x * 32 + y) * 8 + v) * 4 + b; // = (x*32+y)*32 + v*4 + b
        }
    };
    try testing.expectEqual(@as(u32, 0), WordRam.cellImageToBank(cell.at(0, 0, 0, 0)));
    try testing.expectEqual(@as(u32, 3), WordRam.cellImageToBank(cell.at(0, 0, 0, 3)));
    try testing.expectEqual(@as(u32, 256), WordRam.cellImageToBank(cell.at(0, 0, 1, 0)));
    try testing.expectEqual(@as(u32, 4), WordRam.cellImageToBank(cell.at(1, 0, 0, 0)));
    try testing.expectEqual(@as(u32, 8 * 256), WordRam.cellImageToBank(cell.at(0, 1, 0, 0)));
    try testing.expectEqual(@as(u32, 31 * 8 * 256 + 7 * 256 + 63 * 4 + 3), WordRam.cellImageToBank(cell.at(63, 31, 7, 3)));

    // V16 region starts at 0x10000 in both spaces; 16 cells tall.
    try testing.expectEqual(@as(u32, 0x10000), WordRam.cellImageToBank(0x10000));
    try testing.expectEqual(@as(u32, 0x10000 + 4), WordRam.cellImageToBank(0x10000 + 16 * 32));
    try testing.expectEqual(@as(u32, 0x10000 + 8 * 256), WordRam.cellImageToBank(0x10000 + 32));
    // V8 (0x18000): 8 cells tall, so x advances every 8 cells.
    try testing.expectEqual(@as(u32, 0x18000 + 4), WordRam.cellImageToBank(0x18000 + 8 * 32));
    // V4 (0x1C000 and its 0x1E000 twin): 4 cells tall.
    try testing.expectEqual(@as(u32, 0x1C000 + 4), WordRam.cellImageToBank(0x1C000 + 4 * 32));
    try testing.expectEqual(@as(u32, 0x1E000 + 4), WordRam.cellImageToBank(0x1E000 + 4 * 32));

    // Every cell-image byte maps to a distinct bank byte (bijection).
    var wr = WordRam{};
    var seen = [_]bool{false} ** bank_bytes;
    var c: u32 = 0;
    while (c < bank_bytes) : (c += 1) {
        const o = WordRam.cellImageToBank(c);
        try testing.expect(!seen[o]);
        seen[o] = true;
    }
    wr.writeCell16(0, 0x220000 & 0x1FFFF, 0xBEEF);
    try testing.expectEqual(@as(u16, 0xBEEF), wr.readCell16(0, 0));
    try testing.expectEqual(@as(u8, 0xBE), wr.read8Bank(0, 0));
}
