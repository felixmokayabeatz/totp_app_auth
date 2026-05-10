# api/serializers.py

from rest_framework import serializers
from django.contrib.auth.models import User
from .models import (
    AppNotification,
    BulkAccountDeleteRequest,
    DeviceSession,
    EncryptedData,
    PasswordlessLoginRequest,
)
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
        current_device_fingerprint = self.context.get('current_device_fingerprint')

        if current_session_id:
            return str(obj.id) == str(current_session_id)
        if current_device_fingerprint and getattr(obj, 'device_fingerprint', ''):
            return obj.device_fingerprint == current_device_fingerprint
        if current_device_id:
            return obj.device_id == current_device_id
        return False


class PasswordlessLoginRequestSerializer(serializers.ModelSerializer):
    code_expires_at = serializers.SerializerMethodField()
    verification_choices = serializers.SerializerMethodField()

    class Meta:
        model = PasswordlessLoginRequest
        fields = [
            'id',
            'requester_device_label',
            'requester_device_kind',
            'code_expires_at',
            'verification_choices',
            'status',
            'expires_at',
            'created_at',
            'updated_at',
            'approved_at',
            'completed_at',
        ]

    def get_verification_choices(self, obj):
        builder = self.context.get('passwordless_choice_builder')
        if builder is None:
            return []
        return builder(obj)

    def get_code_expires_at(self, obj):
        return obj.code_expires_at().isoformat()


class BulkAccountDeleteRequestSerializer(serializers.ModelSerializer):
    class Meta:
        model = BulkAccountDeleteRequest
        fields = [
            'id',
            'requester_device_label',
            'requester_device_kind',
            'requested_count',
            'range_start_date',
            'range_end_date',
            'status',
            'expires_at',
            'created_at',
            'updated_at',
            'approved_at',
            'completed_at',
        ]
