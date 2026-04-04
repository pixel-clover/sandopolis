const std = @import("std");

const CpuDeps = struct {
    rocket68: *std.Build.Dependency,
    jgz80: *std.Build.Dependency,
};

fn createTestingApiModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    deps: CpuDeps,
) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path("src/testing_root.zig"),
        .target = target,
        .optimize = optimize,
    });
    module.addIncludePath(deps.rocket68.path("include"));
    module.addIncludePath(deps.rocket68.path("src/m68k"));
    module.addIncludePath(deps.jgz80.path("."));
    module.addIncludePath(b.path("src/cpu"));
    return module;
}

fn createSandopolisApiModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    deps: CpuDeps,
) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path("src/api.zig"),
        .target = target,
        .optimize = optimize,
    });
    module.addIncludePath(deps.rocket68.path("include"));
    module.addIncludePath(deps.rocket68.path("src/m68k"));
    module.addIncludePath(deps.jgz80.path("."));
    module.addIncludePath(b.path("src/cpu"));
    return module;
}

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

fn pathExists(relative_path: []const u8) bool {
    std.fs.cwd().access(relative_path, .{}) catch return false;
    return true;
}

fn addStbTruetype(step: *std.Build.Step.Compile, b: *std.Build) void {
    step.addCSourceFiles(.{
        .files = &.{"src/frontend/fonts/stb_impl.c"},
        .flags = &.{"-std=c99"},
    });
    step.addIncludePath(b.path("src/frontend/fonts"));
    step.root_module.addIncludePath(b.path("src/frontend/fonts"));
}

fn linkSdl3(step: *std.Build.Step.Compile, sdl3_lib: *std.Build.Step.Compile) void {
    step.linkLibrary(sdl3_lib);
    step.linkLibC();
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const regression_optimize =
        b.option(std.builtin.OptimizeMode, "regression-optimize", "Optimize mode for regression tests") orelse .ReleaseSafe;
    const version = @import("build.zig.zon").version;

    const zsdl = b.dependency("zsdl", .{});
    const chilli = b.dependency("chilli", .{});
    const minish = b.dependency("minish", .{});
    const sdl3_dep = b.dependency("sdl3", .{
        .target = target,
        .optimize = optimize,
    });
    const sdl3_lib = sdl3_dep.artifact("SDL3");
    const cpu_deps: CpuDeps = .{
        .rocket68 = b.dependency("rocket68", .{}),
        .jgz80 = b.dependency("jgz80", .{}),
    };
    const sandopolis_api = createSandopolisApiModule(b, target, optimize, cpu_deps);
    const regression_api = createSandopolisApiModule(b, target, regression_optimize, cpu_deps);
    const testing_api = createTestingApiModule(b, target, optimize, cpu_deps);
    const compare_ym_available = pathExists("external/Nuked-OPN2/ym3438.c");

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version);

    // Create the executable
    const exe = b.addExecutable(.{
        .name = "sandopolis",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zsdl3", .module = zsdl.module("zsdl3") },
                .{ .name = "chilli", .module = chilli.module("chilli") },
                .{ .name = "build_options", .module = build_options.createModule() },
            },
        }),
    });
    addExternalCpuCores(exe, b, cpu_deps);
    linkSdl3(exe, sdl3_lib);

    addStbTruetype(exe, b);

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
                .{ .name = "chilli", .module = chilli.module("chilli") },
                .{ .name = "build_options", .module = build_options.createModule() },
            },
        }),
    });
    addExternalCpuCores(exe_check, b, cpu_deps);
    linkSdl3(exe_check, sdl3_lib);
    addStbTruetype(exe_check, b);

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
    linkSdl3(unit_tests, sdl3_lib);

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
                .{ .name = "chilli", .module = chilli.module("chilli") },
                .{ .name = "build_options", .module = build_options.createModule() },
            },
        }),
    });
    addExternalCpuCores(frontend_tests, b, cpu_deps);
    linkSdl3(frontend_tests, sdl3_lib);
    addStbTruetype(frontend_tests, b);
    const frontend_run = b.addRunArtifact(frontend_tests);
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
            .optimize = regression_optimize,
            .imports = &.{
                .{ .name = "sandopolis_src", .module = regression_api },
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

    const compare_ym = b.addExecutable(.{
        .name = "compare-ym",
        .root_module = b.createModule(.{
            .root_source_file = if (compare_ym_available)
                b.path("tools/compare_ym.zig")
            else
                b.path("tools/compare_ym_unavailable.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "sandopolis_testing", .module = testing_api },
            },
        }),
    });
    addExternalCpuCores(compare_ym, b, cpu_deps);
    if (compare_ym_available) {
        compare_ym.addIncludePath(b.path("external/Nuked-OPN2"));
        compare_ym.root_module.addIncludePath(b.path("external/Nuked-OPN2"));
        compare_ym.addCSourceFiles(.{
            .root = b.path("external/Nuked-OPN2"),
            .files = &.{"ym3438.c"},
            .flags = &.{"-std=c11"},
        });
        compare_ym.linkLibC();
    }
    const compare_ym_run = b.addRunArtifact(compare_ym);
    if (b.args) |args| {
        compare_ym_run.addArgs(args);
    }
    const compare_ym_step = b.step("compare-ym", "Compare raw YM output against external/Nuked-OPN2");
    compare_ym_step.dependOn(&compare_ym_run.step);

    const dump_audio = b.addExecutable(.{
        .name = "dump-audio",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/dump_audio.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "sandopolis_testing", .module = testing_api },
            },
        }),
    });
    addExternalCpuCores(dump_audio, b, cpu_deps);
    dump_audio.addIncludePath(b.path("tmp/Genesis-Plus-GX/libretro/libretro-common/include"));
    dump_audio.root_module.addIncludePath(b.path("tmp/Genesis-Plus-GX/libretro/libretro-common/include"));
    dump_audio.linkLibC();
    const dump_audio_run = b.addRunArtifact(dump_audio);
    if (b.args) |args| {
        dump_audio_run.addArgs(args);
    }
    const dump_audio_step = b.step("dump-audio", "Dump headless audio to WAV using Sandopolis or Genesis Plus GX");
    dump_audio_step.dependOn(&dump_audio_run.step);

    const trace_sound_boot = b.addExecutable(.{
        .name = "trace-sound-boot",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/trace_sound_boot.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "sandopolis_testing", .module = testing_api },
            },
        }),
    });
    addExternalCpuCores(trace_sound_boot, b, cpu_deps);
    const trace_sound_boot_run = b.addRunArtifact(trace_sound_boot);
    if (b.args) |args| {
        trace_sound_boot_run.addArgs(args);
    }
    const trace_sound_boot_step = b.step("trace-sound-boot", "Trace M68K writes to the sound CPU bring-up regions");
    trace_sound_boot_step.dependOn(&trace_sound_boot_run.step);

    const trace_m68k_failure = b.addExecutable(.{
        .name = "trace-m68k-failure",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/trace_m68k_failure.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "sandopolis_testing", .module = testing_api },
            },
        }),
    });
    addExternalCpuCores(trace_m68k_failure, b, cpu_deps);
    const trace_m68k_failure_run = b.addRunArtifact(trace_m68k_failure);
    if (b.args) |args| {
        trace_m68k_failure_run.addArgs(args);
    }
    const trace_m68k_failure_step = b.step("trace-m68k-failure", "Trace the last M68K instructions before a bad CPU state");
    trace_m68k_failure_step.dependOn(&trace_m68k_failure_run.step);

    const trace_ym_writes = b.addExecutable(.{
        .name = "trace-ym-writes",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/trace_ym_writes.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "sandopolis_testing", .module = testing_api },
            },
        }),
    });
    addExternalCpuCores(trace_ym_writes, b, cpu_deps);
    trace_ym_writes.addIncludePath(b.path("tmp/Genesis-Plus-GX/libretro/libretro-common/include"));
    trace_ym_writes.root_module.addIncludePath(b.path("tmp/Genesis-Plus-GX/libretro/libretro-common/include"));
    trace_ym_writes.linkLibC();
    const trace_ym_writes_run = b.addRunArtifact(trace_ym_writes);
    if (b.args) |args| {
        trace_ym_writes_run.addArgs(args);
    }
    const trace_ym_writes_step = b.step("trace-ym-writes", "Dump decoded YM register writes from Sandopolis or Genesis Plus GX");
    trace_ym_writes_step.dependOn(&trace_ym_writes_run.step);

    const trace_z80_audio_ops = b.addExecutable(.{
        .name = "trace-z80-audio-ops",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/trace_z80_audio_ops.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "sandopolis_testing", .module = testing_api },
            },
        }),
    });
    addExternalCpuCores(trace_z80_audio_ops, b, cpu_deps);
    const trace_z80_audio_ops_run = b.addRunArtifact(trace_z80_audio_ops);
    if (b.args) |args| {
        trace_z80_audio_ops_run.addArgs(args);
    }
    const trace_z80_audio_ops_step = b.step("trace-z80-audio-ops", "Dump raw Z80 audio-mapped writes from Sandopolis");
    trace_z80_audio_ops_step.dependOn(&trace_z80_audio_ops_run.step);

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

    const test_step_all = b.step("test", "Run unit, frontend, integration, regression, and property-based tests");
    test_step_all.dependOn(&unit_run.step);
    test_step_all.dependOn(&frontend_run.step);
    test_step_all.dependOn(&integration_run.step);
    test_step_all.dependOn(&regression_run.step);
    test_step_all.dependOn(&property_run.step);

    // WebAssembly build for browser deployment
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .wasi,
        .cpu_features_add = std.Target.wasm.featureSet(&.{.exception_handling}),
    });
    const wasm_exe = b.addExecutable(.{
        .name = "sandopolis",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wasm.zig"),
            .target = wasm_target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "build_options", .module = build_options.createModule() },
            },
        }),
    });
    wasm_exe.entry = .disabled;
    wasm_exe.rdynamic = true;
    addExternalCpuCores(wasm_exe, b, cpu_deps);
    wasm_exe.addCSourceFiles(.{
        .files = &.{"src/wasm_stubs.c"},
        .flags = &.{"-std=c11"},
    });
    const wasm_install = b.addInstallArtifact(wasm_exe, .{
        .dest_dir = .{ .override = .{ .custom = "web" } },
        .dest_sub_path = "sandopolis.wasm",
    });
    const wasm_step = b.step("wasm", "Build WebAssembly module for browser deployment");
    wasm_step.dependOn(&wasm_install.step);
}
