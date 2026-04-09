const std = @import("std");
const testing = std.testing;
const SmsMachine = @import("machine.zig").SmsMachine;
const SmsBus = @import("bus.zig").SmsBus;
const SmsVdp = @import("vdp.zig").SmsVdp;
const Z80 = @import("../cpu/z80.zig").Z80;

pub const magic = [8]u8{ 'S', 'N', 'D', 'S', 'M', 'S', 'S', 'T' };
pub const version: u16 = 2;

/// Serialize SMS machine state into a byte buffer.
pub fn saveToBuffer(allocator: std.mem.Allocator, sms: *const SmsMachine) ![]u8 {
    var snapshot = try sms.captureSnapshot(allocator);
    defer snapshot.deinit(allocator);
    const m = &snapshot.machine;

    var list = std.ArrayListUnmanaged(u8){};
    errdefer list.deinit(allocator);

    // Header
    try list.appendSlice(allocator, &magic);
    try list.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToLittle(u16, version)));
    try list.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToLittle(u32, @as(u32, @intCast(m.bus.rom.len)))));

    // is_game_gear flag
    try list.append(allocator, @intFromBool(m.is_game_gear));

    // Z80 state
    const z80_state = m.z80.captureState();
    try list.appendSlice(allocator, std.mem.asBytes(&z80_state));

    // VDP state
    try list.appendSlice(allocator, std.mem.asBytes(&m.bus.vdp));

    // Bus RAM, mapper, cartridge RAM
    try list.appendSlice(allocator, &m.bus.ram);
    try list.appendSlice(allocator, &m.bus.page);
    try list.append(allocator, @intFromBool(m.bus.ram_bank_enabled));
    try list.append(allocator, @as(u8, m.bus.ram_bank));
    try list.appendSlice(allocator, &m.bus.cartridge_ram);

    // Machine state
    try list.append(allocator, @intFromBool(m.pal_mode));
    try list.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToLittle(u32, m.z80_cycle_count)));

    // ROM data
    try list.appendSlice(allocator, m.bus.rom);

    return list.toOwnedSlice(allocator);
}

/// Deserialize SMS machine state from a byte buffer.
pub fn loadFromBuffer(allocator: std.mem.Allocator, data: []const u8) !SmsMachine {
    var pos: usize = 0;

    // Verify header
    const magic_bytes = try readSlice(data, &pos, 8);
    if (!std.mem.eql(u8, magic_bytes, &magic)) return error.InvalidSaveState;
    const ver = std.mem.readInt(u16, (try readSlice(data, &pos, 2))[0..2], .little);
    if (ver != version) return error.UnsupportedSaveStateVersion;
    const rom_len = std.mem.readInt(u32, (try readSlice(data, &pos, 4))[0..4], .little);

    // is_game_gear flag
    const is_gg = (try readSlice(data, &pos, 1))[0] != 0;

    // Z80 state
    const z80_bytes = try readSlice(data, &pos, @sizeOf(Z80.State));
    var z80_state: Z80.State = undefined;
    @memcpy(std.mem.asBytes(&z80_state), z80_bytes);

    // VDP state
    const vdp_bytes = try readSlice(data, &pos, @sizeOf(SmsVdp));

    // Bus state
    const ram = try readSlice(data, &pos, 8 * 1024);
    const page_regs = try readSlice(data, &pos, 3);
    const ram_bank_enabled = (try readSlice(data, &pos, 1))[0] != 0;
    const ram_bank: u1 = @truncate((try readSlice(data, &pos, 1))[0]);
    const cartridge_ram = try readSlice(data, &pos, 2 * 16 * 1024);

    // Machine state
    const pal_mode = (try readSlice(data, &pos, 1))[0] != 0;
    const z80_cycle_count = std.mem.readInt(u32, (try readSlice(data, &pos, 4))[0..4], .little);

    // ROM
    const rom_data = try readSlice(data, &pos, rom_len);

    // Build new machine
    var machine = try SmsMachine.initFromRomBytes(allocator, rom_data);
    errdefer machine.deinit(allocator);

    machine.is_game_gear = is_gg;
    @memcpy(&machine.bus.ram, ram);
    @memcpy(std.mem.asBytes(&machine.bus.vdp), vdp_bytes);
    @memcpy(&machine.bus.page, page_regs);
    machine.bus.ram_bank_enabled = ram_bank_enabled;
    machine.bus.ram_bank = ram_bank;
    @memcpy(&machine.bus.cartridge_ram, cartridge_ram);
    machine.pal_mode = pal_mode;
    machine.z80_cycle_count = z80_cycle_count;
    machine.z80.restoreState(&z80_state);
    machine.bound = false;

    return machine;
}

fn readSlice(data: []const u8, pos: *usize, len: usize) ![]const u8 {
    if (pos.* + len > data.len) return error.EndOfStream;
    const slice = data[pos.*..][0..len];
    pos.* += len;
    return slice;
}

test "sms state round-trip" {
    var rom = [_]u8{0xC7} ** 1024;
    var machine = try SmsMachine.initFromRomBytes(testing.allocator, &rom);
    defer machine.deinit(testing.allocator);
    machine.bindPointers();

    // Run a few frames to establish state
    for (0..5) |_| machine.runFrame();

    // Save
    const buf = try saveToBuffer(testing.allocator, &machine);
    defer testing.allocator.free(buf);

    // Verify header
    try testing.expectEqualStrings("SNDSMSS", buf[0..7]);

    // Load
    var restored = try loadFromBuffer(testing.allocator, buf);
    defer restored.deinit(testing.allocator);

    try testing.expectEqual(machine.z80_cycle_count, restored.z80_cycle_count);
    try testing.expectEqual(machine.pal_mode, restored.pal_mode);
    try testing.expectEqualSlices(u8, &machine.bus.ram, &restored.bus.ram);
    try testing.expectEqualSlices(u8, &machine.bus.page, &restored.bus.page);
}

test "gg state round-trip preserves is_game_gear flag" {
    var rom = [_]u8{0xC7} ** 1024;
    var machine = try SmsMachine.initFromRomBytes(testing.allocator, &rom);
    defer machine.deinit(testing.allocator);
    machine.is_game_gear = true;
    machine.bindPointers();

    for (0..3) |_| machine.runFrame();

    const buf = try saveToBuffer(testing.allocator, &machine);
    defer testing.allocator.free(buf);

    var restored = try loadFromBuffer(testing.allocator, buf);
    defer restored.deinit(testing.allocator);

    try testing.expect(restored.is_game_gear);
}
