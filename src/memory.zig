const std = @import("std");
const clock = @import("clock.zig");
const AudioTiming = @import("audio_timing.zig").AudioTiming;
const Vdp = @import("vdp.zig").Vdp;
const Io = @import("io.zig").Io;
const Z80 = @import("z80.zig").Z80;

fn looksLikeGenesis(rom: []const u8) bool {
    if (rom.len < 0x104) return false;
    return std.mem.eql(u8, rom[0x100..0x104], "SEGA");
}

fn deinterleaveSmdPayload(allocator: std.mem.Allocator, payload: []const u8) ![]u8 {
    const block_size: usize = 16 * 1024;
    if (payload.len % block_size != 0) return error.InvalidSmd;

    var out = try allocator.alloc(u8, payload.len);
    var i: usize = 0;
    while (i < payload.len) : (i += block_size) {
        const block = payload[i .. i + block_size];
        var j: usize = 0;
        while (j < block_size / 2) : (j += 1) {
            out[i + j * 2] = block[j];
            out[i + j * 2 + 1] = block[j + (block_size / 2)];
        }
    }

    return out;
}

pub const Bus = struct {
    rom: []u8,
    ram: [64 * 1024]u8, // 64KB Work RAM
    vdp: Vdp,
    io: Io,
    z80: Z80,
    audio_timing: AudioTiming,
    z80_master_remainder: u8,

    fn readRomByte(self: *const Bus, address: u32) u8 {
        if (self.rom.len == 0) return 0;
        const rom_len_u32: u32 = @intCast(self.rom.len);
        const mirrored_addr: u32 = if (address < rom_len_u32) address else address % rom_len_u32;
        return self.rom[@intCast(mirrored_addr)];
    }

    fn hasZ80BusFor68k(self: *Bus) bool {
        return self.z80.readBusReq() == 0x0000;
    }

    fn readHostByteForZ80(self: *Bus, address: u32) u8 {
        const addr = address & 0xFFFFFF;
        if (addr >= 0xA00000 and addr < 0xA10000) return 0xFF;
        return self.read8(addr);
    }

    fn writeHostByteForZ80(self: *Bus, address: u32, value: u8) void {
        const addr = address & 0xFFFFFF;
        if (addr >= 0xA00000 and addr < 0xA10000) return;
        self.write8(addr, value);
    }

    fn z80HostReadCallback(userdata: ?*anyopaque, address: u32) callconv(.c) u8 {
        const self: *Bus = @ptrCast(@alignCast(userdata orelse return 0xFF));
        return self.readHostByteForZ80(address);
    }

    fn z80HostWriteCallback(userdata: ?*anyopaque, address: u32, value: u8) callconv(.c) void {
        const self: *Bus = @ptrCast(@alignCast(userdata orelse return));
        self.writeHostByteForZ80(address, value);
    }

    fn ensureZ80HostWindow(self: *Bus) void {
        self.z80.setHostCallbacks(self, z80HostReadCallback, z80HostWriteCallback);
    }

    pub fn init(allocator: std.mem.Allocator, rom_path: ?[]const u8) !Bus {
        var rom_data: []u8 = undefined;

        if (rom_path) |path| {
            const file = try std.fs.cwd().openFile(path, .{});
            defer file.close();

            const size = try file.getEndPos();
            const raw = try allocator.alloc(u8, size);
            _ = try file.readAll(raw);

            if (std.mem.endsWith(u8, path, ".smd")) {
                var candidate: ?[]u8 = null;

                if (raw.len > 512) {
                    if (deinterleaveSmdPayload(allocator, raw[512..])) |tmp| {
                        if (looksLikeGenesis(tmp)) candidate = tmp else allocator.free(tmp);
                    } else |_| {}
                }

                if (candidate == null) {
                    if (deinterleaveSmdPayload(allocator, raw)) |tmp| {
                        if (looksLikeGenesis(tmp)) candidate = tmp else allocator.free(tmp);
                    } else |_| {}
                }

                if (candidate) |rom| {
                    allocator.free(raw);
                    rom_data = rom;
                } else {
                    rom_data = raw;
                }
            } else {
                rom_data = raw;
            }
        } else {
            // Allocate dummy ROM if no path provided (for testing)
            rom_data = try allocator.alloc(u8, 4 * 1024 * 1024); // 4MB max
            @memset(rom_data, 0);
        }

        return Bus{
            .rom = rom_data,
            .ram = [_]u8{0} ** (64 * 1024),
            .vdp = Vdp.init(),
            .io = Io.init(),
            .z80 = Z80.init(),
            .audio_timing = .{},
            .z80_master_remainder = 0,
        };
    }

    pub fn deinit(self: *Bus, allocator: std.mem.Allocator) void {
        self.z80.deinit();
        allocator.free(self.rom);
    }

    // ---------------------------------------------------------
    // READ OPERATIONS
    // ---------------------------------------------------------

    pub fn read8(self: *Bus, address: u32) u8 {
        const addr = address & 0xFFFFFF; // 24-bit address bus

        if (addr < 0x400000) {
            // ROM (mirrored into the 4MB cartridge window for smaller images).
            return self.readRomByte(addr);
        } else if (addr >= 0xE00000 and addr < 0x1000000) {
            // RAM (Mirrored at 0xE00000 - 0xFFFFFF)
            // Mask to 64KB (0xFFFF)
            return self.ram[addr & 0xFFFF];
        } else if (addr >= 0xA00000 and addr < 0xA10000) {
            // Z80 address-space window.
            if (!self.hasZ80BusFor68k()) return 0xFF;
            self.ensureZ80HostWindow();
            const zaddr: u16 = @truncate(addr & 0xFFFF);
            return self.z80.readByte(zaddr);
        } else if (addr >= 0xC00000 and addr < 0xC00020) {
            if (addr < 0xC00004) {
                const word = self.vdp.readData();
                return if ((addr & 1) == 0) @intCast((word >> 8) & 0xFF) else @intCast(word & 0xFF);
            }
            if (addr < 0xC00008) {
                const word = self.vdp.readControl();
                return if ((addr & 1) == 0) @intCast((word >> 8) & 0xFF) else @intCast(word & 0xFF);
            }
            if (addr < 0xC00010) {
                const word = self.vdp.readHVCounter();
                return if ((addr & 1) == 0) @intCast((word >> 8) & 0xFF) else @intCast(word & 0xFF);
            }
            return 0;
        } else if (addr >= 0xA10000 and addr < 0xA10100) {
            // IO
            return self.io.read(addr);
        }

        // Unmapped / IO Stub
        return 0;
    }

    pub fn read16(self: *Bus, address: u32) u16 {
        const addr = address & 0xFFFFFF;
        if (addr == 0xA11100) { // Z80 Bus Request
            return self.z80.readBusReq();
        } else if (addr == 0xA11200) { // Z80 Reset
            return 0; // Write only?
        } else if (addr >= 0xC00000 and addr < 0xC00020) {
            // VDP Ports
            if (addr == 0xC00000) return self.vdp.readData();
            if (addr == 0xC00004) return self.vdp.readControl();
            if (addr >= 0xC00008 and addr < 0xC00010) return self.vdp.readHVCounter();
        }

        // M68k accesses are generally word-aligned, but we'll support unaligned for safety
        // Real hardware might throw address error on unaligned word access
        const high = self.read8(address);
        const low = self.read8(address + 1);
        return (@as(u16, high) << 8) | low;
    }

    pub fn read32(self: *Bus, address: u32) u32 {
        const high = self.read16(address);
        const low = self.read16(address + 2);
        return (@as(u32, high) << 16) | low;
    }

    // ---------------------------------------------------------
    // WRITE OPERATIONS
    // ---------------------------------------------------------

    pub fn write8(self: *Bus, address: u32, value: u8) void {
        const addr = address & 0xFFFFFF;

        if (addr < 0x400000) {
            // ROM is read-only
            return;
        } else if (addr >= 0xE00000 and addr < 0x1000000) {
            // RAM
            self.ram[addr & 0xFFFF] = value;
        } else if (addr >= 0xA00000 and addr < 0xA10000) {
            // Z80 address-space window.
            if (!self.hasZ80BusFor68k()) return;
            self.ensureZ80HostWindow();
            const zaddr: u16 = @truncate(addr & 0xFFFF);
            self.z80.writeByte(zaddr, value);
            return;
        } else if (addr >= 0xA10000 and addr < 0xA10100) {
            // IO
            self.io.write(addr, value);
        } else if (addr >= 0xC00000 and addr < 0xC00020) {
            const word: u16 = if ((addr & 1) == 0) (@as(u16, value) << 8) else @as(u16, value);
            if (addr < 0xC00004) {
                self.vdp.writeData(word);
            } else if (addr < 0xC00008) {
                self.vdp.writeControl(word);
            }
            return;
        }
    }

    pub fn write16(self: *Bus, address: u32, value: u16) void {
        const addr = address & 0xFFFFFF;

        if (addr >= 0xC00000 and addr < 0xC00020) {
            // VDP Ports
            if (addr == 0xC00000) {
                self.vdp.writeData(value);
            } else if (addr == 0xC00004) {
                self.vdp.writeControl(value);
            }
            return;
        }

        if (addr == 0xA11100) { // Z80 Bus Request
            self.z80.writeBusReq(value);
            return;
        } else if (addr == 0xA11200) { // Z80 Reset
            self.z80.writeReset(value);
            return;
        }

        self.write8(address, @intCast((value >> 8) & 0xFF));
        self.write8(address + 1, @intCast(value & 0xFF));
    }

    pub fn write32(self: *Bus, address: u32, value: u32) void {
        const addr = address & 0xFFFFFF;
        if (addr >= 0xC00000 and addr < 0xC00020) {
            // VDP 32-bit writes are treated as two 16-bit writes
            self.write16(address, @intCast((value >> 16) & 0xFFFF));
            self.write16(address + 2, @intCast(value & 0xFFFF));
            return;
        }

        self.write16(address, @intCast((value >> 16) & 0xFFFF));
        self.write16(address + 2, @intCast(value & 0xFFFF));
    }
    pub fn stepMaster(self: *Bus, master_cycles: u32) void {
        self.vdp.step(master_cycles);
        self.audio_timing.consumeMaster(master_cycles);

        self.ensureZ80HostWindow();
        const total = @as(u32, self.z80_master_remainder) + master_cycles;
        const z80_cycles = total / clock.z80_divider;
        self.z80_master_remainder = @intCast(total % clock.z80_divider);
        self.z80.step(z80_cycles);

        if (self.vdp.dma_active) {
            // Perform DMA
            if (self.vdp.dma_fill) {
                // DMA fill completes on the next VDP data port write.
                // Keep the DMA state armed until VDP.writeData consumes it.
            } else if (self.vdp.dma_copy) {
                // VRAM-to-VRAM Copy (DMA Mode 3).
                // Source and dest are both VRAM-internal; no bus access needed.
                var remaining = self.vdp.dma_remaining;
                if (remaining == 0) {
                    self.vdp.dma_active = false;
                    self.vdp.dma_copy = false;
                    return;
                }
                var budget_words = @as(u32, master_cycles / 8);
                if (budget_words == 0) budget_words = 1;
                if (budget_words > remaining) budget_words = remaining;

                var src_addr = self.vdp.dma_source_addr;
                var words_done: u32 = 0;
                while (words_done < budget_words) : (words_done += 1) {
                    // VRAM copy reads a byte at source and writes to dest.
                    const byte = self.vdp.vram[@as(u16, @truncate(src_addr)) & 0xFFFF];
                    self.vdp.vram[self.vdp.addr & 0xFFFF] = byte;
                    src_addr += 1;
                    self.vdp.advanceAddr();
                }

                self.vdp.dma_source_addr = src_addr;
                remaining -= words_done;
                self.vdp.dma_remaining = remaining;
                if (remaining == 0) {
                    self.vdp.dma_length = 0;
                    self.vdp.dma_active = false;
                    self.vdp.dma_copy = false;
                }
            } else {
                // 68k -> VDP Transfer (DMA Mode 0 or 1)
                var remaining = self.vdp.dma_remaining;
                if (remaining == 0) {
                    self.vdp.dma_active = false;
                    return;
                }
                // Incremental DMA: avoid stalling an entire frame on large transfers.
                var budget_words = @as(u32, master_cycles / 8);
                if (budget_words == 0) budget_words = 1;
                if (budget_words > remaining) budget_words = remaining;

                var src_addr = self.vdp.dma_source_addr;
                var words_done: u32 = 0;
                while (words_done < budget_words) : (words_done += 1) {
                    const word = self.read16(src_addr);
                    self.vdp.writeData(word);
                    src_addr += 2; // Source address increments
                }

                self.vdp.dma_source_addr = src_addr;
                remaining -= words_done;
                self.vdp.dma_remaining = remaining;
                if (remaining == 0) {
                    self.vdp.dma_length = 0;
                    self.vdp.dma_active = false;
                }
            }
        }
    }

    pub fn step(self: *Bus, m68k_cycles: u32) void {
        self.stepMaster(clock.m68kCyclesToMaster(m68k_cycles));
    }
};
