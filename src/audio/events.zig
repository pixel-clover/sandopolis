//! YM2612 and PSG audio event types shared between the audio pipeline and
//! the Z80 bridge that produces them. The audio side owns these types; the
//! Z80 wrapper casts them across its C boundary and comptime-asserts that
//! the layouts stay in lockstep with the structs in jgz80_bridge.h.

pub const YmWriteEvent = extern struct {
    master_offset: u32,
    sequence: u32,
    port: u8,
    reg: u8,
    value: u8,
};

pub const PsgCommandEvent = extern struct {
    master_offset: u32,
    value: u8,
};

pub const YmDacSampleEvent = extern struct {
    master_offset: u32,
    sequence: u32,
    value: u8,
};

pub const YmResetEvent = extern struct {
    master_offset: u32,
    sequence: u32,
};
