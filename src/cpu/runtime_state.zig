const CurrentOpcodeFn = *const fn (?*anyopaque) u16;
const ClearInterruptFn = *const fn (?*anyopaque) void;

var active_ctx: ?*anyopaque = null;
var current_opcode_fn: ?CurrentOpcodeFn = null;
var clear_interrupt_fn: ?ClearInterruptFn = null;

pub fn setActive(ctx: ?*anyopaque, opcode_fn: CurrentOpcodeFn, clear_fn: ClearInterruptFn) void {
    active_ctx = ctx;
    current_opcode_fn = opcode_fn;
    clear_interrupt_fn = clear_fn;
}

pub fn clearActive() void {
    active_ctx = null;
    current_opcode_fn = null;
    clear_interrupt_fn = null;
}

pub fn currentOpcode() u16 {
    const opcode_fn = current_opcode_fn orelse return 0;
    return opcode_fn(active_ctx);
}

pub fn clearInterrupt() void {
    const clear_fn = clear_interrupt_fn orelse return;
    clear_fn(active_ctx);
}
