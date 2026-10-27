"""``manage.py createsuperuser``, asking for an email address and nothing else.

Django's own command asks for a username first and an email second. This site
has no separate usernames -- the email address is the login, see
``beatzlock_app/identity.py`` -- so this override asks only for the address and
writes it to both columns. Everything after that, the password prompt and its
validators included, is still Django's.

It lives in ``console`` rather than ``beatzlock_app`` for one reason: an app
only overrides a built-in command when it is listed *before* that command's app
in INSTALLED_APPS, and ``beatzlock_app`` has to stay after
``django.contrib.auth`` so its admin module can unregister the stock User
admin. ``console`` -- where the rest of the staff-facing tooling lives -- can
sit at the front without that conflict.
"""
import os
import sys

from django.contrib.auth.management.commands import createsuperuser
from django.core.management.base import CommandError

from beatzlock_app.identity import find_user_by_login_identifier, normalize_email


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

        options["email"] = email
        options[self.UserModel.USERNAME_FIELD] = email
        return super().handle(*args, **options)

    def _ask_for_email(self):
        field = self.UserModel._meta.get_field("email")
        while True:
            value = normalize_email(self.get_input_data(field, "Email address: "))
            if not value:
                continue
            if find_user_by_login_identifier(value) is not None:
                self.stderr.write("Error: an account already exists for that address.")
                continue
            return value
