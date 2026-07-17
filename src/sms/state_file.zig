const std = @import("std");
const testing = std.testing;
const SmsMachine = @import("machine.zig").SmsMachine;
const SmsBus = @import("bus.zig").SmsBus;
const SmsVdp = @import("vdp.zig").SmsVdp;
const Z80 = @import("../cpu/z80.zig").Z80;
const Psg = @import("../audio/psg.zig").Psg;

pub const magic = [8]u8{ 'S', 'N', 'D', 'S', 'M', 'S', 'S', 'T' };
// v3: added is_sg1000 flag (SG-1000 games silently became SMS on load).
// v4: added I/O port state (memory/io control, GG regs) and PSG state;
//     both were silently reset to power-on defaults on load.
// v5: SmsVdp gained latched_vscroll (reg 9 latched per frame), which
//     changes the raw-struct serialization layout.
// v6: Jgz80State gained ym_timer_watermark.
pub const version: u16 = 6;

/// Serialize SMS machine state into a byte buffer.
pub fn saveToBuffer(allocator: std.mem.Allocator, sms: *const SmsMachine) ![]u8 {
    var snapshot = try sms.captureSnapshot(allocator);
    defer snapshot.deinit(allocator);
    const m = &snapshot.machine;

    var list = std.ArrayListUnmanaged(u8).empty;
    errdefer list.deinit(allocator);

    // Header
    try list.appendSlice(allocator, &magic);
    try list.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToLittle(u16, version)));
    try list.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToLittle(u32, @as(u32, @intCast(m.bus.rom.len)))));

    // Variant flags
    try list.append(allocator, @intFromBool(m.is_game_gear));
    try list.append(allocator, @intFromBool(m.is_sg1000));

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

    // I/O port state
    try list.append(allocator, m.bus.io.memory_control);
    try list.append(allocator, m.bus.io.io_control);
    try list.appendSlice(allocator, &m.bus.io.gg_regs);

    // PSG state
    try appendPsg(allocator, &list, &m.audio.psg);

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

    // Variant flags
    const is_gg = (try readSlice(data, &pos, 1))[0] != 0;
    const is_sg = (try readSlice(data, &pos, 1))[0] != 0;

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

    // I/O port state
    const memory_control = (try readSlice(data, &pos, 1))[0];
    const io_control = (try readSlice(data, &pos, 1))[0];
    const gg_regs = try readSlice(data, &pos, 7);

    // PSG state
    const psg = try readPsg(data, &pos);

    // ROM
    const rom_data = try readSlice(data, &pos, rom_len);

    // Build new machine
    var machine = try SmsMachine.initFromRomBytes(allocator, rom_data);
    errdefer machine.deinit(allocator);

    machine.is_game_gear = is_gg;
    machine.is_sg1000 = is_sg;
    @memcpy(&machine.bus.ram, ram);
    @memcpy(std.mem.asBytes(&machine.bus.vdp), vdp_bytes);
    // Sanitize scalar fields byte-wise before any typed use: a corrupt
    // state can plant invalid bit patterns in bools/small ints (UB), and
    // out-of-range address bits would index VRAM out of bounds.
    const vdp_raw = std.mem.asBytes(&machine.bus.vdp);
    inline for ([_][]const u8{
        "control_latch", "vint_pending", "hint_pending",
        "pal_mode",      "is_game_gear", "is_sg1000",
    }) |field| {
        const off = @offsetOf(SmsVdp, field);
        vdp_raw[off] = @intFromBool(vdp_raw[off] != 0);
    }
    vdp_raw[@offsetOf(SmsVdp, "code")] &= 0x03;
    const addr_off = @offsetOf(SmsVdp, "addr");
    const addr_raw = std.mem.readInt(u16, vdp_raw[addr_off..][0..2], .little);
    std.mem.writeInt(u16, vdp_raw[addr_off..][0..2], addr_raw & 0x3FFF, .little);
    machine.bus.vdp.is_game_gear = is_gg; // Re-apply after VDP state overwrite
    if (machine.bus.vdp.scanline >= machine.bus.vdp.totalLines()) machine.bus.vdp.scanline = 0;
    @memcpy(&machine.bus.page, page_regs);
    machine.bus.ram_bank_enabled = ram_bank_enabled;
    machine.bus.ram_bank = ram_bank;
    @memcpy(&machine.bus.cartridge_ram, cartridge_ram);
    machine.pal_mode = pal_mode;
    machine.z80_cycle_count = z80_cycle_count;
    machine.bus.io.memory_control = memory_control;
    machine.bus.io.io_control = io_control;
    @memcpy(&machine.bus.io.gg_regs, gg_regs);
    machine.audio.psg = psg;
    machine.z80.restoreState(&z80_state);
    machine.bound = false;

    return machine;
}

fn appendInt(comptime T: type, allocator: std.mem.Allocator, list: *std.ArrayListUnmanaged(u8), value: T) !void {
    try list.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToLittle(T, value)));
}

fn appendPsg(allocator: std.mem.Allocator, list: *std.ArrayListUnmanaged(u8), psg: *const Psg) !void {
    for (psg.tones) |tone| {
        try appendInt(u16, allocator, list, tone.countdown);
        try appendInt(u16, allocator, list, tone.countdown_master);
        try list.append(allocator, tone.attenuation);
        try appendInt(i16, allocator, list, tone.level);
        try list.append(allocator, tone.output_bit);
    }
    try appendInt(u16, allocator, list, psg.noise.countdown);
    try list.append(allocator, psg.noise.attenuation);
    try appendInt(i16, allocator, list, psg.noise.level);
    try list.append(allocator, psg.noise.fake_output_bit);
    try list.append(allocator, psg.noise.real_output_bit);
    try list.append(allocator, psg.noise.frequency_mode);
    try list.append(allocator, @intFromBool(psg.noise.noise_type == .white));
    try appendInt(u16, allocator, list, psg.noise.shift_register);
    try list.append(allocator, psg.latched.channel);
    try list.append(allocator, @intFromBool(psg.latched.is_volume));
    var pan_mask: u8 = 0;
    for (psg.channel_pan, 0..) |pan, ch| {
        if (pan[0]) pan_mask |= @as(u8, 1) << @intCast(ch * 2);
        if (pan[1]) pan_mask |= @as(u8, 1) << @intCast(ch * 2 + 1);
    }
    try list.append(allocator, pan_mask);
}

fn readU16(data: []const u8, pos: *usize) !u16 {
    return std.mem.readInt(u16, (try readSlice(data, pos, 2))[0..2], .little);
}

fn readPsg(data: []const u8, pos: *usize) !Psg {
    // Small-int fields are truncated to their legal ranges so a corrupt
    // state cannot plant invalid bit patterns.
    var psg = Psg{};
    for (&psg.tones) |*tone| {
        tone.countdown = try readU16(data, pos);
        tone.countdown_master = try readU16(data, pos);
        tone.attenuation = @truncate((try readSlice(data, pos, 1))[0]);
        tone.level = @bitCast(try readU16(data, pos));
        tone.output_bit = @truncate((try readSlice(data, pos, 1))[0]);
    }
    psg.noise.countdown = try readU16(data, pos);
    psg.noise.attenuation = @truncate((try readSlice(data, pos, 1))[0]);
    psg.noise.level = @bitCast(try readU16(data, pos));
    psg.noise.fake_output_bit = @truncate((try readSlice(data, pos, 1))[0]);
    psg.noise.real_output_bit = @truncate((try readSlice(data, pos, 1))[0]);
    psg.noise.frequency_mode = @truncate((try readSlice(data, pos, 1))[0]);
    psg.noise.noise_type = if ((try readSlice(data, pos, 1))[0] != 0) .white else .periodic;
    psg.noise.shift_register = try readU16(data, pos);
    psg.latched.channel = @truncate((try readSlice(data, pos, 1))[0]);
    psg.latched.is_volume = (try readSlice(data, pos, 1))[0] != 0;
    const pan_mask = (try readSlice(data, pos, 1))[0];
    for (&psg.channel_pan, 0..) |*pan, ch| {
        pan[0] = (pan_mask >> @intCast(ch * 2)) & 1 != 0;
        pan[1] = (pan_mask >> @intCast(ch * 2 + 1)) & 1 != 0;
    }
    return psg;
}

fn readSlice(data: []const u8, pos: *usize, len: usize) ![]const u8 {
    // Subtraction form: `pos + len` could wrap on 32-bit targets when `len`
    // comes from a corrupt header.
    if (len > data.len - pos.*) return error.EndOfStream;
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

test "sms state round-trip preserves io and psg state" {
    var rom = [_]u8{0xC7} ** 1024;
    var machine = try SmsMachine.initFromRomBytes(testing.allocator, &rom);
    defer machine.deinit(testing.allocator);
    machine.bindPointers();
    machine.runFrame();

    machine.bus.io.memory_control = 0x04;
    machine.bus.io.io_control = 0xAA;
    machine.bus.io.gg_regs[6] = 0x55;
    machine.audio.psg.doCommand(0x8F); // Latch tone 0, low period bits
    machine.audio.psg.doCommand(0x2A); // High period bits
    machine.audio.psg.doCommand(0x93); // Tone 0 attenuation 3
    machine.audio.psg.doCommand(0xE5); // Noise: white, frequency mode 1
    machine.audio.psg.setPanning(0x35);

    const buf = try saveToBuffer(testing.allocator, &machine);
    defer testing.allocator.free(buf);

    var restored = try loadFromBuffer(testing.allocator, buf);
    defer restored.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0x04), restored.bus.io.memory_control);
    try testing.expectEqual(@as(u8, 0xAA), restored.bus.io.io_control);
    try testing.expectEqual(@as(u8, 0x55), restored.bus.io.gg_regs[6]);
    try testing.expectEqualDeep(machine.audio.psg, restored.audio.psg);
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
