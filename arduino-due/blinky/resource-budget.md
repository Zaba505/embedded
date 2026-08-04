# Resource Budget — arduino-due/blinky

Completed from the [repo-wide template](../../docs/resource-budget.md).

**Target & provenance.** Arduino Due — Atmel **SAM3X8E**, ARM **Cortex-M3**. The ceilings below come
from the linker script [`link.ld`](link.ld) (which was itself checked against the probe-rs target
registry, `dagger -m .../flash call chip-info --chip ATSAM3X8E`), the SysTick and clock constants in
[`src/main.zig`](src/main.zig), and the SAM3X datasheet for the electrical limits. The firmware is a
single externally-wired LED on `PD1` toggled at 1 Hz; every resource but flash sits so far under its
ceiling that the sketch's real value here is documenting *why* — see the [README](README.md).

## 1. Code footprint (flash / ROM)

| | Value | Source |
|---|---|---|
| Ceiling | **256 KB** (`0x00080000`–`0x000C0000`, flash bank 0) | [`link.ld`](link.ld) `rom` region; probe-rs registry |
| Budget | fit bank 0 **in `ReleaseSmall`** | [`build.zig`](build.zig) default optimize mode |
| Actual | **240 B** (`.text` = `0xF0`; `.data`/`.bss` empty) | `size` verb / [README](README.md) |
| Headroom | **~255.77 KB** (~99.9%) | ceiling − actual |

Build mode *is* the wall, not code size. The 256 KB region is bank 0 only — Arduino's own script
declares 512 KB, but bank 1 is not exposed as programmable NVM, and a blinky has no use for it. The
one fact that blows the ceiling is the **optimize mode**: a `Debug` build overflows `rom` by ~35 KB
once Zig links in its panic and formatting machinery, which is why `build.zig` defaults to
`ReleaseSmall` and the [README](README.md) warns never to pass a `Debug` `--optimize`. Enforcement is
the linker: a build that overflows `rom` fails to link rather than producing a too-big image.

## 2. Working memory (RAM)

| | Value | Source |
|---|---|---|
| Ceiling | **64 KB** SRAM0 (`0x20000000`–`0x20010000`) | [`link.ld`](link.ld) `ram` region |
| Budget | static ≈ 0; stack the only consumer | design intent |
| Actual | `.data` **0 B** + `.bss` **0 B** + heap **none** + peak stack **≪ 1 KB** | [README](README.md); [`link.ld`](link.ld) |
| Headroom | **~64 KB** (essentially the whole bank) | ceiling − actual |

There is nothing static to budget: `.data` and `.bss` are both empty, and there is **no heap** —
freestanding Zig links no allocator and `single_threaded = true` strips the threading machinery
([`build.zig`](build.zig)). So the entire 64 KB is available to the **stack**, which is the only RAM
consumer and the only risk. The Cortex-M3 has no MMU and no guard page, so a runaway stack would
corrupt `.data`/`.bss` silently — but the call graph is a bounded, non-recursive chain
(`resetHandler` → `main` → `waitHalfPeriod`, all tiny leaf-ish frames), so peak depth is a few dozen
bytes against a 64 KB region. `_estack` is pinned to the top of `ram` in [`link.ld`](link.ld). The
**heap: none** line matters for the future: the moment a project here reaches for an allocator (a
`steth-*` audio buffer, say) this row goes live and needs a real static budget.

## 3. Timing

| | Value | Source |
|---|---|---|
| Core clock | **4 MHz** internal fast RC (`MCK`, reset default — no PLL), accuracy ~few % | [`src/main.zig`](src/main.zig) `MCK_HZ` |
| Hard deadline(s) | **none** — 1 Hz blink is a soft target; RC-grade accuracy is "fine for a blink, not a time reference" | [`src/main.zig`](src/main.zig) |
| Counter-width ceiling | SysTick reload is **24-bit**, max **16,777,215** (`0xFF_FFFF`) | ARMv7-M SysTick; [`src/main.zig`](src/main.zig) |
| Actual / margin | reload = `HALF_PERIOD_TICKS − 1` = **1,999,999** — fits, ~8.4× under the ceiling | [`src/main.zig`](src/main.zig) |

This is the budget's cleanest win, and it is enforced at **compile time**. 500 ms at 4 MHz is
2,000,000 ticks, so the reload is 1,999,999 — comfortably inside the 24-bit register. That the clock
runs at the 4 MHz RC default rather than Arduino's 84 MHz PLL is *because of this ceiling*: at 84 MHz
the half-period would be 41,999,999 ticks, which overflows 24 bits and would force a software divider.
The budget is guarded by a `comptime` assertion that costs zero flash and zero cycles and fails the
build on the developer's machine:

```zig
comptime {
    if (HALF_PERIOD_TICKS - 1 > 0xFF_FFFF) {
        @compileError("SysTick reload exceeds 24 bits; halve the clock or divide in software");
    }
}
```

**New with the feedback path, and comfortably ignorable.** Sampling the sense input has to wait for
`Q1` to settle after `PD1` changes. The dominant term is the sense node's RC — `R3` at 10 kΩ against
a breadboard node of a few tens of pF, so a few hundred nanoseconds — with the 2N3904's own switching
times of the same order. Against a 500 ms half period that is six orders of magnitude of margin, so
it earns no counter and no row of its own; the firmware story has only to avoid sampling in the same
breath as the store.

## 4. Electrical / I/O limits

Three pins now, not one: the LED on `PD1`, the current-sense input on `PA15`, and the fault lamp on
`PB26`. Every figure below is derived on the [schematic](hardware/due-blinky.kicad_sch) and cited
there against the SAM3X datasheet (Atmel-11057C).

**The two LED pins are the reverse of this table's first version.** The board was built with `D1` on
`D26` and `D2` on `D22`, and the schematic now matches the bench. Every row below is restated against
the as-built assignment — which matters here more than anywhere else in the project, because `PB26`
and `PD1` sit in *different* datasheet current groups, so the swap moved a ceiling rather than just
a label.

| | Value | Source |
|---|---|---|
| I/O voltage tolerance | **3.3 V** — **not 5 V-tolerant**; 5 V damages the board | SAM3X datasheet; [README](README.md) |
| Per-pin source ceiling, `PD1` (`D1`) / `PA15` | **`IOH = −15 mA`** — both are **Group 1** (`PA[14–15]`, `PD[0–30]`) | table 45-2, note 2 |
| Per-pin source ceiling, `PB26` (`D2`) | **`IOH = −3 mA`** at `VOH = VDDIO − 0.4 V` — **Group 2** (`PB[25–31]`), *not* the −15 mA Group 1 | table 45-2, note 3 |
| Logic thresholds at the sense input | `VIL` max **0.99 V**, `VIH` min **2.31 V** (`0.3`/`0.7 × VDDIO`); `Vhys` 150–500 mV | table 45-2 |
| Budget | `D1` **≤ 2 mA** via 560 Ω; `D2` **≤ 2 mA** via 1 kΩ; sense network off the `+3V3` rail | schematic |
| Actual — `PD1` (`D1`) | **1.16 mA** nominal, **1.88 mA** worst case → **13 %** of ceiling, 13.1 mA headroom | schematic |
| Actual — `PB26` (`D2`) | **1.10 mA** nominal, **1.40 mA** worst case → **47 %** of ceiling, 1.60 mA headroom | schematic |
| Actual — `PA15` (sense) | an input; ≤ **18 nA** leakage, ≤ **66 µA** sourced by its internal pull-up | table 45-2, §31.5.1 |
| Off-pin draw | `R3` pulls **0.31 mA** from the `+3V3` **rail** while `D1` is lit — not a pin budget | schematic |
| Total device current | **3.66 mA** with both LEDs lit — still trivial | schematic |

The per-pin ceiling is the subtle one, and the swap is what makes it worth restating. `PB26`'s
datasheet **group** caps it at −3 mA, a fifth of the −15 mA that the Group-1 pins allow (and well
under the flat 8 mA Arduino's own datasheet quotes), so whatever hangs off `PB26` must be sized
against −3 mA and not the number most Due pinouts give. As built that is `D2`, the fault lamp, at
47 % of its ceiling. The load — the branch that actually carries current, and the one that used to
be against that wall at 63 % — now sits on `PD1`'s −15 mA at 13 %.

**That was survivable only because `R4` was sized to the −3 mA rule regardless of the pin it landed
on.** The schematic said so explicitly when `D2` was still drawn on a Group-1 pin: "no jumper on this
sheet can put a pin out of spec wherever it ends up." The jumper then ended up somewhere else, and it
did not. The same guarantee now runs the other way: keep `R4` **≥ 470 Ω** — (3.30 − 1.90)/0.003 is
where `D2` would reach `PB26`'s −3 mA.

**`R1` is 560 Ω, and after the swap that is a choice rather than a limit.** `Q1`'s base-emitter
junction takes ~0.7 V out of the same 3.3 V that `D1` and its limit resistor share, so the original
1 kΩ would have left `D1` at ~0.65 mA; 560 Ω restores 1.16 mA nominal, about 17 % dimmer than the
pre-feedback circuit. What has changed is *why* 560 Ω: on `PB26` it was the value that held the worst
case under two thirds of a −3 mA ceiling, and **330 Ω (3.18 mA) and 220 Ω (4.77 mA) were both
illegal there.** On `PD1` none of them comes near −15 mA — even 220 Ω is 32 % of it — so the per-pin
ceiling no longer constrains `R1` at all. It is retained at 560 Ω because it is what is built, it is
adequate, and every saturation and sense figure on the sheet is derived at it. 470 Ω remains legal
and is now merely brighter rather than the practical floor.

Voltage is a hard fact rather than a budget, and there are now **two** places to get it wrong: the
header pin next to `D22` is +5 V, and on the 24-pin power header `+3V3` sits directly beside `+5V`.
A one-position slip at either feeds 5 V into a 3.3 V pin, which the README flags in bold.

The **logic thresholds are new to this table** because the design now has an input to satisfy, and
they are the constraint that shaped the circuit: `VIL`…`VIH` leaves a forbidden band of
0.99–2.31 V, and a passive tap on the LED could only ever reach `VOH − Vf ≤ 1.70 V` — inside it. The
drawn topology clears the band by 0.79 V low and 0.99 V high.

## 5. Project-specific resources

**One, new with the feedback path: diagnostic channels.** The other three candidates remain
deliberate absences.

### 5.1 Diagnostic channels

| | Value | Source |
|---|---|---|
| Ceiling | **2** channels readable without instrumentation — `D1` and `D2` — plus SWD, which needs a probe | [schematic](hardware/due-blinky.kicad_sch) |
| Budget | at least **one** channel that survives a *load* fault, i.e. shares no component with `D1`'s branch | second-indicator decision, on the schematic |
| Actual | `D1` (1 Hz blink, or its absence) and `D2` (solid, fault only) — `D2`'s path is disjoint from `D1`/`R1`/`R2`/`R3`/`Q1` | schematic |
| Headroom | **none spare** — a third channel would cost another pin, another jumper and another part | — |

This row exists because the feedback path created a failure mode the old design could not have had:
the board can now *detect* that its load did not light, and `D1` was the only way it had to say so —
the report would have travelled through the failed part. Bounding the channels, and requiring that
one of them share nothing with the load, is the same "bound every resource at design time" discipline
the four rows above apply, pointed at observability instead of at flash or current. The regress stops
at two because `D2` may only ever assert **fault**: every way it can fail lands on dark, which is
also the no-fault state, so a broken watcher costs an alarm and can never manufacture one.

### 5.2 Still none

- **Energy / battery:** none. The board is USB-powered; there is no sleep state, duty-cycle, or
  battery life to budget (a `WFI`-based low-power design *would* add an energy row). The sense
  network's 0.31 mA of rail draw is an electrical figure (§4), not an energy budget.
- **I/O bandwidth:** none. The firmware masters no bus — no I²C/SPI/UART, no sensor sample rate. Its
  entire I/O surface is a handful of register writes and, once the sense input is read, one more
  level poll.
- **Interrupt latency:** none. The design is **poll-driven, not interrupt-driven** — SysTick is read
  via `COUNTFLAG` in the main loop, and the one wired interrupt vector (SysTick) points at the fault
  trap precisely so a spurious interrupt *stops* the board rather than being serviced. There is no ISR
  whose latency needs budgeting, and the sense input is a level to sample rather than an edge to catch.

That this list is *almost* empty is the same measurement the [research study](../../docs/research/tigerbeetle-for-embedded.md)
makes from the other direction: the blinky has almost no I/O surface, which is why heavier machinery
(a fault-injection harness, a simulator) is still not worth building here. What the feedback path
adds is the cheapest possible instance of that machinery in hardware instead — pulling `D1` out of
the breadboard is fault injection with no code at all, and it is now a fault the board can notice.
