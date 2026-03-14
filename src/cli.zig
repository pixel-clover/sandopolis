const std = @import("std");
const AudioOutput = @import("audio/output.zig").AudioOutput;
const rom_metadata = @import("rom_metadata.zig");

pub const TimingModeOption = rom_metadata.TimingModeOption;

// CLI parsing options
pub const Options = struct {
    rom_path: ?[]const u8 = null,
    audio_mode: AudioOutput.RenderMode = .normal,
    renderer_name: ?[]const u8 = null,
    timing_mode: TimingModeOption = .auto,
    show_help: bool = false,
};

// CLI parsing errors
pub const ParseError = error{
    InvalidAudioMode,
    MissingAudioModeValue,
    MissingRendererValue,
    MultipleRomPaths,
    UnknownOption,
};

// Print usage information
pub fn printUsage() void {
    std.debug.print("Usage: sandopolis [options] [rom_file]\n", .{});
    std.debug.print("Options:\n", .{});
    std.debug.print("  --audio-mode <mode>   Audio render mode: normal, ym-only, psg-only, unfiltered-mix\n", .{});
    std.debug.print("  --audio-mode=<mode>   Same as above\n", .{});
    std.debug.print("  --renderer <name>     SDL render driver override (for example: software, opengl)\n", .{});
    std.debug.print("  --renderer=<name>     Same as above\n", .{});
    std.debug.print("  --pal                 Force PAL/50Hz timing and version bits\n", .{});
    std.debug.print("  --ntsc                Force NTSC/60Hz timing and version bits\n", .{});
    std.debug.print("  -h, --help            Show this help text\n", .{});
}

// Parse command line arguments
pub fn parseArgs(args: []const []const u8) ParseError!Options {
    var options = Options{};
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            options.show_help = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--audio-mode")) {
            index += 1;
            if (index >= args.len) return error.MissingAudioModeValue;
            options.audio_mode = try AudioOutput.RenderMode.parse(args[index]);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--audio-mode=")) {
            options.audio_mode = try AudioOutput.RenderMode.parse(arg["--audio-mode=".len..]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--renderer")) {
            index += 1;
            if (index >= args.len) return error.MissingRendererValue;
            options.renderer_name = args[index];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--renderer=")) {
            options.renderer_name = arg["--renderer=".len..];
            continue;
        }
        if (std.mem.eql(u8, arg, "--pal")) {
            options.timing_mode = .pal;
            continue;
        }
        if (std.mem.eql(u8, arg, "--ntsc")) {
            options.timing_mode = .ntsc;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--")) return error.UnknownOption;
        if (options.rom_path != null) return error.MultipleRomPaths;
        options.rom_path = arg;
    }
    return options;
}

// Get human-readable error message
pub fn errorMessage(err: ParseError) []const u8 {
    return switch (err) {
        error.InvalidAudioMode => "invalid --audio-mode value",
        error.MissingAudioModeValue => "--audio-mode requires a value",
        error.MissingRendererValue => "--renderer requires a value",
        error.MultipleRomPaths => "only one ROM path may be provided",
        error.UnknownOption => "unknown option",
    };
}
