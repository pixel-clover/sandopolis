const std = @import("std");
const Machine = @import("machine.zig").Machine;
const Vdp = @import("video/vdp.zig").Vdp;
const Io = @import("input/io.zig").Io;

const allocator = std.heap.wasm_allocator;

// Suppress logging in WASM builds.
pub const std_options: std.Options = .{
    .log_level = .err,
    .logFn = wasmLogNoop,
};

fn wasmLogNoop(
    comptime _: std.log.Level,
    comptime _: @TypeOf(.enum_literal),
    comptime _: []const u8,
    _: anytype,
) void {}

/// Allocate memory in WASM linear memory so JavaScript can write data into it.
export fn sandopolis_alloc(len: usize) ?[*]u8 {
    const slice = allocator.alloc(u8, len) catch return null;
    return slice.ptr;
}

/// Free memory previously allocated by sandopolis_alloc.
export fn sandopolis_free(ptr: [*]u8, len: usize) void {
    allocator.free(ptr[0..len]);
}

/// Create an emulator instance from ROM bytes already in WASM memory.
export fn sandopolis_create(rom_ptr: [*]const u8, rom_len: usize) ?*Machine {
    const state = allocator.create(Machine) catch return null;
    state.* = Machine.initFromRomBytes(allocator, rom_ptr[0..rom_len]) catch {
        allocator.destroy(state);
        return null;
    };
    return state;
}

/// Destroy an emulator instance and free all associated memory.
export fn sandopolis_destroy(machine: *Machine) void {
    machine.deinit(allocator);
    allocator.destroy(machine);
}

/// Execute one full frame of emulation.
export fn sandopolis_run_frame(machine: *Machine) void {
    machine.runFrame();
}

/// Return a pointer to the current framebuffer (ARGB u32 pixels).
export fn sandopolis_framebuffer_ptr(machine: *const Machine) [*]const u32 {
    return machine.framebuffer().ptr;
}

/// Return the number of pixels in the current framebuffer.
export fn sandopolis_framebuffer_len(machine: *const Machine) usize {
    return machine.framebuffer().len;
}

/// Return the current screen width (320 for H40 mode, 256 for H32 mode).
export fn sandopolis_screen_width(machine: *const Machine) u32 {
    return machine.bus.vdp.screenWidth();
}

/// Return the current screen height (224 for NTSC, 224 or 240 for PAL).
export fn sandopolis_screen_height(machine: *const Machine) u32 {
    return machine.bus.vdp.activeVisibleLines();
}

/// Set or clear a controller button.
/// port: 0 or 1 (player 1 or 2).
/// button: bitmask from Io.Button (e.g., 0x01=Up, 0x10=B, 0x40=A, 0x80=Start).
/// pressed: true to press, false to release.
export fn sandopolis_set_button(machine: *Machine, port: u32, button: u16, pressed: bool) void {
    machine.bus.io.setButton(@intCast(port), button, pressed);
}

/// Perform a soft reset (CPU reset without reloading ROM).
export fn sandopolis_reset(machine: *Machine) void {
    machine.softReset();
}

/// Return true if the loaded ROM uses PAL timing (50 Hz).
export fn sandopolis_is_pal(machine: *const Machine) bool {
    return machine.palMode();
}

// Button constants exported for JavaScript convenience.
export fn sandopolis_button_up() u16 {
    return Io.Button.Up;
}
export fn sandopolis_button_down() u16 {
    return Io.Button.Down;
}
export fn sandopolis_button_left() u16 {
    return Io.Button.Left;
}
export fn sandopolis_button_right() u16 {
    return Io.Button.Right;
}
export fn sandopolis_button_a() u16 {
    return Io.Button.A;
}
export fn sandopolis_button_b() u16 {
    return Io.Button.B;
}
export fn sandopolis_button_c() u16 {
    return Io.Button.C;
}
export fn sandopolis_button_start() u16 {
    return Io.Button.Start;
}
export fn sandopolis_button_x() u16 {
    return Io.Button.X;
}
export fn sandopolis_button_y() u16 {
    return Io.Button.Y;
}
export fn sandopolis_button_z() u16 {
    return Io.Button.Z;
}
