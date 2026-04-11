from django.db.models.signals import post_save
from django.contrib.auth.models import User
from django.dispatch import receiver
from .models import UserProfile

@receiver(post_save, sender=User)
def create_user_profile(sender, instance, created, **kwargs):
    """Create a UserProfile for every new user"""
    if created:
        UserProfile.objects.create(user=instance)
        print(f"Profile created for user: {instance.username}")

@receiver(post_save, sender=User)
def save_user_profile(sender, instance, **kwargs):
    """Save UserProfile when user is saved"""
    if hasattr(instance, 'profile'):
        instance.profile.save()
    else:
        # If profile doesn't exist, create it
        UserProfile.objects.create(user=instance)
        print(f"Profile created for existing user: {instance.username}")