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
// **F3 is the bob measurement** the owner asked for (M5k6): it **arms** a window here, and the
// sampler is pumped on every step below, because a rate has to be measured across steps and not at
// the instant of a key press.
if (keyboard_check_pressed(vk_f3)) global.coopBobAsk = true;
CoopMeasureBob();
// the items probe kept its job, one key over (F3 became the bob measurement the owner asked for)
if (keyboard_check_pressed(vk_f4)) CoopProbeItems();
if (keyboard_check_pressed(vk_f2)) CoopProbeLand();
// **The enemy-API probe runs by itself, once per loaded world** (2026-10-22). It needs no key
// press because it must be readable: its lines go to the mock through `CoopSendDebugLine`, and
// a human pressing a key is not a test plan. F1 re-runs it on demand.
if (!global.coopEnemyProbed && instance_exists(objPlayer) && global.coopPeerAlive) {
    global.coopEnemyProbed = true;
    CoopProbeEnemy();
}
if (keyboard_check_pressed(vk_f1)) CoopProbeEnemy();

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

// **How fast does the player's own `image_index` REALLY advance - per GAME STEP?** (M5k3f)
//
// Every previous rate round measured the index against **wall-clock time** or against **packet
// distance**, and both gave numbers that disagreed with what the owner sees:
//
//     "too fast" (0.17 s/cycle, from image_speed 0.60)   ->   "too slow" (0.67 s, from the index rise)
//
// The index is the game's own frame counter, so the honest unit is **units per game step** - a step
// is a step no matter what the frame rate does - and this counts exactly that: the raw index each
// step, and how much it moved since the last probe dump. The owner's own `idx probe` already showed
// the index **stopped dead while standing** (`imgidx 4.20` five times in a row), so this also has to
// separate "standing" from "walking": the two are summed separately.
//
// ============================================================================
// **M5k8: the puppet's idle bob is advanced HERE, once per game STEP.**
//
// The F3 clock audit settled it with a number:
//
//     bob clock over 4121 ms: outer 505.70/s, enter 122.70/s
//       | raw gap sum 61377 ms (wall 4121 ms, ratio 14.89x)
//
// **Every term in the draw handler's arithmetic was right and the clock it used was not.**
// `current_time` ticks far more slowly than the draw handler is called - the handler runs ~505x/s
// and the gap sum came out **15x** the wall clock, so seven calls in eight see the *same*
// millisecond. The `if (_dt < 1) _dt = 1;` guard then counts that shared millisecond as a whole 1 ms
// each time, and a rate expressed in milliseconds means nothing at all.
//
// The one clock in this mod that has never lied is the **step**: the same probe reads
// `dt 17.97` on ~44-58 steps/s every time, because a step is a step. So the bob is advanced here -
// `_idle_units` is per millisecond, so one step is `_idle_units * step_ms`, where `step_ms` is
// **measured from the gap between steps** (below). Standing and the walk-off are the
// same test the draw handler uses (`coopPeerWalking`); the draw handler now only **reads**
// `coopIdleFrameF` and picks the frame.
// ============================================================================
// **M5k8: measure how long one game step really is.** This is the conversion the bob needs, and
// it is measured rather than assumed for the same reason the bob moved here: the two clocks in
// this build disagree by an order of magnitude, so any "steps per second" taken from the frame
// rate is wrong. `current_time` is honest at *step* rate (every probe reads `dt 17.97`), so the
// gap between consecutive steps is a real step length; it is smoothed because a single hitch
// (world load, a save) must not swing the animation rate.
if (global.coopStepAt > 0) {
    var _sm_raw = current_time - global.coopStepAt;
    if (_sm_raw > 0 && _sm_raw < 1000) {
        global.coopStepMsRaw = _sm_raw;
        global.coopStepMs = global.coopStepMs <= 0 ? _sm_raw
                                                   : (global.coopStepMs * 0.9 + _sm_raw * 0.1);
    }
}
global.coopStepAt = current_time;

if (global.coopPeerAlive && !global.coopPeerWalking) {
    var _ib_n = sprite_get_number(global.coopIdleSprite);
    if (_ib_n < 1) _ib_n = 6;                       // sprPlayerIdle has six frames (live)
    // **One macro decides the rate** (`CoopIdleUnits`), shared with the draw handler, so the two
    // can never derive it differently. M5k8b found the last of the factor-of-ten family here: the
    // inline gate accepted a *tiny nonzero* peer rate (a standing peer's jitter, ~0.0007 u/ms)
    // over the correct 0.012 from the period, and the bob ran ~18x slow while every printed number
    // looked right.
    var _ib_units = CoopIdleUnits();
    // One game step, in milliseconds - **measured here, not assumed.** `fps` was the first
    // thought and it is the wrong one: it is the *draw* rate, and this build's draw handler runs
    // ~505x/s while the step runs ~44-58x/s, so `1000 / fps` would be off by an order of
    // magnitude and would reintroduce exactly the bug being fixed. The step is timed against the
    // same `current_time` that the `idx probe` has been reading honestly all along (`dt 17.97` at
    // 44-58 steps/s), smoothed over a window so one hitch does not swing the rate: the raw gap is
    // kept in `coopStepMsRaw`, and `coopStepMs` is an exponential average of it.
    var _ib_step_ms = global.coopStepMs;
    if (_ib_step_ms <= 0) _ib_step_ms = 1000 / 60;   // first steps, before the average exists
    global.coopIdleFrameF += _ib_units * _ib_step_ms;
    if (global.coopIdleFrameF >= _ib_n) global.coopIdleFrameF = global.coopIdleFrameF mod _ib_n;
    if (global.coopIdleFrameF < 0) global.coopIdleFrameF = 0;
    global.coopIdleTicks += 1;
    global.coopIdleUnitsAdded += _ib_units * _ib_step_ms;
    global.coopIdleDtSum += _ib_step_ms;
    // **M5k8b: keep the last OPERANDS, not just the product.** The product is 10.19x smaller than
    // `_ib_units * coopStepMs` says it should be, and every input has been measured and re-measured
    // without moving: the period prints as 0.50 s, the step prints as 25.26 ms, and the branch runs
    // 458 times over the window - which by the formula is 138 frames, against 13.62 counted. A
    // factor of ten has been the shape of this bug from the start, so the two numbers the arithmetic
    // actually multiplies are recorded at the moment it multiplies them, instead of being inferred
    // from a line printed once at the end of the window.
    global.coopLastUnits  = _ib_units;
    global.coopLastStepMs = _ib_step_ms;
}

// `coopIdxUnitsStand` / `coopIdxUnitsWalk` are hundredths gained, `coopIdxStepsStand` /
// `coopIdxStepsWalk` are the steps they took, and the probe line reports each as units/step.
if (global.coopPeerAlive) {
    var _is_now = abs(objPlayer.image_index) * 100;
    var _is_d   = _is_now - global.coopIdxStepPrev;
    if (_is_d < 0) _is_d += 600;                  // the six-frame cycle wraps at 600 hundredths
    if (global.coopLastMoved) {
        global.coopIdxUnitsWalk += _is_d;
        global.coopIdxStepsWalk += 1;
    } else {
        global.coopIdxUnitsStand += _is_d;
        global.coopIdxStepsStand += 1;
    }
    global.coopIdxStepPrev = _is_now;
}





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
// The enemies (M3.5), third attempt - and this one asks the world instead of guessing a field.
//
// **The first two attempts guessed.** The first watched `parEnemy`/`objSlime` by name (and a
// `>= 0` guard accepted the 0 this build returns for an unknown name, so it walked object 0).
// The second watched every object carrying `hp` - and the live census came back
// "watching 3 of the 4 object(s) carrying hp: { 86, 84, 85 }", which is **two bushes and a
// rock**, with no slime anywhere in it. `hp` is what a **harvestable** has, not what an enemy
// has; the slime does not carry the field at all.
//
// So the census stops guessing and observes the one thing that is true of every killable
// thing whatever its fields are: **the game removes it from the world**. This step walks the
// whole live world, compares it with the previous step's list, and reports **what left** - a
// killed slime, a picked bush, a broken rock, all through the same honest door. What it is, is
// answered by the object itself: `object_get_name` and its own `hp` if it has one.
//
// That is also the shape the rest of the mod already uses for plants (see the bush census
// above), so there is one way of noticing something disappear, not three.
//
// **The diff must run every step, and it did not.** `global.coopMobCensus < 2` made it a
// **one-shot**: it compared step 1 with step 2 and then never ran again - so it could not
// report a slime killed a minute later, and it could not even report the world's contents,
// which is why the owner's log had **no census line at all** and "the slime is still not
// there". A diff of *this step against the last* has to be taken every step by definition;
// the throttle belongs on the *log line*, not on the comparison.
if (instance_exists(objPlayer)) {
    var _wlk_ids = [];
    var _wlk_obj = [];
    var _wlk_x   = [];
    var _wlk_y   = [];
    var _cnt_all = instance_number(all);
    if (_cnt_all > 3000) _cnt_all = 3000;      // a census, not a sweep of the whole map
    for (var _ai = 0; _ai < _cnt_all; _ai += 1) {
        var _ainst = instance_find(all, _ai);
        if (!instance_exists(_ainst)) continue;
        array_push(_wlk_ids, _ainst.id);
        array_push(_wlk_obj, _ainst.object_index);
        array_push(_wlk_x,   floor(_ainst.x));
        array_push(_wlk_y,   floor(_ainst.y));
    }
    // Worth reporting: what left the world since the last step.
    var _gone_text = "";
    var _gone_n = 0;
    for (var _gp = 0; _gp < array_length(global.coopAllIds); _gp += 1) {
        var _still = false;
        for (var _gq = 0; _gq < array_length(_wlk_ids); _gq += 1) {
            if (_wlk_ids[_gq] == global.coopAllIds[_gp]) { _still = true; break; }
        }
        if (_still) continue;
        _gone_n += 1;
        if (_gone_n <= 4) {
            _gone_text += " | LEFT obj#" + string(global.coopAllObj[_gp])
                        + " '" + object_get_name(global.coopAllObj[_gp]) + "'"
                        + " id " + string(global.coopAllIds[_gp])
                        + " at " + string(global.coopAllXs[_gp]) + "," + string(global.coopAllYs[_gp]);
        }
    }
    global.coopAllIds = _wlk_ids;
    global.coopAllObj = _wlk_obj;
    global.coopAllXs  = _wlk_x;
    global.coopAllYs  = _wlk_y;
    if (_gone_n > 0) {
        var _gone_line = "Co-op: " + string(_gone_n) + " thing(s) left the world" + _gone_text;
        Trace(_gone_line);
        CoopSendDebugLine(_gone_line);
    }
    // And, once every couple of seconds, what the world holds - so the next session can see
    // whether a slime is even in the room.
    global.coopMobTick += 1;
    if (global.coopMobTick mod 120 == 0) {
        var _name_text = "";
        var _shown = 0;
        for (var _s = 0; _s < array_length(_wlk_obj); _s += 1) {
            if (_shown >= 6) break;
            var _dupe = false;
            for (var _t = 0; _t < _s; _t += 1) {
                if (_wlk_obj[_t] == _wlk_obj[_s]) { _dupe = true; break; }
            }
            if (_dupe) continue;
            _name_text += " " + object_get_name(_wlk_obj[_s]);
            _shown += 1;
        }
        var _world_line = "Co-op: " + string(array_length(_wlk_ids))
                        + " instances in the world, first objects:" + _name_text;
        Trace(_world_line);
        CoopSendDebugLine(_world_line);
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
 
 i f   ( k e y b o a r d _ c h e c k _ p r e s s e d ( o r d ( " D " ) ) )   {   g l o b a l . c o o p D u s t D e b u g   =   ! g l o b a l . c o o p D u s t D e b u g ;   T r a c e ( " C o - o p :   d u s t   d e b u g   "   +   ( g l o b a l . c o o p D u s t D e b u g   ?   " O N "   :   " O F F " ) ) ;   }  
 
if (keyboard_check_pressed(ord('D'))) { global.coopDustDebug = !global.coopDustDebug; Trace('Co-op: dust debug ' + (global.coopDustDebug ? 'ON' : 'OFF')); }
