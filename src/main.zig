const std = @import("std");
const zsdl3 = @import("zsdl3");

pub fn main() !void {
    // -- Emulator Initialization --
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    // Redirect stdout/stderr to file before SDL captures them
    // const log_file = try std.fs.cwd().createFile("/tmp/sandopolis_debug.log", .{});
    // defer log_file.close();

    // Duplicate stderr to log file
    // const stderr_handle = std.io.getStdErr().handle;
    // const log_fd = log_file.handle;
    // _ = std.os.linux.dup2(log_fd, stderr_handle) catch {};

    std.debug.print("=== Sandopolis Emulator Started ===\n", .{});

    try zsdl3.init(.{ .video = true, .gamepad = true });
    defer zsdl3.quit();

    const window = try zsdl3.Window.create(
        "Sandopolis - Sega Genesis Emulator",
        800,
        600,
        .{ .opengl = true },
    );
    defer window.destroy();

    const renderer = try zsdl3.Renderer.create(window, null);
    defer renderer.destroy();

    // Open first available gamepad
    var gamepad: ?*zsdl3.Gamepad = null;
    var count: c_int = 0;
    if (SDL_GetGamepads(&count)) |gamepads_ptr| {
        defer zsdl3.free(gamepads_ptr);
        if (count > 0) {
            gamepad = zsdl3.openGamepad(gamepads_ptr[0]);
            if (gamepad) |gp| {
                std.debug.print("Opened Gamepad ID: {d}\n", .{@intFromEnum(gamepads_ptr[0])});
                _ = gp;
            }
        }
    }

    // Create VDP Texture (320x224)
    const vdp_texture = try zsdl3.createTexture(renderer, zsdl3.PixelFormatEnum.argb8888, zsdl3.TextureAccess.streaming, 320, 224);
    defer vdp_texture.destroy();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var rom_path: ?[]const u8 = null;
    if (args.len > 1) {
        rom_path = args[1];
        std.debug.print("Loading ROM: {s}\n", .{rom_path.?});
    } else {
        std.debug.print("No ROM file specified. Usage: sandopolis <rom_file>\n", .{});
        std.debug.print("Loading dummy test ROM...\n", .{});
    }

    var bus = try @import("memory.zig").Bus.init(allocator, rom_path);
    defer bus.deinit(allocator);

    // Validate ROM vectors
    if (rom_path) |_| {
        const ssp = bus.read32(0x000000);
        const initial_pc = bus.read32(0x000004);
        const vector_28 = bus.read32(0x000070); // Level 1 interrupt

        std.debug.print("ROM Vectors:\n", .{});
        std.debug.print("  Initial SSP: {X:0>8}\n", .{ssp});
        std.debug.print("  Initial PC:  {X:0>8}\n", .{initial_pc});
        std.debug.print("  Vector $70:  {X:0>8} (Level 1 Int)\n", .{vector_28});

        if (ssp == 0 or ssp > 0x01000000) {
            std.debug.print("WARNING: SSP looks invalid!\n", .{});
        }
        if (initial_pc == 0 or initial_pc > 0x00400000) {
            std.debug.print("WARNING: Initial PC looks invalid!\n", .{});
        }
    }

    var cpu = @import("cpu/cpu.zig").Cpu.init();

    // -- Setup Test Environment (Dummy ROM for Tile Rendering) --
    if (rom_path == null) {
        // Vectors
        std.mem.writeInt(u32, bus.rom[0..4], 0x00FF0000, .big); // SSP
        std.mem.writeInt(u32, bus.rom[4..8], 0x00000200, .big); // PC

        // Opcode at 0x200: VDP Tile Test

        // 1. Setup VDP Registers
        var pc: u32 = 0x200;

        // Reg 2 (Plane A) -> 0x38 (0xE000)
        // MOVE.w #0x8238, 0xC00004
        bus.rom[pc] = 0x33;
        bus.rom[pc + 1] = 0xFC;
        pc += 2;
        bus.rom[pc] = 0x82;
        bus.rom[pc + 1] = 0x38;
        pc += 2;
        bus.rom[pc] = 0x00;
        bus.rom[pc + 1] = 0xC0;
        pc += 2;
        bus.rom[pc] = 0x00;
        bus.rom[pc + 1] = 0x04;
        pc += 2;

        // Reg 15 (Auto Inc) -> 2
        // MOVE.w #0x8F02, 0xC00004
        bus.rom[pc] = 0x33;
        bus.rom[pc + 1] = 0xFC;
        pc += 2;
        bus.rom[pc] = 0x8F;
        bus.rom[pc + 1] = 0x02;
        pc += 2;
        bus.rom[pc] = 0x00;
        bus.rom[pc + 1] = 0xC0;
        pc += 2;
        bus.rom[pc] = 0x00;
        bus.rom[pc + 1] = 0x04;
        pc += 2;

        // 2. Write Palette (Red / Green)
        // CRAM Write @ 0 (Color 0) -> 0xC0000000
        // MOVE.w #0xC000, 0xC00004
        bus.rom[pc] = 0x33;
        bus.rom[pc + 1] = 0xFC;
        pc += 2;
        bus.rom[pc] = 0xC0;
        bus.rom[pc + 1] = 0x00;
        pc += 2;
        bus.rom[pc] = 0x00;
        bus.rom[pc + 1] = 0xC0;
        pc += 2;
        bus.rom[pc] = 0x00;
        bus.rom[pc + 1] = 0x04;
        pc += 2;
        // MOVE.w #0x0000, 0xC00004
        bus.rom[pc] = 0x33;
        bus.rom[pc + 1] = 0xFC;
        pc += 2;
        bus.rom[pc] = 0x00;
        bus.rom[pc + 1] = 0x00;
        pc += 2;
        bus.rom[pc] = 0x00;
        bus.rom[pc + 1] = 0xC0;
        pc += 2;
        bus.rom[pc] = 0x00;
        bus.rom[pc + 1] = 0x04;
        pc += 2;

        // Color 1: Red (0000 000 000 111 -> 0x00E) in Grp 0, Idx 1
        // Auto-inc is 2. So we are at Color 1.
        // MOVE.w #0x000E, 0xC00000 (Data Port)
        bus.rom[pc] = 0x33;
        bus.rom[pc + 1] = 0xFC;
        pc += 2;
        bus.rom[pc] = 0x00;
        bus.rom[pc + 1] = 0x0E;
        pc += 2;
        bus.rom[pc] = 0x00;
        bus.rom[pc + 1] = 0xC0;
        pc += 2;
        bus.rom[pc] = 0x00;
        bus.rom[pc + 1] = 0x00;
        pc += 2;

        // Color 2: Green (0000 000 111 000 -> 0x0E0)
        // MOVE.w #0x00E0, 0xC00000
        bus.rom[pc] = 0x33;
        bus.rom[pc + 1] = 0xFC;
        pc += 2;
        bus.rom[pc] = 0x00;
        bus.rom[pc + 1] = 0xE0;
        pc += 2;
        bus.rom[pc] = 0x00;
        bus.rom[pc + 1] = 0xC0;
        pc += 2;
        bus.rom[pc] = 0x00;
        bus.rom[pc + 1] = 0x00;
        pc += 2;

        // -- Input Test ROM --
        // 1. Set TH = 1 (Port A)
        // MOVE.w #0x40, 0xA10002 -> Writes 0x40 to 0xA10003
        bus.rom[pc] = 0x33;
        bus.rom[pc + 1] = 0xFC;
        pc += 2;
        bus.rom[pc] = 0x00;
        bus.rom[pc + 1] = 0x40;
        pc += 2;
        bus.rom[pc] = 0x00;
        bus.rom[pc + 1] = 0xA1;
        pc += 2;
        bus.rom[pc] = 0x00;
        bus.rom[pc + 1] = 0x02;
        pc += 2;

        const loop_start = pc; // Mark loop start

        // 2. Read Port A (0xA10003) -> D0 (Byte)
        // MOVE.b 0xA10003, D0
        // Opcode: 1039 00xx ...
        // 0001 0000 0011 1001 -> 1039
        bus.rom[pc] = 0x10;
        bus.rom[pc + 1] = 0x39;
        pc += 2;
        bus.rom[pc] = 0x00;
        bus.rom[pc + 1] = 0xA1;
        pc += 2;
        bus.rom[pc] = 0x00;
        bus.rom[pc + 1] = 0x03;
        pc += 2;

        // 3. Test Button B (Bit 4)
        // ANDI.b #0x10, D0
        bus.rom[pc] = 0x02;
        bus.rom[pc + 1] = 0x00;
        pc += 2;
        bus.rom[pc] = 0x00;
        bus.rom[pc + 1] = 0x10;
        pc += 2;

        // 4. Branch if Zero (Pressed) -> BEQ Pressed
        // Offset: Forward X bytes.
        // BEQ opcode: 67xx (xx = 8-bit offset)
        // Needs target label.
        const branch_loc = pc;
        pc += 2; // fill later

        // Released (Red)
        // Set CRAM Addr 0
        bus.rom[pc] = 0x33;
        bus.rom[pc + 1] = 0xFC;
        pc += 2; // MOVE.w #...
        bus.rom[pc] = 0xC0;
        bus.rom[pc + 1] = 0x00;
        pc += 2; // Data
        bus.rom[pc] = 0x00;
        bus.rom[pc + 1] = 0xC0;
        pc += 2; // Addr Hi
        bus.rom[pc] = 0x00;
        bus.rom[pc + 1] = 0x04;
        pc += 2; // Addr Lo
        bus.rom[pc] = 0x33;
        bus.rom[pc + 1] = 0xFC;
        pc += 2;
        bus.rom[pc] = 0x00;
        bus.rom[pc + 1] = 0x00;
        pc += 2; // Data
        bus.rom[pc] = 0x00;
        bus.rom[pc + 1] = 0xC0;
        pc += 2;
        bus.rom[pc] = 0x00;
        bus.rom[pc + 1] = 0x04;
        pc += 2;

        // Write Red (0x000E)
        bus.rom[pc] = 0x33;
        bus.rom[pc + 1] = 0xFC;
        pc += 2;
        bus.rom[pc] = 0x00;
        bus.rom[pc + 1] = 0x0E;
        pc += 2;
        bus.rom[pc] = 0x00;
        bus.rom[pc + 1] = 0xC0;
        pc += 2;
        bus.rom[pc] = 0x00;
        bus.rom[pc + 1] = 0x00;
        pc += 2;

        // BRA Loop
        // Opcode 60xx
        // Target: loop_start. Current pc is at start of BRA.
        const back_jump = @as(i32, @intCast(loop_start)) - @as(i32, @intCast(pc + 2));
        bus.rom[pc] = 0x60;
        bus.rom[pc + 1] = @as(u8, @intCast(back_jump & 0xFF));
        pc += 2;

        // Pressed Label Target
        const pressed_target = pc;
        // Fix up branch offset
        const fwd_jump = @as(i32, @intCast(pressed_target)) - @as(i32, @intCast(branch_loc + 2));
        bus.rom[branch_loc] = 0x67;
        bus.rom[branch_loc + 1] = @as(u8, @intCast(fwd_jump & 0xFF));

        // Pressed (Green)
        // Set CRAM Addr 0
        bus.rom[pc] = 0x33;
        bus.rom[pc + 1] = 0xFC;
        pc += 2;
        bus.rom[pc] = 0xC0;
        bus.rom[pc + 1] = 0x00;
        pc += 2;
        bus.rom[pc] = 0x00;
        bus.rom[pc + 1] = 0xC0;
        pc += 2;
        bus.rom[pc] = 0x00;
        bus.rom[pc + 1] = 0x04;
        pc += 2;
        bus.rom[pc] = 0x33;
        bus.rom[pc + 1] = 0xFC;
        pc += 2;
        bus.rom[pc] = 0x00;
        bus.rom[pc + 1] = 0x00;
        pc += 2;
        bus.rom[pc] = 0x00;
        bus.rom[pc + 1] = 0xC0;
        pc += 2;
        bus.rom[pc] = 0x00;
        bus.rom[pc + 1] = 0x04;
        pc += 2;

        // Write Green (0x00E0)
        bus.rom[pc] = 0x33;
        bus.rom[pc + 1] = 0xFC;
        pc += 2;
        bus.rom[pc] = 0x00;
        bus.rom[pc + 1] = 0xE0;
        pc += 2;
        bus.rom[pc] = 0x00;
        bus.rom[pc + 1] = 0xC0;
        pc += 2;
        bus.rom[pc] = 0x00;
        bus.rom[pc + 1] = 0x00;
        pc += 2;

        // BRA Loop
        const back_jump2 = @as(i32, @intCast(loop_start)) - @as(i32, @intCast(pc + 2));
        bus.rom[pc] = 0x60;
        bus.rom[pc + 1] = @as(u8, @intCast(back_jump2 & 0xFF));
        pc += 2;

        // 5. Halt loop
        bus.rom[pc] = 0x60;
        bus.rom[pc + 1] = 0xFE;
        pc += 2;
    } else {
        // Parse ROM Header (Basic)
        if (bus.rom.len >= 0x200) {
            const console = bus.rom[0x100..0x110];
            const title = bus.rom[0x150..0x180]; // Domestic Name
            std.debug.print("Console: {s}\n", .{console});
            std.debug.print("Title:   {s}\n", .{title});
        }
        const ssp = bus.read32(0x000000);
        const pc = bus.read32(0x000004);
        std.debug.print("Reset Vectors: SSP={X:0>8} PC={X:0>8}\n", .{ ssp, pc });
    }

    cpu.reset(&bus);
    std.debug.print("CPU Reset complete.\n", .{});
    cpu.debugDump();

    mainLoop: while (true) {
        var event: zsdl3.Event = undefined;
        while (zsdl3.pollEvent(&event)) {
            switch (event.type) {
                zsdl3.EventType.quit => break :mainLoop,
                zsdl3.EventType.gamepad_button_down, zsdl3.EventType.gamepad_button_up => {
                    const pressed = (event.type == zsdl3.EventType.gamepad_button_down);
                    const button = event.gbutton.button;
                    const IoButton = @import("io.zig").Io.Button;

                    if (button == @intFromEnum(zsdl3.Gamepad.Button.dpad_up)) bus.io.setButton(0, IoButton.Up, pressed);
                    if (button == @intFromEnum(zsdl3.Gamepad.Button.dpad_down)) bus.io.setButton(0, IoButton.Down, pressed);
                    if (button == @intFromEnum(zsdl3.Gamepad.Button.dpad_left)) bus.io.setButton(0, IoButton.Left, pressed);
                    if (button == @intFromEnum(zsdl3.Gamepad.Button.dpad_right)) bus.io.setButton(0, IoButton.Right, pressed);

                    if (button == @intFromEnum(zsdl3.Gamepad.Button.south)) bus.io.setButton(0, IoButton.A, pressed); // A
                    if (button == @intFromEnum(zsdl3.Gamepad.Button.east)) bus.io.setButton(0, IoButton.B, pressed); // B
                    if (button == @intFromEnum(zsdl3.Gamepad.Button.right_shoulder)) bus.io.setButton(0, IoButton.C, pressed); // C

                    if (button == @intFromEnum(zsdl3.Gamepad.Button.west)) bus.io.setButton(0, IoButton.X, pressed); // X
                    if (button == @intFromEnum(zsdl3.Gamepad.Button.north)) bus.io.setButton(0, IoButton.Y, pressed); // Y
                    if (button == @intFromEnum(zsdl3.Gamepad.Button.left_shoulder)) bus.io.setButton(0, IoButton.Z, pressed); // Z

                    if (button == @intFromEnum(zsdl3.Gamepad.Button.back)) bus.io.setButton(0, IoButton.Mode, pressed); // Mode
                    if (button == @intFromEnum(zsdl3.Gamepad.Button.start)) bus.io.setButton(0, IoButton.Start, pressed);
                },
                zsdl3.EventType.key_down, zsdl3.EventType.key_up => {
                    // ... Input handling ...
                    const pressed = (event.type == zsdl3.EventType.key_down);
                    const scancode = event.key.scancode;
                    const IoButton = @import("io.zig").Io.Button;

                    // Player 1 Input Mapping
                    if (scancode == zsdl3.Scancode.up) bus.io.setButton(0, IoButton.Up, pressed);
                    if (scancode == zsdl3.Scancode.down) bus.io.setButton(0, IoButton.Down, pressed);
                    if (scancode == zsdl3.Scancode.left) bus.io.setButton(0, IoButton.Left, pressed);
                    if (scancode == zsdl3.Scancode.right) bus.io.setButton(0, IoButton.Right, pressed);
                    if (scancode == zsdl3.Scancode.a) bus.io.setButton(0, IoButton.A, pressed);
                    if (scancode == zsdl3.Scancode.s) bus.io.setButton(0, IoButton.B, pressed);
                    if (scancode == zsdl3.Scancode.d) bus.io.setButton(0, IoButton.C, pressed);
                    if (scancode == zsdl3.Scancode.@"return") {
                        bus.io.setButton(0, IoButton.Start, pressed);
                    }

                    // System Keys
                    if (pressed) {
                        if (scancode == zsdl3.Scancode.space) {
                            // Single Step
                            cpu.step(&bus);
                            bus.step(@intCast(cpu.cycles)); // Keep System in sync
                            cpu.debugDump();
                        }
                        if (scancode == zsdl3.Scancode.escape) break :mainLoop;
                    }
                },
                else => {},
            }
        }

        // Emulation Run
        for (0..2000) |_| {
            cpu.step(&bus);
            if (cpu.halted) break :mainLoop;

            // Update System (VDP, Z80, DMA)
            bus.step(@intCast(cpu.cycles));

            // Check for V-BLANK interrupt
            if (bus.vdp.shouldFireVBlankInterrupt()) {
                cpu.requestInterrupt(6); // Level 6 = V-BLANK interrupt
            }
        }

        // Render VDP Scanlines
        for (0..224) |line| {
            bus.vdp.renderScanline(@intCast(line));
        }

        // Update Texture via Lock/Unlock (UpdateTexture missing in binding)
        if (vdp_texture.lock(null)) |locked| {
            const src_ptr = std.mem.sliceAsBytes(&bus.vdp.framebuffer);
            const dst_ptr = locked.pixels;
            const src_pitch: usize = 320 * 4;
            const dst_pitch = @as(usize, @intCast(locked.pitch));

            for (0..224) |row| {
                const src_row = src_ptr[row * src_pitch .. (row + 1) * src_pitch];
                const dst_row = dst_ptr[row * dst_pitch .. row * dst_pitch + src_pitch];
                @memcpy(dst_row, src_row);
            }
            vdp_texture.unlock();
        } else |_| {}

        // Render
        try zsdl3.setRenderDrawColor(renderer, .{ .r = 0x20, .g = 0x20, .b = 0x20, .a = 0xFF });
        try zsdl3.renderClear(renderer);
        try zsdl3.renderTexture(renderer, vdp_texture, null, null);
        zsdl3.renderPresent(renderer);
    }
}

extern fn SDL_GetGamepads(count: *c_int) ?[*]zsdl3.Joystick.Id;
