import base64
import hashlib
import json
import secrets
import string
import struct
import zlib
from functools import lru_cache
from io import BytesIO
from pathlib import Path
from textwrap import wrap

from cryptography.fernet import Fernet
from django.conf import settings


BACKUP_CODE_ALPHABET = string.ascii_uppercase + string.digits
BACKUP_CODE_COUNT = 3
BACKUP_CODE_LENGTH = 10


def generate_backup_codes() -> list[str]:
    codes: set[str] = set()
    while len(codes) < BACKUP_CODE_COUNT:
        codes.add(
            ''.join(
                secrets.choice(BACKUP_CODE_ALPHABET)
                for _ in range(BACKUP_CODE_LENGTH)
            )
        )
    return sorted(codes)


def normalize_backup_code(raw_code: str) -> str:
    return ''.join(ch for ch in raw_code.upper() if ch.isalnum())


def build_backup_code_entries(codes: list[str]) -> list[dict[str, str | None]]:
    return [
        {
            "code": normalize_backup_code(code),
            "used_at": None,
        }
        for code in codes
    ]


def _get_cipher() -> Fernet:
    digest = hashlib.sha256(
        f"beatzlock-backup-codes|{settings.SECRET_KEY}".encode("utf-8")
    ).digest()
    return Fernet(base64.urlsafe_b64encode(digest))


def encrypt_backup_codes(payload_data) -> str:
    payload = json.dumps(payload_data).encode("utf-8")
    return _get_cipher().encrypt(payload).decode("utf-8")


def decrypt_backup_codes(encrypted_codes: str):
    payload = _get_cipher().decrypt(encrypted_codes.encode("utf-8"))
    return json.loads(payload.decode("utf-8"))


def normalize_backup_code_entries(payload_data) -> list[dict[str, str | None]]:
    if not isinstance(payload_data, list):
        raise ValueError("Invalid backup code payload")

    entries: list[dict[str, str | None]] = []
    for item in payload_data:
        if isinstance(item, str):
            entries.append({"code": normalize_backup_code(item), "used_at": None})
            continue

        if isinstance(item, dict):
            entries.append(
                {
                    "code": normalize_backup_code(str(item.get("code", ""))),
                    "used_at": item.get("used_at"),
                }
            )
            continue

        raise ValueError("Invalid backup code entry")

    return entries


def remaining_backup_codes(entries: list[dict[str, str | None]]) -> int:
    return sum(1 for entry in entries if not entry.get("used_at"))


def _paeth_predictor(a: int, b: int, c: int) -> int:
    p = a + b - c
    pa = abs(p - a)
    pb = abs(p - b)
    pc = abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    if pb <= pc:
        return b
    return c


def _unfilter_png_scanlines(raw: bytes, width: int, height: int, bytes_per_pixel: int) -> bytes:
    stride = width * bytes_per_pixel
    rows: list[bytes] = []
    offset = 0

    for _ in range(height):
        filter_type = raw[offset]
        offset += 1
        scanline = bytearray(raw[offset:offset + stride])
        offset += stride
        previous = rows[-1] if rows else bytes(stride)

        if filter_type == 1:
            for i in range(stride):
                left = scanline[i - bytes_per_pixel] if i >= bytes_per_pixel else 0
                scanline[i] = (scanline[i] + left) & 0xFF
        elif filter_type == 2:
            for i in range(stride):
                scanline[i] = (scanline[i] + previous[i]) & 0xFF
        elif filter_type == 3:
            for i in range(stride):
                left = scanline[i - bytes_per_pixel] if i >= bytes_per_pixel else 0
                up = previous[i]
                scanline[i] = (scanline[i] + ((left + up) // 2)) & 0xFF
        elif filter_type == 4:
            for i in range(stride):
                left = scanline[i - bytes_per_pixel] if i >= bytes_per_pixel else 0
                up = previous[i]
                up_left = previous[i - bytes_per_pixel] if i >= bytes_per_pixel else 0
                scanline[i] = (scanline[i] + _paeth_predictor(left, up, up_left)) & 0xFF
        elif filter_type != 0:
            raise ValueError("Unsupported PNG filter type")

        rows.append(bytes(scanline))

    return b"".join(rows)


@lru_cache(maxsize=1)
def _load_pdf_logo() -> dict[str, object]:
    logo_path = (
        Path(__file__).resolve().parents[1]
        / "static"
        / "favicon"
        / "app_icon.ico"
    )
    data = logo_path.read_bytes()

    reserved, icon_type, count = struct.unpack("<HHH", data[:6])
    if reserved != 0 or icon_type != 1 or count <= 0:
        raise ValueError("Unsupported ICO logo format")

    chosen_payload = None
    chosen_score = -1
    for index in range(count):
        entry_offset = 6 + (index * 16)
        width, height, _, _, _, _, size, offset = struct.unpack(
            "<BBBBHHII",
            data[entry_offset:entry_offset + 16],
        )
        actual_width = width or 256
        actual_height = height or 256
        payload = data[offset:offset + size]
        if payload[:8] != b"\x89PNG\r\n\x1a\n":
            continue

        score = min(actual_width, 128) * min(actual_height, 128)
        if score > chosen_score:
            chosen_score = score
            chosen_payload = payload

    if chosen_payload is None:
        raise ValueError("No PNG payload found in ICO logo")

    data = chosen_payload

    offset = 8
    width = height = 0
    bit_depth = color_type = interlace = 0
    idat_parts: list[bytes] = []

    while offset < len(data):
        chunk_length = struct.unpack(">I", data[offset:offset + 4])[0]
        chunk_type = data[offset + 4:offset + 8]
        chunk_data = data[offset + 8:offset + 8 + chunk_length]
        offset += chunk_length + 12

        if chunk_type == b"IHDR":
            width, height, bit_depth, color_type, _, _, interlace = struct.unpack(
                ">IIBBBBB",
                chunk_data,
            )
        elif chunk_type == b"IDAT":
            idat_parts.append(chunk_data)
        elif chunk_type == b"IEND":
            break

    if bit_depth != 8 or color_type != 6 or interlace != 0:
        raise ValueError("Unsupported logo PNG color profile")

    decompressed = zlib.decompress(b"".join(idat_parts))
    pixels = _unfilter_png_scanlines(decompressed, width, height, 4)

    return {
        "width": width,
        "height": height,
        "pixels": pixels,
    }


def build_backup_codes_pdf(
    *,
    email: str,
    account_name: str,
    codes: list[str],
    generated_at: str = '',
    generated_from: str = '',
    theme: str = 'light',
) -> bytes:
    page_width = 595
    page_height = 842
    margin = 40
    y = page_height - 60
    commands: list[str] = []
    is_dark = str(theme).strip().lower() == 'dark'

    page_bg = (0.08, 0.09, 0.15) if is_dark else (1, 1, 1)
    hero_bg = (0.08, 0.11, 0.22) if is_dark else (0.09, 0.13, 0.33)
    hero_accent = (0.38, 0.74, 0.99) if is_dark else (0.31, 0.71, 0.98)
    hero_title = (1, 1, 1)
    hero_subtitle = (0.82, 0.88, 1)
    hero_body = (0.88, 0.91, 0.98)
    card_fill = (0.13, 0.16, 0.24) if is_dark else (0.96, 0.98, 1)
    card_stroke = (0.26, 0.32, 0.44) if is_dark else (0.82, 0.87, 0.96)
    label_color = (0.68, 0.75, 0.88) if is_dark else (0.31, 0.39, 0.56)
    heading_color = (0.95, 0.97, 1) if is_dark else (0.09, 0.13, 0.24)
    body_color = (0.78, 0.82, 0.90) if is_dark else (0.42, 0.47, 0.56)
    code_fill = (0.10, 0.12, 0.18) if is_dark else (1, 1, 1)
    code_stroke = (0.24, 0.29, 0.39) if is_dark else (0.86, 0.89, 0.94)
    note_fill = (0.25, 0.18, 0.08) if is_dark else (1.0, 0.97, 0.92)
    note_stroke = (0.75, 0.55, 0.25) if is_dark else (0.95, 0.79, 0.55)
    note_heading = (1.0, 0.80, 0.42) if is_dark else (0.69, 0.36, 0.04)
    note_body = (0.97, 0.90, 0.78) if is_dark else (0.43, 0.29, 0.09)
    footer_color = (0.57, 0.63, 0.74) if is_dark else (0.47, 0.51, 0.60)
    generated_at_display = (generated_at or "Just now").strip()
    generated_from_display = (generated_from or "Primary device").strip()
    logo = _load_pdf_logo()
    title_text = "BeatzLock Authenticator"

    def esc(value: str) -> str:
        return (
            value.replace("\\", "\\\\")
            .replace("(", "\\(")
            .replace(")", "\\)")
        )

    def text(x: float, y_pos: float, value: str, *, size: int = 12,
             font: str = "F1", color: tuple[float, float, float] = (0, 0, 0)) -> None:
        commands.append(
            f"BT /{font} {size} Tf {color[0]:.3f} {color[1]:.3f} {color[2]:.3f} rg "
            f"1 0 0 1 {x:.2f} {y_pos:.2f} Tm ({esc(value)}) Tj ET"
        )

    def rect(x: float, y_pos: float, width: float, height: float,
             *, fill: tuple[float, float, float] | None = None,
             stroke: tuple[float, float, float] | None = None,
             line_width: float = 1) -> None:
        if fill is not None:
            commands.append(
                f"q {fill[0]:.3f} {fill[1]:.3f} {fill[2]:.3f} rg "
                f"{x:.2f} {y_pos:.2f} {width:.2f} {height:.2f} re f Q"
            )
        if stroke is not None:
            commands.append(
                f"q {line_width:.2f} w {stroke[0]:.3f} {stroke[1]:.3f} {stroke[2]:.3f} RG "
                f"{x:.2f} {y_pos:.2f} {width:.2f} {height:.2f} re S Q"
            )

    def multiline(x: float, y_pos: float, value: str, *, width_chars: int,
                  size: int = 11, font: str = "F1",
                  color: tuple[float, float, float] = (0.2, 0.2, 0.2),
                  leading: int = 15) -> float:
        current_y = y_pos
        for line in wrap(value, width_chars):
            text(x, current_y, line, size=size, font=font, color=color)
            current_y -= leading
        return current_y

    def bounded_lines(value: str, *, width_chars: int, max_lines: int) -> list[str]:
        lines = wrap(value, width_chars) or ['']
        if len(lines) <= max_lines:
            return lines

        trimmed = lines[:max_lines]
        last = trimmed[-1]
        if len(last) > 3:
            trimmed[-1] = f"{last[:-3]}..."
        else:
            trimmed[-1] = f"{last}..."
        return trimmed

    def image(x: float, y_pos: float, width: float, height: float, name: str) -> None:
        commands.append(
            f"q {width:.2f} 0 0 {height:.2f} {x:.2f} {y_pos:.2f} cm /{name} Do Q"
        )

    def estimated_text_width(value: str, size: int, *, weight: str = "regular") -> float:
        factor = 0.60 if weight == "bold" else 0.53
        return len(value) * size * factor

    def flatten_logo_rgb_stream() -> bytes:
        hero_bg_rgb = tuple(int(channel * 255) for channel in hero_bg)
        width = int(logo["width"])
        height = int(logo["height"])
        pixels = logo["pixels"]
        rows: list[bytes] = []

        for row_index in range(height):
            row = pixels[row_index * width * 4:(row_index + 1) * width * 4]
            rgb_row = bytearray()
            for pixel_index in range(0, len(row), 4):
                src_r, src_g, src_b, alpha = row[pixel_index:pixel_index + 4]
                alpha_ratio = alpha / 255.0
                rgb_row.extend([
                    int((src_r * alpha_ratio) + (hero_bg_rgb[0] * (1 - alpha_ratio))),
                    int((src_g * alpha_ratio) + (hero_bg_rgb[1] * (1 - alpha_ratio))),
                    int((src_b * alpha_ratio) + (hero_bg_rgb[2] * (1 - alpha_ratio))),
                ])
            rows.append(bytes(rgb_row))

        return zlib.compress(b"".join(b"\x00" + row for row in rows))

    rect(0, 0, page_width, page_height, fill=page_bg)
    rect(0, page_height - 220, page_width, 220, fill=hero_bg)
    rect(margin, page_height - 242, page_width - (margin * 2), 4, fill=hero_accent)
    logo_size = 48
    logo_x = (page_width - logo_size) / 2
    image(logo_x, y - 14, logo_size, logo_size, "ImLogo")
    y -= 64
    text(
        (page_width - estimated_text_width(title_text, 28, weight="bold")) / 2,
        y,
        title_text,
        size=28,
        font="F2",
        color=hero_title,
    )
    y -= 34
    text(
        (page_width - estimated_text_width("Backup recovery codes", 16, weight="bold")) / 2,
        y,
        "Backup recovery codes",
        size=16,
        font="F2",
        color=hero_subtitle,
    )
    y -= 26
    y = multiline(
        margin,
        y,
        "Keep this PDF somewhere safe. Each code can help you get back into your account if you lose access to your device or your normal sign-in method.",
        width_chars=76,
        size=11,
        color=hero_body,
    )

    y = y - 26 - 138
    card_height = 138
    info_width = (page_width - (margin * 2) - 16) / 2
    rect(margin, y, info_width, card_height, fill=card_fill, stroke=card_stroke)
    rect(margin + info_width + 16, y, info_width, card_height, fill=card_fill, stroke=card_stroke)
    text(margin + 18, y + 108, "Account", size=11, font="F2", color=label_color)
    text(margin + 18, y + 84, title_text, size=18, font="F2", color=heading_color)
    text(margin + 18, y + 54, "Generated", size=11, font="F2", color=label_color)
    for index, line in enumerate(bounded_lines(generated_at_display, width_chars=28, max_lines=2)):
        text(
            margin + 18,
            y + 30 - (index * 14),
            line,
            size=12,
            font="F2",
            color=heading_color,
        )
    text(margin + info_width + 34, y + 108, "Email", size=11, font="F2", color=label_color)
    text(margin + info_width + 34, y + 84, email, size=14, font="F2", color=heading_color)
    text(
        margin + info_width + 34,
        y + 54,
        "Generated from primary device",
        size=11,
        font="F2",
        color=label_color,
    )
    for index, line in enumerate(bounded_lines(generated_from_display, width_chars=22, max_lines=2)):
        text(
            margin + info_width + 34,
            y + 30 - (index * 14),
            line,
            size=12,
            font="F2",
            color=heading_color,
        )

    section_y = y - 52
    text(margin, section_y, "Your backup codes", size=17, font="F2", color=heading_color)
    text(
        margin,
        section_y - 18,
        "Use each code carefully and store them offline if possible.",
        size=10,
        color=body_color,
    )

    block_y = section_y - 64
    block_height = 78
    for index, code in enumerate(codes, start=1):
        rect(
            margin,
            block_y,
            page_width - (margin * 2),
            block_height,
            fill=code_fill,
            stroke=code_stroke,
        )
        text(margin + 18, block_y + 46, f"Code {index}", size=11, font="F2", color=label_color)
        text(margin + 18, block_y + 18, code, size=24, font="F2", color=heading_color)
        block_y -= block_height + 16

    note_y = 110
    rect(margin, note_y, page_width - (margin * 2), 86, fill=note_fill, stroke=note_stroke)
    text(margin + 18, note_y + 58, "Important", size=13, font="F2", color=note_heading)
    multiline(
        margin + 18,
        note_y + 38,
        "Anyone with these backup codes may be able to recover access. Do not share this document. If you think it has been exposed, generate a fresh set from BeatzLock.",
        width_chars=78,
        size=10,
        color=note_body,
        leading=13,
    )
    text(margin, 48, "Generated by BeatzLock Auth", size=10, color=footer_color)

    stream = "\n".join(commands).encode("latin-1", "replace")
    rgb_stream = flatten_logo_rgb_stream()
    logo_width = logo["width"]
    logo_height = logo["height"]

    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        (
            f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {page_width} {page_height}] "
            "/Resources << /Font << /F1 4 0 R /F2 5 0 R >> "
            "/XObject << /ImLogo 7 0 R >> >> /Contents 6 0 R >>"
        ).encode("ascii"),
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold >>",
        f"<< /Length {len(stream)} >>\nstream\n".encode("ascii") + stream + b"\nendstream",
        (
            f"<< /Type /XObject /Subtype /Image /Width {logo_width} /Height {logo_height} "
            f"/ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /FlateDecode "
            f"/DecodeParms << /Predictor 15 /Colors 3 /BitsPerComponent 8 /Columns {logo_width} >> "
            f"/Length {len(rgb_stream)} >>\nstream\n"
        ).encode("ascii") + rgb_stream + b"\nendstream",
    ]

    buffer = BytesIO()
    buffer.write(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
    offsets = [0]
    for index, obj in enumerate(objects, start=1):
        offsets.append(buffer.tell())
        buffer.write(f"{index} 0 obj\n".encode("ascii"))
        buffer.write(obj)
        buffer.write(b"\nendobj\n")

    xref_offset = buffer.tell()
    buffer.write(f"xref\n0 {len(objects) + 1}\n".encode("ascii"))
    buffer.write(b"0000000000 65535 f \n")
    for offset in offsets[1:]:
        buffer.write(f"{offset:010d} 00000 n \n".encode("ascii"))
    buffer.write(
        (
            f"trailer\n<< /Size {len(objects) + 1} /Root 1 0 R >>\n"
            f"startxref\n{xref_offset}\n%%EOF"
        ).encode("ascii")
    )
    return buffer.getvalue()
