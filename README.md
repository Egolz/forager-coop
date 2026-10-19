# Forager Co-op

An unofficial co-op mod for [Forager](https://store.steampowered.com/app/751780/Forager/)
(Steam, 2019, GameMaker Studio 2). Two players, one shared world, no port forwarding
(Steam relay planned for release).

Built with the game's own modding API — no BepInEx, no `data.win` editing, no external
toolchain. The mod is a folder of `.gml` files that Forager compiles itself.

## Status: early prototype — read this first

| | |
|---|---|
| Milestone | **M1 of M5** — networking + presence |
| What works | Host/join over TCP, a version-checked handshake, ping/pong, and you can see your friend's marker in the world |
| What does **not** work yet | **The world is not synced.** Terrain, resources, items, structures and quests are independent per player. You will desync immediately if you both play normally. |
| Tested on | Forager, Steam build **6160665** (Windows) |

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
| **F8** | Print connection status (peer, ping, peer position) |
| **t** | Toggle the console |

Host first (F5), then the other player joins (F6 → the host's IP). On one network that is
the host's LAN address; over the internet it needs the host's public address **and** a port
forward for TCP 6511 — there is no NAT traversal yet. The Steam relay backend (which
removes port forwarding) is milestone M4.

Firewall: Windows asks once whether to allow Forager on the network. If you miss the prompt,
the join will just time out.

## Known issues

- **No world sync** (M2–M3): see the status table above. This is the point of the project
  and it is not done.
- The remote player is drawn as a **marker**, not the real sprite puppet.
- Exactly **2 players**; no more.
- No NAT traversal, no Steam friends list, no host migration.
- Forager refuses to run **two instances on one PC**, so testing needs two machines (or a
  second Windows session/VM).
- Mods other than this one are not handled: if you and your friend run different mods, the
  world will not match. A version check exists but no mod-list check yet.

## Development

```
Main.gml            entry point: globals, the packet enum, version
Net.gml             sockets, handshake, ping/pong, presence, packet dispatch
Events/OnStep.gml   hotkeys, heartbeats, presence cadence
Events/OnNetworkAsync.gml   GameMaker async connect/disconnect/data callbacks
Events/OnDrawEnd.gml        remote player marker
tools/deploy.ps1            copy the mod into the game's mods folder
tools/coop_mockpeer.py      a non-GameMaker peer for testing the protocol
docs/PROTOCOL.md            packet format + GameMaker's socket handshake
```

There is no build step: edit the files, run `tools/deploy.ps1`, then **COMPILE** in the
game's modding menu. Since two Forager instances cannot run on one PC, the protocol is
tested against `tools/coop_mockpeer.py`, which speaks both GameMaker's socket handshake
and this mod's packets:

```powershell
# game is hosting (F5 in game), then:
python tools/coop_mockpeer.py client
# or, to act as the host and have the game join:
python tools/coop_mockpeer.py server
```

`docs/PROTOCOL.md` explains GameMaker's own `GM:Studio-Connect` handshake and
`0xDEADC0DE` packet framing — anyone writing a peer, relay or proxy in another language
has to implement both.

## License

GPL-3.0 — see `LICENSE`. Forager and its assets belong to HopFrog; this repository
contains no game code, assets or other game files.
