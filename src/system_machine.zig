const std = @import("std");
const Machine = @import("machine.zig").Machine;
const SmsMachine = @import("sms/machine.zig").SmsMachine;
const SmsInput = @import("sms/input.zig").SmsInput;
const system_detect = @import("system.zig");
const rom_loader = @import("rom_loader.zig");
const clock = @import("clock.zig");
const sms_clock = @import("sms/clock.zig");
const genesis_state_file = @import("state_file.zig");
const sms_state_file = @import("sms/state_file.zig");
const PendingAudioFrames = @import("audio/timing.zig").PendingAudioFrames;
const CoreFrameCounters = @import("performance_profile.zig").CoreFrameCounters;
const Vdp = @import("video/vdp.zig").Vdp;
const Z80 = @import("cpu/z80.zig").Z80;
const Io = @import("input/io.zig").Io;
const InputBindings = @import("input/mapping.zig");

/// System-agnostic machine wrapper that dispatches to Genesis or SMS.
pub const SystemMachine = union(enum) {
    genesis: Machine,
    sms: SmsMachine,

    pub const SystemType = system_detect.SystemType;

    pub const RomMetadata = Machine.RomMetadata;

    pub const Snapshot = struct {
        state: union(enum) {
            genesis: Machine.Snapshot,
            sms: SmsMachine.Snapshot,
        },

        pub fn deinit(self: *Snapshot, allocator: std.mem.Allocator) void {
            switch (self.state) {
                .genesis => |*g| g.deinit(allocator),
                .sms => |*s| s.deinit(allocator),
            }
        }
    };

    // -- Lifecycle --

    /// Initialize from a ROM file path. Detects system type automatically.
    /// Strip a trailing ".zip" extension so that state/SRAM paths resolve
    /// identically whether the ROM was loaded from a ZIP or directly.
    fn effectiveRomPath(path: []const u8) []const u8 {
        if (path.len > 4 and std.ascii.eqlIgnoreCase(path[path.len - 4 ..], ".zip")) {
            return path[0 .. path.len - 4];
        }
        return path;
    }

    pub fn init(allocator: std.mem.Allocator, rom_path: ?[]const u8) !SystemMachine {
        if (rom_path) |path| {
            // Read the file (with ZIP extraction support) and detect system type.
            const rom_data = try rom_loader.readRomFile(allocator, path, 8 * 1024 * 1024);
            // Both machine inits copy the bytes, so the file data can always
            // be released, including on error paths.
            defer allocator.free(rom_data);
            const effective_path = effectiveRomPath(path);
            // Extension-based detection takes priority (e.g. .sg for SG-1000).
            // Use effective_path (.zip stripped) so ".sg.zip" resolves to ".sg".
            const sys = system_detect.detectSystemFromExtension(effective_path) orelse
                system_detect.detectSystem(rom_data);
            if (sys == .sms or sys == .gg or sys == .sg1000) {
                var sms = try SmsMachine.initFromRomBytes(allocator, rom_data);
                errdefer sms.deinit(allocator);
                sms.is_game_gear = (sys == .gg);
                sms.is_sg1000 = (sys == .sg1000);
                try sms.bus.setSourcePath(allocator, effective_path);
                // NOTE: no bindPointers() here — the struct is moved by the
                // return below; SmsMachine.runFrame binds lazily.
                return .{ .sms = sms };
            }
            // Genesis: init from extracted ROM bytes (handles ZIP transparently)
            // and set source path for SRAM resolution.
            var genesis = try Machine.initFromRomBytes(allocator, rom_data);
            errdefer genesis.deinit(allocator);
            const source_copy = try allocator.dupe(u8, effective_path);
            const Cartridge = @import("bus/cartridge.zig").Cartridge;
            const save_copy = Cartridge.savePathForRom(allocator, effective_path) catch null;
            genesis.bus.replaceStoragePaths(allocator, save_copy, source_copy);
            if (genesis.bus.cartridge.ram.persistent and genesis.bus.cartridge.ram.hasStorage()) {
                genesis.bus.cartridge.loadPersistentStorage() catch {};
            }
            return .{ .genesis = genesis };
        }
        // No ROM path: Genesis dummy/idle mode.
        return .{ .genesis = try Machine.init(allocator, null) };
    }

    /// Initialize from in-memory ROM bytes (ZIP archives are extracted).
    /// `system_hint` overrides content-based detection when the caller knows
    /// the system out-of-band (e.g. from a file extension the raw bytes no
    /// longer carry). No storage paths are attached; frontends that persist
    /// state or SRAM own that concern.
    pub fn initFromRomBytes(
        allocator: std.mem.Allocator,
        raw_bytes: []const u8,
        system_hint: ?SystemType,
    ) !SystemMachine {
        const rom_bytes = try rom_loader.extractRomBytes(allocator, raw_bytes);
        defer allocator.free(rom_bytes);
        const sys = system_hint orelse system_detect.detectSystem(rom_bytes);
        switch (sys) {
            .sms, .gg, .sg1000 => {
                var sms = try SmsMachine.initFromRomBytes(allocator, rom_bytes);
                sms.is_game_gear = (sys == .gg);
                sms.is_sg1000 = (sys == .sg1000);
                return .{ .sms = sms };
            },
            .genesis => return .{ .genesis = try Machine.initFromRomBytes(allocator, rom_bytes) },
        }
    }

    pub fn deinit(self: *SystemMachine, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .genesis => |*g| g.deinit(allocator),
            .sms => |*s| s.deinit(allocator),
        }
    }

    pub fn systemType(self: *const SystemMachine) SystemType {
        return switch (self.*) {
            .genesis => .genesis,
            .sms => |*s| if (s.is_game_gear) .gg else if (s.is_sg1000) .sg1000 else .sms,
        };
    }

    // -- Frame execution --

    pub fn runFrame(self: *SystemMachine) void {
        switch (self.*) {
            .genesis => |*g| g.runFrame(),
            .sms => |*s| s.runFrame(),
        }
    }

    pub fn runFrameProfiled(self: *SystemMachine, counters: *CoreFrameCounters) void {
        switch (self.*) {
            .genesis => |*g| g.runFrameProfiled(counters),
            .sms => |*s| s.runFrame(),
        }
    }

    // -- Video --

    pub fn framebuffer(self: *const SystemMachine) []const u32 {
        return switch (self.*) {
            .genesis => |*g| g.framebuffer(),
            .sms => |*s| s.framebuffer(),
        };
    }

    pub fn framebufferWidth(self: *const SystemMachine) u16 {
        return switch (self.*) {
            .genesis => |*g| g.framebufferWidth(),
            .sms => |*s| s.framebufferWidth(),
        };
    }

    pub fn screenHeight(self: *const SystemMachine) u16 {
        return switch (self.*) {
            .genesis => |*g| g.screenHeight(),
            .sms => |*s| s.screenHeight(),
        };
    }

    /// Maximum possible framebuffer width across all systems (for texture allocation).
    pub fn maxFramebufferWidth() u16 {
        return Vdp.framebuffer_width; // 320 (Genesis) >= 256 (SMS)
    }

    /// Maximum possible framebuffer height across all systems.
    pub fn maxFramebufferHeight() u16 {
        return Vdp.max_framebuffer_height; // 240 (Genesis PAL) >= 224 (SMS)
    }

    /// Display mode bitmask (H40 = 1, interlace mode 2 = 2, shadow/highlight
    /// = 4). SMS/GG have none of these modes and always report 0.
    pub fn displayModeFlags(self: *const SystemMachine) u32 {
        return switch (self.*) {
            .genesis => |*g| g.displayModeFlags(),
            .sms => 0,
        };
    }

    /// Framebuffer stride in pixels (width of the backing buffer row, not active width).
    pub fn framebufferStride(self: *const SystemMachine) u16 {
        return switch (self.*) {
            .genesis => Vdp.framebuffer_width,
            .sms => |*s| s.framebufferWidth(),
        };
    }

    // -- Audio --

    pub fn takePendingAudio(self: *SystemMachine) PendingAudioFrames {
        return switch (self.*) {
            .genesis => |*g| g.takePendingAudio(),
            .sms => .{
                .master_cycles = 0,
                .fm_frames = 0,
                .psg_frames = 0,
                .fm_start_remainder = 0,
                .psg_start_remainder = 0,
            },
        };
    }

    pub fn discardPendingAudio(self: *SystemMachine) void {
        switch (self.*) {
            .genesis => |*g| g.discardPendingAudio(),
            .sms => {},
        }
    }

    /// For Genesis: returns the Z80 for audio state sync. For SMS: returns null.
    pub fn audioZ80(self: *SystemMachine) ?*Z80 {
        return switch (self.*) {
            .genesis => &self.genesis.bus.z80,
            .sms => null,
        };
    }

    /// For SMS: get rendered audio samples from the last frame.
    pub fn smsAudioBuffer(self: *const SystemMachine) ?[]const i16 {
        return switch (self.*) {
            .genesis => null,
            .sms => |*s| s.audioBuffer(),
        };
    }

    // -- Timing & region --

    pub fn palMode(self: *const SystemMachine) bool {
        return switch (self.*) {
            .genesis => |*g| g.palMode(),
            .sms => |*s| s.isPal(),
        };
    }

    pub fn setPalMode(self: *SystemMachine, pal: bool) void {
        switch (self.*) {
            .genesis => |*g| g.setPalMode(pal),
            .sms => |*s| {
                s.pal_mode = pal;
                s.bus.vdp.pal_mode = pal;
            },
        }
    }

    pub fn frameMasterCycles(self: *const SystemMachine) u32 {
        return switch (self.*) {
            .genesis => |*g| g.frameMasterCycles(),
            .sms => |*s| blk: {
                const lines: u32 = if (s.pal_mode) sms_clock.pal_lines_per_frame else sms_clock.ntsc_lines_per_frame;
                break :blk lines * sms_clock.master_cycles_per_line;
            },
        };
    }

    /// Master clock rate in Hz for the running system and region.
    pub fn masterClockHz(self: *const SystemMachine) u32 {
        return switch (self.*) {
            .genesis => |*g| if (g.palMode()) clock.master_clock_pal else clock.master_clock_ntsc,
            .sms => |*s| if (s.isPal()) sms_clock.pal_master_clock else sms_clock.ntsc_master_clock,
        };
    }

    /// Nominal video frame rate derived from the master clock.
    pub fn framesPerSecond(self: *const SystemMachine) f64 {
        const master_hz: f64 = @floatFromInt(self.masterClockHz());
        const per_frame: f64 = @floatFromInt(self.frameMasterCycles());
        return master_hz / per_frame;
    }

    pub fn setConsoleIsOverseas(self: *SystemMachine, overseas: bool) void {
        switch (self.*) {
            .genesis => |*g| g.setConsoleIsOverseas(overseas),
            .sms => {},
        }
    }

    pub fn consoleIsOverseas(self: *const SystemMachine) bool {
        return switch (self.*) {
            .genesis => |*g| g.consoleIsOverseas(),
            .sms => true,
        };
    }

    // -- Reset --

    pub fn reset(self: *SystemMachine) void {
        switch (self.*) {
            .genesis => |*g| g.reset(),
            .sms => |*s| s.reset(),
        }
    }

    pub fn softReset(self: *SystemMachine) void {
        switch (self.*) {
            .genesis => |*g| g.softReset(),
            .sms => |*s| s.softReset(),
        }
    }

    // -- Input --

    pub fn applyControllerTypes(self: *SystemMachine, bindings: *const InputBindings.Bindings) void {
        switch (self.*) {
            .genesis => |*g| g.applyControllerTypes(bindings),
            .sms => {},
        }
    }

    pub fn applyKeyboardBindings(
        self: *SystemMachine,
        bindings: *const InputBindings.Bindings,
        input: InputBindings.KeyboardInput,
        pressed: bool,
    ) bool {
        return switch (self.*) {
            .genesis => |*g| g.applyKeyboardBindings(bindings, input, pressed),
            .sms => false,
        };
    }

    pub fn applyGamepadBindings(
        self: *SystemMachine,
        bindings: *const InputBindings.Bindings,
        port: usize,
        input: InputBindings.GamepadInput,
        pressed: bool,
    ) bool {
        return switch (self.*) {
            .genesis => |*g| g.applyGamepadBindings(bindings, port, input, pressed),
            .sms => false,
        };
    }

    pub fn releaseKeyboardBindings(self: *SystemMachine, bindings: *const InputBindings.Bindings) void {
        switch (self.*) {
            .genesis => |*g| g.releaseKeyboardBindings(bindings),
            .sms => {},
        }
    }

    /// Set SMS button state. For Genesis, this is a no-op (use applyKeyboardBindings etc.).
    pub fn setSmsButton(self: *SystemMachine, port: u1, button: SmsInput.Button, pressed: bool) void {
        switch (self.*) {
            .genesis => {},
            .sms => |*s| s.setButton(port, button, pressed),
        }
    }

    /// Set SMS/GG pause or start button. On SMS, pause triggers NMI (edge-triggered).
    /// On Game Gear, start is readable via I/O port 0x00. For Genesis, this is a no-op.
    pub fn setSmsStartOrPause(self: *SystemMachine, pressed: bool) void {
        switch (self.*) {
            .genesis => {},
            .sms => |*s| {
                if (s.is_game_gear) {
                    s.bus.input.start_pressed = pressed;
                } else if (pressed) {
                    s.bus.input.pause_pressed = true;
                }
            },
        }
    }

    /// Press or release a button identified by its Genesis-style mask
    /// (Io.Button.*). On SMS/GG the mask maps to the nearest equivalent:
    /// A and B -> button 1, C -> button 2, Start -> pause (SMS) or the
    /// Game Gear Start button. Unmappable buttons are ignored.
    pub fn setButton(self: *SystemMachine, port: u32, button_mask: u16, pressed: bool) void {
        switch (self.*) {
            .genesis => |*g| g.setButton(port, button_mask, pressed),
            .sms => |*s| {
                const sms_port: u1 = @intCast(@min(port, 1));
                const sms_button: SmsInput.Button = switch (button_mask) {
                    Io.Button.Up => .up,
                    Io.Button.Down => .down,
                    Io.Button.Left => .left,
                    Io.Button.Right => .right,
                    Io.Button.A, Io.Button.B => .button1,
                    Io.Button.C => .button2,
                    Io.Button.Start => return self.setSmsStartOrPause(pressed),
                    else => return,
                };
                s.setButton(sms_port, sms_button, pressed);
            },
        }
    }

    // -- ROM metadata --

    pub fn romMetadata(self: *const SystemMachine) RomMetadata {
        return switch (self.*) {
            .genesis => |*g| g.romMetadata(),
            .sms => .{
                .console = null,
                .title = null,
                .product_code = null,
                .country_codes = null,
                .reset_stack_pointer = 0,
                .reset_program_counter = 0,
                .header_checksum = 0,
                .computed_checksum = 0,
                .checksum_valid = true,
            },
        };
    }

    // -- Memory regions --

    pub fn romSize(self: *const SystemMachine) usize {
        return switch (self.*) {
            .genesis => |*g| g.romSize(),
            .sms => |*s| s.romSize(),
        };
    }

    /// Console work RAM (68K RAM on Genesis, Z80 RAM on SMS/GG).
    pub fn workRam(self: *SystemMachine) []u8 {
        return switch (self.*) {
            .genesis => |*g| g.workRam(),
            .sms => |*s| s.workRam(),
        };
    }

    /// Battery-backed cartridge storage the frontend may persist and rewrite
    /// in place (e.g. libretro SAVE_RAM), or null when the cartridge has
    /// none. SMS/GG battery RAM is not persisted yet and reports null.
    pub fn persistentSaveRam(self: *SystemMachine) ?[]u8 {
        return switch (self.*) {
            .genesis => |*g| g.persistentSaveRam(),
            .sms => null,
        };
    }

    // -- Save state --

    /// Serialize the machine into a self-describing state buffer. Each
    /// system's format carries its own magic, so loadStateFromBuffer can
    /// dispatch without the caller tracking the variant.
    pub fn saveStateToBuffer(self: *const SystemMachine, allocator: std.mem.Allocator) ![]u8 {
        return switch (self.*) {
            .genesis => |*g| genesis_state_file.saveToBuffer(allocator, g),
            .sms => |*s| sms_state_file.saveToBuffer(allocator, s),
        };
    }

    /// Replace the running machine with one deserialized from a state
    /// buffer. The target system comes from the buffer's magic, so this can
    /// switch variants. On success the old machine is freed and runtime
    /// pointers are rebound; on error self is untouched. Frontend concerns
    /// (audio output resync, recordings) stay with the caller.
    pub fn loadStateFromBuffer(self: *SystemMachine, allocator: std.mem.Allocator, data: []const u8) !void {
        if (data.len >= sms_state_file.magic.len and
            std.mem.eql(u8, data[0..sms_state_file.magic.len], &sms_state_file.magic))
        {
            var next = try sms_state_file.loadFromBuffer(allocator, data);
            errdefer next.deinit(allocator);
            // The SMS format carries no paths; keep the current source path
            // so state and SRAM slots keep resolving after the load.
            if (self.sourcePath()) |sp| try next.bus.setSourcePath(allocator, sp);
            var old = self.*;
            self.* = .{ .sms = next };
            self.rebindRuntimePointers();
            old.deinit(allocator);
            return;
        }
        // The Genesis format restores its own storage paths from the buffer.
        var next = try genesis_state_file.loadFromBuffer(allocator, data);
        errdefer next.deinit(allocator);
        var old = self.*;
        if (old == .genesis) adoptStableSaveRam(&old.genesis, &next);
        self.* = .{ .genesis = next };
        self.rebindRuntimePointers();
        old.deinit(allocator);
    }

    /// Keep the battery-RAM allocation that frontends already hold (libretro
    /// RETRO_MEMORY_SAVE_RAM promises a stable pointer until unload) alive
    /// across a same-system state load: copy the loaded contents into the old
    /// machine's buffer, hand that buffer to the new machine, and let the old
    /// machine's deinit free the replacement instead.
    fn adoptStableSaveRam(old_machine: *Machine, next_machine: *Machine) void {
        const old_cart = &old_machine.bus.cartridge;
        const new_cart = &next_machine.bus.cartridge;
        if (old_cart.ram.data) |old_data| {
            if (new_cart.ram.data) |new_data| {
                if (old_data.len == new_data.len) {
                    @memcpy(old_data, new_data);
                    new_cart.ram.data = old_data;
                    old_cart.ram.data = new_data;
                }
            }
        }
        if (old_cart.mapper == .eeprom_i2c and new_cart.mapper == .eeprom_i2c) {
            const old_eeprom = &old_cart.mapper.eeprom_i2c.eeprom;
            const new_eeprom = &new_cart.mapper.eeprom_i2c.eeprom;
            if (old_eeprom.data.len == new_eeprom.data.len) {
                @memcpy(old_eeprom.data, new_eeprom.data);
                const replacement = new_eeprom.data;
                new_eeprom.data = old_eeprom.data;
                old_eeprom.data = replacement;
            }
        }
    }

    pub fn captureSnapshot(self: *SystemMachine, allocator: std.mem.Allocator) !Snapshot {
        return switch (self.*) {
            .genesis => |*g| .{ .state = .{ .genesis = try g.captureSnapshot(allocator) } },
            .sms => |*s| .{ .state = .{ .sms = try s.captureSnapshot(allocator) } },
        };
    }

    pub fn restoreSnapshot(self: *SystemMachine, allocator: std.mem.Allocator, snapshot: *const Snapshot) !void {
        switch (self.*) {
            .genesis => |*g| {
                switch (snapshot.state) {
                    .genesis => |*gs| try g.restoreSnapshot(allocator, gs),
                    .sms => return error.UnsupportedSaveStateVersion,
                }
            },
            .sms => |*s| {
                switch (snapshot.state) {
                    .sms => |*ss| try s.restoreSnapshot(allocator, ss),
                    .genesis => return error.UnsupportedSaveStateVersion,
                }
            },
        }
    }

    // -- Persistence --

    pub fn flushPersistentStorage(self: *SystemMachine) !void {
        switch (self.*) {
            .genesis => |*g| try g.flushPersistentStorage(),
            .sms => {},
        }
    }

    pub fn rebindRuntimePointers(self: *SystemMachine) void {
        switch (self.*) {
            .genesis => |*g| g.rebindRuntimePointers(),
            .sms => |*s| s.bindPointers(),
        }
    }

    // -- Debug --

    pub fn programCounter(self: *const SystemMachine) u32 {
        return switch (self.*) {
            .genesis => |*g| g.programCounter(),
            .sms => |*s| s.z80.getPc(),
        };
    }

    pub fn debugDump(self: *SystemMachine) void {
        switch (self.*) {
            .genesis => |*g| g.debugDump(),
            .sms => std.debug.print("SMS Z80 running\n", .{}),
        }
    }

    pub fn installDummyTestRom(self: *SystemMachine) void {
        switch (self.*) {
            .genesis => |*g| g.installDummyTestRom(),
            .sms => {},
        }
    }

    // -- Genesis-only accessors (for code that needs them) --

    /// Access the Genesis machine directly. Returns null for SMS.
    pub fn asGenesis(self: *SystemMachine) ?*Machine {
        return switch (self.*) {
            .genesis => &self.genesis,
            .sms => null,
        };
    }

    pub fn asGenesisConst(self: *const SystemMachine) ?*const Machine {
        return switch (self.*) {
            .genesis => &self.genesis,
            .sms => null,
        };
    }

    /// Access the Genesis bus I/O for controller type queries. Returns null for SMS.
    pub fn genesisIo(self: *SystemMachine) ?*Io {
        return switch (self.*) {
            .genesis => &self.genesis.bus.io,
            .sms => null,
        };
    }

    pub fn genesisIoConst(self: *const SystemMachine) ?*const Io {
        return switch (self.*) {
            .genesis => &self.genesis.bus.io,
            .sms => null,
        };
    }

    /// Get the ROM source path (Genesis only, for hard reset).
    pub fn sourcePath(self: *const SystemMachine) ?[]const u8 {
        return switch (self.*) {
            .genesis => |*g| g.bus.sourcePath(),
            .sms => |*s| s.bus.sourcePath(),
        };
    }

    /// Access testing view (Genesis only, for debugger).
    pub fn testing(self: *SystemMachine) ?Machine.TestingView {
        return switch (self.*) {
            .genesis => self.genesis.testing(),
            .sms => null,
        };
    }
};

const testing_alloc = @import("std").testing.allocator;

test "load gg rom from zip" {
    var machine = SystemMachine.init(testing_alloc, "roms/Aerial Assault (World).gg.zip") catch return;
    defer machine.deinit(testing_alloc);
    try @import("std").testing.expectEqual(system_detect.SystemType.gg, machine.systemType());
    machine.runFrame();
    try @import("std").testing.expectEqual(@as(u16, 160), machine.framebufferWidth());
}

test "load sms rom from zip" {
    var machine = SystemMachine.init(testing_alloc, "roms/Paperboy (USA).sms.zip") catch return;
    defer machine.deinit(testing_alloc);
    try @import("std").testing.expectEqual(system_detect.SystemType.sms, machine.systemType());
    machine.runFrame();
    try @import("std").testing.expectEqual(@as(u16, 256), machine.framebufferWidth());
}

test "load genesis smd rom from zip" {
    var machine = SystemMachine.init(testing_alloc, "roms/ros.smd.zip") catch return;
    defer machine.deinit(testing_alloc);
    try @import("std").testing.expectEqual(system_detect.SystemType.genesis, machine.systemType());
    machine.runFrame();
}

test "effectiveRomPath strips .zip suffix" {
    const t = @import("std").testing;
    try t.expectEqualStrings("roms/sonic.md", SystemMachine.effectiveRomPath("roms/sonic.md.zip"));
    try t.expectEqualStrings("roms/sonic.md", SystemMachine.effectiveRomPath("roms/sonic.md"));
    try t.expectEqualStrings("game.gg", SystemMachine.effectiveRomPath("game.gg.ZIP"));
    try t.expectEqualStrings("game.gg", SystemMachine.effectiveRomPath("game.gg.Zip"));
    try t.expectEqualStrings(".zip", SystemMachine.effectiveRomPath(".zip.zip"));
    try t.expectEqualStrings("ab", SystemMachine.effectiveRomPath("ab"));
}

test "state buffer round-trips through the facade and dispatches on magic" {
    const t = @import("std").testing;

    // SMS machine: save, then load back through the facade.
    var sms_rom = [_]u8{0xC7} ** 1024;
    var machine = try SystemMachine.initFromRomBytes(testing_alloc, &sms_rom, .sms);
    defer machine.deinit(testing_alloc);
    machine.runFrame();
    const sms_buf = try machine.saveStateToBuffer(testing_alloc);
    defer testing_alloc.free(sms_buf);
    try machine.loadStateFromBuffer(testing_alloc, sms_buf);
    try t.expectEqual(system_detect.SystemType.sms, machine.systemType());

    // Loading a Genesis buffer into the same instance switches the variant.
    var gen_rom = [_]u8{0} ** 0x400;
    @memcpy(gen_rom[0x100..0x104], "SEGA");
    var gen_machine = try SystemMachine.initFromRomBytes(testing_alloc, &gen_rom, null);
    defer gen_machine.deinit(testing_alloc);
    try t.expectEqual(system_detect.SystemType.genesis, gen_machine.systemType());
    const gen_buf = try gen_machine.saveStateToBuffer(testing_alloc);
    defer testing_alloc.free(gen_buf);
    try machine.loadStateFromBuffer(testing_alloc, gen_buf);
    try t.expectEqual(system_detect.SystemType.genesis, machine.systemType());
    machine.runFrame();

    // A corrupt buffer leaves the machine untouched.
    const junk = [_]u8{0} ** 64;
    try t.expectError(error.InvalidSaveState, machine.loadStateFromBuffer(testing_alloc, &junk));
    try t.expectEqual(system_detect.SystemType.genesis, machine.systemType());
}

test "loadStateFromBuffer keeps the persistent save RAM allocation stable" {
    const t = @import("std").testing;

    // Genesis ROM with a battery-backed SRAM header at 0x200001-0x203FFF.
    var rom = [_]u8{0} ** 0x400;
    @memcpy(rom[0x100..0x104], "SEGA");
    rom[0x1B0] = 'R';
    rom[0x1B1] = 'A';
    rom[0x1B2] = 0xF8;
    rom[0x1B3] = 0x20;
    @import("std").mem.writeInt(u32, rom[0x1B4..0x1B8], 0x200001, .big);
    @import("std").mem.writeInt(u32, rom[0x1B8..0x1BC], 0x203FFF, .big);

    var machine = try SystemMachine.initFromRomBytes(testing_alloc, &rom, null);
    defer machine.deinit(testing_alloc);

    const before = machine.persistentSaveRam().?;
    before[0] = 0xAB;

    const buf = try machine.saveStateToBuffer(testing_alloc);
    defer testing_alloc.free(buf);
    try machine.loadStateFromBuffer(testing_alloc, buf);

    // Frontends (libretro RETRO_MEMORY_SAVE_RAM) hand this pointer out once
    // and hosts read it every frame, so a same-system state load must not
    // move the allocation.
    const after = machine.persistentSaveRam().?;
    try t.expectEqual(before.ptr, after.ptr);
    try t.expectEqual(before.len, after.len);
    try t.expectEqual(@as(u8, 0xAB), after[0]);
}

test "unified setButton maps genesis masks to sms buttons" {
    const t = @import("std").testing;
    var rom = [_]u8{0xC7} ** 1024;
    var machine = try SystemMachine.initFromRomBytes(testing_alloc, &rom, .sms);
    defer machine.deinit(testing_alloc);

    machine.setButton(0, Io.Button.Up, true);
    machine.setButton(0, Io.Button.A, true);
    machine.setButton(1, Io.Button.C, true);
    machine.setButton(0, Io.Button.Start, true);
    const input = &machine.sms.bus.input;
    try t.expect(input.port1.up);
    try t.expect(input.port1.button1);
    try t.expect(input.port2.button2);
    try t.expect(input.pause_pressed);
}

test "zabu demo boots and renders gameplay" {
    const rom_loader_mod = @import("rom_loader.zig");
    const rom_data = rom_loader_mod.readRomFile(testing_alloc, "roms/Zabu_demo_2026-01-24.zip", 8 * 1024 * 1024) catch return;
    defer testing_alloc.free(rom_data);

    var machine = try Machine.initFromRomBytes(testing_alloc, rom_data);
    defer machine.deinit(testing_alloc);
    machine.reset();

    // Press start to get past title screens into gameplay
    for (0..120) |_| machine.runFrame();
    machine.bus.io.setButton(0, Io.Button.Start, true);
    for (0..5) |_| machine.runFrame();
    machine.bus.io.setButton(0, Io.Button.Start, false);
    for (0..300) |_| machine.runFrame();

    const fb = machine.framebuffer();
    var nonblack: usize = 0;
    for (fb) |p| {
        if (p != 0 and p != 0xFF000000) nonblack += 1;
    }
    try @import("std").testing.expect(nonblack > 1000);
}

test "golden axe shadow highlight high priority tiles are not darkened" {
    const screenshot = @import("recording/screenshot.zig");
    var machine = SystemMachine.init(testing_alloc, "roms/Golden Axe.smd") catch return;
    defer machine.deinit(testing_alloc);
    machine.reset();

    // Skip title screens: press start multiple times
    for (0..5) |_| {
        for (0..90) |_| machine.runFrame();
        if (machine.asGenesis()) |g| {
            g.bus.io.setButton(0, @import("input/io.zig").Io.Button.Start, true);
        }
        for (0..5) |_| machine.runFrame();
        if (machine.asGenesis()) |g| {
            g.bus.io.setButton(0, @import("input/io.zig").Io.Button.Start, false);
        }
    }
    // Run into gameplay
    for (0..300) |_| machine.runFrame();

    const fb = machine.framebuffer();
    const w = machine.framebufferWidth();
    const stride = machine.framebufferStride();
    const h: u32 = @intCast(fb.len / stride);
    screenshot.saveBmp("/tmp/golden_axe_sh.bmp", fb, w, h, stride) catch {};

    // Golden Axe uses S/H mode for character shadows on the ground.
    // High-priority tiles (HUD, characters) should not be darkened.
    var bright: usize = 0;
    for (fb) |pixel| {
        const r = (pixel >> 16) & 0xFF;
        const g = (pixel >> 8) & 0xFF;
        const b = pixel & 0xFF;
        if (r > 0x80 or g > 0x80 or b > 0x80) bright += 1;
    }
    // High-priority tiles (HUD, characters, text) should be at normal
    // brightness, not shadowed. With correct S/H priority handling,
    // a significant portion of the screen should have bright pixels.
    try @import("std").testing.expect(bright > 1000);
}
