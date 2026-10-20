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

// Diagnostic, temporary (build-grid investigation, 2026-10-20). A structure the **game** places
// is the ground truth for where a structure belongs, and this is the only place that sees one.
// It reports the raw spawn coordinates and their remainders against the candidate cell sizes
// (8, 12, 16, 24), which is what settled the grid: the world is tiled at **16 px**, and a
// structure reports its block corner while a natural object reports its cell centre.
CoopSendDebugLine("probe spawn: obj#" + string(i.object_index)
                  + " '" + object_get_name(i.object_index) + "'"
                  + " name '" + _name + "' struc " + string(struc)
                  + " at " + string(i.x) + "," + string(i.y)
                  + " mod8 " + string(i.x mod 8) + "," + string(i.y mod 8)
                  + " mod16 " + string(i.x mod 16) + "," + string(i.y mod 16)
                  + " mod24 " + string(i.x mod 24) + "," + string(i.y mod 24)
                  + " sprite " + string(i.sprite_index)
                  + " depth " + string(i.depth));

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
