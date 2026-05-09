#  api/models.py

from django.db import models
from django.contrib.auth.models import User
import uuid

from .passwordless_crypto import decrypt_passwordless_code, encrypt_passwordless_code


class EncryptedData(models.Model):
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name='encrypted_data')
    data_type = models.CharField(max_length=50)
    encrypted_content = models.TextField()
    version = models.IntegerField(default=1)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)
    synced_at = models.DateTimeField(null=True, blank=True)
    deleted_accounts = models.TextField(blank=True, default='') 

    class Meta:
        unique_together = ['user', 'data_type']

    def __str__(self):
        return f"{self.user.username} - {self.data_type}"


class SyncLog(models.Model):
    user = models.OneToOneField(User, on_delete=models.CASCADE, primary_key=True, related_name='sync_log')
    device_id = models.CharField(max_length=255, blank=True, default='')
    sync_type = models.CharField(max_length=50, blank=True, default='')
    status = models.CharField(max_length=50, blank=True, default='')
    timestamp = models.DateTimeField(auto_now=True)  # Auto-updates on each change
    error_message = models.TextField(null=True, blank=True)
    last_sync_count = models.IntegerField(default=0)  # Track how many accounts synced
    total_syncs = models.IntegerField(default=0)  # Counter for number of sync operations

    def __str__(self):
        return f"{self.user.username} - Last sync: {self.timestamp}"


# Tombstone table — once an account ID lands here, no device can re-add it.
class AccountTombstone(models.Model):
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name='tombstones')
    account_id = models.CharField(max_length=255)
    deleted_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        unique_together = ['user', 'account_id']

    def __str__(self):
        return f"{self.user.username} – tombstone {self.account_id}"


# One-time OTP codes for dangerous operations (e.g. delete-all-everywhere)
class DeleteOTPCode(models.Model):
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name='delete_otps')
    code = models.CharField(max_length=6)
    created_at = models.DateTimeField(auto_now_add=True)
    used = models.BooleanField(default=False)

    def is_valid(self):
        from django.utils import timezone
        from datetime import timedelta
        # Code expires after 10 minutes
        return not self.used and (timezone.now() - self.created_at) < timedelta(minutes=10)


class BackupCodeSet(models.Model):
    user = models.OneToOneField(
        User,
        on_delete=models.CASCADE,
        related_name='backup_code_set',
    )
    encrypted_codes = models.TextField()
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)
    last_used_at = models.DateTimeField(null=True, blank=True)

    def __str__(self):
        return f"{self.user.username} - backup codes"


class AppNotification(models.Model):
    user = models.ForeignKey(
        User,
        on_delete=models.CASCADE,
        related_name='app_notifications',
    )
    notification_type = models.CharField(max_length=50, db_index=True)
    encrypted_payload = models.TextField()
    is_read = models.BooleanField(default=False)
    read_at = models.DateTimeField(null=True, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ['-created_at']

    def __str__(self):
        return f"{self.user.username} - {self.notification_type}"


class DeviceSession(models.Model):
    DEVICE_KIND_UNKNOWN = 'unknown'
    DEVICE_KIND_MOBILE = 'mobile'
    DEVICE_KIND_DESKTOP = 'desktop'
    DEVICE_KIND_WEB = 'web'
    DEVICE_KIND_CHOICES = [
        (DEVICE_KIND_UNKNOWN, 'Unknown'),
        (DEVICE_KIND_MOBILE, 'Mobile'),
        (DEVICE_KIND_DESKTOP, 'Desktop'),
        (DEVICE_KIND_WEB, 'Web'),
    ]

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    user = models.ForeignKey(
        User,
        on_delete=models.CASCADE,
        related_name='device_sessions',
    )
    device_id = models.CharField(max_length=255, blank=True, default='', db_index=True)
    device_label = models.CharField(max_length=120, blank=True, default='Unknown device')
    user_agent = models.TextField(blank=True, default='')
    ip_address = models.CharField(max_length=128, blank=True, default='')
    device_kind = models.CharField(
        max_length=20,
        choices=DEVICE_KIND_CHOICES,
        default=DEVICE_KIND_UNKNOWN,
    )
    is_active = models.BooleanField(default=True)
    is_primary = models.BooleanField(default=False)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)
    last_seen_at = models.DateTimeField(auto_now_add=True)
    revoked_at = models.DateTimeField(null=True, blank=True)

    class Meta:
        ordering = ['-last_seen_at', '-created_at']

    def __str__(self):
        return f"{self.user.username} - {self.device_label}"


class PasswordlessLoginRequest(models.Model):
    STATUS_PENDING = 'pending'
    STATUS_APPROVED = 'approved'
    STATUS_DENIED = 'denied'
    STATUS_COMPLETED = 'completed'
    STATUS_EXPIRED = 'expired'
    STATUS_CHOICES = [
        (STATUS_PENDING, 'Pending'),
        (STATUS_APPROVED, 'Approved'),
        (STATUS_DENIED, 'Denied'),
        (STATUS_COMPLETED, 'Completed'),
        (STATUS_EXPIRED, 'Expired'),
    ]

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    user = models.ForeignKey(
        User,
        on_delete=models.CASCADE,
        related_name='passwordless_login_requests',
    )
    requester_device_id = models.CharField(max_length=255, blank=True, default='')
    requester_device_label = models.CharField(max_length=120, blank=True, default='Unknown device')
    requester_device_kind = models.CharField(
        max_length=20,
        choices=DeviceSession.DEVICE_KIND_CHOICES,
        default=DeviceSession.DEVICE_KIND_UNKNOWN,
    )
    verification_code = models.TextField()
    status = models.CharField(
        max_length=20,
        choices=STATUS_CHOICES,
        default=STATUS_PENDING,
    )
    expires_at = models.DateTimeField()
    approved_at = models.DateTimeField(null=True, blank=True)
    completed_at = models.DateTimeField(null=True, blank=True)
    reviewed_by_session = models.ForeignKey(
        DeviceSession,
        null=True,
        blank=True,
        on_delete=models.SET_NULL,
        related_name='reviewed_passwordless_requests',
    )
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ['-created_at']

    def __str__(self):
        return f"{self.user.username} - passwordless {self.status} - {self.requester_device_label}"

    def set_verification_code(self, raw_code: str) -> None:
        self.verification_code = encrypt_passwordless_code(raw_code)

    def get_verification_code(self) -> str:
        if not self.verification_code:
            return ''
        return decrypt_passwordless_code(self.verification_code)

    def matches_verification_code(self, raw_code: str) -> bool:
        return self.get_verification_code() == raw_code
