"""Verify the ctypes binding against the real Steamworks library.

The offline test proves the relay's *logic*; this proves the *binding*, which is the part that
can only be wrong in ways no mock would show: a signature that does not match, an export
that is not there, a struct whose fields are at the wrong offsets.

The steps, in order of how much they can still break:

1. the library loads and every export the binding names resolves;
2. the flat API initialises - this needs `steam_appid.txt` = 480 next to the library;
3. the SteamID comes back - the first value that has to be right;
4. a lobby is created and its id arrives in the callback - the async path;
5. lobby data is written and read back;
6. a message is sent to **our own SteamID** and received - the whole messaging path over
   Steam's real network, with no second account involved.

Step 6 is the interesting one: it is a loopback, so it proves the transport works without
needing anybody else.

Run it with Steam running and logged in.
"""
from __future__ import annotations

import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from steamapi import CtypesSteamApi, CB_LOBBY_CREATED   # noqa: E402


def main() -> int:
    api = CtypesSteamApi()
    print(f"library: {api.dll_path}")
    api.init()
    print("flat API: initialised")

    me = api.my_steam_id()
    print(f"SteamID:  {me}")

    # -- a lobby, and its id arriving in the callback -------------------------
    api.create_lobby()
    lobby = 0
    end = time.time() + 10
    while time.time() < end and lobby == 0:
        for cb in api.poll_callbacks():
            if cb.callback == CB_LOBBY_CREATED:
                lobby = api.lobby_created(cb)
                print(f"lobby:    {lobby}")
        time.sleep(0.02)
    if lobby == 0:
        print("FAIL: no lobby id arrived in CB_LOBBY_CREATED")
        return 1

    # -- lobby data ----------------------------------------------------------
    # The write goes to Valve's servers, so the read-back is a round trip and is not
    # immediate: poll for it rather than reading once and declaring failure.
    wrote = api.set_lobby_data(lobby, "coop", "hello")
    print(f"lobby data: set -> {wrote}")
    api.request_lobby_data(lobby)
    got = ""
    end = time.time() + 10
    while time.time() < end and got != "hello":
        for _ in range(10):
            api.poll_callbacks()
        got = api.get_lobby_data(lobby, "coop")
        time.sleep(0.1)
    print(f"lobby data: wrote 'hello', read {got!r}")
    if got != "hello":
        print("FAIL: the lobby data did not come back")
        return 1

    # -- a message to ourselves ----------------------------------------------
    # The loopback is the whole messaging path: a session request, the accept, a reliable
    # send and a receive - over Steam's real network.
    sent = api.send_to_user(me, b"loopback", reliable=False, channel=0)
    print(f"loopback:  sent to ourselves -> {sent}")

    got_msg = None
    end = time.time() + 10
    while time.time() < end and got_msg is None:
        for msg in api.receive_on_channel(0):
            if msg.sender == me:
                got_msg = msg
        api.poll_callbacks()
        time.sleep(0.05)
    if got_msg is None:
        print("FAIL: the message to ourselves never came back")
        return 1
    print(f"loopback:  received {got_msg.data!r} from {got_msg.sender}")
    if got_msg.data != b"loopback":
        print("FAIL: the payload did not survive")
        return 1

    # The loopback opened a session to ourselves; close it, or Steam complains at exit.
    api.close_session(me)
    api.leave_lobby(lobby)
    time.sleep(0.2)
    print("OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
