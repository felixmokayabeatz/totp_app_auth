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
) -> bytes:
    page_width = 595
    page_height = 842
    margin = 40
    y = page_height - 60
    commands: list[str] = []

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

    rect(0, page_height - 190, page_width, 190, fill=(0.09, 0.13, 0.33))
    rect(margin, page_height - 212, page_width - (margin * 2), 4, fill=(0.31, 0.71, 0.98))
    text(margin, y, "BeatzLock Auth", size=28, font="F2", color=(1, 1, 1))
    y -= 34
    text(
        margin,
        y,
        "Backup recovery codes",
        size=16,
        font="F2",
        color=(0.82, 0.88, 1),
    )
    y -= 26
    y = multiline(
        margin,
        y,
        "Keep this PDF somewhere safe. Each code can help you get back into your account if you lose access to your device or your normal sign-in method.",
        width_chars=72,
        size=11,
        color=(0.90, 0.93, 1),
    )

    y = page_height - 250
    card_height = 92
    info_width = (page_width - (margin * 2) - 16) / 2
    rect(margin, y, info_width, card_height, fill=(0.96, 0.98, 1), stroke=(0.82, 0.87, 0.96))
    rect(margin + info_width + 16, y, info_width, card_height, fill=(0.96, 0.98, 1), stroke=(0.82, 0.87, 0.96))
    text(margin + 18, y + 62, "Account", size=11, font="F2", color=(0.31, 0.39, 0.56))
    text(margin + 18, y + 38, account_name, size=18, font="F2", color=(0.09, 0.13, 0.24))
    text(margin + info_width + 34, y + 62, "Email", size=11, font="F2", color=(0.31, 0.39, 0.56))
    text(margin + info_width + 34, y + 38, email, size=14, font="F2", color=(0.09, 0.13, 0.24))

    section_y = y - 48
    text(margin, section_y, "Your backup codes", size=17, font="F2", color=(0.09, 0.13, 0.24))
    text(
        margin,
        section_y - 18,
        "Use each code carefully and store them offline if possible.",
        size=10,
        color=(0.42, 0.47, 0.56),
    )

    block_y = section_y - 64
    block_height = 78
    for index, code in enumerate(codes, start=1):
        rect(
            margin,
            block_y,
            page_width - (margin * 2),
            block_height,
            fill=(1, 1, 1),
            stroke=(0.86, 0.89, 0.94),
        )
        text(margin + 18, block_y + 46, f"Code {index}", size=11, font="F2", color=(0.31, 0.39, 0.56))
        text(margin + 18, block_y + 18, code, size=24, font="F2", color=(0.09, 0.13, 0.24))
        block_y -= block_height + 16

    note_y = 110
    rect(margin, note_y, page_width - (margin * 2), 86, fill=(1.0, 0.97, 0.92), stroke=(0.95, 0.79, 0.55))
    text(margin + 18, note_y + 58, "Important", size=13, font="F2", color=(0.69, 0.36, 0.04))
    multiline(
        margin + 18,
        note_y + 38,
        "Anyone with these backup codes may be able to recover access. Do not share this document. If you think it has been exposed, generate a fresh set from BeatzLock.",
        width_chars=78,
        size=10,
        color=(0.43, 0.29, 0.09),
        leading=13,
    )
    text(margin, 48, "Generated by BeatzLock Auth", size=10, color=(0.47, 0.51, 0.60))

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
