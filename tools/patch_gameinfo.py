import argparse
import re
import shutil
import sys
from pathlib import Path

DEFAULT_GAME = Path(r"C:\Program Files (x86)\Steam\steamapps\common\Deadlock")

CITADEL_PATH = re.compile(rb"^([ \t]*)Game([ \t]+)citadel[ \t]*(\r?)$", re.MULTILINE)
REQUIRED_PATHS = [
    (b"Mod", b"citadel"),
    (b"Mod", b"core"),
    (b"Write", b"citadel"),
    (b"Game", b"citadel/addons"),
]
ADDON_CONFIG = re.compile(rb"^[ \t]*AddonConfig\b", re.MULTILINE)
FILESYSTEM = re.compile(rb"^([ \t]*)FileSystem[ \t]*\r?\n", re.MULTILINE)


def find_block_end(data, start):
    depth = 0
    index = data.index(b"{", start)
    while index < len(data):
        if data.startswith(b"//", index):
            index = data.index(b"\n", index)
            continue
        if data[index:index + 1] == b"{":
            depth += 1
        elif data[index:index + 1] == b"}":
            depth -= 1
            if depth == 0:
                return index + 1
        index += 1
    sys.exit("unbalanced braces in gameinfo.gi")


def patch(data):
    changed = False
    newline = b"\r\n" if b"\r\n" in data else b"\n"

    for key, value in REQUIRED_PATHS:
        existing = re.compile(rb"^[ \t]*" + key + rb"[ \t]+" + re.escape(value) + rb"[ \t]*\r?$", re.MULTILINE)
        if existing.search(data):
            continue
        match = CITADEL_PATH.search(data)
        if not match:
            sys.exit("could not find 'Game citadel' search path")
        padding = b"\t" * max(1, 4 - len(key) // 4)
        line = match.group(1) + key + padding + value + match.group(3) + b"\n"
        data = data[:match.start()] + line + data[match.start():]
        changed = True

    if not ADDON_CONFIG.search(data):
        match = FILESYSTEM.search(data)
        if not match:
            sys.exit("could not find FileSystem block")
        indent = match.group(1)
        end = find_block_end(data, match.end())
        block = (
            newline + newline
            + indent + b"AddonConfig" + newline
            + indent + b"{" + newline
            + indent + b'\t"UseOfficialAddons"\t"1"' + newline
            + indent + b"}"
        )
        data = data[:end] + block + data[end:]
        changed = True

    return data, changed


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--game", type=Path, default=DEFAULT_GAME)
    args = parser.parse_args()

    gameinfo = args.game / "game" / "citadel" / "gameinfo.gi"
    data, changed = patch(gameinfo.read_bytes())
    if not changed:
        print(f"{gameinfo} already mounts addons")
        return

    backup = gameinfo.with_name("gameinfo.gi.hitfeedback-backup")
    if not backup.exists():
        shutil.copyfile(gameinfo, backup)
    try:
        gameinfo.write_bytes(data)
    except PermissionError:
        sys.exit(f"cannot write {gameinfo}, close Deadlock and try again")
    print(f"patched {gameinfo}")
    print(f"backup at {backup}")


if __name__ == "__main__":
    main()
