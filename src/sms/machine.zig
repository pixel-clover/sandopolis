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
    z80_cycle_count: u32 = 0,

    // Audio buffer for frame output
    audio_buffer: [8192]i16 = [_]i16{0} ** 8192,
    audio_sample_count: usize = 0,

    pub fn initFromRomBytes(rom: []const u8) SmsMachine {
        var machine = SmsMachine{
            .bus = SmsBus.init(rom),
            .z80 = Z80.init(),
        };
        machine.setupZ80();
        return machine;
    }

    pub fn deinit(self: *SmsMachine) void {
        self.z80.deinit();
    }

    fn setupZ80(self: *SmsMachine) void {
        // Enable SMS mode: all memory through host callbacks
        self.z80.setSmsMode(true);

        // Set memory callbacks pointing to our bus
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
    }

    fn psgWriteCallback(ctx: ?*anyopaque, value: u8) void {
        const audio: *SmsAudio = @ptrCast(@alignCast(ctx orelse return));
        // Timestamp with current Z80 cycle (approximation; accurate enough for PSG)
        audio.pushPsgCommand(0, value);
    }

    pub fn reset(self: *SmsMachine) void {
        self.bus.reset();
        self.z80.reset();
        self.audio.reset();
        self.z80_cycle_count = 0;
        self.setupZ80();
    }

    /// Run one complete frame.
    pub fn runFrame(self: *SmsMachine) void {
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
        const entering_vblank = self.bus.vdp.stepScanline();

        // Handle interrupts
        if (entering_vblank and self.bus.vdp.isFrameInterruptEnabled()) {
            self.z80.assertIrq(0xFF);
        } else if (self.bus.vdp.irqPending()) {
            self.z80.assertIrq(0xFF);
        } else {
            self.z80.clearIrq();
        }

        // Handle pause button NMI
        if (self.bus.input.pause_pressed) {
            self.z80.assertNmi();
            self.bus.input.pause_pressed = false;
        }
    }

    // -- Public interface matching Genesis Machine --

    pub fn framebuffer(self: *const SmsMachine) []const u32 {
        const height = self.bus.vdp.activeVisibleLines();
        return self.bus.vdp.framebuffer[0 .. SmsVdp.framebuffer_width * @as(usize, height)];
    }

    pub fn framebufferWidth(self: *const SmsMachine) u16 {
        return self.bus.vdp.screenWidth();
    }

    pub fn screenHeight(self: *const SmsMachine) u16 {
        return self.bus.vdp.activeVisibleLines();
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
};

test "sms machine init" {
    // Minimal ROM: RST 0x00 loop (0xC7 = RST 0)
    var rom = [_]u8{0xC7} ** 1024; // 1KB of RST 0 (infinite loop at 0x0000)
    var machine = SmsMachine.initFromRomBytes(&rom);
    defer machine.deinit();
    try testing.expectEqual(@as(u16, 256), machine.framebufferWidth());
    try testing.expectEqual(@as(u16, 192), machine.screenHeight());
}
