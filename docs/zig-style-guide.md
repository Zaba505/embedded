# Zig Style Guide

*The repo-wide rules for firmware in this repo, derived from [Tiger Style][tiger-style] and filtered
through the [TigerBeetle-for-embedded study][research]. One place to inherit from, so no project
re-derives them.*

Every project here writes bare-metal Zig for some target — Cortex-M today, whatever comes next
tomorrow. This guide is the shared floor: the naming, control-flow, and assertion discipline every
one of them starts from. It is deliberately **architecture-neutral**. Where a rule has a
hardware-dependent nuance, the nuance is stated as a general principle with an example, never as a
rule for one board.

> The Go Dagger modules under [`daggerverse/`](../daggerverse) follow Go conventions and are
> **out of scope**. This guide governs the Zig firmware.

## How to read this guide

**Say why applies to the guide too.** Every rule below states its reason. If a rule's reason does
not hold for your project, that is a conversation to have in review — not a rule to ignore silently.

**Enforcement — the distinction that matters most.** Each rule is tagged one of two ways:

- **`[mechanical]`** — a tool decides pass/fail (the formatter, a compiler flag, a line-length gate,
  a host-side artifact checker). The mechanical subset is what the **[CI story (#14)][issue-14]**
  wires into the shared pipeline, so violations fail the build rather than waiting for a reviewer.
  A rule can be mechanical *in principle* yet have no tool wired yet; the [enforcement
  summary](#enforcement-summary) records the status of each.
- **`[judgment]`** — no tool reliably decides it. It lives in code review and in the author's
  discipline: whether a name is clear, whether a function does one thing, what a device's safe
  failure state is.

**The reference instance, not the definition.** This repo will hold projects across many targets, so
each rule is stated *generally*. Today the only worked example is
[`arduino-due/blinky`](../arduino-due/blinky) — a bare-metal Zig blinky for the Atmel SAM3X8E. It is
cited throughout as *the current example of the shape*, never as the definition. When a rule says
"e.g. the blinky…", read it as one instance of a general principle.

> **One honest caveat up front.** The blinky was written ([#3][issue-3]) before this guide existed,
> and a few function names (`waitHalfPeriod`, `resetHandler`, `defaultHandler`) use camelCase,
> which [§1.1](#11-snake_case-names) rules against. That drift predates the guide; reconciling it is
> a small follow-up, noted where relevant, not a reason to weaken the rule.

---

## 1. Naming and clarity

### 1.1 snake_case names

**`[judgment]`** — Use `snake_case` for function, variable, and file names; `TitleCase` for types.
Tiger Style: *"Use `snake_case` for function, variable, and file names,"* and it deliberately
diverges from Zig's own camelCase-function convention to do so. We follow Tiger Style here for
consistency with the doctrine this repo is built on. *Why judgment:* `zig fmt` does not check
identifier case, so until a linter does (a candidate for a future CI rung), this is a review rule.

> The blinky's camelCase function names predate this guide (see the caveat above) and should migrate
> to `snake_case` — e.g. `wait_half_period`, `reset_handler`, `default_handler`. The names are
> internal Zig symbols; the vector table binds by linker section, not by name, so renaming is free.

### 1.2 No abbreviations

**`[judgment]`** — Spell names out. Tiger Style's one exception — a primitive integer index in a
sort or matrix loop (`i`, `j`) — is the only place a short name earns its keep. A firmware register
name already carries its datasheet abbreviation (`PMC_PCER0`); that is the vendor's spelling
kept verbatim on purpose (§8.1), not an abbreviation you invented.

### 1.3 Units and qualifiers last

**`[judgment]`** — Put units and qualifiers at the *end* of a name, sorted by descending
significance, so the name reads most-significant-word first: `latency_ms_max`, not `max_latency_ms`.
The blinky already mirrors this in `HALF_PERIOD_TICKS` (the quantity, then its unit). On firmware
this doubles as a correctness aid: a name that carries its unit (`_ms`, `_ticks`, `_hz`) is a name
you cannot silently mix with a different unit.

### 1.4 Proper acronym capitalization

**`[judgment]`** — Capitalize acronyms as acronyms: `VSRState`, not `VsrState`; a hypothetical
`I2CBus`, not `I2cBus`. Firmware is dense with them (SPI, PIO, ADC, DMA), so pick this once.

### 1.5 `index`, `count`, and `size` are distinct

**`[judgment]`** — Treat `index` (0-based), `count` (1-based), and `size` (bytes) as distinct types
even though they are all integers, and convert between them deliberately. Show division intent with
`@divExact` / `@divFloor` / `div_ceil` rather than bare `/`, so the reader knows you considered the
remainder. This is where off-by-one bugs breed, and firmware pays for them in silent memory
corruption rather than an exception.

### 1.6 State invariants positively

**`[judgment]`** — Prefer the positive form of a condition: `if (index < length)` over
`if (index >= length)` when the positive space is what you mean. Positive conditions are easier to
read and to get right, and they compose with the positive/negative-space assertion rule (§5.6).

### 1.7 Always say why

**`[judgment]`** — *"Always motivate, always say why. Never forget to say why."* A comment that says
*what* the code does is noise next to the code; a comment that says *why* is the one thing the code
cannot say for itself. This carries extra weight on bare metal, where the reason is often a hardware
fact invisible in the source — *"PIO writes are silently dropped while the peripheral clock is
gated,"* *"`WDT_MR` is write-once."* The blinky's comment density is the standard to match: every
register poke carries its rationale.

---

## 2. Formatting — the mechanical core

This section is where "mechanical" is literal: a tool already decides most of it, and the
[CI story (#14)][issue-14] wires the rest into the shared pipeline.

### 2.1 `zig fmt`

**`[mechanical]`** — Code is formatted by `zig fmt`, checked (never rewritten) in CI. This is
**enforced today**: `ci.yaml` runs `zig fmt --check` for the blinky, and the shared pipeline runs it
for every project. `zig fmt` also settles 4-space indentation and brace placement, so those need no
separate rule.

### 2.2 100-column hard limit

**`[mechanical]`** — Hard-wrap every line — code *and* prose — at 100 columns, for a readable
typographic measure. `zig fmt` does not enforce line length, so this is a separate gate, now
**enforced**: the `line-length` function on the repo's top-level `ci` Dagger module
([`ci/main.go`][check-line-length]) runs in the shared pipeline (`ci.yaml`) as a single repo-wide
pass over every tracked Zig and Markdown file, so the limit applies to every project uniformly, not
one board. It is the same function a developer runs locally: `dagger call line-length --source=.`.

Two details, because a naïve check gets them wrong:

- **Columns are characters, not bytes.** The prose here is full of em-dashes and curly quotes, each
  one column but several UTF-8 bytes; a byte-based check (`wc -c`, bash `${#s}`) would false-positive
  on every such line. The gate counts Unicode characters.
- **Three exemptions, each because the line genuinely cannot be wrapped shorter:** Markdown table
  rows (cannot wrap), fenced code blocks (a shell command may have no safe break point), and an
  *unbreakable tail* — a line whose overflow past column 100 is a single long token such as a URL,
  with nowhere after the limit to break. This matches `markdownlint` MD013's default lenience, so a
  line a column or two over that ends mid-word also slips through: **still target 100** when you
  write. The gate catches the real defect — breakable content left running past the limit — not
  every last column. The Go modules under `daggerverse/` are out of scope (see the intro) and are
  not scanned.

### 2.3 Braces on `if`

**`[mechanical]`** — Add braces to an `if` unless the statement fits on one line, as defense in
depth against `goto fail;`-class bugs. Handled by `zig fmt`.

### 2.4 Strictest compiler diagnostics

**`[mechanical]`** — Build at the compiler's strictest setting and make warnings fail the build. A
warning you can ship past is a warning nobody reads. **Enforced now**, but the shape it takes in Zig
is worth stating plainly: *Zig has no separate warning level.* What another compiler emits as a
warning — an unused variable or parameter, unreachable code, an ignored error — Zig raises as a hard
compile error. There is no `-Werror` to add because there are no warnings to promote; the strictest
setting is the only setting. (Verified against the pinned toolchain: an unused local *and* an unused
parameter each fail the build.)

So the gate is not a flag, it is a guarantee: **every project is actually compiled in the shared
pipeline, and a non-clean compile fails CI.** The blinky's `build` step compiles the firmware — all
code is reachable from the reset vector, so all of it is type-checked. `lib/assert`'s `test` step
compiles the library, and a `refAllDeclsRecursive` test forces even a `pub` decl no test calls
through the compiler — closing the one way Zig's laziness could let a diagnostic slip past. This is
also why the pipeline builds rather than only running the module's `check` verb, which skips
compilation (see the `ci.yaml` comment). On a target where a mistake is a silent no-op on real
silicon (§3.2), a compiler that won't look away is one of the few automatic safety nets available.

---

## 3. Types and the compiler

### 3.1 Explicitly-sized integer types

**`[judgment]`** — Use explicitly-sized types (`u32`, `i16`, `u5`) and avoid architecture-specific
`usize` for values that are not memory sizes or indices. *Bare-metal amplifier:* a memory-mapped
register is *exactly* 32 bits wide regardless of any machine's word size, so a `*volatile u32` is
the hardware's own width and `usize` there is a category error. The blinky types every register as
`*volatile u32`, the peripheral id as `u5`, the pin mask as `u32` — the widths are the datasheet's,
not a style choice.

### 3.2 Be explicit; minimize dependence on the compiler

**`[judgment]`** — Say what you mean and lean on the compiler as little as the language allows. On
firmware this has a concrete edge: `volatile` exists precisely to stop the compiler from eliding or
reordering memory-mapped accesses whose effects it cannot see. Every register access goes through a
`volatile` pointer for exactly this reason. The general principle — *the compiler optimizes what it
can prove; tell it the truth about hardware it cannot* — is the firmware form of this rule.

---

## 4. Control flow

### 4.1 Simple, explicit control flow — no recursion

**`[judgment]`** — Use only simple, explicit control flow, and **do not use recursion**, so every
execution that should be bounded is bounded. *Bare-metal amplifier:* the stack is a fixed region
with **no MMU, no guard page, no overflow trap**. Unbounded recursion does not throw — it grows the
stack down into your live data and corrupts it silently, the single worst failure mode this
environment has. The rule costs nothing and forecloses a catastrophe the hardware cannot catch.

### 4.2 Put a limit on everything

**`[judgment]`** — Every loop and every queue has a fixed upper bound; where a loop genuinely cannot
terminate (an event loop, a fault trap), **assert that intent explicitly** rather than leaving a
bare `while (true) {}`. The bare-metal rider splits the rule in two:

- **A spin on a hardware status bit has no iteration count** — it is the bare-metal idiom (e.g. the
  blinky's `while (SYST_CSR.* & COUNTFLAG == 0) {}`). Bound it *in time* instead, and decide what
  happens when the bound blows. The standard hardware answer is a **watchdog** — but whether you
  want one inverts with the device: a project where a visible hang is the *desired* failure disables
  the watchdog on purpose (the blinky does, as its first act); a project acquiring sensor data over
  a bus wants one, plus a defined timeout on every bus wait.
- **An intentionally non-terminating loop** (a main loop, a fault trap) is exactly the case to make
  explicit. A one-line assertion-as-documentation saying *this loop is meant to run forever* is
  worth more than the bare `while (true) {}` the blinky currently uses in its traps.

### 4.3 Small functions

**`[judgment]`** — Hard-cap functions at ~70 lines. A function that does not fit is doing more than
one thing. *Mechanizable in principle* — a line counter could gate it — but no tool is wired, so it
is a review rule today.

### 4.4 Centralize control flow; keep leaf functions pure

**`[judgment]`** — Concentrate branching in a few places, *"push `if`s up and `for`s down,"* and
keep leaf functions pure (compute from inputs, no reaching out to global state). On firmware this is
the same discipline that keeps interrupt handlers short and pushes state manipulation into the main
loop (§4.5): the fewer places that touch hardware, the fewer places a silent-no-op bug can hide.

### 4.5 Run at your own pace — poll before interrupt

**`[judgment]`** — *"Don't do things directly in reaction to external events. Instead, run at your
own pace."* On firmware this **is** the polling-vs-interrupt decision, stated as doctrine. Prefer
**polling**: control flow stays in one place (the main loop), which is deterministic and easy to
reason about. The blinky polls SysTick's `COUNTFLAG` rather than taking the interrupt, and wires the
unused SysTick vector to the fault trap so a stray interrupt visibly stops the board.

*The honest carve-out:* polling is not always available. Low-power designs must sleep (`WFI`) and
wake on interrupt; hard deadlines may demand an ISR. When interrupts are mandatory the rule does not
vanish — it takes its embedded form: **the ISR does the minimum (clear the source, set a flag,
enqueue to a bounded buffer) and returns; the main loop runs at its own pace and does the work.**

---

## 5. Assertions

Assertions are the center of gravity, and the place where server doctrine needs the most
translation: an MCU has no `stderr`, no `abort`, and no orchestrator to restart a crashed process.
The pieces below do not all transfer the same way.

### 5.1 Crash on corrupt state — but define what "crash" means

**`[judgment]`** — *"The only correct way to handle corrupt code is to crash. Assertions downgrade
catastrophic correctness bugs into liveness bugs."* The philosophy transfers directly; the mechanism
is per-device. On a server, "crash" is `abort()` → the process exits → something restarts it. **None
of that exists on bare metal**, so each project must answer: *what does "crash" do on this device?*

- Halting is the MCU's `abort` — and it is **safe only when the worst outcome is an idle output.**
  For the blinky, halt is strictly safe: a dark LED. For a device driving a motor, a heater, or a
  radio, halting can *hold an output asserted* and be the most dangerous state available.
- So the correct "crash" is often **drive outputs to a safe state, then halt (or reset).** The safe
  state is a property of the device, not a universal, and it belongs in a short written per-project
  policy — the **[fault-response policy][fault-policy]** ([#12][issue-12]), a template each project
  fills in ([the blinky's is the worked instance][fault-policy-blinky]). This guide's rule is only:
  *decide it deliberately; do not default to "halt" without checking halt is safe here.*

### 5.2 Prefer compile-time assertions

**`[judgment]`** — **This is the highest-value item in the guide.** Every hard problem below —
flash cost, ISR context, what "crash" means — *evaporates* for an assertion that runs at compile
time: it costs **zero flash, zero cycles, cannot fire in an ISR**, and its "crash" is a build error
on the developer's machine, the safest place for a correctness bug to surface. So push every
invariant you can to `comptime`. The blinky already does this for its timer reload:

```zig
comptime {
    if (HALF_PERIOD_TICKS - 1 > 0xFF_FFFF) {
        @compileError("SysTick reload exceeds 24 bits; halve the clock or divide in software");
    }
}
```

Register widths, buffer sizes vs. region lengths, timer reloads vs. counter widths, alignment
assumptions — a large fraction of firmware's invariants are static and checkable for free. Reach for
`comptime` *before* reaching for a runtime assert.

### 5.3 Assert liberally

**`[judgment]`** — Tiger Style targets *"a minimum of two assertions per function"* — arguments,
return values, pre/postconditions, invariants. On this target that density is only affordable with a
**flash-cheap assert** that lowers to a bare trap (no message, no format string, no stack unwind) —
because a stock `std.debug.assert` drags in panic and formatting machinery measured in hundreds of
kilobytes, the very machinery firmware deletes to fit its flash budget. That primitive now exists as
**[`lib/assert`][lib-assert]** ([#11][issue-11]): a failed assertion branches once, cold, to the
project's chosen failure state, and it is toggleable on/off per project. Use it for runtime density;
lean on `comptime` (§5.2) for everything checkable before the program runs.

### 5.4 Assertions inside an interrupt context

**`[judgment]`** — An assertion that fires *inside an ISR* trips where the main thread is suspended
and other interrupts may be masked; halting there can wedge the whole system in interrupt context,
which for some devices is worse than the bug. Two riders: **(a)** a failing assertion in an ISR
should reach the *same* safe-state path as a fault (§5.1), not a different ad-hoc one; **(b)** keep
ISRs short enough (§4.4) that there is little in them to assert in the first place. A poll-driven
design (§4.5) sidesteps this entirely — the blinky's only "ISR" is a trap that must never run.

### 5.5 Pair assertions — readback around peripheral config

**`[judgment]`** — *"For every property you want to enforce, find at least two different code paths
where an assertion can be added."* TigerBeetle's pair is write-side / read-side around the disk.
Firmware's equivalent is **write-then-readback around a peripheral register**, and it targets this
environment's nastiest bug class: a write that is *silently dropped* (a gated clock, a
write-protected or wrong-address register) signals no error at all. After configuring a peripheral,
read the status register back and assert the change took. *Caveat, honestly:* readback is not
universally valid — some registers are write-only or read-to-clear (the blinky *relies* on reading
`SYST_CSR` to clear `COUNTFLAG`), so this is a targeted tool for the config phase, not a blanket
rule. Reusable helpers are the **[readback-helpers story (#15)][issue-15]**.

### 5.6 Positive and negative space

**`[judgment]`** — *"Assert the positive space that you do expect AND the negative space that you do
not expect."* Reject the invalid as loudly as you confirm the valid. The best example in the repo is
in CI, not firmware: the *"Assert the reset vectors are sane"* step asserts negative space over the
built image (initial SP must equal top of SRAM0, reset vector must land in flash, Thumb bit must be
set) — each check rejecting a class of image that would hard-fault instantly and that the compiler
would never catch. Generalizing that checker is the **[artifact-checker story (#16)][issue-16]**.

### 5.7 Assertion mechanics

**`[judgment]`** — The language-general mechanics, adopted as-is:

- **Split compound assertions:** `assert(a); assert(b);`, not `assert(a and b)` — so a failure
  points at the exact clause.
- **Single-line `if` for implications:** `if (a) assert(b);`.
- **Blatantly-true assertions as documentation** where a condition is critical and surprising.
- Assertions are *"a safety net, not a substitute for human understanding"*: build the mental model
  first, encode it as assertions, then let testing find the gaps.

### 5.8 Keep assertions on in production

**`[judgment]`** — Ship with assertions enabled — *when* they are flash-cheap (§5.3) and fail into a
designed safe state (§5.1). Those two conditions are the whole disagreement with the more cautious
MISRA/Power-of-Ten stance on shipping assertions: resolve them and keeping assertions on is
affordable; leave them unresolved and the caution is right. The blinky keeps its fault and panic
traps live in `ReleaseSmall` today — proof the affordable case exists.

---

## 6. Error handling

### 6.1 Handle every error — and first, manufacture the missing one

**`[judgment]`** — *"All errors must be handled"* — the cited research found 92% of catastrophic
failures came from mishandling errors software *explicitly signaled*. Zig's error unions make the
handling half straightforward and must be handled wherever they exist. But bare metal adds a **prior
step the server never has**: the dominant firmware failure is not a mishandled error, it is **no
error to handle** — a dropped register write, a poke to a wrong address, a write-once register
written twice. The language cannot hand you `error.ClockWasGated`. So the discipline is:
**manufacture the missing error first** — via readback (§5.5) or a `comptime` check (§5.2) — *then*
handle it.

---

## 7. Memory

### 7.1 Static allocation

**`[judgment]`** — Allocate all working memory statically, at init. On a freestanding target this is
usually the ground state, not a discipline you impose — there is no allocator to abstain from. The
rule bites the moment a project introduces a heap (a parser, a buffer pool for an audio path): at
that point *"if you reach for an allocator, that is a design decision to justify, not a default."*
The habit generalizes past memory: **bound every resource at design time.** The blinky applies
it to flash and cycles — computing its image size, checking a Debug build would overflow ROM, sizing
the timer reload against the counter width at `comptime`. (A per-project resource budget is the
**[resource-budget story (#20)][issue-20]**.)

---

## 8. Dependencies

### 8.1 Depend on the vendor's numbers, not the vendor's code

**`[judgment]`** — Keep firmware link-time dependencies at zero apart from the Zig toolchain (and,
for shared build/flash tooling, the Dagger modules this repo pins by commit SHA). The blinky takes
its register addresses *from* the vendor's CMSIS headers without taking a *dependency on* them — the
deliberate middle path between hardcoding blind and pulling in a heavyweight HAL. *State the tension
honestly:* HALs exist because register maps are large and error-prone, and hand-transcription scales
badly, so this stance is cheap at blinky size and costs more per peripheral. It is a value to uphold
with eyes open, not a law: when a project's register surface makes transcription the bigger risk,
that is a design conversation, not a silent exception.

---

## Bare-metal carve-outs at a glance

The four riders the [research][research] flagged as needing the most translation from server
doctrine, each stated generally:

| Rider | Server assumption | Bare-metal reality | This repo's rule |
|---|---|---|---|
| **What "crash" means** (§5.1) | `abort()` → exit → orchestrator restarts | No OS, no `abort`, no restart. Halt can *hold an output asserted* | Define the device's safe state; "crash" = drive outputs safe, then halt/reset. Halt-only where idle is safe |
| **Assertions in an ISR** (§5.4) | Crash unwinds a normal call stack | Firing in interrupt context can wedge the system with the main thread suspended | ISR assertions reach the same safe-state path as a fault; keep ISRs short; prefer polling |
| **Poll vs. interrupt** (§4.5) | "Run at your own pace" = batch external events | Hardware will not always wait; low-power/real-time may force an ISR | Poll by default; when forced, ISR does the minimum and the main loop does the work |
| **Prefer compile-time assertions** (§5.2) | Runtime asserts are ~free; keep them on | Runtime asserts cost flash and can fire in an ISR | Push every invariant possible to `comptime`: zero flash, zero cycles, cannot fire in an ISR, fails on the dev machine |

---

## Enforcement summary

The distinction the guide turns on — what a tool gates versus what a human judges.

| Rule | Kind | Status |
|---|---|---|
| §2.1 `zig fmt` (incl. indent, braces) | mechanical | **Enforced now** (`ci.yaml`, shared pipeline) |
| §2.2 100-column limit | mechanical | **Enforced now** (`ci.yaml`, `ci` module's `line-length`) |
| §2.4 Strictest compiler diagnostics | mechanical | **Enforced now** (`ci.yaml`; Zig warnings are errors) |
| §5.6 Artifact / negative-space checks | mechanical | Partial today (reset-vector check); generalized by [#16][issue-16] |
| §1.1 snake_case names | judgment | Mechanizable via a future linter; review rule today |
| §4.3 ~70-line function cap | judgment | Mechanizable via a line counter; review rule today |
| §1.2–1.7, §3.x, §4.1–4.2, §4.4–4.5, §5.1–5.5, §5.7–5.8, §6.1, §7.1, §8.1 | judgment | Code review and author discipline |

Rules that lean on shared infrastructure name it. Two pieces have landed: the flash-cheap assert
([`lib/assert`][lib-assert], [#11][issue-11]) and the fault-response policy
([`docs/fault-response-policy.md`][fault-policy], [#12][issue-12]) — use them. The rest are still
open stories: readback helpers ([#15][issue-15]), artifact checker ([#16][issue-16]), host test step
([#17][issue-17]); those rules are stated here so projects code *toward* them.

---

## Sources

- **[Tiger Style][tiger-style]** — TigerBeetle's coding style. The canonical source; read it, not
  just this restatement of it.
- **[TigerBeetle for Embedded][research]** — the in-repo study ([#8][issue-8]) that decided, rule by
  rule, what transfers to bare metal and what needs a carve-out. Every rule here traces to a section
  of that study.

*If this guide and a source disagree, the source wins and this file has drifted — fix it here.*

[tiger-style]: https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md
[research]: research/tigerbeetle-for-embedded.md
[check-line-length]: ../ci/main.go
[lib-assert]: ../lib/assert
[fault-policy]: fault-response-policy.md
[fault-policy-blinky]: ../arduino-due/blinky/fault-response-policy.md
[issue-3]: https://github.com/Zaba505/embedded/issues/3
[issue-8]: https://github.com/Zaba505/embedded/issues/8
[issue-11]: https://github.com/Zaba505/embedded/issues/11
[issue-12]: https://github.com/Zaba505/embedded/issues/12
[issue-14]: https://github.com/Zaba505/embedded/issues/14
[issue-15]: https://github.com/Zaba505/embedded/issues/15
[issue-16]: https://github.com/Zaba505/embedded/issues/16
[issue-17]: https://github.com/Zaba505/embedded/issues/17
[issue-20]: https://github.com/Zaba505/embedded/issues/20
