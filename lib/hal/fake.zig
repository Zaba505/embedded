//! Host backends: the stand-ins a test drives.
//!
//! Each one satisfies the same contract as its memory-mapped counterpart, so
//! the logic under test cannot tell them apart -- which is the entire claim the
//! seam makes. What a fake adds is the two things a register cannot give a
//! host: **observability** (what did the logic drive, how many times, in what
//! order) and **control** (what will the input read next, is the transmitter
//! ready, does this byte arrive at all).
//!
//! Three properties, each with a reason:
//!
//!   - **Bounded and allocation-free.** Every buffer is a fixed array sized by
//!     a comptime parameter -- style guide §7.1, and the same discipline the
//!     firmware itself follows, so a fake cannot pass a test the real backend's
//!     memory budget would fail.
//!
//!   - **Deterministic.** Nothing here reads a clock, a random number, or the
//!     environment. `advance` moves time only when a test says so, which is
//!     what makes a host run of the logic reproducible -- and fast: simulated
//!     time fast-forwards, so a debounce interval costs one function call
//!     instead of twenty milliseconds.
//!
//!   - **Faults are knobs, not policy.** `tx_ready` and `drop_writes` model a
//!     wedged and a lossy link, and a test sets them by hand. Driving those
//!     knobs from a seeded PRNG on a schedule -- with a failure reproducible
//!     from seed and commit -- is the seeded simulator's job (#19), built on
//!     this seam. The knobs are the surface it will drive; the schedule is not
//!     this package's business.

const std = @import("std");
const hal = @import("hal.zig");

const Level = hal.Level;

/// A digital output that records what was driven through it.
///
/// Satisfies `hal.digital_out`. `writes` and `transitions` are the useful
/// distinction: a controller that drives `.high` every pass through its loop is
/// correct but wasteful, and only the two counters together show it. For a load
/// switch it is `transitions` that matters -- how many times the light actually
/// changed -- and a test asserting "one press, one transition" is asserting the
/// property a user would notice.
pub const Output = struct {
    /// The level currently driven. A test may set it directly to model
    /// something else changing the line.
    level: Level = .low,

    /// How many times `write` was called, including redundant writes.
    writes: u32 = 0,

    /// How many times `write` actually changed the level.
    transitions: u32 = 0,

    /// Drive the line, recording the call.
    pub fn write(self: *Output, level: Level) void {
        self.writes += 1;
        if (self.level != level) self.transitions += 1;
        self.level = level;
    }

    /// The level currently driven.
    pub fn driven(self: *const Output) Level {
        return self.level;
    }
};

/// A digital input a test drives.
///
/// Satisfies `hal.digital_in`. Levels are logical, exactly as a real backend
/// reports them once it has applied the pin's polarity, so a test writes what
/// it means -- `.high` for "pressed" -- and never has to model the wiring.
pub const Input = struct {
    /// The level the next `read` returns. A test sets it to script the input;
    /// setting it twice in a row with a `read` between is how a bounce, an
    /// edge, or a long press is modelled.
    level: Level = .low,

    /// How many times the logic sampled the line. Worth asserting on: a
    /// debounce routine that samples once is not debouncing.
    reads: u32 = 0,

    /// Sample the line, recording the call.
    pub fn read(self: *Input) Level {
        self.reads += 1;
        return self.level;
    }
};

/// A serial link with a bounded transmit log and receive queue, plus the
/// fault knobs a lossy link needs.
///
/// Satisfies `hal.serial`. `capacity` bounds each direction independently.
pub fn Serial(comptime capacity: usize) type {
    comptime {
        if (capacity == 0) {
            @compileError("hal.fake.Serial: a capacity of 0 can neither send nor receive");
        }
    }
    return struct {
        const Self = @This();

        /// Everything the logic has transmitted, in order. Read it with
        /// `sent`.
        transmitted: [capacity]u8 = undefined,
        transmitted_len: usize = 0,

        /// Bytes waiting to be received, queued by `deliver`.
        received: [capacity]u8 = undefined,
        received_len: usize = 0,
        received_taken: usize = 0,

        /// Whether the transmitter accepts bytes at all. Set it false to model
        /// a wedged or backed-up link: `try_write` then reports not-ready, and
        /// the property under test is that the logic copes instead of spinning.
        tx_ready: bool = true,

        /// How many of the next accepted bytes vanish on the wire.
        ///
        /// The subtle fault, and the reason it is here: the transmitter says
        /// yes, the byte is gone, and nothing local can tell. That is exactly
        /// the failure a relative command (a `TOGGLE`) cannot recover from and
        /// an idempotent one (`ON`/`OFF`) can -- the trade-off the smart-light
        /// protocol story documents, made testable here.
        drop_writes: u32 = 0,

        /// Offer one byte to the transmitter.
        pub fn try_write(self: *Self, byte: u8) bool {
            if (!self.tx_ready) return false;
            if (self.drop_writes > 0) {
                // Accepted by the peripheral, lost before it arrives: the
                // caller sees success, and must not depend on it.
                self.drop_writes -= 1;
                return true;
            }
            if (self.transmitted_len == capacity) return false;
            self.transmitted[self.transmitted_len] = byte;
            self.transmitted_len += 1;
            return true;
        }

        /// Take one queued byte, or null if the queue is empty.
        pub fn try_read(self: *Self) ?u8 {
            if (self.received_taken == self.received_len) return null;
            const byte = self.received[self.received_taken];
            self.received_taken += 1;
            return byte;
        }

        /// Queue `bytes` for the logic to receive. Fails rather than
        /// overwriting when the queue cannot hold them: a fake that silently
        /// drops a test's input would make the test lie about what it fed in.
        pub fn deliver(self: *Self, bytes: []const u8) error{QueueFull}!void {
            // Reclaim the space taken by bytes already consumed, so a long
            // sequence delivered a few at a time is not bounded by `capacity`
            // in total -- only by how many are outstanding at once.
            if (self.received_taken == self.received_len) {
                self.received_len = 0;
                self.received_taken = 0;
            }
            if (self.received_len + bytes.len > capacity) return error.QueueFull;
            @memcpy(self.received[self.received_len..][0..bytes.len], bytes);
            self.received_len += bytes.len;
        }

        /// Everything transmitted so far, in order.
        pub fn sent(self: *const Self) []const u8 {
            return self.transmitted[0..self.transmitted_len];
        }

        /// Forget the transmit log, so one test can check several exchanges
        /// without the earlier ones running the buffer out.
        pub fn clear_sent(self: *Self) void {
            self.transmitted_len = 0;
        }
    };
}

/// A counter a test advances by hand.
///
/// Satisfies `hal.clock`. `width_bits` exists so a test can reproduce a narrow
/// counter's wrap without waiting for one: an 8-bit fake wraps every 256 ticks,
/// which is how the wrap-safe arithmetic is exercised in a unit test rather
/// than discovered in the field 71 minutes into a run.
pub fn Counter(comptime rate_hz: u32, comptime width_bits: u6) type {
    comptime {
        if (width_bits == 0 or width_bits > 32) {
            @compileError(std.fmt.comptimePrint(
                "hal.fake.Counter: width_bits must be 1..32, found {d}",
                .{width_bits},
            ));
        }
        if (rate_hz == 0) {
            @compileError("hal.fake.Counter: rate_hz is 0, so no duration could ever be " ++
                "converted to ticks");
        }
    }
    return struct {
        const Self = @This();

        /// The counter's rate, as the `clock` contract requires.
        pub const ticks_hz: u32 = rate_hz;

        /// The counter's width, as the `clock` contract requires.
        pub const ticks_bits: u6 = width_bits;

        const value_mask: u32 = if (width_bits == 32)
            std.math.maxInt(u32)
        else
            (@as(u32, 1) << width_bits) - 1;

        /// The current value. A test may set it directly to start a run at an
        /// awkward point -- just below a wrap, say.
        now: u32 = 0,

        /// How many times the logic read the clock.
        reads: u32 = 0,

        /// The counter's current value.
        pub fn ticks(self: *Self) u32 {
            self.reads += 1;
            return self.now & value_mask;
        }

        /// Move time forward by `by` ticks, wrapping at the counter's width.
        pub fn advance(self: *Self, by: u32) void {
            self.now = (self.now +% by) & value_mask;
        }

        /// Move time forward by `milliseconds`, converted at compile time.
        ///
        /// The fast-forward the VOPR's "speed up time arbitrarily" requirement
        /// asks for: a 20 ms debounce interval costs one call here, not 20 ms
        /// of wall clock, so a test can walk a state machine through hours of
        /// modelled time in microseconds.
        pub fn advance_ms(self: *Self, comptime milliseconds: u32) void {
            const ticks_wanted = comptime blk: {
                const wanted = @as(u64, rate_hz) * milliseconds / 1000;
                if (wanted > value_mask) {
                    @compileError(std.fmt.comptimePrint(
                        "hal.fake.Counter: {d} ms is {d} ticks at {d} Hz, more than a " ++
                            "{d}-bit counter holds",
                        .{ milliseconds, wanted, rate_hz, width_bits },
                    ));
                }
                break :blk @as(u32, @intCast(wanted));
            };
            self.advance(ticks_wanted);
        }
    };
}

/// A 32-bit counter at `rate_hz` -- the common case, and the shape of a
/// system timer on the architectures this repo targets.
pub fn Clock(comptime rate_hz: u32) type {
    return Counter(rate_hz, 32);
}

// --- Tests ----------------------------------------------------------------

const testing = std.testing;

test "an output counts writes and transitions separately" {
    var out = Output{};
    out.write(.high);
    out.write(.high); // redundant: a write, not a transition
    out.write(.low);
    try testing.expectEqual(@as(u32, 3), out.writes);
    try testing.expectEqual(@as(u32, 2), out.transitions);
    try testing.expectEqual(Level.low, out.driven());
}

test "an input returns what the test scripted, counting samples" {
    var input = Input{ .level = .high };
    try testing.expectEqual(Level.high, input.read());
    input.level = .low;
    try testing.expectEqual(Level.low, input.read());
    try testing.expectEqual(@as(u32, 2), input.reads);
}

test "a serial link records what was transmitted" {
    var link = Serial(4){};
    try testing.expect(link.try_write('h'));
    try testing.expect(link.try_write('i'));
    try testing.expectEqualSlices(u8, "hi", link.sent());
    link.clear_sent();
    try testing.expectEqualSlices(u8, "", link.sent());
}

test "a not-ready transmitter refuses every byte" {
    var link = Serial(4){};
    link.tx_ready = false;
    try testing.expect(!link.try_write('h'));
    try testing.expectEqualSlices(u8, "", link.sent());
    link.tx_ready = true;
    try testing.expect(link.try_write('h'));
    try testing.expectEqualSlices(u8, "h", link.sent());
}

test "a dropped write is accepted and lost" {
    var link = Serial(4){};
    link.drop_writes = 2;
    // The caller is told the bytes went out. They did not.
    try testing.expect(link.try_write('a'));
    try testing.expect(link.try_write('b'));
    try testing.expect(link.try_write('c'));
    try testing.expectEqualSlices(u8, "c", link.sent());
    try testing.expectEqual(@as(u32, 0), link.drop_writes);
}

test "a full transmit buffer reports not-ready rather than overwriting" {
    var link = Serial(2){};
    try testing.expect(link.try_write('a'));
    try testing.expect(link.try_write('b'));
    try testing.expect(!link.try_write('c'));
    try testing.expectEqualSlices(u8, "ab", link.sent());
}

test "delivered bytes are received in order, and the queue is bounded" {
    var link = Serial(2){};
    try link.deliver("ab");
    try testing.expectError(error.QueueFull, link.deliver("c"));
    try testing.expectEqual(@as(?u8, 'a'), link.try_read());
    try testing.expectEqual(@as(?u8, 'b'), link.try_read());
    try testing.expectEqual(@as(?u8, null), link.try_read());
    // Space reclaimed once the queue has drained.
    try link.deliver("cd");
    try testing.expectEqual(@as(?u8, 'c'), link.try_read());
}

test "a counter wraps at its width and fast-forwards by milliseconds" {
    var counter = Counter(1_000, 8){ .now = 250 };
    counter.advance(10);
    try testing.expectEqual(@as(u32, 4), counter.ticks());

    var clock = Clock(1_000_000){};
    clock.advance_ms(20);
    try testing.expectEqual(@as(u32, 20_000), clock.ticks());
    try testing.expectEqual(@as(u32, 1_000_000), @TypeOf(clock).ticks_hz);
    try testing.expectEqual(@as(u6, 32), @TypeOf(clock).ticks_bits);
}

test "the fake backends satisfy their contracts" {
    try testing.expect(hal.conforms(hal.digital_out, Output));
    try testing.expect(hal.conforms(hal.digital_in, Input));
    try testing.expect(hal.conforms(hal.serial, Serial(8)));
    try testing.expect(hal.conforms(hal.clock, Clock(1_000_000)));
    try testing.expect(hal.conforms(hal.clock, Counter(1_000, 8)));
}

test "every declaration type-checks" {
    testing.refAllDeclsRecursive(@This());
}
