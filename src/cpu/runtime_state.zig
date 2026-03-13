const std = @import("std");

pub const CurrentOpcodeFn = *const fn (?*anyopaque) u16;
pub const ClearInterruptFn = *const fn (?*anyopaque) void;

pub const RuntimeState = struct {
    ctx: ?*anyopaque = null,
    current_opcode_fn: ?CurrentOpcodeFn = null,
    clear_interrupt_fn: ?ClearInterruptFn = null,

    pub fn init(ctx: ?*anyopaque, opcode_fn: CurrentOpcodeFn, clear_fn: ClearInterruptFn) RuntimeState {
        return .{
            .ctx = ctx,
            .current_opcode_fn = opcode_fn,
            .clear_interrupt_fn = clear_fn,
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
};

test "runtime state dispatches callbacks and clears cleanly" {
    const testing = std.testing;

    const CallbackCtx = struct {
        opcode: u16,
        cleared: bool = false,

        fn currentOpcode(ctx: ?*anyopaque) u16 {
            const self: *const @This() = @ptrCast(@alignCast(ctx orelse unreachable));
            return self.opcode;
        }

        fn clearInterrupt(ctx: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx orelse unreachable));
            self.cleared = true;
        }
    };

    var callback_ctx = CallbackCtx{ .opcode = 0x4E71 };
    var runtime = RuntimeState.init(&callback_ctx, CallbackCtx.currentOpcode, CallbackCtx.clearInterrupt);

    try testing.expectEqual(@as(u16, 0x4E71), runtime.currentOpcode());
    runtime.clearInterrupt();
    try testing.expect(callback_ctx.cleared);

    callback_ctx.cleared = false;
    runtime.clear();
    try testing.expectEqual(@as(u16, 0), runtime.currentOpcode());
    runtime.clearInterrupt();
    try testing.expect(!callback_ctx.cleared);
}
