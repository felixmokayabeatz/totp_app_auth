# api/models.py

from django.db import models
from django.contrib.auth.models import User
import uuid


class EncryptedData(models.Model):
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name='encrypted_data')
    data_type = models.CharField(max_length=50)  # 'otp_accounts', 'passwords'
    encrypted_content = models.TextField()
    version = models.IntegerField(default=1)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)
    synced_at = models.DateTimeField(null=True, blank=True)
    
    class Meta:
        unique_together = ['user', 'data_type']
    
    def __str__(self):
        return f"{self.user.username} - {self.data_type}"

class SyncLog(models.Model):
    user = models.ForeignKey(User, on_delete=models.CASCADE)
    device_id = models.CharField(max_length=255)
    sync_type = models.CharField(max_length=50)  # 'upload', 'download'
    status = models.CharField(max_length=50)  # 'success', 'failed'
    timestamp = models.DateTimeField(auto_now_add=True)
    error_message = models.TextField(null=True, blank=True)