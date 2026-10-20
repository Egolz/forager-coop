#!/usr/bin/env python3
"""Mock peer for the Forager Co-op mod.

Lets us exercise the mod's protocol without launching a second copy of Forager
(which the game refuses to do). It speaks both the *GameMaker* socket
handshake/framing and the mod's own packets.

GameMaker's TCP socket protocol (constants from YoYoGames/GameMaker-HTML5,
scripts/functions/Function_Networking.js - the desktop runner behaves the same;
verified by watching this game's server send the step-1 banner):

    step 1  server -> client   "GM:Studio-Connect\\0"                (18 bytes)
    step 2  client -> server   u32 0xCAFEBABE, u32 0xDEADB00B, u32 16
    step 3  server -> client   u32 0xDEAFBEAD, u32 0xF00DBEEB, u32 12
    then    both ways, per packet:
                               u32 0xDEADC0DE, u32 12, u32 payloadLen, payload

Mod packets (little-endian; GameMaker buffer_string = UTF-8 + NUL):

    1  HELLO            u8 protocol, string version, string name
    2  WELCOME          u8 protocol, string version, string name
    3  REJECT           string reason
    4  PING             u32 nonce
    5  PONG             u32 nonce
    6  POS              s32 x, s32 y, u16 angle, s8 facing, s32 sprite, u8 image, u8 room
    7  BYE              string reason
    8  INTENT_PLACE     u32 intentId, u8 room, s32 x, s32 y, string structureName
    9  MUTATION_PLACE   u32 seq, u32 intentId, u8 room, s32 x, s32 y, s32 depth, string name
    10 INTENT_REJECTED  u32 intentId, string reason
    11 STRUCTURE_TABLE  u16 count, { u16 id, string name } * count
    12 DEBUG_LINE       string text
    13 ITEM_TABLE       u16 count, { u16 id, string name } * count
    14 DROP             u8 room, s32 x, s32 y, u16 item, u16 stack
    15 PICKUP           u8 room, s32 x, s32 y, u16 item
    16 RESOURCE_DESTROY u8 room, s32 x, s32 y, u16 objectIndex

Usage (from the repo root, with the game running and the mod loaded):

    python tools/coop_mockpeer.py client                 # game is HOSTING (F5)
    python tools/coop_mockpeer.py client --place forge   # ... then ask to build
    python tools/coop_mockpeer.py server                 # game JOINS (F6, 127.0.0.1)
    python tools/coop_mockpeer.py probe                  # dump the handshake bytes

In `client` mode the mock asks the host to place a structure once it has the
structure table and knows where the player is. By default it picks the first
name in `PREFERRED_STRUCTURES` that the host knows about; `--place NAME`
overrides that and `--no-place` turns the request off.

DEBUG_LINE carries one line of the peer's console and lands in
%TEMP%\\coop_debug.txt. The game's mods cannot write files themselves, so this
is how a long dump (F10 = probe the world) gets out of the game as readable text.
"""

from __future__ import annotations

import argparse
import json
import os
import random
import socket
import struct
import sys
import tempfile
import time

PROTOCOL = 5
VERSION = "mockpeer-5"
# The name the mock presents to the host (M3.1). ASCII on purpose: the host draws it with the
# game's own font, and a non-ASCII name is exactly the kind of thing that renders as boxes if
# the font lacks the glyphs.
NAME = "mock"

# GameMaker handshake / framing
HANDSHAKE_SV0 = b"GM:Studio-Connect\x00"
HANDSHAKE_CL1 = 0xCAFEBABE
HANDSHAKE_CL2 = 0xDEADB00B
HANDSHAKE_SV1 = 0xDEAFBEAD
HANDSHAKE_SV2 = 0xF00DBEEB
HANDSHAKE_PRE = 0xDEADC0DE

# mod packets
HELLO, WELCOME, REJECT, PING, PONG, POS, BYE = 1, 2, 3, 4, 5, 6, 7
INTENT_PLACE, MUTATION_PLACE, INTENT_REJECTED, STRUCTURE_TABLE = 8, 9, 10, 11
DEBUG_LINE = 12
ITEM_TABLE = 13
DROP, PICKUP, RESOURCE_DESTROY = 14, 15, 16

NAMES = {
    HELLO: "HELLO", WELCOME: "WELCOME", REJECT: "REJECT",
    PING: "PING", PONG: "PONG", POS: "POS", BYE: "BYE",
    INTENT_PLACE: "INTENT_PLACE", MUTATION_PLACE: "MUTATION_PLACE",
    INTENT_REJECTED: "INTENT_REJECTED", STRUCTURE_TABLE: "STRUCTURE_TABLE",
    DEBUG_LINE: "DEBUG_LINE", ITEM_TABLE: "ITEM_TABLE",
    DROP: "DROP", PICKUP: "PICKUP", RESOURCE_DESTROY: "RESOURCE_DESTROY",
}

# structures to try to build if we are not told which one (first match wins)
PREFERRED_STRUCTURES = ["forge", "furnace", "anvil", "torch", "bridge", "chest"]


def log(msg: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


# --- the mod's forwarded console -------------------------------------------
# A mod compiled by this game's loader cannot write a file (see DEBUG_LINE in
# docs/PROTOCOL.md), so the mod sends its long dumps over the wire and we keep
# them here. One file per connection, truncated on each new session: it always
# holds the dumps of the session being tested, and never a stale mix.

DEBUG_FILE = os.path.join(tempfile.gettempdir(), "coop_debug.txt")
_debug_handle = None


def debug_note(text: str) -> None:
    global _debug_handle
    log(f"## {text}")
    if _debug_handle is None:
        _debug_handle = open(DEBUG_FILE, "w", encoding="utf-8")
        log(f"   (debug lines are written to {DEBUG_FILE})")
    _debug_handle.write(text + "\n")
    _debug_handle.flush()


def reset_debug_file() -> None:
    global _debug_handle
    if _debug_handle is not None:
        _debug_handle.close()
        _debug_handle = None


# --- packet building -------------------------------------------------------

def p_str(s: str) -> bytes:
    return s.encode("utf-8") + b"\x00"


def hello() -> bytes:
    return bytes([HELLO, PROTOCOL]) + p_str(VERSION) + p_str(NAME)


def welcome() -> bytes:
    return bytes([WELCOME, PROTOCOL]) + p_str(VERSION) + p_str(NAME)


def ping(nonce: int) -> bytes:
    return bytes([PING]) + struct.pack("<I", nonce)


def pong(nonce: int) -> bytes:
    return bytes([PONG]) + struct.pack("<I", nonce)


def pos(x: int, y: int, angle: int = 0, facing: int = 1,
        sprite: int = -1, image: int = 0, room: int = 0) -> bytes:
    return (bytes([POS]) + struct.pack("<iihbiBB", x, y, angle, facing,
                                       sprite, image, room))


def intent_place(intent_id: int, room: int, x: int, y: int, name: str) -> bytes:
    return (bytes([INTENT_PLACE]) + struct.pack("<IBii", intent_id, room, x, y)
            + p_str(name))


def structure_table(entries: list[tuple[int, str]]) -> bytes:
    """The packet only the host sends, id -> name (packet 11)."""
    out = bytes([STRUCTURE_TABLE]) + struct.pack("<H", len(entries))
    for sid, name in entries:
        out += struct.pack("<H", sid) + p_str(name)
    return out


def debug_line(text: str) -> bytes:
    """One line of the sender's console (packet 12). See DEBUG_LINE above."""
    return bytes([DEBUG_LINE]) + p_str(text)


def item_table(entries: list[tuple[int, str]]) -> bytes:
    """The item database, id -> name (packet 13). Same shape as packet 11."""
    out = bytes([ITEM_TABLE]) + struct.pack("<H", len(entries))
    for iid, name in entries:
        out += struct.pack("<H", iid) + p_str(name)
    return out


def drop(room: int, x: int, y: int, item: int, stack: int) -> bytes:
    """An item appeared in the world (packet 14)."""
    return bytes([DROP]) + struct.pack("<BiiHH", room, x, y, item, stack)


def pickup(room: int, x: int, y: int, item: int) -> bytes:
    """An item left the world because someone took it (packet 15)."""
    return bytes([PICKUP]) + struct.pack("<BiiH", room, x, y, item)


def resource_destroy(room: int, x: int, y: int, obj: int) -> bytes:
    """A resource was harvested and is gone (packet 16)."""
    return bytes([RESOURCE_DESTROY]) + struct.pack("<BiiH", room, x, y, obj)


def bye(reason: str) -> bytes:
    return bytes([BYE]) + p_str(reason)


# --- packet parsing --------------------------------------------------------

def _read_str(buf: bytes, i: int):
    j = buf.find(b"\x00", i)
    if j < 0:
        return None
    return buf[i:j].decode("utf-8", "replace"), j + 1


def parse_one(buf: bytes):
    """Return (packet_dict, consumed) or (None, 0) when the payload is short."""
    if not buf:
        return None, 0
    cmd = buf[0]
    if cmd in (HELLO, WELCOME):
        if len(buf) < 2:
            return None, 0
        s = _read_str(buf, 2)
        if s is None:
            return None, 0
        ver, end = s
        # M3.1: the name follows the version. A peer that does not send one (an older build)
        # leaves nothing to read, so the field is optional on the wire and the mock reports
        # an empty name rather than failing the parse.
        nm = ""
        if end < len(buf):
            s2 = _read_str(buf, end)
            if s2 is not None:
                nm, end = s2
        return {"cmd": cmd, "name": NAMES[cmd], "protocol": buf[1],
                "version": ver, "peerName": nm}, end
    if cmd in (PING, PONG):
        if len(buf) < 5:
            return None, 0
        (nonce,) = struct.unpack("<I", buf[1:5])
        return {"cmd": cmd, "name": NAMES[cmd], "nonce": nonce}, 5
    if cmd == POS:
        if len(buf) < 18:
            return None, 0
        x, y, angle, facing, sprite, image, room = struct.unpack("<iihbiBB", buf[1:18])
        return {"cmd": cmd, "name": NAMES[cmd], "x": x, "y": y, "angle": angle,
                "facing": facing, "sprite": sprite, "image": image, "room": room}, 18
    if cmd in (REJECT, BYE):
        s = _read_str(buf, 1)
        if s is None:
            return None, 0
        reason, end = s
        return {"cmd": cmd, "name": NAMES[cmd], "reason": reason}, end
    if cmd == INTENT_PLACE:
        if len(buf) < 14:
            return None, 0
        (iid,) = struct.unpack("<I", buf[1:5])
        room = buf[5]
        x, y = struct.unpack("<ii", buf[6:14])
        s = _read_str(buf, 14)
        if s is None:
            return None, 0
        name, end = s
        return {"cmd": cmd, "name": NAMES[cmd], "intentId": iid, "room": room,
                "x": x, "y": y, "structure": name}, end
    if cmd == MUTATION_PLACE:
        if len(buf) < 18:
            return None, 0
        seq, iid, room = struct.unpack("<IIB", buf[1:10])
        x, y, depth = struct.unpack("<iii", buf[10:22])
        s = _read_str(buf, 22)
        if s is None:
            return None, 0
        name, end = s
        return {"cmd": cmd, "name": NAMES[cmd], "seq": seq, "intentId": iid,
                "room": room, "x": x, "y": y, "depth": depth, "structure": name}, end
    if cmd == INTENT_REJECTED:
        if len(buf) < 5:
            return None, 0
        (iid,) = struct.unpack("<I", buf[1:5])
        s = _read_str(buf, 5)
        if s is None:
            return None, 0
        reason, end = s
        return {"cmd": cmd, "name": NAMES[cmd], "intentId": iid, "reason": reason}, end
    if cmd == STRUCTURE_TABLE:
        if len(buf) < 3:
            return None, 0
        (count,) = struct.unpack("<H", buf[1:3])
        i = 3
        entries = []
        for _ in range(count):
            if i + 2 > len(buf):
                return None, 0
            (sid,) = struct.unpack("<H", buf[i:i + 2])
            i += 2
            s = _read_str(buf, i)
            if s is None:
                return None, 0
            name, i = s
            entries.append((sid, name))
        return {"cmd": cmd, "name": NAMES[cmd], "entries": entries}, i
    if cmd == ITEM_TABLE:
        if len(buf) < 3:
            return None, 0
        (count,) = struct.unpack("<H", buf[1:3])
        i = 3
        items = []
        for _ in range(count):
            if i + 2 > len(buf):
                return None, 0
            (iid,) = struct.unpack("<H", buf[i:i + 2])
            i += 2
            s = _read_str(buf, i)
            if s is None:
                return None, 0
            name, i = s
            items.append((iid, name))
        return {"cmd": cmd, "name": NAMES[cmd], "entries": items}, i
    if cmd == DROP:
        if len(buf) < 14:
            return None, 0
        room = buf[1]
        x, y = struct.unpack("<ii", buf[2:10])
        item, stack = struct.unpack("<HH", buf[10:14])
        return {"cmd": cmd, "name": NAMES[cmd], "room": room, "x": x, "y": y,
                "item": item, "stack": stack}, 14
    if cmd == PICKUP:
        if len(buf) < 12:
            return None, 0
        room = buf[1]
        x, y = struct.unpack("<ii", buf[2:10])
        (item,) = struct.unpack("<H", buf[10:12])
        return {"cmd": cmd, "name": NAMES[cmd], "room": room, "x": x, "y": y,
                "item": item}, 12
    if cmd == RESOURCE_DESTROY:
        if len(buf) < 12:
            return None, 0
        room = buf[1]
        x, y = struct.unpack("<ii", buf[2:10])
        (obj,) = struct.unpack("<H", buf[10:12])
        return {"cmd": cmd, "name": NAMES[cmd], "room": room, "x": x, "y": y,
                "object": obj}, 12
    if cmd == DEBUG_LINE:
        s = _read_str(buf, 1)
        if s is None:
            return None, 0
        text, end = s
        return {"cmd": cmd, "name": NAMES[cmd], "text": text}, end
    raise ValueError(f"unknown mod-packet id {cmd} (raw: {buf[:32].hex()})")


def describe(pkt: dict) -> str:
    name = pkt["name"]
    if name in ("HELLO", "WELCOME"):
        return (f"{name} protocol={pkt['protocol']} version={pkt['version']!r} "
                f"name={pkt.get('peerName', '')!r}")
    if name in ("PING", "PONG"):
        return f"{name} nonce={pkt['nonce']}"
    if name == "POS":
        return (f"POS x={pkt['x']} y={pkt['y']} angle={pkt['angle']} "
                f"facing={pkt['facing']} sprite={pkt['sprite']} "
                f"image={pkt['image']} room={pkt['room']}")
    if name == "MUTATION_PLACE":
        return (f"MUTATION seq={pkt['seq']} intent=#{pkt['intentId']} room={pkt['room']} "
                f"'{pkt['structure']}' at {pkt['x']},{pkt['y']} depth {pkt['depth']}")
    if name == "INTENT_PLACE":
        return (f"INTENT_PLACE #{pkt['intentId']} room={pkt['room']} "
                f"'{pkt['structure']}' at {pkt['x']},{pkt['y']}")
    if name == "INTENT_REJECTED":
        return f"INTENT_REJECTED #{pkt['intentId']}: {pkt['reason']!r}"
    if name == "STRUCTURE_TABLE":
        return f"STRUCTURE_TABLE {len(pkt['entries'])} entries"
    if name == "ITEM_TABLE":
        return f"ITEM_TABLE {len(pkt['entries'])} entries"
    if name == "DROP":
        return (f"DROP item #{pkt['item']} x{pkt['stack']} at {pkt['x']},{pkt['y']} "
                f"room {pkt['room']}")
    if name == "PICKUP":
        return f"PICKUP item #{pkt['item']} at {pkt['x']},{pkt['y']} room {pkt['room']}"
    if name == "RESOURCE_DESTROY":
        return (f"RESOURCE_DESTROY obj#{pkt['object']} at {pkt['x']},{pkt['y']} "
                f"room {pkt['room']}")
    if name == "DEBUG_LINE":
        return f"DEBUG {pkt['text']}"
    return f"{name} reason={pkt.get('reason')!r}"


def frame(payload: bytes) -> bytes:
    """Wrap a mod packet in GameMaker's TCP framing."""
    return struct.pack("<III", HANDSHAKE_PRE, 12, len(payload)) + payload


# --- peer ------------------------------------------------------------------

class Peer:
    """One connection; performs the GM handshake, then the mod handshake."""

    def __init__(self, sock: socket.socket, is_host: bool,
                 place: str | None = None, place_index: int | None = None):
        self.sock = sock
        self.is_host = is_host      # True when we are the GameMaker server side
        self.buf = b""
        self.ready = False          # GM handshake finished
        self.handshaken = False     # mod handshake finished
        self.sent_banner = False    # only the server side sends the GM banner
        self.nonce = 0
        self.last_ping = 0.0
        self.room = 0               # room learned from the game's POS packets
        self.player = None          # last position the game reported
        self.pos_logged = None      # last position we bothered to print
        self.px, self.py = 620, 620 # where our own puppet currently is
        # Where the puppet **stands**. Picked once, when the mock first learns where the host
        # is, and then left alone - see tick().
        self.anchor: tuple[int, int] | None = None
        self.structs: list[tuple[int, str]] = []
        self.items: list[tuple[int, str]] = []
        self.loot_seen: list[str] = []   # loot packets the host announced (M2.2)
        self.place_wanted = place   # None = auto, "" = do not ask
        self.place_index = place_index  # ask for this id from the host's table
        self.placed = False
        self.place_due = 0.0
        # A spot the host refused because it is water. We walk a short list of
        # candidate offsets around the game's player until one is accepted, so a
        # single run exercises both the refusal and a real placement - the mock has
        # no WaterCollision of its own, so trying is how it learns where the land is.
        self.place_try = 0
        self.place_spots: list[tuple[int, int]] = []
        self.last_spot: tuple[int, int] | None = None
        self.mutation_seen = False
        # How many builds to ask for in one session. One is enough to test "can a
        # client place at all"; two is what tests a *new* refusal, because the
        # second request can be aimed at the structure the first one just made.
        self.place_rounds = 2
        self.place_round = 0
        self.place_abs: tuple[int, int] | None = None   # round 2 aims absolutely
        self.sock.settimeout(0.2)

    # -- sending ------------------------------------------------------------
    def send(self, payload: bytes) -> None:
        self.sock.sendall(frame(payload))

    # -- receiving ----------------------------------------------------------
    def recv(self):
        try:
            got = self.sock.recv(4096)
        except socket.timeout:
            return b""              # nothing yet - not an error
        except OSError:
            return None             # peer closed hard
        if got == b"":
            return None             # clean EOF: the peer is *gone*, not idle
        return got

    def pump(self) -> None:
        chunk = self.recv()
        if chunk is None:
            log("connection closed by peer")
            raise SystemExit(0)
        if chunk:
            self.buf += chunk
        if not self.ready:
            # Not guarded by `if chunk`: the server side has to speak first (the
            # GM banner) before the client will say anything, so this must be
            # allowed to run on an empty buffer or the two sides wait forever.
            self._gm_handshake()
        if self.ready:
            self._frames()

    def _gm_handshake(self) -> None:
        if self.is_host:
            # GameMaker's *server* speaks first: the 18-byte banner, then the
            # client's 12 bytes (0xCAFEBABE, 0xDEADB00B, 16), then our 12.
            # The mod never sees this - the game's own netcode does it - which is
            # exactly why this side of the mock has to do it by hand. Sending the
            # banner matters: a GameMaker client waits for it before it says
            # anything, so without this line the two sides wait for each other.
            if not self.sent_banner:
                self.sock.sendall(HANDSHAKE_SV0)
                self.sent_banner = True
                log("GM handshake: server banner sent")
            if len(self.buf) < 12:
                return
            sig1, sig2, size = struct.unpack("<III", self.buf[:12])
            log(f"GM handshake: client sigs {sig1:#010x} {sig2:#010x} size={size}")
            self.buf = self.buf[16:] if len(self.buf) >= 16 else self.buf[12:]
            self.sock.sendall(struct.pack("<III", HANDSHAKE_SV1, HANDSHAKE_SV2, 12))
            log("GM handshake complete (server side)")
            self.ready = True
        else:
            # expect the banner, send the 16 bytes, expect the server's 12 bytes.
            # A runner that already considers the handshake done starts straight
            # at step 3, so tolerate that too.
            if self.buf[:len(HANDSHAKE_SV0)] == HANDSHAKE_SV0:
                if len(self.buf) < len(HANDSHAKE_SV0):
                    return
                self.buf = self.buf[len(HANDSHAKE_SV0):]
                self.sock.sendall(struct.pack("<III", HANDSHAKE_CL1, HANDSHAKE_CL2, 16))
                if len(self.buf) < 12:
                    return
            elif len(self.buf) < 12:
                return
            sig1, sig2, size = struct.unpack("<III", self.buf[:12])
            if sig1 != HANDSHAKE_SV1 or sig2 != HANDSHAKE_SV2:
                log(f"!! unexpected handshake bytes: {self.buf[:32]!r}")
                raise SystemExit(1)
            log(f"GM handshake: server sigs {sig1:#010x} {sig2:#010x} size={size}")
            self.buf = self.buf[12:]
            log("GM handshake complete (client side)")
            self.ready = True

    def _frames(self) -> None:
        while True:
            if len(self.buf) < 12:
                return
            pre, hdr, plen = struct.unpack("<III", self.buf[:12])
            if pre != HANDSHAKE_PRE or hdr != 12:
                log(f"!! bad frame header {pre:#010x} {hdr} raw={self.buf[:24].hex()}")
                self.buf = b""
                return
            if len(self.buf) < 12 + plen:
                return
            payload = self.buf[12:12 + plen]
            self.buf = self.buf[12 + plen:]
            self.handle_payload(payload)

    def handle_payload(self, payload: bytes) -> None:
        pkt, used = parse_one(payload)
        if pkt is None:
            return
        name = pkt["name"]
        # POS is the only packet worth filtering: the host streams it ~20x a
        # second and its animation frame changes every tick. It is logged below,
        # but only when the position actually moves.
        if name != "POS":
            log(f"<- {describe(pkt)}")

        if name == "HELLO" and self.is_host:
            if pkt["protocol"] != PROTOCOL:
                self.send(bye(f"protocol mismatch mock={PROTOCOL} peer={pkt['protocol']}"))
                log("-> BYE protocol mismatch")
                raise SystemExit(1)
            self.send(welcome())
            log("-> WELCOME")
            # Emulate the game host: it sends its structure table right after
            # WELCOME. With this, mock server <-> mock client locally exercises
            # the client's whole place path (choose -> INTENT_PLACE) with no
            # game running, which is how a bug in that path is caught.
            self.send(structure_table([(0, "land"), (1, "forge")]))
            log("-> STRUCTURE_TABLE 2 entries")
            # The real host sends its item table right after, too (M2.2).
            self.send(item_table([(0, "wood"), (1, "stone"), (2, "coin")]))
            log("-> ITEM_TABLE 3 entries")
            # One DEBUG_LINE so the offline test covers packet 12 too: in the
            # real thing this is how the game's long dumps reach us.
            self.send(debug_line("e2e: a debug line from the mock host"))
            log("-> DEBUG_LINE")
            # M2.2: the three loot packets, so packets 14-16 are exercised
            # offline before a game speaks them (see PROTOCOL.md).
            self.send(drop(8, 640, 704, 0, 3))
            log("-> DROP item #0 x3 at 640,704")
            self.send(pickup(8, 640, 704, 0))
            log("-> PICKUP item #0 at 640,704")
            self.send(resource_destroy(8, 512, 640, 5))
            log("-> RESOURCE_DESTROY obj#5 at 512,640")
            self.handshaken = True
        elif name == "WELCOME" and not self.is_host:
            if pkt["protocol"] != PROTOCOL:
                log("!! host protocol mismatch")
                raise SystemExit(1)
            self.handshaken = True
        elif name == "STRUCTURE_TABLE":
            self.structs = pkt["entries"]
            log(f"   host knows {len(self.structs)} structures: "
                + ", ".join(n for _, n in self.structs[:12])
                + (" ..." if len(self.structs) > 12 else ""))
            dump_structs(self.structs)
            if not self.placed and self.place_wanted != "":
                self.place_due = time.time() + 2.0   # give the game a moment
        elif name == "ITEM_TABLE":
            self.items = pkt["entries"]
            log(f"   host knows {len(self.items)} items: "
                + ", ".join(f"#{i}:{n}" for i, n in self.items[:8])
                + (" ..." if len(self.items) > 8 else ""))
            # A divergence check, the same way the structure table gets one: the
            # two installs must agree on what an item id means before any loot
            # packet can travel. The anchors are the ids M2.2 leans on.
            if self.items:
                first = self.items[:8]
                tail = self.items[-4:]
                debug_note("item table: " + f"{len(self.items)} entries; "
                           + "head " + ", ".join(f"#{i}={n}" for i, n in first)
                           + "; tail " + ", ".join(f"#{i}={n}" for i, n in tail))
        elif name in ("DROP", "PICKUP", "RESOURCE_DESTROY"):
            # The host announced a world change. In the real thing a client mirrors
            # it; here we only record it, which is enough to prove the packet
            # reaches a peer and decodes (M2.2 offline coverage).
            if name == "DROP":
                log(f"   host loot: item #{pkt['item']} x{pkt['stack']} at "
                    f"{pkt['x']},{pkt['y']} room {pkt['room']}")
            elif name == "PICKUP":
                log(f"   host loot: picked up item #{pkt['item']} at "
                    f"{pkt['x']},{pkt['y']}")
            else:
                log(f"   host loot: resource obj#{pkt['object']} gone at "
                    f"{pkt['x']},{pkt['y']}")
            self.loot_seen.append(name)
        elif name == "PING":
            self.send(pong(pkt["nonce"]))
            log(f"-> PONG nonce={pkt['nonce']}")
        elif name == "POS":
            self.room = pkt["room"]          # mirror the game's room back to it
            self.player = (pkt["x"], pkt["y"])
            # The host streams this ~20 times a second (the animation frame
            # changes every tick), so log only real movement - otherwise a live
            # log is one long wall of identical lines and the interesting packet
            # that follows is impossible to find.
            if self.player != self.pos_logged:
                self.pos_logged = self.player
                log(f"   pos {pkt['x']},{pkt['y']} room {pkt['room']}"
                    + f" facing {pkt['facing']}")
        elif name == "DEBUG_LINE":
            # The mod's own console, forwarded: this game's mods cannot write
            # files, so a long dump arrives here and we write it down.
            debug_note(pkt["text"])
        elif name == "INTENT_REJECTED":
            # The host refused our build request. If the reason is that the spot is
            # water, try the next candidate offset - this is also the positive
            # control for the host's new spot check: a run should log both a water
            # refusal and an accepted placement.
            log(f"   (refused: {pkt['reason']})")
            if pkt["intentId"] == self.last_intent and not self.mutation_seen:
                if "water" not in pkt["reason"] and "occupied" not in pkt["reason"]:
                    # Any other refusal is not a spot problem - walking the ring
                    # would just repeat it. Stop and say so, so the reason is the
                    # finding rather than ten identical lines.
                    self.placed = True
                    log(f"!! the host refused for a reason that is not water or occupancy: {pkt['reason']}")
                    return
                self.place_try += 1
                if self.place_try < len(self.place_spots):
                    self.place_due = time.time() + 0.2   # ask again elsewhere
                    log(f"   retrying at another spot (refused at {self.last_spot})")
                else:
                    self.placed = True
                    log(f"!! every candidate spot in the {len(self.place_spots)}-cell spiral "
                        f"was refused (all water or occupied) - no free ground near the player")
        elif name == "MUTATION_PLACE":
            # A confirmed placement. If it is the answer to our own intent, that spot
            # was free - the positive half of the spot check. A second round then asks
            # for the *same* cell the first build now occupies, which should come back
            # refused if the occupancy rule works; a mock that stopped here could
            # never show that.
            if pkt["intentId"] and pkt["intentId"] == self.last_intent:
                self.mutation_seen = True
                log(f"   accepted: '{pkt['name']}' at {pkt['x']},{pkt['y']} "
                    f"(seq {pkt['seq']}, depth {pkt['depth']}) - "
                    f"the spot we asked for ({self.last_spot}) was free")
                if self.place_round + 1 < self.place_rounds:
                    self.place_round += 1
                    self.place_try = 0
                    self.place_abs = (pkt["x"], pkt["y"])   # aim at what we just made
                    self.place_spots = [(0, 0)]             # one aim only this round
                    self.mutation_seen = False
                    self.place_due = time.time() + 3.0
                    log(f"   round {self.place_round + 1}: will ask for the occupied cell "
                        f"({pkt['x']},{pkt['y']})")
                else:
                    self.placed = True
        elif name in ("REJECT", "BYE"):
            log("peer ended the session")
            raise SystemExit(0)

    def choose_structure(self) -> str | None:
        if self.place_wanted:
            return self.place_wanted
        if self.place_index is not None:
            for sid, name in self.structs:
                if sid == self.place_index:
                    return name
            log(f"!! the host's table has no structure #{self.place_index}")
            return None
        known = {n.lower() for _, n in self.structs}
        for want in PREFERRED_STRUCTURES:
            if want in known:
                return want
        # Nothing matched by English name (we are on a localized install), so take
        # the first entry a player could actually build. The structure database
        # also stores the build-menu category headers as rows - "для
        # промышленности" and friends, whose object is the objEmpty placeholder -
        # and asking the host to build one creates nothing at all (live run
        # 2026-10-20). The prefix test is a test-tool heuristic, not wire logic.
        for _sid, name in self.structs:
            if not name or name.startswith("для"):
                continue
            return name
        return self.structs[0][1] if self.structs else None

    def tick(self) -> None:
        now = time.time()
        if self.handshaken:
            if now - self.last_ping > 2.0:
                self.nonce += 1
                self.send(ping(self.nonce))
                log(f"-> PING nonce={self.nonce}")
                self.last_ping = now
            # **Stand still, but reappear if the owner walks away.**
            #
            # The mock is a stand-in for a second player, not a player: it has no walk
            # command, so it has no business following the host frame by frame. The earlier
            # version walked a small square around the host's *live* position, which glued
            # the puppet to the host's camera - the owner noticed it as "the mock follows
            # the player" (live, 2026-10-21).
            #
            # But a stand-in that stays where it was put is not much use either: the owner
            # walked off and the mock was left behind, out of sight ("it appeared not next
            # to me"). So the anchor is **re-picked when the host gets far from it**: the
            # mock stands still while the owner is in the area, and reappears nearby when
            # the owner has genuinely gone somewhere else. A 200 px leash is long enough
            # that the mock reads as stationary and short enough that it is never lost.
            #
            # The build spots are a different thing and keep using the host's live position:
            # the host validates them, and a build that lands where the owner is standing is
            # the only placement test worth running.
            if self.player is not None:
                if self.anchor is None:
                    self.anchor = (self.player[0] - 96, self.player[1])
                else:
                    _dx = self.player[0] - self.anchor[0]
                    _dy = self.player[1] - self.anchor[1]
                    if _dx * _dx + _dy * _dy > 200 * 200:
                        self.anchor = (self.player[0] - 96, self.player[1])
                        log(f"   re-anchoring at {self.anchor} - the host moved away")
            ax, ay = self.anchor if self.anchor is not None else (620, 620)
            self.px, self.py = ax, ay
            self.send(pos(ax, ay, angle=0, facing=1, sprite=-1, image=0, room=self.room))
        # ask the host to build something; retry other spots on a spot refusal
        # (water or occupancy), and after a success start the next round, so a run
        # shows the refusal *and* a build - and, with a second round, a spot that is
        # refused because the first build now occupies it
        if self.place_due and not self.placed and now >= self.place_due:
            name = self.choose_structure()
            if name is None:
                log("!! the host sent no structure table; cannot request a build")
                self.placed = True
                return
            if self.player is not None:
                px, py = self.player
            else:
                px, py = self.px, self.py
            if not self.place_spots:
                # Offsets around the **game's player**, on the **16 px world grid**.
                #
                # The base is the host's own player position (`self.player`, which arrives in
                # PLAYER_UPDATE) and only falls back to the mock's own puppet when the host has
                # not reported one yet. That distinction is the whole point: the grid the spots
                # sit on has to be the host's, because the host validates them, but the *origin*
                # must be the host's player too - the owner's complaint live 2026-10-20 was a
                # furnace that was correctly on-grid but placed next to the mock's stand-in
                # somewhere else in the world, which is useless as a placement test.
                #
                # 16 px, not 24. The build-cell is 16, measured from the objects the game itself
                # places (19 natural spawns: smallest gap 16 on both axes). The old 24 was a
                # reading taken from structures this mod had created, so it agreed with itself
                # and put every ask half a cell off the world's lattice.
                #
                # Walking outward in a spiral: a sparse fixed ring reaches 320 px and can miss
                # every legal cell when the owner stands on a small island - which is exactly
                # what happened live 2026-10-20 at 03:41, where all 25 ring spots were water or
                # a tree and the mock had nowhere legal to ask. A dense spiral stays on the land
                # the owner is actually standing on.
                #
                # The base is leveraged to the grid before the offsets are added, so every spot
                # this mock asks for is itself on the grid - a test that asked off-grid would be
                # measuring the host's snap instead of the spot check.
                _bx = round(px / 16) * 16
                _by = round(py / 16) * 16
                self.place_spots = []
                for _ring in range(0, 9):
                    for _gx in range(-_ring, _ring + 1):
                        for _gy in range(-_ring, _ring + 1):
                            if max(abs(_gx), abs(_gy)) != _ring:
                                continue
                            if _gx == 0 and _gy == 0:
                                continue   # the player's own cell is not buildable
                            self.place_spots.append((_bx + _gx * 16, _by + _gy * 16))
            if self.place_abs is not None:
                tx, ty = self.place_abs            # round 2: an exact cell, not an offset
            else:
                tx, ty = self.place_spots[self.place_try % len(self.place_spots)]
            room = self.room if self.room else 8
            self.last_intent = (intent_id := random.randint(1, 0xFFFF))
            self.last_spot = (tx, ty)
            log(f"-> INTENT_PLACE '{name}' at {tx},{ty} (room {room}, "
                f"#{intent_id}, round {self.place_round + 1}, "
                f"spot {self.place_try + 1}/{len(self.place_spots)}); "
                f"our puppet is at {self.px},{self.py}")
            self.send(intent_place(intent_id, room, tx, ty, name))


def dump_structs(structs: list[tuple[int, str]]) -> None:
    """Write the host's structure table to a UTF-8 JSON file.

    These names are the game's own strings, so on a non-English install they are
    localized - the console mangles them and a PowerShell `>` redirect is not
    UTF-8, so this file is the only trustworthy copy. It also serves the
    cross-install divergence check (same build + same language => same names).
    """
    path = os.path.join(tempfile.gettempdir(), "coop_structure_table.json")
    try:
        with open(path, "w", encoding="utf-8") as fh:
            json.dump([{"id": i, "name": n} for i, n in structs],
                      fh, ensure_ascii=False, indent=1)
    except OSError:
        return
    log(f"   (table written to {path})")


def run_selftest() -> int:
    """Round-trip every packet we can build, so a field-order slip cannot hide."""
    cases = [
        (hello(), "HELLO"), (welcome(), "WELCOME"), (ping(7), "PING"),
        (pong(7), "PONG"), (pos(1, 2, 3, -1, 5, 6, 8), "POS"),
        (intent_place(9, 8, 10, 20, "forge"), "INTENT_PLACE"),
        (bye("byebye"), "BYE"),
    ]
    failures = []
    for payload, name in cases:
        try:
            pkt, used = parse_one(payload)
        except Exception as exc:                      # noqa: BLE001
            failures.append(f"{name}: parse raised {exc!r}")
            continue
        if pkt is None or pkt["name"] != name:
            failures.append(f"{name}: parsed as {pkt}")
        elif used != len(payload):
            failures.append(f"{name}: consumed {used} of {len(payload)} bytes")

    # packets only the game sends: build them by hand and parse them back
    mut = (bytes([MUTATION_PLACE]) + struct.pack("<IIB", 12, 9, 8)
           + struct.pack("<iii", 640, 704, -10) + p_str("forge"))
    tbl = (bytes([STRUCTURE_TABLE]) + struct.pack("<H", 2)
           + struct.pack("<H", 0) + p_str("land")
           + struct.pack("<H", 1) + p_str("forge"))
    rej = bytes([INTENT_REJECTED]) + struct.pack("<I", 9) + p_str("too far")
    dbg = debug_line("probe: table #0 obj objForge isStruct=1")
    itm = item_table([(0, "wood"), (1, "stone"), (2, "coin")])
    drp = drop(8, 640, 704, 0, 3)
    pik = pickup(8, 640, 704, 0)
    rds = resource_destroy(8, 512, 640, 5)
    for payload, name, checks in [
        (mut, "MUTATION_PLACE", {"seq": 12, "intentId": 9, "x": 640, "y": 704,
                                 "depth": -10, "structure": "forge"}),
        (tbl, "STRUCTURE_TABLE", {"entries": [(0, "land"), (1, "forge")]}),
        (rej, "INTENT_REJECTED", {"intentId": 9, "reason": "too far"}),
        (dbg, "DEBUG_LINE", {"text": "probe: table #0 obj objForge isStruct=1"}),
        (itm, "ITEM_TABLE", {"entries": [(0, "wood"), (1, "stone"), (2, "coin")]}),
        (drp, "DROP", {"room": 8, "x": 640, "y": 704, "item": 0, "stack": 3}),
        (pik, "PICKUP", {"room": 8, "x": 640, "y": 704, "item": 0}),
        (rds, "RESOURCE_DESTROY", {"room": 8, "x": 512, "y": 640, "object": 5}),
    ]:
        try:
            pkt, used = parse_one(payload)
        except Exception as exc:                      # noqa: BLE001
            failures.append(f"{name}: parse raised {exc!r}")
            continue
        if pkt is None or pkt["name"] != name:
            failures.append(f"{name}: parsed as {pkt}")
            continue
        if used != len(payload):
            failures.append(f"{name}: consumed {used} of {len(payload)} bytes")
        for key, want in checks.items():
            if pkt.get(key) != want:
                failures.append(f"{name}: {key} = {pkt.get(key)!r}, want {want!r}")

    # the GameMaker framing round-trips too
    framed = frame(intent_place(1, 8, 2, 3, "forge"))
    if framed[:12] != struct.pack("<III", HANDSHAKE_PRE, 12, len(framed) - 12):
        failures.append("frame(): wrong header")

    # the place-retry state machine: a water refusal must re-arm the next spot, an
    # accepted mutation must stop it. This is the offline half of the spot-check
    # test the game supplies the other half of.
    a, b = socket.socketpair()
    try:
        peer = Peer(a, is_host=False)
        peer.handshaken = True
        peer.player = (600, 600)
        peer.place_wanted = "forge"
        sent: list[dict] = []
        peer.send = lambda payload: sent.append(parse_one(payload)[0])  # type: ignore[assignment]
        peer.place_due = time.time() - 1.0
        peer.tick()                       # asks at spot 1 (a POS packet comes first)
        intents = [p for p in sent if p["name"] == "INTENT_PLACE"]
        if not intents:
            failures.append(f"retry: first tick sent no intent ({[p['name'] for p in sent]})")
        else:
            first = intents[-1]
            peer.handle_payload(bytes([INTENT_REJECTED])
                                + struct.pack("<I", first["intentId"])
                                + p_str("that spot is on water"))
            if peer.place_try != 1:
                failures.append(f"retry: water refusal left place_try {peer.place_try}")
            if peer.placed:
                failures.append("retry: water refusal stopped the walk instead of retrying")
            peer.place_due = time.time() - 1.0
            peer.tick()                   # asks at spot 2
            intents = [p for p in sent if p["name"] == "INTENT_PLACE"]
            if len(intents) < 2:
                failures.append("retry: second tick did not ask again")
            elif (intents[-1]["x"], intents[-1]["y"]) == (first["x"], first["y"]):
                failures.append("retry: asked the same spot twice")
            else:
                second = intents[-1]
                peer.handle_payload(bytes([MUTATION_PLACE])
                                    + struct.pack("<IIB", 7, second["intentId"], 8)
                                    + struct.pack("<iii", second["x"], second["y"], -second["y"])
                                    + p_str("forge"))
                if peer.placed:
                    failures.append("retry: the walk settled after round 1, so round 2 "
                                    "can never test the occupied cell")
                if peer.place_round != 1:
                    failures.append(f"retry: round after a success is {peer.place_round}")
                if peer.place_abs != (second["x"], second["y"]):
                    failures.append(f"retry: round 2 aims at {peer.place_abs}, "
                                    f"not the cell just built at {(second['x'], second['y'])}")
                # Round 2: the host sees its own new structure in that cell and must
                # refuse it as occupied.
                peer.place_due = time.time() - 1.0
                peer.tick()
                intents = [p for p in sent if p["name"] == "INTENT_PLACE"]
                if len(intents) < 3:
                    failures.append("retry: round 2 did not ask at the built cell")
                elif (intents[-1]["x"], intents[-1]["y"]) != (second["x"], second["y"]):
                    failures.append("retry: round 2 asked somewhere else")
                else:
                    third = intents[-1]
                    peer.handle_payload(bytes([INTENT_REJECTED])
                                        + struct.pack("<I", third["intentId"])
                                        + p_str("that spot is already occupied"))
                    if not peer.placed:
                        failures.append("retry: an occupied refusal on the last aim "
                                        "did not settle the walk")
    finally:
        a.close()
        b.close()

    if failures:
        for f in failures:
            log(f"FAIL {f}")
        return 1
    log(f"selftest: {len(cases) + 8} packets encode/parse correctly, spot-retry ok")
    return 0


def run_client(host: str, port: int, place: str | None, wait: float = 0.0,
               run_for: float = 0.0, place_index: int | None = None) -> int:
    """Talk to the game's host, and dial again whenever the game goes away.

    The owner's game comes and goes - a restart, a crash, a recompile - and a peer
    that quietly hangs on a dead socket wastes the whole test. That happened once:
    the mock sat on a closed connection while a fresh host listened on the port,
    so a clean EOF now counts as "peer gone" (see recv) and this loop redials
    while its time budget lasts.
    """
    start = time.time()
    deadline = start + wait if wait > 0 else None
    stop_at = start + run_for if run_for > 0 else None
    session_no = 0
    while True:
        if stop_at is not None and time.time() >= stop_at:
            log(f"(--for {run_for:.0f}s reached; done)")
            return 0
        session_no += 1
        if session_no == 1:
            log(f"connecting to game host {host}:{port}"
                + (f" (retrying for up to {wait:.0f}s - start hosting whenever)"
                   if wait > 0 else ""))
        else:
            log(f"reconnecting to {host}:{port} (session {session_no})")
        while True:
            try:
                s = socket.create_connection((host, port), timeout=5)
                break
            except OSError as exc:
                if deadline is None or time.time() >= deadline:
                    log(f"!! could not connect: {exc}")
                    return 1
                time.sleep(1.0)
        log("connected")
        reset_debug_file()
        code = _session(s, place, stop_at, run_for, place_index)
        if code is None:                 # time budget ran out inside the session
            return 0
        if code != 0:                    # a protocol mistake - do not loop on it
            return 1
        log("session ended; the host may have restarted")
        if deadline is None or time.time() >= deadline:
            log("no time budget left to reconnect")
            return 1
        time.sleep(1.0)


def _session(s: socket.socket, place: str | None, stop_at: float | None,
             run_for: float, place_index: int | None = None) -> int | None:
    """One connection to the host. None = the time budget ran out, else the exit code."""
    peer = Peer(s, is_host=False, place=place, place_index=place_index)

    def timeup() -> bool:
        return stop_at is not None and time.time() >= stop_at

    try:
        while not peer.ready:
            peer.pump()
            if timeup():
                log(f"(--for {run_for:.0f}s reached; done)")
                return None
        log("sending HELLO")
        peer.send(hello())
        log("-> HELLO")
        while True:
            peer.pump()
            peer.tick()
            time.sleep(0.1)
            if timeup():
                log(f"(--for {run_for:.0f}s reached; done)")
                return None
    except SystemExit as exc:
        return 0 if exc.code is None else int(exc.code)


def run_probe(host: str, port: int, settle: float) -> None:
    """Connect and dump raw bytes so we can see the runner's exact handshake."""
    log(f"probe: connecting to {host}:{port} (sending nothing)")
    s = socket.create_connection((host, port), timeout=5)
    s.settimeout(0.5)
    phase1 = _drain(s, settle)
    log(f"phase 1 (passive, {settle}s): {len(phase1)} bytes")
    if phase1:
        log(f"  hex: {phase1.hex()}")
        log(f"  repr: {phase1!r}")
    log("phase 2: sending client handshake 0xCAFEBABE/0xDEADB00B/16")
    try:
        s.sendall(struct.pack("<III", HANDSHAKE_CL1, HANDSHAKE_CL2, 16))
    except OSError as exc:
        log(f"  send failed: {exc}")
    phase2 = _drain(s, settle)
    log(f"phase 2 ({settle}s): {len(phase2)} bytes")
    if phase2:
        log(f"  hex: {phase2.hex()}")
        log(f"  repr: {phase2!r}")
    s.close()
    log("probe done")


def _drain(s: socket.socket, seconds: float) -> bytes:
    end = time.time() + seconds
    data = b""
    while time.time() < end:
        try:
            chunk = s.recv(4096)
        except socket.timeout:
            continue
        except OSError:
            break
        if not chunk:
            break
        data += chunk
    return data


def run_server(port: int) -> None:
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", port))
    srv.listen(1)
    log(f"listening on 0.0.0.0:{port} - now press F6 in the game and enter 127.0.0.1")
    conn, addr = srv.accept()
    log(f"game connected from {addr[0]}:{addr[1]}")
    reset_debug_file()
    peer = Peer(conn, is_host=True)
    while True:
        peer.pump()
        peer.tick()
        time.sleep(0.1)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("mode", choices=["client", "server", "probe", "selftest"])
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=6511)
    ap.add_argument("--place", default=None,
                    help="structure name to ask the host for (auto if omitted)")
    ap.add_argument("--no-place", action="store_true",
                    help="do not request a structure at all")
    ap.add_argument("--place-index", type=int, default=None,
                    help="client mode: ask for the structure with this id "
                         "from the host's table (test aid)")
    ap.add_argument("--wait", type=float, default=0.0,
                    help="client mode: keep retrying the connection for this many seconds")
    ap.add_argument("--for", dest="run_for", type=float, default=0.0,
                    help="client mode: exit after this many seconds (0 = run until stopped)")
    args = ap.parse_args()
    place = "" if args.no_place else args.place
    try:
        if args.mode == "selftest":
            return run_selftest()
        if args.mode == "client":
            return run_client(args.host, args.port, place, args.wait, args.run_for,
                              args.place_index)
        elif args.mode == "probe":
            run_probe(args.host, args.port, settle=4.0)
        else:
            run_server(args.port)
    except KeyboardInterrupt:
        log("bye")
    return 0


if __name__ == "__main__":
    sys.exit(main())
