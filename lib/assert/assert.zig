//! A flash-cheap assertion primitive for freestanding targets.
//!
//! Tiger Style asks for assertions everywhere -- "assert all function
//! arguments and return values, pre/postconditions and invariants," at an
//! average of two per function, kept on "even in production." On a hosted
//! target that is affordable because a failed assertion reaches `abort`, and
//! the machinery behind it (message formatting, a stack walk) is already
//! linked in. On the bare-metal targets this repo builds for it is not:
//! Zig's default `assert` path reaches `std.debug.panic`, which "drags in
//! message formatting and stack-trace walking -- hundreds of kilobytes" that
//! do not fit in a small flash and could not print anywhere useful. So the
//! density guidance is unaffordable with the stock primitive, and Tiger
//! Style's assertion discipline is off the table on our targets until the
//! primitive is cheap enough to leave on.
//!
//! This file is that primitive. A failed assertion here does exactly one
//! thing: branch, once and cold, to a project-chosen `noreturn` handler.
//! There is no message, no format call, no unwinder, no panic plumbing -- so
//! an assertion costs a compare and a branch, a few instructions, and two per
//! function becomes affordable on a target with a tight code budget.
//!
//! Three things this file deliberately does NOT do, because each would break
//! the "serves every future project on any architecture" contract the issue
//! sets:
//!
//!   1. It never names a CPU, peripheral, clock, or memory map. The only
//!      hardware fact it relies on is `@trap()`, which the compiler lowers to
//!      whatever "stop, something is wrong" instruction the target has (`udf`
//!      on ARM, `unimp`/`ebreak` on RISC-V, and so on). It compiles for the
//!      host too, which is how its logic is unit-tested (see the tests below).
//!
//!   2. It never decides what the safe failure state is. "The only correct
//!      way to handle corrupt code is to crash," but on bare metal "crash"
//!      is not one thing: halting is safe where the worst outcome is an idle
//!      output and dangerous where it holds a motor or heater energized, and
//!      a reset is right only where a clean restart beats a wedge. That choice
//!      is per-device and is delegated to the project (see `Config.onFailure`
//!      and the per-project assertion & fault policy story, issue #12).
//!
//!   3. It never inspects interrupt/exception context. Detecting "am I in an
//!      ISR" is architecture-specific (ARM reads IPSR; other cores do not have
//!      it), so baking it in would violate (1). The primitive is instead
//!      written to be safe to call from any context -- it allocates nothing,
//!      takes no lock, and unwinds nothing -- and a project that needs
//!      context-aware failure queries its own architecture inside its own
//!      `onFailure`. See the README for the full ISR discussion.

const std = @import("std");
const root = @import("root");

/// What an assertion does, expressed as data so a project selects its own
/// behavior without this file naming a single choice.
pub const Config = struct {
    /// Whether `assert` checks anything at all. When false, every `assert`
    /// call compiles to nothing -- not a disabled branch, nothing. See
    /// `defaultEnabled` for how the default asserter resolves this.
    enabled: bool,

    /// The safe state to land in on a failed assertion. Must not return.
    ///
    /// Delegated on purpose. "Crash on corrupt state" means process-exit on a
    /// server, where every process fails into the same benign place and one
    /// universal answer suffices. Firmware has no such universal: the safe
    /// state is a property of the device, not of the assertion, so this file
    /// cannot know it and does not try. A project supplies it here (or via the
    /// `onAssertionFailure` root declaration; see `defaultOnFailure`), which
    /// is where the halt-vs-safe-state-vs-reset policy of issue #12 is encoded.
    ///
    /// Held as a pointer so it can be a project's own function; because a
    /// `Config` is always comptime-known, the call the assertion emits is a
    /// direct branch to that function, not an indirect call through a variable.
    onFailure: *const fn () noreturn,
};

/// The most portable defined failure state there is: a bare trap. The compiler
/// lowers `@trap()` to the target's illegal/undefined instruction, which faults
/// the core deterministically on every architecture and assumes nothing about
/// the board. It is the default `onFailure` for a project that has not chosen
/// one, and a sensible building block for one that has.
pub fn trap() noreturn {
    @trap();
}

/// Build an asserter bound to `config`. Returns a namespace whose `assert` is
/// specialized to that configuration at compile time.
///
/// Most code does not call this directly -- it uses the top-level `assert`,
/// which is an asserter wired from the project's root declarations (below).
/// `Assert` is exposed for the two cases that need an explicit configuration:
/// a project that wants more than one failure route (say a distinct one for
/// assertions inside an ISR), and this file's own tests and size benchmark,
/// which pin `enabled` and `onFailure` to measure and check each path.
pub fn Assert(comptime config: Config) type {
    return struct {
        /// Whether this asserter checks. Exposed so callers and tests can read
        /// the resolved value rather than re-deriving it.
        pub const enabled = config.enabled;

        /// The failure handler this asserter branches to. Exposed for the same
        /// reason as `enabled`, and so a project can reuse one asserter's
        /// failure route when defining another.
        pub const onFailure = config.onFailure;

        /// Assert that `ok` holds.
        ///
        /// Disabled: compiles to nothing. Enabled and `ok` is true: also
        /// nothing at runtime beyond evaluating `ok`. Enabled and `ok` is
        /// false: branch to `config.onFailure`, which does not return. The
        /// `@branchHint(.cold)` tells the optimizer the failure arm is not
        /// taken, so the hot path stays straight-line and the handler is laid
        /// out away from it.
        ///
        /// `inline` so there is no call frame for the check itself -- the
        /// compare and the cold branch land directly in the caller, which is
        /// what keeps two-per-function from adding a function's worth of
        /// prologue each time.
        pub inline fn assert(ok: bool) void {
            if (!config.enabled) return;
            if (!ok) {
                @branchHint(.cold);
                config.onFailure();
            }
        }
    };
}

/// Resolve whether the default asserter checks.
///
/// A project overrides this by declaring `pub const assertions_enabled: bool`
/// in its root source file. Absent that, the default is on in every optimize
/// mode -- including `ReleaseSmall` and `ReleaseFast`. That is deliberate and
/// is the whole point of the primitive: Tiger Style keeps assertions on "even
/// in production," and here that is affordable precisely because the failure
/// path is a bare trap. It also sidesteps a stock-`assert` foot-gun: Zig's
/// `std.debug.assert` lowers to `if (!ok) unreachable`, and `unreachable` in
/// the release-fast/small modes is undefined behavior -- the check is deleted
/// and the optimizer is then free to assume the condition held. This asserter
/// stays a real, checked branch in every mode when enabled.
pub fn defaultEnabled() bool {
    if (@hasDecl(root, "assertions_enabled")) {
        return root.assertions_enabled;
    }
    // On in every optimize mode. If a project ever wants the default to vary by
    // `@import("builtin").mode`, that is the one line to change -- but the point
    // of the primitive is that a bare-trap assertion is cheap enough not to.
    return true;
}

/// The default failure handler: the project's policy if it declared one, else
/// a trap.
///
/// A project supplies its safe state by declaring `pub fn onAssertionFailure()
/// noreturn` in its root source file -- the halt/safe-state/reset choice of
/// issue #12. The `@hasDecl` branch is resolved at compile time, so this
/// wrapper compiles to a direct tail into the project's handler (or into
/// `trap`); it costs nothing at runtime.
fn defaultOnFailure() noreturn {
    if (@hasDecl(root, "onAssertionFailure")) {
        root.onAssertionFailure();
    } else {
        trap();
    }
}

/// The default asserter, wired from the project's root declarations. This is
/// what nearly all code uses:
///
///     const assert = @import("assert").assert;
///     ...
///     assert(index < len);
const Default = Assert(.{
    .enabled = defaultEnabled(),
    .onFailure = &defaultOnFailure,
});

/// Whether the default asserter checks, resolved from the root declarations.
pub const enabled = Default.enabled;

/// Assert that `ok` holds, using the project's configured failure state. The
/// common entry point; see `Assert` for the explicit-configuration form.
pub const assert = Default.assert;

// --- Tests ----------------------------------------------------------------
// These run on the host (`zig build test`) and cover the pure logic: the
// on/off knob and the pass-through path. The failure path is a `noreturn`
// trap and cannot be caught in a host test, so its cost -- the actual "is it
// a bare trap" claim -- is verified on a real freestanding target by the
// size-delta benchmark under bench/ and the CI gate that runs it, not here.

test "disabled asserter is a no-op, even on a false condition" {
    const A = Assert(.{ .enabled = false, .onFailure = &trap });
    // If `enabled = false` did not fully elide the check this would trap and
    // take the test process down; reaching the next line is the assertion.
    A.assert(false);
    try std.testing.expect(!A.enabled);
}

test "enabled asserter passes through a true condition" {
    const A = Assert(.{ .enabled = true, .onFailure = &trap });
    A.assert(true);
    A.assert(1 + 1 == 2);
    try std.testing.expect(A.enabled);
}

test "the default asserter is on absent a project override" {
    // Nothing in the test root declares `assertions_enabled`, so the default
    // (on in every mode) applies.
    try std.testing.expect(enabled);
    try std.testing.expect(defaultEnabled());
}

test "a condition known-true at comptime is accepted at comptime" {
    // Exercises the enabled branch during comptime evaluation: a false literal
    // here would reach `@trap()` at comptime and fail the build, so this both
    // documents and checks that the check really is evaluated when enabled.
    comptime Assert(.{ .enabled = true, .onFailure = &trap }).assert(true);
}
