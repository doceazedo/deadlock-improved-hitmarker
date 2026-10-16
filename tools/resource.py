import struct

ALIGNMENT = 16


def read_blocks(data):
    _, _, _, block_offset, block_count = struct.unpack_from("<IHHII", data, 0)
    blocks = []
    for index in range(block_count):
        entry = 8 + block_offset + index * 12
        name = data[entry:entry + 4].decode()
        relative, size = struct.unpack_from("<II", data, entry + 4)
        blocks.append((name, entry, entry + 4 + relative, size))
    return blocks


def block_bytes(data, name):
    for block_name, _, start, size in read_blocks(data):
        if block_name == name:
            return data[start:start + size]
    raise ValueError(f"resource has no {name} block")


def replace_block(template, name, replacement):
    blocks = read_blocks(template)
    if name not in [block[0] for block in blocks]:
        raise ValueError(f"template has no {name} block")
    first_start = min(start for _, _, start, _ in blocks)
    result = bytearray(template[:first_start])
    for block_name, entry, start, size in blocks:
        content = replacement if block_name == name else template[start:start + size]
        while len(result) % ALIGNMENT:
            result.append(0)
        struct.pack_into("<II", result, entry + 4, len(result) - (entry + 4), len(content))
        result += content
    struct.pack_into("<I", result, 0, len(result))
    return bytes(result)


def replace_data_block(template, compiled):
    return replace_block(template, "DATA", block_bytes(compiled, "DATA"))
