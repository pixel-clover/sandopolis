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

const TestHooks = struct {
    fn ensureZ80HostWindow(_: ?*anyopaque) void {}
};

fn grantM68kZ80Bus(view: *View) void {
    view.write16(0x00A1_1100, 0x0100);
}

const TestFixture = struct {
    cartridge: Cartridge,
    ram: [64 * 1024]u8,
    vdp: Vdp,
    io: Io,
    z80: Z80,
    audio_timing: AudioTiming,
    open_bus: u16,
    runtime: cpu_runtime.RuntimeState,

    fn init(allocator: std.mem.Allocator) !TestFixture {
        var rom = [_]u8{0} ** 0x4000;
        @memcpy(rom[0x100..0x104], "SEGA");

        return .{
            .cartridge = try Cartridge.initFromRomBytes(allocator, &rom),
            .ram = [_]u8{0} ** (64 * 1024),
            .vdp = Vdp.init(),
            .io = Io.init(),
            .z80 = Z80.init(),
            .audio_timing = .{},
            .open_bus = 0,
            .runtime = .{},
        };
    }

    fn deinit(self: *TestFixture, allocator: std.mem.Allocator) void {
        self.z80.deinit();
        self.cartridge.deinit(allocator);
    }

    fn view(self: *TestFixture) View {
        return View.init(
            &self.cartridge,
            &self.ram,
            &self.vdp,
            &self.io,
            &self.z80,
            &self.audio_timing,
            &self.open_bus,
            &self.runtime,
            null,
            TestHooks.ensureZ80HostWindow,
        );
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

    var fixture = try TestFixture.init(testing.allocator);
    defer fixture.deinit(testing.allocator);

    var view = fixture.view();

    var callback_ctx = CallbackCtx{ .opcode = 0x4E71 };
    view.setCpuRuntimeState(cpu_runtime.RuntimeState.init(&callback_ctx, CallbackCtx.currentOpcode, CallbackCtx.clearInterrupt));
    try testing.expectEqual(@as(u16, 0x4E71), fixture.runtime.currentOpcode());

    fixture.z80.writeBusReq(0x0100);
    try testing.expectEqual(clock.m68kCyclesToMaster(1), view.m68kAccessWaitMasterCycles(0x00A0_0000, 1));

    fixture.z80.writeBusReq(0x0000);
    try testing.expectEqual(@as(u32, 0), view.m68kAccessWaitMasterCycles(0x00A0_0000, 1));

    view.clearCpuRuntimeState();
    try testing.expectEqual(@as(u16, 0), fixture.runtime.currentOpcode());
}

test "cpu memory z80 bus window and bus request registers behave as expected" {
    const testing = std.testing;

    var fixture = try TestFixture.init(testing.allocator);
    defer fixture.deinit(testing.allocator);
    var view = fixture.view();

    view.write8(0x00A0_0010, 0x5A);
    try testing.expectEqual(@as(u8, 0x5A), view.read8(0x00A0_0010));
    try testing.expectEqual(@as(u16, 0x5A00), view.read16(0x00A0_0010));

    view.write16(0x00A1_1100, 0x0100);
    try testing.expectEqual(@as(u16, 0x0000), view.read16(0x00A1_1100));

    view.write8(0x00A0_0010, 0x5A);
    try testing.expectEqual(@as(u8, 0x5A), view.read8(0x00A0_0010));

    view.write16(0x00A1_1100, 0x0000);
    try testing.expectEqual(@as(u16, 0x0100), view.read16(0x00A1_1100));

    view.write8(0x00A0_0010, 0xA5);
    try testing.expectEqual(@as(u8, 0xA5), view.read8(0x00A0_0010));
    try testing.expectEqual(@as(u16, 0xA500), view.read16(0x00A0_0010));
}

test "cpu memory bus request does not grant z80 bus while reset is held" {
    const testing = std.testing;

    var fixture = try TestFixture.init(testing.allocator);
    defer fixture.deinit(testing.allocator);
    var view = fixture.view();

    view.write16(0x00A1_1200, 0x0000);
    view.write16(0x00A1_1100, 0x0100);

    try testing.expectEqual(@as(u16, 0x0100), view.read16(0x00A1_1100));
    view.write8(0x00A0_0010, 0x5A);
    try testing.expectEqual(@as(u8, 0x5A), view.read8(0x00A0_0010));
    try testing.expectEqual(@as(u16, 0x5A00), view.read16(0x00A0_0010));

    view.write16(0x00A1_1200, 0x0100);

    try testing.expectEqual(@as(u16, 0x0000), view.read16(0x00A1_1100));
    view.write8(0x00A0_0010, 0x5A);
    try testing.expectEqual(@as(u8, 0x5A), view.read8(0x00A0_0010));
}

test "cpu memory z80 busack reads preserve open-bus bits and reset page reads stay open bus" {
    const testing = std.testing;

    var fixture = try TestFixture.init(testing.allocator);
    defer fixture.deinit(testing.allocator);
    var view = fixture.view();

    fixture.open_bus = 0xA400;
    try testing.expectEqual(@as(u16, 0xA500), view.read16(0x00A1_1100));

    view.write16(0x00A1_1100, 0x0100);
    fixture.open_bus = 0xA400;
    try testing.expectEqual(@as(u16, 0xA400), view.read16(0x00A1_1100));

    view.write16(0x00A1_1200, 0x0000);
    fixture.open_bus = 0xB600;
    try testing.expectEqual(@as(u16, 0xB600), view.read16(0x00A1_1200));

    view.write16(0x00A1_1200, 0x0100);
    fixture.open_bus = 0xB600;
    try testing.expectEqual(@as(u16, 0xB600), view.read16(0x00A1_1200));
}

test "cpu memory z80 control registers support byte reads and writes on even address" {
    const testing = std.testing;

    var fixture = try TestFixture.init(testing.allocator);
    defer fixture.deinit(testing.allocator);
    var view = fixture.view();

    try testing.expectEqual(@as(u8, 0x01), view.read8(0x00A1_1100));
    try testing.expectEqual(@as(u8, 0x00), view.read8(0x00A1_1101));
    fixture.open_bus = 0xCAFE;
    try testing.expectEqual(@as(u8, 0xCA), view.read8(0x00A1_1200));
    try testing.expectEqual(@as(u8, 0xFE), view.read8(0x00A1_1201));

    view.write8(0x00A1_1100, 0x01);
    try testing.expectEqual(@as(u16, 0x0001), view.read16(0x00A1_1100));
    try testing.expectEqual(@as(u8, 0x00), view.read8(0x00A1_1100));

    view.write8(0x00A1_1101, 0x01);
    try testing.expectEqual(@as(u16, 0x0001), view.read16(0x00A1_1100));

    view.write8(0x00A1_1200, 0x00);
    try testing.expectEqual(@as(u16, 0x0000), fixture.z80.readReset());
    try testing.expectEqual(@as(u8, 0x00), view.read8(0x00A1_1200));

    view.write8(0x00A1_1201, 0x01);
    try testing.expectEqual(@as(u16, 0x0000), fixture.z80.readReset());

    view.write8(0x00A1_1200, 0x01);
    view.write8(0x00A1_1100, 0x00);
    try testing.expectEqual(@as(u16, 0x0100), fixture.z80.readReset());
    try testing.expectEqual(@as(u16, 0x0100), view.read16(0x00A1_1100));
    fixture.open_bus = 0;
    try testing.expectEqual(@as(u8, 0x00), view.read8(0x00A1_1200));
    try testing.expectEqual(@as(u8, 0x01), view.read8(0x00A1_1100));
}

test "cpu memory z80 reset control only latches the high-byte low bit" {
    const testing = std.testing;

    var fixture = try TestFixture.init(testing.allocator);
    defer fixture.deinit(testing.allocator);
    var view = fixture.view();

    view.write16(0x00A1_1200, 0x0001);
    try testing.expectEqual(@as(u16, 0x0000), fixture.z80.readReset());

    view.write16(0x00A1_1200, 0x00FF);
    try testing.expectEqual(@as(u16, 0x0000), fixture.z80.readReset());

    view.write16(0x00A1_1200, 0x0200);
    try testing.expectEqual(@as(u16, 0x0000), fixture.z80.readReset());

    view.write16(0x00A1_1200, 0x0101);
    try testing.expectEqual(@as(u16, 0x0100), fixture.z80.readReset());

    view.write8(0x00A1_1200, 0x02);
    try testing.expectEqual(@as(u16, 0x0000), fixture.z80.readReset());

    view.write8(0x00A1_1200, 0x03);
    try testing.expectEqual(@as(u16, 0x0100), fixture.z80.readReset());
}

test "cpu memory z80 control register pages mirror across a111xx and a112xx" {
    const testing = std.testing;

    var fixture = try TestFixture.init(testing.allocator);
    defer fixture.deinit(testing.allocator);
    var view = fixture.view();

    view.write8(0x00A1_11FE, 0x01);
    try testing.expectEqual(@as(u16, 0x0001), view.read16(0x00A1_1100));

    view.write8(0x00A1_11FF, 0x00);
    try testing.expectEqual(@as(u16, 0x0000), view.read16(0x00A1_1100));

    view.write8(0x00A1_12FE, 0x00);
    try testing.expectEqual(@as(u16, 0x0000), fixture.z80.readReset());

    view.write8(0x00A1_12FF, 0x01);
    try testing.expectEqual(@as(u16, 0x0000), fixture.z80.readReset());

    view.write16(0x00A1_12F0, 0x0100);
    try testing.expectEqual(@as(u16, 0x0100), fixture.z80.readReset());
}

test "cpu memory unused vdp ports 0x18 and 0x1c return open bus" {
    const testing = std.testing;

    var fixture = try TestFixture.init(testing.allocator);
    defer fixture.deinit(testing.allocator);
    var view = fixture.view();

    fixture.open_bus = 0xA5C3;
    try testing.expectEqual(@as(u8, 0xA5), view.read8(0x00C0_0018));
    try testing.expectEqual(@as(u8, 0xC3), view.read8(0x00C0_0019));
    try testing.expectEqual(@as(u16, 0xA5C3), view.read16(0x00C0_0018));

    fixture.open_bus = 0x5AA7;
    try testing.expectEqual(@as(u8, 0x5A), view.read8(0x00C0_001C));
    try testing.expectEqual(@as(u8, 0xA7), view.read8(0x00C0_001D));
    try testing.expectEqual(@as(u16, 0x5AA7), view.read16(0x00C0_001C));
}

test "cpu memory io version register reflects region and pal bits and word reads use byte value" {
    const testing = std.testing;

    var fixture = try TestFixture.init(testing.allocator);
    defer fixture.deinit(testing.allocator);
    var view = fixture.view();

    try testing.expectEqual(@as(u8, 0xA0), view.read8(0x00A1_0000));
    try testing.expectEqual(@as(u8, 0xA0), view.read8(0x00A1_0001));
    try testing.expectEqual(@as(u16, 0xA0A0), view.read16(0x00A1_0000));

    fixture.io.setVersionIsOverseas(false);
    try testing.expectEqual(@as(u8, 0x20), view.read8(0x00A1_0000));
    try testing.expectEqual(@as(u16, 0x2020), view.read16(0x00A1_0000));

    fixture.vdp.pal_mode = true;
    try testing.expectEqual(@as(u8, 0x60), view.read8(0x00A1_0000));
    try testing.expectEqual(@as(u16, 0x6060), view.read16(0x00A1_0000));

    fixture.io.setVersionIsOverseas(true);
    try testing.expectEqual(@as(u8, 0xE0), view.read8(0x00A1_0000));
    try testing.expectEqual(@as(u16, 0xE0E0), view.read16(0x00A1_0000));
}

test "cpu memory io register pairs mirror byte registers and serial defaults follow hardware reset state" {
    const testing = std.testing;

    var fixture = try TestFixture.init(testing.allocator);
    defer fixture.deinit(testing.allocator);
    var view = fixture.view();

    try testing.expectEqual(@as(u8, 0x7F), view.read8(0x00A1_0002));
    try testing.expectEqual(@as(u8, 0x7F), view.read8(0x00A1_0003));
    try testing.expectEqual(@as(u16, 0x7F7F), view.read16(0x00A1_0002));

    fixture.io.write(0x09, 0x40);
    try testing.expectEqual(@as(u8, 0x40), view.read8(0x00A1_0008));
    try testing.expectEqual(@as(u8, 0x40), view.read8(0x00A1_0009));
    try testing.expectEqual(@as(u16, 0x4040), view.read16(0x00A1_0008));

    try testing.expectEqual(@as(u8, 0xFF), view.read8(0x00A1_000E));
    try testing.expectEqual(@as(u8, 0xFF), view.read8(0x00A1_000F));
    try testing.expectEqual(@as(u16, 0xFFFF), view.read16(0x00A1_000E));

    try testing.expectEqual(@as(u8, 0x00), view.read8(0x00A1_0012));
    try testing.expectEqual(@as(u16, 0x0000), view.read16(0x00A1_0012));

    try testing.expectEqual(@as(u8, 0xFF), view.read8(0x00A1_0014));
    try testing.expectEqual(@as(u16, 0xFFFF), view.read16(0x00A1_0014));

    try testing.expectEqual(@as(u8, 0xFB), view.read8(0x00A1_001A));
    try testing.expectEqual(@as(u16, 0xFBFB), view.read16(0x00A1_001A));

    try testing.expectEqual(@as(u8, 0x00), view.read8(0x00A1_001E));
    try testing.expectEqual(@as(u16, 0x0000), view.read16(0x00A1_001E));
}

test "cpu memory io port c data and control registers are exposed" {
    const testing = std.testing;

    var fixture = try TestFixture.init(testing.allocator);
    defer fixture.deinit(testing.allocator);
    var view = fixture.view();

    fixture.io.write(0x07, 0x5A);
    fixture.io.write(0x0D, 0xA5);

    try testing.expectEqual(@as(u8, 0x5A), view.read8(0x00A1_0006));
    try testing.expectEqual(@as(u8, 0x5A), view.read8(0x00A1_0007));
    try testing.expectEqual(@as(u16, 0x5A5A), view.read16(0x00A1_0006));

    try testing.expectEqual(@as(u8, 0xA5), view.read8(0x00A1_000C));
    try testing.expectEqual(@as(u8, 0xA5), view.read8(0x00A1_000D));
    try testing.expectEqual(@as(u16, 0xA5A5), view.read16(0x00A1_000C));
}

test "cpu memory io register byte writes require odd address strobes and word writes use the low byte" {
    const testing = std.testing;

    var fixture = try TestFixture.init(testing.allocator);
    defer fixture.deinit(testing.allocator);
    var view = fixture.view();

    view.write8(0x00A1_0002, 0x40);
    try testing.expectEqual(@as(u8, 0x00), fixture.io.data[0]);

    view.write8(0x00A1_0003, 0x40);
    try testing.expectEqual(@as(u8, 0x40), fixture.io.data[0]);

    view.write8(0x00A1_0008, 0x55);
    try testing.expectEqual(@as(u8, 0x00), fixture.io.read(0x09));

    view.write8(0x00A1_0009, 0x55);
    try testing.expectEqual(@as(u8, 0x55), fixture.io.read(0x09));

    view.write8(0x00A1_0006, 0xAA);
    try testing.expectEqual(@as(u8, 0x00), fixture.io.read(0x07));

    view.write8(0x00A1_0007, 0xAA);
    try testing.expectEqual(@as(u8, 0xAA), fixture.io.read(0x07));

    view.write8(0x00A1_000C, 0x11);
    try testing.expectEqual(@as(u8, 0x00), fixture.io.read(0x0D));

    view.write8(0x00A1_000D, 0x11);
    try testing.expectEqual(@as(u8, 0x11), fixture.io.read(0x0D));

    view.write16(0x00A1_0008, 0xAA77);
    try testing.expectEqual(@as(u8, 0x77), fixture.io.read(0x09));

    view.write8(0x00A1_000E, 0x12);
    try testing.expectEqual(@as(u8, 0xFF), fixture.io.tx_data[0]);

    view.write8(0x00A1_000F, 0x12);
    try testing.expectEqual(@as(u8, 0x12), fixture.io.tx_data[0]);

    view.write8(0x00A1_0012, 0xA7);
    try testing.expectEqual(@as(u8, 0x00), fixture.io.serial_ctrl[0]);

    view.write8(0x00A1_0013, 0xA7);
    try testing.expectEqual(@as(u8, 0xA0), fixture.io.serial_ctrl[0]);

    view.write16(0x00A1_001E, 0x005F);
    try testing.expectEqual(@as(u8, 0x58), fixture.io.serial_ctrl[2]);

    view.write16(0x00A1_001E, 0xAA5F);
    try testing.expectEqual(@as(u8, 0x58), fixture.io.serial_ctrl[2]);
}

test "cpu memory io window decode stops at a1001f and higher addresses fall back to open bus" {
    const testing = std.testing;

    var fixture = try TestFixture.init(testing.allocator);
    defer fixture.deinit(testing.allocator);
    var view = fixture.view();

    fixture.open_bus = 0x5A3C;
    try testing.expectEqual(@as(u8, 0x5A), view.read8(0x00A1_0020));
    try testing.expectEqual(@as(u8, 0x3C), view.read8(0x00A1_0021));
    try testing.expectEqual(@as(u16, 0x5A3C), view.read16(0x00A1_0020));

    view.write8(0x00A1_0023, 0x12);
    try testing.expectEqual(@as(u8, 0x00), fixture.io.data[0]);

    view.write16(0x00A1_001E, 0xA0F8);
    try testing.expectEqual(@as(u8, 0xF8), fixture.io.serial_ctrl[2]);

    view.write16(0x00A1_0020, 0x0000);
    try testing.expectEqual(@as(u8, 0xF8), fixture.io.serial_ctrl[2]);
}

test "cpu memory z80 window writes use current audio master offset" {
    const testing = std.testing;

    var fixture = try TestFixture.init(testing.allocator);
    defer fixture.deinit(testing.allocator);
    var view = fixture.view();

    grantM68kZ80Bus(&view);
    fixture.audio_timing.consumeMaster(5000);

    view.write8(0x00A0_4000, 0x22);
    view.write8(0x00A0_4001, 0x0F);

    var writes: [4]Z80.YmWriteEvent = undefined;
    const count = fixture.z80.takeYmWrites(writes[0..]);
    try testing.expectEqual(@as(usize, 1), count);
    try testing.expectEqual(@as(u32, 5000), writes[0].master_offset);
}

test "cpu memory z80 audio window latches ym2612 and psg writes" {
    const testing = std.testing;

    var fixture = try TestFixture.init(testing.allocator);
    defer fixture.deinit(testing.allocator);
    var view = fixture.view();

    grantM68kZ80Bus(&view);

    view.write8(0x00A0_4000, 0x22);
    view.write8(0x00A0_4001, 0x0F);
    try testing.expectEqual(@as(u8, 0x0F), fixture.z80.getYmRegister(0, 0x22));

    view.write8(0x00A0_4002, 0x2B);
    view.write8(0x00A0_4003, 0x80);
    try testing.expectEqual(@as(u8, 0x80), fixture.z80.getYmRegister(1, 0x2B));

    view.write8(0x00A0_7F11, 0x90);
    try testing.expectEqual(@as(u8, 0x90), fixture.z80.getPsgLast());
}

test "cpu memory ym status reads advance busy timing through the z80 window" {
    const testing = std.testing;

    var fixture = try TestFixture.init(testing.allocator);
    defer fixture.deinit(testing.allocator);
    var view = fixture.view();

    const ym_internal_master_cycles: u32 = @as(u32, clock.m68k_divider) * 6;

    grantM68kZ80Bus(&view);

    view.write8(0x00A0_4000, 0x22);
    view.write8(0x00A0_4001, 0x0F);
    try testing.expectEqual(@as(u8, 0x00), view.read8(0x00A0_4000) & 0x80);

    fixture.audio_timing.consumeMaster(ym_internal_master_cycles);
    try testing.expectEqual(@as(u8, 0x80), view.read8(0x00A0_4000) & 0x80);

    fixture.audio_timing.consumeMaster(64 * ym_internal_master_cycles);
    try testing.expectEqual(@as(u8, 0x00), view.read8(0x00A0_4000) & 0x80);
}

test "cpu memory psg latch and data writes through the z80 window decode shadow state" {
    const testing = std.testing;

    var fixture = try TestFixture.init(testing.allocator);
    defer fixture.deinit(testing.allocator);
    var view = fixture.view();

    grantM68kZ80Bus(&view);

    view.write8(0x00A0_7F11, 0x80 | 0x0A);
    view.write8(0x00A0_7F11, 0x15);
    try testing.expectEqual(@as(u16, 0x15A), fixture.z80.getPsgTone(0));

    view.write8(0x00A0_7F11, 0xC0 | 0x10 | 0x07);
    try testing.expectEqual(@as(u8, 0x07), fixture.z80.getPsgVolume(2));

    view.write8(0x00A0_7F11, 0xE0 | 0x03);
    try testing.expectEqual(@as(u8, 0x03), fixture.z80.getPsgNoise());
}

test "cpu memory psg writes through vdp ports reach the psg shadow registers" {
    const testing = std.testing;

    var fixture = try TestFixture.init(testing.allocator);
    defer fixture.deinit(testing.allocator);
    var view = fixture.view();

    view.write8(0x00C0_0011, 0x80 | 0x05);
    view.write8(0x00C0_0011, 0x12);
    try testing.expectEqual(@as(u16, 0x125), fixture.z80.getPsgTone(0));

    view.write16(0x00C0_0010, 0x00D0 | 0x07);
    try testing.expectEqual(@as(u8, 0x07), fixture.z80.getPsgVolume(2));

    var cmds: [4]Z80.PsgCommandEvent = undefined;
    const count = fixture.z80.takePsgCommands(cmds[0..]);
    try testing.expectEqual(@as(usize, 3), count);
}

test "cpu memory ym key-on register updates the channel key mask" {
    const testing = std.testing;

    var fixture = try TestFixture.init(testing.allocator);
    defer fixture.deinit(testing.allocator);
    var view = fixture.view();

    grantM68kZ80Bus(&view);

    view.write8(0x00A0_4000, 0x28);
    view.write8(0x00A0_4001, 0xF0);
    try testing.expectEqual(@as(u8, 0x01), fixture.z80.getYmKeyMask());

    view.write8(0x00A0_4000, 0x28);
    view.write8(0x00A0_4001, 0xF5);
    try testing.expectEqual(@as(u8, 0x11), fixture.z80.getYmKeyMask());

    view.write8(0x00A0_4000, 0x28);
    view.write8(0x00A0_4001, 0x00);
    try testing.expectEqual(@as(u8, 0x10), fixture.z80.getYmKeyMask());
}

test "cpu memory ym dac writes stay in the dedicated queue" {
    const testing = std.testing;

    var fixture = try TestFixture.init(testing.allocator);
    defer fixture.deinit(testing.allocator);
    var view = fixture.view();

    grantM68kZ80Bus(&view);

    view.write8(0x00A0_4000, 0x2A);
    view.write8(0x00A0_4001, 0x12);
    view.write8(0x00A0_4001, 0x34);

    var writes: [4]Z80.YmWriteEvent = undefined;
    try testing.expectEqual(@as(usize, 0), fixture.z80.takeYmWrites(writes[0..]));

    var dac_samples: [4]Z80.YmDacSampleEvent = undefined;
    const count = fixture.z80.takeYmDacSamples(dac_samples[0..]);
    try testing.expectEqual(@as(usize, 2), count);
    try testing.expectEqual(@as(u8, 0x12), dac_samples[0].value);
    try testing.expectEqual(@as(u8, 0x34), dac_samples[1].value);
}

test "cpu memory z80 reset clears ym2612 register shadow state" {
    const testing = std.testing;

    var fixture = try TestFixture.init(testing.allocator);
    defer fixture.deinit(testing.allocator);
    var view = fixture.view();

    grantM68kZ80Bus(&view);

    view.write8(0x00A0_4000, 0x22);
    view.write8(0x00A0_4001, 0x0F);
    view.write8(0x00A0_4000, 0x28);
    view.write8(0x00A0_4001, 0xF0);

    try testing.expectEqual(@as(u8, 0x0F), fixture.z80.getYmRegister(0, 0x22));
    try testing.expectEqual(@as(u8, 0x01), fixture.z80.getYmKeyMask());

    view.write16(0x00A1_1200, 0x0000);

    try testing.expectEqual(@as(u8, 0x00), fixture.z80.getYmRegister(0, 0x22));
    try testing.expectEqual(@as(u8, 0x00), fixture.z80.getYmRegister(0, 0x28));
    try testing.expectEqual(@as(u8, 0x00), fixture.z80.getYmKeyMask());
}

test "cpu memory z80 reset line edges carry the current audio master offset into ym reset events" {
    const testing = std.testing;

    var fixture = try TestFixture.init(testing.allocator);
    defer fixture.deinit(testing.allocator);
    var view = fixture.view();

    fixture.audio_timing.consumeMaster(4321);
    view.write16(0x00A1_1200, 0x0000);

    fixture.audio_timing.consumeMaster(321);
    view.write16(0x00A1_1200, 0x0100);

    var ym_reset_events: [2]Z80.YmResetEvent = undefined;
    try testing.expectEqual(@as(usize, 2), fixture.z80.takeYmResets(ym_reset_events[0..]));
    try testing.expectEqual(@as(u32, 4321), ym_reset_events[0].master_offset);
    try testing.expectEqual(@as(u32, 4642), ym_reset_events[1].master_offset);
}

test "cpu memory z80 reset preserves uploaded z80 ram" {
    const testing = std.testing;

    var fixture = try TestFixture.init(testing.allocator);
    defer fixture.deinit(testing.allocator);
    var view = fixture.view();

    grantM68kZ80Bus(&view);
    view.write16(0x00A1_1200, 0x0100);

    view.write8(0x00A0_0000, 0xAF);
    view.write8(0x00A0_0001, 0x01);
    view.write8(0x00A0_0002, 0xD9);

    view.write16(0x00A1_1200, 0x0000);

    try testing.expectEqual(@as(u8, 0xAF), fixture.z80.readByte(0x0000));
    try testing.expectEqual(@as(u8, 0x01), fixture.z80.readByte(0x0001));
    try testing.expectEqual(@as(u8, 0xD9), fixture.z80.readByte(0x0002));
}

test "cpu memory vdp status high bits come from bus open bus" {
    const testing = std.testing;

    var fixture = try TestFixture.init(testing.allocator);
    defer fixture.deinit(testing.allocator);
    var view = fixture.view();

    view.write16(0x00E0_0000, 0xA5A5);

    const status = view.read16(0x00C0_0004);
    try testing.expectEqual(@as(u16, 0xA400), status & 0xFC00);
    try testing.expectEqual(@as(u16, 0x0200), status & 0x0300);
}
