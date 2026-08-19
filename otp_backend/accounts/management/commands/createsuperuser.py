"""``manage.py createsuperuser``, asking for an email address and nothing else.

Django's own command asks for a username first and an email second. Nobody
signs in to this API with a username -- ``accounts/identity.py`` resolves every
login by email, and ``RegisterSerializer`` has always written the address into
both columns -- so this override asks only for the address and does the same.

Accounts that predate this keep whatever username they were given; they are
found by the username fallback in ``find_user_by_login_identifier`` and are
never touched here.

For this override to win over django.contrib.auth's, ``accounts`` has to come
before ``django.contrib.auth`` in INSTALLED_APPS; see the note there.
"""
import os
import sys

from django.contrib.auth.management.commands import createsuperuser
from django.core.management.base import CommandError

from accounts.identity import find_user_by_login_identifier, normalize_email


class Command(createsuperuser.Command):
    help = "Create a superuser identified by their email address."

    def handle(self, *args, **options):
        email = normalize_email(options.get("email"))

        if not email:
            if options["interactive"]:
                try:
                    email = self._ask_for_email()
                except (KeyboardInterrupt, EOFError):
                    self.stderr.write("\nOperation cancelled.")
                    sys.exit(1)
            else:
                email = normalize_email(os.environ.get("DJANGO_SUPERUSER_EMAIL"))

        if not email:
            raise CommandError(
                "Pass --email, or set DJANGO_SUPERUSER_EMAIL, to create a "
                "superuser with --noinput."
            )
        if find_user_by_login_identifier(email) is not None:
            raise CommandError("An account already exists for {}.".format(email))

        # Django only prompts for the fields it was not handed, so filling in
        # both of them leaves the password as the one thing left to ask.
        options["email"] = email
        options[self.UserModel.USERNAME_FIELD] = email
        return super().handle(*args, **options)

    def _ask_for_email(self):
        field = self.UserModel._meta.get_field("email")
        while True:
            # get_input_data reports its own validation errors and returns None.
            value = normalize_email(self.get_input_data(field, "Email address: "))
            if not value:
                continue
            if find_user_by_login_identifier(value) is not None:
                self.stderr.write("Error: an account already exists for that address.")
                continue
            return value
