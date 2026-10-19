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
//            (see Net.gml)
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
    DEBUG_LINE       = 12   // either way: one line of the sender's console
}

global.coopVersion  = "0.0.7-m2e";
global.coopProtocol = 3;   // 1 = presence only (M1); 2 adds the world-sync packets;
                           // 3 adds DEBUG_LINE, the remote console
global.coopPort     = 6511;
global.coopPlaceRange = 448;   // see Net.gml: how far a client may place from itself

global.coopIsHost    = false;  // we own the listening server
global.coopConnected = false;  // a peer socket is up
global.coopPeerAlive = false;  // handshake completed

global.coopSocket = -1;        // the socket we talk to the peer on (both sides)
global.coopServer = -1;        // listening server (host only)

global.coopPeer = { x: 0, y: 0, angle: 0, room: -1, sprite: -1, image: 0, facing: 1, seen: false };
global.coopPeerVersion = "";
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

Trace("Forager Co-op " + global.coopVersion + " loaded (protocol "
      + string(global.coopProtocol) + ", port " + string(global.coopPort) + ").");
Trace("Keys: F5 host, F6 join, F7 disconnect, F8 status, F9 dump structures.");
