#  api/models.py

from django.db import models
from django.contrib.auth.models import User
from django.conf import settings
from django.utils import timezone
from datetime import timedelta
import hashlib
import uuid

from .passwordless_crypto import (
    decrypt_passwordless_code,
    encrypt_passwordless_code,
)


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
    last_sync_count = models.IntegerField(default=0)  # OTP accounts included in the most recent successful upload
    total_syncs = models.IntegerField(default=0)  # Successful cloud write operations

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
    device_fingerprint = models.CharField(
        max_length=255,
        blank=True,
        default='',
        db_index=True,
    )
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
    push_token = models.TextField(blank=True, default='')
    push_platform = models.CharField(max_length=30, blank=True, default='')
    push_token_updated_at = models.DateTimeField(null=True, blank=True)
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
    unlock_transfer_key = models.TextField(blank=True, default='')
    sync_unlock_payload = models.TextField(blank=True, default='')
    sync_unlock_transferred_at = models.DateTimeField(null=True, blank=True)
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

    def _looks_like_legacy_raw_code(self) -> bool:
        return self.verification_code.isdigit() and len(self.verification_code) == 3

    def _looks_like_seed(self, value: str) -> bool:
        return 1 <= len(value) <= 7 and not (
            value.isdigit() and len(value) == 3
        )

    def _timeslot_for(self, at_time=None) -> int:
        current_time = at_time or timezone.now()
        elapsed = max(
            0,
            int((current_time - self.created_at).total_seconds()),
        )
        return elapsed // 30

    def code_expires_at(self, at_time=None):
        slot = self._timeslot_for(at_time)
        return self.created_at + timedelta(seconds=(slot + 1) * 30)

    def _derive_seeded_code(self, slot: int, *, seed: str) -> str:
        digest = hashlib.sha256(
            f"beatzlock-passwordless|{settings.SECRET_KEY}|{self.id}|{seed}|{slot}".encode(
                "utf-8"
            )
        ).hexdigest()
        return str(int(digest[:8], 16) % 1000).zfill(3)

    def set_verification_code(self, raw_code: str) -> None:
        self.verification_code = encrypt_passwordless_code(raw_code)

    def set_unlock_transfer_key(self, raw_key: str) -> None:
        self.unlock_transfer_key = encrypt_passwordless_code(raw_key)

    def get_unlock_transfer_key(self) -> str:
        if not self.unlock_transfer_key:
            return ''
        try:
            return decrypt_passwordless_code(self.unlock_transfer_key)
        except Exception:
            return ''

    def _raw_verification_value(self) -> str:
        if not self.verification_code:
            return ''
        if self._looks_like_legacy_raw_code() or self._looks_like_seed(self.verification_code):
            return self.verification_code
        try:
            return decrypt_passwordless_code(self.verification_code)
        except Exception:
            return ''

    def get_verification_code(self) -> str:
        raw_value = self._raw_verification_value()
        if not raw_value:
            return ''
        if raw_value.isdigit() and len(raw_value) == 3:
            return raw_value
        if self._looks_like_seed(raw_value):
            return self._derive_seeded_code(self._timeslot_for(), seed=raw_value)
        return raw_value

    def matches_verification_code(self, raw_code: str) -> bool:
        if not raw_code:
            return False
        stored_value = self._raw_verification_value()
        if not stored_value:
            return False
        if stored_value.isdigit() and len(stored_value) == 3:
            return stored_value == raw_code
        if self._looks_like_seed(stored_value):
            current_slot = self._timeslot_for()
            valid_codes = {self._derive_seeded_code(current_slot, seed=stored_value)}
            if current_slot > 0:
                valid_codes.add(
                    self._derive_seeded_code(current_slot - 1, seed=stored_value)
                )
            return raw_code in valid_codes
        return stored_value == raw_code


class BulkAccountDeleteRequest(models.Model):
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
        related_name='bulk_account_delete_requests',
    )
    requester_device_id = models.CharField(max_length=255, blank=True, default='')
    requester_device_label = models.CharField(max_length=120, blank=True, default='Unknown device')
    requester_device_kind = models.CharField(
        max_length=20,
        choices=DeviceSession.DEVICE_KIND_CHOICES,
        default=DeviceSession.DEVICE_KIND_UNKNOWN,
    )
    requested_count = models.IntegerField(default=0)
    range_start_date = models.DateField()
    range_end_date = models.DateField()
    account_ids = models.TextField(default='[]')
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
        related_name='reviewed_bulk_delete_requests',
    )
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ['-created_at']

    def __str__(self):
        return (
            f"{self.user.username} - bulk delete {self.status} - "
            f"{self.requester_device_label}"
        )


class BackupCodeGenerationRequest(models.Model):
    STATUS_PENDING = 'pending'
    STATUS_DENIED = 'denied'
    STATUS_COMPLETED = 'completed'
    STATUS_EXPIRED = 'expired'
    STATUS_CHOICES = [
        (STATUS_PENDING, 'Pending'),
        (STATUS_DENIED, 'Denied'),
        (STATUS_COMPLETED, 'Completed'),
        (STATUS_EXPIRED, 'Expired'),
    ]

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    user = models.ForeignKey(
        User,
        on_delete=models.CASCADE,
        related_name='backup_code_generation_requests',
    )
    requester_device_id = models.CharField(max_length=255, blank=True, default='')
    requester_device_label = models.CharField(max_length=120, blank=True, default='Unknown device')
    requester_device_kind = models.CharField(
        max_length=20,
        choices=DeviceSession.DEVICE_KIND_CHOICES,
        default=DeviceSession.DEVICE_KIND_UNKNOWN,
    )
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
        related_name='reviewed_backup_code_generation_requests',
    )
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ['-created_at']

    def __str__(self):
        return (
            f"{self.user.username} - backup codes {self.status} - "
            f"{self.requester_device_label}"
        )
