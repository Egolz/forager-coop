"""Steam relay: a game's local TCP port, tunnelled over Steam.

Why it exists
-------------
The mod speaks plain TCP on port 6511. That works on a LAN, but across the internet it means
one of the two players needs a routable address and the other has to type it in, with port
forwarding on the router. This relay removes that: the game keeps talking TCP to
`127.0.0.1`, and the relay carries those bytes over Steam's own network, addressed by SteamID.

**The mod does not change at all.** Its join prompt already defaults to `127.0.0.1`, and its
host already listens on 6511:

    host side:  the game listens on 6511; the relay connects to 127.0.0.1:6511 when a peer
                arrives over Steam, and pipes between them.
    join side:  the relay listens on 6511; the game connects to 127.0.0.1:6511, and the relay
                pipes those bytes to the host over Steam.

Design
------
The reference for the Steam side is `cranebeaker/deus-ex-coop` (MIT), whose `steamlink/hxcoop.c`
does exactly this for a different game. Two things are deliberately different:

* **Reliability.** HXCoop sends game data as *unreliable* Steam messages, because Unreal
  Engine 1 does its own reliability on top. A TCP stream cannot: one lost byte and the game's
  framing is broken for good. So the data channel here is **reliable**, and the relay sends an
  unreliable hello first, because in the Steamworks API an unreliable send is what creates a
  session and a reliable send needs one.
* **Framing.** HXCoop puts a connection id in front of every message. That is what lets it
  serve several game connections at once; here there is one game connection per peer, so the
  byte stays (it keeps the two sides' framing identical) and is always zero.

Everything else - the lobby, the session handshake, the control channel with keep-alives -
follows the reference.

The Steam API is behind one small interface (`SteamApi`), so the relay runs unchanged against
the real `steam_api.dll` and against `mocksteam.py`, which is how the whole thing is tested
offline.
"""
from __future__ import annotations

import argparse
import socket
import sys
import threading
import time
from typing import Optional

CHANNEL_DATA = 0
CHANNEL_CTRL = 1

MSG_HELLO = b"H"      # unreliable: opens the session
MSG_READY = b"R"      # reliable: the session is up, data may flow
MSG_KEEPALIVE = b"K"  # reliable, once a second
MSG_BYE = b"B"        # reliable: goodbye

# The connection id that prefixes every data message. One game connection per peer here.
CONN_ID = 0


class Relay:
    """One end of the tunnel."""

    def __init__(self, api, mode: str, port: int, lobby_id: Optional[int] = None,
                 log=print):
        self.api = api
        self.mode = mode                  # "host" or "join"
        self.port = port
        self.lobby_id = lobby_id
        self.log = log

        self.lobby = 0
        self.peer_sid = 0                # the other side's SteamID
        self.session_ready = False       # the Steam session is established
        self.local: Optional[socket.socket] = None   # the socket to the game
        self.listener: Optional[socket.socket] = None
        self.stop = False
        self._pending: list[bytes] = []  # data that could not be sent yet
        self._last_keepalive = 0.0
        self._last_hello = 0.0

    # -- the local (game) side ----------------------------------------------
    def _open_listener(self) -> None:
        """Join side: listen where the game will connect."""
        self.listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.listener.bind(("127.0.0.1", self.port))
        self.listener.listen(1)
        self.listener.settimeout(0.2)
        self.log(f"relay: listening on 127.0.0.1:{self.port} for the game")

    def _connect_to_game(self) -> None:
        """Host side: the game is the server, so the relay dials it."""
        if self.local is not None:
            return
        try:
            s = socket.create_connection(("127.0.0.1", self.port), timeout=2.0)
        except OSError as exc:
            self.log(f"relay: cannot reach the game on 127.0.0.1:{self.port} ({exc})")
            return
        s.settimeout(0.05)
        self.local = s
        self.log("relay: connected to the game")

    def _accept_game(self) -> None:
        """Join side: take the connection the game makes."""
        if self.local is not None or self.listener is None:
            return
        try:
            conn, _ = self.listener.accept()
        except (socket.timeout, OSError):
            return
        conn.settimeout(0.05)
        self.local = conn
        self.log("relay: the game connected")

    # -- the Steam side -----------------------------------------------------
    def _pump_steam(self) -> None:
        """Run one frame of the Steam API and handle what comes back."""
        for callback in self.api.poll_callbacks():
            if callback.callback == self.api.CB_SESSION_REQUEST:
                # Somebody wants to talk to us: accept, then tell them we are ready.
                sender = self.api.session_request_sender(callback)
                self.log(f"relay: session request from {sender}")
                self.api.accept_session(sender)
                if not self.peer_sid:
                    self.peer_sid = sender
                self.api.send_to_user(sender, MSG_READY, reliable=True,
                                      channel=CHANNEL_CTRL)
                self.session_ready = True
                if self.mode == "host":
                    self._connect_to_game()
            elif callback.callback == self.api.CB_LOBBY_CREATED:
                self.lobby = self.api.lobby_created(callback)
                self.log(f"relay: lobby {self.lobby} - give this id to the other player")
            elif callback.callback == self.api.CB_LOBBY_ENTER:
                lobby = self.api.lobby_entered(callback)
                if self.mode == "join" and not self.peer_sid:
                    self.peer_sid = self.api.get_lobby_owner(lobby)
                    self.log(f"relay: joined lobby {lobby}, host is {self.peer_sid}")

        for msg in self.api.receive_on_channel(CHANNEL_CTRL):
            if msg.data == MSG_BYE:
                self.log("relay: the other side said goodbye")
                self.stop = True
            elif msg.data == MSG_READY:
                self.session_ready = True

        for msg in self.api.receive_on_channel(CHANNEL_DATA):
            if self.local is not None:
                try:
                    self.local.sendall(msg.data[1:])   # drop the connection id
                except OSError:
                    self.local = None

    # -- moving bytes -------------------------------------------------------
    def _drain_game(self) -> None:
        """Read whatever the game sent and push it towards Steam."""
        if self.local is None:
            return
        try:
            data = self.local.recv(65536)
        except (socket.timeout, BlockingIOError):
            return
        except OSError:
            self.local = None
            return
        if not data:
            self.local = None
            return
        self._pending.append(bytes([CONN_ID]) + data)

    def _flush_pending(self) -> None:
        """Send what we have, but only once the session can carry it.

        The session's state is not guessed: the **send itself** says. A reliable send to a
        peer with no session is refused by the API, and the data stays queued until it is
        accepted - so the queue is the thing that waits, not a flag that might be wrong.
        """
        if not self._pending or not self.peer_sid:
            return
        while self._pending:
            chunk = self._pending[0]
            ok = self.api.send_to_user(self.peer_sid, chunk, reliable=True,
                                       channel=CHANNEL_DATA)
            if not ok:
                return          # the session is not up yet; try again next tick
            self.session_ready = True
            self._pending.pop(0)

    def _keepalive(self) -> None:
        now = time.time()
        if self.peer_sid and now - self._last_keepalive >= 1.0:
            self._last_keepalive = now
            self.api.send_to_user(self.peer_sid, MSG_KEEPALIVE, reliable=True,
                                  channel=CHANNEL_CTRL)

    # -- the loop ------------------------------------------------------------
    def run(self) -> int:
        if self.mode == "host":
            # The lobby id is **not** known yet: `CreateLobby` is asynchronous, and the id
            # arrives in the CB_LOBBY_CREATED callback. The callback handler logs it.
            self.api.create_lobby()
        else:
            if not self.lobby_id:
                self.log("relay: join needs a lobby id")
                return 2
            self._open_listener()
            self.api.join_lobby(self.lobby_id)
            # The hello is unreliable on purpose: it is what opens the session.
            self.log(f"relay: joining lobby {self.lobby_id}")

        while not self.stop:
            self._pump_steam()
            if self.mode == "join":
                self._accept_game()
                if self.local is not None and self.peer_sid and not self.session_ready:
                    # The session does not exist until the host answers our hello. The hello
                    # is unreliable on purpose - an unreliable send is what opens a session in
                    # the Steamworks API - and it is repeated until the host's reliable "ready"
                    # comes back. At a steady 5 ms it would be a flood, so it is rate-limited.
                    now = time.time()
                    if now - self._last_hello >= 0.2:
                        self._last_hello = now
                        self.api.send_to_user(self.peer_sid, MSG_HELLO, reliable=False,
                                              channel=CHANNEL_CTRL)
            # **Both** sides read the game and push it towards Steam. The join side reads the
            # game the other way round: the game connects *to* the relay there, but the bytes
            # still have to travel to the host.
            self._drain_game()
            self._flush_pending()
            self._keepalive()
            time.sleep(0.005)

        self._say_goodbye()
        return 0

    def _say_goodbye(self) -> None:
        if self.peer_sid:
            self.api.send_to_user(self.peer_sid, MSG_BYE, reliable=True,
                                  channel=CHANNEL_CTRL)
        if self.lobby:
            self.api.leave_lobby(self.lobby)
        if self.local:
            try:
                self.local.close()
            except OSError:
                pass
        if self.listener:
            try:
                self.listener.close()
            except OSError:
                pass


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("mode", choices=["host", "join"])
    ap.add_argument("--port", type=int, default=6511,
                    help="the game's local TCP port (default 6511)")
    ap.add_argument("--lobby-id", type=int, default=None,
                    help="the host's lobby id (join mode)")
    ap.add_argument("--mock", action="store_true",
                    help="use the in-process mock instead of steam_api.dll")
    args = ap.parse_args(argv)

    if args.mock:
        from mocksteam import MockSteam, MockPeer
        api = MockPeer(MockSteam(), steam_id=1)
    else:
        from steamapi import CtypesSteamApi
        api = CtypesSteamApi()
        api.init()

    relay = Relay(api, args.mode, args.port, args.lobby_id)
    try:
        return relay.run()
    except KeyboardInterrupt:
        relay.stop = True
        return 0


if __name__ == "__main__":
    sys.exit(main())
