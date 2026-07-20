//! Benchmark root: the same 8 assertions, disabled. Its .text is the baseline
//! the enabled builds are measured against. See ../README.md.
export fn _start() callconv(.C) noreturn {
    @import("body.zig").run(8, false);
}
