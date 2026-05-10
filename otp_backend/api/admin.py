from django.contrib import admin, messages
from django.utils import timezone
from .models import (
    AppNotification,
    DeviceSession,
    EncryptedData,
    SyncLog,
    AccountTombstone,
    DeleteOTPCode,
    BackupCodeSet,
    PasswordlessLoginRequest,
)


@admin.register(EncryptedData)
class EncryptedDataAdmin(admin.ModelAdmin):
    list_display = (
        "id",
        "user",
        "data_type",
        "version",
        "created_at",
        "updated_at",
        "synced_at",
    )
    list_filter = ("data_type", "created_at", "updated_at")
    search_fields = ("user__username", "data_type")
    readonly_fields = ("id", "created_at", "updated_at", "synced_at", "user", "data_type", "version")
    
    # Disable actions
    def has_add_permission(self, request):
        return False
    
    def has_change_permission(self, request, obj=None):
        return False
    
    def has_delete_permission(self, request, obj=None):
        return False
    
    # Disable clickable links in list display
    def get_list_display_links(self, request, list_display):
        return ()


@admin.register(SyncLog)
class SyncLogAdmin(admin.ModelAdmin):
    list_display = (
        "user",
        "device_id",
        "sync_type",
        "status",
        "timestamp",
    )
    list_filter = ("sync_type", "status", "timestamp")
    search_fields = ("user__username", "device_id")
    readonly_fields = ("timestamp", "user", "device_id", "sync_type", "status")
    
    def has_add_permission(self, request):
        return False
    
    def has_change_permission(self, request, obj=None):
        return False
    
    def has_delete_permission(self, request, obj=None):
        return False
    
    def get_list_display_links(self, request, list_display):
        return ()


@admin.register(AccountTombstone)
class AccountTombstoneAdmin(admin.ModelAdmin):
    list_display = (
        "user",
        "account_id",
        "deleted_at",
    )
    list_filter = ("deleted_at",)
    search_fields = ("user__username", "account_id")
    readonly_fields = ("deleted_at", "user", "account_id")
    
    def has_add_permission(self, request):
        return False
    
    def has_change_permission(self, request, obj=None):
        return False
    
    def has_delete_permission(self, request, obj=None):
        return False
    
    def get_list_display_links(self, request, list_display):
        return ()


@admin.register(DeleteOTPCode)
class DeleteOTPCodeAdmin(admin.ModelAdmin):
    list_display = (
        "user",
        "code",
        "created_at",
        "used",
        "is_valid",
    )
    list_filter = ("used", "created_at")
    search_fields = ("user__username",)
    readonly_fields = ("created_at", "user", "code", "used")
    
    @admin.display(boolean=True, description="Valid?")
    def is_valid(self, obj):
        return obj.is_valid()
    
    def has_add_permission(self, request):
        return False
    
    def has_change_permission(self, request, obj=None):
        return False
    
    def has_delete_permission(self, request, obj=None):
        return False
    
    def get_list_display_links(self, request, list_display):
        return ()


# @admin.register(BackupCodeSet)
# class BackupCodeSetAdmin(admin.ModelAdmin):
#     list_display = (
#         "user",
#         "created_at",
#         "updated_at",
#         "last_used_at",
#     )
#     search_fields = ("user__username", "user__email")
#     readonly_fields = ("user", "encrypted_codes", "created_at", "updated_at", "last_used_at")

#     def has_add_permission(self, request):
#         return False

#     def has_change_permission(self, request, obj=None):
#         return False

#     def has_delete_permission(self, request, obj=None):
#         return False

#     def get_list_display_links(self, request, list_display):
#         return ()

from django.contrib import admin

@admin.register(BackupCodeSet)
class BackupCodeSetAdmin(admin.ModelAdmin):
    list_display = (
        "user",
        "created_at",
        "updated_at",
        "last_used_at",
    )

    search_fields = (
        "user__username",
        "user__email",
    )

    readonly_fields = (
        "created_at",
        "updated_at",
        "last_used_at",
    )

    # Optional: make rows clickable
    list_display_links = ("user",)

    # Optional: prevent creating manually
    def has_add_permission(self, request):
        return False

@admin.register(AppNotification)
class AppNotificationAdmin(admin.ModelAdmin):
    list_display = (
        "user",
        "notification_type",
        "is_read",
        "created_at",
        "read_at",
    )
    list_filter = ("notification_type", "is_read", "created_at")
    search_fields = ("user__username", "user__email", "notification_type")
    readonly_fields = (
        "user",
        "notification_type",
        "encrypted_payload",
        "is_read",
        "read_at",
        "created_at",
        "updated_at",
    )

    def has_add_permission(self, request):
        return False

    def has_change_permission(self, request, obj=None):
        return False

    def has_delete_permission(self, request, obj=None):
        return False

    def get_list_display_links(self, request, list_display):
        return ()


@admin.register(DeviceSession)
class DeviceSessionAdmin(admin.ModelAdmin):
    actions = ("mark_selected_session_as_primary",)
    list_display = (
        "user",
        "device_label",
        "device_kind",
        "device_id",
        "is_primary",
        "is_active",
        "last_seen_at",
        "created_at",
        "revoked_at",
    )
    list_filter = ("is_primary", "is_active", "created_at", "last_seen_at", "revoked_at")
    search_fields = ("user__username", "user__email", "device_label", "device_id", "ip_address")
    readonly_fields = (
        "id",
        "user",
        "device_id",
        "device_fingerprint",
        "device_label",
        "device_kind",
        "user_agent",
        "ip_address",
        "is_primary",
        "is_active",
        "created_at",
        "updated_at",
        "last_seen_at",
        "revoked_at",
    )

    def has_add_permission(self, request):
        return False

    def has_change_permission(self, request, obj=None):
        return request.user.is_superuser

    def has_delete_permission(self, request, obj=None):
        return False

    def get_list_display_links(self, request, list_display):
        return ()

    @admin.action(description="Mark selected device session as primary")
    def mark_selected_session_as_primary(self, request, queryset):
        if not request.user.is_superuser:
            self.message_user(
                request,
                "Only a superuser can change the primary device here.",
                level=messages.ERROR,
            )
            return

        if queryset.count() != 1:
            self.message_user(
                request,
                "Select exactly one active device session to make primary.",
                level=messages.ERROR,
            )
            return

        session = queryset.select_related("user").first()
        if session is None or not session.is_active or session.revoked_at is not None:
            self.message_user(
                request,
                "Choose an active device session.",
                level=messages.ERROR,
            )
            return

        now = timezone.now()
        DeviceSession.objects.filter(
            user=session.user,
            is_active=True,
            revoked_at__isnull=True,
            is_primary=True,
        ).exclude(id=session.id).update(
            is_primary=False,
            updated_at=now,
        )
        if not session.is_primary:
            session.is_primary = True
            session.save(update_fields=["is_primary", "updated_at"])

        self.message_user(
            request,
            f"{session.device_label} is now the primary device for {session.user.username}.",
            level=messages.SUCCESS,
        )


@admin.register(PasswordlessLoginRequest)
class PasswordlessLoginRequestAdmin(admin.ModelAdmin):
    list_display = (
        "user",
        "requester_device_label",
        "requester_device_kind",
        "verification_code",
        "status",
        "expires_at",
        "created_at",
    )
    list_filter = ("status", "requester_device_kind", "created_at", "expires_at")
    search_fields = ("user__username", "user__email", "requester_device_label", "requester_device_id")
    readonly_fields = (
        "id",
        "user",
        "requester_device_id",
        "requester_device_label",
        "requester_device_kind",
        "verification_code",
        "status",
        "expires_at",
        "approved_at",
        "completed_at",
        "reviewed_by_session",
        "created_at",
        "updated_at",
    )

    def has_add_permission(self, request):
        return False

    def has_change_permission(self, request, obj=None):
        return False

    def has_delete_permission(self, request, obj=None):
        return False

    def get_list_display_links(self, request, list_display):
        return ()
