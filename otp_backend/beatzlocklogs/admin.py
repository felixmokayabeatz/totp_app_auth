from django.contrib import admin
from django.conf import settings as django_settings
from django.contrib.auth import get_user_model
from django.urls import path
from django.utils.decorators import method_decorator
from django.views import View
from django.contrib.admin.views.decorators import staff_member_required
from django.contrib.admin.sites import NotRegistered

from .views import log_viewer


@method_decorator(staff_member_required, name="dispatch")
class LogViewerAdmin(View):
    """Expose the shared log viewer inside Django admin."""

    def get(self, request, log_file=None):
        return log_viewer(request, log_file=log_file)


original_get_urls = admin.site.get_urls


def custom_get_urls():
    urls = original_get_urls()
    custom_urls = [
        path("logs/", LogViewerAdmin.as_view(), name="log_viewer"),
        path("logs/<path:log_file>/", LogViewerAdmin.as_view(), name="log_detail"),
    ]
    return custom_urls + urls


admin.site.get_urls = custom_get_urls


def _safe_unregister(model):
    try:
        admin.site.unregister(model)
    except NotRegistered:
        pass


if not django_settings.DEBUG:
    # Group is unregistered outright in users/admin.py; only the account list
    # is hidden conditionally, so it stays reachable in local development.
    _safe_unregister(get_user_model())
