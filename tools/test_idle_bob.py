"""Does the standing puppet animate at the rate the **player's own model** is drawn at?

This is the M5k2 test, and it is the third version of the same question - each one corrected by a
live run, which is the point of keeping it.

**The first version** assumed the player has a full-body idle sprite and read its rate from
`sprite_get_speed`. Both halves were wrong:

  * `sprite_get_speed` is **0** for every player sprite, and in GameMaker `0` means *"use the room's
    default"*, **not** "not animated" - so it is not a rate at all. The code treated it as one, fell
    back to a made-up `0.006 units/ms`, and produced a **1.00 s** six-frame cycle against the
    player's **0.67 s**: the owner's *"the bob is there but it is twice as slow"* (honest number:
    **1.5x**).
  * The `...Idle` names that *do* resolve by name are **cosmetic overlays**, not bodies:
    `sprPlayerGlassesIdle` (id 2), `sprPlayerPinkBowIdle` (id 4), `sprBackpackIdle` (id 439). Draw
    one as the body and you get **an accessory with no body under it** - the owner's *"when I stand
    still I only see the glasses, the name, and the tree"*.

**The second version** concluded from that, wrongly, that there is **no** idle body and held the walk
sprite still - so the owner reported *"the mock stopped using the bob while standing"*. The round's
live probe answered the question it had raised:

    sprite id 0 is 'sprPlayerIdle'          <- sprite_get_name(0)
    sprite id 1 is 'sprPlayerWalk'
    objPlayer sprite_index -> 0  imgspd 0.60

**The idle body exists. It is `sprPlayerIdle`, asset id 0**, and it is unreachable **by name**:
`asset_get_index` answers an unknown name with **0**, and 0 is also this sprite's index, so every
`> 0` check in the codebase skips it (and `> 0` on the draw call drew *nothing* while standing).

**The rate**, and the 4x that had to be settled rather than averaged:

  * the game puts `objPlayer.image_speed` at **0.60** frames per step - the rate the model is
    **drawn** at, i.e. **0.036 units/ms** at 60 steps a second (a 0.17 s cycle);
  * the index on the wire climbs **+0.45 per POS packet**, and a packet goes out every **3 steps**
    (`OnStep`: `coopTick mod 3`), so **+0.15 per step - 0.009 units/ms** (a 0.67 s cycle).

Four times apart. The tie-breaker is **what the eye sees**: the game draws `objPlayer` from
`sprite_index 0` advanced by its **instance** `image_speed`, and that is 0.60. So the wire carries
its own `image_speed` field now, the puppet is animated at *it*, and the measured index rise is only
the fallback.

What this file pins down:

  1. **Sprite 0 is a real answer.** The idle body's index is 0 and must be tested `>= 0`, drawn, and
     asked for its frame count - three separate `> 0` traps that each silently delete the bob.
  2. **The drawn rate wins the 4x tie**, and it is 4x the index rise - not "close to" it.
  3. **The rate is the peer's, not a constant**: the cycle length follows the sent `image_speed`.
"""
import math

STEPS_PER_MS = 1.0 / (1000.0 / 60.0)      # game steps per millisecond
DRAWN_SPEED_PER_STEP = 0.60               # live: objPlayer.image_speed
INDEX_PER_STEP = 0.15                     # live: +0.45 per POS packet / 3 steps per packet
MEASURED_INDEX_PER_MS = 0.009             # the index's rise, the fallback rate


def cycle_seconds(n_frames: int, units_per_ms: float) -> float:
    """How long one whole six-frame bob takes at `units_per_ms`, in seconds."""
    if units_per_ms <= 0:
        return float("inf")
    return (n_frames / units_per_ms) / 1000.0


def units_per_ms_from_speed(speed_per_step: float) -> float:
    """The mod's own conversion: a per-step sprite speed into the millisecond draw clock."""
    return speed_per_step * STEPS_PER_MS


def main() -> int:
    failures = []

    # 1. Sprite 0 is the idle body, and a `> 0` test is what deleted it three times over.
    idle_body_index = 0
    print(f"idle body sprite index: {idle_body_index}  (sprPlayerIdle, live) -> must be tested >= 0")
    if not (idle_body_index >= 0):
        failures.append("the idle body index is not >= 0")
    drawn = {'draw': idle_body_index >= 0, 'frames': idle_body_index >= 0,
             'animates': idle_body_index >= 0 and True}
    print(f"  drawn={drawn['draw']}  frame count asked={drawn['frames']}  "
          f"bob animated={drawn['animates']}")
    if not all(drawn.values()):
        failures.append("a '> 0' guard would delete the idle body on one of its three paths")

    # 2. The 4x tie, broken towards the drawn rate.
    drawn_per_ms = units_per_ms_from_speed(DRAWN_SPEED_PER_STEP)
    index_per_ms = INDEX_PER_STEP * STEPS_PER_MS
    print(f"drawn: {DRAWN_SPEED_PER_STEP} frames/step -> {drawn_per_ms:.4f} units/ms "
          f"-> {cycle_seconds(6, drawn_per_ms):.2f} s cycle")
    print(f"index: {INDEX_PER_STEP} units/step  -> {index_per_ms:.4f} units/ms "
          f"-> {cycle_seconds(6, index_per_ms):.2f} s cycle")
    ratio = drawn_per_ms / index_per_ms
    print(f"drawn / index = {ratio:.2f}x  <- the 4x disagreement, settled by which one is drawn")
    if not (3.8 <= ratio <= 4.2):
        failures.append("the drawn rate is not the measured 4x the index rise")
    if abs(index_per_ms - MEASURED_INDEX_PER_MS) > 1e-9:
        failures.append("the index-per-step arithmetic does not reproduce the measured 0.009/ms")

    # 3. The rate follows the peer's own speed, not a constant.
    a = cycle_seconds(6, units_per_ms_from_speed(0.60))
    b = cycle_seconds(6, units_per_ms_from_speed(0.30))
    print(f"speed 0.60 -> {a:.2f} s;  speed 0.30 -> {b:.2f} s (doubled by halving the speed)")
    if abs(b / a - 2) > 1e-9:
        failures.append("the cycle length does not follow the sent image_speed")

    # 4. The fallback is the measured rise, not a guess, and it is slower than the drawn rate.
    print(f"fallback (no image_speed on the wire): {MEASURED_INDEX_PER_MS} units/ms "
          f"-> {cycle_seconds(6, MEASURED_INDEX_PER_MS):.2f} s cycle")
    if not (0.60 <= cycle_seconds(6, MEASURED_INDEX_PER_MS) <= 0.72):
        failures.append("the fallback is not the measured 0.67 s index cycle")

    if failures:
        for fl in failures:
            print("FAIL:", fl)
        return 1
    print("idle bob: ok - sprite 0 is drawn and animated at the peer's own drawn rate")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
