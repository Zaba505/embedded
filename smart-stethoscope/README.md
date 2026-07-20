# Smart stethoscope

Reverse-engineering of a discontinued **"smart" digital stethoscope** — for repair and
interoperability. This is a device the author owns.

> **This is not a certified medical device.** Nothing in this directory is cleared for clinical
> use. It is a repair-and-interoperability project on hardware the owner already possesses.

> **Identity intentionally withheld.** The exact vendor and model have been positively identified by
> the owner, but the brand names are **deliberately kept out of this repo** to avoid trademark and
> rights entanglements. The device is referred to generically throughout. Because there is no named
> vendor to scope under, this project uses a single unbranded directory instead of the repo's usual
> `<vendor>/<product>/` layout (cf. [`arduino-due/blinky`](../arduino-due/blinky)).

## Where to start

| Document | What it is |
|---|---|
| [`docs/recon.md`](docs/recon.md) | **Device identification & component inventory** — the paper recon that identifies the device and every part it is built from, from public and owner-held sources, *before* any teardown ([#9](https://github.com/Zaba505/embedded/issues/9)). |

## Status

| Story | State |
|---|---|
| [#9 steth-research](https://github.com/Zaba505/embedded/issues/9) — identify the device on paper | recon delivered → [`docs/recon.md`](docs/recon.md) |
| [#5 steth-teardown](https://github.com/Zaba505/embedded/issues/5) — schematic + debug port | not started (this recon de-risks it) |
| [#6 steth-pcb](https://github.com/Zaba505/embedded/issues/6) — functional-equivalent board | not started |
| [#7 steth-firmware](https://github.com/Zaba505/embedded/issues/7) — bare-metal Zig on the original board | not started |
