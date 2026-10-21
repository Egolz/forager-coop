"""Does the checker catch the compile-time-arity class of bug offline?

This is the regression test for the round trip of 2026-10-22: a probe called
`ModEnemySpawn()` with no arguments, the loader answered with the exact arity *and* killed the
whole mod ("Mod failed to unit!"), because arity is checked at compile time. The fix records the
known count so the next wrong call is caught here, in a second, instead of costing a compile.

The test writes a tiny mod into a temp folder and runs the checker on it.
"""
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
CHECKER = os.path.join(HERE, "check_gml.py")


def run_case(body: str) -> str:
    d = tempfile.mkdtemp(prefix="coop_arity_")
    try:
        with open(os.path.join(d, "Main.gml"), "w", encoding="utf-8") as f:
            f.write("#define Main\n" + body + "\n")
        p = subprocess.run([sys.executable, CHECKER, d], capture_output=True, text=True)
        return p.stdout + p.stderr
    finally:
        shutil.rmtree(d, ignore_errors=True)


def main() -> int:
    failures = []

    out = run_case("ModEnemySpawn();")
    if "takes 4" not in out:
        failures.append("a short ModEnemySpawn() was not caught:\n" + out)

    out = run_case("ModEnemySpawn(1, 2, 3, 4);")
    if "ModEnemySpawn" in out:
        failures.append("a correct ModEnemySpawn(1,2,3,4) was wrongly flagged:\n" + out)

    out = run_case("EnemyCreate(1, 2);")
    if "arity this" not in out and "not recorded" not in out:
        failures.append("an unrecorded modding-API arity was not warned about:\n" + out)

    if failures:
        for f in failures:
            print("FAIL:", f)
        print("arity regression: FAILED")
        return 1
    print("arity regression: ok - the compile-time arity class of bug is caught offline")
    return 0


if __name__ == "__main__":
    sys.exit(main())
