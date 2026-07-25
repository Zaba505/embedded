//! Benchmark root: the same logic written as **hand-written register pokes**.
//!
//! The control image for `seam.zig`. This is what the firmware would look like
//! without the seam -- the blinky's style, reaching straight out to the
//! addresses -- so the `.text` difference between the two is exactly what the
//! abstraction costs. See ../README.md, "Evidence: the seam is free".
//!
//! The body of `_start` below is deliberately statement-for-statement identical
//! to `seam.zig`'s; only the helpers underneath differ. Anything else would
//! measure the two *programs* rather than the two *styles*.

const chip = @import("chip.zig");

/// How long the switch must read the same way before the change is believed.
const debounce_ms: u32 = 20;

/// The same interval in counter ticks. Computed at compile time, as the seam's
/// `ticks_for_ms` does -- the arithmetic is free either way; what is being
/// measured is the access, not the multiply.
const debounce_ticks: u32 = chip.counter_hz / 1000 * debounce_ms;

/// The command that toggles the load, and the two state reports.
const toggle_command: u8 = 'T';
const report_on: u8 = '1';
const report_off: u8 = '0';

export fn _start() callconv(.C) noreturn {
    var settled = wall_is_active();
    var settled_at = ticks();

    while (true) {
        const sampled = wall_is_active();
        if (sampled == settled) {
            settled_at = ticks();
        } else if (elapsed_since(settled_at) >= debounce_ticks) {
            settled = sampled;
            settled_at = ticks();
            if (sampled) {
                gate_toggle();
                _ = try_write(if (gate_is_high()) report_on else report_off);
            }
        }

        if (try_read()) |command| {
            if (command == toggle_command) {
                gate_toggle();
                _ = try_write(if (gate_is_high()) report_on else report_off);
            }
        }
    }
}

/// Whether the wall switch is closed, with its active-low wiring applied by
/// hand -- the inversion the seam's backend would carry.
inline fn wall_is_active() bool {
    const closed = chip.gpio_level.* & chip.input_mask != 0;
    return if (chip.input_active_low) !closed else closed;
}

/// Whether the gate is currently driven high.
inline fn gate_is_high() bool {
    return chip.gpio_state.* & chip.output_mask != 0;
}

/// Flip the gate: read the driven level back, then write the opposite.
inline fn gate_toggle() void {
    if (gate_is_high()) {
        chip.gpio_clear.* = chip.output_mask;
    } else {
        chip.gpio_set.* = chip.output_mask;
    }
}

/// The counter's current value.
inline fn ticks() u32 {
    return chip.counter.*;
}

/// Ticks since `start`, wrapping-safe.
inline fn elapsed_since(start: u32) u32 {
    return ticks() -% start;
}

/// Offer one byte to the transmitter; false if it was not ready.
inline fn try_write(byte: u8) bool {
    const flagged = chip.uart_status.* & chip.uart_transmit_mask != 0;
    const ready = if (chip.uart_transmit_ready_when_set) flagged else !flagged;
    if (!ready) return false;
    chip.uart_transmit.* = byte;
    return true;
}

/// Take one received byte, or null if none is waiting.
inline fn try_read() ?u8 {
    const flagged = chip.uart_status.* & chip.uart_receive_mask != 0;
    const ready = if (chip.uart_receive_ready_when_set) flagged else !flagged;
    if (!ready) return null;
    return @truncate(chip.uart_receive.* & chip.uart_data_mask);
}
