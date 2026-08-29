"""Drop the group and per-user-permission join tables.

``auth_user_groups`` and ``auth_user_user_permissions`` arrived with
``PermissionsMixin`` and were never used: no group has ever been created here,
no per-user permission has ever been granted, and every staff account is a
superuser. Removing the two ManyToManyFields drops both tables.

``auth_group``, ``auth_group_permissions`` and ``auth_permission`` stay. They
belong to ``django.contrib.auth``, which cannot leave INSTALLED_APPS -- the
admin declares a hard dependency on it, and the login, the password hashing and
the authentication backend all live there. Those three tables are inert now:
nothing in this project reads them.
"""

from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('users', '0002_email_only_accounts'),
    ]

    operations = [
        migrations.RemoveField(
            model_name='user',
            name='groups',
        ),
        migrations.RemoveField(
            model_name='user',
            name='user_permissions',
        ),
        migrations.AlterField(
            model_name='user',
            name='is_superuser',
            field=models.BooleanField(default=False, help_text='Designates that this user has every permission in the admin.', verbose_name='superuser status'),
        ),
    ]
