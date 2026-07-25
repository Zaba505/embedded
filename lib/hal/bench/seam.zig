//! Benchmark root: the logic written **through the seam**.
//!
//! Paired with `direct.zig`, which implements the identical logic as
//! hand-written register pokes. Both read their addresses and masks from
//! `chip.zig`, so `seam.text - direct.text` is the seam's runtime cost and
//! nothing else. See ../README.md, "Evidence: the seam is free".
//!
//! The logic is deliberately small but exercises all four contracts and has
//! real data-dependent control flow -- a debounced input, a toggled output, a
//! command read off a link, a report written back -- because an abstraction's
//! cost shows up in branches and reloads, not in straight-line stores.

const hal = @import("hal");
const chip = @import("chip.zig");

/// The load's gate, driven through the port's set/clear register pair.
const Gate = hal.DigitalOut(hal.mmio.SetClearOutput(.{
    .set = chip.gpio_set,
    .clear = chip.gpio_clear,
    .state = chip.gpio_state,
    .mask = chip.output_mask,
}));

/// The wall switch, sampled from the port's level register.
const Wall = hal.DigitalIn(hal.mmio.LevelInput(.{
    .level = chip.gpio_level,
    .mask = chip.input_mask,
    .active_low = chip.input_active_low,
}));

/// The command link, polled through the UART's status and data registers.
const Link = hal.Serial(hal.mmio.PolledSerial(.{
    .status = chip.uart_status,
    .transmit_data = chip.uart_transmit,
    .receive_data = chip.uart_receive,
    .transmit_ready_mask = chip.uart_transmit_mask,
    .transmit_ready_when = if (chip.uart_transmit_ready_when_set) .set else .clear,
    .receive_ready_mask = chip.uart_receive_mask,
    .receive_ready_when = if (chip.uart_receive_ready_when_set) .set else .clear,
    .data_mask = chip.uart_data_mask,
}));

/// Time, read from the free-running counter.
const Timer = hal.Clock(hal.mmio.FreeRunningCounter(.{
    .value = chip.counter,
    .ticks_hz = chip.counter_hz,
}));

/// How long the switch must read the same way before the change is believed.
const debounce_ms: u32 = 20;

/// The command that toggles the load, and the two state reports.
const toggle_command: u8 = 'T';
const report_on: u8 = '1';
const report_off: u8 = '0';

export fn _start() callconv(.C) noreturn {
    var gate = Gate.init(.{});
    var wall = Wall.init(.{});
    var link = Link.init(.{});
    var timer = Timer.init(.{});

    var settled = wall.is_active();
    var settled_at = timer.ticks();

    while (true) {
        // Sample-and-settle debounce: any disagreement with the settled state
        // must persist for the whole interval before it is believed.
        const sampled = wall.is_active();
        if (sampled == settled) {
            settled_at = timer.ticks();
        } else if (timer.has_elapsed_ms(settled_at, debounce_ms)) {
            settled = sampled;
            settled_at = timer.ticks();
            if (sampled) {
                gate.toggle();
                _ = link.try_write(if (gate.driven().is_high()) report_on else report_off);
            }
        }

        // A remote command is the second, independent way the load changes.
        if (link.try_read()) |command| {
            if (command == toggle_command) {
                gate.toggle();
                _ = link.try_write(if (gate.driven().is_high()) report_on else report_off);
            }
        }
    }
}
