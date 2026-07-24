# smart-light

A wall switch, an LED on its own 5 V supply, and a bare-metal Raspberry Pi that can toggle it over a
UART — controlled by an [Arduino Due](https://docs.arduino.cc/hardware/due/) (Atmel SAM3X8E).

The "light" is `D2`, the same 5 mm red LED [blinky](../arduino-due/blinky/README.md) uses. What is
different is *where* it sits: not on an I/O pin, but on a dedicated 5 V rail with a MOSFET underneath
it. The switching topology is sized for a 1 A load; the LED draws 9 mA of that. Both numbers appear
throughout these sheets and they are never interchangeable — see
[Two currents](#two-currents-and-which-one-a-number-means).

**There is no firmware here yet, and that is the point.** Per the repo's
[hardware-first rule](../CLAUDE.md), the electrical design is the first deliverable of a project and
is committed and reviewed on its own. This directory currently holds exactly that: the KiCad
schematics for the whole system, in [`hardware/`](hardware/). Every firmware story that follows
implements *against* these sheets and cites them for pin assignments, component values and the
electrical ceilings its `resource-budget.md` has to respect.

## Layout: grouped by system, not by vendor

The rest of this repo groups projects by board vendor (`arduino-due/blinky`). `smart-light` is the
first project that spans **two boards from different families** — an Atmel Cortex-M microcontroller
and a Broadcom Cortex-A SoC — plus a shared protocol that belongs to neither. Filing it under one
vendor would put half the system in the wrong place, so it is grouped by *system* instead:

```
smart-light/
  hardware/     the electrical design for the whole system   <- this story, and only this
  due/          Arduino Due firmware                          (later)
  pi/           bare-metal Raspberry Pi firmware              (later)
  protocol/     the shared, architecture-neutral UART codec   (later)
```

The repo [README](../README.md) lists both layouts. Neither is "the" convention: a single-board
project stays under its vendor, a multi-board system gets its own top-level directory.

## The system in one picture

![System overview](hardware/smart-light.svg)

Two boards, three supplies, one ground:

- The **Due** switches the light through a low-side MOSFET on a **dedicated 5 V rail** and reads a
  mechanical **wall switch**.
- The **Pi** runs bare metal, has a **button** (standing in for "a message arrived from an app") and
  a **boot/status LED**, and talks to the Due over a **3.3 V UART**.
- The **light** never draws current through an I/O pin, and it is **off** whenever the Due is in
  reset, unprogrammed, or halted after a fault.

### Two currents, and which one a number means

Two LEDs in this system are wired in genuinely different ways, and the contrast is the point:

| | Driven by | Series R | Current | Limited by |
|---|---|---|---|---|
| `D1`, Pi status LED (sheet 5) | `GPIO17` **directly** | `R7` = 1 kΩ | 1.4 mA | the pin's 8 mA drive |
| `D2`, the light (sheet 3) | `Q1`, off the **PS3 rail** | `R14` = 330 Ω | 9.1 mA | only the rail and `R14` |

`D1` is blinky's arrangement: an LED hanging off a GPIO, its brightness capped by what the pin may
source. `D2` is what this project is actually about — the pin drives a *gate*, the load current comes
from somewhere else entirely, and the LED could be a 1 A lamp without the firmware knowing.

Which means **`Q1`, `PS3`, `C1` and the star ground are all sized for 1 A, and `D2` draws 9 mA of
it.** That gap is deliberate: a real 5 V light can replace `D2` with no other change. But it makes
every current on these sheets ambiguous unless it says which it is, so they all do. Where a sheet
says 1 A it means *the ceiling this switch is built to permit*, never the current flowing today.

The honest cost of that choice: a 62 A MOSFET is switching 9 mA, `PS3` is roughly two hundred times
the supply `D2` needs, and the star ground buys 2.7 mV of margin where it was drawn to buy 300 mV.
The sheets say so rather than letting the arithmetic imply a load that is not there.

## The sheets

Editable KiCad source is in [`hardware/`](hardware/); the SVG next to each is the export of that
sheet. Each firmware story implements against exactly one of them.

### 2 — Power and ground

![Power and ground](hardware/smart-light-power-and-ground.svg)

Three separate 5 V rails that are never bridged, and a **star ground at the load supply's negative
terminal** with exactly three legs. Q1 switches in about 1 µs and a 300 mm jumper is roughly 0.3 µH,
so `V = L·di/dt` on a wire shared between the load return and a signal reference gives:

| | Ground bounce | Against the Pi's 0.9 V low-level margin |
|---|---|---|
| at the 1 A ceiling | **300 mV** | a third of it, from wiring alone |
| with `D2` fitted | **2.7 mV** | nothing |

Only the first row justifies a star ground, and it is not the row that applies today. It is drawn
anyway because grounds are the one thing that cannot be re-planned after the fact — a rig wired star
from the start survives a real light replacing `D2`, a rig wired as a daisy chain has to come apart
first — and because the star costs exactly one jumper.

### 3 — Due low-side load switch

![Due load switch](hardware/smart-light-due-load-switch.svg)

`D24`/`PA15` → 1 kΩ → the gate of an IRLB8721PbF, with `R14` → `D2` on PS3 and a 12 kΩ gate pulldown.

The load branch is `+5V_LOAD` → `R14` (330 Ω) → `D2` anode, cathode → Q1's drain:

```
I = (5.0 V − Vf) / 330 Ω = (5.0 − 2.0) / 330 = 9.1 mA
```

Q1's drain-source drop is not in that sum — at 9 mA even a pessimistic 160 mΩ contributes 1.4 mV.
Across the 1.8–2.1 V Vf spread of red LEDs the current lands between 8.8 and 9.7 mA, under half a
5 mm LED's 20 mA rating. `R14` dissipates 27 mW, `D2` about 18 mW. Anode (long leg, round rim) goes
to `R14`; cathode (short leg, flat on the rim) to Q1's drain. Backwards, `D2` simply never lights and
nothing is damaged — so a dark load with a correct gate voltage is a polarity check before it is a
fault.

**This sheet is why the hardware-first rule exists.** "Default-OFF" needs more than a gate pulldown,
because the SAM3X datasheet (§31.5.1) says *"After reset, all of the pull-ups are enabled, i.e.
`PIO_PUSR` resets at the value 0x0."* Out of reset `PA15` is not high-impedance — it is an input with
a 50–150 kΩ pull-up fighting the pulldown through R1. With the textbook 100 kΩ pulldown:

| | | |
|---|---|---|
| `R2` = 100 kΩ | `3.3 V × 100k / (50k + 1k + 100k)` | **2.18 V** — above the 1.80 V *typical* gate threshold |
| `R2` = 12 kΩ | `3.3 V × 12k / (50k + 1k + 12k)` | **0.63 V** — below the 1.35 V *minimum* threshold, 2× margin |

An unprogrammed board with the 100 kΩ part sits with the MOSFET half-enhanced, dissipating, light
glowing. No firmware can fix that, because none is running. The sheet records the design *rule*, not
just the number: **`V_gate` at reset must stay below the MOSFET's minimum `V_GS(th)` with the
internal pull-up at its minimum resistance.**

This argument is untouched by the load being an LED. It is about the gate, and the gate does not know
what is on the drain — which is exactly why it was worth settling before any firmware exists.

### 4 — Due wall switch

![Due wall switch](hardware/smart-light-due-wall-switch.svg)

`SW1` → 4.7 kΩ pull-up, 470 Ω series, 100 nF → `D26`/`PD1`, active low, never floating. The pull-up
is external so the rest state is a property of the board rather than of a register that firmware has
not written yet. `PD1` is chosen because Table 45-2's hysteresis exception list — which includes
`PD[10–30]` — does *not* include it: this is the one pin in the system fed by a deliberately slowed
edge, and it needs a Schmitt input.

The RC is sized to kill sub-millisecond chatter and guarantee a monotonic edge, and the sheet is
explicit that it does **not** debounce the switch. Swallowing 10 ms of bounce in hardware alone would
take ~100 µF and would blur a real press; the settle is firmware's job.

### 5 — Pi button and status LED

![Pi button and status LED](hardware/smart-light-pi-button-and-led.svg)

`SW2` → the same debounce network → `GPIO27` (J8 pin 13); `GPIO17` (J8 pin 11) → 1 kΩ → `D1`.

`GPIO27` powers up with a **50–65 kΩ internal pull-down** (BCM2835 ARM Peripherals table 6-31 lists
GPIO9–27 as "Low"), so the pull-up has to win a divider that is already there: 4.7 kΩ gives a 3.02 V
released level at the worst corner, while a perfectly reasonable-looking 47 kΩ would give 1.70 V —
0.1 V above `V_IH` min, which works on the bench and fails on a warm day.

That same default pull-down is what makes `D1` dark at power-on for free. Worth noticing that the two
boards default in **opposite** directions: on the Pi it costs nothing, on the Due it had to be built
out of a resistor and defended.

### 6 — UART interconnect

![UART interconnect](hardware/smart-light-uart-interconnect.svg)

Due `USART0` (`D18`/`TX1`/`PA11`, `D19`/`RX1`/`PA10`) ↔ Pi `PL011` (`GPIO14`/`TXD0`, `GPIO15`/`RXD0`),
3.3 V at both ends, TX↔RX crossed exactly once, two wires and no ground wire (ground is shared at the
star point).

Two details the sheet settles that firmware would otherwise have to work around:

- **220 Ω in series at every pin — four, not two.** A resistor in the middle of a wire only protects
  whichever end is on the far side of it. One at each pin means 5 V landing anywhere on the harness
  is limited to `(5 − 3.3 − 0.7) / 220 = 4.5 mA` into the clamp diode, from either direction. At
  115200 baud the cost is a 13 ns time constant against an 8.7 µs bit.
- **10 kΩ idle pull-ups at each receiver.** An idle UART line is *high*, but `GPIO15` powers up with
  a default pull-*down*, so an unplugged or unpowered Due would leave the Pi's receiver reading a
  permanent break condition and a stream of framing errors. The pull-ups make "the other board isn't
  there" indistinguishable from "the other board has nothing to say" — which is what lets the wall
  switch keep working with the Pi unplugged, settled in hardware before any firmware exists.

## Regenerating the SVGs

The exports are checked in so the diagrams render on the web, but they are derived. Regenerate all
six with a single command from `smart-light/hardware/`:

```sh
flatpak run --command=kicad-cli org.kicad.KiCad sch export svg \
  --no-background-color --draw-hop-over --output . smart-light.kicad_sch
```

(Drop the `flatpak run --command=kicad-cli org.kicad.KiCad` prefix if KiCad is installed natively.
`--draw-hop-over` matters: it draws a hop where wires cross without connecting, which is what makes
the TX↔RX crossover on sheet 6 unambiguous.) The sub-sheet names are deliberately the same
kebab-case strings as the filenames, so the export lands on `smart-light-<sheet>.svg` with no
renaming step.

The design passes electrical rules checking with **zero violations**:

```sh
flatpak run --command=kicad-cli org.kicad.KiCad sch erc --severity-all smart-light.kicad_sch
```

That is worth running after any edit. ERC is what catches a wire that *looks* connected in the
export but is not, and the netlist it builds is the only mechanical check that the TX↔RX crossover
is actually crossed.

## Pin assignments

Every later story cites this table rather than a board pinout site.

**Arduino Due** — SAM3X8E, 144-lead LQFP, 3.3 V logic. Port mapping from
[`ArduinoCore-sam`](https://github.com/arduino/ArduinoCore-sam/blob/master/variants/arduino_due_x/variant.cpp);
header positions from the Arduino Due datasheet A000062 §6.2.2 and §6.2.4.

| Signal | Arduino | SAM3X | Header, position | Table 45-2 group |
|---|---|---|---|---|
| MOSFET gate | `D24` | `PA15` | `D22`–`D53` LHS, pos 3 | Group 1 |
| Wall switch | `D26` | `PD1` | `D22`–`D53` LHS, pos 4 | Group 1 |
| UART transmit | `D18`/`TX1` | `PA11` | 26-pin, pos 23 | Group 2 |
| UART receive | `D19`/`RX1` | `PA10` | 26-pin, pos 24 | Group 2 |
| `+3V3` | — | — | 24-pin, pos 4 | — |
| `GND` (switch return) | — | — | 24-pin, pos 6 | — |
| `GND` (star leg 2) | — | — | `D22`–`D53` LHS, pos 18 | — |

> **`+5V` is position 1 on both rows of the `D22`–`D53` header.** `D24` is the third pin in. A
> two-position slip back-feeds 5 V into `PA15` through R1 and exceeds the SAM3X's absolute maximum
> input rating of +4.0 V (table 45-1). Count twice, and confirm position 18 really is ground with a
> continuity check before applying power.

**Raspberry Pi** — 40-pin J8, 3.3 V logic. Default pulls from BCM2835 ARM Peripherals table 6-31.
The header is identical across Pi 2/3/4/5 and Zero 2 W; the reference build is a **Pi 3 Model B+**
(BCM2837B0, Cortex-A53), which pins down firmware-side facts (target triple, kernel image name, load
address, peripheral base) that these sheets do not constrain.

| Signal | BCM | J8 pin | Default pull | Alternate used |
|---|---|---|---|---|
| Status LED | `GPIO17` | 11 | pull-down, 50–65 kΩ | none |
| Button | `GPIO27` | 13 | pull-down, 50–65 kΩ | none |
| UART transmit | `GPIO14` | 8 | pull-down | ALT0 = `TXD0` |
| UART receive | `GPIO15` | 10 | pull-down | ALT0 = `RXD0` |
| `3V3` | — | 1 or 17 | — | — |
| `GND` | — | 6 or 14 | — | — |

> **Pin 2 and pin 4 are 5 V, and pin 2 sits directly opposite pin 1's 3V3.** Pin 1 is the square pad
> at the micro-SD end. The Raspberry Pi documentation is unambiguous that over-voltage on a GPIO
> triggers latch-up, which shorts the 3V3 rail *inside the die*; the board does not recover.

## Electrical ceilings

These are the rows the firmware stories' `resource-budget.md` §4 inherits, from the repo-wide
[template](../docs/resource-budget.md). They are limits, not budgets — what the hardware permits.

| | Value | Source |
|---|---|---|
| **Due — I/O voltage tolerance** | **3.3 V only** | SAM3X table 45-1: −0.3 V to +4.0 V absolute max on an input pin |
| Due — `VIL` max / `VIH` min | 0.99 V / 2.31 V | table 45-2, `0.3 ×`/`0.7 × VDDIO` |
| Due — `IOH` per pin | −15 mA (Group 1) / −3 mA (Group 2) | table 45-2 at `VOH = VDDIO − 0.4 V`, notes 2 and 3 |
| Due — `IOL` per pin | 9 mA (Group 1) / 6 mA (Group 2) | table 45-2 at `VOL = 0.4 V` |
| Due — input hysteresis | 150–500 mV, on most pins | table 45-2 `Vhys`, with an exception list |
| Due — internal pull-up | 50–150 kΩ, **enabled after reset** | table 45-2 `RPULLUP`; §31.5.1 |
| **Due — total DC output, all I/O** | **130 mA** | table 45-1, 144-lead LQFP |
| **Pi — I/O voltage tolerance** | **3.3 V only**, not 5 V tolerant | Raspberry Pi GPIO documentation |
| Pi — `VIL` max / `VIH` min | 0.9 V / 1.6 V | same, GPIO voltage specification table |
| Pi — `IOL` / `IOH` per pin | 18 mA / 17 mA at maximum (16 mA) drive | same, footnote c |
| Pi — default drive strength | 8 mA | same, footnote b |
| Pi — internal pull-up / pull-down | 50–65 kΩ | same, `RPU` / `RPD` |
| **Load rail** | 5.0 V, **1.0 A design ceiling** | PS3, this design |
| Load current, as fitted | 9.1 mA | `D2` via `R14`, sheet 3 |
| MOSFET `VDS` / `ID` | 30 V / 62 A at `VGS = 10 V` | IRLB8721PbF datasheet |
| MOSFET `VGS(th)` | 1.35 / 1.80 / 2.35 V (min/typ/max) | same, static characteristics |
| MOSFET `RDS(on)` | 16 mΩ max at `VGS = 4.5 V` | same |

Worst-case *actual* draw, for contrast — the system is nowhere near any of these:

| | Value | Against |
|---|---|---|
| Gate drive, transient | 3.3 mA | 22 % of `PA15`'s −15 mA ceiling |
| Wall-switch pull-up | 0.70 mA | only while `SW1` is closed |
| UART line, driven low | 0.32 mA | per line |
| Pi status LED | 1.4 mA | 17 % of the 8 mA default drive |
| Everything on the Due | < 5 mA | 4 % of the 130 mA device total |
| `D2`, the light | 9.1 mA | on PS3, through no pin at all |

One number is deliberately *not* asserted. The IRLB8721PbF's lowest guaranteed `RDS(on)` row is at
`VGS = 4.5 V`, and this gate network delivers 3.05 V. Rather than quote a number the datasheet does
not give, sheet 3 shows the margin: `VGS(th)` max is 2.35 V so the part is 0.7 V above threshold at
the worst corner, figure 3 reads roughly 10 A at `VGS = 3.0 V` — ten times the ceiling — and even at
a pessimistic ten times the 4.5 V figure a 1 A load dissipates 0.16 W in a part rated 65 W.

All of which is an argument about the ceiling, and at 9 mA none of it is stressed: a 62 A MOSFET
switching an LED is a placeholder holding a size open, not engineering. Q1 stays this part so that
substituting a real light is a one-component change. That is the whole reason, and it is better
stated than left for the numbers to imply.

## Bill of materials

| Ref | Value | Note |
|---|---|---|
| `Q1` | IRLB8721PbF | logic-level N-channel MOSFET, TO-220AB |
| `R1` | 1 kΩ | gate series |
| `R2` | 12 kΩ | gate pulldown — **do not omit or resize**; see sheet 3 |
| `R3`, `R5` | 4.7 kΩ | wall-switch and Pi-button pull-ups |
| `R4`, `R6` | 470 Ω | series; caps the capacitor discharge through the contacts at 7.0 mA |
| `R7` | 1 kΩ | Pi status LED series |
| `R8`–`R11` | 220 Ω | UART line series, one per pin |
| `R12`, `R13` | 10 kΩ | UART receiver idle pull-ups |
| `R14` | 330 Ω | `D2` series — numbered last because it was added after `R1`–`R13` |
| `C1` | 220 µF, 16 V | load rail bulk, electrolytic |
| `C2` | 100 nF | load rail high-frequency decoupling |
| `C3`, `C4` | 100 nF | wall-switch and Pi-button debounce |
| `D1` | LED, red | Pi boot / status indicator |
| `D2` | LED, red | the light — same 5 mm part as `D1` and as blinky's |
| `SW1` | SPST maintained | wall switch — an edge in *either* direction is one toggle |
| `SW2` | SPST momentary | Pi button — only its closing edge is an event |
| `PS3` | 5 V, ≥ 2 A regulated | dedicated load supply, rated for the ceiling rather than for `D2` |

All resistors 1/4 W or better. `R14` dissipates 27 mW; every other resistor is under 3 mW. `PS1` and
`PS2` are whatever the two boards already require — a 5 V/2.5 A supply for the Pi, and USB or 7–12 V
on `VIN` for the Due.

Substituting a real 5 V light for `D2` is a one-component change and needs nothing else resized. An
**inductive** load — a relay coil, a fan, a motor — additionally needs a flyback diode (cathode to
`+5V_LOAD`, anode to Q1's drain) fitted *before* power is applied; sheet 3 says why.

## What comes next

The firmware stories implement against these sheets and extend them only to annotate a decision the
diagrams left open:

| Story | Implements | Sheet |
|---|---|---|
| load switch | `smart-light/due/` — drive the gate, prove default-OFF across reset | 3 |
| wall switch | read `D26`, debounce, toggle the load | 4 |
| protocol | `smart-light/protocol/` — shared, allocation-free UART codec | 6 |
| state machine | compose the switch and remote commands behind a host/target seam | 3, 4, 6 |
| Pi boot | `smart-light/pi/` — bare-metal AArch64 boot and blink `D1` | 5 |
| Pi button | debounce `SW2`, emit one `TOGGLE` per press over the link | 5, 6 |

## Sources

Every value on these sheets traces to one of:

- SAM3X / SAM3A datasheet, [Atmel-11057C-ATARM](https://ww1.microchip.com/downloads/en/devicedoc/atmel-11057-32-bit-cortex-m3-microcontroller-sam3x-sam3a_datasheet.pdf)
  (2015-03-23) — §31.5 (PIO), §45.1 and §45.2 (electrical)
- [Arduino Due datasheet A000062](https://docs.arduino.cc/resources/datasheets/A000062-datasheet.pdf)
  — §5.1, §6.2.2, §6.2.4
- [`ArduinoCore-sam`, `variants/arduino_due_x/variant.cpp`](https://github.com/arduino/ArduinoCore-sam/blob/master/variants/arduino_due_x/variant.cpp)
- [BCM2835 ARM Peripherals](https://datasheets.raspberrypi.com/bcm2835/bcm2835-peripherals.pdf)
  (Broadcom, 2012) — §6.2
- [Raspberry Pi documentation, "GPIO and the 40-pin header"](https://www.raspberrypi.com/documentation/computers/raspberry-pi.html#gpio-and-the-40-pin-header)
- [IRLB8721PbF datasheet](https://cdn-shop.adafruit.com/datasheets/irlb8721pbf.pdf), International
  Rectifier, 2009-04-22

Where a datasheet does not guarantee what the design would like it to, the sheet says so and shows
the margin instead of asserting the number.
