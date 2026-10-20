#define OnItemGet(items, size)
// The player picked something up. `items` is the item id, `size` the quantity
// (PencilPal's handler reads exactly these two, which is where the signature comes
// from - the docs do not document OnItemGet either).
//
// Why this needs a packet at all: the pickup happens on one machine, and the item
// is now in *that* player's inventory - but the dropped instance sitting in the
// shared world has to disappear on the other machine too, or the host walks up and
// picks up a pile the client already took.
//
// What this deliberately does NOT do yet: move the item into the other player's
// inventory. Inventories are per-player and this slice only syncs the **world**;
// the money/inventory half is its own step (see M2.4 in DESIGN.md). Trying to do
// both at once is how the placement slice got its "invisible structure" bug - one
// claim at a time, verified.
//
// There is no clean position in this event: the pickup is reported by item, not by
// tile (`size` is a count, not an x). So the drop is located on the far side by
// item id near the *other* player - see CoopApplyPickupNear().

if (global.coopApplyingLoot) return;     // we are mirroring a peer's pickup
if (!global.coopPeerAlive) return;       // no one to tell
if (!instance_exists(objPlayer)) return; // menus, logo rooms

// A pickup with no position: the far end finds the nearest drop of that item to
// its own player. Report our player's position so the far end searches the right
// island rather than the whole world.
CoopSendPickup(objPlayer.x, objPlayer.y, items);
Trace("Co-op: " + (global.coopIsHost ? "announced" : "asked host to confirm")
      + " pickup item #" + string(items) + " x" + string(size)
      + " (" + CoopItemName(items) + ").");
