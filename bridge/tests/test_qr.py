"""Comprehensive ISO/IEC 18004 verification tests for pure-Python QR encoder & renderer."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

_BRIDGE_ROOT = str(Path(__file__).resolve().parent.parent)
if _BRIDGE_ROOT not in sys.path:
    sys.path.insert(0, _BRIDGE_ROOT)

from antigravity_bridge.config import build_pairing_uri
from antigravity_bridge.qr import (
    _EC_TABLES,
    _GF_EXP,
    _GF_LOG,
    _REMAINDER_BITS,
    _build_base_matrix,
    _gf_mul,
    _mask_predicate,
    compute_format_bits,
    compute_version_bits,
    encode_qr,
    render_qr_terminal,
)


def _rs_syndrome(codeword_block: list[int], ec_count: int) -> list[int]:
    """Evaluate Reed-Solomon syndromes at alpha^0 .. alpha^(ec_count-1). All zeros iff valid."""
    syndromes: list[int] = []
    for i in range(ec_count):
        root = _GF_EXP[i]
        acc = 0
        for cw in codeword_block:
            acc = _gf_mul(acc, root) ^ cw
        syndromes.append(acc)
    return syndromes


def _decode_qr_matrix(matrix: list[list[bool]]) -> tuple[int, str, int, bytes]:
    """Independent ISO/IEC 18004 decoder validating format/version bits, RS syndromes, and payload."""
    size = len(matrix)
    version = (size - 17) // 4
    assert size == 17 + 4 * version

    # Read format info from both copies and confirm they match
    tl_coords = [
        (8, 0), (8, 1), (8, 2), (8, 3), (8, 4), (8, 5), (8, 7), (8, 8),
        (7, 8), (5, 8), (4, 8), (3, 8), (2, 8), (1, 8), (0, 8),
    ]
    split_coords = [
        (size - 1, 8), (size - 2, 8), (size - 3, 8), (size - 4, 8),
        (size - 5, 8), (size - 6, 8), (size - 7, 8),
        (8, size - 8), (8, size - 7), (8, size - 6), (8, size - 5),
        (8, size - 4), (8, size - 3), (8, size - 2), (8, size - 1),
    ]
    fmt1 = 0
    fmt2 = 0
    for r, c in tl_coords:
        fmt1 = (fmt1 << 1) | int(matrix[r][c])
    for r, c in split_coords:
        fmt2 = (fmt2 << 1) | int(matrix[r][c])
    assert fmt1 == fmt2, f"Format copies differ: {fmt1:#017b} != {fmt2:#017b}"

    unmasked_fmt = fmt1 ^ 0x5412
    ec_bits = (unmasked_fmt >> 13) & 0b11
    mask_id = (unmasked_fmt >> 10) & 0b111
    ec_map = {0b01: "L", 0b00: "M"}
    assert ec_bits in ec_map, f"Unexpected EC indicator bits: {ec_bits:#b}"
    ec_level = ec_map[ec_bits]
    assert fmt1 == compute_format_bits(ec_level, mask_id)

    # Check dark module
    assert matrix[4 * version + 9][8] is True

    # Check version info for Version >= 7
    if version >= 7:
        v1 = 0
        v2 = 0
        for i in range(18):
            a = i // 3
            b = i % 3
            if matrix[a][size - 11 + b]:
                v1 |= 1 << i
            if matrix[size - 11 + b][a]:
                v2 |= 1 << i
        expected_v = compute_version_bits(version)
        assert v1 == expected_v and v2 == expected_v

    # Rebuild function-module mask and read raw bitstream in zig-zag order
    _, is_func = _build_base_matrix(version)
    bits: list[int] = []
    upward = True
    col = size - 1
    while col > 0:
        if col == 6:
            col -= 1
        row_range = range(size - 1, -1, -1) if upward else range(size)
        for row in row_range:
            for dc in (0, -1):
                c = col + dc
                if not is_func[row][c]:
                    val = matrix[row][c]
                    if _mask_predicate(mask_id, row, c):
                        val = not val
                    bits.append(int(val))
        upward = not upward
        col -= 2

    ec_per_block, g1_b, g1_d, g2_b, g2_d = _EC_TABLES[ec_level][version]
    total_cw = g1_b * (g1_d + ec_per_block) + g2_b * (g2_d + ec_per_block)
    assert len(bits) == total_cw * 8 + _REMAINDER_BITS[version], (
        f"Bit count mismatch for V{version}: got {len(bits)}, expected {total_cw * 8 + _REMAINDER_BITS[version]}"
    )

    codewords: list[int] = []
    for i in range(0, total_cw * 8, 8):
        val = 0
        for b in bits[i : i + 8]:
            val = (val << 1) | b
        codewords.append(val)

    # De-interleave data and EC blocks and verify RS syndromes
    block_data_lens = [g1_d] * g1_b + [g2_d] * g2_b
    num_blocks = len(block_data_lens)
    data_blocks: list[list[int]] = [[] for _ in range(num_blocks)]
    ec_blocks: list[list[int]] = [[] for _ in range(num_blocks)]

    idx = 0
    max_data_len = max(block_data_lens)
    for col_i in range(max_data_len):
        for b_i in range(num_blocks):
            if col_i < block_data_lens[b_i]:
                data_blocks[b_i].append(codewords[idx])
                idx += 1
    for _ in range(ec_per_block):
        for b_i in range(num_blocks):
            ec_blocks[b_i].append(codewords[idx])
            idx += 1
    assert idx == len(codewords)

    for b_i in range(num_blocks):
        full_block = data_blocks[b_i] + ec_blocks[b_i]
        syndromes = _rs_syndrome(full_block, ec_per_block)
        assert all(s == 0 for s in syndromes), f"Non-zero RS syndrome in block {b_i}: {syndromes}"

    # Reconstruct Byte-mode payload
    data_stream: list[int] = []
    for blk in data_blocks:
        for cw in blk:
            for shift in range(7, -1, -1):
                data_stream.append((cw >> shift) & 1)

    def read_int(pos: int, width: int) -> tuple[int, int]:
        v = 0
        for b in data_stream[pos : pos + width]:
            v = (v << 1) | b
        return v, pos + width

    mode, pos = read_int(0, 4)
    assert mode == 0b0100, f"Expected Byte mode 0100, got {mode:#06b}"
    count_width = 8 if version <= 9 else 16
    length, pos = read_int(pos, count_width)
    out = bytearray()
    for _ in range(length):
        byte_val, pos = read_int(pos, 8)
        out.append(byte_val)

    return version, ec_level, mask_id, bytes(out)


class QRCodeTests(unittest.TestCase):
    def test_round_trip_across_versions_1_to_12_level_L_and_M(self) -> None:
        samples = [
            "hello",
            "https://example.com/antigravity",
            build_pairing_uri(
                "http://192.168.1.42:8765",
                "tok_1234567890abcdefghijklmnopqrstuvwxyzABCDEF",
                "Nick's MacBook Pro",
            ),
            "A" * 165,  # forces Version 8+ (version info blocks)
            "B" * 240,  # forces Version 10+ (16-bit byte count indicator & 2-group RS interleaving)
        ]
        for ec_level in ("L", "M"):
            for sample in samples:
                with self.subTest(ec_level=ec_level, length=len(sample)):
                    qr = encode_qr(sample, ec_level=ec_level)
                    self.assertEqual(qr.size, 17 + 4 * qr.version)
                    dec_ver, dec_ec, dec_mask, dec_payload = _decode_qr_matrix(qr.matrix)
                    self.assertEqual(dec_ver, qr.version)
                    self.assertEqual(dec_ec, ec_level)
                    self.assertEqual(dec_mask, qr.mask_id)
                    self.assertEqual(dec_payload.decode("utf-8"), sample)

    def test_every_version_1_through_12_exact_bit_capacity_and_patterns(self) -> None:
        for version in range(1, 13):
            with self.subTest(version=version):
                qr = encode_qr(f"v{version}-test", ec_level="L", min_version=version)
                self.assertEqual(qr.version, version)
                self.assertEqual(qr.size, 17 + 4 * version)

                # Verify 3 finder pattern centers are 3x3 dark squares
                size = qr.size
                for top, left in ((0, 0), (0, size - 7), (size - 7, 0)):
                    for dr in range(2, 5):
                        for dc in range(2, 5):
                            self.assertTrue(qr.matrix[top + dr][left + dc])

                # Verify timing pattern alternation on row 6 and col 6
                for i in range(8, size - 8):
                    self.assertEqual(qr.matrix[6][i], (i % 2) == 0)
                    self.assertEqual(qr.matrix[i][6], (i % 2) == 0)

                dec_ver, _, _, dec_payload = _decode_qr_matrix(qr.matrix)
                self.assertEqual(dec_ver, version)
                self.assertEqual(dec_payload, f"v{version}-test".encode("utf-8"))

    def test_terminal_and_ascii_renderers(self) -> None:
        uri = build_pairing_uri("http://10.0.0.5:8765", "secret-token-abc123", "Workstation")
        rendered_dark = render_qr_terminal(uri, border=2, invert=True)
        rendered_light = render_qr_terminal(uri, border=2, invert=False)
        self.assertTrue(any(ch in rendered_dark for ch in ("█", "▀", "▄")))
        self.assertNotEqual(rendered_dark, rendered_light)

        lines = rendered_dark.splitlines()
        self.assertGreater(len(lines), 10)
        # Every line must have equal visual width
        widths = {len(line) for line in lines}
        self.assertEqual(len(widths), 1)

        ascii_art = encode_qr(uri).render_ascii(border=2)
        self.assertIn("##", ascii_art)

    def test_payload_too_large_raises_value_error(self) -> None:
        with self.assertRaises(ValueError):
            encode_qr("X" * 1000, ec_level="L")


if __name__ == "__main__":
    unittest.main()
