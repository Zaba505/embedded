# embedded

Home for various embedded projects that are not significant enough to get their own repo.

Projects are scoped by vendor, so boards from different families sit alongside each other cleanly.

## Projects

| Project | Board | Description |
|---|---|---|
| [`arduino-due/blinky`](arduino-due/blinky) | Arduino Due (Atmel SAM3X8E) | Bare-metal Zig blinky, built and flashed entirely through Dagger |
| [`smart-stethoscope`](smart-stethoscope) | Discontinued "smart" stethoscope (NXP Kinetis MK26) | Reverse-engineering a discontinued digital stethoscope for repair — a non-destructive [device recon](smart-stethoscope/docs/recon.md), then a [teardown & reconstructed KiCad schematic](smart-stethoscope/docs/teardown.md) with a datasheet-cited [debug-port map](smart-stethoscope/docs/debug-port.md) |

## Libraries

Cross-project, architecture-agnostic building blocks live in [`lib/`](lib):

| Library | Description |
|---|---|
| [`lib/assert`](lib/assert) | A flash-cheap assertion primitive: a failed assertion lowers to a bare trap, configurable on/off per project, with the safe failure state delegated to the project |

## Dagger modules

| Module | Description |
|---|---|
| [`daggerverse/bossac`](daggerverse/bossac) | Flash Atmel SAM MCUs over SAM-BA with bossac, no debug probe and no host-installed flashing tool |

## Docs

Cross-project documentation lives in [`docs/`](docs). Notably:

- [`docs/fault-response-policy.md`](docs/fault-response-policy.md) — an architecture-neutral
  template each project completes to declare its safe state and what a fault does (halt / safe-state
  / reset) with rationale, since firmware's safe failure state is per-device.
- [`docs/resource-budget.md`](docs/resource-budget.md) — an architecture-neutral template each
  project completes to bound its resources at design time (code footprint, working memory, timing,
  electrical / I/O limits, plus project-specific ones), re-deriving Tiger Style's back-of-the-envelope
  sketch for the resources that actually constrain firmware.
- [`docs/zig-style-guide.md`](docs/zig-style-guide.md) — the repo-wide Zig style guide every project
  inherits, derived from Tiger Style with bare-metal carve-outs. Architecture-neutral, and it marks
  which rules a tool enforces versus which are judgment.
- [`docs/research/tigerbeetle-for-embedded.md`](docs/research/tigerbeetle-for-embedded.md) — a study
  of what Tiger Style and TigerBeetle's deterministic simulation testing (the VOPR) transfer to this
  repo's bare-metal work, and the follow-up stories that research recommends.
