# ============================================================
# api/models.py  (ADD these to your existing models.py)
# ============================================================
 
from django.db import models
from django.contrib.auth.models import User
import uuid
 
 
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
    user = models.ForeignKey(User, on_delete=models.CASCADE)
    device_id = models.CharField(max_length=255)
    sync_type = models.CharField(max_length=50)
    status = models.CharField(max_length=50)
    timestamp = models.DateTimeField(auto_now_add=True)
    error_message = models.TextField(null=True, blank=True)
 
 
# NEW: Tombstone table — once an account ID lands here, no device can re-add it.
class AccountTombstone(models.Model):
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name='tombstones')
    account_id = models.CharField(max_length=255)
    deleted_at = models.DateTimeField(auto_now_add=True)
 
    class Meta:
        unique_together = ['user', 'account_id']
 
    def __str__(self):
        return f"{self.user.username} – tombstone {self.account_id}"
 
 
# NEW: One-time OTP codes for dangerous operations (e.g. delete-all-everywhere)
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