const std = @import("std");
const testing = std.testing;
const clock = @import("clock.zig");
const Machine = @import("machine.zig").Machine;
const Vdp = @import("video/vdp.zig").Vdp;
const Io = @import("input/io.zig").Io;
const AudioTiming = @import("audio/timing.zig").AudioTiming;
const Cpu = @import("cpu/cpu.zig").Cpu;
const Z80 = @import("cpu/z80.zig").Z80;

const save_state_magic = [8]u8{ 'S', 'N', 'D', 'S', 'T', 'A', 'T', 'E' };
const save_state_version: u16 = 1;
const default_state_name = "sandopolis.state";
pub const default_persistent_state_slot: u8 = 1;
pub const persistent_state_slot_count: u8 = 3;

const Header = struct {
    magic: [8]u8,
    version: u16,
    rom_len: u32,
    cartridge_ram_len: u32,
    save_path_len: u32,
    source_path_len: u32,
};

const BusState = struct {
    ram: [64 * 1024]u8,
    vdp: Vdp,
    io: Io,
    audio_timing: AudioTiming,
    io_master_remainder: u8,
    z80_master_credit: i64,
    z80_wait_master_cycles: u32,
    z80_odd_access: bool,
    m68k_wait_master_cycles: u32,
    open_bus: u16,
    cartridge_ram_type: u8,
    cartridge_ram_persistent: bool,
    cartridge_ram_dirty: bool,
    cartridge_ram_mapped: bool,
    cartridge_ram_start_address: u32,
    cartridge_ram_end_address: u32,
    m68k_sync: clock.M68kSync,
};

pub const Error = error{
    InvalidSaveState,
    UnsupportedSaveStateVersion,
};

fn storageIntType(comptime T: type) type {
    const int_info = @typeInfo(T).int;
    const bit_count: u16 = ((int_info.bits + 7) / 8) * 8;
    return std.meta.Int(int_info.signedness, bit_count);
}

fn writeValue(writer: anytype, value: anytype) !void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .bool => {
            try writer.writeByte(@intFromBool(value));
        },
        .int => {
            const Storage = comptime storageIntType(T);
            try writer.writeInt(Storage, @as(Storage, value), std.builtin.Endian.little);
        },
        .@"enum" => {
            try writeValue(writer, @intFromEnum(value));
        },
        .array => |array_info| {
            if (array_info.child == u8) {
                try writer.writeAll(value[0..]);
                return;
            }

            for (value) |item| {
                try writeValue(writer, item);
            }
        },
        .@"struct" => |struct_info| {
            inline for (struct_info.fields) |field| {
                try writeValue(writer, @field(value, field.name));
            }
        },
        .@"union" => |union_info| {
            _ = union_info.tag_type orelse @compileError("save-state unions must be tagged");
            const tag = std.meta.activeTag(value);
            try writeValue(writer, tag);

            switch (value) {
                inline else => |payload| try writeValue(writer, payload),
            }
        },
        else => {
            @compileError("unsupported save-state field type: " ++ @typeName(T));
        },
    }
}

fn readValue(reader: anytype, comptime T: type) !T {
    var value: T = undefined;
    try readInto(reader, &value);
    return value;
}

fn readInto(reader: anytype, out: anytype) !void {
    const T = @typeInfo(@TypeOf(out)).pointer.child;
    switch (@typeInfo(T)) {
        .bool => {
            out.* = (try reader.takeByte()) != 0;
        },
        .int => {
            const Storage = comptime storageIntType(T);
            const raw = try reader.takeInt(Storage, std.builtin.Endian.little);
            out.* = @intCast(raw);
        },
        .@"enum" => |enum_info| {
            const raw = try readValue(reader, enum_info.tag_type);
            out.* = @enumFromInt(raw);
        },
        .array => |array_info| {
            if (array_info.child == u8) {
                try reader.readSliceAll(out[0..]);
                return;
            }

            var index: usize = 0;
            while (index < out.len) : (index += 1) {
                try readInto(reader, &out[index]);
            }
        },
        .@"struct" => |struct_info| {
            inline for (struct_info.fields) |field| {
                try readInto(reader, &@field(out.*, field.name));
            }
        },
        .@"union" => |union_info| {
            const Tag = union_info.tag_type orelse @compileError("save-state unions must be tagged");
            const tag = try readValue(reader, Tag);

            inline for (union_info.fields) |field| {
                if (tag == @field(Tag, field.name)) {
                    var payload: field.type = undefined;
                    try readInto(reader, &payload);
                    out.* = @unionInit(T, field.name, payload);
                    return;
                }
            }

            return error.InvalidSaveState;
        },
        else => {
            @compileError("unsupported save-state field type: " ++ @typeName(T));
        },
    }
}

fn readOwnedBytes(allocator: std.mem.Allocator, reader: anytype, len: usize) !?[]u8 {
    if (len == 0) return null;

    const bytes = try allocator.alloc(u8, len);
    errdefer allocator.free(bytes);
    try reader.readSliceAll(bytes);
    return bytes;
}

fn replaceExtension(allocator: std.mem.Allocator, path: []const u8, extension: []const u8) ![]u8 {
    const current_extension = std.fs.path.extension(path);
    if (current_extension.len == 0) {
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ path, extension });
    }

    return std.fmt.allocPrint(allocator, "{s}{s}", .{
        path[0 .. path.len - current_extension.len],
        extension,
    });
}

pub fn normalizePersistentStateSlot(slot: u8) u8 {
    return if (slot >= default_persistent_state_slot and slot <= persistent_state_slot_count)
        slot
    else
        default_persistent_state_slot;
}

pub fn nextPersistentStateSlot(slot: u8) u8 {
    const normalized = normalizePersistentStateSlot(slot);
    return if (normalized == persistent_state_slot_count) default_persistent_state_slot else normalized + 1;
}

pub fn pathForSlot(allocator: std.mem.Allocator, path: []const u8, slot: u8) ![]u8 {
    const normalized = normalizePersistentStateSlot(slot);
    if (normalized == default_persistent_state_slot) {
        return allocator.dupe(u8, path);
    }

    const current_extension = std.fs.path.extension(path);
    if (current_extension.len == 0) {
        return std.fmt.allocPrint(allocator, "{s}.slot{d}.state", .{ path, normalized });
    }

    return std.fmt.allocPrint(allocator, "{s}.slot{d}{s}", .{
        path[0 .. path.len - current_extension.len],
        normalized,
        current_extension,
    });
}

fn captureBusState(machine: *const Machine) BusState {
    return .{
        .ram = machine.bus.ram,
        .vdp = machine.bus.vdp,
        .io = machine.bus.io,
        .audio_timing = machine.bus.audio_timing,
        .io_master_remainder = machine.bus.io_master_remainder,
        .z80_master_credit = machine.bus.z80_master_credit,
        .z80_wait_master_cycles = machine.bus.z80_wait_master_cycles,
        .z80_odd_access = machine.bus.z80_odd_access,
        .m68k_wait_master_cycles = machine.bus.m68k_wait_master_cycles,
        .open_bus = machine.bus.open_bus,
        .cartridge_ram_type = @intFromEnum(machine.bus.cartridge.ram.ram_type),
        .cartridge_ram_persistent = machine.bus.cartridge.ram.persistent,
        .cartridge_ram_dirty = machine.bus.cartridge.ram.dirty,
        .cartridge_ram_mapped = machine.bus.cartridge.ram.mapped,
        .cartridge_ram_start_address = machine.bus.cartridge.ram.start_address,
        .cartridge_ram_end_address = machine.bus.cartridge.ram.end_address,
        .m68k_sync = machine.m68k_sync,
    };
}

pub fn defaultPathForMachine(allocator: std.mem.Allocator, machine: *const Machine) ![]u8 {
    if (machine.bus.cartridge.sourcePath()) |source_path| {
        return replaceExtension(allocator, source_path, ".state");
    }
    return allocator.dupe(u8, default_state_name);
}

pub fn pathForMachineSlot(allocator: std.mem.Allocator, machine: *const Machine, slot: u8) ![]u8 {
    const normalized = normalizePersistentStateSlot(slot);
    const default_path = try defaultPathForMachine(allocator, machine);
    if (normalized == default_persistent_state_slot) {
        return default_path;
    }
    defer allocator.free(default_path);
    return pathForSlot(allocator, default_path, normalized);
}

pub fn saveToFile(machine: *const Machine, path: []const u8) !void {
    const rom_len: u32 = @intCast(machine.bus.cartridge.rom.len);
    const cartridge_ram = machine.bus.cartridge.ram.data;
    const cartridge_ram_len: u32 = @intCast(if (cartridge_ram) |bytes| bytes.len else 0);
    const save_path_len: u32 = @intCast(if (machine.bus.cartridge.save_path) |bytes| bytes.len else 0);
    const source_path_len: u32 = @intCast(if (machine.bus.cartridge.source_path) |bytes| bytes.len else 0);

    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();

    var buffer: [4096]u8 = undefined;
    var file_writer = file.writer(&buffer);
    const writer = &file_writer.interface;

    try writeValue(writer, Header{
        .magic = save_state_magic,
        .version = save_state_version,
        .rom_len = rom_len,
        .cartridge_ram_len = cartridge_ram_len,
        .save_path_len = save_path_len,
        .source_path_len = source_path_len,
    });
    try writeValue(writer, captureBusState(machine));
    try writeValue(writer, machine.cpu.captureState());
    try writeValue(writer, machine.bus.z80.captureState());
    try writer.writeAll(machine.bus.cartridge.rom);
    if (cartridge_ram) |bytes| try writer.writeAll(bytes);
    if (machine.bus.cartridge.save_path) |bytes| try writer.writeAll(bytes);
    if (machine.bus.cartridge.source_path) |bytes| try writer.writeAll(bytes);
    try writer.flush();
}

pub fn loadFromFile(allocator: std.mem.Allocator, path: []const u8) !Machine {
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    var buffer: [4096]u8 = undefined;
    var file_reader = file.reader(&buffer);
    const reader = &file_reader.interface;

    const header = try readValue(reader, Header);
    if (!std.mem.eql(u8, &header.magic, &save_state_magic)) return error.InvalidSaveState;
    if (header.version != save_state_version) return error.UnsupportedSaveStateVersion;

    const bus_state = try readValue(reader, BusState);
    const cpu_state = try readValue(reader, Cpu.State);
    const z80_state = try readValue(reader, Z80.State);

    const rom = (try readOwnedBytes(allocator, reader, header.rom_len)) orelse return error.InvalidSaveState;
    defer allocator.free(rom);

    const cartridge_ram = try readOwnedBytes(allocator, reader, header.cartridge_ram_len);
    defer if (cartridge_ram) |bytes| allocator.free(bytes);

    const save_path_bytes = try readOwnedBytes(allocator, reader, header.save_path_len);
    const source_path_bytes = try readOwnedBytes(allocator, reader, header.source_path_len);

    var machine = try Machine.initFromRomBytes(allocator, rom);
    errdefer machine.deinit(allocator);

    machine.bus.ram = bus_state.ram;
    machine.bus.vdp = bus_state.vdp;
    machine.bus.io = bus_state.io;
    machine.bus.audio_timing = bus_state.audio_timing;
    machine.bus.io_master_remainder = bus_state.io_master_remainder;
    machine.bus.z80_master_credit = bus_state.z80_master_credit;
    machine.bus.z80_wait_master_cycles = bus_state.z80_wait_master_cycles;
    machine.bus.z80_odd_access = bus_state.z80_odd_access;
    machine.bus.m68k_wait_master_cycles = bus_state.m68k_wait_master_cycles;
    machine.bus.open_bus = bus_state.open_bus;
    machine.m68k_sync = bus_state.m68k_sync;

    const next_ram = machine.bus.cartridge.ram.data;
    if ((cartridge_ram != null) != (next_ram != null)) return error.InvalidSaveState;
    if (cartridge_ram) |saved_ram| {
        const next_ram_bytes = next_ram orelse return error.InvalidSaveState;
        if (next_ram_bytes.len != saved_ram.len) return error.InvalidSaveState;
        if (@intFromEnum(machine.bus.cartridge.ram.ram_type) != bus_state.cartridge_ram_type) return error.InvalidSaveState;
        std.mem.copyForwards(u8, next_ram_bytes, saved_ram);
    }

    machine.bus.cartridge.ram.persistent = bus_state.cartridge_ram_persistent;
    machine.bus.cartridge.ram.dirty = bus_state.cartridge_ram_dirty;
    machine.bus.cartridge.ram.mapped = bus_state.cartridge_ram_mapped;
    machine.bus.cartridge.ram.start_address = bus_state.cartridge_ram_start_address;
    machine.bus.cartridge.ram.end_address = bus_state.cartridge_ram_end_address;

    if (machine.bus.cartridge.save_path) |existing| allocator.free(existing);
    machine.bus.cartridge.save_path = save_path_bytes;
    if (machine.bus.cartridge.source_path) |existing| allocator.free(existing);
    machine.bus.cartridge.source_path = source_path_bytes;

    machine.cpu.restoreState(&cpu_state);
    machine.bus.z80.restoreState(&z80_state);
    machine.bus.rebindRuntimePointers();

    return machine;
}

fn makeRomWithSramHeader(
    allocator: std.mem.Allocator,
    rom_len: usize,
    ram_type: u8,
    start_address: u32,
    end_address: u32,
) ![]u8 {
    var rom = try allocator.alloc(u8, rom_len);
    @memset(rom, 0);
    @memcpy(rom[0x100..0x104], "SEGA");
    rom[0x1B0] = 'R';
    rom[0x1B1] = 'A';
    rom[0x1B2] = ram_type;
    rom[0x1B3] = 0x20;
    std.mem.writeInt(u32, rom[0x1B4..0x1B8], start_address, .big);
    std.mem.writeInt(u32, rom[0x1B8..0x1BC], end_address, .big);
    return rom;
}

fn tempFilePath(allocator: std.mem.Allocator, tmp: *testing.TmpDir, file_name: []const u8) ![]u8 {
    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);
    return std.fs.path.join(allocator, &.{ dir_path, file_name });
}

test "default state path derives from ROM source path, slots, and fallback" {
    const allocator = testing.allocator;
    const rom = [_]u8{0} ** 0x400;

    var machine = try Machine.initFromRomBytes(allocator, rom[0..]);
    defer machine.deinit(allocator);

    const fallback_path = try defaultPathForMachine(allocator, &machine);
    defer allocator.free(fallback_path);
    try testing.expectEqualStrings(default_state_name, fallback_path);

    const fallback_slot_path = try pathForMachineSlot(allocator, &machine, 2);
    defer allocator.free(fallback_slot_path);
    try testing.expectEqualStrings("sandopolis.slot2.state", fallback_slot_path);

    machine.bus.cartridge.source_path = try allocator.dupe(u8, "roms/test.bin");

    const derived_path = try defaultPathForMachine(allocator, &machine);
    defer allocator.free(derived_path);
    try testing.expectEqualStrings("roms/test.state", derived_path);

    const derived_slot_path = try pathForMachineSlot(allocator, &machine, 3);
    defer allocator.free(derived_slot_path);
    try testing.expectEqualStrings("roms/test.slot3.state", derived_slot_path);

    try testing.expectEqual(@as(u8, 2), nextPersistentStateSlot(1));
    try testing.expectEqual(@as(u8, 1), nextPersistentStateSlot(persistent_state_slot_count));
}

test "save-state files round-trip machine state" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const rom = try makeRomWithSramHeader(allocator, 0x4000, 0xF8, 0x200001, 0x203FFF);
    defer allocator.free(rom);

    const state_path = try tempFilePath(allocator, &tmp, "roundtrip.state");
    defer allocator.free(state_path);

    var machine = try Machine.initFromRomBytes(allocator, rom);
    defer machine.deinit(allocator);

    machine.bus.rom[0] = 0x11;
    machine.bus.ram[0x1234] = 0x56;
    machine.bus.vdp.regs[1] = 0x40;
    machine.bus.audio_timing.consumeMaster(1234);
    machine.bus.z80.writeByte(0x0000, 0x9A);
    machine.bus.cartridge.ram.data.?[3] = 0xC7;
    machine.bus.cartridge.ram.dirty = true;
    machine.bus.cartridge.ram.mapped = true;
    machine.bus.cartridge.save_path = try allocator.dupe(u8, "saves/test.sav");
    machine.bus.cartridge.source_path = try allocator.dupe(u8, "roms/test.md");
    machine.cpu.core.pc = 0x0000_1234;
    machine.cpu.core.sr = 0x2700;
    machine.m68k_sync.master_cycles = 777;

    try saveToFile(&machine, state_path);

    var restored = try loadFromFile(allocator, state_path);
    defer restored.deinit(allocator);

    try testing.expectEqual(@as(u8, 0x11), restored.bus.rom[0]);
    try testing.expectEqual(@as(u8, 0x56), restored.bus.ram[0x1234]);
    try testing.expectEqual(@as(u8, 0x40), restored.bus.vdp.regs[1]);
    try testing.expectEqual(@as(u8, 0x9A), restored.bus.z80.readByte(0x0000));
    try testing.expectEqual(@as(u8, 0xC7), restored.bus.cartridge.ram.data.?[3]);
    try testing.expectEqual(@as(u32, 0x0000_1234), @as(u32, restored.cpu.core.pc));
    try testing.expectEqual(@as(u16, 0x2700), @as(u16, restored.cpu.core.sr));
    try testing.expectEqual(@as(u64, 777), restored.m68k_sync.master_cycles);
    try testing.expectEqualStrings("saves/test.sav", restored.bus.cartridge.save_path.?);
    try testing.expectEqualStrings("roms/test.md", restored.bus.cartridge.source_path.?);

    const pending = restored.bus.audio_timing.takePending();
    try testing.expectEqual(@as(u32, 1234), pending.master_cycles);
}
