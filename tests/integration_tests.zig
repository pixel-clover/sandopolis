const std = @import("std");
const testing = std.testing;
const sandopolis = @import("sandopolis_src");
const Bus = sandopolis.Bus;
const Cpu = sandopolis.Cpu;

test "cpu reset applies fallback vectors when ROM vectors are invalid" {
    var bus = try Bus.init(testing.allocator, null);
    defer bus.deinit(testing.allocator);

    std.mem.writeInt(u32, bus.rom[0..4], 0x0000_0000, .big);
    std.mem.writeInt(u32, bus.rom[4..8], 0x0000_0200, .big);

    var cpu = Cpu.init();
    var memory = bus.cpuMemory();
    cpu.reset(&memory);

    try testing.expectEqual(@as(u32, 0x00FF_FE00), @as(u32, cpu.core.a_regs[7].l));
    try testing.expectEqual(@as(u32, 0x0000_0200), @as(u32, cpu.core.pc));
}
