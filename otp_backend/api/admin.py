from django.contrib import admin
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


@admin.register(BackupCodeSet)
class BackupCodeSetAdmin(admin.ModelAdmin):
    list_display = (
        "user",
        "created_at",
        "updated_at",
        "last_used_at",
    )
    search_fields = ("user__username", "user__email")
    readonly_fields = ("user", "encrypted_codes", "created_at", "updated_at", "last_used_at")

    def has_add_permission(self, request):
        return False

    def has_change_permission(self, request, obj=None):
        return False

    def has_delete_permission(self, request, obj=None):
        return False

    def get_list_display_links(self, request, list_display):
        return ()


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
    list_display = (
        "user",
        "device_label",
        "device_kind",
        "device_id",
        "is_active",
        "last_seen_at",
        "created_at",
        "revoked_at",
    )
    list_filter = ("is_active", "created_at", "last_seen_at", "revoked_at")
    search_fields = ("user__username", "user__email", "device_label", "device_id", "ip_address")
    readonly_fields = (
        "id",
        "user",
        "device_id",
        "device_label",
        "device_kind",
        "user_agent",
        "ip_address",
        "is_active",
        "created_at",
        "updated_at",
        "last_seen_at",
        "revoked_at",
    )

    def has_add_permission(self, request):
        return False

    def has_change_permission(self, request, obj=None):
        return False

    def has_delete_permission(self, request, obj=None):
        return False

    def get_list_display_links(self, request, list_display):
        return ()


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
