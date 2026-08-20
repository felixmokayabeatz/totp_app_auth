from django import forms
from django.contrib.auth.forms import AuthenticationForm, UserChangeForm, UserCreationForm
from django.contrib.auth.models import User

from .identity import find_user_by_login_identifier, normalize_email
from .models import UserProfile


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
            attrs={
                "autofocus": True,
                "autocomplete": "email",
                "inputmode": "email",
                "placeholder": "you@example.com",
            }
        ),
    )

    password = forms.CharField(
        label="Password",
        strip=False,
        widget=forms.PasswordInput(
            attrs={
                "autocomplete": "current-password",
                "placeholder": "Your password",
            }
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


# 2MB. Big enough for a photo off a phone, small enough that nobody fills the
# disk with one; nginx would take a much larger body without complaining.
MAX_AVATAR_BYTES = 2 * 1024 * 1024


class AccountForm(forms.ModelForm):
    """The name someone chooses to show. The email is their login, so it is
    changed in the admin, not here."""

    class Meta:
        model = User
        fields = ('first_name', 'last_name')
        labels = {'first_name': 'First name', 'last_name': 'Last name'}


class AvatarForm(forms.ModelForm):
    class Meta:
        model = UserProfile
        fields = ('avatar',)
        labels = {'avatar': 'Profile image'}

    def clean_avatar(self):
        avatar = self.cleaned_data.get('avatar')
        # Only a freshly uploaded file has a size to check; an unchanged one
        # comes back as the existing FieldFile.
        if avatar and hasattr(avatar, 'size') and avatar.size > MAX_AVATAR_BYTES:
            raise forms.ValidationError(
                "That image is {:.1f}MB. Please keep it under 2MB.".format(
                    avatar.size / (1024 * 1024)
                )
            )
        return avatar


class SignUpForm(UserCreationForm):
    """Two names, an email and a password. That is the whole account.

    No confirmation mail: nothing here is worth the round trip, and an address
    that turns out to be wrong costs the person their own account, not ours.
    Django's password validators still run -- that is about the password being
    guessable, not about the email being real.
    """

    first_name = forms.CharField(
        label="First name",
        max_length=150,
        widget=forms.TextInput(attrs={
            "placeholder": "Felix", "autocomplete": "given-name", "autofocus": True,
        }),
    )
    last_name = forms.CharField(
        label="Last name",
        max_length=150,
        widget=forms.TextInput(attrs={
            "placeholder": "Mokaya", "autocomplete": "family-name",
        }),
    )
    email = forms.EmailField(
        label="Email address",
        widget=forms.EmailInput(attrs={
            "placeholder": "you@example.com", "autocomplete": "email",
        }),
    )

    class Meta:
        model = User
        fields = ("first_name", "last_name", "email")

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.fields["password1"].label = "Password"
        self.fields["password2"].label = "Confirm password"
        self.fields["password1"].widget.attrs.update({
            "placeholder": "At least 8 characters", "autocomplete": "new-password",
        })
        # Kept rather than dropped for brevity: this site has no password-reset
        # flow, so a typo in a single password box locks someone out for good.
        self.fields["password2"].widget.attrs.update({
            "placeholder": "Type it again", "autocomplete": "new-password",
        })

    def clean_email(self):
        email = normalize_email(self.cleaned_data.get("email"))
        if find_user_by_login_identifier(email) is not None:
            raise forms.ValidationError(
                "An account already exists for this address. Sign in instead."
            )
        return email

    def save(self, commit=True):
        user = super().save(commit=False)
        user.email = self.cleaned_data["email"]
        user.username = user.email
        if commit:
            user.save()
        return user
