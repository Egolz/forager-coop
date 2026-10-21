#define OnMobDeath(inst)
// A mob died - the slime the player killed.
//
// The mob's **death** is the part that matters for a shared world: the enemy is gone on
// this machine, and without this the other machine still has it standing there and still
// attacking its player. The reference mod has the same hook (`OnMobDeath(inst)`) and the
// same idea; its handler is marked `return; // WIP`, so whether the event fires is what
// this mod is here to find out.
//
// The mob is identified the same way it was born: instance id, object index and position.
if (!global.coopPeerAlive) return;        // no one to tell
if (!instance_exists(objPlayer)) return;  // menus, logo rooms
if (!instance_exists(inst)) return;

CoopSendMob(1, inst.x, inst.y, inst.id, inst.object_index);

var _md_text = "Co-op: a mob died - " + object_get_name(inst.object_index)
             + " at " + string(floor(inst.x)) + "," + string(floor(inst.y))
             + " (id " + string(inst.id) + ").";
Trace(_md_text);
CoopSendDebugLine(_md_text);
