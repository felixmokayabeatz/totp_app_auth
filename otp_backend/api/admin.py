from django.contrib import admin
from .models import EncryptedData, SyncLog, AccountTombstone, DeleteOTPCode


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