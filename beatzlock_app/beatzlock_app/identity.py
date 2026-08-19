"""Email addresses are the login identifier on this site.

There are no separate usernames here. Django's `auth_user.username` column is
NOT NULL and unique so it cannot simply be dropped, and dropping it would mean
a custom user model and a swap of `AUTH_USER_MODEL` that any restore of an
older dump would then fight with. Instead the column is kept equal to the
email address on every account this site creates, and nobody is ever asked for
it: not at sign-in, not in the admin, not when deploy.sh creates the first
superuser.

This mirrors `accounts/identity.py` in the authenticator API, which resolves
logins the same way -- the API has older accounts whose username is not their
email, so both sides fall back to a username lookup for those.
"""
from django.contrib.auth.models import User


def normalize_email(value):
    return (value or "").strip().lower()


def find_user_by_email(email):
    """Find a user by email address.

    `User.email` carries no unique constraint, so a plain `.get()` raises
    MultipleObjectsReturned as soon as two accounts share an address. Pick the
    oldest, matching how find_user_by_login_identifier resolves the same
    collision.
    """
    cleaned = (email or "").strip()
    if not cleaned:
        return None

    return User.objects.filter(email__iexact=cleaned).order_by("id").first()


def find_user_by_login_identifier(identifier):
    """Find a user by email first, with a username fallback for legacy rows."""
    cleaned = (identifier or "").strip()
    if not cleaned:
        return None

    user = find_user_by_email(cleaned)
    if user is not None:
        return user

    return User.objects.filter(username__iexact=cleaned).order_by("id").first()
