#!/usr/bin/env python3
import struct
import sys

path = sys.argv[1]
with open(path, "r+b") as f:
    if f.read(4) != b"\xcf\xfa\xed\xfe":
        raise SystemExit(f"not a little-endian Mach-O 64 file: {path}")
    f.seek(4)
    cputype, subtype = struct.unpack("<II", f.read(8))
    if cputype != 0x0100000C:
        raise SystemExit(f"not ARM64: {path}")
    if subtype != 0:
        raise SystemExit(f"expected ordinary arm64 subtype, got {subtype:#x}: {path}")
    # CPU_SUBTYPE_ARM64E | CPU_SUBTYPE_LIB64: modern arm64e ABI accepted by
    # RootHide arm64e-only host processes. Machine code remains the supplied
    # arm64 slice, avoiding every legacy arm64e relocation and ABI dependency.
    f.seek(8)
    f.write(struct.pack("<I", 0x80000002))
