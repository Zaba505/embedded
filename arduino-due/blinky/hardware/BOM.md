# Bill of materials — `due-blinky`

Everything needed to build [`due-blinky.kicad_sch`](due-blinky.kicad_sch) **except the Arduino Due
board itself**, which is assumed on hand.

The schematic is the source of truth. Reference designators, values and the reasoning behind them
live there; this file only says where to buy the parts and what to check when they arrive.

Links are to distributors that stock the exact part. Prices are what the pages listed when this file
was written — treat them as indicative, not as a quote.

## Required — the circuit itself

| Ref | Value | Qty | Buy | Notes |
| --- | --- | --- | --- | --- |
| R1 | 560 Ω, 1/4 W, ±5% | 1 | [DigiKey CF14JT560R](https://www.digikey.com/en/products/detail/stackpole-electronics-inc/CF14JT560R/1830344) (Stackpole) | D1's limit resistor, on `PD1` / D26. 560 Ω is what the sheet is derived at; see the substitution note below if you are ordering from Adafruit only. |
| R2 | 10 kΩ, 1/4 W, ±5% | 1 | [DigiKey CF14JT10K0](https://www.digikey.com/en/products/detail/stackpole-electronics-inc/CF14JT10K0/1741265) · or [Adafruit 2784](https://www.adafruit.com/product/2784) (25-pack) | Q1 base bleed. |
| R3 | 10 kΩ, 1/4 W, ±5% | 1 | same as R2 | Collector pull-up to +3V3. One 25-pack covers both R2 and R3. |
| R4 | 1 kΩ, 1/4 W, ±5% | 1 | [DigiKey CF14JT1K00](https://www.digikey.com/en/products/detail/stackpole-electronics-inc/CF14JT1K00/1741314) · or [Adafruit 4294](https://www.adafruit.com/product/4294) (25-pack) | D2's limit resistor, on `PB26` / D22. **Do not go below 470 Ω** — PB26 is Group 2 and its ceiling is −3 mA. This is the only resistor on the sheet with a hard lower bound. |
| D1 | Red LED, 5 mm, diffused | 1 | [Adafruit 299 — Diffused Red 5 mm, 25-pack, $4.00](https://www.adafruit.com/product/299) | The blink indicator. Spec'd Vf 1.85–2.5 V @ 20 mA, which lands in the schematic's assumed 1.60–1.85 V band at the ~1 mA this circuit runs. **Do not** buy a "super bright" red — see the Vf check below. |
| D2 | Green LED, 5 mm, diffused | 1 | [Adafruit 298 — Diffused Green 5 mm, 25-pack, $4.00](https://www.adafruit.com/product/298) | The fault lamp. Spec'd Vf 2.2–2.5 V @ 20 mA. Must be a **different colour from D1** and must be a standard green, not a high-Vf InGaN "super bright" green — see below. |
| Q1 | 2N3904 NPN, TO-92 | 1 | [DigiKey 2N3904BU (onsemi), $0.28](https://www.digikey.com/en/products/detail/onsemi/2N3904BU/1413) | The conduction sense element. TO-92, **E-B-C left to right with the flat face toward you**. The schematic's saturation numbers are taken from the onsemi 2N3903/2N3904 datasheet, so buying the onsemi part means the numbers on the sheet are the numbers for your part. |

## Required — to actually build it on the bench

| Item | Qty | Buy | Notes |
| --- | --- | --- | --- |
| Solderless breadboard, half-size | 1 | [Adafruit 64 — 400 tie points, $4.95](https://www.adafruit.com/product/64) | Both power rails get used: the ground rail for the GND return, and a second rail is handy for +3V3. |
| Male–male jumper wires, 0.1″ | 5 min. | [Adafruit 758 — 40 × 6″ (150 mm)](https://www.adafruit.com/product/758) | Five jumpers leave the board: D22, D24, D26 (contiguous run on the even-numbered header row) plus +3V3 and GND. Ribbon strips help here — the D22/D24/D26 run can stay as one 3-wide ribbon so it cannot be miscounted independently. **Watch the order at the far end:** D22 is the *fault lamp* and D26 is the *blink LED*, not the other way round. |
| USB Micro-B cable | 1 | — | For the Due's **programming** port (bossac / 1200-baud touch). Probably already on hand; the Due does not ship with one. |

## Optional — the SWD path

Not needed to build or flash this project. `bossac` over the programming USB port does the job with
no probe and no extra wiring; the sheet draws SWD because it is the only route to breakpoints,
memory inspection and GDB. The repo README notes a probe is not currently on hand.

| Ref | Item | Buy | Notes |
| --- | --- | --- | --- |
| J2 | SWD/JTAG debug probe, 3.3 V capable | [Adafruit 3571 — SEGGER J-Link EDU Mini](https://www.adafruit.com/product/3571) | Non-commercial licence. SEGGER lists the Due as a standard Cortex-M 10-pin target. Ships with a target interface cable; **confirm the current bundle includes a 1.27 mm 10-pin lead** before also buying the cable below. |
| — | 10-pin 2×5 1.27 mm IDC cable | [Adafruit 1675 — 150 mm, $2.95](https://www.adafruit.com/product/1675) · [Adafruit 5804 — 300 mm](https://www.adafruit.com/product/5804) | Only if the probe does not include one. |
| — | Budget alternative: CMSIS-DAP / DAPLink probe | [Amazon B0BRW634QV](https://www.amazon.com/CMSIS-DAP-DAPLink-Cortex-M-Program-OpenOCD/dp/B0BRW634QV) | probe-rs speaks CMSIS-DAP. **Confirm the target connector is 1.27 mm pitch, not 2.54 mm**, and that it can be set to 3.3 V — these listings vary. |

**J1 is not a purchase.** It is the 2×5 1.27 mm JTAG/SWD header already fitted to the Arduino Due.

## Tools

A multimeter with continuity mode. The wiring notes on the sheet call for confirming position 1 of
the D22 row *is* +5 V, and confirming GND by continuity, before applying power. Not optional given
that 5 V sits directly beside both D22 and +3V3.

## Substitutions the schematic already sanctions

- **R1 → 470 Ω** if you want a brighter D1 or are ordering from a supplier without 560 Ω.
  Adafruit stocks [470 Ω (2781)](https://www.adafruit.com/product/2781) but no 560 Ω, so an
  Adafruit-only order lands here. 470 Ω gives 1.38 mA nominal, 2.23 mA worst case — **15 % of
  `PD1`'s −15 mA Group-1 ceiling**, so it is comfortably legal and simply brighter. 560 Ω is drawn
  because the sheet's corner table and every sense figure below it are derived at that value.
  Note this substitution used to be the *practical floor*, back when D1 sat on `PB26`'s −3 mA; the
  swap that moved D1 to `PD1` also removed the ceiling as a constraint on R1. **The lower bound did
  not vanish — it moved to R4**, above.
- **Q1 → BC547 or 2N2222.** Both work electrically. A **BC547 in TO-92 is C-B-E — reversed** from
  the 2N3904's E-B-C. Fitting one in the 2N3904's orientation gets you a reverse-biased
  base-emitter junction and no sense signal.
- **D2 → any colour except D1's.** The sheet only requires that the two are never read for each
  other.

## Check on arrival, before trusting the sense circuit

The one part assumption on the sheet that is *not* backed by a datasheet of record is LED forward
voltage. Both LED branches are derived from an assumed Vf, and D1's has thin margin at its
worst-case corner.

1. **Measure D1's Vf at ~1 mA** (LED in series with the 560 Ω off 3.3 V; measure across the LED).
   Expect roughly 1.6–1.9 V. If it reads much above 1.9 V, D1 still lights but Q1's base drive
   shrinks fast — at the min-current corner the design has only ~0.27 mA of base current to give
   away. Drop R1 to 470 Ω and re-measure.
2. **Confirm D2 is not a high-Vf green.** A modern InGaN "super bright" green runs Vf ≈ 3.0–3.4 V,
   which exceeds the 2.90 V worst-case VOH — the fault lamp would simply never light, and it would
   never light in exactly the situation you need it to. The linked diffused green (2.2–2.5 V
   @ 20 mA) is fine.
3. **Confirm Q1's pinout against the package you were shipped**, not against the sheet. TO-92
   pinouts differ by part number and occasionally by vendor.
