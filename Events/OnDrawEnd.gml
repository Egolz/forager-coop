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

// M5k5: count **every** draw, including the ones that exit below for their own reasons, because the
// question is how often the handler runs at all. `coopDrawCount`/`coopDrawMsSum` are printed by the
// idx probe and reset there. The sums use the *previous* draw's `_dt` (`coopLastDt`), because this
// block runs before the exits and `_dt` is computed after them.
global.coopDrawCount += 1;
global.coopDrawMsSum += global.coopLastDt;
global.coopOuterTicks += 1;   // M5k7b: every entry into the handler, before any exit
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
//   * **walking** -> `global.coopWalkSprite` (`sprPlayerWalk`, id 1, six frames);
//   * **standing** -> the **idle body**, `sprPlayerIdle`, which is **asset id 0** - and this was the
//     round's whole trap. `asset_get_index("sprPlayerIdle")` answers **0** for "not found" *and* 0
//     is `sprPlayerIdle`'s own index, so every `> 0` test in this codebase skipped it and the body
//     fell through to the walk sprite. The `...Idle` names that *do* resolve by name
//     (`sprPlayerGlassesIdle` id 2, `sprPinkBowIdle` id 4) are **cosmetics overlays**: drawing one
//     as the body is the owner's "I only see the glasses, the name, and the tree".
var _idle_body = -1;              // the idle body sprite index; **0 is valid** (sprPlayerIdle)
if (!_walking) {
    CoopResolveIdleSprite();
    if (global.coopIdleSprite >= 0) _idle_body = global.coopIdleSprite;
}

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
        // The idle body. **Not `_fallback = _idle_body; if (_fallback <= 0) ...`** - that pattern
        // would throw sprite 0 away, which is the bug this round is about. The `>= 0` test above
        // already decided, and 0 is drawn like any other sprite.
        _fallback = _idle_body;
    }
    if (_walking && _fallback <= 0) {
        CoopResolveBodySprite();
        _fallback = global.coopBodySprite;
    }
    _spr = _fallback;
}
// Is the body being **animated** while standing? Yes, whenever there is an idle body - and there
// is: sprite 0, six frames, which the game itself plays at `image_speed 0.60` (live).
var _idle_anim = (!_walking && _idle_body >= 0);

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
// **M5k7: keep the UNCLAMPED gap, because `_dt` alone cannot say which clock is wrong.** The
// measurement says the idle branch runs **290x/s** while the sum of its `_dt` is **22750 ms over
// 4094 ms** - a sum *larger* than wall-clock time, which is impossible if `_dt` is real milliseconds
// and the handler is called 290 times a second (that would need ~19 ms between calls, i.e. 52/s). The
// two numbers cannot both be right, so both raw inputs are recorded here: `current_time` at this draw
// and at the previous one, plus the running minimum and maximum gap seen. A `min` of 0 with 290 calls
// a second would mean `current_time` only ticks once per *frame* while the handler is called per
// *view* or per *room*, and the same millisecond is being counted many times.
global.coopDtRawSum += _now - global.coopDrawAt;   // before clamping, and before the first-call guard
global.coopDtRawLast = _now;
global.coopDrawAt = _now;
if (_dt < 1) _dt = 1;
// **M5k5: the 100 ms ceiling was capping the *whole animation* at a tenth speed.**
//
// The owner asked for a bob every 0.5 s and got one every **5 s** - a factor of ten, which is not a
// tuning error. This clamp is where a factor of ten comes from: it was added to stop a one-off spike
// at world load throwing the puppet forward, and it silently does the same thing to a handler that is
// called **rarely**. `OnDrawEnd` for a peer standing in the same room is not called at 60 Hz here; the
// wire shows a probe every 180 steps arriving about every 13 s (~14 steps/s), and if a draw arrives
// every ~1000 ms, this line turns each of those seconds into 100 ms - the animation clock then runs at
// **a tenth** of wall-clock speed, and a 0.5 s bob takes 5 s. The comment above even names the cause
// in passing ("the roll froze mid-turn" - it froze because the same clamp was eating its time).
//
// The clamp's *intent* - do not let one long frame fling the puppet - is kept, in the one place such a
// spike can actually happen: a first draw after a pause has no previous timestamp to trust, and that
// case is already `global.coopDrawAt <= 0` above. A long frame mid-session is real elapsed time.
// Raising the ceiling to 1000 ms leaves the load spike clamped (its gap is seconds, not one second)
// while letting an ordinary slow draw carry its true duration.
if (_dt > 1000) _dt = 1000;
global.coopLastDt = _dt;   // M5k5: the top-of-handler counter reads the *previous* draw's dt

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
var _prevDrawX = global.coopDrawX;   // M5k9: the position BEFORE this frame's move, so the walk
var _prevDrawY = global.coopDrawY;   // animation can be driven by the distance actually travelled
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
// **idle** is the peer's own idle body sprite, `sprPlayerIdle`.
//
// **Two clocks, one for each state** (M5k, corrected 2026-10-22).
//
// **Walking:** the frame follows the ground the puppet's own body covers, at the measured 12.2 px
// per index-unit (the probe's clean walking samples: 33/2.70, 76/5.85, 75/5.85 = 12.2, 13.0,
// 12.8). Six units a cycle, the sprite's own length. Standing still does not advance it.
//
// **Standing: the idle body is `sprPlayerIdle`, asset id 0** (live: `sprite_get_name(0)` is
// `'sprPlayerIdle'`, and `objPlayer sprite_index -> 0`). This is the bob the owner asked for, and
// the whole previous round was spent concluding the opposite from a `> 0` test that cannot see id 0.
//
// **The bob's rate, and the 4x that was settled the WRONG way last round.** Two numbers disagree:
//
//   * `objPlayer.image_speed` is **0.60** (live) - the instance's own per-step speed.
//   * The index on the wire climbs **+0.45 per POS packet**, and a POS packet is sent every **3
//     steps** (`OnStep`: `coopTick mod 3`), so that is **+0.15 per step**.
//
// Four times apart. The previous round claimed `image_speed` was "the rate the model is drawn at, so
// the eye sees it" and used 0.60/step = **0.036 units/ms - a 0.17 s cycle**. The owner's report is
// the verdict on that reasoning:
//
//     "Now the mock bobs its head too FAST."
//
// So `image_speed 0.60` is **not** what the eye sees, and the inference behind it was wrong: a
// GameMaker instance can carry an `image_speed` that does not match the counter its sprite is
// actually stepped by, and this build's `sprite_get_speed` is 0 for every player sprite anyway (see
// below) - the two ways of asking for "the drawn speed" both failed to describe the drawing. The
// number that **does** describe what moves on screen is the one measured directly: the index climbs
// **+0.15 a step**, and that is **0.009 units/ms - a 0.67 s six-frame cycle**.
//
// That is the same rate the round before last used. The two rounds are not in conflict: **both fixes
// were needed at once** - sprite 0 has to be **drawn** (the `>= 0` change, which is what stopped the
// stand-still body vanishing) **and** the clock has to run at the measured index rate. Each round
// applied one and concluded the other from a single, correct, incomplete observation.
//
// **The bob's period is 0.5 s, and it is set from the owner's own measurement.**
//
// The history is a calibration, not a guess: 0.17 s per cycle read as *"too fast"*, 0.67 s read as
// *"too slow"*, and the owner's measured numbers - 6/s then, 1.5/s then - bracket the truth. Asked
// directly for the player's own model, the answer is **~2 bobs a second**, i.e. a **0.5 s cycle**.
//
// That number is also what the arithmetic was missing. A "bob" is a **whole cycle**, not one frame,
// and the two rates that were tried were both read as if a cycle were six frames: `image_speed 0.60`
// is 36 frames/s, and 36 fps / 2 cycles/s = **18 frames per cycle** - so the bob does **not** run on
// the six-frame `image_index` at all, which is consistent with the other live fact, that the index
// **stops dead** while the player stands (`imgidx 4.20` five probes in a row). The puppet's clock is
// therefore set directly from the period the owner can actually see, rather than from a counter that
// stops when it matters.
//
// `coopPeerStepRate` belongs to the **step** now: the idle branch below no longer advances anything,
// so this handler has no rate to resolve at all. `_COOP_IDLE_PERIOD_S` is still named here only for
// the walk branch's arithmetic below, and the single decision about the idle rate lives in
// `CoopIdleUnits()` (Net.gml), called by `OnStep` - see the M5k8b note there for why one place was
// not enough and two were.
var _COOP_IDLE_PERIOD_S = global.coopIdlePeriodS;   // one whole bob, in seconds (M5k6: a global now)
// **M5k9: the walk animation is driven by the DISTANCE the puppet actually moved, not by a clock.**
//
// The idle bob had to be rescued from `current_time` because that clock is off by **14.89x** in this
// event (the handler runs ~505x/s, `current_time` ticks ~15 ms). The walk was left on the same clock
// only because walking had been *reported* working - and the owner's report was
// *"the mock animates movement slowly and freezes"*, which is the same symptom the bob had.
//
// Rather than swap one clock for another, the walk needs **no clock at all**: legs should turn with
// the ground covered, not with wall time. That is the same principle M5j already applied to *when*
// the puppet walks (movement-driven, not packet-driven) - it was simply never applied to *how fast
// the legs move*. The distance this frame is exactly the distance the position block above just
// moved the puppet, so the animation cannot drift from the motion, at any frame rate, and a stalled
// or duplicated draw carries no time and therefore cannot distort it.
var _moved_px = point_distance(_prevDrawX, _prevDrawY, global.coopDrawX, global.coopDrawY);
if (_walking) {
    global.coopWalkTicks += 1;                     // M5k7: how many draws take the WALK branch
    // 12.2 px per index-unit, from the idx probe's clean walking samples (33/2.70, 76/5.85, 75/5.85).
    var _ppu = 12.2;
    var _walk_units = _moved_px / _ppu;
    global.coopPeerFrameF += _walk_units;
    global.coopWalkUnitsAdded += _walk_units;      // M5k9: the probe checks distance -> frames
    global.coopWalkPxAdded     += _moved_px;
    var _cyc = global.coopStepMax + 1;
    if (global.coopPeerFrameF >= _cyc) global.coopPeerFrameF = global.coopPeerFrameF mod _cyc;
    if (global.coopPeerFrameF < 0) global.coopPeerFrameF = 0;
} else if (_idle_anim) {
    // **M5k8: the idle frame is no longer advanced here - OnStep does it now.** The audit read
    // `outer 505.70/s, enter 122.70/s, raw gap sum 61377 ms over 4121 ms (14.89x)`, i.e. the draw
    // handler runs ~505x/s while `current_time` ticks ~15 ms, so seven calls in eight see the same
    // millisecond and a millisecond-based rate is meaningless in this event. The step is the one
    // clock that agrees with itself (`dt 17.97` at ~44-58 steps/s, every probe), so the bob is
    // advanced in `OnStep` and this branch only **picks the frame** to draw.
    //
    // Nothing is done here on purpose - the branch is kept (rather than folded into `else`) so that
    // the walk/idle/dead split stays visible, and so the next reader can see the frame is *read*
    // here, not written.
    global.coopIdleDraws += 1;
} else {
    global.coopDeadTicks += 1;                     // M5k7: draws with NO idle body (neither branch)
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
if (_spr >= 0) {
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
if (_spr >= 0) {
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
// **`>= 0`, not `> 0`.** This is the line the whole round turns on: the idle body is
// `sprPlayerIdle`, **asset id 0**, so `> 0` here would draw *nothing* while the peer stood still -
// which is exactly what the owner reported after the previous round ("the mock stopped using the
// bob while standing"). `sprite_exists` was true for id 0 and the name at 0 is `'sprPlayerIdle'`
// (both live, 2026-10-22), so sprite 0 is a real sprite in this build and draws like any other.
if (_spr >= 0) {
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
