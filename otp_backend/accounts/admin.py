from django.contrib import admin
from .models import UserProfile


@admin.register(UserProfile)
class UserProfileAdmin(admin.ModelAdmin):
    list_display = (
        "user",
        "updated_at",
    )
    search_fields = ("user__username", "bio")
    readonly_fields = ("updated_at",)

    # Hide sensitive fields from list view but still editable if needed
    fieldsets = (
        ("User Info", {
            "fields": ("user", "profile_photo", "bio")
        }),
        ("Encryption Keys ⚠️", {
            "fields": ("encryption_public_key", "encryption_private_key"),
            "classes": ("collapse",),  # collapsible section
        }),
        ("Metadata", {
            "fields": ("updated_at",),
        }),
    )