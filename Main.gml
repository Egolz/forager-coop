#define Main
// ============================================================================
// Forager Co-op - presence (M1) + host-authoritative structure placement (M2.1).
//
// Design:  https://github.com/cranebeaker/coop-anything/tree/main/games/forager
// Protocol: docs/PROTOCOL.md
//
// This mod compiles with the game's own loader (main menu -> modding -> enable
// the mod -> COMPILE). No external tool is required - proven by M0.
//
// Controls:  F5 = host   F6 = join   F7 = disconnect   F8 = status
//            F9 = dump structures   F10 = probe the world   F11 = probe the API
//            F12 = probe the spot   F3 = probe the item database (see Net.gml)
//
// The hotkeys are the first free function keys in this build: F1-F2 are the game's
// own help/console helpers and F4 is alt-F4-adjacent on some layouts, so the probes
// start at F3 rather than at F1.
// Console for Trace output: the `t` key.
// ============================================================================

enum CoopCmd {
    HELLO            = 1,   // client -> host: protocol, mod version
    WELCOME          = 2,   // host -> client: protocol, mod version
    REJECT           = 3,   // host -> client: reason
    PING             = 4,   // either way: nonce
    PONG             = 5,   // either way: nonce
    POS              = 6,   // either way: puppet position/room/facing
    BYE              = 7,   // either way: reason
    // --- M2: world sync ---
    INTENT_PLACE     = 8,   // client -> host: please place this structure
    MUTATION_PLACE   = 9,   // host -> client: this structure exists now, at sequence N
    INTENT_REJECTED  = 10,  // host -> client: that intent is refused, and here is why
    STRUCTURE_TABLE  = 11,  // host -> client: the structure id/name list
    DEBUG_LINE       = 12,  // either way: one line of the sender's console
    // --- M2.2: resources and loot ---
    ITEM_TABLE       = 13,  // host -> client: the item id/name list
    DROP             = 14,  // either way: an item appeared in the world
    PICKUP           = 15,  // either way: an item left the world (picked up)
    RESOURCE_DESTROY = 16   // either way: a resource (tree/rock/...) was harvested
}

global.coopVersion  = "0.0.20-m2r";
global.coopProtocol = 4;   // 1 = presence only (M1); 2 adds the world-sync packets;
                           // 3 adds DEBUG_LINE, the remote console; 4 adds the
                           // M2.2 loot packets (DROP/PICKUP/RESOURCE_DESTROY)
global.coopPort     = 6511;
global.coopPlaceRange = 448;   // see Net.gml: how far a client may place from itself
global.coopSolidRadius = 24;   // see Net.gml: how close counts as the same build-cell
global.coopSolidObj    = -2;   // -2 = not resolved yet, -1 = no parSolid in this build
global.coopLivingObjs  = [];   // player/NPC/enemy/pet object indices, resolved lazily

global.coopIsHost    = false;  // we own the listening server
global.coopConnected = false;  // a peer socket is up
global.coopPeerAlive = false;  // handshake completed

global.coopSocket = -1;        // the socket we talk to the peer on (both sides)
global.coopServer = -1;        // listening server (host only)

global.coopPeer = { x: 0, y: 0, angle: 0, room: -1, sprite: -1, image: 0, facing: 1, seen: false };
global.coopPeerVersion = "";

// M3. The name the other player chose, shown over their puppet (M3.3). It travels
// in HELLO/WELCOME, so it is known from the first handshake - no extra packet, and
// it arrives before the first puppet is ever drawn.
global.coopName     = "player";  // what we call ourselves; see CoopLocalName below
global.coopPeerName = "";        // what the peer called themselves ("peer" until known)

// Temporary: how many resource-spawn probe lines have gone out (see
// Events/OnResourceSpawn.gml). Reset each session; the probe is removed when M2.2's
// resource coverage is settled.
global.coopSpawnProbe = 0;

// Temporary: the bush probe (see Events/OnStep.gml, "bush probe"). A first probe watched
// the bush's **frame**, because PencilPal syncs bushes by watching `image_index` change -
// and found nothing at all while bushes were picked. A second probe watched for the bush
// **disappearing**, and that is what happens: `probe bush GONE: id 101898 was 728s600s4`
// with the berries falling at the same `728,600`, while the census read
// `standard 5 vs true 5` - so bushes are active and "gone" means **picked**, not "left the
// room". A picked bush therefore fires **no event**, changes **no frame** and simply
// vanishes, which is why OnResourceDestroy never saw it. The probe now reports the
// vanished bush's object index, name, parent and tile, and **sends the removal** as the
// same RESOURCE_DESTROY the tree and rock already use.
//
// The state is four **numeric** parallel arrays (object, id, x, y), not a ds_map and not a
// packed string: this build has no ds_map_find_first/ds_map_find_next to walk a map, and
// **no string_split** - the first version of this probe died in the loader with
// `string_split is not a function or script`. Numbers need neither.
global.coopBushProbe  = 0;
global.coopBushGone   = 0;
global.coopBushCensus = 0;
global.coopBushObjAt  = [];     // object index of each live bush, last step
global.coopBushIds    = [];     // their instance ids
global.coopBushXs     = [];     // their x
global.coopBushYs     = [];     // their y
global.coopBushObj    = -2;     // -2 = unresolved, -1 = no bush object in this build
global.coopPingNonce   = 0;
global.coopPingSentAt  = -1;
global.coopPingMs      = -1;
global.coopTick        = 0;

// ---------------------------------------------------------------------------
// M2: host-authoritative world state.
// The host owns the world. A client never writes to it: it asks (an "intent"),
// the host decides, applies the change itself and broadcasts it with a
// monotonic `seq`. Clients apply confirmed mutations in seq order.
// ---------------------------------------------------------------------------
global.coopSeq            = 0;     // sequence number of the last mutation applied
global.coopIntentCounter  = 0;     // our own intent ids, to match confirmations
global.coopPending        = [];    // our unconfirmed predictions: [ [id, x, y, sid, obj] ]
global.coopApplyingRemote = false; // re-entrancy guard: we are applying a peer's change

// A snapshot of the game's structure database, so a name can be turned into an
// id and an object index without scanning the database on every packet.
// It is built **lazily** by CoopBuildStructDb() in Net.gml: the database may not
// be up yet while Main runs (Main executes during the registration pass), and a
// mod that is never in a session should not pay for it at all.
global.coopStructNames   = [];  // id -> lowercase name, e.g. "forge"
global.coopStructObjects = [];  // id -> object index, e.g. objForge

// M2.2. The item database, snapshotted the same lazy way (CoopBuildItemDb in
// Net.gml). A resource drop and a pickup both travel as an **item id**, and the
// two installs must agree on what id 12 means, so the table is shipped to the peer
// on join and compared, exactly like the structure table.
global.coopItemNames = [];      // id -> lowercase name from ItemGet(id, ItemData.Name)
global.coopItemCount = 0;       // Item.Count at the time we last looked

// ---------------------------------------------------------------------------
// M2.2. Loot and resource sync. Same host-authoritative shape as placement: a
// client never writes to the world, it asks.
//
// The wire carries item **ids** (Item.Wood == 0 etc., verified live by F3) - the
// names are localized and stay in the logs. A drop is announced by the machine that
// saw it; the *host* decides whether it counts. Keeping it simple on purpose: this
// slice moves items and resource destruction, not HP or inventory totals.
// ---------------------------------------------------------------------------
global.coopApplyingLoot = false;   // re-entrancy guard, like coopApplyingRemote
global.coopLootDrops     = 0;      // counters, for the status line
global.coopLootPicks     = 0;
global.coopLootBreaks    = 0;

Trace("Forager Co-op " + global.coopVersion + " loaded (protocol "
      + string(global.coopProtocol) + ", port " + string(global.coopPort) + ").");
Trace("Keys: F5 host, F6 join, F7 disconnect, F8 status, F9 dump structures.");
