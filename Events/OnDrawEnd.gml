#define OnDrawEnd
// Forager Co-op - draws a marker where the remote player is (M1, placeholder
// for the real puppet instance that M2 will spawn with ModObjectSpawn).

if (!global.coopPeerAlive || !global.coopPeer.seen) exit;
if (!instance_exists(objPlayer)) exit;
if (objPlayer.room != global.coopPeer.room) exit;

var _x = global.coopPeer.x;
var _y = global.coopPeer.y - 30;

draw_set_alpha(0.85);
draw_circle_color(_x, _y, 9, c_aqua, c_blue, false);
draw_set_alpha(1);
draw_set_colour(c_white);
draw_set_halign(fa_center);
draw_text(_x, _y - 22, "peer " + string(global.coopPingMs) + "ms");
draw_set_halign(fa_left);
