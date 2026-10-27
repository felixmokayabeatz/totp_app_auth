"""Sign in with Google, as a plain OAuth 2.0 authorization-code exchange.

No new dependency: requests is already here for the review-reply bridge. The
flow is the short one, because this site needs nothing from Google after the
first hello -- no refresh token is kept and no Google API is called later:

  1. /accounts/google/login/     redirect to Google with a one-time state
  2. Google sends the person back to /accounts/google/callback/?code=&state=
  3. the code is exchanged for an access token, server to server
  4. the token buys one call to userinfo, which is what we actually wanted

Accounts are matched on the email address, because that is the login on this
site, and the Google account id is stored alongside so someone who later
changes the address on their Google account is still recognised.
"""
import secrets
from urllib.parse import urlencode

import requests
from django.conf import settings
from django.contrib import messages
from django.contrib.auth import login as auth_login
from django.contrib.auth.models import User
from django.http import Http404
from django.shortcuts import redirect
from django.urls import reverse

from .identity import find_user_by_login_identifier, normalize_email
from .models import UserProfile, profile_for

GOOGLE_AUTH_ENDPOINT = 'https://accounts.google.com/o/oauth2/v2/auth'
GOOGLE_TOKEN_ENDPOINT = 'https://oauth2.googleapis.com/token'
GOOGLE_USERINFO_ENDPOINT = 'https://openidconnect.googleapis.com/v1/userinfo'

GOOGLE_STATE_SESSION_KEY = 'google_oauth_state'
GOOGLE_NEXT_SESSION_KEY = 'google_oauth_next'

_MODEL_BACKEND = 'django.contrib.auth.backends.ModelBackend'

_HTTP_TIMEOUT = 10


def google_enabled():
    return bool(settings.GOOGLE_CLIENT_ID and settings.GOOGLE_CLIENT_SECRET)


def _callback_url(request):
    return request.build_absolute_uri(reverse('google_callback'))


def _safe_next(request, candidate):
    """Only ever redirect back into this site."""
    if candidate and candidate.startswith('/') and not candidate.startswith('//'):
        return candidate
    return reverse('beatzlock_app:account')


def google_login(request):
    """Step 1: hand the person to Google with a state we can recognise."""
    if not google_enabled():
        raise Http404("Google sign-in is not configured on this site.")

    state = secrets.token_urlsafe(32)
    request.session[GOOGLE_STATE_SESSION_KEY] = state
    request.session[GOOGLE_NEXT_SESSION_KEY] = _safe_next(
        request, request.GET.get('next')
    )

    params = {
        'client_id': settings.GOOGLE_CLIENT_ID,
        'redirect_uri': _callback_url(request),
        'response_type': 'code',
        'scope': 'openid email profile',
        'state': state,
        'prompt': 'select_account',
    }
    return redirect('{}?{}'.format(GOOGLE_AUTH_ENDPOINT, urlencode(params)))


def _fail(request, message):
    messages.error(request, message)
    return redirect('login')


def google_callback(request):
    """Steps 2-4: verify the state, trade the code, then sign the person in."""
    if not google_enabled():
        raise Http404("Google sign-in is not configured on this site.")

    expected_state = request.session.pop(GOOGLE_STATE_SESSION_KEY, None)
    next_url = request.session.pop(GOOGLE_NEXT_SESSION_KEY, None)

    if request.GET.get('error'):
        return _fail(request, "Google sign-in was cancelled.")

    state = request.GET.get('state')
    if not expected_state or not state or not secrets.compare_digest(state, expected_state):
        return _fail(request, "That Google sign-in link has expired. Please try again.")

    code = request.GET.get('code')
    if not code:
        return _fail(request, "Google did not send an authorization code. Please try again.")

    try:
        token_response = requests.post(
            GOOGLE_TOKEN_ENDPOINT,
            data={
                'code': code,
                'client_id': settings.GOOGLE_CLIENT_ID,
                'client_secret': settings.GOOGLE_CLIENT_SECRET,
                'redirect_uri': _callback_url(request),
                'grant_type': 'authorization_code',
            },
            timeout=_HTTP_TIMEOUT,
        )
        token_response.raise_for_status()
        access_token = token_response.json().get('access_token')
        if not access_token:
            return _fail(request, "Google did not return an access token. Please try again.")

        userinfo_response = requests.get(
            GOOGLE_USERINFO_ENDPOINT,
            headers={'Authorization': 'Bearer {}'.format(access_token)},
            timeout=_HTTP_TIMEOUT,
        )
        userinfo_response.raise_for_status()
        profile_data = userinfo_response.json()
    except requests.RequestException:
        return _fail(request, "Could not reach Google to finish signing in. Please try again.")
    except ValueError:
        return _fail(request, "Google sent a response we could not read. Please try again.")

    email = normalize_email(profile_data.get('email'))
    if not email:
        return _fail(request, "That Google account has no email address on it.")
    if not profile_data.get('email_verified'):
        return _fail(request, "Verify your email address with Google first, then sign in.")

    user = _user_for_google(profile_data, email)
    auth_login(request, user, backend=_MODEL_BACKEND)
    messages.success(request, "Signed in as {}.".format(user.email or user.username))
    return redirect(_safe_next(request, next_url))


def _user_for_google(profile_data, email):
    """Find the account this Google identity belongs to, or make one."""
    google_sub = (profile_data.get('sub') or '').strip()

    user = None
    if google_sub:
        profile = (
            UserProfile.objects.filter(google_sub=google_sub)
            .select_related('user')
            .first()
        )
        if profile is not None:
            user = profile.user

    if user is None:
        user = find_user_by_login_identifier(email)

    if user is None:
        user = User.objects.create_user(username=email, email=email)
        user.set_unusable_password()
        user.save(update_fields=['password'])

    changed = []
    if not user.email:
        user.email = email
        changed.append('email')
    if not user.first_name and profile_data.get('given_name'):
        user.first_name = profile_data['given_name'][:150]
        changed.append('first_name')
    if not user.last_name and profile_data.get('family_name'):
        user.last_name = profile_data['family_name'][:150]
        changed.append('last_name')
    if changed:
        user.save(update_fields=changed)

    profile = profile_for(user)
    profile.google_sub = google_sub or profile.google_sub
    profile.google_avatar_url = profile_data.get('picture') or profile.google_avatar_url
    profile.save(update_fields=['google_sub', 'google_avatar_url', 'updated_at'])
    return user
