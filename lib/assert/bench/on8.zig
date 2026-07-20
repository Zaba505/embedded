//! Benchmark root: 8 assertions, enabled. Paired with off8 (identical
//! scaffolding, asserts compiled out) so on8.text - off8.text is the cost of
//! exactly 8 assertions. See ../README.md.
export fn _start() callconv(.C) noreturn {
    @import("body.zig").run(8, true);
}
