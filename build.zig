const std = @import("std");

const CpuDeps = struct {
    rocket68: *std.Build.Dependency,
    jgz80: *std.Build.Dependency,
};

fn addExternalCpuCores(step: *std.Build.Step.Compile, b: *std.Build, deps: CpuDeps) void {
    addCpuIncludePaths(step, b, deps);

    step.addCSourceFiles(.{
        .root = deps.rocket68.path("."),
        .files = &.{
            "src/m68k/m68k.c",
            "src/m68k/ops_arith.c",
            "src/m68k/ops_bit.c",
            "src/m68k/ops_control.c",
            "src/disasm.c",
            "src/m68k/ops_logic.c",
            "src/m68k/ops_move.c",
        },
        .flags = &.{"-std=c11"},
    });
    step.addCSourceFiles(.{
        .root = deps.jgz80.path("."),
        .files = &.{
            "z80.c",
        },
        .flags = &.{"-std=c11"},
    });
    step.addCSourceFiles(.{
        .files = &.{"src/cpu/jgz80_bridge.c"},
        .flags = &.{"-std=c11"},
    });
    step.linkLibC();
}

fn addCpuIncludePaths(step: *std.Build.Step.Compile, b: *std.Build, deps: CpuDeps) void {
    step.addIncludePath(deps.rocket68.path("include"));
    step.addIncludePath(deps.rocket68.path("src/m68k"));
    step.addIncludePath(deps.jgz80.path("."));
    step.addIncludePath(b.path("src/cpu"));
    step.root_module.addIncludePath(deps.rocket68.path("include"));
    step.root_module.addIncludePath(deps.rocket68.path("src/m68k"));
    step.root_module.addIncludePath(deps.jgz80.path("."));
    step.root_module.addIncludePath(b.path("src/cpu"));
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zsdl = b.dependency("zsdl", .{});
    const minish = b.dependency("minish", .{});
    const linux_sdl3 = if (target.result.os.tag == .linux) b.dependency("sdl3_linux", .{}) else null;
    const frontend_test_sdl_install = if (target.result.os.tag == .linux)
        b.addInstallFile(linux_sdl3.?.path("lib/libSDL3.so"), ".zig-test-libs/libSDL3.so.0")
    else
        null;
    const cpu_deps: CpuDeps = .{
        .rocket68 = b.dependency("rocket68", .{}),
        .jgz80 = b.dependency("jgz80", .{}),
    };
    const sandopolis_api = b.createModule(.{
        .root_source_file = b.path("src/api.zig"),
        .target = target,
        .optimize = optimize,
    });
    sandopolis_api.addIncludePath(cpu_deps.rocket68.path("include"));
    sandopolis_api.addIncludePath(cpu_deps.rocket68.path("src/m68k"));
    sandopolis_api.addIncludePath(cpu_deps.jgz80.path("."));
    sandopolis_api.addIncludePath(b.path("src/cpu"));

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
    addExternalCpuCores(exe, b, cpu_deps);

    // Link SDL3
    if (target.result.os.tag == .linux) {
        // Use prebuilt SDL3
        const sdl3_dep = linux_sdl3.?;
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
    addExternalCpuCores(exe_check, b, cpu_deps);

    if (target.result.os.tag == .linux) {
        const sdl3_dep = linux_sdl3.?;
        exe_check.addLibraryPath(sdl3_dep.path("lib"));
        exe_check.addIncludePath(sdl3_dep.path("include"));
        exe_check.linkSystemLibrary("SDL3");
        exe_check.linkLibC();
    } else {
        exe_check.linkSystemLibrary("SDL3");
    }

    const check = b.step("check", "Check if sandopolis compiles");
    check.dependOn(&exe_check.step);

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/api.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zsdl3", .module = zsdl.module("zsdl3") },
            },
        }),
    });
    addExternalCpuCores(unit_tests, b, cpu_deps);

    const unit_run = b.addRunArtifact(unit_tests);
    const unit_step = b.step("test-unit", "Run unit tests");
    unit_step.dependOn(&unit_run.step);

    const frontend_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zsdl3", .module = zsdl.module("zsdl3") },
            },
        }),
    });
    addExternalCpuCores(frontend_tests, b, cpu_deps);
    if (target.result.os.tag == .linux) {
        const sdl3_dep = linux_sdl3.?;
        frontend_tests.addLibraryPath(sdl3_dep.path("lib"));
        frontend_tests.addIncludePath(sdl3_dep.path("include"));
        frontend_tests.addRPath(sdl3_dep.path("lib"));
        frontend_tests.linkSystemLibrary("SDL3");
        frontend_tests.linkLibC();
    } else {
        frontend_tests.linkSystemLibrary("SDL3");
    }
    const frontend_run = b.addRunArtifact(frontend_tests);
    if (target.result.os.tag == .linux) {
        frontend_run.step.dependOn(&frontend_test_sdl_install.?.step);
        frontend_run.setEnvironmentVariable("LD_LIBRARY_PATH", b.getInstallPath(.prefix, ".zig-test-libs"));
    }
    const frontend_step = b.step("test-frontend", "Run frontend helper tests");
    frontend_step.dependOn(&frontend_run.step);

    const integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration_tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "sandopolis_src", .module = sandopolis_api },
            },
        }),
    });
    addExternalCpuCores(integration_tests, b, cpu_deps);

    const integration_run = b.addRunArtifact(integration_tests);
    const integration_step = b.step("test-integration", "Run integration tests");
    integration_step.dependOn(&integration_run.step);

    const regression_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/regression_tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "sandopolis_src", .module = sandopolis_api },
            },
        }),
    });
    addExternalCpuCores(regression_tests, b, cpu_deps);

    const regression_run = b.addRunArtifact(regression_tests);
    const regression_step = b.step("test-regression", "Run regression tests");
    regression_step.dependOn(&regression_run.step);

    const property_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/property_tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "sandopolis_src", .module = sandopolis_api },
                .{ .name = "minish", .module = minish.module("minish") },
            },
        }),
    });
    addExternalCpuCores(property_tests, b, cpu_deps);
    const property_run = b.addRunArtifact(property_tests);
    const property_step = b.step("test-property", "Run property-based tests");
    property_step.dependOn(&property_run.step);

    const docs_module = b.createModule(.{
        .root_source_file = b.path("src/api.zig"),
        .target = target,
        .optimize = optimize,
    });
    const docs_obj = b.addObject(.{
        .name = "sandopolis_docs",
        .root_module = docs_module,
    });
    addCpuIncludePaths(docs_obj, b, cpu_deps);
    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs_obj.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs/api",
    });
    const docs_step = b.step("docs", "Generate API documentation");
    docs_step.dependOn(&install_docs.step);

    const test_step_all = b.step("test", "Run unit, frontend, integration, regression, and property tests");
    test_step_all.dependOn(&unit_run.step);
    test_step_all.dependOn(&frontend_run.step);
    test_step_all.dependOn(&integration_run.step);
    test_step_all.dependOn(&regression_run.step);
    test_step_all.dependOn(&property_run.step);
}
