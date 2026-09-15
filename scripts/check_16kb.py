#!/usr/bin/env python3
"""Verify a release artifact is Play-uploadable: 16 KB page-size support + ABIs.

    python3 scripts/check_16kb.py <app.aab|app.apk> [--abis arm64-v8a,armeabi-v7a,x86_64]

Play blocks an upload when any 64-bit native library has ELF load segments
aligned below 16384 ("Your app does not support 16 KB memory page sizes"), and
warns when a release supports fewer devices than the previous one — which is
what a missing ABI looks like. Both are properties of the produced artifact, not
of the build config, so this reads the file itself.

32-bit ABIs (armeabi-v7a, x86) are reported but never fail the check: the 16 KB
page size is a 64-bit-only Android 15 feature.

Exit 0 = uploadable. Exit 1 = a 64-bit .so is under-aligned or an ABI is missing.
"""
import struct
import sys
import zipfile

SIXTEEN_KB = 16384
ABI_64 = {"arm64-v8a", "x86_64"}


def load_align(data):
    """Largest p_align across PT_LOAD program headers, or None if not an ELF."""
    if data[:4] != b"\x7fELF":
        return None
    if data[4] == 2:  # ELFCLASS64
        phoff = struct.unpack_from("<Q", data, 0x20)[0]
        entsize = struct.unpack_from("<H", data, 0x36)[0]
        count = struct.unpack_from("<H", data, 0x38)[0]
        aligns = [struct.unpack_from("<Q", data, phoff + i * entsize + 48)[0]
                  for i in range(count)
                  if struct.unpack_from("<I", data, phoff + i * entsize)[0] == 1]
    else:  # ELFCLASS32
        phoff = struct.unpack_from("<I", data, 0x1C)[0]
        entsize = struct.unpack_from("<H", data, 0x2A)[0]
        count = struct.unpack_from("<H", data, 0x2C)[0]
        aligns = [struct.unpack_from("<I", data, phoff + i * entsize + 28)[0]
                  for i in range(count)
                  if struct.unpack_from("<I", data, phoff + i * entsize)[0] == 1]
    return max(aligns) if aligns else 0


def main(argv):
    if not argv:
        print(__doc__)
        return 2
    path = argv[0]
    want = {"arm64-v8a", "armeabi-v7a", "x86_64"}
    for i, a in enumerate(argv):
        if a == "--abis" and i + 1 < len(argv):
            want = {x for x in argv[i + 1].split(",") if x}

    failures = []
    seen_abis = set()
    zf = zipfile.ZipFile(path)
    rows = []
    for name in sorted(zf.namelist()):
        if not name.endswith(".so") or "/lib/" not in ("/" + name):
            continue
        abi = ("/" + name).split("/lib/")[1].split("/")[0]
        seen_abis.add(abi)
        align = load_align(zf.read(name))
        if align is None:
            continue
        ok = abi not in ABI_64 or align >= SIXTEEN_KB
        rows.append((ok, abi, name, align))
        if not ok:
            failures.append(f"{name} aligned to {align} (need >= {SIXTEEN_KB})")

    for ok, abi, name, align in rows:
        tag = "OK  " if ok else "BAD "
        note = "" if abi in ABI_64 else "  (32-bit, not checked)"
        print(f"{tag}{name}  p_align={align}{note}")

    print(f"\nABIs present: {', '.join(sorted(seen_abis)) or '(none)'}")
    missing = want - seen_abis
    if missing:
        failures.append("missing ABI(s): " + ", ".join(sorted(missing)))

    if failures:
        print("\n16 KB / ABI CHECK FAILED:")
        for f in failures:
            print("  ✗ " + f)
        return 1
    print("16 KB alignment: OK (all 64-bit libs >= 16384)")
    print("ABI coverage: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
