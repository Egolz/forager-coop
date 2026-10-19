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
global.coopPending        = [];
global.coopApplyingRemote = false;

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

// ---------------------------------------------------------------------------
// M2: structures
//
// A structure is identified on the wire by its **name** (e.g. "forge"), not by
// an object index: names are stable between builds and readable in a log.
//
// Note on the macros below: GML here is happy with the same `var` name in two
// *different* blocks (PencilPal relies on that everywhere) but not twice inside
// one block, so each macro uses its own prefix and none of them is expanded
// twice within a single block.
// ---------------------------------------------------------------------------

// A client may only place within this many pixels of its own puppet - a cheap
// sanity/anti-grief check, not a real anti-cheat.
// Kept as a global rather than a #define: this loader does not accept value
// macros (#define NAME 448) - it reads a macro body as statements and stops with
// "Expected a statement, got number" (seen in the live build, Net.gml L137).
// (global.coopPlaceRange is set in Main.gml.)

#define CoopBuildStructDb()
// Reads the game's structure database into global.coopStructNames/Objects
// (id -> lowercase name / object index). Built lazily (the database is not
// guaranteed to be up when the mod first loads) and only while a peer is
// around, so a build that cannot read it costs one console line, not a crash.
//
// There is deliberately **no try/catch**: this loader's compiler cannot compile
// a try_catch node at all - the game dies with "Can't seekAllOut over
// <file>[L150,c1] try_catch" (error.log, live build, 2026-10-20) and the mod
// never loads. Same reason PencilPal's TODO says "Fix recompile crashing game".
global.coopStructNames   = [];
global.coopStructObjects = [];
var _bd_n = Structure.Count;
for (var _bd_i = 0; _bd_i < _bd_n; _bd_i++) {
    global.coopStructNames[_bd_i]   = string_lower(StructureGet(_bd_i, StructureData.Name));
    global.coopStructObjects[_bd_i] = StructureGet(_bd_i, StructureData.Object);
}
Trace("Co-op: structure database cached (" + string(_bd_n) + " entries).");

#define CoopFindStructure(_name)
// -> id of the structure called _name, or -1
if (array_length(global.coopStructNames) == 0) CoopBuildStructDb();
var _fl_want = string_lower(_name);
var _fl_n    = array_length(global.coopStructNames);
for (var _fl_i = 0; _fl_i < _fl_n; _fl_i++) {
    if (global.coopStructNames[_fl_i] == _fl_want) return _fl_i;
}
return -1;

#define CoopStructObject(_id)
// -> the object index a structure id is built from, or -1
if (_id >= 0 && _id < array_length(global.coopStructObjects)) return global.coopStructObjects[_id];
return -1;

#define CoopStructureNameOf(_struc, _obj)
// The name of the structure an instance belongs to. OnStructureSpawn() hands us
// a structure id; if that id is not one we cached, fall back to the object.
if (_struc >= 0 && _struc < array_length(global.coopStructNames)) return global.coopStructNames[_struc];
var _sno_n = array_length(global.coopStructObjects);
for (var _sno_i = 0; _sno_i < _sno_n; _sno_i++) {
    if (global.coopStructObjects[_sno_i] == _obj) return global.coopStructNames[_sno_i];
}
return "";

#define CoopStructureAt(_obj, _x, _y)
// -> an existing instance of _obj at (_x,_y), or -1. Uses the True Instance
//    system, so instances culled offscreen are found too.
var _at_res  = -1;
var _at_n    = TrueInstanceNumber(_obj);
for (var _at_i = 0; _at_i < _at_n; _at_i++) {
    var _at_inst = TrueInstanceFind(_obj, _at_i);
    if (floor(_at_inst.x) == floor(_x) && floor(_at_inst.y) == floor(_y)) {
        _at_res = _at_inst;
        break;
    }
}
return _at_res;

#define CoopCreateStructure(_sid, _x, _y, _depth)
// -> the instance, or -1 on failure. Takes a structure **id** (run
//    CoopFindStructure first). Never fires an intent/mutation back out:
//    OnStructureSpawn() bails while coopApplyingRemote is set.
var _cs_obj = CoopStructObject(_sid);
if (_cs_obj < 0) return -1;

var _cs_where = CoopStructureAt(_cs_obj, _x, _y);
if (_cs_where >= 0) {
    // already there - usually our own optimistic placement, so adopt it
    _cs_where.structure = _sid;
    return _cs_where;
}

global.coopApplyingRemote = true;
var _cs_new = instance_create_depth(floor(_x), floor(_y), floor(_depth), _cs_obj);
_cs_new.structure = _sid;
global.coopApplyingRemote = false;
return _cs_new;

#define CoopPendingRemoveAt(_pi)
// Drop the pending prediction at index _pi. This build has no array_delete()
// (checked against its symbol table), so rebuild the list instead - it holds at
// most a handful of unconfirmed predictions.
var _pr_new = [];
var _pr_n   = array_length(global.coopPending);
for (var _pr_i = 0; _pr_i < _pr_n; _pr_i++) {
    if (_pr_i != _pi) array_push(_pr_new, array_get(global.coopPending, _pr_i));
}
global.coopPending = _pr_new;

#define CoopForgetPending(_iid)
var _fp_n = array_length(global.coopPending);
for (var _fp_i = 0; _fp_i < _fp_n; _fp_i++) {
    if (array_get(array_get(global.coopPending, _fp_i), 0) == _iid) {
        CoopPendingRemoveAt(_fp_i);
        break;
    }
}

#define CoopUndoPrediction(_iid)
// The host refused an intent we had already placed optimistically. The resource
// cost is NOT refunded (inventories are M2.4) - see the README's known issues.
// A pending entry is [_iid, x, y, sid, obj].
var _up_n = array_length(global.coopPending);
for (var _up_i = 0; _up_i < _up_n; _up_i++) {
    var _up_p = array_get(global.coopPending, _up_i);
    if (array_get(_up_p, 0) != _iid) continue;
    var _up_obj = array_get(_up_p, 4);
    if (_up_obj >= 0) {
        var _up_tn = TrueInstanceNumber(_up_obj);
        for (var _up_ti = 0; _up_ti < _up_tn; _up_ti++) {
            var _up_inst = TrueInstanceFind(_up_obj, _up_ti);
            if (floor(_up_inst.x) == array_get(_up_p, 1)
                && floor(_up_inst.y) == array_get(_up_p, 2)) {
                global.coopApplyingRemote = true;
                instance_destroy(_up_inst, false);
                global.coopApplyingRemote = false;
                Trace("Co-op: rolled back our structure at "
                      + string(array_get(_up_p, 1)) + "," + string(array_get(_up_p, 2)) + ".");
                break;
            }
        }
    }
    CoopPendingRemoveAt(_up_i);
    break;
}

#define CoopSendIntentPlace(_name, _x, _y)
global.coopIntentCounter += 1;
var _ip_iid = global.coopIntentCounter;
var _ip_sid = CoopFindStructure(_name);
array_push(global.coopPending, [_ip_iid, floor(_x), floor(_y), _ip_sid, CoopStructObject(_ip_sid)]);
var _ip_b = buffer_create(96, buffer_grow, 1);
buffer_write(_ip_b, buffer_u8, CoopCmd.INTENT_PLACE);
buffer_write(_ip_b, buffer_u32, _ip_iid);
buffer_write(_ip_b, buffer_u8, objPlayer.room);
buffer_write(_ip_b, buffer_s32, floor(_x));
buffer_write(_ip_b, buffer_s32, floor(_y));
buffer_write(_ip_b, buffer_string, _name);
CoopSend(_ip_b);
Trace("Co-op: -> intent place '" + _name + "' at " + string(floor(_x)) + ","
      + string(floor(_y)) + " (#" + string(_ip_iid) + ")");

#define CoopSendMutationPlace(_intentId, _x, _y, _depth, _name)
global.coopSeq += 1;
var _mp_b = buffer_create(128, buffer_grow, 1);
buffer_write(_mp_b, buffer_u8, CoopCmd.MUTATION_PLACE);
buffer_write(_mp_b, buffer_u32, global.coopSeq);
buffer_write(_mp_b, buffer_u32, _intentId);
buffer_write(_mp_b, buffer_u8, objPlayer.room);
buffer_write(_mp_b, buffer_s32, floor(_x));
buffer_write(_mp_b, buffer_s32, floor(_y));
buffer_write(_mp_b, buffer_s32, floor(_depth));
buffer_write(_mp_b, buffer_string, _name);
CoopSend(_mp_b);

#define CoopSendIntentRejected(_intentId, _why)
var _ir_b = buffer_create(160, buffer_grow, 1);
buffer_write(_ir_b, buffer_u8, CoopCmd.INTENT_REJECTED);
buffer_write(_ir_b, buffer_u32, _intentId);
buffer_write(_ir_b, buffer_string, _why);
CoopSend(_ir_b);

#define CoopSendStructureTable()
if (array_length(global.coopStructNames) == 0) CoopBuildStructDb();
var _st_n = array_length(global.coopStructNames);
if (_st_n > 64) _st_n = 64;
var _st_b = buffer_create(256, buffer_grow, 1);
buffer_write(_st_b, buffer_u8, CoopCmd.STRUCTURE_TABLE);
buffer_write(_st_b, buffer_u16, _st_n);
for (var _st_i = 0; _st_i < _st_n; _st_i++) {
    buffer_write(_st_b, buffer_u16, _st_i);
    buffer_write(_st_b, buffer_string, global.coopStructNames[_st_i]);
}
CoopSend(_st_b);

#define CoopDumpStructures()
// F9. Is the object our table calls a structure really one? `isStruct` asks the
// game itself (object_is_ancestor against its own parStructure), which is the
// only answer that counts - a table of plausible-looking object names proves
// nothing.
if (array_length(global.coopStructNames) == 0) CoopBuildStructDb();
Trace("--- Co-op: structure database (" + string(array_length(global.coopStructNames)) + " entries) ---");
var _ds_par = asset_get_index("parStructure");
var _ds_n   = array_length(global.coopStructNames);
for (var _ds_i = 0; _ds_i < _ds_n; _ds_i++) {
    var _ds_obj = global.coopStructObjects[_ds_i];
    var _ds_txt = "?";
    var _ds_anc = "-";
    if (_ds_obj >= 0) {
        _ds_txt = object_get_name(_ds_obj);
        _ds_anc = "0";
        if (_ds_par >= 0 && object_is_ancestor(_ds_obj, _ds_par)) _ds_anc = "1";
    }
    Trace("#" + string(_ds_i) + "  " + global.coopStructNames[_ds_i]
          + "  (" + _ds_txt + " isStruct=" + _ds_anc + ")");
}
Trace("---");

#define CoopProbeWorld()
// F10. Read-only. Dumps what the game thinks a structure is next to what our
// table thinks, then writes it to coop_probe.ini in the game's own data folder
// (next to error.log) - a console screenshot cannot be trusted for a table this
// size, and the OCR of the first one already garbled every digit.
//
// The console gets the short half: the world, and the room's player. The file
// gets that plus the whole 64-entry id -> object table.
//
// The parStructure half is the ground truth - the game's own parent object for
// every building, whatever our table believes. The other half walks our own
// id -> object map and prints any instance it finds, with the fields that decide
// whether a player would actually see it (depth, image_index, visible).
if (array_length(global.coopStructNames) == 0) CoopBuildStructDb();

var _pw_lines = [];
var _pw_par   = asset_get_index("parStructure");
array_push(_pw_lines, "version " + global.coopVersion + " protocol " + string(global.coopProtocol));
if (instance_exists(objPlayer)) {
    array_push(_pw_lines, "room " + string(objPlayer.room) + " player "
               + string(floor(objPlayer.x)) + "," + string(floor(objPlayer.y))
               + " depth " + string(objPlayer.depth)
               + " obj " + object_get_name(objPlayer.object_index));
} else {
    array_push(_pw_lines, "no player instance - the host is not in a world");
}
if (_pw_par < 0) {
    array_push(_pw_lines, "parStructure: not found in this build");
} else {
    array_push(_pw_lines, "parStructure #" + string(_pw_par) + " name " + object_get_name(_pw_par)
               + ": instance_number " + string(instance_number(_pw_par))
               + ", TrueInstanceNumber " + string(TrueInstanceNumber(_pw_par)));
}

var _pw_alt = asset_get_index("objNewBuilding");
if (_pw_alt >= 0) {
    array_push(_pw_lines, "objNewBuilding #" + string(_pw_alt)
               + " instances " + string(instance_number(_pw_alt)));
}
var _pw_alt2 = asset_get_index("objModStructure");
if (_pw_alt2 >= 0) {
    array_push(_pw_lines, "objModStructure #" + string(_pw_alt2)
               + " instances " + string(instance_number(_pw_alt2)));
}

if (_pw_par >= 0) {
    var _pw_pn = instance_number(_pw_par);
    var _pw_pl = _pw_pn;
    if (_pw_pl > 24) _pw_pl = 24;
    array_push(_pw_lines, "parStructure instances (first " + string(_pw_pl) + "):");
    for (var _pw_pi = 0; _pw_pi < _pw_pl; _pw_pi++) {
        var _pw_p = instance_find(_pw_par, _pw_pi);
        array_push(_pw_lines, " par " + object_get_name(_pw_p.object_index)
                   + " " + string(floor(_pw_p.x)) + "," + string(floor(_pw_p.y))
                   + " depth " + string(_pw_p.depth)
                   + " image " + string(_pw_p.image_index)
                   + " visible " + string(_pw_p.visible));
    }
}

var _pw_hits = 0;
var _pw_kind = array_length(global.coopStructObjects);
for (var _pw_i = 0; _pw_i < _pw_kind; _pw_i++) {
    var _pw_obj = global.coopStructObjects[_pw_i];
    if (_pw_obj < 0) continue;
    var _pw_c = TrueInstanceNumber(_pw_obj);
    if (_pw_c <= 0) continue;
    _pw_hits += 1;
    var _pw_anc = "0";
    if (_pw_par >= 0 && object_is_ancestor(_pw_obj, _pw_par)) _pw_anc = "1";
    array_push(_pw_lines, "table #" + string(_pw_i) + " '" + global.coopStructNames[_pw_i]
               + "' obj " + object_get_name(_pw_obj) + " isStruct=" + _pw_anc
               + " count=" + string(_pw_c));
    for (var _pw_j = 0; _pw_j < _pw_c; _pw_j++) {
        var _pw_inst = TrueInstanceFind(_pw_obj, _pw_j);
        array_push(_pw_lines, "    " + object_get_name(_pw_inst.object_index)
                   + " " + string(floor(_pw_inst.x)) + "," + string(floor(_pw_inst.y))
                   + " depth " + string(_pw_inst.depth)
                   + " image " + string(_pw_inst.image_index)
                   + " visible " + string(_pw_inst.visible));
    }
}
array_push(_pw_lines, "our table matched " + string(_pw_hits) + " kinds in this room");

// The whole id -> object table, file only: 64 console lines would bury the part
// that matters, and the file is the copy we can actually read.
var _pw_tbl = [];
for (var _pw_ti = 0; _pw_ti < _pw_kind; _pw_ti++) {
    var _pw_tobj = global.coopStructObjects[_pw_ti];
    var _pw_txt  = "?";
    var _pw_tanc = "-";
    var _pw_ptxt = "-";
    if (_pw_tobj >= 0) {
        _pw_txt = object_get_name(_pw_tobj);
        _pw_tanc = "0";
        if (_pw_par >= 0 && object_is_ancestor(_pw_tobj, _pw_par)) _pw_tanc = "1";
        var _pw_par2 = object_get_parent(_pw_tobj);
        _pw_ptxt = "none";
        if (_pw_par2 >= 0) _pw_ptxt = object_get_name(_pw_par2);
    }
    array_push(_pw_tbl, "tbl #" + string(_pw_ti) + " '" + global.coopStructNames[_pw_ti]
               + "' obj " + _pw_txt + " parent " + _pw_ptxt + " isStruct=" + _pw_tanc);
}

Trace("--- Co-op probe ---");
var _pw_n = array_length(_pw_lines);
for (var _pw_k = 0; _pw_k < _pw_n; _pw_k++) Trace("  " + array_get(_pw_lines, _pw_k));
Trace("---");

// The file, so a long dump survives a screenshot. Printed to the console first:
// if opening the file fails, the console still has everything.
ini_open("coop_probe.ini");
for (var _pw_w = 0; _pw_w < _pw_n; _pw_w++) {
    ini_write_string("probe", "line" + string(_pw_w), array_get(_pw_lines, _pw_w));
}
ini_write_real("probe", "count", _pw_n);
var _pw_tn = array_length(_pw_tbl);
for (var _pw_tw = 0; _pw_tw < _pw_tn; _pw_tw++) {
    ini_write_string("table", "tbl" + string(_pw_tw), array_get(_pw_tbl, _pw_tw));
}
ini_write_real("table", "count", _pw_tn);
ini_close();
Trace("Co-op: probe written to coop_probe.ini ("
      + string(_pw_n) + " world + " + string(_pw_tn) + " table lines).");

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
Trace("world: " + (global.coopIsHost ? "authority" : "follower")
      + ", seq " + string(global.coopSeq)
      + ", structures known " + string(array_length(global.coopStructNames))
      + ", intents awaiting confirmation " + string(array_length(global.coopPending)));
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
        CoopSendStructureTable();
        global.coopSeq = 0;   // a fresh peer starts from a clean sequence
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

    case CoopCmd.INTENT_PLACE:
        // A client is asking us (the host) to place a structure. We validate it
        // against our own world, apply it ourselves and broadcast the result.
        var _iid   = buffer_read(_buf, buffer_u32);
        var _iroom = buffer_read(_buf, buffer_u8);
        var _ix    = buffer_read(_buf, buffer_s32);
        var _iy    = buffer_read(_buf, buffer_s32);
        var _iname = buffer_read(_buf, buffer_string);

        if (!global.coopIsHost) {
            Trace("Co-op: an intent arrived but we are not the host - ignored.");
            break;
        }
        Trace("Co-op: <- intent place '" + _iname + "' at " + string(_ix) + "," + string(_iy)
              + " room " + string(_iroom) + " (#" + string(_iid) + ")");

        var _sid = CoopFindStructure(_iname);
        if (_sid < 0) {
            CoopSendIntentRejected(_iid, "unknown structure '" + _iname + "'");
            break;
        }
        if (!instance_exists(objPlayer)) {
            CoopSendIntentRejected(_iid, "the host is not in a world right now");
            break;
        }
        if (_iroom != objPlayer.room) {
            CoopSendIntentRejected(_iid, "the host is in room " + string(objPlayer.room)
                                   + ", you are in " + string(_iroom));
            break;
        }
        if (global.coopPeer.seen) {
            var _dist = point_distance(_ix, _iy, global.coopPeer.x, global.coopPeer.y);
            if (_dist > global.coopPlaceRange) {
                CoopSendIntentRejected(_iid, "too far from your player (" + string(round(_dist)) + " px)");
                break;
            }
        }

        var _placed = CoopCreateStructure(_sid, _ix, _iy, 0);
        if (_placed < 0) {
            CoopSendIntentRejected(_iid, "the host could not create it");
            break;
        }
        CoopSendMutationPlace(_iid, _placed.x, _placed.y, _placed.depth, _iname);
        Trace("Co-op: applied intent #" + string(_iid) + " as seq " + string(global.coopSeq) + ".");
        break;

    case CoopCmd.MUTATION_PLACE:
        // The host's world changed. Apply it in sequence order, once.
        var _seq   = buffer_read(_buf, buffer_u32);
        var _miid  = buffer_read(_buf, buffer_u32);
        var _mroom = buffer_read(_buf, buffer_u8);
        var _mx    = buffer_read(_buf, buffer_s32);
        var _my    = buffer_read(_buf, buffer_s32);
        var _mdep  = buffer_read(_buf, buffer_s32);
        var _mname = buffer_read(_buf, buffer_string);

        if (_seq <= global.coopSeq) {
            Trace("Co-op: ignoring stale mutation seq " + string(_seq)
                  + " (we are already at " + string(global.coopSeq) + ").");
            break;
        }
        global.coopSeq = _seq;
        CoopForgetPending(_miid);
        if (instance_exists(objPlayer) && _mroom != objPlayer.room) {
            Trace("Co-op: mutation seq " + string(_seq) + " belongs to room " + string(_mroom)
                  + ", we are in " + string(objPlayer.room) + " - not created here.");
            break;
        }
        var _msid = CoopFindStructure(_mname);
        if (_msid < 0) {
            Trace("Co-op: mutation names an unknown structure '" + _mname + "' - ignored.");
            break;
        }
        CoopCreateStructure(_msid, _mx, _my, _mdep);
        Trace("Co-op: <- mutation seq " + string(_seq) + " '" + _mname + "' at "
              + string(_mx) + "," + string(_my) + ".");
        break;

    case CoopCmd.INTENT_REJECTED:
        var _rid  = buffer_read(_buf, buffer_u32);
        var _rwhy = buffer_read(_buf, buffer_string);
        Trace("Co-op: intent #" + string(_rid) + " was refused: " + _rwhy);
        CoopUndoPrediction(_rid);
        break;

    case CoopCmd.STRUCTURE_TABLE:
        // The host's view of the structure database. We already have our own, so
        // this is a divergence check between the two installs.
        if (array_length(global.coopStructNames) == 0) CoopBuildStructDb();
        var _tn    = buffer_read(_buf, buffer_u16);
        var _match = 0;
        for (var _t = 0; _t < _tn; _t++) {
            var _tid   = buffer_read(_buf, buffer_u16);
            var _tname = buffer_read(_buf, buffer_string);
            if (_tid < array_length(global.coopStructNames)
                && global.coopStructNames[_tid] == _tname) _match += 1;
        }
        Trace("Co-op: host structure table: " + string(_match) + "/" + string(_tn)
              + " names match ours.");
        if (_match < _tn) {
            Trace("Co-op: WARNING - our structure databases differ; the two installs are not the same build.");
        }
        break;

    default:
        Trace("Co-op: unknown packet id " + string(_cmd));
}
