"""The Steamworks flat API, bound for ctypes - and the layouts the relay needs.

Why the *flat* API
------------------
The flat API is a C-style entry point: every function is an ordinary export that takes the
interface pointer as its first argument. That matters here, because it means the binding is a
list of function signatures and **no C++ vtable has to be reproduced**. The reference
implementation (`cranebeaker/deus-ex-coop`, MIT) does the same thing by hand with
`GetProcAddress`, and the comments there are the source for the signatures below.

Why not the game's own `steam_api.dll`
---------------------------------------
Forager ships one, and it is 32-bit with the full lobby API - but it is from 2019 and has
**no `ISteamNetworkingMessages`**, the interface that actually carries bytes. The modern
standalone release is needed, and since the relay is a **separate process** it may be 64-bit,
which is what a 64-bit Python can load. (The game itself is 32-bit and never loads this
library; that is why the two bitnesses do not clash.)

Layouts
-------
Two structures have to be read by hand, and both are layout-sensitive:

* `SteamNetworkingMessage_t` - the data pointer and the size. Their offsets differ between
  32-bit and 64-bit builds, and so does the offset of the embedded identity, so the
  constants below are chosen from the running interpreter's bitness.
* the lobby callbacks - small structs whose fields are read by offset.

`SteamNetworkingIdentity_t` itself is **not** read by hand: the API provides
`SetSteamID64`/`GetSteamID64`, and the relay uses those, so the identity's internal layout
never has to be known.
"""
from __future__ import annotations

import ctypes
import os
import struct
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

# -- callback ids the relay matches on ---------------------------------------
CB_LOBBY_ENTER = 504
CB_LOBBY_CREATED = 513
CB_CALL_COMPLETED = 703
CB_SESSION_REQUEST = 1251
CB_SESSION_FAILED = 1252

# -- the identity blob the API fills in --------------------------------------
IDENT_SIZE = 160

# -- the message struct ------------------------------------------------------
# struct SteamNetworkingMessage_t { void *m_pData; int32 cbSize; SteamNetworkingIdentity_t
# m_identity; ... };
#
# The identity's offset is **16 in both bitnesses**, not 8 or 12: the identity starts with a
# uint64, so it is 8-byte aligned, and it lands after the pointer, the size and the padding
# that keeps it aligned. The size's offset *does* differ - it is 4 on 32-bit and 8 on 64-bit,
# because the pointer is 8 bytes wide there.
#
# These are the hub playbook's numbers (playbook/networking-steam-spacewar.md), and they were
# worth checking against the code rather than deriving: the first draft of this file had the
# identity at 12 on 64-bit, which would have decoded every sender as SteamID 0.
IS_64 = struct.calcsize("P") == 8
MSG_DATA_OFF = 0
MSG_SIZE_OFF = 8 if IS_64 else 4
MSG_IDENT_OFF = 16
MSG_IDENT_FALLBACK_OFF = 12   # tried when the identity at 16 decodes as SteamID 0

# -- the lobby callback structs ----------------------------------------------
# LobbyCreated { int32 result; u64 lobby; } and
# LobbyEnter  { u64 lobby; u64 user_changed; u64 making_change; uint32 state; }
#
# **The lobby id's offset depends on the bitness.** `LobbyCreated` holds a uint64 after an
# int32, and a uint64 is 8-byte aligned, so on 64-bit the id sits at offset **8**, not 4 -
# there are four bytes of padding in between. The reference implementation is 32-bit, where
# the id is at 4, and reading it at 4 on 64-bit yields a number that looks like a lobby id and
# is not one: every later call with it fails.
LOBBY_CREATED_RESULT_OFF = 0
LOBBY_CREATED_LOBBY_OFF = 8 if IS_64 else 4
LOBBY_ENTER_LOBBY_OFF = 0

# -- send flags --------------------------------------------------------------
SEND_UNRELIABLE_NO_NAGLE = 1
SEND_RELIABLE = 8

LOBBY_TYPE_FRIENDS_ONLY = 1

LOBBY_DATA_KEY = "coop"      # the lobby key the host sets for the joiner to look for


class CallbackMsg(ctypes.Structure):
    """`struct CallbackMsg { int32 user; int32 callback; uint8 *param; int32 param_size; }`.

    Defined once at module level, because the argument type has to be the *same* class the
    call is made with: ctypes refuses a `byref` where a `POINTER(T)` is declared, and it
    refuses an instance where a pointer is declared. One class, one pointer.
    """
    _fields_ = [("user", ctypes.c_int32),
                ("callback", ctypes.c_int32),
                ("param", ctypes.POINTER(ctypes.c_uint8)),
                ("param_size", ctypes.c_int32)]


class APICallCompleted(ctypes.Structure):
    """`struct APICallCompleted { uint64 call; int32 callback; uint32 param_size; }`."""
    _fields_ = [("call", ctypes.c_uint64),
                ("callback", ctypes.c_int32),
                ("param_size", ctypes.c_uint32)]


@dataclass
class Callback:
    """One callback from the Steam API."""
    callback: int
    param: bytes


@dataclass
class ReceivedMessage:
    """One message that arrived from another peer."""
    sender: int
    data: bytes
    channel: int = 0


def lobby_created_lobby(param: bytes) -> int:
    return int.from_bytes(param[LOBBY_CREATED_LOBBY_OFF:
                               LOBBY_CREATED_LOBBY_OFF + 8], "little")


def lobby_created_result(param: bytes) -> int:
    return int.from_bytes(param[LOBBY_CREATED_RESULT_OFF:
                               LOBBY_CREATED_RESULT_OFF + 4], "little", signed=True)


def lobby_entered_lobby(param: bytes) -> int:
    return int.from_bytes(param[LOBBY_ENTER_LOBBY_OFF:LOBBY_ENTER_LOBBY_OFF + 8], "little")


def lobby_entered_member(param: bytes) -> int:
    return int.from_bytes(param[8:16], "little")


class CtypesSteamApi:
    """The real Steamworks API, loaded from `steam_api.dll` next to this file."""

    # The callback ids, so the relay can match on them without importing this module.
    CB_SESSION_REQUEST = CB_SESSION_REQUEST
    CB_LOBBY_CREATED = CB_LOBBY_CREATED
    CB_LOBBY_ENTER = CB_LOBBY_ENTER

    def __init__(self, dll_path: Optional[Path] = None):
        self.dll_path = dll_path or self._default_dll_path()
        self.dll = None
        self._fn = {}
        self._pipe = 0
        self._user = None
        self._mm = None
        self._friends = None
        self._msgs = None
        self._utils = None

    @staticmethod
    def _default_dll_path() -> Path:
        name = "steam_api64.dll" if IS_64 else "steam_api.dll"
        return Path(__file__).resolve().parent / name

    # -- loading --------------------------------------------------------------
    def init(self) -> None:
        """Load the library and start the flat API. Raises on failure."""
        if not self.dll_path.exists():
            raise FileNotFoundError(
                f"{self.dll_path.name} not found next to this script. It comes from the "
                f"Steamworks.NET standalone release; see README.md.")

        # The flat API is the Spacewar app: steam_appid.txt must say 480.
        appid = self.dll_path.parent / "steam_appid.txt"
        if not appid.exists():
            appid.write_text("480", encoding="ascii")

        self.dll = ctypes.WinDLL(str(self.dll_path))
        self._load_functions()
        self._init_flat()

    def _load_functions(self) -> None:
        d = self.dll
        f = self._fn

        f["IsSteamRunning"] = d.SteamAPI_IsSteamRunning
        f["IsSteamRunning"].restype = ctypes.c_bool
        f["IsSteamRunning"].argtypes = []

        f["InitFlat"] = d.SteamAPI_InitFlat
        f["InitFlat"].restype = ctypes.c_int
        f["InitFlat"].argtypes = [ctypes.c_char_p]

        f["Shutdown"] = d.SteamAPI_Shutdown
        f["Shutdown"].restype = None
        f["Shutdown"].argtypes = []

        f["GetHSteamPipe"] = d.SteamAPI_GetHSteamPipe
        f["GetHSteamPipe"].restype = ctypes.c_int32
        f["GetHSteamPipe"].argtypes = []

        f["DispatchInit"] = d.SteamAPI_ManualDispatch_Init
        f["DispatchInit"].restype = None
        f["DispatchInit"].argtypes = []

        f["RunFrame"] = d.SteamAPI_ManualDispatch_RunFrame
        f["RunFrame"].restype = None
        f["RunFrame"].argtypes = [ctypes.c_int32]

        # The same CallbackMsg class the call is made with - one class, one pointer type.
        f["GetNextCallback"] = d.SteamAPI_ManualDispatch_GetNextCallback
        f["GetNextCallback"].restype = ctypes.c_bool
        f["GetNextCallback"].argtypes = [ctypes.c_int32, ctypes.POINTER(CallbackMsg)]

        f["FreeLastCallback"] = d.SteamAPI_ManualDispatch_FreeLastCallback
        f["FreeLastCallback"].restype = None
        f["FreeLastCallback"].argtypes = [ctypes.c_int32]

        # **This is how a call's result is actually obtained.** The flat API delivers a
        # CB_CALL_COMPLETED callback whose parameter is an APICallCompleted struct; the
        # result itself has to be fetched with GetAPICallResult, which also says whether the
        # call failed. A lobby id, for instance, is *not* in the callback parameter - reading
        # it from there gives a number that looks right and is not a lobby.
        f["GetAPICallResult"] = d.SteamAPI_ManualDispatch_GetAPICallResult
        f["GetAPICallResult"].restype = ctypes.c_bool
        f["GetAPICallResult"].argtypes = [ctypes.c_int32, ctypes.c_uint64, ctypes.c_void_p,
                                          ctypes.c_int, ctypes.c_int,
                                          ctypes.POINTER(ctypes.c_bool)]

        f["User"] = d.SteamAPI_SteamUser_v023
        f["User"].restype = ctypes.c_void_p
        f["User"].argtypes = []

        f["Matchmaking"] = d.SteamAPI_SteamMatchmaking_v009
        f["Matchmaking"].restype = ctypes.c_void_p
        f["Matchmaking"].argtypes = []

        f["Friends"] = d.SteamAPI_SteamFriends_v018
        f["Friends"].restype = ctypes.c_void_p
        f["Friends"].argtypes = []

        f["Messages"] = d.SteamAPI_SteamNetworkingMessages_SteamAPI_v002
        f["Messages"].restype = ctypes.c_void_p
        f["Messages"].argtypes = []

        f["Utils"] = d.SteamAPI_SteamNetworkingUtils_SteamAPI_v004
        f["Utils"].restype = ctypes.c_void_p
        f["Utils"].argtypes = []

        f["GetSteamID"] = d.SteamAPI_ISteamUser_GetSteamID
        f["GetSteamID"].restype = ctypes.c_uint64
        f["GetSteamID"].argtypes = [ctypes.c_void_p]

        f["CreateLobby"] = d.SteamAPI_ISteamMatchmaking_CreateLobby
        f["CreateLobby"].restype = ctypes.c_uint64
        f["CreateLobby"].argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int]

        f["JoinLobby"] = d.SteamAPI_ISteamMatchmaking_JoinLobby
        f["JoinLobby"].restype = ctypes.c_uint64
        f["JoinLobby"].argtypes = [ctypes.c_void_p, ctypes.c_uint64]

        f["LeaveLobby"] = d.SteamAPI_ISteamMatchmaking_LeaveLobby
        f["LeaveLobby"].restype = None
        f["LeaveLobby"].argtypes = [ctypes.c_void_p, ctypes.c_uint64]

        f["SetLobbyData"] = d.SteamAPI_ISteamMatchmaking_SetLobbyData
        f["SetLobbyData"].restype = ctypes.c_bool
        f["SetLobbyData"].argtypes = [ctypes.c_void_p, ctypes.c_uint64,
                                      ctypes.c_char_p, ctypes.c_char_p]

        f["GetLobbyData"] = d.SteamAPI_ISteamMatchmaking_GetLobbyData
        f["GetLobbyData"].restype = ctypes.c_char_p
        f["GetLobbyData"].argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.c_char_p]

        # The lobby's data lives on Valve's servers, so a reader has to ask for it first;
        # `GetLobbyData` alone can answer with an empty string.
        f["RequestLobbyData"] = d.SteamAPI_ISteamMatchmaking_RequestLobbyData
        f["RequestLobbyData"].restype = ctypes.c_bool
        f["RequestLobbyData"].argtypes = [ctypes.c_void_p, ctypes.c_uint64]

        f["GetLobbyOwner"] = d.SteamAPI_ISteamMatchmaking_GetLobbyOwner
        f["GetLobbyOwner"].restype = ctypes.c_uint64
        f["GetLobbyOwner"].argtypes = [ctypes.c_void_p, ctypes.c_uint64]

        f["SetRichPresence"] = d.SteamAPI_ISteamFriends_SetRichPresence
        f["SetRichPresence"].restype = ctypes.c_bool
        f["SetRichPresence"].argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p]

        f["IdentSet"] = d.SteamAPI_SteamNetworkingIdentity_SetSteamID64
        f["IdentSet"].restype = None
        f["IdentSet"].argtypes = [ctypes.c_void_p, ctypes.c_uint64]

        f["IdentGet"] = d.SteamAPI_SteamNetworkingIdentity_GetSteamID64
        f["IdentGet"].restype = ctypes.c_uint64
        f["IdentGet"].argtypes = [ctypes.c_void_p]

        f["SendMessageToUser"] = d.SteamAPI_ISteamNetworkingMessages_SendMessageToUser
        f["SendMessageToUser"].restype = ctypes.c_int
        f["SendMessageToUser"].argtypes = [ctypes.c_void_p, ctypes.c_void_p,
                                           ctypes.c_void_p, ctypes.c_uint32,
                                           ctypes.c_int, ctypes.c_int]

        f["ReceiveMessages"] = d.SteamAPI_ISteamNetworkingMessages_ReceiveMessagesOnChannel
        f["ReceiveMessages"].restype = ctypes.c_int
        f["ReceiveMessages"].argtypes = [ctypes.c_void_p, ctypes.c_int,
                                         ctypes.POINTER(ctypes.c_void_p), ctypes.c_int]

        f["AcceptSession"] = d.SteamAPI_ISteamNetworkingMessages_AcceptSessionWithUser
        f["AcceptSession"].restype = ctypes.c_bool
        f["AcceptSession"].argtypes = [ctypes.c_void_p, ctypes.c_void_p]

        f["CloseSession"] = d.SteamAPI_ISteamNetworkingMessages_CloseSessionWithUser
        f["CloseSession"].restype = ctypes.c_bool
        f["CloseSession"].argtypes = [ctypes.c_void_p, ctypes.c_void_p]

        f["MessageRelease"] = d.SteamAPI_SteamNetworkingMessage_t_Release
        f["MessageRelease"].restype = None
        f["MessageRelease"].argtypes = [ctypes.c_void_p]

        f["SetConfigInt"] = d.SteamAPI_ISteamNetworkingUtils_SetGlobalConfigValueInt32
        f["SetConfigInt"].restype = ctypes.c_bool
        f["SetConfigInt"].argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int32]

        f["InitRelay"] = d.SteamAPI_ISteamNetworkingUtils_InitRelayNetworkAccess
        f["InitRelay"].restype = None
        f["InitRelay"].argtypes = [ctypes.c_void_p]

    def _init_flat(self) -> None:
        f = self._fn
        if not f["IsSteamRunning"]():
            raise RuntimeError("Steam is not running. Start Steam, log in, and try again.")
        err = ctypes.create_string_buffer(1024)
        if f["InitFlat"](err) != 0:
            raise RuntimeError(f"SteamAPI_InitFlat failed: {err.value.decode(errors='replace')}")
        f["DispatchInit"]()
        self._pipe = f["GetHSteamPipe"]()
        self._user = f["User"]()
        self._mm = f["Matchmaking"]()
        self._friends = f["Friends"]()
        self._msgs = f["Messages"]()
        self._utils = f["Utils"]()
        try:
            f["InitRelay"](self._utils)
        except AttributeError:
            pass    # optional in older builds

    # -- the API the relay uses ---------------------------------------------
    def my_steam_id(self) -> int:
        return int(self._fn["GetSteamID"](self._user))

    def poll_callbacks(self) -> list[Callback]:
        """Run one frame and collect the callbacks it produced.

        A call's result does not arrive in the callback parameter - the parameter of
        CB_CALL_COMPLETED is an `APICallCompleted` struct, and the result has to be fetched
        with `GetAPICallResult`. So a completed call is **re-dispatched** under the inner
        callback id (513 for "lobby created"), carrying the result buffer.

        **The result is not always ready when the callback arrives.** The first
        `GetAPICallResult` for a fresh call can answer "not yet" - Steam is still fetching
        the app's config - and the reference implementation, which asks once and drops the
        result, loses the lobby id that way. So a call that is not ready is **kept and asked
        again** on the following frames, and only dropped when it has been pending too long.
        """
        f = self._fn
        f["RunFrame"](self._pipe)
        out: list[Callback] = []

        # A call that finished but whose result is not readable yet.
        if not hasattr(self, "_pending"):
            self._pending: dict[int, tuple[int, int, float]] = {}

        # Retry the calls that are waiting for their result.
        for call in list(self._pending):
            inner, psize, since = self._pending[call]
            buf = ctypes.create_string_buffer(psize + 16)
            failed = ctypes.c_bool(True)
            ok = f["GetAPICallResult"](self._pipe, call, buf, psize, inner,
                                       ctypes.byref(failed))
            if ok and not failed.value:
                out.append(Callback(inner, buf.raw[:psize]))
                del self._pending[call]
            elif time.time() - since > 20.0:
                del self._pending[call]

        msg = CallbackMsg()
        # The argument is declared as POINTER(CallbackMsg), so ctypes wants a **pointer
        # instance**; `ctypes.pointer` is what produces one. (Passing the struct itself, or
        # a byref of it, is the "expected LP_CallbackMsg instance instead of ..." error.)
        while f["GetNextCallback"](self._pipe, ctypes.pointer(msg)):
            if msg.callback == CB_CALL_COMPLETED and msg.param and msg.param_size >= 16:
                done = APICallCompleted.from_buffer_copy(
                    ctypes.string_at(msg.param, msg.param_size))
                self._pending[done.call] = (done.callback, done.param_size, time.time())
            else:
                param = b""
                if msg.param and msg.param_size > 0:
                    param = ctypes.string_at(msg.param, msg.param_size)
                out.append(Callback(msg.callback, param))
            f["FreeLastCallback"](self._pipe)
        return out

    def create_lobby(self, lobby_type: int = LOBBY_TYPE_FRIENDS_ONLY,
                     max_members: int = 4) -> int:
        """Ask for a lobby. The id arrives later, in the CB_LOBBY_CREATED callback."""
        self._fn["CreateLobby"](self._mm, lobby_type, max_members)
        return 0

    def join_lobby(self, lobby_id: int) -> None:
        self._fn["JoinLobby"](self._mm, lobby_id)

    def leave_lobby(self, lobby_id: int) -> None:
        self._fn["LeaveLobby"](self._mm, lobby_id)

    def get_lobby_owner(self, lobby_id: int) -> int:
        return int(self._fn["GetLobbyOwner"](self._mm, lobby_id))

    def get_lobby_data(self, lobby_id: int, key: str) -> str:
        ptr = self._fn["GetLobbyData"](self._mm, lobby_id, key.encode("utf-8"))
        return ptr.decode("utf-8", errors="replace") if ptr else ""

    def request_lobby_data(self, lobby_id: int) -> bool:
        """Ask for the lobby's data. Without this a read can answer with an empty string."""
        return bool(self._fn["RequestLobbyData"](self._mm, lobby_id))

    def set_lobby_data(self, lobby_id: int, key: str, value: str) -> bool:
        return bool(self._fn["SetLobbyData"](self._mm, lobby_id, key.encode("utf-8"),
                                              value.encode("utf-8")))

    def send_to_user(self, steam_id: int, data: bytes, reliable: bool,
                     channel: int) -> bool:
        """Send to a peer. Returns False when the session is not established yet."""
        ident = ctypes.create_string_buffer(IDENT_SIZE)
        self._fn["IdentSet"](ident, steam_id)
        flags = SEND_RELIABLE if reliable else SEND_UNRELIABLE_NO_NAGLE
        rc = self._fn["SendMessageToUser"](self._msgs, ident, data, len(data),
                                           flags, channel)
        return rc == 0 or rc == 1   # k_ERequestPending / k_OK both mean "accepted"

    def receive_on_channel(self, channel: int) -> list[ReceivedMessage]:
        out: list[ReceivedMessage] = []
        buf = (ctypes.c_void_p * 64)()
        n = self._fn["ReceiveMessages"](self._msgs, channel, buf, 64)
        for i in range(max(0, n)):
            msg_ptr = buf[i]
            if not msg_ptr:
                continue
            raw = ctypes.string_at(msg_ptr)
            data_ptr = ctypes.cast(msg_ptr, ctypes.POINTER(ctypes.c_void_p))[0]
            size = ctypes.cast(msg_ptr + MSG_SIZE_OFF, ctypes.POINTER(ctypes.c_int32))[0]
            data = ctypes.string_at(data_ptr, size) if data_ptr and size > 0 else b""
            sender = int(self._fn["IdentGet"](
                ctypes.cast(msg_ptr + MSG_IDENT_OFF, ctypes.c_void_p)))
            if sender == 0:
                # The identity did not decode at its documented offset; the reference
                # implementation falls back to 12 for the same reason.
                sender = int(self._fn["IdentGet"](
                    ctypes.cast(msg_ptr + MSG_IDENT_FALLBACK_OFF, ctypes.c_void_p)))
            out.append(ReceivedMessage(sender, data, channel))
            self._fn["MessageRelease"](msg_ptr)
        return out

    def accept_session(self, steam_id: int) -> None:
        ident = ctypes.create_string_buffer(IDENT_SIZE)
        self._fn["IdentSet"](ident, steam_id)
        self._fn["AcceptSession"](self._msgs, ident)

    def close_session(self, steam_id: int) -> None:
        ident = ctypes.create_string_buffer(IDENT_SIZE)
        self._fn["IdentSet"](ident, steam_id)
        self._fn["CloseSession"](self._msgs, ident)

    # -- the callback helpers the relay uses --------------------------------
    def session_request_sender(self, callback: Callback) -> int:
        buf = ctypes.create_string_buffer(callback.param, len(callback.param))
        return int(self._fn["IdentGet"](buf))

    def lobby_created(self, callback: Callback) -> int:
        """The lobby id, or 0 when the call reported a failure.

        The `result` field is checked because the reference implementation checks it too, and
        because a failed call still carries a buffer - reading the id out of it gives a number
        that looks like a lobby and is not one, and every later call with it fails.
        """
        if len(callback.param) < LOBBY_CREATED_LOBBY_OFF + 8:
            return 0
        if lobby_created_result(callback.param) != 1:
            return 0
        return lobby_created_lobby(callback.param)

    def lobby_entered(self, callback: Callback) -> int:
        return lobby_entered_lobby(callback.param)
