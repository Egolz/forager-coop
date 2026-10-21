#define Main
// ============================================================================
// Forager Co-op - presence, host-authoritative world sync, and the visible second
// player (M3.1).
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
// start at F3 rather than at F1. F4 was the build-grid probe until 2026-10-21 and
// is free again.
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
    RESOURCE_DESTROY = 16,  // either way: a resource (tree/rock/...) was harvested
    // --- M3.1: the world snapshot ---
    SNAP_LAND        = 17,  // host -> client: a chunk of the world's land cells
    SNAP_STRUCT      = 18   // host -> client: a chunk of the world's structures
}

global.coopVersion  = "0.0.56-m3v";
global.coopProtocol = 6;   // 1 = presence only (M1); 2 adds the world-sync packets;
                           // 3 adds DEBUG_LINE, the remote console; 4 adds the
                           // M2.2 loot packets (DROP/PICKUP/RESOURCE_DESTROY);
                           // 5 adds the player name to HELLO/WELCOME (M3.1);
                           // 6 adds the world snapshot (SNAP_LAND, SNAP_STRUCT)
                           //
                           // The number moves when the **wire format** moves, not when a
                           // feature is added. 5 was free again after a rejected CMD
                           // experiment, and M3.1 needed it: HELLO and WELCOME grew a
                           // `string name` field, so a peer still speaking 4 would read our
                           // name as the end of the version string and then read garbage
                           // after it. A protocol number that survives a format change is
                           // how a field-order bug survives a review.
                           //
                           // 6 is the same kind of move: SNAP_LAND is a new packet, and a
                           // peer that does not know it would silently receive no land at
                           // all - a client whose island never becomes the host's island,
                           // with no error anywhere. Better to refuse the join.
global.coopPort     = 6511;
global.coopPlaceRange = 448;   // see Net.gml: how far a client may place from itself
global.coopSolidRadius = 16;   // see Net.gml: how close counts as the same build-cell
// How much room a built thing needs, and what the world is tiled at.
//
// **16, not 24, and this is measured rather than assumed.** The build-cell was 24 for most of
// this mod's life on the strength of a reading that turned out to be circular: every structure
// coordinate sampled was a multiple of 24, so 24 "confirmed itself" - but every one of those
// samples had been *created by this mod*, which snaps to 24 because it was told to. A furnace
// the owner built by hand (live, 2026-10-20 19:19) landed at 656,608 and settled the question:
// it is 8 px off the mod's grid on both axes, which is exactly the "half a cell up" reported.
//
// The world's real tiling comes from the objects the **game** places - rocks, trees, bushes,
// which the map itself spawns and no mod touched. Across 19 such spawns:
//
//   smallest non-zero gap between neighbours: 16 px on X and 16 px on Y (gaps were 16 and 32)
//   every x and y remainder mod 16 was a single constant, mod 8 was 0, mod 12/24 was noise
//
// i.e. the world is tiled at 16 px. The two families differ only in which point they report:
// a natural object reports its cell (remainder 8, the cell centre), a structure reports its
// top-left block corner (remainder 0). Both are the same 16 px lattice; 24 is not on it.
//
// So a footprint of 2x2 cells is 32x32 px, and the offsets used to sample the covered area are
// +/-8 from the block centre - not +/-12, which was the 24-grid value and sampled half a cell
// outside the structure it was supposed to describe.
global.coopFootprint   = 16;
global.coopSolidObj    = -2;   // -2 = not resolved yet (kept as the "have we looked" flag)
global.coopSolidObjs   = [];   // the concrete object families that block a build cell: see
                               // CoopSolidNear - `instance_number(parSolid)` is 0 in this
                               // build, so the leaf families are listed instead
global.coopLivingObjs  = [];   // player/NPC/enemy/pet object indices, resolved lazily

global.coopIsHost    = false;  // we own the listening server
global.coopConnected = false;  // a peer socket is up
global.coopPeerAlive = false;  // handshake completed

global.coopSocket = -1;        // the socket we talk to the peer on (both sides)
global.coopSocketOwned = false; // true only for a socket we created with network_create_socket
                               // (the client's); a host's peer socket belongs to the runtime.
                               // Destroying a runtime-owned socket again is the native crash
                               // of 2026-10-20 - see CoopResetPeer in Net.gml.
global.coopServer = -1;        // listening server (host only)

global.coopPeer = { x: 0, y: 0, angle: 0, room: -1, sprite: -1, image: 0, facing: 1, seen: false };
global.coopPeerVersion = "";

// M3. The name the other player chose, shown over their puppet (M3.3). It travels
// in HELLO/WELCOME, so it is known from the first handshake - no extra packet, and
// it arrives before the first puppet is ever drawn.
global.coopName     = "player";  // what we call ourselves; see CoopLocalName below
global.coopPeerName = "";        // what the peer called themselves ("peer" until known)
// M3.1: the handshake is retried until the host answers, because the client's async connect
// event did not arrive on the live run of 2026-10-21 - and with no WELCOME, nothing the mod
// can send is sent. `coopHelloAt` paces the retry, `coopHelloTries` bounds it.
global.coopHelloAt   = 0;
global.coopHelloTries = 0;
// The instances we created from a host's mutation. The structure event for one of them arrives
// a frame later, so the `coopApplyingRemote` flag is down by then - and the client must not
// answer the host's own structure with an intent for it, or the two sides confirm each other
// forever. See OnStructureSpawn.
global.coopRemoteInstances = [];
// M3.1: the body sprite is resolved by **name** (`sprPlayerIdle`), because the player's
// instance reports `sprite_index` 0 - the live body probe of 2026-10-21 found the whole
// instance chain (parEntity #20, objPlayer #22, parAlly #46) with a sprite index of 0, while
// the world objects nearby carried real ones (963, 964). So the body is a constant asset, not
// a property of the instance. See CoopResolveBodySprite.
global.coopBodySprite = -1;
global.coopBodyTried = false;
// Where the peer is actually drawn. The host decides, because the host is the side that
// knows the world - a peer with no physics (the mock) reports a position inside a tree or in
// the water, and the host pulls it onto ground a body could stand on.
global.coopStandX   = 0;
global.coopStandY   = 0;
global.coopStandKey = "";
// M3.1: the world snapshot. The host sends its land cells in chunks; the client keeps the
// host's set as a **grid bitmap** (one entry per 16 px cell, 84 x 84 = 7056 of them) so the
// question "is this cell the host's land?" is an array read and not a walk of the list.
// `coopLandGen` is the snapshot's generation: a chunk whose generation differs from the
// one we have starts a new snapshot and clears the bitmap.
global.coopLandGen   = -1;
global.coopHostLand  = [];
global.coopLandAdded = 0;
global.coopLandRemoved = 0;
// How many times the game's own land function was called and the cell was **still**
// water afterwards. A silent failure looks exactly like "the mod does nothing", so it
// is counted and reported over the wire instead.
global.coopLandFailed = 0;
// M3.2: the structures the world has, as three parallel lists (id, x, y) - the same
// shape the mod uses for the bush sync. The list is filled by OnStructureSpawn, which
// is the only place that sees a structure **and its database id** at the same time: the
// event carries the instance (so the position is known) and the structure id (so the
// far end can build the same thing). There is no way to ask the game for "every
// structure in the world" after the fact - the database holds the *types*, not the
// instances - so the world is watched instead of queried.
global.coopStructIds = [];
global.coopStructXs  = [];
global.coopStructYs  = [];
global.coopStructRooms = [];
// The cells the host's structures stand in, as a bitmap over the same 84 x 84 grid the
// land uses. The client keeps it to know which of **its** structures are the host's
// (and which are leftovers of its own island).
global.coopHostStructCells = [];
global.coopStructGen   = -1;
global.coopStructAdded = 0;
global.coopStructRemoved = 0;


// Bush / pickable-plant sync state (see Events/OnStep.gml, "bush sync"). A bush is not a
// resource in this game - its parent is `parHerb` - so no OnResourceDestroy arrives for it
// and the only way to notice a pick is to remember which plants were here and see which one
// vanishes. State is four **numeric** parallel arrays (object, id, x, y), filled together in
// one pass, not a ds_map (this build has no ds_map_find_first/ds_map_find_next to walk one
// with) and not a packed string (string_split is not in the loader's function table).
global.coopBushObjAt  = [];     // object index of each plant, last step
global.coopBushIds    = [];     // its instance id
global.coopBushXs     = [];     // its x
global.coopBushYs     = [];     // its y
global.coopBushObj    = -2;     // -2 = unresolved, -1 = no such object in this build

global.coopPingNonce   = 0;
global.coopPingSentAt  = -1;
global.coopPingMs      = -1;
global.coopTick        = 0;
// Diagnostic (leave-world crash, 2026-10-20): how many packets this side has handled, sent to
// the peer every few seconds so the **last number before the connection drops** says whether
// the receive side was alive when the game died. It is what separated "the mod is stuck" from
// "the game is gone" for the OnRoomLoad probes, and the same trick is what will say whether
// the crash is tied to processing a packet. Remove with the rest of the diagnostics.
// Diagnostic (native crash, 2026-10-20): the number of the operation the game was last
// inside. It is announced every ~5 s to the peer (see OnStep), and because a native fault
// never reaches error.log, the last value to arrive is the only record of where the game
// died. Set - never reset - right before each operation that could fault.
// Diagnostic (packet corpus, 2026-10-20). The phase marker above names *when* the game
// died; this names *what it had last done*. Every completed operation appends one short
// token here and the whole ring goes out when a new one arrives, so the last corpus the
// peer holds reads like a black box flight recorder: "pos pos pos place water-refused
// ok:pos" says the sender was healthy *after* the placement, and a corpus that stops
// right after `place` says the fault was in applying it. Sender-side only - no wire
// change, no reply, so it also fills the hole left by DebugLine being fire-and-forget.
// Capped by rebuilding without its oldest half, because this build has no array_delete.
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
