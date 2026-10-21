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
// **Is the peer walking?** The peer's own flag, read once at the top, because three things need
// it: which sprite to draw (idle vs walk), whether to advance the walk cycle at all, and the dust.
// It used to be read far below, at the dust, and a rewrite that dropped it there killed the whole
// handler once ("does not have a variable _walking"). Reading it once, early, is the fix for both.
var _walking = global.coopPeerWalking;

// **Which sprite, and it now depends on the peer's state in both directions** (M5k).
//
// `global.coopPeer.sprite` is what the peer sent, already resolved by
// `CoopResolvePeerSprite` - `sprPlayerWalk` for `"walk"`, the idle sprite for `"idle"` - so a real
// Forager peer needs nothing here. The mock peer sends `sprite = -1` (it has no assets), so this
// block is the whole decision for it:
//
//   * **walking** -> `global.coopWalkSprite` (`sprPlayerWalk`, six frames, resolved by name);
//   * **standing** -> the **body**, which is the walk sprite **held on its standing frame**. The
//     `...Idle` names in this build are cosmetics **overlays** (glasses, bow, backpack), not bodies:
//     the run of 2026-10-22 drew `sprPlayerGlassesIdle` for a standing peer and the owner saw
//     **"only the glasses, the name, and the tree"** - the accessory with no body under it.
//
// So a standing peer is drawn with the same body as a walking one, at frame 0, and **not animated**:
// the body has no idle animation to play, and the bob the owner sees on their own model is in the
// overlay layers. `CoopResolveIdleSprite` still answers `-1` for a genuine body idle if one ever
// turns up, and then the bob is played at the game's own rate (see the idle clock below).
var _idle_body = -1;              // a real idle BODY sprite, or -1 for "hold the walk sprite"
if (!_walking) CoopResolveIdleSprite();
if (!_walking && global.coopIdleSprite > 0) _idle_body = global.coopIdleSprite;

var _spr = global.coopPeer.sprite;
if (_spr <= 0) {
    var _fallback = -1;
    if (_walking) {
        if (global.coopWalkSprite <= 0) {
            global.coopWalkSprite = asset_get_index("sprPlayerWalk");
            if (global.coopWalkSprite <= 0) global.coopWalkSprite = asset_get_index("Player Walk");
        }
        _fallback = global.coopWalkSprite;
    } else {
        // The body while standing: a real idle body if the game has one, else the walk sprite held.
        _fallback = _idle_body;
    }
    if (_fallback <= 0) {
        CoopResolveBodySprite();
        _fallback = global.coopBodySprite;
    }
    _spr = _fallback;
}
// Is the body being **animated** while standing? Only when there is a real idle body sprite.
var _idle_anim = (!_walking && _idle_body > 0);

// Where the peer is drawn. **The host decides.** A peer with no physics - the mock - reports
// a position that can be inside a tree or in the water, and the owner saw exactly that. The
// host knows the world, so it pulls the peer onto ground a body could stand on, which is the
// same pair of checks the placement code already asks. Mode 0: a peer, so its own position
// is kept, its cell has to be free of solids - **the player does not count**, because the
// mock stands on the player's own cell on purpose: the game spawns nothing on the tile a
// player stands on, and that is what keeps ore off the mock (live, 2026-10-21).
// See CoopStandSpot.
CoopStandSpot(global.coopPeer.x, global.coopPeer.y, 0);

// **How long this frame lasted** - measured once, at the top, so **every** timed thing in this
// handler uses the same clock. It used to be computed inside the position block, which only runs
// while the puppet still has a gap to close: on the frames where the puppet had arrived, `_dt`
// was whatever the last moving frame left behind, and the **roll** (which turns by `_dt`) froze
// mid-turn. The owner's "sometimes turns diagonally" is partly this - a spin that stopped at an
// angle and stayed there.
var _now = current_time;
var _dt = global.coopDrawAt > 0 ? (_now - global.coopDrawAt) : 16;
global.coopDrawAt = _now;
if (_dt < 1) _dt = 1;
if (_dt > 100) _dt = 100;

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

// **The animation (M5j, measured 2026-10-22).** The frame is **not** the peer's index - that
// number is a free-running timer, and this block used to say the opposite, in a paragraph that
// also disagreed with the code below it. It is deleted rather than kept: a stale comment that
// contradicts the code next to it is how the next wrong guess gets written.
//
// What is left of the old reasoning is the two constants it got wrong, recorded so they are not
// used again: "15 px of walking moved the index 3.15, so one unit is 4.76 px" and "a cycle is six
// units, i.e. 0.32 s". The probe's own clean walking samples say **12.2, 13.0, 12.8 px per unit**
// (33/2.70, 76/5.85, 75/5.85), which is where the 12.2 below comes from.
//
// **The index runs while the player stands still**, so it also cannot be the walk:
//
//     idx 120 d 0   px 15   moved 0    <- stood still, the index did not move
//     idx 105 d 585 px 76   moved 0    <- then ran a whole cycle while walking 76 px
//     pos 667 frame 2.55 -> pos 671 frame 3.00    <- +0.45 for 4 px
//     pos 681 frame 4.35 -> ...                   <- +0.45 for 2 px
//
// So the walk cycle is driven **on this side, from movement** (see the frame block below), and the
// **idle** is driven by the peer's own idle sprite - which is the owner's request in M5k: the head
// and backpack bob while standing still. See `global.coopIdleSprite`.
//
// **Two clocks, one for each state, and neither is the peer's index** (M5k).
//
// **Walking:** the frame follows the ground the puppet's own body covers, at the measured 12.2 px
// per index-unit (the probe's clean walking samples: 33/2.70, 76/5.85, 75/5.85 = 12.2, 13.0,
// 12.8). Six units a cycle, the sprite's own length. Standing still does not advance it.
//
// **Standing:** the frame is **held**, because the body has no idle animation in this build (the
// `...Idle` names are cosmetic overlays - live, 2026-10-22; see the sprite block above). If a real
// idle **body** ever resolves (`_idle_anim`), its bob is played at the **game's own animation
// rate**, which is the honest reading of "pick up its speed":
//
//   * `sprite_get_speed` is **useless** for it - every player sprite reports `speed 0`, and in
//     GameMaker `0` means "use the room's default", not "not animated". The first version of this
//     code treated that 0 as a real rate, fell back to a made-up 0.006 units/ms, and the owner saw a
//     **1.0 s** cycle against the player's 0.67 s - "the bob is there but **twice as slow**".
//   * The rate that *is* real is the one the peer's wire already carries: `coopPeerStepRate`, the
//     index's rise measured between two packets. That index is the game's **animation clock** - the
//     free-running timer M5j caught and stopped calling a walk - so its rate is the rate the game
//     plays an animation. Live it is **+0.45 per packet at 20/s = 9 units/s**, a six-frame cycle in
//     **0.67 s**, and it holds while the player stands still.
if (_walking) {
    var _ppu = 12.2;                  // px per index-unit, from the idx probe's walking samples
    global.coopPeerFrameF += global.coopPeerSpeed * _dt / _ppu;
    var _cyc = global.coopStepMax + 1;
    if (global.coopPeerFrameF >= _cyc) global.coopPeerFrameF = global.coopPeerFrameF mod _cyc;
    if (global.coopPeerFrameF < 0) global.coopPeerFrameF = 0;
} else if (_idle_anim) {
    // A real idle body: play its bob at the measured animation rate.
    var _idle_n = _spr > 0 ? sprite_get_number(_spr) : 1;
    if (_idle_n < 1) _idle_n = 1;
    var _idle_units = global.coopPeerStepRate;      // units per millisecond
    if (_idle_units <= 0.0005) _idle_units = 0.009; // 9 units/s: the live idle/walk index rate
    global.coopIdleFrameF += _idle_units * _dt;
    if (global.coopIdleFrameF >= _idle_n) global.coopIdleFrameF = global.coopIdleFrameF mod _idle_n;
    if (global.coopIdleFrameF < 0) global.coopIdleFrameF = 0;
} else {
    // No idle body to animate: settle the walk frame back to its standing pose and hold it.
    global.coopIdleFrameF = 0;
}
var _frame;
if (_walking) {
    _frame = floor(global.coopPeerFrameF);
    if (_frame < 0) _frame = 0;
} else {
    _frame = floor(global.coopIdleFrameF);
    if (_frame < 0) _frame = 0;
}
// **The cycle's length is the sprite's own frame count**, not a constant (M5j). `coopStepMax` is
// the last frame index, and it was a hard-coded 5 from the wire's six-unit cycle - but a frame
// past the end of a sprite draws **nothing**, so a sprite with fewer frames would make the puppet
// vanish for part of every cycle. Where the sprite is known, its own count decides; the constant
// is the fallback for a sprite that cannot be asked about.
var _last = global.coopStepMax;
if (_spr > 0) {
    var _nf = sprite_get_number(_spr);
    if (_nf > 0) _last = _nf - 1;
}
if (_frame > _last) _frame = _last;

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
// "nothing is drawn any more". The flag is read once at the top of the handler now, so the
// frame, the sprite choice and the dust all share the one read.
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
