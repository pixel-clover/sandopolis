const z80_timing = @import("z80_timing.zig");
const Cartridge = @import("cartridge.zig").Cartridge;
const AudioTiming = @import("../audio/timing.zig").AudioTiming;
const Vdp = @import("../video/vdp.zig").Vdp;
const Io = @import("../input/io.zig").Io;

pub const State = struct {
    ram: [64 * 1024]u8,
    vdp: Vdp,
    io: Io,
    audio_timing: AudioTiming,
    timing_state: z80_timing.State,
    open_bus: u16,
    cartridge_ram: Cartridge.RamState,
};
