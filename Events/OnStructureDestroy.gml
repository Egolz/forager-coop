#define OnStructureDestroy(i, structure)
// A built structure left the world - the player demolished it, an enemy broke it, a save
// cleared it. This event was **missing from this mod entirely** until now: our resource
// sync covers trees, rocks and bushes, but a structure is neither, so demolishing a furnace
// left it standing on the other player's island.
//
// It was written as a probe first, and the probe is what makes this file safe to turn on.
// The event carries an undocumented `structure` argument, and the live run (2026-10-20,
// `0.0.17-m2o`) showed what it is:
//
//   probe OnStructureDestroy: obj#109 'objFurnace' parent 'parStructure' structure=1 at 672,672
//   OnItemDrop fired, 1 entries: 0:[item1 id=102231 x10 @672,672]   <- the furnace refunded 10 stone
//
//   * `structure` really is the **structure database index** (row 1 = "печь"/furnace), so
//     the wire key the rest of M2 wanted is available directly from the event.
//   * the parent is `parStructure`, a family distinct from `parNatural` (`parResource` and
//     co.), which is a clean way to tell buildings from nature.
//   * a demolished structure **refunds its materials as a drop** (`x10`), and that refund
//     arrives through OnItemDrop like any other loot - so nothing extra is needed here for
//     it; the loot path already carries it.
//
// Why this reuses RESOURCE_DESTROY instead of adding a packet. The far end does not need to
// know whether the thing that vanished was a tree or a furnace: it needs "the instance with
// this object index at this tile is gone". `CoopApplyResourceDestroy` already does exactly
// that, matching on object index plus tile and walking TrueInstanceNumber so an offscreen
// instance is found too. And an object index **does** identify a structure: the structure
// database stores each row's object (`StructureGet(id, StructureData.Object)` - objFurnace,
// objVeranda, ...), so no two structures share one by accident. Inventing a
// STRUCTURE_DESTROY packet would mean a second switch case, a second mock parser and a
// second e2e assertion to carry the same three numbers, for no gain.
//
// The one thing this does **not** send is the structure id. It is not needed to remove the
// instance, and it would only be needed to *recreate* one - which is the opposite direction
// (there is no undo of a demolish, and a save reload rebuilds structures of its own accord).
// So the id is used for the log line, where a human reads it, and the wire carries the
// object index and the tile, where a machine matches on it.

if (global.coopApplyingRemote) return;    // we are removing a peer's structure locally
if (!global.coopPeerAlive) return;        // no one to tell
if (!instance_exists(objPlayer)) return;  // menus, logo rooms
if (!instance_exists(i)) return;

// Same reasoning as OnStructureSpawn: this fires for the player demolishing something, for
// mod code, and for whatever a loaded save clears, so it must not act on a world it does not
// own. Host-authoritative, like everything else: the host (and a client acting alone, since
// this mod has no separate roles beyond the place path) simply announces the removal and
// lets the far end mirror it. There is no intent/confirm pair here because a demolish has
// nothing to validate - no cost, no placement rule - unlike building, which is why placing
// goes through INTENT_PLACE and this does not.
CoopSendResourceDestroy(i.x, i.y, i.object_index);

Trace("Co-op: structure removed obj#" + string(i.object_index)
      + " at " + string(floor(i.x)) + "," + string(floor(i.y))
      + " (structure id " + string(structure) + ").");
