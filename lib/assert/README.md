# assert

A flash-cheap assertion primitive for freestanding targets. A failed assertion
branches, once and cold, to a project-chosen failure state — no message, no
formatting, no stack walk, no panic machinery — so an assertion costs a few
instructions and Tiger Style's "assert liberally, keep them on in production"
becomes affordable on a target with a tight code budget, on any architecture.

This is the first implementation follow-up from the
[TigerBeetle-for-embedded study](../../docs/research/tigerbeetle-for-embedded.md)
(issue [#11]); it is rung 2 of that study's staircase (§2.7). It is written to
serve every future project in this repo, not one board — the `arduino-due/blinky`
firmware is the current *example of the shape*, not the definition.

## The problem

Tiger Style asks for two assertions per function on average, checking arguments,
return values, pre/postconditions and invariants, and it keeps them on **even in
optimized production builds** — because "the only correct way to handle corrupt
code is to crash. Assertions downgrade catastrophic correctness bugs into
liveness bugs."

On a hosted target that is affordable: a failed `std.debug.assert` reaches
`std.debug.panic`, and the machinery behind it (message formatting, a stack
walk) is already linked in. On the bare-metal targets this repo builds for it is
not. The blinky's own comments spell out why it had to delete Zig's default
panic path:

> Replaces Zig's default panic handler, which drags in message formatting and
> stack-trace walking — hundreds of kilobytes that will not fit in 256K of
> flash, for output nothing here could display anyway.

So the density guidance is simply unaffordable with the stock primitive. Worse,
the usual escape hatch is a trap of its own: `std.debug.assert(x)` lowers to
`if (!x) unreachable`, and `unreachable` in `ReleaseFast`/`ReleaseSmall` is
*undefined behavior* — the check is deleted **and** the optimizer is then free
to assume the condition held. So with stock Zig you get, in optimized builds,
either the panic machinery (too big) or no checked assertion at all (unsafe).
Neither lets you "keep them on in production" on this hardware.

This package is the missing middle: a **checked** assertion in every optimize
mode whose failure path is a bare trap.

## Using it

Most code uses the default asserter, wired from two optional declarations in the
project's **root source file** (the one passed to `addExecutable`):

```zig
const assert = @import("assert").assert;

// Optional: the per-project safe state a failed assertion lands in. Absent
// this, assertions trap. This is the halt/safe-state/reset policy of issue #12.
pub fn onAssertionFailure() noreturn {
    // e.g. the blinky's choice: stop, never reset.
    while (true) {}
}

// Optional: turn assertions off for this project. Absent this, they are on in
// every optimize mode, ReleaseSmall included.
// pub const assertions_enabled = false;

fn read(buf: []u8, index: usize) u8 {
    assert(index < buf.len); // a bare-trap branch when it fails
    return buf[index];
}
```

For the cases that need more than one failure route — say a distinct one for
assertions inside an interrupt handler — build an explicit asserter instead:

```zig
const asrt = @import("assert");

const isr = asrt.Assert(.{ .enabled = true, .onFailure = &driveOutputsSafeThenHalt });
// isr.assert(...) uses that route; the top-level assert() still uses the default.
```

## What the issue asks, point by point

The issue sets five acceptance criteria. Each is answered here, with the
reasoning, so a future project can trust the primitive rather than re-derive it.

### 1. It compiles to a bare trap — measured

`bench/` builds four freestanding images for a real MCU target (Cortex-M3,
`thumb-freestanding-eabi`) at `ReleaseSmall`. Two matched pairs each differ
*only* in whether their assertions are compiled in, so the `.text` delta is the
cost of the assertions and nothing else:

| image | assertions | `.text` |
|---|---|---|
| `off8`  | 8, disabled  | 70 B  |
| `on8`   | 8, enabled   | 138 B |
| `off16` | 16, disabled | 102 B |
| `on16`  | 16, enabled  | 278 B |

- `(on8 − off8) / 8` = **8 bytes per assertion**
- `(on16 − off16) / 16` = **11 bytes per assertion**

A handful of bytes each — a compare and a cold branch to a shared trap site —
and flat as the count grows. If a failed assertion pulled in formatting, an
unwinder, or panic plumbing, this would be hundreds of bytes to kilobytes, and
the two figures would not agree. Reproduce it with:

```
./bench/measure.sh
```

which prints the table and **exits non-zero if the per-assertion cost exceeds a
threshold** (default 32 bytes). CI runs that same script as the
"Assert an assertion compiles to a bare trap" gate — a negative-space check over
the built image, in the spirit of the firmware's "Assert the reset vectors are
sane" step.

### 2. Behavior in optimized / size-optimized builds: on by default, configurable

The default is **on in every optimize mode, `ReleaseSmall` and `ReleaseFast`
included**. That is deliberate: keeping assertions on in production is the whole
point, and it is affordable precisely because criterion 1 holds. Because the
failure path is an explicit branch to a `noreturn` handler (not `unreachable`),
the check stays real in the release-fast/small modes where stock `assert` would
become undefined behavior.

A project overrides the default by declaring, in its root source file:

```zig
pub const assertions_enabled = false; // compile every assert() out to nothing
```

When disabled, an `assert` call is *nothing* — not a predicted-untaken branch,
no code at all (see the `off*` images above, which contain no trap). The knob is
a plain `bool`, so a project can drive it from a build option, an optimize-mode
check, or a constant, whatever suits it — this package does not impose a policy,
it exposes the switch.

### 3. Behavior inside an interrupt / exception context

The primitive is **safe to call from any context, including an ISR or a fault
handler**: it allocates nothing, takes no lock, and unwinds nothing — a failed
assertion is a compare and a branch. So the mechanism never wedges an interrupt
context on its own.

What a failure *should do* in interrupt context is a policy question, and it is
delegated (criterion 4). Halting inside an ISR can be exactly right (the blinky
wires its unused SysTick vector to a trap so a spurious interrupt stops the board
visibly) or exactly wrong (halting with other interrupts masked can wedge a
system that had a safer option). A project that needs context-aware failure
encodes it in its own `onAssertionFailure` — including querying whether it is in
an exception, which is inherently architecture-specific (ARM reads `IPSR`; other
cores have no such register). This package deliberately does **not** detect
interrupt context itself, because doing so would bake an architecture in and
break criterion 5.

### 4. The failure state is delegated, not hardcoded

"Crash on corrupt state" has one universal answer on a server — every process
exits into the same benign place — and no universal answer on bare metal:
halting is safe where the worst outcome is an idle output and dangerous where it
holds a motor or heater energized; a reset is right only where a clean restart
beats a wedge. The safe state is a property of the *device*, so this file cannot
know it.

It is chosen via `Config.onFailure` (or the `onAssertionFailure` root
declaration), a `noreturn` handler the project supplies. Absent one, the default
is the most portable defined failure state there is: `@trap()`, which faults the
core deterministically. Note the default is a *trap*, not a hardcoded halt loop —
the halt/safe-state/reset decision belongs to the per-project **assertion & fault
policy** of issue [#12], for which this primitive is the mechanism.

### 5. Nothing in the API assumes a CPU, peripheral, clock, or memory map

The only hardware fact the primitive relies on is `@trap()`, which the compiler
lowers to whatever "stop, something is wrong" instruction the target has (`udf`
on ARM, `unimp`/`ebreak` on RISC-V, and so on). There is no register, no address,
no clock, no linker symbol anywhere in `assert.zig`. It compiles for the host,
which is how its logic is unit-tested (`zig build test`) — the clearest possible
proof that it assumes no particular silicon. It even runs before C-runtime init,
since a failed assertion touches no initialized global.

## Relationship to the blinky

The blinky's hand-written `panic` and `defaultHandler` — each a bare
`while (true) {}` — are the shape this primitive generalizes: a correctness bug
downgraded to a stopped LED, with no formatting in sight. This package turns that
one-off into a reusable, architecture-neutral mechanism with the on/off knob and
the delegated failure state the blinky never needed to name. The blinky is left
untouched: it is the reference instance, and wiring existing firmware to consume
the module waits on a full-repo build flow (a later follow-up); the module is
proven here by its own tests and the on-target size gate.

## Layout

| Path | What it is |
|---|---|
| [`assert.zig`](assert.zig) | The primitive: `Config`, `Assert`, the default asserter, and host tests |
| [`build.zig`](build.zig) | Exports the `assert` module; `test` and `bench` steps |
| [`build.zig.zon`](build.zig.zon) | Package manifest (name, Zig version pin) |
| [`bench/`](bench) | The size-delta benchmark and `measure.sh`, the evidence for criterion 1 |

[#11]: https://github.com/Zaba505/embedded/issues/11
[#12]: https://github.com/Zaba505/embedded/issues/12
