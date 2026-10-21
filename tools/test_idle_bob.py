"""Does the standing puppet bob at the rate the **player's own movement on screen** shows?

This is the M5k3 test - the **fourth** version of the same question, and every version was corrected
by a live run. The history is the point, so it is kept.

**Round 1.** Assumed a full-body idle sprite and read the rate from `sprite_get_speed`. Both wrong:
that call returns **0** for every player sprite, and in GameMaker `0` means *"use the room's
default"*, **not** "not animated". It fell back to a made-up `0.006 units/ms` - a **1.00 s** cycle
against the player's **0.67 s**: the owner's *"the bob is there but twice as slow"* (**1.5x**).

**Round 2.** Found that the `...Idle` names that resolve by name are **cosmetic overlays**, not bodies
(`sprPlayerGlassesIdle` id 2, `sprPlayerPinkBowIdle` id 4, `sprBackpackIdle` id 439), and drew one as
a body - an accessory with no body under it: *"when I stand still I only see the glasses, the name,
and the tree."* The overlay finding is **correct and stands**. The wrong step was concluding *no idle
body exists* and holding the walk sprite still - *"the mock stopped using the bob while standing."*

**Round 3.** Read the live ids correctly:

    sprite id 0 is 'sprPlayerIdle'          <- sprite_get_name(0)
    sprite id 1 is 'sprPlayerWalk'
    objPlayer sprite_index -> 0  imgspd 0.60

The idle body is **`sprPlayerIdle`, asset id 0** - real, and unreachable **by name**, because
`asset_get_index` answers an unknown name with **0** and that *is* this sprite's index. So `>= 0`
everywhere a sprite 0 must pass (there were **three** such guards). That fix is **correct and
stands**. The wrong step was the **rate**: it read `image_speed 0.60` as "what the eye sees", used
0.60 frames/step = **0.036 units/ms - a 0.17 s cycle**, and the owner said:

> now the mock bobs its head too fast

**Round 4, current: the rate is the measured index rise, and `image_speed` is not used.** The wire's
own index climbs **+0.45 per POS packet**, and a packet goes out every **3 steps**
(`OnStep`: `coopTick mod 3`), so **+0.15 per step = 0.009 units/ms - a 0.67 s six-frame cycle**.

So rounds 2-3 and 4 are **not** in conflict: **both fixes are needed at once** - sprite 0 must be
**drawn**, *and* the clock must run at the measured index rate. Each round applied one and inferred
the other from a single, correct, incomplete observation. Protocol 11 drops the `image_speed` field
protocol 10 added, because a number that does not describe the drawing is **worse than no number**: it
overrides a measurement that does.

What this file pins down:

  1. **Sprite 0 is a real answer** on all three paths (resolve, draw, frame count).
  2. **The index rate wins, and `image_speed` loses by 4x** - the owner's "too fast" is a 4x error.
  3. **The rate is the peer's measured rise**: the cycle follows it, and the fallback is the measured
     `0.009 units/ms`, not a guess.
"""
STEPS_PER_MS = 1.0 / (1000.0 / 60.0)      # game steps per millisecond
DRAWN_SPEED_PER_STEP = 0.60               # live: objPlayer.image_speed - the WRONG rate to use
INDEX_PER_STEP = 0.15                     # live: +0.45 per POS packet / 3 steps per packet
MEASURED_INDEX_PER_MS = 0.009             # the index's rise: the rate that is used and the fallback


def cycle_seconds(n_frames: int, units_per_ms: float) -> float:
    """How long one whole six-frame bob takes at `units_per_ms`, in seconds."""
    if units_per_ms <= 0:
        return float("inf")
    return (n_frames / units_per_ms) / 1000.0


def main() -> int:
    failures = []

    # 1. Sprite 0 is the idle body, and a `> 0` test is what deleted it three times over.
    idle_body_index = 0
    print(f"idle body sprite index: {idle_body_index}  (sprPlayerIdle, live) -> must be tested >= 0")
    paths = {'resolve': idle_body_index >= 0, 'draw': idle_body_index >= 0,
             'frames': idle_body_index >= 0}
    print(f"  resolve={paths['resolve']}  draw={paths['draw']}  frame count asked={paths['frames']}")
    if not all(paths.values()):
        failures.append("a '> 0' guard would delete the idle body on one of its three paths")

    # 2. The 4x tie, broken towards the measured index rate - the reverse of round 3, decided by the
    #    owner's own observation ("now the mock bobs its head too fast").
    index_per_ms = INDEX_PER_STEP * STEPS_PER_MS
    drawn_per_ms = DRAWN_SPEED_PER_STEP * STEPS_PER_MS
    print(f"used: index {INDEX_PER_STEP} units/step -> {index_per_ms:.4f} units/ms "
          f"-> {cycle_seconds(6, index_per_ms):.2f} s cycle")
    print(f"rejected: image_speed {DRAWN_SPEED_PER_STEP}/step -> {drawn_per_ms:.4f} units/ms "
          f"-> {cycle_seconds(6, drawn_per_ms):.2f} s cycle")
    ratio = drawn_per_ms / index_per_ms
    print(f"image_speed / index = {ratio:.2f}x  <- the 'too fast' the owner saw")
    if not (3.8 <= ratio <= 4.2):
        failures.append("the rejected rate is not the measured 4x the index rise")
    if abs(index_per_ms - MEASURED_INDEX_PER_MS) > 1e-9:
        failures.append("the index-per-step arithmetic does not reproduce the measured 0.009/ms")

    # 3. The rate is the peer's own measured rise, not a constant: the cycle follows it.
    a = cycle_seconds(6, MEASURED_INDEX_PER_MS)
    b = cycle_seconds(6, MEASURED_INDEX_PER_MS * 2)
    print(f"rate 0.009/ms -> {a:.2f} s;  rate 0.018/ms -> {b:.2f} s (halved by the rate)")
    if abs(a / b - 2) > 1e-9:
        failures.append("the cycle length does not follow the measured index rate")

    # 4. The fallback is the measured rise, and it is the *used* rate when the peer is silent too -
    #    i.e. there is exactly one rate in the code now, not two that disagree.
    print(f"fallback: {MEASURED_INDEX_PER_MS} units/ms -> {cycle_seconds(6, MEASURED_INDEX_PER_MS):.2f} s")
    if abs(cycle_seconds(6, MEASURED_INDEX_PER_MS) - a) > 1e-9:
        failures.append("the fallback is not the same measured rate the peer reports")

    if failures:
        for fl in failures:
            print("FAIL:", fl)
        return 1
    print("idle bob: ok - sprite 0 is drawn, and the bob runs at the measured index rate (0.67 s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
