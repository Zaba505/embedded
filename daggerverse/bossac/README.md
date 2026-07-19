# bossac

Flash Atmel SAM microcontrollers over SAM-BA with [BOSSA](https://github.com/shumatech/BOSSA),
without installing a flashing tool on the host.

## Why this exists

`probe-rs` — and therefore [`z5labs/devex//daggerverse/flash`](https://github.com/z5labs/devex/tree/main/daggerverse/flash)
— speaks SWD/JTAG and needs a physical debug probe. A SAM device with no probe attached can still
be programmed through its **ROM-resident SAM-BA monitor** over an ordinary USB cable. That is what
this module does.

It is the no-probe path, not a replacement for one. SAM-BA is a flash programmer, not a debug
interface: no breakpoints, no halting, no memory inspection, no GDB. Those need a probe.

## bossac does not require USB/IP — this module does

Run bossac on a host and it simply opens `/dev/ttyACM0`. No usbip, no kernel modules, nothing.

USB/IP appears here purely because the tool runs **inside a container**. Dagger has no device
passthrough — `WithUnixSocket` is the only host-device mechanism it offers, and a serial port is not
a socket — so there is no lighter way to hand a board to a containerized process.

If that trade is not worth it for your use case, running bossac directly on the host is a perfectly
good answer, and this module has nothing to offer you. It exists for pipelines that need the
flashing tool to stay out of the host environment.

Note the asymmetry with `daggerverse/flash`: probe-rs speaks **raw USB**, so USB/IP is genuinely its
only in-container option. SAM-BA is a **byte stream**, so bossac is not stuck in the same way — what
rules out a lighter unix-socket bridge is that bossac's 1200-baud touch does not survive one,
leaving the operator to press ERASE and RESET by hand before every flash.

## Functions

| Function | Hardware needed | Purpose |
|---|---|---|
| `sam-ba` | no (builds the invocation) | Factory. Returns a flasher to chain a verb onto. |
| `sam-ba … plan` | **no** | Renders the exact commands. Safe in CI. |
| `sam-ba … info` | yes | `bossac --info`; confirms the board is reachable, writes nothing. |
| `sam-ba … run` | yes | Attaches and programs. |
| `bridge-command` | no | Prints the host-side USB/IP export command. |
| `tool-version` | no | Reports the bossac build in the container. |

## Usage

```sh
# 1. On the machine holding the board, as root. Load the modules first.
modprobe usbip-host vhci-hcd
usbip list -l                                  # find the busid
dagger -m daggerverse/bossac call bridge-command --busid 3-1
# -> usbipd -D --tcp-port '3240' && usbip bind --busid '3-1'

# 2. Dry run. No board required.
dagger -m daggerverse/bossac call sam-ba \
  --firmware ./firmware.bin --usbip 172.17.0.1:3240 --busid 3-1 \
  plan

# 3. Flash. Check exit-code, not just whether dagger succeeded.
dagger -m daggerverse/bossac call sam-ba \
  --firmware ./firmware.bin --usbip 172.17.0.1:3240 --busid 3-1 \
  run exit-code
```

`--firmware` is a **raw binary**, not an ELF — bossac has no ELF parser. Produce one with the zig
module's `obj-copy --format=binary`.

## Things that will bite you

- **A bossac failure is a non-zero `exit-code`, not a `dagger` error.** `run` returns
  `output` and `exit-code`; a `dagger call` that exits 0 does not mean the flash succeeded. A
  timeout surfaces as `124`.
- **`--usbip` must not be `127.0.0.1`.** Inside the container that is the container. Use an address
  the engine can route to — on Linux the Docker bridge gateway, typically `172.17.0.1`.
- **`usbip bind` takes the device away from the host.** `/dev/ttyACM0` disappears locally while it
  is exported. `usbip unbind --busid <id>` gives it back.
- **The engine must run privileged**, and the host needs the `usbip-host` and `vhci-hcd` kernel
  modules loaded. `usbip attach` drives `vhci_hcd` through sysfs, which an unprivileged exec cannot
  do; the module sets `InsecureRootCapabilities` on its exec for the same reason.
- **`--native-usb` selects which port speaks SAM-BA.** `false` (the default) means the monitor is
  reached over the chip's UART through an external USB-serial bridge — an Arduino Due's
  *Programming* port. `true` means the chip's own USB controller — the Due's *Native* port. Getting
  this backwards makes bossac fail to find the device.

## A note on bossac's argument parsing

`--boot` and `--usb-port` take *optional* arguments, so a space-separated `--usb-port 0` does not
bind: getopt leaves `0` as a positional, where bossac treats it as the input FILE. Arduino's own
`platform.txt` passes `-U false` and gets away with it only because a real filename follows on the
same line. This module always emits the attached `--flag=value` form, which is unambiguous.

## Upstreaming

Shaped deliberately close to `daggerverse/flash` — same USB/IP transport model, same
factory-then-verb chaining, same `output`/`exit-code` result — so it can move upstream without
redesign. That module already carries an unused `Backend` enum (`PROBE_RS`, `OPENOCD`, `ESPTOOL`,
`DFU_UTIL`), suggesting more backends were always anticipated.
