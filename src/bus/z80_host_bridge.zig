const std = @import("std");
const Z80 = @import("../cpu/z80.zig").Z80;

pub const HostReadByteFn = *const fn (ctx: ?*anyopaque, address: u32) u8;
pub const HostPeekByteFn = *const fn (ctx: ?*anyopaque, address: u32) u8;
pub const HostWriteByteFn = *const fn (ctx: ?*anyopaque, address: u32, value: u8) void;
pub const HostM68kBusAccessFn = *const fn (ctx: ?*anyopaque, pre_access_master_cycles: u32) void;

pub const HostBridge = struct {
    ctx: ?*anyopaque,
    read_host_byte_fn: HostReadByteFn,
    peek_host_byte_fn: HostPeekByteFn,
    write_host_byte_fn: HostWriteByteFn,
    m68k_bus_access_fn: HostM68kBusAccessFn,

    pub fn init(
        read_host_byte_fn: HostReadByteFn,
        peek_host_byte_fn: HostPeekByteFn,
        write_host_byte_fn: HostWriteByteFn,
        m68k_bus_access_fn: HostM68kBusAccessFn,
    ) HostBridge {
        return .{
            .ctx = null,
            .read_host_byte_fn = read_host_byte_fn,
            .peek_host_byte_fn = peek_host_byte_fn,
            .write_host_byte_fn = write_host_byte_fn,
            .m68k_bus_access_fn = m68k_bus_access_fn,
        };
    }

    pub fn bind(self: *HostBridge, z80: *Z80, ctx: ?*anyopaque) void {
        self.ctx = ctx;
        z80.setHostCallbacks(self, readCallback, peekCallback, writeCallback, m68kBusAccessCallback);
    }

    fn readCallback(userdata: ?*anyopaque, address: u32) callconv(.c) u8 {
        const self: *HostBridge = @ptrCast(@alignCast(userdata orelse return 0xFF));
        const addr = address & 0xFFFFFF;
        if (addr >= 0xA00000 and addr < 0xA10000) return 0xFF;
        return self.read_host_byte_fn(self.ctx, addr);
    }

    fn writeCallback(userdata: ?*anyopaque, address: u32, value: u8) callconv(.c) void {
        const self: *HostBridge = @ptrCast(@alignCast(userdata orelse return));
        const addr = address & 0xFFFFFF;
        if (addr >= 0xA00000 and addr < 0xA10000) return;
        self.write_host_byte_fn(self.ctx, addr, value);
    }

    fn peekCallback(userdata: ?*anyopaque, address: u32) callconv(.c) u8 {
        const self: *HostBridge = @ptrCast(@alignCast(userdata orelse return 0xFF));
        const addr = address & 0xFFFFFF;
        if (addr >= 0xA00000 and addr < 0xA10000) return 0xFF;
        return self.peek_host_byte_fn(self.ctx, addr);
    }

    fn m68kBusAccessCallback(userdata: ?*anyopaque, pre_access_master_cycles: u32) callconv(.c) void {
        const self: *HostBridge = @ptrCast(@alignCast(userdata orelse return));
        self.m68k_bus_access_fn(self.ctx, pre_access_master_cycles);
    }
};

const TimingProbe = struct {
    time: u32 = 0,
    pending_wait: u32 = 0,
    odd_access: bool = false,
    last_write_time: u32 = 0,
    last_write_address: u32 = 0,
    last_write_value: u8 = 0,
    access_count: u8 = 0,
    access_times: [8]u32 = [_]u32{0} ** 8,
    access_addresses: [8]u32 = [_]u32{0} ** 8,
    memory: [8]u8 = [_]u8{0xFF} ** 8,
    window_memory: [32]u8 = [_]u8{0xFF} ** 32,

    fn memoryIndex(self: *const TimingProbe, address: u32) ?usize {
        if (address < self.memory.len) return @intCast(address);
        if (address >= 0xC00000 and address < 0xC00000 + self.memory.len) return @intCast(address - 0xC00000);
        return null;
    }

    fn rawHostByte(self: *const TimingProbe, address: u32) u8 {
        if (self.memoryIndex(address)) |index| return self.memory[index];
        if (address >= 0xC00000 and address < 0xC00000 + self.window_memory.len) {
            return self.window_memory[address - 0xC00000];
        }
        return 0xFF;
    }

    fn readHostByte(ctx: ?*anyopaque, address: u32) u8 {
        const self: *TimingProbe = @ptrCast(@alignCast(ctx orelse return 0xFF));
        if (self.access_count != 0 and self.access_count <= self.access_addresses.len) {
            self.access_addresses[self.access_count - 1] = address;
        }
        return self.rawHostByte(address);
    }

    fn peekHostByte(ctx: ?*anyopaque, address: u32) u8 {
        const self: *TimingProbe = @ptrCast(@alignCast(ctx orelse return 0xFF));
        return self.rawHostByte(address);
    }

    fn writeHostByte(ctx: ?*anyopaque, address: u32, value: u8) void {
        const self: *TimingProbe = @ptrCast(@alignCast(ctx orelse return));
        if (self.access_count != 0 and self.access_count <= self.access_addresses.len) {
            self.access_addresses[self.access_count - 1] = address;
        }
        if (self.memoryIndex(address)) |index| {
            self.memory[index] = value;
        } else if (address >= 0xC00000 and address < 0xC00000 + self.window_memory.len) {
            self.window_memory[address - 0xC00000] = value;
        }
        self.last_write_time = self.time;
        self.last_write_address = address;
        self.last_write_value = value;
    }

    fn onM68kBusAccess(ctx: ?*anyopaque, pre_access_master_cycles: u32) void {
        const self: *TimingProbe = @ptrCast(@alignCast(ctx orelse return));
        if (self.pending_wait != 0) {
            self.time += self.pending_wait;
            self.pending_wait = 0;
        }
        self.time += pre_access_master_cycles;
        if (self.access_count < self.access_times.len) {
            self.access_times[self.access_count] = self.time;
        }
        self.access_count += 1;
        self.pending_wait = if (self.odd_access) 50 else 49;
        self.odd_access = !self.odd_access;
    }
};

test "z80 io-window reads use delayed host access timing" {
    var z80 = Z80.init();
    defer z80.deinit();

    var probe = TimingProbe{ .memory = .{ 0xFF, 0xFF, 0xFF, 0xFF, 0x42, 0xFF, 0xFF, 0xFF } };
    var bridge = HostBridge.init(TimingProbe.readHostByte, TimingProbe.peekHostByte, TimingProbe.writeHostByte, TimingProbe.onM68kBusAccess);
    bridge.bind(&z80, &probe);

    z80.writeByte(0x0000, 0x7E);

    var state = z80.captureState();
    state.pc = 0x0000;
    state.hl = 0x7F04;
    state.bank = 0x0000;
    z80.restoreState(&state);

    try std.testing.expectEqual(@as(u32, 7), z80.stepInstruction());
    try std.testing.expectEqual(@as(u16, 0x0001), z80.getPc());
    try std.testing.expectEqual(@as(u8, 0x42), @as(u8, @truncate(z80.getRegisterDump().af >> 8)));
    try std.testing.expectEqual(@as(u8, 1), probe.access_count);
    try std.testing.expectEqual(@as(u32, 60), probe.access_times[0]);
    try std.testing.expectEqual(@as(u32, 0x00C0_0004), probe.access_addresses[0]);
    try std.testing.expectEqual(@as(u32, 60), probe.time);
    try std.testing.expectEqual(@as(u32, 49), probe.pending_wait);
    try std.testing.expectEqual(@as(u32, 1), z80.take68kBusAccessCount());
}

test "z80 io-window writes use delayed host access timing" {
    var z80 = Z80.init();
    defer z80.deinit();

    var probe = TimingProbe{};
    var bridge = HostBridge.init(TimingProbe.readHostByte, TimingProbe.peekHostByte, TimingProbe.writeHostByte, TimingProbe.onM68kBusAccess);
    bridge.bind(&z80, &probe);

    z80.writeByte(0x0000, 0x77);

    var state = z80.captureState();
    state.pc = 0x0000;
    state.hl = 0x7F04;
    state.af = 0x9A00;
    state.bank = 0x0000;
    z80.restoreState(&state);

    try std.testing.expectEqual(@as(u32, 7), z80.stepInstruction());
    try std.testing.expectEqual(@as(u16, 0x0001), z80.getPc());
    try std.testing.expectEqual(@as(u8, 1), probe.access_count);
    try std.testing.expectEqual(@as(u32, 60), probe.access_times[0]);
    try std.testing.expectEqual(@as(u32, 0x00C0_0004), probe.access_addresses[0]);
    try std.testing.expectEqual(@as(u8, 0x9A), probe.memory[4]);
    try std.testing.expectEqual(@as(u32, 60), probe.last_write_time);
    try std.testing.expectEqual(@as(u32, 0x00C0_0004), probe.last_write_address);
    try std.testing.expectEqual(@as(u8, 0x9A), probe.last_write_value);
    try std.testing.expectEqual(@as(u32, 60), probe.time);
    try std.testing.expectEqual(@as(u32, 49), probe.pending_wait);
    try std.testing.expectEqual(@as(u32, 1), z80.take68kBusAccessCount());
}

test "psg writes stay direct and do not count as host bus accesses" {
    var z80 = Z80.init();
    defer z80.deinit();

    var probe = TimingProbe{};
    var bridge = HostBridge.init(TimingProbe.readHostByte, TimingProbe.peekHostByte, TimingProbe.writeHostByte, TimingProbe.onM68kBusAccess);
    bridge.bind(&z80, &probe);

    z80.writeByte(0x0000, 0x77);

    var state = z80.captureState();
    state.pc = 0x0000;
    state.hl = 0x7F11;
    state.af = 0x9000;
    state.bank = 0x0000;
    z80.restoreState(&state);

    try std.testing.expectEqual(@as(u32, 7), z80.stepInstruction());
    try std.testing.expectEqual(@as(u16, 0x0001), z80.getPc());
    try std.testing.expectEqual(@as(u8, 0x90), z80.getPsgLast());
    try std.testing.expectEqual(@as(u8, 0), probe.access_count);
    try std.testing.expectEqual(@as(u32, 0), probe.time);
    try std.testing.expectEqual(@as(u32, 0), probe.pending_wait);
    try std.testing.expectEqual(@as(u32, 0), z80.take68kBusAccessCount());
}

test "io-window immediate fetches stay time-separated without host data reads" {
    var z80 = Z80.init();
    defer z80.deinit();

    var probe = TimingProbe{ .memory = .{ 0xC3, 0x05, 0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF } };
    var bridge = HostBridge.init(TimingProbe.readHostByte, TimingProbe.peekHostByte, TimingProbe.writeHostByte, TimingProbe.onM68kBusAccess);
    bridge.bind(&z80, &probe);

    var state = z80.captureState();
    state.pc = 0x7F00;
    state.bank = 0x0000;
    z80.restoreState(&state);

    try std.testing.expectEqual(@as(u32, 10), z80.stepInstruction());
    try std.testing.expectEqual(@as(u16, 0x7F05), z80.getPc());
    try std.testing.expectEqual(@as(u8, 3), probe.access_count);
    try std.testing.expectEqual(@as(u32, 0), probe.access_times[0]);
    try std.testing.expectEqual(@as(u32, 109), probe.access_times[1]);
    try std.testing.expectEqual(@as(u32, 204), probe.access_times[2]);
    try std.testing.expectEqual(@as(u32, 0x00C0_0000), probe.access_addresses[0]);
    try std.testing.expect(probe.access_addresses[1] != probe.access_addresses[2]);
    try std.testing.expect(
        (probe.access_addresses[1] == 0x00C0_0001 and probe.access_addresses[2] == 0x00C0_0002) or
            (probe.access_addresses[1] == 0x00C0_0002 and probe.access_addresses[2] == 0x00C0_0001),
    );
    try std.testing.expectEqual(@as(u32, 204), probe.time);
    try std.testing.expectEqual(@as(u32, 49), probe.pending_wait);
    try std.testing.expectEqual(@as(u32, 3), z80.take68kBusAccessCount());
}

test "io-window fetches skip the psg port without fabricating contention" {
    var z80 = Z80.init();
    defer z80.deinit();

    var probe = TimingProbe{};
    probe.window_memory[0x10] = 0xC3;
    probe.window_memory[0x12] = 0x7F;
    var bridge = HostBridge.init(TimingProbe.readHostByte, TimingProbe.peekHostByte, TimingProbe.writeHostByte, TimingProbe.onM68kBusAccess);
    bridge.bind(&z80, &probe);

    var state = z80.captureState();
    state.pc = 0x7F10;
    state.bank = 0x0000;
    z80.restoreState(&state);

    try std.testing.expectEqual(@as(u32, 10), z80.stepInstruction());
    try std.testing.expectEqual(@as(u16, 0x7FFF), z80.getPc());
    try std.testing.expectEqual(@as(u8, 2), probe.access_count);
    try std.testing.expectEqual(@as(u32, 0), probe.access_times[0]);
    try std.testing.expectEqual(@as(u32, 154), probe.access_times[1]);
    try std.testing.expectEqual(@as(u32, 0x00C0_0010), probe.access_addresses[0]);
    try std.testing.expectEqual(@as(u32, 0x00C0_0012), probe.access_addresses[1]);
    try std.testing.expectEqual(@as(u32, 154), probe.time);
    try std.testing.expectEqual(@as(u32, 50), probe.pending_wait);
    try std.testing.expectEqual(@as(u32, 2), z80.take68kBusAccessCount());
}

test "banked z80 read-modify-write can advance host timing between accesses" {
    var z80 = Z80.init();
    defer z80.deinit();

    var probe = TimingProbe{ .memory = .{ 0x10, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF } };
    var bridge = HostBridge.init(TimingProbe.readHostByte, TimingProbe.peekHostByte, TimingProbe.writeHostByte, TimingProbe.onM68kBusAccess);
    bridge.bind(&z80, &probe);

    z80.writeByte(0x0000, 0x34); // INC (HL)

    var state = z80.captureState();
    state.pc = 0x0000;
    state.hl = 0x8000;
    state.bank = 0x0000;
    z80.restoreState(&state);

    try std.testing.expectEqual(@as(u32, 11), z80.stepInstruction());
    try std.testing.expectEqual(@as(u8, 2), probe.access_count);
    try std.testing.expectEqual(@as(u32, 60), probe.access_times[0]);
    try std.testing.expectEqual(@as(u32, 169), probe.access_times[1]);
    try std.testing.expectEqual(@as(u32, 169), probe.last_write_time);
    try std.testing.expectEqual(@as(u8, 0x11), probe.last_write_value);
    try std.testing.expectEqual(@as(u32, 169), probe.time);
    try std.testing.expectEqual(@as(u32, 50), probe.pending_wait);
}

test "banked z80 instruction fetches can still decode host access offsets" {
    var z80 = Z80.init();
    defer z80.deinit();

    var probe = TimingProbe{ .memory = .{ 0x3A, 0x03, 0x80, 0x42, 0xFF, 0xFF, 0xFF, 0xFF } };
    var bridge = HostBridge.init(TimingProbe.readHostByte, TimingProbe.peekHostByte, TimingProbe.writeHostByte, TimingProbe.onM68kBusAccess);
    bridge.bind(&z80, &probe);

    var state = z80.captureState();
    state.pc = 0x8000;
    state.bank = 0x0000;
    z80.restoreState(&state);

    try std.testing.expectEqual(@as(u32, 13), z80.stepInstruction());
    try std.testing.expectEqual(@as(u16, 0x8003), z80.getPc());
    try std.testing.expectEqual(@as(u8, 0x42), @as(u8, @truncate(z80.getRegisterDump().af >> 8)));
    try std.testing.expectEqual(@as(u8, 4), probe.access_count);
    try std.testing.expectEqual(@as(u32, 0), probe.access_times[0]);
    try std.testing.expectEqual(@as(u32, 109), probe.access_times[1]);
    try std.testing.expectEqual(@as(u32, 204), probe.access_times[2]);
    try std.testing.expectEqual(@as(u32, 298), probe.access_times[3]);
    try std.testing.expectEqual(@as(u32, 298), probe.time);
    try std.testing.expectEqual(@as(u32, 50), probe.pending_wait);
}

test "banked z80 immediate fetches stay time-separated without host data reads" {
    var z80 = Z80.init();
    defer z80.deinit();

    var probe = TimingProbe{ .memory = .{ 0xC3, 0x05, 0x80, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF } };
    var bridge = HostBridge.init(TimingProbe.readHostByte, TimingProbe.peekHostByte, TimingProbe.writeHostByte, TimingProbe.onM68kBusAccess);
    bridge.bind(&z80, &probe);

    var state = z80.captureState();
    state.pc = 0x8000;
    state.bank = 0x0000;
    z80.restoreState(&state);

    try std.testing.expectEqual(@as(u32, 10), z80.stepInstruction());
    try std.testing.expectEqual(@as(u16, 0x8005), z80.getPc());
    try std.testing.expectEqual(@as(u8, 3), probe.access_count);
    try std.testing.expectEqual(@as(u32, 0), probe.access_times[0]);
    try std.testing.expectEqual(@as(u32, 109), probe.access_times[1]);
    try std.testing.expectEqual(@as(u32, 204), probe.access_times[2]);
    try std.testing.expectEqual(@as(u32, 204), probe.time);
    try std.testing.expectEqual(@as(u32, 49), probe.pending_wait);
}

test "indexed z80 memory reads use delayed host access timing" {
    var z80 = Z80.init();
    defer z80.deinit();

    var probe = TimingProbe{ .memory = .{ 0x42, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF } };
    var bridge = HostBridge.init(TimingProbe.readHostByte, TimingProbe.peekHostByte, TimingProbe.writeHostByte, TimingProbe.onM68kBusAccess);
    bridge.bind(&z80, &probe);

    z80.writeByte(0x0000, 0xDD);
    z80.writeByte(0x0001, 0x7E);
    z80.writeByte(0x0002, 0x00);

    var state = z80.captureState();
    state.pc = 0x0000;
    state.ix = 0x8000;
    state.bank = 0x0000;
    z80.restoreState(&state);

    try std.testing.expectEqual(@as(u32, 19), z80.stepInstruction());
    try std.testing.expectEqual(@as(u16, 0x0003), z80.getPc());
    try std.testing.expectEqual(@as(u8, 0x42), @as(u8, @truncate(z80.getRegisterDump().af >> 8)));
    try std.testing.expectEqual(@as(u8, 1), probe.access_count);
    try std.testing.expectEqual(@as(u32, 225), probe.access_times[0]);
    try std.testing.expectEqual(@as(u32, 225), probe.time);
    try std.testing.expectEqual(@as(u32, 49), probe.pending_wait);
}

test "indexed banked fetches keep dd-prefixed instruction bytes separated" {
    var z80 = Z80.init();
    defer z80.deinit();

    var probe = TimingProbe{ .memory = .{ 0xDD, 0x21, 0x34, 0x12, 0xFF, 0xFF, 0xFF, 0xFF } };
    var bridge = HostBridge.init(TimingProbe.readHostByte, TimingProbe.peekHostByte, TimingProbe.writeHostByte, TimingProbe.onM68kBusAccess);
    bridge.bind(&z80, &probe);

    var state = z80.captureState();
    state.pc = 0x8000;
    state.bank = 0x0000;
    z80.restoreState(&state);

    try std.testing.expectEqual(@as(u32, 14), z80.stepInstruction());
    try std.testing.expectEqual(@as(u16, 0x8004), z80.getPc());
    try std.testing.expectEqual(@as(u16, 0x1234), z80.getRegisterDump().ix);
    try std.testing.expectEqual(@as(u8, 4), probe.access_count);
    try std.testing.expectEqual(@as(u32, 0), probe.access_times[0]);
    try std.testing.expectEqual(@as(u32, 109), probe.access_times[1]);
    try std.testing.expectEqual(@as(u32, 219), probe.access_times[2]);
    try std.testing.expectEqual(@as(u32, 313), probe.access_times[3]);
    try std.testing.expectEqual(@as(u32, 313), probe.time);
    try std.testing.expectEqual(@as(u32, 50), probe.pending_wait);
}

test "indexed cb bit reads use delayed host access timing" {
    var z80 = Z80.init();
    defer z80.deinit();

    var probe = TimingProbe{ .memory = .{ 0x42, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF } };
    var bridge = HostBridge.init(TimingProbe.readHostByte, TimingProbe.peekHostByte, TimingProbe.writeHostByte, TimingProbe.onM68kBusAccess);
    bridge.bind(&z80, &probe);

    z80.writeByte(0x0000, 0xDD);
    z80.writeByte(0x0001, 0xCB);
    z80.writeByte(0x0002, 0x00);
    z80.writeByte(0x0003, 0x46);

    var state = z80.captureState();
    state.pc = 0x0000;
    state.ix = 0x8000;
    state.bank = 0x0000;
    z80.restoreState(&state);

    try std.testing.expectEqual(@as(u32, 20), z80.stepInstruction());
    try std.testing.expectEqual(@as(u16, 0x0004), z80.getPc());
    try std.testing.expectEqual(@as(u8, 1), probe.access_count);
    try std.testing.expectEqual(@as(u32, 225), probe.access_times[0]);
    try std.testing.expectEqual(@as(u32, 225), probe.time);
    try std.testing.expectEqual(@as(u32, 49), probe.pending_wait);
}

test "indexed cb banked fetches and writeback stay ordered" {
    var z80 = Z80.init();
    defer z80.deinit();

    var probe = TimingProbe{ .memory = .{ 0xFD, 0xCB, 0x00, 0xC6, 0x80, 0xFF, 0xFF, 0xFF } };
    var bridge = HostBridge.init(TimingProbe.readHostByte, TimingProbe.peekHostByte, TimingProbe.writeHostByte, TimingProbe.onM68kBusAccess);
    bridge.bind(&z80, &probe);

    var state = z80.captureState();
    state.pc = 0x8000;
    state.iy = 0x8004;
    state.bank = 0x0000;
    z80.restoreState(&state);

    try std.testing.expectEqual(@as(u32, 23), z80.stepInstruction());
    try std.testing.expectEqual(@as(u16, 0x8004), z80.getPc());
    try std.testing.expectEqual(@as(u8, 0x81), probe.memory[4]);
    try std.testing.expectEqual(@as(u8, 6), probe.access_count);
    try std.testing.expectEqual(@as(u32, 0), probe.access_times[0]);
    try std.testing.expectEqual(@as(u32, 109), probe.access_times[1]);
    try std.testing.expectEqual(@as(u32, 219), probe.access_times[2]);
    try std.testing.expectEqual(@as(u32, 313), probe.access_times[3]);
    try std.testing.expectEqual(@as(u32, 423), probe.access_times[4]);
    try std.testing.expectEqual(@as(u32, 532), probe.access_times[5]);
    try std.testing.expectEqual(@as(u32, 532), probe.last_write_time);
    try std.testing.expectEqual(@as(u8, 0x81), probe.last_write_value);
    try std.testing.expectEqual(@as(u32, 532), probe.time);
    try std.testing.expectEqual(@as(u32, 50), probe.pending_wait);
}

test "cb bit (hl) uses delayed host access timing" {
    var z80 = Z80.init();
    defer z80.deinit();

    var probe = TimingProbe{ .memory = .{ 0x42, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF } };
    var bridge = HostBridge.init(TimingProbe.readHostByte, TimingProbe.peekHostByte, TimingProbe.writeHostByte, TimingProbe.onM68kBusAccess);
    bridge.bind(&z80, &probe);

    z80.writeByte(0x0000, 0xCB);
    z80.writeByte(0x0001, 0x46);

    var state = z80.captureState();
    state.pc = 0x0000;
    state.hl = 0x8000;
    state.bank = 0x0000;
    z80.restoreState(&state);

    try std.testing.expectEqual(@as(u32, 12), z80.stepInstruction());
    try std.testing.expectEqual(@as(u16, 0x0002), z80.getPc());
    try std.testing.expectEqual(@as(u8, 1), probe.access_count);
    try std.testing.expectEqual(@as(u32, 120), probe.access_times[0]);
    try std.testing.expectEqual(@as(u32, 120), probe.time);
    try std.testing.expectEqual(@as(u32, 49), probe.pending_wait);
}

test "cb banked fetches and writeback stay ordered" {
    var z80 = Z80.init();
    defer z80.deinit();

    var probe = TimingProbe{ .memory = .{ 0xCB, 0xC6, 0xFF, 0xFF, 0x80, 0xFF, 0xFF, 0xFF } };
    var bridge = HostBridge.init(TimingProbe.readHostByte, TimingProbe.peekHostByte, TimingProbe.writeHostByte, TimingProbe.onM68kBusAccess);
    bridge.bind(&z80, &probe);

    var state = z80.captureState();
    state.pc = 0x8000;
    state.hl = 0x8004;
    state.bank = 0x0000;
    z80.restoreState(&state);

    try std.testing.expectEqual(@as(u32, 15), z80.stepInstruction());
    try std.testing.expectEqual(@as(u16, 0x8002), z80.getPc());
    try std.testing.expectEqual(@as(u8, 0x81), probe.memory[4]);
    try std.testing.expectEqual(@as(u8, 4), probe.access_count);
    try std.testing.expectEqual(@as(u32, 0), probe.access_times[0]);
    try std.testing.expectEqual(@as(u32, 109), probe.access_times[1]);
    try std.testing.expectEqual(@as(u32, 219), probe.access_times[2]);
    try std.testing.expectEqual(@as(u32, 328), probe.access_times[3]);
    try std.testing.expectEqual(@as(u32, 328), probe.last_write_time);
    try std.testing.expectEqual(@as(u8, 0x81), probe.last_write_value);
    try std.testing.expectEqual(@as(u32, 328), probe.time);
    try std.testing.expectEqual(@as(u32, 50), probe.pending_wait);
}

test "push af uses delayed host stack writes" {
    var z80 = Z80.init();
    defer z80.deinit();

    var probe = TimingProbe{ .memory = .{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF } };
    var bridge = HostBridge.init(TimingProbe.readHostByte, TimingProbe.peekHostByte, TimingProbe.writeHostByte, TimingProbe.onM68kBusAccess);
    bridge.bind(&z80, &probe);

    z80.writeByte(0x0000, 0xF5);

    var state = z80.captureState();
    state.pc = 0x0000;
    state.sp = 0x8002;
    state.af = 0x2233;
    state.bank = 0x0000;
    z80.restoreState(&state);

    try std.testing.expectEqual(@as(u32, 11), z80.stepInstruction());
    try std.testing.expectEqual(@as(u16, 0x0001), z80.getPc());
    try std.testing.expectEqual(@as(u16, 0x8000), z80.getRegisterDump().sp);
    try std.testing.expectEqual(@as(u8, 2), probe.access_count);
    try std.testing.expectEqual(@as(u32, 75), probe.access_times[0]);
    try std.testing.expectEqual(@as(u32, 169), probe.access_times[1]);
    try std.testing.expectEqual(@as(u8, 0x33), probe.memory[0]);
    try std.testing.expectEqual(@as(u8, 0x22), probe.memory[1]);
    try std.testing.expectEqual(@as(u32, 169), probe.last_write_time);
    try std.testing.expectEqual(@as(u8, 0x22), probe.last_write_value);
    try std.testing.expectEqual(@as(u32, 169), probe.time);
    try std.testing.expectEqual(@as(u32, 50), probe.pending_wait);
}

test "pop hl uses delayed host stack reads" {
    var z80 = Z80.init();
    defer z80.deinit();

    var probe = TimingProbe{ .memory = .{ 0x55, 0x33, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF } };
    var bridge = HostBridge.init(TimingProbe.readHostByte, TimingProbe.peekHostByte, TimingProbe.writeHostByte, TimingProbe.onM68kBusAccess);
    bridge.bind(&z80, &probe);

    z80.writeByte(0x0000, 0xE1);

    var state = z80.captureState();
    state.pc = 0x0000;
    state.sp = 0x8000;
    state.bank = 0x0000;
    z80.restoreState(&state);

    try std.testing.expectEqual(@as(u32, 10), z80.stepInstruction());
    try std.testing.expectEqual(@as(u16, 0x0001), z80.getPc());
    try std.testing.expectEqual(@as(u16, 0x8002), z80.getRegisterDump().sp);
    try std.testing.expectEqual(@as(u16, 0x3355), z80.getRegisterDump().hl);
    try std.testing.expectEqual(@as(u8, 2), probe.access_count);
    try std.testing.expectEqual(@as(u32, 60), probe.access_times[0]);
    try std.testing.expectEqual(@as(u32, 154), probe.access_times[1]);
    try std.testing.expectEqual(@as(u32, 154), probe.time);
    try std.testing.expectEqual(@as(u32, 50), probe.pending_wait);
}

test "call nn banked fetches and stack writes stay ordered" {
    var z80 = Z80.init();
    defer z80.deinit();

    var probe = TimingProbe{ .memory = .{ 0xCD, 0x05, 0x80, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF } };
    var bridge = HostBridge.init(TimingProbe.readHostByte, TimingProbe.peekHostByte, TimingProbe.writeHostByte, TimingProbe.onM68kBusAccess);
    bridge.bind(&z80, &probe);

    var state = z80.captureState();
    state.pc = 0x8000;
    state.sp = 0x8007;
    state.bank = 0x0000;
    z80.restoreState(&state);

    try std.testing.expectEqual(@as(u32, 17), z80.stepInstruction());
    try std.testing.expectEqual(@as(u16, 0x8005), z80.getPc());
    try std.testing.expectEqual(@as(u16, 0x8005), z80.getRegisterDump().sp);
    try std.testing.expectEqual(@as(u8, 5), probe.access_count);
    try std.testing.expectEqual(@as(u32, 0), probe.access_times[0]);
    try std.testing.expectEqual(@as(u32, 109), probe.access_times[1]);
    try std.testing.expectEqual(@as(u32, 204), probe.access_times[2]);
    try std.testing.expectEqual(@as(u32, 313), probe.access_times[3]);
    try std.testing.expectEqual(@as(u32, 408), probe.access_times[4]);
    try std.testing.expectEqual(@as(u8, 0x03), probe.memory[5]);
    try std.testing.expectEqual(@as(u8, 0x80), probe.memory[6]);
    try std.testing.expectEqual(@as(u32, 408), probe.last_write_time);
    try std.testing.expectEqual(@as(u8, 0x80), probe.last_write_value);
    try std.testing.expectEqual(@as(u32, 408), probe.time);
    try std.testing.expectEqual(@as(u32, 49), probe.pending_wait);
}

test "push ix uses delayed indexed host stack writes" {
    var z80 = Z80.init();
    defer z80.deinit();

    var probe = TimingProbe{ .memory = .{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF } };
    var bridge = HostBridge.init(TimingProbe.readHostByte, TimingProbe.peekHostByte, TimingProbe.writeHostByte, TimingProbe.onM68kBusAccess);
    bridge.bind(&z80, &probe);

    z80.writeByte(0x0000, 0xDD);
    z80.writeByte(0x0001, 0xE5);

    var state = z80.captureState();
    state.pc = 0x0000;
    state.sp = 0x8002;
    state.ix = 0x2233;
    state.bank = 0x0000;
    z80.restoreState(&state);

    try std.testing.expectEqual(@as(u32, 15), z80.stepInstruction());
    try std.testing.expectEqual(@as(u16, 0x0002), z80.getPc());
    try std.testing.expectEqual(@as(u16, 0x8000), z80.getRegisterDump().sp);
    try std.testing.expectEqual(@as(u8, 2), probe.access_count);
    try std.testing.expectEqual(@as(u32, 135), probe.access_times[0]);
    try std.testing.expectEqual(@as(u32, 229), probe.access_times[1]);
    try std.testing.expectEqual(@as(u8, 0x33), probe.memory[0]);
    try std.testing.expectEqual(@as(u8, 0x22), probe.memory[1]);
    try std.testing.expectEqual(@as(u32, 229), probe.last_write_time);
    try std.testing.expectEqual(@as(u8, 0x22), probe.last_write_value);
    try std.testing.expectEqual(@as(u32, 229), probe.time);
    try std.testing.expectEqual(@as(u32, 50), probe.pending_wait);
}

test "ex (sp), hl uses delayed host stack exchange timing" {
    var z80 = Z80.init();
    defer z80.deinit();

    var probe = TimingProbe{ .memory = .{ 0x55, 0x33, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF } };
    var bridge = HostBridge.init(TimingProbe.readHostByte, TimingProbe.peekHostByte, TimingProbe.writeHostByte, TimingProbe.onM68kBusAccess);
    bridge.bind(&z80, &probe);

    z80.writeByte(0x0000, 0xE3);

    var state = z80.captureState();
    state.pc = 0x0000;
    state.sp = 0x8000;
    state.hl = 0x2211;
    state.bank = 0x0000;
    z80.restoreState(&state);

    try std.testing.expectEqual(@as(u32, 19), z80.stepInstruction());
    try std.testing.expectEqual(@as(u16, 0x0001), z80.getPc());
    try std.testing.expectEqual(@as(u16, 0x3355), z80.getRegisterDump().hl);
    try std.testing.expectEqual(@as(u8, 4), probe.access_count);
    try std.testing.expectEqual(@as(u32, 60), probe.access_times[0]);
    try std.testing.expectEqual(@as(u32, 154), probe.access_times[1]);
    try std.testing.expectEqual(@as(u32, 264), probe.access_times[2]);
    try std.testing.expectEqual(@as(u32, 358), probe.access_times[3]);
    try std.testing.expectEqual(@as(u8, 0x11), probe.memory[0]);
    try std.testing.expectEqual(@as(u8, 0x22), probe.memory[1]);
    try std.testing.expectEqual(@as(u32, 358), probe.last_write_time);
    try std.testing.expectEqual(@as(u8, 0x22), probe.last_write_value);
    try std.testing.expectEqual(@as(u32, 358), probe.time);
    try std.testing.expectEqual(@as(u32, 50), probe.pending_wait);
}

test "ex (sp), iy banked fetches and exchange writes stay ordered" {
    var z80 = Z80.init();
    defer z80.deinit();

    var probe = TimingProbe{ .memory = .{ 0xFD, 0xE3, 0xFF, 0xFF, 0x55, 0x33, 0xFF, 0xFF } };
    var bridge = HostBridge.init(TimingProbe.readHostByte, TimingProbe.peekHostByte, TimingProbe.writeHostByte, TimingProbe.onM68kBusAccess);
    bridge.bind(&z80, &probe);

    var state = z80.captureState();
    state.pc = 0x8000;
    state.sp = 0x8004;
    state.iy = 0x2211;
    state.bank = 0x0000;
    z80.restoreState(&state);

    try std.testing.expectEqual(@as(u32, 23), z80.stepInstruction());
    try std.testing.expectEqual(@as(u16, 0x8002), z80.getPc());
    try std.testing.expectEqual(@as(u16, 0x3355), z80.getRegisterDump().iy);
    try std.testing.expectEqual(@as(u8, 6), probe.access_count);
    try std.testing.expectEqual(@as(u32, 0), probe.access_times[0]);
    try std.testing.expectEqual(@as(u32, 109), probe.access_times[1]);
    try std.testing.expectEqual(@as(u32, 219), probe.access_times[2]);
    try std.testing.expectEqual(@as(u32, 313), probe.access_times[3]);
    try std.testing.expectEqual(@as(u32, 423), probe.access_times[4]);
    try std.testing.expectEqual(@as(u32, 517), probe.access_times[5]);
    try std.testing.expectEqual(@as(u8, 0x11), probe.memory[4]);
    try std.testing.expectEqual(@as(u8, 0x22), probe.memory[5]);
    try std.testing.expectEqual(@as(u32, 517), probe.last_write_time);
    try std.testing.expectEqual(@as(u8, 0x22), probe.last_write_value);
    try std.testing.expectEqual(@as(u32, 517), probe.time);
    try std.testing.expectEqual(@as(u32, 50), probe.pending_wait);
}

test "ret z only reads host stack when the condition is true" {
    var z80 = Z80.init();
    defer z80.deinit();

    var probe = TimingProbe{ .memory = .{ 0x55, 0x33, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF } };
    var bridge = HostBridge.init(TimingProbe.readHostByte, TimingProbe.peekHostByte, TimingProbe.writeHostByte, TimingProbe.onM68kBusAccess);
    bridge.bind(&z80, &probe);

    z80.writeByte(0x0000, 0xC8);

    var state = z80.captureState();
    state.pc = 0x0000;
    state.sp = 0x8000;
    state.af = 0x0040;
    state.bank = 0x0000;
    z80.restoreState(&state);

    try std.testing.expectEqual(@as(u32, 11), z80.stepInstruction());
    try std.testing.expectEqual(@as(u16, 0x3355), z80.getPc());
    try std.testing.expectEqual(@as(u16, 0x8002), z80.getRegisterDump().sp);
    try std.testing.expectEqual(@as(u8, 2), probe.access_count);
    try std.testing.expectEqual(@as(u32, 75), probe.access_times[0]);
    try std.testing.expectEqual(@as(u32, 169), probe.access_times[1]);
    try std.testing.expectEqual(@as(u32, 169), probe.time);
    try std.testing.expectEqual(@as(u32, 50), probe.pending_wait);
}

test "call z banked fetches skip host stack writes when the condition is false" {
    var z80 = Z80.init();
    defer z80.deinit();

    var probe = TimingProbe{ .memory = .{ 0xCC, 0x05, 0x80, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF } };
    var bridge = HostBridge.init(TimingProbe.readHostByte, TimingProbe.peekHostByte, TimingProbe.writeHostByte, TimingProbe.onM68kBusAccess);
    bridge.bind(&z80, &probe);

    var state = z80.captureState();
    state.pc = 0x8000;
    state.sp = 0x8007;
    state.af = 0x0000;
    state.bank = 0x0000;
    z80.restoreState(&state);

    try std.testing.expectEqual(@as(u32, 10), z80.stepInstruction());
    try std.testing.expectEqual(@as(u16, 0x8003), z80.getPc());
    try std.testing.expectEqual(@as(u16, 0x8007), z80.getRegisterDump().sp);
    try std.testing.expectEqual(@as(u8, 3), probe.access_count);
    try std.testing.expectEqual(@as(u32, 0), probe.access_times[0]);
    try std.testing.expectEqual(@as(u32, 109), probe.access_times[1]);
    try std.testing.expectEqual(@as(u32, 204), probe.access_times[2]);
    try std.testing.expectEqual(@as(u32, 204), probe.time);
    try std.testing.expectEqual(@as(u32, 49), probe.pending_wait);
}

test "reti uses delayed ed-prefixed host stack reads" {
    var z80 = Z80.init();
    defer z80.deinit();

    var probe = TimingProbe{ .memory = .{ 0x55, 0x33, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF } };
    var bridge = HostBridge.init(TimingProbe.readHostByte, TimingProbe.peekHostByte, TimingProbe.writeHostByte, TimingProbe.onM68kBusAccess);
    bridge.bind(&z80, &probe);

    z80.writeByte(0x0000, 0xED);
    z80.writeByte(0x0001, 0x4D);

    var state = z80.captureState();
    state.pc = 0x0000;
    state.sp = 0x8000;
    state.bank = 0x0000;
    z80.restoreState(&state);

    try std.testing.expectEqual(@as(u32, 14), z80.stepInstruction());
    try std.testing.expectEqual(@as(u16, 0x3355), z80.getPc());
    try std.testing.expectEqual(@as(u16, 0x8002), z80.getRegisterDump().sp);
    try std.testing.expectEqual(@as(u8, 2), probe.access_count);
    try std.testing.expectEqual(@as(u32, 120), probe.access_times[0]);
    try std.testing.expectEqual(@as(u32, 214), probe.access_times[1]);
    try std.testing.expectEqual(@as(u32, 214), probe.time);
    try std.testing.expectEqual(@as(u32, 50), probe.pending_wait);
}

test "ini uses delayed host memory write timing" {
    var z80 = Z80.init();
    defer z80.deinit();

    var probe = TimingProbe{ .memory = .{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF } };
    var bridge = HostBridge.init(TimingProbe.readHostByte, TimingProbe.peekHostByte, TimingProbe.writeHostByte, TimingProbe.onM68kBusAccess);
    bridge.bind(&z80, &probe);

    z80.writeByte(0x0000, 0xED);
    z80.writeByte(0x0001, 0xA2);

    var state = z80.captureState();
    state.pc = 0x0000;
    state.hl = 0x8000;
    state.bc = 0x0207;
    state.bank = 0x0000;
    z80.restoreState(&state);

    try std.testing.expectEqual(@as(u32, 16), z80.stepInstruction());
    try std.testing.expectEqual(@as(u16, 0x0002), z80.getPc());
    try std.testing.expectEqual(@as(u16, 0x8001), z80.getRegisterDump().hl);
    try std.testing.expectEqual(@as(u16, 0x0107), z80.getRegisterDump().bc);
    try std.testing.expectEqual(@as(u8, 1), probe.access_count);
    try std.testing.expectEqual(@as(u32, 180), probe.access_times[0]);
    try std.testing.expectEqual(@as(u8, 0xFF), probe.memory[0]);
    try std.testing.expectEqual(@as(u32, 180), probe.last_write_time);
    try std.testing.expectEqual(@as(u8, 0xFF), probe.last_write_value);
    try std.testing.expectEqual(@as(u32, 180), probe.time);
    try std.testing.expectEqual(@as(u32, 49), probe.pending_wait);
}

test "outi uses early host memory read timing" {
    var z80 = Z80.init();
    defer z80.deinit();

    var probe = TimingProbe{ .memory = .{ 0x59, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF } };
    var bridge = HostBridge.init(TimingProbe.readHostByte, TimingProbe.peekHostByte, TimingProbe.writeHostByte, TimingProbe.onM68kBusAccess);
    bridge.bind(&z80, &probe);

    z80.writeByte(0x0000, 0xED);
    z80.writeByte(0x0001, 0xA3);

    var state = z80.captureState();
    state.pc = 0x0000;
    state.hl = 0x8000;
    state.bc = 0x0207;
    state.bank = 0x0000;
    z80.restoreState(&state);

    try std.testing.expectEqual(@as(u32, 16), z80.stepInstruction());
    try std.testing.expectEqual(@as(u16, 0x0002), z80.getPc());
    try std.testing.expectEqual(@as(u16, 0x8001), z80.getRegisterDump().hl);
    try std.testing.expectEqual(@as(u16, 0x0107), z80.getRegisterDump().bc);
    try std.testing.expectEqual(@as(u8, 1), probe.access_count);
    try std.testing.expectEqual(@as(u32, 60), probe.access_times[0]);
    try std.testing.expectEqual(@as(u32, 60), probe.time);
    try std.testing.expectEqual(@as(u32, 49), probe.pending_wait);
}

test "inir banked fetches and host memory write stay ordered" {
    var z80 = Z80.init();
    defer z80.deinit();

    var probe = TimingProbe{ .memory = .{ 0xED, 0xB2, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF } };
    var bridge = HostBridge.init(TimingProbe.readHostByte, TimingProbe.peekHostByte, TimingProbe.writeHostByte, TimingProbe.onM68kBusAccess);
    bridge.bind(&z80, &probe);

    var state = z80.captureState();
    state.pc = 0x8000;
    state.hl = 0x8004;
    state.bc = 0x0207;
    state.bank = 0x0000;
    z80.restoreState(&state);

    try std.testing.expectEqual(@as(u32, 21), z80.stepInstruction());
    try std.testing.expectEqual(@as(u16, 0x8000), z80.getPc());
    try std.testing.expectEqual(@as(u16, 0x8005), z80.getRegisterDump().hl);
    try std.testing.expectEqual(@as(u16, 0x0107), z80.getRegisterDump().bc);
    try std.testing.expectEqual(@as(u8, 3), probe.access_count);
    try std.testing.expectEqual(@as(u32, 0), probe.access_times[0]);
    try std.testing.expectEqual(@as(u32, 109), probe.access_times[1]);
    try std.testing.expectEqual(@as(u32, 279), probe.access_times[2]);
    try std.testing.expectEqual(@as(u8, 0xFF), probe.memory[4]);
    try std.testing.expectEqual(@as(u32, 279), probe.last_write_time);
    try std.testing.expectEqual(@as(u8, 0xFF), probe.last_write_value);
    try std.testing.expectEqual(@as(u32, 279), probe.time);
    try std.testing.expectEqual(@as(u32, 49), probe.pending_wait);
}

test "rld uses delayed host read and write timing" {
    var z80 = Z80.init();
    defer z80.deinit();

    var probe = TimingProbe{ .memory = .{ 0xCD, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF } };
    var bridge = HostBridge.init(TimingProbe.readHostByte, TimingProbe.peekHostByte, TimingProbe.writeHostByte, TimingProbe.onM68kBusAccess);
    bridge.bind(&z80, &probe);

    z80.writeByte(0x0000, 0xED);
    z80.writeByte(0x0001, 0x6F);

    var state = z80.captureState();
    state.pc = 0x0000;
    state.hl = 0x8000;
    state.af = 0xAB00;
    state.bank = 0x0000;
    z80.restoreState(&state);

    try std.testing.expectEqual(@as(u32, 18), z80.stepInstruction());
    try std.testing.expectEqual(@as(u16, 0x0002), z80.getPc());
    try std.testing.expectEqual(@as(u8, 0xAC), @as(u8, @truncate(z80.getRegisterDump().af >> 8)));
    try std.testing.expectEqual(@as(u8, 2), probe.access_count);
    try std.testing.expectEqual(@as(u32, 120), probe.access_times[0]);
    try std.testing.expectEqual(@as(u32, 214), probe.access_times[1]);
    try std.testing.expectEqual(@as(u8, 0xDB), probe.memory[0]);
    try std.testing.expectEqual(@as(u32, 214), probe.last_write_time);
    try std.testing.expectEqual(@as(u8, 0xDB), probe.last_write_value);
    try std.testing.expectEqual(@as(u32, 214), probe.time);
    try std.testing.expectEqual(@as(u32, 50), probe.pending_wait);
}

test "rrd banked fetches and host writeback stay ordered" {
    var z80 = Z80.init();
    defer z80.deinit();

    var probe = TimingProbe{ .memory = .{ 0xED, 0x67, 0xFF, 0xFF, 0xCD, 0xFF, 0xFF, 0xFF } };
    var bridge = HostBridge.init(TimingProbe.readHostByte, TimingProbe.peekHostByte, TimingProbe.writeHostByte, TimingProbe.onM68kBusAccess);
    bridge.bind(&z80, &probe);

    var state = z80.captureState();
    state.pc = 0x8000;
    state.hl = 0x8004;
    state.af = 0xAB00;
    state.bank = 0x0000;
    z80.restoreState(&state);

    try std.testing.expectEqual(@as(u32, 18), z80.stepInstruction());
    try std.testing.expectEqual(@as(u16, 0x8002), z80.getPc());
    try std.testing.expectEqual(@as(u8, 0xAD), @as(u8, @truncate(z80.getRegisterDump().af >> 8)));
    try std.testing.expectEqual(@as(u8, 4), probe.access_count);
    try std.testing.expectEqual(@as(u32, 0), probe.access_times[0]);
    try std.testing.expectEqual(@as(u32, 109), probe.access_times[1]);
    try std.testing.expectEqual(@as(u32, 219), probe.access_times[2]);
    try std.testing.expectEqual(@as(u32, 313), probe.access_times[3]);
    try std.testing.expectEqual(@as(u8, 0xBC), probe.memory[4]);
    try std.testing.expectEqual(@as(u32, 313), probe.last_write_time);
    try std.testing.expectEqual(@as(u8, 0xBC), probe.last_write_value);
    try std.testing.expectEqual(@as(u32, 313), probe.time);
    try std.testing.expectEqual(@as(u32, 50), probe.pending_wait);
}

test "ldir banked fetches and host transfer accesses stay ordered" {
    var z80 = Z80.init();
    defer z80.deinit();

    var probe = TimingProbe{ .memory = .{ 0xED, 0xB0, 0x42, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF } };
    var bridge = HostBridge.init(TimingProbe.readHostByte, TimingProbe.peekHostByte, TimingProbe.writeHostByte, TimingProbe.onM68kBusAccess);
    bridge.bind(&z80, &probe);

    var state = z80.captureState();
    state.pc = 0x8000;
    state.hl = 0x8002;
    state.de = 0x8004;
    state.bc = 0x0001;
    state.bank = 0x0000;
    z80.restoreState(&state);

    try std.testing.expectEqual(@as(u32, 16), z80.stepInstruction());
    try std.testing.expectEqual(@as(u16, 0x8002), z80.getPc());
    try std.testing.expectEqual(@as(u16, 0x8003), z80.getRegisterDump().hl);
    try std.testing.expectEqual(@as(u16, 0x8005), z80.getRegisterDump().de);
    try std.testing.expectEqual(@as(u16, 0x0000), z80.getRegisterDump().bc);
    try std.testing.expectEqual(@as(u8, 4), probe.access_count);
    try std.testing.expectEqual(@as(u32, 0), probe.access_times[0]);
    try std.testing.expectEqual(@as(u32, 109), probe.access_times[1]);
    try std.testing.expectEqual(@as(u32, 219), probe.access_times[2]);
    try std.testing.expectEqual(@as(u32, 313), probe.access_times[3]);
    try std.testing.expectEqual(@as(u8, 0x42), probe.memory[4]);
    try std.testing.expectEqual(@as(u32, 313), probe.last_write_time);
    try std.testing.expectEqual(@as(u8, 0x42), probe.last_write_value);
    try std.testing.expectEqual(@as(u32, 313), probe.time);
    try std.testing.expectEqual(@as(u32, 50), probe.pending_wait);
}

test "cpir banked fetches and host compare read stay ordered" {
    var z80 = Z80.init();
    defer z80.deinit();

    var probe = TimingProbe{ .memory = .{ 0xED, 0xB1, 0x42, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF } };
    var bridge = HostBridge.init(TimingProbe.readHostByte, TimingProbe.peekHostByte, TimingProbe.writeHostByte, TimingProbe.onM68kBusAccess);
    bridge.bind(&z80, &probe);

    var state = z80.captureState();
    state.pc = 0x8000;
    state.hl = 0x8002;
    state.bc = 0x0002;
    state.af = 0x4000;
    state.bank = 0x0000;
    z80.restoreState(&state);

    try std.testing.expectEqual(@as(u32, 21), z80.stepInstruction());
    try std.testing.expectEqual(@as(u16, 0x8000), z80.getPc());
    try std.testing.expectEqual(@as(u16, 0x8003), z80.getRegisterDump().hl);
    try std.testing.expectEqual(@as(u16, 0x0001), z80.getRegisterDump().bc);
    try std.testing.expectEqual(@as(u8, 3), probe.access_count);
    try std.testing.expectEqual(@as(u32, 0), probe.access_times[0]);
    try std.testing.expectEqual(@as(u32, 109), probe.access_times[1]);
    try std.testing.expectEqual(@as(u32, 219), probe.access_times[2]);
    try std.testing.expectEqual(@as(u32, 219), probe.time);
    try std.testing.expectEqual(@as(u32, 49), probe.pending_wait);
}

test "ld (nn), bc uses delayed ed direct-word host writes" {
    var z80 = Z80.init();
    defer z80.deinit();

    var probe = TimingProbe{};
    var bridge = HostBridge.init(TimingProbe.readHostByte, TimingProbe.peekHostByte, TimingProbe.writeHostByte, TimingProbe.onM68kBusAccess);
    bridge.bind(&z80, &probe);

    z80.writeByte(0x0000, 0xED);
    z80.writeByte(0x0001, 0x43);
    z80.writeByte(0x0002, 0x00);
    z80.writeByte(0x0003, 0x80);

    var state = z80.captureState();
    state.pc = 0x0000;
    state.bc = 0x1234;
    state.bank = 0x0000;
    z80.restoreState(&state);

    try std.testing.expectEqual(@as(u32, 20), z80.stepInstruction());
    try std.testing.expectEqual(@as(u16, 0x0004), z80.getPc());
    try std.testing.expectEqual(@as(u8, 2), probe.access_count);
    try std.testing.expectEqual(@as(u32, 210), probe.access_times[0]);
    try std.testing.expectEqual(@as(u32, 304), probe.access_times[1]);
    try std.testing.expectEqual(@as(u8, 0x34), probe.memory[0]);
    try std.testing.expectEqual(@as(u8, 0x12), probe.memory[1]);
    try std.testing.expectEqual(@as(u32, 304), probe.last_write_time);
    try std.testing.expectEqual(@as(u8, 0x12), probe.last_write_value);
    try std.testing.expectEqual(@as(u32, 304), probe.time);
    try std.testing.expectEqual(@as(u32, 50), probe.pending_wait);
}

test "ld hl, (nn) banked fetches and ed host reads stay ordered" {
    var z80 = Z80.init();
    defer z80.deinit();

    var probe = TimingProbe{ .memory = .{ 0xED, 0x6B, 0x04, 0x80, 0x78, 0x56, 0xFF, 0xFF } };
    var bridge = HostBridge.init(TimingProbe.readHostByte, TimingProbe.peekHostByte, TimingProbe.writeHostByte, TimingProbe.onM68kBusAccess);
    bridge.bind(&z80, &probe);

    var state = z80.captureState();
    state.pc = 0x8000;
    state.bank = 0x0000;
    z80.restoreState(&state);

    try std.testing.expectEqual(@as(u32, 20), z80.stepInstruction());
    try std.testing.expectEqual(@as(u16, 0x8004), z80.getPc());
    try std.testing.expectEqual(@as(u16, 0x5678), z80.getRegisterDump().hl);
    try std.testing.expectEqual(@as(u8, 6), probe.access_count);
    try std.testing.expectEqual(@as(u32, 0), probe.access_times[0]);
    try std.testing.expectEqual(@as(u32, 109), probe.access_times[1]);
    try std.testing.expectEqual(@as(u32, 219), probe.access_times[2]);
    try std.testing.expectEqual(@as(u32, 313), probe.access_times[3]);
    try std.testing.expectEqual(@as(u32, 408), probe.access_times[4]);
    try std.testing.expectEqual(@as(u32, 502), probe.access_times[5]);
    try std.testing.expectEqual(@as(u32, 502), probe.time);
    try std.testing.expectEqual(@as(u32, 50), probe.pending_wait);
}
