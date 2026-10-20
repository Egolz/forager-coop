#define OnItemDrop(d)
// An item fell into the world (a resource dropped its loot, a structure was
// destroyed, a recipe popped out). Fires on the machine whose world did it.
//
// d = an array of drops; each entry has x, y, item, stack (and id). PencilPal's
//     own handler walks exactly this array and reads those four fields directly,
//     which is where this shape comes from - the docs do not document OnItemDrop
//     at all. The entries are **structs**, and this build has no `is_struct` or
//     `variable_struct_exists` in its symbol table (checked offline), so there is
//     no runtime test to write: the field access is the test, and the working mod
//     proves the fields are there.
//
// Same shape as placement:
//   host   -> the world already has it; announce it as a confirmed change
//   client -> we only *predicted* it locally; ask the host to confirm
//
// The re-entrancy guard matters here: CoopApplyDrop() calls DropItem(), which
// spawns a drop and would otherwise call straight back into this event.

if (global.coopApplyingLoot) return;     // we are mirroring a peer's drop
if (!global.coopPeerAlive) return;       // no one to tell
if (!instance_exists(objPlayer)) return; // menus, logo rooms
if (array_length(d) <= 0) return;

for (var _od_i = 0; _od_i < array_length(d); _od_i++) {
    var _od = array_get(d, _od_i);

    var _od_x     = _od.x;
    var _od_y     = _od.y;
    var _od_item  = _od.item;
    var _od_stack = _od.stack;
    if (_od_stack <= 0) _od_stack = 1;

    // Both roles announce; the difference is only who applies it. The host is the
    // one that applies, so a client's drop is a request and the host's is the fact.
    CoopSendDrop(_od_x, _od_y, _od_item, _od_stack);
    if (global.coopIsHost) {
        Trace("Co-op: announced drop item #" + string(_od_item) + " x"
              + string(_od_stack) + " at " + string(floor(_od_x)) + ","
              + string(floor(_od_y)) + " (" + CoopItemName(_od_item) + ").");
    } else {
        Trace("Co-op: asked host to confirm drop item #" + string(_od_item)
              + " at " + string(floor(_od_x)) + "," + string(floor(_od_y)) + ".");
    }
}
