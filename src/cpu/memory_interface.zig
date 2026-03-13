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
    setCpuRuntimeStateFn: *const fn (?*anyopaque, runtime_state.RuntimeState) void,
    clearCpuRuntimeStateFn: *const fn (?*anyopaque) void,

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

    pub fn setCpuRuntimeState(self: *const MemoryInterface, state: runtime_state.RuntimeState) void {
        self.setCpuRuntimeStateFn(self.ctx, state);
    }

    pub fn clearCpuRuntimeState(self: *const MemoryInterface) void {
        self.clearCpuRuntimeStateFn(self.ctx);
    }
};
