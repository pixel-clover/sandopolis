const std = @import("std");
const internal_io = @import("../input/io.zig");

const State = struct {
    io: internal_io.Io = internal_io.Io.init(),
};

pub const ControllerType = enum {
    three_button,
    six_button,
};

pub const Button = struct {
    pub const Up: u16 = internal_io.Io.Button.Up;
    pub const Down: u16 = internal_io.Io.Button.Down;
    pub const Left: u16 = internal_io.Io.Button.Left;
    pub const Right: u16 = internal_io.Io.Button.Right;
    pub const B: u16 = internal_io.Io.Button.B;
    pub const C: u16 = internal_io.Io.Button.C;
    pub const A: u16 = internal_io.Io.Button.A;
    pub const Start: u16 = internal_io.Io.Button.Start;
    pub const X: u16 = internal_io.Io.Button.X;
    pub const Y: u16 = internal_io.Io.Button.Y;
    pub const Z: u16 = internal_io.Io.Button.Z;
    pub const Mode: u16 = internal_io.Io.Button.Mode;
};

pub const ControllerIo = struct {
    handle: *State,

    pub fn init(allocator: std.mem.Allocator) !ControllerIo {
        const state = try allocator.create(State);
        errdefer allocator.destroy(state);
        state.* = .{};
        return .{ .handle = state };
    }

    pub fn deinit(self: *ControllerIo, allocator: std.mem.Allocator) void {
        allocator.destroy(self.handle);
    }

    pub fn read(self: *ControllerIo, address: u32) u8 {
        return self.handle.io.read(address);
    }

    pub fn write(self: *ControllerIo, address: u32, value: u8) void {
        self.handle.io.write(address, value);
    }

    pub fn tick(self: *ControllerIo, m68k_cycles: u32) void {
        self.handle.io.tick(m68k_cycles);
    }

    pub fn setButton(self: *ControllerIo, port: usize, button: u16, pressed: bool) void {
        self.handle.io.setButton(port, button, pressed);
    }

    pub fn setControllerType(self: *ControllerIo, port: usize, controller_type: ControllerType) void {
        self.handle.io.setControllerType(port, switch (controller_type) {
            .three_button => .three_button,
            .six_button => .six_button,
        });
    }

    pub fn getControllerType(self: *const ControllerIo, port: usize) ControllerType {
        return switch (self.handle.io.getControllerType(port)) {
            .three_button => .three_button,
            .six_button => .six_button,
        };
    }
};
