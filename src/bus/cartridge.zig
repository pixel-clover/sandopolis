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
    rom: []u8,
    ram: Ram,
    save_path: ?[]u8,

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
        var cartridge = Cartridge{
            .rom = rom_data,
            .ram = try Ram.initFromRomHeader(allocator, rom_data, checksum),
            .save_path = null,
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
        allocator.free(self.rom);
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
        const rom_len_u32: u32 = @intCast(self.rom.len);
        if (address >= rom_len_u32) return 0;
        return self.rom[@intCast(address)];
    }

    pub fn writeRegisterByte(self: *Cartridge, address: u32, value: u8) bool {
        if (address == 0xA130F1) {
            self.ram.setMapped((value & 1) != 0);
            return true;
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
