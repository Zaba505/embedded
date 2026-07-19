//! Blink an externally wired LED on PB26 (Arduino Due digital pin 22) at 1 Hz.
//!
//! Not the on-board D13 LED, on purpose. An on-board LED blinking is weak
//! evidence that this firmware is doing anything: bootloader activity or a
//! watchdog reset loop makes the board blink by itself, and by eye that is
//! indistinguishable from a correct 1 Hz blink. PB26 has no on-board LED, no
//! boot-time role and no peripheral alternate function, so a steady 1 Hz there
//! can only be this code.
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
// gated, so PIOB has to be clocked before any of the registers below take.
const PMC_PCER0: *volatile u32 = @ptrFromInt(0x400E0610);
const ID_PIOB: u5 = 12;

// --- Parallel I/O controller B --------------------------------------------
const PIOB_PER: *volatile u32 = @ptrFromInt(0x400E1000); // PIO Enable (claim from peripheral mux)
const PIOB_OER: *volatile u32 = @ptrFromInt(0x400E1010); // Output Enable
const PIOB_SODR: *volatile u32 = @ptrFromInt(0x400E1030); // Set Output Data
const PIOB_CODR: *volatile u32 = @ptrFromInt(0x400E1034); // Clear Output Data

/// PB26 == Arduino Due digital pin 22, confirmed against
/// ArduinoCore-sam/variants/arduino_due_x/variant.cpp (entry `// PIN 22`).
/// Active high: driving it high lights the LED.
const LED: u32 = 1 << 26;

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

comptime {
    if (HALF_PERIOD_TICKS - 1 > 0xFF_FFFF) {
        @compileError("SysTick reload exceeds 24 bits; halve the clock or divide in software");
    }
}

pub fn main() noreturn {
    WDT_MR.* = WDT_MR_WDDIS;

    PMC_PCER0.* = @as(u32, 1) << ID_PIOB;

    PIOB_PER.* = LED;
    PIOB_OER.* = LED;

    SYST_RVR.* = HALF_PERIOD_TICKS - 1;
    SYST_CVR.* = 0; // any write clears the counter and COUNTFLAG
    SYST_CSR.* = SYST_CSR_ENABLE | SYST_CSR_CLKSOURCE;

    while (true) {
        waitHalfPeriod();
        PIOB_SODR.* = LED;
        waitHalfPeriod();
        PIOB_CODR.* = LED;
    }
}

/// Spin until SysTick wraps. Reading SYST_CSR clears COUNTFLAG as a side
/// effect, which is what makes this poll self-rearming: each read consumes the
/// flag, so the next call waits for a fresh wrap rather than returning at once.
fn waitHalfPeriod() void {
    while (SYST_CSR.* & SYST_CSR_COUNTFLAG == 0) {}
}
