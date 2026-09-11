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
const scd_state_file = @import("scd/state_file.zig");
const scd_bios = @import("scd/bios.zig");
const Disc = @import("scd/cdrom/reader.zig").Disc;
const PendingAudioFrames = @import("audio/timing.zig").PendingAudioFrames;
const CoreFrameCounters = @import("performance_profile.zig").CoreFrameCounters;
const Vdp = @import("video/vdp.zig").Vdp;
const Z80 = @import("cpu/z80.zig").Z80;
const Io = @import("input/io.zig").Io;
const InputBindings = @import("input/mapping.zig");

/// System family a save-state buffer belongs to, derived from its magic.
pub const StateSystem = enum { genesis, sms, segacd };

const StateFormat = struct { magic: [8]u8, system: StateSystem };
const state_formats = [_]StateFormat{
    .{ .magic = sms_state_file.magic, .system = .sms },
    .{ .magic = scd_state_file.magic, .system = .segacd },
    .{ .magic = genesis_state_file.magic, .system = .genesis },
};

/// Classify a state buffer by its leading magic. Null for unknown or short
/// buffers; callers decide whether that is an error.
pub fn classifyStateBuffer(data: []const u8) ?StateSystem {
    if (data.len < 8) return null;
    for (state_formats) |format| {
        if (std.mem.eql(u8, data[0..8], &format.magic)) return format.system;
    }
    return null;
}

/// System-agnostic machine wrapper that dispatches to Genesis or SMS.
pub const SystemMachine = union(enum) {
    genesis: Machine,
    sms: SmsMachine,

    pub const SystemType = system_detect.SystemType;
    pub const BiosSet = scd_bios.BiosSet;
    pub const BiosRegion = scd_bios.BiosRegion;

    /// Options that only matter for systems needing firmware (Sega CD).
    /// Cartridge systems ignore them.
    pub const InitOptions = struct {
        /// BIOS images by region; borrowed for the machine's lifetime.
        bios: ?*const BiosSet = null,
        /// Force a BIOS region instead of following the disc header.
        preferred_bios_region: ?BiosRegion = null,
    };

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
        return initWithOptions(allocator, rom_path, .{});
    }

    pub fn initWithOptions(allocator: std.mem.Allocator, rom_path: ?[]const u8, options: InitOptions) !SystemMachine {
        if (rom_path) |path| {
            // Disc images are opened lazily by the disc layer; never slurp them.
            if (system_detect.detectSystemFromExtension(path) == .segacd) {
                return initSegaCdFromPath(allocator, path, options);
            }
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
            // Sega CD needs a BIOS and a disc reader; the facade arm lands
            // with the sub-board. Until then, refuse clearly instead of
            // booting a disc image as a cartridge.
            if (sys == .segacd) {
                // Content-detected raw disc image handed over as a file.
                const disc = try Disc.fromMemory(allocator, discSheetForImage(rom_data), &.{rom_data});
                return initSegaCdFromDisc(allocator, disc, options);
            }
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
        return initFromRomBytesWithOptions(allocator, raw_bytes, system_hint, .{});
    }

    pub fn initFromRomBytesWithOptions(
        allocator: std.mem.Allocator,
        raw_bytes: []const u8,
        system_hint: ?SystemType,
        options: InitOptions,
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
            .segacd => {
                const disc = try Disc.fromMemory(allocator, discSheetForImage(rom_bytes), &.{rom_bytes});
                return initSegaCdFromDisc(allocator, disc, options);
            },
        }
    }

    fn initSegaCdFromPath(allocator: std.mem.Allocator, path: []const u8, options: InitOptions) !SystemMachine {
        const ext = std.fs.path.extension(path);
        const disc = if (std.ascii.eqlIgnoreCase(ext, ".cue"))
            try Disc.openCuePath(allocator, path)
        else
            try Disc.openIsoPath(allocator, path);
        var machine = try initSegaCdFromDisc(allocator, disc, options);
        errdefer machine.deinit(allocator);
        const source_copy = try allocator.dupe(u8, path);
        machine.genesis.bus.replaceStoragePaths(allocator, null, source_copy);
        // Internal backup RAM persists next to the disc's other data files.
        const rom_paths = @import("rom_paths.zig");
        if (rom_paths.romDataPath(allocator, path, "backup.brm")) |bram_path| {
            defer allocator.free(bram_path);
            machine.genesis.scd.?.setBackupRamPath(bram_path) catch {};
        } else |_| {}
        return machine;
    }

    /// Select a BIOS for the disc and build the machine. Takes ownership of
    /// `disc` on success (and frees it on failure).
    pub fn initSegaCdFromDisc(allocator: std.mem.Allocator, disc: Disc, options: InitOptions) !SystemMachine {
        var mutable_disc = disc;
        errdefer mutable_disc.deinit();
        const bios_set = options.bios orelse return error.BiosMissing;
        var sector0: [2352]u8 = undefined;
        const disc_region: ?BiosRegion = if (mutable_disc.readSector(0, &sector0)) |_|
            scd_bios.discRegion(sector0[16..])
        else |_|
            null;
        const region = try bios_set.selectForDisc(disc_region, options.preferred_bios_region);
        const bios = bios_set.get(region).?;
        try scd_bios.validate(bios);
        const genesis = try Machine.initSegaCd(allocator, bios, mutable_disc);
        return .{ .genesis = genesis };
    }

    /// Raw disc bytes: 2352-byte sectors carry the signature after the
    /// 16-byte sync/header; otherwise treat as a 2048-byte ISO.
    fn discSheetForImage(bytes: []const u8) ?[]const u8 {
        if (bytes.len >= 30 and std.mem.eql(u8, bytes[16..30], system_detect.sega_cd_disc_signature)) {
            return "FILE \"image.bin\" BINARY\n  TRACK 01 MODE1/2352\n    INDEX 01 00:00:00\n";
        }
        return null;
    }

    pub fn deinit(self: *SystemMachine, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .genesis => |*g| g.deinit(allocator),
            .sms => |*s| s.deinit(allocator),
        }
    }

    pub fn systemType(self: *const SystemMachine) SystemType {
        return switch (self.*) {
            .genesis => |*g| if (g.isSegaCd()) .segacd else .genesis,
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
            // The Sega CD container format lands with the sub-board state;
            // a plain Genesis state would silently drop the disc system.
            .genesis => |*g| if (g.isSegaCd()) scd_state_file.saveToBuffer(allocator, g) else genesis_state_file.saveToBuffer(allocator, g),
            .sms => |*s| sms_state_file.saveToBuffer(allocator, s),
        };
    }

    /// Replace the running machine with one deserialized from a state
    /// buffer. The target system comes from the buffer's magic, so this can
    /// switch variants. On success the old machine is freed and runtime
    /// pointers are rebound; on error self is untouched. Frontend concerns
    /// (audio output resync, recordings) stay with the caller.
    pub fn loadStateFromBuffer(self: *SystemMachine, allocator: std.mem.Allocator, data: []const u8) !void {
        const target = classifyStateBuffer(data) orelse return error.InvalidSaveState;
        if (target == .segacd) {
            // Box the incoming machine (stack budget, see scd/state_file.zig)
            // and replace self in place instead of copying the old machine out.
            const next = try allocator.create(Machine);
            defer allocator.destroy(next);
            next.* = try scd_state_file.loadFromBuffer(allocator, data);
            errdefer next.deinit(allocator);
            if (self.* == .genesis and self.genesis.isSegaCd()) adoptStableScdBoard(&self.genesis, next);
            self.deinit(allocator);
            self.* = .{ .genesis = next.* };
            self.rebindRuntimePointers();
            return;
        }
        if (target == .sms) {
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

    /// Keep the sub-board allocation (and so the RETRO_MEMORY_SAVE_RAM
    /// pointer into its backup RAM) stable across a CD-to-CD state load by
    /// moving the loaded board's contents into the old allocation.
    fn adoptStableScdBoard(old_machine: *Machine, next_machine: *Machine) void {
        const old_board = old_machine.scd orelse return;
        const new_board = next_machine.scd orelse return;
        // Swap the whole structs: the new machine now owns the old
        // allocation (with the new contents), the old machine frees the
        // other one on deinit. If the temporary cannot be allocated the
        // pointer simply changes, which is still a correct load.
        old_board.swapContents(new_board) catch return;
        next_machine.scd = old_board;
        old_machine.scd = new_board;
    }

    /// True when a state buffer targets the same system family as the
    /// running machine. loadStateFromBuffer can switch the variant, but
    /// libretro requires serialize size, geometry, and region to stay
    /// stable within a session, so retro_unserialize must reject
    /// cross-family buffers instead of switching.
    pub fn stateBufferMatchesSystem(self: *const SystemMachine, data: []const u8) bool {
        const target = classifyStateBuffer(data) orelse return false;
        return switch (self.*) {
            .sms => target == .sms,
            .genesis => |*g| if (g.isSegaCd()) target == .segacd else target == .genesis,
        };
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

test "stateBufferMatchesSystem distinguishes system families by magic" {
    const t = @import("std").testing;

    var sms_rom = [_]u8{0xC7} ** 1024;
    var sms_machine = try SystemMachine.initFromRomBytes(testing_alloc, &sms_rom, .sms);
    defer sms_machine.deinit(testing_alloc);
    const sms_buf = try sms_machine.saveStateToBuffer(testing_alloc);
    defer testing_alloc.free(sms_buf);

    var gen_rom = [_]u8{0} ** 0x400;
    @memcpy(gen_rom[0x100..0x104], "SEGA");
    var gen_machine = try SystemMachine.initFromRomBytes(testing_alloc, &gen_rom, null);
    defer gen_machine.deinit(testing_alloc);
    const gen_buf = try gen_machine.saveStateToBuffer(testing_alloc);
    defer testing_alloc.free(gen_buf);

    try t.expect(sms_machine.stateBufferMatchesSystem(sms_buf));
    try t.expect(gen_machine.stateBufferMatchesSystem(gen_buf));
    try t.expect(!sms_machine.stateBufferMatchesSystem(gen_buf));
    try t.expect(!gen_machine.stateBufferMatchesSystem(sms_buf));
    // Short/garbage buffers carry no known magic and match nothing.
    try t.expect(!sms_machine.stateBufferMatchesSystem("junk"));
    try t.expect(!gen_machine.stateBufferMatchesSystem("junk"));
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

test "classifyStateBuffer maps every known magic and rejects junk" {
    const t = @import("std").testing;

    var sms_hdr = [_]u8{0} ** 16;
    @memcpy(sms_hdr[0..8], &sms_state_file.magic);
    try t.expectEqual(StateSystem.sms, classifyStateBuffer(&sms_hdr).?);

    var gen_hdr = [_]u8{0} ** 16;
    @memcpy(gen_hdr[0..8], &genesis_state_file.magic);
    try t.expectEqual(StateSystem.genesis, classifyStateBuffer(&gen_hdr).?);

    var scd_hdr = [_]u8{0} ** 16;
    @memcpy(scd_hdr[0..8], &scd_state_file.magic);
    try t.expectEqual(StateSystem.segacd, classifyStateBuffer(&scd_hdr).?);

    try t.expect(classifyStateBuffer("junk") == null);
    try t.expect(classifyStateBuffer("SNDSXXXX........") == null);

    // A Genesis machine must not accept a Sega CD buffer as same-family.
    var gen_rom = [_]u8{0} ** 0x400;
    @memcpy(gen_rom[0x100..0x104], "SEGA");
    var gen_machine = try SystemMachine.initFromRomBytes(testing_alloc, &gen_rom, null);
    defer gen_machine.deinit(testing_alloc);
    try t.expect(!gen_machine.stateBufferMatchesSystem(&scd_hdr));
    try t.expect(!gen_machine.stateBufferMatchesSystem("junk"));
}

test "initWithOptions refuses a disc image without a BIOS and delegates otherwise" {
    const t = @import("std").testing;
    // No BIOS configured: a Sega CD disc cannot boot.
    var iso = [_]u8{0} ** 0x800;
    @memcpy(iso[0..14], "SEGADISCSYSTEM");
    try t.expectError(error.BiosMissing, SystemMachine.initFromRomBytesWithOptions(testing_alloc, &iso, null, .{}));

    // Cartridge systems ignore the BIOS options entirely.
    var gen_rom = [_]u8{0} ** 0x400;
    @memcpy(gen_rom[0x100..0x104], "SEGA");
    var machine = try SystemMachine.initFromRomBytesWithOptions(testing_alloc, &gen_rom, null, .{ .preferred_bios_region = .jp });
    defer machine.deinit(testing_alloc);
    try t.expectEqual(SystemMachine.SystemType.genesis, machine.systemType());
}

test "facade boots a sega cd from bios bytes and an in-memory iso" {
    const t = @import("std").testing;
    const bios = try testing_alloc.alloc(u8, 128 * 1024);
    defer testing_alloc.free(bios);
    @memset(bios, 0);
    @memcpy(bios[0x100..0x104], "SEGA");
    std.mem.writeInt(u32, bios[0..4], 0x00FFFE00, .big);
    std.mem.writeInt(u32, bios[4..8], 0x00000200, .big);
    bios[0x200] = 0x60; // bra.s *
    bios[0x201] = 0xFE;

    var iso = [_]u8{0} ** (2 * 2048);
    @memcpy(iso[0..14], "SEGADISCSYSTEM");
    iso[0x1F0] = 'U';

    // No US BIOS available: selection falls back to the only image.
    const set = SystemMachine.BiosSet{ .eu = bios };
    var machine = try SystemMachine.initFromRomBytesWithOptions(testing_alloc, &iso, null, .{ .bios = &set });
    defer machine.deinit(testing_alloc);
    try t.expectEqual(SystemMachine.SystemType.segacd, machine.systemType());
    machine.reset();
    machine.runFrame();
    machine.discardPendingAudio();
    try t.expectEqual(@as(u32, 0x200), machine.programCounter());

    // A forced region that is not present is an error.
    try t.expectError(error.BiosMissing, SystemMachine.initFromRomBytesWithOptions(testing_alloc, &iso, null, .{ .bios = &set, .preferred_bios_region = .jp }));
    // A wrong-sized BIOS is rejected.
    const short = SystemMachine.BiosSet{ .us = bios[0..0x1000] };
    try t.expectError(error.BiosWrongSize, SystemMachine.initFromRomBytesWithOptions(testing_alloc, &iso, null, .{ .bios = &short }));
    // Snapshots clone the sub-board and keep the (memory) disc.
    var snap = try machine.captureSnapshot(testing_alloc);
    defer snap.deinit(testing_alloc);
    try machine.restoreSnapshot(testing_alloc, &snap);
    try t.expect(machine.genesis.scd.?.disc != null);

    // State saving uses the Sega CD container and only matches CD machines.
    const state = try machine.saveStateToBuffer(testing_alloc);
    defer testing_alloc.free(state);
    try t.expectEqual(StateSystem.segacd, classifyStateBuffer(state).?);
    try t.expect(machine.stateBufferMatchesSystem(state));
    const board_before = machine.genesis.scd.?;
    try machine.loadStateFromBuffer(testing_alloc, state);
    try t.expectEqual(SystemMachine.SystemType.segacd, machine.systemType());
    // The board allocation (libretro save-RAM pointer) survived the load.
    try t.expectEqual(board_before, machine.genesis.scd.?);
    // A memory-backed disc has no path to reopen from: the drive is empty.
    try t.expect(machine.genesis.scd.?.disc == null);
}
