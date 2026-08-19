from django import forms
from django.contrib.auth.forms import AuthenticationForm

from .identity import find_user_by_login_identifier


class EmailAuthenticationForm(AuthenticationForm):
    """Sign in with an email address rather than a username.

    The same form the authenticator API uses for its admin: the field still
    posts as `username`, because that is what `authenticate()` takes, but it
    collects an email and resolves it before the password is checked.
    """

    # Deliberately a text input, not an email input: the browser's type="email"
    # validation would block the legacy username fallback below.
    username = forms.CharField(
        label="Email address",
        max_length=254,
        widget=forms.TextInput(
            attrs={"autofocus": True, "autocomplete": "email", "inputmode": "email"}
        ),
    )

    error_messages = {
        **AuthenticationForm.error_messages,
        "invalid_login": (
            "That email address and password do not match an account."
        ),
    }

    def clean_username(self):
        # Resolve the address to the username the auth backend expects, with
        # the username fallback that covers accounts predating this.
        identifier = self.cleaned_data.get("username", "")
        user = find_user_by_login_identifier(identifier)
        return user.username if user is not None else identifier
