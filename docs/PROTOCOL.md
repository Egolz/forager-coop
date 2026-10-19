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
| 1 | `HELLO` | client → host | `u8 protocol`, `string modVersion` |
| 2 | `WELCOME` | host → client | `u8 protocol`, `string modVersion` |
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

Notes:

- A structure travels as its **name** (`"forge"`), never as an object index: names are
  build-independent and readable in a log. The receiver resolves the name against its own
  structure database (`StructureGet(id, StructureData.Name)` / `StructureData.Object`).
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

Notes:

- **Version check.** The host refuses a peer whose `protocol` differs (it replies `REJECT`
  and drops the socket). Protocol `2`, mod version `0.0.3-m2a` at the time of writing.
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

- `SNAPSHOT` (host → client, chunked, with checksums): world state on join and resync.
  Without it the two players start from whatever each one loaded, so M2.1 is only correct
  when both are looking at the same world.
- Terrain (tile break/place) and resource pickups: no event exists for the former, so the
  host has to detect changes itself.
- Item counts and inventory deltas.
- Any replication of *removal*: destroying a structure is not synced yet, and so
  `OnStructureDestroy` is unused by the mod.

Until then the mod is presence plus structure placement only — do not expect the world to
match between players.
