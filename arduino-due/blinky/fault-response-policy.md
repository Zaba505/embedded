# Fault Response Policy — arduino-due/blinky

Completed from the [repo-wide template](../../docs/fault-response-policy.md).

1. **Device & what it controls.** Arduino Due (Atmel SAM3X8E, Cortex-M3). Exactly one output with
   any effect on the world: a single externally-wired LED on `PB26`, active-high, current-limited by
   a 1 kΩ resistor to ~1 mA. It drives nothing else — no motor, heater, radio, bus, or actuator.
   A held-on or held-off LED can harm nothing.

2. **Safe state.** All outputs idle: `PB26` low, LED off. This is also the power-on default — out of
   reset `PB26` is an input under the PIO controller, driving nothing — so the safe state costs *no
   code* to reach. There is nothing that must be actively de-energized, which is what makes field 3
   a bare **halt** rather than **safe-state → halt**.

3. **Fault response.** **Halt.**

4. **Rationale.** The failure this project exists to rule out is a *reset loop that looks like a
   working blink.* The SAM3X8E watchdog is enabled out of reset with a ~16 s timeout; a board
   resetting every few seconds blinks on its own, and by eye that is indistinguishable from a
   correct 1 Hz blink — the headline test would pass in exactly the case it is meant to catch. So
   `main()` disables the watchdog first, and every fault path is a bare `while (true) {}`:
   a fault must **stop the LED dead**, never restart it. Halting is safe here precisely because
   field 1 has nothing dangerous to leave energized: the trap writes no registers, so the LED
   freezes wherever it was, solid on or solid off depending on when the fault hit. Either way it
   is no longer blinking, which is the signal we want. (Full argument: the project
   [README](README.md), "Why not the on-board LED" and "Verifying it worked".)

5. **What counts as a fault.**
   - **Language panic** — `panic()` in [`src/main.zig`](src/main.zig) replaces Zig's default handler
     (which would drag in formatting and stack-trace machinery that does not fit in 256 KB) with a
     halt.
   - **Any CPU exception** — every entry in the vector table in [`src/start.zig`](src/start.zig)
     (`NMI`, the MemManage/hard/bus/usage faults, and the deliberately-wired-but-unused `SysTick`
     slot) points at `defaultHandler`, which halts.
   - **Runtime assertions** — none yet; the flash-cheap assert primitive is [#11]. When added, it
     will halt through this same path, so this policy already defines its behavior.

6. **Context caveats.** The firmware is **poll-driven, not interrupt-driven**: SysTick is read via
   its `COUNTFLAG` in the main loop, and the SysTick interrupt vector is wired to the trap precisely
   so that if it ever fires, the board visibly stops instead of blinking on regardless. No fault is
   expected in interrupt context. Any that occurs still halts, and halting is safe *regardless of
   context* here because no output needs to be driven to reach safety — the handler touches no
   peripheral, so there is no init-order or masked-interrupt hazard to design around.

7. **Observability.** A **frozen, unchanging LED** — held on or off depending on when the fault
   hit, but in every case *not blinking*: the *absence* of the 1 Hz pattern. There is deliberately
   no second indicator: the entire design rejects "an indicator can lie," and a stopped blink is a
   signal a reset loop cannot counterfeit. To learn *where* it halted, attach a 3.3 V SWD probe
   (see the README's debug-probe notes); the trap loops are tight `while (true) {}`, so the PC sits
   on the faulting handler.

8. **Reset safety.** Reset is rejected here not because it is physically dangerous but because it is
   *epistemically* dangerous for this project's purpose: a reset re-runs startup, and if the
   watchdog logic were ever wrong it would reproduce the exact false-positive blink the project is
   built to expose. Halt is the one response that cannot produce that lie — which is why this is a
   blinky's answer, and why a device that instead *needs* unattended recovery would reach a
   different, equally deliberate conclusion.

[#11]: https://github.com/Zaba505/embedded/issues/11
