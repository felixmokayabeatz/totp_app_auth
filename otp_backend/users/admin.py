"""Admin for the email-only user model.

Django's stock ``UserAdmin`` is built around a username and a person's name, so
every list, form and search here is redefined against the one identifier this
project has: the email address.
"""

from django.contrib import admin
from django.contrib.auth.admin import UserAdmin as DjangoUserAdmin
from django.contrib.auth.forms import AdminUserCreationForm, UserChangeForm
from django.contrib.auth.models import Group

from .models import User


class EmailUserChangeForm(UserChangeForm):
    class Meta(UserChangeForm.Meta):
        model = User
        fields = '__all__'
        field_classes = {}


class EmailUserCreationForm(AdminUserCreationForm):
    class Meta(AdminUserCreationForm.Meta):
        model = User
        fields = ('email',)
        field_classes = {}


class UserAdmin(DjangoUserAdmin):
    form = EmailUserChangeForm
    add_form = EmailUserCreationForm

    fieldsets = (
        (None, {'fields': ('email', 'password')}),
        (
            'Permissions',
            {
                'fields': ('is_active', 'is_staff', 'is_superuser'),
                'description': (
                    'Staff can open the admin; superusers can change things in '
                    'it. There is nothing finer grained than that.'
                ),
            },
        ),
        ('Important dates', {'fields': ('last_login', 'date_joined')}),
    )
    add_fieldsets = (
        (
            None,
            {
                'classes': ('wide',),
                'fields': ('email', 'usable_password', 'password1', 'password2'),
            },
        ),
    )
    list_display = ('email', 'is_staff', 'is_superuser', 'is_active', 'last_login')
    # No 'groups' filter: with the Group admin gone there is no way to create
    # one, so it could only ever render an empty filter panel.
    list_filter = ('is_staff', 'is_superuser', 'is_active')
    search_fields = ('email',)
    ordering = ('email',)
    readonly_fields = ('last_login', 'date_joined')
    # Django's UserAdmin points this at groups and user_permissions, which this
    # model no longer has.
    filter_horizontal = ()


admin.site.register(User, UserAdmin)


# Nothing here uses groups: permissions come from is_superuser, and both
# auth_group and auth_user_groups have always been empty. Registering it only
# left an "Authentication and Authorization" section in the sidebar with one
# useless link in it.
#
# django.contrib.auth.admin is imported explicitly rather than relied on: admin
# autodiscovery walks INSTALLED_APPS in order and 'users' comes before
# 'django.contrib.auth', so without this the unregister would run before Group
# was ever registered and quietly do nothing.
import django.contrib.auth.admin  # noqa: E402,F401  (imported for its registrations)

try:
    admin.site.unregister(Group)
except admin.sites.NotRegistered:
    pass
