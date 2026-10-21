#define OnStructureSpawn(i, struc)
// Every structure that appears in the world passes through here.
//   host   -> announce it to clients as a confirmed mutation (we own the world)
//   client -> never write to the world; ask the host instead (an intent)
//
// i     = the instance that was just created
// struc = its structure id in Forager's structure database
//
// This fires for the player building something, for mod code and for structures
// that come back with a loaded save - hence the guards.

// **Did the host ask for this one?** The boolean flag alone is not enough, and the live run of
// 2026-10-21 showed why: the event for a structure **we** created arrives a frame later, so by
// the time it fires the flag is already down - and the client answered the host's own
// structure with an intent for it. The host confirmed that, and confirmed the confirmation,
// and the game built a row of furnaces marching to the right forever.
//
// So the instances we create from a host's mutation are **remembered by id**, and the event
// checks that list. The id is known by then, because the event is deferred; and the flag is
// kept as well, for the case where the event is not.
if (global.coopApplyingRemote) return;    // we are re-creating a peer's structure
for (var _os_r = array_length(global.coopRemoteInstances) - 1; _os_r >= 0; _os_r -= 1) {
    if (global.coopRemoteInstances[_os_r] == i) {
        // ours: the host already knows about it. Say nothing.
        var _os_keep = [];
        for (var _os_k = 0; _os_k < array_length(global.coopRemoteInstances); _os_k += 1) {
            if (_os_k != _os_r) array_push(_os_keep, global.coopRemoteInstances[_os_k]);
        }
        global.coopRemoteInstances = _os_keep;
        return;
    }
}
if (!global.coopPeerAlive) return;        // no one to tell
if (!instance_exists(objPlayer)) return;  // menus, logo rooms

var _name = CoopStructureNameOf(struc, i.object_index);
if (_name == "") {
    Trace("Co-op: structure at " + string(floor(i.x)) + "," + string(floor(i.y))
          + " is not in the structure database - not synced.");
    return;
}


if (global.coopIsHost) {
    // i.depth is not the game's depth yet - OnStructureSpawn() runs before the
    // instance is y-sorted (a furnace at y=656 announced depth 0 and settled at
    // -656). Send the game's own value, -y.
    CoopSendMutationPlace(0, i.x, i.y, CoopStructDepth(i.y), _name);
    Trace("Co-op: announced '" + _name + "' at " + string(floor(i.x)) + ","
          + string(floor(i.y)) + " as seq " + string(global.coopSeq) + ".");
} else {
    CoopSendIntentPlace(_name, i.x, i.y);
}
