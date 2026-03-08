const std = @import("std");

const CpuDeps = struct {
    rocket68: *std.Build.Dependency,
    jgz80: *std.Build.Dependency,
};

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
                .{ .name = "build_options", .module = build_options.createModule() },
            },
        }),
    });
    addExternalCpuCores(exe, b, cpu_deps);
    linkSdl3(exe, sdl3_lib);

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
                .{ .name = "build_options", .module = build_options.createModule() },
            },
        }),
    });
    addExternalCpuCores(exe_check, b, cpu_deps);
    linkSdl3(exe_check, sdl3_lib);

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
                .{ .name = "build_options", .module = build_options.createModule() },
            },
        }),
    });
    addExternalCpuCores(frontend_tests, b, cpu_deps);
    linkSdl3(frontend_tests, sdl3_lib);
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
