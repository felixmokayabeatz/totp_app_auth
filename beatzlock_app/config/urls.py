from django.conf import settings
from django.conf.urls.static import static
from django.contrib import admin
from django.contrib.auth.views import LoginView
from django.urls import include, path
from django.views.generic import RedirectView

from beatzlock_app.forms import EmailAuthenticationForm

urlpatterns = [
    # The downloads listing is the landing page for this subdomain.
    path("", RedirectView.as_view(pattern_name="beatzlock_app:download_list", permanent=False)),

    path("beatzlock-admin/", admin.site.urls),
    # Ahead of the auth include, so sign-in asks for an email address rather
    # than the username nobody on this site has.
    path(
        "accounts/login/",
        LoginView.as_view(authentication_form=EmailAuthenticationForm),
        name="login",
    ),
    path("accounts/", include("django.contrib.auth.urls")),

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
