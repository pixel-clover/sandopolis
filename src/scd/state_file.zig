//! Sega CD save-state container ("SNDSCDST").
//!
//! Layout: Header, the embedded Genesis state (the main CPU, bus, VDP,
//! Z80, and the BIOS as cartridge ROM, in the regular "SNDSTATE" format),
//! the sub-board state (reflectively serialized), and the disc path. The
//! disc itself is reopened from that path on load; discs given as bytes
//! restore without a disc inserted.

const std = @import("std");
const genesis_state_file = @import("../state_file.zig");
const Machine = @import("../machine.zig").Machine;
const ScdBoard = @import("board.zig").ScdBoard;
const Disc = @import("cdrom/reader.zig").Disc;

pub const magic = [8]u8{ 'S', 'N', 'D', 'S', 'C', 'D', 'S', 'T' };
pub const version: u16 = 1;

const Header = struct {
    magic: [8]u8,
    version: u16,
    genesis_len: u32,
    disc_path_len: u32,
    backup_ram_path_len: u32,
};

pub fn saveToBuffer(allocator: std.mem.Allocator, machine: *const Machine) ![]u8 {
    const board = machine.scd orelse return error.NotSegaCd;
    const genesis_blob = try genesis_state_file.saveToBuffer(allocator, machine);
    defer allocator.free(genesis_blob);

    const disc_path: []const u8 = if (board.disc) |*d| (d.source_path orelse "") else "";
    const bram_path: []const u8 = board.backup_ram_path orelse "";

    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const w = &aw.writer;
    try genesis_state_file.writeValue(w, Header{
        .magic = magic,
        .version = version,
        .genesis_len = @intCast(genesis_blob.len),
        .disc_path_len = @intCast(disc_path.len),
        .backup_ram_path_len = @intCast(bram_path.len),
    });
    try w.writeAll(genesis_blob);
    try board.writeState(w, genesis_state_file.writeValue);
    try w.writeAll(disc_path);
    try w.writeAll(bram_path);
    return aw.toOwnedSlice();
}

pub fn loadFromBuffer(allocator: std.mem.Allocator, bytes: []const u8) !Machine {
    var reader = genesis_state_file.SliceReader{ .buffer = bytes };
    const header = try genesis_state_file.readValue(&reader, Header);
    if (!std.mem.eql(u8, &header.magic, &magic)) return error.InvalidSaveState;
    if (header.version != version) return error.UnsupportedSaveStateVersion;
    if (header.genesis_len == 0 or header.genesis_len > 80 * 1024 * 1024) return error.InvalidSaveState;
    if (header.disc_path_len > 4096 or header.backup_ram_path_len > 4096) return error.InvalidSaveState;

    const genesis_start = reader.pos;
    const genesis_end = genesis_start + header.genesis_len;
    if (genesis_end > bytes.len) return error.InvalidSaveState;
    // Keep the machine boxed while loading: a Machine is about a megabyte
    // and this path already runs several frames deep on an 8MB stack.
    const machine = try allocator.create(Machine);
    defer allocator.destroy(machine);
    machine.* = try genesis_state_file.loadFromBuffer(allocator, bytes[genesis_start..genesis_end]);
    errdefer machine.deinit(allocator);
    reader.pos = genesis_end;

    // The board state follows; its length is implied by the format, and the
    // paths come after it. Read the paths' offsets after restoring.
    const board_state_start = reader.pos;
    _ = board_state_start;

    // Paths are at the end of the buffer.
    const paths_len: usize = header.disc_path_len + header.backup_ram_path_len;
    if (paths_len > bytes.len) return error.InvalidSaveState;
    const disc_path_start = bytes.len - paths_len;
    if (disc_path_start + header.disc_path_len + header.backup_ram_path_len > bytes.len) return error.InvalidSaveState;
    const disc_path = bytes[disc_path_start .. disc_path_start + header.disc_path_len];
    const bram_path = bytes[disc_path_start + header.disc_path_len ..][0..header.backup_ram_path_len];

    var disc: ?Disc = null;
    if (disc_path.len != 0) {
        const ext = std.fs.path.extension(disc_path);
        disc = if (std.ascii.eqlIgnoreCase(ext, ".cue"))
            Disc.openCuePath(allocator, disc_path) catch null
        else
            Disc.openIsoPath(allocator, disc_path) catch null;
    }
    errdefer if (disc) |*d| d.deinit();

    const board = try ScdBoard.create(allocator, machine.bus.cartridge.rom, disc, machine.bus.vdp.pal_mode);
    disc = null; // owned by the board now
    machine.scd = board; // freed by machine.deinit on error from here on
    try board.readState(&reader, genesis_state_file.readInto);
    if (reader.pos != disc_path_start) return error.InvalidSaveState;
    if (bram_path.len != 0) board.backup_ram_path = try allocator.dupe(u8, bram_path);
    machine.rebindRuntimePointers();
    return machine.*;
}

const testing = std.testing;

test "sega cd state round-trips the sub-board and keeps a memory disc out of the file" {
    const bios = try testing.allocator.alloc(u8, 128 * 1024);
    defer testing.allocator.free(bios);
    @memset(bios, 0);
    @memcpy(bios[0x100..0x104], "SEGA");
    std.mem.writeInt(u32, bios[0..4], 0x00FFFE00, .big);
    std.mem.writeInt(u32, bios[4..8], 0x00000200, .big);
    bios[0x200] = 0x60;
    bios[0x201] = 0xFE;
    var iso = [_]u8{0} ** (2 * 2048);
    @memcpy(iso[0..14], "SEGADISCSYSTEM");
    var disc = try Disc.fromMemory(testing.allocator, null, &.{&iso});
    errdefer disc.deinit();

    var machine = try Machine.initSegaCd(testing.allocator, bios, disc);
    defer machine.deinit(testing.allocator);
    machine.reset();
    machine.runFrame();
    machine.discardPendingAudio();

    // Perturb sub-board state.
    const board = machine.scd.?;
    board.prg_ram[0x1234] = 0xAB;
    board.word_ram.write16Linear(0x100, 0xBEEF);
    board.gate.command[3] = 0x4321;
    board.backup_ram[10] = 0x77;
    board.pcm.ram[5] = 0x99;
    board.cdc.ram[100] = 0x42;
    board.cdd.lba = 1;

    const buf = try saveToBuffer(testing.allocator, &machine);
    defer testing.allocator.free(buf);
    try testing.expectEqualSlices(u8, &magic, buf[0..8]);

    var restored = try loadFromBuffer(testing.allocator, buf);
    defer restored.deinit(testing.allocator);
    const rb = restored.scd.?;
    try testing.expectEqual(@as(u8, 0xAB), rb.prg_ram[0x1234]);
    try testing.expectEqual(@as(u16, 0xBEEF), rb.word_ram.read16Linear(0x100));
    try testing.expectEqual(@as(u16, 0x4321), rb.gate.command[3]);
    try testing.expectEqual(@as(u8, 0x77), rb.backup_ram[10]);
    try testing.expectEqual(@as(u8, 0x99), rb.pcm.ram[5]);
    try testing.expectEqual(@as(u8, 0x42), rb.cdc.ram[100]);
    try testing.expectEqual(@as(i32, 1), rb.cdd.lba);
    // A memory disc cannot be reopened by path: the drive reports no disc.
    try testing.expect(rb.disc == null);
    try testing.expect(!rb.cdd.disc_present);
    // The BIOS came back as the cartridge ROM and the machine keeps running.
    try testing.expectEqualSlices(u8, "SEGA", restored.bus.cartridge.rom[0x100..0x104]);
    restored.runFrame();
    restored.discardPendingAudio();

    // Corrupt input is rejected, not a panic.
    try testing.expectError(error.InvalidSaveState, loadFromBuffer(testing.allocator, buf[0..40]));
}
