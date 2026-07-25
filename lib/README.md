# lib

Shared, reusable libraries for this repo's projects. Unlike the per-vendor
projects (e.g. [`arduino-due/blinky`](../arduino-due/blinky)), which target one
board, everything here is written to serve **every** project on **any**
architecture — the code assumes no particular CPU, peripheral, clock, or memory
map, and says so where it matters.

Each library is a self-contained Zig package (its own `build.zig` /
`build.zig.zon`) so it builds and tests in isolation through the same pinned
`zig` Dagger module the firmware uses, and can be depended on as a module once a
full-repo build flow exists.

## Libraries

| Library | What it is |
|---|---|
| [`assert`](assert) | A flash-cheap assertion primitive: a failed assertion lowers to a bare trap (no formatting/unwind/panic machinery), configurable on/off per project, with the safe failure state delegated to the project. Follow-up [#11] from the [TigerBeetle-for-embedded study](../docs/research/tigerbeetle-for-embedded.md). |
| [`readback`](readback) | Write-then-verify (pair-assertion) helpers for peripheral register configuration: after a config write, read the status back and assert the change took, catching a silently-dropped write (gated clock, write-protected or wrong-address register). Architecture-neutral, delegates the failure state to an asserter (`lib/assert`), and is for the config phase, not hot paths. Follow-up [#15]. |
| [`hal`](hal) | A `comptime` hardware-abstraction seam: logic talks to an *injected* representation of its hardware — a contract with a memory-mapped backend and a host backend — so the same code builds for its target and for the host. Backends are parameterized by register *shape*, not by a board, and the seam costs **0 bytes** of `.text` (measured on Cortex-M3 and Cortex-A53). The prerequisite for host-side testing and simulation. Follow-up [#18]. |

[#11]: https://github.com/Zaba505/embedded/issues/11
[#15]: https://github.com/Zaba505/embedded/issues/15
[#18]: https://github.com/Zaba505/embedded/issues/18
