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

NAMES = re.compile(r"\b([A-Za-z_][A-Za-z0-9_]*)\s*\(")
DEFINE = re.compile(r"^\s*#define\s+([A-Za-z_][A-Za-z0-9_]*)"
                    r"(?:\s*\(([^)]*)\))?", re.M)


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
        if fn[0].isupper():
            continue                    # ObjFoo.bar() style, not a builtin
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
        blocks = find_defines(text)
        if not blocks:
            problems.append(f"{where}: no #define found")
        for name, line, body in blocks:
            check_value_macro(name, line, body, str(where), problems)
            check_balance(name, line, body, str(where), problems)
            check_var_names(name, line, body, str(where), problems)
            check_calls(name, line, body, str(where), arities, symbols, missing,
                        problems, warns)

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
