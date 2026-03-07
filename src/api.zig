pub const clock = @import("clock.zig");

pub const audio = struct {
    pub const output = @import("audio/output.zig");
    pub const timing = @import("audio/timing.zig");
    pub const psg = @import("audio/psg.zig");
};

pub const input = struct {
    pub const mapping = @import("input/mapping.zig");
    pub const io = @import("input/io.zig");
};

pub const scheduler = @import("scheduler/frame_scheduler.zig");
pub const bus = @import("bus/bus.zig");
pub const cartridge = @import("bus/cartridge.zig");
pub const machine = @import("machine.zig");
pub const video = struct {
    pub const vdp = @import("video/vdp.zig");
};

pub const cpu = @import("cpu/cpu.zig");
pub const z80 = @import("cpu/z80.zig");

pub const AudioTiming = audio.timing.AudioTiming;
pub const PendingAudioFrames = audio.timing.PendingAudioFrames;
pub const AudioOutput = audio.output.AudioOutput;
pub const Bus = bus.Bus;
pub const Cartridge = cartridge.Cartridge;
pub const Cpu = cpu.Cpu;
pub const Io = input.io.Io;
pub const Machine = machine.Machine;
pub const Psg = audio.psg.Psg;
pub const Vdp = video.vdp.Vdp;
pub const Z80 = z80.Z80;
