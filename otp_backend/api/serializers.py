# api/serializers.py

from rest_framework import serializers
from django.contrib.auth.models import User
from accounts.identity import normalize_email
from .models import (
    AppNotification,
    BackupCodeGenerationRequest,
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
    email = serializers.EmailField()
    password = serializers.CharField(write_only=True)
    
    class Meta:
        model = User
        fields = ['email', 'password']

    def validate_email(self, value):
        email = normalize_email(value)
        if User.objects.filter(email__iexact=email).exists():
            raise serializers.ValidationError(
                'An account already exists with this email.'
            )
        if User.objects.filter(username__iexact=email).exists():
            raise serializers.ValidationError(
                'An account already exists with this email.'
            )
        return email
    
    def create(self, validated_data):
        email = validated_data['email']
        return User.objects.create_user(
            username=email,
            email=email,
            password=validated_data['password'],
        )


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
    push_ready = serializers.SerializerMethodField()
    push_status_text = serializers.SerializerMethodField()

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
            'push_ready',
            'push_status_text',
            'push_platform',
            'push_token_updated_at',
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

    def get_push_ready(self, obj):
        return bool((obj.push_token or '').strip())

    def get_push_status_text(self, obj):
        if not obj.is_active or obj.revoked_at is not None:
            return 'Signed out'
        if bool((obj.push_token or '').strip()):
            return 'Push alerts ready'
        if obj.device_kind == DeviceSession.DEVICE_KIND_MOBILE:
            return 'Push wake-up not connected'
        return 'Push wake-up not available'


class PasswordlessLoginRequestSerializer(serializers.ModelSerializer):
    code_expires_at = serializers.SerializerMethodField()
    verification_choices = serializers.SerializerMethodField()
    unlock_transfer_key = serializers.SerializerMethodField()

    class Meta:
        model = PasswordlessLoginRequest
        fields = [
            'id',
            'requester_device_label',
            'requester_device_kind',
            'code_expires_at',
            'verification_choices',
            'unlock_transfer_key',
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

    def get_unlock_transfer_key(self, obj):
        if obj.status != PasswordlessLoginRequest.STATUS_PENDING:
            return ''
        return obj.get_unlock_transfer_key()

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


class BackupCodeGenerationRequestSerializer(serializers.ModelSerializer):
    class Meta:
        model = BackupCodeGenerationRequest
        fields = [
            'id',
            'requester_device_label',
            'requester_device_kind',
            'status',
            'expires_at',
            'created_at',
            'updated_at',
            'approved_at',
            'completed_at',
        ]
