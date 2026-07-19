const std = @import("std");

pub fn build(b: *std.Build) void {
    // The target is fixed hardware, so it is hardcoded rather than exposed via
    // standardTargetOptions. Consequence worth knowing: the zig Dagger module's
    // --target flag becomes -Dtarget=, which `zig build` would reject as an
    // unknown option. Pass --optimize if you like; never --target.
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .thumb,
        .os_tag = .freestanding,
        .abi = .eabi,
        .cpu_model = .{ .explicit = &std.Target.arm.cpu.cortex_m3 },
    });

    // Deliberately not standardOptimizeOption: given a preferred_optimize_mode
    // it still returns .Debug unless -Drelease is passed, and a Debug build of
    // even this program overflows the 256K rom region by ~35K once Zig links in
    // its panic and formatting machinery. Default to ReleaseSmall and let
    // -Doptimize= (the zig module's --optimize) override it.
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Optimization mode (default: ReleaseSmall; Debug does not fit in flash)",
    ) orelse .ReleaseSmall;

    const exe = b.addExecutable(.{
        .name = "blinky.elf",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        // No OS, no threads: keeps TLS and the threading machinery out entirely.
        .single_threaded = true,
    });

    exe.setLinkerScript(b.path("link.ld"));

    // There is no _start. Execution begins at the reset vector, and the ELF
    // entry point is set to the same symbol so the header is not misleading.
    exe.entry = .{ .symbol_name = "resetHandler" };

    b.installArtifact(exe);
}
