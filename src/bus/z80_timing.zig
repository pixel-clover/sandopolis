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
    z80_cached_can_run: bool = false,
    m68k_wait_master_cycles: u32 = 0,
    m68k_refresh_counter: u32 = 0,
    z80_dma_halted: bool = false,
    z80_in_burst: bool = false,

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

    pub fn applyRefreshPenalty(self: *State, m68k_cycles: u32, ppc: u32) void {
        self.m68k_refresh_counter += m68k_cycles;
        if (self.m68k_refresh_counter >= clock.refresh_interval) {
            self.m68k_refresh_counter -= clock.refresh_interval;
            const region = (ppc >> 21) & 7;
            const wait = clock.refresh_wait_by_region[region];
            self.m68k_wait_master_cycles += clock.m68kCyclesToMaster(wait);
        }
    }

    pub fn resetRefreshCounter(self: *State) void {
        self.m68k_refresh_counter = 0;
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
        // During deferred Z80 burst execution, VDP/audio/I/O have already
        // been advanced for the full slice — skip to avoid double-counting.
        if (!self.state.z80_in_burst) {
            self.advanceNonZ80Master(master_cycles);
        }
        self.state.z80_stall_master_debt += master_cycles;
        if (count_toward_z80_credit) {
            self.state.z80_master_credit += @intCast(master_cycles);
        }
    }

    /// M68K wait-state penalty when Z80 accesses the 68K bus.
    /// Genesis Plus GX uses: m68k.cycles += (((Z80.cycles % 7) + 72) / 7) * 7
    /// which resolves to 70-77 master cycles depending on Z80 phase alignment.
    /// We approximate this using the Z80's master-clock phase modulo the M68K
    /// divider, matching GPGX's per-access result.
    fn z80ContentionM68kWaitMasterCycles(self: *const View) u32 {
        const z80_phase_in_m68k = @as(u32, self.state.z80_master_phase) % clock.m68k_divider;
        return ((z80_phase_in_m68k + 72) / clock.m68k_divider) * clock.m68k_divider;
    }

    pub fn recordZ80M68kBusAccess(self: *View, pre_access_master_cycles: u32) void {
        if (self.state.z80_wait_master_cycles != 0) {
            self.recordZ80EarlyAdvancedMaster(self.state.z80_wait_master_cycles, false);
            self.state.z80_wait_master_cycles = 0;
        }

        self.recordZ80EarlyAdvancedMaster(pre_access_master_cycles, true);

        if (self.vdp.shouldHaltCpu()) {
            self.state.z80_dma_halted = true;
        } else {
            self.state.m68k_wait_master_cycles += self.z80ContentionM68kWaitMasterCycles();
        }

        // Z80 stalls for 3 Z80 cycles (45 master cycles) per bank access,
        // matching GPGX's `Z80.cycles += (3 * 15)`.  The previous value of
        // 49/50 (alternating) was 4-5 master cycles too high per access,
        // which caused GEMS DAC playback to fall behind its timing budget.
        self.state.z80_wait_master_cycles = 3 * clock.z80_divider;
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
        self.state.z80_cached_can_run = can_run;
        if (was_can_run == can_run) return;

        if (!can_run) {
            // Flush any deferred Z80 credit before the Z80 stops,
            // so it executes all earned cycles under the old state.
            self.flushDeferredZ80();
            self.state.z80_wait_master_cycles = 0;
            return;
        }

        // Align to the next Z80 cycle boundary, matching GPGX's
        // ((cycles + 14) / 15) * 15 rounding.  The Z80 loses 0-14
        // master cycles per BUSREQ/RESET release.  This keeps sound
        // driver timing (especially GEMS DAC playback) in sync.
        self.state.z80_master_credit = 0;
    }

    pub fn refreshZ80CanRunCache(self: *View) void {
        self.state.z80_cached_can_run = self.z80.canRun();
    }

    pub fn stepMasterEarly(self: *View, master_cycles: u32) void {
        if (master_cycles == 0) return;

        self.stepMaster(master_cycles);
        // In the deferred model, stepMaster already accumulated the credit.
        // The stall debt would cancel it out during flushDeferredZ80, preventing
        // the Z80 from executing its earned cycles before a control transition.
        // Skip the debt — the deferred flush handles timing naturally.
    }

    /// Advance Z80 execution for the given master cycles without advancing
    /// VDP, audio, or I/O timing. Uses a temporary credit grant: credit is
    /// added so Z80 can execute, then removed so the scheduler's stepMaster
    /// re-accumulates it normally alongside VDP/audio advancement.
    pub fn runZ80Early(self: *View, delta_master_cycles: u32, elapsed_instruction_master: u32) void {
        if (delta_master_cycles == 0) return;
        // In deferred mode Z80 runs as a burst at end-of-slice.
        if (self.state.z80_in_burst) return;
        if (!self.state.z80_cached_can_run) return;
        if (self.state.z80_dma_halted) return;
        if (self.state.z80_wait_master_cycles != 0) return;

        self.ensureZ80HostWindow();

        self.state.z80_master_credit += @intCast(delta_master_cycles);
        defer self.state.z80_master_credit -= @intCast(delta_master_cycles);

        // The Z80 instructions here execute during the current M68K
        // instruction.  Timestamps use the audio window base plus the
        // M68K instruction's elapsed time at the start of this delta,
        // advancing as Z80 credit is consumed.
        const credit_at_start = self.state.z80_master_credit;
        const window_pos = @as(i64, self.audio_timing.pending_master_cycles) + @as(i64, elapsed_instruction_master);
        const audio_base: u32 = @intCast(@as(u64, @intCast(@max(window_pos - @max(credit_at_start, 0), 0))));

        while (self.state.z80_master_credit >= @as(i64, clock.z80_divider)) {
            if (self.state.z80_wait_master_cycles != 0) break;
            if (self.state.z80_dma_halted) break;

            const consumed = credit_at_start - self.state.z80_master_credit;
            const offset = audio_base + @as(u32, @intCast(@max(consumed, 0)));
            self.z80.setAudioMasterOffset(offset);
            const instruction_cycles = self.z80.stepInstruction();
            if (instruction_cycles == 0) break;
            if (self.active_execution_counters) |counters| counters.z80_instructions += 1;

            self.state.z80_master_credit -= @as(i64, instruction_cycles) * clock.z80_divider;
            _ = self.z80.take68kBusAccessCount();
        }
    }

    /// Advance VDP/audio/I/O and accumulate Z80 credit, deferring Z80
    /// instruction execution until flushDeferredZ80() is called.  This
    /// matches GPGX's per-line burst model where the Z80 runs after the
    /// M68K has finished its scanline work, avoiding race conditions in
    /// Z80 drivers (like SOR's GEMS) that depend on M68K shared-RAM
    /// writes being visible before the Z80 reads them.
    pub fn stepMaster(self: *View, master_cycles: u32) void {
        self.ensureZ80HostWindow();
        var remaining = master_cycles;

        // Consume stall debt first — these cycles were pre-advanced during
        // a Z80 bus access and must be accounted for before new work.
        if (self.state.z80_stall_master_debt != 0) {
            const consumed = @min(remaining, self.state.z80_stall_master_debt);
            self.state.z80_stall_master_debt -= consumed;
            remaining -= consumed;
        }

        if (remaining == 0) return;

        // Advance VDP, audio, I/O, and phase tracking for all remaining.
        self.advanceNonZ80Master(remaining);

        // Accumulate Z80 credit only if Z80 can execute.
        if (self.state.z80_cached_can_run and !self.state.z80_dma_halted) {
            // Consume any pending bank-access wait from the Z80 budget.
            if (self.state.z80_wait_master_cycles != 0) {
                const stalled = @min(remaining, self.state.z80_wait_master_cycles);
                self.state.z80_wait_master_cycles -= stalled;
                remaining -= stalled;
            }
            self.state.z80_master_credit += @intCast(remaining);
        } else if (self.state.z80_dma_halted) {
            // Re-evaluate DMA halt: it may have cleared during
            // advanceNonZ80Master (VDP transfer progression).
            if (!self.vdp.shouldHaltCpu()) {
                self.state.z80_dma_halted = false;
            }
        }
    }

    /// stepMaster + flushDeferredZ80 in one call.  Convenience for tests.
    pub fn stepMasterAndFlush(self: *View, master_cycles: u32) void {
        self.stepMaster(master_cycles);
        self.flushDeferredZ80();
    }

    /// Execute Z80 instructions from accumulated credit (deferred burst).
    /// Called at the end of each runMasterSlice() after all M68K
    /// instructions have completed for the current scheduler segment.
    pub fn flushDeferredZ80(self: *View) void {
        if (!self.state.z80_cached_can_run) return;

        self.ensureZ80HostWindow();
        self.state.z80_in_burst = true;
        defer self.state.z80_in_burst = false;

        const threshold = @as(i64, clock.z80_divider);

        // The Z80 burst replays instructions that should have executed
        // during the slice.  Track a running master-clock offset so each
        // instruction's audio events get timestamps that reflect their
        // actual position within the audio window, not just the end.
        const credit_at_start = self.state.z80_master_credit;
        const window_end = self.audio_timing.pending_master_cycles;
        const burst_base: u32 = if (credit_at_start > 0 and window_end >= @as(u32, @intCast(credit_at_start)))
            window_end - @as(u32, @intCast(credit_at_start))
        else
            window_end;

        while (self.state.z80_master_credit >= threshold) {
            // DMA halt check — Z80 bus access may have triggered DMA.
            if (self.state.z80_dma_halted) {
                if (!self.vdp.shouldHaltCpu()) {
                    self.state.z80_dma_halted = false;
                } else {
                    break;
                }
            }

            // Bank-access stall: consume from credit (no VDP/audio advance
            // needed — those components have already been fully advanced).
            if (self.state.z80_wait_master_cycles != 0) {
                const stalled: i64 = @intCast(@min(
                    self.state.z80_wait_master_cycles,
                    @as(u32, @intCast(@max(self.state.z80_master_credit, 0))),
                ));
                self.state.z80_wait_master_cycles -= @intCast(stalled);
                self.state.z80_master_credit -= stalled;
                continue;
            }

            // Stall debt from recordZ80EarlyAdvancedMaster during burst:
            // consume from credit.
            if (self.state.z80_stall_master_debt != 0) {
                const consumed: i64 = @intCast(@min(
                    self.state.z80_stall_master_debt,
                    @as(u32, @intCast(@max(self.state.z80_master_credit, 0))),
                ));
                self.state.z80_stall_master_debt -= @intCast(consumed);
                self.state.z80_master_credit -= consumed;
                continue;
            }

            // Compute the current Z80 instruction's position within the
            // audio window based on how much credit has been consumed.
            const consumed_credit = credit_at_start - self.state.z80_master_credit;
            const current_offset = burst_base + @as(u32, @intCast(@max(consumed_credit, 0)));
            self.z80.setAudioMasterOffset(current_offset);

            const instruction_cycles = self.z80.stepInstruction();
            if (instruction_cycles == 0) break;
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

    // First access: stall_debt = 45, wait = 45 (flushed by second access)
    // Second access: stall_debt already consumed, new wait = 45
    try testing.expectEqual(@as(u32, 45), state.z80_stall_master_debt);
    try testing.expectEqual(@as(u32, 45), state.z80_wait_master_cycles);
    try testing.expectEqual(@as(u32, 45), audio_timing.pending_master_cycles);
    // Two accesses at z80_phase=0: ((0 + 72) / 7) * 7 = 70 each → 140 total
    try testing.expectEqual(@as(u32, 140), state.m68k_wait_master_cycles);
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
    try testing.expectEqual(@as(u32, 45), state.z80_wait_master_cycles);
    try testing.expectEqual(@as(u32, 45), audio_timing.pending_master_cycles);
}

test "z80 timing rounds m68k contention based on z80 phase within m68k cycle" {
    const testing = std.testing;

    const TestHooks = struct {
        fn ensureZ80HostWindow(_: ?*anyopaque) void {}
    };

    var vdp = Vdp.init();
    var z80 = Z80.init();
    defer z80.deinit();
    var audio_timing: AudioTiming = .{};
    var io = Io.init();

    // Z80 phase 0 mod 7 = 0: ((0+72)/7)*7 = 70 master cycles
    var state: State = .{ .z80_master_phase = 0 };
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

    view.recordZ80M68kBusAccess(0);
    try testing.expectEqual(@as(u32, 70), state.m68k_wait_master_cycles);

    // Z80 phase 5 mod 7 = 5: ((5+72)/7)*7 = 77 master cycles
    state = .{ .z80_master_phase = 5 };
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

    view.recordZ80M68kBusAccess(0);
    try testing.expectEqual(@as(u32, 77), state.m68k_wait_master_cycles);

    // Z80 phase 13 mod 7 = 6: ((6+72)/7)*7 = 77 master cycles
    state = .{ .z80_master_phase = 13 };
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

    view.recordZ80M68kBusAccess(0);
    try testing.expectEqual(@as(u32, 77), state.m68k_wait_master_cycles);
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
    view.refreshZ80CanRunCache();
    z80.writeByte(0x0000, 0x00);
    z80.writeByte(0x0001, 0x00);

    view.stepMasterAndFlush(clock.z80_divider);
    try testing.expectEqual(@as(u16, 0x0001), z80.getPc());
    try testing.expectEqual(@as(i64, -45), state.z80_master_credit);

    view.stepMasterAndFlush(45);
    try testing.expectEqual(@as(u16, 0x0001), z80.getPc());
    try testing.expectEqual(@as(i64, 0), state.z80_master_credit);

    view.stepMasterAndFlush(clock.z80_divider);
    try testing.expectEqual(@as(u16, 0x0002), z80.getPc());
    try testing.expectEqual(@as(i64, -45), state.z80_master_credit);
}

test "z80 timing aligns to next 15-cycle boundary on control-line release" {
    // GPGX rounds Z80.cycles up to the next 15-cycle boundary when
    // BUSREQ or RESET is released: Z80.cycles = ((cycles+14)/15)*15.
    // This means the Z80 loses 0-14 cycles per release event. Sandopolis
    // must match this to keep Z80 sound driver timing in sync with GPGX.
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

    // With GPGX-style alignment, phase=14 rounds up to 15, so the Z80
    // gets 0 initial credit.  One more master cycle is not enough to
    // reach a full 15-cycle Z80 instruction.
    view.stepMasterAndFlush(1);
    try testing.expectEqual(@as(u16, 0x0000), z80.getPc());

    // After 14 more master cycles (total 15 since release), the Z80
    // should have enough credit for one instruction.
    view.stepMasterAndFlush(14);
    try testing.expectEqual(@as(u16, 0x0001), z80.getPc());
}
