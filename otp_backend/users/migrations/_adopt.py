"""Introspection helpers shared by the two migrations that adopt ``auth_user``.

Kept beside them rather than inside them because both need the same answers to
the same question: what does this database's ``auth_user`` look like right now?
The pair has to land on a fresh database (every test run, a new deployment) and
on one that has been serving accounts for a year, and leave both identical.
"""

LEGACY_COLUMNS = ('username', 'first_name', 'last_name')

# Postgres names an inline UNIQUE in CREATE TABLE "<table>_<column>_key", so
# reusing that name keeps an adopted table shaped like a freshly created one.
EMAIL_UNIQUE_CONSTRAINT = 'auth_user_email_key'
EMAIL_LIKE_INDEX = 'auth_user_email_like'

USERNAME_UNIQUE_CONSTRAINT = 'auth_user_username_key'
USERNAME_LIKE_INDEX = 'auth_user_username_like'


def table_exists(connection, table='auth_user'):
    return table in connection.introspection.table_names()


def column_names(connection, table='auth_user'):
    with connection.cursor() as cursor:
        return {
            column.name
            for column in connection.introspection.get_table_description(cursor, table)
        }


def has_unique_email(connection, table='auth_user'):
    with connection.cursor() as cursor:
        constraints = connection.introspection.get_constraints(cursor, table)
    return any(
        details['columns'] == ['email']
        and (details['unique'] or details['primary_key'])
        for details in constraints.values()
    )


def require_usable_emails(connection):
    """Refuse to make ``email`` the login identifier while it cannot be one.

    A stock ``auth_user`` allows blank and duplicated addresses. Failing here
    with the offending rows named is far kinder than the IntegrityError the
    unique constraint would raise a few statements later.
    """
    with connection.cursor() as cursor:
        cursor.execute(
            "SELECT id FROM auth_user "
            "WHERE email IS NULL OR btrim(email) = '' ORDER BY id"
        )
        blank = [row[0] for row in cursor.fetchall()]
        cursor.execute(
            "SELECT lower(btrim(email)), count(*) FROM auth_user "
            "WHERE btrim(email) <> '' GROUP BY 1 HAVING count(*) > 1 ORDER BY 1"
        )
        duplicated = [row[0] for row in cursor.fetchall()]

    problems = []
    if blank:
        problems.append(
            'these auth_user rows have no email address: '
            + ', '.join('id=%s' % pk for pk in blank)
        )
    if duplicated:
        problems.append(
            'these addresses are shared by more than one account: '
            + ', '.join(duplicated)
        )
    if problems:
        raise RuntimeError(
            'auth_user cannot become an email-keyed table yet -- '
            + '; '.join(problems)
            + '. Give every account one distinct address, then migrate again.'
        )


def report_diverging_usernames(connection):
    """Name the accounts whose username was not simply their email address.

    The app derives its vault encryption key from whatever the API returns as
    ``user["username"]``, which from here on is the address. For an account
    registered through the app the two were always the same string, so nothing
    changes. For an older account they differ, and the next *fresh* sign-in on
    that account -- a re-install, a new device, a sign-out and back in --
    derives a different key than the one its synced data was encrypted with.
    Installs that are already signed in keep the key they stored and are
    unaffected.

    The comparison is exact, not case-insensitive. Key derivation hashes the
    identifier byte for byte, so an account whose username was ``A@b.com``
    against an address this migration is about to lowercase to ``a@b.com``
    breaks in precisely the same way as one whose username was a real name --
    and that is the far more common case, since the app wrote the address the
    person typed into both columns. Comparing case-insensitively here hid
    exactly the accounts most likely to be affected.

    This prints the list rather than refusing: it is information the operator
    needs at the moment of the switch, and the column is about to be gone.
    """
    with connection.cursor() as cursor:
        cursor.execute(
            "SELECT id, username, email FROM auth_user "
            "WHERE username <> lower(btrim(email)) ORDER BY id"
        )
        rows = cursor.fetchall()

    if not rows:
        return

    print(
        '\n  NOTE: %d account(s) had a username that was not their email '
        'address:' % len(rows)
    )
    for pk, username, email in rows:
        print('    id=%s  username=%r  email=%r' % (pk, username, email))
    print(
        '  Their next fresh sign-in re-derives a vault key from the address, '
        'not\n  the old username, so cloud data encrypted under the old key '
        'will not\n  decrypt for them. Installs already signed in are '
        'unaffected.\n'
    )
