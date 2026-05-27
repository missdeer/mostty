pub fn build(b: *std.Build) void {
    const target = target: {
        var result = b.standardTargetOptions(.{});
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

    const appicon_dep = b.dependency("appicon", .{});
    const x11_mod = if (b.lazyDependency("x11", .{})) |dep| dep.module("x11") else null;
    const appicon_mod = appicon.createModule(b, appicon_dep, .{ .x11 = x11_mod });
    const mosttyicon = appicon.createLinuxIcon(b, appicon_dep, appicon_mod, &.{
        .{ .source = b.path("src/mostty.png"), .sizes = &.{ 16, 32, 48, 128 } },
    });

    const main = b.path(switch (target.result.os.tag) {
        .windows => "src/mosttywindows.zig",
        else => "src/mostty.zig",
    });
    const exe = b.addExecutable(.{
        .name = "mostty",
        .root_module = b.createModule(.{
            .root_source_file = main,
            .target = target,
            .optimize = optimize,
            // Windows uses std.Thread for the ConPTY read thread.
            .single_threaded = if (target.result.os.tag == .windows) null else true,
        }),
        .win32_manifest = b.path("src/win32/mostty.manifest"),
    });
    addImports(b, target.result, exe.root_module, mosttyicon, vt, z2d);

    // ghostty-vt module brings in C++ source files (src/simd/*.cpp). On
    // non-MSVC targets we explicitly link libc/libcpp so those translation
    // units find their headers. On MSVC the MSVC SDK headers already cover
    // both C and C++ (pulled in transitively via ghostty-vt's own libC link),
    // and adding our own linkLibC here is redundant.
    if (target.result.abi != .msvc) {
        exe.linkLibC();
        exe.linkLibCpp();
    }

    exe.addWin32ResourceFile(.{
        .file = b.path("src/win32/mostty.rc"),
        // TODO: add include path if/when we use appicon to generate our .ico file
        // .include_paths = &.{ico.dirname()},
    });
    if (target.result.os.tag == .windows) {
        exe.subsystem = .Windows;
    }

    const install = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&install.step);

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
    addImports(b, target.result, tests.root_module, mosttyicon, vt, z2d);
    if (target.result.abi != .msvc) {
        tests.linkLibC();
        tests.linkLibCpp();
    }
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run unit tests").dependOn(&run_tests.step);
}

fn addImports(
    b: *std.Build,
    target: std.Target,
    mod: *std.Build.Module,
    mosttyicon: *std.Build.Module,
    vt: *std.Build.Module,
    z2d: *std.Build.Module,
) void {
    mod.addImport("mosttyicon", mosttyicon);
    mod.addImport("vt", vt);
    mod.addImport("z2d", z2d);
    switch (target.os.tag) {
        .windows => if (b.lazyDependency("win32", .{})) |win32_dep| {
            mod.addImport("win32", win32_dep.module("win32"));
            mod.addIncludePath(b.path("src/win32"));
        },
        else => {
            if (b.lazyDependency("x11", .{})) |x11_dep| {
                mod.addImport("x11", x11_dep.module("x11"));
            }
            if (b.lazyDependency("TrueType", .{})) |true_type_dep| {
                mod.addImport("TrueType", true_type_dep.module("TrueType"));
            }
        },
    }
    switch (target.os.tag) {
        .linux => if (b.lazyDependency("wayland", .{})) |wayland_dep| {
            mod.addImport("wl", wayland_dep.module("wl"));
        },
        else => {},
    }
}

const builtin = @import("builtin");
const std = @import("std");
const appicon = @import("appicon");
