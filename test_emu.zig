const std = @import("std");
const Bus = @import("src/memory.zig").Bus;
const Cpu = @import("src/cpu/cpu.zig").Cpu;

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    // Get ROM path from args
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const rom_path = if (args.len > 1) args[1] else null;

    std.debug.print("=== Sandopolis Emulator Test ===\n", .{});
    if (rom_path) |path| {
        std.debug.print("Loading ROM: {s}\n", .{path});
    } else {
        std.debug.print("No ROM specified, using test ROM\n", .{});
    }

    // Initialize bus and CPU
    var bus = try Bus.init(allocator, rom_path);
    defer bus.deinit(allocator);

    // Display ROM info
    std.debug.print("\n--- ROM Information ---\n", .{});
    std.debug.print("ROM size: {d} bytes\n", .{bus.rom.len});

    if (bus.rom.len >= 0x200) {
        // Check for Genesis header
        if (bus.rom.len >= 0x104 and std.mem.eql(u8, bus.rom[0x100..0x104], "SEGA")) {
            std.debug.print("Valid Genesis ROM detected (SEGA header found)\n", .{});

            // Display system info
            if (bus.rom.len >= 0x150) {
                const console = std.mem.trimRight(u8, bus.rom[0x100..0x110], " \x00");
                const title = std.mem.trimRight(u8, bus.rom[0x120..0x150], " \x00");
                std.debug.print("Console: {s}\n", .{console});
                std.debug.print("Title:   {s}\n", .{title});
            }
        } else {
            std.debug.print("No Genesis header found (might be raw binary)\n", .{});
        }
    }

    // Read reset vectors
    const ssp = bus.read32(0x000000);
    const initial_pc = bus.read32(0x000004);

    std.debug.print("\n--- Reset Vectors ---\n", .{});
    std.debug.print("Initial SSP: 0x{X:0>8}\n", .{ssp});
    std.debug.print("Initial PC:  0x{X:0>8}\n", .{initial_pc});

    // Validate vectors
    if (ssp == 0 or ssp > 0x01000000) {
        std.debug.print("WARNING: SSP looks invalid!\n", .{});
    }
    if (initial_pc == 0 or initial_pc > 0x00400000) {
        std.debug.print("WARNING: Initial PC looks invalid!\n", .{});
    }

    // Initialize CPU
    var cpu = Cpu.init();
    cpu.reset(&bus);

    std.debug.print("\n--- CPU State After Reset ---\n", .{});
    cpu.debugDump();

    // Execute first 100 instructions with detailed trace
    std.debug.print("\n--- Executing First 100 Instructions ---\n", .{});
    Cpu.trace_enabled = true;

    var instruction_count: u32 = 0;
    while (instruction_count < 100 and !cpu.halted) : (instruction_count += 1) {
        cpu.step(&bus);
    }

    Cpu.trace_enabled = false;

    std.debug.print("\n--- Final CPU State After {d} Instructions ---\n", .{instruction_count});
    cpu.debugDump();

    if (cpu.halted) {
        std.debug.print("\nCPU HALTED (unimplemented opcode or exception)\n", .{});
    } else {
        std.debug.print("\nExecution completed successfully!\n", .{});
    }

    // Continue execution for more cycles to test stability
    std.debug.print("\n--- Running 10000 More Cycles ---\n", .{});
    var cycles: u32 = 0;
    while (cycles < 10000 and !cpu.halted) : (cycles += 1) {
        cpu.step(&bus);
    }

    std.debug.print("Executed {d} additional cycles\n", .{cycles});
    if (cpu.halted) {
        std.debug.print("CPU HALTED\n", .{});
    }

    std.debug.print("\n--- Test Complete ---\n", .{});
}

