const std = @import("std");
const Io = @import("../input/io.zig").Io;

pub fn readVersionRegister(io: *const Io, pal_mode: bool) u8 {
    return io.readVersionRegister(pal_mode);
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
        0x0E, 0x0F => io.readTxData(0),
        0x10, 0x11 => io.readRxData(0),
        0x12, 0x13 => io.readSerialControl(0),
        0x14, 0x15 => io.readTxData(1),
        0x16, 0x17 => io.readRxData(1),
        0x18, 0x19 => io.readSerialControl(1),
        0x1A, 0x1B => io.readTxData(2),
        0x1C, 0x1D => io.readRxData(2),
        0x1E, 0x1F => io.readSerialControl(2),
        else => unreachable,
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
        0x0E, 0x0F => io.writeTxData(0, value),
        0x12, 0x13 => io.writeSerialControl(0, value),
        0x14, 0x15 => io.writeTxData(1, value),
        0x18, 0x19 => io.writeSerialControl(1, value),
        0x1A, 0x1B => io.writeTxData(2, value),
        0x1E, 0x1F => io.writeSerialControl(2, value),
        else => {},
    }
}

test "io window ignores writes to unsupported io bytes" {
    var io = Io.init();

    const before_data_2 = io.read(0x07);
    const before_tx_0 = io.readTxData(0);
    const before_tx_1 = io.readTxData(1);
    const before_tx_2 = io.readTxData(2);
    const before_serial_0 = io.readSerialControl(0);
    const before_serial_1 = io.readSerialControl(1);
    const before_serial_2 = io.readSerialControl(2);

    for ([_]u32{ 0x00, 0x01, 0x10, 0x11, 0x16, 0x17, 0x1C, 0x1D }) |address| {
        writeRegisterByte(&io, address, 0xA5);
    }

    try std.testing.expectEqual(before_data_2, io.read(0x07));
    try std.testing.expectEqual(before_tx_0, io.readTxData(0));
    try std.testing.expectEqual(before_tx_1, io.readTxData(1));
    try std.testing.expectEqual(before_tx_2, io.readTxData(2));
    try std.testing.expectEqual(before_serial_0, io.readSerialControl(0));
    try std.testing.expectEqual(before_serial_1, io.readSerialControl(1));
    try std.testing.expectEqual(before_serial_2, io.readSerialControl(2));
}
