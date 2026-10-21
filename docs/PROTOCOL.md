# Protocol

Two layers: **GameMaker's socket protocol** (imposed by the engine, you cannot skip it)
and **this mod's packets** (ours).

## 1. GameMaker's TCP socket protocol

Forager's mod API gives you `network_create_server` / `network_connect`, i.e. the *framed*
GameMaker sockets — not the `*_raw` variants. So every byte on the wire looks like this.

Handshake, right after the TCP connection is established:

| # | Direction | Bytes |
|---|---|---|
| 1 | server → client | ASCII `GM:Studio-Connect\0` (18 bytes) |
| 2 | client → server | `u32 0xCAFEBABE`, `u32 0xDEADB00B`, `u32 16` (little-endian) |
| 3 | server → client | `u32 0xDEAFBEAD`, `u32 0xF00DBEEB`, `u32 12` |

Then, per packet, in both directions:

```
u32 0xDEADC0DE     magic
u32 12             header size
u32 payloadLen
payloadLen bytes
```

All integers are little-endian. The constants come from YoYo Games' own implementation,
[`GameMaker-HTML5/scripts/functions/Function_Networking.js`](https://github.com/YoYoGames/GameMaker-HTML5/blob/develop/scripts/functions/Function_Networking.js)
(`YYHANDSHAKE_SV0`, `_CL1`, `_CL2`, `_SV1`, `_SV2`, `_PRE`), and were confirmed by dumping
the bytes of a running Forager (the banner, then the step-3 signatures after our reply).

Consequences:

- A GameMaker↔GameMaker session gets all of this for free — the engine does it.
- Any other peer (a Python test script, a relay, a proxy that reinjects packets) **must**
  speak this handshake and this framing itself. `tools/coop_mockpeer.py` is a reference
  implementation in ~60 lines.
- If you see `GM:Studio-Connect` in a capture, that is the engine, not this mod.

## 2. The mod's packets

Every payload starts with one `u8` command id. All integers little-endian. GameMaker's
`buffer_string` is UTF-8 followed by a NUL byte.

| id | Name | Direction | Payload |
|---|---|---|---|
| 1 | `HELLO` | client → host | `u8 protocol`, `string modVersion`, `string name` |
| 2 | `WELCOME` | host → client | `u8 protocol`, `string modVersion`, `string name` |
| 3 | `REJECT` | host → client | `string reason` |
| 4 | `PING` | either | `u32 nonce` |
| 5 | `PONG` | either | `u32 nonce` |
| 6 | `POS` | either | `s32 x`, `s32 y`, `u16 angle`, `s8 facing`, `s32 sprite`, `u8 image`, `u8 room` |
| 7 | `BYE` | either | `string reason` |

### World sync (M2)

The host owns the world. A client never writes to it: it asks, and the host answers
with a confirmed mutation. See the model in the hub's `games/forager/DESIGN.md`.

| id | Name | Direction | Payload |
|---|---|---|---|
| 8 | `INTENT_PLACE` | client → host | `u32 intentId`, `u8 room`, `s32 x`, `s32 y`, `string structureName` |
| 9 | `MUTATION_PLACE` | host → client | `u32 seq`, `u32 intentId`, `u8 room`, `s32 x`, `s32 y`, `s32 depth`, `string structureName` |
| 10 | `INTENT_REJECTED` | host → client | `u32 intentId`, `string reason` |
| 11 | `STRUCTURE_TABLE` | host → client | `u16 count`, `{ u16 id, string name } × count` |
| 12 | `DEBUG_LINE` | either way | `string text` |
| 13 | `ITEM_TABLE` | host → client | `u16 count`, `{ u16 id, string name } × count` |
| 14 | `DROP` | either way | `u8 room`, `s32 x`, `s32 y`, `u16 item`, `u16 stack` |
| 15 | `PICKUP` | either way | `u8 room`, `s32 x`, `s32 y`, `u16 item` |
| 16 | `RESOURCE_DESTROY` | either way | `u8 room`, `s32 x`, `s32 y`, `u16 objectIndex` |
| 17 | `SNAP_LAND` | host → client | `u8 room`, `u8 gen`, `u8 flags`, `u16 count`, `{ u16 x, u16 y } × count` |
| 18 | `SNAP_STRUCT` | host → client | `u8 room`, `u8 gen`, `u8 flags`, `u16 count`, `{ u16 x, u16 y, u16 structureId } × count` |

### The world snapshot (M3.1)

`SNAP_LAND` carries the world's **land**: the cells that are ground rather than water. It is
the first half of the snapshot, and the half that makes the two worlds the same world —
until the client has the host's land, every spot the host builds on may be water on the
client's side, which is why the client had to move a structure to a free cell and why the
two sides could never agree on where a building stands.

| field | meaning |
|---|---|
| `room` | the room the land belongs to (`objPlayer.room`; room 8 is the main world) |
| `gen` | the snapshot's **generation**. A chunk whose generation differs from the one the client has starts a new snapshot, and the client clears its picture of the host's land before the new cells go in |
| `flags` | bit 0 = "the client should also **remove** the land it has and the host does not". It is what makes the client's island *become* the host's island instead of the two growing into each other. A peer without a world must not set it — a fake land set would take the island away for good, and the flag is the only thing standing between that and a broken save |
| `count` | how many cells follow. **A chunk with `count` 0 is the end of the snapshot**, and the client runs its clean-up pass when it sees it |
| `x`, `y` | the cell's **centre**, on the world's 16 px lattice (8, 24, … 1336). The grid is 84 × 84 = 7056 cells, and the world is 1344 px across |

The cells go out in chunks of at most 512 (a 2 KB packet) because a packet per cell is what
made the reference mod's land sync "very slow on big worlds" — its own TODO. The reference
implementation (PencilPal, the one mod known to run in this build) walks the same grid and
sends one `LAND` packet per cell; the two function names this packet needs,
`PlaceLandfill(x, y)` and `RemoveLandfill(x, y)`, are the game's own, and they are called in
the same `with(objPlayer)` context the reference mod uses, because that is the context the
game's function expects.

The client's side of the apply: a cell the host has and the client has not becomes land; a
cell the client has and the host does not is removed (only when the flag says so). The
snapshot can take the ground out from under the player, so the player is put back on the
nearest land afterwards.

### The structures (M3.2)

`SNAP_STRUCT` carries the **buildings** — the second half of the snapshot. The land is only
the ground; the client also needs what stands on it.

| field | meaning |
|---|---|
| `structureId` | the row of the structure in the game's **structure database**, not its name. The names in that database are localized display strings (`"печь"`, `"швейная\nмастерская"`), so a name is not a key; the rows are the same build, which is what the structure table checks |
| `x`, `y` | the position. A structure stands on the **corner** of a cell (`x mod 16 = 0`) |
| `flags` | bit 0 = "the client should also **remove** the buildings it has and the host does not" — the leftovers of the client's own island, which stand on ground that is now the host's. Same rule as the land's flag: only a host that has a world may set it |

**The world is watched, not queried.** There is no call in this build that answers "every
structure in the world": the structure database holds the **types** (92 rows), not the
instances. The only place that sees a structure *and* its database id at the same time is
`OnStructureSpawn(id, structure)`, so the mod keeps its own list as the world happens and
the snapshot sends that list. The list is filled **before every guard in that event**,
including "no peer" and "no player": the buildings that matter are the ones that were
already standing when the peer joined, and their event fired long before anybody connected.

The client's side of the apply is `CoopCreateStructure`, which **adopts** an instance that is
already standing there (this side's own optimistic placement of the same building) and
builds one when there is none — so the snapshot never doubles anything. The removal pass
compares by **cell**, not by id: a structure stands on a cell corner, so the cell is the
same on both sides, while the id is only as good as the two installs matching.

Packets 14-16 are M2.2 (resources and loot). The direction is "either way" because
either machine can be the one that saw the change; the **host** is the one that
applies it to its own world, and a client's copy is its own prediction. See the loot
note below.

**The field order in the table above is normative, and it is checked.**
`tools/check_gml.py` compares, for every packet, the `buffer_write` order in the sender
against the `buffer_read` order in its `case CoopCmd.*` and fails the build when they
differ. It was written because they did differ, in the three packets above: the table says
`u8 room, s32 x, s32 y, ...` and the readers of `DROP`, `PICKUP` and `RESOURCE_DESTROY` read
`s32 x, s32 y, u8 room, ...` for a whole evening of live testing (2026-10-20). Nothing in
GML complains about that - the buffers are untyped, a wrong read returns a wrong number -
and the room byte came back as `0`, so the room test failed first and **every incoming loot
and resource packet was silently discarded**. That is the whole effect of that bug: it is
*not* the cause of the native crash that was investigated the same evening, which is still
open (a wrong-order read shifts the item id too, but it survives the one-byte shift intact,
and `break` ran before the apply path). See `games/forager/NOTES.md` for the crash evidence
and for the phase marker that is meant to name it.

Notes:

- A structure travels as its **name** (`"forge"`). That is what the first slice shipped, and
  live it turned out to be wrong: the names in this game's structure database are
  **localized display strings** (`"печь"`, `"швейная\nмастерская"`), not stable ids, so the
  same structure is a different string in a different language. The key has to move to the
  structure **index** or its object index (what PencilPal syncs); the name stays for logs
  only. Fixing it is the next change to this slice - see `games/forager/NOTES.md`.
- `DEBUG_LINE` carries one line of the sender's console. It exists because a mod in this
  game **cannot write a file**: `ini_open` is not in the loader's function table (a live
  COMPILE fails with "`ini_open` is not function or script"), and `file_text_*`,
  `buffer_save` and `show_debug_message` are not in the build at all. So the mod forwards a
  long dump (F10) to the peer, and `tools/coop_mockpeer.py` writes it to
  `%TEMP%\coop_debug.txt`. It is diagnostics, not world state. The channel was write-only
  for most of a day: the sender existed and the packet switch had **no case for it**, so an
  incoming line fell through to "unknown packet id" and was lost. The wire-layout check in
  `tools/check_gml.py` caught it, because it also fails any packet that is written and never
  read.
- `intentId` is the client's own counter. It lets a client match a confirmation to the
  structure it placed optimistically, and a refusal to the thing it has to roll back.
- `seq` is monotonically increasing per host session. A client applies a mutation only if
  `seq` is greater than the last one it applied, so a duplicate is a no-op. A fresh peer
  resets the sequence at handshake.
- Who sends what: the host turns its own placements into mutations directly
  (`intentId` 0); a client turns its own placements into an intent, and the host validates
  (the structure must exist in the database, the reported room must be the host's room, and
  the spot must be within **448 px** of the client's last reported position) before it
  creates anything.
- `STRUCTURE_TABLE` goes out right after `WELCOME`. A GameMaker client does not need it —
  it has the same database locally — but it is also a divergence check (the mod compares
  the names and warns if the two installs disagree), and it is what lets a non-GML peer
  like `tools/coop_mockpeer.py` ask for a valid structure by name.
  The list is **pruned**: the database this build ships has 92 rows, but only the ones with
  a non-empty name go out. The rows without a name cannot be addressed on a name-keyed wire,
  and the build-menu **category headers** are rows too (`"для промышленности"`, object
  `objEmpty`) — an earlier 64-entry cap hid part of the table and the client's automatic
  choice landed on a header, so the host dutifully created an `objEmpty` and nothing
  appeared in the world (live, 2026-10-20). The mock now skips the headers when it picks.
- `ITEM_TABLE` (13) is the same shape and the same idea for M2.2: every loot packet will
  carry an **item id**, so the ids have to mean the same thing on both installs. A shifted
  database would turn "wood" into "stone" silently - this packet makes it loud instead.
  Unlike the structure table it is **not** pruned: an item row always has a name.
- **Loot and resources (14-16).** The three packets above are driven by the game's own
  events, whose signatures the docs do **not** list - they were read off PencilPal, the one
  mod known to run in this build: `OnItemDrop(d)` (an array of `{x, y, item, stack}`),
  `OnItemGet(items, size)` (an item **id** and a count, with no position), and
  `OnResourceDestroy(i)` (the instance being removed).
  - Items travel as **ids**, never names: F3 (live 2026-10-20) showed the item names are
    localized (`Item.Wood` reads back as `"Древесина"`), while `Item.Wood == 0`,
    `Item.Stone == 1`, `Item.Coin == 111` are build constants.
  - Resources travel as an **object index** for the same reason.
  - `PICKUP` carries no tile - the event does not have one - so the far end removes the
    nearest dropped item of that id within ~48 px of the position the picker reported.
  - This slice syncs the **world** only: an item that leaves the ground leaves it on both
    machines, but it lands in the picker's own inventory and no inventory totals move
    between players yet (that is M2.4).
- `MUTATION_PLACE.depth` is informational. Forager y-sorts the world: an instance sits at
  `depth = -y` (probe, 2026-10-20: the player at y=656 had depth -656, and so did a
  hand-built furnace). The host's `OnStructureSpawn()` fires *before* the game sets that
  depth, so the field went out as 0 for an instance that settled at -656. The receiver
  therefore recomputes the depth from `y` rather than trusting the field; it is carried for
  logs and for a future non-GML peer.

Notes:

- **Version check.** The host refuses a peer whose `protocol` differs (it replies `REJECT`
  and drops the socket). Protocol `6`, mod version `0.0.53-m3s` at the time of writing.
  (`6` adds `SNAP_LAND`, the world snapshot; `5` added the player name to `HELLO`/`WELCOME`;
  `4` added the M2.2 loot packets; `3` added `DEBUG_LINE`; `2` added the world-sync
  packets; `1` was presence only.) The number moves when
  the **wire format** moves, not when a feature is added: `5` grew a `string name` field into
  two packets, and a peer still speaking `4` would read that name as the tail of the version
  string and then read whatever followed it.
- **Ping/pong.** One ping in flight at a time, every 90 steps (≈1.5 s at 60 fps). A ping
  that is not answered within 5 s marks the peer as gone. `PONG` echoes the nonce back.
- **POS** is the one packet that is not host-authoritative: each player sends their own
  position and the receiver just draws it. It is cosmetic and latency-sensitive, so it goes
  out every 3 steps (≈20/s) rather than on the system-step cadence.
- **`room`** is `objPlayer.room` as a byte. Room **8** is the main world; other values are
  menus/UI rooms. A marker is only drawn when the peer's room matches yours.
- GameMaker buffer writes take reals, so integer fields go through `floor()` to avoid
  rounding surprises (`buffer_write` truncates, but be explicit).

## 3. Not implemented yet

Still missing from the world sync:

- `SNAPSHOT` (host → client, chunked, with checksums): the rest of the world state on join
  and resync. `SNAP_LAND` is the **land** half of it and landed first, because it is the half
  everything else stands on: the structures and the resources cannot be placed correctly
  until both sides agree on where the ground is.
- Terrain (tile break/place) and resource pickups: no event exists for the former, so the
  host has to detect changes itself.
- Item counts and inventory deltas.
- Any replication of *removal*: destroying a structure is not synced yet, and so
  `OnStructureDestroy` is unused by the mod.

Until then the mod is presence plus structure placement only — do not expect the world to
match between players.
