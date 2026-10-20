#!/usr/bin/env python3
"""Read pixel colors from a capture PNG, for contrast measurements.

  png_colors.py size <png>
  png_colors.py pixel <png> <x,y> [<x,y> ...]
  png_colors.py region <png> <x,y,width,height> [--top N]

Coordinates are image pixels from the top left. `region` lists the most common
colors in a rectangle: for a text run, the most common is usually the background
and a darker or lighter cluster is the text. Report the colors you chose, and the
region, as the measurement's evidence.

Supports 8-bit, non-interlaced RGB and RGBA PNGs, which is what `screencapture`
writes. Anything else fails with a specific message.
"""
from __future__ import annotations

import argparse
import struct
import sys
import zlib
from collections import Counter
from dataclasses import dataclass
from pathlib import Path

PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
CHANNELS_BY_COLOR_TYPE = {2: 3, 6: 4}


class PNGFormatError(ValueError):
    pass


@dataclass(frozen=True)
class PNGImage:
    width: int
    height: int
    channels: int
    rows: list[bytes]

    def color(self, x: int, y: int) -> str:
        if not (0 <= x < self.width and 0 <= y < self.height):
            raise PNGFormatError(f"pixel {x},{y} is outside {self.width}x{self.height}")
        offset = x * self.channels
        red, green, blue = self.rows[y][offset : offset + 3]
        return f"#{red:02X}{green:02X}{blue:02X}"


def read_png_size(path: Path) -> tuple[int, int]:
    with path.open("rb") as stream:
        header = stream.read(24)
    if len(header) < 24 or header[:8] != PNG_SIGNATURE or header[12:16] != b"IHDR":
        raise PNGFormatError(f"{path} is not a PNG")
    width, height = struct.unpack(">II", header[16:24])
    return width, height


def decode_png(path: Path) -> PNGImage:
    content = path.read_bytes()
    if content[:8] != PNG_SIGNATURE:
        raise PNGFormatError(f"{path} is not a PNG")
    position = 8
    header: tuple[int, ...] | None = None
    compressed = bytearray()
    while position < len(content):
        (length,) = struct.unpack(">I", content[position : position + 4])
        kind = content[position + 4 : position + 8]
        body = content[position + 8 : position + 8 + length]
        position += 12 + length
        if kind == b"IHDR":
            header = struct.unpack(">IIBBBBB", body)
        elif kind == b"IDAT":
            compressed += body
        elif kind == b"IEND":
            break
    if header is None:
        raise PNGFormatError(f"{path} has no IHDR chunk")
    width, height, bit_depth, color_type, _, _, interlace = header
    if bit_depth != 8 or color_type not in CHANNELS_BY_COLOR_TYPE or interlace != 0:
        raise PNGFormatError(
            f"{path}: only 8-bit non-interlaced RGB or RGBA is supported "
            f"(bit depth {bit_depth}, color type {color_type}, interlace {interlace})"
        )
    channels = CHANNELS_BY_COLOR_TYPE[color_type]
    raw = zlib.decompress(bytes(compressed))
    stride = width * channels
    if len(raw) != height * (stride + 1):
        raise PNGFormatError(f"{path}: image data has the wrong length")
    rows: list[bytes] = []
    previous = bytearray(stride)
    for index in range(height):
        start = index * (stride + 1)
        filter_type = raw[start]
        row = bytearray(raw[start + 1 : start + 1 + stride])
        unfilter_row(row, previous, filter_type, channels)
        rows.append(bytes(row))
        previous = row
    return PNGImage(width, height, channels, rows)


def unfilter_row(row: bytearray, previous: bytearray, filter_type: int, channels: int) -> None:
    if filter_type == 0:
        return
    for index in range(len(row)):
        left = row[index - channels] if index >= channels else 0
        above = previous[index]
        upper_left = previous[index - channels] if index >= channels else 0
        if filter_type == 1:
            predictor = left
        elif filter_type == 2:
            predictor = above
        elif filter_type == 3:
            predictor = (left + above) // 2
        elif filter_type == 4:
            estimate = left + above - upper_left
            distances = (abs(estimate - left), abs(estimate - above), abs(estimate - upper_left))
            predictor = (left, above, upper_left)[distances.index(min(distances))]
        else:
            raise PNGFormatError(f"unknown PNG filter type {filter_type}")
        row[index] = (row[index] + predictor) & 0xFF


def region_colors(image: PNGImage, x: int, y: int, width: int, height: int) -> Counter[str]:
    if width <= 0 or height <= 0 or x < 0 or y < 0 or x + width > image.width or y + height > image.height:
        raise PNGFormatError(f"region {x},{y},{width},{height} is outside {image.width}x{image.height}")
    return Counter(image.color(column, row) for row in range(y, y + height) for column in range(x, x + width))


def parse_integers(text: str, count: int) -> list[int]:
    parts = text.split(",")
    if len(parts) != count:
        raise argparse.ArgumentTypeError(f"expected {count} comma-separated integers, got {text!r}")
    return [int(part) for part in parts]


def main(arguments: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    size_command = commands.add_parser("size")
    size_command.add_argument("png", type=Path)
    pixel_command = commands.add_parser("pixel")
    pixel_command.add_argument("png", type=Path)
    pixel_command.add_argument("points", nargs="+", type=lambda text: parse_integers(text, 2))
    region_command = commands.add_parser("region")
    region_command.add_argument("png", type=Path)
    region_command.add_argument("box", type=lambda text: parse_integers(text, 4))
    region_command.add_argument("--top", type=int, default=5)
    options = parser.parse_args(arguments)
    try:
        if options.command == "size":
            width, height = read_png_size(options.png)
            print(f"{width}x{height}")
        elif options.command == "pixel":
            image = decode_png(options.png)
            for x, y in options.points:
                print(f"{x},{y} {image.color(x, y)}")
        else:
            image = decode_png(options.png)
            counts = region_colors(image, *options.box)
            total = sum(counts.values())
            for color, count in counts.most_common(options.top):
                print(f"{color} {count} {100 * count / total:.1f}%")
    except (OSError, PNGFormatError, zlib.error) as error:
        print(f"png_colors: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
