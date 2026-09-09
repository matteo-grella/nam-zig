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
    configureAudio(exe);
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
    configureAudio(tests);
    b.step("test", "Run the unit tests").dependOn(&b.addRunArtifact(tests).step);
}

/// The audio and MIDI device layer: the vendored miniaudio build (one
/// MINIAUDIO_IMPLEMENTATION translation unit, `src/audio_shim.c`) plus the
/// CoreMIDI shim (`src/midi_shim.c`, stubs off macOS), libc, and the
/// CoreAudio/CoreMIDI frameworks on macOS (MA_NO_RUNTIME_LINKING in
/// `miniaudio_config.h`); elsewhere miniaudio dlopens its backend at
/// runtime through libc.
fn configureAudio(step: *std.Build.Step.Compile) void {
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
        for ([_][]const u8{ "CoreFoundation", "CoreAudio", "AudioToolbox", "CoreMIDI" }) |framework| {
            module.linkFramework(framework, .{});
        }
    }
}
