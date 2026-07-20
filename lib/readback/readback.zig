//! Write-then-verify (readback) helpers for peripheral register configuration.
//!
//! On a memory-mapped target a write to a control register can silently do
//! nothing -- the peripheral's clock is gated, the register is write-protected,
//! or the address is simply wrong. The language cannot hand you an error for a
//! dropped write: the store returns nothing and does nothing. So the failure
//! stays invisible until the device misbehaves much later, far from the cause.
//!
//! Tiger Style's *pair assertions* map straight onto this: "for every property
//! you want to enforce, find at least two different code paths where an
//! assertion can be added." TigerBeetle's pair is write-side / read-side around
//! the disk; firmware's is **write-then-readback around a register**. After
//! configuring a peripheral you read the corresponding status back and assert
//! the change took, so the write path and the readback path are two independent
//! checks of the same property, and the gap between them is exactly where the
//! silent-no-op lives. This file is the reusable form of that pattern.
//!
//! Four things it deliberately does, and does not, do -- each so it "serves
//! every future project on any architecture," the same contract lib/assert
//! holds itself to:
//!
//!   1. It names no CPU, peripheral, clock, address, or memory map. A helper
//!      takes a `*volatile` pointer the caller already has and an expected
//!      value the caller already knows; the register's width is read off the
//!      pointer type, so the same code serves an 8-, 16-, or 32-bit register
//!      file on any target. It compiles and unit-tests on the host, the
//!      clearest proof it assumes no particular silicon.
//!
//!   2. It does not choose the failure state. A failed readback routes through
//!      an *asserter* the caller supplies (`Readback(asserter)`), so the
//!      halt-vs-safe-state-vs-reset decision stays the project's -- the same
//!      delegation lib/assert makes, for the same reason (see that package and
//!      issue #12). This file will not smuggle in a `@trap()` default, because
//!      doing so would decide the safe state on the project's behalf.
//!
//!   3. It is for the **configuration phase, not hot paths.** A readback is an
//!      extra volatile load and a compare on every call, and a two-register
//!      verify serializes against the peripheral. That is a fine price paid
//!      once while bringing a peripheral up, and the wrong price to pay in an
//!      ISR or a sample loop. Configure with these; run without them.
//!
//!   4. It does not pretend readback is universal. Readback is *invalid* for
//!      several register kinds, and misapplying it there manufactures a bug
//!      rather than catching one. Those cases are spelled out below and in the
//!      README; the helpers check what you tell them to, so telling them to
//!      read a write-only or read-to-clear register is on the caller.
//!
//! ## When readback is INVALID -- do not use these helpers on:
//!
//!   - **Write-only registers.** Many "action" or trigger registers (a
//!     software-reset kick, a command FIFO port) read back zero or garbage;
//!     the write is real but there is nothing to confirm at that address.
//!     Verify via a *separate* status register instead (`write_status_verify`),
//!     which is the common and correct shape: the SAM3X8E's `PMC_PCER0` (enable
//!     a peripheral clock) is write-only, and the clock state is confirmed by
//!     reading `PMC_PCSR0`, a different register.
//!
//!   - **Read-to-clear / read-side-effect registers.** Reading some status
//!     registers *changes* them -- an interrupt-status register that clears the
//!     bits it reports, or SysTick's `SYST_CSR`, whose `COUNTFLAG` clears on
//!     read (the blinky *relies* on that read to re-arm its poll). A readback
//!     here consumes the very state you are trying to observe and corrupts the
//!     peripheral. Never point a helper at one.
//!
//!   - **Bits hardware owns.** A field the peripheral updates itself (a busy
//!     flag, a live FIFO level, a free-running counter) will not read back the
//!     value you wrote. Confirm only the bits *you* set: pass a `mask` that
//!     covers your configuration bits and excludes the hardware-owned ones.
//!
//!   - **Write-1-to-clear bits.** A `W1C` status bit reads back 0 after a
//!     successful clear, not the 1 you wrote. Model it as a clear
//!     (`verify(reg, 0, mask)` after the write), not a full-word readback.

const std = @import("std");

/// Build readback helpers bound to a specific `asserter`.
///
/// `asserter` is any namespace exposing `pub inline fn assert(ok: bool) void`
/// -- exactly lib/assert's shape, so the intended wiring is one line at the top
/// of a driver:
///
///     const asrt = @import("assert");
///     const rb = @import("readback").Readback(asrt); // project's default route
///     // or a distinct route for config faults:
///     // const rb = @import("readback").Readback(asrt.Assert(.{ ... }));
///
/// Held as a comptime `type` so every `assert` the helpers emit is a direct
/// branch to the project's handler, not an indirect call, and so a disabled
/// asserter elides the readback's *compare* (though not its volatile load; see
/// each helper). The asserter is a parameter rather than an import because the
/// failure state must stay the project's choice (point 2 above): this package
/// provides the mechanism and never the policy.
pub fn Readback(comptime asserter: type) type {
    return struct {
        /// Read `reg` and assert its `mask` bits equal `expected`'s -- a bare
        /// readback assertion with no write of its own. Use it to confirm a
        /// configuration whose write happened elsewhere: a set/clear register
        /// pair (`PIO_SODR`/`PIO_CODR`) whose effect shows in a third status
        /// register, or a hardware-raised "ready"/"locked"/"enabled" bit.
        ///
        /// The load is `volatile`, so it is a real bus read even when the
        /// asserter is disabled; that read can itself have side effects, so
        /// heed the read-to-clear caveat above.
        pub inline fn verify(
            reg: anytype,
            expected: Word(@TypeOf(reg)),
            mask: Word(@TypeOf(reg)),
        ) void {
            asserter.assert(holds(reg.*, expected, mask));
        }

        /// Write the whole word `want` to `reg`, then assert every bit reads
        /// back as written. The strict form, for a register you fully own with
        /// no reserved, hardware-owned, or write-1-to-clear bits. When any bit
        /// is not yours to confirm, reach for `write_verify_masked` instead --
        /// a full-word readback of such a register asserts against bits the
        /// hardware controls and will fire spuriously.
        pub inline fn write_verify(reg: anytype, want: Word(@TypeOf(reg))) void {
            const all = ~@as(Word(@TypeOf(reg)), 0);
            write_verify_masked(reg, want, all);
        }

        /// Write the whole word `want` to `reg`, then assert only the `mask`
        /// bits read back as written -- the everyday form. `mask` is the set of
        /// bits *you* configured and can trust to read back; leave the reserved
        /// and hardware-owned bits out of it. Writing the full word while
        /// verifying a subset is deliberate: you still set the whole register,
        /// you just do not claim the parts hardware owns took your value.
        pub inline fn write_verify_masked(
            reg: anytype,
            want: Word(@TypeOf(reg)),
            mask: Word(@TypeOf(reg)),
        ) void {
            reg.* = want;
            asserter.assert(holds(reg.*, want, mask));
        }

        /// Write `want` to a configuration register `cfg`, then confirm the
        /// change via a **separate** status register `status`: assert its
        /// `mask` bits equal `expected`. This is the headline case, and the
        /// only valid shape for a write-only `cfg` -- reading `cfg` back would
        /// be meaningless, so the readback is aimed at the register the
        /// peripheral actually reflects its state in.
        ///
        /// The canonical instance: write a peripheral's ID bit to `PMC_PCER0`
        /// (write-only) to ungate its clock, then read `PMC_PCSR0` and assert
        /// that clock is on *before* trusting any of the peripheral's own
        /// registers -- because a write to a clock-gated peripheral is silently
        /// dropped, the exact bug this helper exists to make loud.
        pub inline fn write_status_verify(
            cfg: anytype,
            want: Word(@TypeOf(cfg)),
            status: anytype,
            expected: Word(@TypeOf(status)),
            mask: Word(@TypeOf(status)),
        ) void {
            cfg.* = want;
            asserter.assert(holds(status.*, expected, mask));
        }

        /// Read-modify-write to set `bits` in `reg`, then assert they read back
        /// set. The everyday "OR in these config bits, and prove they stuck"
        /// operation. Invalid on a register with read-side effects or
        /// hardware-owned bits inside `bits` (see the caveats above): the read
        /// half of the RMW would disturb the peripheral or the readback would
        /// check a bit you do not own.
        pub inline fn set_bits(reg: anytype, bits: Word(@TypeOf(reg))) void {
            reg.* = reg.* | bits;
            asserter.assert(holds(reg.*, bits, bits));
        }

        /// Read-modify-write to clear `bits` in `reg`, then assert they read
        /// back clear -- the negative-space partner of `set_bits`. Note this is
        /// a plain read-then-clear, *not* a write-1-to-clear: for a `W1C`
        /// register write the 1s directly and confirm with `verify(reg, 0,
        /// bits)`, since RMW-ing a `W1C` register would clear unrelated pending
        /// bits the read observed.
        pub inline fn clear_bits(reg: anytype, bits: Word(@TypeOf(reg))) void {
            reg.* = reg.* & ~bits;
            asserter.assert(holds(reg.*, 0, bits));
        }
    };
}

/// The masked-compare predicate every helper decides on: do `read`'s `mask`
/// bits match `expected`'s? Factored out as a pure function so the host tests
/// can check both its true and its false answer directly -- the actual
/// branch-to-safe-state on a false answer is the asserter's job, proven by
/// lib/assert, and cannot be observed from a host test.
fn holds(read: anytype, expected: @TypeOf(read), mask: @TypeOf(read)) bool {
    return read & mask == expected & mask;
}

/// The register's word type, read off the `*volatile Word` pointer the caller
/// passes. A comptime negative-space check (style guide §5.2/§5.6): it rejects
/// anything that is not a volatile pointer to an unsigned integer with a build
/// error, so a non-volatile pointer -- whose readback the optimizer could elide,
/// silently defeating the whole check -- can never reach a helper.
fn Word(comptime Ptr: type) type {
    const info = @typeInfo(Ptr);
    if (info != .pointer) {
        @compileError("readback: register must be a volatile pointer, found " ++ @typeName(Ptr));
    }
    const ptr = info.pointer;
    if (!ptr.is_volatile) {
        @compileError("readback: register pointer must be `volatile`; a non-volatile " ++
            "readback can be optimized away, defeating the check");
    }
    const child = @typeInfo(ptr.child);
    if (child != .int or child.int.signedness != .unsigned) {
        @compileError("readback: register word must be an unsigned integer (e.g. u32), found " ++
            @typeName(ptr.child));
    }
    return ptr.child;
}

// --- Tests ----------------------------------------------------------------
// These run on the host (`zig build test`). Unlike lib/assert -- whose failure
// path is a noreturn trap it can only prove on-target -- readback's helpers are
// generic over the asserter, so a test asserter that *records* a failure
// instead of trapping lets the host exercise BOTH paths: that a matching
// readback passes, and that a mismatched one (a dropped write, a status bit
// that never rose) is caught. A plain variable behind a `*volatile` pointer
// stands in for a register that faithfully stores writes; a pre-set status
// variable stands in for one the peripheral drives.

const testing = std.testing;

/// A non-trapping asserter for tests: it tallies failures rather than diverging,
/// so a test can assert that a helper *did* catch a bad readback. Real firmware
/// passes a diverging asserter (lib/assert); the helpers require only
/// `assert(ok: bool) void`, which both satisfy.
const Counting = struct {
    var failures: u32 = 0;
    pub inline fn assert(ok: bool) void {
        if (!ok) failures += 1;
    }
    fn reset() void {
        failures = 0;
    }
};

const rb = Readback(Counting);

test "holds: masked compare accepts a match and rejects a mismatch" {
    // Positive space: exact match, and a match confined to the masked bits.
    try testing.expect(holds(@as(u32, 0b1010), 0b1010, 0b1111));
    try testing.expect(holds(@as(u32, 0xDEAD_BEEF), 0x0000_00EF, 0x0000_00FF));
    // Negative space: a bit expected set that reads clear, and vice versa.
    try testing.expect(!holds(@as(u32, 0b0000), 0b0010, 0b0010));
    try testing.expect(!holds(@as(u32, 0xFFFF_FFFF), 0x0000_0000, 0x0000_0001));
}

test "Word extracts the register width from a volatile pointer" {
    try testing.expect(Word(*volatile u32) == u32);
    try testing.expect(Word(*volatile u16) == u16);
    try testing.expect(Word(*volatile u8) == u8);
}

test "write_verify: a register that stores the write reads back and passes" {
    Counting.reset();
    var reg: u32 = 0;
    const p: *volatile u32 = &reg;
    rb.write_verify(p, 0xA5A5_A5A5);
    try testing.expectEqual(@as(u32, 0xA5A5_A5A5), reg);
    try testing.expectEqual(@as(u32, 0), Counting.failures);
}

test "write_verify_masked: verifies only the masked bits" {
    Counting.reset();
    var reg: u32 = 0;
    const p: *volatile u32 = &reg;
    // Confirm just the low byte; the write still sets the whole word.
    rb.write_verify_masked(p, 0x1234_0056, 0x0000_00FF);
    try testing.expectEqual(@as(u32, 0x1234_0056), reg);
    try testing.expectEqual(@as(u32, 0), Counting.failures);
}

test "write_status_verify: a raised status bit confirms the config write" {
    Counting.reset();
    var cfg: u32 = 0;
    var status: u32 = 0;
    const cfg_p: *volatile u32 = &cfg;
    const status_p: *volatile u32 = &status;
    // Model PMC: the peripheral raises its 'clock enabled' status bit, and the
    // write to the (write-only) enable register is confirmed by reading it.
    status = 1 << 12;
    rb.write_status_verify(cfg_p, 1 << 5, status_p, 1 << 12, 1 << 12);
    try testing.expectEqual(@as(u32, 1 << 5), cfg);
    try testing.expectEqual(@as(u32, 0), Counting.failures);
}

test "readback catches a dropped write: status bit never rose" {
    Counting.reset();
    var cfg: u32 = 0;
    var status: u32 = 0; // the 'enabled' bit stays 0: the write was silently dropped
    const cfg_p: *volatile u32 = &cfg;
    const status_p: *volatile u32 = &status;
    rb.write_status_verify(cfg_p, 1 << 5, status_p, 1 << 12, 1 << 12);
    // The write "happened" (cfg holds it) but the peripheral did not react, and
    // the pair assertion is what turns that silent no-op into a caught failure.
    try testing.expectEqual(@as(u32, 1), Counting.failures);
}

test "verify catches a mismatched bare readback" {
    Counting.reset();
    var status: u32 = 0;
    const p: *volatile u32 = &status;
    rb.verify(p, 1 << 3, 1 << 3); // expect bit 3 set; it is clear
    try testing.expectEqual(@as(u32, 1), Counting.failures);
}

test "set_bits and clear_bits round-trip and verify" {
    Counting.reset();
    var reg: u32 = 0b0001;
    const p: *volatile u32 = &reg;
    rb.set_bits(p, 0b1010);
    try testing.expectEqual(@as(u32, 0b1011), reg);
    rb.clear_bits(p, 0b0010);
    try testing.expectEqual(@as(u32, 0b1001), reg);
    try testing.expectEqual(@as(u32, 0), Counting.failures);
}

test "every declaration type-checks" {
    // Zig analyzes only the declarations a build references, so a `pub` decl no
    // test happens to instantiate could ship un-type-checked -- the one way a
    // diagnostic could slip past the strict-compiler gate (style guide §2.4).
    // Referencing the whole namespace forces every decl through the compiler.
    testing.refAllDeclsRecursive(@This());
}
