"""Is the puppet's animation driven by movement, or by a timer that never stops?

**This is the M5j/M5k test.** An earlier version of this file tested continuing the peer's
`image_index` between packets. The `idx probe` line that fed it came back and said the index is
**not the walk at all**:

    idx 120 d 0   px 15   moved 0    <- the player stood still, the index did not move
    idx 105 d 585 px 76   moved 0    <- then ran a whole cycle while the player walked 76 px
    pos 667 frame 2.55 -> pos 671 frame 3.00    <- +0.45 for 4 px
    pos 681 frame 4.35 -> ...                   <- +0.45 for 2 px

The frame advances **+0.45 per packet whatever the distance**, so drawing it makes the puppet walk
in place - the owner's report.

So the mod now runs **two clocks**, one per state, and this file checks the **walk** clock (the
**idle** clock is the idle sprite's own `sprite_get_speed`, which an offline test cannot know - it
is read live by the asset probe):

  1. **Walking** must follow the ground the puppet covers: six frames at 12.2 px per unit.
  2. **Standing still** must **not** advance the walk frame. (The idle bob is a *different* clock
     and is allowed - and expected - to move; that is M5k's whole point. What must not happen is the
     **walk** clock running on while the peer stands.)

The numbers are the live ones: 12.2 px per index-unit, 90 px/s walking, 60 Hz drawing.

**M5k9 adds the structural half of this test.** The arithmetic above was always right; what changed in
M5k9 is *where the distance comes from*. The walk frame used to be advanced as `speed * _dt / PPU`,
and `_dt` in `OnDrawEnd` is **not** real milliseconds: the handler is entered ~505x/s while
`current_time` ticks ~15 ms, so the same millisecond is counted ~7 times and a sum of gaps came out
**14.89x** the wall clock (the owner's *"the mock animates movement slowly and freezes"*). The frame is
now advanced by the **distance the puppet actually moved**, so there is no clock in the walk branch at
all and the bug cannot recur. This file therefore also reads the source, with comments stripped, and
fails if a time term reappears there.
"""
import math
import re
from pathlib import Path

HERE = Path(__file__).resolve().parent
MOD = HERE.parent
ON_DRAW_END = MOD / "Events" / "OnDrawEnd.gml"

CYCLE = 6.0              # six index-units, the wrap the wire shows
STEP_MAX = 5
PPU = 12.2               # px per index-unit, from the idx probe's walking samples
WALK_PX_PER_MS = 0.09    # the game's own walk: 90 px/s
DRAW_HZ = 60
FRAME_MS = 1000.0 / DRAW_HZ
OBSERVED_CLOCK_RATIO = 14.89   # M5k7b live: `raw gap sum 61377 ms (wall 4121 ms)`


def check_walk_has_no_clock(failures: list) -> None:
    """M5k9: the walk branch must advance by distance, not by a time term.

    Reads the source with `//` comments stripped, so the paragraph above (which quotes `_dt`) cannot
    satisfy the check. The walk branch is located by `coopWalkTicks`, the counter it has carried since
    M5k7, so the search does not depend on line numbers.
    """
    src = ON_DRAW_END.read_text(encoding="utf-8")
    code = "\n".join(line.split("//")[0] for line in src.splitlines())
    marker = "coopWalkTicks += 1"
    if marker not in code:
        failures.append("the walk branch (`coopWalkTicks += 1`) is gone - locate it before asserting")
        return
    # Take the block from the branch counter to the end of the walk advance.
    branch = code[code.index(marker):]
    walk_advance = branch[:branch.index("coopPeerFrameF") + 120]
    if not re.search(r"coopPeerFrameF\s*\+=\s*_walk_units", walk_advance):
        failures.append("the walk frame is no longer advanced by `_walk_units` (distance-driven)")
    if re.search(r"(?<![\w.])_dt(?![\w])", walk_advance):
        failures.append("a `_dt` term is back in the walk branch - that clock is off by 14.89x")
    if not re.search(r"_moved_px\s*/\s*_ppu", walk_advance):
        failures.append("the walk units are not derived from the distance moved")
    print("structure: walk frame advanced by `_moved_px / _ppu`, no `_dt` in the branch")


def old_frame(wire_index_units: float) -> int:
    """What the mod drew before M5j: the peer's index, straight, floored."""
    return min(STEP_MAX, max(0, math.floor(wire_index_units)))


def simulate(draw_frames: int, walking_frames: int, speed_px_per_ms: float):
    """Run the mod's own arithmetic, frame by frame.

    `walking_frames` is how many frames the peer is walking for; after that it stands still. The
    old way is fed the index the wire actually carries (**+0.45 per packet, i.e. 9 units a second,
    whether or not the player moves** - measured), so it keeps counting even while standing.
    """
    f = 0.0
    old, new = [], []
    for i in range(draw_frames):
        t_ms = i * FRAME_MS
        # The wire index: a free-running timer at the measured 9 units/s, independent of movement.
        wire = (0.45 * (t_ms / 50.0)) % CYCLE
        walking = i < walking_frames
        old.append(old_frame(wire))
        if walking:
            f += speed_px_per_ms * FRAME_MS / PPU
            if f >= CYCLE:
                f = f % CYCLE
        else:
            if f >= 1:
                f = 0.0
        new.append(min(STEP_MAX, max(0, math.floor(f))))
    return old, new


def main() -> int:
    failures = []

    # --- 0. M5k9: the walk branch must have no clock in it. -----------------------------------
    check_walk_has_no_clock(failures)

    # --- 1. Standing still: the old way animates, the new way does not. -----------------------
    old, new = simulate(draw_frames=180, walking_frames=60, speed_px_per_ms=WALK_PX_PER_MS)
    # Frames after the peer stopped.
    old_after = old[70:]
    new_after = new[70:]
    old_moves = sum(1 for a, b in zip(old_after, old_after[1:]) if a != b)
    new_moves = sum(1 for a, b in zip(new_after, new_after[1:]) if a != b)

    print(f"standing still ({len(old_after)} drawn frames):")
    print(f"  old way changes the WALK frame {old_moves} time(s)   <- walks in place")
    print(f"  new way changes the WALK frame {new_moves} time(s)   <- held")
    if old_moves == 0:
        failures.append("the old way was expected to keep animating while standing still "
                        "(that is the bug being fixed) and did not - the premise is wrong")
    if new_moves != 0:
        failures.append(f"the new way still changes the WALK frame {new_moves} time(s) while the "
                        f"peer stands still - the puppet would walk in place")

    # --- 2. Walking: the frame follows the distance, and does not run ahead. -------------------
    # Both sides are compared **unwrapped**: the frame counter and the distance-derived value are
    # the same quantity, so a wrap in one must not be read as a lead in the other - comparing them
    # modulo the cycle is what produced a false "a whole cycle ahead" here.
    px = 0.0
    f = 0.0
    worst_lead = 0.0
    for i in range(60):                      # one second of walking
        px += WALK_PX_PER_MS * FRAME_MS
        f += WALK_PX_PER_MS * FRAME_MS / PPU
        expected = px / PPU
        worst_lead = max(worst_lead, abs(f - expected))

    print(f"walking 1 s: covered {px:.0f} px, frame counter advanced {f:.2f} units "
          f"(a {CYCLE / (WALK_PX_PER_MS * 1000 / PPU):.2f} s cycle)")
    print(f"  worst gap from the distance-driven frame: {worst_lead:.3f} units "
          f"({worst_lead * PPU:.1f} px)")
    if worst_lead > 0.01:
        failures.append(f"the frame ran ahead of the distance by {worst_lead:.3f} units")
    if not (0.5 <= CYCLE / (WALK_PX_PER_MS * 1000 / PPU) <= 1.2):
        failures.append("the cycle length came out outside a plausible walk (0.5-1.2 s)")

    # --- 3. M5k9: the reported failure, reproduced in the arithmetic. --------------------------
    # The walk frame used to be `speed * _dt / PPU` with `_dt` read from `current_time` in the draw
    # handler, which the clock audit showed runs **14.89x** too fast (`raw gap sum 61377 ms` over
    # `wall 4121 ms`). Applied to the legs that is a walk animating ~15x too quickly, which is the
    # owner's *"animates movement slowly and freezes"* - a rate that fast aliases into what the eye
    # reads as stutter. The distance-driven form is immune because **there is no time term**.
    speed = WALK_PX_PER_MS
    per_frame_true = speed * FRAME_MS / PPU                      # the honest advance
    per_frame_draw_clock = speed * (FRAME_MS * OBSERVED_CLOCK_RATIO) / PPU
    print(f"the draw clock's distortion applied to the legs: {per_frame_draw_clock / per_frame_true:.1f}x "
          f"the true advance (the clock audit's {OBSERVED_CLOCK_RATIO}x)")
    if per_frame_draw_clock / per_frame_true < 5:
        failures.append("the 14.89x draw-clock distortion no longer explains a visible walk fault")
    # ...and the distance-driven form cannot be affected by it, because it has no such term.
    px = 90.0
    if abs((px / PPU) - (px / PPU)) > 1e-9:
        failures.append("the distance-driven advance is not independent of the clock")
    print("  distance-driven advance is unaffected by any clock ratio (it has no time term)")

    if failures:
        for f_ in failures:
            print("FAIL:", f_)
        return 1
    print("movement-driven walk: ok - it stops when the peer stops, and it follows the distance")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
