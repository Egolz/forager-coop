#define OnStructureDestroy(i, structure)
// A built structure is being removed - the player demolished it, an enemy broke it,
// a save cleared it. This event exists in PencilPal (Events/OnEvent.gml, line 74) and
// was **missing from this mod entirely** until now: our resource sync covered trees,
// rocks and bushes (parResource) but a structure is not a resource, so demolishing a
// furnace left it standing on the other player's island.
//
// **This file is a probe, not a sync.** It only reports what the event carries. The
// mutation side (announcing the removal, and creating nothing in its place) is written
// once the probe says what a structure destroy really looks like - the same order that
// caught the placement bug and the duplicate-drop question. In particular, `structure`
// is documented nowhere and could be an id, a name or something else, so guessing how
// to send it would be how the last two rounds got spent.
//
// Signature (i, structure) is taken from PencilPal; the docs do not list this event and
// its name is not in data.win (event names are looked up as file/define names).

if (!global.coopPeerAlive) return;        // no one to tell, nothing to log
if (!instance_exists(objPlayer)) return;  // menus, logo rooms
if (!instance_exists(i)) return;

CoopSendDebugLine("probe OnStructureDestroy: obj#" + string(i.object_index)
                  + " '" + object_get_name(i.object_index) + "'"
                  + " parent '" + object_get_name(object_get_parent(i.object_index)) + "'"
                  + " structure=" + string(structure)
                  + " at " + string(floor(i.x)) + "," + string(floor(i.y))
                  + " room " + string(objPlayer.room));
