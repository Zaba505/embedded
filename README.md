# embedded

Home for various embedded projects that are not significant enough to get their own repo.

Projects are scoped by vendor, so boards from different families sit alongside each other cleanly.

## Projects

| Project | Board | Description |
|---|---|---|
| [`arduino-due/blinky`](arduino-due/blinky) | Arduino Due (Atmel SAM3X8E) | Bare-metal Zig blinky, built and flashed entirely through Dagger |

## Dagger modules

| Module | Description |
|---|---|
| [`daggerverse/bossac`](daggerverse/bossac) | Flash Atmel SAM MCUs over SAM-BA with bossac, no debug probe and no host-installed flashing tool |

## Docs

Cross-project documentation lives in [`docs/`](docs). Notably:

- [`docs/fault-response-policy.md`](docs/fault-response-policy.md) — an architecture-neutral
  template each project completes to declare its safe state and what a fault does (halt / safe-state
  / reset) with rationale, since firmware's safe failure state is per-device.
- [`docs/research/tigerbeetle-for-embedded.md`](docs/research/tigerbeetle-for-embedded.md) — a study
  of what Tiger Style and TigerBeetle's deterministic simulation testing (the VOPR) transfer to this
  repo's bare-metal work, and the follow-up stories that research recommends.
