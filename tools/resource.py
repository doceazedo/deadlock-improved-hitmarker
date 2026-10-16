import struct


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


def replace_data_block(template, compiled):
    blocks = read_blocks(template)
    name, entry, start, size = blocks[-1]
    if name != "DATA" or start + size != len(template):
        raise ValueError("template DATA block is not the last block")
    data = block_bytes(compiled, "DATA")
    result = bytearray(template[:start] + data)
    struct.pack_into("<I", result, entry + 8, len(data))
    struct.pack_into("<I", result, 0, len(result))
    return bytes(result)
