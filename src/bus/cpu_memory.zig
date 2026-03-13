const std = @import("std");
const Cartridge = @import("cartridge.zig").Cartridge;
const io_window = @import("io_window.zig");
const vdp_ports = @import("vdp_ports.zig");
const clock = @import("../clock.zig");
const AudioTiming = @import("../audio/timing.zig").AudioTiming;
const Vdp = @import("../video/vdp.zig").Vdp;
const Io = @import("../input/io.zig").Io;
const Z80 = @import("../cpu/z80.zig").Z80;
const cpu_runtime = @import("../cpu/runtime_state.zig");

pub const View = struct {
    cartridge: *Cartridge,
    ram: *[64 * 1024]u8,
    vdp: *Vdp,
    io: *Io,
    z80: *Z80,
    audio_timing: *AudioTiming,
    open_bus: *u16,
    runtime_state: *cpu_runtime.RuntimeState,
    ensure_z80_host_window_ctx: ?*anyopaque,
    ensure_z80_host_window_fn: *const fn (?*anyopaque) void,

    pub fn init(
        cartridge: *Cartridge,
        ram: *[64 * 1024]u8,
        vdp: *Vdp,
        io: *Io,
        z80: *Z80,
        audio_timing: *AudioTiming,
        open_bus: *u16,
        runtime_state: *cpu_runtime.RuntimeState,
        ensure_z80_host_window_ctx: ?*anyopaque,
        ensure_z80_host_window_fn: *const fn (?*anyopaque) void,
    ) View {
        return .{
            .cartridge = cartridge,
            .ram = ram,
            .vdp = vdp,
            .io = io,
            .z80 = z80,
            .audio_timing = audio_timing,
            .open_bus = open_bus,
            .runtime_state = runtime_state,
            .ensure_z80_host_window_ctx = ensure_z80_host_window_ctx,
            .ensure_z80_host_window_fn = ensure_z80_host_window_fn,
        };
    }

    fn ensureZ80HostWindow(self: *View) void {
        self.ensure_z80_host_window_fn(self.ensure_z80_host_window_ctx);
    }

    fn isZ80WindowAddress(address: u32) bool {
        const addr = address & 0xFFFFFF;
        return addr >= 0xA00000 and addr < 0xA10000;
    }

    fn isZ80BusAckPage(address: u32) bool {
        const addr = address & 0xFFFFFF;
        return addr >= 0xA11100 and addr < 0xA11200;
    }

    fn isZ80ResetPage(address: u32) bool {
        const addr = address & 0xFFFFFF;
        return addr >= 0xA11200 and addr < 0xA11300;
    }

    fn hasZ80BusFor68k(self: *View) bool {
        return self.z80.readBusReq() == 0x0000;
    }

    fn singleM68kAccessWaitMasterCycles(self: *View, address: u32) u32 {
        if (!isZ80WindowAddress(address)) return 0;
        if (!self.hasZ80BusFor68k()) return 0;
        return clock.m68kCyclesToMaster(1);
    }

    pub fn m68kAccessWaitMasterCycles(self: *View, address: u32, size_bytes: u8) u32 {
        var wait = self.singleM68kAccessWaitMasterCycles(address);
        if (size_bytes >= 4) {
            wait += self.singleM68kAccessWaitMasterCycles(address + 2);
        }
        return wait;
    }

    fn latchOpenBus(self: *View, value: u16) u16 {
        self.open_bus.* = value;
        return value;
    }

    fn openBusByte(self: *const View, address: u32) u8 {
        return if ((address & 1) == 0)
            @truncate((self.open_bus.* >> 8) & 0xFF)
        else
            @truncate(self.open_bus.* & 0xFF);
    }

    fn readMirroredZ80ControlRegister(self: *View, control_word: u16) u16 {
        const control_bits: u16 = if ((control_word & 0x0100) != 0) 0x0100 else 0x0000;
        return self.latchOpenBus((self.open_bus.* & ~@as(u16, 0x0100)) | control_bits);
    }

    fn readZ80BusAckRegister(self: *View) u16 {
        return self.readMirroredZ80ControlRegister(self.z80.readBusReq());
    }

    pub fn setCpuRuntimeState(self: *View, state: cpu_runtime.RuntimeState) void {
        self.runtime_state.* = state;
    }

    pub fn clearCpuRuntimeState(self: *View) void {
        self.runtime_state.clear();
    }

    pub fn dataPortReadWaitMasterCycles(self: *View) u32 {
        return self.vdp.dataPortReadWaitMasterCycles();
    }

    pub fn reserveDataPortWriteWaitMasterCycles(self: *View) u32 {
        return self.vdp.reserveDataPortWriteWaitMasterCycles();
    }

    pub fn controlPortWriteWaitMasterCycles(self: *View) u32 {
        return self.vdp.controlPortWriteWaitMasterCycles();
    }

    pub fn read8(self: *View, address: u32) u8 {
        const addr = address & 0xFFFFFF;

        if (self.cartridge.readByte(addr)) |value| {
            return value;
        }

        if (isZ80BusAckPage(addr)) {
            if ((addr & 1) == 0) return @truncate((self.readZ80BusAckRegister() >> 8) & 0xFF);
            return self.openBusByte(addr);
        }
        if (isZ80ResetPage(addr)) return self.openBusByte(addr);

        if (addr < 0xA00000) {
            return self.cartridge.readRomByte(addr);
        } else if (addr >= 0xE00000 and addr < 0x1000000) {
            return self.ram[addr & 0xFFFF];
        } else if (addr >= 0xA00000 and addr < 0xA10000) {
            if (!self.hasZ80BusFor68k()) return @truncate((self.open_bus.* >> 8) & 0xFF);
            self.ensureZ80HostWindow();
            self.z80.setAudioMasterOffset(self.audio_timing.pending_master_cycles);
            const zaddr: u16 = @truncate(addr & 0x7FFF);
            return self.z80.readByte(zaddr);
        } else if (addr >= 0xC00000 and addr <= 0xDFFFFF) {
            return vdp_ports.readByte(self.vdp, self.open_bus, self.runtime_state, addr);
        } else if (addr >= 0xA10000 and addr < 0xA10020) {
            return io_window.readRegisterByte(self.io, self.vdp.pal_mode, addr);
        } else if (addr >= 0xA10020 and addr < 0xA10100) {
            return self.openBusByte(addr);
        }

        return 0;
    }

    pub fn peek8NoSideEffects(self: *View, address: u32) u8 {
        const addr = address & 0xFFFFFF;

        if (self.cartridge.readByte(addr)) |value| {
            return value;
        }

        if (addr < 0xA00000) return self.cartridge.readRomByte(addr);
        if (addr >= 0xE00000 and addr < 0x1000000) return self.ram[addr & 0xFFFF];

        return 0xFF;
    }

    pub fn read16(self: *View, address: u32) u16 {
        const addr = address & 0xFFFFFF;
        if (self.cartridge.readWord(addr)) |value| {
            return self.latchOpenBus(value);
        }
        if (isZ80BusAckPage(addr)) {
            return self.readZ80BusAckRegister();
        } else if (isZ80ResetPage(addr)) {
            return self.latchOpenBus(self.open_bus.*);
        } else if (addr >= 0xA00000 and addr < 0xA10000 and !self.hasZ80BusFor68k()) {
            return self.latchOpenBus(self.open_bus.* & 0xFF00);
        } else if (addr >= 0xA10000 and addr < 0xA10020) {
            const value = io_window.readRegisterByte(self.io, self.vdp.pal_mode, addr);
            return self.latchOpenBus((@as(u16, value) << 8) | value);
        } else if (addr >= 0xC00000 and addr <= 0xDFFFFF) {
            return vdp_ports.readWord(self.vdp, self.open_bus, self.runtime_state, addr);
        }

        const high = self.read8(address);
        const low = self.read8(address + 1);
        return self.latchOpenBus((@as(u16, high) << 8) | low);
    }

    pub fn read32(self: *View, address: u32) u32 {
        const high = self.read16(address);
        const low = self.read16(address + 2);
        return (@as(u32, high) << 16) | low;
    }

    pub fn write8(self: *View, address: u32, value: u8) void {
        const addr = address & 0xFFFFFF;
        self.open_bus.* = (@as(u16, value) << 8) | value;

        if (self.cartridge.writeRegisterByte(addr, value)) return;
        if (self.cartridge.writeByte(addr, value)) return;

        if (isZ80BusAckPage(addr)) {
            if ((addr & 1) == 0) {
                self.z80.writeBusReq(@as(u16, value) << 8);
            }
            return;
        } else if (isZ80ResetPage(addr)) {
            if ((addr & 1) == 0) {
                self.z80.setAudioMasterOffset(self.audio_timing.pending_master_cycles);
                self.z80.writeReset(@as(u16, value) << 8);
            }
            return;
        }

        if (addr < 0xA00000) {
            return;
        } else if (addr >= 0xE00000 and addr < 0x1000000) {
            self.ram[addr & 0xFFFF] = value;
        } else if (addr >= 0xA00000 and addr < 0xA10000) {
            if (!self.hasZ80BusFor68k()) return;
            self.ensureZ80HostWindow();
            self.z80.setAudioMasterOffset(self.audio_timing.pending_master_cycles);
            const zaddr: u16 = @truncate(addr & 0x7FFF);
            self.z80.writeByte(zaddr, value);
            return;
        } else if (addr >= 0xA10000 and addr < 0xA10020) {
            if ((addr & 1) != 0) {
                io_window.writeRegisterByte(self.io, addr, value);
            }
        } else if (addr >= 0xC00000 and addr <= 0xDFFFFF) {
            const port = addr & 0x1F;
            if (port >= 0x11 and port < 0x18 and (port & 1) == 1) {
                self.z80.setAudioMasterOffset(self.audio_timing.pending_master_cycles);
                self.z80.writeByte(0x7F11, value);
            } else {
                vdp_ports.writeByte(self.vdp, addr, value);
            }
            return;
        }
    }

    pub fn write16(self: *View, address: u32, value: u16) void {
        const addr = address & 0xFFFFFF;
        self.open_bus.* = value;

        if (self.cartridge.writeRegisterWord(addr, value)) return;
        if (self.cartridge.writeWord(addr, value)) return;

        if (addr >= 0xC00000 and addr <= 0xDFFFFF) {
            const port = addr & 0x1F;
            if (port >= 0x10 and port < 0x18 and (port & 1) == 0) {
                self.z80.setAudioMasterOffset(self.audio_timing.pending_master_cycles);
                self.z80.writeByte(0x7F11, @intCast(value & 0xFF));
            } else {
                vdp_ports.writeWord(self.vdp, addr, value);
            }
            return;
        }

        if (isZ80BusAckPage(addr)) {
            self.z80.writeBusReq(value);
            return;
        } else if (isZ80ResetPage(addr)) {
            self.z80.setAudioMasterOffset(self.audio_timing.pending_master_cycles);
            self.z80.writeReset(value);
            return;
        }

        self.write8(address, @intCast((value >> 8) & 0xFF));
        self.write8(address + 1, @intCast(value & 0xFF));
    }

    pub fn write32(self: *View, address: u32, value: u32) void {
        self.write16(address, @intCast((value >> 16) & 0xFFFF));
        self.write16(address + 2, @intCast(value & 0xFFFF));
    }
};

test "cpu memory runtime hooks and z80 wait logic stay local to the view" {
    const testing = std.testing;

    const CallbackCtx = struct {
        opcode: u16,

        fn currentOpcode(ctx: ?*anyopaque) u16 {
            const self: *const @This() = @ptrCast(@alignCast(ctx orelse unreachable));
            return self.opcode;
        }

        fn clearInterrupt(_: ?*anyopaque) void {}
    };

    const TestHooks = struct {
        fn ensureZ80HostWindow(_: ?*anyopaque) void {}
    };

    var rom = [_]u8{0} ** 0x4000;
    @memcpy(rom[0x100..0x104], "SEGA");

    var cartridge = try Cartridge.initFromRomBytes(testing.allocator, &rom);
    defer cartridge.deinit(testing.allocator);

    var ram = [_]u8{0} ** (64 * 1024);
    var vdp = Vdp.init();
    var io = Io.init();
    var z80 = Z80.init();
    defer z80.deinit();
    var audio_timing: AudioTiming = .{};
    var open_bus: u16 = 0;
    var runtime: cpu_runtime.RuntimeState = .{};

    var view = View.init(
        &cartridge,
        &ram,
        &vdp,
        &io,
        &z80,
        &audio_timing,
        &open_bus,
        &runtime,
        null,
        TestHooks.ensureZ80HostWindow,
    );

    var callback_ctx = CallbackCtx{ .opcode = 0x4E71 };
    view.setCpuRuntimeState(cpu_runtime.RuntimeState.init(&callback_ctx, CallbackCtx.currentOpcode, CallbackCtx.clearInterrupt));
    try testing.expectEqual(@as(u16, 0x4E71), runtime.currentOpcode());

    z80.writeBusReq(0x0100);
    try testing.expectEqual(clock.m68kCyclesToMaster(1), view.m68kAccessWaitMasterCycles(0x00A0_0000, 1));

    z80.writeBusReq(0x0000);
    try testing.expectEqual(@as(u32, 0), view.m68kAccessWaitMasterCycles(0x00A0_0000, 1));

    view.clearCpuRuntimeState();
    try testing.expectEqual(@as(u16, 0), runtime.currentOpcode());
}
