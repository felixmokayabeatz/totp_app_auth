from django.conf import settings
from django.conf.urls.static import static
from django.contrib import admin
from django.contrib.auth import views as auth_views
from django.contrib.auth.views import LoginView
from django.urls import include, path, reverse_lazy
from django.contrib.sitemaps.views import sitemap
from django.views.generic import RedirectView, TemplateView

from beatzlock_app.sitemaps import sitemaps

from beatzlock_app import google_auth
from beatzlock_app import views as account_views
from beatzlock_app.forms import (
    EmailAuthenticationForm,
    EmailPasswordResetForm,
    EmailSetPasswordForm,
)

urlpatterns = [
    path("", RedirectView.as_view(pattern_name="beatzlock_app:download_list", permanent=False)),

    path("beatzlock-admin/", admin.site.urls),
    path(
        "accounts/login/",
        LoginView.as_view(
            authentication_form=EmailAuthenticationForm,
            extra_context={"site_name": settings.SITE_NAME},
        ),
        name="login",
    ),
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

    path("console/", include("console.urls")),

    path("", include("beatzlock_app.urls", namespace="beatzlock_app")),

    path(
        "favicon.ico",
        RedirectView.as_view(url=settings.STATIC_URL + "favicon/favicon.ico"),
    ),

    path("robots.txt", TemplateView.as_view(
        template_name="robots.txt", content_type="text/plain")),
    path("sitemap.xml", sitemap, {"sitemaps": sitemaps},
         name="django.contrib.sitemaps.views.sitemap"),
]

urlpatterns += static(settings.MEDIA_URL, document_root=settings.MEDIA_ROOT)
