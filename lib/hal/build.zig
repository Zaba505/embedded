const std = @import("std");

pub fn build(b: *std.Build) void {
    // Host by default: the seam exists so logic that touches hardware can be
    // built and run natively, and this package's own tests are the first
    // instance of that -- the contract checks, the wrappers' derived logic, and
    // both backend families run here with no board attached. The on-target
    // evidence, that the seam costs nothing, comes from the `bench` step below.
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Export the seam as a module so any project can depend on it once a
    // full-repo build flow exists:
    //
    //     const hal_dep = b.dependency("hal", .{});
    //     exe.root_module.addImport("hal", hal_dep.module("hal"));
    //
    // then, at the use site, bind the logic to whichever backend the build is
    // for -- the whole point of the seam:
    //
    //     const hal = @import("hal");
    //     const Gate = if (builtin.os.tag == .freestanding)
    //         hal.mmio.SetClearOutput(.{ ... })  // real silicon
    //     else
    //         hal.fake.Output;                   // the host stand-in
    //
    // The bench images below consume it through this exact seam, so the size
    // benchmark doubles as a working example of depending on the module.
    const hal_module = b.addModule("hal", .{
        .root_source_file = b.path("hal.zig"),
    });

    // Host unit tests. `hal.zig` is the root, and its `refAllDeclsRecursive`
    // pulls in `mmio.zig` and `fake.zig`, so one test binary covers all three
    // files -- including their own `test` blocks. This step is also the
    // package's strictest-diagnostics gate (style guide §2.4): compiling the
    // tests type-checks every declaration, and a `comptime` contract check that
    // should fail is a build error rather than a runtime one.
    const tests = b.addTest(.{
        .root_source_file = b.path("hal.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run the hardware-abstraction seam's unit tests");
    test_step.dependOn(&run_tests.step);

    // --- bench: the "the seam is free" evidence --------------------------
    // Two roots implementing the SAME logic -- one through the seam, one as
    // hand-written register pokes -- built for two different architectures. The
    // .text delta between the pair is the seam's runtime cost, and the claim is
    // that it is exactly zero. See bench/measure.sh, which builds this step and
    // reads each image's .text.
    //
    // Two architectures rather than one because "architecture-neutral" is a
    // claim about more than one machine: Cortex-M3 (thumb, the Arduino Due's
    // SAM3X8E) and Cortex-A53 (aarch64, the Raspberry Pi 3B's BCM2837) differ
    // in word size, register file, addressing and calling convention, and the
    // same seam compiles for both from the same source. Kept off the default
    // install step so a plain `zig build` stays a host-only test build.
    const bench_targets = [_]struct { name: []const u8, query: std.Target.Query }{
        .{
            .name = "cortex-m3",
            .query = .{
                .cpu_arch = .thumb,
                .os_tag = .freestanding,
                .abi = .eabi,
                .cpu_model = .{ .explicit = &std.Target.arm.cpu.cortex_m3 },
            },
        },
        .{
            .name = "cortex-a53",
            .query = .{
                .cpu_arch = .aarch64,
                .os_tag = .freestanding,
                .abi = .none,
                .cpu_model = .{ .explicit = &std.Target.aarch64.cpu.cortex_a53 },
            },
        },
    };

    const bench_step = b.step("bench", "Build the seam-vs-direct size benchmark images");
    const bench_roots = [_][]const u8{ "seam", "direct" };
    for (bench_targets) |bench_target| {
        const resolved = b.resolveTargetQuery(bench_target.query);
        for (bench_roots) |root| {
            const exe = b.addExecutable(.{
                .name = b.fmt("{s}-{s}", .{ root, bench_target.name }),
                .root_source_file = b.path(b.fmt("bench/{s}.zig", .{root})),
                .target = resolved,
                // Measured at whatever -Doptimize is passed; CI passes
                // ReleaseSmall, the mode firmware ships in and the one where an
                // abstraction has to earn its keep.
                .optimize = optimize,
                .single_threaded = true,
            });
            exe.root_module.addImport("hal", hal_module);
            // No _start-providing runtime here; the bench roots export their own.
            exe.entry = .{ .symbol_name = "_start" };
            bench_step.dependOn(&b.addInstallArtifact(exe, .{}).step);
        }
    }
}
