# Forager Co-op

An unofficial co-op mod for [Forager](https://store.steampowered.com/app/751780/Forager/)
(Steam, 2019, GameMaker Studio 2). Two players, one shared world, no port forwarding
(Steam relay planned for release).

Built with the game's own modding API — no BepInEx, no `data.win` editing, no external
toolchain. The mod is a folder of `.gml` files that Forager compiles itself.

## Status: early prototype — read this first

| | | 
|---|---|
| Milestone | **M2.1 of M5** — networking, presence and *structure placement* |
| What works | Host/join over TCP, a version-checked handshake, ping/pong, and you can see your friend's marker in the world. Structure placement is implemented host-authoritatively (the client asks, the host decides and broadcasts) — **awaiting its first live test**, see below. |
| What does **not** work yet | **The world is still not synced.** Terrain, resources, items, mobs and quests are independent per player, and there is no world snapshot on join, so the two players must already be looking at the same world for structure sync to mean anything. |
| Tested on | Forager, Steam build **6160665** (Windows) |

The protocol layer itself (framing, encoding, both directions) does have an automated
check you can run without the game: `python tools/coop_mockpeer.py selftest`.

This mod exists because the previous community mod, PencilPal, is gone from the Workshop
and was reported to crash constantly. The write-up and the design live in the
[coop-anything](https://github.com/cranebeaker/coop-anything/tree/main/games/forager) hub.

Not affiliated with HopFrog or YoYo Games. Official Forager multiplayer was cancelled in
2021.

## Install

1. Install Forager and run it once.
2. Copy this folder into `%LOCALAPPDATA%\Forager\mods\` and rename it `Forager Coop`:
   ```
   %LOCALAPPDATA%\Forager\mods\Forager Coop\
       fmConfig.json
       Main.gml
       Net.gml
       Events\...
   ```
   `tools\deploy.ps1` does this for you from a git checkout.
3. In the game: main menu → **modding** → find `Forager Co-op` in the list → **enable** it
   → **COMPILE**. The game restarts its scripts and prints `Forager Co-op ... loaded` to
   the console.
4. Press **`t`** any time to open the in-game console and see the mod's messages.

The mod's folder name does not matter, but keep it stable: the game stores the enabled
mods by path in `%LOCALAPPDATA%\Forager\mods\settings.json`.

## Play

Both players need a copy of the game, this mod installed and enabled.

| Key | Action |
|---|---|
| **F5** | Host — starts listening on TCP **6511** |
| **F6** | Join — asks for the host's IP address |
| **F7** | Disconnect / stop hosting |
| **F8** | Print connection status (peer, ping, peer position, world sequence) |
| **F9** | Print the whole structure database (id, name, object, is it a structure) |
| **F10** | Probe the world: the game's own structure instances next to ours (see below) |
| **t** | Toggle the console |

**F10, the probe**, is read-only. It prints the room's player, the game's own parent object
for buildings (`parStructure`) with every instance of it, then every instance of the object
our structure table names - with `depth`, `image_index` and `visible`, the fields that decide
whether a player would see it. The long part (all 64 table entries) is not printed: the mod
forwards it to the connected peer over the protocol and `tools/coop_mockpeer.py` writes it to
`%TEMP%\coop_debug.txt`. It has to go over the wire because a mod in this game **cannot write
a file**: `ini_open` is not in the loader's function table, and `file_text_*`, `buffer_save`
and `show_debug_message` are not in the build at all.

Host first (F5), then the other player joins (F6 → the host's IP). On one network that is
the host's LAN address; over the internet it needs the host's public address **and** a port
forward for TCP 6511 — there is no NAT traversal yet. The Steam relay backend (which
removes port forwarding) is milestone M4.

Firewall: Windows asks once whether to allow Forager on the network. If you miss the prompt,
the join will just time out.

## Known issues

- **No world sync** (M2–M3): see the status table above. This is the point of the project
  and it is not done. Structure *placement* syncs; nothing else does, and there is no world
  snapshot on join, so it is only meaningful if both players are already in the same world.
- Structure *removal* is not synced yet.
- If the host refuses a placement, the client rolls it back but does **not** get the
  resources back (inventories are not synced yet).
- A client can only place while the host is in the world too; if the host is in a menu the
  placement is refused.
- The remote player is drawn as a **marker**, not the real sprite puppet.
- Exactly **2 players**; no more.
- No NAT traversal, no Steam friends list, no host migration.
- Forager refuses to run **two instances on one PC**, so testing needs two machines (or a
  second Windows session/VM).
- Mods other than this one are not handled: if you and your friend run different mods, the
  world will not match. A version check exists and the structure databases are compared, but
  there is no mod-list check yet.

## Development

```
Main.gml            entry point: globals, the packet enum, version
Net.gml             sockets, handshake, ping/pong, presence, packet dispatch,
                    the structure database cache and the M2 sync helpers
Events/OnStep.gml   hotkeys, heartbeats, presence cadence
Events/OnNetworkAsync.gml   GameMaker async connect/disconnect/data callbacks
Events/OnDrawEnd.gml        remote player marker
Events/OnStructureSpawn.gml the host-authoritative placement hook
tools/deploy.ps1            copy the mod into the game's mods folder
tools/check_gml.py          offline sanity check: brackets, duplicate vars, macro
                            arity, value macros, and every call checked against the
                            game build's symbol table (data.win)
tools/coop_mockpeer.py      a non-GameMaker peer for testing the protocol
tools/mock_e2e.ps1          offline end-to-end test of that peer: mock server <->
                            mock client, asserts the whole session (handshake,
                            welcome, pong, structure table, INTENT_PLACE).
                            No game needed - this is what caught the two bugs in
                            the mock itself.
docs/PROTOCOL.md            packet format + GameMaker's socket handshake
```

There is no build step: edit the files, run `tools/deploy.ps1`, then **COMPILE** in the
game's modding menu.

**Run the checker before every deploy.** A mod that fails to compile does not announce
itself in-game: no error on screen, its events simply never run. Three ways this bit us
already, all now caught offline:

- **No value macros.** `#define PLACE_RANGE 448` is rejected by this loader
  (`Expected a statement, got number`) and takes the whole mod down. A macro body must be
  statements; use a global for a constant.
- **Not every GML builtin exists here.** `array_delete()` and `variable_instance_exists()`
  are absent from this build's symbol table. The checker looks every function you call up
  in `data.win`, so pass `--data-win` (or set `FORAGER_DATA_WIN`) and it will tell you.
- **`try`/`catch` cannot be compiled at all** — it crashes the game on COMPILE, and again on
  every later launch. The game's `%LOCALAPPDATA%\Forager\error.log` is the only place that
  says so:

  ```
  Can't seekAllOut over Forager Coop/Net.gml[L150,c1] try_catch
  ```

  Guard with an `if` instead. (This is also why the big PencilPal mod currently cannot be
  recompiled: it uses try/catch throughout.) When a mod does nothing, or the game dies on
  COMPILE, **read `error.log` first** — it gives a file and line for mod code.

```powershell
python tools/check_gml.py              # uses the default Steam path
python tools/check_gml.py --data-win "D:\Games\Forager\data.win"
```

Since two Forager instances cannot run on one PC, the protocol is tested against
`tools/coop_mockpeer.py`, which speaks both GameMaker's socket handshake and this mod's
packets:

```powershell
python tools/coop_mockpeer.py selftest          # offline: packet codec, no game needed

# the game is HOSTING (F5 in game), then:
python tools/coop_mockpeer.py client            # connect, talk, echo presence
python tools/coop_mockpeer.py client --place forge
                                                # ...and ask the host to build a forge
python tools/coop_mockpeer.py client --no-place # presence only

# or, to act as the host and have the game join:
python tools/coop_mockpeer.py server
```

`docs/PROTOCOL.md` explains GameMaker's own `GM:Studio-Connect` handshake and
`0xDEADC0DE` packet framing — anyone writing a peer, relay or proxy in another language
has to implement both.

## License

GPL-3.0 — see `LICENSE`. Forager and its assets belong to HopFrog; this repository
contains no game code, assets or other game files.
