from django.contrib.auth import authenticate
from django.contrib.auth.models import User


def normalize_email(value: str) -> str:
    return (value or '').strip().lower()


def find_user_by_login_identifier(identifier: str):
    """Find a user by email first, with username fallback for legacy accounts."""
    cleaned = (identifier or '').strip()
    if not cleaned:
        return None

    user = User.objects.filter(email__iexact=cleaned).order_by('id').first()
    if user is not None:
        return user

    return User.objects.filter(username__iexact=cleaned).order_by('id').first()


def authenticate_login_identifier(identifier: str, password: str):
    user = find_user_by_login_identifier(identifier)
    if user is None:
        return None
    return authenticate(username=user.username, password=password)
