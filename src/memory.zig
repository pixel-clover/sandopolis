const std = @import("std");
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

    fn initFromRomHeader(allocator: std.mem.Allocator, rom: []const u8) !CartridgeRam {
        if (rom.len < 0x1BC) return initEmpty();

        const header = rom[0x1B0..0x1BC];
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

    fn initWithRomData(allocator: std.mem.Allocator, rom_data: []u8, rom_path: ?[]const u8) !Bus {
        var bus = Bus{
            .rom = rom_data,
            .cartridge_ram = try CartridgeRam.initFromRomHeader(allocator, rom_data),
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

        return initWithRomData(allocator, rom_data, rom_path);
    }

    pub fn initFromRomBytes(allocator: std.mem.Allocator, rom_bytes: []const u8) !Bus {
        const rom_data = try allocator.alloc(u8, rom_bytes.len);
        std.mem.copyForwards(u8, rom_data, rom_bytes);
        return initWithRomData(allocator, rom_data, null);
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
            const zaddr: u16 = @truncate(addr & 0xFFFF);
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
            return self.io.read(addr);
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
            const zaddr: u16 = @truncate(addr & 0xFFFF);
            self.z80.writeByte(zaddr, value);
            return;
        } else if (addr >= 0xA10000 and addr < 0xA10100) {
            // IO
            self.io.write(addr, value);
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
