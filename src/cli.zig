const std = @import("std");
const chilli = @import("chilli");
const AudioOutput = @import("audio/output.zig").AudioOutput;
const rom_metadata = @import("rom_metadata.zig");
const build_options = @import("build_options");

pub const TimingModeOption = rom_metadata.TimingModeOption;

pub const Config = struct {
    rom_path: ?[]const u8 = null,
    audio_mode: AudioOutput.RenderMode = .normal,
    renderer_name: ?[]const u8 = null,
    timing_mode: TimingModeOption = .auto,
    should_run: bool = false,
};

fn exec(ctx: chilli.CommandContext) !void {
    const config: *Config = ctx.getContextData(Config).?;

    // Positional: ROM path
    const rom_arg = try ctx.getArg("rom_file", []const u8);
    config.rom_path = if (rom_arg.len > 0) rom_arg else null;

    // --audio-mode
    const audio_str = try ctx.getFlag("audio-mode", []const u8);
    if (!std.mem.eql(u8, audio_str, "normal")) {
        config.audio_mode = AudioOutput.RenderMode.parse(audio_str) catch
            return error.InvalidAudioMode;
    }

    // --renderer
    const renderer_str = try ctx.getFlag("renderer", []const u8);
    config.renderer_name = if (renderer_str.len > 0) renderer_str else null;

    // --pal / --ntsc (mutually exclusive)
    const pal = try ctx.getFlag("pal", bool);
    const ntsc = try ctx.getFlag("ntsc", bool);
    if (pal and ntsc) return error.ConflictingTimingFlags;
    if (pal) config.timing_mode = .pal;
    if (ntsc) config.timing_mode = .ntsc;

    config.should_run = true;
}

pub fn createCommand(allocator: std.mem.Allocator) !*chilli.Command {
    var cmd = try chilli.Command.init(allocator, .{
        .name = "sandopolis",
        .description = "A Sega Genesis/Mega Drive emulator written in Zig and C",
        .version = build_options.version,
        .exec = exec,
    });

    try cmd.addFlag(.{
        .name = "audio-mode",
        .description = "Audio render mode: normal, ym-only, psg-only, unfiltered-mix",
        .type = .String,
        .default_value = .{ .String = "normal" },
    });
    try cmd.addFlag(.{
        .name = "renderer",
        .description = "SDL render driver override (e.g. software, opengl)",
        .type = .String,
        .default_value = .{ .String = "" },
    });
    try cmd.addFlag(.{
        .name = "pal",
        .description = "Force PAL/50Hz timing and version bits",
        .type = .Bool,
        .default_value = .{ .Bool = false },
    });
    try cmd.addFlag(.{
        .name = "ntsc",
        .description = "Force NTSC/60Hz timing and version bits",
        .type = .Bool,
        .default_value = .{ .Bool = false },
    });
    try cmd.addPositional(.{
        .name = "rom_file",
        .description = "Path to a ROM file (.bin, .md, or .smd)",
        .default_value = .{ .String = "" },
    });

    return cmd;
}
