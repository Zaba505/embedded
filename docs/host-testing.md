# Host testing

The repo-wide guide to what runs in the **host-test** gate — the shared CI step that compiles and
runs each project's target-independent logic natively, on the CI host, with no board attached. It is
architecture-neutral: a project contributes host tests whatever silicon it ships on.

Zig cross-compiles trivially, so any logic that does not touch a specific piece of hardware can be
built and run for the host regardless of the target. That makes host testing the cheapest rung on
the verification ladder — a build error or a failed assert surfaces on a developer's machine in
seconds, the [safest place for a correctness bug to appear](zig-style-guide.md#52-prefer-compile-time-assertions).
It is also the seam the host-side simulation story ([#8]) plugs into: the place where "runs on the
host" checks live, seeded today with the two free wins below.

## What runs

The gate (`dagger call host-test --source=.`, defined in the [`ci`](../ci) module) discovers every
`build.zig` that declares a step named `test` and runs `zig build test` for it. That one invocation
covers both seeded categories:

- **Compile-time invariant checks.** Compiling a test binary type-checks the code and evaluates
  every `comptime` block; a failed `comptime` assertion is a *build error*, not a runtime one. This
  is the [highest-value assertion class in the style guide](zig-style-guide.md#52-prefer-compile-time-assertions)
  — register widths, buffer sizes vs. region lengths, timer reloads vs. counter widths — checked for
  zero flash and zero cycles, here, before anything ships.
- **Pure-logic unit tests.** The `test { ... }` blocks: a bit-mask predicate, a field extraction, a
  state transition — anything whose correctness does not depend on real silicon. Because the tests
  compile the library, this doubles as the project's [strictest-diagnostics gate](zig-style-guide.md#24-strictest-compiler-diagnostics):
  Zig's would-be warnings are hard errors, and a `refAllDeclsRecursive` test forces even a `pub`
  decl no test calls through the compiler, so nothing ships un-checked.

## What host tests can and cannot prove

Host tests prove **target-independent logic is correct**. They prove nothing about the target
itself. The division is not a matter of effort — it is what the host *cannot observe*:

| Only on-hardware validation can prove | Why the host cannot |
|---|---|
| A peripheral register's reset value, or that a write to it took effect | There is no peripheral; the address is just memory. This is what [readback](../lib/readback) checks **on-target**. |
| An interrupt actually fires, at the priority and latency expected | No interrupt controller, no vector fetch — the host runs the logic straight through. |
| Timing margins: a loop meets its deadline, a bus settles before a read | Host wall-clock says nothing about the target's clock, pipeline, or wait states. |
| Electrical and I/O limits: a pin's level, current, or that a bus is terminated | Physical quantities with no software proxy. These live in the [resource budget](resource-budget.md). |
| The image boots at all: valid reset vectors, sane initial stack pointer | A host binary has none of this. The [image checker](../ci/imagecheck.go) asserts it statically, but only a board proves it by *not* hard-faulting on reset. |

The rule of thumb: if a check would give the same answer on any machine, it is a host test. If its
answer depends on the specific silicon — a register, a clock, a pin, a boot sequence — it needs the
board, and the host can at most check it *statically* (as the image checker does the boot vectors)
rather than *dynamically*.

## Logic that touches hardware: the seam is the prerequisite

The division above has a gap, and it is where most firmware lives: logic that is *conceptually*
target-independent — a debounce, a state machine, a protocol decoder — but that reaches out to a
peripheral to do its job. It cannot be host-tested as written, and the reason is structural rather
than a matter of effort:

```zig
const PIOB_SODR: *volatile u32 = @ptrFromInt(0x400E1030);
```

A host test cannot intercept a store to `0x400E1030`. The [research study][research] (§2.3) names
this the crux of the whole question: **the world — registers, timers, peripherals — must be injected
as a dependency rather than reached out to**, so a host build can substitute a stand-in. Nothing
else in host-side simulation is reachable until that is true.

[`lib/hal`](../lib/hal) ([#18]) is that seam, in reusable form: logic is written against a
**contract** — the operations a project needs to *do* — with a memory-mapped backend on target and a
host backend a test drives. It is `comptime`, so the indirection resolves at compile time and the
seam costs **0 bytes** of `.text` — measured on two architectures by the size gate
(`dagger call size-check --source=./lib/hal`), which is what makes it affordable on a flash budget.
That gate is the other half of the division of labour this document draws: code size is a claim
about generated machine code, so it is proven by weighing built images, never by a host test.

What that changes about this document:

- **It moves the line, it does not erase it.** Behind the seam, the logic becomes a host test —
  "one press produces exactly one toggle" is now provable without a board. The backend itself is
  still on the far side: whether `0x400E1030` is the right address, whether the write took, whether
  the clock was gated, all remain [things only hardware proves](#what-host-tests-can-and-cannot-prove).
  The seam covers *steady-state I/O*, not peripheral bring-up, which stays with
  [`lib/readback`](../lib/readback).
- **It is the prerequisite for the simulator ([#19]).** A seeded simulator is the same host backends
  driven from a PRNG on a schedule, with any failure reproducible from seed + commit. The fault
  knobs are already there (a wedged transmitter, dropped bytes); the seed and the schedule are that
  story's to add.
- **It is applied per project, not universally.** The seam is worth its structure where the logic is
  worth testing off-hardware — a state machine, a protocol, several fallible I/O paths. On trivial
  firmware it is pure overhead, which is exactly why `arduino-due/blinky` reaches out to its
  registers directly and should keep doing so.

## How a project contributes

Target-agnostic by construction, and self-registering: a project opts in by declaring a Zig build
step named `test` in its `build.zig` — the same step `zig build test` runs.

```zig
const tests = b.addTest(.{
    .root_source_file = b.path("mylib.zig"),
    .target = target, // host by default via b.standardTargetOptions
    .optimize = optimize,
});
const test_step = b.step("test", "Run mylib's unit tests");
test_step.dependOn(&b.addRunArtifact(tests).step);
```

There is no central list to edit and no change to the shared gate — onboarding a project's host
tests is a step in its own `build.zig`, exactly as onboarding the image checker is a `target.json`.
A project with nothing yet host-runnable — freestanding firmware such as
[`arduino-due/blinky`](../arduino-due/blinky), whose code is reachable only from the reset vector —
simply declares no `test` step and is not picked up; its compile-time coverage comes from its
`build` step instead. [`lib/assert`](../lib/assert), [`lib/readback`](../lib/readback) and
[`lib/hal`](../lib/hal) are the worked instances.

[#8]: https://github.com/Zaba505/embedded/issues/8
[#18]: https://github.com/Zaba505/embedded/issues/18
[#19]: https://github.com/Zaba505/embedded/issues/19
[research]: research/tigerbeetle-for-embedded.md
