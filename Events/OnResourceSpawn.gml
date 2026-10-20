#define OnResourceSpawn(l)
// A resource appeared in the world - a tree, a rock, a berry bush, ore. PencilPal
// uses this to mirror spawned resources (Events/OnEvent.gml, line 1) and reads `hp`,
// `hpMax`, `image_index` and `depth` off the instance, which is why it is the event to
// probe next: the owner asked to see the same visuals as the host, and a resource's
// HP/stage is exactly what makes a half-mined rock look half-mined.
//
// **This file is a probe, not a sync.** It reports what arrives so the real handler
// can be written against facts. The question it answers right now is the one the owner
// raised: whether a **berry bush** and other pickable resource take this path at all,
// or a different one - if a bush never fires here, mirroring it will need a different
// event, and writing the mirroring first would have been wasted work.
//
// Fields are read defensively: `hp`, `hpMax`, `image_index` and `depth` are all read by
// PencilPal on this same event, so they are present on the objects it cares about - but
// this probe is deliberately pointed at *unusual* resources (bushes, ore), which is the
// case that would expose a field that is not universal. Nothing here writes to the
// world, so a surprise costs a log line, not a desync.

if (!global.coopPeerAlive) return;        // no one to listen
if (!instance_exists(objPlayer)) return;  // menus, logo rooms
if (!instance_exists(l)) return;

// Volume guard. Loading a save or changing a room can spawn every resource on the
// island at once, and this probe would turn coop_debug.txt into a wall of identical
// lines with the interesting harvest buried in it. So only the first few spawns of a
// session are reported, and only a handful per object type: what we need is the *set*
// of object names and parents, not a census. The counter is a global because the
// probe is temporary and a global is the one place a #define cannot hide state.
global.coopSpawnProbe = global.coopSpawnProbe + 1;
if (global.coopSpawnProbe > 60) return;
if (global.coopSpawnProbe mod 4 != 1) return;

CoopSendDebugLine("probe OnResourceSpawn #" + string(global.coopSpawnProbe)
                  + ": obj#" + string(l.object_index)
                  + " '" + object_get_name(l.object_index) + "'"
                  + " parent '" + object_get_name(object_get_parent(l.object_index)) + "'"
                  + " at " + string(floor(l.x)) + "," + string(floor(l.y))
                  + " depth " + string(l.depth)
                  + " image " + string(l.image_index)
                  + " room " + string(objPlayer.room));
