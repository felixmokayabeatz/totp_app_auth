import base64
import hashlib
import json
import secrets
import string
from io import BytesIO
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

    rect(0, 0, page_width, page_height, fill=page_bg)
    rect(0, page_height - 190, page_width, 190, fill=hero_bg)
    rect(margin, page_height - 212, page_width - (margin * 2), 4, fill=hero_accent)
    text(margin, y, "BeatzLock Auth", size=28, font="F2", color=hero_title)
    y -= 34
    text(
        margin,
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
        width_chars=72,
        size=11,
        color=hero_body,
    )

    y = page_height - 250
    card_height = 138
    info_width = (page_width - (margin * 2) - 16) / 2
    rect(margin, y, info_width, card_height, fill=card_fill, stroke=card_stroke)
    rect(margin + info_width + 16, y, info_width, card_height, fill=card_fill, stroke=card_stroke)
    text(margin + 18, y + 108, "Account", size=11, font="F2", color=label_color)
    text(margin + 18, y + 84, account_name, size=18, font="F2", color=heading_color)
    text(margin + 18, y + 54, "Generated", size=11, font="F2", color=label_color)
    text(margin + 18, y + 30, generated_at or "Just now", size=12, font="F2", color=heading_color)
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
    multiline(
        margin + info_width + 34,
        y + 30,
        generated_from or "Primary device",
        width_chars=24,
        size=12,
        font="F2",
        color=heading_color,
        leading=14,
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
    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        (
            f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {page_width} {page_height}] "
            "/Resources << /Font << /F1 4 0 R /F2 5 0 R >> >> /Contents 6 0 R >>"
        ).encode("ascii"),
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold >>",
        f"<< /Length {len(stream)} >>\nstream\n".encode("ascii") + stream + b"\nendstream",
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
