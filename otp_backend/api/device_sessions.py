from __future__ import annotations

from django.contrib.auth.models import User
from django.utils import timezone

from .models import DeviceSession
from .notifications import build_device_label


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


def get_request_device_label(request) -> str:
    provided_label = None
    if hasattr(request, 'data'):
        provided_label = request.data.get('device_label')
    if not provided_label and hasattr(request, 'query_params'):
        provided_label = request.query_params.get('device_label')
    if not provided_label:
        provided_label = request.headers.get('X-Device-Label')

    return build_device_label(provided_label, request.META.get('HTTP_USER_AGENT'))


def ensure_device_session(
    user: User,
    *,
    device_id: str,
    device_label: str,
    user_agent: str = '',
    ip_address: str = '',
) -> DeviceSession:
    normalized_device_id = (device_id or '').strip()
    normalized_device_label = device_label.strip() or 'Unknown device'
    now = timezone.now()

    session = None
    if normalized_device_id:
        session = (
            DeviceSession.objects
            .filter(user=user, device_id=normalized_device_id)
            .order_by('-last_seen_at', '-created_at')
            .first()
        )

    if session is None:
        session = DeviceSession.objects.create(
            user=user,
            device_id=normalized_device_id,
            device_label=normalized_device_label,
            user_agent=user_agent or '',
            ip_address=ip_address or '',
            is_active=True,
            last_seen_at=now,
        )
        return session

    session.device_label = normalized_device_label
    session.user_agent = user_agent or session.user_agent
    session.ip_address = ip_address or session.ip_address
    session.is_active = True
    session.revoked_at = None
    session.last_seen_at = now
    session.save(
        update_fields=[
            'device_label',
            'user_agent',
            'ip_address',
            'is_active',
            'revoked_at',
            'last_seen_at',
            'updated_at',
        ]
    )

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


def attach_session_to_refresh_token(user: User, request, refresh_token):
    device_id = get_request_device_id(request)
    device_label = get_request_device_label(request)
    session = ensure_device_session(
        user,
        device_id=device_id,
        device_label=device_label,
        user_agent=request.META.get('HTTP_USER_AGENT', ''),
        ip_address=extract_request_ip(request),
    )
    refresh_token['session_id'] = str(session.id)
    return session
