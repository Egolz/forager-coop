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
// **F4 did not reach the mod** in the live run of 2026-10-21 - no report, no freeze, the
// game alive - so the land probe is on **F2** as well, and F2 is the one to press.
if (keyboard_check_pressed(vk_f4)) CoopProbeLand();
if (keyboard_check_pressed(vk_f2)) CoopProbeLand();
if (keyboard_check_pressed(vk_f3)) CoopProbeItems();

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

// ---------------------------------------------------------------------------
// **Keep saying hello until the host answers.**
//
// The handshake used to depend on one thing: the async connect event. On the client side that
// event did not arrive - the live run of 2026-10-21 showed the host accepting the connection
// and completing GameMaker's own handshake, while the mod never sent a HELLO and never heard
// a WELCOME. Since `global.coopPeerAlive` is set by the WELCOME, nothing else the mod does
// can be sent either: the placement intent, the loot, the position. One missing event froze
// the whole client.
//
// So the hello is not an event, it is a **retry**: it goes out every second until the host
// answers with a WELCOME. The event still sends the first one immediately, and the retry
// covers the case where it does not.
//
// The retry only runs while a socket exists and we are not the host, so it cannot talk to
// anybody by accident. It is bounded, because a socket that never connects would otherwise be
// written to forever, and it is paced by the clock rather than by the tick counter - the tick
// stops advancing while the peer is not alive, because that is what the gate below does.
if (global.coopSocket >= 0 && !global.coopIsHost && !global.coopPeerAlive
    && global.coopHelloTries < 30) {
    if (current_time - global.coopHelloAt >= 1000) {
        global.coopHelloAt = current_time;
        global.coopHelloTries += 1;
        if (global.coopHelloTries > 1) {
            Trace("Co-op: still no welcome from the host - saying hello again ("
                  + string(global.coopHelloTries) + ").");
        }
        CoopSendHello();
    }
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
    CoopSendPos();
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
//   - no `ds_map_find_first`/`ds_map_find_next`, so a ds_map cannot be walked. State is kept
//     as four **numeric** parallel arrays, filled together in one pass.
//   - no `string_split` (it is present in data.win but **not in the loader's function table** -
//     the first version of this probe failed to load on exactly that call). Nothing here uses
//     a string function: the arrays hold numbers, not a packed record.
//   - `hp` and `grows` are deliberately never read: nothing can test for their presence, and a
//     missing field would take the game down. Only `x`, `y` and `object_index` are touched,
//     which every drawn instance has.
//
// **A correction to what used to be written here.** It said this build has no
// `variable_instance_exists`, and that is **wrong**: the name is not in `data.win`, but the
// reference mod calls it - `variable_instance_exists(id, "enemyCD")` - and PencilPal compiles
// in this very build. So the function is there; **data.win's string table is not the loader's
// function table, in either direction**: it also holds `ini_open`, which the loader refuses
// with "not function or script". A name missing from data.win is a question, and the
// reference mod is the oracle that answers it.

// Resolve the bush objects once per session.
if (global.coopBushObj == -2) {
    global.coopBushObj = [];
    var _bush_names = ["objBush", "objCotton", "objFlower"];
    for (var _bn = 0; _bn < array_length(_bush_names); _bn += 1) {
        var _bidx = asset_get_index(_bush_names[_bn]);
        Trace("Co-op asset probe (bush): '" + _bush_names[_bn] + "' -> " + string(_bidx));
        // **`> 0`** for the same reason as the enemy census: this build answers a name it
        // does not know with 0, and object 0 is a real object, so `>= 0` accepts the miss.
        if (_bidx > 0) array_push(global.coopBushObj, _bidx);
    }
    Trace("Co-op: bush sync watching " + string(array_length(global.coopBushObj))
          + " of 3 plant objects: " + string(global.coopBushObj));
}

if (array_length(global.coopBushObj) > 0 && instance_exists(objPlayer)) {
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
        if (CoopPlantStillExists(_prev_obj[_p], _prev_x[_p], _prev_y[_p])) continue;
        CoopSendResourceDestroy(_prev_x[_p], _prev_y[_p], _prev_obj[_p]);
    }

    global.coopBushObjAt = _now_obj;
    global.coopBushIds   = _now_id;
    global.coopBushXs    = _now_x;
    global.coopBushYs    = _now_y;
}

// ============================================================================
// The enemies (M3.5).
//
// **The census is the sync, and it no longer depends on knowing what a slime is called.**
// The first version watched `parEnemy` and `objSlime` by name and reported **nothing at
// all** while the owner stood next to a slime (live, 2026-10-22). Two causes, both now
// handled:
//
//  * `asset_get_index` in this build answers a name it does not know with **0**, not -1.
//    A guard of `>= 0` therefore *accepts the miss* and puts object 0 in the walk list -
//    a census that walks the wrong object and reports nothing while looking healthy.
//    The guard is `> 0` now, and the answers are printed once so the next session knows
//    which names resolve.
//  * More importantly, the sync must not depend on names at all. What makes a watched
//    object an **enemy** is decided by what it carries: a creature has `hp` and `hpMax`,
//    and a bush, a rock or a building does not. So the watch list is built from the live
//    world - every object that has at least one instance right now - and each candidate
//    is checked for `hp` with `variable_instance_exists`, the field test the reference mod
//    proves the loader knows.
//
// That is one walk over the objects, kept in `global.coopMobObj`, and it is the same shape
// the bush census uses: parallel arrays, `instance_find`, nothing that needs a `ds_map`.
if (!global.coopMobResolved && instance_exists(objPlayer)) {
    global.coopMobResolved = true;
    // **The walk is over `all` - every instance GameMaker has - and the objects are collected
    // into a plain array.** This started as a second global array, and that is the bug the
    // owner hit: it was never initialised, so the *first* check (`global.coopMobObj == -2`,
    // when the array did not exist, so it read as 0) never matched and the census stayed
    // empty forever - "watching 0 object(s) out of 18 in the world: -2", with `-2` printed
    // for an array that was never a list. A local array has no such state to get wrong.
    var _all_objs = [];
    var _n_all = 0;
    var _cnt_all = instance_number(all);
    if (_cnt_all > 4000) _cnt_all = 4000;      // the walk is a census, not a sweep of the map
    var _with_hp = 0;
    for (var _ai = 0; _ai < _cnt_all; _ai += 1) {
        var _ainst = instance_find(all, _ai);
        if (!instance_exists(_ainst)) continue;
        var _aobj = _ainst.object_index;
        var _known = false;
        for (var _ak = 0; _ak < _n_all; _ak += 1) {
            if (_all_objs[_ak] == _aobj) { _known = true; break; }
        }
        if (_known) continue;
        _all_objs[_n_all] = _aobj;
        _n_all += 1;
        // Is this object an enemy? **Only the field says so.** A creature carries `hp`; a
        // bush, a rock or a building does not. `variable_instance_exists` is the field test
        // the reference mod proves the loader knows (data.win does not list it, and
        // data.win is not the loader's function table).
        if (variable_instance_exists(_ainst, "hp")) {
            _with_hp += 1;
            var _is_player = false;
            if (instance_exists(objPlayer) && _aobj == objPlayer.object_index) _is_player = true;
            if (!_is_player) array_push(global.coopMobObj, _aobj);
        }
    }
    var _mob_line = "Co-op: enemy census watching " + string(array_length(global.coopMobObj))
                  + " of the " + string(_with_hp) + " object(s) carrying hp, out of "
                  + string(_n_all) + " in the world: " + string(global.coopMobObj);
    Trace(_mob_line);
    CoopSendDebugLine(_mob_line);
}
if (array_length(global.coopMobObj) > 0 && instance_exists(objPlayer)) {
    var _mob_seen = 0;
    var _mob_text = "";
    for (var _mb = 0; _mb < array_length(global.coopMobObj); _mb += 1) {
        var _mobj   = global.coopMobObj[_mb];
        var _mcount = instance_number(_mobj);
        for (var _mi = 0; _mi < _mcount; _mi += 1) {
            var _minst = instance_find(_mobj, _mi);
            if (!instance_exists(_minst)) continue;
            _mob_seen += 1;
            if (_mob_seen > 6) continue;      // a handful is a census, a list of forty is noise
            _mob_text += " | obj#" + string(_minst.object_index)
                       + " '" + object_get_name(_minst.object_index) + "'"
                       + " id " + string(_minst.id)
                       + " at " + string(floor(_minst.x)) + "," + string(floor(_minst.y));
            // **`hp` is only read after asking if it is there.** A missing field is a
            // hard runtime error, and which objects carry it is exactly the unknown here.
            if (variable_instance_exists(_minst, "hp")) {
                _mob_text += " hp " + string(_minst.hp);
            } else {
                _mob_text += " hp -";
            }
            if (variable_instance_exists(_minst, "hpMax")) {
                _mob_text += "/" + string(_minst.hpMax);
            }
        }
    }
    global.coopMobTick += 1;
    if (global.coopMobTick mod 120 == 0) {
        var _mob_line = "Co-op enemies: " + string(_mob_seen) + " in the walk" + _mob_text;
        Trace(_mob_line);
        if (global.coopMobSeen != _mob_seen) {
            global.coopMobSeen = _mob_seen;
            CoopSendDebugLine(_mob_line);
        }
    }
}

// ============================================================================
// The roll probe is **answered** and can go quiet.
//
// The measurement of 2026-10-22 settled it: `objPlayer.angle` never left zero while the
// owner rolled, and `image_index` ran `5.85 -> 0.00 -> 0.15` instead. So the roll is the
// **body frame counter**, there is nothing left to probe, and the puppet shows the roll for
// free now that it is drawn at the peer's interpolated frame.
//
// All that is kept is a single line when the angle ever *does* move - the one thing that
// would mean this build turns its players after all - so the question stays answered
// without a wall of text.
if (instance_exists(objPlayer)) {
    var _pa = abs(floor(objPlayer.angle));
    if (_pa != global.coopProbeAngle) {
        global.coopProbeAngle = _pa;
        if (_pa != 0) {
            var _pr_line = "Co-op: the player's angle moved to " + string(_pa)
                         + " (until now it has only ever been zero).";
            Trace(_pr_line);
            CoopSendDebugLine(_pr_line);
        }
    }
}
