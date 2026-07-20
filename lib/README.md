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

[#11]: https://github.com/Zaba505/embedded/issues/11
