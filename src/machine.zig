const std = @import("std");
const clock = @import("clock.zig");
const Bus = @import("bus/bus.zig").Bus;
const Cpu = @import("cpu/cpu.zig").Cpu;
const scheduler = @import("scheduler/frame_scheduler.zig");

pub const Machine = struct {
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

    pub fn deinit(self: *Machine, allocator: std.mem.Allocator) void {
        self.bus.deinit(allocator);
    }

    pub fn reset(self: *Machine) void {
        var memory = self.bus.cpuMemory();
        self.cpu.reset(&memory);
        self.m68k_sync = .{};
    }

    pub fn flushPersistentStorage(self: *Machine) !void {
        try self.bus.flushPersistentStorage();
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
