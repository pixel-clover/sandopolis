const std = @import("std");
const clock = @import("../clock.zig");
const CoreFrameCounters = @import("../performance_profile.zig").CoreFrameCounters;
const AudioTiming = @import("../audio/timing.zig").AudioTiming;
const Vdp = @import("../video/vdp.zig").Vdp;
const Io = @import("../input/io.zig").Io;
const Z80 = @import("../cpu/z80.zig").Z80;

pub const State = struct {
    io_master_remainder: u8 = 0,
    m68k_master_phase: u3 = 0,
    z80_master_phase: u4 = 0,
    z80_master_credit: i64 = 0,
    z80_stall_master_debt: u32 = 0,
    z80_wait_master_cycles: u32 = 0,
    z80_odd_access: bool = false,
    m68k_wait_master_cycles: u32 = 0,

    pub fn pendingM68kWaitMasterCycles(self: *const State) u32 {
        return self.m68k_wait_master_cycles;
    }

    pub fn consumeM68kWaitMasterCycles(self: *State, max_master_cycles: u32) u32 {
        const consumed = @min(max_master_cycles, self.m68k_wait_master_cycles);
        self.m68k_wait_master_cycles -= consumed;
        return consumed;
    }

    pub fn setPendingM68kWaitMasterCycles(self: *State, master_cycles: u32) void {
        self.m68k_wait_master_cycles = master_cycles;
    }
};

pub const View = struct {
    vdp: *Vdp,
    z80: *Z80,
    audio_timing: *AudioTiming,
    io: *Io,
    state: *State,
    active_execution_counters: ?*CoreFrameCounters,
    ensure_z80_host_window_ctx: ?*anyopaque,
    ensure_z80_host_window_fn: *const fn (?*anyopaque) void,
    dma_read_ctx: ?*anyopaque,
    dma_read_word_fn: ?Vdp.DmaReadFn,

    pub fn init(
        vdp: *Vdp,
        z80: *Z80,
        audio_timing: *AudioTiming,
        io: *Io,
        state: *State,
        active_execution_counters: ?*CoreFrameCounters,
        ensure_z80_host_window_ctx: ?*anyopaque,
        ensure_z80_host_window_fn: *const fn (?*anyopaque) void,
        dma_read_ctx: ?*anyopaque,
        dma_read_word_fn: ?Vdp.DmaReadFn,
    ) View {
        return .{
            .vdp = vdp,
            .z80 = z80,
            .audio_timing = audio_timing,
            .io = io,
            .state = state,
            .active_execution_counters = active_execution_counters,
            .ensure_z80_host_window_ctx = ensure_z80_host_window_ctx,
            .ensure_z80_host_window_fn = ensure_z80_host_window_fn,
            .dma_read_ctx = dma_read_ctx,
            .dma_read_word_fn = dma_read_word_fn,
        };
    }

    fn ensureZ80HostWindow(self: *View) void {
        self.ensure_z80_host_window_fn(self.ensure_z80_host_window_ctx);
    }

    fn recordZ80EarlyAdvancedMaster(self: *View, master_cycles: u32, count_toward_z80_credit: bool) void {
        if (master_cycles == 0) return;
        self.advanceNonZ80Master(master_cycles);
        self.state.z80_stall_master_debt += master_cycles;
        if (count_toward_z80_credit) {
            self.state.z80_master_credit += @intCast(master_cycles);
        }
    }

    fn z80ContentionM68kWaitMasterCycles(self: *const View) u32 {
        const wait_m68k_cycles: u32 = if (self.state.m68k_master_phase >= 5) 11 else 10;
        return clock.m68kCyclesToMaster(wait_m68k_cycles);
    }

    pub fn recordZ80M68kBusAccess(self: *View, pre_access_master_cycles: u32) void {
        if (self.state.z80_wait_master_cycles != 0) {
            self.recordZ80EarlyAdvancedMaster(self.state.z80_wait_master_cycles, false);
            self.state.z80_wait_master_cycles = 0;
        }

        self.recordZ80EarlyAdvancedMaster(pre_access_master_cycles, true);

        if (!self.vdp.shouldHaltCpu()) {
            self.state.m68k_wait_master_cycles += self.z80ContentionM68kWaitMasterCycles();
        }

        self.state.z80_wait_master_cycles = 49 + @as(u32, if (self.state.z80_odd_access) 1 else 0);
        self.state.z80_odd_access = !self.state.z80_odd_access;
    }

    pub fn recordZ80M68kBusAccesses(self: *View, access_count: u32) void {
        var remaining = access_count;
        while (remaining > 0) : (remaining -= 1) {
            self.recordZ80M68kBusAccess(0);
        }
    }

    fn advanceNonZ80Master(self: *View, master_cycles: u32) void {
        if (master_cycles == 0) return;

        self.vdp.step(master_cycles);
        self.audio_timing.consumeMaster(master_cycles);

        const m68k_div: u32 = clock.m68k_divider;
        const z80_div: u32 = clock.z80_divider;

        var m68k_phase = @as(u32, self.state.m68k_master_phase) + (master_cycles % m68k_div);
        if (m68k_phase >= m68k_div) m68k_phase -= m68k_div;
        self.state.m68k_master_phase = @intCast(m68k_phase);

        var z80_phase = @as(u32, self.state.z80_master_phase) + (master_cycles % z80_div);
        if (z80_phase >= z80_div) z80_phase -= z80_div;
        self.state.z80_master_phase = @intCast(z80_phase);

        const io_total = @as(u32, self.state.io_master_remainder) + master_cycles;
        self.io.tick(io_total / m68k_div);
        self.state.io_master_remainder = @intCast(io_total % m68k_div);

        self.vdp.progressTransfers(master_cycles, self.dma_read_ctx, self.dma_read_word_fn);
    }

    pub fn noteZ80RunnableStateTransition(self: *View, was_can_run: bool) void {
        const can_run = self.z80.canRun();
        if (was_can_run == can_run) return;

        if (!can_run) {
            self.state.z80_wait_master_cycles = 0;
            return;
        }

        self.state.z80_master_credit = self.state.z80_master_phase;
    }

    pub fn stepMasterEarly(self: *View, master_cycles: u32) void {
        if (master_cycles == 0) return;

        self.stepMaster(master_cycles);
        self.state.z80_stall_master_debt += master_cycles;
    }

    pub fn stepMaster(self: *View, master_cycles: u32) void {
        self.ensureZ80HostWindow();
        var remaining = master_cycles;

        while (true) {
            if (self.state.z80_stall_master_debt != 0) {
                const consumed = @min(remaining, self.state.z80_stall_master_debt);
                self.state.z80_stall_master_debt -= consumed;
                remaining -= consumed;
                if (remaining == 0) return;
                continue;
            }

            if (!self.z80.canRun()) {
                if (remaining != 0) self.advanceNonZ80Master(remaining);
                return;
            }

            if (self.state.z80_wait_master_cycles != 0) {
                if (remaining == 0) return;
                const stalled_master = @min(remaining, self.state.z80_wait_master_cycles);
                self.state.z80_wait_master_cycles -= stalled_master;
                self.advanceNonZ80Master(stalled_master);
                remaining -= stalled_master;
                continue;
            }

            const instruction_threshold = @as(i64, clock.z80_divider);
            if (self.state.z80_master_credit < instruction_threshold) {
                if (remaining == 0) return;
                const needed_master: u32 = @intCast(instruction_threshold - self.state.z80_master_credit);
                const chunk = @min(remaining, needed_master);
                self.advanceNonZ80Master(chunk);
                self.state.z80_master_credit += @intCast(chunk);
                remaining -= chunk;
                continue;
            }

            self.z80.setAudioMasterOffset(self.audio_timing.pending_master_cycles);
            const instruction_cycles = self.z80.stepInstruction();
            if (instruction_cycles == 0) {
                if (remaining != 0) self.advanceNonZ80Master(remaining);
                return;
            }
            if (self.active_execution_counters) |counters| counters.z80_instructions += 1;

            self.state.z80_master_credit -= @as(i64, instruction_cycles) * clock.z80_divider;
            _ = self.z80.take68kBusAccessCount();
        }
    }
};

test "z80 timing keeps only the final pending wait after consecutive 68k bus accesses" {
    const testing = std.testing;

    const TestHooks = struct {
        fn ensureZ80HostWindow(_: ?*anyopaque) void {}
    };

    var vdp = Vdp.init();
    var z80 = Z80.init();
    defer z80.deinit();
    var audio_timing: AudioTiming = .{};
    var io = Io.init();
    var state: State = .{};

    var view = View.init(
        &vdp,
        &z80,
        &audio_timing,
        &io,
        &state,
        null,
        null,
        TestHooks.ensureZ80HostWindow,
        null,
        null,
    );

    view.recordZ80M68kBusAccesses(2);

    try testing.expectEqual(@as(u32, 49), state.z80_stall_master_debt);
    try testing.expectEqual(@as(u32, 50), state.z80_wait_master_cycles);
    try testing.expectEqual(@as(u32, 49), audio_timing.pending_master_cycles);
    try testing.expectEqual(clock.m68kCyclesToMaster(20), state.m68k_wait_master_cycles);
}

test "z80 timing reevaluates vdp dma halt state between consecutive 68k bus accesses" {
    const testing = std.testing;

    const TestHooks = struct {
        fn ensureZ80HostWindow(_: ?*anyopaque) void {}

        fn dmaReadWord(_: ?*anyopaque, _: u32) u16 {
            return 0xABCD;
        }
    };

    var vdp = Vdp.init();
    var z80 = Z80.init();
    defer z80.deinit();
    var audio_timing: AudioTiming = .{};
    var io = Io.init();
    var state: State = .{};

    var view = View.init(
        &vdp,
        &z80,
        &audio_timing,
        &io,
        &state,
        null,
        null,
        TestHooks.ensureZ80HostWindow,
        null,
        TestHooks.dmaReadWord,
    );

    vdp.regs[12] = 0x81;
    vdp.regs[15] = 2;
    vdp.code = 0x1;
    vdp.addr = 0x0000;
    vdp.dma_active = true;
    vdp.dma_fill = false;
    vdp.dma_copy = false;
    vdp.dma_source_addr = 0x00E0_0000;
    vdp.dma_length = 1;
    vdp.dma_remaining = 1;
    vdp.dma_start_delay_slots = 0;
    vdp.transfer_line_master_cycle = @intCast(vdp.accessSlotCycles() - 1);

    view.recordZ80M68kBusAccesses(2);

    const expected_wait = if (vdp.shouldHaltCpu()) @as(u32, 0) else clock.m68kCyclesToMaster(10);
    try testing.expectEqual(expected_wait, state.m68k_wait_master_cycles);
    try testing.expectEqual(@as(u32, 50), state.z80_wait_master_cycles);
    try testing.expectEqual(@as(u32, 49), audio_timing.pending_master_cycles);
}

test "z80 timing rounds m68k contention to the current m68k phase" {
    const testing = std.testing;

    const TestHooks = struct {
        fn ensureZ80HostWindow(_: ?*anyopaque) void {}
    };

    var vdp = Vdp.init();
    var z80 = Z80.init();
    defer z80.deinit();
    var audio_timing: AudioTiming = .{};
    var io = Io.init();
    var state: State = .{};

    var view = View.init(
        &vdp,
        &z80,
        &audio_timing,
        &io,
        &state,
        null,
        null,
        TestHooks.ensureZ80HostWindow,
        null,
        null,
    );

    state.m68k_master_phase = 4;
    view.recordZ80M68kBusAccess(0);
    try testing.expectEqual(clock.m68kCyclesToMaster(10), state.m68k_wait_master_cycles);

    state = .{ .m68k_master_phase = 4 };
    audio_timing = .{};
    view = View.init(
        &vdp,
        &z80,
        &audio_timing,
        &io,
        &state,
        null,
        null,
        TestHooks.ensureZ80HostWindow,
        null,
        null,
    );

    view.recordZ80M68kBusAccess(1);
    try testing.expectEqual(clock.m68kCyclesToMaster(11), state.m68k_wait_master_cycles);
}

test "z80 timing carries instruction overshoot across stepMaster slices" {
    const testing = std.testing;

    const TestHooks = struct {
        fn ensureZ80HostWindow(_: ?*anyopaque) void {}
    };

    var vdp = Vdp.init();
    var z80 = Z80.init();
    defer z80.deinit();
    var audio_timing: AudioTiming = .{};
    var io = Io.init();
    var state: State = .{};

    var view = View.init(
        &vdp,
        &z80,
        &audio_timing,
        &io,
        &state,
        null,
        null,
        TestHooks.ensureZ80HostWindow,
        null,
        null,
    );

    z80.reset();
    z80.writeByte(0x0000, 0x00);
    z80.writeByte(0x0001, 0x00);

    view.stepMaster(clock.z80_divider);
    try testing.expectEqual(@as(u16, 0x0001), z80.getPc());
    try testing.expectEqual(@as(i64, -45), state.z80_master_credit);

    view.stepMaster(45);
    try testing.expectEqual(@as(u16, 0x0001), z80.getPc());
    try testing.expectEqual(@as(i64, 0), state.z80_master_credit);

    view.stepMaster(clock.z80_divider);
    try testing.expectEqual(@as(u16, 0x0002), z80.getPc());
    try testing.expectEqual(@as(i64, -45), state.z80_master_credit);
}

test "z80 timing resumes on the current 15-master phase after control-line release" {
    const testing = std.testing;

    const TestHooks = struct {
        fn ensureZ80HostWindow(_: ?*anyopaque) void {}
    };

    var vdp = Vdp.init();
    var z80 = Z80.init();
    defer z80.deinit();
    var audio_timing: AudioTiming = .{};
    var io = Io.init();
    var state: State = .{ .z80_master_phase = 14 };

    var view = View.init(
        &vdp,
        &z80,
        &audio_timing,
        &io,
        &state,
        null,
        null,
        TestHooks.ensureZ80HostWindow,
        null,
        null,
    );

    z80.reset();
    z80.setResetLineAsserted(true);
    z80.writeByte(0x0000, 0x00);

    view.noteZ80RunnableStateTransition(true);
    try testing.expectEqual(@as(u32, 0), z80.stepInstruction());

    const was_can_run = z80.canRun();
    z80.setResetLineAsserted(false);
    view.noteZ80RunnableStateTransition(was_can_run);

    view.stepMaster(1);
    try testing.expectEqual(@as(u16, 0x0001), z80.getPc());
}
