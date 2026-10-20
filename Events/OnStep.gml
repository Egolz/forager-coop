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

if (!global.coopPeerAlive) exit;

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
if (global.coopTick mod 3 == 0) CoopSendPos();

// ============================================================================
// Bush probe, second version (M2.2 coverage, 2026-10-20). **Read-only.**
//
// The first version watched a bush's `image_index` for a change. It found the three bush
// objects (`obj#86 obj#90 obj#87`) and then reported **nothing** while two bushes were
// picked - the owner's berries dropped (`item54` x3, twice) and **no `probe bush changed`
// line appeared**. So a picked bush does **not** change its frame; it goes away. That
// matches what the owner said ("исчезает совсем") and rules out the PencilPal
// `grows`-and-regrow reading for *this* build's berry bush.
//
// So the probe now inverts: instead of watching for a change, it remembers **which bushes
// existed** and reports the ones that **vanished**. The report carries the vanished bush's
// **position** - which is exactly what a RESOURCE_DESTROY line needs - so once this fires
// we know both the event path and the coordinates to send.
//
// It still watches for an `image_index` change too, in the same pass: harmless, and if some
// *other* bush-like object (cotton, flower) does regrow rather than vanish, it will show up
// here rather than being missed for a second round.
//
// What this build does NOT have, and why the probe is shaped this way:
//   - no variable_instance_exists (0 in data.win), so "is this instance a bush" cannot be
//     asked; the bushes are found by **object name** via asset_get_index instead, using the
//     names from PencilPal's own list (its Main.gml:65 `["objBush", "objCotton", "objFlower"]`);
//   - no ds_map_find_first / ds_map_find_next (both 0), so the memory cannot be walked as a
//     ds_map - it is kept as **two parallel arrays** (ids and their "x s y s image" strings)
//     instead, which are trivially walkable and cannot crash on a missing iterator;
//   - try/catch is banned in mod code, so nothing here may depend on a call that can throw.

// Resolve the bush objects once per session. asset_get_index returns **-1**, not an error,
// for a name this build lacks, so an absent bush object just drops out of the list.
if (global.coopBushObj == -2) {
    global.coopBushObj = [];
    var _names = ["objBush", "objCotton", "objFlower"];
    for (var _n = 0; _n < array_length(_names); _n += 1) {
        var _idx = asset_get_index(_names[_n]);
        if (_idx >= 0) array_push(global.coopBushObj, _idx);
    }
    CoopSendDebugLine("probe bush: resolved " + string(array_length(global.coopBushObj))
                      + " bush object(s) of 3: " + string(global.coopBushObj));
}

if (array_length(global.coopBushObj) > 0) {
    // Four numeric parallel arrays (object, id, x, y), recorded last step. See the push
    // site for why these are separate arrays of numbers rather than one packed string.
    var _prev_obj = global.coopBushObjAt;
    var _prev_id  = global.coopBushIds;
    var _prev_x   = global.coopBushXs;
    var _prev_y   = global.coopBushYs;
    var _now_obj  = [];
    var _now_id   = [];
    var _now_x    = [];
    var _now_y    = [];

    for (var _b = 0; _b < array_length(global.coopBushObj); _b += 1) {
        var _obj   = global.coopBushObj[_b];
        // instance_number/instance_find are the standard pair; the True* pair that
        // CoopApplyResourceDestroy uses also sees deactivated instances. Bushes that are
        // off-room may be deactivated, and a deactivated bush that becomes active is a
        // *change of being seen*, not a pick - so both counts are logged once, to tell
        // the two apart instead of mistaking a room change for a harvest.
        var _count = instance_number(_obj);
        for (var _i = 0; _i < _count; _i += 1) {
            var _inst = instance_find(_obj, _i);
            if (!instance_exists(_inst)) continue;
            // Four **numeric** parallel arrays, filled together in one pass and never
            // touched again: object index, instance id, x, y. They are pushed in the same
            // iteration, so they cannot drift; the earlier worry about parallel arrays
            // going out of step applies to arrays written at different times, which these
            // are not. Numbers, not a packed string, on purpose: unpacking a string needs
            // string_split/string_copy, and **string_split is not in this build's function
            // table** (it is only `fgml_std_string_split`, a library symbol) - the first
            // run of this probe died with exactly
            // `Mod failed to unit! Forager Coop/Net.gml[L411,c11] string_split is not a
            // function or script`. Nothing here needs a string function at all now.
            //
            // Only fields every drawn object has are read - `hp` and `grows` are
            // deliberately NOT touched, because this build has no variable_instance_exists
            // to test them with and a missing field would take the game down.
            array_push(_now_obj, _inst.object_index);
            array_push(_now_id,  _inst);
            array_push(_now_x,   floor(_inst.x));
            array_push(_now_y,   floor(_inst.y));
        }
    }

    // A bush that was here last step and is gone now. The instance is gone, so its object
    // index, x and y can only come from the arrays recorded last step - which is why those
    // are stored and not just the id.
    //
    // This is the finding of the second probe (live 2026-10-20): picking a bush produced
    // **no event and no frame change** - the instance simply vanished - while the census
    // showed `standard 5 vs true 5`, i.e. bushes are active and "gone" means picked, not
    // "left the room". The vanished bush's position matched the berry drop exactly
    // (`GONE ... 728s600s4` and the berries fell at `728,600`). So the bush has no event to
    // hook and must be **observed**, and its removal then travels as the very packet the
    // tree and rock already use.
    for (var _p = 0; _p < array_length(_prev_id); _p += 1) {
        var _still_there = false;
        for (var _q = 0; _q < array_length(_now_id); _q += 1) {
            if (_now_id[_q] == _prev_id[_p]) { _still_there = true; break; }
        }
        if (_still_there) continue;

        global.coopBushGone += 1;
        if (global.coopBushGone > 20) continue;    // volume guard

        CoopSendDebugLine("probe bush GONE #" + string(global.coopBushGone)
                          + ": obj#" + string(_prev_obj[_p])
                          + " '" + object_get_name(_prev_obj[_p]) + "'"
                          + " parent '" + object_get_name(object_get_parent(_prev_obj[_p])) + "'"
                          + " id " + string(_prev_id[_p])
                          + " at " + string(_prev_x[_p]) + "," + string(_prev_y[_p])
                          + " room " + string(objPlayer.room));

        // **The sync itself, tried for real.** A bush goes away the same way a tree does,
        // so it goes out the same way: RESOURCE_DESTROY with the object index and the tile.
        // This is safe to send even while the probe is still running - the far end already
        // knows how to remove a resource by index+position (CoopApplyResourceDestroy), and
        // its walk uses TrueInstanceNumber, so a bush object index it is handed will be
        // found and destroyed. Nothing new is invented; the packet that exists is reused.
        CoopSendResourceDestroy(_prev_x[_p], _prev_y[_p], _prev_obj[_p]);
    }

    global.coopBushObjAt = _now_obj;
    global.coopBushIds   = _now_id;
    global.coopBushXs    = _now_x;
    global.coopBushYs    = _now_y;

    // One-off census, so a silent probe can be told apart from "there are no bushes here".
    // It reports the **standard** count and the **TrueInstance** count side by side: the
    // standard pair skips deactivated instances, the True pair is what
    // CoopApplyResourceDestroy walks. If they disagree, bushes are being deactivated while
    // off-screen, and "GONE" would then mean "left the room" rather than "was picked" -
    // exactly the confusion this line exists to prevent.
    global.coopBushCensus += 1;
    if (global.coopBushCensus == 60 || global.coopBushCensus == 300) {
        var _true_total = 0;
        for (var _t = 0; _t < array_length(global.coopBushObj); _t += 1) {
            _true_total += TrueInstanceNumber(global.coopBushObj[_t]);
        }
        CoopSendDebugLine("probe bush census #" + string(global.coopBushCensus)
                          + ": standard " + string(array_length(_now_id))
                          + " vs true " + string(_true_total)
                          + " bush instance(s), objects " + string(global.coopBushObj));
    }
}
