"""Resolving an account from what someone typed into a sign-in field.

There is one identifier: the email address. ``users.User`` stores it lowercased
and unique, so a lookup can only ever match one account -- the older helpers
here had to pick the oldest of several matches, and to fall back to a username
column, and neither situation exists any more.
"""

from django.contrib.auth import authenticate, get_user_model


def normalize_email(value: str) -> str:
    return (value or '').strip().lower()


def find_user_by_email(email: str):
    """Return the account with this address, or None."""
    cleaned = normalize_email(email)
    if not cleaned:
        return None

    # Addresses are written lowercased, but iexact keeps a row that predates
    # that -- or one edited by hand -- reachable.
    return get_user_model().objects.filter(email__iexact=cleaned).first()


def authenticate_email(email: str, password: str):
    """Authenticate an address and password, or return None."""
    cleaned = normalize_email(email)
    if not cleaned:
        return None

    # ModelBackend passes this to User.objects.get_by_natural_key, which looks
    # up USERNAME_FIELD -- the email column.
    return authenticate(username=cleaned, password=password)


def email_from_request(data) -> str:
    """The address a request identifies its account by.

    Released app builds send the same value under both "email" and "username";
    the second is a leftover name from when there was a username column, and it
    is still read so that an app nobody has updated keeps signing in.
    """
    return normalize_email(data.get('email') or data.get('username') or '')
