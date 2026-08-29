import base64
import hashlib
from functools import lru_cache

from cryptography.fernet import Fernet
from django.conf import settings


@lru_cache(maxsize=4)
def _cipher_for(secret: str) -> Fernet:
    """Build the cipher once per secret.

    Deriving the key is a SHA-256 and a Fernet construction. That is cheap on
    its own and was being paid on every single encrypt and decrypt -- hundreds
    of times over one notifications list. Keying the cache on the secret rather
    than caching a module global keeps override_settings(SECRET_KEY=...) honest.
    """
    digest = hashlib.sha256(
        f"beatzlock-passwordless|{secret}".encode("utf-8")
    ).digest()
    return Fernet(base64.urlsafe_b64encode(digest))


def _get_cipher() -> Fernet:
    return _cipher_for(settings.SECRET_KEY)


def encrypt_passwordless_code(code: str) -> str:
    return _get_cipher().encrypt(code.encode("utf-8")).decode("utf-8")


def decrypt_passwordless_code(encrypted_code: str) -> str:
    return _get_cipher().decrypt(encrypted_code.encode("utf-8")).decode("utf-8")
