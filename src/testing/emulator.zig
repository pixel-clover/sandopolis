const std = @import("std");
const internal_machine = @import("../machine.zig");
const internal_timing = @import("../audio/timing.zig");

const empty_rom = [_]u8{};

const State = struct {
    machine: internal_machine.Machine,
};

pub const CpuState = struct {
    program_counter: u32,
    stack_pointer: u32,
};

pub const WaitAccounting = struct {
    m68k_cycles: u32,
    master_cycles: u32,
};

pub const PendingAudioFrames = internal_timing.PendingAudioFrames;

pub const Emulator = struct {
    handle: *State,

    pub fn init(allocator: std.mem.Allocator, rom_path: ?[]const u8) !Emulator {
        const state = try allocator.create(State);
        errdefer allocator.destroy(state);

        state.* = .{
            .machine = try internal_machine.Machine.init(allocator, rom_path),
        };
        return .{ .handle = state };
    }

    pub fn initFromRomBytes(allocator: std.mem.Allocator, rom_bytes: []const u8) !Emulator {
        const state = try allocator.create(State);
        errdefer allocator.destroy(state);

        state.* = .{
            .machine = try internal_machine.Machine.initFromRomBytes(allocator, rom_bytes),
        };
        return .{ .handle = state };
    }

    pub fn initEmpty(allocator: std.mem.Allocator) !Emulator {
        return initFromRomBytes(allocator, &empty_rom);
    }

    pub fn deinit(self: *Emulator, allocator: std.mem.Allocator) void {
        self.handle.machine.deinit(allocator);
        allocator.destroy(self.handle);
    }

    pub fn reset(self: *Emulator) void {
        self.handle.machine.reset();
    }

    pub fn flushPersistentStorage(self: *Emulator) !void {
        try self.handle.machine.flushPersistentStorage();
    }

    pub fn runMasterSlice(self: *Emulator, total_master_cycles: u32) void {
        self.handle.machine.runMasterSlice(total_master_cycles);
    }

    pub fn runFrame(self: *Emulator) void {
        self.handle.machine.runFrame();
    }

    pub fn runFrames(self: *Emulator, frames: usize) void {
        for (0..frames) |_| {
            self.handle.machine.runFrame();
        }
    }

    pub fn cpuState(self: *const Emulator) CpuState {
        return .{
            .program_counter = self.handle.machine.programCounter(),
            .stack_pointer = self.handle.machine.stackPointer(),
        };
    }

    pub fn runCpuCycles(self: *Emulator, budget: u32) u32 {
        var memory = self.handle.machine.bus.cpuMemory();
        return self.handle.machine.cpu.runCycles(&memory, budget);
    }

    pub fn noteCpuBusAccessWait(self: *Emulator, address: u32, size_bytes: u8, is_write: bool) void {
        var memory = self.handle.machine.bus.cpuMemory();
        self.handle.machine.cpu.noteBusAccessWait(&memory, address, size_bytes, is_write);
    }

    pub fn takeCpuWaitAccounting(self: *Emulator) WaitAccounting {
        const wait = self.handle.machine.cpu.takeWaitAccounting();
        return .{
            .m68k_cycles = wait.m68k_cycles,
            .master_cycles = wait.master_cycles,
        };
    }

    pub fn formatCurrentInstruction(self: *Emulator, buffer: []u8) []const u8 {
        var memory = self.handle.machine.bus.cpuMemory();
        return self.handle.machine.cpu.formatCurrentInstruction(&memory, buffer);
    }

    pub fn read8(self: *Emulator, address: u32) u8 {
        return self.handle.machine.bus.read8(address);
    }

    pub fn read16(self: *Emulator, address: u32) u16 {
        return self.handle.machine.bus.read16(address);
    }

    pub fn read32(self: *Emulator, address: u32) u32 {
        return self.handle.machine.bus.read32(address);
    }

    pub fn write8(self: *Emulator, address: u32, value: u8) void {
        self.handle.machine.bus.write8(address, value);
    }

    pub fn write16(self: *Emulator, address: u32, value: u16) void {
        self.handle.machine.bus.write16(address, value);
    }

    pub fn write32(self: *Emulator, address: u32, value: u32) void {
        self.handle.machine.bus.write32(address, value);
    }

    pub fn writeRomByte(self: *Emulator, offset: usize, value: u8) void {
        std.debug.assert(offset < self.handle.machine.bus.rom.len);
        self.handle.machine.bus.rom[offset] = value;
    }

    pub fn hasCartridgeRam(self: *const Emulator) bool {
        return self.handle.machine.bus.hasCartridgeRam();
    }

    pub fn isCartridgeRamMapped(self: *const Emulator) bool {
        return self.handle.machine.bus.isCartridgeRamMapped();
    }

    pub fn persistentSavePath(self: *const Emulator) ?[]const u8 {
        return self.handle.machine.bus.persistentSavePath();
    }

    pub fn configureVdpDataPort(self: *Emulator, code: u8, addr: u16, auto_increment: u8) void {
        self.handle.machine.bus.vdp.regs[15] = auto_increment;
        self.handle.machine.bus.vdp.code = code;
        self.handle.machine.bus.vdp.addr = addr;
    }

    pub fn setVdpRegister(self: *Emulator, index: usize, value: u8) void {
        std.debug.assert(index < self.handle.machine.bus.vdp.regs.len);
        self.handle.machine.bus.vdp.regs[index] = value;
    }

    pub fn vdpRegister(self: *const Emulator, index: usize) u8 {
        std.debug.assert(index < self.handle.machine.bus.vdp.regs.len);
        return self.handle.machine.bus.vdp.regs[index];
    }

    pub fn setVdpCode(self: *Emulator, code: u8) void {
        self.handle.machine.bus.vdp.code = code;
    }

    pub fn setVdpAddr(self: *Emulator, addr: u16) void {
        self.handle.machine.bus.vdp.addr = addr;
    }

    pub fn vdpAddr(self: *const Emulator) u16 {
        return self.handle.machine.bus.vdp.addr;
    }

    pub fn writeVdpData(self: *Emulator, value: u16) void {
        self.handle.machine.bus.vdp.writeData(value);
    }

    pub fn vdpDataPortWriteWaitMasterCycles(self: *const Emulator) u32 {
        return self.handle.machine.bus.vdp.dataPortWriteWaitMasterCycles();
    }

    pub fn vdpDataPortReadWaitMasterCycles(self: *const Emulator) u32 {
        return self.handle.machine.bus.vdp.dataPortReadWaitMasterCycles();
    }

    pub fn vdpShouldHaltCpu(self: *const Emulator) bool {
        return self.handle.machine.bus.vdp.shouldHaltCpu();
    }

    pub fn forceMemoryToVramDma(self: *Emulator, source_addr: u32, length: u16) void {
        self.handle.machine.bus.vdp.dma_active = true;
        self.handle.machine.bus.vdp.dma_fill = false;
        self.handle.machine.bus.vdp.dma_copy = false;
        self.handle.machine.bus.vdp.dma_source_addr = source_addr;
        self.handle.machine.bus.vdp.dma_length = length;
        self.handle.machine.bus.vdp.dma_remaining = length;
        self.handle.machine.bus.vdp.dma_start_delay_slots = 0;
    }

    pub fn vdpIsDmaActive(self: *const Emulator) bool {
        return self.handle.machine.bus.vdp.dma_active;
    }

    pub fn framebuffer(self: *const Emulator) []const u32 {
        return self.handle.machine.framebuffer()[0..];
    }

    pub fn takePendingAudio(self: *Emulator) PendingAudioFrames {
        return self.handle.machine.takePendingAudio();
    }

    pub fn ymKeyMask(self: *const Emulator) u8 {
        return self.handle.machine.bus.z80.getYmKeyMask();
    }

    pub fn ymRegister(self: *const Emulator, port: u1, reg: u8) u8 {
        return self.handle.machine.bus.z80.getYmRegister(port, reg);
    }

    pub fn z80Reset(self: *Emulator) void {
        self.handle.machine.bus.z80.reset();
    }

    pub fn z80WriteByte(self: *Emulator, addr: u16, value: u8) void {
        self.handle.machine.bus.z80.writeByte(addr, value);
    }

    pub fn z80ProgramCounter(self: *const Emulator) u16 {
        return self.handle.machine.bus.z80.getPc();
    }

    pub fn setZ80BusRequest(self: *Emulator, value: u16) void {
        self.handle.machine.bus.write16(0x00A1_1100, value);
    }

    pub fn setZ80ResetControl(self: *Emulator, value: u16) void {
        self.handle.machine.bus.write16(0x00A1_1200, value);
    }

    pub fn pendingM68kWaitMasterCycles(self: *const Emulator) u32 {
        return self.handle.machine.bus.pendingM68kWaitMasterCycles();
    }

    pub fn setPendingM68kWaitMasterCycles(self: *Emulator, master_cycles: u32) void {
        self.handle.machine.bus.m68k_wait_master_cycles = master_cycles;
    }

    pub fn cpuDebtMasterCycles(self: *const Emulator) u32 {
        return self.handle.machine.m68k_sync.debt_master_cycles;
    }
};
