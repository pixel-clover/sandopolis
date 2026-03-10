const std = @import("std");
const internal_machine = @import("../machine.zig");

const empty_rom = [_]u8{};

const State = struct {
    machine: internal_machine.Machine,
};

pub const CpuState = struct {
    program_counter: u32,
    stack_pointer: u32,
};

pub const RomMetadata = struct {
    console: ?[]const u8,
    title: ?[]const u8,
    reset_stack_pointer: u32,
    reset_program_counter: u32,
};

pub const Snapshot = struct {
    handle: internal_machine.Machine.Snapshot,

    pub fn deinit(self: *Snapshot, allocator: std.mem.Allocator) void {
        self.handle.deinit(allocator);
    }
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

    pub fn initFromRomBytes(allocator: std.mem.Allocator, rom_bytes: []const u8) !Machine {
        const state = try allocator.create(State);
        errdefer allocator.destroy(state);

        state.* = .{
            .machine = try internal_machine.Machine.initFromRomBytes(allocator, rom_bytes),
        };
        return .{ .handle = state };
    }

    pub fn initEmpty(allocator: std.mem.Allocator) !Machine {
        return initFromRomBytes(allocator, &empty_rom);
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

    pub fn captureSnapshot(self: *const Machine, allocator: std.mem.Allocator) !Snapshot {
        return .{
            .handle = try self.handle.machine.captureSnapshot(allocator),
        };
    }

    pub fn restoreSnapshot(self: *Machine, allocator: std.mem.Allocator, snapshot: *const Snapshot) !void {
        try self.handle.machine.restoreSnapshot(allocator, &snapshot.handle);
    }

    pub fn runFrame(self: *Machine) void {
        self.handle.machine.runFrame();
    }

    pub fn runMasterSlice(self: *Machine, total_master_cycles: u32) void {
        self.handle.machine.runMasterSlice(total_master_cycles);
    }

    pub fn framebuffer(self: *const Machine) []const u32 {
        return self.handle.machine.framebuffer()[0..];
    }

    pub fn romMetadata(self: *const Machine) RomMetadata {
        const metadata = self.handle.machine.romMetadata();
        return .{
            .console = metadata.console,
            .title = metadata.title,
            .reset_stack_pointer = metadata.reset_stack_pointer,
            .reset_program_counter = metadata.reset_program_counter,
        };
    }

    pub fn palMode(self: *const Machine) bool {
        return self.handle.machine.palMode();
    }

    pub fn cpuState(self: *const Machine) CpuState {
        return .{
            .program_counter = self.handle.machine.programCounter(),
            .stack_pointer = self.handle.machine.stackPointer(),
        };
    }

    pub fn debugDump(self: *Machine) void {
        self.handle.machine.debugDump();
    }
};
