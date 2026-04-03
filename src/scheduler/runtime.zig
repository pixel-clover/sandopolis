const std = @import("std");
const MemoryInterface = @import("../cpu/memory_interface.zig").MemoryInterface;

pub const WaitAccounting = struct {
    m68k_cycles: u32 = 0,
    master_cycles: u32 = 0,
};

pub const InstructionStep = struct {
    m68k_cycles: u32,
    ppc: u32,
    wait: WaitAccounting,
};

pub const SchedulerBus = struct {
    ctx: ?*anyopaque,
    should_halt_m68k_fn: *const fn (?*anyopaque) bool,
    pending_wait_master_cycles_fn: *const fn (?*anyopaque) u32,
    consume_wait_master_cycles_fn: *const fn (?*anyopaque, u32) u32,
    step_master_fn: *const fn (?*anyopaque, u32) void,
    flush_deferred_z80_fn: *const fn (?*anyopaque) void,
    cpu_memory_fn: *const fn (?*anyopaque) MemoryInterface,
    dma_halt_quantum_fn: *const fn (?*anyopaque) u32,
    dma_refresh_gap_fn: *const fn (?*anyopaque) u32,
    dma_refresh_slot_duration_fn: *const fn (?*anyopaque) u32,
    record_refresh_cycles_fn: *const fn (?*anyopaque, u32, u32) void,
    reset_refresh_counter_fn: *const fn (?*anyopaque) void,

    pub fn bind(comptime Context: type, ctx: *Context) SchedulerBus {
        return .{
            .ctx = ctx,
            .should_halt_m68k_fn = struct {
                fn call(raw_ctx: ?*anyopaque) bool {
                    const self: *Context = @ptrCast(@alignCast(raw_ctx orelse unreachable));
                    return self.shouldHaltM68k();
                }
            }.call,
            .pending_wait_master_cycles_fn = struct {
                fn call(raw_ctx: ?*anyopaque) u32 {
                    const self: *Context = @ptrCast(@alignCast(raw_ctx orelse unreachable));
                    return self.pendingM68kWaitMasterCycles();
                }
            }.call,
            .consume_wait_master_cycles_fn = struct {
                fn call(raw_ctx: ?*anyopaque, max_master_cycles: u32) u32 {
                    const self: *Context = @ptrCast(@alignCast(raw_ctx orelse unreachable));
                    return self.consumeM68kWaitMasterCycles(max_master_cycles);
                }
            }.call,
            .step_master_fn = struct {
                fn call(raw_ctx: ?*anyopaque, master_cycles: u32) void {
                    const self: *Context = @ptrCast(@alignCast(raw_ctx orelse unreachable));
                    self.stepMaster(master_cycles);
                }
            }.call,
            .flush_deferred_z80_fn = struct {
                fn call(raw_ctx: ?*anyopaque) void {
                    const self: *Context = @ptrCast(@alignCast(raw_ctx orelse unreachable));
                    self.flushDeferredZ80();
                }
            }.call,
            .cpu_memory_fn = struct {
                fn call(raw_ctx: ?*anyopaque) MemoryInterface {
                    const self: *Context = @ptrCast(@alignCast(raw_ctx orelse unreachable));
                    return self.cpuMemory();
                }
            }.call,
            .dma_halt_quantum_fn = struct {
                fn call(raw_ctx: ?*anyopaque) u32 {
                    const self: *Context = @ptrCast(@alignCast(raw_ctx orelse unreachable));
                    return self.dmaHaltQuantum();
                }
            }.call,
            .dma_refresh_gap_fn = struct {
                fn call(raw_ctx: ?*anyopaque) u32 {
                    const self: *Context = @ptrCast(@alignCast(raw_ctx orelse unreachable));
                    return self.dmaRefreshGapMasterCycles();
                }
            }.call,
            .dma_refresh_slot_duration_fn = struct {
                fn call(raw_ctx: ?*anyopaque) u32 {
                    const self: *Context = @ptrCast(@alignCast(raw_ctx orelse unreachable));
                    return self.dmaRefreshSlotDuration();
                }
            }.call,
            .record_refresh_cycles_fn = struct {
                fn call(raw_ctx: ?*anyopaque, m68k_cycles: u32, ppc: u32) void {
                    const self: *Context = @ptrCast(@alignCast(raw_ctx orelse unreachable));
                    self.recordRefreshCycles(m68k_cycles, ppc);
                }
            }.call,
            .reset_refresh_counter_fn = struct {
                fn call(raw_ctx: ?*anyopaque) void {
                    const self: *Context = @ptrCast(@alignCast(raw_ctx orelse unreachable));
                    self.resetRefreshCounter();
                }
            }.call,
        };
    }

    pub fn shouldHaltM68k(self: SchedulerBus) bool {
        return self.should_halt_m68k_fn(self.ctx);
    }

    pub fn pendingM68kWaitMasterCycles(self: SchedulerBus) u32 {
        return self.pending_wait_master_cycles_fn(self.ctx);
    }

    pub fn consumeM68kWaitMasterCycles(self: SchedulerBus, max_master_cycles: u32) u32 {
        return self.consume_wait_master_cycles_fn(self.ctx, max_master_cycles);
    }

    pub fn stepMaster(self: SchedulerBus, master_cycles: u32) void {
        self.step_master_fn(self.ctx, master_cycles);
    }

    pub fn flushDeferredZ80(self: SchedulerBus) void {
        self.flush_deferred_z80_fn(self.ctx);
    }

    pub fn cpuMemory(self: SchedulerBus) MemoryInterface {
        return self.cpu_memory_fn(self.ctx);
    }

    pub fn dmaHaltQuantum(self: SchedulerBus) u32 {
        return self.dma_halt_quantum_fn(self.ctx);
    }

    pub fn dmaRefreshGapMasterCycles(self: SchedulerBus) u32 {
        return self.dma_refresh_gap_fn(self.ctx);
    }

    pub fn dmaRefreshSlotDuration(self: SchedulerBus) u32 {
        return self.dma_refresh_slot_duration_fn(self.ctx);
    }

    pub fn recordRefreshCycles(self: SchedulerBus, m68k_cycles: u32, ppc: u32) void {
        self.record_refresh_cycles_fn(self.ctx, m68k_cycles, ppc);
    }

    pub fn resetRefreshCounter(self: SchedulerBus) void {
        self.reset_refresh_counter_fn(self.ctx);
    }
};

pub const SchedulerCpu = struct {
    ctx: ?*anyopaque,
    step_instruction_fn: *const fn (?*anyopaque, *MemoryInterface) InstructionStep,

    pub fn bind(comptime Context: type, ctx: *Context) SchedulerCpu {
        return .{
            .ctx = ctx,
            .step_instruction_fn = struct {
                fn call(raw_ctx: ?*anyopaque, memory: *MemoryInterface) InstructionStep {
                    const self: *Context = @ptrCast(@alignCast(raw_ctx orelse unreachable));
                    const instruction = self.stepInstruction(memory);
                    return .{
                        .m68k_cycles = instruction.m68k_cycles,
                        .ppc = instruction.ppc,
                        .wait = .{
                            .m68k_cycles = instruction.wait.m68k_cycles,
                            .master_cycles = instruction.wait.master_cycles,
                        },
                    };
                }
            }.call,
        };
    }

    pub fn stepInstruction(self: SchedulerCpu, memory: *MemoryInterface) InstructionStep {
        return self.step_instruction_fn(self.ctx, memory);
    }
};

test "scheduler bus bind forwards wait, step, memory, and dma queries" {
    const testing = std.testing;

    const MemoryProbe = struct {
        pub fn read8(_: *@This(), address: u32) u8 {
            return @truncate(address);
        }

        pub fn read16(_: *@This(), address: u32) u16 {
            return @truncate(address);
        }

        pub fn read32(_: *@This(), address: u32) u32 {
            return address;
        }

        pub fn write8(_: *@This(), _: u32, _: u8) void {}
        pub fn write16(_: *@This(), _: u32, _: u16) void {}
        pub fn write32(_: *@This(), _: u32, _: u32) void {}
        pub fn m68kAccessWaitMasterCycles(_: *@This(), _: u32, _: u8) u32 {
            return 0;
        }
        pub fn dataPortReadWaitMasterCycles(_: *@This()) u32 {
            return 0;
        }
        pub fn reserveDataPortWriteWaitMasterCycles(_: *@This()) u32 {
            return 0;
        }
        pub fn controlPortWriteWaitMasterCycles(_: *@This()) u32 {
            return 0;
        }
        pub fn setCpuRuntimeState(_: *@This(), _: @import("../cpu/runtime_state.zig").RuntimeState) void {}
        pub fn clearCpuRuntimeState(_: *@This()) void {}
        pub fn notifyBusAccess(_: *@This(), _: u32) void {}
    };

    const BusProbe = struct {
        halt: bool = true,
        pending_wait: u32 = 99,
        last_step_master: u32 = 0,
        last_consume_max: u32 = 0,
        memory: MemoryProbe = .{},

        fn shouldHaltM68k(self: *@This()) bool {
            return self.halt;
        }

        fn pendingM68kWaitMasterCycles(self: *@This()) u32 {
            return self.pending_wait;
        }

        fn consumeM68kWaitMasterCycles(self: *@This(), max_master_cycles: u32) u32 {
            const consumed = @min(self.pending_wait, max_master_cycles);
            self.pending_wait -= consumed;
            self.last_consume_max = max_master_cycles;
            return consumed;
        }

        fn stepMaster(self: *@This(), master_cycles: u32) void {
            self.last_step_master = master_cycles;
        }

        fn cpuMemory(self: *@This()) MemoryInterface {
            return MemoryInterface.bind(MemoryProbe, &self.memory);
        }

        fn dmaHaltQuantum(_: *@This()) u32 {
            return 17;
        }

        fn dmaRefreshGapMasterCycles(_: *@This()) u32 {
            return 0;
        }
        fn dmaRefreshSlotDuration(_: *@This()) u32 {
            return 16;
        }
        fn flushDeferredZ80(_: *@This()) void {}
        fn recordRefreshCycles(_: *@This(), _: u32, _: u32) void {}
        fn resetRefreshCounter(_: *@This()) void {}
    };

    var probe = BusProbe{};
    const runtime = SchedulerBus.bind(BusProbe, &probe);

    try testing.expect(runtime.shouldHaltM68k());
    try testing.expectEqual(@as(u32, 99), runtime.pendingM68kWaitMasterCycles());
    try testing.expectEqual(@as(u32, 40), runtime.consumeM68kWaitMasterCycles(40));
    try testing.expectEqual(@as(u32, 40), probe.last_consume_max);
    try testing.expectEqual(@as(u32, 59), probe.pending_wait);

    runtime.stepMaster(123);
    try testing.expectEqual(@as(u32, 123), probe.last_step_master);
    try testing.expectEqual(@as(u32, 17), runtime.dmaHaltQuantum());

    var memory = runtime.cpuMemory();
    try testing.expectEqual(@as(u8, 0x2A), memory.read8(0x2A));
}

test "scheduler cpu bind forwards instruction stepping through memory" {
    const testing = std.testing;

    const MemoryProbe = struct {
        pub fn read8(_: *@This(), address: u32) u8 {
            return @truncate(address + 3);
        }

        pub fn read16(_: *@This(), address: u32) u16 {
            return @truncate(address);
        }

        pub fn read32(_: *@This(), address: u32) u32 {
            return address;
        }

        pub fn write8(_: *@This(), _: u32, _: u8) void {}
        pub fn write16(_: *@This(), _: u32, _: u16) void {}
        pub fn write32(_: *@This(), _: u32, _: u32) void {}
        pub fn m68kAccessWaitMasterCycles(_: *@This(), _: u32, _: u8) u32 {
            return 0;
        }
        pub fn dataPortReadWaitMasterCycles(_: *@This()) u32 {
            return 0;
        }
        pub fn reserveDataPortWriteWaitMasterCycles(_: *@This()) u32 {
            return 0;
        }
        pub fn controlPortWriteWaitMasterCycles(_: *@This()) u32 {
            return 0;
        }
        pub fn setCpuRuntimeState(_: *@This(), _: @import("../cpu/runtime_state.zig").RuntimeState) void {}
        pub fn clearCpuRuntimeState(_: *@This()) void {}
        pub fn notifyBusAccess(_: *@This(), _: u32) void {}
    };

    const CpuProbe = struct {
        steps: u32 = 0,

        fn stepInstruction(self: *@This(), memory: *MemoryInterface) InstructionStep {
            self.steps += 1;
            return .{
                .m68k_cycles = memory.read8(0x10),
                .ppc = 0,
                .wait = .{
                    .m68k_cycles = 2,
                    .master_cycles = 6,
                },
            };
        }
    };

    var cpu = CpuProbe{};
    var memory_probe = MemoryProbe{};
    var memory = MemoryInterface.bind(MemoryProbe, &memory_probe);
    const runtime = SchedulerCpu.bind(CpuProbe, &cpu);

    const step = runtime.stepInstruction(&memory);
    try testing.expectEqual(@as(u32, 1), cpu.steps);
    try testing.expectEqual(@as(u32, 0x13), step.m68k_cycles);
    try testing.expectEqual(@as(u32, 2), step.wait.m68k_cycles);
    try testing.expectEqual(@as(u32, 6), step.wait.master_cycles);
}
