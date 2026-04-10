const std = @import("std");
const Machine = @import("machine.zig").Machine;
const SmsMachine = @import("sms/machine.zig").SmsMachine;
const SmsInput = @import("sms/input.zig").SmsInput;
const system_detect = @import("system.zig");
const rom_loader = @import("rom_loader.zig");
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
            const effective_path = effectiveRomPath(path);
            const sys = system_detect.detectSystem(rom_data);
            if (sys == .sms or sys == .gg) {
                var sms = try SmsMachine.initFromRomBytes(allocator, rom_data);
                sms.is_game_gear = (sys == .gg);
                allocator.free(rom_data);
                try sms.bus.setSourcePath(allocator, effective_path);
                sms.bindPointers();
                return .{ .sms = sms };
            }
            // Genesis: init from extracted ROM bytes (handles ZIP transparently)
            // and set source path for SRAM resolution.
            var genesis = try Machine.initFromRomBytes(allocator, rom_data);
            allocator.free(rom_data);
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

    pub fn deinit(self: *SystemMachine, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .genesis => |*g| g.deinit(allocator),
            .sms => |*s| s.deinit(allocator),
        }
    }

    pub fn systemType(self: *const SystemMachine) SystemType {
        return switch (self.*) {
            .genesis => .genesis,
            .sms => |*s| if (s.is_game_gear) .gg else .sms,
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

    /// Maximum possible framebuffer width across all systems (for texture allocation).
    pub fn maxFramebufferWidth() u16 {
        return Vdp.framebuffer_width; // 320 (Genesis) >= 256 (SMS)
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
                const sms_clock = @import("sms/clock.zig");
                const lines: u32 = if (s.pal_mode) sms_clock.pal_lines_per_frame else sms_clock.ntsc_lines_per_frame;
                break :blk lines * sms_clock.master_cycles_per_line;
            },
        };
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

    pub fn applyKeyboardBindings(self: *SystemMachine, bindings: *const InputBindings.Bindings) void {
        switch (self.*) {
            .genesis => |*g| g.applyKeyboardBindings(bindings),
            .sms => {},
        }
    }

    pub fn applyGamepadBindings(self: *SystemMachine, bindings: *const InputBindings.Bindings) void {
        switch (self.*) {
            .genesis => |*g| g.applyGamepadBindings(bindings),
            .sms => {},
        }
    }

    pub fn releaseKeyboardBindings(self: *SystemMachine) void {
        switch (self.*) {
            .genesis => |*g| g.releaseKeyboardBindings(),
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

    // -- Save state --

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
    const h: u32 = @intCast(fb.len / w);
    screenshot.saveBmp("/tmp/golden_axe_sh.bmp", fb, w, h) catch {};

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
