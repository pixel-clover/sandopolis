const std = @import("std");
const chilli = @import("chilli");
const AudioOutput = @import("audio/output.zig").AudioOutput;
const rom_metadata = @import("rom_metadata.zig");
const build_options = @import("build_options");

pub const TimingModeOption = rom_metadata.TimingModeOption;
pub const version_summary = std.fmt.comptimePrint("{s} ({s}@{s})", .{
    build_options.version,
    build_options.git_branch,
    build_options.git_hash,
});

pub const Config = struct {
    rom_path: ?[]const u8 = null,
    audio_mode: AudioOutput.RenderMode = .normal,
    audio_mode_overridden: bool = false,
    audio_queue_ms: u16 = AudioOutput.default_queue_budget_ms,
    audio_queue_ms_overridden: bool = false,
    renderer_name: ?[]const u8 = null,
    timing_mode: TimingModeOption = .auto,
    config_path: ?[]const u8 = null,
    should_run: bool = false,
    show_version: bool = false,
};

fn exec(ctx: chilli.CommandContext) !void {
    const config: *Config = ctx.getContextData(Config).?;

    const show_version = try ctx.getFlag("version", bool);
    if (show_version) {
        config.show_version = true;
        return;
    }

    // Positional: ROM path: dupe via app_allocator so it outlives
    // the process-arg memory that chilli frees when run() returns.
    const rom_arg = try ctx.getArg("rom_file", []const u8);
    config.rom_path = if (rom_arg.len > 0) try ctx.app_allocator.dupe(u8, rom_arg) else null;

    // --audio-mode
    const audio_str = try ctx.getFlag("audio-mode", []const u8);
    if (audio_str.len != 0) {
        config.audio_mode = AudioOutput.RenderMode.parse(audio_str) catch
            return error.InvalidAudioMode;
        config.audio_mode_overridden = true;
    }

    // --audio-queue-ms
    const audio_queue_str = try ctx.getFlag("audio-queue-ms", []const u8);
    if (audio_queue_str.len != 0) {
        const parsed = std.fmt.parseUnsigned(u16, audio_queue_str, 10) catch
            return error.InvalidAudioQueueMs;
        if (!AudioOutput.isValidQueueBudgetMs(parsed)) return error.InvalidAudioQueueMs;
        config.audio_queue_ms = parsed;
        config.audio_queue_ms_overridden = true;
    }

    // --renderer: dupe for same reason as rom_path
    const renderer_str = try ctx.getFlag("renderer", []const u8);
    config.renderer_name = if (renderer_str.len > 0) try ctx.app_allocator.dupe(u8, renderer_str) else null;

    // --config
    const config_str = try ctx.getFlag("config", []const u8);
    config.config_path = if (config_str.len > 0) try ctx.app_allocator.dupe(u8, config_str) else null;

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
        .description = "A portable multi-system Sega emulator for Genesis, Master System, and Game Gear",
        .exec = exec,
    });

    try cmd.addFlag(.{
        .name = "audio-mode",
        .description = "Audio render mode: normal, ym-only, psg-only, unfiltered-mix",
        .type = .String,
        .default_value = .{ .String = "" },
    });
    try cmd.addFlag(.{
        .name = "audio-queue-ms",
        .description = "Audio queue budget in milliseconds (40-150) before backlog recovery",
        .type = .String,
        .default_value = .{ .String = "" },
    });
    try cmd.addFlag(.{
        .name = "renderer",
        .description = "SDL render driver override (e.g. software, opengl)",
        .type = .String,
        .default_value = .{ .String = "" },
    });
    try cmd.addFlag(.{
        .name = "config",
        .description = "Path to the unified config file (default: SANDOPOLIS_CONFIG, platform app data, or ./sandopolis.cfg)",
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
    try cmd.addFlag(.{
        .name = "version",
        .description = "Print version information and exit",
        .type = .Bool,
        .default_value = .{ .Bool = false },
    });
    try cmd.addPositional(.{
        .name = "rom_file",
        .description = "Path to a ROM file (.bin, .md, .smd, .gen, .sms, .gg) or a .zip archive containing one",
        .default_value = .{ .String = "" },
    });

    return cmd;
}
