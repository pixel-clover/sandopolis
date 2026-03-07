const Vdp = @import("../video/vdp.zig").Vdp;
const cpu_runtime = @import("../cpu/runtime_state.zig");

fn splitWordByte(word: u16, address: u32) u8 {
    return if ((address & 1) == 0)
        @intCast((word >> 8) & 0xFF)
    else
        @intCast(word & 0xFF);
}

fn readStatus(vdp: *Vdp, open_bus: *u16) u16 {
    const opcode = cpu_runtime.currentOpcode();
    const status = vdp.readControlAdjusted(opcode) | (open_bus.* & 0xFC00);
    open_bus.* = status;
    cpu_runtime.clearInterrupt();
    return status;
}

fn readHVCounter(vdp: *Vdp, open_bus: *u16) u16 {
    const opcode = cpu_runtime.currentOpcode();
    const word = vdp.readHVCounterAdjusted(opcode);
    open_bus.* = word;
    return word;
}

pub fn readByte(vdp: *Vdp, open_bus: *u16, address: u32) u8 {
    const port = address & 0x1F;
    if (port < 0x04) {
        const word = vdp.readData();
        open_bus.* = word;
        return splitWordByte(word, address);
    }
    if (port < 0x08) return splitWordByte(readStatus(vdp, open_bus), address);
    if (port < 0x10) return splitWordByte(readHVCounter(vdp, open_bus), address);
    return 0xFF;
}

pub fn readWord(vdp: *Vdp, open_bus: *u16, address: u32) u16 {
    const port = address & 0x1F;
    if (port < 0x04) {
        const word = vdp.readData();
        open_bus.* = word;
        return word;
    }
    if (port < 0x08) return readStatus(vdp, open_bus);
    if (port < 0x10) return readHVCounter(vdp, open_bus);
    open_bus.* = 0xFFFF;
    return 0xFFFF;
}

pub fn writeByte(vdp: *Vdp, address: u32, value: u8) void {
    const port = address & 0x1F;
    const word: u16 = if ((address & 1) == 0)
        (@as(u16, value) << 8)
    else
        @as(u16, value);

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
