const std = @import("std");

pub fn main() !void {
    var stderr_buffer: [256]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stderr = &stderr_writer.interface;
    try stderr.writeAll(
        "compare-ym requires the optional external/Nuked-OPN2 submodule.\n" ++
            "Run `git submodule update --init external/Nuked-OPN2` and try again.\n",
    );
    try stderr.flush();
    std.process.exit(1);
}
