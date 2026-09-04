#!/usr/bin/env python3
"""Build the CC26 0.6.0.0-universal1 patched dylib from the verified nomedia3 baseline.

This is reproducible binary-patch source, not the original author's Objective-C/Logos project.
Every byte sequence is validated before replacement.  The two final UNIVERSAL_PATCHES make
applyBorderToSpecialViews() return immediately in both Mach-O slices, preventing CC26's global
special-border traversal from entering version-sensitive SpringBoard material/System Aperture
views on iOS 16.x.
"""
from pathlib import Path
import argparse, hashlib, sys

BASE_OUTPUTS = {
    # 用户上传版，与原作者 Git 历史 0.4.9.9b 字节一致。
    "d06ef3a0708d1adf21cf661d000f48a8985f6e66ec0b57964bb9e1298e8c161d":
        "83ac870ccfdd4eceb76c37e7bf83a40ec46bed4a358f0909868a468c9980b0e0",
    # 兼容原 universal1 README 记录的 nomedia3 精确基线。
    "7fd8cab4796fcd2f1683858a37c8a16f8247bd5eb39c4a38bedc3091fc222f17":
        "a2fb4953e85f71f255593edd9f3b134d3d16c611817563d925cba1108ad0f9d4",
}
NOMEDIA13_SHA256 = "9d2160c586ff26cd86635fc4692c0a7c48f348d17e110a466c009e5e1a480633"

# Existing nomedia13 functionality: media hooks neutralization, selective HUD handling,
# UTF-16 menu text, and disabling showsMenuAsPrimaryAction for CCSIM compatibility.
BASE_PATCHES = [
    (0x8704, bytes.fromhex("6820601ee0"), bytes.fromhex("f37bbfa9f3")),
    (0x870A, bytes.fromhex("679e44c4601e4018631e01"), bytes.fromhex("00aaa1d005588214009400")),
    (0x8716, bytes.fromhex("6e"), bytes.fromhex("60")),
    (0x8718, bytes.fromhex("00cc61"), bytes.fromhex("400860")),
    (0x871C, bytes.fromhex("c0035fd6280be8d20101679e0008611e0040661e0018611ec0035fd6"), bytes.fromhex("6020601e6c000054e00313aae5010094f37bc1a8c0035fd61f2003d5")),
    (0xA328, bytes.fromhex("43"), bytes.fromhex("23")),
    (0xA380, bytes.fromhex("cffa"), bytes.fromhex("e1f8")),
    (0xC9C4, bytes.fromhex("22"), bytes.fromhex("02")),
    (0xF1DE, bytes.fromhex("5265737072696e67"), bytes.fromhex("cd912f5400000000")),
    (0xF219, bytes.fromhex("55494361636865"), bytes.fromhex("3752b065000000")),
    (0xF24D, bytes.fromhex("557365727370616365205265626f6f74"), bytes.fromhex("28753762cd912f540000000000000000")),
    (0xF292, bytes.fromhex("43686f6f736520416374696f6e"), bytes.fromhex("0990e962cd645c4f0000000000")),
    (0x10588, bytes.fromhex("c8"), bytes.fromhex("d0")),
    (0x10598, bytes.fromhex("08"), bytes.fromhex("02")),
    (0x105C8, bytes.fromhex("c8"), bytes.fromhex("d0")),
    (0x105D8, bytes.fromhex("07"), bytes.fromhex("02")),
    (0x10608, bytes.fromhex("c8"), bytes.fromhex("d0")),
    (0x10618, bytes.fromhex("10"), bytes.fromhex("04")),
    (0x10648, bytes.fromhex("c8"), bytes.fromhex("d0")),
    (0x10658, bytes.fromhex("0d"), bytes.fromhex("04")),
    (0x20720, bytes.fromhex("6820601e00e4002f44c4601e4018631e01106e1e"), bytes.fromhex("7f2303d5f37bbfa9f30300aae1c60558dd140094")),
    (0x20735, bytes.fromhex("cc61"), bytes.fromhex("1060")),
    (0x20738, bytes.fromhex("c0035fd6280be8d20101679e0008611e0040661e0018611ec003"), bytes.fromhex("4008601e6020601e6c000054e00313aaeb010094f37bc1a8ff0f")),
    (0x223BC, bytes.fromhex("43"), bytes.fromhex("23")),
    (0x22414, bytes.fromhex("b8fa"), bytes.fromhex("c3f8")),
    (0x24A80, bytes.fromhex("22"), bytes.fromhex("02")),
    (0x271D6, bytes.fromhex("5265737072696e67"), bytes.fromhex("cd912f5400000000")),
    (0x27211, bytes.fromhex("55494361636865"), bytes.fromhex("3752b065000000")),
    (0x27245, bytes.fromhex("557365727370616365205265626f6f74"), bytes.fromhex("28753762cd912f540000000000000000")),
    (0x2728A, bytes.fromhex("43686f6f736520416374696f6e"), bytes.fromhex("0990e962cd645c4f0000000000")),
    (0x28690, bytes.fromhex("c8"), bytes.fromhex("d0")),
    (0x286A0, bytes.fromhex("08"), bytes.fromhex("02")),
    (0x286D0, bytes.fromhex("c8"), bytes.fromhex("d0")),
    (0x286E0, bytes.fromhex("07"), bytes.fromhex("02")),
    (0x28710, bytes.fromhex("c8"), bytes.fromhex("d0")),
    (0x28720, bytes.fromhex("10"), bytes.fromhex("04")),
    (0x28750, bytes.fromhex("c8"), bytes.fromhex("d0")),
    (0x28760, bytes.fromhex("0d"), bytes.fromhex("04")),
]

# universal1 safety patch. ARM64 RET = c0 03 5f d6.
# In both slices this replaces only the first instruction at the verified
# applyBorderToSpecialViews() entry, leaving the rest of the function intact/unreachable.
UNIVERSAL_PATCHES = [
    (0x996C, bytes.fromhex("ff4305d1"), bytes.fromhex("c0035fd6")),
    (0x219B0, bytes.fromhex("7f2303d5"), bytes.fromhex("c0035fd6")),
]

PATCHES = BASE_PATCHES + UNIVERSAL_PATCHES

def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("input", help="CC26.dylib from the verified 0.4.9.9b-nomedia3 baseline")
    ap.add_argument("output", help="patched universal1 output dylib")
    args = ap.parse_args()

    data = bytearray(Path(args.input).read_bytes())
    got = sha256(data)
    expected_output = BASE_OUTPUTS.get(got)
    if not expected_output:
        supported = "\n".join(f"  - {value}" for value in BASE_OUTPUTS)
        sys.exit(f"Baseline SHA-256 mismatch\nsupported:\n{supported}\n     got {got}")

    for off, old, new in PATCHES:
        cur = bytes(data[off:off+len(old)])
        if cur != old:
            sys.exit(f"Patch validation failed at 0x{off:X}: expected {old.hex()}, got {cur.hex()}")
        if len(old) != len(new):
            sys.exit(f"Internal patch error at 0x{off:X}: length mismatch")
        data[off:off+len(new)] = new

    out_hash = sha256(data)
    if out_hash != expected_output:
        sys.exit(f"Output SHA-256 mismatch: expected {expected_output}, got {out_hash}")
    Path(args.output).write_bytes(data)
    print(f"patched OK: {args.output}")
    print(f"sha256: {out_hash}")

if __name__ == "__main__":
    main()
