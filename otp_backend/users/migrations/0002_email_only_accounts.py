"""Drop ``username``, ``first_name`` and ``last_name``, and key accounts by email.

Everything here is guarded by introspection rather than by assumption, because
this runs on both kinds of database:

* On an **existing** one, ``auth_user`` still carries the three columns and a
  non-unique email. They go, and the unique constraint moves to ``email``.
* On a **fresh** one, 0001 already built the table from a model that has none of
  them, so every guard is false and this migration does nothing.

That is also what makes it safe to re-run after a half-finished deploy.
"""

from django.db import migrations

from ._adopt import (
    EMAIL_LIKE_INDEX,
    EMAIL_UNIQUE_CONSTRAINT,
    LEGACY_COLUMNS,
    USERNAME_LIKE_INDEX,
    USERNAME_UNIQUE_CONSTRAINT,
    column_names,
    has_unique_email,
    report_diverging_usernames,
    require_usable_emails,
    table_exists,
)


def make_email_the_identifier(apps, schema_editor):
    connection = schema_editor.connection
    if not table_exists(connection):
        return

    columns = column_names(connection)
    legacy = [column for column in LEGACY_COLUMNS if column in columns]

    if legacy:
        require_usable_emails(connection)
        if 'username' in columns:
            report_diverging_usernames(connection)

        # Addresses are compared case-insensitively everywhere in the app;
        # storing them lowercased keeps the unique constraint from disagreeing
        # with that.
        schema_editor.execute(
            'UPDATE "auth_user" SET "email" = lower(btrim("email"))', params=None
        )

        for column in legacy:
            # Drops the column's own unique constraint and LIKE index with it.
            schema_editor.execute(
                'ALTER TABLE "auth_user" DROP COLUMN %s'
                % schema_editor.quote_name(column),
                params=None,
            )

    if not has_unique_email(connection):
        schema_editor.execute(
            'ALTER TABLE "auth_user" ADD CONSTRAINT %s UNIQUE ("email")'
            % schema_editor.quote_name(EMAIL_UNIQUE_CONSTRAINT),
            params=None,
        )
        # The companion index Postgres needs for LIKE 'prefix%' lookups, which
        # is what Django emits alongside any unique varchar column.
        schema_editor.execute(
            'CREATE INDEX %s ON "auth_user" ("email" varchar_pattern_ops)'
            % schema_editor.quote_name(EMAIL_LIKE_INDEX),
            params=None,
        )


def restore_legacy_columns(apps, schema_editor):
    """Put the three columns back for a rollback.

    Usernames are rebuilt from the address each account signs in with, which is
    what the app had been writing into that column for years. An address longer
    than the 150 characters ``username`` allowed would fail here; none exists,
    and a rollback is the wrong moment to silently truncate an identifier.
    """
    connection = schema_editor.connection
    if not table_exists(connection):
        return

    columns = column_names(connection)

    if 'username' not in columns:
        schema_editor.execute(
            'ALTER TABLE "auth_user" ADD COLUMN "username" varchar(150) NULL',
            params=None,
        )
        schema_editor.execute(
            'UPDATE "auth_user" SET "username" = "email"', params=None
        )
        schema_editor.execute(
            'ALTER TABLE "auth_user" ALTER COLUMN "username" SET NOT NULL',
            params=None,
        )
        schema_editor.execute(
            'ALTER TABLE "auth_user" ADD CONSTRAINT %s UNIQUE ("username")'
            % schema_editor.quote_name(USERNAME_UNIQUE_CONSTRAINT),
            params=None,
        )
        schema_editor.execute(
            'CREATE INDEX %s ON "auth_user" ("username" varchar_pattern_ops)'
            % schema_editor.quote_name(USERNAME_LIKE_INDEX),
            params=None,
        )

    for column in ('first_name', 'last_name'):
        if column in columns:
            continue
        quoted = schema_editor.quote_name(column)
        schema_editor.execute(
            'ALTER TABLE "auth_user" ADD COLUMN %s varchar(150) NOT NULL '
            "DEFAULT ''" % quoted,
            params=None,
        )
        # Django keeps no database-level default of its own.
        schema_editor.execute(
            'ALTER TABLE "auth_user" ALTER COLUMN %s DROP DEFAULT' % quoted,
            params=None,
        )

    schema_editor.execute(
        'ALTER TABLE "auth_user" DROP CONSTRAINT IF EXISTS %s'
        % schema_editor.quote_name(EMAIL_UNIQUE_CONSTRAINT),
        params=None,
    )
    schema_editor.execute(
        'DROP INDEX IF EXISTS %s' % schema_editor.quote_name(EMAIL_LIKE_INDEX),
        params=None,
    )


def relabel_user_content_type(apps, schema_editor):
    """Move the existing ``auth | user`` content type over to ``users | user``.

    Left alone, the swap would strand the old row: every admin log entry about
    an account points at it, ``create_permissions`` would add a second set of
    user permissions under the new label, and the next
    ``remove_stale_contenttypes`` would offer to delete the old row and take
    that admin history with it. Renaming the row in place avoids all three.

    On a fresh database ``django_content_type`` is still empty here -- content
    types are created in post_migrate -- so this does nothing.
    """
    ContentType = apps.get_model('contenttypes', 'ContentType')
    legacy = ContentType.objects.filter(app_label='auth', model='user').first()
    if legacy is None:
        return

    current = ContentType.objects.filter(app_label='users', model='user').first()
    if current is None:
        # The ordinary path. Renaming the row rather than replacing it means
        # every admin log entry and permission that points at it follows along
        # without being touched.
        legacy.app_label = 'users'
        legacy.save(update_fields=['app_label'])
        return

    # Both rows exist, which happens if this migration was rolled back and
    # re-applied: post_migrate re-created the new row while the old one was
    # still there. Move the history across and leave the emptied legacy row
    # for remove_stale_contenttypes rather than cascading a delete through it.
    LogEntry = apps.get_model('admin', 'logentry')
    LogEntry.objects.filter(content_type=legacy).update(content_type=current)


def restore_user_content_type(apps, schema_editor):
    ContentType = apps.get_model('contenttypes', 'ContentType')
    if ContentType.objects.filter(app_label='auth', model='user').exists():
        return
    ContentType.objects.filter(app_label='users', model='user').update(app_label='auth')


class Migration(migrations.Migration):

    dependencies = [
        ('users', '0001_initial'),
        ('contenttypes', '0002_remove_content_type_name'),
        # LogEntry rows are re-pointed when a rollback leaves two user
        # content types behind.
        ('admin', '0001_initial'),
    ]

    operations = [
        migrations.RunPython(make_email_the_identifier, restore_legacy_columns),
        migrations.RunPython(relabel_user_content_type, restore_user_content_type),
    ]
