# api/serializers.py

from rest_framework import serializers
from django.contrib.auth.models import User
from .models import AppNotification, DeviceSession, EncryptedData, PasswordlessLoginRequest
from .notifications import decrypt_notification_payload

class UserSerializer(serializers.ModelSerializer):
    class Meta:
        model = User
        fields = ['id', 'username', 'email']

class EncryptedDataSerializer(serializers.ModelSerializer):
    class Meta:
        model = EncryptedData
        fields = ['data_type', 'encrypted_content', 'version', 'updated_at']

class RegisterSerializer(serializers.ModelSerializer):
    password = serializers.CharField(write_only=True)
    
    class Meta:
        model = User
        fields = ['username', 'email', 'password']
    
    def create(self, validated_data):
        user = User.objects.create_user(**validated_data)
        return user


class AppNotificationSerializer(serializers.ModelSerializer):
    title = serializers.SerializerMethodField()
    message = serializers.SerializerMethodField()
    details = serializers.SerializerMethodField()
    preview = serializers.SerializerMethodField()

    class Meta:
        model = AppNotification
        fields = [
            'id',
            'notification_type',
            'title',
            'message',
            'details',
            'preview',
            'is_read',
            'read_at',
            'created_at',
        ]

    def _payload(self, obj):
        try:
            return decrypt_notification_payload(obj.encrypted_payload)
        except Exception:
            return {
                'title': 'Notification unavailable',
                'message': 'This notification could not be decrypted.',
                'details': 'This notification could not be decrypted.',
            }

    def get_title(self, obj):
        return self._payload(obj).get('title', 'Notification')

    def get_message(self, obj):
        return self._payload(obj).get('message', '')

    def get_details(self, obj):
        payload = self._payload(obj)
        return payload.get('details') or payload.get('message', '')

    def get_preview(self, obj):
        message = self._payload(obj).get('message', '')
        return message[:120]


class DeviceSessionSerializer(serializers.ModelSerializer):
    is_current = serializers.SerializerMethodField()

    class Meta:
        model = DeviceSession
        fields = [
            'id',
            'device_id',
            'device_label',
            'device_kind',
            'ip_address',
            'is_active',
            'is_primary',
            'is_current',
            'created_at',
            'last_seen_at',
        ]

    def get_is_current(self, obj):
        current_session_id = self.context.get('current_session_id')
        current_device_id = self.context.get('current_device_id')

        if current_session_id and str(obj.id) == str(current_session_id):
            return True
        if current_device_id and obj.device_id == current_device_id:
            return True
        return False


class PasswordlessLoginRequestSerializer(serializers.ModelSerializer):
    class Meta:
        model = PasswordlessLoginRequest
        fields = [
            'id',
            'requester_device_label',
            'requester_device_kind',
            'verification_code',
            'status',
            'expires_at',
            'created_at',
        ]
