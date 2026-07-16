const c = @cImport({
    @cInclude("jgz80_bridge.h");
});

const std = @import("std");
const clock = @import("../clock.zig");
const audio_events = @import("../audio/events.zig");

pub const Z80 = struct {
    handle: ?*c.Jgz80Handle,

    // The audio event types are owned by audio/events.zig (both files
    // translate the same C header, so the types are identical); these
    // aliases keep the producer side readable.
    pub const YmWriteEvent = audio_events.YmWriteEvent;
    pub const YmDacSampleEvent = audio_events.YmDacSampleEvent;
    pub const YmResetEvent = audio_events.YmResetEvent;
    pub const PsgCommandEvent = audio_events.PsgCommandEvent;
    pub const AudioOpTraceEntry = c.Jgz80AudioOpTraceEntry;
    pub const InstructionTraceEntry = c.Jgz80InstructionTraceEntry;
    pub const RegisterDump = c.Jgz80RegisterDump;
    pub const State = c.Jgz80State;

    pub const HostReadFn = *const fn (userdata: ?*anyopaque, addr: u32) callconv(.c) u8;
    pub const HostPeekFn = *const fn (userdata: ?*anyopaque, addr: u32) callconv(.c) u8;
    pub const HostWriteFn = *const fn (userdata: ?*anyopaque, addr: u32, val: u8) callconv(.c) void;
    pub const HostM68kBusAccessFn = *const fn (userdata: ?*anyopaque, pre_access_master_cycles: u32) callconv(.c) void;
    pub const HostPortInFn = *const fn (userdata: ?*anyopaque, port: u16) callconv(.c) u8;
    pub const HostPortOutFn = *const fn (userdata: ?*anyopaque, port: u16, val: u8) callconv(.c) void;

    pub fn init() Z80 {
        return .{ .handle = c.jgz80_create() };
    }

    pub fn clone(self: *const Z80) error{OutOfMemory}!Z80 {
        const handle = self.handle orelse return .{ .handle = null };
        return .{
            .handle = c.jgz80_clone(handle) orelse return error.OutOfMemory,
        };
    }

    pub fn captureState(self: *const Z80) State {
        var state = std.mem.zeroes(State);
        if (self.handle) |h| c.jgz80_capture_state(h, &state);
        return state;
    }

    pub fn restoreState(self: *Z80, state: *const State) void {
        if (self.handle) |h| c.jgz80_restore_state(h, state);
    }

    /// State fields that belong to the audio side (YM shadow registers,
    /// timers, event queues, PSG latches) rather than Z80 CPU execution.
    const audio_state_fields = [_][]const u8{
        "audio_master_offset",
        "ym_addr",
        "ym_regs",
        "ym_key_mask",
        "ym_offset_cursor",
        "ym_internal_master_remainder",
        "ym_cycle",
        "ym_busy",
        "ym_busy_cycles_remaining",
        "ym_last_status_read",
        "ym_timer_a_cnt",
        "ym_timer_a_reg",
        "ym_timer_a_load_lock",
        "ym_timer_a_load",
        "ym_timer_a_enable",
        "ym_timer_a_reset",
        "ym_timer_a_load_latch",
        "ym_timer_a_overflow_flag",
        "ym_timer_a_overflow",
        "ym_timer_b_cnt",
        "ym_timer_b_subcnt",
        "ym_timer_b_reg",
        "ym_timer_b_load_lock",
        "ym_timer_b_load",
        "ym_timer_b_enable",
        "ym_timer_b_reset",
        "ym_timer_b_load_latch",
        "ym_timer_b_overflow_flag",
        "ym_timer_b_overflow",
        "audio_event_sequence",
        "ym_write_events",
        "ym_write_write_index",
        "ym_write_read_index",
        "ym_write_count",
        "ym_dac_samples",
        "ym_dac_write_index",
        "ym_dac_read_index",
        "ym_dac_count",
        "ym_reset_events",
        "ym_reset_write_index",
        "ym_reset_read_index",
        "ym_reset_count",
        "psg_commands",
        "psg_command_write_index",
        "psg_command_read_index",
        "psg_command_count",
        "psg_last",
        "psg_tone",
        "psg_volume",
        "psg_noise",
        "psg_latched_channel",
        "psg_latched_is_volume",
    };

    /// Re-apply only the audio-side state from `after`, keeping the current
    /// CPU execution state. Used when the bus rewinds and replays a Z80
    /// control-line window: the CPU re-executes the window, but chip time
    /// and the audio event queues must not advance twice.
    pub fn restoreAudioState(self: *Z80, after: *const State) void {
        var merged = self.captureState();
        inline for (audio_state_fields) |name| {
            @field(merged, name) = @field(after, name);
        }
        self.restoreState(&merged);
    }

    pub fn deinit(self: *Z80) void {
        if (self.handle) |h| {
            c.jgz80_destroy(h);
            self.handle = null;
        }
    }

    pub fn reset(self: *Z80) void {
        if (self.handle) |h| c.jgz80_reset(h);
    }

    pub fn softReset(self: *Z80) void {
        if (self.handle) |h| c.jgz80_soft_reset(h);
    }

    pub fn step(self: *Z80, cycles: u32) void {
        if (self.handle) |h| c.jgz80_step(h, cycles);
    }

    pub fn stepInstruction(self: *Z80) u32 {
        if (self.handle) |h| return c.jgz80_step_one(h);
        return 0;
    }

    pub fn readByte(self: *Z80, addr: u16) u8 {
        if (self.handle) |h| return c.jgz80_read_byte(h, addr);
        return 0;
    }

    pub fn writeByte(self: *Z80, addr: u16, val: u8) void {
        if (self.handle) |h| c.jgz80_write_byte(h, addr, val);
    }

    pub fn setHostCallbacks(
        self: *Z80,
        userdata: ?*anyopaque,
        host_read: HostReadFn,
        host_peek: HostPeekFn,
        host_write: HostWriteFn,
        host_m68k_bus_access: HostM68kBusAccessFn,
    ) void {
        if (self.handle) |h| c.jgz80_set_host_callbacks(h, host_read, host_peek, host_write, host_m68k_bus_access, userdata);
    }

    pub fn setSmsMode(self: *Z80, enabled: bool) void {
        if (self.handle) |h| c.jgz80_set_sms_mode(h, if (enabled) 1 else 0);
    }

    pub fn setPortCallbacks(
        self: *Z80,
        userdata: ?*anyopaque,
        port_in: HostPortInFn,
        port_out: HostPortOutFn,
    ) void {
        if (self.handle) |h| c.jgz80_set_port_callbacks(h, port_in, port_out, userdata);
    }

    pub fn assertNmi(self: *Z80) void {
        if (self.handle) |h| c.jgz80_assert_nmi(h);
    }

    pub fn getBank(self: *const Z80) u16 {
        if (self.handle) |h| return c.jgz80_get_bank(h);
        return 0;
    }

    pub fn getPc(self: *const Z80) u16 {
        if (self.handle) |h| return c.jgz80_get_pc(h);
        return 0;
    }

    pub fn getRegisterDump(self: *const Z80) RegisterDump {
        if (self.handle) |h| return c.jgz80_get_register_dump(h);
        return std.mem.zeroes(RegisterDump);
    }

    pub fn debugDump(self: *const Z80) void {
        const dump = self.getRegisterDump();
        std.debug.print("Z80 PC: {X:0>4} SP: {X:0>4} IX: {X:0>4} IY: {X:0>4} BANK: {X:0>3}\n", .{
            dump.pc,
            dump.sp,
            dump.ix,
            dump.iy,
            self.getBank(),
        });
        std.debug.print("Z80 AF: {X:0>4} BC: {X:0>4} DE: {X:0>4} HL: {X:0>4}\n", .{
            dump.af,
            dump.bc,
            dump.de,
            dump.hl,
        });
        std.debug.print("Z80 AF': {X:0>4} BC': {X:0>4} DE': {X:0>4} HL': {X:0>4}\n", .{
            dump.af_alt,
            dump.bc_alt,
            dump.de_alt,
            dump.hl_alt,
        });
        std.debug.print(
            "Z80 IR: {X:0>4} WZ: {X:0>4} IM: {d} IRQ: {X:0>2} IFF1: {d} IFF2: {d} HALT: {d} BUSREQ: {X:0>4} RESET: {X:0>4}\n",
            .{
                dump.ir,
                dump.wz,
                dump.interrupt_mode,
                dump.irq_data,
                dump.iff1,
                dump.iff2,
                dump.halted,
                self.readBusReq(),
                self.readReset(),
            },
        );
    }

    pub fn take68kBusAccessCount(self: *Z80) u32 {
        if (self.handle) |h| return c.jgz80_take_68k_bus_access_count(h);
        return 0;
    }

    pub fn assertIrq(self: *Z80, data: u8) void {
        if (self.handle) |h| c.jgz80_assert_irq(h, data);
    }

    pub fn clearIrq(self: *Z80) void {
        if (self.handle) |h| c.jgz80_clear_irq(h);
    }

    pub fn getYmRegister(self: *const Z80, port: u1, reg: u8) u8 {
        if (self.handle) |h| return c.jgz80_get_ym_register(h, port, reg);
        return 0;
    }

    pub fn getYmKeyMask(self: *const Z80) u8 {
        if (self.handle) |h| return c.jgz80_get_ym_key_mask(h);
        return 0;
    }

    pub fn pendingYmWriteCount(self: *const Z80) u16 {
        if (self.handle) |h| return c.jgz80_peek_ym_write_count(h);
        return 0;
    }

    pub fn pendingYmDacCount(self: *const Z80) u16 {
        if (self.handle) |h| return c.jgz80_peek_ym_dac_count(h);
        return 0;
    }

    pub fn pendingPsgCommandCount(self: *const Z80) u16 {
        if (self.handle) |h| return c.jgz80_peek_psg_command_count(h);
        return 0;
    }

    pub fn pendingAudioOpTraceCount(self: *const Z80) u16 {
        if (self.handle) |h| return c.jgz80_peek_audio_op_trace_count(h);
        return 0;
    }

    pub fn hasPendingAudibleEvents(self: *const Z80) bool {
        return self.pendingYmWriteCount() != 0 or
            self.pendingYmDacCount() != 0 or
            self.pendingPsgCommandCount() != 0;
    }

    /// The audio-owned event structs must mirror the C bridge structs
    /// exactly: the take* functions reinterpret the destination buffers
    /// across the C boundary.
    fn assertEventLayoutMatches(comptime ZigType: type, comptime CType: type) void {
        comptime {
            const zig_fields = @typeInfo(ZigType).@"struct".fields;
            const c_fields = @typeInfo(CType).@"struct".fields;
            std.debug.assert(@sizeOf(ZigType) == @sizeOf(CType));
            std.debug.assert(@alignOf(ZigType) == @alignOf(CType));
            std.debug.assert(zig_fields.len == c_fields.len);
            for (zig_fields) |field| {
                std.debug.assert(@offsetOf(ZigType, field.name) == @offsetOf(CType, field.name));
                std.debug.assert(field.type == @FieldType(CType, field.name));
            }
        }
    }

    comptime {
        assertEventLayoutMatches(YmWriteEvent, c.Jgz80YmWriteEvent);
        assertEventLayoutMatches(YmDacSampleEvent, c.Jgz80YmDacSampleEvent);
        assertEventLayoutMatches(YmResetEvent, c.Jgz80YmResetEvent);
        assertEventLayoutMatches(PsgCommandEvent, c.Jgz80PsgCommandEvent);
    }

    pub fn takeYmWrites(self: *Z80, dest: []YmWriteEvent) usize {
        if (dest.len == 0) return 0;
        if (self.handle) |h| return c.jgz80_take_ym_writes(h, @ptrCast(dest.ptr), @intCast(dest.len));
        return 0;
    }

    pub fn takeYmDacSamples(self: *Z80, dest: []YmDacSampleEvent) usize {
        if (dest.len == 0) return 0;
        if (self.handle) |h| return c.jgz80_take_ym_dac_samples(h, @ptrCast(dest.ptr), @intCast(dest.len));
        return 0;
    }

    pub fn takeYmResets(self: *Z80, dest: []YmResetEvent) usize {
        if (dest.len == 0) return 0;
        if (self.handle) |h| return c.jgz80_take_ym_resets(h, @ptrCast(dest.ptr), @intCast(dest.len));
        return 0;
    }

    pub fn takePsgCommands(self: *Z80, dest: []PsgCommandEvent) usize {
        if (dest.len == 0) return 0;
        if (self.handle) |h| return c.jgz80_take_psg_commands(h, @ptrCast(dest.ptr), @intCast(dest.len));
        return 0;
    }

    pub fn takeAudioOpTrace(self: *Z80, dest: []AudioOpTraceEntry) usize {
        if (dest.len == 0) return 0;
        if (self.handle) |h| return c.jgz80_take_audio_op_trace(h, dest.ptr, @intCast(dest.len));
        return 0;
    }

    /// Returns the total number of audio buffer overflow events since the last
    /// call and resets all overflow counters. Nonzero means audio events were
    /// silently dropped because a ring buffer was full.
    pub fn takeOverflowCounts(self: *Z80) u32 {
        if (self.handle) |h| return c.jgz80_take_overflow_counts(h, null, null, null, null);
        return 0;
    }

    pub fn discardPendingAudioEvents(self: *Z80) void {
        var ym_writes: [64]YmWriteEvent = undefined;
        while (self.takeYmWrites(ym_writes[0..]) != 0) {}

        var ym_dac_samples: [64]YmDacSampleEvent = undefined;
        while (self.takeYmDacSamples(ym_dac_samples[0..]) != 0) {}

        var ym_resets: [16]YmResetEvent = undefined;
        while (self.takeYmResets(ym_resets[0..]) != 0) {}

        var psg_commands: [64]PsgCommandEvent = undefined;
        while (self.takePsgCommands(psg_commands[0..]) != 0) {}
    }

    pub fn setAudioOpTraceEnabled(self: *Z80, enabled: bool) void {
        if (self.handle) |h| c.jgz80_set_audio_op_trace_enabled(h, if (enabled) 1 else 0);
    }

    pub fn clearAudioOpTrace(self: *Z80) void {
        if (self.handle) |h| c.jgz80_clear_audio_op_trace(h);
    }

    pub fn takeAudioOpTraceDroppedCount(self: *Z80) u32 {
        if (self.handle) |h| return c.jgz80_take_audio_op_trace_dropped_count(h);
        return 0;
    }

    pub fn setInstructionTraceEnabled(self: *Z80, enabled: bool) void {
        if (self.handle) |h| c.jgz80_set_instruction_trace_enabled(h, if (enabled) 1 else 0);
    }

    pub fn clearInstructionTrace(self: *Z80) void {
        if (self.handle) |h| c.jgz80_clear_instruction_trace(h);
    }

    pub fn pendingInstructionTraceCount(self: *const Z80) u16 {
        if (self.handle) |h| return c.jgz80_peek_instruction_trace_count(h);
        return 0;
    }

    pub fn takeInstructionTrace(self: *Z80, dest: []InstructionTraceEntry) usize {
        if (dest.len == 0) return 0;
        if (self.handle) |h| return c.jgz80_take_instruction_trace(h, dest.ptr, @intCast(dest.len));
        return 0;
    }

    pub fn setAudioMasterOffset(self: *Z80, master_offset: u32) void {
        if (self.handle) |h| c.jgz80_set_audio_master_offset(h, master_offset);
    }

    pub fn getPsgLast(self: *const Z80) u8 {
        if (self.handle) |h| return c.jgz80_get_psg_last(h);
        return 0;
    }

    pub fn getPsgTone(self: *const Z80, channel: u2) u16 {
        if (self.handle) |h| return c.jgz80_get_psg_tone(h, channel);
        return 0;
    }

    pub fn getPsgVolume(self: *const Z80, channel: u2) u8 {
        if (self.handle) |h| return c.jgz80_get_psg_volume(h, channel);
        return 0x0F;
    }

    pub fn getPsgNoise(self: *const Z80) u8 {
        if (self.handle) |h| return c.jgz80_get_psg_noise(h);
        return 0;
    }

    pub fn writeBusReq(self: *Z80, val: u16) void {
        if (self.handle) |h| c.jgz80_write_bus_req(h, val);
    }

    pub fn readBusReq(self: *const Z80) u16 {
        if (self.handle) |h| return c.jgz80_read_bus_req(@constCast(h));
        return 0x0100;
    }

    pub fn isBusReqAsserted(self: *const Z80) bool {
        if (self.handle) |h| return c.jgz80_bus_req_asserted(@constCast(h)) != 0;
        return false;
    }

    pub fn canRun(self: *const Z80) bool {
        return self.readBusReq() != 0x0000 and self.readReset() != 0x0000;
    }

    pub fn writeReset(self: *Z80, val: u16) void {
        if (self.handle) |h| c.jgz80_write_reset(h, val);
    }

    pub fn readReset(self: *const Z80) u16 {
        if (self.handle) |h| return c.jgz80_read_reset(@constCast(h));
        return 0x0100;
    }

    pub fn isResetLineAsserted(self: *const Z80) bool {
        if (self.handle) |h| return c.jgz80_reset_line_asserted(@constCast(h)) != 0;
        return false;
    }

    pub fn setResetLineAsserted(self: *Z80, asserted: bool) void {
        if (self.handle) |h| c.jgz80_set_reset_line_asserted(h, @intFromBool(asserted));
    }
};

test "z80 register dump reflects stepped state" {
    var z80 = Z80.init();
    defer z80.deinit();

    z80.writeByte(0x0000, 0x00);
    try std.testing.expectEqual(@as(u32, 4), z80.stepInstruction());

    const dump = z80.getRegisterDump();
    try std.testing.expectEqual(@as(u16, 0x0001), dump.pc);
    try std.testing.expectEqual(@as(u8, 0), dump.halted);
}

test "z80 clone preserves and decouples RAM contents" {
    var original = Z80.init();
    defer original.deinit();

    original.writeByte(0x0000, 0x12);
    original.writeByte(0x0001, 0x34);

    var cloned = try original.clone();
    defer cloned.deinit();

    try std.testing.expectEqual(@as(u8, 0x12), cloned.readByte(0x0000));
    try std.testing.expectEqual(@as(u8, 0x34), cloned.readByte(0x0001));

    cloned.writeByte(0x0000, 0xAB);
    try std.testing.expectEqual(@as(u8, 0x12), original.readByte(0x0000));
    try std.testing.expectEqual(@as(u8, 0xAB), cloned.readByte(0x0000));
}

test "z80 ram is mirrored across 0x0000-0x3fff" {
    var z80 = Z80.init();
    defer z80.deinit();

    z80.writeByte(0x2000, 0x5A);
    try std.testing.expectEqual(@as(u8, 0x5A), z80.readByte(0x0000));

    z80.writeByte(0x3FFF, 0xC3);
    try std.testing.expectEqual(@as(u8, 0xC3), z80.readByte(0x1FFF));
}

test "direct z80 audio writes retain explicit master offsets" {
    var z80 = Z80.init();
    defer z80.deinit();

    z80.setAudioMasterOffset(12);
    z80.writeByte(0x4000, 0x2A);
    z80.writeByte(0x4001, 0x56);
    z80.writeByte(0x4000, 0x22);
    z80.writeByte(0x4001, 0x0F);
    z80.writeByte(0x7F11, 0x90);

    var ym_events: [1]Z80.YmWriteEvent = undefined;
    try std.testing.expectEqual(@as(usize, 1), z80.takeYmWrites(ym_events[0..]));
    try std.testing.expectEqual(@as(u32, 12), ym_events[0].master_offset);
    try std.testing.expectEqual(@as(u8, 0x22), ym_events[0].reg);
    try std.testing.expectEqual(@as(u8, 0x0F), ym_events[0].value);

    var ym_dac_events: [1]Z80.YmDacSampleEvent = undefined;
    try std.testing.expectEqual(@as(usize, 1), z80.takeYmDacSamples(ym_dac_events[0..]));
    try std.testing.expectEqual(@as(u32, 12), ym_dac_events[0].master_offset);
    try std.testing.expectEqual(@as(u8, 0x56), ym_dac_events[0].value);

    var psg_events: [1]Z80.PsgCommandEvent = undefined;
    try std.testing.expectEqual(@as(usize, 1), z80.takePsgCommands(psg_events[0..]));
    try std.testing.expectEqual(@as(u32, 12), psg_events[0].master_offset);
    try std.testing.expectEqual(@as(u8, 0x90), psg_events[0].value);
}

test "z80 pending audible event helper ignores reset-only events" {
    var z80 = Z80.init();
    defer z80.deinit();

    try std.testing.expect(!z80.hasPendingAudibleEvents());

    z80.writeReset(0);
    try std.testing.expect(!z80.hasPendingAudibleEvents());

    z80.writeByte(0x7F11, 0x90);
    try std.testing.expect(z80.hasPendingAudibleEvents());

    var psg_events: [1]Z80.PsgCommandEvent = undefined;
    try std.testing.expectEqual(@as(usize, 1), z80.takePsgCommands(psg_events[0..]));
    try std.testing.expect(!z80.hasPendingAudibleEvents());

    var ym_reset_events: [1]Z80.YmResetEvent = undefined;
    try std.testing.expectEqual(@as(usize, 1), z80.takeYmResets(ym_reset_events[0..]));
}

test "z80 can discard all pending audio event queues" {
    var z80 = Z80.init();
    defer z80.deinit();

    z80.setAudioMasterOffset(12);
    z80.writeByte(0x4000, 0x2A);
    z80.writeByte(0x4001, 0x56);
    z80.writeByte(0x4000, 0x22);
    z80.writeByte(0x4001, 0x0F);
    z80.writeByte(0x7F11, 0x90);
    z80.writeReset(0);

    try std.testing.expect(z80.hasPendingAudibleEvents());
    try std.testing.expectEqual(@as(u16, 1), z80.pendingYmWriteCount());
    try std.testing.expectEqual(@as(u16, 1), z80.pendingYmDacCount());
    try std.testing.expectEqual(@as(u16, 1), z80.pendingPsgCommandCount());

    z80.discardPendingAudioEvents();

    try std.testing.expect(!z80.hasPendingAudibleEvents());
    try std.testing.expectEqual(@as(u16, 0), z80.pendingYmWriteCount());
    try std.testing.expectEqual(@as(u16, 0), z80.pendingYmDacCount());
    try std.testing.expectEqual(@as(u16, 0), z80.pendingPsgCommandCount());

    var ym_reset_events: [1]Z80.YmResetEvent = undefined;
    try std.testing.expectEqual(@as(usize, 0), z80.takeYmResets(ym_reset_events[0..]));
}

test "z80 instruction writes stamp ym events at instruction completion time" {
    var z80 = Z80.init();
    defer z80.deinit();

    z80.setAudioMasterOffset(12);
    z80.writeByte(0x4000, 0x22);
    z80.writeByte(0x0000, 0x32);
    z80.writeByte(0x0001, 0x01);
    z80.writeByte(0x0002, 0x40);

    var state = z80.captureState();
    state.pc = 0x0000;
    state.af = 0x5600;
    z80.restoreState(&state);

    try std.testing.expectEqual(@as(u32, 13), z80.stepInstruction());

    var ym_events: [1]Z80.YmWriteEvent = undefined;
    try std.testing.expectEqual(@as(usize, 1), z80.takeYmWrites(ym_events[0..]));
    try std.testing.expectEqual(@as(u32, 12 + (13 * clock.z80_divider)), ym_events[0].master_offset);
    try std.testing.expectEqual(@as(u8, 0x22), ym_events[0].reg);
    try std.testing.expectEqual(@as(u8, 0x56), ym_events[0].value);
}

test "z80 instruction writes stamp dac events at instruction completion time" {
    var z80 = Z80.init();
    defer z80.deinit();

    z80.setAudioMasterOffset(12);
    z80.writeByte(0x4000, 0x2A);
    z80.writeByte(0x0000, 0x32);
    z80.writeByte(0x0001, 0x01);
    z80.writeByte(0x0002, 0x40);

    var state = z80.captureState();
    state.pc = 0x0000;
    state.af = 0x5600;
    z80.restoreState(&state);

    try std.testing.expectEqual(@as(u32, 13), z80.stepInstruction());

    var ym_dac_events: [1]Z80.YmDacSampleEvent = undefined;
    try std.testing.expectEqual(@as(usize, 1), z80.takeYmDacSamples(ym_dac_events[0..]));
    try std.testing.expectEqual(@as(u32, 12 + (13 * clock.z80_divider)), ym_dac_events[0].master_offset);
    try std.testing.expectEqual(@as(u8, 0x56), ym_dac_events[0].value);
}

test "z80 instruction writes stamp psg events at instruction completion time" {
    var z80 = Z80.init();
    defer z80.deinit();

    z80.setAudioMasterOffset(12);
    z80.writeByte(0x0000, 0x77);

    var state = z80.captureState();
    state.pc = 0x0000;
    state.hl = 0x7F11;
    state.af = 0x9000;
    z80.restoreState(&state);

    try std.testing.expectEqual(@as(u32, 7), z80.stepInstruction());

    var psg_events: [1]Z80.PsgCommandEvent = undefined;
    try std.testing.expectEqual(@as(usize, 1), z80.takePsgCommands(psg_events[0..]));
    try std.testing.expectEqual(@as(u32, 12 + (7 * clock.z80_divider)), psg_events[0].master_offset);
    try std.testing.expectEqual(@as(u8, 0x90), psg_events[0].value);
}

test "z80 hard reset restores integrated psg power-on latch and attenuation" {
    var z80 = Z80.init();
    defer z80.deinit();

    try std.testing.expectEqual(@as(u8, 0), z80.getPsgVolume(0));
    try std.testing.expectEqual(@as(u8, 0), z80.getPsgVolume(1));
    try std.testing.expectEqual(@as(u8, 0), z80.getPsgVolume(2));
    try std.testing.expectEqual(@as(u8, 0), z80.getPsgVolume(3));

    z80.writeByte(0x7F11, 0x07);
    try std.testing.expectEqual(@as(u8, 0), z80.getPsgVolume(0));
    try std.testing.expectEqual(@as(u8, 7), z80.getPsgVolume(1));
    try std.testing.expectEqual(@as(u8, 0), z80.getPsgVolume(2));
    try std.testing.expectEqual(@as(u8, 0), z80.getPsgVolume(3));

    z80.writeByte(0x7F11, 0x9F);
    z80.reset();

    try std.testing.expectEqual(@as(u8, 0), z80.getPsgVolume(0));
    try std.testing.expectEqual(@as(u8, 0), z80.getPsgVolume(1));
    try std.testing.expectEqual(@as(u8, 0), z80.getPsgVolume(2));
    try std.testing.expectEqual(@as(u8, 0), z80.getPsgVolume(3));

    var psg_events: [2]Z80.PsgCommandEvent = undefined;
    try std.testing.expectEqual(@as(usize, 0), z80.takePsgCommands(psg_events[0..]));

    z80.writeByte(0x7F11, 0x05);
    try std.testing.expectEqual(@as(u8, 0), z80.getPsgVolume(0));
    try std.testing.expectEqual(@as(u8, 5), z80.getPsgVolume(1));
    try std.testing.expectEqual(@as(u8, 0), z80.getPsgVolume(2));
    try std.testing.expectEqual(@as(u8, 0), z80.getPsgVolume(3));
    try std.testing.expectEqual(@as(usize, 1), z80.takePsgCommands(psg_events[0..]));
    try std.testing.expectEqual(@as(u8, 0x05), psg_events[0].value);
}

test "z80 reset line edges emit timed ym reset events without dropping earlier ym audio events" {
    var z80 = Z80.init();
    defer z80.deinit();

    var state = z80.captureState();
    state.pc = 0x0042;
    z80.restoreState(&state);

    z80.setAudioMasterOffset(9);
    z80.writeByte(0x4000, 0x2A);
    z80.writeByte(0x4001, 0x44);
    z80.writeByte(0x4000, 0x22);
    z80.writeByte(0x4001, 0x33);

    z80.setAudioMasterOffset(27);
    z80.writeReset(0);
    try std.testing.expectEqual(@as(u16, 0x0042), z80.getPc());

    z80.setAudioMasterOffset(45);
    z80.writeReset(0x0100);
    try std.testing.expectEqual(@as(u16, 0x0000), z80.getPc());

    var ym_events: [2]Z80.YmWriteEvent = undefined;
    try std.testing.expectEqual(@as(usize, 1), z80.takeYmWrites(ym_events[0..]));
    try std.testing.expectEqual(@as(u32, 9), ym_events[0].master_offset);

    var ym_dac_events: [2]Z80.YmDacSampleEvent = undefined;
    try std.testing.expectEqual(@as(usize, 1), z80.takeYmDacSamples(ym_dac_events[0..]));
    try std.testing.expectEqual(@as(u32, 9), ym_dac_events[0].master_offset);

    var ym_reset_events: [2]Z80.YmResetEvent = undefined;
    try std.testing.expectEqual(@as(usize, 2), z80.takeYmResets(ym_reset_events[0..]));
    try std.testing.expectEqual(@as(u32, 27), ym_reset_events[0].master_offset);
    try std.testing.expectEqual(@as(u32, 45), ym_reset_events[1].master_offset);
}

test "z80 soft reset preserves ram and psg state while resetting ym and bank state" {
    var z80 = Z80.init();
    defer z80.deinit();

    z80.writeByte(0x0000, 0xAB);
    z80.writeByte(0x7F11, 0x9F);

    var state = z80.captureState();
    state.bank = 0x0123;
    z80.restoreState(&state);

    z80.setAudioMasterOffset(9);
    z80.writeByte(0x4000, 0x22);
    z80.writeByte(0x4001, 0x33);

    z80.setAudioMasterOffset(27);
    z80.softReset();

    try std.testing.expectEqual(@as(u8, 0xAB), z80.readByte(0x0000));
    try std.testing.expectEqual(@as(u16, 0), z80.getBank());
    try std.testing.expectEqual(@as(u8, 0x9F), z80.getPsgLast());
    try std.testing.expectEqual(@as(u8, 0x0F), z80.getPsgVolume(0));

    var ym_events: [1]Z80.YmWriteEvent = undefined;
    try std.testing.expectEqual(@as(usize, 1), z80.takeYmWrites(ym_events[0..]));
    try std.testing.expectEqual(@as(u32, 9), ym_events[0].master_offset);

    var psg_events: [1]Z80.PsgCommandEvent = undefined;
    try std.testing.expectEqual(@as(usize, 1), z80.takePsgCommands(psg_events[0..]));
    try std.testing.expectEqual(@as(u32, 0), psg_events[0].master_offset);
    try std.testing.expectEqual(@as(u8, 0x9F), psg_events[0].value);

    var ym_reset_events: [1]Z80.YmResetEvent = undefined;
    try std.testing.expectEqual(@as(usize, 1), z80.takeYmResets(ym_reset_events[0..]));
    try std.testing.expectEqual(@as(u32, 27), ym_reset_events[0].master_offset);
}

test "z80 external reset line gate blocks execution until released" {
    var z80 = Z80.init();
    defer z80.deinit();

    z80.writeByte(0x0000, 0x00);
    z80.reset();
    z80.setResetLineAsserted(true);

    try std.testing.expectEqual(@as(u16, 0x0000), z80.readReset());
    try std.testing.expectEqual(@as(u32, 0), z80.stepInstruction());

    z80.setResetLineAsserted(false);
    try std.testing.expectEqual(@as(u16, 0x0100), z80.readReset());
    try std.testing.expectEqual(@as(u32, 4), z80.stepInstruction());

    z80.softReset();
    z80.setResetLineAsserted(true);
    try std.testing.expectEqual(@as(u16, 0x0000), z80.readReset());
    try std.testing.expectEqual(@as(u32, 0), z80.stepInstruction());
}

test "z80 ym status read exposes busy on data writes" {
    var z80 = Z80.init();
    defer z80.deinit();

    const ym_internal_master_cycles: u32 = @as(u32, clock.m68k_divider) * 6;

    z80.setAudioMasterOffset(0);
    z80.writeByte(0x4000, 0x22);
    z80.writeByte(0x4001, 0x0F);

    try std.testing.expectEqual(@as(u8, 0x00), z80.readByte(0x4001) & 0x80);
    try std.testing.expectEqual(@as(u8, 0x00), z80.readByte(0x4000) & 0x80);
    z80.setAudioMasterOffset(ym_internal_master_cycles);
    try std.testing.expectEqual(@as(u8, 0x80), z80.readByte(0x4000) & 0x80);
    try std.testing.expectEqual(@as(u8, 0x80), z80.readByte(0x4001) & 0x80);

    z80.setAudioMasterOffset(65 * ym_internal_master_cycles);
    try std.testing.expectEqual(@as(u8, 0x00), z80.readByte(0x4001) & 0x80);
    try std.testing.expectEqual(@as(u8, 0x00), z80.readByte(0x4000) & 0x80);
}

test "z80 ym status read reports and clears timer a overflow" {
    var z80 = Z80.init();
    defer z80.deinit();

    const ym_internal_master_cycles: u32 = @as(u32, clock.m68k_divider) * 6;

    z80.setAudioMasterOffset(0);
    z80.writeByte(0x4000, 0x24);
    z80.writeByte(0x4001, 0xFF);
    z80.writeByte(0x4000, 0x25);
    z80.writeByte(0x4001, 0x03);
    z80.writeByte(0x4000, 0x27);
    z80.writeByte(0x4001, 0x05);

    z80.setAudioMasterOffset(48 * ym_internal_master_cycles);
    try std.testing.expectEqual(@as(u8, 0x01), z80.readByte(0x4000) & 0x01);

    z80.writeByte(0x4000, 0x27);
    z80.writeByte(0x4001, 0x10);
    try std.testing.expectEqual(@as(u8, 0x00), z80.readByte(0x4000) & 0x01);
    z80.setAudioMasterOffset(49 * ym_internal_master_cycles);
    try std.testing.expectEqual(@as(u8, 0x00), z80.readByte(0x4000) & 0x01);
}

test "z80 ym status read clears timer b overflow immediately on reset write" {
    var z80 = Z80.init();
    defer z80.deinit();

    const ym_internal_master_cycles: u32 = @as(u32, clock.m68k_divider) * 6;

    z80.setAudioMasterOffset(0);
    z80.writeByte(0x4000, 0x26);
    z80.writeByte(0x4001, 0xFF);
    z80.writeByte(0x4000, 0x27);
    z80.writeByte(0x4001, 0x0A);

    z80.setAudioMasterOffset(363 * ym_internal_master_cycles);
    try std.testing.expectEqual(@as(u8, 0x02), z80.readByte(0x4000) & 0x02);

    z80.writeByte(0x4000, 0x27);
    z80.writeByte(0x4001, 0x20);
    try std.testing.expectEqual(@as(u8, 0x00), z80.readByte(0x4000) & 0x02);
}
