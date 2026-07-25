//! The register facts the two benchmark roots share, for whichever of the two
//! benchmark architectures is being built.
//!
//! Both roots read their addresses, masks and bit senses from here, so the only
//! difference between the two images is **how the logic reaches the hardware** --
//! through the seam or by hand -- and never which hardware it reaches. That is
//! what makes the `.text` delta attributable to the seam alone.
//!
//! Two very different machines on purpose, because "architecture-neutral" is a
//! claim about more than one of them:
//!
//! | | Cortex-M3 (thumb) | Cortex-A53 (aarch64) |
//! |---|---|---|
//! | Chip | Atmel SAM3X8E (Arduino Due) | Broadcom BCM2837 (Raspberry Pi 3B/3B+) |
//! | GPIO | PIO controller, `SODR`/`CODR`/`ODSR`/`PDSR` | GPIO block, `GPSET0`/`GPCLR0`/`GPLEV0` |
//! | Serial | USART, `US_CSR` ready-when-**set** | PL011, `UARTFR` ready-when-**clear** |
//! | Counter | Timer/Counter `TC_CV` | System timer `CLO` |
//!
//! The two GPIO blocks share a register *shape* and the two UARTs do not even
//! share a bit sense, which is exactly the spread the seam has to absorb.
//!
//! ## What these values are, and what they are not
//!
//! The **addresses and bit positions are datasheet facts**, taken from the
//! Atmel SAM3X8E and Broadcom BCM2835/BCM2837 peripheral documentation, the
//! same way the blinky takes its addresses "from the vendor's numbers, not the
//! vendor's code" (style guide §8.1). The blinky's own `PIOB` addresses are
//! reused verbatim where they overlap.
//!
//! The **pin masks are measurement placeholders, not pin assignments.** No
//! schematic in this repo assigns a gate, a switch or a button to these bits.
//! Under the hardware-first rule (`CLAUDE.md`) that assignment is the
//! smart-light hardware story's (#31) to make, on a committed electrical
//! diagram, before any firmware claims a pin. These images exist to be
//! measured and are never flashed; a mask is here only because a store needs
//! one, and the measurement is identical whichever bit it names.

const builtin = @import("builtin");

/// Which of the two benchmark architectures this build is for.
pub const is_cortex_m = builtin.cpu.arch == .thumb;

// --- GPIO -----------------------------------------------------------------

/// Write the mask here to drive the output pin high.
/// SAM3X8E `PIOB_SODR` (0x400E1030, as the blinky uses) / BCM2837 `GPSET0`.
pub const gpio_set: *volatile u32 = @ptrFromInt(if (is_cortex_m) 0x400E1030 else 0x3F20001C);

/// Write the mask here to drive it low. `PIOB_CODR` / `GPCLR0`.
pub const gpio_clear: *volatile u32 = @ptrFromInt(if (is_cortex_m) 0x400E1034 else 0x3F200028);

/// Read the driven level here. `PIOB_ODSR` / `GPLEV0`.
pub const gpio_state: *volatile u32 = @ptrFromInt(if (is_cortex_m) 0x400E1038 else 0x3F200034);

/// Read input pin levels here. `PIOB_PDSR` / `GPLEV0`.
pub const gpio_level: *volatile u32 = @ptrFromInt(if (is_cortex_m) 0x400E103C else 0x3F200034);

/// The output pin's bit. A placeholder; see the header.
pub const output_mask: u32 = 1 << 26;

/// The input pin's bit. A placeholder; see the header.
pub const input_mask: u32 = 1 << 25;

/// The input is pulled up and closes to ground, so a closed switch reads 0 --
/// the arrangement a schematic normally fixes, and the one that makes polarity
/// worth having in the backend rather than in the logic.
pub const input_active_low: bool = true;

// --- Serial ---------------------------------------------------------------

/// The status register carrying both ready bits.
/// SAM3X8E `US_CSR` (USART0 + 0x14) / BCM2837 PL011 `UARTFR` (UART0 + 0x18).
pub const uart_status: *volatile u32 = @ptrFromInt(if (is_cortex_m) 0x40098014 else 0x3F201018);

/// Write a byte here to transmit. `US_THR` (+0x1C) / `UARTDR` (+0x00).
pub const uart_transmit: *volatile u32 = @ptrFromInt(if (is_cortex_m) 0x4009801C else 0x3F201000);

/// Read a received byte here. `US_RHR` (+0x18) / `UARTDR` (+0x00, the same
/// register as the transmit side on a PL011).
pub const uart_receive: *volatile u32 = @ptrFromInt(if (is_cortex_m) 0x40098018 else 0x3F201000);

/// The transmitter-ready bit: `US_CSR.TXRDY` (bit 1, raised when ready) or
/// `UARTFR.TXFF` (bit 5, raised when the FIFO is FULL).
pub const uart_transmit_mask: u32 = if (is_cortex_m) 1 << 1 else 1 << 5;

/// Whether that bit means ready when set. False on the PL011 -- the whole
/// reason the seam takes a bit *sense* rather than assuming one.
pub const uart_transmit_ready_when_set: bool = is_cortex_m;

/// The byte-waiting bit: `US_CSR.RXRDY` (bit 0, raised when a byte is waiting)
/// or `UARTFR.RXFE` (bit 4, raised when the FIFO is EMPTY).
pub const uart_receive_mask: u32 = if (is_cortex_m) 1 << 0 else 1 << 4;

/// Whether that bit means a byte is waiting when set.
pub const uart_receive_ready_when_set: bool = is_cortex_m;

/// The data bits of the receive register. The PL011 reports framing, parity and
/// break errors above the byte; the USART reports them in `US_CSR`.
pub const uart_data_mask: u32 = 0xFF;

// --- Counter --------------------------------------------------------------

/// A free-running up-counter. SAM3X8E `TC0` channel 0 `TC_CV` (0x40080010) /
/// BCM2837 system timer `CLO` (0x3F003004).
pub const counter: *volatile u32 = @ptrFromInt(if (is_cortex_m) 0x40080010 else 0x3F003004);

/// The counter's rate. 1 MHz is the BCM2837 system timer's fixed rate and a
/// plausible prescaler for the SAM3X8E's `TC0`; the SAM3X figure is a
/// placeholder like the pin masks, since what the timer is actually programmed
/// to is a bring-up decision no committed diagram or firmware has made.
pub const counter_hz: u32 = 1_000_000;
