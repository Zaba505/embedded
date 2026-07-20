# Resource Budget

*The back-of-the-envelope resource sketch, re-aimed at the resources that actually bind firmware — a
template each project fills in.*

[Tiger Style][tiger-style] asks you to size the design before you build it:

> **Perform back-of-the-envelope sketches with respect to the four resources (network, disk, memory,
> CPU) and their two main characteristics (bandwidth, latency).** Sketches are cheap. Use sketches to
> be "roughly right" and land within 90% of the global maximum. — §Performance

It does this because **"the best time to solve performance, to get the huge 1000x wins, is in the
design phase, which is precisely when we can't measure or profile."** (§Performance) The whole point
is to *bound every resource on paper before writing code*, when a bad number is free to fix.

That discipline transfers to firmware wholesale. What does **not** transfer is the resource list.
Tiger Style's four are a server's — network, disk, memory, CPU — and it optimizes "for the slowest
resources first … in that order." Firmware's binding resources are different in kind and in scale:
the image lives in a fixed, un-pageable **flash** measured in kilobytes; working **memory** is a
fixed SRAM with no swap and, usually, no allocator; time is a **fixed clock and hard deadlines**
rather than a "make it faster" gradient; and there is a resource a server has no analog for at all —
the **electrical / I/O limits** where the physical world pushes back on a pin. These vary widely
across targets, so no repo-wide number is possible. Each project sketches its own, *up front*, using
the template below — turning "bound every resource at design time" from folklore into a filled-in
checklist.

This document presumes no board, no architecture, and no toolchain. The reference instance
([`arduino-due/blinky`](../arduino-due/blinky/resource-budget.md)) is one worked example of the
shape, never the definition.

[tiger-style]: https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md

## The resources that bind firmware

The server four map onto firmware unevenly — some tighten, some change character, one has no server
counterpart. Naming the mapping is what keeps this a *re-derivation* of Tiger Style's sketch rather
than a fresh invention.

| Tiger Style resource | Firmware category | What changes |
|---|---|---|
| Memory | **Working memory (RAM)** | Kilobytes, not gigabytes. No swap, usually no heap: every byte is allocated statically at init, and the *stack* is the dangerous part — on an MMU-less core it has no guard page and overflows silently into your data. |
| Disk | **Code footprint (flash / ROM)** | This is where the *program* lives, and it is tiny and fixed. You cannot page or stream it; the image either fits the region or the linker refuses to produce it. Build mode alone can blow it (debug builds drag in machinery release builds strip). |
| CPU | **Timing** | Not a "faster is better" gradient but a **fixed clock**, plus **hard deadlines** and **counter/register widths** that impose exact ceilings (a 24-bit timer reload cannot hold a 25-bit value). Many of these are compile-time-knowable and checkable for free. |
| Network | *(project-specific)* **I/O bandwidth** | Only if the project speaks a bus — a sensor's sample rate, an SPI/I²C throughput, a radio's airtime. Absent for a device that talks to no one. |
| — | **Electrical / I/O limits** | *No server analog.* Per-pin source/sink current, pin-group limits, I/O voltage tolerance, total device current, energy from a battery. Exceed these and you do not get a slow program — you get a damaged one. |

Tiger Style optimizes the slowest server resource first. The firmware equivalent — *budget the
scarcest resource first* — is **per-project**: on one target flash is the wall, on another it is RAM,
on a battery device it is energy, on a motor controller it is a deadline. The budget's job is to make
your target's scarcest resource visible on paper, so you meet it by design and not by surprise.

## Ceiling, budget, headroom

Each resource gets three numbers, and the order you fill them in is the discipline:

- **Ceiling** — the hard limit the silicon or spec imposes (256 KB of flash, −3 mA on a pin, a 24-bit
  reload). A hardware fact, non-negotiable, and it must cite its source: a datasheet table, the linker
  script, the target registry, a measurement. *A budget built on a guessed ceiling is folklore.*
- **Budget** — what the project **commits at design time** to staying within. This is the
  back-of-the-envelope act itself, done before the code exists. It is a choice, and a smaller-than-the
  -ceiling budget is often the right one (leave headroom for the feature you have not written yet).
- **Actual** — the measured or computed number once the thing is built. **Headroom** is the margin
  between actual and ceiling (or budget). A negative headroom is a design error the budget existed to
  catch early.

Fill **ceiling and budget before writing code**; fill **actual** after. The value of the sketch is
that the first two land during design, when Tiger Style says the 1000x wins are — and when a wrong
number costs nothing.

## The template

Copy this into `<project>/resource-budget.md` and fill every field. Delete none: "N/A, because …" is
an answer; a blank is not. The back-link assumes the project sits two directories below the repo root
(like `arduino-due/blinky`); adjust the `../` prefix to your project's depth.

```markdown
# Resource Budget — <project>

Completed from the [repo-wide template](../../docs/resource-budget.md).

**Target & provenance.** The board / MCU / core, and where each *ceiling* below is taken from —
datasheet table, linker script, the probe-rs target registry, a scope measurement. Cite it: a ceiling
with no source is a guess.

## 1. Code footprint (flash / ROM)

| | Value | Source |
|---|---|---|
| Ceiling | e.g. programmable flash region size | linker script / registry |
| Budget | what you commit to at design time | |
| Actual | measured image size | `size` verb / map file |
| Headroom | ceiling − actual | |

Build mode the actual assumes (size-optimized vs. debug — they can differ by tens of KB), and the one
fact most likely to blow the ceiling.

## 2. Working memory (RAM)

| | Value | Source |
|---|---|---|
| Ceiling | total usable SRAM | linker script |
| Budget | committed static + stack ceiling | |
| Actual | `.data` + `.bss` + peak stack + heap | map file / analysis |
| Headroom | ceiling − actual | |

Break the actual into its parts. State **heap: none** if static-only — and note it, because a later
allocator turns this row live. The stack has **no guard page** on an MMU-less core: say what stops it
growing into `.data`/`.bss` (bounded call depth, no recursion — Tiger Style bans it for exactly this).

## 3. Timing

| | Value | Source |
|---|---|---|
| Core clock (and accuracy) | | |
| Hard deadline(s) | the ones missing them breaks correctness | |
| Counter / register-width ceilings | e.g. a timer reload's bit width | datasheet |
| Actual / margin | reload values, cycle counts vs. the above | |

Every width ceiling here is a candidate for a **compile-time assertion** — check the reload against
the counter width and the budget is enforced for free, before the program runs (see below).

## 4. Electrical / I/O limits

| | Value | Source |
|---|---|---|
| I/O voltage tolerance | and what over-voltage does | datasheet |
| Per-pin current (source / sink) | the actual limit for *these* pins, not the headline one | datasheet table |
| Pin-group / bank limit | if the datasheet groups pins with different limits | |
| Total device current | sum across active outputs | |

State the component choices that keep each within its ceiling (a series resistor sizing an LED's
current, a gate driver's limit). Over-voltage or over-current is not a slow program — it is a dead one.

## 5. Project-specific resources

Anything else that binds *this* project and none of the above captured: **energy / battery life**, a
**bus's bandwidth or sample rate**, **interrupt latency**, connector / pin **count**, thermal budget.
"None beyond the four categories above" is an answer to write, not to omit.
```

Five sections; fill them tersely. Sections 1–4 are the categories the acceptance criteria name;
section 5 is the room every real target eventually needs.

## How it feeds the code

A budget that only lives in prose rots. On this repo's flow each row has a mechanism that *enforces*
it, so a blown budget fails a build rather than surprising a person:

- **Flash and RAM ceilings live in the linker's `MEMORY` regions.** Exceeding one is a **link error**,
  not a lint — this is exactly how the reference project's debug build is caught overflowing flash by
  ~35 KB. Set the regions to the true ceilings (§1–2) and the linker enforces them for every build.
- **Code footprint is measured by the `size` verb** of the pinned `zig` Dagger module, and a
  **size-delta gate** turns a footprint regression into a failed check (the `lib/assert` benchmark is
  the worked example: it fails CI if per-assertion cost exceeds a threshold).
- **Timing width-ceilings become `comptime` assertions.** A reload checked against its counter width
  at compile time costs zero flash and zero cycles and fails on the developer's machine — the safest
  place a correctness bug can surface. This is the cheapest, highest-value rung of the whole staircase.
- **Electrical limits become component and configuration choices** — a series resistor sized to a
  pin's current ceiling, a pin picked from the right datasheet group — and belong in the project's
  hardware notes / schematic, checked by hand against §4.
- **CI's image checker asserts the artifact lands in the budgeted regions** (initial stack pointer at
  the top of the RAM region, reset vector inside the flash region) — a negative-space check that the
  built image respects §1–2.

## Filled-in instances

| Project | Scarcest resource | One-line why |
|---|---|---|
| [`arduino-due/blinky`](../arduino-due/blinky/resource-budget.md) | **flash** | ~244 B image in a 256 KB region, yet a *debug* build overflows it by ~35 KB — so build mode, not code, is the wall. Every other resource sits three-plus orders of magnitude under its ceiling. |
