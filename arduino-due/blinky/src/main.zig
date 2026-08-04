//! Blink an externally wired LED on PD1 (Arduino Due digital pin 26) at 1 Hz,
//! and *check that it actually lit*.
//!
//! Not the on-board D13 LED, on purpose. An on-board LED blinking is weak
//! evidence that this firmware is doing anything: bootloader activity or a
//! watchdog reset loop makes the board blink by itself, and by eye that is
//! indistinguishable from a correct 1 Hz blink. PD1 has no on-board LED, no
//! boot-time role and no peripheral alternate function, so a steady 1 Hz there
//! can only be this code.
//!
//! WHAT IS NEW HERE. Driving a pin was never evidence that the LOAD changed
//! state, and this loop no longer assumes it did. After every commanded
//! transition it waits a bounded settle window and then reads the current-sense
//! feedback path the schematic defines, and it holds enough state to disagree
//! with itself: what it commanded, what it has since sensed, and when the
//! settle window closes. An open jumper, a reversed D1 or a dead output driver
//! used to be invisible from in here. They are not any more.
//!
//! `lib/hal` is deliberately NOT used. This logic reaches its registers
//! directly, exactly as the blinky always has, so that issue #42's before/after
//! comparison of the hardware-abstraction seam is measured against a real state
//! machine rather than against a straight-line loop.
//!
//! Every register address below was taken from the Atmel CMSIS headers in
//! arduino/ArduinoCore-sam rather than from memory; a wrong address here is a
//! silent no-op on real silicon, not a build error.

const std = @import("std");
const start = @import("start.zig");

// start.zig is never called from here -- the hardware enters through its vector
// table -- so without this reference nothing would pull it into the binary.
comptime {
    _ = start;
}

/// Replaces Zig's default panic handler, which drags in message formatting and
/// stack-trace walking -- hundreds of kilobytes that will not fit in 256K of
/// flash, for output nothing here could display anyway.
///
/// Halting rather than resetting is the same choice start.zig makes for faults:
/// a reset loop is precisely the false positive this project exists to rule
/// out, so a panic must stop the LED, never restart it.
pub fn panic(
    msg: []const u8,
    error_return_trace: ?*std.builtin.StackTrace,
    ret_addr: ?usize,
) noreturn {
    _ = msg;
    _ = error_return_trace;
    _ = ret_addr;
    while (true) {}
}

// --- Watchdog -------------------------------------------------------------
// The SAM3X8E watchdog is ENABLED out of reset with a ~16 s timeout, and
// WDT_MR is write-once: whatever is written first sticks until the next reset.
// Disabling it has to be the very first thing that happens.
const WDT_MR: *volatile u32 = @ptrFromInt(0x400E1A54);
const WDT_MR_WDDIS: u32 = 1 << 15;

// --- Power Management Controller ------------------------------------------
// PIO writes are silently dropped while the controller's peripheral clock is
// gated, so every controller used below has to be clocked first. Three now,
// not one: the load, the sense input and the fault lamp are on three different
// PIO controllers, and a missing clock here fails silently rather than loudly.
const PMC_PCER0: *volatile u32 = @ptrFromInt(0x400E0610);
const ID_PIOA: u5 = 11;
const ID_PIOB: u5 = 12;
const ID_PIOD: u5 = 14;

// --- Parallel I/O controllers ---------------------------------------------
// Base addresses: PIOA 0x400E0E00, PIOB 0x400E1000, PIOD 0x400E1400.
// Register offsets from the CMSIS `Pio` struct: PER 0x00, OER 0x10, ODR 0x14,
// SODR 0x30, CODR 0x34, ODSR 0x38, PDSR 0x3C.

/// PD1 == digital pin 26 == `D1`, the blink indicator. Active high.
/// Confirmed against ArduinoCore-sam/variants/arduino_due_x/variant.cpp
/// (entry `// PIN 26`: `{ PIOD, PIO_PD1, ID_PIOD, ... }`).
const LED: u32 = 1 << 1;
const PIOD_PER: *volatile u32 = @ptrFromInt(0x400E1400);
const PIOD_OER: *volatile u32 = @ptrFromInt(0x400E1410);
const PIOD_SODR: *volatile u32 = @ptrFromInt(0x400E1430);
const PIOD_CODR: *volatile u32 = @ptrFromInt(0x400E1434);
const PIOD_ODSR: *volatile u32 = @ptrFromInt(0x400E1438);
const PIOD_PDSR: *volatile u32 = @ptrFromInt(0x400E143C);

/// PA15 == digital pin 24 == the current-sense input, `Q1`'s collector.
/// ACTIVE LOW: it reads 0 while `D1` conducts and 1 while it does not. That
/// polarity is fixed by the schematic's topology box, not chosen here.
const SENSE: u32 = 1 << 15;
const PIOA_PER: *volatile u32 = @ptrFromInt(0x400E0E00);
const PIOA_ODR: *volatile u32 = @ptrFromInt(0x400E0E14);
const PIOA_PDSR: *volatile u32 = @ptrFromInt(0x400E0E3C);

/// PB26 == digital pin 22 == `D2`, the fault lamp. Active high, and it may only
/// ever assert FAULT. It never blinks: solid on, or dark. That is what stops
/// the "who watches the watcher" regress -- every way `D2` can fail lands on
/// dark, which is also the no-fault state, so the alarm can be lost but never
/// counterfeited.
const LAMP: u32 = 1 << 26;
const PIOB_PER: *volatile u32 = @ptrFromInt(0x400E1000);
const PIOB_OER: *volatile u32 = @ptrFromInt(0x400E1010);
const PIOB_SODR: *volatile u32 = @ptrFromInt(0x400E1030);
const PIOB_CODR: *volatile u32 = @ptrFromInt(0x400E1034);

// --- SysTick (ARMv7-M core peripheral) ------------------------------------
const SYST_CSR: *volatile u32 = @ptrFromInt(0xE000E010);
const SYST_RVR: *volatile u32 = @ptrFromInt(0xE000E014);
const SYST_CVR: *volatile u32 = @ptrFromInt(0xE000E018);

const SYST_CSR_ENABLE: u32 = 1 << 0;
const SYST_CSR_CLKSOURCE: u32 = 1 << 2; // 1 = processor clock, 0 = MCK/8
const SYST_CSR_COUNTFLAG: u32 = 1 << 16;

/// No PLL is brought up, so the master clock is still the 4 MHz internal fast
/// RC oscillator the chip selects out of reset. (Arduino's SystemInit() climbs
/// to 84 MHz; this deliberately does not.) Accuracy is that of the RC
/// oscillator, a few percent -- fine for a blink, not a time reference.
const MCK_HZ: u32 = 4_000_000;

/// 500 ms high + 500 ms low = 1 Hz. At 4 MHz that is 2,000,000 ticks, which
/// fits SysTick's 24-bit reload (max 16,777,215) -- the reason this runs off
/// the RC oscillator instead of the PLL, where it would not fit.
const HALF_PERIOD_TICKS: u32 = MCK_HZ / 2;

/// One full down-count of the counter, i.e. `SYST_RVR + 1`. Named separately
/// from the half period because it is used as a *modulus* below, and conflating
/// "how long a half period is" with "what the counter wraps at" is exactly the
/// kind of coincidence that stops being true the moment either changes.
const SYST_PERIOD_TICKS: u32 = HALF_PERIOD_TICKS;

comptime {
    if (HALF_PERIOD_TICKS - 1 > 0xFF_FFFF) {
        @compileError("SysTick reload exceeds 24 bits; halve the clock or divide in software");
    }
}

// --- The settle window ----------------------------------------------------
// After a commanded transition the sense does not respond instantly, so the
// firmware must wait before it is entitled to judge. The wait is BOUNDED BY A
// COUNTER, never by the sense: an "spin until the sense agrees" loop would hang
// on precisely the failure being detected -- a dead D1 -- which is the trap
// docs/zig-style-guide.md §4.2 exists to name.
//
// FLOOR, from the sense topology the schematic chose. `Q1`'s collector is
// pulled up by `R3` = 10 kOhm in parallel with PA15's internal pull-up
// (50-150 kOhm), so the node is driven high through 8.3-9.4 kOhm. Against a
// breadboard node of a few tens of pF -- take 50 pF as the pessimistic figure --
// that is tau ~= 470 ns, and 5 tau ~= 2.4 us to full settle. The 2N3904's own
// switching times (t_on ~35 ns, t_off ~250 ns) are the same order and smaller.
// Call the floor 3 us. The falling edge is faster still: `Q1` pulls that node
// down actively rather than through a resistor.
//
// CEILING, from the blink. The window plus the sample gaps must fit inside the
// 500 ms half period, or the verification would eat the thing it verifies.
//
// CHOSEN: 1 ms. That is ~400x the floor and 1/500th of the ceiling -- margin in
// both directions large enough that neither breadboard stray capacitance nor
// RC-oscillator drift can close it. It costs 0.2 % of a half period and is
// invisible to the eye.
const SETTLE_TICKS: u32 = MCK_HZ / 1000; // 1 ms = 4,000 ticks at 250 ns/tick
const SETTLE_FLOOR_TICKS: u32 = 12; // 3 us, the RC-derived floor above

/// One sample would be electrically sufficient here: rung 3 is a hard logic
/// level, clearing `VIL` by 0.79 V and `VIH` by 0.99 V, and PA15 keeps its
/// Schmitt hysteresis. Three spaced samples are taken anyway because they are
/// nearly free and they catch something one sample cannot -- a node that is
/// oscillating or floating rather than settled, which is what a *partly*
/// connected breadboard looks like.
const SAMPLE_COUNT: u32 = 3;
const SAMPLE_GAP_TICKS: u32 = 4; // 1 us between samples

// How a SUSTAINED mismatch is recognised -- a leaky bucket, and the reason it
// is not a consecutive-mismatch counter is worth writing down, because the
// obvious design is silently broken.
//
// A dead load does NOT disagree on every transition. It disagrees on every
// commanded-ON transition and AGREES on every commanded-OFF one, because "not
// conducting" is the correct answer when the LED was told to be dark:
//
//     commanded   ON    OFF   ON    OFF   ON   ...
//     sensed      off   off   off   off   off
//     verdict     BAD   ok    BAD   ok    BAD
//
// So the run of consecutive mismatches never exceeds ONE, and any threshold of
// two or more can never fire -- for exactly the fault this loop exists to
// catch. The failure alternates in step with the blink.
//
// An integrator does not care about ordering. Each disagreeing transition adds
// MISMATCH_WEIGHT and each agreeing one subtracts AGREEMENT_CREDIT (saturating
// at zero), and the fault is declared at FAULT_SCORE. With 2 and 1, a dead load
// climbs 2,1,3,2,4 and trips on the fifth transition -- about 2.5 s -- while an
// isolated one-off disagreement decays back to zero and is forgotten.
const MISMATCH_WEIGHT: u32 = 2;
const AGREEMENT_CREDIT: u32 = 1;
const FAULT_SCORE: u32 = 4;

comptime {
    if (MISMATCH_WEIGHT <= AGREEMENT_CREDIT) {
        @compileError("a sustained fault must gain more than a good transition " ++
            "forgives, or the score can never reach FAULT_SCORE");
    }
    if (FAULT_SCORE <= MISMATCH_WEIGHT) {
        @compileError("FAULT_SCORE at or below MISMATCH_WEIGHT makes a single " ++
            "disagreement fatal; that is not a *sustained* mismatch");
    }
}

comptime {
    if (SETTLE_TICKS < SETTLE_FLOOR_TICKS) {
        @compileError("settle window is below the sense node's RC response " ++
            "floor; see resource-budget.md §3");
    }
    if (SETTLE_TICKS + (SAMPLE_COUNT - 1) * SAMPLE_GAP_TICKS >= HALF_PERIOD_TICKS) {
        @compileError("settle window plus sample gaps does not fit inside the 500 ms half period");
    }
}

// --- State worth being wrong about ----------------------------------------

/// What the firmware believes about the load, held explicitly rather than
/// inferred from where control flow happens to be.
///
/// Reached through a `volatile` pointer on purpose, and that is a design
/// decision rather than a workaround: the fault response is a halt, and the
/// fault response policy sends you to an SWD probe to find out *why* the board
/// stopped. State the optimiser had kept in registers would not survive to be
/// read. This is the only RAM this firmware uses.
const LoadState = extern struct {
    /// The level last driven onto PD1. 1 = commanded lit.
    commanded: u32 = 0,
    /// The level last read back from the sense. 1 = D1 conducting.
    sensed: u32 = 0,
    /// The SysTick counter value at which the open settle window closes.
    settle_deadline: u32 = 0,
    /// Leaky-bucket score over disagreeing transitions. `FAULT_SCORE` trips.
    mismatch_score: u32 = 0,
};

var load_state: LoadState = .{};
const load: *volatile LoadState = &load_state;

pub fn main() noreturn {
    WDT_MR.* = WDT_MR_WDDIS;

    PMC_PCER0.* = (@as(u32, 1) << ID_PIOA) |
        (@as(u32, 1) << ID_PIOB) |
        (@as(u32, 1) << ID_PIOD);

    // The load: claim PD1 from the peripheral mux and drive it out.
    PIOD_PER.* = LED;
    PIOD_OER.* = LED;

    // The fault lamp: driven LOW before the output driver is enabled, so a
    // board coming up cannot flash a fault it has not detected.
    PIOB_CODR.* = LAMP;
    PIOB_PER.* = LAMP;
    PIOB_OER.* = LAMP;

    // The sense: claim PA15 and explicitly disable its output driver. Its
    // internal pull-up is left in the enabled state it powers up in; `R3` also
    // pulls the node up, so the design does not depend on it either way.
    PIOA_PER.* = SENSE;
    PIOA_ODR.* = SENSE;

    SYST_RVR.* = HALF_PERIOD_TICKS - 1;
    SYST_CVR.* = 0; // any write clears the counter and COUNTFLAG
    SYST_CSR.* = SYST_CSR_ENABLE | SYST_CSR_CLKSOURCE;

    while (true) {
        waitHalfPeriod();
        commandAndVerify(true);
        waitHalfPeriod();
        commandAndVerify(false);
    }
}

/// Drive the load to `on`, then establish that it got there -- climbing the
/// schematic's ladder of what "verify" can mean, cheapest rung first.
fn commandAndVerify(on: bool) void {
    load.commanded = @intFromBool(on);
    if (on) PIOD_SODR.* = LED else PIOD_CODR.* = LED;

    // Rung 1: the output register accepted the write. Free, and it is the one
    // check that catches an unclocked PIO controller -- the silent no-op this
    // whole file's header warns about.
    if ((PIOD_ODSR.* & LED != 0) != on) fault();

    // Rung 2: the pad reached the commanded level. Also free, and blind to an
    // open circuit: the pad's level is set by the driver, not by the load.
    // Neither rung is feedback. Both are worth their bytes anyway.
    if ((PIOD_PDSR.* & LED != 0) != on) fault();

    // Rung 3: the load actually conducted. This is the one that needs hardware,
    // and the only one an unplugged D1 cannot fool.
    awaitSettle();

    var agreed = true;
    var i: u32 = 0;
    while (i < SAMPLE_COUNT) : (i += 1) {
        if (i > 0) awaitTicks(SAMPLE_GAP_TICKS);
        const conducting = PIOA_PDSR.* & SENSE == 0; // ACTIVE LOW
        load.sensed = @intFromBool(conducting);
        if (conducting != on) agreed = false;
    }

    const score = load.mismatch_score;
    if (agreed) {
        // Saturating, because u32 would wrap to ~4 billion and read as a fault.
        load.mismatch_score = if (score > AGREEMENT_CREDIT) score - AGREEMENT_CREDIT else 0;
    } else {
        load.mismatch_score = score + MISMATCH_WEIGHT;
        if (load.mismatch_score >= FAULT_SCORE) fault();
    }
}

/// Open the settle window and wait it out.
///
/// The deadline is recorded before the wait rather than being kept on the
/// stack, because it is part of what the board knows about itself: after a halt
/// it says how far through the window the verdict was reached.
fn awaitSettle() void {
    const opened = SYST_CVR.*;
    load.settle_deadline = if (opened >= SETTLE_TICKS)
        opened - SETTLE_TICKS
    else
        opened + (SYST_PERIOD_TICKS - SETTLE_TICKS);
    awaitTicks(SETTLE_TICKS);
}

/// Spin for `ticks` SysTick counts. Bounded by the counter and by nothing else:
/// no sense reading can extend it, which is the whole point.
fn awaitTicks(ticks: u32) void {
    const opened = SYST_CVR.*;
    while (elapsedSince(opened) < ticks) {}
}

/// Ticks elapsed since `opened`, on a counter that counts DOWN and wraps at
/// `SYST_PERIOD_TICKS`. Written as modular arithmetic rather than a plain
/// subtraction so that a reload landing inside a window stays correct; in
/// practice one never does, because every window opens just after the wrap the
/// half-period wait returned on.
fn elapsedSince(opened: u32) u32 {
    const now = SYST_CVR.*;
    return if (now <= opened) opened - now else opened + (SYST_PERIOD_TICKS - now);
}

/// Spin until SysTick wraps. Reading SYST_CSR clears COUNTFLAG as a side
/// effect, which is what makes this poll self-rearming: each read consumes the
/// flag, so the next call waits for a fresh wrap rather than returning at once.
fn waitHalfPeriod() void {
    while (SYST_CSR.* & SYST_CSR_COUNTFLAG == 0) {}
}

/// The mismatch response, and the one place this firmware drives `D2`.
///
/// Safe state first, then report, then halt -- in that order, and the order is
/// the argument. Driving the load low makes the reported picture single-valued:
/// dark red plus solid green is a detected fault and nothing else, where a
/// frozen-on red could still be misread as "working but stuck". Then `D2` is
/// asserted, which is the only reason the second indicator exists: the fault
/// being reported is "the load did not light", so reporting it *through* the
/// load would make a halted board and a dead board the same picture.
///
/// Full reasoning, and why this refines rather than contradicts the project's
/// bare-halt policy for CPU faults: fault-response-policy.md, fields 3 and 7.
fn fault() noreturn {
    PIOD_CODR.* = LED;
    PIOB_SODR.* = LAMP;
    while (true) {}
}
