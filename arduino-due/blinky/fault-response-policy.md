# Fault Response Policy — arduino-due/blinky

Completed from the [repo-wide template](../../docs/fault-response-policy.md).

1. **Device & what it controls.** Arduino Due (Atmel SAM3X8E, Cortex-M3). Two outputs with any
   effect on the world, and both are LEDs: `D1` on `PD1` (digital pin 26), active-high,
   current-limited by a 560 Ω series resistor to ~1.2 mA, and `D2` on `PB26` (digital pin 22),
   active-high, current-limited by 1 kΩ to ~1.1 mA.
   There is also one *input* — the current-sense node on `PA15` — which controls nothing. It drives
   nothing else: no motor, heater, radio, bus, or actuator. A held-on or held-off LED can harm
   nothing. (Values and derivations: the [schematic](hardware/due-blinky.kicad_sch).)

2. **Safe state.** All outputs idle: `PD1` and `PB26` low, both LEDs off. This is also the power-on
   default — out of reset both are inputs under the PIO controller, driving nothing — so the safe
   state costs *no code* to reach, and nothing must be actively de-energized. That is why a **trapped**
   fault is a bare halt: the handler can afford to touch nothing, because nothing needs it to.

   The **detected** load fault still drives that state explicitly (field 3). Not because it must be
   reached — it would be reached by doing nothing — but because it must be *unambiguous*. Halting
   with `PD1` frozen wherever the fault caught it leaves a lit red LED next to a lit green one, and
   the reader has to guess. One register write removes the guess.

3. **Fault response.** **Halt** — in two forms, and the difference is which code is still trusted
   when the fault is declared.
   - **Trapped faults** (panic, CPU exception) → **bare halt.** The handler touches no peripheral.
   - **Detected faults** (the load-verification mismatch, field 5) → **safe state → report → halt.**
     Drive `PD1` low, drive `D2`'s pin `PB26` high, then spin.

   A trapped fault arrives from unknown machine state, so the handler must assume nothing and do the
   least it can. A detected fault is different in kind: it is reached from ordinary code, in the main
   loop, with the peripherals up and known-good — the firmware is not broken, the *world* is. That is
   the one situation where writing two registers before halting is both safe and the entire point.

4. **Rationale.** The failure this project exists to rule out is a *reset loop that looks like a
   working blink.* The SAM3X8E watchdog is enabled out of reset with a ~16 s timeout; a board
   resetting every few seconds blinks on its own, and by eye that is indistinguishable from a
   correct 1 Hz blink — the headline test would pass in exactly the case it is meant to catch. So
   `main()` disables the watchdog first, and every fault path ends in `while (true) {}`: a fault must
   **stop the LED dead**, never restart it. Halting is safe here precisely because field 1 has
   nothing dangerous to leave energized.

   *Trapped* paths write no registers at all, so `D1` freezes wherever it was — solid on or solid off
   depending on when the fault hit. Either way it is no longer blinking, which is the signal we want.
   The *detected* path writes exactly two registers first, for the reasons in fields 2 and 3, and
   then halts identically. (Full argument: the project [README](README.md), "Why not the on-board
   LED" and "Verifying it worked".)

   **The halt latches, and that is a feature.** Nothing polls for the fault clearing, so restoring
   the load does not resume the blink — recovery is a deliberate RESET or power cycle. A board that
   recovered silently would erase its own evidence: an intermittent jumper would give a brief `D2`
   flicker you would probably miss, followed by a board blinking happily that had been lying about
   its load part of the time. Latching means the one thing you cannot do is fail to notice.

5. **What counts as a fault.**
   - **Language panic** — `panic()` in [`src/main.zig`](src/main.zig) replaces Zig's default handler
     (which would drag in formatting and stack-trace machinery that does not fit in 256 KB) with a
     halt.
   - **Any CPU exception** — every entry in the vector table in [`src/start.zig`](src/start.zig)
     (`NMI`, the MemManage/hard/bus/usage faults, and the deliberately-wired-but-unused `SysTick`
     slot) points at `defaultHandler`, which halts.
   - **Runtime assertions** — none yet; the flash-cheap assert primitive is [#11]. When added, it
     will halt through this same path, so this policy already defines its behavior.
   - **Load-verification mismatch** — **new, and the only *detected* fault.** After each commanded
     transition [`src/main.zig`](src/main.zig) climbs the schematic's ladder: the output register
     took the write (`PIO_ODSR`), the pad reached the level (`PIO_PDSR`), and then — after a bounded
     1 ms settle window — the current-sense input on `PA15` agrees that `D1` conducted.

     **How "sustained" is measured, and why the obvious way is broken.** A dead load does *not*
     disagree on every transition. It disagrees when commanded **on** and *agrees* when commanded
     **off**, because "not conducting" is the right answer for an LED told to be dark:

     | commanded | on | off | on | off | on |
     |---|---|---|---|---|---|
     | sensed | off | off | off | off | off |
     | verdict | **bad** | ok | **bad** | ok | **bad** |

     So the run of *consecutive* mismatches never exceeds one, and any consecutive-count threshold
     of two or more can never fire — for precisely the fault this exists to catch. The failure
     alternates in step with the blink. Instead the firmware integrates: a disagreeing transition
     (three unanimous samples) adds 2, an agreeing one subtracts 1 saturating at 0, and **4** trips.
     A dead load climbs `2,1,3,2,4` and faults on the fifth transition — about **2.5 s** — while an
     isolated disagreement decays back to zero and is forgotten.

     **The policy, decided: safe state → report → halt.** Not *count and continue*, and the reason
     is this project's whole thesis. The headline evidence is `D1`'s 1 Hz pattern, so a firmware that
     noticed the load was dead and kept blinking anyway would be asserting, with the only channel
     anyone reads, that everything is fine. Counting is what you do when the count will be collected
     later; nothing here collects it. Halting is what stops the lie.

     **The order matters, and it is the interesting part.** *Safe state first:* `PD1` is driven low
     so the reported picture is single-valued — dark red plus solid green is a detected load fault
     and nothing else, where a frozen-*on* red could still be read as "working but stuck". *Report
     second:* `PB26` is driven high, lighting `D2`. This is the only place any firmware drives `D2`,
     and it exists because the fault being reported is *"the load did not light"* — reporting it
     through `D1` would make a halted board and a dead board the same picture. *Halt last*, per the
     rest of this field.

     Note what is deliberately **not** claimed: `D2` lighting proves a fault was detected, but `D2`
     staying dark proves nothing at all — see field 7.

6. **Context caveats.** The firmware is **poll-driven, not interrupt-driven**: SysTick is read via
   its `COUNTFLAG` in the main loop, and the SysTick interrupt vector is wired to the trap precisely
   so that if it ever fires, the board visibly stops instead of blinking on regardless. No fault is
   expected in interrupt context. Any that occurs still halts, and halting is safe *regardless of
   context* here because no output needs to be driven to reach safety — the handler touches no
   peripheral, so there is no init-order or masked-interrupt hazard to design around.

7. **Observability.** A **frozen, unchanging `D1`** — held on or off depending on when the fault
   hit, but in every case *not blinking*: the *absence* of the 1 Hz pattern. The design still
   rejects "an indicator can lie," and a stopped blink is a signal a reset loop cannot counterfeit.

   **`D2` does not weaken that, and it is now on the diagram.** The
   [schematic](hardware/due-blinky.kicad_sch) carries a second LED on its own pin because the
   current-feedback path introduced a fault whose only symptom would otherwise be delivered
   *through the failed load*: if the board detects that `D1` did not light and halts, a halted board
   and a dead board look identical. `D2` may only ever assert **fault** — it never blinks, it is
   never evidence that anything works, and every way it can fail lands on dark, which is also the
   no-fault state. So this field's original rejection of a second indicator stands as written: it
   was aimed at an indicator that would claim *health*.

   **`D2` is now driven, and field 5 records what by.** The three readable outcomes are:

   | `D1` (`D26`, red) | `D2` (`D22`, green) | means |
   |---|---|---|
   | blinking 1 Hz | dark | running, and every transition verified against the sense |
   | **dark** | **solid** | a load-verification mismatch was detected, and the board halted — **latched; RESET to resume** |
   | frozen or dark | dark | a trapped fault (panic / CPU exception), or the board never ran |

   The asymmetry is deliberate and worth stating plainly: **`D2` lit is proof; `D2` dark is not.**
   A broken `D2` — open LED, pulled jumper, dead pin — is indistinguishable from no fault, and that
   is accepted, because the failure direction it protects is the one that matters. You can lose the
   alarm; you can never gain a false one. It also means `D2`'s own channel is unproven until
   something drives it, which is exactly what the by-hand fault injection in the README does.

   To learn *where* it halted, attach a 3.3 V SWD probe (see the README's debug-probe notes); the
   trap loops are tight `while (true) {}`, so the PC sits on the faulting handler.

8. **Reset safety.** Reset is rejected here not because it is physically dangerous but because it is
   *epistemically* dangerous for this project's purpose: a reset re-runs startup, and if the
   watchdog logic were ever wrong it would reproduce the exact false-positive blink the project is
   built to expose. Halt is the one response that cannot produce that lie — which is why this is a
   blinky's answer, and why a device that instead *needs* unattended recovery would reach a
   different, equally deliberate conclusion.

[#11]: https://github.com/Zaba505/embedded/issues/11
