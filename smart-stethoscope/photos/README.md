# Teardown photographs

🔬 **This directory is a bench checklist, not a gallery yet.** The photographs an acceptance criterion
of [#5](https://github.com/Zaba505/embedded/issues/5) requires can only be taken from the physical unit
by the owner, and none have been committed. This README lists exactly which shots are needed so the
bench session is a checklist, not a guess.

> **Photograph before you change anything.** You will want the pre-desolder state back and you cannot
> re-take it. High resolution, both sides, raking light. Shield cans hide exactly the parts that matter,
> and hot air lifts a can while reflowing everything under it — so shoot *before* and *after* each can.

There is no public FCC filing for this device to borrow internal photos from — the radio rides on a
pre-certified module ([teardown §10](../docs/teardown.md#10-fcc-filing)) — so these must be taken here.

## Required shots

| # | Shot | Committed |
|---|---|:---:|
| 1 | Intact device — all external faces | 🔬 |
| 2 | Regulatory / serial label (look for `Contains FCC ID: SSSBC127-X`) | 🔬 |
| 3 | Charging surface + acoustic port / diaphragm, before opening | 🔬 |
| 4 | Enclosure opened — internal overview, before removing any board | 🔬 |
| 5 | **Each board, top side**, high-res, raking light | 🔬 |
| 6 | **Each board, bottom side**, high-res, raking light | 🔬 |
| 7 | **Each shield can — before removal** (in place) | 🔬 |
| 8 | **Each shield can — after removal** (parts underneath exposed) | 🔬 |
| 9 | U1 MK26 BGA area + candidate debug pads (macro) | 🔬 |
| 10 | U4 S25FS128S SPI-NOR area (for the flashrom fallback clip) | 🔬 |
| 11 | 6× mic array + Mic5 (side-facing ambient) placement | 🔬 |
| 12 | Anything destroyed to gain access (adhesive, welds, torn flex) | 🔬 |

## Naming convention (suggested)

```
NN-short-description.jpg        e.g.  05-boardA-top.jpg
                                      07-mcu-shield-in-place.jpg
                                      08-mcu-shield-removed.jpg
```

Commit the originals (or a sensible-resolution export); reference the key ones from
[`../docs/teardown.md`](../docs/teardown.md) and
[`../docs/debug-port.md`](../docs/debug-port.md) as they land.
