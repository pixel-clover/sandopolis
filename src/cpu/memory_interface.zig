const std = @import("std");
const runtime_state = @import("runtime_state.zig");

pub const MemoryInterface = struct {
    ctx: ?*anyopaque,
    read8Fn: *const fn (?*anyopaque, u32) u8,
    read16Fn: *const fn (?*anyopaque, u32) u16,
    read32Fn: *const fn (?*anyopaque, u32) u32,
    write8Fn: *const fn (?*anyopaque, u32, u8) void,
    write16Fn: *const fn (?*anyopaque, u32, u16) void,
    write32Fn: *const fn (?*anyopaque, u32, u32) void,
    m68kAccessWaitMasterCyclesFn: *const fn (?*anyopaque, u32, u8) u32,
    dataPortReadWaitMasterCyclesFn: *const fn (?*anyopaque) u32,
    reserveDataPortWriteWaitMasterCyclesFn: *const fn (?*anyopaque) u32,
    controlPortWriteWaitMasterCyclesFn: *const fn (?*anyopaque) u32,
    shouldHaltCpuFn: *const fn (?*anyopaque) bool,
    projectedDmaWaitMasterCyclesFn: *const fn (?*anyopaque, u32) u32,
    setCpuRuntimeStateFn: *const fn (?*anyopaque, runtime_state.RuntimeState) void,
    clearCpuRuntimeStateFn: *const fn (?*anyopaque) void,
    notifyBusAccessFn: *const fn (?*anyopaque, u32) void,

    pub fn bind(comptime Context: type, ctx: *Context) MemoryInterface {
        return .{
            .ctx = ctx,
            .read8Fn = struct {
                fn call(raw_ctx: ?*anyopaque, address: u32) u8 {
                    const self: *Context = @ptrCast(@alignCast(raw_ctx orelse unreachable));
                    return self.read8(address);
                }
            }.call,
            .read16Fn = struct {
                fn call(raw_ctx: ?*anyopaque, address: u32) u16 {
                    const self: *Context = @ptrCast(@alignCast(raw_ctx orelse unreachable));
                    return self.read16(address);
                }
            }.call,
            .read32Fn = struct {
                fn call(raw_ctx: ?*anyopaque, address: u32) u32 {
                    const self: *Context = @ptrCast(@alignCast(raw_ctx orelse unreachable));
                    return self.read32(address);
                }
            }.call,
            .write8Fn = struct {
                fn call(raw_ctx: ?*anyopaque, address: u32, value: u8) void {
                    const self: *Context = @ptrCast(@alignCast(raw_ctx orelse unreachable));
                    self.write8(address, value);
                }
            }.call,
            .write16Fn = struct {
                fn call(raw_ctx: ?*anyopaque, address: u32, value: u16) void {
                    const self: *Context = @ptrCast(@alignCast(raw_ctx orelse unreachable));
                    self.write16(address, value);
                }
            }.call,
            .write32Fn = struct {
                fn call(raw_ctx: ?*anyopaque, address: u32, value: u32) void {
                    const self: *Context = @ptrCast(@alignCast(raw_ctx orelse unreachable));
                    self.write32(address, value);
                }
            }.call,
            .m68kAccessWaitMasterCyclesFn = struct {
                fn call(raw_ctx: ?*anyopaque, address: u32, size_bytes: u8) u32 {
                    const self: *Context = @ptrCast(@alignCast(raw_ctx orelse unreachable));
                    return self.m68kAccessWaitMasterCycles(address, size_bytes);
                }
            }.call,
            .dataPortReadWaitMasterCyclesFn = struct {
                fn call(raw_ctx: ?*anyopaque) u32 {
                    const self: *Context = @ptrCast(@alignCast(raw_ctx orelse unreachable));
                    return self.dataPortReadWaitMasterCycles();
                }
            }.call,
            .reserveDataPortWriteWaitMasterCyclesFn = struct {
                fn call(raw_ctx: ?*anyopaque) u32 {
                    const self: *Context = @ptrCast(@alignCast(raw_ctx orelse unreachable));
                    return self.reserveDataPortWriteWaitMasterCycles();
                }
            }.call,
            .controlPortWriteWaitMasterCyclesFn = struct {
                fn call(raw_ctx: ?*anyopaque) u32 {
                    const self: *Context = @ptrCast(@alignCast(raw_ctx orelse unreachable));
                    return self.controlPortWriteWaitMasterCycles();
                }
            }.call,
            .shouldHaltCpuFn = struct {
                fn call(raw_ctx: ?*anyopaque) bool {
                    const self: *Context = @ptrCast(@alignCast(raw_ctx orelse unreachable));
                    return self.shouldHaltCpu();
                }
            }.call,
            .projectedDmaWaitMasterCyclesFn = struct {
                fn call(raw_ctx: ?*anyopaque, elapsed: u32) u32 {
                    const self: *Context = @ptrCast(@alignCast(raw_ctx orelse unreachable));
                    return self.projectedDmaWaitMasterCycles(elapsed);
                }
            }.call,
            .setCpuRuntimeStateFn = struct {
                fn call(raw_ctx: ?*anyopaque, state: runtime_state.RuntimeState) void {
                    const self: *Context = @ptrCast(@alignCast(raw_ctx orelse unreachable));
                    self.setCpuRuntimeState(state);
                }
            }.call,
            .clearCpuRuntimeStateFn = struct {
                fn call(raw_ctx: ?*anyopaque) void {
                    const self: *Context = @ptrCast(@alignCast(raw_ctx orelse unreachable));
                    self.clearCpuRuntimeState();
                }
            }.call,
            .notifyBusAccessFn = struct {
                fn call(raw_ctx: ?*anyopaque, delta_master_cycles: u32) void {
                    const self: *Context = @ptrCast(@alignCast(raw_ctx orelse unreachable));
                    self.notifyBusAccess(delta_master_cycles);
                }
            }.call,
        };
    }

    pub fn read8(self: *const MemoryInterface, address: u32) u8 {
        return self.read8Fn(self.ctx, address);
    }

    pub fn read16(self: *const MemoryInterface, address: u32) u16 {
        return self.read16Fn(self.ctx, address);
    }

    pub fn read32(self: *const MemoryInterface, address: u32) u32 {
        return self.read32Fn(self.ctx, address);
    }

    pub fn write8(self: *const MemoryInterface, address: u32, value: u8) void {
        self.write8Fn(self.ctx, address, value);
    }

    pub fn write16(self: *const MemoryInterface, address: u32, value: u16) void {
        self.write16Fn(self.ctx, address, value);
    }

    pub fn write32(self: *const MemoryInterface, address: u32, value: u32) void {
        self.write32Fn(self.ctx, address, value);
    }

    pub fn m68kAccessWaitMasterCycles(self: *const MemoryInterface, address: u32, size_bytes: u8) u32 {
        return self.m68kAccessWaitMasterCyclesFn(self.ctx, address, size_bytes);
    }

    pub fn dataPortReadWaitMasterCycles(self: *const MemoryInterface) u32 {
        return self.dataPortReadWaitMasterCyclesFn(self.ctx);
    }

    pub fn reserveDataPortWriteWaitMasterCycles(self: *const MemoryInterface) u32 {
        return self.reserveDataPortWriteWaitMasterCyclesFn(self.ctx);
    }

    pub fn controlPortWriteWaitMasterCycles(self: *const MemoryInterface) u32 {
        return self.controlPortWriteWaitMasterCyclesFn(self.ctx);
    }

    pub fn shouldHaltCpu(self: *const MemoryInterface) bool {
        return self.shouldHaltCpuFn(self.ctx);
    }

    pub fn projectedDmaWaitMasterCycles(self: *const MemoryInterface, elapsed: u32) u32 {
        return self.projectedDmaWaitMasterCyclesFn(self.ctx, elapsed);
    }

    pub fn setCpuRuntimeState(self: *const MemoryInterface, state: runtime_state.RuntimeState) void {
        self.setCpuRuntimeStateFn(self.ctx, state);
    }

    pub fn clearCpuRuntimeState(self: *const MemoryInterface) void {
        self.clearCpuRuntimeStateFn(self.ctx);
    }

    pub fn notifyBusAccess(self: *const MemoryInterface, delta_master_cycles: u32) void {
        self.notifyBusAccessFn(self.ctx, delta_master_cycles);
    }
};

test "memory interface bind forwards reads writes waits and runtime hooks" {
    const testing = std.testing;

    const CallbackCtx = struct {
        opcode: u16,

        fn currentOpcode(ctx: ?*anyopaque) u16 {
            const self: *const @This() = @ptrCast(@alignCast(ctx orelse unreachable));
            return self.opcode;
        }

        fn clearInterrupt(_: ?*anyopaque) void {}
    };

    const Probe = struct {
        runtime: runtime_state.RuntimeState = .{},
        last_write_address: u32 = 0,
        last_write_value: u32 = 0,

        fn read8(_: *@This(), address: u32) u8 {
            return @truncate(address + 1);
        }

        fn read16(_: *@This(), address: u32) u16 {
            return @truncate(address + 2);
        }

        fn read32(_: *@This(), address: u32) u32 {
            return address + 3;
        }

        fn write8(self: *@This(), address: u32, value: u8) void {
            self.last_write_address = address;
            self.last_write_value = value;
        }

        fn write16(self: *@This(), address: u32, value: u16) void {
            self.last_write_address = address;
            self.last_write_value = value;
        }

        fn write32(self: *@This(), address: u32, value: u32) void {
            self.last_write_address = address;
            self.last_write_value = value;
        }

        fn m68kAccessWaitMasterCycles(_: *@This(), address: u32, size_bytes: u8) u32 {
            return address + size_bytes;
        }

        fn shouldHaltCpu(_: *const @This()) bool {
            return false;
        }

        fn projectedDmaWaitMasterCycles(_: *const @This(), _: u32) u32 {
            return 0;
        }

        fn dataPortReadWaitMasterCycles(_: *@This()) u32 {
            return 11;
        }

        fn reserveDataPortWriteWaitMasterCycles(_: *@This()) u32 {
            return 22;
        }

        fn controlPortWriteWaitMasterCycles(_: *@This()) u32 {
            return 33;
        }

        fn setCpuRuntimeState(self: *@This(), state: runtime_state.RuntimeState) void {
            self.runtime = state;
        }

        fn clearCpuRuntimeState(self: *@This()) void {
            self.runtime.clear();
        }

        fn notifyBusAccess(_: *@This(), _: u32) void {}
    };

    var probe = Probe{};
    var memory = MemoryInterface.bind(Probe, &probe);

    try testing.expectEqual(@as(u8, 0x11), memory.read8(0x10));
    try testing.expectEqual(@as(u16, 0x0012), memory.read16(0x10));
    try testing.expectEqual(@as(u32, 0x00000013), memory.read32(0x10));

    memory.write8(0x20, 0xAB);
    try testing.expectEqual(@as(u32, 0x20), probe.last_write_address);
    try testing.expectEqual(@as(u32, 0xAB), probe.last_write_value);

    memory.write16(0x30, 0xCDEF);
    try testing.expectEqual(@as(u32, 0x30), probe.last_write_address);
    try testing.expectEqual(@as(u32, 0xCDEF), probe.last_write_value);

    memory.write32(0x40, 0x12345678);
    try testing.expectEqual(@as(u32, 0x40), probe.last_write_address);
    try testing.expectEqual(@as(u32, 0x12345678), probe.last_write_value);

    try testing.expectEqual(@as(u32, 0x52), memory.m68kAccessWaitMasterCycles(0x50, 2));
    try testing.expectEqual(@as(u32, 11), memory.dataPortReadWaitMasterCycles());
    try testing.expectEqual(@as(u32, 22), memory.reserveDataPortWriteWaitMasterCycles());
    try testing.expectEqual(@as(u32, 33), memory.controlPortWriteWaitMasterCycles());

    var callback_ctx = CallbackCtx{ .opcode = 0x4E71 };
    memory.setCpuRuntimeState(runtime_state.RuntimeState.init(&callback_ctx, CallbackCtx.currentOpcode, CallbackCtx.clearInterrupt, null, null));
    try testing.expectEqual(@as(u16, 0x4E71), probe.runtime.currentOpcode());

    memory.clearCpuRuntimeState();
    try testing.expectEqual(@as(u16, 0), probe.runtime.currentOpcode());
}
