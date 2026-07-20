//! Shared body for the size-delta benchmark. See ../README.md, "Evidence".
//!
//! The three roots next to this file (on8, on16, off8) differ only in the
//! `count` and `enabled` they pass to `run`. Everything else -- the volatile
//! reads, the accumulation, the sink -- is identical, so the `.text` delta
//! between two builds is exactly the cost of the assertions and nothing else.

const asrt = @import("assert");

/// The failure route the benchmark measures: a bare trap. Every assertion in
/// every build below branches here, so the builds share one trap site and the
/// per-assertion cost is just the compare and the branch that reach it.
fn trap() noreturn {
    @trap();
}

/// Run `count` distinct assertions, then spin.
///
/// Each assertion tests a value read through a volatile pointer, so the
/// optimizer can neither fold the read away nor prove the condition, and each
/// site uses a distinct address and a distinct compare immediate, so the sites
/// are not merged into one. `enabled` selects whether the asserts are compiled
/// in at all.
pub inline fn run(comptime count: usize, comptime enabled: bool) noreturn {
    const A = asrt.Assert(.{ .enabled = enabled, .onFailure = &trap });

    // A block of made-up MMIO addresses. Never dereferenced on real silicon --
    // this image only exists to be measured, never flashed.
    const mmio: usize = 0x2000_0000;

    var acc: u32 = 0;
    inline for (0..count) |i| {
        const reg: *volatile u32 = @ptrFromInt(mmio + i * 4);
        const value = reg.*;
        A.assert(value != 0xDEAD_0000 +% @as(u32, @intCast(i)));
        acc +%= value;
    }

    // Consume `acc` through a volatile sink so none of the reads -- and so none
    // of the assertions guarding them -- are dead-code-eliminated.
    const sink: *volatile u32 = @ptrFromInt(mmio + 0x1000);
    sink.* = acc;

    while (true) {}
}
