from django import forms
from django.contrib import admin
from django.contrib.admin.forms import AdminAuthenticationForm
from .models import UserProfile
from django.db import models
from django.conf import settings as django_settings


class EmailAdminAuthenticationForm(AdminAuthenticationForm):
    """Sign in to the admin with an email address, like the rest of the app.

    Only the presentation is custom. The field is still called "username"
    because that is the name AuthenticationForm hands to authenticate(), and
    the auth backend resolves it against USERNAME_FIELD -- the email column.
    """

    username = forms.EmailField(
        label="Email",
        max_length=254,
        widget=forms.EmailInput(
            attrs={"autofocus": True, "autocomplete": "email", "maxlength": 254}
        ),
    )

    error_messages = {
        **AdminAuthenticationForm.error_messages,
        "invalid_login": (
            "Please enter the correct email and password for a staff account. "
            "Note that the password may be case-sensitive."
        ),
    }


admin.site.login_form = EmailAdminAuthenticationForm


class UserProfileAdmin(admin.ModelAdmin):
    list_display = (
        "user",
        "updated_at",
    )
    search_fields = ("user__email", "bio")
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


if django_settings.DEBUG:
    admin.site.register(UserProfile, UserProfileAdmin)
