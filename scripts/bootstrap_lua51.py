"""Bootstrap a local Lua 5.1 interpreter for tests.

Usage:
    python scripts/bootstrap_lua51.py

Downloads the official Lua 5.1.5 sources into .tools/ and compiles
.tools/lua51.exe with gcc when the binary is missing. .tools/ is gitignored;
CI installs lua5.1 from apt instead and does not need this script.
"""

import pathlib
import shutil
import subprocess
import sys
import tarfile
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
TOOLS = ROOT / ".tools"
TARGET = TOOLS / "lua51.exe"
URL = "https://www.lua.org/ftp/lua-5.1.5.tar.gz"
ARCHIVE = TOOLS / "lua-5.1.5.tar.gz"
SRC = TOOLS / "lua-5.1.5" / "src"

CORE_SOURCES = (
    "lapi.c lcode.c ldebug.c ldo.c ldump.c lfunc.c lgc.c llex.c lmem.c "
    "lobject.c lopcodes.c lparser.c lstate.c lstring.c ltable.c ltm.c "
    "lundump.c lvm.c lzio.c lauxlib.c lbaselib.c ldblib.c liolib.c "
    "lmathlib.c loslib.c ltablib.c lstrlib.c loadlib.c linit.c"
).split()


def main() -> int:
    if TARGET.exists():
        print(f"already built: {TARGET}")
        return 0
    if shutil.which("gcc") is None:
        print("gcc not found; skip local Lua build (tests will use lua5.1 if present)", file=sys.stderr)
        return 0

    TOOLS.mkdir(exist_ok=True)
    if not SRC.exists():
        print(f"downloading {URL}")
        urllib.request.urlretrieve(URL, ARCHIVE)
        with tarfile.open(ARCHIVE, "r:gz") as tar:
            tar.extractall(TOOLS)

    sources = [str(SRC / name) for name in CORE_SOURCES] + [str(SRC / "lua.c")]
    print("compiling lua51.exe")
    subprocess.run(
        ["gcc", "-O2", "-DLUA_USE_WINDOWS", "-o", str(TARGET), *sources, "-lm"],
        check=True,
        cwd=ROOT,
    )
    print(f"built: {TARGET}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
