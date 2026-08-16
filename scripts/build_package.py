"""Build a MiuRead dev snapshot package and keep historical packages.

Usage:
    python scripts/build_package.py

Behaviour:
    - Reads the plugin version from miuread.koplugin/_meta.lua.
    - If a current package for a different version already exists, moves it
      into dist/archive/ instead of deleting it.
    - Writes dist/miuread-v<VERSION>-dev-full.zip and dist/SHA256SUMS.txt.
"""

import hashlib
import pathlib
import re
import shutil
import sys
import zipfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
PLUGIN = ROOT / "miuread.koplugin"
DIST = ROOT / "dist"
ARCHIVE = DIST / "archive"


def current_version() -> str:
    meta = (PLUGIN / "_meta.lua").read_text(encoding="utf-8")
    match = re.search(r'version\s*=\s*"([0-9]+\.[0-9]+\.[0-9]+)"', meta)
    if not match:
        raise SystemExit("无法从 _meta.lua 读取版本号")
    return match.group(1)


def package_name(version: str) -> str:
    return f"miuread-v{version}-dev-full.zip"


def archive_existing_package(new_name: str) -> None:
    DIST.mkdir(exist_ok=True)
    ARCHIVE.mkdir(exist_ok=True)
    for package in DIST.glob("miuread-v*-dev-full.zip"):
        if package.name == new_name:
            continue
        target = ARCHIVE / package.name
        if target.exists():
            package.unlink(missing_ok=True)
            print(f"removed duplicate current package: {package.name}")
            continue
        shutil.move(str(package), str(target))
        print(f"archived: {package.name}")


def build_package(version: str) -> pathlib.Path:
    name = package_name(version)
    target = DIST / name
    tmp = DIST / f".{name}.tmp"

    if tmp.exists():
        tmp.unlink()
    with zipfile.ZipFile(tmp, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for path in sorted(PLUGIN.rglob("*")):
            if path.is_dir():
                continue
            if path.name in {".DS_Store", "miuread.lua", "settings.reader.lua"}:
                continue
            if path.suffix.lower() in {".md", ".epub", ".log"}:
                continue
            archive.write(path, path.relative_to(ROOT).as_posix())

    target.unlink(missing_ok=True)
    tmp.replace(target)
    return target


def write_sha256(package: pathlib.Path) -> str:
    digest = hashlib.sha256(package.read_bytes()).hexdigest()
    (DIST / "SHA256SUMS.txt").write_text(
        f"{digest}  {package.name}\n", encoding="utf-8"
    )
    return digest


def main() -> int:
    version = current_version()
    name = package_name(version)
    archive_existing_package(name)
    package = build_package(version)
    digest = write_sha256(package)
    print(f"built: {package}")
    print(f"sha256: {digest}")
    print("历史包保留在 dist/archive/，本次未删除任何历史包。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
