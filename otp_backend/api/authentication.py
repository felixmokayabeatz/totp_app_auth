from __future__ import annotations

from django.utils import timezone
from rest_framework_simplejwt.authentication import JWTAuthentication
from rest_framework_simplejwt.exceptions import AuthenticationFailed

from .models import DeviceSession


class DeviceSessionJWTAuthentication(JWTAuthentication):
    def authenticate(self, request):
        result = super().authenticate(request)
        if result is None:
            return None

        user, validated_token = result
        session_id = validated_token.get('session_id')
        if not session_id:
            device_id = request.headers.get('X-Device-ID', '').strip()
            if device_id:
                active_session = DeviceSession.objects.filter(
                    user=user,
                    device_id=device_id,
                    is_active=True,
                    revoked_at__isnull=True,
                ).order_by('-last_seen_at', '-created_at').first()

                if active_session is not None:
                    now = timezone.now()
                    if (
                        active_session.last_seen_at is None
                        or (now - active_session.last_seen_at).total_seconds() >= 15
                    ):
                        DeviceSession.objects.filter(id=active_session.id).update(
                            last_seen_at=now,
                            updated_at=now,
                        )
                elif DeviceSession.objects.filter(
                    user=user,
                    device_id=device_id,
                ).filter(is_active=False).exists() or DeviceSession.objects.filter(
                    user=user,
                    device_id=device_id,
                    revoked_at__isnull=False,
                ).exists():
                    raise AuthenticationFailed(
                        'This device session has been signed out.',
                        code='session_revoked',
                    )
            return (user, validated_token)

        session = DeviceSession.objects.filter(
            id=session_id,
            user=user,
            is_active=True,
            revoked_at__isnull=True,
        ).first()

        if session is None:
            raise AuthenticationFailed(
                'This device session has been signed out.',
                code='session_revoked',
            )

        now = timezone.now()
        if session.last_seen_at is None or (now - session.last_seen_at).total_seconds() >= 15:
            DeviceSession.objects.filter(id=session.id).update(
                last_seen_at=now,
                updated_at=now,
            )

        return (user, validated_token)
