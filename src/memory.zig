const std = @import("std");
const testing = std.testing;
const clock = @import("clock.zig");
const AudioTiming = @import("audio_timing.zig").AudioTiming;
const Vdp = @import("vdp.zig").Vdp;
const Io = @import("io.zig").Io;
const Z80 = @import("z80.zig").Z80;
const rocket68 = @import("cpu/rocket68_cpu.zig");

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

const CartridgeRamType = enum {
    none,
    sixteen_bit,
    eight_bit_even,
    eight_bit_odd,
};

const sonic_and_knuckles_serial = "GM MK-1563 ";
const force_8kb_sram_checksums = [_]u32{
    0x8135702C, // NHL 96 (USA, Europe)
    0xF509145F, // Might and Magic: Gates to Another World (USA, Europe)
    0x6EF7104A, // Might and Magic III: Isles of Terra (USA) (Proto)
    0x2491DF2F, // NBA Action '94 (USA) (Beta) (1994-01-04)
};
const force_32kb_sram_checksums = [_]u32{
    0xA4F2F011, // Al Michaels Announces HardBall III (USA, Europe)
};
const forced_sram_start_address: u32 = 0x200001;

const CartridgeRam = struct {
    data: ?[]u8,
    ram_type: CartridgeRamType,
    persistent: bool,
    dirty: bool,
    mapped: bool,
    start_address: u32,
    end_address: u32,

    fn initEmpty() CartridgeRam {
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

    fn initForced(allocator: std.mem.Allocator, rom_len: usize, ram_len: usize) !CartridgeRam {
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

    fn initFromRomHeader(allocator: std.mem.Allocator, rom: []const u8, checksum: u32) !CartridgeRam {
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

        const ram_type: CartridgeRamType = switch (header[2]) {
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

    fn deinit(self: *CartridgeRam, allocator: std.mem.Allocator) void {
        if (self.data) |data| allocator.free(data);
        self.* = initEmpty();
    }

    fn hasStorage(self: *const CartridgeRam) bool {
        return self.data != null;
    }

    fn clearDirty(self: *CartridgeRam) void {
        self.dirty = false;
    }

    fn setMapped(self: *CartridgeRam, mapped: bool) void {
        if (!self.hasStorage()) return;
        self.mapped = mapped;
    }

    fn mapIndex(self: *const CartridgeRam, address: u32) ?usize {
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

    fn readByte(self: *const CartridgeRam, address: u32) ?u8 {
        const data = self.data orelse return null;
        const index = self.mapIndex(address) orelse return null;
        return data[index];
    }

    fn writeByte(self: *CartridgeRam, address: u32, value: u8) bool {
        const data = self.data orelse return false;
        const index = self.mapIndex(address) orelse return false;
        data[index] = value;
        self.dirty = true;
        return true;
    }

    fn readWord(self: *const CartridgeRam, address: u32) ?u16 {
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

    fn writeWord(self: *CartridgeRam, address: u32, value: u16) bool {
        const msb = @as(u8, @truncate((value >> 8) & 0xFF));
        const lsb = @as(u8, @truncate(value & 0xFF));
        const wrote_high = self.writeByte(address, msb);
        const wrote_low = self.writeByte(address + 1, lsb);
        return wrote_high or wrote_low;
    }
};

pub const Bus = struct {
    rom: []u8,
    cartridge_ram: CartridgeRam,
    save_path: ?[]u8,
    ram: [64 * 1024]u8, // 64KB Work RAM
    vdp: Vdp,
    io: Io,
    z80: Z80,
    audio_timing: AudioTiming,
    io_master_remainder: u8,
    z80_master_credit: i64,
    z80_wait_master_cycles: u32,
    z80_odd_access: bool,
    m68k_wait_master_cycles: u32,
    open_bus: u16,

    fn readRomByte(self: *const Bus, address: u32) u8 {
        if (self.rom.len == 0) return 0;
        const rom_len_u32: u32 = @intCast(self.rom.len);
        if (address >= rom_len_u32) return 0; // open bus — prevents lock-on misdetection
        return self.rom[@intCast(address)];
    }

    fn initWithRomData(
        allocator: std.mem.Allocator,
        rom_data: []u8,
        rom_path: ?[]const u8,
        checksum_override: ?u32,
    ) !Bus {
        const checksum = checksum_override orelse std.hash.Crc32.hash(rom_data);
        var bus = Bus{
            .rom = rom_data,
            .cartridge_ram = try CartridgeRam.initFromRomHeader(allocator, rom_data, checksum),
            .save_path = null,
            .ram = [_]u8{0} ** (64 * 1024),
            .vdp = Vdp.init(),
            .io = Io.init(),
            .z80 = Z80.init(),
            .audio_timing = .{},
            .io_master_remainder = 0,
            .z80_master_credit = 0,
            .z80_wait_master_cycles = 0,
            .z80_odd_access = false,
            .m68k_wait_master_cycles = 0,
            .open_bus = 0,
        };

        if (bus.cartridge_ram.persistent and bus.cartridge_ram.hasStorage() and rom_path != null) {
            bus.save_path = try savePathForRom(allocator, rom_path.?);
            try bus.loadPersistentStorage();
        }

        return bus;
    }

    fn savePathForRom(allocator: std.mem.Allocator, rom_path: []const u8) ![]u8 {
        const extension = std.fs.path.extension(rom_path);
        if (extension.len == 0) {
            return std.fmt.allocPrint(allocator, "{s}.sav", .{rom_path});
        }

        return std.fmt.allocPrint(allocator, "{s}.sav", .{rom_path[0 .. rom_path.len - extension.len]});
    }

    fn writeCartridgeRegisterByte(self: *Bus, address: u32, value: u8) bool {
        if (address == 0xA130F1) {
            self.cartridge_ram.setMapped((value & 1) != 0);
            return true;
        }
        return false;
    }

    fn writeCartridgeRegisterWord(self: *Bus, address: u32, value: u16) bool {
        const register_address = address | 1;
        return self.writeCartridgeRegisterByte(register_address, @truncate(value));
    }

    pub fn hasCartridgeRam(self: *const Bus) bool {
        return self.cartridge_ram.hasStorage();
    }

    pub fn isCartridgeRamMapped(self: *const Bus) bool {
        return self.cartridge_ram.mapped;
    }

    pub fn isCartridgeRamPersistent(self: *const Bus) bool {
        return self.cartridge_ram.persistent;
    }

    pub fn persistentSavePath(self: *const Bus) ?[]const u8 {
        return self.save_path;
    }

    fn loadPersistentStorage(self: *Bus) !void {
        const save_path = self.save_path orelse return;
        if (!self.cartridge_ram.persistent) return;
        if (!self.cartridge_ram.hasStorage()) return;

        const file = std.fs.cwd().openFile(save_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer file.close();

        const data = self.cartridge_ram.data.?;
        const bytes_read = try file.readAll(data);
        if (bytes_read < data.len) {
            @memset(data[bytes_read..], 0);
        }
        self.cartridge_ram.clearDirty();
    }

    pub fn flushPersistentStorage(self: *Bus) !void {
        const save_path = self.save_path orelse return;
        if (!self.cartridge_ram.persistent or !self.cartridge_ram.dirty) return;

        const data = self.cartridge_ram.data orelse return;
        const file = try std.fs.cwd().createFile(save_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(data);
        self.cartridge_ram.clearDirty();
    }

    fn isZ80WindowAddress(address: u32) bool {
        const addr = address & 0xFFFFFF;
        return addr >= 0xA00000 and addr < 0xA10000;
    }

    fn hasZ80BusFor68k(self: *Bus) bool {
        // $A11100 reflects BUSACK on the 68k side. A pending request does not grant
        // access while RESET is held.
        return self.z80.readBusReq() == 0x0000;
    }

    fn singleM68kAccessWaitMasterCycles(self: *Bus, address: u32) u32 {
        if (!isZ80WindowAddress(address)) return 0;
        if (!self.hasZ80BusFor68k()) return 0;

        // 68k accesses into the Z80/YM/PSG window cost one additional 68k cycle.
        return clock.m68kCyclesToMaster(1);
    }

    pub fn m68kAccessWaitMasterCycles(self: *Bus, address: u32, size_bytes: u8) u32 {
        var wait = self.singleM68kAccessWaitMasterCycles(address);
        if (size_bytes >= 4) {
            wait += self.singleM68kAccessWaitMasterCycles(address + 2);
        }
        return wait;
    }

    fn readHostByteForZ80(self: *Bus, address: u32) u8 {
        const addr = address & 0xFFFFFF;
        if (addr >= 0xA00000 and addr < 0xA10000) return 0xFF;
        return self.read8(addr);
    }

    fn writeHostByteForZ80(self: *Bus, address: u32, value: u8) void {
        const addr = address & 0xFFFFFF;
        if (addr >= 0xA00000 and addr < 0xA10000) return;
        self.write8(addr, value);
    }

    fn z80HostReadCallback(userdata: ?*anyopaque, address: u32) callconv(.c) u8 {
        const self: *Bus = @ptrCast(@alignCast(userdata orelse return 0xFF));
        return self.readHostByteForZ80(address);
    }

    fn z80HostWriteCallback(userdata: ?*anyopaque, address: u32, value: u8) callconv(.c) void {
        const self: *Bus = @ptrCast(@alignCast(userdata orelse return));
        self.writeHostByteForZ80(address, value);
    }

    fn vdpDmaReadWordCallback(userdata: ?*anyopaque, address: u32) u16 {
        const self: *Bus = @ptrCast(@alignCast(userdata orelse return 0));
        return self.read16(address);
    }

    fn ensureZ80HostWindow(self: *Bus) void {
        self.z80.setHostCallbacks(self, z80HostReadCallback, z80HostWriteCallback);
    }

    fn latchOpenBus(self: *Bus, value: u16) u16 {
        self.open_bus = value;
        return value;
    }

    fn readMirroredZ80ControlRegister(self: *Bus, control_word: u16) u16 {
        const control_bits: u16 = if ((control_word & 0x0100) != 0) 0x0100 else 0x0000;
        return self.latchOpenBus((self.open_bus & ~@as(u16, 0x0100)) | control_bits);
    }

    fn readZ80BusAckRegister(self: *Bus) u16 {
        return self.readMirroredZ80ControlRegister(self.z80.readBusReq());
    }

    fn readZ80ResetRegister(self: *Bus) u16 {
        return self.readMirroredZ80ControlRegister(self.z80.readReset());
    }

    fn readVdpStatus(self: *Bus) u16 {
        const opcode: u16 = if (rocket68.getActiveCpu()) |cpu| cpu.core.ir else 0;
        const status = self.vdp.readControlAdjusted(opcode) | (self.open_bus & 0xFC00);
        self.open_bus = status;
        return status;
    }

    fn readVdpHVCounter(self: *Bus) u16 {
        const opcode: u16 = if (rocket68.getActiveCpu()) |cpu| cpu.core.ir else 0;
        const word = self.vdp.readHVCounterAdjusted(opcode);
        self.open_bus = word;
        return word;
    }

    fn readVersionRegister(self: *const Bus) u8 {
        var value: u8 = 0x20 | 0x80; // No Mega-CD, overseas region
        if (self.vdp.pal_mode) value |= 0x40;
        return value;
    }

    fn readIoRegisterByte(self: *Bus, address: u32) u8 {
        return switch (address & 0x1F) {
            0x00, 0x01 => self.readVersionRegister(),
            0x02, 0x03 => self.io.read(0x03),
            0x04, 0x05 => self.io.read(0x05),
            0x06, 0x07 => self.io.read(0x07),
            0x08, 0x09 => self.io.read(0x09),
            0x0A, 0x0B => self.io.read(0x0B),
            0x0C, 0x0D => self.io.read(0x0D),
            0x0E, 0x0F, 0x14, 0x15, 0x1A, 0x1B => 0xFF,
            else => 0x00,
        };
    }

    fn writeIoRegisterByte(self: *Bus, address: u32, value: u8) void {
        switch (address & 0x1F) {
            0x02, 0x03 => self.io.write(0x03, value),
            0x04, 0x05 => self.io.write(0x05, value),
            0x06, 0x07 => self.io.write(0x07, value),
            0x08, 0x09 => self.io.write(0x09, value),
            0x0A, 0x0B => self.io.write(0x0B, value),
            0x0C, 0x0D => self.io.write(0x0D, value),
            else => {},
        }
    }

    pub fn init(allocator: std.mem.Allocator, rom_path: ?[]const u8) !Bus {
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
            // Allocate dummy ROM if no path provided (for testing)
            rom_data = try allocator.alloc(u8, 4 * 1024 * 1024); // 4MB max
            @memset(rom_data, 0);
        }

        return initWithRomData(allocator, rom_data, rom_path, null);
    }

    pub fn initFromRomBytes(allocator: std.mem.Allocator, rom_bytes: []const u8) !Bus {
        const rom_data = try allocator.alloc(u8, rom_bytes.len);
        std.mem.copyForwards(u8, rom_data, rom_bytes);
        return initWithRomData(allocator, rom_data, null, null);
    }

    pub fn initFromRomBytesWithChecksum(allocator: std.mem.Allocator, rom_bytes: []const u8, checksum: u32) !Bus {
        const rom_data = try allocator.alloc(u8, rom_bytes.len);
        std.mem.copyForwards(u8, rom_data, rom_bytes);
        return initWithRomData(allocator, rom_data, null, checksum);
    }

    pub fn deinit(self: *Bus, allocator: std.mem.Allocator) void {
        self.z80.deinit();
        self.cartridge_ram.deinit(allocator);
        if (self.save_path) |save_path| allocator.free(save_path);
        allocator.free(self.rom);
    }

    // ---------------------------------------------------------
    // READ OPERATIONS
    // ---------------------------------------------------------

    pub fn read8(self: *Bus, address: u32) u8 {
        const addr = address & 0xFFFFFF; // 24-bit address bus

        if (self.cartridge_ram.readByte(addr)) |value| {
            return value;
        }

        if (addr == 0xA11100) return @truncate((self.readZ80BusAckRegister() >> 8) & 0xFF);
        if (addr == 0xA11101) return @truncate(self.readZ80BusAckRegister() & 0xFF);
        if (addr == 0xA11200) return @truncate((self.readZ80ResetRegister() >> 8) & 0xFF);
        if (addr == 0xA11201) return @truncate(self.readZ80ResetRegister() & 0xFF);

        if (addr < 0xA00000) {
            // ROM (mirrored into the 4MB cartridge window for smaller images).
            return self.readRomByte(addr);
        } else if (addr >= 0xE00000 and addr < 0x1000000) {
            // RAM (Mirrored at 0xE00000 - 0xFFFFFF)
            // Mask to 64KB (0xFFFF)
            return self.ram[addr & 0xFFFF];
        } else if (addr >= 0xA00000 and addr < 0xA10000) {
            // Z80 address-space window.
            if (!self.hasZ80BusFor68k()) return @truncate((self.open_bus >> 8) & 0xFF);
            self.ensureZ80HostWindow();
            const zaddr: u16 = @truncate(addr & 0x7FFF);
            return self.z80.readByte(zaddr);
        } else if (addr >= 0xC00000 and addr <= 0xDFFFFF) {
            const port = addr & 0x1F;
            if (port < 0x04) {
                const word = self.vdp.readData();
                self.open_bus = word;
                return if ((addr & 1) == 0) @intCast((word >> 8) & 0xFF) else @intCast(word & 0xFF);
            }
            if (port < 0x08) {
                const word = self.readVdpStatus();
                if (rocket68.getActiveCpu()) |cpu| cpu.clearInterrupt();
                return if ((addr & 1) == 0) @intCast((word >> 8) & 0xFF) else @intCast(word & 0xFF);
            }
            if (port < 0x10) {
                const word = self.readVdpHVCounter();
                return if ((addr & 1) == 0) @intCast((word >> 8) & 0xFF) else @intCast(word & 0xFF);
            }
            return 0xFF;
        } else if (addr >= 0xA10000 and addr < 0xA10100) {
            // IO
            return self.readIoRegisterByte(addr);
        }

        // Unmapped / IO Stub
        return 0;
    }

    pub fn read16(self: *Bus, address: u32) u16 {
        const addr = address & 0xFFFFFF;
        if (self.cartridge_ram.readWord(addr)) |value| {
            return self.latchOpenBus(value);
        }
        if (addr == 0xA11100) { // Z80 Bus Request
            return self.readZ80BusAckRegister();
        } else if (addr == 0xA11200) { // Z80 Reset
            return self.readZ80ResetRegister();
        } else if (addr >= 0xA00000 and addr < 0xA10000 and !self.hasZ80BusFor68k()) {
            return self.latchOpenBus(self.open_bus & 0xFF00);
        } else if (addr >= 0xA10000 and addr < 0xA10020) {
            return self.latchOpenBus(self.readIoRegisterByte(addr));
        } else if (addr >= 0xC00000 and addr <= 0xDFFFFF) {
            const port = addr & 0x1F;
            if (port < 0x04) return self.latchOpenBus(self.vdp.readData());
            if (port < 0x08) {
                const status = self.readVdpStatus();
                if (rocket68.getActiveCpu()) |cpu| cpu.clearInterrupt();
                return status;
            }
            if (port < 0x10) return self.readVdpHVCounter();
        }

        // M68k accesses are generally word-aligned, but we'll support unaligned for safety
        // Real hardware might throw address error on unaligned word access
        const high = self.read8(address);
        const low = self.read8(address + 1);
        return self.latchOpenBus((@as(u16, high) << 8) | low);
    }

    pub fn read32(self: *Bus, address: u32) u32 {
        const high = self.read16(address);
        const low = self.read16(address + 2);
        return (@as(u32, high) << 16) | low;
    }

    // ---------------------------------------------------------
    // WRITE OPERATIONS
    // ---------------------------------------------------------

    pub fn write8(self: *Bus, address: u32, value: u8) void {
        const addr = address & 0xFFFFFF;
        self.open_bus = (@as(u16, value) << 8) | value;

        if (self.writeCartridgeRegisterByte(addr, value)) return;
        if (self.cartridge_ram.writeByte(addr, value)) return;

        if (addr == 0xA11100) {
            self.z80.writeBusReq(@as(u16, value) << 8);
            return;
        } else if (addr == 0xA11101) {
            return;
        } else if (addr == 0xA11200) {
            self.z80.writeReset(@as(u16, value) << 8);
            return;
        } else if (addr == 0xA11201) {
            return;
        }

        if (addr < 0xA00000) {
            // ROM is read-only
            return;
        } else if (addr >= 0xE00000 and addr < 0x1000000) {
            // RAM
            self.ram[addr & 0xFFFF] = value;
        } else if (addr >= 0xA00000 and addr < 0xA10000) {
            // Z80 address-space window.
            if (!self.hasZ80BusFor68k()) return;
            self.ensureZ80HostWindow();
            const zaddr: u16 = @truncate(addr & 0x7FFF);
            self.z80.writeByte(zaddr, value);
            return;
        } else if (addr >= 0xA10000 and addr < 0xA10100) {
            // IO
            self.writeIoRegisterByte(addr, value);
        } else if (addr >= 0xC00000 and addr <= 0xDFFFFF) {
            const port = addr & 0x1F;
            const word: u16 = if ((addr & 1) == 0) (@as(u16, value) << 8) else @as(u16, value);
            if (port < 0x04) {
                self.vdp.writeData(word);
            } else if (port < 0x08) {
                self.vdp.writeControl(word);
            }
            return;
        }
    }

    pub fn write16(self: *Bus, address: u32, value: u16) void {
        const addr = address & 0xFFFFFF;
        self.open_bus = value;

        if (self.writeCartridgeRegisterWord(addr, value)) return;
        if (self.cartridge_ram.writeWord(addr, value)) return;

        if (addr >= 0xC00000 and addr <= 0xDFFFFF) {
            const port = addr & 0x1F;
            if (port < 0x04) {
                self.vdp.writeData(value);
            } else if (port < 0x08) {
                self.vdp.writeControl(value);
            }
            return;
        }

        if (addr == 0xA11100) { // Z80 Bus Request
            self.z80.writeBusReq(value);
            return;
        } else if (addr == 0xA11200) { // Z80 Reset
            self.z80.writeReset(value);
            return;
        }

        self.write8(address, @intCast((value >> 8) & 0xFF));
        self.write8(address + 1, @intCast(value & 0xFF));
    }

    pub fn write32(self: *Bus, address: u32, value: u32) void {
        const addr = address & 0xFFFFFF;
        if (addr >= 0xC00000 and addr <= 0xDFFFFF) {
            // VDP 32-bit writes are treated as two 16-bit writes
            self.write16(address, @intCast((value >> 16) & 0xFFFF));
            self.write16(address + 2, @intCast(value & 0xFFFF));
            return;
        }

        self.write16(address, @intCast((value >> 16) & 0xFFFF));
        self.write16(address + 2, @intCast(value & 0xFFFF));
    }

    fn recordZ80M68kBusAccesses(self: *Bus, access_count: u32) void {
        if (access_count == 0) return;

        const alternating_extra = if (self.z80_odd_access)
            (access_count / 2) + (access_count % 2)
        else
            access_count / 2;

        self.z80_wait_master_cycles += access_count * 49 + alternating_extra;
        if (!self.vdp.shouldHaltCpu()) {
            self.m68k_wait_master_cycles += access_count * clock.m68kCyclesToMaster(11);
        }
        if ((access_count & 1) != 0) {
            self.z80_odd_access = !self.z80_odd_access;
        }
    }

    fn advanceNonZ80Master(self: *Bus, master_cycles: u32) void {
        if (master_cycles == 0) return;

        self.vdp.step(master_cycles);
        self.audio_timing.consumeMaster(master_cycles);

        const io_total = @as(u32, self.io_master_remainder) + master_cycles;
        self.io.tick(io_total / clock.m68k_divider);
        self.io_master_remainder = @intCast(io_total % clock.m68k_divider);

        self.vdp.progressTransfers(master_cycles, self, vdpDmaReadWordCallback);
    }

    pub fn pendingM68kWaitMasterCycles(self: *const Bus) u32 {
        return self.m68k_wait_master_cycles;
    }

    pub fn consumeM68kWaitMasterCycles(self: *Bus, max_master_cycles: u32) u32 {
        const consumed = @min(max_master_cycles, self.m68k_wait_master_cycles);
        self.m68k_wait_master_cycles -= consumed;
        return consumed;
    }

    pub fn stepMaster(self: *Bus, master_cycles: u32) void {
        self.ensureZ80HostWindow();
        var remaining = master_cycles;

        while (true) {
            if (!self.z80.canRun()) {
                if (remaining != 0) self.advanceNonZ80Master(remaining);
                return;
            }

            if (self.z80_wait_master_cycles != 0) {
                if (remaining == 0) return;
                const stalled_master = @min(remaining, self.z80_wait_master_cycles);
                self.z80_wait_master_cycles -= stalled_master;
                self.advanceNonZ80Master(stalled_master);
                remaining -= stalled_master;
                continue;
            }

            const instruction_threshold = @as(i64, clock.z80_divider);
            if (self.z80_master_credit < instruction_threshold) {
                if (remaining == 0) return;
                const needed_master: u32 = @intCast(instruction_threshold - self.z80_master_credit);
                const chunk = @min(remaining, needed_master);
                self.advanceNonZ80Master(chunk);
                self.z80_master_credit += @intCast(chunk);
                remaining -= chunk;
                continue;
            }

            const instruction_cycles = self.z80.stepInstruction();
            if (instruction_cycles == 0) {
                if (remaining != 0) self.advanceNonZ80Master(remaining);
                return;
            }

            self.z80_master_credit -= @as(i64, instruction_cycles) * clock.z80_divider;
            self.recordZ80M68kBusAccesses(self.z80.take68kBusAccessCount());
        }
    }

    pub fn step(self: *Bus, m68k_cycles: u32) void {
        self.stepMaster(clock.m68kCyclesToMaster(m68k_cycles));
    }
};

fn makeRomWithSramHeader(
    allocator: std.mem.Allocator,
    rom_len: usize,
    ram_type: u8,
    start_address: u32,
    end_address: u32,
) ![]u8 {
    var rom = try allocator.alloc(u8, rom_len);
    @memset(rom, 0);
    @memcpy(rom[0x100..0x104], "SEGA");
    rom[0x1B0] = 'R';
    rom[0x1B1] = 'A';
    rom[0x1B2] = ram_type;
    rom[0x1B3] = 0x20;
    std.mem.writeInt(u32, rom[0x1B4..0x1B8], start_address, .big);
    std.mem.writeInt(u32, rom[0x1B8..0x1BC], end_address, .big);
    return rom;
}

fn makeBasicGenesisRom(allocator: std.mem.Allocator, rom_len: usize) ![]u8 {
    var rom = try allocator.alloc(u8, rom_len);
    @memset(rom, 0);
    @memcpy(rom[0x100..0x104], "SEGA");
    return rom;
}

fn writeSerial(rom: []u8, base: usize, serial: []const u8) void {
    @memcpy(rom[base + 0x180 .. base + 0x180 + serial.len], serial);
}

test "cartridge odd-byte sram past end of rom is auto-mapped" {
    const rom = try makeRomWithSramHeader(testing.allocator, 0x200000, 0xF8, 0x200001, 0x203FFF);
    defer testing.allocator.free(rom);

    var bus = try Bus.initFromRomBytes(testing.allocator, rom);
    defer bus.deinit(testing.allocator);

    try testing.expect(bus.hasCartridgeRam());
    try testing.expect(bus.isCartridgeRamMapped());
    try testing.expect(bus.isCartridgeRamPersistent());

    bus.write8(0x0020_0001, 0x5A);
    try testing.expectEqual(@as(u8, 0x5A), bus.read8(0x0020_0001));
    try testing.expectEqual(@as(u16, 0x5A5A), bus.read16(0x0020_0000));
}

test "forced 8kb sram checksum maps odd-byte persistent ram without header" {
    const rom = try makeBasicGenesisRom(testing.allocator, 0x100000);
    defer testing.allocator.free(rom);

    var bus = try Bus.initFromRomBytesWithChecksum(testing.allocator, rom, 0x8135702C);
    defer bus.deinit(testing.allocator);

    try testing.expect(bus.hasCartridgeRam());
    try testing.expect(bus.isCartridgeRamMapped());
    try testing.expect(bus.isCartridgeRamPersistent());

    bus.write8(0x0020_0001, 0xA5);
    bus.write8(0x0020_3FFF, 0x5A);
    try testing.expectEqual(@as(u8, 0xA5), bus.read8(0x0020_0001));
    try testing.expectEqual(@as(u8, 0x5A), bus.read8(0x0020_3FFF));
    try testing.expectEqual(@as(u16, 0xA5A5), bus.read16(0x0020_0000));
}

test "forced 32kb sram checksum maps full odd-byte 20ffff range without header" {
    const rom = try makeBasicGenesisRom(testing.allocator, 0x100000);
    defer testing.allocator.free(rom);

    var bus = try Bus.initFromRomBytesWithChecksum(testing.allocator, rom, 0xA4F2F011);
    defer bus.deinit(testing.allocator);

    try testing.expect(bus.hasCartridgeRam());
    try testing.expect(bus.isCartridgeRamMapped());
    try testing.expect(bus.isCartridgeRamPersistent());

    bus.write8(0x0020_0001, 0x12);
    bus.write8(0x0020_FFFF, 0x34);
    try testing.expectEqual(@as(u8, 0x12), bus.read8(0x0020_0001));
    try testing.expectEqual(@as(u8, 0x34), bus.read8(0x0020_FFFF));
    try testing.expectEqual(@as(u16, 0x3434), bus.read16(0x0020_FFFE));
}

test "sonic and knuckles lock-on cartridge header enables locked-on sram" {
    var rom = try testing.allocator.alloc(u8, 0x400000);
    defer testing.allocator.free(rom);
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

    var bus = try Bus.initFromRomBytes(testing.allocator, rom);
    defer bus.deinit(testing.allocator);

    try testing.expect(bus.hasCartridgeRam());
    try testing.expect(!bus.isCartridgeRamMapped());

    bus.write16(0x00A1_30F0, 0x0001);
    try testing.expect(bus.isCartridgeRamMapped());
    bus.write8(0x0020_0001, 0xA5);
    try testing.expectEqual(@as(u8, 0xA5), bus.read8(0x0020_0001));
}

test "cartridge sram map register toggles rom fallback" {
    var rom = try makeRomWithSramHeader(testing.allocator, 0x400000, 0xF8, 0x200001, 0x203FFF);
    defer testing.allocator.free(rom);
    rom[0x200001] = 0x33;

    var bus = try Bus.initFromRomBytes(testing.allocator, rom);
    defer bus.deinit(testing.allocator);

    try testing.expect(bus.hasCartridgeRam());
    try testing.expect(!bus.isCartridgeRamMapped());
    try testing.expectEqual(@as(u8, 0x33), bus.read8(0x0020_0001));

    bus.write8(0x0020_0001, 0xAA);
    try testing.expectEqual(@as(u8, 0x33), bus.read8(0x0020_0001));

    bus.write16(0x00A1_30F0, 0x0001);
    try testing.expect(bus.isCartridgeRamMapped());

    bus.write8(0x0020_0001, 0xAA);
    try testing.expectEqual(@as(u8, 0xAA), bus.read8(0x0020_0001));

    bus.write16(0x00A1_30F0, 0x0000);
    try testing.expect(!bus.isCartridgeRamMapped());
    try testing.expectEqual(@as(u8, 0x33), bus.read8(0x0020_0001));

    bus.write16(0x00A1_30F0, 0x0001);
    try testing.expectEqual(@as(u8, 0xAA), bus.read8(0x0020_0001));
}

test "cartridge sixteen-bit sram stores both bytes of a word" {
    const rom = try makeRomWithSramHeader(testing.allocator, 0x100000, 0xE0, 0x200000, 0x20FFFF);
    defer testing.allocator.free(rom);

    var bus = try Bus.initFromRomBytes(testing.allocator, rom);
    defer bus.deinit(testing.allocator);

    try testing.expect(bus.hasCartridgeRam());
    try testing.expect(bus.isCartridgeRamMapped());

    bus.write16(0x0020_0000, 0x1234);
    try testing.expectEqual(@as(u16, 0x1234), bus.read16(0x0020_0000));
    try testing.expectEqual(@as(u8, 0x12), bus.read8(0x0020_0000));
    try testing.expectEqual(@as(u8, 0x34), bus.read8(0x0020_0001));
}

test "persistent cartridge sram flushes to save file and reloads" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rom = try makeRomWithSramHeader(testing.allocator, 0x200000, 0xF8, 0x200001, 0x203FFF);
    defer testing.allocator.free(rom);
    try tmp.dir.writeFile(.{ .sub_path = "persist.md", .data = rom });

    const rom_path = try tmp.dir.realpathAlloc(testing.allocator, "persist.md");
    defer testing.allocator.free(rom_path);

    {
        var bus = try Bus.init(testing.allocator, rom_path);
        defer bus.deinit(testing.allocator);

        const save_path = bus.persistentSavePath() orelse unreachable;
        bus.write8(0x0020_0001, 0xA5);
        bus.write8(0x0020_0003, 0x5A);
        try bus.flushPersistentStorage();

        var save_file = try std.fs.cwd().openFile(save_path, .{});
        defer save_file.close();

        var first_bytes: [2]u8 = undefined;
        const bytes_read = try save_file.readAll(&first_bytes);
        try testing.expectEqual(@as(usize, 2), bytes_read);
        try testing.expectEqualSlices(u8, &[_]u8{ 0xA5, 0x5A }, first_bytes[0..]);
    }

    {
        var bus = try Bus.init(testing.allocator, rom_path);
        defer bus.deinit(testing.allocator);

        try testing.expectEqual(@as(u8, 0xA5), bus.read8(0x0020_0001));
        try testing.expectEqual(@as(u8, 0x5A), bus.read8(0x0020_0003));
    }
}

test "z80 bus mapped memory and busreq registers behave as expected" {
    var bus = try Bus.init(testing.allocator, null);
    defer bus.deinit(testing.allocator);

    // Without BUSREQ, 68k should not see/modify Z80 window.
    bus.write8(0x00A0_0010, 0x5A);
    try testing.expectEqual(@as(u8, 0x5A), bus.read8(0x00A0_0010));
    try testing.expectEqual(@as(u16, 0x5A00), bus.read16(0x00A0_0010));

    bus.write16(0x00A1_1100, 0x0100); // Request Z80 bus
    try testing.expectEqual(@as(u16, 0x0000), bus.read16(0x00A1_1100));

    bus.write8(0x00A0_0010, 0x5A);
    try testing.expectEqual(@as(u8, 0x5A), bus.read8(0x00A0_0010));

    bus.write16(0x00A1_1100, 0x0000); // Release Z80 bus
    try testing.expectEqual(@as(u16, 0x0100), bus.read16(0x00A1_1100));

    // Once released, 68k window should be blocked again.
    bus.write8(0x00A0_0010, 0xA5);
    try testing.expectEqual(@as(u8, 0xA5), bus.read8(0x00A0_0010));
    try testing.expectEqual(@as(u16, 0xA500), bus.read16(0x00A0_0010));
}

test "z80 bus request does not grant bus while reset is held" {
    var bus = try Bus.init(testing.allocator, null);
    defer bus.deinit(testing.allocator);

    bus.write16(0x00A1_1200, 0x0000); // Assert reset
    bus.write16(0x00A1_1100, 0x0100); // Request Z80 bus

    try testing.expectEqual(@as(u16, 0x0100), bus.read16(0x00A1_1100));
    bus.write8(0x00A0_0010, 0x5A);
    try testing.expectEqual(@as(u8, 0x5A), bus.read8(0x00A0_0010));
    try testing.expectEqual(@as(u16, 0x5A00), bus.read16(0x00A0_0010));

    bus.write16(0x00A1_1200, 0x0100); // Release reset

    try testing.expectEqual(@as(u16, 0x0000), bus.read16(0x00A1_1100));
    bus.write8(0x00A0_0010, 0x5A);
    try testing.expectEqual(@as(u8, 0x5A), bus.read8(0x00A0_0010));
}

test "z80 busack and reset reads preserve open-bus bits" {
    var bus = try Bus.init(testing.allocator, null);
    defer bus.deinit(testing.allocator);

    bus.open_bus = 0xA400;
    try testing.expectEqual(@as(u16, 0xA500), bus.read16(0x00A1_1100));

    bus.write16(0x00A1_1100, 0x0100); // Request/grant Z80 bus
    bus.open_bus = 0xA400;
    try testing.expectEqual(@as(u16, 0xA400), bus.read16(0x00A1_1100));

    bus.write16(0x00A1_1200, 0x0000); // Assert reset
    bus.open_bus = 0xB600;
    try testing.expectEqual(@as(u16, 0xB600), bus.read16(0x00A1_1200));

    bus.write16(0x00A1_1200, 0x0100); // Release reset
    bus.open_bus = 0xB600;
    try testing.expectEqual(@as(u16, 0xB700), bus.read16(0x00A1_1200));
}

test "z80 control registers support byte reads and writes on even address" {
    var bus = try Bus.init(testing.allocator, null);
    defer bus.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0x01), bus.read8(0x00A1_1100));
    try testing.expectEqual(@as(u8, 0x00), bus.read8(0x00A1_1101));
    try testing.expectEqual(@as(u8, 0x01), bus.read8(0x00A1_1200));
    try testing.expectEqual(@as(u8, 0x00), bus.read8(0x00A1_1201));

    bus.write8(0x00A1_1100, 0x01); // Request Z80 bus via high byte
    try testing.expectEqual(@as(u16, 0x0001), bus.read16(0x00A1_1100));
    try testing.expectEqual(@as(u8, 0x00), bus.read8(0x00A1_1100));

    bus.write8(0x00A1_1101, 0x01); // Low byte should not change BUSREQ
    try testing.expectEqual(@as(u16, 0x0001), bus.read16(0x00A1_1100));

    bus.write8(0x00A1_1200, 0x00); // Assert reset via high byte
    try testing.expectEqual(@as(u16, 0x0000), bus.read16(0x00A1_1200));
    try testing.expectEqual(@as(u8, 0x00), bus.read8(0x00A1_1200));

    bus.write8(0x00A1_1201, 0x01); // Low byte should not release reset
    try testing.expectEqual(@as(u16, 0x0001), bus.read16(0x00A1_1200));

    bus.write8(0x00A1_1200, 0x01); // Release reset
    bus.write8(0x00A1_1100, 0x00); // Release bus
    try testing.expectEqual(@as(u16, 0x0100), bus.read16(0x00A1_1200));
    try testing.expectEqual(@as(u16, 0x0100), bus.read16(0x00A1_1100));
    try testing.expectEqual(@as(u8, 0x01), bus.read8(0x00A1_1200));
    try testing.expectEqual(@as(u8, 0x01), bus.read8(0x00A1_1100));
}

test "unused vdp port reads return ff" {
    var bus = try Bus.init(testing.allocator, null);
    defer bus.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0xFF), bus.read8(0x00C0_0011));
    try testing.expectEqual(@as(u16, 0xFFFF), bus.read16(0x00C0_0010));
}

test "io version register reflects pal bit and word reads use byte value" {
    var bus = try Bus.init(testing.allocator, null);
    defer bus.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0xA0), bus.read8(0x00A1_0000));
    try testing.expectEqual(@as(u8, 0xA0), bus.read8(0x00A1_0001));
    try testing.expectEqual(@as(u16, 0x00A0), bus.read16(0x00A1_0000));

    bus.vdp.pal_mode = true;
    try testing.expectEqual(@as(u8, 0xE0), bus.read8(0x00A1_0000));
    try testing.expectEqual(@as(u16, 0x00E0), bus.read16(0x00A1_0000));
}

test "io register pairs mirror byte registers and tx data defaults high" {
    var bus = try Bus.init(testing.allocator, null);
    defer bus.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0x7F), bus.read8(0x00A1_0002));
    try testing.expectEqual(@as(u8, 0x7F), bus.read8(0x00A1_0003));
    try testing.expectEqual(@as(u16, 0x007F), bus.read16(0x00A1_0002));

    bus.io.write(0x09, 0x40);
    try testing.expectEqual(@as(u8, 0x40), bus.read8(0x00A1_0008));
    try testing.expectEqual(@as(u8, 0x40), bus.read8(0x00A1_0009));
    try testing.expectEqual(@as(u16, 0x0040), bus.read16(0x00A1_0008));

    try testing.expectEqual(@as(u8, 0xFF), bus.read8(0x00A1_000E));
    try testing.expectEqual(@as(u8, 0xFF), bus.read8(0x00A1_000F));
    try testing.expectEqual(@as(u16, 0x00FF), bus.read16(0x00A1_000E));
}

test "io port c data and control registers are exposed" {
    var bus = try Bus.init(testing.allocator, null);
    defer bus.deinit(testing.allocator);

    bus.io.write(0x07, 0x5A);
    bus.io.write(0x0D, 0xA5);

    try testing.expectEqual(@as(u8, 0x5A), bus.read8(0x00A1_0006));
    try testing.expectEqual(@as(u8, 0x5A), bus.read8(0x00A1_0007));
    try testing.expectEqual(@as(u16, 0x005A), bus.read16(0x00A1_0006));

    try testing.expectEqual(@as(u8, 0xA5), bus.read8(0x00A1_000C));
    try testing.expectEqual(@as(u8, 0xA5), bus.read8(0x00A1_000D));
    try testing.expectEqual(@as(u16, 0x00A5), bus.read16(0x00A1_000C));
}

test "io register writes mirror even and odd addresses" {
    var bus = try Bus.init(testing.allocator, null);
    defer bus.deinit(testing.allocator);

    bus.write8(0x00A1_0002, 0x40);
    try testing.expectEqual(@as(u8, 0x40), bus.io.data[0]);

    bus.write8(0x00A1_0008, 0x55);
    try testing.expectEqual(@as(u8, 0x55), bus.io.read(0x09));

    bus.write8(0x00A1_0006, 0xAA);
    try testing.expectEqual(@as(u8, 0xAA), bus.io.read(0x07));

    bus.write8(0x00A1_000C, 0x11);
    try testing.expectEqual(@as(u8, 0x11), bus.io.read(0x0D));
}

test "bus stepping advances controller timing" {
    var bus = try Bus.init(testing.allocator, null);
    defer bus.deinit(testing.allocator);

    bus.write8(0x00A1_0003, 0x00);
    bus.write8(0x00A1_0009, 0x40);
    bus.write8(0x00A1_0009, 0x00);

    try testing.expectEqual(@as(u8, 0x03), bus.read8(0x00A1_0003) & 0x43);
    bus.stepMaster(clock.m68kCyclesToMaster(29));
    try testing.expectEqual(@as(u8, 0x03), bus.read8(0x00A1_0003) & 0x43);
    bus.stepMaster(clock.m68kCyclesToMaster(1));
    try testing.expectEqual(@as(u8, 0x43), bus.read8(0x00A1_0003) & 0x43);
}

test "z80 audio window latches YM2612 and PSG writes" {
    var bus = try Bus.init(testing.allocator, null);
    defer bus.deinit(testing.allocator);

    bus.write16(0x00A1_1100, 0x0100); // Request Z80 bus

    // YM2612 port 0: addr then data
    bus.write8(0x00A0_4000, 0x22);
    bus.write8(0x00A0_4001, 0x0F);
    try testing.expectEqual(@as(u8, 0x0F), bus.z80.getYmRegister(0, 0x22));

    // YM2612 port 1: addr then data
    bus.write8(0x00A0_4002, 0x2B);
    bus.write8(0x00A0_4003, 0x80);
    try testing.expectEqual(@as(u8, 0x80), bus.z80.getYmRegister(1, 0x2B));

    // PSG latch/data byte
    bus.write8(0x00A0_7F11, 0x90);
    try testing.expectEqual(@as(u8, 0x90), bus.z80.getPsgLast());
}

test "psg latch/data writes decode tone and volume registers" {
    var bus = try Bus.init(testing.allocator, null);
    defer bus.deinit(testing.allocator);

    bus.write16(0x00A1_1100, 0x0100); // Request Z80 bus

    // Tone channel 0: latch low nibble, then data high bits.
    bus.write8(0x00A0_7F11, 0x80 | 0x0A); // ch0 tone low=0xA
    bus.write8(0x00A0_7F11, 0x15); // high 6 bits
    try testing.expectEqual(@as(u16, 0x15A), bus.z80.getPsgTone(0));

    // Volume channel 2 attenuation.
    bus.write8(0x00A0_7F11, 0xC0 | 0x10 | 0x07); // ch2 volume=7
    try testing.expectEqual(@as(u8, 0x07), bus.z80.getPsgVolume(2));

    // Noise register write.
    bus.write8(0x00A0_7F11, 0xE0 | 0x03);
    try testing.expectEqual(@as(u8, 0x03), bus.z80.getPsgNoise());
}

test "ym key-on register updates channel key mask" {
    var bus = try Bus.init(testing.allocator, null);
    defer bus.deinit(testing.allocator);

    bus.write16(0x00A1_1100, 0x0100); // Request Z80 bus

    // Key on channel 0 (operators set in upper nibble).
    bus.write8(0x00A0_4000, 0x28);
    bus.write8(0x00A0_4001, 0xF0);
    try testing.expectEqual(@as(u8, 0x01), bus.z80.getYmKeyMask());

    // Key on channel 4 (ch=1 with high-bank bit set).
    bus.write8(0x00A0_4000, 0x28);
    bus.write8(0x00A0_4001, 0xF5);
    try testing.expectEqual(@as(u8, 0x11), bus.z80.getYmKeyMask());

    // Key off channel 0.
    bus.write8(0x00A0_4000, 0x28);
    bus.write8(0x00A0_4001, 0x00);
    try testing.expectEqual(@as(u8, 0x10), bus.z80.getYmKeyMask());
}

test "ym dac writes are queued for audio output" {
    var bus = try Bus.init(testing.allocator, null);
    defer bus.deinit(testing.allocator);

    bus.write16(0x00A1_1100, 0x0100); // Request Z80 bus

    bus.write8(0x00A0_4000, 0x2A);
    bus.write8(0x00A0_4001, 0x12);
    bus.write8(0x00A0_4001, 0x34);

    var samples: [4]u8 = undefined;
    const count = bus.z80.takeYmDacSamples(samples[0..]);
    try testing.expectEqual(@as(usize, 2), count);
    try testing.expectEqual(@as(u8, 0x12), samples[0]);
    try testing.expectEqual(@as(u8, 0x34), samples[1]);
}

test "z80 reset clears ym2612 register shadow state" {
    var bus = try Bus.init(testing.allocator, null);
    defer bus.deinit(testing.allocator);

    bus.write16(0x00A1_1100, 0x0100); // Request Z80 bus

    bus.write8(0x00A0_4000, 0x22);
    bus.write8(0x00A0_4001, 0x0F);
    bus.write8(0x00A0_4000, 0x28);
    bus.write8(0x00A0_4001, 0xF0);

    try testing.expectEqual(@as(u8, 0x0F), bus.z80.getYmRegister(0, 0x22));
    try testing.expectEqual(@as(u8, 0x01), bus.z80.getYmKeyMask());

    bus.write16(0x00A1_1200, 0x0000); // Assert reset

    try testing.expectEqual(@as(u8, 0x00), bus.z80.getYmRegister(0, 0x22));
    try testing.expectEqual(@as(u8, 0x00), bus.z80.getYmRegister(0, 0x28));
    try testing.expectEqual(@as(u8, 0x00), bus.z80.getYmKeyMask());
}

test "z80 reset preserves uploaded z80 ram" {
    var bus = try Bus.init(testing.allocator, null);
    defer bus.deinit(testing.allocator);

    bus.write16(0x00A1_1100, 0x0100); // Request Z80 bus
    bus.write16(0x00A1_1200, 0x0100); // Keep reset released while uploading

    bus.write8(0x00A0_0000, 0xAF);
    bus.write8(0x00A0_0001, 0x01);
    bus.write8(0x00A0_0002, 0xD9);

    bus.write16(0x00A1_1200, 0x0000); // Pulse reset before starting the uploaded program

    try testing.expectEqual(@as(u8, 0xAF), bus.z80.readByte(0x0000));
    try testing.expectEqual(@as(u8, 0x01), bus.z80.readByte(0x0001));
    try testing.expectEqual(@as(u8, 0xD9), bus.z80.readByte(0x0002));
}

test "z80 bank register selects 68k ROM window" {
    var bus = try Bus.init(testing.allocator, null);
    defer bus.deinit(testing.allocator);

    // Populate distinct bytes in ROM bank 0 and bank 1.
    bus.rom[0x0000] = 0x12;
    bus.rom[0x8000] = 0x34;

    bus.write16(0x00A1_1100, 0x0100); // Request Z80 bus
    bus.stepMaster(0); // Ensure Z80 host callbacks are installed

    // Default bank is 0, so Z80 0x8000 maps to 68k 0x000000.
    try testing.expectEqual(@as(u8, 0x12), bus.z80.readByte(0x8000));

    // Bank register is 9-bit serial, shifted by writes to 0x6000..0x60FF.
    // Program bank=1 by writing bit0=1 followed by zeros for remaining bits.
    bus.write8(0x00A0_6000, 1);
    for (0..8) |_| {
        bus.write8(0x00A0_6000, 0);
    }

    try testing.expectEqual(@as(u16, 1), bus.z80.getBank());
    try testing.expectEqual(@as(u8, 0x34), bus.z80.readByte(0x8000));
}

test "z80 68k-bus stall is applied before the next instruction" {
    var bus = try Bus.init(testing.allocator, null);
    defer bus.deinit(testing.allocator);

    // Loop forever on: LD A,($8000) ; JR $0000
    bus.z80.reset();
    bus.z80.writeByte(0x0000, 0x3A);
    bus.z80.writeByte(0x0001, 0x00);
    bus.z80.writeByte(0x0002, 0x80);
    bus.z80.writeByte(0x0003, 0x18);
    bus.z80.writeByte(0x0004, 0xFB);

    bus.rom[0x0000] = 0x12;

    // This is enough time for the first banked read and its reciprocal stall,
    // but not enough to begin the following JR if the stall is applied inline.
    bus.stepMaster(258);
    try testing.expectEqual(@as(u16, 0x0003), bus.z80.getPc());
    try testing.expectEqual(@as(u32, 0), bus.z80_wait_master_cycles);
    try testing.expectEqual(clock.m68kCyclesToMaster(11), bus.pendingM68kWaitMasterCycles());

    // The next master cycle starts the JR, and the remaining instruction cost is
    // carried as debt instead of letting the following instruction run early.
    bus.stepMaster(1);
    try testing.expectEqual(@as(u16, 0x0000), bus.z80.getPc());
    try testing.expect(bus.z80_master_credit < 0);

    bus.stepMaster(164);
    try testing.expectEqual(@as(u16, 0x0000), bus.z80.getPc());
    try testing.expectEqual(@as(i64, -1), bus.z80_master_credit);

    bus.stepMaster(16);
    try testing.expectEqual(@as(u16, 0x0003), bus.z80.getPc());
    try testing.expect(bus.z80_master_credit < 0);
    try testing.expectEqual(clock.m68kCyclesToMaster(22), bus.pendingM68kWaitMasterCycles());
}

test "z80 instruction overshoot carries between bus slices" {
    var bus = try Bus.init(testing.allocator, null);
    defer bus.deinit(testing.allocator);

    bus.z80.reset();
    bus.z80.writeByte(0x0000, 0x00); // NOP
    bus.z80.writeByte(0x0001, 0x00); // NOP

    bus.stepMaster(clock.z80_divider);
    try testing.expectEqual(@as(u16, 0x0001), bus.z80.getPc());
    try testing.expectEqual(@as(i64, -45), bus.z80_master_credit);

    bus.stepMaster(45);
    try testing.expectEqual(@as(u16, 0x0001), bus.z80.getPc());
    try testing.expectEqual(@as(i64, 0), bus.z80_master_credit);

    bus.stepMaster(clock.z80_divider);
    try testing.expectEqual(@as(u16, 0x0002), bus.z80.getPc());
    try testing.expectEqual(@as(i64, -45), bus.z80_master_credit);
}

test "vdp memory-to-vram dma is progressed by vdp with fifo latency" {
    var bus = try Bus.init(testing.allocator, null);
    defer bus.deinit(testing.allocator);

    bus.write16(0x00E0_0000, 0xABCD);

    bus.vdp.regs[15] = 2;
    bus.vdp.code = 0x1;
    bus.vdp.addr = 0x0000;
    bus.vdp.dma_active = true;
    bus.vdp.dma_fill = false;
    bus.vdp.dma_copy = false;
    bus.vdp.dma_source_addr = 0x00E0_0000;
    bus.vdp.dma_length = 1;
    bus.vdp.dma_remaining = 1;

    try testing.expect(bus.vdp.shouldHaltCpu());

    bus.stepMaster(8);
    try testing.expectEqual(@as(u8, 0), bus.vdp.vram[0]);
    try testing.expectEqual(@as(u8, 0), bus.vdp.vram[1]);
    try testing.expect(bus.vdp.dma_active);

    bus.stepMaster(8);
    try testing.expectEqual(@as(u8, 0), bus.vdp.vram[0]);
    try testing.expect(bus.vdp.dma_active);

    bus.stepMaster(8);
    try testing.expectEqual(@as(u8, 0xAB), bus.vdp.vram[0]);
    try testing.expectEqual(@as(u8, 0xCD), bus.vdp.vram[1]);
    try testing.expect(!bus.vdp.dma_active);
    try testing.expect(!bus.vdp.shouldHaltCpu());
}

test "vdp status high bits come from bus open bus" {
    var bus = try Bus.init(testing.allocator, null);
    defer bus.deinit(testing.allocator);

    bus.write16(0x00E0_0000, 0xA5A5);

    const status = bus.read16(0x00C0_0004);
    try testing.expectEqual(@as(u16, 0xA400), status & 0xFC00);
    try testing.expectEqual(@as(u16, 0x0200), status & 0x0300);
}
