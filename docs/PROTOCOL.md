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

Notes:

- **Version check.** The host refuses a peer whose `protocol` differs (it replies `REJECT`
  and drops the socket). Protocol `1`, mod version `0.0.2-m1` at the time of writing.
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

The host-authoritative world sync (M2) adds, on top of this:

- `INTENT` (client → host): a requested mutation, with a client-local `intentId`.
- `MUTATION` (host → client): a confirmed mutation with a monotonically increasing `seq`
  and the `intentId` it answers. Clients apply them in `seq` order and ignore replays.
- `SNAPSHOT` (host → client, chunked): world state on join/resync, chunks with checksums.

Until then the mod is presence-only — do not expect the world to match between players.
