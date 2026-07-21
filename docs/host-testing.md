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
`build` step instead. [`lib/assert`](../lib/assert) and [`lib/readback`](../lib/readback) are the
worked instances.

[#8]: https://github.com/Zaba505/embedded/issues/8
