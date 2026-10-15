import argparse
import json
import sys
from pathlib import Path

from vpk import VpkReader, write_vpk

ROOT = Path(__file__).resolve().parent.parent
MOD = ROOT / "mod"
DEFAULT_GAME = Path(r"C:\Program Files (x86)\Steam\steamapps\common\Deadlock")


def collect_files(game_citadel):
    files = {}

    raw = MOD / "files"
    if raw.is_dir():
        for path in raw.rglob("*"):
            if path.is_file() and path.name != ".gitkeep":
                files[path.relative_to(raw).as_posix()] = path.read_bytes()

    copies = MOD / "game_copies.json"
    if copies.is_file():
        reader = VpkReader(game_citadel / "pak01_dir.vpk")
        for target, source in json.loads(copies.read_text("utf-8")).items():
            if source not in reader.entries:
                sys.exit(f"{source} not found in game pak01")
            files[target] = reader.read(source)

    return files


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--game", type=Path, default=DEFAULT_GAME)
    parser.add_argument("--pak", type=int, default=9)
    parser.add_argument("--install", action="store_true")
    args = parser.parse_args()

    if not 1 <= args.pak <= 99:
        sys.exit("--pak must be between 1 and 99")

    game_citadel = args.game / "game" / "citadel"
    files = collect_files(game_citadel)
    if not files:
        sys.exit("nothing to pack")

    name = f"pak{args.pak:02d}_dir.vpk"
    output = ROOT / "dist" / name
    write_vpk(output, files)
    print(f"built {output}")
    for path in sorted(files):
        print(f"  {path}")

    if args.install:
        target = game_citadel / "addons" / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(output.read_bytes())
        print(f"installed {target}")


if __name__ == "__main__":
    main()
