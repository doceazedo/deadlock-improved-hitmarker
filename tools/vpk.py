import hashlib
import struct
import zlib
from pathlib import Path

SIGNATURE = 0x55AA1234
VERSION = 2
EMBEDDED_ARCHIVE = 0x7FFF
ENTRY_TERMINATOR = 0xFFFF


def _split(path):
    path = path.replace("\\", "/").strip("/").lower()
    directory, _, filename = path.rpartition("/")
    stem, dot, extension = filename.rpartition(".")
    if not dot:
        stem, extension = filename, ""
    return directory or " ", stem, extension or " "


class VpkReader:
    def __init__(self, path):
        self.path = Path(path)
        self.entries = {}
        with self.path.open("rb") as handle:
            signature, version, tree_size = struct.unpack("<3I", handle.read(12))
            if signature != SIGNATURE:
                raise ValueError(f"{self.path} is not a VPK")
            header_size = 28 if version == 2 else 12
            handle.seek(header_size)
            tree = handle.read(tree_size)
        self.data_start = header_size + tree_size
        self._parse(tree)

    def _parse(self, tree):
        index = 0

        def read_string():
            nonlocal index
            end = tree.index(b"\0", index)
            value = tree[index:end].decode()
            index = end + 1
            return value

        while extension := read_string():
            while directory := read_string():
                while stem := read_string():
                    _, preload, archive, offset, length, _ = struct.unpack_from("<IHHIIH", tree, index)
                    index += 18
                    preload_bytes = tree[index:index + preload]
                    index += preload
                    path = stem if directory == " " else f"{directory}/{stem}"
                    if extension != " ":
                        path = f"{path}.{extension}"
                    self.entries[path] = (preload_bytes, archive, offset, length)

    def read(self, path):
        preload_bytes, archive, offset, length = self.entries[path.replace("\\", "/").lower()]
        if length == 0:
            return preload_bytes
        if archive == EMBEDDED_ARCHIVE:
            source = self.path
            offset += self.data_start
        else:
            source = self.path.with_name(self.path.name.replace("_dir.vpk", f"_{archive:03d}.vpk"))
        with source.open("rb") as handle:
            handle.seek(offset)
            return preload_bytes + handle.read(length)


def write_vpk(output, files):
    tree_layout = {}
    for path, data in sorted(files.items()):
        directory, stem, extension = _split(path)
        tree_layout.setdefault(extension, {}).setdefault(directory, []).append((stem, data))

    tree = bytearray()
    blob = bytearray()
    for extension, directories in tree_layout.items():
        tree += extension.encode() + b"\0"
        for directory, entries in directories.items():
            tree += directory.encode() + b"\0"
            for stem, data in entries:
                tree += stem.encode() + b"\0"
                tree += struct.pack(
                    "<IHHIIH",
                    zlib.crc32(data) & 0xFFFFFFFF,
                    0,
                    EMBEDDED_ARCHIVE,
                    len(blob),
                    len(data),
                    ENTRY_TERMINATOR,
                )
                blob += data
            tree += b"\0"
        tree += b"\0"
    tree += b"\0"

    archive_md5_section = b""
    header = struct.pack(
        "<7I",
        SIGNATURE,
        VERSION,
        len(tree),
        len(blob),
        len(archive_md5_section),
        48,
        0,
    )
    body = header + bytes(tree) + bytes(blob) + archive_md5_section
    tree_md5 = hashlib.md5(tree).digest()
    archive_md5 = hashlib.md5(archive_md5_section).digest()
    whole_md5 = hashlib.md5(body + tree_md5 + archive_md5).digest()

    output = Path(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(body + tree_md5 + archive_md5 + whole_md5)
