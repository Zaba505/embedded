# Fault Response Policy

*What "crash on corrupt state" actually **does** on a device — a template each project fills in.*

[Tiger Style][tiger-style] gives one universal answer to a detected correctness bug: **"The only
correct way to handle corrupt code is to crash."** A server can afford one answer because every
process fails into the same benign place — it exits, and an orchestrator restarts it. Firmware
cannot. There is no `abort`, no orchestrator, and — the part that matters — **the safe failure state
is a property of what the device controls, not a universal.**

Halting is safe for a device whose worst outcome is an idle output: a blinky's dark LED harms
nothing. Halting is *dangerous* for a device holding a motor, heater, radio, or actuator energized —
freezing the CPU there can leave the output asserted, which may be the single most dangerous state
available. There the correct "crash" is to **drive outputs to a safe state first, then halt or
reset.** So the doctrine transfers, but it forces a decision Tiger Style never has to make: *what is
this device's safe state, and what should a fault do about it?*

That decision cannot be a repo-wide default — this repo's projects will span very different hardware
and risk profiles. It is instead **decided per project, in writing, using the template below**, and
that written policy is the single source of truth for the project's assertion primitive and its
fault/exception handlers (see [How it feeds the code](#how-it-feeds-the-code)).

This document presumes no board, no architecture, and no toolchain. The reference instance
([`arduino-due/blinky`](../arduino-due/blinky/fault-response-policy.md)) is one worked example of
the shape, never the definition.

[tiger-style]: https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md

## The decision is two independent questions

A "fault response" is a composition of two choices, and conflating them is how devices get the wrong
one. Answer both.

**A — Does anything need to *move* before stopping?**
If every output's safe state is already its power-on/idle state, and nothing the device controls is
dangerous while the CPU is stopped, then **no** — the response is simply to stop (or restart).
If any output is, or could be, energized when the fault hits — a motor coil, a heater FET, a radio
transmit enable, an actuator, a bus the device is mastering mid-transaction — then **yes**: the
handler must first **drive those outputs to the safe state.** The terminal action alone is not
enough. Halting with an output held on is the failure this whole document exists to prevent.

**B — Halt or reset once safe?**

| Response | Stops? | Use when |
|---|---|---|
| **Halt** | forever | A silent restart would hide the fault or re-enter the dangerous action, *and* a stuck-off device is safe. This is the strongest anti-false-positive stance: a halted device cannot masquerade as a working one. |
| **Reset** | restarts | Unattended recovery matters more than fault visibility, *and* restarting is provably safe — it does not re-energize a dangerous output and cannot spin a reset loop. A watchdog-driven reset lives here, and note it *fights* halt: you cannot both halt and leave a watchdog armed. |

Compose A and B into exactly one of: **halt**, **safe-state → halt**, **safe-state → reset**,
**reset**. The default is not halt and not reset — it is *the one you can justify from the device's
safe state.*

## The template

Copy this into `<project>/fault-response-policy.md` and fill every field. Delete none: "not
applicable, because …" is an answer; a blank is not.

```markdown
# Fault Response Policy — <project>

Completed from the [repo-wide template](../../docs/fault-response-policy.md).

1. **Device & what it controls.** The board/MCU, and — more importantly — every output that can
   affect the physical world (LED, motor driver, heater, radio, actuator, comms bus it masters). If
   nothing it controls can cause harm or damage when left as-is, say so: that is what makes halting
   safe.

2. **Safe state.** For each output above, the value it must hold once the device stops trusting its
   own logic (de-energized / driven low / high-impedance / bus released). If the hardware's
   power-on/reset default *is* already the safe state (pull-downs, default-off gate), say so — it
   determines whether field 3 needs a "safe-state →" prefix at all.

3. **Fault response.** Exactly one of: **halt** · **safe-state → halt** · **safe-state → reset** ·
   **reset**.

4. **Rationale.** Why that response, in terms of fields 1–2: why this is the safe state, and why
   halting/resetting from it is the least-bad outcome. Name the failure you are ruling out.

5. **What counts as a fault.** The trigger sources that invoke field 3 — at minimum a failed
   assertion, an unhandled CPU fault/exception, and a language panic. Add anything project-specific
   (a watchdog bite, a sensor sanity check, a lost heartbeat).

6. **Context caveats.** What the handler does if the fault fires inside an interrupt/exception
   context, or before clocks/GPIO are up. If reaching the safe state (field 2) needs a peripheral
   that may not be initialized yet, state what the handler does instead.

7. **Observability.** How a person or a supervisor can tell this device has faulted (a dark
   indicator, a distinct blink code, a held-low line, a debug-probe trap, nothing). "Nothing" is a
   decision to state, not omit.

8. **Reset safety.** Is repeatedly resetting this device safe? A reset loop can be benign or
   dangerous (re-energizing an actuator every cycle, hammering a mechanism, masking a fault as a
   healthy-looking restart). This is the check that stops "reset" from being chosen by reflex.
```

Eight short fields; fill them tersely. Fields 1–4 are the core the acceptance criteria require;
5–8 are what make the policy *feed code* rather than sit as prose.

## How it feeds the code

This policy is the single source of truth for three pieces of firmware, and they must all route to
the **same** fault path so the device has exactly one designed failure behavior:

- **The assertion primitive** ([#11]). A failed assertion is a detected corrupt-state event; its
  handler performs field 3. The primitive stays flash-cheap by lowering to a bare branch into that
  fault path — no message formatting, no stack unwind — so the safe-state code (field 2) is the only
  thing it costs.
- **The fault/exception vectors.** Every unhandled CPU exception (hard fault, bus fault, usage
  fault, NMI, and any unused-but-wired vector) points at the same fault path. An exception you did
  not expect is corrupt state by another name.
- **The panic handler.** Language-level panics route there too.

If field 3 is `safe-state → …`, that safe-state code is shared by all three entry points and
therefore must be callable from exception context (field 6): it runs with the main thread suspended,
possibly with interrupts masked, and possibly before initialization finished. Keep it to the minimum
that makes the outputs safe.

## Filled-in instances

| Project | Response | One-line why |
|---|---|---|
| [`arduino-due/blinky`](../arduino-due/blinky/fault-response-policy.md) | **halt** | The only output is an LED, and a reset loop mimics a working blink — so halting is the one response that cannot lie. |

[#11]: https://github.com/Zaba505/embedded/issues/11
