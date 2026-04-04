const audio_output = @import("audio/output.zig");
const audio_psg = @import("audio/psg.zig");
const audio_timing = @import("audio/timing.zig");
const audio_ym2612 = @import("audio/ym2612.zig");
const bus = @import("bus/bus.zig");
const bus_eeprom_i2c = @import("bus/eeprom_i2c.zig");
const z80 = @import("cpu/z80.zig");
const input_io = @import("input/io.zig");
const input_mapping = @import("input/mapping.zig");
const recording_gif = @import("recording/gif.zig");
const recording_screenshot = @import("recording/screenshot.zig");
const rom_paths_mod = @import("rom_paths.zig");
const state_file = @import("state_file.zig");
const video_fifo = @import("video/fifo.zig");
const video_timing = @import("video/timing.zig");
const wasm = @import("wasm.zig");

comptime {
    _ = audio_output;
    _ = audio_psg;
    _ = audio_timing;
    _ = audio_ym2612;
    _ = bus;
    _ = bus_eeprom_i2c;
    _ = z80;
    _ = input_io;
    _ = input_mapping;
    _ = recording_gif;
    _ = recording_screenshot;
    _ = rom_paths_mod;
    _ = state_file;
    _ = video_fifo;
    _ = video_timing;
    _ = wasm;
}
