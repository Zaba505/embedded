# hal

A `comptime` **hardware-abstraction seam**: firmware logic talks to an *injected* representation of
its hardware instead of reaching out to fixed peripheral addresses, so the same logic builds for its
real target **and** for the host. Logic is written against a **contract** — the operations a project
needs to *do* — and a **backend** supplies them: [`mmio`](mmio.zig) for real silicon,
[`fake`](fake.zig) for a host test. The two are interchangeable, and the seam costs **zero bytes** of
code on target, measured on two architectures.

This is the follow-up from the [TigerBeetle-for-embedded study][research] (issue [#18]), the
prerequisite the host-testing and simulation work is blocked on. Like everything under
[`lib/`](..) it is written to serve every future project in this repo on any architecture — the
Arduino Due's SAM3X8E and the Raspberry Pi 3B's BCM2837 are cited as the current *examples of the
shape*, never the definition.

## The problem

Deterministic host testing needs one structural property: **the logic must talk to an injected
world.** The [blinky](../../arduino-due/blinky) is the counter-example, deliberately so —

```zig
const PIOB_SODR: *volatile u32 = @ptrFromInt(0x400E1030);
```

— and a host test cannot intercept a store to `0x400E1030`. The research study names this the crux
of the whole simulation question:

> "The 'world' (registers, timers, peripherals) must be injected as a dependency rather than reached
> out to, so a host build can substitute a simulated world. […] Nothing else in DST is reachable
> until it exists." — [`docs/research/tigerbeetle-for-embedded.md`][research] §2.3

The usual objection to a HAL is what it costs: a vtable-driven abstraction charges an indirect call
and a pointer per operation, which is precisely the rent a firmware flash budget cannot pay. Zig's
`comptime` removes the objection — the backend is a **type**, not a value, so every call through the
seam resolves at compile time to the backend's own inlined body.

## Using it

Three steps: pick the backends for the build, bind the seam to them, and write the logic against the
seam.

```zig
const builtin = @import("builtin");
const hal = @import("hal");

// 1. The backends. On target, memory-mapped; on the host, the stand-ins.
//    Addresses and masks come from the project's own chip constants and its
//    committed electrical diagram -- this package names no board.
const GateBackend = if (builtin.os.tag == .freestanding)
    hal.mmio.SetClearOutput(.{
        .set = PIOB_SODR, .clear = PIOB_CODR, .state = PIOB_ODSR, .mask = GATE,
    })
else
    hal.fake.Output;

// 2. The seam, bound to it. `hal.DigitalOut` verifies the backend against the
//    `digital_out` contract here, so a mismatch is a build error naming the
//    contract rather than an error inside the wrapper.
const Gate = hal.DigitalOut(GateBackend);

// 3. The logic, which never learns which backend it got.
fn on_switch_pressed(gate: *Gate) void {
    gate.toggle();
}
```

The host test drives the same logic through the fake and asserts on what it saw:

```zig
test "a press toggles the light" {
    var gate = hal.DigitalOut(hal.fake.Output).init(.{});
    on_switch_pressed(&gate);
    try std.testing.expectEqual(hal.Level.high, gate.driven());
    try std.testing.expectEqual(@as(u32, 1), gate.backend.transitions);
}
```

### The contracts

Four, chosen because they are what a project needs to *do* — not because a peripheral has them.
Each is satisfiable on every architecture surveyed, and a project needing a fifth (an ADC read, an
I²C transfer) declares its own: `hal.Contract` is public for exactly that.

| Contract | A backend provides | The wrapper adds |
|---|---|---|
| `digital_out` | `write(Level)`, `driven() Level` | `drive_high`, `drive_low`, `toggle` |
| `digital_in` | `read() Level` | `is_active` |
| `serial` | `try_write(u8) bool`, `try_read() ?u8` | `write_some`, `read_some` (bounded, non-blocking) |
| `clock` | `ticks() u32`, `ticks_hz`, `ticks_bits` | `elapsed_since` (wrap-safe), `ticks_for_ms`, `has_elapsed_ms` |

Two properties worth stating outright, because they are what keeps the wiring out of the logic:

- **Levels are logical, not electrical.** The backend applies the pin's polarity, so an active-low
  switch — pulled up, closed to ground, the arrangement a schematic normally fixes — reads `.high`
  when pressed. The logic asks "is it pressed", never "is it 0".
- **Nothing blocks.** `try_write`/`try_read` report not-ready and return. A spin inside the seam
  would be a loop the caller cannot bound ([style guide][style-guide] §4.2) and, on the host, a hang
  indistinguishable from a deadlock.

### The backends

**Real** ([`mmio.zig`](mmio.zig)) — parameterized by the *shape* of a register interface, never by a
board, which is what lets one backend serve several architectures:

| Backend | Shape | Instances of that shape |
|---|---|---|
| `SetClearOutput` | write-1-to-set / write-1-to-clear pair + a state register | Atmel `PIO_SODR`/`PIO_CODR`/`PIO_ODSR`; Broadcom `GPSET0`/`GPCLR0`/`GPLEV0` |
| `DataRegisterOutput` | one read-modify-write data register | a port with no set/clear pair |
| `LevelInput` | a pin-level register + a mask + a polarity | Atmel `PIO_PDSR`; Broadcom `GPLEV0` |
| `PolledSerial` | a status register + a data register each way, each ready bit with a **sense** | Atmel USART (`TXRDY` ready when **set**); ARM PL011 (`TXFF` ready when **clear**) |
| `FreeRunningCounter` | a counter register + a rate + a width + a direction | Atmel `TC_CV`; Broadcom system timer `CLO`; ARM `SYST_CVR` (24-bit, counts down) |

Register pointers are `*volatile u32` **comptime parameters**, exactly as [`lib/readback`][readback]
takes the pointer the caller already has. So on target the backend is zero-sized and free — and on
the host the *same* backend binds to a plain container-level `var`, whose address is comptime-known
too, which is how `mmio.zig`'s own bit arithmetic and polarity handling are unit-tested.

**Host** ([`fake.zig`](fake.zig)) — the stand-ins a test drives, adding the two things a register
cannot give a host: **observability** (`Output.transitions`, `Input.reads`, `Serial.sent()`) and
**control** (`Input.level`, `Serial.tx_ready`, `Serial.drop_writes`, `Counter.advance_ms`). All
bounded and allocation-free (style guide §7.1), and all deterministic — nothing here reads a clock,
a random number, or the environment.

## What is on which side of the seam

The seam covers **steady-state I/O**, not **bring-up**, and the split is deliberate:

| Behind the seam | Not behind the seam |
|---|---|
| Drive the gate, sample the switch, move a byte, read the counter | Ungate a peripheral clock, mux a pin, program a baud divisor, set a timer prescaler |
| Happens continuously, is what the logic *does*, is what a test must intercept | Happens once at init, is intensely chip-specific, is where a write is silently dropped |
| Fake it with `hal.fake` | Verify it with [`lib/readback`][readback] — write, then read back and assert it took |

Putting bring-up behind the seam would mean modelling one chip's clock tree in a "portable"
interface — which is how a HAL turns into the vendor's HAL. A backend here assumes it is handed a
peripheral that is already alive.

## Evidence: the seam is free

[`bench/`](bench) builds the **same logic twice** — [`seam.zig`](bench/seam.zig) through the seam,
[`direct.zig`](bench/direct.zig) as hand-written register pokes in the blinky's style — for **two
architectures**, at `ReleaseSmall`. Both roots read their addresses and masks from
[`chip.zig`](bench/chip.zig), so the `.text` difference is the seam and nothing else. The logic is
small but has real data-dependent control flow (a debounced input, a toggled output, a command read
off a link, a report written back), because an abstraction's cost shows up in branches and reloads,
not in straight-line stores.

```
lib/hal -- the hardware-abstraction seam costs nothing
  step=bench  optimize=ReleaseSmall  section=.text

  cortex-m3  (thumb, SAM3X8E)    direct-cortex-m3    198 B  ->  seam-cortex-m3    198 B   delta +0 B = 0.0 B/architecture  (max 0)
  cortex-a53 (aarch64, BCM2837)  direct-cortex-a53   296 B  ->  seam-cortex-a53   296 B   delta +0 B = 0.0 B/architecture  (max 0)

OK: 2 measurement(s) within budget; the hardware-abstraction seam costs nothing.
```

Not merely equal in size: on both targets the two roots compile to a **byte-identical instruction
stream**. Reproduce it, from the repository root, with the single command CI runs:

```
dagger call size-check --source=./lib/hal
```

The budget — 0 bytes per architecture — and the image pairs it compares live in
[`bench/size-budget.json`](bench/size-budget.json); the gate itself is the `ci` module's shared
`size-check` function, the same one [`lib/assert`][assert] holds its per-assertion cost to.

> **The gate has already earned its keep.** `Level` began as `enum(u1)` — the width the values
> actually need — and cost 56 bytes of `.text` on Cortex-M3 and 68 on Cortex-A53. A one-bit value
> has a one-*byte* memory representation, so every level handed between two inlined functions became
> an `i1` store followed by an `i8` load through a stack slot, which the optimizer cannot forward
> and did not delete. Widening the tag to `u8` made the types agree and the cost vanish. Nothing in
> the source hints at this; only measuring found it.

## What this package deliberately does not do

1. **It does not model one board's register map.** A contract names what the logic needs to do. The
   same four are satisfied by an Atmel PIO and a Broadcom GPIO block, by an Atmel USART and an ARM
   PL011 whose ready bits have *opposite senses*.
2. **It does not do peripheral bring-up** — see the table above.
3. **It does not choose the failure state, or assert on the caller's behalf.** Like
   [`lib/assert`][assert] and [`lib/readback`][readback] it is mechanism, never policy: it takes no
   asserter and traps nowhere, so the halt-vs-safe-state-vs-reset decision stays the project's
   ([#12], [`fault-response-policy.md`][fault-policy]).
4. **It does not inject faults or generate randomness.** `fake` exposes deterministic, test-set
   knobs. Driving them from a seeded PRNG, on a schedule, reproducible from seed + commit, is the
   seeded simulator's job ([#19]) — built *on* this seam, not inside it.

## What the issue asks, point by point

| Acceptance criterion | Where it is met |
|---|---|
| Logic builds for both its real target and the host | `bench/seam.zig` builds for two freestanding targets; the same wrappers and the `fake` backends build and run on the host in `zig build test` |
| Real and host backends interchangeable behind one interface | `hal.zig`'s "an mmio backend and a fake backend are interchangeable" test runs one generic routine over both, asserting the same observable outcome; every backend in this package is asserted to `conform`, and a backend that does not is asserted *not* to |
| Runtime-free via `comptime`, verified against code size | `dagger call size-check --source=./lib/hal`: 0 bytes on Cortex-M3 and Cortex-A53, byte-identical instruction streams, gated in CI |
| Architecture-neutral, documented as the prerequisite for host testing / simulation | No CPU, peripheral or address appears in `hal.zig`; the backends are parameterized by register shape and proven on two architectures; [`docs/host-testing.md`][host-testing] records the seam as the prerequisite |
| Applied to a project whose logic warrants it | **Not yet, and deliberately.** See below. |

### The last criterion, honestly

The project that warrants the seam is the **smart light** — the repo's first genuinely stateful
system, with a wall switch and a remote both able to change one load over a link that drops bytes.
Its state-machine story ([#35]) is explicitly the place this pattern lands, and its firmware cannot
be written yet: under the hardware-first rule ([`CLAUDE.md`](../../CLAUDE.md)) the electrical
diagrams ([#31]) come first, and they are not committed. Applying the seam to the
[blinky](../../arduino-due/blinky) instead is exactly what the issue rules out — "not retrofitted
onto trivial firmware where the seam would be pure overhead."

So what ships here is the mechanism, proven on its own: unit-tested on the host, and compiled
against two real architectures' register shapes in `bench/`, which is a working consumer even though
it is not a project. Wiring it into `smart-light/` follows the diagrams.

## Relationship to the other libraries

| | Its half of the job |
|---|---|
| [`lib/hal`](.) | **Intercept** the hardware, so the logic can run somewhere else |
| [`lib/readback`][readback] | **Manufacture** the error a silently-dropped config write does not signal |
| [`lib/assert`][assert] | **Handle** it — branch, once and cold, to the project's safe state |

Each takes what it needs as a parameter rather than importing the others, so every library stays
independently buildable through its own `--source` dir until a full-repo build flow exists — and so
no library decides another's policy.

## Layout

| Path | What it is |
|---|---|
| [`hal.zig`](hal.zig) | The seam: `Level`, the contract machinery (`Contract`/`verify`/`conforms`), the four contracts, the four wrappers, host tests |
| [`mmio.zig`](mmio.zig) | Memory-mapped backends, parameterized by register shape, plus their host tests |
| [`fake.zig`](fake.zig) | Host backends: observable, controllable, bounded, deterministic |
| [`bench/`](bench) | The size evidence: identical logic through the seam and by hand, two architectures, plus `size-budget.json` (what the CI gate holds them to) |
| [`build.zig`](build.zig) | Exports the `hal` module; the `test` step and the `bench` step |
| [`build.zig.zon`](build.zig.zon) | Package manifest (name, Zig version pin) |

[#12]: https://github.com/Zaba505/embedded/issues/12
[#18]: https://github.com/Zaba505/embedded/issues/18
[#19]: https://github.com/Zaba505/embedded/issues/19
[#31]: https://github.com/Zaba505/embedded/issues/31
[#35]: https://github.com/Zaba505/embedded/issues/35
[assert]: ../assert
[readback]: ../readback
[research]: ../../docs/research/tigerbeetle-for-embedded.md
[style-guide]: ../../docs/zig-style-guide.md
[fault-policy]: ../../docs/fault-response-policy.md
[host-testing]: ../../docs/host-testing.md
