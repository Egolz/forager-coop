#define OnDrawEnd
// Forager Co-op - draws the remote player where they are.
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
// `mov ecx, dword ptr [esi]` - the first field read of `this` inside an engine hash-map lookup
// (`call` a hash of the key, mask by capacity-1, compare at `+8`, walk the chain at `+4`). It
// faults because `this` is null or freed. It is called from six places, and none of them is
// this file. **The crash is in the engine's own lookup, not in the mod's drawing.**
//
// So the rules this file follows are good rules that did not fix a crash:
//   * **draw sprites, own no state.** `draw_sprite_ext` takes alpha per call and restores
//     nothing, so it cannot leave the renderer in a state the game does not expect.
//   * draw nothing when the required data is missing, rather than guessing.
// Keeping it this way because it is correct and cheap, not because it cures anything.

if (!global.coopPeerAlive || !global.coopPeer.seen) exit;
if (!instance_exists(objPlayer)) exit;
if (objPlayer.room != global.coopPeer.room) exit;

// The sprite to draw, and why there is a fallback.
//
// `POS` carries the sender's own `objPlayer.sprite_index`, so a real Forager peer always sends a
// usable one. The **mock peer does not**: it has no access to the game's assets and sends
// `sprite = -1`, and the first run of this file therefore drew nothing at all - the marker simply
// vanished, which read as "the draw code is broken" when it was the packet that had no sprite in
// it. Requiring a sprite from a peer that cannot supply one made a cosmetic dependency into a
// hard one.
//
// So the peer's sprite is used when it has one and the **host's own player sprite** stands in
// when it does not. Falling back to a real sprite (rather than to a circle or a primitive) keeps
// the rule this file exists for: draw sprites, own no state.
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
