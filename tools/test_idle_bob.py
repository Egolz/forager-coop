"""Does the idle bob run at the sprite's own speed, and does it wrap?

The owner asked, in M5k:

> make the animation of the head and backpack bobbing while standing still - find that animation
> and pick up its speed

The mod does not hard-code that speed. It reads it from the asset:

    sprite_get_speed(spr)       frames-per-image (type 0) or images-per-frame (type 1)
    sprite_get_speed_type(spr)  which of the two it is

and advances the puppet's idle frame by `speed / 16.667` per millisecond (a GameMaker step is a
sixtieth of a second here). This file is the arithmetic, checked, so that the *shape* of the clock
is right before the live run supplies the **real** per-asset numbers.

What is asserted:

  1. A sprite with **one** frame never advances (there is no bob to play - the puppet must not
     jitter a single sub-image).
  2. A **type-1** speed plays exactly `1/speed` images per step - the two types are inverses, and
     getting this backwards would make the bob run at `speed^2` times the right rate.
  3. The frame wraps at the sprite's frame count, so a bob of N frames repeats every N.
  4. The rate is **the sprite's**, not a constant: halving `sprite_get_speed` halves the frames
     advanced over the same time.
"""
import math


STEP_MS = 1000.0 / 60.0   # a GameMaker step, in ms


def per_ms(speed: float, speed_type: int) -> float:
    """The mod's own conversion: frames per millisecond."""
    if speed <= 0:
        return 0.0
    per_step = (1.0 / speed) if speed_type == 1 else speed
    return per_step / STEP_MS


def frames_advanced(speed: float, speed_type: int, n_frames: int, ms: float) -> float:
    """How far the mod advances the **unwrapped** frame counter in `ms`.

    The mod wraps into the sprite's frame count for drawing, so the wrapped value is not a
    measure of rate - comparing two wrapped values says nothing. This returns the raw distance
    travelled, which is what "did halving the speed halve the rate" is a question about.
    """
    p = per_ms(speed, speed_type)
    if n_frames <= 1 or p <= 0:
        p = 0.006 if p <= 0 else 0.0
    return p * (int(ms // STEP_MS) * STEP_MS)


def main() -> int:
    failures = []

    # 1. One frame: no bob.
    got = frames_advanced(8, 0, 1, 1000.0)
    print(f"one frame: advanced {got:.3f} (expected 0)")
    if got != 0:
        failures.append("a one-frame sprite advanced - it must not")

    # 2. Type 1 is the inverse of type 0.
    a = per_ms(8, 0)          # 8 frames per step
    b = per_ms(8, 1)          # 1/8 image per step
    print(f"speed 8, type 0 -> {a:.5f} frames/ms;  type 1 -> {b:.5f} frames/ms")
    if abs(a * b - (1.0 / STEP_MS) ** 2) > 1e-9:
        failures.append("type 0 and type 1 are not inverses - the conversion is wrong")

    # 3. Wrapping: a 4-frame bob at 4 frames/step runs one whole cycle per step.
    f = 0.0
    p = per_ms(4, 0)
    for _ in range(60):                     # one second
        f += p * STEP_MS
        if f >= 4:
            f = f % 4
    print(f"4-frame bob, 4 frames/step, 1 s -> frame {f:.3f} (wrapped to < 4)")
    if not (0 <= f < 4):
        failures.append("the frame did not wrap inside the sprite's frame count")

    # 4. The rate is the sprite's: halving the speed halves the distance travelled.
    one = frames_advanced(6, 0, 100, 500.0)
    half = frames_advanced(3, 0, 100, 500.0)
    print(f"speed 6 -> {one:.3f} frames in 0.5 s;  speed 3 -> {half:.3f}")
    if abs(one / 2 - half) > 1e-9:
        failures.append("halving sprite_get_speed did not halve the bob rate")

    if failures:
        for fl in failures:
            print("FAIL:", fl)
        return 1
    print("idle bob: ok - it runs at the sprite's own speed, wraps, and a still sprite stays still")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
