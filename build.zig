const std = @import("std");

const CpuDeps = struct {
    rocket68: *std.Build.Dependency,
    jgz80: *std.Build.Dependency,
};

const VendoredSdl3 = struct {
    install_step: *std.Build.Step.Run,
    lib_dir: []const u8,
    runtime_dir: []const u8,
    runtime_install_subdir: []const u8,
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

fn cmakeBuildType(optimize: std.builtin.OptimizeMode) []const u8 {
    return switch (optimize) {
        .Debug => "Debug",
        .ReleaseSafe => "RelWithDebInfo",
        .ReleaseFast => "Release",
        .ReleaseSmall => "MinSizeRel",
    };
}

fn sdlRunEnvVar(os_tag: std.Target.Os.Tag) []const u8 {
    return switch (os_tag) {
        .windows => "PATH",
        .macos => "DYLD_LIBRARY_PATH",
        else => "LD_LIBRARY_PATH",
    };
}

fn addVendoredSdl3(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) VendoredSdl3 {
    const sdl3 = b.dependency("sdl3", .{});
    const triple = target.result.zigTriple(b.allocator) catch @panic("OOM");
    const build_root = b.fmt(".zig-cache/vendored-sdl3/v1/{s}-{s}", .{ triple, @tagName(optimize) });
    const build_dir = b.fmt("{s}/build", .{build_root});
    const install_dir = b.fmt("{s}/install", .{build_root});
    const build_type = cmakeBuildType(optimize);

    const configure = b.addSystemCommand(&.{"cmake"});
    configure.setName("Configure vendored SDL3");
    configure.addArgs(&.{"-S"});
    configure.addDirectoryArg(sdl3.path("."));
    configure.addArgs(&.{
        "-B",
        build_dir,
        b.fmt("-DCMAKE_BUILD_TYPE={s}", .{build_type}),
        b.fmt("-DCMAKE_INSTALL_PREFIX={s}", .{install_dir}),
        "-DSDL_SHARED=ON",
        "-DSDL_STATIC=OFF",
        "-DSDL_TEST_LIBRARY=OFF",
        "-DSDL_TESTS=OFF",
        "-DSDL_INSTALL_TESTS=OFF",
        "-DSDL_EXAMPLES=OFF",
        "-DSDL_INSTALL_DOCS=OFF",
        "-DSDL_INSTALL=ON",
        "-DSDL_FRAMEWORK=OFF",
    });

    const build_sdl = b.addSystemCommand(&.{
        "cmake",
        "--build",
        build_dir,
        "--config",
        build_type,
    });
    build_sdl.setName("Build vendored SDL3");
    build_sdl.step.dependOn(&configure.step);

    const install = b.addSystemCommand(&.{
        "cmake",
        "--install",
        build_dir,
        "--config",
        build_type,
        "--prefix",
        install_dir,
    });
    install.setName("Install vendored SDL3");
    install.step.dependOn(&build_sdl.step);

    return .{
        .install_step = install,
        .lib_dir = b.fmt("{s}/lib", .{install_dir}),
        .runtime_dir = switch (target.result.os.tag) {
            .windows => b.fmt("{s}/bin", .{install_dir}),
            else => b.fmt("{s}/lib", .{install_dir}),
        },
        .runtime_install_subdir = switch (target.result.os.tag) {
            .windows => "bin",
            else => "lib",
        },
    };
}

fn linkVendoredSdl3(step: *std.Build.Step.Compile, sdl: VendoredSdl3) void {
    step.step.dependOn(&sdl.install_step.step);
    step.addLibraryPath(.{ .cwd_relative = sdl.lib_dir });
    step.linkSystemLibrary("SDL3");
    step.linkLibC();
}

fn setVendoredSdl3Runtime(run: *std.Build.Step.Run, sdl: VendoredSdl3, target: std.Build.ResolvedTarget) void {
    run.step.dependOn(&sdl.install_step.step);
    run.setEnvironmentVariable(sdlRunEnvVar(target.result.os.tag), sdl.runtime_dir);
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zsdl = b.dependency("zsdl", .{});
    const minish = b.dependency("minish", .{});
    const vendored_sdl3 = addVendoredSdl3(b, target, optimize);
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
    linkVendoredSdl3(exe, vendored_sdl3);
    switch (target.result.os.tag) {
        .linux => exe.root_module.addRPathSpecial("$ORIGIN/../lib"),
        .macos => exe.root_module.addRPathSpecial("@loader_path/../lib"),
        else => {},
    }

    b.installArtifact(exe);
    const install_sdl3_runtime = b.addInstallDirectory(.{
        .source_dir = .{ .cwd_relative = vendored_sdl3.runtime_dir },
        .install_dir = .prefix,
        .install_subdir = vendored_sdl3.runtime_install_subdir,
    });
    install_sdl3_runtime.step.dependOn(&vendored_sdl3.install_step.step);
    b.getInstallStep().dependOn(&install_sdl3_runtime.step);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    setVendoredSdl3Runtime(run_cmd, vendored_sdl3, target);
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
    linkVendoredSdl3(exe_check, vendored_sdl3);

    const check = b.step("check", "Check if sandopolis compiles");
    check.dependOn(&exe_check.step);

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/unit_test_root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zsdl3", .module = zsdl.module("zsdl3") },
            },
        }),
    });
    addExternalCpuCores(unit_tests, b, cpu_deps);
    linkVendoredSdl3(unit_tests, vendored_sdl3);

    const unit_run = b.addRunArtifact(unit_tests);
    setVendoredSdl3Runtime(unit_run, vendored_sdl3, target);
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
    linkVendoredSdl3(frontend_tests, vendored_sdl3);
    const frontend_run = b.addRunArtifact(frontend_tests);
    setVendoredSdl3Runtime(frontend_run, vendored_sdl3, target);
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
