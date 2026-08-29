"""One-time step that lets a database migrated before ``users`` existed move on.

``AUTH_USER_MODEL`` used to be ``auth.User``. Every migration that has a foreign
key to an account -- ``accounts.0001_initial``, ``api.0001_initial``,
``twofa.0001_initial`` and the rest -- carries a swappable dependency, and that
dependency now resolves to ``users.0001_initial``. On a database where those
migrations were applied years ago, Django's consistency check sees an applied
migration whose dependency is unapplied and refuses to run ``migrate`` at all::

    InconsistentMigrationHistory: Migration accounts.0001_initial is applied
    before its dependency users.0001_initial on database 'default'.

There is nothing for ``users.0001_initial`` to *do* on such a database -- the
``auth_user`` table it would create is already there, which is why that
migration builds the table only when it is missing -- so the fix is to record it
as applied and let ``migrate`` carry on with 0002, the migration that actually
changes the schema.

Safe to run more than once, and safe to run on a fresh database, where it finds
nothing to do and says so. Run it before ``migrate``::

    python manage.py adopt_user_table
    python manage.py migrate
"""

from django.core.management.base import BaseCommand
from django.db import DEFAULT_DB_ALIAS, connections
from django.db.migrations.recorder import MigrationRecorder

APP_LABEL = 'users'
MIGRATION_NAME = '0001_initial'


class Command(BaseCommand):
    help = (
        'Record users.0001_initial as applied on a database whose auth_user '
        'table predates it. Run once, before migrate.'
    )

    def add_arguments(self, parser):
        parser.add_argument(
            '--database',
            default=DEFAULT_DB_ALIAS,
            help='The database to act on. Defaults to "default".',
        )

    def handle(self, *args, **options):
        connection = connections[options['database']]
        recorder = MigrationRecorder(connection)

        if not recorder.has_table():
            self.stdout.write(
                'No migration history yet -- this database has never been '
                'migrated. Just run migrate.'
            )
            return

        if (APP_LABEL, MIGRATION_NAME) in recorder.applied_migrations():
            self.stdout.write(
                self.style.SUCCESS(
                    '%s.%s is already recorded. Nothing to do.'
                    % (APP_LABEL, MIGRATION_NAME)
                )
            )
            return

        if 'auth_user' not in connection.introspection.table_names():
            self.stdout.write(
                'There is no auth_user table to adopt, so migrate will create '
                'one normally. Nothing to do.'
            )
            return

        recorder.record_applied(APP_LABEL, MIGRATION_NAME)
        self.stdout.write(
            self.style.SUCCESS(
                'Recorded %s.%s as applied against the existing auth_user '
                'table. Run migrate next -- 0002 drops the username, '
                'first_name and last_name columns.' % (APP_LABEL, MIGRATION_NAME)
            )
        )
