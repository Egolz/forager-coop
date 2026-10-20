# steamlink - a Steam relay for the Forager co-op mod

Tunnels the mod's local TCP port over Steam, so two players need **no IP address and no port
forwarding**.

## Why this exists

The mod speaks plain TCP on port 6511. On a LAN that is fine, but across the internet one
player needs a routable address, the other has to type it in, and someone has to open a port
on a router. This relay removes that step: the game keeps talking TCP to `127.0.0.1`, and the
relay carries those bytes over Steam's own network, addressed by SteamID.

**The mod does not change at all.** Its join prompt already defaults to `127.0.0.1`, and its
host already listens on 6511:

| side | what happens |
|---|---|
| host | the game listens on 6511; the relay dials `127.0.0.1:6511` when a peer arrives over Steam and pipes between them |
| join | the relay listens on 6511; the game connects to `127.0.0.1:6511`, and the relay pipes those bytes to the host over Steam |

## How it works

The Steam side follows `cranebeaker/deus-ex-coop` (MIT), whose `steamlink/hxcoop.c` does the
same thing for a different game: a friends-only lobby, a session handshake, and the bytes on
a messaging channel. Two things are deliberately different:

- **Reliability.** HXCoop sends game data as *unreliable* Steam messages, because Unreal
  Engine 1 does its own reliability on top. A TCP stream cannot: one lost byte and the game's
  framing is broken for good. So the data channel here is **reliable**, and the relay sends an
  unreliable hello first - in the Steamworks API an unreliable send is what *creates* a
  session, and a reliable send needs one.
- **Framing.** A one-byte connection id prefixes every data message, as in the reference, so
  the two sides' framing stays identical. There is one game connection per peer, so the byte
  is always zero.

The Steam API is behind one small interface, so the same relay code runs against the real
`steam_api.dll` and against the in-process mock.

## Layout

| file | what it is |
|---|---|
| `relay.py` | the relay: host and join modes, the TCP side, the framing, the session |
| `steamapi.py` | the Steamworks flat API bound for ctypes, plus the layouts the relay reads |
| `mocksteam.py` | an in-process stand-in for Steam: lobbies, sessions, messages, loss |
| `test_relay.py` | the offline test: a fake game server, two relays, a mock Steam between them |

## Running it

```
python relay.py host  --port 6511
python relay.py join  --port 6511 --lobby-id <the number the host printed>
```

The host prints a lobby id; the joiner needs it. Both need Steam running and logged in.

## The offline test

```
python test_relay.py
```

It starts a fake game server, two relays and a mock Steam, and checks that the bytes that go
in one end come out the other, in order. It also runs with 30% of the **unreliable** messages
dropped, because that is the case the reference implementation does not have to handle.

## What still needs doing

- **The real library.** `steam_api64.dll` (64-bit, the flat API) and `steam_appid.txt` = 480
  have to sit next to the script. The standalone release of Steamworks.NET is the source; the
  hub's playbook (`playbook/networking-steam-spacewar.md`) pins the SHA-256 of the exact
  build. It has not been downloaded yet, so the ctypes binding is **unverified against the
  real library** - the offline test covers the relay's logic, not the binding.
- **Joining by friend.** The reference also finds the host through the friends list and rich
  presence, so the joiner does not have to be told a number. The lobby id is the first cut.
- **A second account.** The relay has only been run against the mock, because a real test
  needs two Steam accounts.

## Credits

The Steam side follows `hxcoop.c` from [cranebeaker/deus-ex-coop](https://github.com/cranebeaker/deus-ex-coop)
(MIT). This is an independent Python implementation; no code was copied, but the design, the
flat-API signatures and the callback layouts come from reading it.
