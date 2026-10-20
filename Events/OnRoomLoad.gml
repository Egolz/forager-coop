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
//
// ---------------------------------------------------------------------------
// Diagnostic (temporary, 2026-10-20). The owner clarified the symptom: the game does **not**
// crash while playing - it runs for minutes and then dies exactly when "save and quit" is
// pressed, instead of returning to the main menu. That makes this handler the prime suspect,
// because it is the only mod entry point that runs during world teardown.
//
// It sends a line **before** and a line **after** `CoopLeaveWorld()`, so the next quit answers
// two questions at once with no guessing: does this event fire at all, and does the fault land
// inside our teardown or after it? `CoopSendDebugLine` is fire-and-forget over the existing
// socket, so it cannot itself fail an assertion - the mock just writes down what arrived.
//
// **`OUT` must go out before the close**, because `CoopLeaveWorld` now ends the session and a
// line sent after that has no socket to travel on - the diagnostic would silence itself. So the
// close is split from the state clearing: `CoopForgetWorld` drops the stale handles first (it
// touches nothing but globals), `OUT` reports on the socket that is still open, and only then
// `CoopLeaveWorld` performs the close. What `OUT` says about `sock` is therefore the value
// *before* the close, which is exactly what has to be recorded to interpret the next run.
CoopSendDebugLine("probe roomload IN peerAlive=" + string(global.coopPeerAlive)
                  + " connected=" + string(global.coopConnected)
                  + " host=" + string(global.coopIsHost)
                  + " sock=" + string(global.coopSocket)
                  + " player=" + string(instance_exists(objPlayer))
                  + " tick=" + string(global.coopTick));
CoopForgetWorld();
CoopSendDebugLine("probe roomload OUT survived tick=" + string(global.coopTick)
                  + " sock=" + string(global.coopSocket)
                  + " host=" + string(global.coopIsHost));
CoopLeaveWorld();
