# TigerBeetle for Embedded

*What [Tiger Style][tiger-style] and [the VOPR][vopr] — TigerBeetle's deterministic simulation
testing — actually have to teach the bare-metal work in this repo.*

This is a study, not a decision. It reads both source documents first-hand and asks, idea by idea,
whether each one **transfers directly**, **transfers in modified form**, or **does not apply here**,
and shows the reasoning — because the reasoning is where the learning is. It ends with a backlog of
filable follow-up stories. Adopting any of them is out of scope; producing the list is the point.

The hypothesis under test — stated in [issue #8][issue] — is that these two documents, written for a
replicated financial database that runs on servers, port unusually well to firmware, because
firmware shares the part of that world a web app does not: it is hard to update in the field, it
fails where you cannot attach a debugger, and "it worked on my bench" is not proof. That is a bet to
test, not a conclusion to assume. A study that concluded "do everything TigerBeetle does" would be a
failed study: TigerBeetle assumes a heap it chooses not to use, threads, an OS, a cluster of
replicas, and a simulation budget measured in CPU-years. A [244-byte blinky](../../arduino-due/blinky)
has none of that.

## Sources

Both documents were read in full on 2026-07-20, from `tigerbeetle/tigerbeetle@main`:

- **Tiger Style** — [`docs/TIGER_STYLE.md`][tiger-style] (511 lines).
  `sha256:2b634cd1da3762eb9d352e8d3767a12c335138e649ed2bfc67bd5abd4cd78203`
- **Deterministic Simulation Testing / the VOPR** — [`docs/internals/vopr.md`][vopr] (73 lines).
  `sha256:9d5b6889e62cc159659b6efa6346d65e8a2b0bd0c390e94356ed8400bd12de69`

Citations quote these files directly so a reader can check any claim about what a source "requires."

[tiger-style]: https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md
[vopr]: https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/internals/vopr.md
[issue]: https://github.com/Zaba505/embedded/issues/8

## What "this repo" means, concretely

Every recommendation below is tied to one of these, never left abstract:

- **`arduino-due/blinky`** — bare-metal Zig for the Atmel SAM3X8E (Cortex-M3). Toggles an externally
  wired LED on `PB26` at 1 Hz. Register addresses are hardcoded `*volatile u32` pointers taken from
  the CMSIS headers; there is no HAL, no libc, no `_start`. Hard constraints: **256 KB flash** (bank
  0 only), **64 KB SRAM0**, a **4 MHz** RC oscillator, `single_threaded = true`, and `ReleaseSmall`
  by default — a `Debug` build overflows flash by ~35 KB once Zig links in its panic and formatting
  machinery ([`build.zig`](../../arduino-due/blinky/build.zig)).
- **The halt-not-reset choice.** The blinky replaces Zig's panic handler and all fault vectors with
  a bare `while (true) {}`. This is deliberate: a reset loop is the exact false positive the project
  exists to rule out, so a fault must *stop* the LED, never restart it
  ([`src/main.zig`](../../arduino-due/blinky/src/main.zig),
  [`src/start.zig`](../../arduino-due/blinky/src/start.zig)).
- **The silent-failure environment.** "A wrong address here is a silent no-op on real silicon, not a
  build error" (main.zig header). PIO register writes are *silently dropped* while the peripheral
  clock is gated; `WDT_MR` is write-once and the watchdog is enabled out of reset. Order is load-
  bearing and nothing complains when you get it wrong.
- **The Dagger build/flash flow.** Building and flashing go through Dagger modules with no
  host-installed toolchain: the `z5labs/devex` `zig` module builds (pinned by commit SHA in
  [`.github/workflows/ci.yaml`](../../.github/workflows/ci.yaml)), and this repo's
  [`daggerverse/bossac`](../../daggerverse/bossac) module flashes over SAM-BA.
- **The CI checks.** `ci.yaml` runs `zig fmt --check`, a `build`, an ELF/bin export, and a host-side
  Python step — **"Assert the reset vectors are sane"** — that reads the built image and checks the
  initial stack pointer, the reset vector's flash range, and its Thumb bit. There is **no test
  step**; the CI comment records why (`check` "does not compile … reports success on a build that
  does not even type-check").
- **The "an indicator can lie" thesis, already written.** The blinky README argues at length that a
  blinking on-board LED is weak evidence (a watchdog reset loop mimics it), and the `bossac` saga
  documents 1.9.1 reporting "a clean write, a clean verify, and `Boot Flash: true`" on a board that
  *never executed a single instruction*. The repo already believes, in writing, that a green signal
  can be entirely accurate and mean nothing.
- **Related future work.** The `steth-*` stories (#5, #6, #7) are the first candidates for anything
  heavier than a blinky, and the follow-ups below point there.

---

# Part 1 — Tiger Style

## 1.1 The meta-doctrine

Tiger Style opens with three design goals in priority order: **"safety, performance, and developer
experience. In that order"** (§Why Have Style?). It then argues that **"simplicity … is the hardest
revision"** you may still have to "throw one away" (§On Simplicity), and holds a **"zero technical
debt" policy** — "we do it right the first time … because the second time may not transpire"
(§Technical Debt).

**Transfers directly — and the priority order tightens on embedded.** On a server, "developer
experience last" is a values statement. On firmware it is closer to a physical law: the field-un-
updatability the issue names means a shipped bug may never get a second chance, which is Tiger
Style's "the second time may not transpire" made literal. The blinky already embodies safety-over-DX
at every turn — choosing the awkward `PB26` over the convenient on-board D13 precisely because the
convenient choice can lie, and choosing halt-on-fault over the friendlier reset. And "throw one
away" is not hypothetical here: the `bossac` module reached 1.7.0 only by bisecting through 1.9.1
(unbootable) and 1.6.1 (SIGFPE) on real hardware. Nothing to adopt mechanically; a doctrine the repo
already lives, worth stating so future projects inherit it.

## 1.2 Static allocation — the headline "already free" case

> "All memory must be statically allocated at startup. **No memory may be dynamically allocated (or
> freed and reallocated) after initialization.**" — §Safety

**As a rule to adopt: does not apply. As a design mindset: transfers directly — and is already
practiced.** This is the cleanest example of the issue's central question — what is *left to adopt*
once the environment already forces the rule. On a server, "no heap after init" is a hard-won
discipline fought against a runtime that offers `malloc` on every corner. On the blinky there is no
allocator to abstain from: freestanding Zig links no libc, `single_threaded = true` strips the
threading machinery, and `.data`/`.bss` are the entire memory story — hand-initialized word-by-word
in `resetHandler` before any Zig that touches them runs. There is nothing to *adopt*; the rule is
the ground state.

But the second-order insight Tiger Style attaches to the rule *does* transfer, and glossing over
that would miss the point. The document's real claim is that static allocation "makes for more
efficient, simpler designs … because [they] consider all possible memory usage patterns upfront as
part of the design." That mindset — **bound every resource at design time** — is alive and well here,
just pointed at different resources: the blinky README computes the image at ~244 bytes, notes that
Debug overflows the ROM region by ~35 KB, and sizes the SysTick reload against the 24-bit hardware
limit *at compile time*. That is the static-allocation discipline, applied to flash and cycles
instead of heap.

**The threshold worth flagging:** the rule snaps back from "free" to "directly applicable" the
instant a future project introduces a heap — an allocator for a parser, a dynamic buffer pool for a
`steth-*` audio path. At that moment Tiger Style's rule stops being a description of the environment
and becomes a real constraint to enforce. Worth adopting *pre-emptively* as a repo convention:
**freestanding projects allocate all working memory statically at init; if you reach for an
allocator, that is a design decision to justify, not a default.**

## 1.3 Control flow and the ban on recursion

> "Use **only very simple, explicit control flow** … **Do not use recursion** to ensure that all
> executions that should be bounded are bounded." — §Safety

**Transfers directly, and matters *more* here than on a server.** TigerBeetle bans recursion to keep
executions bounded. On a Cortex-M3 the stakes are higher: the stack is a fixed 64 KB region
(`_estack = ORIGIN(ram) + LENGTH(ram)` in [`link.ld`](../../arduino-due/blinky/link.ld)) with **no
MMU, no guard page, no stack-overflow trap**. Unbounded recursion does not throw — it grows the
stack down into `.data`/`.bss` and corrupts live state silently, which is the single worst failure
mode this environment has. The blinky uses only flat loops; the rule costs nothing and forecloses a
catastrophe the hardware cannot otherwise catch. Adopt verbatim.

## 1.4 "Put a limit on everything" — and what to do with the event loop

> "**Put a limit on everything** … all loops and all queues must have a fixed upper bound … Where a
> loop cannot terminate (e.g. an event loop), this must be asserted." — §Safety

**Transfers in modified form — this is where server doctrine and bare-metal reality rub.** The
blinky's `main()` ends in an intentional non-terminating loop, and `waitHalfPeriod()` spins on a
hardware flag with no upper bound:

```zig
fn waitHalfPeriod() void {
    while (SYST_CSR.* & SYST_CSR_COUNTFLAG == 0) {}
}
```

Tiger Style's rule has two halves, and they land differently:

- *"All loops must have a fixed upper bound"* — **modified.** A spin on a hardware status bit is the
  bare-metal idiom, and it has no natural iteration count. But it *does* have an implied time bound
  (SysTick wraps every half-period), and the failure mode — a peripheral that never sets the flag —
  is real: it hangs the LED forever. The server translation is "bound the wait"; the embedded
  translation is "bound the wait *in time* and decide what happens when the bound blows." The
  standard hardware answer is a **watchdog** — which this project deliberately *disables* as its
  first act, because for a blinky a visible hang is the *desired* failure and a watchdog reset is the
  false positive. So the rule inverts cleanly with the domain: a blinky wants no watchdog; a
  `steth-*` device acquiring sensor data wants one, plus a defined timeout on every bus wait.
- *"Where a loop cannot terminate, this must be asserted"* — **transfers directly, and is currently
  absent.** Both infinite loops here (`main`'s blink loop, and the `defaultHandler`/`panic` traps)
  are *intended* to run forever, which is exactly the case Tiger Style says to make explicit. Today
  they are bare `while (true) {}`. A one-line `// unreachable exit: …` assertion-as-documentation
  (see §1.5) would say *this loop is intended to be non-terminating* out loud.

## 1.5 Assertions — the center of gravity

This is the richest transfer and the one the issue flags hardest: *what does an assertion even do on
an MCU with no `stderr`, no `abort`, and where a failed assertion might be the safest state or the
most dangerous one?* Tiger Style's assertion doctrine has several distinct pieces; they do not all
transfer the same way.

### 1.5.1 The philosophy: crash on corrupt state

> "**The only correct way to handle corrupt code is to crash. Assertions downgrade catastrophic
> correctness bugs into liveness bugs.**" — §Safety

**The philosophy transfers directly; the mechanism is modified and system-dependent.** "Crash" on a
server means `abort()` → process exits → an orchestrator restarts it. None of that exists on bare
metal. But the blinky has *already implemented the embedded translation of this exact sentence*
without citing it: its `panic` handler and `defaultHandler` both `while (true) {}`, and the reason
given is Tiger Style's reasoning almost verbatim — a fault must "stop the LED dead instead of
producing a blink," i.e. downgrade a correctness bug (something faulted) into a liveness bug (the LED
stopped). Halt *is* the MCU's `abort`.

The subtlety the issue demands engaging: **whether halting is the safe response is a property of the
system, not a universal.** For a blinky, halt is strictly safe — the worst outcome is a dark LED.
For a device driving a motor, a heater, or a radio, halting mid-action can *hold an output asserted*
and is potentially the most dangerous state available; there the correct "crash" is **drive outputs
to a safe state, then halt or reset**. Tiger Style can afford one universal answer ("crash") because
every TigerBeetle process fails into the same benign place. Firmware cannot: the safe failure state
is per-device and must be designed. So the doctrine transfers, but it forces a decision Tiger Style
never has to make — *what is this device's safe state?* — and that decision belongs in a per-project
policy (→ follow-up story).

### 1.5.2 "Two assertions per function" meets the flash budget and the ISR

> "**Assert all function arguments and return values, pre/postconditions and invariants** … The
> assertion density of the code must average a minimum of two assertions per function." — §Safety

**Transfers in modified form.** "Tiger Style says assert a lot" is not a finding; here is what
happens when the two-per-function rule makes contact with this target:

- **Flash cost is not free, and the blinky already paid to avoid it.** A naïve Zig `assert` reaches
  `std.debug.panic`, which "drags in message formatting and stack-trace walking — hundreds of
  kilobytes" (main.zig) — the very machinery the blinky *deletes* to fit in 256 KB. So the
  density target is unreachable with stock assertions on this target. It becomes reachable only with
  a **flash-cheap assert** that lowers to a bare trap (a branch to a halt/safe-state) with no string,
  no format, no unwind — structurally the blinky's existing `panic` body, wrapped in a condition.
  With that primitive, two assertions per function costs a few instructions each and the rule is
  affordable. Without it, the rule is in direct conflict with the flash budget. (→ follow-up story.)
- **Behavior inside an ISR is a genuinely different question.** Tiger Style assumes the crash
  unwinds a normal call stack. An assertion that fires *inside an interrupt handler* trips in a
  context where the main thread is suspended and other interrupts may be masked — halting there can
  wedge the whole system in interrupt context, which for some devices is worse than the bug. The
  blinky sidesteps this entirely by being **poll-driven, not interrupt-driven** (see §1.9): its
  SysTick handler is wired to the trap "so that if it ever does [fire], the board visibly stops."
  For firmware that *does* take interrupts, the rule needs a rider: an assertion in an ISR should
  reach the same safe-state path as a fault, and ISRs should be short enough (Tiger Style's own
  70-line and "centralize control flow" advice, §1.8) that there is little in them to assert.
- **Much of what the blinky would "assert" is compile-time knowable** — which is the best possible
  news, and the next item.

### 1.5.3 Compile-time assertions — zero-cost, and the single best fit

> "**Assert the relationships of compile-time constants** … Compile-time assertions are extremely
> powerful because they are able to check a program's design integrity _before_ the program even
> executes." — §Safety

**Transfers directly, is already in the codebase, and is the highest-value item in this whole
study.** Every hard problem in §1.5.2 — flash cost, ISR context, what "crash" means — *evaporates*
for assertions that run at compile time: they cost zero flash, zero cycles, cannot fire in an ISR,
and "crash" is a build failure on the developer's machine, which is the safest possible place for a
correctness bug to surface. The blinky already does exactly this:

```zig
comptime {
    if (HALF_PERIOD_TICKS - 1 > 0xFF_FFFF)
        @compileError("SysTick reload exceeds 24 bits; halve the clock or divide in software");
}
```

That is Tiger Style's "assert the relationships of compile-time constants" verbatim, checking a
subtle hardware invariant (the 24-bit reload register) before the program exists. The lesson to
generalize: **on a constrained target, push as many assertions as possible to `comptime`.** Register
widths, buffer sizes vs. region lengths, timer reloads vs. counter widths, alignment assumptions in
the linker script — a large fraction of firmware's invariants are static and can be checked for free.
This is where the assertion doctrine transfers most completely and most cheaply.

### 1.5.4 Pair assertions → readback, aimed at the silent no-op

> "**[Pair assertions.](...)** For every property you want to enforce, try to find at least two
> different code paths where an assertion can be added. For example, assert validity of data right
> before writing it to disk, and also immediately after reading from disk." — §Safety

**Transfers in modified form, and targets this repo's nastiest bug class.** TigerBeetle's pair is
write-side / read-side around the disk. Firmware's equivalent is **write-side / readback around a
peripheral register**, and it lands on precisely the failure the blinky's comments warn about: "PIO
writes are silently dropped while the controller's peripheral clock is gated." That is a property you
cannot get an error for (§1.7) — the write returns nothing and does nothing. A pair assertion catches
it: after writing `PMC_PCER0` to clock PIOB, *read back* `PMC_PCSR0` and assert the clock is on
*before* trusting any subsequent PIO write; after configuring a pin, read the status register and
assert it took. The write path and the readback path are the "two different code paths" Tiger Style
asks for, and the gap between them is exactly where the silent-no-op bug lives. (Caveat, honestly:
readback is not free — some registers are write-only or read-clear, and reads have side effects, e.g.
the blinky *relies* on reading `SYST_CSR` to clear `COUNTFLAG`. So this is a targeted tool for the
config phase, not a blanket rule.) (→ follow-up story.)

### 1.5.5 Positive and negative space → the CI reset-vector checker

> "**The golden rule of assertions is to assert the _positive space_ that you do expect AND to assert
> the _negative space_ that you do not expect** … tests must test exhaustively, not only with valid
> data but also with invalid data." — §Safety

**Transfers directly in spirit; the repo already has one instance and lacks the general habit.** The
best example is not even in the firmware — it is in CI. The **"Assert the reset vectors are sane"**
step asserts negative space over the *built artifact*: the initial SP must equal the top of SRAM0,
the reset vector must fall inside flash bank 0, and it must have its Thumb bit set — each check
rejecting a class of image that would hard-fault instantly on a real Cortex-M3, none of which the
compiler would catch. That is negative-space assertion done well, and it bridges directly to Part 2
(it is a VOPR-style checker in miniature). What is missing is the *habit* of it in the firmware
itself and a *test step* to host exhaustive positive/negative cases (the repo has none — §2.6).

### 1.5.6 The remaining assertion mechanics

Direct, language-general, cheap, no embedded caveat — adopt with the rest of the style rules (§1.10):
**split compound assertions** (`assert(a); assert(b);` over `assert(a and b)`); **single-line `if`
for implications** (`if (a) assert(b)`); **blatantly-true assertions as documentation** where a
condition is "critical and surprising"; and the meta-rule that assertions are "a safety net, not a
substitute for human understanding" — *build the mental model first, encode it as assertions, then
let simulation find the gaps* (§Safety), which is the hinge into Part 2.

## 1.6 "All errors must be handled" — with a bare-metal twist

> "All errors must be handled. An analysis of production failures … found that … almost all (92%) of
> the catastrophic system failures are the result of incorrect handling of non-fatal errors
> explicitly signaled in software." — §Safety

**Transfers in modified form, and the modification is the interesting part.** The cited failure mode
is *mishandling an error the software explicitly signaled*. On this target the dominant failure mode
is the opposite: **there is no error to mishandle.** A dropped PIO write, a poke to a wrong register
address, a write-once register written twice — none of these signal anything. Zig's error unions
work fine on freestanding and should absolutely be handled where they exist, but the language cannot
hand you an `error.ClockWasGated`. So the doctrine transfers with its emphasis shifted: **the
embedded discipline is first to *manufacture* the missing error** — via readback (§1.5.4) or a
compile-time check (§1.5.3) — *and then* handle it. The 92% finding is about the second step; bare
metal adds a prior step the server never has to think about.

## 1.7 "Run at your own pace" — the poll-vs-interrupt choice, already made

> "Whenever your program has to interact with external entities, **don't do things directly in
> reaction to external events**. Instead, your program should run at its own pace." — §Safety

**Transfers directly, and the blinky is already a textbook instance of it.** This rule reads as if
written about servers batching network events, but it *is* the embedded polling-vs-interrupt
decision, stated as doctrine. The blinky **polls** SysTick's `COUNTFLAG` in its main loop rather than
taking the SysTick interrupt, and `start.zig` explains that the handler is wired to the trap because
it "should never fire." That is "run at your own pace" exactly: control flow stays in `main`, not
scattered across asynchronous handlers.

The honest embedded caveat: **polling is not always available.** Low-power designs must sleep (`WFI`)
and wake on interrupt; hard-real-time deadlines may demand an ISR. When interrupts are mandatory,
Tiger Style's rule does not vanish — it becomes the well-known good pattern that *is* the rule's
embedded form: **the ISR does the minimum (clears the source, sets a flag, enqueues to a bounded
buffer) and returns; the main loop runs at its own pace and does the real work.** That is "keep the
control flow under your control" surviving contact with hardware that will not wait, and it composes
with "centralize control flow" (§1.8).

## 1.8 Function shape, size, and control-flow centralization

> "**hard limit of 70 lines per function** … Centralize control flow … 'push `if`s up and `for`s
> down' … Keep leaf functions pure." — §Safety

**Transfers directly, language-general, no embedded conflict — with a bonus for ISRs.** The blinky's
functions are already tiny. The "centralize control flow, keep leaf functions pure" guidance has
extra force in firmware: it is the same advice that keeps interrupt handlers short and pushes state
manipulation into the main loop (§1.7). Adopt with the style bundle (§1.10).

## 1.9 Explicitly-sized types, and being explicit with the compiler

> "Use explicitly-sized types like `u32` for everything, avoid architecture-specific `usize`." —
> §Safety. "Be explicit. Minimize dependence on the compiler." — §Performance

**Transfers directly, already practiced, and *more* justified here than on a server.** Every register
in the blinky is a `*volatile u32`; `ID_PIOB` is a `u5`; the pin mask is a `u32`. On a memory-mapped
target these are not stylistic widths — they are the hardware's widths, and a register is *exactly*
32 bits whatever the word size of some other machine. `usize` would be a category error. Likewise
"minimize dependence on the compiler" has a firmware-specific edge: `volatile` exists precisely to
stop the compiler from eliding or reordering register accesses it cannot see the effects of. The repo
already does this; the value is codifying it so it is a rule, not a habit.

## 1.10 Naming, style-by-the-numbers, and "always say why"

The whole §Developer-Experience block — `snake_case`; no abbreviations; **units and qualifiers last**
(`latency_ms_max`, which the blinky already mirrors in `HALF_PERIOD_TICKS`); proper acronym
capitalization; `index`/`count`/`size` as distinct types with `@divExact`/`@divFloor` to "show your
intent"; `zig fmt`; 4-space indent; 100-column hard limit; braces on non-single-line `if`s; and
**"Always motivate, always say why"** — is **direct and language-general.** This is Zig-and-general
craft with no bare-metal caveat, and the blinky is already close to it (its comment density and
"say why" discipline are, frankly, ahead of Tiger Style's own examples — every register poke carries
its rationale). Two things follow:

1. **Codify it** so future projects inherit it rather than re-deriving it (→ follow-up story).
2. **Enforce the mechanical parts in CI.** `zig fmt --check` already runs. The 100-column limit and
   **"all compiler warnings at the compiler's strictest setting"** (§Safety) are not yet enforced and
   are a small, high-leverage addition to `build.zig` and `ci.yaml` (→ follow-up story).

## 1.11 Zero dependencies — and where the Dagger modules sit

> "TigerBeetle has **a 'zero dependencies' policy**, apart from the Zig toolchain." — §Dependencies

**Transfers directly to the firmware, with a nuance worth naming.** The blinky has *literally zero*
link-time dependencies: no vendor HAL, no CMSIS library, no libc. Register addresses were "taken from
the Atmel CMSIS headers … rather than from memory" — it took the *data* from CMSIS without taking a
*dependency* on it. That is a deliberate middle path between the two things embedded developers
usually pick from (hardcode blind, or pull in a heavyweight vendor HAL), and it is worth stating as a
repo value: **depend on the vendor's numbers, not the vendor's code.** The tension to acknowledge:
HALs exist because register maps are large and error-prone, and hand-transcription scales badly — the
zero-dependency stance is cheap at blinky size and gets more expensive per peripheral. Tiger Style's
own carve-out ("apart from the Zig toolchain") maps here to "apart from the pinned Dagger build
modules," which the repo already treats with the same seriousness Tiger Style treats its toolchain —
pinning `z5labs/devex` by commit SHA because "floating on main would let an upstream change break the
build" (`ci.yaml`).

## 1.12 Tooling — "write scripts in Zig," against a Go/Dagger reality

> "the next time you write a script, instead of `scripts/*.sh`, write `scripts/*.zig` … Standardizing
> on Zig for tooling … reduce[s] dimensionality." — §Tooling

**The principle transfers; the specific prescription is in real tension with this repo's chosen
architecture, and that is worth being honest about.** Tiger Style's underlying point — a small,
standardized toolbox beats an array of specialized instruments — is sound anywhere. But this repo has
deliberately standardized on **Dagger**, whose modules are **Go** (`daggerverse/bossac/main.go`), and
its CI reaches for **inline Python** for the reset-vector check. By Tiger Style's own logic that
Python step is exactly the ad-hoc, OS-specific tool the doctrine warns against — it would be more
robust as a Zig program or a typed Dagger module function. So the finding is not "rewrite everything
in Zig" (the Dagger/Go choice is load-bearing and correct for hermetic builds); it is narrower and
real: **the one genuinely ad-hoc tool in the pipeline — the inline Python checker — is the piece
Tiger Style would have you consolidate**, and doing so also happens to make it reusable across future
projects (→ follow-up story, and it dovetails with the VOPR checkers in §2.5).

## 1.13 The expected conflict with MISRA / Power of Ten — that mostly isn't

The issue asks where Tiger Style "actively conflicts with … established embedded guidance such as
MISRA C or NASA's Power of Ten." The striking answer from reading the source: **Tiger Style is
largely *downstream* of that guidance, not in conflict with it.** It cites [NASA's Power of Ten]
by name and says it "will change the way you code forever" (§Safety), then restates P10's core —
bounded loops, no recursion, assertions, limits on everything, handle every error — in its own words.
Power of Ten was written for JPL spaceflight software; it is *already* embedded-adjacent safety
doctrine. So the feared conflict between "famous server project" and "embedded best practice" is
smaller than the issue's framing allows, because the server project is quoting the embedded practice.

The genuine differences are narrow and resolvable:

- **Assertions in production.** MISRA/P10 culture around shipping with assertions enabled is more
  ambivalent than Tiger Style's "keep them on, even in production" (§2.4). On this target the
  deciding factor is not doctrine but the two mechanical facts already established: assertions must be
  flash-cheap (§1.5.2) and must fail into a *designed* safe state (§1.5.1). Resolve those and
  Tiger Style's position is affordable; leave them unresolved and MISRA's caution is right.
- **Language.** MISRA C is a C standard and much of it (its type rules, its ban on parts of the
  preprocessor) is C-specific and simply moot in Zig. Zig supplies at the language level several
  things MISRA bolts on: defined integer-overflow behavior, exhaustive `switch`, no implicit
  narrowing, `comptime` in place of the preprocessor. Where MISRA and Tiger Style agree, adopt; where
  MISRA is patching C, Zig has usually already removed the wound.

---

# Part 2 — Deterministic Simulation Testing (the VOPR)

## 2.1 What the VOPR actually requires

Stated plainly by the source, so each requirement can be checked against firmware reality:

1. **Determinism from seed + commit.** "our simulator is deterministic based on a _seed_ number and
   the Git commit, we can perfectly reproduce any bugs discovered in testing" (vopr.md).
2. **A clean seam between logic and I/O.** "all non-deterministic parts of the system are stubbed
   out. This includes the clock, network, and disk operations" (vopr.md).
3. **Simulated, fast-forwardable time.** "VOPR can speed up time arbitrarily. One minute of VOPR time
   is equivalent to days of real-world testing" (vopr.md).
4. **Seeded fault injection.** "a random seed to tune parameters for injecting different types of
   faults … drop and reorder packets, partition the network, or corrupt reads and writes to the
   'disk'" (vopr.md).
5. **A workload and checks.** "commits several hundred batches of operations and checks that they are
   applied as expected" (vopr.md).
6. **Assertions as the in-band oracle.** "Simulation testing pairs particularly well with
   TigerBeetle's heavy use of assertions … If any assertion is broken … the simulation will crash"
   (vopr.md).
7. **Out-of-band checkers.** "the simulator also includes a variety of additional checkers that
   verify the correctness of the cluster's state" — e.g. data files "byte-for-byte identical across
   caught-up nodes" (vopr.md).

## 2.2 Mapping the requirements onto firmware

| VOPR requirement | Firmware translation | Transfer |
|---|---|---|
| Determinism from seed+commit | Firmware *logic* is deterministic if I/O is seam'd out; the blinky is nearly so already, except it reads live hardware | **Modified** — needs the seam (§2.3) |
| Stub clock/network/disk | Stub the timer, and the *peripherals*: registers, sensors, buses | **Modified**, and gated on structure |
| Simulated, fast time | A host build runs millions of blink-periods per second vs. 1/sec on the bench | **Direct** as a benefit, once the seam exists |
| Seeded fault injection | Firmware's faults: I²C NACK, sensor garbage, brown-out mid-write, flash bit-flip, ADC noise | **Modified** — the fault *catalog* is domain-specific |
| Workload + checks | Drive inputs, assert outputs/state on the host | **Direct** in principle |
| Assertions as oracle | The same assertions from Part 1, now firing in sim instead of on silicon | **Modified** — see §1.5 |
| Out-of-band checkers | Host checks over state/artifact; the repo already has one in CI | **Direct** — already partially present (§2.5) |

## 2.3 The seam is the crux — and the blinky deliberately doesn't have it

Requirement 2 is the load-bearing one, and it is where firmware structure decides everything. The
VOPR works because TigerBeetle talks to an *injected* clock, network, and disk rather than reaching
out to the real ones. **The blinky does the exact opposite, on purpose:** it reaches straight out to
the world with hardcoded pointers —

```zig
const PIOB_SODR: *volatile u32 = @ptrFromInt(0x400E1030);
```

— and writing to `0x400E1030` is not something a host simulator can intercept. As written, the blinky
is **not simulatable**, and at its size that is the *right* call — a hardware-abstraction seam would
be pure overhead for four register pokes. But it means the first prerequisite for *any* DST in this
repo is a structural change the blinky does not need and should not carry: **the "world" (registers,
timers, peripherals) must be injected as a dependency rather than reached out to**, so a host build
can substitute a simulated world. This is the embedded analog of TigerBeetle's clock/network/disk
seam, and it is the single biggest finding of Part 2. Nothing else in DST is reachable until it
exists.

Concretely, that means a small hardware-abstraction interface — the peripheral operations a project
needs, expressed as something a real backend (`@ptrFromInt` writes) and a simulated backend (a struct
the test drives) both implement. Zig's `comptime` makes this close to zero-cost at runtime, so the
seam need not tax the flash budget the way a vtable-heavy HAL would. (→ follow-up story.)

## 2.4 The fault catalog is different, and mostly has nowhere to land yet

The VOPR injects packet drops, partitions, and disk corruption (requirement 4). Firmware's world of
faults is just as hostile but different in kind — the issue names them well: a sensor returning
garbage, an I²C NACK, a brown-out mid-write, a flash bit-flip. All of these are **modelable on the
host** — *if* the seam of §2.3 exists, so the simulated backend can return a NACK or a corrupt sample
on a seeded schedule.

The blunt observation that drives the worth-it verdict: **the blinky has almost no I/O surface for
faults to land on.** Its entire interaction with the world is disabling the watchdog, clocking PIOB,
claiming a pin, and toggling it on a timer — four register writes and one poll, with *no
data-dependent control flow*. There is no sensor to feed garbage to, no bus to NACK, no parse to
fuzz, no state to corrupt and recover. Fault injection is powerful in proportion to the number and
nastiness of the interactions it can perturb, and here that number is ~zero. This is not a knock on
the blinky; it is the measurement that answers §2.7.

## 2.5 What the repo already has — DST's cheapest end, reinvented

Two pieces of the VOPR are *already present* in this repo, in miniature, which is the strongest
evidence the technique is congruent with the work:

- **An out-of-band checker (requirement 7).** CI's **"Assert the reset vectors are sane"** reads the
  built binary and asserts invariants over it (SP = top of SRAM0, reset vector in flash bank 0, Thumb
  bit set). That is precisely a VOPR-style checker — an independent oracle verifying state the
  program's own control flow would not catch — running in the existing Dagger/CI flow. The repo built
  the cheapest, highest-value end of DST (static checkers over the artifact) without needing the
  simulator at all.
- **Assertions as oracle (requirement 6), keeping them on in production (§Assertions and Checkers:
  "it keeps these assertions on, even in production").** The blinky keeps its fault and panic traps
  live in `ReleaseSmall` — small enough to afford — which is a proof-of-concept that "assertions on
  in production" is affordable on this target *when the handler is a bare trap* (§1.5.2). The
  expensive part TigerBeetle can take for granted (a formatted crash) is exactly what does not fit
  here.

What is missing is the connective tissue: **there is no host test step at all.** The CI comment
records that the `zig` module's `check` "does not compile" and so was replaced with a plain `build`;
the consequence is that the repo has no place to run host-side logic tests, seeded or otherwise. The
Zig toolchain cross-compiles trivially and Dagger already drives it, so the *infrastructure* to run
host tests exists and is simply unused — because, again, there is nothing at blinky scale worth
testing that way (→ follow-up stories 2.6 and the sim story).

## 2.6 What a passing simulation cannot prove — a thesis this repo already wrote

The issue asks what can be proven in simulation and what only real hardware can prove, and points at
the blinky's own "an indicator can lie" argument. That argument answers the question precisely, and
it is worth making explicit because it is the guardrail on the whole endeavor:

**A passing host simulation is itself an indicator that can lie.** It proves the firmware *logic* is
correct *given the modeled hardware* — nothing more. Everything hard about this board lives in the
gap between the model and the silicon, and that gap is exactly where this repo has already been
burned:

- The watchdog is **enabled out of reset** with a ~16 s timeout, and `WDT_MR` is **write-once**. A
  host model that forgets this passes; the board reset-loops.
- **PIO writes are silently dropped** while the peripheral clock is gated. A model that lets a pin
  write "take" unconditionally passes; the pin never moves.
- **bossac 1.9.1** reported "a clean write, a clean verify, and `Boot Flash: true`" on a board that
  never ran an instruction. Every green signal was accurate; none meant the board worked.

That last one is the whole point in one sentence: the repo has *lived* the failure mode where a
passing check means nothing, and documented it. So the boundary is clean and non-negotiable: **DST
and on-hardware validation are complementary, not substitutes.** Simulation is where you get
determinism, fast-forwarded time, seeded reproduction, and fault injection cheaply and in volume; it
can never certify the hardware model itself. The repo's existing CI already respects this — it stops
at "render the flash command" and "assert the vectors," and leaves the "does it actually blink after
a power-cycle" to a human with a board, precisely because the human with the board is testing the one
thing CI structurally cannot.

## 2.7 Is DST worth it at *this* repo's scale? — the required verdict

**For the blinky: no, and it is not close.** The cost is a hardware-abstraction seam (§2.3), a host
simulator, a fault catalog, and a test harness. The surface it would test is four register writes,
one timer poll, and zero data-dependent branches (§2.4). The one host-checkable invariant that
actually matters — that the reset vectors are well-formed — is *already* checked in CI without any of
that machinery (§2.5). Building the VOPR apparatus for a blinky would be cargo-culting the famous
project, which is the exact failure the issue warns against.

**The threshold — what would flip the verdict.** DST starts paying for itself when a project has:

1. **a non-trivial state machine or protocol** — something with enough logic that reproducing a bug
   by seed is worth more than the seam costs to build;
2. **multiple fallible I/O interactions where ordering and faults matter** — sensors, buses,
   persistence — so injected faults have somewhere to land;
3. **state that must survive faults** — anything with a recovery path (a brown-out mid-write, a
   retried transaction) is exactly what fault injection is *for*;
4. **a debugging cost that has become the bottleneck** — when "reproduce it on the board" is slow,
   flaky, or destructive enough that deterministic host replay is the cheaper path.

The blinky hits none of these. The **`steth-*` stories (#5, #6, #7)** are the first plausible
candidates: a device that acquires sensor data, does something with it, and likely speaks a protocol
will cross criteria 1, 2, and probably 3. **The recommended posture is a staircase, not a leap** —
build the pieces in cost order, stopping at whatever rung the current project justifies:

| Rung | What | Cost | Worth it… |
|---|---|---|---|
| 1 | Compile-time assertions (§1.5.3) | ~zero | **Now.** Already started; generalize. |
| 2 | Flash-cheap runtime assert + safe-state policy (§1.5.1–2) | low | **Now.** Enables Part 1's density guidance. |
| 3 | Host-side static checkers over the artifact (§2.5) | low | **Now.** Generalize the reset-vector check. |
| 4 | A hardware-abstraction seam (§2.3) | medium | **At the first stateful project.** Enables everything above rung 4. |
| 5 | Host unit tests of firmware logic (§2.5) | medium | With the seam. Wire `zig build test` into Dagger/CI. |
| 6 | Seeded fault injection + a simulated world (§2.1–2.4) | high | **When a project crosses the threshold** (likely `steth-*`). |

Rungs 1–3 are worth doing regardless of DST — they are just good bare-metal practice that Tiger Style
happens to codify. Rung 4 is the pivot: it is the one investment that unlocks the rest, and it should
be made the first time a project is complex enough that its *logic* is worth testing off-hardware.
Rung 6 — the actual VOPR analog — is worth building only past the threshold, and its natural home is
the flow the repo already has: Zig cross-compiles the logic, Dagger runs it on the host, a failing
seed plus the commit hash reproduces any bug exactly, just as vopr.md describes.

---

# Follow-up stories

The payoff. These have now been **filed** (issues [#11]–[#20]) and are the actionable output of this
research; none are implemented here, which is deliberately out of scope. Two things to note about how
they are written:

- **Architecture-neutral by design.** This repo will hold projects spanning many different targets
  (ARM Cortex-M, RISC-V, AVR, and whatever comes next), so each story states its convention
  *generally* and treats today's `arduino-due/blinky` only as the *current reference instance* — an
  example of the shape, never the definition. Where a story references shared infrastructure (the
  Dagger build/flash flow, the `zig` module, CI), that is repo-wide and applies to every project.
- **Ordered by the staircase in §2.7** — cheap, broadly-useful rungs first; the full simulator last
  and gated on a project crossing the complexity threshold.

1. **[#11] — flash-cheap `assert` with a defined failure state.**
   An assertion primitive that lowers to a bare trap — no formatting, no stack walk, no panic
   machinery — so the density guidance becomes affordable inside any tight code budget, on any
   architecture. Must define behavior in optimized/size-optimized builds (on vs. off), behavior
   inside an interrupt/exception context, and the per-project *safe state* it fails into (delegated to
   the policy in #12, not hardcoded to "halt"). The blinky's halt-on-fault handler is the current
   example of the shape. *Grounds:* Tiger Style §Safety assertions; blinky `panic`/`defaultHandler`;
   §1.5.1–2 above.

2. **[#12] — per-project assertion & fault policy: halt vs. safe-state vs. reset.**
   A short written policy answering, per project, what "crash on corrupt state" *does* on that device,
   since the safe failure state is device-dependent and not universal — halting is safe where the
   worst outcome is an idle output and dangerous where an output is left energized. The blinky's
   "halt, never reset" is one filled-in instance of the template, not the rule. *Grounds:* Tiger Style
   "the only correct way to handle corrupt code is to crash"; §1.5.1.

3. **[#13] — codify a TigerStyle-derived Zig style guide, with embedded carve-outs.**
   Capture the directly-transferable, language/architecture-general rules (snake_case, no
   abbreviations, units-last, no recursion, explicitly-sized types over `usize`, ~70-line functions,
   split assertions, "always say why") plus the bare-metal riders documented in Part 1 (what "crash"
   means with no OS, interrupt-context assertion behavior, poll-vs-interrupt control flow, prefer
   compile-time assertions). Written to apply across targets. *Grounds:* Tiger Style
   §Developer-Experience and §Safety; §1.8–1.10.

4. **[#14] — enforce strictest compiler warnings and a line-length limit across projects.**
   Turn on the compiler's strictest diagnostics (warnings fail the build) and add a line-length gate
   alongside the existing `zig fmt --check` step, in the shared CI pipeline so the mechanical half of
   the style guide is enforced for every project, not just one board. *Grounds:* Tiger Style "all
   compiler warnings at the compiler's strictest setting" and the 100-column rule; existing `ci.yaml`
   fmt step; §1.10.

5. **[#15] — readback/pair-assertion helpers for peripheral register configuration.**
   Reusable write-then-verify helpers for *any* memory-mapped target: after configuring a peripheral,
   read back the corresponding status register and assert the change took, catching the silent-no-op
   class of failure (a write dropped because a clock is gated, a register is write-protected, or an
   address is wrong — none of which signal an error). Must document where readback is invalid
   (write-only and read-to-clear registers). *Grounds:* Tiger Style pair-assertions; the blinky's
   documented "writes are silently dropped" trap as one example; §1.5.4.

6. **[#16] — generalize the image sanity-check into a reusable artifact checker.**
   Lift CI's inline "Assert the reset vectors are sane" step into a typed, reusable checker (a Zig
   program or a Dagger module function) **parameterized by each target's memory map**, and extend it
   — image fits the code region, initialized-data/zero-init sections as expected, entry/stack pointers
   in bounds — so every project gets host-side static checks over its built image by supplying config,
   not by editing the checker. Removes the one ad-hoc tool in an otherwise standardized pipeline.
   *Grounds:* Tiger Style §Tooling; VOPR out-of-band checkers; §1.12, §2.5.

7. **[#17] — add a host test step to the shared build/CI flow.**
   Wire a host test step (`zig build test` / the `zig` module's test verb) into CI — the repo has no
   test step today — and seed it with the free wins: compile-time invariant checks and pure-logic unit
   tests. Target-agnostic: projects for any architecture can contribute host tests. Establishes the
   place seeded simulation later plugs into. *Grounds:* VOPR requirements 5/6; the `ci.yaml` "no test
   step" note; §2.5, staircase rungs 1 & 5.

8. **[#18] — hardware-abstraction seam so firmware logic is host-compilable.**
   Express the peripheral operations a project needs as an injectable interface with a real backend
   (`@ptrFromInt` writes) and a host backend (a stand-in the tests drive), using `comptime` to keep it
   runtime-free. The interface is defined by what a project needs to *do*, not by one board's register
   map, so it serves many architectures. This is the pivot investment that makes any deterministic
   simulation possible; scope it to the first project whose logic is worth testing off-hardware, not
   to trivial firmware. *Grounds:* VOPR "all non-deterministic parts … are stubbed out"; §2.3,
   staircase rung 4.

9. **[#19] — seeded host simulator with fault injection for the first stateful project.**
   Once a project crosses the §2.7 threshold (the `steth-*` work is the current candidate), build the
   VOPR analog on top of the seam (#18): a simulated world driven by a seeded PRNG that injects
   firmware-shaped faults (bus errors/NACKs, garbage inputs, power loss mid-write, storage bit-flips,
   noisy readings), running on the host through the shared flow, with any failure reproducible from
   seed + commit. The fault model is expressed generally and instantiated for the project's actual
   peripherals. Explicitly gated: file it *for* that project, not before. *Grounds:* VOPR requirements
   1–4; §2.4, §2.7, staircase rung 6.

10. **[#20] — per-project resource budget (code, RAM, timing, electrical).**
    Re-derive Tiger Style's back-of-the-envelope resource sketch for the resources that actually bind
    firmware, as general categories each project fills in for its own silicon — code footprint,
    working memory, timing/cycles, and electrical/I/O limits. The blinky README's ad hoc figures
    (image size, Debug overflow, timer-reload width, per-pin current) are one worked example. Makes
    "bound every resource at design time" a checklist, not folklore. *Grounds:* Tiger Style
    §Performance back-of-envelope sketches; blinky README; §1.2, §1.4.

[#11]: https://github.com/Zaba505/embedded/issues/11
[#12]: https://github.com/Zaba505/embedded/issues/12
[#13]: https://github.com/Zaba505/embedded/issues/13
[#14]: https://github.com/Zaba505/embedded/issues/14
[#15]: https://github.com/Zaba505/embedded/issues/15
[#16]: https://github.com/Zaba505/embedded/issues/16
[#17]: https://github.com/Zaba505/embedded/issues/17
[#18]: https://github.com/Zaba505/embedded/issues/18
[#19]: https://github.com/Zaba505/embedded/issues/19
[#20]: https://github.com/Zaba505/embedded/issues/20

---

*Read the sources, not this summary of them, before acting on any of it — both are first-hand and
opinionated, and second-hand write-ups (including this one) drift. The two documents linked at the
top are the required spine.*
