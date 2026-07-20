# Resource Budget — arduino-due/blinky

Completed from the [repo-wide template](../../docs/resource-budget.md).

**Target & provenance.** Arduino Due — Atmel **SAM3X8E**, ARM **Cortex-M3**. The ceilings below come
from the linker script [`link.ld`](link.ld) (which was itself checked against the probe-rs target
registry, `dagger -m .../flash call chip-info --chip ATSAM3X8E`), the SysTick and clock constants in
[`src/main.zig`](src/main.zig), and the SAM3X datasheet for the electrical limits. The firmware is a
single externally-wired LED on `PB26` toggled at 1 Hz; every resource but flash sits so far under its
ceiling that the sketch's real value here is documenting *why* — see the [README](README.md).

## 1. Code footprint (flash / ROM)

| | Value | Source |
|---|---|---|
| Ceiling | **256 KB** (`0x00080000`–`0x000C0000`, flash bank 0) | [`link.ld`](link.ld) `rom` region; probe-rs registry |
| Budget | fit bank 0 **in `ReleaseSmall`** | [`build.zig`](build.zig) default optimize mode |
| Actual | **~244 B** (`.text`; `.data`/`.bss` empty) | `size` verb / [README](README.md) |
| Headroom | **~255.75 KB** (~99.9%) | ceiling − actual |

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

## 4. Electrical / I/O limits

| | Value | Source |
|---|---|---|
| I/O voltage tolerance | **3.3 V** — **not 5 V-tolerant**; 5 V damages the board | SAM3X datasheet; [README](README.md) |
| Per-pin source current (ceiling) | **`IOH = −3 mA`** at `VOH = VDDIO − 0.4 V` — `PB26` is in **Group 2** (`PB[25–31]`), *not* the −15 mA Group 1 | datasheet table 45-2, notes 2 & 3 |
| Budget | **~1–2 mA** via a 1 kΩ series resistor (red LED) | [README](README.md) wiring |
| Actual / headroom | **~1 mA**; ~2 mA headroom to the −3 mA ceiling | [README](README.md) |
| Total device current | one LED at ~1 mA — trivial | — |

The per-pin ceiling is the subtle one: `PB26`'s datasheet **group** caps it at −3 mA, a fifth of the
−15 mA that the headline Group-1 pins allow, so the resistor must be sized against −3 mA and not the
number most Due pinouts quote. The 1 kΩ resistor sets ~1 mA, well inside that. The [README](README.md)
records the trap this rules out: **do not substitute 220 Ω** (~4 mA, over the −3 mA ceiling); 470 Ω
(~2 mA) is the practical floor. Voltage is a hard fact, not a budget — the header pin next to `D22`
is +5 V, so a one-position wiring slip feeds 5 V into a 3.3 V pin, which the README flags in bold.

## 5. Project-specific resources

**None beyond the four categories above** — and each absence is a deliberate design fact, not an
omission:

- **Energy / battery:** none. The board is USB-powered; there is no sleep state, duty-cycle, or
  battery life to budget (a `WFI`-based low-power design *would* add an energy row).
- **I/O bandwidth:** none. The firmware masters no bus — no I²C/SPI/UART, no sensor sample rate. Its
  entire I/O surface is four register writes and one status-flag poll.
- **Interrupt latency:** none. The design is **poll-driven, not interrupt-driven** — SysTick is read
  via `COUNTFLAG` in the main loop, and the one wired interrupt vector (SysTick) points at the fault
  trap precisely so a spurious interrupt *stops* the board rather than being serviced. There is no ISR
  whose latency needs budgeting.

That this list is empty is the same measurement the [research study](../../docs/research/tigerbeetle-for-embedded.md)
makes from the other direction: the blinky has almost no I/O surface, which is exactly why heavier
machinery (fault injection, a simulator) is not yet worth building here.
