//! Sega CD graphics ASIC stamp-map renderer.

const std = @import("std");
const WordRam = @import("word_ram.zig").WordRam;

pub const Gfx = struct {
    active: bool = false,
    cycle_credit: u32 = 0,
    trace_address: u32 = 0,
    buffer_address: u32 = 0,

    pub fn reset(self: *Gfx) void {
        self.* = .{};
    }

    pub fn start(self: *Gfx, regs: *[8]u16) void {
        self.active = (regs[6] & 0x00FF) != 0;
        self.cycle_credit = 0;
        self.trace_address = (@as(u32, regs[7]) << 2) & 0x3FFF8;
        self.buffer_address = (@as(u32, regs[3]) << 3) & 0x7FFC0;
        if (self.active) regs[0] |= 0x8000 else regs[0] &= 0x7FFF;
    }

    /// Returns true once the current operation has finished.
    pub fn advance(self: *Gfx, cycles: u32, regs: *[8]u16, ram: *WordRam) bool {
        if (!self.active) return false;
        self.cycle_credit +|= cycles;
        const width = regs[5] & 0x01FF;
        const line_cycles = 12 * (4 + 2 * @as(u32, width) + ((@as(u32, width) + (regs[4] & 3) + 3) >> 2));
        while (self.active and self.cycle_credit >= line_cycles) {
            self.cycle_credit -= line_cycles;
            self.renderLine(regs, ram);
            const remaining: u8 = @truncate(regs[6]);
            regs[6] = (regs[6] & 0xFF00) | (remaining - 1);
            if (remaining == 1) {
                self.active = false;
                regs[0] &= 0x7FFF;
                return true;
            }
        }
        return false;
    }

    fn renderLine(self: *Gfx, regs: *const [8]u16, ram: *WordRam) void {
        var x = @as(u32, read16(ram, self.trace_address)) << 8;
        var y = @as(u32, read16(ram, self.trace_address + 2)) << 8;
        const dx: i32 = @as(i16, @bitCast(read16(ram, self.trace_address + 4)));
        const dy: i32 = @as(i16, @bitCast(read16(ram, self.trace_address + 6)));
        self.trace_address = (self.trace_address + 8) & 0x3FFFF;

        var output = self.buffer_address + (regs[4] & 0x003F);
        const column_stride = ((@as(u32, regs[2] & 0x001F) + 1) << 6) - 7;
        var i: u32 = 0;
        while (i < (regs[5] & 0x01FF)) : (i += 1) {
            writeDot(ram, output, sourcePixel(ram, regs, x, y));
            output += if ((output & 7) == 7) column_stride else 1;
            x = @bitCast(@as(i32, @bitCast(x)) +% dx);
            y = @bitCast(@as(i32, @bitCast(y)) +% dy);
        }
        self.buffer_address = (self.buffer_address + 8) & 0x7FFFF;
    }

    fn sourcePixel(ram: *const WordRam, regs: *const [8]u16, raw_x: u32, raw_y: u32) u8 {
        const mode: u2 = @truncate((regs[0] >> 1) & 3);
        const large_stamp = (mode & 1) != 0;
        const repeat = (regs[0] & 1) != 0;
        const coordinate_mask: u32 = if ((mode & 2) != 0) 0x7FFFFF else 0x07FFFF;
        const x = raw_x & (if (repeat) coordinate_mask else 0xFFFFFF);
        const y = raw_y & (if (repeat) coordinate_mask else 0xFFFFFF);
        if (!repeat and ((x | y) & ~coordinate_mask) != 0) return 0;

        const stamp_shift: u5 = if (large_stamp) 16 else 15;
        const map_shift: u5 = switch (mode) {
            0 => 4,
            1 => 3,
            2 => 8,
            3 => 7,
        };
        const map_mask: u32 = switch (mode) {
            0 => 0x3FE00,
            1 => 0x3FF80,
            2 => 0x20000,
            3 => 0x38000,
        };
        const map_base = (@as(u32, regs[1]) << 2) & map_mask;
        const entry_offset = ((x >> stamp_shift) | ((y >> stamp_shift) << map_shift)) << 1;
        const entry = read16(ram, map_base + entry_offset);
        const stamp_number = entry & (if (large_stamp) @as(u16, 0x07FC) else 0x07FF);
        if (stamp_number == 0) return 0;

        const size: u32 = if (large_stamp) 32 else 16;
        const max = size - 1;
        var column = (x >> 11) & max;
        var row = (y >> 11) & max;
        const transform: u3 = @truncate(entry >> 13);
        if ((transform & 4) != 0) column ^= max;
        if ((transform & 2) != 0) {
            column ^= max;
            row ^= max;
        }
        if ((transform & 1) != 0) {
            const old_column = column;
            column = row ^ max;
            row = old_column;
        }

        const cells_per_side = size >> 3;
        const cell = (column >> 3) * cells_per_side + (row >> 3);
        const dot = (@as(u32, stamp_number) << 8) + cell * 64 + (row & 7) * 8 + (column & 7);
        const byte = read8(ram, dot >> 1);
        return if ((dot & 1) == 0) byte >> 4 else byte & 0x0F;
    }

    fn read8(ram: *const WordRam, address: u32) u8 {
        return switch (ram.mode) {
            .two_m => ram.read8Linear(address),
            .one_m => ram.read8Bank(ram.subBank1M(), address),
        };
    }

    fn read16(ram: *const WordRam, address: u32) u16 {
        return (@as(u16, read8(ram, address)) << 8) | read8(ram, address + 1);
    }

    fn writeDot(ram: *WordRam, dot: u32, pixel: u8) void {
        if (ram.mode == .one_m) {
            ram.writeDot(ram.subBank1M(), dot, pixel);
            return;
        }
        const address = dot >> 1;
        const old = ram.read8Linear(address);
        const old_pixel = if ((dot & 1) == 0) old >> 4 else old & 0x0F;
        const source = pixel & 0x0F;
        const result = switch (ram.priority) {
            .off => source,
            .underwrite => if (old_pixel == 0) source else old_pixel,
            .overwrite => if (source != 0) source else old_pixel,
            .prohibited => old_pixel,
        };
        ram.write8Linear(address, if ((dot & 1) == 0) (old & 0x0F) | (result << 4) else (old & 0xF0) | result);
    }
};

test "graphics ASIC renders a stamp-map line and completes" {
    var ram = WordRam{ .ret = false };
    var regs = [_]u16{0} ** 8;
    regs[1] = 0x4000;
    regs[3] = 0x6000;
    regs[5] = 1;
    regs[6] = 1;
    regs[7] = 0xC000;
    ram.write16Linear(0x10000, 1);
    ram.write8Linear(0x80, 0xA0);
    ram.write16Linear(0x30000, 0);
    ram.write16Linear(0x30002, 0);
    ram.write16Linear(0x30004, 0);
    ram.write16Linear(0x30006, 0);

    var gfx = Gfx{};
    gfx.start(&regs);
    try std.testing.expectEqual(@as(u16, 0x8000), regs[0] & 0x8000);
    try std.testing.expect(gfx.advance(1000, &regs, &ram));
    try std.testing.expectEqual(@as(u8, 0xA0), ram.read8Linear(0x18000));
    try std.testing.expectEqual(@as(u16, 0), regs[0] & 0x8000);
    try std.testing.expectEqual(@as(u16, 0), regs[6] & 0x00FF);

    // Horizontal flip maps the first output dot to the stamp's last column.
    regs[0] = 0;
    regs[6] = 1;
    ram.write16Linear(0x10000, 0x8001);
    ram.write8Linear(0xC3, 0x0B);
    ram.write8Linear(0x18000, 0);
    gfx.start(&regs);
    try std.testing.expect(gfx.advance(1000, &regs, &ram));
    try std.testing.expectEqual(@as(u8, 0xB0), ram.read8Linear(0x18000));
}
