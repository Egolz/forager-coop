#define OnResourceDestroy(i)
// A resource was harvested - a tree felled, a rock mined, a bush picked - and the
// instance is about to leave the world.
//
// i = the instance being destroyed.
//
// This is the *cause* half of a drop: on the machine that did the harvesting it
// fires, the resource's own code drops its loot, and OnItemDrop() announces that.
// So this event only has to tell the other machine to remove the resource itself -
// otherwise the tree the client cut is still standing on the host's island.
//
// Host-authoritative, like everything else:
//   host   -> announce the removal as a confirmed change
//   client -> ask the host to remove it too
//
// The object travels as an **object index**, never a name: the names are localized
// (F3, 2026-10-20) and the index is a build constant, so the far end matches the
// same object whatever language it runs.

if (global.coopApplyingLoot) return;     // we are mirroring a peer's harvest
if (!global.coopPeerAlive) return;       // no one to tell
if (!instance_exists(objPlayer)) return; // menus, logo rooms
if (!instance_exists(i)) return;

CoopSendResourceDestroy(i.x, i.y, i.object_index);
if (global.coopIsHost) {
    Trace("Co-op: announced resource destroy " + object_get_name(i.object_index)
          + " at " + string(floor(i.x)) + "," + string(floor(i.y)) + ".");
} else {
    Trace("Co-op: asked host to remove " + object_get_name(i.object_index)
          + " at " + string(floor(i.x)) + "," + string(floor(i.y)) + ".");
}
