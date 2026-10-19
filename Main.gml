#define Main
// ============================================================================
// Forager Co-op - M1: direct-TCP presence layer.
// Design: ../../games/forager/DESIGN.md
// API reference: https://topheranselmo.com/forager-modding-docs/
//
// This mod compiles with the game's own loader (main menu -> modding -> enable
// the mod -> COMPILE). No external tool is required - proven by M0.
//
// Controls:  F5 = host   F6 = join   F7 = disconnect   F8 = status
// Console for Trace output: the `t` key.
// ============================================================================

enum CoopCmd {
    HELLO   = 1,   // client -> host: protocol, mod version
    WELCOME = 2,   // host -> client: protocol, mod version
    REJECT  = 3,   // host -> client: reason
    PING    = 4,   // either way: nonce
    PONG    = 5,   // either way: nonce
    POS     = 6,   // either way: puppet position/room/facing
    BYE     = 7    // either way: reason
}

global.coopVersion  = "0.0.2-m1";
global.coopProtocol = 1;
global.coopPort     = 6511;

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

Trace("Forager Co-op " + global.coopVersion + " loaded (protocol "
      + string(global.coopProtocol) + ", port " + string(global.coopPort) + ").");
Trace("Keys: F5 host, F6 join, F7 disconnect, F8 status.");
