const std = @import("std");

fn looksLikeGenesis(rom: []const u8) bool {
    if (rom.len < 0x104) return false;
    return std.mem.eql(u8, rom[0x100..0x104], "SEGA");
}

fn deinterleaveSmdPayload(allocator: std.mem.Allocator, payload: []const u8) ![]u8 {
    const block_size: usize = 16 * 1024;
    if (payload.len % block_size != 0) return error.InvalidSmd;

    var out = try allocator.alloc(u8, payload.len);
    var i: usize = 0;
    while (i < payload.len) : (i += block_size) {
        const block = payload[i .. i + block_size];
        var j: usize = 0;
        while (j < block_size / 2) : (j += 1) {
            out[i + j * 2] = block[j];
            out[i + j * 2 + 1] = block[j + (block_size / 2)];
        }
    }

    return out;
}

const RamType = enum {
    none,
    sixteen_bit,
    eight_bit_even,
    eight_bit_odd,
};

const sonic_and_knuckles_serial = "GM MK-1563 ";
const ssf_console_prefix = "SEGA SSF";
const ssf_bank_size: u32 = 512 * 1024;
const ssf_switchable_bank_count: usize = 7;
const ssf_max_page_mask: u8 = 0x3F;
const force_8kb_sram_checksums = [_]u32{
    0x8135702C,
    0xF509145F,
    0x6EF7104A,
    0x2491DF2F,
};
const force_32kb_sram_checksums = [_]u32{
    0xA4F2F011,
};
const forced_sram_start_address: u32 = 0x200001;

const SsfMapper = struct {
    bank_registers: [ssf_switchable_bank_count]u8 = .{ 1, 2, 3, 4, 5, 6, 7 },

    fn registerIndex(address: u32) ?usize {
        if (address < 0xA130F3 or address > 0xA130FF or (address & 1) == 0) return null;

        const index: usize = @intCast((address - 0xA130F3) / 2);
        if (index >= ssf_switchable_bank_count) return null;
        return index;
    }

    fn translateRomAddress(self: *const SsfMapper, address: u32) u32 {
        if (address < ssf_bank_size) return address;
        if (address >= ssf_bank_size * (ssf_switchable_bank_count + 1)) return address;

        const bank_index: usize = @intCast((address / ssf_bank_size) - 1);
        const page = self.bank_registers[bank_index];
        return @as(u32, page) * ssf_bank_size + (address & (ssf_bank_size - 1));
    }

    fn writeRegisterByte(self: *SsfMapper, address: u32, value: u8) bool {
        const index = registerIndex(address) orelse return false;
        self.bank_registers[index] = value & ssf_max_page_mask;
        return true;
    }
};

const Mapper = union(enum) {
    none,
    ssf: SsfMapper,
};

fn detectMapper(rom: []const u8) Mapper {
    if (rom.len >= 0x100 + ssf_console_prefix.len and
        std.mem.startsWith(u8, rom[0x100..@min(rom.len, 0x110)], ssf_console_prefix))
    {
        return .{ .ssf = .{} };
    }

    return .none;
}

const Ram = struct {
    data: ?[]u8,
    ram_type: RamType,
    persistent: bool,
    dirty: bool,
    mapped: bool,
    start_address: u32,
    end_address: u32,

    fn initEmpty() Ram {
        return .{
            .data = null,
            .ram_type = .none,
            .persistent = false,
            .dirty = false,
            .mapped = false,
            .start_address = 0,
            .end_address = 0,
        };
    }

    fn initForced(allocator: std.mem.Allocator, rom_len: usize, ram_len: usize) !Ram {
        const data = try allocator.alloc(u8, ram_len);
        @memset(data, 0);

        return .{
            .data = data,
            .ram_type = .eight_bit_odd,
            .persistent = true,
            .dirty = false,
            .mapped = forced_sram_start_address >= rom_len,
            .start_address = forced_sram_start_address,
            .end_address = forced_sram_start_address + @as(u32, @intCast((ram_len - 1) * 2)),
        };
    }

    fn initFromRomHeader(allocator: std.mem.Allocator, rom: []const u8, checksum: u32) !Ram {
        if (std.mem.indexOfScalar(u32, &force_8kb_sram_checksums, checksum) != null) {
            return initForced(allocator, rom.len, 8 * 1024);
        }

        if (std.mem.indexOfScalar(u32, &force_32kb_sram_checksums, checksum) != null) {
            return initForced(allocator, rom.len, 32 * 1024);
        }

        var header_rom = rom;
        if (rom.len > 2 * 1024 * 1024 and
            rom.len >= 0x18B and
            std.mem.eql(u8, rom[0x180..0x18B], sonic_and_knuckles_serial))
        {
            const lock_on_rom = rom[2 * 1024 * 1024 ..];
            if (lock_on_rom.len >= 0x1BC) {
                header_rom = lock_on_rom;
            }
        }

        if (header_rom.len < 0x1BC) return initEmpty();

        const header = header_rom[0x1B0..0x1BC];
        if (!(header[0] == 'R' and header[1] == 'A' and header[3] == 0x20)) {
            return initEmpty();
        }

        const ram_type: RamType = switch (header[2]) {
            0xA0, 0xE0 => .sixteen_bit,
            0xB0, 0xF0 => .eight_bit_even,
            0xB8, 0xF8 => .eight_bit_odd,
            else => return initEmpty(),
        };
        const persistent = (header[2] & 0x40) != 0;
        const start_address = std.mem.readInt(u32, header[4..8], .big);
        const end_address = std.mem.readInt(u32, header[8..12], .big);
        if (start_address > end_address) return initEmpty();

        const ram_len_u32: u32 = switch (ram_type) {
            .none => 0,
            .sixteen_bit => end_address - start_address + 1,
            .eight_bit_even, .eight_bit_odd => ((end_address - start_address) / 2) + 1,
        };
        if (ram_len_u32 == 0) return initEmpty();

        const ram_len: usize = @intCast(ram_len_u32);
        const data = try allocator.alloc(u8, ram_len);
        @memset(data, 0);

        return .{
            .data = data,
            .ram_type = ram_type,
            .persistent = persistent,
            .dirty = false,
            .mapped = start_address >= rom.len,
            .start_address = start_address,
            .end_address = end_address,
        };
    }

    fn deinit(self: *Ram, allocator: std.mem.Allocator) void {
        if (self.data) |data| allocator.free(data);
        self.* = initEmpty();
    }

    fn clone(self: *const Ram, allocator: std.mem.Allocator) !Ram {
        const data = if (self.data) |source| blk: {
            const copy = try allocator.alloc(u8, source.len);
            std.mem.copyForwards(u8, copy, source);
            break :blk copy;
        } else null;

        return .{
            .data = data,
            .ram_type = self.ram_type,
            .persistent = self.persistent,
            .dirty = self.dirty,
            .mapped = self.mapped,
            .start_address = self.start_address,
            .end_address = self.end_address,
        };
    }

    fn hasStorage(self: *const Ram) bool {
        return self.data != null;
    }

    fn clearDirty(self: *Ram) void {
        self.dirty = false;
    }

    fn setMapped(self: *Ram, mapped: bool) void {
        if (!self.hasStorage()) return;
        self.mapped = mapped;
    }

    fn mapIndex(self: *const Ram, address: u32) ?usize {
        const data = self.data orelse return null;
        if (!self.mapped) return null;
        if (address < self.start_address or address > self.end_address) return null;

        const index_u32: u32 = switch (self.ram_type) {
            .none => return null,
            .sixteen_bit => address - self.start_address,
            .eight_bit_even, .eight_bit_odd => blk: {
                if ((address & 1) != (self.start_address & 1)) return null;
                break :blk (address - self.start_address) / 2;
            },
        };

        const index: usize = @intCast(index_u32);
        if (index >= data.len) return null;
        return index;
    }

    fn readByte(self: *const Ram, address: u32) ?u8 {
        const data = self.data orelse return null;
        const index = self.mapIndex(address) orelse return null;
        return data[index];
    }

    fn writeByte(self: *Ram, address: u32, value: u8) bool {
        const data = self.data orelse return false;
        const index = self.mapIndex(address) orelse return false;
        data[index] = value;
        self.dirty = true;
        return true;
    }

    fn readWord(self: *const Ram, address: u32) ?u16 {
        const msb = self.readByte(address);
        const lsb = self.readByte(address + 1);
        if (msb) |high| {
            if (lsb) |low| {
                return (@as(u16, high) << 8) | low;
            }
            return (@as(u16, high) << 8) | high;
        }
        if (lsb) |low| {
            return (@as(u16, low) << 8) | low;
        }
        return null;
    }

    fn writeWord(self: *Ram, address: u32, value: u16) bool {
        const msb = @as(u8, @truncate((value >> 8) & 0xFF));
        const lsb = @as(u8, @truncate(value & 0xFF));
        const wrote_high = self.writeByte(address, msb);
        const wrote_low = self.writeByte(address + 1, lsb);
        return wrote_high or wrote_low;
    }
};

pub const Cartridge = struct {
    pub const RamState = struct {
        ram_type: u8,
        persistent: bool,
        dirty: bool,
        mapped: bool,
        start_address: u32,
        end_address: u32,
    };

    rom: []u8,
    ram: Ram,
    mapper: Mapper,
    save_path: ?[]u8,
    source_path: ?[]u8,

    pub fn init(allocator: std.mem.Allocator, rom_path: ?[]const u8) !Cartridge {
        var rom_data: []u8 = undefined;

        if (rom_path) |path| {
            const file = try std.fs.cwd().openFile(path, .{});
            defer file.close();

            const size = try file.getEndPos();
            const raw = try allocator.alloc(u8, size);
            _ = try file.readAll(raw);

            if (std.mem.endsWith(u8, path, ".smd")) {
                var candidate: ?[]u8 = null;

                if (raw.len > 512) {
                    if (deinterleaveSmdPayload(allocator, raw[512..])) |tmp| {
                        if (looksLikeGenesis(tmp)) candidate = tmp else allocator.free(tmp);
                    } else |_| {}
                }

                if (candidate == null) {
                    if (deinterleaveSmdPayload(allocator, raw)) |tmp| {
                        if (looksLikeGenesis(tmp)) candidate = tmp else allocator.free(tmp);
                    } else |_| {}
                }

                if (candidate) |rom| {
                    allocator.free(raw);
                    rom_data = rom;
                } else {
                    rom_data = raw;
                }
            } else {
                rom_data = raw;
            }
        } else {
            rom_data = try allocator.alloc(u8, 4 * 1024 * 1024);
            @memset(rom_data, 0);
        }

        return initWithRomData(allocator, rom_data, rom_path, null);
    }

    pub fn initFromRomBytes(allocator: std.mem.Allocator, rom_bytes: []const u8) !Cartridge {
        const rom_data = try allocator.alloc(u8, rom_bytes.len);
        std.mem.copyForwards(u8, rom_data, rom_bytes);
        return initWithRomData(allocator, rom_data, null, null);
    }

    pub fn initFromRomBytesWithChecksum(allocator: std.mem.Allocator, rom_bytes: []const u8, checksum: u32) !Cartridge {
        const rom_data = try allocator.alloc(u8, rom_bytes.len);
        std.mem.copyForwards(u8, rom_data, rom_bytes);
        return initWithRomData(allocator, rom_data, null, checksum);
    }

    fn initWithRomData(
        allocator: std.mem.Allocator,
        rom_data: []u8,
        rom_path: ?[]const u8,
        checksum_override: ?u32,
    ) !Cartridge {
        const checksum = checksum_override orelse std.hash.Crc32.hash(rom_data);
        const source_path = if (rom_path) |path|
            try allocator.dupe(u8, path)
        else
            null;
        errdefer if (source_path) |path| allocator.free(path);

        var cartridge = Cartridge{
            .rom = rom_data,
            .ram = try Ram.initFromRomHeader(allocator, rom_data, checksum),
            .mapper = detectMapper(rom_data),
            .save_path = null,
            .source_path = source_path,
        };

        if (cartridge.ram.persistent and cartridge.ram.hasStorage() and rom_path != null) {
            cartridge.save_path = try savePathForRom(allocator, rom_path.?);
            try cartridge.loadPersistentStorage();
        }

        return cartridge;
    }

    pub fn deinit(self: *Cartridge, allocator: std.mem.Allocator) void {
        self.ram.deinit(allocator);
        if (self.save_path) |save_path| allocator.free(save_path);
        if (self.source_path) |source_path| allocator.free(source_path);
        allocator.free(self.rom);
    }

    pub fn clone(self: *const Cartridge, allocator: std.mem.Allocator) !Cartridge {
        const rom = try allocator.alloc(u8, self.rom.len);
        errdefer allocator.free(rom);
        std.mem.copyForwards(u8, rom, self.rom);

        var ram = try self.ram.clone(allocator);
        errdefer ram.deinit(allocator);

        const save_path = if (self.save_path) |path|
            try allocator.dupe(u8, path)
        else
            null;
        errdefer if (save_path) |path| allocator.free(path);

        const source_path = if (self.source_path) |path|
            try allocator.dupe(u8, path)
        else
            null;
        errdefer if (source_path) |path| allocator.free(path);

        return .{
            .rom = rom,
            .ram = ram,
            .mapper = self.mapper,
            .save_path = save_path,
            .source_path = source_path,
        };
    }

    pub fn resetHardwareState(self: *Cartridge) void {
        self.mapper = detectMapper(self.rom);
        if (self.ram.hasStorage()) {
            self.ram.setMapped(self.ram.start_address >= self.rom.len);
        }
    }

    fn savePathForRom(allocator: std.mem.Allocator, rom_path: []const u8) ![]u8 {
        const extension = std.fs.path.extension(rom_path);
        if (extension.len == 0) {
            return std.fmt.allocPrint(allocator, "{s}.sav", .{rom_path});
        }

        return std.fmt.allocPrint(allocator, "{s}.sav", .{rom_path[0 .. rom_path.len - extension.len]});
    }

    fn loadPersistentStorage(self: *Cartridge) !void {
        const save_path = self.save_path orelse return;
        if (!self.ram.persistent) return;
        if (!self.ram.hasStorage()) return;

        const file = std.fs.cwd().openFile(save_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer file.close();

        const data = self.ram.data.?;
        const bytes_read = try file.readAll(data);
        if (bytes_read < data.len) {
            @memset(data[bytes_read..], 0);
        }
        self.ram.clearDirty();
    }

    pub fn flushPersistentStorage(self: *Cartridge) !void {
        const save_path = self.save_path orelse return;
        if (!self.ram.persistent or !self.ram.dirty) return;

        const data = self.ram.data orelse return;
        const file = try std.fs.cwd().createFile(save_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(data);
        self.ram.clearDirty();
    }

    pub fn readRomByte(self: *const Cartridge, address: u32) u8 {
        if (self.rom.len == 0) return 0;

        const mapped_address = switch (self.mapper) {
            .none => address,
            .ssf => |mapper| mapper.translateRomAddress(address),
        };

        const rom_len_u32: u32 = @intCast(self.rom.len);
        if (mapped_address >= rom_len_u32) return 0;
        return self.rom[@intCast(mapped_address)];
    }

    pub fn writeRegisterByte(self: *Cartridge, address: u32, value: u8) bool {
        if (address == 0xA130F1) {
            self.ram.setMapped((value & 1) != 0);
            return true;
        }

        switch (self.mapper) {
            .none => {},
            .ssf => |*mapper| {
                if (mapper.writeRegisterByte(address, value)) return true;
            },
        }

        return false;
    }

    pub fn writeRegisterWord(self: *Cartridge, address: u32, value: u16) bool {
        return self.writeRegisterByte(address | 1, @truncate(value));
    }

    pub fn hasRam(self: *const Cartridge) bool {
        return self.ram.hasStorage();
    }

    pub fn isRamMapped(self: *const Cartridge) bool {
        return self.ram.mapped;
    }

    pub fn isRamPersistent(self: *const Cartridge) bool {
        return self.ram.persistent;
    }

    pub fn persistentSavePath(self: *const Cartridge) ?[]const u8 {
        return self.save_path;
    }

    pub fn sourcePath(self: *const Cartridge) ?[]const u8 {
        return self.source_path;
    }

    pub fn romBytes(self: *const Cartridge) []const u8 {
        return self.rom;
    }

    pub fn ramBytes(self: *const Cartridge) ?[]const u8 {
        return self.ram.data;
    }

    pub fn captureRamState(self: *const Cartridge) RamState {
        return .{
            .ram_type = @intFromEnum(self.ram.ram_type),
            .persistent = self.ram.persistent,
            .dirty = self.ram.dirty,
            .mapped = self.ram.mapped,
            .start_address = self.ram.start_address,
            .end_address = self.ram.end_address,
        };
    }

    pub fn restoreRamState(self: *Cartridge, state: RamState, saved_ram: ?[]const u8) error{InvalidSaveState}!void {
        const next_ram = self.ram.data;
        if ((saved_ram != null) != (next_ram != null)) return error.InvalidSaveState;

        if (saved_ram) |saved_ram_bytes| {
            const next_ram_bytes = next_ram orelse return error.InvalidSaveState;
            if (next_ram_bytes.len != saved_ram_bytes.len) return error.InvalidSaveState;
            if (@intFromEnum(self.ram.ram_type) != state.ram_type) return error.InvalidSaveState;
            std.mem.copyForwards(u8, next_ram_bytes, saved_ram_bytes);
        }

        self.ram.persistent = state.persistent;
        self.ram.dirty = state.dirty;
        self.ram.mapped = state.mapped;
        self.ram.start_address = state.start_address;
        self.ram.end_address = state.end_address;
    }

    pub fn readByte(self: *const Cartridge, address: u32) ?u8 {
        return self.ram.readByte(address);
    }

    pub fn readWord(self: *const Cartridge, address: u32) ?u16 {
        return self.ram.readWord(address);
    }

    pub fn writeByte(self: *Cartridge, address: u32, value: u8) bool {
        return self.ram.writeByte(address, value);
    }

    pub fn writeWord(self: *Cartridge, address: u32, value: u16) bool {
        return self.ram.writeWord(address, value);
    }
};

fn makeBasicGenesisRom(allocator: std.mem.Allocator, rom_len: usize) ![]u8 {
    var rom = try allocator.alloc(u8, rom_len);
    @memset(rom, 0);
    @memcpy(rom[0x100..0x104], "SEGA");
    return rom;
}

fn makeRomWithSramHeader(
    allocator: std.mem.Allocator,
    rom_len: usize,
    ram_type: u8,
    start_address: u32,
    end_address: u32,
) ![]u8 {
    var rom = try makeBasicGenesisRom(allocator, rom_len);
    rom[0x1B0] = 'R';
    rom[0x1B1] = 'A';
    rom[0x1B2] = ram_type;
    rom[0x1B3] = 0x20;
    std.mem.writeInt(u32, rom[0x1B4..0x1B8], start_address, .big);
    std.mem.writeInt(u32, rom[0x1B8..0x1BC], end_address, .big);
    return rom;
}

fn writeSerial(rom: []u8, base: usize, serial: []const u8) void {
    @memcpy(rom[base + 0x180 .. base + 0x180 + serial.len], serial);
}

fn readBusVisibleByte(cartridge: *const Cartridge, address: u32) u8 {
    return cartridge.readByte(address) orelse cartridge.readRomByte(address);
}

fn makeSsfMapperRom(allocator: std.mem.Allocator, bank_count: usize) ![]u8 {
    const bank_size = 512 * 1024;
    const rom_len = bank_count * bank_size;
    var rom = try allocator.alloc(u8, rom_len);
    @memset(rom, 0);
    @memcpy(rom[0x100..0x108], "SEGA SSF");

    const marker_offset = 0x0400;
    for (0..bank_count) |bank| {
        rom[bank * bank_size + marker_offset] = @truncate(bank);
    }

    return rom;
}

test "cartridge odd-byte sram past end of rom is auto-mapped" {
    const rom = try makeRomWithSramHeader(std.testing.allocator, 0x200000, 0xF8, 0x200001, 0x203FFF);
    defer std.testing.allocator.free(rom);

    var cartridge = try Cartridge.initFromRomBytes(std.testing.allocator, rom);
    defer cartridge.deinit(std.testing.allocator);

    try std.testing.expect(cartridge.hasRam());
    try std.testing.expect(cartridge.isRamMapped());
    try std.testing.expect(cartridge.isRamPersistent());

    try std.testing.expect(cartridge.writeByte(0x0020_0001, 0x5A));
    try std.testing.expectEqual(@as(u8, 0x5A), cartridge.readByte(0x0020_0001).?);
    try std.testing.expectEqual(@as(u16, 0x5A5A), cartridge.readWord(0x0020_0000).?);
}

test "forced 8kb sram checksum maps odd-byte persistent ram without header" {
    const rom = try makeBasicGenesisRom(std.testing.allocator, 0x100000);
    defer std.testing.allocator.free(rom);

    var cartridge = try Cartridge.initFromRomBytesWithChecksum(std.testing.allocator, rom, 0x8135702C);
    defer cartridge.deinit(std.testing.allocator);

    try std.testing.expect(cartridge.hasRam());
    try std.testing.expect(cartridge.isRamMapped());
    try std.testing.expect(cartridge.isRamPersistent());

    try std.testing.expect(cartridge.writeByte(0x0020_0001, 0xA5));
    try std.testing.expect(cartridge.writeByte(0x0020_3FFF, 0x5A));
    try std.testing.expectEqual(@as(u8, 0xA5), cartridge.readByte(0x0020_0001).?);
    try std.testing.expectEqual(@as(u8, 0x5A), cartridge.readByte(0x0020_3FFF).?);
    try std.testing.expectEqual(@as(u16, 0xA5A5), cartridge.readWord(0x0020_0000).?);
}

test "forced 32kb sram checksum maps full odd-byte 20ffff range without header" {
    const rom = try makeBasicGenesisRom(std.testing.allocator, 0x100000);
    defer std.testing.allocator.free(rom);

    var cartridge = try Cartridge.initFromRomBytesWithChecksum(std.testing.allocator, rom, 0xA4F2F011);
    defer cartridge.deinit(std.testing.allocator);

    try std.testing.expect(cartridge.hasRam());
    try std.testing.expect(cartridge.isRamMapped());
    try std.testing.expect(cartridge.isRamPersistent());

    try std.testing.expect(cartridge.writeByte(0x0020_0001, 0x12));
    try std.testing.expect(cartridge.writeByte(0x0020_FFFF, 0x34));
    try std.testing.expectEqual(@as(u8, 0x12), cartridge.readByte(0x0020_0001).?);
    try std.testing.expectEqual(@as(u8, 0x34), cartridge.readByte(0x0020_FFFF).?);
    try std.testing.expectEqual(@as(u16, 0x3434), cartridge.readWord(0x0020_FFFE).?);
}

test "sonic and knuckles lock-on cartridge header enables locked-on sram" {
    var rom = try std.testing.allocator.alloc(u8, 0x400000);
    defer std.testing.allocator.free(rom);
    @memset(rom, 0);

    @memcpy(rom[0x100..0x104], "SEGA");
    writeSerial(rom, 0, "GM MK-1563 ");

    @memcpy(rom[0x200000 + 0x100 .. 0x200000 + 0x104], "SEGA");
    writeSerial(rom, 0x200000, "GM MK-1079 ");
    rom[0x200000 + 0x1B0] = 'R';
    rom[0x200000 + 0x1B1] = 'A';
    rom[0x200000 + 0x1B2] = 0xF8;
    rom[0x200000 + 0x1B3] = 0x20;
    std.mem.writeInt(u32, rom[0x200000 + 0x1B4 .. 0x200000 + 0x1B8], 0x200001, .big);
    std.mem.writeInt(u32, rom[0x200000 + 0x1B8 .. 0x200000 + 0x1BC], 0x203FFF, .big);

    var cartridge = try Cartridge.initFromRomBytes(std.testing.allocator, rom);
    defer cartridge.deinit(std.testing.allocator);

    try std.testing.expect(cartridge.hasRam());
    try std.testing.expect(!cartridge.isRamMapped());

    try std.testing.expect(cartridge.writeRegisterWord(0x00A1_30F0, 0x0001));
    try std.testing.expect(cartridge.isRamMapped());
    try std.testing.expect(cartridge.writeByte(0x0020_0001, 0xA5));
    try std.testing.expectEqual(@as(u8, 0xA5), cartridge.readByte(0x0020_0001).?);
}

test "cartridge sram map register toggles rom fallback" {
    var rom = try makeRomWithSramHeader(std.testing.allocator, 0x400000, 0xF8, 0x200001, 0x203FFF);
    defer std.testing.allocator.free(rom);
    rom[0x200001] = 0x33;

    var cartridge = try Cartridge.initFromRomBytes(std.testing.allocator, rom);
    defer cartridge.deinit(std.testing.allocator);

    try std.testing.expect(cartridge.hasRam());
    try std.testing.expect(!cartridge.isRamMapped());
    try std.testing.expectEqual(@as(u8, 0x33), readBusVisibleByte(&cartridge, 0x0020_0001));

    try std.testing.expect(!cartridge.writeByte(0x0020_0001, 0xAA));
    try std.testing.expectEqual(@as(u8, 0x33), readBusVisibleByte(&cartridge, 0x0020_0001));

    try std.testing.expect(cartridge.writeRegisterWord(0x00A1_30F0, 0x0001));
    try std.testing.expect(cartridge.isRamMapped());

    try std.testing.expect(cartridge.writeByte(0x0020_0001, 0xAA));
    try std.testing.expectEqual(@as(u8, 0xAA), readBusVisibleByte(&cartridge, 0x0020_0001));

    try std.testing.expect(cartridge.writeRegisterWord(0x00A1_30F0, 0x0000));
    try std.testing.expect(!cartridge.isRamMapped());
    try std.testing.expectEqual(@as(u8, 0x33), readBusVisibleByte(&cartridge, 0x0020_0001));

    try std.testing.expect(cartridge.writeRegisterWord(0x00A1_30F0, 0x0001));
    try std.testing.expectEqual(@as(u8, 0xAA), readBusVisibleByte(&cartridge, 0x0020_0001));
}

test "cartridge sixteen-bit sram stores both bytes of a word" {
    const rom = try makeRomWithSramHeader(std.testing.allocator, 0x100000, 0xE0, 0x200000, 0x20FFFF);
    defer std.testing.allocator.free(rom);

    var cartridge = try Cartridge.initFromRomBytes(std.testing.allocator, rom);
    defer cartridge.deinit(std.testing.allocator);

    try std.testing.expect(cartridge.hasRam());
    try std.testing.expect(cartridge.isRamMapped());

    try std.testing.expect(cartridge.writeWord(0x0020_0000, 0x1234));
    try std.testing.expectEqual(@as(u16, 0x1234), cartridge.readWord(0x0020_0000).?);
    try std.testing.expectEqual(@as(u8, 0x12), cartridge.readByte(0x0020_0000).?);
    try std.testing.expectEqual(@as(u8, 0x34), cartridge.readByte(0x0020_0001).?);
}

test "cartridge ram snapshot restores bytes and mapping state" {
    const rom = try makeRomWithSramHeader(std.testing.allocator, 0x200000, 0xF8, 0x200001, 0x203FFF);
    defer std.testing.allocator.free(rom);

    var source = try Cartridge.initFromRomBytes(std.testing.allocator, rom);
    defer source.deinit(std.testing.allocator);

    try std.testing.expect(source.writeByte(0x0020_0001, 0xA5));
    try std.testing.expect(source.writeRegisterByte(0xA130F1, 0));
    try std.testing.expect(!source.isRamMapped());

    const ram_state = source.captureRamState();

    var restored = try Cartridge.initFromRomBytes(std.testing.allocator, rom);
    defer restored.deinit(std.testing.allocator);

    try restored.restoreRamState(ram_state, source.ramBytes());

    try std.testing.expect(!restored.isRamMapped());
    try std.testing.expect(restored.writeRegisterByte(0xA130F1, 1));
    try std.testing.expectEqual(@as(u8, 0xA5), restored.readByte(0x0020_0001).?);
}

test "cartridge reset restores default ssf mapper banks" {
    const rom = try makeSsfMapperRom(std.testing.allocator, 16);
    defer std.testing.allocator.free(rom);

    var cartridge = try Cartridge.initFromRomBytes(std.testing.allocator, rom);
    defer cartridge.deinit(std.testing.allocator);

    const marker_offset: u32 = 0x0400;
    try std.testing.expectEqual(@as(u8, 1), cartridge.readRomByte(0x080000 + marker_offset));

    try std.testing.expect(cartridge.writeRegisterByte(0xA130F3, 10));
    try std.testing.expectEqual(@as(u8, 10), cartridge.readRomByte(0x080000 + marker_offset));

    cartridge.resetHardwareState();
    try std.testing.expectEqual(@as(u8, 1), cartridge.readRomByte(0x080000 + marker_offset));
}

test "cartridge reset restores default sram mapping state" {
    const rom = try makeBasicGenesisRom(std.testing.allocator, 0x200000);
    defer std.testing.allocator.free(rom);
    rom[0x1B0] = 'R';
    rom[0x1B1] = 'A';
    rom[0x1B2] = 0xF8;
    rom[0x1B3] = 0x20;
    std.mem.writeInt(u32, rom[0x1B4..0x1B8], 0x00200001, .big);
    std.mem.writeInt(u32, rom[0x1B8..0x1BC], 0x00203FFF, .big);

    var cartridge = try Cartridge.initFromRomBytes(std.testing.allocator, rom);
    defer cartridge.deinit(std.testing.allocator);

    try std.testing.expect(cartridge.isRamMapped());
    try std.testing.expect(cartridge.writeRegisterByte(0xA130F1, 0));
    try std.testing.expect(!cartridge.isRamMapped());

    cartridge.resetHardwareState();
    try std.testing.expect(cartridge.isRamMapped());
}
