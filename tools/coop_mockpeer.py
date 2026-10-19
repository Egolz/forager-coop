#!/usr/bin/env python3
"""Mock peer for the Forager Co-op mod's M1 protocol.

Lets us exercise the mod's DirectTCP layer without launching a second copy of
Forager. It speaks both the *GameMaker* socket handshake/framing and the mod's
own packets.

GameMaker's TCP socket protocol (constants from YoYoGames/GameMaker-HTML5,
scripts/functions/Function_Networking.js - the desktop runner behaves the same;
verified by watching this game's server send the step-1 banner):

    step 1  server -> client   "GM:Studio-Connect\\0"                (18 bytes)
    step 2  client -> server   u32 0xCAFEBABE, u32 0xDEADB00B, u32 16
    step 3  server -> client   u32 0xDEAFBEAD, u32 0xF00DBEEB, u32 12
    then    both ways, per packet:
                               u32 0xDEADC0DE, u32 12, u32 payloadLen, payload

Mod's M1 packets (little-endian; GameMaker buffer_string = UTF-8 + NUL):

    HELLO   = 1  u8 protocol, string version
    WELCOME = 2  u8 protocol, string version
    REJECT  = 3  string reason
    PING    = 4  u32 nonce
    PONG    = 5  u32 nonce
    POS     = 6  s32 x, s32 y, u16 angle, s8 facing, s32 sprite, u8 image, u8 room
    BYE     = 7  string reason

Usage (from the repo root, with the game running and the mod loaded):

    python tools/coop_mockpeer.py client   # the game is HOSTING (F5 in game)
    python tools/coop_mockpeer.py server   # the game is JOINING (F6 -> 127.0.0.1)
    python tools/coop_mockpeer.py probe    # dump the raw handshake bytes and exit
"""

from __future__ import annotations

import argparse
import socket
import struct
import sys
import time

PROTOCOL = 1
VERSION = "mockpeer-1"

# GameMaker handshake / framing
HANDSHAKE_SV0 = b"GM:Studio-Connect\x00"
HANDSHAKE_CL1 = 0xCAFEBABE
HANDSHAKE_CL2 = 0xDEADB00B
HANDSHAKE_SV1 = 0xDEAFBEAD
HANDSHAKE_SV2 = 0xF00DBEEB
HANDSHAKE_PRE = 0xDEADC0DE

# mod packets
HELLO, WELCOME, REJECT, PING, PONG, POS, BYE = 1, 2, 3, 4, 5, 6, 7
NAMES = {HELLO: "HELLO", WELCOME: "WELCOME", REJECT: "REJECT",
         PING: "PING", PONG: "PONG", POS: "POS", BYE: "BYE"}


def log(msg: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


# --- mod packet building ---------------------------------------------------

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


def bye(reason: str) -> bytes:
    return bytes([BYE]) + p_str(reason)


# --- mod packet parsing ----------------------------------------------------

POS_LEN = 1 + 4 + 4 + 2 + 1 + 4 + 1 + 1  # 18


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
        if len(buf) < POS_LEN:
            return None, 0
        x, y, angle, facing, sprite, image, room = struct.unpack(
            "<iihbiBB", buf[1:POS_LEN])
        return {"cmd": cmd, "name": NAMES[cmd], "x": x, "y": y, "angle": angle,
                "facing": facing, "sprite": sprite, "image": image,
                "room": room}, POS_LEN
    if cmd in (REJECT, BYE):
        s = _read_str(buf, 1)
        if s is None:
            return None, 0
        reason, end = s
        return {"cmd": cmd, "name": NAMES[cmd], "reason": reason}, end
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
    return f"{name} reason={pkt.get('reason')!r}"


def frame(payload: bytes) -> bytes:
    """Wrap a mod packet in GameMaker's TCP framing."""
    return struct.pack("<III", HANDSHAKE_PRE, 12, len(payload)) + payload


# --- peer -----------------------------------------------------------------

class Peer:
    """One connection; performs the GM handshake, then the mod handshake."""

    def __init__(self, sock: socket.socket, is_host: bool):
        self.sock = sock
        self.is_host = is_host      # True when we are the GameMaker server side
        self.buf = b""
        self.ready = False          # GM handshake finished
        self.handshaken = False     # mod handshake finished
        self.nonce = 0
        self.last_ping = 0.0
        self.room = 0               # room learned from the game's POS packets
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
            # we are the server: send the banner, expect the client's 16 bytes,
            # answer with our 12 bytes
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
            # we are the client: expect the banner, send the 16 bytes, expect
            # the server's 12 bytes. A runner that already considers the
            # handshake done (seen on a reused single-client server) starts
            # straight at step 3, so tolerate that too.
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
        if pkt["name"] == "HELLO" and self.is_host:
            if pkt["protocol"] != PROTOCOL:
                self.send(bye(f"protocol mismatch mock={PROTOCOL} peer={pkt['protocol']}"))
                log("-> BYE protocol mismatch")
                raise SystemExit(1)
            self.send(welcome())
            log("-> WELCOME")
            self.handshaken = True
        elif pkt["name"] == "WELCOME" and not self.is_host:
            if pkt["protocol"] != PROTOCOL:
                log("!! host protocol mismatch")
                raise SystemExit(1)
            self.handshaken = True
        elif pkt["name"] == "POS":
            self.room = pkt["room"]     # mirror the game's room back to it
        elif pkt["name"] == "PING":
            self.send(pong(pkt["nonce"]))
            log(f"-> PONG nonce={pkt['nonce']}")
        elif pkt["name"] in ("REJECT", "BYE"):
            log("peer ended the session")
            raise SystemExit(0)

    def tick(self) -> None:
        now = time.time()
        if not self.handshaken:
            return
        if now - self.last_ping > 2.0:
            self.nonce += 1
            self.send(ping(self.nonce))
            log(f"-> PING nonce={self.nonce}")
            self.last_ping = now
        # walk the mock puppet around a small square, in the room the game told us
        t = int(now) % 40
        x = 620 + (t if t < 10 else 10 if t < 20 else (30 - t) if t < 30 else 0)
        y = 620 + (0 if t < 10 else (t - 10) if t < 20 else 10 if t < 30 else (40 - t))
        self.send(pos(x, y, angle=0, facing=1, sprite=-1, image=0, room=self.room))


def run_client(host: str, port: int) -> None:
    log(f"connecting to game host {host}:{port}")
    s = socket.create_connection((host, port), timeout=5)
    peer = Peer(s, is_host=False)
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
    ap.add_argument("mode", choices=["client", "server", "probe"])
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=6511)
    args = ap.parse_args()
    try:
        if args.mode == "client":
            run_client(args.host, args.port)
        elif args.mode == "probe":
            run_probe(args.host, args.port, settle=4.0)
        else:
            run_server(args.port)
    except KeyboardInterrupt:
        log("bye")
    return 0


if __name__ == "__main__":
    sys.exit(main())
