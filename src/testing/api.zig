pub const SmsMachine = @import("../sms/machine.zig").SmsMachine;
pub const PendingAudioFrames = @import("../audio/timing.zig").PendingAudioFrames;
pub const AudioTiming = @import("audio_timing.zig").AudioTiming;
pub const ControllerIo = @import("controller_io.zig").ControllerIo;
pub const ControllerType = @import("controller_io.zig").ControllerType;
pub const Button = @import("controller_io.zig").Button;
pub const MouseButton = @import("controller_io.zig").MouseButton;
pub const Emulator = @import("emulator.zig").Emulator;
pub const Vdp = @import("vdp.zig").Vdp;
pub const AudioOutput = @import("../audio/output.zig").AudioOutput;
pub const WavRecorder = @import("../recording/wav.zig").WavRecorder;
pub const M68kInstructionTraceEntry = @import("../cpu/rocket68_cpu.zig").Cpu.M68kInstructionTraceEntry;
pub const M68kSoundWriteTraceEntry = @import("../bus/bus.zig").Bus.M68kSoundWriteTraceEntry;
pub const M68kSoundWriteTraceKind = @import("../bus/bus.zig").Bus.M68kSoundWriteTraceKind;
pub const M68kSoundWriteTraceOutcome = @import("../bus/bus.zig").Bus.M68kSoundWriteTraceOutcome;

pub const Ym2612Synth = @import("../audio/ym2612.zig").Ym2612Synth;
pub const YmWriteEvent = @import("../audio/ym2612.zig").YmWriteEvent;
pub const Z80AudioOpTraceEntry = @import("../cpu/z80.zig").Z80.AudioOpTraceEntry;
pub const YmDacSampleEvent = @import("../cpu/z80.zig").Z80.YmDacSampleEvent;

pub fn ymWriteEvent(port: u1, reg: u8, value: u8) YmWriteEvent {
    return .{
        .master_offset = 0,
        .sequence = 0,
        .port = port,
        .reg = reg,
        .value = value,
    };
}
