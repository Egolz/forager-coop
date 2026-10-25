#define OnNetworkAsync(async_load)
// Forager Co-op - GameMaker async networking callbacks (M1).

var _type = async_load[? "type"];

if (_type == network_type_connect) {
    if (global.coopIsHost) {
        global.coopSocket    = async_load[? "socket"];
        // **The runtime owns this socket, not us.** It was handed over by the async connect,
        // so it is the runtime - not `CoopResetPeer` - that releases it on disconnect.
        // Destroying it ourselves is the second destroy that produced every native crash of
        // 2026-10-20 (`0xc0000005` at `0x012c265f`, only ever with a peer connected). The
        // flag is what tells the one teardown path which kind of socket it is holding.
        global.coopSocketOwned = false;
        global.coopConnected = true;
        Trace("Co-op: peer socket connected ("
              + string(async_load[? "ip"]) + ":" + string(async_load[? "port"])
              + "), waiting for HELLO.");
    } else {
        // The client's half of the connect. **The status is checked**, because a connect
        // that failed produces this event too - and sending a HELLO into a dead socket
        // looks like a protocol problem when it is a network one.
        //
        // `global.coopConnected` is set **here** and not when `network_connect` was called:
        // it used to be set optimistically, which meant the mod believed it had a session
        // before there was one, and could send a BYE down a connection that had never
        // finished being set up.
        var _cstatus = async_load[? "status"];
        if (_cstatus != 0) {
            Trace("Co-op: the connect to the host failed (status " + string(_cstatus) + ").");
            if (global.coopSocket >= 0 && global.coopSocketOwned) {
                network_destroy(global.coopSocket);
            }
            global.coopSocket      = -1;
            global.coopSocketOwned = false;
            global.coopConnected   = false;
            return;
        }
        global.coopConnected = true;
        Trace("Co-op: connected to host, sending HELLO.");
        CoopSendHello();
    }
}

if (_type == network_type_disconnect) {
    Trace("Co-op: socket disconnected.");
    if (global.coopIsHost) {
        // Host does not own the peer socket (runtime owns it). Do NOT call CoopResetPeer()
        // as it can destroy/reset things incorrectly and cause native crash on disconnect.
        global.coopConnected   = false;
        global.coopPeerAlive   = false;
        global.coopPeer.seen   = false;
        global.coopPeerVersion = "";
        global.coopPeerName    = "";
        global.coopSocket      = -1;
        global.coopSocketOwned = false;
        global.coopPending        = [];
        global.coopApplyingRemote = false;
        global.coopPingSentAt  = -1;
        global.coopPingMs      = -1;
        Trace("Co-op: still hosting, waiting for a new peer.");
    } else {
        CoopDisconnect("peer dropped");
    }
}

if (_type == network_type_data) {
    // **Do NOT delete the buffer.** It is tempting - an incoming buffer that nothing frees
    // looks like a leak - and it is wrong: the manual is explicit that the buffer is
    // "automatically removed from memory at the end of this event" and "only valid in these
    // events ... will be automatically freed when the event is over". A `buffer_delete` here
    // is a **double free**, and it was added on 2026-10-20 believing the leak was the cause of
    // a native crash (`0xc0000005`). It made that crash arrive *sooner* (the receive side
    // stopped answering ~8 s before the fault without it, ~6 s with it), which is exactly what
    // a double free does to a heap. It has been removed, and this comment stays so the next
    // reader does not "fix" the same non-leak again.
    CoopHandleData(async_load[? "buffer"]);
}
