# smart-stethoscope/hardware

The reverse-engineered **system schematic** for the smart stethoscope — editable KiCad source plus an
exported SVG, following the convention set by
[`arduino-due/blinky/hardware`](../../arduino-due/blinky/hardware).

![System schematic](smart-stethoscope.svg)

| File | Role |
|---|---|
| `smart-stethoscope.kicad_sch` | The schematic — editable source (open in KiCad ≥ 9) |
| `smart-stethoscope.kicad_pro` | KiCad project |
| `smart-stethoscope.svg` | Exported render, linked from here and from the [teardown doc](../docs/teardown.md) |

## This sheet is evidence, not a design

It is a **single system-interconnect sheet** reconstructed from the owner-held design specification
(block diagram + bus map + power table + clock topology) plus datasheet-fixed facts (the MK26 debug
balls). It shows every IC, every inter-chip net, power, and the debug port — at the evidence level
currently available, which is **pre-teardown**. Nothing here has been verified against the metal.

Because the physical board split is not yet known, reference designators are **logical/provisional**
(they name the function, not a board position) and match the [component inventory](../docs/teardown.md#4-component-inventory).

## Every net carries a confidence marker

Wire **colour = confidence**, and the sheet carries an on-drawing **net-confidence ledger** listing
every net with its basis:

| Colour | Confidence | Meaning |
|---|---|---|
| 🟢 green | **V** | verified by continuity — **none yet** (pre-teardown) |
| 🔵 blue | **S** | vendor design spec (block diagram / bus map / power table) |
| 🟠 orange | **D** | datasheet-fixed / typical application circuit (e.g. the MK26 fixed-function SWD balls) |
| 🔴 red | **?** | unknown / bench-TBD (exact pin mapping not yet known) |

**No net is green.** Green means *continuity-verified*, and nothing has been buzzed out yet — that
absence is the honest headline. As the [teardown](../docs/teardown.md) proceeds, re-open the schematic
in eeschema and recolour a net green (or correct it) only after proving it on the bench.

The debug port (`DP1`) nets are orange because the MK26 SWD balls are datasheet-fixed
(`PTA3=M8, PTA0=N8, PTA2=M9, PTA1=N9, PTA4=L9, RESET=L13`); the port's physical footprint and location
are still red/unknown — see [`docs/debug-port.md`](../docs/debug-port.md).

## Regenerate the SVG

Same command shape as the blinky project:

```sh
flatpak run --command=kicad-cli org.kicad.KiCad sch export svg \
  --output smart-stethoscope/hardware smart-stethoscope/hardware/smart-stethoscope.kicad_sch
```

(Drop the `flatpak run --command=kicad-cli org.kicad.KiCad` prefix if KiCad is installed natively.)
Rendered with KiCad 10.0.4. The `.kicad_prl` per-user local state file that KiCad writes is
`.gitignore`d — only the project, schematic, and SVG are tracked.
