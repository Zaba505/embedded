const std = @import("std");

pub fn build(b: *std.Build) void {
    // Host by default: the helpers are architecture-agnostic and generic over
    // the register width and the asserter, so their whole logic -- including the
    // failure path, thanks to a recording test asserter -- builds and runs
    // natively. There is no on-target artifact to measure here (contrast
    // lib/assert's size gate): readback adds a volatile load and a compare, and
    // the cost of the *failure* branch is lib/assert's already-proven bare trap.
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Export the helpers as a module so any project can depend on them once a
    // full-repo build flow exists:
    //
    //     const readback_dep = b.dependency("readback", .{});
    //     exe.root_module.addImport("readback", readback_dep.module("readback"));
    //
    // then, at the use site, bind them to the project's asserter (lib/assert):
    //
    //     const rb = @import("readback").Readback(@import("assert"));
    //
    // readback takes the asserter as a parameter rather than importing
    // lib/assert directly, so the two libraries stay independently buildable
    // (each through its own `--source` dir) and the failure state stays the
    // project's choice -- see readback.zig for the reasoning.
    _ = b.addModule("readback", .{
        .root_source_file = b.path("readback.zig"),
    });

    // Host unit tests of the pure logic (the masked-compare predicate, the
    // width extraction) and of both readback outcomes (a matching readback
    // passes; a dropped write / unraised status bit is caught) via a recording
    // test asserter. This step is also the library's strictest-diagnostics gate
    // (style guide §2.4): compiling the tests type-checks the code, and the
    // `refAllDeclsRecursive` test forces every public declaration through the
    // compiler, so a decl no test calls cannot ship un-checked.
    const tests = b.addTest(.{
        .root_source_file = b.path("readback.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run the readback helpers' unit tests");
    test_step.dependOn(&run_tests.step);
}
