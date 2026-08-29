"""Declare ``users.User`` and give it the ``auth_user`` table.

This migration is deliberately inert on a database that already has an
``auth_user`` table: it records model state, and creates the table only when
there is none to adopt. That is what makes it safe to mark as applied by hand,
which an existing database has to do -- ``accounts.0001_initial`` and friends
were applied years before this app existed, and Django refuses to migrate while
an applied migration depends on an unapplied one. ``manage.py adopt_user_table``
records it; see that command for the whole story.

The schema change itself -- dropping the three columns the new model does not
have -- lives in 0002 so that it runs for real on every database.
"""

import django.utils.timezone
from django.db import migrations, models

import users.models

from ._adopt import table_exists


def create_table_if_absent(apps, schema_editor):
    """Build ``auth_user`` when nothing has built it.

    On a fresh database ``django.contrib.auth`` skips creating the table once
    AUTH_USER_MODEL points elsewhere, so this is the only thing that will.
    create_model also builds the auth_user_groups and
    auth_user_user_permissions join tables.
    """
    if table_exists(schema_editor.connection):
        return
    schema_editor.create_model(apps.get_model('users', 'User'))


class Migration(migrations.Migration):

    initial = True

    dependencies = [
        ('auth', '0012_alter_user_first_name_max_length'),
    ]

    operations = [
        migrations.SeparateDatabaseAndState(
            state_operations=[
                migrations.CreateModel(
                    name='User',
                    fields=[
                        (
                            'id',
                            models.AutoField(
                                auto_created=True,
                                primary_key=True,
                                serialize=False,
                                verbose_name='ID',
                            ),
                        ),
                        ('password', models.CharField(max_length=128, verbose_name='password')),
                        (
                            'last_login',
                            models.DateTimeField(
                                blank=True, null=True, verbose_name='last login'
                            ),
                        ),
                        (
                            'is_superuser',
                            models.BooleanField(
                                default=False,
                                help_text=(
                                    'Designates that this user has all permissions without '
                                    'explicitly assigning them.'
                                ),
                                verbose_name='superuser status',
                            ),
                        ),
                        (
                            'email',
                            models.EmailField(
                                max_length=254, unique=True, verbose_name='email address'
                            ),
                        ),
                        (
                            'is_staff',
                            models.BooleanField(
                                default=False,
                                help_text=(
                                    'Designates whether the user can log into this admin site.'
                                ),
                                verbose_name='staff status',
                            ),
                        ),
                        (
                            'is_active',
                            models.BooleanField(
                                default=True,
                                help_text=(
                                    'Designates whether this account should be treated as '
                                    'active. Unselect this instead of deleting accounts.'
                                ),
                                verbose_name='active',
                            ),
                        ),
                        (
                            'date_joined',
                            models.DateTimeField(
                                default=django.utils.timezone.now,
                                verbose_name='date joined',
                            ),
                        ),
                        (
                            'groups',
                            models.ManyToManyField(
                                blank=True,
                                db_table='auth_user_groups',
                                help_text=(
                                    'The groups this user belongs to. A user will get all '
                                    'permissions granted to each of their groups.'
                                ),
                                related_name='user_set',
                                related_query_name='user',
                                to='auth.group',
                                verbose_name='groups',
                            ),
                        ),
                        (
                            'user_permissions',
                            models.ManyToManyField(
                                blank=True,
                                db_table='auth_user_user_permissions',
                                help_text='Specific permissions for this user.',
                                related_name='user_set',
                                related_query_name='user',
                                to='auth.permission',
                                verbose_name='user permissions',
                            ),
                        ),
                    ],
                    options={
                        'verbose_name': 'user',
                        'verbose_name_plural': 'users',
                        'db_table': 'auth_user',
                    },
                    managers=[
                        ('objects', users.models.UserManager()),
                    ],
                ),
            ],
            database_operations=[],
        ),
        # Reversing leaves auth_user in place: rolling back means
        # django.contrib.auth.User owns the table again, and it expects to
        # find the rows that are already in it.
        migrations.RunPython(create_table_if_absent, migrations.RunPython.noop),
    ]
