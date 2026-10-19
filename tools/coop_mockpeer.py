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

    1  HELLO            u8 protocol, string version
    2  WELCOME          u8 protocol, string version
    3  REJECT           string reason
    4  PING             u32 nonce
    5  PONG             u32 nonce
    6  POS              s32 x, s32 y, u16 angle, s8 facing, s32 sprite, u8 image, u8 room
    7  BYE              string reason
    8  INTENT_PLACE     u32 intentId, u8 room, s32 x, s32 y, string structureName
    9  MUTATION_PLACE   u32 seq, u32 intentId, u8 room, s32 x, s32 y, s32 depth, string name
    10 INTENT_REJECTED  u32 intentId, string reason
    11 STRUCTURE_TABLE  u16 count, { u16 id, string name } * count

Usage (from the repo root, with the game running and the mod loaded):

    python tools/coop_mockpeer.py client                 # game is HOSTING (F5)
    python tools/coop_mockpeer.py client --place forge   # ... then ask to build
    python tools/coop_mockpeer.py server                 # game JOINS (F6, 127.0.0.1)
    python tools/coop_mockpeer.py probe                  # dump the handshake bytes

In `client` mode the mock asks the host to place a structure once it has the
structure table and knows where the player is. By default it picks the first
name in `PREFERRED_STRUCTURES` that the host knows about; `--place NAME`
overrides that and `--no-place` turns the request off.
"""

from __future__ import annotations

import argparse
import random
import socket
import struct
import sys
import time

PROTOCOL = 2
VERSION = "mockpeer-2"

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

NAMES = {
    HELLO: "HELLO", WELCOME: "WELCOME", REJECT: "REJECT",
    PING: "PING", PONG: "PONG", POS: "POS", BYE: "BYE",
    INTENT_PLACE: "INTENT_PLACE", MUTATION_PLACE: "MUTATION_PLACE",
    INTENT_REJECTED: "INTENT_REJECTED", STRUCTURE_TABLE: "STRUCTURE_TABLE",
}

# structures to try to build if we are not told which one (first match wins)
PREFERRED_STRUCTURES = ["forge", "furnace", "anvil", "torch", "bridge", "chest"]


def log(msg: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


# --- packet building -------------------------------------------------------

def p_str(s: str) -> bytes:
    return s.encode("utf-8") + b"\x00"


def hello() -> bytes:
    return bytes([HELLO, PROTOCOL]) + p_str(VERSION)


def welcome() -> bytes:
    return bytes([WELCOME, PROTOCOL]) + p_str(VERSION)


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
        return {"cmd": cmd, "name": NAMES[cmd], "protocol": buf[1], "version": ver}, end
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
    raise ValueError(f"unknown mod-packet id {cmd} (raw: {buf[:32].hex()})")


def describe(pkt: dict) -> str:
    name = pkt["name"]
    if name in ("HELLO", "WELCOME"):
        return f"{name} protocol={pkt['protocol']} version={pkt['version']!r}"
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
    return f"{name} reason={pkt.get('reason')!r}"


def frame(payload: bytes) -> bytes:
    """Wrap a mod packet in GameMaker's TCP framing."""
    return struct.pack("<III", HANDSHAKE_PRE, 12, len(payload)) + payload


# --- peer ------------------------------------------------------------------

class Peer:
    """One connection; performs the GM handshake, then the mod handshake."""

    def __init__(self, sock: socket.socket, is_host: bool,
                 place: str | None = None):
        self.sock = sock
        self.is_host = is_host      # True when we are the GameMaker server side
        self.buf = b""
        self.ready = False          # GM handshake finished
        self.handshaken = False     # mod handshake finished
        self.nonce = 0
        self.last_ping = 0.0
        self.room = 0               # room learned from the game's POS packets
        self.player = None          # last position the game reported
        self.px, self.py = 620, 620 # where our own puppet currently is
        self.structs: list[tuple[int, str]] = []
        self.place_wanted = place   # None = auto, "" = do not ask
        self.placed = False
        self.place_due = 0.0
        self.sock.settimeout(0.2)

    # -- sending ------------------------------------------------------------
    def send(self, payload: bytes) -> None:
        self.sock.sendall(frame(payload))

    # -- receiving ----------------------------------------------------------
    def recv(self):
        try:
            return self.sock.recv(4096)
        except socket.timeout:
            return b""
        except OSError:
            return None  # peer closed

    def pump(self) -> None:
        chunk = self.recv()
        if chunk is None:
            log("connection closed")
            raise SystemExit(0)
        if not chunk:
            return
        self.buf += chunk
        if not self.ready:
            self._gm_handshake()
        if self.ready:
            self._frames()

    def _gm_handshake(self) -> None:
        if self.is_host:
            if self.buf[:len(HANDSHAKE_SV0)] == HANDSHAKE_SV0 and len(self.buf) >= 16:
                self.buf = self.buf[len(HANDSHAKE_SV0):]
            if len(self.buf) < 16:
                return
            sig1, sig2, size = struct.unpack("<III", self.buf[:12])
            log(f"GM handshake: client sigs {sig1:#010x} {sig2:#010x} size={size}")
            self.buf = self.buf[16:]
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
        log(f"<- {describe(pkt)}")
        name = pkt["name"]

        if name == "HELLO" and self.is_host:
            if pkt["protocol"] != PROTOCOL:
                self.send(bye(f"protocol mismatch mock={PROTOCOL} peer={pkt['protocol']}"))
                log("-> BYE protocol mismatch")
                raise SystemExit(1)
            self.send(welcome())
            log("-> WELCOME")
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
            if not self.placed and self.place_wanted != "":
                self.place_due = time.time() + 2.0   # give the game a moment
        elif name == "PING":
            self.send(pong(pkt["nonce"]))
            log(f"-> PONG nonce={pkt['nonce']}")
        elif name == "POS":
            self.room = pkt["room"]          # mirror the game's room back to it
            self.player = (pkt["x"], pkt["y"])
        elif name in ("REJECT", "BYE"):
            log("peer ended the session")
            raise SystemExit(0)

    def choose_structure(self) -> str | None:
        if self.place_wanted:
            return self.place_wanted
        known = {n.lower() for _, n in self.structs}
        for want in PREFERRED_STRUCTURES:
            if want in known:
                return want
        return self.structs[0][1] if self.structs else None

    def tick(self) -> None:
        now = time.time()
        if self.handshaken:
            if now - self.last_ping > 2.0:
                self.nonce += 1
                self.send(ping(self.nonce))
                log(f"-> PING nonce={self.nonce}")
                self.last_ping = now
            # Walk our puppet in a small square just left of the game's player,
            # so the marker is on screen and anything we ask for lands near both.
            # Falls back to a fixed spot until the game reports its position.
            bx, by = self.player or (620, 620)
            bx -= 96
            t = int(now) % 40
            x = bx + (t if t < 10 else 10 if t < 20 else (30 - t) if t < 30 else 0)
            y = by + (0 if t < 10 else (t - 10) if t < 20 else 10 if t < 30 else (40 - t))
            self.px, self.py = x, y
            self.send(pos(x, y, angle=0, facing=1, sprite=-1, image=0, room=self.room))
        # ask the host to build something, once
        if self.place_due and not self.placed and now >= self.place_due:
            self.placed = True
            name = self.choose_structure()
            if name is None:
                log("!! the host sent no structure table; cannot request a build")
                return
            # put it a little to the right of the game's player - near enough for
            # the host's range check, far enough to be an obvious new object
            px, py = self.player or self.px, self.py
            tx, ty = (px + 128, py)
            room = self.room if self.room else 8
            self.last_intent = (intent_id := random.randint(1, 0xFFFF))
            log(f"-> INTENT_PLACE '{name}' at {tx},{ty} (room {room}, "
                f"#{intent_id}); our puppet is at {self.px},{self.py}")
            self.send(intent_place(intent_id, room, tx, ty, name))


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
    for payload, name, checks in [
        (mut, "MUTATION_PLACE", {"seq": 12, "intentId": 9, "x": 640, "y": 704,
                                 "depth": -10, "structure": "forge"}),
        (tbl, "STRUCTURE_TABLE", {"entries": [(0, "land"), (1, "forge")]}),
        (rej, "INTENT_REJECTED", {"intentId": 9, "reason": "too far"}),
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

    if failures:
        for f in failures:
            log(f"FAIL {f}")
        return 1
    log(f"selftest: {len(cases) + 3} packets encode/parse correctly")
    return 0


def run_client(host: str, port: int, place: str | None) -> None:
    log(f"connecting to game host {host}:{port}")
    s = socket.create_connection((host, port), timeout=5)
    peer = Peer(s, is_host=False, place=place)
    while not peer.ready:
        peer.pump()
    log("sending HELLO")
    peer.send(hello())
    log("-> HELLO")
    while True:
        peer.pump()
        peer.tick()
        time.sleep(0.1)


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
    args = ap.parse_args()
    place = "" if args.no_place else args.place
    try:
        if args.mode == "selftest":
            return run_selftest()
        if args.mode == "client":
            run_client(args.host, args.port, place)
        elif args.mode == "probe":
            run_probe(args.host, args.port, settle=4.0)
        else:
            run_server(args.port)
    except KeyboardInterrupt:
        log("bye")
    return 0


if __name__ == "__main__":
    sys.exit(main())
