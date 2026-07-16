const std = @import("std");

pub const I2cState = enum {
    stand_by,
    wait_stop,
    get_device_adr,
    get_word_adr_7bits,
    get_word_adr_high,
    get_word_adr_low,
    write_data,
    read_data,
};

pub const I2cSpec = struct {
    address_bits: u8,
    size_mask: u16,
    pagewrite_mask: u16,
};

pub const i2c_specs = [_]I2cSpec{
    .{ .address_bits = 7, .size_mask = 0x7F, .pagewrite_mask = 0x03 }, // 0: X24C01
    .{ .address_bits = 8, .size_mask = 0xFF, .pagewrite_mask = 0x03 }, // 1: X24C02
    .{ .address_bits = 8, .size_mask = 0x7F, .pagewrite_mask = 0x07 }, // 2: 24C01
    .{ .address_bits = 8, .size_mask = 0xFF, .pagewrite_mask = 0x07 }, // 3: 24C02
    .{ .address_bits = 8, .size_mask = 0x1FF, .pagewrite_mask = 0x0F }, // 4: 24C04
    .{ .address_bits = 8, .size_mask = 0x3FF, .pagewrite_mask = 0x0F }, // 5: 24C08
    .{ .address_bits = 8, .size_mask = 0x7FF, .pagewrite_mask = 0x0F }, // 6: 24C16
    .{ .address_bits = 16, .size_mask = 0xFFF, .pagewrite_mask = 0x1F }, // 7: 24C32
    .{ .address_bits = 16, .size_mask = 0x1FFF, .pagewrite_mask = 0x1F }, // 8: 24C64
    .{ .address_bits = 16, .size_mask = 0x1FFF, .pagewrite_mask = 0x3F }, // 9: 24C65
    .{ .address_bits = 16, .size_mask = 0x3FFF, .pagewrite_mask = 0x3F }, // 10: 24C128
    .{ .address_bits = 16, .size_mask = 0x7FFF, .pagewrite_mask = 0x3F }, // 11: 24C256
    .{ .address_bits = 16, .size_mask = 0xFFFF, .pagewrite_mask = 0x7F }, // 12: 24C512
};

pub const WiringConfig = enum {
    sega,
    ea,
    acclaim_16m,
    acclaim_32m,
    codemasters,
};

fn wiringBits(config: WiringConfig) struct { scl_in: u3, sda_in: u3, sda_out: u3 } {
    return switch (config) {
        .sega => .{ .scl_in = 1, .sda_in = 0, .sda_out = 0 },
        .ea => .{ .scl_in = 6, .sda_in = 7, .sda_out = 7 },
        .acclaim_16m => .{ .scl_in = 1, .sda_in = 0, .sda_out = 1 },
        .acclaim_32m => .{ .scl_in = 0, .sda_in = 0, .sda_out = 0 },
        .codemasters => .{ .scl_in = 1, .sda_in = 0, .sda_out = 7 },
    };
}

pub const EepromI2c = struct {
    // I2C line state
    sda: u1 = 0,
    scl: u1 = 0,
    old_sda: u1 = 0,
    old_scl: u1 = 0,

    // Protocol state
    cycles: u4 = 0,
    rw: u1 = 0,
    device_address: u16 = 0,
    word_address: u16 = 0,
    buffer: u8 = 0,
    state: I2cState = .stand_by,

    // Config
    spec: I2cSpec,
    wiring: WiringConfig,
    scl_in_bit: u3,
    sda_in_bit: u3,
    sda_out_bit: u3,

    // Storage
    data: []u8,
    dirty: bool = false,

    // Acclaim 32M boards (LZ95A53 PAL): word writes to the control window
    // bank-shift $200000-$2FFFFF reads between cartridge ROM (bit 0 set)
    // and the serial EEPROM (bit 0 clear).  Power-on state exposes ROM.
    rom_readable: bool = true,

    pub fn init(
        spec_index: usize,
        wiring: WiringConfig,
        data: []u8,
    ) EepromI2c {
        const spec = i2c_specs[spec_index];
        const bits = wiringBits(wiring);
        return .{
            .spec = spec,
            .wiring = wiring,
            .scl_in_bit = bits.scl_in,
            .sda_in_bit = bits.sda_in,
            .sda_out_bit = bits.sda_out,
            .data = data,
        };
    }

    /// Address window the EEPROM answers READS in, per board wiring
    /// (matches the Genesis Plus GX memory maps).
    fn inReadWindow(self: *const EepromI2c, address: u32) bool {
        return switch (self.wiring) {
            .sega, .ea, .acclaim_16m => address >= 0x20_0000 and address <= 0x3F_FFFF,
            // Bank-shifted: ROM is exposed until the PAL selects the EEPROM.
            .acclaim_32m => !self.rom_readable and address >= 0x20_0000 and address <= 0x2F_FFFF,
            .codemasters => address >= 0x38_0000 and address <= 0x3F_FFFF,
        };
    }

    /// Address window the EEPROM (or its control PAL) claims WRITES in.
    fn inWriteWindow(self: *const EepromI2c, address: u32) bool {
        return switch (self.wiring) {
            .sega, .ea, .acclaim_16m => address >= 0x20_0000 and address <= 0x3F_FFFF,
            .acclaim_32m => address >= 0x20_0000 and address <= 0x2F_FFFF,
            .codemasters => address >= 0x30_0000 and address <= 0x37_FFFF,
        };
    }

    fn latchLines(self: *EepromI2c, value: u8) void {
        self.old_sda = self.sda;
        self.old_scl = self.scl;
        self.sda = @truncate((value >> self.sda_in_bit) & 1);
        self.scl = @truncate((value >> self.scl_in_bit) & 1);
        self.update();
    }

    fn detectStart(self: *EepromI2c) void {
        // START condition: SDA goes HIGH->LOW while SCL is HIGH
        if (self.old_scl == 1 and self.scl == 1) {
            if (self.old_sda == 1 and self.sda == 0) {
                self.cycles = 0;
                if (self.spec.address_bits == 7) {
                    self.word_address = 0;
                    self.state = .get_word_adr_7bits;
                } else {
                    // Keep word_address: a repeated START after setting the
                    // word address is the standard I2C random-read sequence.
                    self.device_address = 0;
                    self.state = .get_device_adr;
                }
            }
        }
    }

    fn detectStop(self: *EepromI2c) void {
        // STOP condition: SDA goes LOW->HIGH while SCL is HIGH
        if (self.old_scl == 1 and self.scl == 1) {
            if (self.old_sda == 0 and self.sda == 1) {
                self.state = .stand_by;
            }
        }
    }

    fn effectiveAddress(self: *const EepromI2c) u16 {
        return (self.device_address | self.word_address) & self.spec.size_mask;
    }

    pub fn update(self: *EepromI2c) void {
        switch (self.state) {
            .stand_by => {
                self.detectStart();
            },
            .wait_stop => {
                self.detectStop();
            },
            .get_device_adr => {
                self.detectStart();
                self.detectStop();
                // Falling edge of SCL
                if (self.old_scl == 1 and self.scl == 0) {
                    if (self.cycles == 9) {
                        self.cycles = 1;
                        // Shift device address according to spec. Widen to u32:
                        // address_bits is 16 for the larger parts, where the
                        // device bits shift entirely out of the word address.
                        self.device_address = @truncate(@as(u32, self.device_address) << @intCast(self.spec.address_bits));
                        if (self.rw == 1) {
                            self.state = .read_data;
                        } else {
                            // A write transaction supplies a fresh word
                            // address; a read (rw==1) keeps the current one.
                            self.word_address = 0;
                            if (self.spec.address_bits == 16) {
                                self.state = .get_word_adr_high;
                            } else {
                                self.state = .get_word_adr_low;
                            }
                        }
                    } else {
                        self.cycles += 1;
                    }
                }
                // Rising edge of SCL - latch data
                if (self.old_scl == 0 and self.scl == 1) {
                    if (self.cycles < 9) {
                        if (self.cycles >= 5 and self.cycles <= 7) {
                            // Device address bits (3 MSBs of device address, bits 2-0)
                            self.device_address |= @as(u16, self.sda) << @intCast(7 - self.cycles);
                        } else if (self.cycles == 8) {
                            self.rw = self.sda;
                        }
                    }
                }
            },
            .get_word_adr_7bits => {
                self.detectStart();
                self.detectStop();
                // Falling edge of SCL
                if (self.old_scl == 1 and self.scl == 0) {
                    if (self.cycles == 9) {
                        self.cycles = 1;
                        if (self.rw == 1) {
                            self.state = .read_data;
                        } else {
                            self.state = .write_data;
                            self.buffer = 0;
                        }
                    } else {
                        self.cycles += 1;
                    }
                }
                // Rising edge of SCL - latch data
                if (self.old_scl == 0 and self.scl == 1) {
                    if (self.cycles < 9) {
                        if (self.cycles >= 1 and self.cycles <= 7) {
                            // Word address bits 6-0
                            self.word_address |= @as(u16, self.sda) << @intCast(7 - self.cycles);
                        } else if (self.cycles == 8) {
                            self.rw = self.sda;
                        }
                    }
                }
            },
            .get_word_adr_high => {
                self.detectStart();
                self.detectStop();
                // Falling edge of SCL
                if (self.old_scl == 1 and self.scl == 0) {
                    if (self.cycles == 9) {
                        self.cycles = 1;
                        self.state = .get_word_adr_low;
                    } else {
                        self.cycles += 1;
                    }
                }
                // Rising edge of SCL - latch high address byte
                if (self.old_scl == 0 and self.scl == 1) {
                    if (self.cycles >= 1 and self.cycles <= 8) {
                        const bit_pos: u4 = @intCast(16 - @as(u5, self.cycles));
                        if (self.spec.size_mask < (@as(u16, 1) << bit_pos)) {
                            // Address bit above size - shift device address down
                            self.device_address = (self.device_address >> 1) | (@as(u16, self.sda) << @intCast(self.spec.address_bits - 1));
                        } else {
                            self.word_address |= @as(u16, self.sda) << bit_pos;
                        }
                    }
                }
            },
            .get_word_adr_low => {
                self.detectStart();
                self.detectStop();
                // Falling edge of SCL
                if (self.old_scl == 1 and self.scl == 0) {
                    if (self.cycles == 9) {
                        self.cycles = 1;
                        self.state = .write_data;
                        self.buffer = 0;
                    } else {
                        self.cycles += 1;
                    }
                }
                // Rising edge of SCL - latch low address byte
                if (self.old_scl == 0 and self.scl == 1) {
                    if (self.cycles >= 1 and self.cycles <= 8) {
                        const bit_pos: u4 = @intCast(8 - @as(u5, self.cycles));
                        if (self.spec.size_mask < (@as(u16, 1) << bit_pos)) {
                            self.device_address = (self.device_address >> 1) | (@as(u16, self.sda) << @intCast(self.spec.address_bits - 1));
                        } else {
                            self.word_address |= @as(u16, self.sda) << bit_pos;
                        }
                    }
                }
            },
            .read_data => {
                self.detectStart();
                self.detectStop();
                // Falling edge of SCL
                if (self.old_scl == 1 and self.scl == 0) {
                    if (self.cycles == 9) {
                        self.cycles = 1;
                    } else {
                        self.cycles += 1;
                    }
                }
                // Rising edge of SCL
                if (self.old_scl == 0 and self.scl == 1) {
                    if (self.cycles == 9) {
                        if (self.sda == 1) {
                            // NAK - end of read
                            self.state = .wait_stop;
                        } else {
                            // ACK - advance to next byte
                            self.word_address = (self.word_address & ~self.spec.size_mask) |
                                ((self.word_address +% 1) & self.spec.size_mask);
                        }
                    }
                }
            },
            .write_data => {
                self.detectStart();
                self.detectStop();
                // Falling edge of SCL
                if (self.old_scl == 1 and self.scl == 0) {
                    if (self.cycles == 9) {
                        self.cycles = 1;
                    } else {
                        self.cycles += 1;
                    }
                }
                // Rising edge of SCL
                if (self.old_scl == 0 and self.scl == 1) {
                    if (self.cycles >= 1 and self.cycles <= 8) {
                        // Latch data bit
                        self.buffer |= @as(u8, self.sda) << @intCast(8 - @as(u4, self.cycles));
                    } else if (self.cycles == 9) {
                        // Write byte to storage
                        const addr = self.effectiveAddress();
                        if (addr < self.data.len) {
                            self.data[addr] = self.buffer;
                            self.dirty = true;
                        }
                        self.buffer = 0;
                        // Advance word address within page boundary
                        self.word_address = (self.word_address & ~self.spec.pagewrite_mask) |
                            ((self.word_address +% 1) & self.spec.pagewrite_mask);
                    }
                }
            },
        }
    }

    pub fn output(self: *const EepromI2c) u1 {
        if (self.state == .read_data and self.cycles < 9) {
            // Output bit from memory
            const addr = self.effectiveAddress();
            if (addr < self.data.len) {
                return @truncate((self.data[addr] >> @intCast(8 - @as(u4, self.cycles))) & 1);
            }
            return 1;
        } else if (self.cycles == 9) {
            // ACK - pull SDA low
            return 0;
        } else {
            return self.sda;
        }
    }

    pub fn readByte(self: *const EepromI2c, address: u32) ?u8 {
        if (!self.inReadWindow(address)) return null;
        // The EEPROM drives D0-D7, i.e. the odd byte lane; even byte reads
        // are open bus (null lets the caller's open-bus handling apply).
        if ((address & 1) != 0) {
            return @as(u8, self.output()) << self.sda_out_bit;
        }
        return null;
    }

    pub fn readWord(self: *const EepromI2c, address: u32) ?u16 {
        if (!self.inReadWindow(address)) return null;
        // SDA appears on D0-D7, the low byte of a word read.
        return @as(u16, self.output()) << self.sda_out_bit;
    }

    pub fn writeByte(self: *EepromI2c, address: u32, value: u8) bool {
        if (!self.inWriteWindow(address)) return false;
        switch (self.wiring) {
            // Only /LWR (odd byte lane) reaches the EEPROM; even byte
            // writes are consumed but ignored.
            .sega, .ea => if ((address & 1) != 0) self.latchLines(value),
            // /LWR & /UWR unused: any byte write latches both lines.
            .acclaim_16m, .codemasters => self.latchLines(value),
            // LZ95A53 PAL: D0 routes to SDA on odd writes, SCL on even.
            .acclaim_32m => {
                self.old_sda = self.sda;
                self.old_scl = self.scl;
                if ((address & 1) != 0) {
                    self.sda = @truncate(value & 1);
                } else {
                    self.scl = @truncate(value & 1);
                }
                self.update();
            },
        }
        return true;
    }

    pub fn writeWord(self: *EepromI2c, address: u32, value: u16) bool {
        if (!self.inWriteWindow(address)) return false;
        switch (self.wiring) {
            // The lines sit on D0-D7, so a word write drives them from the
            // LOW byte of the value.
            .sega, .ea, .acclaim_16m, .codemasters => self.latchLines(@truncate(value)),
            // Word writes (both strobes) hit the PAL bank-shift register.
            .acclaim_32m => self.rom_readable = (value & 1) != 0,
        }
        return true;
    }

    /// The mutable I2C protocol state, for save states.  Configuration
    /// (spec, wiring, address window) is rebuilt from the ROM; the storage
    /// bytes travel separately.
    pub const ProtocolState = struct {
        sda: u1 = 0,
        scl: u1 = 0,
        old_sda: u1 = 0,
        old_scl: u1 = 0,
        cycles: u4 = 0,
        rw: u1 = 0,
        device_address: u16 = 0,
        word_address: u16 = 0,
        buffer: u8 = 0,
        state: I2cState = .stand_by,
        dirty: bool = false,
        rom_readable: bool = true,
    };

    pub fn captureProtocolState(self: *const EepromI2c) ProtocolState {
        return .{
            .sda = self.sda,
            .scl = self.scl,
            .old_sda = self.old_sda,
            .old_scl = self.old_scl,
            .cycles = self.cycles,
            .rw = self.rw,
            .device_address = self.device_address,
            .word_address = self.word_address,
            .buffer = self.buffer,
            .state = self.state,
            .dirty = self.dirty,
            .rom_readable = self.rom_readable,
        };
    }

    pub fn restoreProtocolState(self: *EepromI2c, state: ProtocolState) void {
        self.sda = state.sda;
        self.scl = state.scl;
        self.old_sda = state.old_sda;
        self.old_scl = state.old_scl;
        self.cycles = state.cycles;
        self.rw = state.rw;
        self.device_address = state.device_address;
        self.word_address = state.word_address;
        self.buffer = state.buffer;
        self.state = state.state;
        self.dirty = state.dirty;
        self.rom_readable = state.rom_readable;
    }

    pub fn resetState(self: *EepromI2c) void {
        self.sda = 0;
        self.scl = 0;
        self.old_sda = 0;
        self.old_scl = 0;
        self.cycles = 0;
        self.rw = 0;
        self.device_address = 0;
        self.word_address = 0;
        self.buffer = 0;
        self.state = .stand_by;
        self.rom_readable = true;
    }
};

const GameEntry = struct {
    id: []const u8,
    eeprom_type: usize,
    wiring: WiringConfig,
};

const game_database = [_]GameEntry{
    // EA Games
    .{ .id = "T-50176", .eeprom_type = 0, .wiring = .ea }, // Rings of Power
    .{ .id = "T-50396", .eeprom_type = 0, .wiring = .ea }, // NHLPA Hockey 93
    .{ .id = "T-50446", .eeprom_type = 0, .wiring = .ea }, // John Madden Football 93
    .{ .id = "T-50516", .eeprom_type = 0, .wiring = .ea }, // John Madden Football 93 Championship
    .{ .id = "T-50606", .eeprom_type = 0, .wiring = .ea }, // Bill Walsh College Football

    // SEGA Games
    .{ .id = "T-12046", .eeprom_type = 0, .wiring = .sega }, // Megaman - The Wily Wars
    .{ .id = "T-12053", .eeprom_type = 0, .wiring = .sega }, // Rockman Mega World
    .{ .id = "MK-1215", .eeprom_type = 0, .wiring = .sega }, // Evander Holyfield's Boxing
    .{ .id = "MK-1228", .eeprom_type = 0, .wiring = .sega }, // Greatest Heavyweights
    .{ .id = "G-5538 ", .eeprom_type = 0, .wiring = .sega }, // Greatest Heavyweights (J)
    .{ .id = "G-4060 ", .eeprom_type = 0, .wiring = .sega }, // Wonderboy in Monster World
    .{ .id = "00001211", .eeprom_type = 0, .wiring = .sega }, // Sports Talk Baseball
    .{ .id = "G-4524 ", .eeprom_type = 0, .wiring = .sega }, // Ninja Burai Densetsu

    // Acclaim 16M Games
    .{ .id = "T-81033", .eeprom_type = 1, .wiring = .acclaim_16m }, // NBA Jam (J)
    .{ .id = "T-081326", .eeprom_type = 1, .wiring = .acclaim_16m }, // NBA Jam (UE)

    // Acclaim 32M Games
    .{ .id = "T-081276", .eeprom_type = 3, .wiring = .acclaim_32m }, // NFL Quarterback Club
    .{ .id = "T-81406", .eeprom_type = 4, .wiring = .acclaim_32m }, // NBA Jam TE
    .{ .id = "T-081586", .eeprom_type = 6, .wiring = .acclaim_32m }, // NFL Quarterback Club '96
    .{ .id = "T-81476", .eeprom_type = 9, .wiring = .acclaim_32m }, // Frank Thomas Big Hurt
    .{ .id = "T-81576", .eeprom_type = 9, .wiring = .acclaim_32m }, // College Slam

    // Codemasters
    .{ .id = "T-120106", .eeprom_type = 5, .wiring = .codemasters }, // Brian Lara Cricket
    .{ .id = "T-120096", .eeprom_type = 6, .wiring = .codemasters }, // Micro Machines 2
    .{ .id = "T-120146", .eeprom_type = 9, .wiring = .codemasters }, // Brian Lara Cricket 96
};

pub const DetectResult = struct {
    eeprom_type: usize,
    wiring: WiringConfig,
};

pub fn detect(rom: []const u8) ?DetectResult {
    if (rom.len < 0x18B) return null;

    // Extract product code from ROM header (0x183..0x18B)
    const product_code = rom[0x183..0x18B];

    for (game_database) |entry| {
        if (entry.id.len <= product_code.len) {
            if (std.mem.startsWith(u8, product_code, entry.id)) {
                return .{
                    .eeprom_type = entry.eeprom_type,
                    .wiring = entry.wiring,
                };
            }
        }
    }

    return null;
}

pub fn storageSize(spec_index: usize) usize {
    return @as(usize, i2c_specs[spec_index].size_mask) + 1;
}

// ---- Tests ----

fn makeTestEeprom(spec_index: usize, wiring: WiringConfig, data: []u8) EepromI2c {
    return EepromI2c.init(spec_index, wiring, data);
}

fn sendStart(eeprom: *EepromI2c, wiring: WiringConfig) void {
    const bits = wiringBits(wiring);
    // SDA=1, SCL=1
    var val: u8 = (@as(u8, 1) << bits.sda_in) | (@as(u8, 1) << bits.scl_in);
    _ = eeprom.writeByte(0x200001, val);
    // SDA=0, SCL=1 (START condition: SDA falls while SCL is high)
    val = (@as(u8, 0) << bits.sda_in) | (@as(u8, 1) << bits.scl_in);
    _ = eeprom.writeByte(0x200001, val);
}

fn sendStop(eeprom: *EepromI2c, wiring: WiringConfig) void {
    const bits = wiringBits(wiring);
    // SDA=0, SCL=0 (ensure SDA is low and SCL is low first)
    var val: u8 = (@as(u8, 0) << bits.sda_in) | (@as(u8, 0) << bits.scl_in);
    _ = eeprom.writeByte(0x200001, val);
    // SDA=0, SCL=1 (raise clock)
    val = (@as(u8, 0) << bits.sda_in) | (@as(u8, 1) << bits.scl_in);
    _ = eeprom.writeByte(0x200001, val);
    // SDA=1, SCL=1 (STOP condition: SDA rises while SCL is high)
    val = (@as(u8, 1) << bits.sda_in) | (@as(u8, 1) << bits.scl_in);
    _ = eeprom.writeByte(0x200001, val);
}

fn sendBit(eeprom: *EepromI2c, wiring: WiringConfig, bit: u1) void {
    const bits = wiringBits(wiring);
    // SCL=0, set SDA (setup phase - falling edge from previous SCL=1)
    var val: u8 = (@as(u8, bit) << bits.sda_in) | (@as(u8, 0) << bits.scl_in);
    _ = eeprom.writeByte(0x200001, val);
    // SCL=1 (rising edge - data latched)
    val = (@as(u8, bit) << bits.sda_in) | (@as(u8, 1) << bits.scl_in);
    _ = eeprom.writeByte(0x200001, val);
}

fn sendByte7bitMode(eeprom: *EepromI2c, wiring: WiringConfig, addr: u7, rw: u1) void {
    // Send 7-bit address + RW bit (MSB first for address, then RW)
    var i: u3 = 7;
    while (i > 0) {
        i -= 1;
        sendBit(eeprom, wiring, @truncate((addr >> i) & 1));
    }
    sendBit(eeprom, wiring, rw);
    // ACK cycle
    sendBit(eeprom, wiring, 0);
}

fn sendDataByte(eeprom: *EepromI2c, wiring: WiringConfig, data: u8) void {
    var i: u4 = 8;
    while (i > 0) {
        i -= 1;
        sendBit(eeprom, wiring, @truncate((data >> @intCast(i)) & 1));
    }
    // ACK cycle
    sendBit(eeprom, wiring, 0);
}

fn readDataByte(eeprom: *EepromI2c, wiring: WiringConfig, ack: bool) u8 {
    var result: u8 = 0;
    var i: u4 = 8;
    const bits = wiringBits(wiring);
    while (i > 0) {
        i -= 1;
        // SCL=0 (falling edge from previous SCL=1)
        _ = eeprom.writeByte(0x200001, @as(u8, 0) << bits.scl_in);
        // SCL=1 (rising edge - output becomes valid)
        _ = eeprom.writeByte(0x200001, @as(u8, 1) << bits.scl_in);
        // Read SDA output
        const out = eeprom.output();
        result |= @as(u8, out) << @intCast(i);
    }
    // ACK/NAK cycle
    sendBit(eeprom, wiring, if (ack) 0 else 1);
    return result;
}

test "i2c eeprom start and stop detection transitions state" {
    var data = [_]u8{0} ** 128;
    var eeprom = makeTestEeprom(0, .sega, &data); // X24C01, 7-bit mode

    try std.testing.expectEqual(I2cState.stand_by, eeprom.state);

    sendStart(&eeprom, .sega);
    try std.testing.expectEqual(I2cState.get_word_adr_7bits, eeprom.state);

    sendStop(&eeprom, .sega);
    try std.testing.expectEqual(I2cState.stand_by, eeprom.state);
}

test "i2c eeprom 7-bit mode write and read cycle" {
    var data = [_]u8{0} ** 128;
    var eeprom = makeTestEeprom(0, .sega, &data); // X24C01

    // Write 0xA5 to address 0x10
    sendStart(&eeprom, .sega);
    sendByte7bitMode(&eeprom, .sega, 0x10, 0); // addr=0x10, write
    sendDataByte(&eeprom, .sega, 0xA5);
    sendStop(&eeprom, .sega);

    try std.testing.expectEqual(@as(u8, 0xA5), data[0x10]);

    // Read back from address 0x10
    sendStart(&eeprom, .sega);
    sendByte7bitMode(&eeprom, .sega, 0x10, 1); // addr=0x10, read
    const result = readDataByte(&eeprom, .sega, false); // NAK to end read
    sendStop(&eeprom, .sega);

    try std.testing.expectEqual(@as(u8, 0xA5), result);
}

test "i2c eeprom page write wraps within page boundary" {
    var data = [_]u8{0} ** 128;
    var eeprom = makeTestEeprom(0, .sega, &data); // X24C01, pagewrite_mask=0x03

    // Write starting at address 0x02 (within page 0x00-0x03)
    sendStart(&eeprom, .sega);
    sendByte7bitMode(&eeprom, .sega, 0x02, 0); // addr=0x02, write
    sendDataByte(&eeprom, .sega, 0x11); // -> addr 0x02
    sendDataByte(&eeprom, .sega, 0x22); // -> addr 0x03
    sendDataByte(&eeprom, .sega, 0x33); // -> wraps to addr 0x00
    sendStop(&eeprom, .sega);

    try std.testing.expectEqual(@as(u8, 0x33), data[0x00]); // wrapped
    try std.testing.expectEqual(@as(u8, 0x00), data[0x01]); // untouched
    try std.testing.expectEqual(@as(u8, 0x11), data[0x02]);
    try std.testing.expectEqual(@as(u8, 0x22), data[0x03]);
}

test "i2c eeprom 8-bit mode device address and word address" {
    var data = [_]u8{0} ** 256;
    var eeprom = makeTestEeprom(1, .sega, &data); // X24C02, 8-bit mode

    // Write 0xBE to address 0x42
    sendStart(&eeprom, .sega);
    try std.testing.expectEqual(I2cState.get_device_adr, eeprom.state);

    // Send device address byte: 7-bit device addr (0b1010000) + W bit (0)
    sendDataByte(&eeprom, .sega, 0xA0); // device addr=0b1010000, W=0
    // Note: transition happens lazily on the first falling edge of the next phase

    // Send word address
    sendDataByte(&eeprom, .sega, 0x42);

    // Send data
    sendDataByte(&eeprom, .sega, 0xBE);
    sendStop(&eeprom, .sega);

    try std.testing.expectEqual(@as(u8, 0xBE), data[0x42]);
}

test "i2c eeprom address out of range returns null" {
    var data = [_]u8{0} ** 128;
    var eeprom = makeTestEeprom(0, .sega, &data);

    try std.testing.expectEqual(@as(?u8, null), eeprom.readByte(0x100000));
    try std.testing.expectEqual(@as(?u16, null), eeprom.readWord(0x100000));
    try std.testing.expect(!eeprom.writeByte(0x100000, 0xFF));
    try std.testing.expect(!eeprom.writeWord(0x100000, 0xFFFF));
}

test "i2c eeprom dirty flag set on write" {
    var data = [_]u8{0} ** 128;
    var eeprom = makeTestEeprom(0, .sega, &data);

    try std.testing.expect(!eeprom.dirty);

    sendStart(&eeprom, .sega);
    sendByte7bitMode(&eeprom, .sega, 0x00, 0);
    sendDataByte(&eeprom, .sega, 0xFF);
    sendStop(&eeprom, .sega);

    try std.testing.expect(eeprom.dirty);
}

test "i2c eeprom resetState clears protocol state but not data" {
    var data = [_]u8{0} ** 128;
    var eeprom = makeTestEeprom(0, .sega, &data);

    sendStart(&eeprom, .sega);
    sendByte7bitMode(&eeprom, .sega, 0x00, 0);
    sendDataByte(&eeprom, .sega, 0xAB);
    sendStop(&eeprom, .sega);

    try std.testing.expectEqual(@as(u8, 0xAB), data[0x00]);

    eeprom.resetState();
    try std.testing.expectEqual(I2cState.stand_by, eeprom.state);
    try std.testing.expectEqual(@as(u8, 0xAB), data[0x00]); // data preserved
}

test "i2c eeprom 16-bit mode write and read cycle" {
    var data = [_]u8{0} ** 0x10000;
    var eeprom = makeTestEeprom(12, .sega, &data); // 24C512, 16-bit word address

    // Write 0x5C to address 0x1234
    sendStart(&eeprom, .sega);
    try std.testing.expectEqual(I2cState.get_device_adr, eeprom.state);
    sendDataByte(&eeprom, .sega, 0xA0); // device addr, W=0
    sendDataByte(&eeprom, .sega, 0x12); // word address high
    sendDataByte(&eeprom, .sega, 0x34); // word address low
    sendDataByte(&eeprom, .sega, 0x5C);
    sendStop(&eeprom, .sega);

    try std.testing.expectEqual(@as(u8, 0x5C), data[0x1234]);

    // Read back
    sendStart(&eeprom, .sega);
    sendDataByte(&eeprom, .sega, 0xA0);
    sendDataByte(&eeprom, .sega, 0x12);
    sendDataByte(&eeprom, .sega, 0x34);
    sendStart(&eeprom, .sega); // repeated START
    sendDataByte(&eeprom, .sega, 0xA1); // device addr, R=1
    const result = readDataByte(&eeprom, .sega, false);
    sendStop(&eeprom, .sega);

    try std.testing.expectEqual(@as(u8, 0x5C), result);
}

test "acclaim 32m bank-shift exposes rom until the eeprom is selected" {
    var data = [_]u8{0xFF} ** 512;
    var eeprom = makeTestEeprom(4, .acclaim_32m, &data); // 24C04 (NBA Jam TE)

    // Power-on: reads fall through to cartridge ROM across the window.
    try std.testing.expectEqual(@as(?u8, null), eeprom.readByte(0x20_0001));
    try std.testing.expectEqual(@as(?u16, null), eeprom.readWord(0x2A_BCDE));

    // Word write with bit 0 clear selects the EEPROM for reads.
    try std.testing.expect(eeprom.writeWord(0x20_0000, 0x0000));
    try std.testing.expect(eeprom.readWord(0x20_0000) != null);
    // ...but only in $200000-$2FFFFF; above stays ROM.
    try std.testing.expectEqual(@as(?u16, null), eeprom.readWord(0x30_0000));

    // Bit 0 set switches reads back to ROM.
    try std.testing.expect(eeprom.writeWord(0x20_0000, 0x0001));
    try std.testing.expectEqual(@as(?u8, null), eeprom.readByte(0x20_0001));
}

test "sega wiring word writes drive the i2c lines from the low byte" {
    var data = [_]u8{0} ** 128;
    var eeprom = makeTestEeprom(0, .sega, &data);

    // SCL is D1, SDA is D0 — both live in the LOW byte of a word write.
    try std.testing.expect(eeprom.writeWord(0x20_0000, 0x0003));
    try std.testing.expectEqual(@as(u1, 1), eeprom.sda);
    try std.testing.expectEqual(@as(u1, 1), eeprom.scl);

    try std.testing.expect(eeprom.writeWord(0x20_0000, 0x0300));
    try std.testing.expectEqual(@as(u1, 0), eeprom.sda);
    try std.testing.expectEqual(@as(u1, 0), eeprom.scl);
}

test "codemasters wiring uses split write and read windows" {
    var data = [_]u8{0} ** 1024;
    var eeprom = makeTestEeprom(5, .codemasters, &data); // 24C08

    try std.testing.expect(!eeprom.writeByte(0x20_0001, 0xFF)); // outside write window
    try std.testing.expect(eeprom.writeByte(0x30_0000, 0x03));
    try std.testing.expectEqual(@as(?u8, null), eeprom.readByte(0x30_0001)); // no reads here
    try std.testing.expect(eeprom.readByte(0x38_0001) != null);
}

test "i2c detect finds known game by product code" {
    var rom = [_]u8{0} ** 0x200;
    @memcpy(rom[0x183 .. 0x183 + 7], "T-12046");

    const result = detect(&rom);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 0), result.?.eeprom_type);
    try std.testing.expectEqual(WiringConfig.sega, result.?.wiring);
}

test "i2c detect returns null for unknown game" {
    var rom = [_]u8{0} ** 0x200;
    @memcpy(rom[0x183 .. 0x183 + 7], "UNKNOWN");

    try std.testing.expectEqual(@as(?DetectResult, null), detect(&rom));
}
