"""Capture manifest rules and PNG reading. No screen or app is needed."""
from __future__ import annotations

import hashlib
import struct
import tempfile
import unittest
import zlib
from pathlib import Path

from capture import validate_manifest
from png_colors import decode_png, read_png_size, region_colors


def write_png(path: Path, rows: list[list[tuple[int, int, int]]], filter_type: int = 0) -> None:
    """Write an 8-bit RGB PNG. Filter 1 (Sub) exercises the decoder's unfiltering."""
    raw = bytearray()
    for row in rows:
        raw.append(filter_type)
        flat = [channel for pixel in row for channel in pixel]
        if filter_type == 1:
            flat = [(value - (flat[index - 3] if index >= 3 else 0)) & 0xFF for index, value in enumerate(flat)]
        raw.extend(flat)

    def chunk(kind: bytes, body: bytes) -> bytes:
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body))

    header = struct.pack(">IIBBBBB", len(rows[0]), len(rows), 8, 2, 0, 0, 0)
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(bytes(raw))) + chunk(b"IEND", b""))


class CaptureManifestTests(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = Path(tempfile.mkdtemp())
        self.manifest = {
            "version": 1,
            "reviewId": "menu-bar-review",
            "phase": "before",
            "capturedAt": "2026-10-20T12:00:00+00:00",
            "data": "demo",
            "app": {"bundle": "app/build/Little CI.app", "executableSha256": "a" * 64},
            "requested": {"surfaces": ["panel", "overview"], "appearances": ["light", "dark"]},
            "captures": [],
        }
        for surface, title in (("panel", "Little CI panel"), ("overview", "Little CI")):
            for appearance in ("light", "dark"):
                name = f"{surface}-{appearance}.png"
                write_png(self.directory / name, [[(255, 255, 255)] * 4] * 2)
                self.manifest["captures"].append(
                    {
                        "surface": surface,
                        "appearance": appearance,
                        "windowTitle": title,
                        "file": name,
                        "pixelWidth": 4,
                        "pixelHeight": 2,
                        "pointWidth": 2,
                        "pointHeight": 1,
                        "scale": 2.0,
                        "sha256": hashlib.sha256((self.directory / name).read_bytes()).hexdigest(),
                    }
                )

    def test_complete_manifest_passes_with_files(self) -> None:
        self.assertEqual(validate_manifest(self.manifest, self.directory), [])

    def test_missing_pair_is_reported(self) -> None:
        self.manifest["captures"] = [c for c in self.manifest["captures"] if c["file"] != "panel-dark.png"]
        self.assertEqual(validate_manifest(self.manifest), ["missing capture for panel/dark"])

    def test_repeated_and_unrequested_captures_fail(self) -> None:
        extra = dict(self.manifest["captures"][0], surface="hosts", file="hosts-light.png")
        self.manifest["captures"] += [dict(self.manifest["captures"][0]), extra]
        problems = validate_manifest(self.manifest)
        self.assertIn("captures[4] repeats panel/light", problems)
        self.assertIn("captures[5] is hosts/light, which was not requested", problems)

    def test_wrong_window_title_fails(self) -> None:
        self.manifest["captures"][0]["windowTitle"] = "Little CI"
        self.assertEqual(validate_manifest(self.manifest), ["captures[0] window title must be 'Little CI panel'"])

    def test_changed_image_fails_hash_check(self) -> None:
        write_png(self.directory / "overview-dark.png", [[(0, 0, 0)] * 4] * 2)
        self.assertEqual(validate_manifest(self.manifest, self.directory), ["captures[3]: overview-dark.png does not match its SHA-256"])

    def test_unknown_phase_fails(self) -> None:
        self.manifest["phase"] = "before-dark"
        self.assertIn("phase must be before, after, or after-<n>", validate_manifest(self.manifest))


class PNGColorTests(unittest.TestCase):
    def test_decodes_sub_filtered_rows(self) -> None:
        path = Path(tempfile.mkdtemp()) / "sample.png"
        rows = [[(255, 255, 255), (30, 30, 30), (255, 255, 255)], [(10, 132, 255), (255, 255, 255), (255, 255, 255)]]
        write_png(path, rows, filter_type=1)
        image = decode_png(path)
        self.assertEqual(read_png_size(path), (3, 2))
        self.assertEqual(image.color(1, 0), "#1E1E1E")
        self.assertEqual(image.color(0, 1), "#0A84FF")
        self.assertEqual(region_colors(image, 0, 0, 3, 2).most_common(1), [("#FFFFFF", 4)])


if __name__ == "__main__":
    unittest.main()
