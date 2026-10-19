// Forager Co-op - network layer (M1).
// Plain GameMaker sockets over TCP, one peer. The sync layer later treats this
// as the "DirectTCP" transport backend (see DESIGN.md).

#define CoopSend(_buf)
// Sends a finished packet buffer to the peer and frees it.
var _sock = global.coopSocket;
if (_sock < 0) {
    buffer_delete(_buf);
    exit;
}
network_send_packet(_sock, _buf, buffer_tell(_buf));
buffer_delete(_buf);

#define CoopResetPeer()
// Drops the peer, keeping the listening server (host) if there is one.
global.coopConnected   = false;
global.coopPeerAlive   = false;
global.coopPeer.seen   = false;
global.coopPeerVersion = "";
global.coopPingSentAt  = -1;
global.coopPingMs      = -1;
global.coopSocket      = -1;

#define CoopHost()
if (global.coopIsHost) { Trace("Co-op: already hosting."); exit; }
if (global.coopConnected) { Trace("Co-op: already connected - press F7 first."); exit; }

global.coopServer = network_create_server(network_socket_tcp, global.coopPort, 1);
if (global.coopServer < 0) {
    Trace("Co-op: hosting FAILED (port " + string(global.coopPort)
          + " already in use?). Restart the game and retry.");
    exit;
}
global.coopIsHost = true;
Trace("Co-op: hosting on TCP " + string(global.coopPort) + ", waiting for a peer...");

#define CoopJoin()
if (global.coopIsHost) { Trace("Co-op: you are hosting - press F7 first."); exit; }
if (global.coopConnected) { Trace("Co-op: already connected."); exit; }

var _ip = get_string("Co-op: enter the host's IP", "127.0.0.1");
if (_ip == "") exit;

global.coopSocket = network_create_socket(network_socket_tcp);
if (global.coopSocket < 0) { Trace("Co-op: could not create a socket."); exit; }

var _r = network_connect(global.coopSocket, _ip, global.coopPort);
if (_r < 0) {
    Trace("Co-op: connect to " + _ip + ":" + string(global.coopPort) + " FAILED.");
    global.coopSocket = -1;
    exit;
}
global.coopConnected = true;
Trace("Co-op: connecting to " + _ip + ":" + string(global.coopPort) + " ...");

#define CoopDisconnect(_why)
if (!global.coopConnected && !global.coopIsHost) { Trace("Co-op: not connected."); exit; }

if (global.coopConnected) {
    var _b = buffer_create(64, buffer_grow, 1);
    buffer_write(_b, buffer_u8, CoopCmd.BYE);
    buffer_write(_b, buffer_string, _why);
    CoopSend(_b);
}
if (global.coopServer >= 0) network_destroy(global.coopServer);
global.coopServer = -1;
global.coopIsHost = false;
global.coopTick   = 0;
CoopResetPeer();
Trace("Co-op: disconnected (" + _why + ").");

#define CoopSendHello()
var _b = buffer_create(64, buffer_grow, 1);
buffer_write(_b, buffer_u8, CoopCmd.HELLO);
buffer_write(_b, buffer_u8, global.coopProtocol);
buffer_write(_b, buffer_string, global.coopVersion);
CoopSend(_b);
Trace("Co-op: sent HELLO (protocol " + string(global.coopProtocol) + ").");

#define CoopSendWelcome()
var _b = buffer_create(64, buffer_grow, 1);
buffer_write(_b, buffer_u8, CoopCmd.WELCOME);
buffer_write(_b, buffer_u8, global.coopProtocol);
buffer_write(_b, buffer_string, global.coopVersion);
CoopSend(_b);

#define CoopSendReject(_reason)
var _b = buffer_create(128, buffer_grow, 1);
buffer_write(_b, buffer_u8, CoopCmd.REJECT);
buffer_write(_b, buffer_string, _reason);
CoopSend(_b);

#define CoopSendPing()
global.coopPingNonce  += 1;
global.coopPingSentAt  = current_time;
var _b = buffer_create(8, buffer_grow, 1);
buffer_write(_b, buffer_u8, CoopCmd.PING);
buffer_write(_b, buffer_u32, global.coopPingNonce);
CoopSend(_b);

#define CoopSendPong(_nonce)
var _b = buffer_create(8, buffer_grow, 1);
buffer_write(_b, buffer_u8, CoopCmd.PONG);
buffer_write(_b, buffer_u32, _nonce);
CoopSend(_b);

#define CoopSendPos()
if (!global.coopPeerAlive) exit;
if (!instance_exists(objPlayer)) exit;

var _b = buffer_create(32, buffer_grow, 1);
buffer_write(_b, buffer_u8, CoopCmd.POS);
buffer_write(_b, buffer_s32, floor(objPlayer.x));
buffer_write(_b, buffer_s32, floor(objPlayer.y));
buffer_write(_b, buffer_u16, floor(objPlayer.angle));
buffer_write(_b, buffer_s8, floor(objPlayer.facing));
buffer_write(_b, buffer_s32, objPlayer.sprite_index);
buffer_write(_b, buffer_u8, floor(objPlayer.image_index) mod 256);
buffer_write(_b, buffer_u8, objPlayer.room);
CoopSend(_b);

#define CoopStatus()
Trace("--- Co-op status ---");
Trace("version " + global.coopVersion + ", protocol " + string(global.coopProtocol)
      + ", port " + string(global.coopPort));
Trace("hosting=" + string(global.coopIsHost) + ", socketUp=" + string(global.coopConnected)
      + ", peerAlive=" + string(global.coopPeerAlive));
if (global.coopPeerAlive) {
    Trace("peer " + global.coopPeerVersion + ", ping " + string(global.coopPingMs) + " ms");
    if (global.coopPeer.seen) {
        Trace("peer at " + string(global.coopPeer.x) + "," + string(global.coopPeer.y)
              + " room " + string(global.coopPeer.room));
    }
}
Trace("--------------------");

#define CoopHandleData(_buf)
var _cmd = buffer_read(_buf, buffer_u8);

switch (_cmd) {
    case CoopCmd.HELLO:
        var _p = buffer_read(_buf, buffer_u8);
        var _v = buffer_read(_buf, buffer_string);
        Trace("Co-op: HELLO from peer (protocol " + string(_p) + ", version " + _v + ").");
        if (_p != global.coopProtocol) {
            CoopSendReject("protocol mismatch: host " + string(global.coopProtocol)
                           + ", peer " + string(_p));
            Trace("Co-op: protocol mismatch - rejected the peer.");
            exit;
        }
        global.coopPeerVersion = _v;
        global.coopPeerAlive   = true;
        CoopSendWelcome();
        Trace("Co-op: handshake complete, peer is " + _v + ".");
        break;

    case CoopCmd.WELCOME:
        var _wp = buffer_read(_buf, buffer_u8);
        var _wv = buffer_read(_buf, buffer_string);
        global.coopPeerVersion = _wv;
        global.coopPeerAlive   = true;
        Trace("Co-op: WELCOME (protocol " + string(_wp) + ", version " + _wv
              + ") - handshake complete.");
        break;

    case CoopCmd.REJECT:
        var _why = buffer_read(_buf, buffer_string);
        Trace("Co-op: host rejected us - " + _why);
        CoopDisconnect("rejected");
        break;

    case CoopCmd.PING:
        CoopSendPong(buffer_read(_buf, buffer_u32));
        break;

    case CoopCmd.PONG:
        buffer_read(_buf, buffer_u32); // one ping in flight; the nonce is informational
        global.coopPingMs     = current_time - global.coopPingSentAt;
        global.coopPingSentAt = -1;
        break;

    case CoopCmd.POS:
        global.coopPeer.x      = buffer_read(_buf, buffer_s32);
        global.coopPeer.y      = buffer_read(_buf, buffer_s32);
        global.coopPeer.angle  = buffer_read(_buf, buffer_u16);
        global.coopPeer.facing = buffer_read(_buf, buffer_s8);
        global.coopPeer.sprite = buffer_read(_buf, buffer_s32);
        global.coopPeer.image  = buffer_read(_buf, buffer_u8);
        global.coopPeer.room   = buffer_read(_buf, buffer_u8);
        global.coopPeer.seen   = true;
        break;

    case CoopCmd.BYE:
        var _bye = buffer_read(_buf, buffer_string);
        Trace("Co-op: peer left - " + _bye);
        if (global.coopIsHost) {
            CoopResetPeer();
            Trace("Co-op: still hosting, waiting for a new peer.");
        } else {
            CoopDisconnect("peer left");
        }
        break;

    default:
        Trace("Co-op: unknown packet id " + string(_cmd));
}
