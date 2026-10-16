import argparse
import array
import json
import re
import shutil
import subprocess
import sys
import tempfile
import wave
from pathlib import Path

from resource import replace_data_block
from vpk import VpkReader, write_vpk

ROOT = Path(__file__).resolve().parent.parent
MOD = ROOT / "mod"
ADDON = "hit_feedback"
DEFAULT_GAME = Path(r"C:\Program Files (x86)\Steam\steamapps\common\Deadlock")
DEFAULT_CSDK = Path(r"C:\Users\shaft\Documents\Reduced_CSDK_12")
DEFAULT_S2V = Path(r"C:\Users\shaft\Documents\Source2Viewer-CLI\Source2Viewer-CLI.exe")
ENCODING = """<!-- kv3 encoding:text:version{e21c7f3c-8a33-41c5-9977-a76d3a32aa0d} format:generic:version{7412167c-06e9-4698-aff2-e63eb59037e7} -->
{
\tcompress =
\t{
\t\tformat = "mp3"
\t\tminbitrate = 128
\t\tmaxbitrate = 320
\t\tvbr = 1
\t}
}
"""


def write_with_gain(source, destination, gain):
    if gain == 1.0:
        shutil.copyfile(source, destination)
        return 0
    with wave.open(str(source), "rb") as reader:
        params = reader.getparams()
        frames = reader.readframes(params.nframes)
    if params.sampwidth != 2:
        sys.exit(f"{source} must be 16-bit PCM to apply gain")
    samples = array.array("h", frames)
    clipped = 0
    for index, sample in enumerate(samples):
        value = round(sample * gain)
        if value > 32767 or value < -32768:
            clipped += 1
            value = max(-32768, min(32767, value))
        samples[index] = value
    with wave.open(str(destination), "wb") as writer:
        writer.setparams(params)
        writer.writeframes(samples.tobytes())
    return clipped


def load_json(name):
    path = MOD / name
    return json.loads(path.read_text("utf-8")) if path.is_file() else {}


def prepare_sounds(content):
    config = load_json("sounds.json")
    gain = config.get("gain", 1.0)
    (content / "sounds").mkdir(parents=True, exist_ok=True)
    (content / "sounds" / "encoding.txt").write_text(ENCODING)

    sources = {}
    for target, source in config.get("sounds", {}).items():
        source_path = MOD / source
        if not source_path.is_file():
            sys.exit(f"missing sound {source_path}")
        destination = content / f"{target}{source_path.suffix}"
        destination.parent.mkdir(parents=True, exist_ok=True)
        clipped = write_with_gain(source_path, destination, gain)
        if clipped:
            print(f"warning: {source} clipped {clipped} samples at gain {gain}")
        sources[destination] = f"{target}.vsnd_c"
    return sources


EVENT = re.compile(r"^\t([\w.\-]+) = \n\t\{\n(.*?)^\t\}\n", re.MULTILINE | re.DOTALL)
BASE = re.compile(r'^\t\tbase = "([^"]+)"', re.MULTILINE)
SILENT = "sounds/common/null.vsnd"


def decompile_soundevents(s2v, game_citadel, output):
    result = subprocess.run(
        [str(s2v), "-i", str(game_citadel / "pak01_dir.vpk"), "--vpk_filepath", "soundevents/", "--vpk_extensions", "vsndevts_c", "-d", "-o", str(output)],
        capture_output=True,
        text=True,
        errors="replace",
    )
    texts = {path.relative_to(output).as_posix(): path.read_text("utf-8") for path in output.rglob("*.vsndevts")}
    if result.returncode != 0 or not texts:
        sys.exit(f"could not decompile soundevents\n{result.stdout}{result.stderr}")
    return texts


def kv3_value(value):
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, str):
        return f'"{value}"'
    return repr(float(value))


def set_field(body, key, value):
    line = f"\t\t{key} = {value}\n"
    field = re.compile(r"^\t\t" + re.escape(key) + r" = (?:\n\t\t\[\n.*?^\t\t\]|[^\n]*)\n", re.MULTILINE | re.DOTALL)
    body, count = field.subn(lambda _: line, body, count=1)
    return body if count else body + line


def override_event(text, event, override):
    files = override.get("files")
    fields = override.get("set", {})

    def replace(match):
        if match.group(1) != event:
            return match.group(0)
        body = match.group(2)
        if files is not None:
            lines = "".join(f'\t\t\t"{path}",\n' for path in files)
            body = set_field(body, "vsnd_files", f"\n\t\t[\n{lines}\t\t]")
        for key, value in fields.items():
            body = set_field(body, key, kv3_value(value))
        return f"\t{event} = \n\t{{\n{body}\t}}\n"

    updated = EVENT.sub(replace, text)
    if updated == text and f"\t{event} = \n" not in text:
        sys.exit(f"event {event} not found")
    return updated


def silenced_events(texts, roots):
    bases = {}
    for resource, text in texts.items():
        for name, body in EVENT.findall(text):
            base = BASE.search(body)
            bases[name] = (resource, base.group(1) if base else None)

    def descends(name):
        seen = set()
        while name and name not in seen:
            if name in roots:
                return True
            seen.add(name)
            name = bases.get(name, (None, None))[1]
        return False

    found = {}
    for name, (resource, _) in bases.items():
        if descends(name):
            found.setdefault(resource, {})[name] = {"files": [SILENT]}
    return found


VOLUME = re.compile(r"^\t\tvolume = (-?[\d.]+)$", re.MULTILINE)


def effective_volume(bodies, name):
    seen = set()
    while name in bodies and name not in seen:
        seen.add(name)
        volume = VOLUME.search(bodies[name])
        if volume:
            return float(volume.group(1))
        base = BASE.search(bodies[name])
        name = base.group(1) if base else None
    return 0.0


def prepare_soundevents(content, s2v, game_citadel):
    config = load_json("soundevents.json")
    if not config:
        return {}
    if not s2v.is_file():
        sys.exit(f"missing {s2v}")

    sources = {}
    with tempfile.TemporaryDirectory() as scratch:
        texts = decompile_soundevents(s2v, game_citadel, Path(scratch))
        overrides = silenced_events(texts, set(config.get("silence", [])))
        bodies = {name: body for text in texts.values() for name, body in EVENT.findall(text)}
        offset = config.get("volume_offset_db", 0.0)
        for resource, events in config.get("events", {}).items():
            for event, override in events.items():
                if offset:
                    fields = dict(override.get("set", {}))
                    fields["volume"] = round(effective_volume(bodies, event) + offset, 3)
                    override = {**override, "set": fields}
                overrides.setdefault(resource, {})[event] = override

        for resource, events in sorted(overrides.items()):
            if resource not in texts:
                sys.exit(f"{resource} not found in game soundevents")
            text = texts[resource]
            for event, override in events.items():
                text = override_event(text, event, override)
            destination = content / resource
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_text(text, "utf-8", newline="\n")
            sources[destination] = f"{resource}_c"
        print(f"overriding {sum(len(events) for events in overrides.values())} events in {len(overrides)} soundevent files")
    return sources


def compile_addon(csdk, s2v, game_citadel):
    compiler = csdk / "game" / "bin_cs2" / "win64" / "resourcecompiler.exe"
    if not compiler.is_file():
        sys.exit(f"missing {compiler}")

    content = csdk / "content" / "citadel_addons" / ADDON
    game = csdk / "game" / "citadel_addons" / ADDON
    for folder in (content, game):
        for child in ("sounds", "soundevents"):
            shutil.rmtree(folder / child, ignore_errors=True)
    game.mkdir(parents=True, exist_ok=True)
    addoninfo = game / "addoninfo.txt"
    if not addoninfo.is_file():
        addoninfo.write_text('"AddonInfo"\n{\n\t"IsTemplate"\t"0"\n\t"IsPlayable"\t"0"\n}\n')

    sources = prepare_sounds(content)
    soundevents = prepare_soundevents(content, s2v, game_citadel)
    sources.update(soundevents)
    if not sources:
        return {}

    filelist = content / "filelist.txt"
    filelist.write_text("\n".join(str(path) for path in sources) + "\n")
    result = subprocess.run(
        [str(compiler), "-nop4", "-f", "-filelist", str(filelist)],
        cwd=compiler.parent,
        capture_output=True,
        text=True,
        errors="replace",
    )
    filelist.unlink()
    if result.returncode != 0 or " 0 failed" not in result.stdout:
        sys.exit(result.stdout + result.stderr)

    stock = VpkReader(game_citadel / "pak01_dir.vpk") if soundevents else None
    files = {}
    for compiled_path in sources.values():
        compiled = game / compiled_path
        if not compiled.is_file():
            sys.exit(f"compiler did not produce {compiled}")
        data = compiled.read_bytes()
        if compiled_path in soundevents.values():
            data = replace_data_block(stock.read(compiled_path), data)
        files[compiled_path] = data
    return files


def collect_files(csdk, s2v, game_citadel):
    files = {}

    raw = MOD / "files"
    if raw.is_dir():
        for path in raw.rglob("*"):
            if path.is_file() and path.name != ".gitkeep":
                files[path.relative_to(raw).as_posix()] = path.read_bytes()

    files.update(compile_addon(csdk, s2v, game_citadel))
    return files


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--game", type=Path, default=DEFAULT_GAME)
    parser.add_argument("--csdk", type=Path, default=DEFAULT_CSDK)
    parser.add_argument("--s2v", type=Path, default=DEFAULT_S2V)
    parser.add_argument("--pak", type=int, default=9)
    parser.add_argument("--install", action="store_true")
    args = parser.parse_args()

    if not 1 <= args.pak <= 99:
        sys.exit("--pak must be between 1 and 99")

    game_citadel = args.game / "game" / "citadel"
    files = collect_files(args.csdk, args.s2v, game_citadel)
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
