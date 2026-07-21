# Debug port & firmware dumpability — the headline question

**Story:** [#5 `story(steth-teardown)`](https://github.com/Zaba505/embedded/issues/5). This is the
single most valuable output of the teardown, because both downstream stories depend on it: the
[firmware story #7](https://github.com/Zaba505/embedded/issues/7) cannot start without a working
programming path, and this is also the only way to answer whether the **original firmware can be read
back off the device.**

> **Marker key** (same as [`teardown.md`](teardown.md#0-what-this-document-is-and-how-to-read-the-markers)):
> ✅ **paper** = established from spec/datasheet, no bench needed · 🔬 **bench** = a measurement only the
> owner can take with the physical unit · ✅ **bench-done** = a 🔬 filled in.

> **Honest status.** Everything a datasheet can settle is settled below: the exact MCU balls the debug
> signals *must* land on, the protocol, the logic level, the protection register to read, and the
> fallback route. **Nothing electrical has been measured yet** — no pad buzzed, no probe attached, no
> `FSEC` read. Those are the 🔬 rows, and they are the reason the story stays open.

---

## The gate, in one paragraph

Firmware was flashed onto the MCU at the factory (the owner's archive even contains a **PEmicro Cyclone
production image**), so a programming path physically exists. The MCU's application firmware lives in
the **MK26's internal 2 MB flash**. Whether it can be dumped hinges entirely on **Kinetis flash
security (`FSEC` / the MDM-AP secured bit)**. If secured, SWD reads are blocked and the *only* way to
re-open the port is a **mass-erase** — which **destroys the firmware**. So "unlock the port" and "keep
the original image" become mutually exclusive. That is why we **read the external SPI-NOR flash first**
([§7](#7-fallback-if-the-mcu-is-locked--external-spi-flash)) and treat the MCU image as recoverable
primarily via the app/OTA route.

---

## 1. Where is it, and what is it?

✅ **paper (hypothesis).** **SWD/JTAG on the main (MCU) board, near U1** (the MK26). Evidence: the
design spec's *"Processor JTAG Notes"* describe recovering a bricked unit with a **Segger J-Link** and
the `Unlock Kinetis` command and reference `FSEC` at `0x0000_040C`; a **"Debug" block** is drawn on the
CPU in the block diagram; and the factory Cyclone image programs Kinetis over SWD/JTAG.

🔬 **bench.** The **physical location, footprint type, and pad pitch are unknown** — nailing them down
is the core of this story. Candidate footprints, roughly by how common they are in a product this size:

- **Bare test pads**, a row of 4–6, often gold, sometimes silkscreened `SWD`/`SWC`/`SWO`/`RST`/`TP*`.
- **Tag-Connect** — TC2030 (6 pads) or TC2050 (10 pads, 2 rows), each with 3 alignment holes. Very
  common in space-constrained consumer hardware — no connector needed.
- **Unpopulated header footprint**, 1.27 mm or 2.54 mm, 1×4 through 2×5.
- **2×5 1.27 mm shrouded header** — the ARM Cortex Debug standard, if they paid for the connector.
- **Castellated edge pads / pogo-pin target rings.**
- **Debug lines sharing an existing populated connector** (battery flex, FFC, JST-SH) — easy to miss.

> **U1 is a 169-MAPBGA — there are no pins to probe.** Trace each candidate pad to the nearest via,
> test point, or decoupling-cap pad on the **same net** instead. This is slower, and it is exactly the
> case where the high-resolution both-sides photographs ([`photos/`](../photos/)) pay for themselves.

---

## 2. Proof by continuity — the datasheet-cited target balls

Guessing from pad geometry is **not** identification. The proof is continuity from a candidate
pad to a **named, datasheet-cited MCU ball.** On any Cortex-M part the SWD/JTAG functions are
**fixed-function out of reset** — they are silicon, not a firmware choice — so their ball
locations are known before we touch the board.

✅ **paper.** From the **NXP K26 Sub-Family Data Sheet `K26P169M180SF5` (Rev. 4, 04/2017)**,
"Signal Multiplexing and Pin Assignments", the **169-MAPBGA (`MI`)** package — which is the exact
package on the bench unit (`MK26FN2M0V`**`MI`**`18`):

| Debug function | Port / default | 169-MAPBGA ball | Also (144-LQFP pin) | Candidate pad → | Continuity ✓/✗ |
|---|---|:---:|:---:|---|:---:|
| **SWDIO / TMS** | PTA3 (JTAG_TMS/SWD_DIO) | **M8** | 53 | 🔬 | 🔬 |
| **SWCLK / TCK** | PTA0 (JTAG_TCLK/SWD_CLK) | **N8** | 50 | 🔬 | 🔬 |
| **SWO / TDO** | PTA2 (JTAG_TDO/TRACE_SWO) | **M9** | 52 | 🔬 | 🔬 |
| **TDI** (JTAG only) | PTA1 (JTAG_TDI) | **N9** | 51 | 🔬 | 🔬 |
| **NMI_b** | PTA4 (NMI_b/LLWU_P3) | **L9** | 54 | 🔬 | 🔬 |
| **nRESET** | RESET_b (dedicated) | **L13** | 74 | 🔬 | 🔬 |
| **VTref** (level ref) | VDD (digital 1.8 V) | (VDD balls) | — | 🔬 | 🔬 |
| **GND** | VSS | (VSS balls) | — | 🔬 | 🔬 |

> **Cross-check that pins these ball numbers are right.** The spec independently states the MCU's
> `CHARGE` signal is **PTA24 = ball K11**; the same datasheet table gives PTA24 → 169-MAPBGA **K11**.
> That agreement confirms we are reading the correct (169-MAPBGA) package column, so the SWD balls above
> are trustworthy as continuity targets.

**Procedure** (record the ball number used against each pad so the claim is re-checkable):

1. **Battery (BT1) disconnected**, multimeter in continuity/diode mode.
2. Locate the U1 BGA outline and its A1 corner (dot / chamfer / silkscreen bar) to orient the ball
   grid; you are buzzing to a **via/decap on the net**, not the ball itself.
3. Buzz every candidate pad against **M8, N8, M9, L13** (the four you actually need for SWD + reset).
   Fill the "Continuity" column above.
4. Buzz out **GND** (ties to the shield can and battery negative).
5. Find the supply/**VTref** pad by measuring a candidate against GND **with the device powered** — it
   should read the digital rail (**expect ~1.8 V**, see [§4](#4-then-prove-it-electrically)).
6. `nRESET` is usually pulled up to VDD — check for a resistor to the rail near RESET_b/L13.

Once continuity is known, fill the **pin-by-pin assignment** for whatever footprint was found:

| Debug pad (physical) | Assigned function | Proven to MCU ball | Notes |
|---|---|---|---|
| 🔬 pad 1 | 🔬 | 🔬 | |
| 🔬 pad 2 | 🔬 | 🔬 | |
| 🔬 … | 🔬 | 🔬 | |

---

## 3. Protocol & logic level

- **Protocol:** ✅ **SWD** (2-wire) is expected; the same pads also expose **JTAG** (TMS/TCK/TDO/TDI)
  because PTA0–PTA3 are the shared JTAG/SWD group. SWD is sufficient for probe-rs.
- **Logic level:** ✅ paper — the **digital core is 1.8 V** (design-spec rail table). 🔬 confirm by
  measuring the VTref pad against GND (step 5 above).

> ⚠️ **A 3.3 V probe on a 1.8 V part can damage it.** Use a probe with a **`VTref`** pin and let it take
> its level from the board. Do **not** assume 3.3 V — this part is 1.8 V, unlike the Arduino Due in
> this repo. This is the same class of trap the [`arduino-due/blinky`](../../arduino-due/blinky)
> schematic warns about, inverted: there the danger was 5 V into 3.3 V; here it is 3.3 V into 1.8 V.

---

## 4. Then prove it electrically (before trusting it)

Continuity says the traces go somewhere plausible. It does **not** say the port is alive.

1. 🔬 **Measure VTref/VDD first** ([§3](#3-protocol--logic-level)). Expect ~1.8 V.
2. 🔬 `probe-rs info` (or OpenOCD) **reads the DP IDCODE and enumerates APs without writing anything.**
   A responding DAP with a plausible IDCODE is the proof the port is live.
   - Expect a standard **ARM Cortex-M SW-DP IDCODE `0x2BA01477`** and a Kinetis **MDM-AP** alongside
     the AHB-AP. Record the actual values.
3. 🔬 **Cross-check** the part probe-rs reports against the **package marking** read in
   [`teardown.md` §4.1](teardown.md#41-compute--digital-core) (`MK26FN2M0VMI18`). If they disagree, one
   of the two is wrong and it matters which.

### If the DAP is silent — distinguish the three causes

A silent DAP has three very different causes with completely different next steps. Do **not** just
record "no response" — rule them out one at a time and record which:

| Cause | How to rule it in/out | If it's this |
|---|---|---|
| **A. Wrong pads** | Re-check continuity ([§2](#2-proof-by-continuity--the-datasheet-cited-target-balls)); try JTAG if SWD silent | Keep probing pads |
| **B. Readout protection** | See [§5](#5-then-answer-the-dump-question) — a secured Kinetis answers the DP but blocks memory, and the RESET line oscillates on a blank/locked part | Go to the dump-verdict + fallback |
| **C. Needs reset / external power** | Hold `nRESET` low during connect (the spec's recovery note: *"press the reset pin, hold it low, power-cycle, then run the debugger"*); ensure the board is externally powered | Connect-under-reset |

> The spec's own JTAG note describes cause **C/B** precisely: on a blank device the reset vector reads
> `0xFFFF_FFFF` (illegal), so *"the reset line oscillates as the chip runs then resets"* — the recovery
> is to hold reset low, run J-Link, and (if secured) issue `Unlock Kinetis`.

---

## 5. Then answer the dump question

This is the **gate for [#7](https://github.com/Zaba505/embedded/issues/7).** "Dumpable" and "not
dumpable" are **both successful outcomes** of this story. Only "we never checked" is a failure.

1. 🔬 **Attempt a small read** — e.g. `probe-rs read b32 0x0 4`. A fault, or an all-`0xFFFFFFFF` result
   where the reset vector should be, points at protection (or a blank part).
2. 🔬 **Read the Kinetis protection state the vendor-specific way:**
   - **`FSEC` is at flash address `0x0000_040C`** (the spec confirms this address). On a *blank/erased*
     device `FSEC = 0xFE`; on a *secured* device the `FSEC[SEC]` field (bits 1:0) is **not** `0b10`.
     `FSEC[SEC] == 0b10` ⇒ **unsecured** (dumpable); anything else ⇒ **secured**.
   - Equivalently, read the **MDM-AP** *System Security* status bit via SWD before halting — it mirrors
     the secured state and is readable even when the core is held in reset.
3. 🔬 **Record the verdict explicitly, either way:**

| Item | Verdict |
|---|---|
| `FSEC` @ 0x40C read as | 🔬 `0x__` |
| `FSEC[SEC]` field | 🔬 (`0b10` unsecured / other = secured) |
| MDM-AP secured bit | 🔬 |
| Small read at 0x0 returned | 🔬 |
| **→ Can the original MCU firmware be dumped over SWD?** | 🔬 **YES / NO** |

> ⚠️ **If secured, do NOT run `Unlock Kinetis` / mass-erase to "get in".** On Kinetis,
> unsecuring is a **mass-erase** — it wipes the 2 MB flash, so it trades the port for the
> firmware. If the goal is the original image, a secured part means the image is **not**
> recoverable over SWD; go to the fallback. (A vendor **bootloader exists** — release notes name
> bootloader 2.0.x — so #7 must also flash to the application offset and never chip-erase, or it
> destroys the only way back in.)

---

## 6. probe-rs target support

✅ paper (from [recon §10](recon.md#10-proposed-edits-to-5-6-and-7)). The Kinetis **MK26** family is in
the probe-rs target registry (`MK26*`). 🔬 On the bench, run `probe-rs chip list | grep -i MK26` early
to confirm the exact variant string; if the precise `MK26FN2M0…18` is absent, commit a small custom
target YAML (flash algorithm = standard Kinetis). The blinky project's
[flash notes](../../arduino-due/blinky/README.md#with-a-probe--probe-rs-over-swd) show the
`z5labs/devex` `flash` Dagger-module invocation pattern (`--chip`, `--usbip`, `--busid`) that #7 will
reuse with `--chip MK26…`.

---

## 7. Fallback if the MCU is locked — external SPI flash

**A locked debug port is not the end of the road.** This device records and streams audio, so
it has an **external SPI NOR flash — already located: U4, Cypress/Infineon `S25FS128S`, marking
`FS128SAIF00`, WSON-8, near the MCU** (physically confirmed,
[`teardown.md` §4.1](teardown.md#41-compute--digital-core)).

- 🔬 **Read it in-circuit** with a SOIC-8/WSON-8 test clip + **`flashrom`**, entirely independent of
  whether the MCU's debug port is protected. (WSON has no leads — a clip may need the neighbouring
  passives lifted, or read it on a hot-air-removed part.)
- It holds the **MAX 10 FPGA bitstreams** (backup + pending-burn), audio recordings, audio cues, and
  config. So the **FPGA logic image is likely recoverable even if the CPU is locked.**
- ⚠️ Config is described as holding **crypto keys**, so some contents may be **encrypted** — a
  successful read is not automatically a usable image.
- **The other route to the MCU image is the vendor app / OTA packages** (CRC-checked binaries,
  bootloader 2.0.x, numbered FPGA images). The owner already holds vendor app packages and the
  Cyclone production image. This is the most promising route to the original CPU firmware
  **without touching the debug port at all** — detailed in
  [recon §6/§8](recon.md#6-debug-port--firmware-dumpability-hypotheses-unconfirmed--for-57).

---

## 8. Bench log (fill in on the unit)

| # | Step | Result | Date |
|---|---|---|---|
| 1 | Debug port located: board / location | 🔬 | |
| 2 | Footprint type + pad pitch | 🔬 | |
| 3 | Continuity M8/N8/M9/L13 → pads ([§2](#2-proof-by-continuity--the-datasheet-cited-target-balls)) | 🔬 | |
| 4 | VTref measured (expect ~1.8 V) | 🔬 | |
| 5 | `probe-rs info` DP IDCODE / APs | 🔬 | |
| 6 | Part cross-check vs `MK26FN2M0VMI18` | 🔬 | |
| 7 | If silent: cause A/B/C ruled out how | 🔬 | |
| 8 | `FSEC` @ 0x40C + MDM-AP secured bit | 🔬 | |
| 9 | **Dump verdict: YES / NO** | 🔬 | |
| 10 | If locked: U4 S25FS128S read via flashrom | 🔬 | |
