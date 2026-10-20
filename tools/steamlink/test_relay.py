"""Offline test of the Steam relay: bytes must survive the trip through Steam.

The relay is the piece that cannot be tested by looking at it, because the thing it gets
right is invisible when it is right: a byte that arrives is only interesting if the byte that
did **not** arrive is accounted for. So the test drives the whole path - a fake game server,
two relays, and a mock Steam between them - and checks that what goes in one end comes out
the other, in order, byte for byte.

Two shapes of the same check:

* **the game server's bytes reach the far end**, which is the host side of the tunnel;
* **the far end's bytes reach the game server**, which is the join side.

And one failure mode that matters: a **reliable** channel. The mock can be told to drop
messages, and the relay must still deliver the stream, because a TCP stream cannot survive a
lost byte.
"""
from __future__ import annotations

import socket
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from mocksteam import MockPeer, MockSteam   # noqa: E402
from relay import Relay                      # noqa: E402

HOST_GAME_PORT = 17800     # where the host's game listens
JOIN_GAME_PORT = 17801     # where the join relay listens for the game
TIMEOUT = 10.0


def wait_for(predicate, what: str, timeout: float = TIMEOUT) -> None:
    """Wait for something to become true, or fail the test."""
    end = time.time() + timeout
    while time.time() < end:
        if predicate():
            return
        time.sleep(0.01)
    raise AssertionError(f"timed out waiting for {what}")


def main() -> int:
    steam = MockSteam()
    host_api = MockPeer(steam, steam_id=1000)
    join_api = MockPeer(steam, steam_id=2000)

    # The host's game: a plain TCP server, exactly like the mod's `network_create_server`.
    game_server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    game_server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    game_server.bind(("127.0.0.1", HOST_GAME_PORT))
    game_server.listen(1)
    game_server.settimeout(0.2)
    game_conn: list[socket.socket] = []

    def accept_game():
        try:
            conn, _ = game_server.accept()
        except (socket.timeout, OSError):
            return
        conn.settimeout(0.2)
        game_conn.append(conn)

    threading.Thread(target=accept_game, daemon=True).start()

    logs: list[str] = []

    def log(msg: str) -> None:
        logs.append(msg)
        print("  " + msg)

    host_relay = Relay(host_api, "host", HOST_GAME_PORT, log=log)

    threading.Thread(target=host_relay.run, daemon=True).start()
    wait_for(lambda: host_relay.lobby != 0, "the host to create a lobby")
    lobby_id = host_relay.lobby
    print(f"host created lobby {lobby_id}")

    join_relay = Relay(join_api, "join", JOIN_GAME_PORT, lobby_id=lobby_id, log=log)
    threading.Thread(target=join_relay.run, daemon=True).start()
    wait_for(lambda: join_relay.peer_sid != 0, "the joiner to see the host")
    print(f"joiner sees host {join_relay.peer_sid}")

    # The join side's "game" connects to the relay's listener, as the mod does.
    join_game = socket.create_connection(("127.0.0.1", JOIN_GAME_PORT), timeout=2.0)
    join_game.settimeout(0.2)
    print("the join-side game connected to the relay")

    # The session has to exist before reliable traffic can flow.
    wait_for(lambda: host_relay.session_ready and join_relay.session_ready,
             "the Steam session to be established")
    wait_for(lambda: bool(game_conn), "the host relay to reach the game's server")
    print("the host relay is connected to the game")

    # -- host -> join --------------------------------------------------------
    payload = b"host says hello to the far side" * 40
    game_conn[0].sendall(payload)
    received = b""
    end = time.time() + TIMEOUT
    while len(received) < len(payload) and time.time() < end:
        try:
            chunk = join_game.recv(65536)
        except (socket.timeout, OSError):
            continue
        if not chunk:
            break
        received += chunk
    assert received == payload, (
        f"host -> join mismatch: sent {len(payload)} bytes, got {len(received)}")
    print(f"host -> join: {len(payload)} bytes arrived intact")

    # -- join -> host --------------------------------------------------------
    back = b"and the far side answers" * 40
    join_game.sendall(back)
    got = b""
    end = time.time() + TIMEOUT
    while len(got) < len(back) and time.time() < end:
        try:
            chunk = game_conn[0].recv(65536)
        except (socket.timeout, OSError):
            continue
        if not chunk:
            break
        got += chunk
    assert got == back, (
        f"join -> host mismatch: sent {len(back)} bytes, got {len(got)}")
    print(f"join -> host: {len(back)} bytes arrived intact")

    join_game.close()
    game_conn[0].close()
    game_server.close()
    host_relay.stop = True
    join_relay.stop = True
    time.sleep(0.1)
    print("OK")
    return 0


def test_with_loss() -> int:
    """The same, with the mock dropping messages.

    This is the case the reference implementation does not have to handle: it sends game data
    unreliably because its engine does its own reliability, and a TCP stream has none.
    """
    print("--- with 30% message loss ---")
    steam = MockSteam(loss=0.3, seed=7)
    host_api = MockPeer(steam, steam_id=1000)
    join_api = MockPeer(steam, steam_id=2000)

    game_server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    game_server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    game_server.bind(("127.0.0.1", HOST_GAME_PORT + 10))
    game_server.listen(1)
    game_server.settimeout(0.2)
    game_conn: list[socket.socket] = []

    def accept_game():
        try:
            conn, _ = game_server.accept()
        except (socket.timeout, OSError):
            return
        conn.settimeout(0.2)
        game_conn.append(conn)

    threading.Thread(target=accept_game, daemon=True).start()

    host_relay = Relay(host_api, "host", HOST_GAME_PORT + 10, log=lambda m: None)
    threading.Thread(target=host_relay.run, daemon=True).start()
    wait_for(lambda: host_relay.lobby != 0, "the host to create a lobby")
    join_relay = Relay(join_api, "join", JOIN_GAME_PORT + 10,
                       lobby_id=host_relay.lobby, log=lambda m: None)
    threading.Thread(target=join_relay.run, daemon=True).start()
    wait_for(lambda: join_relay.peer_sid != 0, "the joiner to see the host")

    join_game = socket.create_connection(("127.0.0.1", JOIN_GAME_PORT + 10), timeout=2.0)
    join_game.settimeout(0.2)
    wait_for(lambda: host_relay.session_ready and join_relay.session_ready,
             "the Steam session to be established")
    wait_for(lambda: bool(game_conn), "the host relay to reach the game's server")

    payload = b"a byte order that must not be broken" * 20
    game_conn[0].sendall(payload)
    received = b""
    end = time.time() + TIMEOUT
    while len(received) < len(payload) and time.time() < end:
        try:
            chunk = join_game.recv(65536)
        except (socket.timeout, OSError):
            continue
        if not chunk:
            break
        received += chunk
    assert received == payload, (
        f"with loss, host -> join mismatch: sent {len(payload)}, got {len(received)}")
    print(f"with 30% loss: {len(payload)} bytes still arrived intact")

    join_game.close()
    game_conn[0].close()
    game_server.close()
    host_relay.stop = True
    join_relay.stop = True
    time.sleep(0.1)
    return 0


if __name__ == "__main__":
    rc = main()
    if rc == 0:
        rc = test_with_loss()
    print("OK" if rc == 0 else "FAILED")
    sys.exit(rc)
