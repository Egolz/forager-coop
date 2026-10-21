"""Does continuing the index between packets give a smoother frame than freezing on it?

This is an offline check of the M5i change, using the **real numbers from the owner's own wire
log** rather than invented ones. The log's walk cycle is (from Net.gml's comment):

    frame 4.20 4.65 5.10 5.55 0.00 0.45      <- the game's own index, 20 packets a second
    step  2.10 2.32 2.55 2.77 0.00 0.22

so the peer's index advances about **0.22 per packet** while walking, and the cycle is **six**
index-units. The game draws **60 fps**, the packets come at **20 Hz** - three drawn frames per
packet.

The claim to test: with the old code (`floor(last reported step)`) the drawn frame is a staircase
with two flat frames, and with the new code (continue at the measured rate) it advances nearly
every frame, and never runs ahead of where the peer really is by more than a fraction of a step.
"""
import math

PACKET_HZ = 20
DRAW_HZ = 60
CYCLE = 6.0              # six index-units, measured on the wire
STEP_MAX = 5             # the last whole frame before the cycle wraps


def peer_truth(packet_i: int) -> float:
    """The peer's index at packet `packet_i`, from the log's own numbers."""
    return (2.10 + 0.22 * packet_i) % CYCLE


def clamp_rate(rate: float) -> float:
    """The reader's clamp: never above 0.05 units per millisecond (a healthy walk is ~0.019)."""
    return max(0.0, min(0.05, rate))


def old_frame(step: float) -> int:
    return min(STEP_MAX, max(0, math.floor(step)))


def new_frame(step: float, rate: float, age_ms: float) -> int:
    v = step + rate * min(age_ms, 100.0)
    if v >= CYCLE:
        v = v % CYCLE
    return min(STEP_MAX, max(0, math.floor(v)))


def main() -> int:
    # Packets: the peer walks for 60 packets (3 s), so the cycle runs ten times.
    packets = [peer_truth(i) for i in range(60)]

    old_frames, new_frames = [], []
    step_prev, step_prev_at = packets[0], 0.0
    for draw in range(60 * 3):                    # 3 seconds at 60 fps
        t_ms = draw * (1000.0 / DRAW_HZ)
        pkt = int(t_ms // (1000.0 / PACKET_HZ))   # which packet is the newest
        pkt = min(pkt, len(packets) - 1)
        # The packet's arrival time, on the same clock.
        at_ms = pkt * (1000.0 / PACKET_HZ)
        # The rate the reader would have measured, from this packet's step and the one before.
        if pkt > 0:
            d = packets[pkt] - packets[pkt - 1]
            if d < 0:
                d += CYCLE
            rate = clamp_rate(d / (1000.0 / PACKET_HZ))
        else:
            rate = 0.0
        age = t_ms - at_ms

        old_frames.append(old_frame(packets[pkt]))
        new_frames.append(new_frame(packets[pkt], rate, age))

    def flat_runs(frames):
        runs, cur = [], 1
        for a, b in zip(frames, frames[1:]):
            if a == b:
                cur += 1
            else:
                runs.append(cur)
                cur = 1
        runs.append(cur)
        return runs

    def changes_per_second(frames):
        return sum(1 for a, b in zip(frames, frames[1:]) if a != b) / (len(frames) / DRAW_HZ)

    old_flat = [r for r in flat_runs(old_frames) if r > 1]
    new_flat = [r for r in flat_runs(new_frames) if r > 1]

    # How far the drawn value runs ahead of the peer's real index at any drawn frame, in
    # index-units, at the worst moment. One index-unit is 4.76 px of walking.
    worst_lead = 0.0
    for draw in range(len(new_frames)):
        t_ms = draw * (1000.0 / DRAW_HZ)
        pkt = min(int(t_ms // (1000.0 / PACKET_HZ)), len(packets) - 1)
        at_ms = pkt * (1000.0 / PACKET_HZ)
        d = packets[pkt] - packets[pkt - 1] if pkt > 0 else 0.0
        if d < 0:
            d += CYCLE
        rate = clamp_rate(d / (1000.0 / PACKET_HZ))
        v = packets[pkt] + rate * min(t_ms - at_ms, 100.0)
        # The peer's real index, carried on from the last packet at the same rate.
        lead = ((v - packets[pkt]) % CYCLE)
        worst_lead = max(worst_lead, lead)

    print(f"packets seen:        {len(packets)}")
    print(f"old: frame changes   {changes_per_second(old_frames):.1f}/s, "
          f"longest freeze {max(old_flat) if old_flat else 0} drawn frames")
    print(f"new: frame changes   {changes_per_second(new_frames):.1f}/s, "
          f"longest freeze {max(new_flat) if new_flat else 0} drawn frames")
    print(f"new: runs ahead of the peer by at most {worst_lead:.2f} index-units "
          f"({worst_lead * 4.76:.1f} px of walking)")

    failures = []
    # The claim under test is only about the **shape**: continuing the index must not freeze for
    # long stretches, and must not run a whole step ahead. It says nothing about the rate, because
    # at the rate the owner's log actually shows (0.22 units per packet) a six-unit cycle takes
    # 1.36 s either way - so the *rate* is a separate, open question the live `idx probe` line
    # answers, and the smoothness here is only ever as good as that rate allows.
    if max(new_flat) >= max(old_flat):
        failures.append(f"the new frame freezes for as long as the old one "
                        f"(new {max(new_flat)} vs old {max(old_flat)} drawn frames)")
    if worst_lead > 1.0:
        failures.append(f"the new frame runs more than a whole step ahead "
                        f"({worst_lead:.2f} units) - it would show a frame early")
    if failures:
        for f in failures:
            print("FAIL:", f)
        return 1
    print("frame continuation: ok - never freezes longer than freezing on the packet, "
          "and never a step ahead")
    print("NOTE: at the log's own rate the cycle is 1.36 s - if the live `idx probe` says the "
          "index runs ~19 px per unit, the walk clock itself is 4x too slow and that is the "
          "real cause of the animation looking wrong.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
