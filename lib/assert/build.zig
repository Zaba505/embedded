const std = @import("std");

pub fn build(b: *std.Build) void {
    // Host by default: the primitive is architecture-agnostic, so its unit
    // tests build and run natively. The freestanding, on-target evidence -- the
    // size delta that proves a failed assertion is a bare trap -- comes from the
    // `bench` step below, built for a real MCU target.
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Export the primitive as a module so any project in this repo can depend
    // on it once a full-repo build flow exists:
    //
    //     const assert_dep = b.dependency("assert", .{});
    //     exe.root_module.addImport("assert", assert_dep.module("assert"));
    //
    // then `const assert = @import("assert").assert;` at the use site. The
    // bench images below consume it through this exact seam, so the benchmark
    // doubles as a working example of depending on the module.
    const assert_module = b.addModule("assert", .{
        .root_source_file = b.path("assert.zig"),
    });

    // Host unit tests of the pure logic (the on/off knob, the pass-through
    // path). The failure path is a noreturn trap and is verified on-target by
    // the size-delta gate in CI, not here.
    const tests = b.addTest(.{
        .root_source_file = b.path("assert.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run the assert primitive's unit tests");
    test_step.dependOn(&run_tests.step);

    // --- bench: the size-delta evidence ----------------------------------
    // Freestanding images that differ only in how many assertions they run and
    // whether the asserts are enabled, so the .text delta between them is
    // exactly the cost of an assertion. See bench/README-less note and
    // bench/measure.sh, which builds this step and reads each image's .text.
    //
    // The target is a representative MCU (Cortex-M3), not a special one: any
    // freestanding target shows the same shape because @trap() lowers to
    // whatever trap instruction the target has. Kept off the default install
    // step so a plain `zig build` stays a host-only test build.
    const bench_target = b.resolveTargetQuery(.{
        .cpu_arch = .thumb,
        .os_tag = .freestanding,
        .abi = .eabi,
        .cpu_model = .{ .explicit = &std.Target.arm.cpu.cortex_m3 },
    });

    const bench_step = b.step("bench", "Build the size-delta benchmark images");
    const bench_roots = [_][]const u8{ "off8", "on8", "off16", "on16" };
    for (bench_roots) |name| {
        const exe = b.addExecutable(.{
            .name = name,
            .root_source_file = b.path(b.fmt("bench/{s}.zig", .{name})),
            .target = bench_target,
            // Measured at whatever -Doptimize is passed; CI passes ReleaseSmall,
            // the mode the firmware ships in and the one where the primitive has
            // to earn its keep.
            .optimize = optimize,
            .single_threaded = true,
        });
        exe.root_module.addImport("assert", assert_module);
        // No _start-providing runtime here; the bench roots export their own.
        exe.entry = .{ .symbol_name = "_start" };
        const install = b.addInstallArtifact(exe, .{});
        bench_step.dependOn(&install.step);
    }
}
