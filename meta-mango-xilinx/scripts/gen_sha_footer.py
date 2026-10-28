#!/usr/bin/env python3
"""
 @file gen_sha_footer.py
 @date 2026-04-19
 @brief Append a SHA-256 footer to a firmware image (idempotent)
 Copyright (c) 2026 MangoBoost Inc.

 Footer layout (72 bytes, little-endian):
     Offset  Size  Field         Description
     0x00       4  ulMagic       0x4D425348 ("MBSH")
     0x04       4  ulImageSize   Image data size, including any 0x00
                                 alignment padding (excludes footer)
     0x08      32  ucImageSha    SHA-256 of image data (incl. padding)
     0x28      32  ucFooterSha   SHA-256 of bytes [0x00-0x27]

 The image is zero-padded so the footer starts on a 16-byte boundary
 by default; ulImageSize and ucImageSha cover the padding so the
 verifier can locate and validate the footer without knowing the
 original (unpadded) image size.

 Idempotency: this tool is safe to re-run on its own output,
 including in place (input == output). If the tail already holds a
 footer it is dropped before a fresh one is appended, so running the
 tool N times on the same source produces byte-identical output to
 running it once. Detection is driven purely by the footer's own
 consistency, so BOOT.BIN and image.ub are handled identically.

 Exactly one layer is removed -- the footer occupying the final 72
 bytes -- and exactly one is written back, which is what keeps the
 layer count constant:

     [ image ][ pad ][ footer ]
                      ^^^^^^^^ dropped, then rebuilt in place

 The removed footer starts on an --align boundary (that is what its
 padding was for), so the recovered buffer needs no further padding and
 the rebuilt footer lands at the same offset. Re-running with a
 *smaller* --align than a previous run is the one case that is not
 byte-identical.

 Note this stops the stacking, it does not undo it: a file that already
 carries several stacked footers from before this fix keeps them (its
 outermost ulImageSize still counts the stale inner footers as image
 data). Repair such a file once by hand with

     truncate -s <FIT totalsize at offset 4> image.ub

 before letting the packaging flow re-footer it.
"""

from __future__ import annotations

import argparse
import hashlib
import struct
import sys

MAGIC = 0x4D425348
FOOTER_SIZE = 72
HEADER_SIZE = 0x28
DEFAULT_ALIGN = 16


def build_footer(image_data: bytes) -> bytes:
    image_size = len(image_data)
    image_sha = hashlib.sha256(image_data).digest()

    header = struct.pack("<II", MAGIC, image_size) + image_sha
    assert len(header) == HEADER_SIZE

    footer_sha = hashlib.sha256(header).digest()
    footer = header + footer_sha
    assert len(footer) == FOOTER_SIZE
    return footer


def find_trailing_footer(data: bytes) -> int | None:
    """Return the offset of the footer occupying the last 72 bytes of ``data``.

    ``None`` means the tail is not positively identifiable as a footer, in
    which case the caller must not truncate anything. All three checks below
    have to hold, so real payload that happens to end in the magic is never
    mistaken for a footer.
    """
    offset = len(data) - FOOTER_SIZE
    if offset < 0:
        return None
    if struct.unpack_from("<I", data, offset)[0] != MAGIC:
        return None
    # ulImageSize must name the boundary the footer actually starts at.
    if struct.unpack_from("<I", data, offset + 4)[0] != offset:
        return None
    header = data[offset:offset + HEADER_SIZE]
    if hashlib.sha256(header).digest() != data[offset + HEADER_SIZE:]:
        return None
    return offset


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Append a SHA-256 footer to a firmware image."
    )
    parser.add_argument("input", help="Input image file")
    parser.add_argument("output", help="Output file (input + 72-byte footer)")
    parser.add_argument(
        "--align",
        type=lambda x: int(x, 0),
        default=DEFAULT_ALIGN,
        help=(
            f"Pad image with 0x00 so the footer starts on this byte boundary "
            f"(default: {DEFAULT_ALIGN}). Use 1 to disable padding."
        ),
    )
    args = parser.parse_args()

    if args.align < 1:
        parser.error("--align must be >= 1")

    with open(args.input, "rb") as f:
        raw = f.read()

    footer_offset = find_trailing_footer(raw)
    if footer_offset is None:
        # Common case (BOOT.BIN, a fresh image.ub): no footer, nothing to drop.
        image_data = raw
    else:
        image_data = raw[:footer_offset]
        print(
            f"[gen_sha_footer] replacing existing {FOOTER_SIZE}-byte footer "
            f"at offset {footer_offset} in {args.input}"
        )

    pad_len = (-len(image_data)) % args.align
    padded_image = image_data + b"\x00" * pad_len

    footer = build_footer(padded_image)

    with open(args.output, "wb") as f:
        f.write(padded_image)
        f.write(footer)

    total = len(padded_image) + FOOTER_SIZE
    print(
        f"[gen_sha_footer] image={len(image_data)} bytes, "
        f"pad={pad_len} bytes (align={args.align}), "
        f"footer={FOOTER_SIZE} bytes, total={total} bytes -> {args.output}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
