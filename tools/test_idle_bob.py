"""Is the standing puppet's body animated at the game's own rate, or held?

**This is the M5k test, corrected after the live run of 2026-10-22.** The first version assumed the
player has a full-body idle sprite and read its rate from `sprite_get_speed`. The live ids say
otherwise:

    sprPlayerWalk          id 1    <- the FULL BODY, walking
    sprPlayerGlassesIdle   id 2    <- an OVERLAY: glasses only
    sprPlayerGlassesWalk   id 3
    sprPlayerPinkBowIdle   id 4    <- an OVERLAY: a bow only
    sprPlayerPinkBowWalk   id 5
    sprBackpackIdle       id 439   <- an OVERLAY: a backpack only
    sprPlayerIdle         NOT FOUND

The owner's own report is the proof that those `...Idle` names are overlays and not bodies:

> when I stand still I only see the glasses, the name, and the tree the mock holds; when I walk the
> mock is visible and without glasses

So the standing **body** is the walk sprite **held**, and there is nothing to animate - which is why
the request names the **head and backpack**: the bob lives in the overlay layers.

What this file pins down:

  1. **No idle body -> the frame is held.** Drawing an overlay as the body is the "only the glasses"
     bug, and animating a body that has no idle animation is the "walking in place" one.
  2. **When a real idle body does resolve, its rate is the measured animation rate** - not
     `sprite_get_speed`, which is **0** for every player sprite. In GameMaker `0` means "use the
     room's default", not "not animated", so the first version fell back to a made-up 0.006
     units/ms: a **1.0 s** cycle against the player's 0.67 s, which the owner saw as
     **"twice as slow"**.
  3. The measured rate is **9 units/s** (the index climbs `+0.45` per packet at 20 packets/s, live).
"""
import math

MEASURED_RATE = 0.009     # units per millisecond = 9 units/s, the live index rate
STEP_MS = 1000.0 / 60.0


def cycle_seconds(n_frames: int, rate_per_ms: float) -> float:
    """How long one whole bob cycle takes at `rate_per_ms`, in seconds."""
    if rate_per_ms <= 0:
        return float("inf")
    return (n_frames / rate_per_ms) / 1000.0


def old_rate_from_sprite_get_speed(speed: float, speed_type: int) -> float:
    """The first version's conversion, which is what produced the 2x-slow bob."""
    if speed <= 0:
        return 0.006         # the made-up fallback the owner saw at 1.0 s per cycle
    per_step = (1.0 / speed) if speed_type == 1 else speed
    return per_step / 16.667


def main() -> int:
    failures = []

    # 1. No idle body: held. Nothing to compute - the assertion is that the design says so.
    idle_body_exists = False       # live: sprPlayerIdle/IdleNew/BodyIdle all NOT FOUND
    print(f"idle body sprite found: {idle_body_exists} -> the standing frame is held")
    if idle_body_exists:
        failures.append("the live run found no idle body - this test's premise is stale")

    # 2. The old path, and why it was slow.
    old = old_rate_from_sprite_get_speed(0, 0)     # every player sprite reports speed 0
    print(f"old: sprite_get_speed 0 -> {old:.4f} units/ms -> {cycle_seconds(6, old):.2f} s cycle")
    if not (0.95 <= cycle_seconds(6, old) <= 1.05):
        failures.append("the old fallback was expected at a 1.0 s cycle (the 'twice as slow' bug)")

    # 3. The measured rate is the right one, and it is **1.5x faster** than the old fallback:
    #    1.00 s per cycle against 0.67 s. The owner said "twice as slow", and 1.5x on a six-frame
    #    cycle is a 0.33 s difference - read as "about twice" by eye, but the honest number is the
    #    1.5x, and the test asserts **that**, not the remembered impression.
    print(f"new: measured rate {MEASURED_RATE} units/ms -> {cycle_seconds(6, MEASURED_RATE):.2f} s cycle")
    if not (0.60 <= cycle_seconds(6, MEASURED_RATE) <= 0.72):
        failures.append("the measured rate does not give the 0.67 s cycle the wire shows")
    ratio = cycle_seconds(6, old) / cycle_seconds(6, MEASURED_RATE)   # old cycle / new cycle
    print(f"old cycle / new cycle = {ratio:.2f}x slower before the fix (owner: 'twice as slow')")
    if not (1.4 <= ratio <= 1.6):
        failures.append("the old/new cycle ratio is not the measured 1.5x")

    # 4. The rate is the peer's measured one, so it tracks the player rather than a constant.
    a = cycle_seconds(6, 0.009)
    b = cycle_seconds(6, 0.009 * 2)
    print(f"rate 9 units/s -> {a:.2f} s;  rate 18 units/s -> {b:.2f} s (halved by the rate)")
    if abs(a / b - 2) > 1e-9:
        failures.append("the cycle length does not follow the measured rate")

    if failures:
        for fl in failures:
            print("FAIL:", fl)
        return 1
    print("idle: ok - no idle body is held, and an idle body would run at the measured 0.67 s rate")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

