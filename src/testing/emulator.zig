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
        var machine = self.handle.machine.testing();
        return machine.runCpuCycles(budget);
    }

    pub fn noteCpuBusAccessWait(self: *Emulator, address: u32, size_bytes: u8, is_write: bool) void {
        var machine = self.handle.machine.testing();
        machine.noteCpuBusAccessWait(address, size_bytes, is_write);
    }

    pub fn takeCpuWaitAccounting(self: *Emulator) WaitAccounting {
        var machine = self.handle.machine.testing();
        const wait = machine.takeCpuWaitAccounting();
        return .{
            .m68k_cycles = wait.m68k_cycles,
            .master_cycles = wait.master_cycles,
        };
    }

    pub fn formatCurrentInstruction(self: *Emulator, buffer: []u8) []const u8 {
        var machine = self.handle.machine.testing();
        return machine.formatCurrentInstruction(buffer);
    }

    pub fn read8(self: *Emulator, address: u32) u8 {
        var machine = self.handle.machine.testing();
        return machine.read8(address);
    }

    pub fn read16(self: *Emulator, address: u32) u16 {
        var machine = self.handle.machine.testing();
        return machine.read16(address);
    }

    pub fn read32(self: *Emulator, address: u32) u32 {
        var machine = self.handle.machine.testing();
        return machine.read32(address);
    }

    pub fn write8(self: *Emulator, address: u32, value: u8) void {
        var machine = self.handle.machine.testing();
        machine.write8(address, value);
    }

    pub fn write16(self: *Emulator, address: u32, value: u16) void {
        var machine = self.handle.machine.testing();
        machine.write16(address, value);
    }

    pub fn write32(self: *Emulator, address: u32, value: u32) void {
        var machine = self.handle.machine.testing();
        machine.write32(address, value);
    }

    pub fn writeRomByte(self: *Emulator, offset: usize, value: u8) void {
        var machine = self.handle.machine.testing();
        machine.writeRomByte(offset, value);
    }

    pub fn hasCartridgeRam(self: *const Emulator) bool {
        const machine = self.handle.machine.testingConst();
        return machine.hasCartridgeRam();
    }

    pub fn isCartridgeRamMapped(self: *const Emulator) bool {
        const machine = self.handle.machine.testingConst();
        return machine.isCartridgeRamMapped();
    }

    pub fn persistentSavePath(self: *const Emulator) ?[]const u8 {
        const machine = self.handle.machine.testingConst();
        return machine.persistentSavePath();
    }

    pub fn configureVdpDataPort(self: *Emulator, code: u8, addr: u16, auto_increment: u8) void {
        var machine = self.handle.machine.testing();
        machine.configureVdpDataPort(code, addr, auto_increment);
    }

    pub fn setVdpRegister(self: *Emulator, index: usize, value: u8) void {
        var machine = self.handle.machine.testing();
        machine.setVdpRegister(index, value);
    }

    pub fn setPalMode(self: *Emulator, pal_mode: bool) void {
        var machine = self.handle.machine.testing();
        machine.setPalMode(pal_mode);
    }

    pub fn vdpRegister(self: *const Emulator, index: usize) u8 {
        const machine = self.handle.machine.testingConst();
        return machine.vdpRegister(index);
    }

    pub fn setVdpCode(self: *Emulator, code: u8) void {
        var machine = self.handle.machine.testing();
        machine.setVdpCode(code);
    }

    pub fn setVdpAddr(self: *Emulator, addr: u16) void {
        var machine = self.handle.machine.testing();
        machine.setVdpAddr(addr);
    }

    pub fn vdpAddr(self: *const Emulator) u16 {
        const machine = self.handle.machine.testingConst();
        return machine.vdpAddr();
    }

    pub fn vdpScanline(self: *const Emulator) u16 {
        const machine = self.handle.machine.testingConst();
        return machine.vdpScanline();
    }

    pub fn writeVdpData(self: *Emulator, value: u16) void {
        var machine = self.handle.machine.testing();
        machine.writeVdpData(value);
    }

    pub fn vdpDataPortWriteWaitMasterCycles(self: *const Emulator) u32 {
        const machine = self.handle.machine.testingConst();
        return machine.vdpDataPortWriteWaitMasterCycles();
    }

    pub fn vdpDataPortReadWaitMasterCycles(self: *const Emulator) u32 {
        const machine = self.handle.machine.testingConst();
        return machine.vdpDataPortReadWaitMasterCycles();
    }

    pub fn vdpShouldHaltCpu(self: *const Emulator) bool {
        const machine = self.handle.machine.testingConst();
        return machine.vdpShouldHaltCpu();
    }

    pub fn forceMemoryToVramDma(self: *Emulator, source_addr: u32, length: u16) void {
        var machine = self.handle.machine.testing();
        machine.forceMemoryToVramDma(source_addr, length);
    }

    pub fn vdpIsDmaActive(self: *const Emulator) bool {
        const machine = self.handle.machine.testingConst();
        return machine.vdpIsDmaActive();
    }

    pub fn framebuffer(self: *const Emulator) []const u32 {
        return self.handle.machine.framebuffer();
    }

    pub fn takePendingAudio(self: *Emulator) PendingAudioFrames {
        return self.handle.machine.takePendingAudio();
    }

    pub fn ymKeyMask(self: *const Emulator) u8 {
        const machine = self.handle.machine.testingConst();
        return machine.ymKeyMask();
    }

    pub fn ymRegister(self: *const Emulator, port: u1, reg: u8) u8 {
        const machine = self.handle.machine.testingConst();
        return machine.ymRegister(port, reg);
    }

    pub fn z80Reset(self: *Emulator) void {
        var machine = self.handle.machine.testing();
        machine.z80Reset();
    }

    pub fn z80WriteByte(self: *Emulator, addr: u16, value: u8) void {
        var machine = self.handle.machine.testing();
        machine.z80WriteByte(addr, value);
    }

    pub fn z80ProgramCounter(self: *const Emulator) u16 {
        const machine = self.handle.machine.testingConst();
        return machine.z80ProgramCounter();
    }

    pub fn setZ80BusRequest(self: *Emulator, value: u16) void {
        var machine = self.handle.machine.testing();
        machine.setZ80BusRequest(value);
    }

    pub fn setZ80ResetControl(self: *Emulator, value: u16) void {
        var machine = self.handle.machine.testing();
        machine.setZ80ResetControl(value);
    }

    pub fn pendingM68kWaitMasterCycles(self: *const Emulator) u32 {
        const machine = self.handle.machine.testingConst();
        return machine.pendingM68kWaitMasterCycles();
    }

    pub fn setPendingM68kWaitMasterCycles(self: *Emulator, master_cycles: u32) void {
        var machine = self.handle.machine.testing();
        machine.setPendingM68kWaitMasterCycles(master_cycles);
    }

    pub fn cpuDebtMasterCycles(self: *const Emulator) u32 {
        const machine = self.handle.machine.testingConst();
        return machine.cpuDebtMasterCycles();
    }
};
