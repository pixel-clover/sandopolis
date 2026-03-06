const std = @import("std");
const zsdl3 = @import("zsdl3");
const clock = @import("clock.zig");
const frame_scheduler = @import("frame_scheduler.zig");
const AudioOutput = @import("audio_output.zig").AudioOutput;
const InputBindings = @import("input_mapping.zig");

const AudioInit = struct {
    stream: *zsdl3.AudioStream,
    output: AudioOutput,
};

const SdlAudioSpecRaw = extern struct {
    format: zsdl3.AudioFormat,
    channels: c_int,
    freq: c_int,
};

const GamepadSlot = struct {
    id: zsdl3.Joystick.Id,
    handle: *zsdl3.Gamepad,
};

fn formatName(format: zsdl3.AudioFormat) []const u8 {
    return switch (format) {
        .S16LE => "S16LE",
        .S16BE => "S16BE",
        .F32LE => "F32LE",
        .F32BE => "F32BE",
        else => "unknown",
    };
}

fn keyboardInputFromScancode(scancode: zsdl3.Scancode) ?InputBindings.KeyboardInput {
    return switch (scancode) {
        .up => .up,
        .down => .down,
        .left => .left,
        .right => .right,
        .a => .a,
        .s => .s,
        .d => .d,
        .q => .q,
        .w => .w,
        .e => .e,
        .r => .r,
        .f => .f,
        .h => .h,
        .i => .i,
        .j => .j,
        .k => .k,
        .l => .l,
        .m => .m,
        .n => .n,
        .o => .o,
        .p => .p,
        .u => .u,
        .z => .z,
        .x => .x,
        .c => .c,
        .v => .v,
        .@"return" => .@"return",
        .tab => .tab,
        .backspace => .backspace,
        .space => .space,
        .escape => .escape,
        .lshift => .lshift,
        .rshift => .rshift,
        .semicolon => .semicolon,
        .apostrophe => .apostrophe,
        .comma => .comma,
        .period => .period,
        .slash => .slash,
        else => null,
    };
}

fn gamepadInputFromButton(button: u8) ?InputBindings.GamepadInput {
    if (button == @intFromEnum(zsdl3.Gamepad.Button.dpad_up)) return .dpad_up;
    if (button == @intFromEnum(zsdl3.Gamepad.Button.dpad_down)) return .dpad_down;
    if (button == @intFromEnum(zsdl3.Gamepad.Button.dpad_left)) return .dpad_left;
    if (button == @intFromEnum(zsdl3.Gamepad.Button.dpad_right)) return .dpad_right;
    if (button == @intFromEnum(zsdl3.Gamepad.Button.south)) return .south;
    if (button == @intFromEnum(zsdl3.Gamepad.Button.east)) return .east;
    if (button == @intFromEnum(zsdl3.Gamepad.Button.west)) return .west;
    if (button == @intFromEnum(zsdl3.Gamepad.Button.north)) return .north;
    if (button == @intFromEnum(zsdl3.Gamepad.Button.left_shoulder)) return .left_shoulder;
    if (button == @intFromEnum(zsdl3.Gamepad.Button.right_shoulder)) return .right_shoulder;
    if (button == @intFromEnum(zsdl3.Gamepad.Button.back)) return .back;
    if (button == @intFromEnum(zsdl3.Gamepad.Button.start)) return .start;
    return null;
}

fn findGamepadPort(gamepads: *const [InputBindings.player_count]?GamepadSlot, id: zsdl3.Joystick.Id) ?usize {
    for (gamepads, 0..) |slot, port| {
        if (slot) |assigned| {
            if (assigned.id == id) return port;
        }
    }
    return null;
}

fn assignGamepadSlot(gamepads: *[InputBindings.player_count]?GamepadSlot, id: zsdl3.Joystick.Id) void {
    if (findGamepadPort(gamepads, id) != null) return;
    for (gamepads, 0..) |slot, port| {
        if (slot == null) {
            if (zsdl3.openGamepad(id)) |handle| {
                gamepads[port] = .{ .id = id, .handle = handle };
                std.debug.print("Opened Gamepad ID: {d} for player {d}\n", .{ @intFromEnum(id), port + 1 });
            }
            return;
        }
    }
}

fn removeGamepadSlot(gamepads: *[InputBindings.player_count]?GamepadSlot, id: zsdl3.Joystick.Id) void {
    for (gamepads, 0..) |slot, port| {
        if (slot) |assigned| {
            if (assigned.id == id) {
                assigned.handle.close();
                gamepads[port] = null;
                std.debug.print("Closed Gamepad ID: {d} from player {d}\n", .{ @intFromEnum(id), port + 1 });
                return;
            }
        }
    }
}

fn tryInitAudio(userdata: *u8) ?AudioInit {
    const playback_device: zsdl3.AudioDeviceId = @enumFromInt(zsdl3.AUDIO_DEVICE_DEFAULT_PLAYBACK);
    const candidate_formats = [_]zsdl3.AudioFormat{
        zsdl3.AudioFormat.S16,
    };
    const candidate_rates = [_]c_int{AudioOutput.output_rate};

    for (candidate_formats) |format| {
        for (candidate_rates) |freq| {
            const spec = SdlAudioSpecRaw{
                .format = format,
                .channels = 2,
                .freq = freq,
            };
            if (SDL_OpenAudioDeviceStream(playback_device, &spec, null, userdata)) |stream| {
                const audio_device = zsdl3.getAudioStreamDevice(stream);
                _ = zsdl3.resumeAudioDevice(audio_device);
                std.debug.print("Audio enabled: {s} {d}Hz\n", .{ formatName(format), freq });
                return .{
                    .stream = stream,
                    .output = AudioOutput{ .stream = stream },
                };
            }
        }
    }

    return null;
}

fn findDefaultRomPath(allocator: std.mem.Allocator) !?[]u8 {
    var dir = std.fs.cwd().openDir("roms", .{ .iterate = true }) catch return null;
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        const name = entry.name;
        if (std.mem.endsWith(u8, name, ".smd") or std.mem.endsWith(u8, name, ".bin") or std.mem.endsWith(u8, name, ".md")) {
            return try std.fmt.allocPrint(allocator, "roms/{s}", .{name});
        }
    }
    return null;
}

pub fn main() !void {
    // -- Emulator Initialization --
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    std.debug.print("=== Sandopolis Emulator Started ===\n", .{});

    try zsdl3.init(.{ .audio = true, .video = true, .gamepad = true });
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

    var audio_userdata: u8 = 0;
    var audio: ?AudioInit = tryInitAudio(&audio_userdata);
    if (audio == null) {
        std.debug.print("Audio disabled: no compatible stream format\n", .{});
    }
    defer if (audio) |a| SDL_DestroyAudioStream(a.stream);

    // Open up to two gamepads and assign them to players by SDL device ID.
    var gamepads = [_]?GamepadSlot{null} ** InputBindings.player_count;
    defer {
        for (gamepads) |slot| {
            if (slot) |assigned| assigned.handle.close();
        }
    }
    var count: c_int = 0;
    if (SDL_GetGamepads(&count)) |gamepads_ptr| {
        defer zsdl3.free(gamepads_ptr);
        const gamepad_count: usize = @intCast(@max(count, 0));
        for (0..@min(gamepad_count, InputBindings.player_count)) |i| {
            assignGamepadSlot(&gamepads, gamepads_ptr[i]);
        }
    }

    // Create VDP Texture (320x224)
    const vdp_texture = try zsdl3.createTexture(renderer, zsdl3.PixelFormatEnum.argb8888, zsdl3.TextureAccess.streaming, 320, 224);
    defer vdp_texture.destroy();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var rom_path: ?[]const u8 = null;
    var owned_rom_path: ?[]u8 = null;
    defer if (owned_rom_path) |p| allocator.free(p);
    if (args.len > 1) {
        rom_path = args[1];
        std.debug.print("Loading ROM: {s}\n", .{rom_path.?});
    } else {
        owned_rom_path = try findDefaultRomPath(allocator);
        if (owned_rom_path) |path| {
            rom_path = path;
            std.debug.print("No ROM argument provided. Auto-loading: {s}\n", .{path});
        } else {
            std.debug.print("No ROM file specified. Usage: sandopolis <rom_file>\n", .{});
            std.debug.print("Loading dummy test ROM...\n", .{});
        }
    }

    const input_config_path = try InputBindings.defaultConfigPath(allocator);
    defer if (input_config_path) |path| allocator.free(path);

    var input_bindings = InputBindings.Bindings.defaults();
    if (input_config_path) |path| {
        input_bindings = try InputBindings.Bindings.loadFromFile(allocator, path);
        std.debug.print("Loaded input config: {s}\n", .{path});
    }

    var bus = try @import("memory.zig").Bus.init(allocator, rom_path);
    defer {
        bus.flushPersistentStorage() catch |err| {
            std.debug.print("Failed to flush persistent SRAM: {s}\n", .{@errorName(err)});
        };
        bus.deinit(allocator);
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

    var m68k_sync = clock.M68kSync{};
    const target_frame_ns: u64 = 1_000_000_000 / 60;
    var frame_counter: u32 = 0;
    const uncapped_boot_frames: u32 = 240;

    mainLoop: while (true) {
        const frame_start = std.time.nanoTimestamp();
        var event: zsdl3.Event = undefined;
        while (zsdl3.pollEvent(&event)) {
            switch (event.type) {
                zsdl3.EventType.quit => break :mainLoop,
                zsdl3.EventType.gamepad_added => assignGamepadSlot(&gamepads, event.gdevice.which),
                zsdl3.EventType.gamepad_removed => removeGamepadSlot(&gamepads, event.gdevice.which),
                zsdl3.EventType.gamepad_button_down, zsdl3.EventType.gamepad_button_up => {
                    const pressed = (event.type == zsdl3.EventType.gamepad_button_down);
                    const button = event.gbutton.button;
                    const port = findGamepadPort(&gamepads, event.gbutton.which) orelse continue;
                    if (gamepadInputFromButton(button)) |mapped_button| {
                        _ = input_bindings.applyGamepad(&bus.io, port, mapped_button, pressed);
                    }
                },
                zsdl3.EventType.key_down, zsdl3.EventType.key_up => {
                    const pressed = (event.type == zsdl3.EventType.key_down);
                    const scancode = event.key.scancode;
                    if (keyboardInputFromScancode(scancode)) |mapped_key| {
                        _ = input_bindings.applyKeyboard(&bus.io, mapped_key, pressed);

                        if (pressed) {
                            switch (input_bindings.hotkeyForKeyboard(mapped_key) orelse continue) {
                                .step => {
                                    frame_scheduler.runMasterSlice(&bus, &cpu, &m68k_sync, clock.m68k_divider);
                                    cpu.debugDump();
                                },
                                .quit => break :mainLoop,
                            }
                        }
                    }
                },
                else => {},
            }
        }

        // Frame scheduler (NTSC-like): active display + HBlank per line, then VBlank lines.
        const visible_lines: u16 = if (bus.vdp.pal_mode) clock.pal_visible_lines else clock.ntsc_visible_lines;
        const total_lines: u16 = if (bus.vdp.pal_mode) clock.pal_lines_per_frame else clock.ntsc_lines_per_frame;
        bus.vdp.beginFrame();
        for (0..total_lines) |line_idx| {
            const line: u16 = @intCast(line_idx);
            const entering_vblank = bus.vdp.setScanlineState(line, visible_lines, total_lines);
            if (entering_vblank and bus.vdp.isVBlankInterruptEnabled()) {
                cpu.requestInterrupt(6); // V-BLANK interrupt at vblank entry
            }
            bus.vdp.setHBlank(false);

            const hint_master_cycles = bus.vdp.hInterruptMasterCycles();
            const hblank_start_master_cycles = bus.vdp.hblankStartMasterCycles();
            const first_event_master_cycles = @min(hint_master_cycles, hblank_start_master_cycles);
            const second_event_master_cycles = @max(hint_master_cycles, hblank_start_master_cycles);

            frame_scheduler.runMasterSlice(&bus, &cpu, &m68k_sync, first_event_master_cycles);

            if (hblank_start_master_cycles == first_event_master_cycles) {
                bus.vdp.setHBlank(true);
            }
            if (hint_master_cycles == first_event_master_cycles and bus.vdp.consumeHintForLine(line, visible_lines)) {
                cpu.requestInterrupt(4);
            }

            frame_scheduler.runMasterSlice(&bus, &cpu, &m68k_sync, second_event_master_cycles - first_event_master_cycles);

            if (hblank_start_master_cycles == second_event_master_cycles and hblank_start_master_cycles != first_event_master_cycles) {
                bus.vdp.setHBlank(true);
            }
            if (hint_master_cycles == second_event_master_cycles and hint_master_cycles != first_event_master_cycles and bus.vdp.consumeHintForLine(line, visible_lines)) {
                cpu.requestInterrupt(4);
            }

            frame_scheduler.runMasterSlice(&bus, &cpu, &m68k_sync, clock.ntsc_master_cycles_per_line - second_event_master_cycles);
            bus.vdp.setHBlank(false);

            if (line < visible_lines) {
                bus.vdp.renderScanline(line);
            }
        }
        bus.vdp.odd_frame = !bus.vdp.odd_frame;
        if ((frame_counter % 300) == 0) {
            std.debug.print("f={d} pc={X:0>8}\n", .{ frame_counter, cpu.core.pc });
        }
        const audio_frames = bus.audio_timing.takePending();
        if (audio) |*a| {
            try a.output.pushPending(audio_frames, &bus.z80, bus.vdp.pal_mode);
        }

        // Update texture from framebuffer
        _ = SDL_UpdateTexture(vdp_texture, null, @ptrCast(&bus.vdp.framebuffer), 320 * 4);

        // Render
        try zsdl3.setRenderDrawColor(renderer, .{ .r = 0x20, .g = 0x20, .b = 0x20, .a = 0xFF });
        try zsdl3.renderClear(renderer);
        try zsdl3.renderTexture(renderer, vdp_texture, null, null);
        zsdl3.renderPresent(renderer);

        frame_counter += 1;
        if (frame_counter > uncapped_boot_frames) {
            const frame_elapsed: u64 = @intCast(std.time.nanoTimestamp() - frame_start);
            if (frame_elapsed < target_frame_ns) {
                std.Thread.sleep(target_frame_ns - frame_elapsed);
            }
        }
    }
}

extern fn SDL_GetGamepads(count: *c_int) ?[*]zsdl3.Joystick.Id;
extern fn SDL_OpenAudioDeviceStream(
    device: zsdl3.AudioDeviceId,
    spec: *const SdlAudioSpecRaw,
    callback: ?zsdl3.AudioStreamCallback,
    userdata: *anyopaque,
) ?*zsdl3.AudioStream;
extern fn SDL_DestroyAudioStream(stream: *zsdl3.AudioStream) void;
extern fn SDL_UpdateTexture(texture: *zsdl3.Texture, rect: ?*const zsdl3.Rect, pixels: ?*const anyopaque, pitch: c_int) bool;
