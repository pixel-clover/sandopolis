const std = @import("std");
const testing = std.testing;
const Cartridge = @import("cartridge.zig").Cartridge;
const cpu_memory = @import("cpu_memory.zig");
const bus_save_state = @import("save_state.zig");
const z80_timing = @import("z80_timing.zig");
const z80_host_bridge = @import("z80_host_bridge.zig");
const clock = @import("../clock.zig");
const CoreFrameCounters = @import("../performance_profile.zig").CoreFrameCounters;
const AudioTiming = @import("../audio/timing.zig").AudioTiming;
const Vdp = @import("../video/vdp.zig").Vdp;
const Io = @import("../input/io.zig").Io;
const Z80 = @import("../cpu/z80.zig").Z80;
const MemoryInterface = @import("../cpu/memory_interface.zig").MemoryInterface;
const cpu_runtime = @import("../cpu/runtime_state.zig");
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
    timing_state: z80_timing.State,
    open_bus: u16,
    cpu_runtime_state: cpu_runtime.RuntimeState,
    active_execution_counters: ?*CoreFrameCounters,
    fn initWithCartridge(cartridge: Cartridge) Bus {
        const bus = Bus{
            .rom = cartridge.rom,
            .cartridge = cartridge,
            .ram = [_]u8{0} ** (64 * 1024),
            .vdp = Vdp.init(),
            .io = Io.init(),
            .z80 = Z80.init(),
            .z80_host_bridge = z80_host_bridge.HostBridge.init(z80HostWindowReadByte, z80HostWindowPeekByte, z80HostWindowWriteByte, z80HostM68kBusAccess),
            .audio_timing = .{},
            .timing_state = .{},
            .open_bus = 0,
            .cpu_runtime_state = .{},
            .active_execution_counters = null,
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

    pub fn sourcePath(self: *const Bus) ?[]const u8 {
        return self.cartridge.sourcePath();
    }

    pub fn romBytes(self: *const Bus) []const u8 {
        return self.cartridge.romBytes();
    }

    pub fn cartridgeRamBytes(self: *const Bus) ?[]const u8 {
        return self.cartridge.ramBytes();
    }

    pub fn flushPersistentStorage(self: *Bus) !void {
        try self.cartridge.flushPersistentStorage();
    }

    pub fn m68kAccessWaitMasterCycles(self: *Bus, address: u32, size_bytes: u8) u32 {
        var memory = self.cpuMemoryView();
        return memory.m68kAccessWaitMasterCycles(address, size_bytes);
    }

    fn z80HostWindowReadByte(ctx: ?*anyopaque, address: u32) u8 {
        const self: *Bus = @ptrCast(@alignCast(ctx orelse return 0xFF));
        return self.read8(address);
    }

    fn z80HostWindowPeekByte(ctx: ?*anyopaque, address: u32) u8 {
        const self: *Bus = @ptrCast(@alignCast(ctx orelse return 0xFF));
        return self.peek8NoSideEffects(address);
    }

    fn z80HostWindowWriteByte(ctx: ?*anyopaque, address: u32, value: u8) void {
        const self: *Bus = @ptrCast(@alignCast(ctx orelse return));
        self.write8(address, value);
    }

    fn z80HostM68kBusAccess(ctx: ?*anyopaque, pre_access_master_cycles: u32) void {
        const self: *Bus = @ptrCast(@alignCast(ctx orelse return));
        self.recordZ80M68kBusAccess(pre_access_master_cycles);
    }

    fn vdpDmaReadWordCallback(userdata: ?*anyopaque, address: u32) u16 {
        const self: *Bus = @ptrCast(@alignCast(userdata orelse return 0));
        return self.read16(address);
    }

    fn ensureZ80HostWindowCallback(ctx: ?*anyopaque) void {
        const self: *Bus = @ptrCast(@alignCast(ctx orelse return));
        self.ensureZ80HostWindow();
    }

    fn cpuMemoryView(self: *Bus) cpu_memory.View {
        return cpu_memory.View.init(
            &self.cartridge,
            &self.ram,
            &self.vdp,
            &self.io,
            &self.z80,
            &self.audio_timing,
            &self.open_bus,
            &self.cpu_runtime_state,
            self,
            ensureZ80HostWindowCallback,
        );
    }

    fn z80TimingView(self: *Bus) z80_timing.View {
        return z80_timing.View.init(
            &self.vdp,
            &self.z80,
            &self.audio_timing,
            &self.io,
            &self.timing_state,
            self.active_execution_counters,
            self,
            ensureZ80HostWindowCallback,
            self,
            vdpDmaReadWordCallback,
        );
    }

    fn recordZ80M68kBusAccess(self: *Bus, pre_access_master_cycles: u32) void {
        var timing = self.z80TimingView();
        timing.recordZ80M68kBusAccess(pre_access_master_cycles);
    }

    fn recordZ80M68kBusAccesses(self: *Bus, access_count: u32) void {
        var timing = self.z80TimingView();
        timing.recordZ80M68kBusAccesses(access_count);
    }

    fn ensureZ80HostWindow(self: *Bus) void {
        self.z80_host_bridge.bind(&self.z80, self);
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

    pub fn clone(self: *const Bus, allocator: std.mem.Allocator) !Bus {
        var cartridge = try self.cartridge.clone(allocator);
        errdefer cartridge.deinit(allocator);

        var z80 = try self.z80.clone();
        errdefer z80.deinit();

        var vdp = self.vdp;
        vdp.active_execution_counters = null;
        return .{
            .rom = cartridge.rom,
            .cartridge = cartridge,
            .ram = self.ram,
            .vdp = vdp,
            .io = self.io,
            .z80 = z80,
            .z80_host_bridge = z80_host_bridge.HostBridge.init(z80HostWindowReadByte, z80HostWindowPeekByte, z80HostWindowWriteByte, z80HostM68kBusAccess),
            .audio_timing = self.audio_timing,
            .timing_state = self.timing_state,
            .open_bus = self.open_bus,
            .cpu_runtime_state = .{},
            .active_execution_counters = null,
        };
    }

    pub fn rebindRuntimePointers(self: *Bus) void {
        self.z80_host_bridge.bind(&self.z80, self);
    }

    pub fn setActiveExecutionCounters(self: *Bus, counters: ?*CoreFrameCounters) void {
        self.active_execution_counters = counters;
        self.vdp.setActiveExecutionCounters(counters);
    }

    pub fn reset(self: *Bus) void {
        const pal_mode = self.vdp.pal_mode;
        const controller_pad = self.io.pad;
        const controller_types = self.io.controller_types;
        const version_is_overseas = self.io.versionIsOverseas();
        const active_execution_counters = self.active_execution_counters;

        self.cartridge.resetHardwareState();
        self.ram = [_]u8{0} ** self.ram.len;

        self.vdp = Vdp.init();
        self.vdp.pal_mode = pal_mode;
        self.vdp.applyPowerOnResetTiming();
        self.vdp.setActiveExecutionCounters(active_execution_counters);

        self.io.resetForHardware();
        self.io.pad = controller_pad;
        self.io.controller_types = controller_types;
        self.io.setVersionIsOverseas(version_is_overseas);

        self.z80.reset();
        self.audio_timing = .{};
        self.timing_state = .{};
        self.open_bus = 0;
        self.cpu_runtime_state = .{};
        self.ensureZ80HostWindow();
    }

    pub fn softReset(self: *Bus) void {
        self.cartridge.resetHardwareState();
        self.z80.setAudioMasterOffset(self.audio_timing.pending_master_cycles);
        self.z80.softReset();
        self.timing_state = .{};
        self.open_bus = 0;
        self.cpu_runtime_state = .{};
        self.ensureZ80HostWindow();
    }

    pub fn cpuMemory(self: *Bus) MemoryInterface {
        return MemoryInterface.bind(Bus, self);
    }

    pub fn read8(self: *Bus, address: u32) u8 {
        var memory = self.cpuMemoryView();
        return memory.read8(address);
    }

    fn peek8NoSideEffects(self: *Bus, address: u32) u8 {
        var memory = self.cpuMemoryView();
        return memory.peek8NoSideEffects(address);
    }

    pub fn read16(self: *Bus, address: u32) u16 {
        var memory = self.cpuMemoryView();
        return memory.read16(address);
    }

    pub fn read32(self: *Bus, address: u32) u32 {
        var memory = self.cpuMemoryView();
        return memory.read32(address);
    }

    pub fn write8(self: *Bus, address: u32, value: u8) void {
        var memory = self.cpuMemoryView();
        memory.write8(address, value);
    }

    pub fn write16(self: *Bus, address: u32, value: u16) void {
        var memory = self.cpuMemoryView();
        memory.write16(address, value);
    }

    pub fn write32(self: *Bus, address: u32, value: u32) void {
        var memory = self.cpuMemoryView();
        memory.write32(address, value);
    }

    pub fn dataPortReadWaitMasterCycles(self: *Bus) u32 {
        var memory = self.cpuMemoryView();
        return memory.dataPortReadWaitMasterCycles();
    }

    pub fn reserveDataPortWriteWaitMasterCycles(self: *Bus) u32 {
        var memory = self.cpuMemoryView();
        return memory.reserveDataPortWriteWaitMasterCycles();
    }

    pub fn controlPortWriteWaitMasterCycles(self: *Bus) u32 {
        var memory = self.cpuMemoryView();
        return memory.controlPortWriteWaitMasterCycles();
    }

    pub fn setCpuRuntimeState(self: *Bus, state: cpu_runtime.RuntimeState) void {
        var memory = self.cpuMemoryView();
        memory.setCpuRuntimeState(state);
    }

    pub fn clearCpuRuntimeState(self: *Bus) void {
        var memory = self.cpuMemoryView();
        memory.clearCpuRuntimeState();
    }

    pub fn pendingM68kWaitMasterCycles(self: *const Bus) u32 {
        return self.timing_state.pendingM68kWaitMasterCycles();
    }

    pub fn shouldHaltM68k(self: *const Bus) bool {
        return self.vdp.shouldHaltCpu();
    }

    pub fn schedulerRuntime(self: *Bus) SchedulerBus {
        return SchedulerBus.bind(Bus, self);
    }

    pub fn consumeM68kWaitMasterCycles(self: *Bus, max_master_cycles: u32) u32 {
        return self.timing_state.consumeM68kWaitMasterCycles(max_master_cycles);
    }

    pub fn dmaHaltQuantum(self: *Bus) u32 {
        return self.vdp.nextTransferStepMasterCycles();
    }

    pub fn setPendingM68kWaitMasterCycles(self: *Bus, master_cycles: u32) void {
        self.timing_state.setPendingM68kWaitMasterCycles(master_cycles);
    }

    pub fn captureTimingState(self: *const Bus) z80_timing.State {
        return self.timing_state;
    }

    pub fn restoreTimingState(self: *Bus, state: z80_timing.State) void {
        self.timing_state = state;
    }

    pub fn captureSaveState(self: *const Bus) bus_save_state.State {
        return .{
            .ram = self.ram,
            .vdp = self.vdp,
            .io = self.io,
            .audio_timing = self.audio_timing,
            .timing_state = self.captureTimingState(),
            .open_bus = self.open_bus,
            .cartridge_ram = self.cartridge.captureRamState(),
        };
    }

    pub fn restoreSaveState(self: *Bus, state: bus_save_state.State, cartridge_ram_bytes: ?[]const u8) error{InvalidSaveState}!void {
        self.ram = state.ram;
        self.vdp = state.vdp;
        self.vdp.setActiveExecutionCounters(self.active_execution_counters);
        self.io = state.io;
        self.audio_timing = state.audio_timing;
        self.restoreTimingState(state.timing_state);
        self.open_bus = state.open_bus;
        try self.cartridge.restoreRamState(state.cartridge_ram, cartridge_ram_bytes);
    }

    pub fn replaceStoragePaths(self: *Bus, allocator: std.mem.Allocator, save_path: ?[]u8, source_path: ?[]u8) void {
        if (self.cartridge.save_path) |existing| allocator.free(existing);
        self.cartridge.save_path = save_path;
        if (self.cartridge.source_path) |existing| allocator.free(existing);
        self.cartridge.source_path = source_path;
    }

    pub fn stepMaster(self: *Bus, master_cycles: u32) void {
        var timing = self.z80TimingView();
        timing.stepMaster(master_cycles);
    }

    pub fn step(self: *Bus, m68k_cycles: u32) void {
        self.stepMaster(clock.m68kCyclesToMaster(m68k_cycles));
    }
};

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
    var timing_state = bus.captureTimingState();
    try testing.expectEqual(@as(u16, 0x0003), bus.z80.getPc());
    try testing.expectEqual(@as(u32, 0), timing_state.z80_wait_master_cycles);
    try testing.expectEqual(clock.m68kCyclesToMaster(10), bus.pendingM68kWaitMasterCycles());

    bus.stepMaster(1);
    timing_state = bus.captureTimingState();
    try testing.expectEqual(@as(u16, 0x0000), bus.z80.getPc());
    try testing.expect(timing_state.z80_master_credit < 0);

    bus.stepMaster(164);
    timing_state = bus.captureTimingState();
    try testing.expectEqual(@as(u16, 0x0000), bus.z80.getPc());
    try testing.expectEqual(@as(i64, -1), timing_state.z80_master_credit);

    bus.stepMaster(16);
    timing_state = bus.captureTimingState();
    try testing.expectEqual(@as(u16, 0x0003), bus.z80.getPc());
    try testing.expect(timing_state.z80_master_credit < 0);
    try testing.expectEqual(clock.m68kCyclesToMaster(20), bus.pendingM68kWaitMasterCycles());
}

test "mid-instruction z80 stall flush is charged against later master slices" {
    var bus = try Bus.init(testing.allocator, null);
    defer bus.deinit(testing.allocator);

    bus.z80.reset();
    bus.z80.writeByte(0x0000, 0x34); // INC (HL)

    var state = bus.z80.captureState();
    state.pc = 0x0000;
    state.hl = 0x8000;
    state.bank = 0x0000;
    bus.z80.restoreState(&state);
    bus.rom[0x0000] = 0x10;

    bus.stepMaster(clock.z80_divider);
    var timing_state = bus.captureTimingState();
    try testing.expectEqual(@as(u16, 0x0001), bus.z80.getPc());
    try testing.expectEqual(@as(u32, 169), timing_state.z80_stall_master_debt);
    try testing.expectEqual(@as(u32, 50), timing_state.z80_wait_master_cycles);
    try testing.expectEqual(@as(u32, clock.z80_divider + 169), bus.audio_timing.pending_master_cycles);

    bus.stepMaster(169);
    timing_state = bus.captureTimingState();
    try testing.expectEqual(@as(u32, 0), timing_state.z80_stall_master_debt);
    try testing.expectEqual(@as(u32, 50), timing_state.z80_wait_master_cycles);
    try testing.expectEqual(@as(u32, clock.z80_divider + 169), bus.audio_timing.pending_master_cycles);

    bus.stepMaster(50);
    timing_state = bus.captureTimingState();
    try testing.expectEqual(@as(u32, 0), timing_state.z80_wait_master_cycles);
    try testing.expectEqual(@as(u32, clock.z80_divider + 219), bus.audio_timing.pending_master_cycles);
}

test "banked access offsets advance vdp state before the first z80 host read" {
    var bus = try Bus.init(testing.allocator, null);
    defer bus.deinit(testing.allocator);

    bus.vdp.scanline = 0;
    bus.vdp.line_master_cycle = 0;

    var expected_vdp = bus.vdp;
    expected_vdp.step(11 * clock.z80_divider);
    const expected_counter_byte: u8 = @truncate(expected_vdp.readHVCounterAdjusted(0));
    try testing.expect(expected_counter_byte != @as(u8, @truncate(bus.vdp.readHVCounterAdjusted(0))));

    bus.z80.reset();
    bus.z80.writeByte(0x0000, 0x3A); // LD A,(nn)
    bus.z80.writeByte(0x0001, 0x09);
    bus.z80.writeByte(0x0002, 0x80);
    var state = bus.z80.captureState();
    state.pc = 0x0000;
    state.bank = 0x0180;
    bus.z80.restoreState(&state);

    bus.stepMaster(clock.z80_divider);

    const a = @as(u8, @truncate(bus.z80.getRegisterDump().af >> 8));
    const timing_state = bus.captureTimingState();
    try testing.expectEqual(expected_counter_byte, a);
    try testing.expectEqual(@as(u32, 150), timing_state.z80_stall_master_debt);
    try testing.expectEqual(@as(u32, 49), timing_state.z80_wait_master_cycles);
    try testing.expectEqual(@as(u32, 165), bus.audio_timing.pending_master_cycles);
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
