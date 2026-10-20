"""An in-process stand-in for the Steam services the relay uses.

The relay's Steam side is a handful of calls: create or join a lobby, open a session to the
other side, and send bytes to them. None of that can be exercised without Steam running and a
second account, so this module implements the same behaviour in-process: two or more "peers"
that create lobbies, join each other's, and deliver messages to each other with a configurable
delay and loss rate.

That makes the relay's own logic - the TCP plumbing, the framing, the session handshake, the
lobby flow - testable offline, and it makes the *failure* modes testable too: a message can
be dropped or delayed on purpose, which is exactly what a real relay has to survive.

The API mirrors the slice of the Steamworks flat API that `steamapi.py` binds, and the callback
parameters use the **same layouts** (`LobbyCreated`, `LobbyEnter`, and the identity blob), so
the relay cannot tell the two apart and the parsing code is shared rather than duplicated.
"""
from __future__ import annotations

import itertools
import queue
import random
import threading
from dataclasses import dataclass, field

# The callback ids the real flat API uses. The relay matches on these.
CB_LOBBY_ENTER = 504
CB_LOBBY_CREATED = 513
CB_CALL_COMPLETED = 703
CB_SESSION_REQUEST = 1251
CB_SESSION_FAILED = 1252

LOBBY_TYPE_FRIENDS_ONLY = 1
IDENT_SIZE = 160


@dataclass
class Callback:
    """One callback from the Steam API, as the relay sees it."""
    callback: int
    param: bytes


@dataclass
class ReceivedMessage:
    """One message that arrived from another peer."""
    sender: int
    data: bytes
    channel: int = 0


@dataclass
class Lobby:
    lobby_id: int
    owner: int
    max_members: int = 4
    data: dict = field(default_factory=dict)
    members: set = field(default_factory=set)


def ident_bytes(steam_id: int) -> bytes:
    """The identity blob, with the SteamID where the real one has it.

    The real API fills this in with `SetSteamID64`, so its internal layout is the API's
    business - but the mock has to put the id somewhere the relay can read, and the identity's
    first field is the SteamID.
    """
    b = bytearray(IDENT_SIZE)
    b[0:8] = steam_id.to_bytes(8, "little")
    return bytes(b)


def ident_sid(buf: bytes) -> int:
    return int.from_bytes(buf[0:8], "little")


def lobby_created_lobby(param: bytes) -> int:
    """`LobbyCreated { int32 result; u64 lobby; }`."""
    return int.from_bytes(param[4:12], "little")


def lobby_entered_lobby(param: bytes) -> int:
    """`LobbyEnter { u64 lobby; u64 user_changed; u64 making_change; uint32 state; }`."""
    return int.from_bytes(param[0:8], "little")


def lobby_entered_member(param: bytes) -> int:
    return int.from_bytes(param[8:16], "little")


def _lobby_created_param(lobby_id: int) -> bytes:
    return (1).to_bytes(4, "little") + lobby_id.to_bytes(8, "little") + b"\x00" * 4


def _lobby_enter_param(lobby_id: int, member: int) -> bytes:
    return (lobby_id.to_bytes(8, "little")
            + member.to_bytes(8, "little")
            + member.to_bytes(8, "little")
            + (2).to_bytes(4, "little"))


class MockSteam:
    """The whole simulated Steam, shared by every peer in the process."""

    def __init__(self, delay: float = 0.0, loss: float = 0.0, seed: int = 1234):
        self.delay = delay
        self.loss = loss
        self._rng = random.Random(seed)
        self._lock = threading.RLock()
        self._lobbies: dict[int, Lobby] = {}
        self._next_lobby = itertools.count(1)
        self._peers: dict[int, "MockPeer"] = {}

    # -- internals -----------------------------------------------------------
    def register(self, peer: "MockPeer") -> None:
        with self._lock:
            self._peers[peer.steam_id] = peer

    def peer(self, steam_id: int) -> "MockPeer | None":
        with self._lock:
            return self._peers.get(steam_id)

    def _deliver(self, to_steam_id: int, message: ReceivedMessage) -> None:
        """Deliver a message, honouring the configured delay and loss."""
        if self.loss and self._rng.random() < self.loss:
            return
        peer = self.peer(to_steam_id)
        if peer is None:
            return
        if self.delay:
            timer = threading.Timer(self.delay, peer._inbound.put, (message,))
            timer.daemon = True
            timer.start()
        else:
            peer._inbound.put(message)

    # -- the API the relay uses ---------------------------------------------
    def create_lobby(self, owner: int, lobby_type: int = LOBBY_TYPE_FRIENDS_ONLY,
                     max_members: int = 4) -> int:
        with self._lock:
            lobby_id = next(self._next_lobby)
            lobby = Lobby(lobby_id, owner, max_members)
            lobby.members.add(owner)
            self._lobbies[lobby_id] = lobby
        return lobby_id

    def join_lobby(self, steam_id: int, lobby_id: int) -> bool:
        with self._lock:
            lobby = self._lobbies.get(lobby_id)
            if lobby is None or len(lobby.members) >= lobby.max_members:
                return False
            lobby.members.add(steam_id)
        # The owner is told, and so is the joiner.
        owner = self.peer(lobby.owner)
        if owner is not None:
            owner._callbacks.put(Callback(CB_LOBBY_ENTER,
                                          _lobby_enter_param(lobby_id, steam_id)))
        joiner = self.peer(steam_id)
        if joiner is not None:
            joiner._callbacks.put(Callback(CB_LOBBY_ENTER,
                                           _lobby_enter_param(lobby_id, steam_id)))
        return True

    def leave_lobby(self, steam_id: int, lobby_id: int) -> None:
        with self._lock:
            lobby = self._lobbies.get(lobby_id)
            if lobby:
                lobby.members.discard(steam_id)

    def get_lobby_owner(self, lobby_id: int) -> int:
        with self._lock:
            lobby = self._lobbies.get(lobby_id)
            return lobby.owner if lobby else 0

    def get_lobby_data(self, lobby_id: int, key: str) -> str:
        with self._lock:
            lobby = self._lobbies.get(lobby_id)
            return lobby.data.get(key, "") if lobby else ""

    def set_lobby_data(self, lobby_id: int, key: str, value: str) -> None:
        with self._lock:
            lobby = self._lobbies.get(lobby_id)
            if lobby:
                lobby.data[key] = value

    def accept_session(self, steam_id: int, target: int) -> None:
        """Accepting a session makes the connection usable for reliable sends.

        The real API completes the connection for **both** sides - the peer that accepted and
        the peer that asked - so the mock does the same. If it did not, the side that sent the
        first message could never send reliably, because it would never see itself as having
        a session.
        """
        peer = self.peer(steam_id)
        if peer is not None:
            peer._sessions.add(target)
        other = self.peer(target)
        if other is not None:
            other._sessions.add(steam_id)

    def close_session(self, steam_id: int, target: int) -> None:
        peer = self.peer(steam_id)
        if peer is not None:
            peer._sessions.discard(target)
        other = self.peer(target)
        if other is not None:
            other._sessions.discard(steam_id)

    def send_to_user(self, steam_id: int, target: int, data: bytes,
                     reliable: bool, channel: int) -> bool:
        """Send a message to another peer.

        The mock mirrors the real API's rules:

        * a send to a peer with **no session** is what creates one - the target is told with
          `CB_SESSION_REQUEST`, which is what makes it answer with `AcceptSessionWithUser`;
        * a **reliable** send needs an established session, and is refused without one.

        That is why the relay sends an unreliable hello before its first reliable message.

        "Established" means *with that peer*, which is the whole point: the check is whether
        the target is in this peer's session set, not whether the peer is in its own.
        """
        established = target in self._sessions_of(steam_id)
        if not established:
            peer = self.peer(target)
            if peer is not None:
                peer._callbacks.put(Callback(CB_SESSION_REQUEST, ident_bytes(steam_id)))
            if reliable:
                return False      # a reliable send needs an established session
        # **Only unreliable messages can be lost.** A reliable one is delivered, in order,
        # exactly once - that is what "reliable" means, and it is why the relay's data
        # channel can be reliable while the control channel cannot.
        if not reliable and self.loss and self._rng.random() < self.loss:
            return True          # accepted by the API, then dropped on the way
        self._deliver(target, ReceivedMessage(steam_id, data, channel))
        return True

    def _sessions_of(self, steam_id: int) -> set:
        peer = self.peer(steam_id)
        return peer._sessions if peer else set()


class MockPeer:
    """One participant in the mock Steam: its own queues, sessions and id.

    This is the object the relay talks to, and it presents the same methods as
    `CtypesSteamApi`.
    """

    CB_SESSION_REQUEST = CB_SESSION_REQUEST
    CB_LOBBY_CREATED = CB_LOBBY_CREATED
    CB_LOBBY_ENTER = CB_LOBBY_ENTER

    def __init__(self, steam: MockSteam, steam_id: int):
        self.steam = steam
        self.steam_id = steam_id
        self._inbound: "queue.Queue[ReceivedMessage]" = queue.Queue()
        self._callbacks: "queue.Queue[Callback]" = queue.Queue()
        self._sessions: set[int] = set()
        steam.register(self)

    # -- the API the relay uses ---------------------------------------------
    def my_steam_id(self) -> int:
        return self.steam_id

    def create_lobby(self, lobby_type: int = LOBBY_TYPE_FRIENDS_ONLY,
                     max_members: int = 4) -> int:
        """Ask for a lobby. The id arrives later, in the CB_LOBBY_CREATED callback."""
        lobby_id = self.steam.create_lobby(self.steam_id, lobby_type, max_members)
        self._callbacks.put(Callback(CB_LOBBY_CREATED, _lobby_created_param(lobby_id)))
        return 0

    def join_lobby(self, lobby_id: int) -> bool:
        return self.steam.join_lobby(self.steam_id, lobby_id)

    def leave_lobby(self, lobby_id: int) -> None:
        self.steam.leave_lobby(self.steam_id, lobby_id)

    def get_lobby_owner(self, lobby_id: int) -> int:
        return self.steam.get_lobby_owner(lobby_id)

    def get_lobby_data(self, lobby_id: int, key: str) -> str:
        return self.steam.get_lobby_data(lobby_id, key)

    def set_lobby_data(self, lobby_id: int, key: str, value: str) -> None:
        self.steam.set_lobby_data(lobby_id, key, value)

    def send_to_user(self, target: int, data: bytes, reliable: bool,
                     channel: int) -> bool:
        return self.steam.send_to_user(self.steam_id, target, data, reliable, channel)

    def receive_on_channel(self, channel: int) -> list[ReceivedMessage]:
        """Only the messages of that channel, as the real API does.

        The messages of the **other** channels are put back, not dropped: the real API keeps
        per-channel queues, so asking for one channel never loses another. A mock that threw
        them away would lose the data channel's traffic every time the control channel was
        polled first - which is exactly what happened.
        """
        out = []
        keep = []
        while True:
            try:
                msg = self._inbound.get_nowait()
            except queue.Empty:
                break
            if msg.channel == channel:
                out.append(msg)
            else:
                keep.append(msg)
        for msg in keep:
            self._inbound.put(msg)
        return out

    def accept_session(self, target: int) -> None:
        self.steam.accept_session(self.steam_id, target)

    def close_session(self, target: int) -> None:
        self.steam.close_session(self.steam_id, target)

    def poll_callbacks(self) -> list[Callback]:
        out = []
        while True:
            try:
                cb = self._callbacks.get_nowait()
            except queue.Empty:
                break
            out.append(cb)
        return out

    # -- the callback helpers the relay uses --------------------------------
    def session_request_sender(self, callback: Callback) -> int:
        return ident_sid(callback.param)

    def lobby_created(self, callback: Callback) -> int:
        return lobby_created_lobby(callback.param)

    def lobby_entered(self, callback: Callback) -> int:
        return lobby_entered_lobby(callback.param)
