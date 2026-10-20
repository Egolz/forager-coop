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

// Live question left open by the first real harvest (2026-10-20, tree at 664,680):
// the peer saw **two** byte-identical DROPs - same x, same y, same item, same
// stack. The second harvest (0.0.14-m2l, tree at 680,680) showed a *third* drop at
// the same tile with a different item id, and the owner then explained it: item #55
// is citrus, a rare bonus drop a tree can give in addition to its wood. So the third
// packet was correct all along, and the real question is narrower - whether the two
// wood entries are two piles that both exist or one pile reported twice.
//
// The field that settles it is `id`: it is the dropped instance's own id (PencilPal
// reads d[l].id and even destroys through it). Two entries with **different ids** are
// two real piles and must both be mirrored; the same id twice is one pile announced
// twice. This matters a lot, because the current dedup (position + item) would
// *swallow a legitimate second wood* if the game really does drop two stacks - a
// silent loot loss, which is exactly the kind of bug worth catching now. So the id
// goes out with the count.
//
// Trace() is no help here: it goes to the on-screen console, and a mod cannot write
// files, so nothing it prints survives a run. DEBUG_LINE is the channel that reaches
// the mock (which writes %TEMP%\coop_debug.txt), so the count goes out that way -
// read-only, and only when someone is listening.
if (global.coopPeerAlive) {
    var _od_seen = "";
    for (var _od_d = 0; _od_d < array_length(d); _od_d++) {
        var _od_e = array_get(d, _od_d);
        _od_seen += (string(_od_d) + ":[item" + string(_od_e.item)
                     + " id=" + string(_od_e.id)
                     + " x" + string(_od_e.stack)
                     + " @" + string(floor(_od_e.x)) + "," + string(floor(_od_e.y))
                     + "] ");
    }
    CoopSendDebugLine("OnItemDrop fired, " + string(array_length(d)) + " entries: "
                      + _od_seen);
}

for (var _od_i = 0; _od_i < array_length(d); _od_i++) {
    var _od = array_get(d, _od_i);

    var _od_x     = _od.x;
    var _od_y     = _od.y;
    var _od_item  = _od.item;
    var _od_stack = _od.stack;
    if (_od_stack <= 0) _od_stack = 1;

    // Skip an entry whose instance id we already handled in *this* same array. That
    // is the one duplicate case that is unambiguously a duplicate: the same dropped
    // instance listed twice in one fire. Cross-fire duplicates are NOT deduped yet -
    // whether those even happen is exactly what the DEBUG_LINE above is measuring,
    // and guessing at it risks the worse error of swallowing a legitimate second
    // pile (a tree here drops several, and citrus #55 alongside its wood - live
    // 2026-10-20). One claim at a time.
    var _od_dup = false;
    for (var _od_j = 0; _od_j < _od_i; _od_j++) {
        if (array_get(d, _od_j).id == _od.id) { _od_dup = true; break; }
    }
    if (_od_dup) continue;

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
