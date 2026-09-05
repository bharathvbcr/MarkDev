#!/usr/bin/env python3
"""Contracts for the generated MarkDev icon catalogue fast path."""

from __future__ import annotations

import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib


REPO = Path(__file__).resolve().parents[2]
VALIDATOR = REPO / "tools" / "icongen" / "validate.py"
SLOTS = tuple((size, scale) for size in (16, 32, 128, 256, 512) for scale in (1, 2))


def filename(size: int, scale: int) -> str:
    suffix = "" if scale == 1 else f"@{scale}x"
    return f"icon_{size}x{size}{suffix}.png"


def rgba_pixels(
    width: int,
    height: int,
    first: tuple[int, int, int, int] = (31, 122, 255, 255),
    second: tuple[int, int, int, int] = (175, 82, 222, 255),
) -> bytes:
    """Return a simple, visible two-tone image without hiding test intent."""

    split = max(1, width // 2)
    row = bytes(first) * split + bytes(second) * (width - split)
    return row * height


def png_from_pixels(
    width: int,
    height: int,
    pixels: bytes,
    *,
    filter_kind: int = 0,
) -> bytes:
    def chunk(kind: bytes, payload: bytes) -> bytes:
        checksum = zlib.crc32(kind + payload) & 0xFFFF_FFFF
        return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", checksum)

    self_expected = width * height * 4
    if len(pixels) != self_expected:
        raise ValueError(f"expected {self_expected} RGBA bytes, got {len(pixels)}")
    if filter_kind not in range(5):
        raise ValueError(f"unsupported test PNG filter {filter_kind}")

    def paeth(left: int, above: int, upper_left: int) -> int:
        estimate = left + above - upper_left
        distances = (
            (abs(estimate - left), left),
            (abs(estimate - above), above),
            (abs(estimate - upper_left), upper_left),
        )
        return min(distances, key=lambda item: item[0])[1]

    row_bytes = width * 4
    if filter_kind == 0:
        rows = b"".join(
            b"\0" + pixels[offset : offset + row_bytes]
            for offset in range(0, len(pixels), row_bytes)
        )
    else:
        encoded_rows = bytearray()
        previous = bytes(row_bytes)
        for offset in range(0, len(pixels), row_bytes):
            current = pixels[offset : offset + row_bytes]
            encoded = bytearray(row_bytes)
            for column, value in enumerate(current):
                left = current[column - 4] if column >= 4 else 0
                above = previous[column]
                upper_left = previous[column - 4] if column >= 4 else 0
                if filter_kind == 1:
                    predictor = left
                elif filter_kind == 2:
                    predictor = above
                elif filter_kind == 3:
                    predictor = (left + above) // 2
                else:
                    predictor = paeth(left, above, upper_left)
                encoded[column] = (value - predictor) & 0xFF
            encoded_rows.extend(bytes((filter_kind,)) + encoded)
            previous = current
        rows = bytes(encoded_rows)
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(rows, level=9))
        + chunk(b"IEND", b"")
    )


def png(width: int, height: int) -> bytes:
    return png_from_pixels(width, height, rgba_pixels(width, height))


def legacy_argb(width: int, height: int, pixels: bytes) -> bytes:
    """Encode iconutil's legacy ARGB channel-RLE representation."""

    expected = width * height * 4
    if len(pixels) != expected:
        raise ValueError(f"expected {expected} RGBA bytes, got {len(pixels)}")

    def pack(channel: bytes) -> bytes:
        encoded = bytearray()
        offset = 0
        while offset < len(channel):
            run = 1
            while (
                offset + run < len(channel)
                and channel[offset + run] == channel[offset]
                and run < 130
            ):
                run += 1
            if run >= 3:
                encoded.extend((run + 125, channel[offset]))
                offset += run
                continue

            start = offset
            while offset < len(channel) and offset - start < 128:
                run = 1
                while (
                    offset + run < len(channel)
                    and channel[offset + run] == channel[offset]
                    and run < 130
                ):
                    run += 1
                if run >= 3:
                    break
                offset += 1
            block = channel[start:offset]
            encoded.append(len(block) - 1)
            encoded.extend(block)
        return bytes(encoded)

    channels = (
        pixels[3::4],
        pixels[0::4],
        pixels[1::4],
        pixels[2::4],
    )
    return b"ARGB" + b"".join(pack(channel) for channel in channels)


def replacing_icns_chunk(data: bytes, target: bytes, replacement: bytes) -> bytes:
    offset = 8
    rewritten = bytearray(data[:8])
    replaced = False
    while offset < len(data):
        length = struct.unpack_from(">I", data, offset + 4)[0]
        kind = data[offset : offset + 4]
        payload = replacement if kind == target else data[offset + 8 : offset + length]
        rewritten.extend(kind + struct.pack(">I", len(payload) + 8) + payload)
        replaced = replaced or kind == target
        offset += length
    if not replaced:
        raise ValueError(f"missing ICNS chunk {target!r}")
    struct.pack_into(">I", rewritten, 4, len(rewritten))
    return bytes(rewritten)


def png_with_idat(
    width: int,
    height: int,
    compressed: bytes,
    *,
    bit_depth: int = 8,
    color_type: int = 6,
    interlace: int = 0,
) -> bytes:
    def chunk(kind: bytes, payload: bytes) -> bytes:
        checksum = zlib.crc32(kind + payload) & 0xFFFF_FFFF
        return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", checksum)

    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(
            b"IHDR",
            struct.pack(
                ">IIBBBBB",
                width,
                height,
                bit_depth,
                color_type,
                0,
                0,
                interlace,
            ),
        )
        + chunk(b"IDAT", compressed)
        + chunk(b"IEND", b"")
    )


class IconGenerationContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="markdev-icons-")
        self.root = Path(self.temporary.name)
        self.catalog = self.root / "Assets.xcassets"
        self.icon_set = self.catalog / "AppIcon.appiconset"
        self.document = self.root / "DocumentIcon.icns"
        self.write_valid_fixture()

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def write_valid_fixture(self) -> None:
        self.icon_set.mkdir(parents=True)
        (self.catalog / "Contents.json").write_text(
            json.dumps({"info": {"author": "icongen", "version": 1}}),
            encoding="utf-8",
        )
        images = []
        for size, scale in SLOTS:
            name = filename(size, scale)
            images.append(
                {
                    "filename": name,
                    "idiom": "mac",
                    "scale": f"{scale}x",
                    "size": f"{size}x{size}",
                }
            )
            (self.icon_set / name).write_bytes(png(size * scale, size * scale))
        (self.icon_set / "Contents.json").write_text(
            json.dumps(
                {"images": images, "info": {"author": "icongen", "version": 1}}
            ),
            encoding="utf-8",
        )
        representation_dimensions = {
            b"ic04": 16,
            b"ic11": 32,
            b"ic05": 32,
            b"ic12": 64,
            b"ic07": 128,
            b"ic13": 256,
            b"ic08": 256,
            b"ic14": 512,
            b"ic09": 512,
            b"ic10": 1024,
        }
        chunks = []
        for kind, dimension in representation_dimensions.items():
            payload = (
                legacy_argb(
                    dimension,
                    dimension,
                    rgba_pixels(dimension, dimension),
                )
                if kind in {b"ic04", b"ic05"}
                else png(dimension, dimension)
            )
            chunks.append(kind + struct.pack(">I", len(payload) + 8) + payload)
        payload = b"".join(chunks)
        self.document.write_bytes(b"icns" + struct.pack(">I", 8 + len(payload)) + payload)

    def validate(self, *sources: Path) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                sys.executable,
                str(VALIDATOR),
                str(self.catalog),
                str(self.document),
                *(str(source) for source in sources),
            ],
            text=True,
            capture_output=True,
            check=False,
        )

    def test_complete_catalogue_and_document_icon_pass(self) -> None:
        result = self.validate()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_missing_generated_asset_is_rejected(self) -> None:
        missing = self.icon_set / filename(128, 2)
        missing.unlink()

        result = self.validate()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn(missing.name, result.stderr)

    def test_wrong_pixel_dimensions_are_rejected(self) -> None:
        wrong = self.icon_set / filename(32, 2)
        wrong.write_bytes(png(63, 64))

        result = self.validate()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("expected 64x64", result.stderr)

    def test_fully_transparent_generated_png_is_rejected(self) -> None:
        target = self.icon_set / filename(16, 1)
        target.write_bytes(
            png_from_pixels(16, 16, bytes((0, 0, 0, 0)) * (16 * 16))
        )

        result = self.validate()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("visually empty", result.stderr)

    def test_uniform_generated_png_is_rejected(self) -> None:
        target = self.icon_set / filename(16, 1)
        target.write_bytes(
            png_from_pixels(16, 16, bytes((31, 122, 255, 255)) * (16 * 16))
        )

        result = self.validate()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("visible variation", result.stderr)

    def test_uniform_sub_filtered_png_cannot_manufacture_visible_content(self) -> None:
        target = self.icon_set / filename(16, 1)
        target.write_bytes(
            png_from_pixels(
                16,
                16,
                bytes((31, 122, 255, 255)) * (16 * 16),
                filter_kind=1,
            )
        )

        result = self.validate()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("visible variation", result.stderr)

    def test_every_supported_png_filter_reconstructs_visible_pixels(self) -> None:
        target = self.icon_set / filename(16, 1)
        pixels = rgba_pixels(16, 16)
        for filter_kind in range(5):
            with self.subTest(filter_kind=filter_kind):
                target.write_bytes(
                    png_from_pixels(
                        16,
                        16,
                        pixels,
                        filter_kind=filter_kind,
                    )
                )
                result = self.validate()
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_crc_valid_but_invalid_compressed_pixels_are_rejected(self) -> None:
        corrupt = self.icon_set / filename(16, 1)
        corrupt.write_bytes(png_with_idat(16, 16, b"not a zlib stream"))

        result = self.validate()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("compressed pixel stream", result.stderr)

    def test_truncated_or_trailing_pixel_stream_is_rejected(self) -> None:
        target = self.icon_set / filename(16, 1)
        valid_rows = b"".join(b"\0" + b"\0" * (16 * 4) for _ in range(16))
        for failure, stream in (
            ("truncated", zlib.compress(valid_rows[:-1])),
            ("trailing", zlib.compress(valid_rows) + b"trailing"),
        ):
            with self.subTest(failure=failure):
                target.write_bytes(png_with_idat(16, 16, stream))
                result = self.validate()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("pixel stream", result.stderr)

    def test_unexpected_encoding_and_scanline_filter_are_rejected(self) -> None:
        target = self.icon_set / filename(16, 1)
        valid_rows = b"".join(b"\0" + b"\0" * (16 * 4) for _ in range(16))
        target.write_bytes(
            png_with_idat(16, 16, zlib.compress(valid_rows), bit_depth=16)
        )
        result = self.validate()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("encoding", result.stderr)

        invalid_filter_rows = bytearray(valid_rows)
        invalid_filter_rows[0] = 5
        target.write_bytes(
            png_with_idat(16, 16, zlib.compress(invalid_filter_rows))
        )
        result = self.validate()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("filter", result.stderr)

    def test_unknown_critical_png_chunk_is_rejected(self) -> None:
        target = self.icon_set / filename(16, 1)
        data = png(16, 16)
        kind = b"ABCD"
        payload = b"unknown critical payload"
        checksum = zlib.crc32(kind + payload) & 0xFFFF_FFFF
        chunk = (
            struct.pack(">I", len(payload))
            + kind
            + payload
            + struct.pack(">I", checksum)
        )
        target.write_bytes(data[:33] + chunk + data[33:])

        result = self.validate()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("critical PNG chunk", result.stderr)

    def test_unexpected_catalogue_entry_is_rejected(self) -> None:
        (self.icon_set / "stale.png").write_bytes(png(16, 16))

        result = self.validate()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("stale.png", result.stderr)

    def test_contents_json_must_name_the_exact_generated_slots(self) -> None:
        manifest = self.icon_set / "Contents.json"
        value = json.loads(manifest.read_text(encoding="utf-8"))
        value["images"][0]["scale"] = "3x"
        manifest.write_text(json.dumps(value), encoding="utf-8")

        result = self.validate()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Contents.json", result.stderr)

    def test_truncated_document_icon_is_rejected(self) -> None:
        self.document.write_bytes(b"icns" + struct.pack(">I", 4_096))

        result = self.validate()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("DocumentIcon.icns", result.stderr)

    def test_oversized_document_icon_is_rejected_before_reading(self) -> None:
        with self.document.open("wb") as stream:
            stream.truncate(16 * 1024 * 1024 + 1)

        result = self.validate()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("size safety limit", result.stderr)

    def test_document_icon_representation_dimensions_are_rejected(self) -> None:
        data = self.document.read_bytes()
        marker = data.index(b"ic12")
        payload_start = marker + 8
        payload_length = struct.unpack_from(">I", data, marker + 4)[0] - 8
        replacement = png(63, 64)
        rewritten = (
            data[: marker + 4]
            + struct.pack(">I", len(replacement) + 8)
            + replacement
            + data[payload_start + payload_length :]
        )
        rewritten = rewritten[:4] + struct.pack(">I", len(rewritten)) + rewritten[8:]
        self.document.write_bytes(rewritten)

        result = self.validate()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("DocumentIcon.icns ic12", result.stderr)
        self.assertIn("expected 64x64", result.stderr)

    def test_transparent_legacy_document_icon_representation_is_rejected(self) -> None:
        replacement = legacy_argb(
            16,
            16,
            bytes((0, 0, 0, 0)) * (16 * 16),
        )
        self.document.write_bytes(
            replacing_icns_chunk(self.document.read_bytes(), b"ic04", replacement)
        )

        result = self.validate()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("DocumentIcon.icns ic04", result.stderr)
        self.assertIn("visually empty", result.stderr)

    def test_each_generated_output_must_be_fresh_against_every_source(self) -> None:
        source = self.root / "MarkDevLogo.swift"
        source.write_text("// changed geometry\n", encoding="utf-8")
        stale = self.icon_set / filename(512, 2)
        stale.touch()
        source.touch()

        result = self.validate(source)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn(stale.name, result.stderr)

    def test_just_fast_path_validates_before_reporting_up_to_date(self) -> None:
        source = (REPO / "justfile").read_text(encoding="utf-8")
        recipe = source.split("\nicons:\n", 1)[1].split(
            "\n# --- Xcode project", 1
        )[0]
        validation = 'python3 "$validator" "$catalog" "$document" $freshness_sources'

        self.assertGreaterEqual(
            recipe.count(validation),
            2,
            "the fast path and freshly generated output must both be validated",
        )
        self.assertLess(
            recipe.index(validation),
            recipe.index('echo "icons: up to date"'),
            "the fast path may report success only after full catalogue validation",
        )


if __name__ == "__main__":
    unittest.main()
