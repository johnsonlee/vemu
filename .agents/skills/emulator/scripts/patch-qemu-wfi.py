#!/usr/bin/env python3
"""Patch the verified UTM 4.6.5 ARM64 QEMU WFI skip-sleep branch."""

import argparse
import hashlib
from pathlib import Path

EXPECTED_SHA256 = "f34b2dc9edc0376ecf429ac92c53ee85bfcdc1aff28604bb213656571df0ad13"
OFFSET = 0x4D192C
ORIGINAL = bytes.fromhex("43 02 00 54")  # b.lo return
PATCHED = bytes.fromhex("1f 20 03 d5")  # nop


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    data = bytearray(args.input.read_bytes())
    actual = hashlib.sha256(data).hexdigest()
    if actual != EXPECTED_SHA256:
        parser.error(f"unsupported QEMU ARM64 binary: SHA-256 {actual}")
    if data[OFFSET : OFFSET + 4] != ORIGINAL:
        parser.error("QEMU WFI instruction does not match the verified build")
    data[OFFSET : OFFSET + 4] = PATCHED
    args.output.write_bytes(data)


if __name__ == "__main__":
    main()
