"""Run the headless Lua 5.1 test suite (tests/lua/run.lua).

Preference order for the interpreter:
  1. `.tools/lua51.exe` (local bootstrap, see scripts/bootstrap_lua51.ps1)
  2. `lua5.1` on PATH
  3. any `lua` on PATH that reports Lua 5.1
The suite is skipped when none of these exists.
"""

import pathlib
import shutil
import subprocess
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
RUNNER = ROOT / "tests" / "lua" / "run.lua"


def _is_lua51(binary: pathlib.Path) -> bool:
    try:
        proc = subprocess.run(
            [str(binary), "-v"],
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return False
    return "Lua 5.1" in (proc.stdout or "") or "Lua 5.1" in (proc.stderr or "")


def _find_lua51():
    local = ROOT / ".tools" / "lua51.exe"
    if local.exists() and _is_lua51(local):
        return local
    for name in ("lua5.1", "lua"):
        found = shutil.which(name)
        if found and _is_lua51(pathlib.Path(found)):
            return pathlib.Path(found)
    return None


class LuaSuiteTests(unittest.TestCase):
    def test_lua_suite_passes(self):
        lua = _find_lua51()
        if lua is None:
            self.skipTest("no Lua 5.1 interpreter available (see scripts/bootstrap_lua51.ps1)")
        proc = subprocess.run(
            [str(lua), str(RUNNER)],
            cwd=ROOT,
            capture_output=True,
            text=True,
            timeout=120,
            check=False,
        )
        output = (proc.stdout or "") + (proc.stderr or "")
        self.assertEqual(
            0,
            proc.returncode,
            f"Lua suite failed (exit {proc.returncode})\n{output}",
        )
