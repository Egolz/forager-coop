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
    // **Do NOT delete the buffer.** It is tempting - an incoming buffer that nothing frees
    // looks like a leak - and it is wrong: the manual is explicit that the buffer is
    // "automatically removed from memory at the end of this event" and "only valid in these
    // events ... will be automatically freed when the event is over". A `buffer_delete` here
    // is a **double free**, and it was added on 2026-10-20 believing the leak was the cause of
    // a native crash (`0xc0000005`). It made that crash arrive *sooner* (the receive side
    // stopped answering ~8 s before the fault without it, ~6 s with it), which is exactly what
    // a double free does to a heap. It has been removed, and this comment stays so the next
    // reader does not "fix" the same non-leak again.
    global.coopRxCount += 1;   // diagnostic: how many packets this side has handled (see OnStep)
    CoopHandleData(async_load[? "buffer"]);
}
