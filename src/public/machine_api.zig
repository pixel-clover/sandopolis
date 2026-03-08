const std = @import("std");
const internal_machine = @import("../machine.zig");

const State = struct {
    machine: internal_machine.Machine,
};

pub const CpuState = struct {
    program_counter: u32,
    stack_pointer: u32,
};

pub const Machine = struct {
    handle: *State,

    pub fn init(allocator: std.mem.Allocator, rom_path: ?[]const u8) !Machine {
        const state = try allocator.create(State);
        errdefer allocator.destroy(state);

        state.* = .{
            .machine = try internal_machine.Machine.init(allocator, rom_path),
        };
        return .{ .handle = state };
    }

    pub fn deinit(self: *Machine, allocator: std.mem.Allocator) void {
        self.handle.machine.deinit(allocator);
        allocator.destroy(self.handle);
    }

    pub fn reset(self: *Machine) void {
        self.handle.machine.reset();
    }

    pub fn flushPersistentStorage(self: *Machine) !void {
        try self.handle.machine.flushPersistentStorage();
    }

    pub fn runMasterSlice(self: *Machine, total_master_cycles: u32) void {
        self.handle.machine.runMasterSlice(total_master_cycles);
    }

    pub fn cpuState(self: *const Machine) CpuState {
        return .{
            .program_counter = @as(u32, self.handle.machine.cpu.core.pc),
            .stack_pointer = @as(u32, self.handle.machine.cpu.core.a_regs[7].l),
        };
    }

    pub fn debugDump(self: *Machine) void {
        self.handle.machine.debugDump();
    }
};
