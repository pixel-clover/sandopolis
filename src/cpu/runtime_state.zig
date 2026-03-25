const std = @import("std");

pub const CurrentOpcodeFn = *const fn (?*anyopaque) u16;
pub const ClearInterruptFn = *const fn (?*anyopaque) void;
pub const UpdateInterruptLevelFn = *const fn (?*anyopaque, u3) void;
pub const CurrentAccessElapsedMasterCyclesFn = *const fn (?*anyopaque) u32;

pub const RuntimeState = struct {
    ctx: ?*anyopaque = null,
    current_opcode_fn: ?CurrentOpcodeFn = null,
    clear_interrupt_fn: ?ClearInterruptFn = null,
    update_interrupt_level_fn: ?UpdateInterruptLevelFn = null,
    current_access_elapsed_master_cycles_fn: ?CurrentAccessElapsedMasterCyclesFn = null,

    pub fn init(
        ctx: ?*anyopaque,
        opcode_fn: CurrentOpcodeFn,
        clear_fn: ClearInterruptFn,
        update_interrupt_level_fn: ?UpdateInterruptLevelFn,
        current_access_elapsed_master_cycles_fn: ?CurrentAccessElapsedMasterCyclesFn,
    ) RuntimeState {
        return .{
            .ctx = ctx,
            .current_opcode_fn = opcode_fn,
            .clear_interrupt_fn = clear_fn,
            .update_interrupt_level_fn = update_interrupt_level_fn,
            .current_access_elapsed_master_cycles_fn = current_access_elapsed_master_cycles_fn,
        };
    }

    pub fn clear(self: *RuntimeState) void {
        self.* = .{};
    }

    pub fn currentOpcode(self: *const RuntimeState) u16 {
        const opcode_fn = self.current_opcode_fn orelse return 0;
        return opcode_fn(self.ctx);
    }

    pub fn clearInterrupt(self: *const RuntimeState) void {
        const clear_fn = self.clear_interrupt_fn orelse return;
        clear_fn(self.ctx);
    }

    pub fn updateInterruptLevel(self: *const RuntimeState, level: u3) void {
        const update_fn = self.update_interrupt_level_fn orelse return;
        update_fn(self.ctx, level);
    }

    pub fn currentAccessElapsedMasterCycles(self: *const RuntimeState) u32 {
        const elapsed_fn = self.current_access_elapsed_master_cycles_fn orelse return 0;
        return elapsed_fn(self.ctx);
    }
};

test "runtime state dispatches callbacks and clears cleanly" {
    const testing = std.testing;

    const CallbackCtx = struct {
        opcode: u16,
        cleared: bool = false,
        elapsed_master_cycles: u32 = 123,

        fn currentOpcode(ctx: ?*anyopaque) u16 {
            const self: *const @This() = @ptrCast(@alignCast(ctx orelse unreachable));
            return self.opcode;
        }

        fn clearInterrupt(ctx: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx orelse unreachable));
            self.cleared = true;
        }

        fn currentAccessElapsedMasterCycles(ctx: ?*anyopaque) u32 {
            const self: *const @This() = @ptrCast(@alignCast(ctx orelse unreachable));
            return self.elapsed_master_cycles;
        }
    };

    var callback_ctx = CallbackCtx{ .opcode = 0x4E71 };
    var runtime = RuntimeState.init(
        &callback_ctx,
        CallbackCtx.currentOpcode,
        CallbackCtx.clearInterrupt,
        null,
        CallbackCtx.currentAccessElapsedMasterCycles,
    );

    try testing.expectEqual(@as(u16, 0x4E71), runtime.currentOpcode());
    try testing.expectEqual(@as(u32, 123), runtime.currentAccessElapsedMasterCycles());
    runtime.clearInterrupt();
    try testing.expect(callback_ctx.cleared);

    callback_ctx.cleared = false;
    runtime.clear();
    try testing.expectEqual(@as(u16, 0), runtime.currentOpcode());
    try testing.expectEqual(@as(u32, 0), runtime.currentAccessElapsedMasterCycles());
    runtime.clearInterrupt();
    try testing.expect(!callback_ctx.cleared);
}
