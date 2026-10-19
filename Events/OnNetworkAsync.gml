#define OnNetworkAsync(async_load)
// Forager Co-op - GameMaker async networking callbacks (M1).

var _type = async_load[? "type"];

if (_type == network_type_connect) {
    if (global.coopIsHost) {
        global.coopSocket    = async_load[? "socket"];
        global.coopConnected = true;
        Trace("Co-op: peer socket connected ("
              + string(async_load[? "ip"]) + ":" + string(async_load[? "port"])
              + "), waiting for HELLO.");
    } else {
        Trace("Co-op: connected to host, sending HELLO.");
        CoopSendHello();
    }
}

if (_type == network_type_disconnect) {
    Trace("Co-op: socket disconnected.");
    if (global.coopIsHost) {
        CoopResetPeer();
        Trace("Co-op: still hosting, waiting for a new peer.");
    } else {
        CoopDisconnect("peer dropped");
    }
}

if (_type == network_type_data) {
    CoopHandleData(async_load[? "buffer"]);
}
