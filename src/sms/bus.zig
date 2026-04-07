const std = @import("std");
const testing = std.testing;
const SmsVdp = @import("vdp.zig").SmsVdp;
const SmsIo = @import("io.zig").SmsIo;
const SmsInput = @import("input.zig").SmsInput;

/// SMS memory bus with Sega mapper.
///
/// Memory map:
///   0x0000-0x03FF: First 1KB of ROM (always mapped)
///   0x0400-0x3FFF: ROM page 0
///   0x4000-0x7FFF: ROM page 1
///   0x8000-0xBFFF: ROM page 2 (bankable)
///   0xC000-0xDFFF: 8KB system RAM
///   0xE000-0xFFFF: RAM mirror (mapper registers at 0xFFFC-0xFFFF)
pub const SmsBus = struct {
    rom: []const u8,
    ram: [8 * 1024]u8 = [_]u8{0} ** (8 * 1024),
    vdp: SmsVdp = SmsVdp.init(),
    input: SmsInput = SmsInput{},
    io: SmsIo = undefined, // Initialized in init()

    // Sega mapper page registers
    page: [3]u8 = .{ 0, 1, 2 },
    ram_bank_enabled: bool = false,
    ram_bank: u1 = 0,
    cartridge_ram: [2 * 8 * 1024]u8 = [_]u8{0} ** (2 * 8 * 1024),

    pub fn init(rom: []const u8) SmsBus {
        var bus = SmsBus{ .rom = rom };
        bus.io = SmsIo{ .vdp = &bus.vdp, .input = &bus.input };
        return bus;
    }

    pub fn reset(self: *SmsBus) void {
        self.ram = [_]u8{0} ** (8 * 1024);
        self.vdp.reset();
        self.page = .{ 0, 1, 2 };
        self.ram_bank_enabled = false;
        self.ram_bank = 0;
        self.io = SmsIo{ .vdp = &self.vdp, .input = &self.input };
    }

    /// Rebind internal pointers after a move/copy (needed for save state restore).
    pub fn rebindPointers(self: *SmsBus) void {
        self.io.vdp = &self.vdp;
        self.io.input = &self.input;
    }

    pub fn read(self: *const SmsBus, addr: u16) u8 {
        if (addr < 0x0400) {
            // First 1KB: always from ROM start
            return if (addr < self.rom.len) self.rom[addr] else 0xFF;
        }
        if (addr < 0x4000) {
            // Page 0
            const rom_addr = @as(usize, self.page[0]) * 0x4000 + @as(usize, addr);
            return if (rom_addr < self.rom.len) self.rom[rom_addr] else 0xFF;
        }
        if (addr < 0x8000) {
            // Page 1
            const rom_addr = @as(usize, self.page[1]) * 0x4000 + @as(usize, addr - 0x4000);
            return if (rom_addr < self.rom.len) self.rom[rom_addr] else 0xFF;
        }
        if (addr < 0xC000) {
            // Page 2 or cartridge RAM
            if (self.ram_bank_enabled) {
                const ram_offset = @as(usize, self.ram_bank) * 0x4000 + @as(usize, addr - 0x8000);
                return self.cartridge_ram[ram_offset];
            }
            const rom_addr = @as(usize, self.page[2]) * 0x4000 + @as(usize, addr - 0x8000);
            return if (rom_addr < self.rom.len) self.rom[rom_addr] else 0xFF;
        }
        // 0xC000-0xFFFF: system RAM (8KB mirrored)
        return self.ram[addr & 0x1FFF];
    }

    pub fn write(self: *SmsBus, addr: u16, value: u8) void {
        if (addr < 0x8000) {
            // ROM area: writes are ignored (no mapper in low pages)
            return;
        }
        if (addr < 0xC000) {
            // Page 2 area: write to cartridge RAM if enabled
            if (self.ram_bank_enabled) {
                const ram_offset = @as(usize, self.ram_bank) * 0x4000 + @as(usize, addr - 0x8000);
                self.cartridge_ram[ram_offset] = value;
            }
            return;
        }
        // 0xC000-0xFFFF: system RAM + mapper registers
        self.ram[addr & 0x1FFF] = value;

        // Mapper registers at 0xFFFC-0xFFFF (mirrored via RAM)
        switch (addr) {
            0xFFFC => {
                self.ram_bank_enabled = (value & 0x08) != 0;
                self.ram_bank = @truncate((value >> 2) & 1);
            },
            0xFFFD => self.page[0] = self.clampPage(value),
            0xFFFE => self.page[1] = self.clampPage(value),
            0xFFFF => self.page[2] = self.clampPage(value),
            else => {},
        }
    }

    fn clampPage(self: *const SmsBus, page: u8) u8 {
        if (self.rom.len == 0) return 0;
        const total_pages = @as(u8, @intCast(@max(1, self.rom.len / 0x4000)));
        return page % total_pages;
    }

    // -- Z80 bridge host callbacks (C-compatible) --

    pub fn hostRead(ctx: ?*anyopaque, addr: u32) callconv(.c) u8 {
        const self: *SmsBus = @ptrCast(@alignCast(ctx orelse return 0xFF));
        return self.read(@truncate(addr));
    }

    pub fn hostPeek(ctx: ?*anyopaque, addr: u32) callconv(.c) u8 {
        const self: *const SmsBus = @ptrCast(@alignCast(ctx orelse return 0xFF));
        return self.read(@truncate(addr));
    }

    pub fn hostWrite(ctx: ?*anyopaque, addr: u32, val: u8) callconv(.c) void {
        const self: *SmsBus = @ptrCast(@alignCast(ctx orelse return));
        self.write(@truncate(addr), val);
    }

    pub fn hostPortIn(ctx: ?*anyopaque, port: u16) callconv(.c) u8 {
        const self: *SmsBus = @ptrCast(@alignCast(ctx orelse return 0xFF));
        return self.io.portIn(port);
    }

    pub fn hostPortOut(ctx: ?*anyopaque, port: u16, val: u8) callconv(.c) void {
        const self: *SmsBus = @ptrCast(@alignCast(ctx orelse return));
        self.io.portOut(port, val);
    }

    pub fn hostM68kBusAccess(_: ?*anyopaque, _: u32) callconv(.c) void {
        // No-op: SMS has no M68K
    }
};

// -- Tests --

test "sms bus read rom page 0" {
    const rom = [_]u8{0} ** (32 * 1024) ++ [_]u8{0} ** 0; // 32KB dummy
    var rom_buf: [32 * 1024]u8 = undefined;
    rom_buf[0] = 0x42;
    rom_buf[0x100] = 0xAB;
    const bus = SmsBus.init(&rom_buf);
    try testing.expectEqual(@as(u8, 0x42), bus.read(0x0000));
    try testing.expectEqual(@as(u8, 0xAB), bus.read(0x0100));
}

test "sms bus ram read write mirror" {
    var rom_buf = [_]u8{0} ** 1024;
    var bus = SmsBus.init(&rom_buf);
    bus.write(0xC000, 0x55);
    try testing.expectEqual(@as(u8, 0x55), bus.read(0xC000));
    // Mirror at 0xE000
    try testing.expectEqual(@as(u8, 0x55), bus.read(0xE000));
}

test "sms bus mapper page switch" {
    // 64KB ROM = 4 pages of 16KB
    var rom_buf = [_]u8{0} ** (64 * 1024);
    rom_buf[2 * 0x4000] = 0xAA; // First byte of page 2
    rom_buf[3 * 0x4000] = 0xBB; // First byte of page 3
    var bus = SmsBus.init(&rom_buf);

    // Default: page[2] = 2, so 0x8000 reads from ROM page 2
    try testing.expectEqual(@as(u8, 0xAA), bus.read(0x8000));

    // Switch page 2 to ROM page 3
    bus.write(0xFFFF, 3);
    try testing.expectEqual(@as(u8, 0xBB), bus.read(0x8000));
}
