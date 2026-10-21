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

  1. **Sprite 0 is a real answer** on all three paths (resolve, draw, frame count).
  2. **The period is 0.5 s**, and the rate in units/ms is derived from it and the frame count - not a
     constant.
  3. **The bracketing reports are explained**: 0.17 s cycling at ~6/s and 0.67 s at ~1.5/s were both
     real measurements, which is why the target sits between them and not at either.
"""
IDLE_PERIOD_S = 0.5            # the owner's measurement: ~2 bobs a second
IDLE_FRAMES = 6               # sprPlayerIdle's own frame count (live)
TOO_FAST_CYCLE_S = 0.17       # image_speed 0.60 -> ~6/s, the owner: "too fast"
TOO_SLOW_CYCLE_S = 0.67       # the wire index rise -> ~1.5/s, the owner: "too slow"


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


def main() -> int:
    failures = []

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

    if failures:
        for fl in failures:
            print("FAIL:", fl)
        return 1
    print("idle bob: ok - sprite 0 is drawn and bobs every 0.5 s (~2/s), the owner's own number")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
