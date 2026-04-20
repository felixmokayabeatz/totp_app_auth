from django.contrib import admin
from .models import UserProfile
from django.db import models


@admin.register(UserProfile)
class UserProfileAdmin(admin.ModelAdmin):
    list_display = (
        "user",
        "updated_at",
    )
    search_fields = ("user__username", "bio")
    readonly_fields = ("updated_at", "bio")  # Make bio read-only
    
    # Set rows for bio field (3 rows at default)
    formfield_overrides = {
        models.TextField: {'widget': admin.widgets.AdminTextareaWidget(attrs={'rows': 3})},
    }
    
    # Hide sensitive fields from list view but still editable if needed
    fieldsets = (
        ("User Info", {
            "fields": ("user", "profile_photo", "bio")
        }),
        ("Metadata", {
            "fields": ("updated_at",),
        }),
    )
    
    # Disable deleting
    def has_delete_permission(self, request, obj=None):
        return False
    
    # Disable adding new profiles
    def has_add_permission(self, request):
        return False
    
    # Make user field non-clickable (disable opening user URL)
    def get_list_display_links(self, request, list_display):
        # Return empty tuple to make all list_display fields non-clickable
        return ()
    
    # Override change view to prevent edits (except maybe specific fields if needed)
    def get_readonly_fields(self, request, obj=None):
        # Make all fields readonly except maybe some you want to allow
        if obj:  # Existing object
            return [field.name for field in self.model._meta.fields]
        return self.readonly_fields
    
    # Disable opening image URL - override the image display
    def profile_photo_display(self, obj):
        if obj.profile_photo:
            # Just show text instead of clickable link
            return f"Profile photo exists" if obj.profile_photo else "No photo"
        return "No photo"
    profile_photo_display.short_description = "Profile Photo"
    
    # Override the change form template to disable editing controls
    def change_view(self, request, object_id, form_url='', extra_context=None):
        extra_context = extra_context or {}
        extra_context['show_save'] = False
        extra_context['show_save_and_continue'] = False
        extra_context['show_delete'] = False
        return super().change_view(request, object_id, form_url, extra_context=extra_context)
    
    # Make bio widget have 3 rows specifically
    def get_form(self, request, obj=None, **kwargs):
        form = super().get_form(request, obj, **kwargs)
        if 'bio' in form.base_fields:
            form.base_fields['bio'].widget.attrs['rows'] = 3
        return form
    
    # Disable editing entirely - view only
    def has_change_permission(self, request, obj=None):
        return False