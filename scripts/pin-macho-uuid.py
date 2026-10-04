#!/usr/bin/env python3
"""Pin the LC_UUID of every slice of a Mach-O file to a value derived from a name.

macOS local network privacy keys its grant on the main executable's UUID (Apple TN3179), and the
linker derives a new one from the contents on every build, so each rebuilt dev app is asked again.
Each slice gets uuid5(DNS, "<name>/<arch>"): stable across builds, and distinct per architecture
so two slices of one file never claim to be the same image.

usage: pin-macho-uuid.py <file> <name>            rewrite in place
       pin-macho-uuid.py --expected <file> <name> print "<UUID> (<arch>)" per slice, as dwarfdump does
"""
import struct
import sys
import uuid

LC_UUID = 0x1B
ARCHS = {(0x0100000C, 0): "arm64", (0x0100000C, 2): "arm64e", (0x01000007, 3): "x86_64"}


def slice_offsets(data):
    magic = struct.unpack_from(">I", data)[0]
    if magic not in (0xCAFEBABE, 0xCAFEBABF):
        return [0]
    count = struct.unpack_from(">I", data, 4)[0]
    if magic == 0xCAFEBABE:
        return [struct.unpack_from(">I", data, 8 + i * 20 + 8)[0] for i in range(count)]
    return [struct.unpack_from(">Q", data, 8 + i * 32 + 8)[0] for i in range(count)]


def slices(data, name):
    """Yield (offset of the UUID bytes, arch, pinned UUID) for every slice."""
    for base in slice_offsets(data):
        magic, cpu, sub, _, ncmds = struct.unpack_from("<IiiII", data, base)
        if magic != 0xFEEDFACF:
            sys.exit(f"pin-macho-uuid: slice at {base} is not a 64-bit Mach-O")
        arch = ARCHS.get((cpu, sub & 0xFFFFFF))
        if arch is None:
            sys.exit(f"pin-macho-uuid: unknown cpu {cpu:#x}/{sub:#x}")
        at = base + 32
        for _ in range(ncmds):
            cmd, size = struct.unpack_from("<II", data, at)
            if cmd == LC_UUID:
                yield at + 8, arch, uuid.uuid5(uuid.NAMESPACE_DNS, f"{name}/{arch}")
                break
            at += size
        else:
            sys.exit(f"pin-macho-uuid: {arch} slice has no LC_UUID")


def main(argv):
    expected = argv[:1] == ["--expected"]
    path, name = argv[1:] if expected else argv
    with open(path, "rb") as f:
        data = bytearray(f.read())
    found = list(slices(data, name))
    if expected:
        for _, arch, pinned in found:
            print(f"{str(pinned).upper()} ({arch})")
        return
    for at, _, pinned in found:
        data[at:at + 16] = pinned.bytes
    with open(path, "wb") as f:
        f.write(data)


if __name__ == "__main__":
    main(sys.argv[1:])
