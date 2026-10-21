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
// same pair of checks the placement code already asks. Mode 0: a peer, so its own position
// is kept, its cell has to be free of solids - **the player does not count**, because the
// mock stands on the player's own cell on purpose: the game spawns nothing on the tile a
// player stands on, and that is what keeps ore off the mock (live, 2026-10-21).
// See CoopStandSpot.
CoopStandSpot(global.coopPeer.x, global.coopPeer.y, 0);

// **The puppet's own position, which walks toward the reported one.**
//
// The positions arrive twenty times a second and the game draws sixty times a second, so
// a puppet drawn at the reported position moves in visible steps - and a **roll** (three
// cells in one go, in one packet) would be a teleport rather than a roll.
//
// So the puppet has a position of its own and moves toward the reported one at the speed
// the peer is actually moving - the speed is measured on the far end, from the peer's own
// movement between two packets. The step is capped so a lost packet cannot send the
// puppet across the island, and the puppet never goes past the target.
var _tx = global.coopStandX;
var _ty = global.coopStandY;
if (!global.coopDrawInit) {
    global.coopDrawX = _tx;
    global.coopDrawY = _ty;
    global.coopDrawInit = true;
}
var _dx = _tx - global.coopDrawX;
var _dy = _ty - global.coopDrawY;
var _dist = point_distance(global.coopDrawX, global.coopDrawY, _tx, _ty);
if (_dist > 0.01) {
    // How far this frame may go: the peer's own speed, over the time since the last
    // frame. The step is capped so a lost packet cannot send the puppet across the
    // island, and the puppet never goes past the target.
    var _now = current_time;
    var _dt = global.coopDrawAt > 0 ? (_now - global.coopDrawAt) : 16;
    global.coopDrawAt = _now;
    if (_dt < 1) _dt = 1;
    if (_dt > 100) _dt = 100;
    var _step = global.coopPeerSpeed * _dt;
    if (_step > 24) _step = 24;
    if (_step < 0) _step = 0;
    // **The catch-up step has a floor, and that is what removed the stutter.**
    //
    // The step is the peer's *measured* walking speed, so a packet that arrives while the
    // peer is slowing down carries a small speed - and the puppet then crawls toward the
    // reported spot for a whole frame, which reads as a **micro-freeze** (the owner saw it
    // live, 2026-10-22: "sometimes the mock's model has a micro-freeze while walking").
    //
    // A floor of about a third of the distance, never below the display frame's own
    // pixels-per-frame (`6 * _dt`, the game's walk speed), means the puppet always closes
    // a good part of the gap in the frame it is given, and the motion is even instead of
    // stop-and-go. It still cannot go past the target, and the lost-packet cap stays.
    if (global.coopPeerSpeed <= 0.001) {
        // The peer is standing still: settle on the reported spot.
        global.coopDrawX = _tx;
        global.coopDrawY = _ty;
    } else if (_step >= _dist) {
        // Close enough: land on it.
        global.coopDrawX = _tx;
        global.coopDrawY = _ty;
    } else {
        var _floor_step = _dist * 0.34;
        var _min_step = 6 * _dt;
        if (_floor_step < _min_step) _floor_step = _min_step;
        if (_step < _floor_step) _step = _floor_step;
        if (_step >= _dist) {
            global.coopDrawX = _tx;
            global.coopDrawY = _ty;
        } else {
            global.coopDrawX += _dx / _dist * _step;
            global.coopDrawY += _dy / _dist * _step;
        }
    }
}
var _x = global.coopDrawX;
var _y = global.coopDrawY;

// Facing is signed (1 right, -1 left) and scales x only, exactly as the game draws its own
// player. Alpha is passed per call: no global draw state is touched, so nothing to restore.
var _face = global.coopPeer.facing;
if (_face == 0) _face = 1;

// **The animation (M3.4, measured 2026-10-22).** The frame is the peer's own, as sent - there
// is nothing to run locally.
//
// **The arithmetic, from two numbers in the owner's own wire log - and it is `floor(index)`,
// with no division at all.** The earlier "over two ticks" came from a wrong pairing of the
// constants, and the owner's report ("the animation was better before") is what sent this
// back to the numbers:
//
//  * **15 px of walking moved the index 3.15** - so one index-unit is 15 / 3.15 = **4.76 px**.
//  * `PLAYER_WALK_SPEED 90 px/s`, and the index moves 3.15 per 15 px, so the index runs at
//    90 / 4.76 = **18.9 units per second** - which is the walk constant divided by the step
//    the log measures, not by `SPAWN_ANIM_SPEED 4` (that pairing gave 22.5 and is what was
//    wrong).
//  * The index runs `0.00 … 5.85 -> 0.00`, so the cycle is **six index-units**.
//
// Six units a cycle at 4.76 px each is 28.6 px of walking per sprite cycle, i.e. **0.32 s** at
// 90 px/s - an ordinary walk cycle. Dividing by two made the sprite take twelve units, 57 px
// and 0.63 s per cycle: **half rate**, which is exactly what the owner saw after the last
// change. So the sprite frame **is** the index, and the cycle is six.
//
// **What each earlier version got wrong**, so it is not tried a fourth time: sending an
// integer threw the timer away and stuttered; running a *local cycle* of twelve frames made
// the puppet walk at half the player's rate; a **division by two** did the same; and
// **interpolating** the frame carried it a packet behind the player.
var _frame = floor(global.coopPeerStep);
if (_frame < 0) _frame = 0;
if (_frame > global.coopStepMax) _frame = global.coopStepMax;

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

// **The roll (measured, 2026-10-22).** It is **not** a spin: the mod printed its own
// `objPlayer.angle` while the owner rolled live and it **never left zero**. What the index
// does instead is **reset** - `5.85 -> 0.00` - and that reset is the only mark of a roll the
// wire carries.
//
// So the puppet spins on the reset: `global.coopRollSpin` is set from the packet handler for
// a quarter of a second, and the sprite is turned through a full circle over that time. The
// game's own roll is a spin of the body - it has no sprite of its own, which is why the
// assets are only idle and walk - so a turn is what it should look like.
if (global.coopRollSpin > 0) {
    global.coopRollSpin -= _dt / 1000;
    if (global.coopRollSpin < 0) global.coopRollSpin = 0;
}
var _roll_angle = 0;
if (global.coopRollStep > 0) {
    // 0 -> 360 degrees as the spin runs out.
    _roll_angle = 360 * (1 - global.coopRollSpin / global.coopRollStep);
}

// The angle is still carried and still drawn: the reference mod draws its puppet with it,
// and if this build ever turns the player, the turn should show. On top of it goes the roll.
var _draw_angle = global.coopPeer.angle + _roll_angle;

// **What decides the dust is the packet, not the sprite name.** Two rewrites of the frame
// code dropped the `_walking` local and left the dust test below reading a variable that no
// longer existed - so this whole handler died at that line (`does not have a variable
// _walking`) and **the puppet was not drawn at all**: no body, no name, no held item, and no
// dust. The owner's report read as "the mob is still not there" and the real symptom was
// "nothing is drawn any more". The walking flag lives in a global; read it from there.
var _walking = global.coopPeerWalking;
if (_spr > 0) {
    draw_sprite_ext(_spr, _frame, _x, _yd, _face, 1, _draw_angle, c_white, 0.85);
}

// **The dust the player kicks up while walking.**
//
// The game's own dust is a real object (`objDust`), spawned by the player's own movement -
// a puppet is a drawing and cannot make the game spawn anything, so this is the mod's
// own puff instead: the same sprite (`sprDust`), drawn at the feet while walking.
//
// Three things were wrong with it before, and the owner's reports are what found each:
//
//  * it was drawn at the body's **draw position**, which is two dozen pixels above the
//    ground, so a small sprite floated in the air and was invisible (2026-10-22);
//  * it was drawn only when the frame *changed*, and was then a plain round puff at alpha
//    0.5 - the owner saw it, and saw that it "does not animate" (2026-10-22). A puff frozen
//    on one frame reads as a graphic glitch, not as dust.
//
// So the puff is **animated**: `sprDust` has its own sub-images, the counter below runs
// through them at the game's own rate, and the puff is drawn by its own metrics so its
// bottom edge lands on the ground.
if (_walking) {
    if (global.coopDustSprite <= 0) {
        global.coopDustSprite = asset_get_index("sprDust");
        // **How many frames the puff has - asked, not guessed.** `sprite_get_number(name)`
        // is the standard call for a sprite's sub-image count and it resolves in this build.
        // The guess of four that stood here before was a guess, and a guess that is *wrong
        // in the high direction draws nothing*: a frame past the end of a sprite is empty,
        // so the cycle sat on blank frames and the owner saw a puff that "does not move"
        // (live, 2026-10-22). `sprDust` also exists - it was checked in the asset table
        // alongside `objDust`, `DustSpawn` and `DustEntityStep`.
        global.coopDustFrames = 0;
        if (global.coopDustSprite > 0) {
            global.coopDustFrames = sprite_get_number(global.coopDustSprite);
            if (global.coopDustFrames < 1) global.coopDustFrames = 1;
        }
    }
    if (global.coopDustSprite > 0 && global.coopDustFrames > 0) {
        // **The puff runs on its own clock, not the walk cycle.** Tying it to the walk was the
        // mistake twice over: the walk cycle is six steps to the player's half-second, so a
        // puff that advanced with it moved in visible jerks and then sat still. This is a
        // free-running counter - one sub-image every fourth drawn frame, about fifteen puffs a
        // second - so the dust animates while the puppet walks.
        global.coopDustTimer += 1;
        if (global.coopDustTimer >= 4) {
            global.coopDustTimer = 0;
            global.coopDustFrame += 1;
            if (global.coopDustFrame >= global.coopDustFrames) global.coopDustFrame = 0;
        }
        var _dh = sprite_get_height(global.coopDustSprite);
        var _dyo = sprite_get_yoffset(global.coopDustSprite);
        var _ddy = _y - _dh + _dyo;
        // **Twice as wide as tall.** Forager's players move left and right almost all the
        // time, and `sprDust` is a soft round puff; stretched horizontally it reads as the
        // smear a foot leaves on the ground rather than as a ball.
        draw_sprite_ext(global.coopDustSprite, global.coopDustFrame, _x - _face * 6, _ddy,
                        2, 1, 0, c_white, 0.75);
    }
}

// **The item in the peer's hand (M3.4).** The peer sends the item's **id**, and the
// sprite comes from the game's own item database: `ItemGet(id, ItemData.Sprite)` - the
// same call the reference mod makes, which is the only proof that the enum member and the
// call shape are right in this build.
//
// It is drawn beside the body, five pixels to the side of the way the peer faces and two
// pixels up, turned on its side - the reference mod's shape, which is what makes the
// held thing read as held rather than as a dropped item.
//
// The item ids 114..129 are the ones the reference mod draws **upright** rather than on
// their side; that is its own judgement about which items look wrong rotated, and it is
// copied here rather than reinvented.
if (global.coopPeerHold >= 0 && global.coopPeerHold < 65535) {
    var _hold_spr = ItemGet(global.coopPeerHold, ItemData.Sprite);
    if (typeof(_hold_spr) == "number" && _hold_spr > 0) {
        var _hold_rot = 90 * _face;
        if (global.coopPeerHold >= 114 && global.coopPeerHold <= 129 && _face == 1) {
            _hold_rot = 90;
        }
        draw_sprite_ext(_hold_spr, _hold_spr, _x + (_face == 1 ? -5 : 5), _y - 2, 1, 1,
                        _hold_rot, c_white, 0.85);
    }
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
// The horizontal centring uses `draw_set_halign`, and the alignment is put back
// afterwards: the game's own text is drawn in the same frame, and the reference mod
// manages its alignment the same way.
//
// **The alignment that is put back is `fa_center`, not `fa_left`.** The owner noticed
// (live, 2026-10-21) that the character's own speech - the line over its head, "energy
// running out", "let's build a furnace first!" - sat **a little to the right** of where
// it belongs whenever the mod was loaded.
//
// The game draws that line **centred**, and it does not set the alignment for it: the
// text takes the alignment left over by the frame's own drawing. So the alignment the
// mod inherits at the end of the frame is `fa_center`, and putting back `fa_left` turned
// a centred line into a left-aligned one - and a left-aligned line at the same anchor
// starts half a text further right, which is exactly what was seen.
//
// There is a getter in the build's symbol table (`draw_get_halign`), and saving the
// value would be the textbook fix - but `data.win` is **not** the loader's function
// table (it also lists `ini_open`, which the loader refuses with "not function or
// script"), and a name the loader does not know fails the whole COMPILE. Restoring
// `fa_center` costs nothing and cannot fail to load. If a frame ever needs a different
// value, the getter is the way - but it has to be proven on a live COMPILE first.
var _name = global.coopPeerName;
if (_name == "") _name = "peer";

// The name sits just above the sprite's head. `_top` is already the sprite's top edge, and
// the text is 60% of the default font, so a fixed gap of a few pixels is enough.
draw_set_halign(fa_center);
draw_text_ext_transformed_color(_x, _top - 9, _name, 12, 200, 0.45, 0.45, 0,
                                c_white, c_white, c_white, c_white, 1);
draw_set_halign(fa_center);
