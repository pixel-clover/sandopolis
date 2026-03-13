const std = @import("std");
const clock = @import("../clock.zig");
const MemoryInterface = @import("memory_interface.zig").MemoryInterface;
const runtime_state = @import("runtime_state.zig");
const CoreFrameCounters = @import("../performance_profile.zig").CoreFrameCounters;
const SchedulerCpu = @import("../scheduler/runtime.zig").SchedulerCpu;

const c = @cImport({
    @cInclude("disasm.h");
    @cInclude("m68k.h");
});

var fallback_memory = [_]u8{0} ** 8;

const DisasmCpu = struct {
    core: c.M68kCpu,
    memory: *MemoryInterface,
};

fn isVdpDataPortAddress(address: u32) bool {
    const addr = address & 0xFFFFFF;
    return addr >= 0xC00000 and addr <= 0xDFFFFF and (addr & 0x1F) < 0x04;
}

fn isVdpControlPortAddress(address: u32) bool {
    const addr = address & 0xFFFFFF;
    const port = addr & 0x1F;
    return addr >= 0xC00000 and addr <= 0xDFFFFF and port >= 0x04 and port < 0x08;
}

fn ownerFromCore(core: ?*c.M68kCpu) ?*Cpu {
    const core_ptr = core orelse return null;
    return @fieldParentPtr("core", core_ptr);
}

fn disasmMemoryFromCore(core: ?*c.M68kCpu) ?*MemoryInterface {
    const core_ptr = core orelse return null;
    const shadow: *const DisasmCpu = @fieldParentPtr("core", core_ptr);
    return shadow.memory;
}

fn cpuRead8(core: ?*c.M68kCpu, address: c.u32) callconv(.c) c.u8 {
    const cpu = ownerFromCore(core) orelse return 0;
    const memory = cpu.active_memory orelse return 0;
    cpu.noteBusAccessWait(memory, address, 1, false);
    return @intCast(memory.read8(address));
}

fn cpuRead16(core: ?*c.M68kCpu, address: c.u32) callconv(.c) c.u16 {
    const cpu = ownerFromCore(core) orelse return 0;
    const memory = cpu.active_memory orelse return 0;
    cpu.noteBusAccessWait(memory, address, 2, false);
    return @intCast(memory.read16(address));
}

fn cpuRead32(core: ?*c.M68kCpu, address: c.u32) callconv(.c) c.u32 {
    const cpu = ownerFromCore(core) orelse return 0;
    const memory = cpu.active_memory orelse return 0;
    cpu.noteBusAccessWait(memory, address, 4, false);
    return @intCast(memory.read32(address));
}

fn cpuWrite8(core: ?*c.M68kCpu, address: c.u32, value: c.u8) callconv(.c) void {
    const cpu = ownerFromCore(core) orelse return;
    const memory = cpu.active_memory orelse return;
    cpu.noteBusAccessWait(memory, address, 1, true);
    memory.write8(address, value);
}

fn cpuWrite16(core: ?*c.M68kCpu, address: c.u32, value: c.u16) callconv(.c) void {
    const cpu = ownerFromCore(core) orelse return;
    const memory = cpu.active_memory orelse return;
    cpu.noteBusAccessWait(memory, address, 2, true);
    memory.write16(address, value);
}

fn cpuWrite32(core: ?*c.M68kCpu, address: c.u32, value: c.u32) callconv(.c) void {
    const cpu = ownerFromCore(core) orelse return;
    const memory = cpu.active_memory orelse return;
    cpu.noteBusAccessWait(memory, address, 4, true);
    if (isVdpDataPortAddress(address)) {
        memory.write16(address, @intCast((value >> 16) & 0xFFFF));
        memory.write16(address + 2, @intCast(value & 0xFFFF));
        return;
    }

    memory.write32(address, value);
}

fn cpuDisasmRead8(core: ?*c.M68kCpu, address: c.u32) callconv(.c) c.u8 {
    const memory = disasmMemoryFromCore(core) orelse return 0;
    return @intCast(memory.read8(address));
}

fn cpuDisasmRead16(core: ?*c.M68kCpu, address: c.u32) callconv(.c) c.u16 {
    const memory = disasmMemoryFromCore(core) orelse return 0;
    return @intCast(memory.read16(address));
}

fn cpuDisasmRead32(core: ?*c.M68kCpu, address: c.u32) callconv(.c) c.u32 {
    const memory = disasmMemoryFromCore(core) orelse return 0;
    return @intCast(memory.read32(address));
}

fn cpuIntAck(_: ?*c.M68kCpu, _: c_int) callconv(.c) c_int {
    return -1;
}

pub const Cpu = struct {
    const default_stack_pointer: u32 = 0x00FF_FE00;
    const default_program_counter: u32 = 0x0000_0200;

    pub const State = struct {
        d_regs: [8]u32,
        a_regs: [8]u32,
        pc: u32,
        ppc: u32,
        sr: u16,
        ir: u16,
        irq_level: i32,
        usp: u32,
        ssp: u32,
        stopped: bool,
        trace_pending: bool,
        exception_thrown: i32,
        in_address_error: bool,
        in_bus_error: bool,
        fault_address: u32,
        fault_ir: u16,
        fault_ssw: u16,
        fault_program_access: bool,
        fault_valid: bool,
        vbr: u32,
        sfc: u32,
        dfc: u32,
        target_cycles: i32,
        cycles_remaining: i32,
        cycles: u64,
        halted: bool,
        pending_wait_cycles: u32,
        pending_wait_master_cycles: u32,
    };

    pub const WaitAccounting = struct {
        m68k_cycles: u32 = 0,
        master_cycles: u32 = 0,
    };

    pub const InstructionStep = struct {
        m68k_cycles: u32,
        wait: WaitAccounting,
    };

    core: c.M68kCpu,
    cycles: u64,
    halted: bool,
    pending_wait_cycles: u32,
    pending_wait_master_cycles: u32,
    active_memory: ?*MemoryInterface,
    active_execution_counters: ?*CoreFrameCounters,

    pub var trace_enabled: bool = false;

    pub fn init() Cpu {
        var self = Cpu{
            .core = std.mem.zeroes(c.M68kCpu),
            .cycles = 0,
            .halted = false,
            .pending_wait_cycles = 0,
            .pending_wait_master_cycles = 0,
            .active_memory = null,
            .active_execution_counters = null,
        };

        c.m68k_init(&self.core, &fallback_memory[0], fallback_memory.len);
        c.m68k_set_read8_callback(&self.core, cpuRead8);
        c.m68k_set_read16_callback(&self.core, cpuRead16);
        c.m68k_set_read32_callback(&self.core, cpuRead32);
        c.m68k_set_write8_callback(&self.core, cpuWrite8);
        c.m68k_set_write16_callback(&self.core, cpuWrite16);
        c.m68k_set_write32_callback(&self.core, cpuWrite32);
        c.m68k_set_int_ack_callback(&self.core, cpuIntAck);

        return self;
    }

    pub fn clone(self: *const Cpu) Cpu {
        var copy = Cpu.init();
        copy.core = self.core;
        copy.cycles = self.cycles;
        copy.halted = self.halted;
        copy.pending_wait_cycles = self.pending_wait_cycles;
        copy.pending_wait_master_cycles = self.pending_wait_master_cycles;
        copy.active_memory = null;
        copy.active_execution_counters = null;
        copy.core.fault_trap_active = false;
        copy.core.fault_trap = std.mem.zeroes(@TypeOf(copy.core.fault_trap));
        return copy;
    }

    pub fn captureState(self: *const Cpu) State {
        var state: State = undefined;

        for (0..state.d_regs.len) |i| {
            state.d_regs[i] = self.core.d_regs[i].l;
            state.a_regs[i] = self.core.a_regs[i].l;
        }

        state.pc = self.core.pc;
        state.ppc = self.core.ppc;
        state.sr = self.core.sr;
        state.ir = self.core.ir;
        state.irq_level = self.core.irq_level;
        state.usp = self.core.usp;
        state.ssp = self.core.ssp;
        state.stopped = self.core.stopped;
        state.trace_pending = self.core.trace_pending;
        state.exception_thrown = self.core.exception_thrown;
        state.in_address_error = self.core.in_address_error;
        state.in_bus_error = self.core.in_bus_error;
        state.fault_address = self.core.fault_address;
        state.fault_ir = self.core.fault_ir;
        state.fault_ssw = self.core.fault_ssw;
        state.fault_program_access = self.core.fault_program_access;
        state.fault_valid = self.core.fault_valid;
        state.vbr = self.core.vbr;
        state.sfc = self.core.sfc;
        state.dfc = self.core.dfc;
        state.target_cycles = self.core.target_cycles;
        state.cycles_remaining = self.core.cycles_remaining;
        state.cycles = self.cycles;
        state.halted = self.halted;
        state.pending_wait_cycles = self.pending_wait_cycles;
        state.pending_wait_master_cycles = self.pending_wait_master_cycles;

        return state;
    }

    pub fn restoreState(self: *Cpu, state: *const State) void {
        for (0..state.d_regs.len) |i| {
            self.core.d_regs[i].l = state.d_regs[i];
            self.core.a_regs[i].l = state.a_regs[i];
        }

        self.core.pc = state.pc;
        self.core.ppc = state.ppc;
        self.core.sr = state.sr;
        self.core.ir = state.ir;
        self.core.irq_level = @intCast(state.irq_level);
        self.core.usp = state.usp;
        self.core.ssp = state.ssp;
        self.core.stopped = state.stopped;
        self.core.trace_pending = state.trace_pending;
        self.core.exception_thrown = @intCast(state.exception_thrown);
        self.core.in_address_error = state.in_address_error;
        self.core.in_bus_error = state.in_bus_error;
        self.core.fault_address = state.fault_address;
        self.core.fault_ir = state.fault_ir;
        self.core.fault_ssw = state.fault_ssw;
        self.core.fault_program_access = state.fault_program_access;
        self.core.fault_valid = state.fault_valid;
        self.core.fault_trap_active = false;
        self.core.fault_trap = std.mem.zeroes(@TypeOf(self.core.fault_trap));
        self.core.vbr = state.vbr;
        self.core.sfc = state.sfc;
        self.core.dfc = state.dfc;
        self.core.target_cycles = @intCast(state.target_cycles);
        self.core.cycles_remaining = @intCast(state.cycles_remaining);
        self.cycles = state.cycles;
        self.halted = state.halted;
        self.pending_wait_cycles = state.pending_wait_cycles;
        self.pending_wait_master_cycles = state.pending_wait_master_cycles;
        self.active_memory = null;
    }

    fn currentOpcodeFromCpu(ctx: ?*anyopaque) u16 {
        const self: *Cpu = @ptrCast(@alignCast(ctx orelse return 0));
        return self.core.ir;
    }

    fn clearInterruptFromCpu(ctx: ?*anyopaque) void {
        const self: *Cpu = @ptrCast(@alignCast(ctx orelse return));
        self.clearInterrupt();
    }

    fn runtimeState(self: *Cpu) runtime_state.RuntimeState {
        return runtime_state.RuntimeState.init(self, currentOpcodeFromCpu, clearInterruptFromCpu);
    }

    fn beginExecution(self: *Cpu, memory: *MemoryInterface) void {
        self.active_memory = memory;
        memory.setCpuRuntimeState(self.runtimeState());
    }

    fn endExecution(self: *Cpu) void {
        const memory = self.active_memory orelse return;
        memory.clearCpuRuntimeState();
        self.active_memory = null;
    }

    pub fn reset(self: *Cpu, memory: *MemoryInterface) void {
        self.beginExecution(memory);
        defer self.endExecution();
        c.m68k_reset(&self.core);

        // A zero reset SSP is valid on the Genesis: stack accesses wrap onto the
        // 24-bit bus and land at the top of work RAM. Some ROMs rely on that.
        if (self.core.a_regs[7].l > 0x0100_0000) {
            c.m68k_set_ar(&self.core, 7, default_stack_pointer);
            self.core.ssp = default_stack_pointer;
        }
        if (self.core.pc == 0 or self.core.pc > 0x0040_0000) {
            c.m68k_set_pc(&self.core, default_program_counter);
        }

        self.cycles = 0;
        self.halted = self.core.stopped;
        self.pending_wait_cycles = 0;
        self.pending_wait_master_cycles = 0;
    }

    pub fn setActiveExecutionCounters(self: *Cpu, counters: ?*CoreFrameCounters) void {
        self.active_execution_counters = counters;
    }

    fn addBusWaitMaster(self: *Cpu, master_cycles: u32) void {
        if (master_cycles == 0) return;

        const extra_cycles = std.math.divCeil(u32, master_cycles, clock.m68k_divider) catch unreachable;
        c.m68k_modify_timeslice(&self.core, @intCast(extra_cycles));
        self.pending_wait_cycles += extra_cycles;
        self.pending_wait_master_cycles += master_cycles;
    }

    pub fn noteBusAccessWait(self: *Cpu, memory: *MemoryInterface, address: u32, size_bytes: u8, is_write: bool) void {
        self.addBusWaitMaster(memory.m68kAccessWaitMasterCycles(address, size_bytes));

        if (!isVdpDataPortAddress(address)) {
            if (is_write and isVdpControlPortAddress(address)) {
                self.addBusWaitMaster(memory.controlPortWriteWaitMasterCycles());
            }
            return;
        }

        if (!is_write) {
            if (size_bytes >= 4) {
                self.addBusWaitMaster(memory.dataPortReadWaitMasterCycles());
                self.addBusWaitMaster(memory.dataPortReadWaitMasterCycles());
                return;
            }

            self.addBusWaitMaster(memory.dataPortReadWaitMasterCycles());
            return;
        }

        if (size_bytes >= 4) {
            self.addBusWaitMaster(memory.reserveDataPortWriteWaitMasterCycles());
            self.addBusWaitMaster(memory.reserveDataPortWriteWaitMasterCycles());
            return;
        }

        self.addBusWaitMaster(memory.reserveDataPortWriteWaitMasterCycles());
    }

    pub fn step(self: *Cpu, memory: *MemoryInterface) void {
        _ = self.stepInstruction(memory);
    }

    pub fn stepInstruction(self: *Cpu, memory: *MemoryInterface) InstructionStep {
        _ = trace_enabled;

        self.beginExecution(memory);
        defer self.endExecution();
        self.pending_wait_cycles = 0;
        self.pending_wait_master_cycles = 0;
        self.core.target_cycles = 0;
        self.core.cycles_remaining = 0;

        c.m68k_step(&self.core);

        const ran_cycles_raw = c.m68k_cycles_run(&self.core);
        const ran_cycles: u32 = if (ran_cycles_raw > 0) @intCast(ran_cycles_raw) else 0;
        self.core.target_cycles = 0;
        self.core.cycles_remaining = 0;
        self.cycles += ran_cycles;
        self.halted = self.core.stopped;
        if (self.active_execution_counters) |counters| counters.m68k_instructions += 1;

        return .{
            .m68k_cycles = ran_cycles,
            .wait = self.takeWaitAccounting(),
        };
    }

    pub fn runCycles(self: *Cpu, memory: *MemoryInterface, budget: u32) u32 {
        if (budget == 0) return 0;

        self.beginExecution(memory);
        defer self.endExecution();
        const ran = c.m68k_execute(&self.core, @intCast(budget));
        const consumed: u32 = if (ran > 0) @intCast(ran) else 0;
        self.cycles += consumed;
        self.halted = self.core.stopped;
        return consumed;
    }

    pub fn schedulerRuntime(self: *Cpu) SchedulerCpu {
        return SchedulerCpu.bind(Cpu, self);
    }

    pub fn takeWaitAccounting(self: *Cpu) WaitAccounting {
        const accounting = WaitAccounting{
            .m68k_cycles = self.pending_wait_cycles,
            .master_cycles = self.pending_wait_master_cycles,
        };
        self.pending_wait_cycles = 0;
        self.pending_wait_master_cycles = 0;
        return accounting;
    }

    pub fn clearInterrupt(self: *Cpu) void {
        self.core.irq_level = 0;
    }

    pub fn requestInterrupt(self: *Cpu, level: u3) void {
        const current: c_int = @intCast(self.core.irq_level);
        const new_level: c_int = @intCast(level);
        if (new_level > current) {
            c.m68k_set_irq(&self.core, new_level);
        }
    }

    pub fn debugDump(self: *const Cpu) void {
        std.debug.print("PC: {X:0>8} SR: {X:0>4} SP: {X:0>8}\n", .{
            @as(u32, self.core.pc),
            @as(u16, self.core.sr),
            @as(u32, self.core.a_regs[7].l),
        });
        for (0..8) |i| {
            std.debug.print("D{d}: {X:0>8} A{d}: {X:0>8}\n", .{
                i,
                @as(u32, self.core.d_regs[i].l),
                i,
                @as(u32, self.core.a_regs[i].l),
            });
        }
    }

    pub fn formatInstruction(self: *const Cpu, memory: *MemoryInterface, pc: u32, buffer: []u8) []const u8 {
        if (buffer.len == 0) return buffer[0..0];

        var shadow = DisasmCpu{
            .core = std.mem.zeroes(c.M68kCpu),
            .memory = memory,
        };
        c.m68k_init(&shadow.core, &fallback_memory[0], fallback_memory.len);
        c.m68k_set_context(&shadow.core, &self.core);
        c.m68k_set_read8_callback(&shadow.core, cpuDisasmRead8);
        c.m68k_set_read16_callback(&shadow.core, cpuDisasmRead16);
        c.m68k_set_read32_callback(&shadow.core, cpuDisasmRead32);

        buffer[0] = 0;
        _ = c.m68k_disasm(&shadow.core, pc, @ptrCast(buffer.ptr), @intCast(buffer.len));
        const len = std.mem.indexOfScalar(u8, buffer, 0) orelse buffer.len;
        return buffer[0..len];
    }

    pub fn formatCurrentInstruction(self: *const Cpu, memory: *MemoryInterface, buffer: []u8) []const u8 {
        return self.formatInstruction(memory, self.core.pc, buffer);
    }

    pub fn debugCurrentInstruction(self: *const Cpu, memory: *MemoryInterface) void {
        var buffer: [128]u8 = undefined;
        const text = self.formatCurrentInstruction(memory, &buffer);
        std.debug.print("68K {X:0>8}: {s}\n", .{ @as(u32, self.core.pc), text });
    }
};
