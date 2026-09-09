const std = @import("std");

/// Fucina's `-Dblas` choices, re-declared here so the option passes through
/// by name; fucina's default (Accelerate on macOS, auto-detected on Linux)
/// applies when the flag is absent. `none` builds with no system library.
const BlasKind = enum { none, accelerate, openblas, mkl, blis, nvpl, blas };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const blas = b.option(BlasKind, "blas", "Fucina BLAS provider: none, accelerate, openblas, mkl, blis, nvpl, blas (default: fucina's platform default)");

    // The tensor library. Its exported module carries its own link inputs
    // (BLAS frameworks/libraries) in dependency builds.
    const fucina_dep = if (blas) |kind|
        b.dependency("fucina", .{ .target = target, .optimize = optimize, .blas = kind })
    else
        b.dependency("fucina", .{ .target = target, .optimize = optimize });
    const fucina = fucina_dep.module("fucina");

    const exe = b.addExecutable(.{
        .name = "nam-zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("fucina", fucina);
    configureNative(exe);
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run nam-zig (arguments after --; no command opens the amp menu)").dependOn(&run.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.addImport("fucina", fucina);
    configureNative(tests);
    b.step("test", "Run the unit tests").dependOn(&b.addRunArtifact(tests).step);

    // `zig build app`: the macOS application bundle (zig-out/nam-zig.app),
    // which is what gives the microphone permission prompt the app's own
    // name. Ad-hoc signed when codesign is available.
    const app_step = b.step("app", "Assemble the macOS application bundle (zig-out/nam-zig.app)");
    const app_bin = b.addInstallArtifact(exe, .{ .dest_dir = .{ .override = .{ .custom = "nam-zig.app/Contents/MacOS" } } });
    const app_plist = b.addInstallFile(b.path("packaging/Info.plist"), "nam-zig.app/Contents/Info.plist");
    const app_pkginfo = b.addInstallFile(b.path("packaging/PkgInfo"), "nam-zig.app/Contents/PkgInfo");
    const app_icon = b.addInstallFile(b.path("packaging/nam-zig.icns"), "nam-zig.app/Contents/Resources/nam-zig.icns");
    const sign = b.addSystemCommand(&.{ "codesign", "--force", "--deep", "--sign", "-", b.getInstallPath(.prefix, "nam-zig.app") });
    sign.step.dependOn(&app_bin.step);
    sign.step.dependOn(&app_plist.step);
    sign.step.dependOn(&app_pkginfo.step);
    sign.step.dependOn(&app_icon.step);
    app_step.dependOn(&sign.step);
}

/// The device layers: the vendored miniaudio build (one
/// MINIAUDIO_IMPLEMENTATION translation unit, `src/audio_shim.c`), the
/// CoreMIDI shim (`src/midi_shim.c`, stubs off macOS), the window shim
/// (`src/window_shim.m`: AppKit + WebKit + the microphone-permission query;
/// `src/window_shim.c` elsewhere: GTK/WebKitGTK loaded at runtime when
/// present), libc, and the frameworks on macOS (MA_NO_RUNTIME_LINKING in
/// `miniaudio_config.h`); elsewhere miniaudio dlopens its backend at
/// runtime through libc.
fn configureNative(step: *std.Build.Step.Compile) void {
    const module = step.root_module;
    module.link_libc = true;
    for ([_][]const u8{ "src/audio_shim.c", "src/midi_shim.c" }) |source| {
        module.addCSourceFile(.{
            .file = step.step.owner.path(source),
            .flags = &.{ "-fno-sanitize=undefined", "-O2" },
        });
    }
    const target = module.resolved_target.?.result;
    if (target.os.tag == .macos) {
        module.addCSourceFile(.{
            .file = step.step.owner.path("src/window_shim.m"),
            .flags = &.{ "-fno-sanitize=undefined", "-fobjc-arc", "-O2" },
        });
        for ([_][]const u8{ "CoreFoundation", "CoreAudio", "AudioToolbox", "CoreMIDI", "Cocoa", "WebKit", "AVFoundation" }) |framework| {
            module.linkFramework(framework, .{});
        }
    } else {
        module.addCSourceFile(.{
            .file = step.step.owner.path("src/window_shim.c"),
            .flags = &.{ "-fno-sanitize=undefined", "-O2" },
        });
        if (target.os.tag == .linux) module.linkSystemLibrary("dl", .{});
    }
}
