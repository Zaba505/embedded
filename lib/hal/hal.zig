//! A `comptime` hardware-abstraction seam: firmware logic talks to an injected
//! representation of its hardware instead of reaching out to fixed peripheral
//! addresses, so the same logic builds for its real target and for the host.
//!
//! ## Why a seam at all
//!
//! Deterministic host testing and simulation need one structural property: the
//! logic must talk to an *injected* world. The blinky is the counter-example,
//! deliberately so -- it reaches straight out with `@ptrFromInt(0x400E1030)`,
//! and a host test cannot intercept a store to `0x400E1030`. The research study
//! calls this the crux: "the 'world' (registers, timers, peripherals) must be
//! injected as a dependency rather than reached out to, so a host build can
//! substitute a simulated world. Nothing else in DST is reachable until it
//! exists."
//!
//! This package is that seam, in its reusable form. Logic is written against a
//! **contract** -- the operations a project needs to *do* -- and a **backend**
//! supplies them: `mmio` for real silicon, `fake` for a host test. The two are
//! interchangeable because the contract, not the register map, is what the
//! logic depends on.
//!
//! ## Why `comptime`, and what that buys
//!
//! The backend is a comptime `type`, never a runtime value. There is no vtable,
//! no function pointer, and no dynamic dispatch: every call through the seam
//! resolves at compile time to the backend's own inlined body, so on target the
//! generated code is the register poke and nothing else. That is what makes the
//! seam affordable on a tight flash budget -- the usual objection to a HAL is
//! the indirection it adds, and here there is none to add. The claim is not
//! taken on faith: `bench/` builds the same logic twice, once through the seam
//! and once as hand-written register pokes, for two different architectures,
//! and `bench/measure.sh` gates the `.text` delta at zero.
//!
//! ## Four things this package deliberately does NOT do
//!
//!   1. **It does not model one board's register map.** A contract names what
//!      the logic needs -- drive a line, sample a line, move a byte, read a
//!      counter -- never a peripheral. The same four contracts are satisfied by
//!      an Atmel PIO and a Broadcom GPIO block, by an Atmel USART and an ARM
//!      PL011, which is the whole point: the interface is defined by what a
//!      project needs to do, not by one board. `mmio` backends are likewise
//!      parameterized by register *shape* (a set/clear pair, a level register, a
//!      status-plus-data pair), so one backend serves several architectures.
//!
//!   2. **It does not do peripheral bring-up.** Ungating a clock, muxing a pin,
//!      programming a baud divisor happen once at init, are intensely
//!      chip-specific, and are exactly where a silently-dropped write hides --
//!      so they belong in the project's own init code, written with
//!      `lib/readback` so each config write is verified. The seam covers the
//!      *steady-state* operations the logic performs afterwards, which are the
//!      ones a host test needs to intercept. See the README, "What is on which
//!      side of the seam".
//!
//!   3. **It does not choose the failure state, or assert on the caller's
//!      behalf.** Like `lib/assert` and `lib/readback`, this package provides
//!      mechanism and never policy. It takes no asserter and traps nowhere; a
//!      project's own logic asserts through its own asserter, so the
//!      halt-vs-safe-state-vs-reset decision stays where issue #12 put it.
//!
//!   4. **It does not inject faults or generate randomness.** The `fake`
//!      backends expose *deterministic, test-set* knobs (a stuck transmitter, a
//!      count of bytes to drop) and nothing else. Driving those knobs from a
//!      seeded PRNG, on a schedule, with a reproducible seed, is the seeded
//!      simulator's job (#19) -- built *on* this seam, not inside it.

const std = @import("std");

/// Memory-mapped backends: real silicon, parameterized by register shape.
pub const mmio = @import("mmio.zig");

/// Host backends: the stand-ins a test drives.
pub const fake = @import("fake.zig");

/// The logical level of a single digital line.
///
/// *Logical*, not electrical: a backend applies the pin's polarity, so a switch
/// wired active-low (pulled up, closed to ground -- the usual arrangement, and
/// the one a schematic fixes) reads `.high` when it is pressed. Polarity is a
/// wiring fact, so it belongs in the backend that knows the wiring, not in the
/// logic that would otherwise have to remember to invert every read.
///
/// **The tag type is `u8`, and that is load-bearing.** As `enum(u1)` -- the
/// width the values actually need -- this cost the seam 56 bytes of `.text` on
/// Cortex-M3 and 68 on Cortex-A53, measured. A one-bit value has a one-*byte*
/// memory representation, so every level passed between two inlined functions
/// became an `i1` store followed by an `i8` load through a stack slot, which
/// the optimizer cannot forward and did not delete. Widening the tag makes the
/// stored and loaded types agree, the slot promotes to a register, and the
/// seam's cost returns to zero. The `bench` step is what caught this and is
/// what would catch it coming back.
pub const Level = enum(u8) {
    low = 0,
    high = 1,

    /// The opposite level. Named rather than open-coded so a polarity flip
    /// reads as intent instead of as arithmetic on an enum.
    pub inline fn invert(self: Level) Level {
        return of(!self.is_high());
    }

    /// The level a boolean stands for, with `true` meaning `.high`.
    pub inline fn of(high: bool) Level {
        return @enumFromInt(@intFromBool(high));
    }

    /// Whether this is `.high`. The inverse of `of`, for conditions.
    pub inline fn is_high(self: Level) bool {
        return @intFromEnum(self) != 0;
    }
};

// --- The contract machinery -----------------------------------------------
// A contract is comptime data describing what a backend must provide. Keeping
// it as data rather than as a Zig interface type is what lets the same
// description serve three purposes: check a backend and explain the failure
// (`verify`), answer the same question as a value a test can assert on
// (`conforms`), and document the seam's surface in one place.

/// One operation a backend must provide, as a method.
pub const Op = struct {
    /// The method's name, e.g. `"write"`.
    name: []const u8,

    /// Parameter types *after* the receiver. A backend's receiver may be
    /// `Backend`, `*Backend`, or `*const Backend` -- a zero-sized `mmio`
    /// backend takes itself by value, a `fake` that records calls needs a
    /// mutable pointer, and both satisfy the same contract.
    Params: []const type,

    /// The method's return type.
    Returns: type,

    /// Why the contract needs this operation, and what a backend must
    /// guarantee about it. Carried in the data so the obligation travels with
    /// the check instead of living only in prose someone may not read.
    why: []const u8,
};

/// One compile-time constant a backend must declare.
///
/// A constant rather than a method because these are properties of the
/// hardware, known before the program runs: a clock's tick rate is not
/// something to *call* for. Declaring it as a constant also lets the seam do
/// its unit arithmetic at `comptime` -- the highest-value assertion class in
/// the style guide (§5.2), costing zero flash and zero cycles.
pub const Constant = struct {
    /// The declaration's name, e.g. `"ticks_hz"`.
    name: []const u8,

    /// Its exact type. Exact on purpose: a bare `pub const ticks_hz = 1_000`
    /// is a `comptime_int` and is rejected, because the style guide (§3.1)
    /// wants explicitly-sized types and because the seam's overflow checks are
    /// only meaningful against a stated width.
    T: type,

    /// Why the contract needs it.
    why: []const u8,
};

/// What a backend must provide to stand in for a piece of hardware.
pub const Contract = struct {
    /// The contract's name, used in compile errors.
    name: []const u8,

    /// The operations, checked as methods.
    ops: []const Op = &.{},

    /// The compile-time constants, checked as declarations.
    constants: []const Constant = &.{},
};

/// Whether `Backend` satisfies `contract`, as a value.
///
/// The predicate form of `verify`. It exists so the negative space is testable:
/// a host test can assert that a backend missing an operation, or declaring one
/// with the wrong signature, does *not* conform -- which `verify` cannot show,
/// because a `@compileError` is not catchable. Asserting the negative space as
/// loudly as the positive is style guide §5.6, and here it is the only proof
/// that the check checks anything at all.
pub fn conforms(comptime contract: Contract, comptime Backend: type) bool {
    return comptime explain_mismatch(contract, Backend) == null;
}

/// Check `Backend` against `contract`, failing the build with an explanation if
/// it does not conform.
///
/// Called by every wrapper below, so a backend is verified where it is bound
/// rather than at some later call site. The point is the error message: without
/// this, a missing method surfaces as an error deep inside the wrapper, naming
/// the wrapper's internals instead of the contract the backend was supposed to
/// satisfy.
pub fn verify(comptime contract: Contract, comptime Backend: type) void {
    comptime {
        if (explain_mismatch(contract, Backend)) |message| {
            @compileError(message);
        }
    }
}

/// The single traversal behind both `conforms` and `verify`: it returns `null`
/// when `Backend` satisfies `contract`, else a message naming the contract, the
/// offending declaration, and the signature that was expected.
///
/// Comptime-only in practice -- every parameter is comptime and both callers
/// evaluate it in a comptime context -- but written as an ordinary function so
/// the control flow reads normally.
fn explain_mismatch(comptime contract: Contract, comptime Backend: type) ?[]const u8 {
    const prefix = "hal: " ++ @typeName(Backend) ++ " does not satisfy the '" ++
        contract.name ++ "' contract: ";

    switch (@typeInfo(Backend)) {
        .@"struct", .@"enum", .@"union", .@"opaque" => {},
        else => return prefix ++ "a backend must be a container type (struct, enum, " ++
            "union or opaque), found " ++ @typeName(Backend),
    }

    for (contract.constants) |constant| {
        if (!@hasDecl(Backend, constant.name)) {
            return prefix ++ "missing `pub const " ++ constant.name ++ ": " ++
                @typeName(constant.T) ++ "`. " ++ constant.why;
        }
        const Found = @TypeOf(@field(Backend, constant.name));
        if (Found != constant.T) {
            return prefix ++ "`" ++ constant.name ++ "` must be declared `" ++
                @typeName(constant.T) ++ "`, found " ++ @typeName(Found) ++
                " (declare it as `pub const " ++ constant.name ++ ": " ++
                @typeName(constant.T) ++ " = ...;`)";
        }
    }

    for (contract.ops) |op| {
        if (!@hasDecl(Backend, op.name)) {
            return prefix ++ "missing method `" ++ op.name ++ "`, expected `" ++
                render_signature(op) ++ "`. " ++ op.why;
        }
        const Found = @TypeOf(@field(Backend, op.name));
        const found = @typeInfo(Found);
        if (found != .@"fn") {
            return prefix ++ "`" ++ op.name ++ "` must be a method `" ++
                render_signature(op) ++ "`, found a " ++ @typeName(Found);
        }
        if (mismatched_signature(op, found.@"fn", Backend)) {
            return prefix ++ "`" ++ op.name ++ "` has the wrong signature: expected `" ++
                render_signature(op) ++ "`, found `" ++ @typeName(Found) ++ "`";
        }
    }

    return null;
}

/// Whether `found`'s signature departs from `op`'s. Split out so the message
/// building above stays readable; the receiver rule is the only subtle part.
fn mismatched_signature(
    comptime op: Op,
    comptime found: std.builtin.Type.Fn,
    comptime Backend: type,
) bool {
    // A generic or variadic method cannot be checked here at all: its parameter
    // types are not known until a call site supplies them, so there is nothing
    // to compare and the seam would be verifying nothing.
    if (found.is_generic or found.is_var_args) return true;
    if (found.params.len != op.Params.len + 1) return true;

    const Receiver = found.params[0].type orelse return true;
    if (Receiver != Backend and Receiver != *Backend and Receiver != *const Backend) {
        return true;
    }

    for (op.Params, found.params[1..]) |Expected, param| {
        const Found = param.type orelse return true;
        if (Found != Expected) return true;
    }

    return (found.return_type orelse return true) != op.Returns;
}

/// Render an op as the signature text a compile error shows.
fn render_signature(comptime op: Op) []const u8 {
    var text: []const u8 = "fn " ++ op.name ++ "(self";
    for (op.Params) |Param| {
        text = text ++ ", " ++ @typeName(Param);
    }
    return text ++ ") " ++ @typeName(op.Returns);
}

// --- The contracts ---------------------------------------------------------
// Four, chosen because they are what a project needs to *do* -- drive a line,
// sample a line, move a byte, read elapsed time -- and because each is
// satisfiable on every architecture this repo targets or plans to. Adding a
// fifth is a project's prerogative: `Contract` is public precisely so a project
// can declare its own (an ADC read, an I2C transfer) without editing this file.

/// Drive one digital output line.
pub const digital_out = Contract{
    .name = "DigitalOut",
    .ops = &.{
        .{
            .name = "write",
            .Params = &.{Level},
            .Returns = void,
            .why = "Driving the line is the whole point of an output.",
        },
        .{
            .name = "driven",
            .Params = &.{},
            .Returns = Level,
            .why = "The level currently being driven, so `toggle` needs no state of its " ++
                "own and a host test can observe the output. Every architecture surveyed " ++
                "can read this back (Atmel PIO_ODSR, Broadcom GPLEV0); a backend that " ++
                "truly cannot must track it in a field.",
        },
    },
};

/// Sample one digital input line.
pub const digital_in = Contract{
    .name = "DigitalIn",
    .ops = &.{
        .{
            .name = "read",
            .Params = &.{},
            .Returns = Level,
            .why = "Sampling the line is the whole point of an input. The level returned " ++
                "is LOGICAL: the backend has already applied the pin's polarity, so " ++
                "active-low wiring reads `.high` when the input is asserted.",
        },
    },
};

/// Move bytes over a serial link, one byte at a time, without ever blocking.
pub const serial = Contract{
    .name = "Serial",
    .ops = &.{
        .{
            .name = "try_write",
            .Params = &.{u8},
            .Returns = bool,
            .why = "Offer one byte to the transmitter, returning false if it is not " ++
                "ready. NON-BLOCKING on purpose: a spin inside the seam would be an " ++
                "unbounded loop the caller cannot bound (style guide §4.2) and a hang " ++
                "the host test could not distinguish from a deadlock.",
        },
        .{
            .name = "try_read",
            .Params = &.{},
            .Returns = ?u8,
            .why = "Take one received byte, or null if none has arrived. Non-blocking " ++
                "for the same reason, and optional-returning so 'no byte yet' is a " ++
                "value the logic must handle rather than a sentinel it may forget.",
        },
    },
};

/// Read a free-running counter -- the seam's notion of time.
pub const clock = Contract{
    .name = "Clock",
    .ops = &.{
        .{
            .name = "ticks",
            .Params = &.{},
            .Returns = u32,
            .why = "The counter's current value. It counts UP and WRAPS; the wrapper's " ++
                "`elapsed_since` does the wrap-safe subtraction, so no caller has to.",
        },
    },
    .constants = &.{
        .{
            .name = "ticks_hz",
            .T = u32,
            .why = "How many ticks a second is, so the seam converts milliseconds to " ++
                "ticks at comptime and a project states timeouts in the units it thinks " ++
                "in rather than in one board's counter rate.",
        },
        .{
            .name = "ticks_bits",
            .T = u6,
            .why = "The counter's width in bits, because counters are not all 32 bits " ++
                "wide (SysTick is 24) and elapsed time is only wrap-safe modulo the " ++
                "counter's own range.",
        },
    },
};

// --- The wrappers ----------------------------------------------------------
// What the logic is actually written against. Each verifies its backend where
// it is bound, then adds the derived operations that would otherwise be
// re-implemented per project (toggle, bounded slice I/O, elapsed time in
// milliseconds). Every method is `inline` or a bounded loop over a slice, so
// the wrapper contributes no call frame and no branch of its own.

/// A digital output line, bound to `Backend`.
pub fn DigitalOut(comptime Backend: type) type {
    verify(digital_out, Backend);
    return struct {
        const Self = @This();

        /// The injected hardware. A `pub` field so a test can reach the fake it
        /// passed in (to read `transitions`, say) without a separate handle.
        backend: Backend,

        /// Bind the seam to a backend instance. A zero-sized `mmio` backend
        /// makes this literally free; a `fake` carries its recorded state here.
        pub inline fn init(backend: Backend) Self {
            return .{ .backend = backend };
        }

        /// Drive the line to `level`.
        pub inline fn write(self: *Self, level: Level) void {
            self.backend.write(level);
        }

        /// Drive the line high. Named so a call site reads as the intent
        /// ("open the gate") rather than as an enum argument.
        pub inline fn drive_high(self: *Self) void {
            self.write(.high);
        }

        /// Drive the line low.
        pub inline fn drive_low(self: *Self) void {
            self.write(.low);
        }

        /// The level currently being driven.
        pub inline fn driven(self: *Self) Level {
            return self.backend.driven();
        }

        /// Drive the line to the opposite of what it is driving now.
        ///
        /// Derived from `driven` rather than from a remembered flag on purpose:
        /// a cached copy is a second source of truth for the pin's state, and
        /// the two disagree the moment anything else touches the port.
        pub inline fn toggle(self: *Self) void {
            self.write(self.driven().invert());
        }
    };
}

/// A digital input line, bound to `Backend`.
pub fn DigitalIn(comptime Backend: type) type {
    verify(digital_in, Backend);
    return struct {
        const Self = @This();

        /// The injected hardware; `pub` for the same reason as `DigitalOut`'s.
        backend: Backend,

        /// Bind the seam to a backend instance.
        pub inline fn init(backend: Backend) Self {
            return .{ .backend = backend };
        }

        /// Sample the line, as a logical level with the pin's polarity applied.
        pub inline fn read(self: *Self) Level {
            return self.backend.read();
        }

        /// Whether the input is asserted -- pressed, closed, active.
        ///
        /// The positive-space form (style guide §1.6) of the same sample, and
        /// the one a debounce loop wants: with polarity already applied by the
        /// backend, "is it pressed" is a question the logic can ask directly
        /// instead of one it has to translate through the wiring.
        pub inline fn is_active(self: *Self) bool {
            return self.read().is_high();
        }
    };
}

/// A byte-at-a-time serial link, bound to `Backend`.
pub fn Serial(comptime Backend: type) type {
    verify(serial, Backend);
    return struct {
        const Self = @This();

        /// The injected hardware; `pub` for the same reason as `DigitalOut`'s.
        backend: Backend,

        /// Bind the seam to a backend instance.
        pub inline fn init(backend: Backend) Self {
            return .{ .backend = backend };
        }

        /// Offer one byte to the transmitter. Returns false if it was not
        /// ready, in which case nothing was sent and the caller decides what to
        /// do -- retry next pass, drop, or fault.
        pub inline fn try_write(self: *Self, byte: u8) bool {
            return self.backend.try_write(byte);
        }

        /// Take one received byte, or null if none has arrived.
        pub inline fn try_read(self: *Self) ?u8 {
            return self.backend.try_read();
        }

        /// Offer `bytes` to the transmitter and return how many it accepted,
        /// stopping at the first refusal.
        ///
        /// Bounded by `bytes.len` and never retries, so it cannot spin on a
        /// wedged transmitter (style guide §4.2). A short return is normal and
        /// is the caller's business: it means the link is backing up, which is
        /// exactly the condition a simulator will want to inject.
        pub fn write_some(self: *Self, bytes: []const u8) usize {
            for (bytes, 0..) |byte, sent| {
                if (!self.try_write(byte)) return sent;
            }
            return bytes.len;
        }

        /// Fill `buffer` with whatever bytes have arrived and return how many,
        /// stopping when the receiver runs dry. Bounded by `buffer.len`.
        pub fn read_some(self: *Self, buffer: []u8) usize {
            for (buffer, 0..) |*slot, received| {
                slot.* = self.try_read() orelse return received;
            }
            return buffer.len;
        }
    };
}

/// A free-running counter, bound to `Backend`, with the elapsed-time
/// arithmetic the counter's width and rate imply.
pub fn Clock(comptime Backend: type) type {
    verify(clock, Backend);
    return struct {
        const Self = @This();

        /// The counter's rate, re-exported so callers read it off the seam
        /// rather than reaching past it into the backend.
        pub const ticks_hz = Backend.ticks_hz;

        /// The counter's width in bits.
        pub const ticks_bits = Backend.ticks_bits;

        /// The largest value the counter reaches before wrapping. All elapsed
        /// arithmetic is modulo `ticks_max + 1`, which is why a narrow counter
        /// stays correct here instead of being silently treated as 32-bit.
        pub const ticks_max: u32 = if (ticks_bits >= 32)
            std.math.maxInt(u32)
        else
            (@as(u32, 1) << ticks_bits) - 1;

        comptime {
            if (ticks_bits == 0) @compileError("hal: a clock with a 0-bit counter cannot " ++
                "measure anything");
            if (ticks_bits > 32) @compileError("hal: `ticks` is a u32, so a counter wider " ++
                "than 32 bits cannot be reported through this contract; narrow it or " ++
                "declare a contract of your own");
            if (ticks_hz == 0) @compileError("hal: a clock with `ticks_hz = 0` cannot " ++
                "convert a duration to ticks");
        }

        /// The injected hardware; `pub` for the same reason as `DigitalOut`'s.
        backend: Backend,

        /// Bind the seam to a backend instance.
        pub inline fn init(backend: Backend) Self {
            return .{ .backend = backend };
        }

        /// The counter's current value. Wraps; use `elapsed_since` to compare
        /// two readings rather than subtracting them by hand.
        pub inline fn ticks(self: *Self) u32 {
            return self.backend.ticks() & ticks_max;
        }

        /// Ticks elapsed since the reading `start`, correct across a wrap.
        ///
        /// Wrapping subtraction masked to the counter's width: the reason the
        /// seam knows `ticks_bits` at all. A plain `now - start` underflows the
        /// moment the counter wraps -- on a 1 MHz 32-bit counter that is every
        /// 71 minutes, and on SysTick's 24 bits every 16 seconds.
        pub inline fn elapsed_since(self: *Self, start: u32) u32 {
            return (self.ticks() -% start) & ticks_max;
        }

        /// `milliseconds` expressed in this counter's ticks, computed and
        /// range-checked entirely at compile time (style guide §5.2): zero
        /// flash, zero cycles, and a build error rather than a silent overflow
        /// if the duration cannot be represented.
        pub inline fn ticks_for_ms(comptime milliseconds: u32) u32 {
            return comptime blk: {
                const wanted = @as(u64, ticks_hz) * milliseconds / 1000;
                // Half the counter's range, not all of it: elapsed time is a
                // wrapping difference, so an interval longer than half a period
                // is indistinguishable from a short one in the other direction.
                // Refusing at the halfway mark is the negative-space check that
                // keeps a too-long timeout from reading as already-expired.
                const measurable = (@as(u64, ticks_max) + 1) / 2;
                if (wanted > measurable) {
                    @compileError(std.fmt.comptimePrint(
                        "hal: {d} ms is {d} ticks at {d} Hz, past the {d} ticks a " ++
                            "{d}-bit counter can measure unambiguously; use a slower " ++
                            "counter, a wider one, or a shorter interval",
                        .{ milliseconds, wanted, ticks_hz, measurable, ticks_bits },
                    ));
                }
                if (wanted == 0 and milliseconds != 0) {
                    @compileError(std.fmt.comptimePrint(
                        "hal: {d} ms rounds to 0 ticks at {d} Hz -- the counter is too " ++
                            "slow to measure it, and a 0-tick interval expires instantly",
                        .{ milliseconds, ticks_hz },
                    ));
                }
                break :blk @as(u32, @intCast(wanted));
            };
        }

        /// Whether at least `milliseconds` have elapsed since the reading
        /// `start`. The everyday form: a poll loop reads `ticks()` once, then
        /// asks this each pass.
        pub inline fn has_elapsed_ms(self: *Self, start: u32, comptime milliseconds: u32) bool {
            return self.elapsed_since(start) >= comptime ticks_for_ms(milliseconds);
        }
    };
}

// --- Tests ----------------------------------------------------------------
// These run on the host (`zig build test`). What they can prove is the seam's
// whole claim: that the contract check accepts a conforming backend and rejects
// a broken one, that the wrappers' derived logic is right, and -- the headline
// -- that logic written once against the seam runs unchanged over a memory
// mapped backend and a fake one. What they cannot prove is the code-size claim;
// that is measured on target by bench/measure.sh, the same division of labour
// docs/host-testing.md describes.

const testing = std.testing;

test "the four contracts accept their fake backends" {
    try testing.expect(conforms(digital_out, fake.Output));
    try testing.expect(conforms(digital_in, fake.Input));
    try testing.expect(conforms(serial, fake.Serial(8)));
    try testing.expect(conforms(clock, fake.Clock(1_000_000)));
}

test "the four contracts accept their memory-mapped backends" {
    // Pointed at plain host variables rather than at real peripheral addresses:
    // an `mmio` backend takes the `*volatile` pointers it drives as comptime
    // parameters, so the same backend that drives silicon on target drives a
    // variable here. That is not a testing trick -- it is the property that
    // makes the memory-mapped path host-checkable at all.
    try testing.expect(conforms(digital_out, MmioOut));
    try testing.expect(conforms(digital_in, MmioIn));
    try testing.expect(conforms(serial, MmioSerial));
    try testing.expect(conforms(clock, MmioClock));
}

test "a backend missing an operation does not conform" {
    const NoDriven = struct {
        pub fn write(self: @This(), level: Level) void {
            _ = self;
            _ = level;
        }
    };
    try testing.expect(!conforms(digital_out, NoDriven));
}

test "a backend with the wrong signature does not conform" {
    const WrongParam = struct {
        pub fn write(self: @This(), level: bool) void {
            _ = self;
            _ = level;
        }
        pub fn driven(self: @This()) Level {
            _ = self;
            return .low;
        }
    };
    const WrongReturn = struct {
        pub fn write(self: @This(), level: Level) void {
            _ = self;
            _ = level;
        }
        pub fn driven(self: @This()) bool {
            _ = self;
            return false;
        }
    };
    const NotAFunction = struct {
        pub const write: u32 = 0;
        pub fn driven(self: @This()) Level {
            _ = self;
            return .low;
        }
    };
    const Generic = struct {
        pub fn write(self: @This(), level: anytype) void {
            _ = self;
            _ = level;
        }
        pub fn driven(self: @This()) Level {
            _ = self;
            return .low;
        }
    };
    try testing.expect(!conforms(digital_out, WrongParam));
    try testing.expect(!conforms(digital_out, WrongReturn));
    try testing.expect(!conforms(digital_out, NotAFunction));
    try testing.expect(!conforms(digital_out, Generic));
    try testing.expect(!conforms(digital_out, u32)); // not a container at all
}

test "a clock backend must declare explicitly-sized constants" {
    const Untyped = struct {
        pub const ticks_hz = 1_000_000; // comptime_int, not u32
        pub const ticks_bits: u6 = 32;
        pub fn ticks(self: @This()) u32 {
            _ = self;
            return 0;
        }
    };
    const Missing = struct {
        pub const ticks_hz: u32 = 1_000_000;
        pub fn ticks(self: @This()) u32 {
            _ = self;
            return 0;
        }
    };
    try testing.expect(!conforms(clock, Untyped));
    try testing.expect(!conforms(clock, Missing));
}

test "an mmio backend and a fake backend are interchangeable" {
    // The acceptance criterion, as a test: one generic routine, two backends,
    // identical observable behaviour. `blink_once` never learns which it has.
    const Routine = struct {
        fn blink_once(out: anytype) void {
            out.drive_high();
            out.toggle();
        }
    };

    mmio_out_word = 0;
    var real = DigitalOut(MmioOut).init(.{});
    Routine.blink_once(&real);
    try testing.expectEqual(Level.low, real.driven());

    var stand_in = DigitalOut(fake.Output).init(.{});
    Routine.blink_once(&stand_in);
    try testing.expectEqual(Level.low, stand_in.driven());
    try testing.expectEqual(@as(u32, 2), stand_in.backend.writes);
    try testing.expectEqual(@as(u32, 2), stand_in.backend.transitions);
}

test "toggle reads the driven level rather than remembering it" {
    var out = DigitalOut(fake.Output).init(.{});
    try testing.expectEqual(Level.low, out.driven());
    out.toggle();
    try testing.expectEqual(Level.high, out.driven());

    // Something else drives the line -- another output on the same port, a
    // peripheral, a simulator. A cached copy would now be stale; reading the
    // hardware back cannot be.
    out.backend.level = .low;
    out.toggle();
    try testing.expectEqual(Level.high, out.driven());
}

test "an input reports the logical level, polarity already applied" {
    var input = DigitalIn(fake.Input).init(.{ .level = .low });
    try testing.expect(!input.is_active());
    input.backend.level = .high;
    try testing.expect(input.is_active());
    try testing.expectEqual(@as(u32, 2), input.backend.reads);
}

test "write_some stops at the first refusal and never spins" {
    var link = Serial(fake.Serial(4)).init(.{});
    try testing.expectEqual(@as(usize, 3), link.write_some("abc"));
    try testing.expectEqualSlices(u8, "abc", link.backend.sent());

    // The transmitter wedges: `write_some` reports the short count and returns
    // rather than retrying, which is what keeps a backed-up link from becoming
    // an unbounded loop.
    link.backend.tx_ready = false;
    try testing.expectEqual(@as(usize, 0), link.write_some("de"));
    try testing.expectEqualSlices(u8, "abc", link.backend.sent());
}

test "read_some drains what has arrived and no more" {
    var link = Serial(fake.Serial(8)).init(.{});
    try link.backend.deliver("hi");

    var buffer: [4]u8 = undefined;
    try testing.expectEqual(@as(usize, 2), link.read_some(&buffer));
    try testing.expectEqualSlices(u8, "hi", buffer[0..2]);
    try testing.expectEqual(@as(usize, 0), link.read_some(&buffer));
}

test "elapsed time is correct across a counter wrap" {
    // A 1 kHz, 8-bit counter: it wraps every 256 ms, so the arithmetic below is
    // the one a 24-bit SysTick or a 32-bit system timer meets less often but
    // just as fatally.
    const Narrow = fake.Counter(1_000, 8);
    var timer = Clock(Narrow).init(.{ .now = 250 });
    const started = timer.ticks();

    timer.backend.advance(10); // 250 -> 4, across the wrap
    try testing.expectEqual(@as(u32, 4), timer.ticks());
    try testing.expectEqual(@as(u32, 10), timer.elapsed_since(started));
    try testing.expect(timer.has_elapsed_ms(started, 10));
    try testing.expect(!timer.has_elapsed_ms(started, 11));
}

test "a duration converts to ticks at comptime" {
    const Micro = fake.Clock(1_000_000); // 1 MHz, 32-bit
    const Timer = Clock(Micro);
    try testing.expectEqual(@as(u32, 20_000), comptime Timer.ticks_for_ms(20));
    try testing.expectEqual(@as(u32, 0), comptime Timer.ticks_for_ms(0));
    try testing.expectEqual(@as(u32, 1_000_000), Timer.ticks_hz);
    try testing.expectEqual(@as(u32, std.math.maxInt(u32)), Timer.ticks_max);
}

test "a memory-mapped output drives its register" {
    mmio_out_word = 0;
    var gate = DigitalOut(MmioOut).init(.{});
    gate.drive_high();
    try testing.expectEqual(@as(u32, test_pin_mask), mmio_out_word);
    try testing.expectEqual(Level.high, gate.driven());
    gate.drive_low();
    try testing.expectEqual(@as(u32, 0), mmio_out_word);
    try testing.expectEqual(Level.low, gate.driven());
}

test "every declaration type-checks" {
    // Zig analyzes only the declarations a build references, so a `pub` decl no
    // test instantiates could ship un-type-checked -- the one way a diagnostic
    // could slip past the strict-compiler gate (style guide §2.4). Referencing
    // the whole namespace forces every decl through the compiler.
    testing.refAllDeclsRecursive(@This());
}

// The host stand-ins for peripheral registers the `mmio` tests above drive.
// Container-level `var`s because their addresses must be comptime-known: that
// is exactly what a real register address is, which is why the same backend
// binds to both.
var mmio_out_word: u32 = 0;
var mmio_in_word: u32 = 0;
var mmio_status_word: u32 = 0;
var mmio_tx_word: u32 = 0;
var mmio_rx_word: u32 = 0;
var mmio_counter_word: u32 = 0;

const test_pin_mask: u32 = 1 << 3;

// The read-modify-write shape rather than the set/clear pair, because one host
// word can model a data register faithfully and cannot model "write 1 to this
// address to clear a bit in that one". The set/clear backend is exercised
// against three separate words in mmio.zig's own tests.
const MmioOut = mmio.DataRegisterOutput(.{
    .data = &mmio_out_word,
    .mask = test_pin_mask,
});

const MmioIn = mmio.LevelInput(.{
    .level = &mmio_in_word,
    .mask = test_pin_mask,
});

const MmioSerial = mmio.PolledSerial(.{
    .status = &mmio_status_word,
    .transmit_data = &mmio_tx_word,
    .receive_data = &mmio_rx_word,
    .transmit_ready_mask = 1 << 1,
    .receive_ready_mask = 1 << 0,
});

const MmioClock = mmio.FreeRunningCounter(.{
    .value = &mmio_counter_word,
    .ticks_hz = 1_000_000,
});
