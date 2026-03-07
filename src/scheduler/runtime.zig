const MemoryInterface = @import("../cpu/memory_interface.zig").MemoryInterface;

pub const WaitAccounting = struct {
    m68k_cycles: u32 = 0,
    master_cycles: u32 = 0,
};

pub const InstructionStep = struct {
    m68k_cycles: u32,
    wait: WaitAccounting,
};

pub const SchedulerBus = struct {
    ctx: ?*anyopaque,
    should_halt_m68k_fn: *const fn (?*anyopaque) bool,
    pending_wait_master_cycles_fn: *const fn (?*anyopaque) u32,
    consume_wait_master_cycles_fn: *const fn (?*anyopaque, u32) u32,
    step_master_fn: *const fn (?*anyopaque, u32) void,
    cpu_memory_fn: *const fn (?*anyopaque) MemoryInterface,

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

    pub fn cpuMemory(self: SchedulerBus) MemoryInterface {
        return self.cpu_memory_fn(self.ctx);
    }
};

pub const SchedulerCpu = struct {
    ctx: ?*anyopaque,
    step_instruction_fn: *const fn (?*anyopaque, *MemoryInterface) InstructionStep,

    pub fn stepInstruction(self: SchedulerCpu, memory: *MemoryInterface) InstructionStep {
        return self.step_instruction_fn(self.ctx, memory);
    }
};
