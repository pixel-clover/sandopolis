const std = @import("std");
const testing = std.testing;
const Z80 = @import("../cpu/z80.zig").Z80;
const SmsBus = @import("bus.zig").SmsBus;
const SmsVdp = @import("vdp.zig").SmsVdp;
const SmsAudio = @import("audio.zig").SmsAudio;
const SmsInput = @import("input.zig").SmsInput;
const sms_clock = @import("clock.zig");

/// SMS machine: Z80 CPU + VDP + PSG, coordinated frame loop.
pub const SmsMachine = struct {
    bus: SmsBus,
    z80: Z80,
    audio: SmsAudio = SmsAudio.init(),
    pal_mode: bool = false,
    is_game_gear: bool = false,
    z80_cycle_count: u32 = 0,

    // Audio buffer for frame output
    audio_buffer: [8192]i16 = [_]i16{0} ** 8192,
    audio_sample_count: usize = 0,

    bound: bool = false,

    pub fn initFromRomBytes(alloc: std.mem.Allocator, rom: []const u8) !SmsMachine {
        return SmsMachine{
            .bus = try SmsBus.initOwned(alloc, rom),
            .z80 = Z80.init(),
        };
        // NOTE: do NOT call bindPointers() here. The struct will be moved
        // by value into its final location; pointers would be invalidated.
        // bindPointers() is called lazily on the first runFrame().
    }

    pub fn deinit(self: *SmsMachine, alloc: std.mem.Allocator) void {
        self.bus.deinit(alloc);
        self.z80.deinit();
    }

    /// Rebind all internal self-referential pointers. Must be called after
    /// the SmsMachine reaches its final memory location (e.g., after being
    /// assigned into a heap-allocated WasmEmulator).
    pub fn bindPointers(self: *SmsMachine) void {
        // Propagate GG flag to VDP and I/O
        self.bus.vdp.is_game_gear = self.is_game_gear;
        self.bus.io.is_game_gear = self.is_game_gear;

        // Fix SmsBus internal pointers (io.vdp, io.input)
        self.bus.rebindPointers();

        // Enable SMS mode: all memory through host callbacks
        self.z80.setSmsMode(true);

        // Set memory callbacks pointing to our bus (now at stable address)
        self.z80.setHostCallbacks(
            @ptrCast(&self.bus),
            SmsBus.hostRead,
            SmsBus.hostPeek,
            SmsBus.hostWrite,
            SmsBus.hostM68kBusAccess,
        );

        // Set I/O port callbacks
        self.z80.setPortCallbacks(
            @ptrCast(&self.bus),
            SmsBus.hostPortIn,
            SmsBus.hostPortOut,
        );

        // Set up PSG callback in I/O
        self.bus.io.psg_callback = .{
            .ctx = @ptrCast(&self.audio),
            .write_fn = psgWriteCallback,
        };

        // Wire GG stereo panning callback
        if (self.is_game_gear) {
            self.bus.io.psg_stereo_callback = .{
                .ctx = @ptrCast(&self.audio),
                .write_fn = psgStereoCallback,
            };
        }

        // Set up IRQ clear callback: reading VDP status de-asserts Z80 IRQ immediately
        self.bus.io.irq_clear_callback = .{
            .ctx = @ptrCast(&self.z80),
            .clear_fn = irqClearCallback,
        };

        self.bound = true;
    }

    fn psgWriteCallback(ctx: ?*anyopaque, value: u8) void {
        const audio: *SmsAudio = @ptrCast(@alignCast(ctx orelse return));
        audio.pushPsgCommand(0, value);
    }

    fn psgStereoCallback(ctx: ?*anyopaque, value: u8) void {
        const audio: *SmsAudio = @ptrCast(@alignCast(ctx orelse return));
        audio.psg.setPanning(value);
    }

    fn irqClearCallback(ctx: ?*anyopaque) void {
        const z80: *Z80 = @ptrCast(@alignCast(ctx orelse return));
        z80.clearIrq();
    }

    pub fn reset(self: *SmsMachine) void {
        self.bus.reset();
        self.z80.reset();
        self.audio.reset();
        self.z80_cycle_count = 0;
        self.bindPointers();
    }

    /// Run one complete frame.
    pub fn runFrame(self: *SmsMachine) void {
        if (!self.bound) self.bindPointers();
        const total_lines = self.bus.vdp.totalLines();
        self.bus.vdp.beginFrame();
        self.z80_cycle_count = 0;

        for (0..total_lines) |_| {
            self.runScanline();
        }

        // Render audio for this frame
        self.audio_sample_count = self.audio.renderFrame(self.pal_mode, &self.audio_buffer);
    }

    fn runScanline(self: *SmsMachine) void {
        // Run Z80 for one scanline worth of cycles
        const target_cycles = self.z80_cycle_count + sms_clock.z80_cycles_per_line;

        while (self.z80_cycle_count < target_cycles) {
            const cycles = self.z80.stepInstruction();
            self.z80_cycle_count += cycles;
        }

        // Advance VDP
        _ = self.bus.vdp.stepScanline();

        // Handle interrupts: IRQ stays asserted as long as any enabled interrupt is pending.
        // The VDP status read (port 0xBF) clears the pending flags.
        if (self.bus.vdp.irqPending()) {
            self.z80.assertIrq(0xFF);
        } else {
            self.z80.clearIrq();
        }

        // Handle pause button NMI (SMS only; GG START is read via port 0x00)
        if (!self.is_game_gear and self.bus.input.pause_pressed) {
            self.z80.assertNmi();
            self.bus.input.pause_pressed = false;
        }
    }

    // -- Public interface matching Genesis Machine --

    pub fn framebuffer(self: *const SmsMachine) []const u32 {
        const w: usize = self.bus.vdp.screenWidth();
        const h: usize = self.bus.vdp.displayHeight();
        return self.bus.vdp.framebuffer[0 .. w * h];
    }

    pub fn framebufferWidth(self: *const SmsMachine) u16 {
        return self.bus.vdp.screenWidth();
    }

    pub fn screenHeight(self: *const SmsMachine) u16 {
        return self.bus.vdp.displayHeight();
    }

    pub fn isPal(self: *const SmsMachine) bool {
        return self.pal_mode;
    }

    pub fn setButton(self: *SmsMachine, port: u1, button: SmsInput.Button, pressed: bool) void {
        self.bus.input.setButton(port, button, pressed);
    }

    pub fn softReset(self: *SmsMachine) void {
        self.reset();
    }

    pub fn audioBuffer(self: *const SmsMachine) []const i16 {
        return self.audio_buffer[0 .. self.audio_sample_count * 2];
    }

    // -- Save state --

    pub const Snapshot = struct {
        machine: SmsMachine,

        pub fn deinit(self: *Snapshot, alloc: std.mem.Allocator) void {
            self.machine.deinit(alloc);
        }
    };

    pub fn clone(self: *const SmsMachine, alloc: std.mem.Allocator) !SmsMachine {
        return SmsMachine{
            .bus = try self.bus.clone(alloc),
            .z80 = try self.z80.clone(),
            .audio = self.audio,
            .pal_mode = self.pal_mode,
            .is_game_gear = self.is_game_gear,
            .z80_cycle_count = self.z80_cycle_count,
            .audio_buffer = self.audio_buffer,
            .audio_sample_count = self.audio_sample_count,
            .bound = false, // Will be rebound on next runFrame or explicit bindPointers
        };
    }

    pub fn captureSnapshot(self: *const SmsMachine, alloc: std.mem.Allocator) !Snapshot {
        return .{ .machine = try self.clone(alloc) };
    }

    pub fn restoreSnapshot(self: *SmsMachine, alloc: std.mem.Allocator, snapshot: *const Snapshot) !void {
        const next = try snapshot.machine.clone(alloc);
        var old = self.*;
        self.* = next;
        self.bindPointers();
        old.deinit(alloc);
    }
};

test "sms machine init" {
    // Minimal ROM: RST 0x00 loop (0xC7 = RST 0)
    var rom = [_]u8{0xC7} ** 1024; // 1KB of RST 0 (infinite loop at 0x0000)
    var machine = try SmsMachine.initFromRomBytes(testing.allocator, &rom);
    defer machine.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 256), machine.framebufferWidth());
    try testing.expectEqual(@as(u16, 192), machine.screenHeight());
}

test "sms machine run frames produces visible output" {
    const rom_data = std.fs.cwd().readFileAlloc(testing.allocator, "roms/Pac-Mania (Europe).sms", 8 * 1024 * 1024) catch return;
    defer testing.allocator.free(rom_data);

    var machine = try SmsMachine.initFromRomBytes(testing.allocator, rom_data);
    defer machine.deinit(testing.allocator);
    machine.bindPointers();

    for (0..300) |_| machine.runFrame();

    // After 300 frames, the game should have visible pixels
    const fb = machine.framebuffer();
    var nonblack: usize = 0;
    for (fb) |pixel| {
        if (pixel != 0 and pixel != 0xFF000000) nonblack += 1;
    }
    try testing.expect(nonblack > 100);
}

test "sms machine save and restore state" {
    var rom = [_]u8{0} ** 1024;
    // LD A, 0xE0; OUT (0xBF), A; LD A, 0x81; OUT (0xBF), A; JR -2 (loop)
    rom[0] = 0x3E;
    rom[1] = 0xE0;
    rom[2] = 0xD3;
    rom[3] = 0xBF;
    rom[4] = 0x3E;
    rom[5] = 0x81;
    rom[6] = 0xD3;
    rom[7] = 0xBF;
    rom[8] = 0x18;
    rom[9] = 0xFE;

    var machine = try SmsMachine.initFromRomBytes(testing.allocator, &rom);
    defer machine.deinit(testing.allocator);
    machine.bindPointers();

    // Run a few frames to establish state
    for (0..10) |_| machine.runFrame();

    // Capture snapshot
    var snapshot = try machine.captureSnapshot(testing.allocator);
    defer snapshot.deinit(testing.allocator);

    // VDP reg 1 should be 0xE0 from the ROM program
    try testing.expectEqual(@as(u8, 0xE0), snapshot.machine.bus.vdp.regs[1]);

    // Run more frames to change state
    for (0..10) |_| machine.runFrame();

    // Restore snapshot
    try machine.restoreSnapshot(testing.allocator, &snapshot);

    // State should be restored
    try testing.expectEqual(@as(u8, 0xE0), machine.bus.vdp.regs[1]);
}

test "sms aladdin shows graphics after extended init" {
    const rom_data = std.fs.cwd().readFileAlloc(testing.allocator, "roms/Disney's Aladdin (Europe).sms", 8 * 1024 * 1024) catch return;
    defer testing.allocator.free(rom_data);

    var machine = try SmsMachine.initFromRomBytes(testing.allocator, rom_data);
    defer machine.deinit(testing.allocator);
    machine.bindPointers();

    // Aladdin's init decompresses tiles (~112 frames), then enables display.
    // The game requires proper VDP IRQ de-assertion on status read to avoid
    // spurious interrupt re-triggering after the handler reads VDP status.
    for (0..200) |_| machine.runFrame();

    const fb = machine.framebuffer();
    var nonblack: usize = 0;
    for (fb) |pixel| {
        if (pixel != 0 and pixel != 0xFF000000) nonblack += 1;
    }
    try testing.expect(nonblack > 100);
}

test "sms vdp register write via z80 port" {
    // ROM that writes VDP register 1 = 0xE0 (display enable + frame interrupt + Mode 4)
    // Z80 instructions: OUT (0xBF), A (= data), then OUT (0xBF), A (= reg command)
    // LD A, 0xE0; OUT (0xBF), A; LD A, 0x81; OUT (0xBF), A; JR -4 (loop)
    var rom = [_]u8{0} ** 1024;
    rom[0] = 0x3E; // LD A, 0xE0
    rom[1] = 0xE0;
    rom[2] = 0xD3; // OUT (0xBF), A
    rom[3] = 0xBF;
    rom[4] = 0x3E; // LD A, 0x81 (code=2, reg=1)
    rom[5] = 0x81;
    rom[6] = 0xD3; // OUT (0xBF), A
    rom[7] = 0xBF;
    rom[8] = 0x18; // JR -2 (loop back to JR itself = tight loop)
    rom[9] = 0xFE;

    var machine = try SmsMachine.initFromRomBytes(testing.allocator, &rom);
    defer machine.deinit(testing.allocator);
    machine.bindPointers();

    // Run one frame; the Z80 should execute the OUT instructions
    machine.runFrame();

    // VDP register 1 should now be 0xE0
    try testing.expectEqual(@as(u8, 0xE0), machine.bus.vdp.regs[1]);
    // Display should be enabled
    try testing.expect(machine.bus.vdp.isDisplayEnabled());
}

test "gg aerial assault detected and produces visible output" {
    const system_detect = @import("../system.zig");
    const rom_data = std.fs.cwd().readFileAlloc(testing.allocator, "roms/Aerial Assault (World).gg", 8 * 1024 * 1024) catch return;
    defer testing.allocator.free(rom_data);

    try testing.expectEqual(system_detect.SystemType.gg, system_detect.detectSystem(rom_data));

    var machine = SmsMachine{
        .bus = try SmsBus.initOwned(testing.allocator, rom_data),
        .z80 = Z80.init(),
        .is_game_gear = true,
    };
    defer machine.deinit(testing.allocator);
    machine.bindPointers();

    try testing.expectEqual(@as(u16, 160), machine.framebufferWidth());
    try testing.expectEqual(@as(u16, 144), machine.screenHeight());

    for (0..200) |_| machine.runFrame();

    const fb = machine.framebuffer();
    try testing.expectEqual(@as(usize, 160 * 144), fb.len);

    var nonblack: usize = 0;
    for (fb) |pixel| {
        if (pixel != 0 and pixel != 0xFF000000) nonblack += 1;
    }
    try testing.expect(nonblack > 100);
}

test "gg addams family detected and produces visible output" {
    const system_detect = @import("../system.zig");
    const rom_data = std.fs.cwd().readFileAlloc(testing.allocator, "roms/Addams Family, The (World).gg", 8 * 1024 * 1024) catch return;
    defer testing.allocator.free(rom_data);

    try testing.expectEqual(system_detect.SystemType.gg, system_detect.detectSystem(rom_data));

    var machine = SmsMachine{
        .bus = try SmsBus.initOwned(testing.allocator, rom_data),
        .z80 = Z80.init(),
        .is_game_gear = true,
    };
    defer machine.deinit(testing.allocator);
    machine.bindPointers();

    for (0..600) |_| machine.runFrame();

    const fb = machine.framebuffer();
    try testing.expectEqual(@as(usize, 160 * 144), fb.len);

    var nonblack: usize = 0;
    for (fb) |pixel| {
        if (pixel != 0 and pixel != 0xFF000000) nonblack += 1;
    }
    try testing.expect(nonblack > 100);
}

test "gg 5 in one funpak detected and produces visible output" {
    const system_detect = @import("../system.zig");
    const rom_data = std.fs.cwd().readFileAlloc(testing.allocator, "roms/5 in One FunPak (USA).gg", 8 * 1024 * 1024) catch return;
    defer testing.allocator.free(rom_data);

    try testing.expectEqual(system_detect.SystemType.gg, system_detect.detectSystem(rom_data));

    var machine = SmsMachine{
        .bus = try SmsBus.initOwned(testing.allocator, rom_data),
        .z80 = Z80.init(),
        .is_game_gear = true,
    };
    defer machine.deinit(testing.allocator);
    machine.bindPointers();

    for (0..200) |_| machine.runFrame();

    const fb = machine.framebuffer();
    try testing.expectEqual(@as(usize, 160 * 144), fb.len);

    var nonblack: usize = 0;
    for (fb) |pixel| {
        if (pixel != 0 and pixel != 0xFF000000) nonblack += 1;
    }
    try testing.expect(nonblack > 100);
}

test "gg batman robin detected and produces visible output" {
    const system_detect = @import("../system.zig");
    const rom_data = std.fs.cwd().readFileAlloc(testing.allocator, "roms/Adventures of Batman & Robin, The (USA, Europe) (Beta) (1995-05-02).gg", 8 * 1024 * 1024) catch return;
    defer testing.allocator.free(rom_data);

    try testing.expectEqual(system_detect.SystemType.gg, system_detect.detectSystem(rom_data));

    var machine = SmsMachine{
        .bus = try SmsBus.initOwned(testing.allocator, rom_data),
        .z80 = Z80.init(),
        .is_game_gear = true,
    };
    defer machine.deinit(testing.allocator);
    machine.bindPointers();

    for (0..200) |_| machine.runFrame();

    const fb = machine.framebuffer();
    try testing.expectEqual(@as(usize, 160 * 144), fb.len);

    var nonblack: usize = 0;
    for (fb) |pixel| {
        if (pixel != 0 and pixel != 0xFF000000) nonblack += 1;
    }
    try testing.expect(nonblack > 100);
}
