#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 ChipDesign B.V.
# SPDX-License-Identifier: Apache-2.0
#
# mkbootimg.py -- pack flat binaries into the QSPI boot flash image the
# hardware loader (rtl/boot/cdriscv_qspi_boot.sv) reads.
#
#   python3 scripts/mkbootimg.py out.hex \
#       --seg 0x00000000 build/prog.itcm.bin \
#       [--seg 0x10000000 build/prog.dtcm.bin] \
#       [--quad] [--pad0 N] [--bin out.bin]
#
# Image format (little-endian 32-bit words at flash offset 0; the
# authoritative description is the loader's header comment and
# doc/programming_manual.md):
#
#   word 0  MAGIC      0xCD10B007
#   word 1  FLAGS      bit0 = read the payload with the quad command
#                      (EBh); bits 31:1 reserved, must be 0
#   word 2  SEG0_DEST  byte address, word aligned (I-TCM segment)
#   word 3  SEG0_LEN   bytes, word multiple, > 0
#   word 4  SEG1_DEST  byte address, word aligned (D-TCM segment)
#   word 5  SEG1_LEN   bytes, word multiple, 0 = absent
#   word 6  CRC32      IEEE 802.3 (binascii.crc32) over the payload
#                      bytes of both segments in read order
#   word 7+ payload    seg0 bytes then seg1 bytes, no padding between
#
# --pad0 N appends N zero WORDS to segment 0 (after word-aligning it).
# On a TCM that is X (simulation) or random (silicon) past the image,
# the core's prefetcher reads a word or two beyond the program; padding
# gives those reads a valid ECC codeword.  See finding V4-F2, which is
# why the $readmemh images pad to the full array -- over QSPI a full
# pad costs real load time, so a small margin is the deliberate choice
# and crt0 must not execute off the padded end.
#
# The default output is a byte-per-line hex file ($readmemh format) for
# verif/models/cdriscv_spi_norflash_model.sv; --bin additionally writes the raw
# image, which is what a flash programmer would burn at offset 0.

import argparse
import binascii
import struct
import sys

MAGIC = 0xCD10B007


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("hexfile")
    ap.add_argument("--seg", nargs=2, action="append", metavar=("DEST", "BIN"),
                    required=True, help="segment: dest address + flat binary "
                    "(1 or 2 of these, in load order)")
    ap.add_argument("--quad", action="store_true",
                    help="set FLAGS[0]: payload is read with EBh")
    ap.add_argument("--pad0", type=int, default=0, metavar="N",
                    help="append N zero words to segment 0")
    ap.add_argument("--bin", default=None, help="also write the raw image")
    args = ap.parse_args()

    if not 1 <= len(args.seg) <= 2:
        sys.exit("mkbootimg: 1 or 2 --seg entries required")

    segs = []
    for i, (dest_s, path) in enumerate(args.seg):
        dest = int(dest_s, 0)
        with open(path, "rb") as f:
            data = f.read()
        if len(data) % 4:
            data += b"\x00" * (4 - len(data) % 4)
        if i == 0:
            data += b"\x00" * (4 * args.pad0)
        if dest % 4:
            sys.exit(f"mkbootimg: segment {i} dest 0x{dest:08x} not word aligned")
        if i == 0 and len(data) == 0:
            sys.exit("mkbootimg: segment 0 must not be empty")
        segs.append((dest, data))

    while len(segs) < 2:
        segs.append((0, b""))

    payload = segs[0][1] + segs[1][1]
    crc = binascii.crc32(payload) & 0xFFFFFFFF

    header = struct.pack("<7I", MAGIC, 1 if args.quad else 0,
                         segs[0][0], len(segs[0][1]),
                         segs[1][0], len(segs[1][1]), crc)
    image = header + payload

    with open(args.hexfile, "w") as f:
        for b in image:
            f.write("%02x\n" % b)
    if args.bin:
        with open(args.bin, "wb") as f:
            f.write(image)

    sys.stderr.write(
        "mkbootimg: %s: seg0 %d B @0x%08x, seg1 %d B @0x%08x, quad=%d, "
        "crc32=0x%08x, image %d B\n"
        % (args.hexfile, len(segs[0][1]), segs[0][0], len(segs[1][1]),
           segs[1][0], 1 if args.quad else 0, crc, len(image)))


if __name__ == "__main__":
    main()
