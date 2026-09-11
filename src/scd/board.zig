//! Sega CD sub-board: owns the sub CPU, its bus, the gate array, Word RAM,
//! PRG-RAM, backup RAM, the disc, and the master->sub clock credit. Plugs
//! into the Genesis `Bus` as an `ExpansionDevice`.
//!
//! Scheduling mirrors the Z80 model: `stepMaster` only accrues credit;
//! `flush` runs the sub CPU up to that credit at the end of each 68K slice
//! and whenever the main CPU touches a shared resource (gate array, PRG-RAM,
//! Word RAM), so the two CPUs never observe each other more than one main
//! instruction out of order.

const std = @import("std");
const Cpu = @import("../cpu/cpu.zig").Cpu;
const MemoryInterface = @import("../cpu/memory_interface.zig").MemoryInterface;
const ExpansionDevice = @import("../bus/expansion.zig").ExpansionDevice;
const scd_clock = @import("clock.zig");
const gate_array = @import("gate_array.zig");
const GateArray = gate_array.GateArray;
const WordRam = @import("word_ram.zig").WordRam;
const sub_bus_mod = @import("sub_bus.zig");
const SubBus = sub_bus_mod.SubBus;
const Disc = @import("cdrom/reader.zig").Disc;
const reader = @import("cdrom/reader.zig");
const Cdd = @import("cdd.zig").Cdd;
const cdd_mod = @import("cdd.zig");
const Cdc = @import("cdc.zig").Cdc;
const cdc_mod = @import("cdc.zig");
const backup_ram_mod = @import("backup_ram.zig");
const Pcm = @import("pcm.zig").Pcm;
const ExpansionAudio = @import("../audio/timing.zig").ExpansionAudio;

pub const prg_ram_bytes = sub_bus_mod.prg_ram_bytes;
pub const backup_ram_bytes = sub_bus_mod.backup_ram_bytes;
pub const prg_bank_bytes: u32 = 128 * 1024;

/// Cycle cost charged when the core reports zero (e.g. STOP state) so the
/// burst loop always makes progress.
const min_step_sub_cycles: u32 = 4;

/// Enough CD-DA for two host frames at 44.1 kHz (a NTSC frame is 735).
pub const max_cdda_frames: u32 = 2048;
/// Enough PCM for two host frames at 32.55 kHz (a NTSC frame is 543).
pub const max_pcm_frames: u32 = 2048;

pub const ScdBoard = struct {
    allocator: std.mem.Allocator,
    sub_cpu: Cpu,
    sub_bus: SubBus,
    sub_mem: MemoryInterface,
    gate: GateArray,
    word_ram: WordRam,
    prg_ram: [prg_ram_bytes]u8,
    backup_ram: [backup_ram_bytes]u8,
    sync: scd_clock.SubSync,
    disc: ?Disc,
    cdd: Cdd,
    cdc: Cdc,
    pcm: Pcm,
    /// PCM samples produced this host frame (one per 384-cycle tick).
    pcm_frames: [max_pcm_frames][2]i16 = [_][2]i16{.{ 0, 0 }} ** max_pcm_frames,
    pcm_frame_count: u32 = 0,
    pcm_overflow: u32 = 0,
    /// Slices handed to the audio stage; valid until the next take.
    expansion_audio: ExpansionAudio = .{},
    /// Sub cycles x 75 accumulated toward the next sector tick.
    sector_accumulator: u64 = 0,
    /// CD-DA frames delivered this host frame (drained by the audio path).
    cdda_frames: [max_cdda_frames][2]i16 = [_][2]i16{.{ 0, 0 }} ** max_cdda_frames,
    cdda_frame_count: u32 = 0,
    cdda_overflow: u32 = 0,
    /// BIOS image, borrowed from the Genesis cartridge slot (served as the
    /// mirror at 0x040000+ inside every 0x40000 block below 0x400000).
    bios: []const u8,
    /// Where the internal backup RAM persists, when attached to a disc file.
    backup_ram_path: ?[]u8 = null,
    /// Diagnostics.
    main_non_owner_word_ram_accesses: u32 = 0,
    sub_instructions: u64 = 0,

    pub fn create(allocator: std.mem.Allocator, bios: []const u8, disc: ?Disc, pal_mode: bool) !*ScdBoard {
        const board = try allocator.create(ScdBoard);
        board.* = .{
            .allocator = allocator,
            .sub_cpu = Cpu.init(),
            .sub_bus = undefined,
            .sub_mem = undefined,
            .gate = .{},
            .word_ram = .{},
            .prg_ram = [_]u8{0} ** prg_ram_bytes,
            .backup_ram = backup_ram_mod.initialImage(),
            .sync = scd_clock.SubSync.init(pal_mode),
            .disc = disc,
            .cdd = Cdd.init(disc != null),
            .cdc = .{},
            .pcm = .{},
            .bios = bios,
        };
        board.bind();
        return board;
    }

    pub fn destroy(self: *ScdBoard) void {
        if (self.disc) |*d| d.deinit();
        if (self.backup_ram_path) |p| self.allocator.free(p);
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    /// Rebuild internal pointers after the board moved or was cloned.
    pub fn bind(self: *ScdBoard) void {
        self.sub_bus = .{
            .cpu = &self.sub_cpu,
            .gate = &self.gate,
            .word_ram = &self.word_ram,
            .prg_ram = &self.prg_ram,
            .backup_ram = &self.backup_ram,
            .cdc = &self.cdc,
            .pcm = .{ .ctx = &self.pcm, .read8Fn = pcmRead8, .write8Fn = pcmWrite8 },
        };
        self.sub_mem = self.sub_bus.memoryInterface();
        self.publishCddStatus();
    }

    fn pcmRead8(ctx: *anyopaque, offset: u32) u8 {
        const pcm: *Pcm = @ptrCast(@alignCast(ctx));
        return pcm.read8(offset);
    }

    fn pcmWrite8(ctx: *anyopaque, offset: u32, value: u8) void {
        const pcm: *Pcm = @ptrCast(@alignCast(ctx));
        pcm.write8(offset, value);
    }

    /// Run the PCM chip for `ticks` sample periods.
    fn clockPcm(self: *ScdBoard, ticks: u32) void {
        var i: u32 = 0;
        while (i < ticks) : (i += 1) {
            const sample = self.pcm.clockSample();
            if (self.pcm_frame_count >= max_pcm_frames) {
                self.pcm_overflow += 1;
                continue;
            }
            self.pcm_frames[self.pcm_frame_count] = sample;
            self.pcm_frame_count += 1;
        }
    }

    /// Hand this window's PCM and CD-DA samples to the audio stage.
    pub fn takeExpansionAudio(self: *ScdBoard) *const ExpansionAudio {
        self.expansion_audio = .{
            .pcm = self.pcm_frames[0..self.pcm_frame_count],
            .cdda = self.cdda_frames[0..self.cdda_frame_count],
        };
        self.pcm_frame_count = 0;
        self.cdda_frame_count = 0;
        return &self.expansion_audio;
    }

    fn publishCddStatus(self: *ScdBoard) void {
        self.gate.cdd_status = self.cdd.status;
    }

    fn discPtr(self: *ScdBoard) ?*Disc {
        return if (self.disc) |*d| d else null;
    }

    /// Advance the 75 Hz drive clock by `sub_cycles`.
    fn advanceDrive(self: *ScdBoard, sub_cycles: u32) void {
        self.sector_accumulator += @as(u64, sub_cycles) * scd_clock.sector_rate_hz;
        while (self.sector_accumulator >= scd_clock.sub_clock_hz) {
            self.sector_accumulator -= scd_clock.sub_clock_hz;
            self.driveTick();
        }
    }

    fn driveTick(self: *ScdBoard) void {
        const event = self.cdd.tick(self.discPtr());
        self.publishCddStatus();
        switch (event) {
            .none => {},
            .data => |d| {
                if (self.cdc.decodeSector(d.raw)) self.gate.raise(.cdc, &self.sub_cpu);
            },
            .audio => |a| self.pushCdda(a.frames),
        }
        // HOCK: host clock enabled -> INT4 every sector period.
        if ((self.gate.cdd_control & 0x0004) != 0) self.gate.raise(.cdd, &self.sub_cpu);
    }

    fn pushCdda(self: *ScdBoard, frames: *const [reader.audio_frames_per_sector][2]i16) void {
        const gain: i32 = self.cdd.fader; // 0..0x3FF
        for (frames) |f| {
            if (self.cdda_frame_count >= max_cdda_frames) {
                self.cdda_overflow += 1;
                return;
            }
            self.cdda_frames[self.cdda_frame_count] = .{
                @intCast(@divTrunc(@as(i32, f[0]) * gain, 0x400)),
                @intCast(@divTrunc(@as(i32, f[1]) * gain, 0x400)),
            };
            self.cdda_frame_count += 1;
        }
    }

    /// Hand the CD-DA frames accumulated since the last call to the caller
    /// and reset the ring.
    pub fn takeCddaFrames(self: *ScdBoard) []const [2]i16 {
        const n = self.cdda_frame_count;
        self.cdda_frame_count = 0;
        return self.cdda_frames[0..n];
    }

    fn processCddCommand(self: *ScdBoard) void {
        _ = self.cdd.command(&self.gate.cdd_command, self.discPtr());
        self.publishCddStatus();
    }

    fn serviceSubSideRequests(self: *ScdBoard) void {
        if (self.sub_bus.cdd_command_ready) {
            self.sub_bus.cdd_command_ready = false;
            self.processCddCommand();
        }
        if (self.sub_bus.cdc_irq_request) {
            self.sub_bus.cdc_irq_request = false;
            self.gate.raise(.cdc, &self.sub_cpu);
        }
        // Fader writes take effect immediately.
        self.cdd.setFaderRegister(self.gate.cd_fader);
    }

    pub fn setBios(self: *ScdBoard, bios: []const u8) void {
        self.bios = bios;
    }

    pub fn setPalMode(self: *ScdBoard, pal_mode: bool) void {
        self.sync = scd_clock.SubSync.init(pal_mode);
    }

    /// Duplicate for snapshots: memory discs are copied, file discs reopened.
    pub fn clone(self: *const ScdBoard) !*ScdBoard {
        const board = try self.allocator.create(ScdBoard);
        errdefer self.allocator.destroy(board);
        board.* = self.*;
        board.sub_cpu = self.sub_cpu.clone();
        board.disc = null;
        board.backup_ram_path = null;
        if (self.disc) |*d| board.disc = try d.clone();
        errdefer if (board.disc) |*d| d.deinit();
        if (self.backup_ram_path) |path| board.backup_ram_path = try self.allocator.dupe(u8, path);
        board.bind();
        return board;
    }

    // -----------------------------------------------------------------------
    // Backup RAM persistence
    // -----------------------------------------------------------------------

    /// Attach a file for the internal backup RAM and load it if present.
    pub fn setBackupRamPath(self: *ScdBoard, path: []const u8) !void {
        if (self.backup_ram_path) |old| self.allocator.free(old);
        self.backup_ram_path = try self.allocator.dupe(u8, path);
        const platform = @import("../platform.zig");
        const file = platform.cwd().openFile(path, .{}) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer file.close();
        var image: [backup_ram_bytes]u8 = undefined;
        const n = try file.readAll(&image);
        if (n == backup_ram_bytes) {
            self.backup_ram = image;
            self.sub_bus.backup_ram_dirty = false;
        }
    }

    pub fn flushBackupRam(self: *ScdBoard) !void {
        if (!self.sub_bus.backup_ram_dirty) return;
        const path = self.backup_ram_path orelse return;
        const platform = @import("../platform.zig");
        var file = try platform.cwd().createFile(path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(&self.backup_ram);
        self.sub_bus.backup_ram_dirty = false;
    }

    // -----------------------------------------------------------------------
    // Save-state serialization (in place; large arrays stream without copies
    // because the main thread's stack is only 8MB)
    // -----------------------------------------------------------------------

    pub const state_version: u16 = 1;

    pub fn writeState(self: *const ScdBoard, writer: anytype, comptime writeValue: anytype) !void {
        try writeValue(writer, self.sub_cpu.captureState());
        try writeValue(writer, self.gate);
        try writeValue(writer, self.word_ram.mode);
        try writeValue(writer, self.word_ram.ret);
        try writeValue(writer, self.word_ram.dmna);
        try writeValue(writer, self.word_ram.priority);
        try writer.writeAll(&self.word_ram.banks[0]);
        try writer.writeAll(&self.word_ram.banks[1]);
        try writer.writeAll(&self.prg_ram);
        try writer.writeAll(&self.backup_ram);
        try writeValue(writer, self.sync);
        try writeValue(writer, self.cdd);
        try writeValue(writer, self.cdc.ifstat);
        try writeValue(writer, self.cdc.ifctrl);
        try writeValue(writer, self.cdc.dbc);
        try writeValue(writer, self.cdc.dac);
        try writeValue(writer, self.cdc.head);
        try writeValue(writer, self.cdc.pt);
        try writeValue(writer, self.cdc.wa);
        try writeValue(writer, self.cdc.ctrl);
        try writeValue(writer, self.cdc.stat);
        try writeValue(writer, self.cdc.comin);
        try writeValue(writer, self.cdc.sbout);
        try writeValue(writer, self.cdc.host_transfer_active);
        try writeValue(writer, self.cdc.irq_asserted);
        try writeValue(writer, self.cdc.end_of_transfer);
        try writer.writeAll(&self.cdc.ram);
        try writeValue(writer, self.pcm.channels);
        try writeValue(writer, self.pcm.enabled);
        try writeValue(writer, self.pcm.selected_channel);
        try writeValue(writer, self.pcm.bank);
        try writer.writeAll(&self.pcm.ram);
        try writeValue(writer, self.sector_accumulator);
        try writeValue(writer, self.sub_instructions);
    }

    pub fn readState(self: *ScdBoard, stream: anytype, comptime readInto: anytype) !void {
        var cpu_state: Cpu.State = undefined;
        try readInto(stream, &cpu_state);
        self.sub_cpu.restoreState(&cpu_state);
        try readInto(stream, &self.gate);
        try readInto(stream, &self.word_ram.mode);
        try readInto(stream, &self.word_ram.ret);
        try readInto(stream, &self.word_ram.dmna);
        try readInto(stream, &self.word_ram.priority);
        try stream.readSliceAll(&self.word_ram.banks[0]);
        try stream.readSliceAll(&self.word_ram.banks[1]);
        try stream.readSliceAll(&self.prg_ram);
        try stream.readSliceAll(&self.backup_ram);
        try readInto(stream, &self.sync);
        try readInto(stream, &self.cdd);
        try readInto(stream, &self.cdc.ifstat);
        try readInto(stream, &self.cdc.ifctrl);
        try readInto(stream, &self.cdc.dbc);
        try readInto(stream, &self.cdc.dac);
        try readInto(stream, &self.cdc.head);
        try readInto(stream, &self.cdc.pt);
        try readInto(stream, &self.cdc.wa);
        try readInto(stream, &self.cdc.ctrl);
        try readInto(stream, &self.cdc.stat);
        try readInto(stream, &self.cdc.comin);
        try readInto(stream, &self.cdc.sbout);
        try readInto(stream, &self.cdc.host_transfer_active);
        try readInto(stream, &self.cdc.irq_asserted);
        try readInto(stream, &self.cdc.end_of_transfer);
        try stream.readSliceAll(&self.cdc.ram);
        try readInto(stream, &self.pcm.channels);
        try readInto(stream, &self.pcm.enabled);
        try readInto(stream, &self.pcm.selected_channel);
        try readInto(stream, &self.pcm.bank);
        try stream.readSliceAll(&self.pcm.ram);
        try readInto(stream, &self.sector_accumulator);
        try readInto(stream, &self.sub_instructions);

        self.cdd.disc_present = self.disc != null;
        self.pcm_frame_count = 0;
        self.cdda_frame_count = 0;
        self.sub_bus.cdd_command_ready = false;
        self.sub_bus.cdc_irq_request = false;
        self.sub_bus.backup_ram_dirty = true;
        self.publishCddStatus();
    }

    /// Exchange the contents of two boards without a stack temporary.
    pub fn swapContents(a: *ScdBoard, b: *ScdBoard) !void {
        const tmp = try a.allocator.create(ScdBoard);
        defer a.allocator.destroy(tmp);
        tmp.* = a.*;
        a.* = b.*;
        b.* = tmp.*;
        a.bind();
        b.bind();
    }


    pub fn device(self: *ScdBoard) ExpansionDevice {
        return ExpansionDevice.bind(ScdBoard, self);
    }

    // -----------------------------------------------------------------------
    // ExpansionDevice: scheduling
    // -----------------------------------------------------------------------

    pub fn stepMaster(self: *ScdBoard, master_cycles: u32) void {
        _ = self.sync.addMaster(master_cycles);
    }

    /// Run the sub CPU until its credit is spent.
    pub fn flush(self: *ScdBoard) void {
        self.serviceSubSideRequests();
        while (self.sync.credit > 0) {
            if (self.sub_bus.shouldHaltCpu()) {
                // Held in reset or bus-requested: time passes, nothing runs,
                // but the drive keeps spinning.
                const cycles: u32 = @intCast(@min(self.sync.credit, std.math.maxInt(u32)));
                self.clockPcm(self.gate.advanceSubCycles(cycles, &self.sub_cpu));
                self.advanceDrive(cycles);
                self.sync.drain();
                break;
            }
            if (self.sub_cpu.halted) {
                // STOP: advance to the next tick so timers/drive can wake the CPU.
                const to_tick = scd_clock.timer_divider - self.gate.tick_accumulator;
                const cycles: u32 = @intCast(@min(self.sync.credit, to_tick));
                self.clockPcm(self.gate.advanceSubCycles(cycles, &self.sub_cpu));
                self.advanceDrive(cycles);
                self.sync.consume(cycles);
                if (self.sub_cpu.pending_irq_levels == 0) continue;
            }
            const step = self.sub_cpu.stepInstruction(&self.sub_mem);
            self.sub_instructions += 1;
            var cycles = step.m68k_cycles + step.wait.m68k_cycles;
            if (cycles == 0) cycles = min_step_sub_cycles;
            self.clockPcm(self.gate.advanceSubCycles(cycles, &self.sub_cpu));
            self.advanceDrive(cycles);
            self.gate.observeInterruptService(&self.sub_cpu);
            self.sync.consume(cycles);
            self.serviceSubSideRequests();
        }
    }

    pub fn reset(self: *ScdBoard) void {
        self.sub_cpu = Cpu.init();
        self.gate.reset();
        self.word_ram = .{};
        self.prg_ram = [_]u8{0} ** prg_ram_bytes;
        self.sync.drain();
        self.sync.remainder = 0;
        self.cdd = Cdd.init(self.disc != null);
        self.cdc = .{};
        self.pcm.reset();
        self.sector_accumulator = 0;
        self.cdda_frame_count = 0;
        self.pcm_frame_count = 0;
        self.sub_bus.cdd_command_ready = false;
        self.sub_bus.cdc_irq_request = false;
        self.sub_bus.non_owner_word_ram_accesses = 0;
        self.main_non_owner_word_ram_accesses = 0;
        self.publishCddStatus();
    }

    fn releaseSubReset(self: *ScdBoard) void {
        self.sub_cpu.reset(&self.sub_mem);
    }

    // -----------------------------------------------------------------------
    // ExpansionDevice: main-CPU address claims
    // -----------------------------------------------------------------------

    const MainRegion = union(enum) {
        hint_vector: u2, // byte within the 4-byte vector
        bios_mirror: u32, // offset into BIOS
        prg_window: u32, // offset into PRG-RAM
        word_ram_2m: u32,
        word_ram_1m_bank: u32,
        word_ram_1m_cell: u32,
        gate: u8,
    };

    fn classify(self: *const ScdBoard, addr: u32) ?MainRegion {
        if (addr >= 0x200000 and addr < 0x240000) {
            const off = addr - 0x200000;
            return switch (self.word_ram.mode) {
                .two_m => .{ .word_ram_2m = off },
                .one_m => if (off < 0x20000) .{ .word_ram_1m_bank = off } else .{ .word_ram_1m_cell = off - 0x20000 },
            };
        }
        if (addr < 0x400000) {
            if (addr >= 0x70 and addr < 0x74) return .{ .hint_vector = @intCast(addr - 0x70) };
            const page = addr & 0x3FFFF;
            if (page >= 0x20000) {
                return .{ .prg_window = @as(u32, self.gate.prg_bank) * prg_bank_bytes + (page - 0x20000) };
            }
            if (addr >= 0x40000) return .{ .bios_mirror = page };
            return null; // BIOS proper: served by the cartridge slot.
        }
        if (addr >= 0xA12000 and addr < 0xA12040) return .{ .gate = @intCast(addr - 0xA12000) };
        return null;
    }

    fn biosByte(self: *const ScdBoard, offset: u32) u8 {
        return if (offset < self.bios.len) self.bios[offset] else 0;
    }

    pub fn read8(self: *ScdBoard, address: u32) ?u8 {
        const region = self.classify(address & 0xFFFFFF) orelse return null;
        switch (region) {
            .hint_vector => |b| {
                const vector: u32 = 0x00FF0000 | @as(u32, self.gate.hint_vector);
                return @truncate(vector >> @intCast((3 - @as(u32, b)) * 8));
            },
            .bios_mirror => |o| return self.biosByte(o),
            .prg_window => |o| {
                self.flush();
                return self.prg_ram[o];
            },
            .word_ram_2m => |o| {
                self.flush();
                if (!self.word_ram.mainOwns2M()) {
                    self.main_non_owner_word_ram_accesses += 1;
                    return 0xFF;
                }
                return self.word_ram.read8Linear(o);
            },
            .word_ram_1m_bank => |o| {
                self.flush();
                return self.word_ram.read8Bank(self.word_ram.mainBank1M(), o);
            },
            .word_ram_1m_cell => |o| {
                self.flush();
                return self.word_ram.readCell8(self.word_ram.mainBank1M(), o);
            },
            .gate => |o| {
                self.flush();
                if (o == 0x08 or o == 0x09) {
                    const w = self.mainHostRead();
                    return if (o == 0x08) @truncate(w >> 8) else @truncate(w);
                }
                if (o == 0x04 or o == 0x05) self.sub_bus.syncCdcFlags();
                return self.gate.mainRead8(o, &self.word_ram);
            },
        }
    }

    /// Main-side CDC host data port (0xA12008).
    fn mainHostRead(self: *ScdBoard) u16 {
        if (@as(cdc_mod.Destination, @enumFromInt(self.gate.cdc_device_destination)) != .main_read) return 0xFFFF;
        const r = self.cdc.hostRead();
        if (r.raise_irq) self.gate.raise(.cdc, &self.sub_cpu);
        return r.word;
    }

    pub fn read16(self: *ScdBoard, address: u32) ?u16 {
        const addr = address & 0xFFFFFE;
        const region = self.classify(addr) orelse return null;
        switch (region) {
            .hint_vector => |b| {
                const vector: u32 = 0x00FF0000 | @as(u32, self.gate.hint_vector);
                return if (b == 0) @truncate(vector >> 16) else @truncate(vector);
            },
            .bios_mirror => |o| return (@as(u16, self.biosByte(o)) << 8) | self.biosByte(o + 1),
            .prg_window => |o| {
                self.flush();
                return (@as(u16, self.prg_ram[o]) << 8) | self.prg_ram[o + 1];
            },
            .word_ram_2m => |o| {
                self.flush();
                if (!self.word_ram.mainOwns2M()) {
                    self.main_non_owner_word_ram_accesses += 1;
                    return 0xFFFF;
                }
                return self.word_ram.read16Linear(o);
            },
            .word_ram_1m_bank => |o| {
                self.flush();
                return self.word_ram.read16Bank(self.word_ram.mainBank1M(), o);
            },
            .word_ram_1m_cell => |o| {
                self.flush();
                return self.word_ram.readCell16(self.word_ram.mainBank1M(), o);
            },
            .gate => |o| {
                self.flush();
                if (o == 0x08) return self.mainHostRead();
                if (o == 0x04) self.sub_bus.syncCdcFlags();
                return self.gate.mainRead16(o, &self.word_ram);
            },
        }
    }

    fn applyMainWriteEffects(self: *ScdBoard, effects: gate_array.MainWriteEffects) void {
        if (effects.sub_reset_released) self.releaseSubReset();
    }

    pub fn write8(self: *ScdBoard, address: u32, value: u8) bool {
        const addr = address & 0xFFFFFF;
        const region = self.classify(addr) orelse return false;
        switch (region) {
            .hint_vector, .bios_mirror => return true, // ROM: ignored
            .prg_window => |o| {
                self.flush();
                if (o >= @as(u32, self.gate.write_protect) * sub_bus_mod.write_protect_unit) self.prg_ram[o] = value;
            },
            .word_ram_2m => |o| {
                self.flush();
                if (!self.word_ram.mainOwns2M()) {
                    self.main_non_owner_word_ram_accesses += 1;
                    return true;
                }
                self.word_ram.write8Linear(o, value);
            },
            .word_ram_1m_bank => |o| {
                self.flush();
                self.word_ram.write8Bank(self.word_ram.mainBank1M(), o, value);
            },
            .word_ram_1m_cell => |o| {
                self.flush();
                self.word_ram.writeCell8(self.word_ram.mainBank1M(), o, value);
            },
            .gate => |o| {
                self.flush();
                const lanes: u2 = if ((o & 1) == 0) 0b10 else 0b01;
                const word: u16 = if ((o & 1) == 0) @as(u16, value) << 8 else value;
                const effects = self.gate.mainWrite(o, word, lanes, .{ .cpu = &self.sub_cpu, .word_ram = &self.word_ram });
                self.applyMainWriteEffects(effects);
            },
        }
        return true;
    }

    pub fn write16(self: *ScdBoard, address: u32, value: u16) bool {
        const addr = address & 0xFFFFFE;
        const region = self.classify(addr) orelse return false;
        switch (region) {
            .hint_vector, .bios_mirror => return true,
            .prg_window => |o| {
                self.flush();
                if (o >= @as(u32, self.gate.write_protect) * sub_bus_mod.write_protect_unit) {
                    self.prg_ram[o] = @truncate(value >> 8);
                    self.prg_ram[o + 1] = @truncate(value);
                }
            },
            .word_ram_2m => |o| {
                self.flush();
                if (!self.word_ram.mainOwns2M()) {
                    self.main_non_owner_word_ram_accesses += 1;
                    return true;
                }
                self.word_ram.write16Linear(o, value);
            },
            .word_ram_1m_bank => |o| {
                self.flush();
                self.word_ram.write16Bank(self.word_ram.mainBank1M(), o, value);
            },
            .word_ram_1m_cell => |o| {
                self.flush();
                self.word_ram.writeCell16(self.word_ram.mainBank1M(), o, value);
            },
            .gate => |o| {
                self.flush();
                const effects = self.gate.mainWrite(o, value, 0b11, .{ .cpu = &self.sub_cpu, .word_ram = &self.word_ram });
                self.applyMainWriteEffects(effects);
            },
        }
        return true;
    }

    // -----------------------------------------------------------------------
    // Introspection for tests and debuggers
    // -----------------------------------------------------------------------

    pub fn subProgramCounter(self: *const ScdBoard) u32 {
        return self.sub_cpu.core.pc;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn writeBe32(buf: []u8, offset: usize, value: u32) void {
    std.mem.writeInt(u32, buf[offset..][0..4], value, .big);
}

fn writeBe16(buf: []u8, offset: usize, value: u16) void {
    std.mem.writeInt(u16, buf[offset..][0..2], value, .big);
}

test "main window addresses classify to prg ram, bios mirror, word ram, and gate array" {
    var bios = [_]u8{0} ** 0x20000;
    bios[0x1234] = 0xAB;
    const board = try ScdBoard.create(testing.allocator, &bios, null, false);
    defer board.destroy();

    // BIOS proper is left to the cartridge slot; mirrors are claimed.
    try testing.expect(board.read8(0x001234) == null);
    try testing.expectEqual(@as(?u8, 0xAB), board.read8(0x041234));
    try testing.expectEqual(@as(?u8, 0xAB), board.read8(0x3C1234));

    // HINT vector: 0x00FFxxxx from register 0xA12006.
    try testing.expect(board.write16(0xA12006, 0xFD0C));
    try testing.expectEqual(@as(?u16, 0x00FF), board.read16(0x000070));
    try testing.expectEqual(@as(?u16, 0xFD0C), board.read16(0x000072));
    try testing.expectEqual(@as(?u8, 0x0C), board.read8(0x000073));

    // PRG-RAM window follows the bank register and mirrors every 0x40000.
    try testing.expect(board.write16(0x020000, 0x1122));
    try testing.expectEqual(@as(?u16, 0x1122), board.read16(0x020000));
    try testing.expectEqual(@as(?u16, 0x1122), board.read16(0x3E0000));
    try testing.expectEqual(@as(u8, 0x11), board.prg_ram[0]);
    try testing.expect(board.write8(0xA12003, 0x40)); // BK = 1
    try testing.expectEqual(@as(?u16, 0x0000), board.read16(0x020000));
    try testing.expect(board.write16(0x020002, 0x3344));
    try testing.expectEqual(@as(u8, 0x33), board.prg_ram[prg_bank_bytes + 2]);

    // Word RAM 2M: main owns at power-on.
    try testing.expect(board.write16(0x200000, 0xBEEF));
    try testing.expectEqual(@as(?u16, 0xBEEF), board.read16(0x200000));
    try testing.expectEqual(@as(?u16, 0xBEEF), board.read16(0x200000));
    // Hand off to the sub: main now reads 0xFFFF and is counted.
    try testing.expect(board.write8(0xA12003, 0x42));
    try testing.expectEqual(@as(?u16, 0xFFFF), board.read16(0x200000));
    try testing.expectEqual(@as(u32, 1), board.main_non_owner_word_ram_accesses);

    // Unrelated addresses are not claimed.
    try testing.expect(board.read8(0xFF0000) == null);
    try testing.expect(board.read16(0xA10000) == null);
    try testing.expect(!board.write16(0xC00000, 0));
    try testing.expect(!board.write8(0xA130F1, 1));
}

test "1M mode routes main accesses to the owned bank and its cell image" {
    var bios = [_]u8{0} ** 0x200;
    const board = try ScdBoard.create(testing.allocator, &bios, null, false);
    defer board.destroy();
    board.word_ram.subSetMode(.one_m);
    const bank = board.word_ram.mainBank1M();

    try testing.expect(board.write16(0x200010, 0xABCD));
    try testing.expectEqual(@as(u16, 0xABCD), board.word_ram.read16Bank(bank, 0x10));
    // Cell image byte 4 is line 1 of cell (0,0) -> bitmap offset 256.
    try testing.expect(board.write8(0x220004, 0x5A));
    try testing.expectEqual(@as(u8, 0x5A), board.word_ram.read8Bank(bank, 256));
    try testing.expectEqual(@as(?u8, 0x5A), board.read8(0x220004));
    try testing.expectEqual(@as(?u8, 0x5A), board.read8(0x200100));
    // Cell (1,0) line 0 starts 32 cells (0x400 bytes) later in the image.
    try testing.expect(board.write16(0x220400, 0x0F0F));
    try testing.expectEqual(@as(?u16, 0x0F0F), board.read16(0x200004));
}

test "sub cpu runs a program from prg ram once released from reset" {
    var bios = [_]u8{0} ** 0x200;
    const board = try ScdBoard.create(testing.allocator, &bios, null, false);
    defer board.destroy();

    // Sub program: SSP=0x80000, PC=0x200; at 0x200: move.w #$1234,$FF8020 ; bra.s *
    writeBe32(&board.prg_ram, 0x0, 0x00080000);
    writeBe32(&board.prg_ram, 0x4, 0x00000200);
    writeBe16(&board.prg_ram, 0x200, 0x33FC);
    writeBe16(&board.prg_ram, 0x202, 0x1234);
    writeBe32(&board.prg_ram, 0x204, 0x00FF8020);
    writeBe16(&board.prg_ram, 0x208, 0x60FE);

    // Still in reset: credit is consumed without running anything.
    board.stepMaster(10_000);
    board.flush();
    try testing.expectEqual(@as(u64, 0), board.sub_instructions);
    try testing.expectEqual(@as(?u16, 0), board.read16(0xA12020));

    // Release reset through the main-side register.
    try testing.expect(board.write8(0xA12001, 0x01));
    try testing.expectEqual(@as(u32, 0x200), board.subProgramCounter());
    board.stepMaster(10_000); // ~2328 sub cycles
    board.flush();
    try testing.expect(board.sub_instructions > 10);
    try testing.expectEqual(@as(?u16, 0x1234), board.read16(0xA12020));

    // Bus request halts the sub CPU.
    const before = board.sub_instructions;
    try testing.expect(board.write8(0xA12001, 0x03));
    board.stepMaster(10_000);
    board.flush();
    try testing.expectEqual(before, board.sub_instructions);
    try testing.expectEqual(@as(u64, 0), board.sync.credit);
}

test "gate array access from main flushes pending sub credit first" {
    var bios = [_]u8{0} ** 0x200;
    const board = try ScdBoard.create(testing.allocator, &bios, null, false);
    defer board.destroy();
    writeBe32(&board.prg_ram, 0x0, 0x00080000);
    writeBe32(&board.prg_ram, 0x4, 0x00000200);
    // move.w $FF8010,d0 ; move.w d0,$FF8020 ; bra.s -12
    writeBe16(&board.prg_ram, 0x200, 0x3039);
    writeBe32(&board.prg_ram, 0x202, 0x00FF8010);
    writeBe16(&board.prg_ram, 0x206, 0x33C0);
    writeBe32(&board.prg_ram, 0x208, 0x00FF8020);
    writeBe16(&board.prg_ram, 0x20C, 0x60F2);
    _ = board.write8(0xA12001, 0x01);

    _ = board.write16(0xA12010, 0x4321);
    board.stepMaster(5_000);
    // Reading status flushes, so the echo is already visible.
    try testing.expectEqual(@as(?u16, 0x4321), board.read16(0xA12020));
    try testing.expectEqual(@as(u64, 0), board.sync.credit);
}

test "drive ticks at 75 Hz, raises INT4 under HOCK, and decodes data sectors into the CDC" {
    var bios = [_]u8{0} ** 0x200;
    var image: [4 * 2048]u8 = undefined;
    for (&image, 0..) |*b, i| b.* = @truncate(i * 5);
    @memcpy(image[0..14], "SEGADISCSYSTEM");
    const disc = try Disc.fromMemory(testing.allocator, null, &.{&image});
    const board = try ScdBoard.create(testing.allocator, &bios, disc, false);
    defer board.destroy();
    try testing.expect(backup_ram_mod.isFormatted(&board.backup_ram));
    try testing.expectEqual(@as(u8, 0x0), board.gate.cdd_status[0]); // stopped, disc present

    // Sub side (driven directly; the CPU stays in reset so requested
    // interrupts remain observable): enable INT4/INT5, HOCK on, CDC decoder
    // on, then PLAY 00:02:01.
    var bus = &board.sub_bus;
    bus.write8(0xFF8033, 0x30);
    bus.write8(0xFF8037, 0x04);
    bus.write8(0xFF8005, 0x01);
    bus.write8(0xFF8007, cdc_mod.Ifctrl.decien);
    bus.write8(0xFF8005, 0x0A);
    bus.write8(0xFF8007, cdc_mod.Ctrl0.decen | cdc_mod.Ctrl0.wrrq);
    var cmd = [_]u8{ 0x3, 0, 0, 0, 0, 2, 0, 1, 0, 0 };
    cmd[9] = cdd_mod.checksum(&cmd);
    var i: usize = 0;
    while (i < 10) : (i += 2) bus.write16(0xFF8042 + @as(u32, @intCast(i)), (@as(u16, cmd[i]) << 8) | cmd[i + 1]);
    board.flush();
    try testing.expectEqual(@as(u8, 0x2), board.gate.cdd_status[0]); // seeking

    // One sector period = 12.5M/75 = 166,666.67 sub cycles, about 715,909
    // master cycles; step a little past it so the tick lands.
    board.stepMaster(716_000);
    board.flush();
    try testing.expect(board.sub_cpu.isInterruptPending(4));
    try testing.expectEqual(@as(u8, 0x1), board.gate.cdd_status[0]); // playing
    board.sub_cpu.clearInterrupt();

    // Next tick delivers LBA 1 to the CDC: header 00:02:01, data at PT+4.
    board.stepMaster(716_000);
    board.flush();
    try testing.expect(board.sub_cpu.isInterruptPending(5));
    try testing.expectEqualSlices(u8, &.{ 0x00, 0x02, 0x01, 0x01 }, &board.cdc.head);
    const pt: u32 = board.cdc.pt;
    try testing.expectEqualSlices(u8, image[2048 .. 2048 + 16], board.cdc.ram[pt + 4 .. pt + 4 + 16]);

    // Main reads the block through the host port when DD = main.
    bus.write8(0xFF8005, 0x01);
    bus.write8(0xFF8007, cdc_mod.Ifctrl.douten);
    bus.write8(0xFF8005, 0x02);
    bus.write16(0xFF8006, 0x0003); // DBC = 3 -> 2 words
    bus.write8(0xFF8005, 0x04);
    bus.write16(0xFF8006, @intCast((pt + 4) & 0xFF));
    bus.write16(0xFF8006, @intCast((pt + 4) >> 8));
    bus.write8(0xFF8004, 0x02);
    bus.write8(0xFF8005, 0x06);
    bus.write8(0xFF8007, 0x00);
    try testing.expectEqual(@as(?u16, 0x4200), board.read16(0xA12004));
    const w0 = board.read16(0xA12008).?;
    const w1 = board.read16(0xA12008).?;
    try testing.expectEqual(@as(u16, (@as(u16, image[2048]) << 8) | image[2049]), w0);
    try testing.expectEqual(@as(u16, (@as(u16, image[2050]) << 8) | image[2051]), w1);
    try testing.expectEqual(@as(?u16, 0x8200), board.read16(0xA12004));

    // Reset returns the drive to stopped with the disc still present.
    board.reset();
    try testing.expectEqual(@as(u8, 0x0), board.gate.cdd_status[0]);
}

test "pcm and cd-da samples accumulate per window and are handed to the audio stage" {
    var bios = [_]u8{0} ** 0x200;
    const board = try ScdBoard.create(testing.allocator, &bios, null, false);
    defer board.destroy();

    // Program a PCM channel through the sub bus: constant positive sample.
    var bus = &board.sub_bus;
    bus.write8(0xFF000F, 0x80); // enabled, bank 0
    bus.write8(0xFF2001, 0xFE); // wave byte 0 = +126
    bus.write8(0xFF000F, 0xC0); // select channel 0
    bus.write8(0xFF0001, 0xFF);
    bus.write8(0xFF0003, 0xFF);
    bus.write8(0xFF0005, 0x00); // FD = 0: hold byte 0
    bus.write8(0xFF0007, 0x00);
    bus.write8(0xFF000D, 0x00);
    bus.write8(0xFF0011, 0xFE);

    // One NTSC frame of master cycles while held in reset: ~543 PCM samples.
    board.stepMaster(3420 * 262);
    board.flush();
    const ext = board.takeExpansionAudio();
    try testing.expect(ext.pcm.len >= 540 and ext.pcm.len <= 546);
    try testing.expectEqual(@as(i16, (126 * 255 * 15) >> 5), ext.pcm[10][0]);
    try testing.expectEqual(@as(usize, 0), ext.cdda.len);
    // Taking resets the ring.
    try testing.expectEqual(@as(usize, 0), board.takeExpansionAudio().pcm.len);
}

test "playing an audio track streams faded cd-da frames to the audio stage" {
    var bios = [_]u8{0} ** 0x200;
    const sheet =
        \\FILE "d.bin" BINARY
        \\  TRACK 01 MODE1/2048
        \\    INDEX 01 00:00:00
        \\FILE "a.bin" BINARY
        \\  TRACK 02 AUDIO
        \\    INDEX 01 00:00:00
    ;
    var data: [2 * 2048]u8 = undefined;
    @memset(&data, 0);
    var audio: [4 * 2352]u8 = undefined;
    for (&audio, 0..) |*b, i| b.* = if ((i & 1) == 0) 0x00 else 0x40; // LE 0x4000 every frame
    const disc = try Disc.fromMemory(testing.allocator, sheet, &.{ &data, &audio });
    const board = try ScdBoard.create(testing.allocator, &bios, disc, false);
    defer board.destroy();

    // Half volume fader, then PLAY from track 2 (LBA 2 -> 00:02:02).
    board.sub_bus.write16(0xFF8034, 0x2000); // fader = 0x200 of 0x3FF
    var cmd = [_]u8{ 0x3, 0, 0, 0, 0, 2, 0, 2, 0, 0 };
    cmd[9] = cdd_mod.checksum(&cmd);
    var i: usize = 0;
    while (i < 10) : (i += 2) board.sub_bus.write16(0xFF8042 + @as(u32, @intCast(i)), (@as(u16, cmd[i]) << 8) | cmd[i + 1]);

    // Seek tick + two playing ticks.
    board.stepMaster(3 * 716_000);
    board.flush();
    const ext = board.takeExpansionAudio();
    try testing.expectEqual(@as(usize, 2 * 588), ext.cdda.len);
    try testing.expectEqual(@as(i16, 0x4000 * 0x200 / 0x400), ext.cdda[0][0]);
    try testing.expectEqual(@as(i16, 0x4000 * 0x200 / 0x400), ext.cdda[1175][1]);
}
