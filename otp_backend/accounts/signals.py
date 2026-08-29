from django.db.models.signals import post_save
from django.conf import settings as django_settings
from django.dispatch import receiver
from .models import UserProfile


def debug_print(*args, **kwargs):
    if django_settings.DEBUG:
        print(*args, **kwargs)

@receiver(post_save, sender=django_settings.AUTH_USER_MODEL)
def ensure_user_profile(sender, instance, created, **kwargs):
    """Give every user exactly one UserProfile.

    Deliberately does not re-save an existing profile: the old handler wrote the
    profile row on every single user.save(), which cost an extra UPDATE per save
    and made UserProfile.updated_at track user saves instead of profile edits.
    """
    if created:
        UserProfile.objects.create(user=instance)
        debug_print(f"Profile created for user: {instance.email}")
        return

    _, profile_created = UserProfile.objects.get_or_create(user=instance)
    if profile_created:
        debug_print(f"Profile created for existing user: {instance.email}")
