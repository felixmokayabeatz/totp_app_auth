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
    readonly_fields = ("id", "created_at", "updated_at")


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
    readonly_fields = ("timestamp",)


@admin.register(AccountTombstone)
class AccountTombstoneAdmin(admin.ModelAdmin):
    list_display = (
        "user",
        "account_id",
        "deleted_at",
    )
    list_filter = ("deleted_at",)
    search_fields = ("user__username", "account_id")
    readonly_fields = ("deleted_at",)


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
    readonly_fields = ("created_at",)

    @admin.display(boolean=True, description="Valid?")
    def is_valid(self, obj):
        return obj.is_valid()