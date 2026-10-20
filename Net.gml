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

#define CoopSendDebugLine(_text)
// Sends one line of our console to the peer, which writes it down.
//
// Why over the wire: a mod here cannot write a file. `ini_open` is not in this
// loader's function table ("`ini_open` is not function or script", live COMPILE
// error 2026-10-20), and `file_text_*`, `buffer_save` and `show_debug_message`
// are absent from the build entirely. A long dump therefore leaves the game
// through the socket - the peer is ours, and it has a disk.
//
// console-only fallback: if nobody is connected, the caller still Traces it.
if (global.coopSocket >= 0) {
    var _dbl_b = buffer_create(256, buffer_grow, 1);
    buffer_write(_dbl_b, buffer_u8, CoopCmd.DEBUG_LINE);
    buffer_write(_dbl_b, buffer_string, _text);
    CoopSend(_dbl_b);
}

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
// Wire-key decision (F10 probe, 2026-10-20).
//
// A structure is identified on the wire by its **name** (e.g. "forge"). The live
// database shows why that is fragile: the names are localized display strings
// ("печь", "швейная\nмастерская"), so the same structure is a different string in
// another language, and rows #68..#80 hold an empty string. The fix is to key on
// the Structure enum index and keep the name for logs; that is a wire change and
// is scheduled next, not done here.
//
// What the probe did settle is that a name-keyed request *works*: asking for
// "печь" created a real objFurnace at the right place and the right depth
// (800,672 depth -672), and the game's own OnStructureSpawn() re-announced it.
// ---------------------------------------------------------------------------
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

// ---------------------------------------------------------------------------
// M2.2 - the item database.
//
// Both directions of resource sync travel as an item **id**: a drop says "item 3,
// quantity 1 landed at (x,y)", a pickup says "item 3 left the world". For that to
// mean the same thing on both machines, the ids have to line up. The structure
// table taught us how to check that (CoopSendStructureTable + the mismatch
// warning); the same idea is reused here.
//
// Every call below is one the docs list for the item database AND that this build
// exports (checked against its symbol table: ItemGet, ItemCount, GainItem,
// RemoveItem, DropItem each appear once). They are used inside a lazy builder or a
// probe, never at Main's registration pass - a build whose item database is not up
// yet must cost one console line, not a crash.
// ---------------------------------------------------------------------------

#define CoopBuildItemDb()
// Reads the game's item database into global.coopItemNames (id -> lowercase name).
// Lazy, like CoopBuildStructDb: Item.Count is not guaranteed to be final while
// Main runs, and a session that never touches resources should not pay for it.
global.coopItemNames = [];
global.coopItemCount = Item.Count;
for (var _bi_i = 0; _bi_i < global.coopItemCount; _bi_i++) {
    var _bi_nm = ItemGet(_bi_i, ItemData.Name);
    global.coopItemNames[_bi_i] = string_lower(string(_bi_nm));
}
Trace("Co-op: item database cached (" + string(global.coopItemCount) + " entries).");

#define CoopItemName(_id)
// -> the lowercase name of an item id, or "" when the id is outside the database.
if (array_length(global.coopItemNames) == 0) CoopBuildItemDb();
if (_id < 0 || _id >= array_length(global.coopItemNames)) return "";
return global.coopItemNames[_id];

#define CoopFindItem(_name)
// -> id of the item called _name, or -1. The mirror of CoopFindStructure, and for
//    the same reason: a name is what a human reads in a log, an id is what travels.
//
// Live lesson (F3 probe, 2026-10-20): the names are **localized**, exactly like the
// structure names. `CoopFindItem("Wood")` returned -1 on the owner's install while
// `ItemGet(Item.Wood, ItemData.Name)` returned "Древесина". So this lookup is a
// convenience for a hand-typed console query, never the wire's key: the wire carries
// the item **id**, and `Item.Wood == 0`, `Item.Stone == 1`, `Item.Coin == 111` are
// constants the build itself defines.
if (array_length(global.coopItemNames) == 0) CoopBuildItemDb();
var _fi_want = string_lower(_name);
var _fi_n    = array_length(global.coopItemNames);
for (var _fi_i = 0; _fi_i < _fi_n; _fi_i++) {
    if (global.coopItemNames[_fi_i] == _fi_want) return _fi_i;
}
return -1;

#define CoopSendItemTable()
// Our item database, as id/name pairs, so a divergence between two installs is
// visible before it turns into a wrong item on someone's island.
//
// The **names travel for the log only**. Live F3 (2026-10-20) showed why: they are
// localized, so two installs on different languages disagree on every single name
// while their item **ids** are identical. The check the receiver actually runs is
// therefore count + the anchor ids, which are language-independent - the names are
// there so a divergence report can say *which* item moved.
if (array_length(global.coopItemNames) == 0) CoopBuildItemDb();
var _it_b = buffer_create(512, buffer_grow, 1);
buffer_write(_it_b, buffer_u8, CoopCmd.ITEM_TABLE);
buffer_write(_it_b, buffer_u16, global.coopItemCount);
for (var _it_i = 0; _it_i < global.coopItemCount; _it_i++) {
    buffer_write(_it_b, buffer_u16, _it_i);
    buffer_write(_it_b, buffer_string, global.coopItemNames[_it_i]);
}
CoopSend(_it_b);

// ---------------------------------------------------------------------------
// M2.2 - loot and resource sync.
//
// The shape matches placement: whoever sees a world change announces it, and the
// **host** is the only one allowed to *apply* an announcement to its own world.
//   host sees a drop   -> applies it locally (the game already did) and broadcasts
//   client sees a drop -> announces it to the host, which applies and broadcasts
// The re-entrancy guard coopApplyingLoot stops an applied change from being
// announced again, exactly as coopApplyingRemote does for structures.
//
// Items travel as **ids**, because the F3 probe showed the names are localized and
// ids are build constants (Item.Wood == 0, verified live 2026-10-20).
// ---------------------------------------------------------------------------

#define CoopDropAt(_x, _y, _item, _radius)
// -> an existing dropped-item instance of that item within _radius of (_x,_y), or -1.
//    A drop's own instance is what has to be removed when someone picks it up, and
//    it is found the same way structures are: by walking the true instances, so a
//    culled (offscreen) drop is found too. `parResource` is the parent, and the item
//    is matched through the instance's own `item` field - the same field
//    OnItemDrop() reads - so no name lookup is involved.
var _da_res = -1;
var _da_n   = TrueInstanceNumber(parResource);
for (var _da_i = 0; _da_i < _da_n; _da_i++) {
    var _da_inst = TrueInstanceFind(parResource, _da_i);
    if (point_distance(_da_inst.x, _da_inst.y, _x, _y) > _radius) continue;
    // `variable_instance_exists` is NOT in this build's symbol table (checked
    // offline, count 0), so there is no runtime test for the field. The whole
    // `parResource` family carries `item` - it is what OnItemDrop() hands out - so
    // the field is read directly, the way PencilPal's own drop handler does.
    if (_da_inst.item != _item) continue;
    _da_res = _da_inst;
    break;
}
return _da_res;

#define CoopDropNear(_x, _y, _item, _radius)
// A clearer name for the same walk, used by the pickup path where the exact tile is
// unknown and only a radius around the picker is.
return CoopDropAt(_x, _y, _item, _radius);

#define CoopSendDrop(_x, _y, _item, _stack)
// Announce an item that appeared in the world.
var _dr_b = buffer_create(32, buffer_grow, 1);
buffer_write(_dr_b, buffer_u8, CoopCmd.DROP);
buffer_write(_dr_b, buffer_u8, objPlayer.room);
buffer_write(_dr_b, buffer_s32, floor(_x));
buffer_write(_dr_b, buffer_s32, floor(_y));
buffer_write(_dr_b, buffer_u16, _item);
buffer_write(_dr_b, buffer_u16, _stack);
CoopSend(_dr_b);

#define CoopSendPickup(_x, _y, _item)
// Announce that an item left the world because someone took it.
var _pu_b = buffer_create(32, buffer_grow, 1);
buffer_write(_pu_b, buffer_u8, CoopCmd.PICKUP);
buffer_write(_pu_b, buffer_u8, objPlayer.room);
buffer_write(_pu_b, buffer_s32, floor(_x));
buffer_write(_pu_b, buffer_s32, floor(_y));
buffer_write(_pu_b, buffer_u16, _item);
CoopSend(_pu_b);

#define CoopSendResourceDestroy(_x, _y, _obj)
// Announce that a resource (tree, rock, bush, ...) was harvested and is gone.
// The object index travels, not a name: names are localized, object indices are not.
var _rd_b = buffer_create(32, buffer_grow, 1);
buffer_write(_rd_b, buffer_u8, CoopCmd.RESOURCE_DESTROY);
buffer_write(_rd_b, buffer_u8, objPlayer.room);
buffer_write(_rd_b, buffer_s32, floor(_x));
buffer_write(_rd_b, buffer_s32, floor(_y));
buffer_write(_rd_b, buffer_u16, _obj);
CoopSend(_rd_b);

#define CoopApplyDrop(_x, _y, _item, _stack)
// Create a dropped item the peer told us about. DropItem is the game's own spawner
// (documented, and PencilPal uses it to mirror a drop). Guarded so the spawn does
// not bounce back out as our own announcement.
var _ad_had = CoopDropAt(_x, _y, _item, 20);
if (_ad_had >= 0) return -1;
global.coopApplyingLoot = true;
var _ad_new = DropItem(floor(_x), floor(_y), _item, _stack);
global.coopApplyingLoot = false;
global.coopLootDrops += 1;
return _ad_new;

#define CoopApplyPickup(_x, _y, _item)
// Remove a dropped item the peer told us about. OnItemGet carries no tile - only
// the item and how many - so the drop is located *near the position the picker
// reported*, which is their own player. A radius of ~48 px covers the pickup reach
// without reaching across to an unrelated pile on the same island.
var _ap_inst = CoopDropNear(_x, _y, _item, 48);
if (_ap_inst < 0) return 0;
global.coopApplyingLoot = true;
instance_destroy(_ap_inst, false);
global.coopApplyingLoot = false;
global.coopLootPicks += 1;
return 1;

#define CoopApplyResourceDestroy(_x, _y, _obj)
// Destroy a harvested resource at the given tile. Object index rather than name, so
// a localized build still matches. Walks true instances for the same reason drops do.
var _ar_hits = 0;
var _ar_n    = TrueInstanceNumber(_obj);
for (var _ar_i = 0; _ar_i < _ar_n; _ar_i++) {
    var _ar_inst = TrueInstanceFind(_obj, _ar_i);
    if (floor(_ar_inst.x) != floor(_x) || floor(_ar_inst.y) != floor(_y)) continue;
    global.coopApplyingLoot = true;
    instance_destroy(_ar_inst, false);
    global.coopApplyingLoot = false;
    _ar_hits += 1;
}
if (_ar_hits > 0) global.coopLootBreaks += 1;
return _ar_hits;

#define CoopProbeItems()
// F3. Read-only. Measures the item half of M2.2 before a single byte of loot sync
// is written: how many items does this build have, do the ids we care about
// (Wood, Stone, Coin) resolve to the same numbers the docs and PencilPal assume,
// and does the item database agree between `ItemGet(id, ItemData.Name)` and the
// sprite it points at?
//
// It creates nothing, drops nothing and gains nothing: ItemCount is a read.
if (!instance_exists(objPlayer)) {
    Trace("Co-op: F3 needs a loaded world.");
    exit;
}

var _pi_count = Item.Count;
CoopBuildItemDb();

var _pi_lines = [];
array_push(_pi_lines, "=== item probe begin " + global.coopVersion + " ===");
array_push(_pi_lines, "Item.Count = " + string(_pi_count)
           + ", cached " + string(global.coopItemCount));

// 1) The named anchors. If Wood/Stone/Coin resolve to the same ids in both
//    installs, a drop of "Wood" means the same thing on either machine. Wood and
//    Stone are the two the docs' enum example uses; Coin is the one PencilPal
//    spends and counts.
//
//    Note what "found-by-name" is for: the names in this database are **localized**
//    (live 2026-10-20: Item.Wood reads back as "Древесина" on the owner's install),
//    so a by-name search in English returns -1 and always will. That is not a bug in
//    the lookup, it is the reason the wire carries ids. The line prints it so the
//    asymmetry is on the record rather than discovered later.
var _pi_anchors = [["Wood", Item.Wood], ["Stone", Item.Stone], ["Coin", Item.Coin]];
for (var _pi_ai = 0; _pi_ai < array_length(_pi_anchors); _pi_ai++) {
    var _pi_an = array_get(array_get(_pi_anchors, _pi_ai), 0);
    var _pi_av = array_get(array_get(_pi_anchors, _pi_ai), 1);
    array_push(_pi_lines, "anchor " + _pi_an + " = " + string(_pi_av)
               + "  name '" + CoopItemName(_pi_av) + "'"
               + "  found-by-name " + string(CoopFindItem(_pi_an))
               + "  (a -1 is expected while the install is not English)"
               + "  owned " + string(ItemCount(_pi_av, false)));
}

// 2) The whole table, first and last few, so a shift in one build shows up as a
//    name landing on the wrong id. The full table goes to the peer as a packet.
var _pi_show = 6;
for (var _pi_i = 0; _pi_i < global.coopItemCount; _pi_i++) {
    if (_pi_i >= _pi_show && _pi_i < global.coopItemCount - _pi_show) continue;
    array_push(_pi_lines, "item #" + string(_pi_i) + " '" + global.coopItemNames[_pi_i] + "'");
}

array_push(_pi_lines, "=== item probe end ===");
var _pi_n = array_length(_pi_lines);
Trace("--- Co-op item probe ---");
for (var _pi_j = 0; _pi_j < _pi_n; _pi_j++) {
    Trace("  " + array_get(_pi_lines, _pi_j));
    CoopSendDebugLine(array_get(_pi_lines, _pi_j));
}
Trace("---");

#define CoopStructDepth(_y)// Forager y-sorts the world: an instance's depth is its negated y. The F10 probe
// (2026-10-20) found the player at y=656, depth -656, and a hand-built furnace at
// y=656, depth -656. instance_create_depth() with depth 0 therefore drops a
// peer's structure onto the wrong layer, so we compute the game's own value
// instead of guessing. Depth is a pure function of y, so both ends agree
// without carrying it on the wire.
return -floor(_y);

#define CoopSolidNear(_x, _y)
// How many things share the build-cell of (_x,_y) in a way that makes it
// unbuildable? Two groups, because they are not the same tree:
//
//  * parSolid - the one ancestor every tree, rock, bush *and* built structure
//    descends from. The live F12 probe (2026-10-20) walked the chains:
//        objFurnace -> objFurnace parStructure parObject parSolid
//        objTree    -> objTree    parNatural   parObject parSolid
//        objRock    -> objRock    parNatural   parObject parSolid
//    so one rule covers all of them; parStructure alone would miss trees and rocks,
//    and it has no instances of its own anyway (the game keeps a furnace under
//    objFurnace).
//
//  * Living things - the player and any NPC, enemy or pet. A player cannot build on
//    themselves or on another character, and parSolid does not cover them: the first
//    live run of this test (2026-10-20, 03:47) placed a furnace exactly under the
//    host at offset (0,0) and was accepted, which the owner caught at once. The
//    names below are resolved once and skipped when this build does not have them,
//    so a rename costs a missing guard and never a failed COMPILE.
//
// Only calls already proven live are used (asset_get_index, instance_number,
// instance_find, point_distance) - no collision builtin, which is what keeps this
// honest before one is tested.
if (global.coopSolidObj == -2) global.coopSolidObj = asset_get_index("parSolid");
if (global.coopLivingObjs == undefined) global.coopLivingObjs = [];
if (array_length(global.coopLivingObjs) == 0) {
    var _sld_names = ["objPlayer", "parNPC", "parEnemy", "objPet"];
    for (var _sld_ni = 0; _sld_ni < array_length(_sld_names); _sld_ni++) {
        var _sld_oi = asset_get_index(array_get(_sld_names, _sld_ni));
        if (_sld_oi >= 0) array_push(global.coopLivingObjs, _sld_oi);
    }
}
var _sld_hits = 0;
if (global.coopSolidObj >= 0) {
    var _sld_n = instance_number(global.coopSolidObj);
    for (var _sld_i = 0; _sld_i < _sld_n; _sld_i++) {
        var _sld_inst = instance_find(global.coopSolidObj, _sld_i);
        if (point_distance(_sld_inst.x, _sld_inst.y, _x, _y) <= global.coopSolidRadius) _sld_hits += 1;
    }
}
for (var _sld_li = 0; _sld_li < array_length(global.coopLivingObjs); _sld_li++) {
    var _sld_lobj = array_get(global.coopLivingObjs, _sld_li);
    var _sld_ln = instance_number(_sld_lobj);
    for (var _sld_lj = 0; _sld_lj < _sld_ln; _sld_lj++) {
        var _sld_linst = instance_find(_sld_lobj, _sld_lj);
        if (point_distance(_sld_linst.x, _sld_linst.y, _x, _y) <= global.coopSolidRadius) _sld_hits += 1;
    }
}
return _sld_hits;

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
// The peer's build menu, as id/name pairs. Ids stay indices into the full
// database (CoopFindStructure on the far end searches its own, identical one);
// only the *list* is pruned, so a peer never asks for something unnameable.
// This database has 92 entries in this build, not the 64 an earlier cap assumed
// (F10 probe, 2026-10-20), and its tail carries entries with an empty name
// (#68..#80) that a name-keyed wire cannot address at all.
if (array_length(global.coopStructNames) == 0) CoopBuildStructDb();
var _st_ids = [];
var _st_n   = array_length(global.coopStructNames);
for (var _st_i = 0; _st_i < _st_n; _st_i++) {
    if (global.coopStructNames[_st_i] == "") continue;
    array_push(_st_ids, _st_i);
}
var _st_c = array_length(_st_ids);
var _st_b = buffer_create(256, buffer_grow, 1);
buffer_write(_st_b, buffer_u8, CoopCmd.STRUCTURE_TABLE);
buffer_write(_st_b, buffer_u16, _st_c);
for (var _st_j = 0; _st_j < _st_c; _st_j++) {
    var _st_k = array_get(_st_ids, _st_j);
    buffer_write(_st_b, buffer_u16, _st_k);
    buffer_write(_st_b, buffer_string, global.coopStructNames[_st_k]);
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
// table thinks. The console gets the short half; the whole 64-entry
// id -> object table goes over the wire, to the peer, which writes it to
// %TEMP%\coop_debug.txt - this game's mods cannot write files themselves (see
// CoopSendDebugLine), and a screenshot of a table this size OCRs into nonsense.
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

// The whole id -> object table: wire only. 64 console lines would bury the part
// that matters, and the peer writes what we send to a file we can read.
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

// Out of the game. The peer is ours (tools/coop_mockpeer.py) and writes every
// DEBUG_LINE to %TEMP%\coop_debug.txt, so a dump arrives as text instead of as a
// screenshot whose digits OCR into nonsense. The begin/end markers say whether
// what arrived is a whole dump or half of one.
var _pw_sn = array_length(_pw_tbl);
CoopSendDebugLine("=== probe begin " + global.coopVersion + " ===");
for (var _pw_s = 0; _pw_s < _pw_n; _pw_s++) CoopSendDebugLine(array_get(_pw_lines, _pw_s));
for (var _pw_s2 = 0; _pw_s2 < _pw_sn; _pw_s2++) CoopSendDebugLine(array_get(_pw_tbl, _pw_s2));
CoopSendDebugLine("=== probe end (" + string(_pw_n) + " world + " + string(_pw_sn) + " table lines) ===");
if (global.coopSocket < 0) {
    Trace("Co-op: probe: no peer connected - the table half was dropped (only the lines above exist).");
}

#define CoopProbeApi()
// F11. Can a mod ask the game where water is? This is the question the M2.1 test
// raised: a client's intent is checked for who asked and how far, never for
// whether the spot is legal, so the mock's furnace landed on open water.
//
// `WaterCollision(x, y)` is documented ("Checks for a water tile at the given
// x/y"), but it is a **first-party API script**, not a builtin this build exports
// to mod GML - a bare `WaterCollision(x, y)` resolves as "not function or script"
// and takes the whole mod down.
//
// Live COMPILE (2026-10-20) settled the wrapper shape for us:
//     Mod failed to unit! Forager Coop/Net.gml[L536,c16] `ScriptCall` takes 1 argument, got 3.
// So ScriptCall(wrapper) takes the wrapper **only** - no argument list. The docs
// agree once you read them closely: ScriptWrap returns a 2d array [mod, methodName],
// and ScriptCall "executes a script based on the provided wrapper". A first-party
// script that *needs parameters* (WaterCollision wants x and y) therefore cannot be
// reached this way, which is what this probe reports.
//
// It stays diagnostic: it records what each accessor actually returns, with no
// call that could take the game down. Read-only; it creates nothing.
if (!instance_exists(objPlayer)) {
    Trace("Co-op: F11 needs a loaded world.");
    exit;
}

var _pa_px = floor(objPlayer.x);
var _pa_py = floor(objPlayer.y);
var _pa_lines = [];
array_push(_pa_lines, "=== api probe begin " + global.coopVersion + " ===");
array_push(_pa_lines, "player " + string(_pa_px) + "," + string(_pa_py));

// 1) What is a ScriptWrapper, really? The docs say "2d array [mod, methodName]".
//    Printing it says whether the name resolves and what the first-party mod id is.
var _pa_wrap = ScriptWrap("WaterCollision");
array_push(_pa_lines, "ScriptWrap type   = " + string(typeof(_pa_wrap))
           + ", len " + string(array_length(_pa_wrap)));
var _pa_wn = array_length(_pa_wrap);
for (var _pa_wi = 0; _pa_wi < _pa_wn; _pa_wi++) {
    array_push(_pa_lines, "  wrap[" + string(_pa_wi) + "] = " + string(array_get(_pa_wrap, _pa_wi)));
}

// 2) The first-party lookup: does "Forager" expose WaterCollision by name?
var _pa_fn = ModFunctionGet("Forager", "WaterCollision");
if (_pa_fn == undefined) {
    array_push(_pa_lines, "ModFunctionGet(\"Forager\",\"WaterCollision\") = undefined");
} else {
    array_push(_pa_lines, "ModFunctionGet type = " + string(typeof(_pa_fn))
               + ", value " + string(_pa_fn));
}

// 2b) Which mod ids does the API actually know? The docs say a ScriptWrapper is
//     [mod, methodName] and that index 0 is "Forager" if 1st party - but our own
//     wrap came back as [wrapper, "EgolzForagerCoop", "WaterCollision"], i.e. the
//     name resolved inside *our* mod, and "Forager" returned undefined. So the
//     real first-party id is something else and has to be discovered, not guessed.
//     ModFind/ModIsOnline answer whether an id exists at all.
var _pa_ids = ["Forager", "ForagerModdingAPI", "ModdingSample", "forager", "Forager Coop"];
for (var _pa_ii = 0; _pa_ii < array_length(_pa_ids); _pa_ii++) {
    var _pa_id = array_get(_pa_ids, _pa_ii);
    var _pa_found = -1;
    var _pa_online = -1;
    _pa_found  = ModFind(_pa_id);
    _pa_online = ModIsOnline(_pa_id);
    array_push(_pa_lines, "id '" + _pa_id + "' ModFind=" + string(_pa_found)
               + " ModIsOnline=" + string(_pa_online));
}

// 3) Calling a no-argument first-party script through the documented path is
//    safe. GetLandsOwned takes no arguments (docs: "Returns how many lands the
//    player has") and is in this build, so it is the control: if this line answers
//    with a number, ScriptCall(wrapper) works for zero-argument scripts, and the
//    only thing WaterCollision needs that we cannot supply is its x/y.
var _pa_safe = ScriptCall(ScriptWrap("GetLandsOwned"));
array_push(_pa_lines, "ScriptCall(ScriptWrap(\"GetLandsOwned\")) = " + string(_pa_safe));

// 4) The direct call. The docs list WaterCollision in "General Forager Behavior"
//    next to HasSkill and LighthouseCalculate, and the wrapper path is a dead end
//    for a first-party script:
//      * ScriptWrap resolves the name inside OUR mod ([wrapper, EgolzForagerCoop, ...])
//      * ModFunctionGet("Forager", ...) = undefined, and ModFind/ModIsOnline say the
//        game is not registered as a mod under any id we tried.
//    Live 2026-10-20: the bare call *does* compile and run -
//      WaterCollision(716,630) = 0   and   HasSkill(0) = 0
//    - so the API exposes it directly. What is still unproven is the *sense* of the
//    answer: 0 at a spot needs to be checked against a spot that is definitely water,
//    which is what the two extra points below are for. Sum the probe over the four
//    directions so one of them is likely to land on a shoreline or a pool.
var _pa_dir = WaterCollision(_pa_px, _pa_py);
array_push(_pa_lines, "WaterCollision(" + string(_pa_px) + "," + string(_pa_py) + ") = " + string(_pa_dir));

var _pa_off = 96;
array_push(_pa_lines, "left  " + string(WaterCollision(_pa_px - _pa_off, _pa_py)));
array_push(_pa_lines, "right " + string(WaterCollision(_pa_px + _pa_off, _pa_py)));
array_push(_pa_lines, "up    " + string(WaterCollision(_pa_px, _pa_py - _pa_off)));
array_push(_pa_lines, "down  " + string(WaterCollision(_pa_px, _pa_py + _pa_off)));
array_push(_pa_lines, "far +512 right " + string(WaterCollision(_pa_px + 512, _pa_py)));

// 4b) The control: HasSkill sits in the same docs list.
var _pa_skill = HasSkill(0);
array_push(_pa_lines, "HasSkill(0) = " + string(_pa_skill));

array_push(_pa_lines, "=== api probe end ===");

var _pa_n = array_length(_pa_lines);
Trace("--- Co-op api probe ---");
for (var _pa_i = 0; _pa_i < _pa_n; _pa_i++) {
    Trace("  " + array_get(_pa_lines, _pa_i));
    CoopSendDebugLine(array_get(_pa_lines, _pa_i));
}
Trace("---");

#define CoopProbeSpot()
// F12. Read-only. Is a spot free of *things*, the way water was free of land?
// The host's spot check catches water only, so an intent for a tile that already
// holds a furnace, a tree or a rock is applied anyway - a player could not have
// built there. WaterCollision settled water; nothing in the documented modding API
// answers occupancy (`General Forager Behavior` lists exactly HasSkill,
// LighthouseCalculate, WaterCollision), so this measures, it does not guess.
//
// Two independent readings, on purpose:
//   * The collision builtins (instance_position / place_meeting / position_meeting)
//     are the *right* answer if the loader exports them. data.win holds them, but
//     that is necessary, not sufficient - `ini_open` is in the build and still
//     refused. So each one gets its own line; if it is blocked the COMPILE error
//     names it and we drop that line, not the whole probe.
//   * An instance-distance count, using only calls already proven live in F10
//     (instance_number / instance_find / object_is_ancestor). This cannot fail on a
//     blocked builtin, so the probe still returns a usable answer either way.
//
// Everything is read-only: it creates nothing, moves nothing.
if (!instance_exists(objPlayer)) {
    Trace("Co-op: F12 needs a loaded world.");
    exit;
}

var _ps_px = floor(objPlayer.x);
var _ps_py = floor(objPlayer.y);
var _ps_lines = [];
array_push(_ps_lines, "=== spot probe begin " + global.coopVersion + " ===");
array_push(_ps_lines, "player " + string(_ps_px) + "," + string(_ps_py)
           + " depth " + string(objPlayer.depth));

// Which parent objects exist in this build? A name that is missing is worth
// knowing, because a check that silently measures nothing looks like "free".
// `parSolid` is the parent the first live run (2026-10-20) showed every tree and
// rock sitting under - it caught both with one number. What is still open is
// whether a *structure* (objFurnace) also descends from it, or from a separate
// branch, so the chain below is dumped rather than assumed.
var _ps_pars = ["parStructure", "parResource", "parSolid", "objTile",
                "objTree", "objRock", "objBush", "objCactus",
                "objPlayer", "parNPC", "parEnemy", "parEntity", "objPet"];
var _ps_found = [];
for (var _ps_pi = 0; _ps_pi < array_length(_ps_pars); _ps_pi++) {
    var _ps_pname = array_get(_ps_pars, _ps_pi);
    var _ps_pidx  = asset_get_index(_ps_pname);
    if (_ps_pidx < 0) {
        array_push(_ps_lines, "parent '" + _ps_pname + "' not in this build");
    } else {
        array_push(_ps_found, _ps_pidx);
        array_push(_ps_lines, "parent '" + _ps_pname + "' #" + string(_ps_pidx)
                   + " instances " + string(instance_number(_ps_pidx)));
    }
}

// 0) The parent chain of the objects that decide occupancy. object_get_parent is
//    already proven live in F10, so this cannot fail on a blocked builtin. Walking
//    it answers the one question the check's shape depends on: does a built
//    structure share an ancestor with a tree and a rock? If yes, one rule covers
//    all three; if no, the host needs a second rule.
var _ps_chainof = ["objFurnace", "objTree", "objRock", "parSolid", "parStructure",
                   "objPlayer", "parNPC", "parEnemy", "parEntity", "objPet"];
for (var _ps_ci = 0; _ps_ci < array_length(_ps_chainof); _ps_ci++) {
    var _ps_cname = array_get(_ps_chainof, _ps_ci);
    var _ps_cobj  = asset_get_index(_ps_cname);
    if (_ps_cobj < 0) {
        array_push(_ps_lines, "chain '" + _ps_cname + "': not in this build");
        continue;
    }
    var _ps_walk = "chain " + _ps_cname + " -> ";
    var _ps_up   = _ps_cobj;
    var _ps_guard = 0;
    while (_ps_up >= 0 && _ps_guard < 16) {
        _ps_walk += object_get_name(_ps_up) + " ";
        _ps_up = object_get_parent(_ps_up);
        _ps_guard += 1;
    }
    array_push(_ps_lines, _ps_walk);
}

// 1) The safe reading: how many object instances of the parents above sit within a
//    build-cell of the player. No collision builtin is involved, so a blocked
//    builtin cannot lose us this half. A structure is about one tile (16 px), so
//    anything within ~24 px is sharing the spot.
var _ps_r = 24;
var _ps_hits = 0;
var _ps_np = array_length(_ps_found);
for (var _ps_fi = 0; _ps_fi < _ps_np; _ps_fi++) {
    var _ps_obj = array_get(_ps_found, _ps_fi);
    var _ps_c   = instance_number(_ps_obj);
    for (var _ps_j = 0; _ps_j < _ps_c; _ps_j++) {
        var _ps_inst = instance_find(_ps_obj, _ps_j);
        var _ps_d = point_distance(_ps_inst.x, _ps_inst.y, _ps_px, _ps_py);
        if (_ps_d <= _ps_r) {
            _ps_hits += 1;
            array_push(_ps_lines, "  near " + object_get_name(_ps_inst.object_index)
                       + " at " + string(floor(_ps_inst.x)) + "," + string(floor(_ps_inst.y))
                       + " d " + string(round(_ps_d))
                       + " (parent " + object_get_name(_ps_obj) + ")");
        }
    }
}
array_push(_ps_lines, "within " + string(_ps_r) + "px of the player: "
           + string(_ps_hits) + " instance(s) of the parents above");

// 2) The collision builtins would be the *right* answer, and `data.win` holds
//    `instance_position`, `place_meeting`, `position_meeting` and `place_free`.
//    But that is necessary, not sufficient - `ini_open` is in the build and the
//    loader still refused it, taking the whole COMPILE down with one line. So the
//    candidate stays commented until a dedicated run, exactly like the bare
//    `WaterCollision` call was. The reading above is the one that cannot fail.
//
//    When uncommenting, do it one line at a time and re-COMPILE:
// var _ps_test = -1;
// if (array_length(_ps_found) > 0) _ps_test = array_get(_ps_found, 0);
// if (_ps_test >= 0) {
//     array_push(_ps_lines, "instance_position(" + string(_ps_px) + "," + string(_ps_py)
//                + ", " + object_get_name(_ps_test) + ") = "
//                + string(instance_position(_ps_px, _ps_py, _ps_test)));
//     array_push(_ps_lines, "place_meeting(" + string(_ps_px) + "," + string(_ps_py)
//                + ", " + object_get_name(_ps_test) + ") = "
//                + string(place_meeting(_ps_px, _ps_py, _ps_test)));
// }
array_push(_ps_lines, "collision builtins: not tried this run (see the note in F12)");

array_push(_ps_lines, "=== spot probe end ===");

var _ps_n = array_length(_ps_lines);
Trace("--- Co-op spot probe ---");
for (var _ps_i = 0; _ps_i < _ps_n; _ps_i++) {
    Trace("  " + array_get(_ps_lines, _ps_i));
    CoopSendDebugLine(array_get(_ps_lines, _ps_i));
}
Trace("---");

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
        CoopSendItemTable();
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
        // Is the spot buildable at all? Until now a client could ask for anything
        // in range, and the mock's furnace landed on open water - a player could
        // not have built there. WaterCollision(x, y) is the game's own answer and
        // this build lets a mod call it directly (F11, live 2026-10-20:
        // `WaterCollision(716,630) = 0` compiled and ran, so the wrapper path was
        // never needed). Non-zero means water, so the intent is refused.
        if (WaterCollision(_ix, _iy) != 0) {
            CoopSendIntentRejected(_iid, "that spot is on water");
            Trace("Co-op: refused intent #" + string(_iid) + " - water at "
                  + string(_ix) + "," + string(_iy) + ".");
            break;
        }
        // Occupied? A player can build on bare ground only - not on a tree, a rock
        // or an existing structure. WaterCollision answers water; this answers
        // "something is already standing here", measured against parSolid, the one
        // ancestor trees, rocks and buildings share (F12, live 2026-10-20).
        if (CoopSolidNear(_ix, _iy) > 0) {
            CoopSendIntentRejected(_iid, "that spot is already occupied");
            Trace("Co-op: refused intent #" + string(_iid) + " - solid at "
                  + string(_ix) + "," + string(_iy) + ".");
            break;
        }

        var _placed = CoopCreateStructure(_sid, _ix, _iy, CoopStructDepth(_iy));
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
        // Depth is recomputed rather than taken from the wire: the host's
        // OnStructureSpawn() fires before the game sets a depth (the mutation
        // went out with 0 for an instance that really sat at -656), and depth is
        // a pure function of y anyway, so both ends derive the same value.
        CoopCreateStructure(_msid, _mx, _my, CoopStructDepth(_my));
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

    case CoopCmd.ITEM_TABLE:
        // Same divergence check as the structure table, for M2.2 - with one
        // difference the F3 probe forced (2026-10-20): item **names are localized**
        // ("Древесина", not "wood"), so counting name matches would scream on two
        // installs that merely run different languages while their ids are fine.
        // The verdict is therefore count + the anchor ids; the names are read only
        // to report which rows moved when something really is wrong.
        if (array_length(global.coopItemNames) == 0) CoopBuildItemDb();
        var _itn     = buffer_read(_buf, buffer_u16);
        var _itnames = [];
        for (var _iti = 0; _iti < _itn; _iti++) {
            var _itid   = buffer_read(_buf, buffer_u16);
            var _itname = buffer_read(_buf, buffer_string);
            _itnames[_itid] = _itname;
        }
        var _itlocal = global.coopItemCount;
        Trace("Co-op: host item table: " + string(_itn) + " entries, we have "
              + string(_itlocal) + ".");
        if (_itn != _itlocal) {
            Trace("Co-op: WARNING - item databases differ in size; the two installs "
                  + "are not the same build, and loot ids will not line up.");
            break;
        }
        // The anchors are constants of the build, so they must agree whatever the
        // language. If one moved, ids shifted and loot would arrive as a wrong item.
        var _it_anchors = ["Wood", "Stone", "Coin"];
        var _it_aids    = [Item.Wood, Item.Stone, Item.Coin];
        var _it_bad     = 0;
        for (var _itai = 0; _itai < array_length(_it_aids); _itai++) {
            var _itavo = array_get(_it_aids, _itai);
            if (array_get(_itnames, _itavo) == global.coopItemNames[_itavo]) continue;
            _it_bad += 1;
            Trace("Co-op: WARNING - anchor #" + string(_itavo) + " ("
                  + array_get(_it_anchors, _itai) + ") is '"
                  + global.coopItemNames[_itavo] + "' here and '"
                  + array_get(_itnames, _itavo) + "' there.");
        }
        if (_it_bad > 0) {
            Trace("Co-op: WARNING - item ids shifted between the installs; loot would "
                  + "arrive as the wrong item.");
        } else {
            Trace("Co-op: item ids agree on all anchors.");
        }
        break;

    case CoopCmd.DROP:
        // An item appeared in the world. The peer already has it (or, if we are the
        // host, the world already spawned it) - we only mirror it.
        var _dx   = buffer_read(_buf, buffer_s32);
        var _dy   = buffer_read(_buf, buffer_s32);
        var _drm  = buffer_read(_buf, buffer_u8);
        var _dit  = buffer_read(_buf, buffer_u16);
        var _dstk = buffer_read(_buf, buffer_u16);
        if (instance_exists(objPlayer) && _drm != objPlayer.room) break;
        var _dres = CoopApplyDrop(_dx, _dy, _dit, _dstk);
        if (_dres >= 0) {
            Trace("Co-op: <- drop item #" + string(_dit) + " x" + string(_dstk)
                  + " at " + string(_dx) + "," + string(_dy)
                  + " (" + CoopItemName(_dit) + ").");
        }
        break;

    case CoopCmd.PICKUP:
        var _px2  = buffer_read(_buf, buffer_s32);
        var _py2  = buffer_read(_buf, buffer_s32);
        var _prm  = buffer_read(_buf, buffer_u8);
        var _pit  = buffer_read(_buf, buffer_u16);
        if (instance_exists(objPlayer) && _prm != objPlayer.room) break;
        if (CoopApplyPickup(_px2, _py2, _pit) > 0) {
            Trace("Co-op: <- pickup item #" + string(_pit) + " at "
                  + string(_px2) + "," + string(_py2) + ".");
        }
        break;

    case CoopCmd.RESOURCE_DESTROY:
        var _rx   = buffer_read(_buf, buffer_s32);
        var _ry   = buffer_read(_buf, buffer_s32);
        var _rrm  = buffer_read(_buf, buffer_u8);
        var _robj = buffer_read(_buf, buffer_u16);
        if (instance_exists(objPlayer) && _rrm != objPlayer.room) break;
        var _rnumb = CoopApplyResourceDestroy(_rx, _ry, _robj);
        if (_rnumb > 0) {
            Trace("Co-op: <- resource destroyed obj#" + string(_robj) + " at "
                  + string(_rx) + "," + string(_ry) + ".");
        }
        break;

    default:
        Trace("Co-op: unknown packet id " + string(_cmd));
}
