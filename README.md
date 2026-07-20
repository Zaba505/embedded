# embedded

Home for various embedded projects that are not significant enough to get their own repo.

Projects are scoped by vendor, so boards from different families sit alongside each other cleanly.

## Projects

| Project | Board | Description |
|---|---|---|
| [`arduino-due/blinky`](arduino-due/blinky) | Arduino Due (Atmel SAM3X8E) | Bare-metal Zig blinky, built and flashed entirely through Dagger |
| [`smart-stethoscope`](smart-stethoscope) | Discontinued "smart" stethoscope (NXP Kinetis MK26) | Reverse-engineering a discontinued digital stethoscope for repair — starting with a non-destructive [device recon & component inventory](smart-stethoscope/docs/recon.md) |

## Dagger modules

| Module | Description |
|---|---|
| [`daggerverse/bossac`](daggerverse/bossac) | Flash Atmel SAM MCUs over SAM-BA with bossac, no debug probe and no host-installed flashing tool |
