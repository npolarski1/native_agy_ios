"""Pure-Python ISO/IEC 18004 QR Code encoder and Unicode half-block terminal renderer."""

from __future__ import annotations

from dataclasses import dataclass


# GF(256) with primitive polynomial x^8 + x^4 + x^3 + x^2 + 1 (0x11D)
_GF_EXP = [0] * 512
_GF_LOG = [0] * 256


def _init_gf_tables() -> None:
    val = 1
    for i in range(255):
        _GF_EXP[i] = val
        _GF_LOG[val] = i
        val <<= 1
        if val & 0x100:
            val ^= 0x11D
    for i in range(255, 512):
        _GF_EXP[i] = _GF_EXP[i - 255]


_init_gf_tables()


def _gf_mul(a: int, b: int) -> int:
    if a == 0 or b == 0:
        return 0
    return _GF_EXP[_GF_LOG[a] + _GF_LOG[b]]


def _rs_generator_poly(degree: int) -> list[int]:
    """Return Reed-Solomon generator polynomial coefficients (highest degree first)."""
    poly = [1]
    for i in range(degree):
        root = _GF_EXP[i]
        nxt = [0] * (len(poly) + 1)
        for j, coeff in enumerate(poly):
            nxt[j] ^= coeff
            nxt[j + 1] ^= _gf_mul(coeff, root)
        poly = nxt
    return poly


def rs_encode_block(data: list[int], ec_count: int) -> list[int]:
    """Compute Reed-Solomon error correction codewords for a single block."""
    gen = _rs_generator_poly(ec_count)
    reg = [0] * ec_count
    for byte in data:
        factor = byte ^ reg[0]
        reg = reg[1:] + [0]
        if factor != 0:
            for i in range(ec_count):
                reg[i] ^= _gf_mul(gen[i + 1], factor)
    return reg


# Alignment pattern center coordinates per version (ISO/IEC 18004 Annex E)
_ALIGNMENT_COORDS: dict[int, tuple[int, ...]] = {
    1: (),
    2: (6, 18),
    3: (6, 22),
    4: (6, 26),
    5: (6, 30),
    6: (6, 34),
    7: (6, 22, 38),
    8: (6, 24, 42),
    9: (6, 26, 46),
    10: (6, 28, 50),
    11: (6, 30, 54),
    12: (6, 32, 58),
}

# Remainder bits per version (ISO/IEC 18004 Table 1)
_REMAINDER_BITS: dict[int, int] = {
    1: 0,
    2: 7,
    3: 7,
    4: 7,
    5: 7,
    6: 7,
    7: 0,
    8: 0,
    9: 0,
    10: 0,
    11: 0,
    12: 0,
}

# ECC indicator bits for format info (ISO/IEC 18004 Table 12)
_EC_FORMAT_BITS: dict[str, int] = {
    "L": 0b01,
    "M": 0b00,
}

# Table 9: (ec_per_block, g1_blocks, g1_data_cw, g2_blocks, g2_data_cw)
_EC_TABLES: dict[str, dict[int, tuple[int, int, int, int, int]]] = {
    "L": {
        1: (7, 1, 19, 0, 0),
        2: (10, 1, 34, 0, 0),
        3: (15, 1, 55, 0, 0),
        4: (20, 1, 80, 0, 0),
        5: (26, 1, 108, 0, 0),
        6: (18, 2, 68, 0, 0),
        7: (20, 2, 78, 0, 0),
        8: (24, 2, 97, 0, 0),
        9: (30, 2, 116, 0, 0),
        10: (18, 2, 68, 2, 69),
        11: (20, 4, 81, 0, 0),
        12: (24, 2, 92, 2, 93),
    },
    "M": {
        1: (10, 1, 16, 0, 0),
        2: (16, 1, 28, 0, 0),
        3: (26, 1, 44, 0, 0),
        4: (18, 2, 32, 0, 0),
        5: (24, 2, 43, 0, 0),
        6: (16, 4, 27, 0, 0),
        7: (18, 4, 31, 0, 0),
        8: (22, 2, 38, 2, 39),
        9: (22, 3, 36, 2, 37),
        10: (26, 4, 43, 1, 44),
        11: (30, 1, 50, 4, 51),
        12: (22, 6, 36, 2, 37),
    },
}


def compute_format_bits(ec_level: str, mask_id: int) -> int:
    """Compute the 15-bit BCH(15,5) format information word XORed with 0x5412."""
    data = (_EC_FORMAT_BITS[ec_level] << 3) | (mask_id & 0x07)
    rem = data << 10
    for bit in range(14, 9, -1):
        if rem & (1 << bit):
            rem ^= 0x537 << (bit - 10)
    return ((data << 10) | rem) ^ 0x5412


def compute_version_bits(version: int) -> int:
    """Compute the 18-bit BCH(18,6) version information word (Versions 7+)."""
    rem = version << 12
    for bit in range(17, 11, -1):
        if rem & (1 << bit):
            rem ^= 0x1F25 << (bit - 12)
    return (version << 12) | rem


def _mask_predicate(mask_id: int, r: int, c: int) -> bool:
    if mask_id == 0:
        return (r + c) % 2 == 0
    if mask_id == 1:
        return r % 2 == 0
    if mask_id == 2:
        return c % 3 == 0
    if mask_id == 3:
        return (r + c) % 3 == 0
    if mask_id == 4:
        return ((r // 2) + (c // 3)) % 2 == 0
    if mask_id == 5:
        return ((r * c) % 2) + ((r * c) % 3) == 0
    if mask_id == 6:
        return (((r * c) % 2) + ((r * c) % 3)) % 2 == 0
    if mask_id == 7:
        return (((r + c) % 2) + ((r * c) % 3)) % 2 == 0
    raise ValueError(f"Invalid QR mask id: {mask_id}")


def _select_version(payload_len: int, ec_level: str, min_version: int = 1) -> int:
    table = _EC_TABLES[ec_level]
    for version in range(max(1, min_version), 13):
        _, g1_b, g1_d, g2_b, g2_d = table[version]
        total_data_cw = g1_b * g1_d + g2_b * g2_d
        count_bits = 8 if version <= 9 else 16
        needed_bits = 4 + count_bits + payload_len * 8
        if needed_bits <= total_data_cw * 8:
            return version
    raise ValueError(
        f"Payload of {payload_len} bytes exceeds supported QR code capacity for ECC level {ec_level}."
    )


def _encode_data_codewords(payload: bytes, version: int, ec_level: str) -> list[int]:
    _, g1_b, g1_d, g2_b, g2_d = _EC_TABLES[ec_level][version]
    total_data_cw = g1_b * g1_d + g2_b * g2_d
    total_data_bits = total_data_cw * 8

    bits: list[int] = []

    def append_bits(value: int, width: int) -> None:
        for shift in range(width - 1, -1, -1):
            bits.append((value >> shift) & 1)

    # Byte mode indicator (0100)
    append_bits(0b0100, 4)
    # Character count indicator (8 bits for v1..9, 16 bits for v10..26)
    append_bits(len(payload), 8 if version <= 9 else 16)
    for byte in payload:
        append_bits(byte, 8)

    # Terminator (up to 4 zero bits)
    term_len = min(4, total_data_bits - len(bits))
    bits.extend([0] * term_len)

    # Pad to byte boundary
    while len(bits) % 8 != 0:
        bits.append(0)

    codewords: list[int] = []
    for i in range(0, len(bits), 8):
        val = 0
        for b in bits[i : i + 8]:
            val = (val << 1) | b
        codewords.append(val)

    # Pad bytes alternating 0xEC, 0x11
    pad_bytes = (0xEC, 0x11)
    pad_idx = 0
    while len(codewords) < total_data_cw:
        codewords.append(pad_bytes[pad_idx & 1])
        pad_idx += 1

    return codewords


def _interleave_codewords(data_cw: list[int], version: int, ec_level: str) -> list[int]:
    ec_per_block, g1_b, g1_d, g2_b, g2_d = _EC_TABLES[ec_level][version]
    data_blocks: list[list[int]] = []
    ec_blocks: list[list[int]] = []

    offset = 0
    for _ in range(g1_b):
        blk = data_cw[offset : offset + g1_d]
        offset += g1_d
        data_blocks.append(blk)
        ec_blocks.append(rs_encode_block(blk, ec_per_block))
    for _ in range(g2_b):
        blk = data_cw[offset : offset + g2_d]
        offset += g2_d
        data_blocks.append(blk)
        ec_blocks.append(rs_encode_block(blk, ec_per_block))

    interleaved: list[int] = []
    max_data_len = max(len(b) for b in data_blocks)
    for col in range(max_data_len):
        for blk in data_blocks:
            if col < len(blk):
                interleaved.append(blk[col])

    for col in range(ec_per_block):
        for blk in ec_blocks:
            interleaved.append(blk[col])

    return interleaved


def _build_base_matrix(version: int) -> tuple[list[list[bool]], list[list[bool]]]:
    """Create (modules, is_function) grids populated with all fixed function patterns."""
    size = 17 + 4 * version
    modules = [[False] * size for _ in range(size)]
    is_func = [[False] * size for _ in range(size)]

    def set_func(r: int, c: int, dark: bool) -> None:
        if 0 <= r < size and 0 <= c < size:
            modules[r][c] = dark
            is_func[r][c] = True

    # Finder patterns + 1-module white separators
    def draw_finder(top: int, left: int) -> None:
        for dr in range(-1, 8):
            for dc in range(-1, 8):
                r, c = top + dr, left + dc
                if 0 <= r < size and 0 <= c < size:
                    in_outer = 0 <= dr <= 6 and 0 <= dc <= 6
                    on_border = dr in (0, 6) or dc in (0, 6)
                    in_center = 2 <= dr <= 4 and 2 <= dc <= 4
                    dark = in_outer and (on_border or in_center)
                    set_func(r, c, dark)

    draw_finder(0, 0)
    draw_finder(0, size - 7)
    draw_finder(size - 7, 0)

    # Alignment patterns
    coords = _ALIGNMENT_COORDS[version]
    for cr in coords:
        for cc in coords:
            # Skip positions overlapping the 3 finder patterns
            if (cr == 6 and cc == 6) or (cr == 6 and cc == coords[-1]) or (cr == coords[-1] and cc == 6):
                continue
            for dr in range(-2, 3):
                for dc in range(-2, 3):
                    dark = max(abs(dr), abs(dc)) != 1
                    set_func(cr + dr, cc + dc, dark)

    # Timing patterns (row 6 and col 6)
    for i in range(8, size - 8):
        dark = (i % 2) == 0
        if not is_func[6][i]:
            set_func(6, i, dark)
        if not is_func[i][6]:
            set_func(i, 6, dark)

    # Dark module at (4*version + 9, 8)
    set_func(4 * version + 9, 8, True)

    # Reserve format info modules
    for i in range(9):
        if i != 6:
            is_func[8][i] = True
            is_func[i][8] = True
    for i in range(8):
        is_func[8][size - 1 - i] = True
    for i in range(7):
        is_func[size - 1 - i][8] = True

    # Version info blocks for Version >= 7
    if version >= 7:
        ver_bits = compute_version_bits(version)
        for i in range(18):
            bit = bool((ver_bits >> i) & 1)
            a = i // 3
            b = i % 3
            set_func(a, size - 11 + b, bit)
            set_func(size - 11 + b, a, bit)

    return modules, is_func


def _write_format_info(modules: list[list[bool]], ec_level: str, mask_id: int) -> None:
    size = len(modules)
    fmt = compute_format_bits(ec_level, mask_id)

    # Top-left copy (MSB bit 14 -> LSB bit 0)
    tl_coords = [
        (8, 0),
        (8, 1),
        (8, 2),
        (8, 3),
        (8, 4),
        (8, 5),
        (8, 7),
        (8, 8),
        (7, 8),
        (5, 8),
        (4, 8),
        (3, 8),
        (2, 8),
        (1, 8),
        (0, 8),
    ]
    # Split copy (bottom-left col 8 + top-right row 8)
    split_coords = [
        (size - 1, 8),
        (size - 2, 8),
        (size - 3, 8),
        (size - 4, 8),
        (size - 5, 8),
        (size - 6, 8),
        (size - 7, 8),
        (8, size - 8),
        (8, size - 7),
        (8, size - 6),
        (8, size - 5),
        (8, size - 4),
        (8, size - 3),
        (8, size - 2),
        (8, size - 1),
    ]

    for idx in range(15):
        bit = bool((fmt >> (14 - idx)) & 1)
        r1, c1 = tl_coords[idx]
        r2, c2 = split_coords[idx]
        modules[r1][c1] = bit
        modules[r2][c2] = bit


def _place_data_bits(modules: list[list[bool]], is_func: list[list[bool]], codewords: list[int], version: int) -> None:
    size = len(modules)
    bits: list[bool] = []
    for cw in codewords:
        for shift in range(7, -1, -1):
            bits.append(bool((cw >> shift) & 1))
    bits.extend([False] * _REMAINDER_BITS[version])

    bit_idx = 0
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
                    modules[row][c] = bits[bit_idx] if bit_idx < len(bits) else False
                    bit_idx += 1
        upward = not upward
        col -= 2


def _penalty_score(modules: list[list[bool]]) -> int:
    """Calculate ISO/IEC 18004 mask evaluation penalty score (N1 + N2 + N3 + N4)."""
    size = len(modules)
    penalty = 0

    # N1: 5+ consecutive same-color modules in rows and columns
    def score_line(line: list[bool]) -> int:
        pts = 0
        run_color = line[0]
        run_len = 1
        for cell in line[1:]:
            if cell == run_color:
                run_len += 1
            else:
                if run_len >= 5:
                    pts += 3 + (run_len - 5)
                run_color = cell
                run_len = 1
        if run_len >= 5:
            pts += 3 + (run_len - 5)
        return pts

    # N3: finder-like 1:1:3:1:1 ratio surrounded by 4 light modules
    pat_a = [True, False, True, True, True, False, True, False, False, False, False]
    pat_b = [False, False, False, False, True, False, True, True, True, False, True]

    for r in range(size):
        row = modules[r]
        penalty += score_line(row)
        for c in range(size - 10):
            seg = row[c : c + 11]
            if seg == pat_a or seg == pat_b:
                penalty += 40

    for c in range(size):
        col = [modules[r][c] for r in range(size)]
        penalty += score_line(col)
        for r in range(size - 10):
            seg = col[r : r + 11]
            if seg == pat_a or seg == pat_b:
                penalty += 40

    # N2: 2x2 same-color blocks
    for r in range(size - 1):
        r0 = modules[r]
        r1 = modules[r + 1]
        for c in range(size - 1):
            v = r0[c]
            if v == r0[c + 1] == r1[c] == r1[c + 1]:
                penalty += 3

    # N4: deviation of dark module ratio from 50%
    dark_count = sum(1 for row in modules for cell in row if cell)
    total = size * size
    k = abs(dark_count * 20 - total * 10) // total
    penalty += k * 10
    return penalty


@dataclass(slots=True)
class QRCode:
    """Encoded QR code matrix (`True` = dark module, `False` = light module)."""

    version: int
    ec_level: str
    mask_id: int
    matrix: list[list[bool]]

    @property
    def size(self) -> int:
        return len(self.matrix)

    def render_terminal(self, *, border: int = 2, invert: bool = True) -> str:
        """Render the QR code using Unicode half-block characters (`█`, `▀`, `▄`, ` `).

        With `invert=True` (default), light modules and quiet zone are drawn with bright foreground
        blocks so the QR code scans cleanly on dark terminal backgrounds.
        """
        quiet = max(1, int(border))
        total_w = self.size + 2 * quiet
        padded: list[list[bool]] = []
        light_row = [False] * total_w
        for _ in range(quiet):
            padded.append(light_row)
        for row in self.matrix:
            padded.append([False] * quiet + list(row) + [False] * quiet)
        for _ in range(quiet):
            padded.append(light_row)

        if len(padded) % 2 == 1:
            padded.append(light_row)

        lines: list[str] = []
        for r in range(0, len(padded), 2):
            top_row = padded[r]
            bot_row = padded[r + 1]
            chars: list[str] = []
            for c in range(total_w):
                # When invert=True, foreground cell is drawn for LIGHT (False) modules.
                t_fg = (not top_row[c]) if invert else top_row[c]
                b_fg = (not bot_row[c]) if invert else bot_row[c]
                if t_fg and b_fg:
                    chars.append("█")
                elif t_fg:
                    chars.append("▀")
                elif b_fg:
                    chars.append("▄")
                else:
                    chars.append(" ")
            lines.append("".join(chars))
        return "\n".join(lines)

    def render_ascii(self, *, border: int = 2) -> str:
        """Render the QR code using pure ASCII `##` and spaces for legacy terminals."""
        quiet = max(1, int(border))
        total_w = self.size + 2 * quiet
        lines: list[str] = []
        blank = "  " * total_w
        for _ in range(quiet):
            lines.append(blank)
        for row in self.matrix:
            inner = "".join("##" if cell else "  " for cell in row)
            lines.append(("  " * quiet) + inner + ("  " * quiet))
        for _ in range(quiet):
            lines.append(blank)
        return "\n".join(lines)


def encode_qr(data: str | bytes, *, ec_level: str = "L", min_version: int = 1) -> QRCode:
    """Encode a string or bytes into an ISO/IEC 18004 QRCode matrix."""
    ec = ec_level.upper()
    if ec not in _EC_TABLES:
        raise ValueError(f"Unsupported ECC level '{ec_level}'. Supported: 'L', 'M'.")

    payload = data.encode("utf-8") if isinstance(data, str) else bytes(data)
    version = _select_version(len(payload), ec, min_version=min_version)
    data_cw = _encode_data_codewords(payload, version, ec)
    final_cw = _interleave_codewords(data_cw, version, ec)

    base_modules, is_func = _build_base_matrix(version)
    _place_data_bits(base_modules, is_func, final_cw, version)

    size = len(base_modules)
    best_mask = 0
    best_score = 10**9
    best_matrix: list[list[bool]] | None = None

    for mask_id in range(8):
        candidate = [row[:] for row in base_modules]
        for r in range(size):
            for c in range(size):
                if not is_func[r][c] and _mask_predicate(mask_id, r, c):
                    candidate[r][c] = not candidate[r][c]
        _write_format_info(candidate, ec, mask_id)
        score = _penalty_score(candidate)
        if score < best_score:
            best_score = score
            best_mask = mask_id
            best_matrix = candidate

    assert best_matrix is not None
    return QRCode(version=version, ec_level=ec, mask_id=best_mask, matrix=best_matrix)


def render_qr_terminal(data: str | bytes, *, ec_level: str = "L", border: int = 2, invert: bool = True) -> str:
    """Convenience helper encoding data and returning Unicode half-block terminal art."""
    return encode_qr(data, ec_level=ec_level).render_terminal(border=border, invert=invert)
