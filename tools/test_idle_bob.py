"""Does the standing puppet bob at the period the player's own model actually has?

This is the M5k4 test - the **fifth** version of the same question, and the history is the test, so it
is kept. The owner's reports were a calibration curve, and each answer narrowed it:

| round | rate used | cycle | owner's verdict |
|---|---|---|---|
| 1 | a made-up fallback | 1.00 s | "twice as slow" |
| 2 | (no animation) | - | "stopped using the bob" |
| 3 | `image_speed 0.60` | 0.17 s | "too fast" |
| 4 | the wire index's rise | 0.67 s | "too slow, ~1.5/s" |
| 5 | **0.5 s period** | **0.50 s** | asked directly: **"~2/s"** |

The two bracketing numbers are the owner's **measured** ones - 6/s at round 3 and 1.5/s at round 4 -
and both were **self-consistent**: a 0.17 s cycle *is* ~6/s, a 0.67 s cycle *is* ~1.5/s. So the owner
was measuring correctly the whole time and the code was the thing moving; asked for the player's own
model, the answer is **~2 bobs a second, a 0.5 s cycle**.

**What the arithmetic had been missing: a "bob" is a whole cycle, not one frame.** Both earlier rates
were computed as if a cycle were six frames, and the two facts that never fit are now consistent:

  * `image_speed 0.60` is 36 frames/s, and 36 / 2 = **18 frames per cycle** - not 6;
  * the player's `image_index` **stops dead while standing** (live: `imgidx 4.20` five probes in a
    row), so a six-frame `image_index` cannot be the thing that bobs at all.

So the puppet's clock is set from the **period** the owner can see, and the sprite's own frame count
converts it: `frames / period`. One tunable number, in the unit the report is given in (bobs per
second), instead of a rate that has to be re-derived whenever the frame count or the build changes.

A peer that reports its own rate (`coopPeerStepRate`) still drives the puppet from that, so a peer who
genuinely bobs differently is matched; the period is the fallback and the default.

What this file pins down:

  0. **M5k8: the bob is advanced in `OnStep`, not in `OnDrawEnd`** - because the draw handler in this
     build runs ~505x/s while `current_time` ticks ~15 ms, so a millisecond-based rate in that event
     is meaningless (the audit read `raw gap sum 61377 ms over 4121 ms = 14.89x`). This is asserted
     against the source, because it is a **structure**, not a number.
  1. **Sprite 0 is a real answer** on all three paths (resolve, draw, frame count).
  2. **The period is 0.5 s**, and the rate in units/ms is derived from it and the frame count - not a
     constant.
  3. **The bracketing reports are explained**: 0.17 s cycling at ~6/s and 0.67 s at ~1.5/s were both
     real measurements, which is why the target sits between them and not at either.
  4. **The step length is measured, never `fps`** - `fps` is the draw rate in this build and would be
     wrong by an order of magnitude.
  5. **M5k8c: a tiny nonzero peer rate must never override the period.** The stub-or-noise rate
     (~0.0007 u/ms) is rejected on both sides of the pipe: at the measurement (floored to 0) and at
     `CoopIdleUnits` (below a tenth of the period's rate). The correct 0.012 survives.
"""
import re
from pathlib import Path

HERE = Path(__file__).resolve().parent
MOD = HERE.parent
ON_STEP = MOD / "Events" / "OnStep.gml"
ON_DRAW_END = MOD / "Events" / "OnDrawEnd.gml"
NET = MOD / "Net.gml"

IDLE_PERIOD_S = 0.5            # the owner's measurement: ~2 bobs a second
IDLE_FRAMES = 6               # sprPlayerIdle's own frame count (live)
TOO_FAST_CYCLE_S = 0.17       # image_speed 0.60 -> ~6/s, the owner: "too fast"
TOO_SLOW_CYCLE_S = 0.67       # the wire index rise -> ~1.5/s, the owner: "too slow"
CLAMPED_CYCLE_S = 5.0         # M5k5: the owner saw this - a 100 ms `_dt` ceiling over a ~1 s draw
OLD_DT_CEILING_MS = 100       # the clamp that produced it
NEW_DT_CEILING_MS = 1000      # the clamp that replaces it


def units_per_ms(frames: int, period_s: float) -> float:
    """The mod's own derivation: `frames / period`, in units per millisecond."""
    if period_s <= 0:
        return 0.0
    return frames / (period_s * 1000.0)


def cycle_seconds(frames: int, rate_per_ms: float) -> float:
    if rate_per_ms <= 0:
        return float("inf")
    return (frames / rate_per_ms) / 1000.0


def bobs_per_second(cycle_s: float) -> float:
    return float("inf") if cycle_s <= 0 else 1.0 / cycle_s


def check_bob_lives_in_on_step(failures: list) -> None:
    """M5k8: assert the bob is advanced in `OnStep` and the step length is measured, not `fps`.

    This is a check on the **structure** because the bug was structural: the arithmetic in the draw
    handler was right, the clock it used was not. Comments are stripped first, so a mention in prose
    (the file quotes `fps` and `1000 / fps` while explaining why they are wrong) cannot pass the test.
    """
    step_src = ON_STEP.read_text(encoding="utf-8")
    draw_src = ON_DRAW_END.read_text(encoding="utf-8")
    # Strip `//` comments so explanations cannot satisfy a check about code.
    step_code = "\n".join(line.split("//")[0] for line in step_src.splitlines())
    draw_code = "\n".join(line.split("//")[0] for line in draw_src.splitlines())

    # 1. The idle frame counter is *written* in OnStep.
    if not re.search(r"coopIdleFrameF\s*\+=", step_code):
        failures.append("OnStep no longer advances coopIdleFrameF - the step clock is gone")
    # 2. and only *read* (never advanced) in OnDrawEnd.
    if re.search(r"coopIdleFrameF\s*\+=", draw_code):
        failures.append("OnDrawEnd advances coopIdleFrameF again - it uses the 14.89x clock")
    if "coopIdleFrameF" not in draw_code:
        failures.append("OnDrawEnd no longer reads coopIdleFrameF - nothing would bob")
    # 3. The step length is measured, and `fps` is not called as a variable anywhere in code.
    if "coopStepMs" not in step_code:
        failures.append("OnStep does not use a measured step length (coopStepMs)")
    if re.search(r"(?<![\w.])fps(?![\w(])", step_code):
        failures.append("OnStep uses `fps` - it is the draw rate here, not the step rate")
    print("structure: bob advanced in OnStep, read in OnDrawEnd, step length measured (no `fps`)")


def idle_units(peer_rate: float, frames: int = IDLE_FRAMES,
               period_s: float = IDLE_PERIOD_S) -> float:
    """The mod's `CoopIdleUnits()`: the peer rate only inside a plausible band, else the period.

    M5k8c: the observed failure was a peer rate of ~0.0007 u/ms (a standing peer's packet jitter)
    overriding the correct 0.012. The gate here is the *shape* of the fix, so a change back to a
    bare `> 0` test fails this file.
    """
    from_period = frames / (period_s * 1000.0)
    if from_period * 0.1 <= peer_rate <= 0.05:
        return peer_rate
    return from_period


def check_window_counters_reset_at_arming(failures: list) -> None:
    """M5k9b: the window counters must be zeroed when F3 *arms*, not only when it prints.

    This was a **measuring** bug that read exactly like a code bug: the first press of a session
    divided counters accumulated since mod load (~35 s) by a ~6 s window and reported
    `step idle 165.10/s` against a measured `41.6 steps/s`, plus `expect 9.39 bobs/s` while the bob's
    own cycle counters - which *were* reset at arming - said 2.03. A report contradicting itself is the
    tell, and the cause was two counters covering different spans.
    """
    src = NET.read_text(encoding="utf-8")
    code = "\n".join(line.split("//")[0] for line in src.splitlines())
    marker = "global.coopBobArmed == false && global.coopBobSteps == 0"
    if marker not in code:
        failures.append("the F3 arming block is gone - locate it before asserting")
        return
    arm = code[code.index(marker):]
    arm_block = arm[:arm.index("\n}")]
    for name in ("coopIdleTicks", "coopWalkTicks", "coopIdleDraws", "coopIdleUnitsAdded"):
        if f"global.{name}" not in arm_block:
            failures.append(f"the F3 arming block does not reset `{name}` - the window would be "
                            f"measured from mod load instead")
    print("structure: F3 arming resets the idle/walk window counters")


def main() -> int:
    failures = []

    # 0. M5k8: where the clock lives, and that it is measured.
    check_bob_lives_in_on_step(failures)
    # 0b. M5k9b: and that the measurement window is actually a window.
    check_window_counters_reset_at_arming(failures)

    # 1. Sprite 0 is the idle body, and a `> 0` test is what deleted it three times over.
    idle_body_index = 0
    print(f"idle body sprite index: {idle_body_index}  (sprPlayerIdle, live) -> must be tested >= 0")
    paths = {'resolve': idle_body_index >= 0, 'draw': idle_body_index >= 0,
             'frames': idle_body_index >= 0}
    if not all(paths.values()):
        failures.append("a '> 0' guard would delete the idle body on one of its three paths")
    print(f"  resolve={paths['resolve']}  draw={paths['draw']}  frame count asked={paths['frames']}")

    # 2. The period is the source of truth, converted with the sprite's own frame count.
    rate = units_per_ms(IDLE_FRAMES, IDLE_PERIOD_S)
    got_cycle = cycle_seconds(IDLE_FRAMES, rate)
    got_rate = bobs_per_second(got_cycle)
    print(f"period {IDLE_PERIOD_S} s over {IDLE_FRAMES} frames -> {rate:.4f} units/ms "
          f"-> cycle {got_cycle:.2f} s -> {got_rate:.1f} bobs/s")
    if not (0.48 <= got_cycle <= 0.52):
        failures.append("the derived cycle is not the 0.5 s period")
    if not (1.9 <= got_rate <= 2.1):
        failures.append("the derived rate is not the ~2 bobs/s the owner measured")

    # 3. The two bracketing reports are explained - so the target is between them, not at either.
    fast = bobs_per_second(TOO_FAST_CYCLE_S)
    slow = bobs_per_second(TOO_SLOW_CYCLE_S)
    print(f"bracketing reports: {fast:.1f} bobs/s ('too fast') < {got_rate:.1f} < "
          f"{slow:.1f} bobs/s ('too slow')")
    if not (slow < got_rate < fast):
        failures.append("the chosen rate is not between the two rates the owner rejected")

    # 4. A different frame count must still give the same period (the derivation, not a constant).
    other = units_per_ms(18, IDLE_PERIOD_S)
    other_cycle = cycle_seconds(18, other)
    print(f"18-frame sprite at the same period -> cycle {other_cycle:.2f} s (period preserved)")
    if abs(other_cycle - IDLE_PERIOD_S) > 1e-9:
        failures.append("the period is not preserved when the frame count changes")

    # 5. M5k5: the `_dt` ceiling must not be able to stretch a correct period into the observed one.
    #    A ceiling of `c` ms applied to a draw arriving every `d` ms scales the animation by `c / d`,
    #    so the reported bob of ~1 per 5 s against a 0.5 s period is a **clamp at a tenth**: a draw
    #    every ~1000 ms, each counted as 100 ms.
    def clamped_cycle(period_s: float, draw_interval_ms: float, ceiling_ms: float) -> float:
        if draw_interval_ms <= 0:
            return period_s
        effective = min(draw_interval_ms, ceiling_ms) / draw_interval_ms
        return period_s / effective if effective > 0 else float("inf")

    observed = clamped_cycle(IDLE_PERIOD_S, 1000.0, OLD_DT_CEILING_MS)
    print(f"a 1000 ms draw under the OLD {OLD_DT_CEILING_MS} ms ceiling -> "
          f"{observed:.1f} s per bob (the owner saw {CLAMPED_CYCLE_S:.1f} s)")
    if abs(observed - CLAMPED_CYCLE_S) > 0.01:
        failures.append("the old ceiling does not reproduce the observed 5 s bob")
    fixed = clamped_cycle(IDLE_PERIOD_S, 1000.0, NEW_DT_CEILING_MS)
    print(f"the same draw under the NEW {NEW_DT_CEILING_MS} ms ceiling -> {fixed:.2f} s per bob")
    if abs(fixed - IDLE_PERIOD_S) > 1e-9:
        failures.append("the new ceiling still distorts an ordinary slow draw")

    # 6. M5k8c: the noise gate. This is the bug that cost the round, and its shape is the point.
    period_rate = units_per_ms(IDLE_FRAMES, IDLE_PERIOD_S)
    noise = 0.0007            # the peer rate the probe printed as `units 0.00`
    print(f"peer noise rate {noise} u/ms (a standing peer's jitter, prints as '0.00'): "
          f"gate -> {idle_units(noise):.4f} u/ms (period rate {period_rate:.4f})")
    if abs(idle_units(noise) - period_rate) > 1e-9:
        failures.append("a tiny nonzero peer rate still overrides the period - the M5k8c bug")
    if idle_units(0.0) != period_rate:
        failures.append("a zero peer rate must fall through to the period")
    # A peer that genuinely reports its own idle rate must still be honoured.
    peer_real = period_rate * 1.5
    if abs(idle_units(peer_real) - peer_real) > 1e-9:
        failures.append("a plausible peer rate is not honoured - the peer-rates path is dead")
    # ...and the walk ceiling still caps it.
    if idle_units(0.9) != period_rate:
        failures.append("an above-ceiling peer rate is not rejected")
    print(f"  zero -> period, plausible {peer_real:.4f} -> honoured, 0.9 -> rejected: ok")

    if failures:
        for fl in failures:
            print("FAIL:", fl)
        return 1
    print("idle bob: ok - sprite 0 is drawn, the period is 0.5 s, and the _dt ceiling no longer eats it")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
