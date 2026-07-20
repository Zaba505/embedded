//! Benchmark root: 16 assertions, enabled. Paired with off16, a second data
//! point confirming the per-assertion cost (on16.text - off16.text) / 16 is
//! flat as the count grows. See ../README.md.
export fn _start() callconv(.C) noreturn {
    @import("body.zig").run(16, true);
}
