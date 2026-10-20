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

if (global.coopApplyingRemote) return;    // we are re-creating a peer's structure
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
