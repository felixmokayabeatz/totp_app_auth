# twofa/models.py

from django.db import models
from django.contrib.auth.models import User
import random
import string

class EmailVerification(models.Model):
    user = models.ForeignKey(User, on_delete=models.CASCADE)
    code = models.CharField(max_length=6)
    created_at = models.DateTimeField(auto_now_add=True)
    is_used = models.BooleanField(default=False)
    
    def save(self, *args, **kwargs):
        if not self.code:
            self.code = ''.join(random.choices(string.digits, k=6))
        super().save(*args, **kwargs)
    
    def is_valid(self):
        from django.utils import timezone
        from datetime import timedelta
        return not self.is_used and self.created_at > timezone.now() - timedelta(minutes=10)