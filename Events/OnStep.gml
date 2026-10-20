#define OnStep
// Forager Co-op - per-frame pump: hotkeys, heartbeats, presence.
// World sync only reacts to events (OnStructureSpawn) and to packets; nothing
// heavy is scanned here.

if (keyboard_check_pressed(vk_f5)) CoopHost();
if (keyboard_check_pressed(vk_f6)) CoopJoin();
if (keyboard_check_pressed(vk_f7)) CoopDisconnect("requested");
if (keyboard_check_pressed(vk_f8)) CoopStatus();
if (keyboard_check_pressed(vk_f9)) CoopDumpStructures();
if (keyboard_check_pressed(vk_f10)) CoopProbeWorld();
if (keyboard_check_pressed(vk_f11)) CoopProbeApi();
if (keyboard_check_pressed(vk_f12)) CoopProbeSpot();
if (keyboard_check_pressed(vk_f3)) CoopProbeItems();
if (keyboard_check_pressed(vk_f4)) CoopProbeGrid();

// ---------------------------------------------------------------------------
// **Save & quit: end the session here, before the world unloads.**
//
// This is the fix for the native crash (`0xc0000005` at `0x012c265f`) that killed the game on
// every "save and quit" while a peer was connected. The evidence is a controlled pair of live
// runs on 2026-10-20:
//
//     press F7 first (our own CoopDisconnect) -> the game returns to the menu, no crash
//     leave the socket open                   -> the game dies ~1 s after OnRoomLoad
//
// So the fault is caused by the socket being **live while the world tears down**, not by the
// world teardown itself. `OnRoomLoad` already closed the socket, and did not help, because that
// event fires on the way *out* - the world is already gone by then, and the close lands inside
// the window that faults. The engine's own netcode closes its sockets at the transition instead
// (the reference mod's OnStep: `instance_exists(objTransition) && objTransition.target ==
// rmInputSelect`, then `network_destroy`), which is the one place that is early enough.
//
// This copies that: as soon as the transition to the menu begins, end the session. The guard is
// the same pair `CoopLeaveWorld` uses, and it is naturally one-shot - the first call clears both
// flags, so the repeated frames of the transition do nothing. If the transition is reached while
// not connected the guard is false and nothing happens, which is why the initial menu entry is
// safe.
if (instance_exists(objTransition) && objTransition.target == rmInputSelect) {
    if (global.coopConnected || global.coopIsHost) CoopDisconnect("save and quit");
}

if (!global.coopPeerAlive) exit;

// **"Am I in a world?" is asked here, not remembered from a room event.** A flag set by
// OnRoomLoad looked right and was wrong: the probe of 2026-10-20 showed OnRoomLoad arriving
// only with `player=0` - the game fires it on the way *out* (and twice), never on the way in -
// so a `coopWorldLoaded` flag stayed false for a whole session and this exit killed the mod's
// entire per-frame half: no heartbeat, no POS, and the host silently ignored nothing at all
// because it looked alive while doing no work. A live check has no such edge, and needs no
// builtin this build lacks.
//
// `objPlayer` exists is the honest test: it is the same guard the events already use, and
// OnStep runs from the system step, which the game keeps calling while a room is torn down -
// exactly the frames where a remembered flag and reality disagree.
if (!instance_exists(objPlayer)) exit;

global.coopTick += 1;

// Diagnostic, temporary (native crash, 2026-10-20). The fault leaves no log, so the only
// record of where the game died is what the peer already received. Reporting the phase on a
// timer turned out to be too coarse: the last test announced `phase 10` every five seconds
// while the game ran, and a phase that is *set* rather than *reset* says nothing about the
// moment in between. So this reports it **on change** as well, rate-limited to avoid the
// flood an earlier version of this diagnostic caused (comments above are the record of that
// mistake - a counter sitting before its own increment fired every frame).
//
// `phaseAge` counts frames since the last change, so a phase that never changes is visible
// too: a frozen phase with a growing age means the game is stuck *inside* that operation,
// which is a different and much more specific finding than "it was somewhere in OnStep".
if (global.coopPhase != global.coopPhaseSent) {
    CoopSendDebugLine("probe phase " + string(global.coopPhase)
                      + " at tick " + string(global.coopTick)
                      + " rx " + string(global.coopRxCount));
    global.coopPhaseSent = global.coopPhase;
    global.coopPhaseAge  = 0;
} else {
    global.coopPhaseAge += 1;
}
if (global.coopTick mod 300 == 0) {
    CoopSendDebugLine("probe tick " + string(global.coopTick)
                      + " rx " + string(global.coopRxCount)
                      + " phase " + string(global.coopPhase)
                      + " age " + string(global.coopPhaseAge)
                      + " player " + string(instance_exists(objPlayer)));
}

// Packet corpus: the whole recent operation ring goes out whenever a new token was added.
// This is the flight recorder the phase marker is not - see the diagnostics block in
// Net.gml. It rides the once-per-frame OnStep rather than being sent where the token was
// added, so a send can never happen in the middle of parsing a packet.
if (global.coopTraceDirty) {
    global.coopTraceDirty = false;
    var _ct_line = "corpus";
    for (var _ct_j = 0; _ct_j < array_length(global.coopTrace); _ct_j += 1) {
        _ct_line += " " + global.coopTrace[_ct_j];
    }
    CoopSendDebugLine(_ct_line);
}

// Phase markers for the native crash. The fault kills the process without reaching
// error.log, so the only evidence is what the peer already received - and the last phase
// number to arrive names the code the game died in. Cheap (an assignment) and removed
// together with the rest of the diagnostics.
//
// Deliberately **not** reset each frame: it is set immediately before each operation that
// could fault, so whatever the peer last heard is the operation the game was inside when it
// died. A reset would only ever answer "we were in OnStep", which is known already.

// heartbeat: keep at most one ping in flight
if (global.coopTick mod 90 == 0 && global.coopPingSentAt < 0) {
    CoopSendPing();
}
// a ping that never comes back means the peer is gone
if (global.coopPingSentAt >= 0 && current_time - global.coopPingSentAt > 5000) {
    Trace("Co-op: ping timeout - peer looks gone.");
    global.coopPingSentAt = -1;
    global.coopPeerAlive  = false;
}

// presence: ~20 packets/second, cosmetic and latency-sensitive
if (global.coopTick mod 3 == 0) {
    global.coopPhase = 13;   // sending our position
    CoopTraceStep("sndpos");   // diagnostic: the corpus's send half
    CoopSendPos();
    CoopTraceStep("spos");
}

// ============================================================================
// Bush/pickable-plant sync (M2.2, live 2026-10-20). **Working sync, not a probe.**
//
// Why this is an *observation* and not an event. Forager fires OnResourceDestroy for a
// tree or a rock, and this mod hooks that. It does **not** fire it for a bush: picking one
// dropped berries (`OnItemDrop fired: item54 x3`) with **no destroy event at all**. Two
// probes settled what actually happens, rather than assuming:
//
//   1. A probe watched the bush's `image_index`, because PencilPal syncs bushes by noticing
//      a frame change (`Events/OnEvent.gml:316-321`). It reported **nothing** while bushes
//      were picked - a picked bush does **not** change its frame in this build, so the
//      PencilPal `grows`-and-regrow reading does not apply here.
//   2. A probe then watched for the bush **disappearing**, and caught it:
//
//        probe bush census: standard 7 vs true 7          <- bushes are active, not merely
//                                                            deactivated off-screen, so "gone"
//                                                            means *picked*, not "left the room"
//        probe bush GONE: obj#86 'objBush' parent 'parHerb' id 101967 at 696,648
//        OnItemDrop fired: item54 x3 @600,648             <- berries fell on the same tile
//
//   and the mock confirmed the sync itself:
//
//        <- RESOURCE_DESTROY obj#86 at 696,648 room 8
//        <- DROP item #54 x1 at 600,648   (x3)
//        <- RESOURCE_DESTROY obj#86 at 600,648 room 8
//        <- PICKUP item #54 at 628,656 room 8
//
// **The bush's parent is `parHerb`, not `parResource`** - which is the real reason no
// destroy event ever arrived: in the game's own taxonomy a bush is not a resource, it is a
// herb. That is also why PencilPal keeps a separate `["objBush", "objCotton", "objFlower"]`
// list instead of treating it with the trees.
//
// So a bush must be **observed**: remember which ones were here, and when one vanishes
// announce the very same RESOURCE_DESTROY the tree uses (object index + tile). Reusing the
// existing packet means the far end needs no new code - `CoopApplyResourceDestroy` already
// matches on index+tile and walks with TrueInstanceNumber, and it destroys whatever bush
// index it is handed.
//
// **Known limitation (accepted 2026-10-20):** the walk uses `instance_number`/`instance_find`,
// which only see instances **active in the current room**. A bush picked somewhere the player
// is not standing is never seen to vanish, so the peer keeps it. Widening it to
// `TrueInstanceNumber` would catch those, but that pair also sees deactivated instances, and a
// room change would then look exactly like every bush in the old room being picked at once.
// Fixing it properly means remembering each bush's room, which is deferred with the rest of the
// room-scoped world work. Until then: bushes sync while in view.
//
// What this build does NOT have, and how the shape below works around it:
//   - no `variable_instance_exists`, so "is this instance a bush" cannot be asked. The bush
//     objects are looked up **by name** instead, via `asset_get_index`, using PencilPal's own
//     three names; a name this build lacks returns -1 and simply drops out.
//   - no `ds_map_find_first`/`ds_map_find_next`, so a ds_map cannot be walked. State is kept
//     as four **numeric** parallel arrays, filled together in one pass.
//   - no `string_split` (it is present in data.win but **not in the loader's function table** -
//     the first version of this probe failed to load on exactly that call). Nothing here uses
//     a string function: the arrays hold numbers, not a packed record.
//   - `hp` and `grows` are deliberately never read: nothing can test for their presence, and a
//     missing field would take the game down. Only `x`, `y` and `object_index` are touched,
//     which every drawn instance has.

// Resolve the bush objects once per session.
if (global.coopBushObj == -2) {
    global.coopBushObj = [];
    var _bush_names = ["objBush", "objCotton", "objFlower"];
    for (var _bn = 0; _bn < array_length(_bush_names); _bn += 1) {
        var _bidx = asset_get_index(_bush_names[_bn]);
        if (_bidx >= 0) array_push(global.coopBushObj, _bidx);
    }
    Trace("Co-op: bush sync watching " + string(array_length(global.coopBushObj))
          + " of 3 plant objects: " + string(global.coopBushObj));
}

if (array_length(global.coopBushObj) > 0 && instance_exists(objPlayer)) {
    global.coopPhase = 10;   // walking the plant snapshot
    var _prev_obj = global.coopBushObjAt;   // object index of each plant, last step
    var _prev_id  = global.coopBushIds;     // its instance id
    var _prev_x   = global.coopBushXs;      // its x
    var _prev_y   = global.coopBushYs;      // its y
    var _now_obj  = [];
    var _now_id   = [];
    var _now_x    = [];
    var _now_y    = [];

    // **In this build the idiom is safe, and the guard below was written from the opposite
    // assumption - corrected here rather than left to mislead.** The pair
    // `instance_number(obj)` / `instance_find(obj, i)` was suspected of returning a freed slot
    // when the instance list changes mid-walk, which would explain the native access violation
    // (`0xc0000005` at `0x012c265f`) that only ever appears with a peer connected. The owner
    // then clarified the symptom and the room-load diagnostic of 2026-10-20 23:12 settled it:
    // the game runs for minutes **without faulting**, and dies when "save and quit" is pressed,
    // *after* this handler has already completed (see OnRoomLoad - `OUT survived` arrived, then
    // the process died). So the walk is not the fault and the "freed slot" theory is retired:
    // GameMaker's `instance_find` returns the instance at that position of the **current** list,
    // and a destroyed instance leaves the list; it does not hand back dangling memory.
    //
    // The `instance_exists` re-check stays as cheap insurance and because it costs one call per
    // plant, but it is no longer load-bearing: the comment that called it "the whole reason this
    // walk is safe" overstated a precaution. What matters is that the walk reads only `x`, `y`
    // and `object_index`, which every drawn instance has.
    for (var _b = 0; _b < array_length(global.coopBushObj); _b += 1) {
        var _obj   = global.coopBushObj[_b];
        var _count = instance_number(_obj);
        for (var _i = 0; _i < _count; _i += 1) {
            var _inst = instance_find(_obj, _i);
            if (!instance_exists(_inst)) continue;
            array_push(_now_obj, _inst.object_index);
            array_push(_now_id,  _inst);
            array_push(_now_x,   floor(_inst.x));
            array_push(_now_y,   floor(_inst.y));
        }
    }

    // A plant that was here last step and is gone now *might* be a pick - and might also be
    // a plant the room merely **deactivated** because the player walked away from it, which
    // is the common case, not the rare one. Telling those apart is what stops the repeat
    // below, and it was measured live on 2026-10-20:
    //
    //     [18:50:42] <- RESOURCE_DESTROY obj#86 at 616,728 room 8
    //     [18:50:43] <- RESOURCE_DESTROY obj#86 at 616,728 room 8
    //     [18:50:49] <- RESOURCE_DESTROY obj#86 at 616,728 room 8
    //     [18:50:55] <- RESOURCE_DESTROY obj#86 at 616,728 room 8
    //
    // Four announcements for one bush. The snapshot above is built from `instance_number`,
    // which sees **only active** instances, so a bush that went inactive left the snapshot,
    // was announced, came back into view, went inactive again, and was announced again.
    //
    // The test for "still there, just inactive" is the one pair this build already gives us
    // and the snapshot deliberately does not use: `TrueInstanceNumber`/`TrueInstanceFind`
    // see **deactivated** instances too. A bush that is absent from the active walk but
    // present in the true walk was not picked - it was culled - so nothing is announced
    // and, more importantly, the peer is never told to destroy a bush that still exists.
    //
    // Both halves are needed as before: the previous step says *what* and *where* it was
    // (the active instance is already gone and cannot be asked), the true walk says whether
    // it is really gone.
    for (var _p = 0; _p < array_length(_prev_id); _p += 1) {
        var _bush_alive = false;
        for (var _q = 0; _q < array_length(_now_id); _q += 1) {
            if (_now_id[_q] == _prev_id[_p]) { _bush_alive = true; break; }
        }
        if (_bush_alive) continue;
        // Absent from the active walk - but is it gone, or only culled?
        global.coopPhase = 11;   // asking whether a vanished plant is really gone
        if (CoopPlantStillExists(_prev_obj[_p], _prev_x[_p], _prev_y[_p])) continue;
        global.coopPhase = 12;   // announcing the picked plant
        CoopSendResourceDestroy(_prev_x[_p], _prev_y[_p], _prev_obj[_p]);
    }

    global.coopBushObjAt = _now_obj;
    global.coopBushIds   = _now_id;
    global.coopBushXs    = _now_x;
    global.coopBushYs    = _now_y;
    global.coopPhase = 14;   // diagnostic: the plant walk finished without faulting
    CoopTraceStep("plants");
}
