const std = @import("std");
const clock = @import("clock.zig");
const PendingAudioFrames = @import("audio/timing.zig").PendingAudioFrames;
const Bus = @import("bus/bus.zig").Bus;
const Cpu = @import("cpu/cpu.zig").Cpu;
const InputBindings = @import("input/mapping.zig");
const Io = @import("input/io.zig").Io;
const scheduler = @import("scheduler/frame_scheduler.zig");

pub const Machine = struct {
    pub const Snapshot = struct {
        machine: Machine,

        pub fn deinit(self: *Snapshot, allocator: std.mem.Allocator) void {
            self.machine.deinit(allocator);
        }
    };

    pub const RomMetadata = struct {
        console: ?[]const u8,
        title: ?[]const u8,
        reset_stack_pointer: u32,
        reset_program_counter: u32,
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
            self.machine.bus.m68k_wait_master_cycles = master_cycles;
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

        pub fn pendingM68kWaitMasterCycles(self: *const TestingConstView) u32 {
            return self.machine.bus.pendingM68kWaitMasterCycles();
        }

        pub fn cpuDebtMasterCycles(self: *const TestingConstView) u32 {
            return self.machine.m68k_sync.debt_master_cycles;
        }
    };

    bus: Bus,
    cpu: Cpu,
    m68k_sync: clock.M68kSync,

    pub fn init(allocator: std.mem.Allocator, rom_path: ?[]const u8) !Machine {
        return .{
            .bus = try Bus.init(allocator, rom_path),
            .cpu = Cpu.init(),
            .m68k_sync = .{},
        };
    }

    pub fn initFromRomBytes(allocator: std.mem.Allocator, rom_bytes: []const u8) !Machine {
        return .{
            .bus = try Bus.initFromRomBytes(allocator, rom_bytes),
            .cpu = Cpu.init(),
            .m68k_sync = .{},
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
        };
    }

    pub fn reset(self: *Machine) void {
        var memory = self.bus.cpuMemory();
        self.cpu.reset(&memory);
        self.m68k_sync = .{};
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
        old_machine.deinit(allocator);
    }

    pub fn rebindRuntimePointers(self: *Machine) void {
        self.bus.rebindRuntimePointers();
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
        const visible_lines: u16 = if (self.bus.vdp.pal_mode) clock.pal_visible_lines else clock.ntsc_visible_lines;
        const total_lines: u16 = if (self.bus.vdp.pal_mode) clock.pal_lines_per_frame else clock.ntsc_lines_per_frame;
        const master_cycles_per_line: u16 = if (self.bus.vdp.pal_mode) clock.pal_master_cycles_per_line else clock.ntsc_master_cycles_per_line;

        self.bus.vdp.beginFrame();
        for (0..total_lines) |line_idx| {
            const line: u16 = @intCast(line_idx);
            const entering_vblank = self.bus.vdp.setScanlineState(line, visible_lines, total_lines);
            if (entering_vblank and self.bus.vdp.isVBlankInterruptEnabled()) {
                self.cpu.requestInterrupt(6);
            }
            if (entering_vblank) {
                self.bus.z80.assertIrq(0xFF);
            } else if (!self.bus.vdp.vint_pending) {
                self.bus.z80.clearIrq();
            }
            self.bus.vdp.setHBlank(false);

            const hint_master_cycles = self.bus.vdp.hInterruptMasterCycles();
            const hblank_start_master_cycles = self.bus.vdp.hblankStartMasterCycles();
            const first_event_master_cycles = @min(hint_master_cycles, hblank_start_master_cycles);
            const second_event_master_cycles = @max(hint_master_cycles, hblank_start_master_cycles);

            scheduler.runMasterSlice(self.bus.schedulerRuntime(), self.cpu.schedulerRuntime(), &self.m68k_sync, first_event_master_cycles);

            if (hblank_start_master_cycles == first_event_master_cycles) {
                self.bus.vdp.setHBlank(true);
            }
            if (hint_master_cycles == first_event_master_cycles and self.bus.vdp.consumeHintForLine(line, visible_lines)) {
                self.cpu.requestInterrupt(4);
            }

            scheduler.runMasterSlice(
                self.bus.schedulerRuntime(),
                self.cpu.schedulerRuntime(),
                &self.m68k_sync,
                second_event_master_cycles - first_event_master_cycles,
            );

            if (hblank_start_master_cycles == second_event_master_cycles and hblank_start_master_cycles != first_event_master_cycles) {
                self.bus.vdp.setHBlank(true);
            }
            if (hint_master_cycles == second_event_master_cycles and
                hint_master_cycles != first_event_master_cycles and
                self.bus.vdp.consumeHintForLine(line, visible_lines))
            {
                self.cpu.requestInterrupt(4);
            }

            scheduler.runMasterSlice(
                self.bus.schedulerRuntime(),
                self.cpu.schedulerRuntime(),
                &self.m68k_sync,
                master_cycles_per_line - second_event_master_cycles,
            );
            self.bus.vdp.setHBlank(false);

            if (line < visible_lines) {
                self.bus.vdp.renderScanline(line);
            }
        }
        self.bus.vdp.odd_frame = !self.bus.vdp.odd_frame;
    }

    pub fn framebuffer(self: *const Machine) *const [320 * 224]u32 {
        return &self.bus.vdp.framebuffer;
    }

    pub fn romMetadata(self: *const Machine) RomMetadata {
        return .{
            .console = if (self.bus.rom.len >= 0x200) self.bus.rom[0x100..0x110] else null,
            .title = if (self.bus.rom.len >= 0x200) self.bus.rom[0x150..0x180] else null,
            .reset_stack_pointer = readBeU32(self.bus.rom[0..], 0),
            .reset_program_counter = readBeU32(self.bus.rom[0..], 4),
        };
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
    try std.testing.expectEqual(@as(u32, 0x0000_1234), @as(u32, machine.cpu.core.pc));
    try std.testing.expectEqual(@as(u16, 0x2700), @as(u16, machine.cpu.core.sr));
    try std.testing.expectEqual(@as(u64, 777), machine.m68k_sync.master_cycles);

    const pending = machine.bus.audio_timing.takePending();
    try std.testing.expectEqual(@as(u32, 1234), pending.master_cycles);
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

    _ = machine.applyGamepadBindings(&bindings, 0, .east, true);
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
    try std.testing.expectEqual(@as(u32, 0x00FF_FE00), metadata.reset_stack_pointer);
    try std.testing.expectEqual(@as(u32, 0x0000_0200), metadata.reset_program_counter);
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
