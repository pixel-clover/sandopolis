const std = @import("std");
const testing = std.testing;
const bus_save_state = @import("bus/save_state.zig");
const clock = @import("clock.zig");
const Machine = @import("machine.zig").Machine;
const Cpu = @import("cpu/cpu.zig").Cpu;
const Z80 = @import("cpu/z80.zig").Z80;

const save_state_magic = [8]u8{ 'S', 'N', 'D', 'S', 'T', 'A', 'T', 'E' };
const save_state_version: u16 = 2;
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
    bus: bus_save_state.State,
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

fn skipSaveStateField(comptime Parent: type, comptime field_name: []const u8) bool {
    if (!@hasDecl(Parent, "save_state_skip_fields")) return false;

    inline for (@field(Parent, "save_state_skip_fields")) |skip_name| {
        if (comptime std.mem.eql(u8, skip_name, field_name)) return true;
    }
    return false;
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
                if (comptime skipSaveStateField(T, field.name)) continue;
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
                if (comptime skipSaveStateField(T, field.name)) {
                    @field(out.*, field.name) = std.mem.zeroes(field.type);
                    continue;
                }
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
        .bus = machine.bus.captureSaveState(),
        .m68k_sync = machine.m68k_sync,
    };
}

pub fn defaultPathForMachine(allocator: std.mem.Allocator, machine: *const Machine) ![]u8 {
    if (machine.bus.sourcePath()) |source_path| {
        return replaceExtension(allocator, source_path, ".state");
    }
    return allocator.dupe(u8, default_state_name);
}

pub fn pathForMachineSlot(allocator: std.mem.Allocator, machine: *const Machine, slot: u8) ![]u8 {
    const normalized = normalizePersistentStateSlot(slot);
    const default_path = try defaultPathForMachine(allocator, machine);
    defer allocator.free(default_path);
    return pathForSlot(allocator, default_path, normalized);
}

pub fn saveToFile(machine: *const Machine, path: []const u8) !void {
    const rom = machine.bus.romBytes();
    const cartridge_ram = machine.bus.cartridgeRamBytes();
    const save_path = machine.bus.persistentSavePath();
    const source_path = machine.bus.sourcePath();
    const rom_len: u32 = @intCast(rom.len);
    const cartridge_ram_len: u32 = @intCast(if (cartridge_ram) |bytes| bytes.len else 0);
    const save_path_len: u32 = @intCast(if (save_path) |bytes| bytes.len else 0);
    const source_path_len: u32 = @intCast(if (source_path) |bytes| bytes.len else 0);

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
    try writer.writeAll(rom);
    if (cartridge_ram) |bytes| try writer.writeAll(bytes);
    if (save_path) |bytes| try writer.writeAll(bytes);
    if (source_path) |bytes| try writer.writeAll(bytes);
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

    var save_path_bytes = try readOwnedBytes(allocator, reader, header.save_path_len);
    defer if (save_path_bytes) |bytes| allocator.free(bytes);
    var source_path_bytes = try readOwnedBytes(allocator, reader, header.source_path_len);
    defer if (source_path_bytes) |bytes| allocator.free(bytes);

    var machine = try Machine.initFromRomBytes(allocator, rom);
    errdefer machine.deinit(allocator);

    try machine.bus.restoreSaveState(bus_state.bus, cartridge_ram);
    machine.m68k_sync = bus_state.m68k_sync;
    machine.bus.replaceStoragePaths(allocator, save_path_bytes, source_path_bytes);
    save_path_bytes = null;
    source_path_bytes = null;

    machine.cpu.restoreState(&cpu_state);
    machine.bus.z80.restoreState(&z80_state);
    machine.bus.rebindRuntimePointers();
    machine.clearPendingAudioTransferState();

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

test "default state path derives from ROM source path, numbered slots, and fallback" {
    const allocator = testing.allocator;
    const rom = [_]u8{0} ** 0x400;

    var machine = try Machine.initFromRomBytes(allocator, rom[0..]);
    defer machine.deinit(allocator);

    const fallback_path = try defaultPathForMachine(allocator, &machine);
    defer allocator.free(fallback_path);
    try testing.expectEqualStrings(default_state_name, fallback_path);

    const fallback_slot1_path = try pathForMachineSlot(allocator, &machine, 1);
    defer allocator.free(fallback_slot1_path);
    try testing.expectEqualStrings("sandopolis.slot1.state", fallback_slot1_path);

    const fallback_slot2_path = try pathForMachineSlot(allocator, &machine, 2);
    defer allocator.free(fallback_slot2_path);
    try testing.expectEqualStrings("sandopolis.slot2.state", fallback_slot2_path);

    machine.bus.replaceStoragePaths(allocator, null, try allocator.dupe(u8, "roms/test.bin"));

    const derived_path = try defaultPathForMachine(allocator, &machine);
    defer allocator.free(derived_path);
    try testing.expectEqualStrings("roms/test.state", derived_path);

    const derived_slot1_path = try pathForMachineSlot(allocator, &machine, 1);
    defer allocator.free(derived_slot1_path);
    try testing.expectEqualStrings("roms/test.slot1.state", derived_slot1_path);

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
    machine.bus.z80.setAudioMasterOffset(1234);
    machine.bus.z80.writeByte(0x4000, 0x22);
    machine.bus.z80.writeByte(0x4001, 0x0F);
    machine.bus.z80.writeByte(0x7F11, 0x90);
    var timing_state = machine.bus.captureTimingState();
    timing_state.z80_stall_master_debt = 49;
    timing_state.z80_wait_master_cycles = 50;
    timing_state.z80_odd_access = true;
    timing_state.m68k_wait_master_cycles = 33;
    machine.bus.restoreTimingState(timing_state);
    machine.bus.z80.writeByte(0x0000, 0x9A);
    machine.bus.write8(0x0020_0007, 0xC7);
    machine.bus.replaceStoragePaths(
        allocator,
        try allocator.dupe(u8, "saves/test.sav"),
        try allocator.dupe(u8, "roms/test.md"),
    );
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
    try testing.expectEqual(@as(u8, 0x0F), restored.bus.z80.getYmRegister(0, 0x22));
    try testing.expectEqual(@as(u8, 0x90), restored.bus.z80.getPsgLast());
    try testing.expectEqual(@as(u8, 0xC7), restored.bus.read8(0x0020_0007));
    try testing.expectEqual(@as(u32, 0x0000_1234), @as(u32, restored.cpu.core.pc));
    try testing.expectEqual(@as(u16, 0x2700), @as(u16, restored.cpu.core.sr));
    try testing.expectEqual(@as(u64, 777), restored.m68k_sync.master_cycles);
    const restored_timing_state = restored.bus.captureTimingState();
    try testing.expectEqual(@as(u32, 49), restored_timing_state.z80_stall_master_debt);
    try testing.expectEqual(@as(u32, 50), restored_timing_state.z80_wait_master_cycles);
    try testing.expect(restored_timing_state.z80_odd_access);
    try testing.expectEqual(@as(u32, 33), restored_timing_state.m68k_wait_master_cycles);
    try testing.expectEqualStrings("saves/test.sav", restored.bus.persistentSavePath().?);
    try testing.expectEqualStrings("roms/test.md", restored.bus.sourcePath().?);

    try testing.expectEqual(@as(u32, 0), restored.bus.audio_timing.takePending().master_cycles);
    try testing.expectEqual(@as(u16, 0), restored.bus.z80.pendingYmWriteCount());
    try testing.expectEqual(@as(u16, 0), restored.bus.z80.pendingPsgCommandCount());
}
