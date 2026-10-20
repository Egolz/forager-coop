#!/usr/bin/env python3
"""A tiny sanity checker for the mod's GML.

This is not a GML compiler, but it catches the mistakes that a mod makes quiet:
a mod whose code does not load just... does nothing, with no visible error.

  * unbalanced () [] {} inside a `#define` block (a truncated or mistyped macro)
  * the same `var` name declared twice at the same brace depth in one block
  * our own macros called with the wrong number of arguments
  * **calls to functions that do not exist in the game build** - checked against
    the build's own symbol table (`data.win`), which is the only reliable list:
    a name that is not in there fails at load time

Usage:
    python tools/check_gml.py [paths...] [--data-win PATH]

    paths default to Main.gml Net.gml Events.
    --data-win defaults to $env:FORAGER_DATA_WIN, else the usual Steam path.

Exit code: 0 clean, 1 problems, 2 warnings only.

Note: a mod compile is the only real check. This catches the boring failures so
a live test is spent on interesting ones.
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path

DEFAULT_DATA_WIN = Path(
    r"C:\Program Files (x86)\Steam\steamapps\common\Forager\data.win")

# Names used by PencilPal, the mod known to have run in this build. Only used as
# a fallback when no data.win is available to check against.
SEEN_IN_PENCILPAL = {
    "array_length", "array_create", "array_copy", "array_resize", "array_sort",
    "array_push", "array_pop", "array_join", "ds_list_to_array",
    "string_lower", "string_upper", "string_replace", "string_length", "string",
    "buffer_create", "buffer_write", "buffer_read", "buffer_delete", "buffer_tell",
    "buffer_seek", "buffer_get_size",
    "network_create_server", "network_create_socket", "network_destroy",
    "network_send_packet", "network_send_raw", "network_connect", "network_set_timeout",
    "instance_exists", "instance_create_depth", "instance_destroy", "instance_number",
    "object_get_name", "point_distance", "floor", "ceil", "round", "abs", "min", "max",
    "keyboard_check", "keyboard_check_pressed", "keyboard_clear", "keyboard_string",
    "show_debug_message", "get_string", "get_integer", "get_real",
    "draw_set_alpha", "draw_set_colour", "draw_set_halign", "draw_set_valign",
    "draw_text", "draw_circle_color", "display_get_width",
    "StructureGet", "TrueInstanceFind", "TrueInstanceNumber", "TrueInstanceExists",
    "Trace",
}

KEYWORDS = {"if", "for", "while", "switch", "with", "return", "repeat", "do", "until",
            "catch", "case", "and", "or", "not", "mod", "div", "var", "function", "new",
            "delete", "try", "else"}

# Names that sit in data.win's bytes but that a mod still cannot call: the loader
# resolves a mod's calls against its own function table, not against the build, so
# "the string is in data.win" is necessary but not sufficient. This list is what
# that costs when it is missed.
#
# Live evidence (2026-10-20): a COMPILE of Net.gml failed with
#     Mod failed to unit! Forager Coop/Net.gml[L453,c1] `ini_open` is not function or script
# while ini_open, ini_write_string, ini_write_real and ini_close all appear in
# data.win - the game writes its own secretSettings.ini with them. So the mod's
# dump cannot go to a file this way.
#
# Proven blocked: ini_open. Included by inference (same family, same call site
# pattern, not individually tested): the rest.
LOADER_BLOCKED = {
    "ini_open", "ini_close", "ini_write_string", "ini_write_real",
    "ini_read_string", "ini_read_real", "ini_key_exists", "ini_section_exists",
    "ini_key_delete", "ini_section_delete",
}

# Arity of the engine builtins this mod calls, as **this build's loader** reports them.
#
# The loader's own message is exact and cheap to read - "`sprite_get_yoffset` takes 1 argument,
# got 2" - but finding that out costs a round trip through the game (compile, launch, read the
# console, fix, repeat), and that is exactly the loop the wire-layout check below was written
# to break. So the arities learned from the loader are recorded here and checked locally.
#
# **This build's text functions are not GameMaker's.** The loader rejected the stock
# `draw_text_ext(x, y, string, color, alpha, alignment, xscale, yscale)` with "takes 5
# arguments, got 8", and the one mod that runs in this build shows the real shapes:
#
#     draw_text_ext(x, y, string, size, width)                                  5
#     draw_text_ext_transformed_color(x, y, string, size, width,
#                                     xscale, yscale, rotation,
#                                     c1, c2, c3, c4, alpha)                    13
#     draw_text_transformed_color(x, y, string, xscale, yscale, rotation,
#                                  c1, c2, c3, c4, alpha)                         11
#
# Live evidence:
#   2026-10-21  `sprite_get_yoffset` takes 1 argument - the subimage variant of the sprite
#               getters is not in this build, unlike in the GameMaker manual.
#   2026-10-21  `draw_text_ext` takes 5 arguments, and the two transformed variants take 13
#               and 11 - all copied from the reference mod's own calls, which render.
BUILTIN_ARITIES = {
    "sprite_get_yoffset": 1,
    "sprite_get_height": 1,
    "sprite_get_width": 1,
    "string_width": 1,
    "string_height": 1,
    "draw_sprite_ext": 9,
    "draw_text_ext": 5,
    "draw_text_ext_transformed_color": 13,
    "draw_text_transformed_color": 11,
}

NAMES = re.compile(r"\b([A-Za-z_][A-Za-z0-9_]*)\s*\(")
DEFINE = re.compile(r"^\s*#define\s+([A-Za-z_][A-Za-z0-9_]*)"
                    r"(?:\s*\(([^)]*)\))?", re.M)

# Wire layout (see check_wire_layout). The command byte is captured by name so the
# sender's byte can be compared with the `case` that reads it; everything else is a
# buffer_* type in the order it is written or read.
WRITE = re.compile(r"buffer_write\(\s*\w+\s*,\s*(CoopCmd|buffer_\w+)\s*,"
                   r"\s*(?:CoopCmd\.(\w+))?")
READ = re.compile(r"buffer_read\(\s*\w+\s*,\s*(buffer_\w+)\s*\)")
CASE = re.compile(r"case\s+CoopCmd\.(\w+)\s*:")


def strip_code(text: str) -> str:
    """Remove comments and string literals, keeping line structure."""
    out = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == "/" and i + 1 < n and text[i + 1] == "/":
            j = text.find("\n", i)
            i = n if j < 0 else j          # keep the newline itself
        elif c == "/" and i + 1 < n and text[i + 1] == "*":
            j = text.find("*/", i + 2)
            end = n if j < 0 else j + 2
            out.append("\n" * text.count("\n", i, end))
            i = end
        elif c == '"':
            j = i + 1
            while j < n and text[j] != '"':
                j += 2 if text[j] == "\\" else 1
            out.append('""')
            i = j + 1
        else:
            out.append(c)
            i += 1
    return "".join(out)


def find_defines(text: str) -> list[tuple[str, int, str]]:
    """[(name, line_no, body)] - a define runs until the next #define."""
    marks = [(m.start(), m.group(1), text[: m.start()].count("\n") + 1)
             for m in DEFINE.finditer(text)]
    blocks = []
    for idx, (pos, name, line) in enumerate(marks):
        end = marks[idx + 1][0] if idx + 1 < len(marks) else len(text)
        blocks.append((name, line, text[pos:end]))
    return blocks


def check_forbidden(where: str, text: str, problems: list[str]) -> None:
    """Constructs this build's mod compiler cannot compile at all.

    `try`/`catch` is the important one, and it is not a style preference: the
    loader compiles mod GML into its own AST, and a try_catch node makes that
    compiler give up. The game dies with

        ERROR in Other Event: User Defined 0 for object ModControl:
        Can't seekAllOut over Forager Coop/Net.gml[L150,c1] try_catch

    (the owner's error.log, live build, 2026-10-20) and the mod never loads. It
    also matches PencilPal's own TODO, "Fix recompile crashing game": that mod
    uses try/catch in Networking.gml and GUI.gml. Guard with an `if` instead.
    """
    for ln, line in enumerate(text.splitlines(), 1):
        m = re.search(r"\b(try|catch)\b", line)
        if m:
            problems.append(f"{where}:{ln}: `{m.group(1)}` - this loader cannot compile "
                            f"try/catch; the game crashes and the mod never loads. "
                            f"Use an `if` guard.")


def define_arity(body: str) -> int:
    head = DEFINE.match(body)
    if head is None or head.group(2) is None:
        return -1                       # a plain macro, e.g. #define Main
    return len([a for a in head.group(2).split(",") if a.strip()])


def check_value_macro(name: str, line: int, body: str, where: str,
                      problems: list[str]) -> None:
    """`#define NAME 448` is not a constant here.

    The loader reads a macro body as *statements*, so a bare value fails with
    "Expected a statement, got number" and the whole mod refuses to load - seen
    in the live build (Net.gml L137). Use a global instead.
    """
    head = DEFINE.match(body)
    if head is None or head.group(2) is not None:
        return
    rest = body[head.end():]
    rest = rest.split("\n", 1)[0].strip()
    if rest:
        problems.append(f"{where}:{line}: #define {name} {rest[:24]} - this loader has no "
                        f"value macros; a macro body must be statements. Use a global.")


def check_balance(name: str, line: int, body: str, where: str, problems: list[str]) -> None:
    pairs = {")": "(", "]": "[", "}": "{"}
    stack: list[tuple[str, int]] = []
    for off, ch in enumerate(body):
        if ch in "([{":
            stack.append((ch, line + body[:off].count("\n")))
        elif ch in ")]}":
            if not stack or stack[-1][0] != pairs[ch]:
                problems.append(f"{where}:{line + body[:off].count(chr(10))}: "
                                f"'{ch}' closes nothing in #define {name}")
                return
            stack.pop()
    for ch, ln in stack:
        problems.append(f"{where}:{ln}: '{ch}' opened in #define {name} is never closed")


def check_var_names(name: str, line: int, body: str, where: str, problems: list[str]) -> None:
    depth = 0
    seen: dict[tuple[int, str], int] = {}
    for off, text in enumerate(body.splitlines()):
        for ch in text:
            if ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
        for m in re.finditer(r"\bvar\s+([A-Za-z_][A-Za-z0-9_]*)", text):
            key = (depth, m.group(1))
            if key in seen:
                problems.append(f"{where}:{line + off}: 'var {m.group(1)}' declared twice "
                                f"at the same depth in #define {name} "
                                f"(first at line {seen[key]})")
            else:
                seen[key] = line + off


def check_wire_layout(files: list, problems: list[str]) -> None:
    """Sender and receiver must read the fields of a packet in the same order.

    This exists because they did not, and the cost was not a wrong number on screen.
    Three of the five payload packets (DROP, PICKUP, RESOURCE_DESTROY) wrote
    `u8 room, s32 x, s32 y, ...` and read `s32 x, s32 y, u8 room, ...`. The room
    test then compared a slice of a coordinate against the room number, so every
    incoming packet was discarded - and the item id handed to `DropItem()` was a
    slice of a coordinate, i.e. an arbitrary number, which is an out-of-range native
    read inside the game: `0xc0000005` at one fixed instruction, sixteen times in one
    evening (live evidence 2026-10-20, see NOTES.md).

    Nothing in the language catches this, the buffers are untyped and the wrong read
    silently returns a wrong number, so the check has to be here.
    """
    # Every packet's write order, keyed by the command it announces. Scanned across the
    # whole file rather than only inside `CoopSend*`: BYE and DEBUG_LINE are written from
    # the middle of other functions (CoopDisconnect and CoopSendDebugLine), and a check
    # that trusted the naming convention would quietly stop covering them.
    writers: dict[str, tuple[str, list[str]]] = {}
    readers: dict[str, list[str]] = {}
    defines = {f: find_defines(strip_code(f.read_text(encoding="utf-8-sig", errors="replace")))
               for f in files}

    for f, blocks in defines.items():
        where = f.name
        for name, _line, body in blocks:
            # A write whose value is `CoopCmd.X` starts a packet; the writes after it up to
            # the next command are its fields. The command byte itself is not a field.
            cur: str | None = None
            fields: list[str] = []
            for m in WRITE.finditer(body):
                if m.group(2):                      # `... , CoopCmd.X);`
                    if cur is not None:
                        writers.setdefault(cur, (f"{where}:{name}", list(fields)))
                    cur, fields = m.group(2), []
                    continue
                if cur is not None:
                    fields.append(m.group(1))
            if cur is not None:
                writers.setdefault(cur, (f"{where}:{name}", list(fields)))
        # the switch in CoopHandleData
        text = "\n".join(b for _, _, b in blocks)
        for m in CASE.finditer(text):
            cmd = m.group(1)
            rest = text[m.end():]
            nxt = CASE.search(rest)
            body = rest[: nxt.start()] if nxt else rest
            readers[cmd] = [m2.group(1) for m2 in READ.finditer(body)]

    for cmd, (wname, wrote) in sorted(writers.items()):
        read = readers.get(cmd)
        if read is None:
            problems.append(f"packet {cmd}: {wname} sends it and no `case CoopCmd.{cmd}:` "
                            f"reads it")
            continue
        if read != wrote:
            problems.append(f"packet {cmd}: {wname} writes {wrote} but the reader reads "
                            f"{read} - the field order must match")
    for cmd in sorted(readers):
        if cmd not in writers:
            problems.append(f"packet {cmd}: a reader exists and no CoopSend* writes it")


def check_calls(name: str, line: int, body: str, where: str, arities: dict[str, int],
                symbols: bytes | None, missing: set[str], problems: list[str],
                warns: list[str]) -> None:
    for m in NAMES.finditer(body):
        fn = m.group(1)
        ln = line + body[: m.start()].count("\n")
        if fn in KEYWORDS:
            continue
        if fn in arities and arities[fn] >= 0 and m.end() <= len(body):
            want = arities[fn]
            got = count_args(body, m.end() - 1)
            if got is not None and got != want:
                problems.append(f"{where}:{ln}: {fn}() called with {got} arguments, "
                                f"defined with {want}")
            continue
        if fn in arities:
            continue
        if fn in BUILTIN_ARITIES and m.end() <= len(body):
            want = BUILTIN_ARITIES[fn]
            got = count_args(body, m.end() - 1)
            if got is not None and got != want:
                problems.append(f"{where}:{ln}: {fn}() called with {got} arguments, but this "
                                f"build's loader takes {want} - COMPILE fails with "
                                f"\"`{fn}` takes {want} argument(s), got {got}\"")
            continue
        if fn[0].isupper():
            continue                    # ObjFoo.bar() style, not a builtin
        if fn in LOADER_BLOCKED:
            problems.append(f"{where}:{ln}: {fn}() is in data.win but NOT in the mod "
                            f"loader's function table - COMPILE fails with "
                            f"\"`{fn}` is not function or script\"")
            continue
        if symbols is not None:
            if fn.encode() not in symbols:
                missing.add(fn)
                problems.append(f"{where}:{ln}: {fn}() is not in the build's symbol "
                                f"table - it will fail at load time")
        elif fn not in SEEN_IN_PENCILPAL:
            warns.append(f"{where}:{ln}: calls {fn}() - not used by PencilPal and no "
                         f"data.win given to check against")


def count_args(text: str, open_paren: int) -> int | None:
    """Number of top-level arguments at that '(', or None if it never closes."""
    depth, commas, empty, i, n = 0, 0, True, open_paren, len(text)
    while i < n:
        c = text[i]
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
            if depth == 0:
                return 0 if empty else commas + 1
        elif c == "," and depth == 1:
            commas += 1
        elif depth >= 1 and not c.isspace():
            empty = False
        i += 1
    return None


def main(argv: list[str] | None = None) -> int:
    here = Path(__file__).resolve().parent.parent
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("paths", nargs="*", default=None)
    ap.add_argument("--data-win", default=os.environ.get("FORAGER_DATA_WIN"),
                    help="path to the game's data.win, for the symbol check")
    args = ap.parse_args(argv)

    targets = args.paths or ["Main.gml", "Net.gml", "Events"]
    files: list[Path] = []
    for t in targets:
        p = Path(t) if Path(t).is_absolute() else here / t
        files += sorted(p.rglob("*.gml")) if p.is_dir() else [p]
    files = [f for f in files if f.is_file()]

    data_win = Path(args.data_win) if args.data_win else DEFAULT_DATA_WIN
    symbols = None
    if data_win.is_file():
        symbols = data_win.read_bytes()
        print(f"symbol table: {data_win} ({len(symbols)} bytes)")
    else:
        print(f"symbol table: not found ({data_win}) - falling back to the "
              f"PencilPal list")

    stripped = {f: strip_code(f.read_text(encoding="utf-8-sig", errors="replace"))
                for f in files}
    arities: dict[str, int] = {}
    for text in stripped.values():
        for name, _, body in find_defines(text):
            arities[name] = define_arity(body)

    problems: list[str] = []
    warns: list[str] = []
    missing: set[str] = set()
    for f in files:
        text = stripped[f]
        where = f.relative_to(here) if here in f.parents else f
        check_forbidden(str(where), text, problems)
        blocks = find_defines(text)
        if not blocks:
            problems.append(f"{where}: no #define found")
        for name, line, body in blocks:
            check_value_macro(name, line, body, str(where), problems)
            check_balance(name, line, body, str(where), problems)
            check_var_names(name, line, body, str(where), problems)
            check_calls(name, line, body, str(where), arities, symbols, missing,
                        problems, warns)

    check_wire_layout(files, problems)

    for line in problems:
        print(f"ERROR {line}")
    for line in warns:
        print(f"warn  {line}")
    if missing and symbols is not None:
        print(f"\nmissing from the build: {', '.join(sorted(missing))}")
    print(f"\n{len(files)} file(s), {len(arities)} macro(s): "
          f"{len(problems)} problem(s), {len(warns)} warning(s)")
    if problems:
        return 1
    return 2 if warns else 0


if __name__ == "__main__":
    sys.exit(main())
