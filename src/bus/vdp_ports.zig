const Vdp = @import("../video/vdp.zig").Vdp;
const cpu_runtime = @import("../cpu/runtime_state.zig");

fn splitWordByte(word: u16, address: u32) u8 {
    return if ((address & 1) == 0)
        @intCast((word >> 8) & 0xFF)
    else
        @intCast(word & 0xFF);
}

fn readOpenBusByte(open_bus: *const u16, address: u32) u8 {
    return splitWordByte(open_bus.*, address);
}

fn readStatus(vdp: *Vdp, open_bus: *u16, runtime: *const cpu_runtime.RuntimeState) u16 {
    const opcode = runtime.currentOpcode();
    // On real hardware, undefined VDP status bits (15:10) return the
    // instruction prefetch word, not the last value on the data bus.
    // Genesis Plus GX reads from m68k.pc for these bits.
    const status = vdp.readControlAdjusted(opcode) | (opcode & 0xFC00);
    open_bus.* = status;
    // readControlAdjusted() already cleared vint_pending/sprite flags in the VDP.
    // Recalculate the M68K IRQ level from remaining VDP sources instead of
    // unconditionally zeroing it.  On real hardware the VDP de-asserts its
    // interrupt output when vint_pending clears; it does NOT reach into the
    // CPU and cancel an already-latched interrupt.  The old clearInterrupt()
    // call would zero irq_level even if the CPU hadn't serviced a pending
    // VBlank yet, causing games that poll VDP status in a loop (like SoR's
    // GEMS driver) to lose interrupts.
    runtime.updateInterruptLevel(vdp.currentInterruptLevel());
    return status;
}

fn readHVCounter(vdp: *Vdp, open_bus: *u16, runtime: *const cpu_runtime.RuntimeState) u16 {
    const opcode = runtime.currentOpcode();
    const word = vdp.readHVCounterAdjusted(opcode);
    open_bus.* = word;
    return word;
}

pub fn readByte(vdp: *Vdp, open_bus: *u16, runtime: *const cpu_runtime.RuntimeState, address: u32) u8 {
    const port = address & 0x1F;
    switch (port) {
        0x00, 0x01, 0x02, 0x03 => {
            const word = vdp.readData();
            open_bus.* = word;
            return splitWordByte(word, address);
        },
        0x04, 0x05, 0x06, 0x07 => return splitWordByte(readStatus(vdp, open_bus, runtime), address),
        // HVC counter mirrors: GPGX masks with (address & 0xFD) so 0x0A/0x0B
        // map to 0x08/0x09 and 0x0E/0x0F map to 0x0C/0x0D.
        0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F => return splitWordByte(readHVCounter(vdp, open_bus, runtime), address),
        // Unused ports return instruction prefetch (open bus), matching GPGX.
        0x18, 0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F => return splitWordByte(runtime.currentOpcode(), address),
        // PSG / test register / invalid ports (0x10-0x17): on real hardware
        // these cause a lockup (no /DTACK). Return prefetch as a safe fallback.
        else => return splitWordByte(runtime.currentOpcode(), address),
    }
}

pub fn readWord(vdp: *Vdp, open_bus: *u16, runtime: *const cpu_runtime.RuntimeState, address: u32) u16 {
    const port = address & 0x1F;
    switch (port & 0x1E) {
        0x00, 0x02 => {
            const word = vdp.readData();
            open_bus.* = word;
            return word;
        },
        0x04, 0x06 => return readStatus(vdp, open_bus, runtime),
        0x08, 0x0A, 0x0C, 0x0E => return readHVCounter(vdp, open_bus, runtime),
        0x18, 0x1A, 0x1C, 0x1E => return runtime.currentOpcode(),
        else => {
            open_bus.* = 0xFFFF;
            return 0xFFFF;
        },
    }
}

pub fn writeByte(vdp: *Vdp, address: u32, value: u8) void {
    const port = address & 0x1F;
    const word: u16 = (@as(u16, value) << 8) | value;

    if (port < 0x04) {
        vdp.writeData(word);
    } else if (port < 0x08) {
        vdp.writeControl(word);
    }
}

pub fn writeWord(vdp: *Vdp, address: u32, value: u16) void {
    const port = address & 0x1F;
    if (port < 0x04) {
        vdp.writeData(value);
    } else if (port < 0x08) {
        vdp.writeControl(value);
    }
}

pub fn writeLong(vdp: *Vdp, address: u32, value: u32) void {
    writeWord(vdp, address, @intCast((value >> 16) & 0xFFFF));
    writeWord(vdp, address + 2, @intCast(value & 0xFFFF));
}
