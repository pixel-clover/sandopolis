const Io = @import("../input/io.zig").Io;

pub fn readVersionRegister(io: *const Io, pal_mode: bool) u8 {
    _ = io;
    var value: u8 = 0x20 | 0x80;
    if (pal_mode) value |= 0x40;
    return value;
}

pub fn readRegisterByte(io: *Io, pal_mode: bool, address: u32) u8 {
    return switch (address & 0x1F) {
        0x00, 0x01 => readVersionRegister(io, pal_mode),
        0x02, 0x03 => io.read(0x03),
        0x04, 0x05 => io.read(0x05),
        0x06, 0x07 => io.read(0x07),
        0x08, 0x09 => io.read(0x09),
        0x0A, 0x0B => io.read(0x0B),
        0x0C, 0x0D => io.read(0x0D),
        0x0E, 0x0F, 0x14, 0x15, 0x1A, 0x1B => 0xFF,
        else => 0x00,
    };
}

pub fn writeRegisterByte(io: *Io, address: u32, value: u8) void {
    switch (address & 0x1F) {
        0x02, 0x03 => io.write(0x03, value),
        0x04, 0x05 => io.write(0x05, value),
        0x06, 0x07 => io.write(0x07, value),
        0x08, 0x09 => io.write(0x09, value),
        0x0A, 0x0B => io.write(0x0B, value),
        0x0C, 0x0D => io.write(0x0D, value),
        else => {},
    }
}
