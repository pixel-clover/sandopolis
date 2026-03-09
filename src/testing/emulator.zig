const std = @import("std");
const clock = @import("../clock.zig");
const scheduler = @import("../scheduler/frame_scheduler.zig");
const internal_bus = @import("../bus/bus.zig");
const internal_cpu = @import("../cpu/cpu.zig");
const internal_timing = @import("../audio/timing.zig");

const empty_rom = [_]u8{};

const State = struct {
    bus: internal_bus.Bus,
    cpu: internal_cpu.Cpu,
    m68k_sync: clock.M68kSync,
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
            .bus = try internal_bus.Bus.init(allocator, rom_path),
            .cpu = internal_cpu.Cpu.init(),
            .m68k_sync = .{},
        };
        return .{ .handle = state };
    }

    pub fn initFromRomBytes(allocator: std.mem.Allocator, rom_bytes: []const u8) !Emulator {
        const state = try allocator.create(State);
        errdefer allocator.destroy(state);

        state.* = .{
            .bus = try internal_bus.Bus.initFromRomBytes(allocator, rom_bytes),
            .cpu = internal_cpu.Cpu.init(),
            .m68k_sync = .{},
        };
        return .{ .handle = state };
    }

    pub fn initEmpty(allocator: std.mem.Allocator) !Emulator {
        return initFromRomBytes(allocator, &empty_rom);
    }

    pub fn deinit(self: *Emulator, allocator: std.mem.Allocator) void {
        self.handle.bus.deinit(allocator);
        allocator.destroy(self.handle);
    }

    pub fn reset(self: *Emulator) void {
        var memory = self.handle.bus.cpuMemory();
        self.handle.cpu.reset(&memory);
        self.handle.m68k_sync = .{};
    }

    pub fn flushPersistentStorage(self: *Emulator) !void {
        try self.handle.bus.flushPersistentStorage();
    }

    pub fn runMasterSlice(self: *Emulator, total_master_cycles: u32) void {
        scheduler.runMasterSlice(
            self.handle.bus.schedulerRuntime(),
            self.handle.cpu.schedulerRuntime(),
            &self.handle.m68k_sync,
            total_master_cycles,
        );
    }

    fn runFrameState(state: *State) void {
        const visible_lines = clock.ntsc_visible_lines;
        const total_lines = clock.ntsc_lines_per_frame;
        const bus = &state.bus;
        const cpu = &state.cpu;
        const m68k_sync = &state.m68k_sync;

        bus.vdp.beginFrame();
        for (0..total_lines) |line_idx| {
            const line: u16 = @intCast(line_idx);
            const entering_vblank = bus.vdp.setScanlineState(line, visible_lines, total_lines);
            if (entering_vblank and bus.vdp.isVBlankInterruptEnabled()) {
                cpu.requestInterrupt(6);
            }
            if (entering_vblank) {
                bus.z80.assertIrq(0xFF);
            } else if (!bus.vdp.vint_pending) {
                bus.z80.clearIrq();
            }
            bus.vdp.setHBlank(false);

            const hint_master_cycles = bus.vdp.hInterruptMasterCycles();
            const hblank_start_master_cycles = bus.vdp.hblankStartMasterCycles();
            const first_event_master_cycles = @min(hint_master_cycles, hblank_start_master_cycles);
            const second_event_master_cycles = @max(hint_master_cycles, hblank_start_master_cycles);

            scheduler.runMasterSlice(bus.schedulerRuntime(), cpu.schedulerRuntime(), m68k_sync, first_event_master_cycles);

            if (hblank_start_master_cycles == first_event_master_cycles) {
                bus.vdp.setHBlank(true);
            }
            if (hint_master_cycles == first_event_master_cycles and bus.vdp.consumeHintForLine(line, visible_lines)) {
                cpu.requestInterrupt(4);
            }

            scheduler.runMasterSlice(bus.schedulerRuntime(), cpu.schedulerRuntime(), m68k_sync, second_event_master_cycles - first_event_master_cycles);

            if (hblank_start_master_cycles == second_event_master_cycles and hblank_start_master_cycles != first_event_master_cycles) {
                bus.vdp.setHBlank(true);
            }
            if (hint_master_cycles == second_event_master_cycles and hint_master_cycles != first_event_master_cycles and bus.vdp.consumeHintForLine(line, visible_lines)) {
                cpu.requestInterrupt(4);
            }

            scheduler.runMasterSlice(bus.schedulerRuntime(), cpu.schedulerRuntime(), m68k_sync, clock.ntsc_master_cycles_per_line - second_event_master_cycles);
            bus.vdp.setHBlank(false);

            if (line < visible_lines) {
                bus.vdp.renderScanline(line);
            }
        }
        bus.vdp.odd_frame = !bus.vdp.odd_frame;
    }

    pub fn runFrame(self: *Emulator) void {
        runFrameState(self.handle);
    }

    pub fn runFrames(self: *Emulator, frames: usize) void {
        for (0..frames) |_| {
            runFrameState(self.handle);
        }
    }

    pub fn cpuState(self: *const Emulator) CpuState {
        return .{
            .program_counter = @as(u32, self.handle.cpu.core.pc),
            .stack_pointer = @as(u32, self.handle.cpu.core.a_regs[7].l),
        };
    }

    pub fn runCpuCycles(self: *Emulator, budget: u32) u32 {
        var memory = self.handle.bus.cpuMemory();
        return self.handle.cpu.runCycles(&memory, budget);
    }

    pub fn noteCpuBusAccessWait(self: *Emulator, address: u32, size_bytes: u8, is_write: bool) void {
        var memory = self.handle.bus.cpuMemory();
        self.handle.cpu.noteBusAccessWait(&memory, address, size_bytes, is_write);
    }

    pub fn takeCpuWaitAccounting(self: *Emulator) WaitAccounting {
        const wait = self.handle.cpu.takeWaitAccounting();
        return .{
            .m68k_cycles = wait.m68k_cycles,
            .master_cycles = wait.master_cycles,
        };
    }

    pub fn formatCurrentInstruction(self: *Emulator, buffer: []u8) []const u8 {
        var memory = self.handle.bus.cpuMemory();
        return self.handle.cpu.formatCurrentInstruction(&memory, buffer);
    }

    pub fn read8(self: *Emulator, address: u32) u8 {
        return self.handle.bus.read8(address);
    }

    pub fn read16(self: *Emulator, address: u32) u16 {
        return self.handle.bus.read16(address);
    }

    pub fn read32(self: *Emulator, address: u32) u32 {
        return self.handle.bus.read32(address);
    }

    pub fn write8(self: *Emulator, address: u32, value: u8) void {
        self.handle.bus.write8(address, value);
    }

    pub fn write16(self: *Emulator, address: u32, value: u16) void {
        self.handle.bus.write16(address, value);
    }

    pub fn write32(self: *Emulator, address: u32, value: u32) void {
        self.handle.bus.write32(address, value);
    }

    pub fn writeRomByte(self: *Emulator, offset: usize, value: u8) void {
        std.debug.assert(offset < self.handle.bus.rom.len);
        self.handle.bus.rom[offset] = value;
    }

    pub fn hasCartridgeRam(self: *const Emulator) bool {
        return self.handle.bus.hasCartridgeRam();
    }

    pub fn isCartridgeRamMapped(self: *const Emulator) bool {
        return self.handle.bus.isCartridgeRamMapped();
    }

    pub fn persistentSavePath(self: *const Emulator) ?[]const u8 {
        return self.handle.bus.persistentSavePath();
    }

    pub fn configureVdpDataPort(self: *Emulator, code: u8, addr: u16, auto_increment: u8) void {
        self.handle.bus.vdp.regs[15] = auto_increment;
        self.handle.bus.vdp.code = code;
        self.handle.bus.vdp.addr = addr;
    }

    pub fn setVdpRegister(self: *Emulator, index: usize, value: u8) void {
        std.debug.assert(index < self.handle.bus.vdp.regs.len);
        self.handle.bus.vdp.regs[index] = value;
    }

    pub fn vdpRegister(self: *const Emulator, index: usize) u8 {
        std.debug.assert(index < self.handle.bus.vdp.regs.len);
        return self.handle.bus.vdp.regs[index];
    }

    pub fn setVdpCode(self: *Emulator, code: u8) void {
        self.handle.bus.vdp.code = code;
    }

    pub fn setVdpAddr(self: *Emulator, addr: u16) void {
        self.handle.bus.vdp.addr = addr;
    }

    pub fn vdpAddr(self: *const Emulator) u16 {
        return self.handle.bus.vdp.addr;
    }

    pub fn writeVdpData(self: *Emulator, value: u16) void {
        self.handle.bus.vdp.writeData(value);
    }

    pub fn vdpDataPortWriteWaitMasterCycles(self: *const Emulator) u32 {
        return self.handle.bus.vdp.dataPortWriteWaitMasterCycles();
    }

    pub fn vdpDataPortReadWaitMasterCycles(self: *const Emulator) u32 {
        return self.handle.bus.vdp.dataPortReadWaitMasterCycles();
    }

    pub fn vdpShouldHaltCpu(self: *const Emulator) bool {
        return self.handle.bus.vdp.shouldHaltCpu();
    }

    pub fn forceMemoryToVramDma(self: *Emulator, source_addr: u32, length: u16) void {
        self.handle.bus.vdp.dma_active = true;
        self.handle.bus.vdp.dma_fill = false;
        self.handle.bus.vdp.dma_copy = false;
        self.handle.bus.vdp.dma_source_addr = source_addr;
        self.handle.bus.vdp.dma_length = length;
        self.handle.bus.vdp.dma_remaining = length;
        self.handle.bus.vdp.dma_start_delay_slots = 0;
    }

    pub fn vdpIsDmaActive(self: *const Emulator) bool {
        return self.handle.bus.vdp.dma_active;
    }

    pub fn framebuffer(self: *const Emulator) []const u32 {
        return self.handle.bus.vdp.framebuffer[0..];
    }

    pub fn takePendingAudio(self: *Emulator) PendingAudioFrames {
        return self.handle.bus.audio_timing.takePending();
    }

    pub fn ymKeyMask(self: *const Emulator) u8 {
        return self.handle.bus.z80.getYmKeyMask();
    }

    pub fn ymRegister(self: *const Emulator, port: u1, reg: u8) u8 {
        return self.handle.bus.z80.getYmRegister(port, reg);
    }

    pub fn z80Reset(self: *Emulator) void {
        self.handle.bus.z80.reset();
    }

    pub fn z80WriteByte(self: *Emulator, addr: u16, value: u8) void {
        self.handle.bus.z80.writeByte(addr, value);
    }

    pub fn z80ProgramCounter(self: *const Emulator) u16 {
        return self.handle.bus.z80.getPc();
    }

    pub fn setZ80BusRequest(self: *Emulator, value: u16) void {
        self.handle.bus.write16(0x00A1_1100, value);
    }

    pub fn setZ80ResetControl(self: *Emulator, value: u16) void {
        self.handle.bus.write16(0x00A1_1200, value);
    }

    pub fn pendingM68kWaitMasterCycles(self: *const Emulator) u32 {
        return self.handle.bus.pendingM68kWaitMasterCycles();
    }

    pub fn setPendingM68kWaitMasterCycles(self: *Emulator, master_cycles: u32) void {
        self.handle.bus.m68k_wait_master_cycles = master_cycles;
    }

    pub fn cpuDebtMasterCycles(self: *const Emulator) u32 {
        return self.handle.m68k_sync.debt_master_cycles;
    }
};
