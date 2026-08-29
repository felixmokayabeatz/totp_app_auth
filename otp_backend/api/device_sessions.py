from __future__ import annotations

from django.contrib.auth import get_user_model
from django.utils import timezone

from .models import DeviceSession
from .notifications import build_device_label

# The project-wide account model; users.User, keyed by email.
User = get_user_model()


def extract_request_ip(request) -> str:
    forwarded_for = request.META.get('HTTP_X_FORWARDED_FOR', '')
    if forwarded_for:
        return forwarded_for.split(',')[0].strip()
    return request.META.get('REMOTE_ADDR', '') or ''


def get_request_device_id(request) -> str:
    sources = []
    if hasattr(request, 'data'):
        sources.append(request.data.get('device_id'))
    if hasattr(request, 'query_params'):
        sources.append(request.query_params.get('device_id'))
    sources.append(request.headers.get('X-Device-ID'))

    for value in sources:
        if value and str(value).strip():
            return str(value).strip()
    return ''


def get_request_device_fingerprint(request) -> str:
    sources = []
    if hasattr(request, 'data'):
        sources.append(request.data.get('device_fingerprint'))
    if hasattr(request, 'query_params'):
        sources.append(request.query_params.get('device_fingerprint'))
    sources.append(request.headers.get('X-Device-Fingerprint'))

    for value in sources:
        if value and str(value).strip():
            return str(value).strip()
    return ''


def get_request_device_label(request) -> str:
    provided_label = None
    if hasattr(request, 'data'):
        provided_label = request.data.get('device_label')
    if not provided_label and hasattr(request, 'query_params'):
        provided_label = request.query_params.get('device_label')
    if not provided_label:
        provided_label = request.headers.get('X-Device-Label')

    return build_device_label(provided_label, request.META.get('HTTP_USER_AGENT'))


def get_request_device_kind(request) -> str:
    provided_kind = None
    if hasattr(request, 'data'):
        provided_kind = request.data.get('device_kind')
    if not provided_kind and hasattr(request, 'query_params'):
        provided_kind = request.query_params.get('device_kind')
    if not provided_kind:
        provided_kind = request.headers.get('X-Device-Kind')

    normalized = str(provided_kind or '').strip().lower()
    if normalized in {
        DeviceSession.DEVICE_KIND_MOBILE,
        DeviceSession.DEVICE_KIND_DESKTOP,
        DeviceSession.DEVICE_KIND_WEB,
    }:
        return normalized
    return DeviceSession.DEVICE_KIND_UNKNOWN


def find_active_device_session(
    user: User,
    *,
    device_id: str = '',
    device_fingerprint: str = '',
) -> DeviceSession | None:
    normalized_device_id = (device_id or '').strip()
    normalized_device_fingerprint = (device_fingerprint or '').strip()

    if normalized_device_id:
        session = DeviceSession.objects.filter(
            user=user,
            device_id=normalized_device_id,
            is_active=True,
            revoked_at__isnull=True,
        ).order_by('-last_seen_at', '-created_at').first()
        if session is not None:
            return session

    if normalized_device_fingerprint:
        return DeviceSession.objects.filter(
            user=user,
            device_fingerprint=normalized_device_fingerprint,
            is_active=True,
            revoked_at__isnull=True,
        ).order_by('-last_seen_at', '-created_at').first()

    return None


def find_known_device_session(
    user: User,
    *,
    device_id: str = '',
    device_fingerprint: str = '',
) -> DeviceSession | None:
    active_session = find_active_device_session(
        user,
        device_id=device_id,
        device_fingerprint=device_fingerprint,
    )
    if active_session is not None:
        return active_session

    normalized_device_id = (device_id or '').strip()
    normalized_device_fingerprint = (device_fingerprint or '').strip()

    if normalized_device_id:
        session = DeviceSession.objects.filter(
            user=user,
            device_id=normalized_device_id,
        ).order_by('-is_primary', '-last_seen_at', '-created_at').first()
        if session is not None:
            return session

    if normalized_device_fingerprint:
        return DeviceSession.objects.filter(
            user=user,
            device_fingerprint=normalized_device_fingerprint,
        ).order_by('-is_primary', '-last_seen_at', '-created_at').first()

    return None


def ensure_device_session(
    user: User,
    *,
    device_id: str,
    device_fingerprint: str = '',
    device_label: str,
    device_kind: str = DeviceSession.DEVICE_KIND_UNKNOWN,
    user_agent: str = '',
    ip_address: str = '',
) -> DeviceSession:
    normalized_device_id = (device_id or '').strip()
    normalized_device_fingerprint = (device_fingerprint or '').strip()
    normalized_device_label = device_label.strip() or 'Unknown device'
    now = timezone.now()
    normalized_device_kind = device_kind or DeviceSession.DEVICE_KIND_UNKNOWN

    session = find_known_device_session(
        user,
        device_id=normalized_device_id,
        device_fingerprint=normalized_device_fingerprint,
    )

    if (
        session is None
        and normalized_device_kind == DeviceSession.DEVICE_KIND_MOBILE
        and normalized_device_label
        and normalized_device_label != 'Unknown device'
    ):
        same_label_sessions = DeviceSession.objects.filter(
            user=user,
            is_active=True,
            revoked_at__isnull=True,
            device_kind=DeviceSession.DEVICE_KIND_MOBILE,
            device_label=normalized_device_label,
        ).order_by('-is_primary', '-last_seen_at', '-created_at')

        if user_agent.strip():
            same_label_user_agent = same_label_sessions.filter(user_agent=user_agent.strip())
            if same_label_user_agent.count() == 1:
                session = same_label_user_agent.first()

        if session is None:
            same_label_primary = same_label_sessions.filter(is_primary=True)
            if same_label_primary.count() == 1:
                session = same_label_primary.first()

        if session is None and same_label_sessions.count() == 1:
            session = same_label_sessions.first()

    if session is None:
        should_be_primary = not DeviceSession.objects.filter(
            user=user,
            is_primary=True,
        ).exists()
        session = DeviceSession.objects.create(
            user=user,
            device_id=normalized_device_id,
            device_fingerprint=normalized_device_fingerprint,
            device_label=normalized_device_label,
            device_kind=normalized_device_kind,
            user_agent=user_agent or '',
            ip_address=ip_address or '',
            is_active=True,
            is_primary=should_be_primary,
            last_seen_at=now,
        )
    else:
        if normalized_device_id:
            session.device_id = normalized_device_id
        if normalized_device_fingerprint:
            session.device_fingerprint = normalized_device_fingerprint
        session.device_label = normalized_device_label
        session.device_kind = normalized_device_kind or session.device_kind
        session.user_agent = user_agent or session.user_agent
        session.ip_address = ip_address or session.ip_address
        session.is_active = True
        session.revoked_at = None
        session.last_seen_at = now
        session.save(
            update_fields=[
                'device_id',
                'device_fingerprint',
                'device_label',
                'device_kind',
                'user_agent',
                'ip_address',
                'is_active',
                'revoked_at',
                'last_seen_at',
                'updated_at',
            ]
        )

    current_primary = DeviceSession.objects.filter(
        user=user,
        is_active=True,
        revoked_at__isnull=True,
        is_primary=True,
    ).exclude(id=session.id).order_by('-last_seen_at', '-created_at').first()

    other_active_mobile_exists = DeviceSession.objects.filter(
        user=user,
        is_active=True,
        revoked_at__isnull=True,
        device_kind=DeviceSession.DEVICE_KIND_MOBILE,
    ).exclude(id=session.id).exists()

    if (
        normalized_device_kind == DeviceSession.DEVICE_KIND_MOBILE
        and current_primary is not None
        and current_primary.device_kind != DeviceSession.DEVICE_KIND_MOBILE
        and not other_active_mobile_exists
        and not session.is_primary
    ):
        current_primary.is_primary = False
        current_primary.save(update_fields=['is_primary', 'updated_at'])
        session.is_primary = True
        session.save(update_fields=['is_primary', 'updated_at'])

    if normalized_device_id:
        DeviceSession.objects.filter(
            user=user,
            device_id=normalized_device_id,
            is_active=True,
            revoked_at__isnull=True,
        ).exclude(id=session.id).update(
            is_active=False,
            revoked_at=now,
            updated_at=now,
        )

    return session


def ensure_primary_session(user: User) -> DeviceSession | None:
    primary_session = DeviceSession.objects.filter(
        user=user,
        is_active=True,
        revoked_at__isnull=True,
        is_primary=True,
    ).order_by('-last_seen_at', '-created_at').first()
    if primary_session is not None:
        return primary_session

    remembered_primary = DeviceSession.objects.filter(
        user=user,
        is_primary=True,
    ).order_by('-last_seen_at', '-created_at').first()
    if remembered_primary is not None:
        return remembered_primary

    fallback_session = DeviceSession.objects.filter(
        user=user,
        is_active=True,
        revoked_at__isnull=True,
    ).order_by('-last_seen_at', '-created_at').first()
    if fallback_session is None:
        return None

    fallback_session.is_primary = True
    fallback_session.save(update_fields=['is_primary', 'updated_at'])
    return fallback_session


def attach_session_to_refresh_token(user: User, request, refresh_token):
    device_id = get_request_device_id(request)
    device_fingerprint = get_request_device_fingerprint(request)
    device_label = get_request_device_label(request)
    session = ensure_device_session(
        user,
        device_id=device_id,
        device_fingerprint=device_fingerprint,
        device_label=device_label,
        device_kind=get_request_device_kind(request),
        user_agent=request.META.get('HTTP_USER_AGENT', ''),
        ip_address=extract_request_ip(request),
    )
    refresh_token['session_id'] = str(session.id)
    return session
