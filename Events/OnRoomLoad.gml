#define OnRoomLoad()
// A room finished (re)loading. Used for one thing only: **forget the world we were
// describing**, because every instance handle in that description is about to become invalid.
//
// What the probes settled (live 2026-10-20). This event was added to fix a native crash
// (`0xc0000005` at `0x012c265f`, only while a peer was connected, invisible to error.log
// because a native fault never reaches the GML error handler). It was first written to drive
// **both** directions - enter and leave - on the assumption that rooms load either way. The
// wire proved that wrong:

//     probe step:  tick 0 worldLoaded=0 player=1        <- repeated forever
//     probe roomload: entering=0 player=0 loaded=0 peerAlive=1

// `OnRoomLoad` arrived only with `player=0`, i.e. **on the way out, after the world is gone**
// (and it arrived twice), and never on the way in. So it cannot be an enter hook, and a
// `coopWorldLoaded` flag set by CoopEnterWorld stayed false for the whole session - which
// silently disabled the mod's entire per-frame half (the per-frame code bailed out at its
// gate, so no heartbeat, no POS). That is why a mock sitting on a working connection never
// got a furnace: the host was not doing anything while looking alive.
//
// The lesson is in the shape of the fix: **ask whether the world is alive when you need it**
// (`instance_exists(objPlayer)`), instead of remembering the answer from an event whose
// timing you only guessed at. Every per-frame and per-event entry point now does exactly that,
// so this handler no longer has an "enter" job at all - it only has to drop stale state.
//
// It is deliberately safe to call at any point in the teardown: nothing here touches the
// world (no `objPlayer`, no instances). It clears the plant snapshot, whose handles point
// into the room being destroyed, and the two re-entrancy flags, which can only be set for the
// instant of an apply and would otherwise disable the loot path in the next world.
CoopLeaveWorld();
