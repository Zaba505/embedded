# docs

Cross-project documentation for this repo. Per-project docs live with their project (e.g.
[`arduino-due/blinky/README.md`](../arduino-due/blinky/README.md)); this is for material that spans
projects or informs how they are built.

## Policy

| Document | What it is |
|---|---|
| [`fault-response-policy.md`](fault-response-policy.md) | An architecture-neutral template each project fills in to state its **safe state** and what a detected fault does — **halt / safe-state / reset** — with rationale. Firmware's safe failure state is per-device (halting is safe for an idle output, dangerous for an energized one), so this cannot be a repo-wide default; the template is the single source of truth for a project's assertion primitive and fault/exception handlers. `arduino-due/blinky` is the [worked instance](../arduino-due/blinky/fault-response-policy.md). |

## Research

| Document | What it is |
|---|---|
| [`research/tigerbeetle-for-embedded.md`](research/tigerbeetle-for-embedded.md) | A first-hand study of what [Tiger Style](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md) and [the VOPR](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/internals/vopr.md) (TigerBeetle's deterministic simulation testing) do and do not teach this repo's bare-metal work — classifying each idea as transfers-directly / transfers-modified / does-not-apply, and ending with a backlog of filable follow-up stories. |
