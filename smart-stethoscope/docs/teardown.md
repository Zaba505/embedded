# Smart stethoscope — teardown & schematic reconstruction

**Story:** [#5 `story(steth-teardown)`](https://github.com/Zaba505/embedded/issues/5) — reverse-engineer
the schematic and identify the debug port. Blocks [#6 (PCB)](https://github.com/Zaba505/embedded/issues/6)
and [#7 (firmware)](https://github.com/Zaba505/embedded/issues/7).

> **This is reverse-engineering of a device the author owns, for repair and interoperability. It is
> not a certified medical device and nothing here is cleared for clinical use.** The original product
> was a market-cleared electronic stethoscope sold by its vendor; this project is not that product and
> makes no medical claim. Vendor and model names are **deliberately kept out of this repo** (see the
> [recon](recon.md) for why); the device is referred to generically throughout.

---

## 0. What this document is, and how to read the markers

This story's deliverable is **evidence, not a design.** A schematic that looks complete but is partly
fiction is worse than one with honest holes, because everything downstream ([#6](https://github.com/Zaba505/embedded/issues/6),
[#7](https://github.com/Zaba505/embedded/issues/7)) inherits the fiction silently. So every claim here
is tagged with where it came from and whether it has touched the metal yet.

This document has **two kinds of content**, and it never blurs them:

| Marker | Meaning |
|:---:|---|
| ✅ **paper** | Established from the owner-held design spec and/or manufacturer datasheets. No bench access needed; done now. |
| 🔬 **bench** | A measurement, photograph, or probe result that **only the owner can produce** with the physical unit (multimeter, debugger, camera). Left as an explicit blank to fill in — *not* guessed. |
| ✅ **bench-done** | A 🔬 item that has since been completed on the unit (with the reading recorded). |

**Per-part confidence** reuses the [recon's scale](recon.md#2-sources-and-how-confidence-is-rated):
`P` physically confirmed (marking read off the PCB) · `A` vendor spec · `B` datasheet-corroborated ·
`C` public source · `D` inferred. **Per-net confidence** in the schematic uses `V` verified-by-continuity
· `S` spec · `D` datasheet-fixed · `?` unknown (see [§11](#11-the-schematic)).

> **Honest status of this deliverable.** The **paper-and-CAD spine is complete**: the schematic, the
> full inventory, the power tree, the bus map, and the debug-port target pins are all reconstructed and
> committed. **No rail has been probed, no debugger attached, and no board photographed yet** — every
> 🔬 row below is still open. The point of doing the paper work first is that the bench session is now
> fill-in-the-blank against named target pins, not discovery from scratch.

---

## 1. Teardown procedure & disassembly order

Written as a checklist to follow at the bench. The device is a **sealed hygienic-use puck**; getting
in is destructive in places, so the order matters. 🔬 = still to be executed on the unit.

1. 🔬 **Photograph the intact device** — all faces, the label, any silkscreen, the charging surface.
   You cannot re-take the pre-teardown state. See [`photos/`](../photos/).
2. 🔬 **Find and record the FCC ID / regulatory label** (if any) before opening — cross-check against
   [§10](#10-fcc-filing).
3. 🔬 **Open the enclosure.** Record the method and anything destroyed (adhesive, ultrasonic weld,
   snap-fits). Note the acoustic port / diaphragm arrangement before disturbing it.
4. 🔬 **Photograph every board, both sides, before removing anything** — high resolution, raking light.
5. 🔬 **Establish the board count and per-board function** ([§3](#3-boards)). The spec is *logical*, not
   physical; the physical split is unknown until now.
6. 🔬 **Identify the power tree first** ([§6](#6-power-tree)). Battery → protection → charger →
   regulators → rails. Naming each rail by voltage is the fastest way to orient on the board.
7. 🔬 **Remove shield cans only when needed.** Hot air lifts them and reflows everything underneath —
   pick the moment, expect to lose the can, photograph before and after.
8. 🔬 **Remove conformal coating** locally before probing — the meter will not make contact through it.
9. 🔬 **Read every package marking** to confirm the paper inventory ([§4](#4-component-inventory));
   decode logo → part → date/lot code. Some parts (house-marked, laser-etched) may be
   unidentifiable — record them as such rather than omitting them.
10. 🔬 **Locate and prove the debug port** — the headline question. Full procedure in
    [`debug-port.md`](debug-port.md).

> **Lithium cell — do not short, puncture, or leave connected while probing.** Disconnect the Li-Po
> before continuity work.

> **Destructive delayering** to trace inner layers of a multilayer board is a genuine last resort:
> there is exactly one of these devices.

---

## 2. Bench toolkit

What the 🔬 steps in this document assume you have on the bench:

| Tool | Used for |
|---|---|
| Multimeter (continuity/diode + DC volts) | Continuity to MCU balls ([debug-port §2](debug-port.md#2-proof-by-continuity--the-datasheet-cited-target-balls)); rail voltages ([§6](#6-power-tree)) |
| Camera + raking light | The [`photos/`](../photos/) shot list |
| Hot-air rework station | Lifting shield cans; removing the WSON flash if it must come off |
| Conformal-coating removal (scalpel / rework pen / solvent) | Exposing pads for the meter |
| **SWD probe with a `VTref` pin** (CMSIS-DAP / J-Link / ST-Link) | **1.8 V** debug — a fixed-3.3 V probe can damage the part |
| `probe-rs` (and/or OpenOCD) | Reading the DP IDCODE and `FSEC` without writing ([debug-port §4](debug-port.md#4-then-prove-it-electrically)) |
| SOIC-8 / WSON-8 test clip + `flashrom` | In-circuit read of the external SPI-NOR fallback (U4) |
| Bench PSU / the device's own charger | Powering the board while probing VTref and connecting under reset |

---

## 3. Boards

🔬 **bench.** Board count, the per-board function split, and which board each part sits on are **not
knowable from paper** — the design spec is a logical block diagram, not a physical layout. Fill in as
the teardown proceeds:

| Board | Function (expected) | Key parts expected on it | Photos |
|---|---|---|---|
| 🔬 Board A (main / MCU) | Compute, storage, debug port | U1 MCU, U2 FPGA, U3 SDRAM, U4 flash, DP1 debug | 🔬 |
| 🔬 Board B (analog / audio) | Codec, headphone jack, some mics | U5 codec, J1 jack, mics | 🔬 |
| 🔬 Board C (flex / mic array) | 6× PDM mic array, touch/LED flex | MK1–6 mics, U7 touch | 🔬 |
| 🔬 Board D (power / charger) | PMIC, wireless charger, fuel gauge | U10 PMIC, U11 BQ51050B, U9 gauge | 🔬 |

*(Row set is a hypothesis from the block diagram; the real split — and whether these collapse onto
fewer boards — is a bench finding.)*

---

## 4. Component inventory

Reference designators here **match the schematic** ([`hardware/`](../hardware/)). Because the physical
board split is not yet known, refdes are **logical/provisional** — they name the function, not a board
position. Six rows are already **physically confirmed (P)** by reading the top-side package marking off
the bench unit during the non-destructive inspection; the rest are **paper** and must have their
markings read during the teardown.

The inspected unit is a **"Premium" build** (it carries the BQ51050B wireless charger *and* the E-Ink
panel).

### 4.1 Compute & digital core

| Ref | Marking as read | Decoded part | Package | Function | Datasheet | Conf. |
|---|---|---|---|---|---|---|
| **U1** | *(read on bench)* | NXP **MK26FN2M0VMI18** | 169-MAPBGA 9×9 | Main MCU: Cortex-M4F 180 MHz, **2 MB flash + 256 KB SRAM**; runs FreeRTOS, orchestrates audio/BT/storage/UI/power | NXP K26 DS `K26P169M180SF5` (Rev.4) + RM (owner archive) | **P** |
| **U2** | *(read on bench)* | Intel/Altera **10M16SCU169C8G** | 169-UBGA | MAX 10 FPGA (16 K LE, single-supply): all mic DSP (PDM→PCM, CIC + IIR biquad + denoise + FFT/ARMA), drives display SPI | Intel MAX 10 datasheet | **P** |
| **U3** | *(read on bench)* | ISSI **IS42VM16800H-75BLI** | 54-TFBGA | 128 Mbit ×16 1.8 V mobile LPSDR SDRAM, 133 MHz — working RAM | ISSI IS42VM16800H DS | **P** |
| **U4** | `FS128SAIF00` | Cypress/Infineon **S25FS128S** | WSON-8 | 128 Mbit (16 MB) SPI/QSPI NOR, 1.8 V — audio recordings, cues, **FPGA logic images**, config (serial #, **crypto keys**) | Infineon `002-00368` (owner archive) | **P** |

### 4.2 Radio / connectivity

| Ref | Marking as read | Decoded part | Package | Function | Datasheet | Conf. |
|---|---|---|---|---|---|---|
| **M1** | 🔬 | BlueCreation **BC127** | module | The only radio: BT Classic (A2DP/HFP) + BLE/SPP; file transfer; UART to MCU | BC127 TechSpec (owner archive); FCC `SSSBC127-X` | **B** |

### 4.3 Acoustic / audio path

| Ref | Marking as read | Decoded part | Package | Function | Datasheet | Conf. |
|---|---|---|---|---|---|---|
| **MK1–6** | 🔬 (`MP34DT02TR`) | 6× ST **MP34DT02** | MEMS | PDM MEMS mics: **5 body + 1 ambient** (Mic5, side-facing, for noise cancellation). PDM straight to FPGA — **no analog stage** | ST MP34DT02 DS | **A** |
| **U5** | 🔬 | NXP **SGTL5000** | QFN | Stereo audio codec + HP amp: drives 3.5 mm jack for live monitoring; I²S from MCU; its I²S L/R clock is the timing master the FPGA locks its mic clock to | SGTL5000 DS (owner archive) | **B** |

### 4.4 Sensors & human interface

| Ref | Marking as read | Decoded part | Package | Function | Datasheet | Conf. |
|---|---|---|---|---|---|---|
| **U6** | 🔬 (`FXOS8700CQR1`) | NXP **FXOS8700CQ** | QFN | 6-axis accel + mag; ~1000 accel vectors @100 Hz per recording in metadata | FXOS8700CQ DS | **A** |
| **U7** | 🔬 | Azoteq **IQS333** | QFN | Cap touch controller (Premium): 3 buttons (TZ0–2) + right-edge slider (wheel 2); drives 6 UI LEDs; proximity wake | IQS333 DS (owner archive) | **A/B** |
| **U8** | 🔬 | ON Semi / TI **PCA9535 / TCA9535** | TSSOP/QFN | 16-bit I²C GPIO expander (**Economy** variant): reads SW1–4, drives LEDs. *Not expected on this Premium unit.* | PCA9535 DS (owner archive) | **A/B** |
| **DS1** | 🔬 | E Ink **ET011TT2** (spec `ET011TT2U1`) | module | 1.1″ round EPD, 240×240, SPI (via FPGA) — Premium status UI | [Beck Elektronik ET011TT2](https://www.beck-elektronik.de/en/products/displays/e-paper-display-epd/active-matrix-e-paper/active-matrix-epd/et011tt2) | **A**/C |
| **D1–D7** | 🔬 | 6–7 discrete LEDs | 0402/0603 | Status: charge / BT / recording / classification / battery. D4 (Premium) / D2 (Economy) charge LED wired direct to charger | — | **A** |

### 4.5 Power tree parts

| Ref | Marking as read | Decoded part | Package | Function | Datasheet | Conf. |
|---|---|---|---|---|---|---|
| **BT1** | 🔬 | Li-Po ~500 mAh, ~4.2 V | cell | Sole power source | — | **A** (cell PN **D**) |
| **U11** | *(read on bench)* | TI **BQ51050B** | QFN | Qi v1.2 wireless-power RX + integrated Li-Ion charger (≤1.5 A) — Premium wireless charging | [TI BQ51050B](https://www.ti.com/product/BQ51050B) | **P** |
| **U10** | *(read on bench)* | TI **TPS65053** | 24-VQFN | PMIC: 2 buck (DCDC1 1 A, DCDC2 0.6 A) + 3 LDO — generates 1.8 V / 3.3 V / 3.3 Va / 2.5 V rails | [TI TPS65053](https://www.ti.com/product/TPS65053) | **P** |
| **U9** | 🔬 (`LC709203FQH-01TWG`) | ON Semi **LC709203F** | QFN | I²C battery fuel gauge — SoC; **must be initialised before other I²C0 traffic**, and only when not charging | onsemi LC709203F DS | **A** |
| **L1** | 🔬 | Rx coil (Qi) | coil | Receives inductive power → BQ51050B AC1/AC2 | — | **A** |

### 4.6 Debug / test

| Ref | Marking as read | Decoded part | Package | Function | Datasheet | Conf. |
|---|---|---|---|---|---|---|
| **DP1** | 🔬 | Debug port (footprint TBD) | 🔬 | SWD/JTAG to U1; the headline of this story — see [`debug-port.md`](debug-port.md) | — | **A** (hypothesis) |

---

## 5. Explicitly unidentified

Listed rather than omitted — each is a known gap for the bench:

- **Wired battery charger** (Economy 5 V path via the mic jack) — not named in the spec; may be
  integrated into the PMIC. *Not present on the Premium bench unit* (it charges via BQ51050B), so it
  cannot be confirmed from this unit at all.
- **Li-Po cell** — capacity/chemistry known (~500 mAh, ~4.2 V), no part number.
- **Board count & per-board part placement** ([§3](#3-boards)) — logical spec only; a bench finding.
- 🔬 Any **house-marked / laser-etched** parts found on the board that decode to nothing — record as
  unidentified, do not invent a part number.

---

## 6. Power tree

Battery → protection → charger → PMIC → rails. The **spec/expected** column is ✅ paper (from the
design-spec power table + sequencing note); the **measured** column is 🔬 — *these must be probed, not
copied from the datasheet-typical values.*

```
                 ┌───────────────┐
  Qi coil L1 ───►│ U11 BQ51050B  │──► +VBAT ──┬──► U9 fuel gauge (I²C0 0x16)
 (Premium)       │ Qi RX+charger │            │
                 └───────────────┘            ▼
  5 V via jack ─────(Economy only)──►  ┌───────────────┐
                                       │  U10 TPS65053 │──► +1V8  ─► core/dig, SDRAM, flash, mics, codec-dig, touch
                                       │  PMIC 2×buck  │──► +3V3  ─► codec-analog, IMU, FPGA core/VCCA, BC127, display
                                       │      +3×LDO   │──► +3V3a
                                       └───────────────┘──► +2V5
       power-on sequence:  1.8 V ─► 3.3 V ─► 3.3 Va ─► 2.5 V     (SGTL5000 needs 1.8 V before 3.3 V)
```

| Rail | Spec/expected (✅) | Source | Feeds | Measured (🔬) |
|---|---|---|---|:---:|
| **+VBAT** | ~4.2 V (Li-Po) | BT1 / U11 charger out | PMIC input, fuel gauge, charge LED | 🔬 |
| **+1V8** | 1.8 V | U10 DCDC1 | CPU core/dig, SDRAM, flash, 6× mics, codec-digital, touch, 1.8 V IO | 🔬 |
| **+3V3** | 3.3 V | U10 DCDC2 | codec-analog, IMU, FPGA core/VCCA, BC127, display | 🔬 |
| **+3V3a** | 3.3 V (analog) | U10 LDO | analog domains | 🔬 |
| **+2V5** | 2.5 V | U10 LDO | (bench: identify load) | 🔬 |

- 🔬 **Confirm the PMIC rail→pin mapping.** The spec names the *rails* (2 buck + 3 LDO) but not which
  TPS65053 output produces which rail — buzz each output.
- 🔬 **Confirm charge path.** Premium = BQ51050B (Qi). The CHARGE signal to the MCU is **PTA24 / ball
  K11** (low = charging); the charge LED is wired directly to the charger so it lights even when the
  battery is too low for the CPU to boot.
- **Digital core is 1.8 V.** This is the single most safety-relevant power fact: a 3.3 V debug
  probe on a 1.8 V part can damage it — see [`debug-port.md`](debug-port.md).

---

## 7. Analog / acoustic signal chain

**The one architectural fact that matters most: this device has _no analog microphone front end at
all._** ✅ paper (design spec, mic section + block diagram):

```
  6× PDM MEMS (MP34DT02)          U2 MAX 10 FPGA (all DSP in fabric)                U1 MCU        U5 codec
  5 body + 1 ambient (Mic5)  ──►  CIC decimate 48:1 ──► IIR dual-biquad    ──► I²S ──► (slave) ──► I²S ──► HP jack J1
  PDM: clk ≤2.4 MHz, data         bandpass ──► sum mic0-4 + separate           passes audio to codec for
  (FPGA generates mic clock,      ambient ch ──► denoise ──► I²S               live auscultation monitoring
   PLL-locked to codec I²S
   L/R 8 kHz, ×64)
```

- **Transducer type:** omnidirectional **PDM MEMS** (digital). There is no electret, no analog MEMS,
  no piezo, and therefore **no gain/filter/ADC stage to look for** — a PDM mic clocks straight into the
  FPGA. This changes the whole shape of the schematic and of the [#6](https://github.com/Zaba505/embedded/issues/6)
  redesign.
- **Acoustic/electrical coupling:** 5 mics face the body (chestpiece), **Mic5 is side-facing** (input
  port out the side of the puck) as the ambient/noise reference for cancellation. The mics power down
  by stopping their clock when idle.
- 🔬 **Confirm mic count and technology on the bench.** There is a genuine spec-vs-public conflict
  worth resolving against the metal: the vendor's foundational patent describes a research embodiment
  with **five _electret_** mics, while the owner-held spec shows **six _PDM MEMS_ (MP34DT02)**. The
  commercial device diverged; do not assume either source — read the mic markings and count them.
- 🔬 **Confirm the codec output** to the headphone jack (HP_L/HP_R) and the I²S clock topology
  (codec L/R clock is the master the FPGA locks to).

---

## 8. Inter-chip bus map

Every inter-chip bus, by protocol and by which pins it lands on at both ends. The **MCU-side named
balls** are ✅ where the spec or datasheet names them; most MCU-side ports are 🔬 (the exact BGA balls
are a bench finding — buzz them out). Endpoint device-side pins follow each device's datasheet.

| Bus | Protocol | Signals | MCU side (U1) | Peripheral side | Conf. |
|---|---|---|---|---|:---:|
| **I²C0** | I²C, 1.8 V, pull-ups to +1V8 | SCL, SDA | 🔬 (I²C0 pinmux) | U6 IMU **0x1E**, U5 codec **0x0A**, U9 gauge **0x16**, U2 FPGA **TBD** | S |
| **I²C2** | I²C, 1.8 V, pull-ups to +1V8 | SCL, SDA | 🔬 (I²C2 pinmux) | U7 touch **0x64**, U8 GPIO **0x40** | S |
| **SPI1** | SPI, 1.8 V | SCK, MOSI, MISO, 3× CS | 🔬 (SPI1 pinmux) | U4 flash (**CS1**), U2 FPGA regs (**CS2**), DS1 display (**CS0, via FPGA**) | S |
| **I²S0** | I²S, MCU master | MCLK, BCLK, LRCLK, TXD, RXD | 🔬 (I²S0 pinmux) | U5 codec ↔ U2 FPGA | S |
| **UART0** | UART | TX, RX | 🔬 (UART0 pinmux) | M1 BC127 | S |
| **PDM ×6** | PDM | mic clock + data | — (FPGA-side) | U2 FPGA ↔ MK1–6 mics; 🔬 exact line count/pairing | ? |
| **SDRAM/FlexBus** | parallel | A[·], D[15:0], CLK/CKE/CS/RAS/CAS/WE/DQM | 🔬 (FlexBus/SDRAMC) | U3 SDRAM | ? |
| **SWD/JTAG** | ARM debug | SWDIO, SWCLK, SWO, (TDI), nRESET | **PTA3=M8, PTA0=N8, PTA2=M9, PTA1=N9, RESET=L13** ✅ | DP1 debug pads | D |
| **Control** | GPIO/IRQ | CHARGE_n, touch/GPIO INT, BLE reset/vreg-en | **CHARGE=PTA24/K11**, **INT=PTC4/LLWU_P8 (spec 'B8')** ✅; BLE_RESET/VREG from **FPGA** | U11 charger, U7/U8, M1 | S |

*(MCU-side debug and control balls are ✅ because the MK26 datasheet fixes them and the spec names
PTA24/LLWU_P8; the bus-port balls (I²C/SPI/I²S/UART) are pin-mux choices and remain 🔬 until read on the
board — but the peripheral-side addresses and the buses themselves are spec-solid.)*

---

## 9. Debug port & firmware dumpability

The headline question — *where is the debug port, what is it, and can the original firmware be read
back* — has its own document: **[`debug-port.md`](debug-port.md).** It carries the footprint candidates,
the datasheet-cited SWD-ball continuity table (proof-by-continuity targets), the DAP-response triage,
the Kinetis `FSEC` readout-protection verdict template, and the external-SPI-flash fallback. That
verdict is the gate for [#7](https://github.com/Zaba505/embedded/issues/7).

---

## 10. FCC filing

✅ paper (from the [recon §7](recon.md#7-fcc-filing)). **No standalone FCC filing exists for the device**
— a confident negative, because the radio rides on a **pre-certified module**: the BlueCreation
**BC127** carries its own modular grant **FCC ID `SSSBC127-X`** (grantee Cambridge Executive Limited;
2402–2480 MHz BT Classic + BLE; module internal photos public at
[fccid.io/SSSBC127-X](https://fccid.io/SSSBC127-X)). Consequence for the bench: **fccid.io will not hand
over better teardown photos of this device** the way it often does for whole-product filings — the
photographs in [`photos/`](../photos/) have to be taken here. 🔬 Confirm the *"Contains FCC ID:
SSSBC127-X"* marking on the device label during the teardown.

---

## 11. The schematic

Editable KiCad source and an exported SVG are in **[`hardware/`](../hardware/)** — see
[`hardware/README.md`](../hardware/README.md) for the confidence colour key, the full net ledger, and
the regeneration command.

The schematic is a **single system-interconnect sheet** at the evidence level currently available:
every IC, every inter-chip net, power and debug, drawn from the owner-held spec plus datasheet-fixed
facts. **Every net is colour-coded by confidence** and the sheet carries an on-drawing net-confidence
ledger. Crucially, **no net is green** — green means *verified by continuity*, and nothing has been
buzzed out yet. That absence is the honest headline: this is a spec reconstruction, and the bench
session's job is to turn nets green (or correct them) one probe at a time.

![System schematic](../hardware/smart-stethoscope.svg)

---

## 12. Acceptance-criteria trace

| #5 criterion | Status | Where |
|---|:---:|---|
| Project directory in vendor-scoped layout | ✅ | `smart-stethoscope/` (unbranded; see [README](../README.md)) |
| Part numbers & descriptions recorded, mapped to board | ✅ parts / 🔬 board | [§4](#4-component-inventory) (board split [§3](#3-boards) 🔬) |
| Photos of both sides of every board, pre-disassembly + post-shield | 🔬 | [`photos/`](../photos/) checklist |
| FCC filing located (or recorded absent, why) | ✅ | [§10](#10-fcc-filing) |
| Component inventory table w/ marking, decoded PN, package, function, datasheet, **confidence** | ✅ | [§4](#4-component-inventory) |
| Unidentified parts listed explicitly | ✅ | [§5](#5-explicitly-unidentified) |
| Power tree end-to-end with **measured** rail voltages | ✅ tree / 🔬 measured | [§6](#6-power-tree) |
| Analog signal chain: transducer type + coupling | ✅ | [§7](#7-analog--acoustic-signal-chain) |
| Every inter-chip bus by protocol + pins at both ends | ✅ spec / 🔬 MCU balls | [§8](#8-inter-chip-bus-map) |
| **KiCad schematic committed** (editable source) | ✅ | [`hardware/`](../hardware/) |
| Exported SVG committed + linked + regen command | ✅ | [`hardware/`](../hardware/), [README](../hardware/README.md) |
| **Every net carries a confidence marker** | ✅ | [§11](#11-the-schematic) (colour + on-sheet ledger) |
| **Debug port identified**: board, location, footprint, pitch, pin-by-pin | ✅ targets / 🔬 physical | [`debug-port.md`](debug-port.md) |
| Each debug pad proven by continuity to a **named datasheet MCU pin**, pins recorded | ✅ targets / 🔬 continuity | [`debug-port.md`](debug-port.md) |
| Debug protocol + **measured** logic level recorded | ✅ protocol / 🔬 level | [`debug-port.md`](debug-port.md) |
| **Debugger attached, DAP responds**, IDCODE recorded + cross-checked | 🔬 | [`debug-port.md`](debug-port.md) |
| If DAP silent, which of 3 causes ruled out, how | 🔬 | [`debug-port.md`](debug-port.md) |
| **Readout-protection state determined**, explicit dump yes/no | 🔬 | [`debug-port.md`](debug-port.md) |
| If MCU locked, external SPI flash checked as alternate route | ✅ located / 🔬 read | [`debug-port.md`](debug-port.md) (U4 already located) |
| README: procedure, disassembly order, what was destroyed | ✅ procedure / 🔬 destroyed | [§1](#1-teardown-procedure--disassembly-order) |
| README: owner's device, repair/interop, not a certified medical device | ✅ | header + [README](../README.md) |

**Legend:** ✅ done from paper/CAD · 🔬 pending a bench measurement only the owner can take. This story
is *not* closed until the 🔬 rows are filled — but the discovery scaffolding they hang on is complete.
