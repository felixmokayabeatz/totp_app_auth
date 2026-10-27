
import secrets
import string
from datetime import timedelta

from django.conf import settings
from django.db import models
from django.utils import timezone
from django.utils.crypto import constant_time_compare


class EmailVerification(models.Model):
    """A short-lived numeric code emailed to an account's address.

    Six digits is a million possibilities, which sounds like a lot until you
    notice that the endpoints checking it are AllowAny and used to accept an
    unlimited number of guesses inside the ten-minute window -- enough tries to
    make guessing a password-reset code, and with it the account, realistic.
    ``MAX_ATTEMPTS`` closes that: a code burns itself out after a handful of
    wrong answers and the caller has to request a new one, which lands in the
    real owner's inbox.
    """

    CODE_LENGTH = 6
    LIFETIME = timedelta(minutes=10)
    MAX_ATTEMPTS = 5

    user = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE)
    code = models.CharField(max_length=6)
    created_at = models.DateTimeField(auto_now_add=True)
    is_used = models.BooleanField(default=False)
    attempts = models.PositiveSmallIntegerField(default=0)

    class Meta:
        indexes = [
            models.Index(
                fields=['user', 'is_used', '-created_at'],
                name='twofa_user_unused_recent',
            ),
        ]

    def save(self, *args, **kwargs):
        if not self.code:
            self.code = ''.join(
                secrets.choice(string.digits) for _ in range(self.CODE_LENGTH)
            )
        super().save(*args, **kwargs)

    def expires_at(self):
        return self.created_at + self.LIFETIME

    def is_expired(self):
        return timezone.now() > self.expires_at()

    def is_valid(self):
        return (
            not self.is_used
            and self.attempts < self.MAX_ATTEMPTS
            and not self.is_expired()
        )

    def matches(self, raw_code: str) -> bool:
        """Compare in constant time, so a wrong code leaks no digit positions."""
        return bool(raw_code) and constant_time_compare(self.code, raw_code)

    def register_failed_attempt(self):
        """Count a wrong guess, and retire the code once there are too many."""
        self.attempts += 1
        fields = ['attempts']
        if self.attempts >= self.MAX_ATTEMPTS:
            self.is_used = True
            fields.append('is_used')
        self.save(update_fields=fields)

    def attempts_remaining(self) -> int:
        return max(0, self.MAX_ATTEMPTS - self.attempts)

    def consume(self):
        self.is_used = True
        self.save(update_fields=['is_used'])
