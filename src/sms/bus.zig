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
    rom_owned: bool = false,
    source_path: ?[]const u8 = null,
    source_path_owned: bool = false,
    is_sg1000: bool = false,
    ram: [8 * 1024]u8 = [_]u8{0} ** (8 * 1024),
    vdp: SmsVdp = SmsVdp.init(),
    input: SmsInput = SmsInput{},
    io: SmsIo = undefined, // Initialized in init()

    // Sega mapper page registers
    page: [3]u8 = .{ 0, 1, 2 },
    ram_bank_enabled: bool = false,
    ram_bank: u1 = 0,
    cartridge_ram: [2 * 16 * 1024]u8 = [_]u8{0} ** (2 * 16 * 1024),

    /// Create a bus with a borrowed ROM slice (caller keeps ownership).
    pub fn init(rom: []const u8) SmsBus {
        var bus = SmsBus{ .rom = rom };
        bus.io = SmsIo{ .vdp = &bus.vdp, .input = &bus.input };
        return bus;
    }

    /// Create a bus with a copied ROM (bus owns the memory).
    pub fn initOwned(alloc: std.mem.Allocator, rom_bytes: []const u8) !SmsBus {
        const rom_copy = try alloc.alloc(u8, rom_bytes.len);
        @memcpy(rom_copy, rom_bytes);
        var bus = SmsBus{ .rom = rom_copy, .rom_owned = true };
        bus.io = SmsIo{ .vdp = &bus.vdp, .input = &bus.input };
        return bus;
    }

    pub fn setSourcePath(self: *SmsBus, alloc: std.mem.Allocator, path: []const u8) !void {
        if (self.source_path_owned) {
            if (self.source_path) |old| alloc.free(@constCast(old));
        }
        const copy = try alloc.dupe(u8, path);
        self.source_path = copy;
        self.source_path_owned = true;
    }

    pub fn sourcePath(self: *const SmsBus) ?[]const u8 {
        return self.source_path;
    }

    pub fn deinit(self: *SmsBus, alloc: std.mem.Allocator) void {
        if (self.source_path_owned) {
            if (self.source_path) |p| alloc.free(@constCast(p));
            self.source_path = null;
            self.source_path_owned = false;
        }
        if (self.rom_owned) {
            alloc.free(@constCast(self.rom));
            self.rom = &.{};
            self.rom_owned = false;
        }
    }

    pub fn clone(self: *const SmsBus, alloc: std.mem.Allocator) !SmsBus {
        const rom_copy = try alloc.alloc(u8, self.rom.len);
        @memcpy(rom_copy, self.rom);
        const path_copy: ?[]const u8 = if (self.source_path) |p| try alloc.dupe(u8, p) else null;
        return SmsBus{
            .rom = rom_copy,
            .rom_owned = true,
            .source_path = path_copy,
            .source_path_owned = path_copy != null,
            .ram = self.ram,
            .vdp = self.vdp,
            .input = self.input,
            .io = undefined, // Rebind after placement
            .page = self.page,
            .ram_bank_enabled = self.ram_bank_enabled,
            .ram_bank = self.ram_bank,
            .cartridge_ram = self.cartridge_ram,
        };
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
        // SG-1000: flat ROM up to 0xBFFF, 1KB RAM at 0xC000 mirrored
        if (self.is_sg1000) {
            if (addr < 0xC000) {
                return if (addr < self.rom.len) self.rom[addr] else 0xFF;
            }
            return self.ram[addr & 0x03FF]; // 1KB mirrored
        }
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
        // SG-1000: no mapper, 1KB RAM at 0xC000 mirrored
        if (self.is_sg1000) {
            if (addr >= 0xC000) {
                self.ram[addr & 0x03FF] = value;
            }
            return;
        }
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

test "sms bus cartridge ram bank 1 access" {
    var rom_buf = [_]u8{0} ** 1024;
    var bus = SmsBus.init(&rom_buf);

    // Enable cartridge RAM bank 1: bit 3=1 (enable), bit 2=1 (bank 1)
    bus.write(0xFFFC, 0x0C);
    try testing.expect(bus.ram_bank_enabled);
    try testing.expectEqual(@as(u1, 1), bus.ram_bank);

    // Write to cart RAM bank 1 at 0x8000
    bus.write(0x8000, 0xAA);
    try testing.expectEqual(@as(u8, 0xAA), bus.read(0x8000));

    // Write to end of cart RAM bank 1
    bus.write(0xBFFF, 0xBB);
    try testing.expectEqual(@as(u8, 0xBB), bus.read(0xBFFF));

    // Switch to bank 0: data should be different
    bus.write(0xFFFC, 0x08);
    try testing.expectEqual(@as(u1, 0), bus.ram_bank);
    try testing.expectEqual(@as(u8, 0x00), bus.read(0x8000)); // bank 0 was not written
}

test "sms bus read rom page 0" {
    var rom_buf = [_]u8{0} ** (32 * 1024);
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

test "sg1000 bus uses flat rom and 1kb mirrored ram" {
    // SG-1000: ROM direct-mapped 0x0000-0xBFFF, 1KB RAM at 0xC000 mirrored
    var rom_buf = [_]u8{0} ** (48 * 1024);
    rom_buf[0x0000] = 0xF3; // First byte (DI instruction)
    rom_buf[0x4000] = 0xAA; // Byte in second 16KB
    rom_buf[0x8000] = 0xBB; // Byte in third 16KB
    var bus = SmsBus.init(&rom_buf);
    bus.is_sg1000 = true;

    // ROM reads are flat (no mapper)
    try testing.expectEqual(@as(u8, 0xF3), bus.read(0x0000));
    try testing.expectEqual(@as(u8, 0xAA), bus.read(0x4000));
    try testing.expectEqual(@as(u8, 0xBB), bus.read(0x8000));

    // RAM write at 0xC000, read back at 0xC000
    bus.write(0xC000, 0x42);
    try testing.expectEqual(@as(u8, 0x42), bus.read(0xC000));

    // 1KB mirroring: addr & 0x03FF maps to same RAM offset
    // 0xC000 & 0x03FF = 0x000, 0xC400 & 0x03FF = 0x000, 0xD000 & 0x03FF = 0x000
    try testing.expectEqual(@as(u8, 0x42), bus.read(0xC400)); // same offset 0
    try testing.expectEqual(@as(u8, 0x42), bus.read(0xD000)); // same offset 0
    try testing.expectEqual(@as(u8, 0x42), bus.read(0xFC00)); // same offset 0

    // Writing to ROM area is ignored for SG-1000
    bus.write(0x4000, 0xFF);
    try testing.expectEqual(@as(u8, 0xAA), bus.read(0x4000));

    // Mapper register writes at 0xFFFC-0xFFFF should only affect 1KB RAM, not paging
    bus.write(0xFFFF, 0x03);
    try testing.expectEqual(@as(u8, 0xBB), bus.read(0x8000)); // ROM still direct-mapped
}

test "sg1000 bus 1kb ram does not alias into 8kb" {
    // Verify SG-1000 only has 1KB RAM, not 8KB
    var rom_buf = [_]u8{0} ** (16 * 1024);
    var bus = SmsBus.init(&rom_buf);
    bus.is_sg1000 = true;

    // Write at offset 0 within RAM
    bus.write(0xC000, 0xAA);
    // Write at offset 1024 (should mirror back to offset 0)
    bus.write(0xC400, 0xBB);
    // Both addresses should read 0xBB (1KB mirror overwrote 0xC000)
    try testing.expectEqual(@as(u8, 0xBB), bus.read(0xC000));
    try testing.expectEqual(@as(u8, 0xBB), bus.read(0xC400));
}
