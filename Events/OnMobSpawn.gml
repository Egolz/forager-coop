#define OnMobSpawn(inst)
// A mob appeared in the world (the slime on the island, mostly).
//
// **The events exist - the reference mod defines handlers for them** (`OnMobSpawn(inst)` and
// `OnMobDeath(inst)` in PencilPal's `Events/OnEvent.gml`), so the loader knows the names.
// PencilPal's own handlers are marked `return; // WIP`, which means nobody ever learned
// whether the events actually fire - that is what this mod is here to find out.
//
// The mob is identified by its **instance id** plus its **object index** and its position -
// the same three numbers the reference mod's `ENEMY` packet carries. The id is the
// identity: two installs of the same world create the same instances in the same order,
// so the ids line up; the position is the fallback, because they do not always.
//
// On the far end the mob is **adopted** if one is already standing there - both machines
// have the same island, so the client usually has a slime at that spot already, and
// creating a second one would double every slime on the island.
if (!global.coopPeerAlive) return;        // no one to tell
if (!instance_exists(objPlayer)) return;  // menus, logo rooms
if (!instance_exists(inst)) return;

CoopSendMob(0, inst.x, inst.y, inst.id, inst.object_index);

var _ms_text = "Co-op: a mob appeared - " + object_get_name(inst.object_index)
             + " at " + string(floor(inst.x)) + "," + string(floor(inst.y))
             + " (id " + string(inst.id) + ").";
Trace(_ms_text);
CoopSendDebugLine(_ms_text);
