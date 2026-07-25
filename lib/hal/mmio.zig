//! Memory-mapped backends: the real side of the seam.
//!
//! Each backend here is parameterized by the *shape* of a register interface,
//! never by a board. That is what lets one backend serve several
//! architectures: an Atmel PIO controller and a Broadcom GPIO block both drive
//! a pin through a write-1-to-set / write-1-to-clear register pair, and an
//! Atmel USART and an ARM PL011 both move a byte through a status register plus
//! a data register. The addresses, bit positions and polarities differ; the
//! shape does not, so the difference is a value a project passes in rather than
//! a backend it has to write.
//!
//! Register pointers are `*volatile u32` **comptime parameters**, exactly as
//! `lib/readback` takes the pointer the caller already has. Two consequences,
//! both deliberate:
//!
//!   - **On target the backend is zero-sized and free.** The pointer and the
//!     mask are compile-time constants, so a `write` lowers to the same store
//!     the hand-written poke would emit. There is no field to hold, no
//!     indirection to chase, and nothing on the stack.
//!
//!   - **On the host the same backend binds to a plain variable.** A
//!     container-level `var`'s address is comptime-known too, so the memory
//!     mapped path itself is exercisable in a host test -- see the tests below.
//!     It is not a substitute for the board (a host word has none of a
//!     peripheral's behaviour, per docs/host-testing.md), but it does prove the
//!     bit arithmetic, the polarity handling and the register choice.
//!
//! **Registers here are 32 bits.** Every architecture this repo targets or has
//! surveyed uses 32-bit peripheral registers, so widening the backends
//! generically would buy nothing today and cost clarity. A future 8- or 16-bit
//! register file needs its own backend -- and, crucially, *no change to the
//! contracts*, because the logic never learns a register width. That the
//! backend is the part that varies is the seam working as intended.
//!
//! **These backends do steady-state I/O, not bring-up.** Ungating a peripheral
//! clock, muxing a pin away from its peripheral function, programming a baud
//! divisor: all chip-specific, all done once, and all places a write is
//! silently dropped. That work belongs in the project's init code written with
//! `lib/readback`, which verifies each config write took. A backend here
//! assumes it is handed a peripheral that is already alive.

const std = @import("std");
const hal = @import("hal.zig");

const Level = hal.Level;

/// Whether a status bit signals its condition by being set or by being clear.
///
/// Not pedantry -- it is the difference between two real UARTs. The Atmel USART
/// raises `TXRDY` when the transmitter is ready; the ARM PL011 raises `TXFF`
/// when the transmit FIFO is *full*, i.e. when it is **not** ready. Same shape,
/// opposite sense, so the sense is a parameter and neither chip needs its own
/// backend.
pub const BitSense = enum {
    /// The condition holds while the bit reads 1.
    set,
    /// The condition holds while the bit reads 0.
    clear,
};

/// How to drive an output pin through a write-1-to-set / write-1-to-clear
/// register pair.
pub const SetClearOutputConfig = struct {
    /// Write the mask here to drive the pin high (Atmel `PIO_SODR`, Broadcom
    /// `GPSET0`).
    set: *volatile u32,

    /// Write the mask here to drive the pin low (Atmel `PIO_CODR`, Broadcom
    /// `GPCLR0`).
    clear: *volatile u32,

    /// Read the pin's current level here (Atmel `PIO_ODSR`, Broadcom `GPLEV0`).
    state: *volatile u32,

    /// The pin's bit within those registers. Exactly one bit: this backend is
    /// one pin, and a multi-bit mask would make `driven` ambiguous.
    mask: u32,

    /// Whether the pin is asserted low. The seam speaks in *logical* levels, so
    /// with this set, writing `.high` drives the line low. A wiring fact, kept
    /// with the wiring rather than smeared through the logic.
    active_low: bool = false,
};

/// A digital output driven through a set/clear register pair.
///
/// The preferred output shape wherever the hardware offers it, because each
/// write is a single store that touches exactly one pin. The read-modify-write
/// alternative below has to read the whole port, and anything that changes
/// another pin in that window is lost.
pub fn SetClearOutput(comptime config: SetClearOutputConfig) type {
    comptime require_single_bit(config.mask, "SetClearOutput");
    return struct {
        const Self = @This();

        /// Drive the pin to the logical level `level`.
        pub inline fn write(self: Self, level: Level) void {
            _ = self;
            const electrical = if (config.active_low) level.invert() else level;
            // One store, one pin, no read: nothing else on the port can be
            // clobbered, and no interrupt can land inside the operation.
            if (electrical.is_high()) {
                config.set.* = config.mask;
            } else {
                config.clear.* = config.mask;
            }
        }

        /// The logical level the pin is currently at.
        pub inline fn driven(self: Self) Level {
            _ = self;
            const electrical = Level.of(config.state.* & config.mask != 0);
            return if (config.active_low) electrical.invert() else electrical;
        }
    };
}

/// How to drive an output pin through a single read-modify-write data register.
pub const DataRegisterOutputConfig = struct {
    /// The port's output data register, both read and written.
    data: *volatile u32,

    /// The pin's bit within it. Exactly one bit, as above.
    mask: u32,

    /// Whether the pin is asserted low; see `SetClearOutputConfig.active_low`.
    active_low: bool = false,
};

/// A digital output driven through one read-modify-write data register.
///
/// For a port with no set/clear pair. It exists here for two reasons: some
/// register files genuinely only offer this, and having two backends of
/// different register shapes behind one contract is the demonstration that the
/// contract, not the register map, is what the logic depends on.
///
/// **The hazard, stated because it is invisible in the source:** read-modify
/// write is not atomic. An interrupt, another core, or the peripheral itself
/// touching the same port between the read and the write silently loses that
/// change. Prefer `SetClearOutput` whenever the hardware has the registers for
/// it; reach for this only when it does not.
pub fn DataRegisterOutput(comptime config: DataRegisterOutputConfig) type {
    comptime require_single_bit(config.mask, "DataRegisterOutput");
    return struct {
        const Self = @This();

        /// Drive the pin to the logical level `level`.
        pub inline fn write(self: Self, level: Level) void {
            _ = self;
            const electrical = if (config.active_low) level.invert() else level;
            const current = config.data.*;
            config.data.* = if (electrical.is_high())
                current | config.mask
            else
                current & ~config.mask;
        }

        /// The logical level the pin is currently at.
        pub inline fn driven(self: Self) Level {
            _ = self;
            const electrical = Level.of(config.data.* & config.mask != 0);
            return if (config.active_low) electrical.invert() else electrical;
        }
    };
}

/// How to sample an input pin from a port's level register.
pub const LevelInputConfig = struct {
    /// The register reporting the pins' electrical levels (Atmel `PIO_PDSR`,
    /// Broadcom `GPLEV0`).
    level: *volatile u32,

    /// The pin's bit within it. Exactly one bit.
    mask: u32,

    /// Whether the input is asserted low -- the common case for a switch or
    /// button, which is pulled up and closes to ground. With this set, a closed
    /// switch reads `.high`, so the logic asks "is it pressed" rather than
    /// remembering that pressed means 0.
    active_low: bool = false,
};

/// A digital input sampled from a port's level register.
pub fn LevelInput(comptime config: LevelInputConfig) type {
    comptime require_single_bit(config.mask, "LevelInput");
    return struct {
        const Self = @This();

        /// Sample the pin as a logical level, polarity applied.
        pub inline fn read(self: Self) Level {
            _ = self;
            const electrical = Level.of(config.level.* & config.mask != 0);
            return if (config.active_low) electrical.invert() else electrical;
        }
    };
}

/// How to move bytes over a polled serial peripheral: one status register plus
/// a data register in each direction.
pub const PolledSerialConfig = struct {
    /// The status register carrying both ready bits (Atmel `US_CSR`, ARM
    /// PL011 `UARTFR`).
    status: *volatile u32,

    /// Write a byte here to transmit it (Atmel `US_THR`, PL011 `UARTDR`).
    transmit_data: *volatile u32,

    /// Read a received byte from here (Atmel `US_RHR`, PL011 `UARTDR` -- the
    /// same address on the PL011, a different one on the USART, which is why
    /// they are separate fields).
    receive_data: *volatile u32,

    /// The status bit reporting the transmitter's readiness.
    transmit_ready_mask: u32,

    /// Whether that bit means ready when set (Atmel `TXRDY`) or when clear
    /// (PL011 `TXFF`, which is raised when the FIFO is full).
    transmit_ready_when: BitSense = .set,

    /// The status bit reporting that a received byte is waiting.
    receive_ready_mask: u32,

    /// Whether that bit means a byte is waiting when set (Atmel `RXRDY`) or
    /// when clear (PL011 `RXFE`, raised when the FIFO is empty).
    receive_ready_when: BitSense = .set,

    /// The data bits within the receive register. The PL011's `UARTDR` carries
    /// framing, parity and break flags above the byte; masking them off here
    /// keeps the logic from ever seeing them as data. Errors are the project's
    /// to handle from the status register, deliberately: what a framing error
    /// *means* is a protocol decision, not a backend one.
    data_mask: u32 = 0xFF,
};

/// A polled, non-blocking serial link.
///
/// Polled rather than interrupt-driven because the style guide (§4.5) says to
/// run at your own pace, and because a poll keeps control flow in the main loop
/// where a host test can step it. Non-blocking because a spin inside the seam
/// would be a loop the caller cannot bound (§4.2) -- the backend reports "not
/// ready" and the caller decides.
pub fn PolledSerial(comptime config: PolledSerialConfig) type {
    comptime {
        if (config.transmit_ready_mask == 0) {
            @compileError("hal.mmio.PolledSerial: transmit_ready_mask is 0, so the " ++
                "transmitter would never read as ready");
        }
        if (config.receive_ready_mask == 0) {
            @compileError("hal.mmio.PolledSerial: receive_ready_mask is 0, so a received " ++
                "byte would never be noticed");
        }
        if (config.data_mask == 0) {
            @compileError("hal.mmio.PolledSerial: data_mask is 0, so every received byte " ++
                "would read as 0");
        }
    }
    return struct {
        const Self = @This();

        /// Offer one byte to the transmitter; false if it was not ready, in
        /// which case nothing was written to the data register.
        pub inline fn try_write(self: Self, byte: u8) bool {
            _ = self;
            if (!holds(config.status.*, config.transmit_ready_mask, config.transmit_ready_when)) {
                return false;
            }
            config.transmit_data.* = byte;
            return true;
        }

        /// Take one received byte, or null if none is waiting.
        pub inline fn try_read(self: Self) ?u8 {
            _ = self;
            if (!holds(config.status.*, config.receive_ready_mask, config.receive_ready_when)) {
                return null;
            }
            return @truncate(config.receive_data.* & config.data_mask);
        }
    };
}

/// How to read time from a free-running counter register.
pub const FreeRunningCounterConfig = struct {
    /// The counter's value register (Atmel `TC_CV`, Broadcom system timer
    /// `CLO`, ARM `SYST_CVR`).
    value: *volatile u32,

    /// How many times a second it advances.
    ticks_hz: u32,

    /// The counter's width. Not every counter is 32 bits: SysTick is 24, and
    /// treating it as 32 makes every elapsed measurement wrong the first time
    /// it wraps -- 16 seconds in, at 1 MHz.
    bits: u6 = 32,

    /// Whether the counter counts down instead of up (SysTick does).
    ///
    /// **Precondition when set:** the counter must reload at its full width, so
    /// that the reversed value advances by one per tick modulo the same range.
    /// A SysTick programmed with a short reload -- the usual arrangement, and
    /// what the blinky does -- does not satisfy this and is not a clock; it is
    /// a periodic tick source, which is a different thing to model.
    counts_down: bool = false,
};

/// A free-running counter read straight from a register.
pub fn FreeRunningCounter(comptime config: FreeRunningCounterConfig) type {
    comptime {
        if (config.bits == 0 or config.bits > 32) {
            @compileError(std.fmt.comptimePrint(
                "hal.mmio.FreeRunningCounter: bits must be 1..32, found {d}",
                .{config.bits},
            ));
        }
        if (config.ticks_hz == 0) {
            @compileError("hal.mmio.FreeRunningCounter: ticks_hz is 0, so no duration " ++
                "could ever be converted to ticks");
        }
    }
    return struct {
        const Self = @This();

        /// The counter's rate, as the `clock` contract requires.
        pub const ticks_hz: u32 = config.ticks_hz;

        /// The counter's width, as the `clock` contract requires.
        pub const ticks_bits: u6 = config.bits;

        const value_mask: u32 = if (config.bits == 32)
            std.math.maxInt(u32)
        else
            (@as(u32, 1) << config.bits) - 1;

        /// The counter's current value, normalized to count up.
        pub inline fn ticks(self: Self) u32 {
            _ = self;
            const raw = config.value.* & value_mask;
            // Subtracting a down-counter from its full range yields a value
            // that increases by one per tick and wraps at the same modulus, so
            // the wrap-safe subtraction in `hal.Clock` stays valid unchanged.
            return if (config.counts_down) (value_mask - raw) else raw;
        }
    };
}

/// Whether `status`'s `mask` bits report their condition as holding.
fn holds(status: u32, mask: u32, sense: BitSense) bool {
    return switch (sense) {
        .set => status & mask != 0,
        .clear => status & mask == 0,
    };
}

/// Reject a pin mask that is not exactly one bit.
///
/// A comptime negative-space check (style guide §5.2/§5.6): a zero mask would
/// make a pin that silently does nothing, and a multi-bit mask would make
/// `driven`/`read` ambiguous -- "is the pin high" has no answer when the mask
/// covers two pins that disagree. Both are build errors rather than runtime
/// surprises.
fn require_single_bit(comptime mask: u32, comptime who: []const u8) void {
    comptime {
        if (@popCount(mask) != 1) {
            @compileError(std.fmt.comptimePrint(
                "hal.mmio.{s}: mask must name exactly one pin, found 0x{X:0>8} with {d} " ++
                    "bits set",
                .{ who, mask, @popCount(mask) },
            ));
        }
    }
}

// --- Tests ----------------------------------------------------------------
// Host words stand in for peripheral registers: a container-level `var` has a
// comptime-known address, which is the only thing these backends need of a
// register. What that proves is the bit arithmetic, the polarity handling and
// the ready-sense handling -- not that any of these addresses exist on any
// chip, which only a board can show (docs/host-testing.md).

const testing = std.testing;

var set_word: u32 = 0;
var clear_word: u32 = 0;
var state_word: u32 = 0;
var data_word: u32 = 0;
var input_word: u32 = 0;
var status_word: u32 = 0;
var transmit_word: u32 = 0;
var receive_word: u32 = 0;
var counter_word: u32 = 0;

const pin: u32 = 1 << 26;

test "a set/clear output writes the pin's bit to the right register" {
    set_word = 0;
    clear_word = 0;
    const Out = SetClearOutput(.{
        .set = &set_word,
        .clear = &clear_word,
        .state = &state_word,
        .mask = pin,
    });
    const out = Out{};

    out.write(.high);
    try testing.expectEqual(pin, set_word);
    try testing.expectEqual(@as(u32, 0), clear_word);

    set_word = 0;
    out.write(.low);
    try testing.expectEqual(@as(u32, 0), set_word);
    try testing.expectEqual(pin, clear_word);
}

test "a set/clear output reads its level from the state register" {
    const Out = SetClearOutput(.{
        .set = &set_word,
        .clear = &clear_word,
        .state = &state_word,
        .mask = pin,
    });
    const out = Out{};

    state_word = 0;
    try testing.expectEqual(Level.low, out.driven());
    state_word = pin;
    try testing.expectEqual(Level.high, out.driven());
    // Another pin on the same port must not be mistaken for this one.
    state_word = ~pin;
    try testing.expectEqual(Level.low, out.driven());
}

test "an active-low output inverts between logical and electrical" {
    set_word = 0;
    clear_word = 0;
    const Out = SetClearOutput(.{
        .set = &set_word,
        .clear = &clear_word,
        .state = &state_word,
        .mask = pin,
        .active_low = true,
    });
    const out = Out{};

    // Logical high on an active-low pin drives the line LOW.
    out.write(.high);
    try testing.expectEqual(pin, clear_word);
    try testing.expectEqual(@as(u32, 0), set_word);

    state_word = 0; // line low -> logically asserted
    try testing.expectEqual(Level.high, out.driven());
}

test "a data-register output read-modify-writes only its own bit" {
    const Out = DataRegisterOutput(.{ .data = &data_word, .mask = pin });
    const out = Out{};

    data_word = 0x0000_00FF; // other pins on the same port, already driven
    out.write(.high);
    try testing.expectEqual(@as(u32, 0x0000_00FF) | pin, data_word);
    try testing.expectEqual(Level.high, out.driven());

    out.write(.low);
    try testing.expectEqual(@as(u32, 0x0000_00FF), data_word);
    try testing.expectEqual(Level.low, out.driven());
}

test "an input applies its polarity" {
    const Active_high = LevelInput(.{ .level = &input_word, .mask = pin });
    const Active_low = LevelInput(.{ .level = &input_word, .mask = pin, .active_low = true });

    input_word = 0;
    try testing.expectEqual(Level.low, (Active_high{}).read());
    try testing.expectEqual(Level.high, (Active_low{}).read());

    input_word = pin;
    try testing.expectEqual(Level.high, (Active_high{}).read());
    try testing.expectEqual(Level.low, (Active_low{}).read());
}

test "a polled serial link honours a ready-when-set status bit" {
    // The Atmel USART shape: TXRDY (bit 1) and RXRDY (bit 0) are raised when
    // the peripheral is ready.
    const Link = PolledSerial(.{
        .status = &status_word,
        .transmit_data = &transmit_word,
        .receive_data = &receive_word,
        .transmit_ready_mask = 1 << 1,
        .receive_ready_mask = 1 << 0,
    });
    const link = Link{};

    status_word = 0; // neither ready
    try testing.expect(!link.try_write('a'));
    try testing.expectEqual(@as(u32, 0), transmit_word);
    try testing.expectEqual(@as(?u8, null), link.try_read());

    status_word = 1 << 1; // transmitter ready
    try testing.expect(link.try_write('a'));
    try testing.expectEqual(@as(u32, 'a'), transmit_word);

    status_word = 1 << 0; // a byte waiting
    receive_word = 'z';
    try testing.expectEqual(@as(?u8, 'z'), link.try_read());
}

test "a polled serial link honours a ready-when-clear status bit" {
    // The ARM PL011 shape: TXFF (bit 5) is raised when the transmit FIFO is
    // FULL and RXFE (bit 4) when the receive FIFO is EMPTY -- both the
    // opposite sense, and both handled by configuration rather than by a
    // second backend.
    const Link = PolledSerial(.{
        .status = &status_word,
        .transmit_data = &transmit_word,
        .receive_data = &receive_word,
        .transmit_ready_mask = 1 << 5,
        .transmit_ready_when = .clear,
        .receive_ready_mask = 1 << 4,
        .receive_ready_when = .clear,
        // The PL011 reports framing/parity/break errors above the data byte.
        .data_mask = 0xFF,
    });
    const link = Link{};

    status_word = (1 << 5) | (1 << 4); // FIFO full, receive FIFO empty
    try testing.expect(!link.try_write('a'));
    try testing.expectEqual(@as(?u8, null), link.try_read());

    status_word = 0; // room to send, and a byte waiting
    try testing.expect(link.try_write('a'));
    try testing.expectEqual(@as(u32, 'a'), transmit_word);

    receive_word = 0x0000_0F42; // 'B' with error flags set above it
    try testing.expectEqual(@as(?u8, 'B'), link.try_read());
}

test "a free-running counter reads up, masked to its width" {
    const Counter = FreeRunningCounter(.{
        .value = &counter_word,
        .ticks_hz = 1_000_000,
        .bits = 24, // a 24-bit counter in a 32-bit register
    });
    const counter = Counter{};

    counter_word = 0x00FF_FFFF;
    try testing.expectEqual(@as(u32, 0x00FF_FFFF), counter.ticks());
    // Bits above the counter's width belong to something else and must not
    // leak into a time reading.
    counter_word = 0xFF00_0001;
    try testing.expectEqual(@as(u32, 1), counter.ticks());
    try testing.expectEqual(@as(u32, 1_000_000), Counter.ticks_hz);
    try testing.expectEqual(@as(u6, 24), Counter.ticks_bits);
}

test "a down-counter is normalized to count up" {
    const Counter = FreeRunningCounter(.{
        .value = &counter_word,
        .ticks_hz = 1_000,
        .bits = 8,
        .counts_down = true,
    });
    const counter = Counter{};

    counter_word = 0xFF; // full: no time elapsed yet
    try testing.expectEqual(@as(u32, 0), counter.ticks());
    counter_word = 0xFE; // one tick later
    try testing.expectEqual(@as(u32, 1), counter.ticks());
    counter_word = 0x00; // one short of a wrap
    try testing.expectEqual(@as(u32, 0xFF), counter.ticks());
}

test "the memory-mapped backends satisfy their contracts" {
    // The same check the wrappers run, asserted here as a value so this file's
    // own tests fail loudly if a backend drifts from its contract.
    try testing.expect(hal.conforms(hal.digital_out, SetClearOutput(.{
        .set = &set_word,
        .clear = &clear_word,
        .state = &state_word,
        .mask = pin,
    })));
    try testing.expect(hal.conforms(hal.digital_out, DataRegisterOutput(.{
        .data = &data_word,
        .mask = pin,
    })));
    try testing.expect(hal.conforms(hal.digital_in, LevelInput(.{
        .level = &input_word,
        .mask = pin,
    })));
    try testing.expect(hal.conforms(hal.serial, PolledSerial(.{
        .status = &status_word,
        .transmit_data = &transmit_word,
        .receive_data = &receive_word,
        .transmit_ready_mask = 1 << 1,
        .receive_ready_mask = 1 << 0,
    })));
    try testing.expect(hal.conforms(hal.clock, FreeRunningCounter(.{
        .value = &counter_word,
        .ticks_hz = 1_000_000,
    })));
}

test "every declaration type-checks" {
    testing.refAllDeclsRecursive(@This());
}
