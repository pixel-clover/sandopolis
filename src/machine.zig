const std = @import("std");
const clock = @import("clock.zig");
const PendingAudioFrames = @import("audio/timing.zig").PendingAudioFrames;
const Bus = @import("bus/bus.zig").Bus;
const Cpu = @import("cpu/cpu.zig").Cpu;
const scheduler = @import("scheduler/frame_scheduler.zig");

pub const Machine = struct {
    pub const Snapshot = struct {
        machine: Machine,

        pub fn deinit(self: *Snapshot, allocator: std.mem.Allocator) void {
            self.machine.deinit(allocator);
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
        self.bus.rebindRuntimePointers();
        old_machine.deinit(allocator);
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

    pub fn palMode(self: *const Machine) bool {
        return self.bus.vdp.pal_mode;
    }

    pub fn takePendingAudio(self: *Machine) PendingAudioFrames {
        return self.bus.audio_timing.takePending();
    }

    pub fn programCounter(self: *const Machine) u32 {
        return @as(u32, self.cpu.core.pc);
    }

    pub fn stackPointer(self: *const Machine) u32 {
        return @as(u32, self.cpu.core.a_regs[7].l);
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
