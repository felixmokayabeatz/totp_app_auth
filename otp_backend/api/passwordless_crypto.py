import base64
import hashlib

from cryptography.fernet import Fernet
from django.conf import settings


def _get_cipher() -> Fernet:
    digest = hashlib.sha256(
        f"beatzlock-passwordless|{settings.SECRET_KEY}".encode("utf-8")
    ).digest()
    return Fernet(base64.urlsafe_b64encode(digest))


def encrypt_passwordless_code(code: str) -> str:
    return _get_cipher().encrypt(code.encode("utf-8")).decode("utf-8")


def decrypt_passwordless_code(encrypted_code: str) -> str:
    return _get_cipher().decrypt(encrypted_code.encode("utf-8")).decode("utf-8")
