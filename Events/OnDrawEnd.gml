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
// The sprite to draw.
//
// The peer's `POS` now carries the **body sprite** - a real asset index, resolved by name on
// the peer's side (see CoopResolveBodySprite), because the player's instance reports
// `sprite_index` 0 in this build. When the peer cannot supply one (the mock peer has no
// assets and sends -1), the host's own body sprite stands in: it is the same game, so it is
// the same body.
//
// **The name is drawn even when there is no sprite.** A peer that cannot be drawn is exactly
// the situation where the owner needs to see that the peer is there at all, so the label
// does not depend on the body being drawable.
var _spr = global.coopPeer.sprite;
if (_spr <= 0) {
    CoopResolveBodySprite();
    _spr = global.coopBodySprite;
}

// Where the peer is drawn. **The host decides.** A peer with no physics - the mock - reports
// a position that can be inside a tree or in the water, and the owner saw exactly that. The
// host knows the world, so it pulls the peer onto ground a body could stand on, which is the
// same pair of checks the placement code already asks. See CoopStandSpot.
CoopStandSpot(global.coopPeer.x, global.coopPeer.y);
var _x = global.coopStandX;
var _y = global.coopStandY;

// Facing is signed (1 right, -1 left) and scales x only, exactly as the game draws its own
// player. Alpha is passed per call: no global draw state is touched, so nothing to restore.
var _face = global.coopPeer.facing;
if (_face == 0) _face = 1;

// Where the sprite is drawn so that its **feet land on the peer's position**. A sprite's
// origin is not its top-left corner and not necessarily its bottom either, and
// `sprite_get_yoffset` says how far down the origin sits inside the image - so the image's
// bottom edge is `drawn_y - yoffset + height`, and putting that on the peer's y gives
// `drawn_y = peer_y - height + yoffset`. The old fixed offset of -30 was a guess that put the
// puppet in the air or underground depending on the sprite.
//
// The defaults are for the case where there is no sprite at all: a name on its own still has
// to land somewhere sensible.
var _h  = 24;
var _yo = 24;
if (_spr > 0) {
    _h  = sprite_get_height(_spr);
    _yo = sprite_get_yoffset(_spr);
}
var _yd = _y - _h + _yo;
var _top = _yd - _yo;      // the sprite's top edge, in world coordinates

if (_spr > 0) {
    draw_sprite_ext(_spr, 0, _x, _yd, _face, 1, 0, c_white, 0.85);
}

// The name, centred over the puppet.
//
// **This build's text functions are not GameMaker's.** The loader rejected the stock call:
// `draw_text_ext` takes 5 arguments, got 8. Forager ships its own, and the one mod that runs
// in this build shows what they are:
//
//     draw_text_ext(x, y, string, size, width)                                    // 5
//     draw_text_ext_transformed_color(x, y, string, size, width,
//                                     xscale, yscale, rotation,
//                                     c1, c2, c3, c4, alpha)                    // 13
//     draw_text_transformed_color(x, y, string, xscale, yscale, rotation,
//                                  c1, c2, c3, c4, alpha)                         // 11
//
// (From the reference mod's GUI.gml - `draw_text_ext_transformed_color(textBox.x1+10,
// textBox.y1+10, _str, 30, ((textBox.x2-textBox.x1)+100-5), .7, .7, 0, _color, _color,
// _color, _color, _alpha)`.) The stock `draw_text_ext` has alignment and two scales; this
// one has a **size** and a **width** instead, so the stock call cannot be adapted by
// argument order - it is a different function.
//
// The transformed variant is used because it takes the size directly, which is what a small
// label needs, and because the shape above is copied from a call that demonstrably renders in
// this build rather than guessed. The four colours are all the same, exactly as the reference
// mod passes them, so the text is one flat colour.
//
// The vertical position is **computed, not guessed**: a sprite's origin is not its top-left
// corner, and `sprite_get_yoffset` says how far down the origin sits inside the image, so
// when the sprite is drawn at (x, y) its top edge is at `y - yoffset`. A fixed pixel offset
// was wrong by most of a sprite, which is why the name first landed *inside* the puppet.
//
// The horizontal centring uses `draw_set_halign`, and the previous alignment is put back
// afterwards: the game's own HUD text is drawn in the same frame, and the reference mod
// manages its alignment the same way (it sets `fa_left` / `fa_top` before its own draws).
var _name = global.coopPeerName;
if (_name == "") _name = "peer";

// The name sits just above the sprite's head. `_top` is already the sprite's top edge, and
// the text is 60% of the default font, so a fixed gap of a few pixels is enough.
draw_set_halign(fa_center);
draw_text_ext_transformed_color(_x, _top - 9, _name, 12, 200, 0.45, 0.45, 0,
                                c_white, c_white, c_white, c_white, 1);
draw_set_halign(fa_left);
