from django.conf import settings
from django.conf.urls.static import static
from django.contrib import admin
from django.contrib.auth import views as auth_views
from django.contrib.auth.views import LoginView
from django.urls import include, path, reverse_lazy
from django.views.generic import RedirectView

from beatzlock_app import google_auth
from beatzlock_app import views as account_views
from beatzlock_app.forms import (
    EmailAuthenticationForm,
    EmailPasswordResetForm,
    EmailSetPasswordForm,
)

urlpatterns = [
    # The downloads listing is the landing page for this subdomain.
    path("", RedirectView.as_view(pattern_name="beatzlock_app:download_list", permanent=False)),

    path("beatzlock-admin/", admin.site.urls),
    # Ahead of the auth include, so sign-in asks for an email address rather
    # than the username nobody on this site has.
    path(
        "accounts/login/",
        LoginView.as_view(
            authentication_form=EmailAuthenticationForm,
            # LoginView puts its own site_name in the context -- the request's
            # host, since django.contrib.sites is not installed -- and view
            # context beats context processors. Without this the nav and footer
            # on this one page read "127.0.0.1:8005" instead of the site name.
            # extra_context is merged last, so it wins.
            extra_context={"site_name": settings.SITE_NAME},
        ),
        name="login",
    ),
    # Ahead of the include as well: django.contrib.auth.urls has no google/
    # routes, so these would otherwise fall through to the catch-all below.
    path("accounts/signup/", account_views.signup, name="signup"),
    path("accounts/google/login/", google_auth.google_login, name="google_login"),
    path("accounts/google/callback/", google_auth.google_callback, name="google_callback"),
    path(
        "accounts/password_reset/",
        auth_views.PasswordResetView.as_view(
            form_class=EmailPasswordResetForm,
            template_name="registration/password_reset_form.html",
            email_template_name="registration/password_reset_email.txt",
            html_email_template_name="registration/password_reset_email.html",
            subject_template_name="registration/password_reset_subject.txt",
            success_url=reverse_lazy("password_reset_done"),
            extra_context={"site_name": settings.SITE_NAME},
            extra_email_context={
                "site_name": settings.SITE_NAME,
                "support_email": settings.SUPPORT_EMAIL,
            },
        ),
        name="password_reset",
    ),
    path(
        "accounts/password_reset/done/",
        auth_views.PasswordResetDoneView.as_view(
            template_name="registration/password_reset_done.html",
            extra_context={"site_name": settings.SITE_NAME},
        ),
        name="password_reset_done",
    ),
    path(
        "accounts/reset/<uidb64>/<token>/",
        auth_views.PasswordResetConfirmView.as_view(
            form_class=EmailSetPasswordForm,
            template_name="registration/password_reset_confirm.html",
            success_url=reverse_lazy("password_reset_complete"),
            extra_context={"site_name": settings.SITE_NAME},
        ),
        name="password_reset_confirm",
    ),
    path(
        "accounts/reset/done/",
        auth_views.PasswordResetCompleteView.as_view(
            template_name="registration/password_reset_complete.html",
            extra_context={"site_name": settings.SITE_NAME},
        ),
        name="password_reset_complete",
    ),
    path(
        "accounts/password-reset/",
        auth_views.PasswordResetView.as_view(
            form_class=EmailPasswordResetForm,
            template_name="registration/password_reset_form.html",
            email_template_name="registration/password_reset_email.txt",
            html_email_template_name="registration/password_reset_email.html",
            subject_template_name="registration/password_reset_subject.txt",
            success_url=reverse_lazy("password_reset_done"),
            extra_context={"site_name": settings.SITE_NAME},
            extra_email_context={
                "site_name": settings.SITE_NAME,
                "support_email": settings.SUPPORT_EMAIL,
            },
        ),
    ),
    path(
        "accounts/password-reset/done/",
        auth_views.PasswordResetDoneView.as_view(
            template_name="registration/password_reset_done.html",
            extra_context={"site_name": settings.SITE_NAME},
        ),
    ),
    path("accounts/logout/", auth_views.LogoutView.as_view(), name="logout"),

    # Staff console: download stats, review replies, build history.
    path("console/", include("console.urls")),

    # The BeatzLock apps site owns the root on this subdomain.
    path("", include("beatzlock_app.urls", namespace="beatzlock_app")),

    path(
        "favicon.ico",
        RedirectView.as_view(url=settings.STATIC_URL + "favicon/favicon.ico"),
    ),
]

urlpatterns += static(settings.MEDIA_URL, document_root=settings.MEDIA_ROOT)
