//! Sub-CPU (12.5 MHz 68000) address space. Implements the `MemoryInterface`
//! contract used by the rocket68 wrapper; the VDP-specific wait hooks are
//! no-ops because the sub CPU has no VDP.
//!
//!   0x000000-0x07FFFF  PRG-RAM 512KB (low region write-protected by WP)
//!   0x080000-0x0BFFFF  Word RAM: 2M linear (256KB) / 1M dot image (256KB)
//!   0x0C0000-0x0DFFFF  Word RAM: 1M raw view of the sub-owned bank
//!   0xFE0000-0xFE3FFF  Backup RAM 8KB on odd bytes
//!   0xFF0000-0xFF3FFF  RF5C164 PCM (attached later)
//!   0xFF8000-0xFF81FF  Gate array

const std = @import("std");
const cpu_runtime = @import("../cpu/runtime_state.zig");
const MemoryInterface = @import("../cpu/memory_interface.zig").MemoryInterface;
const Cpu = @import("../cpu/cpu.zig").Cpu;
const GateArray = @import("gate_array.zig").GateArray;
const gate_array = @import("gate_array.zig");
const WordRam = @import("word_ram.zig").WordRam;
const cdc_mod = @import("cdc.zig");
const Cdc = cdc_mod.Cdc;

pub const prg_ram_bytes: u32 = 512 * 1024;
pub const backup_ram_bytes: u32 = 8 * 1024;
/// Write-protect granularity: WP counts 0x200-byte blocks from address 0.
pub const write_protect_unit: u32 = 0x200;

/// Hooks for devices that live outside this module.
pub const PcmHooks = struct {
    ctx: *anyopaque,
    read8Fn: *const fn (*anyopaque, u32) u8,
    write8Fn: *const fn (*anyopaque, u32, u8) void,
};

pub const SubBus = struct {
    cpu: *Cpu,
    gate: *GateArray,
    word_ram: *WordRam,
    prg_ram: *[prg_ram_bytes]u8,
    backup_ram: *[backup_ram_bytes]u8,
    cdc: *Cdc,
    pcm: ?PcmHooks = null,
    /// Set when the CDC finished a transfer or decoded a block with its
    /// interrupt enabled; the board turns it into INT5.
    cdc_irq_request: bool = false,
    /// Set when the sub CPU completes a CDD command; the board consumes it.
    cdd_command_ready: bool = false,
    /// Set when the sub CPU cleared RES0; the board resets the CD hardware.
    peripheral_reset_request: bool = false,

    /// Accesses to Word RAM while the other CPU owned it (2M mode).
    non_owner_word_ram_accesses: u32 = 0,
    /// Backup RAM changed since it was last written to disk.
    backup_ram_dirty: bool = false,
    runtime_state: cpu_runtime.RuntimeState = .{},

    fn peripherals(self: *SubBus) gate_array.Peripherals {
        return .{ .cpu = self.cpu, .word_ram = self.word_ram };
    }

    pub fn memoryInterface(self: *SubBus) MemoryInterface {
        return MemoryInterface.bind(SubBus, self);
    }

    // -- CDC ports behind the gate array window ------------------------------

    /// Mirror the CDC's transfer flags into the gate array mode register.
    pub fn syncCdcFlags(self: *SubBus) void {
        const dest: cdc_mod.Destination = @enumFromInt(self.gate.cdc_device_destination);
        const host = dest == .main_read or dest == .sub_read;
        self.gate.cdc_data_set_ready = host and self.cdc.dataSetReady();
        self.gate.cdc_end_of_transfer = self.cdc.end_of_transfer;
    }

    fn cdcRegisterRead(self: *SubBus) u8 {
        const value = self.cdc.readRegister(self.gate.cdc_register_address);
        self.gate.cdc_register_address +%= 1;
        return value;
    }

    fn cdcRegisterWrite(self: *SubBus, value: u8) void {
        self.cdc.writeRegister(self.gate.cdc_register_address, value);
        self.gate.cdc_register_address +%= 1;
        self.runPendingDma();
    }

    /// Sub-side host data port (0xFF8008): pops a word while DD selects
    /// the sub CPU.
    fn cdcHostReadSub(self: *SubBus) u16 {
        if (@as(cdc_mod.Destination, @enumFromInt(self.gate.cdc_device_destination)) != .sub_read) return 0xFFFF;
        const r = self.cdc.hostRead();
        if (r.raise_irq) self.cdc_irq_request = true;
        return r.word;
    }

    /// Complete a triggered transfer whose destination is a DMA target.
    pub fn runPendingDma(self: *SubBus) void {
        if (!self.cdc.transferPending()) return;
        const dest: cdc_mod.Destination = @enumFromInt(self.gate.cdc_device_destination);
        switch (dest) {
            .pcm_ram, .prg_ram, .word_ram => {},
            else => return,
        }
        const address = @as(u32, self.gate.cdc_dma_address) << 3;
        if (self.cdc.runDma(dest, address, .{ .ctx = self, .writeFn = dmaWrite })) self.cdc_irq_request = true;
    }

    fn dmaWrite(ctx: *anyopaque, destination: cdc_mod.Destination, address: u32, data: []const u8) void {
        const self: *SubBus = @ptrCast(@alignCast(ctx));
        switch (destination) {
            .prg_ram => {
                for (data, 0..) |b, i| {
                    const a = (address + @as(u32, @intCast(i))) & (prg_ram_bytes - 1);
                    self.prg_ram[a] = b;
                }
            },
            .word_ram => {
                switch (self.word_ram.mode) {
                    .two_m => {
                        for (data, 0..) |b, i| self.word_ram.write8Linear(address + @as(u32, @intCast(i)), b);
                    },
                    .one_m => {
                        const bank = self.word_ram.subBank1M();
                        for (data, 0..) |b, i| self.word_ram.write8Bank(bank, address + @as(u32, @intCast(i)), b);
                    },
                }
            },
            .pcm_ram => {
                if (self.pcm) |p| {
                    // PCM DMA lands in the currently selected 4KB wave bank
                    // window (0xFF2001+, odd bytes).
                    for (data, 0..) |b, i| p.write8Fn(p.ctx, 0x2001 + (((address + @as(u32, @intCast(i))) & 0xFFF) << 1), b);
                }
            },
            else => {},
        }
    }

    // -- MemoryInterface: data access ---------------------------------------

    pub fn read8(self: *SubBus, address: u32) u8 {
        const addr = address & 0xFFFFFF;
        if (addr < prg_ram_bytes) return self.prg_ram[addr];
        if (addr < 0x0C0000) {
            return switch (self.word_ram.mode) {
                .two_m => blk: {
                    if (!self.word_ram.subOwns2M()) {
                        self.non_owner_word_ram_accesses += 1;
                        break :blk 0xFF;
                    }
                    break :blk self.word_ram.read8Linear(addr - 0x080000);
                },
                .one_m => self.word_ram.readDot(self.word_ram.subBank1M(), addr - 0x080000),
            };
        }
        if (addr < 0x0E0000) {
            return switch (self.word_ram.mode) {
                .two_m => 0,
                .one_m => self.word_ram.read8Bank(self.word_ram.subBank1M(), addr - 0x0C0000),
            };
        }
        if (addr >= 0xFE0000 and addr < 0xFE4000) {
            if ((addr & 1) == 0) return 0;
            return self.backup_ram[(addr >> 1) & (backup_ram_bytes - 1)];
        }
        if (addr >= 0xFF0000 and addr < 0xFF4000) {
            if (self.pcm) |p| return p.read8Fn(p.ctx, addr - 0xFF0000);
            return 0;
        }
        if (addr >= 0xFF8000 and addr < 0xFF8200) {
            const off: u16 = @intCast(addr - 0xFF8000);
            switch (off) {
                0x04, 0x05 => self.syncCdcFlags(),
                0x07 => return self.cdcRegisterRead(),
                0x06 => return 0,
                0x08, 0x09 => {
                    const w = self.cdcHostReadSub();
                    return if (off == 0x08) @truncate(w >> 8) else @truncate(w);
                },
                else => {},
            }
            return self.gate.subRead8(off, self.word_ram);
        }
        return 0;
    }

    pub fn read16(self: *SubBus, address: u32) u16 {
        const addr = address & 0xFFFFFE;
        if (addr < prg_ram_bytes) {
            return (@as(u16, self.prg_ram[addr]) << 8) | self.prg_ram[addr + 1];
        }
        if (addr >= 0x080000 and addr < 0x0C0000 and self.word_ram.mode == .two_m) {
            if (!self.word_ram.subOwns2M()) {
                self.non_owner_word_ram_accesses += 1;
                return 0xFFFF;
            }
            return self.word_ram.read16Linear(addr - 0x080000);
        }
        if (addr >= 0x0C0000 and addr < 0x0E0000 and self.word_ram.mode == .one_m) {
            return self.word_ram.read16Bank(self.word_ram.subBank1M(), addr - 0x0C0000);
        }
        if (addr >= 0xFF8000 and addr < 0xFF8200) {
            const off: u16 = @intCast(addr - 0xFF8000);
            switch (off) {
                0x04 => self.syncCdcFlags(),
                0x06 => return self.cdcRegisterRead(),
                0x08 => return self.cdcHostReadSub(),
                else => {},
            }
            return self.gate.subRead16(off, self.word_ram);
        }
        return (@as(u16, self.read8(addr)) << 8) | self.read8(addr + 1);
    }

    pub fn read32(self: *SubBus, address: u32) u32 {
        return (@as(u32, self.read16(address)) << 16) | self.read16(address + 2);
    }

    pub fn write8(self: *SubBus, address: u32, value: u8) void {
        const addr = address & 0xFFFFFF;
        if (addr < prg_ram_bytes) {
            if (addr < @as(u32, self.gate.write_protect) * write_protect_unit) return;
            self.prg_ram[addr] = value;
            return;
        }
        if (addr < 0x0C0000) {
            switch (self.word_ram.mode) {
                .two_m => {
                    if (!self.word_ram.subOwns2M()) {
                        self.non_owner_word_ram_accesses += 1;
                        return;
                    }
                    self.word_ram.write8Linear(addr - 0x080000, value);
                },
                .one_m => self.word_ram.writeDot(self.word_ram.subBank1M(), addr - 0x080000, value),
            }
            return;
        }
        if (addr < 0x0E0000) {
            if (self.word_ram.mode == .one_m) {
                self.word_ram.write8Bank(self.word_ram.subBank1M(), addr - 0x0C0000, value);
            }
            return;
        }
        if (addr >= 0xFE0000 and addr < 0xFE4000) {
            if ((addr & 1) != 0) {
                self.backup_ram[(addr >> 1) & (backup_ram_bytes - 1)] = value;
                self.backup_ram_dirty = true;
            }
            return;
        }
        if (addr >= 0xFF0000 and addr < 0xFF4000) {
            if (self.pcm) |p| p.write8Fn(p.ctx, addr - 0xFF0000, value);
            return;
        }
        if (addr >= 0xFF8000 and addr < 0xFF8200) {
            const off: u16 = @intCast(addr - 0xFF8000);
            if (off == 0x07) return self.cdcRegisterWrite(value);
            if (off == 0x06) return;
            const lanes: u2 = if ((off & 1) == 0) 0b10 else 0b01;
            const word: u16 = if ((off & 1) == 0) @as(u16, value) << 8 else value;
            const effects = self.gate.subWriteWithEffects(off, word, lanes, self.peripherals());
            if (effects.cdd_command) self.cdd_command_ready = true;
            if (effects.peripheral_reset) self.peripheral_reset_request = true;
            if (off == 0x04 or off == 0x05) self.runPendingDma();
        }
    }

    pub fn write16(self: *SubBus, address: u32, value: u16) void {
        const addr = address & 0xFFFFFE;
        if (addr < prg_ram_bytes) {
            if (addr < @as(u32, self.gate.write_protect) * write_protect_unit) return;
            self.prg_ram[addr] = @truncate(value >> 8);
            self.prg_ram[addr + 1] = @truncate(value);
            return;
        }
        if (addr >= 0x080000 and addr < 0x0C0000 and self.word_ram.mode == .two_m) {
            if (!self.word_ram.subOwns2M()) {
                self.non_owner_word_ram_accesses += 1;
                return;
            }
            self.word_ram.write16Linear(addr - 0x080000, value);
            return;
        }
        if (addr >= 0x0C0000 and addr < 0x0E0000 and self.word_ram.mode == .one_m) {
            self.word_ram.write16Bank(self.word_ram.subBank1M(), addr - 0x0C0000, value);
            return;
        }
        if (addr >= 0xFF8000 and addr < 0xFF8200) {
            const off: u16 = @intCast(addr - 0xFF8000);
            if (off == 0x06) return self.cdcRegisterWrite(@truncate(value));
            const effects = self.gate.subWriteWithEffects(off, value, 0b11, self.peripherals());
            if (effects.cdd_command) self.cdd_command_ready = true;
            if (effects.peripheral_reset) self.peripheral_reset_request = true;
            if (off == 0x04) self.runPendingDma();
            return;
        }
        self.write8(addr, @truncate(value >> 8));
        self.write8(addr + 1, @truncate(value));
    }

    pub fn write32(self: *SubBus, address: u32, value: u32) void {
        self.write16(address, @truncate(value >> 16));
        self.write16(address + 2, @truncate(value));
    }

    // -- MemoryInterface: timing hooks (no VDP on this bus) -----------------

    pub fn m68kAccessWaitMasterCycles(_: *SubBus, _: u32, _: u8) u32 {
        return 0;
    }
    pub fn dataPortReadWaitMasterCycles(_: *SubBus) u32 {
        return 0;
    }
    pub fn reserveDataPortWriteWaitMasterCycles(_: *SubBus) u32 {
        return 0;
    }
    pub fn controlPortWriteWaitMasterCycles(_: *SubBus) u32 {
        return 0;
    }
    pub fn projectedDmaWaitMasterCycles(_: *SubBus, _: u32) u32 {
        return 0;
    }

    /// The sub CPU stops while held in reset or while the main CPU holds
    /// its bus (SBRQ).
    pub fn shouldHaltCpu(self: *SubBus) bool {
        return !self.gate.sub_running or self.gate.sub_bus_requested;
    }

    pub fn setCpuRuntimeState(self: *SubBus, state: cpu_runtime.RuntimeState) void {
        self.runtime_state = state;
    }
    pub fn clearCpuRuntimeState(self: *SubBus) void {
        self.runtime_state = .{};
    }
    pub fn notifyBusAccess(_: *SubBus, _: u32, _: u32) void {}
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const Fixture = struct {
    cpu: Cpu,
    gate: GateArray,
    word_ram: WordRam,
    prg_ram: [prg_ram_bytes]u8,
    backup_ram: [backup_ram_bytes]u8,
    cdc: Cdc,

    fn init(allocator: std.mem.Allocator) !*Fixture {
        const f = try allocator.create(Fixture);
        f.* = .{
            .cpu = Cpu.init(),
            .gate = .{},
            .word_ram = .{},
            .prg_ram = [_]u8{0} ** prg_ram_bytes,
            .backup_ram = [_]u8{0} ** backup_ram_bytes,
            .cdc = .{},
        };
        return f;
    }

    fn bus(self: *Fixture) SubBus {
        return .{
            .cpu = &self.cpu,
            .gate = &self.gate,
            .word_ram = &self.word_ram,
            .prg_ram = &self.prg_ram,
            .backup_ram = &self.backup_ram,
            .cdc = &self.cdc,
        };
    }
};

test "prg ram is readable everywhere and write protected below the WP boundary" {
    const f = try Fixture.init(testing.allocator);
    defer testing.allocator.destroy(f);
    var bus = f.bus();

    bus.write32(0x000100, 0xDEADBEEF);
    try testing.expectEqual(@as(u32, 0xDEADBEEF), bus.read32(0x000100));
    bus.write16(0x07FFFE, 0x1234);
    try testing.expectEqual(@as(u16, 0x1234), bus.read16(0x07FFFE));

    f.gate.write_protect = 2; // protect 0x000000-0x0003FF
    bus.write8(0x0003FF, 0xAA);
    bus.write16(0x000100, 0x0000);
    try testing.expectEqual(@as(u8, 0x00), bus.read8(0x0003FF));
    try testing.expectEqual(@as(u32, 0xDEADBEEF), bus.read32(0x000100));
    bus.write8(0x000400, 0xAA);
    try testing.expectEqual(@as(u8, 0xAA), bus.read8(0x000400));
}

test "word ram 2M is only reachable while the sub owns it" {
    const f = try Fixture.init(testing.allocator);
    defer testing.allocator.destroy(f);
    var bus = f.bus();

    // Main owns at power-on.
    bus.write16(0x080000, 0xBEEF);
    try testing.expectEqual(@as(u16, 0xFFFF), bus.read16(0x080000));
    try testing.expectEqual(@as(u32, 2), bus.non_owner_word_ram_accesses);
    try testing.expectEqual(@as(u16, 0), f.word_ram.read16Linear(0));

    f.word_ram.mainRequestHandoff();
    bus.write16(0x080000, 0xBEEF);
    bus.write8(0x0BFFFF, 0x77);
    try testing.expectEqual(@as(u16, 0xBEEF), bus.read16(0x080000));
    try testing.expectEqual(@as(u8, 0x77), bus.read8(0x0BFFFF));
    try testing.expectEqual(@as(u16, 0xBEEF), f.word_ram.read16Linear(0));
    // 0x0C0000 is unmapped in 2M mode.
    bus.write16(0x0C0000, 0x1111);
    try testing.expectEqual(@as(u16, 0), bus.read16(0x0C0000));
}

test "word ram 1M exposes the dot image and the raw bank" {
    const f = try Fixture.init(testing.allocator);
    defer testing.allocator.destroy(f);
    var bus = f.bus();
    f.word_ram.subSetMode(.one_m);
    const bank = f.word_ram.subBank1M();

    bus.write8(0x080000, 0x0A); // pixel 0 -> high nibble of bank byte 0
    bus.write8(0x080001, 0x05);
    try testing.expectEqual(@as(u8, 0xA5), f.word_ram.read8Bank(bank, 0));
    try testing.expectEqual(@as(u8, 0xA5), bus.read8(0x0C0000));
    try testing.expectEqual(@as(u16, 0x0A05), bus.read16(0x080000));

    bus.write16(0x0C0002, 0x1234);
    try testing.expectEqual(@as(u16, 0x1234), f.word_ram.read16Bank(bank, 2));
    try testing.expectEqual(@as(u8, 0x1), bus.read8(0x080004));
    try testing.expectEqual(@as(u8, 0x4), bus.read8(0x080007));
}

test "backup ram sits on odd bytes and gate array registers decode by lane" {
    const f = try Fixture.init(testing.allocator);
    defer testing.allocator.destroy(f);
    var bus = f.bus();

    bus.write8(0xFE0001, 0x5A);
    bus.write8(0xFE0000, 0xFF); // even byte ignored
    try testing.expectEqual(@as(u8, 0x5A), f.backup_ram[0]);
    try testing.expectEqual(@as(u16, 0x005A), bus.read16(0xFE0000));
    bus.write16(0xFE3FFE, 0x1234);
    try testing.expectEqual(@as(u8, 0x34), f.backup_ram[backup_ram_bytes - 1]);

    // Byte write to the low lane of the IRQ mask register.
    bus.write8(0xFF8033, 0x7E);
    try testing.expectEqual(@as(u8, 0x7E), f.gate.irq_mask);
    // Word write to status 0, then byte read of each half.
    bus.write16(0xFF8020, 0xCAFE);
    try testing.expectEqual(@as(u8, 0xCA), bus.read8(0xFF8020));
    try testing.expectEqual(@as(u8, 0xFE), bus.read8(0xFF8021));
    // Completing a CDD command flags the board.
    try testing.expect(!bus.cdd_command_ready);
    bus.write8(0xFF804B, 0x0F);
    try testing.expect(bus.cdd_command_ready);

    // Halt follows the gate array's reset and bus-request bits.
    try testing.expect(bus.shouldHaltCpu());
    f.gate.sub_running = true;
    try testing.expect(!bus.shouldHaltCpu());
    f.gate.sub_bus_requested = true;
    try testing.expect(bus.shouldHaltCpu());
}

test "cdc register port auto-increments and host/dma transfers route by destination" {
    const f = try Fixture.init(testing.allocator);
    defer testing.allocator.destroy(f);
    var bus = f.bus();
    for (&f.cdc.ram, 0..) |*b, i| b.* = @truncate(i);

    // RS = 2, then two data writes land in DBC low/high and advance RS.
    bus.write8(0xFF8005, 0x02);
    bus.write8(0xFF8007, 0x03);
    bus.write8(0xFF8007, 0x00);
    try testing.expectEqual(@as(u16, 0x0003), f.cdc.dbc);
    try testing.expectEqual(@as(u4, 0x4), f.gate.cdc_register_address);
    // Reads also auto-increment: read DBC back from RS = 2.
    bus.write8(0xFF8005, 0x02);
    try testing.expectEqual(@as(u8, 0x03), bus.read8(0xFF8007));
    try testing.expectEqual(@as(u8, 0x00), bus.read8(0xFF8007));

    // Enable data out, DAC = 0x0100, destination = sub host read, trigger.
    bus.write8(0xFF8005, 0x01);
    bus.write8(0xFF8007, cdc_mod.Ifctrl.douten);
    bus.write8(0xFF8005, 0x04);
    bus.write16(0xFF8006, 0x0000); // DACL
    bus.write16(0xFF8006, 0x0001); // DACH
    bus.write8(0xFF8004, 0x03); // DD = sub read
    bus.write8(0xFF8005, 0x06);
    bus.write8(0xFF8007, 0x00); // DTTRG
    try testing.expectEqual(@as(u16, 0x4300), bus.read16(0xFF8004) & 0x4700); // DSR + DD
    try testing.expectEqual(@as(u16, 0x0001), bus.read16(0xFF8008));
    try testing.expectEqual(@as(u16, 0x0203), bus.read16(0xFF8008));
    try testing.expectEqual(@as(u16, 0x8300), bus.read16(0xFF8004) & 0x8700); // EDT, DSR clear

    // DMA to PRG-RAM at DMA address 0x1000 << 3 = 0x8000, 4 bytes from DAC 0x0200.
    bus.write8(0xFF8005, 0x02);
    bus.write8(0xFF8007, 0x03); // DBC = 3
    bus.write8(0xFF8005, 0x04);
    bus.write8(0xFF8007, 0x00);
    bus.write8(0xFF8007, 0x02); // DAC = 0x0200
    bus.write16(0xFF800A, 0x1000);
    bus.write8(0xFF8004, 0x05); // DD = PRG-RAM
    bus.write8(0xFF8005, 0x06);
    bus.write8(0xFF8007, 0x00); // DTTRG -> runs at once
    try testing.expectEqualSlices(u8, f.cdc.ram[0x200..0x204], f.prg_ram[0x8000..0x8004]);
    try testing.expect(!f.cdc.transferPending());

    // DMA to Word RAM (2M, sub-owned) at 0x2000 << 3 = 0x10000.
    f.word_ram.mainRequestHandoff();
    bus.write8(0xFF8005, 0x02);
    bus.write8(0xFF8007, 0x01); // DBC = 1 -> 2 bytes
    bus.write16(0xFF800A, 0x2000);
    bus.write8(0xFF8004, 0x07);
    bus.write8(0xFF8005, 0x06);
    bus.write8(0xFF8007, 0x00);
    try testing.expectEqual(@as(u8, f.cdc.ram[0x204]), f.word_ram.read8Linear(0x10000));
    try testing.expectEqual(@as(u8, f.cdc.ram[0x205]), f.word_ram.read8Linear(0x10001));
}
