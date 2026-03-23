const std = @import("std");
const internal_machine = @import("../machine.zig");
const internal_timing = @import("../audio/timing.zig");
const state_file = @import("../state_file.zig");
const AudioOutput = @import("../audio/output.zig").AudioOutput;
const M68kInstructionTraceEntry = @import("../cpu/rocket68_cpu.zig").Cpu.M68kInstructionTraceEntry;
const Bus = @import("../bus/bus.zig").Bus;
const M68kSoundWriteTraceEntry = Bus.M68kSoundWriteTraceEntry;
const Z80AudioOpTraceEntry = @import("../cpu/z80.zig").Z80.AudioOpTraceEntry;
const YmWriteEvent = @import("../audio/ym2612.zig").YmWriteEvent;
const YmDacSampleEvent = @import("../cpu/z80.zig").Z80.YmDacSampleEvent;

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
        state.machine.reset();
        return .{ .handle = state };
    }

    pub fn initFromRomBytes(allocator: std.mem.Allocator, rom_bytes: []const u8) !Emulator {
        const state = try allocator.create(State);
        errdefer allocator.destroy(state);

        state.* = .{
            .machine = try internal_machine.Machine.initFromRomBytes(allocator, rom_bytes),
        };
        state.machine.reset();
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

    pub fn softReset(self: *Emulator) void {
        self.handle.machine.softReset();
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

    pub const CoreFrameCounters = @import("../performance_profile.zig").CoreFrameCounters;

    pub fn runFrameProfiled(self: *Emulator) CoreFrameCounters {
        var counters = CoreFrameCounters{};
        self.handle.machine.runFrameProfiled(&counters);
        return counters;
    }

    pub fn runFrames(self: *Emulator, frames: usize) void {
        for (0..frames) |_| {
            self.handle.machine.runFrame();
        }
    }

    pub fn discardPendingAudio(self: *Emulator) void {
        self.handle.machine.discardPendingAudio();
    }

    pub fn runFramesDiscardingAudio(self: *Emulator, frames: usize) void {
        for (0..frames) |_| {
            self.handle.machine.runFrame();
            self.handle.machine.discardPendingAudio();
        }
    }

    pub fn runFramesProcessingAudio(self: *Emulator, frames: usize) !void {
        var output = AudioOutput.init();
        for (0..frames) |_| {
            self.handle.machine.runFrame();
            const pending = self.handle.machine.takePendingAudio();
            try output.discardPending(pending, &self.handle.machine.bus.z80, self.handle.machine.palMode());
        }
    }

    pub fn renderPendingAudio(self: *Emulator, output: *AudioOutput, sink: anytype) !void {
        const pending = self.handle.machine.takePendingAudio();
        try output.renderPending(pending, &self.handle.machine.bus.z80, self.handle.machine.palMode(), sink);
    }

    pub fn discardPendingAudioWithOutput(self: *Emulator, output: *AudioOutput) !void {
        const pending = self.handle.machine.takePendingAudio();
        try output.discardPending(pending, &self.handle.machine.bus.z80, self.handle.machine.palMode());
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

    pub const TestPrefetchCtx = Bus.TestPrefetchCtx;

    pub fn setTestPrefetch(self: *Emulator, ctx: *TestPrefetchCtx) void {
        var machine = self.handle.machine.testing();
        machine.setTestPrefetch(ctx);
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

    pub fn pendingYmWriteCount(self: *const Emulator) u16 {
        return self.handle.machine.bus.z80.pendingYmWriteCount();
    }

    pub fn takeYmWrites(self: *Emulator, dest: []YmWriteEvent) usize {
        return self.handle.machine.bus.z80.takeYmWrites(dest);
    }

    pub fn pendingYmDacCount(self: *const Emulator) u16 {
        return self.handle.machine.bus.z80.pendingYmDacCount();
    }

    pub fn takeYmDacSamples(self: *Emulator, dest: []YmDacSampleEvent) usize {
        return self.handle.machine.bus.z80.takeYmDacSamples(dest);
    }

    pub fn pendingPsgCommandCount(self: *const Emulator) u16 {
        return self.handle.machine.bus.z80.pendingPsgCommandCount();
    }

    pub fn takeAudioOverflowCounts(self: *Emulator) u32 {
        return self.handle.machine.bus.z80.takeOverflowCounts();
    }

    pub fn setZ80AudioOpTraceEnabled(self: *Emulator, enabled: bool) void {
        self.handle.machine.bus.z80.setAudioOpTraceEnabled(enabled);
    }

    pub fn clearZ80AudioOpTrace(self: *Emulator) void {
        self.handle.machine.bus.z80.clearAudioOpTrace();
    }

    pub fn pendingZ80AudioOpTraceCount(self: *const Emulator) u16 {
        return self.handle.machine.bus.z80.pendingAudioOpTraceCount();
    }

    pub fn takeZ80AudioOpTrace(self: *Emulator, dest: []Z80AudioOpTraceEntry) usize {
        return self.handle.machine.bus.z80.takeAudioOpTrace(dest);
    }

    pub fn takeZ80AudioOpTraceDroppedCount(self: *Emulator) u32 {
        return self.handle.machine.bus.z80.takeAudioOpTraceDroppedCount();
    }

    pub fn setM68kInstructionTraceEnabled(self: *Emulator, enabled: bool) void {
        var machine = self.handle.machine.testing();
        machine.setM68kInstructionTraceEnabled(enabled);
    }

    pub fn setM68kInstructionTraceStopOnFault(self: *Emulator, stop_on_fault: bool) void {
        var machine = self.handle.machine.testing();
        machine.setM68kInstructionTraceStopOnFault(stop_on_fault);
    }

    pub fn clearM68kInstructionTrace(self: *Emulator) void {
        var machine = self.handle.machine.testing();
        machine.clearM68kInstructionTrace();
    }

    pub fn m68kInstructionTraceEntries(self: *const Emulator) []const M68kInstructionTraceEntry {
        const machine = self.handle.machine.testingConst();
        return machine.m68kInstructionTraceEntries();
    }

    pub fn m68kInstructionTraceDroppedCount(self: *const Emulator) u32 {
        const machine = self.handle.machine.testingConst();
        return machine.m68kInstructionTraceDroppedCount();
    }

    pub fn setM68kSoundWriteTraceEnabled(self: *Emulator, enabled: bool) void {
        var machine = self.handle.machine.testing();
        machine.setM68kSoundWriteTraceEnabled(enabled);
    }

    pub fn clearM68kSoundWriteTrace(self: *Emulator) void {
        var machine = self.handle.machine.testing();
        machine.clearM68kSoundWriteTrace();
    }

    pub fn m68kSoundWriteTraceEntries(self: *const Emulator) []const M68kSoundWriteTraceEntry {
        const machine = self.handle.machine.testingConst();
        return machine.m68kSoundWriteTraceEntries();
    }

    pub fn m68kSoundWriteTraceDroppedCount(self: *const Emulator) u32 {
        const machine = self.handle.machine.testingConst();
        return machine.m68kSoundWriteTraceDroppedCount();
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

    pub fn z80Iff1(self: *const Emulator) u8 {
        return self.handle.machine.bus.z80.getRegisterDump().iff1;
    }

    pub fn z80InterruptMode(self: *const Emulator) u8 {
        return self.handle.machine.bus.z80.getRegisterDump().interrupt_mode;
    }

    pub fn z80Halted(self: *const Emulator) u8 {
        return self.handle.machine.bus.z80.getRegisterDump().halted;
    }

    pub fn z80ReadByte(self: *const Emulator, addr: u16) u8 {
        return self.handle.machine.bus.z80.readByte(addr);
    }

    pub fn z80Bank(self: *const Emulator) u16 {
        return self.handle.machine.bus.z80.getBank();
    }

    pub fn z80BusAckWord(self: *const Emulator) u16 {
        const machine = self.handle.machine.testingConst();
        return machine.z80BusAckWord();
    }

    pub fn z80ResetControlWord(self: *const Emulator) u16 {
        const machine = self.handle.machine.testingConst();
        return machine.z80ResetControlWord();
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

    pub fn saveToFile(self: *const Emulator, path: []const u8) !void {
        try state_file.saveToFile(&self.handle.machine, path);
    }

    pub fn loadFromFile(allocator: std.mem.Allocator, path: []const u8) !Emulator {
        const state = try allocator.create(State);
        errdefer allocator.destroy(state);

        state.* = .{
            .machine = try state_file.loadFromFile(allocator, path),
        };
        return .{ .handle = state };
    }

    pub fn cpuPc(self: *const Emulator) u32 {
        return self.handle.machine.programCounter();
    }

    pub fn palMode(self: *const Emulator) bool {
        return self.handle.machine.palMode();
    }

    pub fn cpuInstructionRegister(self: *const Emulator) u16 {
        return self.handle.machine.cpu.core.ir;
    }

    pub fn cpuExceptionThrown(self: *const Emulator) i32 {
        return self.handle.machine.cpu.core.exception_thrown;
    }

    pub fn cpuSr(self: *const Emulator) u16 {
        return self.handle.machine.cpu.core.sr;
    }

    pub fn m68kSyncCycles(self: *const Emulator) u64 {
        return self.handle.machine.m68k_sync.master_cycles;
    }

    pub fn readRam(self: *const Emulator, offset: u16) u8 {
        return self.handle.machine.bus.ram[offset];
    }

    pub fn writeRam(self: *Emulator, offset: u16, value: u8) void {
        self.handle.machine.bus.ram[offset] = value;
    }

    pub fn setCpuPc(self: *Emulator, pc: u32) void {
        self.handle.machine.cpu.core.pc = pc;
    }

    pub fn setCpuSr(self: *Emulator, sr: u16) void {
        self.handle.machine.cpu.core.sr = sr;
    }

    pub fn setM68kSyncCycles(self: *Emulator, cycles: u64) void {
        self.handle.machine.m68k_sync.master_cycles = cycles;
    }
};
