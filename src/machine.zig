const std = @import("std");
const clock = @import("clock.zig");
const PendingAudioFrames = @import("audio/timing.zig").PendingAudioFrames;
const Bus = @import("bus/bus.zig").Bus;
const Cpu = @import("cpu/cpu.zig").Cpu;
const InputBindings = @import("input/mapping.zig");
const Io = @import("input/io.zig").Io;
const perf_profile = @import("performance_profile.zig");
const scheduler = @import("scheduler/frame_scheduler.zig");
const Vdp = @import("video/vdp.zig").Vdp;

pub const Machine = struct {
    pub const CoreFrameCounters = perf_profile.CoreFrameCounters;
    const PendingFramePhase = enum {
        none,
        hard_reset,
        current,
    };

    pub const Snapshot = struct {
        machine: Machine,

        pub fn deinit(self: *Snapshot, allocator: std.mem.Allocator) void {
            self.machine.deinit(allocator);
        }
    };

    pub const RomMetadata = struct {
        console: ?[]const u8,
        title: ?[]const u8,
        product_code: ?[]const u8,
        country_codes: ?[]const u8,
        reset_stack_pointer: u32,
        reset_program_counter: u32,
        header_checksum: u16,
        computed_checksum: u16,
        checksum_valid: bool,
    };

    pub const TestingView = struct {
        machine: *Machine,

        pub fn runCpuCycles(self: *TestingView, budget: u32) u32 {
            var memory = self.machine.bus.cpuMemory();
            return self.machine.cpu.runCycles(&memory, budget);
        }

        pub fn noteCpuBusAccessWait(self: *TestingView, address: u32, size_bytes: u8, is_write: bool) void {
            var memory = self.machine.bus.cpuMemory();
            self.machine.cpu.noteBusAccessWait(&memory, address, size_bytes, is_write);
        }

        pub fn takeCpuWaitAccounting(self: *TestingView) Cpu.WaitAccounting {
            return self.machine.cpu.takeWaitAccounting();
        }

        pub fn formatCurrentInstruction(self: *TestingView, buffer: []u8) []const u8 {
            var memory = self.machine.bus.cpuMemory();
            return self.machine.cpu.formatCurrentInstruction(&memory, buffer);
        }

        pub fn read8(self: *TestingView, address: u32) u8 {
            return self.machine.bus.read8(address);
        }

        pub fn read16(self: *TestingView, address: u32) u16 {
            return self.machine.bus.read16(address);
        }

        pub fn read32(self: *TestingView, address: u32) u32 {
            return self.machine.bus.read32(address);
        }

        pub fn write8(self: *TestingView, address: u32, value: u8) void {
            self.machine.bus.write8(address, value);
        }

        pub fn write16(self: *TestingView, address: u32, value: u16) void {
            self.machine.bus.write16(address, value);
        }

        pub fn write32(self: *TestingView, address: u32, value: u32) void {
            self.machine.bus.write32(address, value);
        }

        pub fn setTestPrefetch(self: *TestingView, ctx: *Bus.TestPrefetchCtx) void {
            self.machine.bus.setTestPrefetch(ctx);
        }

        pub fn writeRomByte(self: *TestingView, offset: usize, value: u8) void {
            std.debug.assert(offset < self.machine.bus.rom.len);
            self.machine.bus.rom[offset] = value;
        }

        pub fn configureVdpDataPort(self: *TestingView, code: u8, addr: u16, auto_increment: u8) void {
            self.machine.bus.vdp.regs[15] = auto_increment;
            self.machine.bus.vdp.code = code;
            self.machine.bus.vdp.addr = addr;
        }

        pub fn setVdpRegister(self: *TestingView, index: usize, value: u8) void {
            std.debug.assert(index < self.machine.bus.vdp.regs.len);
            self.machine.bus.vdp.regs[index] = value;
        }

        pub fn setPalMode(self: *TestingView, pal_mode: bool) void {
            self.machine.setPalMode(pal_mode);
        }

        pub fn setVdpCode(self: *TestingView, code: u8) void {
            self.machine.bus.vdp.code = code;
        }

        pub fn setVdpAddr(self: *TestingView, addr: u16) void {
            self.machine.bus.vdp.addr = addr;
        }

        pub fn writeVdpData(self: *TestingView, value: u16) void {
            self.machine.bus.vdp.writeData(value);
        }

        pub fn forceMemoryToVramDma(self: *TestingView, source_addr: u32, length: u16) void {
            self.machine.bus.vdp.dma_active = true;
            self.machine.bus.vdp.dma_fill = false;
            self.machine.bus.vdp.dma_copy = false;
            self.machine.bus.vdp.dma_source_addr = source_addr;
            self.machine.bus.vdp.dma_length = length;
            self.machine.bus.vdp.dma_remaining = length;
            self.machine.bus.vdp.dma_start_delay_slots = 0;
        }

        pub fn z80Reset(self: *TestingView) void {
            self.machine.bus.z80.reset();
            self.machine.bus.syncZ80RunCache();
        }

        pub fn z80WriteByte(self: *TestingView, addr: u16, value: u8) void {
            self.machine.bus.z80.writeByte(addr, value);
        }

        pub fn setZ80BusRequest(self: *TestingView, value: u16) void {
            self.machine.bus.write16(0x00A1_1100, value);
        }

        pub fn setZ80ResetControl(self: *TestingView, value: u16) void {
            self.machine.bus.write16(0x00A1_1200, value);
        }

        pub fn setPendingM68kWaitMasterCycles(self: *TestingView, master_cycles: u32) void {
            self.machine.bus.setPendingM68kWaitMasterCycles(master_cycles);
        }

        pub fn setM68kInstructionTraceEnabled(self: *TestingView, enabled: bool) void {
            self.machine.cpu.setInstructionTraceEnabled(enabled);
        }

        pub fn setM68kInstructionTraceStopOnFault(self: *TestingView, stop_on_fault: bool) void {
            self.machine.cpu.setInstructionTraceStopOnFault(stop_on_fault);
        }

        pub fn clearM68kInstructionTrace(self: *TestingView) void {
            self.machine.cpu.clearInstructionTrace();
        }

        pub fn setM68kSoundWriteTraceEnabled(self: *TestingView, enabled: bool) void {
            self.machine.bus.setM68kSoundWriteTraceEnabled(enabled);
        }

        pub fn clearM68kSoundWriteTrace(self: *TestingView) void {
            self.machine.bus.clearM68kSoundWriteTrace();
        }
    };

    pub const TestingConstView = struct {
        machine: *const Machine,

        pub fn hasCartridgeRam(self: *const TestingConstView) bool {
            return self.machine.bus.hasCartridgeRam();
        }

        pub fn isCartridgeRamMapped(self: *const TestingConstView) bool {
            return self.machine.bus.isCartridgeRamMapped();
        }

        pub fn persistentSavePath(self: *const TestingConstView) ?[]const u8 {
            return self.machine.bus.persistentSavePath();
        }

        pub fn vdpRegister(self: *const TestingConstView, index: usize) u8 {
            std.debug.assert(index < self.machine.bus.vdp.regs.len);
            return self.machine.bus.vdp.regs[index];
        }

        pub fn vdpAddr(self: *const TestingConstView) u16 {
            return self.machine.bus.vdp.addr;
        }

        pub fn vdpScanline(self: *const TestingConstView) u16 {
            return self.machine.bus.vdp.scanline;
        }

        pub fn vdpDataPortWriteWaitMasterCycles(self: *const TestingConstView) u32 {
            return self.machine.bus.vdp.dataPortWriteWaitMasterCycles();
        }

        pub fn vdpDataPortReadWaitMasterCycles(self: *const TestingConstView) u32 {
            return self.machine.bus.vdp.dataPortReadWaitMasterCycles();
        }

        pub fn vdpShouldHaltCpu(self: *const TestingConstView) bool {
            return self.machine.bus.vdp.shouldHaltCpu();
        }

        pub fn vdpIsDmaActive(self: *const TestingConstView) bool {
            return self.machine.bus.vdp.dma_active;
        }

        pub fn ymKeyMask(self: *const TestingConstView) u8 {
            return self.machine.bus.z80.getYmKeyMask();
        }

        pub fn ymRegister(self: *const TestingConstView, port: u1, reg: u8) u8 {
            return self.machine.bus.z80.getYmRegister(port, reg);
        }

        pub fn z80ProgramCounter(self: *const TestingConstView) u16 {
            return self.machine.bus.z80.getPc();
        }

        pub fn z80BusAckWord(self: *const TestingConstView) u16 {
            return self.machine.bus.z80.readBusReq();
        }

        pub fn z80ResetControlWord(self: *const TestingConstView) u16 {
            return self.machine.bus.z80.readReset();
        }

        pub fn pendingM68kWaitMasterCycles(self: *const TestingConstView) u32 {
            return self.machine.bus.pendingM68kWaitMasterCycles();
        }

        pub fn cpuDebtMasterCycles(self: *const TestingConstView) u32 {
            return self.machine.m68k_sync.debt_master_cycles;
        }

        pub fn m68kInstructionTraceEntries(self: *const TestingConstView) []const Cpu.M68kInstructionTraceEntry {
            return self.machine.cpu.instructionTraceEntries();
        }

        pub fn m68kInstructionTraceDroppedCount(self: *const TestingConstView) u32 {
            return self.machine.cpu.instructionTraceDroppedCount();
        }

        pub fn m68kSoundWriteTraceEntries(self: *const TestingConstView) []const Bus.M68kSoundWriteTraceEntry {
            return self.machine.bus.m68kSoundWriteTraceEntries();
        }

        pub fn m68kSoundWriteTraceDroppedCount(self: *const TestingConstView) u32 {
            return self.machine.bus.m68kSoundWriteTraceDroppedCount();
        }
    };

    bus: Bus,
    cpu: Cpu,
    m68k_sync: clock.M68kSync,
    pending_frame_phase: PendingFramePhase,

    pub fn init(allocator: std.mem.Allocator, rom_path: ?[]const u8) !Machine {
        return .{
            .bus = try Bus.init(allocator, rom_path),
            .cpu = Cpu.init(),
            .m68k_sync = .{},
            .pending_frame_phase = .none,
        };
    }

    pub fn initFromRomBytes(allocator: std.mem.Allocator, rom_bytes: []const u8) !Machine {
        return .{
            .bus = try Bus.initFromRomBytes(allocator, rom_bytes),
            .cpu = Cpu.init(),
            .m68k_sync = .{},
            .pending_frame_phase = .none,
        };
    }

    pub fn deinit(self: *Machine, allocator: std.mem.Allocator) void {
        self.bus.deinit(allocator);
    }

    pub fn clone(self: *const Machine, allocator: std.mem.Allocator) !Machine {
        return .{
            .bus = try self.bus.clone(allocator),
            .cpu = self.cpu.clone(),
            .m68k_sync = self.m68k_sync,
            .pending_frame_phase = self.pending_frame_phase,
        };
    }

    pub fn reset(self: *Machine) void {
        self.bus.reset();
        var memory = self.bus.cpuMemory();
        self.cpu.reset(&memory);
        self.m68k_sync = .{};
        self.pending_frame_phase = .hard_reset;
    }

    pub fn softReset(self: *Machine) void {
        self.bus.softReset();
        var memory = self.bus.cpuMemory();
        self.cpu.reset(&memory);
        self.m68k_sync = .{};
        self.pending_frame_phase = .current;
    }

    pub fn flushPersistentStorage(self: *Machine) !void {
        try self.bus.flushPersistentStorage();
    }

    pub fn captureSnapshot(self: *const Machine, allocator: std.mem.Allocator) !Snapshot {
        return .{
            .machine = try self.clone(allocator),
        };
    }

    pub fn restoreSnapshot(self: *Machine, allocator: std.mem.Allocator, snapshot: *const Snapshot) !void {
        const next_machine = try snapshot.machine.clone(allocator);
        var old_machine = self.*;
        self.* = next_machine;
        self.rebindRuntimePointers();
        self.clearPendingAudioTransferState();
        old_machine.deinit(allocator);
    }

    pub fn rebindRuntimePointers(self: *Machine) void {
        self.bus.rebindRuntimePointers();
    }

    pub fn clearPendingAudioTransferState(self: *Machine) void {
        self.bus.clearPendingAudioTransferState();
    }

    pub fn testing(self: *Machine) TestingView {
        return .{ .machine = self };
    }

    pub fn testingConst(self: *const Machine) TestingConstView {
        return .{ .machine = self };
    }

    pub fn runMasterSlice(self: *Machine, total_master_cycles: u32) void {
        scheduler.runMasterSlice(self.bus.schedulerRuntime(), self.cpu.schedulerRuntime(), &self.m68k_sync, total_master_cycles);
    }

    pub fn runFrame(self: *Machine) void {
        self.runFrameInternal(null);
    }

    pub fn runFrameProfiled(self: *Machine, counters: *CoreFrameCounters) void {
        self.runFrameInternal(counters);
    }

    fn runFrameInternal(self: *Machine, counters: ?*CoreFrameCounters) void {
        if (counters) |active_counters| {
            active_counters.* = .{};
        }
        self.bus.setActiveExecutionCounters(counters);
        self.cpu.setActiveExecutionCounters(counters);
        defer {
            self.bus.setActiveExecutionCounters(null);
            self.cpu.setActiveExecutionCounters(null);
        }

        if (self.pending_frame_phase != .none) {
            const startup_visible_lines = self.bus.vdp.activeVisibleLines();
            const startup_total_lines = self.bus.vdp.totalLinesForCurrentFrame();
            const startup_master_cycles_per_line: u16 = if (self.bus.vdp.pal_mode) clock.pal_master_cycles_per_line else clock.ntsc_master_cycles_per_line;
            const startup_line = self.bus.vdp.scanline;
            const startup_line_master_cycle = self.bus.vdp.line_master_cycle;

            self.pending_frame_phase = .none;
            self.bus.vdp.beginFrame();
            for (startup_line..startup_total_lines) |line_idx| {
                const line: u16 = @intCast(line_idx);
                const line_start_master_cycles: u16 = if (line == startup_line) startup_line_master_cycle else 0;
                self.runScheduledScanline(line, startup_visible_lines, startup_total_lines, startup_master_cycles_per_line, line_start_master_cycles, false, null);
            }
        }

        const visible_lines = self.bus.vdp.activeVisibleLines();
        const total_lines = self.bus.vdp.totalLinesForCurrentFrame();
        const master_cycles_per_line: u16 = if (self.bus.vdp.pal_mode) clock.pal_master_cycles_per_line else clock.ntsc_master_cycles_per_line;

        self.bus.vdp.beginFrame();
        for (0..total_lines) |line_idx| {
            const line: u16 = @intCast(line_idx);
            self.runScheduledScanline(line, visible_lines, total_lines, master_cycles_per_line, 0, true, counters);
        }
        self.bus.vdp.odd_frame = !self.bus.vdp.odd_frame;
    }

    fn runScheduledScanline(
        self: *Machine,
        line: u16,
        visible_lines: u16,
        total_lines: u16,
        master_cycles_per_line: u16,
        start_master_cycles: u16,
        render_visible: bool,
        counters: ?*CoreFrameCounters,
    ) void {
        const entering_vblank = self.bus.vdp.setScanlineState(line, visible_lines, total_lines);
        if (!entering_vblank and !self.bus.vdp.vint_pending) {
            self.bus.z80.clearIrq();
        }

        if (render_visible and line < visible_lines) {
            self.bus.vdp.preParseSpritesForLine(line);
        }

        const hint_master_cycles = self.bus.vdp.hInterruptMasterCycles();
        const hblank_start_master_cycles = self.bus.vdp.hblankStartMasterCycles();
        self.bus.vdp.hblank = start_master_cycles >= hblank_start_master_cycles;

        // Collect all scanline events and sort by time. VInt fires at a specific
        // cycle offset into the vblank entry line (matching Genesis Plus GX), not
        // at cycle 0. This lets HInt fire first when both occur on the same line.
        var events: [3]u16 = undefined;
        var event_count: u8 = 0;
        events[event_count] = hint_master_cycles;
        event_count += 1;
        events[event_count] = hblank_start_master_cycles;
        event_count += 1;
        const vint_master_cycles: u16 = if (entering_vblank) self.bus.vdp.vIntMasterCycles() else master_cycles_per_line;
        if (entering_vblank) {
            events[event_count] = vint_master_cycles;
            event_count += 1;
        }

        // Sort events (simple insertion sort for 2-3 elements).
        var i: u8 = 1;
        while (i < event_count) : (i += 1) {
            var j = i;
            while (j > 0 and events[j] < events[j - 1]) : (j -= 1) {
                const tmp = events[j];
                events[j] = events[j - 1];
                events[j - 1] = tmp;
            }
        }

        var current_master_cycles = start_master_cycles;
        var prev_event: u16 = start_master_cycles;
        for (events[0..event_count]) |event_mc| {
            if (event_mc == prev_event and event_mc != events[0]) continue; // skip duplicates
            if (current_master_cycles < event_mc) {
                scheduler.runMasterSlice(
                    self.bus.schedulerRuntime(),
                    self.cpu.schedulerRuntime(),
                    &self.m68k_sync,
                    event_mc - current_master_cycles,
                );
                current_master_cycles = event_mc;
            }
            if (event_mc > start_master_cycles or event_mc == events[0]) {
                self.applyScanlineEvent(line, visible_lines, entering_vblank, hint_master_cycles, hblank_start_master_cycles, vint_master_cycles, event_mc);
            }
            prev_event = event_mc;
        }

        if (current_master_cycles < master_cycles_per_line) {
            scheduler.runMasterSlice(
                self.bus.schedulerRuntime(),
                self.cpu.schedulerRuntime(),
                &self.m68k_sync,
                master_cycles_per_line - current_master_cycles,
            );
        }
        self.bus.vdp.setHBlank(false);

        if (render_visible and line < visible_lines) {
            if (counters) |active_counters| active_counters.render_scanlines += 1;
            self.bus.vdp.renderScanline(line);
        }
    }

    fn applyScanlineEvent(
        self: *Machine,
        line: u16,
        visible_lines: u16,
        entering_vblank: bool,
        hint_master_cycles: u16,
        hblank_start_master_cycles: u16,
        vint_master_cycles: u16,
        event_master_cycles: u16,
    ) void {
        if (hblank_start_master_cycles == event_master_cycles) {
            self.bus.vdp.setHBlank(true);
        }
        if (hint_master_cycles == event_master_cycles and self.bus.vdp.consumeHintForLine(line, visible_lines)) {
            self.cpu.requestInterrupt(4);
        }
        if (entering_vblank and vint_master_cycles == event_master_cycles) {
            if (self.bus.vdp.isVBlankInterruptEnabled()) {
                self.cpu.requestInterrupt(6);
            }
            self.bus.z80.assertIrq(0xFF);
        }
    }

    pub fn frameMasterCycles(self: *const Machine) u32 {
        return self.bus.vdp.frameMasterCycles();
    }

    pub fn framebuffer(self: *const Machine) []const u32 {
        return self.bus.vdp.framebuffer[0 .. Vdp.framebuffer_width * @as(usize, self.bus.vdp.activeVisibleLines())];
    }

    pub fn romMetadata(self: *const Machine) RomMetadata {
        const rom = self.bus.rom;
        const has_header = rom.len >= 0x200;
        const header_checksum: u16 = if (has_header)
            (@as(u16, rom[0x18E]) << 8) | rom[0x18F]
        else
            0;
        const computed_checksum = computeRomChecksum(rom);
        return .{
            .console = if (has_header) rom[0x100..0x110] else null,
            .title = if (has_header) rom[0x150..0x180] else null,
            .product_code = if (has_header) rom[0x183..0x18B] else null,
            .country_codes = if (has_header) rom[0x1F0..0x200] else null,
            .reset_stack_pointer = readBeU32(rom[0..], 0),
            .reset_program_counter = readBeU32(rom[0..], 4),
            .header_checksum = header_checksum,
            .computed_checksum = computed_checksum,
            .checksum_valid = has_header and header_checksum == computed_checksum,
        };
    }

    fn computeRomChecksum(rom: []const u8) u16 {
        // Genesis ROM checksum: sum of all 16-bit words from offset 0x200
        // to end of ROM, wrapping at 16 bits.
        if (rom.len < 0x202) return 0;
        var sum: u16 = 0;
        var offset: usize = 0x200;
        while (offset + 1 < rom.len) : (offset += 2) {
            const word = (@as(u16, rom[offset]) << 8) | rom[offset + 1];
            sum +%= word;
        }
        return sum;
    }

    pub fn controllerPadState(self: *const Machine, port: usize) u16 {
        std.debug.assert(port < self.bus.io.pad.len);
        return self.bus.io.pad[port];
    }

    pub fn readWorkRamByte(self: *const Machine, offset: usize) u8 {
        std.debug.assert(offset < self.bus.ram.len);
        return self.bus.ram[offset];
    }

    pub fn writeWorkRamByte(self: *Machine, offset: usize, value: u8) void {
        std.debug.assert(offset < self.bus.ram.len);
        self.bus.ram[offset] = value;
    }

    pub fn palMode(self: *const Machine) bool {
        return self.bus.vdp.pal_mode;
    }

    pub fn setPalMode(self: *Machine, pal_mode: bool) void {
        self.bus.vdp.pal_mode = pal_mode;
        if (self.pending_frame_phase == .hard_reset) {
            self.bus.vdp.applyPowerOnResetTiming();
        }
    }

    pub fn consoleIsOverseas(self: *const Machine) bool {
        return self.bus.io.versionIsOverseas();
    }

    pub fn setConsoleIsOverseas(self: *Machine, overseas: bool) void {
        self.bus.io.setVersionIsOverseas(overseas);
    }

    pub fn takePendingAudio(self: *Machine) PendingAudioFrames {
        return self.bus.audio_timing.takePending();
    }

    pub fn drainPendingAudio(self: *Machine, sink: anytype) !void {
        const pending = self.takePendingAudio();
        if (sink.canAcceptPending()) {
            try sink.pushPending(pending, &self.bus.z80, self.palMode());
        } else {
            try sink.discardPending(pending, &self.bus.z80, self.palMode());
        }
    }

    pub fn discardPendingAudio(self: *Machine) void {
        _ = self.takePendingAudio();
    }

    pub fn programCounter(self: *const Machine) u32 {
        return @as(u32, self.cpu.core.pc);
    }

    pub fn stackPointer(self: *const Machine) u32 {
        return @as(u32, self.cpu.core.a_regs[7].l);
    }

    pub fn installDummyTestRom(self: *Machine) void {
        std.debug.assert(self.bus.rom.len >= 0x280);
        seedDummyTestRom(self.bus.rom[0..]);
    }

    pub fn applyControllerTypes(self: *Machine, bindings: *const InputBindings.Bindings) void {
        bindings.applyControllerTypes(&self.bus.io);
    }

    pub fn applyKeyboardBindings(
        self: *Machine,
        bindings: *const InputBindings.Bindings,
        input: InputBindings.KeyboardInput,
        pressed: bool,
    ) bool {
        return bindings.applyKeyboard(&self.bus.io, input, pressed);
    }

    pub fn releaseKeyboardBindings(self: *Machine, bindings: *const InputBindings.Bindings) void {
        bindings.releaseKeyboard(&self.bus.io);
    }

    pub fn applyGamepadBindings(
        self: *Machine,
        bindings: *const InputBindings.Bindings,
        port: usize,
        input: InputBindings.GamepadInput,
        pressed: bool,
    ) bool {
        return bindings.applyGamepad(&self.bus.io, port, input, pressed);
    }

    pub fn releaseGamepadBindings(self: *Machine, bindings: *const InputBindings.Bindings, port: usize) void {
        bindings.releaseGamepad(&self.bus.io, port);
    }

    pub fn debugDump(self: *Machine) void {
        std.debug.print("=== Register Dump ===\n", .{});
        self.cpu.debugDump();
        var memory = self.bus.cpuMemory();
        self.cpu.debugCurrentInstruction(&memory);
        self.bus.z80.debugDump();
        self.bus.vdp.debugDump();
    }
};

fn readBeU32(buffer: []const u8, offset: usize) u32 {
    if (buffer.len < offset + 4) return 0;
    return (@as(u32, buffer[offset]) << 24) |
        (@as(u32, buffer[offset + 1]) << 16) |
        (@as(u32, buffer[offset + 2]) << 8) |
        @as(u32, buffer[offset + 3]);
}

fn writeBeU16(buffer: []u8, offset: usize, value: u16) void {
    buffer[offset] = @truncate(value >> 8);
    buffer[offset + 1] = @truncate(value);
}

fn writeBeU32(buffer: []u8, offset: usize, value: u32) void {
    buffer[offset] = @truncate(value >> 24);
    buffer[offset + 1] = @truncate(value >> 16);
    buffer[offset + 2] = @truncate(value >> 8);
    buffer[offset + 3] = @truncate(value);
}

fn emitMoveWordAbs(rom: []u8, pc: *u32, value: u16, address: u32) void {
    writeBeU16(rom, pc.*, 0x33FC);
    writeBeU16(rom, pc.* + 2, value);
    writeBeU32(rom, pc.* + 4, address);
    pc.* += 8;
}

fn emitMoveByteAbsToD0(rom: []u8, pc: *u32, address: u32) void {
    writeBeU16(rom, pc.*, 0x1039);
    writeBeU32(rom, pc.* + 2, address);
    pc.* += 6;
}

fn emitAndiByteD0(rom: []u8, pc: *u32, value: u8) void {
    writeBeU16(rom, pc.*, 0x0200);
    writeBeU16(rom, pc.* + 2, value);
    pc.* += 4;
}

fn emitBra8(rom: []u8, pc: *u32, offset: i32) void {
    rom[pc.*] = 0x60;
    rom[pc.* + 1] = @as(u8, @intCast(offset & 0xFF));
    pc.* += 2;
}

fn seedDummyTestRom(rom: []u8) void {
    writeBeU32(rom, 0, 0x00FF_0000);
    writeBeU32(rom, 4, 0x0000_0200);

    var pc: u32 = 0x0200;

    emitMoveWordAbs(rom, &pc, 0x8238, 0x00C0_0004);
    emitMoveWordAbs(rom, &pc, 0x8F02, 0x00C0_0004);
    emitMoveWordAbs(rom, &pc, 0xC000, 0x00C0_0004);
    emitMoveWordAbs(rom, &pc, 0x0000, 0x00C0_0004);
    emitMoveWordAbs(rom, &pc, 0x000E, 0x00C0_0000);
    emitMoveWordAbs(rom, &pc, 0x00E0, 0x00C0_0000);
    emitMoveWordAbs(rom, &pc, 0x0040, 0x00A1_0002);

    const loop_start = pc;
    emitMoveByteAbsToD0(rom, &pc, 0x00A1_0003);
    emitAndiByteD0(rom, &pc, 0x10);

    const branch_loc = pc;
    pc += 2;

    emitMoveWordAbs(rom, &pc, 0xC000, 0x00C0_0004);
    emitMoveWordAbs(rom, &pc, 0x0000, 0x00C0_0004);
    emitMoveWordAbs(rom, &pc, 0x000E, 0x00C0_0000);

    const back_jump = @as(i32, @intCast(loop_start)) - @as(i32, @intCast(pc + 2));
    emitBra8(rom, &pc, back_jump);

    const pressed_target = pc;
    const fwd_jump = @as(i32, @intCast(pressed_target)) - @as(i32, @intCast(branch_loc + 2));
    rom[branch_loc] = 0x67;
    rom[branch_loc + 1] = @as(u8, @intCast(fwd_jump & 0xFF));

    emitMoveWordAbs(rom, &pc, 0xC000, 0x00C0_0004);
    emitMoveWordAbs(rom, &pc, 0x0000, 0x00C0_0004);
    emitMoveWordAbs(rom, &pc, 0x00E0, 0x00C0_0000);

    const back_jump2 = @as(i32, @intCast(loop_start)) - @as(i32, @intCast(pc + 2));
    emitBra8(rom, &pc, back_jump2);
    emitBra8(rom, &pc, -2);
}

test "machine snapshots restore CPU bus and Z80 state" {
    const allocator = std.testing.allocator;
    const rom = [_]u8{0} ** 0x400;

    var machine = try Machine.initFromRomBytes(allocator, rom[0..]);
    defer machine.deinit(allocator);

    machine.bus.rom[0] = 0x11;
    machine.bus.ram[0x1234] = 0x56;
    machine.bus.vdp.regs[1] = 0x40;
    machine.bus.audio_timing.consumeMaster(1234);
    machine.bus.z80.writeByte(0x0000, 0x9A);
    machine.bus.z80.setAudioMasterOffset(1234);
    machine.bus.z80.writeByte(0x4000, 0x22);
    machine.bus.z80.writeByte(0x4001, 0x0F);
    machine.bus.z80.writeByte(0x7F11, 0x90);
    machine.cpu.core.pc = 0x0000_1234;
    machine.cpu.core.sr = 0x2700;
    machine.m68k_sync.master_cycles = 777;

    var snapshot = try machine.captureSnapshot(allocator);
    defer snapshot.deinit(allocator);

    machine.bus.rom[0] = 0x99;
    machine.bus.ram[0x1234] = 0x00;
    machine.bus.vdp.regs[1] = 0x00;
    _ = machine.bus.audio_timing.takePending();
    machine.bus.z80.writeByte(0x0000, 0x00);
    machine.cpu.core.pc = 0x0000_0002;
    machine.cpu.core.sr = 0x0000;
    machine.m68k_sync.master_cycles = 0;

    try machine.restoreSnapshot(allocator, &snapshot);

    try std.testing.expectEqual(@as(u8, 0x11), machine.bus.rom[0]);
    try std.testing.expectEqual(@as(u8, 0x56), machine.bus.ram[0x1234]);
    try std.testing.expectEqual(@as(u8, 0x40), machine.bus.vdp.regs[1]);
    try std.testing.expectEqual(@as(u8, 0x9A), machine.bus.z80.readByte(0x0000));
    try std.testing.expectEqual(@as(u8, 0x0F), machine.bus.z80.getYmRegister(0, 0x22));
    try std.testing.expectEqual(@as(u8, 0x90), machine.bus.z80.getPsgLast());
    try std.testing.expectEqual(@as(u32, 0x0000_1234), @as(u32, machine.cpu.core.pc));
    try std.testing.expectEqual(@as(u16, 0x2700), @as(u16, machine.cpu.core.sr));
    try std.testing.expectEqual(@as(u64, 777), machine.m68k_sync.master_cycles);
    try std.testing.expectEqual(@as(u32, 0), machine.takePendingAudio().master_cycles);
    try std.testing.expectEqual(@as(u16, 0), machine.bus.z80.pendingYmWriteCount());
    try std.testing.expectEqual(@as(u16, 0), machine.bus.z80.pendingPsgCommandCount());
}

fn makeGenesisRom(allocator: std.mem.Allocator, stack_pointer: u32, program_counter: u32, program: []const u8) ![]u8 {
    const rom_len = @max(@as(usize, 0x4000), 0x0200 + program.len);
    var rom = try allocator.alloc(u8, rom_len);
    @memset(rom, 0);
    @memcpy(rom[0x100..0x104], "SEGA");
    std.mem.writeInt(u32, rom[0..4], stack_pointer, .big);
    std.mem.writeInt(u32, rom[4..8], program_counter, .big);
    @memcpy(rom[0x0200 .. 0x0200 + program.len], program);
    return rom;
}

test "machine runFrame advances execution and toggles the frame parity bit" {
    const allocator = std.testing.allocator;
    const program = [_]u8{
        0x4E, 0x71,
        0x4E, 0x71,
        0x60, 0xFC,
    };
    const rom = try makeGenesisRom(allocator, 0x00FF_FE00, 0x0000_0200, &program);
    defer allocator.free(rom);

    var machine = try Machine.initFromRomBytes(allocator, rom);
    defer machine.deinit(allocator);
    machine.reset();

    const pc_before = machine.programCounter();
    try std.testing.expect(!machine.bus.vdp.odd_frame);

    machine.runFrame();

    try std.testing.expect(machine.programCounter() != pc_before);
    try std.testing.expect(machine.bus.vdp.odd_frame);
}

test "machine reset seeds the reference power-on phase and setPalMode retargets it before first frame" {
    const allocator = std.testing.allocator;
    const rom = try makeGenesisRom(allocator, 0x00FF_FE00, 0x0000_0200, &[_]u8{
        0x4E, 0x71,
        0x60, 0xFE,
    });
    defer allocator.free(rom);

    var machine = try Machine.initFromRomBytes(allocator, rom);
    defer machine.deinit(allocator);

    machine.reset();
    try std.testing.expectEqual(@as(@TypeOf(machine.pending_frame_phase), .hard_reset), machine.pending_frame_phase);
    try std.testing.expectEqual(@as(u16, 159), machine.bus.vdp.scanline);
    try std.testing.expectEqual(@as(u16, 522), machine.bus.vdp.line_master_cycle);
    try std.testing.expectEqual(@as(u16, 0x0000), machine.bus.z80.readReset());
    try std.testing.expect(!machine.bus.z80.canRun());

    machine.setPalMode(true);
    try std.testing.expectEqual(@as(@TypeOf(machine.pending_frame_phase), .hard_reset), machine.pending_frame_phase);
    try std.testing.expect(machine.palMode());
    try std.testing.expectEqual(@as(u16, 132), machine.bus.vdp.scanline);
    try std.testing.expectEqual(@as(u16, 522), machine.bus.vdp.line_master_cycle);

    machine.runFrame();
    try std.testing.expectEqual(@as(@TypeOf(machine.pending_frame_phase), .none), machine.pending_frame_phase);

    const scanline_after_frame = machine.bus.vdp.scanline;
    const line_master_cycle_after_frame = machine.bus.vdp.line_master_cycle;
    machine.setPalMode(false);
    try std.testing.expectEqual(scanline_after_frame, machine.bus.vdp.scanline);
    try std.testing.expectEqual(line_master_cycle_after_frame, machine.bus.vdp.line_master_cycle);
}

test "machine soft reset preserves runtime memory and phase while resetting cpu and z80 core state" {
    const allocator = std.testing.allocator;
    const rom = try makeGenesisRom(allocator, 0x00FF_FE00, 0x0000_0200, &[_]u8{
        0x4E, 0x71,
        0x60, 0xFE,
    });
    defer allocator.free(rom);

    var machine = try Machine.initFromRomBytes(allocator, rom);
    defer machine.deinit(allocator);

    machine.reset();
    machine.runFrame();

    machine.writeWorkRamByte(0x1234, 0xA5);
    machine.bus.vdp.scanline = 77;
    machine.bus.vdp.line_master_cycle = 1234;
    machine.bus.vdp.odd_frame = true;
    machine.bus.z80.writeByte(0x0000, 0x12);

    machine.softReset();

    try std.testing.expectEqual(@as(@TypeOf(machine.pending_frame_phase), .current), machine.pending_frame_phase);
    try std.testing.expectEqual(@as(u8, 0xA5), machine.readWorkRamByte(0x1234));
    try std.testing.expectEqual(@as(u16, 77), machine.bus.vdp.scanline);
    try std.testing.expectEqual(@as(u16, 1234), machine.bus.vdp.line_master_cycle);
    try std.testing.expect(machine.bus.vdp.odd_frame);
    try std.testing.expectEqual(@as(u8, 0x12), machine.bus.z80.readByte(0x0000));
    try std.testing.expectEqual(@as(u16, 0x0000), machine.bus.z80.readReset());
    try std.testing.expect(!machine.bus.z80.canRun());
    try std.testing.expectEqual(@as(u32, 0x0000_0200), machine.programCounter());

    machine.setPalMode(true);
    try std.testing.expectEqual(@as(u16, 77), machine.bus.vdp.scanline);
    try std.testing.expectEqual(@as(u16, 1234), machine.bus.vdp.line_master_cycle);

    machine.runFrame();
    try std.testing.expectEqual(@as(@TypeOf(machine.pending_frame_phase), .none), machine.pending_frame_phase);
}

test "machine binding helpers update and release controller state" {
    const allocator = std.testing.allocator;
    const rom = [_]u8{0} ** 0x400;

    var machine = try Machine.initFromRomBytes(allocator, rom[0..]);
    defer machine.deinit(allocator);

    var bindings = InputBindings.Bindings.defaults();
    machine.applyControllerTypes(&bindings);

    _ = machine.applyKeyboardBindings(&bindings, .a, true);
    try std.testing.expectEqual(@as(u16, 0), machine.controllerPadState(0) & Io.Button.A);

    machine.releaseKeyboardBindings(&bindings);
    try std.testing.expect((machine.controllerPadState(0) & Io.Button.A) != 0);

    _ = machine.applyGamepadBindings(&bindings, 0, .south, true);
    try std.testing.expectEqual(@as(u16, 0), machine.controllerPadState(0) & Io.Button.B);

    machine.releaseGamepadBindings(&bindings, 0);
    try std.testing.expect((machine.controllerPadState(0) & Io.Button.B) != 0);
}

test "machine audio drain helper routes pending audio to sink policy" {
    const allocator = std.testing.allocator;
    const rom = [_]u8{0} ** 0x400;

    const MockSink = struct {
        can_accept: bool = true,
        push_count: usize = 0,
        discard_count: usize = 0,
        last_master_cycles: u32 = 0,
        saw_pal: bool = false,

        fn canAcceptPending(self: *@This()) bool {
            return self.can_accept;
        }

        fn pushPending(self: *@This(), pending: PendingAudioFrames, z80: anytype, is_pal: bool) !void {
            _ = z80;
            self.push_count += 1;
            self.last_master_cycles = pending.master_cycles;
            self.saw_pal = is_pal;
        }

        fn discardPending(self: *@This(), pending: PendingAudioFrames, z80: anytype, is_pal: bool) !void {
            _ = z80;
            self.discard_count += 1;
            self.last_master_cycles = pending.master_cycles;
            self.saw_pal = is_pal;
        }
    };

    var machine = try Machine.initFromRomBytes(allocator, rom[0..]);
    defer machine.deinit(allocator);
    machine.bus.vdp.pal_mode = true;

    var sink = MockSink{};

    machine.bus.audio_timing.consumeMaster(1234);
    try machine.drainPendingAudio(&sink);
    try std.testing.expectEqual(@as(usize, 1), sink.push_count);
    try std.testing.expectEqual(@as(usize, 0), sink.discard_count);
    try std.testing.expectEqual(@as(u32, 1234), sink.last_master_cycles);
    try std.testing.expect(sink.saw_pal);

    sink.can_accept = false;
    machine.bus.audio_timing.consumeMaster(567);
    try machine.drainPendingAudio(&sink);
    try std.testing.expectEqual(@as(usize, 1), sink.push_count);
    try std.testing.expectEqual(@as(usize, 1), sink.discard_count);
    try std.testing.expectEqual(@as(u32, 567), sink.last_master_cycles);
}

test "machine rom metadata exposes header slices and reset vectors" {
    const allocator = std.testing.allocator;
    const rom = try makeGenesisRom(allocator, 0x00FF_FE00, 0x0000_0200, &[_]u8{ 0x4E, 0x71 });
    defer allocator.free(rom);

    var machine = try Machine.initFromRomBytes(allocator, rom);
    defer machine.deinit(allocator);

    const metadata = machine.romMetadata();
    try std.testing.expect(metadata.console != null);
    try std.testing.expect(metadata.title != null);
    try std.testing.expect(metadata.product_code != null);
    try std.testing.expectEqual(@as(u32, 0x00FF_FE00), metadata.reset_stack_pointer);
    try std.testing.expectEqual(@as(u32, 0x0000_0200), metadata.reset_program_counter);
}

test "rom checksum validation detects correct and incorrect checksums" {
    const allocator = std.testing.allocator;
    // Build a ROM with a program starting at 0x200.
    const program = [_]u8{ 0x4E, 0x71, 0x4E, 0x71 }; // two NOPs
    const rom = try makeGenesisRom(allocator, 0x00FF_FE00, 0x0000_0200, &program);
    defer allocator.free(rom);

    // Compute the expected checksum by summing words from 0x200.
    var expected: u16 = 0;
    var offset: usize = 0x200;
    while (offset + 1 < rom.len) : (offset += 2) {
        const word = (@as(u16, rom[offset]) << 8) | rom[offset + 1];
        expected +%= word;
    }

    // Write the correct checksum into the header.
    rom[0x18E] = @intCast((expected >> 8) & 0xFF);
    rom[0x18F] = @intCast(expected & 0xFF);

    var valid_machine = try Machine.initFromRomBytes(allocator, rom);
    defer valid_machine.deinit(allocator);
    const valid_meta = valid_machine.romMetadata();
    try std.testing.expect(valid_meta.checksum_valid);
    try std.testing.expectEqual(expected, valid_meta.header_checksum);
    try std.testing.expectEqual(expected, valid_meta.computed_checksum);

    // Corrupt the checksum and verify detection.
    rom[0x18E] = 0xFF;
    rom[0x18F] = 0xFF;
    var invalid_machine = try Machine.initFromRomBytes(allocator, rom);
    defer invalid_machine.deinit(allocator);
    const invalid_meta = invalid_machine.romMetadata();
    try std.testing.expect(!invalid_meta.checksum_valid);
    try std.testing.expectEqual(@as(u16, 0xFFFF), invalid_meta.header_checksum);
    try std.testing.expectEqual(expected, invalid_meta.computed_checksum);
}

test "machine installs dummy test rom vectors and program" {
    const allocator = std.testing.allocator;
    const rom = [_]u8{0} ** 0x400;

    var machine = try Machine.initFromRomBytes(allocator, rom[0..]);
    defer machine.deinit(allocator);

    machine.installDummyTestRom();
    const metadata = machine.romMetadata();

    try std.testing.expectEqual(@as(u32, 0x00FF_0000), metadata.reset_stack_pointer);
    try std.testing.expectEqual(@as(u32, 0x0000_0200), metadata.reset_program_counter);
    try std.testing.expectEqual(@as(u16, 0x33FC), (@as(u16, machine.bus.rom[0x0200]) << 8) | @as(u16, machine.bus.rom[0x0201]));
    try std.testing.expectEqual(@as(u16, 0x8238), (@as(u16, machine.bus.rom[0x0202]) << 8) | @as(u16, machine.bus.rom[0x0203]));
}

test "machine reset clears transient hardware state and preserves console configuration" {
    const allocator = std.testing.allocator;
    const rom = try makeGenesisRom(allocator, 0x00FF_FE00, 0x0000_0200, &[_]u8{
        0x4E, 0x71,
        0x60, 0xFE,
    });
    defer allocator.free(rom);

    var machine = try Machine.initFromRomBytes(allocator, rom);
    defer machine.deinit(allocator);

    var bindings = InputBindings.Bindings.defaults();
    bindings.setControllerType(0, .three_button);

    machine.setPalMode(true);
    machine.setConsoleIsOverseas(false);
    machine.applyControllerTypes(&bindings);
    _ = machine.applyKeyboardBindings(&bindings, .a, true);

    machine.bus.ram[0x1234] = 0xA5;
    machine.bus.vdp.regs[1] = 0x40;
    machine.bus.vdp.scanline = 77;
    machine.bus.vdp.line_master_cycle = 1234;
    machine.bus.vdp.odd_frame = true;
    machine.bus.z80.writeByte(0x0000, 0x12);
    machine.bus.audio_timing.consumeMaster(555);
    machine.m68k_sync.master_cycles = 777;

    machine.reset();

    try std.testing.expectEqual(@as(u8, 0), machine.bus.ram[0x1234]);
    try std.testing.expectEqual(@as(u8, 0), machine.bus.vdp.regs[1]);
    try std.testing.expectEqual(@as(@TypeOf(machine.pending_frame_phase), .hard_reset), machine.pending_frame_phase);
    try std.testing.expectEqual(@as(u16, 132), machine.bus.vdp.scanline);
    try std.testing.expectEqual(@as(u16, 522), machine.bus.vdp.line_master_cycle);
    try std.testing.expect(!machine.bus.vdp.odd_frame);
    try std.testing.expect(machine.palMode());
    try std.testing.expect(!machine.consoleIsOverseas());
    try std.testing.expectEqual(Io.ControllerType.three_button, machine.bus.io.getControllerType(0));
    try std.testing.expectEqual(@as(u16, 0), machine.controllerPadState(0) & Io.Button.A);
    try std.testing.expectEqual(@as(u8, 0), machine.bus.z80.readByte(0x0000));
    try std.testing.expectEqual(@as(u32, 0), machine.takePendingAudio().master_cycles);
    try std.testing.expectEqual(@as(u64, 0), machine.m68k_sync.master_cycles);
    try std.testing.expectEqual(@as(u32, 0x0000_0200), machine.programCounter());
}
