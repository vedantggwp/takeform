#!/usr/bin/env python3
"""Pack the conventional PNG iconset into a minimal ICNS container."""

from __future__ import annotations

import pathlib
import struct
import sys


SPECS = (
    (b"icp4", "icon_16x16.png", 16),
    (b"icp5", "icon_32x32.png", 32),
    (b"icp6", "icon_64x64.png", 64),
    (b"ic07", "icon_128x128.png", 128),
    (b"ic08", "icon_256x256.png", 256),
    (b"ic09", "icon_512x512.png", 512),
    (b"ic10", "icon_512x512@2x.png", 1024),
)
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


def png_dimensions(payload: bytes) -> tuple[int, int]:
    if payload[:8] != PNG_SIGNATURE or payload[12:16] != b"IHDR":
        raise ValueError("not a PNG with an IHDR header")
    return struct.unpack(">II", payload[16:24])


def main(iconset: pathlib.Path, output: pathlib.Path) -> None:
    chunks: list[bytes] = []
    for chunk_type, name, expected_pixels in SPECS:
        payload = (iconset / name).read_bytes()
        width, height = png_dimensions(payload)
        if (width, height) != (expected_pixels, expected_pixels):
            raise ValueError(f"{name} is {width}x{height}; expected {expected_pixels}x{expected_pixels}")
        chunks.append(chunk_type + struct.pack(">I", len(payload) + 8) + payload)

    body = b"".join(chunks)
    container = b"icns" + struct.pack(">I", len(body) + 8) + body
    if struct.unpack(">I", container[4:8])[0] != len(container):
        raise ValueError("ICNS container length did not match its payload")
    output.write_bytes(container)
    print(f"Wrote {output}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("usage: pack-icns.py ICONSET OUTPUT")
    main(pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]))
