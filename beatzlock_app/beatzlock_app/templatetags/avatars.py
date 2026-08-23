# beatzlock_app/templatetags/avatars.py
"""Reading a person's picture and initials from a template.

Profiles are created on first use rather than by a signal (see profile_for in
models.py), so a user can legitimately have no profile row -- anyone made with
createsuperuser, for one. `{{ user.profile.avatar_url }}` on such a user
resolves to nothing and the template quietly renders neither a picture nor a
fallback, which is why the nav showed a bare name.

These read what is there and work out the rest. Neither writes: a template
render is not the place to create rows.
"""
import re

from django import template

register = template.Library()


@register.filter
def avatar_url(user):
    """The picture to show, or '' when there is none."""
    if not user or not getattr(user, 'is_authenticated', False):
        return ''
    profile = getattr(user, 'profile', None)
    if profile is None:
        return ''
    try:
        return profile.avatar_url or ''
    except Exception:  # noqa: BLE001 - a missing file must not break the nav
        return ''


@register.filter
def initials(user):
    """Two letters for the fallback badge, profile or no profile."""
    if not user:
        return '?'

    profile = getattr(user, 'profile', None)
    if profile is not None:
        try:
            return profile.initials
        except Exception:  # noqa: BLE001
            pass

    # Same rule the profile uses, applied straight to the user.
    source = (
        f"{getattr(user, 'first_name', '')} {getattr(user, 'last_name', '')}".strip()
        or getattr(user, 'email', '')
        or getattr(user, 'username', '')
    )
    parts = [p for p in re.split(r'[\s._@-]+', source) if p]
    if not parts:
        return '?'
    if len(parts) >= 2:
        return (parts[0][0] + parts[1][0]).upper()
    return parts[0][:2].upper()
