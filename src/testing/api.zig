pub const PendingAudioFrames = @import("../audio/timing.zig").PendingAudioFrames;
pub const AudioTiming = @import("audio_timing.zig").AudioTiming;
pub const ControllerIo = @import("controller_io.zig").ControllerIo;
pub const ControllerType = @import("controller_io.zig").ControllerType;
pub const Button = @import("controller_io.zig").Button;
pub const Emulator = @import("emulator.zig").Emulator;
pub const Vdp = @import("vdp.zig").Vdp;

pub const Ym2612Synth = @import("../audio/ym2612.zig").Ym2612Synth;
pub const YmWriteEvent = @import("../audio/ym2612.zig").YmWriteEvent;

pub fn ymWriteEvent(port: u1, reg: u8, value: u8) YmWriteEvent {
    return .{
        .master_offset = 0,
        .sequence = 0,
        .port = port,
        .reg = reg,
        .value = value,
    };
}
