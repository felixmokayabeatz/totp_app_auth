from __future__ import annotations

from django.contrib.auth import get_user_model
from django.utils import timezone
from rest_framework_simplejwt.exceptions import InvalidToken
from rest_framework_simplejwt.serializers import TokenRefreshSerializer
from rest_framework_simplejwt.tokens import RefreshToken
from rest_framework_simplejwt.views import TokenRefreshView

from .models import DeviceSession

# The project-wide account model; users.User, keyed by email.
User = get_user_model()


class DeviceSessionTokenRefreshSerializer(TokenRefreshSerializer):
    def validate(self, attrs):
        refresh = RefreshToken(attrs['refresh'])
        session_id = refresh.get('session_id')

        if session_id:
            user = User.objects.filter(id=refresh.get('user_id')).first()
            session = DeviceSession.objects.filter(
                id=session_id,
                user=user,
                is_active=True,
                revoked_at__isnull=True,
            ).first()
            if session is None:
                raise InvalidToken('This device session has been signed out.')

            now = timezone.now()
            session.last_seen_at = now
            session.save(update_fields=['last_seen_at', 'updated_at'])

        return super().validate(attrs)


class DeviceSessionTokenRefreshView(TokenRefreshView):
    serializer_class = DeviceSessionTokenRefreshSerializer
