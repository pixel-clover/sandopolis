const std = @import("std");

fn addExternalCpuCores(step: *std.Build.Step.Compile, b: *std.Build) void {
    step.addIncludePath(b.path("external/rocket68/include"));
    step.addIncludePath(b.path("external/rocket68/src/m68k"));
    step.addIncludePath(b.path("external/jgz80"));
    step.addIncludePath(b.path("src/c"));

    step.addCSourceFiles(.{
        .files = &.{
            "external/rocket68/src/m68k/m68k.c",
            "external/rocket68/src/m68k/ops_arith.c",
            "external/rocket68/src/m68k/ops_bit.c",
            "external/rocket68/src/m68k/ops_control.c",
            "external/rocket68/src/m68k/ops_logic.c",
            "external/rocket68/src/m68k/ops_move.c",
            "external/jgz80/z80.c",
            "src/c/jgz80_bridge.c",
        },
        .flags = &.{ "-std=c11" },
    });
    step.linkLibC();
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zsdl = b.dependency("zsdl", .{});

    // Create the executable
    const exe = b.addExecutable(.{
        .name = "sandopolis",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zsdl3", .module = zsdl.module("zsdl3") },
            },
        }),
    });
    addExternalCpuCores(exe, b);

    // Link SDL3
    if (target.result.os.tag == .linux) {
        // Use prebuilt SDL3
        const sdl3_dep = b.dependency("sdl3_linux", .{});
        exe.addLibraryPath(sdl3_dep.path("lib"));
        // Install the shared library to the bin directory so it can be found at runtime
        const install_sdl3 = b.addInstallFile(sdl3_dep.path("lib/libSDL3.so"), "bin/libSDL3.so.0");
        b.getInstallStep().dependOn(&install_sdl3.step);

        // Also symlink or install simply implies it's there.
        // We link against it.
        exe.linkSystemLibrary("SDL3");
        exe.linkLibC();

        // Add rpath so it finds the lib in the same dir
        exe.root_module.addRPathSpecial("$ORIGIN");
    } else {
        // Fallback for other systems (assuming installed)
        exe.linkSystemLibrary("SDL3");
        if (target.result.os.tag == .macos) {
            // macOS specifics if needed
        }
    }

    b.installArtifact(exe);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Check step
    const exe_check = b.addExecutable(.{
        .name = "sandopolis",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zsdl3", .module = zsdl.module("zsdl3") },
            },
        }),
    });
    addExternalCpuCores(exe_check, b);

    if (target.result.os.tag == .linux) {
        const sdl3_dep = b.dependency("sdl3_linux", .{});
        exe_check.addLibraryPath(sdl3_dep.path("lib"));
        exe_check.addIncludePath(sdl3_dep.path("include"));
        exe_check.linkSystemLibrary("SDL3");
        exe_check.linkLibC();
    } else {
        exe_check.linkSystemLibrary("SDL3");
    }

    const check = b.step("check", "Check if sandopolis compiles");
    check.dependOn(&exe_check.step);

    // Test executable (no SDL dependency)
    const test_exe = b.addExecutable(.{
        .name = "test_emu",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test_emu.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    addExternalCpuCores(test_exe, b);

    b.installArtifact(test_exe);

    const test_run_cmd = b.addRunArtifact(test_exe);
    test_run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        test_run_cmd.addArgs(args);
    }

    const test_step = b.step("test-emu", "Run the emulator test");
    test_step.dependOn(&test_run_cmd.step);
}
