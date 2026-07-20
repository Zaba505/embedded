//! Benchmark root: the same 16 assertions, disabled. Paired with on16 to
//! isolate the cost of 16 assertions from identical scaffolding. See
//! ../README.md.
export fn _start() callconv(.C) noreturn {
    @import("body.zig").run(16, false);
}
