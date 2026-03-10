const std = @import("std");
const clock = @import("clock.zig");
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
