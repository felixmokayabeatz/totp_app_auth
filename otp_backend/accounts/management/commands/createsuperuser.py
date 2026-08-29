"""``manage.py createsuperuser``, asking for an email address and nothing else.

``users.User`` already makes ``email`` the USERNAME_FIELD, so Django's own
command asks the right question -- but it asks it as "Email address" only after
deciding the address is free by a lookup that is case-sensitive. This override
normalises the address the way the rest of the app does before anything is
written, so ``Felix@Example.com`` cannot become a second account alongside
``felix@example.com``.

For this override to win over django.contrib.auth's, ``accounts`` has to come
before ``django.contrib.auth`` in INSTALLED_APPS; see the note there.
"""
import os
import sys

from django.contrib.auth.management.commands import createsuperuser
from django.core.management.base import CommandError

from accounts.identity import find_user_by_email, normalize_email


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
        if find_user_by_email(email) is not None:
            raise CommandError("An account already exists for {}.".format(email))

        # USERNAME_FIELD is "email" too, so this fills the one field Django
        # would otherwise prompt for and leaves the password as the only ask.
        options["email"] = email
        return super().handle(*args, **options)

    def _ask_for_email(self):
        field = self.UserModel._meta.get_field("email")
        while True:
            # get_input_data reports its own validation errors and returns None.
            value = normalize_email(self.get_input_data(field, "Email address: "))
            if not value:
                continue
            if find_user_by_email(value) is not None:
                self.stderr.write("Error: an account already exists for that address.")
                continue
            return value
