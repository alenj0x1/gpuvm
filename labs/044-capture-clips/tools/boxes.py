"""Lab 044: lists an MP4's boxes (top level, and inside moov / the first moofs), to see what a player trips over."""
import struct
import sys

CONTAINERS = {b"moov", b"trak", b"mdia", b"minf", b"stbl", b"mvex", b"moof", b"traf", b"mfra", b"dinf", b"edts"}


def walk(data, start, end, depth, out, limit):
    i = start
    while i + 8 <= end:
        size, kind = struct.unpack(">I4s", data[i:i + 8])
        if size == 1:
            size = struct.unpack(">Q", data[i + 8:i + 16])[0]
        if size < 8 or i + size > end:
            out.append("  " * depth + f"BAD box at {i}: size {size} type {kind!r}")
            return
        info = ""
        if kind == b"trun":
            flags = struct.unpack(">I", data[i + 8:i + 12])[0] & 0xFFFFFF
            count = struct.unpack(">I", data[i + 12:i + 16])[0]
            info = f" flags={flags:06x} samples={count}"
        if kind == b"tfdt":
            info = f" t={struct.unpack('>Q', data[i + 12:i + 20])[0]}"
        if kind == b"tfhd":
            info = f" track={struct.unpack('>I', data[i + 12:i + 16])[0]}"
        out.append("  " * depth + f"{kind.decode('latin1')} {size}{info}")
        if kind in CONTAINERS and len(out) < limit:
            walk(data, i + 8, i + size, depth + 1, out, limit)
        if kind == b"stsd":
            walk(data, i + 16, i + size, depth + 1, out, limit)
        i += size


if __name__ == "__main__":
    data = open(sys.argv[1], "rb").read(int(sys.argv[2]) if len(sys.argv) > 2 else 4_000_000)
    out = []
    walk(data, 0, len(data), 0, out, 400)
    print("\n".join(out[:120]))
