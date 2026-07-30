from django import forms
from django.contrib import admin
from django.contrib.admin.forms import AdminAuthenticationForm
from .identity import find_user_by_login_identifier
from .models import UserProfile
from django.db import models
from django.conf import settings as django_settings


class EmailAdminAuthenticationForm(AdminAuthenticationForm):
    """Sign in to the admin with an email address, like the rest of the app."""

    # Deliberately a text input, not an email input: the browser's type="email"
    # validation would block the legacy username fallback below.
    username = forms.CharField(
        label="Email",
        widget=forms.TextInput(
            attrs={"autofocus": True, "autocomplete": "email", "inputmode": "email"}
        ),
    )

    error_messages = {
        **AdminAuthenticationForm.error_messages,
        "invalid_login": (
            "Please enter the correct email and password for a staff account. "
            "Note that both fields may be case-sensitive."
        ),
    }

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        # AuthenticationForm clamps this to the username field's max_length.
        self.fields["username"].max_length = 254
        self.fields["username"].widget.attrs["maxlength"] = 254

    def clean_username(self):
        # Resolve the email to the username that the auth backend expects, with
        # the same username fallback the app login uses for legacy accounts.
        identifier = self.cleaned_data.get("username", "")
        user = find_user_by_login_identifier(identifier)
        return user.username if user is not None else identifier


admin.site.login_form = EmailAdminAuthenticationForm


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


if django_settings.DEBUG:
    admin.site.register(UserProfile, UserProfileAdmin)
