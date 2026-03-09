const std = @import("std");
const testing = std.testing;
const Cartridge = @import("cartridge.zig").Cartridge;
const io_window = @import("io_window.zig");
const vdp_ports = @import("vdp_ports.zig");
const z80_host_bridge = @import("z80_host_bridge.zig");
const clock = @import("../clock.zig");
const AudioTiming = @import("../audio/timing.zig").AudioTiming;
const Vdp = @import("../video/vdp.zig").Vdp;
const Io = @import("../input/io.zig").Io;
const Z80 = @import("../cpu/z80.zig").Z80;
const MemoryInterface = @import("../cpu/memory_interface.zig").MemoryInterface;
const SchedulerBus = @import("../scheduler/runtime.zig").SchedulerBus;

pub const Bus = struct {
    rom: []u8,
    cartridge: Cartridge,
    ram: [64 * 1024]u8,
    vdp: Vdp,
    io: Io,
    z80: Z80,
    z80_host_bridge: z80_host_bridge.HostBridge,
    audio_timing: AudioTiming,
    io_master_remainder: u8,
    z80_master_credit: i64,
    z80_wait_master_cycles: u32,
    z80_odd_access: bool,
    m68k_wait_master_cycles: u32,
    open_bus: u16,
    fn initWithCartridge(cartridge: Cartridge) Bus {
        const bus = Bus{
            .rom = cartridge.rom,
            .cartridge = cartridge,
            .ram = [_]u8{0} ** (64 * 1024),
            .vdp = Vdp.init(),
            .io = Io.init(),
            .z80 = Z80.init(),
            .z80_host_bridge = z80_host_bridge.HostBridge.init(z80HostWindowReadByte, z80HostWindowWriteByte),
            .audio_timing = .{},
            .io_master_remainder = 0,
            .z80_master_credit = 0,
            .z80_wait_master_cycles = 0,
            .z80_odd_access = false,
            .m68k_wait_master_cycles = 0,
            .open_bus = 0,
        };
        return bus;
    }

    pub fn hasCartridgeRam(self: *const Bus) bool {
        return self.cartridge.hasRam();
    }

    pub fn isCartridgeRamMapped(self: *const Bus) bool {
        return self.cartridge.isRamMapped();
    }

    pub fn isCartridgeRamPersistent(self: *const Bus) bool {
        return self.cartridge.isRamPersistent();
    }

    pub fn persistentSavePath(self: *const Bus) ?[]const u8 {
        return self.cartridge.persistentSavePath();
    }

    pub fn flushPersistentStorage(self: *Bus) !void {
        try self.cartridge.flushPersistentStorage();
    }

    fn isZ80WindowAddress(address: u32) bool {
        const addr = address & 0xFFFFFF;
        return addr >= 0xA00000 and addr < 0xA10000;
    }

    fn hasZ80BusFor68k(self: *Bus) bool {
        return self.z80.readBusReq() == 0x0000;
    }

    fn singleM68kAccessWaitMasterCycles(self: *Bus, address: u32) u32 {
        if (!isZ80WindowAddress(address)) return 0;
        if (!self.hasZ80BusFor68k()) return 0;

        return clock.m68kCyclesToMaster(1);
    }

    pub fn m68kAccessWaitMasterCycles(self: *Bus, address: u32, size_bytes: u8) u32 {
        var wait = self.singleM68kAccessWaitMasterCycles(address);
        if (size_bytes >= 4) {
            wait += self.singleM68kAccessWaitMasterCycles(address + 2);
        }
        return wait;
    }

    fn z80HostWindowReadByte(ctx: ?*anyopaque, address: u32) u8 {
        const self: *Bus = @ptrCast(@alignCast(ctx orelse return 0xFF));
        return self.read8(address);
    }

    fn z80HostWindowWriteByte(ctx: ?*anyopaque, address: u32, value: u8) void {
        const self: *Bus = @ptrCast(@alignCast(ctx orelse return));
        self.write8(address, value);
    }

    fn vdpDmaReadWordCallback(userdata: ?*anyopaque, address: u32) u16 {
        const self: *Bus = @ptrCast(@alignCast(userdata orelse return 0));
        return self.read16(address);
    }

    fn ensureZ80HostWindow(self: *Bus) void {
        self.z80_host_bridge.bind(&self.z80, self);
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

    pub fn init(allocator: std.mem.Allocator, rom_path: ?[]const u8) !Bus {
        const cartridge = try Cartridge.init(allocator, rom_path);
        return initWithCartridge(cartridge);
    }

    pub fn initFromRomBytes(allocator: std.mem.Allocator, rom_bytes: []const u8) !Bus {
        const cartridge = try Cartridge.initFromRomBytes(allocator, rom_bytes);
        return initWithCartridge(cartridge);
    }

    pub fn initFromRomBytesWithChecksum(allocator: std.mem.Allocator, rom_bytes: []const u8, checksum: u32) !Bus {
        const cartridge = try Cartridge.initFromRomBytesWithChecksum(allocator, rom_bytes, checksum);
        return initWithCartridge(cartridge);
    }

    pub fn deinit(self: *Bus, allocator: std.mem.Allocator) void {
        self.z80.deinit();
        self.cartridge.deinit(allocator);
    }

    fn cpuMemoryRead8(ctx: ?*anyopaque, address: u32) u8 {
        const self: *Bus = @ptrCast(@alignCast(ctx orelse return 0));
        return self.read8(address);
    }

    fn cpuMemoryRead16(ctx: ?*anyopaque, address: u32) u16 {
        const self: *Bus = @ptrCast(@alignCast(ctx orelse return 0));
        return self.read16(address);
    }

    fn cpuMemoryRead32(ctx: ?*anyopaque, address: u32) u32 {
        const self: *Bus = @ptrCast(@alignCast(ctx orelse return 0));
        return self.read32(address);
    }

    fn cpuMemoryWrite8(ctx: ?*anyopaque, address: u32, value: u8) void {
        const self: *Bus = @ptrCast(@alignCast(ctx orelse return));
        self.write8(address, value);
    }

    fn cpuMemoryWrite16(ctx: ?*anyopaque, address: u32, value: u16) void {
        const self: *Bus = @ptrCast(@alignCast(ctx orelse return));
        self.write16(address, value);
    }

    fn cpuMemoryWrite32(ctx: ?*anyopaque, address: u32, value: u32) void {
        const self: *Bus = @ptrCast(@alignCast(ctx orelse return));
        self.write32(address, value);
    }

    fn cpuMemoryM68kAccessWaitMasterCycles(ctx: ?*anyopaque, address: u32, size_bytes: u8) u32 {
        const self: *Bus = @ptrCast(@alignCast(ctx orelse return 0));
        return self.m68kAccessWaitMasterCycles(address, size_bytes);
    }

    fn cpuMemoryDataPortReadWaitMasterCycles(ctx: ?*anyopaque) u32 {
        const self: *Bus = @ptrCast(@alignCast(ctx orelse return 0));
        return self.vdp.dataPortReadWaitMasterCycles();
    }

    fn cpuMemoryReserveDataPortWriteWaitMasterCycles(ctx: ?*anyopaque) u32 {
        const self: *Bus = @ptrCast(@alignCast(ctx orelse return 0));
        return self.vdp.reserveDataPortWriteWaitMasterCycles();
    }

    fn cpuMemoryControlPortWriteWaitMasterCycles(ctx: ?*anyopaque) u32 {
        const self: *Bus = @ptrCast(@alignCast(ctx orelse return 0));
        return self.vdp.controlPortWriteWaitMasterCycles();
    }

    pub fn cpuMemory(self: *Bus) MemoryInterface {
        return .{
            .ctx = self,
            .read8Fn = cpuMemoryRead8,
            .read16Fn = cpuMemoryRead16,
            .read32Fn = cpuMemoryRead32,
            .write8Fn = cpuMemoryWrite8,
            .write16Fn = cpuMemoryWrite16,
            .write32Fn = cpuMemoryWrite32,
            .m68kAccessWaitMasterCyclesFn = cpuMemoryM68kAccessWaitMasterCycles,
            .dataPortReadWaitMasterCyclesFn = cpuMemoryDataPortReadWaitMasterCycles,
            .reserveDataPortWriteWaitMasterCyclesFn = cpuMemoryReserveDataPortWriteWaitMasterCycles,
            .controlPortWriteWaitMasterCyclesFn = cpuMemoryControlPortWriteWaitMasterCycles,
        };
    }

    pub fn read8(self: *Bus, address: u32) u8 {
        const addr = address & 0xFFFFFF;

        if (self.cartridge.readByte(addr)) |value| {
            return value;
        }

        if (addr == 0xA11100) return @truncate((self.readZ80BusAckRegister() >> 8) & 0xFF);
        if (addr == 0xA11101) return @truncate(self.readZ80BusAckRegister() & 0xFF);
        if (addr == 0xA11200) return @truncate((self.readZ80ResetRegister() >> 8) & 0xFF);
        if (addr == 0xA11201) return @truncate(self.readZ80ResetRegister() & 0xFF);

        if (addr < 0xA00000) {
            return self.cartridge.readRomByte(addr);
        } else if (addr >= 0xE00000 and addr < 0x1000000) {
            return self.ram[addr & 0xFFFF];
        } else if (addr >= 0xA00000 and addr < 0xA10000) {
            if (!self.hasZ80BusFor68k()) return @truncate((self.open_bus >> 8) & 0xFF);
            self.ensureZ80HostWindow();
            self.z80.setAudioMasterOffset(self.audio_timing.pending_master_cycles);
            const zaddr: u16 = @truncate(addr & 0x7FFF);
            return self.z80.readByte(zaddr);
        } else if (addr >= 0xC00000 and addr <= 0xDFFFFF) {
            return vdp_ports.readByte(&self.vdp, &self.open_bus, addr);
        } else if (addr >= 0xA10000 and addr < 0xA10100) {
            return io_window.readRegisterByte(&self.io, self.vdp.pal_mode, addr);
        }

        return 0;
    }

    pub fn read16(self: *Bus, address: u32) u16 {
        const addr = address & 0xFFFFFF;
        if (self.cartridge.readWord(addr)) |value| {
            return self.latchOpenBus(value);
        }
        if (addr == 0xA11100) {
            return self.readZ80BusAckRegister();
        } else if (addr == 0xA11200) {
            return self.readZ80ResetRegister();
        } else if (addr >= 0xA00000 and addr < 0xA10000 and !self.hasZ80BusFor68k()) {
            return self.latchOpenBus(self.open_bus & 0xFF00);
        } else if (addr >= 0xA10000 and addr < 0xA10100) {
            return self.latchOpenBus(io_window.readRegisterByte(&self.io, self.vdp.pal_mode, addr));
        } else if (addr >= 0xC00000 and addr <= 0xDFFFFF) {
            return vdp_ports.readWord(&self.vdp, &self.open_bus, addr);
        }

        const high = self.read8(address);
        const low = self.read8(address + 1);
        return self.latchOpenBus((@as(u16, high) << 8) | low);
    }

    pub fn read32(self: *Bus, address: u32) u32 {
        const high = self.read16(address);
        const low = self.read16(address + 2);
        return (@as(u32, high) << 16) | low;
    }

    pub fn write8(self: *Bus, address: u32, value: u8) void {
        const addr = address & 0xFFFFFF;
        self.open_bus = (@as(u16, value) << 8) | value;

        if (self.cartridge.writeRegisterByte(addr, value)) return;
        if (self.cartridge.writeByte(addr, value)) return;

        if (addr == 0xA11100) {
            self.z80.writeBusReq(@as(u16, value) << 8);
            return;
        } else if (addr == 0xA11101) {
            return;
        } else if (addr == 0xA11200) {
            self.z80.setAudioMasterOffset(self.audio_timing.pending_master_cycles);
            self.z80.writeReset(@as(u16, value) << 8);
            return;
        } else if (addr == 0xA11201) {
            return;
        }

        if (addr < 0xA00000) {
            return;
        } else if (addr >= 0xE00000 and addr < 0x1000000) {
            self.ram[addr & 0xFFFF] = value;
        } else if (addr >= 0xA00000 and addr < 0xA10000) {
            if (!self.hasZ80BusFor68k()) return;
            self.ensureZ80HostWindow();
            self.z80.setAudioMasterOffset(self.audio_timing.pending_master_cycles);
            const zaddr: u16 = @truncate(addr & 0x7FFF);
            self.z80.writeByte(zaddr, value);
            return;
        } else if (addr >= 0xA10000 and addr < 0xA10100) {
            io_window.writeRegisterByte(&self.io, addr, value);
        } else if (addr >= 0xC00000 and addr <= 0xDFFFFF) {
            const port = addr & 0x1F;
            if (port >= 0x11 and port < 0x18 and (port & 1) == 1) {
                self.z80.setAudioMasterOffset(self.audio_timing.pending_master_cycles);
                self.z80.writeByte(0x7F11, value);
            } else {
                vdp_ports.writeByte(&self.vdp, addr, value);
            }
            return;
        }
    }

    pub fn write16(self: *Bus, address: u32, value: u16) void {
        const addr = address & 0xFFFFFF;
        self.open_bus = value;

        if (self.cartridge.writeRegisterWord(addr, value)) return;
        if (self.cartridge.writeWord(addr, value)) return;

        if (addr >= 0xC00000 and addr <= 0xDFFFFF) {
            const port = addr & 0x1F;
            if (port >= 0x10 and port < 0x18 and (port & 1) == 0) {
                self.z80.setAudioMasterOffset(self.audio_timing.pending_master_cycles);
                self.z80.writeByte(0x7F11, @intCast(value & 0xFF));
            } else {
                vdp_ports.writeWord(&self.vdp, addr, value);
            }
            return;
        }

        if (addr == 0xA11100) {
            self.z80.writeBusReq(value);
            return;
        } else if (addr == 0xA11200) {
            self.z80.setAudioMasterOffset(self.audio_timing.pending_master_cycles);
            self.z80.writeReset(value);
            return;
        }

        self.write8(address, @intCast((value >> 8) & 0xFF));
        self.write8(address + 1, @intCast(value & 0xFF));
    }

    pub fn write32(self: *Bus, address: u32, value: u32) void {
        self.write16(address, @intCast((value >> 16) & 0xFFFF));
        self.write16(address + 2, @intCast(value & 0xFFFF));
    }

    fn recordZ80M68kBusAccesses(self: *Bus, access_count: u32) void {
        if (access_count == 0) return;

        var remaining = access_count;
        while (remaining > 0) : (remaining -= 1) {
            const extra: u32 = if (self.z80_odd_access) 1 else 0;
            const z80_wait: u32 = 49 + extra;
            if (!self.vdp.shouldHaltCpu()) {
                self.m68k_wait_master_cycles += clock.m68kCyclesToMaster(11);
            }

            if (remaining > 1) {
                self.advanceNonZ80Master(z80_wait);
            } else {
                self.z80_wait_master_cycles += z80_wait;
            }
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

    pub fn shouldHaltM68k(self: *const Bus) bool {
        return self.vdp.shouldHaltCpu();
    }

    fn schedulerShouldHaltM68k(ctx: ?*anyopaque) bool {
        const self: *Bus = @ptrCast(@alignCast(ctx orelse return false));
        return self.shouldHaltM68k();
    }

    fn schedulerPendingM68kWaitMasterCycles(ctx: ?*anyopaque) u32 {
        const self: *Bus = @ptrCast(@alignCast(ctx orelse return 0));
        return self.pendingM68kWaitMasterCycles();
    }

    fn schedulerConsumeM68kWaitMasterCycles(ctx: ?*anyopaque, max_master_cycles: u32) u32 {
        const self: *Bus = @ptrCast(@alignCast(ctx orelse return 0));
        return self.consumeM68kWaitMasterCycles(max_master_cycles);
    }

    fn schedulerStepMaster(ctx: ?*anyopaque, master_cycles: u32) void {
        const self: *Bus = @ptrCast(@alignCast(ctx orelse return));
        self.stepMaster(master_cycles);
    }

    fn schedulerCpuMemory(ctx: ?*anyopaque) MemoryInterface {
        const self: *Bus = @ptrCast(@alignCast(ctx orelse unreachable));
        return self.cpuMemory();
    }

    fn schedulerDmaHaltQuantum(ctx: ?*anyopaque) u32 {
        const self: *Bus = @ptrCast(@alignCast(ctx orelse return 8));
        return self.vdp.nextTransferStepMasterCycles();
    }

    pub fn schedulerRuntime(self: *Bus) SchedulerBus {
        return .{
            .ctx = self,
            .should_halt_m68k_fn = schedulerShouldHaltM68k,
            .pending_wait_master_cycles_fn = schedulerPendingM68kWaitMasterCycles,
            .consume_wait_master_cycles_fn = schedulerConsumeM68kWaitMasterCycles,
            .step_master_fn = schedulerStepMaster,
            .cpu_memory_fn = schedulerCpuMemory,
            .dma_halt_quantum_fn = schedulerDmaHaltQuantum,
        };
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

            self.z80.setAudioMasterOffset(self.audio_timing.pending_master_cycles);
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

test "z80 bus mapped memory and busreq registers behave as expected" {
    var bus = try Bus.init(testing.allocator, null);
    defer bus.deinit(testing.allocator);

    bus.write8(0x00A0_0010, 0x5A);
    try testing.expectEqual(@as(u8, 0x5A), bus.read8(0x00A0_0010));
    try testing.expectEqual(@as(u16, 0x5A00), bus.read16(0x00A0_0010));

    bus.write16(0x00A1_1100, 0x0100);
    try testing.expectEqual(@as(u16, 0x0000), bus.read16(0x00A1_1100));

    bus.write8(0x00A0_0010, 0x5A);
    try testing.expectEqual(@as(u8, 0x5A), bus.read8(0x00A0_0010));

    bus.write16(0x00A1_1100, 0x0000);
    try testing.expectEqual(@as(u16, 0x0100), bus.read16(0x00A1_1100));

    bus.write8(0x00A0_0010, 0xA5);
    try testing.expectEqual(@as(u8, 0xA5), bus.read8(0x00A0_0010));
    try testing.expectEqual(@as(u16, 0xA500), bus.read16(0x00A0_0010));
}

test "z80 bus request does not grant bus while reset is held" {
    var bus = try Bus.init(testing.allocator, null);
    defer bus.deinit(testing.allocator);

    bus.write16(0x00A1_1200, 0x0000);
    bus.write16(0x00A1_1100, 0x0100);

    try testing.expectEqual(@as(u16, 0x0100), bus.read16(0x00A1_1100));
    bus.write8(0x00A0_0010, 0x5A);
    try testing.expectEqual(@as(u8, 0x5A), bus.read8(0x00A0_0010));
    try testing.expectEqual(@as(u16, 0x5A00), bus.read16(0x00A0_0010));

    bus.write16(0x00A1_1200, 0x0100);

    try testing.expectEqual(@as(u16, 0x0000), bus.read16(0x00A1_1100));
    bus.write8(0x00A0_0010, 0x5A);
    try testing.expectEqual(@as(u8, 0x5A), bus.read8(0x00A0_0010));
}

test "z80 busack and reset reads preserve open-bus bits" {
    var bus = try Bus.init(testing.allocator, null);
    defer bus.deinit(testing.allocator);

    bus.open_bus = 0xA400;
    try testing.expectEqual(@as(u16, 0xA500), bus.read16(0x00A1_1100));

    bus.write16(0x00A1_1100, 0x0100);
    bus.open_bus = 0xA400;
    try testing.expectEqual(@as(u16, 0xA400), bus.read16(0x00A1_1100));

    bus.write16(0x00A1_1200, 0x0000);
    bus.open_bus = 0xB600;
    try testing.expectEqual(@as(u16, 0xB600), bus.read16(0x00A1_1200));

    bus.write16(0x00A1_1200, 0x0100);
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

    bus.write8(0x00A1_1100, 0x01);
    try testing.expectEqual(@as(u16, 0x0001), bus.read16(0x00A1_1100));
    try testing.expectEqual(@as(u8, 0x00), bus.read8(0x00A1_1100));

    bus.write8(0x00A1_1101, 0x01);
    try testing.expectEqual(@as(u16, 0x0001), bus.read16(0x00A1_1100));

    bus.write8(0x00A1_1200, 0x00);
    try testing.expectEqual(@as(u16, 0x0000), bus.read16(0x00A1_1200));
    try testing.expectEqual(@as(u8, 0x00), bus.read8(0x00A1_1200));

    bus.write8(0x00A1_1201, 0x01);
    try testing.expectEqual(@as(u16, 0x0001), bus.read16(0x00A1_1200));

    bus.write8(0x00A1_1200, 0x01);
    bus.write8(0x00A1_1100, 0x00);
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

test "m68k z80 window writes use current audio master offset" {
    var bus = try Bus.init(testing.allocator, null);
    defer bus.deinit(testing.allocator);

    bus.write16(0x00A1_1100, 0x0100);

    bus.audio_timing.consumeMaster(5000);

    bus.write8(0x00A0_4000, 0x22);
    bus.write8(0x00A0_4001, 0x0F);

    var writes: [4]Z80.YmWriteEvent = undefined;
    const count = bus.z80.takeYmWrites(writes[0..]);
    try testing.expectEqual(@as(usize, 1), count);
    try testing.expectEqual(@as(u32, 5000), writes[0].master_offset);
}

test "z80 audio window latches YM2612 and PSG writes" {
    var bus = try Bus.init(testing.allocator, null);
    defer bus.deinit(testing.allocator);

    bus.write16(0x00A1_1100, 0x0100);

    bus.write8(0x00A0_4000, 0x22);
    bus.write8(0x00A0_4001, 0x0F);
    try testing.expectEqual(@as(u8, 0x0F), bus.z80.getYmRegister(0, 0x22));

    bus.write8(0x00A0_4002, 0x2B);
    bus.write8(0x00A0_4003, 0x80);
    try testing.expectEqual(@as(u8, 0x80), bus.z80.getYmRegister(1, 0x2B));

    bus.write8(0x00A0_7F11, 0x90);
    try testing.expectEqual(@as(u8, 0x90), bus.z80.getPsgLast());
}

test "m68k ym status reads advance busy timing through the z80 window" {
    var bus = try Bus.init(testing.allocator, null);
    defer bus.deinit(testing.allocator);

    const ym_internal_master_cycles: u32 = @as(u32, clock.m68k_divider) * 6;

    bus.write16(0x00A1_1100, 0x0100);

    bus.write8(0x00A0_4000, 0x22);
    bus.write8(0x00A0_4001, 0x0F);
    try testing.expectEqual(@as(u8, 0x00), bus.read8(0x00A0_4000) & 0x80);

    bus.audio_timing.consumeMaster(ym_internal_master_cycles);
    try testing.expectEqual(@as(u8, 0x80), bus.read8(0x00A0_4000) & 0x80);

    bus.audio_timing.consumeMaster(64 * ym_internal_master_cycles);
    try testing.expectEqual(@as(u8, 0x00), bus.read8(0x00A0_4000) & 0x80);
}

test "psg latch/data writes decode tone and volume registers" {
    var bus = try Bus.init(testing.allocator, null);
    defer bus.deinit(testing.allocator);

    bus.write16(0x00A1_1100, 0x0100);

    bus.write8(0x00A0_7F11, 0x80 | 0x0A);
    bus.write8(0x00A0_7F11, 0x15);
    try testing.expectEqual(@as(u16, 0x15A), bus.z80.getPsgTone(0));

    bus.write8(0x00A0_7F11, 0xC0 | 0x10 | 0x07);
    try testing.expectEqual(@as(u8, 0x07), bus.z80.getPsgVolume(2));

    bus.write8(0x00A0_7F11, 0xE0 | 0x03);
    try testing.expectEqual(@as(u8, 0x03), bus.z80.getPsgNoise());
}

test "m68k psg writes through vdp port reach the psg shadow registers" {
    var bus = try Bus.init(testing.allocator, null);
    defer bus.deinit(testing.allocator);

    bus.write8(0x00C0_0011, 0x80 | 0x05);
    bus.write8(0x00C0_0011, 0x12);
    try testing.expectEqual(@as(u16, 0x125), bus.z80.getPsgTone(0));

    bus.write16(0x00C0_0010, 0x00D0 | 0x07);
    try testing.expectEqual(@as(u8, 0x07), bus.z80.getPsgVolume(2));

    var cmds: [4]Z80.PsgCommandEvent = undefined;
    const count = bus.z80.takePsgCommands(cmds[0..]);
    try testing.expectEqual(@as(usize, 3), count);
}

test "ym key-on register updates channel key mask" {
    var bus = try Bus.init(testing.allocator, null);
    defer bus.deinit(testing.allocator);

    bus.write16(0x00A1_1100, 0x0100);

    bus.write8(0x00A0_4000, 0x28);
    bus.write8(0x00A0_4001, 0xF0);
    try testing.expectEqual(@as(u8, 0x01), bus.z80.getYmKeyMask());

    bus.write8(0x00A0_4000, 0x28);
    bus.write8(0x00A0_4001, 0xF5);
    try testing.expectEqual(@as(u8, 0x11), bus.z80.getYmKeyMask());

    bus.write8(0x00A0_4000, 0x28);
    bus.write8(0x00A0_4001, 0x00);
    try testing.expectEqual(@as(u8, 0x10), bus.z80.getYmKeyMask());
}

test "ym dac writes stay in the dedicated DAC queue for audio output" {
    var bus = try Bus.init(testing.allocator, null);
    defer bus.deinit(testing.allocator);

    bus.write16(0x00A1_1100, 0x0100);

    bus.write8(0x00A0_4000, 0x2A);
    bus.write8(0x00A0_4001, 0x12);
    bus.write8(0x00A0_4001, 0x34);

    var writes: [4]Z80.YmWriteEvent = undefined;
    try testing.expectEqual(@as(usize, 0), bus.z80.takeYmWrites(writes[0..]));

    var dac_samples: [4]Z80.YmDacSampleEvent = undefined;
    const count = bus.z80.takeYmDacSamples(dac_samples[0..]);
    try testing.expectEqual(@as(usize, 2), count);
    try testing.expectEqual(@as(u8, 0x12), dac_samples[0].value);
    try testing.expectEqual(@as(u8, 0x34), dac_samples[1].value);
}

test "z80 reset clears ym2612 register shadow state" {
    var bus = try Bus.init(testing.allocator, null);
    defer bus.deinit(testing.allocator);

    bus.write16(0x00A1_1100, 0x0100);

    bus.write8(0x00A0_4000, 0x22);
    bus.write8(0x00A0_4001, 0x0F);
    bus.write8(0x00A0_4000, 0x28);
    bus.write8(0x00A0_4001, 0xF0);

    try testing.expectEqual(@as(u8, 0x0F), bus.z80.getYmRegister(0, 0x22));
    try testing.expectEqual(@as(u8, 0x01), bus.z80.getYmKeyMask());

    bus.write16(0x00A1_1200, 0x0000);

    try testing.expectEqual(@as(u8, 0x00), bus.z80.getYmRegister(0, 0x22));
    try testing.expectEqual(@as(u8, 0x00), bus.z80.getYmRegister(0, 0x28));
    try testing.expectEqual(@as(u8, 0x00), bus.z80.getYmKeyMask());
}

test "z80 reset writes carry the current audio master offset into ym reset events" {
    var bus = try Bus.init(testing.allocator, null);
    defer bus.deinit(testing.allocator);

    bus.audio_timing.consumeMaster(4321);
    bus.write16(0x00A1_1200, 0x0000);

    var ym_reset_events: [1]Z80.YmResetEvent = undefined;
    try testing.expectEqual(@as(usize, 1), bus.z80.takeYmResets(ym_reset_events[0..]));
    try testing.expectEqual(@as(u32, 4321), ym_reset_events[0].master_offset);
}

test "z80 reset preserves uploaded z80 ram" {
    var bus = try Bus.init(testing.allocator, null);
    defer bus.deinit(testing.allocator);

    bus.write16(0x00A1_1100, 0x0100);
    bus.write16(0x00A1_1200, 0x0100);

    bus.write8(0x00A0_0000, 0xAF);
    bus.write8(0x00A0_0001, 0x01);
    bus.write8(0x00A0_0002, 0xD9);

    bus.write16(0x00A1_1200, 0x0000);

    try testing.expectEqual(@as(u8, 0xAF), bus.z80.readByte(0x0000));
    try testing.expectEqual(@as(u8, 0x01), bus.z80.readByte(0x0001));
    try testing.expectEqual(@as(u8, 0xD9), bus.z80.readByte(0x0002));
}

test "z80 bank register selects 68k ROM window" {
    var bus = try Bus.init(testing.allocator, null);
    defer bus.deinit(testing.allocator);

    bus.rom[0x0000] = 0x12;
    bus.rom[0x8000] = 0x34;

    bus.write16(0x00A1_1100, 0x0100);
    bus.stepMaster(0);

    try testing.expectEqual(@as(u8, 0x12), bus.z80.readByte(0x8000));

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

    bus.z80.reset();
    bus.z80.writeByte(0x0000, 0x3A);
    bus.z80.writeByte(0x0001, 0x00);
    bus.z80.writeByte(0x0002, 0x80);
    bus.z80.writeByte(0x0003, 0x18);
    bus.z80.writeByte(0x0004, 0xFB);

    bus.rom[0x0000] = 0x12;

    bus.stepMaster(258);
    try testing.expectEqual(@as(u16, 0x0003), bus.z80.getPc());
    try testing.expectEqual(@as(u32, 0), bus.z80_wait_master_cycles);
    try testing.expectEqual(clock.m68kCyclesToMaster(11), bus.pendingM68kWaitMasterCycles());

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

test "z80 contention reevaluates vdp dma halt state between accesses" {
    var bus = try Bus.init(testing.allocator, null);
    defer bus.deinit(testing.allocator);

    bus.write16(0x00E0_0000, 0xABCD);
    bus.vdp.regs[12] = 0x81;
    bus.vdp.regs[15] = 2;
    bus.vdp.code = 0x1;
    bus.vdp.addr = 0x0000;
    bus.vdp.dma_active = true;
    bus.vdp.dma_fill = false;
    bus.vdp.dma_copy = false;
    bus.vdp.dma_source_addr = 0x00E0_0000;
    bus.vdp.dma_length = 1;
    bus.vdp.dma_remaining = 1;
    bus.vdp.dma_start_delay_slots = 0;
    bus.vdp.transfer_line_master_cycle = @intCast(bus.vdp.accessSlotCycles() - 1);

    bus.recordZ80M68kBusAccesses(2);

    const expected_wait = if (bus.vdp.shouldHaltCpu()) @as(u32, 0) else clock.m68kCyclesToMaster(11);
    try testing.expectEqual(expected_wait, bus.pendingM68kWaitMasterCycles());
    try testing.expectEqual(@as(u32, 50), bus.z80_wait_master_cycles);
    try testing.expectEqual(@as(u32, 49), bus.audio_timing.pending_master_cycles);
}

test "multiple z80 68k-bus accesses only leave the final stall pending" {
    var bus = try Bus.init(testing.allocator, null);
    defer bus.deinit(testing.allocator);

    bus.recordZ80M68kBusAccesses(2);

    try testing.expectEqual(@as(u32, 50), bus.z80_wait_master_cycles);
    try testing.expectEqual(@as(u32, 49), bus.audio_timing.pending_master_cycles);
    try testing.expectEqual(clock.m68kCyclesToMaster(22), bus.pendingM68kWaitMasterCycles());
}

test "z80 instruction overshoot carries between bus slices" {
    var bus = try Bus.init(testing.allocator, null);
    defer bus.deinit(testing.allocator);

    bus.z80.reset();
    bus.z80.writeByte(0x0000, 0x00);
    bus.z80.writeByte(0x0001, 0x00);

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

    var saw_inflight_step = false;
    var iterations: usize = 0;
    while (bus.vdp.dma_active and iterations < 32) : (iterations += 1) {
        const step = bus.vdp.nextTransferStepMasterCycles();
        try testing.expect(step > 0);
        bus.stepMaster(step);
        if (bus.vdp.vram[0] == 0 and bus.vdp.vram[1] == 0) {
            saw_inflight_step = true;
        }
    }

    try testing.expect(saw_inflight_step);
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
