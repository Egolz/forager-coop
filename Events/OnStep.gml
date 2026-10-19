#define OnStep
// Forager Co-op - per-frame pump: hotkeys, heartbeats, presence.
// World sync only reacts to events (OnStructureSpawn) and to packets; nothing
// heavy is scanned here.

if (keyboard_check_pressed(vk_f5)) CoopHost();
if (keyboard_check_pressed(vk_f6)) CoopJoin();
if (keyboard_check_pressed(vk_f7)) CoopDisconnect("requested");
if (keyboard_check_pressed(vk_f8)) CoopStatus();
if (keyboard_check_pressed(vk_f9)) CoopDumpStructures();
if (keyboard_check_pressed(vk_f10)) CoopProbeWorld();
if (keyboard_check_pressed(vk_f11)) CoopProbeApi();
if (keyboard_check_pressed(vk_f12)) CoopProbeSpot();

if (!global.coopPeerAlive) exit;

global.coopTick += 1;

// heartbeat: keep at most one ping in flight
if (global.coopTick mod 90 == 0 && global.coopPingSentAt < 0) {
    CoopSendPing();
}
// a ping that never comes back means the peer is gone
if (global.coopPingSentAt >= 0 && current_time - global.coopPingSentAt > 5000) {
    Trace("Co-op: ping timeout - peer looks gone.");
    global.coopPingSentAt = -1;
    global.coopPeerAlive  = false;
}

// presence: ~20 packets/second, cosmetic and latency-sensitive
if (global.coopTick mod 3 == 0) CoopSendPos();
