# readback

Write-then-verify (readback) helpers for peripheral register configuration. On
any memory-mapped target, after you configure a peripheral these helpers read
the corresponding status back and **assert the change took** — turning a write
that was silently dropped (a gated clock, a write-protected or wrong-address
register) into a caught failure instead of a bug that surfaces later, far from
its cause. Architecture-neutral, generic over the register width, and for the
**configuration phase, not hot paths**.

This is a follow-up from the
[TigerBeetle-for-embedded study](../../docs/research/tigerbeetle-for-embedded.md)
(issue [#15]), the reusable form of the pair-assertion pattern the
[Zig style guide][style-guide] describes in §5.5. Like everything under
[`lib/`](..), it is written to serve every future project in this repo, not one
board — the `arduino-due/blinky` firmware is cited as the current *example of
the shape*, never the definition.

## The problem

On a memory-mapped target a write to a control register can silently do nothing:

- the peripheral's clock is **gated** (the blinky's own comment: *"PIO writes are
  silently dropped while the controller's peripheral clock is gated"*),
- the register is **write-protected** or write-once,
- the **address is simply wrong** (*"a wrong address here is a silent no-op on
  real silicon, not a build error"*).

The language cannot hand you an error for any of these — the store returns
nothing and does nothing. This is firmware's dominant failure mode, and it is
not *a mishandled error*, it is **no error to handle**. So the discipline
(style guide §6.1) is to **manufacture the missing error first**, then handle it.

Tiger Style's *pair assertions* are how:

> "For every property you want to enforce, try to find at least two different
> code paths where an assertion can be added." — Tiger Style, §Safety

TigerBeetle pairs a write-side check with a read-side check around the disk.
Firmware's equivalent is **write-side / readback around a register**: after
configuring a peripheral, read the corresponding status back and assert it took.
The write path and the readback path are the two independent code paths, and the
gap between them is exactly where the silent no-op lives.

## Using it

The helpers are generic over an **asserter** — any namespace exposing
`pub inline fn assert(ok: bool) void`, which is exactly [`lib/assert`][lib-assert]'s
shape. Bind them once at the top of a driver:

```zig
const rb = @import("readback").Readback(@import("assert"));
```

Then, configuring a peripheral (using the blinky's SAM3X8E registers as the
worked example — the *shape*, not the definition):

```zig
// Ungate PIOB's clock, then confirm it actually came on BEFORE trusting any
// PIO write. PMC_PCER0 is write-only, so the readback is aimed at PMC_PCSR0, a
// separate status register — the canonical two-register pair.
rb.write_status_verify(PMC_PCER0, @as(u32, 1) << ID_PIOB, // write the enable
    PMC_PCSR0, @as(u32, 1) << ID_PIOB, // confirm via the status register
    @as(u32, 1) << ID_PIOB); //         mask: just this peripheral's bit

// Claim the pin and set it to output, confirming each write reads back.
rb.set_bits(PIOB_PER, LED); // PIO Enable
rb.set_bits(PIOB_OER, LED); // Output Enable
```

The `failure` a readback manufactures routes through the asserter you passed, so
what happens on a caught dropped-write — halt, drive-outputs-safe, reset — is the
project's [fault-response policy][fault-policy] (issue #12), never this package's
call. For a distinct route for config faults, pass an explicit asserter:

```zig
const asrt = @import("assert");
const rb = @import("readback").Readback(asrt.Assert(.{ .enabled = true, .onFailure = &safeThenHalt }));
```

### The helpers

| Helper | What it does |
|---|---|
| `verify(reg, expected, mask)` | Read `reg`, assert its `mask` bits equal `expected`'s. A bare readback, no write — for a config written elsewhere (e.g. a `SODR`/`CODR` pair) or a hardware-raised ready/locked bit. |
| `write_verify(reg, want)` | Write the whole word, assert **every** bit reads back. Strict form, for a register you fully own (no reserved / hardware / W1C bits). |
| `write_verify_masked(reg, want, mask)` | Write the whole word, assert only the `mask` bits read back. The everyday form; leave reserved and hardware-owned bits out of `mask`. |
| `write_status_verify(cfg, want, status, expected, mask)` | Write `want` to `cfg`, confirm via a **separate** `status` register. The headline case and the only valid shape for a write-only `cfg` (PMC_PCER0 → PMC_PCSR0). |
| `set_bits(reg, bits)` | Read-modify-write to set `bits`, assert they read back set. |
| `clear_bits(reg, bits)` | Read-modify-write to clear `bits`, assert they read back clear. |

## When readback is INVALID

Readback is **not free and not universal** (style guide §5.5, honest caveat).
Pointing a helper at the wrong kind of register *manufactures* a bug rather than
catching one, so this is the part to read before reaching for it:

- **Write-only registers.** A trigger/action register (a reset kick, a command
  port) reads back zero or garbage — there is nothing to confirm *there*. Verify
  via a separate status register with `write_status_verify`.
- **Read-to-clear / read-side-effect registers.** Reading some status registers
  *changes* them — an interrupt-status register that clears the bits it reports,
  or SysTick's `SYST_CSR`, whose `COUNTFLAG` clears on read. The blinky **relies**
  on that read to re-arm its poll; a readback there consumes the state you meant
  to observe. Never point a helper at one.
- **Bits hardware owns.** A busy flag, a live FIFO level, a free-running counter
  will not read back what you wrote. Confirm only *your* bits — pass a `mask`
  that excludes the hardware-owned ones.
- **Write-1-to-clear bits.** A `W1C` bit reads back 0 after a successful clear,
  not the 1 you wrote. Write the 1s directly and confirm with `verify(reg, 0,
  mask)`; do not RMW a `W1C` register (`clear_bits` would clear unrelated pending
  bits the read observed).

## Configuration phase, not hot paths

Every helper adds a `volatile` load and a compare, and `write_status_verify`
serializes against the peripheral. That is the right price to pay **once**,
while bringing a peripheral up, and the wrong price in an ISR or a sample loop.
Configure with these; run without them. (The masked-compare *branch* elides when
the asserter is disabled; the volatile load does not, because a `volatile` read
may itself have side effects — one more reason to keep these out of hot paths.)

## What the issue asks, point by point

The issue sets four acceptance criteria; each is answered here so a future
project can trust the helpers rather than re-derive them.

1. **Reusable write-then-verify helpers exist** — the six above, each a one-line
   pair assertion around a register poke.
2. **Architecture-neutral** — no CPU, peripheral, clock, address, or memory map
   appears in `readback.zig`. A helper takes a `*volatile` pointer the caller
   already has; the register width is read *off that pointer's type*, so the same
   code serves an 8-, 16-, or 32-bit register file on any target. A comptime
   check rejects a non-volatile or non-unsigned pointer with a build error. It
   compiles and unit-tests on the host — proof it assumes no particular silicon.
3. **The invalid cases are documented** — the section above, plus a doc comment
   on every helper naming where it must not be used, so the pattern is not
   misapplied.
4. **Configuration phase, not hot paths, and it says so** — stated in the module
   doc comment, per-helper, and the section above.

## Relationship to lib/assert

`readback` is the "manufacture the error" half; [`lib/assert`][lib-assert] is the
"handle it" half. readback finds a dropped write and asserts; assert branches,
once and cold, to the project's chosen safe state. readback takes the asserter as
a **parameter** rather than importing assert directly, so (a) each library stays
independently buildable through its own `--source` dir until a full-repo build
flow exists, and (b) the failure state stays the project's choice — readback
provides the mechanism and never the policy, the same contract assert holds.

## Relationship to the blinky

The blinky configures PMC and PIOB with plain writes (`PMC_PCER0.* = ...;
PIOB_PER.* = LED;`) and trusts them — correct for a blink whose only output is an
LED, where a dropped write just leaves the LED dark. These helpers are what that
same sequence looks like when a dropped write must be *caught* rather than merely
tolerated. The blinky is left untouched: it is the reference instance, and wiring
existing firmware to consume the module waits on a full-repo build flow (a later
follow-up); the module is proven here by its own host tests.

## Layout

| Path | What it is |
|---|---|
| [`readback.zig`](readback.zig) | The helpers: `Readback`, the six verify helpers, and host tests |
| [`build.zig`](build.zig) | Exports the `readback` module; the `test` step |
| [`build.zig.zon`](build.zig.zon) | Package manifest (name, Zig version pin) |

[#15]: https://github.com/Zaba505/embedded/issues/15
[lib-assert]: ../assert
[style-guide]: ../../docs/zig-style-guide.md
[fault-policy]: ../../docs/fault-response-policy.md
