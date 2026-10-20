#define OnDrawEnd
// Forager Co-op - draws the remote player and their name.
//
// Two earlier versions of this file were wrong about why the game crashed on leaving a world,
// and both are worth keeping only as a warning.
//
// v1 drew an aqua circle with `draw_circle_color` plus `draw_set_alpha` / `draw_set_colour` /
// `draw_set_halign` / `draw_text`. v2 drew the peer sprite with `draw_sprite_ext` instead, on
// the theory that the crash was a **drawing-state fault**: the game dies with a native access
// violation (`0xc0000005`) at one fixed address on "save and quit", only while a peer is
// connected, and never during play - which does look like a renderer being disturbed. That
// theory is now **disproved by a live run**: v2 crashed at the same address as v1, and v2 had
// no primitive and no `draw_set_*` call anywhere.
//
// What the address actually is was read afterwards with a disassembler, and reading it needed
// no theory at all: `0x012c265f` is an RVA (not a file offset - an earlier pass got that
// wrong by 0xc00 bytes and analysed the wrong instruction), and it lands on
// `mov ecx, dword ptr [esi]` - the first field read of `this` inside an engine hash-map lookup.
// It faults because `this` is null or freed, and the cause is a socket left live during world
// teardown, fixed in `OnStep`. **The crash is not in the mod's drawing at all.**
//
// So the rule this file follows is a good rule that did not fix a crash, and it has changed
// shape: it is no longer "never touch draw state", it is **own no state** - set what a draw
// needs, restore it, and never leave the renderer somewhere the game did not put it. The name
// over the puppet's head needs horizontal centring and bottom alignment to sit above the
// sprite, so this file sets `draw_set_halign` / `draw_set_valign` and puts them back to the
// GameMaker defaults (`fa_left`, `fa_top`) on the way out. Restoring matters because the
// game's own HUD text is drawn later in the same frame's pipeline and would otherwise inherit
// our alignment.
//
// The sprite is the peer's own, taken from the `POS` packet (`global.coopPeer.sprite`), with the
// host's own player sprite standing in when the peer sent none (the mock peer sends `sprite =
// -1` and has no assets to send). The name comes from the handshake (`global.coopPeerName`,
// M3.1) and falls back to "peer" until one arrives.

if (!global.coopPeerAlive || !global.coopPeer.seen) exit;
if (!instance_exists(objPlayer)) exit;
if (objPlayer.room != global.coopPeer.room) exit;

// A sprite index the peer sent. `POS` carries the sender's own `objPlayer.sprite_index`, so a
// real Forager peer always sends a usable one. The **mock peer does not**: it has no access to
// the game's assets and sends `sprite = -1`, and the first run of this file therefore drew
// nothing at all - the marker simply vanished, which read as "the draw code is broken" when it
// was the packet that had no sprite in it. Requiring a sprite from a peer that cannot supply one
// made a cosmetic dependency into a hard one.
//
// So the peer's sprite is used when it has one and the **host's own player sprite** stands in
// when it does not. Falling back to a real sprite (rather than to a circle or a primitive) keeps
// this file free of primitives, which is worth having anyway.
var _spr = global.coopPeer.sprite;
if (_spr <= 0) _spr = objPlayer.sprite_index;
if (_spr <= 0) exit;

var _x = global.coopPeer.x;
var _y = global.coopPeer.y;

// Facing is signed (1 right, -1 left) and scales x only, exactly as the game draws its own
// player. Alpha is passed per call: no global draw state is touched, so nothing to restore.
var _face = global.coopPeer.facing;
if (_face == 0) _face = 1;

draw_sprite_ext(_spr, 0, _x, _y - 30, _face, 1, 0, c_white, 0.85);

// The name, centred over the puppet and small enough to read as a label rather than as a
// signpost.
//
// The position is **computed, not guessed**. A sprite's origin is not its top-left corner:
// `sprite_get_yoffset` says how far down the origin sits inside the image, so when the sprite
// is drawn at (x, y) its top edge is at `y - yoffset`. A fixed pixel offset was wrong by most
// of a sprite, which is why the name first landed *inside* the puppet instead of above its
// head.
//
// **One argument, not two.** This build's `sprite_get_yoffset` takes only the sprite - the
// subimage variant is not in it, and the mod loader's error says so exactly:
// `sprite_get_yoffset` takes 1 argument, got 2. The same goes for `sprite_get_height`.
//
// `draw_text_ext` takes the alignment and the scale as arguments, so this needs no draw state
// at all - which matters, because the game's own HUD text is drawn in the same frame and
// would otherwise inherit whatever this left behind. The horizontal centring is done by hand
// (`string_width` is the unscaled width, so it is scaled by hand too) because the alignment
// argument of `draw_text_ext` is horizontal only, and `fa_center` is a constant this build
// does not export.
var _name = global.coopPeerName;
if (_name == "") _name = "peer";

var _yd  = _y - 30;                              // where the sprite is drawn
var _top = _yd - sprite_get_yoffset(_spr);       // the sprite's top edge

var _scale = 0.6;
var _nw = string_width(_name) * _scale;
var _nh = string_height(_name) * _scale;

draw_text_ext(_x - _nw / 2, _top - _nh - 3, _name, c_white, 1, fa_left, _scale, _scale);
