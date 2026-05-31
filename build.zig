pub fn build(b: *std.Build) void {
    const target = target: {
        var result = b.standardTargetOptions(.{});
        if (result.result.os.tag != .windows) {
            std.debug.panic(
                "Mostty is Windows-only; use -Dtarget=x86_64-windows-msvc or build on Windows without -Dtarget",
                .{},
            );
        }
        // On Windows, default to MSVC ABI. The ghostty-vt module's C++ source
        // files (src/simd/*.cpp) are compiled with MSVC ABI because ghostty's
        // own build.zig forces it, so the exe ABI must match or clang's
        // intrinsics headers break under MSVC SDK include paths. Mirror the
        // override from ghostty's src/build/Config.zig.
        if (result.result.os.tag == .windows and result.query.abi == null) {
            var query = result.query;
            query.abi = .msvc;
            result = b.resolveTargetQuery(query);
        }
        // Mostty's Windows build only supports MSVC ABI today: the WinMain
        // shim, libcmt entry point, and ghostty-vt's C++ ABI all assume it.
        // Fail fast on explicit Windows-GNU to avoid a confusing link error.
        if (result.result.os.tag == .windows and result.result.abi != .msvc) {
            std.debug.panic(
                "Mostty's Windows build requires MSVC ABI; use -Dtarget=x86_64-windows-msvc or omit -Dtarget",
                .{},
            );
        }
        break :target result;
    };
    const optimize = b.standardOptimizeOption(.{});

    const vt = b.dependency("ghostty", .{}).module("ghostty-vt");
    const z2d = b.dependency("z2d", .{}).module("z2d");

    const main = b.path("src/mosttywindows.zig");
    const exe = b.addExecutable(.{
        .name = "Mostty",
        .root_module = b.createModule(.{
            .root_source_file = main,
            .target = target,
            .optimize = optimize,
        }),
        .win32_manifest = b.path("src/win32/mostty.manifest"),
    });
    addImports(b, exe.root_module, vt, z2d);

    exe.addWin32ResourceFile(.{
        .file = b.path("src/win32/mostty.rc"),
    });
    exe.subsystem = .Windows;

    const install = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&install.step);

    // Ship the bundled themes next to the exe so a config's `theme = <name>`
    // resolves via the <exeDir>/themes/<name> lookup. exe installs to bin/, so
    // exeDir is zig-out/bin and the themes must land in zig-out/bin/themes.
    const install_themes = b.addInstallDirectory(.{
        .source_dir = b.path("themes"),
        .install_dir = .bin,
        .install_subdir = "themes",
    });
    b.getInstallStep().dependOn(&install_themes.step);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(&install.step);
    if (b.args) |a| run.addArgs(a);
    b.step("run", "").dependOn(&run.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = main,
            .target = target,
            .optimize = optimize,
        }),
    });
    addImports(b, tests.root_module, vt, z2d);
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run unit tests").dependOn(&run_tests.step);
}

fn addImports(
    b: *std.Build,
    mod: *std.Build.Module,
    vt: *std.Build.Module,
    z2d: *std.Build.Module,
) void {
    mod.addImport("vt", vt);
    mod.addImport("z2d", z2d);
    if (b.lazyDependency("win32", .{})) |win32_dep| {
        mod.addImport("win32", win32_dep.module("win32"));
        mod.addIncludePath(b.path("src/win32"));
    }
}

const std = @import("std");
