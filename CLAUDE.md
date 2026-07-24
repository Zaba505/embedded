# CLAUDE.md

Guidance for Claude Code when working in this repository. These instructions apply to every project
here and override default behavior.

## Hardware first: design the electrical diagrams before writing any code

For every project in this repo, **hash out the overall hardware before beginning any coding.** The
electrical diagram(s) — the KiCad schematic(s) for the whole system: every board, the parts it
switches or senses, the power-and-ground plan, and the interconnects between boards — are the
**first deliverable**, committed and reviewed on their own.

When a project is broken into stories, **the first story defines the electrical diagram(s) only** —
no firmware, no build wiring, no code. The coding stories come after and **implement against those
diagrams** (citing the committed schematic for pin assignments, component values, and voltage/current
limits), extending them only to annotate a decision the diagram left open.

**Why.** The hardware — switching topology, voltage domains, per-pin current limits, default-safe
states — constrains everything the firmware can and must do, and it is far cheaper to get right on
paper than after code and a board exist. This is the same "bound every resource at design time"
discipline the repo's [resource budget](docs/resource-budget.md) and
[Tiger-Style research](docs/research/tigerbeetle-for-embedded.md) already apply to flash, RAM, and
timing — here extended to the electrical design and made the explicit first step.
