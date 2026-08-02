# rtk

A two-node RTK GNSS survey system for a 0.69-acre wooded lot: a **base station** bolted permanently
to a roof, and a **rover** — a hand-pushed cart that logs a GNSS epoch five times a second while
somebody walks it over lawn, pine straw and gravel. Post-processed against the base, the rover
produces full-property elevation and a genuinely located tree line.

**This directory currently contains the electrical diagrams and nothing else.** Per the repo's
[hardware-first rule](../CLAUDE.md), the schematics are the first deliverable of any project here and
they are reviewed on their own, before any firmware exists. Every coding story then implements
against them.

## The system

![System overview](hardware/rtk.svg)

Two nodes and one radio link. Both nodes are the **same schematic** — same MCU, same receiver board,
same radio, same storage, same pin assignment — because it means one bring-up serves both and there
is only ever one pin table to get right. What differs is the power source, the field indicator, the
antenna mount, and which end of the radio link actually transmits.

| | base | rover |
|---|---|---|
| power source | mains + pass-through bank as a UPS | 5 V USB power bank |
| field indicator | RGB LED only | RGB LED + memory LCD + buzzer + mark button |
| antenna mount | roof ridge, forced centering | 0.5 m mast on the cart |
| radio | transmits (PL=0, +7 dBm) | receive-only, never keys up |
| fault policy (#50 / #52) | `reset` — unattended, keep serving | stop and say so — a human is there |

**The correction link is one-way on purpose.** RTCM3 is broadcast base → rover with no
acknowledgement, so the rover's radio never transmits, so it can never desense the GNSS antenna
sitting a metre from it. The cost — the base cannot know the rover missed a message — is already
paid, because PPK reprocesses the whole session from raw observations at the desk. A dropped
correction degrades the live display and nothing else.

## Layout — grouped by system, not by vendor

Most projects in this repo are scoped by board vendor. This one is not: it is two boards of the same
kind doing different jobs, plus a codec they share, so it is grouped by **system**.

```
rtk/
  hardware/   the KiCad project — five sheets covering both nodes.  ** this story **
  base/       base-station firmware (#50)
  rover/      rover logger firmware (#52)
  epoch/      the shared, architecture-neutral epoch record codec (#51)
```

`base/`, `rover/` and `epoch/` do not exist yet. They are listed because the layout is part of what
this story settles: `epoch/` is deliberately a sibling of the two firmware directories rather than a
subdirectory of either, since both import it and desk-side tooling uses it unchanged.

## The sheets

Editable KiCad source is in [`hardware/`](hardware/): `rtk.kicad_pro`, five `.kicad_sch` files, and
`rtk.kicad_sym` — a project-local symbol library, wired up through `sym-lib-table`, so the sheets do
not carry orphaned embedded symbols.

**The schematics are the source of truth for every value below.** They also carry the derivations,
the rejected alternatives and the datasheet citations behind them; this README is a summary and a
map.

### `rtk-node` — one node, drawn once, built twice

![Node](hardware/rtk-node.svg)

The Arduino Due, the ZED-F9P carrier, the XBee radio, the microSD card, and the pin assignment table
that every later story cites instead of a pinout website.

### `rtk-antenna` — the antenna chain, the ARP offset, and radio coexistence

![Antenna](hardware/rtk-antenna.svg)

The gain budget, the bias budget, a dimensioned figure of the antenna reference point, and the
arithmetic that sets the minimum separation between the GNSS antenna and the radio antenna.

### `rtk-power` — both power plans, session length, and the brownout hazard

![Power](hardware/rtk-power.svg)

### `rtk-indicator` — what the operator can see with their hands on the handle

![Indicator](hardware/rtk-indicator.svg)

## What was bought, and why

| | part | why |
|---|---|---|
| receiver | u-blox **ZED-F9P** on a SparkFun GPS-RTK-SMA carrier | the best-documented multi-band RTK module: every number on these sheets traces to a u-blox document with a revision on it |
| antenna | u-blox **ANN-MB-00**, L1/L2, 5 m RG-174, SMA | specified as a complete chain against the F9P's 17–50 dB external-gain window, with published phase-centre offsets |
| radio | Digi **XBee-PRO 900HP S3B** | a pre-certified modular radio (FCC ID MCQ-XB900HP) with a documented transmit current and hardware flow control |
| logger | **Arduino Due** (Atmel SAM3X8E) ×2 | the toolchain already exists in this repo — pinned Zig Dagger module, linker script, `target.json`, `bossac` flashing with no probe, `lib/hal`'s memory-mapped backend |
| storage | microSD, raw sectors, no filesystem | see below |
| display | Sharp **LS027B7DH01** memory LCD on a breakout | reflective, so it gets *more* readable as the sun gets brighter |

### IMU tilt compensation is out of scope, and that is a decision, not an omission

At 0.5 m antenna height, 10° of tilt is 8.7 cm of horizontal error, and a cart on roots and leaf
litter is not bubble-levelled. Tilt compensation is the clean way out — and it is rejected here for
three reasons, of which only the first is the obvious one.

It changes which board gets bought (the ZED-F9P has no IMU and no dead reckoning at all — *"the
ZED-F9P firmware does not support the dead reckoning position fix type"*), and the tilt-capable
alternatives cost roughly eight times as much for the pair. The ZED-F9R is not a substitute: it is
automotive sensor fusion, *"optimized for automotive, e-scooter, rail vehicle and robotic lawn mower
platforms only"*, and it wants wheel ticks and a calibration drive.

**But the finding that actually settles it is that a cart cannot perform the procedure.** Every
documented tilt-compensation initialisation assumes a survey pole with its tip planted on the ground
— shake it, plant it, rock the head — and the mode exits the moment RTK fix is lost. It would be
present on the open lawn where it is not needed and absent under the pines where it is.

So the rover applies a **fixed ARP → ground offset**, records it per epoch, and #54 measures the
residual tilt by driving over monumented iron pipes. That is an honest 10 cm instrument rather than a
silent one — and if tilt turns out to dominate, the first lever is a shorter mast, not a different
receiver.

### Storage: a bounded append-only region on raw sectors

A microSD card written as raw 512-byte sectors in SPI mode, as one append-only region of fixed-stride
records. No FAT, no directory, no file; read at the desk with `dd`.

The whole address calculation is `sector = REGION_BASE + (sequence * STRIDE) / 512`. No allocator, no
cluster chain, no free-space search, and therefore no unbounded worst case. FAT32 from freestanding
Zig would have been a larger subproject than the rover firmware it exists to serve, and it makes
every power cut worse: appending to a file touches the data cluster, the FAT chain and the directory
entry, so an interrupted append can lose the filesystem rather than one record.

**Read that precisely.** Append-only removes *our* metadata from the path of a power cut. It does not
make the card safe — see below.

### The brownout, which is the rover's only genuine hardware hazard

Nothing in this system is energised, hot, or moving. The one thing that can be destroyed is data, and
the way to destroy it is to collapse the supply partway through a card write.

The SD Physical Layer Simplified Specification (9.10; the same wording is in 3.01) is less reassuring
than folklore: §4.3.3 guarantees data survives sudden shutdown **"except write or erase operations
issued by the host"**, and §7.2.4 warns that terminating a program in progress *"may destroy the data
formats on the card"*. Swissbit's power-failure application note AN2109en documents loss of data
written long before, spare-block exhaustion, and cards that stop identifying themselves. There is no
bound.

So the mechanism is four layers, cheapest first:

1. **Don't lose power unexpectedly** — a strain-relieved, cable-tied USB connection, a bank sized to
   three times the longest session, and a divider on the *5 V* rail into `A0` so firmware sees the
   sag before the regulated rail knows about it. This is the layer the rover's "stop and say so"
   fault policy acts on.
2. **Detect it in hardware** — the SAM3X8E supply monitor (`SUPC_SMMR`) at 3.0 V, raising an
   **interrupt, not a reset**: a reset at an arbitrary instant leaves the chip selects in an
   arbitrary state, which is the exact condition §7.2.4 warns about.
3. **Hold up long enough to finish and shut down in order** — 4700 µF gives ~7.6 ms between the
   3.0 V trip and the card's 2.7 V minimum, against 0.51 ms of wire time for a 512-byte sector. The
   *order* matters too: the card's pull-ups can back-power its controller from host pins left high.
4. **Assume the card can still be lost** — a magic header, a per-record check field, monotonic
   sequence numbers, a spare card in the operator's pocket, and the base's own log as the second copy
   of the one thing that cannot be re-driven.

A hold-up big enough to *guarantee* the card finishes is deliberately not built: §4.6.2.2 defines the
maximum busy as 250 ms for all writes on a High Capacity card, lets an SDXC/SDUC card stretch to
500 ms in four named cases, and §4.6.2 then recommends hosts tolerate *more* than 500 ms. At 214 mA
across a 0.6 V window that would need 178,000 µF.

### Session length — and why a four-hour battery is not a requirement

Because PPK ties every session back to the same base, sessions stitch with no registration step. The
method is a coarse pass at 1 m track spacing (~1.7 h) and selective densification afterwards, so the
worst case is the 3.4 h full-property pass at 0.5 m spacing.

| | average draw at 5 V | worst-case burst |
|---|---|---|
| rover | 330 mA (1.65 W) | 462 mA (2.31 W) |
| base | 295 mA (1.48 W) | — |

A 5000 mAh bank delivers about 16.7 Wh at 5 V, so the rover runs **10.1 hours** — three times the
longest planned session. A 2500 mAh bank still clears it at 5.0 hours. Ten thousand is 190 g of cart
nobody needs. The base's 10000 mAh pass-through bank buys about **22 hours** of ride-through, and
when a cut outlasts it the node boots back into service by itself — with the MCU re-applying the full
base configuration over UART1 on **every** boot, because the module's backup cell holds it for about
five days rather than the advertised two weeks.

### The under-canopy bet, and the way out if it loses

Hardware is being committed before anyone knows whether RTK holds a fix under these pines; there is
no feasibility spike ahead of this story. The bet is recorded on the sheets rather than discovered
later.

The boundary half of the original job is already answered by a Class A VRS RTK survey at 0.08 ft
horizontal. The topography half is untouched by it — the tell is the letter H in *"positional
accuracy: H 0.08'"*, a horizontal figure with no vertical companion anywhere on the sheet. Roughly
two thirds of the parcel is open, so a total under-canopy failure produces **holes, not a dead
project**: a complete, uniform, current surface over the open ground and gaps under the trees.

The named escape route is **UWB ranging anchors on the monumented iron pipes** — UWB does not care
about sky view, the monuments are already surveyed to 2.4 cm, and the rover carries spare UARTs and a
spare SPI chip select. It is not being built now; it is recorded so it is an escape route rather than
a surprise.

## Pin assignment

Reproduced from the `rtk-node` sheet, which is the source of truth. Header positions are Arduino Due
datasheet A000062 §6.2.1–6.2.5; current groups are SAM3X `Atmel-11057C` table 45-2, note 2 (Group 1,
−15 mA source / 9 mA sink) and note 3 (Group 2, −3 mA / 6 mA).

| signal | Due pin | port | header + position | dir | group | goes to |
|---|---|---|---|---|---|---|
| `GNSS1_MCU_TX` | D18 | PA11 | 26-pin pos 23, TXD0 | out | 2 | ZED-F9P J7-3 UART1 RXI |
| `GNSS1_MCU_RX` | D19 | PA10 | 26-pin pos 24, RXD0 | in | 2 | ZED-F9P J7-2 UART1 TXO |
| `GNSS2_MCU_TX` | D14 | PD4 | 26-pin pos 19, TXD3 | out | 1 | ZED-F9P J7-5 UART2 RX2 |
| `GNSS2_MCU_RX` | D15 | PD5 | 26-pin pos 20, RXD3 | in | 1 | ZED-F9P J7-6 UART2 TX2 |
| `RADIO_MCU_TX` | D16 | PA13 | 26-pin pos 21, TXD1 | out | 2 | XBee pin 3, DIN |
| `RADIO_MCU_RX` | D17 | PA12 | 26-pin pos 22, RXD1 | in | 2 | XBee pin 2, DOUT |
| `RADIO_nRTS` | D23 | PA14 | RHS pos 2, RTS1 | out | 1 | XBee pin 16, nRTS |
| `RADIO_nCTS` | D24 | PA15 | LHS pos 3, CTS1 | in | 1 | XBee pin 12, nCTS |
| `RADIO_nRESET` | D12 | PD8 | 26-pin pos 6 | o-d | 1 | XBee pin 5, nRESET |
| `GNSS_RESET_N` | D50 | PC13 | LHS pos 16 | o-d | 1 | ZED-F9P J6-4 RESET |
| `GNSS_PPS` | D51 | PC12 | RHS pos 16 | in | 1 | ZED-F9P J6-3 TIMEPULSE |
| `SPI_SCK` | — | PA27 | ICSP pos 3 | out | 1 | microSD CLK, LCD SCLK |
| `SPI_MOSI` | — | PA26 | ICSP pos 4 | out | 1 | microSD DI, LCD SI |
| `SPI_MISO` | — | PA25 | ICSP pos 1 | in | 1 | microSD DO |
| `SD_CS_N` | D48 | PC15 | LHS pos 15 | out | 1 | microSD CS (active low) |
| `SD_DET` | D52 | PB21 | LHS pos 17 | in | 2 | microSD DET (card detect) |
| `LCD_CS` | D49 | PC14 | RHS pos 15 | out | 1 | LCD SCS (**active high**) |
| `LCD_EXTCOMIN` | D9 | PC21 | 26-pin pos 9 | out | 1 | LCD JP1-9 EXTCOMIN |
| `LCD_DISP` | D8 | PC22 | 26-pin pos 10 | out | 1 | LCD JP1-8 DISP |
| `LED_R_DRV` | D3 | PC28 | 26-pin pos 15 | out | 1 | Q1 base |
| `LED_G_DRV` | D5 | PC25 | 26-pin pos 13 | out | 1 | Q2 base |
| `LED_B_DRV` | D6 | PC24 | 26-pin pos 12 | out | 1 | Q3 base |
| `BUZZER_DRV` | D7 | PC23 | 26-pin pos 11 | out | 1 | Q4 base |
| `MARK_BTN_N` | D11 | PD7 | 26-pin pos 7 | in | 1 | SW1, pulled up (rover only) |
| `VBAT_SENSE` | A0 | PA16 | 24-pin pos 9, AD7 | ain | 2 | 5 V divider |
| `+5V` | — | — | 24-pin pos 5 | power | — | 5 V source; also feeds the GNSS carrier |
| `+3V3` | — | — | 24-pin pos 4 | power | — | XBee, microSD, memory LCD |
| `GND` | — | — | 24-pin pos 6 + ICSP pos 6 | power | — | single common ground |

> **Three places a count goes wrong.** **ICSP position 2 is +5 V and it is the neighbour of MISO** —
> and the microSD breakout is 3 V only, with no regulator and no level shifters, so 5 V on its supply
> pin destroys the card. **Both D22–D53 headers put +5 V at position 1**, so count from the GND end
> at position 18 instead. And the six-wire UART run at 26-pin positions 19–24 has no power pin near
> it, but **position 18 is `D0/RX0`**, the programming port's own receive line: a run that slips one
> position toward the board edge silently breaks flashing and fills the GNSS link with garbage.
>
> Arduino's own datasheet labels position 18 *"D0/TX0"* while describing it as *"Serial 0 Receiver"*.
> It is `D0/RX0`. That typo is the label you would be counting against.

> **Every I/O pin on this board tolerates 3.3 V and 5 V damages it.** The receiver is worse: its
> input pin voltage range is 0 to VCC with no headroom at all. There is no 5 V logic anywhere in this
> system — the only 5 V is a supply.

## Electrical ceilings

The rows both firmware stories copy into `resource-budget.md` §4, from the repo
[template](../docs/resource-budget.md). Full table with sources on the `rtk` sheet.

| quantity | ceiling | budget (worst case) | headroom |
|---|---|---|---|
| I/O voltage on any Due pin | 3.3 V | 3.3 V | 0 % |
| ZED-F9P input pin voltage | VCC (3.3 V) | 3.3 V | 0 % |
| Source current, Due Group 1 pin | −15 mA | −0.62 mA | 96 % |
| Source current, Due Group 2 pin | −3 mA | −0.05 mA | 98 % |
| Total DC output current, all Due I/O | 130 mA | 4.0 mA | 97 % |
| Antenna bias current out of `VCC_RF` | 50 mA | 15 mA typ | 70 % |
| Antenna bias voltage **at the antenna** | 3.0–5.0 V | **2.7 V as shipped** | **fails** |
| External gain seen at `RF_IN` | 17–50 dB | 21.4 dB typ | 4.4 dB over the floor |
| Input power at `RF_IN` | **+10 dBm absolute max** | −44 dBm at 1 m | 54 dB |
| microSD supply current, SPI mode | 100 mA | 100 mA | 0 % |
| Due board normal-mode current | 130–800 mA | 462 mA | 42 % |
| Radio conducted output power | +24 dBm max | +7 dBm (PL=0) | 17 dB |
| SPI clock, shared bus | 2 MHz (the LCD) | 2 MHz / 8 MHz | 0 % |

### One row does not pass, and that is the point of drawing it first

**The antenna bias voltage fails as shipped.** The SparkFun GPS-RTK-SMA feeds the antenna from the
ZED-F9P's `VCC_RF` (VCC − 0.1 V = 3.2 V) through a **33 Ω** series resistor. At the ANN-MB's 15 mA
that drops 0.5 V, so the antenna sees **2.70 V against a 3.0 V minimum**. The U.FL variant of the
same board — and u-blox's own reference design — use 10 Ω, which lands at 3.05 V with 50 mV to spare.

A sub-spec bias does not fail loudly. It leaves the LNA's gain and noise figure unspecified, and the
symptom is a receiver that tracks fewer satellites and holds a fix less well — **which is
indistinguishable from being under a tree**. This project's central open question is whether RTK
holds under this canopy; answering it with an under-volted LNA would produce a wrong answer nobody
could challenge.

So the sheet specifies a bring-up measurement rather than a blind modification: measure the DC at the
SMA centre with the antenna connected, and if it reads below 3.0 V, change `R14` to 10 Ω — accepting
that the shipped 33 Ω is the *only* current limiter in the bias path, and 10 Ω puts a shorted coax
above `VCC_RF`'s 300 mA absolute maximum. There is no value that satisfies both at a 3.3 V rail; a
design that owned its own board would bias the antenna from 5 V, where there are two volts to spend.

## Regenerating and checking the diagrams

No host KiCad. Everything goes through the `kicad` toolchain pinned by commit SHA in
[`dagger.json`](../dagger.json), like every other toolchain in this repo, so the commands carry no
module ref and no SHA of their own. Run them **from the repository root**.

```sh
# Re-export the SVGs. One file per sheet; the export lands them back in hardware/
# and leaves the KiCad sources alone.
dagger call kicad project --source=./rtk/hardware sch svg export --path=./rtk/hardware
```

```sh
# The Electrical Rule Check. This is the one that matters.
dagger call kicad project --source=./rtk/hardware sch erc --severity=all
```

**ERC passes with zero violations at `--severity=all`** — errors *and* warnings, across all five
sheets. That is a deliberately stronger bar than `arduino-due/blinky`, which passes at the default
`--severity=error` and carries eleven expected warnings. Meeting it required two things: the symbols
live in a project-local `rtk.kicad_sym` referenced through `sym-lib-table` rather than being embedded
in the sheets, and every net carries at least two connections, so there are no labels stranded on
single-pin nets.

> **A clean SVG export proves the sheet *renders*. Only ERC and the netlist prove it is *wired*.**
> KiCad silently stops parsing a `.kicad_sch` at the first element it does not understand and still
> plots everything it read, so a sheet can look perfectly drawn and be half empty electrically. The
> netlist is the mechanical proof of the thing this design most needs to be right:
>
> ```sh
> dagger call kicad project --source=./rtk/hardware sch netlist export --path=./netlist.net
> ```
>
> `/node/GNSS1_MCU_RX` lands on `A1.P26-24` (D19/RX1) and `U1.J7-2` (UART1 TXO);
> `/node/GNSS1_MCU_TX` lands on `A1.P26-23` (D18/TX1) and `U1.J7-3` (UART1 RXI). TX really is crossed
> to RX, at all four ends of the three serial links, and that is a fact about the file rather than
> about the picture.

The rest of `kicad-cli` is reachable the same way — `sch pdf`, `sch bom`, `sch netlist` — and
`dagger call kicad version` reports which KiCad the pin ships (10.0.5 at the time of writing, against
sheets written in the 9.0 file format, which it reads unchanged).

## What this story deliberately does not decide

- **Anything in firmware.** No project skeleton, no linker script, no register write.
- **The epoch record's field layout.** #51 owns the wire format; these sheets only fix that it is
  bounded and fixed-stride, because the storage decision depends on that and nothing else.
- **The property boundary geometry.** The plat's corners and the cul-de-sac arc live in the owner's
  CAD repo, not here.
- **The phone app and the desk-side GIS / PPK pipeline.** Out of scope for this repo entirely.
- **The chassis.** Wheelbase and wheel diameter set the effective topographic resolution — #54
  measures it — and the only things these sheets impose are the mast height and the 1 m of separation
  between the two antennas.

## What comes next

| story | what it builds |
|---|---|
| #50 | the base station: corrections over the radio from a permanently repeatable mount, and the repo's first `reset` fault policy |
| #51 | `rtk/epoch/` — a bounded record in which it is impossible to encode a position without its solution status |
| #52 | the rover logger: every epoch at 5 Hz, and never a FLOAT promoted to ground truth |
| #53 | the field indicator: telling the operator *which kind* of coverage hole they are standing next to |
| #54 | driving the monumented iron pipes to turn the error budget into measured numbers |

Per the repo rule, those stories implement against these diagrams and extend them only to annotate a
decision the diagrams left open. #54 explicitly does the reverse as well: any hardware assumption its
measurements contradict gets corrected here.
